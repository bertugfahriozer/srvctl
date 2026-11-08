#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# Adım adım SIGKILL çökme düzeneği — test_domconf_fm_g13_*.sh için ORTAK (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, harness_safe.sh, lib/domconf.sh, lib/domain.sh, fm_f9c_phpswitch_bk_common.sh'yi source eder, sonra bunu.
#
# Düzenek: normal 'fm-auth off' / 'on' komutunun K. adımında (_domconf_atomic_write, _fmprov_write, mv, rm ve `systemctl reload` çağrısı sayacı; çağrıdan ÖNCE ölür) komutu çalıştıran alt kabuk ve altındaki TÜM süreç zinciri SIGKILL ile ölür (güç kesintisi benzetimi). Sinyal yalnız
# hs_signal_ancestor ile gider (kendi/ata süreçler). Sayaç dosyadadır: alt kabuklarda sayaç kaybolmaz.
#   G13_K = 0  : devre dışı (sayaç da tutulmaz)
#   G13_K = -1 : yalnız say (toplam adım sayısı g13_steps ile okunur)
#   G13_K > 0  : K. adımda öl
G13_K=0
G13_CNT="${FM_STUBS}/g13.cnt"; G13_S1="${FM_STUBS}/g13.s1"
echo 0 > "$G13_CNT"
eval "_g13_orig_aw() $(declare -f _domconf_atomic_write | sed 1d)"
eval "_g13_orig_fw() $(declare -f _fmprov_write | sed 1d)"
_g13_boom() {
    local n me s1 cur i j
    local -a chain=()
    [[ "${G13_K:-0}" != "0" ]] || return 0
    # "Çalışan nginx" taklidinin (fm_sim_reload) kendi rm/cp çağrıları srvctl adımı DEĞİLDİR; sayılmaz (reload çağrısının kendisi systemctl sarmalayıcısında sayılır).
    [[ " ${FUNCNAME[*]} " != *" fm_sim_reload "* ]] || return 0
    n=$(( $(cat "$G13_CNT") + 1 )); echo "$n" > "$G13_CNT"
    [[ "$G13_K" == "$n" ]] || return 0
    _hs_set_me; me="$HS_ME"; s1=$(cat "$G13_S1"); cur="$me"; i=0
    while [[ "$cur" != "$s1" && $i -lt 20 ]]; do chain+=("$cur"); cur=$(ps -o ppid= -p "$cur" | tr -d ' '); i=$((i + 1)); done
    hs_signal_ancestor KILL "$s1" 2>/dev/null
    for (( j = ${#chain[@]} - 1; j >= 0; j-- )); do hs_signal_ancestor KILL "${chain[j]}" 2>/dev/null; done
    return 0
}
_domconf_atomic_write() { _g13_boom; _g13_orig_aw "$@"; }
_fmprov_write() { _g13_boom; _g13_orig_fw "$@"; }
eval "_g13_orig_sc() $(declare -f systemctl | sed 1d)"
systemctl() { if [[ "${1:-}" == "reload" ]]; then _g13_boom; fi; _g13_orig_sc "$@"; }   # reload çağrısından ÖNCE ölüm = "commit ile reload arası kesinti"
mv() { _g13_boom; command mv "$@"; }
rm() { _g13_boom; command rm "$@"; }

g13_steps() { cat "$G13_CNT"; }
# g13_killed <K> <komut...>: komutu alt kabukta K. adımda öldürerek koşturur; çıktı OUTF'ta. rc = alt kabuğun rc'si (öldüyse 137).
g13_killed() {
    local k="$1" rc; shift
    echo 0 > "$G13_CNT"; G13_K="$k"
    { ( sh -c 'echo $PPID' > "$G13_S1"; "$@" ) >"$OUTF" 2>&1; } 2>/dev/null   # kabuğun "Killed: 9" iş bildirimi testin çıktısına karışmasın
    rc=$?
    G13_K=0
    return $rc
}
g13_off() { _domconf_fm_auth example.com off; }
g13_on()  { _domconf_fm_auth example.com on "--script=${SCRIPT}"; }

# ── Anlık görüntü: pahalı kurulumu (fm-auth on = onlarca süreç) her K için yinelememek için ──
# g13_snap_save <ad>: custom.d/example_com + köken kayıt dizini + acil işaret dizini + "çalışan nginx" görüntüsü kopyalanır.
# g13_snap_restore <ad>: _fm_reset (bayraklar/günlükler/taklit durumları sıfırlanır) + kopyadan geri yükleme. Modlar/sahiplik korunur (cp -Rp).
g13_snap_save() {
    local s="${FM_STUBS}/snap-$1"
    mkdir -p "$s/cur" "$s/state" "$s/run" "$s/em"
    cp -Rp "${CUR_DIR}/." "$s/cur/"
    if [[ -d "${SRVCTL_STATE_DIR}/_fm-auth" ]]; then cp -Rp "${SRVCTL_STATE_DIR}/_fm-auth/." "$s/state/"; fi
    if [[ -d "$SRVCTL_FM_EMERGENCY_DIR" ]]; then cp -Rp "${SRVCTL_FM_EMERGENCY_DIR}/." "$s/em/"; fi
    if [[ -d "$FM_RUNNING" ]]; then cp -Rp "${FM_RUNNING}/." "$s/run/"; fi
    G13_SNAP_STATE_MODE=$(_mode "${SRVCTL_STATE_DIR}/_fm-auth" 2>/dev/null || echo 700)
}
g13_snap_restore() {
    local s="${FM_STUBS}/snap-$1"
    _fm_reset; rm -f "${FM_STUBS}"/*.flag
    cp -Rp "$s/cur/." "${CUR_DIR}/"
    if [[ -n "$(ls -A "$s/state" 2>/dev/null)" ]]; then
        mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; chmod "${G13_SNAP_STATE_MODE:-700}" "${SRVCTL_STATE_DIR}/_fm-auth"
        cp -Rp "$s/state/." "${SRVCTL_STATE_DIR}/_fm-auth/"
    fi
    if [[ -n "$(ls -A "$s/em" 2>/dev/null)" ]]; then mkdir -p "$SRVCTL_FM_EMERGENCY_DIR"; cp -Rp "$s/em/." "${SRVCTL_FM_EMERGENCY_DIR}/"; fi
    if [[ -n "$(ls -A "$s/run" 2>/dev/null)" ]]; then cp -Rp "$s/run/." "${FM_RUNNING}/"; fi
}
