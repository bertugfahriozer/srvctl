#!/bin/bash
# shellcheck disable=SC2034,SC2317  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# '/__fm_' ad alanı yakalayıcısı — GERÇEK nginx 1.28 laboratuvarında: 90 (auth) ya da 21 (indirme) yokken iç istek uygulamaya DÜŞMEZ.
# nginx ya da curl YOKSA bu dosya ATLANIR. YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl sarmalayıcı kalkanı; resolver
# 127.0.0.1:9). Port aralığı: 19380–19399.
# Uygulama (CI4) taklidi: vhost'un `location /` bloğu ikinci dinleyicideki /app/ ucuna vekiller; o ucun erişim günlüğündeki her satır
# "uygulama koştu" demektir (nginx alt istekleri kendi erişim günlüğüne yazmaz; alt istek yalnız vekil yoluyla sayılabilir).
# Auth uç taklidi: ikinci bir dinleyici (srvctl'in gerçek 90 dosyasından yalnız `fastcgi_*` satırları atılıp `proxy_pass` konur).
#  A  90 YOK (20+21) ve YALNIZ 20: yükleme alt isteği → istemci 403, uygulama günlüğü 0, auth ucu 0, pCloud tarafı 0.
#  B  90+20+21 VAR (pozitif kontrol): auth ucu çağrılır (yakalayıcı onu ÖRTMEZ: `= /__fm_auth` tam eşleşmesi önce kazanır), yükleme
#     auth'tan geçer (kapalı kapıdan 403 DEĞİL), uygulama günlüğü 0; X-Accel-Redirect `/__fm_dl` 21'e ulaşır (403 yakalayıcısı DEĞİL).
#  C  21 YOK: X-Accel-Redirect `/__fm_dl` yakalayıcıda 403 (uygulamaya düşüp döngüye girmez).
#  D  dışarıdan `/__fm_auth`, `/__fm_dl`, `/__fm_baska` → 404 (internal), uygulama günlüğü 0.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1; then
    echo "── gerçek nginx/curl yok — BU DOSYA ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi> ile çalıştırın) ──"
    test_summary
    exit 0
fi

CA=""
for c in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [[ -f "$c" ]] && { CA="$c"; break; }; done
if [[ -z "$CA" ]]; then echo "── CA paketi yok — ATLANDI ──"; test_summary; exit 0; fi

T="$(mktemp -d)"; mkdir -p "$T/logs" "$T/tmp" "$T/live" "$T/shim"
P=0; P2=0
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

lab_port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
lab_down() {
    local pid i
    if [[ -f "$T/n.pid" ]]; then
        pid=$(cat "$T/n.pid"); "$NG" -s quit -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    fi
}
trap 'lab_down; rm -rf "$T"; _fm_env_cleanup' EXIT

SN=example_com
# srvctl'in GERÇEK render çıktısı; lab düzeltmesi yalnız: modsecurity satırı, pCloud ana makinesi (çözümlenemez ad), günlük yolu.
render_lab() {
    sed -e "/^[[:space:]]*modsecurity off;/d" -e "s#eapi\.pcloud\.com#x.invalid#g" -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${T}/logs/#g"
}
# 90: yalnız fastcgi_* satırları atılır, auth ucu taklidine proxy_pass konur (location'ın adı, internal'ı ve sırası gerçek dosyanın).
render_auth_lab() {
    render_lab | awk -v up="http://127.0.0.1:${P2}" '/^[[:space:]]*fastcgi_/ { next } { print } /^[[:space:]]*internal;/ { print "    proxy_pass " up ";" }'
}
set_state() {  # $1 = open|no90|only20|no21
    rm -f "$T"/live/*.conf
    _domconf_fm_render_upload eu 0 "$SN" | render_lab > "$T/live/20-srvctl-fm-upload.conf"
    [[ "$1" == open || "$1" == no90 ]] && _domconf_fm_render_download "$SN" | render_lab > "$T/live/21-srvctl-fm-download.conf"
    [[ "$1" == open || "$1" == no21 ]] && _domconf_fm_render_auth "$SN" 8.3 /current/modules/FileManager/Auth/fm-auth.php 0 | render_auth_lab > "$T/live/90-srvctl-fm-auth.conf"
    "$NG" -t -c "$T/nginx.conf" -p "$T" >"$T/t.out" 2>&1 || return 1
    "$NG" -s reload -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1 || return 1
    lab_wait_reload
}
lab_wait_reload() {
    local i n0
    n0=$(grep -c 'exited with code' "$T/logs/e.log" 2>/dev/null); n0=${n0:-0}
    for (( i = 0; i < 200; i++ )); do
        [[ "$(grep -c 'exited with code' "$T/logs/e.log" 2>/dev/null)" -gt "$n0" ]] && return 0
        sleep 0.05
    done
    return 1
}
lab_up() {
    local tries=0 i
    while (( tries < 12 )); do
        P=$((19380 + RANDOM % 18)); P2=$((P + 1))
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
   location / { proxy_pass http://127.0.0.1:$P2/app/; }
   location = /dl { proxy_pass http://127.0.0.1:$P2/xdl; }
   include $T/live/*.conf;
 }
 server { listen 127.0.0.1:$P2;
   location = /xdl { add_header X-Accel-Redirect "/__fm_dl?u=https://p.pcloud.com/a" always; return 200 "x"; }
   location /app/ { access_log $T/logs/app.log; return 404 "APP"; }
   location / { access_log $T/logs/auth.log; add_header X-Fm-Auth "Bearer tok123"; return 204; }
 }
}
EOT
        : > "$T/logs/e.log"; : > "$T/logs/app.log"; : > "$T/logs/auth.log"
        _domconf_fm_render_upload eu 0 "$SN" | render_lab > "$T/live/20-srvctl-fm-upload.conf"
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
lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# $1 = ad; kalan = curl bağımsız değişkenleri (URL son). Çıktı: "<kod> app=<n> auth=<n>"
req() {
    local app0 auth0 code
    app0=$(lines "$T/logs/app.log"); auth0=$(lines "$T/logs/auth.log")
    code=$(curl -sS -q --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' "${@}" 2>/dev/null)
    printf '%s app=%s auth=%s' "$code" "$(( $(lines "$T/logs/app.log") - app0 ))" "$(( $(lines "$T/logs/auth.log") - auth0 ))"
}
UP() { req -X PUT -H 'Content-Type: application/octet-stream' --data-binary 'abc' "http://127.0.0.1:${P}/_fm/up/777/0"; }

if ! lab_up; then
    echo "  FAIL lab açılamadı"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1
fi

echo "── A: 90 YOK (20+21) ve YALNIZ 20 — alt istek uygulamaya düşmez ──"
set_state no90; assert_eq "$?" "0" "A0: lab 90 yok (20+21)"
assert_eq "$(UP)" "403 app=0 auth=0" "A1: 90 yok: yükleme 403, uygulama günlüğü 0, auth 0"
set_state only20; assert_eq "$?" "0" "A2: lab yalnız 20"
assert_eq "$(UP)" "403 app=0 auth=0" "A3: yalnız 20: yükleme 403, uygulama günlüğü 0, auth 0"

echo "── B: 90+20+21 VAR (pozitif kontrol) — yakalayıcı gerçek uçları örtmez ──"
set_state open; assert_eq "$?" "0" "B0: lab açık (90+20+21)"
r=$(UP)
assert_contains "$r" "auth=1" "B1: auth ucu ÇAĞRILDI (= /__fm_auth yakalayıcıdan önce kazanır)"
assert_contains "$r" "app=0" "B2: açık durumda da uygulama günlüğü 0"
code=${r%% *}
assert_ne "$code" "403" "B3: yükleme auth'tan GEÇTİ (403 değil; pCloud ucu çözümlenemez → 5xx beklenir): ${code}"
assert_eq "$(req "http://127.0.0.1:${P}/dl")" "502 app=0 auth=0" "B4: X-Accel /__fm_dl 21'e ulaştı (yakalayıcının 403'ü değil: pCloud ana makinesi çözümlenemez → 502)"

echo "── C: 21 YOK — X-Accel iç isteği yakalayıcıda 403 ──"
set_state no21; assert_eq "$?" "0" "C0: lab 21 yok (90+20)"
assert_eq "$(req "http://127.0.0.1:${P}/dl")" "403 app=0 auth=0" "C1: 21 yok: /__fm_dl iç isteği 403, uygulamaya düşmez"

echo "── D: dışarıdan ad alanı → 404 (internal), uygulama koşmaz ──"
for p in /__fm_auth /__fm_dl "/__fm_dl?u=https://p.pcloud.com/a" /__fm_baska /__fm_; do
    assert_eq "$(req "http://127.0.0.1:${P}${p}")" "404 app=0 auth=0" "D1: dışarıdan GET ${p}"
done
assert_eq "$(grep -c DENY "$SHIM_LOG")" "0" "E: dış ağa istek yok (kalkan DENY 0)"

test_summary
