#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9d/dev (parça a/2: ÇEKİRDEK matris; B-G: test_domconf_fm_f9d_double_bk_more.sh) — ARCHITECTURE §15/43(b): bir alanda >=2 yarım-işlem yedeği (.bk.*) varsa kurtarma YAPILMAZ (hangisinin doğru olduğu bilinemez)
# AMA alan AÇIK BIRAKILMAZ: §15/38 ile hizalı olarak kayıt `off` sayılır ve alan 403 köküne KAPATILIR; İKİ YEDEK DOKUNULMADAN korunur
# (içerik/md5 aynı, silinmez/taşınmaz/ayrılmaz/yeniden adlandırılmaz); rc≠0 ve "elle inceleyin". Eski ağaçta (d0de1c0e) bu durumda alan
# kapatılmaz ve açılmaz (GÖZLEM-ÇİFT-YEDEK): 2 yedek + açık alan => alan AÇIK kalırdı. Kapsam: yarım-işlem kurtarmasına giren her yol
# (repair 8.3/8.4, toplu repair, fm-root, fm-root --all, php-switch [soket yazacağı zaman], provision) + status (salt-okur).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

source "${REPO_ROOT}/tests/fm_f9d_double_bk_common.sh"

# ═══ A. ÇEKİRDEK: 2 yedek -> HER yol alanı KAPATIR, yedekler DOKUNULMADAN kalır, rc≠0, "elle inceleyin" ═══
for sc in K0 K4_90 K4_21 K4_20 KOFF_OPENDISK KNOREC_EMPTY KNOREC_OPEN; do
    for path in repair83 repair84 repairall fmroot fmrootall phpswitch provision; do
        if [[ "$path" == phpswitch ]] && ! phpswitch_enters "$sc"; then continue; fi
        setup "$sc"; s0=$(snap)
        runpath "$path"; rc=$?; out=$(strip < "$OUTF")
        assert_eq "$((rc != 0))|$(snap)" "1|${s0}" "A [${sc} / ${path}]: rc≠0 ve iki yedek BAYT BAYT aynı (md5/mod/ad; silinmedi, taşınmadı, ayrılmadı)"
        assert_eq "$(_bkn)|$(_supn)" "2|0" "A [${sc} / ${path}]: .bk sayısı 2, .superseded 0 (geçici kapatma yedeği sızmadı)"
        assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "A [${sc} / ${path}]: alan KAPATILDI (diskte 403 kökü, 90/21 yok, kayıt off, çalışan nginx KAPALI)"
        assert_contains "$out" "elle inceleyin" "A [${sc} / ${path}]: 'elle inceleyin' denir"
        assert_contains "$out" "KAPATILDI" "A [${sc} / ${path}]: ileti alanın KAPATILDIĞINI söyler"
        assert_not_contains "$out" "GERİ YÜKLENDİ" "A [${sc} / ${path}]: hiçbir yedek geri yüklenmedi"
    done
done

test_summary
