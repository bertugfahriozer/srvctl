#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# php-switch (sock_sync) + kayıt 'off' iken diskte AÇIK iz — otomatik yollar yalnız KAPATIR (ARCHITECTURE §15/33, §15/38, §15/80(b)).
# 'off' kaydı diskten ÖNCE yazar; araya giren kesinti "kayıt off + disk açık" bırakabilir. repair / fm-root / provision bunu kapatır;
# php-switch eskiden `[[ state == on ]] || return 0` ile no-op rc 0 dönüp alanı AÇIK bırakıyordu.
#  A  kayıt off + {90+21+20 açık | yalnız 90 | yalnız 21 | yalnız açık 20} × yedek {yok | tek yarım-işlem yedeği (kayıt on)}:
#     rc 10, disk 403 kökü (90/21 yok), kayıt off, çalışan KAPALI, yedek geri YÜKLENMEDİ (.superseded), _DOMCONF_FM_SWITCH_CLOSED=1.
#  B  kontroller: kayıt off + disk kapalı → no-op (rc 0, disk/kayıt DEĞİŞMEZ); kayıt on + sürüm değişir → soket güncellenir,
#     alan AÇIK kalır, SWITCH_CLOSED=0; kayıt on + aynı sürüm → no-op; kayıt yok → no-op.
#  C  kapatılamıyorsa (nginx -t düşer): rc≠0 ve rc≠10, "FM HÂLÂ AÇIK OLABİLİR".
#  D  çağıran (lib/domain.sh php-switch) kapatmayı "soket çekildi" diye SÖYLEMEZ.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

# Kayıt 'off' + diskte açık iz kurar. $1 = all|only90|only21|only20 · $2 = none|one (yarım-işlem yedeği, kaydı 'on')
mk_off_open() {
    local var="$1" bk="$2" keep="${FM_STUBS}/openkeep"
    reset_all; _on
    mkdir -p "$keep"; cp -p "$F90" "$F21" "$F20" "$keep/"; cp -p "$MAN" "${FM_STUBS}/man.on"
    _off
    case "$var" in
        all)    cp -p "$keep/${N90}" "$F90"; cp -p "$keep/${N21}" "$F21"; cp -p "$keep/${N20}" "$F20" ;;
        only90) cp -p "$keep/${N90}" "$F90" ;;
        only21) cp -p "$keep/${N21}" "$F21" ;;
        only20) cp -p "$keep/${N20}" "$F20" ;;
    esac
    if [[ "$bk" == one ]]; then
        _mk_stale_bk AAAAAA
        cp -p "${FM_STUBS}/man.on" "${SD}/.bk.example_com.AAAAAA/manifest"
    fi
    fm_sim_reload
}
# php-switch çekirdeği (alt kabukta; global işaret dosyayla taşınır). PSRC = rc, PSCL = kapatıldı işareti.
_ps() {
    _DOMCONF_FM_SWITCH_CLOSED=0
    ( _domconf_fm_auth_sock_sync example.com 8.4; echo "$?" > "${FM_STUBS}/ps.rc"; echo "$_DOMCONF_FM_SWITCH_CLOSED" > "${FM_STUBS}/ps.closed" ) >"$OUTF" 2>&1
    PSRC=$(cat "${FM_STUBS}/ps.rc"); PSCL=$(cat "${FM_STUBS}/ps.closed"); fm_sim_reload
}
_snap() { { cat "$MAN" 2>/dev/null; ls -l "$F20" "$F21" "$F90" 2>&1; cat "$F20" 2>/dev/null; } | _md5stdin; }

echo "── A: kayıt off + diskte açık iz → php-switch KAPATIR ──"
for var in all only90 only21 only20; do
    for bk in none one; do
        mk_off_open "$var" "$bk"
        want_run=RUN-OPEN; [[ "$var" == only90 || "$var" == only21 ]] && want_run=RUN-CLOSED   # 20 kapalı kök: yetim 90/21 yükü açmaz (auth_request yok)
        assert_eq "$(_shut)|$(_st)|$(_run)" "OPEN|off|${want_run}" "A0 [${var}/yedek=${bk}]: kurulum: diskte açık iz, kayıt off (çalışan ${want_run})"
        _ps
        n=0; [[ "$bk" == one ]] && n=1
        assert_eq "$PSRC|$(_shut)|$(_st)|$(_run)|$(_bkn)|$(_supn)|${PSCL}" "10|SHUT|off|RUN-CLOSED|0|${n}|1" "A [${var}/yedek=${bk}]: rc 10, 403 kökü, kayıt off, çalışan KAPALI, yedek geri yüklenmedi (.superseded=${n}), kapatıldı işareti 1"
    done
done

echo "── B: kontroller — kapalı alan / açık alan davranışı değişmez ──"
reset_all; _on; _off; fm_sim_reload
before=$(_snap)
_ps
assert_eq "$PSRC|$(_shut)|$(_st)|${PSCL}" "0|SHUT|off|0" "B1: kayıt off + disk kapalı: no-op (rc 0)"
assert_eq "$(_snap)" "$before" "B1: ... disk ve kayıt DEĞİŞMEDİ"
reset_all; _on; fm_sim_reload
_ps
assert_eq "$PSRC|$(_shut)|$(_st)|$(_run)|${PSCL}" "10|OPEN|on|RUN-OPEN|0" "B2: kayıt on + php 8.3 → 8.4: soket güncellendi, alan AÇIK kalır, kapatıldı işareti 0"
assert_contains "$(cat "$F90")" "php8.4-fpm-example_com.sock" "B2: 90 yeni PHP soketine bakıyor"
reset_all; _on; fm_sim_reload
php_now=$(sed -n 's/^php_version //p' "$MAN" | head -1)
( _domconf_fm_auth_sock_sync example.com "$php_now" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(_shut)" "0|OPEN" "B3: kayıt on + aynı PHP sürümü: no-op (rc 0), alan AÇIK kalır"
reset_all
( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; assert_eq "$?" "0" "B4: kayıt YOK: no-op (KAYITSIZ alan php-switch'te yazılmaz)"

echo "── C: kapatılamıyorsa rc≠0 ve 'FM HÂLÂ AÇIK OLABİLİR' ──"
mk_off_open all none
NGINX_TEST_RC=1
_ps
assert_ne "$PSRC" "10" "C1: nginx -t düşer: php-switch kapatmayı BAŞARILI saymaz (rc ${PSRC})"
assert_ne "$PSRC" "0" "C1: ... rc 0 DEĞİL"
assert_contains "$(strip < "$OUTF")" "FM HÂLÂ AÇIK OLABİLİR" "C1: ileti FM HÂLÂ AÇIK OLABİLİR der"
assert_eq "$PSCL" "0" "C1: kapatıldı işareti 0"
NGINX_TEST_RC=0

echo "── D: çağıran gerçeği söyler ──"
blk=$(sed -n '/_domconf_fm_auth_sock_sync "\$domain" "\$new_ver"/,/esac/p' "${REPO_ROOT}/lib/domain.sh")
assert_contains "$blk" "_DOMCONF_FM_SWITCH_CLOSED" "D1: lib/domain.sh php-switch kapatma işaretini okur"
assert_contains "$blk" "KAPATILDI" "D2: kapatma durumunda ileti 'KAPATILDI' der"
assert_contains "$blk" "soketi php" "D3: soket güncellemesi iletisi yalnız gerçekten güncellendiğinde basılır"
assert_eq "$(grep -c '10) info "fm-auth soketi php' "${REPO_ROOT}/lib/domain.sh")" "0" "D4: rc 10'u koşulsuz 'soket çekildi' diye basan eski satır YOK"

test_summary
