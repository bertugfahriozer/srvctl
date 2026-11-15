#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e-11 — test_domconf_fm_f9b_never_opens*.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, harness_safe.sh, lib/domconf.sh, lib/domain.sh'yi source eder (fm_env'in EXIT tuzağı çağıranda), sonra bunu.
set +e
export SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
ALTD="${SRVCTL_FM_EMERGENCY_DIR}"
list_all_domains() { printf '%s\n' example.com; }

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_shut() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]] && echo SHUT || echo OPEN; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_repair() { ( _domconf_fm_auth_repair example.com "${1:-${DEFAULT_PHP_VERSION}}" 1 ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
_phpswitch() { ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; PSRC=$?; fm_sim_reload; return $PSRC; }
_batch() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 0 ) >"$OUTF" 2>&1; ( systemctl reload nginx ) >/dev/null 2>&1; }
_provision() { ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1; }
_mk_stale_bk() {   # yarım işlem yedeği: MEVCUT disk + kayıt kopyası (kesintiye uğramış bir yazımdan kalmış)
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" || -L "$f" ]]; then cp -pP "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
reset_all() { rm -rf "$ALTD"; _fm_reset; rm -f "${FM_STUBS}"/*.flag "${FM_STUBS}/trig" "${FM_STUBS}/arm" "${FM_STUBS}/hk" "${FM_STUBS}/hook.out"; MOCK_BAD_OWNER=""; }

SIG=$(_domconf_fm_body_sig example_com)
EQ="location = /_fm { return 403 \"srvctl-fm-closed ${SIG}\"; }"
PR="location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG}\"; }"

# unrec <sınıf>: kayıt `on` iken 20'yi TANINMAYAN duruma getirir (sınıf adı -> senaryo)
unrec() {
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        missing20)        rm -f "$F20" ;;                                                          # 20 eksik, 90/21 duruyor
        gone)             rm -f "$F20" "$F90" "$F21" ;;                                            # üçü de yok (kayıt on)
        fake_proxy)       printf '%s\n' "$EQ" "$PR" 'proxy_pass http://127.0.0.1:9;' > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21" ;;
        fake_proxy9021)   printf '%s\n' "$EQ" "$PR" 'proxy_pass http://127.0.0.1:9;' > "$F20"; chmod 644 "$F20" ;;
        badsig)           printf '%s\n' "location = /_fm { return 403 \"srvctl-fm-closed ${SIG:0:11}\"; }" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG:0:11}\"; }" > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21" ;;
        garbage)          printf 'return 200 "kullanici";\n' > "$F20"; chmod 644 "$F20" ;;
        empty)            : > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21" ;;
        symlink)          printf 'x\n' > "${FM_STUBS}/victim"; rm -f "$F20"; ln -s "${FM_STUBS}/victim" "$F20" ;;
        nul)              { printf '%s\n' "$EQ" "$PR"; printf '\0'; } > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21" ;;
        open_tamper)      printf '# kurcalandi\n' >> "$F20" ;;                                      # açık şablon + eklenti: özet kayıtta YOK
        open_badowner)    MOCK_BAD_OWNER="$F20" ;;                                                 # açık şablon, ama sahip root değil
        open_mode666)     chmod 666 "$F20" ;;                                                      # açık şablon, ama g/o yazılabilir
        open_foreign)     sed -i.b 's/srvctl-fm-open [0-9a-f]*/srvctl-fm-open 000000000000/' "$F20"; rm -f "${F20}.b" ;;
        closed_with9021)  printf '%s\n' "$good" > "$F20"; chmod 644 "$F20" ;;                      # 403 kökü, ama 90/21 duruyor (yarım kapanış)
    esac
    fm_sim_reload
}
runpath() {
    case "$1" in
        fmroot) _fmroot ;;
        fmrootall) _fmroot_all ;;                  # self-update geçişi de bu çağrıdır (cmd_domain fm-root --all --apply)
        repair83) _repair 8.3 ;;
        repair84) _repair 8.4 ;;                   # PHP sürüm kayması da var
        repairall) _batch ;;
        phpswitch) _phpswitch ;;
        provision) _provision ;;
    esac
}
# A bölümünün sınıf listesi dört parçaya bölündü (tam liste = CLASSES_1 … CLASSES_4; eski CLASSES değişkeni birleşimdir).
CLASSES_1="missing20 gone fake_proxy fake_proxy9021"
CLASSES_2="badsig garbage empty symlink"
CLASSES_3="nul open_tamper open_badowner"
CLASSES_4="open_mode666 open_foreign closed_with9021"
CLASSES="${CLASSES_1} ${CLASSES_2} ${CLASSES_3} ${CLASSES_4}"
PATHS="fmroot fmrootall repair83 repair84 repairall phpswitch provision"
