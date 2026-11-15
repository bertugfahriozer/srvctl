#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# Çökme sonrası yeniden yükleme, SONDA KÖR alanda (ARCHITECTURE §15/93(b)(1)(3)): normal 'fm-auth off' K. dosya-sistemi adımında SIGKILL ile ölür
# (K=1…12); ardından otomatik yol, çalışan durum doğrulanamazken (sonda kör) koşar. Doğrulanamayan çalışan durum "kapalı" SAYILMAZ:
# diskte KAPALI kanıtı varsa yapılandırma KOŞULSUZ yeniden yüklenir; sonda KESİN KAPALI ise gereksiz reload yoktur.
#  A  K=1…12 × {repair, fm-root --apply, fm-root --all --apply, provision, toplu repair}, sonda kör: alan meşru AÇIK (kayıt on + disk açık: K=1/2, hiçbir
#     şey yazılmadı) DEĞİLSE sonunda disk KAPALI ve çalışan nginx KAPALI.
#  B  reload başarısız (SYSTEMCTL_RC=1), sonda kör: disk kapalı olur ya da zaten kapalıdır; çalışan nginx hâlâ AÇIK iken rc≠0 ve ileti "FM HÂLÂ AÇIK OLABİLİR"
#     der (K=3–5: kurtarma kapatmayı diske yazıp reload düşünce de; §15/93(b)(3)). Sonda kesin AÇIK iken de aynı.
#  C  kontroller: sonda KESİN KAPALI → reload 0; kör ama reload edilebilir çalışan durum → ileti "DOĞRULANAMADI" der, rc 0; açık alan (kayıt on) → reload yok.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
source "${REPO_ROOT}/tests/fm_g13_crash_common.sh"
export SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT=80
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

# Dosya başı süre payı için K aralığı dört dosyaya bölünür (bu dosya 1–3 ve kontroller; _2: 4–6, _3: 7–9, _4: 10–12; üçü G13_KFROM/G13_KTO/G13_SKIPC ayarlayıp bunu koşar).
KFROM="${G13_KFROM:-1}"; KTO="${G13_KTO:-3}"
PATHS="${G13_PATHS:-repair fmroot fmrootall provision toplu}"

# Çalışma yolları: $1 = ad. Çıktı OUTF'ta, rc PSRC'de, reload sayısı farkı RLD'de.
run_path() {
    local r0 r1
    r0=$(_reloads)
    case "$1" in
        repair)    ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1 ) >"$OUTF" 2>&1 ;;
        fmroot)    ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1 ;;
        fmrootall) ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1 ;;
        provision) ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1 ;;
        toplu)     ( _DOMAIN_REPAIR_FM_PENDING="${FM_STUBS}/pending"; : > "$_DOMAIN_REPAIR_FM_PENDING"
                     _domain_repair_fm_step example.com "${DEFAULT_PHP_VERSION}"; r=$?
                     if [[ -s "$_DOMAIN_REPAIR_FM_PENDING" ]]; then
                         if ! { nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; }; then
                             echo "FM HÂLÂ AÇIK OLABİLİR (toplu reload başarısız)"; r=1
                         fi
                     fi
                     exit $r ) >"$OUTF" 2>&1 ;;
    esac
    PSRC=$?
    r1=$(_reloads); RLD=$((r1 - r0))
}
# K. adımda ölen normal 'off' (kapalı kökten değil: açık alandan başlar). Ölüm anı durumu PRE'ye yazılır.
mk_killed_off() {
    g13_snap_restore open
    g13_killed "$1" g13_off
    KRC=$?
    PRE="$(_shut)|$(_st)|$(_run)|bk=$(_bkn)"
}
# alan meşru AÇIK: kayıt on + disk açık (K=1/2: off hiçbir şey yazmadan öldü; kurtarma yedeği olduğu gibi geri koyar → yine açık). Ölçüt dışı.
legit_open() { [[ "$(_shut)|$(_st)" == "OPEN|on" ]]; }

echo "── 0: düzenek — normal off'un adım sayısı ──"
reset_all; _on; fm_sim_reload; g13_snap_save open   # pahalı kurulum (fm-auth on) bir kez; her vaka anlık görüntüden döner
echo 0 > "$G13_CNT"; G13_K=-1; ( g13_off ) >"$OUTF" 2>&1; G13_K=0
NSTEPS=$(g13_steps)
assert_ne "$NSTEPS" "0" "0a: off adım sayacı çalışıyor (${NSTEPS} adım)"
(( KTO > NSTEPS )) && KTO=$NSTEPS
assert_eq "$(_shut)|$(_st)" "SHUT|off" "0b: kesintisiz off: disk KAPALI, kayıt off"

echo "── A: SIGKILL K=${KFROM}…${KTO} × yol, SONDA KÖR, reload başarılı ──"
for (( K = KFROM; K <= KTO; K++ )); do
    for p in $PATHS; do
        mk_killed_off "$K"
        if legit_open; then
            assert_eq "$KRC" "137" "A K=${K} [${p}]: ölüm gerçekleşti ve hiçbir şey yazılmadı (alan meşru AÇIK: kayıt on + disk açık)"
            continue
        fi
        FM_PROBE_MODE=unknown
        run_path "$p"
        FM_PROBE_MODE=sim
        assert_eq "$(_shut)|$(_run)" "SHUT|RUN-CLOSED" "A K=${K} [${p}]: ölüm sonrası ${PRE} → rc ${PSRC}, reload ${RLD}: disk KAPALI ve çalışan nginx KAPALI (kör sondada da yeniden yüklendi)"
        if [[ "$p" == toplu ]]; then
            assert_eq "$PSRC" "0" "A K=${K} [${p}]: rc 0"
        fi
    done
done

echo "── B: reload başarısız (sonda kör ve sonda AÇIK) → çalışan hâlâ AÇIK ise rc≠0 + 'FM HÂLÂ AÇIK OLABİLİR' ──"
for (( K = KFROM; K <= KTO; K++ )); do
    for p in $PATHS; do
        [[ "$p" != toplu && "$p" != fmrootall ]] || continue   # fmrootall = fmroot ile aynı apply işlevi; toplu reload'u çağıranda
        for pm in unknown sim; do
            [[ "$pm" == unknown || "$K" == 3 || "$K" == 6 || "$K" == 10 ]] || continue   # sonda AÇIK kontrolü yalnız temsilci K'lerde
            mk_killed_off "$K"
            if legit_open; then continue; fi
            FM_PROBE_MODE="$pm"; SYSTEMCTL_RC=1
            run_path "$p"
            SYSTEMCTL_RC=0; FM_PROBE_MODE=sim
            if [[ "$(_run)" == "RUN-OPEN" ]]; then
                assert_ne "$PSRC" "0" "B K=${K} [${p}/${pm}]: reload başarısız, çalışan hâlâ AÇIK: rc≠0 (${PSRC})"
                assert_contains "$(strip < "$OUTF")" "FM HÂLÂ AÇIK OLABİLİR" "B K=${K} [${p}/${pm}]: ileti FM HÂLÂ AÇIK OLABİLİR der (ölüm sonrası ${PRE})"
            fi
        done
    done
done

echo "── C: kontroller ──"
for p in repair fmroot provision; do
    [[ "${G13_SKIPC:-0}" != 1 ]] || break
    # C1 sonda KESİN KAPALI → gereksiz reload yok
    g13_snap_restore open; _off; fm_sim_reload; FM_PROBE_MODE=sim
    run_path "$p"
    assert_eq "$PSRC|$(_run)|${RLD}" "0|RUN-CLOSED|0" "C1 [${p}]: çalışan KESİN KAPALI: reload 0, rc 0"
    # C2 kör ama reload edilebilir: rc 0, ileti 'DOĞRULANAMADI' der (sessiz değil)
    mk_killed_off 10
    FM_PROBE_MODE=unknown
    run_path "$p"
    FM_PROBE_MODE=sim
    assert_eq "$PSRC|$(_run)|${RLD}" "0|RUN-CLOSED|1" "C2 [${p}]: kör sonda: tam 1 reload, çalışan KAPALI, rc 0"
    assert_contains "$(strip < "$OUTF")" "DOĞRULANAMADI" "C2 [${p}]: ileti çalışan durumun doğrulanamadığını söyler"
    # C3 açık alan (kayıt on): AÇIK kalır, bu yol reload yapmaz
    g13_snap_restore open; FM_PROBE_MODE=unknown
    run_path "$p"
    FM_PROBE_MODE=sim
    assert_eq "$(_shut)|$(_st)|$(_run)|${RLD}" "OPEN|on|RUN-OPEN|0" "C3 [${p}]: açık alan (kayıt on), kör sonda: AÇIK kalır, reload 0"
done

test_summary
