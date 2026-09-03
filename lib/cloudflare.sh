#!/bin/bash
# ═══════════════════════════════════════════════
#  cloudflare.sh — Cloudflare API Entegrasyonu
#  DNS, WAF, DDoS koruması
# ═══════════════════════════════════════════════

# Yapılandırma (srvctl.conf):
#   CF_API_TOKEN=xxxxx
#   CF_ZONE_ID=xxxxx (opsiyonel, domain bazında otomatik bulunur)

cmd_cloudflare() {
    require_root
    _cf_check_token
    case "${1:-help}" in
        setup)   _cf_setup ;;
        dns)     _cf_dns "${@:2}" ;;
        purge)   _cf_purge "${@:2}" ;;
        waf)     _cf_waf "${@:2}" ;;
        ddos)    _cf_ddos "${@:2}" ;;
        status)  _cf_status "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl cloudflare <setup|dns|purge|waf|ddos|status>"
            echo ""
            echo "    setup                    API token yapılandır"
            echo "    dns list <domain>        DNS kayıtlarını listele"
            echo "    dns add <domain> <type> <name> <content>"
            echo "    dns remove <domain> <record_id>"
            echo "    purge <domain>           Cache temizle"
            echo "    waf enable <domain>      WAF aktifleştir"
            echo "    waf disable <domain>     WAF devre dışı bırak"
            echo "    ddos on <domain>         Under Attack modu aç"
            echo "    ddos off <domain>        Under Attack modu kapat"
            echo "    status <domain>          Domain durumu"
            echo ""
            ;;
    esac
}

_cf_check_token() {
    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        if [[ "${1:-}" != "setup" ]]; then
            error "Cloudflare API token ayarlanmamış. Önce: srvctl cloudflare setup"
        fi
    fi
}

_cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    # O2 (denetim 2026-09): token '-H "Authorization: Bearer ..."' ile argv'de
    # görünüyordu ('ps auxww' / /proc/<pid>/cmdline). Artık '--config -' ile
    # stdin'den verilir; argv'de yalnız sırsız argümanlar kalır.
    local args=(--config - -sf -X "$method"
        -H "Content-Type: application/json"
        "https://api.cloudflare.com/client/v4${endpoint}")

    [[ -n "$data" ]] && args+=(-d "$data")

    printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" \
        | curl "${args[@]}" 2>/dev/null
}

_cf_get_zone_id() {
    local domain="$1"
    # Ana domain'i bul (subdomain varsa)
    local root_domain
    root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

    local result
    result=$(_cf_api GET "/zones?name=${root_domain}")
    echo "$result" | jq -r '.result[0].id // empty' 2>/dev/null
}

_cf_setup() {
    header "Cloudflare Yapılandırması"

    read -rp "  API Token: " token
    [[ -z "$token" ]] && error "Token boş olamaz."

    # Token'ı test et
    local verify
    verify=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl --config - -sf -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "Content-Type: application/json" 2>/dev/null)   # O2: token argv'de değil

    local status
    status=$(echo "$verify" | jq -r '.result.status // "error"' 2>/dev/null)

    if [[ "$status" == "active" ]]; then
        _update_conf "CF_API_TOKEN" "$token"
        success "Cloudflare API token doğrulandı ve kaydedildi"
    else
        error "Token doğrulanamadı. Token'ı kontrol edin."
    fi
}

# DNS kayıt gövdesini güvenli kur: string alanlar jq -n --arg ile kaçışlanır,
# proxied boolean --argjson ile ham JSON olarak yerleşir. String enterpolasyonu YOK.
_cf_dns_add_body() {
    local type="$1" name="$2" content="$3" proxied="$4"
    jq -n --arg type "$type" --arg name "$name" --arg content "$content" \
        --argjson proxied "$proxied" \
        '{type: $type, name: $name, content: $content, proxied: $proxied}'
}

_cf_dns() {
    case "${1:-}" in
        list)
            local domain="$2"
            [[ -z "$domain" ]] && error "Domain belirtilmedi."
            local zone_id
            zone_id=$(_cf_get_zone_id "$domain")
            [[ -z "$zone_id" ]] && error "Zone bulunamadı: ${domain}"

            header "DNS Kayıtları: ${domain}"
            printf "  ${DIM}%-8s %-25s %-8s %-30s %-6s${NC}\n" "ID" "NAME" "TYPE" "CONTENT" "PROXY"
            divider

            _cf_api GET "/zones/${zone_id}/dns_records?per_page=100" | \
                jq -r '.result[] | [.id[:8], .name, .type, .content, (.proxied|tostring)] | @tsv' 2>/dev/null | \
                while IFS=$'\t' read -r id name type content proxied; do
                    local proxy_icon="❌"
                    [[ "$proxied" == "true" ]] && proxy_icon="🟠"
                    printf "  %-8s %-25s %-8s %-30s %-6s\n" "$id" "$name" "$type" "$content" "$proxy_icon"
                done
            echo ""
            ;;
        add)
            local domain="$2" type="$3" name="$4" content="$5"
            [[ -z "$content" ]] && error "Kullanım: srvctl cloudflare dns add <domain> <A|CNAME|TXT> <name> <content>"

            local zone_id
            zone_id=$(_cf_get_zone_id "$domain")
            [[ -z "$zone_id" ]] && error "Zone bulunamadı: ${domain}"

            local proxied="true"
            [[ "$type" == "TXT" || "$type" == "MX" ]] && proxied="false"

            local result
            result=$(_cf_api POST "/zones/${zone_id}/dns_records" \
                "$(_cf_dns_add_body "$type" "$name" "$content" "$proxied")")

            local success_status
            success_status=$(echo "$result" | jq -r '.success' 2>/dev/null)
            if [[ "$success_status" == "true" ]]; then
                success "DNS kaydı eklendi: ${type} ${name} → ${content}"
            else
                local errors
                errors=$(echo "$result" | jq -r '.errors[].message' 2>/dev/null)
                error "DNS kaydı eklenemedi: ${errors}"
            fi
            ;;
        remove)
            local domain="$2" record_id="$3"
            [[ -z "$record_id" ]] && error "Kullanım: srvctl cloudflare dns remove <domain> <record_id>"

            local zone_id
            zone_id=$(_cf_get_zone_id "$domain")

            # Tam ID'yi bul (kısa ID verilmiş olabilir)
            local full_id
            full_id=$(_cf_api GET "/zones/${zone_id}/dns_records" | \
                jq -r ".result[] | select(.id | startswith(\"${record_id}\")) | .id" 2>/dev/null | head -1)

            [[ -z "$full_id" ]] && error "Kayıt bulunamadı: ${record_id}"

            _cf_api DELETE "/zones/${zone_id}/dns_records/${full_id}" > /dev/null
            success "DNS kaydı silindi: ${record_id}"
            ;;
        *)
            error "Kullanım: srvctl cloudflare dns <list|add|remove>"
            ;;
    esac
}

_cf_purge() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."

    local zone_id
    zone_id=$(_cf_get_zone_id "$domain")
    [[ -z "$zone_id" ]] && error "Zone bulunamadı."

    _cf_api POST "/zones/${zone_id}/purge_cache" '{"purge_everything":true}' > /dev/null
    success "Cloudflare cache temizlendi: ${domain}"
    log_action "CF PURGE: ${domain}"
}

_cf_waf() {
    local action="$1" domain="$2"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."

    local zone_id
    zone_id=$(_cf_get_zone_id "$domain")
    [[ -z "$zone_id" ]] && error "Zone bulunamadı."

    local value
    case "$action" in
        enable)  value="high" ;;
        disable) value="off" ;;
        *)       error "Kullanım: srvctl cloudflare waf <enable|disable> <domain>" ;;
    esac

    _cf_api PATCH "/zones/${zone_id}/settings/security_level" \
        "{\"value\":\"${value}\"}" > /dev/null
    success "WAF seviyesi: ${value} (${domain})"
    log_action "CF WAF ${action}: ${domain}"
}

_cf_ddos() {
    local action="$1" domain="$2"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."

    local zone_id
    zone_id=$(_cf_get_zone_id "$domain")
    [[ -z "$zone_id" ]] && error "Zone bulunamadı."

    local value
    case "$action" in
        on)  value="under_attack" ;;
        off) value="medium" ;;
        *)   error "Kullanım: srvctl cloudflare ddos <on|off> <domain>" ;;
    esac

    _cf_api PATCH "/zones/${zone_id}/settings/security_level" \
        "{\"value\":\"${value}\"}" > /dev/null

    if [[ "$action" == "on" ]]; then
        warn "Under Attack modu AKTİF: ${domain}"
        # shellcheck disable=SC1091
        source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
        # DALGA 6 / madde-5: send_notification artık PREDİKAT (0/1/2) —
        # başarısızlık ana işlemi düşürmemeli ('||') ama artık görünür (warn).
        if declare -F send_notification >/dev/null 2>&1; then
            send_notification "🛡️ DDoS Koruması" "${domain} için Under Attack modu açıldı" "warning" \
                || warn "Bildirim gönderilemedi (DDoS Under Attack: ${domain})"
        fi
    else
        success "Under Attack modu kapatıldı: ${domain}"
    fi
    log_action "CF DDOS ${action}: ${domain}"
}

_cf_status() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."

    local zone_id
    zone_id=$(_cf_get_zone_id "$domain")
    [[ -z "$zone_id" ]] && error "Zone bulunamadı."

    header "Cloudflare Durumu: ${domain}"

    local zone_info
    zone_info=$(_cf_api GET "/zones/${zone_id}")

    echo "  Zone ID:     ${zone_id}"
    echo "  Durum:       $(echo "$zone_info" | jq -r '.result.status' 2>/dev/null)"
    echo "  Plan:        $(echo "$zone_info" | jq -r '.result.plan.name' 2>/dev/null)"
    echo "  NS:          $(echo "$zone_info" | jq -r '.result.name_servers[]' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')"

    divider

    local settings
    settings=$(_cf_api GET "/zones/${zone_id}/settings")

    echo "  SSL Mode:    $(echo "$settings" | jq -r '.result[] | select(.id=="ssl") | .value' 2>/dev/null)"
    echo "  Security:    $(echo "$settings" | jq -r '.result[] | select(.id=="security_level") | .value' 2>/dev/null)"
    echo "  Minify:      $(echo "$settings" | jq -r '.result[] | select(.id=="minify") | .value | [.css, .html, .js] | join("/")' 2>/dev/null)"

    echo ""
}

# _update_conf → lib/core.sh (O5: tek kopya, doğrulamalı, tırnaklı yazım)
