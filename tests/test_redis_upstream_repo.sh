#!/bin/bash
# _install_redis_upstream_repo / _redis_upstream_repo_codename (lib/init.sh)
#
# NEDEN VAR: kullanıcı kararı — Redis pub/sub kanal izolasyonu HER
# desteklenen platformda (Ubuntu 22.04 VE 24.04) çalışmalı. Ubuntu 24.04
# dağıtım paketi zaten redis-server 7.0.15 verir (6.2+); Ubuntu 22.04 ise
# 6.0.16 (6.2 ALTI) verir — 6.2 öncesi Redis'te pub/sub kanal ACL'i
# ('resetchannels'/'&pattern') parser'da HİÇ TANIMLI DEĞİL (bkz. core.sh
# _redis_channel_isolation_mode başlığı). '_install_redis_upstream_repo'
# BU YÜZDEN Ubuntu 22.04'te packages.redis.io resmi deposundan 7.x'e
# yükseltmeyi DENER; Ubuntu 24.04'te (zaten 6.2+) apt'a HİÇ dokunmadan
# no-op'tur.
#
# Bu test GERÇEK ağa/apt'a/gpg'ye ASLA dokunmaz: curl/gpg/apt-get/_apt_install
# hepsi stub'lanır (test_apt_install_required.sh'taki '_apt_install stub'lama
# deseniyle AYNI yaklaşım); dosya yazma hedefleri (keyring/sources/preferences
# dizinleri) SRVCTL_APT_KEYRING_DIR/SRVCTL_APT_SOURCES_DIR/SRVCTL_APT_PREFS_DIR
# test-seam'leri ile bir tmp dizine yönlendirilir — gerçek /etc/apt'a ASLA
# yazılmaz.
#
# KAPSAM SINIRI: '_install_redis' fonksiyonunun KENDİSİ (redis.conf/ACL/
# systemctl restart/chown redis:redis) macOS'ta gerçek anlamda unit test
# EDİLEMEZ (gerçek /etc/redis, gerçek 'redis' sistem kullanıcısı, gerçek
# systemd gerektirir) — bu, mevcut proje sınırıyla AYNIDIR (bkz.
# test_apt_install_required.sh'ın da yalnız _apt_install_required'ı test
# edip _install_nginx/_install_mariadb gibi tam kurulum fonksiyonlarına
# GİRMEMESİ). Bu dosya YALNIZ bu turda EKLENEN iki saf/yarı-saf fonksiyonu
# hedefler; '_install_redis'in ACL karar bloğundaki yeni "pub/sub kanal
# izolasyonu AKTİF" success mesajı HOST'ta doğrulanmalı (bkz. rapor).
#
# EK BULGULAR (HOST doğrulaması, gerçek Ubuntu 22.04 VM — coordinator, İKİ TUR):
#
# TUR 1: packages.redis.io depoSU yalnız 7.x SUNMUYOR — 8.x (ve
# memtier-benchmark gibi redis-DIŞI paketler) de sunuyor; ilk pinning
# tasarımı (origin-only, 'Package: redis*' + 'Pin: origin ...' + Priority
# 600, SÜRÜM KISITI YOK) candidate'ı GERÇEKTEN '6:8.10.0-1rl2~jammy1'ye
# (majör 8) çekiyordu — ki kullanıcı onayı AÇIKÇA Redis 7 üzerineydi.
#
# TUR 2 (TUR 1'in "düzeltmesi" de HATALIYDI): 'Pin: version *:7.*' deseni
# GERÇEK apt'ta HİÇBİR sürümle eşleşmiyordu — apt'ın 'version' pin'i BAŞTA
# joker DESTEKLEMEZ, yalnız SABİT bir önek + sonda '*' kabul eder. Sonuç:
# redis-server candidate'ı DEĞİŞMİYORDU (dağıtımın 6.0.16'sında KALIYORDU),
# 7.x girdilerinin TÜMÜ de -1 alıyordu — yani "majör 7'ye kilitleme" hiç
# ÇALIŞMIYORDU, sessizce hiçbir yükseltme olmuyordu. Doğru desen upstream'in
# GÜNCEL epoch'unu SABİT yazan '6:7.*'tir (GERÇEK VM'de tam doğrulandı:
# redis-server/redis-tools candidate '6:7.4.10-...', 8.x'in 32 girdisi de
# -1, memtier-benchmark/redis-stack-server engelli). Bu turda AYRICA ilk
# denemenin YANLIŞ "spesifik Package glob'u kazanır" varsayımı da GERÇEK
# ölçümle düzeltildi: apt'ın gerçek modeli "koşulu TUTAN TÜM stanza'lar
# arasında EN YÜKSEK (max) öncelik" — specificity DEĞİL (bkz. lib/init.sh
# başlık yorumu madde 2/3). Aşağıdaki "REGRESYON KAPISI" ve "majör kilidi"
# blokları HER İKİ hatayı da (majör 8 sızıntısı VE sessiz-hiç-yükseltmeme)
# bir daha SESSİZCE geri gelemeyecek şekilde, APT'nin GERÇEK önek-eşleştirme
# semantiğini simüle ederek kilitler (bash glob'un aksine — bkz. aşağıdaki
# '_apt_version_pin_match' yorumu, bir önceki turun test-kırılganlığı burada
# açıklanıyor).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/init.sh"

if ! declare -F _install_redis_upstream_repo >/dev/null 2>&1; then
    echo "  SKIP: _install_redis_upstream_repo henüz yok"
    rm -rf "$WEB_ROOT"
    test_summary
    exit 0
fi

# ─── Ağa/host'a ASLA dokunma: varsayılan olarak curl/gpg/apt-get
#     ÇAĞRILIRSA görünür biçimde patlasın (senaryolar kendi ihtiyacına göre
#     override eder) ───
curl() { echo "TEST HATASI: gerçek curl çağrıldı" >&2; return 99; }
gpg()  { echo "TEST HATASI: gerçek gpg çağrıldı" >&2; return 99; }
apt-get() { echo "TEST HATASI: gerçek apt-get çağrıldı" >&2; return 99; }

APT_ROOT="$(mktemp -d)"
export SRVCTL_APT_KEYRING_DIR="${APT_ROOT}/keyrings"
export SRVCTL_APT_SOURCES_DIR="${APT_ROOT}/sources.list.d"
export SRVCTL_APT_PREFS_DIR="${APT_ROOT}/preferences.d"

reset_apt_dirs() {
    rm -rf "$SRVCTL_APT_KEYRING_DIR" "$SRVCTL_APT_SOURCES_DIR" "$SRVCTL_APT_PREFS_DIR"
    mkdir -p "$SRVCTL_APT_SOURCES_DIR" "$SRVCTL_APT_PREFS_DIR"
}

OS_RELEASE_JAMMY="$(mktemp)"
cat > "$OS_RELEASE_JAMMY" << 'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
ID=ubuntu
EOF

OS_RELEASE_NO_CODENAME="$(mktemp)"
cat > "$OS_RELEASE_NO_CODENAME" << 'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
ID=ubuntu
EOF

# ═══════════════════════════════════════════════
#  _redis_upstream_repo_codename — saf, dosya-tabanlı
# ═══════════════════════════════════════════════
SRVCTL_OS_RELEASE_FILE="$OS_RELEASE_JAMMY" \
    assert_eq "$(SRVCTL_OS_RELEASE_FILE="$OS_RELEASE_JAMMY" _redis_upstream_repo_codename)" "jammy" \
    "codename: VERSION_CODENAME=jammy doğru ayrıştırılıyor"
assert_eq "$(SRVCTL_OS_RELEASE_FILE="$OS_RELEASE_NO_CODENAME" _redis_upstream_repo_codename)" "" \
    "codename: VERSION_CODENAME yoksa boş döner (fail-closed çağıran tarafta)"
assert_eq "$(SRVCTL_OS_RELEASE_FILE="/nonexistent/os-release-xyz" _redis_upstream_repo_codename)" "" \
    "codename: dosya yoksa boş döner (exit YOK — [[ -r ]] guard)"

# ═══════════════════════════════════════════════
#  1) Zaten 6.2+ (Ubuntu 24.04 = 7.0.15) — apt'a HİÇ dokunma
# ═══════════════════════════════════════════════
reset_apt_dirs
export SRVCTL_OS_RELEASE_FILE="$OS_RELEASE_JAMMY"
_redis_version_pair() { echo "7 0"; }
assert_ok _install_redis_upstream_repo
assert_eq "$([[ -d "$SRVCTL_APT_KEYRING_DIR" ]] && echo var || echo yok)" "yok" \
    "zaten 6.2+: keyring dizini bile OLUŞTURULMADI (apt'a hiç dokunulmadı)"
assert_eq "$(ls -A "$SRVCTL_APT_SOURCES_DIR" 2>/dev/null)" "" \
    "zaten 6.2+: sources.list.d'ye dosya YAZILMADI"
assert_eq "$(ls -A "$SRVCTL_APT_PREFS_DIR" 2>/dev/null)" "" \
    "zaten 6.2+: preferences.d'ye dosya YAZILMADI"

# major=6 minor=2 (tam sınır) da 'supported' olmalı — aynı no-op davranışı
reset_apt_dirs
_redis_version_pair() { echo "6 2"; }
assert_ok _install_redis_upstream_repo
assert_eq "$([[ -d "$SRVCTL_APT_KEYRING_DIR" ]] && echo var || echo yok)" "yok" \
    "6.2 (tam sınır): supported sayılır, apt'a dokunulmadı"

# ═══════════════════════════════════════════════
#  2) 6.0 (jammy) + codename tespit edilemiyor — fail-safe, dosya YOK
# ═══════════════════════════════════════════════
reset_apt_dirs
export SRVCTL_OS_RELEASE_FILE="$OS_RELEASE_NO_CODENAME"
_redis_version_pair() { echo "6 0"; }
assert_fail _install_redis_upstream_repo
assert_eq "$([[ -d "$SRVCTL_APT_KEYRING_DIR" ]] && echo var || echo yok)" "yok" \
    "codename yok: keyring dizinine hiç DOKUNULMADI"

# ═══════════════════════════════════════════════
#  3) 6.0 (jammy) + gpg yok — fail-safe, dosya YOK
# ═══════════════════════════════════════════════
reset_apt_dirs
export SRVCTL_OS_RELEASE_FILE="$OS_RELEASE_JAMMY"
export SRVCTL_GPG_BIN="srvctl-test-nonexistent-gpg-xyz"
assert_fail _install_redis_upstream_repo
assert_eq "$([[ -d "$SRVCTL_APT_KEYRING_DIR" ]] && echo var || echo yok)" "yok" \
    "gpg yok: keyring dizinine hiç DOKUNULMADI"
unset SRVCTL_GPG_BIN

# ═══════════════════════════════════════════════
#  4) 6.0 (jammy) + GPG anahtarı indirilemiyor (curl/gpg başarısız)
#     → rollback: apt-get update'e HİÇ ulaşılmadan geri dönülür, hiçbir
#     dosya kalıcı konumda kalmaz.
# ═══════════════════════════════════════════════
reset_apt_dirs
curl() { return 1; }   # ağ hatası simülasyonu
gpg() { cat > /dev/null; return 1; }
assert_fail _install_redis_upstream_repo
assert_eq "$(ls -A "$SRVCTL_APT_KEYRING_DIR" 2>/dev/null)" "" \
    "GPG anahtarı başarısız: keyring dizininde YARIM/kalıcı dosya YOK"
assert_eq "$(ls -A "$SRVCTL_APT_SOURCES_DIR" 2>/dev/null)" "" \
    "GPG anahtarı başarısız: sources.list.d'ye HİÇ yazılmadı"

# ═══════════════════════════════════════════════
#  5) 6.0 (jammy) + tam BAŞARI: anahtar+sources+pin yazılıyor, apt-get
#     update ve _apt_install çağrılıyor
# ═══════════════════════════════════════════════
reset_apt_dirs
curl() { echo "FAKE-GPG-KEY-BYTES"; }
gpg() { cat; }   # 'dearmor' stub: stdin'i olduğu gibi geçirir
_apt_install_seen=""
_apt_install() { _apt_install_seen="$*"; return 0; }
apt-get() { return 0; }   # 'apt-get update' başarılı
assert_ok _install_redis_upstream_repo

keyring_file="${SRVCTL_APT_KEYRING_DIR}/redis.gpg"
sources_file="${SRVCTL_APT_SOURCES_DIR}/redis.list"
pin_file="${SRVCTL_APT_PREFS_DIR}/99-srvctl-redis.pref"

assert_eq "$([[ -f "$keyring_file" ]] && echo var || echo yok)" "var" \
    "başarı: keyring dosyası oluşturuldu"
assert_eq "$(cat "$keyring_file" 2>/dev/null)" "FAKE-GPG-KEY-BYTES" \
    "başarı: keyring dosyası curl|gpg çıktısını İÇERİYOR"
assert_eq "$(_stat_mode "$keyring_file")" "644" \
    "başarı: keyring dosyası 0644 (parola/sır İÇERMEZ — apt/_apt okuyabilsin)"

assert_eq "$([[ -f "$sources_file" ]] && echo var || echo yok)" "var" \
    "başarı: sources.list.d/redis.list oluşturuldu"
sources_content="$(cat "$sources_file" 2>/dev/null)"
assert_contains "$sources_content" "signed-by=${keyring_file}" \
    "sources: 'signed-by=' YALNIZ bu depoya ait anahtara bağlanıyor"
assert_contains "$sources_content" "https://packages.redis.io/deb jammy main" \
    "sources: doğru URL + codename (jammy) + suite"
assert_eq "$(_stat_mode "$sources_file")" "644" "sources dosyası 0644"

pin_content="$(cat "$pin_file" 2>/dev/null)"
assert_contains "$pin_content" "Pin: origin packages.redis.io" \
    "pin: origin packages.redis.io ile eşleniyor (fetch-host pinning)"
assert_contains "$pin_content" "Pin-Priority: -1" \
    "pin: TÜM diğer paketler (Package: *) negatif öncelikle ENGELLENİYOR"
assert_contains "$pin_content" "Package: redis-server redis-tools" \
    "pin: YALNIZ kurduğumuz iki paket adı yüksek öncelik alabiliyor"
assert_contains "$pin_content" "Pin: version 6:7.*" \
    "pin: sürüm kısıtı '6:7.*' ile MAJÖR 7'ye kilitleniyor (8.x/9.x DEĞİL)"
assert_contains "$pin_content" "Pin-Priority: 600" \
    "pin: redis-server/redis-tools 7.x sürümleri dağıtım varsayılanından (500) yüksek öncelikli"
assert_eq "$(_stat_mode "$pin_file")" "644" "pin dosyası 0644"

# ─── REGRESYON KAPISI: origin+versiyon AYNI stanza'da BİRLEŞTİRİLMEMELİ
#     (apt_preferences(5) buna izin vermiyor) VE 'redis*' GLOB'u sürüm
#     kısıtı OLMADAN kullanılmamalı (bu, coordinator'ın gerçek VM'de bulduğu
#     "candidate 8.10.0" hatasının TAM KAYNAĞIYDI) ───
assert_eq "$(grep -c '^Pin: origin packages.redis.io$' <<< "$pin_content")" "1" \
    "pin: 'Pin: origin ...' TAM OLARAK bir kez geçiyor (yalnız geniş engelleme stanza'sında — redis-specific stanza'da origin YOK)"
assert_eq "$(grep -c '^Pin: version 6:7\.\*$' <<< "$pin_content")" "1" \
    "pin: 'Pin: version 6:7.*' TAM OLARAK bir kez geçiyor"
assert_not_contains "$pin_content" "Package: redis*" \
    "pin: eski (majör-kilitsiz) 'Package: redis*' glob'u YOK — düzeltme kalıcı"
assert_not_contains "$pin_content" "*:7.*" \
    "pin: İLK (BOZUK) '*:7.*' deseni YOK — GERÇEK apt'ta HİÇBİR sürümle eşleşmiyordu (coordinator ÖLÇTÜ), düzeltme kalıcı"

# ─── Majör 7 kilidinin GERÇEK VM'de gözlemlenen sürüm string'leriyle
#     eşleştiğini APT'NİN GERÇEK 'Pin: version' semantiğiyle doğrula.
#
#     ÖNEMLİ (bir önceki turun HATASI): apt_preferences(5)'in 'version'
#     pin'i bash/fnmatch tarzı SERBEST glob DEĞİLDİR — BAŞTA joker
#     DESTEKLEMEZ, yalnızca sonda '*' varsa SABİT bir ÖNEK karşılaştırması
#     yapar (apt kaynağında pkgCache::VerIterator ile literal prefix
#     karşılaştırması — GERÇEK Ubuntu 22.04 VM'de ÖLÇÜLEREK doğrulandı: bkz.
#     lib/init.sh başlık yorumu madde 3). Önceki turda burada bash'ın KENDİ
#     '[[ == $pattern ]]' glob'u kullanılmıştı ('*' HER YERDE joker) — bu,
#     '*:7.*' desenini '6:7.4.10-...' ile YANLIŞLIKLA eşleştiriyordu ve test
#     YEŞİL kalırken GERÇEK apt'ta desen HİÇBİR ŞEYLE eşleşmiyordu (test
#     kırık kodu "doğru" diye kilitlemişti). Aşağıdaki '_apt_version_pin_match'
#     BİLEREK bash glob'u KULLANMAZ — 'case' içinde $prefix TIRNAKLI
#     geçirilir (yalnız LİTERAL karşılaştırma, prefix'in İÇİNDEKİ '*' varsa
#     bile o da literal kalır), sonuna YALNIZ TEK bir gerçek wildcard eklenir
#     — APT'nin "sabit önek + serbest kalan" davranışının SADIK simülasyonu.
_apt_version_pin_match() {
    local candidate_version="$1" pin_pattern="$2" prefix
    prefix="${pin_pattern%\*}"   # sondaki TEK '*' düşürülür (APT: sonek joker)
    case "$candidate_version" in
        "$prefix"*) echo evet ;;   # "$prefix" TIRNAKLI -> literal, glob YOK
        *)          echo hayir ;;
    esac
}

pin_version_pattern="$(awk '/^Package: redis-server redis-tools$/{getline; print $3}' <<< "$pin_content")"
assert_eq "$pin_version_pattern" "6:7.*" "pin: sürüm deseni tam olarak '6:7.*' okunuyor"

# GERÇEK VM candidate string'leri (coordinator ölçümü):
assert_eq "$(_apt_version_pin_match '6:7.4.10-1rl1~jammy1' "$pin_version_pattern")" "evet" \
    "majör kilidi (APT önek semantiği): GERÇEK 7.x aday ('6:7.4.10-1rl1~jammy1') EŞLEŞİYOR"
assert_eq "$(_apt_version_pin_match '6:8.10.0-1rl2~jammy1' "$pin_version_pattern")" "hayir" \
    "majör kilidi (APT önek semantiği): GERÇEK 8.x aday ('6:8.10.0-1rl2~jammy1') EŞLEŞMİYOR (majör sıçrama engelleniyor)"
assert_eq "$(_apt_version_pin_match '6:7.0.15-1rl1~jammy1' "$pin_version_pattern")" "evet" \
    "majör kilidi (APT önek semantiği): farklı bir 7.x YAMA sürümü de eşleşiyor (patch güncellemeleri akmaya devam ediyor)"

# REGRESYON KANITI: İLK (BOZUK) '*:7.*' deseni APT'nin GERÇEK önek
# semantiğiyle (baştaki '*' LİTERAL karakter sayılır, joker DEĞİL) hiçbir
# GERÇEK aday sürümüyle eşleşmiyordu — coordinator'ın "candidate 6.0.16'da
# kaldı, 7.x girdilerinin TÜMÜ -1 aldı" ölçümünün TAM AÇIKLAMASI budur.
assert_eq "$(_apt_version_pin_match '6:7.4.10-1rl1~jammy1' '*:7.*')" "hayir" \
    "REGRESYON KANITI: BOZUK '*:7.*' deseni APT önek semantiğiyle GERÇEK bir 7.x adayla BİLE eşleşmiyor (bash glob'un aksine)"

assert_eq "$_apt_install_seen" "redis-server redis-tools" \
    "başarı: _apt_install TAM OLARAK 'redis-server redis-tools' ile çağrıldı (pin dosyasındaki isimlerle BİREBİR aynı)"

# İdempotent: aynı senaryo İKİNCİ kez de hatasız çalışmalı (dosyalar
# append değil, ÜZERİNE yazılır)
assert_ok _install_redis_upstream_repo
assert_eq "$(cat "$keyring_file" 2>/dev/null)" "FAKE-GPG-KEY-BYTES" \
    "idempotent: ikinci çalıştırmada da keyring içeriği doğru (append değil overwrite)"

# ═══════════════════════════════════════════════
#  6) 6.0 (jammy) + apt-get update BAŞARISIZ → rollback: 3 dosya da
#     GERİ ALINIYOR (bozuk depo sistemde bırakılmıyor)
# ═══════════════════════════════════════════════
reset_apt_dirs
curl() { echo "FAKE-GPG-KEY-BYTES"; }
gpg() { cat; }
apt-get() { return 1; }   # 'apt-get update' başarısız (ör. codename desteklenmiyor)
assert_fail _install_redis_upstream_repo
assert_eq "$([[ -f "${SRVCTL_APT_KEYRING_DIR}/redis.gpg" ]] && echo var || echo yok)" "yok" \
    "apt-get update başarısız: keyring dosyası GERİ ALINDI"
assert_eq "$([[ -f "${SRVCTL_APT_SOURCES_DIR}/redis.list" ]] && echo var || echo yok)" "yok" \
    "apt-get update başarısız: sources.list.d/redis.list GERİ ALINDI"
assert_eq "$([[ -f "${SRVCTL_APT_PREFS_DIR}/99-srvctl-redis.pref" ]] && echo var || echo yok)" "yok" \
    "apt-get update başarısız: preferences.d dosyası GERİ ALINDI"

# ═══════════════════════════════════════════════
#  7) 6.0 (jammy) + apt-get update BAŞARILI ama 'redis-server' KURULAMADI
#     → depo KALIR (zaten doğrulanmış/güvenilir), yalnız kurulum başarısız
# ═══════════════════════════════════════════════
reset_apt_dirs
curl() { echo "FAKE-GPG-KEY-BYTES"; }
gpg() { cat; }
apt-get() { return 0; }
_apt_install() { return 1; }   # ör. tutulu paket / disk dolu
assert_fail _install_redis_upstream_repo
assert_eq "$([[ -f "${SRVCTL_APT_KEYRING_DIR}/redis.gpg" ]] && echo var || echo yok)" "var" \
    "_apt_install başarısız: keyring KORUNUYOR (repo zaten apt-get update ile doğrulanmıştı)"
assert_eq "$([[ -f "${SRVCTL_APT_SOURCES_DIR}/redis.list" ]] && echo var || echo yok)" "var" \
    "_apt_install başarısız: sources.list.d/redis.list KORUNUYOR"

rm -rf "$WEB_ROOT" "$APT_ROOT" "$OS_RELEASE_JAMMY" "$OS_RELEASE_NO_CODENAME"
test_summary
