#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# origin-lock / tls-default / fm-up — komut davranışı (nginx/systemctl/certbot/dig TAKLİT) + yapısal şablon kilitleri.
# GERÇEK nginx davranışı tests/test_edge_up_real.sh'ta (SRVCTL_TEST_NGINX).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/edge.sh"
source "${REPO_ROOT}/lib/monitor.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
CONFD="${WEB_ROOT}/.conf.d"; mkdir -p "$CONFD"
export SRVCTL_NGINX_CONF_D="$CONFD"
export NGINX_CF_GEO_CONF="${CONFD}/srvctl-cf-origin-geo.conf"
export TRUSTED_STATE_DIR="${WEB_ROOT}/.trusted"; mkdir -p "$TRUSTED_STATE_DIR"
export SRVCTL_ACME_ROOT="${WEB_ROOT}/.acme"
export SRVCTL_LE_LIVE_DIR="${WEB_ROOT}/.le-live"
export SRVCTL_SELF_IPS="198.51.100.7"
export SRVCTL_NGINX_EDGE_DIR="${WEB_ROOT}/.edge.d"
export SRVCTL_FMUP_LOG_DIR="${WEB_ROOT}/.varlog"; mkdir -p "$SRVCTL_FMUP_LOG_DIR"
mkdir -p "${WEB_ROOT}/example.com/logs"
cf_list() { local i; : > "${TRUSTED_STATE_DIR}/cloudflare.conf"; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "10.0.${i}.0/24" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; for i in 1 2 3 4 5 6; do printf '2400:cb0%x::/32\n' "$i" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; }
cf_list
LOCK="${SRVCTL_NGINX_EDGE_DIR}/example_com/05-srvctl-origin-lock.conf"
EREC="${SRVCTL_STATE_DIR}/_edge/example_com.edge"
GREC="${SRVCTL_STATE_DIR}/_edge/GLOBAL.edge"
UPC="${CONFD}/srvctl-fmup-example_com.conf"
TLSC="${CONFD}/00-srvctl-tls-default.conf"
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
tcount() { local n; n=$(grep -c '^t$' "$NGINX_T_LOG" 2>/dev/null); echo "${n:-0}"; }
require_root() { return 0; }   # birim test: root olmadan
# SSL'li vhost (custom.d yalnız 443 bloğunda)
ssl_vhost() { printf 'server {\n    listen 80;\n    server_name example.com;\n    return 301 https://$server_name$request_uri;\n}\nserver {\n    listen 443 ssl http2;\n    server_name example.com;\n    include /etc/nginx/edge.d/example_com/*.conf;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"; }
geo_ok() { printf '# srvctl\ngeo $realip_remote_addr $srvctl_via_cf {\n    default 0;\n    127.0.0.1 1;\n}\n' > "$NGINX_CF_GEO_CONF"; }

# certbot / dig taklitleri (PATH başı; ham çağrılar günlüğe)
CB_LOG="${FM_STUBS}/certbot.log"; : > "$CB_LOG"
cat > "${FM_STUBS}/certbot" <<'CBEOF'
#!/bin/bash
echo "$*" >> "${CB_LOG:?}"
host=""; prev=""
for a in "$@"; do [[ "$prev" == "-d" || "$prev" == "--cert-name" ]] && host="$a"; prev="$a"; done
if [[ "$1" == "delete" ]]; then echo "DELETE ${host}" >> "$CB_LOG"; exit 0; fi
# çağrı ANINDA conf.d içeriği: faz 1 mi (443 yok), tam mı?
f="${SRVCTL_NGINX_CONF_D}/srvctl-fmup-example_com.conf"
if [[ -f "$f" ]]; then if grep -q 'listen 443' "$f"; then echo "AT-CERTBOT has443=1" >> "$CB_LOG"; else echo "AT-CERTBOT has443=0 has80=$(grep -c 'listen 80' "$f")" >> "$CB_LOG"; fi; else echo "AT-CERTBOT conf-yok" >> "$CB_LOG"; fi
[[ "${CERTBOT_FAIL:-0}" == "1" ]] && { echo "Challenge failed" >&2; exit 1; }
mkdir -p "${SRVCTL_LE_LIVE_DIR}/${host}"
echo CERT > "${SRVCTL_LE_LIVE_DIR}/${host}/fullchain.pem"; echo KEY > "${SRVCTL_LE_LIVE_DIR}/${host}/privkey.pem"
exit 0
CBEOF
cat > "${FM_STUBS}/dig" <<'DGEOF'
#!/bin/bash
t="A"; for a in "$@"; do case "$a" in A|AAAA) t="$a" ;; esac; done
if [[ "$t" == "A" ]]; then printf '%b' "${DIG_A:-}"; else printf '%b' "${DIG_AAAA:-}"; fi
exit 0
DGEOF
chmod +x "${FM_STUBS}/certbot" "${FM_STUBS}/dig"
export CB_LOG SRVCTL_NGINX_CONF_D SRVCTL_LE_LIVE_DIR
# fm-up on, tls-default AÇIK olmasını ŞART koşar: kapıyı yalnız durum olarak kur (reload/nginx -t yok). SEED_TLS=0 → kapalı.
tls_seed() {
    local f sha; f=$(_edge_tls_conf)
    mkdir -p "$(dirname "$f")"; printf '%s\n' "$(_edge_tls_default_render)" > "$f"
    _edge_prepare_dir && sha=$(_domconf_sha256_file "$f") && _edge_rec_set GLOBAL tls-default "$sha" "$f" ""
}
reset_edge() {
    _fm_reset
    rm -rf "${SRVCTL_STATE_DIR:?}/_edge" "${CONFD:?}"/* "${SRVCTL_LE_LIVE_DIR:?}" "${SRVCTL_ACME_ROOT:?}" "${SRVCTL_NGINX_EDGE_DIR:?}" "${SRVCTL_FMUP_LOG_DIR:?}" 2>/dev/null
    mkdir -p "$CONFD" "$CUR_DIR" "$SRVCTL_FMUP_LOG_DIR"; : > "$CB_LOG"
    unset CERTBOT_FAIL; DIG_A="198.51.100.7\n"; DIG_AAAA=""; export DIG_A DIG_AAAA
    NGINX_V_OUT="nginx version: nginx/1.24.0 (Ubuntu)"; unset SRVCTL_NGINX_VERSION
    cf_list
    [[ "${SEED_TLS:-1}" == "1" ]] && tls_seed
}

echo "══ A: ŞABLON — yapısal kilitler (yorum-dışı) ══"
TPL="${REPO_ROOT}/templates/nginx/fm-up-server.conf.tpl"
noc() { grep -v '^[[:space:]]*#' "$1"; }
T=$(noc "$TPL")
assert_contains "$T" "server_name {{FM_UP_HOST}};" "tam server_name (joker/regex/default yok)"
assert_not_contains "$T" "default_server" "up bloğu default_server DEĞİL"
assert_not_contains "$T" "server_name _" "joker ad yok"
assert_contains "$T" "include {{CUSTOM_D}}/{{SAFE_NAME}}/20-srvctl-fm-upload.con[f];" "20 glob ile içerilir"
assert_contains "$T" "include {{CUSTOM_D}}/{{SAFE_NAME}}/90-srvctl-fm-auth.con[f];" "90 glob ile içerilir"
assert_eq "$(printf '%s\n' "$T" | grep -c '^[[:space:]]*include ')" "2" "YALNIZ iki include (21, 00-custom, '*.conf' glob'u YOK)"
assert_not_contains "$T" "21-srvctl" "21 (indirme) girmez"
assert_not_contains "$T" "custom.d/{{SAFE_NAME}}/*" "custom.d joker include YOK"
assert_contains "$T" "ssl_certificate     {{LE_LIVE}}/{{FM_UP_HOST}}/fullchain.pem;" "LE sertifikası (up host'a özgü)"
assert_contains "$T" "location / { return 404; }" "kalan her yol 404"
assert_contains "$T" 'if ($fmup_route_{{SAFE_NAME}} = 0) { rewrite ^ /__fmup_gate last; }' "yol kapısı sunucu-rewrite'ta (karar @fmup_gate'te, limitlerden sonra)"
assert_contains "$T" 'if ($fmup_route_{{SAFE_NAME}} = 0) { return 404; }' "yol kapısı kararı 404 (@fmup_gate içinde)"
assert_contains "$T" 'map $request_uri $fmup_route_{{SAFE_NAME}}' "route map"
assert_contains "$T" '"~^PUT\|/_fm/up/[0-9]{1,20}/[0-9]{1,20}\|[0-9a-f]{64}$" 0;' "K5: 64-hex bilet biçimi (yalnız up bloğunda)"
assert_contains "$T" '"~^OPTIONS\|{{FM_UP_ORIGIN_RE}}\|PUT\|/_fm/up/[0-9]{1,20}/[0-9]{1,20}$" 1;' "K9: tam Origin + ACRM PUT + biçimli yol"
assert_contains "$T" '"~^OPTIONS\|" 2;' "başka OPTIONS → 403 kolu"
assert_contains "$T" 'return 204;' "ön uçuş 204"
assert_contains "$T" "client_max_body_size 1k;" "K6 sunucu 1k"
assert_contains "$T" "client_header_timeout 10s;" "K7 başlık zaman aşımı"
assert_contains "$T" "client_body_timeout 30s;" "K7 gövde zaman aşımı"
assert_contains "$T" "large_client_header_buffers 4 4k;" "K7 başlık tamponu"
assert_contains "$T" "zone=fmup_ip_{{SAFE_NAME}}:" "K8 alana özgü IP bölgesi"
assert_contains "$T" "zone=fmup_all_{{SAFE_NAME}}:" "K8 alana özgü toplam bölge"
assert_contains "$T" "limit_conn_zone \$binary_remote_addr zone=fmup_cip_{{SAFE_NAME}}" "K8 limit_conn IP"
assert_contains "$T" "limit_conn_zone \$server_name        zone=fmup_call_{{SAFE_NAME}}" "K8 limit_conn toplam"
assert_not_contains "$T" "zone=general" "paylaşılan bölge adı kullanılmaz"
assert_not_contains "$T" "zone=conn_per_ip" "paylaşılan conn bölgesi kullanılmaz"
assert_contains "$T" "Strict-Transport-Security \"max-age=63072000; includeSubDomains\" always" "K10 HSTS always"
assert_contains "$T" 'add_header X-Content-Type-Options "nosniff" always;' "nosniff always"
assert_contains "$T" "Access-Control-Allow-Origin  \$fmup_acao_{{SAFE_NAME}} always;" "ACAO always"
assert_contains "$T" "Access-Control-Allow-Methods \$fmup_acam_{{SAFE_NAME}} always;" "ACAM"
assert_contains "$T" "Access-Control-Allow-Headers \$fmup_acah_{{SAFE_NAME}} always;" "ACAH"
assert_contains "$T" "Access-Control-Max-Age       \$fmup_acma_{{SAFE_NAME}} always;" "Max-Age"
assert_contains "$T" 'add_header Vary "Origin" always;' "Vary: Origin"
assert_not_contains "$(printf '%s' "$T" | tr 'A-Z' 'a-z')" "allow-credentials" "ACAC YOK"
assert_not_contains "$T" 'Access-Control-Allow-Origin "*"' "joker ACAO yok"
assert_contains "$T" "{{MODSEC_LINE}}" "ModSecurity satırı (modül yoksa yoruma döner)"
# add_header yalnız SUNUCU düzeyinde: location bloklarında YOK
loc_ah=$(awk '/^[[:space:]]*location /{inloc=1} inloc && /add_header/{print} inloc && /^[[:space:]]*}/{inloc=0}' <<< "$T")
assert_eq "$loc_ah" "" "location içinde add_header YOK (üst blok başlıklarını düşürürdü)"
# günlük: başlık/bilet/$fm_auth YOK
LF=$(grep -E '^log_format' "$TPL")
assert_contains "$LF" "log_format fmup_{{SAFE_NAME}}" "ayrı log_format"
for bad in http_x_fm_ticket http_authorization upstream_http sent_http fm_auth http_origin http_cookie 'http_'; do
    assert_not_contains "$LF" "$bad" "log_format '${bad}' İÇERMEZ"
done
assert_contains "$T" "access_log {{LOG_DIR}}/srvctl-fmup-{{SAFE_NAME}}.access.log fmup_{{SAFE_NAME}};" "root'a ait günlük dizininde srvctl-fmup-<safe>.access.log"
assert_contains "$T" "error_log  {{LOG_DIR}}/srvctl-fmup-{{SAFE_NAME}}.error.log warn;" "hata günlüğü warn"
assert_not_contains "$(grep -E '^[[:space:]]*error_log' "$TPL")" "debug" "debug/info yok"
# faz 1: yalnız port 80, sunucu düzeyinde return YOK, location içinde return var
P1=$(noc "$TPL" | awk '/@@PHASE2/{exit} {print}')
P1b=$(awk '/@@PHASE1/{f=1;next} /@@PHASE2/{exit} f' "$TPL" | grep -v '^[[:space:]]*#')
assert_contains "$P1b" "listen 80;" "faz 1: port 80"
assert_not_contains "$P1b" "listen 443" "faz 1: 443 YOK"
assert_contains "$P1b" "location ^~ /.well-known/acme-challenge/" "faz 1: ACME location"
assert_contains "$P1b" "root {{ACME_ROOT}};" "faz 1: ACME kökü (webroot ile aynı)"
srv_ret=$(awk '/^server \{/{d=1;next} d&&/^    return /{print} ' <<< "$P1b")
assert_eq "$srv_ret" "" "faz 1: SUNUCU DÜZEYİNDE return YOK (certbot renew düşmesin)"
assert_contains "$P1b" "return 301 https://{{FM_UP_HOST}}\$request_uri;" "kalanı 301 (sabit host; \$host KULLANILMAZ)"
assert_not_contains "$P1b" '$host' "\$host kullanılmıyor"
# 20: add_header YOK, @fm_deny MODSEC satırı (K11/W4)
U20=$(noc "${REPO_ROOT}/templates/nginx/fm-upload.conf.tpl")
assert_not_contains "$U20" "add_header" "20'de add_header hâlâ YOK"
fd=$(awk '/location @fm_deny/{f=1} f{print} f&&/^}/{exit}' <<< "$U20")
assert_contains "$fd" "{{MODSEC_LINE}}" "K11: @fm_deny ModSecurity satırını taşır"
assert_contains "$fd" "return 403;" "@fm_deny hâlâ imzasız 403"
# 90: ayrı FPM soketi/tenant izolasyonu aynı kaldı
assert_contains "$(noc "${REPO_ROOT}/templates/nginx/fm-auth.conf.tpl")" "fastcgi_pass unix:/run/php/php{{PHP_VERSION}}-fpm-{{SAFE_NAME}}.sock;" "90: yalnız bu alanın soketi"

echo "══ B: render ══"
reset_edge
out=$(_edge_fmup_render example.com up.example.com https://example.com 1 2); rc=$?
assert_eq "$rc" "0" "faz 2 render rc 0"
assert_not_contains "$out" "{{" "kalan jeton yok"
assert_contains "$out" 'map $http_origin $fmup_acao_example_com {' "değişken adları alana özgü"
assert_contains "$out" '"https://example.com" "https://example.com";' "ACAO yalnız tam kök"
assert_contains "$out" '"~^OPTIONS\|https://example\.com\|PUT\|' "Origin regex'i noktaları kaçırır"
assert_contains "$out" "zone=fmup_ip_example_com:10m rate=5r/s;" "K8 oran (varsayılan 5r/s)"
assert_contains "$out" "limit_conn fmup_cip_example_com  12;" "K8 IP başına 12"
assert_contains "$out" "log_format fmup_example_com " "log_format"
assert_contains "$out" "modsecurity off;" "modsec=1 → modsecurity off"
assert_contains "$out" "listen 443 ssl http2;" "1.24 sözdizimi (http2 on; 1.25+ DEĞİL)"
assert_not_contains "$out" "http2 on;" "1.25+ sözdizimi yok"
p1=$(_edge_fmup_render example.com up.example.com https://example.com 1 1)
assert_not_contains "$p1" "listen 443" "faz 1 render: 443 yok"
assert_contains "$p1" "listen 80;" "faz 1 render: 80 var"
assert_contains "$p1" "log_format fmup_example_com" "faz 1: log_format var (80 bloğu kullanır)"
o0=$(_edge_fmup_render example.com up.example.com https://example.com 0 2)
assert_not_contains "$o0" "modsecurity off;" "modsec=0 → direktif yok"
assert_contains "$o0" "# ModSecurity yüklü değil" "modsec=0 → yorum"

echo "══ C: origin-lock ══"
reset_edge; ssl_vhost
out=$( ( _edge_origin_lock_cmd example.com on ) 2>&1 ); rc=$?
assert_eq "$rc" "1" "geo dosyası yokken on REDDEDİLİR"
assert_contains "$out" "trusted sync" "neden + çare söylenir"
assert_eq "$(_exists "$LOCK")" "yok" "geo yok: kilit dosyası YAZILMADI"
geo_ok
( _edge_origin_lock_cmd example.com on --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "dry rc 0"
assert_eq "$(_exists "$LOCK")" "yok" "dry: dosya yok"
assert_eq "$(_exists "$EREC")" "yok" "dry: kayıt yok"
assert_eq "$(_reloads)" "0" "dry: reload yok"
t0=$(tcount)
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "on rc 0"
assert_eq "$(_exists "$LOCK")" "var" "05-srvctl-origin-lock.conf yazıldı"
assert_contains "$(cat "$LOCK")" 'if ($srvctl_via_cf = 0) { return 444; }' "kilit satırı"
assert_eq "$(_mode "$LOCK")" "644" "dosya 0644"
assert_eq "$(( $(tcount) - t0 ))" "1" "tek nginx -t"
assert_eq "$(_reloads)" "1" "tek reload"
assert_contains "$(cat "$EREC")" "origin-lock $(_domconf_sha256_file "$LOCK") ${LOCK}" "köken kaydı: sha256 + yol"
assert_eq "$(_mode "$EREC")" "600" "kayıt 0600"
assert_eq "$(_mode "${SRVCTL_STATE_DIR}/_edge")" "700" "kayıt dizini 0700"
assert_ok _edge_is_generated example_com "$LOCK"
out=$( ( _edge_origin_lock_cmd example.com status ) 2>&1 ); rc=$?
assert_contains "$out" "origin-lock example.com: AÇIK" "status AÇIK"
assert_eq "$rc" "0" "status AÇIK rc 0"
# nginx-audit tanır: üretilmiş kilit İHLAL değil
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; rc=$?
assert_not_contains "$(cat "$OUTF")" "İHLAL" "nginx-audit: kilit dosyası ihlal sayılmadı"
assert_contains "$(cat "$OUTF")" "köken kilidi (tanındı)" "nginx-audit: tanındı notu"
# kurcalanırsa tanınmaz
printf '# oynandi\nif ($srvctl_via_cf = 0) { return 444; }\n' > "$LOCK"
assert_fail _edge_is_generated example_com "$LOCK"
out=$( ( _edge_origin_lock_cmd example.com status ) 2>&1 ); rc=$?
assert_contains "$out" "BOZUK" "kurcalanmış: status BOZUK"
assert_eq "$rc" "1" "BOZUK rc 1"
( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "kurcalanmış dosya off ile SİLİNMEZ"
assert_eq "$(_exists "$LOCK")" "var" "dosya duruyor"
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "kurcalanmış dosyanın ÜZERİNE on yazmaz"
reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1
before=$(_md5 "$LOCK"); r0=$(_reloads)
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "idempotent: ikinci on rc 0"
assert_eq "$(_md5 "$LOCK")" "$before" "idempotent: içerik aynı"
# off
( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off rc 0"
assert_eq "$(_exists "$LOCK")" "yok" "off: dosya silindi"
assert_eq "$(_exists "$EREC")" "yok" "off: boş kayıt dosyası kaldırıldı"
out=$( ( _edge_origin_lock_cmd example.com status ) 2>&1 )
assert_contains "$out" "KAPALI" "status KAPALI"
( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "kapalıyken off rc 0 (idempotent)"
# nginx -t düşerse geri alınır
reset_edge; ssl_vhost; geo_ok
NGINX_TEST_RC=1
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
NGINX_TEST_RC=0
assert_eq "$rc" "1" "nginx -t düştü → rc 1"
assert_eq "$(_exists "$LOCK")" "yok" "nginx -t düştü: dosya GERİ ALINDI (yok)"
assert_eq "$(_exists "$EREC")" "yok" "kayıt da geri alındı"
assert_eq "$(_reloads)" "0" "reload yapılmadı"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENDİ" "ileti"
assert_eq "$(find "$CUR_DIR" -name '*.srvctl*' | wc -l | tr -d ' ')" "0" "yedek/artık dosya kalmadı"
# off sırasında nginx -t düşerse dosya geri gelir
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1
NGINX_TEST_RC=1
( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1; rc=$?
NGINX_TEST_RC=0
assert_eq "$rc" "1" "off: nginx -t düştü rc 1"
assert_eq "$(_exists "$LOCK")" "var" "off: dosya geri geldi"
assert_ok _edge_is_generated example_com "$LOCK"
# yalnız 443: SSL'siz vhost (custom.d port 80 bloğunda) → reddedilir
reset_edge; geo_ok
printf 'server {\n    listen 80;\n    server_name example.com;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
out=$( ( _edge_origin_lock_cmd example.com on ) 2>&1 ); rc=$?
assert_eq "$rc" "1" "SSL'siz vhost: reddedilir"
assert_contains "$out" "443" "gerekçe: 443"
assert_eq "$(_exists "$LOCK")" "yok" "yazılmadı"
printf 'server {\n    listen 80;\n    server_name example.com;\n    return 301 https://$server_name$request_uri;\n}\nserver {\n    listen 443 ssl;\n    server_name example.com;\n}\n' > "$VHOST"
out=$( ( _edge_origin_lock_cmd example.com on ) 2>&1 ); rc=$?
assert_eq "$rc" "1" "vhost custom.d include ETMİYOR: reddedilir"
assert_contains "$out" "include" "gerekçe: include"
rm -f "$VHOST"
out=$( ( _edge_origin_lock_cmd example.com on ) 2>&1 ); rc=$?
assert_eq "$rc" "1" "vhost yok: reddedilir (fail-closed)"
# 80 + 443 İKİSİ de include ediyorsa (443 olmayan blok içeriyor) reddedilir
ssl_vhost
printf 'server {\n    listen 80;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' >> "$VHOST"
out=$( ( _edge_origin_lock_cmd example.com on ) 2>&1 ); rc=$?
assert_eq "$rc" "1" "port 80 bloğu da include ediyorsa reddedilir"
# güvenilmez custom.d
ssl_vhost; mkdir -p "${SRVCTL_NGINX_EDGE_DIR}/example_com"; MOCK_BAD_OWNER="$(cd "${SRVCTL_NGINX_EDGE_DIR}/example_com" && pwd -P)"
out=$( ( _edge_origin_lock_cmd example.com on ) 2>&1 ); rc=$?
MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "güvenilmez custom.d: HİÇBİR ŞEY yazılmaz"
assert_eq "$(_exists "$LOCK")" "yok" "dosya yok"
# argüman doğrulama
( _edge_origin_lock_cmd example.com ) >/dev/null 2>&1; assert_eq "$?" "1" "eylemsiz ret"
( _edge_origin_lock_cmd example.com bogus ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen eylem ret"
( _edge_origin_lock_cmd example.com on --x ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek ret"
( _edge_origin_lock_cmd nonexistent.test on ) >/dev/null 2>&1; assert_eq "$?" "1" "olmayan alan ret"
assert_contains "$(_edge_origin_lock_cmd --capabilities)" "srvctl-origin-lock-caps v1" "--capabilities"

echo "══ D: tls-default ══"
SEED_TLS=0 reset_edge
( cmd_tls_default on --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "dry rc 0"; assert_eq "$(_exists "$TLSC")" "yok" "dry: yazılmadı"
t0=$(tcount)
( cmd_tls_default on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "on rc 0"
assert_contains "$(cat "$TLSC")" "listen 443 ssl default_server;" "default_server"
assert_contains "$(cat "$TLSC")" "ssl_reject_handshake on;" "ssl_reject_handshake"
assert_eq "$(_mode "$TLSC")" "644" "0644"
assert_eq "$(( $(tcount) - t0 ))" "1" "tek nginx -t"; assert_eq "$(_reloads)" "1" "tek reload"
assert_contains "$(cat "$GREC")" "tls-default $(_domconf_sha256_file "$TLSC") ${TLSC}" "kayıt"
assert_contains "$( ( cmd_tls_default status ) 2>&1 )" "tls-default: AÇIK" "status AÇIK"
( cmd_tls_default off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off rc 0"
assert_eq "$(_exists "$TLSC")" "yok" "off: dosya silindi"; assert_eq "$(_exists "$GREC")" "yok" "off: kayıt gitti"
assert_contains "$( ( cmd_tls_default status ) 2>&1 )" "KAPALI" "status KAPALI"
# sürüm kapısı
NGINX_V_OUT="nginx version: nginx/1.18.0"
( cmd_tls_default on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "nginx 1.18 < 1.19.4: ret"; assert_eq "$(_exists "$TLSC")" "yok" "yazılmadı"
assert_contains "$(cat "$OUTF")" "1.19.4" "gerekçe"
NGINX_V_OUT="nginx version: nginx/1.19.4"; ( cmd_tls_default on ) >/dev/null 2>&1; assert_eq "$?" "0" "tam 1.19.4 kabul"
( cmd_tls_default off ) >/dev/null 2>&1
NGINX_V_OUT="nginx version: nginx/1.19.3"; ( cmd_tls_default on ) >/dev/null 2>&1; assert_eq "$?" "1" "1.19.3 ret"
NGINX_V_OUT="nginx version: nginx/mock"; ( cmd_tls_default on ) >/dev/null 2>&1; assert_eq "$?" "1" "sürüm okunamadı: AÇILMAZ (fail-closed)"
assert_ok _edge_ver_ge 1.28.0 1.19.4; assert_ok _edge_ver_ge 1.24.0 1.19.4; assert_fail _edge_ver_ge 1.9.9 1.19.4; assert_ok _edge_ver_ge 2.0.0 1.19.4
# nginx -t düşerse geri
NGINX_V_OUT="nginx version: nginx/1.24.0"
NGINX_TEST_RC=1; ( cmd_tls_default on ) >"$OUTF" 2>&1; rc=$?; NGINX_TEST_RC=0
assert_eq "$rc" "1" "nginx -t düştü rc 1"; assert_eq "$(_exists "$TLSC")" "yok" "dosya geri alındı"; assert_eq "$(_exists "$GREC")" "yok" "kayıt geri alındı"
# kayıtsız dosyanın üzerine yazmaz / silmez
printf 'elle\n' > "$TLSC"
( cmd_tls_default on ) >/dev/null 2>&1; assert_eq "$?" "1" "kayıtsız dosyanın ÜZERİNE yazmaz"
( cmd_tls_default off ) >/dev/null 2>&1; assert_eq "$?" "1" "kayıtsız dosyayı SİLMEZ"
assert_eq "$(cat "$TLSC")" "elle" "içerik korunur"
( cmd_tls_default bogus ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen eylem ret"
assert_contains "$(cmd_tls_default --capabilities)" "srvctl-tls-default-caps v1" "--capabilities"

echo "══ E: fm-up — DNS kapısı ══"
reset_edge
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "DNS tamam (A = kendi IPv4, CF dışı): on rc 0"
reset_edge; DIG_A=""; ( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "A kaydı yok: DUR"; assert_contains "$(cat "$OUTF")" "A kaydı yok" "ileti"; assert_eq "$(_exists "$UPC")" "yok" "yazılmadı"; assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "certbot çağrılmadı"
reset_edge; DIG_A="10.0.3.9\n"; ( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "CF aralığında (turuncu bulut): DUR"; assert_contains "$(cat "$OUTF")" "Cloudflare aralığında" "ileti"; assert_eq "$(_exists "$UPC")" "yok" "yazılmadı"
reset_edge; DIG_A="203.0.113.50\n"; ( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "başka IP: DUR"; assert_contains "$(cat "$OUTF")" "kendi IPv4" "ileti"
reset_edge; DIG_A="198.51.100.7\n203.0.113.50\n"; ( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "iki kayıttan biri yabancı: DUR"
reset_edge; DIG_AAAA="2001:db8::1\n"; ( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "AAAA var: DUR"; assert_contains "$(cat "$OUTF")" "AAAA" "ileti"
reset_edge; DIG_A="up-edge.cdn.cloudflare.net.\n"; ( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "CNAME/çöp: DUR"
reset_edge; DIG_A="198.51.100.7\n"; ( SRVCTL_SELF_IPS="" _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "kendi IPv4 belirlenemedi: DUR"
reset_edge; DIG_A="203.0.113.50\n"; ( SRVCTL_PUBLIC_IPV4="203.0.113.50" _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "0" "NAT: SRVCTL_PUBLIC_IPV4 ile eşleşme kabul"
reset_edge; ( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "0" "dry rc 0"
assert_eq "$(_exists "$UPC")" "yok" "dry: yazılmadı"; assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "dry: certbot yok"; assert_eq "$(_reloads)" "0" "dry: reload yok"
DIG_A=""; ( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "dry de DNS kapısından geçer"; DIG_A="198.51.100.7\n"
assert_ok _edge_ip_in_cidr 10.0.3.9 10.0.3.0/24; assert_fail _edge_ip_in_cidr 10.0.4.9 10.0.3.0/24; assert_ok _edge_ip_in_cidr 1.2.3.4 1.2.3.4; assert_fail _edge_ip_in_cidr 1.2.3.5 1.2.3.4/32; assert_ok _edge_ip_in_cidr 200.1.2.3 128.0.0.0/1

echo "══ F: fm-up — parametre doğrulama ══"
reset_edge
for badh in up.other.org example.com www.example.com a.b.example.com UP.example.com "up.example.com;x" ".example.com"; do
    ( _edge_fmup_cmd example.com on "--host=${badh}" ) >/dev/null 2>&1; assert_eq "$?" "1" "geçersiz --host reddedilir: ${badh}"
done
for bado in http://example.com https://example.com:8443 https://evil.com https://example.com/x "https://example.com.evil.com" "*" null; do
    ( _edge_fmup_cmd example.com on "--origin=${bado}" ) >/dev/null 2>&1; assert_eq "$?" "1" "geçersiz --origin reddedilir: ${bado}"
done
assert_eq "$(_exists "$UPC")" "yok" "hiçbiri yazmadı"
( _edge_fmup_cmd example.com on --purge-cert ) >/dev/null 2>&1; assert_eq "$?" "1" "--purge-cert yalnız off ile"
( _edge_fmup_cmd example.com on --bogus ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek"
( _edge_fmup_cmd nonexistent.test on ) >/dev/null 2>&1; assert_eq "$?" "1" "olmayan alan"
( _edge_fmup_cmd example.com on --origin=https://www.example.com --host=cdn.example.com ) >/dev/null 2>&1; assert_eq "$?" "0" "www kökeni + başka tek etiketli host kabul"
assert_contains "$(cat "$UPC")" '"https://www.example.com" "https://www.example.com";' "www kökeni yazıldı"

echo "══ G: fm-up — iki faz ══"
reset_edge
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "on rc 0"
assert_contains "$(cat "$CB_LOG")" "certonly --webroot -w ${SRVCTL_ACME_ROOT} -d up.example.com" "certbot certonly --webroot -w <acme> -d <host>"
assert_contains "$(cat "$CB_LOG")" "AT-CERTBOT has443=0 has80=1" "certbot ANINDA yalnız port 80 bloğu vardı (faz 1)"
assert_eq "$(_exists "$UPC")" "var" "conf.d/srvctl-fmup-example_com.conf"
assert_contains "$(cat "$UPC")" "listen 443 ssl http2;" "sonunda TAM dosya (443 var)"
assert_eq "$(_mode "$UPC")" "644" "0644"
assert_eq "$(_reloads)" "2" "iki reload (faz 1 + faz 2)"
assert_contains "$(cat "$EREC")" "fm-up $(_domconf_sha256_file "$UPC") ${UPC} up.example.com https://example.com" "kayıt: sha + yol + host + köken"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "2" "iki nginx -t"
assert_eq "$(_exists "$SRVCTL_ACME_ROOT")" "var" "ACME kökü oluşturuldu"
# canlı sunucuda sertifika zaten varsa faz 1 atlanır
reset_edge; mkdir -p "${SRVCTL_LE_LIVE_DIR}/up.example.com"; echo C > "${SRVCTL_LE_LIVE_DIR}/up.example.com/fullchain.pem"; echo K > "${SRVCTL_LE_LIVE_DIR}/up.example.com/privkey.pem"
( _edge_fmup_cmd example.com on --adopt-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "sertifika var: rc 0"; assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "certbot ÇAĞRILMADI"; assert_eq "$(_reloads)" "1" "tek reload"
# status
out=$( ( _edge_fmup_cmd example.com status ) 2>&1 ); rc=$?
assert_contains "$out" "fm-up example.com: AÇIK (host: up.example.com, köken: https://example.com)" "status AÇIK"
assert_contains "$out" "sertifika: up.example.com" "status: sertifika satırı"
assert_contains "$out" "DNS: up.example.com → sunucunun kendi IPv4'ü" "status: DNS tamam"
assert_eq "$rc" "0" "status rc 0"
DIG_A="10.0.1.1\n"; out=$( ( _edge_fmup_cmd example.com status ) 2>&1 ); rc=$?; DIG_A="198.51.100.7\n"
assert_contains "$out" "DNS UYARI" "status: turuncu bulut UYARI"; assert_eq "$rc" "1" "status UYARI rc 1"
# ssl status (K13) up sertifikasını kapsar
hosts=$(_edge_fmup_hosts); assert_eq "$hosts" "up.example.com" "kayıtlı up host listesi (ssl status/monitor için)"
# nginx-audit tanır; kurcalanırsa bulgu
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1
assert_contains "$(cat "$OUTF")" "fm-up srvctl üretimi up sunucu bloğu (tanındı)" "nginx-audit: fm-up tanındı"
printf '# oynandi\n' >> "$UPC"
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; rc=$?
assert_contains "$(cat "$OUTF")" "FM-UP-SAĞLAM-DEĞİL" "nginx-audit: kurcalanmış fm-up bulgu"
assert_ne "$rc" "0" "nginx-audit rc != 0"
assert_contains "$( ( _edge_fmup_cmd example.com status ) 2>&1 )" "BOZUK" "status BOZUK"
( _edge_fmup_cmd example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "1" "kurcalanmış up dosyası off ile SİLİNMEZ"
# yeniden on: kayıtsız/kurcalanmış üzerine yazmaz
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "kurcalanmışın ÜZERİNE on yazmaz"

echo "══ H: fm-up — geri alma ══"
reset_edge; CERTBOT_FAIL=1; export CERTBOT_FAIL
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
unset CERTBOT_FAIL
assert_eq "$rc" "1" "certbot düştü: rc 1"
assert_eq "$(_exists "$UPC")" "yok" "faz 1 dosyası GERİ ALINDI (başlangıçta yoktu)"
assert_eq "$(_exists "$EREC")" "yok" "kayıt yok"
assert_eq "$(_reloads)" "2" "faz 1 reload + geri alma reload'u"
assert_contains "$(cat "$OUTF")" "certbot BAŞARISIZ" "ileti"
assert_eq "$(find "$CONFD" -name '*.srvctl*' | wc -l | tr -d ' ')" "0" "artık yok"
# faz 2 nginx -t düşer → başlangıç hâli (faz 1 değil) geri gelir
reset_edge; printf '# onceki up icerigi\n' > "$UPC"; ssl_vhost
sha_prev=$(_domconf_sha256_file "$UPC")
_edge_rec_set example_com fm-up "$sha_prev" "$UPC" "up.example.com https://example.com" 2>/dev/null || { _edge_prepare_dir; _edge_rec_set example_com fm-up "$sha_prev" "$UPC" "up.example.com https://example.com"; }
mkdir -p "${SRVCTL_LE_LIVE_DIR}/up.example.com"; echo C > "${SRVCTL_LE_LIVE_DIR}/up.example.com/fullchain.pem"; echo K > "${SRVCTL_LE_LIVE_DIR}/up.example.com/privkey.pem"
NGINX_TEST_RC=1; ( _edge_fmup_cmd example.com on --adopt-cert ) >"$OUTF" 2>&1; rc=$?; NGINX_TEST_RC=0
assert_eq "$rc" "1" "faz 2 nginx -t düştü rc 1"
assert_eq "$(cat "$UPC")" "# onceki up icerigi" "ÖNCEKİ içerik geri yüklendi"
assert_contains "$(cat "$EREC")" "fm-up ${sha_prev}" "önceki kayıt korundu"
# reload düşer (faz 2): geri alınır
reset_edge; mkdir -p "${SRVCTL_LE_LIVE_DIR}/up.example.com"; echo C > "${SRVCTL_LE_LIVE_DIR}/up.example.com/fullchain.pem"; echo K > "${SRVCTL_LE_LIVE_DIR}/up.example.com/privkey.pem"
SYSTEMCTL_RC=1; ( _edge_fmup_cmd example.com on --adopt-cert ) >"$OUTF" 2>&1; rc=$?; SYSTEMCTL_RC=0
assert_eq "$rc" "1" "faz 2 reload düştü rc 1"
assert_eq "$(_exists "$UPC")" "yok" "geri alındı"; assert_eq "$(_exists "$EREC")" "yok" "kayıt geri alındı"
# SINYAL: faz 1'de certbot sırasında TERM → başlangıç hâli geri gelir
reset_edge
cat > "${FM_STUBS}/certbot-slow" <<'SLEOF'
#!/bin/bash
echo "slow $*" >> "${CB_LOG:?}"
# certbot, "out=$(certbot …)" alt kabuğunun çocuğudur; sinyal fm-up'ı koşturan kabuğa (alt kabuğun ebeveyni) gider.
gp=$(ps -o ppid= -p "$PPID" | tr -d ' ')
kill -TERM "$gp"
sleep 1
exit 1
SLEOF
chmod +x "${FM_STUBS}/certbot-slow"
cp "${FM_STUBS}/certbot" "${FM_STUBS}/certbot.real"
(
    export PATH="${FM_STUBS}/slowbin:${PATH}"; mkdir -p "${FM_STUBS}/slowbin"; cp "${FM_STUBS}/certbot-slow" "${FM_STUBS}/slowbin/certbot"
    _edge_fmup_cmd example.com on >"$OUTF" 2>&1
) ; rc=$?
assert_eq "$rc" "143" "TERM: rc 143"
assert_eq "$(_exists "$UPC")" "yok" "sinyal: yazılan faz 1 dosyası GERİ ALINDI"
assert_contains "$(cat "$OUTF")" "GERİ ALINIYOR" "sinyal iletisi"

echo "══ I: fm-up off / purge / remove ══"
reset_edge
( _edge_fmup_cmd example.com on ) >/dev/null 2>&1
: > "$CB_LOG"
( _edge_fmup_cmd example.com off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off rc 0"; assert_eq "$(_exists "$UPC")" "yok" "up dosyası silindi"; assert_eq "$(grep -c '^fm-up ' "$EREC")" "0" "fm-up kaydı silindi"; assert_contains "$(grep '^fm-up-cert ' "$EREC")" "up.example.com issued=1" "sertifika sahiplik kaydı (tombstone) KALIR (M8: --purge-cert sonradan bulur)"
assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "--purge-cert yok: sertifika SİLİNMEZ"
assert_contains "$(cat "$OUTF")" "Sertifika KALDI" "ileti"
( _edge_fmup_cmd example.com off ) >/dev/null 2>&1; assert_eq "$?" "0" "kapalıyken off idempotent"
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1; : > "$CB_LOG"
( _edge_fmup_cmd example.com off --purge-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off --purge-cert rc 0"
assert_contains "$(cat "$CB_LOG")" "delete --cert-name up.example.com" "certbot delete --cert-name <host>"
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1; : > "$CB_LOG"
r0=$(_reloads)
( _edge_fmup_cmd example.com off --dry --purge-cert ) >"$OUTF" 2>&1
assert_eq "$(_exists "$UPC")" "var" "off --dry: dosya duruyor"; assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "off --dry: certbot yok"; assert_eq "$(_reloads)" "$r0" "off --dry: reload yok"
# domain remove temizliği
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1; : > "$CB_LOG"
_edge_purge_domain example.com
assert_eq "$(_exists "$UPC")" "yok" "remove: up dosyası silindi"; assert_eq "$(_exists "$EREC")" "yok" "remove: kayıt silindi"
assert_contains "$(cat "$CB_LOG")" "delete --cert-name up.example.com" "remove: up sertifikası silindi"
assert_contains "$(grep -n '_edge_purge_domain' "${REPO_ROOT}/lib/domain.sh")" "_edge_purge_domain" "domain.sh purge kancası bağlı"
# fm-auth off ⇒ up bloğu 20/90 glob'u: dosyalar tek kaynak (yapısal; gerçek davranış test_edge_up_real.sh)
assert_contains "$(cat "$UPC" 2>/dev/null; _edge_fmup_render example.com up.example.com https://example.com 1 2)" "20-srvctl-fm-upload.con[f]" "20 glob"
assert_contains "$(_edge_fmup_cmd --capabilities)" "srvctl-fm-up-caps v1" "--capabilities"
echo "══ J: monitor — up 403/429 yoğunluğu ve CF listesi yaşı (K13) ══"
UL="${FM_STUBS}/fm-up.access.log"; : > "$UL"
for i in $(seq 1 120); do echo "203.0.113.5 [15/Nov/2026:05:00:00 +0300] \"PUT /_fm/up/1/$i\" 429 0 0.000" >> "$UL"; done
for i in $(seq 1 30); do echo "203.0.113.5 [15/Nov/2026:05:00:00 +0300] \"PUT /_fm/up/1/$i\" 200 0 0.100" >> "$UL"; done
for i in $(seq 1 10); do echo "203.0.113.6 [15/Nov/2026:05:00:00 +0300] \"PUT /_fm/up/1/$i\" 403 12 0.001" >> "$UL"; done
assert_eq "$(_monitor_up_abuse_count "$UL")" "130" "403+429 sayımı (200'ler hariç)"
assert_eq "$(_monitor_up_abuse_count "${FM_STUBS}/yok.log")" "0" "günlük yoksa 0"
echo "══ ACAO şablon düzeyinde yansıtmaz (gerçek nginx gerektirmez) ══"
acao_blk=$(printf '%s\n' "$T" | awk '/^map \$http_origin \$fmup_acao_/ { on = 1 } on { print } on && /^}/ { exit }')
assert_ne "$acao_blk" "" "ACAO map bloğu bulundu"
acao_body=$(printf '%s\n' "$acao_blk" | sed '1d;$d')
assert_eq "$(printf '%s\n' "$acao_body" | grep -c .)" "2" "ACAO map'inde yalnız 2 satır: default + tek tam köken"
assert_eq "$(printf '%s\n' "$acao_body" | grep -cE '^[[:space:]]*default[[:space:]]+"";[[:space:]]*$')" "1" "default BOŞ ('\"\"') — gelen Origin'e düşmez"
assert_eq "$(printf '%s\n' "$acao_body" | grep -c 'http_origin')" "0" "map gövdesinde \$http_origin DEĞER olarak yok (yansıtma yok)"
assert_eq "$(printf '%s\n' "$acao_body" | grep -cE '~|\*|null|\$')" "0" "map gövdesinde regex/joker/null/değişken yok"
assert_eq "$(printf '%s\n' "$acao_body" | grep -cE '^[[:space:]]*"\{\{FM_UP_ORIGIN\}\}"[[:space:]]+"\{\{FM_UP_ORIGIN\}\}";[[:space:]]*$')" "1" "tek girdi: sabit yapılandırma kökeni → aynı sabit"
assert_eq "$(printf '%s\n' "$T" | grep -c 'add_header Access-Control-Allow-Origin  *\$http_origin')" "0" "ACAO başlığı doğrudan \$http_origin yazmaz"
assert_eq "$(printf '%s\n' "$T" | grep -E 'add_header Access-Control-Allow-Origin' | grep -vc 'fmup_acao_{{SAFE_NAME}} always')" "0" "her ACAO başlığı yalnız map çıktısını kullanır"
test_summary
