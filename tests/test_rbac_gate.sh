#!/bin/bash
# Y1 regresyonu (haftalık denetim 2026-09): sudoers 'domain info *' joker'i
# '--show-secrets'i de geçiriyordu (fnmatch '*' boşluk dahil eşleşir) ve
# 'user grant' ile yazılan DOMAINS= alanı hiçbir yerde okunmuyordu.
# Gerçek kapı artık CLI'da: require_role / require_domain_grant (core.sh).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_USERS_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

printf 'ROLE=viewer\nDOMAINS=\n'                 > "${SRVCTL_USERS_DIR}/vw.conf"
printf 'ROLE=developer\nDOMAINS=a.com,b.com\n'   > "${SRVCTL_USERS_DIR}/dv.conf"
printf 'ROLE=admin\nDOMAINS=\n'                  > "${SRVCTL_USERS_DIR}/ad.conf"

_as() { local u="$1"; shift; ( SUDO_USER="$u" "$@" ) 2>&1; }

# ── doğrudan root (SUDO_USER yok/root): her şey serbest ──
assert_ok  bash -c 'unset SUDO_USER; source '"$REPO_ROOT"'/lib/core.sh; log_action(){ :;}; require_role admin'
assert_ok  _as root require_role admin
assert_ok  _as root require_domain_grant x.com

# ── require_role ──
assert_ok   _as ad require_role admin
assert_fail _as vw require_role admin
assert_fail _as dv require_role admin
assert_ok   _as dv require_role admin developer
out=$(_as vw require_role admin)
assert_contains "$out" "Yetki yok" "viewer → admin gerektiren işlem reddedilir"
assert_contains "$out" "rol=viewer" "mesaj çağıranın rolünü söyler"

# ── require_domain_grant ──
assert_ok   _as dv require_domain_grant a.com
assert_ok   _as dv require_domain_grant b.com
assert_fail _as dv require_domain_grant c.com
assert_fail _as dv require_domain_grant "a.co"            # önek eşleşmesi YOK
assert_fail _as dv require_domain_grant "(tüm domainler)"  # kısıtlı kullanıcı 'hepsi'ni alamaz
assert_ok   _as vw require_domain_grant c.com             # boş DOMAINS = tümü (geriye uyumlu)
assert_ok   _as ad require_domain_grant c.com             # admin her zaman
out=$(_as dv require_domain_grant c.com)
assert_contains "$out" "c.com" "reddedilen domain mesajda"

# ── bilinmeyen / geçersiz SUDO_USER: conf yok → rol tanımsız → reddedilir ──
assert_fail _as yok_kullanici require_role admin
assert_fail _as "../../etc/passwd" require_role admin
assert_fail _as "../../etc/passwd" require_domain_grant a.com

# ── _domain_info kapısının yerinde olduğunu yapısal doğrula ──
src="$(cat "${REPO_ROOT}/lib/domain.sh")"
assert_contains "$src" '[[ "$show_secrets" == "1" ]] && require_role admin' "domain info --show-secrets → require_role admin"
assert_contains "$(cat "${REPO_ROOT}/lib/deploy.sh")" 'require_domain_grant "$1"; _deploy_run' "deploy <domain> → require_domain_grant"
assert_contains "$(cat "${REPO_ROOT}/lib/backup.sh")" 'require_domain_grant "${2:-(tüm domainler)}"' "backup run → require_domain_grant"

rm -rf "$SRVCTL_USERS_DIR"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
