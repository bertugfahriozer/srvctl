#!/bin/bash
# lib/nginx_allow.sh — custom.d KULLANICI dosyaları için varsayılan-ret izin listesi.
#
# Kilitlenenler (v1 D3 + v2 revizyonu; QL1-QL3 + SEC/devops tasarım PoC'leri):
#   A  her direktif için POZİTİF vaka (tarayıcı gerçekten kabul eden bir tarayıcıdır)
#   B  her kısıt için İHLAL NEGATİFİ (rc + gerekçe sınıfı)
#   C  KESİN RET listesi, tanınmayan direktif, G0 yasak dizgiler, kapalı değişken kümesi
#   D  lexer / yapı / boyut tavanı / rezerve ad / sembolik bağ / set -e güvenliği
#   E  PoC korpusu: tests/fuzz/seeds/poc/*.conf hepsi RED, seeds/ok/*.conf hepsi KABUL
#   F  fuzz regresyonları: tests/fuzz/regress/*.conf (RED beklenir; kabul∧güvensiz sabitleri)
# Vaka biçimi:  BEKLENEN_RC @@ GEREKÇE_SINIFI|- @@ NGINX_METNİ(¶=satır sonu) @@ AÇIKLAMA
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
# MUTASYON KANCASI: SRVCTL_NGXALLOW_LIB ile mutant kopya yüklenebilir (yalnız test)
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

echo "── A: POZİTİF — izin listesindeki her direktif kabul edilir ──"
run_cases <<'CASES'
0 @@ - @@ client_max_body_size 100M; @@ client_max_body_size 100M
0 @@ - @@ client_max_body_size 64k; @@ client_max_body_size 64k
0 @@ - @@ client_max_body_size 1g; @@ client_max_body_size 1g
0 @@ - @@ client_max_body_size 999999; @@ client_max_body_size 999999 (6 hane)
0 @@ - @@ location /a/ {¶}¶ @@ location öneki
0 @@ - @@ location = /robots.txt {¶ return 200 "ok";¶}¶ @@ location = tam eşleşme
0 @@ - @@ location ^~ /assets/ {¶ expires 30d;¶}¶ @@ location ^~ önek
0 @@ - @@ location ~ \.(jpg|png)$ {¶ expires max;¶}¶ @@ location ~ düzenli ifade (alternasyon, nicelik yok)
0 @@ - @@ location ~* \.(gif|ico|svg)$ {¶ log_not_found off;¶}¶ @@ location ~* büyük/küçük harf duyarsız
0 @@ - @@ location @app {¶ return 404;¶}¶ @@ adlı location (fm hariç)
0 @@ - @@ location /a/ {¶ location /a/b/ {¶ return 403;¶ }¶}¶ @@ iç içe location
0 @@ - @@ add_header X-Frame-Options "SAMEORIGIN" always; @@ add_header sabit + always
0 @@ - @@ add_header Cache-Control "public, max-age=3600"; @@ add_header sabit
0 @@ - @@ add_header X-Req $request_uri; @@ add_header $request_uri (ham) serbest
0 @@ - @@ add_header X-H "$scheme://$host:$server_name $args$is_args$query_string"; @@ add_header ham değişkenler serbest
0 @@ - @@ add_header X-M "$request_method $remote_addr $http_host $http_user_agent $http_referer $arg_foo_1"; @@ add_header kalan kapalı küme + $arg_*
0 @@ - @@ return 403; @@ return KOD
0 @@ - @@ return 444; @@ return 444
0 @@ - @@ return 200 "ok"; @@ return 200 metin
0 @@ - @@ return 301 https://$host$request_uri; @@ return 301 URL (ham değişkenler)
0 @@ - @@ return https://example.com/x; @@ return tek URL
0 @@ - @@ allow 10.0.0.0/8;¶deny all; @@ allow/deny IPv4 CIDR + all
0 @@ - @@ allow 192.168.1.1; @@ allow tek IPv4
0 @@ - @@ allow 2001:db8::/32;¶allow ::1; @@ allow IPv6
0 @@ - @@ location /x {¶ try_files $uri $uri/ /index.php?$args;¶} @@ try_files $uri $uri/ sabit?$args
0 @@ - @@ location /x {¶ try_files $uri =404;¶} @@ try_files =KOD
0 @@ - @@ location /x {¶ try_files $uri @app;¶}¶location @app { return 404; } @@ try_files @ad
0 @@ - @@ location /x {¶ try_files /a.html /b.html /index.php?$query_string;¶} @@ try_files sabit yollar
0 @@ - @@ location /x {¶ limit_req zone=rl_api burst=20 nodelay;¶} @@ limit_req zone+burst+nodelay
0 @@ - @@ location /x {¶ limit_req zone=login_strict;¶ limit_conn conn_per_ip 10;¶} @@ limit_req login_strict + limit_conn
0 @@ - @@ location /x {¶ limit_except GET POST {¶ deny all;¶ }¶} @@ limit_except + deny
0 @@ - @@ location /x {¶ limit_except GET {¶ allow 10.0.0.0/8;¶ deny all;¶ }¶} @@ limit_except allow+deny
0 @@ - @@ expires 30d; @@ expires süre
0 @@ - @@ location /e1 { expires off; }¶location /e2 { expires epoch; }¶location /e3 { expires max; }¶location /e4 { expires -1; }¶location /e5 { expires 1h; } @@ expires off/epoch/max/-1/1h (ayrı location)
0 @@ - @@ expires modified +24h; @@ expires modified
0 @@ - @@ log_not_found off; @@ log_not_found off
0 @@ - @@ log_not_found on; @@ log_not_found on
0 @@ - @@ access_log off; @@ access_log off
0 @@ - @@ index index.html index.php; @@ index sabit dosya adları
0 @@ - @@ set $u_flag "1";¶add_header X-F $u_flag; @@ set $u_… + sonra kullanım
0 @@ - @@ set $u_flag "1";¶add_header X-F $U_FLAG; @@ değişken adı küçük harfe çevrilerek eşlenir
0 @@ - @@ set $u_dst "https://$host/x"; @@ set değeri ham değişkenlerle
0 @@ - @@ if ($arg_x = "1") {¶ return 403;¶} @@ if $arg_x = sabit
0 @@ - @@ if ($request_method = POST) {¶ return 405;¶} @@ if $request_method = POST
0 @@ - @@ if ($http_user_agent ~* "badbot") {¶ return 403;¶} @@ if $http_user_agent ~* sabit
0 @@ - @@ if ($uri ~ "^/old/[0-9]+$") {¶ return 410;¶} @@ if $uri ~ regex ($uri koşulda serbest)
0 @@ - @@ if ($uri !~ "^/ok/") {¶ return 403;¶} @@ if !~
0 @@ - @@ set $u_a 1;¶if ($u_a) {¶ return 403;¶} @@ if tek değişken (doğruluk)
0 @@ - @@ rewrite ^/old-page$ /new-page permanent; @@ rewrite permanent
0 @@ - @@ rewrite ^/a/([0-9]+)$ /b last; @@ rewrite last (sabit yol)
0 @@ - @@ rewrite ^/x$ /y break; @@ rewrite break
0 @@ - @@ rewrite ^/x$ https://$host/y redirect; @@ rewrite redirect (ham değişken)
0 @@ - @@ rewrite ^/x$ /y; @@ rewrite bayraksız iç yol
0 @@ - @@ if ($arg_x) {¶ return 403;¶} @@ server düzeyi if içinde return
0 @@ - @@ if ($arg_x) {¶ set $u_a 1;¶ rewrite ^/a$ /b break;¶} @@ server düzeyi if içinde set/rewrite
0 @@ - @@ location /a {¶ if ($arg_x) {¶ add_header X-A b;¶ expires 1d;¶ access_log off;¶ }¶} @@ location içi if içinde add_header/expires/access_log
0 @@ - @@ # yorum¶¶  # başka yorum¶ @@ yalnız yorum
0 @@ - @@  @@ boş dosya
0 @@ - @@ location ~ "^/p/(?<u_id>[0-9]+)$" {¶ if ($u_id = 5) {¶ return 403;¶ }¶} @@ adlı yakalama u_ adı; yalnız if koşulunda kullanılır
CASES

echo "── B: NEGATİF — her kısıt için ihlal ──"
run_cases <<'CASES'
# client_max_body_size
1 @@ arguman @@ client_max_body_size 0; @@ client_max_body_size 0 (sınırsız) yasak
1 @@ arguman @@ client_max_body_size 0m; @@ client_max_body_size 0m yasak
1 @@ arguman @@ client_max_body_size 1234567; @@ client_max_body_size 7 hane yasak
1 @@ arguman @@ client_max_body_size 10x; @@ client_max_body_size geçersiz birim
1 @@ arguman @@ client_max_body_size -1; @@ client_max_body_size negatif
1 @@ arguman @@ client_max_body_size $uri; @@ client_max_body_size değişken
1 @@ arguman @@ client_max_body_size 1m 2m; @@ client_max_body_size iki argüman
1 @@ arguman @@ client_max_body_size; @@ client_max_body_size argümansız
1 @@ baglam @@ if ($arg_x) {¶ client_max_body_size 1m;¶} @@ client_max_body_size if içinde
1 @@ baglam @@ if ($arg_x) {¶ add_header X-A b;¶} @@ add_header server düzeyi if içinde (nginx: not allowed here)
1 @@ baglam @@ if ($arg_x) {¶ expires 1d;¶} @@ expires server düzeyi if içinde
1 @@ baglam @@ if ($arg_x) {¶ access_log off;¶} @@ access_log server düzeyi if içinde
# location
1 @@ arguman @@ location a/ {¶} @@ location öneki / ile başlamalı
1 @@ arguman @@ location /a/../b {¶} @@ location önekinde ..
1 @@ arguman @@ location /a$b {¶} @@ location önekinde $
1 @@ baglam @@ location /a;b {¶} @@ location önekinde ;  (tırnaksız ';' ifadeyi böler)
1 @@ arguman @@ location "/a b" {¶} @@ location önekinde boşluk
1 @@ arguman @@ location @Bad {¶} @@ adlı location büyük harf
1 @@ arguman @@ location = @app {¶} @@ adlı location değiştiricisiz olmalı
1 @@ arguman @@ location ?? /x {¶} @@ location değiştirici geçersiz
1 @@ arguman @@ location {¶} @@ location argümansız
1 @@ arguman @@ location a b c {¶} @@ location üç argüman
1 @@ baglam @@ location /x; @@ location blok olmalı (ifade)
1 @@ baglam @@ if ($arg_x) {¶ location /y {¶ return 404;¶ }¶} @@ location if içinde
1 @@ regex @@ location ~ (a+)+$ {¶} @@ iç içe nicelik (a+)+
1 @@ regex @@ location ~ "(a|b)*c" {¶} @@ alternasyonlu nicelik (a|b)*
1 @@ regex @@ location ~ "((a*)b)*" {¶} @@ dolaylı iç içe nicelik
1 @@ regex @@ location ~ "(a{1,9}){1,9}" {¶} @@ iç içe sınırlı nicelik
# QL4-M9: eski "a*b*c*d*" / "a*b*c*d*e*" vakaları AYIRT ETMİYORDU — boş dizgiye eşleştikleri için her FM
# yolu örneğine de eşleşir ve nicelik tavanı olmadan da reddedilirlerdi. Çapalı "^/…x$" biçimi hiçbir
# örneğe eşleşmez; gerekçe iletisi ve 3/4 sınırı aşağıda (G1) ayrıca kilitli.
1 @@ regex @@ location ~ "^/a*b*c*d*e*x$" {¶} @@ çok sayıda sınırsız nicelik (çapalı; FM örneğine eşleşmez)
1 @@ regex @@ location ~ "a**" {¶} @@ ERE'ye çevrilemeyen/derlenemeyen desen fail-closed RED (grep rc 2)
1 @@ regex @@ location ~ "^/a*b*c*d*x$" {¶} @@ 4 sınırsız nicelik (sınır: en çok 3; çapalı)
0 @@ - @@ location ~ "^/a/(.*)/b/(.*)$" {¶} @@ 2 sınırsız nicelik serbest
1 @@ regex @@ location ~ "(?{ echo })" {¶} @@ PCRE kod bloğu (?{
1 @@ regex @@ location ~ "(*FAIL)" {¶} @@ PCRE fiili (*FAIL)
1 @@ regex @@ location ~ "(?R)" {¶} @@ PCRE rekürsiyon (?R)
1 @@ regex @@ location ~ "(?i)abc" {¶} @@ satır içi bayrak (?i)
1 @@ regex @@ location ~ "a(?=b)" {¶} @@ lookahead
1 @@ regex @@ location ~ "(a)\\1" {¶} @@ geri başvuru
1 @@ regex @@ location ~ "\\x5ffm" {¶} @@ onaltılık kaçış
1 @@ regex @@ location ~ "(?<a>x)" {¶} @@ adlı yakalama adı u_ ile başlamalı
1 @@ regex @@ location ~ "(?<u_>x)" {¶} @@ adlı yakalama adı çok kısa
1 @@ regex @@ location ~ "(abc" {¶} @@ kapanmamış grup
1 @@ regex @@ location ~ "abc)" {¶} @@ eşleşmeyen )
1 @@ regex @@ location ~ "[abc" {¶} @@ kapanmamış sınıf
1 @@ regex @@ location ~ "a{x" {¶} @@ yalın {
1 @@ regex @@ location ~ "" {¶} @@ boş desen
1 @@ regex @@ location ~ "^/.fm/up/" {¶} @@ .fm — FM yoluna eşleşir (nokta joker)
1 @@ regex @@ location ~ "^/..m/up/" {¶} @@ ..m — FM yoluna eşleşir
1 @@ regex @@ location ~ "^/[^a]fm/" {¶} @@ [^a]fm — FM yoluna eşleşir
1 @@ regex @@ location ~ "up/" {¶} @@ çapasız 'up/' — /_fm/up/1/2'ye eşleşir
1 @@ regex @@ location ~* "/UP/" {¶} @@ ~* büyük harf desen (küçük harfe indirgenip /_fm/up/ ile eşleşir)
1 @@ yasak-dizgi @@ location ~ "^/_fm/" {¶} @@ doğrudan /_fm/ regex
1 @@ regex @@ location ~ ".*" {¶} @@ her şeye eşleşen desen
# regex: sınır / kaçış / ardışık gizleme / bulaşık yakalamalar / politika kilitleri
1 @@ regex @@ location ~ "^/a_(b)$" {¶} @@ '_' komşuluk kuralı: sonrasında grup
1 @@ regex @@ location ~ "^/a[b]c$" {¶} @@ tek karakterlik sınıf gizleme yasağı
1 @@ regex @@ location ~ "^/.fm/z" {¶} @@ nokta jokeri /_fm/z ile eşleşir (genişletilmiş örnek kümesi)
1 @@ regex @@ location ~ "^/..m/up/[a-z]+$" {¶} @@ ..m jokeri /_fm/up/a/a ile eşleşir
1 @@ regex @@ location ~ "^/.fm/dl/[0-9]+" {¶} @@ nokta jokeri + rakam kuyruğu
0 @@ - @@ location ~ "^/form/$" {¶ return 403;¶} @@ 'fm' alt dizgisi içeren masum desen (form) KABUL — yanlış-ret yok
0 @@ - @@ location ~ "^/x/(\d+?)$" {¶ return 403;¶} @@ tembel (lazy) nicelik ERE'ye çevrilir
0 @@ - @@ location ~ "^/img\_[0-9]+\.png$" {¶ return 403;¶} @@ kaçışlı '_' düz karakter (taşınabilir ERE)
1 @@ degisken @@ location /x {¶ if ($uri ~ "^/(?<u_id>[0-9]+)$") {¶ add_header X-I $u_id;¶ }¶} @@ if regex adlı yakalaması çıkış kanalında yasak (bulaşık)
1 @@ degisken @@ rewrite "^/(?<u_id>[0-9]+)$" /b last;¶add_header X-I $u_id; @@ rewrite regex adlı yakalaması çıkış kanalında yasak (bulaşık)
1 @@ yasak-dizgi @@ return 200 "x_\fm_y"; @@ ters bölü soyulduktan sonra _fm_ (kaçış gizleme)
1 @@ yasak-dizgi @@ return 200 "x_f\m_y"; @@ ters bölü YALNIZ soyulunca _fm_ olur (soyma adımını tek başına kilitler)
1 @@ yasak-dizgi @@ return 200 "X_\FM_Y"; @@ büyük harf + ters bölü gizleme
1 @@ kesin-ret @@ example_pass http://x; @@ herhangi *_pass direktifi kesin-ret
1 @@ kesin-ret @@ location /x {¶ ldap_pass x;¶} @@ ldap_pass (genel *_pass sınıfı)
1 @@ arguman @@ ï»¿return 403; @@ BOM önekli direktif adı (ASCII dışı)
# add_header
1 @@ arguman @@ add_header X-A; @@ add_header tek argüman
1 @@ arguman @@ add_header X-A b c d; @@ add_header dört argüman
1 @@ arguman @@ add_header X-A b never; @@ add_header üçüncü argüman always değil
1 @@ arguman @@ add_header 1X b; @@ add_header ad rakamla başlıyor
1 @@ arguman @@ add_header "X A" b; @@ add_header adında boşluk
1 @@ arguman @@ add_header X_A:b c; @@ add_header adında ':' '_'
1 @@ yasak-dizgi @@ add_header X-Fm-Foo bar; @@ add_header X-Fm-* ad uzayı
1 @@ yasak-dizgi @@ add_header X-Accel-Redirect /x; @@ add_header X-Accel-*
1 @@ yasak-dizgi @@ add_header x-fm-auth y; @@ add_header x-fm-auth (küçük harf)
1 @@ degisken @@ add_header X-A $uri; @@ add_header $uri (CRLF)
1 @@ degisken @@ add_header X-A "a${host}b"; @@ add_header ${…} biçimi
1 @@ degisken @@ add_header X-A $; @@ add_header çıplak $
1 @@ degisken @@ add_header X-A $foo; @@ add_header kapalı küme dışı değişken
1 @@ degisken @@ add_header X-A $u_nodef; @@ add_header tanımsız u_ değişkeni
1 @@ degisken @@ add_header X-A $host$uri; @@ add_header karışık değer $uri
1 @@ degisken @@ add_header X-A $1; @@ add_header $1 (yakalama; CRLF)
1 @@ degisken @@ add_header X-A $0; @@ add_header $0
1 @@ degisken @@ add_header X-A $10; @@ add_header $10
1 @@ degisken @@ add_header X-A $Uri; @@ add_header $Uri (büyük harf)
1 @@ degisken @@ add_header X-A $URI; @@ add_header $URI
1 @@ degisken @@ add_header X-A "\$uri"; @@ add_header ters bölülü \$uri hâlâ değişkendir
1 @@ degisken @@ add_header X-A $arg_; @@ add_header $arg_ (adsız)
1 @@ arguman @@ add_header X-A "a\nb"; @@ add_header LF kaçışı (CRLF)
1 @@ arguman @@ add_header X-A "a\rb"; @@ add_header CR kaçışı
1 @@ arguman @@ add_header X-A "a\tb"; @@ add_header sekme
1 @@ yasak-dizgi @@ add_header X-A $http_authorization; @@ add_header $http_authorization
1 @@ yasak-dizgi @@ add_header X-A $cookie_a; @@ add_header $cookie_a
1 @@ yasak-dizgi @@ add_header X-A $sent_http_x_a; @@ add_header $sent_http_*
1 @@ yasak-dizgi @@ add_header X-A $upstream_http_x_a; @@ add_header $upstream_http_*
1 @@ yasak-dizgi @@ add_header X-A $ssl_client_cert; @@ add_header $ssl_*
# return
1 @@ arguman @@ return 99; @@ return kod < 200
1 @@ arguman @@ return 600; @@ return kod > 599
1 @@ arguman @@ return abc; @@ return çıplak sözcük
1 @@ arguman @@ return 200 a b; @@ return üç argüman
1 @@ arguman @@ return; @@ return argümansız
1 @@ arguman @@ return 1000 x; @@ return dört haneli kod
1 @@ degisken @@ return 200 $uri; @@ return $uri
1 @@ degisken @@ return 301 https://$host$uri; @@ return redirect $uri
1 @@ degisken @@ return 302 http://x/$1; @@ return redirect $1
1 @@ arguman @@ return $uri; @@ return $uri tek argüman  (URL değil)
1 @@ yasak-dizgi @@ return 200 "/_fm/x"; @@ return /_fm/ metni
1 @@ degisken @@ return 200 "$foo"; @@ return bilinmeyen değişken
# set
1 @@ yasak-dizgi @@ set $fm_gate 1; @@ set $fm_* hedefi
1 @@ degisken @@ set $args x; @@ set $args hedefi
1 @@ degisken @@ set $limit_rate 1; @@ set $limit_rate hedefi
1 @@ degisken @@ set $arg_x 1; @@ set $arg_x hedefi
1 @@ degisken @@ set $http_x 1; @@ set $http_x hedefi
1 @@ yasak-dizgi @@ set $cookie_x 1; @@ set $cookie_x hedefi
1 @@ degisken @@ set $upstream_x 1; @@ set $upstream_x hedefi
1 @@ yasak-dizgi @@ set $sent_http_x 1; @@ set $sent_http_x hedefi
1 @@ yasak-dizgi @@ set $ssl_x 1; @@ set $ssl_x hedefi
1 @@ degisken @@ set $blocked_country 1; @@ set $blocked_country hedefi
1 @@ yasak-dizgi @@ set $srvctl_x 1; @@ set $srvctl_x hedefi
1 @@ degisken @@ set $U_Upper 1; @@ set hedefi büyük harf
1 @@ degisken @@ set $u_ 1; @@ set hedefi çok kısa
1 @@ degisken @@ set $u_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1; @@ set hedefi 33 karakter (tavan)
1 @@ degisken @@ set u_a 1; @@ set hedefi $ olmadan
1 @@ degisken @@ set $u_a $uri; @@ set değeri $uri (laundering)
1 @@ degisken @@ set $u_a $1; @@ set değeri $1
1 @@ degisken @@ set $u_a $u_nodef; @@ set değeri tanımsız u_
1 @@ arguman @@ set $u_a; @@ set tek argüman
1 @@ arguman @@ set $u_a 1 2; @@ set üç argüman
1 @@ degisken @@ location ~ "^/p/(?<u_id>[0-9]+)$" {¶ add_header X-I $u_id;¶} @@ yakalama değişkeni (bulaşık) çıkış kanalında
1 @@ degisken @@ location ~ "^/p/(?<u_id>[0-9]+)$" {¶ set $u_b $u_id;¶} @@ yakalama değişkeni set ile aklanamaz
1 @@ degisken @@ location ~ "^/p/(?<u_id>[0-9]+)$" {¶ return 301 https://$host/$u_id;¶} @@ yakalama değişkeni redirect'te
# allow / deny
1 @@ arguman @@ allow unix:/run/x.sock; @@ allow unix:
1 @@ arguman @@ allow 999.1.1.1; @@ allow geçersiz IPv4
1 @@ arguman @@ allow 1.2.3.4/33; @@ allow CIDR > 32
1 @@ arguman @@ allow 1.2.3; @@ allow eksik IPv4
1 @@ arguman @@ allow ::1/129; @@ allow IPv6 CIDR > 128
1 @@ arguman @@ allow all all; @@ allow iki argüman
1 @@ arguman @@ deny example.com; @@ deny ad
1 @@ arguman @@ deny $remote_addr; @@ deny değişken
1 @@ baglam @@ if ($arg_x) {¶ allow all;¶} @@ allow if içinde
# try_files
1 @@ arguman @@ try_files $uri /a/../b; @@ try_files yolunda ..
1 @@ arguman @@ try_files $uri.php =404; @@ try_files $uri.php biçimi
1 @@ arguman @@ try_files $uri =4040; @@ try_files =KOD 4 hane
1 @@ arguman @@ try_files $uri @Bad; @@ try_files @ad büyük harf
1 @@ arguman @@ try_files $uri; @@ try_files tek argüman
1 @@ arguman @@ try_files /x$uri =404; @@ try_files /x$uri
1 @@ arguman @@ try_files $uri /index.php?$foo; @@ try_files ?$foo
1 @@ arguman @@ try_files $uri $uri/ /a /b /c /d /e /f /g /h; @@ try_files 9 argüman
# limit_req / limit_conn / limit_except
1 @@ arguman @@ location /x {¶ limit_req zone=evil burst=5;¶} @@ limit_req kapalı küme dışı zone
1 @@ arguman @@ location /x {¶ limit_req zone=conn_per_ip;¶} @@ limit_req conn zone'u
1 @@ arguman @@ location /x {¶ limit_req burst=5;¶} @@ limit_req zone'suz
1 @@ arguman @@ location /x {¶ limit_req zone=rl_api zone=rl_api;¶} @@ limit_req zone tekrarı
1 @@ arguman @@ location /x {¶ limit_req zone=rl_api burst=x;¶} @@ limit_req burst sayı değil
1 @@ arguman @@ location /x {¶ limit_req zone=rl_api burst=123456;¶} @@ limit_req burst 6 hane
1 @@ arguman @@ location /x {¶ limit_req zone=rl_api burst=0;¶} @@ limit_req burst=0 (nginx de reddeder)
1 @@ arguman @@ location /x {¶ limit_req zone=rl_api delay=3;¶} @@ limit_req delay=
1 @@ baglam @@ limit_req zone=rl_api; @@ limit_req server düzeyinde
1 @@ baglam @@ limit_conn conn_per_ip 10; @@ limit_conn server düzeyinde
1 @@ arguman @@ location /x {¶ limit_conn other 10;¶} @@ limit_conn başka zone
1 @@ arguman @@ location /x {¶ limit_conn conn_per_ip 0;¶} @@ limit_conn N=0
1 @@ arguman @@ location /x {¶ limit_conn conn_per_ip x;¶} @@ limit_conn N sayı değil
1 @@ arguman @@ location /x {¶ limit_except TRACE {¶ deny all;¶ }¶} @@ limit_except TRACE
1 @@ arguman @@ location /x {¶ limit_except get {¶ deny all;¶ }¶} @@ limit_except küçük harf yöntem
1 @@ baglam @@ limit_except GET {¶ deny all;¶} @@ limit_except server düzeyinde
1 @@ baglam @@ location /x {¶ limit_except GET {¶ return 200 x;¶ }¶} @@ limit_except gövdesinde return
1 @@ baglam @@ location /x {¶ limit_except GET {¶ set $u_a 1;¶ }¶} @@ limit_except gövdesinde set
# expires / log_not_found / access_log / index
1 @@ arguman @@ expires 1x; @@ expires geçersiz birim
1 @@ arguman @@ expires $exp; @@ expires değişken
1 @@ arguman @@ expires modified; @@ expires modified süresiz
1 @@ arguman @@ expires a b c; @@ expires üç argüman
1 @@ arguman @@ expires 1234567890123; @@ expires çok uzun sayı
1 @@ arguman @@ log_not_found maybe; @@ log_not_found geçersiz değer
1 @@ arguman @@ log_not_found on off; @@ log_not_found iki argüman
1 @@ arguman @@ access_log /var/log/nginx/x.log; @@ access_log yol
1 @@ arguman @@ access_log /var/log/nginx/../../tmp/e.log main; @@ access_log .. yolu
1 @@ arguman @@ access_log off main; @@ access_log off + format
1 @@ arguman @@ access_log syslog:server=127.0.0.1; @@ access_log syslog
1 @@ arguman @@ access_log; @@ access_log argümansız
1 @@ arguman @@ index $x; @@ index değişken
1 @@ arguman @@ index /abs/path.html; @@ index mutlak yol
1 @@ arguman @@ index ..; @@ index ..
1 @@ arguman @@ index a b c d e f g h i; @@ index 9 dosya
# rewrite
1 @@ arguman @@ rewrite ^/a$ /b/$1 last; @@ rewrite last YERİNE değişken ($1)
1 @@ arguman @@ rewrite ^/a$ $uri last; @@ rewrite last YERİNE $uri
1 @@ arguman @@ rewrite ^/a$ /b/../c last; @@ rewrite YERİNE ..
1 @@ arguman @@ rewrite ^/a$ /b flagx; @@ rewrite geçersiz bayrak
1 @@ arguman @@ rewrite ^/a$; @@ rewrite tek argüman
1 @@ arguman @@ rewrite ^/a$ /b last extra; @@ rewrite dört argüman
1 @@ arguman @@ rewrite ^/a$ b last; @@ rewrite YERİNE / ile başlamıyor
1 @@ degisken @@ rewrite ^/a/(.*)$ http://evil/$1 redirect; @@ rewrite redirect hedefi $1
1 @@ degisken @@ rewrite ^/a$ http://evil/$uri; @@ rewrite bayraksız http:// $uri
1 @@ degisken @@ rewrite ^/a$ https://$host$uri permanent; @@ rewrite permanent $uri
1 @@ regex @@ rewrite (a+)+ /b last; @@ rewrite regex ReDoS
1 @@ yasak-dizgi @@ rewrite "^/_fm/(.*)$" /b last; @@ rewrite regex /_fm/
# if
1 @@ arguman @@ if (-f $request_filename) {¶ return 403;¶} @@ if dosya testi -f
1 @@ arguman @@ if (!-e $request_filename) {¶ return 403;¶} @@ if dosya testi !-e
1 @@ arguman @@ if (-d /etc) {¶ return 403;¶} @@ if dosya testi -d
1 @@ arguman @@ if ($arg_a = b && $arg_c = d) {¶ return 403;¶} @@ if bileşik koşul
1 @@ arguman @@ if ("$arg_a$arg_b" = x) {¶ return 403;¶} @@ if sol işlenen bileşik dize
1 @@ arguman @@ if ($arg_a == b) {¶ return 403;¶} @@ if geçersiz işleç
1 @@ arguman @@ if ($arg_a = $arg_b) {¶ return 403;¶} @@ if sağ işlenen değişken
1 @@ arguman @@ if arg_a {¶ return 403;¶} @@ if parantezsiz
1 @@ arguman @@ if () {¶ return 403;¶} @@ if boş koşul
1 @@ degisken @@ if ($foo = 1) {¶ return 403;¶} @@ if kapalı küme dışı değişken
1 @@ yasak-dizgi @@ if ($fm_gate != 1) {¶ return 403;¶} @@ if $fm_gate
1 @@ degisken @@ if ($u_nodef) {¶ return 403;¶} @@ if tanımsız u_
1 @@ regex @@ if ($arg_a ~ "(a+)+") {¶ return 403;¶} @@ if regex ReDoS
1 @@ regex @@ location ~ "(?<u_a>.)fm/up/" {¶} @@ adlı yakalama sonrası '.fm/up/' eşleşmesi (fuzz F1: adlı yakalama ofset hatası)
1 @@ regex @@ location ~ "(?<u_a>p)$" {¶} @@ adlı yakalama + sonu sabit: /_fm/up/p ile eşleşir (fuzz F1)
1 @@ regex @@ rewrite "(a?){30}a{30}" /b last; @@ (X?){n} sınırlı-ama-üstel ReDoS (fuzz F2)
1 @@ regex @@ rewrite "^up/(?:[^/][a-z0-9]?){2}1/up{1,3}" /new last; @@ grup içi '?' + {n} (fuzz F2 aslı)
0 @@ - @@ location ~ "^/blog/(?<u_slug>[a-z-]+)/$" {¶ return 403;¶} @@ adlı yakalama doğru ayrıştırılır (izinli desen KABUL)
0 @@ - @@ location ~ "^/a(b)?c$" {¶ return 403;¶} @@ grup dışı '?' (isteğe bağlı grup) serbest
1 @@ regex @@ if ($uri ~* "/UP/") {¶ return 403;¶} @@ if ~* küçük harfe indirgenip /_fm/up/ ile eşleşir
1 @@ regex @@ if ($uri !~* "^/ok|/UP/") {¶ return 403;¶} @@ if !~* alternasyon /UP/
1 @@ yasak-dizgi @@ if ($uri ~ "/_fm/") {¶ return 403;¶} @@ if regex /_fm/
1 @@ baglam @@ if ($arg_a) {¶ if ($arg_b) {¶ return 403;¶ }¶} @@ if içinde if
1 @@ baglam @@ if ($arg_a);¶ @@ if blok olmalı
1 @@ baglam @@ if($arg_a) {¶ return 403;¶} @@ if( bitişik (nginx de reddeder)
CASES

echo "── C: KESİN RET / tanınmayan direktif / G0 yasak dizgiler ──"
run_cases <<'CASES'
1 @@ kesin-ret @@ location /x {¶ proxy_pass https://api.pcloud.com/;¶} @@ proxy_pass (tek istisna da KULLANILMAZ — v2)
1 @@ kesin-ret @@ location /x {¶ proxy_pass http://127.0.0.1:3000;¶} @@ proxy_pass loopback
1 @@ kesin-ret @@ location /x {¶ proxy_pass $arg_u;¶} @@ proxy_pass değişkenli
1 @@ kesin-ret @@ location /x {¶ proxy_pass http://unix:/run/x.sock:/;¶} @@ proxy_pass unix soket
1 @@ kesin-ret @@ location /x {¶ proxy_set_header Authorization $http_authorization;¶} @@ proxy_set_header
1 @@ kesin-ret @@ location /x {¶ proxy_http_version 1.1;¶} @@ proxy_http_version
1 @@ kesin-ret @@ location /x {¶ proxy_ssl_verify off;¶} @@ proxy_ssl_verify
1 @@ kesin-ret @@ location /x {¶ proxy_redirect off;¶} @@ proxy_redirect
1 @@ kesin-ret @@ location /x {¶ proxy_buffering off;¶} @@ proxy_buffering
1 @@ kesin-ret @@ location /x {¶ fastcgi_pass unix:/run/php/o.sock;¶} @@ fastcgi_pass
1 @@ kesin-ret @@ location /x {¶ fastcgi_param PHP_VALUE "x";¶} @@ fastcgi_param
1 @@ kesin-ret @@ location /x {¶ fastcgi_hide_header X-Fm-Auth;¶} @@ fastcgi_hide_header
1 @@ kesin-ret @@ location /x {¶ fastcgi_read_timeout 300s;¶} @@ fastcgi_read_timeout (ölü etki; v2'de çıkarıldı)
1 @@ kesin-ret @@ location /x {¶ uwsgi_pass 127.0.0.1:9;¶} @@ uwsgi_pass
1 @@ kesin-ret @@ location /x {¶ scgi_pass 127.0.0.1:9;¶} @@ scgi_pass
1 @@ kesin-ret @@ location /x {¶ grpc_pass grpc://127.0.0.1:9;¶} @@ grpc_pass
1 @@ kesin-ret @@ location /x {¶ memcached_pass 127.0.0.1:11211;¶} @@ memcached_pass
1 @@ kesin-ret @@ location /x {¶ auth_request /__a;¶} @@ auth_request
1 @@ kesin-ret @@ location /x {¶ auth_request_set $u_t $upstream_http_x;¶} @@ auth_request_set
1 @@ kesin-ret @@ include /etc/nginx/x.conf; @@ include
1 @@ kesin-ret @@ location /x {¶ include /etc/nginx/custom.d/example_com/srvctl-fm-upload-*.inc;¶} @@ include (glob)
1 @@ kesin-ret @@ root /etc; @@ root
1 @@ kesin-ret @@ alias /etc/; @@ alias
1 @@ kesin-ret @@ server_name evil.com; @@ server_name
1 @@ kesin-ret @@ listen 8080; @@ listen
1 @@ kesin-ret @@ disable_symlinks off; @@ disable_symlinks
1 @@ kesin-ret @@ modsecurity off; @@ modsecurity
1 @@ kesin-ret @@ modsecurity_rules_file /dev/null; @@ modsecurity_rules_file
1 @@ kesin-ret @@ ssl_certificate /etc/x.pem; @@ ssl_certificate
1 @@ kesin-ret @@ ssl_verify_client off; @@ ssl_verify_client
1 @@ kesin-ret @@ upstream u {¶ server 127.0.0.1:1;¶} @@ upstream
1 @@ kesin-ret @@ map $uri $u_x {¶ default 1;¶} @@ map
1 @@ kesin-ret @@ geo $u_x {¶ default 1;¶} @@ geo
1 @@ kesin-ret @@ split_clients "x" $u_x {¶ * a;¶} @@ split_clients
1 @@ kesin-ret @@ stream {¶} @@ stream
1 @@ kesin-ret @@ mail {¶} @@ mail
1 @@ kesin-ret @@ events {¶} @@ events
1 @@ kesin-ret @@ http {¶} @@ http
1 @@ kesin-ret @@ server {¶ listen 1;¶} @@ server
1 @@ kesin-ret @@ error_log /var/log/nginx/x.log; @@ error_log
1 @@ kesin-ret @@ error_log /var/log/nginx/x.log debug; @@ error_log debug
1 @@ kesin-ret @@ error_page 404 /e.html; @@ error_page
1 @@ kesin-ret @@ location /x {¶ internal;¶} @@ internal
1 @@ kesin-ret @@ charset utf-8; @@ charset
1 @@ - @@ default_type $uri; @@ default_type değişkenli (MIME belirteci değil)
1 @@ kesin-ret @@ gzip on; @@ gzip
1 @@ kesin-ret @@ etag off; @@ etag
1 @@ kesin-ret @@ autoindex on; @@ autoindex
1 @@ kesin-ret @@ server_tokens off; @@ server_tokens
1 @@ kesin-ret @@ satisfy any; @@ satisfy
1 @@ kesin-ret @@ limit_rate 1k; @@ limit_rate
1 @@ kesin-ret @@ client_body_timeout 5s; @@ client_body_timeout
1 @@ kesin-ret @@ client_body_buffer_size 1m; @@ client_body_buffer_size
1 @@ kesin-ret @@ client_body_temp_path /tmp/x; @@ client_body_temp_path
1 @@ kesin-ret @@ keepalive_timeout 5s; @@ keepalive_timeout
1 @@ kesin-ret @@ send_timeout 5s; @@ send_timeout
1 @@ kesin-ret @@ large_client_header_buffers 4 8k; @@ large_client_header_buffers
1 @@ kesin-ret @@ auth_basic "x"; @@ auth_basic
1 @@ kesin-ret @@ auth_basic_user_file /etc/nginx/.htpasswd; @@ auth_basic_user_file
1 @@ kesin-ret @@ ssi on; @@ ssi
1 @@ kesin-ret @@ add_before_body /x; @@ add_before_body
1 @@ kesin-ret @@ add_after_body /x; @@ add_after_body
1 @@ kesin-ret @@ sub_filter a b; @@ sub_filter
1 @@ kesin-ret @@ more_set_headers "X-A: b"; @@ more_set_headers
1 @@ kesin-ret @@ add_trailer X-A b; @@ add_trailer
1 @@ kesin-ret @@ lua_package_path "/x"; @@ lua_*
1 @@ kesin-ret @@ content_by_lua_block {¶} @@ content_by_lua_block
1 @@ kesin-ret @@ js_content main; @@ js_content
1 @@ kesin-ret @@ perl_modules /x; @@ perl_modules
1 @@ kesin-ret @@ echo hi; @@ echo
1 @@ kesin-ret @@ xslt_stylesheet /x; @@ xslt_stylesheet
1 @@ kesin-ret @@ load_module modules/x.so; @@ load_module
1 @@ kesin-ret @@ mirror /m; @@ mirror
1 @@ kesin-ret @@ dav_methods PUT; @@ dav_methods
1 @@ kesin-ret @@ resolver 8.8.8.8; @@ resolver
1 @@ - @@ types text/html; @@ types argümanlı (blok değil)
1 @@ kesin-ret @@ limit_req_zone $binary_remote_addr zone=z:1m rate=1r/s; @@ limit_req_zone
1 @@ kesin-ret @@ log_format x '$remote_addr'; @@ log_format
1 @@ kesin-ret @@ set_real_ip_from 0.0.0.0/0; @@ set_real_ip_from
1 @@ kesin-ret @@ empty_gif; @@ empty_gif
1 @@ tanınmayan-direktif @@ foo bar; @@ bilinmeyen direktif
1 @@ kesin-ret @@ PROXY_PASS http://x; @@ büyük harf sözdizimi (proxy)
1 @@ tanınmayan-direktif @@ Location /x {¶} @@ Location (büyük harf) tanınmaz
1 @@ tanınmayan-direktif @@ Return 200; @@ Return (büyük harf)
1 @@ tanınmayan-direktif @@ stub_x 1; @@ stub_x
1 @@ tanınmayan-direktif @@ xml_external_entities on; @@ nginx'te olmayan direktif de tanınmaz
1 @@ tanınmayan-direktif @@ client_max_body_size_x 1; @@ benzer ad
1 @@ tanınmayan-direktif @@ add_header_x a b; @@ benzer ad 2
1 @@ yasak-dizgi @@ return 200 "/_FM/x"; @@ /_FM/ büyük harf
1 @@ yasak-dizgi @@ return 200 "__fm_auth"; @@ __fm_auth
1 @@ yasak-dizgi @@ return 200 "@fm_up"; @@ @fm_up
1 @@ yasak-dizgi @@ location /_fm/ {¶} @@ location /_fm/ önek
1 @@ yasak-dizgi @@ location = /__fm_auth {¶} @@ location = /__fm_auth
1 @@ yasak-dizgi @@ location /FM_AUTH {¶} @@ location FM_AUTH (büyük harf)
1 @@ yasak-dizgi @@ location /\_fm/ {¶} @@ ters bölü ile gizlenmiş /\_fm/
1 @@ yasak-dizgi @@ return 200 "x_fm_auth"; @@ x_fm_auth
1 @@ yasak-dizgi @@ return 200 "$fm_auth"; @@ $fm_auth
1 @@ yasak-dizgi @@ return 200 "$FM_AUTH"; @@ $FM_AUTH (büyük harf)
1 @@ yasak-dizgi @@ return 200 "srvctl"; @@ srvctl ad uzayı
1 @@ yasak-dizgi @@ return 200 "@srvctl_x"; @@ @srvctl_
1 @@ yasak-dizgi @@ return 200 "__srvctl_webhook"; @@ __srvctl_webhook
1 @@ yasak-dizgi @@ try_files $uri @fm_up; @@ try_files @fm_up
1 @@ yasak-dizgi @@ return 200 "$cookie_a"; @@ $cookie_
1 @@ yasak-dizgi @@ return 200 "$http_authorization"; @@ $http_authorization
1 @@ yasak-dizgi @@ return 200 "$HTTP_AUTHORIZATION"; @@ $HTTP_AUTHORIZATION (büyük harf)
1 @@ yasak-dizgi @@ return 200 "$UPSTREAM_HTTP_X_FM_AUTH"; @@ $UPSTREAM_HTTP_* büyük harf
1 @@ yasak-dizgi @@ return 200 "$Sent_Http_X"; @@ $Sent_Http_
1 @@ yasak-dizgi @@ return 200 "$SSL_CLIENT_CERT"; @@ $SSL_
CASES

echo "── D: lexer / yapı / boyut / rezerve ad / sembolik bağ / set -e ──"
# D1: rc 2 (çözümlenemedi) vakaları
run_cases <<'CASES'
2 @@ lexer @@ location /x {¶ return 403;¶ @@ kapanmamış blok
2 @@ lexer @@ location /x {¶ return 403;¶}¶} @@ fazladan }
2 @@ lexer @@ } location /x {¶ @@ üst bloğu kapatma girişimi (dosya düzeyi })
2 @@ lexer @@ return 200 "abc; @@ açık tırnak
2 @@ lexer @@ return 200 'abc; @@ açık tek tırnak
2 @@ lexer @@ return 403 @@ ';' eksik
2 @@ lexer @@ return 200 "a"b; @@ kapanan tırnaktan sonra bitişik karakter
2 @@ lexer @@ ;; @@ boş ifade
2 @@ lexer @@ { @@ ifadesiz {
2 @@ lexer @@ location /x { return 403; @@ tek satır açık blok
1 @@ kesin-ret @@ location /x { fastcgi_pass unix:/x; } @@ tek satır blok içi yasak direktif (QL2-R3)
1 @@ kesin-ret @@ location /x { return 200 ok; proxy_pass http://x; } @@ tek satır blok içi ikinci ifade
1 @@ kesin-ret @@ return 200 "a;b"; proxy_pass http://x; @@ tırnaklı ';' sonrası ifade (QL2-M1)
1 @@ kesin-ret @@ "proxy_pass" http://x; @@ tırnaklı direktif adı (QL2-R3)
1 @@ kesin-ret @@ return 200 a"; proxy_pass http://x; @@ sözcük ortasındaki " tırnak AÇMAZ (QL2-M1)
1 @@ kesin-ret @@ return 200 \"; proxy_pass http://x; @@ kaçışlı " düz karakter
CASES

# D2: dosya sistemi uçları
_rc_of() { _ngxallow_scan "$@" >/dev/null 2>&1; echo $?; }
printf 'return 403;\n' > "${TMP}/ok.conf"
assert_eq "$(_rc_of "${TMP}/ok.conf" example.com 10-site.conf)" "0" "temiz dosya rc 0"
assert_eq "$(_rc_of "${TMP}/yok.conf" example.com)" "2" "olmayan dosya rc 2 (fail-closed)"
assert_eq "$(_rc_of "" example.com)" "2" "boş dosya yolu rc 2"
assert_eq "$(_rc_of "${TMP}/ok.conf" "")" "2" "boş domain rc 2"
assert_eq "$(_rc_of "${TMP}/ok.conf" "../evil")" "2" "geçersiz domain rc 2"
assert_eq "$(_rc_of "${TMP}/ok.conf" "a b")" "2" "boşluklu domain rc 2"
assert_eq "$(_rc_of)" "2" "argümansız çağrı rc 2"
ln -s "${TMP}/ok.conf" "${TMP}/link.conf"
assert_eq "$(_rc_of "${TMP}/link.conf" example.com)" "2" "sembolik bağ rc 2"
_o=$(_ngxallow_scan "${TMP}/link.conf" example.com 2>&1) || true
assert_contains "$_o" ":sembolik-bag:" "sembolik bağ gerekçesi"
mkdir "${TMP}/dir.conf"
assert_eq "$(_rc_of "${TMP}/dir.conf" example.com)" "2" "dizin rc 2"
printf 'return 403;\n\0return 403;\n' > "${TMP}/nul.conf"
assert_eq "$(_rc_of "${TMP}/nul.conf" example.com)" "2" "NUL bayt rc 2"

# D3: boyut tavanı — 32 KiB (32768) kabul, 32769 ret (sınır testi)
_pad() { # $1=toplam bayt: yorum satırlarıyla doldur
    local n="$1" f="$2" line
    line="# $(printf '%0.s-' {1..60})"$'\n'    # 63 bayt
    : > "$f"
    local cnt=$(( n / ${#line} )) i rem
    for ((i = 0; i < cnt; i++)); do printf '%s' "$line"; done >> "$f"
    rem=$(( n - cnt * ${#line} ))
    if (( rem > 0 )); then
        # kalan baytı yorum + LF olarak yaz
        printf '#%*s\n' $((rem - 2)) '' | tr ' ' 'x' >> "$f"
    fi
}
_pad 32768 "${TMP}/cap-ok.conf"
assert_eq "$(wc -c < "${TMP}/cap-ok.conf" | tr -d ' ')" "32768" "(ön koşul) tavan dosyası tam 32768 bayt"
assert_eq "$(_rc_of "${TMP}/cap-ok.conf" example.com)" "0" "32768 bayt (tavan) kabul"
_pad 32769 "${TMP}/cap-big.conf"
assert_eq "$(wc -c < "${TMP}/cap-big.conf" | tr -d ' ')" "32769" "(ön koşul) tavan+1 dosyası 32769 bayt"
assert_eq "$(_rc_of "${TMP}/cap-big.conf" example.com)" "2" "32769 bayt (tavan+1) rc 2"
_o=$(_ngxallow_scan "${TMP}/cap-big.conf" example.com 2>&1) || true
assert_contains "$_o" ":boyut:" "tavan aşımı gerekçe sınıfı boyut"

# D4: rezerve ad uzayı (ad üzerinden)
_scan 'return 403;' 'srvctl-fm-upload.inc'
assert_eq "$_RC" "1" "srvctl- önekli ad rezerve"
assert_contains "$_OUT" ":rezerve-ad:" "rezerve-ad gerekçesi"
_scan 'return 403;' '20-srvctl-fm-upload.conf'
assert_eq "$_RC" "1" "20-…srvctl… rezerve"
_scan 'return 403;' '90-SRVCTL-fm-auth.conf'
assert_eq "$_RC" "1" "büyük harfli srvctl adı rezerve"
_scan 'return 403;' '10-fm.conf'
assert_eq "$_RC" "1" "'fm' içeren ad rezerve"
_scan 'return 403;' 'x-FM-y.conf'
assert_eq "$_RC" "1" "'FM' içeren ad rezerve (büyük harf)"
_scan 'return 403;' '21-fm-download.conf'
assert_eq "$_RC" "1" "21-fm-download.conf adı rezerve"
_scan 'return 403;' '00-custom.conf'
assert_eq "$_RC" "0" "00-custom.conf (iskelet adı) rezerve DEĞİL"
_scan 'return 403;' '10-site.conf'
assert_eq "$_RC" "0" "sıradan ad rezerve değil"
# mantıksal ad verilmezse dosyanın kendi adı
printf 'return 403;\n' > "${TMP}/srvctl-x.conf"
assert_eq "$(_rc_of "${TMP}/srvctl-x.conf" example.com)" "1" "3. argüman yoksa dosyanın kendi adı kullanılır"

# D5: çıktı biçimi satır:direktif:gerekçe ve satır numarası
_scan '¶¶return 200 "/_fm/";¶'
assert_contains "$_OUT" "3:return:yasak-dizgi:" "bulgu satırı satır:direktif:sınıf: biçiminde, doğru satır numarasıyla"
_bad=0
while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    [[ "$l" =~ ^[0-9]+:[^:]+:[a-z-]+:\  ]] || _bad=$((_bad + 1))
done <<< "$_OUT"
assert_eq "$_bad" "0" "bulgu satırlarının hepsi 'satır:direktif:sınıf: gerekçe' biçiminde"
_scan 'return 403;¶'
assert_eq "$_OUT" "" "temiz dosyada stdout boş"

# D1b: kapalı değişken kümesi kilidi — listede olmayan her yerleşik değişken RED
for _v in document_root upstream_addr request_filename binary_remote_addr realpath_root time_local request_body \
          http_x_forwarded_for hostname msec pid server_addr server_port remote_port remote_user request_time status \
          uid_got content_type content_length request_length body_bytes_sent bytes_sent connection https proxy_add_x_forwarded_for \
          http_accept limit_rate nginx_version document_uri fastcgi_script_name; do
    _scan "return 200 \"\$${_v}\";"
    assert_eq "$_RC" "1" "kapalı küme dışı \$${_v} RED"
    case "$_OUT" in *":degisken:"*|*":yasak-dizgi:"*) ;; *) assert_contains "$_OUT" ":degisken:" "\$${_v} gerekçesi" ;; esac
done
# D1c: blok derinliği tavanı — 5 iç içe location kabul, 6 RED (tavan 4 üst-blok)
_nest() { local n="$1" i out="" close=""; for ((i = 1; i <= n; i++)); do out+="location /a${i}/ { "; close+="} "; done; printf '%s%s' "$out" "$close"; }
_scan "$(_nest 5)"
assert_eq "$_RC" "0" "5 iç içe location kabul (derinlik tavanı içinde)"
_scan "$(_nest 6)"
assert_eq "$_RC" "1" "6 iç içe location RED (derinlik tavanı)"
assert_contains "$_OUT" ":baglam:" "derinlik tavanı gerekçesi baglam"
# D1d: regex uzunluk sınırı — 200 karakter KABUL, 201 RED
_rx200="^/$(printf 'a%.0s' {1..197})$"; _rx201="^/$(printf 'a%.0s' {1..198})$"
assert_eq "${#_rx200}" "200" "(ön koşul) 200 karakterlik desen"
_scan "location ~ \"${_rx200}\" { return 403; }"
assert_eq "$_RC" "0" "200 karakterlik regex KABUL"
_scan "location ~ \"${_rx201}\" { return 403; }"
assert_eq "$_RC" "1" "201 karakterlik regex RED"
assert_contains "$_OUT" ":regex:" "regex uzunluk gerekçesi"

# D6: durum sızıntısı yok — önceki dosyanın set tanımı sonrakine taşınmaz (AYNI kabukta: komut ikamesi alt kabuk olur)
printf 'set $u_leak 1;' > "$F"
_RC=0; _ngxallow_scan "$F" example.com 10-site.conf > "${TMP}/d6a.out" 2>&1 || _RC=$?
assert_eq "$_RC" "0" "(ön koşul) set tanımı kabul"
printf 'add_header X-A $u_leak;' > "$F"
_RC=0; _ngxallow_scan "$F" example.com 10-site.conf > "${TMP}/d6b.out" 2>&1 || _RC=$?
assert_eq "$_RC" "1" "önceki taramanın set tanımı sonraki taramaya SIZMAZ (DEFINED sıfırlanır)"
printf 'location ~ "^/(?<u_cap>[0-9]+)$" { return 403; }' > "$F"
_RC=0; _ngxallow_scan "$F" example.com 10-site.conf > "${TMP}/d6c.out" 2>&1 || _RC=$?
assert_eq "$_RC" "0" "(ön koşul) adlı yakalama kabul"
printf 'set $u_cap 1;\nadd_header X-A $u_cap;' > "$F"
_RC=0; _ngxallow_scan "$F" example.com 10-site.conf > "${TMP}/d6d.out" 2>&1 || _RC=$?
assert_eq "$_RC" "0" "önceki taramanın BULAŞIK işareti sonrakine sızmaz (TAINT sıfırlanır; set ile yeniden tanımlı değişken temiz)"

# D7: set -e / pipefail altında güvenli
_se=$(bash -c '
    set -euo pipefail
    source "'"${REPO_ROOT}"'/lib/core.sh"; SRVCTL_ROOT="'"${REPO_ROOT}"'"
    source "'"${REPO_ROOT}"'/lib/domconf.sh"; source "'"${SRVCTL_NGXALLOW_LIB:-${REPO_ROOT}/lib/nginx_allow.sh}"'"
    printf "return 403;\nif (\$arg_x) { return 403; }\nlocation /a { if (\$arg_x) { set \$u_a 1; } limit_except GET { deny all; } }\n" > "'"${TMP}"'/se1.conf"
    printf "proxy_pass http://x;\nlocation ~ \"(a+)+\" { }\n" > "'"${TMP}"'/se2.conf"
    rc=0; _ngxallow_scan "'"${TMP}"'/se1.conf" example.com 10-site.conf >/dev/null || rc=$?
    echo "clean=$rc"
    rc=0; _ngxallow_scan "'"${TMP}"'/se2.conf" example.com 10-site.conf >/dev/null || rc=$?
    echo "bad=$rc"
    echo "ULASTI"
' 2>&1)
assert_contains "$_se" "clean=0" "set -euo pipefail: temiz dosya rc 0, kabuk ölmez"
assert_contains "$_se" "bad=1" "set -euo pipefail: ihlal rc 1, kabuk ölmez"
assert_contains "$_se" "ULASTI" "set -euo pipefail: tarama sonrası kod çalışır"

echo "── E: PoC korpusu (QL1-QL3 + SEC/devops tasarım) ──"
_n=0
for f in "${REPO_ROOT}"/tests/fuzz/seeds/poc/*.conf; do
    [[ -f "$f" ]] || continue
    _n=$((_n + 1))
    _RC=0; _ngxallow_scan "$f" example.com 10-site.conf >/dev/null 2>&1 || _RC=$?
    if [[ "$_RC" == "0" ]]; then
        assert_eq "$_RC" "!=0" "PoC RED edilmeli: ${f##*/}"
    else
        assert_eq "reddedildi" "reddedildi" "PoC RED: ${f##*/} (rc=${_RC})"
    fi
done
assert_eq "$(( _n >= 30 ? 1 : 0 ))" "1" "PoC korpusu boş değil (>=30 dosya; bulunan: ${_n})"
_n=0
for f in "${REPO_ROOT}"/tests/fuzz/seeds/ok/*.conf; do
    [[ -f "$f" ]] || continue
    _n=$((_n + 1))
    _RC=0; _ngxallow_scan "$f" example.com 10-site.conf >/dev/null 2>&1 || _RC=$?
    assert_eq "$_RC" "0" "izinli yapı KABUL: ${f##*/}"
done
assert_eq "$(( _n >= 2 ? 1 : 0 ))" "1" "izinli korpus boş değil (bulunan: ${_n})"

echo "── F: fuzz regresyonları (kabul∧güvensiz bulguları) ──"
_n=0
for f in "${REPO_ROOT}"/tests/fuzz/regress/*.conf; do
    [[ -f "$f" ]] || continue
    _n=$((_n + 1))
    _RC=0; _ngxallow_scan "$f" example.com 10-site.conf >/dev/null 2>&1 || _RC=$?
    if [[ "$_RC" == "0" ]]; then
        assert_eq "$_RC" "!=0" "fuzz regresyonu RED edilmeli: ${f##*/}"
    else
        assert_eq "reddedildi" "reddedildi" "fuzz regresyonu RED: ${f##*/}"
    fi
done
echo "  (fuzz regresyon dosyası: ${_n})"

# _why <metin> <rc> <iğne|""> <açıklama>: rc VE gerekçe iletisinin TAM alt dizgisi (sınıf yetmez:
# aynı sınıfta başka bir kural da reddedebilir — QL4-M9 dersi)
_why() {
    _scan "$1"
    assert_eq "$_RC" "$2" "${4} [rc] :: $(printf '%s' "$_OUT" | head -1)"
    if [[ -n "$3" ]]; then assert_contains "$_OUT" "$3" "${4} [ileti]"; fi
}

echo "── G1: regex sınırsız nicelik tavanı 3 (QL4-M9/qa2-Q15): 3 KABUL, 4 RED — her sayma yolu ayrı ──"
_UNB='regex: 4+ sınırsız nicelik (ReDoS sezgisi)'
_why 'location ~ "^/(a+)(b+)(c+)x$" { return 403; }'     0 ""      "3 sınırsız nicelik (+) KABUL (sınır)"
_why 'location ~ "^/(a+)(b+)(c+)(d+)x$" { return 403; }' 1 "$_UNB" "4 sınırsız nicelik (+) RED (qa2-Q15 vakası)"
_why 'location ~ "^/a*b*c*x$" { return 403; }'           0 ""      "3 sınırsız nicelik (*) KABUL"
_why 'location ~ "^/a*b*c*d*x$" { return 403; }'         1 "$_UNB" "4 sınırsız nicelik (*) RED"
_why 'location ~ "^/a+b+c+d{2,}x$" { return 403; }'      1 "$_UNB" "açık uçlu {n,} sınırsız sayılır (4.)"
_why 'location ~ "^/a+b+c+d{2,5}x$" { return 403; }'     0 ""      "sınırlı {n,m} sınırsız SAYILMAZ"
# Grup niceliği )+ / )* İKİ kez sayılır (kapanışta VE ardından gelen '+'/'*' karakterinde) — belgelenen
# "en çok 3"ten KATI yönde sapma (fazla red); gevşetilmedi, davranış olduğu gibi kilitli.
_why 'location ~ "^/(ab)+c+x$" { return 403; }'          0 ""      "grup niceliği )+ (2 sayılır) + c+ = 3 KABUL"
_why 'location ~ "^/(ab)+c+d+x$" { return 403; }'        1 "$_UNB" "grup niceliği )+ (2) + c+ d+ = 4 RED (kapanıştaki sayım kilitli)"
_why 'location ~ "^/(ab)*c+d+x$" { return 403; }'        1 "$_UNB" "grup niceliği )* (2) + c+ d+ = 4 RED"
_why 'location ~ "^/(ab){2,}c+d+x$" { return 403; }'     0 ""      "grup niceliği ){n,} bir sayılır: toplam 3 KABUL"
_why 'location ~ "^/(ab){2,}c+d+e+x$" { return 403; }'   1 "$_UNB" "grup niceliği ){n,} ile toplam 4 RED"
_why 'location ~ "^/(ab){2}c+d+e+x$" { return 403; }'    0 ""      "grup niceliği ){n} sınırlı: toplam 3 KABUL"

echo "── G2: {n,m} sınırı 255 ve n<=m (GNU grep {0,m} açılımı karesel: tek {1,32767} sondası 26,8 s) ──"
_DUP='regex: nicelik sınırı en çok 255'
_why 'location ~ "^/x[0-9]{255}$" { return 403; }'      0 ""      "{255} KABUL (sınır)"
_why 'location ~ "^/x[0-9]{256}$" { return 403; }'      1 "$_DUP" "{256} RED"
_why 'location ~ "^/x[0-9]{1,255}$" { return 403; }'    0 ""      "{1,255} KABUL (sınır)"
_why 'location ~ "^/x[0-9]{1,256}$" { return 403; }'    1 "$_DUP" "{1,256} RED (üst değer)"
_why 'location ~ "^/x[0-9]{256,}$" { return 403; }'     1 "$_DUP" "{256,} RED (alt değer, açık uçlu)"
_why 'location ~ "^/x[0-9]{1,32767}$" { return 403; }'  1 "$_DUP" "{1,32767} RED"
_why 'location ~ "^/x[0-9]{00255}$" { return 403; }'    0 ""      "baştaki sıfırlar ondalık okunur ({00255} = 255)"
_why 'location ~ "^/x[0-9]{5,2}$" { return 403; }'      1 'regex: {n,m} niceliğinde n > m' "{5,2} RED (n > m)"
_why 'location ~ "^/x[0-9]{2,2}$" { return 403; }'      0 ""      "{2,2} KABUL (n = m)"
# sonda ERE'si X{n,m} → X{min(n,8),}: üst küme — sınırlı nicelikle FM yoluna eşleşen desen hâlâ RED
_why 'location ~ "^/.{1,2}m/up/" { return 403; }'       1 'regex: srvctl FM yoluna' ".{1,2}m/up/ FM eşleşmesi RED"
_why 'location ~ "^/[^a]{3}/" { return 403; }'          1 'regex: srvctl FM yoluna' "[^a]{3}/ ile /_fm/ eşleşmesi RED"
_why 'location ~ "^/[^a]{0,2}fm" { return 403; }'       1 'regex: srvctl FM yoluna' "[^a]{0,2}fm FM eşleşmesi RED"
# beyaz kutu: kuyruğa yazılan sonda ERE'si tam olarak üst-küme biçimi (her platformda belirlenimci kilit)
_ere=$( _NGXALLOW_DEFER=1; _NGXALLOW_PQ_ERE=(); _NGXALLOW_PQ_LINE=(); _NGXALLOW_PQ_DIR=()
        _ngxallow_regex_ok '^/x[0-9]{1,255}[a-z]{9,20}(ab){3}c{0}d{12,}y$' >/dev/null 2>&1; echo "rc=$? ${_NGXALLOW_PQ_ERE[0]-YOK}" )
assert_eq "$_ere" 'rc=0 ^/x[0-9]{1,}[a-z]{8,}(ab){3,}c{0,}d{8,}y$' "sonda ERE'si: {1,255}→{1,} {9,20}→{8,} {3}→{3,} {0}→{0,} {12,}→{8,}"

echo "── G3: dosya başına ifade tavanı 2048 (seca-L1; _NGXALLOW_NSTMT kıyaslanır; blok başlığı da sayılır) ──"
_rep() { local n="$1" s="$2" i out=""; for ((i = 0; i < n; i++)); do out+="$s"; done; printf '%s%s' "$out" "${3-}" > "$F"; }
_scan_f() { _RC=0; _OUT=$(_ngxallow_scan "$F" example.com 10-site.conf 2>&1) || _RC=$?; }
_STMT='boyut: dosya başına ifade tavanı (2048) aşıldı'
_rep 2048 $'return 403;\n'; _scan_f
assert_eq "$_RC" "0" "2048 ifade (tavan) KABUL"
_rep 2049 $'return 403;\n'; _scan_f
assert_eq "$_RC" "2" "2049 ifade RED rc 2 (boyut tavanı = doğrulanamadı, fail-closed)"
assert_contains "$_OUT" "2049:return:${_STMT}" "tavan bulgusu 2049. ifadenin satırında, TAM ileti"
assert_eq "$(printf '%s' "$_OUT" | grep -c 'ifade tavanı')" "1" "tavan bulgusu TEK kez yazılır"
_rep 1024 $'location /a { return 403; }\n'; _scan_f
assert_eq "$_RC" "0" "1024 location bloğu (1024 başlık + 1024 ifade = 2048) KABUL"
_rep 1024 $'location /a { return 403; }\n' $'return 403;\n'; _scan_f
assert_eq "$_RC" "2" "blok başlıkları da sayılır: 2049. giriş RED"
_rep 2049 $'return 403;\n' $'proxy_pass http://x;\n'; _scan_f
assert_eq "$_RC" "2" "tavan sonrası yasak direktif: dosya yine RED (kalan denetlenmeden)"

echo "── G4: FM yolu sondası TARAMA BAŞINA TOPLU (seca-L1): grep çağrı sayısı (taklit grep sayar) ──"
_REAL_GREP="$(command -v grep)"
SHIM="${TMP}/shim"; mkdir -p "$SHIM"; GREP_LOG="${TMP}/grep.log"; : > "$GREP_LOG"
cat > "${SHIM}/grep" <<SHIMEOF
#!/bin/bash
echo "\$*" >> "${GREP_LOG}"
case " \$* " in *" -q "*) if [[ -n "\${FAKE_BATCH_RC:-}" ]]; then exit "\${FAKE_BATCH_RC}"; fi ;; esac
exec "${_REAL_GREP}" "\$@"
SHIMEOF
chmod +x "${SHIM}/grep"
_scan_n() { # dosya $F; → _RC _OUT _NG (grep çağrısı)
    : > "$GREP_LOG"; _RC=0
    _OUT=$( PATH="${SHIM}:${PATH}"; hash -r; _ngxallow_scan "$F" example.com 10-site.conf 2>&1 ) || _RC=$?
    _NG=$(wc -l < "$GREP_LOG" | tr -d ' ')
}
_gen() { # $1=adet $2=biçim (printf, %d = sıra) → $F
    local i out=""
    for ((i = 1; i <= $1; i++)); do out+="$(printf "$2" "$i")"$'\n'; done
    printf '%s' "$out" > "$F"
}
printf 'return 403;\n' > "$F"; _scan_n
assert_eq "${_RC}/${_NG}" "0/0" "regex yok: grep hiç çağrılmaz"
_gen 1500 'rewrite ^/r%d$ /b;'; _scan_n
assert_eq "${_RC}/${_NG}" "0/1" "1500 farklı TEMİZ regex: TEK grep (eskiden 1500)"
_gen 1500 'rewrite . /a;'; _scan_n
assert_eq "${_RC}/${_NG}" "1/2" "1500 aynı FM'e eşleşen regex: toplu + tek tanımlama (aynı ERE bir kez)"
assert_eq "$(printf '%s' "$_OUT" | grep -c ':rewrite:regex: srvctl FM yoluna')" "1500" "…ve 1500 satırın HER biri bulgu"
_gen 20 'rewrite /|a%d /b;'; _scan_n
assert_eq "${_RC}/$(printf '%s' "$_OUT" | grep -c 'regex: srvctl FM yoluna')/$(printf '%s' "$_OUT" | grep -c 'bütçesi')" "1/20/0" "20 farklı FM'e eşleşen regex: hepsi tek tek bulunur, bütçe yetiyor"
assert_eq "$(( _NG <= 1 + 64 ? 1 : 0 ))" "1" "…grep çağrısı toplu + en çok 64 (${_NG})"
_gen 300 'rewrite /|a%d /b;'; _scan_n
_nid=$(printf '%s' "$_OUT" | grep -c 'regex: srvctl FM yoluna')
_nun=$(printf '%s' "$_OUT" | sed -n 's/.*bitti — \([0-9]*\) ayrı desen tek tek sınanmadı.*/\1/p')
assert_eq "${_RC}/${_NG}" "1/65" "300 farklı FM'e eşleşen regex: toplu + 64 grep bütçesi (tavan)"
assert_eq "$(( _nid > 0 && _nun > 0 && _nid + _nun == 300 ? 1 : 0 ))" "1" "…bulunan (${_nid}) + sınanmayan (${_nun}) = 300; kalanlar için TEK toplu bulgu"
assert_eq "$(printf '%s' "$_OUT" | grep -c 'ayrıştırma bütçesi (64 grep) bitti')" "1" "…toplu bütçe bulgusu tek ve TAM iletiyle"
# kötü desen önündeki temiz desenlerden BAĞIMSIZ bulunur (ikiye bölme): 50 temiz + 1 kötü + 30 temiz
_mx=""; for ((_i = 1; _i <= 50; _i++)); do _mx+="rewrite ^/r${_i}\$ /b;"$'\n'; done
_mx+='location ~ "^/.fm/" { return 403; }'$'\n'
for ((_i = 1; _i <= 30; _i++)); do _mx+="rewrite ^/s${_i}\$ /b;"$'\n'; done
printf '%s' "$_mx" > "$F"; _scan_n
assert_eq "$_RC" "1" "81 regexten biri FM'e eşleşir: RED"
assert_contains "$_OUT" "51:location:regex: srvctl FM yoluna" "…bulgu DOĞRU satır/direktifte (önündeki 50 temiz desen bütçeyi tüketmez)"
assert_eq "$(printf '%s' "$_OUT" | grep -c .)" "1" "…yalnız o desen raporlanır (toplu bulgu YOK)"
assert_eq "$(( _NG <= 1 + 2 * 7 + 1 ? 1 : 0 ))" "1" "…ikiye bölme: grep <= 1 + 2·log2(81) + 1 (${_NG})"
# derlenemeyen desen (geçersiz aralık [z-a]: BSD ve GNU grep ikisi de rc 2) ikiye bölmede KENDİ iletisiyle bulunur
_mx=""; for ((_i = 1; _i <= 20; _i++)); do _mx+="rewrite ^/r${_i}\$ /b;"$'\n'; done
_mx+='location ~ "^/x[z-a]$" { return 403; }'$'\n'
printf '%s' "$_mx" > "$F"; _scan_n
assert_eq "$_RC" "1" "derlenemeyen desen (20 temizin ardında): RED"
assert_contains "$_OUT" "21:location:regex: doğrulayıcı ERE'ye çeviremedi (fail-closed)" "…KENDİ iletisiyle ve DOĞRU satırda (tutarsızlık kolu DEĞİL)"
assert_not_contains "$_OUT" "tek tek sondayla doğrulanamadı" "…tutarsızlık iletisi YOK"
_rd=0; _ngxallow_regex_ok '^/x[z-a]$' || _rd=$?
assert_eq "${_rd}" "1" "doğrudan _ngxallow_regex_ok: derlenemeyen desen rc 1"
assert_contains "$_NGXALLOW_WHY" "regex: doğrulayıcı ERE'ye çeviremedi" "…gerekçe"
# tutarsızlık kolu: toplu sonda eşleşme/hata bildirir, tek tek sonda bulamazsa da RED
_gen 3 'rewrite ^/r%d$ /b;'
for _fb in 0 2; do
    : > "$GREP_LOG"; _RC=0
    _OUT=$( PATH="${SHIM}:${PATH}"; hash -r; FAKE_BATCH_RC=$_fb _ngxallow_scan "$F" example.com 10-site.conf 2>&1 ) || _RC=$?
    assert_eq "$_RC" "1" "toplu sonda rc ${_fb} ama tek tek temiz → RED (fail-closed)"
    assert_contains "$_OUT" "regex: toplu FM yolu sondası (rc ${_fb}) tek tek sondayla doğrulanamadı" "…tutarsızlık iletisi (rc ${_fb})"
done
# kuyruk taramalar arasında sızmaz (AYNI kabukta tarama: komut ikamesi alt kabuk olurdu); doğrudan
# çağrı (kuyruksuz) sondayı kendisi yapar
printf 'location ~ "^/r1$" { return 403; }\nlocation ~ "^/.fm/" { return 403; }\n' > "$F"
_RC=0; _ngxallow_scan "$F" example.com 10-site.conf > "${TMP}/g4.out" 2>&1 || _RC=$?
assert_eq "$_RC" "1" "(ön koşul) aynı kabukta tarama: FM eşleşmesi RED"
assert_eq "$(declare -p _NGXALLOW_PQ_ERE >/dev/null 2>&1 && echo sizdi || echo yok)$( [[ "${_NGXALLOW_DEFER:-0}" == 1 ]] && echo sizdi || echo yok )" "yokyok" "tarama sonrası kuyruk/erteleme bayrağı çağırana sızmaz"
_rd=0; _ngxallow_regex_ok '^/.fm/' || _rd=$?
assert_eq "${_rd}" "1" "doğrudan _ngxallow_regex_ok: FM eşleşmesi rc 1 (sonda yerinde)"
assert_contains "$_NGXALLOW_WHY" "regex: srvctl FM yoluna" "…gerekçe"

echo "── G5: tarama süresi doğrusal ve lexer'a yakın (seca-L1: eski 2340 x 'rewrite . /a;' 8,8-10,5 s) ──"
_now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null || printf '%d' "$(( $(date +%s) * 1000 ))"; }
_noop_cb() { :; }
_timed() { # $1=etiket; dosya $F → _LEX _SCN (ms)
    local t0 t1 t2
    t0=$(_now_ms); _domconf_nginx_parse "$F" _noop_cb >/dev/null 2>&1; t1=$(_now_ms)
    _RC=0; _OUT=$(_ngxallow_scan "$F" example.com 10-site.conf 2>&1) || _RC=$?; t2=$(_now_ms)
    _LEX=$((t1 - t0)); _SCN=$((t2 - t1))
    echo "  ($1: lexer ${_LEX} ms, tarama ${_SCN} ms, rc ${_RC})"
}
_gen 2000 'rewrite . /a;'
_timed "2000 x rewrite . /a;"
assert_eq "$(( _SCN <= 2 * _LEX + 1500 ? 1 : 0 ))" "1" "FM'e eşleşen 2000 regex: tarama <= 2 x lexer + 1,5 s (${_SCN} <= $(( 2 * _LEX + 1500 )))"
_gen 1500 'rewrite ^/r%d$ /b;'
_timed "1500 farklı temiz regex"
assert_eq "$(( _SCN <= 2 * _LEX + 1500 ? 1 : 0 ))" "1" "1500 farklı temiz regex: tarama <= 2 x lexer + 1,5 s (${_SCN} <= $(( 2 * _LEX + 1500 )))"
# GNU grep (Ubuntu'nun grep'i) ile ağır nicelik: eski kodda 150 desen 17,7 s, tek {1,32767} 27,8 s
_GNUDIR="${SRVCTL_TEST_GNU_GREP_DIR:-}"
if [[ -z "$_GNUDIR" ]]; then
    # BSD grep de "--version"da "GNU compatible" yazar: yalnız "(GNU grep)" GNU'dur
    if grep --version 2>/dev/null | head -1 | grep -qF '(GNU grep)'; then _GNUDIR="$(dirname "$(command -v grep)")"
    elif [[ -x /opt/homebrew/opt/grep/libexec/gnubin/grep ]]; then _GNUDIR=/opt/homebrew/opt/grep/libexec/gnubin
    fi
fi
if [[ -n "$_GNUDIR" ]]; then
    _q=""; for ((_i = 0; _i < 15; _i++)); do _q+='[a-z]{0,255}'; done
    _gen 150 "location ~ \"^/r%d${_q}y\$\" { return 403; }"
    _t0=$(_now_ms); _domconf_nginx_parse "$F" _noop_cb >/dev/null 2>&1; _t1=$(_now_ms)
    _RC=0; _OUT=$( PATH="${_GNUDIR}:${PATH}"; hash -r; _ngxallow_scan "$F" example.com 10-site.conf 2>&1 ) || _RC=$?; _t2=$(_now_ms)
    _LEX=$((_t1 - _t0)); _SCN=$((_t2 - _t1))
    echo "  (GNU grep ${_GNUDIR}: 150 x 15[a-z]{0,255} lexer ${_LEX} ms, tarama ${_SCN} ms, rc ${_RC})"
    assert_eq "$_RC" "0" "GNU grep: ağır sınırlı nicelikli 150 temiz desen KABUL"
    assert_eq "$(( _SCN <= 2 * _LEX + 1500 ? 1 : 0 ))" "1" "GNU grep: ağır nicelikte tarama <= 2 x lexer + 1,5 s (${_SCN} <= $(( 2 * _LEX + 1500 )))"
else
    echo "  (GNU grep bulunamadı: G5 GNU alt vakası ATLANDI — SRVCTL_TEST_GNU_GREP_DIR ile verilebilir)"
fi

echo "── G6: qa2 LOW kilitleri: Q13 IPv4 sekizli, Q16 if ')' sonu, Q11 argüman tavanı, Q25 \${…}, belirteç 1024 ──"
_why 'allow 255.255.255.255;'   0 ""                     "IPv4 sekizli 255 KABUL (sınır)"
_why 'allow 256.0.0.1;'         1 "arguman: allow yalnız" "IPv4 ilk sekizli 256 RED (qa2-Q13)"
_why 'allow 1.2.3.256;'         1 "arguman: allow yalnız" "IPv4 son sekizli 256 RED"
_why 'allow 10.0.0.0/32;'       0 ""                     "IPv4 /32 KABUL (sınır)"
_why $'if ($arg_xy {\n return 403;\n}' 1 "arguman: if koşulu ')' ile bitmeli" "if koşulu ')' olmadan RED (qa2-Q16: soyma son karakteri yiyip \$arg_x kabul ederdi)"
_a16=""; for ((_i = 1; _i <= 16; _i++)); do _a16+=" a${_i}"; done
_scan "index${_a16};"
assert_eq "$_RC" "1" "16 argümanlı index RED (index en çok 8)"
assert_not_contains "$_OUT" "argüman sayısı tavanı" "16 argüman G0 tavanına TAKILMAZ (tavan 16)"
_scan "index${_a16} a17;"
assert_eq "$_RC" "1" "17 argüman RED"
assert_contains "$_OUT" "arguman: argüman sayısı tavanı (16) aşıldı" "17 argüman: G0 tavanı iletisi (qa2-Q11)"
_why 'add_header X-A "a${host}b";' 1 'degisken: ${…} biçimi yasak' "\${…} biçimi kendi iletisiyle RED (qa2-Q25)"
_t1024=$(printf 'a%.0s' {1..1024}); _t1025="${_t1024}a"
_why "add_header X-A \"${_t1024}\";" 0 "" "1024 baytlık belirteç KABUL (sınır)"
_why "add_header X-A \"${_t1025}\";" 1 "arguman: belirteç uzunluk tavanı (1024)" "1025 baytlık belirteç RED"

test_summary
