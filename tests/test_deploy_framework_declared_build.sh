#!/bin/bash
# BUG B regresyon testi — AÇIKÇA beyan edilmiş bir framework'ün build'i
# sessizce atlanmamalı.
#
# GERÇEK VM BUG'I (koordinatör raporu, Symfony 7.3 skeleton deploy'u,
# Ubuntu 22.04): domain 'srvctl domain add --framework=symfony' ile AÇIKÇA
# kurulmuştu. '[6/9] Framework build (symfony)' adımında:
#     ℹ  bin/console bulunamadı — Symfony build adımları atlanıyor
# basılıp deploy'a İNFO ile devam ediliyordu. Ama framework AÇIKÇA beyan
# edilmiş bir domainde entry dosyasının (bin/console/artisan/spark) YOKLUĞU
# normal bir durum DEĞİL — kırık bir composer/build zincirinin kanıtıdır
# (bu VM'de kök neden BUG A'ydı: symfony/flex'in KENDİ İÇ 'composer update'i
# çökmüştü, bkz. tests/test_deploy_composer_php.sh). 'info' ile sessizce
# atlanması deploy'un "başarılı" görünmesine (health probe 200/302 dönerse)
# izin veriyordu.
#
# DÜZELTME: _deploy_build artık '_deploy_framework_declared' predikatını
# kullanıp YALNIZ AÇIKÇA beyan edilmiş bir framework'ün entry dosyası
# eksikse error() ile durur; framework BEYAN EDİLMEMİŞSE (varsayılan/ci4'e
# düşülmüşse) ESKİ yumuşak davranış (info+atla) KORUNUR — çünkü o durumda
# bunun kırık bir framework mü yoksa framework KULLANMAYAN sıradan bir PHP
# uygulaması mı olduğu BİLİNEMEZ (bkz. dosya-geneli disiplin: bir kontrolü
# SIKILAŞTIRMAK AÇIK BEYAN ister; "beyan yok/okunamadı" HER ZAMAN yumuşak
# tarafa düşer — lib/domain.sh'ın '_domain_framework_declared' kontratıyla
# AYNI mantık).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Test-seam'ler (bkz. CLAUDE.md "Test-seams for macOS dev"): SRVCTL_STATE_DIR
# '${SRVCTL_STATE_DIR:-...}' ile env'den override edilebilir (core.sh) — bu
# sayede '_domain_is_hardened' (lib/domain.sh) test domain'lerimizi HİÇBİR
# ZAMAN "hardened" bulmaz, '_require_owned_or_warn' sahiplik denetimini
# atlar (warn+devam) ve macOS'ta root OLMADAN .srvctl-meta okunabilir.
export SRVCTL_STATE_DIR="$(mktemp -d)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_framework_declared >/dev/null 2>&1 || ! declare -F _deploy_build >/dev/null 2>&1; then
    echo "  SKIP: _deploy_framework_declared / _deploy_build henüz yok"
    test_summary
    rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
    exit 0
fi

# error() ile exit eden çağrıları güvenle yapmak için subshell'de çalıştır.
_run_isolated() { ( "$@" ); }

# ═══════════════════ _deploy_framework_declared ═══════════════════
echo "  --- _deploy_framework_declared: operatör AÇIKÇA beyan etmiş mi? ---"

# lib/domain.sh'ı GERÇEKTEN source edebilmek için SRVCTL_ROOT'u repo'ya
# yönlendiriyoruz. core.sh SRVCTL_ROOT'u SABİT '/usr/local/srvctl'e atar
# (bu, macOS dev makinesinde YOK — bkz. CLAUDE.md "repo ≠ kurulum");
# '_deploy_framework_declared' bu değişkeni ÇAĞRI ANINDA okur (deploy.sh
# source edilirken DEĞİL), bu yüzden sourcing'den SONRA değiştirmek güvenli
# ve deploy.sh'ın kendi davranışını ETKİLEMEZ.
SRVCTL_ROOT="$REPO_ROOT"

dom_declared="declared.example.com"
mkdir -p "${WEB_ROOT}/${dom_declared}"
printf 'FRAMEWORK=symfony\n' > "${WEB_ROOT}/${dom_declared}/.srvctl-meta"

dom_other="other.example.com"
mkdir -p "${WEB_ROOT}/${dom_other}"
printf 'FRAMEWORK=laravel\n' > "${WEB_ROOT}/${dom_other}/.srvctl-meta"

dom_none="none.example.com"
mkdir -p "${WEB_ROOT}/${dom_none}"
# .srvctl-meta hiç YOK -> beyan yok

dom_invalid="invalid.example.com"
mkdir -p "${WEB_ROOT}/${dom_invalid}"
printf 'FRAMEWORK=not-a-real-framework\n' > "${WEB_ROOT}/${dom_invalid}/.srvctl-meta"

assert_ok   _deploy_framework_declared "$dom_declared" "symfony"
assert_fail _deploy_framework_declared "$dom_declared" "laravel"
assert_ok   _deploy_framework_declared "$dom_other" "laravel"
assert_fail _deploy_framework_declared "$dom_none" "symfony"
assert_fail _deploy_framework_declared "$dom_invalid" "symfony"
assert_fail _deploy_framework_declared "yok-boyle-bir-domain" "symfony"

# ═══════════════ _deploy_build: BUG B hard-stop ═══════════════
echo "  --- _deploy_build: AÇIKÇA beyan edilmiş framework'ün entry dosyası eksikse HATA ---"

# runuser gerektirmeden test edebilmek için privdrop'u komple stub'la (bkz.
# tests/test_deploy_chroot_cache_cleanup.sh — AYNI desen).
_deploy_privdrop() { local _u="$1"; shift; "$@"; }
FAKE_PHP="$(mktemp -d)/fake-php.sh"
cat > "$FAKE_PHP" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_PHP"

WORK="$(mktemp -d)"

# ── beyan EDİLMİŞ (framework_declared=true) + entry dosyası YOK -> DURUR ──
rel1="${WORK}/symfony-declared-broken/releases/20260101_000001"
mkdir -p "$rel1"   # bin/console YOK
out1=$(_run_isolated _deploy_build "symfony" "$rel1" "web_x" "$FAKE_PHP" "true" "true" 2>&1)
rc1=$?
assert_eq "$([[ "$rc1" != "0" ]] && echo durdu || echo devam)" "durdu" \
    "framework AÇIKÇA 'symfony' beyan edilmiş ama bin/console YOKSA build DURUR"
assert_contains "$out1" "AÇIKÇA beyan edilmiş" "hata mesajı beyan durumunu açıklıyor"

# ── beyan EDİLMEMİŞ (framework_declared=false) + entry dosyası YOK -> ESKİ yumuşak davranış ──
rel2="${WORK}/symfony-notdeclared-broken/releases/20260101_000001"
mkdir -p "$rel2"
out2=$(_deploy_build "symfony" "$rel2" "web_x" "$FAKE_PHP" "true" "false" 2>&1)
rc2=$?
assert_eq "$rc2" "0" "framework beyan EDİLMEMİŞSE, entry dosyası yoksa build DURMAZ (eski davranış korunur)"
assert_contains "$out2" "bin/console bulunamadı" "eski bilgi mesajı hâlâ basılıyor"

# ── framework_declared parametresi HİÇ verilmezse (varsayılan 'false') -> eski davranış ──
rel3="${WORK}/symfony-default-broken/releases/20260101_000001"
mkdir -p "$rel3"
assert_ok _deploy_build "symfony" "$rel3" "web_x" "$FAKE_PHP" "true"

# ── beyan EDİLMİŞ + entry dosyası VARSA -> normal ilerler (build adımları çalışır) ──
rel4="${WORK}/symfony-declared-ok/releases/20260101_000001"
mkdir -p "${rel4}/bin"; touch "${rel4}/bin/console"; mkdir -p "${rel4}/public"
assert_ok _deploy_build "symfony" "$rel4" "web_x" "$FAKE_PHP" "true" "true"

# ── laravel / ci4 dallarında da AYNI disiplin (statik doğrulanan, tek tek) ──
rel5="${WORK}/laravel-declared-broken/releases/20260101_000001"
mkdir -p "$rel5"   # artisan YOK
out5=$(_run_isolated _deploy_build "laravel" "$rel5" "web_x" "$FAKE_PHP" "true" "true" 2>&1)
rc5=$?
assert_eq "$([[ "$rc5" != "0" ]] && echo durdu || echo devam)" "durdu" "laravel AÇIKÇA beyan + artisan YOK -> DURUR"

rel5b="${WORK}/laravel-notdeclared-broken/releases/20260101_000001"
mkdir -p "$rel5b"
assert_ok _deploy_build "laravel" "$rel5b" "web_x" "$FAKE_PHP" "true" "false"

rel6="${WORK}/ci4-declared-broken/releases/20260101_000001"
mkdir -p "$rel6"   # spark YOK
out6=$(_run_isolated _deploy_build "ci4" "$rel6" "web_x" "$FAKE_PHP" "true" "true" 2>&1)
rc6=$?
assert_eq "$([[ "$rc6" != "0" ]] && echo durdu || echo devam)" "durdu" "ci4 AÇIKÇA beyan + spark YOK -> DURUR"

rel6b="${WORK}/ci4-notdeclared-broken/releases/20260101_000001"
mkdir -p "$rel6b"
assert_ok _deploy_build "ci4" "$rel6b" "web_x" "$FAKE_PHP" "true" "false"

rm -rf "$WORK" "$(dirname "$FAKE_PHP")" "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
