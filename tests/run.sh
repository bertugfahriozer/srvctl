#!/bin/bash
# Tüm tests/test_*.sh dosyalarını çalıştırır.
# Kullanım: bash tests/run.sh
#
# DOSYA BAŞINA SÜRE SINIRI (QL9-L8): askıya düşen TEK dosya süiti kilitlemesin diye
# her test dosyası bir süre sınırıyla koşar. Sınır aşılırsa o dosya "ZAMAN AŞIMI"
# olarak raporlanır, BAŞARISIZ sayılır ve süit sonraki dosyayla devam eder.
#   SRVCTL_TEST_FILE_TIMEOUT=<sn>   varsayılan 600; 0 = sınır yok (eski davranış)
#   SRVCTL_TEST_FORCE_FALLBACK=1    GNU timeout/gtimeout olsa bile PID tabanlı düşüşü kullan (test için)
# Uygulama: GNU timeout/gtimeout varsa o; yoksa bash 3.2 uyumlu, kendi PID'imizle
# (kendi süreç grubuna alınan çocuk + bekçi) uygulanan düşüş. Hiçbir yerde pkill -f yok.
# F9b/b: düşüşteki TÜM sinyaller tests/harness_safe.sh üzerinden gider (hs_track + hs_kill_group): PID yalnız bu
# kabuğun çocuğu VE hâlâ aynı süreç (lstart/ppid) ise vurulur; PID yeniden kullanımı REDDEDİLİR (bkz. harness_safe.sh başlığı).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
source "${REPO_ROOT}/tests/harness_safe.sh" || exit 1
trap 'hs_reap KILL' EXIT

# Saf yardımcılar repo içindeki conf/template'leri kullansın
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"

TEST_DIR="${SRVCTL_TEST_DIR:-tests}"
FILE_TIMEOUT="${SRVCTL_TEST_FILE_TIMEOUT:-600}"
if [[ ! "$FILE_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "UYARI: SRVCTL_TEST_FILE_TIMEOUT='${FILE_TIMEOUT}' sayı değil -> 600 kullanılıyor" >&2
    FILE_TIMEOUT=600
fi

TIMEOUT_BIN=""
if [[ "${SRVCTL_TEST_FORCE_FALLBACK:-0}" != "1" ]]; then
    for _cand in timeout gtimeout; do
        if command -v "$_cand" >/dev/null 2>&1 && "$_cand" --version 2>/dev/null | head -1 | grep -qi 'gnu coreutils'; then
            TIMEOUT_BIN="$_cand"; break
        fi
    done
fi

# _run_limited <dosya> : rc = dosyanın rc'si; süre aşımında 124.
_run_limited() {
    local tf="$1" pid wd start rc
    if [[ "$FILE_TIMEOUT" -eq 0 ]]; then
        bash "$tf"; return $?
    fi
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" -k 10 "$FILE_TIMEOUT" bash "$tf"; return $?
    fi
    # Düşüş: çocuk ve bekçi ayrı süreç gruplarında (set -m) -> grup olarak öldürülebilir.
    start=$SECONDS
    set -m
    bash "$tf" & pid=$!; hs_track "$pid"
    ( sleep "$FILE_TIMEOUT"; hs_kill_group TERM "$pid"; sleep 5; hs_kill_group KILL "$pid" ) & wd=$!; hs_track "$wd"
    set +m
    wait "$pid" 2>/dev/null; rc=$?
    hs_kill_group TERM "$wd"
    wait "$wd" 2>/dev/null
    if [[ "$rc" -ge 128 && $((SECONDS - start)) -ge "$FILE_TIMEOUT" ]]; then
        return 124
    fi
    return "$rc"
}

total_fail=0
timed_out=""
for tf in "$TEST_DIR"/test_*.sh; do
    [[ -f "$tf" ]] || continue
    echo ""
    echo "═══ ${tf} ═══"
    _run_limited "$tf"; rc=$?
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]] && [[ "$FILE_TIMEOUT" -ne 0 ]]; then
        echo "ZAMAN AŞIMI: ${tf} ${FILE_TIMEOUT} sn içinde bitmedi (SRVCTL_TEST_FILE_TIMEOUT)" >&2
        timed_out="${timed_out}${tf}"$'\n'
        total_fail=$((total_fail + 1))
    elif [[ "$rc" -ne 0 ]]; then
        total_fail=$((total_fail + 1))
    fi
done

echo ""
if [[ -n "$timed_out" ]]; then
    echo "ZAMAN AŞIMI dosyaları:"
    while IFS= read -r _l; do [[ -n "$_l" ]] && echo "  ${_l}"; done <<< "$timed_out"
fi
if [[ "$total_fail" -eq 0 ]]; then
    echo "TÜM TEST DOSYALARI GEÇTİ"
else
    echo "${total_fail} TEST DOSYASI BAŞARISIZ"
fi
exit "$total_fail"
