#!/bin/bash
# ═══════════════════════════════════════════════
#  selfupdate.sh — srvctl Self-Update
# ═══════════════════════════════════════════════

SRVCTL_REPO="https://github.com/bertugfahriozer/srvctl.git"
SRVCTL_UPDATE_DIR="/tmp/srvctl-update"

cmd_selfupdate() {
    require_root
    case "${1:-run}" in
        check)  _selfupdate_check ;;
        run)    _selfupdate_run ;;
        *)
            echo ""
            echo "  Kullanım: srvctl self-update [check|run]"
            echo ""
            echo "    check    Yeni sürüm var mı kontrol et"
            echo "    run      Güncellemeyi uygula (varsayılan)"
            echo ""
            ;;
    esac
}

_selfupdate_check() {
    header "srvctl Güncelleme Kontrolü"

    # Mevcut sürümü oku
    local current_version
    current_version=$(grep -oP 'Versiyon:\s*\K[0-9.]+' "${SRVCTL_ROOT}/bin/srvctl" 2>/dev/null || echo "bilinmiyor")
    info "Mevcut sürüm: ${current_version}"

    # Uzak repo'dan son commit'i kontrol et
    local remote_hash
    remote_hash=$(git ls-remote "$SRVCTL_REPO" HEAD 2>/dev/null | awk '{print $1}')
    if [[ -z "$remote_hash" ]]; then
        warn "Uzak repo'ya erişilemedi. İnternet bağlantınızı kontrol edin."
        return 1
    fi

    # Yerel hash varsa karşılaştır
    local local_hash_file="${SRVCTL_ROOT}/.current-commit"
    if [[ -f "$local_hash_file" ]]; then
        local local_hash
        local_hash=$(cat "$local_hash_file")
        if [[ "$local_hash" == "$remote_hash" ]]; then
            success "srvctl güncel. (${remote_hash:0:8})"
            return 0
        else
            info "Yeni sürüm mevcut!"
            info "  Yerel:  ${local_hash:0:8}"
            info "  Uzak:   ${remote_hash:0:8}"
            info "  Güncellemek için: sudo srvctl self-update"
            return 0
        fi
    else
        info "Yerel sürüm kaydı bulunamadı."
        info "  Uzak:   ${remote_hash:0:8}"
        info "  Güncellemek için: sudo srvctl self-update"
    fi
}

_selfupdate_run() {
    header "srvctl Güncelleme"

    # 1. Git kontrolü
    if ! command -v git &>/dev/null; then
        error "git kurulu değil. Kurun: apt install git"
    fi

    # 2. Mevcut sürümü göster
    local current_version
    current_version=$(grep -oP 'Versiyon:\s*\K[0-9.]+' "${SRVCTL_ROOT}/bin/srvctl" 2>/dev/null || echo "bilinmiyor")
    info "Mevcut sürüm: ${current_version}"

    # 3. Eski güncelleme dizinini temizle
    rm -rf "$SRVCTL_UPDATE_DIR"

    # 4. Repo'yu klonla
    info "GitHub'dan son sürüm çekiliyor..."
    if ! git clone --depth 1 "$SRVCTL_REPO" "$SRVCTL_UPDATE_DIR" 2>&1; then
        error "Repo klonlanamadı. İnternet bağlantınızı kontrol edin."
    fi

    # 5. Yedek al
    local backup_dir="${SRVCTL_ROOT}.backup.$(date +%Y%m%d_%H%M%S)"
    info "Mevcut kurulum yedekleniyor → ${backup_dir}"
    cp -a "$SRVCTL_ROOT" "$backup_dir"

    # 6. Dosyaları kopyala (conf/ ve logs/ HARİÇ — ayarlar korunur)
    info "Dosyalar güncelleniyor..."

    # bin/
    cp -f "${SRVCTL_UPDATE_DIR}/bin/srvctl" "${SRVCTL_ROOT}/bin/srvctl"
    chmod +x "${SRVCTL_ROOT}/bin/srvctl"

    # lib/
    cp -f "${SRVCTL_UPDATE_DIR}/lib/"*.sh "${SRVCTL_ROOT}/lib/"

    # templates/
    if [[ -d "${SRVCTL_UPDATE_DIR}/templates" ]]; then
        cp -rf "${SRVCTL_UPDATE_DIR}/templates/"* "${SRVCTL_ROOT}/templates/"
    fi

    # completions/
    if [[ -d "${SRVCTL_UPDATE_DIR}/completions" ]]; then
        cp -f "${SRVCTL_UPDATE_DIR}/completions/"* "${SRVCTL_ROOT}/completions/" 2>/dev/null || true
    fi

    # 7. Commit hash'ini kaydet
    local new_hash
    new_hash=$(git -C "$SRVCTL_UPDATE_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
    echo "$new_hash" > "${SRVCTL_ROOT}/.current-commit"

    # 8. Yeni sürümü oku
    local new_version
    new_version=$(grep -oP 'Versiyon:\s*\K[0-9.]+' "${SRVCTL_ROOT}/bin/srvctl" 2>/dev/null || echo "bilinmiyor")

    # 9. Temizle
    rm -rf "$SRVCTL_UPDATE_DIR"

    # 10. Changelog'a yaz
    if declare -f changelog_write &>/dev/null; then
        changelog_write "SELF-UPDATE" "srvctl güncellendi: ${current_version} → ${new_version} (${new_hash:0:8})"
    fi

    success "srvctl güncellendi!"
    info "  Eski: ${current_version}"
    info "  Yeni: ${new_version} (${new_hash:0:8})"
    info "  Yedek: ${backup_dir}"
    echo ""
    warn "NOT: conf/srvctl.conf ayarlarınıza dokunulmadı."
    warn "Yeni config seçenekleri varsa, changelog'u kontrol edin."
}
