#!/bin/bash
# lib/nginx_allow.sh — custom.d kullanıcı dosyasında DAR genişleme: types bloğu, default_type, autoindex off.
#
# İzin verilen YALNIZ şunlardır (bağlam: server/location; her şey tablo dışında varsayılan-ret):
#   types { <tür>/<alt-tür> <uzantı> [<uzantı> …]; … }   tür: RFC 6838 karakterleri AMA '$' yok; uzantı: [A-Za-z0-9]+
#   default_type <tür>/<alt-tür>;
#   autoindex off;                                       (autoindex on ve her varyantı kesin-ret KALIR)
# Boş `types {}` KABUL: nginx -t geçerli sayar, hiçbir eşleme eklemez (her uzantı default_type'a düşer) —
# yani en dar izin listesi; saldırı yüzeyi yok.
# Kilitlenenler: A pozitifler · B autoindex negatifleri · C default_type negatifleri · D types negatifleri ·
#   E kesin-ret ve izinli direktiflerin types içine gizlenmesi · F bağlam/yapı · G canlı media.conf kopyası (fikstür).
# Vaka biçimi:  BEKLENEN_RC @@ GEREKÇE_SINIFI|- @@ NGINX_METNİ(¶=satır sonu) @@ AÇIKLAMA
# MUTASYON KANCASI: SRVCTL_NGXALLOW_LIB ile mutant kopya yüklenebilir (yalnız test).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"; export SRVCTL_ROOT
log_action() { :; }
source "${REPO_ROOT}/lib/domconf.sh"
# shellcheck source=/dev/null
source "${SRVCTL_NGXALLOW_LIB:-${REPO_ROOT}/lib/nginx_allow.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
F="${TMP}/10-site.conf"

_scan() { # $1=metin  [$2=mantıksal ad]  → _OUT, _RC
    local p="${1//¶/$'\n'}"
    printf '%s' "$p" > "$F"
    _RC=0
    _OUT=$(_ngxallow_scan "$F" example.com "${2:-10-site.conf}" 2>&1) || _RC=$?
}

run_cases() { # stdin: vaka satırları
    local line rc cls pay desc rest
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        rc="${line%% @@ *}"; rest="${line#* @@ }"
        cls="${rest%% @@ *}"; rest="${rest#* @@ }"
        pay="${rest%% @@ *}"; desc="${rest#* @@ }"
        _scan "$pay"
        if [[ "$_RC" != "$rc" ]]; then
            assert_eq "$_RC" "$rc" "${desc} [rc] :: $(printf '%s' "$_OUT" | head -2 | tr '\n' ' ')"
        elif [[ "$cls" != "-" && "$_OUT" != *":${cls}:"* ]]; then
            assert_contains "$_OUT" ":${cls}:" "${desc} [gerekçe sınıfı]"
        else
            assert_eq "$_RC" "$rc" "${desc}"
        fi
    done
}

echo "── A: POZİTİF — types / default_type / autoindex off ──"
run_cases <<'CASES'
0 @@ - @@ types {¶ image/jpeg jpg jpeg;¶ image/png png;¶ text/plain txt;¶} @@ types bloğu (server düzeyi, çok satır, çok uzantı)
0 @@ - @@ types { image/svg+xml svg svgz; } @@ types tek satırda
0 @@ - @@ types {} @@ boş types {} (nginx -t geçerli; eşleme eklemez)
0 @@ - @@ types {¶} @@ boş types, satır sonlu
0 @@ - @@ location /m/ {¶ types {¶ image/png png;¶ }¶ default_type application/octet-stream;¶ autoindex off;¶} @@ location içinde types + default_type + autoindex off
0 @@ - @@ location /m/ {¶ location ~* \.svgz?$ {¶ types { image/svg+xml svg svgz; }¶ try_files $uri =404;¶ }¶} @@ iç location içinde types
0 @@ - @@ types { Image/PNG PNG; } @@ büyük harfli tür ve uzantı (RFC 6838 harf kümesi)
0 @@ - @@ types { a!#&^_.+-b/c!#&^_.+-d x1; } @@ tür belirteci: RFC 6838 özel karakterleri ('$' hariç)
0 @@ - @@ types { application/vnd.ms-excel.sheet.macroEnabled.12 xlsm; } @@ gerçek uzun tür
0 @@ - @@ types { a/b c1 c2 c3 c4 c5 c6 c7 c8 c9 d1 d2 d3 d4 d5 d6 d7; } @@ 16 uzantı (argüman tavanı 16)
0 @@ - @@ types { a/b c; }¶types { d/e f; } @@ birden çok types bloğu
0 @@ - @@ default_type application/octet-stream; @@ default_type (server düzeyi)
0 @@ - @@ location /x {¶ default_type text/plain;¶} @@ default_type (location)
0 @@ - @@ default_type image/svg+xml; @@ default_type + işareti
0 @@ - @@ autoindex off; @@ autoindex off (server düzeyi)
0 @@ - @@ location /x {¶ autoindex off;¶} @@ autoindex off (location)
CASES

echo "── B: autoindex — YALNIZ off; on ve bütün varyantları kesin-ret kalır ──"
run_cases <<'CASES'
1 @@ kesin-ret @@ autoindex on; @@ autoindex on
1 @@ kesin-ret @@ location /x {¶ autoindex on;¶} @@ location içinde autoindex on
1 @@ kesin-ret @@ autoindex ON; @@ autoindex ON
1 @@ kesin-ret @@ autoindex On; @@ autoindex On
1 @@ kesin-ret @@ autoindex oN; @@ autoindex oN
1 @@ kesin-ret @@ autoindex "on"; @@ autoindex "on" (çift tırnak)
1 @@ kesin-ret @@ autoindex 'on'; @@ autoindex 'on' (tek tırnak)
1 @@ kesin-ret @@ autoindex  on  ; @@ autoindex on (fazladan boşluk)
1 @@ kesin-ret @@ autoindex¶ on; @@ autoindex on (satır bölünmüş)
1 @@ kesin-ret @@ autoindex; @@ autoindex argümansız
1 @@ kesin-ret @@ autoindex off on; @@ autoindex off on (fazla argüman)
1 @@ kesin-ret @@ autoindex off off; @@ autoindex off off
1 @@ kesin-ret @@ autoindex OFF; @@ autoindex OFF (yalnız tam 'off')
1 @@ kesin-ret @@ autoindex Off; @@ autoindex Off
1 @@ kesin-ret @@ autoindex $x; @@ autoindex değişkenli
1 @@ kesin-ret @@ autoindex "";  @@ autoindex boş değer
1 @@ kesin-ret @@ autoindex of\f; @@ autoindex 'of\f' (ters bölü kaçışı 'off' DEĞİL)
1 @@ kesin-ret @@ autoindex 1; @@ autoindex 1
1 @@ kesin-ret @@ AutoIndex off; @@ AutoIndex off (büyük harfli direktif adı)
1 @@ kesin-ret @@ AUTOINDEX off; @@ AUTOINDEX off
1 @@ kesin-ret @@ autoindex_exact_size off; @@ autoindex_exact_size
1 @@ kesin-ret @@ autoindex_format html; @@ autoindex_format
1 @@ kesin-ret @@ autoindex_localtime off; @@ autoindex_localtime
1 @@ baglam @@ location /x {¶ if ($x) {¶ autoindex off;¶ }¶} @@ if içinde autoindex off (bağlam)
1 @@ baglam @@ location /x {¶ limit_except GET {¶ autoindex off;¶ }¶} @@ limit_except içinde autoindex
1 @@ baglam @@ autoindex off {¶} @@ autoindex blok olarak
CASES

echo "── C: default_type — yalnız tek MIME belirteci ──"
run_cases <<'CASES'
1 @@ arguman @@ default_type $x; @@ değişkenli default_type
1 @@ arguman @@ default_type $uri; @@ default_type $uri
1 @@ arguman @@ default_type text/$x; @@ default_type tür/$x
1 @@ arguman @@ default_type $a/$b; @@ default_type $a/$b
1 @@ arguman @@ default_type text/html$; @@ default_type sonda $
1 @@ arguman @@ default_type text; @@ default_type alt türsüz
1 @@ arguman @@ default_type /plain; @@ default_type türsüz
1 @@ arguman @@ default_type text/; @@ default_type boş alt tür
1 @@ arguman @@ default_type a/b/c; @@ default_type üç parça
1 @@ arguman @@ default_type text/plain text/html; @@ default_type iki argüman
1 @@ arguman @@ default_type; @@ default_type argümansız
1 @@ arguman @@ default_type ""; @@ default_type boş değer
1 @@ arguman @@ default_type "text/pl ain"; @@ default_type boşluklu belirteç
1 @@ - @@ default_type text/plain;x; @@ default_type ';' sonrası (lexer: ayrı ifade)
1 @@ arguman @@ default_type text/pl"ain"; @@ default_type gömülü tırnak
1 @@ arguman @@ default_type text/pl:ain; @@ default_type ':' RFC 6838 dışı
1 @@ arguman @@ default_type text/pl=ain; @@ default_type '=' RFC 6838 dışı
1 @@ arguman @@ default_type text/pl,ain; @@ default_type ',' RFC 6838 dışı
1 @@ arguman @@ default_type text/pl*ain; @@ default_type '*' RFC 6838 dışı
1 @@ arguman @@ default_type text/pl%ain; @@ default_type '%' RFC 6838 dışı
1 @@ kesin-ret @@ Default_Type text/plain; @@ Default_Type (büyük harfli ad)
1 @@ kesin-ret @@ DEFAULT_TYPE text/plain; @@ DEFAULT_TYPE
1 @@ baglam @@ location /x {¶ if ($x) {¶ default_type text/plain;¶ }¶} @@ if içinde default_type (bağlam)
1 @@ baglam @@ default_type text/plain {¶} @@ default_type blok olarak
1 @@ yasak-dizgi @@ default_type application/x-fm-auth; @@ default_type FM ad uzayı dizgisi (x-fm)
1 @@ yasak-dizgi @@ default_type application/x-accel-redirect; @@ default_type x-accel
CASES

echo "── D: types içeriği — yalnız 'tür/alt-tür uzantı… ;' satırı ──"
run_cases <<'CASES'
1 @@ - @@ types { text/html $x; } @@ uzantı değişken ($x)
1 @@ - @@ types { text/html jpg $x; } @@ ikinci uzantı değişken
1 @@ - @@ types { $x/y z; } @@ tür değişkenli ($x/y)
1 @@ - @@ types { text/$x z; } @@ alt tür değişkenli
1 @@ - @@ types { text/h$tml z; } @@ tür ortasında $
1 @@ - @@ types { include /etc/passwd; } @@ include
1 @@ - @@ types { include mime.types; } @@ include mime.types
1 @@ - @@ types { a/b c; proxy_pass http://x; } @@ geçerli satırdan sonra proxy_pass
1 @@ - @@ types { proxy_pass http://x; a/b c; } @@ başta proxy_pass
1 @@ - @@ types { a/b c; location /x { return 200; } } @@ iç blok (location)
1 @@ - @@ types { a/b c { } } @@ iç blok, MIME görünümlü başlık
1 @@ - @@ types { a/b c; types { d/e f; } } @@ iç içe types
1 @@ - @@ types { a/b c; if ($x) { return 200; } } @@ iç if
1 @@ - @@ types { a/"b" c; } @@ tür belirtecinde gömülü tırnak
1 @@ - @@ types { a/b c"d"; } @@ lexer yapı hatası ya da gömülü tırnak
2 @@ - @@ types { a/b "c"d; } @@ kapanan tırnaktan sonra karakter (lexer rc 2)
1 @@ - @@ types { a/b c\"d; } @@ kaçışlı tırnak uzantıda
1 @@ - @@ types { a/b\'c d; } @@ kaçışlı tek tırnak türde
1 @@ - @@ types { a/b ""; } @@ boş uzantı
1 @@ - @@ types { a/b ''; } @@ boş uzantı (tek tırnak)
1 @@ - @@ types { "" c; } @@ boş tür
1 @@ - @@ types { a/b c-d; } @@ uzantıda '-'
1 @@ - @@ types { a/b c.d; } @@ uzantıda '.'
1 @@ - @@ types { a/b c_d; } @@ uzantıda '_'
1 @@ - @@ types { a/b c*; } @@ uzantıda '*'
1 @@ - @@ types { a/b *; } @@ yalnız '*' uzantı
1 @@ - @@ types { a/b c/d; } @@ uzantıda '/'
1 @@ - @@ types { a/b c$; } @@ uzantıda sonda $
1 @@ - @@ types { a/b; } @@ uzantısız satır
1 @@ - @@ types { a/b ; } @@ uzantısız satır (boşluklu)
1 @@ - @@ types { /b c; } @@ tür boş
1 @@ - @@ types { a/ c; } @@ alt tür boş
1 @@ - @@ types { a/b/c d; } @@ üç parçalı tür
1 @@ - @@ types { a b c; } @@ eğik çizgisiz tür
1 @@ - @@ types { abc d; } @@ eğik çizgisiz tek sözcük
1 @@ - @@ types { a/b$c d; } @@ türde $
1 @@ - @@ types { a/b%c d; } @@ türde %
1 @@ - @@ types { a/b:c d; } @@ türde :
1 @@ - @@ types { a/b,c d; } @@ türde ,
1 @@ - @@ types { a/b=c d; } @@ türde =
1 @@ - @@ types { a/b@c d; } @@ türde @
1 @@ - @@ types { a/b~c d; } @@ türde ~
1 @@ - @@ types { a/b(c) d; } @@ türde parantez
1 @@ - @@ types { a/b[c] d; } @@ türde köşeli parantez
1 @@ - @@ types { a/b*c d; } @@ türde *
1 @@ - @@ types { a/b?c d; } @@ türde ?
1 @@ - @@ types { a/b\c d; } @@ türde ters bölü
1 @@ - @@ types { a/b c; } types { d/e f; foo bar; } @@ ikinci blokta tanınmayan satır
1 @@ yasak-dizgi @@ types { image/x-fm-auth fm1; } @@ tür: FM ad uzayı (x-fm)
1 @@ yasak-dizgi @@ types { application/x-accel-redirect x; } @@ tür: x-accel
1 @@ yasak-dizgi @@ types { a/b upstream_http; } @@ uzantı: upstream_http
1 @@ yasak-dizgi @@ types { a/b cookie_x; } @@ uzantı: cookie_
1 @@ arguman @@ types { a/b c1 c2 c3 c4 c5 c6 c7 c8 c9 d1 d2 d3 d4 d5 d6 d7 d8; } @@ 17 uzantı (argüman tavanı)
CASES

# tür / alt tür uzunluk tavanı 127 (sınır: 127 kabul, 128 ret)
L127=$(printf 'a%.0s' $(seq 1 127)); L128="${L127}a"
_scan "types { ${L127}/${L127} x; }"; assert_eq "$_RC" "0" "tür 127 + alt tür 127 karakter: kabul (tavan)"
_scan "types { ${L128}/b x; }"; assert_eq "$_RC" "1" "tür 128 karakter: ret"
_scan "types { a/${L128} x; }"; assert_eq "$_RC" "1" "alt tür 128 karakter: ret"
_scan "default_type ${L127}/${L127};"; assert_eq "$_RC" "0" "default_type 127+127: kabul"
_scan "default_type ${L128}/b;"; assert_eq "$_RC" "1" "default_type tür 128: ret"

echo "── E: kesin-ret ve izinli direktifler types içine gizlenince de RET ──"
# direktif|argüman — kesin-ret listesindeki her yönerge (glob'lardan örnekler) + izinli direktifler + büyük harfli varyantlar
HID=(
'proxy_pass|http://127.0.0.1:3000' 'proxy_set_header|Host x' 'proxy_http_version|1.1' 'proxy_ssl_verify|off' 'fastcgi_pass|unix:/run/x.sock' 'fastcgi_param|A b'
'uwsgi_pass|x' 'scgi_pass|x' 'grpc_pass|grpc://x' 'memcached_pass|x' 'auth_request|/a' 'auth_request_set|$a b' 'auth_basic|x' 'auth_basic_user_file|/x'
'include|/etc/passwd' 'root|/' 'alias|/' 'server_name|x' 'listen|80' 'disable_symlinks|off' 'modsecurity|on' 'modsecurity_rules_file|/x' 'ssl_certificate|/x'
'ssl_verify_client|off' 'upstream|x' 'map|$a $b' 'geo|$a' 'split_clients|$a $b' 'stream|x' 'mail|x' 'events|x' 'http|x' 'server|x' 'types|a/b c' 'types_hash_max_size|1'
'error_log|/x' 'error_page|404 /x' 'internal|' 'resolver|1.1.1.1' 'mirror|/m' 'ssi|on' 'ssi_types|x' 'add_before_body|/x' 'add_after_body|/x' 'dav_methods|PUT'
'client_body_temp_path|/x' 'proxy_cache_path|/x' 'fastcgi_store|on' 'sub_filter|a b' 'more_set_headers|"A: b"' 'add_trailer|A b' 'load_module|x' 'lua_code_cache|on'
'content_by_lua_block|x' 'js_content|x' 'perl_modules|/x' 'echo|hi' 'xslt_stylesheet|/x' 'secure_link|x' 'image_filter|test' 'userid|on' 'satisfy|any' 'charset|utf-8'
'default_type|text/html' 'gzip|on' 'etag|off' 'autoindex|on' 'autoindex|off' 'server_tokens|off' 'limit_rate|1k' 'client_body_timeout|5s' 'client_header_buffer_size|1k'
'keepalive_timeout|5s' 'send_timeout|5s' 'large_client_header_buffers|4 8k' 'set_real_ip_from|0.0.0.0/0' 'real_ip_header|X-F' 'if_modified_since|off'
'open_file_cache|off' 'sendfile|on' 'tcp_nodelay|on' 'worker_processes|1' 'user|x' 'pid|/x' 'daemon|off' 'env|X' 'rewrite_log|on' 'log_subrequest|on' 'log_format|x y'
'open_log_file_cache|off' 'ancient_browser|x' 'referer_hash_bucket_size|64' 'valid_referers|none' 'random_index|on' 'empty_gif|' 'flv|' 'mp4|' 'slice|1m'
'stub_status|' 'status|' 'hls|' 'fancyindex|on' 'geoip_country|/x' 'vhost_traffic_status|on' 'limit_req_zone|$a zone=z:1m rate=1r/s' 'limit_conn_zone|$a zone=z:1m'
'limit_req_status|429' 'limit_conn_status|429' 'limit_req_log_level|warn' 'limit_conn_log_level|warn' 'allow_x|1' 'clean_x|1'
'PROXY_PASS|http://x' 'Include|/etc/passwd' 'ROOT|/' 'Alias|/' 'Autoindex|on'
'set|$u_a b' 'return|403' 'add_header|X y' 'allow|all' 'deny|all' 'try_files|$uri =404' 'limit_req|zone=api' 'limit_conn|conn_per_ip 5' 'limit_except|GET' 'expires|1d'
'log_not_found|off' 'access_log|off' 'index|index.html' 'rewrite|^/a /b last' 'client_max_body_size|1m' 'location|/x' 'if|($x)'
)
nh=0
for h in "${HID[@]}"; do
    d="${h%%|*}"; a="${h#*|}"
    # (1) yalnız başına geçerli satır + gizlenmiş direktif
    _scan "types {¶ image/png png;¶ ${d} ${a};¶}¶"
    assert_eq "$_RC" "1" "gizleme: types içinde '${d} ${a}' reddedilir (rc 1)"
    # (2) ilk satır olarak; bulgu direktif adını taşır
    _scan "types {¶ ${d} ${a};¶}¶"
    assert_eq "$_RC" "1" "gizleme: types içinde ilk satır '${d}' reddedilir"
    assert_contains "$_OUT" ":${d}:" "gizleme: '${d}' bulgusu direktif adını taşır"
    nh=$((nh + 1))
done
echo "  (gizlenen direktif sayısı: ${nh})"
# kesin-ret olanlar types DIŞINDA da (aynen) kesin-ret kalır
for h in 'proxy_pass|http://x' 'include|/etc/passwd' 'root|/' 'server_name|x' 'ssl_certificate|/x' 'gzip|on' 'charset|utf-8' 'error_page|404 /x' 'types_hash_max_size|1' 'autoindex_format|html' 'client_body_temp_path|/x'; do
    _scan "${h%%|*} ${h#*|};¶"
    assert_eq "$_RC" "1" "(kontrol) ${h%%|*} types dışında da reddedilir"
    assert_contains "$_OUT" ":kesin-ret:" "(kontrol) ${h%%|*}: sınıf kesin-ret"
done
# blok başlıkları olarak gizleme (iç blok)
for h in location 'if ($x)' server upstream map geo limit_except events http stream 'types' 'a/b c'; do
    _scan "types {¶ ${h} {¶ }¶}¶"
    assert_eq "$_RC" "1" "gizleme: types içinde iç blok '${h} {' reddedilir"
done

echo "── F: bağlam ve yapı ──"
run_cases <<'CASES'
1 @@ baglam @@ location /x {¶ if ($x) {¶ types { a/b c; }¶ }¶} @@ if içinde types
1 @@ baglam @@ location /x {¶ limit_except GET {¶ types { a/b c; }¶ }¶} @@ limit_except içinde types
1 @@ baglam @@ types;¶ @@ types ifade olarak (blok değil)
1 @@ arguman @@ types a/b {¶} @@ types argümanlı blok
1 @@ arguman @@ types foo {¶ a/b c;¶} @@ types argümanlı blok (içerikli)
1 @@ kesin-ret @@ Types {¶} @@ Types (büyük harfli ad)
1 @@ kesin-ret @@ TYPES { a/b c; } @@ TYPES
1 @@ kesin-ret @@ types_hash_max_size 1024; @@ types_hash_max_size kesin-ret
1 @@ kesin-ret @@ types_hash_bucket_size 64; @@ types_hash_bucket_size kesin-ret
2 @@ lexer @@ types { a/b c; @@ kapanmamış types bloğu
2 @@ lexer @@ types { a/b c } @@ ';' eksik, '}' ifade içinde
2 @@ lexer @@ types { a/b c; } } @@ fazla '}'
2 @@ lexer @@ types { a/b c; }} @@ fazla '}' (bitişik)
2 @@ lexer @@ } types { a/b c; } @@ başta '}'
1 @@ kesin-ret @@ types { a/b c; }¶proxy_pass http://x; @@ types dışına taşan proxy_pass
1 @@ kesin-ret @@ types { a/b c; }¶include /etc/passwd; @@ types dışına taşan include
1 @@ tanınmayan-direktif @@ types { a/b c; }¶foo bar; @@ types dışına taşan tanınmayan satır
1 @@ - @@ types { a/b c; }¶image/jpeg jpg; @@ types DIŞINDA MIME satırı (blok kapandı → tanınmayan)
1 @@ tanınmayan-direktif @@ image/jpeg jpg; @@ types'sız çıplak MIME satırı
1 @@ - @@ location /x {¶ types { a/b c; }¶ image/png png;¶} @@ location içinde types dışı MIME satırı
CASES

echo "── G: canlı media.conf kopyası (birebir fikstür) ──"
FIX="${REPO_ROOT}/tests/fixtures/custom.d/media.conf"
assert_ok test -f "$FIX"
assert_eq "$(md5 -q "$FIX" 2>/dev/null || md5sum "$FIX" | cut -d' ' -f1)" "a3f9f4413c69bcfd35683cb41ebb87ab" "fikstür = canlı media.conf kopyası (md5 kilidi, 74 satır)"
assert_eq "$(wc -l < "$FIX" | tr -d ' ')" "74" "fikstür 74 satır"
_RC=0; _OUT=$(_ngxallow_scan "$FIX" designwestgate.art media.conf 2>&1) || _RC=$?
assert_eq "$_RC" "0" "canlı media.conf: _ngxallow_scan rc 0 (TEMİZ) :: $(printf '%s' "$_OUT" | head -2 | tr '\n' ' ')"
assert_eq "$_OUT" "" "canlı media.conf: bulgu yok"
# fikstürün güvenlik özü bozulursa (koruma çıkarılırsa) beklenti kırılmasın diye: fikstürün kendisi korumayı İÇERMELİ
FIXTXT=$(cat "$FIX")
assert_contains "$FIXTXT" "return 403;" "fikstür: betik uzantıları 403"
assert_contains "$FIXTXT" "default_type application/octet-stream;" "fikstür: bilinmeyen uzantı octet-stream"
assert_contains "$FIXTXT" "autoindex off;" "fikstür: autoindex off"
assert_contains "$FIXTXT" "sandbox" "fikstür: SVG sandbox CSP"
# nginx-audit'in kullanıcı dosyası tarayıcısı (_domconf_scan_user_files): custom.d/<sname>/media.conf olarak TEMİZ (rc 0), bulgu yok
SUFDIR="${TMP}/custom.d/designwestgate_art"; mkdir -p "$SUFDIR"; cp "$FIX" "${SUFDIR}/media.conf"
export SRVCTL_STATE_DIR="${TMP}/state"; mkdir -p "$SRVCTL_STATE_DIR"
_RC=0; _domconf_scan_user_files designwestgate.art designwestgate_art "$SUFDIR" >/dev/null 2>&1 || _RC=$?
assert_eq "$_RC" "0" "nginx-audit kullanıcı dosyası taraması (media.conf): rc 0 (TEMİZ) :: ${_SUF_OUT}"
assert_eq "$_SUF_OUT" "" "nginx-audit kullanıcı dosyası taraması: bulgu yok"
printf 'location /m/ {\n autoindex on;\n}\n' > "${SUFDIR}/media.conf"
_RC=0; _domconf_scan_user_files designwestgate.art designwestgate_art "$SUFDIR" >/dev/null 2>&1 || _RC=$?
assert_eq "$_RC" "1" "nginx-audit kullanıcı dosyası taraması: autoindex on → İHLAL (rc 1)"

test_summary
