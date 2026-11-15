#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9/a1 (QL9-S1, QL9-S2, QL9-M2, QL9-M3, QL9-L1, QL9-L12, qalab9-I2) — kapı-B penceresi, geri alma sinyal tuzağı, status sözleşmesi.
#  S1-a  kapı-B penceresi (QL9 g2 gateB_window.sh tp/none + status_stale_claim.sh'ın KALICI mock karşılığı): acil kapatma yazıcının
#        kapı B'si ile stage dosya yazımı arasına düşer (`_fmprov_write` kancası); yazıcının kapı-reddi geri alması diski kapatır,
#        reload eder, çalışan durum KAPALI; ilgisiz sonraki reload alanı AÇMAZ
#  S1-b  `_domconf_fm_em_state_guard`: kilit tutuluyorsa sahibinin .bk.*'sine DOKUNMAZ; kilit serbestse / "held" ise ayırır
#  S1-c  `_domconf_fm_restore_entry`: yedek yok/geçersiz olsa da işaretli alanın diski KOŞULSUZ kapanır
#  S1-d  `_domconf_fm_reclose_verify`: rrc≠0'da reload + sonda YALNIZ kapalı-disk kanıtı varsa; yoksa reload YOK + rc 6 + "OLABİLİR"
#  S1-e  iletiler yalnız gerçekten kapalıysa "KAPALI kalır / disk yeniden KAPATILDI" der; status F8-M1 kolu kanıta sorar
#  S2    `_domconf_fm_fail_restore` sinyal tuzağını reclose BİTENE kadar kaldırmaz (rev sig2.sh F1) ve `apply_abort` ikinci sinyali
#        zararsız kılar (sig2.sh A1/A2; R01)
#  M2    `status` "kayıt AÇIK + çalışan KAPALI" rc 4 (test_domconf_fm_emergency.sh F3 de sabitler)
#  M3    yaşayan mutantları öldüren davranış testleri: R02/R03 (ikinci konum işareti), R04 (grup-yazma biti), R06/R8 (settled sonda),
#        R07/R1 (reclose "kapalı + reload yok" iletisi), R09 (_FMP_LOCK_TIMED_OUT sıfırlaması), K1 (satır içi `#` yorum)
#  L1    işaretsiz kapalı alanda başarısız `fm-auth on` + üçüncü taraf reload: geri alma çalışan nginx'i de kapatır
#  L12   açık `fm-auth on` eşzamanlı acil kapatma sonrası "AÇILDI rc 0" DEMEZ
#  I2    (test_domconf_fm_f9_cosmetic.sh) kayıt on + kozmetik bozuk kapalı kök: 8 yolun hiçbiri alanı AÇMAZ
#        status kurcalama raporlar, 'fm-root --apply' önermez
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
MARK="${SD}/example_com.emergency"
ALTD="${SRVCTL_FM_EMERGENCY_DIR}"
ALTMARK="${ALTD}/example_com.emergency"
list_all_domains() { printf '%s\n' example.com; }

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_closed() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]]; }
_disk() { printf '%s%s%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_closed && echo K || echo A)"; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_tamp() { find "$CUR_DIR" -maxdepth 1 -name '*.srvctl-tampered' 2>/dev/null | wc -l | tr -d ' '; }
_ld() { _fmprov_load example_com; RG="$_FMP_REGION"; SC="$_FMP_SCRIPT"; PH="$_FMP_PHP"; MS="$_FMP_MODSEC"; }
_placemark() { printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"; }
_repair() { ( _domconf_fm_auth_repair example.com "${1:-${DEFAULT_PHP_VERSION}}" 1 ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
_phpswitch() { ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; }
_batch() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 0 ) >"$OUTF" 2>&1; ( systemctl reload nginx ) >/dev/null 2>&1; }
_mk_stale_bk() {   # açık pre-state yedeği (kesintiye uğramış bir yazımdan kalmış)
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" ]]; then cp -p "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
reset_all() { rm -rf "$ALTD"; _fm_reset; rm -f "${FM_STUBS}"/*.flag "${FM_STUBS}/trig" "${FM_STUBS}/arm" "${FM_STUBS}/hk" "${FM_STUBS}/hook.out"; }

# ═══════════════════════════ S1-a: kapı-B penceresi (QL9 g2 gateB_window.sh + status_stale_claim.sh) ═══════════════════════════
# yazıcı (repair; TX_ACTION=repair) stage'de yedeği aldı ve kapı B'yi GEÇTİ; tam o anda acil kapatma (kilit yazıcıda: FLOCK_RC=1 →
# kilit aşaması zaman aşımı, rc 4) işareti koyar, diski kapatır, nginx'i yükler ve yazıcının .bk.*'sine DOKUNMAMALI. Yazıcı sonra
# AÇIK 90/21/20 yazar → commit kapısı reddeder → geri alma yedeği geri koyar + işaretli alanı KAPATIR + reload + sonda.
eval "_f9_orig_fmprov_write() $(declare -f _fmprov_write | sed 1d)"
F9_WRITE_HOOK=""
_fmprov_write() {
    if [[ -n "$F9_WRITE_HOOK" && ! -e "${FM_STUBS}/trig" && "${2:-}" == on ]]; then
        : > "${FM_STUBS}/trig"
        "$F9_WRITE_HOOK"
    fi
    _f9_orig_fmprov_write "$@"
}
# acil kapatma, yazıcının kapı B'si ile ilk yazım arasında (kilit yazıcıda)
_hook_emergency_in_window() {
    ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/em.out" 2>&1; echo "$?" > "${FM_STUBS}/em.rc"
    printf 'bk=%s superseded=%s marker=%s disk=%s run=%s\n' "$(_bkn)" "$(_supn)" "$(_exists "$MARK")" "$(_disk)" "$(_run)" > "${FM_STUBS}/hook.out"
    : > "${FM_STUBS}/arm"
}
# yazıcının nginx -t'sinde üçüncü taraf reload (diskteki AÇIK 90/21/20'yi çalışan nginx'e yükler)
_h_third() { if [[ -e "${FM_STUBS}/arm" && ! -e "${FM_STUBS}/hk" ]]; then : > "${FM_STUBS}/hk"; fm_sim_reload; fi; }
for var in tp none; do
    reset_all; _on; fm_sim_reload; _ld
    assert_eq "$(_disk)|$(_run)" "varvarA|RUN-OPEN" "S1-a [${var}]: ön koşul: alan AÇIK (disk ve çalışan)"
    F9_WRITE_HOOK=_hook_emergency_in_window
    if [[ "$var" == tp ]]; then NGINX_T_HOOK=_h_third; else NGINX_T_HOOK=""; fi
    r0=$(_reloads)
    _DOMCONF_FM_TX_ACTION=repair
    ( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
    _DOMCONF_FM_TX_ACTION=""; NGINX_T_HOOK=""; F9_WRITE_HOOK=""
    assert_eq "$(cat "${FM_STUBS}/em.rc")" "4" "S1-a [${var}]: acil kapatma rc 4 (kilit yazıcıda: kapanış kilit altında doğrulanamadı)"
    assert_eq "$(cat "${FM_STUBS}/hook.out")" "bk=1 superseded=0 marker=var disk=yokyokK run=RUN-CLOSED" "S1-a [${var}]: acil bitince yazıcının .bk.*'si YERİNDE (QL9: .superseded'e ayrılıyordu), işaret var, disk+çalışan KAPALI"
    assert_eq "$wrc|$(_disk)|$(_run)|$(_bkn)|$(_supn)" "4|yokyokK|RUN-CLOSED|0|0" "S1-a [${var}]: yazıcı kapı reddi: rc 4, disk KAPALI, çalışan KAPALI (QL9: varvarA + RUN-OPEN), yedek tüketildi, ayrılmış yedek yok"
    assert_contains "$(_out)" "alanı yeniden KAPATTI (kapalı-disk kanıtı var" "S1-a [${var}]: yazıcı 'yeniden KAPATTI' der — kanıt gerçek (disk gerçekten kapalı)"
    assert_not_contains "$(_out)" "alan KAPALI kalır" "S1-a [${var}]: tx_commit kapısı koşulsuz 'alan KAPALI kalır' DEMEZ"
    assert_eq "$(_exists "$MARK")" "var" "S1-a [${var}]: işaret yerinde"
    out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); src=$?
    out=$(strip <<< "$out")
    assert_eq "$src" "0" "S1-a [${var}]: status rc 0 (disk kapalı kanıtlı + çalışan KAPALI)"
    assert_contains "$out" "diskle tutarlı" "S1-a [${var}]: 'diskle tutarlı' — şimdi diskten türetilir ve doğrudur"
    fm_sim_reload
    assert_eq "$(_run)" "RUN-CLOSED" "S1-a [${var}]: ilgisiz sonraki reload (certbot vb.) alanı AÇMAZ (QL9: AÇIK)"
done

# kontrol: acil kapatma yazıcıdan SONRA gelirse kilit aşaması zaten yeniden kapatır (probe gateB_window2 adım 4)
reset_all; _on; fm_sim_reload; _ld
F9_WRITE_HOOK=""
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; erc=$?
assert_eq "$erc|$(_disk)|$(_run)" "0|yokyokK|RUN-CLOSED" "S1-a kontrol: sıralı acil kapatma rc 0, disk+çalışan KAPALI"

# ═══════════════════════════ S1-a2: status — işaret var + diskte AÇIK 20 (status_stale_claim.sh) ═══════════════════════════
reset_all; _on
cp -p "$F20" "${FM_STUBS}/open20"; _domconf_fm_render_off example_com > "$F20"; fm_sim_reload; cp -p "${FM_STUBS}/open20" "$F20"
rm -f "$F90" "$F21"; _placemark
out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); src=$?; out=$(strip <<< "$out")
assert_eq "$(_run)" "RUN-CLOSED" "S1-a2: ön koşul: çalışan KAPALI (kapalı kök yüklü), diskte AÇIK 20 (90/21 yok), işaret var"
assert_not_contains "$out" "fm-auth STALE (KAPALI KANITI):" "S1-a2: status diskteki AÇIK 20 için 'KAPALI KANITI' DEMEZ (QL9: diyordu)"
assert_contains "$out" "KAPALI KANITI YOK" "S1-a2: 'KAPALI KANITI YOK' söyler"
assert_not_contains "$out" "diskle tutarlı" "S1-a2: 'diskle tutarlı' DEMEZ (disk AÇIK 20 taşıyor)"
assert_contains "$out" "off --emergency" "S1-a2: çıkış yolu: off --emergency"
assert_eq "$src" "1" "S1-a2: rc 1 (tutarsız)"
# kontrol: gerçekten ESKİ biçimli kapalı kök → 'KAPALI KANITI' (F8-M1 davranışı korunur)
reset_all; _on; _domconf_fm_render_off example_com > "$F20"; _domconf_fm_render_off example_com | sed 's/srvctl-fm-closed [0-9a-f]\{12\}/srvctl-fm-closed 0123456789ab/' > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; _placemark; fm_sim_reload
out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "fm-auth STALE (KAPALI KANITI):" "S1-a2 kontrol: gerçekten tanınan ESKİ kapalı kök → 'KAPALI KANITI' (F8-M1 korunur)"

# ═══════════════════════════ S1-b: state_guard — yalnız sahibi ölü yedek bayattır ═══════════════════════════
reset_all; _on; _mk_stale_bk AAAAAA
FLOCK_RC=1; _domconf_fm_em_state_guard example_com; FLOCK_RC=0
assert_eq "$(_bkn)|$(_supn)|$_FME_SUPERSEDED" "1|0|0" "S1-b: kilit TUTULUYOR (sahibi sürüyor): .bk.* ayrılmaz"
FLOCK_RC=1; _domconf_fm_em_state_guard example_com held; FLOCK_RC=0
assert_eq "$(_bkn)|$(_supn)|$_FME_SUPERSEDED" "0|1|1" "S1-b: 'held' (çağıran kilidi tutuyor ⇒ eldeki yedek ölü sahibin): ayrılır"
reset_all; _on; _mk_stale_bk BBBBBB
_domconf_fm_em_state_guard example_com
assert_eq "$(_bkn)|$(_supn)|$_FME_SUPERSEDED" "0|1|1" "S1-b: kilit SERBEST (sahibi ölü): ayrılır"
assert_contains "$(cat "$FLOCK_LOG")" "-n 9" "S1-b: kilitsiz çağrı kilidi engellemeden (flock -n) yoklar"
reset_all; _on; _mk_stale_bk CCCCCC
PATH_SAVE="$PATH"; _fl() { cat "$FLOCK_LOG" | wc -l | tr -d ' '; }
# flock YOKSA sahip bilinemez → dokunma
( PATH="/usr/bin:/bin"; if command -v flock >/dev/null 2>&1; then echo "SKIP"; else _domconf_fm_em_state_guard example_com; echo "$(_bkn)" > "${FM_STUBS}/noflock.n"; fi ) > "${FM_STUBS}/noflock.out" 2>&1
if grep -q SKIP "${FM_STUBS}/noflock.out"; then echo "  SKIP S1-b: flock'suz kol (sistemde gerçek flock var)"; else assert_eq "$(cat "${FM_STUBS}/noflock.n")" "1" "S1-b: flock YOK: sahip bilinemez → .bk.* ayrılmaz"; fi

# yoklama anında kilit TUTULUYORDU (yazıcı sürüyordu) ama acil kilit aşamasını alınca yazıcı bitmiş/ölmüş: kilit aşaması ('held')
# eldeki yedeği ölü sahibin sayar ve ayırır (kilitsiz ilk çağrı dokunmadı, kilitli ikinci çağrı ayırdı)
cat > "${FM_STUBS}/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
case " $* " in *" -n "*) [[ -e "${FLOCK_N_FAIL:-/nonexistent}" ]] && exit 1 ;; esac
exit "${FLOCK_RC:-0}"
FLOCKEOF
chmod +x "${FM_STUBS}/flock"
reset_all; _on; fm_sim_reload; _mk_stale_bk AAAAAA
: > "${FM_STUBS}/nfail.flag"; export FLOCK_N_FAIL="${FM_STUBS}/nfail.flag"
_e --emergency; erc=$?
unset FLOCK_N_FAIL; rm -f "${FM_STUBS}/nfail.flag"
assert_eq "$erc|$(_bkn)|$(_supn)" "0|0|1" "S1-b: yoklamada kilit tutuluyordu (.bk'ya dokunulmadı) ama kilit aşamasında sahibi artık yok: 'held' çağrısı AYIRDI (rc 0)"
cat > "${FM_STUBS}/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
exit "${FLOCK_RC:-0}"
FLOCKEOF
chmod +x "${FM_STUBS}/flock"

# ═══════════════════════════ S1-c: restore_entry — yedek yok/geçersiz ama işaret var ⇒ disk KOŞULSUZ kapanır ═══════════════════════════
reset_all; _on; fm_sim_reload; _ld; _placemark
_FMT_BK=("${SD}/.bk.example_com.GONE00"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com)
_domconf_fm_restore_entry 0; rrc=$?
assert_eq "$rrc|$(_disk)" "1|yokyokK" "S1-c: yedek YOK + işaret var: restore_entry rc 1 AMA disk KAPATILDI (QL9: AÇIK 90/21/20 kalıyordu)"
_domconf_fm_tx_reset
reset_all; _on; fm_sim_reload   # işaret YOK: yedek yoksa diske DOKUNULMAZ
_FMT_BK=("${SD}/.bk.example_com.GONE00"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com)
_domconf_fm_restore_entry 0; rrc=$?
assert_eq "$rrc|$(_disk)" "1|varvarA" "S1-c kontrol: işaret YOK + yedek yok: rc 1 ve diske dokunulmadı (açık alan açık kalır)"
_domconf_fm_tx_reset

# ═══════════════════════════ S1-d: reclose_verify — rrc≠0'da kanıt koşullu ═══════════════════════════
# geri yükleme BAŞARISIZ ama disk kapalı kanıtlı (restore_entry kapatmayı yaptı): reload + sonda yapılır, çalışan KAPALI olur
reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
# yazıcı açık yazdı (stage) ve geri alma (stub) kapatır ama rc 1 döner
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
eval "_f9_orig_rfb() $(declare -f _domconf_fm_restore_from_bk | sed 1d)"
_domconf_fm_restore_from_bk() { _domconf_fm_em_close_disk "$CUR_DIR" example_com; return 1; }
r0=$(_reloads)
( _domconf_fm_fail_restore 4 ) >"$OUTF" 2>&1; frc=$?
_domconf_fm_restore_from_bk() { _f9_orig_rfb "$@"; }
assert_eq "$frc|$(_disk)|$(_run)|$(( $(_reloads) - r0 ))" "6|yokyokK|RUN-CLOSED|1" "S1-d: rrc≠0 + disk kapalı KANITLI: rc 6, reload YAPILDI, çalışan KAPALI (QL9: reload 'skipped', çalışan AÇIK kalıyordu)"
assert_contains "$(_out)" "alanı yeniden KAPATTI (kapalı-disk kanıtı var" "S1-d: 'yeniden KAPATTI' yalnız kanıt varken"
# geri yükleme BAŞARISIZ ve disk AÇIK (kanıt YOK): reload YOK, rc 6, "OLABİLİR"; 'disk yeniden KAPATILDI' DENMEZ
reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
_domconf_fm_restore_from_bk() { return 1; }
r0=$(_reloads)
( _domconf_fm_fail_restore 4 ) >"$OUTF" 2>&1; frc=$?
_domconf_fm_restore_from_bk() { _f9_orig_rfb "$@"; }
assert_eq "$frc|$(_disk)|$(_run)|$(( $(_reloads) - r0 ))" "6|varvarA|RUN-OPEN|0" "S1-d: rrc≠0 + disk AÇIK (kanıt yok): rc 6, reload YOK (yarım/AÇIK disk yüklenmez)"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR — geri alma sonrası example.com: diskte KAPALI KÖK KANITI YOK" "S1-d: ileti 'FM HÂLÂ AÇIK OLABİLİR' + neden (kapalı kök kanıtı yok)"
assert_not_contains "$(_out)" "yeniden KAPATILDI" "S1-d: 'disk yeniden KAPATILDI' DENMEZ (QL9: sabit metin diyordu)"
assert_not_contains "$(_out)" "yeniden KAPATTI" "S1-d: 'yeniden KAPATTI' da DENMEZ"
# rrc=0 ama disk kapalı kanıtı yok (işaretli alan, kapatma yazılamadı): rc 6
reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
_domconf_fm_restore_from_bk() { return 0; }
r0=$(_reloads)
( _domconf_fm_fail_restore 3 ) >"$OUTF" 2>&1; frc=$?
_domconf_fm_restore_from_bk() { _f9_orig_rfb "$@"; }
assert_eq "$frc|$(( $(_reloads) - r0 ))" "6|0" "S1-d: rrc=0 ama işaretli alanda kapalı-disk kanıtı YOK: çağıran kodu (3) yerine rc 6, reload YOK"
_domconf_fm_tx_reset

# ═══════════════════════════ S1-e: kapı iletileri (stage kapısı A) ═══════════════════════════
reset_all; _on; fm_sim_reload; _ld; _placemark
_domconf_fm_em_close_disk "$CUR_DIR" example_com
_DOMCONF_FM_TX_ACTION=repair
( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
assert_eq "$wrc" "4" "S1-e: işaret + kapalı disk: sahneleme reddi rc 4"
assert_contains "$(_out)" "alan KAPALI kalır" "S1-e: kapalı-disk KANITI varken 'alan KAPALI kalır'"
reset_all; _on; fm_sim_reload; _ld; _placemark   # işaret var, disk AÇIK (acil kapatma disk adımını tamamlayamamış)
_DOMCONF_FM_TX_ACTION=repair
( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
assert_eq "$wrc|$(_disk)" "4|varvarA" "S1-e: işaret + AÇIK disk: sahneleme reddi rc 4, diske dokunulmadı"
assert_not_contains "$(_out)" "alan KAPALI kalır" "S1-e: kanıt YOKKEN 'alan KAPALI kalır' DENMEZ"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "S1-e: kanıt yokken dürüst ileti"

# ═══════════════════════════ M3-R02/R03: ikinci konum işareti (kapı A/B ve commit kapısı) ═══════════════════════════
# işaret YALNIZ ikinci (kayıt dizininden bağımsız) konumda — kapı A bunu görmeli (R02: yalnız kayıt dizinine bakan mutant yaşıyordu)
reset_all; _on; fm_sim_reload; _ld
mkdir -p "$ALTD"; chmod 700 "$ALTD"; printf 'srvctl-fm-emergency v1\n' > "$ALTMARK"; chmod 600 "$ALTMARK"
assert_eq "$(_exists "$MARK")|$(_exists "$ALTMARK")" "yok|var" "R02: ön koşul: işaret YALNIZ ikinci konumda"
m20=$(_md5 "$F20"); : > "${FM_STUBS}/cp.log"
_DOMCONF_FM_TX_ACTION=repair
( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
assert_eq "$wrc|$(_md5 "$F20")|$(_bkn)" "4|${m20}|0" "R02: kapı A ikinci konumdaki işareti GÖRÜR: rc 4, diske dokunulmadı, yedek yok"
assert_contains "$(_out)" "SAHNELENMEDİ" "R02: sahnelenmedi iletisi"
# commit kapısı: işaret stage'DEN SONRA (nginx -t penceresinde) YALNIZ ikinci konuma konur (R03)
_h_alt_marker() { if [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]]; then : > "${FM_STUBS}/hk"; mkdir -p "$ALTD"; chmod 700 "$ALTD"; printf 'srvctl-fm-emergency v1\n' > "$ALTMARK"; chmod 600 "$ALTMARK"; fi; }
reset_all; _on; fm_sim_reload; rm -f "$F90"; _ld
NGINX_T_HOOK=_h_alt_marker
_DOMCONF_FM_TX_ACTION=repair
( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""; NGINX_T_HOOK=""
assert_eq "$wrc|$(_exists "$MARK")|$(_exists "$ALTMARK")" "4|yok|var" "R03: commit kapısı İKİNCİ konumdaki işareti görür: rc 4 (işaret yalnız alt konumda)"
assert_contains "$(_out)" "'on' kaydı YAZILMADI" "R03: commit kapısı reddi iletisi"
assert_eq "$(_disk)|$(_st)" "yokyokK|on" "R03: geri alma diski KAPATTI (kayıt yedekten 'on' döndü ama işaret/kanıt kapalı tutar)"
_fmprov_load example_com
assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|1" "R03: yükleme kaydı KAPALI sayar (işaret ikinci konumda)"

# ═══════════════════════════ M3-R04: closed_root_known grup-yazma biti ═══════════════════════════
SIG=$(_domconf_fm_body_sig example_com)
EQ="location = /_fm { return 403 \"srvctl-fm-closed ${SIG}\"; }"
PR="location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG}\"; }"
mkroot() { printf '%s\n' "$@" > "$F20"; chmod "${MODE:-644}" "$F20"; }
reset_all; _on
for m in 644 640 600; do
    MODE=$m mkroot "$EQ" "$PR"
    _domconf_fm_closed_root_known "$F20" example_com ""; assert_eq "$?" "0" "R04: mod ${m} → kanıt"
done
for m in 664 660 620 646 666 622; do
    MODE=$m mkroot "$EQ" "$PR"
    _domconf_fm_closed_root_known "$F20" example_com ""; assert_eq "$?" "1" "R04: mod ${m} (grup ya da diğer YAZILABİLİR) → kanıt DEĞİL"
done
MODE=664 mkroot "$EQ" "$PR"; rm -f "$F90" "$F21"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|3" "R04: mod 664 kök kanıt (|2) DEĞİL; kapalı görünümlü (|3) olarak AÇILMAZ"

# ═══════════════════════════ M3-K1: satır içi '#' yorum SAHTE-KANIT üretmez ═══════════════════════════
reset_all; _on
MODE=644 mkroot "$EQ" "$PR" "include /etc/nginx/evil.conf; # location = /_fm"
_domconf_fm_closed_root_known "$F20" example_com ""; assert_eq "$?" "1" "K1: 'include …; # yorum' satırı → kanıt DEĞİL (satır içi # satırı yok saydırmaz)"
MODE=644 mkroot "$EQ" "$PR" "proxy_pass http://127.0.0.1:9; #"
_domconf_fm_closed_root_known "$F20" example_com ""; assert_eq "$?" "1" "K1: 'proxy_pass …; #' → kanıt DEĞİL"
MODE=644 mkroot "$EQ # kapalı" "$PR"
_domconf_fm_closed_root_known "$F20" example_com ""; assert_eq "$?" "1" "K1: konum satırına eklenmiş satır içi yorum → KATI kanıt DEĞİL"
rm -f "$F90" "$F21"; MODE=644 mkroot "$EQ" "$PR" "include /etc/nginx/evil.conf; # location = /_fm"; _fmprov_load example_com
assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "K1: hasmane (include + yorum) kök: kanıt DEĞİL, kapalı görünümlü de DEĞİL → F9b: tanınan açık eser de değil → sınıf 4 (kapalı sayılır, otomatik yol açmaz)"
MODE=644 mkroot "$EQ" "$PR" "# ayrı satır yorum"
_domconf_fm_closed_root_known "$F20" example_com ""; assert_eq "$?" "0" "K1 kontrol: AYRI satırdaki '#' yorum kanıtı bozmaz"

# ═══════════════════════════ M3-R09: _FMP_LOCK_TIMED_OUT her çağrıda sıfırlanır ═══════════════════════════
reset_all; _on
( FLOCK_RC=1; _fmprov_with_lock true >/dev/null 2>&1; echo "$_FMP_LOCK_TIMED_OUT" > "${FM_STUBS}/lto.1" )
assert_eq "$(cat "${FM_STUBS}/lto.1")" "1" "R09: kilit zaman aşımı → bayrak 1"
( FLOCK_RC=1; _fmprov_with_lock true >/dev/null 2>&1
  # ardından kilit dosyası sembolik bağ olur: bu çağrı kilit beklemeye HİÇ varmaz (reddedilir); bayrak bayat 1 kalmamalı
  rm -f "${SD}/.lock"; ln -s /dev/null "${SD}/.lock"; _fmprov_with_lock true >/dev/null 2>&1; echo "$?|$_FMP_LOCK_TIMED_OUT" > "${FM_STUBS}/lto.2"; rm -f "${SD}/.lock" )
assert_eq "$(cat "${FM_STUBS}/lto.2")" "1|0" "R09: kilit beklemeden reddedilen çağrı (.lock sembolik bağ) bayrağı 0 yapar (bayat 1 kalmaz)"
( _fmprov_with_lock true >/dev/null 2>&1; echo "$_FMP_LOCK_TIMED_OUT" > "${FM_STUBS}/lto.3" )
assert_eq "$(cat "${FM_STUBS}/lto.3")" "0" "R09 kontrol: başarılı kilit → 0"

# ═══════════════════════════ M3-R06/R8 + R07/R1: settled sonda ve 'kapalı + reload yok' iletisi ═══════════════════════════
# sonda taklidi: ilk N sonda AÇIK (worker devri), sonra KAPALI
eval "_f9_orig_probe() $(declare -f _domconf_fm_runtime_probe | sed 1d)"
PROBE_N="${FM_STUBS}/probe.n"
_f9_probe_seq() {   # N açık, sonra gerçek sonda
    local n; n=$(cat "$PROBE_N" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$PROBE_N"
    if (( n <= ${F9_OPEN_FIRST:-0} )); then _FMRT_STATE="open"; _FMRT_DETAIL="taklit: worker devri"; return 0; fi
    _f9_orig_probe "$@"
}
_domconf_fm_runtime_probe() { _f9_probe_seq "$@"; }
export SRVCTL_FM_PROBE_RETRIES=3
# reclose: işaretli alan, restore sonrası kapalı kanıtlı, reload ok, ilk sonda AÇIK sonra KAPALI → settled ⇒ başarı
reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
echo 0 > "$PROBE_N"; F9_OPEN_FIRST=1
( _domconf_fm_fail_restore 4 ) >"$OUTF" 2>&1; frc=$?
F9_OPEN_FIRST=0
assert_eq "$frc" "4" "R06: reclose settled sonda: ilk sonda AÇIK ama yeniden denemede KAPALI → çağıranın kodu (4), rc 6 DEĞİL"
assert_contains "$(_out)" "alanı yeniden KAPATTI" "R06: settled sonda worker devrini bekledi → 'yeniden KAPATTI'"
assert_not_contains "$(_out)" "FM HÂLÂ AÇIK" "R06: yanlış alarm yok (tek sondaya bakan mutant 'FM HÂLÂ AÇIK' derdi)"
# acil kapatma: aynı settled sözleşmesi (R8)
reset_all; _on; fm_sim_reload
echo 0 > "$PROBE_N"; F9_OPEN_FIRST=1
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; erc=$?
F9_OPEN_FIRST=0
assert_eq "$erc|$(_run)" "0|RUN-CLOSED" "R8: acil kapatma settled sonda: ilk sonda AÇIK, sonra KAPALI → rc 0 (tek sondaya bakan mutant rc 3 verirdi)"
export SRVCTL_FM_PROBE_RETRIES=1
_domconf_fm_runtime_probe() { _f9_orig_probe "$@"; }
# reclose: kapalı-disk kanıtlı ama reload BAŞARISIZ/GEÇERSİZ + çalışan KAPALI → 'yeniden KAPATTI' DENMEZ, dürüst ileti (R07/R1)
for how in failed invalid; do
    reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
    _FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
    # restore + close çalışsın, SONRA çalışan görüntü KAPALI olsun (önceden kapalı kök yüklü), reload sonucu bozulsun
    _domconf_fm_restore_from_bk() { _f9_orig_rfb "$@"; local r=$?; _domconf_fm_render_off example_com > "${FM_RUNNING}/20-srvctl-fm-upload.conf"; rm -f "${FM_RUNNING}/90-"* "${FM_RUNNING}/21-"*; return $r; }
    if [[ "$how" == failed ]]; then SYSTEMCTL_RC=1; else NGINX_TEST_RC=1; fi
    ( _domconf_fm_fail_restore 4 ) >"$OUTF" 2>&1; frc=$?
    SYSTEMCTL_RC=0; NGINX_TEST_RC=0
    _domconf_fm_restore_from_bk() { _f9_orig_rfb "$@"; }
    assert_eq "$frc" "4" "R07/R1 [${how}]: çağıranın kodu korunur (4)"
    assert_contains "$(_out)" "nginx yeniden yüklenemedi (reload: ${how})" "R07 [${how}]: 'çalışan KAPALI ama nginx yeniden yüklenemedi' iletisi BASILIR (sessiz değil)"
    assert_contains "$(_out)" "kapanış DOĞRULANMIŞ SAYILMAZ" "R07 [${how}]: kapanış doğrulanmış sayılmaz"
    assert_not_contains "$(_out)" "alanı yeniden KAPATTI" "R1 [${how}]: reload YAPILMADIYSA 'yeniden KAPATTI' DENMEZ"
done
_domconf_fm_tx_reset

# ═══════════════════════════ S2: geri alma sırasında sinyal (rev sig2.sh F1 + A1/A2) ═══════════════════════════
PIDF="${FM_STUBS}/pid"; CNT="${FM_STUBS}/cnt"
_sig_run() { ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$1"; shift; "$@" ) >"$OUTF" 2>&1; }
# FIRST: ilk canlı -t'de INT (yes|no) ; SECOND: 2. canlı -t'de ne olur: none | shell (TERM) | shell2x (TERM+HUP)
_hook_sig() {
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT"
    if (( n == 1 )); then _placemark; fm_sim_reload; [[ "$FIRST" == yes ]] && kill -INT "$KILL_TARGET"; fi
    if (( n == 2 )); then
        case "$SECOND" in
            shell) kill -TERM "$KILL_TARGET" ;;
            shell2x) kill -TERM "$KILL_TARGET"; kill -HUP "$KILL_TARGET" ;;
        esac
    fi
}
# F9c (§15/38): "20 tanınan + 90 eksik" artık kayıtlı parametreyle AÇIK yeniden üretime gitmez (alan KAPANIR, sınıf 4); kapı-B reddi/geri alma
# sinyal tuzağı ise bir 'on' YAZIMI ister. Bu yüzden F-vakalarının tetikleyicisi 90 silmek yerine PHP kayması (tanınan açık eser + repair 8.4 =
# meşru 'on' yazımı) oldu; beklentiler DEĞİŞMEDİ. A-vakaları sınıf 4 tetikleyicisini (90 eksik) korur (kapatma yazımı sırasında sinyal).
DRIFT=0
_rep() { _domconf_fm_auth_repair example.com "$(if (( DRIFT )); then echo 8.4; else echo "${DEFAULT_PHP_VERSION}"; fi)" 1; }
sigcase() {   # sigcase <ad> FIRST SECOND [drift]
    local name="$1"; FIRST="$2"; SECOND="$3"; DRIFT="${4:-0}"
    reset_all; _on >/dev/null 2>&1; fm_sim_reload; if (( ! DRIFT )); then rm -f "$F90"; fi; rm -f "$CNT"
    NGINX_T_HOOK=_hook_sig; r0=$(_reloads)
    _sig_run INT _rep; SRC=$?; NGINX_T_HOOK=""
    SDISK=$(_disk); SRUN=$(_run); SRL=$(( $(_reloads) - r0 )); SBK=$(_bkn)
}
sigcase "F0c" no none
assert_eq "$SRC|$SDISK|$SRUN|$SBK" "0|yokyokK|RUN-CLOSED|0" "S2/F0c (F9c §15/38 TERSİNE ÇEVRİLDİ): 20 tanınan + 90 eksik: repair rc 0, alan KAPANDI (kayıtlı parametreyle açık yeniden üretim YOK), disk+çalışan KAPALI"
assert_contains "$(_out)" "alanı KAPATTI" "S2/F0c: repair 'alanı KAPATTI' der (yeniden üretildi demez)"
sigcase "F0" no none 1
assert_eq "$SRC|$SDISK|$SRUN|$SBK" "1|yokyokK|RUN-CLOSED|0" "S2/F0 kontrol: kapı reddi, sinyal yok: repair rc 1, disk+çalışan KAPALI, yedek tüketildi"
assert_contains "$(_out)" "alanı yeniden KAPATTI" "S2/F0 kontrol: 'yeniden KAPATTI'"
sigcase "F1" no shell 1
assert_eq "$SRC|$SDISK|$SRUN" "1|yokyokK|RUN-CLOSED" "S2/F1: kapı reddi + TERM reclose'un nginx -t'si SIRASINDA: süreç ÖLMEZ (rc 1 = repair başarısız; QL9: 143), disk+çalışan KAPALI (QL9: RUN-OPEN)"
assert_contains "$(_out)" "alanı yeniden KAPATTI" "S2/F1: reclose tamamlandı ve SÖYLENDİ (QL9: iletisiz ölüm)"
sigcase "F1b" no shell2x 1
assert_eq "$SRC|$SDISK|$SRUN" "1|yokyokK|RUN-CLOSED" "S2/F1b: TERM+HUP birlikte reclose sırasında: süreç ÖLMEZ, KAPALI"
sigcase "A0" yes none
assert_eq "$SRC|$SDISK|$SRUN" "130|yokyokK|RUN-CLOSED" "S2/A0 kontrol: tek sinyal (INT): 130, KAPALI"
sigcase "A1" yes shell
assert_eq "$SRC|$SDISK|$SRUN" "130|yokyokK|RUN-CLOSED" "S2/A1: apply_abort reclose'u sırasında 2. sinyal (TERM) zararsız: 130, KAPALI (R01: tuzak yoksa 143 + RUN-OPEN)"
assert_contains "$(_out)" "alanı yeniden KAPATTI" "S2/A1: reclose tamamlandı (iletisiz ölüm yok)"
sigcase "A2" yes shell2x
assert_eq "$SRC|$SDISK|$SRUN" "130|yokyokK|RUN-CLOSED" "S2/A2: 2. sinyal TERM+HUP zararsız: 130, KAPALI"
# fail_restore tuzağı reclose'dan SONRA kalkar (sızmaz)
reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
out=$( trap 'echo DUMMY' INT TERM HUP; _domconf_fm_fail_restore 4 >/dev/null 2>&1; echo "rc=$?"; echo "izler=[$(trap -p INT TERM HUP | tr '\n' ' ')]" )
assert_contains "$out" "izler=[]" "S2: fail_restore dönünce INT/TERM/HUP tuzakları SÖKÜLDÜ (reclose sonrası)"
# reclose SIRASINDA tuzak ':' (boş değil, '' değil): nginx -t içinde tuzak durumunu kaydet
_probe_trap() { [[ "$NGINX_T_ARGS" == "-t" ]] && trap -p TERM > "${FM_STUBS}/trap.during"; }
reset_all; _on; fm_sim_reload; _ld; _placemark; _mk_stale_bk AAAAAA
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); _FMT_DOMAIN=(example.com); _FMT_ARGS=("on|eu|-|-|0")
rm -f "${FM_STUBS}/trap.during"; NGINX_T_HOOK=_probe_trap
( _domconf_fm_fail_restore 4 ) >/dev/null 2>&1
NGINX_T_HOOK=""
assert_eq "$(cat "${FM_STUBS}/trap.during" 2>/dev/null)" "trap -- ':' SIGTERM" "S2: reclose'un nginx -t'si sırasında TERM tuzağı ':' (kaldırılmamış; '' değil — çocuklara miras kalmasın)"
_domconf_fm_tx_reset

# ═══════════════════════════ L1: işaretsiz kapalı alan + başarısız `fm-auth on` + üçüncü taraf reload ═══════════════════════════
# fm-auth on (işaretsiz, kapalı alan): stage açık yazar, nginx -t penceresinde üçüncü taraf reload bunu yükler, sonra yazım hatası.
_h_l1() { [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]] || return 0; : > "${FM_STUBS}/hk"; fm_sim_reload; }
reset_all; _on; _e; fm_sim_reload      # kapalı alan (kayıt 'off'), işaret YOK
assert_eq "$(_disk)|$(_run)|$(_st)" "yokyokK|RUN-CLOSED|off" "L1: ön koşul: işaretsiz KAPALI alan"
eval "_f9_orig_fw2() $(declare -f _f9_orig_fmprov_write | sed 1d)"
WC="${FM_STUBS}/wc"; rm -f "$WC"
_f9_orig_fmprov_write() { local n; n=$(cat "$WC" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$WC"; if (( n == 2 )); then return 1; fi; _f9_orig_fw2 "$@"; }
NGINX_T_HOOK=_h_l1; r0=$(_reloads)
_on; lrc=$?
NGINX_T_HOOK=""
eval "_f9_orig_fmprov_write() $(declare -f _f9_orig_fw2 | sed 1d)"
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "L1: commit kaydı yazılamadı + üçüncü taraf reload: geri alma çalışan nginx'i de KAPATTI (QL9: RUN-OPEN, ileti 'geri alındı')"
assert_eq "$((lrc != 0))" "1" "L1: komut rc≠0"
assert_contains "$(_out)" "alanı yeniden KAPATTI" "L1: işaretsiz alanda da reload + sonda yapıldı ve söylendi"
assert_eq "$(( $(_reloads) - r0 ))" "1" "L1: tam bir reload (geri alma sonrası)"
# kontrol: zaten AÇIK alanın (bk'da 90 var) başarısız onarımı ek reload yapmaz
reset_all; _on; fm_sim_reload; rm -f "${FM_STUBS}/ngxfail1"; r0=$(_reloads); NGINX_TEST_RC=1; _repair; wrc=$?; NGINX_TEST_RC=0
assert_eq "$wrc|$(( $(_reloads) - r0 ))" "1|0" "L1 kontrol: açık alanın nginx -t hatası geri almasında reload YOK (davranış değişmedi)"

# ═══════════════════════════ L12: açık `fm-auth on` + eşzamanlı acil kapatma ═══════════════════════════
reset_all; _e; fm_sim_reload   # kapalı kayıtlı alan
_h_l12() { [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]] || return 0; : > "${FM_STUBS}/hk"; ( _domconf_fm_auth example.com off --emergency ) >/dev/null 2>&1; }
# yaz: açık on, nginx -t'de beklerken acil kapatma diski kapatır (kilit serbest, acil kilit aşamasını alamaz: açık on kilidi tutar)
NGINX_T_HOOK=_h_l12
( FLOCK_RC=0; _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; orc=$?
NGINX_T_HOOK=""
# acil kapatma alt kabukta koştu; aynı kabuğun ortamında FLOCK_RC=0 (kilit alınabilir) → kilit aşaması da koşar
assert_eq "$(_disk)" "yokyokK" "L12: ön koşul: acil kapatma diski kapattı (yazıcı AÇIK yazdıktan sonra)"
assert_eq "$((orc != 0))" "1" "L12: açık 'fm-auth on' rc≠0 (QL9: rc 0 'AÇILDI')"
assert_not_contains "$(_out)" "fm-auth AÇILDI" "L12: 'fm-auth AÇILDI' DEMEZ"
assert_contains "$(_out)" "fm-auth AÇILMADI" "L12: gerçeği söyler: AÇILMADI"
assert_eq "$(_exists "$MARK")" "var" "L12: acil işareti yeniden kondu (kayıt 'on' ama alan KAPALI kalır)"
# kontrol: eşzamanlı olay yoksa normal on aynen çalışır
reset_all; _on; orc=$?
assert_eq "$orc|$(_disk)" "0|varvarA" "L12 kontrol: eşzamanlı olay yok → 'AÇILDI' rc 0"
assert_contains "$(_out)" "fm-auth AÇILDI" "L12 kontrol: ileti"

test_summary
