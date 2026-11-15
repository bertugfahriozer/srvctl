#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# Çökme sonrası yeniden yükleme, SONDA KÖR alanda — GERÇEK nginx 1.28 laboratuvarında (ARCHITECTURE §15/93(b)(1)). nginx ya da curl YOKSA bu dosya ATLANIR.
# YALNIZ 127.0.0.1:19300–19399, geçici prefix; dış ağa istek YOK.
#  A  kör sonda durumu: `fm-auth on` (gerçek reload; gerçek nginx gövdesiz PUT'a "411 srvctl-fm-open <imza>" verir) → `fm-auth off` YAZILIR ama reload YAPILMAZ
#     (commit ile reload arası kesinti) → disk 403 kökü, 90/21 yok, kayıt off, GERÇEK nginx hâlâ 411 AÇIK → sonda kapatılır (SRVCTL_FM_PROBE_HTTP_PORT=off) →
#     repair / fm-root --apply / fm-root --all --apply / provision: gerçek nginx 403 "srvctl-fm-closed <imza>" (KAPALI). Kontrol: sonda AÇIK (port verildi) → aynı sonuç.
#  B  normal `off` K. dosya-sistemi adımında SIGKILL ile ölür (K=1…son adım) → kör sonda → repair / provision: gerçek nginx alan meşru açık (kayıt on + disk açık)
#     DEĞİLSE KAPALI imzası verir.
#  C  `systemctl reload nginx` başarısızsa (reload düşürülür; gerçek nginx eski yapılandırmasında kalır) rc≠0 + "FM HÂLÂ AÇIK OLABİLİR"; gerçek nginx hâlâ 411 AÇIK.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
source "${REPO_ROOT}/tests/fm_g13_crash_common.sh"
source "${REPO_ROOT}/tests/fm_g13_real_common.sh"
set +e
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
g13_real_skip_if_missing
trap 'g13_lab_down; rm -rf "${G13_T:?}"; _fm_env_cleanup' EXIT
if ! g13_lab_up; then echo "  FAIL lab açılamadı"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; fi
KFROM="${G13_KFROM:-1}"; KTO="${G13_KTO:-99}"
g13_real_reset; G13_RELOAD_REAL=1; _on; g13_snap_save openreal   # pahalı kurulum (gerçek reload'lu fm-auth on) bir kez; her vaka anlık görüntüden döner

# gerçek nginx açıkken `on` (gerçek reload), ardından $1 = reload'suz `off` (kesinti benzetimi) ya da K. adımda ölen `off`
mk_open_real() { g13_real_restore openreal; G13_RELOAD_REAL=1; systemctl reload nginx; }
run_path() {   # $1 = yol; sonda KÖR (HTTP portu off) ya da $2=open ise sonda AÇIK (port verildi)
    local hp="off"; [[ "${2:-}" == open ]] && hp="$G13_P"
    SRVCTL_FM_PROBE_HTTP_PORT="$hp"
    case "$1" in
        repair)    ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1 ) >"$OUTF" 2>&1 ;;
        fmroot)    ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1 ;;
        fmrootall) ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1 ;;
        provision) ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1 ;;
    esac
    PSRC=$?
    SRVCTL_FM_PROBE_HTTP_PORT="$G13_P"
}

echo "── A: reload'suz off (commit→reload kesintisi) → kör sonda → gerçek nginx ──"
for mode in blind open; do
    for p in repair fmroot fmrootall provision; do
        mk_open_real
        assert_eq "$(g13_real_state)" "REAL-OPEN" "A0 [${p}/${mode}]: gerçek nginx 'on' sonrası 411 AÇIK"
        G13_RELOAD_REAL=0; _off; G13_RELOAD_REAL=1
        assert_eq "$(_shut)|$(_st)|$(g13_real_state)" "SHUT|off|REAL-OPEN" "A1 [${p}/${mode}]: disk 403 kökü, kayıt off, GERÇEK nginx hâlâ AÇIK (kesinti)"
        run_path "$p" "$mode"
        assert_eq "$PSRC|$(_shut)|$(g13_real_state)" "0|SHUT|REAL-CLOSED" "A2 [${p}/${mode}]: rc 0, gerçek nginx 403 KAPALI imzası"
    done
done

echo "── B: SIGKILL K × yol (kör sonda), gerçek nginx ──"
mk_open_real; echo 0 > "$G13_CNT"; G13_K=-1; ( g13_off ) >"$OUTF" 2>&1; G13_K=0; NSTEPS=$(g13_steps)
assert_ne "$NSTEPS" "0" "B0: off adım sayacı çalışıyor (${NSTEPS} adım)"
(( KTO > NSTEPS )) && KTO=$NSTEPS
for (( K = KFROM; K <= KTO; K++ )); do
    for p in repair provision; do
        mk_open_real
        G13_RELOAD_REAL=1; g13_killed "$K" g13_off   # ölüm reload'dan önce: gerçek reload yalnız off'un SON adımındadır
        PRE="$(_shut)|$(_st)|$(g13_real_state)|bk=$(_bkn)"
        if [[ "$(_shut)|$(_st)" == "OPEN|on" ]]; then
            assert_eq "$(g13_real_state)" "REAL-OPEN" "B K=${K} [${p}]: (alan meşru açık: kayıt on + disk açık; ölçüt dışı) gerçek nginx AÇIK"
            continue
        fi
        run_path "$p" blind
        assert_eq "$(_shut)|$(g13_real_state)" "SHUT|REAL-CLOSED" "B K=${K} [${p}]: ölüm sonrası ${PRE} → rc ${PSRC}: disk KAPALI ve GERÇEK nginx 403 KAPALI"
    done
done

echo "── C: gerçek reload başarısız → rc≠0 + 'FM HÂLÂ AÇIK OLABİLİR', gerçek nginx hâlâ AÇIK ──"
for p in repair fmroot provision; do
    mk_open_real
    G13_RELOAD_REAL=0; _off; G13_RELOAD_REAL=1
    G13_RELOAD_REAL=fail    # `systemctl reload nginx` başarısız; gerçek nginx eski (AÇIK) yapılandırmasında kalır
    run_path "$p" blind
    G13_RELOAD_REAL=1
    assert_ne "$PSRC" "0" "C [${p}]: reload düştü: rc≠0 (${PSRC})"
    assert_contains "$(strip < "$OUTF")" "FM HÂLÂ AÇIK OLABİLİR" "C [${p}]: ileti FM HÂLÂ AÇIK OLABİLİR der"
    assert_eq "$(g13_real_state)" "REAL-OPEN" "C [${p}]: gerçek nginx hâlâ 411 AÇIK (ileti doğru)"
done

test_summary
