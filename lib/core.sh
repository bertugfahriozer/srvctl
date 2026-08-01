#!/bin/bash
# ═══════════════════════════════════════════════
#  core.sh — Ortak fonksiyonlar
# ═══════════════════════════════════════════════

SRVCTL_VERSION="2.0.0"
SRVCTL_ROOT="/usr/local/srvctl"
SRVCTL_CONF="${SRVCTL_ROOT}/conf/srvctl.conf"
SRVCTL_LOG="${SRVCTL_ROOT}/logs/srvctl.log"
SRVCTL_TEMPLATES="${SRVCTL_ROOT}/templates"

# ─── Renkler ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Log Fonksiyonları ───
# KARAR 1 (denetim DALGA 4): warn() STDERR'e taşındı. Önceden stdout'a
# yazıyordu; 146 çağrı yerinden yalnız _deploy_prune'un çıktısı $( ) ile
# yakalanıyordu ve o da zaten '2>&1' kullandığından davranışı DEĞİŞMEZ
# (bkz. lib/deploy.sh). info()/success() BİLEREK stdout'ta kalır —
# _deploy_prune_one'ın info çıktısı bilinçli olarak toplanıyor.
info()    { echo -e "  ${BLUE}ℹ${NC}  $*"; }
success() { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*" >&2; }
error()   { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
step()    { echo -e "  ${CYAN}[${1}]${NC} ${2}"; }

# srvctl olay günlüğü. HER ZAMAN 0 döner ve stderr'e HİÇBİR ŞEY sızdırmaz.
#
# GEREKÇE (güvenlik denetimi — "sessiz fail-closed" sınıfı): bu fonksiyon
# ARTIK güvenlik olaylarının (bkz. security_event/security_error) kalıcı iz
# bırakma yoludur ve secure_file/secure_dir gibi ÇOK sık çağrılan
# yardımcıların İÇİNDEN tetiklenebilir. Eski hâli 'mkdir -p' başarısız
# olduğunda (yazılamayan/olmayan log dizini, macOS geliştirme kutusu, test
# harness'ı) HEM stderr'e ham bir 'mkdir: Permission denied' basıyor HEM DE
# sıfırdan farklı dönüyordu — 'set -e' altında bu, LOG YAZAMAMANIN ASIL
# KOMUTU ÖLDÜRMESİ demekti. Loglama bir yan etkidir; asla akışı düşürmemeli
# ve asla operatörün gördüğü çıktıyı kirletmemelidir.
log_action() {
    local dir
    dir=$(dirname "${SRVCTL_LOG}")
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(whoami)" "$*" \
        >> "${SRVCTL_LOG}" 2>/dev/null || return 0
    return 0
}

# ─── GÜVENLİK OLAYI RAPORLAMA (İKİ KANAL: operatör + kalıcı iz) ───
#
# ÖLÇÜLEN KUSUR (bu depoda TEKRARLAYAN hata sınıfı — "sessiz fail-closed"):
# deploy kilidi sembolik bağ saldırısı fail-closed reddedildiğinde davranış
# DOĞRUYDU ama olay YALNIZ stderr'de, YALNIZ o anlık terminalde yaşıyordu:
#   * stdout'a 0 bayt yazılıyordu (ölçüldü — bkz. tests/
#     test_lock_symlink_visibility.sh),
#   * '/usr/local/srvctl/logs/srvctl.log' dosyasına HİÇ satır düşmüyordu
#     (ölçüldü) — çünkü bu yolun HİÇBİR yerinde 'log_action' YOKTU.
# Sonuç: biri root'a keyfi chown/truncate primitifi denediğinde operatörün
# elinde SONRADAN bakılabilecek HİÇBİR kanıt kalmıyordu. Reddetmek yetmez;
# güvenlik olayı KAYDEDİLMELİDİR.
#
# İki fonksiyon, İKİ farklı akış kararı için:
#   security_event  → warn (stderr) + log_action, AKIŞ DEVAM EDER (0 döner).
#   security_error  → log_action + error (stderr) ve ÇIKAR (exit 1).
# İkisi de log satırını 'GÜVENLİK' önekiyle yazar — 'grep GÜVENLİK
# /usr/local/srvctl/logs/srvctl.log' tek komutla tüm olayları verir.
security_event() {
    warn "$*"
    log_action "GÜVENLİK OLAYI: $*"
    return 0
}

security_error() {
    log_action "GÜVENLİK REDDİ: $*"
    error "$*"
}

# ─── Ayırıcılar ───
header() {
    echo ""
    echo -e "  ${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}  $*${NC}"
    echo -e "  ${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
}

divider() {
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
}

# ─── OS Sürüm Tespiti (bkz. .claude/ubuntu-compat.md) ───
# TEK doğruluk kaynağı burasıdır — modüller kendi /etc/os-release parse'ını
# YAZMAZ, bu helper'ları kullanır. Kural: yetenek tespiti > çıplak sürüm
# karşılaştırması. Bu helper'lar SADECE "hangi Ubuntu LTS'yiz" sorusuna
# cevap verir (örn. install.sh'ın destek gate'i); davranış farkı olan her
# yerde (paket adı, config yönergesi, log yolu vb.) önce 'command -v',
# dosya varlığı, '--version' çıktısı gibi YETENEK kontrolü tercih edilir.
# source DEĞİL: /etc/os-release'i katı grep+cut ile ayrıştırır (dosya
# root'a ait olsa da source alışkanlığı edinmeyelim — beklenmedik
# değişken/komut enjeksiyonuna karşı savunma).
_os_version_id() {
    [[ -r /etc/os-release ]] || { echo ""; return 0; }
    grep -m1 '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'
}

_os_id() {
    [[ -r /etc/os-release ]] || { echo ""; return 0; }
    grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'
}

# srvctl'in test ettiği Ubuntu LTS'lerinden biri mi? (PREDIKAT: 0=destekli
# 1=değil/Ubuntu değil — exit YOK). Yeni bir LTS çıktığında burası güncellenir.
_os_is_supported_ubuntu() {
    [[ "$(_os_id)" == "ubuntu" ]] || return 1
    case "$(_os_version_id)" in
        22.04|24.04) return 0 ;;
        *)           return 1 ;;
    esac
}

# ─── Girdi Doğrulayıcıları (PREDIKAT: 0=geçerli 1=geçersiz; çıktı YOK, exit YOK) ───
# Çağıran taraf karar verir:  validate_x "$v" || error "..."
# NOT: validate_uint/validate_bool/validate_http_code/validate_gpg_recipient,
# load_config'de kaynak-zamanı çağrısından ÖNCE tanımlanmalıdır (load_config
# bunları kullanır).

# İşaretsiz tamsayı; opsiyonel üst sınır
validate_uint() {
    local v="$1" max="${2:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    if [[ -n "$max" ]]; then
        (( v <= max )) || return 1
    fi
    return 0
}

# Boole: yalnızca literal 'true'/'false' string'i (shell truthy DEĞİL)
validate_bool() {
    [[ "$1" == "true" || "$1" == "false" ]]
}

# HTTP durum kodu: tam 3 haneli, 100-599 aralığı (10# → sekizlik yorumlanmasın)
validate_http_code() {
    [[ "$1" =~ ^[0-9]{3}$ ]] || return 1
    (( 10#$1 >= 100 && 10#$1 <= 599 ))
}

# GPG alıcı tanımlayıcısı (e-posta / key-ID / fingerprint). BACKUP_GPG_RECIPIENT
# doğrudan 'gpg -r "$deger"' argümanı olarak geçtiğinden (bkz. lib/backup.sh)
# boşluk ve baştaki '-' reddedilir (option-injection savunma-derinliği —
# _deploy_validate_repo_url/validate_git_url ile aynı desen); yalnızca
# e-posta/fingerprint'te geçerli karakterler ([A-Za-z0-9._%+=@-]) kabul edilir.
validate_gpg_recipient() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    [[ "$v" == -* ]] && return 1
    [[ "$v" =~ [[:space:]] ]] && return 1
    [[ "$v" =~ ^[A-Za-z0-9._%+=@-]+$ ]]
}

# ─── Yapılandırma ───
load_config() {
    if [[ -f "$SRVCTL_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$SRVCTL_CONF"
    fi
    # Varsayılanlar
    DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.3}"
    SSH_PORT="${SSH_PORT:-2222}"
    WEB_ROOT="${WEB_ROOT:-/var/www}"
    BACKUP_DIR="${BACKUP_DIR:-/backups}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    DEPLOYER_USER="${DEPLOYER_USER:-deployer}"

    # ─── Per-domain FPM izolasyonu (Faz 2/T7a — Seçenek C, kullanıcı kararı) ───
    # Varsayılan AÇIK: 'domain add' sonunda domain otomatik olarak paylaşılan
    # php<ver>-fpm master'ından kendi 'srvctl-fpm-<sname>.service' unit'ine
    # (AppArmor/cgroups/seccomp GERÇEKTEN attach — bkz. HOST doğrulaması)
    # taşınır. Migrasyon mantığının TEK kaynağı lib/security.sh:_harden_fpm_apply'dır
    # (buradan yalnız ÇAĞRILIR, KOPYALANMAZ — bkz. lib/domain.sh
    # _domain_migrate_to_isolated_fpm). 100 domain / hepsi e-ticaret hedefi
    # için varsayılan izolasyon istendi. fail-closed: migrasyon başarısız
    # olursa domain PAYLAŞILAN pool'da çalışmaya DEVAM eder — 'domain add'
    # bu yüzden ASLA başarısız SAYILMAZ.
    DOMAIN_ISOLATED_FPM="${DOMAIN_ISOLATED_FPM:-true}"

    # ─── Deploy release saklama ───
    # Rollback hedefi gerektiğinden taban 2'dir; altı zorlanır.
    DEPLOY_KEEP_RELEASES="${DEPLOY_KEEP_RELEASES:-5}"
    DEPLOY_PRUNE_BAK_DAYS="${DEPLOY_PRUNE_BAK_DAYS:-7}"

    # ─── Deploy davranışı (lib/deploy.sh okur) ───
    # Varsayılan KAPALI: migration rollback şemayı geri ALMAZ; otomatik migration
    # + health-check tetiklemeli otomatik rollback birleşimi şema/veri arasında
    # SESSİZ tutarsızlık üretebilir. Operatör kararı olmalı; per-domain
    # '.srvctl-meta' üzerinden açılabilir (bkz. write_meta/read_meta).
    DEPLOY_RUN_MIGRATIONS="${DEPLOY_RUN_MIGRATIONS:-false}"
    # 'npm ci && npm run build' — varsayılan KAPALI (her sunucuda node
    # kurulu/istenir olmayabilir; opt-in).
    DEPLOY_NPM_BUILD="${DEPLOY_NPM_BUILD:-false}"
    # Sağlık kontrolü retry: tek atışlık probe + 'pm = ondemand' soğuk worker
    # kombinasyonu yanlış-negatif üretip gereksiz oto-rollback'e yol açabilir.
    DEPLOY_HEALTH_RETRIES="${DEPLOY_HEALTH_RETRIES:-5}"
    DEPLOY_HEALTH_INTERVAL="${DEPLOY_HEALTH_INTERVAL:-2}"
    # Kabul edilen HTTP kodları. 404/403 KASITLI OLARAK yok: composer/vendor
    # kurulmamış bir release nginx 404 dönebilir ve "sağlıklı" sayılıp canlıya
    # alınabilirdi.
    DEPLOY_HEALTH_OK_CODES="${DEPLOY_HEALTH_OK_CODES:-200 301 302}"

    # ─── Yedekleme: sır şifreleme + disk eşiği (lib/backup.sh okur) ───
    # DALGA 6'da '${VAR:-}' fallback'iyle okunmaya başlandı ama core.sh o
    # zaman bu anahtarların sahibi değildi — kalıcı varsayılan/doğrulama
    # EKLENMEMİŞTİ (bkz. lib/backup.sh:_backup_run yorumu). install.sh mevcut
    # kurulumlarda conf/srvctl.conf'u KORUDUĞUNDAN eski kurulumlarda bu
    # anahtarlar dosyada HİÇ olmayabilir — varsayılanlar burada ZORUNLUDUR.
    # Boş = kapalı (configs.tar.gz şifrelenmez, düz metin üretilir).
    BACKUP_GPG_RECIPIENT="${BACKUP_GPG_RECIPIENT:-}"
    # Yedek öncesi asgari boş disk alanı (MB); yetersizse yedekleme
    # BAŞLATILMADAN reddedilir.
    BACKUP_MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-500}"

    # ─── Self-update yedek saklama (lib/selfupdate.sh okur) ───
    # Son N kurulum yedeği tutulur. En az 1 ZORUNLUDUR — 0'a izin verilirse
    # 'self-update run' BAŞARILI bir güncellemeden hemen SONRA kendi az önce
    # oluşturduğu yedeği de siler ve manuel 'self-update rollback' için HİÇBİR
    # hedef kalmaz (bkz. lib/selfupdate.sh:_selfupdate_prune_backups çağrı sırası).
    SELFUPDATE_KEEP_BACKUPS="${SELFUPDATE_KEEP_BACKUPS:-3}"

    # ─── Güvenilir edge-IP senkronu (Cloudflare + UptimeRobot) ───
    TRUSTED_SYNC_ENABLED="${TRUSTED_SYNC_ENABLED:-true}"
    TRUSTED_SOURCES="${TRUSTED_SOURCES:-cloudflare uptimerobot}"
    TRUSTED_STATE_DIR="${TRUSTED_STATE_DIR:-/etc/srvctl/trusted}"
    CLOUDFLARE_IPS_V4_URL="${CLOUDFLARE_IPS_V4_URL:-https://www.cloudflare.com/ips-v4}"
    CLOUDFLARE_IPS_V6_URL="${CLOUDFLARE_IPS_V6_URL:-https://www.cloudflare.com/ips-v6}"
    UPTIMEROBOT_IPS_URL="${UPTIMEROBOT_IPS_URL:-https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt}"

    # Doğrulama (sshd/ufw/fail2ban ve tüm domain yollarının kaynağı — fail-closed).
    # validate_uint her zaman tanımlıdır (yukarıda load_config'den önce tanımlandı).
    validate_uint "$SSH_PORT" 65535 || error "Geçersiz SSH_PORT: ${SSH_PORT} (1-65535 arası tam sayı)"
    [[ "$WEB_ROOT" == /* ]] || error "Geçersiz WEB_ROOT: ${WEB_ROOT} (mutlak yol olmalı)"
    validate_bool "$DOMAIN_ISOLATED_FPM" \
        || error "Geçersiz DOMAIN_ISOLATED_FPM: ${DOMAIN_ISOLATED_FPM} (true|false olmalı)"
    validate_uint "$DEPLOY_KEEP_RELEASES" 1000 \
        || error "Geçersiz DEPLOY_KEEP_RELEASES: ${DEPLOY_KEEP_RELEASES} (1-1000 arası tam sayı)"
    (( DEPLOY_KEEP_RELEASES >= 2 )) \
        || error "DEPLOY_KEEP_RELEASES en az 2 olmalı (rollback hedefi gerekir): ${DEPLOY_KEEP_RELEASES}"
    validate_uint "$DEPLOY_PRUNE_BAK_DAYS" 3650 \
        || error "Geçersiz DEPLOY_PRUNE_BAK_DAYS: ${DEPLOY_PRUNE_BAK_DAYS}"
    validate_bool "$DEPLOY_RUN_MIGRATIONS" \
        || error "Geçersiz DEPLOY_RUN_MIGRATIONS: ${DEPLOY_RUN_MIGRATIONS} (true|false olmalı)"
    validate_bool "$DEPLOY_NPM_BUILD" \
        || error "Geçersiz DEPLOY_NPM_BUILD: ${DEPLOY_NPM_BUILD} (true|false olmalı)"
    validate_uint "$DEPLOY_HEALTH_RETRIES" 60 \
        || error "Geçersiz DEPLOY_HEALTH_RETRIES: ${DEPLOY_HEALTH_RETRIES} (0-60 arası tam sayı)"
    validate_uint "$DEPLOY_HEALTH_INTERVAL" 300 \
        || error "Geçersiz DEPLOY_HEALTH_INTERVAL: ${DEPLOY_HEALTH_INTERVAL} (0-300 arası saniye)"
    [[ -n "$DEPLOY_HEALTH_OK_CODES" ]] \
        || error "Geçersiz DEPLOY_HEALTH_OK_CODES: boş olamaz"
    local _code
    for _code in $DEPLOY_HEALTH_OK_CODES; do
        validate_http_code "$_code" \
            || error "Geçersiz DEPLOY_HEALTH_OK_CODES girdisi: '${_code}' (100-599 arası 3 haneli HTTP kodu olmalı)"
    done

    [[ -z "$BACKUP_GPG_RECIPIENT" ]] || validate_gpg_recipient "$BACKUP_GPG_RECIPIENT" \
        || error "Geçersiz BACKUP_GPG_RECIPIENT: ${BACKUP_GPG_RECIPIENT} (boşluk/öncü '-' yok; yalnız harf/rakam/._%+=@- karakterleri)"
    validate_uint "$BACKUP_MIN_FREE_MB" 10000000 \
        || error "Geçersiz BACKUP_MIN_FREE_MB: ${BACKUP_MIN_FREE_MB} (0-10000000 arası MB)"
    validate_uint "$SELFUPDATE_KEEP_BACKUPS" 1000 \
        || error "Geçersiz SELFUPDATE_KEEP_BACKUPS: ${SELFUPDATE_KEEP_BACKUPS} (1-1000 arası tam sayı)"
    (( SELFUPDATE_KEEP_BACKUPS >= 1 )) \
        || error "SELFUPDATE_KEEP_BACKUPS en az 1 olmalı (rollback hedefi kaybolmasın): ${SELFUPDATE_KEEP_BACKUPS}"
}

load_config

# ─── Yardımcı Fonksiyonlar ───

# ─── Portable stat sarmalayıcıları (GNU -c / BSD -f) ───
# macOS geliştirme kutusunda GNU stat yoktur; ikisini de dene.

# Bir yolun sahibinin kullanıcı adını yaz
_stat_owner() {
    stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1"
}

# Bir yolun octal izinlerini yaz
_stat_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Bir yolun sahip GRUBUNU yaz (chown --reference GNU-only olduğundan
# _sed_inplace'te sahiplik/grup korumasını portable şekilde yeniden
# uygulamak için kullanılır — bkz. KARAR 2)
_stat_group() {
    stat -c '%G' "$1" 2>/dev/null || stat -f '%Sg' "$1"
}

# ─── KARAR 2 (denetim DALGA 4): atomik/portable 'sed -i' sarmalayıcısı ───
# GEREKÇE: repoda 26+ çıplak 'sed -i' (GNU-only, macOS BSD sed'de '-i' AYRI
# bir argüman ister — burada çalıştırılmıyor olsa da portable helper istendi)
# ve 1 adet 'sed -i.bak' vardı. 'sed -i.bak' deseni users.acl.bak,
# .credentials.bak, srvctl.conf.bak gibi SIR İÇEREN kalıcı yedek dosyaları
# bırakır — yedek/exclude listeleri (tests/test_backup_excludes_creds.sh)
# '.credentials'ı bilir ama '*.bak' türevlerini BİLMEZ. Ayrıca GNU 'sed -i'
# bile atomik DEĞİLDİR (bazı durumlarda dosyayı yerinde truncate+write eder) —
# 'users.acl'/'sshd_config' gibi eşzamanlı okunan dosyalarda yarım-yazılmış
# içerik riski taşır.
# STRATEJİ: geçici dosyaya yaz → sed BAŞARILIYSA orijinalin mod/sahip/grubunu
# (chown/chmod --reference GNU-only olduğundan _stat_mode/_stat_owner/
# _stat_group ile PORTABLE biçimde) uygula → aynı dizinde 'mv' ile ATOMİK
# olarak üzerine al. sed BAŞARISIZSA geçici dosya silinir, ORİJİNALE
# DOKUNULMAZ, 1 döner — çağıran '|| true' ile mi yoksa 'set -e' ile mi
# durdurulacağına karar verir (H5 bulgusu: eskiden 'sed -i.bak ... && rm'
# zincirinin dönüş değeri hiç kontrol edilmiyordu).
# Kullanım: _sed_inplace <dosya> <sed argümanları...>  (ör. -e 's|a|b|')
_sed_inplace() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 1
    local mode owner group tmp
    mode="$(_stat_mode "$file")" || mode=""
    owner="$(_stat_owner "$file")" || owner=""
    group="$(_stat_group "$file")" || group=""
    tmp="$(mktemp "${file}.srvctl.XXXXXX")" || return 1
    if sed "$@" "$file" > "$tmp"; then
        # set -e altında '[[ ]] && cmd' ifadesinin kendisi 0/1 dönebilir —
        # koşul YANLIŞSA (mode/owner boşsa) '|| true' olmadan script ölürdü.
        { [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null; } || true
        { [[ -n "$owner" && -n "$group" ]] && chown "${owner}:${group}" "$tmp" 2>/dev/null; } || true
        mv -f -- "$tmp" "$file"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

# ─── Geri kalan doğrulayıcılar ───

# Domain adı: harf/rakam ile başlar-biter, içeride .-, '..'/'/'/baştaki nokta yok, ≤253
validate_domain() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    (( ${#name} <= 253 )) || return 1
    [[ "$name" == *".."* ]] && return 1
    [[ "$name" == *"/"* ]] && return 1
    [[ "$name" == "."* ]] && return 1
    [[ "$name" == *"."* ]] && [[ "$name" == *".-"* ]] && return 1
    [[ "$name" == *"-."* ]] && return 1
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

# Güvenli tanımlayıcı (DB adı/kullanıcı): yalnız harf/rakam/alt-çizgi
assert_safe_ident() {
    [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

# PHP versiyonu: N.N
assert_php_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]
}

# nginx regex token: yalnız [A-Za-z0-9_./|-]; {,},;,boşluk,newline yasak
assert_regex_safe() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    [[ "$v" == *"{"* || "$v" == *"}"* || "$v" == *";"* ]] && return 1
    [[ "$v" =~ [[:space:]] ]] && return 1
    # Backslash'a da izin ver (regex escape'i; örn. DEFAULT_SENSITIVE_PATHS'teki
    # 'wp-login\.php'). Tehlikeli nginx-config karakterleri ({ } ; boşluk) zaten
    # yukarıda reddedildi. NOT: eski '[...\|...]' backslash'ı değil escape'li pipe'ı
    # kabul ediyordu → default her zaman reddedilip "Geçersiz SENSITIVE_PATHS" uyarısı
    # veriyordu. Char class'ta literal backslash için '\\', değişkenle veriyoruz.
    local re='^[A-Za-z0-9_./|\\-]+$'
    [[ "$v" =~ $re ]]
}

# Linux kullanıcı adı: [a-z_] ile başlar, [a-z0-9_-], ≤32
validate_username() {
    local v="$1"
    (( ${#v} <= 32 )) || return 1
    [[ "$v" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

# IPv4/IPv6/CIDR
validate_ip_or_cidr() {
    local v="$1" addr="$1" prefix="" max=""
    [[ -n "$v" ]] || return 1
    if [[ "$v" == */* ]]; then
        addr="${v%/*}"; prefix="${v#*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    fi
    # IPv4?
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local o
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( o <= 255 )) || return 1
        done
        max=32
    # IPv6? (kabaca: hex grupları ve :: kısaltması)
    elif [[ "$addr" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ || "$addr" =~ ^::1$ || "$addr" =~ ^([0-9a-fA-F]{0,4}:)+:?([0-9a-fA-F]{0,4})$ ]]; then
        max=128
    else
        return 1
    fi
    if [[ -n "$prefix" ]]; then
        (( prefix <= max )) || return 1
    fi
    return 0
}

# Ülke kodu: 2 büyük harf
validate_country() {
    [[ "$1" =~ ^[A-Z]{2}$ ]]
}

# ─── Git repo URL güvenlik kapısı (PREDİKAT: 0=güvenli 1=güvensiz; exit YOK) ───
# KONSOLİDASYON (DALGA 7): bu predikat DALGA 5'te lib/deploy.sh'ta
# '_deploy_validate_repo_url' olarak yazıldı; DALGA 6'da lib/plugin.sh'a
# '_plugin_validate_source' ve lib/selfupdate.sh'a '_selfupdate_validate_repo_url'
# adlarıyla BİREBİR KOPYALANDI (üç modül de kullanıcı/config kaynaklı bir URL'i
# doğrudan 'git clone'a geçiriyor). Üç kopya = ayrışma riski (biri düzeltilip
# diğer ikisi unutulabilir) — core.sh HER ZAMAN ilk source edildiğinden tek
# doğruluk kaynağı burasıdır. Yalnız https://, ssh://, git@host:path şemaları
# kabul edilir; git transport helper'ları ('ext::', 'fd::', 'file::' — kabuk
# komutu çalıştırabilen RCE vektörleri), baştaki '-' (option-injection),
# boşluk ve çıplak '::' reddedilir.
# GERİYE UYUMLULUK: lib/deploy.sh/lib/plugin.sh/lib/selfupdate.sh KENDİ
# '_deploy_validate_repo_url'/'_plugin_validate_source'/
# '_selfupdate_validate_repo_url' kopyalarını hâlâ kullanıyor (bu dosyaların
# sahibi biz değiliz, kırılmasınlar diye dokunulmadı) — bu üç fonksiyonun
# gövdesini buraya delege etmesi devredilen bir iştir (bkz. rapor).
validate_git_url() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    [[ "$url" == -* ]] && return 1
    [[ "$url" =~ [[:space:]] ]] && return 1
    [[ "$url" == *"::"* ]] && return 1
    [[ "$url" == file://* ]] && return 1
    [[ "$url" =~ ^https://[A-Za-z0-9._~:/@%?=\&-]+$ ]] && return 0
    [[ "$url" =~ ^ssh://[A-Za-z0-9._~:/@%-]+$ ]] && return 0
    [[ "$url" =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$ ]] && return 0
    return 1
}

# ─── Katı key=value okuyucu (ASLA source/eval) ───
# Kullanım: read_kv_file <dosya> KEY1 KEY2 ...
# Her KEY için: ^KEY= ile eşleşen İLK satırı bul, ilk '='ten sonrasını
# (ham, tırnak çözmeden) global KEY değişkenine ata. Eksik anahtar → değişkene
# dokunma. Her durumda 0 döner. Komut-subst/eval ASLA tetiklenmez.
# O1 DÜZELTMESİ (denetim DALGA 4): yorum '^KEY=' diyordu ama eşleşme
# 'grep -F "${k}="' idi — SATIR BAŞINA SABİTLENMEMİŞTİ, oysa write_meta()
# aynı anahtarı SİLERKEN 'grep -v "^${key}="' ile SABİTLİ arıyordu (asimetri).
# Web-yazılabilir (henüz hardened olmayan) bir meta/credentials dosyasına
# saldırgan başına boşluk eklenmiş bir satır (' FRAMEWORK=laravel') yazarsa:
# eski davranışta bu satır YİNE okunuyordu (grep -F satır içinde herhangi
# yerde arar) ama write_meta onu SİLEMİYORDU (anchor'lı grep -v eşleşmiyor) —
# harden-fs dosyayı root:root yapsa bile İÇERİK temizlenmediğinden zehirlenme
# KALICI oluyordu. Şimdi okuma da SATIR BAŞINA sabit (grep -E "^${k}=") —
# böyle bir satır artık HİÇ okunmaz (zararsız, ölü satır olarak kalır) ve
# okuma/yazma sahiplik politikası simetrik hale gelir. assert_safe_ident ile
# anahtar adı da doğrulanır (çağıranlar hep sabit [A-Za-z0-9_]+ anahtar
# kullanır — bu yalnızca gelecekte yanlış kullanım/regex meta-karakter
# enjeksiyonuna karşı savunma katmanıdır).
read_kv_file() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    local k line
    for k in "$@"; do
        assert_safe_ident "$k" || { warn "read_kv_file: geçersiz anahtar adı reddedildi: '${k}'"; continue; }
        line="$(grep -E "^${k}=" "$file" 2>/dev/null | head -1)" || true
        [[ -n "$line" ]] || continue
        # İlk '='ten sonrasını ata — komut-substitution YOK (printf -v atama)
        printf -v "$k" '%s' "${line#*=}"
    done
    return 0
}

# ─── Sahiplik kapısı (PREDIKAT: 0=güvenli 1=güvensiz; exit YOK) ───
# <path> ve ${WEB_ROOT}'a kadar (dahil) tüm üst dizinler root sahipli,
# symlink değil ve grup/diğer-yazılabilir değil mi? Değilse 1 döner.
assert_root_owned_path() {
    local path="$1"
    [[ -e "$path" ]] || return 1

    local cur="$path"
    # WEB_ROOT'un kanonik kökü; döngü buraya gelince dahil edip durur.
    local stop
    stop="$(cd "${WEB_ROOT}" 2>/dev/null && pwd -P)" || return 1

    while :; do
        # symlink olmamalı (dosya veya ara dizin)
        [[ -L "$cur" ]] && return 1

        local owner mode
        owner="$(_stat_owner "$cur")" || return 1
        mode="$(_stat_mode "$cur")"   || return 1
        [[ "$owner" == "root" ]] || return 1
        # grup-yazılabilir (mod & 020) veya diğer-yazılabilir (mod & 002) yasak.
        # mode son iki octal hanesi: grup, diğer.
        local last2="${mode: -2}"
        local grp="${last2:0:1}" oth="${last2:1:1}"
        (( (grp & 2) == 0 )) || return 1
        (( (oth & 2) == 0 )) || return 1

        # WEB_ROOT köküne ulaştıysak (onu da kontrol ettik) bitir.
        local curp
        curp="$(cd "$(dirname "$cur")" 2>/dev/null && pwd -P)/$(basename "$cur")" 2>/dev/null || curp="$cur"
        [[ "$cur" == "$stop" || "$curp" == "$stop" ]] && return 0

        local parent
        parent="$(dirname "$cur")"
        [[ "$parent" == "$cur" ]] && return 0   # '/'a ulaştık (WEB_ROOT'tan yukarı çıkma)
        cur="$parent"
    done
}

# ─── Per-domain "hardened" durum dizini (root-only) ───
SRVCTL_STATE_DIR="${SRVCTL_STATE_DIR:-${SRVCTL_ROOT}/state}"

# Domain T1 modeline geçmiş mi? (marker root-only state dosyası)
_domain_is_hardened() {
    [[ -f "${SRVCTL_STATE_DIR}/${1}/hardened" ]]
}

# Sahiplik politikası (PREDİKAT: 0=devam, 1=tamper, 2=eksik → çağıran error eder).
# root-owned değilse (bu hem "dosya hiç yok" hem "dosya var ama sahiplik/izin
# bozuk" anlamına gelebilir — assert_root_owned_path ikisini de AYNI '1' ile
# bildirir, bkz. o fonksiyonun başlık yorumu): hardened domain'de fail-closed
# reddedilir, migrate edilmemiş domain'de yalnız warn + 0 (devam).
#
# GÜVENLİK DENETİMİ EKİ (KUSUR 2 — designwestgate.art HOST bulgusu): fail-
# closed dalı ARTIK TEK bir '1'e İNDİRGENMİYOR. Öncesinde read_credentials/
# read_meta bu dalın HER iki alt-durumuna da "root-owned değil (tamper)."
# diyordu — ama üretimde 'designwestgate.art' için gerçek durum TAMPER
# DEĞİLDİ: '.credentials' eski bir srvctl sürümünde HİÇ YAZILMAMIŞTI.
# Operatör bu mesajı görünce sunucusunda kötü niyetli bir müdahale olduğunu
# sanırdı (yanlış alarm) — ve bu, gerçek bir tamper olayının ciddiyetini de
# aşındırırdı. Çağıranın DOĞRU mesajı basabilmesi için "hiç yok" (2) ile
# "var ama bozuk" (1) burada ayrıştırılıyor. NOT: assert_root_owned_path'İN
# KENDİSİ DEĞİŞMEDİ — paylaşılan bir yardımcı (bkz. lib/plugin.sh; ayrıca
# tests/test_assert_root_owned.sh açıkça "yok" durumunun da '1' (fail)
# saydığını kilitliyor) ve o tüketiciler için missing/tamper'ı AYNI
# reddetmek zaten doğru davranış — ayrım yalnız BU özel (hardened-domain)
# karar noktasında, çağırana ek bilgi olarak yapılıyor.
#
# warn() ARTIK KENDİLİĞİNDEN stderr'e yazar (KARAR 1) — elle '>&2' gerekmez.
_require_owned_or_warn() {
    local domain="$1" file="$2"
    assert_root_owned_path "$file" && return 0
    if _domain_is_hardened "$domain"; then
        if [[ -e "$file" ]]; then
            return 1   # var ama sahiplik/izin bozuk → gerçek tamper
        fi
        return 2       # hiç yok → eksik (tamper DEĞİL — bkz. yukarı)
    fi
    warn "Domain '${domain}' henüz hardened değil — 'srvctl security harden-fs ${domain}' önerilir"
    return 0
}

# ─── Güvenli FS oluşturma (umask 077 altında) ───
# chown macOS dev kutusunda başarısız olabilir → guard'lı; mod/varlık test edilir.
#
# 3. parametre 'owner' (İSTEĞE BAĞLI, varsayılan 'root:root' — TÜM mevcut
# çağrı yerleri GERİYE DÖNÜK UYUMLU kalır, hiçbiri 3. argüman VERMEZ): bazı
# kaynaklar (ör. lib/deploy.sh:_deploy_lock_dir / lib/cron.sh:_cron_lock_dir
# — domain başına deploy kilidi dizini) kasıtlı olarak root DIŞINDA bir
# sahibe (domain'in web_<sname> kullanıcısı) ait olmalı; bu tür kaynaklar
# İÇİN chown hedefi PARAMETRELENDİRİLDİ. Genel amaç (root-owned sır/durum
# dosyaları) DEĞİŞMEDİ — yalnızca ihtiyaç duyan ÇAĞIRAN taraf farklı bir
# sahip isteyebilir.
# ─── SYMLINK FAIL-CLOSED (KRİTİK — canlı üretimde SÖMÜRÜLEBİLİRLİĞİ
#     KANITLANMIŞ ayrıcalık yükseltme sınıfı) ───
#
# ÖLÇÜLEN SALDIRI (Ubuntu 24.04, gerçek e-ticaret sunucusu, web_<sname>
# kullanıcısı olarak): kilit dizini domain kullanıcısına ait (700
# web_x:web_x) olduğundan o kullanıcı dizin İÇİNDE unlink+create yapabiliyor;
# kilit dosyasını silip yerine '/etc/ld.so.preload' gibi KEYFİ bir hedefe
# sembolik bağ koyabiliyordu. Ardından root olarak çalışan srvctl
#   secure_file "$lock_path" 600 "web_x:web_x"
# çağrısı sembolik bağı DEREFERENCE ederek:
#   * 'touch'  → hedef YOKSA root olarak YARATIYOR,
#   * 'chmod'  → HEDEFİN modunu değiştiriyor,
#   * 'chown'  → HEDEFİ SALDIRGANA VERİYOR ('chown -h' değildi)
# yani keyfi dosya sahipliği + (çağıranın 'exec 9>' açışıyla birlikte) keyfi
# dosya truncate primitifi sunuyordu. '/etc/ld.so.preload' hedeflenirse TAM
# ROOT; '/etc/shadow' hedeflenirse hesap kilidi.
#
# ⚠ DAVRANIŞ DEĞİŞİKLİĞİ (belgelenmiştir — mevcut çağrı yerleri taranmıştır):
#   Hedef yolun KENDİSİ bir sembolik bağ ise secure_file/secure_dir ARTIK
#   HİÇBİR ŞEY YAPMAZ: 'warn' basar ve 1 DÖNER (fail-closed). Bu, yapısal
#   olarak SEMBOLİK BAĞ ÜZERİNDEN mod/sahiplik uygulanmasını İMKÂNSIZ kılar.
#   Repodaki 34 çağrı yerinin TAMAMI (plugin/init/domain/backup/security/
#   selfupdate/webhook/cron/deploy) GERÇEK dosya-dizin hedefler; hiçbiri
#   kasıtlı olarak bir sembolik bağa yazmaz. Bilinen TEK gri alan: operatör
#   'BACKUP_DIR'i (varsayılan '/backups') bir mount noktasına SEMBOLİK BAĞ
#   yapmışsa 'srvctl backup'/'srvctl init' artık uyarıp durur — çözüm,
#   conf/srvctl.conf'ta BACKUP_DIR'e GERÇEK yolu yazmaktır (belgelenen desen
#   zaten budur, bkz. README).
#
# Ayrıca 'chown' → 'chown -h': sembolik bağ kontrolü ile açılış arasındaki
# (teorik) yarış penceresinde bile chown ARTIK hedefi DEĞİL bağın KENDİSİNİ
# değiştirir — dereference primitifi kökten yok edilir. ('chmod'un portable
# bir '-h' karşılığı YOKTUR; bu yüzden kontrol chmod'dan hemen ÖNCE tekrar
# yapılır ve asıl savunma, kilit ağacında dizinin artık domain kullanıcısına
# YAZILABİLİR OLMAMASIDIR — bkz. _srvctl_lock_ensure.)
#
# GÖRÜNÜRLÜK (güvenlik denetimi — "sessiz fail-closed" düzeltmesi): red
# ARTIK 'warn' DEĞİL 'security_event' ile bildirilir. Fark, olayın srvctl
# olay günlüğüne de DÜŞMESİDİR: reddin kendisi doğru davranıştı ama olay
# terminal kapandığında BUHARLAŞIYORDU (ölçüldü: srvctl.log'a 0 satır).
# Ayrıca bağın HEDEFİ de yazılır — operatörün ihlali inceleyebilmesi için
# "hangi dosyaya yönlendirilmek istendi" bilgisi ZORUNLUDUR.
_reject_symlink() {
    local path="$1" kind="$2"
    [[ -L "$path" ]] || return 0
    local target=""
    target=$(readlink "$path" 2>/dev/null) || target=""
    security_event "SEMBOLİK BAĞ REDDEDİLDİ (${kind}): '${path}' bir sembolik bağ${target:+ → hedef: '${target}'} — mod/sahiplik uygulaması YAPILMADI. Bu, root'a KEYFİ bir dosyayı chown/truncate ettirme girişimi olabilir; ilgili domain için 'srvctl domain repair <domain>' çalıştırın ve hedef dosyanın sahipliğini/içeriğini DOĞRULAYIN."
    return 1
}

secure_file() {
    local path="$1" mode="${2:-600}" owner="${3:-root:root}"
    # KAPI 1: 'touch'tan ÖNCE — sarkan (dangling) bir bağda 'touch' HEDEFİ
    # YARATIRDI; kontrol bu yüzden HER ŞEYDEN önce gelir.
    _reject_symlink "$path" "dosya" || return 1
    # Dosyayı oluştur (yoksa) — MEVCUT içeriği KORU. 'touch' truncate ETMEZ;
    # (eski ': >' mevcut dosyayı boşaltıyordu → yazımdan sonra çağrılınca içerik
    #  kaybı: /root/.my.cnf, yedek artefaktları, migrate credentials).
    ( umask 077; touch "$path" 2>/dev/null || true )
    [[ -e "$path" ]] || { umask 077; touch "$path" || return 1; }
    # KAPI 2: chmod dereference ettiğinden, touch ile chmod ARASINDAKİ
    # pencereye karşı tekrar bak (TOCTOU daraltma).
    _reject_symlink "$path" "dosya" || return 1
    chmod "$mode" "$path" || return 1
    chown -h "$owner" "$path" 2>/dev/null || true
    return 0
}

secure_dir() {
    local path="$1" mode="${2:-700}" owner="${3:-root:root}"
    _reject_symlink "$path" "dizin" || return 1
    ( umask 077; mkdir -p "$path" ) || return 1
    _reject_symlink "$path" "dizin" || return 1
    chmod "$mode" "$path" || return 1
    chown -h "$owner" "$path" 2>/dev/null || true
    return 0
}

# ═══════════════════════════════════════════════════════════════════
#  DEPLOY/CRON KİLİT AĞACI — TEK KAYNAK (drift KÖKTEN engellenir)
# ═══════════════════════════════════════════════════════════════════
# ESKİDEN bu formül İKİ YERDE (lib/deploy.sh:_deploy_lock_dir ve
# lib/cron.sh:_cron_lock_dir) AYRI AYRI yazılıydı ("çapraz modül bağımlılığı
# kurmamak" gerekçesiyle). İkisi de AYNI güvenlik hatasını taşıyordu ve bir
# düzeltmenin ikisine BİRDEN uygulanması operatöre/teste bırakılmıştı. Bu
# fonksiyonlar core.sh'a taşındı: core.sh HER modülden ÖNCE ve KOŞULSUZ
# source edilir (bin/srvctl:_load_and_run) — yani çapraz modül 'source'
# sorunu (exit 127) HİÇ DOĞMAZ ve İKİ formülün sürüklenmesi YAPISAL olarak
# imkânsızlaşır.
#
# İZİN MODELİ (KRİTİK GÜVENLİK DÜZELTMESİ — bkz. _reject_symlink başlığındaki
# sömürü zinciri):
#   1) <base>                    711 root:root   — yalnız GEÇİŞ (listeleme YOK)
#   2) <base>/locks              711 root:root   — FPM'in pid dosyalarından
#                                                  ad alanı ayrımı
#   3) <base>/locks/<sname>      710 root:web_<sname>
#        root: rwx | grup (web_<sname>): --x | diğer: ---
#        ⚠ ESKİDEN '700 web_<sname>:web_<sname>' idi. Dizinin SAHİBİ domain
#        kullanıcısı olduğu için o kullanıcı dizin içinde UNLINK + CREATE
#        yapabiliyordu → kilit dosyasını silip yerine sembolik bağ koyma
#        primitifi (canlı üretimde KANITLANDI). Artık dizinde 'w' biti YOK:
#        domain kullanıcısı dosyayı SİLEMEZ, YERİNE BAŞKA BİR ŞEY KOYAMAZ;
#        'x' (traverse) biti ile dizinden GEÇEBİLİR (open() bunun için
#        yeterlidir), 'r' biti OLMADIĞI için LİSTELEYEMEZ. BAŞKA domainlerin
#        kullanıcıları 'diğer: ---' ile TAMAMEN dışarıdadır — domainler arası
#        izolasyon KORUNUR.
#   4) <base>/locks/<sname>/deploy-<sname>.lock  660 root:web_<sname>
#        ⚠ Dosya ROOT tarafından ÖN-OLUŞTURULUR ve root'a ait KALIR.
#
# ÖLÇÜLEN GERÇEK — flock(1) dosyayı HANGİ kiple açar?
#   util-linux 'sys-utils/flock.c', open_file():
#       int fl = *flags == 0 ? O_RDONLY : *flags;
#       fl |= O_NOCTTY | O_CREAT;
#       fd = open(filename, fl, 0666);
#   Yani VARSAYILAN açış 'O_RDONLY | O_CREAT | O_NOCTTY' (0666) — 'O_RDWR'
#   DEĞİL. (v2.37.2 = Ubuntu 22.04 ve v2.39.3 = Ubuntu 24.04 etiketlerinde
#   BİREBİR AYNI kod — kaynaktan doğrulandı, tahmin DEĞİL. 'O_RDWR' yalnızca
#   flock() EIO/EBADF döndüren NFS yolunda, 'access(file, R_OK|W_OK)'
#   başarılıysa YENİDEN AÇMA olarak devreye girer.)
#   SONUÇLARI:
#     (a) Mevcut bir dosya için domain kullanıcısına 'r' YETER; 660 verilmesi
#         yalnız yukarıdaki NFS geri çekilme yolunu ve AppArmor 'rwk'
#         kuralıyla tutarlılığı korumak İÇİNDİR (fazladan bir yetenek
#         AÇMAZ — dizinde 'w' olmadığından dosya SİLİNEMEZ/DEĞİŞTİRİLEMEZ,
#         yalnız İÇERİĞİ yazılabilir; kilit dosyasının içeriği zaten
#         anlamsızdır, flock yalnız fd'yi kullanır).
#     (b) O_CREAT HER ZAMAN verilir. Dizin artık domain kullanıcısına
#         YAZILABİLİR OLMADIĞINDAN, dosya YOKSA flock(1) onu ARTIK
#         OLUŞTURAMAZ (EACCES). Bu yüzden kilit dosyasını ROOT'un ÖNCEDEN
#         yaratması ZORUNLUDUR — bu fonksiyon tam olarak bunu garanti eder
#         ve HEM _deploy_lock_dir HEM _cron_lock_dir bunu çağırır.
#   ÜRETİMDE '644 web_x:web_x' GÖRÜLMESİNİN AÇIKLAMASI: secure_file 600
#   istediği hâlde diskte 644 ölçüldü çünkü dosyayı orada secure_file DEĞİL,
#   cron job'unun KENDİ flock(1) çağrısı yaratmıştı: O_CREAT mode 0666 &
#   ~umask(022) = 0644, sahibi de süreci çalıştıran web_x. Yani deploy'lar
#   arasında dosya SİLİNİP domain kullanıcısı tarafından YENİDEN
#   yaratılabiliyordu — sömürünün 'rm -f' adımının doğrudan kanıtı. Yeni
#   modelde bu mümkün DEĞİL.

# Saf yol hesapları (YAN ETKİSİZ — mkdir/chmod YAPMAZ; test edilebilir).
_srvctl_lock_dir_path() {
    printf '%s/locks/%s' "${SRVCTL_LOCK_DIR:-/run/srvctl}" "$1"
}
_srvctl_lock_file_path() {
    printf '%s/locks/%s/deploy-%s.lock' "${SRVCTL_LOCK_DIR:-/run/srvctl}" "$1" "$1"
}

# Kilit ağacını güvenli izinlerle KURAR/ONARIR ve domain alt dizininin
# YOLUNU stdout'a yazar. Başarısızlıkta 1 döner ve stdout'a HİÇBİR ŞEY
# yazmaz — çağıran fail-closed davranmalıdır.
#
# GÖRÜNÜRLÜK SÖZLEŞMESİ (güvenlik denetimi düzeltmesi): HİÇBİR başarısızlık
# dalı SESSİZ DEĞİLDİR. Eskiden her adım çıplak '|| return 1' idi; symlink
# dalında en azından _reject_symlink konuşuyordu, ama mkdir/chmod'un
# başarısız olduğu dallarda operatöre yalnız ham 'mkdir: ...' satırı
# ulaşıyor, srvctl loguna HİÇBİR iz düşmüyordu. Artık HANGİ adımın
# düştüğü hem stderr'e hem olay günlüğüne yazılır.
_srvctl_lock_ensure() {
    local sname="$1" web_user="$2"
    local base="${SRVCTL_LOCK_DIR:-/run/srvctl}"
    local dom_dir; dom_dir=$(_srvctl_lock_dir_path "$sname")
    local lock_file; lock_file=$(_srvctl_lock_file_path "$sname")

    secure_dir "$base" 711 \
        || { security_event "Kilit ağacı KURULAMADI (adım 1/4 — taban dizin): '${base}'"; return 1; }
    secure_dir "${base}/locks" 711 \
        || { security_event "Kilit ağacı KURULAMADI (adım 2/4 — locks dizini): '${base}/locks'"; return 1; }
    # 710 root:web_<sname> — sahiplik ROOT'ta; domain kullanıcısına yalnız
    # GEÇİŞ (--x) hakkı kalır (unlink/create YOK).
    secure_dir "$dom_dir" 710 "root:${web_user}" \
        || { security_event "Kilit ağacı KURULAMADI (adım 3/4 — domain kilit dizini): '${dom_dir}'"; return 1; }
    # Kilit dosyası ROOT tarafından ÖN-OLUŞTURULUR (flock(1) artık kendisi
    # yaratamaz — yukarıdaki (b) maddesi).
    secure_file "$lock_file" 660 "root:${web_user}" \
        || { security_event "Kilit ağacı KURULAMADI (adım 4/4 — kilit dosyası): '${lock_file}'"; return 1; }

    printf '%s' "$dom_dir"
    return 0
}

# ─── Güvenli arşiv çıkarma (tar/zip-slip + symlink/hardlink reddi) ───
# Çıkarmadan ÖNCE üyeleri listeler; mutlak yol (/), '..' veya symlink/hardlink
# üye varsa HİÇ çıkarmadan 1 döner. Aksi halde dest_dir içine çıkarır, 0 döner.
safe_extract() {
    local archive="$1" dest="$2"
    [[ -f "$archive" ]] || return 1
    [[ -n "$dest" ]] || return 1

    # Verbose listele: 1. sütun mod dizgesi ('l'=symlink, 'h'=hardlink), son sütun ad.
    local listing
    listing="$(tar -tvzf "$archive" 2>/dev/null)" || return 1
    [[ -n "$listing" ]] || return 1

    # Sadece üye adları (mutlak/.. kontrolü için): -tzf isim-bazlı liste.
    local names
    names="$(tar -tzf "$archive" 2>/dev/null)" || return 1

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # Mutlak yol
        [[ "$name" == /* ]] && return 1
        # '..' bileşeni (yol içinde herhangi yerde)
        [[ "$name" == ".." || "$name" == "../"* || "$name" == *"/../"* || "$name" == *"/.." ]] && return 1
    done <<< "$names"

    # Symlink/hardlink üyesi: verbose mod dizgesinin ilk karakteri 'l' veya 'h'.
    local line firstchar
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        firstchar="${line:0:1}"
        [[ "$firstchar" == "l" || "$firstchar" == "h" ]] && return 1
    done <<< "$listing"

    # Güvenli: hedefe çıkar.
    mkdir -p "$dest" || return 1
    tar -xzf "$archive" -C "$dest" || return 1
    return 0
}

# Root kontrolü
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Bu komut root yetkisi gerektirir. Kullanım: sudo srvctl $*"
    fi
}

# Domain adından güvenli kullanıcı adı üret
# example.com → example_com
safe_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]'
}

# Domain varlığını kontrol et
# Domain var mı? (PREDIKAT: 0=var, 1=yok/geçersiz)
# validate_domain kapısı BURADA: neredeyse her komut yalnız domain_exists'e
# güveniyordu, o da '../..' içeren girdiyi memnuniyetle kabul ediyordu
# (örn. 'domain remove ../../var/log' → rm -rf /var/www/../../var/log).
# Tek noktadan kapatmak tüm çağrı yerlerini birden korur.
domain_exists() {
    local domain="$1"
    validate_domain "$domain" || return 1
    [[ -d "${WEB_ROOT}/${domain}" ]]
}

# Güçlü şifre üret
generate_password() {
    local length="${1:-24}"
    openssl rand -base64 48 | tr -d '/+=\n' | head -c "$length"
}

# PHP versiyonunun kurulu olup olmadığını kontrol et
php_version_exists() {
    local ver="$1"
    [[ -x "/usr/sbin/php-fpm${ver}" ]] || [[ -f "/etc/php/${ver}/fpm/php-fpm.conf" ]]
}

# Nginx config test
nginx_test() {
    if ! nginx -t 2>/dev/null; then
        error "Nginx yapılandırma hatası! 'nginx -t' ile kontrol edin."
    fi
}

# Onay iste
confirm() {
    local message="${1:-Devam etmek istiyor musunuz?}"
    read -rp "  ${message} (evet/hayır): " answer
    [[ "$answer" == "evet" ]]
}

# Template dosyasını işle — değişkenleri yerine koy
# Kullanım: render_template template.tpl VAR1=value1 VAR2=value2
#
# GERÇEK ÜRETİM SUNUCUSUNDA İZOLE EDİLEN KUSUR: 'srvctl cron add ...
# --command="echo bir && echo iki"' 'beslenmeyen token kaldı ({{CRON_
# COMMAND}})' hatasıyla EXIT=1 veriyordu; '&' içermeyen komutlar sorunsuzdu.
# DOĞRULAMA: bu fonksiyon repo tarihi boyunca (repo init'ten beri) 'sed'
# HİÇ KULLANMADI — her zaman saf bash parametre genişletmesi
# ('${content//pattern/replacement}') kullandı, bu yüzden sed'in DEĞİŞTİRME
# tarafındaki '&' (= "eşleşen metnin tamamı") tuzağı BU FONKSİYONDA HİÇ
# MEVCUT OLMADI (ampirik doğrulandı: gerçek şablon + gerçek escape
# fonksiyonlarıyla '&&' içeren değer sorunsuz render edildi) — üretimdeki
# kurulum muhtemelen bu repodan senkronize DEĞİLDİ (bkz. CLAUDE.md 'Repo ≠
# kurulum'; 'sudo bash install.sh' çalıştırılmamış bir /usr/local/srvctl,
# eski/farklı bir render_template taşıyor olabilir).
#
# YİNE DE İKİ GERÇEK SORUN BURADA GİDERİLDİ:
#   1) SAĞLAMLIK: '${content//pattern/replacement}' bash'in KENDİ glob
#      motoruna bel bağlar — REPLACEMENT tarafı bugün zararsız olsa da
#      "değeri bir yerine-koyma motoruna teslim etme" deseni sed ile AYNI
#      RİSK SINIFIDIR (bkz. bash sürüm/'extglob' farklılıkları). Artık DEĞER
#      hiçbir yorumlayıcıya (ne sed ne bash glob) teslim EDİLMİYOR — aşağıdaki
#      awk yardımcısı SAF 'index()'/'substr()' ile bayt-bayt arama/birleştirme
#      yapar (regex/backreference/glob YOK); '&', '\', '|', '$', backtick,
#      tek/çift tırnak DAHİL HİÇBİR karakter özel yorumlanmaz.
#   2) PERFORMANS (100 domain hedefi): ÖLÇÜLDÜ — macOS bash 3.2'de (test
#      ortamı) eski '${content//pattern/replacement}' döngüsü 16KB'lık TEK
#      bir systemd şablonunda (11 token) TEK ÇAĞRI başına ~1.7 saniyeye kadar
#      çıkıyordu; 100 domain'lik bir 'security audit'/'domain repair --all'
#      taramasında bu tolere edilemez (100 tekrarlı bir benzetim 2 dakikada
#      BİLE bitmedi). AWK'nin string motoru AYNI şablon için render_template
#      ÇAĞRISI başına ~10ms mertebesindedir (bkz. tests/test_render_perf.sh)
#      — token sayısından BAĞIMSIZ TEK bir alt-süreç (fork) maliyeti.
#
# GÜVENLİ VERİ AKTARIMI (bash → awk): değerler awk'ye '-v ad=değer' İLE
# DEĞİL, ortam değişkenleri (ENVIRON) ile aktarılır — POSIX awk '-v'
# atamasında değer İÇİN kaçış dizisi ('\n','\t','\\', ...) çözümlemesi
# YAPAR (ör. değerde LİTERAL iki karakterlik '\n' varsa '-v' bunu GERÇEK bir
# satırsonuna çevirirdi — CRLF-reddi korumasını BYPASS eden yeni bir
# enjeksiyon sınıfı). 'ENVIRON["..."]' ise işletim sisteminin environ'ından
# DOĞRUDAN, HİÇBİR kaçış çözümlemesi OLMADAN okunur (POSIX/gawk/mawk/bwk-awk
# hepsinde aynı) — değerler 'env "AD=değer" awk ...' ÖN-EKİYLE (mevcut
# desen, bkz. lib/deploy.sh) yalnızca O TEK awk alt-sürecinin ortamına
# yazılır; kalıcı shell ortamı KİRLENMEZ, 'export'/'unset' çifti GEREKMEZ.
# Boş '$@' durumunda 'env_pairs' dizisinin genişlemesi CLAUDE.md'nin bilinen
# bash 3.2 tuzağına ("${arr[@]}" boş dizide 'set -u' altında ÖLÜR) düşmemesi
# için 'lib/deploy.sh' İLE AYNI '${arr[@]+"${arr[@]}"}' deseniyle yapılır.
render_template() {
    local template="$1"
    shift

    if [[ ! -f "$template" ]]; then
        error "Template bulunamadı: ${template}"
    fi

    local pair key value
    local -a env_pairs=()
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        # CRLF/config-enjeksiyon koruması: değer satırsonu/CR içeremez.
        # (render-time değişmezi — bu error EXIT eder; charset doğrulaması
        #  çağıran tarafta assert_regex_safe ile yapılır.)
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
            error "render_template: '${key}' değeri satırsonu/CR içeriyor — reddedildi"
        fi
        # Savunma derinliği: token adı geçerli bir tanımlayıcı OLMALI —
        # aşağıda '_RT_VAL_<key>' biçiminde bir ortam değişkeni adına
        # gömülür; ad sağlamsa (yalnız harf/rakam/alt çizgi, rakamla
        # BAŞLAMAZ) isim çakışması/enjeksiyonu YAPISAL olarak imkansızdır.
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            error "render_template: geçersiz token adı: '${key}'"
        fi
        env_pairs+=("_RT_VAL_${key}=${value}")
    done

    local content
    content=$(env ${env_pairs[@]+"${env_pairs[@]}"} awk '
        BEGIN {
            prefix = "_RT_VAL_"
            plen = length(prefix)
            n = 0
            for (name in ENVIRON) {
                if (substr(name, 1, plen) == prefix) {
                    n++
                    key = substr(name, plen + 1)
                    pat[n] = "{{" key "}}"
                    patlen[n] = length(pat[n])
                    val[n] = ENVIRON[name]
                }
            }
        }
        {
            line = $0
            for (i = 1; i <= n; i++) {
                if (index(line, pat[i]) > 0) {
                    line = replace_literal(line, pat[i], patlen[i], val[i])
                }
            }
            print line
        }
        # SAF bayt-bayt literal degistirme -- gsub/sub KASITLI OLARAK
        # KULLANILMAZ (POSIX ERE + "&"/"\\N" geri-referans yorumlamasi
        # tasirlar; tam da sed ile AYNI risk sinifi). index()/substr()
        # yalniz duz alt-dizge arar/birlestirir, HICBIR karakteri
        # yorumlamaz.
        function replace_literal(s, pat, plen, rep,    result, idx) {
            result = ""
            while ((idx = index(s, pat)) > 0) {
                result = result substr(s, 1, idx - 1) rep
                s = substr(s, idx + plen)
            }
            return result s
        }
    ' "$template") || error "render_template: awk render başarısız: ${template}"

    echo "$content"
}

# Servis durumunu kontrol et
service_is_active() {
    systemctl is-active "$1" > /dev/null 2>&1
}

# Tüm domain'leri listele (sadece isimler)
# WEB_ROOT altındaki SRVCTL DOMAİNLERİNİ listeler.
#
# HOST BULGUSU (Ubuntu 24.04, gerçek VM): eski hali '${WEB_ROOT}/*/' altındaki
# HER dizini domain sayıyordu. nginx paketi '/var/www/html' dizinini kendi
# kuruyor → 'srvctl security audit' onu domain sanıp sahte FAIL'ler üretti:
#   ❌ FAIL  html: chroot aktif
#   ❌ FAIL  html: AppArmor enforce DEĞİL
# Yalnız gürültü değil: 'harden-fs --all' / 'domain repair --all' /
# 'deploy prune --all' gibi TOPLU komutlar da bu sahte girdiyi işlemeye
# çalışır. Ayırt edici işaret '.credentials' olarak seçildi — 'domain add'
# her domain için root:600 olarak yazar (bkz. _domain_write_credentials);
# nginx'in html dizininde bulunmaz.
#
# GÜVENLİK DENETİMİ EKİ (REGRESYON — HOST'ta ölçüldü, Ubuntu 24.04 üretim,
# v1.0.0→v2.0.0 yükseltmesi): '.credentials' kapısı hayaletleri doğru elerken
# GERÇEK ama EKSİK-KURULMUŞ domainleri de sessizce eliyordu. Ölçülen örnek:
# 'designwestgate.art' — CANLI, HTTP 200 dönen gerçek bir domain — 'web_
# designwestgate_art' sistem kullanıcısına, FPM pool'una, nginx vhost'una
# sahipti AMA '.credentials' dosyası YOKTU (muhtemelen 'domain add' yarıda
# kesilmiş — bu dosya add akışında GEÇ yazılır). Sonuç: 'domain list' onu
# göstermiyordu, 'domain repair --all' hayalet sayıp ATLIYORDU, 'security
# audit' onu HİÇ denetlemiyordu — ve en kötüsü, AppArmor profili hiç
# oluşturulmamış olduğu halde bu durum HİÇBİR YERDE raporlanmıyordu (MAC
# korumasız canlı bir site, srvctl'in kendi körlüğü yüzünden görünmez).
#
# DÜZELTME: kapı artık İKİ YOLLU (OR) — '.credentials' VAR OLMASI YETERLİ
# (mevcut davranış KORUNDU) AMA TEK GEÇERLİ YOL DEĞİL: 'web_<sname>' Linux
# sistem kullanıcısının VARLIĞI da domain'i GERÇEK sayar. Bu ikinci sinyal
# '_domain_repair_is_ghost' (lib/domain.sh) İLE BİREBİR AYNI gerekçeye
# dayanır — o fonksiyonun başlık yorumuna bkz.: 'useradd' bu kod tabanında
# YALNIZCA '_domain_add'in ilk adımında çağrılır, 'repair' (ya da başka
# hiçbir onarım/denetim akışı) bu kullanıcıyı KENDİSİ ASLA üretemez. Yani bu
# sinyal kendi kendini doğrulayan bir döngü OLUŞTURAMAZ (nginx'in
# '/var/www/html'i yine elenir: 'web_html' diye bir sistem kullanıcısı YOK).
# Sonuç: hayaletler yine elenir, eksik-kurulmuş GERÇEK domainler artık
# görünür kalır — üç tüketici de (domain list / domain repair --all /
# security audit) AYNI genişletilmiş kümeyi görür (tek sözleşme korunur).
list_all_domains() {
    local dir name sname
    for dir in "${WEB_ROOT}"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        # Domain adı kuralına uymayan dizinleri ele (savunma derinliği)
        validate_domain "$name" || continue
        sname=$(safe_name "$name")
        # İki-yollu kapı (OR): '.credentials' VAR OLMASI YETERLİ; DEĞİLSE
        # 'web_<sname>' sistem kullanıcısının VARLIĞI da domain'i GERÇEK sayar
        # (gerekçe yukarıda). İkisi de yoksa hayalet — atla.
        if [[ -f "${dir}.credentials" ]] || id "web_${sname}" &>/dev/null; then
            printf '%s\n' "$name"
        fi
    done
}

# Credentials dosyasını oku (source DEĞİL — katı parse)
# Sahiplik kapısı: hardened domain + root-owned-değil → tamper → error (çıkış).
# Migrate edilmemiş (marker yok) → warn stderr + oku.
# O2 DÜZELTMESİ (denetim DALGA 4): read_kv_file "eksik anahtar → değişkene
# dokunma" sözleşmesine sahiptir — read_credentials KENDİSİ sıfırlamıyordu.
# 'domain repair --all' gibi bir döngüde A domaini için okunan DB_PASS/
# REDIS_PASS/PHP_VERSION GLOBAL kalıyordu; B domaininin .credentials'ı eksik/
# bozuksa bu ESKİ (A'ya ait) değerler B için SESSİZCE yeniden kullanılıyordu
# (ör. 'usr_b' parolası A'nınkiyle senkronlanırdı — kiracılar arası parola
# bulaşması). Şimdi her çağrıda ÖNCE tüm alanlar sıfırlanır, SONRA dosyadan
# okunur — eksik bir alan artık HER ZAMAN boş kalır, önceki çağrıdan miras
# KALMAZ.
read_credentials() {
    local domain="$1"
    local creds_file="${WEB_ROOT}/${domain}/.credentials"
    # GÜVENLİK DENETİMİ EKİ (KUSUR 2 — designwestgate.art): _require_owned_or_warn
    # artık "eksik" (2) ile "tamper" (1) döndürüyor (bkz. o fonksiyonun başlık
    # yorumu) — ESKİDEN ikisi de AYNI "(tamper). Okuma reddedildi." mesajını
    # basıyordu; dosya HİÇ YAZILMAMIŞ bir domain (ör. eski srvctl sürümü) için
    # bu yanlış alarmdı. 'local _co_rc=$(...)' YAZILMADI (Bash tuzağı: exit
    # status'u maskeler) — '||' ile yakalanıp ayrı bir değişkende tutuluyor.
    local _co_rc=0
    _require_owned_or_warn "$domain" "$creds_file" || _co_rc=$?
    if [[ "$_co_rc" -eq 2 ]]; then
        error "Güvenlik: ${creds_file} eksik — bu domain hardened ama '.credentials' hiç oluşturulmamış (ör. eski bir srvctl sürümünde eklenmiş domain). Bu TAMPER DEĞİL. Kurtarma: 'srvctl domain repair ${domain}' dosyayı gözlemlenen durumdan (PHP sürümü, web kullanıcısı) yeniden üretmeyi dener — DB/Redis parolası bilinmiyorsa boş bırakılır, kullanıyorsanız elle tamamlamanız gerekir."
    elif [[ "$_co_rc" -ne 0 ]]; then
        error "Güvenlik: ${creds_file} root-owned değil (tamper). Okuma reddedildi."
    fi
    DOMAIN="" SAFE_NAME="" WEB_USER="" PHP_VERSION=""
    DB_NAME="" DB_USER="" DB_PASS=""
    REDIS_USER="" REDIS_PASS="" REDIS_PREFIX=""
    read_kv_file "$creds_file" \
        DOMAIN SAFE_NAME WEB_USER PHP_VERSION \
        DB_NAME DB_USER DB_PASS \
        REDIS_USER REDIS_PASS REDIS_PREFIX
}

# Domain için doğrulanmış PHP versiyonu döndür.
# .credentials'taki PHP_VERSION yalnızca assert_php_version geçerse kullanılır,
# aksi halde verilen fallback (varsayılan DEFAULT_PHP_VERSION) döner.
# Böylece bozuk/saldırgan .credentials root'a path/komut enjekte edemez.
_derive_php() {
    local domain="$1" fallback="${2:-${DEFAULT_PHP_VERSION}}"
    local PHP_VERSION=""
    read_credentials "$domain"
    if [[ -n "${PHP_VERSION:-}" ]] && assert_php_version "${PHP_VERSION}"; then
        echo "${PHP_VERSION}"
    else
        echo "${fallback}"
    fi
}

# ─── Rate-Limit Profilleri ───
SRVCTL_RATE_PROFILES="${SRVCTL_RATE_PROFILES:-${SRVCTL_ROOT}/conf/rate-profiles.conf}"

# PHP-geneli varsayılan hassas yol regex'i (login/admin brute-force koruması)
DEFAULT_SENSITIVE_PATHS='login|admin|auth|panel|dashboard|wp-login\.php|wp-admin|user/login'

# Bir profilin conf satırını getir (yorum/boş satırlar hariç)
rate_profile_line() {
    [[ -f "$SRVCTL_RATE_PROFILES" ]] || return 1
    grep -E "^${1}:" "$SRVCTL_RATE_PROFILES" 2>/dev/null | grep -v '^#' | head -1
}

# Bir profilin N. alanını getir (1=ad 2=req_zone 3=req_burst 4=login_zone 5=login_burst 6=conn)
rate_profile_field() {
    local line
    line=$(rate_profile_line "$1") || return 1
    [[ -z "$line" ]] && return 1
    echo "$line" | cut -d: -f"$2"
}

# Tüm profil adlarını listele
rate_profile_names() {
    [[ -f "$SRVCTL_RATE_PROFILES" ]] || return 1
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$SRVCTL_RATE_PROFILES" | cut -d: -f1
}

# Geçerli profil adını döndür; geçersiz/boş ise 'standard'a düş
# (warn() zaten stderr'e yazar — stdout yalnız 'echo "$profile"' ile kirlenmez)
rate_profile_resolve() {
    local profile="$1"
    if [[ -n "$profile" && -n "$(rate_profile_line "$profile")" ]]; then
        echo "$profile"
    else
        [[ -n "$profile" ]] && warn "Bilinmeyen rate-limit profili: ${profile} — 'standard' kullanılıyor"
        echo "standard"
    fi
}

# Profili global RL_* değişkenlerine yükle
rate_profile_load() {
    local profile
    profile=$(rate_profile_resolve "$1")
    RL_PROFILE="$profile"
    RL_REQ_ZONE=$(rate_profile_field "$profile" 2)
    RL_REQ_BURST=$(rate_profile_field "$profile" 3)
    RL_LOGIN_ZONE=$(rate_profile_field "$profile" 4)
    RL_LOGIN_BURST=$(rate_profile_field "$profile" 5)
    RL_CONN=$(rate_profile_field "$profile" 6)
}

# ─── Kaynak (Resource) Profilleri — cgroups + FPM pool boyutlandırma ───
# Sözleşme (conf/resource-profiles.conf, ops-infra sahipliğinde):
#   profil:pm_mode:max_children:memory_limit_mb:tasks_max
# ör. "ecommerce:dynamic:16:512:300". Bu format DEĞİŞTİRİLMEZ; rate_profile_*
# desenin BİREBİR kardeşidir (aynı dosya/stil).
SRVCTL_RESOURCE_PROFILES="${SRVCTL_RESOURCE_PROFILES:-${SRVCTL_ROOT}/conf/resource-profiles.conf}"

# Bir profilin conf satırını getir (yorum/boş satırlar hariç)
resource_profile_line() {
    [[ -f "$SRVCTL_RESOURCE_PROFILES" ]] || return 1
    grep -E "^${1}:" "$SRVCTL_RESOURCE_PROFILES" 2>/dev/null | grep -v '^#' | head -1
}

# Bir profilin N. alanını getir (1=ad 2=pm_mode 3=max_children 4=memory_limit_mb 5=tasks_max)
resource_profile_field() {
    local line
    line=$(resource_profile_line "$1") || return 1
    [[ -z "$line" ]] && return 1
    echo "$line" | cut -d: -f"$2"
}

# Tüm profil adlarını listele
resource_profile_names() {
    [[ -f "$SRVCTL_RESOURCE_PROFILES" ]] || return 1
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$SRVCTL_RESOURCE_PROFILES" | cut -d: -f1
}

# Geçerli profil adını döndür; geçersiz/boş/dosya-yok ise 'standard'a düş
# (rate_profile_resolve İLE BİREBİR AYNI desen — warn() zaten stderr'e yazar).
resource_profile_resolve() {
    local profile="$1"
    if [[ -n "$profile" && -n "$(resource_profile_line "$profile")" ]]; then
        echo "$profile"
    else
        [[ -n "$profile" ]] && warn "Bilinmeyen kaynak profili: ${profile} — 'standard' kullanılıyor"
        echo "standard"
    fi
}

# ───────────────────────────────────────────────────────────────
#  Profili global RES_* değişkenlerine yükler — cgroups slice VE FPM pool
#  boyutlandırmasının TEK doğruluk kaynağı budur (görev sözleşmesi: "iki
#  bağımsız sabit bırakma, drift'in sebebi buydu"). Formüller conf/
#  resource-profiles.conf VE templates/php-fpm/pool.conf.tpl başlık
#  yorumlarıyla (ops-infra sözleşmesi, karşılıklı çapraz-referanslı) BİREBİR
#  AYNI olmalıdır:
#    MemoryHigh (MB)    = max_children × memory_limit_mb
#    MemoryMax (MB)     = MemoryHigh × 9/8   (tamsayı aritmetiği, ≈ ×1.125)
#    MemorySwapMax (MB) = MemoryHigh / 8     (tamsayı bölme, TABAN 1M — sabit
#                         256M taban EKLENMEDİ: küçük profillerde (ör. micro
#                         512M tepe → 64M swap) mutlak değerin küçük olması
#                         sorun değil, ORANIN sıfır OLMAMASI önemliydi)
#  pm.start_servers/min_spare_servers/max_spare_servers ('dynamic' bunları
#  ZORUNLU kılar; 'ondemand' sessizce yok sayar, status=78/CONFIG VERMEZ —
#  Ubuntu 22.04/24.04'te 'php-fpm -t' ile doğrulandı) tamsayı bölme + clamp:
#    min_spare_servers = max(1, max_children / 8)
#    start_servers      = max(1, max_children / 4)
#    max_spare_servers  = clamp(max_children / 2, start_servers, max_children)
#  ör. ecommerce (max_children=16) → min=2 start=4 max=8; heavy (32) →
#  min=4 start=8 max=16 (pool.conf.tpl/resource-profiles.conf ile doğrulanan
#  ÖRNEKLERLE BİREBİR EŞLEŞİR). pm.process_idle_timeout TOKEN DEĞİL — sabit
#  '10s' pool.conf.tpl içine gömülü (yalnız 'ondemand'ta anlamlı).
#  Profil/dosya bulunamazsa (ör. conf/resource-profiles.conf henüz kurulu
#  değil) alanlar boş kalır ve aşağıda fail-closed 'standard' sözleşme
#  değerlerine (ondemand:8:256:120) düşülür — bu İKİNCİ bir bağımsız sabit
#  DEĞİLDİR, yalnızca 'standard' satırının sözleşmedeki DEĞERİYLE birebir
#  aynı bir dahili güvenlik ağıdır.
# ───────────────────────────────────────────────────────────────
resource_profile_load() {
    local profile
    profile=$(resource_profile_resolve "$1")
    RES_PROFILE="$profile"
    RES_PM_MODE=$(resource_profile_field "$profile" 2) || RES_PM_MODE=""
    RES_MAX_CHILDREN=$(resource_profile_field "$profile" 3) || RES_MAX_CHILDREN=""
    RES_MEMORY_LIMIT_MB=$(resource_profile_field "$profile" 4) || RES_MEMORY_LIMIT_MB=""
    RES_TASKS_MAX=$(resource_profile_field "$profile" 5) || RES_TASKS_MAX=""

    case "$RES_PM_MODE" in
        ondemand|dynamic|static) : ;;
        *) RES_PM_MODE="ondemand" ;;
    esac
    if ! validate_uint "$RES_MAX_CHILDREN" 1000 || (( RES_MAX_CHILDREN < 1 )); then
        RES_MAX_CHILDREN=8
    fi
    if ! validate_uint "$RES_MEMORY_LIMIT_MB" 1000000 || (( RES_MEMORY_LIMIT_MB < 1 )); then
        RES_MEMORY_LIMIT_MB=256
    fi
    if ! validate_uint "$RES_TASKS_MAX" 1000000 || (( RES_TASKS_MAX < 1 )); then
        RES_TASKS_MAX=120
    fi

    # MemoryHigh/Max/SwapMax — conf/resource-profiles.conf'un GERÇEK
    # uygulaması (tamsayı aritmetiği, taban 1M — 256M taban YOK).
    local mem_high_mb mem_max_mb mem_swap_mb
    mem_high_mb=$(( RES_MAX_CHILDREN * RES_MEMORY_LIMIT_MB ))
    mem_max_mb=$(( mem_high_mb * 9 / 8 ))
    mem_swap_mb=$(( mem_high_mb / 8 ))
    (( mem_swap_mb >= 1 )) || mem_swap_mb=1

    RES_MEMORY_HIGH_MB="$mem_high_mb"
    RES_MEMORY_MAX_MB="$mem_max_mb"
    RES_MEMORY_SWAP_MB="$mem_swap_mb"
    RES_MEMORY_HIGH="${mem_high_mb}M"
    RES_MEMORY_MAX="${mem_max_mb}M"
    RES_MEMORY_SWAP="${mem_swap_mb}M"

    # pm.min_spare/start/max_spare_servers — ops-infra'nın clamp formülü
    # (templates/php-fpm/pool.conf.tpl + conf/resource-profiles.conf başlık
    # yorumlarıyla BİREBİR AYNI; örnekleriyle doğrulandı: bkz. yukarı).
    local min_spare start max_spare half
    min_spare=$(( RES_MAX_CHILDREN / 8 )); (( min_spare >= 1 )) || min_spare=1
    start=$(( RES_MAX_CHILDREN / 4 )); (( start >= 1 )) || start=1
    half=$(( RES_MAX_CHILDREN / 2 ))
    max_spare=$half
    (( max_spare >= start )) || max_spare=$start
    (( max_spare <= RES_MAX_CHILDREN )) || max_spare=$RES_MAX_CHILDREN
    RES_PM_MIN_SPARE_SERVERS="$min_spare"
    RES_PM_START_SERVERS="$start"
    RES_PM_MAX_SPARE_SERVERS="$max_spare"
}

# ═══════════════════════════════════════════════
#  Redis sürüm tespiti + ACL kanal-izolasyonu yetenek kararı
#  (ÇAPRAZ-MODÜL PAYLAŞIMLI — bkz. aşağıdaki "NEDEN core.sh'TA" notu)
# ═══════════════════════════════════════════════
# NEDEN core.sh'TA (lib/domain.sh'ta DEĞİL): hem lib/domain.sh (per-domain
# Redis ACL kullanıcısı, bkz. _domain_build_redis_acl_line) hem lib/init.sh
# (sunucu-geneli admin/default Redis ACL kullanıcıları, bkz. _install_redis)
# AYNI "Redis'in şu an hangi sürümde çalıştığı" ve "pub/sub kanal ACL'i bu
# sürümde MÜMKÜN MÜ" kararına ihtiyaç duyuyor. '_load_and_run' (bin/srvctl)
# YALNIZ dispatch edilen TEK modülü source ettiğinden (bkz. CLAUDE.md)
# domain.sh'ta tanımlı kalsaydı init.sh'tan çağrısı çalışma zamanında
# "command not found" (127) verirdi — resource_profile_*/rate_profile_*
# İLE AYNI gerekçeyle burası (her modülde HER ZAMAN ilk source edilen
# core.sh) doğru ev. Bu üç fonksiyon 2026-07-31'de lib/domain.sh'tan
# BURAYA TAŞINDI (_domain_redis_channel_isolation_mode ->
# _redis_channel_isolation_mode olarak yeniden adlandırıldı — artık
# domain.sh'a özel değil; _redis_version_pair/_redis_major_version isim
# DEĞİŞTİRMEDİ, domain.sh çağrı yerleri kırılmadı).
#
# GEREKÇE (KENDİ DOĞRULAMAM, kaynaklı — kanal izolasyonu kararı için):
#   - 'resetchannels', '&pattern' VE 'allchannels' (üçü de pub/sub kanal
#     ACL'i) Redis'e 6.2.0'da eklendi: resmi 6.2 RELEASENOTES'ta 6.0.9
#     tabanına kıyasla yeni özellik olarak "ACL patterns for Pub/Sub
#     channels (#7993)" geçer (github.com/redis/redis, 00-RELEASENOTES,
#     6.2 dalı — indirip grep ile teyit edildi).
#   - Redis 6.0.16'nın KENDİ kaynağında (src/acl.c) ACLSetUser'ın op
#     ayrıştırma zincirinde ('~' anahtar deseni dalından hemen sonra
#     '+'/'-' komut bayrağı dalına geçer) '&' İÇİN HİÇBİR DAL YOK; Redis
#     6.2.0'ın AYNI zincirinde 'op[0] == '&'' diye AYRI bir dal var (satır
#     928). 'allchannels'/'resetchannels' string'leri de 6.0.16 kaynağında
#     SIFIR kez geçiyor (grep ile teyit edildi — ne token ne de config
#     yönergesi 'acl-pubsub-default' 6.0.16'da mevcut, o da 6.2 eklentisi).
#     Sonuç: 6.0'da '&*' gibi bir token parser'ın HİÇBİR dalına uymadığından
#     jenerik "Syntax error"a düşer ve Redis HİÇ BAŞLAMAZ — bu, gerçek
#     Ubuntu 22.04 VM'de hem domain.sh'ın per-domain ACL satırında hem
#     init.sh'ın ürettiği admin/default satırlarında (ikisi de '&*'
#     içeriyordu) birebir gözlemlendi.
#   - Ubuntu 22.04 (jammy) paketi: redis-server 6.0.16 (6.2 ALTI). Ubuntu
#     24.04 (noble) paketi: redis-server 7.0.15 (6.2 ÜSTÜ). Kaynak:
#     packages.ubuntu.com/{jammy,noble}/redis-server.
#   - ÖNEMLİ (güvenlik açısından): Redis 6.0'da pub/sub ACL denetimi KAVRAM
#     OLARAK YOK — kanal token'ını ATLAMAK bir kısıtlamayı GEVŞETMEZ (zaten
#     hiçbir kısıtlama yoktu, TÜM kimliği doğrulanmış istemciler TÜM
#     kanallara serbestçe abone olabilir/yayın yapabilir); yalnızca Redis'in
#     BAŞLAMASINI sağlar. Bu izolasyonsuzluk operatöre SESSİZCE değil,
#     AÇIKÇA bildirilmelidir (bkz. çağıran taraflardaki warn metinleri:
#     lib/domain.sh per-domain, lib/init.sh sunucu-geneli — BİR KEZ).

# Redis sunucu (MAJOR, MINOR) sürüm ÇİFTİNİ tespit eder.
#
# BUG 1 DÜZELTMESİ (GERÇEK Ubuntu 22.04 VM'de coordinator tarafından
# ÖLÇÜLEREK bulundu — 2026-07-31): bu fonksiyon ESKİDEN ÖNCE 'redis-server
# --version' (KURULU BINARY'nin sürümü) okuyordu, yalnız o başarısızsa
# 'redis-cli INFO server' (ÇALIŞAN SÜRECİN sürümü) düşüyordu. Bu YANLIŞTI:
# ACL sözdizimi kararını (ör. '&*' kanal token'ı 6.2+ gerektirir) hangi
# SÜRECİN yorumlayacağı sorusuna binary sürümü CEVAP VERMEZ — yalnız ÇALIŞAN
# süreç verir. GERÇEK VM'de birebir gözlemlendi: 'apt-get install
# redis-server' binary'yi 6.0.16'dan 7.4.10'a yükseltti ama redis-server
# SÜRECİNİ yeniden BAŞLATMADI (systemd/dpkg bunu garanti etmez — bkz.
# lib/init.sh _install_redis'teki BUG 2 düzeltmesi); 'redis-server --version'
# 7.4.10 derken 'redis-cli INFO server' hâlâ 'redis_version:6.0.16'
# (process_id/uptime de ESKİ süreci doğruluyordu) diyordu. Eski kod BİRİNCİ
# (yanlış, binary) kaynağı ÖNCELİKLİ okuduğundan srvctl "6.2+ destekleniyor"
# sanıp ACL dosyasına '&*'/'resetchannels' yazdı — ama bunu YORUMLAMASI
# gereken süreç HÂLÂ 6.0.16 olduğundan Redis'in KENDİSİ 'ACL LOAD'ı
# "ERR ... Syntax error" ile reddetti (bkz. BUG 3 / _redis_acl_load).
#
# YENİ DAVRANIŞ: YALNIZ ÇALIŞAN sunucuya sorulur ('redis-cli INFO server' —
# 'redis_version:' alanı). Admin parolası biliniyorsa (SRVCTL_CONF'tan
# GÜVENLİ biçimde okunur — source DEĞİL, grep+cut; lib/domain.sh'taki AYNI
# desen) 'REDISCLI_AUTH' env'e (argv'ye DEĞİL — 'ps' çıktısında görünmez)
# konur ve '--user admin' ile bağlanılır — ACL zaten kilitliyse (default
# kullanıcı 'off'/'-@all') parolasız bağlantı NOAUTH ile reddedilir. Parola
# henüz YOKSA (ör. ilk kurulumda, ACL yazılmadan ÖNCE) parolasız denenir —
# o an çalışan stok config'te ACL kısıtı yoktur, bu yeterlidir.
#
# FAIL-CLOSED FALLBACK (BİLEREK KALDIRILAN eski 'redis-server --version'
# dalı): çalışan sunucu SORULAMIYORSA (redis-cli yok, bağlantı reddedildi,
# parola yanlış) bu fonksiyon 1 döner (stdout boş) — 'redis-server --version'
# okuyup "büyük ihtimalle bu sürüm çalışıyordur" diye TAHMİN ETMEZ. Çağıran
# taraf bunu 'unknown' sayıp kanal token'ını ACL'e HİÇ YAZMAMALI (mevcut
# fail-closed sözleşmesi — bkz. _redis_channel_isolation_mode): başlamayan/
# izolasyonsuz ama en azından TUTARLI bir Redis, canlı kural kümesiyle
# UYUŞMAYAN bir ACL dosyasından kesinlikle iyidir.
#
# NEDEN çift (yalnız major değil): kanal (pub/sub) ACL izolasyonu kararı
# major=6 içinde İKİYE bölünür — 6.0'da 'resetchannels'/'&pattern' token'ları
# PARSER'DA HİÇ TANIMLI DEĞİL (bkz. yukarıdaki kaynak referanslı gerekçe),
# 6.2+'da tanımlı. Yalnız major bilgisiyle bu ayrım yapılamaz.
_redis_version_pair() {
    local out redis_admin_pass=""
    command -v redis-cli >/dev/null 2>&1 || return 1

    if [[ -n "${SRVCTL_CONF:-}" && -f "${SRVCTL_CONF}" ]]; then
        redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    fi

    if [[ -n "$redis_admin_pass" ]]; then
        out=$(REDISCLI_AUTH="$redis_admin_pass" redis-cli --user admin --no-auth-warning INFO server 2>/dev/null | grep -m1 '^redis_version:')
    else
        out=$(redis-cli INFO server 2>/dev/null | grep -m1 '^redis_version:')
    fi
    if [[ "$out" =~ redis_version:([0-9]+)\.([0-9]+)\. ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# Geriye uyumlu ince sarmalayıcı — yalnız MAJOR döndürür (mevcut çağıranlar/
# testler bunu bekliyor: bkz. tests/test_pure_helpers.sh, lib/domain.sh).
# Tek gerçek kaynak _redis_version_pair'dir; iki ayrı redis-server/redis-cli
# çağrısı YAPMAZ.
_redis_major_version() {
    local pair major
    pair=$(_redis_version_pair) || return 1
    major="${pair%% *}"
    [[ -n "$major" ]] || return 1
    echo "$major"
}

# Saf karar fonksiyonu — redis-server/redis-cli ÇAĞIRMAZ, macOS'ta argüman
# enjeksiyonuyla unit-test edilebilir (bkz. lib/domain.sh:
# _domain_redis_scripting_mode ile aynı desen). KARAR: major>6 OR
# (major==6 AND minor>=2) -> 'supported'; aksi halde (6.0/6.1 ya da sürüm
# belirlenemedi) -> 'unsupported'/'unknown' — çağıran taraf bu durumda
# kanal token'larını ('resetchannels'/'&pattern'/'allchannels') ACL
# satırına HİÇ EKLEMEMELİ (fail-closed: başlamayan bir Redis, izolasyonsuz
# ama ÇALIŞAN bir Redis'ten kötüdür — ama izolasyonsuzluk operatöre AÇIKÇA
# uyarılarak kabul edilir; bkz. çağıran taraftaki warn metinleri).
# Çıktı: durum kodu (supported|unsupported|unknown).
_redis_channel_isolation_mode() {
    local major="$1" minor="$2"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        if (( major > 6 || (major == 6 && minor >= 2) )); then
            echo "supported"
        else
            echo "unsupported"
        fi
    else
        echo "unknown"
    fi
}

# ═══════════════════════════════════════════════
#  _redis_acl_load — 'ACL LOAD' sarmalayıcısı, FAIL-CLOSED (BUG 3 düzeltmesi)
# ═══════════════════════════════════════════════
# NEDEN VAR (GERÇEK Ubuntu 22.04 VM'de coordinator tarafından bulundu —
# 2026-07-31, EN CİDDİ bulgu): lib/domain.sh:655 ve :2385 şu deseni
# kullanıyordu:
#   REDISCLI_AUTH="$pass" redis-cli --user admin --no-auth-warning ACL LOAD \
#       2>/dev/null || systemctl restart redis-server
# Bu, 'redis-cli'nin PROCESS exit kodunun ACL LOAD'ın SUNUCU TARAFINDAKİ
# başarısını yansıttığını VARSAYAR — YANLIŞ VARSAYIM. 'redis-cli', sunucuya
# bağlanıp komutu gönderip HERHANGİ bir yanıt aldığı sürece (yanıt bir HATA
# mesajı OLSA BİLE) genellikle 0 ile çıkar; yalnız BAĞLANTI düzeyinde bir
# sorunda (sunucuya ulaşılamadı, timeout) non-zero döner. GERÇEK VM'de elle
# çalıştırıldığında Redis ACL LOAD'a şu yanıtı verdi:
#     ERR /etc/redis/users.acl:5: Syntax error. /etc/redis/users.acl:6: ...
#     WARNING: ACL errors detected, no change to the previously active ACL
#     rules was performed
# yani Redis'in KENDİSİ "hiçbir değişiklik yapılmadı" diyordu — ACL dosyası
# ile CANLI kural kümesi TAMAMEN AYRIŞMIŞTI. Buna rağmen eski desen bunu
# YUTUYORDU: '|| systemctl restart redis-server' fallback'i ÇALIŞMIYORDU
# (çünkü '||' yalnız SOL taraf non-zero dönerse tetiklenir; redis-cli'nin
# kendisi burada 0 ile çıkmış olabilir), çağıran (_domain_repair/_domain_add)
# bu satırın dönüş değerini hiç kontrol ETMEDEN devam ediyor, EXIT=0 ve
# "Domain onarıldı" raporluyordu — bir güvenlik kontrolü (kanal ACL'i) HİÇ
# UYGULANMAMIŞKEN operatör başarı görüyordu.
#
# BU SARMALAYICI: hem dönüş kodunu HEM ÇIKTIYI kontrol eder — 'ACL LOAD'
# yalnız TAM olarak 'OK' basıp 0 döndüğünde başarılı sayılır (Redis'in
# başarılı 'ACL LOAD' yanıtı budur — '+OK' simple string). Başarısızlıkta
# Redis'in kendi teşhis metnini (ör. yukarıdaki "no change..." satırı — bu
# zaten en iyi teşhistir) stderr'e basar ve 1 döner. ÇAĞIRAN TARAF bu dönüş
# değerini KONTROL ETMEDEN "başarılı"/"onarıldı" RAPORLAMAMALI.
#
# KAPSAM NOTU: bu fonksiyonun ÇAĞRI SİTELERİ (lib/domain.sh:655, :2385)
# BAŞKA bir agent'ın eşzamanlı çalıştığı dosyada olduğundan BURADAN
# değiştirilmedi — yalnız paylaşılan sarmalayıcı core.sh'a eklendi; domain.sh
# sahibi çağrı sitelerini '_redis_acl_load "$redis_admin_pass" || <fallback>'
# şeklinde buna bağlayabilir (dönüş değerini KONTROL ETMESİ ve başarısızlıkta
# 'repair'/'add' sonucunu da başarısız SAYMASI gerekir — aksi halde BUG 3
# yarı yarıya düzeltilmiş olur).
#
# Kullanım: _redis_acl_load <admin_parolası>
# Dönüş: 0 = ACL GERÇEKTEN yüklendi (canlı kural kümesi dosyayla eşleşiyor).
#        1 = başarısız — teşhis metni ZATEN stderr'e basıldı, çağıran bunu
#            YUTMADAN kendi hata yoluna (warn/error/exit≠0) YAYMALI.
_redis_acl_load() {
    local admin_pass="$1"
    local out rc
    out=$(REDISCLI_AUTH="$admin_pass" redis-cli --user admin --no-auth-warning ACL LOAD 2>&1)
    rc=$?
    # rc'ye TEK BAŞINA GÜVENİLMEZ (yukarıdaki NEDEN VAR notuna bkz.) — çıktı
    # da 'OK' değilse başarısız sayılır. 'tr -d' ile CR (\r) ÖNCE atılır
    # (redis-cli bazı terminal/pty bağlamlarında CRLF basabilir), SONRA
    # 'xargs' ile baştaki/sondaki boşluk/newline kırpılır.
    if [[ $rc -ne 0 ]] || [[ "$(echo "$out" | tr -d '\r' | xargs 2>/dev/null)" != "OK" ]]; then
        echo "GÜVENLİK: Redis ACL LOAD BAŞARISIZ — önceki ACL kuralları hâlâ yürürlükte, YENİ kurallar UYGULANMADI. Redis'in kendi çıktısı:" >&2
        echo "$out" >&2
        return 1
    fi
    return 0
}

# ─── Per-Domain Meta (sır değil) ───

# Domain meta dosyasını oku (source DEĞİL — katı parse)
# Sahiplik kapısı: hardened domain + root-owned-değil → tamper → error (çıkış).
# Migrate edilmemiş (marker yok) → warn stderr + oku.
read_meta() {
    local meta_file="${WEB_ROOT}/${1}/.srvctl-meta"
    [[ -f "$meta_file" ]] || return 0
    # KUSUR 2 NOTU: _require_owned_or_warn artık "eksik" (2) ile "tamper" (1)
    # ayrımı yapıyor (bkz. core.sh:_require_owned_or_warn) ama BURADA sabit
    # "(tamper)" mesajı hâlâ DOĞRU — bir satır yukarıdaki '[[ -f ]] || return 0'
    # dosyanın VAR OLDUĞUNU zaten garanti ettiğinden, bu satıra ulaşıldığında
    # dönüş değeri asla 2 (eksik) olamaz. Bu guard'ı kaldırırsanız
    # read_credentials'taki case ayrımını buraya da taşıyın.
    _require_owned_or_warn "$1" "$meta_file" \
        || error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
    read_kv_file "$meta_file" RATE_PROFILE SENSITIVE_PATHS
}

# Meta dosyasına key=value ekle/güncelle (yoksa oluştur)
write_meta() {
    local domain="$1" key="$2" value="$3"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    # Mevcut anahtarı çıkar (varsa), sonra TIRNAKSIZ (%s=%s) yeniden ekle —
    # read_kv_file verbatim okur (source/eval yok), bu yüzden %q gerekmez.
    # sed yerine grep-filtre: keyfi değerlerde (| & \ vb.) ve BSD/GNU sed farkında güvenli.
    if [[ -f "$meta_file" ]]; then
        grep -v "^${key}=" "$meta_file" > "${meta_file}.tmp" 2>/dev/null || true
        mv "${meta_file}.tmp" "$meta_file"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$meta_file"
    chmod 644 "$meta_file" 2>/dev/null || true
    chown root:root "$meta_file" 2>/dev/null || true
}
