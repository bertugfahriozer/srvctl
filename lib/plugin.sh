#!/bin/bash
# ═══════════════════════════════════════════════
#  plugin.sh — Plugin Sistemi
#  srvctl'yi modüler olarak genişlet
# ═══════════════════════════════════════════════

SRVCTL_PLUGINS_DIR="${SRVCTL_ROOT:-/usr/local/srvctl}/plugins"

# ─── Kaynak URL doğrulama kapısı (PREDİKAT: 0=güvenli 1=güvensiz; exit YOK) ───
# DALGA 6 / O13-a bulgusu: 'git clone --depth 1 "$source"' HİÇBİR şema
# doğrulaması yapmadan çağrılıyordu — 'ext::sh -c <komut>' gibi git transport
# helper'ları doğrudan root komut çalıştırma (RCE) sağlar. Bu,
# lib/deploy.sh:_deploy_validate_repo_url'ün BİREBİR KOPYASIDIR (aynı tehdit
# modeli: ext::/fd::/file:: transport, baştaki '-' option-injection, boşluk,
# '::'). İDEAL çözüm bu predikatı core.sh'a taşımaktır (tüm modüllerin ortak
# kapısı olsun) — core.sh bu dosyanın SAHİBİ OLMADIĞIMIZDAN burada KOPYA
# tutuluyor; bkz. rapor "devredilen iş".
_plugin_validate_source() {
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

# ─── Plugin adı doğrulama (PREDİKAT: 0=güvenli 1=güvensiz) ───
# 'basename <url> .git' güvenilmez girdiden path traversal üretebilir: ör.
# 'srvctl plugin install https://evil.example/foo/..' → plugin_name='..' →
# "${SRVCTL_PLUGINS_DIR}/.." SRVCTL_ROOT'un KENDİSİNE eşitlenir; sonraki
# 'rm -rf'/'mkdir -p'/'chown -R' çağrıları SRVCTL_ROOT'u hedef alır. '/' veya
# '..' bileşeni ya da baştaki '.' reddedilir (isim yalnız dizin BİLEŞENİ
# olarak kullanılmalı).
_plugin_valid_name() {
    local n="$1"
    [[ -n "$n" ]] || return 1
    [[ "$n" == *".."* ]] && return 1
    [[ "$n" == */* ]] && return 1
    [[ "$n" == "."* ]] && return 1
    return 0
}

cmd_plugin() {
    case "${1:-help}" in
        install)  _plugin_install "${@:2}" ;;
        remove)   _plugin_remove "${@:2}" ;;
        list)     _plugin_list ;;
        enable)   _plugin_enable "${@:2}" ;;
        disable)  _plugin_disable "${@:2}" ;;
        create)   _plugin_create "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl plugin <install|remove|list|enable|disable|create>"
            echo ""
            echo "    install <git_url>       Plugin kur (git repo)"
            echo "    remove <isim>           Plugin kaldır"
            echo "    list                    Yüklü plugin'leri listele"
            echo "    enable <isim>           Plugin'i aktifleştir"
            echo "    disable <isim>          Plugin'i devre dışı bırak"
            echo "    create <isim>           Yeni plugin iskeleti oluştur"
            echo ""
            ;;
    esac
}

_plugin_install() {
    require_root
    local source="$1"
    [[ -z "$source" ]] && error "Git URL veya plugin dizini belirtilmedi."

    # Plugin dizinini root:root 755 olarak güvenli kur (dünyaya yazılabilir
    # bir dizinde 'git clone'un hedefi olmasın).
    secure_dir "${SRVCTL_PLUGINS_DIR}" 755

    local plugin_name
    plugin_name=$(basename "$source" .git)
    _plugin_valid_name "$plugin_name" \
        || error "Kaynaktan güvenli bir plugin adı türetilemedi: '${plugin_name}'"

    if [[ -d "${SRVCTL_PLUGINS_DIR}/${plugin_name}" ]]; then
        error "Plugin zaten yüklü: ${plugin_name}"
    fi

    step "1/3" "Plugin indiriliyor: ${plugin_name}"

    if [[ -d "$source" ]]; then
        cp -r -- "$source" "${SRVCTL_PLUGINS_DIR}/${plugin_name}"
    else
        # O13-a: yalnız https://, ssh://, git@host:path — 'ext::'/'file::' gibi
        # git transport helper'ları (RCE) ve option-injection reddedilir.
        _plugin_validate_source "$source" \
            || error "Güvensiz/desteklenmeyen kaynak: ${source} (yalnız https://, ssh://, git@host:path kabul edilir)"
        GIT_ALLOW_PROTOCOL='https:ssh:git' git clone --depth 1 -- "$source" "${SRVCTL_PLUGINS_DIR}/${plugin_name}" 2>/dev/null || \
            error "Plugin indirilemedi: ${source}"
    fi

    # Klonlanan/kopyalanan ağacı kökten itibaren root'a sabitle ve
    # grup/diğer-yazılabilir bitlerini temizle — kaynak depo dünyaya-yazılabilir
    # mod bitleriyle gelmiş olabilir ('cp -r'/'git clone' kaynağın izin
    # bitlerini kısmen taşıyabilir). Root 'source' ÖNCESİ bu satır olmadan
    # assert_root_owned_path aşağıda zaten reddedecekti; burada PROAKTİF düzeltiyoruz.
    chown -R root:root "${SRVCTL_PLUGINS_DIR}/${plugin_name}" 2>/dev/null || true
    chmod -R go-w "${SRVCTL_PLUGINS_DIR}/${plugin_name}" 2>/dev/null || true

    # Manifest kontrol
    if [[ ! -f "${SRVCTL_PLUGINS_DIR}/${plugin_name}/plugin.conf" ]]; then
        rm -rf -- "${SRVCTL_PLUGINS_DIR:?}/${plugin_name}"
        error "Geçersiz plugin: plugin.conf bulunamadı"
    fi

    step "2/3" "Plugin doğrulanıyor..."

    # O13-b: root 'source' ÖNCESİ sahiplik/izin kapısı (fail-closed).
    assert_root_owned_path "${SRVCTL_PLUGINS_DIR}/${plugin_name}/plugin.conf" \
        || { rm -rf -- "${SRVCTL_PLUGINS_DIR:?}/${plugin_name}"; error "Plugin reddedildi: plugin.conf sahipliği/izinleri güvenilmez"; }

    # plugin.conf oku
    # shellcheck disable=SC1090
    source "${SRVCTL_PLUGINS_DIR}/${plugin_name}/plugin.conf"

    # Hook script'leri kontrol et
    local main_script="${SRVCTL_PLUGINS_DIR}/${plugin_name}/main.sh"
    if [[ -f "$main_script" ]]; then
        assert_root_owned_path "$main_script" \
            || { rm -rf -- "${SRVCTL_PLUGINS_DIR:?}/${plugin_name}"; error "Plugin reddedildi: main.sh sahipliği/izinleri güvenilmez"; }
        bash -n "$main_script" 2>/dev/null || {
            rm -rf -- "${SRVCTL_PLUGINS_DIR:?}/${plugin_name}"
            error "Plugin syntax hatası: main.sh"
        }
    fi

    step "3/3" "Plugin aktifleştiriliyor..."

    # Aktif olarak işaretle
    touch "${SRVCTL_PLUGINS_DIR}/${plugin_name}/.enabled"
    chown root:root "${SRVCTL_PLUGINS_DIR}/${plugin_name}/.enabled" 2>/dev/null || true

    # Install hook varsa çalıştır — root ÇALIŞTIRMA ÖNCESİ sahiplik kapısı.
    local install_hook="${SRVCTL_PLUGINS_DIR}/${plugin_name}/hooks/install.sh"
    if [[ -f "$install_hook" ]]; then
        if assert_root_owned_path "$install_hook"; then
            bash "$install_hook" 2>/dev/null || true
        else
            warn "install.sh çalıştırılmadı: sahiplik/izin güvenilmez (${install_hook})"
        fi
    fi

    success "Plugin yüklendi: ${plugin_name}"
    echo "  Versiyon:    ${PLUGIN_VERSION:-1.0.0}"
    echo "  Açıklama:    ${PLUGIN_DESCRIPTION:-Belirtilmemiş}"
    echo "  Komut:       srvctl ${plugin_name}"
    echo ""

    log_action "PLUGIN INSTALL: ${plugin_name}"
}

_plugin_remove() {
    require_root
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    _plugin_valid_name "$name" || error "Geçersiz plugin adı: ${name}"
    [[ ! -d "${SRVCTL_PLUGINS_DIR}/${name}" ]] && error "Plugin bulunamadı: ${name}"

    confirm "Plugin silinecek: ${name}. Devam?" || return 0

    # Uninstall hook — root ÇALIŞTIRMA ÖNCESİ sahiplik kapısı (O13-b).
    local uninstall_hook="${SRVCTL_PLUGINS_DIR}/${name}/hooks/uninstall.sh"
    if [[ -f "$uninstall_hook" ]]; then
        if assert_root_owned_path "$uninstall_hook"; then
            bash "$uninstall_hook" 2>/dev/null || true
        else
            warn "uninstall.sh çalıştırılmadı: sahiplik/izin güvenilmez (${uninstall_hook})"
        fi
    fi

    rm -rf -- "${SRVCTL_PLUGINS_DIR:?}/${name}"
    success "Plugin kaldırıldı: ${name}"
    log_action "PLUGIN REMOVE: ${name}"
}

_plugin_list() {
    header "Yüklü Plugin'ler"

    printf "  ${DIM}%-20s %-10s %-8s %-35s${NC}\n" "İSİM" "VERSİYON" "DURUM" "AÇIKLAMA"
    divider

    local count=0
    for plugin_dir in "${SRVCTL_PLUGINS_DIR}"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        local name
        name=$(basename "$plugin_dir")

        local version="?" description="?" status_text

        if [[ -f "${plugin_dir}/plugin.conf" ]]; then
            # O13-b: 'source' ÖNCESİ sahiplik kapısı — sahipliği/izinleri
            # bozuk bir plugin.conf sessizce OKUNMAZ, görünür şekilde
            # işaretlenir (bkz. rapor).
            if assert_root_owned_path "${plugin_dir}/plugin.conf"; then
                # Önceki yinelemeden kalan PLUGIN_VERSION/PLUGIN_DESCRIPTION
                # değerlerinin bu yinelemeye SIZMAMASI için sıfırla.
                unset PLUGIN_VERSION PLUGIN_DESCRIPTION
                # shellcheck disable=SC1090
                source "${plugin_dir}/plugin.conf"
                version="${PLUGIN_VERSION:-?}"
                description="${PLUGIN_DESCRIPTION:-?}"
            else
                description="(sahiplik güvenilmez — okunmadı)"
            fi
        fi

        if [[ -f "${plugin_dir}/.enabled" ]]; then
            status_text="${GREEN}aktif${NC}"
        else
            status_text="${DIM}kapalı${NC}"
        fi

        printf "  %-20s %-10s %-8b %-35s\n" "$name" "$version" "$status_text" "$description"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  Henüz plugin yüklenmemiş."
    fi

    divider
    echo "  Toplam: ${count} plugin"
    echo ""
}

_plugin_enable() {
    # Mutasyon: bu marker load_plugins() tarafından her srvctl çağrısında
    # KOŞULSUZ root olarak source edilecek main.sh'ı belirler — root
    # gerektirmeden değiştirilebilirse yetki yükseltme yoludur (O13-b).
    require_root
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    _plugin_valid_name "$name" || error "Geçersiz plugin adı: ${name}"
    [[ ! -d "${SRVCTL_PLUGINS_DIR}/${name}" ]] && error "Plugin bulunamadı."

    touch "${SRVCTL_PLUGINS_DIR}/${name}/.enabled"
    chown root:root "${SRVCTL_PLUGINS_DIR}/${name}/.enabled" 2>/dev/null || true
    success "Plugin aktifleştirildi: ${name}"
}

_plugin_disable() {
    require_root
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    _plugin_valid_name "$name" || error "Geçersiz plugin adı: ${name}"
    [[ ! -d "${SRVCTL_PLUGINS_DIR}/${name}" ]] && error "Plugin bulunamadı."

    rm -f -- "${SRVCTL_PLUGINS_DIR}/${name}/.enabled"
    success "Plugin devre dışı bırakıldı: ${name}"
}

_plugin_create() {
    require_root
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    _plugin_valid_name "$name" || error "Geçersiz plugin adı: ${name} ('/' veya '..' içeremez, '.' ile başlayamaz)"

    local dir="${SRVCTL_PLUGINS_DIR}/${name}"
    secure_dir "${SRVCTL_PLUGINS_DIR}" 755
    ( umask 022; mkdir -p "${dir}/hooks" )
    chown -R root:root "${dir}" 2>/dev/null || true

    # plugin.conf
    cat > "${dir}/plugin.conf" << CONF
PLUGIN_NAME="${name}"
PLUGIN_VERSION="1.0.0"
PLUGIN_DESCRIPTION="Yeni plugin açıklaması"
PLUGIN_AUTHOR="$(whoami)"
PLUGIN_COMMANDS="${name}"
CONF

    # main.sh
    cat > "${dir}/main.sh" << 'MAIN'
#!/bin/bash
# Plugin ana modülü

cmd_PLUGIN_NAME() {
    case "${1:-help}" in
        hello)
            echo "  Merhaba, plugin çalışıyor!"
            ;;
        *)
            echo ""
            echo "  Kullanım: srvctl PLUGIN_NAME <hello>"
            echo ""
            ;;
    esac
}
MAIN
    _sed_inplace "${dir}/main.sh" -e "s/PLUGIN_NAME/${name}/g" \
        || error "Plugin şablonu oluşturulamadı: ${dir}/main.sh"

    # install/uninstall hooks
    echo '#!/bin/bash' > "${dir}/hooks/install.sh"
    echo '# Kurulum sonrası çalışır' >> "${dir}/hooks/install.sh"
    echo '#!/bin/bash' > "${dir}/hooks/uninstall.sh"
    echo '# Kaldırma öncesi çalışır' >> "${dir}/hooks/uninstall.sh"

    chmod +x "${dir}/main.sh" "${dir}/hooks/"*.sh

    success "Plugin iskeleti oluşturuldu: ${dir}"
    echo ""
    echo "  Düzenleyin: nano ${dir}/main.sh"
    echo "  Etkinleştirin: srvctl plugin enable ${name}"
    echo ""
}

# ─── Plugin Loader (bin/srvctl tarafından HER çağrıda çağrılır) ───
# DİKKAT (rapor): bin/srvctl:27 bunu 'load_plugins 2>/dev/null || true' ile
# çağırıyor — bu satır BENİM DOSYAM DEĞİL, düzeltemiyorum. Bu redirect fonksiyonun
# TÜM stderr çıktısını (dolayısıyla aşağıdaki warn() çağrılarını) yutar; yani
# reddedilen bir plugin burada TERMİNALDE görünmez. log_action() DOSYAYA
# doğrudan yazdığından bu redirect'ten ETKİLENMEZ — reddedilen plugin en
# azından denetim izinde kalıcı olarak görünür. Gerçek düzeltme (bin/srvctl'in
# '2>/dev/null'ı kaldırması ya da log'a yönlendirmesi) devredilen iştir.
load_plugins() {
    [[ ! -d "$SRVCTL_PLUGINS_DIR" ]] && return

    for plugin_dir in "${SRVCTL_PLUGINS_DIR}"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        [[ ! -f "${plugin_dir}/.enabled" ]] && continue
        [[ ! -f "${plugin_dir}/main.sh" ]] && continue

        # O13-b: root 'source' ÖNCESİ sahiplik/izin kapısı (fail-closed) —
        # sahipliği bozuk bir plugin sessizce ATLANMAZ, görünür şekilde reddedilir.
        if ! assert_root_owned_path "${plugin_dir}/main.sh"; then
            log_action "PLUGIN REDDEDİLDİ (sahiplik/izin güvenilmez, root olarak source EDİLMEDİ): ${plugin_dir}"
            warn "Plugin reddedildi (sahiplik/izin güvenilmez): ${plugin_dir}"
            continue
        fi

        # shellcheck disable=SC1090
        source "${plugin_dir}/main.sh"
    done
}
