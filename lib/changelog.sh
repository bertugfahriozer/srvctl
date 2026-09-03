#!/bin/bash
# ═══════════════════════════════════════════════
#  changelog.sh — Değişiklik Kaydı
#  Her srvctl işlemi zaman damgalı olarak loglanır
# ═══════════════════════════════════════════════

CHANGELOG_FILE="${SRVCTL_ROOT:-/usr/local/srvctl}/logs/changelog.log"

cmd_changelog() {
    case "${1:-help}" in
        show)  _changelog_show "${@:2}" ;;
        tail)  _changelog_tail "${@:2}" ;;
        search) _changelog_search "${@:2}" ;;
        export) _changelog_export "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl changelog <show|tail|search|export>"
            echo ""
            echo "    show [N]             Son N işlemi göster (varsayılan: 20)"
            echo "    tail                 Canlı takip (tail -f)"
            echo "    search <terim>       Arama yap"
            echo "    export [dosya]       Değişiklikleri dışa aktar"
            echo ""
            ;;
    esac
}

_changelog_show() {
    local count="${1:-20}"
    header "Son ${count} İşlem"

    if [[ ! -f "$CHANGELOG_FILE" ]]; then
        info "Henüz kayıt yok."
        return
    fi

    printf "  ${DIM}%-20s %-12s %-50s${NC}\n" "TARİH" "KULLANICI" "İŞLEM"
    divider

    tail -"$count" "$CHANGELOG_FILE" 2>/dev/null | while IFS='|' read -r timestamp user action; do
        printf "  %-20s %-12s %-50s\n" "$timestamp" "$user" "$action"
    done

    echo ""
}

_changelog_tail() {
    info "Canlı takip (Ctrl+C ile çıkın)..."
    tail -f "$CHANGELOG_FILE" 2>/dev/null || error "Changelog dosyası bulunamadı."
}

_changelog_search() {
    local term="$1"
    [[ -z "$term" ]] && error "Arama terimi belirtilmedi."

    header "Arama: ${term}"

    grep -i "$term" "$CHANGELOG_FILE" 2>/dev/null | tail -30 | \
    while IFS='|' read -r timestamp user action; do
        printf "  %-20s %-12s %-50s\n" "$timestamp" "$user" "$action"
    done

    echo ""
}

# O1 DÜZELTMESİ (haftalık denetim 2026-09): varsayılan çıktı yolu
# '/tmp/srvctl-changelog-YYYYMMDD.txt' idi — tarih dışında sabit ve tahmin
# edilebilir. Yerel bir kullanıcı o adı önceden symlink olarak koyarsa root'un
# 'cp'si hedefi izleyip ÜZERİNE YAZAR (keyfi root dosya yazımı); 0666 düz
# dosya koyarsa 'cp' modu korur ve denetim izi dünya-okunur olur.
# YENİ: varsayılan SRVCTL_ROOT/logs (root-only), symlink kapısı, umask 077,
# --no-dereference; mevcut hedef yalnız düz ve root sahipli dosyaysa yazılır.
_changelog_export() {
    local output="${1:-}"
    [[ -n "$output" ]] || output="${SRVCTL_ROOT:-/usr/local/srvctl}/logs/changelog-$(date +%Y%m%d-%H%M%S).txt"

    [[ -f "$CHANGELOG_FILE" ]] || error "Changelog dosyası bulunamadı."
    [[ -L "$output" ]] && error "GÜVENLİK: ${output} bir sembolik bağ — dışa aktarma İPTAL."
    [[ -e "$output" && ! -f "$output" ]] && error "GÜVENLİK: ${output} düz dosya değil — dışa aktarma İPTAL."
    if [[ -e "$output" ]]; then
        local own; own="$(_stat_owner "$output" 2>/dev/null)" || own=""
        [[ "$own" == "root" ]] || error "GÜVENLİK: ${output} root'a ait değil (${own:-?}) — üzerine yazılmadı."
    fi
    ( umask 077; cp --no-dereference -- "$CHANGELOG_FILE" "$output" ) \
        || error "Dışa aktarma başarısız: ${output}"
    chmod 600 -- "$output" 2>/dev/null || true
    success "Changelog dışa aktarıldı: ${output}"
}

# ─── core.sh'den çağrılan log fonksiyonu ───
# log_to_changelog "İşlem açıklaması"
log_to_changelog() {
    local action="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-root}"

    mkdir -p "$(dirname "$CHANGELOG_FILE")"
    echo "${timestamp}|${user}|${action}" >> "$CHANGELOG_FILE"
}
