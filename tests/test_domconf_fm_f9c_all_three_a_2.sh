#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça a_2/12: A6 dizin sınırı, G çökme penceresi
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
# ═══ A6. BİLİNEN SINIR: 90/21 yerinde DİZİN (isdir). Aşama yedeği `cp -pP` dizini kopyalayamaz → yazım reddedilir, işlem geri alınır:
#     kapatma YAPILAMAZ (önceki durum aynen kalır, çalışan nginx de bir dizini include edemez), ama ALAN YENİDEN AÇILMAZ / yeniden ÜRETİLMEZ,
#     rc ≠ 0 (provision/repair/php-switch/fm-root hepsi yüksek sesle başarısız; toplu repair adımı da). Eski F9b'de 20=dizin için aynıydı. ═══
for t in $TARGETS; do
    for path in fmroot fmrootall repair83 repair84 repairall phpswitch provision; do
        reset_all; _on; apply_target "$t" isdir; m20=$(_md5 "$F20")
        runpath "$path"; rc=$?
        assert_eq "$((rc != 0))|$(_st)|$(_md5 "$F20")" "1|on|${m20}" "A6 [${t}/isdir / ${path}]: dizin: kapatma yapılamaz AMA yüksek sesle rc≠0, 20 değişmedi, yeniden üretim/açma yok"
    done
done

# ═══ G. çökme penceresi: kayıt (on: yeni 90/21/20-açık + ESKİ kapalı kök özeti), diskte 90/21 yazılmış, 20 hâlâ ESKİ kapalı kök: açık eser SAYILMAZ ═══
for path in $PATHS; do
    reset_all; _on
    cp -p "$F90" "${FM_STUBS}/s90"; cp -p "$F21" "${FM_STUBS}/s21"; cp -p "$MAN" "${FM_STUBS}/sman"
    ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1
    cp -p "${FM_STUBS}/s90" "$F90"; cp -p "${FM_STUBS}/s21" "$F21"
    h20=$(_domconf_sha256_file "$F20")
    cp -p "${FM_STUBS}/sman" "$MAN"; printf 'sha256 %s %s\n' "$h20" "20-srvctl-fm-upload.conf" >> "$MAN"
    fm_sim_reload; _fmprov_load example_com; pre="$_FMP_STATE|$_FMP_EMERGENCY"
    runpath "$path"
    assert_eq "$pre|$(_shut)|$(_st)|$(_run)" "off|4|SHUT|off|RUN-CLOSED" "G [${path}]: çökme penceresi (kayıttaki ESKİ kapalı kök özeti açık eser SAYILMAZ; 90/21 tanınan olsa da): alan AÇILMADI"
done

test_summary
