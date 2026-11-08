#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — test_domconf_fm_f9c_all_three_{a,a_2,a_3,b,c,d,e,e_2,e_3,f,f_2,f_3}.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
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
PEND="${FM_STUBS}/pending.lst"
# Toplu repair (`repair --all`) FM adımı: gerçek _domain_repair_fm_step (PENDING dosyası ile alan başına reload YOK) + döngü sonunda
# PENDING boş değilse TEK nginx -t + TEK reload (lib/domain.sh `_domain_repair --all` döngüsünün aynısı). rc = ADIMIN rc'si.
_batch() {
    : > "$PEND"
    ( export _DOMAIN_REPAIR_FM_PENDING="$PEND"; _domain_repair_fm_step example.com "${DEFAULT_PHP_VERSION}" ) >"$OUTF" 2>&1; BRC=$?
    if [[ -s "$PEND" ]]; then ( nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 ); fi
    return $BRC
}
_provision() { ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1; }
_mk_stale_bk() {   # yarım işlem yedeği: MEVCUT disk + kayıt kopyası (kesintiye uğramış bir yazımdan kalmış)
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" || -L "$f" ]]; then cp -pP "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
reset_all() { rm -rf "$ALTD"; _fm_reset; rm -f "${FM_STUBS}"/*.flag "${FM_STUBS}/trig" "${FM_STUBS}/arm" "${FM_STUBS}/hk" "${FM_STUBS}/hook.out"; MOCK_BAD_OWNER=""; }

printf 'x\n' > "${FM_STUBS}/victim"

# mutf <dosya yolu> <ad> <kayıt dosyası> <varyant>: tek bir eseri verilen biçimde BOZAR (ad = kayıttaki dosya adı).
mutf() {
    local f="$1" nm="$2" man="$3" v="$4"
    case "$v" in
        missing)    rm -f "$f" ;;
        tamper)     printf '# kurcalandi\n' >> "$f" ;;
        symlink)    rm -f "$f"; ln -s "${FM_STUBS}/victim" "$f" ;;
        badowner)   MOCK_BAD_OWNER="${MOCK_BAD_OWNER} ${f}" ;;
        mode666)    chmod 666 "$f" ;;
        unknown)    printf 'return 200 "kullanici";\n' > "$f"; chmod 644 "$f" ;;
        empty)      : > "$f"; chmod 644 "$f" ;;
        isdir)      rm -f "$f"; mkdir "$f" ;;
        hardlink)   ln "$f" "${f%/*}/zz.hl" ;;
        unrecorded) sed -i.b "/^sha256 [0-9a-f]* ${nm}\$/d" "$man"; rm -f "${man}.b" ;;
    esac
}
VARS="missing tamper symlink badowner mode666 unknown empty isdir hardlink unrecorded"
AVARS="missing tamper symlink badowner mode666 unknown empty hardlink unrecorded"   # isdir: A6'da (bilinen sınır)
N90="90-srvctl-fm-auth.conf"; N21="21-srvctl-fm-download.conf"
# apply_target <90|21|both> <varyant>: kayıt `on` iken seçilen eser(ler)i bozar; ardından çalışan nginx diskle eşitlenir.
apply_target() {
    case "$1" in
        90)   mutf "$F90" "$N90" "$MAN" "$2" ;;
        21)   mutf "$F21" "$N21" "$MAN" "$2" ;;
        both) mutf "$F90" "$N90" "$MAN" "$2"; mutf "$F21" "$N21" "$MAN" "$2" ;;
    esac
    fm_sim_reload
}
runpath() {
    case "$1" in
        fmroot) _fmroot ;;
        fmrootall) _fmroot_all ;;
        repair83) _repair 8.3 ;;
        repair84) _repair 8.4 ;;
        repairall) _batch ;;
        phpswitch) _phpswitch ;;
        provision) _provision ;;
    esac
}
PATHS="fmroot fmrootall repair83 repair84 repairall phpswitch provision"
TARGETS="90 21 both"
mut20() {   # 20'yi bozar (kayıt on iken; 21/90 dokunulmaz)
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        closed_root) printf '%s\n' "$good" > "$F20"; chmod 644 "$F20" ;;      # 20 = tanınan 403 kökü, 21/90 duruyor (yarım kapalı)
        *)           mutf "$F20" "20-srvctl-fm-upload.conf" "$MAN" "$v" ;;
    esac
    fm_sim_reload
}
VARS20="missing tamper symlink badowner mode666 unknown empty hardlink unrecorded closed_root"
# B (yarım-işlem yedeği) testleri için: yedek dizinindeki eser(ler)i bozar (parça _f ve _f_2).
bk_mut() {   # <hedef 90|21|both> <varyant>: yedek dizinindeki eser(ler)i bozar
    local t="$1" v="$2" b="${SD}/.bk.example_com.AAAAAA"
    case "$t" in
        90)   mutf "${b}/${N90}" "$N90" "${b}/manifest" "$v" ;;
        21)   mutf "${b}/${N21}" "$N21" "${b}/manifest" "$v" ;;
        both) mutf "${b}/${N90}" "$N90" "${b}/manifest" "$v"; mutf "${b}/${N21}" "$N21" "${b}/manifest" "$v" ;;
    esac
}
