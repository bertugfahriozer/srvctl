#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e-11 — test_domconf_fm_f7_emergency{,_2,_3}.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, lib/domconf.sh, lib/domain.sh'yi source eder (fm_env'in EXIT tuzağı çağıranda), sonra bunu.
set +e
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"
ALT="${SRVCTL_FM_EMERGENCY_DIR}"
AMARK="${ALT}/example_com.emergency"
list_all_domains() { printf '%s\n' example.com; }

# Bekleyen flock taklidi (fm_env'inkinin yerine; FM_STUBS bu testin kendi geçici dizinidir)
cat > "${FM_STUBS}/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
w=0
while (( $# )); do case "$1" in -w) w="${2:-0}"; shift ;; esac; shift; done
if [[ "${FLOCK_RC:-0}" != "0" ]]; then exit "$FLOCK_RC"; fi
if [[ -n "${FLOCK_HELD:-}" && -e "$FLOCK_HELD" ]]; then
    t=0
    while [[ -e "$FLOCK_HELD" ]] && (( t < w * 10 )); do sleep 0.1; t=$((t + 1)); done
    if [[ -e "$FLOCK_HELD" ]]; then exit 1; fi
fi
exit 0
FLOCKEOF
chmod +x "${FM_STUBS}/flock"
HELD="${FM_STUBS}/lock.held"; export FLOCK_HELD="$HELD"
# F8-L11: saniye düzeyinde `sleep` sıralaması YOK. Arka plan "eşzamanlı yazıcı", acil kapatmanın kilit aşamasına GELDİĞİNİ
# FLOCK_LOG'daki `-w <N> 8` çağrısından anlar (flock taklidi çağrıyı beklemeden ÖNCE günlüğe yazar) ve ancak o zaman davranır.
# Süre dolarsa (20 sn) bekleyen taraf yine de ilerler; testin ilgili iddiası kırmızı verir (sonsuz döngü yok).
_wait_flock_call() {
    local pat="$1" i
    for (( i = 0; i < 400; i++ )); do
        if grep -q -- "$pat" "$FLOCK_LOG" 2>/dev/null; then return 0; fi
        sleep 0.05
    done
    return 1
}

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_closed() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]]; }
_disk() { printf '%s%s%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_closed && echo K || echo A)"; }
# çalışan nginx görüntüsü (fm_sim_reload'un son kopyası)
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_tamp() { find "$CUR_DIR" -maxdepth 1 -name '*.srvctl-tampered' 2>/dev/null | wc -l | tr -d ' '; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_asn() { find "$CUR_DIR" -maxdepth 1 -name '*.srvctl-emergency.*' 2>/dev/null | wc -l | tr -d ' '; }
_repair() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" "${1:-1}" ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
# Sembolik bağlı kayıt dizini senaryosu: açık alan → dizin sembolik bağ → acil kapatma (rc $_SCN_RC) → operatör dizini düzeltir.
_scn_symlink() {
    _fm_reset; _on
    mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
    _e; _SCN_RC=$?
    rm -f "$SD"; mv "${SD}.real" "$SD"
}

