#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/trusted.sh"

WORK="$(mktemp -d)"

# ── parse_validate: çöp ayıklama ──
cat > "${WORK}/raw" <<'RAW'
173.245.48.0/20
# yorum satırı
103.21.244.0/22

not-an-ip
2400:cb00::/32
999.999.1.1
198.51.100.7
RAW
out="$(_trusted_parse_validate "${WORK}/raw")"
assert_contains "$out" "173.245.48.0/20" "geçerli v4 CIDR geçer"
assert_contains "$out" "198.51.100.7" "geçerli v4 IP geçer"
assert_contains "$out" "2400:cb00::/32" "geçerli v6 CIDR geçer"
assert_not_contains "$out" "not-an-ip" "geçersiz satır ayıklanır"
assert_not_contains "$out" "999.999" "aralık-dışı v4 ayıklanır"
assert_not_contains "$out" "yorum" "yorum ayıklanır"

# ── sane ──
printf 'a\nb\nc\n' > "${WORK}/three"
assert_ok   _trusted_sane 2 "${WORK}/three"
assert_fail _trusted_sane 5 "${WORK}/three"
: > "${WORK}/empty"
assert_fail _trusted_sane 1 "${WORK}/empty"
assert_fail _trusted_sane 1 "${WORK}/yok-dosya"

# ── render_realip ──
printf '173.245.48.0/20\n2400:cb00::/32\n' > "${WORK}/cf"
r="$(_trusted_render_realip "${WORK}/cf")"
assert_contains "$r" "set_real_ip_from 173.245.48.0/20;" "v4 set_real_ip_from"
assert_contains "$r" "set_real_ip_from 2400:cb00::/32;" "v6 set_real_ip_from"
assert_contains "$r" "real_ip_header CF-Connecting-IP;" "real_ip_header satırı"

# ── compute_ignoreip: dedup + tek satır ──
printf '1.1.1.1\n2.2.2.2\n' > "${WORK}/a"
printf '2.2.2.2\n3.3.3.3\n' > "${WORK}/b"
line="$(_trusted_compute_ignoreip "127.0.0.1/8" "${WORK}/a" "${WORK}/b")"
assert_contains "$line" "127.0.0.1/8" "base var"
assert_contains "$line" "3.3.3.3" "b'den IP var"
assert_eq "$(printf '%s\n' "$line" | grep -o '2\.2\.2\.2' | wc -l | tr -d ' ')" "1" "dedup: 2.2.2.2 bir kez"
assert_eq "$(printf '%s' "$line" | grep -c '')" "1" "tek satır (yeni-satır yok)"


# ── fetch (fixture) + sync e2e + fail-safe ──
export TRUSTED_STATE_DIR="${WORK}/state"; mkdir -p "$TRUSTED_STATE_DIR"
export SRVCTL_TRUSTED_FIXTURE_DIR="${WORK}/fix"; mkdir -p "$SRVCTL_TRUSTED_FIXTURE_DIR"
export FAIL2BAN_JAIL_LOCAL="${WORK}/jail.local"
export NGINX_CF_REALIP_CONF="${WORK}/cf-realip.conf"
export TRUSTED_SOURCES="cloudflare uptimerobot"

# CF v4 (8) + v6 (3) → sane(8) geçer; UR (6) → sane(5) geçer
{ for i in $(seq 1 8); do echo "10.0.${i}.0/24"; done; } > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v4"
printf '2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n' > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v6"
{ for i in $(seq 1 6); do echo "216.144.250.${i}"; done; } > "${SRVCTL_TRUSTED_FIXTURE_DIR}/uptimerobot"
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' > "$FAIL2BAN_JAIL_LOCAL"

_trusted_sync >/dev/null 2>&1

assert_ok test -f "${TRUSTED_STATE_DIR}/cloudflare.conf"
assert_ok test -f "${TRUSTED_STATE_DIR}/uptimerobot.conf"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "10.0.1.0/24" "ignoreip CF içerir"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "216.144.250.1" "ignoreip UR içerir"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "127.0.0.1/8" "ignoreip base korunur"
assert_contains "$(cat "$NGINX_CF_REALIP_CONF")" "set_real_ip_from 10.0.1.0/24;" "realip conf CF içerir"
assert_not_contains "$(cat "$NGINX_CF_REALIP_CONF")" "216.144.250" "realip UR İÇERMEZ (proxy değil)"

# fail-safe: CF fixture'ı boşalt → yeni sync mevcut cloudflare.conf'u KORUMALI
cf_before="$(cat "${TRUSTED_STATE_DIR}/cloudflare.conf")"
: > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v4"
: > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v6"
_trusted_sync >/dev/null 2>&1
assert_eq "$(cat "${TRUSTED_STATE_DIR}/cloudflare.conf")" "$cf_before" "fetch boş/sanity-fail → cloudflare.conf korunur"

# cmd_trusted help çalışır (exit 0)
assert_ok cmd_trusted help

# init.sh trusted cron + ilk senkronu içeriyor mu (yapısal)
assert_contains "$(cat "${REPO_ROOT}/lib/init.sh")" "srvctl trusted sync" "init.sh trusted cron satırı içerir"

# ── Y2 (denetim 2026-09): aşırı geniş aralık tavanı ──
cat > "${WORK}/wide" <<'RAW'
0.0.0.0/0
::/0
10.0.0.0/7
2400::/8
173.245.48.0/20
8.0.0.0/8
2400:cb00::/16
RAW
out="$(_trusted_parse_validate "${WORK}/wide" 2>/dev/null)"
assert_not_contains "$out" "0.0.0.0/0"       "0.0.0.0/0 REDDEDİLİR (fail2ban susar + real_ip spoofing)"
assert_not_contains "$out" "::/0"            "::/0 reddedilir"
assert_not_contains "$out" "10.0.0.0/7"      "/8'den geniş v4 reddedilir"
assert_not_contains "$out" "2400::/8"        "/16'dan geniş v6 reddedilir"
assert_contains     "$out" "173.245.48.0/20" "normal CF aralığı geçer"
assert_contains     "$out" "8.0.0.0/8"       "tam /8 sınırda geçer"
assert_contains     "$out" "2400:cb00::/16"  "tam /16 v6 sınırda geçer"
assert_ok   validate_ip_or_cidr_narrow "1.2.3.4"
assert_ok   validate_ip_or_cidr_narrow "1.2.3.0/24"
assert_fail validate_ip_or_cidr_narrow "0.0.0.0/0"
assert_fail validate_ip_or_cidr_narrow "1.0.0.0/4"
assert_ok   validate_ip_or_cidr        "0.0.0.0/0"   # eski doğrulayıcı sözdizimini kabul etmeye devam eder

# ── Y2: üst sınır — binlerce satırlık yanıt sane DEĞİL ──
seq 1 600 | sed 's|^|10.0.|; s|$|.0/24|' > "${WORK}/huge"
assert_fail _trusted_sane 5 "${WORK}/huge"
TRUSTED_MAX_LINES=1000 assert_ok _trusted_sane 5 "${WORK}/huge"

# ── Düşük: ignoreip güncellemesi jail.local modunu korur ──
FAIL2BAN_JAIL_LOCAL="${WORK}/jail2.local"
TRUSTED_STATE_DIR="${WORK}/state2"; mkdir -p "$TRUSTED_STATE_DIR"
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' > "$FAIL2BAN_JAIL_LOCAL"; chmod 644 "$FAIL2BAN_JAIL_LOCAL"
printf '173.245.48.0/20\n' > "${TRUSTED_STATE_DIR}/cloudflare.conf"
_trusted_apply_ignoreip >/dev/null 2>&1
assert_eq "$(stat -c %a "$FAIL2BAN_JAIL_LOCAL")" "644" "jail.local modu 644 KORUNDU (eski mktemp+mv → 600 yapıyordu)"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "ignoreip = 127.0.0.1/8 173.245.48.0/20" "ignoreip satırı güncellendi"

rm -rf "$WORK"
test_summary
