#!/bin/bash
# AppArmor shared/<dizin> kapsam denetimi — üretici/tüketici drift dedektörü.
#
# NEDEN VAR (gerçek Ubuntu 22.04 VM'de KANITLANMIŞ bug): 'srvctl deploy'
# (lib/deploy.sh:_deploy_run, 'shared_pairs' dizisi) framework'e göre
# release içindeki bir alt yolu (writable/storage/bootstrap-cache/var)
# shared/<ad>'a symlink'ler (bkz. _deploy_link_shared). AppArmor bir
# symlink'i ÇÖZER ve GERÇEK (shared) yolu denetler — release-yolu için
# yazılmış bir kural (ör. 'releases/**/bootstrap/cache/**') bu yüzden HİÇ
# EŞLEŞMEZ. Gerçek dünya kanıtı: Laravel deploy'unda 'shared/bootstrap-cache'
# templates/apparmor/profile.tpl'de YOKTU — 'tempnam()'/PackageManifest
# yazımı reddedildi, HTTP 500 + "Class 'view' does not exist" (service
# provider keşfi bootstrap/cache/services.php'ye bağımlı).
#
# Bu, ÜÇ framework'ün TAMAMI için tekrarlanabilecek bir SINIF hatasıdır:
# 'shared_pairs'e yeni bir '"relpath:subdir"' eklenir (lib/deploy.sh —
# ÜRETİCİ) ama templates/apparmor/profile.tpl / profile-cli.tpl'e (TÜKETİCİ)
# karşılık gelen 'shared/<subdir>/**' yazma kuralı eklenmeyi UNUTULUR.
# Sonuç sessizdir: deploy "başarılı" biter, symlink kurulur, ama ilk yazma
# denemesinde AppArmor DENIED verir (audit.log'da görünür, ama kimse deploy
# anında bakmaz) — uygulama HTTP 500 ile patlar.
#
# İKİNCİ, AYNI OTURUMDA VM'DE ÖLÇÜLEN katman: 'k' (dosya kilidi) izni.
# 'rw' TEK BAŞINA flock(2)/LOCK_EX'e YETMEZ — AppArmor'da kilitleme AYRI bir
# izin harfidir. shared/bootstrap-cache eklenip 'rw' verildiğinde Laravel
# HÂLÂ HTTP 500 veriyordu ("Exclusive locks are not supported for this
# stream" — Illuminate\Filesystem\Filesystem::put($lock=true)); domain-içi
# TÜM yazma kuralları 'rwk,' yapılınca (VM'de doğrulandı) HTTP 200 döndü.
# Bu yüzden bu test yalnız kuralın VARLIĞINI değil, 'k' iznini de denetler.
#
# TEST_TEMPLATE_TOKENS/test_meta_key_registry/test_disable_functions_sync
# İLE AYNI DESEN: ÜRETİCİYİ (lib/deploy.sh'taki 'shared_pairs=(...)'
# atamaları) STATİK olarak tara, TÜKETİCİYİ (profil dosyalarındaki gerçek
# '{{WEB_ROOT}}/{{DOMAIN}}/shared/<ad>/**' kuralları) STATİK olarak tara,
# İKİSİNİ KARŞILAŞTIR. Hiçbir render/apparmor_parser ÇALIŞTIRILMAZ (macOS'ta
# çalıştırılamaz) — bu tamamen metin taramasıdır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

DEPLOY_SH="${REPO_ROOT}/lib/deploy.sh"
PROFILE_TPL="${REPO_ROOT}/templates/apparmor/profile.tpl"
PROFILE_CLI_TPL="${REPO_ROOT}/templates/apparmor/profile-cli.tpl"

# ─── ÜRETİCİ tarayıcı: 'shared_pairs=(...)' atamalarından ':'den SONRAKİ
#     (gerçek shared/ alt dizin adı) kısmı çıkarır. Girdi bir DOSYA YOLU
#     DEĞİL, METİN'dir (fixture'larla da test edilebilsin diye) ───
_deploy_extract_shared_subdirs() {
    local text="$1"
    printf '%s\n' "$text" \
        | grep -oE 'shared_pairs=\([^)]*\)' \
        | grep -oE '"[^"]*"' \
        | sed -E 's/^"//; s/"$//' \
        | grep ':' \
        | sed -E 's/^.*://' \
        | sort -u
}

# ─── TÜKETİCİ tarayıcı: verilen profil metninde 'shared/<subdir>/**' yazma
#     kuralının izin harflerini (ör. 'rwk') döndürür; kural yoksa boş döner.
#     Girdi METİN'dir (dosya değil) — fixture'larla test edilebilir. ───
_aa_shared_rule_perm() {
    local text="$1" subdir="$2"
    printf '%s\n' "$text" \
        | grep -F "{{WEB_ROOT}}/{{DOMAIN}}/shared/${subdir}/**" \
        | grep -oE '[a-zA-Z]+,[[:space:]]*$' \
        | head -1 \
        | tr -d ', \t'
}

# ═══════════════════════════════════════════════════════════════
# KENDİ KENDİNİ DOĞRULAMA — tarayıcı bozulursa sessizce hep PASS vermemeli.
# Sentetik fixture'lar: gerçek dosyalar HİÇ dokunulmadan, saf metinle test.
# ═══════════════════════════════════════════════════════════════
echo "== Kendi kendini doğrulama (sentetik fixture) =="

fixture_producer='
    case "$FRAMEWORK" in
        ci4)     shared_pairs=("writable:writable") ;;
        laravel) shared_pairs=("storage:storage" "bootstrap/cache:bootstrap-cache") ;;
        symfony) shared_pairs=("var:var") ;;
    esac
'
producer_out="$(_deploy_extract_shared_subdirs "$fixture_producer" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "$producer_out" "bootstrap-cache storage var writable" \
    "üretici tarayıcı: sentetik 'shared_pairs' bloğundan doğru 4 alt dizini çıkarıyor"

# (a) Kural TAMAMEN eksik — dedektör 'kural yok' u yakalamalı
fixture_missing_rule='
  {{WEB_ROOT}}/{{DOMAIN}}/shared/storage/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var/** rwk,
'
perm_missing="$(_aa_shared_rule_perm "$fixture_missing_rule" "bootstrap-cache")"
assert_eq "$perm_missing" "" \
    "dedektör: 'shared/bootstrap-cache' kuralı HİÇ yokken boş dönüyor (BULGU üretir)"

# (b) Kural var ama yalnız 'rw' — 'k' EKSİK (VM'de kanıtlanan ikinci katman)
fixture_no_lock='
  {{WEB_ROOT}}/{{DOMAIN}}/shared/bootstrap-cache/** rw,
'
perm_no_lock="$(_aa_shared_rule_perm "$fixture_no_lock" "bootstrap-cache")"
assert_eq "$perm_no_lock" "rw" \
    "dedektör: 'rw' (k'siz) kuralı doğru okuyor"
assert_not_contains "$perm_no_lock" "k" \
    "dedektör: 'k' eksikliğini doğru tespit ediyor (YANLIŞ POZİTİF yok)"

# (c) Kontrol grubu: doğru kural ('rwk') — YANLIŞ POZİTİF üretmemeli
fixture_ok='
  {{WEB_ROOT}}/{{DOMAIN}}/shared/bootstrap-cache/** rwk,
'
perm_ok="$(_aa_shared_rule_perm "$fixture_ok" "bootstrap-cache")"
assert_contains "$perm_ok" "w" "kontrol grubu: 'rwk' kuralında yazma izni bulunuyor"
assert_contains "$perm_ok" "k" "kontrol grubu: 'rwk' kuralında kilit izni bulunuyor"

# ═══════════════════════════════════════════════════════════════
# ASIL DENETİM — gerçek lib/deploy.sh + gerçek profil şablonları
# ═══════════════════════════════════════════════════════════════
echo ""
echo "== Gerçek lib/deploy.sh + templates/apparmor/*.tpl denetimi =="

deploy_text="$(cat "$DEPLOY_SH")"
subdirs="$(_deploy_extract_shared_subdirs "$deploy_text")"

assert_eq "$(test -n "$subdirs" && echo yes)" "yes" \
    "lib/deploy.sh'ta en az bir 'shared_pairs' ataması bulundu (dedektör kör DEĞİL)"

for tpl in "$PROFILE_TPL" "$PROFILE_CLI_TPL"; do
    rel="${tpl#"${REPO_ROOT}"/}"
    [[ -f "$tpl" ]] || { assert_eq "eksik" "var" "${rel} dosyası bulunamadı"; continue; }
    tpl_text="$(cat "$tpl")"
    for subdir in $subdirs; do
        perm="$(_aa_shared_rule_perm "$tpl_text" "$subdir")"
        assert_contains "$perm" "w" \
            "${rel}: 'shared/${subdir}/**' için yazma (w) kuralı var"
        assert_contains "$perm" "k" \
            "${rel}: 'shared/${subdir}/**' için kilit (k) izni var (flock/LOCK_EX)"
    done
done

test_summary
