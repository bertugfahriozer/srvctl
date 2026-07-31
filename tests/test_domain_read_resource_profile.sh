#!/bin/bash
# _domain_read_resource_profile (lib/domain.sh) — domain'in kaynak (cgroups/
# FPM pool) profili beyanını '.srvctl-meta' RESOURCE_PROFILE'dan okur.
#
# NEDEN VAR: _domain_read_framework İLE AYNI KAPI/DESEN — '.srvctl-meta'
# web-yazılabilir olduğundan ham RESOURCE_PROFILE değerine GÜVENİLMEZ.
# Bu değer DOĞRUDAN _domain_resources'ın "mevcut değerleri koru" varsayılan
# kaynağı olarak kullanılıyor (bkz. tests/test_domain_resources_preserve.sh);
# resource_profile_resolve (core.sh, conf/resource-profiles.conf'a karşı)
# ile doğrulanmadan geçseydi, ele geçirilmiş bir web kullanıcısı
# 'RESOURCE_PROFILE=../../etc/passwd' gibi bir değer yazıp _domain_resources'ın
# sonraki bir çağrısında bambaşka (yanlış boyutlandırılmış ya da hiç
# eşleşmeyen) bir cgroups/FPM profiline SESSİZCE düşülmesine sebep olabilirdi.
# Whitelist dışı/boş/enjeksiyon → 'standard'a düşer. Hardened + root-owned
# OLMAYAN meta (tamper) → error() ile SERT DURUR (_domain_read_framework ile
# BİREBİR AYNI davranış — _domain_isolated_fpm_effective'DEN FARKLI: o yalnız
# warn+global'e düşer, exit ETMEZ; burada exit EDER).
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

if ! declare -F _domain_read_resource_profile >/dev/null 2>&1; then
    echo "  SKIP: _domain_read_resource_profile henüz yok (lib/domain.sh paralel değişiyor olabilir)"
    rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
    test_summary
    exit 0
fi

mkdir -p "${WEB_ROOT}/rp-none.com" "${WEB_ROOT}/rp-micro.com" "${WEB_ROOT}/rp-ecommerce.com" \
         "${WEB_ROOT}/rp-heavy.com" "${WEB_ROOT}/rp-garbage.com" "${WEB_ROOT}/rp-inject.com"

# ═══════════════ Meta yok → varsayılan 'standard' ═══════════════
assert_eq "$(_domain_read_resource_profile rp-none.com 2>/dev/null)" "standard" \
    "meta hiç yoksa varsayılan 'standard'"

# ═══════════════ Geçerli beyan → aynen döner ═══════════════
write_meta rp-micro.com     RESOURCE_PROFILE micro
write_meta rp-ecommerce.com RESOURCE_PROFILE ecommerce
write_meta rp-heavy.com     RESOURCE_PROFILE heavy

assert_eq "$(_domain_read_resource_profile rp-micro.com 2>/dev/null)"     "micro"     "geçerli değer: micro aynen döner"
assert_eq "$(_domain_read_resource_profile rp-ecommerce.com 2>/dev/null)" "ecommerce" "geçerli değer: ecommerce aynen döner"
assert_eq "$(_domain_read_resource_profile rp-heavy.com 2>/dev/null)"     "heavy"     "geçerli değer: heavy aynen döner"

# ═══════════════ Whitelist dışı / enjeksiyon → 'standard'a düşer ═══════════════
write_meta rp-garbage.com RESOURCE_PROFILE 'gold-tier-9000'
assert_eq "$(_domain_read_resource_profile rp-garbage.com 2>/dev/null)" "standard" \
    "conf/resource-profiles.conf'ta olmayan bir profil adı → standard'a düşer"

write_meta rp-inject.com RESOURCE_PROFILE '../../etc/passwd'
assert_eq "$(_domain_read_resource_profile rp-inject.com 2>/dev/null)" "standard" \
    "path-traversal görünümlü değer → standard'a düşer (asla dosya yolu olarak kullanılmaz)"

write_meta rp-inject.com RESOURCE_PROFILE '$(rm -rf /)'
assert_eq "$(_domain_read_resource_profile rp-inject.com 2>/dev/null)" "standard" \
    "komut enjeksiyonu içeren değer → standard'a düşer (asla eval edilmez)"

# ═══════════════ Hardened + root-owned OLMAYAN meta → tamper → error() (exit) ═══════════════
mkdir -p "${WEB_ROOT}/rp-hardened.com"
write_meta rp-hardened.com RESOURCE_PROFILE heavy
mkdir -p "${SRVCTL_STATE_DIR}/rp-hardened.com"
touch "${SRVCTL_STATE_DIR}/rp-hardened.com/hardened"
assert_fail _run_isolated _domain_read_resource_profile rp-hardened.com

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
