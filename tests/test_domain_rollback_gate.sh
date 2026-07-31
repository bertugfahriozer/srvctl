#!/bin/bash
# B3 (denetim): '_domain_purge_resources' — DB/sertifika "önceden var mıydı"
# bayrakları.
#
# ESKİ AÇIK: 'domain add' ortasında bir adım başarısız olup rollback (EXIT/
# INT/TERM trap'i) tetiklendiğinde, eski kod KOŞULSUZ 'DROP DATABASE'
# çalıştırıyordu. Senaryo: '/var/www/${domain}' henüz yok ama
# 'db_${sname}' zaten VAR (ör. bir yedekten 'zcat | mysql' ile ELLE geri
# yüklenmiş, ya da 'domain add' aynı isimle DAHA ÖNCE kısmen denenmiş ve DB
# adım 8'de zaten oluşturulmuş) — sonraki bir adım (ör. redis restart)
# başarısız olup rollback devreye girerse, GERİ YÜKLENMİŞ ÜRETİM VERİSİ
# (ya da önceki denemenin DB'si) sessizce DROP ediliyordu. Aynı sınıf:
# certbot bu çalıştırmada sertifikayı HİÇ ALMAMIŞ olsa bile 'certbot
# delete' onu silerdi (başka bir süreç/manuel adım tarafından önceden
# alınmış olabilir).
#
# DÜZELTME: '_domain_add' rollback tetiklenmeden ÖNCE DB/sertifikanın
# ÇALIŞTIRMA'DAN ÖNCE var olup olmadığını kaydeder (_db_preexisted/
# _cert_preexisted), bunları '_domain_purge_resources'a bayrak olarak
# geçirir — bu fonksiyon GERÇEKTEN OLUŞTURULMAYAN kaynaklara ASLA
# dokunmaz: preexisted=1 ise DROP DATABASE/'certbot delete' ATLANIR
# (yalnızca warn), DROP USER HER ZAMAN çalışır (kullanıcı hesabı bu
# çalıştırmanın kendi ürünüdür, ayrım gerekmez).
#
# Bu test _domain_purge_resources'ı GERÇEKTEN çalıştırır; mysql/certbot
# ÇAĞRILARINI bir log dosyasına yakalayan stub'larla (gerçek servise
# dokunmadan) hangi komutların GERÇEKTEN yürütüldüğünü doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

mysql_log="${WEB_ROOT}/mysql.log"
certbot_log="${WEB_ROOT}/certbot.log"
mysql()        { printf '%s\n' "$*" >> "$mysql_log"; return 0; }
certbot()      { printf '%s\n' "$*" >> "$certbot_log"; return 0; }
systemctl()    { return 0; }
nginx()        { return 0; }
aa-disable()   { return 0; }
userdel()      { return 0; }
groupdel()     { return 0; }

source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_purge_resources >/dev/null 2>&1; then
    echo "SKIP: _domain_purge_resources tanımlı değil"
    test_summary
    exit $?
fi

# ═══ Vaka 1: DB + sertifika bu çalıştırmadan ÖNCE zaten VARDI (preexisted=1) ═══
: > "$mysql_log"; : > "$certbot_log"
d1="preexisting.com"
mkdir -p "${WEB_ROOT}/${d1}"
_domain_purge_resources "$d1" "8.3" "1" "1" >/dev/null 2>&1

assert_not_contains "$(cat "$mysql_log")" "DROP DATABASE" \
    "B3: DB önceden vardıysa (preexisted=1) DROP DATABASE ÇALIŞTIRILMADI"
assert_contains "$(cat "$mysql_log")" "DROP USER" \
    "B3: DROP USER her durumda çalışır (hesap bu çalıştırmanın ürünü)"
assert_eq "$(cat "$certbot_log")" "" \
    "B3: sertifika önceden vardıysa (preexisted=1) 'certbot delete' ÇALIŞTIRILMADI"

# ═══ Vaka 2: DB + sertifika bu çalıştırmada OLUŞTURULDU (preexisted=0) ═══
: > "$mysql_log"; : > "$certbot_log"
d2="freshly-created.com"
mkdir -p "${WEB_ROOT}/${d2}"
_domain_purge_resources "$d2" "8.3" "0" "0" >/dev/null 2>&1

assert_contains "$(cat "$mysql_log")" "DROP DATABASE" \
    "B3: DB bu çalıştırmada oluşturulduysa (preexisted=0) DROP DATABASE ÇALIŞTIRILDI"
assert_contains "$(cat "$certbot_log")" "delete" \
    "B3: sertifika bu çalıştırmada alındıysa (preexisted=0) 'certbot delete' ÇALIŞTIRILDI"

# ═══ Varsayılan (argüman verilmezse) preexisted=0 kabul eder (geriye uyumlu) ═══
: > "$mysql_log"; : > "$certbot_log"
d3="no-flags.com"
mkdir -p "${WEB_ROOT}/${d3}"
_domain_purge_resources "$d3" "8.3" >/dev/null 2>&1
assert_contains "$(cat "$mysql_log")" "DROP DATABASE" \
    "B3: bayrak verilmezse varsayılan preexisted=0 (geriye uyumlu — eski çağıranlar da temizler)"

rm -rf "$WEB_ROOT"
test_summary
