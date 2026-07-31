#!/bin/bash
# Tüm tests/test_*.sh dosyalarını çalıştırır.
# Kullanım: bash tests/run.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Saf yardımcılar repo içindeki conf/template'leri kullansın
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"

total_fail=0
for tf in tests/test_*.sh; do
    [[ -f "$tf" ]] || continue
    echo ""
    echo "═══ ${tf} ═══"
    bash "$tf" || total_fail=$((total_fail + 1))
done

echo ""
if [[ "$total_fail" -eq 0 ]]; then
    echo "TÜM TEST DOSYALARI GEÇTİ"
else
    echo "${total_fail} TEST DOSYASI BAŞARISIZ"
fi
exit "$total_fail"
