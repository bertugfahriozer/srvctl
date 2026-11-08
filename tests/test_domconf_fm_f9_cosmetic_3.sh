#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9/a1 (qalab9-I2) — kayıt 'on' + kozmetik bozuk ama srvctl adlı kapalı kök: 8 yolun HİÇBİRİ alanı AÇMAZ (mock; gerçek nginx: test_domconf_fm_f9_real.sh). Parça 3/4: I2 döngüsü (wstabbody wsmulti wsquote x sekiz yol).
# (Diğer F9 testleri: test_domconf_fm_f9_closure.sh.)
# Eski tek dosya (136 satır) yük altında 300 sn'yi aştığı için dört dosyaya bölündü (hiçbir doğrulama silinmedi ya da gevşetilmedi); ortak düzenek: tests/fm_f9_cosmetic_common.sh. Parçalar: (ad yok) I2 döngüsü crlf/trailing/mode664, _2 hardlink/wstab/wstab1, _3 wstabbody/wsmulti/wsquote, _4 ikinci I2 döngüsü + kontroller + status.
#  I2    kayıt `on` + kozmetik bozuk ama srvctl adlı kapalı kök (CRLF, mod 664, sondaki boşluk, sert bağ …): 8 yolun HİÇBİRİ alanı AÇMAZ;
#        status kurcalama raporlar, 'fm-root --apply' önermez
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9_cosmetic_common.sh"
COS_V1="wstabbody wsmulti wsquote"
for v in $COS_V1; do
    for path in $ALLP; do
        reset_all; _on; MOCK_BAD_OWNER=""
        case "$path" in stalebk_*) _mk_stale_bk AAAAAA ;; esac
        cosmetic "$v"
        _fmprov_load example_com; evv="$_FMP_STATE|$_FMP_EMERGENCY"
        runpath "$path"
        assert_eq "$evv|$(_sh)|$(_run)|$(_exists "$F90")$(_exists "$F21")" "off|3|SHUT|RUN-CLOSED|yokyok" "I2 [${v} / ${path}]: kozmetik bozuk kapalı kök: alan AÇILMADI (QL9 qalab: 6/8 yol 90/21+AÇIK yazdı)"
        rm -f "${F20}.hard"; MOCK_BAD_OWNER=""
    done
done
test_summary
