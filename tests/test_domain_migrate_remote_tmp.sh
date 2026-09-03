#!/bin/bash
# Y3 regresyonu (haftalık denetim 2026-09): 'domain migrate' credentials + DB
# dökümünü 'scp -r' (-p YOK) ile karşı sunucunun DÜNYA-OKUNUR /tmp'sine
# bırakıyor, hiçbir dal temizlemiyordu. Artık /root altında 0700 dizin,
# 'scp -p', %q ile tırnaklanmış uzak argümanlar, yerel paket silinir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
export WEB_ROOT="$(mktemp -d)"
export BACKUP_DIR="$(mktemp -d)"
export SRVCTL_ROOT="$(mktemp -d)"     # lib/backup.sh YOK → migrate içindeki source sessizce atlanır
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/domain.sh"

DOM="example.com"
mkdir -p "${WEB_ROOT}/${DOM}"; printf 'DB_PASS=s3cr3t\n' > "${WEB_ROOT}/${DOM}/.credentials"
domain_exists() { [[ "$1" == "$DOM" ]]; }
_derive_php() { echo "8.3"; }
_backup_files_tar() { : > "$3"; }
mysqldump() { echo "-- dump"; }
LOG="$(mktemp)"
ssh() { printf 'SSH %s\n' "$*" >> "$LOG"; return 0; }
scp() { printf 'SCP %s\n' "$*" >> "$LOG"; return 0; }
DEFAULT_PHP_VERSION=8.3

out=$( ( _domain_migrate "$DOM" "root@10.0.0.9" --auto ) 2>&1 )
log="$(cat "$LOG")"

assert_not_contains "$log" ":/tmp/"            "scp hedefi artık /tmp DEĞİL"
assert_contains     "$log" "SCP -p -r"         "scp -p ile mod korunuyor"
assert_contains     "$log" ":/root/.srvctl-migrate/migrate-${DOM}-" "hedef /root/.srvctl-migrate altında"
assert_contains     "$log" "umask 077 && mkdir -p -- /root/.srvctl-migrate/" "uzak dizin umask 077 ile oluşturuluyor"
assert_contains     "$log" "chmod 700 -- /root/.srvctl-migrate/" "uzak dizin 0700"
assert_contains     "$log" "chmod 600 -- /root/.srvctl-migrate/migrate-${DOM}-" "uzak dosyalar 0600"
assert_contains     "$log" "srvctl domain add ${DOM} --php=8.3" "--auto içe aktarma komutu"
assert_contains     "$log" "zcat /root/.srvctl-migrate/" "db dökümü yeni konumdan okunuyor"
assert_not_contains "$log" "/tmp/migrate-"    "hiçbir uzak komut /tmp'e bakmıyor"
assert_eq "$(ls "$BACKUP_DIR" | wc -l)" "0"   "yerel migrate paketi iş sonunda SİLİNDİ"
assert_contains     "$out" "rm -rf /root/.srvctl-migrate/" "operatöre uzak temizlik talimatı"

# Manuel dal: talimatlar /tmp'e yönlendirmiyor
: > "$LOG"; mkdir -p "${WEB_ROOT}/${DOM}"
out2=$( ( _domain_migrate "$DOM" "root@10.0.0.9" ) 2>&1 )
assert_contains     "$out2" "cd /root/.srvctl-migrate/" "manuel talimat yeni dizini gösteriyor"
assert_not_contains "$out2" "cd /tmp/"         "manuel talimat /tmp'e yönlendirmiyor"

# %q tırnaklama yapısal: ssh dizgesinde ham \${domain} enterpolasyonu kalmadı
src="$(declare -f _domain_migrate)"
assert_not_contains "$src" 'srvctl domain add ${domain} --php=${php} && tar' "ssh dizgesi ham \${domain} enterpolasyonu kullanmıyor"
assert_contains     "$src" "printf -v q_domain '%q'" "uzak argümanlar %q ile tırnaklanıyor"

rm -rf "$WEB_ROOT" "$BACKUP_DIR" "$SRVCTL_ROOT" "$LOG"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
