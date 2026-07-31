#!/bin/bash
# HEALTH_OK_CODES meta anahtarı — whitelist regresyon testi.
#
# GERÇEK ÜRETİM ENGELİ: HTTP Basic auth ile korunan bir staging site
# kimliksiz HER isteğe BİLİNÇLİ olarak 401 döner. lib/deploy.sh bunu
# per-domain '.srvctl-meta: HEALTH_OK_CODES' ile kabul edilebilir hale
# getiriyor — ANCAK lib/security.sh:_meta_known_keys whitelist'i bu
# anahtarı tanımıyorsa 'harden-fs --apply' meta dosyasını SIFIRDAN
# yeniden yazarken satırı SESSİZCE ATAR (bkz. _meta_rewrite_whitelist).
# Operatörün ayarı ilk 'harden-fs' çalıştırmasında kaybolur ve site bir
# daha HİÇ deploy edilemez — kimse fark etmeden.
#
# Bu test üç KRİTİK assertion'ı doğrular:
#   1) HEALTH_OK_CODES artık _meta_known_keys whitelist'inde.
#   2) Geçerli bir kod listesi _meta_validate_value + harden-fs
#      yeniden-yazımı tarafından KORUNUYOR.
#   3) Geçersiz değerler (not-a-code / 999 / boş) REDDEDİLİYOR.
#
# MUTASYON (self-check): bu testin GERÇEKTEN bir şey doğruladığını
# kanıtlamak için — lib/security.sh'ın scratchpad MUTANT kopyasında
# HEALTH_OK_CODES whitelist'ten ÇIKARILIR ve _meta_rewrite_whitelist'in
# bu mutantta satırı SESSİZCE ATTIĞI doğrulanır. Yani bu görevdeki
# düzeltme YAPILMASAYDI bu test dosyası regresyonu GERÇEKTEN yakalardı
# (kör bir PASS değil).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

if ! declare -F _meta_known_keys >/dev/null 2>&1 \
    || ! declare -F _meta_validate_value >/dev/null 2>&1 \
    || ! declare -F _meta_rewrite_whitelist >/dev/null 2>&1; then
    echo "  SKIP: _meta_known_keys/_meta_validate_value/_meta_rewrite_whitelist henüz yok"
    rm -rf "$WEB_ROOT"
    test_summary
    exit 0
fi

# ═══ 1) HEALTH_OK_CODES whitelist'te mi? ═══
known_keys="$(_meta_known_keys)"
in_whitelist="hayir"
for k in $known_keys; do
    [[ "$k" == "HEALTH_OK_CODES" ]] && in_whitelist="evet"
done
assert_eq "$in_whitelist" "evet" "HEALTH_OK_CODES _meta_known_keys whitelist'inde"

# ═══ 2) _meta_validate_value — geçerli/geçersiz değerler (validate_http_code ile TUTARLI) ═══
assert_ok   _meta_validate_value HEALTH_OK_CODES "200"
assert_ok   _meta_validate_value HEALTH_OK_CODES "200 301 302"
assert_ok   _meta_validate_value HEALTH_OK_CODES "200 301 302 401"
assert_fail _meta_validate_value HEALTH_OK_CODES "not-a-code"
assert_fail _meta_validate_value HEALTH_OK_CODES "999"                       # aralık dışı (100-599)
assert_fail _meta_validate_value HEALTH_OK_CODES "20"                        # 2 haneli, biçim geçersiz
assert_fail _meta_validate_value HEALTH_OK_CODES ""                         # boş -> reddedilir (sessizce genişlemez)
assert_fail _meta_validate_value HEALTH_OK_CODES "200 not-a-code 301"        # listede TEK geçersiz öğe -> tamamı red

# ═══ 3) _meta_rewrite_whitelist ile uçtan uca — 'harden-fs --apply' GERÇEKTEN koruyor mu? ═══
mkdir -p "${WEB_ROOT}/dev.example.com"
meta="${WEB_ROOT}/dev.example.com/.srvctl-meta"
cat > "$meta" <<'EOF'
RATE_PROFILE=standard
HEALTH_OK_CODES=200 301 302 401
EOF
result=$(_meta_rewrite_whitelist "$meta")
read -r kept dropped <<< "$result"
assert_eq "$kept" "2" "HEALTH_OK_CODES + RATE_PROFILE = 2 satır KORUNDU"
assert_eq "$dropped" "0" "hiçbir satır atılmadı"
content="$(cat "$meta")"
assert_contains "$content" "HEALTH_OK_CODES=200 301 302 401" \
    "harden-fs --apply SONRASI HEALTH_OK_CODES satırı HÂLÂ MEVCUT (üretim regresyonu düzeltildi)"

# Geçersiz değerli HEALTH_OK_CODES satırı ATILMALI (whitelist'te olmak yetmez, değer de geçerli olmalı)
mkdir -p "${WEB_ROOT}/bad.example.com"
meta_bad="${WEB_ROOT}/bad.example.com/.srvctl-meta"
printf 'HEALTH_OK_CODES=not-a-code\n' > "$meta_bad"
result_bad=$(_meta_rewrite_whitelist "$meta_bad")
read -r kept_bad dropped_bad <<< "$result_bad"
assert_eq "$kept_bad" "0" "geçersiz değerli HEALTH_OK_CODES KORUNMADI"
assert_eq "$dropped_bad" "1" "geçersiz değerli HEALTH_OK_CODES ATILDI"

# Boş değerli HEALTH_OK_CODES da ATILMALI (boş liste hiçbir kodu kabul etmez -> her deploy'u geri aldırır)
mkdir -p "${WEB_ROOT}/empty.example.com"
meta_empty="${WEB_ROOT}/empty.example.com/.srvctl-meta"
printf 'HEALTH_OK_CODES=\n' > "$meta_empty"
result_empty=$(_meta_rewrite_whitelist "$meta_empty")
read -r kept_empty dropped_empty <<< "$result_empty"
assert_eq "$kept_empty" "0" "boş HEALTH_OK_CODES KORUNMADI"
assert_eq "$dropped_empty" "1" "boş HEALTH_OK_CODES ATILDI"

# ═══ 4) MUTASYON self-check — bu dedektör GERÇEKTEN bir şey mi kontrol ediyor? ═══
# lib/security.sh'ın scratchpad kopyasında HEALTH_OK_CODES'u whitelist'ten
# ÇIKARAN bir mutant üretilir; mutant üzerinde _meta_rewrite_whitelist'in
# AYNI satırı SESSİZCE ATTIĞI doğrulanır — yani bu görevdeki düzeltme
# YAPILMASAYDI üretimde yaşanan kayıp senaryosu BURADA yeniden üretilebiliyor.
MUTANT_DIR="$(mktemp -d)"
mutant_file="${MUTANT_DIR}/security_mutant.sh"
sed -E 's/(RESOURCE_PROFILE) HEALTH_OK_CODES"/\1"/' "${REPO_ROOT}/lib/security.sh" > "$mutant_file"

# Mutasyonun GERÇEKTEN uygulandığını doğrula (yanlışlıkla no-op sed olup testi kör bırakmasın)
mutant_known_line="$(grep -n 'RATE_PROFILE SENSITIVE_PATHS FRAMEWORK' "$mutant_file" | head -1)"
if [[ "$mutant_known_line" == *"HEALTH_OK_CODES"* ]]; then
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "  $(_red FAIL) mutasyon UYGULANAMADI — sed deseni eşleşmedi, aşağıdaki self-check kör olurdu"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $(_green PASS) mutasyon uygulandı: mutant kopyada HEALTH_OK_CODES whitelist'ten ÇIKARILDI"
fi

runner="${MUTANT_DIR}/run_mutant.sh"
cat > "$runner" <<EOF
set -uo pipefail
source "${REPO_ROOT}/lib/core.sh"
source "${mutant_file}"
mkdir -p "\${WEB_ROOT}/mutant.example.com"
m="\${WEB_ROOT}/mutant.example.com/.srvctl-meta"
printf 'HEALTH_OK_CODES=200 301 302 401\n' > "\$m"
_meta_rewrite_whitelist "\$m"
echo "---CONTENT---"
cat "\$m"
EOF

mutant_out="$(bash "$runner" 2>&1)"
mutant_result_line="$(printf '%s\n' "$mutant_out" | sed -n '1p')"
mutant_content="$(printf '%s\n' "$mutant_out" | sed -n '3,$p')"
read -r mutant_kept mutant_dropped <<< "$mutant_result_line"

assert_eq "$mutant_kept" "0" \
    "MUTASYON: whitelist'ten çıkarılmış anahtar mutant'ta ARTIK KORUNMUYOR (bu, düzeltme öncesi gerçek üretim hatasının simülasyonu)"
assert_eq "$mutant_dropped" "1" \
    "MUTASYON: satır SESSİZCE ATILDI (harden-fs --apply hiçbir error/warn üretmeden düşürüyor)"
assert_not_contains "$mutant_content" "HEALTH_OK_CODES" \
    "MUTASYON: mutant dosyada HEALTH_OK_CODES satırı KALMADI (operatörün ayarı sessizce kaybolurdu)"

rm -rf "$MUTANT_DIR"
rm -rf "$WEB_ROOT"
test_summary
