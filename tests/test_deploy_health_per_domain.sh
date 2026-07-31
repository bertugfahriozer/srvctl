#!/bin/bash
# Per-domain HEALTH_OK_CODES override — regresyon testi.
#
# GERÇEK ÜRETİM ENGELİ: bir staging sitesi (dev.<domain>) UYGULAMA
# SEVİYESİNDE HTTP Basic auth ile korunuyor; uygulamanın kendi 'DevGate'
# filtresi ENVIRONMENT=development iken kimliksiz HER isteğe BİLİNÇLİ olarak
# 401 döner (markalı "401 - Unauthorized" sayfası). Bu bir arıza DEĞİL,
# site dışarıya kapalı — ama _deploy_health_ok varsayılanda ("200 301 302")
# 401'i ölümcül sayıyor ve deploy'un [9/9] adımında OTOMATİK ROLLBACK
# tetikleniyordu; bu site srvctl ile HİÇ deploy edilemiyordu.
#
# DEPLOY_HEALTH_OK_CODES (global env/conf) zaten vardı ve çalışıyordu, ama
# TÜM domainleri etkiliyordu — bir domain için 401'i kabul etmek diğer
# domainlerde gerçek bir 401 arızasını görünmez kılardı. Bu test per-domain
# '.srvctl-meta: HEALTH_OK_CODES' override'ını doğrular:
#   1) Yapılandırma YOKKEN 401 hâlâ BAŞARISIZ sayılıyor (global gevşemiyor).
#   2) Per-domain override VARKEN 401 SADECE O domain için kabul ediliyor
#      (izolasyon: başka bir domain'e SIZMIYOR).
#   3) Gevşetme deploy/rollback/health çıktısında AÇIKÇA GÖRÜNÜYOR
#      (_deploy_health_report_override).
#   4) Geçersiz biçimli bir override SESSİZCE YOK SAYILIR (fail-soft) — asla
#      global varsayılanı GENİŞLETMEZ.
#
# NOT (koordinasyon): per-domain HEALTH_OK_CODES anahtarı
# 'lib/security.sh:_meta_known_keys' beyaz listesine de EKLENMELİDİR (bu
# dosyanın kapsamı DIŞINDA — bkz. görev talimatı); aksi halde
# 'harden-fs --apply' bu anahtarı meta'yı yeniden yazarken SESSİZCE atar.
# Bu test yalnız TÜKETİCİ tarafını (lib/deploy.sh okuma yolu) doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Test-seam'ler (bkz. CLAUDE.md "Test-seams for macOS dev" ve
# tests/test_deploy_framework_declared_build.sh AYNI desen): SRVCTL_STATE_DIR
# override edilirse '_domain_is_hardened' test domain'lerini HİÇBİR ZAMAN
# "hardened" bulmaz, '_require_owned_or_warn' sahiplik denetimini atlar
# (warn+devam) ve macOS'ta root OLMADAN .srvctl-meta okunabilir.
export SRVCTL_STATE_DIR="$(mktemp -d)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_health_ok >/dev/null 2>&1 \
    || ! declare -F _deploy_health_codes >/dev/null 2>&1 \
    || ! declare -F _deploy_health_report_override >/dev/null 2>&1; then
    echo "  SKIP: per-domain HEALTH_OK_CODES fonksiyonları henüz yok"
    test_summary
    rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
    exit 0
fi

# ═══ 1) KRİTİK: yapılandırma YOKKEN 401 hâlâ başarısız — GLOBAL gevşemedi ═══
assert_eq "${DEPLOY_HEALTH_OK_CODES}" "200 301 302" "varsayılan GLOBAL DEPLOY_HEALTH_OK_CODES değişmedi"
assert_ok   _deploy_health_ok "200"                  # domainsiz eski çağrı biçimi (geriye uyum)
assert_fail _deploy_health_ok "401"                  # domainsiz -> 401 hâlâ ölümcül
assert_fail _deploy_health_ok "401" ""                # boş domain -> aynı sonuç

dom_nometa="plain.example.com"
mkdir -p "${WEB_ROOT}/${dom_nometa}"
assert_fail _deploy_health_ok "401" "$dom_nometa"     # meta hiç yok -> 401 hâlâ ölümcül

# ═══ 2) Per-domain override YALNIZ O domain'i etkiler (izolasyon) ═══
dom_dev="dev.example.com"
mkdir -p "${WEB_ROOT}/${dom_dev}"
printf 'HEALTH_OK_CODES=200 301 302 401\n' > "${WEB_ROOT}/${dom_dev}/.srvctl-meta"

assert_ok   _deploy_health_ok "401" "$dom_dev"        # artık kabul ediliyor
assert_ok   _deploy_health_ok "200" "$dom_dev"        # varsayılan kodlar hâlâ geçerli
assert_fail _deploy_health_ok "500" "$dom_dev"        # override listesinde OLMAYAN kod hâlâ reddediliyor

dom_other="other.example.com"
mkdir -p "${WEB_ROOT}/${dom_other}"
assert_fail _deploy_health_ok "401" "$dom_other"      # override BAŞKA domain'e SIZMADI
assert_fail _deploy_health_ok "401"                    # global/domainsiz çağrı hâlâ etkilenmedi

# ═══ 3) Geçersiz biçimli override SESSİZCE reddedilir (fail-soft, asla genişletmez) ═══
dom_bad="bad.example.com"
mkdir -p "${WEB_ROOT}/${dom_bad}"
printf 'HEALTH_OK_CODES=not-a-code\n' > "${WEB_ROOT}/${dom_bad}/.srvctl-meta"
assert_fail _deploy_health_ok "401" "$dom_bad"        # geçersiz değer -> global varsayılana düşüldü

dom_bad2="bad2.example.com"
mkdir -p "${WEB_ROOT}/${dom_bad2}"
printf 'HEALTH_OK_CODES=999\n' > "${WEB_ROOT}/${dom_bad2}/.srvctl-meta"   # 999: 3 haneli ama aralık dışı (100-599)
assert_fail _deploy_health_ok "999" "$dom_bad2"       # validate_http_code aralığı da uygulanıyor

# ═══ 4) Görünürlük (görev şartı #2): override YÜRÜRLÜKTEYSE çıktıda AÇIKÇA görünsün ═══
out_dev=$(_deploy_health_report_override "$dom_dev" "401" 2>&1)
assert_contains "$out_dev" "401" "görünürlük mesajı kabul edilen kodu (401) açıkça anıyor"
assert_contains "$out_dev" "KABUL EDİLEN kod olarak yapılandırılmış" "görünürlük mesajı 'kabul edilen kod' ifadesini içeriyor"
assert_contains "$out_dev" "HEALTH_OK_CODES" "görünürlük mesajı .srvctl-meta anahtarını anıyor"

# Override YOKSA (ya da devreye girmediyse) görünürlük mesajı BASILMAMALI —
# aksi halde her health-check çıktısı gereksiz gürültüyle dolar.
out_other=$(_deploy_health_report_override "$dom_other" "200" 2>&1)
assert_eq "$out_other" "" "override yokken görünürlük mesajı SESSİZ"

# Geçersiz override -> ayrı bir tanılama uyarısı (farklı domain, spam ÖNLENMİŞ:
# retry döngüsünün İÇİNDEN değil, çağrı başına BİR KEZ çağrılır — bkz. lib/deploy.sh).
out_bad=$(_deploy_health_report_override "$dom_bad" "401" 2>&1)
assert_contains "$out_bad" "Geçersiz .srvctl-meta HEALTH_OK_CODES" "geçersiz override tanılama uyarısı basıldı"

# ═══ 5) _health_probe UÇTAN UCA: retry döngüsü domain'e özel override'ı GERÇEKTEN kullanıyor ═══
# (bkz. test_deploy_health_ok.sh'taki AYNI dosya-tabanlı sayaç deseni — nested
# subshell'ler arası paylaşılan durum İÇİN sıradan bir shell değişkeni YETMEZ.)
_probe_counter_file="$(mktemp)"
_probe_sequence=()
_deploy_http_code() {
    local n
    n=$(<"$_probe_counter_file")
    n=$((n + 1))
    echo "$n" > "$_probe_counter_file"
    echo "${_probe_sequence[$((n - 1))]:-000}"
}

# dom_dev (override'lı): ilk denemede 401 gelirse HEMEN kabul edilip erken çıkmalı.
echo 0 > "$_probe_counter_file"
_probe_sequence=(401 200 200)
DEPLOY_HEALTH_RETRIES=5 DEPLOY_HEALTH_INTERVAL=0 out=$(_health_probe "$dom_dev")
assert_eq "$out" "401" "override'lı domain: HTTP 401 ilk denemede kabul edildi"
assert_eq "$(cat "$_probe_counter_file")" "1" "override'lı domain: erken çıkış (yalnız 1 deneme)"

# dom_other (override YOK): AYNI 401 dizisi bu sefer TÜM denemeleri tüketmeli.
echo 0 > "$_probe_counter_file"
_probe_sequence=(401 401 401 401 401)
DEPLOY_HEALTH_RETRIES=5 DEPLOY_HEALTH_INTERVAL=0 out=$(_health_probe "$dom_other")
assert_eq "$out" "401" "override'sız domain: HTTP 401 yine SON görülen kod olarak döner"
assert_eq "$(cat "$_probe_counter_file")" "5" "override'sız domain: 401 kabul edilmediği için TÜM denemeler tüketildi"

rm -f "$_probe_counter_file"
unset -f _deploy_http_code

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
