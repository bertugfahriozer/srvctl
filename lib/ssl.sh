#!/bin/bash
# ═══════════════════════════════════════════════
#  ssl.sh — SSL Sertifika Yönetimi
# ═══════════════════════════════════════════════

cmd_ssl() {
    require_root
    case "${1:-help}" in
        renew)  _ssl_renew ;;
        status) _ssl_status ;;
        *)
            # Bilinmeyen alt komut kullanımı basar ama rc≠0 döner; yalnız açık yardım isteği rc 0.
            local _usage_rc=1
            case "${1:-help}" in help|-h|--help) _usage_rc=0 ;; esac
            [[ "$_usage_rc" -eq 0 ]] || warn "Bilinmeyen ssl alt komutu: ${1}"
            echo ""
            echo "  Kullanım: srvctl ssl <renew|status>"
            echo ""
            echo "    renew     Tüm sertifikaları yenile"
            echo "    status    Sertifika durumlarını göster"
            echo ""
            return "$_usage_rc"
            ;;
    esac
}

_ssl_renew() {
    header "SSL Sertifika Yenileme"

    info "Certbot ile tüm sertifikalar kontrol ediliyor..."
    certbot renew --quiet --deploy-hook 'systemctl reload nginx' 2>&1

    success "SSL yenileme tamamlandı"
    echo ""

    _ssl_status

    log_action "SSL RENEW completed"
}

_ssl_status() {
    echo ""
    echo -e "  ${BOLD}SSL Sertifika Durumu${NC}"
    divider
    printf "  ${DIM}%-30s %-12s %-30s${NC}\n" "DOMAIN" "DURUM" "BİTİŞ"
    divider

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
            local expiry
            expiry=$(openssl x509 -enddate -noout \
                -in "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null | cut -d= -f2)

            # Süresi dolmuş mu kontrol et
            local expiry_epoch
            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            local status_text
            if [[ $days_left -lt 0 ]]; then
                status_text="${RED}❌ Süresi dolmuş${NC}"
            elif [[ $days_left -lt 14 ]]; then
                status_text="${YELLOW}⚠️  ${days_left} gün${NC}"
            else
                status_text="${GREEN}✅ ${days_left} gün${NC}"
            fi

            printf "  %-30s %-12b %-30s\n" "$domain" "$status_text" "$expiry"
        else
            printf "  %-30s %-12b %-30s\n" "$domain" "${RED}❌ Yok${NC}" "-"
        fi
    done

    divider
    echo ""
}
