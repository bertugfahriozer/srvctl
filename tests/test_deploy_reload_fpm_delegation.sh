#!/bin/bash
# _deploy_reload_fpm artık core.sh'a delege ediyor — SÖZLEŞMESİ değişmedi:
# (php_version, sname) alır ve başarısızlıkta error ile EXIT eder.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

MOCK_RC=0
reload_domain_fpm() { return "$MOCK_RC"; }
domain_fpm_unit() { echo "srvctl-fpm-$1.service"; }
source "${REPO_ROOT}/lib/deploy.sh"

# Her iki çağrı da ALT KABUKTA: 'error' exit eder, delegasyon bozuksa test
# scriptinin kendisi ölür ve hangi assert'in patladığı görünmez olurdu.
MOCK_RC=0
out=$( _deploy_reload_fpm 8.3 example_com 2>&1 ); rc=$?
assert_eq "$rc" "0" "reload_domain_fpm 0 → başarılı"

# error exit ettiği için alt kabukta koş
MOCK_RC=1
out=$( _deploy_reload_fpm 8.3 example_com 2>&1 ); rc=$?
assert_eq "$rc" "1" "reload_domain_fpm 1 → exit 1 (fail-closed)"
assert_contains "$out" "ÇALIŞMIYOR OLABİLİR" "operatöre manuel müdahale yönlendirmesi veriliyor"

test_summary
