#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# 'fm-auth on' kesintisinden sonra otomatik yollar alanı AÇMAZ (ARCHITECTURE §15/93(b)(2); §15/33, §15/38, §15/43(d), §15/44(b)).
# Kapalı 403 kökünden başlayan normal 'on' K. dosya-sistemi adımında SIGKILL ile ölür (K=1…son adım); ardından otomatik yol koşar.
# php-switch yolu domain.sh akışındaki gibidir: soket senkronu, ARDINDAN koşulsuz `nginx -t && systemctl reload nginx`. Eskiden K=10–14'te (yarım
# açılışın yedeği duruyor, kayıt on, disk açık, çalışan nginx KAPALI) senkron "REDDEDİLDİ" der ama arkasından gelen reload yarım açılışı
# çalışan nginx'e YÜKLER (KAPALI → AÇIK). Şimdi php-switch, repair / fm-root gibi, önce kurtarıp kapatır; ardından reload KAPALI yükler.
#  A  K × {repair, fm-root --apply, fm-root --all --apply, provision, toplu repair, php-switch}: kesinti sonrası (kayıt on + disk TAM açık + yedek yok)
#     DEĞİLSE (o durum "on" kaydının yalnız reload'u eksik: kabul edilmiş AÇIK-KORUNDU) otomatik yol sonunda çalışan nginx'i AÇIK YAPMAZ.
#  B  php-switch iletisi: yarım açılış kurtarılıp alan KAPATILDIysa "fm-auth alanı KAPATILDI" der ("soketi çekildi" DEMEZ); rc 10.
#  C  kurtarma YAPILAMAZSA (yedek korunur, kurtarma düşer) php-switch yüksek sesle "FM HÂLÂ AÇIK OLABİLİR" der ve rc≠0 verir.
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

# Dosya başı süre payı için K aralığı ikiye bölünür (bu dosya 1–8 ve B/C/D; _2: 9–son adım).
KFROM="${G13_KFROM:-1}"; KTO="${G13_KTO:-8}"
PATHS="${G13_PATHS:-phpswitch repair fmroot fmrootall provision toplu}"

run_path() {
    local r0 r1
    r0=$(_reloads)
    case "$1" in
        repair)    ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1 ) >"$OUTF" 2>&1 ;;
        fmroot)    ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1 ;;
        fmrootall) ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1 ;;
        provision) ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1 ;;
        phpswitch) # domain.sh akışı: soket senkronu, sonra (senkronun sonucundan bağımsız) koşulsuz nginx -t + reload; çağıranın iletisi
                   ( fm_rc=0; _domconf_fm_auth_sock_sync example.com 8.4 || fm_rc=$?
                     case "$fm_rc" in
                         0) ;;
                         10) if [[ "${_DOMCONF_FM_SWITCH_CLOSED:-0}" == "1" ]]; then echo "fm-auth alanı KAPATILDI (403 kökü)"; else echo "fm-auth soketi php8.4'e çekildi"; fi ;;
                         *) echo "fm-auth soketi güncellenemedi" ;;
                     esac
                     nginx -t >/dev/null 2>&1 && systemctl reload nginx
                     exit "$fm_rc" ) >"$OUTF" 2>&1 ;;
        toplu)     ( _DOMAIN_REPAIR_FM_PENDING="${FM_STUBS}/pending"; : > "$_DOMAIN_REPAIR_FM_PENDING"
                     _domain_repair_fm_step example.com "${DEFAULT_PHP_VERSION}"; r=$?
                     if [[ -s "$_DOMAIN_REPAIR_FM_PENDING" ]]; then nginx -t >/dev/null 2>&1 && systemctl reload nginx; fi
                     exit $r ) >"$OUTF" 2>&1 ;;
    esac
    PSRC=$?
    r1=$(_reloads); RLD=$((r1 - r0))
}
# Kapalı 403 kökünden başlayıp K. adımda ölen normal 'on'. Başlangıç: kök kuruldu + çalışan KAPALI.
mk_killed_on() {
    g13_snap_restore root
    g13_killed "$1" g13_on
    KRC=$?
    PRE="$(_shut)|$(_st)|$(_run)|bk=$(_bkn)"
}
# kesintiden sonra "on" kaydı tam yazılmış, disk TAM açık ve yarım işlem yedeği yok: yalnız reload eksik (kabul edilmiş AÇIK-KORUNDU)
fully_committed_open() { [[ "$(_shut)|$(_st)|$(_bkn)" == "OPEN|on|0" ]]; }

echo "── 0: düzenek — normal on'un adım sayısı ──"
reset_all; ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; fm_sim_reload; g13_snap_save root   # kapalı 403 kökü + çalışan KAPALI
echo 0 > "$G13_CNT"; G13_K=-1; ( g13_on ) >"$OUTF" 2>&1; G13_K=0
NSTEPS=$(g13_steps)
assert_ne "$NSTEPS" "0" "0a: on adım sayacı çalışıyor (${NSTEPS} adım)"
(( KTO > NSTEPS )) && KTO=$NSTEPS
[[ "${G13_KTO_OPEN:-0}" != 1 ]] || KTO=$NSTEPS   # son dilim: son adıma kadar
assert_eq "$(_shut)|$(_st)|$(_run)" "OPEN|on|RUN-OPEN" "0b: kesintisiz on: disk AÇIK, kayıt on, çalışan AÇIK"

echo "── A: SIGKILL K=${KFROM}…${KTO} × yol: kesinti sonrası otomatik yol çalışan nginx'i KAPALI → AÇIK YAPMAZ ──"
for (( K = KFROM; K <= KTO; K++ )); do
    for p in $PATHS; do
        mk_killed_on "$K"
        if [[ "$(_run)" == "RUN-OPEN" ]]; then continue; fi    # ölüm reload'dan SONRA: alan zaten (kayıtlı) açık
        if fully_committed_open; then
            assert_eq "$KRC" "137" "A K=${K} [${p}]: (kayıt on + disk tam açık + yedek yok: kabul edilmiş AÇIK-KORUNDU; ölçüt dışı) ölüm gerçekleşti"
            continue
        fi
        run_path "$p"
        assert_ne "$(_run)" "RUN-OPEN" "A K=${K} [${p}]: ölüm sonrası ${PRE} → rc ${PSRC}, reload ${RLD}: çalışan nginx AÇIK DEĞİL"
        # provision tek yarım işlem yedeğini kurtarmaz ve reload etmez (diskte yarım açılış kalır; çalışan nginx KAPALI kalır): yukarıdaki ölçüt (çalışan AÇIK DEĞİL) onu kapsar.
        [[ "$p" != provision ]] || continue
        assert_ne "$(_shut)|$(_st)" "OPEN|on" "A K=${K} [${p}]: yarım açılış otomatik yolla TAMAMLANMADI (disk/kayıt açık değil)"
    done
done

if [[ "${G13_SKIPBCD:-0}" == 1 ]]; then test_summary; exit $?; fi
echo "── B: php-switch iletisi — yarım açılış kurtarılıp KAPATILDI ──"
mk_killed_on 10
if [[ "$(_bkn)" == "1" && "$(_st)" == "on" ]]; then
    run_path phpswitch
    assert_eq "$PSRC|$(_shut)|$(_st)|$(_run)|$(_bkn)" "10|SHUT|off|RUN-CLOSED|0" "B1: php-switch rc 10, disk KAPALI, kayıt off, çalışan KAPALI, yedek tüketildi"
    assert_contains "$(strip < "$OUTF")" "fm-auth alanı KAPATILDI" "B2: çağıran 'KAPATILDI' der"
    assert_not_contains "$(strip < "$OUTF")" "soketi php8.4'e çekildi" "B3: 'soketi çekildi' DEMEZ (alan açılmadı, kapatıldı)"
else
    assert_eq "yedek-yok" "yedek-var" "B0: K=10 kesintisi yarım açılış yedeği bırakmalı (bk=$(_bkn) kayıt=$(_st))"
fi

echo "── C: kurtarma yapılamaz → rc≠0 + 'FM HÂLÂ AÇIK OLABİLİR' (kilit alınamaz) ──"
mk_killed_on 10
FLOCK_RC=1
run_path phpswitch
FLOCK_RC=0
assert_ne "$PSRC" "0" "C1: kurtarma yapılamadı: rc≠0 (${PSRC})"
assert_contains "$(strip < "$OUTF")" "FM HÂLÂ AÇIK OLABİLİR" "C2: ileti FM HÂLÂ AÇIK OLABİLİR der"

echo "── D: kontroller ──"
# yedek yok, sınıf 0: soket güncellenir (rc 10)
reset_all; _on; run_path phpswitch
assert_eq "$PSRC|$(grep -c 'php8.4-fpm' "$F90")|$(_run)" "10|1|RUN-OPEN" "D1: açık alan, yedek yok: soket güncellenir (rc 10), alan AÇIK kalır"
assert_contains "$(strip < "$OUTF")" "soketi php8.4'e çekildi" "D2: ileti 'soketi çekildi' der"
# kayıt KAPALI + yedek: senkron no-op (rc 0), yedeğe dokunmaz
reset_all; _on; _off; _mk_stale_bk AAAAAA; run_path phpswitch
assert_eq "$PSRC|$(_bkn)" "0|1" "D3: kayıt kapalı + yedek: php-switch no-op, yedeğe dokunmaz"

test_summary
