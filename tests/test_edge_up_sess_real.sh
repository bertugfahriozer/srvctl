#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329,SC2086
# GERÇEK nginx laboratuvarı — E66: yükleme OTURUMU başına tek eşzamanlı PUT (fm-upload 20 + http düzeyi fm-sess bölgesi).
#
# SORUN: FmAuthStoreFm::authorize sıradaki ofseti yetkilendirme anında ilerletir; değiştirilmiş bir istemci aynı uploadid'in ardışık
# ofsetlerini PARALEL gönderebilir. pCloud aynı uploadid'e paralel yazmayı reddeder (2068) ama nginx her uçuştaki istek için @fm_up'ta
# ≤4 MiB tampon tutar; tek IP ≈ conn_per_ip(20..200) x 4 MiB. Düzeltme: uploadid başına limit_conn 1 (srvctl-fmsess bölgesi).
#
# LABORATUVAR (dış ağa istek YOK; dinleme YALNIZ 127.0.0.1; portlar SRVCTL_LAB_PORT_BASE (8941) .. +3):
#   curl ──► lab nginx (BASE, TLS + http2; srvctl'in RENDER ettiği GERÇEK 20 + conf.d/srvctl-fmsess.conf; vhost'un
#            'limit_conn conn_per_ip' satırı ve http düzeyi limit_conn_status 429 canlıdaki gibi) ──► sahte pCloud (BASE+2, TLS;
#            gövdeyi alır, '9' ile başlayan uploadid'lerde yanıtı SESS_HOLD_MS (1500) tutar = YAVAŞ yutan üst akış; eşzamanlılığı kaydeder).
#   auth_request kapısı: lab kuklası (BASE+1) aynı sözleşmeyi verir (geçerli bilet → 204 + X-Fm-Auth; aksi 403). Kapılar 20'de GERÇEK.
#   SESS_TPL_ROOT=<dizin> → şablonlar <dizin>/nginx/ altından (KIRMIZI ölçüm: düzeltmeden ÖNCEKİ şablon, ör. srvctl-e66-base/templates).
#   SESS_WORKERS (varsayılan 4): nginx işçi sayısı (çapraz-işçi yarışı için).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
RED_MODE=0
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
if [[ -n "${SESS_TPL_ROOT:-}" ]]; then SRVCTL_TEMPLATES="$SESS_TPL_ROOT"; export SRVCTL_TEMPLATES; RED_MODE=1; fi

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "── gerçek nginx/curl/openssl/python3 yok — ÖLÇÜM BÖLÜMÜ ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi>) ──"
    test_summary; exit 0
fi
B="${SRVCTL_LAB_PORT_BASE:-8941}"
[[ "$B" =~ ^[1-9][0-9]{3,4}$ ]] || { echo "SRVCTL_LAB_PORT_BASE geçersiz"; exit 1; }
LP_TLS=$B; LP_AUTH=$((B + 1)); LP_PC=$((B + 2)); LP_UP=$((B + 3))
port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
for p in $LP_TLS $LP_AUTH $LP_PC $LP_UP; do
    port_free "$p" || { echo "── lab portu ${p} DOLU — ÖLÇÜM BÖLÜMÜ ATLANDI ──"; test_summary; exit 0; }
done
HOLD_MS="${SESS_HOLD_MS:-1500}"; WORKERS="${SESS_WORKERS:-4}"; ROUNDS="${SESS_ROUNDS:-10}"; SEQ="${SESS_SEQ:-100}"
HELPER="${REPO_ROOT}/tests/sess_lab.py"

LAB_KEEP=0
if [[ -n "${SRVCTL_LAB_DIR:-}" ]]; then LAB="$SRVCTL_LAB_DIR"; LAB_KEEP=1; mkdir -p "$LAB"; else LAB="$(mktemp -d)"; fi
mkdir -p "$LAB/logs" "$LAB/tmp" "$LAB/pki" "$LAB/conf.d"
lab_down() {
    local i pid
    if [[ -f "$LAB/n.pid" ]]; then
        pid=$(cat "$LAB/n.pid")
        "$NG" -s quit -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        hs_kill_pidfile TERM "$LAB/n.pid" 'nginx'
    fi
    hs_kill_pidfile TERM "$LAB/sink.pid" 'python[0-9.]*|Python'
}
cleanup() { lab_down; if (( LAB_KEEP == 0 )); then rm -rf -- "${LAB:?}"; fi; }
trap 'cleanup; _fm_env_cleanup' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$LAB/pki/k.pem" -out "$LAB/pki/c.pem" -days 2 -subj "/CN=lab" \
    -addext "subjectAltName=DNS:example.com,DNS:up.example.com,DNS:eapi.pcloud.com" >/dev/null 2>&1
[[ -s "$LAB/pki/c.pem" ]] || { echo "  FAIL PKI üretilemedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; }
GOOD=$(printf 'a%.0s' $(seq 1 64))

# ── srvctl'in GERÇEK çıktıları: 20 (render) + http düzeyi bölge dosyası (srvctl'in kendi yazıcısı; yoksa — KIRMIZI taban — yazılmaz) ──
RENDERED=$(_domconf_fm_render_upload eu 0 example_com) || { echo "  FAIL 20 şablonu render edilemedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; }
printf '%s\n' "$RENDERED" | sed -e "s#/etc/ssl/certs/ca-certificates\.crt#${LAB}/pki/c.pem#g" -e "s#proxy_ssl_verify on;#proxy_ssl_verify off;#" > "$LAB/20.conf"
export SRVCTL_NGINX_CONF_D="$LAB/conf.d"
if declare -F _domconf_fm_sess_conf_ensure >/dev/null && (( RED_MODE == 0 )); then
    _domconf_fm_sess_conf_ensure || echo "  (bölge dosyası yazılamadı)"
fi
# HİPOTEZ ölçümü (RAPOR §1): SESS_ZONE_FILE=<dosya> bölge dosyasını değiştirir; SESS_CONFD_AFTER=1 conf.d'yi sunucudan SONRA include eder
# ('set' ile doğan değişken anahtar olacaksa bölge, değişken tanımlandıktan sonra çözülmelidir). Varsayılan akışta KULLANILMAZ.
if [[ -n "${SESS_ZONE_FILE:-}" ]]; then cat "$SESS_ZONE_FILE" > "$LAB/conf.d/srvctl-fmsess.conf"; fi
VHOST_CONN="limit_conn conn_per_ip 50;"; [[ "${SESS_NO_VHOST_CONN:-0}" == "1" ]] && VHOST_CONN=""
INC_BEFORE="include $LAB/conf.d/*.conf;"; INC_AFTER=""
if [[ "${SESS_CONFD_AFTER:-0}" == "1" ]]; then INC_AFTER="$INC_BEFORE"; INC_BEFORE=""; fi
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
worker_processes ${WORKERS};
error_log $LAB/logs/e.log info;
events { worker_connections 256; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $LAB/tmp/b; proxy_temp_path $LAB/tmp/p; fastcgi_temp_path $LAB/tmp/f; uwsgi_temp_path $LAB/tmp/u; scgi_temp_path $LAB/tmp/s;
 limit_conn_zone \$binary_remote_addr zone=conn_per_ip:10m;
 limit_conn_status 429;
 ${INC_BEFORE}
 upstream eapi.pcloud.com { server 127.0.0.1:${LP_PC}; }
 server { listen 127.0.0.1:${LP_AUTH};
   location = /auth {
     if (\$http_x_fm_ticket = "$GOOD") { add_header X-Fm-Auth "Bearer lab-token" always; return 204; }
     return 403; }
 }
 server { listen 127.0.0.1:${LP_UP} ssl http2; server_name up.example.com;
   ssl_certificate $LAB/pki/c.pem; ssl_certificate_key $LAB/pki/k.pem;
   ${VHOST_CONN}
   include $LAB/20.conf;
   include $LAB/90.conf;
   location / { return 404; }
 }
 server { listen 127.0.0.1:${LP_TLS} ssl http2; server_name example.com;
   ssl_certificate $LAB/pki/c.pem; ssl_certificate_key $LAB/pki/k.pem;
   ${VHOST_CONN}
   add_header X-Lab-Srv "1" always;
   include $LAB/20.conf;
   include $LAB/90.conf;
   location / { return 404; }
 }
 ${INC_AFTER}
}
EOT
if ! "$NG" -t -c "$LAB/nginx.conf" -p "$LAB" >"$LAB/t.out" 2>&1; then
    sed 's/^/    [lab] /' "$LAB/t.out" >&2; echo "  FAIL lab nginx yapılandırması geçmedi"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1
fi
SINKLOG="$LAB/logs/sink.log"; : > "$SINKLOG"
python3 -I "$HELPER" spawn "$LAB/sink.pid" "$LAB/logs/sink.out" slowsink "$LP_PC" "$LAB/pki/c.pem" "$LAB/pki/k.pem" "$SINKLOG" "$HOLD_MS"
"$NG" -c "$LAB/nginx.conf" -p "$LAB" >/dev/null 2>&1
for (( i = 0; i < 100; i++ )); do ! port_free "$LP_TLS" && ! port_free "$LP_PC" && break; sleep 0.05; done

head -c 65536 /dev/zero > "$LAB/b64k.bin"
U="https://example.com:${LP_TLS}/_fm/up"
COMMON=(-sS -q -k --noproxy '*' --max-time 40 -H 'Expect:' -H "X-Fm-Ticket: $GOOD" --resolve "example.com:${LP_TLS}:127.0.0.1" --resolve "up.example.com:${LP_UP}:127.0.0.1")
CURL=(curl "${COMMON[@]}")
# paralel/çok-blok çağrılarda --next her blokta seçenekleri SIFIRLAR: ortak seçenekler her bloğa yeniden verilir
sink_max() { awk -v u="$1" '$1=="S" && $2==u && $4>m{m=$4} END{print m+0}' "$SINKLOG"; }   # uploadid için üst akışta görülen EN YÜKSEK eşzamanlılık
sink_max_all() { awk '$1=="S" && $5>m{m=$5} END{print m+0}' "$SINKLOG"; }
sink_hits() { awk -v u="$1" '$1=="S" && $2==u{c++} END{print c+0}' "$SINKLOG"; }
# $1=--http2|--http1.1 $2=uploadid $3..=ofsetler → paralel PUT (curl --parallel); "kod" satırları sıralı
par_put() {
    local proto="$1" uid="$2"; shift 2
    local args=() o first=1
    for o in "$@"; do
        (( first )) || args+=(--next)
        first=0
        args+=("${COMMON[@]}" "$proto" -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}\n' "${U}/${uid}/${o}")
    done
    curl --parallel --parallel-immediate "${args[@]}" 2>/dev/null | sort | tr '\n' ' '
}
# $1=proto $2..=tam URL'ler (her biri PUT) → paralel
par_urls() {
    local proto="$1"; shift
    local args=() u first=1
    for u in "$@"; do
        (( first )) || args+=(--next)
        first=0
        args+=("${COMMON[@]}" "$proto" -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}\n' "$u")
    done
    curl --parallel --parallel-immediate "${args[@]}" 2>/dev/null | sort | tr '\n' ' '
}

echo "══ 0: lab zinciri ══"
c=$("${CURL[@]}" --http1.1 -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}' "${U}/1234/0" 2>/dev/null)
assert_eq "$c" "200" "tek PUT: vekil → gerçek 20 → sahte pCloud 200"

echo "══ 1: AYNI uploadid'e iki EŞZAMANLI PUT (yavaş üst akış, ${HOLD_MS} ms) ══"
for proto in --http1.1 --http2; do
    : > "$SINKLOG"
    r=$(par_put "$proto" 9101 0 1)
    mx=$(sink_max 9101); hits=$(sink_hits 9101)
    echo "  ÖLÇÜM ${proto}: kodlar=[${r}] üst akışa ulaşan=${hits} üst akışta en yüksek eşzamanlılık=${mx}"
    assert_eq "$mx" "1" "${proto}: aynı uploadid için üst akışta AZAMİ 1 eşzamanlı istek"
    assert_eq "$hits" "1" "${proto}: ikinci eşzamanlı PUT üst akışa ULAŞMADI"
    assert_eq "$r" "200 503 " "${proto}: biri 200, öteki 503 (istemci putError: 5xx → backoff + resume, ölümcül değil)"
done

echo "══ 1b: 503 yanıtı sunucu düzeyi 'always' başlıklarını taşır (up bloğunda CORS ACAO için: tarayıcı 503'ü 'ağ hatası' değil durum olarak görür) ══"
: > "$SINKLOG"
r=$(curl --parallel --parallel-immediate "${COMMON[@]}" --http2 -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}:%header{x-lab-srv}\n' "${U}/9151/0" \
    --next "${COMMON[@]}" --http2 -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}:%header{x-lab-srv}\n' "${U}/9151/1" 2>/dev/null | sort | tr '\n' ' ')
assert_eq "$r" "200:1 503:1 " "reddedilen 503 de sunucu düzeyi add_header (always) başlığını taşır"

echo "══ 2: FARKLI uploadid'ler paralel geçer ══"
for proto in --http1.1 --http2; do
    : > "$SINKLOG"
    out=$(par_urls "$proto" "${U}/9211/0" "${U}/9212/0" "${U}/9213/0")
    echo "  ÖLÇÜM ${proto}: kodlar=[${out}] üst akışta toplam eşzamanlılık=$(sink_max_all)"
    assert_eq "$out" "200 200 200 " "${proto}: üç farklı uploadid de 200"
    assert_eq "$(( $(sink_max_all) >= 2 ? 1 : 0 ))" "1" "${proto}: farklı oturumlar GERÇEKTEN paralel koştu (üst akışta eşzamanlılık >= 2)"
done

echo "══ 3: ardışık meşru akış — ${SEQ} ardışık parça, tek h2 bağlantısı ve h1.1 keep-alive: yanlış red 0 ══"
for proto in --http2 --http1.1; do
    : > "$SINKLOG"
    # tek sıralı curl çağrısı: --next bağlantıyı yeniden kullanır (h2: tek bağlantı; h1.1: keep-alive); ortak seçenekler her bloğa
    fargs=(); for (( k = 0; k < SEQ; k++ )); do fargs+=("${COMMON[@]}" "$proto" -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}\n' "${U}/1300/${k}"); (( k < SEQ - 1 )) && fargs+=(--next); done
    out=$(curl "${fargs[@]}" 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';')
    echo "  ÖLÇÜM ${proto}: ${out}"
    assert_eq "$out" " ${SEQ} 200;" "${proto}: ${SEQ} ardışık PUT'un HEPSİ 200 (yanlış red 0)"
    assert_eq "$(sink_hits 1300)" "$SEQ" "${proto}: ${SEQ} istek de üst akışa ulaştı"
done

echo "══ 3b: her istek YENİ bağlantı (TLS+TCP) — en çok 60 ayrı curl süreci, çapraz-işçi yuva serbest bırakma yarışı: yanlış red 0 ══"
for proto in --http1.1 --http2; do
    : > "$SINKLOG"; bad=0; n3=$(( SEQ < 60 ? SEQ : 60 ))
    for (( k = 0; k < n3; k++ )); do
        c=$("${CURL[@]}" "$proto" -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}' "${U}/1400/${k}" 2>/dev/null)
        [[ "$c" == "200" ]] || bad=$((bad + 1))
    done
    assert_eq "$bad" "0" "${proto}: ${n3} ardışık YENİ-bağlantılı PUT, ${WORKERS} işçi: yanlış red 0"
done

echo "══ 4: sızıntı yok — ${ROUNDS} tur: (paralel çift → 200+503) sonra ardışık PUT her seferinde 200 ══"
bad=0
for (( t = 0; t < ROUNDS; t++ )); do
    proto="--http2"; (( t % 2 )) && proto="--http1.1"
    r=$(par_put "$proto" 9301 0 1)
    [[ "$r" == "200 503 " ]] || { bad=$((bad + 1)); echo "  tur ${t} ${proto}: çift=[${r}]"; }
    c=$("${CURL[@]}" "$proto" -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}' "${U}/9301/2" 2>/dev/null)
    [[ "$c" == "200" ]] || { bad=$((bad + 1)); echo "  tur ${t} ${proto}: çift sonrası ardışık=[${c}]"; }
done
assert_eq "$bad" "0" "${ROUNDS} turda sızıntı/yanlış red yok (reddedilen istek yer bırakıyor, biten istek yer bırakıyor)"

echo "══ 5: boş/biçimsiz uploadid yolu hâlâ 403 ve limit_conn anahtarına GİRMEZ ══"
: > "$SINKLOG"
for path in "/_fm/up/abc/0" "/_fm/up//0" "/_fm/up/12/0?x=1" "/_fm/up/12/0/" "/_fm/up/12" "/_fm/up/%39101/0" "/_fm/up/9401/0/../1" "/_fm/up/123456789012345678901/0"; do
    c=$("${CURL[@]}" --http1.1 --path-as-is -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w '%{http_code}' "https://example.com:${LP_TLS}${path}" 2>/dev/null)
    assert_eq "$c" "403" "PUT ${path} → 403"
done
assert_eq "$(awk '$1=="S"{c++} END{print c+0}' "$SINKLOG")" "0" "biçimsiz yolların hiçbiri üst akışa ulaşmadı"
# eş zamanlı biçimsiz yol: aynı (boş) anahtar paylaşılsaydı biri 503 alırdı
r=$(par_urls --http2 "${U}/abc/0" "${U}/abc/1")
assert_eq "$r" "403 403 " "eşzamanlı iki biçimsiz yol: boş anahtar sayılmaz → ikisi de 403 (503 YOK)"

echo "══ 6: PUT dışı yöntem anahtara girmez; yetkisiz istek ──"
: > "$SINKLOG"
r=$(curl --parallel --parallel-immediate "${COMMON[@]}" --http2 -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null -w 'put=%{http_code}\n' "${U}/9501/0" \
    --next "${COMMON[@]}" --http2 -X GET -o /dev/null -w 'get=%{http_code}\n' "${U}/9501/1" \
    --next "${COMMON[@]}" --http2 -X OPTIONS -o /dev/null -w 'opt=%{http_code}\n' "${U}/9501/2" 2>/dev/null | sort | tr '\n' ' ')
echo "  ÖLÇÜM: ${r}"
assert_contains "$r" "put=200" "uzun süren PUT 200 ile bitti"
assert_not_contains "$r" "=503" "GET/OPTIONS aynı uploadid'in PUT kotasını tüketmez (503 YOK)"
FAKE1=$(printf 'b%.0s' $(seq 1 64)); FAKE2=$(printf 'c%.0s' $(seq 1 64))
NOTK=(-sS -q -k --noproxy '*' --max-time 40 -H 'Expect:' --resolve "example.com:${LP_TLS}:127.0.0.1" --resolve "up.example.com:${LP_UP}:127.0.0.1")
head -c 2097152 /dev/zero > "$LAB/b2m.bin"

echo "══ 7: B1 — YETKİSİZ istek meşru oturumun yuvasını TUTAMAZ (anahtar = uploadid + bilet) ══"
# saldırgan: büyük Content-Length + damla gövde ⇒ 403'ü hemen alır ama nginx gövdeyi atarken (lingering) istek yaşar ve limit_conn yuvası dolu kalır.
for atk in "-" "$FAKE1"; do
    r=$(python3 -I "$HELPER" race "$LP_TLS" example.com 9601 "$atk" "$GOOD" 9)
    echo "  ÖLÇÜM saldırgan bileti=$([[ "$atk" == "-" ]] && echo YOK || echo 'sahte(geçerli biçim)'): ${r}"
    assert_contains "$r" "saldirgan=403" "yetkisiz istek 403 aldı"
    assert_not_contains "$r" "503" "yetkisiz istek meşru oturumun PUT'larını 503'e DÜŞÜRMEDİ"
    assert_not_contains "$r" "mesru=," "meşru PUT'lar gerçekten gönderildi"
done
echo "  ── aynı BİÇİMCE GEÇERLİ sahte biletle iki eşzamanlı PUT ⇒ biri 403 (auth), öteki hemen 503; farklı sahte biletle ikisi de 403 ──"
par_tk() { # $1=bilet1 $2=bilet2 $3=url ; ikisi de yavaş (--limit-rate) büyük gövdeli
    curl --parallel --parallel-immediate "${NOTK[@]}" -H "X-Fm-Ticket: $1" --limit-rate 400k --http1.1 -X PUT --data-binary @"$LAB/b2m.bin" -o /dev/null -w '%{http_code}\n' "$3" \
        --next "${NOTK[@]}" -H "X-Fm-Ticket: $2" --limit-rate 400k --http1.1 -X PUT --data-binary @"$LAB/b2m.bin" -o /dev/null -w '%{http_code}\n' "$3" 2>/dev/null | sort | tr '\n' ' '
}
r=$(par_tk "$FAKE1" "$FAKE1" "${U}/9611/0"); echo "  ÖLÇÜM aynı sahte bilet: [${r}]"
assert_eq "$r" "403 503 " "aynı (sahte) bilet + aynı uploadid: biri 403 (auth), ikincisi 503 (aynı bilet paralel gönderemez)"
r=$(par_tk "$FAKE1" "$FAKE2" "${U}/9612/0"); echo "  ÖLÇÜM farklı sahte biletler: [${r}]"
assert_eq "$r" "403 403 " "farklı sahte biletler: ikisi de 403 (yuvası başkasında DEĞİL — sayılmadı)"
r=$(curl --parallel --parallel-immediate "${NOTK[@]}" --limit-rate 400k --http1.1 -X PUT --data-binary @"$LAB/b2m.bin" -o /dev/null -w '%{http_code}\n' "${U}/9614/0" \
    --next "${NOTK[@]}" --limit-rate 400k --http1.1 -X PUT --data-binary @"$LAB/b2m.bin" -o /dev/null -w '%{http_code}\n' "${U}/9614/0" 2>/dev/null | sort | tr '\n' ' ')
assert_eq "$r" "403 403 " "biletsiz iki eşzamanlı istek: anahtar BOŞ ⇒ sayılmaz ⇒ ikisi de 403"
r=$(par_tk "XYZ" "XYZ" "${U}/9615/0")
assert_eq "$r" "403 403 " "biçimsiz bilet (geçersiz): anahtar BOŞ ⇒ sayılmaz ⇒ ikisi de 403"
r=$(par_tk "${GOOD:0:63}" "${GOOD:0:63}" "${U}/9616/0")
assert_eq "$r" "403 403 " "63 hane bilet (biçim dışı): sayılmaz ⇒ ikisi de 403"
r=$(par_tk "${GOOD}0" "${GOOD}0" "${U}/9617/0")
assert_eq "$r" "403 403 " "65 hane bilet (biçim dışı): sayılmaz ⇒ ikisi de 403"

echo "══ 8: B2 — fm-up sunucusu (up.<alan>) AYNI oturum kotasını paylaşır ══"
for proto in --http1.1 --http2; do
    : > "$SINKLOG"
    r=$(par_urls "$proto" "https://example.com:${LP_TLS}/_fm/up/9701/0" "https://up.example.com:${LP_UP}/_fm/up/9701/1")
    echo "  ÖLÇÜM ${proto}: ana alan + up sunucusu, aynı uploadid, aynı bilet: [${r}] üst akışta en yüksek eşzamanlılık=$(sink_max 9701)"
    assert_eq "$r" "200 503 " "${proto}: ana alandan + up sunucusundan eşzamanlı iki PUT: biri 200, öteki 503"
    assert_eq "$(sink_max 9701)" "1" "${proto}: üst akışta AZAMİ 1 eşzamanlı istek (iki sunucu toplamı)"
done
: > "$SINKLOG"
r=$(par_urls --http1.1 "https://example.com:${LP_TLS}/_fm/up/9711/0" "https://up.example.com:${LP_UP}/_fm/up/9712/0")
assert_eq "$r" "200 200 " "iki sunucuda FARKLI uploadid'ler birbirini sınırlamaz"

echo "══ 9: bilet SIZMAZ — hata günlüğü ve yanıtlar bilet içermez (limit_conn anahtarı yalnız paylaşılan bellekte) ══"
assert_ne "$(grep -c 'limiting connections' "$LAB/logs/e.log")" "0" "(önkoşul) reddedilen istekler hata günlüğüne yazıldı"
leak=$(grep -c -F -e "$GOOD" -e "$FAKE1" -e "$FAKE2" -e "${GOOD:0:32}" -e "${FAKE1:0:32}" "$LAB/logs/e.log")
assert_eq "$leak" "0" "hata günlüğünde bilet (ya da 32 haneli öneki) YOK"
hdr=$(curl --parallel --parallel-immediate "${COMMON[@]}" --http1.1 -D - -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null "${U}/9801/0" --next "${COMMON[@]}" --http1.1 -D - -X PUT --data-binary @"$LAB/b64k.bin" -o /dev/null "${U}/9801/1" 2>/dev/null)
assert_not_contains "$hdr" "$GOOD" "yanıt başlıklarında bilet YOK"
test_summary
