#!/bin/bash
# Redis 'ACL LOAD' dürüstlüğü — HOST'ta ölçülen BUG 3 (srvctl-jammy).
#
# KÖK NEDEN: 'redis-cli', sunucudan HERHANGİ bir yanıt aldığı sürece —
# yanıt bir HATA METNİ olsa bile — genellikle 0 ile ÇIKAR. Eski
# lib/domain.sh çağrı siteleri (_domain_repair VE _domain_add) yalnız
# exit koduna bakıyordu:
#   REDISCLI_AUTH="$pass" redis-cli --user admin --no-auth-warning ACL LOAD \
#       2>/dev/null || systemctl restart redis-server
# HOST'ta ölçüldü: 'ACL LOAD' "ERR /etc/redis/users.acl:5: Syntax error"
# ile ÇÖKTÜ, Redis "no change to the previously active ACL rules was
# performed" dedi — ama 'srvctl domain repair ci4.local' "✓ Domain
# onarıldı" + EXIT=0 basıyordu. Sonuç: bu domainin Redis kanal izolasyonu
# (komşu domainin pub/sub kanalını dinlemesini/yayın yapmasını ENGELLEYEN
# kontrol) hiç yürürlüğe girmemişti — fonksiyonel testte domain A, domain
# B'nin kanalına hem PUBLISH hem SUBSCRIBE yapabiliyordu.
#
# DÜZELTME: her iki çağrı sitesi de core.sh'ın paylaşılan '_redis_acl_load'
# sarmalayıcısını kullanıyor (hem dönüş kodu HEM çıktının TAM OLARAK 'OK'
# olduğunu kontrol eder). '_domain_repair'daki dönüş değeri artık
# 'repair_failed' bayrağına bağlı — bu turda kurulan dürüst raporlama
# mekanizmasını (bkz. test_domain_repair_reporting.sh) ACL LOAD'a da
# genişletiyor. Ayrıca: ACL LOAD başarısız olduğunda 'systemctl restart
# redis-server' fallback'i BİLEREK KALDIRILDI — sebep muhtemelen
# users.acl'deki bir SÖZDİZİMİ HATASIYSA, restart TÜM domainlerin
# Redis'ini çökertebilirdi (tek domainin izolasyon eksikliğinden daha
# büyük bir hasar).
#
# Bu test üç şeyi kilitler:
#   1) [EN KRİTİK] ACL LOAD başarısızken '_domain_repair' SIFIRDAN FARKLI
#      döner, "✓ Domain onarıldı" BASMAZ, güvenlik uyarısı basar.
#   2) ACL LOAD başarılıyken normal akış bozulmaz (yanlış pozitif üretmez).
#   3) Statik kilit: HER İKİ çağrı sitesi de ham 'redis-cli ... ACL LOAD'
#      komutunu DEĞİL '_redis_acl_load'ı kullanıyor; başarısızlık dalında
#      kör bir 'systemctl restart redis-server' YOK (ACL dosyası bozuksa
#      TÜM Redis'i çökertebilirdi).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
mysql() { return 0; }
id() { return 0; }
systemctl_calls="$(mktemp)"
systemctl() { printf '%s\n' "$*" >> "$systemctl_calls"; return 0; }
redis-cli() { echo "MOCK ÇAĞRILDI — _redis_acl_load KULLANILMALIYDI"; return 0; }

source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_repair >/dev/null 2>&1; then
    echo "  SKIP: _domain_repair tanımlı değil"
    test_summary
    exit $?
fi

_setup_domain() {
    local domain="$1" sname
    sname=$(safe_name "$domain")
    mkdir -p "${WEB_ROOT}/${domain}"
    _domain_write_credentials "$domain" "${WEB_ROOT}/${domain}" "web_${sname}" "8.3" \
        "db_${sname}" "usr_${sname}" "cleanpassdb1234" \
        "redis_${sname}" "cleanpassredis1234" "${sname}:"
}

echo "== Redis ACL LOAD dürüstlüğü =="

export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
# 'SRVCTL_CONF' core.sh'ta düz atamayla (SRVCTL_ROOT hardcoded) geldiğinden
# sourcing SONRASI test için serbestçe yeniden atanabilir (bir sonraki
# 'load_config' çağrısı yok) — REDIS_ADMIN_PASS'i test'in kendi geçici
# dosyasından okutuyoruz.
SRVCTL_CONF="$(mktemp)"
echo "REDIS_ADMIN_PASS=test-admin-pass-123" > "$SRVCTL_CONF"

_domain_activate_fpm_unit() { return 0; }

# ═══ A [EN KRİTİK]: ACL LOAD başarısız — repair dürüstçe başarısız raporlamalı ═══
_redis_acl_load() { return 1; }

dA="acl-fail.test"
_setup_domain "$dA"
: > "$systemctl_calls"
outA=$(_domain_repair "$dA" 2>&1); rcA=$?

assert_eq "$([[ "$rcA" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "A [KRİTİK]: ACL LOAD başarısızken _domain_repair SIFIRDAN FARKLI döner (rc=${rcA})"
assert_not_contains "$outA" "Domain onarıldı:" \
    "A [KRİTİK]: ACL LOAD başarısızken başarı mesajı ('Domain onarıldı:') BASILMADI"
assert_contains "$outA" "GÜVENLİK: Redis ACL" \
    "A: güvenlik uyarısı basıldı (ACL canlıya UYGULANMADI)"
assert_contains "$outA" "kanal izolasyonu" \
    "A: kanal izolasyonu YÜRÜRLÜKTE OLMADIĞI özellikle söyleniyor"
assert_not_contains "$(cat "$systemctl_calls")" "restart redis-server" \
    "A: ACL dosyası bozuk olabileceğinden 'restart redis-server' KÖRCE denenmedi"
assert_contains "$outA" "KISMEN onarıldı" \
    "A: genel sonuç dürüstçe 'KISMEN onarıldı' olarak raporlanıyor"

# ═══ B: ACL LOAD başarılı — yanlış pozitif üretilmemeli ═══
_redis_acl_load() { return 0; }

dB="acl-ok.test"
_setup_domain "$dB"
: > "$systemctl_calls"
outB=$(_domain_repair "$dB" 2>&1); rcB=$?

assert_eq "$([[ "$rcB" -eq 0 ]] && echo ZERO || echo NONZERO)" "ZERO" \
    "B: ACL LOAD başarılıyken (ve başka hiçbir şey başarısız değilken) repair BAŞARILI döner"
assert_contains "$outB" "Domain onarıldı:" \
    "B: ACL LOAD başarılıyken başarı mesajı BASILDI"
assert_not_contains "$outB" "GÜVENLİK: Redis ACL" \
    "B: ACL LOAD başarılıyken YANLIŞ POZİTİF güvenlik uyarısı ÜRETİLMEDİ"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR"
rm -f "$SRVCTL_CONF" "$systemctl_calls"

# ═══ C: Statik regresyon kilidi — HER İKİ çağrı sitesi de ham redis-cli
# ÇAĞIRMIYOR (_redis_acl_load kullanıyor); başarısızlık dalında kör bir
# 'systemctl restart redis-server' YOK. ═══
echo ""
echo "== statik regresyon kilidi =="

raw_calls=$(grep -n 'redis-cli --user admin --no-auth-warning ACL LOAD' "${REPO_ROOT}/lib/domain.sh" || true)
assert_eq "$raw_calls" "" \
    "C [KRİTİK]: lib/domain.sh'ta HAM 'redis-cli ... ACL LOAD' çağrısı KALMADI (ikisi de _redis_acl_load kullanıyor)"

wrapper_calls=$(grep -c '_redis_acl_load "\$redis_admin_pass"' "${REPO_ROOT}/lib/domain.sh")
assert_eq "$wrapper_calls" "2" \
    "C: TAM OLARAK iki çağrı sitesi '_redis_acl_load' kullanıyor (_domain_repair + _domain_add)"

# Her '_redis_acl_load' başarısızlık dalının HEMEN ardından (en fazla 4 satır
# içinde) kör bir 'systemctl restart redis-server' KOMUTU (uyarı METNİ
# İÇİNDEKİ alıntı DEĞİL — bu yüzden satır başında '^[[:space:]]*systemctl'
# ile GERÇEK bir komut çağrısı arıyoruz) OLMAMALI.
blind_restart_after_failure=$(awk '
    /if ! _redis_acl_load/ { after=4; next }
    after > 0 {
        if ($0 ~ /^[[:space:]]*systemctl restart redis-server/) { print NR": "$0 }
        after--
    }
' "${REPO_ROOT}/lib/domain.sh")
assert_eq "$blind_restart_after_failure" "" \
    "C [KRİTİK]: ACL LOAD başarısızlık dalının hemen ardından kör bir 'systemctl restart redis-server' YOK"

test_summary
