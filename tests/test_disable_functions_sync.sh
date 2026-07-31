#!/bin/bash
# disable_functions senkron + tek-yönlülük dedektörü.
#
# NEDEN VAR: 'disable_functions' TEK YÖNLÜDÜR. Global
# /etc/php/<ver>/fpm/conf.d/99-srvctl-security.ini (lib/init.sh içinde heredoc)
# içinde listelenen bir fonksiyon php.ini/conf.d işlenirken zend_disable_function()
# ile fonksiyon tablosundan SİLİNİR. Pool'un php_admin_value[disable_functions]'ı
# onu GERİ AÇAMAZ — yalnızca listeyi UZATABİLİR.
#
# Bu asimetri sessiz ve pahalı bir hata sınıfı üretti (Ubuntu 22.04 VM'de
# ölçüldü): pool listesinde 'putenv' YOKKEN bile, global listede olduğu için
# function_exists('putenv') = false döndü ve CodeIgniter 4 HİÇ boot edemedi
# ('Call to undefined function CodeIgniter\Config\putenv()', HTTP 500). Yani
# "pool'da yok" demek "domainde açık" DEMEK DEĞİLDİR; ci4 istisnası ancak
# fonksiyon global tabandan ÇIKARILIP pool tarafında geri EKLENİRSE çalışır.
#
# Bu testin kilitlediği üç şey:
#   1) İki listenin TABANI birebir aynı kalsın (elle senkron tutulan iki ayrı
#      dosya — tam da test_template_tokens / test_meta_key_registry ile aynı
#      "üretici-tüketici iki dosyada" sınıfı).
#   2) 'putenv' global tabana GERİ EKLENMESİN (eklenirse ci4 sessizce kırılır;
#      pool'daki istisna etkisiz kalır, kimse fark etmez).
#   3) Process-spawn primitifleri HER İKİ listede de kapalı kalsın. ci4'te
#      putenv'i açık bırakmanın güvenli olmasının TEK dayanağı budur:
#      putenv("LD_PRELOAD=...") ancak yeni bir fork+exec ile sömürülebilir.
#      Biri ileride 'exec'/'proc_open' vb. listeden çıkarırsa ci4 istisnası
#      gerçek bir yerel privilege-escalation zincirine dönüşür — o yüzden
#      sömürü zincirinin diğer halkasını burada kilitliyoruz.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "== disable_functions senkron + tek-yönlülük =="

# --- Global taban: lib/init.sh heredoc'undaki ini satırı (yorum satırları ';'
# ile başlar, onları eleyerek gerçek direktifi al) ---
global_list=$(grep -E "^disable_functions[[:space:]]*=" "${REPO_ROOT}/lib/init.sh" \
    | head -1 | sed 's/^[^=]*=[[:space:]]*//')

# --- Pool tabanı: lib/domain.sh:_domain_disable_functions_for'ın kendi çıktısı.
# domain.sh'ı bütün olarak source etmek ağır (core.sh + yan etkiler); yalnız
# ilgili fonksiyonu izole ederek çalıştır. Tabanı sabit metinden değil
# FONKSİYONDAN almak, testin gerçek davranışı ölçmesini sağlar. ---
fn_body=$(awk '/^_domain_disable_functions_for\(\) \{/,/^\}/' "${REPO_ROOT}/lib/domain.sh")
assert_ok test -n "$fn_body"
eval "$fn_body"

# ci4 dalı tam olarak 'base'i döndürür (putenv eklenmeyen dal)
pool_base=$(_domain_disable_functions_for "ci4")

assert_ok test -n "$global_list"
assert_ok test -n "$pool_base"

# (1) İki taban birebir aynı olmalı
assert_eq "$pool_base" "$global_list" \
    "global 99-srvctl-security.ini tabanı == _domain_disable_functions_for base"

# (2) 'putenv' global tabanda OLMAMALI — geri eklenirse ci4 sessizce kırılır
assert_not_contains ",${global_list}," ",putenv," \
    "'putenv' global tabanda YOK (pool geri açamaz; ci4 boot edemez)"

# (3) Spawn primitifleri her iki listede de kapalı — ci4'teki putenv
#     istisnasının güvenli kalmasının tek dayanağı
for fn in exec passthru shell_exec system proc_open popen pcntl_exec pcntl_fork; do
    assert_contains ",${global_list}," ",${fn}," "global: '${fn}' kapalı"
    assert_contains ",${pool_base},"   ",${fn}," "pool tabanı: '${fn}' kapalı"
done

# (4) GÜVENLİK DENETİMİ EKİ — mail-ailesi fonksiyonlar + putenv() LD_PRELOAD
# zinciri: mail()/mb_send_mail()/imap_mail() ÜÇÜ DE dahili popen(sendmail_path)
# çağırır; bu iç popen() disable_functions içindeki 'popen' girişinden
# BAĞIMSIZDIR (o giriş yalnız PHP kodunun DOĞRUDAN popen() çağırmasını
# engeller) — HOST'ta doğrulandı (srvctl-jammy, Ubuntu 22.04, PHP 8.3): 'mail'
# disable_functions'tayken bile mb_send_mail() GERÇEKTEN spawn etti. putenv'in
# aksine bu üç fonksiyon için hiçbir framework'ün boot-zamanı zorunluluğu
# yoktur — bu yüzden istisnasız HER framework için (ci4 DAHİL) TABANDA kapalı
# olmalı; ne global'den ne pool tabanından eksik olabilir.
for fn in mail mb_send_mail imap_mail; do
    assert_contains ",${global_list}," ",${fn}," \
        "global: '${fn}' kapalı (mail-ailesi + putenv() LD_PRELOAD zincirinin savunması)"
    assert_contains ",${pool_base}," ",${fn}," \
        "pool tabanı (ci4 dalı): '${fn}' kapalı — putenv'in aksine ci4'e istisna YOK"
done

# (5) error_log KASITLI OLARAK listede OLMAMALI — kapatılamayan kalıcı delik.
# error_log($msg, 1, $to) AYNI dahili sendmail yolunu kullanır ve HOST'ta
# 'mail' disable_functions'tayken bile spawn ETTİĞİ doğrulandı, ama
# Laravel/CI4/Monolog'un TEMEL hata loglamasına gömülü olduğundan
# disable_functions'a EKLENEMEZ (eklenirse framework'ler ÇALIŞAMAZ hale gelir).
# Bu NEGATİF assertion, birinin ileride "tutarlılık" adına error_log'u listeye
# eklemesini (ve frameworkleri kırmasını) yakalar — bkz.
# lib/domain.sh:_domain_disable_functions_for başlık yorumu ("error_log
# KASITLI OLARAK EKLENMEDİ" bölümü, gerçek kontrolün AppArmor exec deny
# olduğu HOST kanıtıyla birlikte).
assert_not_contains ",${global_list}," ",error_log," \
    "global: 'error_log' KAPATILMADI (Laravel/CI4/Monolog'u kırmamak için kasıtlı)"
assert_not_contains ",${pool_base}," ",error_log," \
    "pool tabanı: 'error_log' KAPATILMADI (kasıtlı — yukarı bkz.)"

# --- Fonksiyonun kendi davranışı: ci4 istisnası dar mı? ---
ci4_out=$(_domain_disable_functions_for "ci4")
lar_out=$(_domain_disable_functions_for "laravel")
sym_out=$(_domain_disable_functions_for "symfony")
none_out=$(_domain_disable_functions_for "")

assert_not_contains ",${ci4_out}," ",putenv," "ci4: 'putenv' AÇIK (framework boot edebilsin)"
assert_contains     ",${lar_out},"  ",putenv," "laravel: 'putenv' kapalı"
assert_contains     ",${sym_out},"  ",putenv," "symfony: 'putenv' kapalı"
assert_contains     ",${none_out}," ",putenv," "framework beyan edilmemiş: 'putenv' kapalı (güvenli varsayılan)"

# mail-ailesi (mail/mb_send_mail/imap_mail) putenv'in AKSİNE HER framework
# çıktısında kapalı olmalı — ci4 için de istisna YOK (hiçbiri boot'ta
# gerekmiyor, yalnız uygulama-zamanı opsiyonel).
for fn in mail mb_send_mail imap_mail; do
    assert_contains ",${ci4_out}," ",${fn}," "ci4: '${fn}' kapalı (putenv'ten farklı olarak istisna yok)"
    assert_contains ",${lar_out}," ",${fn}," "laravel: '${fn}' kapalı"
    assert_contains ",${sym_out}," ",${fn}," "symfony: '${fn}' kapalı"
    assert_contains ",${none_out}," ",${fn}," "framework beyan edilmemiş: '${fn}' kapalı"
done

# error_log HİÇBİR framework çıktısında OLMAMALI (kasıtlı — yukarı bkz.)
assert_not_contains ",${ci4_out}," ",error_log," "ci4: 'error_log' KAPATILMADI (kasıtlı)"
assert_not_contains ",${lar_out}," ",error_log," "laravel: 'error_log' KAPATILMADI (kasıtlı)"
assert_not_contains ",${sym_out}," ",error_log," "symfony: 'error_log' KAPATILMADI (kasıtlı)"
assert_not_contains ",${none_out}," ",error_log," "framework beyan edilmemiş: 'error_log' KAPATILMADI (kasıtlı)"

# İstisna GERÇEKTEN dar olmalı: ci4 ile laravel arasındaki TEK fark putenv
diff_only=$(tr ',' '\n' <<<"$lar_out" | sort > /tmp/.df_lar.$$; \
            tr ',' '\n' <<<"$ci4_out" | sort > /tmp/.df_ci4.$$; \
            comm -23 /tmp/.df_lar.$$ /tmp/.df_ci4.$$ | tr '\n' ' ' | sed 's/ *$//')
rm -f /tmp/.df_lar.$$ /tmp/.df_ci4.$$
assert_eq "$diff_only" "putenv" \
    "ci4 istisnası DAR: laravel'e göre tek fark 'putenv' (başka fonksiyon gevşetilmemiş)"

# ─────────────────────────────────────────────────────────────────────────────
# ZİNCİR TESTİ — asıl korunan sınıf
#
# NEDEN VAR: bu testin ilk sürümü YALNIZ _domain_disable_functions_for'u izole
# çağırıyordu ('' → putenv kapalı) ve GEÇİYORDU. Ama gerçek çağrı sitesi
# fonksiyona _domain_read_framework çıktısını veriyordu; o da beyan
# yoksa/geçersizse 'ci4' döndürdüğü için '--framework' verilmeden eklenmiş HER
# domain ve meta'sı olmayan TÜM eski domainler sessizce 'putenv' AÇIK pool
# alıyordu. Yani test HALKAYI doğruluyordu, ZİNCİRİ değil — bir güvenlik
# denetimi bunu yakaladı.
#
# Bu blok artık zincirin tamamını ölçer: meta içeriği → _domain_framework_declared
# → _domain_disable_functions_for → putenv açık/kapalı.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== zincir: meta beyanı -> disable_functions =="

source "${REPO_ROOT}/lib/core.sh"
WEB_ROOT=$(mktemp -d)

# Sahiplik kapısı bu testin kapsamı DEĞİL (kendi testi var) — nötrle ki
# framework beyan mantığını izole ölçebilelim.
_require_owned_or_warn() { return 0; }

decl_body=$(awk '/^_domain_framework_declared\(\) \{/,/^\}/' "${REPO_ROOT}/lib/domain.sh")
assert_ok test -n "$decl_body"
eval "$decl_body"

# meta_içeriği | beklenen_declared | beklenen_putenv_durumu | açıklama
_chain_case() {
    local meta_content="$1" want_decl="$2" want_putenv="$3" label="$4"
    local d="ornek.test"
    rm -rf "${WEB_ROOT:?}/${d}"; mkdir -p "${WEB_ROOT}/${d}"
    [[ "$meta_content" != "__YOK__" ]] && printf '%s\n' "$meta_content" > "${WEB_ROOT}/${d}/.srvctl-meta"

    local got_decl; got_decl=$(_domain_framework_declared "$d" 2>/dev/null)
    assert_eq "$got_decl" "$want_decl" "${label}: beyan='${want_decl:-<boş>}'"

    local out; out=$(_domain_disable_functions_for "$got_decl")
    local got_putenv; case ",$out," in *,putenv,*) got_putenv="KAPALI";; *) got_putenv="AÇIK";; esac
    assert_eq "$got_putenv" "$want_putenv" "${label}: putenv ${want_putenv}"
}

_chain_case "__YOK__"              ""        "KAPALI" "meta dosyası YOK (eski domain)"
_chain_case "RATE_PROFILE=standard" ""       "KAPALI" "meta var ama FRAMEWORK satırı yok"
_chain_case "FRAMEWORK="            ""       "KAPALI" "FRAMEWORK boş"
_chain_case "FRAMEWORK=bogus"       ""       "KAPALI" "FRAMEWORK geçersiz (bozuk/tamper)"
_chain_case "FRAMEWORK=ci4"         "ci4"    "AÇIK"   "FRAMEWORK=ci4 AÇIKÇA beyan edilmiş"
_chain_case "FRAMEWORK=laravel"     "laravel" "KAPALI" "FRAMEWORK=laravel"
_chain_case "FRAMEWORK=symfony"     "symfony" "KAPALI" "FRAMEWORK=symfony"

rm -rf "${WEB_ROOT:?}"

# ─── Statik regresyon kilidi ───
# Çağrı siteleri fail-open okuyucuyu (_domain_read_framework) disable_functions'a
# BESLEMEMELİ. Biri ileride geri değiştirirse burada yakalanır.
bad_calls=$(grep -nE '_domain_disable_functions_for "\$\(?_domain_read_framework' "${REPO_ROOT}/lib/domain.sh" || true)
assert_eq "$bad_calls" "" \
    "hiçbir çağrı sitesi _domain_read_framework çıktısını disable_functions'a beslemiyor"

# Her çağrı sitesi 'declared' izini kullanmalı
call_args=$(grep -oE '_domain_disable_functions_for "\$[a-z_]+"' "${REPO_ROOT}/lib/domain.sh" \
    | sed 's/.*"\$//; s/"//' | sort -u | tr '\n' ' ' | sed 's/ *$//')
assert_eq "$call_args" "framework_declared repair_fw_declared unit_fw_declared" \
    "üç çağrı sitesi de AÇIK beyan değişkenini kullanıyor"

test_summary
