#!/bin/bash
# domain_exists artık validate_domain kapısından geçiyor.
#
# Eskiden domain_exists yalnız '[[ -d "${WEB_ROOT}/${domain}" ]]' idi ve
# validate_domain tüm repoda TEK yerden (_domain_add) çağrılıyordu. Sonuç:
# 'srvctl domain remove ../../var/log' → rm -rf /var/www/../../var/log.
# Kapıyı domain_exists'e koymak tüm çağrı yerlerini birden korur.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
mkdir -p "${WEB_ROOT}/alt.example.com"

# Geçerli domain'ler
assert_ok domain_exists "example.com"
assert_ok domain_exists "alt.example.com"
assert_fail domain_exists "yokboyle.com"

# ── Traversal / geçersiz girdiler: dizin GERÇEKTEN var olsa bile reddedilmeli ──
mkdir -p "${WEB_ROOT}/tuzak"
assert_fail domain_exists "../../etc"
assert_fail domain_exists "../tuzak"
assert_fail domain_exists "example.com/../../etc"
assert_fail domain_exists "/etc"
assert_fail domain_exists ".gizli"
assert_fail domain_exists ""
assert_fail domain_exists "boşluk lu.com"

# '..' içeren yol gerçekten var olsa da reddedilir (asıl regresyon)
mkdir -p "${WEB_ROOT}/../$(basename "$WEB_ROOT")/example.com" 2>/dev/null || true
assert_fail domain_exists "../$(basename "$WEB_ROOT")/example.com"

rm -rf "$WEB_ROOT"
test_summary
