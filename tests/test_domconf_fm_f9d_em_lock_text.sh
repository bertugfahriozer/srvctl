#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2120  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# F9d §15/43(e) — acil kapatma, kilit ALINAMADI (lk==2) + eşzamanlı açık yazıcı diski yeniden açıp yükledi (sonda AÇIK):
#  rc 3 KALIR (karar değişmedi); ileti "disk KAPALI / reload başarılı görünüyor" ve "journalctl ile reload hatasını giderin"
#  DEMEZ, "kilit alınamadı … DOĞRULANMADI" ve "fm-auth <alan> off --emergency" yönlendirmesini söyler.
# Eski sürümle karşılaştırma: F9D_DOMCONF_LIB=<eski domconf.sh yolu> (varsayılan lib/domconf.sh).
# Senkron: yazıcı, acilin kilit aşamasına GELDİĞİNİ FLOCK_LOG'daki `-w 2 8` çağrısından anlar (sleep yok; 20 sn sınırı).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
trap 'hs_reap; _fm_env_cleanup' EXIT
# shellcheck source=/dev/null
source "${F9D_DOMCONF_LIB:-${REPO_ROOT}/lib/domconf.sh}"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
list_all_domains() { printf '%s\n' example.com; }

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
_wait_flock_call() {
    local pat="$1" i
    for (( i = 0; i < 400; i++ )); do
        if grep -q -- "$pat" "$FLOCK_LOG" 2>/dev/null; then return 0; fi
        sleep 0.05
    done
    return 1
}
_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_out() { cat "$OUTF"; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }

echo "── F9d (e): lk==2 + sonda AÇIK ──"
_fm_reset; _on; : > "$HELD"; : > "$FLOCK_LOG"
cp -p "$F20" "${FM_STUBS}/open20"; cp -p "$F90" "${FM_STUBS}/open90"; cp -p "$F21" "${FM_STUBS}/open21"
# Eşzamanlı açık yazıcı: kilidi tutarken diski yeniden açar ve nginx'i yükler; kilidi acil vazgeçene dek BIRAKMAZ.
( _wait_flock_call '-w 2 8'; echo "$?" > "${FM_STUBS}/sync.rc"
  cp -p "${FM_STUBS}/open90" "$F90"; cp -p "${FM_STUBS}/open21" "$F21"; cp -p "${FM_STUBS}/open20" "$F20"; fm_sim_reload ) &
HPID=$!; hs_track "$HPID"
( SRVCTL_FM_EMERGENCY_LOCK_WAIT=2 _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
wait "$HPID"
rm -f "$HELD"
assert_eq "$(cat "${FM_STUBS}/sync.rc")" "0" "F9d-e: senkron: yazıcı acilin kilit aşamasına GELDİĞİNİ FLOCK_LOG'dan gördü"
assert_eq "$(_run)" "RUN-OPEN" "F9d-e: senaryo: çalışan nginx AÇIK (yazıcı yükledi)"
assert_eq "$rc" "3" "F9d-e: rc 3 (karar DEĞİŞMEDİ)"
assert_contains "$(_out)" "FM HÂLÂ AÇIK — çalışan nginx yüklemeye izin veriyor; fm-auth kilidi 2 sn içinde alınamadı" "F9d-e: ileti kilidin alınamadığını söyler"
assert_contains "$(_out)" "disk durumu kilit altında DOĞRULANMADI" "F9d-e: ileti DOĞRULANMADI der"
assert_contains "$(_out)" "off --emergency' (kapanışı kilit altında yeniden doğrular), ardından 'srvctl domain fm-auth example.com status'" "F9d-e: Yapılacak: yazıcı bitince off --emergency + status"
assert_not_contains "$(_out)" "disk KAPALI, reload başarılı görünüyor" "F9d-e: yanıltıcı 'disk KAPALI, reload başarılı görünüyor' YOK"
assert_not_contains "$(_out)" "journalctl" "F9d-e: yanıltıcı 'journalctl ile reload hatasını giderin' YOK"
assert_not_contains "$(_out)" "BAŞARISIZ" "F9d-e: yanıltıcı 'reload BAŞARISIZ' YOK"

test_summary
