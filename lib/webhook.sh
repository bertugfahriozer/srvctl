#!/bin/bash
# ═══════════════════════════════════════════════
#  webhook.sh — Webhook Auto-Deploy Listener
#  GitHub/GitLab push → otomatik deploy
# ═══════════════════════════════════════════════

# Yapılandırma:
#   WEBHOOK_PORT=9443
#   WEBHOOK_SECRET=xxxxxx (GitHub/GitLab secret)

WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"
WEBHOOK_PID_FILE="/var/run/srvctl-webhook.pid"
WEBHOOK_LOG="/usr/local/srvctl/logs/webhook.log"
# GÜVENLİK (DALGA 6): bind adresi KASITLI OLARAK KONFİGÜRE EDİLEMEZ — eskiden
# burada bir 'WEBHOOK_BIND' değişkeni vardı ama HİÇBİR YERDE kullanılmıyordu
# (ölü config: belgelenen ayar çalışmıyordu). Bilerek WIRE ETMEDİK: bu portu
# nginx reverse-proxy'nin (TLS + imza/replay doğrulaması + rate-limit) DIŞINDA
# hiçbir arayüze bağlamak GÜVENLİK MODELİNİ tamamen atlar — bir operatörün
# conf/srvctl.conf'a yanlışlıkla/bilmeden 'WEBHOOK_BIND=0.0.0.0' yazması,
# imza/replay kontrolünü ATLAYAN çıplak bir HTTP uç noktasını dışa açardı.
# Aşağıdaki socat çağrısında bind adresi bu yüzden HER ZAMAN sabit
# '127.0.0.1' yazılır (bkz. _webhook_start, tests/test_webhook_bind.sh bunu
# kilitler).

# ─── HMAC-SHA256 imza doğrulama (fail-closed) ───
# _webhook_verify_sig <secret> <payload> <header_value>
# GitHub X-Hub-Signature-256 doğrulaması. 0 döner ANCAK header dolu VE
# 'sha256='+HMAC-SHA256(secret,payload)'a eşitse. Eksik/boş header, boş
# secret veya yanlış imza → 1. Çıkış/çıktı yapmaz.
#
# GÜVENLİK (O11 — DALGA 6): secret ARTIK openssl'e CLI ARGÜMANI olarak
# VERİLMİYOR. Önceki uygulama 'openssl dgst -sha256 -hmac "$secret"' idi —
# bu, secret'i openssl child process'inin argv'sine yazıyordu; hidepid=2
# KURULMAMIŞ varsayılan bir Ubuntu'da /proc/<pid>/cmdline (ör. `ps auxww`)
# HERHANGİ bir yerel kullanıcı tarafından okunabilir — web_* dahil (srvctl'in
# ürettiği en az güvenilir yerel kullanıcılar). openssl'in '-hmac' bayrağı
# redis-cli'nin REDISCLI_AUTH'u gibi argv-dışı bir kaynak (env/fd/dosya)
# DESTEKLEMEDİĞİNDEN, HMAC-SHA256 RFC 2104 tanımına göre SAF 'openssl dgst
# -sha256' (bayraksız hash) + pipe ile elle hesaplanır: secret HİÇBİR ZAMAN
# bir CLI argümanı olarak yazılmaz, yalnızca STDIN/pipe üzerinden akar (pipe
# içeriği /proc/*/cmdline ile GÖRÜNMEZ — yalnızca ptrace yetkisi olan biri
# görebilir, ki o zaten root'tur). Doğruluk RFC 4231 test vektörleri +
# mevcut '-hmac' çıktısına karşı elle doğrulandı (macOS/LibreSSL üzerinde;
# Ubuntu/OpenSSL 3.x üzerinde HOST doğrulaması önerilir — aşağıdaki NOT'a
# bakın).
#
# NOT: bu fonksiyon KASITLI OLARAK tek, kendi-kendine-yeten bir blok —
# tests/test_webhook_listener_sig.sh heredoc'tan yalnız
# '^_webhook_verify_sig\(\) \{' ile başlayıp ilk '^\}$' ile biten bloğu
# awk ile ayıklıyor. Hesaplama ayrı bir yardımcı fonksiyona (ör.
# '_hmac_sha256') bölünseydi o yardımcı ayıklanmadığından heredoc kopyası
# runtime'da "command not found" ile patlardı — bu yüzden HMAC hesaplaması
# BİLEREK inline tutulur (kod tekrarı burada bilinçli bir tercih).
_webhook_verify_sig() {
    local secret="$1" payload="$2" header="$3"
    # Secret yoksa veya header boşsa fail-closed
    [[ -z "$secret" ]] && return 1
    [[ -z "$header" ]] && return 1

    # ── RFC 2104 HMAC-SHA256 (argv-free) ──
    # 1) anahtar hex'e çevrilir (od — coreutils, her Ubuntu kurulumunda var)
    local block_size=64 key_hex
    key_hex=$(printf '%s' "$secret" | od -An -tx1 -v 2>/dev/null | tr -d ' \n')
    [[ -z "$key_hex" ]] && return 1
    # 2) anahtar block_size'dan (64 byte) uzunsa önce hashlenir (RFC 2104)
    if (( ${#key_hex} / 2 > block_size )); then
        key_hex=$(printf '%s' "$secret" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')
    fi
    # 3) block_size'a sıfır-byte ile doldurulur (hex string 128 karaktere tamamlanır)
    key_hex=$(printf -- '%-128s' "$key_hex" | tr ' ' '0')

    # 4) K XOR ipad(0x36) / K XOR opad(0x5c) — bash arithmetic ile (argv/pipe
    #    kullanmadan; printf -v ile doğrudan değişkene yazılır, subshell fork
    #    YOK).
    local i hbyte xb ipad_hex="" opad_hex=""
    for (( i=0; i<${#key_hex}; i+=2 )); do
        hbyte="${key_hex:i:2}"
        printf -v xb '%02x' $(( 16#$hbyte ^ 16#36 )); ipad_hex+="$xb"
        printf -v xb '%02x' $(( 16#$hbyte ^ 16#5c )); opad_hex+="$xb"
    done

    # 5) hex -> ham byte'lara çevrilecek \xHH escape dizgesi. NOT: bash
    #    DEĞİŞKENİ NUL byte TUTAMAZ, ama 'printf %b' ÇIKTISI doğrudan
    #    stdout'a (pipe'a) yazıldığından anahtar 0x00 byte İÇERSE bile
    #    (ör. XOR sonucu sıfır) veri GÜVENLE akar — hiçbir aşamada
    #    komut-substitution ($()) ile ham/binary veri YAKALANMAZ.
    local ipad_esc="" opad_esc=""
    for (( i=0; i<${#ipad_hex}; i+=2 )); do ipad_esc+="\\x${ipad_hex:i:2}"; done
    for (( i=0; i<${#opad_hex}; i+=2 )); do opad_esc+="\\x${opad_hex:i:2}"; done

    # 6) inner = SHA256(K^ipad || payload); dış aşama SHA256(K^opad || inner)
    #    — ikisi de tek bir pipeline üzerinden akar (binary veri $() İLE
    #    ASLA yakalanmaz, yalnız SON hex çıktısı $() ile alınır — hex ASCII
    #    olduğundan NUL riski yoktur).
    local hmac_hex
    hmac_hex=$( { printf '%b' "$ipad_esc"; printf '%s' "$payload"; } \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | { printf '%b' "$opad_esc"; cat; } \
        | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}' )
    [[ -z "$hmac_hex" ]] && return 1

    local expected="sha256=${hmac_hex}"

    # Sabit-zamanlı karşılaştırma: her iki dizgenin SHA-256'sını al,
    # böylece uzunluk farkı ve byte-byte erken-çıkış sızıntısı olmaz.
    # NOT: Bash [[==]] tam anlamıyla sabit-zamanlı değil; ancak eşit uzunluklu
    # hash karşılaştırması pratik timing saldırılarını önemli ölçüde zorlaştırır.
    local h_recv h_exp
    h_recv="$(printf '%s' "$header"   | openssl dgst -sha256 | awk '{print $NF}')"
    h_exp="$(printf '%s' "$expected"  | openssl dgst -sha256 | awk '{print $NF}')"
    [[ "$h_recv" == "$h_exp" ]] && return 0
    return 1
}

# ─── Replay/nonce koruması (O11 — DALGA 6) ───
# _webhook_check_replay <sname> <delivery_id>
# GitHub 'X-GitHub-Delivery' / GitLab 'X-Gitlab-Event-UUID' başlığındaki
# benzersiz teslimat kimliğini root-only bir state dosyasında tutar; daha
# önce görülmüş bir id'yi REDDEDER (imza doğru olsa bile). Böylece geçerli
# bir isteği bir kez yakalayan biri (proxy logu, TLS-terminasyon yapan ara
# sunucu, CI log'u) onu SINIRSIZ tekrar oynatamaz.
#
# ÖNEMLİ — ÇAĞRI SIRASI: bu fonksiyon yalnız _webhook_verify_sig BAŞARILI
# olduktan SONRA çağrılmalı (handle_request'teki sıraya bkz.). Aksi halde
# secret'i BİLMEYEN bir saldırgan, imza kontrolünden hiç geçmeden çöp
# delivery-id'ler gönderip state dosyasını (son N kayıt penceresini)
# doldurabilir ve GERÇEK/meşru bir delivery-id'yi pencereden düşürüp onu
# yeniden-oynatılabilir hale getirebilirdi ("ring-buffer poisoning"). İmza
# kontrolünden SONRA çalıştırmak bu sınıfı tamamen önler.
#
# NOT: GitHub'ın panel üzerinden manuel "Redeliver" düğmesi AYNI delivery-id
# ile yeniden gönderir — bu da BİLEREK reddedilir (kayıtlı bir replay'den
# ayırt edilemez). Operatör yeniden tetiklemek isterse yeni bir push ya da
# doğrudan 'srvctl deploy <domain>' kullanabilir. GitHub/GitLab bir zaman
# damgası başlığı GÖNDERMEDİĞİNDEN (Stripe'ın 'Stripe-Signature: t=...'
# deseninin bir eşdeğeri yok) burada bir zaman-penceresi kontrolü YOKTUR —
# yalnız delivery-id tabanlı tekilleştirme (nonce) uygulanır; ileride bir
# zaman damgası başlığı standartlaşırsa kolayca eklenebilir.
#
# 0=geçerli/yeni (state'e YAZILDI), 1=replay/eksik/geçersiz/kilit alınamadı
# (fail-closed — hepsi aynı sonucu üretir, çağıran 403 döner).
_webhook_check_replay() {
    local sname="$1" delivery_id="$2"
    [[ -z "$delivery_id" ]] && return 1
    # Opaque token charset — GitHub/GitLab UUID gönderir (ör.
    # '72d3162e-cc78-11e3-81ab-4c9367dc0958'); state dosyasına TEK SATIR
    # olarak yazılacağından boşluk/newline/özel karakter KABUL EDİLMEZ.
    [[ "$delivery_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

    local dir="${SRVCTL_STATE_DIR:-/usr/local/srvctl/state}/_webhook/${sname}"
    secure_dir "$dir" 700
    local seen="${dir}/seen-delivery-ids" lock="${dir}/.lock"
    secure_file "$seen" 600

    # flock ile check+append ATOMİK yapılır — socat 'fork' ile HER bağlantı
    # ayrı bir process olduğundan (aynı domain'e eşzamanlı iki istek TOCTOU
    # riski taşır), kilitsiz bir 'grep sonra echo' yarışı aynı delivery-id'nin
    # iki kez kabul edilmesine yol açabilirdi.
    local rc=1
    exec 9>"$lock"
    if flock -w 5 9; then
        if grep -qxF -- "$delivery_id" "$seen" 2>/dev/null; then
            rc=1   # replay — daha önce görülmüş
        else
            printf '%s\n' "$delivery_id" >> "$seen"
            # Son N kayıtla sınırla — dosya sınırsız BÜYÜMEZ.
            tail -n 500 "$seen" > "${seen}.tmp" 2>/dev/null && mv -f "${seen}.tmp" "$seen"
            chmod 600 "$seen" 2>/dev/null || true
            rc=0
        fi
    fi
    exec 9>&-
    return "$rc"
}

cmd_webhook() {
    require_root
    case "${1:-help}" in
        start)  _webhook_start ;;
        stop)   _webhook_stop ;;
        status) _webhook_status ;;
        setup)  _webhook_setup "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl webhook <start|stop|status|setup>"
            echo ""
            echo "    start              Webhook listener'ı başlat"
            echo "    stop               Webhook listener'ı durdur"
            echo "    status             Listener durumu"
            echo "    setup <domain>     Domain için webhook yapılandır"
            echo ""
            echo "  GitHub/GitLab webhook URL'si domain'e ÖZELDİR (sabit bir"
            echo "  IP:port kalıbı DEĞİL — 9443 dışa hiçbir zaman açılmaz):"
            echo "    'srvctl webhook setup <domain>' çalıştırın, orada"
            echo "    gösterilen 'https://<domain>/__srvctl_webhook/<...>' "
            echo "    adresini GitHub/GitLab'a Payload URL olarak girin."
            echo ""
            ;;
    esac
}

_webhook_setup() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı."

    local sname
    sname=$(safe_name "$domain")
    local secret
    secret=$(generate_password 32)
    # Fail-closed: boş secret ile webhook yapılandırma (imza doğrulama anlamsız olur)
    [[ -z "$secret" ]] && error "Webhook secret üretilemedi."

    # Webhook config dosyası (umask 077 ile dünya-okunur sızıntısı önlenir)
    mkdir -p /etc/srvctl/webhooks
    chmod 700 /etc/srvctl/webhooks
    local conf="/etc/srvctl/webhooks/${sname}.conf"
    ( umask 077; : > "$conf" )
    cat > "$conf" << WHCONF
WEBHOOK_DOMAIN=${domain}
WEBHOOK_SECRET=${secret}
WEBHOOK_BRANCH=main
WEBHOOK_AUTO_DEPLOY=true
WEBHOOK_HEALTH_CHECK=true
WHCONF
    chmod 600 "$conf"

    # Nginx location kurulumu (opt-in, yalnız BU domain için) — bkz. fonksiyon
    # yorumu. Bu adım BAŞARISIZ olursa (nginx -t/render hatası) 'error' ile
    # EXIT eder (fail-closed) — secret zaten üretildi ama URL çalışmaz
    # durumda operatöre "kuruldu" denmez.
    _webhook_install_nginx_location "$domain" "$sname"

    header "Webhook Yapılandırıldı: ${domain}"
    echo "  Dahili:   http://127.0.0.1:${WEBHOOK_PORT}/deploy/${sname}"
    echo "  Genel:    https://${domain}/__srvctl_webhook/${sname}  (nginx reverse-proxy ile)"
    echo "  Secret:   ${secret}"
    echo "  Branch:   main"
    echo ""
    echo "  GitHub'da:"
    echo "    Settings → Webhooks → Add webhook"
    echo "    Payload URL:  https://${domain}/__srvctl_webhook/${sname}"
    echo "    Content type: application/json"
    echo "    Secret:       ${secret}"
    echo "    Events:       Just the push event"
    echo ""

    log_action "WEBHOOK SETUP: ${domain}"
}

# ─── Nginx webhook location kurulumu (opt-in — DALGA 6) ───
# 'srvctl webhook setup <domain>' ÇAĞRILMADIĞI sürece hiçbir domain'in
# vhost'unda webhook location'ı AKTİF olmaz: vhost.conf.tpl/vhost-ssl.conf.tpl
# ZATEN (her domain için, her zaman) şu satırı içerir:
#     include /etc/nginx/webhook.d/{{SAFE_NAME}}/*.conf;
# — SAFE_NAME zaten _domain_write_vhost (lib/domain.sh) tarafından
# besleniyordu (YENİ token DEĞİL). Bu glob dosya/dizin yoksa nginx'te sıfır
# eşleşme HATA DEĞİLDİR (bkz. /etc/nginx/conf.d/*.conf deseni, lib/init.sh)
# — saldırı yüzeyi yalnız bu fonksiyon ÇAĞRILDIKTAN sonra, yalnız İLGİLİ
# domain için büyür.
#
# ÖNKOŞUL (raporlanmalı — bu dosyanın sahibi domain.sh DEĞİL): vhost yalnız
# 'domain add' anında render edilir; BU DEĞİŞİKLİKTEN ÖNCE eklenmiş mevcut
# domainlerin vhost.conf'u henüz yukarıdaki 'include' satırını İÇERMEYEBİLİR.
# Böyle bir domain için 'srvctl webhook setup' nginx location'ı yazar ama
# vhost onu dahil ETMEZ (404). Operatör 'srvctl domain rate-limit set
# <domain> <aynı-profil>' çalıştırarak vhost'u YENİDEN render ettirip satırı
# kazanabilir (bu, _domain_write_vhost'u çağıran mevcut bir komut) — kalıcı
# bir çözüm (ör. 'domain repair'e vhost regenerasyonu eklemek) domain.sh'ın
# sahibinin kararıdır.
_webhook_install_nginx_location() {
    local domain="$1" sname="$2"
    local whd="/etc/nginx/webhook.d/${sname}"
    mkdir -p /etc/nginx/webhook.d "$whd" 2>/dev/null
    chmod 755 /etc/nginx/webhook.d "$whd" 2>/dev/null

    # Domain'in kendi rate-limit profili (.srvctl-meta → RATE_PROFILE) —
    # yoksa/geçersizse rate_profile_load zaten 'standard'a düşer (core.sh).
    # RATE_PROFILE/SENSITIVE_PATHS'i BİLEREK yerel değişken olarak açıyoruz;
    # read_meta (core.sh) bunları 'printf -v' ile dinamik-kapsam yoluyla BU
    # fonksiyonun yerel değişkenlerine yazar (global isim kirliliği önlenir).
    # SENSITIVE_PATHS burada KULLANILMIYOR — yalnız read_meta'nın YAN ETKİSİYLE
    # global isim alanına sızmasını önlemek için yerel olarak açık tutuluyor.
    # shellcheck disable=SC2034
    local RATE_PROFILE="" SENSITIVE_PATHS=""
    read_meta "$domain" 2>/dev/null || true
    rate_profile_load "${RATE_PROFILE:-}"

    local loc_conf="${whd}/location.conf"
    render_template "${SRVCTL_TEMPLATES:-/usr/local/srvctl/templates}/nginx/webhook-location.conf.tpl" \
        "SAFE_NAME=${sname}" \
        "WEBHOOK_PORT=${WEBHOOK_PORT}" \
        "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" \
        "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
        > "$loc_conf"

    # Leftover-token guard — lib/domain.sh:_domain_assert_no_leftover_tokens
    # ile AYNI niyet (beslenmeyen bir '{{TOKEN}}' asla diskte/nginx'te
    # kalmamalı). Cross-module private helper'a bağımlı OLMAMAK için
    # (CLAUDE.md: '_domain_*' isimlendirmesi domain.sh'a ÖZELDİR) burada
    # bağımsız/yerel bir kopyası tutulur.
    if grep -q '{{' "$loc_conf" 2>/dev/null; then
        rm -f "$loc_conf"
        error "Webhook nginx şablonu render hatası: beslenmeyen token kaldı — dosya silindi, işlem durduruldu."
    fi

    # Test etmeden reload etme (CLAUDE.md ops disiplini). core.sh'ın paylaşılan
    # 'nginx_test' helper'ı KASITLI OLARAK kullanılmıyor: o başarısızlıkta
    # doğrudan 'error' ile exit eder ve BOZUK dosyayı temizlemeden çıkar —
    # burada önce dosyayı SİLİP sonra 'error' etmemiz gerekiyor (bir
    # SONRAKİ ilgisiz nginx reload'ının bu bozuk dosya yüzünden başarısız
    # olmasını önlemek için, _domain_assert_no_leftover_tokens'daki gerekçenin
    # aynısı).
    if ! nginx -t &>/dev/null; then
        rm -f "$loc_conf"
        error "Nginx yapılandırma testi başarısız — webhook location kurulmadı, dosya silindi. 'nginx -t' ile ayrıntıyı kontrol edin."
    fi

    if ! systemctl reload nginx 2>/dev/null && ! service nginx reload 2>/dev/null; then
        warn "nginx reload başarısız — konfigürasyon diskte ama devreye alınmadı; elle 'systemctl reload nginx' deneyin"
    fi
}

_webhook_start() {
    if [[ -f "$WEBHOOK_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBHOOK_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            warn "Webhook listener zaten çalışıyor (PID: ${pid})"
            return 0
        fi
    fi

    info "Webhook listener başlatılıyor (port: ${WEBHOOK_PORT})..."

    # socat ile lightweight HTTP listener
    if ! command -v socat &>/dev/null; then
        error "socat kurulu değil. Kurun: apt install socat"
    fi

    # systemd service oluştur
    cat > /etc/systemd/system/srvctl-webhook.service << SERVICE
[Unit]
Description=srvctl Webhook Listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/srvctl/lib/webhook-listener.sh
Restart=always
RestartSec=5
User=root
Group=root
StandardOutput=append:${WEBHOOK_LOG}
StandardError=append:${WEBHOOK_LOG}
# O3 (haftalık denetim 2026-09): bu servis ağa (nginx üzerinden) açık, root
# çalışan bir bash HTTP ayrıştırıcısıdır; eskiden hiçbir sertleştirme yoktu.
# Aşağıdaki küme, listener'ın tetiklediği 'srvctl deploy'u KIRMAYAN alt
# kümedir. ProtectSystem=strict ve MemoryMax BİLEREK dışarıda bırakıldı:
# deploy'un yazma kümesi framework'e bağlıdır (bkz. srvctl-cron.service.tpl
# ReadWritePaths= yorumu) ve composer büyük projelerde 512M'ı aşabilir.
NoNewPrivileges=true
PrivateTmp=yes
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
TasksMax=512

[Install]
WantedBy=multi-user.target
SERVICE

    # Listener script'i oluştur
    cat > /usr/local/srvctl/lib/webhook-listener.sh << 'LISTENER'
#!/bin/bash
# srvctl Webhook HTTP Listener
# socat tabanlı, hafif webhook handler

SRVCTL_ROOT="/usr/local/srvctl"
WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"

source "${SRVCTL_ROOT}/conf/srvctl.conf"
source "${SRVCTL_ROOT}/lib/core.sh"

# _webhook_verify_sig <secret> <payload> <header_value>  (webhook.sh ile
# birebir aynı — argv-free HMAC-SHA256, bkz. o dosyadaki güvenlik notu).
# lib/webhook.sh source EDİLMEDİĞİNDEN (yalnız core.sh + conf) kopya
# zorunlu; sözleşme tests/test_webhook_listener_sig.sh ile kilitli — bu
# fonksiyon BİLEREK tek, kendi-kendine-yeten bir blok (awk ile ayıklanıyor).
_webhook_verify_sig() {
    local secret="$1" payload="$2" header="$3"
    [[ -z "$secret" ]] && return 1
    [[ -z "$header" ]] && return 1

    local block_size=64 key_hex
    key_hex=$(printf '%s' "$secret" | od -An -tx1 -v 2>/dev/null | tr -d ' \n')
    [[ -z "$key_hex" ]] && return 1
    if (( ${#key_hex} / 2 > block_size )); then
        key_hex=$(printf '%s' "$secret" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')
    fi
    key_hex=$(printf -- '%-128s' "$key_hex" | tr ' ' '0')

    local i hbyte xb ipad_hex="" opad_hex=""
    for (( i=0; i<${#key_hex}; i+=2 )); do
        hbyte="${key_hex:i:2}"
        printf -v xb '%02x' $(( 16#$hbyte ^ 16#36 )); ipad_hex+="$xb"
        printf -v xb '%02x' $(( 16#$hbyte ^ 16#5c )); opad_hex+="$xb"
    done

    local ipad_esc="" opad_esc=""
    for (( i=0; i<${#ipad_hex}; i+=2 )); do ipad_esc+="\\x${ipad_hex:i:2}"; done
    for (( i=0; i<${#opad_hex}; i+=2 )); do opad_esc+="\\x${opad_hex:i:2}"; done

    local hmac_hex
    hmac_hex=$( { printf '%b' "$ipad_esc"; printf '%s' "$payload"; } \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | { printf '%b' "$opad_esc"; cat; } \
        | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}' )
    [[ -z "$hmac_hex" ]] && return 1

    local expected="sha256=${hmac_hex}"
    local h_recv h_exp
    h_recv="$(printf '%s' "$header"  | openssl dgst -sha256 | awk '{print $NF}')"
    h_exp="$(printf '%s' "$expected" | openssl dgst -sha256 | awk '{print $NF}')"
    [[ "$h_recv" == "$h_exp" ]] && return 0
    return 1
}

# _webhook_check_replay <sname> <delivery_id>  (webhook.sh ile birebir aynı —
# bkz. o dosyadaki 'ring-buffer poisoning' notu: yalnız imza doğrulandıktan
# SONRA çağrılmalı).
_webhook_check_replay() {
    local sname="$1" delivery_id="$2"
    [[ -z "$delivery_id" ]] && return 1
    [[ "$delivery_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

    local dir="${SRVCTL_STATE_DIR:-/usr/local/srvctl/state}/_webhook/${sname}"
    secure_dir "$dir" 700
    local seen="${dir}/seen-delivery-ids" lock="${dir}/.lock"
    secure_file "$seen" 600

    local rc=1
    exec 9>"$lock"
    if flock -w 5 9; then
        if grep -qxF -- "$delivery_id" "$seen" 2>/dev/null; then
            rc=1
        else
            printf '%s\n' "$delivery_id" >> "$seen"
            tail -n 500 "$seen" > "${seen}.tmp" 2>/dev/null && mv -f "${seen}.tmp" "$seen"
            chmod 600 "$seen" 2>/dev/null || true
            rc=0
        fi
    fi
    exec 9>&-
    return "$rc"
}

handle_request() {
    local request=""
    local content_length=0
    local body=""

    # HTTP request headers oku
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ -z "$line" ]] && break
        request+="${line}\n"
        if [[ "$line" =~ ^Content-Length:\ ([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    # Body oku — O3: uygulama tarafı tavan (nginx'in client_max_body_size 1m
    # sınırı 127.0.0.1:${WEBHOOK_PORT}'a doğrudan bağlanan yerel işlem için
    # geçerli değil). 1 MiB üstü: 413, hiç okunmaz.
    if (( content_length > 1048576 )); then
        printf 'HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        return
    fi
    if [[ $content_length -gt 0 ]]; then
        body=$(head -c "$content_length")
    fi

    # URL'den domain çıkar
    local path
    path=$(echo -e "$request" | head -1 | awk '{print $2}')

    if [[ "$path" =~ ^/deploy/([a-zA-Z0-9_]+)$ ]]; then
        local sname="${BASH_REMATCH[1]}"
        local conf="/etc/srvctl/webhooks/${sname}.conf"

        if [[ -f "$conf" ]]; then
            source "$conf"

            # WEBHOOK_SECRET zorunlu — yoksa fail-closed (servis etme)
            if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nWebhook secret tanımsız"
                log_action "WEBHOOK REJECTED: ${sname} (secret tanımsız)"
                return
            fi

            # Signature doğrulama (GitHub) — fail-closed: header HER ZAMAN gerekli
            local hub_sig
            hub_sig=$(echo -e "$request" | grep -i "X-Hub-Signature-256" | awk '{print $2}' | tr -d '\r')
            if ! _webhook_verify_sig "${WEBHOOK_SECRET}" "$body" "$hub_sig"; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nImza geçersiz"
                log_action "WEBHOOK REJECTED: ${sname} (imza geçersiz/eksik)"
                return
            fi

            # ─── Replay koruması (O11 — DALGA 6) ───
            # İmza doğrulandıktan SONRA kontrol edilir (bkz.
            # _webhook_check_replay yorumu — ring-buffer poisoning önlemi).
            # GitHub/GitLab HER teslimatta benzersiz bir delivery-id
            # gönderir; aynı id ikinci kez görülürse (yakalanmış isteğin
            # tekrar oynatılması) reddedilir.
            local delivery_id
            delivery_id=$(echo -e "$request" | grep -i "X-GitHub-Delivery" | awk '{print $2}' | tr -d '\r')
            if [[ -z "$delivery_id" ]]; then
                delivery_id=$(echo -e "$request" | grep -i "X-Gitlab-Event-UUID" | awk '{print $2}' | tr -d '\r')
            fi
            if ! _webhook_check_replay "$sname" "$delivery_id"; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nTekrar oynatma tespit edildi veya delivery-id eksik"
                log_action "WEBHOOK REJECTED: ${sname} (replay/delivery-id eksik)"
                return
            fi

            # Branch kontrolü
            local push_branch
            push_branch=$(echo "$body" | jq -r '.ref // empty' 2>/dev/null | sed 's|refs/heads/||')
            if [[ -n "$push_branch" && "$push_branch" != "${WEBHOOK_BRANCH:-main}" ]]; then
                echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nSkipped (branch: ${push_branch})"
                return
            fi

            # Deploy başlat
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nDeploy started: ${WEBHOOK_DOMAIN}"

            # Asenkron deploy — GÜVENLİK (DALGA 6): eskiden burada, deploy'un
            # ÇIKIŞ KODUNU HİÇ KONTROL ETMEDEN, HER ZAMAN "success" bildirimi
            # gönderiliyordu; lib/deploy.sh artık KENDİ doğru bildirimini
            # (başarı/otomatik-rollback/başarısızlık, _deploy_notify) her
            # 'srvctl deploy' çağrısı için üretiyor — o çağrı BU webhook
            # tetiklemesini de kapsıyor. Burada AYRICA (ve YANLIŞ biçimde)
            # bildirim göndermek çifte/çelişkili bildirime yol açıyordu; bu
            # yüzden webhook'un kendi bildirimi KALDIRILDI (tek doğruluk
            # kaynağı deploy.sh). Çıkış kodu yine de log için PIPESTATUS[0]
            # ile yakalanır ('tee' pipe'ının kendi exit kodu değil, srvctl'in
            # exit kodu — pipe'ın SON komutu tee olduğundan '$?' burada
            # YANLIŞ olurdu).
            (
                sleep 2
                /usr/local/srvctl/bin/srvctl deploy "${WEBHOOK_DOMAIN}" "${WEBHOOK_BRANCH:-main}" 2>&1 | \
                    tee -a "${SRVCTL_ROOT}/logs/webhook.log"
                deploy_rc="${PIPESTATUS[0]}"
                log_action "WEBHOOK DEPLOY SONUCU: ${WEBHOOK_DOMAIN} (branch=${push_branch:-main}) exit=${deploy_rc}"
            ) &

            log_action "WEBHOOK DEPLOY: ${WEBHOOK_DOMAIN} (branch=${push_branch:-main})"
        else
            echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nDomain not configured"
        fi
    elif [[ "$path" == "/health" ]]; then
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nOK"
    else
        echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found"
    fi
}

# ─── Handle modu (socat 'fork' ile ÇAĞIRDIĞI HER bağlantı) ───
# GÜVENLİK/SAĞLAMLIK (DALGA 6 — item 4): bu kontrol BİLEREK aşağıdaki socat
# başlatma satırından ÖNCEDİR ve bulunursa HEMEN 'exit' eder. ÖNCEKİ tasarımda
# bu blok socat satırından SONRA idi: socat'ın 'fork'u her bağlantıda BU
# SCRIPT'İ 'handle' argümanıyla YENİDEN ÇALIŞTIRDIĞINDAN, script baştan sona
# okunuyor ve İKİNCİ bir socat başlatma denemesi (aynı porta, ana dinleyici
# ZATEN bağlıyken) EADDRINUSE ile başarısız oluyordu — kırılgan/gürültülü
# (her istekte fazladan fork+exec, log kirliliği) bir davranıştı. Erken
# 'exit' bunu YAPISAL olarak imkânsız kılar: 'handle' argümanıyla çağrılan
# bir çalıştırma socat satırına HİÇ ULAŞMAZ.
if [[ "${1:-}" == "handle" ]]; then
    handle_request
    exit 0
fi

# Yalnızca localhost'a bind — nginx reverse-proxy önde; port dışa açılmaz.
socat TCP-LISTEN:${WEBHOOK_PORT},bind=127.0.0.1,reuseaddr,fork SYSTEM:"/usr/local/srvctl/lib/webhook-listener.sh handle"
LISTENER
    chmod +x /usr/local/srvctl/lib/webhook-listener.sh

    # Port yalnızca 127.0.0.1'e bind; dışa UFW kuralı AÇILMAZ.
    # Dışarıdan erişim nginx reverse-proxy (TLS) üzerinden olmalı.

    # Başlat
    systemctl daemon-reload
    systemctl enable srvctl-webhook
    systemctl start srvctl-webhook

    success "Webhook listener aktif (port: ${WEBHOOK_PORT})"
    log_action "WEBHOOK START: port=${WEBHOOK_PORT}"
}

_webhook_stop() {
    systemctl stop srvctl-webhook 2>/dev/null
    systemctl disable srvctl-webhook 2>/dev/null
    success "Webhook listener durduruldu"
    log_action "WEBHOOK STOP"
}

_webhook_status() {
    header "Webhook Listener Durumu"

    if systemctl is-active srvctl-webhook > /dev/null 2>&1; then
        echo -e "  Durum: ${GREEN}● aktif${NC} (port: ${WEBHOOK_PORT})"
    else
        echo -e "  Durum: ${RED}● kapalı${NC}"
    fi

    divider

    echo -e "  ${CYAN}Yapılandırılmış Domain'ler${NC}"
    for conf in /etc/srvctl/webhooks/*.conf; do
        [[ ! -f "$conf" ]] && continue
        # shellcheck disable=SC1090
        source "$conf"
        echo "  🔗 ${WEBHOOK_DOMAIN} (branch: ${WEBHOOK_BRANCH:-main})"
    done

    divider

    echo -e "  ${CYAN}Son Webhook İşlemleri${NC}"
    tail -10 "${WEBHOOK_LOG}" 2>/dev/null || echo "  Log yok"

    echo ""
}
