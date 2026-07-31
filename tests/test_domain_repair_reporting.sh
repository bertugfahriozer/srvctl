#!/bin/bash
# 'domain repair' dürüst sonuç raporlaması — HOST'ta ölçülen fail-open bug.
#
# KÖK NEDEN (lib/domain.sh:_domain_repair): FPM unit/pool aktivasyonu
# BAŞARISIZ olsa bile fonksiyon KOŞULSUZ "✓ Domain onarıldı" basıyor ve
# implicit olarak 0 dönüyordu; '--all' dalı da tek tek dönüş değerlerini
# YOK SAYIP döngü sonunda KOŞULSUZ "✓ Tüm domainler onarıldı." + EXIT=0
# basıyordu. HOST'ta (srvctl-jammy, Ubuntu 22.04) ölçüldü: başarısız bir
# Symfony deploy'unun bıraktığı kırık 'public_html' symlink'i php-fpm'in
# 'chdir = /public_html' (chroot'a göreli) doğrulamasını başarısız kılıyor,
# izole FPM unit hiç başlamıyor (journalctl: repair ÖNCESİ 'active', SONRASI
# 'inactive') — ama repair yine de "✓ Domain onarıldı" + "✓ Tüm domainler
# onarıldı." + EXIT=0 basıyordu. Bir cron/betik yalnız exit kodunu
# kontrol ederse her şeyin yolunda olduğunu SANIR (composer/privdrop'ta
# yakalanan sınıfla AYNI kategori).
#
# Bu test dört şeyi kilitler:
#   1) TEK domain: izole FPM unit aktivasyonu başarısız olursa
#      '_domain_repair' SIFIRDAN FARKLI döner ve "✓ Domain onarıldı" mesajını
#      BASMAZ; bunun yerine domain'in şu an KAPALI olduğunu AÇIKÇA söyler.
#   2) TEK domain: paylaşılan pool'da php-fpm restart'ı başarısız olursa AYNI
#      dürüstlük (izole dalla SİMETRİK — 'restart ... || true' AYNI
#      fail-open sınıfıydı).
#   3) '--all': TEK bir domain başarısız olsa bile KALAN domainler için
#      onarım DEVAM EDER (toplu iş yarıda kesilmez), ama sonuç dürüst: kaç
#      domain başarısız olduğu yazılır ve fonksiyon SIFIRDAN FARKLI döner.
#   4) KARAR REVİZYONU (yeni HOST kanıtıyla): eksik/kırık 'public_html' artık
#      repair'in KENDİSİ TARAFINDAN onarılır (önceki sürüm yalnız teşhis
#      koyup onarmıyordu — 'releases/' boşken yönlendirilecek geçerli hedef
#      yoktu gerekçesiyle; ama deploy'un kendi kurtarma kodu arkasında GERÇEK
#      bir 'public_html.bak.<epoch>/' yedeği bırakabiliyor VE 'public_html'
#      TAMAMEN YOKKEN repair/php-switch/harden-fpm dahil TÜM kurtarma yolları
#      FPM config-test aşamasında çöküyordu — repair'in KENDİSİ onarmazsa
#      kendi kurtarma yolu da çalışmıyordu). En yeni '.bak.<epoch>' varsa
#      geri yüklenir (hangi yedek/ne zaman AÇIKÇA söylenir); yoksa doğru
#      sahiplik/izinle BOŞ bir 'public_html' oluşturulur. 'current' İÇİN
#      AYRI karar: kırıksa KALDIRILIR ama ASLA yeniden üretilmez (geçerli
#      bir release'e işaret etmesi zorunlu, sahte hedef üretmek yanlış olur).
#
# Test-seam'ler: WEB_ROOT / SRVCTL_STATE_DIR / SRVCTL_FPM_DIR /
# SRVCTL_SYSTEMD_DIR / SRVCTL_PHP_POOL_DIR — tests/test_domain_repair_isolation.sh
# ile AYNI desen.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
mysql() { return 0; }
redis-cli() { return 0; }

if ! declare -F _domain_repair >/dev/null 2>&1; then
    : # lib/domain.sh henüz source edilmedi; aşağıda source edilecek
fi

# systemctl mock: normalde başarılı, MOCK_SYSTEMCTL_RESTART_FAIL set'liyken
# 'restart' alt komutunu başarısız kılar (paylaşılan-pool senaryosu için).
systemctl() {
    if [[ "${1:-}" == "restart" && -n "${MOCK_SYSTEMCTL_RESTART_FAIL:-}" ]]; then
        return 1
    fi
    return 0
}

# 'id' mock: NÖTR varsayılan — '_domain_repair_is_ghost' (lib/domain.sh)
# 'web_<sname>' Linux kullanıcısının VARLIĞINA bakar. Bölüm A-D bu testin
# fixture'ları ('_setup_domain') gerçek bir sistem kullanıcısı OLUŞTURMUYOR;
# o bölümlerin konusu hayalet tespiti DEĞİL (FPM/symlink raporlaması) —
# burada 'id' HER ZAMAN "kullanıcı var" döner ki test domain'leri hayalet
# sayılıp reddedilmesin. Hayalet tespiti Bölüm E'de AYRICA ve ÖZEL OLARAK
# test ediliyor (orada 'id' yerel olarak override edilir).
id() { return 0; }

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_repair >/dev/null 2>&1; then
    echo "  SKIP: _domain_repair tanımlı değil"
    test_summary
    exit $?
fi

# Yardımcı: bir domain'in temel '.credentials' + dizin iskeletini kur.
_setup_domain() {
    local domain="$1" sname
    sname=$(safe_name "$domain")
    mkdir -p "${WEB_ROOT}/${domain}"
    _domain_write_credentials "$domain" "${WEB_ROOT}/${domain}" "web_${sname}" "8.3" \
        "db_${sname}" "usr_${sname}" "cleanpassdb1234" \
        "redis_${sname}" "cleanpassredis1234" "${sname}:"
}

echo "== domain repair: dürüst sonuç raporlama =="

# ═══════════ Bölüm A: TEK domain, İZOLE FPM aktivasyonu BAŞARISIZ ═══════════
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"

dA="broken-symfony.test"
snameA=$(safe_name "$dA")
_setup_domain "$dA"
# İzole unit ÖNCEDEN var (harden-fpm daha önce uygulanmış) -> izole dala düşer
printf 'listen = /run/php/php8.3-fpm-%s.sock\n' "$snameA" > "${SRVCTL_FPM_DIR}/${snameA}.conf"

# _domain_activate_fpm_unit'i BU domain için başarısız kılan mock (gerçek
# php-fpm/systemd'ye ihtiyaç duymadan '_domain_repair'in davranışını izole test eder).
_domain_activate_fpm_unit() { return 1; }

outA=$(_domain_repair "$dA" 2>&1); rcA=$?

assert_eq "$([[ "$rcA" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "Bölüm A: izole FPM aktivasyonu başarısızken _domain_repair SIFIRDAN FARKLI döner (rc=${rcA})"
assert_not_contains "$outA" "Domain onarıldı:" \
    "Bölüm A: başarı mesajı ('Domain onarıldı:') BASILMADI"
assert_contains "$outA" "ŞU AN KAPALI" \
    "Bölüm A: domainin şu an KAPALI olduğu AÇIKÇA söyleniyor"
assert_contains "$outA" "KISMEN onarıldı" \
    "Bölüm A: kısmi/başarısız onarım dürüstçe raporlanıyor"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

# ═══════════ Bölüm B: TEK domain, PAYLAŞILAN pool restart BAŞARISIZ ═══════════
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"

# Bölüm A'daki mock'u nötrle (bu bölümde izole dala hiç girilmiyor, ama temiz olsun)
_domain_activate_fpm_unit() { return 0; }

dB="shared-broken.test"
_setup_domain "$dB"
# İzole conf YOK -> paylaşılan pool.d dalına düşer

outB=$(MOCK_SYSTEMCTL_RESTART_FAIL=1 _domain_repair "$dB" 2>&1); rcB=$?

assert_eq "$([[ "$rcB" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "Bölüm B: paylaşılan pool restart'ı başarısızken _domain_repair SIFIRDAN FARKLI döner (rc=${rcB})"
assert_not_contains "$outB" "Domain onarıldı:" \
    "Bölüm B: başarı mesajı ('Domain onarıldı:') BASILMADI"
assert_contains "$outB" "BAŞLATILAMADI" \
    "Bölüm B: paylaşılan master'ın yeniden başlatılamadığı AÇIKÇA söyleniyor"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

# ═══════════ Bölüm C: '--all' — TEK domain başarısız, DÖNGÜ DEVAM ETMELİ ═══════════
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"

dOk="good-shop.test"
dFail="bad-shop.test"
snameFail=$(safe_name "$dFail")
_setup_domain "$dOk"
_setup_domain "$dFail"
# Yalnız dFail izole unit'e sahip (izole dala düşsün, aktivasyonu mock ile başarısız kılınacak)
printf 'listen = /run/php/php8.3-fpm-%s.sock\n' "$snameFail" > "${SRVCTL_FPM_DIR}/${snameFail}.conf"

# İsme-göre-koşullu mock: yalnız 'bad-shop.test' başarısız, diğerleri (dOk paylaşılan
# pool dalına düşer, orada aktivasyon hiç çağrılmaz) etkilenmez.
_domain_activate_fpm_unit() {
    case "$1" in
        "$dFail") return 1 ;;
        *) return 0 ;;
    esac
}

outAll=$(_domain_repair "--all" 2>&1); rcAll=$?

assert_eq "$([[ "$rcAll" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "Bölüm C: '--all' içinde bir domain başarısızken toplam sonuç SIFIRDAN FARKLI döner (rc=${rcAll})"
assert_contains "$outAll" "TAMAMLANAMADI" \
    "Bölüm C: '--all' dürüstçe başarısızlık raporluyor (koşulsuz 'Tüm domainler onarıldı.' YOK)"
assert_contains "$outAll" "$dFail" \
    "Bölüm C: başarısız domain adı ('${dFail}') sonuç mesajında GEÇİYOR"
# DÖNGÜ DEVAM ETTİ mi? dOk paylaşılan pool.d'ye GERÇEKTEN yazıldıysa (chroot
# içeriyor) bu domain'in onarımı da FİİLEN ÇALIŞTIRILMIŞ demektir — ilk
# domain başarısız olunca döngü KESİLMEDİ.
snameOk=$(safe_name "$dOk")
assert_contains "$(cat "${SRVCTL_PHP_POOL_DIR}/${snameOk}.conf" 2>/dev/null)" "chroot" \
    "Bölüm C: İLK domain başarısız olsa bile İKİNCİ domain (${dOk}) için onarım FİİLEN ÇALIŞTI (döngü kesilmedi)"
assert_contains "$outAll" "1/2 domain başarısız" \
    "Bölüm C: sayaç doğru — 2 domainden TAM OLARAK 1'i başarısız olarak raporlanıyor"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

# ═══════════ Bölüm D: public_html/current onarımı (KARAR REVİZYONU) ═══════
# HOST bulgusu: deploy'un kendi kurtarma kodu kırık symlink'i kaldırıp
# arkasında ('public_html.bak.<epoch>/') GERÇEK bir yedek bırakabiliyordu;
# 'public_html' TAMAMEN YOKKEN repair DAHİL tüm kurtarma yolları FPM
# config-test aşamasında çöküyordu. Artık repair KENDİSİ onarıyor.
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
_domain_activate_fpm_unit() { return 0; }

echo ""
echo "== public_html / current onarımı =="

# ─── D1: KOORDİNATÖRÜN 'KRİTİK ASSERTION'I — yedek YOK, public_html hem
# KIRIK symlink hem de 'current' kırık: repair sonrası public_html GERÇEK
# bir dizin olarak var olmalı (FPM config-testinin 'chdir' invariant'ını
# artık karşılar) ve 'current' KALDIRILMALI (asla uydurulmamalı). ---
dSym="dangling.test"
_setup_domain "$dSym"
rm -rf "${WEB_ROOT:?}/${dSym}/releases"
mkdir -p "${WEB_ROOT}/${dSym}/releases"
ln -s "releases/20260731_190854_009bf1" "${WEB_ROOT}/${dSym}/current"
ln -s "releases/20260731_190854_009bf1" "${WEB_ROOT}/${dSym}/public_html"

outSym=$(_domain_repair "$dSym" 2>&1)

assert_eq "$(test -e "${WEB_ROOT}/${dSym}/public_html" && echo VAR || echo YOK)" "VAR" \
    "D1 [KRİTİK]: yedek yokken bile repair SONRASI 'public_html' MEVCUT (chdir invariant'ı karşılanıyor)"
assert_eq "$(test -L "${WEB_ROOT}/${dSym}/public_html" && echo SYMLINK || echo GERCEK_DIZIN)" "GERCEK_DIZIN" \
    "D1: yeni oluşturulan 'public_html' GERÇEK bir dizin (symlink değil)"
assert_contains "$outSym" "BOŞ bir 'public_html' oluşturuldu" \
    "D1: yedek bulunamadığı ve boş dizin oluşturulduğu AÇIKÇA söyleniyor"
assert_eq "$(test -e "${WEB_ROOT}/${dSym}/current" || test -L "${WEB_ROOT}/${dSym}/current" && echo VAR || echo YOK)" "YOK" \
    "D1: kırık 'current' KALDIRILDI (ne dosya ne symlink olarak kaldı)"
assert_contains "$outSym" "YENİDEN ÜRETİLMEDİ" \
    "D1: 'current' UYDURULMADI — yalnız kaldırıldığı AÇIKÇA belirtiliyor"

rm -rf "${WEB_ROOT:?}/${dSym}"

# ─── D2: 'public_html.bak.<epoch>' YEDEĞİ VARSA geri yüklenir — EN YENİSİ
# kazanır (iki yedek: eskisi ve yenisi, içerikleri farklı marker dosyalarıyla
# ayırt edilebilir). ---
dBak="withbackup.test"
_setup_domain "$dBak"
rm -rf "${WEB_ROOT:?}/${dBak}/releases"
mkdir -p "${WEB_ROOT}/${dBak}/releases"
ln -s "releases/silinmis-release" "${WEB_ROOT}/${dBak}/public_html"
mkdir -p "${WEB_ROOT}/${dBak}/public_html.bak.1000000000"
echo "ESKI_YEDEK" > "${WEB_ROOT}/${dBak}/public_html.bak.1000000000/marker.txt"
mkdir -p "${WEB_ROOT}/${dBak}/public_html.bak.2000000000"
echo "YENI_YEDEK" > "${WEB_ROOT}/${dBak}/public_html.bak.2000000000/marker.txt"

outBak=$(_domain_repair "$dBak" 2>&1)

assert_eq "$(cat "${WEB_ROOT}/${dBak}/public_html/marker.txt" 2>/dev/null)" "YENI_YEDEK" \
    "D2: EN YENİ '.bak.<epoch>' (2000000000) geri yüklendi, eskisi DEĞİL"
assert_eq "$(test -d "${WEB_ROOT}/${dBak}/public_html.bak.2000000000" && echo VAR || echo YOK)" "YOK" \
    "D2: geri yüklenen yedek dizini TAŞINDI (eski konumda artık YOK — kopyalanmadı)"
assert_eq "$(test -d "${WEB_ROOT}/${dBak}/public_html.bak.1000000000" && echo VAR || echo YOK)" "VAR" \
    "D2: kullanılmayan (eski) yedek dizinine DOKUNULMADI"
assert_contains "$outBak" "public_html.bak.2000000000" \
    "D2: hangi yedeğin geri yüklendiği AÇIKÇA (dizin adıyla) söyleniyor"
assert_eq "$(test -L "${WEB_ROOT}/${dBak}/public_html" && echo SYMLINK || echo GERCEK_DIZIN)" "GERCEK_DIZIN" \
    "D2: 'public_html' artık GERÇEK bir dizin (kırık symlink DEĞİL)"

rm -rf "${WEB_ROOT:?}/${dBak}"

# ─── D3: 'current' kırık AMA 'public_html' ZATEN sağlıklı (gerçek dizin) —
# yalnız 'current' kaldırılmalı, 'public_html'e DOKUNULMAMALI. ---
dCurOnly="curonly.test"
_setup_domain "$dCurOnly"
mkdir -p "${WEB_ROOT}/${dCurOnly}/public_html"
echo "DOKUNMA" > "${WEB_ROOT}/${dCurOnly}/public_html/index.php"
ln -s "releases/yok-boyle-bir-release" "${WEB_ROOT}/${dCurOnly}/current"

outCurOnly=$(_domain_repair "$dCurOnly" 2>&1)

assert_eq "$(cat "${WEB_ROOT}/${dCurOnly}/public_html/index.php" 2>/dev/null)" "DOKUNMA" \
    "D3: zaten sağlıklı 'public_html' İÇERİĞİNE DOKUNULMADI"
assert_contains "$outCurOnly" "current' kırık bir symlink'ti" \
    "D3: 'current' kaldırma mesajı da basıldı ('public_html' sağlıklıyken bile)"
assert_eq "$(test -e "${WEB_ROOT}/${dCurOnly}/current" || test -L "${WEB_ROOT}/${dCurOnly}/current" && echo VAR || echo YOK)" "YOK" \
    "D3: yalnız kırık 'current' kaldırıldı"

rm -rf "${WEB_ROOT:?}/${dCurOnly}"

# ─── D4: Sağlıklı symlink'ler (hedefleri VAR) — YANLIŞ POZİTİF üretmemeli,
# repair sessizce hiçbir şeye dokunmamalı. ---
dHealthy="healthy.test"
_setup_domain "$dHealthy"
rm -rf "${WEB_ROOT:?}/${dHealthy}/releases"
mkdir -p "${WEB_ROOT}/${dHealthy}/releases/20260101_000000_aaaaaa/public"
ln -s "releases/20260101_000000_aaaaaa" "${WEB_ROOT}/${dHealthy}/current"
ln -s "releases/20260101_000000_aaaaaa/public" "${WEB_ROOT}/${dHealthy}/public_html"

outHealthy=$(_domain_repair "$dHealthy" 2>&1)
assert_not_contains "$outHealthy" "kırık bir symlink'ti" \
    "D4: SAĞLIKLI symlink'lere YANLIŞ POZİTİF üretilmiyor (dokunulmadı)"
assert_eq "$(readlink "${WEB_ROOT}/${dHealthy}/current" 2>/dev/null)" "releases/20260101_000000_aaaaaa" \
    "D4: sağlıklı 'current' DEĞİŞTİRİLMEDİ"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

# ═══════════ Bölüm E: Hayalet/kalıntı domain tespiti (kendi kendini ═══════
# ═══════════ sahiplenme döngüsünün kırılması — HOST bulgusu: 'html') ══════
# HOST bulgusu (srvctl-jammy): nginx paketinin kurduğu '/var/www/html'
# dizini 'repair --all' tarafından "onarılmaya" çalışılıyor, DB/Redis adımı
# atlanıyor (boş parola) ama fonksiyon sonunda yine de '.credentials' YAZIYOR
# ve bir AppArmor profili YÜKLÜYORDU — var olmayan 'web_html' kullanıcısına
# atıfta bulunan HAYALET bir "domain" kalıcı hale geliyordu. Daha da kötüsü:
# bir kez '.credentials' yazılınca dizin 'list_all_domains()'e (lib/core.sh —
# işareti '.credentials') göre de MEŞRU bir domain oluyordu — kendi kendini
# doğrulayan bir döngü.
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
_domain_activate_fpm_unit() { return 0; }

echo ""
echo "== hayalet/kalıntı domain tespiti =="

# ─── E1: KOORDİNATÖRÜN 'EN KRİTİK ASSERTION'I — TEMİZ hayalet (nginx'in
# gerçek '/var/www/html'i taklidi): '.credentials' YOK, web kullanıcısı YOK.
# 'list_all_domains()' bunu zaten '.credentials' yokluğuna göre ELER — bu
# yüzden '--all' döngüsüne HİÇ GİRMEMELİ, dokunmamalı, '.credentials'
# YAZMAMALI. ---
dHtml="html"
mkdir -p "${WEB_ROOT}/${dHtml}"
# 'id' NÖTR mock'u (Bölüm A-D'den) burada da geçerli — ama '/var/www/html'
# gerçek dünyada zaten 'web_html' kullanıcısı OLMADIĞI için gerçek senaryoyu
# tam yansıtmak adına AÇIKÇA "yok" döndüren bir mock kullanıyoruz.
id() { [[ "$1" == "web_html" ]] && return 1 || return 0; }

# Başka hiçbir domain yokken bile (yalnız 'html') '--all' çalıştırılabilmeli.
outHtmlAll=$(_domain_repair "--all" 2>&1); rcHtmlAll=$?

assert_eq "$(test -f "${WEB_ROOT}/${dHtml}/.credentials" && echo VAR || echo YOK)" "YOK" \
    "E1 [EN KRİTİK]: '.credentials'ı OLMAYAN 'html' dizinine '--all' SONRASI da '.credentials' YAZILMADI"
assert_not_contains "$outHtmlAll" "html" \
    "E1: 'html' 'list_all_domains()' tarafından zaten elendiği için çıktıda HİÇ GEÇMİYOR (ne başarılı ne hayalet ne başarısız)"
assert_eq "$([[ "$rcHtmlAll" -eq 0 ]] && echo ZERO || echo NONZERO)" "ZERO" \
    "E1: tek 'domain' aslında hayalet olduğunda bile (henüz .credentials yok) '--all' SIFIR döner — sahte gürültü YOK"

rm -rf "${WEB_ROOT:?}/${dHtml}"

# ─── E2: KENDİ KENDİNİ SAHİPLENME DÖNGÜSÜ — dizin ZATEN kirlenmiş (önceki
# BUGGY bir 'repair --all' çalıştırması '.credentials' bırakmış), ama web
# kullanıcısı YOK. Bu artık 'list_all_domains()'e göre "meşru" görünüyor —
# '_domain_repair_is_ghost' katmanı BURADA devreye girip döngüyü kırmalı. ---
dGhost="ghost-leftover.test"
mkdir -p "${WEB_ROOT}/${dGhost}"
snameGhost=$(safe_name "$dGhost")
# Önceki (buggy) repair'in bıraktığı türden kalıntı: '.credentials' VAR.
_domain_write_credentials "$dGhost" "${WEB_ROOT}/${dGhost}" "web_${snameGhost}" "8.3" \
    "db_${snameGhost}" "usr_${snameGhost}" "cleanpassdb1234" \
    "redis_${snameGhost}" "cleanpassredis1234" "${snameGhost}:"
_credsBeforeGhost=$(cat "${WEB_ROOT}/${dGhost}/.credentials")

dReal="real-domain.test"
_setup_domain "$dReal"

id() {
    case "$1" in
        "web_${snameGhost}") return 1 ;;
        *) return 0 ;;
    esac
}

outMixed=$(_domain_repair "--all" 2>&1); rcMixed=$?

assert_contains "$outMixed" "GÖRÜNMÜYOR" \
    "E2: kirlenmiş kalıntı ('${dGhost}') AÇIKÇA hayalet olarak raporlanıyor"
assert_not_contains "$outMixed" "${dGhost} başarısız" \
    "E2: hayalet bir 'başarısızlık' olarak SAYILMIYOR (gerçek hatalardan ayrışıyor)"
assert_eq "$(cat "${WEB_ROOT}/${dGhost}/.credentials" 2>/dev/null)" "$_credsBeforeGhost" \
    "E2 [EN KRİTİK — döngü kırıldı]: kirlenmiş kalıntının '.credentials'ı DOKUNULMADAN aynı kaldı (repair onu YENİDEN YAZMADI/güncellemedi)"
assert_eq "$([[ "$rcMixed" -eq 0 ]] && echo ZERO || echo NONZERO)" "ZERO" \
    "E2: aradaki tek GERÇEK domain başarılıyken hayalet kalıntı '--all' sonucunu BOZMUYOR (return 0)"

# İKİNCİ (gerçek) domain'in onarımı hayalet YÜZÜNDEN atlanmadı mı?
snameReal=$(safe_name "$dReal")
assert_contains "$(cat "${SRVCTL_PHP_POOL_DIR}/${snameReal}.conf" 2>/dev/null)" "chroot" \
    "E2: gerçek domain ('${dReal}') hayalete rağmen FİİLEN onarıldı"

# ─── E3: doğrudan tek-domain çağrısı da AYNI korumadan geçiyor mu? ───
dGhost2="direct-ghost.test"
mkdir -p "${WEB_ROOT}/${dGhost2}"
snameGhost2=$(safe_name "$dGhost2")
_domain_write_credentials "$dGhost2" "${WEB_ROOT}/${dGhost2}" "web_${snameGhost2}" "8.3" \
    "db_${snameGhost2}" "usr_${snameGhost2}" "cleanpassdb1234" \
    "redis_${snameGhost2}" "cleanpassredis1234" "${snameGhost2}:"
id() { [[ "$1" == "web_${snameGhost2}" ]] && return 1 || return 0; }

outDirect=$(_domain_repair "$dGhost2" 2>&1); rcDirect=$?
assert_eq "$([[ "$rcDirect" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "E3: doğrudan 'srvctl domain repair ${dGhost2}' çağrısı da SIFIRDAN FARKLI döner"
assert_contains "$outDirect" "GÖRÜNMÜYOR" "E3: doğrudan çağrıda da hayalet teşhisi basılıyor"
assert_not_contains "$outDirect" "Domain onarıldı:" "E3: doğrudan çağrıda başarı mesajı BASILMADI"

# Nötr mock'u geri yükle (dosyanın geri kalanı için — şu an sonda olsa da iyi pratik).
id() { return 0; }

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

test_summary
