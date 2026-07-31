#!/bin/bash
# Chroot ↔ host yol uzayı çatışması regresyonu (gerçek Laravel 13.x deploy'unda
# ölçüldü, Ubuntu 22.04 VM).
#
# KÖK NEDEN: build adımı (composer install + artisan config:cache/route:cache/
# view:cache/event:cache) HER ZAMAN host'ta, chroot'un DIŞINDA, web_user olarak
# çalışır. Laravel'in composer 'post-autoload-dump' script'i (package:discover)
# ve 'artisan config:cache' HOST'un mutlak yolunu (ör.
# /var/www/laravel.local/releases/<id>/...) 'bootstrap/cache/*.php'ye GÖMER.
# FPM chroot'lu çalıştığından (pool.conf.tpl: 'chroot = {{WEB_ROOT}}/{{DOMAIN}}')
# ve open_basedir chroot-GÖRELİ yollarla sınırlı olduğundan bu gömülü HOST yolu
# asla ÇÖZÜLEMEZ:
#   is_dir(): open_basedir restriction in effect.
#   File(/var/www/laravel.local/releases/.../resources/views/vendor/laravel-exceptions)
# → HTTP 500. VM'DE KANITLANAN düzeltme: 'bootstrap/cache/*.php' build sonunda
# SİLİNİR — Laravel bunları ÇALIŞMA ZAMANINDA, chroot İÇİNDE (bu kez DOĞRU
# yollarla) yeniden üretir.
#
# Bu test dosyası ikiye ayrılır:
#   1) _deploy_chroot_active: pool config'inden chroot durumu doğru okunuyor
#      mu, belirsizlikte (pool dosyası yok) doğru yöne (aktif) mi düşüyor?
#   2) _deploy_build: chroot_active="true" iken bootstrap/cache (Laravel) ve
#      var/cache/prod (Symfony, HİPOTEZ) build sonunda GERÇEKTEN temizleniyor
#      mu; chroot_active="false" iken KÖRLEMESİNE SİLİNMİYOR mu (chroot
#      kullanılmayan kurulumlarda config:cache gerçek bir performans kazancı —
#      bu testin en kritik negatif iddiası budur). CI4 hiç etkilenmemeli.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_chroot_active >/dev/null 2>&1 || ! declare -F _deploy_build >/dev/null 2>&1; then
    echo "  SKIP: _deploy_chroot_active / _deploy_build henüz yok"
    test_summary
    rm -rf "$WEB_ROOT"
    exit 0
fi

FPM_SEAM="$(mktemp -d)"
POOL_SEAM="$(mktemp -d)"
export SRVCTL_FPM_DIR="${FPM_SEAM}"
export SRVCTL_PHP_POOL_DIR="${POOL_SEAM}"

# ═══════════════════════ _deploy_chroot_active ═══════════════════════
# ── Belirsizlik: HİÇBİR pool dosyası yok -> "chroot aktif" varsayılır ──
# (bu dosyadaki diğer fonksiyonların "belirsizlikte hiçbir şey yapma"
# fail-closed kuralının BİLİNÇLİ istisnası — bkz. kaynak yorumu: chroot'u
# "yok" sanmak KATASTROFİK/500, "var" sanmak yalnız ZARARSIZ soğuk-cache.)
assert_ok _deploy_chroot_active "yok-boyle-domain" "8.3"

# ── İzole pool config (SRVCTL_FPM_DIR) 'chroot =' içeriyor -> aktif ──
printf 'chroot = /var/www/chrootlu.example.com\n' > "${FPM_SEAM}/chrootlu.conf"
assert_ok _deploy_chroot_active "chrootlu" "8.3"

# ── İzole pool config VAR ama 'chroot' direktifi YOK -> aktif DEĞİL ──
printf 'listen = /run/php/chrootsuz.sock\n' > "${FPM_SEAM}/chrootsuz.conf"
assert_fail _deploy_chroot_active "chrootsuz" "8.3"

# ── pool.d tarzı config (SRVCTL_PHP_POOL_DIR) 'chroot =' içeriyor -> aktif ──
printf 'chroot = /var/www/pooldeki.example.com\n' > "${POOL_SEAM}/pooldeki.conf"
assert_ok _deploy_chroot_active "pooldeki" "8.3"

# ── pool.d tarzı config VAR ama chroot YOK -> aktif DEĞİL ──
printf 'listen = /run/php/pooldeki2.sock\n' > "${POOL_SEAM}/pooldeki2.conf"
assert_fail _deploy_chroot_active "pooldeki2" "8.3"

rm -rf "$FPM_SEAM" "$POOL_SEAM"
unset SRVCTL_FPM_DIR SRVCTL_PHP_POOL_DIR

# ═══════════════════════════ _deploy_build ═══════════════════════════
# runuser gerektirmeden test edebilmek için privdrop'u komple stub'la (bu
# testin amacı yetki düşürme DEĞİL, build/cleanup mantığı — bkz.
# tests/test_deploy_privdrop.sh o kısmı ZATEN ayrı test ediyor).
_deploy_privdrop() { local _u="$1"; shift; "$@"; }

# Sahte php CLI: gerçek artisan/console/spark yerine, çağrıldığı komuta göre
# MUTLAK-yol-benzeri bir HOST işareti gömülü sahte cache dosyası üretir
# (gerçek Laravel/Symfony'nin build sırasında yaptığının minyatür simülasyonu).
FAKE_PHP="$(mktemp -d)/fake-php.sh"
cat > "$FAKE_PHP" <<'EOF'
#!/bin/bash
entry="$1"; cmd="${2:-}"
dir="$(dirname "$entry")"
base="$(basename "$entry")"
case "${base}:${cmd}" in
    artisan:config:cache|artisan:route:cache|artisan:view:cache|artisan:event:cache)
        mkdir -p "${dir}/bootstrap/cache"
        printf '<?php return array(); // HOST-YOLU-ISARETI: %s\n' "$dir" \
            > "${dir}/bootstrap/cache/$(echo "$cmd" | tr ':' '-').php"
        ;;
    console:cache:clear|console:cache:warmup)
        # 'bin/console' release KÖKÜNÜN bir alt dizinindedir (bkz. gerçek
        # çağrı: "${release_dir}/bin/console") — release kökü bir seviye
        # daha yukarıda ('var/cache' orada yaşar), 'artisan'dan FARKLI.
        dir="$(dirname "$dir")"
        mkdir -p "${dir}/var/cache/prod"
        printf '<?php // kernel.project_dir HOST-YOLU-ISARETI: %s\n' "$dir" \
            > "${dir}/var/cache/prod/appKernelProdContainer.php"
        ;;
esac
exit 0
EOF
chmod +x "$FAKE_PHP"

_bootstrap_cache_php_count() { find "${1}/bootstrap/cache" -maxdepth 1 -name '*.php' 2>/dev/null | wc -l | tr -d ' '; }
_symfony_cache_php_count()   { find "${1}/var/cache/prod" -maxdepth 1 -name '*.php' 2>/dev/null | wc -l | tr -d ' '; }

# ── Laravel + chroot_active=true -> bootstrap/cache/*.php TEMİZLENİR ──
rel="${WEB_ROOT}/laravel-chroot/releases/20260101_000001"
mkdir -p "$rel"; touch "${rel}/artisan"
assert_ok _deploy_build "laravel" "$rel" "web_x" "$FAKE_PHP" "true"
assert_eq "$(_bootstrap_cache_php_count "$rel")" "0" \
    "Laravel + chroot AKTİF: bootstrap/cache/*.php build sonunda silindi (open_basedir 500 fix'i)"

# ── Laravel + chroot_active=false -> KÖRLEMESİNE SİLİNMEZ (perf kazancı korunur) ──
rel2="${WEB_ROOT}/laravel-nochroot/releases/20260101_000001"
mkdir -p "$rel2"; touch "${rel2}/artisan"
assert_ok _deploy_build "laravel" "$rel2" "web_x" "$FAKE_PHP" "false"
assert_eq "$(_bootstrap_cache_php_count "$rel2")" "4" \
    "Laravel + chroot AKTİF DEĞİL: bootstrap/cache/*.php KORUNDU (config:cache gerçek perf kazancı, körlemesine kaldırılmadı)"

# ── Laravel + chroot_active parametresi HİÇ verilmezse (varsayılan) -> temizlenir ──
# (_deploy_build imzası '${5:-true}' — belirsizlikte GÜVENLİ tarafa, temizliğe düşer)
rel3="${WEB_ROOT}/laravel-default/releases/20260101_000001"
mkdir -p "$rel3"; touch "${rel3}/artisan"
assert_ok _deploy_build "laravel" "$rel3" "web_x" "$FAKE_PHP"
assert_eq "$(_bootstrap_cache_php_count "$rel3")" "0" \
    "chroot_active parametresi verilmezse varsayılan 'true' (güvenli taraf) uygulanır"

# ── Symfony + chroot_active=true -> var/cache/prod/*.php TEMİZLENİR (HİPOTEZ) ──
rel4="${WEB_ROOT}/symfony-chroot/releases/20260101_000001"
mkdir -p "${rel4}/bin"; touch "${rel4}/bin/console"; mkdir -p "${rel4}/public"
assert_ok _deploy_build "symfony" "$rel4" "web_x" "$FAKE_PHP" "true"
assert_eq "$(_symfony_cache_php_count "$rel4")" "0" \
    "Symfony + chroot AKTİF: var/cache/prod/*.php build sonunda silindi (HİPOTEZ, HOST'ta doğrulanmalı)"

# ── Symfony + chroot_active=false -> KORUNUR ──
rel5="${WEB_ROOT}/symfony-nochroot/releases/20260101_000001"
mkdir -p "${rel5}/bin"; touch "${rel5}/bin/console"; mkdir -p "${rel5}/public"
assert_ok _deploy_build "symfony" "$rel5" "web_x" "$FAKE_PHP" "false"
assert_eq "$(_symfony_cache_php_count "$rel5")" "1" \
    "Symfony + chroot AKTİF DEĞİL: var/cache/prod KORUNDU"

# ── CI4: chroot_active ne olursa olsun ETKİLENMEMELİ (gerçek deploy'da HTTP
#    200, open_basedir hatası sıfır — bu sınıf bug CI4'te YOK, bkz. rapor) ──
rel6="${WEB_ROOT}/ci4-chroot/releases/20260101_000001"
mkdir -p "$rel6"; touch "${rel6}/spark"
assert_ok _deploy_build "ci4" "$rel6" "web_x" "$FAKE_PHP" "true"
# CI4'te bootstrap/cache kavramı yok; sadece build'in hatasız tamamlandığını
# ve hiçbir yeni dizin/dosya üretmediğini doğrula (gereksiz temizlik yapılmadı).
assert_eq "$(find "$rel6" -mindepth 1 | wc -l | tr -d ' ')" "1" \
    "CI4: build sonrası release'de yalnız 'spark' var — chroot cleanup mantığı CI4'e SIZMADI"

# ── Savunma-derinliği: release_dir BOŞ/YOK ise 'rm -rf --
#    "${release_dir}/var/cache/prod/"*' gibi bir satır '/var/cache/prod/*'
#    (HOST'un GERÇEK kök dizini) haline SIZMAMALI — build tamamen reddedilir. ──
assert_fail _deploy_build "symfony" "" "web_x" "$FAKE_PHP" "true"
assert_fail _deploy_build "symfony" "${WEB_ROOT}/hic-var-olmayan-release" "web_x" "$FAKE_PHP" "true"

# ── Statik kaynak-kod kapısı: cleanup satırları KAZARA silinirse bu test
#    dosyası GEÇMEMELİ diye YUKARIDAKİ davranışsal testler yeterli, ama
#    ayrıca cleanup'ın chroot_active KOŞULUNA bağlı olduğunu da statik
#    doğrula (bir sonraki ajan "koşulu kaldırıp hep temizleyeyim" derse
#    yukarıdaki 'chroot_active=false' testleri zaten yakalar; burası
#    yalnız CI4 dalına cleanup EKLENMEDİĞİNİ garanti eder). ──
# _deploy_build fonksiyonunun TAMAMIYLA sınırlı gövdesi (başka fonksiyonlardaki
# 'laravel)'/'ci4)' etiketlerine — ör. _deploy_run'daki shared_pairs case'i —
# YANLIŞLIKLA sızmaması için '^_deploy_build() {' ... ilk sütun-0 '}' arası.
func_body=$(awk '/^_deploy_build\(\) \{/{flag=1} flag{print; if ($0 == "}") exit}' "${REPO_ROOT}/lib/deploy.sh")
laravel_block=$(awk '/laravel\)/{flag=1} flag{print} /ci4\)/{exit}' <<< "$func_body")
assert_contains "$laravel_block" 'chroot_active' "Laravel dalı chroot_active kontrolü içeriyor"
ci4_block=$(awk '/ci4\)/{flag=1} flag{print} /symfony\)/{exit}' <<< "$func_body")
assert_not_contains "$ci4_block" 'chroot_active' "CI4 dalına chroot cleanup mantığı EKLENMEDİ (gereksiz temizlik yok)"

rm -rf "$WEB_ROOT" "$(dirname "$FAKE_PHP")"
test_summary
