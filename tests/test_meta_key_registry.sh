#!/bin/bash
# Meta anahtar kayıt defteri (registry) drift dedektörü — '.srvctl-meta'ya
# YAZILAN her anahtarın _meta_known_keys (lib/security.sh) whitelist'inde
# VE _meta_validate_value'da kendi case dalında olduğunu STATİK olarak
# doğrular.
#
# NEDEN VAR: bu oturumda AYNI hata sınıfı ÜÇ KEZ tekrarlandı — bir agent
# 'write_meta domain YENİ_ANAHTAR değer' çağrısı ekliyor ama
# lib/security.sh:_meta_known_keys whitelist'ine YENİ_ANAHTAR'ı eklemeyi
# atlıyor (RESOURCE_PROFILE, ISOLATED_FPM, REDIS_CHANNEL_ISOLATION — üçü de
# elle yakalandı). Sonuç SESSİZ VERİ KAYBIDIR: '_meta_rewrite_whitelist'
# (harden-fs --apply'ın çağırdığı) meta dosyasını SIFIRDAN, YALNIZ bilinen
# anahtarları yazarak yeniden üretir — whitelist'te olmayan bir satır
# error/warn ÜRETMEDEN sessizce atlanır (bkz. lib/security.sh
# _meta_rewrite_whitelist). Üretimde şöyle görünür: operatör
# '--resources=ecommerce' ile domain açar, sonra 'harden-fs --apply' çalışır,
# RESOURCE_PROFILE satırı düşer, domain bir sonraki okumada sessizce
# 'standard'a döner — kimse fark etmez.
#
# Bu, şablon token'ları için zaten çözülmüş sınıfla (TOKENS: envanteri +
# tests/test_template_tokens.sh + _domain_assert_no_leftover_tokens runtime
# guard) AYNI YAPISAL SORUN: "üretici" (write_meta / render_template) ile
# "tüketici" (whitelist / TOKENS: listesi) iki ayrı dosyada elle senkron
# tutuluyor. Çözüm de aynı desen: TÜM üretici çağrı sitelerini STATİK
# TARA, gerçek tüketiciyi (whitelist) SOURCE ederek al, ikisini KARŞILAŞTIR.
#
# İKİ YÖNLÜ kontrol:
#   1) YAZILAN ama whitelist'te OLMAYAN  → BULGU (asıl korunan sınıf).
#   2) Whitelist'te olan ama HİÇ YAZILMAYAN → bilgi amaçlı, HATA DEĞİL.
#      (RUN_MIGRATIONS / KEEP_GIT / ISOLATED_FPM operatörün elle '.srvctl-meta'ya
#      koyduğu override'lardır — kod bunları yalnız OKUR, hiçbir 'write_meta'
#      çağrısı bu anahtarları YAZMAZ. Whitelist'te olmaları hâlâ ZORUNLU
#      çünkü _meta_rewrite_whitelist bu anahtarları da KORUMALI — ama
#      "kod hiç yazmıyor" durumu bir regresyon değildir, salt bilgidir.)
#
# AYRICA: whitelist'teki HER anahtarın _meta_validate_value'da KENDİ case
# dalı olmalı — dalı olmayan anahtar `*) return 1` joker dalına düşer ve
# YİNE sessizce atılır (whitelist'e eklemeyi hatırlayıp doğrulayıcıyı
# unutan BİR SONRAKİ kişiyi yakalamak için).
#
# KENDİ KENDİNİ DOĞRULAMA: dedektörün gerçekten çalıştığını (her zaman PASS
# vermediğini) göstermek için — v1 test_no_undefined_functions.sh'ın
# düştüğü tuzak — izole bir fixture dizininde BİLEREK whitelist dışı bir
# 'write_meta' çağrısı ve BİLEREK eksik bir case dalı üretilir; dedektörün
# ikisini de yakaladığı + meşru/bilinen kullanımlarda YANLIŞ ALARM
# VERMEDİĞİ ayrıca doğrulanır.
#
# PARALEL AGENT NOTU: lib/domain.sh şu an db-redis-specialist tarafından
# değiştiriliyor — TARAMA statik (grep) olduğundan domain.sh'ı source ETMEZ,
# yalnız metnini okur. lib/security.sh'daki _meta_known_keys/_meta_validate_value
# yoksa/adı değiştiyse SKIP edilir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

if ! declare -F _meta_known_keys >/dev/null 2>&1 || ! declare -F _meta_validate_value >/dev/null 2>&1; then
    echo "  SKIP: _meta_known_keys/_meta_validate_value henüz yok (lib/security.sh değişmiş olabilir)"
    rm -rf "$WEB_ROOT"
    test_summary
    exit 0
fi

# ─── Tarayıcılar (saf; fixture ile de test edilebilir) ───

# write_meta "<domain-ifadesi>" "ANAHTAR" ... çağrılarından ANAHTAR'ları çıkar.
_extract_written_keys() {
    grep -rhoE 'write_meta[[:space:]]+"[^"]*"[[:space:]]+"[A-Z][A-Z0-9_]*"' "$@" 2>/dev/null \
        | sed -E 's/.*"([A-Z][A-Z0-9_]*)"$/\1/' \
        | sort -u
}

# Bir write_meta çağrısının İLK dosya:satır konumunu bul (BULGU raporlamak için).
_first_write_meta_location() {
    local key="$1"; shift
    grep -rnoE "write_meta[[:space:]]+\"[^\"]*\"[[:space:]]+\"${key}\"" "$@" 2>/dev/null \
        | head -1 | cut -d: -f1-2
}

# Boşluk-ayrılmış bir listede eleman var mı? (PREDİKAT)
_in_list() {
    local needle="$1"; shift
    local w
    for w in "$@"; do
        [[ "$w" == "$needle" ]] && return 0
    done
    return 1
}

# _meta_validate_value GÖVDE METNİNDE <anahtar> için bir case dalı var mı?
# (yorum satırları hariç; joker '*)' dalına düşen anahtarları yakalamak için)
_case_branch_exists() {
    local body="$1" key="$2"
    printf '%s\n' "$body" | grep -v '^[[:space:]]*#' | grep -qE "(^|[^A-Za-z0-9_])${key}\)"
}

# ═══════════════════════════════════════════════════════════════
#  ASIL TARAMA — gerçek lib/*.sh + gerçek whitelist
# ═══════════════════════════════════════════════════════════════
lib_files=("${REPO_ROOT}"/lib/*.sh)
written_keys="$(_extract_written_keys "${lib_files[@]}")"
known_keys="$(_meta_known_keys)"
validate_body="$(sed -n '/^_meta_validate_value() {/,/^}/p' "${REPO_ROOT}/lib/security.sh")"

assert_eq "$(test -n "$written_keys" && echo yes)" "yes" \
    "tarama en az bir write_meta çağrısı buldu (dedektör kör DEĞİL)"
assert_eq "$(test -n "$known_keys" && echo yes)" "yes" \
    "_meta_known_keys boş değil"

# 1) YAZILAN her anahtar whitelist'te mi? (asıl korunan sınıf)
for k in $written_keys; do
    if _in_list "$k" $known_keys; then
        status="whitelisted"
    else
        status="EKSIK(${k}):$(_first_write_meta_location "$k" "${lib_files[@]}")"
    fi
    assert_eq "$status" "whitelisted" "write_meta ile yazılan '${k}' _meta_known_keys içinde"
done

# 2) Whitelist'teki her anahtarın _meta_validate_value'da bir case dalı var mı?
for k in $known_keys; do
    has_branch="yok"
    _case_branch_exists "$validate_body" "$k" && has_branch="var"
    assert_eq "$has_branch" "var" \
        "whitelist anahtarı '${k}' _meta_validate_value içinde KENDİ case dalına sahip (joker '*)' dalına düşmüyor)"
done

# 3) Bilgi amaçlı (HATA DEĞİL): whitelist'te olup kodun hiç YAZMADIĞI anahtarlar.
#    (RUN_MIGRATIONS/KEEP_GIT/ISOLATED_FPM gibi yalnız operatörün elle koyduğu
#    override'lar — testi KIRMAZ, yalnız raporlanır.)
echo ""
echo "  (bilgi) whitelist'te olup HİÇBİR 'write_meta' çağrısının yazmadığı anahtarlar"
echo "          (operatör-elle-override — hata DEĞİL):"
_none_found=1
for k in $known_keys; do
    if ! _in_list "$k" $written_keys; then
        echo "    - ${k}"
        _none_found=0
    fi
done
[[ "$_none_found" -eq 1 ]] && echo "    (yok)"

# ═══════════════════════════════════════════════════════════════
#  KENDİ KENDİNİ DOĞRULAMA — dedektör GERÇEKTEN bulgu üretiyor mu?
#  (izole fixture; gerçek lib/ veya gerçek whitelist DEĞİŞTİRİLMEZ)
# ═══════════════════════════════════════════════════════════════
probe_dir="$(mktemp -d)"

# Probe A: whitelist DIŞI bir write_meta çağrısı — dedektör YAKALAMALI.
cat > "${probe_dir}/probe_bad.sh" << 'EOF'
_probe_fn() {
    write_meta "$domain" "TOTALLY_UNREGISTERED_KEY" "$value"
}
EOF
probe_a_keys="$(_extract_written_keys "${probe_dir}/probe_bad.sh")"
assert_eq "$probe_a_keys" "TOTALLY_UNREGISTERED_KEY" "probe A: sahte çağrıdan anahtar doğru çıkarıldı"
probe_a_status="whitelisted"
_in_list "TOTALLY_UNREGISTERED_KEY" $known_keys || probe_a_status="EKSIK"
assert_eq "$probe_a_status" "EKSIK" \
    "probe A: dedektör whitelist DIŞI anahtarı GERÇEKTEN yakalıyor (kör değil)"

# Probe B: whitelist İÇİ (gerçek, bilinen) bir anahtarla çağrı — YANLIŞ ALARM VERMEMELİ.
cat > "${probe_dir}/probe_good.sh" << 'EOF'
_probe_fn() {
    write_meta "$domain" "FRAMEWORK" "$framework"
}
EOF
probe_b_keys="$(_extract_written_keys "${probe_dir}/probe_good.sh")"
probe_b_status="EKSIK"
_in_list "FRAMEWORK" $known_keys && probe_b_status="whitelisted"
assert_eq "$probe_b_status" "whitelisted" \
    "probe B: meşru/bilinen anahtar kullanımı YANLIŞ ALARM üretmiyor"

# Probe C: _meta_validate_value BENZERİ ama bir anahtarın case dalı EKSİK —
# case-branch dedektörü YAKALAMALI.
probe_c_body='_probe_validate() {
    local key="$1" value="$2"
    case "$key" in
        FRAMEWORK) [[ "$value" == "ci4" ]] ;;
        *) return 1 ;;
    esac
}'
assert_eq "$(_case_branch_exists "$probe_c_body" "FRAMEWORK" && echo var || echo yok)" "var" \
    "probe C: mevcut case dalı doğru tespit ediliyor (yanlış alarm yok)"
assert_eq "$(_case_branch_exists "$probe_c_body" "RESOURCE_PROFILE" && echo var || echo yok)" "yok" \
    "probe C: EKSİK case dalı ('RESOURCE_PROFILE') GERÇEKTEN yakalanıyor (joker '*)' dalına sessizce düşüyor)"

rm -rf "$probe_dir"

rm -rf "$WEB_ROOT"
test_summary
