#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça f_3/12: B2 (hedef both) / B3 / B4 / B5 / B6
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
# ═══ B. yarım-işlem yedeği (manifest 'on'): yedekteki 90/21 de kayıtlı özetle eşleşmeli; eşleşmezse GERİ YÜKLENMEZ ═══
# B2: yollar — MEVCUT disk tanınan açık (üçü), yedek (kesintiden kalma) 90/21 bozuk → yedek ayrılır, açık durum diskte korunur  (hedef both; 90 _f, 21 _f_2)
B2_HEDEF="both"
for t in $B2_HEDEF; do
    for v in missing tamper unknown unrecorded; do
        for path in fmroot fmrootall repair84 repairall; do
            reset_all; _on; _mk_stale_bk AAAAAA; bk_mut "$t" "$v"
            runpath "$path"
            assert_eq "$(_bkn)|$(_supn)" "0|1" "B2 [${t}/${v} / ${path}]: yedekte ${t} ${v}: yedek GERİ YÜKLENMEDİ, adli olarak ayrıldı"
            assert_eq "$(_st)|$(_exists "$F90")$(_exists "$F21")" "on|varvar" "B2 [${t}/${v} / ${path}]: mevcut disk üçü de tanınan açıktı: bakım açık durumu korur"
        done
    done
done
# B3: yedek 90/21 bozuk + MEVCUT disk de bozuk (kayıt on) → ne yedek geri yüklenir ne alan açılır
for path in fmroot repair84 fmrootall; do
    reset_all; _on; _mk_stale_bk AAAAAA; bk_mut 90 tamper; rm -f "$F21"; fm_sim_reload
    runpath "$path"
    assert_eq "$(_shut)|$(_st)|$(_run)|$(_bkn)|$(_supn)" "SHUT|off|RUN-CLOSED|0|1" "B3 [${path}]: yedek 90 kurcalanmış + mevcut 21 eksik: yedek ayrıldı, alan kapatıldı"
done
# B4: kuru plan (fm-root bayraksız) geri yüklenmeyecek yedeği ve nedenini söyler, hiçbir şey yazmaz
reset_all; _on; _mk_stale_bk AAAAAA; bk_mut 21 tamper
out=$( ( _domconf_fm_root_cmd example.com ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "ön durum tanınan bir srvctl eseri değil" "B4 kuru plan (yedek 21 kurcalanmış): yedeğin geri yüklenmeyeceğini söyler"
assert_eq "$(_bkn)|$(_supn)" "1|0" "B4 kuru plan: hiçbir şey yazmaz (yedek yerinde)"
# B5: kontrol — yedek üç eser de tanınan açık ve MEVCUT disk de tanınan açık: yedek geri yüklenir, açık durum korunur
reset_all; _on; _mk_stale_bk AAAAAA; _fmroot
assert_eq "$(_bkn)|$(_supn)|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_shut)" "0|0|varvar|on|OPEN" "B5 kontrol: yedek ve disk üçü de tanınan açık: yedek geri yüklenir, açık durum korunur"
# B6: yedek üçü de tanınan ama MEVCUT disk (kesintiye uğrayan yazım) 90'ı kurcalanmış: kayıt off sayılır → yedek geri yüklenmez, alan KAPANIR
for path in fmroot repair84; do
    reset_all; _on; _mk_stale_bk AAAAAA; printf '# yarim\n' >> "$F90"; fm_sim_reload
    runpath "$path"
    assert_eq "$(_bkn)|$(_supn)|$(_shut)|$(_st)|$(_run)" "0|1|SHUT|off|RUN-CLOSED" "B6 [${path}]: mevcut disk 90 kurcalanmış (sınıf 4): sağlam yedek bile alanı AÇIK geri koymaz, alan kapanır"
done

test_summary
