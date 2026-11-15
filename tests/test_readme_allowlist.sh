#!/bin/bash
# README.md "custom.d izin listesi" tablosu = lib/nginx_allow.sh (bire bir).
# Kilitlenenler: (1) tablodaki direktif kümesi = kodun direktif tablosundaki `case` etiketleri,
# (2) her satırın BAĞLAM harfleri = koddaki _ngxallow_ctx_ok harfleri, (3) limit_req zone kümesi =
# koddaki kapalı küme ve conn_per_ip limit_req satırında YOK, limit_conn satırında VAR,
# (4) README'deki her sayısal tavan koddaki sabitle aynı.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
set +e
README="${REPO_ROOT}/README.md"
CODE="${REPO_ROOT}/lib/nginx_allow.sh"
[[ -n "${ALLOW_README:-}" ]] && README="$ALLOW_README"   # mutasyon kancası
[[ -n "${ALLOW_CODE:-}" ]] && CODE="$ALLOW_CODE"

# README tablo satırları: "| `ad`[, `ad2`] [(blok)] | CTX | kısıt |"
rows=$(awk '/^\| İzinli direktif \| Bağlam \| Kısıt \|/{t=1;next} t&&/^\|---/{next} t&&/^\|/{print;next} t&&!/^\|/{t=0}' "$README")
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
assert_ne "$rows" "" "README tablosu bulundu (başlık: İzinli direktif | Bağlam | Kısıt)"

# README -> "direktif ctx" çiftleri
rd=$(printf '%s\n' "$rows" | awk -F'|' '{
  c=$2; ctx=$3; gsub(/ /,"",ctx);
  n=split(c, a, "`");
  for(i=2;i<=n;i+=2){ if(a[i]!="") print a[i], ctx }
}' | sort)
# kod -> direktif etiketleri + ilk _ngxallow_ctx_ok harfleri
cd_=$(awk '
  /# ── direktif tablosu ──/ {t=1; next}
  t && /^    [a-z_|]+\)$/ { lab=$1; sub(/\)$/,"",lab); got=0; next }
  t && lab!="" && !got && /_ngxallow_ctx_ok [A-Z]+/ { match($0,/_ngxallow_ctx_ok [A-Z]+/); s=substr($0,RSTART+17,RLENGTH-17); n=split(lab,b,"|"); for(i=1;i<=n;i++) print b[i], s; got=1 }
  t && /^    \*\)$/ { t=0 }
' "$CODE" | sort)
assert_ne "$cd_" "" "koddan direktif+bağlam çıkarıldı"
assert_ne "$rd" "" "README'den direktif+bağlam çıkarıldı"
echo "── 1+2: direktif kümesi ve bağlam harfleri bire bir ──"
only_r=$(comm -23 <(printf '%s\n' "$rd") <(printf '%s\n' "$cd_"))
only_c=$(comm -13 <(printf '%s\n' "$rd") <(printf '%s\n' "$cd_"))
assert_eq "$only_r" "" "README'de olup kodda (aynı bağlamla) olmayan satır YOK"
assert_eq "$only_c" "" "kodda olup README'de (aynı bağlamla) olmayan direktif YOK"
assert_eq "$(printf '%s\n' "$rd" | wc -l | tr -d ' ')" "$(printf '%s\n' "$cd_" | wc -l | tr -d ' ')" "direktif sayısı eşit"

echo "── 3: limit_req zone kümesi + conn_per_ip ──"
rz=$(printf '%s\n' "$rows" | grep '^| `limit_req` |' | sed 's/.*kapalı küme\*\*: //; s/ *|.*//' | tr -d '`.' | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
cz=$(grep -o 'zone=[a-z_]*|' "$CODE" | head -1 >/dev/null; grep 'zone=rl_strict|' "$CODE" | head -1 | tr -d ' ' | sed 's/).*//' | tr '|' '\n' | sed 's/^zone=//' | sort | tr '\n' ' ')
assert_ne "$rz" "" "README zone listesi çıkarıldı"
assert_eq "$rz" "$cz" "limit_req zone kümesi README = kod"
reqrow=$(printf '%s\n' "$rows" | grep '^| `limit_req` |')
connrow=$(printf '%s\n' "$rows" | grep '^| `limit_conn` |')
assert_eq "$([[ "$reqrow" == *"zone=conn_per_ip"* || "$rz" == *conn_per_ip* ]] && echo var || echo yok)" "yok" "conn_per_ip limit_req zone'u olarak YAZILMAMIŞ"
assert_contains "$connrow" 'limit_conn conn_per_ip N' "conn_per_ip limit_conn satırında"
assert_contains "$(grep -n 'limit_req_zone\|limit_conn_zone' "${REPO_ROOT}/lib/init.sh" | grep conn_per_ip)" "limit_conn_zone" "init.sh'ta conn_per_ip bir limit_conn_zone"
# kod: her README zone'u init.sh'ta limit_req_zone olarak tanımlı
miss=""; for z in $rz; do grep -q "limit_req_zone .*zone=${z}:" "${REPO_ROOT}/lib/init.sh" || miss+="$z "; done
assert_eq "$miss" "" "README'deki her limit_req zone'u init.sh'ta tanımlı"

echo "── 4: sayısal tavanlar README = kod (TAM sayı; alt dizgi iğnesi DEĞİL — rev-L3) ──"
# rev-L3: eski iğneler alt dizgiydi: "nargs > 16" → "nargs > 160", "nst > 4" → "nst > 40",
# "${#t} > 1024" → "> 10240", "_NGXALLOW_MAX_BYTES=32768" → "=327680", README "blok derinliği 4" →
# "… 40" de geçerdi. Şimdi: koddaki TAM ifade ve README cümlesi ayrı ayrı TEK kez bulunur, içindeki
# sayı çıkarılır; ikisi birbirine VE beklenen değere eşit olmalı.
_num() { # $1=metin $2=ERE → TEK eşleşmedeki son sayı; eşleşme sayısı 1 değilse "eşleşme=<n>"
    local m c
    m=$(printf '%s\n' "$1" | grep -Eo -- "$2")
    c=$(printf '%s' "$m" | grep -c .)
    if [[ "$c" != "1" ]]; then printf 'eşleşme=%s' "$c"; return 0; fi
    printf '%s' "$m" | grep -Eo '[0-9]+' | tail -1
}
_cap() { # $1=açıklama $2=beklenen $3=kod ERE $4=README ERE [$5=README çarpanı (KiB → bayt)]
    local c r
    c=$(_num "$CODE_TXT" "$3"); r=$(_num "$sec" "$4")
    if [[ -n "${5:-}" && "$r" =~ ^[0-9]+$ ]]; then r=$(( r * $5 )); fi
    assert_eq "$c" "$2" "kod: ${1} = ${2} (tam ifade: ${3})"
    assert_eq "$r" "$2" "README: ${1} = ${2} (${4})"
}
CODE_TXT=$(cat "$CODE")
sec=$(awk '/^### `custom.d` izin listesi/{t=1} t{print} /^```bash/{if(t&&++c==1)exit}' "$README")
_cap "dosya bayt tavanı"        32768 '^_NGXALLOW_MAX_BYTES=[0-9]+$'          'dosya [0-9]+ KiB' 1024
_cap "dosya başına ifade"       2048  '^_NGXALLOW_MAX_STMT=[0-9]+$'           'en çok [0-9]+ ifade'
_cap "ifade başına argüman"     16    '\(\( nargs > [0-9]+ \)\)'              'en çok [0-9]+ argüman'
_cap "blok derinliği"           4     '\(\( nst > [0-9]+ \)\); then$'         'blok derinliği [0-9]+'
_cap "belirteç baytı"           1024  '\(\( \$\{#t\} > [0-9]+ \)\)'           'belirteç [0-9]+'
_cap "regex uzunluğu"           200   '\(\( n > [0-9]+ \)\)'                  '≤[0-9]+ karakter'
_cap "sınırsız nicelik"         3     '\(\( unb > [0-9]+ \)\)'                '>[0-9]+ sınırsız nicelik'
_cap "{n,m} değeri"             255   '^_NGXALLOW_RX_DUP_MAX=[0-9]+$'         'değerleri en çok [0-9]+'
_cap "sonda ayrıştırma bütçesi" 64    '^_NGXALLOW_PROBE_ID_MAX=[0-9]+$'       'en çok [0-9]+ `grep`'
assert_contains "$sec" "burst=N\` (1-99999)" "README burst 1-99999 der"; assert_contains "$(cat "$CODE")" '^burst=[1-9][0-9]{0,4}$' "kod: burst 1-99999"

echo "── 5: yasak dizgi listesi README = kod ──"
pat=$(grep -m1 '__fm_\*|' "$CODE" | tr -d ' \t' | sed 's/).*//' | tr '|' '\n' | sed 's/^\*//; s/\*$//; s/\\//g' | sort)
for tok in $pat; do
    assert_contains "$sec" "$tok" "README yasak dizgi listesinde: ${tok}"
done
test_summary
