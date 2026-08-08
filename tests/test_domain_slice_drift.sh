#!/bin/bash
# cgroups slice drift'i: 'domain repair' denetimi + 'domain resources --reset'.
#
# KÖK SORUN: '_apply_cgroups_slice' yalnız 'domain add' yolundan çağrılıyordu.
# Kaynak profili sistemine geçildikten sonra MEVCUT domainlerin slice'ları
# ASLA güncellenmedi — HOST'ta bir domain'in slice'ı aylarca eski sabitlerde
# (MemoryMax=512M/MemoryHigh=450M/MemorySwapMax=0) kaldı, oysa 'standard'
# profili 2048M/2304M/256M üretir.
#
# TASARIM KİLİDİ: repair mevcut bir slice'ı ASLA körlemesine EZMEZ (operatörün
# 'domain resources' ile yaptığı bilinçli ayar sessizce geri alınmamalı) —
# yalnız (a) dosya hiç yoksa oluşturur, (b) objektif olarak yanlış üç durumu
# raporlar. "Profilden farklı olmak" TEK BAŞINA bulgu DEĞİLDİR.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
systemctl() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

_run_isolated() { ( "$@" ); }

d="driftdom.example.com"
sname="$(safe_name "$d")"
mkdir -p "${WEB_ROOT}/${d}"
SLICE="${SRVCTL_SYSTEMD_DIR}/srvctl-${sname}.slice"

# Meta yok → profil 'standard' (ondemand:8:256:120):
#   MemoryHigh=8×256=2048M, MemoryMax=2048×9/8=2304M, MemorySwapMax=2048/8=256M
echo "── Bölüm A: slice YOKSA repair adımı onu OLUŞTURUR ──"
rm -f "$SLICE"
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_ok test -f "$SLICE"
conf=$(cat "$SLICE" 2>/dev/null)
assert_contains "$conf" "MemoryHigh=2048M"    "profil MemoryHigh uygulandı"
assert_contains "$conf" "MemoryMax=2304M"     "profil MemoryMax uygulandı (%12,5 pay)"
assert_contains "$conf" "MemorySwapMax=256M"  "profil MemorySwapMax uygulandı (0 DEĞİL)"
assert_contains "$conf" "TasksMax=120"        "profil TasksMax uygulandı"

echo "── Bölüm B: SAĞLIKLI slice EZİLMEZ ve bulgu üretmez ──"
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_not_contains "$out" "düzeltilmesi gereken" "sağlıklı slice'ta uyarı yok"
assert_contains "$(cat "$SLICE")" "MemoryMax=2304M" "içerik değişmedi"

echo "── Bölüm C: operatörün BİLİNÇLİ ayarı bulgu SAYILMAZ ──"
# Profilden farklı ama kendi içinde tutarlı: High<Max, swap>0, Max>=tepe talep.
cat > "$SLICE" <<'EOF'
[Slice]
CPUQuota=200%
MemoryMax=4096M
MemoryHigh=3600M
MemorySwapMax=450M
IOWeight=100
TasksMax=200
EOF
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_not_contains "$out" "düzeltilmesi gereken" \
    "profilden farklı ama tutarlı ayar UYARI ÜRETMEZ (gürültü yok)"
assert_contains "$(cat "$SLICE")" "MemoryMax=4096M" "operatör ayarı EZİLMEDİ"

echo "── Bölüm D: MemorySwapMax=0 yakalanır ──"
cat > "$SLICE" <<'EOF'
[Slice]
MemoryMax=2304M
MemoryHigh=2048M
MemorySwapMax=0
TasksMax=120
EOF
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_contains "$out" "MemorySwapMax=0" "swap=0 bulgusu raporlanır"
assert_contains "$out" "--reset"         "düzeltme yolu gösterilir"
assert_contains "$(cat "$SLICE")" "MemorySwapMax=0" "bulgu raporlanır ama EZİLMEZ"

echo "── Bölüm E: MemoryHigh == MemoryMax yakalanır ──"
cat > "$SLICE" <<'EOF'
[Slice]
MemoryMax=2048M
MemoryHigh=2048M
MemorySwapMax=256M
TasksMax=120
EOF
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_contains "$out" "throttle" "High==Max bulgusu raporlanır"

echo "── Bölüm F: kapasite açığı (Max < havuz tepe talebi) yakalanır ──"
# HOST'ta gerçekten görülen durum: 512M tavan, 8×256M=2048M talep.
cat > "$SLICE" <<'EOF'
[Slice]
MemoryMax=512M
MemoryHigh=450M
MemorySwapMax=64M
TasksMax=100
EOF
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_contains "$out" "tavan yetmez" "kapasite açığı raporlanır"
assert_contains "$out" "2048M"        "havuz tepe talebi sayıyla gösterilir"

echo "── Bölüm G: 'infinity' tavan kapasite bulgusu ÜRETMEZ ──"
cat > "$SLICE" <<'EOF'
[Slice]
MemoryMax=infinity
MemoryHigh=2048M
MemorySwapMax=256M
TasksMax=120
EOF
out=$(_run_isolated _domain_repair_cgroups_slice "$d" "$sname" 2>&1)
assert_not_contains "$out" "tavan yetmez" "'infinity' sınırsızlıktır, kıyaslanmaz"

echo "── Bölüm H: 'resources --reset' profile döndürür ──"
cat > "$SLICE" <<'EOF'
[Slice]
CPUQuota=200%
MemoryMax=512M
MemoryHigh=512M
MemorySwapMax=0
IOWeight=300
TasksMax=100
EOF
_run_isolated _domain_resources "$d" --reset >/dev/null 2>&1
conf=$(cat "$SLICE")
assert_contains "$conf" "MemoryHigh=2048M"   "--reset: MemoryHigh profile döndü"
assert_contains "$conf" "MemoryMax=2304M"    "--reset: MemoryMax profile döndü"
assert_contains "$conf" "MemorySwapMax=256M" "--reset: MemorySwapMax profile döndü (0 kurtarıldı)"
assert_contains "$conf" "TasksMax=120"       "--reset: TasksMax profile döndü"
assert_contains "$conf" "CPUQuota=200%"      "--reset: CPU KORUNDU (profil sözleşmesinde yok)"
assert_contains "$conf" "IOWeight=300"       "--reset: IO KORUNDU"

echo "── Bölüm I: --reset + açık bayrak → bayrak üstüne yazar ──"
_run_isolated _domain_resources "$d" --reset --cpu=50% >/dev/null 2>&1
conf=$(cat "$SLICE")
assert_contains "$conf" "CPUQuota=50%"       "--reset ile birlikte verilen --cpu uygulandı"
assert_contains "$conf" "MemorySwapMax=256M" "--reset bellek tarafını yine de düzeltti"

echo "── Bölüm J: bayraksız çağrı hâlâ reddedilir ──"
assert_fail _run_isolated _domain_resources "$d"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR"
test_summary
