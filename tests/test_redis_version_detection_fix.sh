#!/bin/bash
# BUG 1/2/3 (coordinator HOST bulgusu, GERÇEK Ubuntu 22.04 VM — 2026-07-31):
# üç ayrı, ZİNCİRLENMİŞ bug bulundu (_install_redis_upstream_repo başarıyla
# 7.4.10'a yükselttikten SONRA, fonksiyonel kanal-izolasyonu testinde):
#
#   BUG 1 (core.sh _redis_version_pair): sürüm tespiti ÖNCE BINARY'yi
#   ('redis-server --version') okuyordu, yalnız o başarısızsa ÇALIŞAN
#   sürece ('redis-cli INFO server') düşüyordu. GERÇEK VM'de apt binary'yi
#   6.0.16'dan 7.4.10'a yükseltti ama ÇALIŞAN SÜRECİ yeniden başlatmadı —
#   binary 7.4.10 derken çalışan süreç (process_id:48064,
#   uptime_in_seconds:13662 ile doğrulandı) hâlâ 6.0.16'ydı. Eski kod
#   BİRİNCİL (binary) kaynağı okuyup "6.2+ destekleniyor" sandı, ACL
#   dosyasına '&*'/'resetchannels' yazdı — ama bunu YORUMLAMASI gereken
#   süreç hâlâ 6.0.16 olduğundan bu sözdizimini TANIMIYORDU.
#
#   BUG 2 (lib/init.sh _install_redis): yükseltme sonrası Redis süreci
#   yeniden başlatılmıyordu — BUG 1'in kök nedeni. Elle 'systemctl restart
#   redis-server' yapılınca 'redis_version:7.4.10' ve 'ACL LOAD -> OK' oldu.
#
#   BUG 3 (EN CİDDİSİ — core.sh _redis_acl_load, çağrı siteleri
#   lib/domain.sh:655/:2385'te, O DOSYAYA DOKUNULMADI): 'redis-cli ...
#   ACL LOAD 2>/dev/null || systemctl restart redis-server' deseni
#   redis-cli'nin PROCESS exit kodunun ACL LOAD'ın SUNUCU TARAFINDAKİ
#   başarısını yansıttığını VARSAYIYORDU. GERÇEK VM'de Redis'in kendisi
#   şunu döndürdü:
#     ERR /etc/redis/users.acl:5: Syntax error. /etc/redis/users.acl:6: ...
#     WARNING: ACL errors detected, no change to the previously active ACL
#     rules was performed
#   — yani "hiçbir değişiklik yapılmadı" — ama 'srvctl domain repair
#   ci4.local' YİNE DE EXIT=0 ve "Domain onarıldı" dedi. Bir güvenlik
#   kontrolü HİÇ uygulanmamışken operatör başarı görüyordu.
#
# BU TEST DOSYASI ÜÇÜNÜ DE HEDEFLER: core.sh'taki _redis_version_pair (BUG
# 1 düzeltmesi) ve YENİ _redis_acl_load (BUG 3 paylaşılan sarmalayıcı —
# domain.sh'a bağlanması BAŞKA bir agent'a bırakıldı, bkz. core.sh başlık
# yorumu "KAPSAM NOTU"), init.sh'taki _redis_installed_binary_version_pair /
# _redis_restart_decision (BUG 2 saf karar fonksiyonu).
#
# Bu test GERÇEK redis-cli/redis-server'a ASLA dokunmaz — ikisi de bash
# fonksiyonu olarak stub'lanır (test_redis_upstream_repo.sh'taki curl/gpg
# stub'lama deseniyle AYNI yaklaşım).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/init.sh"

# ─── Ağa/gerçek servise ASLA dokunma: varsayılan olarak çağrılırsa görünür
#     biçimde patlasın (senaryolar kendi ihtiyacına göre override eder) ───
redis-cli() { echo "TEST HATASI: gerçek redis-cli çağrıldı" >&2; return 99; }
redis-server() { echo "TEST HATASI: gerçek redis-server çağrıldı" >&2; return 99; }

# SRVCTL_CONF salt-okunur DEĞİL (core.sh'ta 'readonly' yok) — test-seam
# gerekmeden doğrudan bir tmp dosyaya çekilebilir.
SRVCTL_CONF="$(mktemp)"

# ═══════════════════════════════════════════════
#  BUG 1 — _redis_version_pair ÇALIŞAN sunucudan okur, BINARY'den DEĞİL
# ═══════════════════════════════════════════════

# (1a) SRVCTL_CONF'ta REDIS_ADMIN_PASS YOK (ilk kurulum senaryosu) — parolasız
#      dener. Binary 7.4.10 derken ÇALIŞAN süreç 6.0.16 diyorsa fonksiyon
#      ÇALIŞAN sürümü (6 0) döndürmeli, BİNARY'yi (7 4) DEĞİL.
: > "$SRVCTL_CONF"
redis-server() { echo "Redis server v=7.4.10 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=abcdef1234567890"; }
redis-cli() {
    if [[ "$*" == *"INFO server"* ]]; then
        printf 'redis_version:6.0.16\r\nprocess_id:48064\r\nuptime_in_seconds:13662\r\n'
    fi
}
assert_eq "$(_redis_version_pair)" "6 0" \
    "BUG 1: binary 7.4.10 diyor ama ÇALIŞAN süreç 6.0.16 diyor -> fonksiyon ÇALIŞANI (6 0) döndürüyor, BINARY'yi (7 4) DEĞİL"

# (1b) Admin parolası SRVCTL_CONF'ta VARSA (ACL zaten kilitli olabilir) —
#      REDISCLI_AUTH env + '--user admin' ile denenmeli, argv'ye DEĞİL.
#
# ÖNEMLİ (subshell tuzağı — test_deploy_health_ok.sh'taki AYNI sınıf notla
# BİREBİR): '_redis_version_pair' içeride 'out=$(... | grep ...)' ile
# redis-cli'yi bir PIPE + komut ikamesinin İÇİNDE çağırır — bu, stub'ın
# İÇİNDEKİ sıradan bir GLOBAL DEĞİŞKEN atamasını bir ALT KABUĞA hapseder;
# üst kabuğa ASLA YANSIMAZ (sessizce boş kalır, YANLIŞ POZİTİF üretir). Bu
# yüzden gözlem DOSYA üzerinden yapılır (subshell sınırını AŞAR).
echo "REDIS_ADMIN_PASS=s3cr3t-admin-pw" > "$SRVCTL_CONF"
_auth_capture="$(mktemp)"
_args_capture="$(mktemp)"
redis-cli() {
    echo "${REDISCLI_AUTH:-}" > "$_auth_capture"
    echo "$*" > "$_args_capture"
    if [[ "$*" == *"INFO server"* ]]; then
        printf 'redis_version:7.4.10\r\n'
    fi
}
assert_eq "$(_redis_version_pair)" "7 4" "BUG 1: admin parolası varken de doğru sürüm okunuyor"
assert_eq "$(cat "$_auth_capture")" "s3cr3t-admin-pw" \
    "BUG 1: parola REDISCLI_AUTH ENV'e gidiyor (argv'ye DEĞİL — 'ps' çıktısında görünmesin)"
assert_contains "$(cat "$_args_capture")" "--user admin" \
    "BUG 1: admin parolası bilinince '--user admin' ile bağlanılıyor"
assert_not_contains "$(cat "$_args_capture")" "s3cr3t-admin-pw" \
    "BUG 1: parola redis-cli'ye ARGÜMAN olarak GEÇMİYOR (yalnız env)"
rm -f "$_auth_capture" "$_args_capture"

# (1c) Çalışan sunucuya ULAŞILAMIYORSA (redis-cli boş/hata döner) — fail-closed:
#      1 döner, stdout boş (BİNARY'ye asla düşülmüyor — eski dead-code fallback
#      KALICI olarak kaldırıldı).
: > "$SRVCTL_CONF"
redis-server() { echo "Redis server v=7.4.10 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=abcdef1234567890"; }
redis-cli() { return 1; }   # bağlantı reddedildi simülasyonu
pair_out="$(_redis_version_pair 2>/dev/null)"; pair_rc=$?
assert_eq "$pair_rc" "1" "BUG 1: çalışan sunucuya ulaşılamıyorsa fail-closed (rc=1) — BİNARY fallback YOK"
assert_eq "$pair_out" "" "BUG 1: çalışan sunucuya ulaşılamıyorsa stdout boş"

# (1d) redis-cli hiç YOKSA (PATH'te bulunamıyor) — yine fail-closed, redis-server
#      hiç SORULMUYOR (BUG 1'in TAM KAYNAĞI: eski kod BURADA binary'ye
#      düşerdi).
unset -f redis-cli
_old_path="$PATH"
PATH="${WEB_ROOT}/nonexistent_bin_$$"
redis_server_called=false
redis-server() { redis_server_called=true; echo "Redis server v=7.4.10 ..."; }
pair_out2="$(_redis_version_pair 2>/dev/null)"; pair_rc2=$?
PATH="$_old_path"
assert_eq "$pair_rc2" "1" "BUG 1: redis-cli PATH'te yoksa fail-closed (rc=1)"
assert_eq "$pair_out2" "" "BUG 1: redis-cli PATH'te yoksa stdout boş"
assert_eq "$redis_server_called" "false" \
    "BUG 1 REGRESYON KANITI: redis-cli yokken 'redis-server --version' ARTIK HİÇ ÇAĞRILMIYOR (eski dead-code fallback kalıcı olarak kaldırıldı)"
redis-cli() { echo "TEST HATASI: gerçek redis-cli çağrıldı" >&2; return 99; }

# ═══════════════════════════════════════════════
#  BUG 2 — _redis_restart_decision (saf karar) + _redis_installed_binary_version_pair
# ═══════════════════════════════════════════════
assert_eq "$(_redis_restart_decision 7 4 6 0)" "restart_needed" \
    "BUG 2: binary(7.4) != çalışan(6.0) -> restart GEREKLİ (GERÇEK VM senaryosu)"
assert_eq "$(_redis_restart_decision 7 4 7 4)" "no_restart_needed" \
    "BUG 2: binary(7.4) == çalışan(7.4) -> restart GEREKMEZ (gereksiz kesinti YOK)"
assert_eq "$(_redis_restart_decision 6 0 6 0)" "no_restart_needed" \
    "BUG 2: ikisi de 6.0 (yükseltme hiç olmadı) -> restart GEREKMEZ"
assert_eq "$(_redis_restart_decision "" "" 6 0)" "no_restart_needed" \
    "BUG 2: binary bilinmiyor -> fail-safe, GEREKSİZ restart YOK"
assert_eq "$(_redis_restart_decision 7 4 "" "")" "no_restart_needed" \
    "BUG 2: çalışan sürüm bilinmiyor -> fail-safe, GEREKSİZ restart YOK"
assert_eq "$(_redis_restart_decision "" "" "" "")" "no_restart_needed" \
    "BUG 2: ikisi de bilinmiyor -> fail-safe, GEREKSİZ restart YOK"

redis-server() { echo "Redis server v=7.4.10 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=abcdef1234567890"; }
assert_eq "$(_redis_installed_binary_version_pair)" "7 4" \
    "BUG 2: _redis_installed_binary_version_pair binary'den (7.4.10) doğru okuyor"
unset -f redis-server
PATH="${WEB_ROOT}/nonexistent_bin_$$" ; bin_out="$(_redis_installed_binary_version_pair 2>/dev/null)"; bin_rc=$?; PATH="$_old_path"
assert_eq "$bin_rc" "1" "BUG 2: redis-server PATH'te yoksa fail-closed (rc=1)"
assert_eq "$bin_out" "" "BUG 2: redis-server PATH'te yoksa stdout boş"
redis-server() { echo "TEST HATASI: gerçek redis-server çağrıldı" >&2; return 99; }

# ═══════════════════════════════════════════════
#  BUG 3 (EN CİDDİSİ) — _redis_acl_load hatayı YUTMUYOR
# ═══════════════════════════════════════════════

# (3a) Başarı: TAM OLARAK 'OK' + rc=0
redis-cli() { echo "OK"; return 0; }
assert_ok _redis_acl_load "somepass"

# (3b) GERÇEK VM hata senaryosu — KRİTİK NOKTA: redis-cli BURADA 0 DÖNSE
#      BİLE (gerçek bug TAM OLARAK buydu: process exit kodu ACL LOAD'ın
#      SUNUCU TARAFINDAKİ anlamsal başarısını YANSITMIYOR) çıktı 'OK'
#      olmadığından BAŞARISIZ sayılmalı.
redis-cli() {
    printf 'ERR /etc/redis/users.acl:5: Syntax error. /etc/redis/users.acl:6: Syntax error.\nWARNING: ACL errors detected, no change to the previously active ACL rules was performed\n'
    return 0   # <-- eski kod TAM OLARAK bunu "başarı" sayıyordu
}
assert_fail _redis_acl_load "somepass"
acl_err_out="$(_redis_acl_load "somepass" 2>&1 1>/dev/null)"
assert_contains "$acl_err_out" "no change to the previously active ACL rules was performed" \
    "BUG 3: Redis'in KENDİ teşhis metni operatöre GÖSTERİLİYOR (yutulmuyor)"
assert_contains "$acl_err_out" "BAŞARISIZ" \
    "BUG 3: açık bir BAŞARISIZLIK etiketi basılıyor (sessiz değil)"

# (3c) redis-cli GERÇEKTEN non-zero dönerse de (bağlantı hatası vb.) başarısız
redis-cli() { return 1; }
assert_fail _redis_acl_load "somepass"

# (3d) Fazladan boşluk/CR ile 'OK' — hâlâ başarı sayılmalı (redis-cli CRLF
#      basabilir; xargs ile kırpma regresyona yol açmamalı)
redis-cli() { printf 'OK\r\n'; return 0; }
assert_ok _redis_acl_load "somepass"

# (3e) Parola argv'ye DEĞİL env'e gidiyor mu? (subshell tuzağı için bkz.
#      (1b)'deki yorum — '_redis_acl_load' içeride 'out=$(...)' kullanır,
#      gözlem yine DOSYA üzerinden yapılır.)
_acl_auth_capture="$(mktemp)"
redis-cli() { echo "${REDISCLI_AUTH:-}" > "$_acl_auth_capture"; echo "OK"; return 0; }
_redis_acl_load "gizli-parola" >/dev/null 2>&1
assert_eq "$(cat "$_acl_auth_capture")" "gizli-parola" \
    "BUG 3: _redis_acl_load parolayı REDISCLI_AUTH env'e koyuyor (argv'ye DEĞİL)"
rm -f "$_acl_auth_capture"

rm -f "$SRVCTL_CONF"
rm -rf "$WEB_ROOT"
test_summary
