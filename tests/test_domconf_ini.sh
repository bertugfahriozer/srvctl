#!/bin/bash
# 'domain ini' — reddedilen anahtar taraması, --force kaçış kapısı,
# ve ROLLBACK BÜTÜNLÜĞÜ (bozuk .ini yalnız kendini değil, türettiği pool'u
# da geri almalı — aksi halde bozuk pool diskte kalır ve bir sonraki
# repair/reload onu canlıya alır).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_PHP_INI_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"
log_action() { :; }
send_notification() { :; }
mkdir -p "${WEB_ROOT}/example.com"

_derive_php() { echo "8.3"; }
RENDER_CALLS=0
# Pool'u .ini'den TÜRET — rollback'in pool'u da geri aldığını görebilelim.
_domain_render_fpm_unit() {
    RENDER_CALLS=$((RENDER_CALLS+1))
    local sname; sname=$(safe_name "$1")
    cat "${SRVCTL_PHP_INI_DIR}/${sname}.ini" > "${SRVCTL_FPM_DIR}/${sname}.conf" 2>/dev/null || true
}
reload_domain_fpm() { return 0; }
domain_fpm_unit() { echo "srvctl-fpm-$1.service"; }
source "${REPO_ROOT}/lib/domconf.sh"

# DİKKAT: _domconf_fpm_config_test domconf.sh'ta TANIMLI — mock'u source'tan
# ÖNCE koyarsak source onu EZER ve mock hiç devreye girmez. (Gerçek fonksiyon
# macOS'ta "php-fpm binary yok → 0" der, yani rollback yolu HİÇ test edilmemiş
# olurdu.) reload_domain_fpm/domain_fpm_unit core.sh'ta olduğu için onların
# mock'ları yukarıda, core.sh source'undan SONRA tanımlanıyor — aynı kural.
FPM_TEST_RC=0
_domconf_fpm_config_test() { return "$FPM_TEST_RC"; }

INI="${SRVCTL_PHP_INI_DIR}/example_com.ini"
POOL="${SRVCTL_FPM_DIR}/example_com.conf"
TMP="$(mktemp -d)"

echo "── Bölüm A: reddedilen anahtar taraması ──"
for key in extension zend_extension open_basedir disable_functions \
           disable_classes sendmail_path allow_url_fopen allow_url_include \
           cgi.fix_pathinfo; do
    printf '%s = x\n' "$key" > "${TMP}/scan.ini"
    _domconf_scan_ini "${TMP}/scan.ini" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "reddedilen anahtar yakalanır: ${key}"
done

printf 'memory_limit = 512M\nopcache.enable = 1\n' > "${TMP}/scan.ini"
_domconf_scan_ini "${TMP}/scan.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "masum anahtarlar temiz geçer"

printf '; extension = evil.so\n# open_basedir = /\n' > "${TMP}/scan.ini"
_domconf_scan_ini "${TMP}/scan.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "YORUM içindeki reddedilen anahtar yakalanmaz"

printf 'extension = evil.so\n' > "${TMP}/scan.ini"
out=$(_domconf_scan_ini "${TMP}/scan.ini" 2>&1 || true)
assert_contains "$out" "satır 1" "bulgu satır numarasıyla raporlanır"
assert_contains "$out" "root" "gerekçe metni gösterilir"

echo "── Bölüm B: --file ile uygulama ──"
printf 'memory_limit = 512M\n' > "${TMP}/new.ini"
_domconf_edit_ini example.com --file "${TMP}/new.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "geçerli .ini uygulanır"
assert_contains "$(cat "$INI")" "memory_limit = 512M" "içerik canlı dosyaya yazıldı"

# DİKKAT: core.sh'ın error() fonksiyonu EXIT EDER. Hata bekleyen her çağrı
# ALT KABUKTA '( ... )' koşmalı, aksi halde test scriptinin KENDİSİ ölür ve
# kalan bölümler hiç çalışmaz (sessizce "geçmiş" görünür).
echo "── Bölüm C: reddedilen anahtar --force olmadan UYGULANMAZ ──"
cp "$INI" "${TMP}/before.ini"
printf 'extension = evil.so\n' > "${TMP}/bad.ini"
( _domconf_edit_ini example.com --file "${TMP}/bad.ini" ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reddedilen anahtar → exit 1"
assert_eq "$(cat "$INI")" "$(cat "${TMP}/before.ini")" "canlı .ini DEĞİŞMEDİ"

echo "── Bölüm D: --force geçer ──"
_domconf_edit_ini example.com --file "${TMP}/bad.ini" --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--force ile uygulanır"
assert_contains "$(cat "$INI")" "extension = evil.so" "--force içeriği yazdı"

echo "── Bölüm E: ROLLBACK BÜTÜNLÜĞÜ ──"
printf 'memory_limit = 512M\n' > "${TMP}/good.ini"
_domconf_edit_ini example.com --file "${TMP}/good.ini" >/dev/null 2>&1
cp "$INI" "${TMP}/before.ini"; cp "$POOL" "${TMP}/before.conf"

FPM_TEST_RC=1
printf 'max_execution_time = 999\n' > "${TMP}/next.ini"
( _domconf_edit_ini example.com --file "${TMP}/next.ini" ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "php-fpm -t başarısız → exit 1"
assert_eq "$(cat "$INI")" "$(cat "${TMP}/before.ini")" "rollback: .ini eski halinde"
assert_eq "$(cat "$POOL")" "$(cat "${TMP}/before.conf")" "rollback: POOL da eski halinde"
FPM_TEST_RC=0

echo "── Bölüm F: sözdizimi hatası hiçbir şey yazmaz ──"
cp "$INI" "${TMP}/before.ini"
printf '[www]\n' > "${TMP}/syn.ini"
( _domconf_edit_ini example.com --file "${TMP}/syn.ini" ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "sözdizimi hatası → exit 1"
assert_eq "$(cat "$INI")" "$(cat "${TMP}/before.ini")" "sözdizimi hatasında .ini değişmedi"

echo "── Bölüm G: değişiklik yoksa render/reload yapılmaz ──"
RENDER_CALLS=0
cp "$INI" "${TMP}/same.ini"
_domconf_edit_ini example.com --file "${TMP}/same.ini" >/dev/null 2>&1
assert_eq "$RENDER_CALLS" "0" "içerik aynıysa render/reload yapılmaz"

echo "── Bölüm H: iskelet ve --show ──"
rm -f "$INI"
out=$(_domconf_edit_ini example.com --show 2>&1)
assert_contains "$out" "REDDEDİLEN" "--show iskeleti üretip gösterir"
assert_contains "$out" "srvctl domain reload example.com" "iskelet reload komutunu hatırlatır"

test_summary
