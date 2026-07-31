#!/bin/bash
# shared/.env koruması + mükerrer-anahtar teşhisi + APP_ENV/APP_DEBUG
# gerçek-ortam zorlaması — regresyon testi.
#
# GERÇEK VM BUG'I (koordinatör raporu, symfony/demo + PHP 8.4, tam
# commit'lenmiş repo, Ubuntu 22.04):
#     [4/9] Composer install ...
#     Script cache:clear returned with error code 255
#     !! Uncaught Error: Class "Symfony\Bundle\DebugBundle\DebugBundle" not found
#     ✗ Composer install başarısız — deploy durduruldu
# Kök neden: release/.env shared/.env'e SYMLINK'ti; composer/symfony-flex'in
# "henüz uygulanmamış" sandığı bir recipe .env'e YAZINCA bu yazı SYMLINK
# ÜZERİNDEN doğrudan KALICI shared/.env'e SIZDI:
#     ###> symfony/framework-bundle ###
#     APP_ENV=dev
#     APP_SECRET=
#     ###< symfony/framework-bundle ###
# Dotenv dosya İÇİNDE SON tanımın KAZANDIĞI kurala göre çalıştığından,
# ÜRETİMDE GEÇERLİ olan değerler 'APP_ENV=dev' ve BOŞ 'APP_SECRET' oldu —
# KALICI (shared/ deploy'lar arası yaşar), hiçbir uyarı ÜRETİLMEDEN.
# APP_ENV=dev üretimde profiler/web-debug-toolbar'ı ve tam stack trace'leri
# açığa çıkarır; boş APP_SECRET CSRF/imzalı-URI/oturum çerezi anahtarının
# BOŞ olması demektir.
#
# DÜZELTME — ÜÇ katman:
#   1) Composer/artisan/console GERÇEK ortam değişkeni olarak APP_ENV=prod
#      (Symfony) / APP_ENV=production (Laravel) + APP_DEBUG zorlanır —
#      Dotenv ZATEN VAR olan bir gerçek env'i EZMEZ, .env'in içeriği NE
#      OLURSA OLSUN doğru ortamda çalışılır (bkz. _deploy_build_env_overrides).
#   2) release/.env artık shared/.env'e SYMLINK DEĞİL, KOPYADIR — release
#      içinden yapılan yazılar (composer/flex/npm) yalnız disposable kopyayı
#      etkiler, KALICI shared/.env HİÇBİR ZAMAN açılıp yazılmaz (bkz.
#      _deploy_env_link).
#   3) shared/.env'de (ÖNCEDEN bozulmuş olabilir) MÜKERRER anahtar varsa
#      operatöre AÇIKÇA bildirilir — güvenlik-kritik anahtarlar (APP_ENV/
#      APP_DEBUG/APP_SECRET/...) ESKALE edilir, SIR değerler (APP_SECRET vb.)
#      log'a YAZILMAZ, otomatik SİLME yapılmaz (bkz. _deploy_env_duplicate_keys/
#      _deploy_env_check_duplicates).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_build_env_overrides >/dev/null 2>&1 \
    || ! declare -F _deploy_env_duplicate_keys >/dev/null 2>&1 \
    || ! declare -F _deploy_env_link >/dev/null 2>&1; then
    echo "  SKIP: .env koruması fonksiyonları henüz yok"
    test_summary
    rm -rf "$WEB_ROOT"
    exit 0
fi

_run_isolated() { ( "$@" ); }

# ══════════════ _deploy_build_env_overrides ══════════════
echo "  --- _deploy_build_env_overrides: framework'e göre GERÇEK env çifti ---"
out_symfony=$(_deploy_build_env_overrides "symfony")
assert_contains "$out_symfony" "APP_ENV=prod" "symfony -> APP_ENV=prod"
assert_contains "$out_symfony" "APP_DEBUG=0" "symfony -> APP_DEBUG=0"
out_laravel=$(_deploy_build_env_overrides "laravel")
assert_contains "$out_laravel" "APP_ENV=production" "laravel -> APP_ENV=production"
assert_contains "$out_laravel" "APP_DEBUG=false" "laravel -> APP_DEBUG=false"
out_ci4=$(_deploy_build_env_overrides "ci4")
assert_eq "$out_ci4" "" "ci4'e KASITLI olarak dokunulmadı (flex-benzeri bir .env-yazan recipe sistemi YOK)"
out_none=$(_deploy_build_env_overrides "")
assert_eq "$out_none" "" "framework boşsa/bilinmiyorsa hiçbir override üretilmez"

# ══════════════ _deploy_composer_install: composer GERÇEKTEN APP_ENV/APP_DEBUG ile çağrılıyor ══════════════
echo "  --- _deploy_composer_install: composer çağrısı APP_ENV=prod/APP_DEBUG=0 gerçek env içeriyor ---"

_deploy_privdrop() { local _u="$1"; shift; "$@"; }

ENVWORK="$(mktemp -d)"
PROBE="${ENVWORK}/probe.log"

# Sahte php_bin: composer_bin'i argüman olarak alır, KENDİ ortamındaki
# APP_ENV/APP_DEBUG'ı PROBE'a kaydeder (gerçek composer'ın flex hook'unun
# İÇİNDE bulacağı ortamın AYNISI — env değişkenleri fork edilen SÜREÇLERE
# miras kalır).
FAKE_PHP_BIN="$(mktemp -d)/fake-php"
cat > "$FAKE_PHP_BIN" <<EOF
#!/bin/bash
composer_bin="\$1"; shift
{
    printf 'APP_ENV=%s\n' "\${APP_ENV:-YOK}"
    printf 'APP_DEBUG=%s\n' "\${APP_DEBUG:-YOK}"
} >> "${PROBE}"
wd=""
for a in "\$@"; do
    case "\$a" in --working-dir=*) wd="\${a#--working-dir=}";; esac
done
# BUG A'nın (bkz. test_deploy_composer_php.sh) vendor-paket kontrolünü bu
# testte YANLIŞLIKLA tetiklememek için (bu test yalnız ENV AKTARIMINI
# doğruluyor, BUG A ayrı dosyada zaten test ediliyor) HER framework'ün
# beklediği paketi de üretir.
mkdir -p "\${wd}/vendor/symfony/framework-bundle" "\${wd}/vendor/laravel/framework" "\${wd}/vendor/codeigniter4/framework"
printf '<?php\n' > "\${wd}/vendor/autoload.php"
exit 0
EOF
chmod +x "$FAKE_PHP_BIN"

FAKE_COMPOSER_PHAR="$(mktemp -d)/fake-composer-phar"
printf '#!/usr/bin/env php\n<?php\n' > "$FAKE_COMPOSER_PHAR"
chmod +x "$FAKE_COMPOSER_PHAR"

_composer_target="$FAKE_COMPOSER_PHAR"
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "composer" ]]; then
        if [[ -n "$_composer_target" ]]; then echo "$_composer_target"; return 0; else return 1; fi
    fi
    builtin command "$@"
}

# ── symfony: composer APP_ENV=prod / APP_DEBUG=0 GERÇEK ortamla çağrılıyor ──
relS="${WEB_ROOT}/symf/releases/20260101_000001"
mkdir -p "$relS"
cat > "${relS}/composer.json" <<'EOF'
{"require": {"php": ">=8.1"}}
EOF
composer_homeS="${WEB_ROOT}/symf/tmp/composer"
rm -f "$PROBE"
_deploy_composer_install "$relS" "web_x" "$FAKE_PHP_BIN" "8.3" "symf.example.com" "$composer_homeS" "symfony" >/dev/null 2>&1
assert_contains "$(cat "$PROBE")" "APP_ENV=prod" \
    "symfony: composer çağrısı GERÇEK ortamda APP_ENV=prod içeriyor (kök nedenin doğrudan düzeltmesi)"
assert_contains "$(cat "$PROBE")" "APP_DEBUG=0" \
    "symfony: composer çağrısı GERÇEK ortamda APP_DEBUG=0 içeriyor"

# ── laravel: composer APP_ENV=production / APP_DEBUG=false ile çağrılıyor ──
relL="${WEB_ROOT}/lara/releases/20260101_000001"
mkdir -p "$relL"
cat > "${relL}/composer.json" <<'EOF'
{"require": {"php": ">=8.1"}}
EOF
composer_homeL="${WEB_ROOT}/lara/tmp/composer"
rm -f "$PROBE"
_deploy_composer_install "$relL" "web_x" "$FAKE_PHP_BIN" "8.3" "lara.example.com" "$composer_homeL" "laravel" >/dev/null 2>&1
assert_contains "$(cat "$PROBE")" "APP_ENV=production" \
    "laravel: composer çağrısı GERÇEK ortamda APP_ENV=production içeriyor"
assert_contains "$(cat "$PROBE")" "APP_DEBUG=false" \
    "laravel: composer çağrısı GERÇEK ortamda APP_DEBUG=false içeriyor"

# ── ci4/boş framework: hiçbir APP_ENV/APP_DEBUG zorlaması YOK (gereksiz davranış eklenmedi) ──
relC="${WEB_ROOT}/ci4x/releases/20260101_000001"
mkdir -p "$relC"
cat > "${relC}/composer.json" <<'EOF'
{"require": {"php": ">=8.1"}}
EOF
composer_homeC="${WEB_ROOT}/ci4x/tmp/composer"
rm -f "$PROBE"
_deploy_composer_install "$relC" "web_x" "$FAKE_PHP_BIN" "8.3" "ci4x.example.com" "$composer_homeC" "ci4" >/dev/null 2>&1
assert_contains "$(cat "$PROBE")" "APP_ENV=YOK" \
    "ci4: composer çağrısına APP_ENV zorlanmadı (CI4'te flex-benzeri bir bug sınıfı YOK)"

unset -f command

# ══════════════ _deploy_build: artisan/console çağrıları da AYNI zorlamayı alıyor ══════════════
echo "  --- _deploy_build: artisan/console çağrıları da GERÇEK APP_ENV/APP_DEBUG ile çalışıyor ---"

FAKE_PHP_BUILD="$(mktemp -d)/fake-php-build"
cat > "$FAKE_PHP_BUILD" <<EOF
#!/bin/bash
{
    printf 'BUILD_APP_ENV=%s\n' "\${APP_ENV:-YOK}"
    printf 'BUILD_APP_DEBUG=%s\n' "\${APP_DEBUG:-YOK}"
} >> "${PROBE}"
exit 0
EOF
chmod +x "$FAKE_PHP_BUILD"

relSym="${WEB_ROOT}/symbuild/releases/20260101_000001"
mkdir -p "${relSym}/bin"; touch "${relSym}/bin/console"; mkdir -p "${relSym}/public"
rm -f "$PROBE"
_deploy_build "symfony" "$relSym" "web_x" "$FAKE_PHP_BUILD" "false" "false" >/dev/null 2>&1
assert_contains "$(cat "$PROBE")" "BUILD_APP_ENV=prod" \
    "symfony build (cache:clear/warmup/assets:install): GERÇEK APP_ENV=prod ile çalıştı"

relLar="${WEB_ROOT}/larbuild/releases/20260101_000001"
mkdir -p "$relLar"; touch "${relLar}/artisan"
rm -f "$PROBE"
_deploy_build "laravel" "$relLar" "web_x" "$FAKE_PHP_BUILD" "false" "false" >/dev/null 2>&1
assert_contains "$(cat "$PROBE")" "BUILD_APP_ENV=production" \
    "laravel build (artisan config:cache vb.): GERÇEK APP_ENV=production ile çalıştı"

rm -rf "$ENVWORK" "$(dirname "$FAKE_PHP_BIN")" "$(dirname "$FAKE_COMPOSER_PHAR")" "$(dirname "$FAKE_PHP_BUILD")"

# ══════════════ _deploy_env_duplicate_keys / _deploy_env_key_is_* ══════════════
echo "  --- _deploy_env_duplicate_keys: shared/.env'de MÜKERRER anahtar tespiti ---"

d="$(mktemp -d)"
cat > "${d}/clean.env" <<'EOF'
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=efa9e73311468dfef9afde68654b3b2b
DATABASE_URL="mysql://user:pass@127.0.0.1:3306/db"
EOF
assert_eq "$(_deploy_env_duplicate_keys "${d}/clean.env")" "" \
    "mükerrer anahtar YOKSA boş döner"

# VM'de BİREBİR gözlemlenen bozulma: flex bloğu APP_ENV/APP_SECRET'ı TEKRAR ekliyor.
cat > "${d}/corrupted.env" <<'EOF'
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=efa9e73311468dfef9afde68654b3b2b
DB_PASSWORD=super_gizli_parola

###> symfony/framework-bundle ###
APP_ENV=dev
APP_SECRET=
APP_SHARE_DIR=var/share
###< symfony/framework-bundle ###
EOF
dup_out=$(_deploy_env_duplicate_keys "${d}/corrupted.env")
assert_contains "$dup_out" "APP_ENV:1,7" "APP_ENV mükerrerliği DOĞRU satır numaralarıyla tespit edildi (1 ve 7)"
assert_contains "$dup_out" "APP_SECRET:3,8" "APP_SECRET mükerrerliği DOĞRU satır numaralarıyla tespit edildi (3 ve 8)"
assert_not_contains "$dup_out" "APP_DEBUG:" "mükerrer OLMAYAN anahtar (APP_DEBUG, tek geçiyor) listede YOK"
assert_not_contains "$dup_out" "DB_PASSWORD:" "mükerrer OLMAYAN DB_PASSWORD listede YOK"

echo "  --- _deploy_env_key_is_critical / _deploy_env_key_is_secret ---"
assert_ok   _deploy_env_key_is_critical "APP_ENV"
assert_ok   _deploy_env_key_is_critical "APP_DEBUG"
assert_ok   _deploy_env_key_is_critical "APP_SECRET"
assert_fail _deploy_env_key_is_critical "SOME_RANDOM_KEY"
assert_ok   _deploy_env_key_is_secret "APP_SECRET"
assert_ok   _deploy_env_key_is_secret "DB_PASSWORD"
assert_ok   _deploy_env_key_is_secret "JWT_SECRET_KEY"
assert_fail _deploy_env_key_is_secret "APP_ENV"
assert_fail _deploy_env_key_is_secret "APP_DEBUG"

echo "  --- _deploy_env_check_duplicates: operatöre AÇIKÇA bildirim, SIR değer maskeleme ---"
out_dup=$(_deploy_env_check_duplicates "${d}/corrupted.env" 2>&1)
assert_contains "$out_dup" "GÜVENLİK-KRİTİK" "MÜKERRER güvenlik-kritik anahtarlar [GÜVENLİK-KRİTİK] etiketiyle ESKALE ediliyor"
assert_contains "$out_dup" "APP_ENV=dev" \
    "APP_ENV mükerrerliğinde GEÇERLİ (son/kazanan) değer AÇIKÇA gösteriliyor (secret değil, teşhis için gerekli)"
assert_not_contains "$out_dup" "efa9e73311468dfef9afde68654b3b2b" \
    "APP_SECRET'ın (SIR) hiçbir değeri (ne eski ne yeni) log çıktısına YAZILMIYOR"
assert_contains "$out_dup" "gizli değer" "APP_SECRET için değer yerine 'gizli değer' maskesi gösteriliyor"
assert_contains "$out_dup" "OTOMATİK SİLME YAPMAZ" "operatöre otomatik silme YAPILMADIĞI AÇIKÇA söyleniyor"

out_clean=$(_deploy_env_check_duplicates "${d}/clean.env" 2>&1)
assert_eq "$out_clean" "" "mükerrer anahtar yoksa HİÇBİR uyarı üretilmez (gürültü yok)"

rm -rf "$d"

# ══════════════ _deploy_env_link: KOPYA korur, flex'in yazması KALICI dosyayı ETKİLEMEZ ══════════════
echo "  --- _deploy_env_link: KRİTİK — flex'in release/.env'e yazması shared/.env'i DEĞİŞTİRMEZ ---"

base="${WEB_ROOT}/protect.example.com"
shared_dir="${base}/shared"
release_dir="${base}/releases/20260101_000001"
mkdir -p "$shared_dir" "$release_dir"
cat > "${shared_dir}/.env" <<'EOF'
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=gercek_uretim_sirri_123
EOF
shared_before=$(cat "${shared_dir}/.env")

assert_ok _deploy_env_link "$shared_dir" "$release_dir"
assert_eq "$([[ -L "${release_dir}/.env" ]] && echo symlink || echo dosya)" "dosya" \
    "release/.env artık SYMLINK DEĞİL — düz bir dosya (kopya)"
assert_eq "$(cat "${release_dir}/.env")" "$shared_before" \
    "release/.env kopyalandığı anda shared/.env ile AYNI içeriğe sahip"

# GERÇEK VM BUG'INI SİMÜLE ET: composer/symfony-flex release İÇİNDEKİ .env'e
# (kendi disposable kopyasına) bir recipe bloğu YAZAR — TAM OLARAK
# koordinatörün gözlemlediği bozulma.
cat >> "${release_dir}/.env" <<'EOF'

###> symfony/framework-bundle ###
APP_ENV=dev
APP_SECRET=
###< symfony/framework-bundle ###
EOF

assert_eq "$(cat "${shared_dir}/.env")" "$shared_before" \
    "[KRİTİK] release/.env'e (flex simülasyonu) YAZILDIKTAN SONRA shared/.env HİÇ DEĞİŞMEDİ — KALICI dosya korunuyor"
assert_not_contains "$(cat "${shared_dir}/.env")" "APP_ENV=dev" \
    "[KRİTİK] shared/.env'de flex'in eklediği 'APP_ENV=dev' bloğu YOK (sızma engellendi)"

# ── shared/.env symlink ise (saldırı senaryosu) reddedilir, kopyalanmaz ──
base2="${WEB_ROOT}/evilenv.example.com"
shared_dir2="${base2}/shared"
release_dir2="${base2}/releases/20260101_000001"
mkdir -p "$shared_dir2" "$release_dir2"
ln -s /etc/passwd "${shared_dir2}/.env"
assert_fail _deploy_env_link "$shared_dir2" "$release_dir2"
assert_eq "$([[ -e "${release_dir2}/.env" || -L "${release_dir2}/.env" ]] && echo var || echo yok)" "yok" \
    "shared/.env bir symlink'se release/.env HİÇ oluşturulmaz (güvenlik reddi)"

# ── shared/.env hiç yoksa 2 döner, hata değil ──
base3="${WEB_ROOT}/noenv.example.com"
shared_dir3="${base3}/shared"
release_dir3="${base3}/releases/20260101_000001"
mkdir -p "$shared_dir3" "$release_dir3"
rc=0
_deploy_env_link "$shared_dir3" "$release_dir3" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "shared/.env yoksa 2 döner (atlanır, hata sayılmaz)"

rm -rf "$WEB_ROOT"
test_summary
