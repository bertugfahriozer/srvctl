#!/bin/bash
# Composer'ın domain'in PHP sürümüyle çalıştırılması — regresyon testi.
#
# GERÇEK VM BUG'I (koordinatör raporu, Ubuntu 22.04, Laravel 13.x): host'ta
# hem php8.3 hem php8.4 kuruluyken, composer.json 'require.php: >=8.4.1'
# isteyen bir Laravel 13.x, PHP 8.3'teki bir domaine deploy edildi.
#   - '[4/9] Composer install' adımı BAŞARIYLA geçti ('✓ Composer paketleri
#     yüklendi') çünkü composer ÇIPLAK 'composer' adıyla çağrıldığından
#     kendi shebang'ı ('#!/usr/bin/env php') üzerinden HOST'un PATH'indeki
#     VARSAYILAN php8.4'ü seçti ve platform kontrolünü YANLIŞLIKLA geçti.
#   - İKİ ADIM SONRA '[6/9] Framework build' adımında 'artisan config:cache'
#     domain'in GERÇEK php8.3'üyle çalıştı ve şu hatayla patladı:
#     "Composer detected issues in your platform: ... PHP version '>= 8.4.1'
#     ... You are running 8.3.33."
#   - Operatörün gördüğü hata ('✗ artisan config:cache başarısız') gerçek
#     nedenden (composer'ın YANLIŞ PHP'yle koştuğu) iki adım geride ve
#     YANILTICIYDI.
#
# DÜZELTME (lib/deploy.sh): composer artık HER ZAMAN domain'in PHP CLI'ıyla
# (${php_bin}) çağrılıyor, VE composer.json'daki 'require.php' kısıtı
# composer'dan ÖNCE, erken ve net bir Türkçe mesajla kontrol ediliyor. Bu
# dosya üç şeyi kilitler: (a) composer domain'in php_bin'iyle çağrılıyor —
# hem VM'de doğrulanan çıplak-phar yolunda hem de tanınmayan bir sarmalayıcı
# olsa dahi PATH-shim düşüş yoluyla, (b) uyumsuz 'require.php' deploy'u
# composer'dan ÖNCE durduruyor, (c) uyumlu/kısıt-yok/belirsiz durumlarda
# akış normal ilerliyor (belirsizlikte GÖRÜNÜR bir uyarıyla, sessiz
# fail-open OLMADAN).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_php_satisfies >/dev/null 2>&1 \
    || ! declare -F _deploy_composer_php_constraint >/dev/null 2>&1 \
    || ! declare -F _deploy_composer_is_php_script >/dev/null 2>&1 \
    || ! declare -F _deploy_composer_install >/dev/null 2>&1; then
    echo "  SKIP: composer PHP sürüm uyumluluğu fonksiyonları henüz yok"
    test_summary
    rm -rf "$WEB_ROOT"
    exit 0
fi

# error() ile exit eden çağrıları güvenle yapmak için subshell'de çalıştır.
_run_isolated() { ( "$@" ); }

# ══════════════════════ _deploy_php_satisfies ══════════════════════
echo "  --- _deploy_php_satisfies: composer.json 'require.php' kısıtı ↔ domain PHP sürümü ---"

# GERÇEK VM BUG SENARYOSU: Laravel 13.x >=8.4.1 ister, domain 8.3'te.
assert_fail _deploy_php_satisfies "8.3" ">=8.4.1"
assert_ok   _deploy_php_satisfies "8.4" ">=8.4.1"
assert_ok   _deploy_php_satisfies "8.5" ">=8.4.1"

# caret (^): aynı major, >= minor
assert_fail _deploy_php_satisfies "8.1" "^8.2"
assert_ok   _deploy_php_satisfies "8.2" "^8.2"
assert_ok   _deploy_php_satisfies "8.3" "^8.2"
assert_fail _deploy_php_satisfies "9.0" "^8.2"

# AND (boşlukla ayrılmış): ">=8.1 <9.0"
assert_ok   _deploy_php_satisfies "8.3" ">=8.1 <9.0"
assert_ok   _deploy_php_satisfies "8.1" ">=8.1 <9.0"
assert_fail _deploy_php_satisfies "9.0" ">=8.1 <9.0"
assert_fail _deploy_php_satisfies "7.4" ">=8.1 <9.0"

# wildcard: '8.2.*'
assert_ok   _deploy_php_satisfies "8.2" "8.2.*"
assert_fail _deploy_php_satisfies "8.3" "8.2.*"

# OR ('||'): en az bir grup KESİN uyumluysa uyumlu
assert_ok   _deploy_php_satisfies "9.0" "^8.1 || ^9.0"
assert_fail _deploy_php_satisfies "7.4" "^8.1 || ^9.0"

# kısıt yok / '*' -> her zaman uyumlu
assert_ok   _deploy_php_satisfies "7.4" "*"
assert_ok   _deploy_php_satisfies "8.3" ""

# çıplak sürüm (operatörsüz) -> tam eşleşme
assert_ok   _deploy_php_satisfies "8.3" "8.3"
assert_fail _deploy_php_satisfies "8.3" "8.2"

# BELİRSİZLİK: hyphen-range gibi tam desteklenmeyen bir biçim KESİN uyumsuz
# (1) SAYILMAMALI — 2 (belirsiz) dönmeli; çağıran bunu warn+devam olarak ele
# alır (fail-open DEĞİL, ama yanlış-pozitifle sağlam bir deploy'u da
# BLOKE ETMEZ).
rc=0; _deploy_php_satisfies "8.3" "5.6 - 7.0" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "hyphen-range gibi tanınmayan biçim BELİRSİZ (2) sayılır — KESİN uyumsuz (1) DEĞİL"

# ══════════════════ _deploy_composer_php_constraint ══════════════════
echo "  --- _deploy_composer_php_constraint: composer.json'dan require.php okuma (jq VE awk düşüş yolu) ---"

d="$(mktemp -d)"
cat > "${d}/composer.json" <<'EOF'
{
    "name": "acme/app",
    "require": {
        "php": ">=8.4.1",
        "laravel/framework": "^13.0"
    },
    "require-dev": {
        "phpunit/phpunit": "^10.0"
    }
}
EOF
cat > "${d}/composer-nophp.json" <<'EOF'
{
    "require": {
        "laravel/framework": "^13.0"
    }
}
EOF
cat > "${d}/composer-norequire.json" <<'EOF'
{
    "name": "acme/app"
}
EOF

# Mevcut ortamda (jq varsa jq, yoksa awk düşüş yolu) doğru okunmalı.
assert_eq "$(_deploy_composer_php_constraint "${d}/composer.json")" ">=8.4.1" \
    "require.php doğru okunuyor (mevcut ortam: $(command -v jq >/dev/null 2>&1 && echo jq || echo awk-düşüş-yolu))"
assert_eq "$(_deploy_composer_php_constraint "${d}/composer-nophp.json")" "" \
    "'require' var ama 'php' anahtarı yok -> boş (kısıt yok sayılır)"
assert_eq "$(_deploy_composer_php_constraint "${d}/composer-norequire.json")" "" \
    "'require' bloğu hiç yok -> boş"
assert_eq "$(_deploy_composer_php_constraint "${d}/yok-boyle-dosya.json")" "" \
    "composer.json yoksa boş döner (hata değil)"

# jq YOKMUŞ gibi ZORLA (awk düşüş yolunu ortamdan BAĞIMSIZ kesin test et).
_orig_command=$(declare -f command 2>/dev/null || true)
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then return 1; fi
    builtin command "$@"
}
assert_eq "$(_deploy_composer_php_constraint "${d}/composer.json")" ">=8.4.1" \
    "jq YOKKEN awk düşüş yolu da require.php'yi doğru okuyor"
assert_eq "$(_deploy_composer_php_constraint "${d}/composer-nophp.json")" "" \
    "jq YOKKEN de: 'php' anahtarı yoksa awk düşüş yolu boş döner"
unset -f command
[[ -n "$_orig_command" ]] && eval "$_orig_command"

rm -rf "$d"

# ══════════════════ _deploy_composer_is_php_script ══════════════════
echo "  --- _deploy_composer_is_php_script: composer ikilisi PHP betiği/phar mı? ---"

d2="$(mktemp -d)"
# VM'de DOĞRULANAN gerçek composer biçimi: '#!/usr/bin/env php' + phar.
printf '#!/usr/bin/env php\n<?php // fake phar stub\n' > "${d2}/phar-with-shebang"
chmod +x "${d2}/phar-with-shebang"
assert_ok _deploy_composer_is_php_script "${d2}/phar-with-shebang"

printf '<?php\necho 1;\n' > "${d2}/plain-php-no-shebang"
assert_ok _deploy_composer_is_php_script "${d2}/plain-php-no-shebang"

printf '#!/bin/bash\necho hi\n' > "${d2}/shell-wrapper"
chmod +x "${d2}/shell-wrapper"
assert_fail _deploy_composer_is_php_script "${d2}/shell-wrapper"

assert_fail _deploy_composer_is_php_script "${d2}/yok-boyle-dosya"

rm -rf "$d2"

# ══════════════════════ _deploy_composer_install ══════════════════════
echo "  --- _deploy_composer_install: uçtan uca (sahte composer + sahte php_bin, privdrop stub'lı) ---"

# runuser gerektirmeden test edebilmek için privdrop'u komple stub'la (bkz.
# tests/test_deploy_chroot_cache_cleanup.sh — AYNI desen; bu testin amacı
# yetki düşürme DEĞİL, PHP sürüm seçimi mantığı).
_deploy_privdrop() { local _u="$1"; shift; "$@"; }

D4WORK="$(mktemp -d)"
PROBE="${D4WORK}/probe.log"

# Sahte php_bin: 'composer' phar'ını argüman olarak alır (gerçek
# '"$php_bin" "$composer_bin" install ...' çağrı biçimini simüle eder),
# çağrıldığını PROBE'a kaydeder ve --working-dir'de vendor/autoload.php
# üretir (gerçek composer'ın minyatür simülasyonu).
FAKE_PHP_BIN="$(mktemp -d)/fake-php"
cat > "$FAKE_PHP_BIN" <<EOF
#!/bin/bash
composer_bin="\$1"; shift
{
    printf 'php_bin_called_with:%s\n' "\$composer_bin"
    printf 'args:%s\n' "\$*"
} >> "${PROBE}"
wd=""
for a in "\$@"; do
    case "\$a" in --working-dir=*) wd="\${a#--working-dir=}";; esac
done
mkdir -p "\${wd}/vendor"
printf '<?php\n' > "\${wd}/vendor/autoload.php"
exit 0
EOF
chmod +x "$FAKE_PHP_BIN"

FAKE_PHP_BIN_FAIL="$(mktemp -d)/fake-php-fail"
cat > "$FAKE_PHP_BIN_FAIL" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAKE_PHP_BIN_FAIL"

# VM'de doğrulanan biçim: composer çıplak bir PHP betiği/phar.
FAKE_COMPOSER_PHAR="$(mktemp -d)/fake-composer-phar"
printf '#!/usr/bin/env php\n<?php // fake composer phar (icerik FAKE_PHP_BIN tarafindan kullanilmiyor)\n' > "$FAKE_COMPOSER_PHAR"
chmod +x "$FAKE_COMPOSER_PHAR"

# NADİR yol: composer php-script olarak TANINMAYAN bir sarmalayıcı (kendi
# içinde PATH'ten 'php' arıyor — shim düşüş yolunu tetiklemeli).
FAKE_COMPOSER_WRAPPER="$(mktemp -d)/fake-composer-wrapper"
cat > "$FAKE_COMPOSER_WRAPPER" <<EOF
#!/bin/bash
php_resolved="\$(command -v php)"
# Sembolik bağlantının HEDEFİNİ ŞİMDİ (sarmalayıcı hâlâ çalışırken) kaydet —
# _deploy_composer_install çağrı BİTİNCE shim dizinini TEMİZLER (bkz.
# 'sızıntı yok' testi); PROBE'a yalnız PATH'ten bulunan yolu yazarsak test
# bu satırı fonksiyon DÖNDÜKTEN SONRA okuyacağından symlink çoktan silinmiş
# olur ve 'readlink' YOK döner — bu yüzden hedef BURADA çözülür.
php_target="\$(readlink "\$php_resolved" 2>/dev/null || echo NOLINK)"
{
    printf 'wrapper_used_php:%s\n' "\$php_resolved"
    printf 'wrapper_used_php_target:%s\n' "\$php_target"
    printf 'args:%s\n' "\$*"
} >> "${PROBE}"
wd=""
for a in "\$@"; do
    case "\$a" in --working-dir=*) wd="\${a#--working-dir=}";; esac
done
mkdir -p "\${wd}/vendor"
printf '<?php\n' > "\${wd}/vendor/autoload.php"
exit 0
EOF
chmod +x "$FAKE_COMPOSER_WRAPPER"

# 'command -v composer' çağrısını sahte bir hedefe (ya da "bulunamadı"ya)
# yönlendiren tek bir override — PATH'e/host'un gerçek composer'ına
# (varsa) BAĞIMLI olmadan deterministik test.
_composer_target=""
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "composer" ]]; then
        if [[ -n "$_composer_target" ]]; then echo "$_composer_target"; return 0; else return 1; fi
    fi
    builtin command "$@"
}

# ── D1: KESİN uyumsuz PHP kısıtı -> composer'a HİÇ ULAŞILMAZ ──
_composer_target="$FAKE_COMPOSER_PHAR"
rel1="${WEB_ROOT}/incompat/releases/20260101_000001"
mkdir -p "$rel1"
cat > "${rel1}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.4.1"
    }
}
EOF
composer_home1="${WEB_ROOT}/incompat/tmp/composer"
rm -f "$PROBE"
out1=$(_run_isolated _deploy_composer_install "$rel1" "web_x" "$FAKE_PHP_BIN" "8.3" "incompat.example.com" "$composer_home1" 2>&1)
rc1=$?
assert_eq "$([[ "$rc1" != "0" ]] && echo durdu || echo devam)" "durdu" \
    "PHP kısıtı KESİN uyumsuzsa (>=8.4.1 vs 8.3) deploy composer'dan ÖNCE durur"
assert_contains "$out1" "srvctl domain php-switch" \
    "hata mesajı operatöre somut bir düzeltme komutu öneriyor"
assert_eq "$([[ -f "$PROBE" ]] && echo VAR || echo YOK)" "YOK" \
    "composer'a HİÇ ULAŞILMADI (php_bin/composer_bin hiç çağrılmadı)"
assert_eq "$([[ -f "${rel1}/vendor/autoload.php" ]] && echo VAR || echo YOK)" "YOK" \
    "vendor/autoload.php üretilmedi"

# ── D2: uyumlu kısıt + tanınan php-script/phar -> php_bin ÜZERİNDEN çalışır ──
_composer_target="$FAKE_COMPOSER_PHAR"
rel2="${WEB_ROOT}/compat/releases/20260101_000001"
mkdir -p "$rel2"
cat > "${rel2}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_home2="${WEB_ROOT}/compat/tmp/composer"
rm -f "$PROBE"
out2=$(_run_isolated _deploy_composer_install "$rel2" "web_x" "$FAKE_PHP_BIN" "8.3" "compat.example.com" "$composer_home2" 2>&1)
rc2=$?
assert_eq "$rc2" "0" "uyumlu PHP kısıtında composer normal çalışır"
assert_not_contains "$out2" "PATH shim ile zorlanıyor" \
    "tanınan bir PHP betiği/phar için GEREKSİZ shim düşüş yolu uyarısı basılmadı"
assert_eq "$([[ -f "${rel2}/vendor/autoload.php" ]] && echo VAR || echo YOK)" "VAR" \
    "composer çalıştı (vendor/autoload.php üretildi)"
assert_eq "$(grep -c '^php_bin_called_with:' "$PROBE" 2>/dev/null || echo 0)" "1" \
    "composer TAM OLARAK BİR KEZ, php_bin ÜZERİNDEN çağrıldı"
assert_contains "$(cat "$PROBE")" "php_bin_called_with:${FAKE_COMPOSER_PHAR}" \
    "composer_bin AÇIKÇA php_bin'e argüman olarak geçirildi (host'un PATH'teki varsayılan php'sine BIRAKILMADI — kök nedenin düzeltmesi)"

# ── D3: require.php hiç yok -> composer normal çalışır, gereksiz uyarı yok ──
_composer_target="$FAKE_COMPOSER_PHAR"
rel3="${WEB_ROOT}/norequirement/releases/20260101_000001"
mkdir -p "$rel3"
cat > "${rel3}/composer.json" <<'EOF'
{
    "require": {
        "laravel/framework": "^13.0"
    }
}
EOF
composer_home3="${WEB_ROOT}/norequirement/tmp/composer"
rm -f "$PROBE"
out3=$(_run_isolated _deploy_composer_install "$rel3" "web_x" "$FAKE_PHP_BIN" "8.3" "norequirement.example.com" "$composer_home3" 2>&1)
rc3=$?
assert_eq "$rc3" "0" "require.php YOKSA (başka paket var) deploy hatasız devam eder"
assert_eq "$([[ -f "${rel3}/vendor/autoload.php" ]] && echo VAR || echo YOK)" "VAR" "composer yine çalıştı"
assert_not_contains "$out3" "doğrulanamadı" "kısıt hiç yoksa 'doğrulanamadı' uyarısı GEREKSİZ basılmaz"

# ── D4: BELİRSİZ kısıt (hyphen-range) -> BLOKE ETMEZ, ama GÖRÜNÜR uyarı bırakır ──
_composer_target="$FAKE_COMPOSER_PHAR"
rel4="${WEB_ROOT}/ambiguous/releases/20260101_000001"
mkdir -p "$rel4"
cat > "${rel4}/composer.json" <<'EOF'
{
    "require": {
        "php": "5.6 - 7.0"
    }
}
EOF
composer_home4="${WEB_ROOT}/ambiguous/tmp/composer"
rm -f "$PROBE"
out4=$(_run_isolated _deploy_composer_install "$rel4" "web_x" "$FAKE_PHP_BIN" "8.3" "ambiguous.example.com" "$composer_home4" 2>&1)
rc4=$?
assert_eq "$rc4" "0" "belirsiz kısıtta deploy BLOKE EDİLMEZ (composer normal çalışır)"
assert_contains "$out4" "doğrulanamadı" "belirsiz kısıtta GÖRÜNÜR bir uyarı bırakılır (sessiz fail-open DEĞİL)"
assert_eq "$([[ -f "${rel4}/vendor/autoload.php" ]] && echo VAR || echo YOK)" "VAR" "composer yine çalıştı (bloklanmadı)"

# ── D5: composer TANINMAYAN bir sarmalayıcı -> PATH-shim düşüş yolu ──
_composer_target="$FAKE_COMPOSER_WRAPPER"
rel5="${WEB_ROOT}/wrapper/releases/20260101_000001"
mkdir -p "$rel5"
cat > "${rel5}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_home5="${WEB_ROOT}/wrapper/tmp/composer"
rm -f "$PROBE"
out5=$(_run_isolated _deploy_composer_install "$rel5" "web_x" "$FAKE_PHP_BIN" "8.3" "wrapper.example.com" "$composer_home5" 2>&1)
rc5=$?
assert_eq "$rc5" "0" "composer php-script olarak TANINMAYAN bir sarmalayıcıysa da deploy shim ile devam eder"
assert_contains "$out5" "PATH shim ile zorlanıyor" "tanınmayan sarmalayıcıda operatöre görünür bir uyarı bırakılır"
assert_eq "$([[ -f "${rel5}/vendor/autoload.php" ]] && echo VAR || echo YOK)" "VAR" "shim yoluyla da composer başarıyla çalıştı"
php_target_line=$(grep '^wrapper_used_php_target:' "$PROBE" 2>/dev/null || true)
assert_eq "${php_target_line#wrapper_used_php_target:}" "$FAKE_PHP_BIN" \
    "sarmalayıcı İÇİNDE 'php' PATH'ten arandığında domain'in php_bin'ine SYMLINK ediyor (shim doğru kuruldu)"
assert_eq "$(find "$composer_home5" -maxdepth 1 -name '.php-shim.*' 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "composer PHP-shim geçici dizini işlem sonunda TEMİZLENDİ (sızıntı yok)"

# ── D6: composer install BAŞARISIZ olursa deploy DURUR, net Türkçe mesaj ──
_composer_target="$FAKE_COMPOSER_PHAR"
rel6="${WEB_ROOT}/fails/releases/20260101_000001"
mkdir -p "$rel6"
cat > "${rel6}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_home6="${WEB_ROOT}/fails/tmp/composer"
out6=$(_run_isolated _deploy_composer_install "$rel6" "web_x" "$FAKE_PHP_BIN_FAIL" "8.3" "fails.example.com" "$composer_home6" 2>&1)
rc6=$?
assert_eq "$([[ "$rc6" != "0" ]] && echo durdu || echo devam)" "durdu" "composer install BAŞARISIZ olunca deploy DURUR"
assert_contains "$out6" "Composer install başarısız" "operatöre net Türkçe hata mesajı gösterilir"
assert_eq "$([[ -f "${rel6}/vendor/autoload.php" ]] && echo VAR || echo YOK)" "YOK" "başarısız composer'da vendor/autoload.php üretilmedi"

# ── D7: composer HİÇ kurulu değil -> net Türkçe hata, composer'a ulaşılmadan durur ──
_composer_target=""
rel7="${WEB_ROOT}/nocomposer/releases/20260101_000001"
mkdir -p "$rel7"
cat > "${rel7}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_home7="${WEB_ROOT}/nocomposer/tmp/composer"
out7=$(_run_isolated _deploy_composer_install "$rel7" "web_x" "$FAKE_PHP_BIN" "8.3" "nocomposer.example.com" "$composer_home7" 2>&1)
rc7=$?
assert_eq "$([[ "$rc7" != "0" ]] && echo durdu || echo devam)" "durdu" "composer kurulu değilse deploy DURUR"
assert_contains "$out7" "composer kurulu değil" "operatöre net mesaj: composer kurulu değil"

# ══════ BUG A: composer 'başarılı' görünüp gerçek bağımlılık ağacı çözülmemiş ══════
# GERÇEK VM BUG'I (koordinatör raporu, Symfony 7.3 skeleton, Ubuntu 22.04):
# composer ÖNCE yalnız symfony/flex'i kurup (rc=0) SONRA flex'in KENDİ İÇ
# 'composer update'i güvenlik-danışmanlığı (advisory) engeliyle çöküyor;
# flex zaten kurulduğundan 'vendor/autoload.php' VARDI ve eski guard bunu
# "başarılı" sayıyordu.
echo "  --- BUG A: 'vendor/autoload.php var' guard'ı YETERSİZ; iki bağımsız katman ---"

# Composer 'çıkış kodu 0' + autoload.php ÜRETİR ama STDOUT'UNDA composer'ın
# kendi "could not be resolved" imzasını basar (VM'de GÖZLEMLENEN BİREBİR
# metin) VE beklenen framework paketini KURMAZ.
FAKE_PHP_BIN_ADVISORY="$(mktemp -d)/fake-php-advisory"
cat > "$FAKE_PHP_BIN_ADVISORY" <<EOF
#!/bin/bash
composer_bin="\$1"; shift
wd=""
for a in "\$@"; do
    case "\$a" in --working-dir=*) wd="\${a#--working-dir=}";; esac
done
echo "Your requirements could not be resolved to an installable set of packages."
echo "  Problem 1"
echo "    - Root composer.json requires symfony/runtime 7.3.*, found symfony/runtime[...] but these were not loaded, because they are affected by security advisories (\"PKSA-xf5h-y6vg-qj98\")."
# BİLEREK beklenen framework paketini de (vendor/symfony/framework-bundle)
# üretir — bu senaryo YALNIZ advisory-metni doğrulama katmanını izole
# etmeli; vendor-paket kontrolü (2. katman) ile YANLIŞLIKLA KARIŞMAMALI
# (bkz. mutasyon testi notu: metin kontrolü tek başına devre dışı
# bırakıldığında bu test hâlâ vendor-paket kontrolü sayesinde YANLIŞLIKLA
# geçebiliyordu — düzeltildi).
mkdir -p "\${wd}/vendor/symfony/framework-bundle"
printf '<?php\n' > "\${wd}/vendor/autoload.php"
exit 0
EOF
chmod +x "$FAKE_PHP_BIN_ADVISORY"

# Composer 'çıkış kodu 0' + autoload.php ÜRETİR, advisory metni YOK, ama
# beklenen framework paketini (vendor/symfony/framework-bundle) KURMAZ —
# BUG A'nın advisory-METNİ OLMAYAN, daha sinsi bir varyantı (ör. farklı bir
# composer hatası/versiyon uyuşmazlığı).
FAKE_PHP_BIN_MISSING_PKG="$(mktemp -d)/fake-php-missing-pkg"
cat > "$FAKE_PHP_BIN_MISSING_PKG" <<EOF
#!/bin/bash
composer_bin="\$1"; shift
wd=""
for a in "\$@"; do
    case "\$a" in --working-dir=*) wd="\${a#--working-dir=}";; esac
done
mkdir -p "\${wd}/vendor"
printf '<?php\n' > "\${wd}/vendor/autoload.php"
exit 0
EOF
chmod +x "$FAKE_PHP_BIN_MISSING_PKG"

# GERÇEK bir başarılı kurulum: autoload.php VE beklenen framework paketi
# (vendor/symfony/framework-bundle) İKİSİ DE üretilir.
FAKE_PHP_BIN_REAL_SUCCESS="$(mktemp -d)/fake-php-real-success"
cat > "$FAKE_PHP_BIN_REAL_SUCCESS" <<EOF
#!/bin/bash
composer_bin="\$1"; shift
wd=""
for a in "\$@"; do
    case "\$a" in --working-dir=*) wd="\${a#--working-dir=}";; esac
done
mkdir -p "\${wd}/vendor/symfony/framework-bundle"
printf '<?php\n' > "\${wd}/vendor/autoload.php"
exit 0
EOF
chmod +x "$FAKE_PHP_BIN_REAL_SUCCESS"

_composer_target="$FAKE_COMPOSER_PHAR"

# ── A1: composer çıktısında 'could not be resolved' -> KOŞULSUZ hata ──
relA1="${WEB_ROOT}/advisory/releases/20260101_000001"
mkdir -p "$relA1"
cat > "${relA1}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_homeA1="${WEB_ROOT}/advisory/tmp/composer"
outA1=$(_run_isolated _deploy_composer_install "$relA1" "web_x" "$FAKE_PHP_BIN_ADVISORY" "8.3" "advisory.example.com" "$composer_homeA1" "symfony" 2>&1)
rcA1=$?
assert_eq "$([[ "$rcA1" != "0" ]] && echo durdu || echo devam)" "durdu" \
    "composer çıktısında 'could not be resolved' varsa deploy DURUR (exit=0 VE autoload.php VAR olsa bile)"
assert_contains "$outA1" "could not be resolved" "hata mesajı composer'ın kendi imzasını yansıtıyor"
assert_contains "$outA1" "advisor" "hata mesajı security-advisory politikasını AÇIKLIYOR (operatör ne olduğunu anlar)"

# ── A2: advisory metni YOK ama beklenen framework paketi eksik -> yine hata ──
relA2="${WEB_ROOT}/missingpkg/releases/20260101_000001"
mkdir -p "$relA2"
cat > "${relA2}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_homeA2="${WEB_ROOT}/missingpkg/tmp/composer"
outA2=$(_run_isolated _deploy_composer_install "$relA2" "web_x" "$FAKE_PHP_BIN_MISSING_PKG" "8.3" "missingpkg.example.com" "$composer_homeA2" "symfony" 2>&1)
rcA2=$?
assert_eq "$([[ "$rcA2" != "0" ]] && echo durdu || echo devam)" "durdu" \
    "advisory metni yoksa BİLE, beklenen framework paketi (vendor/symfony/framework-bundle) eksikse deploy DURUR"
assert_contains "$outA2" "vendor/symfony/framework-bundle" "hata mesajı HANGİ paketin eksik olduğunu somut olarak belirtiyor"

# ── A3: GERÇEK başarılı kurulum (autoload.php + beklenen paket) -> normal ilerler ──
relA3="${WEB_ROOT}/realsuccess/releases/20260101_000001"
mkdir -p "$relA3"
cat > "${relA3}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_homeA3="${WEB_ROOT}/realsuccess/tmp/composer"
outA3=$(_run_isolated _deploy_composer_install "$relA3" "web_x" "$FAKE_PHP_BIN_REAL_SUCCESS" "8.3" "realsuccess.example.com" "$composer_homeA3" "symfony" 2>&1)
rcA3=$?
assert_eq "$rcA3" "0" "autoload.php VE beklenen framework paketi İKİSİ DE varsa deploy normal ilerler"

# ── A4: framework BEYAN EDİLMEMİŞ (boş) -> paket kontrolü ATLANIR (fail-closed yerine güvenli varsayım) ──
relA4="${WEB_ROOT}/noframeworkdecl/releases/20260101_000001"
mkdir -p "$relA4"
cat > "${relA4}/composer.json" <<'EOF'
{
    "require": {
        "php": ">=8.1"
    }
}
EOF
composer_homeA4="${WEB_ROOT}/noframeworkdecl/tmp/composer"
outA4=$(_run_isolated _deploy_composer_install "$relA4" "web_x" "$FAKE_PHP_BIN_MISSING_PKG" "8.3" "noframeworkdecl.example.com" "$composer_homeA4" "" 2>&1)
rcA4=$?
assert_eq "$rcA4" "0" \
    "framework parametresi boş geçilirse (eski çağrı biçimi/bilinmeyen framework) vendor-paket kontrolü atlanır — YALNIZ autoload.php yeterli"

rm -rf "$(dirname "$FAKE_PHP_BIN_ADVISORY")" "$(dirname "$FAKE_PHP_BIN_MISSING_PKG")" "$(dirname "$FAKE_PHP_BIN_REAL_SUCCESS")"

unset -f command
rm -rf "$D4WORK" "$(dirname "$FAKE_PHP_BIN")" "$(dirname "$FAKE_PHP_BIN_FAIL")" \
       "$(dirname "$FAKE_COMPOSER_PHAR")" "$(dirname "$FAKE_COMPOSER_WRAPPER")"

# ══════ php_bin türetimi: HOST'un varsayılan PHP'sine SESSİZ düşüş YOK ══════
# _deploy_run içindeki php_bin türetimi (git clone gerektirdiğinden bu
# dosyada uçtan uca ÇAĞRILAMAZ) ESKİDEN php${php_version} bulunamazsa
# PATH'teki genel 'php'ye (ya da o da yoksa çıplak "php" adına) SESSİZCE
# düşüyordu — composer/artisan'ın GERÇEK VM bug'ıyla AYNI sınıf hatayla
# (host'un/PATH'in rastgele bir PHP sürümüyle çalışması) karşılaşmasına yol
# açabilirdi. Statik kaynak denetimiyle bu düşüşün KALDIRILDIĞINI VE net bir
# hatayla değiştirildiğini kilitle.
echo "  --- _deploy_run: php_bin artık HOST'un varsayılan php'sine sessizce düşmüyor (statik) ---"
run_src=$(cat "${REPO_ROOT}/lib/deploy.sh")
assert_not_contains "$run_src" '[[ -z "$php_bin" ]] && php_bin=$(command -v php 2>/dev/null)' \
    "php\${php_version} bulunamazsa artık PATH'teki genel 'php'ye SESSİZCE düşülmüyor"
assert_not_contains "$run_src" '[[ -z "$php_bin" ]] && php_bin="php"' \
    "php\${php_version} bulunamazsa artık çıplak \"php\" adına SESSİZCE düşülmüyor"
assert_contains "$run_src" 'Domain PHP sürümü için CLI ikili dosyası bulunamadı' \
    "domain'in PHP CLI'ı (php\${php_version}) yoksa net Türkçe hatayla durulur"

rm -rf "$WEB_ROOT"
test_summary
