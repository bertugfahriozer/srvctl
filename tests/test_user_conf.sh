#!/bin/bash
# Kullanıcı conf okuma + 2FA_* → TWOFA_* göçü.
#
# Eski kod conf'a '2FA_ENABLED=false' yazıp dosyayı 'source' ediyordu.
# '2FA_ENABLED' GEÇERLİ BİR BASH DEĞİŞKEN ADI DEĞİLDİR (rakamla başlıyor):
#   source → "2FA_ENABLED=false: command not found"  (ROLE/DOMAINS set edilmez)
#   ${2FA_ENABLED:-false} → "bad substitution"       (shell düşer)
# Yani 'srvctl user list' ve 'user info' fiilen çalışmıyordu.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
export SRVCTL_USERS_DIR="$(mktemp -d)"
source "${REPO_ROOT}/lib/user.sh"

# ── 1) ESKİ formatlı conf (regresyon fixture'ı) ──
cat > "${SRVCTL_USERS_DIR}/eski.conf" << 'EOF'
ROLE=developer
DOMAINS=a.com,b.com
CREATED=1750000000
LAST_LOGIN=
2FA_ENABLED=true
2FA_SECRET=ABC123
EOF

_user_read_conf "${SRVCTL_USERS_DIR}/eski.conf" >/dev/null 2>&1

assert_eq "${ROLE}"           "developer"   "eski conf'tan ROLE okundu"
assert_eq "${DOMAINS}"        "a.com,b.com" "eski conf'tan DOMAINS okundu"
assert_eq "${TWOFA_ENABLED}"  "true"        "2FA_ENABLED → TWOFA_ENABLED göç etti"
assert_eq "${TWOFA_SECRET}"   "ABC123"      "2FA_SECRET → TWOFA_SECRET göç etti"

# Dosya kalıcı olarak göç etmiş olmalı, .bak artığı kalmamalı
assert_contains     "$(cat "${SRVCTL_USERS_DIR}/eski.conf")" "TWOFA_ENABLED=true" "dosya diske göç edildi"
assert_not_contains "$(cat "${SRVCTL_USERS_DIR}/eski.conf")" "2FA_ENABLED="       "eski anahtar kalmadı"
assert_eq "$(ls "${SRVCTL_USERS_DIR}"/*.bak 2>/dev/null | wc -l | tr -d ' ')" "0" ".bak artığı temizlendi"

# ── 2) Yeni formatlı conf ──
cat > "${SRVCTL_USERS_DIR}/yeni.conf" << 'EOF'
ROLE=viewer
DOMAINS=
CREATED=1760000000
LAST_LOGIN=
TWOFA_ENABLED=false
TWOFA_SECRET=
EOF

_user_read_conf "${SRVCTL_USERS_DIR}/yeni.conf" >/dev/null 2>&1
assert_eq "${ROLE}"          "viewer" "yeni conf'tan ROLE okundu"
assert_eq "${TWOFA_ENABLED}" "false"  "yeni conf'tan TWOFA_ENABLED okundu"
assert_eq "${DOMAINS}"       ""       "önceki okumadan artık değer sızmadı"

# ── 3) source ETMEME sözleşmesi: conf'taki komut ÇALIŞTIRILMAMALI ──
cat > "${SRVCTL_USERS_DIR}/kotu.conf" << 'EOF'
ROLE=admin
DOMAINS=
TWOFA_ENABLED=false
EOF
printf 'ETKI_DOSYASI=$(touch %s/pwned)\n' "$SRVCTL_USERS_DIR" >> "${SRVCTL_USERS_DIR}/kotu.conf"
_user_read_conf "${SRVCTL_USERS_DIR}/kotu.conf" >/dev/null 2>&1
assert_eq "$([[ -e "${SRVCTL_USERS_DIR}/pwned" ]] && echo evet || echo hayir)" "hayir" \
          "conf source/eval EDİLMEDİ (komut çalışmadı)"

# ── 4) _user_key: 3. argümansız çağrı 'unbound variable' ile düşmemeli ──
out=$( _user_key remove 2>&1 )
assert_not_contains "$out" "unbound variable" "eksik argümanda unbound variable yok"

rm -rf "$WEB_ROOT" "$SRVCTL_USERS_DIR"
test_summary
