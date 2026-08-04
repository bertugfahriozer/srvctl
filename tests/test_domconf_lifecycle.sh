#!/bin/bash
# Yaşam döngüsü: add iskelet üretir, remove temizler, clone kopyalar.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_PHP_INI_DIR="$(mktemp -d)"
export SRVCTL_NGINX_CUSTOM_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
systemctl() { return 0; }
nginx() { return 0; }
id() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

echo "── Bölüm A: iskelet üretimi ──"
mkdir -p "${WEB_ROOT}/example.com"
_domain_provision_conf_skeletons example.com
test -f "${SRVCTL_PHP_INI_DIR}/example_com.ini"; assert_eq "$?" "0" ".ini iskeleti oluşturuldu"
test -f "${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf"; assert_eq "$?" "0" "nginx iskeleti oluşturuldu"
assert_contains "$(cat "${SRVCTL_PHP_INI_DIR}/example_com.ini")" "REDDEDİLEN" \
    ".ini iskeleti reddedilenleri anlatıyor"
assert_contains "$(cat "${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf")" "add_header" \
    "nginx iskeleti add_header tuzağını anlatıyor"

# İskelet ÜZERİNE YAZMAZ — operatörün ayarını silmek, bu özelliğin çözdüğü
# problemin ta kendisi olurdu.
printf 'memory_limit = 512M\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
printf 'client_max_body_size 99M;\n' > "${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf"
_domain_provision_conf_skeletons example.com
assert_eq "$(cat "${SRVCTL_PHP_INI_DIR}/example_com.ini")" "memory_limit = 512M" \
    "mevcut .ini ÜZERİNE YAZILMAZ"
assert_eq "$(cat "${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf")" "client_max_body_size 99M;" \
    "mevcut nginx override ÜZERİNE YAZILMAZ"

echo "── Bölüm B: temizlik ──"
_domain_purge_conf_files example.com
test -f "${SRVCTL_PHP_INI_DIR}/example_com.ini"; assert_eq "$?" "1" ".ini silindi"
test -d "${SRVCTL_NGINX_CUSTOM_DIR}/example_com"; assert_eq "$?" "1" "nginx custom dizini silindi"

# Boş/geçersiz domain adıyla çağrılırsa HİÇBİR ŞEY silmemeli (rm -rf koruması)
mkdir -p "${SRVCTL_NGINX_CUSTOM_DIR}/baska_com"
_domain_purge_conf_files "" 2>/dev/null || true
test -d "${SRVCTL_NGINX_CUSTOM_DIR}/baska_com"; assert_eq "$?" "0" \
    "boş domain adı komşu dizini SİLMEZ"

echo "── Bölüm C: klonlama ──"
mkdir -p "${WEB_ROOT}/kaynak.com" "${WEB_ROOT}/hedef.com"
_domain_provision_conf_skeletons kaynak.com
printf 'memory_limit = 777M\n' > "${SRVCTL_PHP_INI_DIR}/kaynak_com.ini"
printf 'client_max_body_size 77M;\n' > "${SRVCTL_NGINX_CUSTOM_DIR}/kaynak_com/00-custom.conf"
_domain_clone_conf_files kaynak.com hedef.com
assert_contains "$(cat "${SRVCTL_PHP_INI_DIR}/hedef_com.ini")" "memory_limit = 777M" ".ini klonlandı"
assert_contains "$(cat "${SRVCTL_NGINX_CUSTOM_DIR}/hedef_com/00-custom.conf")" "client_max_body_size 77M;" \
    "nginx override klonlandı"

# Kaynakta dosya yoksa klonlama ÇÖKMEZ
mkdir -p "${WEB_ROOT}/bos.com" "${WEB_ROOT}/bos2.com"
_domain_clone_conf_files bos.com bos2.com; assert_eq "$?" "0" "kaynakta dosya yoksa klonlama sessizce geçer"

test_summary
