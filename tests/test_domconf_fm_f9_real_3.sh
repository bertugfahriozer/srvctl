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
lab_up || { echo "  FAIL lab ayağa kalkmadı"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; }
export SRVCTL_FM_PROBE_HTTP_PORT="$P"
fresh_open || { echo "  FAIL kontrol: srvctl'in GERÇEK ürettiği açık alan gerçek nginx'te 411 + srvctl-fm-open <imza> vermedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); }

PIDF="${FM_STUBS}/s2.pid"   # S2-A'da (1. parça) tanımlanırdı; L1-A/Y-A kancaları kullanır
echo "── L1-A: kayıt 'on' + tanınmayan ama 403 veren yapısal kök (işaretsiz), yazıcı yarıda kesilir + üçüncü taraf reload AÇIK'ı yükler (gerçek nginx) ──"
# F9/a1b: soft (işaretsiz açık yazım) alanda geri alma sonrası sessiz atlama YOK: çalışan nginx KAPALI olmalı ve iletilmeli
l1_fake() {
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        f_dirline) { printf '%s\n' "$good"; echo 'add_header X-Foo bar;'; } > "$F20" ;;
        f_include) : > "$T/extra/empty.inc"; { printf '%s\n' "$good"; echo "include $T/extra/empty.inc;"; } > "$F20" ;;
    esac
    chmod 644 "$F20"; rm -f "$F90" "$F21"
}
CNT1="${FM_STUBS}/l1.cnt"
_hook_l1() {
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT1" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT1"
    if (( n == 1 )); then _third; raw > "${FM_STUBS}/l1.mid"; kill -"$KILL_SIG" "$KILL_TARGET"; fi
}
for v in f_dirline f_include; do
    for sig in TERM INT HUP; do
        for w in on repair fmroot; do
            fresh_open; l1_fake "$v"; _third; rm -f "$CNT1" "${FM_STUBS}/l1.mid"
            r=$(raw); assert_eq "${r%%|*}" "403" "L1-A [${v}/${sig}/${w}] kontrol: tanınmayan kök gerçek nginx'te 403 veriyor"
            NGINX_T_HOOK=_hook_l1
            ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$sig"
              case "$w" in on) _domconf_fm_auth example.com on "--script=${SCRIPT}" ;; repair) _domconf_fm_auth_repair example.com 8.4 1 ;; *) _domconf_fm_root_cmd example.com --apply ;; esac ) >"$OUTF" 2>&1; wrc=$?
            NGINX_T_HOOK=""
            # F9b (§15/33): kayıt 'on' + tanınmayan 20 → OTOMATİK yollar (repair / fm-root) AÇIK yazmaz (403 kökü sahneler): üçüncü taraf reload KAPALI yükler.
            # Staged AÇIK yazan tek yazıcı AÇIK `fm-auth on`'dur (F9/a1b kapanış doğrulaması onun içindir).
            if [[ "$w" == on ]]; then
                assert_eq "$(cat "${FM_STUBS}/l1.mid" 2>/dev/null)" "$OPEN" "L1-A [${v}/${sig}/${w}] kontrol: üçüncü taraf reload staged AÇIK'ı GERÇEKTEN yükledi (gerçek nginx 411)"
            else
                assert_eq "$(cat "${FM_STUBS}/l1.mid" 2>/dev/null)" "$CLOSED" "L1-A [${v}/${sig}/${w}] F9b: otomatik yol AÇIK sahnelemedi: üçüncü taraf reload staged 403 kökünü yükledi (gerçek nginx 403)"
            fi
            case "$sig" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
            assert_eq "$wrc" "$want" "L1-A [${v}/${sig}/${w}]: sinyal çıkış kodu"
            assert_eq "$(raw)" "$CLOSED" "L1-A [${v}/${sig}/${w}]: iptal sonrası gerçek nginx KAPALI (F9/a1: AÇIK kalıyor, iletisiz)"
            assert_eq "$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "yokyok" "L1-A [${v}/${sig}/${w}]: diskte 90/21 YOK"
            if [[ "$w" == on ]]; then
                assert_contains "$(_out)" "çalışan durum KAPALI imzası (403)" "L1-A [${v}/${sig}/${w}]: kapanış SÖYLENDİ (sessiz değil)"
            else
                assert_not_contains "$(_out)" "FM HÂLÂ AÇIK" "L1-A [${v}/${sig}/${w}] F9b: AÇIK yazılmadığı için 'FM HÂLÂ AÇIK' iletisi YOK"
            fi
        done
    done
done

echo "── Y-A (F9/a1c, qalab2 A1B-Y): kayıt 'on', diskte yetim 90 (21 yok) + tanınan kapalı kök; yazıcı yarıda kesilir + üçüncü taraf reload AÇIK'ı yükler (gerçek nginx) ──"
# Yedekte 90 var → eskiden alan doğrulama listesine girmiyordu: gerçek nginx AÇIK kalıyor ve çıktı iletisizdi. Şimdi: reload YOK ama "FM HÂLÂ AÇIK OLABİLİR".
for sig in INT TERM; do
    fresh_open; _domconf_fm_render_off example_com > "$F20"; chmod 644 "$F20"; rm -f "$F21"; _third; rm -f "$CNT1" "${FM_STUBS}/l1.mid"
    r=$(raw); assert_eq "${r%%|*}|$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "403|varyok" "Y-A [${sig}] kontrol: 90 var, 21 yok, gerçek nginx KAPALI (403)"
    NGINX_T_HOOK=_hook_l1
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$sig"; _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; wrc=$?
    NGINX_T_HOOK=""
    assert_eq "$(cat "${FM_STUBS}/l1.mid" 2>/dev/null)" "$OPEN" "Y-A [${sig}] kontrol: üçüncü taraf reload staged AÇIK'ı GERÇEKTEN yükledi (gerçek nginx 411)"
    case "$sig" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
    assert_eq "$wrc" "$want" "Y-A [${sig}]: sinyal çıkış kodu"
    # F9b/a3 (BLOKER-1): ön durum (kayıt on + yetim 90) tanınan srvctl eseri DEĞİL → geri alma yetim 90'ı diske GERİ KOYMAZ, diski 403 köküne
    # kapatır, nginx yeniden yüklenir (gerçek nginx KAPALI) ve sonuç söylenir (önceki beklenti: disk belirsiz bırakılır, "FM HÂLÂ AÇIK OLABİLİR").
    assert_contains "$(_out)" "yeniden KAPATTI" "Y-A [${sig}]: geri alma yetim-90 ön durumunu kapattı ve SÖYLEDİ (F9b/a3; eski: disk belirsiz, 'HÂLÂ AÇIK OLABİLİR')"
    assert_eq "$(raw)|$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "${CLOSED}|yokyok" "Y-A [${sig}]: iptal sonrası gerçek nginx KAPALI, diskte 90/21 YOK"
done
# F9b: aynı yarım durumda (kayıt on, yetim 90, tanınan kapalı 20) OTOMATİK yol (repair) AÇIK sahnelemez: staged 403 kökü yüklenir, ileti YOK
for sig in INT TERM; do
    fresh_open; _domconf_fm_render_off example_com > "$F20"; chmod 644 "$F20"; rm -f "$F21"; _third; rm -f "$CNT1" "${FM_STUBS}/l1.mid"
    NGINX_T_HOOK=_hook_l1
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$sig"; _domconf_fm_auth_repair example.com 8.4 1 ) >"$OUTF" 2>&1; wrc=$?
    NGINX_T_HOOK=""
    case "$sig" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
    assert_eq "$wrc|$(cat "${FM_STUBS}/l1.mid" 2>/dev/null)|$(raw)" "$want|$CLOSED|$CLOSED" "Y-A-F9b [${sig}]: repair yetim-90 alanını AÇMAZ: staged 403 kökü yüklendi, iptal sonrası gerçek nginx KAPALI"
    assert_not_contains "$(_out)" "FM HÂLÂ AÇIK" "Y-A-F9b [${sig}]: AÇIK yazılmadığı için 'FM HÂLÂ AÇIK' iletisi YOK"
done

echo "── dışarı-0-istek ──"
assert_eq "$(grep -c '^DENY' "$SHIM_LOG")" "0" "kalkan günlüğünde DENY satırı yok (dışarı istek 0)"
HOSTS=$(grep -o 'https\{0,1\}://[^/ ]*' "$SHIM_LOG" | sed 's#.*://##; s#:.*##' | sort -u | tr '\n' ' ')
assert_eq "$HOSTS" "127.0.0.1 example.com " "kalkan: curl hedeflerinin TAMAMI yerel (127.0.0.1 / --resolve example.com; $(grep -vc '^DENY' "$SHIM_LOG") çağrı)"

test_summary
