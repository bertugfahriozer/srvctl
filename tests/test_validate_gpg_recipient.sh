#!/bin/bash
# validate_gpg_recipient (lib/core.sh) — option-injection reddi.
#
# NEDEN VAR: BACKUP_GPG_RECIPIENT, lib/backup.sh içinde DOĞRUDAN
# 'gpg -r "$deger"' argümanı olarak geçiyor. gpg (tüm çoğu CLI aracı gibi)
# '-' ile başlayan bir argümanı YENİ BİR SEÇENEK olarak yorumlar — operatör
# (ya da srvctl.conf'u ele geçiren bir saldırgan) BACKUP_GPG_RECIPIENT'ı
# '--output=/root/.ssh/authorized_keys' gibi bir değere ayarlarsa, "alıcı"
# aslında gpg'ye YENİ BİR YAZMA HEDEFİ / DAVRANIŞ enjekte eder (option-injection
# — _deploy_validate_repo_url/validate_git_url'DEKİ AYNI SINIF açığın gpg
# çağrısındaki karşılığı). Bu test:
#   1) Geçerli e-posta/fingerprint/key-ID biçimlerinin kabul edildiğini,
#   2) Boşluk, baştaki '-' ve whitelist dışı kabuk meta-karakterlerinin
#      (';', '|', '$()', backtick) REDDEDİLDİĞİNİ,
#   3) load_config'in BACKUP_GPG_RECIPIENT'ı TAM OLARAK bu predikattan
#      geçirdiğini ve saldırgan bir değer verildiğinde config yüklemenin
#      error() ile FAIL-CLOSED durduğunu (srvctl'in hiçbir komutu ilerlemez)
#      doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# ═══════════════ Geçerli değerler ═══════════════
assert_ok validate_gpg_recipient "backups@example.com"
assert_ok validate_gpg_recipient "First.Last+tag@sub.example.co"
assert_ok validate_gpg_recipient "0123456789ABCDEF0123456789ABCDEF01234567"   # fingerprint
assert_ok validate_gpg_recipient "0xDEADBEEF"                                  # key-id (hex + 0x)
assert_ok validate_gpg_recipient "a"                                           # tek karakter — hâlâ whitelist içinde

# ═══════════════ Reddedilmesi gereken değerler ═══════════════
assert_fail validate_gpg_recipient ""                               # boş
assert_fail validate_gpg_recipient "-"                               # tek başına tire
assert_fail validate_gpg_recipient "-r"                              # option-injection: kısa bayrak
assert_fail validate_gpg_recipient "--output=/root/.ssh/authorized_keys"  # option-injection: uzun bayrak
assert_fail validate_gpg_recipient "--batch"                         # option-injection
assert_fail validate_gpg_recipient "user name@example.com"           # iç boşluk
assert_fail validate_gpg_recipient "$(printf 'user\tname@example.com')"  # tab
assert_fail validate_gpg_recipient "$(printf 'user\nname@example.com')"  # newline
assert_fail validate_gpg_recipient "user;rm -rf /@example.com"       # ';' komut ayırıcı
assert_fail validate_gpg_recipient "user|whoami@example.com"         # '|' pipe
assert_fail validate_gpg_recipient 'user$(whoami)@example.com'       # komut ikamesi karakterleri
assert_fail validate_gpg_recipient 'user`whoami`@example.com'        # backtick
assert_fail validate_gpg_recipient "user&@example.com"               # '&' arka plan/AND

# ═══════════════ load_config entegrasyonu: fail-closed ═══════════════
# BACKUP_GPG_RECIPIENT env ile enjekte edilip core.sh yeniden kaynak
# gösterilerek (kaynak-zamanı load_config) doğrulanıyor — test_load_config_validate.sh
# ile AYNI desen (run_load).
run_load_gpg() {
    BACKUP_GPG_RECIPIENT="$1" WEB_ROOT="${WEB_ROOT}" bash -c '
        source "'"${REPO_ROOT}"'/lib/core.sh"   # kaynak-zamanı load_config
    ' >/dev/null 2>&1
}

assert_ok   run_load_gpg ""                       # boş = kapalı, izin verilir
assert_ok   run_load_gpg "backups@example.com"    # geçerli alıcı
assert_fail run_load_gpg "--output=/root/.ssh/authorized_keys"   # saldırgan → error() → exit
assert_fail run_load_gpg "-r"                                     # saldırgan → error() → exit
assert_fail run_load_gpg "user name@example.com"                  # boşluklu → error() → exit

rm -rf "$WEB_ROOT"
test_summary
