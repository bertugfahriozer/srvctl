#!/bin/bash
# 'domain reload' — hedef seçimi, --all'da devam-et politikası, nginx'in
# BİR KEZ reload edilmesi.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

mkdir -p "${WEB_ROOT}/a.com" "${WEB_ROOT}/b.com"
touch "${WEB_ROOT}/a.com/.credentials" "${WEB_ROOT}/b.com/.credentials"

_derive_php() { echo "8.3"; }
NGINX_RELOADS=0
NGINX_TEST_RC=0
nginx() { [[ "$1" == "-t" ]] && return "$NGINX_TEST_RC"; return 0; }
systemctl() { [[ "$1" == "reload" && "$2" == "nginx" ]] && NGINX_RELOADS=$((NGINX_RELOADS+1)); return 0; }

FAIL_FOR=""
reload_domain_fpm() { [[ "$1" == "$FAIL_FOR" ]] && return 1; return 0; }
domain_fpm_unit() { echo "srvctl-fpm-$1.service"; }

source "${REPO_ROOT}/lib/domconf.sh"

echo "── Bölüm A: tek domain ──"
NGINX_RELOADS=0
_domconf_reload a.com >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "sağlıklı domain → 0"
assert_eq "$NGINX_RELOADS" "1" "varsayılanda nginx de reload edilir"

NGINX_RELOADS=0
_domconf_reload a.com --fpm >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--fpm → yalnız FPM, exit 0"
assert_eq "$NGINX_RELOADS" "0" "--fpm ile nginx reload edilmez"

FAIL_FOR="a_com"
out=$( _domconf_reload a.com 2>&1 ); rc=$?
assert_eq "$rc" "1" "FPM reload başarısız → exit 1"
FAIL_FOR=""

echo "── Bölüm B: --all devam-et politikası ──"
# b.com başarısız olsa BİLE a.com işlenmeli; komut yine non-zero dönmeli.
#
# DİKKAT: NGINX_RELOADS sayacını ölçen çağrılar ANA KABUKTA yapılmalı.
# 'out=$( _domconf_reload ... )' bir komut ikamesidir → alt kabukta koşar →
# sayaç artışı ana kabuğa YANSIMAZ ve "0 reload" gibi YANLIŞ bir ölçüm verir
# (bu tuzak testin ilk halinde Bölüm C'yi yanlış sebeple geçirmişti).
# Çözüm: çıktıyı geçici dosyaya yönlendir, fonksiyonu doğrudan çağır.
OUT_F="$(mktemp)"
FAIL_FOR="b_com"
NGINX_RELOADS=0
_domconf_reload --all > "$OUT_F" 2>&1; rc=$?
out=$(cat "$OUT_F")
assert_eq "$rc" "1" "--all: bir domain başarısızsa exit 1"
assert_contains "$out" "b.com" "başarısız domain özette adıyla raporlanır"
assert_contains "$out" "a.com" "sağlıklı domain YİNE DE işlendi (devam-et politikası)"
assert_eq "$NGINX_RELOADS" "1" "--all: nginx domain başına DEĞİL, BİR KEZ reload edilir"
FAIL_FOR=""

echo "── Bölüm C: nginx -t başarısız ──"
NGINX_TEST_RC=1; NGINX_RELOADS=0
_domconf_reload --all > "$OUT_F" 2>&1; rc=$?
assert_eq "$NGINX_RELOADS" "0" "nginx -t başarısızsa reload denenmez"
assert_eq "$rc" "1" "nginx -t başarısız → exit 1"
NGINX_TEST_RC=0

echo "── Bölüm D: argüman doğrulama ──"
out=$( _domconf_reload 2>&1 ); rc=$?
assert_eq "$rc" "1" "argümansız → hata"
out=$( _domconf_reload yok.com 2>&1 ); rc=$?
assert_eq "$rc" "1" "var olmayan domain → hata"
out=$( _domconf_reload a.com --bilinmeyen 2>&1 ); rc=$?
assert_eq "$rc" "1" "bilinmeyen seçenek → hata"

test_summary
