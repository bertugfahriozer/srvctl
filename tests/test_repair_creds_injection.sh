#!/bin/bash
# K3 (denetim DALGA 4 — KRİTİK): '.credentials' içindeki DB_PASS/REDIS_PASS
# artık DOĞRUDAN bir SQL heredoc'una ve tek satırlık Redis ACL metnine
# GÖMÜLÜYOR — ikisi de birer string-enjeksiyon sink'i.
#
# ESKİ AÇIK: henüz hardened olmayan (harden-fs uygulanmamış) bir domainde
# '.credentials' web_user tarafından SİLİNİP YENİDEN YAZILABİLİR
# (_require_owned_or_warn bu durumda yalnız warn verip 0 döner). Saldırgan
# (ele geçirilmiş bir PHP endpoint'i üzerinden) ör.
#   DB_PASS="x'; GRANT ALL PRIVILEGES ON *.* TO 'usr_evil'@'127.0.0.1'; --"
# ya da
#   REDIS_PASS="y ~* &* +@all"
# yazarsa, 'srvctl domain repair' çalıştığında root'un MySQL oturumuna SQL
# enjekte edebilir ya da Redis ACL satırına (boşlukla ayrılmış token'lar)
# fazladan token ekleyip '~*' ile TÜM Redis anahtarlarına erişebilirdi.
#
# DÜZELTME (_domain_repair, lib/domain.sh): DB_PASS/REDIS_PASS kullanılmadan
# ÖNCE '^[A-Za-z0-9]+$' beyaz listesinden geçirilir (generate_password()'ın
# ürettiği karakter kümesiyle BİREBİR aynı) — uymayan (tamper edilmiş) bir
# değer SQL/ACL'e ASLA AKMAZ; bunun yerine YENİ bir parola üretilip
# '.credentials' dosyasına KANONİK olarak GERİ YAZILIR (bir sonraki 'domain
# repair' aynı tamper'ı bir daha bulmaz).
#
# Bu test _domain_repair'ı GERÇEKTEN çalıştırır (mysql/systemctl/redis-cli
# stub'lanır — gerçek servise dokunmaz; AppArmor/FPM-pool/redis.acl yazımları
# hardcoded /etc yollarına gittiğinden bu sandbox'ta doğal olarak başarısız
# olur ve zararsızca 'stderr'e uyarı basar — 'set -e' YOK, fonksiyon devam
# eder ve asıl ilgilendiğimiz '.credentials' geri-yazımına ulaşır).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
mysql() { return 0; }
systemctl() { return 0; }
redis-cli() { return 0; }
# GÜVENLİK DENETİMİ EKİ: '_domain_repair' artık hayalet/kalıntı domain
# tespiti yapıyor (bkz. lib/domain.sh:_domain_repair_is_ghost — 'web_<sname>'
# Linux kullanıcısının VARLIĞINA bakar, yoksa 'error' ile reddeder). Bu
# testin fixture'ları ('_setup_and_repair') gerçek bir sistem kullanıcısı
# OLUŞTURMUYOR; bu testin konusu K3 parola-enjeksiyonu savunması, hayalet
# tespiti DEĞİL — 'id' burada NÖTRLENİR (her zaman "kullanıcı var" der) ki
# test domain'leri hayalet sayılıp reddedilmesin. Hayalet tespiti kendi
# testinde (test_domain_repair_reporting.sh) ayrıca doğrulanıyor.
id() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_repair >/dev/null 2>&1; then
    echo "SKIP: _domain_repair tanımlı değil"
    test_summary
    exit $?
fi

# Yardımcı: verilen domain için DB_PASS'i tamper edilmiş değerle kur, repair
# çalıştır, sonucu döndür.
_setup_and_repair() {
    local domain="$1" tampered_db_pass="$2" tampered_redis_pass="$3"
    local base="${WEB_ROOT}/${domain}" sname
    mkdir -p "$base"
    sname=$(safe_name "$domain")
    _domain_write_credentials "$domain" "$base" "web_${sname}" "8.3" \
        "db_${sname}" "usr_${sname}" "$tampered_db_pass" \
        "redis_${sname}" "$tampered_redis_pass" "${sname}:"
    _domain_repair "$domain" >/dev/null 2>&1
}

_is_alnum() { [[ "$1" =~ ^[A-Za-z0-9]+$ ]] && echo evet || echo hayır; }

# ═══ Vaka 1: tek tırnak (SQL enjeksiyonu) ═══
d1="repair-quote.com"
_setup_and_repair "$d1" "x'; DROP TABLE users; --" "temizredis1"
read_credentials "$d1" 2>/dev/null
assert_eq "$(_is_alnum "$DB_PASS")" "evet" "K3: tek-tırnaklı DB_PASS reddedildi, yeni alfanümerik parola üretildi"
assert_not_contains "$DB_PASS" "'" "K3: yeni DB_PASS'te tek tırnak YOK"
assert_not_contains "$DB_PASS" "DROP" "K3: yeni DB_PASS'te SQL payload'ı YOK"

# ═══ Vaka 2: boşluk (Redis ACL token enjeksiyonu) ═══
d2="repair-space.com"
_setup_and_repair "$d2" "temizdb1" "y ~* &* +@all"
read_credentials "$d2" 2>/dev/null
assert_eq "$(_is_alnum "$REDIS_PASS")" "evet" "K3: boşluklu REDIS_PASS reddedildi, yeni alfanümerik parola üretildi"
assert_not_contains "$REDIS_PASS" " " "K3: yeni REDIS_PASS'te boşluk YOK"
assert_not_contains "$REDIS_PASS" "~*" "K3: yeni REDIS_PASS'te ACL joker karakteri '~*' YOK"

# ═══ Vaka 3: '~*' (Redis ACL — tüm anahtarlara erişim) tek başına ═══
d3="repair-glob.com"
_setup_and_repair "$d3" "temizdb2" 'gecerlimigibi~*'
read_credentials "$d3" 2>/dev/null
assert_eq "$(_is_alnum "$REDIS_PASS")" "evet" "K3: '~*' içeren REDIS_PASS reddedildi, yeni alfanümerik parola üretildi"
assert_not_contains "$REDIS_PASS" "~" "K3: yeni REDIS_PASS'te '~' YOK"

# ═══ Vaka 4: noktalı virgül (komut/SQL ayraç enjeksiyonu) ═══
d4="repair-semicolon.com"
_setup_and_repair "$d4" "x; DROP DATABASE mysql;" "temizredis4"
read_credentials "$d4" 2>/dev/null
assert_eq "$(_is_alnum "$DB_PASS")" "evet" "K3: noktalı-virgüllü DB_PASS reddedildi, yeni alfanümerik parola üretildi"
assert_not_contains "$DB_PASS" ";" "K3: yeni DB_PASS'te ';' YOK"

# ═══ Kontrol vakası: GERÇEKTEN alfanümerik (tamper OLMAYAN) parola KORUNUR ═══
# (regresyon: her repair'de KOŞULSUZ yeni parola üretmiyor — yalnız tamper
# şüphesinde)
d5="repair-clean.com"
clean_db="aB3xY9zQ7mK2pL5w"
clean_redis="rD8fG2hJ4kM6nP0q"
_setup_and_repair "$d5" "$clean_db" "$clean_redis"
read_credentials "$d5" 2>/dev/null
assert_eq "$DB_PASS"    "$clean_db"    "K3: geçerli alfanümerik DB_PASS regenerate EDİLMEDİ (yalnız tamper'da üretilir)"
assert_eq "$REDIS_PASS" "$clean_redis" "K3: geçerli alfanümerik REDIS_PASS regenerate EDİLMEDİ"

# ═══ .credentials KANONİK geri yazıldı mı? (dosyadaki değer de değişti, bellek DEĞİL) ═══
DB_PASS="" REDIS_PASS=""
read_credentials "$d1" 2>/dev/null
assert_eq "$(_is_alnum "$DB_PASS")" "evet" "K3: '.credentials' dosyası KANONİK yeni parolayla geri yazıldı (yeniden okundu, aynı sonuç)"

rm -rf "$WEB_ROOT"
test_summary
