#!/bin/bash
# Per-domain .ini → pool config enjeksiyonu.
#
# EN KRİTİK KİLİT: override edilen anahtar pool'da TEK KEZ görünmeli.
# Şablondan gelen satır düşürülmezse php-fpm'in çift tanımda hangi değeri
# seçtiğine bağımlı hale gelirdik (belgelenmemiş davranış).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_INI_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
id() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"
POOL="${SRVCTL_FPM_DIR}/example_com.conf"
INI="${SRVCTL_PHP_INI_DIR}/example_com.ini"

echo "── Bölüm A: .ini yokken davranış değişmez ──"
rm -f "$INI"
_domain_render_fpm_unit example.com 8.3
assert_eq "$(grep -c '^php_admin_value\[memory_limit\]' "$POOL" | tr -d ' ')" "1" \
    ".ini yokken memory_limit şablondan tek kez gelir"
assert_not_contains "$(cat "$POOL")" "per-domain override" "override başlığı basılmaz"

echo "── Bölüm B: override şablon satırını DÜŞÜRÜR ──"
printf 'memory_limit = 512M\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
pool=$(cat "$POOL")
assert_eq "$(grep -c '^php_admin_value\[memory_limit\]' "$POOL" | tr -d ' ')" "1" \
    "memory_limit pool'da TEK KEZ görünür (şablon satırı düşürüldü)"
assert_contains "$pool" "php_admin_value[memory_limit] = 512M" "override değeri yürürlükte"
assert_contains "$pool" "per-domain override" "override bloğu kendini tanıtır"

echo "── Bölüm C: noktalı anahtar (grep regex tuzağı) ──"
printf 'opcache.memory_consumption = 256\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
assert_contains "$(cat "$POOL")" "php_admin_value[opcache.memory_consumption] = 256" \
    "noktalı anahtar basılır"

echo "── Bölüm D: şablonda OLMAYAN anahtar eklenir ──"
printf 'max_file_uploads = 30\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
assert_contains "$(cat "$POOL")" "php_admin_value[max_file_uploads] = 30" \
    "şablonda olmayan anahtar eklenir"

echo "── Bölüm E: çoklu override + token kalıntısı yok ──"
printf 'memory_limit = 512M\nmax_execution_time = 120\nupload_max_filesize = 100M\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
pool=$(cat "$POOL")
assert_not_contains "$pool" "{{" "render sonrası token kalıntısı yok"
assert_eq "$(grep -c '^php_admin_value\[max_execution_time\]' "$POOL" | tr -d ' ')" "1" \
    "max_execution_time tek kez"
assert_eq "$(grep -c '^php_admin_value\[upload_max_filesize\]' "$POOL" | tr -d ' ')" "1" \
    "upload_max_filesize tek kez"

echo "── Bölüm F: bozuk .ini render'ı DURDURUR ──"
printf '[www]\n' > "$INI"
out=$( _domain_render_fpm_unit example.com 8.3 2>&1 ); rc=$?
assert_eq "$rc" "1" "geçersiz .ini → render fail-closed durur"

test_summary
