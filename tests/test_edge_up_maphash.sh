#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# fm-up şablonundaki map'ler nginx'in VARSAYILAN map_hash_bucket_size (32) değeriyle yüklenmeli: uzun tam metin
# anahtar hash kovasına sığmaz (nginx kovayı önbellek satırına yuvarlar: x86 Linux'ta 64, Apple Silicon'da 128 bayt; bu yüzden
# laboratuvarda hatayı görmek için çok uzun köken de denenir — kısa kökende yalnız canlı mimaride düşer) ("could not build map_hash"). Gerçek nginx: SRVCTL_TEST_NGINX, port SRVCTL_LAB_PORT_BASE+4 gerekmez (yalnız nginx -t).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/edge.sh"
set +e
TPL="${REPO_ROOT}/templates/nginx/fm-up-server.conf.tpl"

echo "══ durağan: hash'e giren tırnaklı tam metin map anahtarı yok ══"
bad=$(awk '/^map /{on=1} on && /^[[:space:]]*"[^~"][^"]*"[[:space:]]+"/ && !/^[[:space:]]*"~/ {print} /^}/{on=0}' "$TPL" | grep -vc '^$')
assert_eq "$bad" "0" "fm-up map'lerinde tam metin (regex olmayan) anahtar yok"
long_keys=$(grep -cE '^[[:space:]]*"\{\{FM_UP_ORIGIN\}\}"[[:space:]]' "$TPL")
assert_eq "$long_keys" "0" "FM_UP_ORIGIN map anahtarı olarak kullanılmaz"

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]]; then echo "── nginx yok: gerçek nginx -t ATLANDI ──"; test_summary; exit 0; fi
L1=$(printf 'a%.0s' $(seq 1 60))
D="$(mktemp -d)"; trap 'rm -rf -- "${D:?}"; _fm_env_cleanup' EXIT
for bucket in 32 ""; do
  for spec in "example.com up.example.com https://example.com" \
              "designwestgate.art up.designwestgate.art https://designwestgate.art" \
              "xx.${L1}.${L1}.com up.xx.${L1}.${L1}.com https://xx.${L1}.${L1}.com" \
              "very-long-customer-domain-name.example-hosting.com up.very-long-customer-domain-name.example-hosting.com https://very-long-customer-domain-name.example-hosting.com"; do
    set -- $spec
    out=$(_edge_fmup_render "$1" "$2" "$3" 0 2) || { echo "  FAIL render $1"; TESTS_FAIL=$((TESTS_FAIL+1)); TESTS_RUN=$((TESTS_RUN+1)); continue; }
    printf '%s\n' "$out" | awk '/^map /{on=1} on && /^server \{/{exit} on{print}' > "$D/maps.conf"
    { echo "pid $D/n.pid; error_log $D/e.log; events {}"; echo "http { variables_hash_bucket_size 1024; ${bucket:+map_hash_bucket_size $bucket;} include $D/maps.conf; }"; } > "$D/nginx.conf"
    r=$("$NG" -t -c "$D/nginx.conf" -p "$D" 2>&1); rc=$?
    assert_eq "$rc" "0" "nginx -t (map_hash_bucket_size=${bucket:-varsayılan}) $1 :: $(printf '%s' "$r" | grep -m1 emerg)"
  done
done
test_summary
