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

# Sunucunun KENDİ genel IP'leri (köken kilidinde yerel/aynı-makine çağrıları geçsin: sunucu kendi genel IP'sine
# bağlanırsa eş adresi o IP olur). SRVCTL_SELF_IPS tanımlıysa (boş dahil) AYNEN o kullanılır (test/NAT düzeltmesi);
# yoksa `ip -o addr show scope global`, yoksa `hostname -I`. Yalnız TEK IP kabul edilir (CIDR/çöp atılır). stdout: boşlukla ayrık.
_trusted_self_ips() {
    local raw="" a out="" seen=" "
    if [[ -n "${SRVCTL_SELF_IPS+x}" ]]; then
        raw="$SRVCTL_SELF_IPS"
    elif command -v ip >/dev/null 2>&1; then
        raw=$(ip -o addr show scope global 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "inet" || $i == "inet6") { sub(/\/.*/, "", $(i + 1)); print $(i + 1) } }')
    elif command -v hostname >/dev/null 2>&1; then
        raw=$(hostname -I 2>/dev/null || true)
    fi
    for a in $raw; do
        [[ "$a" == */* ]] && continue
        validate_ip_or_cidr "$a" || continue
        case "$seen" in *" ${a} "*) continue ;; esac
        seen+="${a} "
        out+="${out:+ }${a}"
    done
    printf '%s' "$out"
}

# Köken kilidinin geo bloğu (stdout). $1 = CF listesi dosyası, $2 = kendi IP'ler (boşlukla ayrık).
# `geo $realip_remote_addr`: realip, POST_READ aşamasında $remote_addr'ı istemci IP'siyle DEĞİŞTİRİR; allow/deny bu yüzden
# CF kenarını değil istemciyi görür. $realip_remote_addr ORİJİNAL TCP eşidir (realip bağlamı yoksa $remote_addr).
# Yinelenen ağlar tekilleştirilir (nginx geo aynı ağı iki kez görünce hata verir).
_trusted_render_geo() {
    local file="$1" selfips="${2:-}" ip
    {
        echo "# srvctl — köken kilidi geo kaynağı (otomatik oluşturuldu; srvctl trusted sync üretir, elle düzenlemeyin)"
        echo "# \$srvctl_via_cf = 1: bağlantı Cloudflare kenarından / yerel makineden; 0: köken IP'sine doğrudan."
        echo "# Kullanan: srvctl domain origin-lock <alan> on  (edge.d/<alan>/05-srvctl-origin-lock.conf)"
        echo 'geo $realip_remote_addr $srvctl_via_cf {'
        echo "    default 0;"
        {
            echo "127.0.0.1"
            echo "::1"
            for ip in $selfips; do echo "$ip"; done
            if [[ -f "$file" ]]; then
                while IFS= read -r ip; do [[ -n "$ip" ]] && echo "$ip"; done < "$file"
            fi
        } | awk 'NF && !seen[$1]++ { printf "    %s 1;\n", $1 }'
        echo "}"
    }
}

# Cloudflare listesinin adres AİLESİ başına sayısı: stdout "<v4> <v6>". Toplam satır sayısı tek başına yetmez: IPv4 girdisi 0 iken
# (yukarı akış kısmi ama geçerli bir liste verdi) IPv6 satırları toplamı eşiğe taşırdı ve köken yalnız IPv4 dinlediği için TÜM
# Cloudflare trafiği 444 alırdı.
_trusted_family_counts() {
    awk '/:/ { v6++; next } NF { v4++ } END { printf "%d %d\n", v4 + 0, v6 + 0 }' "$1" 2>/dev/null || echo "0 0"
}

# geo dosyasını yazan çekirdek: fm-auth kilidi (_fmprov_with_lock) ALTINDA çalışır (edge.sh yazımlarıyla aynı kilit; yarış yok).
# Liste yoksa/boşsa/çok kısaysa YAZILMAZ: default 0 + boş liste TÜM Cloudflare trafiğini 444'e çevirirdi; yazılmayan dosya mevcut
# kilitleri eski listeyle çalışır halde bırakır ve yeni kilit açılmasını engeller (origin-lock on dosya yoksa reddeder). Eşik
# AİLE BAŞINA: IPv4 >= TRUSTED_GEO_MIN_V4 (varsayılan 10; Cloudflare ~15) VE IPv6 >= TRUSTED_GEO_MIN_V6 (varsayılan 5; ~7).
# `nginx -t` düşerse önceki hâl geri yüklenir; ÖNCEKİ HÂL YOKSA (ilk yazım) geo silinir VE $srvctl_via_cf'ye başvuran açık köken
# kilitleri de geri alınır (tanımsız değişkene başvuran kilit dosyası kalmasın; nginx yeniden yüklenebilsin).
# rc 0 yazıldı | 1 yazılmadı (neden uyarıda).
_trusted_apply_geo_locked() {
    local conf="${NGINX_CF_GEO_CONF:-/etc/nginx/conf.d/srvctl-cf-origin-geo.conf}"
    local list="${TRUSTED_STATE_DIR}/cloudflare.conf" content bk="" selfips tmp v4 v6 min4 min6
    if ! _trusted_sane 8 "$list"; then
        warn "köken kilidi geo dosyası yazılmadı: Cloudflare listesi yok/boş/eksik (${list}) — mevcut kilitler eski listeyle sürer, yeni kilit açılamaz"
        return 1
    fi
    min4="${TRUSTED_GEO_MIN_V4:-10}"; min6="${TRUSTED_GEO_MIN_V6:-5}"
    [[ "$min4" =~ ^[1-9][0-9]{0,3}$ ]] || min4=10
    [[ "$min6" =~ ^[1-9][0-9]{0,3}$ ]] || min6=5
    read -r v4 v6 <<< "$(_trusted_family_counts "$list")"
    if (( v4 < min4 || v6 < min6 )); then
        warn "köken kilidi geo dosyası yazılmadı: Cloudflare listesinde IPv4=${v4} (en az ${min4}), IPv6=${v6} (en az ${min6}) aralık var — aile başına eşik geçilmedi (IPv4 0 iken yazılsaydı TÜM Cloudflare trafiği 444 olurdu); mevcut kilitler eski listeyle sürer"
        return 1
    fi
    selfips=$(_trusted_self_ips)
    content=$(_trusted_render_geo "$list" "$selfips")
    [[ -d "$(dirname "$conf")" ]] || { warn "köken kilidi geo dosyası yazılamadı: dizin yok: $(dirname "$conf")"; return 1; }
    if [[ -e "$conf" || -L "$conf" ]]; then
        [[ -L "$conf" ]] && { warn "geo dosyası sembolik bağ — yazılmadı: ${conf}"; return 1; }
        bk=$(mktemp "${conf}.srvctl-bk.XXXXXX") || return 1
        cp -p "$conf" "$bk" || { rm -f -- "$bk"; return 1; }
    fi
    tmp=$(mktemp "${conf}.srvctl.XXXXXX") || { [[ -n "$bk" ]] && rm -f -- "$bk"; return 1; }
    if ! { printf '%s\n' "$content" > "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$conf"; }; then
        rm -f -- "$tmp"; [[ -n "$bk" ]] && rm -f -- "$bk"
        warn "geo dosyası yazılamadı: ${conf}"; return 1
    fi
    if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        if [[ -n "$bk" ]]; then
            mv -f -- "$bk" "$conf"
        else
            rm -f -- "$conf"
            # İlk yazım geri alındı: $srvctl_via_cf artık TANIMSIZ. Ona başvuran açık kilitler nginx'in yüklenmesini engellerdi.
            if declare -F _edge_origin_locks_drop_all >/dev/null 2>&1 || { [[ -f "${SRVCTL_ROOT:-}/lib/edge.sh" ]] && source "${SRVCTL_ROOT}/lib/edge.sh" 2>/dev/null; }; then
                _edge_origin_locks_drop_all || true
            fi
        fi
        warn "nginx -t geo dosyasıyla BAŞARISIZ — önceki hâl geri yüklendi: ${conf}"
        return 1
    fi
    [[ -n "$bk" ]] && rm -f -- "$bk"
    return 0
}

# geo dosyasını yaz (nginx reload YOK; sync sonunda apply_realip tek reload yapar). fm-auth kilidi altında.
_trusted_apply_geo() {
    local rc=0
    if ! declare -F _fmprov_with_lock >/dev/null 2>&1; then
        if [[ -f "${SRVCTL_ROOT:-}/lib/domconf.sh" ]]; then
            # shellcheck disable=SC1091
            source "${SRVCTL_ROOT}/lib/domconf.sh" 2>/dev/null || true
        fi
    fi
    if ! declare -F _fmprov_with_lock >/dev/null 2>&1; then
        warn "köken kilidi geo dosyası yazılmadı: fm-auth kilidi yüklenemedi (lib/domconf.sh) — kilitsiz yazım YAPILMAZ"
        return 1
    fi
    _fmprov_with_lock _trusted_apply_geo_locked || rc=$?
    return "$rc"
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
    # geo (köken kilidi) realip ile AYNI eşitleme adımında ve AYNI cloudflare.conf'tan; reload'u apply_realip tek yapar.
    _trusted_apply_geo || true
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
    # köken kilidi geo dosyası (srvctl domain origin-lock bunu ister)
    local g="${NGINX_CF_GEO_CONF:-/etc/nginx/conf.d/srvctl-cf-origin-geo.conf}"
    if [[ -f "$g" ]]; then
        echo "    köken-kilidi geo: var  (son: $(date -r "$g" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))"
    else
        echo "    köken-kilidi geo: YOK  (srvctl trusted sync üretir; origin-lock on için gerekli)"
    fi
}

cmd_trusted() {
    case "${1:-help}" in
        sync)  require_root; _trusted_sync ;;
        list)  _trusted_list ;;
        *)
            # Bilinmeyen alt komut kullanımı basar ama rc≠0 döner; yalnız açık yardım isteği rc 0.
            local _usage_rc=1
            case "${1:-help}" in help|-h|--help) _usage_rc=0 ;; esac
            [[ "$_usage_rc" -eq 0 ]] || warn "Bilinmeyen trusted alt komutu: ${1}"
            echo "  Kullanım: srvctl trusted <sync|list>"
            echo "    sync   Cloudflare + UptimeRobot IP'lerini çek, allowlist'e uygula"
            echo "    list   Yönetilen güvenilir IP'leri ve son senkronu göster"
            return "$_usage_rc"
            ;;
    esac
}
