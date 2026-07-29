#!/bin/bash
# ═══════════════════════════════════════════════
#  domain.sh — Domain CRUD Operasyonları
#  Her domain için 12 güvenlik katmanı otomatik
# ═══════════════════════════════════════════════

cmd_domain() {
    require_root
    case "${1:-help}" in
        add)       _domain_add "${@:2}" ;;
        remove)    _domain_remove "${@:2}" ;;
        list)      _domain_list ;;
        info)      _domain_info "${@:2}" ;;
        clone)     _domain_clone "${@:2}" ;;
        suspend)   _domain_suspend "${@:2}" ;;
        unsuspend) _domain_unsuspend "${@:2}" ;;
        php-switch) _domain_php_switch "${@:2}" ;;
        resources) _domain_resources "${@:2}" ;;
        staging)   _domain_staging "${@:2}" ;;
        migrate)    _domain_migrate "${@:2}" ;;
        rate-limit) _domain_rate_limit "${@:2}" ;;
        repair)    _domain_repair "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl domain <komut>"
            echo ""
            echo "  Temel:"
            echo "    add <domain> [--php=8.3]        Yeni domain ekle"
            echo "    remove <domain>                 Domain kaldır"
            echo "    list                            Tüm domain'leri listele"
            echo "    info <domain>                   Domain bilgisi"
            echo ""
            echo "  Operasyonel:"
            echo "    clone <kaynak> <hedef>          Domain klonla (DB + dosya)"
            echo "    suspend <domain>                Bakım moduna al"
            echo "    unsuspend <domain>              Bakım modundan çıkar"
            echo "    php-switch <domain> <versiyon>  PHP versiyonu değiştir"
            echo "    resources <domain> [seçenekler] Kaynak limitleri (cgroups v2)"
            echo "    staging <domain>                Staging ortamı oluştur"
            echo "    migrate <domain> <user@host>    Sunucular arası taşı"
            echo "    rate-limit <domain> <profil>    Rate-limit profilini değiştir/göster"
            echo "    repair <domain>|--all           Eksik chroot kütüphanelerini onarır"
            echo ""
            ;;
    esac
}

_apply_chroot_php_deps() {
    local base="$1" php_ver="$2"
    
    # 1. PHP-FPM ana kütüphaneleri
    local fpm_bin="/usr/sbin/php-fpm${php_ver}"
    if [[ -x "$fpm_bin" ]]; then
        local lib dir loader
        while IFS= read -r lib; do
            [[ -z "$lib" ]] && continue
            dir=$(dirname "$lib")
            mkdir -p "${base}${dir}"
            cp -u "$lib" "${base}${lib}" 2>/dev/null || true
        done < <(ldd "$fpm_bin" 2>/dev/null | awk '{print $3}' | grep -v '^$')

        loader=$(ldd "$fpm_bin" 2>/dev/null | grep 'ld-linux' | awk '{print $1}')
        if [[ -n "$loader" && -f "$loader" ]]; then
            mkdir -p "${base}$(dirname "$loader")"
            cp -u "$loader" "${base}${loader}" 2>/dev/null || true
        fi
    fi

    # 2. PHP Eklentileri (Extensions) ve bağımlılıkları
    local ext_dir
    ext_dir=$(php"${php_ver}" -i 2>/dev/null | grep "^extension_dir" | awk '{print $3}')
    if [[ -n "$ext_dir" && -d "$ext_dir" ]]; then
        mkdir -p "${base}${ext_dir}"
        for ext in "${ext_dir}"/*.so; do
            [[ -f "$ext" ]] || continue
            cp -u "$ext" "${base}${ext}" 2>/dev/null || true
            while IFS= read -r lib; do
                [[ -z "$lib" ]] && continue
                local libdir
                libdir=$(dirname "$lib")
                mkdir -p "${base}${libdir}"
                cp -u "$lib" "${base}${lib}" 2>/dev/null || true
            done < <(ldd "$ext" 2>/dev/null | awk '{print $3}' | grep "^/")
        done
    fi

    # 3. NSS ve Resolv (DNS/Kullanıcı çözümleme)
    mkdir -p "${base}/lib/x86_64-linux-gnu"
    cp -u /lib/x86_64-linux-gnu/libnss_* "${base}/lib/x86_64-linux-gnu/" 2>/dev/null || true
    cp -u /lib/x86_64-linux-gnu/libresolv* "${base}/lib/x86_64-linux-gnu/" 2>/dev/null || true
}

_domain_repair() {
    local target="$1"
    [[ -z "$target" ]] && error "Kullanım: srvctl domain repair <domain> | --all"

    if [[ "$target" == "--all" ]]; then
        header "Tüm Domainler Onarılıyor..."
        for dir in "${WEB_ROOT}"/*/; do
            [[ ! -d "$dir" ]] && continue
            local domain
            domain=$(basename "$dir")
            read_credentials "$domain"
            local php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
            info "${domain} onarılıyor (PHP ${php_ver})..."
            _apply_chroot_php_deps "${dir%/}" "${php_ver}"
            systemctl restart "php${php_ver}-fpm" 2>/dev/null || true
        done
        success "Tüm domainler onarıldı."
        return
    fi

    domain_exists "$target" || error "Domain bulunamadı: ${target}"
    read_credentials "$target"
    local base="${WEB_ROOT}/${target}"
    local php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    
    header "Domain Onarılıyor: ${target}"
    step "1/2" "Chroot kütüphaneleri güncelleniyor (PHP ${php_ver})..."
    _apply_chroot_php_deps "${base}" "${php_ver}"
    
    step "2/2" "PHP-FPM yeniden başlatılıyor..."
    systemctl restart "php${php_ver}-fpm" 2>/dev/null || true
    
    success "Domain onarıldı: ${target}"
}


# Bir domain için HEDEF dosya-sahiplik/izin modelini (uygulamadan) yazar.
# Çıktı: "<path>|<owner>|<mode>" satırları. Saf fonksiyon — chown/chmod YOK.
# harden-fs dry-run (Task 4) ve unit-testler bunu kullanır.
_domain_fs_plan() {
    local base="$1" web_user="$2"
    local rows=(
        ".|root|751"
        "dev|root|755" "etc|root|755" "lib|root|755" "lib64|root|755" "usr|root|755"
        ".credentials|root|600" ".srvctl-meta|root|644" ".deploy-repo|root|600"
        "public_html|${web_user}|750"
        "private|${web_user}|750"
        "private/writable|${web_user}|770"
        "logs|${web_user}|750"
        "tmp|${web_user}|770"
        "sessions|${web_user}|770"
        "releases|${web_user}|750"
        "shared|${web_user}|750"
    )
    local row rel owner mode path
    for row in "${rows[@]}"; do
        IFS='|' read -r rel owner mode <<< "$row"
        [[ "$rel" == "." ]] && path="$base" || path="${base}/${rel}"
        printf '%s|%s|%s\n' "$path" "$owner" "$mode"
    done
}

# Mevcut sahiplik/izinleri kaydet (revert güvenlik ağı). Satır: "<path> <owner> <mode>".
_fs_record_before() {
    local base="$1" out="$2" p
    : > "$out"
    printf '%s %s %s\n' "$base" "$(_stat_owner "$base")" "$(_stat_mode "$base")" >> "$out"
    for p in "$base"/* "$base"/.credentials "$base"/.srvctl-meta "$base"/.deploy-repo; do
        [[ -e "$p" ]] || continue
        printf '%s %s %s\n' "$p" "$(_stat_owner "$p")" "$(_stat_mode "$p")" >> "$out"
    done
}

# Kayıttan geri yükle (chown/chmod — gerçek etki [HOST]).
_fs_revert() {
    local rec="$1" path owner mode
    while read -r path owner mode; do
        [[ -e "$path" ]] || continue
        chown "${owner}:${owner}" "$path" 2>/dev/null || true
        chmod "$mode" "$path" 2>/dev/null || true
    done < "$rec"
}

# HEDEF sahiplik modelini UYGULAR (root gerekir). Strateji: önce tüm ağaç web_user,
# sonra base'in KENDİSİ + chroot sistem dizinleri + kontrol dosyaları root'a geri alınır.
# Böylece web app yazma erişimini korur ama base'de write/unlink yapamaz (RC1 kapalı).
_domain_apply_fs_ownership() {
    local base="$1" web_user="$2"
    # 1. Tüm ağaç web_user
    chown -R "${web_user}:${web_user}" "$base"
    # 2. base dizininin KENDİSİ root (yalnız bu inode — çocuklar web kalır)
    chown root:root "$base"; chmod 751 "$base"
    # 3. chroot sistem dizinleri root (recursive)
    local sysd
    for sysd in dev etc lib lib64 usr; do
        [[ -d "${base}/${sysd}" ]] && { chown -R root:root "${base}/${sysd}"; chmod 755 "${base}/${sysd}"; }
    done
    # 4. kontrol dosyaları root
    local cf
    for cf in .credentials .srvctl-meta .deploy-repo; do
        [[ -e "${base}/${cf}" ]] && chown root:root "${base}/${cf}"
    done
    [[ -e "${base}/.credentials" ]] && chmod 600 "${base}/.credentials"
    [[ -e "${base}/.srvctl-meta" ]] && chmod 644 "${base}/.srvctl-meta"
    [[ -e "${base}/.deploy-repo" ]] && chmod 600 "${base}/.deploy-repo"
    # 5. leaf izinleri (sahiplik zaten web_user)
    chmod 750 "${base}/public_html" "${base}/private" "${base}/logs" 2>/dev/null || true
    chmod 770 "${base}/tmp" "${base}/sessions" 2>/dev/null || true
    chmod -R 770 "${base}/private/writable" 2>/dev/null || true
}

# vhost config'i seçili profil + meta ile üret ve yaz.
# mode: "http" → vhost.conf.tpl, "ssl" → vhost-ssl.conf.tpl
# SITES_AVAILABLE env'i test için override edilebilir (varsayılan /etc/nginx/sites-available).
_domain_write_vhost() {
    local domain="$1" php_version="$2" profile="$3" mode="$4"
    local sites="${SITES_AVAILABLE:-/etc/nginx/sites-available}"
    local sname
    sname=$(safe_name "$domain")
    # php_version sink-doğrulama (T2 residual): .credentials'tan gelen tainted
    # PHP_VERSION nginx vhost'una enjekte olmasın; geçersizse DEFAULT'a düş.
    if ! assert_php_version "$php_version"; then
        warn "Geçersiz PHP sürümü '${php_version}' — '${DEFAULT_PHP_VERSION}' kullanılıyor"
        php_version="${DEFAULT_PHP_VERSION}"
    fi
    local tpl="${SRVCTL_TEMPLATES}/nginx/vhost.conf.tpl"
    [[ "$mode" == "ssl" ]] && tpl="${SRVCTL_TEMPLATES}/nginx/vhost-ssl.conf.tpl"

    rate_profile_load "$profile"

    # Hassas yollar: meta override yoksa varsayılan.
    # Meta web kullanıcısı tarafından yazılabildiğinden değer GÜVENİLMEZ:
    # nginx token charset'ine uymuyorsa (boşluk, {, }, ; ...) varsayılana düş.
    local sensitive="${DEFAULT_SENSITIVE_PATHS}"
    read_meta "$domain"
    if [[ -n "${SENSITIVE_PATHS:-}" ]]; then
        if assert_regex_safe "${SENSITIVE_PATHS}"; then
            sensitive="${SENSITIVE_PATHS}"
        else
            warn "Geçersiz SENSITIVE_PATHS (${domain}) — varsayılan hassas yollar kullanılıyor"
        fi
    fi

    render_template "$tpl" \
        "DOMAIN=${domain}" \
        "SAFE_NAME=${sname}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        "RL_REQ_ZONE=${RL_REQ_ZONE}" \
        "RL_REQ_BURST=${RL_REQ_BURST}" \
        "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" \
        "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
        "RL_CONN=${RL_CONN}" \
        "RL_SENSITIVE_PATHS=${sensitive}" \
        > "${sites}/${domain}.conf"
}

# Per-domain FPM config (global+pool) + systemd unit dosyalarını RENDER eder.
# systemctl ÇAĞIRMAZ (aktivasyon _domain_activate_fpm_unit, [HOST]).
# Test için SRVCTL_FPM_DIR / SRVCTL_SYSTEMD_DIR override edilebilir.
_domain_render_fpm_unit() {
    local domain="$1" php_version="$2"
    local sname; sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local fpm_dir="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    mkdir -p "$fpm_dir" "$sysd_dir"
    # config = [global] + pool (pool.conf.tpl TEK kaynak, kopyalanmaz)
    {
        render_template "${SRVCTL_TEMPLATES}/php-fpm/fpm-global.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}"
        render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}" \
            "PHP_VERSION=${php_version}" "WEB_USER=${web_user}"
    } > "${fpm_dir}/${sname}.conf"
    render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-fpm.service.tpl" \
        "DOMAIN=${domain}" "SAFE_NAME=${sname}" "PHP_VERSION=${php_version}" \
        > "${sysd_dir}/srvctl-fpm-${sname}.service"
}

# Sihirbaz: girdileri toplar, WIZ_* global değişkenlerine yazar. İptalde 1 döner.
_domain_wizard_collect() {
    WIZ_DOMAIN=""; WIZ_PHP=""; WIZ_PROFILE=""; WIZ_SSL="evet"; WIZ_SENSITIVE=""
    local domain php_version profile ssl_ans sensitive

    # 1. Domain
    while :; do
        read -rp "  Domain adı (örn. example.com): " domain
        [[ -z "$domain" ]] && { warn "Domain boş olamaz."; continue; }
        if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            warn "Geçersiz domain formatı."; continue
        fi
        domain_exists "$domain" && { warn "Domain zaten mevcut: ${domain}"; continue; }
        break
    done

    # 2. PHP sürümü
    read -rp "  PHP sürümü [${DEFAULT_PHP_VERSION}]: " php_version
    php_version="${php_version:-${DEFAULT_PHP_VERSION}}"

    # 3. Rate-limit profili
    echo "  Profiller: $(rate_profile_names | tr '\n' ' ')"
    read -rp "  Rate-limit profili [standard]: " profile
    profile="${profile:-standard}"

    # 4. SSL
    read -rp "  SSL şimdi alınsın mı? (evet/hayır) [evet]: " ssl_ans
    ssl_ans="${ssl_ans:-evet}"

    # 5. Hassas yollar
    echo "  Varsayılan hassas yollar: ${DEFAULT_SENSITIVE_PATHS}"
    read -rp "  Değiştir (boş = varsayılan): " sensitive
    sensitive="${sensitive:-${DEFAULT_SENSITIVE_PATHS}}"

    # Özet
    divider
    echo "  Domain:    ${domain}"
    echo "  PHP:       ${php_version}"
    echo "  Profil:    ${profile}"
    echo "  SSL:       ${ssl_ans}"
    echo "  Hassas:    ${sensitive}"
    divider

    WIZ_DOMAIN="$domain"; WIZ_PHP="$php_version"; WIZ_PROFILE="$profile"
    WIZ_SSL="$ssl_ans"; WIZ_SENSITIVE="$sensitive"

    confirm "Bu ayarlarla devam edilsin mi?" || return 1
    return 0
}

# Sihirbaz: girdi toplar ve _domain_add'i kurulu argümanlarla çağırır.
_domain_add_wizard() {
    header "Yeni Domain — İnteraktif Kurulum"
    _domain_wizard_collect || { info "İptal edildi."; return 1; }

    local args=("$WIZ_DOMAIN" "--php=${WIZ_PHP}" "--rate=${WIZ_PROFILE}" "--sensitive=${WIZ_SENSITIVE}")
    [[ "$WIZ_SSL" != "evet" ]] && args+=("--no-ssl")
    _domain_add "${args[@]}"
}

# CLI yolu için domain doğrulama kapısı (test edilebilir ince sarmalayıcı).
# validate_domain predikatını birebir uygular; geçersizse 1 döner.
_domain_add_validate_gate() {
    validate_domain "$1"
}

# Per-domain .credentials dosyasını güvenli yaz (umask 077 + 0600 root:root).
# Saf yardımcı: mysql/redis/nginx gerektirmez — macOS'ta unit-test edilebilir.
# Argümanlar: domain base web_user php_ver db_name db_user db_pass redis_user redis_pass redis_prefix
_domain_write_credentials() {
    local domain="$1" base="$2" web_user="$3" php_version="$4"
    local db_name="$5" db_user="$6" db_pass="$7"
    local redis_user="$8" redis_pass="$9" redis_prefix="${10}"
    local creds_file="${base}/.credentials"

    # Foundation primitive: dosyayı 0600 root:root ile önceden oluştur
    secure_file "$creds_file" 600
    # İçeriği umask 077 bağlamında yaz (dosya zaten 0600, içerik güvenli)
    (
        umask 077
        cat > "$creds_file" << CREDS
# ═══════════════════════════════════════════════
#  srvctl credentials — ${domain}
#  Oluşturulma: $(date '+%Y-%m-%d %H:%M:%S')
#  DİKKAT: Bu dosyayı güvenli bir yere yedekleyin!
# ═══════════════════════════════════════════════
DOMAIN=${domain}
SAFE_NAME=$(safe_name "$domain")
WEB_USER=${web_user}
PHP_VERSION=${php_version}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
REDIS_USER=${redis_user}
REDIS_PASS=${redis_pass}
REDIS_PREFIX=${redis_prefix}
CREDS
    )
}

# ═══════════════════════════════════════════════
#  DOMAIN ADD — 10 adımda tam güvenlikli domain
# ═══════════════════════════════════════════════
_domain_add() {
    # Argümansız (pozisyonel domain yok) çağrı → interaktif sihirbaz
    local _has_domain=false _a
    for _a in "$@"; do [[ "$_a" != -* ]] && _has_domain=true; done
    if [[ "$_has_domain" == false ]]; then
        _domain_add_wizard
        return
    fi

    local domain=""
    local php_version="${DEFAULT_PHP_VERSION}"
    local rate_profile="standard"
    local do_ssl=true
    local sensitive_paths="${DEFAULT_SENSITIVE_PATHS}"

    # Argümanları parse et
    for arg in "$@"; do
        case "$arg" in
            --php=*)       php_version="${arg#--php=}" ;;
            --rate=*)      rate_profile="${arg#--rate=}" ;;
            --sensitive=*) sensitive_paths="${arg#--sensitive=}" ;;
            --no-ssl)      do_ssl=false ;;
            -*) warn "Bilinmeyen seçenek: ${arg}" ;;
            *) domain="$arg" ;;
        esac
    done

    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain add example.com [--php=8.3] [--rate=standard]"
    _domain_add_validate_gate "$domain" || error "Geçersiz domain adı: ${domain}"
    domain_exists "$domain" && error "Domain zaten mevcut: ${domain}"
    php_version_exists "$php_version" || error "PHP ${php_version} kurulu değil. Önce kurun."
    rate_profile="$(rate_profile_resolve "$rate_profile")"

    # Değişkenler
    local sname
    sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local base="${WEB_ROOT}/${domain}"
    local db_name="db_${sname}"
    local db_user="usr_${sname}"
    local db_pass
    db_pass=$(generate_password 24)
    local redis_user="redis_${sname}"
    local redis_pass
    redis_pass=$(generate_password 24)

    header "Yeni Domain: ${domain}"

    local total=10
    local current=0

    # ─── 1. Linux Kullanıcısı ───
    current=$((current + 1))
    step "${current}/${total}" "Linux kullanıcısı: ${web_user}"

    groupadd "${web_user}" 2>/dev/null || true
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        -g "${web_user}" "${web_user}" 2>/dev/null || true
    usermod -aG "${web_user}" www-data 2>/dev/null || true

    # Deployer'a erişim ver
    if id "${DEPLOYER_USER}" &>/dev/null; then
        usermod -aG "${web_user}" "${DEPLOYER_USER}" 2>/dev/null || true
    fi

    success "Kullanıcı oluşturuldu"

    # ─── 2. Dizin Yapısı ───
    current=$((current + 1))
    step "${current}/${total}" "Dizin yapısı oluşturuluyor..."

    mkdir -p "${base}"/{public_html,private,logs,tmp,sessions,releases,shared}
    mkdir -p "${base}/private"/{app,modules,system,vendor}
    mkdir -p "${base}/private/writable"/{cache,logs,session,uploads}

    # Chroot için gerekli dizinler
    mkdir -p "${base}"/{dev,etc,lib,lib64}
    mkdir -p "${base}/usr"/{lib,share/zoneinfo}
    mkdir -p "${base}/etc/ssl/certs"

    # İzinler — Yeni sahiplik modeli (T1, RC1): base root:root 751, leaf'ler web_user.
    # NOT: eski 'chmod o-rwx' + 'setfacl o::---' KALDIRILDI — base artık root:root ve
    # web_user "other" olarak o+x (traverse) iznine ihtiyaç duyar; www-data da öyle.
    _domain_apply_fs_ownership "${base}" "${web_user}"
    # Yeni domain doğuştan hardened: marker yaz (fail-closed kapı hemen aktif).
    secure_dir "${SRVCTL_STATE_DIR}/${domain}" 700
    printf 'hardened %s srvctl-%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SRVCTL_VERSION}" \
        > "${SRVCTL_STATE_DIR}/${domain}/hardened"
    chmod 600 "${SRVCTL_STATE_DIR}/${domain}/hardened"

    # ACL — www-data (nginx) public_html'i okuyabilsin (o::--- YOK; base o+x korunur)
    setfacl -R -m "u:www-data:rx" "${base}/public_html" 2>/dev/null || true
    setfacl -R -d -m "u:www-data:rx" "${base}/public_html" 2>/dev/null || true

    success "Dizin yapısı hazır"

    # ─── 3. Chroot Ortamı ───
    current=$((current + 1))
    step "${current}/${total}" "Chroot ortamı hazırlanıyor..."

    # /dev aygıtları
    [[ ! -c "${base}/dev/null" ]] && mknod -m 0666 "${base}/dev/null" c 1 3 2>/dev/null || true
    [[ ! -c "${base}/dev/urandom" ]] && mknod -m 0444 "${base}/dev/urandom" c 1 9 2>/dev/null || true
    [[ ! -c "${base}/dev/zero" ]] && mknod -m 0666 "${base}/dev/zero" c 1 5 2>/dev/null || true

    # Temel sistem dosyaları
    cp /etc/resolv.conf "${base}/etc/" 2>/dev/null || true
    cp /etc/hosts "${base}/etc/" 2>/dev/null || true
    cp /etc/nsswitch.conf "${base}/etc/" 2>/dev/null || true
    cp /etc/localtime "${base}/etc/" 2>/dev/null || true
    cp /etc/ssl/certs/ca-certificates.crt "${base}/etc/ssl/certs/" 2>/dev/null || true
    cp -r /usr/share/zoneinfo "${base}/usr/share/" 2>/dev/null || true

    # PHP-FPM, Eklentiler (Extensions) ve Shared Libraries
    _apply_chroot_php_deps "${base}" "${php_version}"

    success "Chroot ortamı hazır"

    # ─── 4. PHP-FPM Pool (chroot) ───
    current=$((current + 1))
    step "${current}/${total}" "PHP-FPM pool (chroot jail)..."

    render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/php/${php_version}/fpm/pool.d/${sname}.conf"

    systemctl reload "php${php_version}-fpm" 2>/dev/null || \
        systemctl restart "php${php_version}-fpm"
    success "PHP-FPM pool aktif (chroot: ${base})"

    # ─── 5. Nginx Vhost ───
    current=$((current + 1))
    step "${current}/${total}" "Nginx vhost oluşturuluyor... (profil: ${rate_profile})"

    write_meta "$domain" "RATE_PROFILE" "$rate_profile"
    write_meta "$domain" "SENSITIVE_PATHS" "$sensitive_paths"

    _domain_write_vhost "$domain" "$php_version" "$rate_profile" http

    ln -sf "/etc/nginx/sites-available/${domain}.conf" \
        "/etc/nginx/sites-enabled/${domain}.conf"

    nginx_test
    systemctl reload nginx
    success "Nginx vhost aktif"

    # ─── 6. SSL (Let's Encrypt) ───
    current=$((current + 1))
    if [[ "$do_ssl" == true ]]; then
        step "${current}/${total}" "SSL sertifikası alınıyor..."
        if certbot --nginx -d "${domain}" \
            --non-interactive --agree-tos --redirect \
            -m "admin@${domain}" 2>/dev/null; then

            _domain_write_vhost "$domain" "$php_version" "$rate_profile" ssl
            nginx_test && systemctl reload nginx
            success "SSL aktif (Let's Encrypt + HSTS)"
        else
            warn "SSL alınamadı — DNS ayarlarını kontrol edin"
            warn "Sonra çalıştırın: certbot --nginx -d ${domain}"
        fi
    else
        step "${current}/${total}" "SSL atlandı (--no-ssl)"
        info "Sonra almak için: certbot --nginx -d ${domain}"
    fi

    # ─── 7. AppArmor Profili ───
    current=$((current + 1))
    step "${current}/${total}" "AppArmor profili (enforce)..."

    render_template "${SRVCTL_TEMPLATES}/apparmor/profile.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/apparmor.d/srvctl-${sname}"

    apparmor_parser -r "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || true
    aa-enforce "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || \
        warn "AppArmor profili yüklenemedi — manuel kontrol edin"

    success "AppArmor profili enforce modda"

    # ─── 8. MariaDB ───
    current=$((current + 1))
    step "${current}/${total}" "Veritabanı oluşturuluyor..."

    # Parolayı argv'den uzak tut: SQL stdin heredoc ile beslenir (ps/cmdline'da sır görünmez).
    # Root kimliği /root/.my.cnf'ten gelir (0600 root:root).
    # --force: yeni kullanıcıda REVOKE ALL PRIVILEGES hata verse bile sonraki SQL'ler çalışır.
    mysql --force << SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
REVOKE ALL PRIVILEGES ON *.* FROM '${db_user}'@'localhost';
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,CREATE TEMPORARY TABLES,LOCK TABLES,REFERENCES,TRIGGER ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL

    success "DB: ${db_name} / User: ${db_user}"

    # ─── 9. Redis ACL ───
    current=$((current + 1))
    step "${current}/${total}" "Redis ACL ekleniyor..."

    # Mevcut ACL'den aynı kullanıcıyı sil (varsa)
    sed -i "/^user ${redis_user} /d" /etc/redis/users.acl 2>/dev/null || true

    # Yeni ACL ekle
    echo "user ${redis_user} on >${redis_pass} ~${sname}:* &* +@all -@dangerous -CONFIG -DEBUG -KEYS -FLUSHALL -FLUSHDB -SHUTDOWN" \
        >> /etc/redis/users.acl

    # ACL'i yeniden yükle
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        # Parolayı argv'den uzak tut: REDISCLI_AUTH env redis-cli tarafından okunur (ps'te görünmez).
        REDISCLI_AUTH="$redis_admin_pass" redis-cli --user admin --no-auth-warning ACL LOAD 2>/dev/null || \
            systemctl restart redis-server
    else
        systemctl restart redis-server
    fi

    success "Redis ACL: ${redis_user} → ${sname}:*"

    # ─── 10. Logrotate ───
    current=$((current + 1))
    step "${current}/${total}" "Logrotate yapılandırılıyor..."

    render_template "${SRVCTL_TEMPLATES}/logrotate/domain.tpl" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/logrotate.d/srvctl-${sname}"

    success "Logrotate aktif"
    # ─── 11. cgroups slice + seccomp (Faz 1) ───
    _apply_cgroups_slice "${domain}" "${sname}"
    _apply_seccomp_hardening "${php_version}"
    success "cgroups slice + seccomp uygulandı"

    # ─── Credentials Dosyası (umask 077 + 0600 root:root) ───
    _domain_write_credentials "$domain" "$base" "$web_user" "$php_version" \
        "$db_name" "$db_user" "$db_pass" \
        "$redis_user" "$redis_pass" "${sname}:"

    # ─── Hoşgeldin sayfası ───
    cat > "${base}/public_html/index.php" << 'INDEXPHP'
<?php
echo '<h1>Domain is active</h1>';
echo '<p>Server time: ' . date('Y-m-d H:i:s') . '</p>';
echo '<p>PHP version: ' . PHP_VERSION . '</p>';
INDEXPHP
    chown "${web_user}:${web_user}" "${base}/public_html/index.php"

    # ─── Sonuç ───
    header "✅ Domain başarıyla eklendi: ${domain}"

    echo "  Web root:       ${base}/public_html"
    echo "  Private:        ${base}/private"
    echo "  PHP:            ${php_version} (chroot: ${base})"
    divider
    echo "  DB Name:        ${db_name}"
    echo "  DB User:        ${db_user}"
    echo "  DB Pass:        ${db_pass}"
    divider
    echo "  Redis User:     ${redis_user}"
    echo "  Redis Pass:     ${redis_pass}"
    echo "  Redis Prefix:   ${sname}:"
    divider
    echo "  Credentials:    ${base}/.credentials"
    echo ""
    echo -e "  ${BOLD}Sonraki adım:${NC}  srvctl deploy ${domain}"
    echo ""

    log_action "DOMAIN ADD: ${domain} (user=${web_user}, php=${php_version}, db=${db_name})"
}

# ═══════════════════════════════════════════════
#  DOMAIN REMOVE
# ═══════════════════════════════════════════════
_domain_remove() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname
    sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local base="${WEB_ROOT}/${domain}"

    echo ""
    warn "⚠️  ${domain} ve TÜM VERİLERİ silinecek!"
    warn "Bu işlem geri alınamaz."
    echo ""

    if ! confirm "Silmek istediğinizden emin misiniz?"; then
        info "İptal edildi."
        return 0
    fi

    # Credentials'dan bilgileri oku
    local php_version="${DEFAULT_PHP_VERSION}"
    local db_name="db_${sname}"
    local db_user="usr_${sname}"
    read_credentials "$domain"

    info "Son yedek alınıyor..."
    mkdir -p "${BACKUP_DIR}"
    tar czf "${BACKUP_DIR}/${domain}-final-$(date +%Y%m%d_%H%M%S).tar.gz" \
        "${base}" 2>/dev/null || true

    # 1. Nginx
    rm -f "/etc/nginx/sites-enabled/${domain}.conf" \
          "/etc/nginx/sites-available/${domain}.conf"
    nginx -t 2>/dev/null && systemctl reload nginx

    # 2. PHP-FPM pool
    rm -f "/etc/php/${php_version}/fpm/pool.d/${sname}.conf"
    systemctl reload "php${php_version}-fpm" 2>/dev/null || true

    # 3. AppArmor
    aa-disable "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || true
    rm -f "/etc/apparmor.d/srvctl-${sname}"

    # 4. MariaDB
    mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    # 5. Redis ACL
    sed -i "/^user redis_${sname} /d" /etc/redis/users.acl 2>/dev/null || true
    systemctl restart redis-server 2>/dev/null || true

    # 6. SSL sertifikası
    certbot delete --cert-name "${domain}" --non-interactive 2>/dev/null || true

    # 7. Logrotate
    rm -f "/etc/logrotate.d/srvctl-${sname}"

    # 7.5 cgroups slice
    systemctl stop "srvctl-${sname}.slice" 2>/dev/null || true
    rm -f "/etc/systemd/system/srvctl-${sname}.slice"
    systemctl daemon-reload 2>/dev/null || true
    
    # 8. Dosyalar
    rm -rf "${base}"

    # 9. Linux kullanıcısı
    userdel "${web_user}" 2>/dev/null || true
    groupdel "${web_user}" 2>/dev/null || true

    success "Domain kaldırıldı: ${domain}"
    info "Son yedek: ${BACKUP_DIR}/${domain}-final-*.tar.gz"

    log_action "DOMAIN REMOVE: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  Tek domain dizini için liste satırı üret (saf, parse-not-source)
#  Çıktı: domain|php|user|ssl|chroot
# ───────────────────────────────────────────────────────────────
_domain_row() {
    local dir="$1"
    local domain sname php_ver user ssl chroot
    domain=$(basename "$dir")
    sname=$(safe_name "$domain")
    php_ver="${DEFAULT_PHP_VERSION}"
    user="web_${sname}"
    ssl="❌"
    chroot="❌"

    # Credentials'tan PHP/USER bilgisini parse et (source DEĞİL); her satırda sıfırla
    if [[ -f "${dir}.credentials" ]]; then
        local PHP_VERSION="" WEB_USER=""
        read_kv_file "${dir}.credentials" PHP_VERSION WEB_USER
        # Kimlik: dosyaya güvenme — safe_name'den türet, PHP'yi doğrula
        [[ -n "$PHP_VERSION" ]] && assert_php_version "$PHP_VERSION" && php_ver="$PHP_VERSION"
        user="web_${sname}"
    fi

    # SSL kontrolü
    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && ssl="✅"

    # Chroot kontrolü
    if [[ -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" ]]; then
        grep -q "chroot" "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" 2>/dev/null && chroot="✅"
    fi

    printf '%s|%s|%s|%s|%s\n' "$domain" "$php_ver" "$user" "$ssl" "$chroot"
}

# ═══════════════════════════════════════════════
#  DOMAIN LIST
# ═══════════════════════════════════════════════
_domain_list() {
    echo ""
    echo -e "  ${BOLD}Kayıtlı Domain'ler${NC}"
    divider
    printf "  ${DIM}%-30s %-8s %-15s %-6s %-8s${NC}\n" "DOMAIN" "PHP" "KULLANICI" "SSL" "CHROOT"
    divider

    local count=0
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local row domain php_ver user ssl chroot
        row=$(_domain_row "$dir")
        IFS='|' read -r domain php_ver user ssl chroot <<< "$row"
        printf "  %-30s %-8s %-15s %-6s %-8s\n" "$domain" "$php_ver" "$user" "$ssl" "$chroot"
        count=$((count + 1))
    done

    divider
    echo "  Toplam: ${count} domain"
    echo ""
}

# ═══════════════════════════════════════════════
#  DOMAIN INFO
# ═══════════════════════════════════════════════
_domain_info() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname
    sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"

    header "Domain Bilgisi: ${domain}"

    # Credentials
    if [[ -f "${base}/.credentials" ]]; then
        read_credentials "$domain"
        echo -e "  ${CYAN}Genel${NC}"
        echo "  Kullanıcı:      ${WEB_USER:-web_${sname}}"
        echo "  PHP versiyonu:  ${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
        echo "  Dizin:          ${base}"
        divider
        echo -e "  ${CYAN}Veritabanı${NC}"
        echo "  DB Name:        ${DB_NAME:-db_${sname}}"
        echo "  DB User:        ${DB_USER:-usr_${sname}}"
        echo "  DB Pass:        ${DB_PASS:-[credentials dosyasından okunabilir]}"
        divider
        echo -e "  ${CYAN}Redis${NC}"
        echo "  Redis User:     ${REDIS_USER:-redis_${sname}}"
        echo "  Redis Prefix:   ${REDIS_PREFIX:-${sname}:}"
    else
        warn "Credentials dosyası bulunamadı: ${base}/.credentials"
    fi

    divider

    # Disk kullanımı
    echo -e "  ${CYAN}Kaynaklar${NC}"
    local disk
    disk=$(du -sh "${base}" 2>/dev/null | awk '{print $1}')
    echo "  Disk kullanımı: ${disk}"

    # DB boyutu
    local db_size
    db_size=$(mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = 'db_${sname}';" 2>/dev/null)
    echo "  DB boyutu:      ${db_size:-0} MB"

    divider

    # Güvenlik durumu
    echo -e "  ${CYAN}Güvenlik Durumu${NC}"

    local php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"

    # PHP-FPM pool
    local pool_status="${RED}❌ Yok${NC}"
    if [[ -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" ]]; then
        if grep -q "chroot" "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" 2>/dev/null; then
            pool_status="${GREEN}✅ Aktif (chroot)${NC}"
        else
            pool_status="${YELLOW}⚠️  Aktif (chroot yok)${NC}"
        fi
    fi
    echo -e "  PHP-FPM Pool:   ${pool_status}"

    # AppArmor
    local aa_status="${RED}❌ Yok${NC}"
    if aa-status 2>/dev/null | grep -q "srvctl-${sname}"; then
        aa_status="${GREEN}✅ Enforce${NC}"
    fi
    echo -e "  AppArmor:       ${aa_status}"

    # SSL
    local ssl_status="${RED}❌ Yok${NC}"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout \
            -in "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null | cut -d= -f2)
        ssl_status="${GREEN}✅ Aktif (bitiş: ${expiry})${NC}"
    fi
    echo -e "  SSL:            ${ssl_status}"

    # Nginx
    local nginx_status="${RED}❌ Yok${NC}"
    [[ -f "/etc/nginx/sites-enabled/${domain}.conf" ]] && \
        nginx_status="${GREEN}✅ Aktif${NC}"
    echo -e "  Nginx:          ${nginx_status}"

    # Dosya izinleri
    local perm
    perm=$(stat -c %a "${base}" 2>/dev/null)
    local perm_status="${RED}❌ ${perm}${NC}"
    [[ "$perm" == "750" ]] && perm_status="${GREEN}✅ 750${NC}"
    echo -e "  Dosya izinleri: ${perm_status}"

    echo ""
}
# ═══════════════════════════════════════════════════════════════
#  domain.sh — EK BLOK (Faz 1 cgroups/seccomp helpers + Faz 2 ops)
#
#  Bu blok mevcut lib/domain.sh dosyanızın SONUNA eklenir.
#  cmd_domain() dispatcher'ı bu fonksiyonları zaten çağırıyor.
#  _domain_add içine 2 satırlık çağrı eklemeniz gerekir (bkz. INTEGRATION.md).
# ═══════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  Helper: Per-domain cgroups v2 slice oluştur (Faz 1)
#  systemd "srvctl-<sname>.slice" otomatik olarak srvctl.slice altına girer.
# ───────────────────────────────────────────────────────────────
_apply_cgroups_slice() {
    local domain="$1" sname="$2"
    local slice_file="/etc/systemd/system/srvctl-${sname}.slice"

    # Template varsa kullan, yoksa güvenli varsayılanlarla üret.
    if [[ -f "${SRVCTL_TEMPLATES}/cgroups/domain.slice.tpl" ]]; then
        render_template "${SRVCTL_TEMPLATES}/cgroups/domain.slice.tpl" \
            "DOMAIN=${domain}" \
            "CPU_QUOTA=100%" \
            "MEMORY_MAX=512M" \
            "MEMORY_HIGH=450M" \
            "IO_READ_MAX=" \
            "IO_WRITE_MAX=" \
            "TASKS_MAX=100" \
            > "${slice_file}.tmp" 2>/dev/null
        # Geçersiz/boş IO satırlarını temizle (device gerektirir)
        grep -vE 'IO(Read|Write)BandwidthMax=\s*$' "${slice_file}.tmp" > "${slice_file}" 2>/dev/null
        rm -f "${slice_file}.tmp"
    else
        cat > "${slice_file}" << SLICE
[Unit]
Description=srvctl resource slice for ${domain}
[Slice]
CPUWeight=100
CPUQuota=100%
MemoryHigh=450M
MemoryMax=512M
MemorySwapMax=0
TasksMax=100
IOWeight=100
SLICE
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl start "srvctl-${sname}.slice" 2>/dev/null || true
}

# ───────────────────────────────────────────────────────────────
#  Helper: PHP-FPM servisine seccomp benzeri syscall kısıtı (Faz 1)
#  systemd SystemCallFilter ile tehlikeli syscall'ları engeller.
#  Sistem geneli (php-fpm tek master) — sadece ilk kez/uygulanmamışsa
#  servisi yeniden başlatır (idempotent).
# ───────────────────────────────────────────────────────────────
_apply_seccomp_hardening() {
    local php_version="$1"
    local dropin_dir="/etc/systemd/system/php${php_version}-fpm.service.d"
    local dropin="${dropin_dir}/10-srvctl-seccomp.conf"

    # seccomp JSON'daki deny listesinden türetildi (clone3 hariç — glibc kırılmasın)
    local deny="kexec_load kexec_file_load reboot swapon swapoff mount umount2 pivot_root init_module finit_module delete_module create_module query_module unshare setns userfaultfd perf_event_open bpf add_key request_key keyctl ptrace process_vm_readv process_vm_writev kcmp lookup_dcookie io_uring_setup io_uring_enter io_uring_register"

    mkdir -p "$dropin_dir"
    local new_content
    new_content="[Service]
SystemCallFilter=~${deny}
SystemCallArchitectures=native
NoNewPrivileges=true
RestrictSUIDSGID=true
ProtectKernelModules=true
ProtectKernelTunables=true"

    # Sadece değişiklik varsa yaz + restart (her domain add'de restart etme)
    if [[ ! -f "$dropin" ]] || [[ "$(cat "$dropin")" != "$new_content" ]]; then
        echo "$new_content" > "$dropin"
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "php${php_version}-fpm" 2>/dev/null || \
            warn "php${php_version}-fpm yeniden başlatılamadı (seccomp drop-in)"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Faz 2 — OPERASYONEL KOMUTLAR
# ═══════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  domain clone <kaynak> <hedef>
# ───────────────────────────────────────────────────────────────
_domain_clone() {
    local src="$1" dst="$2"
    [[ -z "$src" || -z "$dst" ]] && error "Kullanım: srvctl domain clone <kaynak> <hedef>"
    domain_exists "$src" || error "Kaynak domain bulunamadı: ${src}"
    domain_exists "$dst" && error "Hedef domain zaten mevcut: ${dst}"

    local src_base="${WEB_ROOT}/${src}"
    local src_sname; src_sname=$(safe_name "$src")
    local dst_sname; dst_sname=$(safe_name "$dst")

    # Kimlikleri dosyaya güvenmeden safe_name'den türet; PHP'yi doğrula
    local src_php; src_php=$(_derive_php "$src" "${DEFAULT_PHP_VERSION}")
    local src_db="db_${src_sname}"

    header "Domain Klonlama: ${src} → ${dst}"

    step "1/4" "Hedef domain oluşturuluyor (tam güvenlik kurulumu)..."
    _domain_add "$dst" "--php=${src_php}"

    local dst_base="${WEB_ROOT}/${dst}"
    local dst_web_user="web_${dst_sname}"
    local dst_db="db_${dst_sname}"

    step "2/4" "Dosyalar kopyalanıyor..."
    if [[ -d "${src_base}/public_html" ]]; then
        rsync -a --delete --exclude 'releases/' --exclude '.credentials' --exclude '.deploy-repo' \
            "${src_base}/public_html/" "${dst_base}/public_html/" 2>/dev/null || \
            cp -a "${src_base}/public_html/." "${dst_base}/public_html/" 2>/dev/null || true
    fi
    [[ -d "${src_base}/private" ]] && rsync -a "${src_base}/private/" "${dst_base}/private/" 2>/dev/null || true
    [[ -d "${src_base}/shared"  ]] && rsync -a "${src_base}/shared/"  "${dst_base}/shared/"  2>/dev/null || true
    chown -R "${dst_web_user}:${dst_web_user}" "${dst_base}/public_html" "${dst_base}/private" "${dst_base}/shared" 2>/dev/null || true
    success "Dosyalar kopyalandı"

    step "3/4" "Veritabanı kopyalanıyor (${src_db} → ${dst_db})..."
    if mysql -e "USE \`${src_db}\`" 2>/dev/null; then
        mysqldump --single-transaction --routines --triggers "${src_db}" 2>/dev/null \
            | mysql "${dst_db}" 2>/dev/null \
            && success "Veritabanı kopyalandı" || warn "DB kopyalanamadı"
    else
        warn "Kaynak DB bulunamadı: ${src_db} — atlanıyor"
    fi

    step "4/4" "Yapılandırma referansları güncelleniyor..."
    for envf in "${dst_base}/shared/.env" "${dst_base}/public_html/.env"; do
        [[ -f "$envf" ]] && sed -i "s|${src}|${dst}|g" "$envf" 2>/dev/null || true
    done
    success "Tamamlandı"

    echo ""
    warn "Hedef DB şifresi yeni üretildi — ${dst_base}/.credentials dosyasına bakın ve .env'i güncelleyin."
    log_action "DOMAIN CLONE: ${src} -> ${dst}"
}

# ───────────────────────────────────────────────────────────────
#  domain suspend <domain>  — bakım modu (503 + maintenance.html)
# ───────────────────────────────────────────────────────────────
_domain_suspend() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl domain suspend <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local base="${WEB_ROOT}/${domain}"
    local vhost="/etc/nginx/sites-available/${domain}.conf"
    [[ -f "$vhost" ]] || error "Nginx vhost bulunamadı: ${vhost}"

    info "Bakım moduna alınıyor: ${domain}"

    # maintenance.html'i public_html'e render et
    if [[ -f "${SRVCTL_TEMPLATES}/nginx/maintenance.html" ]]; then
        render_template "${SRVCTL_TEMPLATES}/nginx/maintenance.html" "DOMAIN=${domain}" \
            > "${base}/public_html/maintenance.html"
    fi

    # Bakım bloğunu vhost'a idempotent ekle
    if ! grep -q "srvctl-maintenance-block" "$vhost"; then
        sed -i "/server_name ${domain}/a\\
    # srvctl-maintenance-block\\
    error_page 503 @srvctl_maintenance;\\
    location @srvctl_maintenance { root ${base}/public_html; rewrite ^ /maintenance.html break; }\\
    if (-f ${base}/.suspended) { return 503; }" "$vhost"
    fi

    touch "${base}/.suspended"
    nginx_test && systemctl reload nginx
    success "Domain bakım modunda: ${domain}"
    log_action "DOMAIN SUSPEND: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  domain unsuspend <domain>
# ───────────────────────────────────────────────────────────────
_domain_unsuspend() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl domain unsuspend <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    local base="${WEB_ROOT}/${domain}"
    rm -f "${base}/.suspended"
    nginx_test && systemctl reload nginx
    success "Domain tekrar aktif: ${domain}"
    log_action "DOMAIN UNSUSPEND: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  domain php-switch <domain> <versiyon>
# ───────────────────────────────────────────────────────────────
_domain_php_switch() {
    local domain="$1" new_ver="$2"
    [[ -z "$domain" || -z "$new_ver" ]] && error "Kullanım: srvctl domain php-switch <domain> <versiyon>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    php_version_exists "$new_ver" || error "PHP ${new_ver} kurulu değil. Önce: apt install php${new_ver}-fpm"

    local sname; sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"
    local PHP_VERSION="${DEFAULT_PHP_VERSION}"
    read_credentials "$domain"
    local old_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    # old_ver .credentials'tan geliyor (untrusted); sed/systemctl'e gitmeden doğrula.
    assert_php_version "$old_ver" || old_ver="${DEFAULT_PHP_VERSION}"
    [[ "$old_ver" == "$new_ver" ]] && { info "Domain zaten PHP ${new_ver} kullanıyor."; return; }

    local old_pool="/etc/php/${old_ver}/fpm/pool.d/${sname}.conf"
    local new_pool="/etc/php/${new_ver}/fpm/pool.d/${sname}.conf"
    [[ -f "$old_pool" ]] || error "Mevcut pool bulunamadı: ${old_pool}"

    header "PHP Sürüm Değişimi: ${old_ver} → ${new_ver} (${domain})"

    step "1/5" "Chroot kütüphaneleri (php${new_ver}-fpm)..."
    # PHP-FPM, Eklentiler (Extensions) ve Shared Libraries
    _apply_chroot_php_deps "${base}" "${new_ver}"
    success "Chroot kütüphaneleri güncellendi"

    step "2/5" "PHP-FPM pool taşınıyor..."
    sed "s|php${old_ver}-fpm-${sname}.sock|php${new_ver}-fpm-${sname}.sock|g" "$old_pool" > "$new_pool"
    rm -f "$old_pool"
    systemctl reload "php${old_ver}-fpm" 2>/dev/null || true
    systemctl reload "php${new_ver}-fpm" 2>/dev/null || systemctl restart "php${new_ver}-fpm"
    success "Pool: php${new_ver}-fpm-${sname}"

    step "3/5" "Seccomp hardening (yeni sürüm)..."
    _apply_seccomp_hardening "$new_ver"
    success "Seccomp uygulandı"

    step "4/5" "Nginx fastcgi_pass güncelleniyor..."
    sed -i "s|php${old_ver}-fpm-${sname}.sock|php${new_ver}-fpm-${sname}.sock|g" \
        "/etc/nginx/sites-available/${domain}.conf"
    nginx_test && systemctl reload nginx
    success "Nginx güncellendi"

    step "5/5" "Kayıt güncelleniyor..."
    sed -i "s|^PHP_VERSION=.*|PHP_VERSION=${new_ver}|" "${base}/.credentials"
    success "Domain artık PHP ${new_ver}"
    log_action "DOMAIN PHP-SWITCH: ${domain} (${old_ver} -> ${new_ver})"
}

# ───────────────────────────────────────────────────────────────
#  domain resources <domain> [--memory=512M] [--cpu=50%] [--io=100] [--show]
# ───────────────────────────────────────────────────────────────
_domain_resources() {
    local domain="$1"; shift || true
    [[ -z "$domain" ]] && error "Kullanım: srvctl domain resources <domain> [--memory=512M] [--cpu=50%] [--io=100] [--show]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local slice="srvctl-${sname}.slice"
    local slice_path="/etc/systemd/system/${slice}"
    local mem="" cpu="" io="" show=0

    for arg in "$@"; do
        case "$arg" in
            --memory=*) mem="${arg#--memory=}" ;;
            --cpu=*)    cpu="${arg#--cpu=}" ;;
            --io=*)     io="${arg#--io=}" ;;
            --show)     show=1 ;;
            *) warn "Bilinmeyen seçenek: ${arg}" ;;
        esac
    done

    if [[ "$show" == "1" ]]; then
        header "Kaynak Durumu: ${domain}"
        if systemctl show "$slice" >/dev/null 2>&1; then
            systemctl show "$slice" -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax -p MemoryCurrent 2>/dev/null | sed 's/^/  /'
        else
            echo "  (Henüz kaynak limiti tanımlı değil)"
        fi
        echo ""
        return
    fi

    [[ -z "$mem$cpu$io" ]] && error "En az bir limit verin: --memory=512M / --cpu=50% / --io=100"

    info "Kaynak limitleri uygulanıyor: ${domain}"
    {
        echo "[Unit]"
        echo "Description=srvctl resource slice for ${domain}"
        echo "[Slice]"
        [[ -n "$mem" ]] && { echo "MemoryMax=${mem}"; echo "MemoryHigh=${mem}"; }
        [[ -n "$cpu" ]] && echo "CPUQuota=${cpu}"
        [[ -n "$io"  ]] && echo "IOWeight=${io}"
    } > "$slice_path"

    systemctl daemon-reload
    systemctl start "$slice" 2>/dev/null || true

    [[ -n "$mem" ]] && success "Bellek limiti: ${mem}"
    [[ -n "$cpu" ]] && success "CPU limiti:    ${cpu}"
    [[ -n "$io"  ]] && success "IO ağırlığı:   ${io}"
    log_action "DOMAIN RESOURCES: ${domain} (mem=${mem} cpu=${cpu} io=${io})"
}

# ───────────────────────────────────────────────────────────────
#  domain staging <domain>  — staging.<domain> klonu
# ───────────────────────────────────────────────────────────────
_domain_staging() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl domain staging <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    local staging="staging.${domain}"
    domain_exists "$staging" && error "Staging zaten mevcut: ${staging}"

    info "Staging ortamı oluşturuluyor: ${staging}"
    _domain_clone "$domain" "$staging"
    echo ""
    success "Staging hazır: https://${staging}"
    warn "DNS: ${staging} A kaydı + 'srvctl ssl renew' gerekebilir."
    log_action "DOMAIN STAGING: ${domain} -> ${staging}"
}

# ───────────────────────────────────────────────────────────────
#  domain migrate <domain> <user@host> [--auto]
# ───────────────────────────────────────────────────────────────
_domain_migrate() {
    local domain="$1" remote="$2" auto=0
    [[ "${3:-}" == "--auto" ]] && auto=1
    [[ -z "$domain" || -z "$remote" ]] && error "Kullanım: srvctl domain migrate <domain> <user@host> [--auto]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"
    # Identifier'ları safe_name'den türet; PHP'yi doğrula (dosyaya güvenme)
    local db="db_${sname}"
    local php; php=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")

    local stamp; stamp=$(date +%Y%m%d_%H%M%S)
    local bundle="${BACKUP_DIR}/migrate-${domain}-${stamp}"
    mkdir -p "$bundle"

    header "Migrasyon: ${domain} → ${remote}"

    step "1/3" "Dosyalar arşivleniyor..."
    # NOT: .credentials/.srvctl-meta tarball'a girmez (sır sızıntısı); credentials
    # ayrı 0600 dosya olarak taşınır. Relatif yol → karşı uçta safe_extract uyumlu.
    source "${SRVCTL_ROOT}/lib/backup.sh" 2>/dev/null || true
    _backup_files_tar "${domain}" "${WEB_ROOT}" "${bundle}/files.tar.gz" 2>/dev/null
    cp "${base}/.credentials" "${bundle}/credentials" 2>/dev/null || true
    secure_file "${bundle}/credentials" 600

    step "2/3" "Veritabanı dökümü (${db})..."
    mysqldump --single-transaction --routines --triggers "${db}" 2>/dev/null | gzip > "${bundle}/db.sql.gz" \
        || warn "DB dökümü alınamadı"

    step "3/3" "Karşı sunucuya kopyalanıyor (${remote})..."
    scp -r "${bundle}" "${remote}:/tmp/" || error "scp başarısız — SSH erişimini kontrol edin."
    success "Paket kopyalandı: ${remote}:/tmp/$(basename "$bundle")"

    echo ""
    if [[ "$auto" == "1" ]]; then
        warn "--auto: karşı sunucuda içe aktarma deneniyor..."
        ssh "$remote" "command -v srvctl >/dev/null && srvctl domain add ${domain} --php=${php} && tar xzf /tmp/$(basename "$bundle")/files.tar.gz -C ${WEB_ROOT} && zcat /tmp/$(basename "$bundle")/db.sql.gz | mysql ${db}" \
            && success "Karşı sunucuda içe aktarıldı." || warn "Otomatik aktarma başarısız — manuel adımları izleyin."
    else
        echo -e "  ${BOLD}Karşı sunucuda çalıştırın:${NC}"
        echo "    cd /tmp/$(basename "$bundle")"
        echo "    srvctl domain add ${domain} --php=${php}"
        echo "    tar xzf files.tar.gz -C ${WEB_ROOT}"
        echo "    zcat db.sql.gz | mysql ${db}"
        echo ""
    fi
    log_action "DOMAIN MIGRATE: ${domain} -> ${remote} (auto=${auto})"
}

# ═══════════════════════════════════════════════
#  DOMAIN RATE-LIMIT — per-domain profil yönetimi
# ═══════════════════════════════════════════════
_rate_limit_list() {
    header "Rate-Limit Profilleri"
    printf "  %-10s %-12s %-6s %-15s %-6s %s\n" "PROFİL" "REQ_ZONE" "BURST" "LOGIN_ZONE" "BURST" "CONN"
    divider
    local p
    for p in $(rate_profile_names); do
        printf "  %-10s %-12s %-6s %-15s %-6s %s\n" \
            "$p" \
            "$(rate_profile_field "$p" 2)" \
            "$(rate_profile_field "$p" 3)" \
            "$(rate_profile_field "$p" 4)" \
            "$(rate_profile_field "$p" 5)" \
            "$(rate_profile_field "$p" 6)"
    done
}

_domain_rate_limit() {
    # require_root yalnızca yazma (profil değiştirme) için; --show/--list salt-okunur.
    local domain="" profile="" action="set" arg
    for arg in "$@"; do
        case "$arg" in
            --show) action="show" ;;
            --list) action="list" ;;
            -*)     warn "Bilinmeyen seçenek: ${arg}" ;;
            *)      if [[ -z "$domain" ]]; then domain="$arg"; else profile="$arg"; fi ;;
        esac
    done

    if [[ "$action" == "list" ]]; then
        _rate_limit_list
        return
    fi

    [[ -z "$domain" ]] && error "Kullanım: srvctl domain rate-limit <domain> <profil> | --show | --list"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    if [[ "$action" == "show" ]]; then
        read_meta "$domain"
        rate_profile_load "${RATE_PROFILE:-standard}"
        info "Domain: ${domain}"
        echo "  Profil:        ${RL_PROFILE}"
        echo "  İstek zone:    ${RL_REQ_ZONE} (burst ${RL_REQ_BURST})"
        echo "  Login zone:    ${RL_LOGIN_ZONE} (burst ${RL_LOGIN_BURST})"
        echo "  Bağlantı/IP:   ${RL_CONN}"
        return
    fi

    # ─── Profil değiştir (root gerekir) ───
    require_root
    [[ -z "$profile" ]] && error "Profil belirtilmedi. Kullanım: srvctl domain rate-limit ${domain} <profil>"
    [[ -z "$(rate_profile_line "$profile")" ]] && error "Geçersiz profil: ${profile} (srvctl domain rate-limit --list)"

    read_credentials "$domain"
    local php_version="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    local conf="/etc/nginx/sites-available/${domain}.conf"
    local mode="http"
    grep -q 'listen 443' "$conf" 2>/dev/null && mode="ssl"

    # Mevcut config'i yedekle (atomic geri dönüş)
    local backup="${conf}.bak.$$"
    cp "$conf" "$backup"

    _domain_write_vhost "$domain" "$php_version" "$profile" "$mode"

    if nginx -t 2>/dev/null; then
        rm -f "$backup"
        write_meta "$domain" "RATE_PROFILE" "$profile"
        systemctl reload nginx
        log_action "domain rate-limit ${domain} → ${profile}"
        success "Rate-limit profili güncellendi: ${domain} → ${profile}"
    else
        mv "$backup" "$conf"
        error "Nginx testi başarısız — değişiklik geri alındı. Profil değişmedi."
    fi
}
