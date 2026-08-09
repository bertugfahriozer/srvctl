#!/bin/bash
# self-update'in conf/ VERİ tablolarını taşıması — yedekle / kur / geri yükle.
#
# KÖK SORUN: bu üç yol elle senkron tutuluyordu ve asimetri oluşmuştu.
# 'rate-profiles.conf' üçünde de vardı, 'resource-profiles.conf' HİÇBİRİNDE
# yoktu. Sonuç sessizdi: install.sh ile kuranlar profil dosyasını alıyor,
# 'srvctl self-update' ile güncelleyenler ALMIYORDU. Profil tablosu
# değiştiğinde bu ikinci grup eski değerlerde kalır ve resource_profile_load
# (lib/core.sh) dosya yokken gömülü varsayılanlara düştüğü için fark
# GİZLENİRDİ — hiçbir hata mesajı üretilmezdi.
#
# KİLİT: dosya listesi artık TEK kaynaktan (_SELFUPDATE_DATA_CONFS) geliyor.
# Aşağıdaki testler hem listenin içeriğini hem de ÜÇ yolun da o listeyi
# gerçekten kullandığını doğrular — biri listeyi atlarsa asimetri geri döner.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

log_action() { :; }

# SRVCTL_ROOT override'ı selfupdate.sh SOURCE EDİLMEDEN ÖNCE yapılmalı:
# SRVCTL_SELFUPDATE_PIN/.BACKUPS/.CURRENT_COMMIT dosya başında ondan türetilir
# (aynı desen: tests/test_selfupdate_pin_guidance.sh).
SRVCTL_ROOT="$(mktemp -d)"
mkdir -p "${SRVCTL_ROOT}/bin" "${SRVCTL_ROOT}/lib" "${SRVCTL_ROOT}/conf" \
         "${SRVCTL_ROOT}/templates" "${SRVCTL_ROOT}/completions"
source "${REPO_ROOT}/lib/selfupdate.sh"

# Yedek dizini root sahipliği kapısı (_selfupdate_restore_from_backup) —
# macOS/CI'da test kullanıcısı root DEĞİL, bu yüzden sahiplik sorgusu
# mock'lanır. Kapının KENDİSİ ayrı bir testin konusudur; burada taşınan
# DOSYA KÜMESİ ölçülüyor.
_stat_owner() { echo "root"; }

echo "── Bölüm A: liste her iki veri tablosunu da içeriyor ──"
all_confs="${_SELFUPDATE_DATA_CONFS[*]}"
assert_contains "$all_confs" "rate-profiles.conf"     "rate-profiles.conf listede"
assert_contains "$all_confs" "resource-profiles.conf" "resource-profiles.conf listede (REGRESYON KİLİDİ)"

echo "── Bölüm B: kurulum — staging'deki her iki tablo da kurulur ──"
STAGING="$(mktemp -d)"
mkdir -p "${STAGING}/bin" "${STAGING}/lib" "${STAGING}/conf" \
         "${STAGING}/templates" "${STAGING}/completions"
printf '#!/bin/bash\n' > "${STAGING}/bin/srvctl"
printf 'YENI_RATE\n'     > "${STAGING}/conf/rate-profiles.conf"
printf 'YENI_RESOURCE\n' > "${STAGING}/conf/resource-profiles.conf"
# Operatörün dosyası: staging'de olsa BİLE canlıya taşınmamalı.
printf 'SAHTE_SIR=staging-surumu\n' > "${STAGING}/conf/srvctl.conf"
printf 'ESKI_RATE\n'      > "${SRVCTL_ROOT}/conf/rate-profiles.conf"
printf 'ESKI_RESOURCE\n'  > "${SRVCTL_ROOT}/conf/resource-profiles.conf"
printf 'GERCEK_SIR=canli\n' > "${SRVCTL_ROOT}/conf/srvctl.conf"

_selfupdate_install_from_staging "$STAGING"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/rate-profiles.conf")"     "YENI_RATE" \
    "rate-profiles.conf güncellendi"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf")" "YENI_RESOURCE" \
    "resource-profiles.conf güncellendi (eskiden HİÇ güncellenmiyordu)"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/srvctl.conf")" "GERCEK_SIR=canli" \
    "conf/srvctl.conf'a DOKUNULMADI (operatörün sırları korunur)"

echo "── Bölüm C: yedekleme — her iki tablo da yedeğe girer ──"
BACKUP_DIR="$(_selfupdate_backup_current)"
assert_ok test -f "${BACKUP_DIR}/conf/rate-profiles.conf"
assert_ok test -f "${BACKUP_DIR}/conf/resource-profiles.conf"
assert_eq "$(cat "${BACKUP_DIR}/conf/resource-profiles.conf")" "YENI_RESOURCE" \
    "yedeğe o anki içerik girdi"
assert_fail test -f "${BACKUP_DIR}/conf/srvctl.conf"   # sır birikimi önlenir (O12)

echo "── Bölüm D: geri yükleme — her iki tablo da geri döner ──"
printf 'BOZUK_RATE\n'     > "${SRVCTL_ROOT}/conf/rate-profiles.conf"
printf 'BOZUK_RESOURCE\n' > "${SRVCTL_ROOT}/conf/resource-profiles.conf"
_selfupdate_restore_from_backup "$BACKUP_DIR" >/dev/null 2>&1
assert_eq "$(cat "${SRVCTL_ROOT}/conf/rate-profiles.conf")"     "YENI_RATE" \
    "rate-profiles.conf geri yüklendi"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf")" "YENI_RESOURCE" \
    "resource-profiles.conf geri yüklendi (rollback artık eksiksiz)"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/srvctl.conf")" "GERCEK_SIR=canli" \
    "rollback da conf/srvctl.conf'a dokunmaz"

echo "── Bölüm E: eksik dosya çökme ÜRETMEZ (yeni kurulum senaryosu) ──"
FRESH="$(mktemp -d)"; mkdir -p "${FRESH}/bin" "${FRESH}/lib" "${FRESH}/conf"
printf '#!/bin/bash\n' > "${FRESH}/bin/srvctl"
printf 'SADECE_RATE\n' > "${FRESH}/conf/rate-profiles.conf"   # resource-profiles YOK
assert_ok _selfupdate_install_from_staging "$FRESH"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/rate-profiles.conf")" "SADECE_RATE" \
    "var olan tablo yine de kuruldu"
assert_eq "$(cat "${SRVCTL_ROOT}/conf/resource-profiles.conf")" "YENI_RESOURCE" \
    "staging'de olmayan tablo canlıda OLDUĞU GİBİ kalır (silinmez)"

rm -rf "$SRVCTL_ROOT" "$STAGING" "$FRESH"
test_summary
