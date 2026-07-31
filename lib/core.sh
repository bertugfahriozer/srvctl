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

log_action() {
    mkdir -p "$(dirname "${SRVCTL_LOG}")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(whoami)] $*" >> "${SRVCTL_LOG}"
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

# Sahiplik politikası (PREDIKAT: 0=devam, 1=tamper → çağıran error eder).
# root-owned değilse: hardened domain → tamper (1); migrate edilmemiş → warn + 0.
# warn() ARTIK KENDİLİĞİNDEN stderr'e yazar (KARAR 1) — elle '>&2' gerekmez.
_require_owned_or_warn() {
    local domain="$1" file="$2"
    assert_root_owned_path "$file" && return 0
    if _domain_is_hardened "$domain"; then
        return 1
    fi
    warn "Domain '${domain}' henüz hardened değil — 'srvctl security harden-fs ${domain}' önerilir"
    return 0
}

# ─── Güvenli FS oluşturma (umask 077 altında) ───
# chown macOS dev kutusunda başarısız olabilir → guard'lı; mod/varlık test edilir.
secure_file() {
    local path="$1" mode="${2:-600}"
    # Dosyayı oluştur (yoksa) — MEVCUT içeriği KORU. 'touch' truncate ETMEZ;
    # (eski ': >' mevcut dosyayı boşaltıyordu → yazımdan sonra çağrılınca içerik
    #  kaybı: /root/.my.cnf, yedek artefaktları, migrate credentials).
    ( umask 077; touch "$path" 2>/dev/null || true )
    [[ -e "$path" ]] || { umask 077; touch "$path"; }
    chmod "$mode" "$path"
    chown root:root "$path" 2>/dev/null || true
}

secure_dir() {
    local path="$1" mode="${2:-700}"
    ( umask 077; mkdir -p "$path" )
    chmod "$mode" "$path"
    chown root:root "$path" 2>/dev/null || true
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
render_template() {
    local template="$1"
    shift

    if [[ ! -f "$template" ]]; then
        error "Template bulunamadı: ${template}"
    fi

    local content
    content=$(cat "$template")

    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        # CRLF/config-enjeksiyon koruması: değer satırsonu/CR içeremez.
        # (render-time değişmezi — bu error EXIT eder; charset doğrulaması
        #  çağıran tarafta assert_regex_safe ile yapılır.)
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
            error "render_template: '${key}' değeri satırsonu/CR içeriyor — reddedildi"
        fi
        content="${content//\{\{${key}\}\}/${value}}"
    done

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
# çalışır. Ayırt edici işaret '.credentials' — 'domain add' her domain için
# root:600 olarak yazar (bkz. _domain_write_credentials); nginx'in html
# dizininde bulunmaz.
list_all_domains() {
    local dir name
    for dir in "${WEB_ROOT}"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        # Domain adı kuralına uymayan dizinleri ele (savunma derinliği)
        validate_domain "$name" || continue
        # srvctl tarafından oluşturulmuş mu? (.credentials = domain işareti)
        [[ -f "${dir}.credentials" ]] || continue
        printf '%s\n' "$name"
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
    _require_owned_or_warn "$domain" "$creds_file" \
        || error "Güvenlik: ${creds_file} root-owned değil (tamper). Okuma reddedildi."
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

# Redis sunucu (MAJOR, MINOR) sürüm ÇİFTİNİ tespit eder. Önce
# 'redis-server --version' (host'ta paket kuruluysa her zaman mevcuttur,
# auth gerekmez), yoksa 'redis-cli INFO server' düşer (parola argv'ye değil
# REDISCLI_AUTH env'e gider — çağıran taraf gerekirse onu set etmeli).
# Belirlenemezse 1 döner (stdout boş) — çağıran fail-closed davranmalı.
# NEDEN çift (yalnız major değil): kanal (pub/sub) ACL izolasyonu kararı
# major=6 içinde İKİYE bölünür — 6.0'da 'resetchannels'/'&pattern' token'ları
# PARSER'DA HİÇ TANIMLI DEĞİL (bkz. yukarıdaki kaynak referanslı gerekçe),
# 6.2+'da tanımlı. Yalnız major bilgisiyle bu ayrım yapılamaz.
_redis_version_pair() {
    local out
    if command -v redis-server >/dev/null 2>&1; then
        out=$(redis-server --version 2>/dev/null)
        if [[ "$out" =~ v=([0-9]+)\.([0-9]+)\. ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
            return 0
        fi
    fi
    out=$(redis-cli INFO server 2>/dev/null | grep -m1 '^redis_version:')
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

# ─── Per-Domain Meta (sır değil) ───

# Domain meta dosyasını oku (source DEĞİL — katı parse)
# Sahiplik kapısı: hardened domain + root-owned-değil → tamper → error (çıkış).
# Migrate edilmemiş (marker yok) → warn stderr + oku.
read_meta() {
    local meta_file="${WEB_ROOT}/${1}/.srvctl-meta"
    [[ -f "$meta_file" ]] || return 0
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
