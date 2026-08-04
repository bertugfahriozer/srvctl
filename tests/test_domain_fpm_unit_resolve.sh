#!/bin/bash
# domain_fpm_unit / reload_domain_fpm — hangi unit hedefleniyor ve reload
# başarısızlığı fail-closed mı?
#
# KÖK NEDEN (bkz. lib/deploy.sh:_deploy_reload_fpm host bulgusu): izole FPM'li
# bir kurulumda paylaşılan php<ver>-fpm servisi havuzsuz kaldığı için BİLEREK
# durdurulmuştur. Yanlış unit'i reload etmek sessizce başarısız olur ve
# opcache.validate_timestamps=0 yüzünden site SÜRESİZ eski bytecode servis eder.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

# ─── systemctl mock ───
# MOCK_ISOLATED=1 → izole unit systemd'ye kayıtlı görünür
# MOCK_RELOAD_RC / MOCK_RESTART_RC / MOCK_ACTIVE_RC → ilgili alt komutun rc'si
MOCK_ISOLATED=0; MOCK_RELOAD_RC=0; MOCK_RESTART_RC=0; MOCK_ACTIVE_RC=0
systemctl() {
    case "$1" in
        list-units)
            [[ "$MOCK_ISOLATED" == "1" ]] && echo "srvctl-fpm-example_com.service loaded active running"
            return 0 ;;
        reload)  return "$MOCK_RELOAD_RC" ;;
        restart) return "$MOCK_RESTART_RC" ;;
        is-active) return "$MOCK_ACTIVE_RC" ;;
    esac
    return 0
}

echo "── Bölüm A: unit çözümleme ──"
MOCK_ISOLATED=1
assert_eq "$(domain_fpm_unit example_com 8.3)" "srvctl-fpm-example_com.service" \
    "izole unit kayıtlıysa o seçilir"
MOCK_ISOLATED=0
assert_eq "$(domain_fpm_unit example_com 8.3)" "php8.3-fpm" \
    "izole unit yoksa paylaşılan servise düşer"

echo "── Bölüm B: reload fail-closed ──"
MOCK_ISOLATED=1; MOCK_RELOAD_RC=0; MOCK_ACTIVE_RC=0
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "reload başarılı + aktif → 0"

MOCK_RELOAD_RC=1; MOCK_RESTART_RC=0; MOCK_ACTIVE_RC=0
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "reload başarısız → restart kurtarır → 0"

MOCK_RELOAD_RC=1; MOCK_RESTART_RC=1
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reload+restart başarısız → 1"

# EN KRİTİK: reload 0 döner ama servis AKTİF DEĞİL (sessiz başarısızlık).
# Bu tam olarak 'süresiz eski bytecode' senaryosu — restart'a düşülmeli.
MOCK_RELOAD_RC=0; MOCK_ACTIVE_RC=1; MOCK_RESTART_RC=1
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reload rc=0 ama is-active başarısız → 1"

test_summary
