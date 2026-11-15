#!/bin/bash
# D1/1 — köken kilidinin geo kaynağı: trusted sync, realip dosyasıyla AYNI eşitleme adımında, AYNI CF listesinden
# conf.d/srvctl-cf-origin-geo.conf üretir (`geo $realip_remote_addr $srvctl_via_cf`). Liste boş/okunamazsa dosya
# YAZILMAZ (gerekçe: boş liste + default 0 = TÜM Cloudflare trafiği 444; yazılmayan dosya mevcut kilitleri eski listeyle
# çalışır halde bırakır, yeni kilit açılamaz — 'srvctl domain origin-lock on' dosya yoksa reddeder).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# fm_env.sh: geçici WEB_ROOT/SRVCTL_STATE_DIR + flock taklidi (geo yazımı fm-auth kilidi altında — M6)
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/trusted.sh"
set +e
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"; _fm_env_cleanup' EXIT

echo "── A: render ──"
printf '173.245.48.0/20\n103.21.244.0/22\n2400:cb00::/32\n' > "${WORK}/cf"
g="$(_trusted_render_geo "${WORK}/cf" "198.51.100.7 2001:db8::7")"
assert_contains "$g" 'geo $realip_remote_addr $srvctl_via_cf {' "geo, ORİJİNAL eş adresine (\$realip_remote_addr) bağlı"
assert_contains "$g" "default 0;" "default 0 (CF dışı = kilit)"
assert_contains "$g" "173.245.48.0/20 1;" "CF v4 → 1"
assert_contains "$g" "2400:cb00::/32 1;" "CF v6 → 1"
assert_contains "$g" "127.0.0.1 1;" "loopback v4 → 1 (yerel sondalar)"
assert_contains "$g" "::1 1;" "loopback v6 → 1"
assert_contains "$g" "198.51.100.7 1;" "sunucunun kendi v4 IP'si → 1"
assert_contains "$g" "2001:db8::7 1;" "sunucunun kendi v6 IP'si → 1"
assert_eq "$(printf '%s\n' "$g" | grep -c '^[[:space:]]*default 0;')" "1" "tek default"
dd1="$(_trusted_render_geo "${WORK}/cf" "198.51.100.7 198.51.100.7 127.0.0.1")"
assert_eq "$(printf '%s\n' "$dd1" | grep -c '^[[:space:]]*127\.0\.0\.1 1;')" "1" "yinelenen ağ tek satır (nginx geo çift girişte hata verir)"
assert_eq "$(printf '%s\n' "$dd1" | grep -c '^[[:space:]]*198\.51\.100\.7 1;')" "1" "yinelenen kendi IP tek satır"

echo "── B: sync e2e (fixture) — realip ile aynı adımda ──"
export TRUSTED_STATE_DIR="${WORK}/state"; mkdir -p "$TRUSTED_STATE_DIR"
export SRVCTL_TRUSTED_FIXTURE_DIR="${WORK}/fix"; mkdir -p "$SRVCTL_TRUSTED_FIXTURE_DIR"
export FAIL2BAN_JAIL_LOCAL="${WORK}/jail.local"
export NGINX_CF_REALIP_CONF="${WORK}/cf-realip.conf"
export NGINX_CF_GEO_CONF="${WORK}/cf-geo.conf"
export TRUSTED_SOURCES="cloudflare"
export SRVCTL_SELF_IPS="198.51.100.7"
{ for i in $(seq 1 12); do echo "10.0.${i}.0/24"; done; } > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v4"
printf '2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n2405:b500::/32\n2405:8100::/32\n2a06:98c0::/29\n' > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v6"
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' > "$FAIL2BAN_JAIL_LOCAL"
_trusted_sync >/dev/null 2>&1
assert_ok test -f "$NGINX_CF_REALIP_CONF"
assert_ok test -f "$NGINX_CF_GEO_CONF"
assert_contains "$(cat "$NGINX_CF_GEO_CONF")" "10.0.3.0/24 1;" "geo CF listesinden (cloudflare.conf ile AYNI kaynak)"
assert_contains "$(cat "$NGINX_CF_GEO_CONF")" "198.51.100.7 1;" "geo kendi IP'yi içerir"
assert_eq "$(grep -c 'set_real_ip_from' "$NGINX_CF_REALIP_CONF")" "18" "realip 18 aralık (12 v4 + 6 v6)"
assert_eq "$(grep -cE '^[[:space:]]*[0-9a-f:./]+ 1;' "$NGINX_CF_GEO_CONF")" "$((18 + 3))" "geo: 18 CF + 127.0.0.1 + ::1 + 1 kendi IP"
assert_eq "$(stat -c '%a' "$NGINX_CF_GEO_CONF" 2>/dev/null || stat -f '%Lp' "$NGINX_CF_GEO_CONF")" "644" "geo dosyası 0644"
geo_before="$(cat "$NGINX_CF_GEO_CONF")"

echo "── C: liste boş/okunamaz → geo YAZILMAZ, mevcut korunur ──"
: > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v4"; : > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v6"
_trusted_sync >/dev/null 2>&1
assert_eq "$(cat "$NGINX_CF_GEO_CONF")" "$geo_before" "boş fetch: mevcut geo DEĞİŞMEDİ"
: > "${TRUSTED_STATE_DIR}/cloudflare.conf"
out=$(_trusted_apply_geo 2>&1); rc=$?
assert_eq "$rc" "1" "cloudflare.conf boşken apply_geo rc 1"
assert_eq "$(cat "$NGINX_CF_GEO_CONF")" "$geo_before" "boş liste: geo dosyasına YAZILMADI"
assert_contains "$out" "yazılmadı" "uyarı söyler: kilit dosyası yazılmadı"
rm -f "${TRUSTED_STATE_DIR}/cloudflare.conf" 2>/dev/null
out=$(_trusted_apply_geo 2>&1); rc=$?
assert_eq "$rc" "1" "cloudflare.conf YOKken apply_geo rc 1"
assert_eq "$(cat "$NGINX_CF_GEO_CONF")" "$geo_before" "liste yok: geo korunur"
# liste yok + geo yok → dosya oluşmaz
export NGINX_CF_GEO_CONF="${WORK}/yeni-geo.conf"
_trusted_apply_geo >/dev/null 2>&1
assert_ok test ! -e "$NGINX_CF_GEO_CONF"
# çok az satır (sane 8 altı) → yazılmaz
printf '10.9.0.0/24\n10.9.1.0/24\n' > "${TRUSTED_STATE_DIR}/cloudflare.conf"
_trusted_apply_geo >/dev/null 2>&1
assert_ok test ! -e "$NGINX_CF_GEO_CONF"

echo "── D: nginx -t düşerse geo geri alınır (bozuk dosya diskte KALMAZ) ──"
{ for i in $(seq 1 12); do echo "10.0.${i}.0/24"; done; printf '2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n2405:b500::/32\n2405:8100::/32\n'; } > "${TRUSTED_STATE_DIR}/cloudflare.conf"
export NGINX_CF_GEO_CONF="${WORK}/rb-geo.conf"
printf 'ESKI-ICERIK\n' > "$NGINX_CF_GEO_CONF"
nginx() { return 1; }
_trusted_apply_geo >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "nginx -t başarısız → rc 1"
assert_eq "$(cat "$NGINX_CF_GEO_CONF")" "ESKI-ICERIK" "önceki içerik GERİ yüklendi"
rm -f "$NGINX_CF_GEO_CONF" 2>/dev/null
_trusted_apply_geo >/dev/null 2>&1
assert_ok test ! -e "$NGINX_CF_GEO_CONF"
unset -f nginx
assert_eq "$(find "$WORK" -name '*.srvctl*' | wc -l | tr -d ' ')" "0" "artık geçici/yedek dosya kalmadı"

echo "── E: kendi IP tespiti ──"
assert_eq "$(SRVCTL_SELF_IPS='203.0.113.9  2001:db8::9' _trusted_self_ips)" "203.0.113.9 2001:db8::9" "SRVCTL_SELF_IPS geçersiz kılar"
assert_eq "$(SRVCTL_SELF_IPS='' _trusted_self_ips)" "" "boş geçersiz kılma = hiç kendi IP yok"
assert_eq "$(SRVCTL_SELF_IPS='203.0.113.9 abc 999.1.1.1 10.0.0.0/8' _trusted_self_ips)" "203.0.113.9" "geçersiz/CIDR girdiler atılır (tek IP beklenir)"
echo "── F: aile eşiği (IPv4 ve IPv6 AYRI AYRI) — toplam sayı yetmez ──"
export NGINX_CF_GEO_CONF="${WORK}/aile-geo.conf"
fam_list() { local n4="$1" n6="$2" i; : > "${TRUSTED_STATE_DIR}/cloudflare.conf"; for ((i = 1; i <= n4; i++)); do echo "10.0.${i}.0/24" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; for ((i = 1; i <= n6; i++)); do printf '2400:cb0%x::/32\n' "$i" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; }
for combo in "15 0" "0 9" "9 7" "10 4" "0 0"; do
    set -- $combo
    rm -f "$NGINX_CF_GEO_CONF"; fam_list "$1" "$2"
    _trusted_apply_geo >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "v4=$1 v6=$2 (toplam eşik üstü olsa da bir aile eşik altında) → rc 1"
    assert_ok test ! -e "$NGINX_CF_GEO_CONF"
done
for combo in "10 5" "15 7"; do
    set -- $combo
    rm -f "$NGINX_CF_GEO_CONF"; fam_list "$1" "$2"
    _trusted_apply_geo >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "0" "v4=$1 v6=$2 (iki aile eşikte/üstünde) → rc 0"
    assert_ok test -f "$NGINX_CF_GEO_CONF"
done
test_summary
