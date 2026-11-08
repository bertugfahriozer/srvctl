#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e-11 — test_domconf_fm_f9c_phpswitch_bk{,_2,_3}.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, harness_safe.sh, lib/domconf.sh, lib/domain.sh'yi source eder (fm_env'in EXIT tuzağı çağıranda), sonra bunu.
set +e
export SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
list_all_domains() { printf '%s\n' example.com; }

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_off() { ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
_shut() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]] && echo SHUT || echo OPEN; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_md5stdin() { if command -v md5sum >/dev/null 2>&1; then md5sum | cut -d' ' -f1; else md5 -q; fi; }
_phpswitch() { ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; PSRC=$?; fm_sim_reload; return $PSRC; }
_mk_stale_bk() {   # yarım işlem yedeği: MEVCUT disk + kayıt kopyası
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" || -L "$f" ]]; then cp -pP "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
reset_all() { _fm_reset; rm -f "${FM_STUBS}"/*.flag; MOCK_BAD_OWNER=""; }
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

N90="90-srvctl-fm-auth.conf"; N21="21-srvctl-fm-download.conf"; N20="20-srvctl-fm-upload.conf"
# bozulan eser: 20 | 21 | 90
corrupt() {
    case "$1" in
        20) mutf "$F20" "$N20" "$MAN" "$2" ;;
        21) mutf "$F21" "$N21" "$MAN" "$2" ;;
        90) mutf "$F90" "$N90" "$MAN" "$2" ;;
    esac
}
# yedek türleri (kayıt on + bozulma kurulmadan ÖNCE/SONRA alınır; tür adı = yedeğin içeriği)
#   cur   : bozulmuş MEVCUT diskin kopyası (yedekte de aynı eser bozuk)
#   good  : üç eser tanınan açık + on manifest (tek başına _fmprov_bk_restore_allowed = geri yüklenebilir)
#   off   : manifest off + tanınan 403 kökü (tek başına geri yüklenebilir)
#   empty : boş yedek dizini (manifest yok)
setup() {   # <hedef> <varyant> <yedek türü|none|two>
    local t="$1" v="$2" k="$3"
    reset_all; _on
    case "$k" in
        good) _mk_stale_bk AAAAAA ;;
        off)  _off; _mk_stale_bk AAAAAA; mv "${SD}/.bk.example_com.AAAAAA" "${FM_STUBS}/offbk"; _on; mv "${FM_STUBS}/offbk" "${SD}/.bk.example_com.AAAAAA" ;;
        empty) mkdir -p "${SD}/.bk.example_com.AAAAAA" ;;
    esac
    corrupt "$t" "$v"
    case "$k" in
        cur) _mk_stale_bk AAAAAA ;;
        two) _mk_stale_bk AAAAAA; _mk_stale_bk BBBBBB ;;
    esac
    fm_sim_reload
}
