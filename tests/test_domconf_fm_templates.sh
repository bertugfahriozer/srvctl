#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitlerinin okuduğu bayraklar (MOCK_*, NGINX_*, SYSTEMCTL_RC …) bu dosyada atanır
# FM şablonları (fm-auth / fm-upload / fm-download) — YORUM-DIŞI yapısal kilit.
#
# QL3-M5 sınıfı: eski testler direktifleri `assert_contains` ile ARIYORDU; '# direktif;'
# yorumuna da uyduğundan `# fastcgi_hide_header X-Fm-Auth;` mutantı yaşıyordu. Burada
# render edilen şablonlar _domconf_nginx_parse (ngx_conf_read_token birebir) ile ÇÖZÜMLENİR;
# yorumlar lexer'da hiç yoktur. Her direktif "üst blok yolu + ad + argüman" olarak aranır.
# Dedektörün kendisi de sınanır (yoruma çevrilmiş direktif BULUNMAMALI).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
T="$(mktemp -d)"; trap 'rm -rf "$T"; _fm_env_cleanup' EXIT   # rev-L9: fm_env temizliği zincirde

R90=$(_domconf_fm_render_auth example_com 8.3 "$SCRIPT" 1)
R21=$(_domconf_fm_render_download example_com)
R20=$(_domconf_fm_render_upload eu 1 example_com)
printf '%s\n' "$R90" > "$T/90.conf"; printf '%s\n' "$R21" > "$T/21.conf"; printf '%s\n' "$R20" > "$T/20.conf"

echo "── A: 20-srvctl-fm-upload.conf — konum öncelik kilidi (SEC-H1) ──"
fm_collect "$T/20.conf"; assert_eq "$?" "0" "20: lexer temiz çözümler"
UPL='location ^~ /_fm/up/'
assert_ok fm_has "" "$UPL"
assert_ok fm_has "" 'location ^~ /_fm/'
assert_ok fm_has "" 'location @fm_up'
assert_ok fm_has 'location ^~ /_fm/' 'return 403'
nreg=$(grep -cE '^[0-9]+\|\|location (~|~\*) ' <<< "$_FM_COLL")
assert_eq "$nreg" "0" "20: dosyada REGEX location YOK ('^~' önek eşleşmesi regex'leri devre dışı bırakır)"
nloc=$(grep -cE '^[0-9]+\|\|location ' <<< "$_FM_COLL")
assert_eq "$nloc" "6" "20: tam altı location (yükleme öneki, '= /_fm' tam eşleşme, '^~ /_fm/' 403 kökü, @fm_deny, '^~ /__fm_' ad alanı yakalayıcısı, @fm_up)"
assert_ok fm_has 'location @fm_deny' 'return 403'
# G12-c: /__fm_ ad alanı yakalayıcısı — 90 yokken auth alt isteği ve 21 yokken X-Accel iç isteği uygulamaya düşmez
assert_ok fm_has "" 'location ^~ /__fm_'
assert_ok fm_has 'location ^~ /__fm_' 'internal'
assert_ok fm_has 'location ^~ /__fm_' 'return 403'
assert_eq "$(grep -cE '^[0-9]+\|\|location \^~ /__fm_( |$)' <<< "$_FM_COLL")" "1" "20: /__fm_ yakalayıcısı tam 1 (önek, regex değil)"
assert_fail fm_has "" 'location = /__fm_auth'
assert_fail fm_has "" 'location = /__fm_dl'
assert_ok fm_has "$UPL" 'error_page 500 =403 @fm_deny'
assert_ok fm_has "" 'location = /_fm'
assert_ok fm_has 'location = /_fm' 'return 403'
assert_fail fm_has "" 'location ^~ /_fm'
assert_fail fm_has "" 'location /_fm'
assert_fail fm_has "" 'location ^~ /_fm {'
assert_ok fm_has "$UPL" 'modsecurity off'
assert_ok fm_has 'location @fm_up' 'modsecurity off'
echo "── A2: biçim kapısı ve auth sırası ──"
GATE='if ($request_uri !~ ^/_fm/up/[0-9]{1,20}/[0-9]{1,20}$ )'   # lexer ')' sözcüğünü AYRI jeton yapar
assert_ok fm_has "$UPL" "$GATE"
assert_ok fm_has "$UPL > $GATE" 'return 403'
assert_ok fm_has "$UPL" 'limit_except PUT'
assert_ok fm_has "$UPL > limit_except PUT" 'deny all'
CL='if ($http_content_length =  )'   # boş dize jetonu + ')'
assert_ok fm_has "$UPL" "$CL"
assert_ok fm_has "$UPL > $CL" "return 411 srvctl-fm-open $(_domconf_fm_body_sig example_com)"
assert_ok fm_has "$UPL" 'client_max_body_size 33m'
assert_ok fm_has "$UPL" 'auth_request /__fm_auth'
assert_ok fm_has "$UPL" 'auth_request_set $fm_auth $upstream_http_x_fm_auth'
assert_ok fm_has "$UPL" 'try_files /__fm_never_exists @fm_up'
lg=$(fm_line "$UPL" "$GATE"); la=$(fm_line "$UPL" 'auth_request /__fm_auth'); lt=$(fm_line "$UPL" 'try_files /__fm_never_exists @fm_up')
assert_eq "$([[ -n "$lg" && -n "$la" && "$lg" -lt "$la" && "$la" -lt "$lt" ]] && echo sirali || echo bozuk)" "sirali" "20: biçim kapısı < auth_request < try_files"
# 'set'li (içinden dönmeyen) if, asıl location'da OLMAMALI: if-bloğu eşleşince try_files miras kalmaz (PUT→405)
nset=$(grep -cE "^[0-9]+\|location \^~ /_fm/up/ > if .*\|set " <<< "$_FM_COLL")
assert_eq "$nset" "0" "20: prefix location'da 'set' yapan if YOK (try_files kaybı: nginx 1.28 ölçümü)"
echo "── A3: KAPI 2 (yorum-dışı) ──"
FA='location @fm_up'
G2='if ($fm_auth !~ ^Bearer [A-Za-z0-9._~+/=-]+$ )'
assert_ok fm_has "$FA" "$G2"
assert_ok fm_has "$FA > $G2" 'return 403'
l2=$(fm_line "$FA" "$G2"); lp=$(fm_line "$FA" 'proxy_pass https://eapi.pcloud.com/upload_write?uploadid=$fm_up_uid&uploadoffset=$fm_up_off')
assert_eq "$([[ -n "$l2" && -n "$lp" && "$l2" -lt "$lp" ]] && echo sirali || echo bozuk)" "sirali" "20: KAPI 2, proxy_pass'ten ÖNCE"
echo "── A4: proxy güvenlik direktifleri ──"
for d in 'proxy_http_version 1.1' 'proxy_request_buffering off' 'proxy_buffering off' 'proxy_max_temp_file_size 0' \
         'proxy_ssl_server_name on' 'proxy_ssl_name eapi.pcloud.com' 'proxy_ssl_verify on' 'proxy_ssl_verify_depth 3' \
         'proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt' 'proxy_ssl_protocols TLSv1.2 TLSv1.3' \
         'proxy_pass_request_headers off' 'proxy_set_header Host eapi.pcloud.com' 'proxy_set_header Authorization $fm_auth' \
         'proxy_set_header Content-Type $http_content_type' 'proxy_set_header Connection ' \
         'proxy_ignore_headers X-Accel-Redirect X-Accel-Expires X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset' \
         'proxy_hide_header X-Accel-Redirect' 'proxy_hide_header X-Accel-Limit-Rate' 'proxy_hide_header X-Accel-Buffering' \
         'proxy_hide_header Set-Cookie' 'proxy_hide_header Access-Control-Allow-Origin' 'client_max_body_size 33m'; do
    assert_ok fm_has "$FA" "$d"
done
assert_eq "$(grep -cE '^[0-9]+\|location @fm_up\|add_header ' <<< "$_FM_COLL")" "0" "20: add_header YOK (üst blok güvenlik başlıkları düşmesin)"
assert_eq "$(grep -cE '\|include( |$)' <<< "$_FM_COLL")" "0" "20: include YOK (custom.d'de include sıfır)"
assert_not_contains "$R20" "fm_gate" "20: eski \$fm_gate düzeneği kalktı"

echo "── B: 21-srvctl-fm-download.conf ──"
fm_collect "$T/21.conf"; assert_eq "$?" "0" "21: lexer temiz çözümler"
DL='location = /__fm_dl'
assert_ok fm_has "" "$DL"
assert_ok fm_has "$DL" 'internal'
assert_ok fm_has "$DL" 'limit_except GET HEAD'
assert_ok fm_has "$DL > limit_except GET HEAD" 'deny all'
assert_ok fm_has "$DL" 'error_log /var/log/nginx/example_com-fm-dl.error.log crit'
assert_ok fm_has "$DL" 'set $fm_u '
assert_ok fm_has "$DL" 'set $fm_h '
RX='^https://((?!(?:[a-z0-9-]+\.)*localhost\.)(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+pcloud\.com)/(?!.*\.\.)(?:[A-Za-z0-9._~:/-]|%(?!0[0-9A-Fa-f]|1[0-9A-Fa-f]|2[5EeFf]|5[Cc]|7[Ff])[0-9A-Fa-f]{2})+$'
assert_ok fm_has "$DL" "if (\$arg_u ~ ${RX} )"
assert_ok fm_has "$DL > if (\$arg_u ~ ${RX} )" 'set $fm_u $arg_u'
assert_ok fm_has "$DL > if (\$arg_u ~ ${RX} )" 'set $fm_h $1'
assert_ok fm_has "$DL" 'if ($fm_u =  )'
assert_ok fm_has "$DL > if (\$fm_u =  )" 'return 403'
assert_ok fm_has "$DL" 'proxy_pass $fm_u'
for d in 'proxy_pass_request_headers off' 'proxy_set_header Host $fm_h' 'proxy_set_header Range $http_range' \
         'proxy_set_header If-Range $http_if_range' 'proxy_set_header X-Fm-Ticket ' 'proxy_ssl_verify on' 'proxy_ssl_name $fm_h' \
         'proxy_buffering off' 'proxy_max_temp_file_size 0' 'proxy_intercept_errors off' \
         'proxy_ignore_headers X-Accel-Redirect X-Accel-Expires X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset' \
         'proxy_hide_header X-Accel-Redirect' 'proxy_hide_header X-Accel-Expires' 'proxy_hide_header X-Accel-Limit-Rate' \
         'proxy_hide_header X-Accel-Buffering' 'proxy_hide_header X-Accel-Charset' 'proxy_hide_header Content-Disposition' \
         'proxy_hide_header Set-Cookie' 'proxy_ssl_protocols TLSv1.2 TLSv1.3'; do
    assert_ok fm_has "$DL" "$d"
done
assert_eq "$(grep -cE '\|(add_header|include)( |$)' <<< "$_FM_COLL")" "0" "21: add_header/include YOK"
assert_eq "$(grep -c 'pcloud' <<< "$(grep -E '^[0-9]+\|[^|]*\|proxy_pass ' <<< "$_FM_COLL")")" "0" "21: proxy_pass hedefi sabit alan adı DEĞİL (yalnız \$fm_u)"

echo "── C: 90-srvctl-fm-auth.conf ──"
fm_collect "$T/90.conf"; assert_eq "$?" "0" "90: lexer temiz çözümler"
AU='location = /__fm_auth'
assert_ok fm_has "" "$AU"
for d in 'internal' 'modsecurity off' 'fastcgi_pass unix:/run/php/php8.3-fpm-example_com.sock' 'fastcgi_pass_request_body off' \
         'client_max_body_size 33m' "fastcgi_param SCRIPT_FILENAME ${SCRIPT}" 'fastcgi_param SCRIPT_NAME /__fm_auth' \
         'fastcgi_param FM_AUTH_SUBREQ 1' 'fastcgi_param CONTENT_LENGTH ' 'fastcgi_param DOCUMENT_ROOT /public_html' \
         'fastcgi_hide_header X-Fm-Auth' 'fastcgi_hide_header X-Powered-By' 'fastcgi_param QUERY_STRING ' \
         'fastcgi_param FM_CLIENT_CONTENT_LENGTH $http_content_length'; do
    assert_ok fm_has "$AU" "$d"
done
assert_eq "$(grep -cE '\|include( |$)' <<< "$_FM_COLL")" "0" "90: include YOK"
assert_eq "$(grep -cE '\|include( |$)' <<< "$_FM_COLL")" "0" "90: fastcgi_params include edilmez (çift parametre olmasın)"

echo "── D: dedektörün KENDİSİ — yoruma çevrilen direktif BULUNMAMALI (QL3-M5 mutantı) ──"
sed 's/^    fastcgi_hide_header X-Fm-Auth;/    # fastcgi_hide_header X-Fm-Auth;/' "$T/90.conf" > "$T/90m.conf"
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
assert_ne "$(cmp -s "$T/90.conf" "$T/90m.conf" && echo ayni || echo farkli)" "ayni" "sondaj: mutant dosya gerçekten değişti"
fm_collect "$T/90m.conf"
assert_fail fm_has "$AU" 'fastcgi_hide_header X-Fm-Auth'
sed 's/^    if (\$fm_auth !~ "\^Bearer \[A-Za-z0-9._~+\/=-\]+\$") { return 403; }/    # KAPI2 yok/' "$T/20.conf" > "$T/20m.conf"
assert_ne "$(cmp -s "$T/20.conf" "$T/20m.conf" && echo ayni || echo farkli)" "ayni" "sondaj: KAPI 2 mutantı gerçekten değişti"
fm_collect "$T/20m.conf"
assert_fail fm_has "$FA" "$G2"
sed 's/^location \^~ \/_fm\/up\//location ~ \/_fm\/up\//' "$T/20.conf" > "$T/20r.conf"
fm_collect "$T/20r.conf"
assert_fail fm_has "" "$UPL"
assert_eq "$(grep -cE '^[0-9]+\|\|location (~|~\*) ' <<< "$_FM_COLL")" "1" "dedektör: '^~'→'~' mutantında REGEX location sayacı 1 (yapısal kilit kırmızıya döner)"

echo "── E: render GÜVENLİĞİ — token doğrulama, beslenmeyen {{}} ──"
assert_fail _domconf_fm_render_auth 'a;b' 8.3 "$SCRIPT" 1
assert_fail _domconf_fm_render_auth 'a b' 8.3 "$SCRIPT" 1
assert_fail _domconf_fm_render_auth '' 8.3 "$SCRIPT" 1
assert_fail _domconf_fm_render_auth example_com 8 "$SCRIPT" 1
assert_fail _domconf_fm_render_auth example_com '8.3;x' "$SCRIPT" 1
assert_fail _domconf_fm_render_auth example_com 8.3 '/current/public/x.php' 1
assert_fail _domconf_fm_render_auth example_com 8.3 "$SCRIPT" 2
assert_fail _domconf_fm_render_download 'a/b'
assert_fail _domconf_fm_render_download ''
assert_fail _domconf_fm_render_upload zz 1 example_com
assert_fail _domconf_fm_render_upload '' 1 example_com
assert_fail _domconf_fm_render_upload eu 2 example_com
# beslenmeyen token: şablona bir '{{BESLENMEYEN}}' eklenmiş kopya → rc 2 (render reddedilir)
mkdir -p "$T/tpl/nginx"; cp "${REPO_ROOT}"/templates/nginx/fm-*.tpl "$T/tpl/nginx/"
for f in fm-auth fm-upload fm-download; do
    cp "${REPO_ROOT}/templates/nginx/${f}.conf.tpl" "$T/tpl/nginx/${f}.conf.tpl"
    printf '# {{BESLENMEYEN}}\n' >> "$T/tpl/nginx/${f}.conf.tpl"
done
( SRVCTL_TEMPLATES="$T/tpl"; _domconf_fm_render_auth example_com 8.3 "$SCRIPT" 1 >/dev/null ); assert_eq "$?" "2" "beslenmeyen token: auth render rc=2"
( SRVCTL_TEMPLATES="$T/tpl"; _domconf_fm_render_upload eu 1 example_com >/dev/null ); assert_eq "$?" "2" "beslenmeyen token: upload render rc=2"
( SRVCTL_TEMPLATES="$T/tpl"; _domconf_fm_render_download example_com >/dev/null ); assert_eq "$?" "2" "beslenmeyen token: download render rc=2"
assert_not_contains "$R20$R21$R90" "{{" "üç render'da '{{' kalmadı"

echo "── F: bölge tablosu (host başka yerden okunmaz) ──"
assert_eq "$(_domconf_fm_region_host eu)" "eapi.pcloud.com" "eu → eapi.pcloud.com"
assert_eq "$(_domconf_fm_region_host us)" "api.pcloud.com" "us → api.pcloud.com"
for bad in "" EU Us eapi.pcloud.com "eu " "eu;x" "../eu" "evil.com" "api.pcloud.com.evil.com" "*" "1"; do
    assert_fail _domconf_fm_region_host "$bad"
done
RUS=$(_domconf_fm_render_upload us 1 example_com)
assert_contains "$RUS" "proxy_pass https://api.pcloud.com/upload_write?" "us: proxy_pass api.pcloud.com"
assert_contains "$RUS" "proxy_ssl_name api.pcloud.com;" "us: proxy_ssl_name"
assert_contains "$RUS" "proxy_set_header Host api.pcloud.com;" "us: Host başlığı"
printf '%s\n' "$RUS" > "$T/20us.conf"; fm_collect "$T/20us.conf"
assert_eq "$(grep -c 'eapi\.pcloud\.com' <<< "$_FM_COLL")" "0" "us: yorum-dışı hiçbir yerde eapi geçmez"
fm_collect "$T/20.conf"
assert_eq "$(grep -cE '[^e]api\.pcloud\.com' <<< "$_FM_COLL")" "0" "eu: yorum-dışı hiçbir yerde us ana makinesi geçmez"
R20N=$(_domconf_fm_render_upload eu 0 example_com)
assert_contains "$R20N" "# ModSecurity yüklü değil" "modsec=0: yorum satırı"
fm_collect <(printf '%s\n' "$R20N") 2>/dev/null
printf '%s\n' "$R20N" > "$T/20n.conf"; fm_collect "$T/20n.conf"
assert_fail fm_has "$UPL" 'modsecurity off'
assert_fail fm_has 'location @fm_up' 'modsecurity off'

echo "── G: şablon dosya başlıkları (TOKENS) ──"
assert_contains "$(head -1 "${REPO_ROOT}/templates/nginx/fm-upload.conf.tpl")" "TOKENS: PCLOUD_HOST MODSEC_LINE" "fm-upload TOKENS"
assert_contains "$(head -1 "${REPO_ROOT}/templates/nginx/fm-download.conf.tpl")" "TOKENS: SAFE_NAME" "fm-download TOKENS"
assert_contains "$(head -1 "${REPO_ROOT}/templates/nginx/fm-auth.conf.tpl")" "TOKENS: SAFE_NAME PHP_VERSION AUTH_SCRIPT MODSEC_LINE" "fm-auth TOKENS"
assert_eq "$([[ -d "${REPO_ROOT}/templates/nginx/fm" ]] && echo var || echo yok)" "yok" "templates/nginx/fm/ alt dizini YOK (install.sh'a dokunulmaz)"

test_summary
