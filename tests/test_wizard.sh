#!/bin/bash
# _domain_wizard_collect: sihirbaz girdi toplama + iptal sözleşmesi.
#
# REGRESYON: _domain_wizard_collect'e framework sorusu eklendiğinde bu test
# sabit satır sayılı bir printf ile besleniyordu ("example.com\n\n\n\n\nevet\n").
# Yeni framework promptu araya girince 6. satır ("evet") artık framework
# promptuna gidiyor, ardından confirm() EOF alıp akışı iptal ediyordu — yani
# testin KENDİSİ satır-sırasına bağımlı olduğu için kırıldı, kod değil.
#
# Kırılganlığı azaltmak için girdi artık İSİM+YORUMLU bir bash dizisinden
# (satır = 1 prompt) inşa ediliyor: yeni bir prompt eklendiğinde hangi
# satırın nereye gittiği burada görünür olsun, sabit '\n' sayımı gerekmesin.
#
# _domain_wizard_collect prompt sırası (bkz. lib/domain.sh):
#   1) Domain adı                      2) PHP sürümü [DEFAULT_PHP_VERSION]
#   3) Rate-limit profili [standard]   4) SSL (evet/hayır) [evet]
#   5) Hassas yollar (boş=varsayılan)  6) Framework [ci4/laravel/symfony] (varsayılan: ci4)
#   7) confirm "devam edilsin mi?" (evet/hayır)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# ── Senaryo 1: tüm varsayılanlar + confirm=evet ──
default_flow=(
    "example.com"   # 1) domain
    ""              # 2) php            -> boş = DEFAULT_PHP_VERSION
    ""              # 3) rate profili   -> boş = standard
    ""              # 4) ssl            -> boş = evet
    ""              # 5) hassas yollar  -> boş = DEFAULT_SENSITIVE_PATHS
    ""              # 6) framework      -> boş = ci4
    "evet"          # 7) confirm        -> devam
)
# Process substitution (< <(...)) kullanılır: redirect subshell YARATMAZ, böylece
# WIZ_* global'leri mevcut shell'de kalır ve assert edilebilir. (Pipe `|` subshell
# yaratır — kullanma.)
_domain_wizard_collect < <(printf '%s\n' "${default_flow[@]}") >/dev/null 2>&1
rc_default=$?
assert_eq "$rc_default"    "0"                            "varsayılan akış rc=0"
assert_eq "$WIZ_DOMAIN"    "example.com"                  "wizard domain"
assert_eq "$WIZ_PHP"       "${DEFAULT_PHP_VERSION}"       "wizard php varsayılan"
assert_eq "$WIZ_PROFILE"   "standard"                     "wizard profil varsayılan"
assert_eq "$WIZ_SSL"       "evet"                         "wizard ssl varsayılan"
assert_eq "$WIZ_SENSITIVE" "${DEFAULT_SENSITIVE_PATHS}"   "wizard hassas varsayılan"
assert_eq "$WIZ_FRAMEWORK" "ci4"                           "wizard framework varsayılan (ci4)"

# ── Senaryo 2: özel değerler (framework AÇIKÇA 'laravel') + iptal (confirm=hayır -> return 1) ──
cancel_flow=(
    "site.com"   # 1) domain
    "8.2"        # 2) php
    "strict"     # 3) rate profili
    "hayir"      # 4) ssl (serbest metin, doğrulanmaz)
    "admin|x"    # 5) hassas yollar
    "laravel"    # 6) framework -> AÇIKÇA verilen değer (varsayılan DEĞİL)
    "hayır"      # 7) confirm -> iptal
)
_domain_wizard_collect < <(printf '%s\n' "${cancel_flow[@]}") >/dev/null 2>&1
rc_cancel=$?
assert_eq "$rc_cancel"     "1"          "iptal -> rc=1"
assert_eq "$WIZ_DOMAIN"    "site.com"   "iptal öncesi domain set edilmiş"
assert_eq "$WIZ_PROFILE"   "strict"     "iptal öncesi profil set edilmiş"
assert_eq "$WIZ_FRAMEWORK" "laravel"    "iptal öncesi AÇIKÇA verilen framework WIZ_FRAMEWORK'e yazılmış"

# ── Senaryo 3: geçersiz framework girilirse döngü tekrar sorar (reprompt) ──
invalid_fw_flow=(
    "bad-fw.example.com"  # 1) domain
    ""                    # 2) php
    ""                    # 3) rate profili
    ""                    # 4) ssl
    ""                    # 5) hassas yollar
    "wordpress"           # 6a) framework -> GEÇERSİZ, döngü tekrar sormalı
    "symfony"             # 6b) framework -> bu kez geçerli
    "hayır"               # 7) confirm -> iptal (yalnız reprompt'u doğrulamak yeterli)
)
_domain_wizard_collect < <(printf '%s\n' "${invalid_fw_flow[@]}") >/dev/null 2>&1
rc_invalid=$?
assert_eq "$rc_invalid"    "1"        "geçersiz framework denemesi sonrası iptal ile biten akış rc=1"
assert_eq "$WIZ_FRAMEWORK" "symfony"  "geçersiz framework reddedilip tekrar soruldu, geçerli değer kabul edildi"

rm -rf "$WEB_ROOT"
test_summary
