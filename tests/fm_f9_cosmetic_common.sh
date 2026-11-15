#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9/a1 (qalab9-I2) — test_domconf_fm_f9_cosmetic{,_2,_3,_4}.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, lib/domconf.sh, lib/domain.sh'yi source eder (fm_env'in EXIT tuzağı çağıranda), sonra bunu.
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

SIG=$(_domconf_fm_body_sig example_com)
EQ="location = /_fm { return 403 \"srvctl-fm-closed ${SIG}\"; }"
PR="location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG}\"; }"

# ═══════════════════════════ I2: kayıt 'on' + kozmetik bozuk ama srvctl adlı kapalı kök → hiçbir yol AÇMAZ ═══════════════════════════
_sh() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" ]] && ! grep -q 'auth_request' "$F20" && grep -Eq 'return[[:space:]]+403' "$F20" && echo SHUT || echo OPEN; }
cosmetic() {   # cosmetic <varyant>: 20'yi kozmetik bozuk kapalı köke çevirir (90/21 yok, işaret yok)
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        crlf)       printf '%s\n' "$good" | sed 's/$/\r/' > "$F20"; chmod 644 "$F20" ;;
        trailing)   printf '%s\n' "$good" | sed 's/$/ /' > "$F20"; chmod 644 "$F20" ;;
        inlinecmt)  printf '%s\n' "$good" | sed 's/$/ # kozmetik/' > "$F20"; chmod 644 "$F20" ;;
        leading)    printf '%s\n' "$good" | sed 's/^location/   location/' > "$F20"; chmod 644 "$F20" ;;
        mode664)    printf '%s\n' "$good" > "$F20"; chmod 664 "$F20" ;;
        mode666)    printf '%s\n' "$good" > "$F20"; chmod 666 "$F20" ;;
        hardlink)   printf '%s\n' "$good" > "$F20"; chmod 644 "$F20"; ln -f "$F20" "${F20}.hard" ;;
        foreign)    printf '%s\n' "$good" > "$F20"; chmod 644 "$F20"; MOCK_BAD_OWNER="$F20" ;;
        wstab)      printf '%s\n' "$good" | tr ' ' '\t' > "$F20"; chmod 644 "$F20" ;;                       # f_ws_tab: tüm boşluklar tab (belirteç arası + tırnaklı gövde)
        wstab1)     { printf '%s\n' "$good" | sed -n '1,2p'; printf '%s\n' "$good" | sed -n '3p' | tr ' ' '\t'; printf '%s\n' "$good" | sed -n '4p'; } > "$F20"; chmod 644 "$F20" ;;   # qalab f_ws_tab: yalnız `location =` satırı
        wstabbody)  printf '%s\n' "$good" | sed 's/srvctl-fm-closed /srvctl-fm-closed\t/' > "$F20"; chmod 644 "$F20" ;;   # tab YALNIZ tırnaklı gövdede
        wsmulti)    printf '%s\n' "$good" | sed 's/srvctl-fm-closed /srvctl-fm-closed   /' > "$F20"; chmod 644 "$F20" ;;  # gövdede çoklu boşluk
        wsquote)    printf '%s\n' "$good" | sed 's/"srvctl-fm-closed \([0-9a-f]*\)"/" srvctl-fm-closed \1 "/' > "$F20"; chmod 644 "$F20" ;;   # tırnak içinde baş/son boşluk
        unsigned_unknown) printf '%s\n' '# başka yorum' 'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }' > "$F20"; chmod 644 "$F20" ;;
    esac
    rm -f "$F90" "$F21"; fm_sim_reload
}
runpath() {
    case "$1" in
        fmroot|stalebk_fmroot) _fmroot ;;
        repair83) _repair 8.3 ;;
        repair84|stalebk_repair) _repair 8.4 ;;
        fmrootall) _fmroot_all ;;
        phpswitch) _phpswitch ;;
        repairall) _batch ;;
    esac
}
ALLP="fmroot repair83 repair84 fmrootall phpswitch repairall stalebk_fmroot stalebk_repair"