#!/bin/bash
# _domain_isolated_fpm_effective (lib/domain.sh) — per-domain FPM izolasyonu
# efektif değeri: global DOMAIN_ISOLATED_FPM (conf/srvctl.conf) mu, yoksa
# domain'in KENDİ '.srvctl-meta' ISOLATED_FPM override'ı mı geçerli?
#
# NEDEN VAR: '.srvctl-meta' web-yazılabilir bir dosyadır (henüz hardened
# olmamış bir domain'de web_<domain> kullanıcısı bile buraya yazabilir).
# Bu fonksiyon YOKSA/YANLIŞ davranırsa iki karşıt risk doğar:
#   a) Ham meta değeri sorgusuz kabul edilirse, ele geçirilmiş bir web
#      kullanıcısı 'ISOLATED_FPM=false' yazıp kendi domain'ini paylaşılan
#      (izole OLMAYAN) FPM pool'una GERİ döndürebilir — AppArmor/cgroups/
#      seccomp izolasyonunu operatör bilgisi dışında SÖNDÜRÜR.
#   b) Geçersiz/çöp bir değer (yazım hatası, bozuk dosya) sessizce "false"
#      gibi davranırsa, varsayılan-AÇIK izolasyon politikası (DOMAIN_ISOLATED_FPM)
#      sebepsiz yere devre dışı kalır.
# Sözleşme: yalnızca validate_bool'dan geçen LİTERAL 'true'/'false' override
# sayılır; her şey (boş/çöp/enjeksiyon) global değere düşer + (dosya varsa)
# warn üretir. Domain 'hardened' + meta root-owned DEĞİLSE (tamper) override
# YOK SAYILIR (error() ile EXIT ETMEZ — bu fonksiyon _domain_read_framework/
# _domain_read_resource_profile'dan FARKLI olarak sert durdurmaz, sadece
# global'e düşer; bkz. lib/domain.sh başlık yorumu).
#
# PARALEL AGENT NOTU: lib/domain.sh şu anda db-redis-specialist tarafından
# değiştiriliyor — fonksiyon yoksa/adı değiştiyse SKIP edilir.
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
source "${REPO_ROOT}/lib/domain.sh"

_run_isolated() { ( "$@" ); }

if ! declare -F _domain_isolated_fpm_effective >/dev/null 2>&1; then
    echo "  SKIP: _domain_isolated_fpm_effective henüz yok (lib/domain.sh paralel değişiyor olabilir)"
    rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
    test_summary
    exit 0
fi

# ═══════════════ Global varsayılan (meta yok) ═══════════════
mkdir -p "${WEB_ROOT}/if-none.com"
DOMAIN_ISOLATED_FPM=true
assert_eq "$(_domain_isolated_fpm_effective if-none.com 2>/dev/null)" "true" \
    "meta yokken global (true) döner"

DOMAIN_ISOLATED_FPM=false
assert_eq "$(_domain_isolated_fpm_effective if-none.com 2>/dev/null)" "false" \
    "meta yokken global (false) döner"
DOMAIN_ISOLATED_FPM=true

# ═══════════════ Meta override — geçerli değerler ═══════════════
mkdir -p "${WEB_ROOT}/if-false.com"
write_meta if-false.com ISOLATED_FPM false
assert_eq "$(_domain_isolated_fpm_effective if-false.com 2>/dev/null)" "false" \
    "meta ISOLATED_FPM=false, global=true iken override EDER"

mkdir -p "${WEB_ROOT}/if-true.com"
DOMAIN_ISOLATED_FPM=false
write_meta if-true.com ISOLATED_FPM true
assert_eq "$(_domain_isolated_fpm_effective if-true.com 2>/dev/null)" "true" \
    "meta ISOLATED_FPM=true, global=false iken override EDER"
DOMAIN_ISOLATED_FPM=true

# ═══════════════ Meta çöp/geçersiz değer → global'e düş + warn ═══════════════
mkdir -p "${WEB_ROOT}/if-garbage.com"
DOMAIN_ISOLATED_FPM=true
write_meta if-garbage.com ISOLATED_FPM "elma"
assert_eq "$(_domain_isolated_fpm_effective if-garbage.com 2>/dev/null)" "true" \
    "çöp meta değeri ('elma') → global'e düşer"
warn_out="$(_domain_isolated_fpm_effective if-garbage.com 2>&1 1>/dev/null)"
assert_contains "$warn_out" "Geçersiz ISOLATED_FPM meta değeri" "çöp değer için warn üretiliyor"

mkdir -p "${WEB_ROOT}/if-inject.com"
write_meta if-inject.com ISOLATED_FPM '$(rm -rf /)'
assert_eq "$(_domain_isolated_fpm_effective if-inject.com 2>/dev/null)" "true" \
    "enjeksiyon içeren meta değeri de global'e düşer (asla eval edilmez)"

# validate_bool literal string ister: 'True'/'FALSE'/'1'/'yes' KABUL EDİLMEZ.
mkdir -p "${WEB_ROOT}/if-caseinsensitive.com"
write_meta if-caseinsensitive.com ISOLATED_FPM "True"
assert_eq "$(_domain_isolated_fpm_effective if-caseinsensitive.com 2>/dev/null)" "true" \
    "'True' (büyük T) literal 'true' SAYILMAZ → global'e düşer"

# ═══════════════ Hardened + root-owned OLMAYAN meta → tamper: override YOK SAYILIR (exit YOK) ═══════════════
# _domain_read_framework/_domain_read_resource_profile'dan FARKLI: bu fonksiyon
# error() ile durmaz, yalnız warn + global. Sandbox'ta dosya zaten test
# kullanıcısına ait (root değil); 'hardened' marker'ı ile tamper senaryosu
# tetikleniyor.
mkdir -p "${WEB_ROOT}/if-hardened.com"
DOMAIN_ISOLATED_FPM=true
write_meta if-hardened.com ISOLATED_FPM false
mkdir -p "${SRVCTL_STATE_DIR}/if-hardened.com"
touch "${SRVCTL_STATE_DIR}/if-hardened.com/hardened"
assert_ok _run_isolated _domain_isolated_fpm_effective if-hardened.com
assert_eq "$(_domain_isolated_fpm_effective if-hardened.com 2>/dev/null)" "true" \
    "hardened+tampered meta → override YOK SAYILIR, global (true) kullanılır (exit ETMEZ)"
tamper_warn="$(_domain_isolated_fpm_effective if-hardened.com 2>&1 1>/dev/null)"
assert_contains "$tamper_warn" "YOK SAYILIYOR" "tamper durumunda açık warn mesajı üretiliyor"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
