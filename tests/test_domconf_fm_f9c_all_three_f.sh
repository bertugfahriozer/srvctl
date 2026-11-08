#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça f/12: B1/B1b/B1c yedek birimleri + B2 (hedef 90)
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
# (bk_mut: tests/fm_f9c_common.sh)
BVARS="missing tamper symlink badowner mode666 unknown empty hardlink unrecorded"
for t in $TARGETS; do
    for v in $BVARS; do
        # B1: birim — yedekte 20 tanınan açık ama 90/21 bozuk: geri yüklenemez
        reset_all; _on; _mk_stale_bk AAAAAA; bk_mut "$t" "$v"
        _fmprov_bk_restore_allowed "${SD}/.bk.example_com.AAAAAA" example_com; brc=$?
        assert_eq "$brc" "1" "B1 [${t}/${v}]: _fmprov_bk_restore_allowed: yedekte 20 tanınan açık + ${t} ${v} → geri yüklenemez (rc 1)"
        MOCK_BAD_OWNER=""
    done
done
# B1b: birim — yedekte 20 tanınmıyor (90/21 tanınan): geri yüklenemez; yedekte 20 = tanınan kapalı kök + 90/21 (on manifest) geri yüklenemez
for v in missing tamper symlink unknown empty unrecorded; do
    reset_all; _on; _mk_stale_bk AAAAAA; bk20="${SD}/.bk.example_com.AAAAAA/20-srvctl-fm-upload.conf"
    mutf "$bk20" "20-srvctl-fm-upload.conf" "${SD}/.bk.example_com.AAAAAA/manifest" "$v"
    _fmprov_bk_restore_allowed "${SD}/.bk.example_com.AAAAAA" example_com; brc=$?
    assert_eq "$brc" "1" "B1b [20/${v}]: yedekte 20 tanınmıyor (90/21 tanınan): geri yüklenemez (rc 1)"
done
reset_all; _on; _mk_stale_bk AAAAAA; _domconf_fm_render_off example_com > "${SD}/.bk.example_com.AAAAAA/20-srvctl-fm-upload.conf"; chmod 644 "${SD}/.bk.example_com.AAAAAA/20-srvctl-fm-upload.conf"
printf 'sha256 %s %s\n' "$(_domconf_sha256_file "${SD}/.bk.example_com.AAAAAA/20-srvctl-fm-upload.conf")" "20-srvctl-fm-upload.conf" >> "${SD}/.bk.example_com.AAAAAA/manifest"
_fmprov_bk_restore_allowed "${SD}/.bk.example_com.AAAAAA" example_com; brc=$?
assert_eq "$brc" "1" "B1b [20/closed_root]: yedekte 20 = kapalı kök + 90/21 (on manifest): geri yüklenemez (rc 1)"
# B1c: kontrol birimi — yedekte üç eser de tanınan açık: geri yüklenebilir (rc 0)
reset_all; _on; _mk_stale_bk AAAAAA
_fmprov_bk_restore_allowed "${SD}/.bk.example_com.AAAAAA" example_com; brc=$?
assert_eq "$brc" "0" "B1c kontrol: yedekte üç eser de tanınan açık: geri yüklenebilir (rc 0)"
# B2: yollar — MEVCUT disk tanınan açık (üçü), yedek (kesintiden kalma) 90/21 bozuk → yedek ayrılır, açık durum diskte korunur  (hedef 90; kalanı _f_2 ve _f_3)
B2_HEDEF="90"
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

test_summary
