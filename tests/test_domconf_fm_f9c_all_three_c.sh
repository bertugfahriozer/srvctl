#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça c/6: A (hedef 21 x varyant x yol)
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
A_TARGETS="21"
# ═══ A. hedef x varyant x yol: hiçbir otomatik yol bozulan 21/90 için sessiz yeniden üretmez: 403 kökü, 90/21 yok, kayıt off, çalışan KAPALI ═══
for t in $A_TARGETS; do
    for v in $AVARS; do
        for path in $PATHS; do
            reset_all; _on; apply_target "$t" "$v"
            runpath "$path"
            assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "A [${t}/${v} / ${path}]: 20 tanınan açık + ${t} ${v}: 403 kökü yazıldı, 90/21 yok, kayıt off, çalışan KAPALI (sessiz yeniden üretim YOK)"
            MOCK_BAD_OWNER=""
        done
    done
done
test_summary
