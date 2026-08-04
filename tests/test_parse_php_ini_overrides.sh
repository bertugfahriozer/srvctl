#!/bin/bash
# parse_php_ini_overrides — per-domain .ini sözdizimi kapısı.
#
# GÜVENLİK: değer pool config'ine DOĞRUDAN basılıyor. Değerde satır sonu
# karakteri kabul edilirse operatör (ya da .ini'yi yazabilen herhangi bir
# şey) 'user = root' gibi KEYFİ bir FPM direktifi enjekte edebilir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

TMP="$(mktemp -d)"
w() { printf '%b' "$1" > "${TMP}/t.ini"; }

echo "── Bölüm A: geçerli girdi ──"
w 'memory_limit = 512M\n; yorum\n\nmax_execution_time=120\n'
out=$(parse_php_ini_overrides "${TMP}/t.ini"); rc=$?
assert_eq "$rc" "0" "geçerli dosya kabul edilir"
assert_contains "$out" "memory_limit=512M" "değer boşluk kırpılarak çıkar"
assert_contains "$out" "max_execution_time=120" "boşluksuz '=' kabul edilir"
assert_not_contains "$out" "yorum" "; yorumları atlanır"

w '# diyez yorumu\nopcache.memory_consumption = 256\n'
out=$(parse_php_ini_overrides "${TMP}/t.ini")
assert_contains "$out" "opcache.memory_consumption=256" "noktalı anahtar kabul edilir"
assert_not_contains "$out" "diyez" "# yorumları atlanır"

echo "── Bölüm B/C: güvenlik ve sözdizimi reddi ──"
# Her satır: <girdi>|<açıklama>. Hepsi 1 (reddedildi) dönmeli.
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    w "$payload"
    parse_php_ini_overrides "${TMP}/t.ini" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "$desc"
done <<'CASES'
memory_limit = 512M\ruser = root\n|değerde CR → reddedilir (direktif enjeksiyonu)
memory_limit = {{PM_MODE}}\n|değerde '{{' → reddedilir (token karışması)
[www]\nmemory_limit = 512M\n|[section] başlığı reddedilir
memory_limit\n|'=' içermeyen satır reddedilir
memory_limit =\n|boş değer reddedilir
memory_limit = 512M\nmemory_limit = 256M\n|çift anahtar reddedilir
1invalid = x\n|rakamla başlayan anahtar reddedilir
CASES

echo "── Bölüm D: kenar durumlar ──"
: > "${TMP}/t.ini"
out=$(parse_php_ini_overrides "${TMP}/t.ini"); rc=$?
assert_eq "$rc" "0" "boş dosya geçerli"
assert_eq "$out" "" "boş dosya boş çıktı verir"

w '; sadece yorum\n'
out=$(parse_php_ini_overrides "${TMP}/t.ini")
assert_eq "$out" "" "yalnız yorum içeren dosya boş çıktı verir"

# Son satırda newline YOK — 'read' bu satırı kaybetmemeli
printf 'memory_limit = 512M' > "${TMP}/t.ini"
out=$(parse_php_ini_overrides "${TMP}/t.ini")
assert_contains "$out" "memory_limit=512M" "son satırda newline olmasa da okunur"

# CRLF dosyası: satır sonu CR'ı kırpılmalı, değere sızmamalı
printf 'memory_limit = 512M\r\n' > "${TMP}/t.ini"
out=$(parse_php_ini_overrides "${TMP}/t.ini"); rc=$?
assert_eq "$rc" "0" "CRLF dosyası kabul edilir (satır sonu CR'ı kırpılır)"
assert_eq "$out" "memory_limit=512M" "CRLF sonrası değerde CR kalmaz"

# Hata mesajı satır numarası içermeli (operatör hangi satırı düzeltecek?)
w 'memory_limit = 512M\n[www]\n'
err=$(parse_php_ini_overrides "${TMP}/t.ini" 2>&1 >/dev/null)
assert_contains "$err" "satır 2" "hata mesajı satır numarası içerir"

test_summary
