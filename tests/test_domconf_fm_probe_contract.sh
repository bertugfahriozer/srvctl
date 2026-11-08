#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh taklit bayrakları burada atanır; yardımcılar dolaylı çağrılır
# F7-M1 / M3 / L6 / L11(sonda) — ALAN ADINA ÖZGÜ GÖVDE İMZASI ve ÇALIŞAN DURUM SONDASININ SÖZLEŞMESİ.
#
# SÖZLEŞME (tek kaynak: lib/domconf.sh _domconf_fm_body_sig + _domconf_fm_runtime_probe):
#   sig  = ilk 12 hex( sha256("srvctl-fm-sig:v" + _DOMCONF_FM_TPL_VER + ":" + sname) )      (_DOMCONF_FM_TPL_VER = 2)
#   KAPALI kök : `location = /_fm` ve `location ^~ /_fm/` → `return 403 "srvctl-fm-closed <sig>";`   (render_off <sname>)
#   AÇIK yük.  : `if ($http_content_length = "") { return 411 "srvctl-fm-open <sig>"; }`          (render_upload <r> <m> <sname>)
#   Sonda      : gövdesiz `PUT /_fm/up/1/0`, curl --resolve <alan>:<port>:127.0.0.1. YALNIZ (403 + gövde TAM `srvctl-fm-closed
#                <sig>`) → closed; YALNIZ (411 + gövde TAM `srvctl-fm-open <sig>`) → open; başka HER şey → unknown.
#
# Bu dosya sondanın kapılarını DAVRANIŞLA kilitler (sözcük araması değil): curl taklidi (tests/fm_env.sh) gerçek curl'ün
# biçimiyle yanıt verir (-o -, -w '\n%{http_code}', --max-filesize); yanıtlar kod+gövde ikilisi olarak beslenir.
# Gerçek nginx 1.28 ile gövde/imza/proxy ölçümleri: tests/test_domconf_fm_probe_real.sh.
# NOT: ön planda koşun (arka plan başlatması sinyalleri yok saydırır).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
SIG=$(_domconf_fm_body_sig example_com)
SIG_O=$(_domconf_fm_body_sig other_com)
CLOSED="srvctl-fm-closed ${SIG}"
OPEN="srvctl-fm-open ${SIG}"
_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_out() { cat "$OUTF"; }
calls() { grep -c . "$CURL_LOG" | tr -d ' '; }
# probe <https-port|off> <http-port|off>: sondayı koştur; "durum|detay" yazar (çağrı sayısı CURL_LOG'da)
probe() {
    : > "$CURL_LOG"; : > "$CURL_ARGS_LOG"
    SRVCTL_FM_PROBE_HTTPS_PORT="$1" SRVCTL_FM_PROBE_HTTP_PORT="$2" _domconf_fm_runtime_probe "${3:-example.com}"
    printf '%s' "$_FMRT_STATE"
}
# fx <kod> [gövde]: https sabit yanıt (gövde verilmezse otomatik imza; verilirse — boş dize dahil — aynen)
fx() {
    FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS="$1"; FM_PROBE_CODE_HTTP="000"
    unset FM_PROBE_BODY_HTTPS FM_PROBE_BODY_HTTP
    if (( $# >= 2 )); then FM_PROBE_BODY_HTTPS="$2"; fi
}

echo "── A: imza işlevi ve şablon sürümü ──"
assert_eq "$_DOMCONF_FM_TPL_VER" "4" "A1: _DOMCONF_FM_TPL_VER = 4 (imzalı şablon sürümü; 20 şablonunda ve kapalı kökte /__fm_ ad alanı yakalayıcısı)"
want=$(printf 'srvctl-fm-sig:v4:example_com' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)
assert_eq "$SIG" "$want" "A2: sig = ilk 12 hex sha256('srvctl-fm-sig:v4:example_com') (bağımsız hesap)"
assert_eq "${#SIG}" "12" "A3: sig 12 karakter"
hexok=0; [[ "$SIG" =~ ^[0-9a-f]{12}$ ]] && hexok=1
assert_eq "$hexok" "1" "A3: sig küçük harf hex"
assert_eq "$SIG" "be1fe5facfa8" "A4: example_com / v4 imzası SABİT (şablon sürümü ya da biçim sessizce değişemez)"
assert_eq "$([[ "$SIG" != "$SIG_O" ]] && echo farkli)" "farkli" "A5: farklı alan → farklı imza"
sig3=$( _DOMCONF_FM_TPL_VER=3; _domconf_fm_body_sig example_com )
assert_eq "$([[ "$sig3" != "$SIG" ]] && echo farkli)" "farkli" "A6: tpl_ver artınca imza değişir (eski şablon yeni imzayla karışmaz)"
for bad in "" 'a;b' 'a b' 'a.b' 'a/b' '-x' 'a"b' $'a\nb'; do
    o=$(_domconf_fm_body_sig "$bad"); rc=$?
    assert_eq "$rc|$o" "1|" "A7: güvensiz sname '${bad//$'\n'/\\n}' → rc 1, çıktı YOK"
done
o=$(_domconf_fm_body_sig); assert_eq "$?|$o" "1|" "A7: argümansız → rc 1, çıktı YOK"

echo "── B: üretilen şablonlar imzayı TAM taşır ──"
OFF=$(_domconf_fm_render_off example_com)
assert_eq "$(grep -c '^location' <<< "$OFF")" "3" "B1: kapalı kök tam üç location (/_fm, ^~ /_fm/ ve /__fm_ ad alanı yakalayıcısı)"
assert_contains "$OFF" "location ^~ /__fm_ { internal; return 403; }" "B1: '^~ /__fm_' yakalayıcı (iç istek 403; imzasız, durum kanıtı DEĞİL)"
assert_contains "$OFF" "location = /_fm { return 403 \"srvctl-fm-closed ${SIG}\"; }" "B1: '= /_fm' imzalı 403"
assert_contains "$OFF" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG}\"; }" "B1: '^~ /_fm/' imzalı 403"
assert_eq "$(grep -c 'srvctl-fm-closed' <<< "$OFF")" "2" "B1: imza yalnız bu iki yerde"
assert_eq "$(grep -c 'return' <<< "$OFF")" "3" "B1: kapalı kökte başka return yok (iki imzalı 403 + yakalayıcının imzasız 403'ü)"
o=$(_domconf_fm_render_off other_com)
assert_contains "$o" "srvctl-fm-closed ${SIG_O}" "B2: başka alanın kapalı kökü KENDİ imzasını taşır"
assert_not_contains "$o" "$SIG " "B2: ... ve example_com'unkini taşımaz"
o=$(_domconf_fm_render_off ''); assert_eq "$?|$o" "1|" "B3: sname boş → rc 1, çıktı YOK (boş dosya yazılmaz)"
o=$(_domconf_fm_render_off 'a;b'); assert_eq "$?|$o" "1|" "B3: güvensiz sname → rc 1, çıktı YOK"
UP=$(_domconf_fm_render_upload eu 1 example_com)
assert_eq "$(grep -c 'return 411' <<< "$UP")" "1" "B4: açık şablonda tek 411"
assert_contains "$UP" "if (\$http_content_length = \"\") { return 411 \"srvctl-fm-open ${SIG}\"; }" "B4: 411 gövdesi AÇIK imzası"
UPC=$(grep -v '^[[:space:]]*#' <<< "$UP")   # yalnız direktifler (yorumlar imza SÖZCÜĞÜNÜ anabilir; yanıt üretmez)
assert_eq "$(grep -c 'srvctl-fm-open' <<< "$UPC")" "1" "B4: AÇIK imzası (direktif olarak) yalnız 411'de"
assert_not_contains "$UPC" "srvctl-fm-closed" "B5: AÇIK şablonda KAPALI imzası YOK (açık dosya 'kapalı' kanıtı üretemez)"
assert_not_contains "$UP" "{{" "B5: beslenmeyen token yok"
n403=0
while IFS= read -r l; do
    [[ "$l" == *"return 403"* ]] || continue
    n403=$((n403 + 1))
    assert_not_contains "$l" "srvctl-fm-" "B6: açık şablondaki 403 satırı imzasız: ${l# }"
done <<< "$UPC"
assert_eq "$n403" "7" "B6: açık şablonda (yorum hariç) 7 satırda 403 (@fm_deny hata eşlemesi ve /__fm_ yakalayıcısı dahil) — hiçbirinde imza yok"
UPU=$(_domconf_fm_render_upload us 0 other_com)
assert_contains "$UPU" "srvctl-fm-open ${SIG_O}" "B7: us/modsec0/başka alan: imza o alanın"
o=$(_domconf_fm_render_upload eu 1 ''); assert_eq "$?|$o" "1|" "B8: sname'siz upload render REDDEDİLİR (imzasız açık dosya üretilemez)"
o=$(_domconf_fm_render_upload eu 1 'a;b'); assert_eq "$?|$o" "1|" "B8: güvensiz sname reddedilir"
o=$(_domconf_fm_render_upload eu 1); assert_eq "$?|$o" "1|" "B8: 3. argümansız çağrı reddedilir"
# yapısal: nginx sözcük çözümleyicisi imzalı gövdeyi tek bağımsız değişken olarak okur
printf '%s\n' "$OFF" > "${FM_STUBS}/off.conf"; fm_collect "${FM_STUBS}/off.conf"; assert_eq "$?" "0" "B9: kapalı kök lexer'dan geçer"
assert_eq "$(fm_has 'location = /_fm' "return 403 srvctl-fm-closed ${SIG}" && echo var)" "var" "B9: lexer 403 gövdesini tek argüman olarak görür"
printf '%s\n' "$UP" > "${FM_STUBS}/up.conf"; fm_collect "${FM_STUBS}/up.conf"; assert_eq "$?" "0" "B9: açık şablon lexer'dan geçer"

echo "── C: sonda sözleşmesi — YALNIZ imzalı (403|411) durum kanıtıdır ──"
fx 403;  assert_eq "$(probe 18901 off)" "closed" "C1: 403 + KAPALI imzası → closed"
fx 411;  assert_eq "$(probe 18901 off)" "open"   "C1: 411 + AÇIK imzası → open"
fx 403 "$CLOSED"; assert_eq "$(probe 18901 off)" "closed" "C1: açık gövde parametresiyle de closed"
fx 411 "$OPEN";   assert_eq "$(probe 18901 off)" "open"   "C1: açık gövde parametresiyle de open"
t() { # t <beklenen> <kod> <gövde> <ad>
    fx "$2" "$3"; assert_eq "$(probe 18901 off)" "$1" "$4"
}
t unknown 403 ""                                  "C2: imzasız (boş gövde) 403 → unknown (sunucu düzeyi 403 / başka vhost)"
t unknown 411 ""                                  "C2: imzasız 411 → unknown (köksüz alanda uygulamanın kendi 411'i)"
t unknown 403 "Forbidden"                         "C2: genel 403 sayfası → unknown"
t unknown 403 "<html>403 Forbidden</html>"        "C2: nginx varsayılan 403 HTML → unknown"
t unknown 403 "srvctl-fm-closed"                  "C3: imza eksik (sig yok) → unknown"
t unknown 403 "srvctl-fm-closed ${SIG:0:11}"      "C3: kısaltılmış imza → unknown"
t unknown 403 "srvctl-fm-closed ${SIG_O}"         "C3: BAŞKA alanın KAPALI imzası → unknown"
t unknown 411 "srvctl-fm-open ${SIG_O}"           "C3: BAŞKA alanın AÇIK imzası → unknown"
t unknown 403 "srvctl-fm-open ${SIG}"             "C4: 403 + AÇIK sözcüğü → unknown (kod/gövde çapraz eşleşmez)"
t unknown 411 "srvctl-fm-closed ${SIG}"           "C4: 411 + KAPALI sözcüğü → unknown"
for pair in "403:${CLOSED}:KAPALI" "411:${OPEN}:AÇIK"; do
    c5="${pair%%:*}"; rest="${pair#*:}"; w5="${rest%:*}"; n5="${rest##*:}"
    t unknown "$c5" "${w5} "                        "C5: ${n5} imza + sonda boşluk → unknown (TAM eşleşme)"
    t unknown "$c5" " ${w5}"                        "C5: ${n5} imza + başta boşluk → unknown"
    t unknown "$c5" "${w5}"$'\n'                    "C5: ${n5} imza + sonda satırsonu → unknown"
    t unknown "$c5" "x${w5}"                        "C5: ${n5} imza + önek → unknown"
    t unknown "$c5" "${w5}x"                        "C5: ${n5} imza + sonek → unknown"
    t unknown "$c5" "${w5}"$'\n'"${w5}"              "C5: ${n5} imza çift satır → unknown"
    t unknown "$c5" "$(printf '%s' "$w5" | tr a-z A-Z)" "C5: ${n5} imza büyük harf → unknown"
done
t unknown 403 "$(printf 'x%.0s' $(seq 1 1100))${CLOSED}" "C6: 1 KiB'den uzun gövde (--max-filesize) → unknown"
# imzalı gövde başka KODLARDA da kanıt değildir (R11 / C03: 404, 40x, 3xx, 5xx, 200, 000)
for c in 200 204 301 302 400 401 404 405 408 410 413 429 500 502 503 504 000; do
    t unknown "$c" "$CLOSED" "C7: ${c} + KAPALI imzalı gövde → unknown (yalnız 403)"
    t unknown "$c" "$OPEN"   "C7: ${c} + AÇIK imzalı gövde → unknown (yalnız 411)"
done
# koşu ayrıntısı: kod ve imza yokluğu söylenir
fx 403 ""; probe 18901 off >/dev/null
assert_contains "$_FMRT_DETAIL" "https:18901=403" "C8: ayrıntı kodu söyler"
assert_contains "$_FMRT_DETAIL" "imza" "C8: imza yokluğunu söyler (neden doğrulanamadığı belli)"
assert_contains "$_FMRT_DETAIL" "$SIG" "C8: beklenen imza ayrıntıda (operatör karşılaştırabilir)"
fx 403; probe 18901 off >/dev/null
assert_not_contains "$_FMRT_DETAIL" "imza (srvctl" "C8: kesin sonuçta 'imza yok' notu basılmaz"

echo "── D: şema sırası ve ulaşılamayan portlar ──"
FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=411; FM_PROBE_BODY_HTTPS="Forbidden"; unset FM_PROBE_BODY_HTTP
assert_eq "$(probe 18901 18902)" "open" "D1: https imzasız 403 (başka vhost) → http'ye geçilir, http imzalı 411 → open"
assert_eq "$(calls)" "2" "D1: iki şema da denendi"
probe 18901 18902 >/dev/null
assert_contains "$_FMRT_DETAIL" "https:18901=403 http:18902=411" "D1: ayrıntı iki şemayı sırayla yazar"
FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; unset FM_PROBE_BODY_HTTPS FM_PROBE_BODY_HTTP
assert_eq "$(probe 18901 18902)" "closed" "D2: https KESİN → http'ye hiç gidilmez"
assert_eq "$(calls)" "1" "D2: ilk kesin yanıtta durur (tek istek)"
FM_PROBE_CODE_HTTPS=000; FM_PROBE_CODE_HTTP=403
assert_eq "$(probe 18901 18902)" "closed" "D3: https bağlanamadı (000) → http imzalı 403 → closed"
FM_PROBE_CODE_HTTPS=403; FM_PROBE_BODY_HTTPS=""; FM_PROBE_CODE_HTTP=403; FM_PROBE_BODY_HTTP=""
assert_eq "$(probe 18901 18902)" "unknown" "D4: iki şema da imzasız → unknown"
probe 18901 18902 >/dev/null
assert_contains "$_FMRT_DETAIL" "https:18901=403 http:18902=403" "D4: iki şema ayrıntıda"
unset FM_PROBE_BODY_HTTPS FM_PROBE_BODY_HTTP
# C02: port "off"/geçersiz → şema ATLANIR (443/80'e düşülmez)
fx 403
assert_eq "$(probe off off)" "unknown" "D5: iki port off → unknown"
assert_eq "$(calls)" "0" "D5: iki port off → curl çağrısı 0 (443/80'e düşülmez)"
for bad in 0 abc -1 '12 3' '1.5' 'off ' 123456 '08080x'; do
    : > "$CURL_LOG"
    SRVCTL_FM_PROBE_HTTPS_PORT="$bad" SRVCTL_FM_PROBE_HTTP_PORT=off _domconf_fm_runtime_probe example.com
    assert_eq "$(calls)|$_FMRT_STATE" "0|unknown" "D6: geçersiz https portu '${bad}' atlanır (curl yok)"
done
fx 000; : > "$CURL_LOG"; ( unset SRVCTL_FM_PROBE_HTTPS_PORT SRVCTL_FM_PROBE_HTTP_PORT; _domconf_fm_runtime_probe example.com )
assert_contains "$(cat "$CURL_LOG")" "https://example.com:443/_fm/up/1/0" "D7: ortam yoksa varsayılan https 443"
assert_contains "$(cat "$CURL_LOG")" "http://example.com:80/_fm/up/1/0" "D7: ortam yoksa varsayılan http 80"
fx 000; : > "$CURL_LOG"; ( SRVCTL_FM_PROBE_HTTPS_PORT=; SRVCTL_FM_PROBE_HTTP_PORT=; _domconf_fm_runtime_probe example.com )
assert_contains "$(cat "$CURL_LOG")" "https://example.com:443/_fm/up/1/0" "D7: boş dize ortamı varsayılana döner (443)"
fx 000; : > "$CURL_LOG"
SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT=18903 _domconf_fm_runtime_probe example.com
assert_contains "$(cat "$CURL_LOG")" "http://example.com:18903/_fm/up/1/0 put=1 resolve=example.com:18903:127.0.0.1" "D8: SRVCTL_FM_PROBE_HTTP_PORT --resolve ile birlikte uygulanır"
assert_not_contains "$(cat "$CURL_LOG")" ":80/" "D8: ... ve 80'e gidilmez"
: > "$CURL_LOG"
SRVCTL_FM_PROBE_HTTPS_PORT=18904 SRVCTL_FM_PROBE_HTTP_PORT=off _domconf_fm_runtime_probe example.com
assert_contains "$(cat "$CURL_LOG")" "https://example.com:18904/_fm/up/1/0 put=1 resolve=example.com:18904:127.0.0.1" "D9: SRVCTL_FM_PROBE_HTTPS_PORT uygulanır"

echo "── E: yeniden deneme (settled) — RETRIES ──"
SEQ="${FM_STUBS}/seq"
settled() { # settled <RETRIES> → "durum|çağrı"
    : > "$CURL_LOG"
    SRVCTL_FM_PROBE_HTTPS_PORT=18905 SRVCTL_FM_PROBE_HTTP_PORT=off SRVCTL_FM_PROBE_RETRY_SLEEP=0 SRVCTL_FM_PROBE_RETRIES="$1" \
        _domconf_fm_runtime_probe_settled example.com
    printf '%s|%s' "$_FMRT_STATE" "$(calls)"
}
fx 411
assert_eq "$(settled 2)" "open|2" "E1: RETRIES=2 + sürekli AÇIK → 2 sonda (env uygulanır)"
assert_eq "$(settled 4)" "open|4" "E1: RETRIES=4 → 4 sonda"
assert_eq "$(settled 1)" "open|1" "E1: RETRIES=1 → tek sonda (yeniden deneme yok)"
assert_eq "$(settled 12)" "open|12" "E1: RETRIES=12 (2 basamak) uygulanır"
for bad in 0 abc '' -1 100 1.5 ' 2'; do
    assert_eq "$(settled "$bad")" "open|3" "E2: geçersiz RETRIES '${bad}' → varsayılan 3 (0 sonda DEĞİL)"
done
assert_eq "$(unset SRVCTL_FM_PROBE_RETRIES; : > "$CURL_LOG"; SRVCTL_FM_PROBE_HTTPS_PORT=18905 SRVCTL_FM_PROBE_HTTP_PORT=off SRVCTL_FM_PROBE_RETRY_SLEEP=0 _domconf_fm_runtime_probe_settled example.com; printf '%s|%s' "$_FMRT_STATE" "$(calls)")" "open|3" "E2: RETRIES tanımsız → 3"
fx 403
assert_eq "$(settled 5)" "closed|1" "E3: ilk sonda KAPALI → hemen durur (yeniden deneme yalnız AÇIK görülünce)"
fx 404 ""
assert_eq "$(settled 5)" "unknown|1" "E3: ilk sonda doğrulanamadı → durur (yeniden denenmez)"
# R09: reload sonrası worker'lar yenilenene dek AÇIK görülür, sonra KAPALI
FM_PROBE_MODE=fixed; unset FM_PROBE_BODY_HTTPS; FM_PROBE_SEQ="$SEQ"
printf '411\n411\n403\n' > "$SEQ"; FM_PROBE_CODE_HTTPS=403
assert_eq "$(settled 3)" "closed|3" "E4 (R09): AÇIK,AÇIK,KAPALI → yeniden deneme KAPALI'ya ulaşır (3 sonda)"
printf '411\n403\n' > "$SEQ"
assert_eq "$(settled 3)" "closed|2" "E4 (R09): AÇIK,KAPALI → 2. sondada durur"
printf '411\n411\n411\n403\n' > "$SEQ"
assert_eq "$(settled 3)" "open|3" "E4 (R09): RETRIES sınırı aşılmaz (3 AÇIK → open, 4. denenmez)"
unset FM_PROBE_SEQ

echo "── F: errexit altında sonda ÖLDÜRMEZ (R05) ──"
FM_PROBE_MODE=unknown
out=$( set -e; SRVCTL_FM_PROBE_HTTPS_PORT=18906 SRVCTL_FM_PROBE_HTTP_PORT=18907 _domconf_fm_runtime_probe example.com; echo "ULASILDI:${_FMRT_STATE}" ) 2>&1
assert_contains "$out" "ULASILDI:unknown" "F1: bağlantı yok (curl rc≠0) + 'set -e' → sonda sonrası kod çalışır"
out=$( set -euo pipefail; SRVCTL_FM_PROBE_HTTPS_PORT=18906 SRVCTL_FM_PROBE_HTTP_PORT=off _domconf_fm_runtime_probe_settled example.com; echo "ULASILDI:${_FMRT_STATE}" ) 2>&1
assert_contains "$out" "ULASILDI:unknown" "F2: 'set -euo pipefail' + settled: bin/srvctl ortamı"
FM_PROBE_MODE=silent
out=$( set -euo pipefail; SRVCTL_FM_PROBE_HTTPS_PORT=18906 SRVCTL_FM_PROBE_HTTP_PORT=off _domconf_fm_runtime_probe example.com; echo "ULASILDI:${_FMRT_STATE}|${_FMRT_DETAIL}" ) 2>&1
assert_contains "$out" "ULASILDI:unknown" "F3: curl HİÇ çıktı vermeden düşse de (rc 28) sonda sürer"
assert_contains "$out" "https:18906=000" "F3 (C08): çıktısız curl kodu '000' olarak kaydedilir (boş değil)"
FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS="abc"; unset FM_PROBE_BODY_HTTPS
probe 18906 off >/dev/null
assert_contains "$_FMRT_DETAIL" "https:18906=000" "F4 (C08): sayısal olmayan kod '000'a indirgenir"
assert_eq "$_FMRT_STATE" "unknown" "F4: sayısal olmayan kod → unknown"

echo "── G: curl yok (C05) ve güvensiz alan adı (C06) ──"
fx 403
(
    command() { if [[ "${1:-}" == "-v" && "${2:-}" == "curl" ]]; then return 1; fi; builtin command "$@"; }
    : > "$CURL_LOG"
    SRVCTL_FM_PROBE_HTTPS_PORT=18908 SRVCTL_FM_PROBE_HTTP_PORT=off _domconf_fm_runtime_probe example.com
    echo "${_FMRT_STATE}|$(calls)|${_FMRT_DETAIL}" > "${FM_STUBS}/nocurl.txt"
)
assert_eq "$(cut -d'|' -f1,2 "${FM_STUBS}/nocurl.txt")" "unknown|0" "G1: curl yoksa sonda çağırmaz (taklit KAPALI imzası verecekti) ve unknown"
assert_contains "$(cat "${FM_STUBS}/nocurl.txt")" "curl bulunamadı" "G1: ayrıntı 'curl bulunamadı'"
for d in 'example.com:443' 'a:b' '[::1]' '::1' 'a/b' 'a b' '-oevil' '' 'a_b.com' 'a;b.com' 'a$(x).com' 'a`x`.com' '.example.com' 'example.com.' 'a..b:80' $'a\nb.com' 'ex@mple.com' 'a,b.com' "a'b.com"; do
    : > "$CURL_LOG"; SRVCTL_FM_PROBE_HTTPS_PORT=18909 SRVCTL_FM_PROBE_HTTP_PORT=18910 _domconf_fm_runtime_probe "$d"
    assert_eq "$_FMRT_STATE|$(calls)" "unknown|0" "G2 (C06): alan adı '${d//$'\n'/\\n}' → curl çağrılmaz"
done
assert_contains "$_FMRT_DETAIL" "güvenli değil" "G2: ayrıntı nedeni söyler"
for d in example.com a-b.example.co.uk X1.test 1.invalid; do
    : > "$CURL_LOG"; fx 403 "x"; SRVCTL_FM_PROBE_HTTPS_PORT=18909 SRVCTL_FM_PROBE_HTTP_PORT=off _domconf_fm_runtime_probe "$d"
    assert_eq "$(calls)" "1" "G3: geçerli alan adı '${d}' sondalanır"
done

echo "── H: curl bayrakları (R01 R02 R03 — sonda dışarı çıkmaz, askıda kalmaz) ──"
fx 403; probe 18911 off >/dev/null
A=$(cat "$CURL_ARGS_LOG")
assert_eq "$(grep -c . "$CURL_ARGS_LOG")" "1" "H0: tek istek, tek curl satırı"
assert_contains "$A" "--noproxy *" "H1 (R01): --noproxy '*' (ortam proxy'si 127.0.0.1 sondasını dışarı taşımaz)"
assert_contains "$A" "--connect-timeout 2" "H2 (R02): bağlantı zaman aşımı 2 sn"
assert_contains "$A" "--max-time 5" "H2 (R02): toplam zaman aşımı 5 sn"
assert_contains "$A" "--path-as-is" "H3 (R03): --path-as-is"
assert_contains "$A" "-X PUT" "H4: PUT"
assert_contains "$A" "-H Expect:" "H4: Expect başlığı boş (100-continue beklenmez)"
assert_contains "$A" "--resolve example.com:18911:127.0.0.1" "H5: --resolve yalnız 127.0.0.1"
assert_contains "$A" "https://example.com:18911/_fm/up/1/0" "H5: hedef URL"
assert_contains "$A" "--max-filesize 1024" "H6: gövde üst sınırı"
assert_contains "$A" "-o -" "H7: gövde stdout'ta (imza okunur)"
assert_contains "$A" "-w \\n%{http_code}" "H7: durum kodu gövdeden sonra yazılır"
for x in " -d " "--data" " -T " "--upload-file" " -F " "-L" "--location" "-u " "-H Authorization" "-H Cookie" "-b " "--proxy "; do
    assert_not_contains " $A" "$x" "H8: sonda gövde/kimlik/yönlendirme taşımaz: '${x}'"
done
assert_eq "$(grep -c '^DENY' "$CURL_LOG")|$(grep -v 'resolve=[^ ]*:127.0.0.1$' "$CURL_LOG" | grep -c .)" "0|0" "H9: DENY 0, her istek --resolve …:127.0.0.1 taşır (dışarı istek yok)"

echo "── I: uçtan uca — gerçek üretilmiş dosya ↔ sonda (imza tutarlılığı) ──"
_fm_reset; FM_PROBE_MODE=sim; _on
assert_eq "$?" "0" "I0: fm-auth on rc 0"
assert_contains "$(cat "$F20")" "return 411 \"srvctl-fm-open ${SIG}\"" "I1: diske yazılan 20: AÇIK imzası"
assert_eq "$(sed -n 's/^tpl_ver //p' "$MAN")" "${_DOMCONF_FM_TPL_VER}" "I1: köken kaydı tpl_ver (güncel şablon sürümü)"
assert_eq "$(probe 18912 off)" "open" "I2: çalışan (reload edilmiş) AÇIK dosya → sonda open"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "I3: status rc 0 (disk AÇIK + çalışan AÇIK, tutarlı)"
assert_contains "$out" "AÇIK imzası (411) — diskle tutarlı" "I3: status çalışan AÇIK imzasını söyler"
assert_eq "$(probe 18912 off other.com)" "unknown" "I4: BAŞKA alan adı aynı çalışan dosyaya sorulunca unknown (örnek: SSL'siz alanın 443'te başka vhost'a düşmesi)"
_e; assert_eq "$?" "0" "I5: normal off rc 0"
assert_contains "$(cat "$F20")" "return 403 \"srvctl-fm-closed ${SIG}\"" "I5: diske yazılan 20: KAPALI imzası"
assert_eq "$(probe 18912 off)" "closed" "I6: reload sonrası sonda closed"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "I7: status rc 0 (disk KAPALI + çalışan KAPALI)"
assert_contains "$out" "KAPALI imzası (403) — diskle tutarlı" "I7: status çalışan KAPALI imzasını söyler"
assert_eq "$(probe 18912 off other.com)" "unknown" "I8: başka alan adı → unknown"
# eski (v1) imzasız kapalı kök çalışıyorsa: KAPALI uydurulmaz
printf 'location = /_fm { return 403; }\nlocation ^~ /_fm/ { return 403; }\n' > "$F20"; fm_sim_reload
assert_eq "$(probe 18912 off)" "unknown" "I9: v1 (imzasız) kapalı kök çalışıyor → unknown (KAPALI uydurulmaz)"
# eski (v1) imzasız AÇIK şablon: AÇIK uydurulmaz ama status'ta sürüm ipucu
_fm_reset; FM_PROBE_MODE=sim; _on
sed -i.b 's/return 411 "srvctl-fm-open [0-9a-f]*"/return 411/' "$F20"; rm -f "${F20}.b"; fm_sim_reload
assert_eq "$(probe 18912 off)" "unknown" "I10: imzasız 411 çalışıyor → unknown"
sed -i.b "s/^tpl_ver ${_DOMCONF_FM_TPL_VER}\$/tpl_ver 1/" "$MAN"; rm -f "${MAN}.b"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "çalışan durum DOĞRULANAMADI" "I11: status 'doğrulanamadı' der"
assert_contains "$out" "tpl_ver 1" "I11: eski şablon sürümü ipucu (kayıt tpl_ver 1 ≠ 2)"
assert_contains "$out" "fm-root example.com --apply" "I11: yenileme komutu önerilir"
assert_not_contains "$out" "KAPALI imzası" "I11: 'KAPALI imzası' uydurulmaz"
assert_not_contains "$out" "AÇIK imzası" "I11: 'AÇIK imzası' uydurulmaz"
_fm_reset; FM_PROBE_MODE=sim; _on
out=$(_domconf_fm_auth example.com status 2>&1)
assert_not_contains "$out" "güncel değil" "I12: tpl_ver güncelken sürüm ipucu YOK"

echo "── J: L6 — köksüz/kayıtsız alanda yanıltıcı ikinci uyarı yok ──"
_fm_reset
fx 411 ""
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "J1: kayıtsız alan: status rc 1 ('YOK')"
assert_not_contains "$out" "FM HÂLÂ AÇIK" "J1: uygulamanın kendi 411'i (imzasız) → 'FM HÂLÂ AÇIK' BASILMAZ"
assert_not_contains "$out" "AÇIK imzası" "J1: ... 'AÇIK imzası' da değil"
assert_contains "$out" "srvctl FM imzası" "J1: 'imza alınmadı / doğrulanamadı' söylenir"
fx 403 ""
out=$(_domconf_fm_auth example.com status 2>&1)
assert_not_contains "$out" "KAPALI imzası" "J2: uygulamanın kendi 403'ü (imzasız) → 'KAPALI imzası' BASILMAZ"
assert_contains "$out" "srvctl FM imzası" "J2: 'imza alınmadı' söylenir"
fx 411
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "J3: kayıtsız alanda İMZALI AÇIK yanıt: rc 1"
assert_contains "$out" "FM HÂLÂ AÇIK" "J3: gerçek srvctl AÇIK imzası → alarm kalır (kayıt/disk yok ama çalışan açık)"
# SSL'siz alan: https başka vhost'un imzasız 403'ü, http alanın kendi KAPALI kökü
_fm_reset; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_BODY_HTTPS="Forbidden"; FM_PROBE_CODE_HTTP=403
_on; _e
SRVCTL_FM_PROBE_HTTPS_PORT=18913 SRVCTL_FM_PROBE_HTTP_PORT=18914 out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "KAPALI imzası (403)" "J4: https yabancı 403 → http alanın kendi imzası: KAPALI doğrulanır"
assert_contains "$out" "https:18913=403 http:18914=403" "J4: ayrıntı iki şemayı yazar"
# yalnız yabancı 403 (SSL'siz alan, http yok)
FM_PROBE_CODE_HTTP=000
SRVCTL_FM_PROBE_HTTPS_PORT=18913 SRVCTL_FM_PROBE_HTTP_PORT=18914 out=$(_domconf_fm_auth example.com status 2>&1)
assert_not_contains "$out" "KAPALI imzası" "J5: yalnız yabancı vhost 403'ü → KAPALI sayılmaz (QL7-M1)"
assert_contains "$out" "çalışan durum DOĞRULANAMADI" "J5: 'doğrulanamadı'"

echo "── K: R07 — .superseded eşiği sınırı (> eşik uyarı; = eşik bilgi) ──"
_fm_reset; FM_PROBE_MODE=unknown; _on
mk_sup() { local i; rm -rf "$SD"/.superseded.bk.example_com.*; for ((i = 1; i <= $1; i++)); do mkdir -p "$SD/.superseded.bk.example_com.S0000${i}"; done; }
assert_eq "$_FMP_SUPERSEDED_WARN" "5" "K0: eşik 5"
mk_sup 5
assert_not_contains "$(_fmprov_superseded_note example_com)" "SAYI EŞİĞİ" "K1: tam eşikte (5) not uyarı eşiğini AŞMAZ"
mk_sup 6
assert_contains "$(_fmprov_superseded_note example_com)" "SAYI EŞİĞİ (5) AŞILDI" "K1: eşik+1'de (6) 'SAYI EŞİĞİ AŞILDI'"
mk_sup 5
err=$(_domconf_fm_auth example.com status 2>&1 >/dev/null); outp=$(_domconf_fm_auth example.com status 2>/dev/null)
assert_not_contains "$err" "ayrılmış (.superseded.bk.*)" "K2: tam eşikte status notu UYARI (stderr) DEĞİL"
assert_contains "$outp" "5 adet ayrılmış (.superseded.bk.*)" "K2: ... bilgi (stdout) olarak basılır"
mk_sup 6
err=$(_domconf_fm_auth example.com status 2>&1 >/dev/null)
assert_contains "$err" "6 adet ayrılmış (.superseded.bk.*)" "K2: eşik+1'de status notu UYARI (stderr)"
mk_sup 0

echo "── L: R08 — acil kapatma sırası: 403 kökü, auth/indirme dosyaları devre dışı kalmadan ÖNCE yazılır ──"
_fm_reset; FM_PROBE_MODE=sim; _on
ORDER="${FM_STUBS}/order.log"; : > "$ORDER"
eval "$(declare -f _domconf_fm_em_disable | sed '1s/.*/_orig_em_disable ()/')"
_domconf_fm_em_disable() {
    local st="A"
    [[ -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]] && st="K"
    echo "disable ${1##*/} f20=${st}" >> "$ORDER"
    _orig_em_disable "$@"
}
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$ORDER"
_domconf_fm_em_close_disk "$CUR_DIR" example_com; rc=$?
assert_eq "$rc|$_FME_DISK" "0|closed" "L1: disk kapatıldı"
assert_eq "$(grep -c '^disable' "$ORDER")" "2" "L1: 90 ve 21 devre dışı bırakıldı"
assert_eq "$(grep -c 'f20=K$' "$ORDER")" "2" "L1 (R08): 90/21 devre dışı bırakılırken 20 ZATEN imzalı 403 kökü (arada kesinti açık vekil bırakmaz)"
assert_eq "$(grep -c 'f20=A$' "$ORDER")" "0" "L1 (R08): hiçbir devre dışı bırakma 'açık 20' durumunda olmadı"
unset -f _domconf_fm_em_disable; eval "$(declare -f _orig_em_disable | sed '1s/.*/_domconf_fm_em_disable ()/')"
# render başarısızsa (güvensiz sname) BOŞ 20 yazılmaz
_fm_reset; FM_PROBE_MODE=sim; _on
_domconf_fm_em_close_disk "$CUR_DIR" 'bad;name'; rc=$?
assert_eq "$_FME_DISK" "partial" "L2: imza üretilemezse disk 'partial' (kapalı DEĞİL)"
assert_eq "$(_exists "$F20")" "yok" "L2: boş/imzasız 20 YAZILMADI; eski açık 20 devre dışı bırakıldı"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "L2: 90/21 yine de devre dışı"
assert_eq "$(find "$CUR_DIR" -maxdepth 1 -name '*.conf' -size 0 | wc -l | tr -d ' ')" "0" "L2: sıfır baytlık .conf yok"
_fm_reset; FM_PROBE_MODE=sim; _on
_domconf_fm_em_close_disk "$CUR_DIR"; assert_eq "$_FME_DISK" "partial" "L3: sname verilmeden çağrı da imzasız kök yazmaz (partial)"
assert_eq "$(_exists "$F20")" "yok" "L3: imzasız 20 yok"

echo "── M: acil kapatma dosyası imzalıdır ve ardından sonda KAPALI görür ──"
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$RELOAD_LOG"
_e --emergency; rc=$?
assert_eq "$rc" "0" "M1: acil kapatma rc 0"
assert_eq "$(cat "$F20")" "$(_domconf_fm_render_off example_com)" "M1: acil yolun yazdığı 20 = imzalı kapalı kök (BAYT-BAYT)"
assert_contains "$(_out)" "sonda 403" "M1: sonda imzalı 403'ü KAPALI diye okudu"
SRVCTL_FM_PROBE_HTTPS_PORT=18915 SRVCTL_FM_PROBE_HTTP_PORT=off out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "KAPALI imzası (403)" "M2: status aynı sondayı kullanır"
# acil yol: çalışan nginx eski yapılandırmada → imzalı AÇIK
_fm_reset; FM_PROBE_MODE=sim; _on; SYSTEMCTL_RC=1
_e --emergency; rc=$?
assert_eq "$rc" "3" "M3: reload yok + çalışan imzalı AÇIK → rc 3"
assert_contains "$(_out)" "FM HÂLÂ AÇIK" "M3: 'FM HÂLÂ AÇIK'"
# acil yol: sunucu düzeyi imzasız 403 → KAPALI sayılmaz
_fm_reset; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_BODY_HTTPS="Forbidden"; _on
SYSTEMCTL_RC=1; _e --emergency; rc=$?
assert_eq "$rc" "4" "M4: reload başarısız + sonda imzasız 403 → rc 4 (doğrulanamadı; KAPALI sayılmaz)"
assert_not_contains "$(_out)" "çalışan nginx de KAPALI imzası" "M4: 'KAPALI imzası' denmez"

echo "── N: v1 → v2 geçişi — eski (imzasız) kurulum fm-root --apply ile imzalıya yükselir ──"
_fm_reset; FM_PROBE_MODE=sim; _on
# kurulumu v1 biçimine çevir: imzasız 411, kayıtta tpl_ver 1 ve v1 özeti (srvctl'in v1 sürümünün yazacağı hâl)
sed -i.b 's/return 411 "srvctl-fm-open [0-9a-f]*"/return 411/' "$F20"; rm -f "${F20}.b"
h1=$(_domconf_sha256_file "$F20")
sed -i.b -e "s/^tpl_ver ${_DOMCONF_FM_TPL_VER}\$/tpl_ver 1/" -e "s/^sha256 [0-9a-f]* ${_DOMCONF_FM_UP_FILE}\$/sha256 ${h1} ${_DOMCONF_FM_UP_FILE}/" "$MAN"; rm -f "${MAN}.b"; fm_sim_reload
assert_eq "$(probe 18916 off)" "unknown" "N1: v1 açık kurulum: sonda AÇIK uydurmaz (unknown)"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "tpl_ver 1" "N1: status sürüm ipucunu verir"
( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; assert_eq "$?" "0" "N2: fm-root --apply rc 0"
assert_contains "$(cat "$F20")" "return 411 \"srvctl-fm-open ${SIG}\"" "N2: 20 imzalı AÇIK şablonla yeniden üretildi"
assert_eq "$(sed -n 's/^tpl_ver //p' "$MAN")" "${_DOMCONF_FM_TPL_VER}" "N2: kayıt tpl_ver (güncel şablon sürümü)"
assert_contains "$(cat "$MAN")" "$(_domconf_sha256_file "$F20") ${_DOMCONF_FM_UP_FILE}" "N2: kayıttaki 20 özeti yeni dosyayla eşit"
assert_contains "$(cat "$MAN")" "state on" "N2: açık alan AÇIK kaldı (yükseltme durumu değiştirmez)"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "varvar" "N2: 90/21 yerinde"
assert_eq "$(probe 18916 off)" "open" "N3: reload sonrası sonda imzalı AÇIK görür"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "N3: status rc 0"
assert_not_contains "$out" "güncel değil" "N3: sürüm ipucu kalktı"
# v1 KAPALI kök (off): yükseltme imzalı kökü yazar, KAPALI kalır
_fm_reset; FM_PROBE_MODE=sim; _on; _e
printf '# srvctl: FileManager yükleme yolu KAPALI (srvctl domain fm-auth <alan> off). SRVCTL ÜRETİR.\n# Bu 403 kökü, /_fm/ yolunun CI4'"'"'e düşmesini engeller; açmak için: fm-auth <alan> on --script=...\nlocation = /_fm { return 403; }\nlocation ^~ /_fm/ { return 403; }\n' > "$F20"
h1=$(_domconf_sha256_file "$F20")
sed -i.b -e "s/^tpl_ver ${_DOMCONF_FM_TPL_VER}\$/tpl_ver 1/" -e "s/^sha256 [0-9a-f]* ${_DOMCONF_FM_UP_FILE}\$/sha256 ${h1} ${_DOMCONF_FM_UP_FILE}/" "$MAN"; rm -f "${MAN}.b"; fm_sim_reload
assert_eq "$(probe 18916 off)" "unknown" "N4: v1 kapalı kök: sonda KAPALI uydurmaz (unknown) — status 'doğrulanamadı' der"
( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; assert_eq "$?" "0" "N5: fm-root --apply rc 0 (kapalı alan)"
assert_eq "$(cat "$F20")" "$(_domconf_fm_render_off example_com)" "N5: 20 imzalı kapalı kök"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "N5: KAPALI alan AÇILMADI"
assert_eq "$(probe 18916 off)" "closed" "N5: reload sonrası sonda imzalı KAPALI görür"

test_summary
