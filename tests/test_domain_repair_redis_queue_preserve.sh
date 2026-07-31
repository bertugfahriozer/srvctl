#!/bin/bash
# 'domain repair' — Redis scripting (EVAL/Lua) kararının İKİ YÖNLÜ SESSİZ
# DEĞİŞİMDEN korunması (koordinatör düzeltmesi, bkz. lib/domain.sh:_domain_
# redis_queue_gate).
#
# ÖLÇÜM (bu düzeltmeden ÖNCEKİ davranış): '_domain_repair', domainin
# '.srvctl-meta'sındaki MEVCUT REDIS_SCRIPTING değerine HİÇ BAKMADAN,
# scripting_status'u HER ÇALIŞTIRMADA _domain_redis_scripting_mode(major)
# ile SIFIRDAN, YALNIZ o ANKİ Redis sürümüne göre yeniden hesaplıyordu.
# Sonuç: host Redis 6'dan 7'ye yükseltildiğinde (ör. resmi depo geçişi),
# hiçbir '--redis-queue' talebi olmayan bir domain'de 'srvctl domain repair'
# çalıştırıldığı an scripting SESSİZCE 'enabled'a dönerdi — 'domain add'deki
# TAM OLARAK aynı sınıf regresyon ('--redis-queue' YOK sayılan bir domain'in
# sürüm yükseltmesiyle otomatik açılması).
#
# DÜZELTME: repair CLI bayrağı ALMAZ (idempotent bakım komutu) — bunun
# yerine domainin BU çalıştırmadan ÖNCEKİ REDIS_SCRIPTING meta değeri
# "operatör daha önce AÇIKÇA istedi mi" sinyali olarak kullanılır:
#   - önceden 'enabled' + sürüm HÂLÂ izin veriyor  -> 'enabled' KALIR (sessizce KAPANMAZ)
#   - önceden 'enabled' + sürüm ARTIK izin vermiyor -> 'disabled'a düşer AMA
#     bu SESSİZ değil: operatöre "daha önce açıktı, kapatıldı" diye özel bir
#     uyarı ile bildirilir (fail-closed meşru bir gerekçeyle, şeffaf biçimde).
#   - önceden 'disabled'/'unknown'/meta hiç yok -> sürüm 7+'a çıksa BİLE
#     'disabled' KALIR (sessizce AÇILMAZ — bu, koordinatörün özellikle
#     vurguladığı YÖN).
#
# Test-seam'ler (CLAUDE.md deseni): WEB_ROOT / SRVCTL_STATE_DIR / SRVCTL_FPM_DIR
# / SRVCTL_SYSTEMD_DIR / SRVCTL_PHP_POOL_DIR — gerçek /etc'e dokunmadan test.
# '_redis_version_pair' (core.sh) test boyunca sahte bir sürüm döndürecek
# şekilde EZİLİR (override) — gerçek redis-server'a dokunmadan sürüm senaryosu
# (6 vs 7) enjekte edilir.
#
# PARALEL AGENT NOTU: lib/domain.sh başka agent'lar tarafından da
# değiştiriliyor olabilir — ilgili sembol yoksa/adı değiştiyse SKIP edilir.
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
certbot() { return 0; }
systemctl() { return 0; }
redis-cli() { return 0; }
nginx() { return 0; }
aa-disable() { return 0; }
userdel() { return 0; }
groupdel() { return 0; }
# Bu testin konusu Redis scripting kararı — hayalet/kalıntı tespiti DEĞİL;
# fixture'lar gerçek bir Linux kullanıcısı oluşturmuyor (bkz.
# test_domain_repair_isolation.sh'taki AYNI NÖTRLEME gerekçesi).
id() { return 0; }

# ─── Redis sürüm enjeksiyonu (gerçek redis-server'a dokunmadan) ───
FAKE_REDIS_MAJOR="7"
FAKE_REDIS_MINOR="0"
_redis_version_pair() { echo "${FAKE_REDIS_MAJOR} ${FAKE_REDIS_MINOR}"; }

source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_repair >/dev/null 2>&1 || ! declare -F _domain_redis_queue_gate >/dev/null 2>&1; then
    echo "  SKIP: _domain_repair/_domain_redis_queue_gate henüz yok (lib/domain.sh paralel değişiyor olabilir)"
    rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"
    test_summary
    exit 0
fi

_setup_domain() {
    local domain="$1" sname
    sname=$(safe_name "$domain")
    mkdir -p "${WEB_ROOT}/${domain}"
    _domain_write_credentials "$domain" "${WEB_ROOT}/${domain}" "web_${sname}" "8.3" \
        "db_${sname}" "usr_${sname}" "cleanpassdb1234" \
        "redis_${sname}" "cleanpassredis1234" "${sname}:"
}

_final_status() {
    local domain="$1"
    _domain_read_redis_scripting_status "$domain" 2>/dev/null
}

echo "== domain repair: Redis scripting kararının iki yönlü sessiz değişimden korunması =="

# ═════ Senaryo 1 (KRİTİK): önceden KAPALI + Redis ŞİMDİ >=7 -> KAPALI KALMALI ═════
# (koordinatörün özellikle vurguladığı yön: sürüm yükseltmesi TEK BAŞINA
#  hiçbir domaini sessizce açamaz)
d1="repair-closed-stays-closed.test"
_setup_domain "$d1"
write_meta "$d1" "REDIS_SCRIPTING" "disabled"
FAKE_REDIS_MAJOR="7"; FAKE_REDIS_MINOR="0"
_domain_repair "$d1" >/dev/null 2>&1
assert_eq "$(_final_status "$d1")" "disabled" \
    "KRİTİK: önceden disabled + Redis>=7 -> repair sonrası YİNE disabled (sessizce AÇILMADI)"

# ═════ Senaryo 1b: meta HİÇ YOK (eski/yeni domain) + Redis >=7 -> KAPALI KALMALI ═════
d1b="repair-no-meta-stays-closed.test"
_setup_domain "$d1b"
FAKE_REDIS_MAJOR="7"; FAKE_REDIS_MINOR="0"
_domain_repair "$d1b" >/dev/null 2>&1
assert_eq "$(_final_status "$d1b")" "disabled" \
    "meta hiç yoksa (unknown) + Redis>=7 -> repair sonrası disabled (sessizce AÇILMADI)"

# ═════ Senaryo 2 (KRİTİK): önceden AÇIK + Redis HÂLÂ >=7 -> AÇIK KALMALI ═════
# (kapanmamalı — sessiz kayıp yaşanmamalı)
d2="repair-open-stays-open.test"
_setup_domain "$d2"
write_meta "$d2" "REDIS_SCRIPTING" "enabled"
FAKE_REDIS_MAJOR="7"; FAKE_REDIS_MINOR="0"
_domain_repair "$d2" >/dev/null 2>&1
assert_eq "$(_final_status "$d2")" "enabled" \
    "KRİTİK: önceden enabled + Redis hâlâ >=7 -> repair sonrası YİNE enabled (sessizce KAPANMADI)"

# ═════ Senaryo 3: önceden AÇIK + Redis ARTIK <7 (downgrade) -> KAPANIR AMA ŞEFFAF ═════
d3="repair-open-downgrades-safely.test"
_setup_domain "$d3"
write_meta "$d3" "REDIS_SCRIPTING" "enabled"
FAKE_REDIS_MAJOR="6"; FAKE_REDIS_MINOR="0"
out3="$(_domain_repair "$d3" 2>&1)"
assert_eq "$(_final_status "$d3")" "disabled" \
    "önceden enabled + Redis artık <7 -> fail-closed uygulanır (disabled, ZORLA açık bırakılmaz)"
assert_contains "$out3" "DAHA ÖNCE AÇIKTI" \
    "downgrade durumu SESSİZ değil — operatöre önceden açık olduğu AÇIKÇA bildirilir"

# ═════ Senaryo 4 (sanity): önceden KAPALI + Redis <7 -> davranış DEĞİŞMEDİ ═════
d4="repair-closed-stays-closed-v6.test"
_setup_domain "$d4"
write_meta "$d4" "REDIS_SCRIPTING" "disabled"
FAKE_REDIS_MAJOR="6"; FAKE_REDIS_MINOR="0"
_domain_repair "$d4" >/dev/null 2>&1
assert_eq "$(_final_status "$d4")" "disabled" \
    "sanity: önceden disabled + Redis<7 -> disabled (değişmedi)"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"
test_summary
