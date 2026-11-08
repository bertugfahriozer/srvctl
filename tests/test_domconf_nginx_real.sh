#!/bin/bash
# GERÇEK nginx ile ölçümler (nginx YOKSA bu dosya ATLANIR, kırmızı vermez; ikili:
# $SRVCTL_TEST_NGINX ya da PATH'teki 'nginx'). YALNIZ 127.0.0.1:19450-19499 (geçici prefix; port-boş denetimi);
# dış ağa istek YOK: resolver 127.0.0.1:9 (UDP kapalı → çözüm hemen düşer), ana makineler '*.invalid'.
#
#  1) 90: 'internal' → dışarıdan 404 (mutant '# internal;' → 502)
#  2) 20: '^~' önek öncelik kilidi (vhost regex'leri bu yolda DEVRE DIŞI), biçim kapısı, KAPI 2,
#     limit_except, Content-Length, gövde sınırı, auth_request çağrısı — şablondan render edilen
#     GERÇEK dosya; hedef host *.invalid, sertifika yolu yerel CA paketi (yalnız laboratuvar dönüşümü)
#  3) off: 403 kökü (yük hattı CI4'e DÜŞMEZ)
#  4) 21: /__fm_dl internal + $arg_u deseni (açık proxy negatifleri) — X-Accel-Redirect ile
#  5) lexer ↔ nginx diferansiyel: tarayıcının sözcük çözümlemesi nginx'inkiyle AYNI mı?
# Mutantlar (takım tarafından ÖLDÜRÜLMELİ): '^~'→'~', KAPI 2 kaldır, biçim kapısı kaldır,
# '^~ /_fm/ {403}' kaldır, limit_except kaldır, 411 kapısı kaldır, 33m sınırı kaldır, 'internal' kaldır.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1; then
    echo "── gerçek nginx/curl yok — BU DOSYA ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi> ile çalıştırın) ──"
    test_summary
    exit 0
fi
CA=""
for c in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [[ -f "$c" ]] && { CA="$c"; break; }; done
if [[ -z "$CA" ]]; then echo "── CA paketi yok — ATLANDI ──"; test_summary; exit 0; fi

T="$(mktemp -d)"; mkdir -p "$T/logs" "$T/c" "$T/tmp"
P1=0; P2=0
lab_down() { if [[ -f "$T/n.pid" ]]; then hs_kill_pidfile TERM "$T/n.pid" 'nginx'; sleep 0.3; rm -f "$T/n.pid"; fi; }   # F9b/b: ham kill yok; pid dosyası bayat/yeniden kullanılmışsa REDDEDİLİR (harness_safe.sh)
trap 'lab_down; rm -rf "$T"; _fm_env_cleanup' EXIT   # rev-L9: fm_env temizliği zincirde
lab_port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
# LAB_CI4_404=1: /__fm_auth için vhost'un uygulama (CI4) yoluna düşen alt isteğe GERÇEK CI4 gibi 404 verilir (90 yokken auth_request 500 üretir).
LAB_CI4_404=0
# lab_up <vhost-include satırları...>: backend (P2) + ana sunucu (P1). Dönüş 0 = ayağa kalktı.
lab_up() {
    lab_down
    local tries=0 inc="" f ci4_404=""
    for f in "$@"; do inc+="   include $f;"$'\n'; done
    if [[ "$LAB_CI4_404" == 1 ]]; then ci4_404='   location = /__fm_auth { return 404 "CI4-404"; }'$'\n'; fi
    while (( tries < 8 )); do
        P1=$((19450 + 2 * (RANDOM % 25))); P2=$((P1 + 1))   # yalnız 127.0.0.1:19450-19499
        if ! lab_port_free "$P1" || ! lab_port_free "$P2"; then tries=$((tries + 1)); continue; fi
        [[ -f "$T/c/90.tpl" ]] && sed "s/@P2@/${P2}/" "$T/c/90.tpl" > "$T/c/90.conf"
        cat > "$T/nginx.conf" <<EOT
pid $T/n.pid;
error_log $T/logs/e.log info;
events { worker_connections 32; }
http {
 log_format l "\$request_method \$uri \$status";
 access_log $T/logs/a.log l;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $T/tmp/b; proxy_temp_path $T/tmp/p; fastcgi_temp_path $T/tmp/f; uwsgi_temp_path $T/tmp/u; scgi_temp_path $T/tmp/s;
 server { listen 127.0.0.1:$P2;
   access_log $T/logs/backend.log l;
   location = /auth     { add_header X-Fm-Auth "Bearer tok123"; return 204; }
   location = /auth-bad { add_header X-Fm-Auth "Basic abc"; return 204; }
   location = /auth-none { return 204; }
   location = /auth-sp  { add_header X-Fm-Auth "Bearer a b"; return 204; }
   location = /auth-deny { return 403; }
   location = /auth-404 { return 404; }
   location = /auth-500 { return 500; }
   location = /auth-302 { return 302 /login; }
   location = /redir    { add_header X-Accel-Redirect \$http_x_r; return 200 "backend"; }
 }
 server { listen 127.0.0.1:$P1; server_name x;
   location ~ \.php\$ { return 200 "PHP"; }
   location ~* \.(css|js|jpg)\$ { return 200 "STATIC"; }
   location /dl { proxy_pass http://127.0.0.1:$P2/redir; }
$ci4_404   location / { return 200 "CI4"; }
$inc }
}
EOT
        : > "$T/logs/a.log"; : > "$T/logs/backend.log"; : > "$T/logs/e.log"
        if "$NG" -t -c "$T/nginx.conf" -p "$T" >"$T/t.out" 2>&1 && "$NG" -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1; then
            sleep 0.4
            if curl -sS -q --noproxy '*' -o /dev/null --max-time 3 "http://127.0.0.1:${P1}/" 2>/dev/null; then return 0; fi
        fi
        lab_down
        tries=$((tries + 1))
    done
    sed 's/^/    [lab] /' "$T/t.out" >&2
    return 1
}
# istek: req <yöntem> <yol> [ek curl argümanları] → "HTTP-kodu|gövde"
req() {
    local m="$1" p="$2"; shift 2
    curl -sS -q --noproxy '*' --max-time 8 -X "$m" -o "$T/body" -w '%{http_code}' "$@" "http://127.0.0.1:${P1}${p}" 2>/dev/null
    printf '|%s' "$(head -c 40 "$T/body" 2>/dev/null)"
}
code() { local r; r=$(req "$@"); printf '%s' "${r%%|*}"; }
put() { local p="$1"; shift; code PUT "$p" -H 'Content-Length: 3' --data-binary abc "$@"; }
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

# ── şablonlardan render + YALNIZ laboratuvar dönüşümleri ──────────────────────
lab_fix() { # stdin → stdout: ana makine *.invalid, CA yolu yerel, günlük yolu geçici
    sed -e "s#eapi\.pcloud\.com#x.invalid#g" -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${T}/logs/#g"
}
render_all() { # $1=auth-url-yolu ('/auth' ...) → c/20.conf c/21.conf c/90.conf
    _domconf_fm_render_upload eu "$MODSEC" example_com | lab_fix > "$T/c/20.conf"
    _domconf_fm_render_download example_com | lab_fix > "$T/c/21.conf"
    cat > "$T/c/90.tpl" <<EOT
location = /__fm_auth {
    internal;
    client_max_body_size 33m;
    proxy_pass http://127.0.0.1:@P2@$1;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}
EOT
}
# 90'ın GERÇEK ÜRETİMİ de aynı laboratuvarda: yalnız fastcgi_pass soketi olmadığı için 502
# ModSecurity modülü bu nginx'te yoksa (yerel/CI sık durum) 'modsecurity off;' satırı nginx -t'yi düşürür:
# BU gerçek mesaj, _domconf_fm_apply_detect'in beklediği biçimdir (aşağıda sınanır). Modül yoksa
# laboratuvar dosyaları satırsız (modsec=0) render edilir.
MODSEC=1
"$NG" -V 2>&1 | grep -qi 'modsecurity' || MODSEC=0
_domconf_fm_render_auth example_com 8.3 "$SCRIPT" "$MODSEC" > "$T/c/90real.conf"

echo "── 0: ModSecurity modülü tespiti — gerçek nginx -t mesajı biçimi ──"
printf 'events { worker_connections 4; }\nhttp { server { listen 127.0.0.1:19499; include %s; } }\n' "$T/c/modsec.conf" > "$T/nginx-m.conf"
_domconf_fm_render_auth example_com 8.3 "$SCRIPT" 1 > "$T/c/modsec.conf"
mo=$("$NG" -t -c "$T/nginx-m.conf" -p "$T" 2>&1)
if [[ "$mo" == *'unknown directive "modsecurity"'* ]]; then
    assert_contains "$mo" "unknown directive \"modsecurity\" in $T/c/modsec.conf:" "modül yokken nginx -t mesajı '_domconf_fm_apply_detect' kalıbına uyar (… in <dosya>:<satır>)"
    case "$mo" in *'unknown directive "modsecurity" in '"$T/c/"*) r=eslesti ;; *) r=eslesmedi ;; esac
    assert_eq "$r" "eslesti" "apply_detect'in glob kalıbı ('unknown directive \"modsecurity\" in <dizin>/') gerçek mesajla eşleşir"
else
    assert_contains "$mo" "test is successful" "modül varsa modsecurity off kabul edilir"
fi

echo "── 1: 90 'internal' → dışarıdan 404; mutant 502 ──"
for variant in orig mut; do
    lab_down
    if [[ "$variant" == orig ]]; then cp "$T/c/90real.conf" "$T/c/90x.conf"; else sed 's/^    internal;/    # internal;/' "$T/c/90real.conf" > "$T/c/90x.conf"; fi
    lab_up "$T/c/90x.conf"; up=$?
    assert_eq "$up" "0" "lab ayağa kalktı (${variant})"
    if [[ "$variant" == orig ]]; then
        out=$("$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1); assert_contains "$out" "test is successful" "gerçek nginx srvctl'in ürettiği 90'ı kabul eder"
        assert_eq "$(code GET /__fm_auth)" "404" "dışarıdan GET /__fm_auth → 404 (internal)"
    else
        assert_eq "$(code GET /__fm_auth)" "502" "MUTANT '# internal;' → 502 (404 DEĞİL: internal'ı gerçekten nginx uyguluyor)"
    fi
done
lab_down

echo "── 2: 20 — '^~' önek önceliği, biçim kapısı, KAPI 2, limit_except, 411, gövde sınırı ──"
run_matrix() { # stdout: "anahtar=kod" satırları
    printf 'ok=%s\n' "$(put /_fm/up/12/34)"
    printf 'trailing_slash=%s\n' "$(put /_fm/up/12/34/)"
    printf 'php_ext=%s\n' "$(put /_fm/up/12/34.php)"
    printf 'css_ext=%s\n' "$(put /_fm/up/12/34.css)"
    printf 'pct_digit=%s\n' "$(put /_fm/up/%31/34)"
    printf 'query=%s\n' "$(put '/_fm/up/12/34?x=1')"
    printf 'dslash=%s\n' "$(put /_fm/up//12/34)"
    printf 'dotdot=%s\n' "$(put /_fm/up/12/../34)"
    printf 'letters=%s\n' "$(put /_fm/up/a/b)"
    printf 'bare_up=%s\n' "$(put /_fm/up/)"
    printf 'other_fm=%s\n' "$(put /_fm/x)"
    printf 'fm_slash=%s\n' "$(put /_fm/)"
    printf 'long_id=%s\n' "$(put /_fm/up/123456789012345678901/1)"
    printf 'crlf=%s\n' "$(put '/_fm/up/12/34%0d%0ax')"
    printf 'sub_php=%s\n' "$(put /_fm/up/12/34/x.php)"
    printf 'get=%s\n' "$(code GET /_fm/up/12/34)"
    printf 'post=%s\n' "$(code POST /_fm/up/12/34 -H 'Content-Length: 3' --data-binary abc)"
    printf 'vhost_php=%s\n' "$(put /x.php)"
}
kv() { grep "^$2=" <<< "$1" | cut -d= -f2; }
render_all /auth
cp "$T/c/20.conf" "$T/c/20orig.conf"
lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"; assert_eq "$?" "0" "lab (20+21+90) ayağa kalktı"
out=$("$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1); assert_contains "$out" "test is successful" "gerçek nginx srvctl'in ürettiği 20/21 dosyalarını kabul eder"
M=$(run_matrix)
assert_eq "$(kv "$M" ok)" "502" "geçerli yol: auth geçti, proxy'ye ulaştı (çözümsüz *.invalid → 502)"
for k in trailing_slash php_ext css_ext pct_digit query dslash dotdot letters bare_up other_fm fm_slash long_id crlf sub_php get post; do
    assert_eq "$(kv "$M" $k)" "403" "403: ${k}"
done
assert_eq "$(kv "$M" vhost_php)" "200" "kontrol: /x.php vhost PHP regex'ine gider (lab doğru kurulu)"
assert_eq "$(code GET /_fm)" "403" "'/_fm' (eğik çizgisiz) tam eşleşmeyle 403 (CI4 catch-all'a DÜŞMEZ)"
assert_eq "$(code GET '/_fm?x=1')" "403" "'/_fm?x=1' → 403"
assert_eq "$(code PUT /_fm -H 'Content-Length: 3' --data-binary abc)" "403" "PUT '/_fm' → 403"
assert_eq "$(code GET /_fmx)" "200" "'/_fmx' ETKİLENMEZ (önek '^~ /_fm' DEĞİL, tam eşleşme) → vhost"
assert_eq "$(code GET /_fm_rapor)" "200" "'/_fm_rapor' ETKİLENMEZ → vhost"
assert_eq "$(code GET /_fm.php)" "200" "'/_fm.php' ETKİLENMEZ → vhost PHP regex'i (FM yolu değil)"
# 411: Content-Length yok (chunked)
assert_eq "$(code PUT /_fm/up/12/34 -H 'Transfer-Encoding: chunked' --data-binary abc)" "411" "Content-Length yok (chunked) → 411"
# gövde sınırı: 2 MiB geçer (33m), 34 MiB → 413
dd if=/dev/zero of="$T/b2m" bs=1048576 count=2 2>/dev/null; dd if=/dev/zero of="$T/b34m" bs=1048576 count=34 2>/dev/null
assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b2m")" "502" "2 MiB gövde (sınır 33m) → geçer (502: proxy)"
assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b34m")" "413" "34 MiB gövde → 413 (33m sınırı)"
# auth alt isteği GERÇEKTEN çağrılıyor
: > "$T/logs/backend.log"; put /_fm/up/12/34 >/dev/null
assert_contains "$(cat "$T/logs/backend.log")" "GET /auth 204" "auth_request auth ucunu çağırdı"
: > "$T/logs/backend.log"; put '/_fm/up/12/34?x' >/dev/null
assert_eq "$(wc -l < "$T/logs/backend.log" | tr -d ' ')" "0" "biçim kapısından dönen istek auth ucuna HİÇ ulaşmaz"
# KAPI 2: auth ucu 2xx ama başlık yok/biçimsiz → 403 (pCloud'a gitmez)
for au in auth-none auth-bad auth-sp; do
    render_all "/${au}"; lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
    assert_eq "$(put /_fm/up/12/34)" "403" "KAPI 2: ${au} → 403"
done
render_all /auth-deny; lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(put /_fm/up/12/34)" "403" "auth ucu 403 → 403"
# fm-auth (90) HİÇ yokken (elle silinmiş): alt istek CI4'e düşse bile KAPI 2 → 403
lab_up "$T/c/20.conf" "$T/c/21.conf"
assert_eq "$(put /_fm/up/12/34)" "403" "90 YOK: alt istek CI4'e düşer (2xx, başlıksız) → KAPI 2 → 403"
# GERÇEK CI4 davranışı: 90 yokken alt istek uygulamaya düşer ve 404 alır → auth_request bunu 500'e çevirir → error_page → 403
# (ARCHITECTURE §15/8 fail-closed: her gövde boyutunda 403, pCloud'a istek 0).
LAB_CI4_404=1
lab_up "$T/c/20.conf" "$T/c/21.conf"; assert_eq "$?" "0" "lab (90 YOK, alt istek CI4'e 404) ayağa kalktı"
: > "$T/logs/e.log"
assert_eq "$(put /_fm/up/12/34)" "403" "90 YOK + alt istek 404 (gerçek CI4): küçük gövde (3 B) → 403 (500 DEĞİL)"
assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b2m")" "403" "90 YOK + alt istek 404: 2 MiB gövde → 403"
dd if=/dev/zero of="$T/b32m" bs=1048576 count=32 2>/dev/null
assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b32m")" "403" "90 YOK + alt istek 404: 32 MiB gövde (gerçek parça boyu, sınır içi) → 403"
assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b34m")" "413" "90 YOK + alt istek 404: 34 MiB gövde (33m sınırı üstü) → 413 (sınır denetimi auth'tan ÖNCE; yine ret, pCloud'a istek 0)"
assert_eq "$(code PUT /_fm/up/12/34 -H 'Transfer-Encoding: chunked' --data-binary abc)" "411" "90 YOK + alt istek 404: Content-Length'siz istek yine 411 (rewrite aşaması auth'tan önce)"
assert_eq "$(code GET /_fm/up/12/34)" "403" "90 YOK + alt istek 404: GET → 403"
assert_eq "$(grep -c 'x.invalid' "$T/logs/e.log" | tr -d ' ')" "0" "90 YOK + alt istek 404: pCloud'a (x.invalid) bağlanma girişimi 0"
assert_eq "$(grep -c ' 500$' "$T/logs/a.log" | tr -d ' ')" "0" "90 YOK + alt istek 404: erişim günlüğünde 500 yok"
LAB_CI4_404=0
# auth ucu uygulamadan 2xx/401/403 dışı dönerse (404 / 500 / 302) de 403
for au in auth-404 auth-500 auth-302; do
    render_all "/${au}"; lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
    assert_eq "$(put /_fm/up/12/34)" "403" "auth ucu 2xx/401/403 dışı (${au}) → 403 (500 DEĞİL)"
    assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b2m")" "403" "auth ucu ${au}: 2 MiB gövde → 403"
done
render_all /auth; lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(put /_fm/up/12/34)" "502" "kontrol: auth geçince (204 + belirteç) hata eşlemesi YOK, proxy'ye ulaşır (502)"

echo "── 2b: MUTANTLAR — yapısal yorum-dışı kilitler gerçek nginx'te de ÖLÜR ──"
mutant() { # $1=etiket $2=sed ifadesi $3=anahtar $4=orijinal-kod $5=mutantta beklenen
    render_all /auth; sed -e "$2" "$T/c/20orig.conf" > "$T/c/20.conf"
    if cmp -s "$T/c/20orig.conf" "$T/c/20.conf"; then echo "  FAIL sondaj: mutant dosyayı DEĞİŞTİRMEDİ: $1"; TESTS_FAIL=$((TESTS_FAIL + 1)); TESTS_RUN=$((TESTS_RUN + 1)); return; fi
    if ! lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"; then
        echo "  PASS mutant '$1' nginx -t'de reddedildi/başlamadı (kilit zaten öldürür)"; TESTS_RUN=$((TESTS_RUN + 1)); return
    fi
    local mm; mm=$(run_matrix)
    assert_eq "$(kv "$mm" "$3")" "$5" "MUTANT '$1': ${3} → ${5} (orijinal ${4}) — nginx davranışı farkı yakalar"
}
mutant "^~ → ~ (yükleme location'ı)" 's|^location \^~ /_fm/up/ {|location ~ /_fm/up/ {|'  ok      502 403
mutant "her iki ^~ kaldır (düz önek)" 's|^location \^~ /_fm/|location /_fm/|'                php_ext 403 200
mutant "^~ /_fm/ 403 kökü kaldır"  's|^location \^~ /_fm/ { return 403; }|\# mutant|'         other_fm 403 200
mutant "limit_except kaldır"       's|^    limit_except PUT { deny all; }|    \# mutant|'     get     403 411
# Biçim kapısı mutantı: @fm_up'taki ikinci savunma (uid boşsa 403) DURUMU aynı tutar; fark, kapısız isteğin
# auth ucuna ULAŞMASIDIR (orijinalde 0 çağrı) — kilit bunu backend günlüğünden yakalar.
render_all /auth; sed -e 's|^    if (\$request_uri !~ .*|    \# mutant|' "$T/c/20orig.conf" > "$T/c/20.conf"
assert_ne "$(cmp -s "$T/c/20orig.conf" "$T/c/20.conf" && echo ayni || echo farkli)" "ayni" "sondaj: biçim kapısı mutantı dosyayı değiştirdi"
lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
: > "$T/logs/backend.log"; put '/_fm/up/12/34?x=1' >/dev/null
assert_eq "$(wc -l < "$T/logs/backend.log" | tr -d ' ')" "1" "MUTANT 'biçim kapısı kaldır': biçimsiz yol auth ucuna ULAŞIR (1 çağrı; orijinal 0) — kilit yakalar"
assert_eq "$(put '/_fm/up/12/34?x=1')" "403" "…ama @fm_up'taki ikinci savunma (uid boş → 403) durumu korur (derinlemesine savunma)"
# KAPI 2 mutantı: auth ucu başlıksız (auth-none) iken orijinal 403, mutant proxy'ye ulaşır (502)
render_all /auth-none; sed -e 's|^    if (\$fm_auth !~ .*|    \# mutant|' "$T/c/20orig.conf" > "$T/c/20.conf"
assert_ne "$(cmp -s "$T/c/20orig.conf" "$T/c/20.conf" && echo ayni || echo farkli)" "ayni" "sondaj: KAPI 2 mutantı dosyayı değiştirdi"
lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(put /_fm/up/12/34)" "502" "MUTANT 'KAPI 2 kaldır': başlıksız auth yanıtı pCloud'a ULAŞIR (502) — orijinal 403 (kilit bunu yakalar)"
# 411 mutantı
render_all /auth; sed -e 's|^    if (\$http_content_length = "") { return 411 "srvctl-fm-open [0-9a-f]*"; }|    \# mutant|' "$T/c/20orig.conf" > "$T/c/20.conf"
lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
assert_ne "$(code PUT /_fm/up/12/34 -H 'Transfer-Encoding: chunked' --data-binary abc)" "411" "MUTANT '411 kapısı kaldır': artık 411 değil (kilit yakalar)"
# 33m mutantı: 2 MiB gövde varsayılan 1m'e takılır
sed -e 's|^    client_max_body_size 33m;|    \# mutant|' "$T/c/20orig.conf" > "$T/c/20.conf"
lab_up "$T/c/20.conf" "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(code PUT /_fm/up/12/34 --data-binary "@$T/b2m")" "413" "MUTANT '33m kaldır': 2 MiB gövde 413 (orijinal 502)"
# error_page mutantı: 90 yok + alt istek 404 iken orijinal 403, mutant 500 (A bulgusu geri gelir)
sed -e 's|^    error_page 500 =403 @fm_deny;|    \# mutant|' "$T/c/20orig.conf" > "$T/c/20.conf"
assert_ne "$(cmp -s "$T/c/20orig.conf" "$T/c/20.conf" && echo ayni || echo farkli)" "ayni" "sondaj: error_page mutantı dosyayı değiştirdi"
LAB_CI4_404=1; lab_up "$T/c/20.conf" "$T/c/21.conf"; LAB_CI4_404=0
assert_eq "$(put /_fm/up/12/34)" "500" "MUTANT 'error_page kaldır': 90 yok + alt istek 404 → 500 (orijinal 403) — kilit yakalar"
lab_down

echo "── 3: off → 403 kökü: /_fm/ yolu CI4'e DÜŞMEZ ──"
_domconf_fm_render_off example_com > "$T/c/off.conf"
lab_up "$T/c/off.conf"; assert_eq "$?" "0" "lab (off) ayağa kalktı"
out=$("$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1); assert_contains "$out" "test is successful" "gerçek nginx 403 kökünü kabul eder"
assert_eq "$(put /_fm/up/12/34)" "403" "off: /_fm/up/12/34 → 403"
assert_eq "$(put /_fm/x)" "403" "off: /_fm/x → 403"
assert_eq "$(code GET /_fm/up/1/2)" "403" "off: GET → 403"
assert_eq "$(put /_fm/up/12/34.php)" "403" "off: .php uzantılı yol da 403 (vhost PHP regex'ine DÜŞMEZ)"
assert_eq "$(code GET /_fm)" "403" "off: '/_fm' (eğik çizgisiz) da 403"
assert_eq "$(code GET /_fmx)" "200" "off: '/_fmx' etkilenmez"
assert_eq "$(code GET /baska)" "200" "off: /_fm/ dışı yollar etkilenmez (CI4)"
# hiç açılmamış alan (dosya yok): /_fm/ CI4'e düşer — belgeli YOK durumu
lab_up; assert_eq "$(put /_fm/up/12/34)" "200" "YOK (dosya yok): /_fm/ CI4'e düşer (CI4'te /_fm/ rotası yok; fm-auth off ile kökler)"
lab_down

echo "── 3b: HER alanın 403 kökü (domain add/repair → _domconf_fm_root_provision): kiracı yolları etkilenmez ──"
_fm_reset
_domconf_fm_root_provision example.com 0 >/dev/null 2>&1; assert_eq "$?" "0" "403 kökü üretildi (srvctl üretimi, köken kaydı)"
assert_eq "$(_exists "$F20")" "var" "gerçek dosya custom.d/<sname>/20-srvctl-fm-upload.conf"
cp "$F20" "$T/c/root.conf"
lab_up "$T/c/root.conf"; assert_eq "$?" "0" "lab (üretilmiş 403 kökü) ayağa kalktı"
out=$("$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1); assert_contains "$out" "test is successful" "gerçek nginx ÜRETİLMİŞ kökü kabul eder"
for pth in /_fm /_fm/ /_fm/x /_fm/up/12/34 '/_fm?x=1' /%5ffm/x '/a/../_fm' '//_fm' /_fm/up/12/34.php; do
    assert_eq "$(code GET "$pth" --path-as-is)" "403" "kök: ${pth} → 403"
done
for pth in /_fmx /_fm-x /_fm_rapor /_fm.php /_fm.css /_fmx/up/1/2 /_fm-x/y /baska; do
    c=$(code GET "$pth" --path-as-is)
    assert_eq "$([[ "$c" == "200" ]] && echo 200 || echo "$c")" "200" "kök: kiracı yolu ${pth} ETKİLENMEZ (200)"
done
lab_down
# on → kök yerini gerçek yapılandırmaya bırakır; off → kök geri gelir (aynı dosya adı, tek dosya)
_domconf_fm_apply example.com example_com on eu "$SCRIPT" "${DEFAULT_PHP_VERSION}" 0 0 >/dev/null 2>&1
assert_eq "$([[ -f "$F90" && -f "$F21" && -f "$F20" ]] && echo hepsi)" "hepsi" "on: 90/21/20 kuruldu (kök 20'nin yerini aldı)"
assert_eq "$(grep -c 'location = /_fm {' "$F20")" "1" "on: 20 gerçek yapılandırma (=/_fm tek kez)"
_domconf_fm_apply example.com example_com off eu - - 0 0 >/dev/null 2>&1
cp "$F20" "$T/c/root2.conf"; lab_up "$T/c/root2.conf"
assert_eq "$(code GET /_fm)" "403" "off sonrası kök geri: /_fm 403"
assert_eq "$(code GET /_fm-x)" "200" "off sonrası kök: /_fm-x etkilenmez"
lab_down

echo "── 4: 21 — /__fm_dl internal + \$arg_u deseni (açık proxy negatifleri) ──"
render_all /auth
lab_up "$T/c/21.conf" "$T/c/90.conf"; assert_eq "$?" "0" "lab (21) ayağa kalktı"
assert_eq "$(code GET '/__fm_dl?u=https://a.pcloud.com/h/x.jpg')" "404" "dışarıdan /__fm_dl → 404 (internal)"
dl() { code GET /dl -H "X-R: /__fm_dl?u=$1"; }
while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    assert_eq "$(dl "$u")" "403" "açık proxy negatifi 403: ${u}"
done <<'URLS'
https://evil.com/x
http://a.pcloud.com/x
https://a.pcloud.com.evil.com/x
https://a.pcloudXcom/x
https://localhost.pcloud.com/x
https://a.localhost.pcloud.com/x
https://a.pcloud.com/../x
https://a.pcloud.com/a/../x
https://a.pcloud.com/%2e%2e/x
https://a.pcloud.com/%2E/x
https://a.pcloud.com/%2f/x
https://a.pcloud.com/%5c/x
https://a.pcloud.com/%00
https://a.pcloud.com/%1f
https://a.pcloud.com/%25
https://pcloud.com/x
https://.pcloud.com/x
https://-a.pcloud.com/x
https://a.pcloud.com:8080/x
https://user@a.pcloud.com/x
https://a.pcloud.com
https://127.0.0.1/x
https://unix:/run/php/php8.3-fpm-x.sock:/a
https://a.pcloud.com/x y
https://a.pcloud.com/x?y
https://a.pcloud.com/x#y
URLS
assert_eq "$(dl 'https://eapi.pcloud.com/h/x.jpg')" "502" "geçerli pCloud bağlantısı proxy'ye ulaşır (çözümsüz → 502)"
assert_eq "$(dl 'https://c1.pcloud.com/h/My%20picture.jpg')" "502" "yüzde-kodlu güvenli bayt kabul (502)"
# MUTANTLAR (21)
render_all /auth
_domconf_fm_render_download example_com | lab_fix > "$T/c/21orig.conf"
sed -e 's|^    internal;|    \# mutant|' "$T/c/21orig.conf" > "$T/c/21.conf"
lab_up "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(code GET '/__fm_dl?u=https://a.pcloud.com/h/x.jpg')" "502" "MUTANT 'internal kaldır': dışarıdan erişilebilir (502; orijinal 404)"
sed -e 's#pcloud\\\.com#pcloud.com#' "$T/c/21orig.conf" > "$T/c/21.conf"
if cmp -s "$T/c/21orig.conf" "$T/c/21.conf"; then echo "  FAIL sondaj: regex-nokta mutantı değişmedi"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; TESTS_RUN=$((TESTS_RUN+1))
lab_up "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(dl 'https://a.pcloudXcom/x')" "502" "MUTANT 'pcloud\\.com noktası kaçışsız': sahte alan adı geçer (502; orijinal 403)"
sed -e 's#(?!\.\*\\\.\\\.)##' "$T/c/21orig.conf" > "$T/c/21.conf"
if cmp -s "$T/c/21orig.conf" "$T/c/21.conf"; then echo "  FAIL sondaj: '..' mutantı değişmedi"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; TESTS_RUN=$((TESTS_RUN+1))
lab_up "$T/c/21.conf" "$T/c/90.conf"
assert_eq "$(dl 'https://a.pcloud.com/a/../x')" "502" "MUTANT '.. yasağı kaldır': dizin atlatma geçer (502; orijinal 403)"
lab_down

echo "── 5: diferansiyel — tarayıcı (lexer) = nginx sözcük çözümlemesi ──"
INC="$T/inc.conf"; printf 'zzinc_marker;\n' > "$INC"
SEEN=0
_diff_cb() { local n="${3:-}"; if [[ "$n" == "zzdeny_a" || "$n" == "include" ]]; then SEEN=1; fi; return 0; }
cat_main() { # $1 = server gövdesi
    cat <<EOF
pid $T/d.pid;
error_log $T/logs/d.log;
events { worker_connections 8; }
http {
  access_log off;
  client_body_temp_path $T/tmp/b; proxy_temp_path $T/tmp/p; fastcgi_temp_path $T/tmp/f; uwsgi_temp_path $T/tmp/u; scgi_temp_path $T/tmp/s;
  server { listen 127.0.0.1:${P1}; server_name x;
$1
  }
}
EOF
}
diff_case() { # $1=etiket $2=SEES|HIDDEN $3=içerik
    printf '%s\n' "$3" > "$T/dc.conf"
    cat_main "    include $T/dc.conf;" > "$T/nginx-d.conf"
    local o; o=$("$NG" -t -c "$T/nginx-d.conf" -p "$T" 2>&1)
    local sees=0
    [[ "$o" == *'unknown directive "zzdeny_a"'* || "$o" == *'unknown directive "zzinc_marker"'* ]] && sees=1
    SEEN=0; _domconf_nginx_parse "$T/dc.conf" _diff_cb >/dev/null 2>&1; local lex=$SEEN
    if [[ "$2" == "SEES" ]]; then
        assert_eq "$sees" "1" "[$1] (kontrol) nginx marker'ı gerçekten direktif olarak görüyor"
        assert_eq "$lex" "1" "[$1] nginx görüyor ⇒ lexer de direktif olarak GÖRÜR (sessiz atlatma yok)"
    else
        assert_eq "$sees" "0" "[$1] (kontrol) nginx marker'ı direktif olarak GÖRMÜYOR"
        assert_eq "$lex" "0" "[$1] nginx görmüyor ⇒ lexer yanlış pozitif vermez"
    fi
}
P1=19499   # yalnız 'nginx -t' (dinlemez)
diff_case "düz satır"            SEES   'zzdeny_a x;'
diff_case "tek satırlık blok"    SEES   'location /a { zzdeny_a x; }'
diff_case "aynı satır çoklu"     SEES   'return 204; zzdeny_a x;'
diff_case "tırnaklı ad"          SEES   '"zzdeny_a" x;'
diff_case "tek tırnaklı ad"      SEES   "'zzdeny_a' x;"
diff_case "token-ortası tırnak"  SEES   'add_header X-A a"; zzdeny_a x; add_header X-B "b";'
diff_case "kaçışlı tırnak"       SEES   'set $v \" ; zzdeny_a x; set $w \";'
diff_case "\${değişken}"         SEES   'set $x ${y}; zzdeny_a x;'
diff_case "a#b yorum değil"      SEES   'add_header X a#b; zzdeny_a x;'
diff_case "CRLF"                 SEES   $'return 204;\r\nzzdeny_a x;\r'
diff_case "blok kapanışı sonrası" SEES  'location /a { return 204; } zzdeny_a x;'
diff_case "include yüklenir"     SEES   "include $INC;"
diff_case "tırnaklı include"     SEES   "\"include\" \"$INC\";"
diff_case "yorumda marker"       HIDDEN '# zzdeny_a x;
return 204;'
diff_case "tırnak içi marker"    HIDDEN 'add_header X "zzdeny_a x;";'
diff_case "argüman marker"       HIDDEN 'add_header X zzdeny_a;'
diff_case "yorumdaki include"    HIDDEN "# include $INC;
return 204;"
diff_case "kaçışlı ; argüman"    HIDDEN 'add_header X a\;zzdeny_a;'

test_summary
