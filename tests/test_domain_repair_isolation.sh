#!/bin/bash
# 'domain repair' izolasyon-farkındalığı regresyonu — BLOKE EDİCİ bug, gerçek
# Ubuntu 22.04 VM'de kanıtlandı.
#
# KÖK NEDEN (lib/domain.sh:_domain_repair): repair KOŞULSUZ olarak pool
# tanımını paylaşılan '/etc/php/<ver>/fpm/pool.d/<sname>.conf'a yazıyordu.
# Domain per-domain FPM unit'e (DOMAIN_ISOLATED_FPM=true — varsayılan) zaten
# geçmişse bu, izole unit'in ZATEN bind ettiği unix socket'i PAYLAŞILAN
# master'a da tanımlatıyordu. Paylaşılan master aynı socket'i bind edemeyip
# 'status=78' (config hatası) ile ölüyor ve BİR SONRAKİ 'domain add' (önce
# paylaşılan pool'a yazıp master'ı başlatan akış) o andan itibaren HER ZAMAN
# başarısız oluyordu — 100 domain hedefinin önünde tam bir engel.
#
# Bu test üç şeyi kilitler:
#   1) İZOLE domainde repair pool.d'ye YAZMAZ — izole hedefe
#      (${SRVCTL_FPM_DIR}/<sname>.conf) yazar.
#   2) PAYLAŞILAN pool'da çalışan (izole OLMAYAN) domainde repair ESKİ (doğru)
#      davranışı KORUR — pool.d'ye yazmaya devam eder (regresyon: davranışı
#      yanlışlıkla tersine çevirmedik).
#   3) Bozuk-MEVCUT-kurulum onarımı: "izole unit VAR + pool.d'de AYNI isimde
#      kalıntı VAR" durumunda repair kalıntıyı TESPİT EDİP KALDIRIR (bu bug'a
#      daha önce çarpmış bir sunucudaki mevcut arızayı da onarır).
#
# Test-seam'ler (CLAUDE.md deseni): WEB_ROOT / SRVCTL_STATE_DIR / SRVCTL_FPM_DIR
# / SRVCTL_SYSTEMD_DIR / SRVCTL_PHP_POOL_DIR — hepsi macOS'ta gerçek /etc'e
# dokunmadan test edilebilsin diye lib/domain.sh'ta zaten var olan (ya da bu
# değişiklikle eklenen) env override'lardır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
mysql() { return 0; }
systemctl() { return 0; }
redis-cli() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_repair >/dev/null 2>&1; then
    echo "  SKIP: _domain_repair tanımlı değil"
    test_summary
    exit $?
fi

# Yardımcı: bir domain'in temel '.credentials' + dizin iskeletini kur
# (gerçek 'domain add' akışını TAMAMEN taklit etmez — yalnız repair'in
# ihtiyaç duyduğu asgari durumu kurar).
_setup_domain() {
    local domain="$1" sname
    sname=$(safe_name "$domain")
    mkdir -p "${WEB_ROOT}/${domain}"
    _domain_write_credentials "$domain" "${WEB_ROOT}/${domain}" "web_${sname}" "8.3" \
        "db_${sname}" "usr_${sname}" "cleanpassdb1234" \
        "redis_${sname}" "cleanpassredis1234" "${sname}:"
}

echo "== domain repair: izolasyon-farkındalığı =="

# ═══════════════ Vaka 1: İZOLE domain — repair pool.d'ye YAZMAMALI ═══════════════
d1="isolated-shop.test"
sname1=$(safe_name "$d1")
_setup_domain "$d1"
# İzole unit'i ÖNCEDEN var say (ör. 'harden-fpm --apply' daha önce uygulanmış)
printf 'listen = /run/php/php8.3-fpm-%s.sock\n' "$sname1" > "${SRVCTL_FPM_DIR}/${sname1}.conf"

_domain_repair "$d1" >/dev/null 2>&1

assert_eq "$(test -f "${SRVCTL_PHP_POOL_DIR}/${sname1}.conf" && echo VAR || echo YOK)" "YOK" \
    "İzole domain: repair sonrası pool.d'de dosya YOK (paylaşılan master'la socket çakışması oluşmadı)"
assert_contains "$(cat "${SRVCTL_FPM_DIR}/${sname1}.conf" 2>/dev/null)" "chroot" \
    "İzole domain: repair GERÇEKTEN izole hedefe yazdı (pool.conf.tpl render edildi)"

# ═══════════════ Vaka 2: PAYLAŞILAN pool domain — eski (doğru) davranış KORUNUR ═══════════════
d2="shared-shop.test"
sname2=$(safe_name "$d2")
_setup_domain "$d2"
# Bu domain için izole conf YOK -> repair paylaşılan pool.d'ye yazmalı (regresyon yok)

_domain_repair "$d2" >/dev/null 2>&1

assert_contains "$(cat "${SRVCTL_PHP_POOL_DIR}/${sname2}.conf" 2>/dev/null)" "chroot" \
    "Paylaşılan-pool domain: repair pool.d'ye yazmaya DEVAM EDİYOR"
assert_eq "$(test -f "${SRVCTL_FPM_DIR}/${sname2}.conf" && echo VAR || echo YOK)" "YOK" \
    "Paylaşılan-pool domain: izole hedefe YAZILMADI (yanlış dala düşmedi)"

# ═══════════════ Vaka 3: Bozuk MEVCUT kurulum — kalıntı OTOMATİK temizlenir ═══════════════
d3="broken-shop.test"
sname3=$(safe_name "$d3")
_setup_domain "$d3"
printf 'listen = /run/php/php8.3-fpm-%s.sock\n' "$sname3" > "${SRVCTL_FPM_DIR}/${sname3}.conf"
# ÖNCEKİ (buggy) repair'in bıraktığı türden bir kalıntıyı simüle et: aynı isimde
# pool.d kopyası, izole unit'le socket çakışması yaratacak durumda.
printf 'chroot = %s/%s\nlisten = /run/php/php8.3-fpm-%s.sock\n' "$WEB_ROOT" "$d3" "$sname3" \
    > "${SRVCTL_PHP_POOL_DIR}/${sname3}.conf"

out3="$(_domain_repair "$d3" 2>&1)"

assert_eq "$(test -f "${SRVCTL_PHP_POOL_DIR}/${sname3}.conf" && echo VAR || echo YOK)" "YOK" \
    "Bozuk mevcut kurulum: kalıntı pool.d kopyası KALDIRILDI"
assert_contains "$out3" "kalıntı" "Bozuk mevcut kurulum: kullanıcıya Türkçe bilgi verildi"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"
test_summary
