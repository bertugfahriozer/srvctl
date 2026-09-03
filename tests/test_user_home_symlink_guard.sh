#!/bin/bash
# K1 regresyonu (haftalık denetim 2026-09): 'user key add|remove' ve
# '2fa setup' fallback dalı, kullanıcının KENDİ SAHİBİ olduğu ~/.ssh altındaki
# sembolik bağı root olarak izliyor ve 'chown' (-h olmadan) ile hedefi
# saldırgana DEVREDİYORDU:
#   ln -sf /etc/shadow ~/.ssh/authorized_keys
#   sudo srvctl user key add <u> key.pub   → /etc/shadow'a yaz + chown <u>
# DÜZELTME: _user_guard_home_path — ev dizini, ~/.ssh ve hedef dosyanın
# hiçbiri sembolik bağ olamaz; yazım secure_file üzerinden, chown '-h' ile.
#
# Bu test, SRVCTL_HOME_BASE seam'i ile GERÇEK /home'a dokunmadan çalışır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_USERS_DIR="$(mktemp -d)"
export SRVCTL_HOME_BASE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
security_event() { :; }
source "${REPO_ROOT}/lib/user.sh"

_run_isolated() { ( "$@" ) 2>&1; }

U="deployer"
printf 'ROLE=developer\nDOMAINS=\n' > "${SRVCTL_USERS_DIR}/${U}.conf"
HOME_U="${SRVCTL_HOME_BASE}/${U}"
mkdir -p "${HOME_U}/.ssh"

# Saldırganın hedef almak isteyeceği root dosyasını temsil eden "nöbetçi"
SENTINEL="$(mktemp)"
printf 'root:!:19000:0:99999:7:::\n' > "$SENTINEL"
SENTINEL_BEFORE="$(cat "$SENTINEL")"
PUBKEY="ssh-ed25519 AAAATESTKEY test@example"

# ═══════════════════════════════════════════════════════════════
# 1) authorized_keys → sembolik bağ: key add REDDEDİLMELİ, hedef DOKUNULMAMALI
# ═══════════════════════════════════════════════════════════════
ln -sf "$SENTINEL" "${HOME_U}/.ssh/authorized_keys"
out=$(_run_isolated _user_key add "$U" "$PUBKEY")
assert_fail _run_isolated _user_key add "$U" "$PUBKEY"
assert_contains "$out" "GÜVENLİK" "key add: authorized_keys sembolik bağ → reddedildi"
assert_eq "$(cat "$SENTINEL")" "$SENTINEL_BEFORE" "key add: symlink hedefine HİÇBİR ŞEY yazılmadı"
assert_not_contains "$(cat "$SENTINEL")" "AAAATESTKEY" "key add: pubkey hedefe sızmadı"

# ═══════════════════════════════════════════════════════════════
# 2) authorized_keys → sembolik bağ: key remove hedefi TRUNCATE ETMEMELİ
# ═══════════════════════════════════════════════════════════════
out=$(_run_isolated _user_key remove "$U")
assert_fail _run_isolated _user_key remove "$U"
assert_contains "$out" "SIFIRLANMADI" "key remove: sembolik bağ → sıfırlama reddedildi"
assert_eq "$(cat "$SENTINEL")" "$SENTINEL_BEFORE" "key remove: symlink hedefi truncate edilmedi"
rm -f "${HOME_U}/.ssh/authorized_keys"

# ═══════════════════════════════════════════════════════════════
# 3) ~/.ssh DİZİNİNİN kendisi sembolik bağ (→ başka bir 'root' dizini)
# ═══════════════════════════════════════════════════════════════
FAKE_ROOT_SSH="$(mktemp -d)"
rmdir "${HOME_U}/.ssh"
ln -s "$FAKE_ROOT_SSH" "${HOME_U}/.ssh"
out=$(_run_isolated _user_key add "$U" "$PUBKEY")
assert_fail _run_isolated _user_key add "$U" "$PUBKEY"
assert_eq "$(ls -A "$FAKE_ROOT_SSH" | wc -l)" "0" "~/.ssh sembolik bağ → hedef dizine dosya OLUŞMADI"
rm -f "${HOME_U}/.ssh"

# ═══════════════════════════════════════════════════════════════
# 4) Ev dizininin KENDİSİ sembolik bağ
# ═══════════════════════════════════════════════════════════════
FAKE_HOME="$(mktemp -d)"
rm -rf "${HOME_U}"
ln -s "$FAKE_HOME" "${HOME_U}"
assert_fail _run_isolated _user_key add "$U" "$PUBKEY"
assert_eq "$(ls -A "$FAKE_HOME" | wc -l)" "0" "ev dizini sembolik bağ → hedefe hiçbir şey yazılmadı"
rm -f "${HOME_U}"

# ═══════════════════════════════════════════════════════════════
# 5) 2FA fallback dalı: .google_authenticator sembolik bağ → İPTAL
#    (google-authenticator/su yolu bu ortamda zaten yok; kapı ÖNCE gelir)
# ═══════════════════════════════════════════════════════════════
mkdir -p "${HOME_U}"
ln -sf "$SENTINEL" "${HOME_U}/.google_authenticator"
apt-get() { return 0; }   # kurulum adımını etkisizleştir
command() { [[ "$2" == "google-authenticator" ]] && return 0; builtin command "$@"; }
out=$(_run_isolated _user_2fa setup "$U")
assert_contains "$out" "2FA kurulumu İPTAL" "2fa setup: .google_authenticator sembolik bağ → iptal"
assert_eq "$(cat "$SENTINEL")" "$SENTINEL_BEFORE" "2fa setup: symlink hedefine secret yazılmadı"
unset -f command apt-get
rm -f "${HOME_U}/.google_authenticator"

# ═══════════════════════════════════════════════════════════════
# 6) KONTROL GRUBU: düz dosya → key add ÇALIŞIR, 0600, içerik doğru
#    (chown <u>:<u> bu ortamda kullanıcı olmadığı için hata basar; yalnız
#     dosya içeriği ve modu doğrulanır)
# ═══════════════════════════════════════════════════════════════
mkdir -p "${HOME_U}/.ssh"
_run_isolated _user_key add "$U" "$PUBKEY" >/dev/null
AK="${HOME_U}/.ssh/authorized_keys"
assert_eq "$([[ -f "$AK" && ! -L "$AK" ]] && echo düz)" "düz" "kontrol: authorized_keys düz dosya olarak oluştu"
assert_contains "$(cat "$AK")" "AAAATESTKEY" "kontrol: pubkey yazıldı"
assert_eq "$(stat -c %a "$AK")" "600" "kontrol: authorized_keys 0600"
assert_eq "$(stat -c %a "${HOME_U}/.ssh")" "700" "kontrol: ~/.ssh 700"

_run_isolated _user_key remove "$U" >/dev/null
assert_eq "$(wc -c < "$AK")" "0" "kontrol: key remove düz dosyayı sıfırladı"

rm -rf "$WEB_ROOT" "$SRVCTL_USERS_DIR" "$SRVCTL_HOME_BASE" "$SENTINEL" "$FAKE_ROOT_SSH" "$FAKE_HOME"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
