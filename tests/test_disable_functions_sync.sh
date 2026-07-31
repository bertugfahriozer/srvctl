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

# --- Fonksiyonun kendi davranışı: ci4 istisnası dar mı? ---
ci4_out=$(_domain_disable_functions_for "ci4")
lar_out=$(_domain_disable_functions_for "laravel")
sym_out=$(_domain_disable_functions_for "symfony")
none_out=$(_domain_disable_functions_for "")

assert_not_contains ",${ci4_out}," ",putenv," "ci4: 'putenv' AÇIK (framework boot edebilsin)"
assert_contains     ",${lar_out},"  ",putenv," "laravel: 'putenv' kapalı"
assert_contains     ",${sym_out},"  ",putenv," "symfony: 'putenv' kapalı"
assert_contains     ",${none_out}," ",putenv," "framework beyan edilmemiş: 'putenv' kapalı (güvenli varsayılan)"

# İstisna GERÇEKTEN dar olmalı: ci4 ile laravel arasındaki TEK fark putenv
diff_only=$(tr ',' '\n' <<<"$lar_out" | sort > /tmp/.df_lar.$$; \
            tr ',' '\n' <<<"$ci4_out" | sort > /tmp/.df_ci4.$$; \
            comm -23 /tmp/.df_lar.$$ /tmp/.df_ci4.$$ | tr '\n' ' ' | sed 's/ *$//')
rm -f /tmp/.df_lar.$$ /tmp/.df_ci4.$$
assert_eq "$diff_only" "putenv" \
    "ci4 istisnası DAR: laravel'e göre tek fark 'putenv' (başka fonksiyon gevşetilmemiş)"

test_summary
