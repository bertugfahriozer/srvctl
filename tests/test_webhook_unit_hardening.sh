#!/bin/bash
# O3 regresyonu (haftalık denetim 2026-09): srvctl-webhook.service ağa açık,
# root çalışan bir bash HTTP ayrıştırıcısı için hiçbir systemd sertleştirmesi
# içermiyordu; gövde boyutu için uygulama tarafı tavan yoktu.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
WORK="$(mktemp -d)"

# systemd unit heredoc'u (SERVICE ... SERVICE)
awk '/<< SERVICE$/{f=1;next} /^SERVICE$/{f=0} f' "${REPO_ROOT}/lib/webhook.sh" > "${WORK}/unit"
UNIT="$(cat "${WORK}/unit")"
for d in NoNewPrivileges=true PrivateTmp=yes ProtectHome=read-only ProtectKernelTunables=yes \
         ProtectKernelModules=yes "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" \
         RestrictSUIDSGID=yes TasksMax=512; do
    assert_contains "$UNIT" "$d" "unit: ${d}"
done
assert_contains "$UNIT" "User=root" "unit hâlâ root (deploy gerektirir) — sertleştirme bu yüzden şart"

# Listener: 1 MiB üstü gövde 413 ile reddedilir, head -c ÇAĞRILMAZ
awk '/<< .LISTENER.$/{f=1;next} /^LISTENER$/{f=0} f' "${REPO_ROOT}/lib/webhook.sh" > "${WORK}/listener.sh"
awk '/^handle_request\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "${WORK}/listener.sh" > "${WORK}/hr.sh"
# shellcheck disable=SC1090
source "${WORK}/hr.sh"
HEAD_MARK="${WORK}/head_called"
head() { : > "$HEAD_MARK"; command head "$@"; }
out="$(printf 'POST /deploy/x HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n' | handle_request 2>/dev/null)"
assert_contains "$out" "413 Payload Too Large" "2 MB Content-Length → 413"
assert_eq "$([[ -e "$HEAD_MARK" ]] && echo 1 || echo 0)" "0" "413 yolunda gövde hiç okunmadı"

rm -rf "$WORK"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
