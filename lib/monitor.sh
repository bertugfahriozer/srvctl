#!/bin/bash
# ═══════════════════════════════════════════════
#  monitor.sh — İzleme, Uptime, Anomaly Detection
# ═══════════════════════════════════════════════

cmd_monitor() {
    case "${1:-help}" in
        live)     _monitor_live ;;
        domains)  _monitor_domains ;;
        uptime)   _monitor_uptime "${@:2}" ;;
        check)    _monitor_check ;;
        traffic)  _monitor_traffic "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl monitor <live|domains|uptime|check|traffic>"
            echo ""
            echo "    live              Canlı sistem izleme (htop benzeri)"
            echo "    domains           Per-domain kaynak kullanımı"
            echo "    uptime [domain]   Uptime kontrolü"
            echo "    check             Tam durum kontrolü + alarmlar"
            echo "    traffic <domain>  GoAccess trafik analizi"
            echo ""
            ;;
    esac
}

# ═══════════════════════════════════════════════
#  CANLI İZLEME — Tek bakışta sunucu durumu
# ═══════════════════════════════════════════════
_monitor_live() {
    while true; do
        clear
        echo ""
        echo -e "  ${BOLD}📊 srvctl monitor — $(date '+%H:%M:%S')${NC}  (Ctrl+C ile çıkın)"
        divider

        # CPU
        local load
        load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}')
        local cpu_cores
        cpu_cores=$(grep -c processor /proc/cpuinfo 2>/dev/null)
        # Düşük (denetim 2026-09): boş/0 → awk sıfıra bölme hatası
        [[ "$cpu_cores" =~ ^[1-9][0-9]*$ ]] || cpu_cores=1
        local cpu_pct
        cpu_pct=$(awk "BEGIN {printf \"%.0f\", (${load} / ${cpu_cores}) * 100}")
        local cpu_bar
        cpu_bar=$(_progress_bar "$cpu_pct")
        echo -e "  CPU:  ${cpu_bar} ${cpu_pct}% (load: ${load}/${cpu_cores})"

        # RAM
        local ram_total ram_used ram_pct
        ram_total=$(free -m | awk '/Mem:/ {print $2}')
        ram_used=$(free -m | awk '/Mem:/ {print $3}')
        ram_pct=$((ram_used * 100 / ram_total))
        local ram_bar
        ram_bar=$(_progress_bar "$ram_pct")
        echo -e "  RAM:  ${ram_bar} ${ram_pct}% (${ram_used}M / ${ram_total}M)"

        # Disk
        local disk_pct
        disk_pct=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
        local disk_bar
        disk_bar=$(_progress_bar "$disk_pct")
        echo -e "  Disk: ${disk_bar} ${disk_pct}%"

        divider

        # Per-domain cgroups (varsa)
        echo -e "  ${CYAN}Domain Kaynakları${NC}"
        printf "  ${DIM}%-28s %-8s %-10s %-8s${NC}\n" "DOMAIN" "CPU%" "RAM" "PROCS"
        divider

        for dir in "${WEB_ROOT}"/*/; do
            [[ ! -d "$dir" ]] && continue
            local domain
            domain=$(basename "$dir")
            local sname
            sname=$(safe_name "$domain")
            local web_user="web_${sname}"

            # Per-user CPU ve RAM
            local user_cpu user_ram user_procs
            user_procs=$(pgrep -u "$web_user" 2>/dev/null | wc -l)
            if [[ $user_procs -gt 0 ]]; then
                user_cpu=$(ps -u "$web_user" -o %cpu= 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s}')
                user_ram=$(ps -u "$web_user" -o rss= 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
                printf "  %-28s %-8s %-10s %-8s\n" "$domain" "${user_cpu}%" "${user_ram}M" "$user_procs"
            else
                printf "  %-28s %-8s %-10s %-8s\n" "$domain" "0.0%" "0M" "0"
            fi
        done

        divider

        # Aktif bağlantılar
        local conn_count
        conn_count=$(ss -s 2>/dev/null | grep "estab" | head -1 | awk '{print $4}' | tr -d ',')
        echo "  Aktif bağlantı: ${conn_count:-0}"

        # Fail2Ban
        local banned_total=0
        if command -v fail2ban-client &>/dev/null; then
            banned_total=$(fail2ban-client status 2>/dev/null | grep -oP 'Currently banned:\s+\K\d+' | awk '{s+=$1} END {print s+0}')
        fi
        echo "  Fail2Ban banned: ${banned_total}"

        sleep 3
    done
}

# ═══════════════════════════════════════════════
#  PER-DOMAIN KAYNAK KULLANIMI
# ═══════════════════════════════════════════════
_monitor_domains() {
    header "Domain Kaynak Kullanımı"

    printf "  ${DIM}%-25s %-8s %-10s %-8s %-10s %-8s${NC}\n" \
        "DOMAIN" "CPU%" "RAM" "PROCS" "DISK" "CONN"
    divider

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        local sname
        sname=$(safe_name "$domain")
        local web_user="web_${sname}"

        # Process bazlı metrikler
        local user_procs user_cpu user_ram
        user_procs=$(pgrep -u "$web_user" 2>/dev/null | wc -l)
        if [[ $user_procs -gt 0 ]]; then
            user_cpu=$(ps -u "$web_user" -o %cpu= 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s}')
            user_ram=$(ps -u "$web_user" -o rss= 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
        else
            user_cpu="0.0"
            user_ram="0"
        fi

        # Disk
        local disk_size
        disk_size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')

        # Aktif bağlantılar (bu domain'e)
        local conn_count=0
        if [[ -f "${dir}logs/access.log" ]]; then
            conn_count=$(tail -100 "${dir}logs/access.log" 2>/dev/null | \
                awk -v t="$(date -d '1 minute ago' '+%d/%b/%Y:%H:%M' 2>/dev/null)" '$0 ~ t' | wc -l)
        fi

        printf "  %-25s %-8s %-10s %-8s %-10s %-8s\n" \
            "$domain" "${user_cpu}%" "${user_ram}M" "$user_procs" "$disk_size" "$conn_count"
    done

    divider

    # cgroups v2 bilgileri (varsa)
    if [[ -d /sys/fs/cgroup/srvctl.slice ]]; then
        echo ""
        echo -e "  ${CYAN}cgroups v2 Limitleri${NC}"
        for slice_dir in /sys/fs/cgroup/srvctl.slice/srvctl-*/; do
            [[ ! -d "$slice_dir" ]] && continue
            local slice_name
            slice_name=$(basename "$slice_dir" | sed 's/srvctl-//')
            local cg_cpu cg_mem_current cg_mem_max
            cg_cpu=$(cat "${slice_dir}/cpu.stat" 2>/dev/null | awk '/usage_usec/ {printf "%.1f", $2/1000000}')
            cg_mem_current=$(cat "${slice_dir}/memory.current" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
            cg_mem_max=$(cat "${slice_dir}/memory.max" 2>/dev/null)
            [[ "$cg_mem_max" == "max" ]] && cg_mem_max="unlimited" || cg_mem_max=$(echo "$cg_mem_max" | awk '{printf "%.0f", $1/1024/1024}')
            printf "  %-25s CPU: %ss  RAM: %sM / %s\n" "$slice_name" "${cg_cpu:-0}" "${cg_mem_current:-0}" "${cg_mem_max}"
        done
    fi

    echo ""
}

# ═══════════════════════════════════════════════
#  UPTIME CHECK — HTTP durum kontrolü
# ═══════════════════════════════════════════════
_monitor_uptime() {
    local target_domain="$1"

    header "Uptime Kontrolü"

    printf "  ${DIM}%-30s %-8s %-10s %-10s${NC}\n" "DOMAIN" "HTTP" "SÜRE" "SSL"
    divider

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        [[ -n "$target_domain" && "$domain" != "$target_domain" ]] && continue

        # HTTP kontrolü
        local http_code response_time
        local start_time end_time

        start_time=$(date +%s%N)
        http_code=$(curl -so /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 10 \
            "https://${domain}/" 2>/dev/null || echo "000")
        end_time=$(date +%s%N)
        response_time=$(( (end_time - start_time) / 1000000 ))

        local http_status
        if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
            http_status="${GREEN}${http_code}${NC}"
        elif [[ "$http_code" == "000" ]]; then
            http_status="${RED}DOWN${NC}"
            # Alarm gönder
            source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null
            send_notification "🔴 Domain Down!" "${domain} yanıt vermiyor!" "critical" 2>/dev/null || true
        else
            http_status="${YELLOW}${http_code}${NC}"
        fi

        # SSL kontrolü
        local ssl_status="${RED}✗${NC}"
        local ssl_days=""
        if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
            local expiry_epoch
            expiry_epoch=$(openssl x509 -enddate -noout \
                -in "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null | \
                cut -d= -f2 | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            if [[ $days_left -lt 7 ]]; then
                ssl_status="${RED}${days_left}d${NC}"
                source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null
                send_notification "⚠️ SSL Süresi Doluyor" "${domain} — ${days_left} gün kaldı!" "warning" 2>/dev/null || true
            elif [[ $days_left -lt 30 ]]; then
                ssl_status="${YELLOW}${days_left}d${NC}"
            else
                ssl_status="${GREEN}${days_left}d${NC}"
            fi
        fi

        printf "  %-30s %-8b %-10s %-10b\n" "$domain" "$http_status" "${response_time}ms" "$ssl_status"
    done

    divider
    echo ""
}

# ═══════════════════════════════════════════════
#  DURUM KONTROLÜ + ALARMLAR
# ═══════════════════════════════════════════════
_monitor_check() {
    require_root
    local alerts=0

    # Bildirim modülünü yükle
    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true

    # ─── Disk kontrolü ───
    local disk_pct
    disk_pct=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
    if [[ $disk_pct -ge 90 ]]; then
        send_notification "🔴 Disk Kritik!" "Disk kullanımı: ${disk_pct}%" "critical" 2>/dev/null || true
        alerts=$((alerts + 1))
    elif [[ $disk_pct -ge 80 ]]; then
        send_notification "⚠️ Disk Uyarısı" "Disk kullanımı: ${disk_pct}%" "warning" 2>/dev/null || true
        alerts=$((alerts + 1))
    fi

    # ─── RAM kontrolü ───
    local ram_pct
    ram_pct=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
    if [[ $ram_pct -ge 95 ]]; then
        send_notification "🔴 RAM Kritik!" "RAM kullanımı: ${ram_pct}%" "critical" 2>/dev/null || true
        alerts=$((alerts + 1))
    fi

    # ─── Servis kontrolü ───
    for svc in nginx "php${DEFAULT_PHP_VERSION}-fpm" mariadb redis-server; do
        if ! systemctl is-active "$svc" > /dev/null 2>&1; then
            send_notification "🔴 Servis Down!" "${svc} çalışmıyor!" "critical" 2>/dev/null || true
            alerts=$((alerts + 1))

            # Otomatik kurtarma denemesi
            systemctl restart "$svc" 2>/dev/null
            if systemctl is-active "$svc" > /dev/null 2>&1; then
                send_notification "✅ Servis Kurtarıldı" "${svc} otomatik yeniden başlatıldı" "success" 2>/dev/null || true
            fi
        fi
    done

    # ─── Domain uptime ───
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        local http_code
        http_code=$(curl -so /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 10 \
            "https://${domain}/" 2>/dev/null || echo "000")

        if [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
            send_notification "🔴 Domain Down!" "${domain} — HTTP ${http_code}" "critical" 2>/dev/null || true
            alerts=$((alerts + 1))
        fi
    done

    # ─── Fail2Ban anomali ───
    if command -v fail2ban-client &>/dev/null; then
        local total_banned=0
        while IFS= read -r jail; do
            jail=$(echo "$jail" | xargs)
            [[ -z "$jail" ]] && continue
            local banned
            banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
            total_banned=$((total_banned + ${banned:-0}))
        done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g')

        if [[ $total_banned -ge 20 ]]; then
            send_notification "⚠️ Yoğun Saldırı" "Fail2Ban: ${total_banned} IP banned" "warning" 2>/dev/null || true
            alerts=$((alerts + 1))
        fi
    fi

    if [[ $alerts -eq 0 ]]; then
        success "Tüm kontroller başarılı — sorun yok"
    else
        warn "${alerts} alarm tetiklendi"
    fi

    log_action "MONITOR CHECK: ${alerts} alerts"
}

# ═══════════════════════════════════════════════
#  TRAFİK ANALİZİ — GoAccess
# ═══════════════════════════════════════════════
_monitor_traffic() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl monitor traffic <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local log_file="${WEB_ROOT}/${domain}/logs/access.log"
    [[ ! -f "$log_file" ]] && error "Access log bulunamadı: ${log_file}"

    if command -v goaccess &>/dev/null; then
        goaccess "$log_file" \
            --log-format='%h - %^ [%d:%t %^] "%r" %s %b "%R" "%u" %T %^' \
            --date-format='%d/%b/%Y' \
            --time-format='%H:%M:%S' \
            --no-color
    else
        warn "GoAccess kurulu değil. Kurmak için: apt install goaccess"
        echo ""
        info "Basit trafik özeti:"
        divider

        echo "  Son 24 saat request sayısı:"
        local today
        today=$(date '+%d/%b/%Y')
        grep -c "$today" "$log_file" 2>/dev/null || echo "  0"

        echo ""
        echo "  En çok erişilen sayfalar:"
        awk '{print $7}' "$log_file" 2>/dev/null | sort | uniq -c | sort -rn | head -10

        echo ""
        echo "  En çok erişen IP'ler:"
        awk '{print $1}' "$log_file" 2>/dev/null | sort | uniq -c | sort -rn | head -10

        echo ""
        echo "  HTTP durum kodları:"
        awk '{print $9}' "$log_file" 2>/dev/null | sort | uniq -c | sort -rn | head -10
    fi
}

# ─── Progress Bar ───
_progress_bar() {
    local pct="$1"
    local width=20
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local color="$GREEN"
    [[ $pct -ge 70 ]] && color="$YELLOW"
    [[ $pct -ge 90 ]] && color="$RED"

    printf "${color}["
    printf '%0.s█' $(seq 1 "$filled") 2>/dev/null
    printf '%0.s░' $(seq 1 "$empty") 2>/dev/null
    printf "]${NC}"
}
