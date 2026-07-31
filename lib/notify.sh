#!/bin/bash
# ═══════════════════════════════════════════════
#  notify.sh — Bildirim Sistemi
#  Telegram, Discord, Slack, webhook desteği
# ═══════════════════════════════════════════════

# Yapılandırma değişkenleri (srvctl.conf'tan okunur):
#   NOTIFY_TELEGRAM_TOKEN=bot123:ABC...
#   NOTIFY_TELEGRAM_CHAT_ID=-100123456
#   NOTIFY_DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
#   NOTIFY_SLACK_WEBHOOK=https://hooks.slack.com/services/...
#   NOTIFY_EMAIL=admin@example.com

cmd_notify() {
    case "${1:-help}" in
        test)   _notify_test ;;
        setup)  _notify_setup ;;
        *)
            echo ""
            echo "  Kullanım: srvctl notify <test|setup>"
            echo ""
            echo "    setup     Bildirim kanallarını yapılandır"
            echo "    test      Test bildirimi gönder"
            echo ""
            ;;
    esac
}

# ─── Ana Bildirim Fonksiyonu (PREDİKAT) ───
# Kullanım: send_notification "başlık" "mesaj" "seviye"
# Seviyeler: info, warning, critical
# DÖNÜŞ: 0 = yapılandırılmış TÜM kanallar başarıyla gönderdi
#        1 = en az bir kanal yapılandırılmıştı ve BAŞARISIZ oldu
#        2 = hiçbir bildirim kanalı yapılandırılmamış (gönderilecek bir şey yoktu)
# DALGA 6 / madde-5 düzeltmesi: eskiden her kanal fonksiyonu kendi içinde
# '|| true' ile başarısızlığı yutuyordu; 'notify test' KOŞULSUZ "gönderildi"
# diyordu (geçersiz token ile başarılı gönderim ayırt edilemiyordu). ÇAĞIRAN
# KARAR VERSİN diye burada yalnız gerçek sonucu DÖNDÜRÜYORUZ — deploy/monitor
# gibi kritik yollardan '|| true' ile çağrılmaya devam edebilir (bu fonksiyonun
# başarısızlığı ana işlemi DÜŞÜRMEMELİ), ama artık isteyen çağıran gerçek
# durumu görebilir (bkz. _notify_test, lib/ip.sh:_ip_ban, lib/cloudflare.sh:_cf_ddos).
send_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-info}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log'a yaz
    log_action "NOTIFY [${level}]: ${title} — ${message}"

    # Emoji seç
    local emoji="ℹ️"
    case "$level" in
        warning)  emoji="⚠️" ;;
        critical) emoji="🚨" ;;
        success)  emoji="✅" ;;
    esac

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local full_message="${emoji} *${title}*
🖥️ Sunucu: \`${hostname}\`
🕐 Zaman: \`${timestamp}\`

${message}"

    # Her yapılandırılmış kanal arka planda çalışır; PID + etiket kaydedilir ki
    # 'wait' sonrası HANGİ kanalın başarısız olduğu ayırt edilebilsin (eskiden
    # hepsi '|| true' ile aynı kefeye konuyordu).
    local pids=() labels=() attempted=0 failed=0

    if [[ -n "${NOTIFY_TELEGRAM_TOKEN:-}" && -n "${NOTIFY_TELEGRAM_CHAT_ID:-}" ]]; then
        _send_telegram "$full_message" &
        pids+=("$!"); labels+=("telegram"); attempted=$((attempted + 1))
    fi

    if [[ -n "${NOTIFY_DISCORD_WEBHOOK:-}" ]]; then
        _send_discord "$title" "$message" "$level" &
        pids+=("$!"); labels+=("discord"); attempted=$((attempted + 1))
    fi

    if [[ -n "${NOTIFY_SLACK_WEBHOOK:-}" ]]; then
        _send_slack "$title" "$message" "$level" &
        pids+=("$!"); labels+=("slack"); attempted=$((attempted + 1))
    fi

    if [[ -n "${NOTIFY_EMAIL:-}" ]] && command -v mail &>/dev/null; then
        ( echo -e "${message}" | mail -s "[srvctl][${level}] ${title}" "${NOTIFY_EMAIL}" ) 2>/dev/null &
        pids+=("$!"); labels+=("email"); attempted=$((attempted + 1))
    fi

    # "${pids[@]}" boş dizide 'set -u' altında bash <4.4'te (ör. macOS'un
    # sistem '/bin/bash' 3.2'si) "unbound variable" ile PATLAR — üretim hedefi
    # Ubuntu 22.04/24.04'te bash 5.x olduğundan bu ORADA sorun değildir, ama
    # bu proje macOS'ta da test edildiğinden ('_deploy_civil_epoch' yorumuna
    # bkz.) sayaç kapısıyla (${#pids[@]}) portable hale getiriyoruz.
    if (( ${#pids[@]} > 0 )); then
        local i=0 pid
        for pid in "${pids[@]}"; do
            if ! wait "$pid"; then
                failed=$((failed + 1))
                log_action "NOTIFY BAŞARISIZ: kanal=${labels[$i]:-?} başlık=${title}"
            fi
            i=$((i + 1))
        done
    fi

    if (( attempted == 0 )); then
        return 2
    elif (( failed > 0 )); then
        return 1
    fi
    return 0
}

_send_telegram() {
    local message="$1"
    # NOT: 'curl -f' HTTP >=400'de başarısız SAYAR — geçersiz token/chat_id
    # gibi durumlar artık gerçekten yansıyor ('|| true' YOK, dönüş değeri
    # send_notification() tarafından kontrol ediliyor).
    curl -sf -X POST \
        "https://api.telegram.org/bot${NOTIFY_TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${NOTIFY_TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" \
        > /dev/null 2>&1
}

_send_discord() {
    local title="$1"
    local message="$2"
    local level="$3"

    local color=3447003  # mavi
    case "$level" in
        warning)  color=16776960 ;;  # sarı
        critical) color=15158332 ;;  # kırmızı
        success)  color=3066993 ;;   # yeşil
    esac

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    curl -sf -X POST "${NOTIFY_DISCORD_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "{
            \"embeds\": [{
                \"title\": \"${title}\",
                \"description\": \"${message}\",
                \"color\": ${color},
                \"footer\": {\"text\": \"srvctl — ${hostname}\"},
                \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
            }]
        }" > /dev/null 2>&1
}

_send_slack() {
    local title="$1"
    local message="$2"
    local level="$3"

    local color="#36a64f"
    case "$level" in
        warning)  color="#ff9900" ;;
        critical) color="#ff0000" ;;
    esac

    curl -sf -X POST "${NOTIFY_SLACK_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "{
            \"attachments\": [{
                \"color\": \"${color}\",
                \"title\": \"${title}\",
                \"text\": \"${message}\",
                \"footer\": \"srvctl\",
                \"ts\": $(date +%s)
            }]
        }" > /dev/null 2>&1
}

_notify_setup() {
    require_root
    header "Bildirim Yapılandırması"

    echo "  Hangi kanalları kullanmak istiyorsunuz?"
    echo ""

    # Telegram
    read -rp "  Telegram Bot Token (boş = atla): " tg_token
    if [[ -n "$tg_token" ]]; then
        read -rp "  Telegram Chat ID: " tg_chat
        _update_conf "NOTIFY_TELEGRAM_TOKEN" "$tg_token"
        _update_conf "NOTIFY_TELEGRAM_CHAT_ID" "$tg_chat"
        success "Telegram yapılandırıldı"
    fi

    # Discord
    read -rp "  Discord Webhook URL (boş = atla): " dc_webhook
    if [[ -n "$dc_webhook" ]]; then
        _update_conf "NOTIFY_DISCORD_WEBHOOK" "$dc_webhook"
        success "Discord yapılandırıldı"
    fi

    # Slack
    read -rp "  Slack Webhook URL (boş = atla): " sl_webhook
    if [[ -n "$sl_webhook" ]]; then
        _update_conf "NOTIFY_SLACK_WEBHOOK" "$sl_webhook"
        success "Slack yapılandırıldı"
    fi

    # Email
    read -rp "  Email adresi (boş = atla): " email
    if [[ -n "$email" ]]; then
        _update_conf "NOTIFY_EMAIL" "$email"
        success "Email yapılandırıldı"
    fi

    echo ""
    info "Test göndermek için: srvctl notify test"
}

_notify_test() {
    load_config
    info "Test bildirimi gönderiliyor..."

    # DALGA 6 / madde-5 düzeltmesi: eskiden KOŞULSUZ "gönderildi" diyordu
    # (hiç kanal yapılandırılmamış olsa da, gönderim başarısız olsa da).
    # 'set -e' altında doğrudan 'send_notification ...' çağrısı nonzero
    # dönerse script'i DÜŞÜRÜR — bu yüzden if/else içinde tutuluyor.
    local rc=0
    if send_notification "Test Bildirimi" "srvctl bildirim sistemi düzgün çalışıyor." "success"; then
        rc=0
    else
        rc=$?
    fi

    case "$rc" in
        0) success "Test bildirimi gönderildi" ;;
        2) error "Hiçbir bildirim kanalı yapılandırılmamış — önce: srvctl notify setup" ;;
        *) error "Test bildirimi gönderilemedi: en az bir kanal başarısız oldu (token/webhook'u kontrol edin)" ;;
    esac
}

# Config dosyasına key=value ekle/güncelle
_update_conf() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "${SRVCTL_CONF}" 2>/dev/null; then
        _sed_inplace "${SRVCTL_CONF}" -e "s|^${key}=.*|${key}=${value}|" \
            || error "Config güncellenemedi: ${SRVCTL_CONF} (${key})"
    else
        echo "${key}=${value}" >> "${SRVCTL_CONF}"
    fi
}
