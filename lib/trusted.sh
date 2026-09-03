#!/bin/bash
# ═══════════════════════════════════════════════
#  srvctl — Güvenilir Edge-IP Senkronu (Cloudflare + UptimeRobot)
#  IP listelerini çeker, allowlist'e (fail2ban ignoreip) işler,
#  Cloudflare için nginx real-IP restorasyonu kurar.
# ═══════════════════════════════════════════════

# Ham IP listesini satır-satır doğrula; yalnız geçerli IP/CIDR'leri stdout'a yaz.
# Yorumlar (#...), boş satırlar, CR ve geçersiz satırlar ayıklanır. Dosya yoksa boş.
_trusted_parse_validate() {
    local file="$1" line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                 # satır-içi yorumu at
        line="${line//[$' \t\r']/}"        # boşluk/tab/CR temizle
        [[ -n "$line" ]] || continue
        # Y2: '/0' gibi aşırı geniş aralıklar REDDEDİLİR (bkz. core.sh
        # validate_ip_or_cidr_narrow gerekçesi). Bu liste fail2ban allowlist'ine
        # ve nginx set_real_ip_from'a gider; genişlik tavanı fail-closed'dır.
        if ! validate_ip_or_cidr "$line"; then
            continue
        fi
        if ! validate_ip_or_cidr_narrow "$line" 8 16; then
            warn "trusted: AŞIRI GENİŞ aralık REDDEDİLDİ: ${line} (v4 ≥ /8, v6 ≥ /16 gerekli)"
            continue
        fi
        echo "$line"
    done < "$file"
}

# Liste yeterli mi (boş/çöp yanıt koruması). $1=min satır sayısı, $2=dosya.
# Y2: bir de ÜST sınır var — Cloudflare ~22, UptimeRobot ~100 satır yayınlar;
# binlerce satırlık bir yanıt (yanlış URL, ele geçirilmiş kaynak) reddedilir.
_trusted_sane() {
    local min="$1" file="$2" count max="${TRUSTED_MAX_LINES:-500}"
    [[ -f "$file" ]] || return 1
    count=$(grep -c . "$file" 2>/dev/null || echo 0)
    (( count >= min && count <= max ))
}

# CF listesinden nginx real-ip bloğu üret (stdout). Yalnız Cloudflare aralıkları.
_trusted_render_realip() {
    local file="$1" ip
    echo "# srvctl — Cloudflare real IP (otomatik oluşturuldu)"
    if [[ -f "$file" ]]; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
        done < "$file"
    fi
    echo "real_ip_header CF-Connecting-IP;"
}

# ignoreip satırını türet: base + verilen dosyalardaki IP'ler, sıra-koruyan dedup,
# tek satır (stdout). Eksik dosyalar atlanır.
_trusted_compute_ignoreip() {
    local base="$1"; shift
    local f ip
    {
        printf '%s\n' "$base"
        for f in "$@"; do
            [[ -f "$f" ]] || continue
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && printf '%s\n' "$ip"
            done < "$f"
        done
    } | awk 'NF && !seen[$0]++' | paste -sd' ' -
}

# Fetch: SRVCTL_TRUSTED_FIXTURE_DIR set ise fixture'dan, yoksa curl. $3=fixture adı.
_trusted_fetch() {
    local url="$1" dest="$2" name="$3"
    if [[ -n "${SRVCTL_TRUSTED_FIXTURE_DIR:-}" ]]; then
        [[ -f "${SRVCTL_TRUSTED_FIXTURE_DIR}/${name}" ]] || return 1
        cat "${SRVCTL_TRUSTED_FIXTURE_DIR}/${name}" > "$dest"
        return 0
    fi
    # Y2: yalnız HTTPS + TLS1.2+ ve yönlendirme YOK (init.sh'daki composer
    # indirmesiyle aynı desen). Config'te URL 'http://'ye çevrilse bile
    # düz metin çekilmez — curl '--proto' ihlalinde başarısız döner.
    curl -sf --proto '=https' --tlsv1.2 --max-redirs 0 --max-time 20 "$url" -o "$dest" 2>/dev/null
}

# ignoreip'i fail2ban jail.local'e uygula (+ reload, fail2ban varsa).
_trusted_apply_ignoreip() {
    local jail="${FAIL2BAN_JAIL_LOCAL:-/etc/fail2ban/jail.local}"
    local manual="/etc/srvctl/ip-whitelist.conf"
    local line tmp
    line=$(_trusted_compute_ignoreip "127.0.0.1/8" "$manual" \
        "${TRUSTED_STATE_DIR}/cloudflare.conf" "${TRUSTED_STATE_DIR}/uptimerobot.conf")
    [[ -f "$jail" ]] || return 0
    if grep -q '^ignoreip = ' "$jail"; then
        # Düşük (denetim 2026-09): eski 'mktemp + mv' jail.local'in modunu/
        # sahipliğini mktemp'in 0600'üne indirgiyordu; _sed_inplace korur.
        _sed_inplace "$jail" -e "s|^ignoreip = .*|ignoreip = ${line}|" \
            || { warn "fail2ban ignoreip güncellenemedi: ${jail}"; return 1; }
    else
        printf '\n[DEFAULT]\nignoreip = %s\n' "$line" >> "$jail"
    fi
    command -v fail2ban-client >/dev/null 2>&1 && systemctl reload fail2ban 2>/dev/null || true
}

# Cloudflare real-ip conf'unu yaz (+ nginx reload, nginx varsa).
_trusted_apply_realip() {
    local conf="${NGINX_CF_REALIP_CONF:-/etc/nginx/conf.d/srvctl-cloudflare-realip.conf}"
    _trusted_render_realip "${TRUSTED_STATE_DIR}/cloudflare.conf" > "$conf"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
}

# Tüm kaynakları çek → doğrula → sanity → (başarıda) kaydet; sonra uygula. Fail-safe.
_trusted_sync() {
    mkdir -p "$TRUSTED_STATE_DIR"
    local src t1 t2 combined
    for src in $TRUSTED_SOURCES; do
        case "$src" in
            cloudflare)
                t1=$(mktemp); t2=$(mktemp); combined=$(mktemp)
                if _trusted_fetch "$CLOUDFLARE_IPS_V4_URL" "$t1" "cloudflare-v4" \
                   && _trusted_fetch "$CLOUDFLARE_IPS_V6_URL" "$t2" "cloudflare-v6"; then
                    { _trusted_parse_validate "$t1"; _trusted_parse_validate "$t2"; } > "$combined"
                    if _trusted_sane 8 "$combined"; then
                        mv "$combined" "${TRUSTED_STATE_DIR}/cloudflare.conf"
                        info "Cloudflare IP listesi güncellendi ($(grep -c . "${TRUSTED_STATE_DIR}/cloudflare.conf") satır)"
                    else
                        warn "Cloudflare listesi boş/eksik — mevcut liste korunuyor"
                    fi
                else
                    warn "Cloudflare IP fetch başarısız — mevcut liste korunuyor"
                fi
                rm -f "$t1" "$t2" "$combined"
                ;;
            uptimerobot)
                t1=$(mktemp); combined=$(mktemp)
                if _trusted_fetch "$UPTIMEROBOT_IPS_URL" "$t1" "uptimerobot"; then
                    _trusted_parse_validate "$t1" > "$combined"
                    if _trusted_sane 5 "$combined"; then
                        mv "$combined" "${TRUSTED_STATE_DIR}/uptimerobot.conf"
                        info "UptimeRobot IP listesi güncellendi ($(grep -c . "${TRUSTED_STATE_DIR}/uptimerobot.conf") satır)"
                    else
                        warn "UptimeRobot listesi boş/eksik — mevcut liste korunuyor"
                    fi
                else
                    warn "UptimeRobot IP fetch başarısız — mevcut liste korunuyor"
                fi
                rm -f "$t1" "$combined"
                ;;
        esac
    done
    _trusted_apply_ignoreip
    _trusted_apply_realip
    log_action "TRUSTED SYNC" 2>/dev/null || true
    success "Güvenilir IP senkronu tamamlandı"
}

# Yönetilen güvenilir IP'leri ve son senkronu göster.
_trusted_list() {
    local src f
    echo "  Güvenilir IP'ler (${TRUSTED_STATE_DIR})"
    for src in cloudflare uptimerobot; do
        f="${TRUSTED_STATE_DIR}/${src}.conf"
        if [[ -f "$f" ]]; then
            echo "    ${src}: $(grep -c . "$f") IP  (son: $(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))"
        else
            echo "    ${src}: (henüz senkron edilmedi)"
        fi
    done
}

cmd_trusted() {
    case "${1:-help}" in
        sync)  require_root; _trusted_sync ;;
        list)  _trusted_list ;;
        help|*)
            echo "  Kullanım: srvctl trusted <sync|list>"
            echo "    sync   Cloudflare + UptimeRobot IP'lerini çek, allowlist'e uygula"
            echo "    list   Yönetilen güvenilir IP'leri ve son senkronu göster"
            ;;
    esac
}
