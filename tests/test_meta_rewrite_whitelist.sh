#!/bin/bash
# _meta_validate_value / _meta_rewrite_whitelist (lib/security.sh) — O1'in
# TAM kapanışı: '.srvctl-meta' beyaz liste ile YENİDEN ÜRETİLİYOR mu?
#
# GEREKÇE (bkz. lib/security.sh başlık yorumu): read_kv_file artık satır
# başına sabit anchor kullanıyor ('^KEY=') ve assert_safe_ident kapısı var
# — ama bu yalnız OKUMAYI süzer. Dosyanın İÇERİĞİ hardened-öncesi bir
# domainde saldırgan tarafından kirletilebilir (ör. baştaki boşlukla
# ' FRAMEWORK=laravel' ya da '#FRAMEWORK=...') ve 'harden-fs --apply'
# dosyayı root:root 644 yapsa bile bu satır write_meta'nın anchor'lı
# 'grep -v "^KEY="'i ile ASLA silinemediği için KALICI olarak dosyada
# kalıyordu (artık okunmuyor ama ölü/kirli satır olarak duruyor).
# '_meta_rewrite_whitelist' dosyayı SIFIRDAN, yalnız bilinen anahtarların
# GEÇERLİ değerlerini yazarak yeniden üretir — bu test zehirlenme
# senaryolarının GERÇEKTEN temizlendiğini ve işlemin İDEMPOTENT olduğunu
# doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

# ═══════════════════════════════════════════════════════════════
# 1) _meta_validate_value — her bilinen anahtarın KENDİ doğrulayıcısı
# ═══════════════════════════════════════════════════════════════
assert_ok   _meta_validate_value RATE_PROFILE "standard"
assert_ok   _meta_validate_value RATE_PROFILE "strict"
assert_fail _meta_validate_value RATE_PROFILE "boyle_bir_profil_yok"

assert_ok   _meta_validate_value SENSITIVE_PATHS "login|admin|wp-login\\.php"
assert_fail _meta_validate_value SENSITIVE_PATHS "login; admin"     # noktalı virgül/boşluk — nginx enjeksiyon
assert_fail _meta_validate_value SENSITIVE_PATHS "a{b}c"            # süslü parantez

assert_ok   _meta_validate_value FRAMEWORK "ci4"
assert_ok   _meta_validate_value FRAMEWORK "laravel"
assert_ok   _meta_validate_value FRAMEWORK "symfony"
assert_fail _meta_validate_value FRAMEWORK "wordpress"

assert_ok   _meta_validate_value RUN_MIGRATIONS "true"
assert_ok   _meta_validate_value RUN_MIGRATIONS "false"
assert_fail _meta_validate_value RUN_MIGRATIONS "maybe"              # görevdeki tam örnek

assert_ok   _meta_validate_value KEEP_GIT "true"
assert_fail _meta_validate_value KEEP_GIT "1"                        # yalnız literal true/false (validate_bool)

assert_ok   _meta_validate_value REDIS_SCRIPTING "enabled"
assert_ok   _meta_validate_value REDIS_SCRIPTING "disabled"
assert_ok   _meta_validate_value REDIS_SCRIPTING "unknown"
assert_fail _meta_validate_value REDIS_SCRIPTING "yes"

# Bilinmeyen anahtar: değeri ne olursa olsun reddedilir (case default)
assert_fail _meta_validate_value COMPLETELY_UNKNOWN_KEY "anything"

# ═══════════════════════════════════════════════════════════════
# 2) _meta_rewrite_whitelist — zehirlenme senaryosu
# ═══════════════════════════════════════════════════════════════
mkdir -p "${WEB_ROOT}/example.com"
meta="${WEB_ROOT}/example.com/.srvctl-meta"
cat > "$meta" <<'EOF'
 FRAMEWORK=leading_space_poison
#FRAMEWORK=hash_poison
FRAMEWORK_UNKNOWN_SUFFIX=poison
UNKNOWN_KEY=poison
RUN_MIGRATIONS=maybe

RATE_PROFILE=standard
FRAMEWORK=laravel
SENSITIVE_PATHS=login|admin
this_line_has_no_equals_sign
EOF

result=$(_meta_rewrite_whitelist "$meta")
read -r kept dropped <<< "$result"

assert_eq "$kept" "3" "3 GEÇERLİ satır hayatta kaldı (RATE_PROFILE, FRAMEWORK, SENSITIVE_PATHS)"
assert_eq "$dropped" "6" "6 ZEHİRLİ/geçersiz/boş satır atıldı"

content="$(cat "$meta")"
assert_contains     "$content" "RATE_PROFILE=standard"    "geçerli RATE_PROFILE satırı KORUNDU"
assert_contains     "$content" "FRAMEWORK=laravel"        "geçerli FRAMEWORK satırı KORUNDU"
assert_contains     "$content" "SENSITIVE_PATHS=login|admin" "geçerli SENSITIVE_PATHS satırı KORUNDU"
assert_not_contains "$content" "leading_space_poison"     "baştaki boşluklu zehirli satır TEMİZLENDİ"
assert_not_contains "$content" "hash_poison"               "'#' önekli zehirli satır TEMİZLENDİ"
assert_not_contains "$content" "FRAMEWORK_UNKNOWN_SUFFIX"  "anahtar-önekli farklı anahtar TEMİZLENDİ"
assert_not_contains "$content" "UNKNOWN_KEY"                "bilinmeyen anahtar TEMİZLENDİ"
assert_not_contains "$content" "RUN_MIGRATIONS"             "geçersiz değerli (maybe) RUN_MIGRATIONS TEMİZLENDİ"
assert_not_contains "$content" "no_equals_sign"             "'=' içermeyen satır TEMİZLENDİ"
assert_eq "$(grep -c '^FRAMEWORK=' "$meta")" "1" "yeniden yazım sonrası duplicate FRAMEWORK yok"

# ── read_kv_file ile round-trip: temizlenmiş dosya hâlâ doğru okunuyor ──
unset RATE_PROFILE SENSITIVE_PATHS FRAMEWORK
read_meta example.com 2>/dev/null
FRAMEWORK=""; read_kv_file "$meta" FRAMEWORK
assert_eq "${RATE_PROFILE:-}"    "standard"     "temizlenmiş dosya read_meta ile doğru okunuyor (RATE_PROFILE)"
assert_eq "${SENSITIVE_PATHS:-}" "login|admin"  "temizlenmiş dosya read_meta ile doğru okunuyor (SENSITIVE_PATHS)"
assert_eq "${FRAMEWORK:-}"       "laravel"      "temizlenmiş dosya read_kv_file ile doğru okunuyor (FRAMEWORK)"

# ═══════════════════════════════════════════════════════════════
# 3) İDEMPOTENT mi? Zaten temiz bir dosya üzerinde İKİNCİ çalıştırma
#    hiçbir şeyi DEĞİŞTİRMEMELİ (0 dropped, aynı içerik).
# ═══════════════════════════════════════════════════════════════
before="$(cat "$meta")"
result2=$(_meta_rewrite_whitelist "$meta")
read -r kept2 dropped2 <<< "$result2"
after="$(cat "$meta")"
assert_eq "$dropped2" "0"     "temiz dosya üzerinde ikinci çalıştırma HİÇBİR ŞEY atmadı (idempotent)"
assert_eq "$kept2"    "$kept" "temiz dosya üzerinde ikinci çalıştırma aynı sayıda satırı korudu"
assert_eq "$after" "$before" "ikinci çalıştırma sonrası dosya İÇERİĞİ birebir AYNI (idempotent)"

# ═══════════════════════════════════════════════════════════════
# 4) Dosya hiç yoksa → "0 0" döner, hata YOK, dosya OLUŞTURULMAZ
# ═══════════════════════════════════════════════════════════════
never="${WEB_ROOT}/example.com/.hic-yok-boyle-meta"
result3=$(_meta_rewrite_whitelist "$never")
assert_eq "$result3" "0 0" "olmayan dosya için '0 0' döndü"
assert_eq "$([[ -f "$never" ]] && echo var || echo yok)" "yok" "olmayan dosya YARATILMADI"

rm -rf "$WEB_ROOT"
test_summary
