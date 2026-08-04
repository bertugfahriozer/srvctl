#!/bin/bash
# self-update ÇALIŞAN script'in üzerine in-place yazıyordu + resource
# profillerini hiç kopyalamıyordu.
#
# ── BULGU 1: in-place ezme (CANLI SUNUCUDA GÖZLENDİ) ──
# '_selfupdate_install_from_staging' 'cp -f' kullanıyordu. 'cp -f' mevcut
# inode'u TRUNCATE edip yeniden doldurur — YENİ dosya oluşturmaz. Oysa bash
# bir script'i baştan sona okuyup tamponlamaz; BYTE OFFSET tutar ve gerektikçe
# okur. Çalışan 'bin/srvctl' (ve source edilmiş 'lib/selfupdate.sh') böyle
# ezilince bash, kalan komutları YENİ içerikten ESKİ offset'ten okur → satır
# kayması → yarım/anlamsız bir kod parçası çalışır.
# Gerçek gözlem (üretim sunucusu, 'srvctl self-update run' sonu):
#   /usr/local/bin/srvctl: line 165: plugin_dir: unbound variable
# Bu hata bin/srvctl'e BİRKAÇ SATIR eklenince ORTAYA ÇIKTI — yani kusur
# önceden de vardı ama kayma zararsız bir bölgeye denk geliyordu. SESSİZ
# olması daha tehlikelidir: kayma bir komutun ortasına denk gelirse
# ÖNGÖRÜLEMEZ kod çalışır.
# Çözüm: geçici dosyaya yaz + 'mv' ile ATOMİK rename. mv dizin girdisini YENİ
# inode'a bağlar; çalışan süreç ESKİ inode'u okumaya devam eder, bozulma olmaz.
#
# ── BULGU 2: resource-profiles.conf hiç kopyalanmıyordu ──
# install.sh bu dosyayı kuruyor, self-update KURMUYORDU. Yalnız self-update
# ile yükseltilen sunucuda dosya hiç oluşmaz → resource_profile_line boş
# döner → HER profil "bilinmeyen" sayılır → '--resources=ecommerce|heavy' ile
# eklenmiş domainler SESSİZCE 'standard'a (8 child / 256MB) düşer.
# Yedekleme ve rollback de bu dosyayı kapsamıyordu.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

# Sahte kurulum + staging
SRVCTL_ROOT="$(mktemp -d)"
STAGING="$(mktemp -d)"
SRVCTL_SELFUPDATE_BACKUPS="$(mktemp -d)"
SRVCTL_CURRENT_COMMIT="$(mktemp -d)/.current-commit"

mkdir -p "${SRVCTL_ROOT}"/{bin,lib,templates,completions,conf}
mkdir -p "${STAGING}"/{bin,lib,templates,completions,conf}

printf '#!/bin/bash\necho ESKI\n'  > "${SRVCTL_ROOT}/bin/srvctl"
printf '#!/bin/bash\necho ESKI\n'  > "${SRVCTL_ROOT}/lib/core.sh"
printf '#!/bin/bash\necho YENI\n'  > "${STAGING}/bin/srvctl"
printf '#!/bin/bash\necho YENI\n'  > "${STAGING}/lib/core.sh"
printf 'standard:ondemand:8:256:120\n' > "${STAGING}/conf/resource-profiles.conf"
printf 'standard:10r/s:20\n'           > "${STAGING}/conf/rate-profiles.conf"

# root gerektiren yardımcıları mock'la
secure_dir() { mkdir -p "$1"; }
_stat_owner() { echo "root"; }

source "${REPO_ROOT}/lib/selfupdate.sh"

inode_of() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }

echo "── Bölüm A: kurulum ATOMİK olmalı (in-place ezme YOK) ──"
bin_before=$(inode_of "${SRVCTL_ROOT}/bin/srvctl")
lib_before=$(inode_of "${SRVCTL_ROOT}/lib/core.sh")

_selfupdate_install_from_staging "$STAGING"

bin_after=$(inode_of "${SRVCTL_ROOT}/bin/srvctl")
lib_after=$(inode_of "${SRVCTL_ROOT}/lib/core.sh")

# ASIL KİLİT: inode DEĞİŞMELİ. Aynı kalırsa dosya in-place ezilmiş demektir
# ve o an çalışmakta olan bash süreci bozulur.
[[ "$bin_before" != "$bin_after" ]]; assert_eq "$?" "0" \
    "bin/srvctl ATOMİK değiştirildi (inode değişti — çalışan süreç bozulmaz)"
[[ "$lib_before" != "$lib_after" ]]; assert_eq "$?" "0" \
    "lib/*.sh ATOMİK değiştirildi (inode değişti)"

# Atomiklik içeriği bozmamalı
assert_contains "$(cat "${SRVCTL_ROOT}/bin/srvctl")" "YENI" "bin/srvctl yeni içerikle güncellendi"
assert_contains "$(cat "${SRVCTL_ROOT}/lib/core.sh")" "YENI" "lib/core.sh yeni içerikle güncellendi"
[[ -x "${SRVCTL_ROOT}/bin/srvctl" ]]; assert_eq "$?" "0" "bin/srvctl çalıştırılabilir kaldı"
[[ -x "${SRVCTL_ROOT}/lib/core.sh" ]]; assert_eq "$?" "0" "lib/core.sh çalıştırılabilir kaldı"

echo "── Bölüm B: resource-profiles.conf kopyalanmalı ──"
assert_contains "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf" 2>/dev/null)" "standard:ondemand" \
    "resource-profiles.conf staging'den kuruldu"
assert_contains "$(cat "${SRVCTL_ROOT}/conf/rate-profiles.conf" 2>/dev/null)" "standard:" \
    "rate-profiles.conf da kuruldu (mevcut davranış korundu)"

echo "── Bölüm C: yedekleme resource-profiles'ı içermeli ──"
BDIR=$(_selfupdate_backup_current)
assert_contains "$(cat "${BDIR}/conf/resource-profiles.conf" 2>/dev/null)" "standard:ondemand" \
    "yedek resource-profiles.conf içeriyor"
assert_contains "$(cat "${BDIR}/conf/rate-profiles.conf" 2>/dev/null)" "standard:" \
    "yedek rate-profiles.conf içeriyor"

echo "── Bölüm D: rollback resource-profiles'ı geri yüklemeli ──"
# Kötü bir güncelleme profilleri bozsun
printf 'BOZUK\n' > "${SRVCTL_ROOT}/conf/resource-profiles.conf"
_selfupdate_restore_from_backup "$BDIR" >/dev/null 2>&1
assert_contains "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf" 2>/dev/null)" "standard:ondemand" \
    "rollback resource-profiles.conf'u geri yükledi"
assert_not_contains "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf" 2>/dev/null)" "BOZUK" \
    "bozuk içerik kalmadı"

echo "── Bölüm E: staging'de dosya yoksa çökmemeli ──"
STAGING2="$(mktemp -d)"; mkdir -p "${STAGING2}/bin" "${STAGING2}/lib"
printf '#!/bin/bash\necho X\n' > "${STAGING2}/bin/srvctl"
_selfupdate_install_from_staging "$STAGING2" >/dev/null 2>&1; assert_eq "$?" "0" \
    "conf/ olmayan staging ile kurulum çökmüyor"
assert_contains "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf" 2>/dev/null)" "standard:ondemand" \
    "staging'de yoksa MEVCUT resource-profiles.conf korunuyor"

test_summary
