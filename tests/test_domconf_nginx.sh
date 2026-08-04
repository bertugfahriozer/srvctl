#!/bin/bash
# 'domain nginx' — reddedilen direktifler, include ÖN KOŞUL kapısı, rollback.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_NGINX_CUSTOM_DIR="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"
log_action() { :; }
send_notification() { :; }
mkdir -p "${WEB_ROOT}/example.com"

NGINX_TEST_RC=0
nginx() { [[ "$1" == "-t" ]] && return "$NGINX_TEST_RC"; return 0; }
systemctl() { return 0; }
source "${REPO_ROOT}/lib/domconf.sh"

CUSTOM="${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf"
VHOST="${SITES_AVAILABLE}/example.com.conf"
TMP="$(mktemp -d)"

echo "── Bölüm A: reddedilen direktifler ──"
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    printf '%b' "$payload" > "${TMP}/scan.conf"
    _domconf_scan_nginx "${TMP}/scan.conf" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "$desc"
done <<'CASES'
fastcgi_pass unix:/run/php/other.sock;\n|fastcgi_pass reddedilir (domainler arası izolasyon)
root /etc/passwd;\n|root reddedilir
alias /root/;\n|alias reddedilir
server_name evil.com;\n|server_name reddedilir
listen 8080;\n|listen reddedilir
disable_symlinks off;\n|disable_symlinks reddedilir
modsecurity off;\n|modsecurity reddedilir
modsecurity_rules_file /dev/null;\n|modsecurity_rules_file reddedilir
fastcgi_param PHP_ADMIN_VALUE "open_basedir=";\n|fastcgi_param PHP_ADMIN_VALUE reddedilir (open_basedir boşaltma)
fastcgi_param PHP_VALUE "memory_limit=9G";\n|fastcgi_param PHP_VALUE reddedilir
    root /tmp;\n|girintili direktif de yakalanır
CASES

echo "── Bölüm B: serbest bırakılanlar ──"
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    printf '%b' "$payload" > "${TMP}/scan.conf"
    _domconf_scan_nginx "${TMP}/scan.conf" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "0" "$desc"
done <<'CASES'
client_max_body_size 100M;\n|client_max_body_size serbest
location /api/ {\n    proxy_pass http://127.0.0.1:3000;\n}\n|proxy_pass BİLİNÇLİ olarak serbest
# root /etc/passwd;\n|yorum içindeki direktif yakalanmaz
    fastcgi_param SCRIPT_FILENAME $doc;\n|masum fastcgi_param serbest
location /uzun/ {\n    fastcgi_read_timeout 300s;\n}\n|fastcgi_read_timeout serbest
CASES

printf 'root /tmp;\n' > "${TMP}/scan.conf"
out=$(_domconf_scan_nginx "${TMP}/scan.conf" 2>&1 || true)
assert_contains "$out" "satır 1" "bulgu satır numarasıyla raporlanır"
assert_contains "$out" "chroot" "gerekçe metni gösterilir"

echo "── Bölüm C: include ÖN KOŞUL kapısı ──"
printf 'server {\n    listen 80;\n}\n' > "$VHOST"
printf 'client_max_body_size 100M;\n' > "${TMP}/new.conf"
out=$( _domconf_edit_nginx example.com --file "${TMP}/new.conf" 2>&1 ); rc=$?
assert_eq "$rc" "1" "vhost'ta include yoksa fail-closed durur"
assert_contains "$out" "repair" "kurtarma yolu (domain repair) önerilir"

echo "── Bölüm D: include varken uygulanır ──"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
_domconf_edit_nginx example.com --file "${TMP}/new.conf" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "include varsa uygulanır"
assert_contains "$(cat "$CUSTOM")" "client_max_body_size 100M;" "içerik yazıldı"

echo "── Bölüm E: rollback ──"
cp "$CUSTOM" "${TMP}/before.conf"
NGINX_TEST_RC=1
printf 'client_max_body_size 200M;\n' > "${TMP}/next.conf"
( _domconf_edit_nginx example.com --file "${TMP}/next.conf" ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "nginx -t başarısız → exit 1"
assert_eq "$(cat "$CUSTOM")" "$(cat "${TMP}/before.conf")" "rollback: dosya eski halinde"
NGINX_TEST_RC=0

echo "── Bölüm F: --force ──"
printf 'root /tmp;\n' > "${TMP}/bad.conf"
cp "$CUSTOM" "${TMP}/before.conf"
( _domconf_edit_nginx example.com --file "${TMP}/bad.conf" ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reddedilen direktif → exit 1"
assert_eq "$(cat "$CUSTOM")" "$(cat "${TMP}/before.conf")" "reddedilince dosya DEĞİŞMEDİ"
_domconf_edit_nginx example.com --file "${TMP}/bad.conf" --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--force geçer"
assert_contains "$(cat "$CUSTOM")" "root /tmp;" "--force içeriği yazdı"

echo "── Bölüm G: iskelet ve --show ──"
rm -rf "${SRVCTL_NGINX_CUSTOM_DIR}/example_com"
out=$(_domconf_edit_nginx example.com --show 2>&1)
assert_contains "$out" "add_header" "iskelet add_header tuzağını anlatır"
assert_contains "$out" "REDDEDİLEN" "iskelet reddedilen direktifleri listeler"

echo "── Bölüm H: değişiklik yoksa reload yapılmaz ──"
cp "$CUSTOM" "${TMP}/same.conf"
out=$(_domconf_edit_nginx example.com --file "${TMP}/same.conf" 2>&1); rc=$?
assert_eq "$rc" "0" "aynı içerik → 0"
assert_contains "$out" "Değişiklik yok" "değişiklik olmadığı bildirilir"

test_summary
