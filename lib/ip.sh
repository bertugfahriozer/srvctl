#!/bin/bash
# ═══════════════════════════════════════════════
#  ip.sh — IP Engelleme / İzin Listesi Yönetimi
# ═══════════════════════════════════════════════

cmd_ip() {
    require_root
    case "${1:-help}" in
        ban)       _ip_ban "${@:2}" ;;
        unban)     _ip_unban "${@:2}" ;;
        whitelist) _ip_whitelist "${@:2}" ;;
        blacklist) _ip_blacklist "${@:2}" ;;
        list)      _ip_list ;;
        geoblock)  _ip_geoblock "${@:2}" ;;
        reapply)   _ip_reapply_all ;;
        *)
            echo ""
            echo "  Kullanım: srvctl ip <ban|unban|whitelist|blacklist|list|geoblock|reapply>"
            echo ""
            echo "    ban <ip> [süre]           IP'yi engelle (varsayılan: 24h)"
            echo "    unban <ip>                IP engelini kaldır"
            echo "    whitelist add <ip>        Beyaz listeye ekle"
            echo "    whitelist remove <ip>     Beyaz listeden çıkar"
            echo "    blacklist add <ip>        Kalıcı engelle"
            echo "    blacklist remove <ip>     Kalıcı engeli kaldır"
            echo "    list                      Engelli IP'leri listele"
            echo "    geoblock add <ülke_kodu>  Ülkeyi engelle (TR, RU, CN...)"
            echo "    geoblock remove <ülke>    Ülke engelini kaldır"
            echo "    geoblock list             Engelli ülkeleri listele"
            echo "    reapply                   Kayıtlı ban/whitelist/geoblock kurallarını"
            echo "                              ufw+fail2ban+nginx'e yeniden uygula"
            echo "                              (ör. 'srvctl init --force' sonrası)"
            echo ""
            ;;
    esac
}

# ─── Test edilebilir doğrulama kapıları (predicate; error/exit YOK) ───
# Komut girişlerinde kullanılan predikatları birebir uygular.
_ip_value_gate()    { validate_ip_or_cidr "$1"; }
_ip_duration_gate() { [[ "$1" == "permanent" ]] || validate_uint "$1"; }
_ip_geoblock_gate() { validate_country "$(echo "$1" | tr '[:lower:]' '[:upper:]')"; }

_ip_ban() {
    local ip="$1"
    local duration="${2:-86400}"  # varsayılan 24 saat

    [[ -z "$ip" ]] && error "IP belirtilmedi."
    _ip_value_gate "$ip" || error "Geçersiz IP/CIDR: ${ip}"
    _ip_duration_gate "$duration" || error "Geçersiz süre: ${duration} (saniye sayısı veya 'permanent')"

    # UFW ile engelle — O4 (denetim 2026-09): çıkış kodu HİÇ kontrol edilmiyor,
    # ufw pasifken/kural limiti doluyken bile "engellendi" deniyordu.
    if ufw insert 1 deny from "$ip" to any comment "srvctl-ban-$(date +%s)" > /dev/null 2>&1; then
        success "IP engellendi: ${ip} (${duration}s)"
    else
        error "UFW kuralı EKLENEMEDİ: ${ip} — IP ENGELLENMEDİ ('ufw status' kontrol edin)."
    fi

    # Süre sonunda otomatik kaldır
    if [[ "$duration" != "permanent" ]]; then
        (sleep "$duration" && ufw delete deny from "$ip" to any 2>/dev/null) &
        info "Otomatik kaldırılacak: ${duration} saniye sonra"
    fi

    # Bildirim (modül YOKSA sessizce atla — 'source ... || true' EKSİKTİ,
    # 'set -e' altında dosya bulunamazsa TÜM komutu düşürebilirdi).
    # shellcheck disable=SC1091
    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
    # DALGA 6 / madde-5: send_notification artık PREDİKAT (0/1/2) —
    # başarısızlık ana işlemi düşürmemeli ('||') ama artık görünür (warn).
    if declare -F send_notification >/dev/null 2>&1; then
        send_notification "🚫 IP Engellendi" "IP: ${ip} (süre: ${duration}s)" "warning" \
            || warn "Bildirim gönderilemedi (IP ban: ${ip})"
    fi

    log_action "IP BAN: ${ip} (duration=${duration})"
}

_ip_unban() {
    local ip="$1"
    [[ -z "$ip" ]] && error "IP belirtilmedi."

    ufw delete deny from "$ip" to any 2>/dev/null
    # Fail2Ban'dan da kaldır
    for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g'); do
        fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null || true
    done

    success "IP engeli kaldırıldı: ${ip}"
    log_action "IP UNBAN: ${ip}"
}

_ip_whitelist() {
    local action="$1" ip="$2"
    local whitelist_file="/etc/srvctl/ip-whitelist.conf"
    mkdir -p /etc/srvctl

    case "$action" in
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            _ip_value_gate "$ip" || error "Geçersiz IP/CIDR: ${ip}"
            echo "$ip" >> "$whitelist_file"
            sort -u -o "$whitelist_file" "$whitelist_file"

            # Fail2Ban'a ignoreip olarak ekle
            if [[ -f /etc/fail2ban/jail.local ]] && ! grep -q "$ip" /etc/fail2ban/jail.local 2>/dev/null; then
                if _sed_inplace /etc/fail2ban/jail.local -e "s|^ignoreip = |ignoreip = ${ip} |"; then
                    systemctl reload fail2ban 2>/dev/null || true
                else
                    warn "fail2ban ignoreip güncellenemedi (jail.local) — beyaz liste fail2ban'a YANSITILMADI: ${ip}"
                fi
            fi

            # Nginx'e güvenilir IP olarak ekle (O4: başarısızlık artık görünür)
            _update_nginx_whitelist \
                || error "nginx beyaz listesi CANLIYA ALINAMADI (nginx -t başarısız) — ${ip} dosyada, nginx'te DEĞİL"

            success "Beyaz listeye eklendi: ${ip}"
            log_action "IP WHITELIST ADD: ${ip}"
            ;;
        remove)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            if [[ -f "$whitelist_file" ]]; then
                _sed_inplace "$whitelist_file" -e "/^${ip}$/d" \
                    || warn "Beyaz liste dosyası güncellenemedi: ${whitelist_file}"
            fi
            _update_nginx_whitelist \
                || error "nginx beyaz listesi CANLIYA ALINAMADI (nginx -t başarısız) — dosya güncellendi, nginx'te DEĞİL"
            success "Beyaz listeden çıkarıldı: ${ip}"
            log_action "IP WHITELIST REMOVE: ${ip}"
            ;;
        *)
            error "Kullanım: srvctl ip whitelist <add|remove> <ip>"
            ;;
    esac
}

_ip_blacklist() {
    local action="$1" ip="$2"
    local blacklist_file="/etc/srvctl/ip-blacklist.conf"
    mkdir -p /etc/srvctl

    case "$action" in
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            _ip_value_gate "$ip" || error "Geçersiz IP/CIDR: ${ip}"
            echo "$ip" >> "$blacklist_file"
            sort -u -o "$blacklist_file" "$blacklist_file"

            # UFW'ye kalıcı engel (O4: başarısızlık artık görünür; dosyaya
            # yazıldığı için 'ip reapply' ile tekrar denenebilir)
            ufw insert 1 deny from "$ip" to any comment "srvctl-blacklist" > /dev/null 2>&1 \
                || warn "UFW kuralı eklenemedi: ${ip} — kara listeye yazıldı, 'srvctl ip reapply' ile tekrar deneyin"

            # Nginx deny listesini güncelle
            _update_nginx_blacklist \
                || error "nginx kara listesi CANLIYA ALINAMADI (nginx -t başarısız) — ${ip} dosyada, nginx'te DEĞİL"

            success "Kalıcı engellendi: ${ip}"
            log_action "IP BLACKLIST ADD: ${ip}"
            ;;
        remove)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            if [[ -f "$blacklist_file" ]]; then
                _sed_inplace "$blacklist_file" -e "/^${ip}$/d" \
                    || warn "Kara liste dosyası güncellenemedi: ${blacklist_file}"
            fi
            ufw delete deny from "$ip" to any 2>/dev/null

            _update_nginx_blacklist \
                || error "nginx kara listesi CANLIYA ALINAMADI (nginx -t başarısız) — dosya güncellendi, nginx'te DEĞİL"

            success "Kalıcı engel kaldırıldı: ${ip}"
            log_action "IP BLACKLIST REMOVE: ${ip}"
            ;;
        *)
            error "Kullanım: srvctl ip blacklist <add|remove> <ip>"
            ;;
    esac
}

_ip_list() {
    header "IP Engel/İzin Listeleri"

    echo -e "  ${CYAN}Beyaz Liste${NC}"
    if [[ -f /etc/srvctl/ip-whitelist.conf ]]; then
        while IFS= read -r ip; do
            echo "    ✅ ${ip}"
        done < /etc/srvctl/ip-whitelist.conf
    else
        echo "    (boş)"
    fi

    divider

    echo -e "  ${CYAN}Kara Liste (Kalıcı)${NC}"
    if [[ -f /etc/srvctl/ip-blacklist.conf ]]; then
        while IFS= read -r ip; do
            echo "    🚫 ${ip}"
        done < /etc/srvctl/ip-blacklist.conf
    else
        echo "    (boş)"
    fi

    divider

    echo -e "  ${CYAN}Fail2Ban Bans (Geçici)${NC}"
    if command -v fail2ban-client &>/dev/null; then
        while IFS= read -r jail; do
            jail=$(echo "$jail" | xargs)
            [[ -z "$jail" ]] && continue
            local banned_ips
            banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list" | sed 's/.*://')
            [[ -n "$banned_ips" ]] && echo "    ${jail}: ${banned_ips}"
        done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g')
    fi

    divider

    echo -e "  ${CYAN}GeoIP Engelli Ülkeler${NC}"
    if [[ -f /etc/srvctl/geoblock.conf ]]; then
        while IFS= read -r country; do
            echo "    🌍 ${country}"
        done < /etc/srvctl/geoblock.conf
    else
        echo "    (boş)"
    fi

    echo ""
}

_ip_geoblock() {
    local action="$1" country="$2"
    local geoblock_file="/etc/srvctl/geoblock.conf"
    mkdir -p /etc/srvctl

    case "$action" in
        add)
            [[ -z "$country" ]] && error "Ülke kodu belirtilmedi (ör: CN, RU, KP)"
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            validate_country "$country" || error "Geçersiz ülke kodu: ${country} (2 harfli ISO, ör: CN, RU)"
            echo "$country" >> "$geoblock_file"
            sort -u -o "$geoblock_file" "$geoblock_file"

            if _update_nginx_geoblock; then
                success "Ülke engellendi: ${country} (nginx haritası güncellendi)"
                info "Devreye almak için ilgili vhost'a şunu ekleyin: if (\$blocked_country) { return 403; }"
            else
                warn "Ülke listeye eklendi ama nginx haritası uygulanamadı: ${country} (GeoIP modülü/veritabanı kurulu mu? 'srvctl init' kontrol edin)"
            fi
            log_action "GEOBLOCK ADD: ${country}"
            ;;
        remove)
            [[ -z "$country" ]] && error "Ülke kodu belirtilmedi."
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            if [[ -f "$geoblock_file" ]]; then
                _sed_inplace "$geoblock_file" -e "/^${country}$/d" \
                    || warn "GeoIP liste dosyası güncellenemedi: ${geoblock_file}"
            fi

            if _update_nginx_geoblock; then
                success "Ülke engeli kaldırıldı: ${country}"
            else
                warn "Ülke listeden çıkarıldı ama nginx haritası güncellenirken sorun oluştu: ${country}"
            fi
            log_action "GEOBLOCK REMOVE: ${country}"
            ;;
        list)
            if [[ -f "$geoblock_file" && -s "$geoblock_file" ]]; then
                echo ""
                echo -e "  ${BOLD}Engelli Ülkeler${NC}"
                divider
                while IFS= read -r c; do
                    echo "  🌍 ${c}"
                done < "$geoblock_file"
                echo ""
                echo "  NOT: nginx haritası ('\$blocked_country') hazır ama devreye almak için"
                echo "       ilgili vhost'a manuel olarak eklenmesi gerekir:"
                echo "       if (\$blocked_country) { return 403; }"
                echo ""
            else
                info "GeoIP engeli tanımlanmamış"
            fi
            ;;
        *)
            error "Kullanım: srvctl ip geoblock <add|remove|list> [ülke_kodu]"
            ;;
    esac
}

# ─── init --force sonrası ban/whitelist/geoblock kurallarını yeniden uygula ───
# 'srvctl init --force' 'ufw --force reset' ile UFW'yi SIFIRLAR (bkz.
# lib/init.sh) ama /etc/srvctl/ip-whitelist.conf ve ip-blacklist.conf DİSKTE
# KALIR — operatör firewall'un sıfırlandığını fark etmeyebilir, ban/whitelist
# kaybolmuş görünmeden devam eder (DALGA 6 bulgusu). Bu fonksiyon MEVCUT conf
# dosyalarından ufw/fail2ban/nginx durumunu YENİDEN üretir; idempotenttir,
# ne zaman çağrılırsa çağrılsın güvenlidir.
# DEVREDİLEN İŞ: lib/init.sh'ın '--force' akışının SONUNDA
#   source "${SRVCTL_ROOT}/lib/ip.sh" 2>/dev/null && _ip_reapply_all
# çağrısını (guard'lı) eklemesi gerekir — lib/init.sh bu dosyanın SAHİBİ
# OLMADIĞIMIZ bir modül olduğundan buradan eklenemiyor.
_ip_reapply_all() {
    local bl_count=0 wl_count=0 ip

    # Kara liste → UFW kalıcı deny kuralları
    if [[ -f /etc/srvctl/ip-blacklist.conf ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            if _ip_value_gate "$ip"; then
                ufw insert 1 deny from "$ip" to any comment "srvctl-blacklist" > /dev/null 2>&1
                bl_count=$((bl_count + 1))
            else
                warn "Kara listede geçersiz IP/CIDR atlandı: ${ip}"
            fi
        done < /etc/srvctl/ip-blacklist.conf
    fi

    # Beyaz liste → fail2ban ignoreip (jail.local varsa)
    if [[ -f /etc/srvctl/ip-whitelist.conf ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            if ! _ip_value_gate "$ip"; then
                warn "Beyaz listede geçersiz IP/CIDR atlandı: ${ip}"
                continue
            fi
            wl_count=$((wl_count + 1))
            if [[ -f /etc/fail2ban/jail.local ]] && ! grep -q "$ip" /etc/fail2ban/jail.local 2>/dev/null; then
                _sed_inplace /etc/fail2ban/jail.local -e "s|^ignoreip = |ignoreip = ${ip} |" \
                    || warn "fail2ban ignoreip güncellenemedi: ${ip}"
            fi
        done < /etc/srvctl/ip-whitelist.conf
        systemctl reload fail2ban 2>/dev/null || true
    fi

    # Nginx snippet'lerini (whitelist/blacklist/geoblock) yeniden üret —
    # idempotent, mevcut conf dosyalarından yeniden yazar.
    _update_nginx_whitelist || warn "nginx beyaz listesi canlıya alınamadı (yukarıdaki uyarıya bakın)"
    _update_nginx_blacklist || warn "nginx kara listesi canlıya alınamadı (yukarıdaki uyarıya bakın)"
    _update_nginx_geoblock || warn "GeoIP haritası yeniden uygulanırken sorun oluştu (yukarıdaki uyarıya bakın)"

    success "IP kuralları yeniden uygulandı (kara liste: ${bl_count} IP, beyaz liste: ${wl_count} IP)"
    log_action "IP REAPPLY: blacklist=${bl_count} whitelist=${wl_count}"
}

# ─── O4 DÜZELTMESİ (haftalık denetim 2026-09) ───
# ESKİ: 'nginx -t && reload || true' — test başarısızsa sonuç YUTULUYOR, fonksiyon
# 0 dönüyor, çağıran "Kalıcı engellendi" basıyordu (kural canlıda DEĞİL) ve bozuk
# conf.d dosyası diskte kalıp sonraki ilgisiz reload'ları da düşürüyordu.
# Dosyadan okunan IP'ler doğrulanmıyordu (oysa _ip_reapply_all doğruluyor).
# YENİ: _update_nginx_geoblock ile aynı desen — geçersiz satır atlanır, nginx -t
# başarısızsa dosya geri alınır ve 1 döner; reload başarısızlığı uyarıdır.
# $1=allow|deny, $2=kaynak liste, $3=hedef conf, $4=başlık
_ip_render_nginx_list() {
    local directive="$1" src="$2" conf="$3" title="$4" ip tmp
    tmp="$(mktemp "${conf}.srvctl.XXXXXX")" || { warn "geçici dosya oluşturulamadı: ${conf}"; return 1; }
    {
        echo "# srvctl ${title} — otomatik oluşturuldu"
        if [[ -f "$src" ]]; then
            while IFS= read -r ip; do
                [[ -n "$ip" ]] || continue
                validate_ip_or_cidr "$ip" || { warn "${src}: geçersiz IP atlandı: ${ip}"; continue; }
                echo "${directive} ${ip};"
            done < "$src"
        fi
    } > "$tmp"
    local had_old=0 bak=""
    if [[ -f "$conf" ]]; then
        had_old=1; bak="$(mktemp "${conf}.bak.XXXXXX")" && cp -p -- "$conf" "$bak"
    fi
    mv -f -- "$tmp" "$conf"
    if ! nginx -t 2>/dev/null; then
        if (( had_old )) && [[ -n "$bak" ]]; then mv -f -- "$bak" "$conf"; else rm -f -- "$conf"; fi
        warn "nginx -t başarısız — ${conf} geri alındı, kural CANLIYA ALINMADI"
        return 1
    fi
    [[ -n "$bak" ]] && rm -f -- "$bak"
    systemctl reload nginx 2>/dev/null \
        || warn "nginx reload başarısız — ${conf} diskte, canlıda DEĞİL ('systemctl reload nginx' ile tekrar deneyin)"
    return 0
}

_update_nginx_whitelist() {
    _ip_render_nginx_list allow /etc/srvctl/ip-whitelist.conf \
        "${SRVCTL_NGINX_WHITELIST_CONF:-/etc/nginx/conf.d/srvctl-whitelist.conf}" "IP whitelist"
}

_update_nginx_blacklist() {
    _ip_render_nginx_list deny /etc/srvctl/ip-blacklist.conf \
        "${SRVCTL_NGINX_BLACKLIST_CONF:-/etc/nginx/conf.d/srvctl-blacklist.conf}" "IP blacklist"
}

# ─── DALGA 6 O13/madde-4 düzeltmesi ───
# ESKİ HALİ FİİLEN NO-OP'TU: 'geo $blocked_country { default 0; # TR ... }'
# — (a) 'geo' yönergesi CLIENT IP ARALIĞINA göre eşleme yapar, ülke koduna
# göre DEĞİL (yanlış yönerge); (b) gövde yalnız YORUM SATIRLARI ekliyordu,
# hiçbir zaman '$blocked_country'yi 1 yapan gerçek bir satır ÜRETMİYORDU.
# 'nginx -t' bunu her zaman GEÇERLİ (boş/yorum-only blok) sayıp "başarı"
# bildiriyordu — sessiz no-op. Doğru yönerge init.sh'ın kurduğu
# 'geoip_country' modülünün ürettiği '$geoip_country' değişkenini haritalayan
# 'map'tir. NOT (devredilen kapsam dışı iş): bu harita yalnız
# '$blocked_country' değişkenini ÜRETİR; onu gerçekten TÜKETİP isteği
# reddeden 'if ($blocked_country) { return 403; }' satırı vhost server
# bloklarına elle (ya da domain/template sahibinin vhost template'ine
# eklemesiyle) girmelidir — bu dosya (lib/ip.sh) vhost template'lerine
# DOKUNMUYOR (kapsam dışı, bkz. rapor).
_update_nginx_geoblock() {
    local conf="/etc/nginx/conf.d/srvctl-geoblock.conf"
    local geoblock_file="/etc/srvctl/geoblock.conf"

    if [[ ! -f "$geoblock_file" || ! -s "$geoblock_file" ]]; then
        rm -f -- "$conf"
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        return 0
    fi

    cat > "$conf" << 'GEOHEAD'
# srvctl GeoIP blocking — otomatik oluşturuldu
# GeoIP modülü gerektirir: apt install libnginx-mod-http-geoip geoip-database
# (bkz. srvctl init — 'geoip_country' yönergesini nginx.conf http bloğuna ekler)
# $blocked_country: 1 ise istek engellenecek ülkeden, 0 ise değil.
map $geoip_country $blocked_country {
    default 0;
GEOHEAD

    # Her ülke kodu için GERÇEK bir eşleme satırı üret (yorum DEĞİL).
    while IFS= read -r country; do
        [[ -z "$country" ]] && continue
        # 'add' aşamasında zaten validate_country ile doğrulandı; dosya elle
        # düzenlenmiş olabileceğinden burada ikinci bir savunma katmanı.
        validate_country "$country" || { warn "geoblock.conf içinde geçersiz ülke kodu atlandı: ${country}"; continue; }
        echo "    ${country} 1;" >> "$conf"
    done < "$geoblock_file"

    echo "}" >> "$conf"
    cat >> "$conf" << 'GEOFOOT'

# ETKİNLEŞTİRME GEREKİR (henüz OTOMATİK değil): bu harita TEK BAŞINA hiçbir
# isteği engellemez. İlgili domain'in vhost server bloğuna şu satırı ekleyin:
#   if ($blocked_country) { return 403; }
GEOFOOT

    if ! nginx -t 2>/dev/null; then
        warn "GeoIP haritası nginx -t testinden geçemedi — GeoIP modülü/veritabanı kurulu olmayabilir ('srvctl init' ile kurun)"
        return 1
    fi
    systemctl reload nginx 2>/dev/null || true
    return 0
}
