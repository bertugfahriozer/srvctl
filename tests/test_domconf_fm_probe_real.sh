#!/bin/bash
# shellcheck disable=SC2034,SC2317  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# F7-M1 — GERÇEK nginx + GERÇEK curl ile alan adına özgü gövde imzası ve sonda ölçümleri.
# nginx ya da curl YOKSA bu dosya ATLANIR, kırmızı vermez (ikili: $SRVCTL_TEST_NGINX ya da PATH'te 'nginx').
# YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl --resolve <alan>:<port>:127.0.0.1; resolver 127.0.0.1:9;
# ana makineler '*.invalid'). Port aralığı: 18930–18949 (F7/a2).
#
# Ölçülenler (taklitle ölçülemeyen, nginx'in GERÇEK davranışı):
#  1) `return 403|411 "metin"` gövdesi TAM metindir (sonda satırsonu yok), `error_page` bunu DEĞİŞTİRMEZ
#  2) sonda: kendi alanının AÇIK/KAPALI imzası → open/closed
#  3) sunucu düzeyi `if (...) { return 403; }`, varsayılan sunucu 403'ü, köksüz alanda uygulamanın 403/411'i,
#     başka alanın imzası, 1 KiB'den uzun gövde → unknown (ASLA closed/open uydurulmaz)
#  4) ortamda ölü bir HTTP proxy tanımlıyken sonda yine yerel nginx'e ulaşır (--noproxy '*')
#  5) status uçtan uca (gerçek curl, gerçek üretilmiş 20 dosyası)
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
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

T="$(mktemp -d)"; mkdir -p "$T/logs" "$T/c" "$T/tmp" "$T/shim"
P=0
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
trap 'lab_down; rm -rf "$T"; _fm_env_cleanup' EXIT
# lab_fix: YALNIZ laboratuvar dönüşümleri (ana makine *.invalid, yerel CA, günlük yolu; ModSecurity modülü bu nginx'te
# yoksa 'modsecurity off;' satırı düşürülür — sonda yanıtını etkilemez).
lab_fix() { sed -e "/^[[:space:]]*modsecurity off;/d" -e "s#eapi\.pcloud\.com#x.invalid#g" -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${T}/logs/#g"; }

# lab_up <sunucu-gövdesi-dosyası>: verilen dosya http{} içine alınır (server blokları). Dönüş 0 = ayağa kalktı.
lab_up() {
    lab_down
    local tries=0 i
    while (( tries < 12 )); do
        # PREF_P: 'off' alt kabukta koşar → reload kancasının yeniden başlattığı lab AYNI portta kalmalı (sonda portu ortamdan okunur;
        # alt kabukta P değişirse ebeveyn göremez). F8-L12: PREF_P varken BAŞKA port seçilmez — port boşalana dek (en çok ~5 sn) beklenir.
        if [[ -n "${PREF_P:-}" ]]; then
            P="$PREF_P"
            for (( i = 0; i < 100; i++ )); do lab_port_free "$P" && break; sleep 0.05; done
        else
            P=$((18930 + RANDOM % 20))
            if ! lab_port_free "$P"; then tries=$((tries + 1)); continue; fi
        fi
        sed "s/@P@/${P}/g" "$1" > "$T/servers.conf"
        cat > "$T/nginx.conf" <<EOT
pid $T/n.pid;
error_log $T/logs/e.log info;
events { worker_connections 32; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $T/tmp/b; proxy_temp_path $T/tmp/p; fastcgi_temp_path $T/tmp/f; uwsgi_temp_path $T/tmp/u; scgi_temp_path $T/tmp/s;
 include $T/servers.conf;
}
EOT
        : > "$T/logs/e.log"
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
# kök: <ad>.conf = alan adına özgü 20 dosyası (gerçek render, yalnız laboratuvar dönüşümü)
mk_open()   { _domconf_fm_render_upload eu 0 "$1" | lab_fix > "$T/c/$1.conf"; }
mk_closed() { _domconf_fm_render_off "$1" > "$T/c/$1.conf"; }
# probe <alan>: gerçek curl ile sonda (yalnız http portu P)
probe() {
    SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" _domconf_fm_runtime_probe "$1"
    printf '%s' "$_FMRT_STATE"
}
raw() { # raw <alan> → "kod|gövde" (sondayla AYNI istek biçimi, gövde BAYT-BAYT)
    local out
    out=$(curl -s -k -o - -w '\n%{http_code}' --noproxy '*' --path-as-is --resolve "$1:${P}:127.0.0.1" -X PUT -H 'Expect:' "http://$1:${P}/_fm/up/1/0" 2>/dev/null)
    printf '%s|%s' "${out##*$'\n'}" "${out%$'\n'*}"
}

SIG_E=$(_domconf_fm_body_sig example_com); SIG_O=$(_domconf_fm_body_sig other_com)
echo "── 1: gövde TAM imzadır; error_page onu değiştirmez ──"
mk_open example_com; mk_closed other_com
cat > "$T/s1.conf" <<EOT
server { listen 127.0.0.1:@P@; server_name example.com;
  error_page 403 /e403.html; error_page 411 /e411.html;
  location = /e403.html { return 200 "ERRORPAGE403"; }
  location = /e411.html { return 200 "ERRORPAGE411"; }
  include $T/c/example_com.conf; }
server { listen 127.0.0.1:@P@; server_name other.com;
  error_page 403 /e403.html;
  location = /e403.html { return 200 "ERRORPAGE403"; }
  include $T/c/other_com.conf; }
server { listen 127.0.0.1:@P@ default_server; server_name _; return 403; }
EOT
lab_up "$T/s1.conf"; assert_eq "$?" "0" "lab ayağa kalktı (nginx $("$NG" -v 2>&1 | sed 's/.*nginx\///'))"
out=$("$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1); assert_contains "$out" "test is successful" "gerçek nginx srvctl'in imzalı 20/kök dosyalarını kabul eder"
assert_eq "$(raw example.com)" "411|srvctl-fm-open ${SIG_E}" "1a: AÇIK 20 → 411 + gövde TAM 'srvctl-fm-open <sig>' (error_page 411 gövdeyi değiştirmedi)"
assert_eq "$(raw other.com)" "403|srvctl-fm-closed ${SIG_O}" "1b: KAPALI kök → 403 + gövde TAM 'srvctl-fm-closed <sig>' (error_page 403 gövdeyi değiştirmedi)"
curl -s -k -o "$T/b411" --noproxy '*' --resolve "example.com:${P}:127.0.0.1" -X PUT -H 'Expect:' "http://example.com:${P}/_fm/up/1/0"
assert_eq "$(wc -c < "$T/b411" | tr -d ' ')" "$(printf 'srvctl-fm-open %s' "$SIG_E" | wc -c | tr -d ' ')" "1c: gövde bayt sayısı = metin (sonda satırsonu YOK)"
r=$(raw nobody.invalid)
assert_eq "${r%%|*}" "403" "1d: kontrol — varsayılan sunucu 403 döner"
assert_not_contains "$r" "srvctl-fm-" "1d: ... ve gövdesi imza taşımaz (nginx'in kendi sayfası)"

echo "── 2: sonda sonuçları (gerçek curl) ──"
assert_eq "$(probe example.com)" "open" "2a: kendi AÇIK imzası → open"
assert_eq "$(probe other.com)" "closed" "2b: kendi KAPALI imzası → closed"
probe other.com >/dev/null
assert_contains "$_FMRT_DETAIL" "http:${P}=403" "2b: ayrıntıda gerçek kod"
assert_eq "$(probe nobody.invalid)" "unknown" "2c: varsayılan sunucu 403'ü (SSL'siz alanın 443'te başka vhost'a düşmesi benzeri) → unknown"
probe nobody.invalid >/dev/null
assert_contains "$_FMRT_DETAIL" "imza" "2c: ayrıntı imza yokluğunu söyler"

echo "── 3: yanıltıcı 403/411'ler ──"
mk_closed other_com
cp "$T/c/other_com.conf" "$T/c/example_com.conf"   # example.com vhost'unda YABANCI (other.com) imzası: yanlış include
cat > "$T/s3.conf" <<EOT
server { listen 127.0.0.1:@P@; server_name example.com; include $T/c/example_com.conf; }
server { listen 127.0.0.1:@P@; server_name lvl403.com;
  if (\$request_method = PUT) { return 403; }
  include $T/c/lvl403_com.conf; }
server { listen 127.0.0.1:@P@; server_name rootless411.com; location / { return 411 "app"; } }
server { listen 127.0.0.1:@P@; server_name rootless411e.com; location / { return 411; } }
server { listen 127.0.0.1:@P@; server_name rootless403.com; location / { return 403 "app"; } }
server { listen 127.0.0.1:@P@; server_name rootless404.com; location / { return 404 "srvctl-fm-closed ${SIG_E}"; } }
server { listen 127.0.0.1:@P@; server_name big.com;
  location / { return 403 "$(printf 'x%.0s' $(seq 1 1500))srvctl-fm-closed $(_domconf_fm_body_sig big_com)"; } }
server { listen 127.0.0.1:@P@; server_name v1.com; location = /_fm { return 403; } location ^~ /_fm/ { return 403; } }
server { listen 127.0.0.1:@P@ default_server; server_name _; return 403; }
EOT
mk_open lvl403_com
lab_up "$T/s3.conf"; assert_eq "$?" "0" "lab 3 ayağa kalktı"
assert_eq "$(probe example.com)" "unknown" "3a: vhost'ta BAŞKA alanın KAPALI imzası → unknown"
assert_eq "$(raw example.com)" "403|srvctl-fm-closed ${SIG_O}" "3a: (kanıt) yanıt gerçekten yabancı imza"
r=$(raw lvl403.com); assert_eq "${r%%|*}" "403" "3b: (kanıt) sunucu düzeyi 'if PUT return 403' gerçekten 403 veriyor, AÇIK 20 include'a rağmen"
assert_eq "$(probe lvl403.com)" "unknown" "3b: sunucu düzeyi 403 (QL7-M1/P5: gerçekte AÇIK) → unknown, KAPALI DEĞİL"
assert_eq "$(probe rootless411.com)" "unknown" "3c: köksüz alanda uygulamanın 411'i → unknown (sahte 'open' YOK)"
assert_eq "$(probe rootless411e.com)" "unknown" "3c: gövdesiz 411 → unknown"
assert_eq "$(probe rootless403.com)" "unknown" "3d: köksüz alanda uygulamanın 403'ü → unknown (sahte 'closed' YOK)"
assert_eq "$(probe rootless404.com)" "unknown" "3e: 404 + (doğru) KAPALI imzalı gövde → unknown (yalnız 403)"
r=$(raw big.com); assert_eq "${r%%|*}" "403" "3f: (kanıt) uzun gövdeli 403"
assert_eq "$(probe big.com)" "unknown" "3f: gövde > 1 KiB (--max-filesize) → unknown, imza sonda olsa bile"
assert_eq "$(probe v1.com)" "unknown" "3g: v1 (imzasız) kapalı kök → unknown"
assert_eq "$(probe nobody.invalid)" "unknown" "3h: varsayılan sunucu → unknown"

echo "── 4: ortam proxy'si sondayı dışarı taşımaz (R01 --noproxy '*') ──"
mk_open example_com; mk_closed other_com
lab_up "$T/s1.conf"
assert_eq "$(probe example.com)" "open" "4a: kontrol — proxy yokken open"
st=$( export http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9; probe example.com )
assert_eq "$st" "open" "4b: ölü proxy ortamda (http_proxy=127.0.0.1:9) sonda yine yerel nginx'e ULAŞIR ve open okur"
# kontrol: aynı ortamda --noproxy'siz bir curl gerçekten proxy'ye gider (4b'nin anlamlı olduğunu kanıtlar)
code=$( export http_proxy=http://127.0.0.1:9; curl -s -o /dev/null -w '%{http_code}' --max-time 3 --resolve "example.com:${P}:127.0.0.1" -X PUT "http://example.com:${P}/_fm/up/1/0" 2>/dev/null )
assert_eq "$code" "000" "4c: kontrol — --noproxy'siz curl bu ortamda proxy'ye gider ve düşer (000): proxy ortamı gerçekten devrede"

echo "── 5: status uçtan uca (gerçek curl, srvctl'in GERÇEK ürettiği 20) ──"
_fm_reset
# Bu noktada çalışan nginx YOK (lab henüz kalkmadı): `on` diski+kaydı yazar, reload (taklit) başarılıdır, ama çalışan durum AÇIK imzasıyla
# doğrulanamaz → açılış geri alınmaz AMA rc 4 ve "AÇILDI, canlıda DOĞRULANAMADI" der (status'un doğrulanamadı koduyla aynı anlam).
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$T/on.out" 2>&1; rc5a=$?
assert_eq "$rc5a" "4" "5a: fm-auth on (taklit nginx -t/reload; çalışan nginx yok) → rc 4 (açıldı, canlıda doğrulanamadı)"
assert_contains "$(sed 's/\x1b\[[0-9;]*m//g' "$T/on.out")" "DOĞRULANAMADI" "5a: ileti 'DOĞRULANAMADI' der"
assert_contains "$(sed 's/\x1b\[[0-9;]*m//g' "$T/on.out")" "GERİ ALINMADI" "5a: geri alınmadığını söyler"
lab_fix < "$F20" > "$T/c/example_com.conf"; mk_closed other_com
lab_up "$T/s1.conf"
out=$(SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" _domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "5b: status rc 0 (disk AÇIK + çalışan AÇIK)"
assert_contains "$out" "AÇIK imzası (411) — diskle tutarlı" "5b: çalışan AÇIK imzası gerçek nginx'ten okundu"
# F7-H2: 'off' çalışan durumu da sınar → mock reload GERÇEK nginx'i de yeniler (lab diski izler); aksi halde off, çalışan nginx'in
# hâlâ AÇIK olduğunu (haklı olarak) rc 3 ile bildirirdi.
eval "_orig5__systemctl() $(declare -f systemctl | sed 1d)"
systemctl() {
    _orig5__systemctl "$@"
    if [[ "$1" == "reload" ]]; then cp "$F20" "$T/c/example_com.conf"; lab_up "$T/s1.conf"; fi
    return 0
}
( PREF_P="$P" SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" _domconf_fm_auth example.com off ) >"$T/off.out" 2>&1; rc5c=$?; [[ "$rc5c" == "0" ]] || sed 's/^/    [off.out] /' "$T/off.out" >&2
assert_eq "$rc5c" "0" "5c: fm-auth off (çalışan nginx KAPALI imzası verir → rc 0)"
systemctl() { _orig5__systemctl "$@"; }
cp "$F20" "$T/c/example_com.conf"
lab_up "$T/s1.conf"
out=$(SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" _domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "5d: status rc 0 (disk KAPALI + çalışan KAPALI)"
assert_contains "$out" "KAPALI imzası (403) — diskle tutarlı" "5d: çalışan KAPALI imzası gerçek nginx'ten okundu"
# disk KAPALI ama çalışan nginx hâlâ eski (AÇIK) yapılandırmada: reload edilmemiş
mk_open example_com
lab_up "$T/s1.conf"
out=$(SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" _domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "5e: disk KAPALI + çalışan imzalı AÇIK → rc 1"
assert_contains "$out" "FM HÂLÂ AÇIK" "5e: 'FM HÂLÂ AÇIK'"
# köksüz alan (kayıt yok, dosya yok), uygulama 411: sahte alarm YOK
_fm_reset
cat > "$T/s5.conf" <<EOT
server { listen 127.0.0.1:@P@; server_name example.com; location / { return 411 "app"; } }
EOT
lab_up "$T/s5.conf"
out=$(SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" _domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "5f: köksüz alan: status rc 1 ('fm-auth YOK')"
assert_not_contains "$out" "FM HÂLÂ AÇIK" "5f (L6): köksüz alanda uygulamanın 411'i → ikinci yanıltıcı 'FM HÂLÂ AÇIK' uyarısı YOK"
assert_contains "$out" "srvctl FM imzası" "5f (L6): 'imza alınmadı' söylenir"

lab_down
echo "── dışarı-0-istek kanıtı (curl sarmalayıcı günlüğü) ──"
assert_eq "$(command -v curl)" "$T/shim/curl" "K0: curl PATH'te sarmalayıcı (kalkan devrede)"
n_all=$(grep -vc '^DENY' "$SHIM_LOG"); n_deny=$(grep -c '^DENY' "$SHIM_LOG")
assert_eq "$n_deny" "0" "K1: DENY edilen istek 0 (toplam $n_all curl çağrısı, hepsi --resolve …:127.0.0.1 ya da 127.0.0.1)"
assert_eq "$(grep -v 'DENY' "$SHIM_LOG" | grep -vc -e '--resolve [^ ]*:127\.0\.0\.1' -e 'http://127\.0\.0\.1:')" "0" "K2: her çağrı --resolve …:127.0.0.1 ya da doğrudan 127.0.0.1 taşıyor"
curl -s https://evil.example/x >/dev/null 2>&1; assert_eq "$?" "7" "K3: kalkan dış hedefi REDDEDER (kanıt: kalkan çalışıyor)"
grep -q '^DENY https://evil.example/x' "$SHIM_LOG"; assert_eq "$?" "0" "K3: DENY günlüğe yazıldı"
test_summary
