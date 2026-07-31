#!/bin/bash
# MADDE 2 — mevcut bir domaine framework beyan etmenin CLI yolu yoktu.
#
# HOST'ta ÖLÇÜLEN KESİNTİ (Ubuntu 24.04, v1.0.0→v2.0.0 yükseltmesi): v1.0.0'da
# 'FRAMEWORK' anahtarı hiç yoktu; yükseltme sonrası HİÇBİR eski domain'in
# '.srvctl-meta'sında bu anahtar yoktu. '_domain_framework_declared' beyan
# yokken BOŞ döner ve '_domain_disable_functions_for ""' SIKI listeyi
# (putenv DAHİL) uygular — CodeIgniter 4'ün DotEnv sınıfı putenv() kullanır,
# alternatifi yoktur:
#   PHP Fatal error: Uncaught Error: Call to undefined function
#   CodeIgniter\Config\putenv() ... DotEnv.php:98
# Site geri gelsin diye '.srvctl-meta'ya ELLE 'FRAMEWORK=ci4' yazmak ZORUNDA
# kalındı — hiçbir 'domain' alt komutu bunu YAPMIYORDU. Bu test yeni
# 'srvctl domain framework <domain> <ci4|laravel|symfony|none>' komutunu
# kilitler.
#
# Bu test şunları kilitler:
#   1) Geçersiz değer REDDEDİLİYOR (error/exit, meta DEĞİŞMİYOR).
#   2) 'ci4' beyanı: '.srvctl-meta' güncelleniyor, GÜVENLİK ÖDÜNÜ (putenv
#      AÇIK) uyarısı BASILIYOR, disable_functions zincirinde putenv GERÇEKTEN
#      açılıyor (_domain_disable_functions_for üzerinden uçtan uca doğrulama).
#   3) 'laravel'/'symfony' beyanı: meta güncelleniyor, ci4'e ÖZGÜ putenv
#      uyarısı BASILMIYOR.
#   4) 'none': beyanı TEMİZLİYOR — '_domain_framework_declared' sonrasında
#      BOŞ döner (beyan yokmuş gibi geriye dönüyor, disable_functions SIKI
#      listeye dönüyor — putenv yeniden KAPALI).
#   5) [KRİTİK — regresyon assertion'ı]: HİÇ 'domain framework' çağrılmamış
#      taze bir domain'de (v1.0.0'dan yükseltilmiş domain'i simüle eder)
#      '_domain_framework_declared' BOŞ döner ve disable_functions listesinde
#      putenv KAPALI kalır (sıkı taraf varsayılan — fail-closed).
#   6) Her başarılı değişiklikten sonra operatöre 'domain repair' AÇIKÇA
#      önerilir (pool'un YENİDEN RENDER edilmesi gerektiği söylenir) — komut
#      repair'i SESSİZCE/otomatik ÇAĞIRMAZ (servis yeniden başlatma sürpriz
#      olmasın).
#
# Test-seam: WEB_ROOT / SRVCTL_STATE_DIR — diğer domain.sh testleriyle AYNI desen.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_framework >/dev/null 2>&1; then
    echo "  SKIP: _domain_framework tanımlı değil"
    test_summary
    exit $?
fi

_run_isolated() { ( "$@" ); }

echo "== srvctl domain framework <domain> <deger> =="

dom="framework-cmd.test"
mkdir -p "${WEB_ROOT}/${dom}"

# ─── 1) Olmayan domain → error (exit) ───
assert_fail _run_isolated _domain_framework "yok-boyle-domain.test" ci4

# ─── 2) Eksik argüman → error (exit) ───
assert_fail _run_isolated _domain_framework "$dom"
assert_fail _run_isolated _domain_framework

# ─── 3) Geçersiz değer → REDDEDİLİYOR, meta DEĞİŞMİYOR ───
_domain_framework "$dom" ci4 >/dev/null 2>&1
before_meta=$(cat "${WEB_ROOT}/${dom}/.srvctl-meta" 2>/dev/null)
assert_fail _run_isolated _domain_framework "$dom" wordpress
after_meta=$(cat "${WEB_ROOT}/${dom}/.srvctl-meta" 2>/dev/null)
assert_eq "$after_meta" "$before_meta" \
    "[KRİTİK] geçersiz değer REDDEDİLDİĞİNDE '.srvctl-meta' DEĞİŞMEDİ"

echo ""
echo "== 'ci4' beyanı: GÜVENLİK ÖDÜNÜ uyarısı + putenv fiilen AÇILIYOR =="

dCi4="ci4-declare.test"
mkdir -p "${WEB_ROOT}/${dCi4}"
outCi4=$(_domain_framework "$dCi4" ci4 2>&1)

assert_contains "$outCi4" "GÜVENLİK ÖDÜNÜ" "'ci4' beyanında GÜVENLİK ÖDÜNÜ uyarısı BASILIYOR"
assert_contains "$outCi4" "putenv" "uyarı 'putenv'e AÇIKÇA atıfta bulunuyor"
assert_contains "$outCi4" "domain repair" \
    "operatöre AÇIKÇA 'domain repair' ÖNERİLİYOR (pool yeniden render edilmeli)"

declared_ci4=$(_domain_framework_declared "$dCi4" 2>/dev/null)
assert_eq "$declared_ci4" "ci4" "'_domain_framework_declared' artık 'ci4' döndürüyor"

# Uçtan uca: disable_functions zincirinde putenv GERÇEKTEN açık mı?
dfCi4=$(_domain_disable_functions_for "$declared_ci4")
assert_not_contains "$dfCi4" "putenv" \
    "[KRİTİK] 'ci4' beyanı disable_functions listesinden putenv'i GERÇEKTEN ÇIKARIYOR (uçtan uca)"

echo ""
echo "== 'laravel'/'symfony' beyanı: ci4'e ÖZGÜ uyarı BASILMIYOR ==="

dLaravel="laravel-declare.test"
mkdir -p "${WEB_ROOT}/${dLaravel}"
outLaravel=$(_domain_framework "$dLaravel" laravel 2>&1)
assert_not_contains "$outLaravel" "GÜVENLİK ÖDÜNÜ" \
    "'laravel' beyanında ci4'e özgü GÜVENLİK ÖDÜNÜ uyarısı BASILMIYOR"
declared_laravel=$(_domain_framework_declared "$dLaravel" 2>/dev/null)
assert_eq "$declared_laravel" "laravel" "'_domain_framework_declared' 'laravel' döndürüyor"
dfLaravel=$(_domain_disable_functions_for "$declared_laravel")
assert_contains "$dfLaravel" "putenv" \
    "'laravel' beyanında putenv disable_functions listesinde KALIYOR (sıkı liste)"

dSymfony="symfony-declare.test"
mkdir -p "${WEB_ROOT}/${dSymfony}"
outSymfony=$(_domain_framework "$dSymfony" symfony 2>&1)
assert_not_contains "$outSymfony" "GÜVENLİK ÖDÜNÜ" \
    "'symfony' beyanında da ci4'e özgü uyarı BASILMIYOR"
declared_symfony=$(_domain_framework_declared "$dSymfony" 2>/dev/null)
assert_eq "$declared_symfony" "symfony" "'_domain_framework_declared' 'symfony' döndürüyor"

echo ""
echo "== 'none': beyan TEMİZLENİYOR — sıkı listeye (putenv KAPALI) dönülüyor =="

# Önce ci4 beyan et (putenv AÇIK), sonra 'none' ile temizle.
_domain_framework "$dCi4" ci4 >/dev/null 2>&1
outNone=$(_domain_framework "$dCi4" none 2>&1)
assert_contains "$outNone" "TEMİZLENDİ" "'none' beyanı temizleme mesajı BASIYOR"

declared_after_none=$(_domain_framework_declared "$dCi4" 2>/dev/null)
assert_eq "$declared_after_none" "" \
    "[KRİTİK] 'none' sonrası '_domain_framework_declared' BOŞ döner (beyan yokmuş gibi)"
dfNone=$(_domain_disable_functions_for "$declared_after_none")
assert_contains "$dfNone" "putenv" \
    "[KRİTİK] 'none' sonrası putenv disable_functions listesine GERİ DÖNÜYOR (sıkı taraf)"

# _domain_read_framework (fs iskeleti için ayrı okuyucu) 'none' sonrası HÂLÂ
# 'ci4' varsayılanına düşer (dizin şeması amaçlı fallback — güvenlik kararını
# ETKİLEMEZ, bkz. _domain_framework_declared başlık yorumu).
read_after_none=$(_domain_read_framework "$dCi4" 2>/dev/null)
assert_eq "$read_after_none" "ci4" \
    "_domain_read_framework 'none' sonrası fs-iskeleti amaçlı 'ci4' fallback'ine düşer (beyan ile KARIŞTIRILMAMALI)"

echo ""
echo "== [KRİTİK REGRESYON] hiç 'domain framework' çağrılmamış taze domain: putenv KAPALI kalır =="

# v1.0.0'dan yükseltilmiş bir domain'i simüle eder: '.srvctl-meta' hiç YOK.
dUpgraded="upgraded-legacy.test"
mkdir -p "${WEB_ROOT}/${dUpgraded}"

declared_upgraded=$(_domain_framework_declared "$dUpgraded" 2>/dev/null)
assert_eq "$declared_upgraded" "" \
    "[KRİTİK] beyan hiç yapılmamış domain'de '_domain_framework_declared' BOŞ döner"
dfUpgraded=$(_domain_disable_functions_for "$declared_upgraded")
assert_contains "$dfUpgraded" "putenv" \
    "[KRİTİK] beyan yokken putenv disable_functions listesinde KALIR (sıkı/fail-closed varsayılan — CI4 boot hatası YERİNE önce güvenlik)"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
