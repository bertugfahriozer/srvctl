#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# Çökme sonrası yeniden yükleme (ARCHITECTURE §15/80(e)): 'fm-auth off' commit'i ile reload arasında ölüm → disk KAPALI (403 kökü, 90/21 yok),
# kayıt off, ama ÇALIŞAN nginx hâlâ AÇIK. Yazılacak bir şey olmadığından repair / fm-root --apply / provision eskiden reload YAPMAZ ve rc 0
# dönerdi. Şimdi: diskte KAPALI kanıtı + çalışan durum AÇIK imzası → nginx -t + reload + KAPALI imzası doğrulaması; başarısızsa rc≠0 ve
# "FM HÂLÂ AÇIK OLABİLİR". Yalnız KAPATMA yönü: çalışan durum KAPALI ya da doğrulanamıyorsa dokunmaz; açık alanı etkilemez.
#  A  yollar {repair, fm-root --apply, fm-root --all --apply, provision, toplu repair (reload=0)} × {kayıt off + disk kapalı + çalışan AÇIK}:
#     rc 0, çalışan KAPALI, tam 1 reload (toplu: reload çağırana bırakılır, WROTE=1).
#  B  reload başarısız / nginx -t düşer: rc≠0, "FM HÂLÂ AÇIK OLABİLİR", çalışan hâlâ AÇIK, disk KAPALI kalır.
#  C  kontroller: çalışan zaten KAPALI → reload 0; sonda kör (doğrulanamıyor) → KOŞULSUZ yeniden yüklenir (§15/93(b)(1); kör sondada kesinti sonrası ayrıntı:
#     test_domconf_fm_g13_blind_reload*.sh, test_domconf_fm_g13_blind_real.sh); açık alan (kayıt on) → alan AÇIK kalır, reload yok.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
export SRVCTL_FM_PROBE_HTTPS_PORT=443 SRVCTL_FM_PROBE_HTTP_PORT=80
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

# Kayıt off + disk KAPALI + ÇALIŞAN nginx AÇIK (off commit'i ile reload arası ölüm).
mk_run_open() {
    local keep="${FM_STUBS}/openkeep"
    reset_all; _on
    mkdir -p "$keep"; cp -p "$F90" "$F21" "$F20" "$keep/"
    _off
    rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"; cp -p "$keep"/* "$FM_RUNNING/"
    FM_PROBE_MODE=sim
}
# Çalışma yolları: $1 = ad. Çıktı OUTF'ta, rc PSRC'de, reload sayısı farkı RLD'de.
run_path() {
    local r0 r1
    r0=$(_reloads)
    case "$1" in
        repair)     ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1 ) >"$OUTF" 2>&1 ;;
        fmroot)     ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1 ;;
        fmrootall)  ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1 ;;
        provision)  ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1 ;;
        toplu)      ( _DOMCONF_FM_WROTE=0; _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 0; r=$?; echo "$_DOMCONF_FM_WROTE" > "${FM_STUBS}/wrote"; exit $r ) >"$OUTF" 2>&1 ;;
    esac
    PSRC=$?
    r1=$(_reloads); RLD=$((r1 - r0))
}

echo "── A: kayıt off + disk kapalı + çalışan AÇIK → yeniden yüklenir, KAPALI doğrulanır ──"
for p in repair fmroot fmrootall provision; do
    mk_run_open
    assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-OPEN" "A0 [${p}]: kurulum: disk KAPALI, kayıt off, çalışan AÇIK"
    run_path "$p"
    assert_eq "$PSRC|$(_shut)|$(_st)|$(_run)|${RLD}" "0|SHUT|off|RUN-CLOSED|1" "A [${p}]: rc 0, çalışan KAPALI, tam 1 reload"
    assert_contains "$(strip < "$OUTF")" "hâlâ AÇIK imzası veriyor" "A [${p}]: ileti çalışan durumun AÇIK olduğunu söyler"
done
mk_run_open; rm -f "${FM_STUBS}/wrote"
run_path toplu
assert_eq "$PSRC|$(_shut)|$(_run)|${RLD}|$(cat "${FM_STUBS}/wrote" 2>/dev/null)" "0|SHUT|RUN-OPEN|0|1" "A [toplu repair]: alan başına reload YOK, çağırana 'yazım var' (WROTE=1) bildirilir"

echo "── B: yeniden yükleme başarısız → rc≠0 + 'FM HÂLÂ AÇIK OLABİLİR' ──"
for p in repair fmroot provision; do
    mk_run_open; SYSTEMCTL_RC=1
    run_path "$p"
    SYSTEMCTL_RC=0
    assert_ne "$PSRC" "0" "B1 [${p}]: reload başarısız: rc≠0 (${PSRC})"
    assert_contains "$(strip < "$OUTF")" "FM HÂLÂ AÇIK OLABİLİR" "B1 [${p}]: ileti FM HÂLÂ AÇIK OLABİLİR der"
    assert_eq "$(_shut)|$(_run)" "SHUT|RUN-OPEN" "B1 [${p}]: disk KAPALI kalır, çalışan hâlâ AÇIK (ileti doğru)"
    mk_run_open; NGINX_TEST_RC=1
    run_path "$p"
    NGINX_TEST_RC=0
    assert_ne "$PSRC" "0" "B2 [${p}]: nginx -t düşer: rc≠0 (${PSRC})"
    if [[ "$p" == repair ]]; then   # repair kendi nginx -t kapısında düşer (bu alanın dosyası değil): rc≠0 yeter, ileti genel
        assert_contains "$(strip < "$OUTF")" "nginx -t BAŞARISIZ" "B2 [${p}]: ileti nginx -t hatasını söyler"
    else
        assert_contains "$(strip < "$OUTF")" "FM HÂLÂ AÇIK OLABİLİR" "B2 [${p}]: ileti FM HÂLÂ AÇIK OLABİLİR der"
    fi
    assert_eq "$(_shut)|$(_run)" "SHUT|RUN-OPEN" "B2 [${p}]: disk KAPALI kalır, çalışan hâlâ AÇIK"
done

echo "── C: kontroller — yalnız kapatma yönü, gereksiz reload yok ──"
for p in repair fmroot provision; do
    reset_all; _on; _off; fm_sim_reload
    run_path "$p"
    assert_eq "$PSRC|$(_run)|${RLD}" "0|RUN-CLOSED|0" "C1 [${p}]: çalışan zaten KAPALI: reload 0, rc 0"
    # C2 (ARCHITECTURE §15/93(b)(1): önceki beklenti "sonda kör → dokunmaz (reload 0, çalışan AÇIK kalır)" idi; karar tersine döndü): doğrulanamayan çalışan durum
    # "diskle aynı" SAYILMAZ (fail-closed, §15/80(e) "koşulsuz reload"): disk KAPALI kanıtı varsa yapılandırma yeniden yüklenir; rc 0 ama ileti doğrulanamadığını söyler.
    mk_run_open; FM_PROBE_MODE=unknown
    run_path "$p"
    assert_eq "$PSRC|$(_run)|${RLD}" "0|RUN-CLOSED|1" "C2 [${p}]: sonda kör (doğrulanamıyor): yeniden yüklenir (tam 1 reload, çalışan KAPALI, rc 0)"
    assert_contains "$(strip < "$OUTF")" "DOĞRULANAMADI" "C2 [${p}]: ileti çalışan durumun doğrulanamadığını söyler (sessiz değil)"
    FM_PROBE_MODE=sim
    reset_all; _on; fm_sim_reload
    run_path "$p"
    assert_eq "$(_shut)|$(_st)|$(_run)|${RLD}" "OPEN|on|RUN-OPEN|0" "C3 [${p}]: açık alan (kayıt on): AÇIK kalır, bu yol reload yapmaz"
done

test_summary
