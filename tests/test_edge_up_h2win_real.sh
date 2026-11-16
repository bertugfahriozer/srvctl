#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329
# GERÇEK nginx laboratuvarı — HTTP/2 + tamponsuz istek gövdesi akış penceresi (fm-up / @fm_up).
#
# SORUN: @fm_up 'proxy_request_buffering off' ile gövdeyi pCloud'a akıtır. nginx (ngx_http_v2_read_request_body) tamponsuz
# gövdede HTTP/2 akış alma penceresini max(client_body_buffer_size, http2_body_preread_size) = varsayılan 64 KiB tutar;
# pencere ancak üst akışa yazılınca açılır ⇒ tavan = pencere / RTT. 240 ms RTT'de ≈ 0.26 MiB/sn (8 MiB ≈ 30 sn). HTTP/1.1'de bu sınır yoktur.
#
# LABORATUVAR (hepsi rapora da yazılır; dış ağa istek YOK, dinleme YALNIZ 127.0.0.1, portlar SRVCTL_LAB_PORT_BASE .. +3):
#   curl ──► [gecikme vekili BASE+2, her yönde H2WIN_DELAY_MS (varsayılan 120) ms ⇒ RTT 240 ms] ──► lab nginx (BASE, TLS+http2)
#        ──► @fm_up (srvctl'in RENDER ettiği GERÇEK 20 şablonu) ──► sahte pCloud (BASE+3, TLS, gövdeyi hızla yutar)
#   auth_request kapısı: lab kuklası (BASE+1) AYNI sözleşmeyi verir (geçerli bilet → 204 + X-Fm-Auth; aksi 403). Kapı 1/2 mantığı gerçek 20'de.
#   H2WIN_TPL_ROOT=<dizin> verilirse şablonlar <dizin>/nginx/ altından okunur (KIRMIZI ölçüm: düzeltmeden ÖNCEKİ şablon).
#   H2WIN_BYTES (varsayılan 8 MiB), H2WIN_RATIO (h2 ≤ RATIO x h1), H2WIN_MAXSEC (h2 ≤ MAXSEC sn; ikisinden biri yeter).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
if [[ -n "${H2WIN_TPL_ROOT:-}" ]]; then SRVCTL_TEMPLATES="$H2WIN_TPL_ROOT"; export SRVCTL_TEMPLATES; fi

echo "══ 0: yapısal kilit — @fm_up gövde direktifleri ══"
U20=$(grep -v '^[[:space:]]*#' "$(_domconf_fm_tpl_dir)/fm-upload.conf.tpl")
FMUP_BLK=$(awk '/location @fm_up \{/{f=1} f{print} f&&/^}/{exit}' <<< "$U20")
assert_contains "$FMUP_BLK" "proxy_request_buffering off;" "@fm_up: gövde hâlâ tamponsuz (proxy_request_buffering off)"
cbbs=$(grep -E '^[[:space:]]*client_body_buffer_size[[:space:]]+[0-9]+[kKmM]?;' <<< "$FMUP_BLK" | head -1 | sed -E 's/.*client_body_buffer_size[[:space:]]+([0-9]+)([kKmM]?);.*/\1 \2/')
cb_bytes=0
if [[ -n "$cbbs" ]]; then
    read -r cb_n cb_u <<< "$cbbs"
    case "$cb_u" in k|K) cb_bytes=$((cb_n * 1024)) ;; m|M) cb_bytes=$((cb_n * 1048576)) ;; *) cb_bytes=$cb_n ;; esac
fi
assert_eq "$(( cb_bytes >= 1048576 ? 1 : 0 ))" "1" "@fm_up: client_body_buffer_size >= 1m (HTTP/2 akış penceresi; bulundu: ${cbbs:-yok})"
assert_eq "$(( cb_bytes <= 16777216 ? 1 : 0 ))" "1" "@fm_up: client_body_buffer_size <= 16m (bellek üst sınırı: istek başına)"
assert_eq "$(grep -c 'client_body_buffer_size' <<< "$U20")" "1" "client_body_buffer_size YALNIZ @fm_up içinde (başka location'a sızmadı)"
assert_contains "$FMUP_BLK" "proxy_max_temp_file_size 0;" "@fm_up: geçici dosya yok (proxy_max_temp_file_size 0)"

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "── gerçek nginx/curl/openssl/python3 yok — ÖLÇÜM BÖLÜMÜ ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi>) ──"
    test_summary; exit 0
fi
B="${SRVCTL_LAB_PORT_BASE:-8941}"
[[ "$B" =~ ^[1-9][0-9]{3,4}$ ]] || { echo "SRVCTL_LAB_PORT_BASE geçersiz"; exit 1; }
LP_TLS=$B; LP_AUTH=$((B + 1)); LP_DLY=$((B + 2)); LP_PC=$((B + 3))
port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
for p in $LP_TLS $LP_AUTH $LP_DLY $LP_PC; do
    port_free "$p" || { echo "── lab portu ${p} DOLU — ÖLÇÜM BÖLÜMÜ ATLANDI ──"; test_summary; exit 0; }
done
DELAY_MS="${H2WIN_DELAY_MS:-120}"; BYTES="${H2WIN_BYTES:-8388608}"; RATIO="${H2WIN_RATIO:-2}"; MAXSEC="${H2WIN_MAXSEC:-6}"
HELPER="${REPO_ROOT}/tests/h2win_lab.py"

LAB_KEEP=0
if [[ -n "${SRVCTL_LAB_DIR:-}" ]]; then LAB="$SRVCTL_LAB_DIR"; LAB_KEEP=1; mkdir -p "$LAB"; else LAB="$(mktemp -d)"; fi
mkdir -p "$LAB/logs" "$LAB/tmp" "$LAB/pki"
lab_down() {
    local f pid
    if [[ -f "$LAB/n.pid" ]]; then
        pid=$(cat "$LAB/n.pid")
        "$NG" -s quit -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        hs_kill_pidfile TERM "$LAB/n.pid" 'nginx'
    fi
    # ayrık python yardımcıları (h2win_lab.py spawn): pid dosyasından, ad + "bu koşudan sonra başladı" doğrulamasıyla (ham kill YOK)
    for f in "$LAB/dly.pid" "$LAB/sink.pid"; do
        hs_kill_pidfile TERM "$f" 'python[0-9.]*|Python'
    done
}
cleanup() { lab_down; if (( LAB_KEEP == 0 )); then rm -rf -- "${LAB:?}"; fi; }
trap 'cleanup; _fm_env_cleanup' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$LAB/pki/k.pem" -out "$LAB/pki/c.pem" -days 2 -subj "/CN=lab" \
    -addext "subjectAltName=DNS:up.example.com,DNS:eapi.pcloud.com" >/dev/null 2>&1
[[ -s "$LAB/pki/c.pem" ]] || { echo "  FAIL PKI üretilemedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; }
GOOD=$(printf 'a%.0s' $(seq 1 64))

# ── GERÇEK 20 şablonu (srvctl render eder) → lab uyarlaması: yalnız CA yolu/günlük yolu/pCloud TLS doğrulaması ──
RENDERED=$(_domconf_fm_render_upload eu 0 example_com) || { echo "  FAIL 20 şablonu render edilemedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; }
printf '%s\n' "$RENDERED" | sed -e "s#/etc/ssl/certs/ca-certificates\.crt#${LAB}/pki/c.pem#g" -e "s#proxy_ssl_verify on;#proxy_ssl_verify off;#" > "$LAB/20.conf"
cat > "$LAB/90.conf" <<EOT
location = /__fm_auth {
    internal;
    client_max_body_size 33m;
    proxy_pass http://127.0.0.1:${LP_AUTH}/auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Fm-Ticket \$http_x_fm_ticket;
}
EOT
cat > "$LAB/nginx.conf" <<EOT
pid $LAB/n.pid;
error_log $LAB/logs/e.log info;
events { worker_connections 256; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $LAB/tmp/b; proxy_temp_path $LAB/tmp/p; fastcgi_temp_path $LAB/tmp/f; uwsgi_temp_path $LAB/tmp/u; scgi_temp_path $LAB/tmp/s;
 upstream eapi.pcloud.com { server 127.0.0.1:${LP_PC}; }
 server { listen 127.0.0.1:${LP_AUTH};
   location = /auth {
     if (\$http_x_fm_ticket = "$GOOD") { add_header X-Fm-Auth "Bearer lab-token" always; return 204; }
     return 403; }
 }
 server { listen 127.0.0.1:${LP_TLS} ssl http2; server_name up.example.com;
   ssl_certificate $LAB/pki/c.pem; ssl_certificate_key $LAB/pki/k.pem;
   include $LAB/90.conf;
   include $LAB/20.conf;
   location / { return 404; }
 }
}
EOT
if ! "$NG" -t -c "$LAB/nginx.conf" -p "$LAB" >"$LAB/t.out" 2>&1; then
    sed 's/^/    [lab] /' "$LAB/t.out" >&2; echo "  FAIL lab nginx yapılandırması geçmedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1
fi
python3 -I "$HELPER" spawn "$LAB/sink.pid" "$LAB/logs/sink.out" sink "$LP_PC" "$LAB/pki/c.pem" "$LAB/pki/k.pem" "$LAB/logs/sink.log"
python3 -I "$HELPER" spawn "$LAB/dly.pid" "$LAB/logs/dly.out" delay "$LP_DLY" "$LP_TLS" "$DELAY_MS"
"$NG" -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1
for (( i = 0; i < 100; i++ )); do ! port_free "$LP_TLS" && ! port_free "$LP_DLY" && ! port_free "$LP_PC" && break; sleep 0.05; done

head -c "$BYTES" /dev/zero > "$LAB/body.bin"
UPH="up.example.com"
put_time() {   # $1=--http2|--http1.1 → "kod sürüm süre"
    curl -sS -q -k --noproxy '*' --max-time 150 "$1" -X PUT -H 'Expect:' -H "X-Fm-Ticket: $GOOD" -H 'Content-Type: application/octet-stream' \
        --data-binary @"$LAB/body.bin" --resolve "${UPH}:${LP_DLY}:127.0.0.1" -o /dev/null -w '%{http_code} %{http_version} %{time_total}' \
        "https://${UPH}:${LP_DLY}/_fm/up/12/0" 2>/dev/null
}
# ısınma: kapı/auth/üst akış zinciri ve TLS (küçük gövde, vekil gecikmeli)
w=$(curl -sS -q -k --noproxy '*' --max-time 30 --http1.1 -X PUT -H 'Expect:' -H "X-Fm-Ticket: $GOOD" --data-binary 'x' \
    --resolve "${UPH}:${LP_DLY}:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${UPH}:${LP_DLY}/_fm/up/12/0" 2>/dev/null)
assert_eq "$w" "200" "lab zinciri çalışıyor (vekil → nginx → gerçek 20 → sahte pCloud): küçük PUT 200"

echo "══ 1: ${BYTES} bayt PUT, RTT $((DELAY_MS * 2)) ms — HTTP/1.1 ve HTTP/2 ══"
r1=$(put_time --http1.1); r2=$(put_time --http2)
read -r c1 v1 t1 <<< "$r1"; read -r c2 v2 t2 <<< "$r2"
echo "  ÖLÇÜM h1.1: kod=${c1} sürüm=${v1} süre=${t1}s | h2: kod=${c2} sürüm=${v2} süre=${t2}s | pencere-tavanı tahmini h2 ≈ $(awk -v b="$BYTES" 'BEGIN{printf "%.1f", b/65536*0.24}')s (64 KiB/RTT)"
assert_eq "$c1" "200" "h1.1 PUT 200"
assert_eq "$c2" "200" "h2 PUT 200"
assert_eq "$v2" "2" "h2 isteği gerçekten HTTP/2 (curl http_version)"
assert_eq "$(awk -v n="$BYTES" '$1==n{c++} END{print c+0}' "$LAB/logs/sink.log")" "2" "sahte pCloud iki ölçümün de TAM gövdesini aldı (ısınma 1 bayttı)"
ok=$(awk -v h1="$t1" -v h2="$t2" -v r="$RATIO" -v m="$MAXSEC" 'BEGIN{print ((h2 <= r*h1) || (h2 <= m)) ? 1 : 0}')
assert_eq "$ok" "1" "h2 süresi (${t2}s) <= ${RATIO} x h1.1 (${t1}s) ya da <= ${MAXSEC}s"
test_summary
