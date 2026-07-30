#!/bin/bash
# ═══════════════════════════════════════════════
#  deploy.sh — Git-based Zero-Downtime Deploy (v2)
#  Atomic symlink switch + dry-run + pre/post hook
#  + health check (otomatik rollback) + rollback
# ═══════════════════════════════════════════════

cmd_deploy() {
    require_root
    case "${1:-}" in
        rollback) _deploy_rollback "${@:2}" ;;
        health)   _deploy_health "${@:2}" ;;
        list)     _deploy_list "${@:2}" ;;
        ""|help|-h|--help)
            echo ""
            echo "  Kullanım: srvctl deploy <domain> [branch] [--dry-run]"
            echo ""
            echo "    <domain> [branch]      Deploy et (varsayılan branch: main)"
            echo "    --dry-run              Sadece dene, canlıya geçirme"
            echo "    rollback <domain>      Bir önceki sürüme dön"
            echo "    health <domain>        Sağlık kontrolü çalıştır"
            echo "    list <domain>          Mevcut release'leri listele"
            echo ""
            ;;
        *) _deploy_run "$@" ;;
    esac
}

# bin/srvctl 'rollback' komutunu doğrudan buraya yönlendirir
cmd_rollback() {
    require_root
    _deploy_rollback "$@"
}

# ───────────────────────────────────────────────────────────────
#  Yardımcı: hook çalıştır (varsa)
#  ${base}/shared/hooks/pre-deploy.sh  ve  post-deploy.sh
# ───────────────────────────────────────────────────────────────
_run_hook() {
    local hook_file="$1" release="$2" domain="$3"
    if [[ -f "$hook_file" ]]; then
        info "Hook çalıştırılıyor: $(basename "$hook_file")"
        RELEASE_DIR="$release" DOMAIN="$domain" bash "$hook_file" \
            || warn "Hook hata döndürdü: $(basename "$hook_file")"
    fi
}

# ───────────────────────────────────────────────────────────────
#  Yardımcı: sağlık kontrolü — localhost'a Host header ile istek
#  Çıktı: HTTP kodu (son satır)
# ───────────────────────────────────────────────────────────────
_health_probe() {
    local domain="$1"
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 10 -H "Host: ${domain}" "https://127.0.0.1/" 2>/dev/null)
    if [[ -z "$code" || "$code" == "000" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 10 -H "Host: ${domain}" "http://127.0.0.1/" 2>/dev/null)
    fi
    echo "${code:-000}"
}

# Repo URL güvenlik kapısı (PREDIKAT: 0=güvenli 1=güvensiz; exit YOK).
# .deploy-repo web-kullanıcısına ait dizinde olabildiğinden içeriği GÜVENİLMEZ.
# Yalnız https://, ssh://, git@host:path şemaları; ext::/fd::/file:: transport
# helper'ları (git RCE vektörü), baştaki '-' (option-injection), boşluk/'::' reddedilir.
_deploy_validate_repo_url() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    [[ "$url" == -* ]] && return 1
    [[ "$url" =~ [[:space:]] ]] && return 1
    [[ "$url" == *"::"* ]] && return 1
    [[ "$url" == file://* ]] && return 1
    [[ "$url" =~ ^https://[A-Za-z0-9._~:/@%?=\&-]+$ ]] && return 0
    [[ "$url" =~ ^ssh://[A-Za-z0-9._~:/@%-]+$ ]] && return 0
    [[ "$url" =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$ ]] && return 0
    return 1
}

# shared/ artefaktı root operasyonu (ln/chown -R) için güvenli mi?
# PREDİKAT: 0=güvenli, 1=güvensiz. Symlink (dangling dahil) reddedilir —
# yoksa web_user 'shared/writable'ı /etc'ye symlink yapıp 'chown -R' ile
# /etc'yi ele geçirebilir (yetki yükseltme). Var olmayan yol da güvensiz sayılır.
_deploy_assert_safe_shared() {
    local path="$1"
    [[ -L "$path" ]] && return 1
    [[ -e "$path" ]] || return 1
    return 0
}

# ───────────────────────────────────────────────────────────────
#  deploy <domain> [branch] [--dry-run]
# ───────────────────────────────────────────────────────────────
_deploy_run() {
    local domain="" branch="main" dry_run=0
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --*) warn "Bilinmeyen seçenek: ${arg}" ;;
            *) if [[ -z "$domain" ]]; then domain="$arg"; else branch="$arg"; fi ;;
        esac
    done

    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy <domain> [branch] [--dry-run]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname
    sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"
    local release_dir="${base}/releases/$(date +%Y%m%d_%H%M%S)"
    local shared_dir="${base}/shared"
    local public_dir="${base}/public_html"

    # Kimlikleri safe_name'den türet; PHP'yi doğrula (web-owned .credentials'a güvenme)
    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    local web_user="web_${sname}"

    local prev_target=""
    [[ -L "$public_dir" ]] && prev_target=$(readlink -f "$public_dir")

    header "Deploy: ${domain} (branch: ${branch})"
    [[ "$dry_run" == "1" ]] && warn "DRY-RUN modu: değişiklik canlıya YANSIMAYACAK."

    # Git repo URL
    local repo_url="" repo_file="${base}/.deploy-repo"
    [[ -f "$repo_file" ]] && repo_url=$(cat "$repo_file")
    if [[ -z "$repo_url" ]]; then
        read -rp "  Git repo URL'si: " repo_url
        [[ -z "$repo_url" ]] && error "Repo URL'si boş olamaz."
        echo "$repo_url" > "$repo_file"
        chmod 600 "$repo_file"; chown root:root "$repo_file"
        info "Repo kaydedildi: ${repo_file}"
    fi

    # Sahiplik kapısı: dosya varsa root-owned kontrolü (T1 bütünlük kapısı).
    # repo_file yoksa interaktif sorulur; varsa kapı: tamper'da aşağıdaki validate zaten reddeder.
    [[ -f "$repo_file" ]] && _require_owned_or_warn "$domain" "$repo_file" \
        || true

    # Güvenlik: web-yazılabilir .deploy-repo'dan gelen URL'yi ve branch'i clone'dan
    # önce doğrula (ext::/file:: git RCE + option-injection reddi).
    _deploy_validate_repo_url "$repo_url" \
        || error "Güvensiz repo URL'si reddedildi: ${repo_url} (yalnız https://, ssh://, git@host:path)"
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$branch" != -* ]] \
        || error "Geçersiz branch adı: ${branch}"

    # 1. Clone
    step "1/7" "Git clone (branch: ${branch})..."
    mkdir -p "${base}/releases"
    GIT_ALLOW_PROTOCOL='https:ssh:git' git clone --depth 1 --branch "${branch}" -- "${repo_url}" "${release_dir}" 2>/dev/null \
        || error "Git clone başarısız. Repo URL'si ve branch'i kontrol edin."
    success "Clone tamamlandı"

    # 2. Composer
    step "2/7" "Composer install..."
    if [[ -f "${release_dir}/composer.json" ]] && command -v composer &>/dev/null; then
        ( cd "${release_dir}" && composer install --no-dev --optimize-autoloader --no-interaction --quiet 2>/dev/null ) \
            && success "Composer paketleri yüklendi" \
            || warn "Composer install hatası"
    else
        info "composer.json yok veya composer kurulu değil — atlanıyor"
    fi

    # 3. Pre-deploy hook
    step "3/7" "Pre-deploy hook..."
    _run_hook "${shared_dir}/hooks/pre-deploy.sh" "${release_dir}" "${domain}"

    # 4. Shared dosyalar
    step "4/7" "Shared dosyalar bağlanıyor..."
    mkdir -p "${shared_dir}"
    if [[ -e "${shared_dir}/.env" ]] && _deploy_assert_safe_shared "${shared_dir}/.env"; then
        ln -sf "../../shared/.env" "${release_dir}/.env"
        success ".env bağlandı"
    elif [[ -L "${shared_dir}/.env" ]]; then
        warn "shared/.env bir symlink — güvenlik nedeniyle atlandı"
    else
        warn ".env bulunamadı: ${shared_dir}/.env"
    fi
    if [[ -d "${shared_dir}/writable" ]]; then
        _deploy_assert_safe_shared "${shared_dir}/writable" \
            || error "shared/writable bir symlink — deploy reddedildi (chown -R yetki-yükseltme riski)"
        rm -rf "${release_dir}/writable"
        ln -sf "../../shared/writable" "${release_dir}/writable"
    elif [[ -d "${release_dir}/writable" ]]; then
        cp -r "${release_dir}/writable" "${shared_dir}/writable"
        rm -rf "${release_dir}/writable"
        ln -sf "../../shared/writable" "${release_dir}/writable"
    fi

    # 5. İzinler
    step "5/7" "İzinler ayarlanıyor..."
    chown -R "${web_user}:${web_user}" "${release_dir}"
    chmod -R 750 "${release_dir}"
    if [[ -d "${shared_dir}/writable" ]]; then
        _deploy_assert_safe_shared "${shared_dir}/writable" \
            || error "shared/writable bir symlink — deploy reddedildi (chown -R yetki-yükseltme riski)"
        chmod -R 770 "${shared_dir}/writable"
        chown -R "${web_user}:${web_user}" "${shared_dir}/writable"
    fi
    success "İzinler ayarlandı"

    # DRY-RUN: burada dur
    if [[ "$dry_run" == "1" ]]; then
        echo ""
        warn "DRY-RUN: Release hazırlandı ama canlıya geçirilmedi:"
        echo "    ${release_dir}"
        rm -rf "${release_dir}"
        info "Gerçek deploy için --dry-run olmadan çalıştırın."
        return
    fi

    # 6. Atomic switch
    step "6/7" "Atomic switch (zero-downtime)..."
    if [[ -d "$public_dir" && ! -L "$public_dir" ]]; then
        mv "$public_dir" "${base}/public_html.bak.$(date +%s)" 2>/dev/null || true
    fi
    local rel_id; rel_id=$(basename "${release_dir}")
    if [[ -d "${release_dir}/public" ]]; then
        ln -sfn "releases/${rel_id}/public" "$public_dir"
    else
        ln -sfn "releases/${rel_id}" "$public_dir"
    fi
    systemctl reload "php${php_version}-fpm" 2>/dev/null || true
    success "Atomic switch tamamlandı"

    # 7. Health check + gerekirse otomatik rollback
    step "7/7" "Sağlık kontrolü..."
    local code; code=$(_health_probe "$domain")
    if [[ "$code" =~ ^(200|301|302)$ ]]; then
        success "Sağlık kontrolü OK (HTTP ${code})"
        _run_hook "${shared_dir}/hooks/post-deploy.sh" "${release_dir}" "${domain}"
    else
        warn "Sağlık kontrolü BAŞARISIZ (HTTP ${code}) — otomatik rollback!"
        if [[ -n "$prev_target" && -d "$prev_target" ]]; then
            rm -rf "$public_dir"
            ln -sfn "$prev_target" "$public_dir"
            systemctl reload "php${php_version}-fpm" 2>/dev/null || true
            rm -rf "${release_dir}"
            error "Deploy geri alındı. Önceki sürüm geri yüklendi: ${prev_target}"
        else
            error "Geri alınacak önceki sürüm yok. Manuel müdahale: ${release_dir}"
        fi
    fi

    # Eski release temizliği (son 5)
    if [[ -d "${base}/releases" ]]; then
        ( cd "${base}/releases" && ls -t 2>/dev/null | tail -n +6 | xargs -r rm -rf )
    fi

    header "✅ Deploy Tamamlandı: ${domain}"
    echo "  Release:        $(basename "${release_dir}")"
    echo "  Branch:         ${branch}"
    echo "  public_html →   $(readlink -f "$public_dir" 2>/dev/null)"
    echo "  HTTP:           ${code}"
    echo ""
    log_action "DEPLOY: ${domain} (branch=${branch}, http=${code}, release=$(basename "${release_dir}"))"
}

# ───────────────────────────────────────────────────────────────
#  deploy rollback <domain>  /  srvctl rollback <domain>
# ───────────────────────────────────────────────────────────────
_deploy_rollback() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && error "Kullanım: srvctl rollback <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local base="${WEB_ROOT}/${domain}"
    local public_dir="${base}/public_html"
    local releases="${base}/releases"
    [[ -d "$releases" ]] || error "Release dizini yok: ${releases}"

    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")

    local current_real=""; [[ -L "$public_dir" ]] && current_real=$(readlink -f "$public_dir")
    local current_rel="${current_real%/public}"

    # Mevcut release'den bir öncekini bul
    local prev="" found=0
    while read -r r; do
        [[ -z "$r" ]] && continue
        local full="${releases}/${r}"
        if [[ "$found" == "1" ]]; then prev="$full"; break; fi
        [[ "$full" == "$current_rel" ]] && found=1
    done < <(ls -t "$releases" 2>/dev/null)

    if [[ -z "$prev" ]]; then
        prev=$(ls -dt "${releases}"/*/ 2>/dev/null | sed -n '2p'); prev="${prev%/}"
    fi
    [[ -z "$prev" || ! -d "$prev" ]] && error "Geri alınacak önceki release bulunamadı."

    header "Rollback: ${domain} → $(basename "$prev")"
    rm -rf "$public_dir"
    local prev_name; prev_name=$(basename "$prev")
    if [[ -d "${prev}/public" ]]; then ln -sfn "releases/${prev_name}/public" "$public_dir"; else ln -sfn "releases/${prev_name}" "$public_dir"; fi
    systemctl reload "php${php_version}-fpm" 2>/dev/null || true

    local code; code=$(_health_probe "$domain")
    if [[ "$code" =~ ^(200|301|302)$ ]]; then
        success "Rollback başarılı: $(basename "$prev") (HTTP ${code})"
    else
        warn "Rollback yapıldı ama sağlık kontrolü zayıf (HTTP ${code})"
    fi
    log_action "ROLLBACK: ${domain} -> $(basename "$prev")"
}

# ───────────────────────────────────────────────────────────────
#  deploy health <domain>
# ───────────────────────────────────────────────────────────────
_deploy_health() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy health <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    local code; code=$(_health_probe "$domain")
    if [[ "$code" =~ ^(200|301|302)$ ]]; then
        success "${domain} sağlıklı (HTTP ${code})"
    else
        error "${domain} sağlıksız (HTTP ${code})"
    fi
}

# ───────────────────────────────────────────────────────────────
#  deploy list <domain>
# ───────────────────────────────────────────────────────────────
_deploy_list() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy list <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    local base="${WEB_ROOT}/${domain}"
    local current_real=""; [[ -L "${base}/public_html" ]] && current_real=$(readlink -f "${base}/public_html")
    header "Release'ler: ${domain}"
    local r full marker
    while read -r r; do
        [[ -z "$r" ]] && continue
        full="${base}/releases/${r}"; marker="  "
        [[ "$current_real" == "${full}/public" || "$current_real" == "$full" ]] && marker="${GREEN}→ ${NC}"
        echo -e "  ${marker}${r}"
    done < <(ls -t "${base}/releases" 2>/dev/null)
    echo ""
}
