#!/bin/bash
# MADDE 1 — REGRESYON (KRİTİK): 'list_all_domains()' (lib/core.sh) yalnızca
# '.credentials' varlığına bakıyordu. HOST'ta ölçüldü (Ubuntu 24.04, üretim,
# v1.0.0→v2.0.0 yükseltmesi): 'designwestgate.art' — CANLI, HTTP 200 dönen
# GERÇEK bir domain — 'web_designwestgate_art' sistem kullanıcısına, FPM
# pool'una, nginx vhost'una sahipti AMA '.credentials' dosyası YOKTU
# (muhtemelen yarıda kesilmiş bir 'domain add'). Sonuç: 'domain list' onu
# göstermiyordu, 'domain repair --all' hayalet sayıp ATLIYORDU, 'security
# audit' HİÇ denetlemiyordu — AppArmor profili hiç oluşturulmamış olduğu
# halde bu durum HİÇBİR YERDE raporlanmıyordu.
#
# DÜZELTME: kapı artık İKİ YOLLU (OR) — '.credentials' VAR OLMASI YETERLİ
# (mevcut davranış KORUNDU) AMA TEK GEÇERLİ YOL DEĞİL: 'web_<sname>' Linux
# sistem kullanıcısının VARLIĞI da domain'i GERÇEK sayar (_domain_repair_
# is_ghost İLE AYNI sinyal/gerekçe — repair bu kullanıcıyı KENDİSİ ASLA
# üretmez, bu yüzden kendi kendini doğrulayan bir döngü OLUŞTURMAZ).
#
# Bu test şunları kilitler:
#   1) [KRİTİK] '.credentials'ı OLMAYAN ama 'web_<sname>' kullanıcısı OLAN
#      bir dizin 'list_all_domains()' tarafından artık GÖRÜNÜR.
#   2) [KRİTİK] '.credentials'ı OLMAYAN VE 'web_<sname>' kullanıcısı da
#      OLMAYAN bir dizin (nginx'in '/var/www/html' taklidi) HÂLÂ ELENİYOR —
#      ikinci kapı hayalet tespitini GEVŞETMEDİ.
#   3) 'domain list': yeni görünür domain PHP sütununda UYDURULMUŞ bir
#      değer DEĞİL, 'bilinmiyor' gösteriyor; KULLANICI sütunu doğru
#      ('web_<sname>' — bu bir tahmin değil, doğrulanmış kimlik); ve
#      operatöre '.credentials' eksikliğinin onarılması gerektiği AYRI bir
#      dipnotla AÇIKÇA söyleniyor.
#   4) 'domain repair --all': yeni görünür domain hayalet SAYILMIYOR (ghost
#      raporuna DÜŞMÜYOR), fiilen onarım denemesine giriyor (repair_total'e
#      dahil).
#   5) Yan bulgu — REGRESYON İÇİNDE REGRESYON: ikinci kapı açıldıktan SONRA,
#      hardened+'.credentials'sız bir domain 'read_credentials' (core.sh)
#      üzerinden 'error()' (gerçek 'exit') tetikleyebiliyordu; bu çıplak
#      (subshell'siz) bir çağrıda TÜM '--all' sürecini SESSİZCE yarıda
#      kesiyordu. Alt-kabuk düzeltmesi bunu engelliyor: tek domain
#      "başarısız" sayılır, döngü KESİLMEDEN devam eder.
#
# Test-seam'ler: WEB_ROOT / SRVCTL_STATE_DIR / SRVCTL_FPM_DIR /
# SRVCTL_SYSTEMD_DIR / SRVCTL_PHP_POOL_DIR — diğer domain.sh testleriyle AYNI
# desen. 'id' mock'u CASE tabanlı (bash 3.2/macOS varsayılan /bin/bash
# 'declare -A' desteklemez — bkz. tests/test_resource_profile_load.sh AYNI
# kısıt/gerekçe): yalnız İSMİ AÇIKÇA eşleşen kullanıcılar için 0 döner.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
mysql() { return 0; }
redis-cli() { return 0; }
systemctl() { return 0; }

export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/domain.sh"

echo "== list_all_domains(): İKİ-YOLLU kapı =="

# ─── Fixture A: designwestgate.art benzeri — '.credentials' YOK, web
# kullanıcısı VAR (add yarıda kesilmiş gerçek bir domain). ---
dReal="designwestgate-like.art"
snameReal=$(safe_name "$dReal")
mkdir -p "${WEB_ROOT}/${dReal}"

# ─── Fixture B: nginx'in '/var/www/html' taklidi — NE '.credentials' NE
# web kullanıcısı VAR (TEMİZ hayalet). Ad KASITLI OLARAK 'html' DEĞİL:
# 'domain list'in kendi sabit örnek metninde ("ör. nginx'in varsayılan
# '/var/www/html' dizini") zaten 'html' geçtiğinden 'html' adını kullanmak
# assert_not_contains'ı YANLIŞ POZİTİF (metin çakışması) yüzünden kırardı.
dGhost="faux-nginx-default.invalid"
mkdir -p "${WEB_ROOT}/${dGhost}"

# ─── Fixture C: normal/sağlıklı bir domain — '.credentials' VAR (kontrol grubu). ---
dNormal="normal-domain.test"
snameNormal=$(safe_name "$dNormal")
mkdir -p "${WEB_ROOT}/${dNormal}"
_domain_write_credentials "$dNormal" "${WEB_ROOT}/${dNormal}" "web_${snameNormal}" "8.3" \
    "db_${snameNormal}" "usr_${snameNormal}" "cleanpassdb1234" \
    "redis_${snameNormal}" "cleanpassredis1234" "${snameNormal}:"

# 'id' mock: yalnız dReal VE dNormal'in web kullanıcıları "var" (0) döner —
# dGhost'un ('web_html') kullanıcısı YOK (1). NOT: dNormal '.credentials'
# ile ZATEN görünür olmalı (birinci kapı TEK BAŞINA yeterli, OR mantığı) —
# yine de _domain_repair_is_ghost (repair --all içinde) HER domain için 'id'
# çağırdığından dNormal'in kullanıcısı da "var" işaretlendi (aksi halde
# repair --all bölümünde yanlışlıkla hayalet sayılırdı — bu test o katmanı
# DEĞİL, list_all_domains/domain list davranışını ölçüyor).
id() {
    case "$1" in
        "web_${snameReal}")   return 0 ;;
        "web_${snameNormal}") return 0 ;;
        *)                    return 1 ;;
    esac
}

lad_out="$(list_all_domains)"

assert_contains "$lad_out" "$dReal" \
    "[KRİTİK] '.credentials'sız ama web kullanıcısı VAR olan GERÇEK domain artık GÖRÜNÜR"
assert_not_contains "$lad_out" "$dGhost" \
    "[KRİTİK] ne '.credentials' ne web kullanıcısı olan TEMİZ hayalet HÂLÂ ELENİYOR"
assert_contains "$lad_out" "$dNormal" \
    "'.credentials'lı normal domain (birinci kapı TEK BAŞINA yeterli) GÖRÜNÜYOR"

lad_count=$(echo "$lad_out" | grep -c . || true)
assert_eq "$lad_count" "2" "yalnız 2 GERÇEK domain görünüyor (hayalet dahil değil)"

echo ""
echo "== domain list: PHP sütunu UYDURULMUYOR + operatör bilgilendiriliyor =="

list_out="$(_domain_list 2>&1)"

assert_contains "$list_out" "$dReal" "'domain list' yeni görünür domain'i GÖSTERİYOR"
assert_not_contains "$list_out" "$dGhost" "'domain list' hayalet 'html' dizinini HÂLÂ GÖSTERMİYOR"

# PHP sütunu: UYDURULMUŞ bir sürüm (ör. DEFAULT_PHP_VERSION) DEĞİL, 'bilinmiyor'.
# NOT: yalnız TABLO SATIRINI yakala — aşağıdaki '.credentials' eksikliği
# dipnotu da domain adını (VE 'bilinmiyor' kelimesini) İÇERDİĞİNDEN düz
# 'grep -F "$dReal"' YANLIŞLIKLA dipnot satırını da eşleştirip PHP sütununun
# gerçekten 'bilinmiyor' bastığını DEĞİL, dipnotun varlığını doğrulardı
# (mutasyon testiyle yakalanan bir kendi-kendini-kandırma). Tablo satırı
# '_domain_list' içinde 'printf "  %-30s ..."' ile İKİ BOŞLUKLA başlar; warn()
# satırları renk kodu/ikonla başlar — bu yüzden ÇAPA'lı regex kullanılıyor.
real_row_line=$(echo "$list_out" | grep -E "^  ${dReal}[[:space:]]")
assert_contains "$real_row_line" "bilinmiyor" \
    "[KRİTİK] '.credentials'sız domain için PHP sütunu 'bilinmiyor' gösteriyor (UYDURMA YOK)"
# KULLANICI sütunu doğru — bu bir tahmin değil, safe_name'den güvenilir türetim.
assert_contains "$real_row_line" "web_${snameReal}" \
    "KULLANICI sütunu doğru gösteriliyor (web_${snameReal} — fabrikasyon değil, doğrulanmış kimlik)"

# Operatör bilgilendirmesi: '.credentials' eksikliği AÇIKÇA raporlanıyor, sessizce geçilmiyor.
assert_contains "$list_out" "'.credentials' dosyasına SAHİP DEĞİL" \
    "operatör '.credentials' eksikliği konusunda AÇIKÇA uyarılıyor"
assert_contains "$list_out" "$dReal" "eksik-credentials dipnotu domain adını İÇERİYOR"
assert_contains "$list_out" "domain repair" \
    "operatöre onarım için AÇIKÇA 'domain repair' ÖNERİLİYOR"

echo ""
echo "== domain repair --all: yeni görünür domain HAYALET SAYILMIYOR =="

outAll="$(_domain_repair "--all" 2>&1)"

assert_not_contains "$outAll" "GÖRÜNMÜYOR" \
    "[KRİTİK] '.credentials'sız ama GERÇEK olan domain hayalet raporuna DÜŞMÜYOR"
# NOT: 'faux-nginx-default.invalid' list_all_domains() tarafından ZATEN
# elendiğinden (bkz. yukarısı) '--all' döngüsüne hiç girmiyor — bu yüzden
# 'ghost_domains' burada BOŞ kalır ve mesaj "Tüm GERÇEK domainler onarıldı"
# DEĞİL, sıradan "Tüm domainler onarıldı" olur (hayalet raporlama katmanı
# yalnız GÖRÜNÜR ama sonradan hayalet çıkan domainler için devreye girer).
assert_contains "$outAll" "Tüm domainler onarıldı (2/2)" \
    "[KRİTİK] repair_total 2'yi sayıyor — yeni görünür domain FİİLEN onarım denemesine dahil edildi"

# İki domain de FİİLEN işlendi mi? (paylaşılan pool.d'ye pool conf yazıldıysa
# onarım gerçekten çalıştırılmış demektir.)
assert_ok test -f "${SRVCTL_PHP_POOL_DIR}/${snameReal}.conf"
assert_ok test -f "${SRVCTL_PHP_POOL_DIR}/${snameNormal}.conf"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

echo ""
echo "== YAN BULGU: hardened + '.credentials'sız domain '--all' sürecini ARTIK ÇÖKERTMİYOR =="

export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"

# Nötr mock — bu bölümün konusu hayalet tespiti DEĞİL (ikisi de gerçek kullanıcıya sahip).
id() { return 0; }

# 'a-' önekiyle alfabetik olarak İLK sırada — döngü kesilirse 'z-' asla işlenmez.
dHardened="a-hardened-nocreds.test"
mkdir -p "${WEB_ROOT}/${dHardened}"
mkdir -p "${SRVCTL_STATE_DIR}/${dHardened}"
touch "${SRVCTL_STATE_DIR}/${dHardened}/hardened"

dAfter="z-after.test"
snameAfter=$(safe_name "$dAfter")
mkdir -p "${WEB_ROOT}/${dAfter}"
_domain_write_credentials "$dAfter" "${WEB_ROOT}/${dAfter}" "web_${snameAfter}" "8.3" \
    "db_${snameAfter}" "usr_${snameAfter}" "cleanpassdb1234" \
    "redis_${snameAfter}" "cleanpassredis1234" "${snameAfter}:"

outCrash="$(_domain_repair "--all" 2>&1)"; rcCrash=$?

assert_eq "$([[ "$rcCrash" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "hardened+'.credentials'sız domain '--all' sonucunu SIFIRDAN FARKLI yapıyor (dürüst raporlama)"
assert_contains "$outCrash" "TAMAMLANAMADI" \
    "'--all' dürüstçe 'TAMAMLANAMADI' raporluyor (crash değil, kontrollü başarısızlık)"
assert_contains "$outCrash" "$dHardened" \
    "başarısız domain adı sonuç mesajında GEÇİYOR"
# [KRİTİK] İLK domain çökse/başarısız olsa bile SONRAKİ domain (dAfter) FİİLEN
# işlenmiş olmalı (pool conf yazıldıysa süreç YARIDA KESİLMEMİŞ demektir).
assert_ok test -f "${SRVCTL_PHP_POOL_DIR}/${snameAfter}.conf"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"

test_summary
