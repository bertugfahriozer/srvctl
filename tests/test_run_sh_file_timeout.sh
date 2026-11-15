#!/bin/bash
# tests/run.sh dosya başına süre sınırı (QL9-L8): askıdaki tek dosya süiti kilitlemez,
# "ZAMAN AŞIMI" olarak raporlanır, başarısız sayılır, süit devam eder. Üç yol:
# GNU timeout/gtimeout, PID tabanlı düşüş (SRVCTL_TEST_FORCE_FALLBACK=1), sınırsız (=0).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/t"
printf '#!/bin/bash\necho ok-file\nexit 0\n' > "$W/t/test_a_ok.sh"
printf '#!/bin/bash\n( sleep 120 ) \nsleep 120\n' > "$W/t/test_b_hang.sh"
printf '#!/bin/bash\necho after-hang-ran\nexit 0\n' > "$W/t/test_c_after.sh"

_run_suite() {   # <fallback 0|1> <timeout sn> -> $OUT, $RC, $ELAPSED
    local s=$SECONDS
    OUT="$(SRVCTL_TEST_DIR="$W/t" SRVCTL_TEST_FILE_TIMEOUT="$2" SRVCTL_TEST_FORCE_FALLBACK="$1" \
           bash "${REPO_ROOT}/tests/run.sh" 2>&1)"; RC=$?
    ELAPSED=$((SECONDS - s))
}

for fb in 0 1; do
    lbl="$([[ $fb == 1 ]] && echo 'düşüş(PID)' || echo 'GNU timeout')"
    _run_suite "$fb" 2
    assert_contains "$OUT" "ZAMAN AŞIMI: ${W}/t/test_b_hang.sh" "[$lbl] askıdaki dosya ZAMAN AŞIMI olarak raporlanır"
    assert_contains "$OUT" "after-hang-ran" "[$lbl] askıdan SONRAKİ dosya yine koşar (süit kilitlenmez)"
    assert_eq "$RC" "1" "[$lbl] yalnız askıdaki dosya başarısız sayılır (rc 1)"
    assert_eq "$([[ $ELAPSED -lt 30 ]] && echo hizli || echo "yavas:${ELAPSED}")" "hizli" "[$lbl] 120 sn'lik askı ~2 sn sınırında kesilir"
done
test_summary
