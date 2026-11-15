#!/bin/bash
# QL5-L1: `domain repair` domconf modülünü YÜKLEYEMEZSE fail-closed olmalı.
# ESKİDEN: _domain_repair_fm_step yalnız uyarıp rc 0 dönüyordu → "Domain onarıldı", /_fm 403 kökü kurulmadı.
# ŞİMDİ:
#   A  _domain_repair <alan>: yükleme başarısız → rc≠0 ve HİÇBİR yan etkiye (domain_exists, kimlik üretimi,
#      systemctl/mysql/redis-cli/nginx) ULAŞMADAN durur (yan etki izi = sentinel günlüğü boş)
#   B  _domain_repair --all: aynı — list_all_domains bile çağrılmaz
#   C  _domain_repair_fm_step (savunma derinliği): yükleme başarısız → rc 1 (sessiz başarı değil)
#   D  pozitif kontrol: yükleme BAŞARILIYKEN aynı sentinel'ler GERÇEKTEN tetiklenir (A/B'nin "boş günlük"ü
#      sahte yeşil olamaz)
# Gerçek domconf yüklemesi KASITLI olarak başarısız: SRVCTL_ROOT içinde lib/domconf.sh olmayan boş dizin.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export WEB_ROOT="${T}/www" SRVCTL_STATE_DIR="${T}/state" SRVCTL_FPM_DIR="${T}/fpm" \
       SRVCTL_SYSTEMD_DIR="${T}/sd" SRVCTL_PHP_POOL_DIR="${T}/pool"
mkdir -p "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/domain.sh"

# gerçek domconf yüklemesi başarısız: boş SRVCTL_ROOT, _domconf_reload tanımsız
mkdir -p "${T}/emptyroot/lib"
# shellcheck disable=SC2034  # SRVCTL_ROOT: _domain_load_conf_lib (domain.sh) okur
SRVCTL_ROOT="${T}/emptyroot"
unset -f _domconf_reload 2>/dev/null || true
SENT="${T}/sentinel.log"; : > "$SENT"
domain_exists()              { echo "domain_exists $*" >> "$SENT"; return 0; }
list_all_domains()           { echo "list_all_domains" >> "$SENT"; }
_domain_ensure_credentials() { echo "ensure_credentials $*" >> "$SENT"; }
systemctl() { echo "systemctl $*" >> "$SENT"; return 0; }
mysql()     { echo "mysql" >> "$SENT"; return 0; }
redis-cli() { echo "redis-cli" >> "$SENT"; return 0; }
nginx()     { echo "nginx $*" >> "$SENT"; return 0; }

echo "── Ön koşul: gerçek _domain_load_conf_lib bu ortamda BAŞARISIZ ──"
( _domain_load_conf_lib ) >/dev/null 2>&1; pre=$?
assert_eq "$([[ "$pre" -ne 0 ]] && echo FAIL || echo OK)" "FAIL" "(ön koşul) boş SRVCTL_ROOT'ta domconf yüklenemiyor"

echo "── A: tek alan ──"
: > "$SENT"
outA=$( ( _domain_repair "fail-a.test" ) 2>&1 ); rcA=$?
assert_eq "$([[ "$rcA" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" "A: domconf yüklenemezse repair rc≠0"
assert_contains "$outA" "domconf modülü yüklenemedi" "A: neden açıkça yazılı"
assert_not_contains "$outA" "Domain onarıldı" "A: başarı mesajı basılmadı"
assert_eq "$(wc -c < "$SENT" | tr -d ' ')" "0" "A: hiçbir yan etkiye (domain_exists/kimlik/systemctl/mysql/redis/nginx) ULAŞILMADI"

echo "── B: --all ──"
: > "$SENT"
outB=$( ( _domain_repair "--all" ) 2>&1 ); rcB=$?
assert_eq "$([[ "$rcB" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" "B: --all domconf yüklenemezse rc≠0"
assert_not_contains "$outB" "Tüm domainler onarıldı" "B: toplu başarı mesajı basılmadı"
assert_eq "$(wc -c < "$SENT" | tr -d ' ')" "0" "B: --all alan numaralandırmasına (list_all_domains) bile ULAŞMADI"

echo "── C: FM adımı (savunma derinliği) ──"
outC=$( ( _domain_repair_fm_step "fail-c.test" "8.3" ) 2>&1 ); rcC=$?
assert_eq "$rcC" "1" "C: _domain_repair_fm_step yükleme başarısızlığında rc 1 (eskiden 0)"
assert_contains "$outC" "domconf modülü yüklenemedi" "C: uyarı yazıldı"

echo "── D: pozitif kontrol (yükleme başarılıyken sentinel'ler tetiklenir) ──"
_domain_load_conf_lib() { return 0; }
_domain_repair_fm_step() { return 0; }
: > "$SENT"
( _domain_repair "ok-d.test" ) >/dev/null 2>&1 || true
assert_contains "$(cat "$SENT")" "domain_exists ok-d.test" "D: yükleme başarılıyken repair domain_exists'e ULAŞIR (A'nın boş günlüğü anlamlı)"
: > "$SENT"
( _domain_repair "--all" ) >/dev/null 2>&1 || true
assert_contains "$(cat "$SENT")" "list_all_domains" "D: yükleme başarılıyken --all list_all_domains'e ULAŞIR (B'nin boş günlüğü anlamlı)"

test_summary
