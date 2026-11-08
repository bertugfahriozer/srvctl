#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça e_3/12: A2 (karışık) / A3 (üçü birden) / A4 (idempotent)
# Eski tek dosya (test_domconf_fm_f9c_all_three.sh, 677 doğrulama, tam süitte >600 sn) 6 bağımsız dosyaya, sonra yük altında 300 sn'yi aşan a/e/f 12 dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f9c_common.sh. Parçalar: _a (P/A5), _a_2 (A6/G), _a_3 (C/E/R), _b (A[90]+D), _c (A[21]), _d (A[both]), _e (A1b: ilk 5 varyant), _e_2 (A1b: kalan 5 varyant), _e_3 (A2/A3/A4), _f (B1/B1b/B1c + B2[90]), _f_2 (B2[21]), _f_3 (B2[both] + B3..B6).
# İlkenin açıklaması (üçü de tanınmalı; sınıf 4 yolları): test_domconf_fm_f9c_all_three_a.sh başlığında.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"
# A2: karışık bozulmalar x her yol
for combo in "missing:tamper" "tamper:symlink" "badowner:missing"; do
    for path in $PATHS; do
        reset_all; _on
        mutf "$F90" "$N90" "$MAN" "${combo%%:*}"; mutf "$F21" "$N21" "$MAN" "${combo##*:}"; fm_sim_reload
        runpath "$path"
        assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "A2 [90=${combo%%:*}/21=${combo##*:} / ${path}]: karışık bozulma: kapatıldı"
        MOCK_BAD_OWNER=""
    done
done
# A3: 20 de bozuk + 21/90 bozuk (üçü birden): kapatma
for path in $PATHS; do
    reset_all; _on; printf '# kurcalandi\n' >> "$F20"; rm -f "$F21"; printf '# kurcalandi\n' >> "$F90"; fm_sim_reload
    runpath "$path"
    assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "A3 [20+21+90 bozuk / ${path}]: üçü birden bozuk: kapatıldı"
done
# A4: kapatılan alanda yeniden repair/fm-root idempotent: yeniden AÇMAZ, sağlam KAPALI der
reset_all; _on; apply_target 90 missing; _fmroot; _repair 8.4; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "0|SHUT|off" "A4: kapatılan alanda tekrar repair idempotent (yeniden AÇMAZ)"
out=$( ( _domconf_fm_root_cmd example.com ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "sağlam: KAPALI" "A4: kapatıldıktan sonra fm-root planı 'sağlam: KAPALI' der"

test_summary
