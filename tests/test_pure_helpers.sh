#!/bin/bash
# Daha önce HİÇ test edilmemiş "saf" (yan etkisiz) yardımcı fonksiyonlar.
# Bunlar tek tek küçük ama davranışları yanlış olursa sessizce yayılan
# kararlar üretiyor (framework worker/scheduler komut üretimi, boole/HTTP
# kod doğrulama, OS sürüm desteği, Redis scripting ACL kararı) — hiçbirinin
# regresyon koruması yoktu. _domain_valid_mem_value/_domain_valid_cpu_value
# zaten tests/test_domain_resources_preserve.sh'ta, _deploy_civil_epoch
# zaten tests/test_deploy_prune.sh'ta kapsandığı için burada TEKRAR
# EDİLMİYOR.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
systemctl() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

# ═══════════════════════════════════════════════════════════════
#  validate_bool — yalnız literal 'true'/'false' (shell truthy DEĞİL)
# ═══════════════════════════════════════════════════════════════
assert_ok   validate_bool "true"
assert_ok   validate_bool "false"
assert_fail validate_bool "1"
assert_fail validate_bool "0"
assert_fail validate_bool "yes"
assert_fail validate_bool "TRUE"
assert_fail validate_bool ""

# ═══════════════════════════════════════════════════════════════
#  validate_http_code — tam 3 haneli, 100-599 aralığı (10# ile sekizlik
#  yorumlama tuzağından kaçınıyor: '008' gibi girdiler kırılmamalı)
# ═══════════════════════════════════════════════════════════════
assert_ok   validate_http_code "200"
assert_ok   validate_http_code "100"
assert_ok   validate_http_code "599"
assert_fail validate_http_code "099"
assert_fail validate_http_code "600"
assert_fail validate_http_code "20"
assert_fail validate_http_code "2000"
assert_fail validate_http_code "abc"

# '10#' ÖNEKİ OLMASA: bash '((008 >= 100))' ifadesini SEKİZLİK yorumlamaya
# çalışır, '8' geçerli bir sekizlik hane OLMADIĞINDAN "value too great for
# base" ile PATLAR — 'set -e' altında (core.sh/load_config tam olarak bu
# modda çalışır) bu TÜM SCRIPT'İ durdurur (doğrulandı, bkz. rapor). '008'
# sayısal olarak yalnızca 8 olduğundan (100-599 dışı) REDDEDİLMESİ doğru
# davranış; asıl garanti EDİLEN şey RET DEĞİL, ÇÖKMEDEN ret olması.
assert_fail validate_http_code "008"
err_out=$(validate_http_code "008" 2>&1 >/dev/null)
assert_eq "$err_out" "" "validate_http_code: '008' 10# sayesinde sekizlik parse hatası ÜRETMEDEN (stderr boş) temiz false döner"

# ═══════════════════════════════════════════════════════════════
#  _os_is_supported_ubuntu — GERÇEK /etc/os-release OKUNMAZ (bkz.
#  .claude/ubuntu-compat.md). _os_id/_os_version_id stub'lanarak sürüm
#  PARAMETRE olarak enjekte edilir; hem 22.04 hem 24.04 ayrı vaka.
# ═══════════════════════════════════════════════════════════════
_os_id() { echo "ubuntu"; }

_os_version_id() { echo "22.04"; }
assert_ok _os_is_supported_ubuntu

_os_version_id() { echo "24.04"; }
assert_ok _os_is_supported_ubuntu

_os_version_id() { echo "20.04"; }
assert_fail _os_is_supported_ubuntu

_os_version_id() { echo "26.04"; }
assert_fail _os_is_supported_ubuntu

_os_version_id() { echo ""; }
assert_fail _os_is_supported_ubuntu

_os_id() { echo "debian"; }
_os_version_id() { echo "22.04"; }
assert_fail _os_is_supported_ubuntu   # doğru VERSION_ID ama Ubuntu değil

# ═══════════════════════════════════════════════════════════════
#  _domain_worker_cmd — framework -> tam worker komutu (laravel/symfony),
#  desteklenmeyen framework 1 döner + boş stdout (KARAR 1: warn stderr'e).
# ═══════════════════════════════════════════════════════════════
assert_eq "$(_domain_worker_cmd laravel /usr/bin/php8.3)" \
    "/usr/bin/php8.3 artisan queue:work --sleep=3 --tries=3" \
    "_domain_worker_cmd: laravel"
assert_eq "$(_domain_worker_cmd symfony /usr/bin/php8.3)" \
    "/usr/bin/php8.3 bin/console messenger:consume async" \
    "_domain_worker_cmd: symfony"
assert_fail _domain_worker_cmd ci4 /usr/bin/php8.3
out_worker=$(_domain_worker_cmd ci4 /usr/bin/php8.3 2>/dev/null)
assert_eq "$out_worker" "" "_domain_worker_cmd: desteklenmeyen framework'te stdout boş"

# ═══════════════════════════════════════════════════════════════
#  _domain_scheduler_cmd — framework -> tam scheduler komutu
#  (laravel/ci4); symfony (messenger worker'a devredilir) DESTEKLENMEZ.
# ═══════════════════════════════════════════════════════════════
assert_eq "$(_domain_scheduler_cmd laravel /usr/bin/php8.3)" \
    "/usr/bin/php8.3 artisan schedule:run" \
    "_domain_scheduler_cmd: laravel"
assert_eq "$(_domain_scheduler_cmd ci4 /usr/bin/php8.3)" \
    "/usr/bin/php8.3 spark tasks:run" \
    "_domain_scheduler_cmd: ci4"
assert_fail _domain_scheduler_cmd symfony /usr/bin/php8.3

# ═══════════════════════════════════════════════════════════════
#  _domain_redis_scripting_mode — karar tablosu: 7+ enabled, 1-6 disabled,
#  boş/çöp unknown (fail-closed: belirsizlikte KISITLI taraf seçilir).
# ═══════════════════════════════════════════════════════════════
assert_eq "$(_domain_redis_scripting_mode 7)"  "+@scripting enabled"  "redis scripting: major=7 -> enabled"
assert_eq "$(_domain_redis_scripting_mode 8)"  "+@scripting enabled"  "redis scripting: major=8 -> enabled"
assert_eq "$(_domain_redis_scripting_mode 6)"  "-@scripting disabled" "redis scripting: major=6 -> disabled"
assert_eq "$(_domain_redis_scripting_mode 1)"  "-@scripting disabled" "redis scripting: major=1 -> disabled"
assert_eq "$(_domain_redis_scripting_mode "")" "-@scripting unknown"  "redis scripting: boş -> unknown (fail-closed)"
assert_eq "$(_domain_redis_scripting_mode "cop")" "-@scripting unknown" "redis scripting: çöp girdi -> unknown (fail-closed)"

# ═══════════════════════════════════════════════════════════════
#  _domain_redis_queue_gate — NİHAİ ACL/meta kararı: YETENEK (sürüm, bkz.
#  _domain_redis_scripting_mode) VE TALEP (--redis-queue/repair'de önceki
#  meta) BİRLİKTE gerekir. Çıktı: "<acl_bayrağı> <durum_kodu> <sebep_kodu>".
#
#  EN KRİTİK İKİ SATIR (koordinatörün az önceki düzeltmesi):
#   1) Redis >=7 + bayrak YOK -> disabled (ÖNCEKİ davranıştan KASITLI sapma:
#      sürüm yükseltmesi TEK BAŞINA hiçbir domaini sessizce açamaz).
#   2) Redis <7 + bayrak VAR -> yine disabled (fail-closed garantisi bayrakla
#      ASLA aşılamaz — komşu domainin anahtar alanına EVAL ile erişim riski).
# ═══════════════════════════════════════════════════════════════

# ── (1) KRİTİK: talep yok + yetenek VAR (Redis 7+) -> disabled/default ──
# Bu, koordinatörün istediği DAVRANIŞ DEĞİŞİKLİĞİNİN ta kendisi: sessizce
# geri dönerse (eskisi gibi 'enabled' ÜRETİRSE) KİMSE FARK ETMEZ.
assert_eq "$(_domain_redis_queue_gate "+@scripting" "enabled" "false")" \
    "-@scripting disabled default" \
    "redis-queue KRİTİK: Redis>=7 + bayrak YOK -> disabled (otomatik açılma YOK)"
assert_eq "$(_domain_redis_queue_gate "+@scripting" "enabled" "")" \
    "-@scripting disabled default" \
    "redis-queue: requested boş (çağıran geçirmemiş) -> yine disabled (güvenli varsayılan)"

# ── Talep yok + yetenek zaten YOK (Redis <7/unknown) -> davranış DEĞİŞMEDİ ──
assert_eq "$(_domain_redis_queue_gate "-@scripting" "disabled" "false")" \
    "-@scripting disabled default" \
    "redis-queue: Redis<7 + bayrak YOK -> disabled (zaten kısıtlıydı, değişmedi)"
assert_eq "$(_domain_redis_queue_gate "-@scripting" "unknown" "false")" \
    "-@scripting unknown default" \
    "redis-queue: sürüm bilinmiyor + bayrak YOK -> unknown/default (değişmedi)"

# ── Talep VAR + yetenek VAR (Redis 7+) -> onaylanır, gerçekten açılır ──
assert_eq "$(_domain_redis_queue_gate "+@scripting" "enabled" "true")" \
    "+@scripting enabled requested" \
    "redis-queue: Redis>=7 + bayrak VAR -> +@scripting enabled (bilinçli açılış GERÇEKTEN uygulanır)"

# ── (2) KRİTİK: talep VAR ama yetenek YOK (Redis <7) -> yine disabled ──
# fail-closed garantisi bayrakla ASLA aşılamaz.
assert_eq "$(_domain_redis_queue_gate "-@scripting" "disabled" "true")" \
    "-@scripting disabled rejected_version" \
    "redis-queue KRİTİK: Redis<7 + bayrak VAR -> yine disabled (ZORLA açılmaz, fail-closed korunur)"
assert_eq "$(_domain_redis_queue_gate "-@scripting" "unknown" "true")" \
    "-@scripting unknown rejected_version" \
    "redis-queue: sürüm bilinmiyor + bayrak VAR -> yine unknown/reddedildi (fail-closed korunur)"

# ── Uçtan uca kompozisyon: gerçek _domain_redis_scripting_mode çıktısı gate'e beslenir ──
_gate_from_major() {
    local major="$1" requested="$2" flag status
    read -r flag status <<< "$(_domain_redis_scripting_mode "$major")"
    _domain_redis_queue_gate "$flag" "$status" "$requested"
}
assert_eq "$(_gate_from_major 7 false)" "-@scripting disabled default" \
    "kompozisyon: major=7 + bayrak YOK -> disabled (uçtan uca doğrulama)"
assert_eq "$(_gate_from_major 7 true)"  "+@scripting enabled requested" \
    "kompozisyon: major=7 + bayrak VAR -> enabled (uçtan uca doğrulama)"
assert_eq "$(_gate_from_major 6 true)"  "-@scripting disabled rejected_version" \
    "kompozisyon: major=6 + bayrak VAR -> yine disabled (uçtan uca fail-closed doğrulama)"
assert_eq "$(_gate_from_major 6 false)" "-@scripting disabled default" \
    "kompozisyon: major=6 + bayrak YOK -> disabled (değişmedi)"

# ═══════════════════════════════════════════════════════════════
#  _redis_major_version — fail-closed: ne redis-server ne redis-cli
#  PATH'te bulunamazsa 1 döner ve stdout BOŞ kalır (gerçek servise
#  dokunmadan: PATH geçici olarak boşaltılıyor, test sonunda geri
#  yükleniyor).
# ═══════════════════════════════════════════════════════════════
_old_path="$PATH"
PATH="${WEB_ROOT}/nonexistent_bin_$$"
redis_out=$(_redis_major_version 2>/dev/null)
redis_rc=$?
PATH="$_old_path"
assert_eq "$redis_rc"  "1" "_redis_major_version: ikisi de yoksa fail-closed (rc=1)"
assert_eq "$redis_out" ""  "_redis_major_version: ikisi de yoksa stdout boş"

rm -rf "$WEB_ROOT"
test_summary
