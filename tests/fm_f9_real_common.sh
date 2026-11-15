#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# F9/a1 — test_domconf_fm_f9_real{,_2,_3}.sh için ORTAK gerçek-nginx laboratuvarı ve yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, lib/domconf.sh, lib/domain.sh'yi source eder, `set +e` yapar, sonra bunu. nginx ya da curl YOKSA çağıran test burada ATLANIR (exit 0).
NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1; then
    echo "── gerçek nginx/curl yok — BU DOSYA ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi> ile çalıştırın) ──"
    test_summary
    exit 0
fi
CA=""
for c in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [[ -f "$c" ]] && { CA="$c"; break; }; done
if [[ -z "$CA" ]]; then echo "── CA paketi yok — ATLANDI ──"; test_summary; exit 0; fi
PY=""
for c in /opt/homebrew/bin/python3 /usr/bin/python3 "$(command -v python3 2>/dev/null)"; do [[ -n "$c" && -x "$c" ]] && { PY="$c"; break; }; done

T="$(mktemp -d)"; mkdir -p "$T/logs" "$T/tmp" "$T/live" "$T/extra" "$T/shim"
P=0; P2=0; HPID=""
# DIŞARI-0-İSTEK KALKANI: PATH başında curl sarmalayıcı. YALNIZ `--resolve <alan>:<port>:127.0.0.1` ile aynı <alan>:<port>
# hedefine (ya da doğrudan 127.0.0.1:<port>) izin verir; başka her hedef DENY + rc 7. Günlük: $T/shim.log.
REAL_CURL=$(command -v curl)
cat > "$T/shim/curl" <<'SHIMEOF'
#!/bin/bash
echo "$*" >> "${SHIM_LOG:?}"
orig=("$@"); res=""; url=""
while (( $# )); do
    case "$1" in
        --resolve) res="${2:-}"; shift ;;
        http://*|https://*) url="$1" ;;
    esac
    shift
done
hp="${url#*://}"; hp="${hp%%/*}"
if [[ "$hp" == 127.0.0.1:* || ( -n "$res" && "$res" == "${hp}:127.0.0.1" ) ]]; then exec "${SHIM_REAL:?}" "${orig[@]}"; fi
echo "DENY ${url:-?}" >> "$SHIM_LOG"; exit 7
SHIMEOF
chmod +x "$T/shim/curl"
SHIM_LOG="$T/shim.log"; : > "$SHIM_LOG"; export SHIM_LOG SHIM_REAL="$REAL_CURL"
export PATH="$T/shim:$PATH"

# F8-L12: bağlantı denemesiyle "port kullanımda mı" (yalnız 127.0.0.1); lab_down süreç GERÇEKTEN çıkana dek bekler (sabit sleep yok).
lab_port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
lab_down() {
    local pid i
    if [[ -f "$T/n.pid" ]]; then
        pid=$(cat "$T/n.pid"); kill "$pid" 2>/dev/null
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        rm -f "$T/n.pid"
    fi
}
holder_down() { if [[ -n "$HPID" ]]; then kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; HPID=""; fi; }
trap 'holder_down; lab_down; rm -rf "$T"; _fm_env_cleanup' EXIT
lab_fix() { sed -e "/^[[:space:]]*modsecurity off;/d" -e "s#eapi\.pcloud\.com#x.invalid#g" -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${T}/logs/#g"; }
# custom.d/example_com/*.conf → $T/live (nginx'in okuduğu kopya; yalnız laboratuvar dönüşümleri). nginx -t ve reload ÖNCESİ.
lab_sync() {
    local f
    rm -f "$T"/live/*.conf
    for f in "${CUR_DIR}"/*.conf; do [[ -f "$f" ]] && lab_fix < "$f" > "$T/live/${f##*/}"; done
    return 0
}
lab_up() {
    lab_down
    local tries=0 i
    while (( tries < 12 )); do
        P=$((19150 + RANDOM % 48)); P2=$((P + 1))
        # F8-L12: iki port (P ve P2) da boş olmalı; doluysa başka çift denenir
        if ! lab_port_free "$P" || ! lab_port_free "$P2"; then tries=$((tries + 1)); continue; fi
        cat > "$T/nginx.conf" <<EOT
pid $T/n.pid;
error_log $T/logs/e.log info;
events { worker_connections 32; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $T/tmp/b; proxy_temp_path $T/tmp/p; fastcgi_temp_path $T/tmp/f; uwsgi_temp_path $T/tmp/u; scgi_temp_path $T/tmp/s;
 server { listen 127.0.0.1:$P; server_name example.com;
   location / { return 200 "APP"; }
   include $T/live/*.conf;
 }
 include $T/extra/*.conf;
}
EOT
        : > "$T/logs/e.log"; lab_sync
        if "$NG" -t -c "$T/nginx.conf" -p "$T" >"$T/t.out" 2>&1 && "$NG" -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1; then
            for (( i = 0; i < 100; i++ )); do
                if curl -sS -q --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${P}/" 2>/dev/null; then return 0; fi
                sleep 0.05
            done
        fi
        lab_down
        tries=$((tries + 1))
    done
    sed 's/^/    [lab] /' "$T/t.out" >&2
    return 1
}
# srvctl'in çevresi → gerçek nginx
eval "_lab_orig_nginx() $(declare -f nginx | sed 1d)"
nginx() {
    if [[ "${1:-}" == "-t" && -z "${2:-}" ]]; then
        NGINX_T_ARGS="-t"; echo "t" >> "$NGINX_T_LOG"
        lab_sync
        [[ -n "${NGINX_T_HOOK:-}" ]] && "$NGINX_T_HOOK"
        "$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1
        return $?
    fi
    _lab_orig_nginx "$@"
}
# nginx günlük sayaçları: "sig start exit nobind emerg_nonbind" (grep -c eşleşme yoksa exit 1 verir: || true)
lab_log_counts() {
    local f="$T/logs/e.log" a b c d e
    a=$(grep -c 'signal 1 (SIGHUP)' "$f" 2>/dev/null || true)
    b=$(grep -c 'start worker process ' "$f" 2>/dev/null || true)
    c=$(grep -c 'exited with code' "$f" 2>/dev/null || true)
    d=$(grep -c 'still could not bind()' "$f" 2>/dev/null || true)
    e=$( { grep '\[emerg\]' "$f" 2>/dev/null || true; } | grep -vc 'bind()' || true)
    echo "${a:-0} ${b:-0} ${c:-0} ${d:-0} ${e:-0}"
}
lab_reload_done() {   # $1 = reload ÖNCESİ lab_log_counts
    local -a o n
    read -r -a o <<< "$1"; read -r -a n <<< "$(lab_log_counts)"
    (( n[0] > o[0] )) || return 1
    if (( n[1] > o[1] && n[2] > o[2] )); then return 0; fi
    if (( n[3] > o[3] || n[4] > o[4] )); then return 0; fi
    return 1
}
systemctl() {
    if [[ "${1:-}" == "reload" ]]; then
        echo r >> "$RELOAD_LOG"
        [[ "${SYSTEMCTL_RC:-0}" == "0" ]] || return 1
        lab_sync
        # F8-L11: sabit `sleep 0.6` yerine nginx'in kendi günlüğünü bekle (üst sınır ~10 sn; dolarsa devam edilir, iddialar kırmızı verir):
        #   SIGHUP alındı VE ( yeni worker başladı + eski worker çıktı  YA DA  "still could not bind()"  YA DA bind-dışı [emerg] ).
        local rrc i c0
        c0=$(lab_log_counts)
        "$NG" -s reload -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1
        rrc=$?
        if (( rrc == 0 )); then
            for (( i = 0; i < 200; i++ )); do
                if lab_reload_done "$c0"; then break; fi
                sleep 0.05
            done
        fi
        return $rrc
    fi
    return 0
}
# raw: gövdesiz PUT /_fm/up/1/0 → "kod|gövde" (sondayla AYNI istek biçimi, BAĞIMSIZ ölçüm)
raw() {
    local out
    out=$(curl -s -k -o - -w '\n%{http_code}' --noproxy '*' --path-as-is --resolve "example.com:${P}:127.0.0.1" -X PUT -H 'Expect:' "http://example.com:${P}/_fm/up/1/0" 2>/dev/null)
    printf '%s|%s' "${out##*$'\n'}" "${out%$'\n'*}"
}
SIG=$(_domconf_fm_body_sig example_com)
OPEN="411|srvctl-fm-open ${SIG}"; CLOSED="403|srvctl-fm-closed ${SIG}"

OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"; ALT="${SRVCTL_FM_EMERGENCY_DIR}"; AMARK="${ALT}/example_com.emergency"
list_all_domains() { printf '%s\n' example.com; }
_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_out() { cat "$OUTF"; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_repair() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" "${1:-1}" ) >"$OUTF" 2>&1; }
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
# yeni açık alan: gerçek nginx'te 411 + AÇIK imzası görülmeli (kontrol)
fresh_open() {
    _fm_reset; rm -f "$T"/extra/*.conf; holder_down
    SYSTEMCTL_RC=0
    _on
    [[ "$(raw)" == "$OPEN" ]]
}
export SRVCTL_FM_PROBE_HTTPS_PORT=off
_ld() { _fmprov_load example_com; RG="$_FMP_REGION"; SC="$_FMP_SCRIPT"; PH="$_FMP_PHP"; MS="$_FMP_MODSEC"; }
_placemark() { printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"; }
legacy_root() {   # F4-F6 imzasız kapalı kök
    printf '%s\n' '# srvctl: FileManager yükleme yolu KAPALI (srvctl domain fm-auth <alan> off). SRVCTL ÜRETİR.' \
        "# Bu 403 kökü, /_fm/ yolunun CI4'e düşmesini engeller; açmak için: fm-auth <alan> on --script=..." \
        'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }'
}
# sahneleme girişine tek seferlik kanca (durum işaretten ÖNCE okundu, sahneleme işaretten SONRA)
eval "_f8_orig_stage() $(declare -f _domconf_fm_stage | sed 1d)"
F8_PRE=""
_domconf_fm_stage() {
    if [[ -n "$F8_PRE" && ! -e "${FM_STUBS}/pre.done" ]]; then : > "${FM_STUBS}/pre.done"; "$F8_PRE"; fi
    _f8_orig_stage "$@"
}
_pre_emergency() {
    ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/pre.em.out" 2>&1
    echo "$?" > "${FM_STUBS}/pre.em.rc"
}
_third() { ( systemctl reload nginx ) >/dev/null 2>&1; }   # üçüncü taraf reload (certbot / logrotate / başka srvctl komutu)
