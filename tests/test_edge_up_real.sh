#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329,SC2086  # fm_env.sh bayrakları; işlevler dolaylı çağrılır; curl bayrak listeleri bilerek bölünür
# GERÇEK nginx laboratuvarı — köken kilidi (D1) + tls-default (D1) + fm-up (D2): up-mimari K7–K14 matrisi.
# nginx ya da curl ya da openssl YOKSA bu dosya ATLANIR. SRVCTL_TEST_NGINX=<nginx ikilisi> (ssl, realip, geo gerekir).
#
# LABORATUVAR YÖNTEMİ (hepsi rapora da yazılır):
#  * Dinleme YALNIZ 127.0.0.1; portlar SRVCTL_LAB_PORT_BASE (varsayılan 8941) .. +3 ve +8 (kapalı port). Dış ağa istek YOK.
#  * Tek TLS portu (BASE) üç sunucu bloğunu birlikte taşır, SNI seçer: ana vhost (example.com), up.example.com (srvctl'in render
#    ettiği fm-up dosyası), tls-default (srvctl'in yazdığı default_server). BASE+1 = up'ın port-80 bloğu (ACME + 301).
#  * srvctl'in yazdığı dosyalar AYNEN kullanılır; yalnız render_template çıktısı süzülür: 'listen 443 ssl http2' / 'listen 80' lab
#    adresine çevrilir, CA yolu/günlük dizini lab yoluna çevrilir, pCloud TLS doğrulaması kapatılır (sahte pCloud kendinden imzalı),
#    fm-auth.conf.tpl'in FASTCGI taşıması (FPM/chroot lab'da yok) auth_request'in AYNI sözleşmesini (bilet başlığı → 2xx + X-Fm-Auth ya da
#    403) veren bir proxy'ye çevrilir — kapı mantığı 20 şablonunda (gerçek), auth sonucu lab kuklasında.
#  * 'sunucu dışı eş' (köken kilidi): macOS'ta 127.0.0.2 takma adı sudo ister; bunun yerine makinenin kendi LAN adresinden
#    'curl --interface <LAN>' ile 127.0.0.1'e bağlanılır → nginx GERÇEK eş adresi olarak o LAN IP'sini görür ($realip_remote_addr).
#    Cloudflare listesi/realip/geo dosyaları gerçek 'srvctl trusted sync' ile (fixture) üretilir.
#  * certbot ve dig: PATH başında sahte ikililer. certbot kuklası ACME webroot'unu GERÇEKTEN dener (belirteç dosyasını yazar, faz-1
#    port-80 sunucusundan http ile okur), sonra lab sertifikasını canlı dizine koyar.
#  * Lab dizini SRVCTL_LAB_DIR (tanımsızsa mktemp -d ve çıkışta silinir; tanımlıysa dizin ve içeriği KALIR — kanıt).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/edge.sh"
source "${REPO_ROOT}/lib/deploy.sh"
source "${REPO_ROOT}/lib/ssl.sh"
source "${REPO_ROOT}/lib/monitor.sh"
set +e
require_root() { return 0; }
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    echo "── gerçek nginx/curl/openssl yok — BU DOSYA ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi> ile çalıştırın) ──"
    test_summary; exit 0
fi
B="${SRVCTL_LAB_PORT_BASE:-8941}"
[[ "$B" =~ ^[1-9][0-9]{3,4}$ ]] || { echo "SRVCTL_LAB_PORT_BASE geçersiz"; exit 1; }
LP_TLS=$B; LP_HTTP=$((B + 1)); LP_APP=$((B + 2)); LP_PC=$((B + 3)); LP_DEAD=$((B + 8))
port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
for p in $LP_TLS $LP_HTTP $LP_APP $LP_PC $LP_DEAD; do
    port_free "$p" || { echo "── lab portu ${p} DOLU — BU DOSYA ATLANDI (SRVCTL_LAB_PORT_BASE ile başka aralık verin) ──"; test_summary; exit 0; }
done

LAB_KEEP=0
if [[ -n "${SRVCTL_LAB_DIR:-}" ]]; then LAB="$SRVCTL_LAB_DIR"; LAB_KEEP=1; mkdir -p "$LAB"; else LAB="$(mktemp -d)"; fi
mkdir -p "$LAB/logs" "$LAB/tmp" "$LAB/conf.d" "$LAB/pki" "$LAB/trusted" "$LAB/acme" "$LAB/le-live" "$LAB/bin" "$LAB/fix"
lab_down() {
    local pid i
    if [[ -f "$LAB/n.pid" ]]; then
        pid=$(cat "$LAB/n.pid")
        "$NG" -s quit -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    fi
}
cleanup() { lab_down; if (( LAB_KEEP == 0 )); then rm -rf -- "${LAB:?}"; fi; }
trap 'cleanup; _fm_env_cleanup' EXIT

# ── PKI: tek kendinden imzalı sertifika (SAN: example.com, up.example.com, eapi.pcloud.com) ──
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$LAB/pki/k.pem" -out "$LAB/pki/c.pem" -days 2 -subj "/CN=lab" \
    -addext "subjectAltName=DNS:example.com,DNS:www.example.com,DNS:up.example.com,DNS:eapi.pcloud.com" >/dev/null 2>&1
[[ -s "$LAB/pki/c.pem" ]] || { echo "  FAIL PKI üretilemedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; }
CA="$LAB/pki/c.pem"

GOOD=$(printf 'a%.0s' $(seq 1 64)); OTHER=$(printf 'b%.0s' $(seq 1 64)); MARK=$(printf 'c%.0s' $(seq 1 64))
export SRVCTL_NGINX_CONF_D="$LAB/conf.d"
export NGINX_CF_GEO_CONF="$LAB/conf.d/srvctl-cf-origin-geo.conf" NGINX_CF_REALIP_CONF="$LAB/conf.d/srvctl-cloudflare-realip.conf"
export SRVCTL_TLS_DEFAULT_CONF="$LAB/conf.d/00-srvctl-tls-default.conf" SRVCTL_TLS_DEFAULT_LISTEN="127.0.0.1:${LP_TLS}"
export TRUSTED_STATE_DIR="$LAB/trusted" SRVCTL_TRUSTED_FIXTURE_DIR="$LAB/fix" TRUSTED_SOURCES="cloudflare"
export SRVCTL_ACME_ROOT="$LAB/acme" SRVCTL_LE_LIVE_DIR="$LAB/le-live" SRVCTL_FMUP_EMPTY_ROOT="$LAB/tmp"
export SRVCTL_SELF_IPS="198.51.100.7"
# L1: ön uçuş ve ucuz 403/404 yanıtları da limit_req'e SAYILIR → işlevsel dizilerin (yüzlerce hızlı istek) 429'a takılmaması için
# varsayılan sınırlar bu dosyada yüksek tutulur; 7. ve 11. bölümler düşük sınırı KENDİ komut önekiyle verir.
export FMUP_RATE_IP=1000 FMUP_BURST_IP=1000 FMUP_RATE_ALL=1000 FMUP_BURST_ALL=1000
export SRVCTL_NGINX_EDGE_DIR="${WEB_ROOT}/.edge.d" SRVCTL_FMUP_LOG_DIR="${WEB_ROOT}/.fmup-logs"; mkdir -p "$SRVCTL_FMUP_LOG_DIR"
export SRVCTL_NGINX_VERSION; SRVCTL_NGINX_VERSION=$("$NG" -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
mkdir -p "${WEB_ROOT}/example.com/logs"
UPLOG="${SRVCTL_FMUP_LOG_DIR}/srvctl-fmup-example_com.access.log"; UPERR="${SRVCTL_FMUP_LOG_DIR}/srvctl-fmup-example_com.error.log"

# ── sahte pCloud yukarı akışı ──
write_pc_upstream() { printf 'upstream eapi.pcloud.com { server 127.0.0.1:%s; }\n' "$1" > "$LAB/pcloud-upstream.conf"; }
write_pc_upstream "$LP_PC"
cat > "$LAB/nginx.conf" <<EOT
pid $LAB/n.pid;
error_log $LAB/logs/e.log info;
events { worker_connections 256; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $LAB/tmp/b; proxy_temp_path $LAB/tmp/p; fastcgi_temp_path $LAB/tmp/f; uwsgi_temp_path $LAB/tmp/u; scgi_temp_path $LAB/tmp/s;
 log_format pc '\$request_method \$request_uri auth=[\$http_authorization] ticket=[\$http_x_fm_ticket] cookie=[\$http_cookie] cl=[\$content_length]';
 include $LAB/conf.d/*.conf;
 include $LAB/pcloud-upstream.conf;
 # auth_request sözleşmesi kuklası (gerçek 90: FPM): geçerli bilet → 204 + X-Fm-Auth; diğer → 403. Her çağrı auth.log'a düşer.
 # K11 kanıtı: error_page ile girilen ADLI location'ın yapılandırması çağıran location'ınki DEĞİL, sunucu/http düzeyindekidir
 # (ModSecurity'nin 'modsecurity on' http-düzeyi ayarı bu yüzden @fm_deny'a da iner).
 server { listen 127.0.0.1:$LP_APP;
   add_header X-Srv-Level "1" always;
   location = /k11 { add_header X-Orig-Location "1" always; error_page 500 =403 @k11d; return 500; }
   location @k11d { return 403; }
   location = /auth { access_log $LAB/logs/auth.log;
     if (\$http_x_fm_ticket = "$GOOD") { add_header X-Fm-Auth "Bearer lab-token" always; return 204; }
     return 403; }
 }
 # sahte pCloud
 server { listen 127.0.0.1:$LP_PC ssl; server_name eapi.pcloud.com;
   ssl_certificate $LAB/pki/c.pem; ssl_certificate_key $LAB/pki/k.pem;
   location /upload_write { access_log $LAB/logs/pcloud.log pc; return 200 '{"result":0}'; }
 }
 # ana vhost (srvctl vhost-ssl şablonunun lab eşdeğeri: custom.d EN SONDA include)
 server { listen 127.0.0.1:$LP_TLS ssl; server_name example.com www.example.com;
   ssl_certificate $LAB/pki/c.pem; ssl_certificate_key $LAB/pki/k.pem;
   include ${SRVCTL_NGINX_EDGE_DIR}/example_com/*.conf;
   location / { access_log $LAB/logs/app.log; return 200 "APP"; }
   include ${CUR_DIR}/*.conf;
 }
}
EOT

# ── srvctl çıktısını lab'a uyarlayan süzgeç + auth taşıması ──
lab_fix() {
    sed -e "s#listen 443 ssl http2;#listen 127.0.0.1:${LP_TLS} ssl http2;#" -e "s#listen 80;#listen 127.0.0.1:${LP_HTTP};#" \
        -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${LAB}/logs/#g" -e "s#proxy_ssl_verify on;#proxy_ssl_verify off;#" \
    | awk -v app="$LP_APP" '
        /^[[:space:]]*fastcgi_/ { next }
        { print }
        /^location = \/__fm_auth \{/ {
            print "    proxy_pass http://127.0.0.1:" app "/auth;"
            print "    proxy_pass_request_body off;"
            print "    proxy_set_header Content-Length \"\";"
            print "    proxy_set_header X-Fm-Ticket $http_x_fm_ticket;"
        }'
}
eval "_lab_orig_rt() $(declare -f render_template | sed 1d)"
render_template() { _lab_orig_rt "$@" | lab_fix; }

# ── nginx/systemctl taklitleri → gerçek lab nginx'i ──
lab_counts() { local f="$LAB/logs/e.log"; printf '%s %s %s' "$(grep -c 'signal 1 (SIGHUP)' "$f" 2>/dev/null)" "$(grep -c 'start worker process ' "$f" 2>/dev/null)" "$(grep -c 'exited with code' "$f" 2>/dev/null)"; }
lab_wait_reload() {
    local i o n; read -r -a o <<< "$1"
    for (( i = 0; i < 400; i++ )); do
        read -r -a n <<< "$(lab_counts)"
        if (( ${n[0]:-0} > ${o[0]:-0} && ${n[1]:-0} > ${o[1]:-0} && ${n[2]:-0} > ${o[2]:-0} )); then return 0; fi
        sleep 0.05
    done
    return 1
}
lab_reload() { local c0; c0=$(lab_counts); "$NG" -s reload -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1 || return 1; lab_wait_reload "$c0"; }
eval "_lab_orig_nginx() $(declare -f nginx | sed 1d)"
nginx() {
    if [[ "${1:-}" == "-t" && -z "${2:-}" ]]; then echo "t" >> "$NGINX_T_LOG"; "$NG" -t -c "$LAB/nginx.conf" -p "$LAB" 2>&1; return $?; fi
    _lab_orig_nginx "$@"
}
systemctl() {
    if [[ "${1:-}" == "reload" ]]; then echo r >> "$RELOAD_LOG"; lab_reload; return $?; fi
    return 0
}
export SRVCTL_FM_PROBE_HTTPS_PORT="$LP_TLS" SRVCTL_FM_PROBE_HTTP_PORT=off SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
export SRVCTL_PROBE_HTTPS_PORT="$LP_TLS" SRVCTL_PROBE_HTTP_PORT="$LP_HTTP"
NGINX_FAIL_ON_MODSEC=1   # lab nginx'inde modsecurity modülü YOK → 'modsecurity off' satırı yoruma döner (yetenek sondası ile)

# ── certbot / dig kuklaları ──
export LAB LP_HTTP LP_TLS
cat > "$LAB/bin/certbot" <<'CBEOF'
#!/bin/bash
echo "$*" >> "${LAB}/logs/certbot.log"
host=""; webroot=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-d" || "$prev" == "--cert-name" ]] && host="$a"
    [[ "$prev" == "-w" ]] && webroot="$a"
    prev="$a"
done
[[ "$1" == "delete" ]] && { echo "DELETE ${host}" >> "${LAB}/logs/certbot.log"; rm -rf -- "${SRVCTL_LE_LIVE_DIR:?}/${host:?}"; exit 0; }
# faz-1 sunucusunun ACME webroot'unu GERÇEKTEN dene (certbot --webroot'un yaptığı gibi)
mkdir -p "${webroot}/.well-known/acme-challenge"; echo "tok-$$" > "${webroot}/.well-known/acme-challenge/tok$$"
got=$(curl -s --max-time 5 --noproxy '*' --resolve "${host}:${LP_HTTP}:127.0.0.1" "http://${host}:${LP_HTTP}/.well-known/acme-challenge/tok$$")
echo "ACME-FETCH=${got}" >> "${LAB}/logs/certbot.log"
red=$(curl -s -o /dev/null --max-time 5 --noproxy '*' -w '%{http_code} %{redirect_url}' --resolve "${host}:${LP_HTTP}:127.0.0.1" "http://${host}:${LP_HTTP}/x")
echo "ROOT301=${red}" >> "${LAB}/logs/certbot.log"
echo "HAS443=$(grep -c 'ssl' "${SRVCTL_NGINX_CONF_D}/srvctl-fmup-example_com.conf" 2>/dev/null)" >> "${LAB}/logs/certbot.log"
[[ "$got" == "tok-$$" ]] || { echo "ACME dogrulama basarisiz" >&2; exit 1; }
mkdir -p "${SRVCTL_LE_LIVE_DIR}/${host}"
cp "${LAB}/pki/c.pem" "${SRVCTL_LE_LIVE_DIR}/${host}/fullchain.pem"; cp "${LAB}/pki/k.pem" "${SRVCTL_LE_LIVE_DIR}/${host}/privkey.pem"
exit 0
CBEOF
cat > "$LAB/bin/dig" <<'DGEOF'
#!/bin/bash
t="A"; for a in "$@"; do case "$a" in A|AAAA) t="$a" ;; esac; done
if [[ "$t" == "A" ]]; then printf '%b' "${DIG_A:-}"; else printf '%b' "${DIG_AAAA:-}"; fi
DGEOF
chmod +x "$LAB/bin/certbot" "$LAB/bin/dig"
export PATH="$LAB/bin:$PATH"
DIG_A="198.51.100.7\n"; DIG_AAAA=""; export DIG_A DIG_AAAA
{ for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "10.77.${i}.0/24"; done; } > "$LAB/fix/cloudflare-v4"
CF_V6_TXT='2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n2405:b500::/32\n2405:8100::/32\n2a06:98c0::/29\n'
printf "$CF_V6_TXT" > "$LAB/fix/cloudflare-v6"
CF_V4_BASE="$LAB/fix/cloudflare-v4.base"; cp "$LAB/fix/cloudflare-v4" "$CF_V4_BASE"

# ── lab'ı başlat ──
: > "$LAB/logs/e.log"
if ! "$NG" -t -c "$LAB/nginx.conf" -p "$LAB" >"$LAB/t.out" 2>&1 || ! "$NG" -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1; then
    sed 's/^/    [lab] /' "$LAB/t.out" >&2; echo "  FAIL lab nginx açılamadı"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1
fi
for (( i = 0; i < 100; i++ )); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${LP_APP}/" 2>/dev/null && break; sleep 0.05; done

# ── istek yardımcıları ──
UPH="up.example.com"
cu()  { curl -sS -q --http1.1 -k --noproxy '*' --max-time 10 --resolve "${UPH}:${LP_TLS}:127.0.0.1" "$@" 2>/dev/null; }
cuh() { curl -sS -q --http1.1 -k --noproxy '*' --max-time 10 --resolve "${UPH}:${LP_TLS}:127.0.0.1" -D - -o /dev/null "$@" 2>/dev/null | tr -d '\r'; }
UPU="https://${UPH}:${LP_TLS}"
H_code() { sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' <<< "$1"; }
H_has()  { grep -ci "^$2:" <<< "$1"; }
H_val()  { grep -i "^$2:" <<< "$1" | head -1 | sed 's/^[^:]*:[[:space:]]*//'; }
pre() { local h; h=$(cuh -X OPTIONS ${1:+-H "Origin: $1"} ${2:+-H "Access-Control-Request-Method: $2"} "${UPU}${3}"); printf '%s|%s' "$(H_code "$h")" "$(H_has "$h" access-control-allow-origin)"; }
put() { local h; h=$(cuh -X PUT -H 'Expect:' -H "Origin: https://example.com" "$@"); printf '%s|%s' "$(H_code "$h")" "$(H_has "$h" access-control-allow-origin)"; }
lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
OUTF="${FM_STUBS}/out.txt"
ssl_vhost() { printf 'server {\n    listen 80;\n    server_name example.com;\n    return 301 https://$server_name$request_uri;\n}\nserver {\n    listen 443 ssl http2;\n    server_name example.com;\n    include /etc/nginx/edge.d/example_com/*.conf;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"; }
ssl_vhost
echo "x" > "$LAB/body.bin"; head -c 1024 /dev/zero > "$LAB/body.bin"

echo "══ 0: ön koşul — fm-auth on (gerçek şablonlar, gerçek nginx) ══"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; rc=$?
if (( rc != 0 )); then sed 's/^/    [fm-auth on] /' "$OUTF" >&2; fi
assert_eq "$rc" "0" "fm-auth on rc 0 (20/21/90 yazıldı, gerçek nginx -t geçti)"
assert_contains "$(cat "$F90")" "proxy_pass http://127.0.0.1:${LP_APP}/auth;" "lab: 90'ın FASTCGI taşıması auth kuklasına çevrildi (yalnız taşıma)"
assert_contains "$(cat "$F20")" "location ^~ /_fm/up/" "20 gerçek şablon"
assert_contains "$(cat "$F20")" "# ModSecurity yüklü değil" "K11: modül yok → MODSEC_LINE yorum"
assert_eq "$(awk '/location @fm_deny/{f=1} f{print} f&&/^}/{exit}' "$F20" | grep -c 'ModSecurity yüklü değil')" "1" "K11: @fm_deny da MODSEC_LINE taşır (render edilmiş)"

echo "══ 0b: ön koşul — tls-default AÇIK (fm-up on bunu ŞART koşar) ══"
( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "tls-default KAPALIYKEN fm-up on --dry reddedilir"
assert_contains "$(cat "$OUTF")" "tls-default on" "ileti: önce tls-default on"
( cmd_tls_default on ) >"$OUTF" 2>&1; rc=$?
if (( rc != 0 )); then sed 's/^/    [tls-default on] /' "$OUTF" >&2; fi
assert_eq "$rc" "0" "tls-default on rc 0 (fm-up öncesi)"

echo "══ 1: fm-up on — iki faz, gerçek ACME webroot ══"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
if (( rc != 0 )); then sed 's/^/    [fm-up on] /' "$OUTF" >&2; fi
assert_eq "$rc" "0" "fm-up on rc 0"
CBL="$(cat "$LAB/logs/certbot.log")"
assert_contains "$CBL" "certonly --webroot -w ${LAB}/acme -d up.example.com" "certbot certonly --webroot -w <acme> -d <host>"
assert_contains "$CBL" "ACME-FETCH=tok-" "faz-1 80 bloğu ACME belirtecini GERÇEKTEN sundu (root=webroot)"
assert_contains "$CBL" "ROOT301=301 https://up.example.com/x" "port 80'de kalanı 301 (sunucu düzeyi return ACME'yi bozmadı)"
assert_contains "$CBL" "HAS443=0" "certbot ANINDA diskte yalnız faz-1 vardı (443 yok)"
UPC="${LAB}/conf.d/srvctl-fmup-example_com.conf"
assert_contains "$(cat "$UPC")" "ssl_certificate     ${LAB}/le-live/up.example.com/fullchain.pem;" "sonra TAM dosya (443 + LE yolu)"
assert_eq "$(_reloads)" "4" "fm-auth on(1) + tls-default on + faz 1 + faz 2 reload"
assert_eq "$(cu -o /dev/null -w '%{http_code}' "${UPU}/")" "404" "up kökü: 404 (444 değil)"
assert_eq "$(curl -sS -q -k --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' --resolve "${UPH}:${LP_TLS}:127.0.0.1" "https://${UPH}:${LP_TLS}/")" "404" "SNI+Host up: 404"
h2=$(curl -sS -q -k --noproxy '*' --max-time 5 --http2 -D - -o /dev/null --resolve "${UPH}:${LP_TLS}:127.0.0.1" -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: PUT' "${UPU}/_fm/up/1/0" 2>/dev/null | tr -d '\r')
assert_contains "$h2" "HTTP/2 204" "HTTP/2 üzerinden de ön uçuş 204 (listen ssl http2 ile)"

echo "══ 2: OPTIONS ön uçuşu (K9) ══"
assert_eq "$(pre https://example.com PUT /_fm/up/1/0)" "204|1" "izinli köken + ACRM PUT + biçimli yol → 204 + ACAO"
h=$(cuh -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: PUT' "${UPU}/_fm/up/12/345")
assert_eq "$(H_val "$h" access-control-allow-origin)" "https://example.com" "ACAO tam köken (yansıtma değil sabit)"
assert_eq "$(H_val "$h" access-control-allow-methods)" "PUT" "Allow-Methods: PUT"
assert_eq "$(H_val "$h" access-control-allow-headers)" "X-Fm-Ticket, Content-Type" "Allow-Headers"
assert_eq "$(H_val "$h" access-control-max-age)" "600" "Max-Age 600"
assert_eq "$(H_val "$h" vary)" "Origin" "Vary: Origin"
assert_eq "$(H_has "$h" access-control-allow-credentials)" "0" "ACAC YOK"
assert_contains "$(H_val "$h" strict-transport-security)" "max-age=63072000; includeSubDomains" "HSTS"
assert_eq "$(H_val "$h" x-content-type-options)" "nosniff" "nosniff"
assert_eq "$(H_val "$h" cache-control)" "no-store" "Cache-Control: no-store"
for o in "https://evil.example" "null" "https://example.com.evil.example" "http://example.com" "https://sub.example.com" "https://EXAMPLE.com.evil.example" "*"; do
    assert_eq "$(pre "$o" PUT /_fm/up/1/0)" "403|0" "yabancı köken '${o}' → 403, ACAO YOK"
done
assert_eq "$(pre "" PUT /_fm/up/1/0)" "403|0" "Origin başlığı yok → 403"
# İzinli köken + bozuk ön uçuş: yanıt 403'tür (tarayıcı ön uçuşu başarısız sayar); ACAO yalnız Origin'e bağlıdır, 403'te zararsız.
assert_eq "$(pre https://example.com GET /_fm/up/1/0 | cut -d'|' -f1)" "403" "ACRM GET → 403"
assert_eq "$(pre https://example.com "" /_fm/up/1/0 | cut -d'|' -f1)" "403" "ACRM yok → 403"
for pth in /_fm/up/1 /_fm/up/1/0/9 "/_fm/up/1/0?x=1" /_fm/up/a/0 /_fm/up/1/-1 /_fm/up/../x /other /; do
    assert_eq "$(pre https://example.com PUT "$pth" | cut -d'|' -f1)" "403" "biçimsiz/yabancı yol '${pth}' → 403 (204 DEĞİL)"
    assert_eq "$(pre https://evil.example PUT "$pth")" "403|0" "yabancı köken + '${pth}' → 403, ACAO YOK"
done
assert_eq "$(pre https://example.com PUT /_fm/up/$(printf '9%.0s' $(seq 1 21))/0 | cut -d'|' -f1)" "403" "21 haneli kimlik → 403"

echo "══ 3: PUT (K5/K6/K9) ══"
: > "$LAB/logs/auth.log"; : > "$LAB/logs/pcloud.log"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" -H 'Content-Type: application/octet-stream' --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/0")" "200|1" "geçerli bilet + CL → 200 (sahte pCloud) + ACAO"
PCL="$(cat "$LAB/logs/pcloud.log")"
assert_contains "$PCL" "PUT /upload_write?uploadid=12&uploadoffset=0 auth=[Bearer lab-token]" "pCloud'a doğru uploadid/offset + Authorization (auth sonucundan)"
assert_contains "$PCL" "ticket=[-]" "bilet pCloud'a İLETİLMEDİ (günlükte '-')"
assert_contains "$PCL" "cookie=[-]" "çerez pCloud'a iletilmedi"
assert_eq "$(lines "$LAB/logs/auth.log")" "1" "auth ucu 1 kez çağrıldı"
assert_eq "$(put -H "X-Fm-Ticket: $OTHER" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/1")" "403|1" "biçimli ama reddedilen bilet → 403 + ACAO (auth çağrılır)"
assert_eq "$(lines "$LAB/logs/auth.log")" "2" "reddedilen bilet auth'a gitti"
a0=$(lines "$LAB/logs/auth.log")
for t in "short" "$(printf 'A%.0s' $(seq 1 64))" "${GOOD}0" "${GOOD:1}" "g$(printf 'a%.0s' $(seq 1 63))" ""; do
    assert_eq "$(put ${t:+-H "X-Fm-Ticket: $t"} --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/2")" "403|1" "K5: biçimsiz bilet '${t:0:12}…' → 403 + ACAO"
done
assert_eq "$(lines "$LAB/logs/auth.log")" "$a0" "K5: biçimsiz biletlerin HİÇBİRİ auth ucuna (FPM/DB) ulaşmadı"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" "${UPU}/_fm/up/12/3")" "411|1" "geçerli bilet, Content-Length yok → 411 + ACAO"
h=$(cuh -X PUT -H 'Expect:' -H "X-Fm-Ticket: $GOOD" "${UPU}/_fm/up/12/3")
body=$(cu -X PUT -H 'Expect:' -H "X-Fm-Ticket: $GOOD" "${UPU}/_fm/up/12/3")
assert_contains "$body" "srvctl-fm-open $(_domconf_fm_body_sig example_com)" "411 gövdesi alana özgü AÇIK imzasını taşır (status sondası tanır)"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" -H 'Content-Length: 40000000' --max-time 4 "${UPU}/_fm/up/12/4")" "413|1" "K6: gövde > 33m → 413 + ACAO"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" -H 'Content-Length: 34603008' --max-time 4 "${UPU}/_fm/up/12/4")" "413|1" "K6: 33 MiB + 1 MiB → 413 (sınır tam 33m)"
assert_eq "$(cuh -X GET -H 'Origin: https://example.com' "${UPU}/_fm/up/1/0" | head -1 | cut -d' ' -f2)" "403" "GET /_fm/up/… → 403 (limit_except PUT)"
assert_eq "$(H_has "$(cuh -X GET -H 'Origin: https://example.com' "${UPU}/_fm/up/1/0")" access-control-allow-origin)" "1" "GET 403'ünde de ACAO"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/1/0?x=1")" "403|1" "sorgu dizeli yol → 403"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" --path-as-is "${UPU}/_fm/up/1/../0")" "403|1" "'..' → 403"
# 502: pCloud ulaşılamaz
write_pc_upstream "$LP_DEAD"; lab_reload
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/5")" "502|1" "pCloud ulaşılamaz → 502 + ACAO (istemci 'ağ hatası' yerine 502'yi görür)"
write_pc_upstream "$LP_PC"; lab_reload
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/6")" "200|1" "pCloud geri gelince 200"
# yabancı köken PUT: ACAO YOK (istek yine işlenir; tarayıcı yanıtı okumaz)
h=$(cuh -X PUT -H 'Expect:' -H 'Origin: https://evil.example' -H "X-Fm-Ticket: $OTHER" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/7")
assert_eq "$(H_has "$h" access-control-allow-origin)" "0" "yabancı köken PUT yanıtında ACAO YOK"

echo "══ 4: başka yol 404, ad alanı kapalı (K4) ══"
for pth in / /index.php /robots.txt /_fm /_fm/ /_fm/x /_fm/dl /_fm/up /_fm/upx/1/0 /__fm_auth /__fm_dl /__fm_x /.env /admin "/_fm/up/../../x"; do
    assert_eq "$(cu -o /dev/null -w '%{http_code}' --path-as-is "${UPU}${pth}")" "404" "GET ${pth} → 404"
done
assert_eq "$(cu -o /dev/null -w '%{http_code}' -X POST -d x "${UPU}/_fm/up/1/0")" "403" "POST /_fm/up/… → 403 (limit_except)"
assert_not_contains "$(cu "${UPU}/")" "APP" "up bloğu ana vhost içeriğini SUNMAZ"
assert_eq "$(cu -o /dev/null -w '%{http_code}' -H 'Host: example.com' "${UPU}/")" "200" "BİLİNEN SINIR (T1): SNI=up + Host=example.com ana vhost'a düşer — köken kilidi bunun içindir (bkz. §6)"
assert_not_contains "$(grep -v '^[[:space:]]*#' "$UPC")" "00-custom" "up bloğu 00-custom'u içermez (yorum dışı)"
assert_eq "$(grep -v '^[[:space:]]*#' "$UPC" | grep -c '^[[:space:]]*include ')" "2" "yalnız iki include (20, 90)"

hdr_wait() {   # yarım başlıkla bekleyen TLS bağlantısının sunucu tarafından kesilme süresi (sn); python3 yoksa boş
    python3 -I -c '
import socket, ssl, sys, time
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=25)
t = ctx.wrap_socket(s, server_hostname=sys.argv[2])
t.sendall(b"PUT /_fm/up/1/0 HTTP/1.1\r\nHost: " + sys.argv[2].encode() + b"\r\n")
t0 = time.time()
try:
    while True:
        d = t.recv(1024)
        if not d: break
except Exception:
    pass
print("closed-after=%.0f" % (time.time() - t0))
' "$LP_TLS" "$UPH" 2>&1
}
echo "══ 4b: K7 başlık zaman aşımı (10 sn) ══"
if command -v python3 >/dev/null 2>&1; then
    out=$(hdr_wait)
    el="${out##*closed-after=}"
    assert_eq "$([[ "$el" =~ ^[0-9]+$ ]] && (( el >= 9 && el <= 12 )) && echo ok || echo "${out}")" "ok" "yarım başlıkla bekleyen bağlantı ~10 sn'de (client_header_timeout 10s) sunucu tarafından kesildi (ölçülen: ${el} sn)"
else
    echo "  ATLANDI: python3 yok — başlık zaman aşımı ölçülemedi"
fi

echo "══ 5: günlük + ModSecurity (K11) ══"
kh=$(curl -sS -q --noproxy '*' --max-time 5 -D - -o /dev/null "http://127.0.0.1:${LP_APP}/k11" 2>/dev/null | tr -d '\r')
assert_eq "$(H_has "$kh" x-srv-level)|$(H_has "$kh" x-orig-location)" "1|0" "K11 kanıtı: error_page ile girilen adlı location SUNUCU düzeyi yapılandırmayı devralır, çağıran location'ınkini DEĞİL → http düzeyi 'modsecurity on' @fm_deny'a iner; bu yüzden 20'de @fm_deny'a MODSEC_LINE gerekir"
: > "$UPLOG"
put -H "X-Fm-Ticket: ${MARK}" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/8" >/dev/null
put -H "X-Fm-Ticket: ${GOOD}" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/9" >/dev/null
put -H "X-Fm-Ticket: ${OTHER}" -H 'Authorization: Bearer topsecret' --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/10" >/dev/null
sleep 0.3
assert_ne "$(lines "$UPLOG")" "0" "erişim günlüğü yazıldı (sınama boş değil)"
assert_eq "$(grep -cE '[0-9a-f]{64}' "$UPLOG")" "0" "günlükte 64-hex DİZİSİ yok"
assert_eq "$(grep -c "$MARK" "$UPLOG" "$UPERR" | awk -F: '{s+=$2} END{print s+0}')" "0" "izlenen bilet günlüklerde 0"
assert_eq "$(grep -c "$GOOD" "$UPLOG" "$UPERR" | awk -F: '{s+=$2} END{print s+0}')" "0" "geçerli bilet günlüklerde 0"
assert_eq "$(grep -ci 'lab-token\|topsecret\|bearer' "$UPLOG" "$UPERR" | awk -F: '{s+=$2} END{print s+0}')" "0" "Authorization/Bearer günlüklerde 0"
assert_contains "$(cat "$UPLOG")" '"PUT /_fm/up/12/9"' "günlük satırı biçimi (yöntem + yol, başlık YOK)"
assert_not_contains "$(grep -E '^[[:space:]]*(access_log|error_log)' "$UPC")" "debug" "hata günlüğü debug değil"

echo "══ 6: fm-auth off ⇒ up kendiliğinden kapanır (kapılar TEK KAYNAK) ══"
sig=$(_domconf_fm_body_sig example_com)
( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; rc=$?
if (( rc != 0 )); then sed 's/^/    [fm-auth off] /' "$OUTF" >&2; fi
assert_eq "$rc" "0" "fm-auth off rc 0"
assert_eq "$(cu -X PUT -H 'Expect:' -H "X-Fm-Ticket: $GOOD" "${UPU}/_fm/up/12/11")" "srvctl-fm-closed ${sig}" "up PUT (geçerli bilet) → 403 KAPALI imzası"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/11")" "403|1" "up PUT → 403 + ACAO (kapalıyken de istemci 403'ü görür)"
a1=$(lines "$LAB/logs/auth.log"); pc1=$(lines "$LAB/logs/pcloud.log")
put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/12" >/dev/null
assert_eq "$(lines "$LAB/logs/auth.log")" "$a1" "kapalı: auth ucuna ve"
assert_eq "$(lines "$LAB/logs/pcloud.log")" "$pc1" "kapalı: pCloud'a istek 0"
assert_eq "$(pre https://example.com PUT /_fm/up/1/0)" "204|1" "NOT: ön uçuş yapılandırma düzeyindedir, kapalıyken de 204 (PUT 403 ile biter)"
assert_eq "$(_exists "$F90")|$(_exists "$F21")" "yok|yok" "90/21 silindi (up bloğunun 90 glob'u sıfır eşleşme)"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/13")" "200|1" "fm-auth yeniden on → up yeniden açılır"
# acil kapanış
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
assert_eq "$(cu -X PUT -H 'Expect:' -H "X-Fm-Ticket: $GOOD" "${UPU}/_fm/up/12/14")" "srvctl-fm-closed ${sig}" "ACİL kapanış up'ı da kapatır (KAPALI imzası)"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/15")" "200|1" "acil sonrası açık 'on' ile up yeniden açılır"

echo "══ 7: K8 oran sınırı (düşük sınırla yeniden render) ══"
( FMUP_RATE_IP=1 FMUP_BURST_IP=3 _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "düşük sınırla fm-up yeniden on (idempotent yeniden yazım) rc 0"
assert_contains "$(cat "$UPC")" "rate=1r/s;" "oran yapılandırmadan"
codes=""; acao=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    h=$(cuh -X PUT -H 'Expect:' -H "Origin: https://example.com" -H "X-Fm-Ticket: $OTHER" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/2${i}")
    c=$(H_code "$h"); codes+="$c "; if [[ "$c" == "429" ]]; then acao=$(( acao + $(H_has "$h" access-control-allow-origin) )); fi
done
n429=$(tr ' ' '\n' <<< "$codes" | grep -c '^429$')
assert_ne "$n429" "0" "burst aşılınca 429 döner (kodlar: ${codes% })"
assert_eq "$acao" "$n429" "TÜM 429 yanıtlarında ACAO var"
assert_contains "$(grep -E 'limit_conn |limit_req ' "$UPC" | tr -s ' ')" "limit_conn fmup_cip_example_com 12;" "limit_conn IP başına 12 (yapısal; eşzamanlı bağlantı sınaması arka plan süreci gerektirir)"
sleep 3
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/30")" "200|1" "varsayılan sınırlara dönüldü: 200"

echo "══ 8: köken kilidi (gerçek trusted sync, gerçek eş adresi) ══"
LAN=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
if [[ -z "$LAN" ]]; then
    echo "  ATLANDI: makinede loopback dışı IPv4 yok — sunucu-dışı eş taklit edilemez"
else
    LANNET="${LAN%.*}.0/24"
    EX="https://example.com:${LP_TLS}/"
    exu() { curl -sS -q -k --http1.1 --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' --resolve "example.com:${LP_TLS}:127.0.0.1" "$@" 2>/dev/null; }
    sync_cf() { ( SRVCTL_SELF_IPS="$1" _trusted_sync ) >"$LAB/sync.out" 2>&1; }
    # CF listesi LAN'ı İÇERMİYOR, kendi IP listesi boş
    cp "$CF_V4_BASE" "$LAB/fix/cloudflare-v4"
    sync_cf ""
    assert_contains "$(cat "$NGINX_CF_GEO_CONF")" 'geo $realip_remote_addr $srvctl_via_cf {' "sync gerçek geo dosyasını üretti"
    assert_contains "$(cat "$NGINX_CF_REALIP_CONF")" "set_real_ip_from 10.77.3.0/24;" "aynı sync realip dosyasını da üretti (aynı liste)"
    assert_contains "$(cat "$NGINX_CF_GEO_CONF")" "10.77.3.0/24 1;" "geo aynı CF listesinden"
    assert_not_contains "$(cat "$NGINX_CF_GEO_CONF")" "$LAN" "geo LAN adresini İÇERMİYOR (sunucu-dışı eş)"
    assert_eq "$(exu "$EX")" "200" "kilit KAPALI: LAN eşi de geçer (200)"
    assert_eq "$(exu --interface "$LAN" "$EX")" "200" "kilit KAPALI: 'dış' eş 200 (kontrol)"
    ( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
    if (( rc != 0 )); then sed 's/^/    [origin-lock on] /' "$OUTF" >&2; fi
    assert_eq "$rc" "0" "origin-lock on rc 0 (gerçek nginx -t geçti)"
    assert_eq "$(exu "$EX")" "200" "127.0.0.1 eşi geçer (yerel sondalar)"
    assert_eq "$(exu --interface "$LAN" "$EX")" "000" "CF dışı eş (${LAN}) → 444 (boş yanıt)"
    assert_eq "$(exu --interface "$LAN" -H 'CF-Connecting-IP: 127.0.0.1' "$EX")" "000" "sahte CF-Connecting-IP başlığı güvenilmeyen eşi KURTARMAZ"
    assert_eq "$(exu --interface "$LAN" -H 'CF-Connecting-IP: 10.77.3.9' "$EX")" "000" "CF aralığı IP'li sahte başlık da kurtarmaz (geo ORİJİNAL eşe bakar)"
    assert_eq "$(exu --interface "$LAN" -H 'X-Forwarded-For: 127.0.0.1' "$EX")" "000" "X-Forwarded-For kurtarmaz"
    # up bloğu kilitli DEĞİL (DNS-only; kilit custom.d 05'te, up yalnız 20/90'ı glob'lar)
    h=$(cuh --interface "$LAN" -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: PUT' "${UPU}/_fm/up/1/0")
    assert_eq "$(H_code "$h")" "204" "up bloğu CF dışı eşe 204 verir (kilitlenmedi)"
    # "CF" eşi: LAN /24 CF listesine girer → geçer; sahte başlık gerçek istemci olarak yansır
    { for i in 1 2 3 4 5 6 7 8 9 10 11; do echo "10.77.${i}.0/24"; done; echo "$LANNET"; } > "$LAB/fix/cloudflare-v4"
    sync_cf ""
    assert_contains "$(cat "$NGINX_CF_GEO_CONF")" "${LANNET} 1;" "LAN aralığı artık 'CF' listesinde"
    assert_eq "$(exu --interface "$LAN" "$EX")" "200" "'CF' eşi (listedeki aralık) geçer"
    assert_eq "$(exu --interface "$LAN" -H 'CF-Connecting-IP: 203.0.113.9' "$EX")" "200" "'CF' eşi + CF-Connecting-IP → geçer"
    # kendi IP
    cp "$CF_V4_BASE" "$LAB/fix/cloudflare-v4"
    sync_cf "$LAN"
    assert_contains "$(cat "$NGINX_CF_GEO_CONF")" "${LAN} 1;" "kendi IP geo'da"
    assert_eq "$(exu --interface "$LAN" "$EX")" "200" "sunucunun kendi IP'si geçer"
    # liste boşken sync geo'yu BOZMAZ ve kilit yeni listeyle değişmez
    sync_cf ""
    : > "$LAB/fix/cloudflare-v4"; : > "$LAB/fix/cloudflare-v6"
    geo_b=$(cat "$NGINX_CF_GEO_CONF")
    sync_cf ""
    assert_eq "$(cat "$NGINX_CF_GEO_CONF")" "$geo_b" "boş fetch: geo korunur"
    assert_eq "$(exu --interface "$LAN" "$EX")" "000" "boş fetch sonrası kilit hâlâ aynı listeyle çalışır (LAN dışarıda → 444)"
    cp "$CF_V4_BASE" "$LAB/fix/cloudflare-v4"; printf "$CF_V6_TXT" > "$LAB/fix/cloudflare-v6"
    ( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; rc=$?
    assert_not_contains "$(cat "$OUTF")" "İHLAL" "nginx-audit: üretilmiş kilit ihlal sayılmadı"
    ( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1
    assert_eq "$(exu --interface "$LAN" "$EX")" "200" "kilit KAPALI → LAN eşi tekrar geçer"
    # M1: kiracı custom.d dosyasındaki sunucu düzeyi rewrite/if kuralı kilidi DELEMEZ (kilit edge.d'de, kiracıdan ÖNCE)
    cp "$CF_V4_BASE" "$LAB/fix/cloudflare-v4"; sync_cf ""
    printf 'rewrite ^/blog/(.*)$ /index.php last;\nif ($uri = /t-ret) { return 200 "T"; }\n' > "${CUR_DIR}/00-custom.conf"
    assert_eq "$("$NG" -t -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1 && echo ok || echo bozuk)" "ok" "(ön koşul) kiracı rewrite/if dosyasıyla nginx -t geçer"
    lab_reload
    assert_eq "$(exu --interface "$LAN" "https://example.com:${LP_TLS}/blog/x")" "200" "KONTROL: kilitsiz, kiracı rewrite'ı /blog/x'i 200 yapar"
    ( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
    if (( rc != 0 )); then sed 's/^/    [origin-lock on 8b] /' "$OUTF" >&2; fi
    assert_eq "$rc" "0" "origin-lock on (kiracı rewrite dosyası varken) rc 0"
    assert_eq "$(_exists "${SRVCTL_NGINX_EDGE_DIR}/example_com/05-srvctl-origin-lock.conf")" "var" "kilit edge.d'de"
    assert_eq "$(_exists "${CUR_DIR}/05-srvctl-origin-lock.conf")" "yok" "kilit custom.d'de DEĞİL"
    for pth in / /index.php /blog/x "/blog/admin?id=1" /t-ret /robots.txt; do
        assert_eq "$(exu --interface "$LAN" "https://example.com:${LP_TLS}${pth}")" "000" "M1: CF dışı eş + tenant rewrite/if ${pth} → 444 (HER yol)"
    done
    assert_eq "$(exu --interface "$LAN" -H 'CF-Connecting-IP: 10.77.3.9' "https://example.com:${LP_TLS}/blog/x")" "000" "M1: sahte CF başlığı + rewrite yolu → 444"
    assert_eq "$(exu "https://example.com:${LP_TLS}/blog/x")" "200" "yerel eş (127.0.0.1) tenant rewrite'ını kullanır: 200"
    assert_eq "$(curl -sS -q -k --http1.1 --noproxy '*' --max-time 5 --resolve "example.com:${LP_TLS}:127.0.0.1" "https://example.com:${LP_TLS}/t-ret" 2>/dev/null)" "T" "yerel eş: kiracının if/return kuralı çalışmaya devam eder"
    ( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1
    assert_eq "$(exu --interface "$LAN" "https://example.com:${LP_TLS}/blog/x")" "200" "kilit KAPALI → kiracı rewrite yolu tekrar açık"
    rm -f -- "${CUR_DIR}/00-custom.conf"
fi

echo "══ 9: tls-default ══"
OSC() { openssl s_client -connect "127.0.0.1:${LP_TLS}" "$@" -showcerts </dev/null 2>&1; }
assert_eq "$(_exists "$SRVCTL_TLS_DEFAULT_CONF")" "var" "tls-default zaten açık (gerçek nginx -t: default_server + ssl_reject_handshake geçerli)"
assert_contains "$(cat "$SRVCTL_TLS_DEFAULT_CONF")" "ssl_reject_handshake on;" "dosya"
o=$(OSC); assert_eq "$(grep -c 'BEGIN CERTIFICATE' <<< "$o")" "0" "SNI'sız el sıkışma: sertifika VERİLMEDİ"
assert_ne "$(grep -ciE 'alert|unrecognized|handshake failure' <<< "$o")" "0" "SNI'sız: alert"
o=$(OSC -servername unknown.example.org); assert_eq "$(grep -c 'BEGIN CERTIFICATE' <<< "$o")" "0" "bilinmeyen SNI: sertifika yok"
assert_ne "$(grep -ciE 'alert|unrecognized|handshake failure' <<< "$o")" "0" "bilinmeyen SNI: alert"
assert_eq "$(curl -sk --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${LP_TLS}/" 2>/dev/null)" "000" "curl çıplak IP → 000"
o=$(OSC -servername example.com); assert_ne "$(grep -c 'BEGIN CERTIFICATE' <<< "$o")" "0" "bilinen alan (example.com) etkilenmez: el sıkışma tamam"
o=$(OSC -servername up.example.com); assert_ne "$(grep -c 'BEGIN CERTIFICATE' <<< "$o")" "0" "up.example.com etkilenmez"
assert_eq "$(exu "https://example.com:${LP_TLS}/")" "200" "ana alan 200 (tls-default açıkken)"
assert_eq "$(pre https://example.com PUT /_fm/up/1/0)" "204|1" "up ön uçuşu tls-default açıkken 204"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/40")" "200|1" "up PUT tls-default açıkken 200"
# BLOKER K3: eski sonda (çıplak IP + Host) tls-default ile 000; yeni deploy sondası doğru
old=$(curl -sk --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -H 'Host: example.com' "https://127.0.0.1:${LP_TLS}/" 2>/dev/null)
assert_eq "$old" "000" "NEGATİF KONTROL: eski sonda biçimi (https://127.0.0.1 + Host) tls-default açıkken 000"
assert_eq "$(_deploy_http_code example.com)" "200" "deploy sağlık sondası (--resolve + SNI) tls-default açıkken 200"
assert_eq "$(SRVCTL_PROBE_HTTP_PORT=$LP_DEAD _deploy_http_code nonexistent.example.org)" "000" "deploy sondası bilinmeyen alanda 000 (https SNI reddi, http kapalı: yanlış-olumlu yok)"
# fm probe (status/acil yol): tls-default açıkken doğru
( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1
assert_contains "$(cat "$OUTF")" "AÇIK" "fm-auth status tls-default açıkken AÇIK görür"
assert_not_contains "$(cat "$OUTF")" "doğrulanamadı" "fm sondası kör kalmadı"
# monitor/ssl (K13)
sout=$(_ssl_status 2>&1); assert_contains "$sout" "up.example.com" "K13: ssl status up sertifikasını kapsar"
assert_eq "$(_monitor_up_hosts)" "up.example.com" "K13: monitor up host'unu görür"
assert_ne "$(_monitor_up_cert_raw_days up.example.com)" "" "K13: monitor sertifika gününü okur"
# monitor probu hostname ile (SNI gider): yapısal
assert_eq "$(grep -n 'curl' "${REPO_ROOT}/lib/monitor.sh" | grep -c 'https://127\.0\.0\.1')" "0" "monitor: IP URL'li curl yok"
# M3: tls-default AÇIKKEN de ilk istekte başlık zaman aşımı 10 sn (varsayılan sunucunun değeri bağlantıyı yönetir)
if command -v python3 >/dev/null 2>&1; then
    out=$(hdr_wait); el="${out##*closed-after=}"
    assert_eq "$([[ "$el" =~ ^[0-9]+$ ]] && (( el >= 9 && el <= 12 )) && echo ok || echo "${out}")" "ok" "M3: tls-default AÇIKKEN yarım başlık ~10 sn'de kesildi (ölçülen: ${el} sn; düzeltmeden önce 60)"
fi
( cmd_tls_default off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "tls-default off: fm-up sunucusu AÇIKKEN reddedilir"
assert_contains "$(cat "$OUTF")" "fm-up off" "ileti: önce fm-up off"
assert_eq "$(_exists "$SRVCTL_TLS_DEFAULT_CONF")" "var" "red sonrası tls-default dosyası duruyor"

echo "══ 11: L1 — ön uçuş ve ucuz 403/404 yanıtları limit_req'e SAYILIR ══"
( FMUP_RATE_IP=1 FMUP_BURST_IP=2 _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "düşük sınırla fm-up on rc 0"
n429() { local i c n=0; for i in 1 2 3 4 5 6 7 8 9 10; do c=$(H_code "$("$@")"); [[ "$c" == "429" ]] && n=$((n + 1)); done; echo "$n"; }
sleep 4
assert_ne "$(n429 cuh -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: PUT' "${UPU}/_fm/up/1/0")" "0" "L1: OPTIONS ön uçuş (204) seli 429 alır"
sleep 4
assert_ne "$(n429 cuh -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: PUT' "${UPU}/_fm/up/1/0")" "0" "L1: yabancı köken OPTIONS (403) seli 429 alır"
sleep 4
assert_ne "$(n429 cuh -X GET "${UPU}/other")" "0" "L1: /other (404) seli 429 alır"
sleep 4
assert_ne "$(n429 cuh -X PUT -H 'Expect:' -H 'X-Fm-Ticket: short' -H 'Content-Length: 0' "${UPU}/_fm/up/1/0")" "0" "L1: biçimsiz bilet (403) seli 429 alır"
sleep 4
h=$(cuh -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: PUT' "${UPU}/_fm/up/1/0")
assert_eq "$(H_code "$h")|$(H_has "$h" access-control-allow-origin)" "204|1" "L1 düzeltmesi sonrası ön uçuş hâlâ 204 + ACAO"
sleep 4
assert_eq "$(pre https://example.com PUT /_fm/up/1/0)" "204|1" "ön uçuş 204|ACAO (varsayılan)"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1
sleep 3
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/50")" "200|1" "varsayılan sınırlara dönüldü: 200"

echo "══ 10: fm-up off / remove ══"
( _edge_fmup_cmd example.com off --purge-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off --purge-cert rc 0"
assert_contains "$(cat "$LAB/logs/certbot.log")" "DELETE up.example.com" "sertifika silme çağrısı"
assert_eq "$(_exists "$UPC")" "yok" "up dosyası silindi"
( cmd_tls_default off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "fm-up kapalıyken tls-default off rc 0"
o=$(OSC); assert_ne "$(grep -c 'BEGIN CERTIFICATE' <<< "$o")" "0" "off: SNI'sız el sıkışma yeniden sertifika verir (eski davranış)"
assert_ne "$(cu -o /dev/null -w '%{http_code}' "${UPU}/_fm/up/1/0")" "404" "off sonrası up host'u artık up bloğundan YANIT VERMEZ (varsayılan/ana vhost'a düşer)"
( cmd_tls_default on ) >"$OUTF" 2>&1; assert_eq "$?" "0" "tls-default yeniden on (fm-up on'un ön koşulu)"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1
assert_eq "$?" "0" "yeniden on (sertifika silindi → iki faz tekrar) rc 0"
assert_eq "$(put -H "X-Fm-Ticket: $GOOD" --data-binary @"$LAB/body.bin" "${UPU}/_fm/up/12/41")" "200|1" "yeniden on sonrası PUT 200"
: > "$LAB/logs/certbot.log"
_edge_purge_domain example.com
assert_eq "$(_exists "$UPC")" "yok" "domain remove: up dosyası temizlendi"
assert_contains "$(cat "$LAB/logs/certbot.log")" "DELETE up.example.com" "domain remove: up sertifikası silindi"
cp "$UPLOG" "$LAB/logs/fm-up.access.log.copy" 2>/dev/null; cp "$UPERR" "$LAB/logs/fm-up.error.log.copy" 2>/dev/null
test_summary
