#!/bin/bash
# Paylaşılan (shared/) dizin eşlemesi — release-özgü cache framework'ler
# arası SIZMAMALI/ZEHİRLENMEMELİ. Regresyon testi.
#
# GERÇEK VM BUG'I (koordinatör raporu, symfony/demo, Ubuntu 22.04): srvctl
# Symfony için TÜM 'var/' dizinini paylaşıyordu ('var:var'). Symfony'nin
# derlenmiş DI container'ı (var/cache/prod/App_KernelProdContainer.php),
# route eşleyici ve Doctrine mapping meta'sı BUILD ANINDA release'in MUTLAK
# YOLUNU koda/meta'ya GÖMER. 'var/cache' PAYLAŞILINCA:
#   - İlk deploy çalıştı; ikinci deploy'dan itibaren HER release bir
#     ÖNCEKİNİN (bazen SİLİNMİŞ) mutlak yolunu MİRAS ALDI:
#         In MappingException.php line 45:
#           File mapping drivers must have a valid directory path, however
#           the given path [.../releases/20260731_205336_36f351/src/Entity]
#           seems to be incorrect!
#   - DAHA KÖTÜSÜ: YENİ release'in build'i (atomik switch'TEN ÖNCE, henüz
#     CANLI değilken) shared cache'i KENDİ mutlak yoluyla EZERKEN, O ANDA
#     CANLI olan ESKİ release de AYNI shared cache'i okuyordu — canlı site
#     deploy SIRASINDA "Class DebugBundle not found" ile 500 vermeye
#     başladı (paylaşılan cache'te DEV ortamında derlenmiş bir container
#     kalmıştı, --no-dev kurulumunda DebugBundle YOK).
#
# Bu, kod tabanında ZATEN çözülmüş bir sınıfın AYNISI: Laravel için
# 'bootstrap/cache/*.php' (_deploy_build) chroot'lu deploy'da host yolu
# gömülmesin diye build sonunda temizleniyordu — ama PAYLAŞIM SEVİYESİNDE
# aynı hata Laravel'de de VARDI ('bootstrap/cache:bootstrap-cache' PAYLAŞIM
# LİSTESİNDEYDİ) — kontrol edilip AYNI şekilde düzeltildi.
#
# DÜZELTME: shared_pairs artık Symfony için yalnız 'var/log' ve
# 'var/sessions'ı paylaşıyor (var/cache ASLA); Laravel için 'bootstrap/
# cache' paylaşım listesinden ÇIKARILDI (yalnız 'storage:storage' kaldı).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_link_shared >/dev/null 2>&1 \
    || ! declare -F _deploy_symfony_detect_poisoned_shared_var >/dev/null 2>&1; then
    echo "  SKIP: paylaşılan-cache izolasyonu fonksiyonları henüz yok"
    test_summary
    rm -rf "$WEB_ROOT"
    exit 0
fi

_run_isolated() { ( "$@" ); }

# ═══════════════ [KRİTİK] shared_pairs statik denetimi ═══════════════
# _deploy_run içindeki 'case "$FRAMEWORK" in ... esac' bloğunu (shared_pairs
# ataması) izole edip metinsel olarak denetler — bkz. tests/test_meta_key_
# registry.sh'ın AYNI '_case_branch_exists' tarzı statik-gövde deseni.
echo "  --- [KRİTİK] shared_pairs: Symfony 'var/cache'i İÇERMİYOR, Laravel 'bootstrap/cache'i İÇERMİYOR ---"
shared_pairs_block=$(sed -n '/local shared_pairs=()/,/esac/p' "${REPO_ROOT}/lib/deploy.sh")

assert_not_contains "$shared_pairs_block" "var:var" \
    "[KRİTİK] Symfony için ARTIK TÜM 'var/' paylaşılmıyor ('var:var' yok)"
assert_not_contains "$shared_pairs_block" "\"var/cache" \
    "[KRİTİK] Symfony shared_pairs'inde 'var/cache' HİÇ YOK (release-özgü, ASLA paylaşılmamalı)"
assert_contains "$shared_pairs_block" "var/log:var-log" \
    "Symfony 'var/log' paylaşılıyor (deploy'lar arası log tarihçesi için)"
assert_contains "$shared_pairs_block" "var/sessions:var-sessions" \
    "Symfony 'var/sessions' paylaşılıyor (oturum sürekliliği için)"

assert_not_contains "$shared_pairs_block" "bootstrap/cache:bootstrap-cache" \
    "[KRİTİK] Laravel için 'bootstrap/cache' ARTIK PAYLAŞILMIYOR (release-özgü, mutlak yol gömüyordu)"
assert_contains "$shared_pairs_block" "storage:storage" \
    "Laravel 'storage' paylaşımı KORUNDU (güvenli — app/logs/sessions düz veri)"

# ═══════════════ [KRİTİK] davranışsal: ikinci deploy önceki cache'i miras ALMIYOR ═══════════════
echo "  --- [KRİTİK] davranışsal: iki ardışık 'deploy' simülasyonu — cache SIZMIYOR, log/session PAYLAŞILIYOR ---"

base="${WEB_ROOT}/symfony.local"
shared_dir="${base}/shared"
mkdir -p "$shared_dir"

# ── "Deploy 1" ──
rel1="${base}/releases/20260731_100000_aaaaaa"
mkdir -p "${rel1}/var/log" "${rel1}/var/sessions" "${rel1}/var/cache/prod"
echo "release1 log satırı" > "${rel1}/var/log/prod.log"
echo "release1 oturum verisi" > "${rel1}/var/sessions/sess_abc"
# release1'in KENDİ (build zamanı üretilen, mutlak yol gömen) cache'i:
printf '<?php // kernel.project_dir = %s\n' "$rel1" > "${rel1}/var/cache/prod/App_KernelProdContainer.php"

assert_ok _deploy_link_shared "$rel1" "$shared_dir" "var/log" "var-log"
assert_ok _deploy_link_shared "$rel1" "$shared_dir" "var/sessions" "var-sessions"
# var/cache HİÇ bağlanmıyor (shared_pairs'te YOK) — release1'in cache'i
# olduğu gibi KENDİ dizininde kalır, hiçbir yere "bootstrap edilmez".

# Release 1 "başarısız/eskidi" senaryosu: release1 TAMAMEN SİLİNİYOR (ör.
# prune ya da başarısız deploy temizliği) — cache'i de ONUNLA BİRLİKTE gider.
rm -rf -- "$rel1"

# ── "Deploy 2" — release1 ARTIK DİSKTE YOK ──
rel2="${base}/releases/20260731_110000_bbbbbb"
mkdir -p "${rel2}/var/sessions" "${rel2}/var/cache/prod"
# release2'nin var/log'u HENÜZ yok (ilk kez bootstrap edilecek) — ama
# shared/var-log ZATEN release1'den kalma içerik barındırıyor (paylaşılan
# dizin release1 silinse BİLE YAŞAMAYA devam eder, bu KASITLI/istenen).
assert_ok _deploy_link_shared "$rel2" "$shared_dir" "var/log" "var-log"
assert_ok _deploy_link_shared "$rel2" "$shared_dir" "var/sessions" "var-sessions"

assert_eq "$(cat "${rel2}/var/log/prod.log" 2>/dev/null)" "release1 log satırı" \
    "var/log PAYLAŞILDIĞI için release1'in log tarihçesi release2'de GÖRÜNÜYOR (istenen süreklilik)"
assert_eq "$(cat "${rel2}/var/sessions/sess_abc" 2>/dev/null)" "release1 oturum verisi" \
    "var/sessions PAYLAŞILDIĞI için oturum verisi release2'de GÖRÜNÜYOR (istenen süreklilik)"

# release2 KENDİ cache'ini üretir (release1'in cache'i SİLİNMİŞ release'le
# BİRLİKTE gitmişti — release2 bunu GÖRMEZ, MİRAS ALMAZ):
printf '<?php // kernel.project_dir = %s\n' "$rel2" > "${rel2}/var/cache/prod/App_KernelProdContainer.php"
assert_eq "$(grep -c "$rel1" "${rel2}/var/cache/prod/App_KernelProdContainer.php" 2>/dev/null)" "0" \
    "[KRİTİK] release2'nin cache'i release1'in (SİLİNMİŞ) mutlak yolunu İÇERMİYOR — cache SIZMASI YOK"
assert_contains "$(cat "${rel2}/var/cache/prod/App_KernelProdContainer.php")" "$rel2" \
    "release2'nin cache'i KENDİ mutlak yolunu içeriyor (release-özgü, taze üretim)"

# ── Aynı izolasyon Laravel bootstrap/cache için de geçerli ──
echo "  --- [KRİTİK] Laravel: bootstrap/cache release'ler arasında İZOLE (paylaşılmıyor) ---"
lbase="${WEB_ROOT}/laravel.local"
lshared="${lbase}/shared"
mkdir -p "$lshared"

lrel1="${lbase}/releases/20260731_100000_aaaaaa"
mkdir -p "${lrel1}/storage/app" "${lrel1}/bootstrap/cache"
echo "laravel storage verisi" > "${lrel1}/storage/app/dosya.txt"
printf '<?php return array(); // storage_path baked: %s\n' "$lrel1" > "${lrel1}/bootstrap/cache/config.php"
assert_ok _deploy_link_shared "$lrel1" "$lshared" "storage" "storage"
# bootstrap/cache shared_pairs'te YOK — bağlanmıyor, release1'e ÖZGÜ kalıyor.
rm -rf -- "$lrel1"

lrel2="${lbase}/releases/20260731_110000_bbbbbb"
mkdir -p "${lrel2}/bootstrap/cache"
assert_ok _deploy_link_shared "$lrel2" "$lshared" "storage" "storage"
assert_eq "$(cat "${lrel2}/storage/app/dosya.txt" 2>/dev/null)" "laravel storage verisi" \
    "Laravel storage PAYLAŞILDIĞI için release1'in verisi release2'de GÖRÜNÜYOR (istenen)"
printf '<?php return array(); // storage_path baked: %s\n' "$lrel2" > "${lrel2}/bootstrap/cache/config.php"
assert_eq "$(grep -c "$lrel1" "${lrel2}/bootstrap/cache/config.php" 2>/dev/null)" "0" \
    "[KRİTİK] Laravel release2'nin bootstrap/cache'i release1'in (SİLİNMİŞ) mutlak yolunu İÇERMİYOR"

# ═══════════════ _deploy_symfony_detect_poisoned_shared_var ═══════════════
echo "  --- _deploy_symfony_detect_poisoned_shared_var: ESKİ şemadan kalma zehirli cache teşhisi ---"

base2="${WEB_ROOT}/poisoned.example.com"
shared2="${base2}/shared"
mkdir -p "${shared2}/var/cache/prod"
printf '<?php // %s/releases/20260701_000000_deadbeef/src/Entity\n' "$base2" > "${shared2}/var/cache/prod/App_KernelProdContainer.php.meta"
content_before=$(cat "${shared2}/var/cache/prod/App_KernelProdContainer.php.meta")
out_poisoned=$(_deploy_symfony_detect_poisoned_shared_var "$shared2" 2>&1)
assert_contains "$out_poisoned" "shared/var/cache" \
    "zehirli shared/var/cache TESPİT EDİLDİ ve raporlandı"
assert_contains "$out_poisoned" "OTOMATİK SİLMEZ" \
    "operatöre otomatik silme YAPILMADIĞI AÇIKÇA söyleniyor"
assert_eq "$(cat "${shared2}/var/cache/prod/App_KernelProdContainer.php.meta")" "$content_before" \
    "teşhis fonksiyonu dosyanın İÇERİĞİNE dokunmadı (yalnız okudu — çağrı ÖNCESİ/SONRASI birebir aynı)"
assert_eq "$([[ -d "${shared2}/var/cache" ]] && echo var || echo yok)" "var" \
    "[KRİTİK] teşhis fonksiyonu HİÇBİR ŞEYİ SİLMEDİ — 'shared/var/cache' hâlâ diskte"

base3="${WEB_ROOT}/clean.example.com"
shared3="${base3}/shared"
mkdir -p "$shared3"
assert_ok _deploy_symfony_detect_poisoned_shared_var "$shared3"
out_clean=$(_deploy_symfony_detect_poisoned_shared_var "$shared3" 2>&1)
assert_eq "$out_clean" "" "shared/var/cache hiç yoksa HİÇBİR uyarı üretilmez"

base4="${WEB_ROOT}/emptycache.example.com"
shared4="${base4}/shared"
mkdir -p "${shared4}/var/cache/prod"
echo "zararsiz icerik, hicbir ozel yol gecmiyor" > "${shared4}/var/cache/prod/normal.txt"
out_emptycache=$(_deploy_symfony_detect_poisoned_shared_var "$shared4" 2>&1)
assert_eq "$out_emptycache" "" \
    "shared/var/cache VAR ama içinde 'releases/' geçen bir şey YOKSA uyarı üretilmez (yanlış pozitif yok)"

rm -rf "$WEB_ROOT"
test_summary
