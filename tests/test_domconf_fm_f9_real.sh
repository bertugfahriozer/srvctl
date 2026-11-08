#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# F9/a1 — GERÇEK nginx 1.28 laboratuvarında QL9-S1 (kapı-B penceresi), QL9-S2 (geri alma sırasında sinyal), qalab9-I2 (kozmetik bozuk
# kapalı kök) ölçümleri. nginx ya da curl YOKSA bu dosya ATLANIR (test_domconf_fm_f9_closure.sh mock karşılığıdır).
# YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl sarmalayıcı kalkanı; resolver 127.0.0.1:9; ana makine 'example.com'
# yalnız `curl --resolve example.com:<port>:127.0.0.1` ile çözülür). Port aralığı: 19150–19197 (F9/a1).
# Taklit EDİLEN yalnız srvctl'in çevresi (systemctl → `nginx -s reload`, nginx -t → gerçek `nginx -t -c`, flock); disk yazımları,
# köken kaydı, işaret, sonda ve kararlar srvctl'in GERÇEK kodudur; "çalışan durum" gerçek nginx'in gerçek yanıtıdır.
#  S1-A  kapı-B penceresi: acil kapatma yazıcının kapı B'si ile ilk yazımı arasına düşer (+ yazıcının nginx -t'sinde üçüncü taraf reload):
#        yazıcı bitince ve sonraki ilgisiz reload'dan sonra gerçek nginx KAPALI
#  S2-A  kapı reddi geri almasının reclose'u sırasında TERM: süreç ölmez, gerçek nginx KAPALI
#  I2-A  kayıt 'on' + kozmetik bozuk (CRLF / sondaki boşluk / mod 664 / sert bağ) kapalı kök: yollar gerçek nginx'i 411'e çevirmez
# Eski tek dosya (395 satır, 194 doğrulama) yük altında 300 sn'ye dayandığı için üç dosyaya bölündü (hiçbir doğrulama silinmedi ya da gevşetilmedi); ortak düzenek: tests/fm_f9_real_common.sh.
# Parçalar: (ad yok) lab + S1-A + S2-A + I2-A (crlf trailing mode664); _2: I2-A (hardlink wstab wstabbody) + I2-A kontrol; _3: L1-A + Y-A + dışarı-0-istek. Her parça kendi laboratuvarını kurar; "lab ayağa kalktı" ve
# "kontrol" doğrulamaları yalnız 1. parçada yazılır (2./3. parçada aynı koşul sessiz denetlenir, düşerse FAIL basar); dışarı-0-istek kalkanı 3. parçada doğrulama, 1./2. parçada yalnız-düşerse-FAIL denetimidir
# (iddia kümesi eski dosyayla birebir aynı; tek fark kalkan etiketindeki çağrı sayısıdır).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
source "${REPO_ROOT}/tests/fm_f9_real_common.sh"

echo "── lab ──"
lab_up; assert_eq "$?" "0" "lab ayağa kalktı (nginx $("$NG" -v 2>&1 | sed 's/.*nginx\///'), 127.0.0.1:${P})"
export SRVCTL_FM_PROBE_HTTP_PORT="$P"
fresh_open; assert_eq "$?" "0" "kontrol: srvctl'in GERÇEK ürettiği açık alan gerçek nginx'te 411 + srvctl-fm-open <imza> verir"

echo "── S1-A: kapı-B penceresi — acil kapatma, yazıcının kapı B'si ile ilk dosya yazımı arasında (gerçek nginx) ──"
eval "_f9_orig_fmprov_write() $(declare -f _fmprov_write | sed 1d)"
F9_WRITE_HOOK=""
_fmprov_write() {
    if [[ -n "$F9_WRITE_HOOK" && ! -e "${FM_STUBS}/trig" && "${2:-}" == on ]]; then : > "${FM_STUBS}/trig"; "$F9_WRITE_HOOK"; fi
    _f9_orig_fmprov_write "$@"
}
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_hook_em() {
    ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/em.out" 2>&1; echo "$?" > "${FM_STUBS}/em.rc"
    printf 'bk=%s sup=%s raw=%s\n' "$(_bkn)" "$(_supn)" "$(raw)" > "${FM_STUBS}/hook.out"
    : > "${FM_STUBS}/arm"
}
_h_tp() { if [[ -e "${FM_STUBS}/arm" && ! -e "${FM_STUBS}/hk" ]]; then : > "${FM_STUBS}/hk"; _third; raw > "${FM_STUBS}/mid.raw"; fi; }
for var in tp none; do
    fresh_open; rm -f "${FM_STUBS}/trig" "${FM_STUBS}/arm" "${FM_STUBS}/hk" "${FM_STUBS}/mid.raw" "${FM_STUBS}/em.rc" "${FM_STUBS}/hook.out"
    _ld
    F9_WRITE_HOOK=_hook_em
    if [[ "$var" == tp ]]; then NGINX_T_HOOK=_h_tp; else NGINX_T_HOOK=""; fi
    _DOMCONF_FM_TX_ACTION=repair
    ( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
    _DOMCONF_FM_TX_ACTION=""; NGINX_T_HOOK=""; F9_WRITE_HOOK=""
    assert_eq "$(cat "${FM_STUBS}/em.rc" 2>/dev/null)" "4" "S1-A [${var}]: ön koşul: acil kapatma pencerede koştu (kilit yazıcıda → rc 4)"
    assert_eq "$(cat "${FM_STUBS}/hook.out")" "bk=1 sup=0 raw=${CLOSED}" "S1-A [${var}]: acil bitince yazıcının .bk.*'si YERİNDE (ayrılmadı), gerçek nginx KAPALI"
    if [[ "$var" == tp ]]; then
        assert_eq "$(cat "${FM_STUBS}/mid.raw" 2>/dev/null)" "$OPEN" "S1-A [tp] kontrol: yazıcının nginx -t'sindeki üçüncü taraf reload AÇIK diski GERÇEKTEN yükledi (gerçek nginx 411)"
    fi
    assert_eq "$wrc" "4" "S1-A [${var}]: yazıcı kapı reddi rc 4"
    assert_eq "$(raw)" "$CLOSED" "S1-A [${var}]: yazıcı bitince gerçek nginx KAPALI (QL9: tp'de AÇIK kalıyordu)"
    assert_eq "$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "yokyok" "S1-A [${var}]: diskte 90/21 YOK (QL9: 'varvar')"
    _third
    assert_eq "$(raw)" "$CLOSED" "S1-A [${var}]: ilgisiz sonraki reload'dan SONRA da gerçek nginx KAPALI (QL9 none: AÇIK)"
    assert_eq "$(_bkn)|$(_supn)" "0|0" "S1-A [${var}]: yedek tüketildi, ayrılmış yedek yok"
done

echo "── S2-A: kapı reddi geri almasının reclose'u sırasında TERM (gerçek nginx) ──"
PIDF="${FM_STUBS}/s2.pid"; CNT="${FM_STUBS}/s2.cnt"
_hook_s2() {
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT"
    if (( n == 1 )); then _placemark; _third; fi
    if (( n == 2 )); then kill -TERM "$KILL_TARGET"; fi
}
# F9c (§15/38): eski tetikleyici (90 sil) artık alanı KAPATIR; kapı-B reddi bir 'on' YAZIMI ister → tetikleyici STALE şablon (üç eser tanınan). Beklentiler DEĞİŞMEDİ.
fresh_open; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "$CNT"
NGINX_T_HOOK=_hook_s2
( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1 ) >"$OUTF" 2>&1; wrc=$?
NGINX_T_HOOK=""
assert_eq "$(cat "$CNT" 2>/dev/null)" "2" "S2-A kontrol: kapı reddi + reclose'un nginx -t'si gerçekten koştu (2 canlı nginx -t)"
assert_eq "$wrc" "1" "S2-A: TERM reclose sırasında geldi: süreç ÖLMEDİ (rc 1; QL9: 143)"
assert_eq "$(raw)" "$CLOSED" "S2-A: gerçek nginx KAPALI (QL9: reclose yarıda kaldı, AÇIK)"
assert_contains "$(_out)" "alanı yeniden KAPATTI" "S2-A: reclose tamamlandı ve söylendi (QL9: iletisiz ölüm)"

echo "── I2-A: kayıt 'on' + kozmetik bozuk kapalı kök + 90/21 yok — yollar gerçek nginx'i AÇMAZ ──"
cosm() {
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        crlf) printf '%s\n' "$good" | sed 's/$/\r/' > "$F20"; chmod 644 "$F20" ;;
        trailing) printf '%s\n' "$good" | sed 's/$/ /' > "$F20"; chmod 644 "$F20" ;;
        mode664) printf '%s\n' "$good" > "$F20"; chmod 664 "$F20" ;;
        hardlink) printf '%s\n' "$good" > "$F20"; chmod 644 "$F20"; ln -f "$F20" "${F20}.hard" ;;
        wstab) printf '%s\n' "$good" | tr ' ' '\t' > "$F20"; chmod 644 "$F20" ;;                                                  # F9/a1b f_ws_tab: tüm boşluklar tab
        wstabbody) printf '%s\n' "$good" | sed 's/srvctl-fm-closed /srvctl-fm-closed\t/' > "$F20"; chmod 644 "$F20" ;;             # tab yalnız tırnaklı gövdede
    esac
    rm -f "$F90" "$F21"
}
for v in crlf trailing mode664; do
    for path in fmroot repair83 repair84 fmrootall phpswitch repairall stalebk_fmroot stalebk_repair; do
        fresh_open
        case "$path" in stalebk_*) _mk_stale_bk AAAAAA ;; esac
        cosm "$v"; _third
        r=$(raw)
        if [[ "${r%%|*}" != "403" ]]; then assert_eq "${r%%|*}" "403" "I2-A [${v}/${path}] kontrol: yazılan kozmetik bozuk kök gerçek nginx'te 403 veriyor"; fi
        case "$path" in
            fmroot|stalebk_fmroot) _fmroot ;;
            repair83) ( _domconf_fm_auth_repair example.com 8.3 1 ) >"$OUTF" 2>&1 ;;
            repair84|stalebk_repair) ( _domconf_fm_auth_repair example.com 8.4 1 ) >"$OUTF" 2>&1 ;;
            fmrootall) _fmroot_all ;;
            phpswitch) _phpswitch ;;
            repairall) _batch ;;
        esac
        _third
        r=$(raw)
        assert_eq "${r%%|*}|$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "403|yokyok" "I2-A [${v}/${path}]: yol sonrası gerçek nginx 403, 90/21 YOK (QL9 qalab: 6/8 yol 411)"
        rm -f "${F20}.hard"
    done
done

# dışarı-0-istek kalkanı (bu laboratuvar için): düşmezse FAIL (doğrulama etiketi 3. parçada)
if [[ "$(grep -c '^DENY' "$SHIM_LOG")" != "0" ]]; then echo "  FAIL kalkan günlüğünde DENY satırı var (dışarı istek!)"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); fi

test_summary
