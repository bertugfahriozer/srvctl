#!/bin/bash
# ═══════════════════════════════════════════════
#  user.sh — RBAC Kullanıcı Yönetimi + 2FA
# ═══════════════════════════════════════════════

# Test için override edilebilir (SITES_AVAILABLE / SRVCTL_FPM_DIR ile aynı desen)
SRVCTL_USERS_DIR="${SRVCTL_USERS_DIR:-/etc/srvctl/users}"
# Ev dizini tabanı — test seam'i (K1 düzeltmesi, aşağıya bkz.). Üretimde /home.
SRVCTL_HOME_BASE="${SRVCTL_HOME_BASE:-/home}"

# ─── K1 DÜZELTMESİ (haftalık denetim 2026-09) — ev dizini altına ROOT yazımı ───
# ESKİ DAVRANIŞ: 'user key add|remove' ve 'user 2fa setup' (fallback dalı),
# '/home/<u>/.ssh/authorized_keys' ve '/home/<u>/.google_authenticator'a root
# olarak '>>' / ': >' ile yazıyor, ardından 'chmod' + 'chown' (-h OLMADAN)
# uyguluyordu. '_user_add' bu dizini zaten hedef kullanıcıya 'chown -R' ettiği
# için kullanıcı, dizinin TAM SAHİBİDİR: 'ln -sf /etc/shadow
# ~/.ssh/authorized_keys' koyabilir. Operatörün tek bir 'srvctl user key add'
# çağrısı → root symlink'i izleyip /etc/shadow'a yazar, 600'e çeker ve
# dosyayı 'chown' ile SALDIRGANA DEVREDER (tam root yükseltmesi). 'key
# remove' tek başına keyfi bir root dosyasını TRUNCATE eder. 2FA fallback
# dalı da saldırgan tarafından tetiklenebilir ('su - <u> -c ...' kullanıcının
# kendi ~/.profile'ı sıfırdan farklı dönerse başarısız olur).
#
# 'fs.protected_symlinks=1' (init.sh) burada KORUMAZ: o sysctl yalnız
# world-writable + sticky dizinlerde (/tmp) devreye girer; ~/.ssh 700'dür.
#
# DÜZELTME: '_user_guard_home_path' — ev dizininden hedef dosyaya kadar HER
# bileşen sembolik bağ değil mi diye bakar (ev dizininin KENDİSİ dahil:
# kullanıcı '~/.ssh' dizinini de '/root/.ssh'e bağlayabilir). Yazımlar
# 'secure_file' (core.sh — kendi ikinci TOCTOU kapısı var) üzerinden, tüm
# chown'lar '-h' ile yapılır. Kalan pencere secure_file'ınkiyle aynıdır.
#
# Kullanım: _user_guard_home_path <username> <göreli-yol>   (predicate, exit YOK)
_user_guard_home_path() {
    local username="$1" rel="$2"
    local home="${SRVCTL_HOME_BASE}/${username}"
    local p="$home" comp
    _reject_symlink "$home" "ev dizini" || return 1
    local IFS='/'
    for comp in $rel; do
        [[ -n "$comp" ]] || continue
        p="${p}/${comp}"
        _reject_symlink "$p" "ev dizini altı yol" || return 1
    done
    return 0
}

# Kullanıcının ~/.ssh dizinini güvenle hazırla (symlink kapısı + 700 + -h chown).
_user_ensure_ssh_dir() {
    local username="$1"
    local ssh_dir="${SRVCTL_HOME_BASE}/${username}/.ssh"
    _user_guard_home_path "$username" ".ssh" || return 1
    mkdir -p "$ssh_dir" || return 1
    _reject_symlink "$ssh_dir" "dizin" || return 1
    chmod 700 "$ssh_dir" || return 1
    chown -h "${username}:${username}" "$ssh_dir" 2>/dev/null || true
    return 0
}

cmd_user() {
    require_root
    case "${1:-help}" in
        add)      _user_add "${@:2}" ;;
        remove)   _user_remove "${@:2}" ;;
        list)     _user_list ;;
        info)     _user_info "${@:2}" ;;
        grant)    _user_grant "${@:2}" ;;
        revoke)   _user_revoke "${@:2}" ;;
        key)      _user_key "${@:2}" ;;
        2fa)      _user_2fa "${@:2}" ;;
        audit)    _user_audit "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl user <add|remove|list|info|grant|revoke|key|2fa|audit>"
            echo ""
            echo "    add <username> [--role=admin|developer|viewer]"
            echo "    remove <username>"
            echo "    list"
            echo "    info <username>"
            echo "    grant <username> <domain>     Domain erişimi ver"
            echo "    revoke <username> <domain>    Domain erişimini kaldır"
            echo "    key add <username> <pubkey>   SSH key ekle"
            echo "    key remove <username>         SSH key kaldır"
            echo "    2fa setup <username>          TOTP 2FA etkinleştir"
            echo "    2fa disable <username>        2FA devre dışı bırak"
            echo "    audit [username]              İşlem geçmişi"
            echo ""
            echo "  Roller:"
            echo "    admin       Tüm komutlara erişim"
            echo "    developer   deploy, domain info, backup, status"
            echo "    viewer      status, domain list, domain info"
            echo ""
            ;;
    esac
}

# Test edilebilir kullanıcı adı doğrulama kapısı (predicate; error/exit YOK).
_user_add_validate_gate() {
    validate_username "$1"
}

_user_add() {
    local username=""
    local role="developer"

    for arg in "$@"; do
        case "$arg" in
            --role=*) role="${arg#--role=}" ;;
            *) username="$arg" ;;
        esac
    done

    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    _user_add_validate_gate "$username" || error "Geçersiz kullanıcı adı: ${username} (^[a-z_][a-z0-9_-]*$, en fazla 32)"
    [[ "$role" =~ ^(admin|developer|viewer)$ ]] || error "Geçersiz rol: ${role}. (admin|developer|viewer)"

    mkdir -p "${SRVCTL_USERS_DIR}"

    [[ -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı zaten mevcut: ${username}"

    # Linux kullanıcısı oluştur
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash "$username"
        info "Linux kullanıcısı oluşturuldu: ${username}"
    fi

    # SSH dizini (K1: symlink kapısı + '-h' chown; eski 'chown -R' hedefi izlerdi)
    _user_ensure_ssh_dir "$username" \
        || error "GÜVENLİK: ${SRVCTL_HOME_BASE}/${username}/.ssh güvenli hazırlanamadı (sembolik bağ?) — kullanıcı eklenmedi."

    # Kullanıcı yapılandırma dosyası
    cat > "${SRVCTL_USERS_DIR}/${username}.conf" << USERCONF
# srvctl kullanıcısı: ${username}
# Oluşturulma: $(date '+%Y-%m-%d %H:%M:%S')
ROLE=${role}
DOMAINS=
CREATED=$(date +%s)
LAST_LOGIN=
TWOFA_ENABLED=false
TWOFA_SECRET=
USERCONF
    chmod 600 "${SRVCTL_USERS_DIR}/${username}.conf"

    # sudoers — role göre izinler
    _update_sudoers "$username" "$role"

    success "Kullanıcı oluşturuldu: ${username} (rol: ${role})"
    log_action "USER ADD: ${username} (role=${role})"
}

_user_remove() {
    local username="$1"
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    confirm "Kullanıcı silinecek: ${username}. Devam?" || return 0

    # sudoers'dan kaldır
    rm -f "/etc/sudoers.d/srvctl-${username}"

    # Kullanıcı config'i sil
    rm -f "${SRVCTL_USERS_DIR}/${username}.conf"

    # Opsiyonel: Linux kullanıcısını da sil
    if confirm "Linux kullanıcısını da silmek ister misiniz? (home dizini silinir)"; then
        userdel -r "$username" 2>/dev/null || true
    fi

    success "Kullanıcı silindi: ${username}"
    log_action "USER REMOVE: ${username}"
}

# Kullanıcı conf'unu OKU (asla source etme) + eski anahtar adlarını göç ettir.
# Eski dosyalar '2FA_ENABLED=' yazıyordu; bu geçerli bir bash değişken adı
# DEĞİL — 'source' ederken "command not found", '${2FA_ENABLED}' ise
# "bad substitution" veriyordu, yani user list/info tamamen çalışmıyordu.
_user_read_conf() {
    local conf="$1"
    [[ -f "$conf" ]] || return 0

    # Tek seferlik göç: 2FA_* → TWOFA_*.
    # H5 DÜZELTMESİ (denetim DALGA 4): _sed_inplace (core.sh) ATOMİK yazar VE
    # başarı/başarısızlığı DÖNÜŞ DEĞERİYLE bildirir — eski 'sed -i.bak ... &&
    # rm -f .bak' zincirinin sonucu HİÇ kontrol edilmiyordu: salt-okunur/
    # immutable bir dosyada sed başarısız olsa bile "güncellendi" deniyor,
    # '.bak' (2FA secret'ini İÇEREN) kalıcı bir kopya olarak kalıyordu VE
    # sonraki read_kv_file eski 'TWOFA_*' adlarını bulamadığından tüm alanlar
    # sessizce boş kalıyordu ('user list' 2FA'yı kapalı gösterirdi). Ayrıca
    # '_sed_inplace' '.bak' TÜRÜ bir kopya HİÇ bırakmaz (sır sızıntısı riski
    # azalır — KARAR 2 gerekçesi).
    if grep -q '^2FA_' "$conf" 2>/dev/null; then
        if _sed_inplace "$conf" -e 's|^2FA_ENABLED=|TWOFA_ENABLED=|' -e 's|^2FA_SECRET=|TWOFA_SECRET=|'; then
            info "Kullanıcı conf'u güncellendi (2FA_* → TWOFA_*): $(basename "$conf")"
        else
            warn "Kullanıcı conf'u göç ettirilemedi (2FA_* → TWOFA_*): $(basename "$conf") — dosya salt-okunur/immutable olabilir; 2FA alanları eski adlarla kalmış olabilir"
        fi
    fi

    ROLE=""; DOMAINS=""; CREATED=""; LAST_LOGIN=""; TWOFA_ENABLED=""; TWOFA_SECRET=""
    read_kv_file "$conf" ROLE DOMAINS CREATED LAST_LOGIN TWOFA_ENABLED TWOFA_SECRET
}

_user_list() {
    header "srvctl Kullanıcıları"

    printf "  ${DIM}%-15s %-12s %-30s %-6s${NC}\n" "KULLANICI" "ROL" "DOMAİNLER" "2FA"
    divider

    for conf in "${SRVCTL_USERS_DIR}"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        local username
        username=$(basename "$conf" .conf)

        _user_read_conf "$conf"

        local twofa_icon="❌"
        [[ "${TWOFA_ENABLED:-false}" == "true" ]] && twofa_icon="✅"

        printf "  %-15s %-12s %-30s %-6s\n" "$username" "${ROLE:-?}" "${DOMAINS:-tümü}" "$twofa_icon"
    done

    echo ""
}

_user_info() {
    local username="$1"
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    _user_read_conf "${SRVCTL_USERS_DIR}/${username}.conf"

    header "Kullanıcı: ${username}"

    echo "  Rol:            ${ROLE:-bilinmiyor}"
    echo "  Domain'ler:     ${DOMAINS:-tümü (admin)}"
    echo "  Oluşturulma:    $(date -d "@${CREATED:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${CREATED:-bilinmiyor}")"
    echo "  Son giriş:      ${LAST_LOGIN:-bilinmiyor}"
    echo "  2FA:            ${TWOFA_ENABLED:-false}"

    divider

    # SSH key'ler
    echo -e "  ${CYAN}SSH Key'ler${NC}"
    if [[ -f "${SRVCTL_HOME_BASE}/${username}/.ssh/authorized_keys" ]]; then
        local key_count
        key_count=$(wc -l < "${SRVCTL_HOME_BASE}/${username}/.ssh/authorized_keys")
        echo "  ${key_count} key tanımlı"
    else
        echo "  Henüz key eklenmemiş"
    fi

    divider

    # Son işlemler
    echo -e "  ${CYAN}Son İşlemler${NC}"
    grep "\[${username}\]" "${SRVCTL_LOG}" 2>/dev/null | tail -5 || echo "  İşlem kaydı yok"

    echo ""
}

_user_grant() {
    local username="$1" domain="$2"
    [[ -z "$domain" ]] && error "Kullanım: srvctl user grant <username> <domain>"
    # B5 sertleştirmesi (denetim DALGA 4): domain_exists'e eklenen validate_domain
    # kapısının birebir user tarafı — username daha sonra dosya yollarına
    # (ör. /home/${username}/...) akan başka komutlarda kullanılabileceğinden
    # burada da erken doğrulanır (defense-in-depth; conf dosyası varlık
    # kontrolü zaten aşağıda var ama tek başına yeterli garanti değil).
    validate_username "$username" || error "Geçersiz kullanıcı adı: ${username}"
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    local current_domains
    current_domains=$(grep "^DOMAINS=" "${SRVCTL_USERS_DIR}/${username}.conf" | cut -d= -f2)

    # KARAR 2: atomik/portable _sed_inplace (bkz. core.sh) — çıplak GNU-only
    # 'sed -i' yerine.
    if [[ -z "$current_domains" ]]; then
        _sed_inplace "${SRVCTL_USERS_DIR}/${username}.conf" "s|^DOMAINS=|DOMAINS=${domain}|"
    else
        _sed_inplace "${SRVCTL_USERS_DIR}/${username}.conf" "s|^DOMAINS=.*|DOMAINS=${current_domains},${domain}|"
    fi

    # Domain'in web grubuna ekle
    local sname
    sname=$(safe_name "$domain")
    usermod -aG "web_${sname}" "$username" 2>/dev/null || true

    success "${username} → ${domain} erişimi verildi"
    log_action "USER GRANT: ${username} → ${domain}"
}

_user_revoke() {
    local username="$1" domain="$2"
    [[ -z "$domain" ]] && error "Kullanım: srvctl user revoke <username> <domain>"
    # B5 sertleştirmesi — bkz. _user_grant üzerindeki gerekçe.
    validate_username "$username" || error "Geçersiz kullanıcı adı: ${username}"
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    # Domain'i listeden kaldır
    local current
    current=$(grep "^DOMAINS=" "${SRVCTL_USERS_DIR}/${username}.conf" | cut -d= -f2)
    local new_domains
    new_domains=$(echo "$current" | tr ',' '\n' | grep -v "^${domain}$" | tr '\n' ',' | sed 's/,$//')
    # KARAR 2: atomik/portable _sed_inplace (bkz. core.sh).
    _sed_inplace "${SRVCTL_USERS_DIR}/${username}.conf" "s|^DOMAINS=.*|DOMAINS=${new_domains}|"

    # Gruptan çıkar
    local sname
    sname=$(safe_name "$domain")
    gpasswd -d "$username" "web_${sname}" 2>/dev/null || true

    success "${username} → ${domain} erişimi kaldırıldı"
    log_action "USER REVOKE: ${username} → ${domain}"
}

_user_key() {
    # set -u altında 'user key remove <name>' 3. argümansız çağrılıyordu
    # → "$3: unbound variable" ile komut düşüyordu.
    local action="${1:-}" username="${2:-}" pubkey="${3:-}"
    [[ -z "$username" ]] && error "Kullanım: srvctl user key <add|remove> <username> [pubkey]"
    # ─── B5 DÜZELTMESİ (denetim DALGA 4) ───
    # 'remove' dalında NE validate_username NE DE kullanıcı conf'unun varlık
    # kontrolü vardı (add dalında ikisi de vardı). 'srvctl user key remove
    # ../../root' → '/home/../../root/.ssh/authorized_keys' == GERÇEKTEN
    # '/root/.ssh/authorized_keys' — sessizce (2>/dev/null) SIFIRLANIYORDU ve
    # "Tüm SSH key'ler kaldırıldı" başarı mesajı basılıyordu. Kapı artık HER
    # İKİ dal için de ortak/erken uygulanır (domain_exists'teki validate_domain
    # kapısıyla birebir aynı desen).
    validate_username "$username" || error "Geçersiz kullanıcı adı: ${username}"

    case "$action" in
        add)
            [[ -z "$pubkey" ]] && error "Kullanım: srvctl user key add <username> <pubkey_dosyası_veya_string>"
            [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

            local auth_keys="${SRVCTL_HOME_BASE}/${username}/.ssh/authorized_keys"
            # K1: dizin ve dosya sembolik bağ olamaz; dosya secure_file ile
            # (0600, -h chown, ikinci TOCTOU kapısı) oluşturulur/korunur.
            _user_ensure_ssh_dir "$username" \
                || error "GÜVENLİK: ~/.ssh sembolik bağ ya da hazırlanamadı — key EKLENMEDİ (${username})."
            _user_guard_home_path "$username" ".ssh/authorized_keys" \
                || error "GÜVENLİK: authorized_keys sembolik bağ — key EKLENMEDİ (${username})."
            secure_file "$auth_keys" 600 "${username}:${username}" \
                || error "authorized_keys güvenli oluşturulamadı: ${auth_keys}"

            # Dosya mı string mi?
            if [[ -f "$pubkey" ]]; then
                cat -- "$pubkey" >> "$auth_keys"
            else
                printf '%s\n' "$pubkey" >> "$auth_keys"
            fi

            chmod 600 "$auth_keys"
            chown -h "${username}:${username}" "$auth_keys"

            success "SSH key eklendi: ${username}"
            log_action "USER KEY ADD: ${username}"
            ;;
        remove)
            [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."
            local auth_keys_rm="${SRVCTL_HOME_BASE}/${username}/.ssh/authorized_keys"
            # K1: ': >' symlink hedefini TRUNCATE ederdi — kapı fail-closed.
            _user_guard_home_path "$username" ".ssh/authorized_keys" \
                || error "GÜVENLİK: authorized_keys sembolik bağ — SIFIRLANMADI (${username})."
            if [[ -e "$auth_keys_rm" ]]; then
                # shellcheck disable=SC2188  # kasıtlı: dosyayı sıfırlamak için no-op komut
                : > "$auth_keys_rm" || error "authorized_keys sıfırlanamadı: ${auth_keys_rm}"
            fi
            success "Tüm SSH key'ler kaldırıldı: ${username}"
            log_action "USER KEY REMOVE: ${username}"
            ;;
        *)
            error "Kullanım: srvctl user key <add|remove> <username>"
            ;;
    esac
}

_user_2fa() {
    local action="$1" username="$2"
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    # B5 sertleştirmesi — bkz. _user_grant üzerindeki gerekçe.
    validate_username "$username" || error "Geçersiz kullanıcı adı: ${username}"
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    case "$action" in
        setup)
            # google-authenticator yüklü mü?
            if ! command -v google-authenticator &>/dev/null; then
                info "libpam-google-authenticator kuruluyor..."
                apt-get install -y -qq libpam-google-authenticator > /dev/null 2>&1 || \
                    error "google-authenticator kurulamadı."
            fi

            # TOTP secret oluştur
            local secret
            secret=$(head -c 20 /dev/urandom | base32 | head -c 16)

            _user_read_conf "${SRVCTL_USERS_DIR}/${username}.conf"   # eski anahtarları göç ettir
            # KARAR 2: atomik/portable _sed_inplace (bkz. core.sh) — bu dosya
            # TWOFA_SECRET (sır) içerir, atomik yazım önemlidir.
            _sed_inplace "${SRVCTL_USERS_DIR}/${username}.conf" "s|^TWOFA_ENABLED=.*|TWOFA_ENABLED=true|"
            _sed_inplace "${SRVCTL_USERS_DIR}/${username}.conf" "s|^TWOFA_SECRET=.*|TWOFA_SECRET=${secret}|"

            # google-authenticator dosyasını oluştur
            local ga_file="${SRVCTL_HOME_BASE}/${username}/.google_authenticator"
            # K1: fallback dalı root olarak ev dizinine yazar; kapı ÖNCE gelir.
            # (Kullanıcı 'su - ... -c' adımını kendi ~/.profile'ıyla bilerek
            #  düşürüp bu dala yönlendirebilir — bu yüzden kapı fallback'e
            #  özel değil, her iki dal için ortaktır.)
            _user_guard_home_path "$username" ".google_authenticator" \
                || error "GÜVENLİK: ${ga_file} sembolik bağ — 2FA kurulumu İPTAL (${username})."
            su - "$username" -c "google-authenticator -t -d -f -r 3 -R 30 -W -s ${ga_file}" 2>/dev/null || {
                # Manuel oluştur — secure_file: 0600 + symlink kapısı + -h chown
                secure_file "$ga_file" 600 "${username}:${username}" \
                    || error "2FA dosyası güvenli oluşturulamadı: ${ga_file}"
                {
                    printf '%s\n' "${secret}"
                    printf '%s\n' '"RATE_LIMIT 3 30' '" DISALLOW_REUSE' '" TOTP_AUTH'
                } > "$ga_file"
                chmod 400 "$ga_file"
                chown -h "${username}:${username}" "$ga_file"
            }

            # PAM yapılandır
            if ! grep -q "pam_google_authenticator" /etc/pam.d/sshd 2>/dev/null; then
                echo "auth required pam_google_authenticator.so" >> /etc/pam.d/sshd
                # KARAR 2: atomik/portable _sed_inplace (bkz. core.sh) —
                # sshd_config eşzamanlı okunan sistem-geneli bir dosyadır.
                _sed_inplace /etc/ssh/sshd_config \
                    's/^ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/' 2>/dev/null || true
                systemctl restart sshd 2>/dev/null || true
            fi

            header "2FA Etkinleştirildi: ${username}"
            echo "  Secret Key:  ${secret}"
            echo ""
            echo "  Google Authenticator veya benzeri uygulamaya"
            echo "  bu secret key'i girin."
            echo ""
            echo "  veya QR kodu için:"
            echo "  otpauth://totp/srvctl:${username}?secret=${secret}&issuer=srvctl"
            echo ""

            log_action "USER 2FA SETUP: ${username}"
            ;;
        disable)
            _user_read_conf "${SRVCTL_USERS_DIR}/${username}.conf"   # eski anahtarları göç ettir
            _sed_inplace "${SRVCTL_USERS_DIR}/${username}.conf" "s|^TWOFA_ENABLED=.*|TWOFA_ENABLED=false|"
            rm -f -- "${SRVCTL_HOME_BASE}/${username}/.google_authenticator"
            success "2FA devre dışı bırakıldı: ${username}"
            log_action "USER 2FA DISABLE: ${username}"
            ;;
        *)
            error "Kullanım: srvctl user 2fa <setup|disable> <username>"
            ;;
    esac
}

_user_audit() {
    local username="$1"

    header "İşlem Geçmişi"

    if [[ -n "$username" ]]; then
        grep "\[${username}\]" "${SRVCTL_LOG}" 2>/dev/null | tail -30 || echo "  Kayıt yok"
    else
        tail -50 "${SRVCTL_LOG}" 2>/dev/null || echo "  Kayıt yok"
    fi

    echo ""
}

_update_sudoers() {
    local username="$1"
    local role="$2"
    local sudoers_file="/etc/sudoers.d/srvctl-${username}"

    case "$role" in
        admin)
            cat > "$sudoers_file" << SUDOERS
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl *
SUDOERS
            ;;
        developer)
            cat > "$sudoers_file" << SUDOERS
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl deploy *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain info *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain list
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl backup run *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl status
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl ssl status
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl monitor *
SUDOERS
            ;;
        viewer)
            cat > "$sudoers_file" << SUDOERS
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl status
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain list
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain info *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl ssl status
SUDOERS
            ;;
    esac
    chmod 440 "$sudoers_file"
}
