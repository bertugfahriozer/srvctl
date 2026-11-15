#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9/a1b (qalab9-L1 regresyonu) — işaretsiz ("yumuşak") alanda geri alma sonrası kapanış doğrulaması SESSİZCE ATLANMAZ.
#  Kayıt `on`, acil işareti yok, 20 = TANINMAYAN ama 403 veren yapısal kök (f_dirline = +add_header, f_include), 90/21 yok;
#  yazıcı (repair / fm-root) 'on'u yeniden üretirken nginx -t'de durur, üçüncü taraf reload staged AÇIK'ı yükler, sonra INT/TERM/HUP.
#  F8: çalışan KAPALI; F9/a1: disk eski kapalı sahte köke dönüyordu ama ÇALIŞAN nginx AÇIK kalıyordu (iletisiz).
#  F9b (§15/33): OTOMATİK yazıcılar (repair / fm-root) artık tanınmayan 20'li 'on' kaydından AÇIK yazmaz (403 kökü yazar) → yumuşak alana AÇIK yazan
#  tek yazıcı AÇIK `fm-auth on`'dur; L1/Y senaryolarının yarıda kesilen yazıcısı `on`a çevrildi, repair/fm-root için yeni beklenti (açmaz) eklendi.
#  Kural (en katı): disk AÇIK/belirsiz (90/21 var, 20 açık imzalı) → reload YOK + "FM HÂLÂ AÇIK OLABİLİR"; 90/21 yok ve 20 açık imzalı
#  değil → çalışan durum SONDALANIR; AÇIK/bilinmiyor ise reload + settled sonda; kapanmazsa "FM HÂLÂ AÇIK OLABİLİR" rc≠0.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
export SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
ALTD="${SRVCTL_FM_EMERGENCY_DIR}"
list_all_domains() { printf '%s\n' example.com; }

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_out() { cat "$OUTF"; }
_disk() { printf '%s%s' "$(_exists "$F90")" "$(_exists "$F21")"; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_repair() { ( _domconf_fm_auth_repair example.com "${1:-${DEFAULT_PHP_VERSION}}" 1 ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
reset_all() { rm -rf "$ALTD"; _fm_reset; rm -f "${FM_STUBS}"/*.flag "${FM_STUBS}/trig" "${FM_STUBS}/arm" "${FM_STUBS}/hk" "${FM_STUBS}/hook.out"; }

# yapısal sahte kök: 403 veren ama tanınmayan (srvctl kökü + ek direktif)
fake20() {   # fake20 <f_dirline|f_include|open|none>
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        f_dirline) { printf '%s\n' "$good"; echo 'add_header X-Foo bar;'; } > "$F20" ;;
        f_include) : > "${FM_STUBS}/empty.inc"; { printf '%s\n' "$good"; echo "include ${FM_STUBS}/empty.inc;"; } > "$F20" ;;
        none)      rm -f "$F20" ;;
    esac
    [[ -f "$F20" ]] && chmod 644 "$F20"
    rm -f "$F90" "$F21"; fm_sim_reload
}

# ═══════════════════════════ L1 (uçtan uca): yazıcı yarıda kesilir, üçüncü taraf reload staged AÇIK'ı yükledi ═══════════════════════════
PIDF="${FM_STUBS}/pid"; CNT="${FM_STUBS}/cnt"
_sig_run() { ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$1"; shift; "$@" ) >"$OUTF" 2>&1; }
_hook_l1() {
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT"
    if (( n == 1 )); then fm_sim_reload; kill -"$KILL_SIG" "$KILL_TARGET"; fi
}
for v in f_dirline f_include; do
  for sig in INT TERM HUP; do
    for w in on repair fmroot; do
        reset_all; _on; fake20 "$v"; rm -f "$CNT"
        _fmprov_load example_com
        # F9b (§15/33): kayıt 'on' + tanınmayan 20 = sınıf 4 (kapalı sayılır; otomatik yollar açmaz). Açık yazıcı yalnız `fm-auth on`.
        assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "L1 [${v}/${sig}/${w}]: ön koşul: kayıt on, işaret yok, sahte kök kanıt/lookalike DEĞİL → F9b sınıf 4 (otomatik yol açmaz)"
        assert_eq "$(_disk)|$(_run)" "yokyok|RUN-CLOSED" "L1 [${v}/${sig}/${w}]: ön koşul: 90/21 yok, çalışan KAPALI (403 veren kök)"
        NGINX_T_HOOK=_hook_l1
        case "$w" in
            on)     _sig_run "$sig" _domconf_fm_auth example.com on "--script=${SCRIPT}" ;;
            repair) _sig_run "$sig" _domconf_fm_auth_repair example.com 8.4 1 ;;
            fmroot) _sig_run "$sig" _domconf_fm_root_cmd example.com --apply ;;
        esac; wrc=$?
        NGINX_T_HOOK=""
        want=130; [[ "$sig" == TERM ]] && want=143; [[ "$sig" == HUP ]] && want=129
        assert_eq "$wrc" "$want" "L1 [${v}/${sig}/${w}]: çıkış kodu sinyal kodu"
        assert_eq "$(_disk)" "yokyok" "L1 [${v}/${sig}/${w}]: disk eski (90/21 yok) durumuna döndü"
        assert_eq "$(_run)" "RUN-CLOSED" "L1 [${v}/${sig}/${w}]: ÇALIŞAN nginx KAPALI (F9/a1: RUN-OPEN, iletisiz)"
        if [[ "$w" == on ]]; then
            assert_contains "$(strip <<< "$(_out)")" "çalışan durum KAPALI imzası (403)" "L1 [${v}/${sig}/${w}]: çalışan durum yeniden kapatıldı ve SÖYLENDİ (sessiz değil)"
        else
            # F9b: repair/fm-root zaten 403 kökü yazıyordu (AÇIK değil): üçüncü taraf reload'u KAPALI yükler, "FM HÂLÂ AÇIK" iletisi doğru DEĞİLDİR
            assert_not_contains "$(strip <<< "$(_out)")" "FM HÂLÂ AÇIK" "L1 [${v}/${sig}/${w}]: otomatik yol AÇIK yazmadı: 'FM HÂLÂ AÇIK' iletisi YOK"
        fi
    done
  done
done

# ═══════════════════════════ birim: yumuşak alan, kanıt yok — diske/çalışan duruma göre dal ═══════════════════════════
# _domconf_fm_reclose_verify'ı yumuşak (işaretsiz açık yazım) alanla doğrudan çağırır; disk/çalışan durumu elle kurulur.
softcase() {   # softcase <ad> <disk: fake|open|none|openroot> <çalışan: closed|open|none> [reload rc]
    local name="$1" disk="$2" run="$3" rrc="${4:-0}"
    reset_all; _on
    case "$disk" in
        fake)     fake20 f_dirline ;;
        none)     fake20 none ;;
        open)     : ;;                                   # _on: 90/21/20 AÇIK
        symlink)  fake20 f_dirline; mv "$F20" "${F20}.real"; ln -s "${F20}.real" "$F20" ;;
        dir)      fake20 none; mkdir "$F20" ;;
        openroot) fake20 f_dirline; printf '%s\n' 'auth_request /x;' >> "$F20"; rm -f "$F90" "$F21" ;;
    esac
    case "$run" in
        closed) _domconf_fm_render_off example_com > "${FM_STUBS}/off20"; rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"; cp "${FM_STUBS}/off20" "$FM_RUNNING/20-srvctl-fm-upload.conf" ;;
        open)   rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"; cp "${FM_STUBS}/open20" "$FM_RUNNING/20-srvctl-fm-upload.conf" ;;
        none)   rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING" ;;
    esac
    SYSTEMCTL_RC="$rrc"
    r0=$(_reloads)
    _FMRV_SOFT=" example.com "; _FMRV_CTX="geri alma"
    ( _domconf_fm_reclose_verify 0 example.com ) >"$OUTF" 2>&1; SRC=$?
    SYSTEMCTL_RC=0
    SRL=$(( $(_reloads) - r0 ))
}
# AÇIK çalışan görüntü şablonu: önce bir AÇIK yazım yap, 20'yi sakla
reset_all; _on; cp -p "$F20" "${FM_STUBS}/open20"

softcase U1 open open
assert_eq "$SRC|$SRL" "1|0" "U1: yumuşak alan, disk AÇIK (90/21 duruyor): reload YOK, rc 1 (yarım/AÇIK disk çalışan nginx'e yüklenmesin)"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U1: dürüst ileti"
assert_contains "$(_out)" "nginx yeniden YÜKLENMEDİ" "U1: reload yapılmadığı söylenir"

softcase U1b openroot open
assert_eq "$SRC|$SRL" "1|0" "U1b: 90/21 yok ama 20 AÇIK imzalı (auth_request): reload YOK, rc 1"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U1b: dürüst ileti"

# 90 YA DA 21 tek başına varsa (20 kapalı-görünümlü): disk AÇIK sayılır
for only in 90 21; do
    softcase U1e-${only} fake open
    if [[ "$only" == 90 ]]; then : > "$F90"; else : > "$F21"; fi
    r0=$(_reloads); _FMRV_SOFT=" example.com "; ( _domconf_fm_reclose_verify 0 example.com ) >"$OUTF" 2>&1; SRC=$?; SRL=$(( $(_reloads) - r0 ))
    assert_eq "$SRC|$SRL" "1|0" "U1e [yalnız ${only}]: 90/21'den BİRİ duruyor (20 kapalı-görünümlü): disk AÇIK, reload YOK, rc 1"
    assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U1e [yalnız ${only}]: dürüst ileti"
    rm -f "$F90" "$F21"
done

softcase U1c symlink open
assert_eq "$SRC|$SRL" "1|0" "U1c: 20 sembolik bağ (içeriği bilinemez): reload YOK, rc 1"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U1c: dürüst ileti"
rm -f "${F20}.real"
softcase U1d dir open
assert_eq "$SRC|$SRL" "1|0" "U1d: 20 normal dosya değil (dizin): reload YOK, rc 1"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U1d: dürüst ileti"
rmdir "$F20" 2>/dev/null

softcase U2 fake open
assert_eq "$SRC|$SRL|$(_run)" "0|1|RUN-CLOSED" "U2: disk kapalı-görünümlü (90/21 yok), çalışan AÇIK: reload + sonda, KAPALI (F9/a1: sessiz atlama)"
assert_contains "$(strip <<< "$(_out)")" "çalışan durum KAPALI imzası (403)" "U2: iletilir"

softcase U3 fake closed
assert_eq "$SRC|$SRL" "0|0" "U3: disk kapalı-görünümlü, çalışan KAPALI: sonda yeterli, reload gerekmez"
assert_contains "$(strip <<< "$(_out)")" "çalışan durum KAPALI imzası (403)" "U3: sessiz DEĞİL (sondanın sonucu söylenir)"

softcase U4 fake open 1
assert_eq "$SRC" "1" "U4: çalışan AÇIK ve reload BAŞARISIZ: rc 1"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U4: dürüst ileti"

softcase U5 fake none
assert_eq "$SRC|$SRL|$(_run)" "0|1|RUN-CLOSED" "U5: 20 var (tanınmayan) + çalışan durum KAPALI imzası vermiyor (çalışan görüntü boş): reload + sonda, KAPALI"

softcase U5b fake none 1
assert_eq "$SRC" "1" "U5b: aynı, reload BAŞARISIZ: KAPALI doğrulanamaz, rc 1"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U5b: dürüst ileti"

softcase U6 none none
assert_eq "$SRC|$SRL" "0|0" "U6: disk BOŞ (hiç kurulmamış alanın başarısız ilk 'on'u), çalışan AÇIK imzası yok: reload GEREKMEZ (gereksiz nginx -t yok), rc 0"
assert_contains "$(strip <<< "$(_out)")" "disk BOŞ" "U6: sessiz DEĞİL (sonda sonucu söylenir)"

softcase U6b none open
assert_eq "$SRC|$SRL|$(_run)" "0|1|RUN-NONE" "U6b: disk BOŞ ama çalışan AÇIK (üçüncü taraf reload staged AÇIK'ı yükledi): reload + sonda, artık AÇIK imzası yok"

softcase U6c none open 1
assert_eq "$SRC" "1" "U6c: disk BOŞ, çalışan AÇIK, reload BAŞARISIZ: rc 1"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "U6c: dürüst ileti"

# karışık işlem (iki alan): biri kapalı-disk KANITLI, diğeri yumuşak ve diski AÇIK → reload HİÇBİR alanda yapılmaz (host geneli reload açık diski yüklemesin)
OTH_DIR="${SRVCTL_NGINX_CUSTOM_DIR}/other_com"
reset_all; _on; mkdir -p "$OTH_DIR"; _domconf_fm_render_off other_com > "$OTH_DIR/20-srvctl-fm-upload.conf"; chmod 644 "$OTH_DIR/20-srvctl-fm-upload.conf"
fm_sim_reload; cp -p "${FM_STUBS}/open20" "$FM_RUNNING/20-srvctl-fm-upload.conf"   # çalışan: AÇIK; example_com diski: AÇIK (90/21/20)
r0=$(_reloads); _FMRV_SOFT=" example.com "; _FMRV_CTX="geri alma"
( _domconf_fm_reclose_verify 0 other.com example.com ) >"$OUTF" 2>&1; SRC=$?; SRL=$(( $(_reloads) - r0 ))
assert_eq "$SRC|$SRL" "1|0" "M1: kanıtlı alan + diski AÇIK yumuşak alan: reload YOK (host geneli), rc 1 (yumuşak alan 2'ye çıkarmaz)"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "M1: dürüst ileti"
rm -rf "$OTH_DIR"

# S1 güvencesi (hard alan = acil işareti VAR, yumuşak DEĞİL): diski açık/yarım + kanıt yok → reload YOK, rc 2 (BOZULMADI)
for how in open openroot; do
    softcase H-$how $how open; reset_all; _on
    [[ "$how" == openroot ]] && { fake20 f_dirline; printf '%s\n' 'auth_request /x;' >> "$F20"; rm -f "$F90" "$F21"; }
    printf 'srvctl-fm-emergency v1\n' > "${SRVCTL_STATE_DIR}/_fm-auth/example_com.emergency"; chmod 600 "${SRVCTL_STATE_DIR}/_fm-auth/example_com.emergency"
    rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"; cp "${FM_STUBS}/open20" "$FM_RUNNING/20-srvctl-fm-upload.conf"
    r0=$(_reloads); _FMRV_SOFT=" "; ( _domconf_fm_reclose_verify 0 example.com ) >"$OUTF" 2>&1; SRC=$?; SRL=$(( $(_reloads) - r0 ))
    assert_eq "$SRC|$SRL" "2|0" "S1 hard [${how}]: acil işaretli alan, kanıt yok: reload YOK, rc 2 (yumuşak olmayan alanın güvencesi)"
    assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "S1 hard [${how}]: dürüst ileti"
done

# hard alan (acil işareti) + kapalı-görünümlü ama TANINMAYAN kök + çalışan AÇIK: yumuşak muamelesi YOK → reload yok, rc 2
reset_all; _on; fake20 f_dirline; printf 'srvctl-fm-emergency v1\n' > "${SRVCTL_STATE_DIR}/_fm-auth/example_com.emergency"; chmod 600 "${SRVCTL_STATE_DIR}/_fm-auth/example_com.emergency"
rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"; cp "${FM_STUBS}/open20" "$FM_RUNNING/20-srvctl-fm-upload.conf"
r0=$(_reloads); _FMRV_SOFT=" "; ( _domconf_fm_reclose_verify 0 example.com ) >"$OUTF" 2>&1; SRC=$?; SRL=$(( $(_reloads) - r0 ))
assert_eq "$SRC|$SRL" "2|0" "S1 hard [fake root]: acil işaretli alan, 20 tanınmayan: reload YOK, rc 2 (yumuşak muamelesi yalnız işaretsiz alana)"

# ═══════════════════════════ F9/a1c (QL9-S2 / qalab2 A1B-Y): YEDEĞİNDE 90 VAR, 21 yok, 20 tanınan kapalı kök ═══════════════════════════
# Kayıt on, diskte yetim 90 (+ tanınan kapalı 20), çalışan KAPALI. Yazıcı yarıda kesilir, üçüncü taraf reload staged AÇIK'ı yükler.
# Eski: yedekte 90 var → alan doğrulama listesine hiç girmedi → T1=OPEN ve iletisiz. Şimdi: liste → disk AÇIK/belirsiz (90 var) → reload YOK
# + "FM HÂLÂ AÇIK OLABİLİR" (rc ≠ 0), sessiz yol yok.
oauth_setup() {
    reset_all; _on
    _domconf_fm_render_off example_com > "$F20"; chmod 644 "$F20"; rm -f "$F21"; fm_sim_reload
}
for sig in INT TERM; do
    oauth_setup; rm -f "$CNT"
    assert_eq "$(_disk)|$(_run)" "varyok|RUN-CLOSED" "Y [${sig}]: ön koşul: 90 var, 21 yok, çalışan KAPALI"
    NGINX_T_HOOK=_hook_l1
    _sig_run "$sig" _domconf_fm_auth example.com on "--script=${SCRIPT}"; wrc=$?
    NGINX_T_HOOK=""
    want=130; [[ "$sig" == TERM ]] && want=143
    assert_eq "$wrc" "$want" "Y [${sig}]: çıkış kodu sinyal kodu"
    # F9b/a3 (BLOKER-1): ön durum (kayıt on + yetim 90) tanınan srvctl eseri DEĞİL → geri alma yetim 90'ı GERİ KOYMAZ, diski 403 köküne kapatır,
    # çalışan nginx yeniden yüklenir ve sonuç söylenir (önceki beklenti: disk belirsiz bırakılır, "FM HÂLÂ AÇIK OLABİLİR").
    assert_contains "$(strip <<< "$(_out)")" "yeniden KAPATTI" "Y [${sig}]: yedeğinde 90 olsa da alan doğrulanır; geri alma yetim 90'ı geri KOYMAZ, diski kapatır ve SÖYLER (iletisiz DEĞİL)"
    assert_eq "$(_disk)|$(_run)" "yokyok|RUN-CLOSED" "Y [${sig}]: iptal sonrası disk kapalı (90/21 yok), çalışan KAPALI"
done
# F9b: aynı yarım durumda (kayıt on, yetim 90, kapalı 20) OTOMATİK yol (repair) AÇIK yazmaz: 403 kökü yazar, kesinti geri alması ön durumu döndürür, ileti YOK
for sig in INT TERM; do
    oauth_setup; rm -f "$CNT"
    NGINX_T_HOOK=_hook_l1
    _sig_run "$sig" _domconf_fm_auth_repair example.com 8.4 1; wrc=$?
    NGINX_T_HOOK=""
    want=130; [[ "$sig" == TERM ]] && want=143
    assert_eq "$wrc|$(_run)" "$want|RUN-CLOSED" "Y-F9b [${sig}]: repair yetim-90 alanını AÇMAZ: çalışan KAPALI (403 kökü)"
    assert_not_contains "$(strip <<< "$(_out)")" "FM HÂLÂ AÇIK" "Y-F9b [${sig}]: AÇIK yazılmadığı için 'FM HÂLÂ AÇIK' iletisi YOK"
done

test_summary
