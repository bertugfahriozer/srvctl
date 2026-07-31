#!/bin/bash
# KUSUR 3 regresyon testi (designwestgate.art HOST bulgusu): CANLI, gerçek
# bir domain (web_<sname> sistem kullanıcısı var, FPM/nginx/chroot/seccomp
# aktif) ama '.credentials' hiç yazılmamış (eski bir srvctl sürümünde
# eklenmiş) olduğunda 'domain repair' ve 'security harden-fpm --apply'
# read_credentials'ın fail-closed tamper reddi yüzünden ÇALIŞAMIYORDU —
# audit FAIL diyordu ama düzeltme komutu da çalışmıyordu (çıkmaz).
#
# Bu test dört şeyi kilitler:
#   1) '.credentials' HİÇ YOKSA gözlemlenen durumdan (PHP sürümü FPM unit'ten,
#      kimlikler safe_name'den) yeniden üretilir.
#   2) VAR OLAN bir '.credentials'a ASLA dokunulmaz (byte-byte MUTASYON testi).
#   3) DB_NAME/DB_USER/DB_PASS/REDIS_USER/REDIS_PASS/REDIS_PREFIX asla
#      UYDURULMAZ — hepsi boş kalır.
#   4) Hayalet bir dizine (web_<sname> yok) credentials ÜRETİLMEZ.
# Ayrıca: bu kurtarma sayesinde 'domain repair' ve 'security harden-fpm
# --apply' artık '.credentials'sız hardened bir domainde ÇALIŞABİLİYOR
# (uçtan uca, gerçek üretim komutlarıyla).
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
source "${REPO_ROOT}/lib/security.sh"

echo "== 1) '.credentials' eksik + GERÇEK domain (web kullanıcısı var) → yeniden üretilir =="
d="designwestgate.art"
sname=$(safe_name "$d")
mkdir -p "${WEB_ROOT}/${d}"
# GERÇEK bir 'id web_<sname>' çağrısını taklit et — yalnız BU kullanıcı için.
id() { [[ "$1" == "web_${sname}" ]]; }
# İzole FPM unit'i "önceden kurulmuş" gibi davransın (PHP sürümü BURADAN
# gözlemlenmeli, '.credentials'tan DEĞİL — o zaten yok).
mkdir -p "${WEB_ROOT}/${d}/public_html"
cat > "${SRVCTL_SYSTEMD_DIR}/srvctl-fpm-${sname}.service" <<'EOF'
[Service]
ExecStart=/usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /etc/srvctl/fpm/designwestgate_art.conf
EOF

creds_file="${WEB_ROOT}/${d}/.credentials"
assert_eq "$(test -e "$creds_file" && echo VAR || echo YOK)" "YOK" "ön koşul: '.credentials' gerçekten yok"

_domain_ensure_credentials "$d" 2>/dev/null

assert_eq "$(test -f "$creds_file" && echo VAR || echo YOK)" "VAR" "'.credentials' yeniden üretildi"
assert_eq "$(_stat_mode "$creds_file" 2>/dev/null)" "600" "yeniden üretilen dosya 600 modunda"

DOMAIN="" SAFE_NAME="" WEB_USER="" PHP_VERSION=""
DB_NAME="" DB_USER="" DB_PASS=""
REDIS_USER="" REDIS_PASS="" REDIS_PREFIX=""
# 'source <(...)' KULLANILMADI: read_kv_file (core.sh) — projenin KENDİ katı
# key=value okuyucusu, source/eval YOK — kullanılıyor (ayrıca macOS'un eski
# bash 3.2'sinde process-substitution + 'source' bazı ortamlarda değişkenleri
# SESSİZCE set ETMİYOR; bu Ubuntu hedefinde geçerli olmayan bir dev-makine
# tuhaflığı, ama read_kv_file zaten doğru/taşınabilir araç).
read_kv_file "$creds_file" DOMAIN SAFE_NAME WEB_USER PHP_VERSION \
    DB_NAME DB_USER DB_PASS REDIS_USER REDIS_PASS REDIS_PREFIX
assert_eq "${DOMAIN:-}"      "$d"              "DOMAIN doğru"
assert_eq "${SAFE_NAME:-}"   "$sname"          "SAFE_NAME safe_name'den türetildi"
assert_eq "${WEB_USER:-}"    "web_${sname}"    "WEB_USER safe_name'den türetildi"
assert_eq "${PHP_VERSION:-}" "8.3"             "PHP_VERSION FPM unit'in ExecStart'ından doğru tespit edildi"
assert_eq "${DB_NAME:-}"     "" "KUSUR 3: DB_NAME UYDURULMADI — boş"
assert_eq "${DB_USER:-}"     "" "KUSUR 3: DB_USER UYDURULMADI — boş"
assert_eq "${DB_PASS:-}"     "" "KUSUR 3: DB_PASS UYDURULMADI — boş"
assert_eq "${REDIS_USER:-}"   "" "KUSUR 3: REDIS_USER UYDURULMADI — boş"
assert_eq "${REDIS_PASS:-}"   "" "KUSUR 3: REDIS_PASS UYDURULMADI — boş"
assert_eq "${REDIS_PREFIX:-}" "" "KUSUR 3: REDIS_PREFIX UYDURULMADI — boş"

echo ""
echo "== 2) MUTASYON: VAR OLAN '.credentials'a ASLA dokunulmaz =="
d2="has-creds.example"
sname2=$(safe_name "$d2")
mkdir -p "${WEB_ROOT}/${d2}"
id() { [[ "$1" == "web_${sname2}" ]]; }
_domain_write_credentials "$d2" "${WEB_ROOT}/${d2}" "web_${sname2}" "8.1" \
    "db_${sname2}" "usr_${sname2}" "GERCEK_PAROLA_DOKUNMA" \
    "redis_${sname2}" "GERCEK_REDIS_PAROLA" "${sname2}:"
creds_file2="${WEB_ROOT}/${d2}/.credentials"
before_hash="$(cksum "$creds_file2")"
before_content="$(cat "$creds_file2")"

_domain_ensure_credentials "$d2" 2>/dev/null

after_hash="$(cksum "$creds_file2")"
after_content="$(cat "$creds_file2")"
assert_eq "$after_hash" "$before_hash" "MUTASYON: var olan '.credentials' checksum'ı DEĞİŞMEDİ"
assert_eq "$after_content" "$before_content" "MUTASYON: var olan '.credentials' byte-byte AYNI (parola korundu)"
assert_contains "$after_content" "GERCEK_PAROLA_DOKUNMA" "gerçek DB parolası hâlâ dosyada (üzerine yazılmadı)"

echo ""
echo "== 3) Hayalet dizine (web kullanıcısı YOK) credentials ÜRETİLMEZ =="
d3="ghost.example"
mkdir -p "${WEB_ROOT}/${d3}"
id() { return 1; }   # hiçbir kullanıcı yok
_domain_ensure_credentials "$d3" 2>/dev/null
assert_eq "$(test -e "${WEB_ROOT}/${d3}/.credentials" && echo VAR || echo YOK)" "YOK" \
    "hayalet dizin için '.credentials' ÜRETİLMEDİ"

echo ""
echo "== 4) Uçtan uca: 'domain repair' artık '.credentials'sız hardened domainde ÇALIŞIYOR =="
d4="recoverable.example"
sname4=$(safe_name "$d4")
mkdir -p "${WEB_ROOT}/${d4}/public_html"
id() { [[ "$1" == "web_${sname4}" ]]; }
mkdir -p "${SRVCTL_STATE_DIR}/${d4}"; : > "${SRVCTL_STATE_DIR}/${d4}/hardened"   # hardened marker VAR
# '.credentials' HİÇ YOK — bu, KUSUR 3'ten ÖNCE 'domain repair'i error() ile
# koşulsuz öldürüyordu (bkz. görev talebi). Alt-kabukta çalıştırılır ki
# repair'in kendi (ilgisiz mock eksikliğinden kaynaklanabilecek) hataları bu
# test script'ini düşürmesin — asıl iddia aşağıda dosyanın VARLIĞI.
if declare -F _domain_repair >/dev/null 2>&1; then
    (_domain_repair "$d4") >/dev/null 2>&1 || true
fi
assert_eq "$(test -f "${WEB_ROOT}/${d4}/.credentials" && echo VAR || echo YOK)" "VAR" \
    "'domain repair' artık '.credentials'sız hardened domainde ÇÖKMEDEN çalışıp dosyayı üretti"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"
test_summary
