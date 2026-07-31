#!/bin/bash
# _deploy_relative_link + _deploy_link_current: chroot symlink sözleşmesi.
#
# FPM per-domain pool chroot=/var/www/<domain> ile çalışır; public_html MUTLAK
# bir yola işaret ederse chroot içinde çözülemez ("No input file specified").
# Commit 4374021 bunu deploy/rollback yollarında düzeltti ama OTOMATİK ROLLBACK
# dalını (deploy.sh:237) atlamıştı — yani sağlık kontrolü patladığında devreye
# giren kurtarma yolunun kendisi bozuktu.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

base="${WEB_ROOT}/example.com"
mkdir -p "${base}/releases/20260101_000001/public"
mkdir -p "${base}/releases/20260102_000002"

# ── _deploy_relative_link: mutlak → göreli ──
assert_eq "$(_deploy_relative_link "$base" "${base}/releases/20260101_000001/public")" \
          "releases/20260101_000001/public" "public'li release göreliye çevrildi"
assert_eq "$(_deploy_relative_link "$base" "${base}/releases/20260102_000002")" \
          "releases/20260102_000002" "public'siz release göreliye çevrildi"

# releases/ dışındaki hedefler REDDEDİLİR (çağıran rollback yapmaz)
assert_fail _deploy_relative_link "$base" "/etc/passwd"
assert_fail _deploy_relative_link "$base" "${base}/public_html"
assert_fail _deploy_relative_link "$base" ""
assert_fail _deploy_relative_link "$base" "${base}/releases/../../../etc"

# ── _deploy_link_current: MUTLAK hedefi reddet ──
assert_fail _deploy_link_current "$base" "${base}/releases/20260101_000001/public"
assert_fail _deploy_link_current "$base" "/var/www/example.com/releases/x/public"
assert_fail _deploy_link_current "$base" ""

# ── Göreli hedef kabul edilir ve symlink kurulur ──
assert_ok _deploy_link_current "$base" "releases/20260101_000001/public"
assert_eq "$(readlink "${base}/public_html")" "releases/20260101_000001/public" \
          "public_html GÖRELİ symlink oldu"

# ── Değiştirme: eski symlink'in üzerine yazar ──
assert_ok _deploy_link_current "$base" "releases/20260102_000002"
assert_eq "$(readlink "${base}/public_html")" "releases/20260102_000002" \
          "symlink yeni release'e çevrildi"

# ── public_html GERÇEK bir dizinse üzerine yazmayı reddet ──
# (eski _deploy_rollback 'rm -rf "$public_dir"' ile tüm siteyi silebiliyordu)
base2="${WEB_ROOT}/gercek.example.com"
mkdir -p "${base2}/releases/20260101_000001"
mkdir -p "${base2}/public_html"
echo "onemli" > "${base2}/public_html/index.php"
_deploy_link_current "$base2" "releases/20260101_000001" >/dev/null 2>&1
assert_eq "$(cat "${base2}/public_html/index.php" 2>/dev/null)" "onemli" \
          "gerçek public_html dizini silinmedi"

# Geçici artefakt bırakmıyor
assert_eq "$(find "$base" "$base2" -maxdepth 1 -name '.public_html.new.*' | wc -l | tr -d ' ')" "0" \
          "geçici symlink artefaktı temizlendi"

rm -rf "$WEB_ROOT"
test_summary
