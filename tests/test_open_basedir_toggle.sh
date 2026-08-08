#!/bin/bash
# 'srvctl domain open-basedir <domain> off' — open_basedir'i pool'dan KALDIRMA.
#
# EN KRİTİK KİLİTLER:
#  1) VARSAYILAN DEĞİŞMEMELİ: .ini yokken pool bugünküyle birebir aynı kalmalı
#     (open_basedir satırı YERİNDE). Bu komut opt-in'dir.
#  2) 'off' ASLA LİTERAL BASILMAMALI: 'php_admin_value[open_basedir] = off'
#     yazılsaydı PHP bunu 'off' ADLI GÖRECELİ BİR DİZİN sanar ve domainin TÜM
#     dosya erişimini kırardı. Kaldırmanın tek doğru yolu satırı HİÇ basmamak.
#  3) 'off' DIŞINDAKİ open_basedir değerleri REDDEDİLMEYE devam etmeli —
#     o gerçek bir gevşetmedir, 'off' ise sınırı chroot'a bırakan bir kaldırma.
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
source "${REPO_ROOT}/lib/domconf.sh"

mkdir -p "${WEB_ROOT}/example.com"
POOL="${SRVCTL_FPM_DIR}/example_com.conf"
INI="${SRVCTL_PHP_INI_DIR}/example_com.ini"

echo "── Bölüm A: VARSAYILAN — .ini yokken open_basedir YERİNDE ──"
rm -f "$INI"
_domain_render_fpm_unit example.com 8.3
assert_eq "$(grep -c '^php_admin_value\[open_basedir\]' "$POOL" | tr -d ' ')" "1" \
    "opt-in: .ini yokken open_basedir şablondan gelir (varsayılan değişmedi)"
assert_contains "$(cat "$POOL")" "/public_html/:/private/" "şablon listesi olduğu gibi"

echo "── Bölüm B: 'off' → satır pool'dan TAMAMEN kalkar ──"
printf 'open_basedir = off\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
pool=$(cat "$POOL")
assert_eq "$(grep -c '^php_admin_value\[open_basedir\]' "$POOL" | tr -d ' ')" "0" \
    "open_basedir satırı pool'da HİÇ yok"

echo "── Bölüm C: 'off' ASLA literal basılmaz ('off' adlı dizin tuzağı) ──"
assert_not_contains "$pool" "open_basedir] = off" "literal 'off' değeri basılmadı"
assert_not_contains "$pool" "open_basedir] = none" "literal 'none' de basılmadı"

echo "── Bölüm D: yalnız 'off' varken boş override bloğu basılmaz ──"
assert_not_contains "$pool" "per-domain override" "basılacak satır kalmayınca başlık da basılmaz"

echo "── Bölüm E: 'off' + başka override birlikte çalışır ──"
printf 'open_basedir = off\nmemory_limit = 512M\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
pool=$(cat "$POOL")
assert_eq "$(grep -c '^php_admin_value\[open_basedir\]' "$POOL" | tr -d ' ')" "0" \
    "open_basedir yine kaldırıldı"
assert_contains "$pool" "php_admin_value[memory_limit] = 512M" "diğer override etkilenmedi"
assert_contains "$pool" "per-domain override" "basılacak satır varsa başlık basılır"
assert_not_contains "$pool" "{{" "token kalıntısı yok"

echo "── Bölüm F: 'on'a dönüş — satır geri gelir ──"
printf 'memory_limit = 512M\n' > "$INI"
_domain_render_fpm_unit example.com 8.3
assert_eq "$(grep -c '^php_admin_value\[open_basedir\]' "$POOL" | tr -d ' ')" "1" \
    "beyan kalkınca şablon satırı geri gelir (geri alınabilir)"

echo "── Bölüm G: deny taraması — 'off' --force İSTEMEZ ──"
printf 'open_basedir = off\n' > "$INI"
assert_ok _domconf_scan_ini "$INI" "'open_basedir = off' temiz sayılır"

echo "── Bölüm H: deny taraması — GEVŞETME hâlâ reddedilir ──"
printf 'open_basedir = /public_html/:/etc/\n' > "$INI"
assert_fail _domconf_scan_ini "$INI" "başka bir open_basedir değeri reddedilir"
printf 'open_basedir = off extra\n' > "$INI"
assert_fail _domconf_scan_ini "$INI" "'off' benzeri ama farklı değer reddedilir"
printf 'disable_functions = \n' > "$INI"
assert_fail _domconf_scan_ini "$INI" "diğer deny anahtarları etkilenmedi"

echo "── Bölüm I: durum sorgusu ──"
printf 'open_basedir = off\n' > "$INI"
assert_ok _domconf_open_basedir_is_off "$INI" "'off' beyanı algılanır"
printf 'memory_limit = 512M\n' > "$INI"
assert_fail _domconf_open_basedir_is_off "$INI" "beyan yokken 'on' sayılır"
rm -f "$INI"
assert_fail _domconf_open_basedir_is_off "$INI" ".ini hiç yokken 'on' sayılır"

test_summary
