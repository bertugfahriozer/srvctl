#!/bin/bash
# ═══════════════════════════════════════════════
#  domconf.sh — Per-domain yapılandırma düzenleme ve reload
#
#  Bu modül KULLANICI ARAYÜZÜNÜ sahiplenir (editör, doğrulama, tarama,
#  rollback, reload tetikleme). Override'ların pool config'ine BASILMASI
#  render zincirinin parçasıdır ve lib/domain.sh'ta kalır
#  (_domain_render_php_overrides) — böylece repair/php-switch/harden-fpm
#  gibi pool'u yeniden üreten HER yol override'ları bedavaya uygular.
#
#  cmd_domain tarafından _domain_load_conf_lib ile source edilir.
#
#  FM bölümü (fm-auth / fm-root / acil kapatma): bir alanın /_fm yolunu açan 20/21/90 dosyalarının (custom.d) yazımı, köken
#  kaydı ve kurtarması. DEĞİŞMEZ: otomatik yollar (repair, toplu repair, fm-root, fm-root --all, php-switch, 403 kökü kurulumu,
#  yarım işlem kurtarması, açma geri alması) bir alanı ASLA açmaz; yalnız kapatma yönünde değiştirir. Alanı yalnız açık
#  'srvctl domain fm-auth <alan> on --script=…' açar. Kayıt 'on' ve 20/21/90'ın ÜÇÜ DE tanınan srvctl eseri ise alan "açık" korunur;
#  aksi hâlde kayıt 'off' sayılır. Kayıt sınıfları (_fmprov_load → _FMP_EMERGENCY): 0 normal | 1 acil kapatma işareti var |
#  2 işaret yok, diskte srvctl'in 403 kökü KANITI var | 3 kapalı GÖRÜNÜMLÜ kök (kanıt değil) | 4 kayıt 'on' ama üç eserden biri
#  eksik/kurcalanmış/tanınmıyor. 1–4'te kayıt 'off' sayılır ve alan 403 köküne kapatılır (sessiz yeniden üretim yok).
# ═══════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  srvctl domain reload <domain>|--all [--fpm|--nginx]
#
#  nginx TEK bir master process'tir — domain başına nginx reload diye bir şey
#  YOKTUR. Bu yüzden '--all' akışında nginx BİR KEZ reload edilir.
#
#  '--all' HATADA DURMAZ: 100 domainli bir sunucuda tek bozuk domain, 99
#  sağlıklı domaini reload edilmemiş bırakmamalı. Başarısızlar sonda
#  özetlenir ve komut non-zero döner.
# ───────────────────────────────────────────────────────────────
_domconf_reload() {
    local target="" do_fpm=1 do_nginx=1 arg
    for arg in "$@"; do
        case "$arg" in
            --all)    target="--all" ;;
            --fpm)    do_nginx=0 ;;
            --nginx)  do_fpm=0 ;;
            -*)       error "Bilinmeyen seçenek: ${arg} (kullanım: srvctl domain reload <domain>|--all [--fpm|--nginx])" ;;
            *)        target="$arg" ;;
        esac
    done
    [[ -z "$target" ]] && error "Kullanım: srvctl domain reload <domain>|--all [--fpm|--nginx]"

    local -a domains=()
    local d
    if [[ "$target" == "--all" ]]; then
        while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(list_all_domains)
        [[ ${#domains[@]} -eq 0 ]] && { info "Reload edilecek domain yok."; return 0; }
    else
        domain_exists "$target" || error "Domain bulunamadı: ${target}"
        domains=("$target")
    fi

    local -a failed=()
    local sname php_ver unit
    if [[ "$do_fpm" == "1" ]]; then
        for d in "${domains[@]}"; do
            sname=$(safe_name "$d")
            php_ver=$(_derive_php "$d" "${DEFAULT_PHP_VERSION}")
            unit=$(domain_fpm_unit "$sname" "$php_ver")
            if reload_domain_fpm "$sname" "$php_ver"; then
                success "FPM reload: ${d} (${unit})"
            else
                failed+=("$d")
                warn "FPM reload BAŞARISIZ: ${d} — systemctl status ${unit}"
            fi
        done
    fi

    local nginx_failed=0
    if [[ "$do_nginx" == "1" ]]; then
        # nginx_test() BAŞARISIZLIKTA EXIT EDER — burada döngü sonrası özet
        # basmamız gerektiği için doğrudan 'nginx -t' çağrılıyor.
        if nginx -t >/dev/null 2>&1; then
            if systemctl reload nginx >/dev/null 2>&1; then
                success "nginx reload edildi"
            else
                warn "nginx reload başarısız"
                nginx_failed=1
            fi
        else
            warn "nginx -t BAŞARISIZ — nginx reload EDİLMEDİ. 'nginx -t' ile hatayı görün."
            nginx_failed=1
        fi
    fi

    log_action "DOMAIN RELOAD: ${target} (fpm=${do_fpm} nginx=${do_nginx} başarısız=${#failed[@]})"

    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Reload edilemeyen domainler (${#failed[@]}): ${failed[*]}"
        return 1
    fi
    [[ "$nginx_failed" == "1" ]] && return 1
    return 0
}

# domain.sh'ı talep üzerine yükler (lib/security.sh'ın _security_load_domain_lib
# deseniyle aynı). PRATİKTE domain.sh zaten yüklüdür — bu modül yalnız
# cmd_domain'in case bloğundan çağrılır — ama guard'sız bırakmak modülü tek
# başına source eden her tüketiciyi (testler dahil) exit 127 ile düşürürdü.
# İki yönlü source döngüsü guard'lar sayesinde oluşmaz: her iki taraf da önce
# 'declare -F' ile karşı tarafın yüklü olup olmadığına bakar.
_domconf_load_domain_lib() {
    declare -F _domain_render_fpm_unit >/dev/null 2>&1 && return 0
    # shellcheck disable=SC1091
    source "${SRVCTL_ROOT}/lib/domain.sh" || return 1
}

# Bildirim gönderir (kanal yapılandırılmamışsa sessizce geçer).
#
# İKİ TUZAK BURADA KAPATILIYOR:
#  1) send_notification'ın imzası '(başlık, mesaj, [seviye])' — TEK argümanla
#     çağırmak 'set -u' altında '$2: unbound variable' ile PATLAR. Bu, --force
#     yolunu her kullanımda düşürürdü.
#  2) notify.sh KOŞULSUZ source edilirse, çağıranın (ör. testlerin) kendi
#     tanımladığı send_notification'ı EZER. Yalnız fonksiyon henüz yoksa yükle.
_domconf_notify() {
    local title="$1" message="$2"
    if ! declare -F send_notification >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || return 0
    fi
    declare -F send_notification >/dev/null 2>&1 || return 0
    send_notification "$title" "$message" "warning" || true
}

# ───────────────────────────────────────────────────────────────
#  Reddedilen PHP ini anahtarları — izolasyonu DELEN ayarlar.
#  "Ayağına sıkma" kategorisi (display_errors vb.) BİLİNÇLİ OLARAK
#  listede DEĞİL; buradaki ölçüt "srvctl'in güvenlik modelini deler mi".
# ───────────────────────────────────────────────────────────────
_DOMCONF_INI_DENY=(
    extension zend_extension
    open_basedir disable_functions disable_classes
    sendmail_path
    allow_url_fopen allow_url_include
    cgi.fix_pathinfo
)

_domconf_ini_deny_reason() {
    case "$1" in
        extension|zend_extension)
            echo "FPM master ROOT olarak başlar — keyfi .so yükleme = root kod çalıştırma" ;;
        open_basedir)
            echo "chroot içi dosya erişim sınırını gevşetir (tek istisna: 'open_basedir = off' — ayarı gevşetmez, tamamen kaldırıp sınırı chroot'a bırakır; 'srvctl domain open-basedir <domain> off')" ;;
        disable_functions|disable_classes)
            echo "hardening listesini gevşetir (bkz. pool.conf.tpl BUG 2 notu)" ;;
        sendmail_path)
            echo "mail() üzerinden komut çalıştırma — pool bu anahtarı set ETMİYOR" ;;
        allow_url_fopen|allow_url_include)
            echo "RFI/SSRF" ;;
        cgi.fix_pathinfo)
            echo "klasik PHP-FPM arbitrary-exec vektörü" ;;
        *)  echo "izolasyon politikası" ;;
    esac
}

# PREDİKAT: 0=temiz, 1=reddedilen anahtar bulundu (rapor stdout'a).
#
# Tarama ANAHTAR bazlıdır, TEK bir DEĞER-farkında istisna dışında:
# 'open_basedir = off'. Bu istisna izolasyonu GEVŞETMEZ — ayarı tamamen
# kaldırır ve dosya erişim sınırını pool'un ZATEN uyguladığı
# 'chroot = WEB_ROOT/DOMAIN'e bırakır (chroot open_basedir'den daha güçlü bir
# sınırdır; ayrıntılı gerekçe ve ölçüm: lib/domain.sh
# _domain_render_php_overrides başlık yorumu). Bu yüzden --force İSTEMEZ.
# Başka HER open_basedir değeri (ör. listeye yeni bir yol eklemek) reddedilmeye
# DEVAM EDER: o gerçek bir gevşetmedir.
_domconf_scan_ini() {
    local file="$1"
    local line key val deny lineno=0 found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*[\;\#] ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        [[ "$key" == "open_basedir" && "$val" == "off" ]] && continue
        for deny in "${_DOMCONF_INI_DENY[@]}"; do
            if [[ "$key" == "$deny" ]]; then
                echo "    satır ${lineno}: ${key} — $(_domconf_ini_deny_reason "$key")"
                found=1
            fi
        done
    done < "$file"
    return $found
}

# php-fpm config testi — AYRI fonksiyon, testte mock'lanabilsin diye.
# PREDİKAT: 0=geçerli. php-fpm binary yoksa test ATLANIR (0 döner) — macOS
# geliştirme ortamında ve php-fpm kurulu olmayan host'ta komut kilitlenmesin.
_domconf_fpm_config_test() {
    local php_version="$1" conf="$2"
    local bin="/usr/sbin/php-fpm${php_version}"
    [[ -x "$bin" ]] || { warn "php-fpm binary yok: ${bin} — config testi atlandı"; return 0; }
    local err
    if ! err=$("$bin" --fpm-config "$conf" -t 2>&1); then
        warn "FPM config testi başarısız: ${conf}"
        # Çıktı YUTULMAZ: _domain_activate_fpm_unit'te bunun tersi bir
        # regresyon yaşandı ve php-fpm'in asıl hata satırı operatörden
        # gizlenmişti (bkz. o fonksiyonun başlık yorumu).
        [[ -n "$err" ]] && echo "$err" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

_domconf_ini_skeleton() {
    local domain="$1"
    cat <<EOF
; ═══════════════════════════════════════════════
;  srvctl per-domain PHP ayarları — ${domain}
; ═══════════════════════════════════════════════
;
; Buradaki satırlar FPM pool config'ine 'php_admin_value[...]' olarak
; enjekte edilir ve ŞABLONDAKİ aynı isimli ayarı EZER.
; Bu dosya render'ın DIŞINDADIR: 'domain repair', 'php-switch' ve
; 'security harden-fpm' onu EZMEZ, her seferinde yeniden uygular.
;
; Düzenleyip kaydettiğinizde srvctl doğrular ve FPM'i kendisi reload eder.
; Dosyayı elle değiştirdiyseniz:  srvctl domain reload ${domain}
;
; ─── Sık kullanılan ayarlar (yorumu kaldırıp değiştirin) ───
; memory_limit = 512M
; max_execution_time = 120
; max_input_time = 120
; upload_max_filesize = 100M
; post_max_size = 105M
; max_input_vars = 10000
; opcache.memory_consumption = 256
;
; ─── REDDEDİLEN anahtarlar (--force olmadan uygulanmaz) ───
;   extension, zend_extension  → FPM master ROOT'tur, keyfi .so = root RCE
;   open_basedir               → chroot içi erişim sınırını gevşetir
;   disable_functions          → hardening listesini gevşetir
;   sendmail_path              → mail() üzerinden komut çalıştırma
;   allow_url_fopen/_include   → RFI/SSRF
;   cgi.fix_pathinfo           → PHP-FPM arbitrary-exec vektörü
;
; Biçim: 'anahtar = değer'. [section] başlığı ve çok satırlı değer YOKTUR.
EOF
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain ini <domain> [--show] [--file <path>] [--force]
#
#  ROLLBACK BÜTÜNLÜĞÜ: doğrulama başarısız olduğunda yalnız .ini değil,
#  ondan TÜRETİLMİŞ pool da eski haline döner. Aksi halde bozuk pool
#  diskte kalır ve bir sonraki 'repair'/reload onu CANLIYA ALIR — hata,
#  kendisini tetikleyen komuttan çok sonra patlar.
# ───────────────────────────────────────────────────────────────
_domconf_edit_ini() {
    local domain="" src_file="" show=0 force=0 arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --show)   show=1 ;;
            --force)  force=1 ;;
            --file)   shift; src_file="${1:-}"; [[ -n "$src_file" ]] || error "--file bir yol gerektirir" ;;
            --file=*) src_file="${arg#--file=}" ;;
            -*)       error "Bilinmeyen seçenek: ${arg}" ;;
            *)        domain="$arg" ;;
        esac
        shift
    done
    [[ -n "$domain" ]] || error "Kullanım: srvctl domain ini <domain> [--show] [--file <yol>] [--force]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local ini_dir="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}"
    local ini="${ini_dir}/${sname}.ini"
    mkdir -p "$ini_dir"
    [[ -f "$ini" ]] || { _domconf_ini_skeleton "$domain" > "$ini"; chmod 644 "$ini"; }

    if [[ "$show" == "1" ]]; then
        cat "$ini"
        return 0
    fi

    # ─── Aday içeriği elde et ───
    local cand; cand=$(mktemp)
    # Düşük (denetim 2026-09): 'error' (exit) ya da Ctrl+C ile kesintide aday/
    # yedek dosya /tmp'te kalmasın (M8 deseni: EXIT tek başına INT'i garanti etmez).
    trap 'rm -f -- "${cand:-}" "${backup:-}"' EXIT
    trap 'rm -f -- "${cand:-}" "${backup:-}"; exit 130' INT TERM
    if [[ -n "$src_file" ]]; then
        [[ -f "$src_file" ]] || { rm -f "$cand"; error "Dosya bulunamadı: ${src_file}"; }
        cp "$src_file" "$cand"
    else
        cp "$ini" "$cand"
        # NOT: 'sudo' varsayılan olarak env_reset uygular ve $EDITOR'ü TEMİZLER.
        # 'sudo srvctl domain ini <d>' bu yüzden nano açar; operatörün kendi
        # editörü için 'sudo -E' gerekir (README'de belgelendi).
        "${EDITOR:-nano}" "$cand" || { rm -f "$cand"; error "Editör hata döndürdü — değişiklik uygulanmadı"; }
    fi

    if cmp -s "$cand" "$ini"; then
        rm -f "$cand"
        info "Değişiklik yok — hiçbir şey yapılmadı."
        return 0
    fi

    # ─── Doğrulama: sözdizimi ───
    if ! parse_php_ini_overrides "$cand" >/dev/null; then
        rm -f "$cand"
        error "Sözdizimi hatası — değişiklik UYGULANMADI (yukarıdaki satırı düzeltin)"
    fi

    # ─── Doğrulama: reddedilen anahtarlar ───
    local findings
    if ! findings=$(_domconf_scan_ini "$cand"); then
        if [[ "$force" != "1" ]]; then
            rm -f "$cand"
            warn "REDDEDİLDİ — izolasyonu delen ayar(lar):"
            echo "$findings" >&2
            error "Değişiklik UYGULANMADI. Bilerek yapıyorsanız: srvctl domain ini ${domain} --force"
        fi
        warn "UYARI: izolasyon override edildi (--force) — ${domain}"
        echo "$findings" >&2
        log_action "DOMAIN INI --force: ${domain} — izolasyon override edildi"
        _domconf_notify "srvctl: izolasyon override (${domain})" \
            "PHP ini dosyasında izolasyonu delen bir ayar --force ile uygulandı: ${domain}"
    fi

    # ─── Uygula (yedekle → yerleştir → render → test) ───
    local backup; backup=$(mktemp)
    trap 'rm -f -- "${cand:-}" "${backup:-}"' EXIT
    trap 'rm -f -- "${cand:-}" "${backup:-}"; exit 130' INT TERM
    cp "$ini" "$backup"
    cat "$cand" > "$ini"
    chmod 644 "$ini"
    rm -f "$cand"

    local php_ver; php_ver=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    local pool="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"

    _domconf_load_domain_lib || error "domain modülü yüklenemedi — pool render edilemiyor"

    if ! _domain_render_fpm_unit "$domain" "$php_ver"; then
        cat "$backup" > "$ini"; rm -f "$backup"
        _domain_render_fpm_unit "$domain" "$php_ver" || true
        error "Pool render başarısız — .ini ve pool eski haline döndürüldü"
    fi

    if ! _domconf_fpm_config_test "$php_ver" "$pool"; then
        cat "$backup" > "$ini"; rm -f "$backup"
        _domain_render_fpm_unit "$domain" "$php_ver" || true
        error "php-fpm config testi başarısız — .ini VE pool eski haline döndürüldü, reload YAPILMADI"
    fi
    rm -f "$backup"

    local unit; unit=$(domain_fpm_unit "$sname" "$php_ver")
    reload_domain_fpm "$sname" "$php_ver" \
        || error "${unit} reload/restart başarısız — config GEÇERLİ, sorun servis katmanında. systemctl status ${unit}"

    success "PHP ayarları uygulandı ve FPM reload edildi: ${domain}"
    log_action "DOMAIN INI: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain open-basedir <domain>|--all <on|off> [--show]
#
#  NE YAPAR: pool'daki 'php_admin_value[open_basedir]' satırını per-domain
#  .ini üzerinden AÇAR/KAPATIR. Kapatmak ayarı GEVŞETMEZ, TAMAMEN KALDIRIR —
#  dosya erişim sınırı pool'un zaten uyguladığı 'chroot = WEB_ROOT/DOMAIN'e
#  kalır (chroot daha güçlü bir sınırdır).
#
#  NEDEN AYRI BİR KOMUT: 'off' değeri .ini'ye elle de yazılabilir, ama üç
#  tuzağı vardır ve bu komut üçünü de kapatır:
#    1) 'none' YAZILAMAZ — PHP'de özel değer değildir, 'none' ADLI göreli bir
#       dizin sanılır ve tüm dosya erişimi kırılır.
#    2) BOŞ değer YAZILAMAZ — parse_php_ini_overrides boş değeri reddeder
#       (lib/core.sh, "değer boş" hatası).
#    3) '/' de İŞE YARAMAZ — boş olmayan HERHANGİ bir değer PHP'ye ayarı
#       "set edilmiş" saydırır ve realpath cache kapalı kalır; kazanç sıfır.
#
#  VARSAYILAN DEĞİŞMEDİ: hiçbir domain bu komut çağrılmadan etkilenmez.
#  Ayar .ini'de saklandığı için 'repair'/'php-switch'/'harden-fpm' EZMEZ.
# ───────────────────────────────────────────────────────────────

# PREDİKAT: 0 = bu domainde open_basedir KAPALI (.ini'de 'off' beyanı var).
_domconf_open_basedir_is_off() {
    local ini="$1"
    [[ -f "$ini" ]] || return 1
    grep -qE '^[[:space:]]*open_basedir[[:space:]]*=[[:space:]]*off[[:space:]]*$' "$ini"
}

_domconf_open_basedir_show_one() {
    local domain="$1"
    local sname; sname=$(safe_name "$domain")
    local ini="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}/${sname}.ini"
    local pool="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"
    local beyan="on" pool_satiri="YOK"
    _domconf_open_basedir_is_off "$ini" && beyan="off"
    # Yürürlükteki GERÇEK durum pool'dur; .ini beyanı ile pool ayrışmışsa
    # (ör. .ini elle düzenlenmiş ama reload edilmemiş) operatör bunu görmeli.
    grep -qE '^php_admin_value\[open_basedir\][[:space:]]*=' "$pool" 2>/dev/null && pool_satiri="VAR"
    printf '  %-38s beyan=%-3s  pool_satiri=%s\n' "$domain" "$beyan" "$pool_satiri"
}

# Tek domaine uygular. Hata durumunda 'error' ile çıkar (çağıran --all
# döngüsü bu yüzden subshell kullanır — bir domainin hatası diğerlerini
# durdurmasın, 'domain reload --all' deseniyle aynı).
_domconf_open_basedir_one() {
    local domain="$1" state="$2"
    local sname; sname=$(safe_name "$domain")
    local ini_dir="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}"
    local ini="${ini_dir}/${sname}.ini"
    mkdir -p "$ini_dir"
    [[ -f "$ini" ]] || { _domconf_ini_skeleton "$domain" > "$ini"; chmod 644 "$ini"; }

    # Mevcut .ini KORUNUR; yalnız open_basedir satırı çıkarılır/eklenir.
    local cand; cand=$(mktemp)
    # Düşük (denetim 2026-09): 'error' (exit) ya da Ctrl+C ile kesintide aday/
    # yedek dosya /tmp'te kalmasın (M8 deseni: EXIT tek başına INT'i garanti etmez).
    trap 'rm -f -- "${cand:-}" "${backup:-}"' EXIT
    trap 'rm -f -- "${cand:-}" "${backup:-}"; exit 130' INT TERM
    grep -vE '^[[:space:]]*open_basedir[[:space:]]*=' "$ini" > "$cand" || true
    [[ "$state" == "off" ]] && printf 'open_basedir = off\n' >> "$cand"

    if cmp -s "$cand" "$ini"; then
        rm -f "$cand"
        info "${domain}: open_basedir zaten '${state}' — değişiklik yok"
        return 0
    fi

    # Doğrulama + render + php-fpm -t + reload + rollback: hepsi _domconf_edit_ini'de.
    # Yeniden yazmıyoruz — o yol rollback bütünlüğü için zaten tek doğru yer.
    _domconf_edit_ini "$domain" --file "$cand"
    rm -f "$cand"
    log_action "DOMAIN OPEN-BASEDIR: ${domain} → ${state}"
}

_domconf_open_basedir() {
    local domain="" state="" show=0 all=0 arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --show)  show=1 ;;
            --all)   all=1 ;;
            on|off)  state="$arg" ;;
            -*)      error "Bilinmeyen seçenek: ${arg}" ;;
            *)       domain="$arg" ;;
        esac
        shift
    done

    if [[ "$show" == "1" ]]; then
        header "open_basedir durumu"
        echo ""
        if [[ "$all" == "1" || -z "$domain" ]]; then
            local d
            while IFS= read -r d; do
                [[ -n "$d" ]] || continue
                _domconf_open_basedir_show_one "$d"
            done < <(list_all_domains)
        else
            domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
            _domconf_open_basedir_show_one "$domain"
        fi
        echo ""
        echo "  beyan=off  → pool'da open_basedir satırı BASILMAZ, sınır chroot'tur"
        echo "  beyan=on   → şablon varsayılanı yürürlükte (değişiklik yapılmamış)"
        echo ""
        return 0
    fi

    [[ "$state" == "on" || "$state" == "off" ]] \
        || error "Kullanım: srvctl domain open-basedir <domain>|--all <on|off> [--show]"

    if [[ "$all" == "1" ]]; then
        # Ad NOTU: 'failed' bu dosyada başka bir fonksiyonda DİZİ olarak
        # kullanılıyor; aynı adı burada skaler olarak kullanmak shellcheck
        # SC2178/SC2128 üretiyordu. Ayrı ad bilinçli.
        local d total=0 fail_count=0
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            total=$((total + 1))
            # Subshell: bir domainin 'error'ü tüm döngüyü düşürmesin.
            if ! ( _domconf_open_basedir_one "$d" "$state" ); then
                warn "${d}: uygulanamadı — atlandı"
                fail_count=$((fail_count + 1))
            fi
        done < <(list_all_domains)
        echo ""
        if [[ "$fail_count" -gt 0 ]]; then
            warn "open_basedir=${state}: ${total} domainden ${fail_count} tanesi BAŞARISIZ"
            return 1
        fi
        success "open_basedir=${state} uygulandı: ${total} domain"
        return 0
    fi

    [[ -n "$domain" ]] || error "Kullanım: srvctl domain open-basedir <domain>|--all <on|off> [--show]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    _domconf_open_basedir_one "$domain" "$state"
}

# ───────────────────────────────────────────────────────────────
#  ORTAK nginx SÖZCÜK ÇÖZÜMLEYİCİ (lexer + blok yığını)
#
#  Bu çözümleyici lib/nginx_allow.sh'ın izin listesi taramasını (kullanıcı custom.d
#  dosyaları) ve 'fm-auth off' referans taramasını besler. Eski
#  tarayıcılar (satır/ilk-kelime bazlı ve "tırnak her yerde açılır" bazlı)
#  nginx'in GERÇEK sözcük kurallarından saptığı için atlatılabiliyordu
#  Bu işlev ngx_conf_read_token'ı (src/core/ngx_conf_file.c)
#  birebir izler:
#
#    - Tırnak YALNIZ sözcüğün BAŞINDA açılır; sözcük ortasındaki  "  ve  \"
#      düz karakterdir (add_header X-A a";  → tırnak AÇMAZ).
#    - Kapanan tırnaktan sonra yalnız boşluk, ';', '{' ya da ')' gelebilir.
#    - '\' (tırnak dışı da, tırnak içi de) sonraki karakteri kaçırır; \" \' \\
#      sözcüğe tek karakter, \t \r \n sekme/CR/LF, diğerleri '\x' olarak girer.
#    - '#' yorumu YALNIZ sözcük başında başlar (a#b düz sözcüktür).
#    - '$' değişken başlatır; '${' içindeki '{' blok DEĞİLDİR.
#    - Sözcük ayırıcıları: boşluk, sekme, CR, LF; ifade/blok ayırıcıları ';' '{'
#      ('}' sözcük ortasında düz karakterdir; sözcük başında blok kapatır).
#    - Baştaki/dosya sonundaki dengesiz yapı (açık tırnak, ';'sız ifade, açık
#      blok, dosya düzeyinde '}') nginx'in de reddettiği durumdur → HATA.
#
#  Kullanım:  _domconf_nginx_parse <dosya> <geri-çağrı>
#  Geri çağrı:  <cb> stmt|open <satır> <ad> [argümanlar…]   (aynı kabukta çalışır)
#    stmt = ';' ile biten ifade, open = '{' ile açılan blok başlığı. Çağrı
#    sırasında _NGX_STACK ÜST bağlamı tutar (her blok başlığının ilk sözcüğü).
#  Dönüş: 0 = ayrıştırıldı, 2 = yapı hatası, 3 = okunamadı/NUL bayt.
#  Hata metni _NGX_ERR, satırı _NGX_ERR_LINE'da. FAIL-CLOSED: çağıranlar 0
#  dışındaki HER dönüşü "reddedildi" sayar.
# ───────────────────────────────────────────────────────────────
_NGX_ERR=""
_NGX_ERR_LINE=0
_NGX_STACK=()

# Dinamik kapsam: _domconf_nginx_parse'ın yerelleri (toks, cb, stmt_line …).
_domconf_ngx_reset_state() {
    tok=""; last_space=1; need_space=0; dq=0; sq=0; variable=0; quoted=0
    toks=(); ntok=0
}

_domconf_ngx_emit() {
    # $1 = stmt|open
    "$cb" "$1" "$stmt_line" "${toks[@]}" || true
    if [[ "$1" == "open" ]]; then
        _NGX_STACK+=("${toks[0]}")
    fi
    _domconf_ngx_reset_state
}

_domconf_nginx_parse() {
    local file="$1" cb="$2"
    local LC_ALL=C
    _NGX_ERR=""; _NGX_ERR_LINE=0; _NGX_STACK=()
    local content=""
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        _NGX_ERR="dosya okunamadı"
        return 3
    fi
    # Boyut tavanı: lexer bash'te karakter karakter işler ve hafif süper-doğrusaldır (bash 3.2 ölçümü:
    # 4 KB 0,08 sn, 16 KB 0,47 sn, 32 KiB 1,4 sn). Gerçek
    # override dosyaları birkaç KB'dır; tavanı aşan dosya hem DoS hem "dev dosya
    # içine gizleme" yoludur → ÇÖZÜMLENMEZ = REDDEDİLİR (fail-closed).
    local size
    size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size > ${_DOMCONF_NGX_MAX_BYTES:-32768} )); then
        _NGX_ERR="dosya çok büyük (>${_DOMCONF_NGX_MAX_BYTES:-32768} bayt) ya da boyutu okunamadı"
        return 3
    fi
    # NUL bayt: bash değişkeni taşıyamaz (sessizce düşerdi) → tarama körleşirdi.
    if ! LC_ALL=C tr -d '\000' < "$file" 2>/dev/null | cmp -s - "$file" 2>/dev/null; then
        _NGX_ERR="dosya NUL bayt içeriyor ya da okunamadı"
        return 3
    fi
    if ! content=$(cat -- "$file" 2>/dev/null && printf x); then
        _NGX_ERR="dosya okunamadı"
        return 3
    fi
    content="${content%x}"

    local -a toks=()
    local tok="" last_space=1 need_space=0 dq=0 sq=0 variable=0 quoted=0 cmt=0
    local ntok=0 line=1 stmt_line=1 found=0 c i n="${#content}"

    for ((i = 0; i < n; i++)); do
        c="${content:i:1}"
        if [[ "$c" == $'\n' ]]; then
            line=$((line + 1))
            cmt=0
        fi
        (( cmt )) && continue

        if (( quoted )); then
            quoted=0
            case "$c" in
                '"'|"'"|'\') tok+="$c" ;;
                t) tok+=$'\t' ;;
                r) tok+=$'\r' ;;
                n) tok+=$'\n' ;;
                *) tok+="\\${c}" ;;
            esac
            continue
        fi

        if (( need_space )); then
            case "$c" in
                ' '|$'\t'|$'\r'|$'\n') last_space=1; need_space=0; continue ;;
                ';') _domconf_ngx_emit stmt; continue ;;
                '{') _domconf_ngx_emit open; continue ;;
                ')') last_space=1; need_space=0 ;;
                *)
                    _NGX_ERR="kapanan tırnaktan sonra beklenmeyen karakter"
                    _NGX_ERR_LINE=$line
                    return 2
                    ;;
            esac
        fi

        if (( last_space )); then
            case "$c" in
                ' '|$'\t'|$'\r'|$'\n') continue ;;
                ';'|'{')
                    if (( ntok == 0 )); then
                        _NGX_ERR="ifadesiz '${c}'"; _NGX_ERR_LINE=$line; return 2
                    fi
                    if [[ "$c" == ';' ]]; then _domconf_ngx_emit stmt; else _domconf_ngx_emit open; fi
                    continue
                    ;;
                '}')
                    if (( ntok != 0 )); then
                        _NGX_ERR="ifade içinde beklenmeyen '}' (';' eksik)"; _NGX_ERR_LINE=$line; return 2
                    fi
                    if (( ${#_NGX_STACK[@]} == 0 )); then
                        _NGX_ERR="eşleşmeyen '}' (dosya düzeyi — üst bloğu kapatma girişimi)"; _NGX_ERR_LINE=$line; return 2
                    fi
                    unset '_NGX_STACK[${#_NGX_STACK[@]}-1]'
                    _domconf_ngx_reset_state
                    continue
                    ;;
                '#') cmt=1; continue ;;
                '\') (( ntok == 0 )) && stmt_line=$line; quoted=1; last_space=0; tok=""; continue ;;
                '"') (( ntok == 0 )) && stmt_line=$line; dq=1; last_space=0; tok=""; continue ;;
                "'") (( ntok == 0 )) && stmt_line=$line; sq=1; last_space=0; tok=""; continue ;;
                '$') (( ntok == 0 )) && stmt_line=$line; variable=1; last_space=0; tok='$'; continue ;;
                *)   (( ntok == 0 )) && stmt_line=$line; last_space=0; tok="$c"; continue ;;
            esac
        else
            if [[ "$c" == '{' ]] && (( variable )); then
                tok+="$c"; continue
            fi
            variable=0
            if [[ "$c" == '\' ]]; then quoted=1; continue; fi
            if [[ "$c" == '$' ]]; then variable=1; tok+="$c"; continue; fi
            found=0
            if (( dq )); then
                if [[ "$c" == '"' ]]; then dq=0; need_space=1; found=1; fi
            elif (( sq )); then
                if [[ "$c" == "'" ]]; then sq=0; need_space=1; found=1; fi
            else
                case "$c" in
                    ' '|$'\t'|$'\r'|$'\n'|';'|'{') last_space=1; found=1 ;;
                esac
            fi
            if (( found )); then
                toks+=("$tok"); ntok=$((ntok + 1)); tok=""
                if [[ "$c" == ';' ]]; then _domconf_ngx_emit stmt
                elif [[ "$c" == '{' ]]; then _domconf_ngx_emit open
                fi
            else
                tok+="$c"
            fi
        fi
    done

    if (( ntok > 0 || last_space == 0 )); then
        _NGX_ERR="dosya sonunda kapanmamış tırnak ya da ';' ile bitmeyen ifade"
        _NGX_ERR_LINE=$line
        return 2
    fi
    if (( ${#_NGX_STACK[@]} > 0 )); then
        _NGX_ERR="dosya sonunda kapanmamış blok"
        _NGX_ERR_LINE=$line
        return 2
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────
#  custom.d KULLANICI DOSYALARI — varsayılan-ret İZİN LİSTESİ
#
#  ESKİ yasak-listesi (ad/kalıp deny, proxy_pass koşullu politikası, B-biçimi
#  korpus, "SCAN_OWN" içerik muafiyeti) KALDIRILDI. Yerine:
#   (1) srvctl'in KENDİ ürettiği dosyalar (20/21/90) şablondan gelir ve KÖKEN
#       KAYDI (aşağıda _fmprov_*) ile tanınır; tarama muafiyeti YALNIZ buna bağlıdır
#       (içerik kalıbıyla muafiyet YOK).
#   (2) kalan HER dosya "kullanıcı dosyası"dır ve lib/nginx_allow.sh'ın
#       _ngxallow_scan'ından (varsayılan ret; lexer = aşağıdaki ngx_conf_read_token
#       birebir çözümleyicisi) geçer. Doğrulanamayan (rc 2) = reddedilmiş sayılır.
#  Bu dosyada tablo/kural YOKTUR: izin listesi tek kaynakta (nginx_allow.sh) durur.
# ───────────────────────────────────────────────────────────────

# İzin listesi kitaplığını talep üzerine yükler (indirect source: test_no_undefined_functions).
_domconf_load_allow_lib() {
    declare -F _ngxallow_scan >/dev/null 2>&1 && return 0
    local lib="${SRVCTL_ROOT}/lib/nginx_allow.sh"
    [[ -f "$lib" ]] || return 1
    # shellcheck disable=SC1090
    source "$lib" || return 1
    declare -F _ngxallow_scan >/dev/null 2>&1
}

# Sarmalayıcı: $1=dosya $2=domain [$3=mantıksal dosya adı — dosya aday/geçici yolda ise HEDEF
# adı; izin listesi rezerve-ad denetimini bu ada göre yapar]. stdout: bulgular (satır:direktif:gerekçe).
# rc 0 temiz, 1 ihlal, 2 doğrulanamadı (kitaplık yok/çökme/beklenmeyen kod = 2, FAIL-CLOSED).
_domconf_user_scan() {
    local file="$1" domain="$2" lname="${3:-}" rc=0
    if ! _domconf_load_allow_lib; then
        echo "0:-:izin listesi kitaplığı (lib/nginx_allow.sh) yüklenemedi — FAIL-CLOSED"
        return 2
    fi
    _ngxallow_scan "$file" "$domain" "$lname" || rc=$?
    case "$rc" in
        0|1|2) return "$rc" ;;
    esac
    echo "0:-:izin listesi beklenmeyen çıkış kodu (${rc}) — FAIL-CLOSED"
    return 2
}

# ───────────────────────────────────────────────────────────────
#  Genel yardımcılar (sha256, nlink)
# ───────────────────────────────────────────────────────────────
# stdin'i okur, sha256 onaltılığını basar. sha256sum (GNU) | shasum -a 256 (macOS).
_domconf_sha256_stdin() {
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256) || return 1
    else
        return 1
    fi
    out="${out%% *}"
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$out"
}

_domconf_sha256_file() {
    [[ -f "$1" ]] || return 1
    _domconf_sha256_stdin < "$1"
}

# Metnin, _domconf_atomic_write'ın dosyaya yazacağı biçimdeki (metin + LF) özeti.
_domconf_sha256_text() {
    printf '%s\n' "$1" | _domconf_sha256_stdin
}

# Sabit bağ (hardlink) sayısı (GNU stat -c %h | BSD stat -f %l).
_stat_nlink() {
    stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1"
}

_domconf_fm_dir() {
    printf '%s/%s' "${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}" "$1"
}

# custom.d/<sname> GÜVEN KAPISI. FM yazıcıları (20/21/90) bu dizine root olarak yazar; dizin (ya da yol bileşenlerinden
# biri) sembolik bağ ya da root'a ait olmayan / grup-herkes tarafından yazılabilen bir dizinse yazım bağı İZLER ve
# kiracının dizinine düşer. Güvenilir = yok (üst dizin zinciri güvenilir) ya da sembolik bağ olmayan, tüm zinciri root
# sahipli, g/o-yazılamaz gerçek dizin. $1 dizin yolu $2 sname. PREDİKAT: 0 = güvenilir, 1 = değil (neden _FMD_WHY).
_FMD_WHY=""
_domconf_fm_dir_trusted() {
    local dir="$1" sname="${2:-}" anc phys
    _FMD_WHY=""
    if [[ -L "$dir" ]]; then
        _FMD_WHY="custom.d/${sname} sembolik bağ: ${dir}"
        return 1
    fi
    # Üst dizinler FİZİKSEL yolla denetlenir (kök tarafından konmuş üst bağlar — ör. /var -> /private/var — kiracının
    # değiştirebileceği bir bileşen değildir; fiziksel zincirde root sahipli olmayan ya da g/o-yazılabilir dizin güvenilmezdir).
    if [[ -e "$dir" ]]; then
        if [[ ! -d "$dir" ]]; then
            _FMD_WHY="custom.d/${sname} dizin değil: ${dir}"
            return 1
        fi
        phys=$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P) || phys=""
        if [[ -z "$phys" ]] || ! assert_root_owned_path "${phys}/$(basename "$dir")"; then
            _FMD_WHY="custom.d/${sname} root'a ait değil, grup/herkes tarafından yazılabilir ya da yol bileşenlerinden biri güvenilmez: ${dir}"
            return 1
        fi
        return 0
    fi
    anc=$(dirname "$dir")
    while [[ ! -e "$anc" && ! -L "$anc" && "$anc" != "/" && -n "$anc" ]]; do anc=$(dirname "$anc"); done
    phys=$(cd "$anc" 2>/dev/null && pwd -P) || phys=""
    if [[ -z "$phys" ]] || ! assert_root_owned_path "$phys"; then
        _FMD_WHY="custom.d/${sname} henüz yok ama en yakın var olan üst dizin güvenilmez (root sahipli değil, g/o-yazılabilir ya da çözülemiyor): ${anc}"
        return 1
    fi
    return 0
}

# Güvenilmeyen custom.d/<sname> girdisini KENARA alır (sembolik bağın KENDİSİ ya da yabancı dizin; hedefe/içine
# yazılmaz, silinmez), yerine root sahipli yeni dizin + 403 kökü kurar. Kenara alınan girdi yeni dizinin içine
# '<sname>.srvctl-emergency.<pid>.<rastgele>' adıyla girer (*.conf glob'una UYMAZ; adli kanıt). Yalnız KAPATMA yönündeki
# yollar çağırır (acil kapatma, 'fm-auth off'). $1 dizin $2 sname. PREDİKAT: 0 = dizin artık güvenilir + 403 kökü yerinde,
# 1 = yapılamadı (neden _FMD_WHY; çağıran "FM HÂLÂ AÇIK OLABİLİR" der).
_FMD_ASIDE=""
_FMD_SIG=0
# SİNYAL KORUMASI: kenara alma (mkdir → 403 kökü → iki mv → doğrulama) bir BÜTÜNDÜR; ortasında INT/TERM/HUP süreci öldürürse
# custom.d/<sname> eksik kalır ('/_fm' uygulamaya düşer) ya da yetim '<sname>.srvctl-new.*' dizini kalırdı. Bu yüzden bu sarmalayıcı
# üç sinyali İŞARETLE ertelenmiş tutar (_FMD_SIG = sinyalin çıkış kodu: INT 130, TERM 143, HUP 129), kenara almayı TAMAMLAR (ya da
# kendi hata dalında geri koyar), çağıranın tuzaklarını eski haline getirir ve dönüşte sinyali çağırana BIRAKIR (çağıran
# _FMD_SIG'e bakıp temiz çıkar). Önceki tuzak yok-sayma ('') ise (acil kapatma yolu) o korunur: sinyal yine ertelenir, çağıran bakmaz.
_domconf_fm_dir_quarantine() {
    local sv_int sv_term sv_hup rc=0
    sv_int=$(trap -p INT); sv_term=$(trap -p TERM); sv_hup=$(trap -p HUP)
    _FMD_SIG=0
    trap '_FMD_SIG=130' INT
    trap '_FMD_SIG=143' TERM
    trap '_FMD_SIG=129' HUP
    _domconf_fm_dir_quarantine_do "$@" || rc=$?
    if [[ -n "$sv_int" ]]; then eval "$sv_int"; else trap - INT; fi
    if [[ -n "$sv_term" ]]; then eval "$sv_term"; else trap - TERM; fi
    if [[ -n "$sv_hup" ]]; then eval "$sv_hup"; else trap - HUP; fi
    return $rc
}

_domconf_fm_dir_quarantine_do() {
    local dir="$1" sname="${2:-}" base newd aside off_txt
    _FMD_ASIDE=""
    off_txt=$(_domconf_fm_render_off "$sname") || { _FMD_WHY="403 kökü üretilemedi (sname güvensiz)"; return 1; }
    base=$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P) || base=""
    if [[ -z "$base" ]] || ! assert_root_owned_path "$base"; then
        _FMD_WHY="üst dizin güvenilmez (root sahipli değil, g/o-yazılabilir ya da çözülemiyor): $(dirname "$dir")"
        return 1
    fi
    newd="${dir}.srvctl-new.$$.${RANDOM}"
    if [[ -e "$newd" || -L "$newd" ]]; then _FMD_WHY="geçici ad dolu: ${newd}"; return 1; fi
    if ! mkdir -m 755 -- "$newd" 2>/dev/null; then _FMD_WHY="yeni dizin oluşturulamadı: ${newd}"; return 1; fi
    if ! _domconf_atomic_write "${newd}/${_DOMCONF_FM_UP_FILE}" "$off_txt"; then
        _FMD_WHY="403 kökü yeni dizine yazılamadı: ${newd}"
        rm -rf -- "${newd:?}"
        return 1
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
        aside="${newd}/${sname}.srvctl-emergency.$$.${RANDOM}"
        if ! mv -- "$dir" "$aside" 2>/dev/null; then
            _FMD_WHY="${dir} kenara alınamadı"
            rm -rf -- "${newd:?}"
            return 1
        fi
        _FMD_ASIDE="$aside"
    fi
    if ! mv -- "$newd" "$dir" 2>/dev/null; then
        # Yarım durum bırakma: eski girdiyi yerine geri koy (aynı dizin içinde yeniden adlandırma), hazırlanan dizini kaldır.
        if [[ -n "$_FMD_ASIDE" && ! -e "$dir" && ! -L "$dir" ]] && mv -- "$_FMD_ASIDE" "$dir" 2>/dev/null; then
            _FMD_ASIDE=""
            rm -rf -- "${newd:?}"
            _FMD_WHY="yeni dizin yerine konamadı: ${newd} -> ${dir} (eski girdi geri konuldu)"
        else
            _FMD_WHY="yeni dizin yerine konamadı: ${newd} -> ${dir} (YARIM DURUM: ${newd} ve içindeki ${_FMD_ASIDE:-kenara alınan girdi} elle incelenmeli)"
        fi
        return 1
    fi
    # Kenara alınan eski girdi artık YENİ dizinin içinde değil, son yoldadır (ileti gerçek yolu söylesin).
    if [[ -n "$_FMD_ASIDE" ]]; then _FMD_ASIDE="${dir}/${_FMD_ASIDE##*/}"; fi
    if [[ -L "$dir" ]] || ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        _FMD_WHY="kurulan dizin doğrulanamadı: ${_FMD_WHY:-${dir}}"
        return 1
    fi
    return 0
}

# Yazım (açma yönü) reddi iletisi: srvctl güvenilmeyen custom.d/<sname> girdisine YAZMAZ, izlemez, taşımaz.
# $1 domain $2 eylem adı. stdout YOK; stderr'e yüksek sesli ileti (_FMD_WHY dolu olmalı).
_domconf_fm_dir_refuse() {
    local domain="$1" what="$2"
    warn "${domain}: YAPILAMAZ — ${_FMD_WHY} — ${what}: HİÇBİR dosya yazılmadı (srvctl bu girdiyi izlemez; kiracının dizinine root olarak yazmak güvenlik açığıdır). Girdiyi inceleyip root sahipli gerçek bir dizine çevirin; alanı yine de KAPATMAK için: srvctl domain fm-auth ${domain} off (girdiyi kenara alıp root sahipli 403 kökü kurar)"
}

# ───────────────────────────────────────────────────────────────
#  KÖKEN KAYDI (provenance) — srvctl'in ürettiği FM dosyalarının tanınması
#
#  Kayıt: ${SRVCTL_STATE_DIR}/_fm-auth/<sname>.manifest (dizin root 0700, dosya 0600,
#  atomik yazım). Satırlar (sabit sözlük; tanınmayan satır = bozuk kayıt):
#     srvctl-fm-auth-manifest v1 / state on|off / region eu|us / script <yol> /
#     php_version <N.N> / modsec 0|1 / tpl_ver <N> / sha256 <64 hex> <dosya adı>
#  Sabit dosya adı kümesi (3 ad) dışında girdi tanınmaz. Bir ad için BİRDEN ÇOK sha256
#  satırı olabilir: İKİ-AŞAMALI GEÇİŞ (yazımdan önce eski+yeni özet, doğrulanınca yalnız
#  yeni) — araya giren çökme "üretilmiş" dosyayı kullanıcı dosyasına çevirmez.
#
#  Güven: dizin/dosya sembolik bağ DEĞİL, root sahipli, g/o yazma yok (assert_root_owned_path),
#  mod tam 700/600, manifest nlink==1, dizin yolu fiziksel yolla eşit. Aksi → STATE-UNTRUSTED:
#  HİÇBİR dosya "üretilmiş" tanınmaz (hepsi kullanıcı dosyası → izin listesine tabi).
#  Muafiyet SADECE _fmprov_is_generated'a bağlıdır: ad sabit kümede + normal dosya
#  (sembolik bağ değil, nlink==1) + root sahipli + g/o yazma yok + sha256 kayıtla eşit.
# ───────────────────────────────────────────────────────────────
_DOMCONF_FM_AUTH_FILE="90-srvctl-fm-auth.conf"
_DOMCONF_FM_DL_FILE="21-srvctl-fm-download.conf"
_DOMCONF_FM_UP_FILE="20-srvctl-fm-upload.conf"
_DOMCONF_FM_LEGACY_INC="srvctl-fm-upload-modsec.inc"
# Şablon sürümü. 2 = alan adına özgü gövde imzası (bkz. _domconf_fm_body_sig); 3 = 2 + 20 şablonunda '/__fm_' ad alanı yakalayıcısı
# (90 ya da 21 yokken iç istek uygulamaya düşmez); 4 = 3 + KAPALI kökte de aynı yakalayıcı (alan kapalıyken uygulama X-Accel-Redirect ile
# '/__fm_dl'e yönlendirirse istek uygulamaya düşmez, 403 alır). Gövde imzasını ya da 20-srvctl-fm-upload.conf şablonunu değiştiren her değişiklik
# BU sayıyı artırmalıdır (imza sürüme bağlıdır: eski sürümle üretilmiş dosya sonda tarafından tanınmaz, "doğrulanamadı" çıkar;
# fm-root --apply yeniler).
_DOMCONF_FM_TPL_VER=4

# alan adına özgü GÖVDE İMZASI (sır DEĞİL; yalnız "bu yanıt BU alanın srvctl üretimi kökünden geldi" kanıtı):
#   sig = sha256("srvctl-fm-sig:v" + _DOMCONF_FM_TPL_VER + ":" + sname) ilk 12 hex
# Kapalı kök  → `return 403 "srvctl-fm-closed <sig>"` (render_off: `= /_fm` + `^~ /_fm/`)
# Açık yükleme → `return 411 "srvctl-fm-open <sig>"`   (render_upload: Content-Length yok kolu)
# Sonda (_domconf_fm_runtime_probe) YALNIZ (403 + tam "srvctl-fm-closed <sig>") ya da (411 + tam
# "srvctl-fm-open <sig>") yanıtını tanır; imzasız 403/411 (sunucu düzeyi 403, köksüz alanda uygulamanın 411'i,
# SSL'siz alanın 443'te başka vhost'a düşmesi, başka alanın imzası) HİÇBİR ZAMAN durum kanıtı sayılmaz.
# Tek üretici BU işlevdir. PREDİKAT: 0 = imza stdout'ta; 1 = sname güvensiz / sha256 yok.
_domconf_fm_body_sig() {
    local sname="${1:-}" h
    assert_safe_ident "$sname" || return 1
    h=$(printf 'srvctl-fm-sig:v%s:%s' "$_DOMCONF_FM_TPL_VER" "$sname" | _domconf_sha256_stdin) || return 1
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${h:0:12}"
}

_fmprov_dir() {
    printf '%s/_fm-auth' "${SRVCTL_STATE_DIR}"
}

_fmprov_manifest() {
    printf '%s/%s.manifest' "$(_fmprov_dir)" "$1"
}

_fmprov_known_name() {
    case "$1" in
        "$_DOMCONF_FM_AUTH_FILE"|"$_DOMCONF_FM_DL_FILE"|"$_DOMCONF_FM_UP_FILE") return 0 ;;
    esac
    return 1
}

# PREDİKAT: 0=güvenilir (yok olması da güvenilir), 1=güvenilmez.
_fmprov_state_ok() {
    local sname="${1:-}" dir man phys par
    dir=$(_fmprov_dir)
    if [[ -e "$dir" || -L "$dir" ]]; then
        [[ -d "$dir" && ! -L "$dir" ]] || return 1
        assert_root_owned_path "$dir" || return 1
        [[ "$(_stat_mode "$dir")" == "700" ]] || return 1
        phys=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
        par=$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P) || return 1
        [[ "$phys" == "${par}/_fm-auth" ]] || return 1
    fi
    if [[ -n "$sname" ]]; then
        man=$(_fmprov_manifest "$sname")
        if [[ -e "$man" || -L "$man" ]]; then
            [[ -f "$man" && ! -L "$man" ]] || return 1
            assert_root_owned_path "$man" || return 1
            [[ "$(_stat_mode "$man")" == "600" ]] || return 1
            [[ "$(_stat_nlink "$man")" == "1" ]] || return 1
        fi
    fi
    return 0
}

# VAR OLAN kayıt dizininin sahibi/modu GÜVENİLMEZ mi? PREDİKAT: 0 = güvenilmez (neden _FMP_PREP_WHY'a), 1 = sorun yok.
# Yabancı sahip (root değil) ya da grup/herkes YAZILABİLİR (mod & 022). Yalnız bu iki durum "onarılmaz": mod 0700'e çekmek dizinin
# İÇERİĞİNİ doğrulamaz (yabancı sahip ya da yazabilen biri manifest/işaret/yedek koymuş olabilir). Yazılamaz-gevşek modlar (0755, 0750 …)
# root sahipliyken eskisi gibi 0700'e sıkılaştırılır.
_FMP_PREP_WHY=""
_fmprov_dir_untrusted_preexisting() {
    local dir="$1" own mode last2
    _FMP_PREP_WHY=""
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    own=$(_stat_owner "$dir") || own="?"
    mode=$(_stat_mode "$dir") || mode="?"
    if [[ "$own" != "root" ]]; then _FMP_PREP_WHY="yabancı sahipli (${own}; root bekleniyor)"; return 0; fi
    if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
        last2="${mode: -2}"
        if (( (${last2:0:1} & 2) != 0 || (${last2:1:1} & 2) != 0 )); then
            _FMP_PREP_WHY="grup/herkes tarafından yazılabilir (mod ${mode})"; return 0
        fi
    else
        _FMP_PREP_WHY="mod okunamadı"; return 0
    fi
    return 1
}

# Kayıt dizinini hazırlar (0700 root) ve güvenini doğrular. rc 0/1.
# Dizin HİÇ YOKSA oluşturulur (ilk kurulum, muaf). VAR ve yabancı sahipli / grup-herkes yazılabilir ise modu SESSİZCE 0700'e
# ÇEKİLMEZ: reddedilir (rc 1; çağıranlar zaten yazım yapmadan çıkar) ve düzeltme ipucu verilir.
_fmprov_prepare_dir() {
    local dir; dir=$(_fmprov_dir)
    if [[ -L "$dir" ]]; then
        warn "köken kayıt dizini sembolik bağ: ${dir} — reddedildi"
        return 1
    fi
    if _fmprov_dir_untrusted_preexisting "$dir"; then
        warn "kayıt dizini güvenilmez: ${dir} — ${_FMP_PREP_WHY}. Modu sessizce 0700'e çekmek içeriğini doğrulamaz; HİÇBİR ŞEY YAZILMADI. Yapılacak: dizinin içeriğini inceleyin, sonra 'chown root:root ${dir} && chmod 700 ${dir}'; alan açık olabiliyorsa kayıttan bağımsız kapatın: srvctl domain fm-auth <alan> off --emergency"
        return 1
    fi
    secure_dir "$dir" 700 || return 1
    _fmprov_state_ok "" || { warn "köken kayıt dizini güvenilmez (sahip/mod/yol): ${dir}"; return 1; }
    return 0
}

_FMP_STATE=""; _FMP_REGION=""; _FMP_SCRIPT=""; _FMP_PHP=""; _FMP_MODSEC=""; _FMP_TPL=""; _FMP_HASHES=""; _FMP_EMERGENCY=0
_fmprov_reset() {
    _FMP_STATE=""; _FMP_REGION=""; _FMP_SCRIPT=""; _FMP_PHP=""; _FMP_MODSEC=""; _FMP_TPL=""; _FMP_HASHES=""; _FMP_EMERGENCY=0
}

# ACİL KAPATMA İŞARETİ — ${SRVCTL_STATE_DIR}/_fm-auth/<sname>.emergency. 'fm-auth off --emergency'
# (ya da normal 'off' başarısız olunca otomatik acil yol) kayıt/kilit olmadan diski KAPATIR; kayıt o
# sırada yazılamazsa (kilit alınamadı, flock yok, nginx -t düştü) kayıtta hâlâ 'state on' yazar. İşaret,
# sonraki repair / fm-root / php-switch / yarım-işlem kurtarmasının kaydı 'on' diye okuyup 90/21'i yeniden
# üretmesini (= acil kapanmayı geri AÇMASINI) engeller: _fmprov_load işaret varken 'on'u 'off'a ÇEVİRİR.
# Yalnız açık bir 'fm-auth on' (tüm kapılardan geçerek, aşama-2 kaydı yazılınca) işareti kaldırır; bir
# 'off' kaydı (tx_commit) ya da 'domain remove' da kaldırır. İşaret yalnızca kapatma yönünü sıkılaştırır.
_fmprov_emergency_marker() {
    printf '%s/%s.emergency' "$(_fmprov_dir)" "$1"
}

# İKİNCİ GÜVENİLİR KONUM. Kayıt dizini (SRVCTL_STATE_DIR/_fm-auth) güvenilmezse (sembolik bağ, sahip/mod/yol
# yanlış) işaret oraya YAZILAMAZ (root sembolik bağ izleyerek yazmaz) — oysa tam o durumda operatör dizini düzeltip
# 'status'un önerdiği komutu koşunca kayıt 'on' diye okunurdu. Bu yüzden işaret, kayıt dizininden BAĞIMSIZ,
# root:root 0700 bir dizine yazılır: ${SRVCTL_FM_EMERGENCY_DIR:-/var/lib/srvctl/fm-emergency} (srvctl durum ağacının
# DIŞINDA; /usr/local/srvctl altındaki bir bozulma buraya taşmaz). _fmprov_emergency_present HER İKİ konuma bakar;
# varlık yönü yalnız sıkılaştırır (bir işareti "var" saymak alanı yalnız KAPALI tutar), bu yüzden okurken güven aranmaz;
# YAZARKEN dizin güveni aranır.
# varsayılan yol SABİTTİR (test kancası: değişken yeniden atanabilir; SRVCTL_FM_EMERGENCY_DIR öncelikli).
_DOMCONF_FM_EM_DEFAULT_DIR="/var/lib/srvctl/fm-emergency"
_fmprov_emergency_alt_dir() {
    printf '%s' "${SRVCTL_FM_EMERGENCY_DIR:-${_DOMCONF_FM_EM_DEFAULT_DIR}}"
}

_fmprov_emergency_alt_marker() {
    printf '%s/%s.emergency' "$(_fmprov_emergency_alt_dir)" "$1"
}

# PREDİKAT: 0 = ikinci konum dizini güvenilir (gerçek dizin, sembolik bağ değil, root sahipli zincir, 0700, fiziksel yol eşit).
# reddin NEDENİ _FMP_ALT_WHY'a yazılır (iletide görünür: mod / sahip / sembolik bağ / sondaki '/' / yol).
_FMP_ALT_WHY=""
_fmprov_emergency_alt_ok() {
    local dir phys par mode
    _FMP_ALT_WHY=""
    dir=$(_fmprov_emergency_alt_dir)
    if [[ "$dir" == */ ]]; then _FMP_ALT_WHY="yol sondaki '/' ile bitiyor (fiziksel yol karşılaştırması bozulur)"; return 1; fi
    if [[ -L "$dir" ]]; then _FMP_ALT_WHY="dizin sembolik bağ"; return 1; fi
    if [[ ! -e "$dir" ]]; then _FMP_ALT_WHY="dizin yok"; return 1; fi
    if [[ ! -d "$dir" ]]; then _FMP_ALT_WHY="dizin değil"; return 1; fi
    if ! assert_root_owned_path "$dir"; then _FMP_ALT_WHY="sahip/yol zinciri root değil, grup/diğer yazılabilir ya da bir bileşen sembolik bağ (root:root bekleniyor)"; return 1; fi
    mode=$(_stat_mode "$dir")
    if [[ "$mode" != "700" ]]; then _FMP_ALT_WHY="mod ${mode} (700 bekleniyor)"; return 1; fi
    phys=$(cd "$dir" 2>/dev/null && pwd -P) || { _FMP_ALT_WHY="dizin çözülemedi"; return 1; }
    par=$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P) || { _FMP_ALT_WHY="üst dizin çözülemedi"; return 1; }
    if [[ "$phys" != "${par}/${dir##*/}" ]]; then _FMP_ALT_WHY="fiziksel yol farklı (üst bileşen sembolik bağ?): ${phys}"; return 1; fi
    return 0
}

# ikinci konum dizinini ÖNCEDEN hazırlar: mkdir -p + chmod 700 + root sahipliği/güven doğrulaması; İDEMPOTENT.
# install.sh / init / self-update kurulum yolu bunu çağırır (acil kapatma ilk ihtiyaçta dizin oluşturmaya bırakılmaz:
# tam o anda /var/lib yazılamaz/AppArmor reddi olabilir). Mod 0700'e NORMALLEŞTİRİLİR (srvctl'in kendi dizini); sembolik bağ / yanlış sahip / sondaki '/' ONARILMAZ, REDDEDİLİR (rc 1).
# PREDİKAT: 0 = dizin root:root 0700 ve güvenilir.
_domconf_fm_em_state_dir_prepare() {
    local dir
    dir=$(_fmprov_emergency_alt_dir)
    [[ -n "$dir" && "$dir" == /* ]] || { warn "acil kapatma işareti dizini mutlak yol değil: ${dir:-?}"; return 1; }
    if [[ "$dir" == */ ]]; then warn "acil kapatma işareti dizini sondaki '/' ile bitiyor: ${dir}"; return 1; fi
    if [[ -L "$dir" ]]; then warn "acil kapatma işareti dizini sembolik bağ: ${dir} — reddedildi"; return 1; fi
    if [[ -e "$dir" && ! -d "$dir" ]]; then warn "acil kapatma işareti dizini dizin değil: ${dir}"; return 1; fi
    secure_dir "$dir" 700 || { warn "acil kapatma işareti dizini hazırlanamadı: ${dir}"; return 1; }
    # assert_root_owned_path (zincir denetimi) WEB_ROOT'ta durur ve WEB_ROOT YOKSA hata verir; taze kurulumda (install.sh / ilk
    # init) /var/www henüz olmayabilir. Bu dizin WEB_ROOT'un DIŞINDA olduğundan zincir kök dizine ('/') kadar doğrulanır.
    local WEB_ROOT="${WEB_ROOT:-}"
    [[ -d "$WEB_ROOT" ]] || WEB_ROOT=/
    if ! _fmprov_emergency_alt_ok; then
        warn "acil kapatma işareti dizini güvenilir değil: ${dir} (${_FMP_ALT_WHY}) — root:root 0700 yapın"
        return 1
    fi
    return 0
}

# PREDİKAT: 0 = bu alan için acil kapatma işareti VAR (iki konumdan biri; sarkan/yanlış türde girdi dahil).
_fmprov_emergency_present() {
    local m
    for m in "$(_fmprov_emergency_marker "$1")" "$(_fmprov_emergency_alt_marker "$1")"; do
        if [[ -e "$m" || -L "$m" ]]; then return 0; fi
    done
    return 1
}

# İşareti HER İKİ konumdan kaldırır (yalnız açık 'on'/'off' kaydı ve 'domain remove' çağırır).
_fmprov_emergency_clear() {
    rm -f -- "$(_fmprov_emergency_marker "$1")" "$(_fmprov_emergency_alt_marker "$1")"
}

# İşaretin bulunduğu yol(lar) (bilgi iletisi için).
_fmprov_emergency_where() {
    local m out=""
    for m in "$(_fmprov_emergency_marker "$1")" "$(_fmprov_emergency_alt_marker "$1")"; do
        if [[ -e "$m" || -L "$m" ]]; then out+="${out:+, }${m}"; fi
    done
    printf '%s' "$out"
}

# kayıt 'on' diyor ama diskte YALNIZ srvctl'in 403 kökü var (20 = _domconf_fm_render_off, 90/21 YOK) →
# alan KAPALIDIR: acil kapatma işareti yazılamamış/silinmiş olsa bile bu iz "kayıt on" yazısından güçlüdür (diskin
# kendisi kapalı). _fmprov_load bu durumda kaydı KAPALI sayar; repair/fm-root/php-switch/kurtarma 'on' YAZMAZ.
# Çıkış yönü yalnız sıkılaştırır: 'on' ile 'kapalı' arasında yarım kalmış bir geçiş (kayıt on yazıldı, 90 henüz
# yazılmadı) de KAPALI sayılır — açıkça 'fm-auth on' yeniden koşulur (fail-closed). PREDİKAT: 0 = kanıt var.
_fmprov_closed_evidence() {
    local sname="$1" dir f
    dir=$(_domconf_fm_dir "$sname")
    [[ -d "$dir" ]] || return 1
    for f in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
        if [[ -e "${dir}/${f}" || -L "${dir}/${f}" ]]; then return 1; fi
    done
    # KAPALI KANITI srvctl'in ürettiği HER 403 kökü biçimini tanır (güncel/önceki/gelecek tpl_ver imzası, eski
    # imzasız biçim); yalnız GÜNCEL tpl_ver'in kökünü tanımak her tpl_ver artışında sınıfı yeniden doğururdu.
    _domconf_fm_closed_root_known "${dir}/${_DOMCONF_FM_UP_FILE}" "$sname" "${_FMP_HASHES:-}"
}

# Kayıt 'on' + 90/21 yok + 20 srvctl 403 köküne BENZİYOR ama birebir/güvenli değil (CRLF, sondaki boşluk, satır
# içi yorum, mod 664/666, yabancı sahip, sert bağ …) → bu KANIT DEĞİLDİR (_fmprov_closed_evidence reddeder) ama alan da
# otomatik AÇILMAZ: _fmprov_load kaydı KAPALI sayar (_FMP_EMERGENCY=3); repair / fm-root / php-switch / kurtarma 'on' YAZMAZ,
# yalnız açık 'fm-auth on' açar. Eski davranış ("sahte kök kanıt değil, kayda göre yeniden üretilir") 8 yolun 6'sında
# kozmetik bozulmuş kapalı alanı AÇIYORDU. PREDİKAT: 0 = kapalı görünümlü kök var.
_fmprov_closed_lookalike_evidence() {
    local sname="$1" dir f
    dir=$(_domconf_fm_dir "$sname")
    [[ -d "$dir" ]] || return 1
    for f in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
        if [[ -e "${dir}/${f}" || -L "${dir}/${f}" ]]; then return 1; fi
    done
    _domconf_fm_closed_root_lookalike "${dir}/${_DOMCONF_FM_UP_FILE}"
}

# MANİFEST AYRIŞTIRICI (saf; sınıflama/güven denetimi YOK). $1 = manifest yolu. Küresel _FMP_*'ı doldurur
# (çağıran _fmprov_reset yapmış olmalı). rc 0 = ayrıştırıldı, 2 = bozuk (_FMP_* sıfırlanır). Dosya varlığını çağıran denetler.
# _fmprov_load ve yarım-işlem yedeğinin ön durumunu inceleyen _fmprov_bk_restore_allowed AYNI ayrıştırıcıyı kullanır.
_fmprov_parse_manifest() {
    local man="$1" line rest hx nm hdr=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "srvctl-fm-auth-manifest v1") hdr=1 ;;
            "state on"|"state off") _FMP_STATE="${line#state }" ;;
            "region eu"|"region us") _FMP_REGION="${line#region }" ;;
            "script -") _FMP_SCRIPT="-" ;;
            "script "*)
                rest="${line#script }"
                _domconf_fm_auth_script_ok "$rest" || { _fmprov_reset; return 2; }
                _FMP_SCRIPT="$rest" ;;
            "php_version -") _FMP_PHP="-" ;;
            "php_version "*)
                rest="${line#php_version }"
                assert_php_version "$rest" || { _fmprov_reset; return 2; }
                _FMP_PHP="$rest" ;;
            "modsec 0"|"modsec 1") _FMP_MODSEC="${line#modsec }" ;;
            "tpl_ver "*)
                rest="${line#tpl_ver }"
                [[ "$rest" =~ ^[0-9]{1,4}$ ]] || { _fmprov_reset; return 2; }
                _FMP_TPL="$rest" ;;
            "sha256 "*)
                rest="${line#sha256 }"
                hx="${rest%% *}"; nm="${rest#* }"
                [[ "$hx" =~ ^[0-9a-f]{64}$ ]] || { _fmprov_reset; return 2; }
                _fmprov_known_name "$nm" || { _fmprov_reset; return 2; }
                _FMP_HASHES+="${hx} ${nm}"$'\n' ;;
            *) _fmprov_reset; return 2 ;;
        esac
    done < "$man"
    if (( hdr == 0 )) || [[ -z "$_FMP_STATE" || -z "$_FMP_REGION" || -z "$_FMP_SCRIPT" || -z "$_FMP_PHP" || -z "$_FMP_MODSEC" || -z "$_FMP_TPL" ]]; then
        _fmprov_reset; return 2
    fi
    if [[ "$_FMP_STATE" == "on" ]]; then
        [[ "$_FMP_SCRIPT" != "-" && "$_FMP_PHP" != "-" ]] || { _fmprov_reset; return 2; }
    fi
    return 0
}

# srvctl üretimi dosyanın METAVERİ güveni: normal dosya (sembolik bağ DEĞİL), nlink==1, sahip root, grup/diğer yazma yok.
# PREDİKAT: 0 = güvenli.
_fmprov_file_meta_ok() {
    local path="$1" mode last2
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ "$(_stat_nlink "$path")" == "1" ]] || return 1
    [[ "$(_stat_owner "$path")" == "root" ]] || return 1
    mode=$(_stat_mode "$path") || return 1
    last2="${mode: -2}"
    (( (${last2:0:1} & 2) == 0 && (${last2:1:1} & 2) == 0 )) || return 1
    return 0
}

# "bir dosya kayıtlı özetle eşleşen, güvenli metaveriye sahip srvctl üretimi mi" (YÜKLEME YOK: çağıran _FMP_HASHES'i
# doldurmuş olmalı). $1 = dosya adı (sabit kümede), $2 = yol. Özet _FMP_HASHES'te "<hex> <ad>" olarak kayıtlı olmalı. PREDİKAT: 0 = eşleşir.
_fmprov_file_matches_record() {
    local base="$1" path="$2" h
    _fmprov_known_name "$base" || return 1
    _fmprov_file_meta_ok "$path" || return 1
    h=$(_domconf_sha256_file "$path") || return 1
    case $'\n'"${_FMP_HASHES}" in
        *$'\n'"${h} ${base}"$'\n'*) return 0 ;;
    esac
    return 1
}

# TANINAN srvctl AÇIK ESERİ (ÜÇÜ DE tanınmalı). Yeni, gevşek bir tanıma DEĞİL: mevcut iki tanıyıcının bileşimi.
# 20-srvctl-fm-upload.conf (a) kayıtlı özetle eşleşen güvenli srvctl üretimi (_fmprov_file_matches_record: normal dosya, nlink 1, root,
# g/o yazma yok, özet kayıtta) VE (b) tanınan bir 403 kökü DEĞİL (_domconf_fm_closed_root_known; kayıttaki eski özet "kapalı"yı AÇIK saymasın).
# 90-srvctl-fm-auth.conf ve 21-srvctl-fm-download.conf için ölçüt (a)'dır (kapalı kök kavramı yok). Eksik, sembolik bağ, boş, dizin, bozuk/yabancı
# imza, ek direktifli sahte kök, bilinmeyen içerik, kurcalanmış açık şablon, yabancı sahip/mod, nlink!=1 ya da kayıtta özeti olmayan HERHANGİ BİR
# eser (20, 21 ya da 90) bu yüklemi düşürür. Önce _fmprov_load'un ayrıştırması yapılmış olmalı (küresel _FMP_HASHES). $1 = sname.
# PREDİKAT: 0 = üç eser de tanınan açık eser.
# Kapsam: ölçüt 20/21/90'ın ÜÇÜDÜR. Bu, önceki "kapsam notunu" (20 tanınıyorsa 90/21'in tek başına
# eksik/kurcalanmış olması kayıtlı parametrelerle yeniden üretimle onarılır) GEÇERSİZ KILAR: o yeniden üretim sessiz bir açma yoludur.
_fmprov_open_artifact_recognized() {
    local sname="$1" f d
    d="$(_domconf_fm_dir "$sname")"
    f="${d}/${_DOMCONF_FM_UP_FILE}"
    _fmprov_file_matches_record "$_DOMCONF_FM_UP_FILE" "$f" || return 1
    if _domconf_fm_closed_root_known "$f" "$sname" "$_FMP_HASHES"; then return 1; fi
    _fmprov_file_matches_record "$_DOMCONF_FM_AUTH_FILE" "${d}/${_DOMCONF_FM_AUTH_FILE}" || return 1
    _fmprov_file_matches_record "$_DOMCONF_FM_DL_FILE" "${d}/${_DOMCONF_FM_DL_FILE}" || return 1
    return 0
}

# Tanıma ayrıntısı (yalnız ileti için): $1 ad $2 yol → "tanınan" | "EKSİK" | "TANINMAYAN". _FMP_HASHES yüklü olmalı. Salt-okur.
_fmprov_art_word() {
    local base="$1" path="$2"
    if [[ ! -e "$path" && ! -L "$path" ]]; then printf 'EKSİK'; return 0; fi
    if _fmprov_file_matches_record "$base" "$path"; then printf 'tanınan'; else printf 'TANINMAYAN'; fi
}

# Kaydı küresel _FMP_* değişkenlerine yükler (hiçbir şey doğrulanmadan KULLANILMAZ).
# rc 0=yüklendi, 1=kayıt yok, 2=güvenilmez/bozuk (STATE-UNTRUSTED).
_fmprov_load() {
    local sname="$1" man
    _fmprov_reset
    _fmprov_state_ok "$sname" || return 2
    man=$(_fmprov_manifest "$sname")
    [[ -e "$man" ]] || return 1
    _fmprov_parse_manifest "$man" || return 2
    # acil kapatma işareti varken 'on' kaydı KAPALI sayılır (bkz. _fmprov_emergency_marker). İşaret iki
    # konumdan birinde olabilir; işaret yoksa bile "kayıt on + diskte yalnız srvctl 403 kökü" KAPALI kanıtıdır.
    # _FMP_EMERGENCY: 0 = yok | 1 = işaret | 2 = işaret yok, diskin kendisi kapalı (kanıt) | 3 = işaret yok, disk kapalı
    # GÖRÜNÜMLÜ (kanıt değil: alan otomatik AÇILMAZ) | 4 = kayıt 'on' ama 20-srvctl-fm-upload.conf
    # TANINAN bir srvctl AÇIK eseri DEĞİL (eksik, yapısal sahte kök, bilinmeyen içerik …) YA DA 21/90'dan biri eksik/kurcalanmış/kayıtla
    # eşleşmiyor (ÜÇÜ DE tanınmalı): alan otomatik AÇILMAZ, 403 kökü yazılır; kayıtlı parametreyle sessiz yeniden üretim YOK.
    # Her sınıfta kayıt 'off' sayılır; yalnız açık 'fm-auth on' alanı açar (otomatik yollar YALNIZ kapatma yönünde değiştirir).
    if _fmprov_emergency_present "$sname"; then
        _FMP_EMERGENCY=1
        _FMP_STATE="off"
    elif [[ "$_FMP_STATE" == "on" ]] && _fmprov_closed_evidence "$sname"; then
        _FMP_EMERGENCY=2
        _FMP_STATE="off"
    elif [[ "$_FMP_STATE" == "on" ]] && _fmprov_closed_lookalike_evidence "$sname"; then
        _FMP_EMERGENCY=3
        _FMP_STATE="off"
    elif [[ "$_FMP_STATE" == "on" ]] && ! _fmprov_open_artifact_recognized "$sname"; then
        _FMP_EMERGENCY=4
        _FMP_STATE="off"
    fi
    return 0
}

# Sınıf 4 (kayıt 'on' + 20/21/90'dan biri TANINAN bir srvctl AÇIK eseri değil): son _fmprov_load sonucuna bakar. PREDİKAT: 0 = sınıf 4.
_fmprov_is_class4() {
    [[ "${_FMP_EMERGENCY:-0}" == "4" ]]
}

# Kaydı yazar: $1 sname $2 state $3 region $4 script $5 php $6 modsec $7 özet satırları ("hex ad\n"...).
_fmprov_write() {
    local sname="$1" state="$2" region="$3" script="$4" php="$5" modsec="$6" hashes="$7"
    local dir man tmp line
    dir=$(_fmprov_dir); man=$(_fmprov_manifest "$sname")
    tmp=$(mktemp "${dir}/.${sname}.XXXXXX") || return 1
    {
        printf 'srvctl-fm-auth-manifest v1\n'
        printf 'state %s\n' "$state"
        printf 'region %s\n' "$region"
        printf 'script %s\n' "$script"
        printf 'php_version %s\n' "$php"
        printf 'modsec %s\n' "$modsec"
        printf 'tpl_ver %s\n' "$_DOMCONF_FM_TPL_VER"
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then printf 'sha256 %s\n' "$line"; fi
        done <<< "$hashes"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f -- "$tmp" "$man" || { rm -f -- "$tmp"; return 1; }
    return 0
}

# Üretilmiş mi? (alt kabukta: küresel _FMP_* durumunu BOZMAZ). 0=evet.
_fmprov_is_generated() {
    (
        local sname="$1" path="$2" base h
        base="${path##*/}"
        _fmprov_known_name "$base" || exit 1
        _fmprov_load "$sname" || exit 1
        _fmprov_file_matches_record "$base" "$path" && exit 0
        # acil kapatma işareti varken (kayıt eşitlenemedi) srvctl'in 403 kökü de "üretilmiş" sayılır —
        # yoksa kendi acil kökü kullanıcı dosyası/ihlal görünürdü.
        if [[ "${_FMP_EMERGENCY:-0}" != "0" && "$base" == "$_DOMCONF_FM_UP_FILE" ]]; then
            _fmprov_file_meta_ok "$path" || exit 1
            h=$(_domconf_sha256_file "$path") || exit 1
            [[ "$h" == "$(_domconf_sha256_text "$(_domconf_fm_render_off "$sname")")" ]] && exit 0
            # önceki/gelecek tpl_ver imzalı ya da eski imzasız srvctl 403 kökü de srvctl üretimidir.
            _domconf_fm_closed_root_known "$path" "$sname" "$_FMP_HASHES" && exit 0
        fi
        exit 1
    )
}

# Kayıtlı parametrelerle (küresel _FMP_*) bir dosyanın TAZE render'ının özeti.
_fmprov_fresh_hash() {
    local sname="$1" name="$2" text
    if [[ "$_FMP_STATE" == "on" ]]; then
        case "$name" in
            "$_DOMCONF_FM_AUTH_FILE") text=$(_domconf_fm_render_auth "$sname" "$_FMP_PHP" "$_FMP_SCRIPT" "$_FMP_MODSEC") || return 1 ;;
            "$_DOMCONF_FM_DL_FILE")   text=$(_domconf_fm_render_download "$sname") || return 1 ;;
            "$_DOMCONF_FM_UP_FILE")   text=$(_domconf_fm_render_upload "$_FMP_REGION" "$_FMP_MODSEC" "$sname") || return 1 ;;
            *) return 1 ;;
        esac
    else
        [[ "$name" == "$_DOMCONF_FM_UP_FILE" ]] || return 1
        text=$(_domconf_fm_render_off "$sname") || return 1
    fi
    _domconf_sha256_text "$text"
}

# Dosya durumu: OK | STALE | TAMPERED | EKSIK. Önce _fmprov_load çağrılmış olmalı.
_fmprov_file_state() {
    local sname="$1" name="$2" path="$3" fresh cur
    if [[ ! -e "$path" && ! -L "$path" ]]; then echo EKSIK; return 0; fi
    if ! _fmprov_is_generated "$sname" "$path"; then echo TAMPERED; return 0; fi
    fresh=$(_fmprov_fresh_hash "$sname" "$name") || { echo STALE; return 0; }
    cur=$(_domconf_sha256_file "$path") || { echo TAMPERED; return 0; }
    if [[ "$cur" == "$fresh" ]]; then echo OK; else echo STALE; fi
    return 0
}

# Kilit bekleme süresi (sn). Varsayılan 30. Normal 'off' denemesi 10 sn (SRVCTL_FM_OFF_LOCK_WAIT); acil kapatmanın kilit
# aşaması disk ve nginx ZATEN kapatıldıktan sonra kilidi alana dek BEKLER: üst sınır SRVCTL_FM_EMERGENCY_LOCK_WAIT,
# varsayılan 60 sn (bkz. _domconf_fm_auth_off_emergency).
_FMP_LOCK_WAIT=30
# Son _fmprov_with_lock çağrısı kilidi ZAMAN AŞIMINDAN kaybetti mi (1) — "eşzamanlı yazıcı var" ile "kayıt
# dizini güvenilmez / flock yok" (yazıcı olamaz, hepsi reddedilir) ayrımı için.
_FMP_LOCK_TIMED_OUT=0
# kilit bekleme ortam değişkeni doğrulaması (SRVCTL_FM_EMERGENCY_LOCK_WAIT ve SRVCTL_FM_OFF_LOCK_WAIT AYNI kural).
# Geçerli: 1-4 haneli onluk tamsayı (0 = beklemeden dene; 9999 üst sınır). Tanımsız/boş → varsayılan (sessiz). Geçersiz
# (negatif, 'abc', 5+ hane, ondalık, boşluklu) → varsayılan + uyarı (flock -w'ye çöp gitmesin; "kilit alınamadı" yanılsaması
# yaratmasın). $1 değişken adı, $2 varsayılan; stdout: kullanılacak değer.
_domconf_fm_lock_wait_env() {
    local name="$1" def="$2" val
    val="${!name-}"
    if [[ -z "$val" ]]; then printf '%s' "$def"; return 0; fi
    if [[ "$val" =~ ^[0-9]{1,4}$ ]]; then printf '%s' "$val"; return 0; fi
    warn "${name}='${val}' geçersiz (0-9999 sn bekleniyor) — varsayılan ${def} sn kullanılıyor" >&2
    printf '%s' "$def"
}

# Üretilmiş dosyalar için serileştirme kilidi: ${SRVCTL_STATE_DIR}/_fm-auth/.lock.
# "$@" kilit altında çalışır; dönüşü onun dönüşüdür. flock yoksa FAIL-CLOSED (yazım yok).
_fmprov_with_lock() {
    local dir lf rc=0
    _FMP_LOCK_TIMED_OUT=0
    _fmprov_prepare_dir || return 1
    dir=$(_fmprov_dir); lf="${dir}/.lock"
    if [[ -L "$lf" ]]; then
        warn "kilit dosyası sembolik bağ: ${lf} — reddedildi"
        return 1
    fi
    if ! command -v flock >/dev/null 2>&1; then
        warn "flock bulunamadı — fm-auth yazımı eşzamanlılık koruması olmadan YAPILMAZ (util-linux kurun)"
        return 1
    fi
    ( umask 077; : >> "$lf" ) || return 1
    exec 8>>"$lf" || return 1
    if ! flock -w "${_FMP_LOCK_WAIT}" 8; then
        exec 8>&-
        _FMP_LOCK_TIMED_OUT=1
        warn "fm-auth kilidi ${_FMP_LOCK_WAIT} sn içinde alınamadı (başka bir srvctl işlemi çalışıyor): ${lf}"
        return 1
    fi
    "$@" || rc=$?
    exec 8>&-
    return $rc
}

# Yarım işlem yedekleri. _fmprov_bk_list <sname>: bu alanın .bk.<sname>.XXXXXX dizinleri;
# _fmprov_bk_legacy_list: eski biçim .bk.XXXXXX (sahibi BİLİNEMEZ — yalnız raporlanır). Salt-okur;
# stdout: satır başına bir yol.
_fmprov_bk_list() {
    local sname="$1" d f
    d=$(_fmprov_dir)
    [[ -d "$d" && ! -L "$d" ]] || return 0
    for f in "$d"/.bk."${sname}".??????; do
        if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
    done
    return 0
}

_fmprov_bk_legacy_list() {
    local d f
    d=$(_fmprov_dir)
    [[ -d "$d" && ! -L "$d" ]] || return 0
    for f in "$d"/.bk.??????; do
        if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
    done
    return 0
}

# Bu alanın yarım işlem yedeği SAYISI (stdout; yedek yoksa 0). Salt-okur.
_fmprov_bk_count() {
    local sname="$1" bks n=0
    bks=$(_fmprov_bk_list "$sname")
    if [[ -n "$bks" ]]; then n=$(grep -c . <<< "$bks"); fi
    printf '%s' "$n"
}

# kenara ayrılmış (.superseded.bk.*) yedekler. _fmprov_superseded_list <sname>: bu alanınkiler
# (".superseded.bk.<sname>.*"); <sname> boşsa HEPSİ. Salt-okur; stdout: satır başına bir yol.
# POLİTİKA (en katı, SİLMEYEN): kod bu yedekleri ASLA okumaz/geri yüklemez ve OTOMATİK SİLMEZ (adli
# kanıt: bir kapatmanın üstüne yazılan açık-durum kopyası). Yalnız 'domain remove' alanın kendi
# yedeklerini siler (_domconf_fm_auth_forget_locked); gerisini operatör inceleyip elle siler.
# status / nginx-audit / fm-root planı varlıklarını SAYAR; alan başına _FMP_SUPERSEDED_WARN'ı aşınca
# birikme UYARI olur (bir 'off' çağrısı kesinti başına en çok bir yedek ayırır; eşik üstü = tekrarlayan
# kesinti ya da el yazısı bir sorun işareti).
_FMP_SUPERSEDED_WARN=5
_fmprov_superseded_list() {
    local sname="${1:-}" d f pat
    d=$(_fmprov_dir)
    [[ -d "$d" && ! -L "$d" ]] || return 0
    if [[ -n "$sname" ]]; then pat=".superseded.bk.${sname}."; else pat=".superseded.bk."; fi
    for f in "$d"/.superseded.bk.*; do
        if [[ -e "$f" || -L "$f" ]]; then
            case "${f##*/}" in
                "${pat}"*) printf '%s\n' "$f" ;;
            esac
        fi
    done
    return 0
}

# Tek satırlık not (stdout; ayrılmış yedek yoksa BOŞ). $1=sname ("" = tüm alanlar). Salt-okur.
_fmprov_superseded_note() {
    local sname="${1:-}" lst n names warnpart=""
    lst=$(_fmprov_superseded_list "$sname")
    [[ -n "$lst" ]] || return 0
    n=$(grep -c . <<< "$lst")
    names=$(sed 's#.*/##' <<< "$lst" | tr '\n' ' ' | sed 's/ $//')
    if (( n > _FMP_SUPERSEDED_WARN )); then
        warnpart=" — SAYI EŞİĞİ (${_FMP_SUPERSEDED_WARN}) AŞILDI: tekrarlayan kesinti/yarım işlem var, nedenini araştırın"
    fi
    printf '%s adet ayrılmış (.superseded.bk.*) yarım işlem yedeği [%s]: adli kayıttır, srvctl bunları OKUMAZ, geri yüklemez ve otomatik SİLMEZ; inceleyip gereksizse elle silin (alan silinirse "domain remove" kendi yedeklerini siler)%s' \
        "$n" "$names" "$warnpart"
    return 0
}

# Yarım işlem yedeğini GERİ YÜKLEMEDEN kenara ayırır (silmez — adli): .bk.<sname>.XXXXXX →
# .superseded.bk.<sname>.XXXXXX (kayıt dizini içinde; _fmprov_bk_list/_legacy_list glob'larına UYMAZ,
# yani status/audit/kurtarma onu artık "yarım işlem" saymaz). Yeni ad _FMP_SUPERSEDED'e yazılır. rc 0/1.
_FMP_SUPERSEDED=""
_fmprov_bk_supersede() {
    local b="${1:-}" d nm
    _FMP_SUPERSEDED=""
    [[ -n "$b" && "${b##*/}" == .bk.* && -d "$b" && ! -L "$b" ]] || return 1
    d="${b%/*}"; nm=".superseded${b##*/}"
    if [[ -e "${d}/${nm}" || -L "${d}/${nm}" ]]; then nm="${nm}.$$.${RANDOM}"; fi
    [[ ! -e "${d}/${nm}" && ! -L "${d}/${nm}" ]] || return 1
    mv -- "$b" "${d}/${nm}" 2>/dev/null || return 1
    [[ ! -e "$b" && ! -L "$b" ]] || return 1
    _FMP_SUPERSEDED="${d}/${nm}"
    return 0
}

# YARIM-İŞLEM YEDEĞİNİN ÖN DURUMU GERİ YÜKLENEBİLİR Mİ. Kurtarma (ve fm-root/repair planı) yedeği YALNIZ ön durum
# bir srvctl eseriyse geri koyar: (i) yedekte manifest yok: 90/21 yok (geri yükleme FM adlarını kaldırır ya da kayıtsız kullanıcı
# 20'sini koyar; açık srvctl eseri üretmez) | (ii) manifest 'off': 90/21 yok ve 20 yok ya da tanınan 403 kökü (yedeğin kendi özetleriyle) |
# (iii) manifest 'on': yedekteki 20 TANINAN AÇIK eser (kayıtlı özetle eşleşen güvenli üretim, 403 kökü değil) VE 90 ile 21 de yedeğin
# kendi kaydıyla eşleşen güvenli üretim (üçü de tanınmalı). Başka her şey (bozuk
# manifest, tanınmayan 20, yedekte 90/21'li 'off', ...) geri YÜKLENMEZ: yedek adli olarak ayrılır. ALT KABUKTA koşar (küresel _FMP_* bozulmaz).
# $1 yedek dizini $2 sname. PREDİKAT: 0 = geri yüklenebilir.
_fmprov_bk_restore_allowed() {
    (
        local bk="$1" sname="$2" n
        _fmprov_reset
        if [[ ! -e "${bk}/manifest" && ! -L "${bk}/manifest" ]]; then
            for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
                if [[ -e "${bk}/${n}" || -L "${bk}/${n}" ]]; then exit 1; fi
            done
            # Kayıtsız (manifestsiz) yedekteki 20 AÇIK imzalı / belirsiz ise (auth_request | srvctl-fm-open | proxy_pass,
            # sembolik bağ, normal dosya değil) geri YÜKLENMEZ: kayıt + 90/21 olmadan açık 20 koymak "kayıtsız yarım-açık" üretir
            # (geri yükleme mevcut kaydı ve 90/21'i siler). Açık eser yalnız kayıt + 90/21 + 20 TUTARLI ise (aşağıdaki 'on' dalı) geri gelir.
            if _domconf_fm_disk_open_or_unknown "$bk"; then exit 1; fi
            exit 0
        fi
        [[ -f "${bk}/manifest" && ! -L "${bk}/manifest" ]] || exit 1
        _fmprov_parse_manifest "${bk}/manifest" || exit 1
        if [[ "$_FMP_STATE" == "off" ]]; then
            for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
                if [[ -e "${bk}/${n}" || -L "${bk}/${n}" ]]; then exit 1; fi
            done
            [[ -e "${bk}/${_DOMCONF_FM_UP_FILE}" || -L "${bk}/${_DOMCONF_FM_UP_FILE}" ]] || exit 0
            _domconf_fm_closed_root_known "${bk}/${_DOMCONF_FM_UP_FILE}" "$sname" "$_FMP_HASHES"
            exit $?
        fi
        _fmprov_file_matches_record "$_DOMCONF_FM_UP_FILE" "${bk}/${_DOMCONF_FM_UP_FILE}" || exit 1
        _domconf_fm_closed_root_known "${bk}/${_DOMCONF_FM_UP_FILE}" "$sname" "$_FMP_HASHES" && exit 1
        # Yedekteki 90 ve 21 de yedeğin kendi kaydındaki özetle eşleşmeli (ÜÇÜ DE tanınan açık eser); aksi geri YÜKLENMEZ.
        for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
            _fmprov_file_matches_record "$n" "${bk}/${n}" || exit 1
        done
        exit 0
    )
}

# BİRDEN ÇOK (>=2) YARIM-İŞLEM YEDEĞİ: hangisinin doğru olduğu bilinemez, ikisi de GERİ YÜKLENMEZ — ama alan AÇIK
# BIRAKILMAZ: sınıf 4 ile hizalı olarak kayıt 'off' sayılır ve alan 403 köküne KAPATILIR (sınıf 4 ile aynı yazım yolu: _domconf_fm_apply
# off; kayıtsız / kapalı kayıtlı / açık alan fark etmez). Yedeklere DOKUNULMAZ: geri yüklenmez, ayrılmaz (.superseded), taşınmaz, silinmez,
# yeniden adlandırılmaz (kapatma yazımı KENDİ geçici yedeğini kullanır ve onu siler; eldeki ikiliyi tanımaz). Diskte KAPALI-DİSK KANITI zaten
# varsa (90/21 yok + 20 srvctl'in tanınan 403 kökü) yazım YAPILMAZ (gereksiz nginx -t / reload yok). Dönüş HER ZAMAN 1: işlem tamamlanmış
# sayılmaz, operatör yedekleri inceleyip elle kaldırmalıdır ("elle inceleyin"). Kapatılamazsa ileti "FM HÂLÂ AÇIK OLABİLİR" der.
# Kilit altında çağrılır. $1 domain $2 sname $3 reload (0|1; varsayılan 0: çağıran yeniden yükler).
_FMP_MBK_SPOKE=0
_fmprov_multi_bk_close_locked() {
    local domain="$1" sname="$2" reload="${3:-0}" dir bks lrc=0 rg="eu" sc="-" ph="-" ms="0" rc=0
    _FMP_MBK_SPOKE=1
    dir=$(_domconf_fm_dir "$sname")
    bks=$(_fmprov_bk_list "$sname")
    warn "birden çok yarım işlem yedeği (${domain}): $(tr '\n' ' ' <<< "$bks")— otomatik kurtarma YAPILMADI, elle inceleyin. Yedeklere DOKUNULMAZ (geri yüklenmez, ayrılmaz, silinmez); alan KAPATILIR (kayıt 'off' sayılır, 403 kökü). Yedekleri incelemeyi bitirince: 'srvctl domain fm-auth ${domain} off' bu yedeklerin hepsini geri yüklemeden ayırır (kapatmayı geri açmaz); 'fm-root --apply' ise birden çok yedekte yine rc 1 verir"
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        warn "alan KAPATILAMADI (${domain}): köken kaydı güvenilmez (STATE-UNTRUSTED) — FM HÂLÂ AÇIK OLABİLİR; yedeklere dokunulmadı. Yapılacak: kayıt dizinini root:root 0700 yapın; ya da: srvctl domain fm-auth ${domain} off --emergency"
        return 1
    fi
    if _domconf_fm_disk_closed_proof "$dir" "$sname"; then
        warn "alan zaten KAPALI (${domain}): 90/21 yok, ${_DOMCONF_FM_UP_FILE} srvctl'in 403 kökü — kapatma yazımı gerekmedi; yedeklere dokunulmadı, elle inceleyin. Yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' açar"
        return 1
    fi
    if (( lrc == 0 )); then rg="$_FMP_REGION"; sc="$_FMP_SCRIPT"; ph="$_FMP_PHP"; ms="$_FMP_MODSEC"; fi
    _domconf_fm_apply "$domain" "$sname" off "$rg" "$sc" "$ph" "$ms" "$reload" || rc=$?
    case "$rc" in
        0) warn "alan 403 köküne KAPATILDI (${domain}; kayıt 'off', 90/21 kaldırıldı)$([[ "$reload" == "1" ]] || printf ' — nginx yeniden yüklemesi çağırana aittir'): birden çok yarım işlem yedeği duruyor ve DOKUNULMADI — elle inceleyin. Yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' yeniden açar" ;;
        3) printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2
           warn "alan KAPATILAMADI (${domain}): nginx -t BAŞARISIZ — dosya+kayıt geri alındı, reload YAPILMADI — FM HÂLÂ AÇIK OLABİLİR (yedeklere dokunulmadı, elle inceleyin). Yapılacak: srvctl domain fm-auth ${domain} off --emergency" ;;
        5) warn "alan diskte KAPATILDI (${domain}) ama nginx reload BAŞARISIZ — çalışan nginx eski yapılandırmayla sürüyor: FM HÂLÂ AÇIK OLABİLİR (yedeklere dokunulmadı, elle inceleyin). Yapılacak: 'nginx -t' sonra 'systemctl reload nginx'" ;;
        6) warn "alan KAPATILAMADI (${domain}) VE GERİ ALMA BAŞARISIZ — FM HÂLÂ AÇIK OLABİLİR; geçici yedek: ${_FMA_KEEP_BK:-?} (iki asıl yedeğe dokunulmadı, elle inceleyin). Yapılacak: srvctl domain fm-auth ${domain} off --emergency" ;;
        *) warn "alan KAPATILAMADI (${domain}): render/yazım/köken kaydı hatası — geri alındı — FM HÂLÂ AÇIK OLABİLİR (yedeklere dokunulmadı, elle inceleyin). Yapılacak: srvctl domain fm-auth ${domain} off --emergency" ;;
    esac
    return 1
}

# Kilit altında: bu alanın yarım işlem yedeğini kesinti ÖNCESİ haline geri yükler (dosyalar + kayıt).
# Önceki durum o an 'nginx -t'den geçmiş bilinen-iyi durumdur; ardından çağıran normal akışı
# (kök kur / yeniden üret) yeniden değerlendirir. Reload YAPMAZ.
# KAYIT DURUMU KAPALI İSE yedek GERİ YÜKLENMEZ — kurtarma operatörün kapatmasını (ya da
# kesintiye uğrayan bir kapatmayı) asla geri açamaz. Yedek silinmez, '.superseded.' adıyla ayrılır
# (adli); diskteki dosyalar çağıranın yeniden değerlendirmesine kalır (kayda göre: KAPALI → 90/21 kalkar,
# 403 kökü yenilenir). Kayıt güvenilmezse (STATE-UNTRUSTED) hiçbir şey geri yüklenmez.
# rc 0 = kalıntı yoktu / geri yüklendi / kapalı kayıt nedeniyle ayrıldı | 1 = birden çok kalıntı /
# güvenilmez kayıt / geri yükleme başarısız (yedek KORUNUR). Birden çok kalıntıda alan KAPATILIR (bkz. _fmprov_multi_bk_close_locked;
# $3 = reload 0|1), rc yine 1.
_fmprov_recover_locked() {
    local domain="$1" sname="$2" dir b n lrc=0
    dir=$(_domconf_fm_dir "$sname")
    n=$(_fmprov_bk_count "$sname")
    (( n > 0 )) || return 0
    if (( n > 1 )); then
        # Otomatik kurtarma YOK ama alan KAPATILIR, iki yedek DOKUNULMAZ; rc her zaman 1.
        _fmprov_multi_bk_close_locked "$domain" "$sname" "${3:-0}"
        return 1
    fi
    b=$(_fmprov_bk_list "$sname")
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        warn "yarım işlem yedeği geri yüklenemedi (${domain}): köken kaydı güvenilmez (STATE-UNTRUSTED) — yedek KORUNDU: ${b}"
        _domconf_fm_untrusted_loud "$domain" "$sname" "kurtarma/kapatma"
        return 1
    fi
    if (( lrc == 0 )) && [[ "$_FMP_STATE" == "off" ]]; then
        if _fmprov_bk_supersede "$b"; then
            _DOMCONF_FM_WROTE=1
            warn "yarım işlem yedeği (${domain}) GERİ YÜKLENMEDİ: kayıt durumu KAPALI — kapatma kurtarmayla geri açılmaz; yedek adli olarak ayrıldı (${_FMP_SUPERSEDED##*/}); diskteki dosyalar kayda göre yeniden değerlendirilecek"
            return 0
        fi
        warn "yarım işlem yedeği ayrılamadı (${domain}) — yedek KORUNDU: ${b}"
        return 1
    fi
    # Kurtarma YALNIZ kapatma yönünde değiştirir — ön durum tanınan bir srvctl eseri değilse yedek geri yüklenmez.
    if ! _fmprov_bk_restore_allowed "$b" "$sname"; then
        if _fmprov_bk_supersede "$b"; then
            _DOMCONF_FM_WROTE=1
            warn "yarım işlem yedeği (${domain}) GERİ YÜKLENMEDİ: ön durum tanınan bir srvctl eseri değil (tanınmayan/eksik ${_DOMCONF_FM_UP_FILE}, bozuk kayıt ya da 90/21'li kapalı kayıt) — kurtarma açık yapılandırma üretmez; yedek adli olarak ayrıldı (${_FMP_SUPERSEDED##*/}); diskteki dosyalar kayda göre yeniden değerlendirilecek"
            return 0
        fi
        warn "yarım işlem yedeği ayrılamadı (${domain}) — yedek KORUNDU: ${b}"
        return 1
    fi
    _domconf_fm_tx_reset
    _FMT_BK=("$b"); _FMT_SNAME=("$sname"); _FMT_DIR=("$dir")
    if _domconf_fm_restore_entry 0; then
        _domconf_fm_bk_drop "$b"
        _domconf_fm_tx_reset
        # Diskteki dosyalar değişti: çalışan nginx (belki yarım durumu yüklemiş) çağıranın reload'unu bekler.
        _DOMCONF_FM_WROTE=1
        warn "kesintiye uğramış FM yazımı (${domain}) kesinti ÖNCESİ haline geri yüklendi (yedek: ${b##*/})"
        return 0
    fi
    _domconf_fm_tx_reset
    warn "yarım işlem yedeği geri yüklenemedi (${domain}) — yedek KORUNDU: ${b}"
    return 1
}

# Kayıt YOKKEN diskte duran rezerve FM adları (sarkan bağ dahil). _FMX_PRESENT: "ad ad " (sondaki
# boşluklu), _FMX_FIRST: ilk ad. PREDİKAT: 0 = en az bir ad var. (6 kopya döngü tek yerde.)
_FMX_PRESENT=""; _FMX_FIRST=""
_domconf_fm_reserved_present() {
    local dir="$1" n
    _FMX_PRESENT=""; _FMX_FIRST=""
    for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE" "$_DOMCONF_FM_UP_FILE"; do
        if [[ -e "${dir}/${n}" || -L "${dir}/${n}" ]]; then
            _FMX_PRESENT+="${n} "
            if [[ -z "$_FMX_FIRST" ]]; then _FMX_FIRST="$n"; fi
        fi
    done
    [[ -n "$_FMX_PRESENT" ]]
}

# Kayıt (önce _fmprov_load 0 dönmüş olmalı) ile FM dosyaları SAĞLAM mı? off: 20 OK ve 90/21 diskte
# YOK; on: 90/21/20 OK. Durumlar _FMR_STATES'e yazılır. PREDİKAT.
_FMR_STATES=""
_domconf_fm_files_ok() {
    local sname="$1" dir="$2" s90 s21 s20
    s20=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_UP_FILE" "${dir}/${_DOMCONF_FM_UP_FILE}")
    if [[ "$_FMP_STATE" == "off" ]]; then
        _FMR_STATES="20=${s20}"
        if [[ -e "${dir}/${_DOMCONF_FM_AUTH_FILE}" || -L "${dir}/${_DOMCONF_FM_AUTH_FILE}" || -e "${dir}/${_DOMCONF_FM_DL_FILE}" || -L "${dir}/${_DOMCONF_FM_DL_FILE}" ]]; then
            _FMR_STATES+=" 90/21=kayıt-dışı"
            return 1
        fi
        [[ "$s20" == "OK" ]]
        return
    fi
    s90=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_AUTH_FILE" "${dir}/${_DOMCONF_FM_AUTH_FILE}")
    s21=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_DL_FILE" "${dir}/${_DOMCONF_FM_DL_FILE}")
    _FMR_STATES="90=${s90} 21=${s21} 20=${s20}"
    [[ "$s90" == "OK" && "$s21" == "OK" && "$s20" == "OK" ]]
}

# /_fm 403 kökü SAĞLAM mı (karantina/denetim kapısı): kayıt güvenilir+yüklü, yarım işlem yedeği yok
# ve 20 srvctl üretimi (kayıtla eşleşen; STALE kabul — yine srvctl'in dosyası). PREDİKAT.
_domconf_fm_root_intact() {
    local sname="$1" dir="$2"
    _fmprov_state_ok "$sname" || return 1
    [[ -z "$(_fmprov_bk_list "$sname")" ]] || return 1
    _fmprov_load "$sname" || return 1
    _fmprov_is_generated "$sname" "${dir}/${_DOMCONF_FM_UP_FILE}"
}

# ───────────────────────────────────────────────────────────────
#  Şablon render'ı (üç dosya + 403 kökü). Tüm token'lar doğrulanır; beslenmeyen
#  '{{...}}' kalırsa RET (rc 2). Pcloud ana makinesi YALNIZ sabit tablodan gelir.
# ───────────────────────────────────────────────────────────────
# PREDİKAT: 0=geçerli. Allowlist: /current/modules/<Modül>/Auth/<ad>.php —
# '.', '..', '//', public/, writable/, public_html/ vb. YAPISAL olarak eşleşmez.
_domconf_fm_auth_script_ok() {
    [[ "$1" =~ ^/current/modules/[A-Za-z0-9_-]+/Auth/[A-Za-z0-9_-]+\.php$ ]]
}

# Bölge → pCloud API ana makinesi (SABİT TABLO; başka değer ret, host başka yerden okunmaz).
_domconf_fm_region_host() {
    case "${1:-}" in
        eu) printf 'eapi.pcloud.com' ;;
        us) printf 'api.pcloud.com' ;;
        *)  return 1 ;;
    esac
}

_domconf_fm_modsec_line() {
    if [[ "$1" == "1" ]]; then printf 'modsecurity off;'; else printf '# ModSecurity yüklü değil'; fi
}

_domconf_fm_tpl_dir() {
    printf '%s/nginx' "${SRVCTL_TEMPLATES:-${SRVCTL_ROOT}/templates}"
}

# $1=sname $2=php $3=script $4=modsec(0|1)
_domconf_fm_render_auth() {
    local sname="$1" php="$2" script="$3" modsec="$4" rendered
    assert_safe_ident "$sname" || return 1
    assert_php_version "$php" || return 1
    _domconf_fm_auth_script_ok "$script" || return 1
    assert_regex_safe "$script" || return 1
    [[ "$modsec" == "0" || "$modsec" == "1" ]] || return 1
    rendered=$(render_template "$(_domconf_fm_tpl_dir)/fm-auth.conf.tpl" \
        "SAFE_NAME=${sname}" "PHP_VERSION=${php}" "AUTH_SCRIPT=${script}" \
        "MODSEC_LINE=$(_domconf_fm_modsec_line "$modsec")") || return 1
    [[ "$rendered" != *'{{'* ]] || return 2
    printf '%s' "$rendered"
}

# $1=region(eu|us) $2=modsec $3=sname (gövde imzası için)
_domconf_fm_render_upload() {
    local region="$1" modsec="$2" sname="${3:-}" host rendered sig
    host=$(_domconf_fm_region_host "$region") || return 1
    assert_regex_safe "$host" || return 1
    [[ "$modsec" == "0" || "$modsec" == "1" ]] || return 1
    sig=$(_domconf_fm_body_sig "$sname") || return 1
    rendered=$(render_template "$(_domconf_fm_tpl_dir)/fm-upload.conf.tpl" \
        "PCLOUD_HOST=${host}" "MODSEC_LINE=$(_domconf_fm_modsec_line "$modsec")" "FM_SIG=${sig}") || return 1
    [[ "$rendered" != *'{{'* ]] || return 2
    printf '%s' "$rendered"
}

# $1=sname
_domconf_fm_render_download() {
    local sname="$1" rendered
    assert_safe_ident "$sname" || return 1
    rendered=$(render_template "$(_domconf_fm_tpl_dir)/fm-download.conf.tpl" \
        "SAFE_NAME=${sname}") || return 1
    [[ "$rendered" != *'{{'* ]] || return 2
    printf '%s' "$rendered"
}

# 'off' kökü: yükleme yolunu FAIL-CLOSED 403 yapar (kullanıcı dosyası olamaz: köken kayıtlı).
# $1=sname: gövde BU alana özgü imzayı taşır (`srvctl-fm-closed <sig>`; sonda yalnız bunu KAPALI sayar).
# sname güvensizse rc 1 ve çıktı YOK (çağıran boş dosya yazmamalı).
_domconf_fm_render_off() {
    local sig
    sig=$(_domconf_fm_body_sig "${1:-}") || return 1
    printf '%s\n' \
        '# srvctl: FileManager yükleme yolu KAPALI (srvctl domain fm-auth <alan> off). SRVCTL ÜRETİR.' \
        "# Bu 403 kökü, /_fm/ yolunun CI4'e düşmesini engeller; açmak için: fm-auth <alan> on --script=..." \
        "location = /_fm { return 403 \"srvctl-fm-closed ${sig}\"; }" \
        "location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${sig}\"; }" \
        "# '/__fm_' ad alanı yakalayıcısı: alan kapalıyken uygulama X-Accel-Redirect ile '/__fm_dl'e (ya da bir auth alt isteği '/__fm_auth'a)" \
        "# yönlendirirse istek CI4'e düşmez (iç istek 403 alır, dışarıdan gelen 'internal' gereği 404 alır)." \
        'location ^~ /__fm_ { internal; return 403; }'
}

# fm-auth dosyalarında bu alanın BETİĞİNİN host karşılığı güvenli mi?
# Sıra: ÖNCE -L (betiğin kendisi sembolik bağ olamaz), SONRA gerçek yol
# (dizin sembolik bağları çözülür) alanın KENDİ ağacında kalmalı. Dosya henüz
# yoksa 0 (çağıran "deploy sonrası var olmalı" uyarır).
# PREDİKAT: 0=temiz/yok, 1=reddedildi (neden stdout'a).
_domconf_fm_auth_host_script_check() {
    local domain="$1" script="$2"
    local host="${WEB_ROOT}/${domain}${script}"
    [[ -e "$host" || -L "$host" ]] || return 0
    if [[ -L "$host" ]]; then
        echo "betik sembolik bağ: ${host}"
        return 1
    fi
    local rb rd
    rb=$(cd "${WEB_ROOT}/${domain}" 2>/dev/null && pwd -P) || { echo "alan dizini çözülemedi: ${WEB_ROOT}/${domain}"; return 1; }
    rd=$(cd "$(dirname "$host")" 2>/dev/null && pwd -P) || { echo "betik dizini çözülemedi: $(dirname "$host")"; return 1; }
    case "${rd}/" in
        "${rb}/"*) return 0 ;;
    esac
    echo "betiğin gerçek yolu alanın ağacı DIŞINDA: ${rd} (alan: ${rb}) — sembolik bağ ile başka dizine yönlendirme"
    return 1
}

# Atomik yazım: aynı dizinde geçici dosya + mv (yarım/kesik dosya nginx'e
# ASLA görünmez). Geçici ad '*.conf' glob'una UYMAZ.
# mktemp dosyayı 0600 üretir → chmod 644 GERÇEKTEN gereklidir (testte umask 077).
_domconf_atomic_write() {
    local dest="$1" content="$2" tmp
    # Hedefin dizini sembolik bağsa yazım bağı izler ve kiracının dizinine düşer: ret (son savunma; asıl kapı _domconf_fm_dir_trusted).
    [[ ! -L "$(dirname "$dest")" ]] || return 1
    tmp=$(mktemp "${dest}.srvctl.XXXXXX") || return 1
    if printf '%s\n' "$content" > "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$dest"; then
        return 0
    fi
    rm -f -- "${tmp:?}"
    return 1
}

# ───────────────────────────────────────────────────────────────
#  YAZIM ÇEKİRDEĞİ — İŞLEM (bir ya da birden çok alan; 'fm-root --all' tek işlemde toplar):
#  her alan için render → yedek → manifest (aşama 1: eski+yeni özet) → dosyalar; sonra TEK
#  nginx -t → manifest (aşama 2: yalnız yeni). Hata/sinyal → işlemdeki TÜM alanların
#  dosyaları + kayıtları GERİ.
#
#  Sıra (fail-closed, yarım durumda yol AÇIK kalmaz):
#    on : 90 (auth) → 21 (indirme) → 20 (yükleme) EN SON
#    off: 20'yi 403 köküyle DEĞİŞTİR → sonra 90/21 (ve eski .inc) sil
#  Yedek dizini: $(_fmprov_dir)/.bk.<sname>.XXXXXX — hangi alana ait olduğu adından
#  bellidir; kesinti (SIGKILL/güç) sonrası status/nginx-audit/repair/fm-root bunu görür ve
#  kurtarır. 'nginx -t' çıktısı _DOMCONF_NGX_T_OUT'a girer. Reload yalnız $8=1 ise.
#  Dönüş: 0 ok | 3 nginx -t hatası (geri alındı) | 4 render/yazım/kayıt hatası (geri alındı)
#         | 5 reload hatası (config geçerli) | 6 GERİ ALMA BAŞARISIZ (yedek diskte kalır)
#         | 7 ModSecurity yetenek tespiti yapılamadı (hiçbir şey yazılmadı; apply_detect)
# ───────────────────────────────────────────────────────────────
_DOMCONF_NGX_T_OUT=""
_FMA_KEEP_BK=""
# İşlem kayıtları (indis = sahneleme sırası). _FMT_ARGS: "state|region|script|php|modsec"
# (script allowlist'i '|' içeremez).
_FMT_BK=(); _FMT_SNAME=(); _FMT_DIR=(); _FMT_NEWH=(); _FMT_OLDH=(); _FMT_ARGS=(); _FMT_DOMAIN=()
# Bu süreçte en az bir FM işlemi kayıt aşama 2'ye ulaştı mı (repair --all tek reload için).
_DOMCONF_FM_WROTE=0

_domconf_fm_tx_reset() {
    _FMT_BK=(); _FMT_SNAME=(); _FMT_DIR=(); _FMT_NEWH=(); _FMT_OLDH=(); _FMT_ARGS=(); _FMT_DOMAIN=()
    _FMA_KEEP_BK=""
}

# Yedekteki bir öğeyi hedefe KOPYALAYARAK geri koyar (geçici ad + mv: hedef hiçbir an yarım görünmez).
# Yedek ASLA tüketilmez: geri yükleme ortada ölürse ikinci çağrı AYNI sonucu verir (
# eski mv-tabanlı geri yükleme yedekten çıkardığı dosyayı ikinci turda "yedekte yok" sayıp SİLERDİ).
_domconf_fm_restore_file() {
    local src="$1" dst="$2" tmp
    # hedef dizin YA DA dizine sembolik bağ ise reddet ('mv -f' bağı izler, dosya hedef dizinin
    # İÇİNE '<ad>.srvctl-rs.*' olarak düşer ve sahte başarı döner). '-d' bağı izlediği için ikisini de kapsar.
    if [[ -d "$dst" ]]; then return 1; fi
    tmp="${dst}.srvctl-rs.$$.${RANDOM}"
    if [[ -e "$tmp" || -L "$tmp" ]]; then return 1; fi
    if cp -pP -- "$src" "$tmp" && mv -f -- "$tmp" "$dst"; then return 0; fi
    rm -f -- "${tmp:?}"
    return 1
}

# İşlemdeki i. girdiyi yedeğinden geri yükler (yedek korunur; İDEMPOTENT). rc 0/1.
_domconf_fm_restore_entry() {
    local i="$1" n rc=0 bk dir sname man
    bk="${_FMT_BK[i]:-}"; dir="${_FMT_DIR[i]:-}"; sname="${_FMT_SNAME[i]:-}"
    if ! [[ -n "$bk" && -d "$bk" && -n "$dir" && -n "$sname" ]]; then
        # Yedek yok/geçersiz olsa da İŞARETLİ alanın diski KOŞULSUZ kapatılır (geri yüklenecek bir şey yok ama
        # acil kapatma işareti var: yazıcının AÇIK yazdığı 90/21/20 diskte KALMAMALI). Kapatma monotondur/idempotenttir.
        if [[ -n "$dir" && -n "$sname" ]] && _fmprov_emergency_present "$sname"; then
            _domconf_fm_em_close_disk "$dir" "$sname" || true
        fi
        return 1
    fi
    # Hedef dizin işlem sürerken sembolik bağa / yabancı dizine çevrildiyse geri yükleme ONA yazmaz: alan kapatılır (kapatma
    # yolu girdiyi kenara alıp root sahipli 403 kökü kurar) ve geri alma BAŞARISIZ sayılır.
    if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        warn "geri yükleme custom.d/${sname} dizinine YAZILMADI: ${_FMD_WHY} — alan kapatılıyor"
        _domconf_fm_em_close_disk "$dir" "$sname" || true
        return 1
    fi
    for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE" "$_DOMCONF_FM_UP_FILE" "$_DOMCONF_FM_LEGACY_INC"; do
        if [[ -e "${bk}/${n}" || -L "${bk}/${n}" ]]; then
            _domconf_fm_restore_file "${bk}/${n}" "${dir}/${n}" || rc=1
        else
            rm -f -- "${dir:?}/${n:?}" || rc=1
        fi
    done
    man=$(_fmprov_manifest "$sname")
    if [[ -e "${bk}/manifest" ]]; then
        _domconf_fm_restore_file "${bk}/manifest" "$man" || rc=1
    else
        rm -f -- "${man:?}" || rc=1
    fi
    # Yedeğin ön durumu tanınan bir srvctl eseri DEĞİLSE (kayıt 'on' + tanınmayan 20: yapısal sahte kök, açık
    # imzalı vekil ...) ve geri konan disk AÇIK / belirsizse, geri alma o sahte AÇIK kökü diske bırakmaz: disk KAPATILIR
    # (403 kökü, 90/21 kalkar; yalnız kapatma yönü). Kapatılamazsa rc 1 (çağıran "FM HÂLÂ AÇIK OLABİLİR" der).
    if ! _fmprov_bk_restore_allowed "$bk" "$sname" && _domconf_fm_disk_open_or_unknown "$dir"; then
        _domconf_fm_em_close_disk "$dir" "$sname" || rc=1
    fi
    # yedek, acil kapatmadan ÖNCEKİ (açık olabilen) durumu taşır. İşlem sürerken bir acil kapatma işareti
    # konduysa geri alma kapatmayı GERİ AÇMAZ: dosyalar yedekten döndükten sonra disk yeniden KAPATILIR (monoton,
    # idempotent). İşaret yoksa davranış değişmez.
    if _fmprov_emergency_present "$sname"; then
        _domconf_fm_em_close_disk "$dir" "$sname" || rc=1
    fi
    return $rc
}

# İşlemdeki TÜM girdileri (sondan başa) geri yükler. rc 0 = hepsi geri geldi.
_domconf_fm_restore_from_bk() {
    local i rc=0
    (( ${#_FMT_BK[@]} > 0 )) || return 1
    for (( i = ${#_FMT_BK[@]} - 1; i >= 0; i-- )); do
        _domconf_fm_restore_entry "$i" || rc=1
    done
    return $rc
}

# Yedek dizinini siler (boş/yanlış değerde HİÇBİR şey silmez).
_domconf_fm_bk_drop() {
    local bk="${1:-}"
    [[ -n "$bk" && "${bk##*/}" == .bk.* ]] || return 0
    rm -rf -- "${bk:?}"
}

_domconf_fm_tx_drop_bks() {
    local b
    for b in "${_FMT_BK[@]+"${_FMT_BK[@]}"}"; do _domconf_fm_bk_drop "$b"; done
    _FMT_BK=(); _FMT_SNAME=(); _FMT_DIR=(); _FMT_NEWH=(); _FMT_OLDH=(); _FMT_ARGS=(); _FMT_DOMAIN=()
}

# GERİ ALMA SONRASI KAPATMA DOĞRULAMASI. Acil kapatma işareti olan bir alanın geri alması (kapı reddi: tx_commit rc 4,
# nginx -t hatası, sahneleme reddi) yedeği (AÇIK olabilen eski durum) diske geri koyup SONRA diski yeniden kapatır
# (_domconf_fm_restore_entry). O pencerede üçüncü bir taraf reload'u (acilin kendisi, certbot kancası, başka srvctl komutu) AÇIK
# yapılandırmayı çalışan nginx'e YÜKLEMİŞ olabilir; disk kapandı diye çalışan durum kapanmaz. Bu yüzden geri alma, diski
# kapattıktan sonra nginx'i yeniden yükler ve çalışan durumu sınar: KAPALI imzası → bilgi; AÇIK / doğrulanamadı → "FM HÂLÂ AÇIK"
# (rc≠0: çağıranın kodu zaten 3/4/6'dır, hiçbir dalda 0 dönmez). Geri alma BAŞARISIZsa (rc 6) disk kapalı doğrulanamadığı için
# reload YAPILMAZ (yarım diski yüklememek için); yalnız sınanır ve söylenir. $1 = geri alma rc, kalan argümanlar = alanlar.
# _FMRV_CTX iletideki bağlamı söyler ("geri alma" = kapı reddi; "sinyal kesintisi geri alması" = INT/TERM/HUP).
_FMRV_CTX="geri alma"

# KAPALI-DİSK KANITI. PREDİKAT: 0 = $1 (custom.d/<sname> dizini) altında 90/21 YOK ve 20 srvctl'in tanınan 403
# kökü (_domconf_fm_closed_root_known; kayıtlı özet gerekmez). Geri alma sonrası "disk yeniden KAPATILDI" demenin ve
# nginx'i yeniden yüklemenin TEK koşulu budur; yedeğin varlığı/geri yükleme rc'si bunun kanıtı DEĞİLDİR. Salt-okur.
_domconf_fm_disk_closed_proof() {
    local dir="$1" sname="$2" n
    for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
        if [[ -e "${dir}/${n}" || -L "${dir}/${n}" ]]; then return 1; fi
    done
    _domconf_fm_closed_root_known "${dir}/${_DOMCONF_FM_UP_FILE}" "$sname" ""
}

# KAYIT GÜVENİLMEZKEN (STATE-UNTRUSTED) YAZIM YAPILMAZ (değişmez) AMA alan AÇIK olabiliyorsa ileti bunu söyler.
# Kayıt dizini güvenilmezken kapatma yazımı (403 kökü, kayıt 'off') yapılamaz: eskiden ileti yalnız "kayıt dizinini root:root 0700 yapın" derdi
# ve alanın hâlâ açık olabileceğini SÖYLEMEZDİ. Kural: diskte KAPALI-DİSK KANITI (90/21 yok + 20 srvctl'in tanınan 403 kökü) YOKSA ileti
# "FM HÂLÂ AÇIK OLABİLİR" der + çözüm (kayıt dizinini root:root 0700 yap; ya da 'fm-auth <alan> off --emergency' — o yol kayıttan bağımsızdır);
# kanıt VARSA alanın diskte KAPALI göründüğünü söyler ("AÇIK OLABİLİR" DENMEZ: doğru olan dal bozulmaz). Salt-okur; hiçbir şey yazmaz,
# hiçbir şey çalıştırmaz. Dönüş HER ZAMAN 0 (rc kararı çağıranın). $1 domain $2 sname $3 yapılamayan iş (ileti öznesi).
_domconf_fm_untrusted_loud() {
    local domain="$1" sname="$2" what="${3:-yazım}"
    if _domconf_fm_disk_closed_proof "$(_domconf_fm_dir "$sname")" "$sname"; then
        warn "${domain}: ${what} YAPILAMADI: köken kaydı güvenilmez (STATE-UNTRUSTED) — kayıt güvenilmezken hiçbir şey yazılmaz; diskte KAPALI kanıtı var (90/21 yok, ${_DOMCONF_FM_UP_FILE} srvctl'in 403 kökü; çalışan nginx bu yoldan doğrulanmadı). Yapılacak: kayıt dizinini root:root 0700 yapın"
    else
        warn "FM HÂLÂ AÇIK OLABİLİR — ${domain}: ${what} YAPILAMADI: köken kaydı güvenilmez (STATE-UNTRUSTED) — kayıt güvenilmezken hiçbir şey yazılmaz (disk ve kayıt DEĞİŞMEDİ) ve diskte KAPALI kanıtı yok (90/21 duruyor ya da ${_DOMCONF_FM_UP_FILE} tanınan 403 kökü değil). Yapılacak: kayıt dizinini root:root 0700 yapın; ya da kayıttan bağımsız kapatın: srvctl domain fm-auth ${domain} off --emergency"
    fi
    return 0
}

# Geri alma sonrası doğrulanacak alanlar (işlem tablosu DİSKE dokunmadan ÖNCE okunmalı). Koşul: (a) acil kapatma işareti var
# YA DA (b) 'on' sahneleyen girdinin yedeğinde AUTH (90) yoktu ama diskte şimdi VAR (açık yazım: işaretsiz alan dahil).
# (a) alanlar KAPALI OLMAK ZORUNDADIR (kanıt yoksa alarm); (b) alanlar "YUMUŞAK"tır: önceki durum kapalı idiyse (geri alma
# sonrası kapalı-disk kanıtı var) tam doğrulama yapılır; kanıt yoksa önceki durum zaten AÇIK/yarımdı (ör. açık alanın onarımı):
# SESSİZ ATLANMAZ (bkz. _domconf_fm_reclose_verify: disk açıksa dürüst uyarı, değilse çalışan durum sondalanır). Sonuç: _FMRV_LIST (alan adları), _FMRV_SOFT (yumuşak alanlar, boşlukla ayrık).
# apply_abort ve fail_restore AYNI kuralı kullanır.
_FMRV_LIST=(); _FMRV_SOFT=" "
_domconf_fm_tx_verify_list() {
    local i st
    _FMRV_LIST=(); _FMRV_SOFT=" "
    for (( i = 0; i < ${#_FMT_SNAME[@]}; i++ )); do
        [[ -n "${_FMT_DOMAIN[i]:-}" ]] || continue
        st="${_FMT_ARGS[i]%%|*}"
        if _fmprov_emergency_present "${_FMT_SNAME[i]}"; then
            _FMRV_LIST+=("${_FMT_DOMAIN[i]}")
        elif [[ "$st" == "on" && -e "${_FMT_DIR[i]}/${_DOMCONF_FM_AUTH_FILE}" ]]; then
            # Yedeğinde 90 OLSA DA (yetim 90 + kapalı kök = yarım/TAMPERED önceki durum) açık yazılmış alan listeye girer.
            _FMRV_LIST+=("${_FMT_DOMAIN[i]}"); _FMRV_SOFT+="${_FMT_DOMAIN[i]} "
        elif [[ -n "${_FMT_BK[i]:-}" && -d "${_FMT_BK[i]}" ]] && ! _fmprov_bk_restore_allowed "${_FMT_BK[i]}" "${_FMT_SNAME[i]}"; then
            # Ön durum tanınan bir srvctl eseri değil (kayıt 'on' + tanınmayan 20 vb.): yazıcı kapatma yönünde
            # çalıştığı için st 'off' görünür ama geri alma bu ön durumu diske koyabilir (restore_entry açıksa yeniden KAPATIR).
            # Alan YUMUŞAK listeye girer: sonuç her zaman söylenir (kapalı kaldı / yeniden KAPATTI / FM HÂLÂ AÇIK OLABİLİR).
            _FMRV_LIST+=("${_FMT_DOMAIN[i]}"); _FMRV_SOFT+="${_FMT_DOMAIN[i]} "
        fi
    done
}

# YUMUŞAK ALANDA DİSK AÇIK MI / BELİRSİZ Mİ. PREDİKAT: 0 = açık ya da belirsiz (90/21 var, 20 sembolik bağ / normal dosya
# değil / okunamıyor, ya da 20 AÇIK imzalı: auth_request | srvctl-fm-open | proxy_pass) → reload YAPILMAZ; 1 = 90/21 yok ve 20 yok ya da
# açık imzasız (tanınan kök olması şart DEĞİL: tanınmayan ama 403 veren yapısal kök dahil) → reload güvenli, çalışan durum sondalanır. Salt-okur.
_domconf_fm_disk_open_or_unknown() {
    local dir="$1" n f="$1/${_DOMCONF_FM_UP_FILE}"
    for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
        if [[ -e "${dir}/${n}" || -L "${dir}/${n}" ]]; then return 0; fi
    done
    [[ -L "$f" ]] && return 0
    [[ -e "$f" ]] || return 1
    [[ -f "$f" && -r "$f" ]] || return 0
    if grep -Eq 'auth_request|srvctl-fm-open|proxy_pass' "$f" 2>/dev/null; then return 0; fi
    return 1
}

# Kanıtsız ama diski açık OLMAYAN yumuşak alanın sonucu. $1 domain $2/$3 reload ÖNCESİ sonda (durum, ayrıntı) $4 tür: C = 20 var
# (çalışan durum KAPALI imzası vermeli) | N = disk boş (90/21/20 yok: yalnız çalışan AÇIK olmamalı). nginx reload'u ÇAĞIRAN yapmıştır
# (_FME_RELOAD = ok | failed | skipped | notneeded). Dönüş 0 = tamam | 1 = KAPALI doğrulanamadı (ya da N'de çalışan AÇIK).
_domconf_fm_reclose_soft_one() {
    local d="$1" st="$2" det="$3" kind="$4" ok=0
    if [[ "$_FME_RELOAD" == "ok" ]]; then
        _domconf_fm_runtime_probe_settled "$d"; st="$_FMRT_STATE"; det="$_FMRT_DETAIL"
    fi
    if [[ "$st" == "closed" ]]; then ok=1
    elif [[ "$kind" == "N" && "$st" != "open" ]]; then ok=2
    fi
    if (( ok == 1 )); then
        info "${_FMRV_CTX} sonrası ${d}: disk AÇIK DEĞİL (90/21 yok, ${_DOMCONF_FM_UP_FILE} tanınan srvctl kökü değil; reload: ${_FME_RELOAD}) — çalışan durum KAPALI imzası (403)"
        return 0
    elif (( ok == 2 )); then
        info "${_FMRV_CTX} sonrası ${d}: disk BOŞ (90/21/20 yok); çalışan durumda AÇIK imzası yok (sonda: ${st}; reload: ${_FME_RELOAD})"
        return 0
    fi
    _domconf_fm_em_fail "FM HÂLÂ AÇIK OLABİLİR — ${_FMRV_CTX} sonrası ${d}: disk AÇIK DEĞİL (90/21 yok) ama çalışan durum KAPALI doğrulanamadı (sonda: ${st}; reload: ${_FME_RELOAD}; ${det}). Yapılacak: 'nginx -t' sonra 'systemctl reload nginx'; ardından: srvctl domain fm-auth ${d} off --emergency ; srvctl domain fm-auth ${d} status"
    return 1
}

# Bir alanın geri alma sonrası sonuç bildirimi: $1 domain $2 geri alma rc ("" = 0) $3 kapalı-disk kanıtı (0|1). nginx
# reload'u ÇAĞIRAN (_domconf_fm_reclose_verify) yapmıştır (_FME_RELOAD). Dönüş 0 = kapanış doğrulandı (kanıt + reload ok +
# sonda KAPALI) | 1 = çalışan durum KAPALI doğrulanmadı | 2 = KAPALI-DİSK KANITI YOK (ileti basıldı: FM HÂLÂ AÇIK / OLABİLİR).
_domconf_fm_reclose_one() {
    local d="$1" rrc="$2" proof="$3" vrc=0
    if [[ "$_FME_RELOAD" == "ok" ]]; then _domconf_fm_runtime_probe_settled "$d"; else _domconf_fm_runtime_probe "$d"; fi
    if (( ! proof )); then
        _domconf_fm_em_fail "FM HÂLÂ AÇIK OLABİLİR — ${_FMRV_CTX} sonrası ${d}: diskte KAPALI KÖK KANITI YOK (90/21 duruyor ya da ${_DOMCONF_FM_UP_FILE} tanınan 403 kökü değil${rrc:+; geri yükleme rc ${rrc}}) — nginx yeniden YÜKLENMEDİ (yarım/AÇIK disk çalışan nginx'e yüklenmesin); $(_domconf_fm_em_running_line). Yapılacak: srvctl domain fm-auth ${d} off --emergency ; srvctl domain fm-auth ${d} status"
        return 2
    fi
    case "$_FMRT_STATE" in
        closed)
            if [[ "$_FME_RELOAD" == "ok" ]]; then
                info "${_FMRV_CTX} alanı yeniden KAPATTI (kapalı-disk kanıtı var: 90/21 yok, 403 kökü tanındı): ${d} — nginx yeniden yüklendi, çalışan durum KAPALI imzası (403)"
            else
                _domconf_fm_em_fail "${_FMRV_CTX} sonrası ${d}: disk KAPALI (kanıtlı) ve çalışan nginx KAPALI imzası veriyor AMA nginx yeniden yüklenemedi (reload: ${_FME_RELOAD}) — disk ile çalışan yapılandırma ayrışık olabilir: kapanış DOĞRULANMIŞ SAYILMAZ; 'srvctl domain fm-auth ${d} status'"
                vrc=1
            fi ;;
        open)
            _domconf_fm_em_fail "FM HÂLÂ AÇIK — ${_FMRV_CTX} sonrası ${d}: çalışan nginx hâlâ yüklemeye izin veriyor (disk KAPALI kanıtlı, reload: ${_FME_RELOAD}; ${_FMRT_DETAIL}). Yapılacak: 'nginx -t' sonra 'systemctl reload nginx'; ardından: srvctl domain fm-auth ${d} off --emergency"
            vrc=1 ;;
        *)
            _domconf_fm_em_fail "${_FMRV_CTX} sonrası ${d}: çalışan durum DOĞRULANAMADI (reload: ${_FME_RELOAD}; ${_FMRT_DETAIL}) — 'doğrulanamadı' KAPALI SAYILMAZ: FM HÂLÂ AÇIK OLABİLİR. Yapılacak: srvctl domain fm-auth ${d} off ; srvctl domain fm-auth ${d} status"
            vrc=1 ;;
    esac
    return $vrc
}

# $1 = geri alma rc, kalan = alanlar. Dönüş 0 = hepsi doğrulandı | 1 = çalışan durum en az bir alanda KAPALI doğrulanmadı |
# 2 = en az bir alanda KAPALI-DİSK KANITI yok (çağıran fail_restore bu durumda rc 6 verir; sinyal yolunda çıkış kodu zaten ≠ 0).
# KARAR: reload + settled sonda YALNIZ kapalı-disk kanıtı tutuyorsa yapılır — rrc≠0 (geri yükleme başarısız)
# olsa da. nginx reload'u host geneldir: HERHANGİ bir alanda kanıt yoksa reload YAPILMAZ (o alanın yarım/AÇIK diski çalışan
# nginx'e yüklenmesin); yalnız sonda yapılır ve ileti "FM HÂLÂ AÇIK OLABİLİR" der.
# YUMUŞAK alan (işaretsiz açık yazım) artık SESSİZCE ATLANMAZ: (P) kapalı-disk kanıtı var → reload + settled sonda;
# (C) kanıt yok ama diskte 90/21 yok ve 20 açık imzalı değil (tanınmayan ama 403 veren yapısal kök) → çalışan durum SONDALANIR, AÇIK/bilinmiyorsa
# reload + settled sonda, kapanmazsa "FM HÂLÂ AÇIK OLABİLİR" (rc 1); (O) disk AÇIK/belirsiz → reload YOK + "FM HÂLÂ AÇIK OLABİLİR" (rc 1;
# önceki durum zaten açıktı, çağıranın 3/4 kodu ve nginx -t iletisi korunur). Hard alan (acil işareti, X) kanıtsızsa rc 2 (değişmedi).
_domconf_fm_reclose_verify() {
    local rrc="$1" d sn bad=0 all=1 r need=0 i; shift
    local -a kinds=() pst=() pdet=()
    (( $# > 0 )) || return 0
    if [[ "$rrc" == "0" ]]; then rrc=""; fi
    for d in "$@"; do
        sn=$(safe_name "$d")
        if _domconf_fm_disk_closed_proof "$(_domconf_fm_dir "$sn")" "$sn"; then
            kinds+=(P); need=1
        elif [[ "$_FMRV_SOFT" == *" ${d} "* ]] && ! _domconf_fm_disk_open_or_unknown "$(_domconf_fm_dir "$sn")"; then
            # Yumuşak alan, kapalı-disk KANITI yok ama diskte 90/21 yok ve 20 açık imzalı değil (tanınmayan ama
            # 403 veren yapısal kök): reload güvenlidir ve ÇALIŞAN durum SONDALANIR — sessiz atlama yok.
            # 20 yoksa (N: disk BOŞ — ör. hiç kurulmamış alanın başarısız ilk 'on'u) /_fm için hiçbir konum yoktur: "KAPALI imzası" beklenmez;
            # reload yalnız çalışan durum AÇIK ise gerekir. 20 varsa (C) çalışan durum KAPALI imzası vermeli, vermiyorsa reload.
            _domconf_fm_runtime_probe "$d"; pst+=("$_FMRT_STATE"); pdet+=("$_FMRT_DETAIL")
            if [[ -e "$(_domconf_fm_dir "$sn")/${_DOMCONF_FM_UP_FILE}" ]]; then
                kinds+=(C); if [[ "$_FMRT_STATE" != "closed" ]]; then need=1; fi
            else
                kinds+=(N); if [[ "$_FMRT_STATE" == "open" ]]; then need=1; fi
            fi
            continue
        else
            # kanıt yok VE (hard alan | yumuşak alanda disk AÇIK/belirsiz): reload YOK (yarım/AÇIK disk yüklenmesin). Hard alan = acil
            # işareti var (kapalı OLMAK ZORUNDA) → rc 2; yumuşak alan = önceki durum zaten AÇIK/yarımdı → dürüst uyarı, rc 1 (çağıranın 3/4 kodu
            # ve nginx -t hata iletisi korunur).
            if [[ "$_FMRV_SOFT" == *" ${d} "* ]]; then kinds+=(O); else kinds+=(X); fi
            all=0
        fi
        pst+=(""); pdet+=("")
    done
    if (( ! all )); then _FME_RELOAD="skipped"
    elif (( need )); then _domconf_fm_em_reload
    else _FME_RELOAD="notneeded"; fi
    i=0
    for d in "$@"; do
        r=0
        case "${kinds[i]}" in
            P) _domconf_fm_reclose_one "$d" "$rrc" 1 || r=$? ;;
            X) _domconf_fm_reclose_one "$d" "$rrc" 0 || r=$? ;;
            O) _domconf_fm_reclose_one "$d" "$rrc" 0 || r=$?; if (( r == 2 )); then r=1; fi ;;
            C|N) _domconf_fm_reclose_soft_one "$d" "${pst[i]}" "${pdet[i]}" "${kinds[i]}" || r=$? ;;
        esac
        if (( r > bad )); then bad=$r; fi
        i=$((i + 1))
    done
    return $bad
}

# Hata dalı: işlemi geri al, yedekleri sil, tuzağı kaldır; GERİ ALMA başarısızsa 6 (aksi halde verilen kod).
# (Geri yükleme dönüşü denetlenmezse yüklenemese de "geri alındı" denirdi.)
# Acil kapatma işareti olan alan(lar) için geri alma sonrası nginx yeniden yüklenir ve çalışan durum sınanır.
# Sinyal tuzağı (INT/TERM/HUP) geri alma VE yeniden kapatma doğrulaması BİTENE KADAR `:` olarak kalır
# (_domconf_fm_apply_abort ile AYNI koruma): reclose sırasında gelen ikinci sinyal süreci iletisiz öldüremez; tuzak yalnız
# her çıkış yolunda, en sonda kaldırılır. Doğrulama listesi işaretsiz alanda da "açık yazım" koluyla kurulur
# (_domconf_fm_tx_verify_list). Doğrulanamayan kapanış (kapalı-disk kanıtı yok / çalışan AÇIK ya da bilinmiyor)
# koşulsuz rc 6 verir — çağıranın kodu (3/4) "geri alındı" izlenimi vermesin.
_domconf_fm_fail_restore() {
    local code="$1" rrc=0 vrc=0
    local -a reclosed=()
    trap ':' INT TERM HUP
    _domconf_fm_tx_verify_list
    reclosed=("${_FMRV_LIST[@]+"${_FMRV_LIST[@]}"}")
    _domconf_fm_restore_from_bk || rrc=$?
    if (( rrc != 0 )); then
        # Yedek(ler) DİSKTE KALIR (elle kurtarma için): silinmez.
        _FMA_KEEP_BK="${_FMT_BK[*]+"${_FMT_BK[*]}"}"
        _FMT_BK=(); _FMT_SNAME=(); _FMT_DIR=(); _FMT_NEWH=(); _FMT_OLDH=(); _FMT_ARGS=(); _FMT_DOMAIN=()
        _domconf_fm_reclose_verify "$rrc" "${reclosed[@]+"${reclosed[@]}"}" || true
        trap - INT TERM HUP
        return 6
    fi
    _domconf_fm_tx_drop_bks
    _domconf_fm_reclose_verify 0 "${reclosed[@]+"${reclosed[@]}"}" || vrc=$?
    trap - INT TERM HUP
    if (( vrc == 2 )); then return 6; fi
    return "$code"
}

# Sinyal tuzağı: geri al; GERİ ALMA başarılıysa yedeği sil, BAŞARISIZSA yedeği KORU; çıkış
# kodu sinyale göre: INT 130, TERM 143, HUP 129 (varsayılan 130).
# SİNYAL İPTALİ DE KAPI REDDİ GİBİ GERİ ALMA SONRASI KAPATMAYI DOĞRULAR (_domconf_fm_fail_restore ile AYNI sözleşme).
# Stage açık yazmış (90/21/20) ve nginx -t penceresinde üçüncü bir reload bu diski yüklemiş olabilir; ya da acil kapatma işareti
# vardır ve geri alma diski yeniden kapatmıştır: iki durumda da disk kapandı diye çalışan nginx kapanmaz. Bu alanlar için geri
# alma SONRASI nginx yeniden yüklenir + settled sonda; AÇIK/doğrulanamadı → "FM HÂLÂ AÇIK (OLABİLİR)" (çıkış kodu zaten sinyal
# kodu, 0 DEĞİL). Alan işaretsizse ve stage açık yazmadıysa (ör. zaten açık olan alanın onarımı, kapalı kalan alan) reload YOK.
# Temizlik sürerken gelen ikinci sinyal işlemi bölmesin diye tuzak boş işleve çevrilir (reload/sonda sınırlı zaman aşımlıdır).
_domconf_fm_apply_abort() {
    local code="${1:-130}" rrc=0
    local -a verify=()
    trap ':' INT TERM HUP   # '' DEĞİL: yok sayma çocuk süreçlere (nginx -t, curl, timeout) miras kalır; ':' exec'te sıfırlanır
    _domconf_fm_tx_verify_list
    verify=("${_FMRV_LIST[@]+"${_FMRV_LIST[@]}"}")
    _domconf_fm_restore_from_bk || rrc=$?
    if (( rrc == 0 )); then
        _domconf_fm_tx_drop_bks
    else
        if (( ${#_FMT_BK[@]} > 0 )); then
            warn "kesinti: fm-auth geri alma BAŞARISIZ — yedek diskte korunuyor: ${_FMT_BK[*]} ('srvctl domain repair <alan>' / 'srvctl domain fm-root <alan>' kurtarır)"
        else
            warn "kesinti: fm-auth geri alma BAŞARISIZ — korunan yedek kaydı yok; durumu denetleyin: 'srvctl domain fm-auth <alan> status' ('srvctl domain repair <alan>' / 'srvctl domain fm-root <alan>' kurtarır)"
        fi
    fi
    if (( ${#verify[@]} > 0 )); then
        _FMRV_CTX="sinyal kesintisi geri alması"
        _domconf_fm_reclose_verify "$rrc" "${verify[@]}" || true
        _FMRV_CTX="geri alma"
    fi
    exit "$code"
}

# SAHNELEME KAPISI. Kilit altında, diske YAZMADAN önce acil kapatma işaretini (iki konum) YENİDEN okur. Çağıran
# durumu ('on') işaretten ÖNCE okumuş olabilir (eşzamanlı acil kapatma kilidi beklerken işareti ve KAPALI diski koyar); açık
# `fm-auth <alan> on` DIŞINDAki bir eylem (repair / fm-root / php-switch / sock_sync / toplu repair / kurtarma) bu durumda
# 90/21/20'yi AÇIK yazamaz: mevcut (kapalı) diske DOKUNULMAZ. $1 domain $2 sname $3 state. PREDİKAT: 0 = geçilebilir, 1 = ret.
_domconf_fm_stage_gate() {
    local domain="$1" sname="$2" state="$3"
    [[ "$state" == "on" && "$_DOMCONF_FM_TX_ACTION" != "on" ]] || return 0
    _fmprov_emergency_present "$sname" || return 0
    # "Alan KAPALI kalır" YALNIZ diskte kapalı-kök kanıtı varsa söylenir (kanıt yoksa acil kapatma tamamlanmamış olabilir).
    if _domconf_fm_disk_closed_proof "$(_domconf_fm_dir "$sname")" "$sname"; then
        warn "acil kapatma işareti var (${sname}): 'on' durumu SAHNELENMEDİ — mevcut KAPALI diske dokunulmadı, alan KAPALI kalır; yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' yeniden açar"
    else
        warn "acil kapatma işareti var (${sname}): 'on' durumu SAHNELENMEDİ — diske dokunulmadı AMA diskte KAPALI KÖK KANITI YOK (90/21 duruyor ya da ${_DOMCONF_FM_UP_FILE} tanınan 403 kökü değil): FM HÂLÂ AÇIK OLABİLİR — 'srvctl domain fm-auth ${domain} off --emergency' ile kapatın; yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' yeniden açar"
    fi
    return 1
}

# YERİNDE DİZİN (yabancı nesne). 20/21/90 adlı bir yol DİZİN ise (sembolik bağ değil) sahneleme yedeği ('cp -pP' dizini
# kopyalamaz) alınamaz ve yazım reddedilir: srvctl yabancı nesneyi OTOMATİK taşımaz, silmez, üzerine yazmaz (kanıt + sahiplik; yeni taşıma/silme
# mekanizması YOKTUR). Kapatma yönündeki ('off') reddi SESSİZ BIRAKMAZ: "FM HÂLÂ AÇIK OLABİLİR" (çalışan nginx bu dizin yüzünden zaten
# 'nginx -t'den geçmeyen yapılandırma altında eski — belki açık — durumunu sunmaya devam eder; araç bunu değiştiremez). Çağıranın rc'si ≠ 0'dır
# (stage 4), 'status' bu durumu TAMPERED ve rc≠0 raporlar. $1 domain $2 state $3 dizin yolu. Dizin değilse HİÇBİR şey söylemez.
_domconf_fm_stage_dir_report() {
    local domain="$1" state="$2" path="$3"
    [[ -d "$path" && ! -L "$path" ]] || return 0
    if [[ "$state" == "off" ]]; then
        warn "FM HÂLÂ AÇIK OLABİLİR — ${domain}: kapatma YAPILAMADI: ${path} yerinde DİZİN (yabancı nesne) — srvctl dizini taşımaz, silmez, üzerine yazmaz; disk ve kayıt DEĞİŞMEDİ. Bu dizin 'nginx -t'yi zaten geçersiz kılabilir ve çalışan nginx eski yapılandırmayı sunmaya devam eder. Yapılacak: dizini inceleyip elle kaldırın/taşıyın, sonra: srvctl domain fm-auth ${domain} off ; srvctl domain fm-auth ${domain} status"
    else
        warn "${domain}: yazım REDDEDİLDİ: ${path} yerinde DİZİN (yabancı nesne) — srvctl dizini taşımaz, silmez, üzerine yazmaz; dizini inceleyip elle kaldırın/taşıyın"
    fi
    return 0
}

# Bir alanı işleme SAHNELER: render → yedek → kayıt aşama 1 → dosyalar (nginx -t YOK).
# $1 domain $2 sname $3 state(on|off) $4 region $5 script $6 php $7 modsec(0|1)
# Dönüş 0 | 4. Yedek oluştuktan SONRAKİ her hata için girdi işleme eklenmiştir: çağıran
# _domconf_fm_fail_restore ile (bu ve önceki girdiler dahil) geri alır.
_domconf_fm_stage() {
    local domain="$1" sname="$2" state="$3" region="$4" script="$5" php="$6" modsec="$7"
    local dir; dir=$(_domconf_fm_dir "$sname")
    local c90="" c21="" c20="" h90="" h21="" h20="" oldh="" newh="" lrc=0 n bk="" why=""

    # 0) custom.d/<sname> güven kapısı (diske HİÇBİR şey yazılmadan): sembolik bağ / yabancı sahipli dizin izlenmez.
    # Açma yönündeki her yazıcı (on, repair, provision, php-switch, fm-root) reddedilir; yalnız açık 'fm-auth off' girdiyi kenara alıp
    # root sahipli yeni dizine 403 kökü kurar (kapatma yönü; hedefe yazılmaz).
    if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        if [[ "$_DOMCONF_FM_TX_ACTION" == "off" ]]; then
            why="$_FMD_WHY"
            if _domconf_fm_dir_quarantine "$dir" "$sname"; then
                warn "${domain}: ${why} — girdi kenara alındı (${_FMD_ASIDE:-yok}); yerine root sahipli dizin + 403 kökü kuruldu, hedefe/içine yazılmadı"
            else
                warn "FM HÂLÂ AÇIK OLABİLİR — ${domain}: kapatma YAPILAMADI: ${_FMD_WHY} — girdi kenara alınamadı; hedefe YAZILMADI. Elle inceleyin: ${dir}"
                if (( _FMD_SIG != 0 )); then _domconf_fm_apply_abort "$_FMD_SIG"; fi
                return 4
            fi
            # Kenara alma sinyal korumalıdır (pencere içinde gelen INT/TERM/HUP ertelendi): işlem BÜTÜN tamamlandı, yetim dizin kalmadı;
            # şimdi sinyalin çıkış koduyla (130/143/129) temiz çık. Kayıt 'off'a eşitlenmedi: 'fm-auth <alan> off' yeniden koşulabilir.
            if (( _FMD_SIG != 0 )); then
                warn "${domain}: kesinti (sinyal ${_FMD_SIG}) kenara alma sırasında geldi — kenara alma TAMAMLANDI (alan KAPALI, yetim dizin yok); köken kaydı 'off'a eşitlenmedi: srvctl domain fm-auth ${domain} off"
                _domconf_fm_apply_abort "$_FMD_SIG"
            fi
        else
            _domconf_fm_dir_refuse "$domain" "yazım REDDEDİLDİ (${state})"
            return 4
        fi
    fi

    # 1) render (+ doğrulama)
    if [[ "$state" == "on" ]]; then
        c90=$(_domconf_fm_render_auth "$sname" "$php" "$script" "$modsec") || return 4
        c21=$(_domconf_fm_render_download "$sname") || return 4
        c20=$(_domconf_fm_render_upload "$region" "$modsec" "$sname") || return 4
        h90=$(_domconf_sha256_text "$c90") || return 4
        h21=$(_domconf_sha256_text "$c21") || return 4
        newh="${h90} ${_DOMCONF_FM_AUTH_FILE}"$'\n'"${h21} ${_DOMCONF_FM_DL_FILE}"$'\n'
    else
        c20=$(_domconf_fm_render_off "$sname") || return 4
    fi
    h20=$(_domconf_sha256_text "$c20") || return 4
    newh+="${h20} ${_DOMCONF_FM_UP_FILE}"$'\n'

    # 2) eski kayıt (iki-aşamalı geçiş için eski özetler)
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        warn "köken kaydı güvenilmez (STATE-UNTRUSTED) — yazım reddedildi"
        # Kapatma yönü ('off') yazılamadıysa alan açık olabilir — sessiz bırakılmaz (yazım yine YAPILMAZ).
        if [[ "$state" == "off" ]]; then _domconf_fm_untrusted_loud "$domain" "$sname" "kapatma"; fi
        return 4
    fi
    if (( lrc == 0 )); then oldh="$_FMP_HASHES"; fi

    # 2b) kapı A — yedek ve herhangi bir yazımdan ÖNCE işareti yeniden oku (bkz. _domconf_fm_stage_gate).
    _domconf_fm_stage_gate "$domain" "$sname" "$state" || return 4

    # 3) yedek (adı alanı taşır: .bk.<sname>.XXXXXX)
    mkdir -p "$dir" || return 4
    bk=$(mktemp -d "$(_fmprov_dir)/.bk.${sname}.XXXXXX") || return 4
    for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE" "$_DOMCONF_FM_UP_FILE" "$_DOMCONF_FM_LEGACY_INC"; do
        if [[ -e "${dir}/${n}" || -L "${dir}/${n}" ]]; then
            cp -pP -- "${dir}/${n}" "${bk}/${n}" || { _domconf_fm_bk_drop "$bk"; _domconf_fm_stage_dir_report "$domain" "$state" "${dir}/${n}"; return 4; }
        fi
    done
    if [[ -e "$(_fmprov_manifest "$sname")" ]]; then
        cp -p -- "$(_fmprov_manifest "$sname")" "${bk}/manifest" || { _domconf_fm_bk_drop "$bk"; return 4; }
    fi
    # kapı B — yedek kopyalama süresince bir acil kapatma işareti konmuş olabilir; hiçbir şey yazılmadan ve işleme
    # girdi eklenmeden (geri yüklenecek bir şey yok → kapalı diske dokunulmaz) reddet.
    _domconf_fm_stage_gate "$domain" "$sname" "$state" || { _domconf_fm_bk_drop "$bk"; return 4; }
    _FMT_BK+=("$bk"); _FMT_SNAME+=("$sname"); _FMT_DIR+=("$dir")
    _FMT_NEWH+=("$newh"); _FMT_OLDH+=("$oldh"); _FMT_ARGS+=("${state}|${region}|${script}|${php}|${modsec}"); _FMT_DOMAIN+=("$domain")
    # Kullanıcı kesintisi (INT/TERM/HUP) → işlemi geri al (yarım yapılandırma kalmasın).
    trap '_domconf_fm_apply_abort 130' INT
    trap '_domconf_fm_apply_abort 143' TERM
    trap '_domconf_fm_apply_abort 129' HUP

    # 4) kayıt aşama 1 (eski + yeni özet) → dosyalar
    _fmprov_write "$sname" "$state" "$region" "$script" "$php" "$modsec" "${newh}${oldh}" || return 4
    if [[ "$state" == "on" ]]; then
        _domconf_atomic_write "${dir}/${_DOMCONF_FM_AUTH_FILE}" "$c90" || return 4
        _domconf_atomic_write "${dir}/${_DOMCONF_FM_DL_FILE}" "$c21" || return 4
        _domconf_atomic_write "${dir}/${_DOMCONF_FM_UP_FILE}" "$c20" || return 4
        rm -f -- "${dir:?}/${_DOMCONF_FM_LEGACY_INC:?}"
    else
        _domconf_atomic_write "${dir}/${_DOMCONF_FM_UP_FILE}" "$c20" || return 4
        rm -f -- "${dir:?}/${_DOMCONF_FM_AUTH_FILE:?}" "${dir:?}/${_DOMCONF_FM_DL_FILE:?}" "${dir:?}/${_DOMCONF_FM_LEGACY_INC:?}"
    fi
    return 0
}

# nginx -t geçtikten SONRA: tüm girdilerin kaydı aşama 2 (yalnız yeni özet), kurcalanmış içerik
# adli kopyası, yedeklerin silinmesi. rc 0 | 4 (çağıran geri alır).
# ÇAĞIRAN AÇIKÇA bildirir: "on" = açık 'fm-auth on' (yalnız o, tüm kapılardan geçmiş). Acil kapatma işareti
# şu iki durumda kalkar: (a) açık 'fm-auth on' kaydı, (b) 'off' kaydı (işaretin işi 'on' kaydını geçersiz kılmaktır; kayıt
# artık 'off' ise gereksizdir ve kalırsa her repair/fm-root boşuna yeniden üretir). repair / fm-root / php-switch
# (sock_sync) / toplu repair 'on' kaydı yazarken işareti KALDIRMAZ — işaret varken 'on' kaydı hiç YAZAMAZLAR (kapı).
# "off" = açık 'fm-auth off' (yalnız o): sahneleme güvenilmeyen custom.d/<sname> girdisini kenara alıp root sahipli dizin kurabilir
# (_domconf_fm_dir_quarantine); öteki yazıcılar o girdiyi İZLEMEZ ve reddeder.
_DOMCONF_FM_TX_ACTION=""
_domconf_fm_tx_commit() {
    local i n cur st rg sc ph ms rest bk dir oldh sn
    # (1) KAPI — kilit altında, yazmadan ÖNCE işareti YENİDEN okur (stage'den sonra eşzamanlı bir acil kapatma konmuş
    # olabilir): açık 'on' dışındaki bir yazıcı 'on' kaydı yazamaz → rc 4, çağıran geri alır (geri alma diski yeniden kapatır).
    for (( i = 0; i < ${#_FMT_BK[@]}; i++ )); do
        IFS='|' read -r st rg sc ph ms rest <<< "${_FMT_ARGS[i]}"
        if [[ "$st" == "on" && "$_DOMCONF_FM_TX_ACTION" != "on" ]] && _fmprov_emergency_present "${_FMT_SNAME[i]}"; then
            warn "acil kapatma işareti var (${_FMT_SNAME[i]}): 'on' kaydı YAZILMADI — işlem geri alınıyor; geri alma alanı yeniden KAPATIR ve sonucu bildirir (kapanış doğrulanamazsa 'FM HÂLÂ AÇIK OLABİLİR' denir); yalnız açık 'srvctl domain fm-auth <alan> on --script=…' yeniden açar"
            return 4
        fi
    done
    for (( i = 0; i < ${#_FMT_BK[@]}; i++ )); do
        IFS='|' read -r st rg sc ph ms rest <<< "${_FMT_ARGS[i]}"
        _fmprov_write "${_FMT_SNAME[i]}" "$st" "$rg" "$sc" "$ph" "$ms" "${_FMT_NEWH[i]}" || return 4
        # Her commit'in işareti silmesi yanlıştı: 'on' yazan bir repair/fm-root eşzamanlı acil kapatmanın işaretini
        # silip alanı yeniden açabiliyordu. Şimdi 'on' kaydı yalnız açık 'fm-auth on' ile işareti kaldırır (başkası kapıdan
        # zaten geçemez); 'off' kaydı işareti kaldırır (kayıt zaten kapalı).
        if [[ "$st" == "off" || "$_DOMCONF_FM_TX_ACTION" == "on" ]]; then _fmprov_emergency_clear "${_FMT_SNAME[i]}"; fi
    done
    # Üzerine yazılan TAMPERED/kayıtsız içerik adli inceleme için yüklenmeyen adla saklanır.
    # srvctl'in KENDİ 403 kökü (acil kapatmanın yazdığı 20) kurcalanmış içerik DEĞİLDİR — kilit zaman aşımından
    # sonra kayıt hâlâ 'on' özetlerini taşıdığı için eskiden her fm-root --apply fazladan bir '.srvctl-tampered' bırakırdı.
    for (( i = 0; i < ${#_FMT_BK[@]}; i++ )); do
        bk="${_FMT_BK[i]}"; dir="${_FMT_DIR[i]}"; oldh="${_FMT_OLDH[i]}"; sn="${_FMT_SNAME[i]}"
        for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE" "$_DOMCONF_FM_UP_FILE"; do
            if [[ -f "${bk}/${n}" && ! -L "${bk}/${n}" ]]; then
                if [[ "$n" == "$_DOMCONF_FM_UP_FILE" ]] && _domconf_fm_closed_root_known "${bk}/${n}" "$sn" "$oldh"; then continue; fi
                cur=$(_domconf_sha256_file "${bk}/${n}" 2>/dev/null) || cur="none"
                case $'\n'"${oldh}" in
                    *$'\n'"${cur} ${n}"$'\n'*) ;;
                    *) cp -p -- "${bk}/${n}" "${dir}/${n}.srvctl-tampered" 2>/dev/null || true ;;
                esac
            fi
        done
    done
    # _DOMCONF_FM_TX_KEEP_TRAP=1 (yalnız _domconf_fm_apply): yedekler silinmeden ÖNCE tuzak ':'a çevrilir (yedeksiz kalan geri alma işleyicisi
    # "geri alma başarısız" deyip diski açık bırakırdı) ve reload bitene kadar öyle KALIR; apply reload'dan sonra kaldırır.
    if [[ "${_DOMCONF_FM_TX_KEEP_TRAP:-0}" == "1" ]]; then trap ':' INT TERM HUP; fi
    _domconf_fm_tx_drop_bks
    if [[ "${_DOMCONF_FM_TX_KEEP_TRAP:-0}" != "1" ]]; then trap - INT TERM HUP; fi
    _DOMCONF_FM_WROTE=1
    return 0
}

# $1 domain $2 sname $3 state(on|off) $4 region $5 script $6 php $7 modsec(0|1) $8 reload(0|1)
_domconf_fm_apply() {
    local reload="$8" rc=0 trc=0
    _DOMCONF_NGX_T_OUT=""
    _domconf_fm_tx_reset
    _domconf_fm_stage "$1" "$2" "$3" "$4" "$5" "$6" "$7" || rc=$?
    if (( rc != 0 )); then
        (( ${#_FMT_BK[@]} > 0 )) || return "$rc"
        _domconf_fm_fail_restore 4; return $?
    fi
    _DOMCONF_NGX_T_OUT=$(nginx -t 2>&1) || trc=$?
    if (( trc != 0 )); then
        _domconf_fm_fail_restore 3; return $?
    fi
    # Commit ile reload arasında sinyal (SSH kopması) açan süreci öldürürse disk AÇIK + kayıt 'on' + çalışan nginx yüklenmemiş kalırdı: başarısız
    # bir açılışın ara durumunun aynısı. Tuzak (':', yok sayma DEĞİL: çocuk süreçlere miras kalmaz) reload bitene kadar sürer; sonra kalkar.
    _DOMCONF_FM_TX_KEEP_TRAP=1
    _domconf_fm_tx_commit || trc=$?
    _DOMCONF_FM_TX_KEEP_TRAP=0
    if (( trc != 0 )); then
        _domconf_fm_fail_restore 4; return $?
    fi
    if [[ "$reload" == "1" ]]; then
        systemctl reload nginx >/dev/null 2>&1 || trc=$?
    fi
    trap - INT TERM HUP
    if (( trc != 0 )); then return 5; fi
    return 0
}

# ───────────────────────────────────────────────────────────────
#  ModSecurity YETENEK TESPİTİ — CANLI yapılandırmaya HİÇBİR şey yazmadan.
#  Eski yol 'modsecurity off;' varyantını custom.d'ye YAZIP 'nginx -t' deniyor, "unknown directive"
#  ise satırsız yeniden yazıyordu: arada SIGKILL/OOM/güç kesintisi = diskte host genelinde GEÇERSİZ
#  yapılandırma (köken kaydı aşama-1 özetiyle "AÇIK" derdi). Yeni yol: köken kayıt dizini altında
#  (root 0700; nginx'in hiçbir include glob'u buraya bakmaz) ADAY bir dizine BAĞIMSIZ bir sonda
#  yapılandırması yazılır ve 'nginx -t -c <sonda>' çalıştırılır. Sonda yalnız: ana yapılandırmanın
#  ANA BAĞLAMDAKİ load_module satırları (yalnız root sahipli, g/o-yazılamaz dosyalardan; kiracı
#  dosyası ASLA okunmaz — custom.d http/server içinde include edilir, ana bağlamda değil) + ana
#  bağlamdaki 'user' satırı (root çalışan nginx 'user' yoksa derleme-varsayılan kullanıcı/
#  grubunu çözer, grup yoksa 'nginx -t' düşer; macOS/root-dışı çalışmada 'user' yok sayılır → bu
#  kısım yalnız Linux+root canlıda ÖLÇÜLEBİLİR) + sondanın kendi pid/geçici yolları +
#  'http { modsecurity off; }'.
#  Sonuç (_DOMCONF_MODSEC): 0 → sonda geçti: 1 | 'unknown directive "modsecurity" in <sonda>' → 0 |
#  başka her hata → rc 2 (FAIL-CLOSED: tespit yapılamadı, çağıran hiçbir FM dosyası yazmaz).
#  Yanılma yönü güvenlidir: yanlış "yok" → FM konumunda WAF AÇIK kalır (daha sıkı; yalnız akıtma
#  etkilenir, uyarı basılır); yanlış "var" → canlı 'nginx -t' reddeder ve işlem geri alınır.
#  Ana yapılandırma yolu: $SRVCTL_NGINX_CONF | 'nginx -V' --conf-path | /etc/nginx/nginx.conf.
# ───────────────────────────────────────────────────────────────
_DOMCONF_MODSEC=""
_DOMCONF_MODSEC_PROBE_OUT=""
_DOMCONF_LM=""
_DOMCONF_LM_USER=""
_DOMCONF_LM_INC=()
_DOMCONF_LM_BAD=0
_DOMCONF_PROBE_DIR=""

# Yol jetonu güvenli mi (sonda dosyasına AYNEN yazılacak): boşluk/';'/tırnak/'$'/'#'/'{}' yok.
_domconf_safe_path_tok() {
    [[ "$1" =~ ^[A-Za-z0-9_./+-]+$ ]]
}

# Dosya güvenilir mi (root sahipli zincir, g/o-yazılamaz; tek seviye sembolik bağ — ör.
# modules-enabled → modules-available — bağın dizini ve hedefin zinciri ayrıca denetlenir).
# stdout: fiziksel yol. PREDİKAT: 0=güvenilir.
_domconf_conf_trusted() {
    local f="$1" dir real t
    dir=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || return 1
    assert_root_owned_path "$dir" || return 1
    real="${dir}/$(basename "$f")"
    if [[ -L "$real" ]]; then
        t=$(readlink "$real") || return 1
        case "$t" in /*) ;; *) t="${dir}/${t}" ;; esac
        dir=$(cd "$(dirname "$t")" 2>/dev/null && pwd -P) || return 1
        real="${dir}/$(basename "$t")"
        [[ ! -L "$real" ]] || return 1
        assert_root_owned_path "$dir" || return 1
    fi
    [[ -f "$real" ]] || return 1
    assert_root_owned_path "$real" || return 1
    printf '%s' "$real"
}

_domconf_lm_cb() {
    local kind="$1"; shift 2
    (( ${#_NGX_STACK[@]} == 0 )) || return 0
    [[ "$kind" == "stmt" ]] || return 0
    case "${1:-}" in
        user)
            # Root çalışan nginx 'user' yoksa derleme-varsayılan kullanıcı/grubunu getpwnam/getgrnam
            # ile çözer (grup yoksa 'nginx -t' düşer). Sonda CANLI yapılandırmayla AYNI user'ı taşır.
            if (( $# >= 2 && $# <= 3 )) && _domconf_safe_path_tok "$2" && { (( $# == 2 )) || _domconf_safe_path_tok "$3"; }; then
                _DOMCONF_LM_USER="user ${2}${3:+ ${3}};"$'\n'
            else
                _DOMCONF_LM_BAD=1
            fi ;;
        load_module)
            if (( $# == 2 )) && _domconf_safe_path_tok "$2"; then _DOMCONF_LM+="load_module ${2};"$'\n'; else _DOMCONF_LM_BAD=1; fi ;;
        include)
            if (( $# == 2 )) && [[ "$2" =~ ^[A-Za-z0-9_./+*?-]+$ ]]; then _DOMCONF_LM_INC+=("$2"); else _DOMCONF_LM_BAD=1; fi ;;
    esac
    return 0
}

# Ana yapılandırmanın ANA BAĞLAM load_module satırlarını _DOMCONF_LM'e toplar (ana bağlam include'ları
# izlenir; en çok 32 dosya). AYNI kabukta çağrılmalı ($(...) içinde DEĞİL — küresel sonuç kaybolur).
# rc 0 toplandı | 1 doğrulanamadı (neden _DOMCONF_LM_WHY).
_DOMCONF_LM_WHY=""
_domconf_ngx_main_load_modules() {
    local main="$1" base f real p g n=0
    local -a queue=() seen_files=()
    _DOMCONF_LM=""; _DOMCONF_LM_USER=""; _DOMCONF_LM_BAD=0; _DOMCONF_LM_WHY=""
    [[ -n "$main" && -e "$main" ]] || { _DOMCONF_LM_WHY="ana yapılandırma bulunamadı: ${main:-?}"; return 1; }
    base=$(cd "$(dirname "$main")" 2>/dev/null && pwd -P) || { _DOMCONF_LM_WHY="ana yapılandırma dizini çözülemedi"; return 1; }
    queue=("$main")
    while (( ${#queue[@]} > 0 )); do
        f="${queue[0]}"; queue=("${queue[@]:1}")
        n=$((n + 1))
        (( n <= 32 )) || { _DOMCONF_LM=""; _DOMCONF_LM_WHY="ana bağlam include sayısı sınırı (32) aşıldı"; return 1; }
        real=$(_domconf_conf_trusted "$f") || { _DOMCONF_LM=""; _DOMCONF_LM_WHY="güvenilmez (root sahipli/g-o yazılamaz değil) ya da okunamaz: ${f}"; return 1; }
        case " ${seen_files[*]+"${seen_files[*]}"} " in *" ${real} "*) continue ;; esac
        seen_files+=("$real")
        _DOMCONF_LM_INC=()
        _domconf_nginx_parse "$real" _domconf_lm_cb || { _DOMCONF_LM=""; _DOMCONF_LM_WHY="çözümlenemedi: ${real} (${_NGX_ERR})"; return 1; }
        (( _DOMCONF_LM_BAD == 0 )) || { _DOMCONF_LM=""; _DOMCONF_LM_WHY="ana bağlamda güvenle yeniden üretilemeyen load_module/include: ${real}"; return 1; }
        for p in "${_DOMCONF_LM_INC[@]+"${_DOMCONF_LM_INC[@]}"}"; do
            case "$p" in /*) ;; *) p="${base}/${p}" ;; esac
            # shellcheck disable=SC2086  # glob genişlemesi KASITLI (nginx include deseni; jeton doğrulandı)
            for g in $p; do
                [[ -e "$g" || -L "$g" ]] || continue
                queue+=("$g")
            done
        done
    done
    return 0
}

_domconf_fm_probe_abort() {
    if [[ -n "${_DOMCONF_PROBE_DIR:-}" && "${_DOMCONF_PROBE_DIR##*/}" == .probe.* ]]; then rm -rf -- "${_DOMCONF_PROBE_DIR:?}"; fi
    exit "${1:-130}"
}

# SIGKILL/güç kesintisi sonda dizinini (.probe.XXXXXX) geride bırakır. Sonda fm-auth kilidi
# altında koşar → kilit sahibiyken var olan HER .probe.* dizini bayattır. Silinir ve söylenir.
# Kayıt dizini altındaki, sembolik bağ olmayan .probe.* dizinleri dışında hiçbir şeye dokunmaz.
_domconf_fm_probe_sweep() {
    local d f n=0
    d=$(_fmprov_dir)
    [[ -d "$d" && ! -L "$d" ]] || return 0
    for f in "$d"/.probe.??????; do
        [[ -d "$f" && ! -L "$f" ]] || continue
        rm -rf -- "${f:?}" && n=$((n + 1))
    done
    if (( n > 0 )); then warn "kesintiye uğramış ${n} eski ModSecurity sonda dizini (.probe.*) temizlendi"; fi
    return 0
}

# rc 0: _DOMCONF_MODSEC = 0|1 | rc 2: tespit yapılamadı (_DOMCONF_MODSEC_PROBE_OUT). Kilit altında çağrılır.
_domconf_fm_modsec_probe() {
    local v main pd tok line lm="" lmu="" out="" prc=0 nouwsgi=0 noscgi=0
    local -a toks=()
    _DOMCONF_MODSEC=""; _DOMCONF_MODSEC_PROBE_OUT=""
    v=$(nginx -V 2>&1) || true
    [[ "$v" == *--without-http_uwsgi_module* ]] && nouwsgi=1
    [[ "$v" == *--without-http_scgi_module* ]] && noscgi=1
    main="${SRVCTL_NGINX_CONF:-}"
    if [[ -z "$main" ]]; then
        while IFS= read -r line; do
            read -ra toks <<< "$line"
            for tok in "${toks[@]+"${toks[@]}"}"; do
                case "$tok" in --conf-path=*) main="${tok#--conf-path=}" ;; esac
            done
        done <<< "$v"
        main="${main:-/etc/nginx/nginx.conf}"
    fi
    if _domconf_ngx_main_load_modules "$main"; then
        lm="$_DOMCONF_LM"; lmu="$_DOMCONF_LM_USER"
    else
        warn "nginx ana yapılandırmasının load_module satırları doğrulanamadı (${_DOMCONF_LM_WHY}) — ModSecurity sondası load_module'süz koşuyor (yanılma yönü güvenli: modül 'yok' sayılırsa FM konumunda WAF açık kalır)"
        lm=""; lmu=""
    fi
    _domconf_fm_probe_sweep
    pd=$(mktemp -d "$(_fmprov_dir)/.probe.XXXXXX") || { _DOMCONF_MODSEC_PROBE_OUT="sonda dizini oluşturulamadı"; return 2; }
    _DOMCONF_PROBE_DIR="$pd"
    trap '_domconf_fm_probe_abort 130' INT
    trap '_domconf_fm_probe_abort 143' TERM
    trap '_domconf_fm_probe_abort 129' HUP
    if ! _domconf_safe_path_tok "$pd"; then
        rm -rf -- "${pd:?}"; _DOMCONF_PROBE_DIR=""; trap - INT TERM HUP
        _DOMCONF_MODSEC_PROBE_OUT="sonda dizini yolu güvenle yazılamaz: ${pd}"; return 2
    fi
    {
        printf '# srvctl ModSecurity yetenek sondası (geçici; canlı yapılandırma DEĞİL)\n'
        printf '%s' "$lm"
        printf '%s' "$lmu"
        printf 'pid %s/probe.pid;\nerror_log stderr;\nevents { }\nhttp {\n' "$pd"
        printf '    client_body_temp_path %s/cb;\n    proxy_temp_path %s/p;\n    fastcgi_temp_path %s/f;\n' "$pd" "$pd" "$pd"
        if (( nouwsgi == 0 )); then printf '    uwsgi_temp_path %s/u;\n' "$pd"; fi
        if (( noscgi == 0 )); then printf '    scgi_temp_path %s/s;\n' "$pd"; fi
        printf '    modsecurity off;\n}\n'
    } > "${pd}/probe.conf" || { rm -rf -- "${pd:?}"; _DOMCONF_PROBE_DIR=""; trap - INT TERM HUP; _DOMCONF_MODSEC_PROBE_OUT="sonda yazılamadı"; return 2; }
    out=$(nginx -t -c "${pd}/probe.conf" 2>&1) || prc=$?
    rm -rf -- "${pd:?}"; _DOMCONF_PROBE_DIR=""
    trap - INT TERM HUP
    if (( prc == 0 )); then _DOMCONF_MODSEC=1; return 0; fi
    if [[ "$out" == *'unknown directive "modsecurity" in '"${pd}/probe.conf:"* ]]; then _DOMCONF_MODSEC=0; return 0; fi
    _DOMCONF_MODSEC_PROBE_OUT="$out"
    return 2
}

# ModSecurity yeteneği CANLI dosyalara yazmadan sondayla belirlenir, sonra TEK uygulama.
# 'off' (403 kökü) modsec satırı içermez: sonda koşmaz, kayıtlı değer korunur.
# $1 domain $2 sname $3 state $4 region $5 script $6 php $7 reload [$8 off için kayıtlı modsec]
_domconf_fm_apply_detect() {
    local domain="$1" sname="$2" state="$3" region="$4" script="$5" php="$6" reload="$7" modsec="${8:-0}" rc=0
    if [[ "$state" == "on" ]]; then
        if ! _domconf_fm_modsec_probe; then
            _DOMCONF_NGX_T_OUT="$_DOMCONF_MODSEC_PROBE_OUT"
            return 7
        fi
        modsec="$_DOMCONF_MODSEC"
        if [[ "$modsec" == "0" ]]; then
            warn "ModSecurity modülü yüklü değil (nginx: unknown directive \"modsecurity\") — 'modsecurity off' satırları yazılmadı"
        fi
    fi
    [[ "$modsec" == "0" || "$modsec" == "1" ]] || modsec=0
    _domconf_fm_apply "$domain" "$sname" "$state" "$region" "$script" "$php" "$modsec" "$reload" || rc=$?
    return $rc
}

# apply dönüş kodunu operatör hatasına çevirir (rc 0 değilse EXIT).
_domconf_fm_apply_check() {
    local rc="$1" what="$2"
    case "$rc" in
        0) return 0 ;;
        3) printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2
           error "nginx -t BAŞARISIZ (${what}) — dosyalar+köken kaydı geri alındı, reload YAPILMADI" ;;
        5) error "nginx reload başarısız — config GEÇERLİ, sorun servis katmanında. systemctl status nginx" ;;
        6) error "fm-auth ${what} başarısız VE GERİ ALMA BAŞARISIZ — dosyalar/köken kaydı yarım olabilir; yedek: ${_FMA_KEEP_BK:-?} — 'srvctl domain fm-auth <alan> status' ve 'srvctl domain fm-root <alan>' ile denetleyin" ;;
        7) printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2
           error "ModSecurity yetenek tespiti YAPILAMADI (aday sonda: nginx -t -c) — hiçbir FM dosyası yazılmadı (${what})" ;;
        *) error "fm-auth ${what} başarısız (render/yazım/köken kaydı ya da acil kapatma kapısı) — geri alındı; işlemin kendi reload'u YAPILMADI (acil kapatma işaretli alanda geri alma çalışan nginx'i kapalı tutmak için ayrıca yeniden yükler: yukarıdaki iletilere bakın)" ;;
    esac
}

# ───────────────────────────────────────────────────────────────
#  Kullanıcı dosyası taraması (disk-glob; nginx -t/-T ÇALIŞTIRMAZ, salt-okur)
#
#  Birim = <custom.d>/<sname>/*.conf (nginx'in vhost'ta yüklediği glob). Köken kaydıyla
#  tanınan ÜRETİLMİŞ dosyalar atlanır; kalan her dosya: (1) sembolik bağ → ret,
#  (2) izin listesi (rezerve ad dahil: köken kaydında olmayan srvctl/FM adı → ret).
#  *.conf olmayan adlar nginx'e görünmez: yalnız BİLGİ satırı.
#  Çıktı satırı: "<dosya>:<satır>:<direktif>:<gerekçe>" (bilgi: "BILGI <ad> ...").
#  rc 0 temiz, 1 ihlal, 2 doğrulanamadı (en az bir dosya doğrulanamadı; ihlal satırları da basılır).
#  $4 (ops.) = taramadan MUAF tutulacak dosya adları (boşlukla ayrık; yazım yolunda
#  yeniden üretilecek srvctl adları).
# ───────────────────────────────────────────────────────────────
_SUF_OUT=""
# Satır sonu içeren adlar için güvenli liste (ad satır sonu taşıyabilir; eski
# satırla-bölünen _SUF_BAD kaldırıldı — yazılıp hiç okunmuyordu).
_SUF_BAD_ARR=()
_domconf_scan_user_files() {
    local domain="$1" sname="$2" dir="$3" skip="${4:-}"
    local f base out frc rc=0 viol=0 unv=0 line this
    _SUF_OUT=""; _SUF_BAD_ARR=()
    for f in "$dir"/*; do
        [[ -e "$f" || -L "$f" ]] || continue
        base="${f##*/}"
        case "$base" in
            *.conf) ;;
            *) _SUF_OUT+="BILGI ${base}: .conf değil — nginx yüklemez (taranmadı)"$'\n'; continue ;;
        esac
        case " ${skip} " in
            *" ${base} "*) continue ;;
        esac
        if _fmprov_is_generated "$sname" "$f"; then
            continue
        fi
        this=0
        if [[ -L "$f" ]]; then
            _SUF_OUT+="${base}:0:sembolik-bağ:sembolik bağ olan *.conf dosyası reddedilir (hedef denetlenemez)"$'\n'
            viol=1; _SUF_BAD_ARR+=("$base")
            continue
        fi
        frc=0
        out=$(_domconf_user_scan "$f" "$domain" "$base") || frc=$?
        case "$frc" in
            0) ;;
            1) viol=1; this=1 ;;
            *) unv=1 ;;
        esac
        if [[ -n "$out" ]]; then
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then _SUF_OUT+="${base}:${line}"$'\n'; fi
            done <<< "$out"
        fi
        if (( frc >= 2 )); then
            _SUF_OUT+="${base}:0:doğrulanamadı:izin listesi dosyayı çözümleyemedi (FAIL-CLOSED)"$'\n'
        fi
        if (( this )); then _SUF_BAD_ARR+=("$base"); fi
    done
    if (( unv )); then rc=2; elif (( viol )); then rc=1; fi
    return $rc
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain nginx-audit [<domain>|--all] [--quarantine]
#  SALT-OKUR denetim: yazmaz, nginx -t/-T/reload ÇALIŞTIRMAZ, '--show' yolunu (iskelet
#  yazan) KULLANMAZ. Çıkış: 0 temiz | 1 ihlal | 2 doğrulanamadı (2 > 1 öncelikli;
#  ihlal satırları yine basılır). '--json' YOK.
#  Kullanıcı dosyalarına EK olarak her alanın /_fm 403 KÖKÜ denetlenir: kök yok (KÖK-YOK),
#  kayıtsız FM adı (KÖK-KAYITSIZ), kayıtlı ama 20 eksik/kurcalanmış (KÖK-SAĞLAM-DEĞİL), kayıt
#  güvenilmez (KÖK-DOĞRULANAMADI) ya da yarım işlem yedeği (YARIM-İŞLEM) → en az 1. Çözüm her
#  satırda: 'srvctl domain fm-root <alan> --apply'.
#  '--quarantine' (YALNIZ açık bayrakla): ihlalli KULLANICI dosyasını '<ad>.srvctl-rejected'e
#  taşır. ASLA: srvctl/FM rezerve adları (20/21/90 — kayıtlı, kurcalanmış ya da kayıtsız; 403 kökü
#  dahil) taşınmaz → "yeniden üret: fm-root" denir; STATE-UNTRUSTED alanda HİÇBİR dosya taşınmaz;
#  403 kökü sağlam olmayan alanda karantina YAPILMAZ (taşınan bir kullanıcı dosyası /_fm'i
#  uygulamaya düşürebilirdi). Taşımalar fm-auth kilidi altında, hepsi-ya-hiçbiri (mv hatası →
#  önceki taşımalar geri), sonra nginx -t ve 403 kökü yeniden doğrulanır → hata: HEPSİ geri, reload YOK.
# ───────────────────────────────────────────────────────────────
_FMRA_LINE=""
# Bir alanın 403 kökünü denetler (salt-okur). _FMRA_LINE: bulgu satırı (sağlamsa boş). PREDİKAT: 0=sağlam.
_domconf_fm_root_audit() {
    local domain="$1" sname="$2" dir="$3" lrc=0 present="" bks
    _FMRA_LINE=""
    bks=$(_fmprov_bk_list "$sname")
    if [[ -n "$bks" ]]; then
        _FMRA_LINE="YARIM-İŞLEM: kesintiye uğramış FM yazımının yedeği duruyor ($(tr '\n' ' ' <<< "$bks" | sed 's#[^ ]*/##g'))— dosyalar/kayıt ara durumda olabilir; kurtarmak için: srvctl domain fm-root ${domain} --apply"
        return 1
    fi
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        _FMRA_LINE="KÖK-DOĞRULANAMADI: köken kaydı güvenilmez (STATE-UNTRUSTED) — 403 kökü üretilmiş sayılamaz; kayıt dizinini root:root 0700 yapın, sonra: srvctl domain fm-root ${domain} --apply"
        return 1
    fi
    if (( lrc == 1 )); then
        _domconf_fm_reserved_present "$dir" || true; present="$_FMX_PRESENT"
        if [[ -n "$present" ]]; then
            _FMRA_LINE="KÖK-KAYITSIZ: FM adlı dosya(lar) köken kaydı OLMADAN diskte (${present% }) — srvctl üretimi sayılmaz; 403 kökünü kurmak için: srvctl domain fm-root ${domain} --apply (devralır; eski içerik <ad>.srvctl-tampered)"
        else
            _FMRA_LINE="KÖK-YOK: /_fm 403 kökü kurulu değil — /_fm ve /_fm/… uygulamaya (CI4) düşer; kurmak için: srvctl domain fm-root ${domain} --apply"
        fi
        return 1
    fi
    if ! _fmprov_is_generated "$sname" "${dir}/${_DOMCONF_FM_UP_FILE}"; then
        _FMRA_LINE="KÖK-SAĞLAM-DEĞİL: köken kaydı var (durum: ${_FMP_STATE}) ama ${_DOMCONF_FM_UP_FILE} eksik ya da kayıtla uyuşmuyor — yeniden üretmek için: srvctl domain fm-root ${domain} --apply"
        return 1
    fi
    return 0
}

# Karantina adayları (alan, kaynak yol) — denetim geçişinde doldurulur, kilit altında uygulanır.
_Q_DOM=(); _Q_SRC=(); _Q_DST=()

# Benzersiz, *.conf glob'una GİRMEYEN karantina adı (var olan bir kanıtın ÜZERİNE yazılmaz).
_domconf_rejected_name() {
    local src="$1" cand i=1
    cand="${src}.srvctl-rejected"
    while [[ -e "$cand" || -L "$cand" ]]; do
        cand="${src}.srvctl-rejected.${i}"; i=$((i + 1))
        (( i < 1000 )) || return 1
    done
    printf '%s' "$cand"
}

# _Q_DST'deki taşımaları (sondan başa) geri alır. rc 0 = hepsi geri geldi.
_domconf_quarantine_revert() {
    local i rc=0
    for (( i = ${#_Q_DST[@]} - 1; i >= 0; i-- )); do
        [[ -n "${_Q_DST[i]}" ]] || continue
        if mv -n -- "${_Q_DST[i]}" "${_Q_SRC[i]}" 2>/dev/null && [[ ! -e "${_Q_DST[i]}" && ! -L "${_Q_DST[i]}" ]]; then
            _Q_DST[i]=""
        else
            warn "karantina GERİ ALINAMADI: ${_Q_DST[i]} → ${_Q_SRC[i]}"
            rc=1
        fi
    done
    return $rc
}

# Sinyal tuzağı: taşımalar yarıda kalmasın — hepsini geri al, sinyale göre kodla çık
# (INT 130, TERM 143, HUP 129). Geri alma başarısızsa neden basılır (taşınan dosya adı _Q_DST'de).
_domconf_quarantine_abort() {
    local code="${1:-130}"
    if ! _domconf_quarantine_revert; then
        warn "kesinti: karantina taşımaları GERİ ALINAMADI — '<ad>.srvctl-rejected' dosyalarını elle denetleyin"
    fi
    exit "$code"
}

# Kilit altında: taşı (hepsi-ya-hiçbiri) → nginx -t → her alanın 403 kökü hâlâ sağlam mı → reload.
# rc 0 | 1 taşıma/geri alma hatası | 3 nginx -t (geri alındı) | 4 kök doğrulaması (geri alındı) | 5 reload.
# INT/TERM/HUP: taşımalar geri alınır (reload'dan hemen ÖNCE tuzak kalkar: reload başlamışken
# geri alma çalışan nginx ile diski ayrıştırırdı).
_domconf_quarantine_locked() {
    local rc=0
    trap '_domconf_quarantine_abort 130' INT
    trap '_domconf_quarantine_abort 143' TERM
    trap '_domconf_quarantine_abort 129' HUP
    _domconf_quarantine_body || rc=$?
    trap - INT TERM HUP
    return $rc
}

_domconf_quarantine_body() {
    local i src dst d sname dir out trc=0
    _Q_DST=()
    for (( i = 0; i < ${#_Q_SRC[@]}; i++ )); do
        d="${_Q_DOM[i]}"; sname=$(safe_name "$d"); dir=$(_domconf_fm_dir "$sname"); src="${_Q_SRC[i]}"
        if ! _domconf_fm_root_intact "$sname" "$dir"; then
            warn "karantina İPTAL (${d}): 403 kökü artık sağlam değil — hiçbir dosya taşınmadı"
            _domconf_quarantine_revert || return 1
            return 4
        fi
        if [[ ! -e "$src" && ! -L "$src" ]]; then _Q_DST+=(""); continue; fi
        dst=$(_domconf_rejected_name "$src") || { _Q_DST+=(""); warn "karantina adı üretilemedi: ${src}"; _domconf_quarantine_revert; return 1; }
        if mv -n -- "$src" "$dst" 2>/dev/null && [[ ! -e "$src" && ! -L "$src" ]]; then
            _Q_DST+=("$dst")
        else
            _Q_DST+=("")
            warn "karantina taşıması başarısız: ${src} — önceki taşımalar geri alınıyor"
            _domconf_quarantine_revert
            return 1
        fi
    done
    out=$(nginx -t 2>&1) || trc=$?
    if (( trc != 0 )); then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        _domconf_quarantine_revert || return 1
        return 3
    fi
    for (( i = 0; i < ${#_Q_SRC[@]}; i++ )); do
        d="${_Q_DOM[i]}"; sname=$(safe_name "$d"); dir=$(_domconf_fm_dir "$sname")
        if ! _domconf_fm_root_intact "$sname" "$dir"; then
            warn "karantina sonrası 403 kökü SAĞLAM DEĞİL (${d}) — karantina GERİ ALINIYOR"
            _domconf_quarantine_revert || return 1
            return 4
        fi
    done
    trap - INT TERM HUP
    systemctl reload nginx >/dev/null 2>&1 || return 5
    return 0
}

_domconf_nginx_audit() {
    local usage="srvctl domain nginx-audit [<domain>|--all] [--quarantine]"
    local target="" quarantine=0 arg
    for arg in "$@"; do
        case "$arg" in
            --all)        target="--all" ;;
            --quarantine) quarantine=1 ;;
            -*)           error "Bilinmeyen seçenek: ${arg} (kullanım: ${usage})" ;;
            *)            target="$arg" ;;
        esac
    done
    [[ -n "$target" ]] || error "Kullanım: ${usage}"

    local -a domains=()
    local d
    if [[ "$target" == "--all" ]]; then
        while IFS= read -r d; do if [[ -n "$d" ]]; then domains+=("$d"); fi; done < <(list_all_domains)
        if (( ${#domains[@]} == 0 )); then info "Denetlenecek domain yok."; return 0; fi
    else
        domain_exists "$target" || error "Domain bulunamadı: ${target}"
        domains=("$target")
    fi

    local worst=0 sname dir rc line f untrusted dir_untrusted root_ok legacy note orph
    _Q_DOM=(); _Q_SRC=(); _Q_DST=()
    legacy=$(_fmprov_bk_legacy_list)
    if [[ -n "$legacy" ]]; then
        echo "UYARI: sahibi bilinmeyen (eski biçim) yarım işlem yedeği: $(tr '\n' ' ' <<< "$legacy")— hangi alana ait olduğu bilinemez; alan durumlarını ve 'nginx -t'yi denetleyip elle kaldırın"
    fi
    for d in "${domains[@]}"; do
        sname=$(safe_name "$d")
        dir=$(_domconf_fm_dir "$sname")
        echo "[${d}]"
        orph=$(_domconf_fm_orphan_note "$d" "$sname")
        if [[ ! -d "$dir" ]]; then
            if [[ -n "$orph" ]]; then echo "  UYARI: ${orph}"; fi
            echo "  (custom.d dizini yok — denetlenecek kullanıcı dosyası yok)"
            echo "  KÖK-YOK: custom.d/${sname} dizini yok — /_fm 403 kökü kurulu değil; kurmak için: srvctl domain fm-root ${d} --apply"
            if (( worst == 0 )); then worst=1; fi
            continue
        fi
        untrusted=0
        if ! _fmprov_state_ok "$sname"; then
            untrusted=1
            echo "  STATE-UNTRUSTED: köken kaydı/dizini güvenilmez — hiçbir dosya 'üretilmiş' sayılmaz (hepsi kullanıcı dosyası)"
        fi
        # custom.d/<sname> GÜVEN KAPISI: sembolik bağ, root'a ait olmayan ya da g/o-yazılabilir dizin (inode taklidi dahil) GÜVENİLMEZ;
        # içindeki "kayıtla eşleşen" dosyalar kiracının denetiminde olabilir → kök sağlam raporlanmaz, rc ≠ 0.
        dir_untrusted=0
        if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
            dir_untrusted=1
            echo "  GÜVENİLMEZ: ${_FMD_WHY} — srvctl bu girdiyi izlemez; 403 kökü ve üretilmiş dosyalar DOĞRULANAMAZ. Alanı kapatmak için: srvctl domain fm-auth ${d} off (girdiyi kenara alıp root sahipli dizinde 403 kökü kurar)"
        fi
        if [[ -n "$orph" ]]; then echo "  UYARI: ${orph}"; fi
        # ayrılmış (.superseded.bk.*) yedekler görünür olsun (bilgi; çıkış kodunu DEĞİŞTİRMEZ).
        note=$(_fmprov_superseded_note "$sname")
        if [[ -n "$note" ]]; then echo "  BİLGİ: ${note}"; fi
        # acil kapatma artıkları — dosya başına BİLGİ satırlarının yanında SAYI özeti ve eşik uyarısı.
        note=$(_domconf_fm_aside_note "$dir")
        if [[ -n "$note" ]]; then
            if (( $(_domconf_fm_aside_list "$dir" | grep -c .) > _FME_ASIDE_WARN )); then echo "  UYARI: ${note}"; else echo "  BİLGİ: ${note}"; fi
        fi
        rc=0
        _domconf_scan_user_files "$d" "$sname" "$dir" || rc=$?
        if [[ -n "$_SUF_OUT" ]]; then
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then echo "  ${line}"; fi
            done <<< "$_SUF_OUT"
        fi
        root_ok=1
        if [[ -L "$dir" ]]; then
            # nginx bağı izler (dosyalar yukarıda taranmıştır) ama srvctl yazımları bağa yapılmaz (fm-root reddeder).
            root_ok=0
            echo "  KÖK-DOĞRULANAMADI: custom.d/${sname} sembolik bağ — srvctl 403 kökünü buraya kurmaz/doğrulamaz; bağı gerçek dizinle değiştirin, sonra: srvctl domain fm-root ${d} --apply"
        elif (( dir_untrusted )); then
            root_ok=0
            echo "  KÖK-DOĞRULANAMADI: custom.d/${sname} güvenilmez (root'a ait değil ya da grup/herkes yazabilir) — srvctl 403 kökünü buraya kurmaz/doğrulamaz; dizini root sahipli yapın (ya da kapatıp yeniden kurun: srvctl domain fm-auth ${d} off)"
        elif ! _domconf_fm_root_audit "$d" "$sname" "$dir"; then
            root_ok=0
            echo "  ${_FMRA_LINE}"
        fi
        case "$rc" in
            0) if (( root_ok )) && [[ -z "$orph" ]]; then echo "  temiz"; elif (( root_ok )); then echo "  kullanıcı dosyaları temiz — YETİM kenara alma artığı var"; else echo "  kullanıcı dosyaları temiz — 403 KÖKÜ SAĞLAM DEĞİL"; fi ;;
            1) echo "  İHLAL VAR" ;;
            *) echo "  DOĞRULANAMADI" ;;
        esac
        if (( root_ok == 0 && rc == 0 )); then rc=1; fi
        if [[ -n "$orph" && rc -eq 0 ]]; then rc=1; fi
        if (( rc == 2 )); then worst=2; elif (( rc == 1 && worst == 0 )); then worst=1; fi

        if (( quarantine )) && (( ${#_SUF_BAD_ARR[@]} > 0 )); then
            if (( untrusted )); then
                echo "  KARANTİNA YAPILMADI: STATE-UNTRUSTED — köken doğrulanamadan hiçbir dosya taşınmaz (srvctl'in kendi 403 kökü de olabilir). Kayıt dizinini root:root 0700 yapın, sonra: srvctl domain fm-root ${d} --apply"
                continue
            fi
            if (( root_ok == 0 )); then
                echo "  KARANTİNA YAPILMADI: 403 kökü sağlam değil — bir kullanıcı dosyasını taşımak /_fm'i uygulamaya düşürebilir. Önce: srvctl domain fm-root ${d} --apply"
                continue
            fi
            for f in "${_SUF_BAD_ARR[@]}"; do
                [[ -n "$f" && "$f" != */* ]] || continue
                if _fmprov_known_name "$f"; then
                    echo "  KARANTİNAYA ALINMADI: ${f} srvctl/FM rezerve adı (kayıtla uyuşmuyor) — srvctl dosyası yeniden ÜRETİLİR, taşınmaz: srvctl domain fm-root ${d} --apply"
                    continue
                fi
                if [[ -e "${dir}/${f}" || -L "${dir}/${f}" ]]; then
                    _Q_DOM+=("$d"); _Q_SRC+=("${dir}/${f}")
                fi
            done
        fi
    done

    if (( quarantine && ${#_Q_SRC[@]} > 0 )); then
        local qrc=0 i
        _fmprov_with_lock _domconf_quarantine_locked || qrc=$?
        case "$qrc" in
            0) ;;
            3) error "nginx -t BAŞARISIZ — karantina GERİ ALINDI, reload YAPILMADI" ;;
            4) error "karantina 403 kökünü bozacaktı — GERİ ALINDI, reload YAPILMADI" ;;
            5) warn "nginx reload başarısız — config GEÇERLİ (dosyalar taşındı) AMA taşınan ihlalli dosya(lar) ÇALIŞAN nginx'te hâlâ etkin olabilir; sorun servis katmanında: systemctl status nginx, ardından: srvctl domain reload" ;;
            *) error "karantina uygulanamadı (kilit/taşıma/geri alma) — yukarıdaki iletilere bakın" ;;
        esac
        local moved=0
        for (( i = 0; i < ${#_Q_DST[@]}; i++ )); do
            if [[ -n "${_Q_DST[i]}" ]]; then moved=$((moved + 1)); fi
        done
        log_action "DOMAIN NGINX-AUDIT --quarantine: ${moved} dosya"
        info "Karantinaya alınan dosya: ${moved} (<ad>.srvctl-rejected; geri almak için adı eski haline getirip 'srvctl domain reload')"
    fi
    return "$worst"
}

# ───────────────────────────────────────────────────────────────
#  nginx -T SON DENETİMİ (yalnız 'domain nginx' yazım yolu)
#
#  nginx'in GERÇEKTE yüklediği, bu alanın ÜRETİLMİŞ-OLMAYAN custom.d dosyaları
#  izin listesinden geçirilir. Düzenlenen dosyanın bulgusu/doğrulanamaması = RET (rc 1/2,
#  çağıran geri alır). DüzenlenMEYEN başka dosyalardaki mevcut ihlaller yazımı ENGELLEMEZ:
#  "UYARI ..." satırı olarak basılır (mevcut yapılandırmayı kırmamak için).
#  Bölüm başlığı SAHTELENEMEZ: her bölümün içeriği DİSKTEKİ dosyayla bayt bayt
#  karşılaştırılır (uyuşmazlık = bölüm kaçırma girişimi ya da yarış → rc 2).
#  FAIL-CLOSED: nginx yok / -T hata / çıktı boş / aynı yol iki kez başlık → rc 2.
#  $3=düzenlenen dosyanın taban adı. rc 0 temiz, 1 düzenlenen dosyada bulgu, 2 doğrulanamadı.
# ───────────────────────────────────────────────────────────────
_domconf_dump_check() {
    local domain="$1" sname="$2" edited="$3"
    local custdir="${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}"
    local mydir="${custdir}/${sname}"
    if ! command -v nginx >/dev/null 2>&1; then
        echo "nginx bulunamadı — 'nginx -T' alınamadı, yüklenen yapılandırma doğrulanamıyor"
        return 2
    fi
    local tmpd; tmpd=$(mktemp -d) || { echo "geçici dizin oluşturulamadı"; return 2; }
    local rc=0
    _domconf_dump_check_run "$domain" "$sname" "$edited" "$mydir" "$tmpd" || rc=$?
    if [[ -n "$tmpd" && -d "$tmpd" ]]; then rm -rf -- "${tmpd:?}"; fi
    return $rc
}

_domconf_dump_check_run() {
    local domain="$1" sname="$2" edited="$3" mydir="$4" tmpd="$5"
    if ! nginx -T > "${tmpd}/dump" 2>/dev/null; then
        echo "'nginx -T' başarısız — yüklenen yapılandırma doğrulanamıyor"
        return 2
    fi
    local line path seen=$'\n' markers=0 idx=0 keep=0 cur=""
    local -a kept=() keptf=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^"# configuration file "(.*):$ ]]; then
            path="${BASH_REMATCH[1]}"
            markers=$((markers + 1))
            case "$seen" in
                *$'\n'"${path}"$'\n'*)
                    echo "'nginx -T' çıktısında aynı yol iki kez başlık oldu (${path}) — bölüm sahteciliği ya da tutarsız çıktı"
                    return 2
                    ;;
            esac
            seen+="${path}"$'\n'
            keep=0
            if [[ "$path" == "${mydir}/"*.conf ]]; then
                keep=1
                idx=$((idx + 1))
                cur="${tmpd}/sec.${idx}"
                : > "$cur"
                kept+=("$path"); keptf+=("$cur")
            fi
            continue
        fi
        if (( keep )); then
            printf '%s\n' "$line" >> "$cur"
        fi
    done < "${tmpd}/dump"
    if (( markers == 0 )); then
        echo "'nginx -T' çıktısında hiç '# configuration file' başlığı yok — çıktı alınamadı/tanınmadı"
        return 2
    fi

    local i found=0 sec base out frc ln
    for ((i = 0; i < ${#kept[@]}; i++)); do
        path="${kept[i]}"; sec="${keptf[i]}"
        base="${path##*/}"
        if [[ ! -f "$path" ]]; then
            echo "${path}: nginx yükledi ama diskte yok — doğrulanamıyor"
            return 2
        fi
        if [[ "$(cat -- "$sec")" != "$(cat -- "$path")" ]]; then
            echo "${path}: 'nginx -T' bölümü diskteki dosyayla UYUŞMUYOR (başlık sahteciliği ya da eşzamanlı değişiklik) — doğrulanamıyor"
            return 2
        fi
        if _fmprov_is_generated "$sname" "$path"; then
            continue
        fi
        frc=0
        out=$(_domconf_user_scan "$sec" "$domain" "$base") || frc=$?
        if [[ "$base" == "$edited" ]]; then
            if (( frc == 2 )); then
                if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
                echo "${base}: izin listesi dosyayı doğrulayamadı (nginx -T bölümü) — FAIL-CLOSED"
                return 2
            fi
            if (( frc == 1 )); then
                found=1
                while IFS= read -r ln; do if [[ -n "$ln" ]]; then printf '%s:%s\n' "$base" "$ln"; fi; done <<< "$out"
            fi
        elif (( frc != 0 )); then
            echo "UYARI ${base}: mevcut dosya izin listesine UYMUYOR (yazımı engellemez; 'srvctl domain nginx-audit ${domain}' ile inceleyin)"
        fi
    done
    return $found
}

_domconf_nginx_skeleton() {
    local domain="$1"
    cat <<EOF
# ═══════════════════════════════════════════════
#  srvctl per-domain nginx override — ${domain}
# ═══════════════════════════════════════════════
#
# Bu dosya vhost'un server{} bloğuna, EN SONDA include edilir.
# Render'ın DIŞINDADIR: 'domain repair' onu EZMEZ.
#
# ─── ÖNEMLİ KISIT ───
# Bir include dosyası mevcut direktifleri EZEMEZ — nginx çoğu direktifte
# "is duplicate" hatası verir. Buraya EKLEME yapılır, override DEĞİL.
# ('client_max_body_size' vhost'ta tanımlı DEĞİL, yani serbestçe eklenebilir.)
#
# ─── add_header TUZAĞI ───
# Bir location{} bloğu İÇİNDE add_header kullanırsanız, o location için üst
# bloğun TÜM güvenlik başlıkları (HSTS, X-Frame-Options, Referrer-Policy…)
# SESSİZCE düşer. Kullanacaksanız üsttekileri de o blokta TEKRARLAYIN.
#
# ─── İZİN LİSTESİ (varsayılan RET) ───
# Bu dosya yalnız izin verilen direktiflerle yazılabilir; listede olmayan HER
# direktif, değişken ve yapı reddedilir (kaydedilirken 'nginx -t'den ÖNCE taranır):
#   client_max_body_size, location, add_header, return, allow/deny, try_files,
#   limit_req/limit_conn (srvctl'in hazır zone'ları), limit_except, expires,
#   log_not_found, access_log off, index, set, if, rewrite
# Reddedilenlerin başlıcaları: her *_pass (proxy_pass dahil), include, root/alias,
# listen/server_name, modsecurity*, auth_request*, error_log/access_log <yol>,
# kod/alt istek/yazma modülleri, '_fm' ile ilgili her ad ('/_fm/', '@fm…', '\$fm…').
# 'proxy_pass' TAM YASAKTIR (kullanıcı kararı): ters vekil ihtiyacı için srvctl'e ayrı bir
# şablonlu komut istenir; kullanıcı dosyasından asla.
# Kesin ve güncel liste: lib/nginx_allow.sh ve README "custom.d izin listesi".
# Denetim (salt-okur, hiçbir şeyi değiştirmez):  srvctl domain nginx-audit ${domain}
#
# Tarama nginx'in kendi sözcük kurallarıyla (token + blok) yapılır: tek satırlık
# blok, aynı satırda çoklu direktif, tırnaklı direktif adı da yakalanır; dengesiz
# tırnak/blok gibi çözümlenemeyen yapı REDDEDİLİR. Kayıttan sonra 'nginx -T' ile
# nginx'in gerçekten yüklediği dosyalar da denetlenir. '--force' YOKTUR.
#
# ─── Örnek ───
# client_max_body_size 100M;
EOF
}

# vhost'un custom.d dizinini yüklememesi hatasında operatöre 'domain repair' ÖNERİLMEZ: _domain_repair
# vhost YAZMAZ (yalnız FPM havuzu / AppArmor / DB / Redis adımları; _domain_write_vhost'u yalnız 'domain add' ve
# 'domain rate-limit' çağırır — tests/test_domain_nginx_include_guidance.sh A) ve geniş yan etkilidir. Doğru çıkış
# (elle include) hata satırının KENDİSİNDE yazılır; bu yardımcı yalnız alternatifi ve yan etkisini ekler.
_domconf_vhost_include_alt() {
    local domain="$1"
    printf "('repair' vhost YAZMAZ, çare DEĞİLDİR.) Vhost'u şablondan yeniden üreten tek komut 'srvctl domain rate-limit %s <mevcut-profil>'dir — YAN ETKİSİ: vhost'un TAMAMINI şablondan yeniden yazar (vhost'taki tüm elle düzenlemeler kaybolur), nginx -t + reload yapar" "$domain"
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain nginx <domain> [--show] [--file <path>]
#
#  Sıra: aday → İZİN LİSTESİ taraması (nginx -t'den ÖNCE) → yaz → nginx -t → nginx -T
#  son denetimi (düzenlenen dosya) → reload. Her aşamada hata → eski dosya geri.
#  '--force' KALKTI: izin listesinin baypası yoktur.
# ───────────────────────────────────────────────────────────────
_domconf_edit_nginx() {
    local domain="" src_file="" show=0 arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --show)   show=1 ;;
            --force)  error "'--force' kaldırıldı: custom.d izin listesinin baypası yoktur. Reddedilen bir yapıyı izin listesine uyacak biçimde yazın (srvctl domain nginx-audit <domain>)" ;;
            --file)   shift; src_file="${1:-}"; [[ -n "$src_file" ]] || error "--file bir yol gerektirir" ;;
            --file=*) src_file="${arg#--file=}" ;;
            -*)       error "Bilinmeyen seçenek: ${arg}" ;;
            *)        domain="$arg" ;;
        esac
        shift
    done
    [[ -n "$domain" ]] || error "Kullanım: srvctl domain nginx <domain> [--show] [--file <yol>]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local dir; dir=$(_domconf_fm_dir "$sname")
    local conf="${dir}/00-custom.conf"
    mkdir -p "$dir"
    [[ -f "$conf" ]] || { _domconf_nginx_skeleton "$domain" > "$conf"; chmod 644 "$conf"; }

    if [[ "$show" == "1" ]]; then
        cat "$conf"
        return 0
    fi

    # ─── ÖN KOŞUL: vhost bu dizini include ediyor mu? ───
    local vhost="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${domain}.conf"
    if [[ -f "$vhost" ]] && ! grep -q "custom\.d/${sname}/" "$vhost"; then
        error "Bu domainin vhost'u custom.d dizinini include ETMİYOR (${vhost}) — düzenleme ETKİSİZ kalırdı. Çıkış: vhost'un server bloğuna elle 'include /etc/nginx/custom.d/${sname}/*.conf;' ekleyin, 'nginx -t' ile doğrulayıp reload edin, sonra bu komutu yeniden çalıştırın. $(_domconf_vhost_include_alt "$domain")"
    fi

    local cand; cand=$(mktemp)
    trap 'rm -f -- "${cand:-}" "${backup:-}"' EXIT
    trap 'rm -f -- "${cand:-}" "${backup:-}"; exit 130' INT TERM
    if [[ -n "$src_file" ]]; then
        [[ -f "$src_file" ]] || { rm -f -- "${cand:?}"; error "Dosya bulunamadı: ${src_file}"; }
        cp "$src_file" "$cand"
    else
        cp "$conf" "$cand"
        # 'sudo' env_reset ile $EDITOR'ü temizler — 'sudo -E' gerekir (README).
        "${EDITOR:-nano}" "$cand" || { rm -f -- "${cand:?}"; error "Editör hata döndürdü — değişiklik uygulanmadı"; }
    fi

    if cmp -s "$cand" "$conf"; then
        rm -f -- "${cand:?}"
        info "Değişiklik yok — hiçbir şey yapılmadı."
        return 0
    fi

    # ─── İZİN LİSTESİ (aday; nginx -t'den ÖNCE) ───
    local findings frc=0
    findings=$(_domconf_user_scan "$cand" "$domain" "00-custom.conf") || frc=$?
    if (( frc != 0 )); then
        rm -f -- "${cand:?}"
        if (( frc == 1 )); then
            warn "REDDEDİLDİ — izin listesi dışı direktif/yapı (satır:direktif:gerekçe):"
        else
            warn "REDDEDİLDİ — dosya güvenle DOĞRULANAMADI (FAIL-CLOSED):"
        fi
        printf '%s\n' "$findings" | sed 's/^/    /' >&2
        error "Değişiklik UYGULANMADI. (--force yoktur; izin listesine uyacak biçimde yazın)"
    fi

    # Yazım → nginx -t → nginx -T denetimi → reload, fm-auth kilidi ALTINDA (fm-auth/fm-root/
    # karantina yazımlarıyla yarışmaz). Kilit alınamazsa HİÇBİR şey yazılmaz.
    _fmprov_with_lock _domconf_edit_nginx_commit_locked "$domain" "$sname" "$conf" "$cand" \
        || { rm -f -- "${cand:?}"; error "nginx override UYGULANMADI: fm-auth kilidi/kayıt dizini alınamadı (yukarıya bakın)"; }
}

# Kilit altında: adayı yerine yaz, nginx -t, nginx -T son denetimi, reload; hata → eski içerik geri.
_domconf_edit_nginx_commit_locked() {
    local domain="$1" sname="$2" conf="$3" cand="$4"
    local backup; backup=$(mktemp)
    cp "$conf" "$backup"
    cat "$cand" > "$conf"
    chmod 644 "$conf"
    rm -f -- "${cand:?}"

    if ! nginx -t >/dev/null 2>&1; then
        cat "$backup" > "$conf"; rm -f -- "${backup:?}"
        warn "nginx -t BAŞARISIZ — dosya eski haline döndürüldü, reload YAPILMADI. nginx'in kendi çıktısı:"
        nginx -t 2>&1 | sed 's/^/    /' >&2 || true
        error "nginx yapılandırma hatası"
    fi

    # POST-PARSE: nginx'in GERÇEKTE yüklediği, bu alanın ÜRETİLMİŞ-OLMAYAN dosyaları (nginx -T).
    local dfind drc=0
    dfind=$(_domconf_dump_check "$domain" "$sname" "00-custom.conf") || drc=$?
    if (( drc == 2 )); then
        cat "$backup" > "$conf"; rm -f -- "${backup:?}"
        warn "nginx -T ile yüklenen yapılandırma DOĞRULANAMADI — dosya eski haline döndürüldü, reload YAPILMADI:"
        printf '%s\n' "$dfind" | sed 's/^/    /' >&2
        error "Doğrulama yapılamadığı için değişiklik UYGULANMADI"
    elif (( drc == 1 )); then
        cat "$backup" > "$conf"; rm -f -- "${backup:?}"
        warn "REDDEDİLDİ — nginx -T'de düzenlenen dosyada izin listesi dışı yapı:"
        printf '%s\n' "$dfind" | sed 's/^/    /' >&2
        error "Değişiklik UYGULANMADI (dosya eski haline döndürüldü)"
    fi
    if [[ -n "$dfind" ]]; then printf '%s\n' "$dfind" | grep '^UYARI' >&2 || true; fi
    rm -f -- "${backup:?}"

    systemctl reload nginx >/dev/null 2>&1 \
        || error "nginx reload başarısız — config GEÇERLİ, sorun servis katmanında. systemctl status nginx"

    success "nginx override uygulandı ve reload edildi: ${domain}"
    log_action "DOMAIN NGINX: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain fm-auth <domain> <on|off|status> [--script=<yol>] [--region=eu|us]
#                        [--force] [--dry]
#
#  FileManager (OPT-IN, varsayılan KAPALI). 'on' ÜÇ dosya yazar (custom.d/<safe_name>/,
#  vhost şablonu DEĞİŞMEZ; hepsi şablondan, root:root 644):
#    90-srvctl-fm-auth.conf      → 'location = /__fm_auth' (internal, FPM'e gövdesiz fastcgi_pass)
#    21-srvctl-fm-download.conf  → 'location = /__fm_dl' (internal, X-Accel indirme)
#    20-srvctl-fm-upload.conf    → 'location ^~ /_fm/up/' + 'location ^~ /_fm/ {403}' + '@fm_deny' + '@fm_up'
#  ve köken kaydını yazar (${SRVCTL_STATE_DIR}/_fm-auth/<sname>.manifest). Yazım sırası
#  90 → 21 → 20 (yükleme yolu EN SON açılır). Yerinde yaz → nginx -t → hata → GERİ AL.
#  Kullanıcı dosyaları (00-custom.conf …) HER nginx -t'den ÖNCE izin listesinden geçer;
#  alanın kullanıcı dosyalarında ihlal varsa 'on' REDDEDİLİR (kullanıcı dosyası FM yolunu
#  etkileyebilir).
#  'off' hepsini kaldırır ve yerine iki satırlık 403 kökü (20-srvctl-fm-upload.conf:
#  'location = /_fm { return 403 "srvctl-fm-closed <sig>"; }' + 'location ^~ /_fm/ { ... }'; gövde imzası bulunur) bırakır — yükleme
#  yolu fail-closed (eğik çizgisiz '/_fm' de CI4'e düşmez; '/_fmx' gibi yollar ETKİLENMEZ).
#  Durum 'YOK' (hiç açılmamış alan): /_fm/ CI4'e düşer (CI4'te /_fm/ rotası yoktur).
#
#  'off' HER ZAMAN KAPATIR: normal yol (kayıt + kilit + custom.d başvuru denetimi + nginx -t geri
#  alması) hangi nedenle olursa olsun başarısız olursa OTOMATİK ACİL yola düşülür; 'off --emergency' normal
#  yolu atlar. Acil yol monotondur (yalnız kapatır), kayda/kilide/--force'a/nginx -t geri almasına bağlı
#  DEĞİLDİR ve GERÇEĞİ söyler (rc 0 KAPALI | 3 FM HÂLÂ AÇIK | 4 doğrulanamadı/kısmen | 5 disk kapatılamadı).
#  'status' diskin yanında ÇALIŞAN durumu da sınar (127.0.0.1 sondası). Ayrıntı ve gerekçe:
#  _domconf_fm_runtime_probe'un üstündeki blok.
#
#  --script: FPM chroot'una GÖRELİ, release İÇİNDE, docroot DIŞINDA .php yolu;
#  YALNIZ /current/modules/<Modül>/Auth/<ad>.php biçimi (tahmin yok, allowlist).
#  --region: pCloud bölgesi, yalnız eu (eapi.pcloud.com, varsayılan) | us (api.pcloud.com).
# ───────────────────────────────────────────────────────────────

# 'off' için engelleyici referanslar: kullanıcı dosyalarının FM adlarına (/__fm_auth,
# __fm_dl, /_fm/) başvurusu. PREDİKAT: 0=referans var (adlar stdout), 1=yok.
# Çözümlenemeyen yüklenebilir dosya = "referans VAR" (FAIL-CLOSED).
_DOMCONF_REF_HIT=0
_domconf_ref_cb() {
    shift 2
    local t
    for t in "$@"; do
        case "$t" in
            */__fm_auth*|*__fm_dl*|*/_fm/*) _DOMCONF_REF_HIT=1 ;;
        esac
    done
    return 0
}

_domconf_fm_auth_refs() {
    local dir="$1" sname="$2" f base found=1 prc
    for f in "$dir"/*.conf; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        if _fmprov_is_generated "$sname" "$f"; then continue; fi
        _DOMCONF_REF_HIT=0
        prc=0
        _domconf_nginx_parse "$f" _domconf_ref_cb || prc=$?
        if (( prc != 0 || _DOMCONF_REF_HIT )); then
            echo "$base"
            found=0
        fi
    done
    return $found
}

_domconf_fm_auth_status_core() {
    local domain="$1" sname="$2" dir="$3"
    local lrc=0 n present=0 s90 s21 s20 bad=0 exp_ver="" drift=0
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        warn "fm-auth STATE-UNTRUSTED: köken kaydı/dizini güvenilmez ($(_fmprov_dir)) — hiçbir dosya 'üretilmiş' tanınmaz (hepsi kullanıcı dosyası → izin listesine tabi). Çözüm: kayıt dizinini root:root 0700 yapın, sonra 'srvctl domain fm-root ${domain} --apply'"
        if _fmprov_emergency_present "$sname"; then
            info "  acil kapatma işareti var ($(_fmprov_emergency_where "$sname")): kayıt dizini düzeltilince de bu alan KAPALI sayılır; fm-root/repair/php-switch onu AÇMAZ"
        else
            warn "  acil kapatma işareti YOK: kayıt dizini düzeltilince kayıt 'on' diyorsa alan AÇIK sayılır — acil kapatma yaptıysanız önce kayıt dizinini root:root 0700 yapıp 'srvctl domain fm-auth ${domain} off' koşun (fm-root/repair açık kaydı yeniden üretir)"
            if ! _domconf_fm_disk_closed_proof "$dir" "$sname"; then _domconf_fm_untrusted_loud "$domain" "$sname" "durum doğrulaması"; fi
        fi
        return 1
    fi
    if _domconf_fm_reserved_present "$dir"; then present=1; fi
    if (( lrc == 1 )); then
        if (( present )); then
            warn "fm-auth KAYITSIZ (TAMPERED): köken kaydı yok ama FM dosya adları diskte — hiçbiri 'üretilmiş' sayılmaz (kullanıcı dosyası; izin listesine tabi). Çözüm: 'srvctl domain fm-root ${domain} --apply' (dosyaları <ad>.srvctl-tampered adli kopyasıyla devralır, 403 kökünü kurar) ya da dosyaları kaldırın/taşıyın"
            return 1
        fi
        # Köksüz alan GÜVENSİZ bir durumdur — sessiz bilgi + rc 0 DEĞİL.
        warn "fm-auth YOK: ${domain} — /_fm 403 kökü kurulu DEĞİL; /_fm ve /_fm/… uygulamaya (CI4) düşer. Kökü kurmak için: srvctl domain fm-root ${domain} --apply  (yalnız FM dosyası; 'repair'in geniş yan etkileri olmadan)"
        return 1
    fi

    s20=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_UP_FILE" "${dir}/${_DOMCONF_FM_UP_FILE}")
    if [[ "$_FMP_STATE" == "off" ]] && _fmprov_is_class4; then
        # Kayıt 'on' ama 20/21/90'dan biri TANINAN bir srvctl AÇIK eseri değil: kanıt/doğrulama YOK; hiçbir otomatik yol alanı AÇMAZ.
        # fm-root --apply/repair/php-switch/kurtarma bu alanı 403 köküne alır (kapatma yönü); 'fm-root --apply' ÖNERİLMEZ (durumu açık
        # kayda göre yeniden üretmeyi çağrıştırır). Alanı AÇAN tek komut açık 'fm-auth on'.
        warn "fm-auth TAMPERED (TANINMAYAN AÇIK ESER): ${domain} — kayıt 'on' yazıyor ama 20/21/90 (${_DOMCONF_FM_UP_FILE}, ${_DOMCONF_FM_DL_FILE}, ${_DOMCONF_FM_AUTH_FILE}) eserlerinden en az biri tanınan bir srvctl AÇIK eseri DEĞİL (20: ${s20/EKSIK/EKSİK}; 21: $(_fmprov_art_word "$_DOMCONF_FM_DL_FILE" "${dir}/${_DOMCONF_FM_DL_FILE}"); 90: $(_fmprov_art_word "$_DOMCONF_FM_AUTH_FILE" "${dir}/${_DOMCONF_FM_AUTH_FILE}"); eksik, yapısal sahte kök, bozuk imza, bilinmeyen içerik, kayıtta özeti olmayan, kurcalanmış/yabancı sahipli dosya ya da 90/21'li kapalı kök). Durum DOĞRULANAMADI: alan KAPALI sayılır; hiçbir otomatik yol (repair / fm-root / php-switch / kurtarma / toplu) bu alanı AÇMAZ, yalnız 403 köküne alır. Alanı AÇAN tek komut açık: srvctl domain fm-auth ${domain} on --script=… ; kapalı kalacaksa kaydı eşitleyip kökü yenilemek için: srvctl domain fm-auth ${domain} off"
        return 1
    fi
    if [[ "$_FMP_STATE" == "off" ]]; then
        if [[ -e "${dir}/${_DOMCONF_FM_AUTH_FILE}" || -L "${dir}/${_DOMCONF_FM_AUTH_FILE}" || -e "${dir}/${_DOMCONF_FM_DL_FILE}" || -L "${dir}/${_DOMCONF_FM_DL_FILE}" ]]; then
            warn "fm-auth TAMPERED: durum KAPALI ama 90/21 dosyaları diskte (kayıt dışı) — 'srvctl domain fm-auth ${domain} off' ya da 'srvctl domain fm-root ${domain} --apply' ile temizleyin"
            bad=1
        fi
        if [[ "$s20" == "OK" ]]; then
            if (( bad == 0 )); then info "fm-auth KAPALI (403 kökü): ${domain} — /_fm ve /_fm/ yolları 403 verir"; return 0; fi
            return 1
        fi
        if [[ "$s20" == "STALE" && "${_FMP_EMERGENCY:-0}" != "0" ]] \
            && _domconf_fm_closed_root_known "${dir}/${_DOMCONF_FM_UP_FILE}" "$sname" "$_FMP_HASHES"; then
            # kayıt 'on' + diskte eski biçimli (önceki tpl_ver ya da imzasız) srvctl 403 kökü = KAPALI KANITI.
            # Öneri 'off' (kaydı eşitler, kökü güncel imzaya yeniler); TAMPERED/onarım DEĞİL.
            # Bu hüküm YALNIZ diskteki 20 gerçekten tanınan bir kapalı kök ise verilir (_domconf_fm_closed_root_known);
            # işaret var diye "STALE = eski kapalı kök" varsaymak, AÇIK 20 duran bir diske "KAPALI KANITI" derdi.
            warn "fm-auth STALE (KAPALI KANITI): ${domain} — diskte srvctl'in ESKİ biçimli 403 kökü var (önceki şablon sürümü ya da imzasız); yol hâlâ 403 verir ve alan KAPALI sayılır. Kaydı eşitleyip kökü güncel imzaya yenilemek için: srvctl domain fm-auth ${domain} off"
        elif [[ "$s20" == "STALE" && "${_FMP_EMERGENCY:-0}" != "0" ]]; then
            warn "fm-auth STALE (KAPALI KANITI YOK): ${domain} — acil kapatma işareti/kanıtı var ama diskteki ${_DOMCONF_FM_UP_FILE} tanınan bir 403 kökü DEĞİL (AÇIK şablon ya da yarım kapatma): disk KAPATILMAMIŞ, FM AÇIK KALABİLİR (sonraki herhangi bir nginx reload'u yükler). Kapatmak için: srvctl domain fm-auth ${domain} off --emergency"
        elif [[ "$s20" == "TAMPERED" && "${_FMP_EMERGENCY:-0}" == "3" ]]; then
            # Kayıt 'on' + 90/21 yok + 20 srvctl 403 köküne BENZİYOR ama birebir değil (CRLF, sondaki boşluk,
            # satır içi yorum, mod 664/666, yabancı sahip, sert bağ …). Kanıt SAYILMAZ, ama hiçbir otomatik yol alanı AÇMAZ.
            warn "fm-auth TAMPERED (KAPALI GÖRÜNÜMLÜ KÖK): ${domain} — kayıt 'on' yazıyor, 90/21 yok ve ${_DOMCONF_FM_UP_FILE} srvctl'in 403 köküne BENZİYOR ama birebir/güvenli biçimde değil (satır sonu, sondaki boşluk, satır içi yorum, mod, sahip ya da sert bağ sapması): kanıt SAYILMAZ; ancak hiçbir otomatik yol (repair / fm-root / php-switch / kurtarma / toplu) bu alanı AÇMAZ. Alanı AÇAN tek komut açık: srvctl domain fm-auth ${domain} on --script=… ; kapalı kalacaksa kaydı eşitleyip kökü yenilemek için: srvctl domain fm-auth ${domain} off"
        elif [[ "$s20" == "STALE" ]]; then
            # STALE = srvctl'in kendi (eski şablonlu) 403 kökü: yol HÂLÂ 403 verir; yalnız yenilenmeli.
            warn "fm-auth STALE: KAPALI durumunda 403 kökü (${_DOMCONF_FM_UP_FILE}) srvctl üretimi ama güncel şablondan farklı — yol hâlâ 403 verir; yenilemek için: srvctl domain fm-root ${domain} --apply"
        else
            warn "fm-auth ${s20/EKSIK/EKSİK}: KAPALI durumunda 403 kökü (${_DOMCONF_FM_UP_FILE}) sağlam değil — yol CI4'e düşebilir. Çözüm: srvctl domain fm-root ${domain} --apply"
        fi
        return 1
    fi

    s90=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_AUTH_FILE" "${dir}/${_DOMCONF_FM_AUTH_FILE}")
    s21=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_DL_FILE" "${dir}/${_DOMCONF_FM_DL_FILE}")
    exp_ver=$( _derive_php "$domain" "${DEFAULT_PHP_VERSION}" 2>/dev/null ) || exp_ver=""
    if [[ -n "$exp_ver" && "$exp_ver" != "$_FMP_PHP" ]]; then drift=1; fi
    if [[ "$s90" == "OK" && "$s21" == "OK" && "$s20" == "OK" && $drift -eq 0 ]]; then
        info "fm-auth AÇIK: ${domain} → ${_FMP_SCRIPT} (bölge: ${_FMP_REGION}, php${_FMP_PHP})"
        info "  ${_DOMCONF_FM_AUTH_FILE}: OK  ${_DOMCONF_FM_DL_FILE}: OK  ${_DOMCONF_FM_UP_FILE}: OK"
        return 0
    fi
    local worst="STALE"
    for n in "$s90" "$s21" "$s20"; do
        if [[ "$n" == "TAMPERED" ]]; then worst="TAMPERED"; fi
    done
    for n in "$s90" "$s21" "$s20"; do
        if [[ "$n" == "EKSIK" && "$worst" != "TAMPERED" ]]; then worst="EKSİK"; fi
    done
    warn "fm-auth ${worst}: ${domain} — ${_DOMCONF_FM_AUTH_FILE}=${s90} ${_DOMCONF_FM_DL_FILE}=${s21} ${_DOMCONF_FM_UP_FILE}=${s20}${exp_ver:+ (havuz: php${exp_ver}, kayıt: php${_FMP_PHP})}"
    if [[ "$s20" != "OK" && "$s90" == "EKSIK" ]]; then
        warn "  yükleme (20) var ama auth (90) YOK — KAPI 2 belirteçsiz isteği 403'ler; yine de onarın: srvctl domain fm-root ${domain} --apply"
    fi
    warn "  Onarım (yalnız FM dosyaları, kayıtlı parametrelerle): srvctl domain fm-root ${domain} --apply  (PHP sürüm kayması için: srvctl domain repair ${domain})"
    return 1
}

# Ek savunma: durum, kayıt+özetten ÖTE iki şeyi daha denetler — (1) bu alanın yarım işlem
# yedeği (kesinti sonrası ara durum), (2) 'nginx -t' (özetler "sağlam" dese de yapılandırma host
# genelinde yüklenemiyorsa AÇIK/KAPALI demek yalandır). Hiçbir şey yazmaz.
_domconf_fm_auth_status() {
    local domain="$1" sname="$2" dir="$3" rc=0 bks legacy out trc=0 lrc=0 note=""
    # Güven kapısı çekirdek durumdan ÖNCE: güvenilmeyen custom.d/<sname> (sembolik bağ, root'a ait olmayan, g/o-yazılabilir; inode
    # taklidi dahil) içindeki "kayıtla eşleşen" dosyalar kiracının denetiminde olabilir; AÇIK/KAPALI/OK demek yalan olurdu.
    if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        warn "fm-auth GÜVENİLMEZ: ${domain} — ${_FMD_WHY} — durum DOĞRULANAMAZ: dosyalar kayıtla eşleşse bile kiracının denetimindeki bir dizinde olabilir; srvctl bu girdiyi izlemez ve hiçbir komut ona yazmaz. Alanı KAPATMAK için: srvctl domain fm-auth ${domain} off (girdiyi kenara alıp root sahipli dizinde 403 kökü kurar); incelemek için girdiyi root sahipli gerçek bir dizine çevirin"
        note=$(_domconf_fm_orphan_note "$domain" "$sname")
        if [[ -n "$note" ]]; then warn "$note"; fi
        return 1
    fi
    _domconf_fm_auth_status_core "$domain" "$sname" "$dir" || rc=$?
    bks=$(_fmprov_bk_list "$sname")
    # Sınıf 4 (kayıt 'on' + tanınmayan 20) alanında hiçbir ipucu 'fm-root --apply' önermez; kapatan 'fm-auth off', açan açık 'fm-auth on'.
    local c4=0
    _fmprov_load "$sname" || lrc=$?
    if _fmprov_is_class4; then c4=1; fi
    if [[ -n "$bks" ]]; then
        if (( lrc == 0 )) && [[ "$_FMP_STATE" == "off" ]]; then
            note=" (kayıt KAPALI: fm-root --apply bu yedeği GERİ YÜKLEMEZ — yalnız kenara ayırır ve dosyaları kayda göre yeniden değerlendirir; kapatma geri açılmaz)"
        fi
        if (( $(_fmprov_bk_count "$sname") > 1 )); then
            # Birden çok yedek — hangi yazımın doğru olduğu bilinemez; hiçbir yol geri yüklemez.
            warn "fm-auth YARIM İŞLEM (BİRDEN ÇOK YEDEK): ${domain} — $(tr '\n' ' ' <<< "$bks")— dosyalar/kayıt ara durumda olabilir; hiçbir otomatik yol bu yedekleri geri YÜKLEMEZ ve onlara DOKUNMAZ: repair / fm-root --apply / php-switch alanı 403 köküne KAPATIR (rc 1 kalır); yedekleri elle inceleyin. Yeniden açmak yalnız açık: srvctl domain fm-auth ${domain} on --script=…"
        elif (( c4 )); then
            warn "fm-auth YARIM İŞLEM: ${domain} — kesintiye uğramış bir FM yazımının yedeği duruyor ($(tr '\n' ' ' <<< "$bks")); dosyalar/kayıt ara durumda olabilir. Kayıt 'on' ama ${_DOMCONF_FM_UP_FILE} tanınan bir srvctl AÇIK eseri değil: yedek GERİ YÜKLENMEZ (kurtarma yalnız kapatma yönünde değiştirir). Kapatmak için: srvctl domain fm-auth ${domain} off ; AÇAN tek komut açık: srvctl domain fm-auth ${domain} on --script=…"
        else
            warn "fm-auth YARIM İŞLEM: ${domain} — kesintiye uğramış bir FM yazımının yedeği duruyor ($(tr '\n' ' ' <<< "$bks")); dosyalar/kayıt ara durumda olabilir. Kurtarma: srvctl domain fm-root ${domain} --apply${note}"
        fi
        rc=1
    fi
    legacy=$(_fmprov_bk_legacy_list)
    if [[ -n "$legacy" ]]; then
        warn "sahibi bilinmeyen (eski biçim) yarım işlem yedeği: $(tr '\n' ' ' <<< "$legacy")— hangi alana ait olduğu bilinemez; alan durumlarını ve 'nginx -t'yi denetleyip elle kaldırın"
    fi
    out=$(nginx -t 2>&1) || trc=$?
    if (( trc != 0 )); then
        if [[ "$out" == *"${dir}/"* ]]; then
            if (( c4 )); then
                warn "nginx -t BAŞARISIZ ve hata BU alanın custom.d dosyasında (${domain}) — yapılandırma host genelinde YÜKLENEMEZ (yukarıdaki durum gerçeği yansıtmıyor). Kayıt 'on' ama ${_DOMCONF_FM_UP_FILE} tanınmayan: alanı kapatmak için: srvctl domain fm-auth ${domain} off ; AÇAN tek komut açık: srvctl domain fm-auth ${domain} on --script=…"
            else
                warn "nginx -t BAŞARISIZ ve hata BU alanın custom.d dosyasında (${domain}) — yapılandırma host genelinde YÜKLENEMEZ (yukarıdaki durum gerçeği yansıtmıyor). Onarım: srvctl domain fm-root ${domain} --apply"
            fi
        else
            warn "nginx -t BAŞARISIZ (host geneli; hata bu alanın FM dosyasında değil) — 'nginx -t' çıktısına bakın"
        fi
        printf '%s\n' "$out" | tail -3 | sed 's/^/    /' >&2
        rc=1
    fi
    # ayrılmış (.superseded) yedeklerin varlığı/sayısı (bilgi; rc'yi DEĞİŞTİRMEZ).
    note=$(_fmprov_superseded_note "$sname")
    if [[ -n "$note" ]]; then
        if (( $(_fmprov_superseded_list "$sname" | grep -c .) > _FMP_SUPERSEDED_WARN )); then warn "$note"; else info "$note"; fi
    fi
    # acil kapatma artıkları (*.srvctl-emergency.*) görünür olsun (bilgi; eşik aşılınca uyarı; rc'yi DEĞİŞTİRMEZ).
    note=$(_domconf_fm_aside_note "$dir")
    if [[ -n "$note" ]]; then
        if (( $(_domconf_fm_aside_list "$dir" | grep -c .) > _FME_ASIDE_WARN )); then warn "$note"; else info "$note"; fi
    fi
    # yarıda kalmış kenara alma artıkları (custom.d/<sname>.srvctl-new.* / .srvctl-emergency.*): UYARI ve rc ≠ 0.
    note=$(_domconf_fm_orphan_note "$domain" "$sname")
    if [[ -n "$note" ]]; then warn "$note"; if (( rc == 0 )); then rc=1; fi; fi
    # ÇALIŞAN durum (disk değil). Kayıt AÇIK ise sonda AÇIK görmek tutarlıdır; kayıt/disk KAPALI (ya da kayıt
    # yok) iken sonda AÇIK imzası = reload edilmemiş/yüklenememiş eski yapılandırma → "FM HÂLÂ AÇIK", rc 1.
    lrc=0; _fmprov_load "$sname" || lrc=$?
    local disk_open=0 emerg=0
    if (( lrc == 0 )); then
        if [[ "$_FMP_STATE" == "on" ]]; then disk_open=1; fi
        emerg=$_FMP_EMERGENCY
    fi
    if (( emerg == 1 )); then
        info "fm-auth ACİL KAPATMA işareti var ($(_fmprov_emergency_where "$sname")): kayıt 'on' yazsa da KAPALI sayılır; yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' yeniden açar. Kaydı 'off'a eşitlemek için: srvctl domain fm-auth ${domain} off"
    elif (( emerg == 4 )); then
        info "fm-auth TANINMAYAN AÇIK ESER: kayıt 'on' yazıyor ama diskteki 20/21/90 eserlerinden (${_DOMCONF_FM_UP_FILE}, ${_DOMCONF_FM_DL_FILE}, ${_DOMCONF_FM_AUTH_FILE}) biri tanınan bir srvctl AÇIK eseri değil — alan KAPALI sayılır, hiçbir otomatik yol onu AÇMAZ (yalnız 403 köküne alır). Yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' açar; kaydı eşitlemek için: srvctl domain fm-auth ${domain} off"
    elif (( emerg == 3 )); then
        info "fm-auth KAPALI GÖRÜNÜMLÜ KÖK (kanıt değil): kayıt 'on' yazıyor, diskte 90/21 yok ve ${_DOMCONF_FM_UP_FILE} srvctl 403 köküne benziyor ama birebir değil — alan KAPALI sayılır, hiçbir otomatik yol onu AÇMAZ ('fm-root --apply' önerilmez). Yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' açar; kaydı eşitlemek için: srvctl domain fm-auth ${domain} off"
    elif (( emerg == 2 )); then
        # işaret yok ama disk kendi kendine kanıt: kayıt 'on', diskte yalnız srvctl 403 kökü (90/21 yok).
        info "fm-auth KAPALI KANITI: kayıt 'on' yazıyor ama diskte YALNIZ srvctl 403 kökü var (90/21 yok) — alan KAPALI sayılır (acil kapatma ya da yarım kalmış geçişten kalmış olabilir; işaret yok). repair / fm-root / php-switch / kurtarma bu alanı AÇMAZ ('fm-root --apply' önerilmez). Kaydı eşitlemek için: srvctl domain fm-auth ${domain} off; yeniden açmak için açık: srvctl domain fm-auth ${domain} on --script=…"
    fi
    _domconf_fm_runtime_probe "$domain"
    case "$_FMRT_STATE" in
        open)
            if (( disk_open )); then
                info "çalışan nginx: AÇIK imzası (411) — diskle tutarlı (${_FMRT_DETAIL})"
            else
                warn "FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla yüklemeye izin veriyor, oysa disk/kayıt KAPALI ya da kayıtsız (${_FMRT_DETAIL}). Önce: nginx -t, sonra systemctl reload nginx; gerekirse: srvctl domain fm-auth ${domain} off --emergency"
                rc=1
            fi ;;
        closed)
            if (( disk_open )); then
                # Kayıt AÇIK + çalışan KAPALI = kayıtla uyumlu doğrulanmış AÇIK DEĞİL → rc 0 verilmez (rc 4).
                warn "çalışan nginx KAPALI imzası (403) veriyor ama kayıt/disk AÇIK — reload bekliyor ya da yüklenemiyor olabilir (${_FMRT_DETAIL})"
                if (( rc == 0 )); then rc=4; fi
            elif (( lrc == 0 )); then
                # "Diskle tutarlı" DİSKTEN türetilir (kayıttan/işaretten DEĞİL): kapalı-disk kanıtı şart.
                if _domconf_fm_disk_closed_proof "$dir" "$sname"; then
                    info "çalışan nginx: KAPALI imzası (403) — diskle tutarlı (${_FMRT_DETAIL})"
                else
                    warn "çalışan nginx KAPALI imzası (403) veriyor AMA diskte KAPALI KÖK KANITI YOK (90/21 duruyor ya da ${_DOMCONF_FM_UP_FILE} tanınan 403 kökü değil) — çalışan durum diskle TUTARSIZ: bir sonraki nginx reload'u FM'yi AÇABİLİR (${_FMRT_DETAIL})"
                    if (( rc == 0 )); then rc=1; fi
                fi
            fi ;;
        *)
            # imza yoksa her zaman "doğrulanamadı" (kayıt VAR ya da YOK). Köksüz alanda uygulamanın kendi
            # 411/403'ü artık "AÇIK"/"KAPALI" sayılmaz; "FM HÂLÂ AÇIK" yalnız srvctl AÇIK imzasıyla basılır.
            # sonda KÖR (curl yok, bağlantı yok/yabancı imza, sunucu düzeyi 403/503/IP/basic-auth/UA kuralı, v1 şablon,
            # askıya alınmış alan …) → "doğrulanamadı" artık rc 0 DEĞİL, rc 4 (rc 0 yalnız doğrulanmış KAPALI ya da kayıtla
            # uyumlu doğrulanmış AÇIK). Çekirdek durum zaten bir sorun bildirdiyse (rc≠0) o kod korunur.
            if (( rc == 0 )); then rc=4; fi
            if (( lrc == 0 )); then
                info "çalışan durum DOĞRULANAMADI (${_FMRT_DETAIL}) — yukarıdaki durum yalnız DİSK/kayıt durumudur; reload sonrası gerçeği ayrıca doğrulayın (status rc 4 = doğrulanamadı)"
                if [[ -n "${_FMP_TPL:-}" && "$_FMP_TPL" != "$_DOMCONF_FM_TPL_VER" ]]; then
                    info "  kayıttaki şablon sürümü (tpl_ver ${_FMP_TPL}) güncel değil (${_DOMCONF_FM_TPL_VER}): yanıtta alan adına özgü imza yok. Yenilemek için: srvctl domain fm-root ${domain} --apply"
                fi
            else
                info "çalışan durum: srvctl FM imzası (srvctl-fm-closed/open) alınmadı — bu alanda srvctl üretimi FM kökü çalışmıyor ya da doğrulanamadı (${_FMRT_DETAIL}); uygulamanın kendi 403/411 yanıtı FM durumu kanıtı SAYILMAZ"
            fi ;;
    esac
    return $rc
}

# ───────────────────────────────────────────────────────────────
#  ÇALIŞAN DURUM SONDASI ve ACİL KAPATMA YOLU
#
#  GEREKÇE: "acil off her zaman başarır" ölçüldüğünde tutmadı: gerçek nginx lab'ında
#  15 off hücresinin 8'inde off reddedildi/geri alındı ve alan AÇIK kaldı (kayıt dizini güvenilmez, kilit
#  alınamadı, flock yok, nginx -t düştü, custom.d başvurusu --force'suz, kayıtsız FM dosyası …), reload
#  başarısız olunca da 'status' diskteki durumu "KAPALI" diyordu ama ÇALIŞAN nginx AÇIKTI.
#
#  KARAR (en katı seçenek): normal 'off' yolu hangi nedenle olursa olsun başarısız olursa OTOMATİK ACİL
#  YOLA düşülür (operatör acil anda bayrak bilmek zorunda kalmaz) + açık 'off --emergency' normal yolu
#  atlar. Acil yol MONOTONDUR — yalnız kapatma yönünde ilerler:
#    1. ÖNCE İŞARET: diske dokunmadan <sname>.emergency yazılır (kayıt dizini güvenilir ve kayıt varsa orada;
#       güvenilmezse ya da yazılamazsa kayıt dizininden BAĞIMSIZ ikinci konumda: ${SRVCTL_FM_EMERGENCY_DIR:-
#       /var/lib/srvctl/fm-emergency}, root:root 0700). _fmprov_load işaret varken 'on'u 'off'a ÇEVİRİR → repair /
#       fm-root / php-switch / yarım-işlem kurtarması kapatmayı geri AÇAMAZ; _domconf_fm_tx_commit işaret varken 'on'
#       yazmaz ve işareti YALNIZ açık 'fm-auth on'/'off' ile 'domain remove' kaldırır. Hiçbir yer güvenilir değilse
#       işaret yazılamaz: kapatma YİNE yapılır (disk kapatma monotondur) ama rc 6.
#       Ek savunma: kayıt 'on' + diskte yalnız srvctl 403 kökü (90/21 yok) = KAPALI kanıtı (_fmprov_closed_evidence).
#    1b. diski kapatır (işaretten SONRA): 20-srvctl-fm-upload.conf'u srvctl 403 köküne ATOMİK yazar (mktemp+mv; sembolik bağ
#       ya da dizin olan eski girdi önce kenara alınır), 90/21'i devre dışı bırakır (".srvctl-emergency.*"
#       adıyla kenara alır — *.conf glob'una UYMAZ; alınamazsa siler). Köken kaydına, kilide, custom.d
#       başvurularına (--force) ve 'nginx -t' geri almasına BAĞLI DEĞİLDİR; hiçbir hata yolunda eski
#       (açık) içeriği geri koymaz.
#    2. kayıt dizini güvenilir dizinse bu alanın bayat yarım-işlem yedeklerini geri yüklemeden ayırır; kilit
#       aşamasında kayıt 'off'a eşitlenir ve işaret kaldırılır.
#    3. nginx -t, geçerse reload (nginx -t düşerse reload DENENMEZ ve "reload edildi" sayılmaz: nginx -s reload
#       geçersiz yapılandırmada da rc 0 dönebilir, ana süreç ESKİ yapılandırmada kalır).
#    4. ÇALIŞAN durumu sınar (aşağıdaki sonda) ve GERÇEĞİ söyler:
#         rc 0  KAPALI: disk kapalı + reload tamam + sonda KAPALI imzası (403 + srvctl-fm-closed <imza>) + işaret (gerekliyse) yazıldı
#         rc 3  "FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla" (sonda 411 imzası)
#         rc 4  disk KAPALI ama çalışan durum DOĞRULANAMADI (KAPALI SAYILMAZ) / reload başarısız / disk KISMEN /
#               kilit bekleme süresi doldu (eşzamanlı yazıcı: kapanış kilit altında doğrulanamadı)
#         rc 5  disk KAPATILAMADI
#         rc 6  disk KAPALI + çalışan KAPALI AMA acil işareti hiçbir güvenilir yere yazılamadı (kalıcılık garantisiz)
#    5. KİLİT AŞAMASI: kilidi alana dek BEKLER (SRVCTL_FM_EMERGENCY_LOCK_WAIT, varsayılan 60 sn — bkz. aşağıda) ve
#       kilit altında kapanışı TEKRAR doğrular (eşzamanlı bir yazıcı arada açmış olabilir); kayıt güvenilirse 'off'a
#       eşitler. Disk ve nginx bu aşamadan ÖNCE kapatılır AMA bekleme yalnız raporu geciktirmez: sürmekte olan bir yazıcı diski arada
#       yeniden açmış olabilir; kapanış kilit altında yeniden doğrulanana dek kesin değildir. Süre dolarsa rc 4 ve ileti
#       "FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir)" der ("disk KAPALI" DEMEZ).
#       Kilit alınınca diskte DEĞİŞİKLİK olmasa da nginx BİR kez daha yüklenir ve sonda yapılır (yazıcı arada
#       açıp kendi geri almasıyla kapatmış, üçüncü bir reload AÇIK yapılandırmayı yüklemiş olabilir). SRVCTL_FM_EMERGENCY_LOCK_WAIT
#       sınırları: 0-9999 sn (0 = beklemeden dene); tanımsız/boş → 60 (sessiz); geçersiz (negatif, 'abc', 5+ hane, ondalık,
#       boşluklu) → 60 + uyarı. SRVCTL_FM_OFF_LOCK_WAIT (normal off, varsayılan 10) AYNI kuralı kullanır (_domconf_fm_lock_wait_env).
#    6. YAZICI TARAFI: _domconf_fm_stage kilit altında diske yazmadan ÖNCE işareti yeniden okur ('on' + açık `fm-auth on`
#       DEĞİL → ret, kapalı diske dokunulmaz); kapı reddi sonrası geri alma (_domconf_fm_fail_restore) diski yeniden kapattıktan
#       sonra nginx'i yükler ve çalışan durumu sınar (_domconf_fm_reclose_verify).
#
#  SONDA (status, acil yol, normal off): şema başına tek istek, YALNIZ 127.0.0.1 (curl --resolve
#  <alan>:<port>:127.0.0.1; dışarı istek yok): `PUT /_fm/up/1/0` GÖVDESİZ, Content-Length yok. Yükleme
#  location'ı rewrite aşamasında `$http_content_length = ""` → 411 döner (auth_request'ten ÖNCE, pCloud'a/FPM'e
#  hiçbir şey gitmeden); 403 kökü ise 403 döner.
#  YANIT GÖVDESİ İMZASI: ikisi de alan adına özgü gövde taşır (_domconf_fm_body_sig): kapalı kök
#  `srvctl-fm-closed <sig>`, açık yükleme `srvctl-fm-open <sig>`. Sonda YALNIZ (403 + gövde TAM `srvctl-fm-closed
#  <sig>`) → KAPALI, YALNIZ (411 + gövde TAM `srvctl-fm-open <sig>`) → AÇIK sayar; başka HER şey (imzasız 403/411,
#  başka alanın imzası, sunucu düzeyi 403, SSL'siz alanın 443'te başka vhost'a düşmesi, köksüz alanda uygulamanın
#  kendi 411/403'ü, 404/5xx/000/curl yok) "doğrulanamadı" kalır ve ASLA KAPALI uydurulmaz. Önceki sürüm her 403'ü
#  KAPALI sayıyordu. Neden yapılandırma-değişim/reload karşılaştırması DEĞİL: reload'un başarılı görünüp
#  worker'ların eski yapılandırmada kalması bu yöntemle yakalanmaz; sonda ÇALIŞAN davranışı doğrudan ölçer.
#  Sınır: yalnız belirli bir IP'de dinleyen (127.0.0.1'e kapalı) vhost'ta sonuç "doğrulanamadı" olur. Önce https
#  (SRVCTL_FM_PROBE_HTTPS_PORT, 443), sonra http (SRVCTL_FM_PROBE_HTTP_PORT, 80); bir şemanın portu "off"
#  verilirse o şema atlanır (hermetik lab: curl kalkanı yalnız kendi portuna izin verir). İlk KESİN (imzalı)
#  yanıt kararı verir.
# ───────────────────────────────────────────────────────────────
_FMRT_STATE="unknown"; _FMRT_DETAIL=""
_domconf_fm_runtime_probe() {
    local domain="$1" scheme port out="" code="" body="" tried="" sig sname want_closed want_open
    _FMRT_STATE="unknown"; _FMRT_DETAIL=""
    if ! [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _FMRT_DETAIL="alan adı sonda için güvenli değil"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        _FMRT_DETAIL="curl bulunamadı"
        return 0
    fi
    # alan adına özgü gövde imzası (bkz. _domconf_fm_body_sig). İmza üretilemezse sonda KARAR VERMEZ.
    sname=$(safe_name "$domain")
    if ! sig=$(_domconf_fm_body_sig "$sname"); then
        _FMRT_DETAIL="gövde imzası üretilemedi"
        return 0
    fi
    want_closed="srvctl-fm-closed ${sig}"; want_open="srvctl-fm-open ${sig}"
    for scheme in https http; do
        if [[ "$scheme" == "https" ]]; then port="${SRVCTL_FM_PROBE_HTTPS_PORT:-443}"; else port="${SRVCTL_FM_PROBE_HTTP_PORT:-80}"; fi
        # Port "off" / 0 / geçersiz → o şema ATLANIR (hermetik lab/entegrasyon ortamı yalnız kendi portunu sınar).
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || continue
        # Yanıt gövdesi + son satırda durum kodu (-w '\n%{http_code}'); gövde 1 KiB üstüyse curl keser (--max-filesize).
        # '|| true': bin/srvctl 'set -euo pipefail' altında curl hatası (bağlantı yok, 28, 63 …) betiği öldürmemeli.
        out=$(curl -s -k -o - -w '\n%{http_code}' --connect-timeout 2 --max-time 5 --noproxy '*' --path-as-is --max-filesize 1024 \
                    --resolve "${domain}:${port}:127.0.0.1" -X PUT -H 'Expect:' \
                    "${scheme}://${domain}:${port}/_fm/up/1/0" 2>/dev/null) || true
        code=""; body=""
        if [[ "$out" == *$'\n'* ]]; then code="${out##*$'\n'}"; body="${out%$'\n'*}"; fi
        [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
        tried+="${scheme}:${port}=${code} "
        # YALNIZ (403 + tam KAPALI imzası) ya da (411 + tam AÇIK imzası) durum kanıtıdır. İmzasız/başka alanın
        # imzalı her yanıt ("sunucu düzeyi 403", köksüz alanda uygulamanın 411'i, 443'te başka vhost, 404/5xx/000)
        # "doğrulanamadı" kalır ve sıradaki şemaya geçilir.
        if [[ "$code" == "403" && "$body" == "$want_closed" ]]; then _FMRT_STATE="closed"; break; fi
        if [[ "$code" == "411" && "$body" == "$want_open" ]]; then _FMRT_STATE="open"; break; fi
    done
    _FMRT_DETAIL="sonda 127.0.0.1, PUT /_fm/up/1/0 gövdesiz: ${tried% }"
    if [[ "$_FMRT_STATE" == "unknown" && -n "$tried" ]]; then _FMRT_DETAIL+=" — alan adına özgü imza (srvctl-fm-closed/open ${sig}) yok"; fi
    return 0
}

# Reload sonrası worker'ların yenilenmesi için kısa bekleyerek yeniden sınar (yalnız AÇIK görülürse).
_domconf_fm_runtime_probe_settled() {
    local domain="$1" i n="${SRVCTL_FM_PROBE_RETRIES:-3}"
    [[ "$n" =~ ^[1-9][0-9]?$ ]] || n=3
    for (( i = 1; i <= n; i++ )); do
        _domconf_fm_runtime_probe "$domain"
        [[ "$_FMRT_STATE" == "open" ]] || return 0
        if (( i < n )); then sleep "${SRVCTL_FM_PROBE_RETRY_SLEEP:-1}"; fi
    done
    return 0
}

# 20-srvctl-fm-upload.conf tam olarak srvctl 403 kökü mü (normal dosya, sembolik bağ değil, içerik eşit)? PREDİKAT.
_domconf_fm_em_off_root_ok() {
    local f="$1" sname="${2:-}" h want off_txt
    [[ -f "$f" && ! -L "$f" ]] || return 1
    h=$(_domconf_sha256_file "$f") || return 1
    off_txt=$(_domconf_fm_render_off "$sname") || return 1
    want=$(_domconf_sha256_text "$off_txt") || return 1
    [[ "$h" == "$want" ]]
}

# srvctl'in ürettiği HER kapalı-kök (403) biçiminin YAPISAL ve KATI tanıyıcısı. _domconf_fm_em_off_root_ok yalnız
# GÜNCEL tpl_ver'in köküne eşitti (tpl_ver artışı ya da eski imzasız kök "kanıt" sayılmıyor, `fm-root --apply`
# "kayıt on + kapalı kök" alanını AÇIYORDU). Tanınan biçimler:
#   (i)  İMZALI  (herhangi bir tpl_ver; imza 12 hex, alanın güncel imzası şart DEĞİL):
#          location = /_fm { return 403 "srvctl-fm-closed <12hex>"; }  +  location ^~ /_fm/ { return 403 "srvctl-fm-closed <12hex>"; }
#        (iki satırdaki imza AYNI); yalnız bu iki satır + `#` yorum/boş satırlar. Şablon sürümü 4+ kökü ayrıca TAM BİR KEZ
#        `location ^~ /__fm_ { internal; return 403; }` (ad alanı yakalayıcısı) taşır; o satır yalnız İMZALI kökte tanınır.
#   (ii) İMZASIZ eski biçim (`return 403;`) — YALNIZ özeti bilinen eski srvctl üretimi (aşağıdaki sabit) ya da köken
#        kaydında bu ad için kayıtlı olan özetlerden biriyse (yapısal + özet kaydı).
# Başka direktif / include / proxy_pass / ek location / başka biçim varsa (ya da dosya normal-root-sahipli-yazılamaz değilse)
# kanıt DEĞİLDİR. $1 dosya $2 sname (arayüz simetrisi; imza alana bağlanmaz) $3 kayıtlı özet satırları ("hex ad\n"...).
# PREDİKAT: 0 = kapalı kök. Salt-okur.
_DOMCONF_FM_LEGACY_OFF_SHA="36b4d899b2333ea8f3f744d03b142b6877882e9298420f3f1a2358b211d86b20"
_domconf_fm_closed_root_known() {
    local f="$1" recorded="${3:-}" line mode last2 h sig1="" sig2="" seen_eq=0 seen_pre=0 seen_ns=0 signed=0 size nonul
    local re_eq='^location = /_fm \{ return 403 "srvctl-fm-closed ([0-9a-f]{12})"; \}$'
    local re_pre='^location \^~ /_fm/ \{ return 403 "srvctl-fm-closed ([0-9a-f]{12})"; \}$'
    [[ -f "$f" && ! -L "$f" ]] || return 1
    [[ "$(_stat_nlink "$f")" == "1" ]] || return 1
    [[ "$(_stat_owner "$f")" == "root" ]] || return 1
    mode=$(_stat_mode "$f") || return 1
    last2="${mode: -2}"
    (( (${last2:0:1} & 2) == 0 && (${last2:1:1} & 2) == 0 )) || return 1
    # NUL bayt: `read` onları sessizce atar; yapısal denetim görmediği içerik hakkında karar vermesin.
    size=$(wc -c < "$f" | tr -d ' ') || return 1
    nonul=$(tr -d '\000' < "$f" | wc -c | tr -d ' ') || return 1
    [[ "$size" == "$nonul" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if [[ "$line" =~ $re_eq ]]; then
            (( seen_eq == 0 )) || return 1
            seen_eq=1; signed=1; sig1="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $re_pre ]]; then
            (( seen_pre == 0 )) || return 1
            seen_pre=1; signed=1; sig2="${BASH_REMATCH[1]}"
        elif [[ "$line" == 'location = /_fm { return 403; }' ]]; then
            (( seen_eq == 0 )) || return 1
            seen_eq=1
        elif [[ "$line" == 'location ^~ /_fm/ { return 403; }' ]]; then
            (( seen_pre == 0 )) || return 1
            seen_pre=1
        elif [[ "$line" == 'location ^~ /__fm_ { internal; return 403; }' ]]; then
            # '/__fm_' ad alanı yakalayıcısı (şablon sürümü 4+, yalnız İMZALI kökte): iç istek 403; kapalı kökü AÇMAZ.
            (( seen_ns == 0 )) || return 1
            seen_ns=1
        else
            return 1
        fi
    done < "$f"
    (( seen_eq && seen_pre )) || return 1
    (( seen_ns == 0 || signed )) || return 1
    # İmzalı + imzasız KARIŞIK dosya burada elenir: imzalı satır yalnız BİR imza (sig1 ya da sig2) doldurur → eşitlik sağlanamaz.
    if (( signed )); then
        [[ "$sig1" == "$sig2" ]]
        return
    fi
    h=$(_domconf_sha256_file "$f") || return 1
    [[ "$h" == "$_DOMCONF_FM_LEGACY_OFF_SHA" ]] && return 0
    case $'\n'"${recorded}" in
        *$'\n'"${h} ${_DOMCONF_FM_UP_FILE}"$'\n'*) return 0 ;;
    esac
    return 1
}

# KAPALI GÖRÜNÜMLÜ KÖK. _domconf_fm_closed_root_known "kanıt"tır (katı: satır satır birebir, metaveri
# güvenli). Bu yüklem daha GEVŞEKTİR ve YALNIZ "bu alanı otomatik AÇMA" kararı içindir (asla "kapalı doğrulandı" kararı değil):
# dosya normal dosya (sembolik bağ DEĞİL) ve — CR, baştaki/sondaki boşluk, satır içi/ayrı `#` yorum ve boş satırlar yok sayıldıktan
# sonra — YALNIZ iki konum satırından (`location = /_fm {…}` + `location ^~ /_fm/ {…}`, her biri tam bir kez; ek olarak şablon sürümü 4+ kökünün
# `location ^~ /__fm_ { internal; return 403; }` ad alanı yakalayıcısı en çok bir kez) oluşur; konum satırlarının ikisi de
# `return 403;` (eski imzasız biçim) ya da ikisi de AYNI 12-hex imzalı `return 403 "srvctl-fm-closed <12hex>";`. Dosya
# METAVERİSİ (mod, sahip, sert bağ sayısı) ARANMAZ: mod 664/666, yabancı sahip, sert bağ, CRLF, sondaki boşluk kozmetik sapmadır.
# Tırnaklı 403 GÖVDESİNDEKİ boşluk karakteri türü de kozmetiktir (`"srvctl-fm-closed<TAB>sig"`, çoklu boşluk, tırnak içi baş/son
# boşluk): imza DEĞERİ (12 hex) değişmedikçe lookalike'tır.
# Ek direktif / include / proxy_pass / ek ya da tekrarlı location / bozuk, farklı ya da karışık imza / NUL bayt → DEĞİL.
# PREDİKAT: 0 = kapalı görünümlü. Salt-okur.
_domconf_fm_closed_root_lookalike() {
    local f="$1" line seen_eq=0 seen_pre=0 seen_ns=0 sig1="" sig2="" size nonul
    local re_ns='^[[:space:]]*location[[:space:]]+\^~[[:space:]]+/__fm_[[:space:]]*\{[[:space:]]*internal[[:space:]]*;[[:space:]]*return[[:space:]]+403[[:space:]]*;[[:space:]]*\}[[:space:]]*$'
    local re_eq='^[[:space:]]*location[[:space:]]*=[[:space:]]*/_fm[[:space:]]*\{[[:space:]]*return[[:space:]]+403([[:space:]]+"[[:space:]]*srvctl-fm-closed[[:space:]]+([0-9a-f]{12})[[:space:]]*")?[[:space:]]*;[[:space:]]*\}[[:space:]]*$'
    local re_pre='^[[:space:]]*location[[:space:]]+\^~[[:space:]]+/_fm/[[:space:]]*\{[[:space:]]*return[[:space:]]+403([[:space:]]+"[[:space:]]*srvctl-fm-closed[[:space:]]+([0-9a-f]{12})[[:space:]]*")?[[:space:]]*;[[:space:]]*\}[[:space:]]*$'
    [[ -f "$f" && ! -L "$f" ]] || return 1
    size=$(wc -c < "$f" | tr -d ' ') || return 1
    nonul=$(tr -d '\000' < "$f" | wc -c | tr -d ' ') || return 1
    [[ "$size" == "$nonul" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line%%#*}"
        [[ -n "${line//[[:space:]]/}" ]] || continue
        if [[ "$line" =~ $re_eq ]]; then
            (( seen_eq == 0 )) || return 1
            seen_eq=1; sig1="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $re_pre ]]; then
            (( seen_pre == 0 )) || return 1
            seen_pre=1; sig2="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $re_ns ]]; then
            (( seen_ns == 0 )) || return 1
            seen_ns=1
        else
            return 1
        fi
    done < "$f"
    (( seen_eq && seen_pre )) || return 1
    [[ "$sig1" == "$sig2" ]]
}

# Bir girdiyi nginx'e görünmez yapar: ".srvctl-emergency.<pid>.<rnd>" adıyla kenara alır (adli; *.conf glob'una
# UYMAZ). ad ÇAKIŞIRSA yeni bir ad denenir (eskiden doğrudan 'rm -f' → adli kopya sessizce kaybolurdu); yalnız
# taşıma gerçekten başarısız olursa (izin / dosya sistemi) son çare olarak silinir — kapatma adli kopya uğruna ASLA
# ertelenmez. PREDİKAT: 0 = artık yok.
_domconf_fm_em_disable() {
    local f="$1" aside n=0
    [[ -e "$f" || -L "$f" ]] || return 0
    while (( n < 20 )); do
        aside="${f}.srvctl-emergency.$$.${RANDOM}"
        if [[ ! -e "$aside" && ! -L "$aside" ]]; then
            mv -f -- "$f" "$aside" 2>/dev/null || true
            break
        fi
        n=$((n + 1))
    done
    if [[ -e "$f" || -L "$f" ]]; then rm -f -- "${f:?}" 2>/dev/null || true; fi
    [[ ! -e "$f" && ! -L "$f" ]]
}

# Diski KAPATIR (kayıt/kilit/nginx -t'den bağımsız; İDEMPOTENT). _FME_DISK: closed | partial | failed;
# _FME_CHANGED: bu çağrı bir şey yazdı/kaldırdı mı; _FME_REMAIN: kapatılamayanlar (açıklama).
_FME_DISK="failed"; _FME_CHANGED=0; _FME_REMAIN=""
_FME_FOREIGN=""
_domconf_fm_em_close_disk() {
    local dir="$1" sname="${2:-}" phys f20 f f90=0 f21=0 off_txt foreign why=""
    _FME_DISK="failed"; _FME_CHANGED=0; _FME_REMAIN=""; _FME_FOREIGN=""
    # Gövde imzalı 403 kökü. Üretilemezse (sname güvensiz) boş dosya YAZILMAZ: 20 devre dışı bırakılır.
    off_txt=$(_domconf_fm_render_off "$sname") || off_txt=""
    # Sembolik bağ / yabancı sahipli dizin İZLENMEZ: girdinin KENDİSİ kenara alınır, yerine root sahipli dizin + 403 kökü kurulur
    # (yazım hedefe düşmez). Yapılamazsa disk kapatılmış sayılmaz (_FME_DISK=failed → çağıran "FM HÂLÂ AÇIK OLABİLİR" der).
    if [[ -n "$sname" ]] && ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        why="$_FMD_WHY"
        if _domconf_fm_dir_quarantine "$dir" "$sname"; then
            _FME_CHANGED=1
            warn "${dir} güvenilir DEĞİLDİ (${why}) — girdi kenara alındı (${_FMD_ASIDE:-yok}); yerine root sahipli dizin + 403 kökü kuruldu, hedefe/içine yazılmadı"
        else
            _FME_REMAIN="${dir} güvenilmez ve kenara alınamadı (${_FMD_WHY}); hedefe yazılmadı — FM HÂLÂ AÇIK OLABİLİR"
            return 1
        fi
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
        if [[ ! -d "$dir" ]]; then _FME_REMAIN="${dir} dizin değil"; return 1; fi
    else
        mkdir -p -- "$dir" 2>/dev/null || { _FME_REMAIN="${dir} oluşturulamadı"; return 1; }
        _FME_CHANGED=1
    fi
    phys=$(cd "$dir" 2>/dev/null && pwd -P) || { _FME_REMAIN="${dir} çözülemedi"; return 1; }
    f20="${phys}/${_DOMCONF_FM_UP_FILE}"
    if ! _domconf_fm_em_off_root_ok "$f20" "$sname"; then
        _FME_CHANGED=1
        # Dizin/sembolik bağ/yabancı içerik olan eski girdi önce kenara (mv -f dizinin İÇİNE düşerdi).
        if [[ -e "$f20" || -L "$f20" ]] && ! [[ -f "$f20" && ! -L "$f20" ]]; then
            _domconf_fm_em_disable "$f20" || true
        elif [[ -f "$f20" && ! -L "$f20" ]]; then
            # düz dosya olan 20 srvctl üretimi DEĞİLSE (kayıtla eşleşmeyen / tanınmayan = yabancı kullanıcı içeriği)
            # ezilmeden ÖNCE adli kopyası alınır: `<ad>.srvctl-foreign.<ts>` (*.conf glob'una UYMAZ, nginx yüklemez). Kopya
            # alınamazsa kapatma YİNE yapılır (adli kopya uğruna kapatma ertelenmez) ama uyarılır.
            if ! _domconf_fm_closed_root_known "$f20" "$sname" "" && ! _fmprov_is_generated "$sname" "$f20"; then
                foreign="${f20}.srvctl-foreign.$(date +%Y%m%d%H%M%S).$$.${RANDOM}"
                if [[ ! -e "$foreign" && ! -L "$foreign" ]] && cp -p -- "$f20" "$foreign" 2>/dev/null; then
                    _FME_FOREIGN="${_FME_FOREIGN}${foreign##*/} "
                else
                    warn "yabancı ${_DOMCONF_FM_UP_FILE} içeriğinin adli kopyası ALINAMADI (${foreign##*/}) — kapatma yine de yapılıyor"
                fi
            fi
        fi
        if [[ -z "$off_txt" ]] || ! _domconf_atomic_write "$f20" "$off_txt"; then
            # 403 kökü yazılamadı: en azından yükleme vekilini (eski 20) devre dışı bırak.
            _domconf_fm_em_disable "$f20" || _FME_REMAIN+="${_DOMCONF_FM_UP_FILE} (yazılamadı/devre dışı bırakılamadı) "
        fi
    fi
    for f in "${phys}/${_DOMCONF_FM_AUTH_FILE}" "${phys}/${_DOMCONF_FM_DL_FILE}"; do
        if [[ -e "$f" || -L "$f" ]]; then
            _FME_CHANGED=1
            _domconf_fm_em_disable "$f" || _FME_REMAIN+="${f##*/} (devre dışı bırakılamadı) "
        fi
    done
    # Doğrulama (yazımın SONUCU okunur; "yazdım" varsayımı yok).
    if [[ -e "${phys}/${_DOMCONF_FM_AUTH_FILE}" || -L "${phys}/${_DOMCONF_FM_AUTH_FILE}" ]]; then f90=1; fi
    if [[ -e "${phys}/${_DOMCONF_FM_DL_FILE}" || -L "${phys}/${_DOMCONF_FM_DL_FILE}" ]]; then f21=1; fi
    if _domconf_fm_em_off_root_ok "$f20" "$sname"; then
        if (( f90 == 0 && f21 == 0 )); then _FME_DISK="closed"; _FME_REMAIN=""; return 0; fi
        _FME_DISK="partial"
        return 1
    fi
    if [[ ! -e "$f20" && ! -L "$f20" ]]; then
        # 403 kökü yok ama yükleme vekili de yok: /_fm uygulamaya düşer (yükleme AÇIK DEĞİL).
        _FME_DISK="partial"; _FME_REMAIN+="403 kökü yazılamadı (/_fm uygulamaya düşer; yükleme vekili devre dışı) "
        return 1
    fi
    _FME_DISK="failed"; _FME_REMAIN+="${_DOMCONF_FM_UP_FILE} hâlâ eski/yabancı içerikte "
    return 1
}

# Bu alanın custom.d dizininde kenara alınmış acil kapatma artıkları (nginx YÜKLEMEZ — *.conf glob'una uymaz):
#   ".srvctl-emergency.<pid>.<rnd>" = kapatılan 90/21 (ve dizin/sembolik bağ olan eski 20 girdisi);
#   ".srvctl-foreign.<ts>…" = düz dosya olan YABANCI 20 içeriğinin ezilmeden önce alınan adli kopyası.
# (Eski yorum "yabancı 20 içeriği" diyordu ama düz dosya yabancı 20 kopyasız eziliyordu; artık ayrı adla korunur.)
# Her acil kapatma en çok 3 dosya bırakır; srvctl bunları ASLA okumaz, geri yüklemez, otomatik SİLMEZ (adli kanıt).
# Silme yalnız 'domain remove' (custom.d/<sname> dizininin kendisi silinir) ve operatörün elidir. status / nginx-audit /
# fm-root planı sayıyı gösterir; sayı _FME_ASIDE_WARN'ı aşınca birikme UYARI olur (eşik 10 dosya ≈ 5 acil kapatma:
# tekrarlayan kesinti ya da elle tekrarlanan 'off --emergency' işareti). Salt-okur; stdout: satır başına bir yol.
_FME_ASIDE_WARN=10
_domconf_fm_aside_list() {
    local dir="${1:-}" f
    [[ -n "$dir" && -d "$dir" ]] || return 0
    for f in "$dir"/*.srvctl-emergency.* "$dir"/*.srvctl-foreign.*; do
        if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
    done
    return 0
}

# Tek satırlık not (stdout; artık yoksa BOŞ). $1 = custom.d/<sname> dizini. Salt-okur.
_domconf_fm_aside_note() {
    local dir="${1:-}" lst n names warnpart=""
    lst=$(_domconf_fm_aside_list "$dir")
    [[ -n "$lst" ]] || return 0
    n=$(grep -c . <<< "$lst")
    names=$(sed 's#.*/##' <<< "$lst" | tr '\n' ' ' | sed 's/ $//')
    if (( n > _FME_ASIDE_WARN )); then
        warnpart=" — SAYI EŞİĞİ (${_FME_ASIDE_WARN}) AŞILDI: tekrarlayan acil kapatma var, nedenini araştırın"
    fi
    printf '%s adet acil kapatma artığı (*.srvctl-emergency.*) [%s]: nginx YÜKLEMEZ; adli kayıttır, srvctl bunları OKUMAZ, geri yüklemez ve otomatik SİLMEZ; inceleyip gereksizse elle silin (alan silinirse "domain remove" custom.d dizinini siler)%s' \
        "$n" "$names" "$warnpart"
    return 0
}

# YETİM kenara alma dizinleri (custom.d DİZİNİNİN içinde, custom.d/<sname> ile KARDEŞ): kenara alma (_domconf_fm_dir_quarantine)
# SIGKILL/elektrik kesintisi/dosya sistemi hatasıyla yarıda kalırsa '<sname>.srvctl-new.<pid>.<rnd>' (hazırlanan yeni dizin; içinde
# 403 kökü ve varsa kenara alınan eski girdi) ya da '<sname>.srvctl-emergency.<pid>.<rnd>' kardeşi geride kalır. nginx bunları
# YÜKLEMEZ (include yalnız custom.d/<sname>/*.conf). srvctl bunları OKUMAZ, geri yüklemez, SİLMEZ. Salt-okur; stdout: satır başına bir yol.
# $1 = sname.
_domconf_fm_orphan_list() {
    local sname="${1:-}" base f
    [[ -n "$sname" ]] || return 0
    base=$(_domconf_fm_dir "$sname")
    for f in "${base}".srvctl-new.* "${base}".srvctl-emergency.*; do
        if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
    done
    return 0
}

# Tek satırlık not (stdout; yetim yoksa BOŞ). $1 = domain $2 = sname. Salt-okur.
_domconf_fm_orphan_note() {
    local domain="${1:-}" sname="${2:-}" lst n names
    lst=$(_domconf_fm_orphan_list "$sname")
    [[ -n "$lst" ]] || return 0
    n=$(grep -c . <<< "$lst")
    names=$(sed 's#.*/##' <<< "$lst" | tr '\n' ' ' | sed 's/ $//')
    printf 'YETİM kenara alma dizini: %s adet [%s] — bir kapatma (kenara alma) yarıda kalmış; nginx bunları YÜKLEMEZ, srvctl OKUMAZ/SİLMEZ. custom.d/%s bu sırada eksik olabilir (/_fm uygulamaya düşer): önce "srvctl domain fm-auth %s off" ile kapatıp 403 kökünü kurun, sonra artıkları inceleyip elle silin' \
        "$n" "$names" "$sname" "$domain"
    return 0
}

# İŞARET DİSKTEN ÖNCE. Acil kapatma diske dokunmadan ÖNCE işareti yazar (diski kapattıktan SONRA yazmak yetmezdi:
# aradaki hata / SIGKILL penceresinde disk kapalı, kayıt 'on', işaret yok → 'status'un önerdiği komut alanı yeniden açıyordu).
# Nereye: kayıt dizini GÜVENİLİR ve bu alanın kaydı VARSA oraya (<sname>.emergency); kayıt dizini güvenilmezse (sembolik
# bağ, sahip/mod/yol yanlış) ya da oraya yazılamazsa İKİNCİ güvenilir konuma (root:root 0700, _fmprov_emergency_alt_dir).
# güvenilmez dizinde mktemp / printf / chmod / mv HİÇBİRİ çalışmaz (root sembolik bağ izleyerek yazmaz).
# Kayıt dizini hiç yoksa ya da dizin güvenilir ama bu alanın kaydı yoksa işaret GEREKMEZ (kayıt yok → 'on' diye okunacak
# bir şey yok; yetim işaret bırakılmaz). Sonuç: _FME_MARKER (1 = işaret bir konumda VAR), _FME_MARKER_WHERE
# (state | alt | mevcut), _FME_MARKER_NEED (1 = işaret gerekliydi), _FME_MARKER_WHY (yazılamama nedeni).
_FME_MARKER=0; _FME_MARKER_WHERE=""; _FME_MARKER_NEED=0; _FME_MARKER_WHY=""; _FME_SUPERSEDED=0
_domconf_fm_em_marker_put() {
    local dir="$1" marker="$2" sname="$3" tmp
    if [[ -d "$marker" ]]; then return 1; fi
    tmp=$(mktemp "${dir}/.${sname}.emerg.XXXXXX" 2>/dev/null) || return 1
    if printf 'srvctl-fm-emergency v1\n' > "$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$marker" \
       && [[ -f "$marker" && ! -L "$marker" ]]; then
        return 0
    fi
    rm -f -- "${tmp:?}"
    return 1
}

_domconf_fm_em_marker_write() {
    local sname="$1" dir man
    _FME_MARKER=0; _FME_MARKER_WHERE=""; _FME_MARKER_NEED=0; _FME_MARKER_WHY=""
    dir=$(_fmprov_dir); man=$(_fmprov_manifest "$sname")
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then return 0; fi
    if [[ -d "$dir" && ! -L "$dir" ]] && _fmprov_state_ok ""; then
        if [[ ! -e "$man" && ! -L "$man" ]]; then return 0; fi
        _FME_MARKER_NEED=1
        if _domconf_fm_em_marker_put "$dir" "$(_fmprov_emergency_marker "$sname")" "$sname"; then
            _FME_MARKER=1; _FME_MARKER_WHERE="state"; return 0
        fi
        _FME_MARKER_WHY="kayıt dizinine yazılamadı"
    else
        _FME_MARKER_NEED=1
        _FME_MARKER_WHY="kayıt dizini güvenilmez (sembolik bağ / sahip / mod / yol)"
    fi
    _domconf_fm_em_marker_write_alt "$sname"
}

# İşareti YALNIZ ikinci konuma yazar (kayıt dizinine HİÇ dokunmaz; kayıt dizininin güvenilmez/okunamaz olduğu durumlar için).
# _FME_MARKER_WHY çağıran tarafından önceden doldurulmuş olabilir; sonuç alanları _domconf_fm_em_marker_write ile aynıdır.
_domconf_fm_em_marker_write_alt() {
    local sname="$1" alt
    alt=$(_fmprov_emergency_alt_dir)
    if [[ ! -e "$alt" && ! -L "$alt" ]]; then
        mkdir -p -- "$alt" 2>/dev/null && chmod 700 "$alt" 2>/dev/null
    fi
    if _fmprov_emergency_alt_ok; then
        if _domconf_fm_em_marker_put "$alt" "$(_fmprov_emergency_alt_marker "$sname")" "$sname"; then
            _FME_MARKER=1; _FME_MARKER_WHERE="alt"; return 0
        fi
        _FMP_ALT_WHY="dizin güvenilir ama işaret dosyası yazılamadı"
    fi
    # ikinci konumun reddedilme NEDENİ iletide (mod / sahip / sembolik bağ / sondaki '/' / yazılamadı).
    _FME_MARKER_WHY+="; ikinci konum da güvenilir değil/yazılamadı ($(_fmprov_emergency_alt_dir)): ${_FMP_ALT_WHY:-neden bilinmiyor}"
    # Önceki bir acil kapatmanın işareti zaten duruyorsa koruma sürüyor demektir.
    if _fmprov_emergency_present "$sname"; then _FME_MARKER=1; _FME_MARKER_WHERE="mevcut"; fi
    return 0
}

# Kayıt dizini GÜVENİLİR dizinse: bu alanın bayat yarım-işlem yedeklerini geri yüklemeden ayırır (kayıt yokken bile
# yedek 'on' durumunu geri getirebilirdi). Güvenilmez dizinde HİÇBİR şey yapmaz.
# Yedek YALNIZ sahibi ölüyse bayattır. Yedeği alan yazıcı fm-auth kilidini yazım boyunca TUTAR; kilit
# tutuluyorsa sahibi SÜRÜYOR demektir ve yedeği kendi geri almasının girdisidir — ayrılırsa (.superseded) yazıcının kapı-reddi
# geri alması yedeksiz kalır (AÇIK 90/21/20 diskte kalıyordu). Bu yüzden:
#   $2 = "held": ÇAĞIRAN kilidi ZATEN tutuyor (kilit aşaması) → kilit sahibi ÇAĞIRAN, eldeki her yedek ölü sahibindir → ayır.
#   $2 boş  : kilitsiz çağrı → kilit ŞİMDİ ALINABİLİYORSA (sahip yok) ayır, kilit tutuluyorsa DOKUNMA; ayırma süresince kilit
#             tutulur (araya yeni bir yazıcı giremez). flock yoksa / kilit dosyası açılamazsa: sahip bilinemez → DOKUNMA.
# Dokunulmayan bayat yedek kilit aşamasında (acil, $2=held) ya da sahibi bitince bir sonraki fm-auth off/kurtarmada ayrılır.
_domconf_fm_em_state_guard() {
    local sname="$1" held="${2:-}" dir b lf got=0
    _FME_SUPERSEDED=0
    dir=$(_fmprov_dir)
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    _fmprov_state_ok "" || return 0
    if [[ "$held" != "held" ]]; then
        [[ -n "$(_fmprov_bk_list "$sname")" ]] || return 0
        lf="${dir}/.lock"
        [[ ! -L "$lf" ]] || return 0
        command -v flock >/dev/null 2>&1 || return 0
        ( umask 077; : >> "$lf" ) 2>/dev/null || return 0
        exec 9>>"$lf" || return 0
        if flock -n 9; then got=1; fi
        if (( ! got )); then exec 9>&-; return 0; fi
    fi
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        if _fmprov_bk_supersede "$b"; then _FME_SUPERSEDED=$((_FME_SUPERSEDED + 1)); fi
    done <<< "$(_fmprov_bk_list "$sname")"
    if [[ "$held" != "held" ]]; then exec 9>&-; fi
    return 0
}

# nginx -t, geçerse reload. _FME_RELOAD: ok | failed (reload komutu başarısız) | invalid (nginx -t düştü, reload
# DENENMEZ). 'systemctl reload nginx' geçersiz yapılandırmada da rc 0 dönebilir (nginx -s reload yalnız sinyali
# iletir, ana süreç yeni yapılandırmayı reddedip ESKİSİNDE kalır) — bu yüzden reload yalnız -t geçince
# sayılır. _FME_NGXT_OUT/_FME_NGXT_RC nginx -t çıktısıdır.
_FME_RELOAD="failed"; _FME_NGXT_OUT=""; _FME_NGXT_RC=0
_domconf_fm_em_reload() {
    local rrc=0
    _FME_NGXT_RC=0; _FME_NGXT_OUT=$(nginx -t 2>&1) || _FME_NGXT_RC=$?
    if (( _FME_NGXT_RC != 0 )); then _FME_RELOAD="invalid"; return 0; fi
    systemctl reload nginx >/dev/null 2>&1 || rrc=$?
    if (( rrc == 0 )); then _FME_RELOAD="ok"; else _FME_RELOAD="failed"; fi
    return 0
}

# Kilit ALTINDA: kapanışı tekrar doğrular (eşzamanlı yazıcı açmış olabilir) ve güvenilir kaydı 'off'a eşitler.
# _FME_RECLOSED: kapanış bu aşamada (yeniden) TAMAMLANDI → çağıran nginx'i yeniden yükler; _FME_PREV_DISK: bu aşamadan
# ÖNCEKİ disk durumu (arada biri açmış mıydı, yoksa ilk deneme mi yarım kalmıştı — D01 ileti ayrımı).
_FME_RECLOSED=0; _FME_RECORD="değişmedi"; _FME_PREV_DISK=""
_domconf_fm_auth_off_emergency_locked() {
    local domain="$1" sname="$2" dir="$3" lrc=0 h20
    _FME_RECLOSED=0; _FME_RECORD="değişmedi"; _FME_PREV_DISK="$_FME_DISK"
    _domconf_fm_em_close_disk "$dir" "$sname" || true
    if (( _FME_CHANGED )) && [[ "$_FME_DISK" == "closed" ]]; then _FME_RECLOSED=1; fi
    _domconf_fm_em_state_guard "$sname" held
    # Kilit alındıysa kayıt dizini artık GÜVENİLİRDİR (_fmprov_with_lock prepare_dir): ilk aşamada yazılamayan işaret şimdi yazılır.
    if (( _FME_MARKER_NEED && ! _FME_MARKER )); then _domconf_fm_em_marker_write "$sname"; fi
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 0 )) && [[ "$_FME_DISK" == "closed" ]]; then
        h20=$(_domconf_fm_render_off "$sname") || return 0
        h20=$(_domconf_sha256_text "$h20") || return 0
        if _fmprov_write "$sname" off "$_FMP_REGION" "$_FMP_SCRIPT" "$_FMP_PHP" "$_FMP_MODSEC" "${h20} ${_DOMCONF_FM_UP_FILE}"$'\n'; then
            _fmprov_emergency_clear "$sname"
            _FME_RECORD="off olarak yazıldı"
        fi
    elif (( lrc == 2 )); then
        _FME_RECORD="güvenilmez (STATE-UNTRUSTED) — yazılmadı"
    elif (( lrc == 1 )); then
        _FME_RECORD="yok"
    fi
    return 0
}

# Çalışan-durum kararı için kırmızı satır (error() gibi ÇIKMAZ).
_domconf_fm_em_fail() {
    echo -e "  ${RED}✗${NC}  $*" >&2
}

# rc≠0 dallarında çalışan durumu AÇIKÇA söyleyen tek satır (_FMRT_STATE, son sondadan). "Doğrulanamadı" KAPALI
# SAYILMAZ: FM HÂLÂ AÇIK OLABİLİR.
_domconf_fm_em_running_line() {
    case "$_FMRT_STATE" in
        open)   printf 'çalışan durum: AÇIK imzası (411) — FM HÂLÂ AÇIK (%s)' "$_FMRT_DETAIL" ;;
        closed) printf 'çalışan durum: KAPALI imzası (403) (%s)' "$_FMRT_DETAIL" ;;
        *)      printf 'çalışan durum: DOĞRULANAMADI — KAPALI SAYILMAZ, FM HÂLÂ AÇIK OLABİLİR (%s)' "$_FMRT_DETAIL" ;;
    esac
}

# $1 domain $2 sname $3 dir $4 neden (iletide) $5 dry(0|1). Dönüş kodları: yukarıdaki blok başlığına bakın.
_domconf_fm_auth_off_emergency() {
    local domain="$1" sname="$2" dir="$3" why="${4:-}" dry="${5:-0}"
    local t_int t_term t_hup lk=0 rc=0 disk reloadst saved_wait prevdisk lockwait mk
    if [[ "$dry" == "1" ]]; then
        info "DRY-OK (yazım yok): ACİL KAPATMA uygulanabilir — önce acil işareti yazılır, sonra ${_DOMCONF_FM_UP_FILE} 403 köküne ATOMİK yazılır, 90/21 devre dışı bırakılır; kayıt/kilit/custom.d başvurusu/'nginx -t' geri alması BEKLENMEZ; ardından nginx -t + reload + 127.0.0.1 sondası, kilit altında yeniden doğrulama ve gerçek durum raporu"
        return 0
    fi
    warn "ACİL KAPATMA: ${domain}${why:+ (${why})} — kayıt, kilit, custom.d başvurusu ve 'nginx -t' geri almasından BAĞIMSIZ; yalnız KAPATMA yönünde ilerler"
    t_int=$(trap -p INT); t_term=$(trap -p TERM); t_hup=$(trap -p HUP)
    trap '' INT TERM HUP

    # 1) İŞARET ÖNCE: diske dokunulmadan; bu noktadan sonra her hata/SIGKILL penceresinde repair/fm-root/php-switch/
    # kurtarma alanı yeniden AÇAMAZ. Yazılamazsa kapatma YİNE yapılır (monoton) ama rc≠0 verilir.
    _domconf_fm_em_marker_write "$sname"
    if (( _FME_MARKER )); then
        case "$_FME_MARKER_WHERE" in
            alt) mk="$(_fmprov_emergency_alt_marker "$sname")" ;;
            state) mk="$(_fmprov_emergency_marker "$sname")" ;;
            *) mk="$(_fmprov_emergency_marker "$sname") ya da $(_fmprov_emergency_alt_marker "$sname") (önceden yazılmış)" ;;
        esac
        info "acil kapatma işareti yazıldı (disk kapatılmadan ÖNCE): ${mk} — repair/fm-root/php-switch bu alanı yeniden AÇAMAZ; yalnız açık 'fm-auth on' açar"
    elif (( _FME_MARKER_NEED )); then
        _domconf_fm_em_fail "acil kapatma işareti YAZILAMADI (${_FME_MARKER_WHY}) — disk YİNE kapatılacak, ama kalıcılık işaretsiz: kayıt dizini düzelince 'repair' / 'fm-root --apply' / 'php-switch' alanı YENİDEN AÇABİLİR. Önce kayıt dizinini root:root 0700 yapıp 'srvctl domain fm-auth ${domain} off' koşun"
    fi

    # 2) disk
    _domconf_fm_em_close_disk "$dir" "$sname" || true
    disk="$_FME_DISK"
    if [[ -n "$_FME_FOREIGN" ]]; then warn "yabancı (srvctl üretimi olmayan) ${_DOMCONF_FM_UP_FILE} içeriği ezilmeden önce adli kopyalandı: ${_FME_FOREIGN}— ${dir}/ altında; nginx yüklemez, inceleyip gereksizse elle silin"; fi
    if [[ "$disk" != "closed" ]]; then _domconf_fm_em_fail "disk TAM kapatılamadı (${disk}): ${_FME_REMAIN}"; fi
    _domconf_fm_em_state_guard "$sname"
    if (( _FME_SUPERSEDED > 0 )); then info "bayat yarım işlem yedeği ${_FME_SUPERSEDED} adet geri yüklenmeden ayrıldı (kurtarma kapatmayı geri açamaz)"; fi
    _domconf_fm_em_reload

    # 3) Kilit aşaması: kilidi alana dek BEKLER (üst sınır SRVCTL_FM_EMERGENCY_LOCK_WAIT, varsayılan 60 sn) ve
    # kapanışı kilit altında YENİDEN doğrular. Disk ve nginx zaten kapatıldı AMA bekleme yalnız raporu geciktirmez: bu sürede bir yazıcı
    # diski yeniden açmış olabilir, kapanış kilit altında doğrulanana dek kesin değildir.
    # Süre bu bekleme dolunca kapanış "doğrulanamaz" sayılır (rc 4): eşzamanlı yazıcı bırakmadıysa son durumu bilemeyiz.
    if [[ -d "$(_fmprov_dir)" && ! -L "$(_fmprov_dir)" ]]; then
        lockwait=$(_domconf_fm_lock_wait_env SRVCTL_FM_EMERGENCY_LOCK_WAIT 60)
        saved_wait="$_FMP_LOCK_WAIT"
        _FMP_LOCK_WAIT="$lockwait"
        prevdisk="$disk"
        info "disk kapatıldı ve nginx yeniden yüklendi; kayıt/kilit aşaması bekleniyor (en çok ${lockwait} sn — eşzamanlı bir srvctl yazımı varsa bitmesi beklenir; bu sürede o yazıcı diski yeniden açmış olabilir, kapanış kilit altında doğrulanana dek kesin değildir)"
        _fmprov_with_lock _domconf_fm_auth_off_emergency_locked "$domain" "$sname" "$dir" || lk=1
        _FMP_LOCK_WAIT="$saved_wait"
        if (( lk )); then
            if (( _FMP_LOCK_TIMED_OUT )); then
                lk=2
                _domconf_fm_em_fail "kapanış DOĞRULANAMAZ: eşzamanlı bir srvctl yazıcısı fm-auth kilidini ${lockwait} sn boyunca bırakmadı — kapanış kilit altında yeniden doğrulanamadı, kayıt eşitlenmedi; yazıcı diski yeniden açmış olabilir (FM HÂLÂ AÇIK OLABİLİR). Yazıcı bitince: srvctl domain fm-auth ${domain} off (ve status) ile doğrulayın"
            else
                warn "kilit/kayıt aşaması UYGULANAMADI (kayıt dizini güvenilmez ya da flock yok: tüm FM yazımları da reddedilir) — disk kapanışı geçerli, kayıt eşitlenmedi (acil işareti: $( (( _FME_MARKER )) && printf yazıldı || printf yazılmadı )); 'srvctl domain fm-auth ${domain} status' ile doğrulayın"
            fi
        else
            disk="$_FME_DISK"
            info "kayıt: ${_FME_RECORD}"
            if (( _FME_RECLOSED )); then
                if [[ "$prevdisk" == "closed" ]]; then
                    warn "kilit altında kapanış YENİDEN yapıldı (arada biri açmıştı) — nginx yeniden yükleniyor"
                else
                    info "kilit altında kapanış TAMAMLANDI (ilk aşamada ${prevdisk} kalmıştı) — nginx yeniden yükleniyor"
                fi
            elif [[ "$disk" != "closed" ]]; then
                warn "kilit altında kapanış yeniden DENENDİ ama TAMAMLANAMADI (disk: ${disk}) — nginx yeniden yükleniyor"
            else
                # Diskte DEĞİŞİKLİK yok (eşzamanlı yazıcı açıp kendi geri almasıyla yeniden kapatmış olabilir; disk
                # kapalı görünür ama çalışan nginx o arada üçüncü bir reload ile AÇIK yapılandırmayı yüklemiş olabilir).
                # Kilidi alınca BİR kez daha reload + sonda yapılır; sonuç aşağıdaki karar tablosuna girer.
                info "kilit altında disk zaten KAPALI (değişiklik yok) — çalışan nginx'in de kapalı olduğundan emin olmak için nginx bir kez daha yükleniyor"
            fi
            _domconf_fm_em_reload
        fi
    fi

    reloadst="$_FME_RELOAD"
    if [[ "$reloadst" == "ok" ]]; then
        _domconf_fm_runtime_probe_settled "$domain"
    else
        _domconf_fm_runtime_probe "$domain"
    fi
    log_action "DOMAIN FM-AUTH off --emergency: ${domain} disk=${disk} reload=${reloadst} sonda=${_FMRT_STATE} isaret=${_FME_MARKER_WHERE:-yok} kilit=${lk}"

    # ── karar (gerçek durum): rc 0 YALNIZ disk KAPALI + reload tamam + sonda KAPALI imzası + (gerekliyse) işaret yazıldı ──
    if [[ "$disk" == "failed" ]]; then
        _domconf_fm_em_fail "ACİL KAPATMA BAŞARISIZ: disk KAPATILAMADI (${_FME_REMAIN})— ${_DOMCONF_FM_UP_FILE} ve 90/21'i ${dir}/ altında ELLE kaldırın, sonra: nginx -t && systemctl reload nginx"
        _domconf_fm_em_fail "  $(_domconf_fm_em_running_line)"
        rc=5
    elif [[ "$_FMRT_STATE" == "open" ]]; then
        if [[ "$reloadst" != "ok" ]]; then
            if [[ "$reloadst" == "invalid" ]]; then
                _domconf_fm_em_fail "FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla yüklemeye izin veriyor (disk KAPALI ama 'nginx -t' BAŞARISIZ, reload denenmedi: $(printf '%s' "$_FME_NGXT_OUT" | tail -1))"
            else
                _domconf_fm_em_fail "FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla yüklemeye izin veriyor (disk KAPALI ama 'systemctl reload nginx' BAŞARISIZ)"
            fi
        elif (( lk == 2 )); then
            # Kilit alınamadı: disk durumu kilit altında DOĞRULANMADI; "disk KAPALI / reload başarılı" iddiası yapılamaz.
            _domconf_fm_em_fail "FM HÂLÂ AÇIK — çalışan nginx yüklemeye izin veriyor; fm-auth kilidi ${lockwait} sn içinde alınamadı: eşzamanlı yazıcı (ör. açık 'fm-auth on') diski yeniden açıp yüklemiş olabilir — disk durumu kilit altında DOĞRULANMADI"
        else
            _domconf_fm_em_fail "FM HÂLÂ AÇIK — çalışan nginx hâlâ yüklemeye izin veriyor (disk KAPALI, reload başarılı görünüyor ama sonda AÇIK imzası verdi)"
        fi
        _domconf_fm_em_fail "  ${_FMRT_DETAIL}"
        if (( lk == 2 )); then
            _domconf_fm_em_fail "  Yapılacak: yazıcı bitince 'srvctl domain fm-auth ${domain} off --emergency' (kapanışı kilit altında yeniden doğrular), ardından 'srvctl domain fm-auth ${domain} status'"
        elif [[ "$reloadst" == "invalid" ]]; then
            _domconf_fm_em_fail "  Yapılacak: 'nginx -t' çıktısındaki hatayı giderin, sonra 'systemctl reload nginx'; en kötü durumda nginx'i yeniden başlatın; ardından: srvctl domain fm-auth ${domain} status"
        else
            _domconf_fm_em_fail "  Yapılacak: 'systemctl status nginx' / 'journalctl -u nginx' ile reload hatasını giderin, sonra 'systemctl reload nginx'; en kötü durumda nginx'i yeniden başlatın; ardından: srvctl domain fm-auth ${domain} status"
        fi
        rc=3
    elif [[ "$reloadst" != "ok" ]]; then
        if [[ "$_FMRT_STATE" == "closed" ]]; then
            _domconf_fm_em_fail "disk KAPALI ve çalışan nginx de KAPALI imzası veriyor (sonda 403) AMA nginx yeniden yüklenemedi — disk ile çalışan yapılandırma ayrışık: kapanış DOĞRULANMIŞ SAYILMAZ, nginx düzelince durum değişebilir (${_FMRT_DETAIL})"
        else
            _domconf_fm_em_fail "FM HÂLÂ AÇIK OLABİLİR — disk KAPALI ama nginx yeniden yüklenemedi (çalışan nginx eski yapılandırmayla sürüyor) ve çalışan durum doğrulanamadı (${_FMRT_DETAIL})"
        fi
        if [[ -n "$_FME_NGXT_OUT" ]]; then printf '%s\n' "$_FME_NGXT_OUT" | tail -3 | sed 's/^/    /' >&2; fi
        _domconf_fm_em_fail "  Yapılacak: yukarıdaki hatayı giderip 'systemctl reload nginx'; ardından: srvctl domain fm-auth ${domain} status"
        rc=4
    elif [[ "$disk" == "partial" ]]; then
        _domconf_fm_em_fail "ACİL KAPATMA KISMEN: yükleme vekili devre dışı ama ${_FME_REMAIN}"
        _domconf_fm_em_fail "  $(_domconf_fm_em_running_line)"
        rc=4
    elif (( lk == 2 )); then
        # Zaman aşımı "disk KAPALI" DEMEZ: kapanış ilk aşamada yazıldı ama kilit altında yeniden doğrulanamadı; kilidi tutan
        # eşzamanlı yazıcı o arada AÇIK dosyaları yeniden yazmış (ve bir reload AÇIK yapılandırmayı yüklemiş) olabilir.
        _domconf_fm_em_fail "ACİL KAPATMA DOĞRULANAMADI — FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir): kapanış ${lockwait} sn kilit beklemesinde yeniden doğrulanamadı; $(_domconf_fm_em_running_line)"
        _domconf_fm_em_fail "  Yapılacak: yazıcı bitince 'srvctl domain fm-auth ${domain} off' (kapanışı kilit altında yeniden doğrular), ardından 'srvctl domain fm-auth ${domain} status'"
        rc=4
    elif [[ "$_FMRT_STATE" != "closed" ]]; then
        _domconf_fm_em_fail "disk KAPALI ve nginx yeniden yüklendi AMA çalışan durum DOĞRULANAMADI — 'doğrulanamadı' KAPALI SAYILMAZ: FM HÂLÂ AÇIK OLABİLİR (${_FMRT_DETAIL})"
        _domconf_fm_em_fail "  Yapılacak: gövdesiz 'curl -sS -X PUT --resolve ${domain}:443:<origin> -o- -w \"%{http_code}\" https://${domain}/_fm/up/1/0' ile elle sınayın (403 + 'srvctl-fm-closed <imza>' beklenir); ardından: srvctl domain fm-auth ${domain} status"
        rc=4
    elif (( _FME_MARKER_NEED && ! _FME_MARKER )); then
        _domconf_fm_em_fail "disk KAPALI, çalışan durum KAPALI (sonda 403) AMA acil kapatma işareti YAZILAMADI — repair / fm-root / php-switch alanı YENİDEN AÇABİLİR. Önce kayıt dizinini root:root 0700 yapıp 'srvctl domain fm-auth ${domain} off' koşun"
        rc=6
    else
        success "fm-auth ACİL KAPATILDI: ${domain} — disk KAPALI, nginx yeniden yüklendi, çalışan durum KAPALI (sonda 403)"
        rc=0
    fi

    trap - INT TERM HUP
    if [[ -n "$t_int" ]]; then eval "$t_int"; fi
    if [[ -n "$t_term" ]]; then eval "$t_term"; fi
    if [[ -n "$t_hup" ]]; then eval "$t_hup"; fi
    return $rc
}

# 'fm-auth off' girişi: normal yol ALT KABUKTA koşar (error() çıkışı yakalansın); HERHANGİ bir nedenle
# başarısız olursa acil yola düşer. --emergency normal yolu atlar. --dry normal yolu AYNEN sınar.
# normal yol başarılı olsa da "kapatıldı" demeden ÇALIŞAN durum sınanır (acil yolla AYNI sözleşme): AÇIK imzası →
# acil yola geçilir (rc 3 "FM HÂLÂ AÇIK"); KAPALI imzası → rc 0; DOĞRULANAMADI → rc 4 (KAPALI sayılmaz).
_domconf_fm_auth_off_entry() {
    local domain="$1" sname="$2" dir="$3" force="$4" dry="$5" emergency="$6" nrc=0 saved_wait eflag
    if [[ "$emergency" == "1" ]]; then
        _domconf_fm_auth_off_emergency "$domain" "$sname" "$dir" "--emergency" "$dry"
        return $?
    fi
    if [[ "$dry" == "1" ]]; then
        _domconf_fm_auth_off "$domain" "$sname" "$dir" "$force" "$dry"
        return $?
    fi
    # Acil durumda 30 sn kilit beklemek kapatmayı geciktirir: normal denemenin kilit beklemesi 10 sn (acil yol
    # zaten kilitsiz kapatır); başka bir srvctl işlemi kısa süre tutuyorsa normal yol yine bekleyip başarır.
    saved_wait="$_FMP_LOCK_WAIT"; _FMP_LOCK_WAIT=$(_domconf_fm_lock_wait_env SRVCTL_FM_OFF_LOCK_WAIT 10)
    # "( … ) || nrc=$?" errexit'i alt kabukta SÖNDÜRÜRDÜ (test bağlamı): normal yolun 'set -e' davranışı eskisi gibi
    # kalsın diye çağıran kabukta errexit geçici kapatılır, alt kabukta (varsa) yeniden açılır.
    case $- in *e*) eflag=1 ;; *) eflag="" ;; esac
    set +e
    ( if [[ -n "$eflag" ]]; then set -e; fi; _domconf_fm_auth_off "$domain" "$sname" "$dir" "$force" "$dry" )
    nrc=$?
    if [[ -n "$eflag" ]]; then set -e; fi
    _FMP_LOCK_WAIT="$saved_wait"
    if (( nrc == 0 )); then
        _domconf_fm_runtime_probe_settled "$domain"
        case "$_FMRT_STATE" in
            closed)
                info "çalışan durum: KAPALI imzası (403) — kapanış çalışan nginx'te doğrulandı (${_FMRT_DETAIL})"
                return 0 ;;
            open)
                warn "normal 'fm-auth off' disk+reload başarılı göründü AMA çalışan nginx hâlâ AÇIK imzası (411) veriyor (reload sessizce uygulanmamış olabilir) — ACİL KAPATMA yoluna geçiliyor"
                _domconf_fm_auth_off_emergency "$domain" "$sname" "$dir" "normal off sonrası sonda AÇIK" 0
                return $? ;;
            *)
                _domconf_fm_em_fail "fm-auth kapatıldı (disk KAPALI, nginx yeniden yüklendi) AMA çalışan durum DOĞRULANAMADI — 'doğrulanamadı' KAPALI SAYILMAZ: FM HÂLÂ AÇIK OLABİLİR (${_FMRT_DETAIL})"
                _domconf_fm_em_fail "  Yapılacak: gövdesiz 'curl -sS -X PUT --resolve ${domain}:443:<origin> -o- -w \"%{http_code}\" https://${domain}/_fm/up/1/0' ile elle sınayın (403 + 'srvctl-fm-closed <imza>' beklenir); ardından: srvctl domain fm-auth ${domain} status"
                return 4 ;;
        esac
    fi
    warn "normal 'fm-auth off' BAŞARISIZ (rc=${nrc}) — kapatma yarım kalmasın diye ACİL KAPATMA yoluna geçiliyor"
    _domconf_fm_auth_off_emergency "$domain" "$sname" "$dir" "normal off rc=${nrc}" 0
}

_domconf_fm_auth_off_locked() {
    local domain="$1" sname="$2" force="$3" refs="$4" rc=0 lrc=0 region script php modsec taken="" stale="" b
    local dir; dir=$(_domconf_fm_dir "$sname")
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        error "fm-auth off REDDEDİLDİ: köken kaydı güvenilmez (STATE-UNTRUSTED) — önce kayıt dizinini root:root 0700 yapın"
    fi
    # Bayat yarım işlem yedeği kapatmadan SONRA kurtarmayla yeniden açabilirdi: kapatma başarılı
    # olunca yedek(ler) geri yüklenmeden kenara ayrılır (aşağıda). bu NORMAL yol kayıt/kilit/nginx -t
    # sağlığına bağlıdır ve başarısız olabilir; "off her zaman başarır" garantisi _domconf_fm_auth_off_entry'nin
    # otomatik ACİL yoluyla (_domconf_fm_auth_off_emergency) karşılanır — bu yol başarısız olursa o devreye girer.
    stale=$(_fmprov_bk_list "$sname")
    region="eu"; script="-"; php="-"; modsec="0"
    if (( lrc == 0 )); then region="$_FMP_REGION"; script="$_FMP_SCRIPT"; php="$_FMP_PHP"; modsec="$_FMP_MODSEC"; fi
    if (( lrc == 1 )); then
        _domconf_fm_reserved_present "$dir" || true; taken="$_FMX_PRESENT"
    fi
    _DOMCONF_FM_TX_ACTION="off"
    _domconf_fm_apply "$domain" "$sname" off "$region" "$script" "$php" "$modsec" 1 || rc=$?
    _DOMCONF_FM_TX_ACTION=""
    _domconf_fm_apply_check "$rc" "off"
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        if _fmprov_bk_supersede "$b"; then
            warn "bayat yarım işlem yedeği (${b##*/}) kapatmadan sonra GERİ YÜKLENMEYECEK biçimde ayrıldı (${_FMP_SUPERSEDED##*/}) — kurtarma komutları kapatmayı geri açamaz"
        else
            warn "bayat yarım işlem yedeği ayrılamadı: ${b} — kapatma yapıldı AMA 'fm-root --apply' bu yedeği (kayıt KAPALI olduğundan) geri yüklemez; elle inceleyin"
        fi
    done <<< "$stale"
    success "fm-auth kapatıldı: ${domain} (yükleme yolu 403 köküne alındı)"
    if [[ -n "$taken" ]]; then
        # KAPATAN eylemler (off, fm-root) kayıtsız FM adlarını adli kopyayla DEVRALIR (yol
        # 403'e kapanır); AÇAN/örtük eylemler (on, add, repair) reddeder — bilinçli, belgeli ayrım.
        warn "kayıtsız FM adlı dosya(lar) devralındı: ${taken}— eski içerik <ad>.srvctl-tampered olarak saklandı (normal dosyaysa)"
    fi
    if [[ -n "$refs" ]]; then
        warn "custom.d'de kullanan dosya(lar) duruyor: $(echo "$refs" | tr '\n' ' ')— bu dosyalar FM adlarına başvuruyor"
        log_action "DOMAIN FM-AUTH off --force: ${domain} (referans: $(echo "$refs" | tr '\n' ' '))"
    else
        log_action "DOMAIN FM-AUTH off: ${domain}"
    fi
    return 0
}

_domconf_fm_auth_off() {
    local domain="$1" sname="$2" dir="$3" force="$4" dry="$5"
    local refs="" lrc=0
    # STATE-UNTRUSTED önce söylenir — aksi halde kurcalanmış FM dosyaları "referans" sayılıp
    # önce --force istenir, --force ile de kayıt reddederdi (yanıltıcı iki adım).
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        error "fm-auth off REDDEDİLDİ: köken kaydı güvenilmez (STATE-UNTRUSTED) — --force bunu AŞMAZ. Önce kayıt dizinini root:root 0700 yapın ('srvctl domain fm-auth ${domain} status')"
    fi
    # custom.d'deki kullanıcı dosyaları FM adlarını kullanıyorsa kapatmak o yolu bozar
    # (kapı kalkınca bu dosya 403/CI4 davranışı verir): --force ister.
    if refs=$(_domconf_fm_auth_refs "$dir" "$sname") && [[ "$force" != "1" ]]; then
        error "fm-auth KAPATILMADI: custom.d'de FM adlarına başvuran dosya(lar) var: $(echo "$refs" | tr '\n' ' ')— önce o dosyaları kaldırın ya da bilerek kapatmak için: srvctl domain fm-auth ${domain} off --force"
    fi
    if [[ "$dry" == "1" ]]; then
        info "DRY-OK (yazım yok): fm-auth off uygulanabilir — 90/21 silinecek, ${_DOMCONF_FM_UP_FILE} 403 köküne alınacak"
        return 0
    fi
    _fmprov_with_lock _domconf_fm_auth_off_locked "$domain" "$sname" "$force" "$refs" \
        || error "fm-auth off uygulanamadı (kilit/kayıt dizini)"
}

# 'on' sonrası çalışan-durum sondası: reload'dan sonra worker'ların yenilenmesi için AÇIK imzası (411) görülene dek en çok
# SRVCTL_FM_PROBE_RETRIES (varsayılan 3) kez sınar (settled sonda'nın tersi: o AÇIK görülürse yeniden dener, bu KAPALI/bilinmiyor iken). Sonuç _FMRT_STATE.
_domconf_fm_on_probe_settle() {
    local domain="$1" i n="${SRVCTL_FM_PROBE_RETRIES:-3}"
    [[ "$n" =~ ^[1-9][0-9]?$ ]] || n=3
    for (( i = 1; i <= n; i++ )); do
        _domconf_fm_runtime_probe "$domain"
        [[ "$_FMRT_STATE" != "open" ]] || return 0
        if (( i < n )); then sleep "${SRVCTL_FM_PROBE_RETRY_SLEEP:-1}"; fi
    done
    return 0
}

# Geri alma da BAŞARISIZ oldu: acil kapatma işaretini (yeniden) yaz, diski acil kapatma yoluyla kapat; sonuç _FMUF_LINE'a (hata iletisinin
# ortasına girer). Çıkmaz, hata vermez; kapatma monotondur ve idempotenttir. $1 domain $2 sname $3 custom.d dizini.
_FMUF_LINE=""
_domconf_fm_on_unwind_force_close() {
    local sname="$2" dir="$3" mk="işaret YAZILAMADI" dk
    _domconf_fm_em_marker_write "$sname"
    if (( _FME_MARKER )); then mk="acil kapatma işareti yazıldı (otomatik yollar alanı yeniden AÇAMAZ)"; fi
    _domconf_fm_em_close_disk "$dir" "$sname" || true
    case "$_FME_DISK" in
        closed) dk="disk acil kapatma yoluyla KAPATILDI (403 kökü; 90/21 yok)" ;;
        *)      dk="disk TAM kapatılamadı (${_FME_DISK}: ${_FME_REMAIN:-?})" ;;
    esac
    _FMUF_LINE="${mk}; ${dk}; kayıt 'on' kalmış olabilir."
}

# Geri alma sırasında köken kaydı OKUNAMADI (rc 1: kayıt yok) ya da GÜVENİLMEZ (rc 2): kayıt dizinine HİÇBİR ŞEY yazılmaz (kayıt
# güvenilmezken yazım yok), ama alan açık bırakılmaz — disk, kayıttan ve kilitten bağımsız acil kapatma yoluyla (nginx custom.d
# dosyaları) kapatılır. Acil işaret kayıt dizinine YAZILMAZ; kayıt güvenilmezse (rc 2) yalnız kayıt dizininin dışındaki ikinci
# konuma yazılır (kayıt hiç yoksa 'on' diye okunacak bir şey olmadığından işaret gerekmez). Her zaman error (rc 1) ile biter.
# $1 domain $2 sname $3 custom.d dizini $4 _fmprov_load rc $5 hata iletisi başı.
_domconf_fm_on_unwind_no_record() {
    local domain="$1" sname="$2" dir="$3" lrc="$4" head="$5" mk="kayıt dizinine hiçbir şey yazılmadı" dk why
    if (( lrc == 2 )); then why="güvenilmez (STATE-UNTRUSTED)"; else why="yok/okunamadı"; fi
    if (( lrc == 2 )); then
        _FME_MARKER=0; _FME_MARKER_WHERE=""; _FME_MARKER_NEED=1; _FME_MARKER_WHY="kayıt dizini güvenilmez"
        _domconf_fm_em_marker_write_alt "$sname"
        if (( _FME_MARKER )); then mk+="; acil kapatma işareti kayıt dizininin DIŞINDA yazıldı ($(_fmprov_emergency_where "$sname"))"; fi
    fi
    _domconf_fm_em_close_disk "$dir" "$sname" || true
    case "$_FME_DISK" in
        closed) dk="disk acil kapatma yoluyla KAPATILDI (403 kökü; 90/21 yok)" ;;
        *)      dk="disk TAM kapatılamadı (${_FME_DISK}: ${_FME_REMAIN:-?})" ;;
    esac
    error "${head}; açılış GERİ ALINAMADI (köken kaydı ${why}) — ${mk}; ${dk}; kayıt 'on' kalmış olabilir, çalışan nginx eski yapılandırmayı sunabilir. FM HÂLÂ AÇIK OLABİLİR. Yapılacak: kayıt dizinini root:root 0700 yapın; srvctl domain fm-auth ${domain} off --emergency ; sonra: srvctl domain fm-auth ${domain} status"
}

# Yarım kalan 'fm-auth on'u GERİ AL (fm-auth kilidi ALTINDA çağrılır). $1 domain $2 sname $3 neden (reload|probe)
# $4 komuttan ÖNCEKİ kayıt durumu (on|off|none). Disk 403 köküne (90/21 kalkar, 20 = kök), kayıt 'off' (kayıt-disk tutarlı), nginx yeniden
# yüklenmeye çalışılır. Hata çıkışı (error, rc 1) BURADA verilir ve gerçeği söyler: kapatma geri alındı; çalışan nginx şu an ne sunuyor.
# Otomatik yollar yalnız kapatma yönünde: geri alma ASLA 'on' yazmaz. Önceki durum 'on' idiyse (zaten açık alanda başarısız bir
# yeniden 'on') geri alma onu KAPATIR — çalışan nginx eski AÇIK yapılandırmayla sürebilir → "FM HÂLÂ AÇIK OLABİLİR". Önceki durum kapalı/yoksa
# reload'u yüklenemeyen açılış çalışan nginx'e hiç girmemiştir: "AÇIK OLABİLİR" DENMEZ, ama çalışan durum doğrulanamıyorsa o da söylenir.
_domconf_fm_on_unwind_locked() {
    local domain="$1" sname="$2" why="$3" prev="${4:-none}" dir="${5:-}" lrc=0 urc=0 head tail runline=""
    if [[ -z "$dir" ]]; then dir=$(_domconf_fm_dir "$sname"); fi
    case "$why" in
        reload) head="fm-auth AÇILMADI: ${domain} — dosyalar ve kayıt yazıldı AMA nginx reload BAŞARISIZ" ;;
        *)      head="fm-auth AÇILMADI: ${domain} — nginx yeniden yüklendi AMA çalışan nginx hâlâ KAPALI imzası (403) veriyor (açılış çalışan yapılandırmaya yansımadı)" ;;
    esac
    _fmprov_load "$sname" || lrc=$?
    if (( lrc != 0 )); then
        _domconf_fm_on_unwind_no_record "$domain" "$sname" "$dir" "$lrc" "$head"
    fi
    # Geri almanın kendisi düşerse (nginx -t / sahneleme / geri yükleme) kendi yedeği AÇIK durumu taşır ve _domconf_fm_fail_restore onu geri
    # koyar. Bu yüzden acil kapatma işareti geri almadan ÖNCE yazılır: geri yükleme işaretli alanı dosyalar döndükten sonra yeniden kapatır
    # (açık eseri geri koyamaz). Geri alma başarılı olursa 'off' kaydı işareti kaldırır; işaret kalıcı kilit bırakmaz.
    _domconf_fm_em_marker_write "$sname"
    _domconf_fm_apply "$domain" "$sname" off "$_FMP_REGION" "$_FMP_SCRIPT" "$_FMP_PHP" "$_FMP_MODSEC" 1 || urc=$?
    case "$urc" in
        0|5) ;;
        *)
            _domconf_fm_on_unwind_force_close "$domain" "$sname" "$dir"
            error "${head}; açılış GERİ ALINAMADI (geri alma rc=${urc}) — ${_FMUF_LINE} FM HÂLÂ AÇIK OLABİLİR (çalışan nginx eski yapılandırmayı sunabilir; yedek: ${_FMA_KEEP_BK:-yok}). Yapılacak: srvctl domain fm-auth ${domain} off --emergency ; sonra: srvctl domain fm-auth ${domain} status" ;;
    esac
    _domconf_fm_runtime_probe_settled "$domain"
    case "$_FMRT_STATE" in
        open)   runline="çalışan durum: AÇIK imzası (411) — FM HÂLÂ AÇIK (${_FMRT_DETAIL})" ;;
        closed) runline="çalışan durum: KAPALI imzası (403) (${_FMRT_DETAIL})" ;;
        *)      runline="çalışan durum DOĞRULANAMADI (${_FMRT_DETAIL})" ;;
    esac
    if [[ "$urc" == "0" ]]; then
        tail="açılış GERİ ALINDI: disk 403 köküne (90/21 kaldırıldı), kayıt 'off'; nginx yeniden yüklendi. ${runline}"
        if [[ "$_FMRT_STATE" != "closed" ]]; then tail+=" — KAPALI doğrulanamadı: 'srvctl domain fm-auth ${domain} status'"; fi
        if [[ "$prev" == "on" ]]; then tail+=". Alan komuttan önce AÇIKTI; bu başarısız yeniden 'on' onu KAPATTI — yeniden açmak için nginx sorununu giderip 'fm-auth ${domain} on --script=…' çalıştırın"; fi
    else
        tail="açılış GERİ ALINDI: disk 403 köküne (90/21 kaldırıldı), kayıt 'off'; reload yeniden denendi, yine BAŞARISIZ — çalışan nginx reload öncesi yapılandırmayla sürüyor. ${runline}"
        if [[ "$prev" == "on" || "$_FMRT_STATE" == "open" ]]; then
            tail+=". FM HÂLÂ AÇIK OLABİLİR (alan komuttan önce AÇIKTI, çalışan nginx eski açık yapılandırmayı sunabilir): 'systemctl status nginx' ile reload hatasını giderip 'systemctl reload nginx'; gerekirse: srvctl domain fm-auth ${domain} off --emergency"
        else
            tail+=". Yeni açılış nginx'e hiç yüklenmedi; reload'u düzeltince diskle çalışan nginx hizalanır (disk KAPALI): 'systemctl status nginx' ; sonra: srvctl domain fm-auth ${domain} status"
        fi
    fi
    error "${head}; ${tail}"
}

_domconf_fm_auth_on_locked() {
    local domain="$1" sname="$2" dir="$3" script="$4" region="$5" php="$6" dry="$7"
    local lrc=0 n rc=0 find_rc=0 prev_state="none"
    _DOMCONF_FM_ON_RC=0
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 0 )); then prev_state="$_FMP_STATE"; fi
    if (( lrc == 2 )); then
        _domconf_fm_untrusted_loud "$domain" "$sname" "açılış (fm-auth on)"
        error "fm-auth on REDDEDİLDİ: köken kaydı güvenilmez (STATE-UNTRUSTED) — önce kayıt dizinini root:root 0700 yapın"
    fi
    if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        _domconf_fm_dir_refuse "$domain" "açılış (fm-auth on)"
        error "fm-auth on REDDEDİLDİ: ${_FMD_WHY} — hiçbir şey yazılmadı"
    fi
    if [[ -z "$region" ]]; then
        if (( lrc == 0 )); then region="$_FMP_REGION"; else region="eu"; fi
    fi
    _domconf_fm_region_host "$region" >/dev/null || error "Geçersiz --region: '${region}' (yalnız eu|us)"

    # Kayıtsız FM adı: köken kaydı yokken bu adlardan biri diskteyse kullanıcı dosyasıdır → ret.
    if (( lrc == 1 )); then
        if _domconf_fm_reserved_present "$dir"; then
            n="$_FMX_FIRST"
            error "fm-auth on REDDEDİLDİ: ${dir}/${n} köken kaydı OLMADAN diskte (kullanıcı dosyası sayılır; rezerve ad). Kaldırın/taşıyın ya da önce 'srvctl domain fm-root ${domain} --apply' (adli kopyayla devralıp 403 kökünü kurar), sonra yeniden deneyin"
        fi
    fi
    # Yarım işlem yedeği varken açma: önce kurtarma.
    if [[ -n "$(_fmprov_bk_list "$sname")" ]]; then
        error "fm-auth on REDDEDİLDİ: bu alanın yarım kalmış bir FM yazımı var — önce: srvctl domain fm-root ${domain} --apply"
    fi
    # Kullanıcı dosyaları (yeniden üretilecek 3 ad hariç) izin listesinden geçer; ihlal → ret.
    _domconf_scan_user_files "$domain" "$sname" "$dir" "$_DOMCONF_FM_AUTH_FILE $_DOMCONF_FM_DL_FILE $_DOMCONF_FM_UP_FILE" || find_rc=$?
    if (( find_rc != 0 )); then
        warn "alanın kullanıcı dosyalarında izin listesi ihlali/doğrulanamayan yapı var — fm-auth on REDDEDİLDİ (kullanıcı dosyası FM yolunu etkileyebilir):"
        printf '%s\n' "$_SUF_OUT" | grep -v '^BILGI' | sed 's/^/    /' >&2 || true
        error "Önce 'srvctl domain nginx-audit ${domain}' çıktısını giderin: dosyayı izin listesine uyacak biçimde düzenleyin ya da 'srvctl domain nginx-audit ${domain} --quarantine' ile ayırın (karantina yalnız 403 kökü SAĞLAM alanda ve yalnız kullanıcı dosyalarında çalışır; kök yoksa önce: srvctl domain fm-root ${domain} --apply)"
    fi

    if [[ "$dry" == "1" ]]; then
        info "DRY-OK (yazım yok): fm-auth on uygulanabilir — ${domain} → ${script} (bölge: ${region})"
        info "  yazılacak (sırayla): ${dir}/${_DOMCONF_FM_AUTH_FILE}, ${dir}/${_DOMCONF_FM_DL_FILE}, ${dir}/${_DOMCONF_FM_UP_FILE}"
        return 0
    fi
    # açık 'fm-auth on' kaydı (tüm kapılardan geçtikten sonra) acil kapatma işaretini kaldırabilir.
    _DOMCONF_FM_TX_ACTION="on"
    _domconf_fm_apply_detect "$domain" "$sname" on "$region" "$script" "$php" 1 || rc=$?
    _DOMCONF_FM_TX_ACTION=""
    # 'on' YARIM KALMAZ. rc 5 = dosyalar+kayıt 'on' YAZILDI (commit) ama nginx reload BAŞARISIZ → disk AÇIK + kayıt 'on'
    # kalırdı (sonraki herhangi bir reload ya da repair/fm-root alanı açardı). Geri al: disk 403 köküne, kayıt 'off'; hata çıkışı orada.
    if (( rc == 5 )); then _domconf_fm_on_unwind_locked "$domain" "$sname" reload "$prev_state" "$dir"; fi
    _domconf_fm_apply_check "$rc" "on"
    # "AÇILDI" demeden GERÇEK disk durumu okunur. Açık 'on' nginx -t / reload beklerken eşzamanlı bir acil kapatma
    # diski kapatabilir; commit kaydı yine de 'on' yazar ve işareti kaldırır → eskiden rc 0 "AÇILDI" denirdi, gerçek durum KAPALI
    # idi. Disk kayıtla uyuşmuyorsa (kayıt 'on' değil/yüklenemedi ya da 90/21/20 sağlam değil) gerçeği söyle, acil işaretini YENİDEN
    # koy (monoton: kapalı kalır) ve rc≠0 ile çık.
    lrc=0; _fmprov_load "$sname" || lrc=$?
    if (( lrc != 0 )) || [[ "$_FMP_STATE" != "on" ]] || ! _domconf_fm_files_ok "$sname" "$dir"; then
        _domconf_fm_em_marker_write "$sname"
        error "fm-auth AÇILMADI: ${domain} — yazım sırasında eşzamanlı bir acil kapatma (ya da başka bir yazıcı) diski değiştirdi; GERÇEK durum KAPALI/tutarsız (${_FMR_STATES:-kayıt okunamadı}). Acil kapatma işareti yeniden kondu (alan KAPALI kalır). Doğrulayın: srvctl domain fm-auth ${domain} status ; yeniden açmak için bu komutu tekrar çalıştırın"
    fi
    # Reload BAŞARILI ama çalışan nginx KAPALI imzası (403) veriyorsa açılış çalışan yapılandırmaya yansımamıştır (reload
    # sessizce uygulanmadı / yanlış worker): disk açık + kayıt 'on' + çalışan KAPALI tutarsızlığı bırakılmaz → geri al. YALNIZ KESİN 'closed'
    # imzası geri aldırır; 'doğrulanamadı' (curl yok, 443'te başka vhost, sonda kapalı) geri ALDIRMAZ (aksi halde sondası çalışmayan her alan açılamazdı).
    _domconf_fm_on_probe_settle "$domain"
    if [[ "$_FMRT_STATE" == "closed" ]]; then _domconf_fm_on_unwind_locked "$domain" "$sname" probe "$prev_state" "$dir"; fi
    if [[ "$_FMRT_STATE" == "open" ]]; then
        success "fm-auth AÇILDI: ${domain} → ${script} (bölge: ${region}, php${php})"
    else
        # Sonda ne AÇIK ne KAPALI imzası gördü → açılış geri ALINMAZ (sondası çalışmayan alan açılamaz olurdu) AMA
        # sessiz "AÇILDI" da denmez: yüksek sesli ileti + AYRI rc (_DOMCONF_FM_ON_RC=4, 'status'un doğrulanamadı koduyla aynı anlam).
        # Yalnız disk+kayıt gerçeği 'on'dur; canlı durum KANITLANMADI.
        _DOMCONF_FM_ON_RC=4
        warn "fm-auth AÇILDI, canlıda DOĞRULANAMADI (${_FMRT_DETAIL}): ${domain} → ${script} (bölge: ${region}, php${php}) — disk ve kayıt 'on' yazıldı, nginx yeniden yüklendi AMA çalışan durum AÇIK imzasıyla doğrulanmadı; açılış GERİ ALINMADI. rc 4. Doğrulayın: srvctl domain fm-auth ${domain} status ; açık kalmaması gerekiyorsa: srvctl domain fm-auth ${domain} off"
    fi
    info "  ${dir}/${_DOMCONF_FM_AUTH_FILE}, ${_DOMCONF_FM_DL_FILE}, ${_DOMCONF_FM_UP_FILE} (köken kaydı: $(_fmprov_manifest "$sname"))"
    log_action "DOMAIN FM-AUTH on: ${domain} script=${script} region=${region}$([[ "$_DOMCONF_FM_ON_RC" == "4" ]] && echo ' unverified=rc4')"
}

_domconf_fm_auth_on() {
    local domain="$1" sname="$2" dir="$3" script="$4" region="$5" dry="$6"
    [[ -n "$script" ]] || error "--script=<yol> zorunlu (ör. --script=/current/modules/FileManager/Auth/fm-auth.php)"
    _domconf_fm_auth_script_ok "$script" \
        || error "Geçersiz --script: '${script}' — /current/modules/<Modül>/Auth/<ad>.php biçiminde (harf/rakam/_/-) chroot-göreli yol olmalı"
    if [[ -n "$region" ]]; then
        _domconf_fm_region_host "$region" >/dev/null || error "Geçersiz --region: '${region}' (yalnız eu|us)"
    fi
    assert_safe_ident "$sname" || error "Geçersiz domain kimliği: ${sname}"

    local vhost="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${domain}.conf"
    if [[ -f "$vhost" ]] && ! grep -q "custom\.d/${sname}/" "$vhost"; then
        error "Bu domainin vhost'u custom.d dizinini include ETMİYOR (${vhost}) — fm-auth ETKİSİZ kalırdı. Çıkış: vhost'un server bloğuna elle 'include /etc/nginx/custom.d/${sname}/*.conf;' ekleyin, 'nginx -t' ile doğrulayıp reload edin, sonra bu komutu yeniden çalıştırın. $(_domconf_vhost_include_alt "$domain")"
    fi

    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    assert_php_version "$php_version" || error "Geçersiz PHP sürümü: ${php_version}"

    local why=""
    why=$(_domconf_fm_auth_host_script_check "$domain" "$script") \
        || error "Geçersiz --script (${script}): ${why}"

    local host_script="${WEB_ROOT}/${domain}${script}"
    [[ -f "$host_script" ]] || warn "Auth betiği şu an yok: ${host_script} — deploy sonrası var olmalı (yoksa her yükleme parçası 403 alır)"
    if [[ -e "${WEB_ROOT}/${domain}/current" && ! -d "${WEB_ROOT}/${domain}/current/public" ]]; then
        warn "Release'te public/ yok — docroot release KÖKÜNE bakıyor: ${script} web'den DOĞRUDAN erişilebilir olur. Auth betiğini public/ altı olan bir release yapısına taşıyın"
    fi

    # Şablonlar render edilebilir mi? (--dry de doğrular; yazım yok)
    local rrc=0
    _domconf_fm_render_auth "$sname" "$php_version" "$script" 1 >/dev/null || rrc=$?
    if [[ "$rrc" == "2" ]]; then error "fm-auth şablonu render hatası: beslenmeyen token kaldı — işlem durduruldu"; fi
    [[ "$rrc" == "0" ]] || error "fm-auth auth şablonu render edilemedi"
    _domconf_fm_render_download "$sname" >/dev/null || error "fm-auth indirme şablonu render edilemedi"
    _domconf_fm_render_upload "${region:-eu}" 1 "$sname" >/dev/null || error "fm-auth yükleme şablonu render edilemedi"

    if [[ "$dry" == "1" ]]; then
        # --dry SALT-OKURDUR: kayıt dizini/kilit dosyası YARATILMAZ (_fmprov_with_lock mkdir+touch yapar).
        # Gerçek çalıştırma flock'suz başarısız olacağından DRY-OK da bunu dürüstçe öngörür.
        command -v flock >/dev/null 2>&1 \
            || error "flock bulunamadı — fm-auth yazımı eşzamanlılık koruması olmadan YAPILMAZ (util-linux kurun); --dry bu yüzden BAŞARISIZ"
        _domconf_fm_auth_on_locked "$domain" "$sname" "$dir" "$script" "$region" "$php_version" "$dry" \
            || error "fm-auth on --dry başarısız"
        return 0
    fi
    _DOMCONF_FM_ON_RC=0
    if ! _fmprov_with_lock _domconf_fm_auth_on_locked "$domain" "$sname" "$dir" "$script" "$region" "$php_version" "$dry"; then
        # Kayıt dizini güvenilmezse (ya da var olan dizin yabancı sahipli/yazılabilir) hiçbir şey yazılmadı; alan zaten açık olabiliyorsa
        # öteki yollarla AYNI yüksek sesli ifade ("FM HÂLÂ AÇIK OLABİLİR" + düzeltme ipucu) söylenir.
        if ! _fmprov_state_ok "$sname"; then _domconf_fm_untrusted_loud "$domain" "$sname" "açılış (fm-auth on)"; fi
        error "fm-auth on uygulanamadı (kilit/kayıt dizini)"
    fi
    # 4 = açıldı ama canlıda doğrulanamadı (status rc 4 ile aynı anlam); 0 = doğrulanmış AÇIK.
    return "${_DOMCONF_FM_ON_RC:-0}"
}

# Yalnız UYARI: alanın kullanıcı dosyalarında izin listesi ihlali/doğrulanamayan yapı varsa söyler.
# Hiçbir şeye dokunmaz; dönüş HER ZAMAN 0.
_domconf_warn_user_violations() {
    local domain="$1" sname="$2" dir="$3" rc=0
    _domconf_scan_user_files "$domain" "$sname" "$dir" "$_DOMCONF_FM_AUTH_FILE $_DOMCONF_FM_DL_FILE $_DOMCONF_FM_UP_FILE" || rc=$?
    if (( rc != 0 )); then
        warn "custom.d kullanıcı dosyalarında izin listesi ihlali/doğrulanamayan yapı var (${domain}) — dosyalar DEĞİŞTİRİLMEDİ; ayrıntı: srvctl domain nginx-audit ${domain}"
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────
#  403 KÖKÜ — HER alanda (fm-auth açık olmasa da): 'domain add', 'domain repair' ve
#  'domain fm-root' yazar.
#  Kullanıcı kararı (2026-10-25): /_fm yolu hiç açılmamış alanda CI4 catch-all'a DÜŞMEZ.
#  İçerik = fm-auth 'off' kökü (location = /_fm + ^~ /_fm/ → 403); köken kaydına
#  `state off` ile girer (kullanıcı dosyası olamaz). 'fm-auth on' bu dosyanın yerini
#  gerçek yapılandırmayla alır, 'off' kökü geri bırakır.
#  Kayıt VARSA "dokunmaz" DEĞİL — dosyalar kayıtla doğrulanır (_domconf_fm_files_ok);
#  eksik/kurcalanmış/bayatsa KAYITLI parametrelerle (açık alan açık) yeniden üretilir, üretilemezse rc 1.
#  Kayıt YOK ama FM adlı dosya diskte → kullanıcı dosyası sayılır, EZİLMEZ: uyarı + rc 1
#  (bilinçli devralma yalnız 'fm-root --apply' ve 'fm-auth off' ile).
#  nginx -t başarısızsa dosya+kayıt GERİ ALINIR (çalışan yapılandırma kırılmaz).
#  $1 domain $2 reload(0|1). Dönüş: 0=kurulu/sağlam, 1=kurulamadı (neden uyarıda).
# ───────────────────────────────────────────────────────────────
# apply dönüş kodunu kök iletisine çevirir. rc 0/1.
_domconf_fm_root_rc_report() {
    local domain="$1" rc="$2" closing="${3:-0}"
    case "$rc" in
        0) return 0 ;;
        3) warn "403 kökü kurulamadı (${domain}): nginx -t başarısız — dosya+kayıt geri alındı, reload YAPILMADI (çalışan yapılandırma korundu):"
           printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2 ;;
        5) # closing=1: yazılan kapatmaydı (kayıt off ya da tanınmayan açık eser kapatıldı) — çalışan nginx eski (AÇIK olabilen) yapılandırmada kalır.
           if [[ "$closing" == "1" ]]; then
               warn "403 kökü yazıldı (config geçerli) ama nginx reload başarısız (${domain}) — FM HÂLÂ AÇIK OLABİLİR (çalışan nginx eski yapılandırmada); systemctl status nginx; gerekirse: srvctl domain fm-auth ${domain} off --emergency"
           else
               warn "403 kökü yazıldı (config geçerli) ama nginx reload başarısız (${domain}) — systemctl status nginx"
           fi ;;
        6) warn "403 kökü kurulamadı (${domain}) VE GERİ ALMA BAŞARISIZ — yedek: ${_FMA_KEEP_BK:-?}; srvctl domain fm-auth ${domain} status" ;;
        7) warn "403 kökü/FM dosyaları yeniden üretilemedi (${domain}): ModSecurity yetenek tespiti yapılamadı — hiçbir şey yazılmadı:"
           printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2 ;;
        *) warn "403 kökü kurulamadı (${domain}): render/yazım/köken kaydı hatası — geri alındı" ;;
    esac
    return 1
}

# Kayıtlı durumu (_fmprov_load sonrası _FMP_*) yeniden üretir. Kilit altında. rc: apply kodu.
_domconf_fm_regen_recorded_locked() {
    local domain="$1" sname="$2" reload="$3" st="$_FMP_STATE" rg="$_FMP_REGION" sc="$_FMP_SCRIPT" ph="$_FMP_PHP" ms="$_FMP_MODSEC" php rc=0
    if [[ "$st" == "on" ]]; then
        php=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}" 2>/dev/null) || php="$ph"
        assert_php_version "$php" || php="$ph"
        _domconf_fm_apply_detect "$domain" "$sname" on "$rg" "$sc" "$php" "$reload" || rc=$?
    else
        _domconf_fm_apply "$domain" "$sname" off "$rg" "$sc" "$ph" "$ms" "$reload" || rc=$?
    fi
    return $rc
}

# ÇALIŞAN DURUM UZLAŞTIRMASI (yalnız KAPATMA yönü). Diskte KAPALI kanıtı olan (90/21 yok, 20 srvctl'in tanınan 403 kökü) alanda çalışan
# nginx KESİN KAPALI imzası (403 srvctl-fm-closed) vermiyorsa — 'off' commit'i ile reload arasındaki kesinti ya da yüklenmeyen bir yazım — yazılacak
# bir şey olmadığından repair / fm-root / provision eskiden reload YAPMAZ ve rc 0 dönerdi. Bu işlev yapılandırmayı yeniden yükler ve KAPALI
# imzasını doğrular. YALNIZ KESİN KAPALI çalışan durumda DOKUNMAZ: AÇIK imzası da, sonda kör (doğrulanamıyor: curl yok, iki portta başka imza,
# sunucu düzeyi 403/503, limit_req) durum da "çalışan nginx diskten farklı olabilir" sayılır ve yapılandırma KOŞULSUZ yeniden yüklenir (fail-closed).
# Sonda kör iken reload başarılıysa rc 0 ama ileti çalışan KAPALI durumun doğrulanamadığını söyler (sessiz başarı yok).
# $1 domain $2 reload (1 = şimdi nginx -t + reload; 0 = toplu çağıran sonda tek reload yapar: _DOMCONF_FM_WROTE=1).
# rc 0 = sorun yok / giderildi / toplu reload'a bırakıldı; rc 1 = nginx -t ya da reload başarısız ya da sonra AÇIK görüldü
# ("FM HÂLÂ AÇIK OLABİLİR").
_DOMCONF_FM_SYNC_RELOADED=0   # bu işlev yeniden yükleme yaptı/planladı (çağıranın "yazılacak bir şey yok: reload ÇALIŞTIRILMADI" iletisi doğru kalsın)
_domconf_fm_running_closed_sync() {
    local domain="$1" reload="${2:-1}" sname dir was
    sname=$(safe_name "$domain"); dir=$(_domconf_fm_dir "$sname")
    _domconf_fm_disk_closed_proof "$dir" "$sname" || return 0
    _domconf_fm_runtime_probe "$domain"
    [[ "$_FMRT_STATE" != "closed" ]] || return 0
    was="$_FMRT_STATE"
    _DOMCONF_FM_SYNC_RELOADED=1
    if [[ "$was" == "open" ]]; then
        warn "${domain}: disk KAPALI (403 kökü, 90/21 yok) ama ÇALIŞAN nginx hâlâ AÇIK imzası veriyor (${_FMRT_DETAIL}) — yapılandırma yeniden yükleniyor"
    else
        warn "${domain}: disk KAPALI (403 kökü, 90/21 yok) ama çalışan nginx'in durumu DOĞRULANAMADI (${_FMRT_DETAIL}) — eski AÇIK yapılandırmada olabilir; yapılandırma yeniden yükleniyor"
    fi
    if [[ "$reload" != "1" ]]; then
        _DOMCONF_FM_WROTE=1
        return 0
    fi
    if ! nginx -t >/dev/null 2>&1; then
        warn "FM HÂLÂ AÇIK OLABİLİR — ${domain}: disk KAPALI ama nginx -t BAŞARISIZ, reload YAPILAMADI (çalışan nginx eski AÇIK yapılandırmada). nginx -t çıktısını giderin, sonra: systemctl reload nginx; gerekirse: srvctl domain fm-auth ${domain} off --emergency"
        return 1
    fi
    if ! systemctl reload nginx >/dev/null 2>&1; then
        warn "FM HÂLÂ AÇIK OLABİLİR — ${domain}: disk KAPALI ama nginx reload BAŞARISIZ (çalışan nginx eski AÇIK yapılandırmada): systemctl status nginx; gerekirse: srvctl domain fm-auth ${domain} off --emergency"
        return 1
    fi
    _domconf_fm_runtime_probe_settled "$domain"
    if [[ "$_FMRT_STATE" == "closed" ]]; then
        success "${domain}: nginx yeniden yüklendi; çalışan durum KAPALI imzası (403) veriyor"
        return 0
    fi
    if [[ "$was" != "open" && "$_FMRT_STATE" != "open" ]]; then
        # Sonda önce de sonra da kör: reload BAŞARILI ve diskte KAPALI kanıtı var → kapatma yüklendi; yalnız canlı doğrulama yok.
        warn "${domain}: nginx yeniden yüklendi (disk KAPALI) ama çalışan durum KAPALI imzasıyla DOĞRULANAMADI (${_FMRT_DETAIL}) — doğrulayın: srvctl domain fm-auth ${domain} status"
        return 0
    fi
    warn "FM HÂLÂ AÇIK OLABİLİR — ${domain}: reload sonrası çalışan durum KAPALI doğrulanamadı (${_FMRT_DETAIL}); gerekirse: srvctl domain fm-auth ${domain} off --emergency"
    return 1
}

_domconf_fm_root_provision_locked() {
    local domain="$1" sname="$2" reload="$3" dir rc=0 lrc=0
    dir=$(_domconf_fm_dir "$sname")
    # Birden çok yarım işlem yedeği = alan KAPATILIR, yedeklere dokunulmaz, rc 1 (sağlam görünen açık alan dahil).
    if (( $(_fmprov_bk_count "$sname") > 1 )); then
        _fmprov_multi_bk_close_locked "$domain" "$sname" "$reload"
        return 1
    fi
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then
        warn "403 kökü kurulamadı (${domain}): köken kaydı güvenilmez (STATE-UNTRUSTED) — kayıt dizinini root:root 0700 yapın"
        _domconf_fm_untrusted_loud "$domain" "$sname" "403 kökü kurulumu"
        return 1
    fi
    if (( lrc == 0 )); then
        # Kayıt var / dosya yok (yarım remove + yeniden add, state yedekten geri, custom.d
        # elle silinmiş) artık sessiz rc 0 DEĞİL.
        if _domconf_fm_files_ok "$sname" "$dir"; then
            # Yazılacak bir şey yok; ama disk KAPALI iken çalışan nginx hâlâ AÇIK olabilir (kesinti): uzlaştır.
            _domconf_fm_running_closed_sync "$domain" "$reload"
            return $?
        fi
        warn "403 kökü/FM dosyaları köken kaydıyla UYUŞMUYOR (${domain}: ${_FMR_STATES}) — kayıtlı parametrelerle (durum: ${_FMP_STATE}) yeniden üretiliyor"
        local closing=0
        if [[ "$_FMP_STATE" != "on" ]] || _fmprov_is_class4; then closing=1; fi
        _domconf_fm_regen_recorded_locked "$domain" "$sname" "$reload" || rc=$?
        _domconf_fm_root_rc_report "$domain" "$rc" "$closing"
        return $?
    fi
    if _domconf_fm_reserved_present "$dir"; then
        warn "403 kökü kurulamadı (${domain}): ${dir}/${_FMX_FIRST} köken kaydı OLMADAN diskte (kullanıcı dosyası sayılır, EZİLMEDİ) — /_fm yolu korunmuyor. Bilinçli devralma: srvctl domain fm-root ${domain} --apply (eski içerik <ad>.srvctl-tampered) ya da dosyayı kaldırın/taşıyın"
        return 1
    fi
    mkdir -p "$dir" || return 1
    _domconf_fm_apply "$domain" "$sname" off eu - - 0 "$reload" || rc=$?
    _domconf_fm_root_rc_report "$domain" "$rc"
}

_domconf_fm_root_provision() {
    local domain="${1:-}" reload="${2:-0}" sname rc=0 t_int t_term t_hup
    sname=$(safe_name "$domain")
    assert_safe_ident "$sname" || return 1
    # Güven kapısı kilitten ve _domconf_fm_files_ok erken dönüşünden ÖNCE: dosyalar kayıtla uyuşsa bile (kayma yokken de)
    # güvenilmeyen custom.d/<sname> için başarı BİLDİRİLMEZ (rc 1, yazım 0).
    if ! _domconf_fm_dir_trusted "$(_domconf_fm_dir "$sname")" "$sname"; then
        _domconf_fm_dir_refuse "$domain" "403 kökü kurulumu (provision) REDDEDİLDİ — dosyalar sağlam görünse bile başarı bildirilmez"
        return 1
    fi
    # _domconf_fm_apply çıkışta `trap - INT TERM HUP` yapar: ÇAĞIRANIN tuzakları (ör. _domain_add'in
    # yarım-alan geri alması) silinmesin diye kaydedilip geri kurulur.
    t_int=$(trap -p INT); t_term=$(trap -p TERM); t_hup=$(trap -p HUP)
    _fmprov_with_lock _domconf_fm_root_provision_locked "$domain" "$sname" "$reload" || rc=$?
    # Kilit katmanı kayıt dizini güvenilmezliği yüzünden başarısızsa (lrc==2 dalına hiç girilmez) alanın açık olabileceği söylenir.
    if (( rc != 0 )) && ! _fmprov_state_ok "$sname"; then _domconf_fm_untrusted_loud "$domain" "$sname" "403 kökü kurulumu"; fi
    trap - INT TERM HUP
    if [[ -n "$t_int" ]]; then eval "$t_int"; fi
    if [[ -n "$t_term" ]]; then eval "$t_term"; fi
    if [[ -n "$t_hup" ]]; then eval "$t_hup"; fi
    return $rc
}

# ───────────────────────────────────────────────────────────────
#  'domain add' ÖN KOŞUL KAPISI — HİÇBİR şey yazmadan, alan kaynağı yaratılmadan ÖNCE:
#  403 kökü bu alana kurulabilecek mi? flock var ve çalışıyor (kilit alınabilir), köken kayıt dizini
#  güvenilir (sembolik bağ değil, root sahipli zincir, fiziksel yol), bu alan için KALINTI köken kaydı
#  ya da yarım işlem yedeği YOK, custom.d/<sname> sembolik bağ/dosya değil ve yazılabilir, içinde FM
#  adlı (20/21/90; sarkan bağ dahil) dosya YOK. stdout: ret nedeni. PREDİKAT: 0=geçer, 1=kurulamaz.
#  'domain clone'/'domain staging' bu kapıdan _domain_add üzerinden geçer.
# ───────────────────────────────────────────────────────────────
_domconf_fm_root_precheck() {
    local domain="$1" sname sd lf lp cdir anc man phys par bks
    sname=$(safe_name "$domain")
    assert_safe_ident "$sname" || { echo "geçersiz alan kimliği: ${sname}"; return 1; }
    command -v flock >/dev/null 2>&1 \
        || { echo "flock bulunamadı (util-linux) — FM yazımı eşzamanlılık koruması olmadan YAPILMAZ"; return 1; }
    sd=$(_fmprov_dir)
    if [[ -L "$sd" ]]; then echo "köken kayıt dizini sembolik bağ: ${sd}"; return 1; fi
    lp="/dev/null"
    if [[ -e "$sd" ]]; then
        [[ -d "$sd" ]] || { echo "köken kayıt dizini dizin değil: ${sd}"; return 1; }
        assert_root_owned_path "$sd" \
            || { echo "köken kayıt dizini güvenilmez (root sahipli değil ya da g/o-yazılabilir zincir): ${sd} — root:root 0700 yapın"; return 1; }
        phys=$(cd "$sd" 2>/dev/null && pwd -P) && par=$(cd "$(dirname "$sd")" 2>/dev/null && pwd -P) && [[ "$phys" == "${par}/_fm-auth" ]] \
            || { echo "köken kayıt dizininin fiziksel yolu beklenenle uyuşmuyor: ${sd}"; return 1; }
        man=$(_fmprov_manifest "$sname")
        if [[ -e "$man" || -L "$man" ]]; then
            echo "bu alan için KALINTI köken kaydı var (${man}) — önceki bir alandan kalmış olabilir; inceleyip kaldırın"
            return 1
        fi
        bks=$(_fmprov_bk_list "$sname")
        if [[ -n "$bks" ]]; then
            echo "bu alan için yarım işlem yedeği var ($(tr '\n' ' ' <<< "$bks"))— inceleyip kaldırın"
            return 1
        fi
        lf="${sd}/.lock"
        if [[ -L "$lf" ]]; then echo "kilit dosyası sembolik bağ: ${lf}"; return 1; fi
        if [[ -e "$lf" ]]; then
            [[ -f "$lf" ]] || { echo "kilit dosyası normal dosya değil: ${lf}"; return 1; }
            lp="$lf"
        fi
    else
        anc=$(dirname "$sd")
        while [[ ! -e "$anc" && "$anc" != "/" && -n "$anc" ]]; do anc=$(dirname "$anc"); done
        [[ -d "$anc" && -w "$anc" ]] || { echo "köken kayıt dizini oluşturulamaz (üst dizin yazılamaz): ${anc}"; return 1; }
        # Provizyon dizini yaratınca _fmprov_state_ok ata zincirini de ister; kapı AYNI güveni
        # önceden sınar ki "hiçbir kaynak oluşturulmadı" sözü tutsun.
        assert_root_owned_path "$anc" \
            || { echo "köken kayıt dizini oluşturulamaz: üst dizin zinciri güvenilmez (root sahipli değil, sembolik bağ ya da g/o-yazılabilir): ${anc}"; return 1; }
    fi
    # Kilit alınabilir mi (dosya yoksa flock'un kendisi /dev/null üzerinde sınanır — yazım yok).
    ( exec 9<"$lp" && flock -w 30 9 ) 2>/dev/null \
        || { echo "fm-auth kilidi alınamadı (flock çalışmıyor ya da başka bir srvctl işlemi 30 sn'den uzun tutuyor): ${lp}"; return 1; }
    cdir=$(_domconf_fm_dir "$sname")
    if [[ -L "$cdir" ]]; then echo "custom.d/${sname} sembolik bağ: ${cdir}"; return 1; fi
    if ! _domconf_fm_dir_trusted "$cdir" "$sname"; then echo "$_FMD_WHY"; return 1; fi
    if [[ -e "$cdir" ]]; then
        [[ -d "$cdir" ]] || { echo "custom.d/${sname} dizin değil: ${cdir}"; return 1; }
        [[ -w "$cdir" ]] || { echo "custom.d/${sname} yazılamaz: ${cdir}"; return 1; }
        if _domconf_fm_reserved_present "$cdir"; then
            echo "${cdir}/${_FMX_FIRST} köken kaydı OLMADAN diskte (kullanıcı dosyası sayılır; rezerve ad) — kaldırın/taşıyın"
            return 1
        fi
    else
        anc="${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}"
        while [[ ! -e "$anc" && "$anc" != "/" && -n "$anc" ]]; do anc=$(dirname "$anc"); done
        [[ -d "$anc" && -w "$anc" ]] || { echo "custom.d dizini oluşturulamaz/yazılamaz: ${anc}"; return 1; }
    fi
    return 0
}

# 'domain repair' adımı: FM dosyalarını KAYITLI parametrelerle yeniden üretir (STALE/TAMPERED/EKSİK
# ya da PHP sürüm kayması); kayıt yoksa 403 kökünü kurar. Kullanıcı dosyalarına DOKUNMAZ ve ihlalli
# olsa bile KIRMAZ (yalnız uyarı). Önce yarım işlem yedeğini kurtarır; özetler sağlam dese
# de 'nginx -t' bu alanın dosyasında düşüyorsa yeniden üretir.
# $3 reload (varsayılan 1; 'repair --all' 0 verip, YAZIM olduysa sonda TEK reload yapar; yazım yoksa reload da yoktur).
# Dönüş: 0=sağlam/onarıldı, 1=onarılamadı.
_domconf_fm_auth_repair_locked() {
    local domain="$1" sname="$2" php_ver="$3" reload="${4:-1}" rc=0 lrc=0 php closing=0
    _fmprov_load "$sname" || lrc=$?
    if (( lrc != 0 )); then return 1; fi
    # Yazılacak olan KAPATMA mı (kayıt off ya da sınıf 4: tanınmayan açık eser kapatılır)? Reload düşerse çalışan nginx eski (AÇIK olabilen) yapılandırmada kalır.
    if [[ "$_FMP_STATE" != "on" ]] || _fmprov_is_class4; then closing=1; fi
    php="$_FMP_PHP"
    if [[ "$_FMP_STATE" == "on" ]]; then php="$php_ver"; fi
    if [[ "$_FMP_STATE" == "on" ]]; then
        _domconf_fm_apply_detect "$domain" "$sname" on "$_FMP_REGION" "$_FMP_SCRIPT" "$php" "$reload" || rc=$?
    else
        _domconf_fm_apply "$domain" "$sname" off "$_FMP_REGION" "$_FMP_SCRIPT" "$php" "$_FMP_MODSEC" "$reload" || rc=$?
    fi
    if (( rc != 0 )); then
        if (( rc == 3 || rc == 7 )); then printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2; fi
        if (( rc == 5 && closing )); then
            warn "kapatma yazıldı (config geçerli) ama nginx reload başarısız (${domain}) — FM HÂLÂ AÇIK OLABİLİR (çalışan nginx eski yapılandırmada); systemctl status nginx; gerekirse: srvctl domain fm-auth ${domain} off --emergency"
        fi
        return 1
    fi
    return 0
}

_domconf_fm_auth_repair() {
    local domain="$1" php_ver="$2" reload="${3:-1}" sname dir lrc=0 n st need=0 out trc=0 recovered=0
    sname=$(safe_name "$domain")
    assert_safe_ident "$sname" || return 0
    dir=$(_domconf_fm_dir "$sname")
    # Güven kapısı HER erken dönüşten ÖNCE: dosyalar kayıtla uyuşsa bile (yazım gerekmese de) güvenilmeyen custom.d/<sname>
    # (sembolik bağ, root'a ait olmayan, g/o-yazılabilir; inode taklidi dahil) başarı BİLDİRİLMEZ: rc 1 + yüksek sesli ileti, yazım 0.
    if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        _domconf_fm_dir_refuse "$domain" "onarım (repair) REDDEDİLDİ — dosyalar sağlam görünse bile başarı bildirilmez"
        return 1
    fi
    if [[ -n "$(_fmprov_bk_list "$sname")" ]]; then
        # Birden çok yedekte kurtarma alanı KAPATIR (reload burada: $reload) ve yine rc 1 verir; yedeklere dokunulmaz.
        _fmprov_with_lock _fmprov_recover_locked "$domain" "$sname" "$reload" \
            || { warn "fm-auth onarılamadı (${domain}): yarım işlem yedeği kurtarılamadı — 'srvctl domain fm-auth ${domain} status'"; return 1; }
        recovered=1; _DOMCONF_FM_WROTE=1
    fi
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 1 )); then
        # Hiç kayıt yok: alan 403 kökünü henüz almamış (eski alan). Kökü kur (opt-in DEĞİL).
        _domconf_warn_user_violations "$domain" "$sname" "$dir"
        _domconf_fm_root_provision "$domain" "$reload"
        return $?
    fi
    if (( lrc == 2 )); then
        warn "fm-auth köken kaydı GÜVENİLMEZ (STATE-UNTRUSTED): ${domain} — onarılamadı; kayıt dizinini root:root 0700 yapın"
        _domconf_fm_untrusted_loud "$domain" "$sname" "onarım/kapatma"
        return 1
    fi
    if [[ "$_FMP_STATE" == "on" ]]; then
        for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE" "$_DOMCONF_FM_UP_FILE"; do
            st=$(_fmprov_file_state "$sname" "$n" "${dir}/${n}")
            if [[ "$st" != "OK" ]]; then need=1; fi
        done
        if [[ "$_FMP_PHP" != "$php_ver" ]]; then need=1; fi
        assert_php_version "$php_ver" || { warn "fm-auth onarımı: geçersiz PHP sürümü (${php_ver})"; return 1; }
    else
        st=$(_fmprov_file_state "$sname" "$_DOMCONF_FM_UP_FILE" "${dir}/${_DOMCONF_FM_UP_FILE}")
        if [[ "$st" != "OK" ]]; then need=1; fi
        if [[ -e "${dir}/${_DOMCONF_FM_AUTH_FILE}" || -e "${dir}/${_DOMCONF_FM_DL_FILE}" ]]; then need=1; fi
    fi
    # acil kapatma işareti varsa kayıt 'on' yazıyor olabilir — dosyalar KAPALI olsa da kaydı 'off'a eşitle.
    if [[ "${_FMP_EMERGENCY:-0}" != "0" ]]; then need=1; fi
    if (( need == 0 )); then
        # Özetler sağlam; yapılandırma GERÇEKTEN yüklenebiliyor mu?
        out=$(nginx -t 2>&1) || trc=$?
        if (( trc == 0 )); then
            # Kurtarma diskteki dosyaları değiştirdiyse çalışan nginx'i ona hizala (--all altında toplu reload).
            if (( recovered && reload == 1 )); then
                systemctl reload nginx >/dev/null 2>&1 || { warn "kurtarma sonrası nginx reload başarısız (${domain}) — FM HÂLÂ AÇIK OLABİLİR; systemctl status nginx"; return 1; }
            else
                # Yazım/kurtarma yok ama disk KAPALI iken çalışan nginx hâlâ AÇIK olabilir (off commit'i ile reload arasındaki kesinti): uzlaştır.
                _domconf_fm_running_closed_sync "$domain" "$reload" || return 1
            fi
            return 0
        fi
        if [[ "$out" != *"${dir}/"* ]]; then
            warn "fm-auth dosyaları sağlam (${domain}) ama nginx -t BAŞARISIZ (hata bu alanın FM dosyasında değil) — onarım bunu düzeltemez:"
            printf '%s\n' "$out" | tail -3 | sed 's/^/    /' >&2
            return 1
        fi
        warn "nginx -t bu alanın custom.d dosyasında düşüyor (${domain}) — FM dosyaları (ModSecurity yeniden tespitiyle) yeniden üretiliyor"
        need=1
    fi
    # Kullanıcı dosyaları HER nginx -t'den ÖNCE taranır; repair'de yalnız UYARI (mevcut ihlalli
    # dosya kırılmaz/silinmez/yeniden yazılmaz).
    _domconf_warn_user_violations "$domain" "$sname" "$dir"
    local c4=0
    if _fmprov_is_class4; then c4=1; fi
    if _fmprov_with_lock _domconf_fm_auth_repair_locked "$domain" "$sname" "$php_ver" "$reload"; then
        if (( c4 )); then
            # Sınıf 4 — kayıtlı parametreyle yeniden üretim YOK; alan KAPATILDI.
            warn "fm-auth alanı KAPATTI (403 kökü): ${domain} — kayıt 'on' idi ama 20/21/90 eserlerinden biri tanınmıyordu; kayıtlı parametrelerle yeniden üretim YAPILMADI. Yalnız açık 'srvctl domain fm-auth ${domain} on --script=…' açar"
        else
            info "fm-auth yeniden üretildi (kayıtlı parametrelerle): ${domain} (php${php_ver})"
        fi
        return 0
    fi
    warn "fm-auth onarılamadı (${domain}) — 'srvctl domain fm-auth ${domain} status' ile bakın"
    return 1
}

# php-switch: fm-auth açıksa 90 dosyası (soket yolu) yeni sürümle YENİDEN ÜRETİLİR
# (sed YOK; render + köken kaydı). Reload'u ÇAĞIRAN yapar (php-switch zaten nginx_test+reload).
# Dönüş: 0=değişiklik gerekmedi/opt-in yok, 10=güncellendi, 1=hata.
_domconf_fm_auth_sock_sync_locked() {
    local domain="$1" sname="$2" new_ver="$3" rc=0 lrc=0
    _fmprov_load "$sname" || lrc=$?
    if (( lrc != 0 )); then return 1; fi
    # Yarım işlem yedeği varken yazım YAPILMAZ (yazım bayat yedeği kurtarmayla çelişen bir
    # duruma sokardı); önce kurtarma. php-switch bunu görünür uyarıyla bildirir (soket uyuşmazlığı
    # 502 verir = fail-closed).
    if [[ -n "$(_fmprov_bk_list "$sname")" ]]; then
        # Birden çok yedek = alan KAPATILIR (sınıftan bağımsız; reload'u php-switch yapar), yedeklere dokunulmaz, rc 1.
        if (( $(_fmprov_bk_count "$sname") > 1 )); then
            _fmprov_multi_bk_close_locked "$domain" "$sname" 0
            return 1
        fi
        # Yarım işlem yedeği her durumda (sınıf 4, kayıt 'off' + açık iz, kayıt 'on') ÖNCE mevcut kurtarma yoluyla ele alınır; yazım ancak ondan sonra gelir
        # (yazım bayat yedeği kurtarmayla çelişen bir duruma sokmaz). Kayıt 'on' + yedek = yarım kalmış bir AÇILIŞ ('on' dosyaları ve kaydı yazıldı, reload
        # öncesi kesinti): eskiden burada "REDDEDİLDİ" deyip yedeği olduğu gibi bırakırdı, ama çağıranın (php-switch) koşulsuz `nginx -t && reload`'u o yarım
        # açılışı çalışan nginx'e yüklerdi — otomatik yol alanı AÇARDI. Şimdi kurtarma, kesinti ÖNCESİ haline geri yükler (kapalı alan kapalı kalır) ya da
        # kayıt/ön durum kapalıysa yedeği ayırıp kapatır; bundan sonra aşağıdaki mevcut yazım (kapalı kök ya da açık alanın soket senkronu) çalışır.
        # Sınıf 4'te kayıt OFF sayılır: geri YÜKLENMEZ, '.superseded.' ayrılır; birden çok yedek yukarıda ayrı ele alınır: alan KAPATILIR, yedekler korunur, rc 1.
        _fmprov_recover_locked "$domain" "$sname" || return 1
        lrc=0; _fmprov_load "$sname" || lrc=$?
        if (( lrc != 0 )); then return 1; fi
        # Kurtarma sonucu alan KAPALI ise (açılış hiç tamamlanmamıştı) çağıran "soketi çekildi" değil "KAPATILDI" demeli.
        if [[ "$_FMP_STATE" != "on" ]]; then _DOMCONF_FM_SWITCH_CLOSED=1; fi
    fi
    _domconf_fm_apply_detect "$domain" "$sname" "$_FMP_STATE" "$_FMP_REGION" "$_FMP_SCRIPT" "$new_ver" 0 "$_FMP_MODSEC" || rc=$?
    (( rc == 0 ))
}

_domconf_fm_auth_sock_sync() {
    local domain="$1" new_ver="$2" sname lrc=0
    sname=$(safe_name "$domain")
    assert_safe_ident "$sname" || return 0
    assert_php_version "$new_ver" || return 1
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 1 )); then return 0; fi
    if (( lrc == 2 )); then
        _domconf_fm_untrusted_loud "$domain" "$sname" "php-switch soket senkronu"
        return 1
    fi
    # KAPATMA YÖNÜ (otomatik yollar yalnız kapatır): (a) TANINMAYAN 20'li 'on' kaydı (sınıf 4) ya da (b) kayıt 'off' iken diskte AÇIK iz
    # (90/21 var ya da 20 srvctl'in 403 kökü değil; ör. 'off' kaydı diskten ÖNCE yazar, araya giren kesinti kaydı 'off', diski açık bırakır)
    # php-switch'te soket güncellemesiyle AÇILMAZ ve no-op ile AÇIK DA BIRAKILMAZ — alan 403 köküne alınır (rc 10: çağıran reload eder).
    _DOMCONF_FM_SWITCH_CLOSED=0
    local c4=0 closing=0 halfon=0
    if _fmprov_is_class4; then c4=1; fi
    if (( ! c4 )); then
        if [[ "$_FMP_STATE" == "on" ]]; then
            # Kayıt 'on' + yarım işlem yedeği = yarım kalmış açılış: PHP sürümü aynı görünse de (kesintiden önce yazılan kayıt) ele alınır — çağıranın
            # koşulsuz reload'u yarım açılışı yüklemesin diye kurtarma/kapatma burada yapılır.
            if [[ -n "$(_fmprov_bk_list "$sname")" ]]; then halfon=1; else [[ "$_FMP_PHP" != "$new_ver" ]] || return 0; fi
        else
            _domconf_fm_off_open_trace "$sname" || return 0
            closing=1
        fi
    fi
    _domconf_warn_user_violations "$domain" "$sname" "$(_domconf_fm_dir "$sname")"
    _FMP_MBK_SPOKE=0
    if _fmprov_with_lock _domconf_fm_auth_sock_sync_locked "$domain" "$sname" "$new_ver"; then
        if (( c4 || closing )); then _DOMCONF_FM_SWITCH_CLOSED=1; fi
        return 10
    fi
    if (( halfon && ! _FMP_MBK_SPOKE )); then
        warn "fm-auth yarım kalmış açılış KAPATILAMADI (${domain}): kayıt 'on' ve yarım işlem yedeği var; php-switch yedeği kurtaramadı — FM HÂLÂ AÇIK OLABİLİR (arkadan gelen nginx reload'u yarım açılışı yükleyebilir); kapatmak için: srvctl domain fm-auth ${domain} off --emergency"
    fi
    # Birden çok yedek yolunda sonuç (KAPATILDI / KAPATILAMADI — FM HÂLÂ AÇIK OLABİLİR) yardımcı tarafından zaten söylendi.
    if (( (c4 || closing) && ! _FMP_MBK_SPOKE )); then
        if (( closing )); then
            warn "fm-auth alanı KAPATILAMADI (${domain}): kayıt 'off' ama diskte AÇIK iz var (90/21 ya da 403 kökü olmayan 20) ve php-switch 403 köküne alamadı — FM HÂLÂ AÇIK OLABİLİR; kapatmak için: srvctl domain fm-auth ${domain} off --emergency"
        else
            warn "fm-auth alanı KAPATILAMADI (${domain}): kayıt 'on' ama 20/21/90 eserlerinden biri tanınmıyor ve php-switch 403 köküne alamadı — FM HÂLÂ AÇIK OLABİLİR; kapatmak için: srvctl domain fm-auth ${domain} off --emergency"
        fi
    fi
    return 1
}

# Kayıt 'off' iken diskte AÇIK iz var mı? PREDİKAT: 0 = var (90/21 mevcut — sembolik bağ dahil — ya da 20 mevcut ve srvctl'in tanınan 403
# kökü değil). Salt-okur; kayıt güvenilir olmalıdır (çağıran _fmprov_load ile doğruladı). Dosyanın hiç olmaması açık iz DEĞİLDİR.
_DOMCONF_FM_SWITCH_CLOSED=0
_domconf_fm_off_open_trace() {
    local sname="$1" dir n f
    dir=$(_domconf_fm_dir "$sname")
    for n in "$_DOMCONF_FM_AUTH_FILE" "$_DOMCONF_FM_DL_FILE"; do
        if [[ -e "${dir}/${n}" || -L "${dir}/${n}" ]]; then return 0; fi
    done
    f="${dir}/${_DOMCONF_FM_UP_FILE}"
    if [[ -e "$f" || -L "$f" ]] && ! _domconf_fm_closed_root_known "$f" "$sname" ""; then return 0; fi
    return 1
}

# Ayrılmış (.superseded.bk.*) yedeği siler; başka ad hiçbir şey silmez.
_domconf_fm_superseded_drop() {
    local b="${1:-}"
    [[ -n "$b" && "${b##*/}" == .superseded.bk.* && ! -L "$b" ]] || return 0
    rm -rf -- "${b:?}"
}

# 'domain remove': köken kaydını (ve bu alanın yarım işlem yedeklerini) siler — fm-auth
# kilidi ALTINDA (eşzamanlı bir fm-auth/fm-root yazımıyla yarışmaz). Kilit alınamazsa SİLMEZ
# (kalıntı kayıt sonraki 'domain add'in ön koşul kapısında yakalanır; fail-closed). rc 0/1.
_domconf_fm_auth_forget_locked() {
    local sname="$1" man b
    man=$(_fmprov_manifest "$sname")
    rm -f -- "${man:?}" || return 1
    _fmprov_emergency_clear "$sname"
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        _domconf_fm_bk_drop "$b"
    done < <(_fmprov_bk_list "$sname")
    # Alan SİLİNİYOR: kenara ayrılmış (.superseded.) yedekleri de aynı alanın kalıntısıdır.
    for b in "$(_fmprov_dir)"/.superseded.bk."${sname}".*; do
        if [[ -e "$b" || -L "$b" ]]; then _domconf_fm_superseded_drop "$b"; fi
    done
    return 0
}

_domconf_fm_auth_forget() {
    local sname="${1:-}" man
    if [[ -z "$sname" ]] || ! assert_safe_ident "$sname"; then return 0; fi
    man=$(_fmprov_manifest "$sname")
    # Kayıt, yedek, ayrılmış (.superseded) yedek ve acil işareti yoksa kilide (ve kayıt dizini yaratmaya) gerek yok.
    # (yalnız .superseded kalmışsa da temizlenir — eskiden erken dönüp yetim bırakırdı.)
    if [[ ! -e "$man" && ! -L "$man" && -z "$(_fmprov_bk_list "$sname")" && -z "$(_fmprov_superseded_list "$sname")" ]] \
       && ! _fmprov_emergency_present "$sname"; then return 0; fi
    if _fmprov_with_lock _domconf_fm_auth_forget_locked "$sname"; then return 0; fi
    warn "fm-auth köken kaydı SİLİNEMEDİ (kilit/kayıt dizini): ${man} — kalıntı kayıt aynı adlı yeni 'domain add'i durdurur; inceleyip elle kaldırın"
    return 1
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain fm-root <domain>|--all [--apply]
#  YALNIZ /_fm 403 kökü ve FM dosyaları — 'repair'in geniş yan etkileri (FPM havuzu/AppArmor,
#  paylaşılan FPM reload/restart, DB yetkisi + parola senkronu, Redis ACL, alan başına nginx reload)
#  YOKTUR. Varsayılan KURU: hiçbir şey yazmaz, nginx'e dokunmaz; her alan için yapılacak işi
#  listeler. '--apply': TEK fm-auth kilidi altında tüm alanlar TEK işlemde sahnelenir; YAZILACAK iş
#  varsa → TEK 'nginx -t' → hata: HEPSİ geri alınır, reload YOK; başarı: köken kayıtları aşama 2 + TEK
#  reload. Yazılacak iş YOKSA 'nginx -t' ve reload ÇALIŞMAZ (sayı üst sınırdır, koşulsuz değil;
#  yalnız yarım-işlem kurtarması yapıldıysa tek 'nginx -t' + tek reload çalışır) — TEK İSTİSNA: diskte KAPALI kanıtı olan sağlam
#  bir alanda çalışan nginx KESİN KAPALI imzası vermiyorsa (AÇIK imzası ya da sonda kör; kapatma commit'i ile reload arasındaki kesinti) o alan için yapılandırma
#  yeniden yüklenir ve KAPALI imzası doğrulanır (_domconf_fm_running_closed_sync); başarısızsa rc 1 + "FM HÂLÂ AÇIK OLABİLİR".
#  Eylemler: YOK → kök kur | kayıtlı ama EKSİK/STALE/TAMPERED → kayıtlı parametrelerle yeniden üret
#  (açık alan açık kalır; ModSecurity sondası bir kez) | kayıtsız FM adlı dosya → DEVRAL (403 kökü;
#  eski içerik <ad>.srvctl-tampered) | yarım işlem yedeği → önce kesinti öncesine geri yükle, sonra
#  yeniden değerlendir (kayıt durumu KAPALI ise yedek GERİ YÜKLENMEZ, '.superseded.' olarak
#  ayrılır — kurtarma bir kapatmayı asla geri açamaz) | sağlam → dokunma. YAPILAMAZ: STATE-UNTRUSTED, vhost custom.d include
#  etmiyor, custom.d/<sname> sembolik bağ/dosya, birden çok yarım yedek.
#  Çıkış: 0 hepsi sağlam/uygulandı (kuru: hepsi uygulanabilir) | 1 en az bir alan YAPILAMAZ ya da
#  uygulama başarısız.
# ───────────────────────────────────────────────────────────────
_FRP_ACT=""; _FRP_WHY=""; _FRP_ST=""; _FRP_RG=""; _FRP_SC=""; _FRP_PH=""; _FRP_MS=""; _FRP_C4=0
# Planlayıcı STATE-UNTRUSTED'ı reddederken (salt-okur) diskte KAPALI kanıtı yoksa nedene "FM HÂLÂ AÇIK OLABİLİR" + çözüm eklenir.
_domconf_fm_root_plan_untrusted_note() {
    local dir="$1" sname="$2" domain="$3"
    if ! _domconf_fm_disk_closed_proof "$dir" "$sname"; then
        _FRP_WHY+=" — FM HÂLÂ AÇIK OLABİLİR (diskte KAPALI kanıtı yok; kayıt güvenilmezken hiçbir şey yazılmaz). Kayıttan bağımsız kapatmak için: srvctl domain fm-auth ${domain} off --emergency"
    fi
    return 0
}
# Salt-okur planlayıcı. _FRP_ACT ∈ none|install|regen|takeover|recover|refuse; _FRP_WHY açıklama.
_domconf_fm_root_plan() {
    local domain="$1" sname dir vhost lrc=0 present="" bks nb
    _FRP_ACT="refuse"; _FRP_WHY=""; _FRP_ST=""; _FRP_RG=""; _FRP_SC=""; _FRP_PH=""; _FRP_MS=""; _FRP_C4=0
    sname=$(safe_name "$domain")
    assert_safe_ident "$sname" || { _FRP_WHY="geçersiz alan kimliği (${sname})"; return 0; }
    dir=$(_domconf_fm_dir "$sname")
    vhost="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${domain}.conf"
    if [[ -f "$vhost" ]] && ! grep -q "custom\.d/${sname}/" "$vhost"; then
        # fm-root vhost'a DOKUNMAZ; geniş 'repair' (FPM/AppArmor/DB/Redis yan etkili) ÖNERİLMEZ.
        _FRP_WHY="vhost custom.d/${sname}/ dizinini include ETMİYOR (${vhost}) — kök ETKİSİZ olurdu; fm-root vhost'u DEĞİŞTİRMEZ: vhost'un server bloğuna elle 'include /etc/nginx/custom.d/${sname}/*.conf;' ekleyip nginx -t ile doğrulayın, sonra fm-root'u yeniden çalıştırın"
        return 0
    fi
    if [[ -L "$dir" ]]; then _FRP_WHY="custom.d/${sname} sembolik bağ (${dir})"; return 0; fi
    if [[ -e "$dir" && ! -d "$dir" ]]; then _FRP_WHY="custom.d/${sname} dizin değil (${dir})"; return 0; fi
    if ! _domconf_fm_dir_trusted "$dir" "$sname"; then
        _FRP_WHY="YAPILAMAZ — ${_FMD_WHY}; fm-root bu girdiyi izlemez, yazım yok. Girdiyi inceleyip root sahipli gerçek bir dizine çevirin; alanı KAPATMAK için: srvctl domain fm-auth ${domain} off"
        return 0
    fi
    if ! _fmprov_state_ok "$sname"; then
        _FRP_WHY="köken kaydı/dizini güvenilmez (STATE-UNTRUSTED) — kayıt dizinini root:root 0700 yapın, sonra yeniden çalıştırın"
        _domconf_fm_root_plan_untrusted_note "$dir" "$sname" "$domain"
        return 0
    fi
    bks=$(_fmprov_bk_list "$sname")
    if [[ -n "$bks" ]]; then
        nb=$(grep -c . <<< "$bks")
        if (( nb > 1 )); then
            # Otomatik kurtarma YOK (YAPILAMAZ); --apply alanı 403 köküne KAPATIR, yedeklere DOKUNMAZ, rc 1. Zaten kapalıysa yazım yok.
            _FRP_WHY="birden çok yarım işlem yedeği ($(tr '\n' ' ' <<< "$bks"))— elle inceleyin; otomatik kurtarma YAPILMAZ, yedeklere DOKUNULMAZ; --apply alanı 403 köküne KAPATIR (kayıt 'off' sayılır; yedekleri incelemeyi bitirince 'srvctl domain fm-auth ${domain} off' hepsini geri yüklemeden ayırır, kapatmayı geri açmaz)"
            lrc=0; _fmprov_load "$sname" || lrc=$?
            if (( lrc == 2 )); then _FRP_WHY+=" — AMA köken kaydı bozuk/güvenilmez (STATE-UNTRUSTED): kapatılamaz, FM HÂLÂ AÇIK OLABİLİR"; return 0; fi
            if _domconf_fm_disk_closed_proof "$dir" "$sname"; then _FRP_WHY+=" — alan zaten KAPALI (403 kökü, 90/21 yok): yazım gerekmez"; return 0; fi
            _FRP_ACT="closebk"
            _FRP_RG="eu"; _FRP_SC="-"; _FRP_PH="-"; _FRP_MS="0"
            if (( lrc == 0 )); then _FRP_RG="$_FMP_REGION"; _FRP_SC="$_FMP_SCRIPT"; _FRP_PH="$_FMP_PHP"; _FRP_MS="$_FMP_MODSEC"; fi
            return 0
        fi
        _FRP_ACT="recover"; _FRP_WHY="yarım işlem yedeği (${bks##*/}) kesinti öncesine geri yüklenecek, sonra yeniden değerlendirilecek"
        # Kayıt durumu KAPALI ise yedek geri YÜKLENMEZ (kapatma kurtarmayla geri açılmaz).
        lrc=0; _fmprov_load "$sname" || lrc=$?
        if (( lrc == 0 )) && [[ "$_FMP_STATE" == "off" ]]; then
            _FRP_WHY="yarım işlem yedeği (${bks##*/}) GERİ YÜKLENMEYECEK: kayıt durumu KAPALI — kapatma kurtarmayla geri açılmaz; yedek adli olarak ayrılacak (.superseded), diskteki dosyalar kayda göre yeniden değerlendirilecek"
        elif ! _fmprov_bk_restore_allowed "${bks}" "$sname"; then
            _FRP_WHY="yarım işlem yedeği (${bks##*/}) GERİ YÜKLENMEYECEK: ön durum tanınan bir srvctl eseri değil — kurtarma açık yapılandırma üretmez; yedek adli olarak ayrılacak (.superseded), diskteki dosyalar kayda göre yeniden değerlendirilecek"
        fi
        return 0
    fi
    _fmprov_load "$sname" || lrc=$?
    if (( lrc == 2 )); then _FRP_WHY="köken kaydı bozuk/güvenilmez (STATE-UNTRUSTED)"; _domconf_fm_root_plan_untrusted_note "$dir" "$sname" "$domain"; return 0; fi
    if (( lrc == 1 )); then
        _domconf_fm_reserved_present "$dir" || true; present="$_FMX_PRESENT"
        if [[ -n "$present" ]]; then
            _FRP_ACT="takeover"; _FRP_WHY="kayıtsız FM adlı dosya(lar): ${present}— 403 kökü ile DEVRALINACAK (eski içerik <ad>.srvctl-tampered)"
        else
            _FRP_ACT="install"; _FRP_WHY="403 kökü YOK — kurulacak (${_DOMCONF_FM_UP_FILE}, köken kaydı: state off)"
        fi
        return 0
    fi
    _FRP_ST="$_FMP_STATE"; _FRP_RG="$_FMP_REGION"; _FRP_SC="$_FMP_SCRIPT"; _FRP_PH="$_FMP_PHP"; _FRP_MS="$_FMP_MODSEC"
    if _domconf_fm_files_ok "$sname" "$dir"; then
        if (( _FMP_EMERGENCY )); then
            # dosyalar sağlam KAPALI ama kayıt hâlâ 'on' diyor (acil kapatma kaydı eşitleyemedi): kaydı eşitle.
            # alan ASLA açılmaz — yazılan kayıt 'off'tur (işaret ya da "disk kapalı" kanıtı kaydı KAPALI sayar).
            if (( _FMP_EMERGENCY == 2 )); then
                _FRP_ACT="regen"; _FRP_WHY="KAPALI KANITI: kayıt 'on' yazıyor ama diskte yalnız srvctl 403 kökü var (90/21 yok) — kayıt 'off'a eşitlenecek (alan AÇILMAZ; yeniden açmak için açık 'fm-auth on')"
            else
                _FRP_ACT="regen"; _FRP_WHY="acil kapatma işareti var: dosyalar KAPALI (403 kökü) ama kayıt 'on' yazıyor — kayıt 'off'a eşitlenecek ve işaret kaldırılacak (alan AÇILMAZ)"
            fi
            return 0
        fi
        _FRP_ACT="none"
        if [[ "$_FRP_ST" == "on" ]]; then _FRP_WHY="sağlam: AÇIK (90/21/20 kayıtla eşit)"; else _FRP_WHY="sağlam: KAPALI (403 kökü)"; fi
        return 0
    fi
    if _fmprov_is_class4; then
        # Kayıt 'on' ama 20/21/90'dan biri TANINAN AÇIK eser değil → otomatik yol açık yapılandırma ÜRETMEZ; yalnız 403 kökü yazılır.
        _FRP_C4=1
        _FRP_ACT="regen"; _FRP_WHY="kayıt 'on' yazıyor ama 20/21/90 eserlerinden (${_DOMCONF_FM_UP_FILE}, ${_DOMCONF_FM_DL_FILE}, ${_DOMCONF_FM_AUTH_FILE}) biri TANINAN bir srvctl AÇIK eseri değil (${_FMR_STATES}) — 403 kökü yazılacak ve 90/21 kaldırılacak, kayıt 'off'a eşitlenecek (alan AÇILMAZ; yalnız açık 'fm-auth on' açar)"
        return 0
    fi
    _FRP_ACT="regen"; _FRP_WHY="kayıtlı dosyalar sağlam değil (${_FMR_STATES}) — kayıtlı parametrelerle yeniden üretilecek (durum: ${_FRP_ST})"
    return 0
}

_domconf_fm_root_apply_locked() {
    local d sname i rc=0 refused=0 trc=0 frc=0 need_probe=0 ms=0 php recovered=0 note has_close2=0 closing_any=0
    local -a act_dom=() act_kind=() act_c4=() chk_dom=()
    _domconf_fm_tx_reset; _DOMCONF_NGX_T_OUT=""
    for d in "$@"; do
        # ayrılmış (.superseded.bk.*) yedekler (bilgi).
        note=$(_fmprov_superseded_note "$(safe_name "$d")")
        if [[ -n "$note" ]]; then info "  ${d}: ${note}"; fi
        # acil kapatma artıkları (*.srvctl-emergency.*)
        note=$(_domconf_fm_aside_note "$(_domconf_fm_dir "$(safe_name "$d")")")
        if [[ -n "$note" ]]; then info "  ${d}: ${note}"; fi
        note=$(_domconf_fm_orphan_note "$d" "$(safe_name "$d")")
        if [[ -n "$note" ]]; then warn "  ${d}: ${note}"; fi
        _domconf_fm_root_plan "$d"
        if [[ "$_FRP_ACT" == "recover" ]]; then
            if ! _fmprov_recover_locked "$d" "$(safe_name "$d")"; then
                warn "  ${d}: YAPILAMAZ — yarım işlem yedeği kurtarılamadı"
                refused=1; continue
            fi
            recovered=1
            _domconf_fm_root_plan "$d"
        fi
        case "$_FRP_ACT" in
            none) info "  ${d}: ${_FRP_WHY}"; chk_dom+=("$d") ;;
            install|regen|takeover)
                act_dom+=("$d"); act_kind+=("$_FRP_ACT"); act_c4+=("${_FRP_C4:-0}")
                if [[ "$_FRP_ACT" == "regen" && "$_FRP_ST" == "on" ]]; then need_probe=1; fi
                # yazılacak şey KAPATMA ise (kayıt off ya da sınıf 4) son reload düşerse çalışan nginx eski (AÇIK olabilen) yapılandırmada kalır
                if [[ "$_FRP_ACT" == "regen" && ( "$_FRP_ST" != "on" || "${_FRP_C4:-0}" == "1" ) ]]; then closing_any=1; fi ;;
            closebk)
                # Kurtarma YAPILAMAZ (rc 1 kalır) ama alan işlemle birlikte KAPATILIR; yedekler DOKUNULMAZ.
                warn "  ${d}: YAPILAMAZ — ${_FRP_WHY}"
                act_dom+=("$d"); act_kind+=("closebk"); act_c4+=(0); has_close2=1; refused=1; closing_any=1 ;;
            *) warn "  ${d}: YAPILAMAZ — ${_FRP_WHY}"; refused=1 ;;
        esac
    done
    if (( ${#act_dom[@]} == 0 )); then
        # Yazılacak bir şey yoksa başlıktaki "tek nginx -t, tek reload" söz verilmiş sayılmasın. (İleti, çalışan durum uzlaştırması aşağıda reload
        # yapmadıysa söylenir; yaptıysa yerine bunun söylendiği aşağıda yer alır.)
        # Yalnız kurtarma yapıldıysa: diskteki (kesinti öncesi) durum çalışan nginx'e yüklenir.
        if (( recovered )); then
            _DOMCONF_NGX_T_OUT=$(nginx -t 2>&1) || trc=$?
            if (( trc != 0 )); then
                printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2
                warn "kurtarma sonrası nginx -t BAŞARISIZ — reload YAPILMADI"
                return 1
            fi
            systemctl reload nginx >/dev/null 2>&1 || { warn "kurtarma sonrası nginx reload başarısız — FM HÂLÂ AÇIK OLABİLİR; systemctl status nginx"; return 1; }
        else
            # Yazılacak bir şey yok: diskte KAPALI kanıtı olan sağlam alanlarda çalışan nginx hâlâ AÇIK olabilir (off commit'i ile reload
            # arasındaki kesinti) — uzlaştır (yalnız kapatma yönü; yalnız KESİN KAPALI imzası dokunmaz — AÇIK imzası ve sonda kör olması reload eder).
            _DOMCONF_FM_SYNC_RELOADED=0
            for d in "${chk_dom[@]}"; do
                _domconf_fm_running_closed_sync "$d" 1 || refused=1
            done
            if (( _DOMCONF_FM_SYNC_RELOADED == 0 )); then
                info "  yazılacak bir şey yok: nginx -t / reload ÇALIŞTIRILMADI"
            else
                info "  yazılacak bir şey yok; ama çalışan nginx KESİN KAPALI imzası vermediği için yapılandırma yeniden yüklendi (yukarıya bakın)"
            fi
        fi
        return "$refused"
    fi
    if (( need_probe )); then
        if ! _domconf_fm_modsec_probe; then
            printf '%s\n' "$_DOMCONF_MODSEC_PROBE_OUT" | sed 's/^/    /' >&2
            warn "ModSecurity yetenek tespiti yapılamadı — HİÇBİR alan yazılmadı"
            return 1
        fi
        ms="$_DOMCONF_MODSEC"
        if [[ "$ms" == "0" ]]; then warn "ModSecurity modülü yüklü değil (nginx: unknown directive \"modsecurity\") — 'modsecurity off' satırları yazılmadı"; fi
    fi
    for (( i = 0; i < ${#act_dom[@]}; i++ )); do
        d="${act_dom[i]}"; sname=$(safe_name "$d"); rc=0
        _domconf_fm_root_plan "$d"
        case "${act_kind[i]}" in
            install|takeover)
                _domconf_fm_stage "$d" "$sname" off eu - - 0 || rc=$? ;;
            closebk)
                _domconf_fm_stage "$d" "$sname" off "$_FRP_RG" "$_FRP_SC" "$_FRP_PH" "$_FRP_MS" || rc=$? ;;
            regen)
                if [[ "$_FRP_ST" == "on" ]]; then
                    php=$(_derive_php "$d" "${DEFAULT_PHP_VERSION}" 2>/dev/null) || php="$_FRP_PH"
                    assert_php_version "$php" || php="$_FRP_PH"
                    _domconf_fm_stage "$d" "$sname" on "$_FRP_RG" "$_FRP_SC" "$php" "$ms" || rc=$?
                else
                    _domconf_fm_stage "$d" "$sname" off "$_FRP_RG" "$_FRP_SC" "$_FRP_PH" "$_FRP_MS" || rc=$?
                fi ;;
        esac
        if (( rc != 0 )); then
            frc=4
            if (( ${#_FMT_BK[@]} > 0 )); then _domconf_fm_fail_restore 4 || frc=$?; fi
            if (( frc == 6 )); then
                warn "  ${d}: sahneleme BAŞARISIZ VE GERİ ALMA BAŞARISIZ — yedek(ler): ${_FMA_KEEP_BK:-?}"
            else
                warn "  ${d}: sahneleme BAŞARISIZ (render/yazım/kayıt) — işlemdeki TÜM alanlar geri alındı, reload YAPILMADI"
            fi
            if (( has_close2 )); then warn "  FM HÂLÂ AÇIK OLABİLİR — birden çok yarım işlem yedeği olan alan(lar) KAPATILAMADI (yedeklere dokunulmadı, elle inceleyin): srvctl domain fm-auth <alan> off --emergency"; fi
            return 1
        fi
    done
    _DOMCONF_NGX_T_OUT=$(nginx -t 2>&1) || trc=$?
    if (( trc != 0 )); then
        frc=3; _domconf_fm_fail_restore 3 || frc=$?
        printf '%s\n' "$_DOMCONF_NGX_T_OUT" | sed 's/^/    /' >&2
        if (( frc == 6 )); then
            warn "nginx -t BAŞARISIZ VE GERİ ALMA BAŞARISIZ — yedek(ler): ${_FMA_KEEP_BK:-?}"
        else
            warn "nginx -t BAŞARISIZ — ${#act_dom[@]} alanın TÜMÜ geri alındı, reload YAPILMADI"
        fi
        if (( has_close2 )); then warn "FM HÂLÂ AÇIK OLABİLİR — birden çok yarım işlem yedeği olan alan(lar) KAPATILAMADI (yedeklere dokunulmadı, elle inceleyin): srvctl domain fm-auth <alan> off --emergency"; fi
        return 1
    fi
    if ! _domconf_fm_tx_commit; then
        frc=4; _domconf_fm_fail_restore 4 || frc=$?
        warn "köken kaydı aşama 2 yazılamadı — işlem geri alındı (geri alma kodu ${frc}), reload YAPILMADI"
        if (( has_close2 )); then warn "FM HÂLÂ AÇIK OLABİLİR — birden çok yarım işlem yedeği olan alan(lar) KAPATILAMADI (yedeklere dokunulmadı, elle inceleyin): srvctl domain fm-auth <alan> off --emergency"; fi
        return 1
    fi
    for (( i = 0; i < ${#act_dom[@]}; i++ )); do
        case "${act_kind[i]}" in
            install)  success "  ${act_dom[i]}: 403 kökü kuruldu" ;;
            takeover) success "  ${act_dom[i]}: kayıtsız FM adları devralındı, 403 kökü kuruldu (eski içerik <ad>.srvctl-tampered)" ;;
            closebk)  warn "  ${act_dom[i]}: alan KAPATILDI (403 kökü; kayıt 'off', 90/21 kaldırıldı) — birden çok yarım işlem yedeği DOKUNULMADI, elle inceleyin. Yalnız açık 'srvctl domain fm-auth ${act_dom[i]} on --script=…' yeniden açar" ;;
            regen)
                if [[ "${act_c4[i]:-0}" == "1" ]]; then
                    # Sınıf 4 — kayıtlı parametreyle yeniden üretim YOK; alan KAPATILDI.
                    warn "  ${act_dom[i]}: alan KAPATILDI (403 kökü; 90/21 kaldırıldı) — kayıt 'on' idi ama 20/21/90 eserlerinden biri tanınmıyordu; kayıtlı parametrelerle yeniden üretim YAPILMADI. Yalnız açık 'srvctl domain fm-auth ${act_dom[i]} on --script=…' açar"
                else
                    success "  ${act_dom[i]}: FM dosyaları kayıtlı parametrelerle yeniden üretildi"
                fi ;;
        esac
    done
    log_action "DOMAIN FM-ROOT --apply: ${#act_dom[@]} alan (${act_dom[*]})"
    if ! systemctl reload nginx >/dev/null 2>&1; then
        warn "nginx reload başarısız — config GEÇERLİ (nginx -t geçti), sorun servis katmanında: systemctl status nginx"
        if (( closing_any )); then warn "FM HÂLÂ AÇIK OLABİLİR — diskte KAPATMA yazıldı ama çalışan nginx eski yapılandırmayla sürüyor; gerekirse: srvctl domain fm-auth <alan> off --emergency"; fi
        if (( has_close2 )); then warn "FM HÂLÂ AÇIK OLABİLİR — birden çok yarım işlem yedeği olan alan(lar) diskte KAPATILDI ama çalışan nginx eski yapılandırmayla sürüyor"; fi
        return 1
    fi
    return "$refused"
}

_domconf_fm_root_cmd() {
    local usage="srvctl domain fm-root <domain>|--all [--apply]"
    local target="" apply=0 arg d rc=0 n_act=0 n_ok=0 n_bad=0 note
    for arg in "$@"; do
        case "$arg" in
            --all)   if [[ -n "$target" ]]; then error "Fazla argüman: ${arg} (kullanım: ${usage}) — <domain> ile --all birlikte verilemez"; fi
                     target="--all" ;;
            --apply) apply=1 ;;
            -*)      error "Bilinmeyen seçenek: ${arg} (kullanım: ${usage})" ;;
            *)       if [[ -z "$target" ]]; then target="$arg"; else error "Fazla argüman: ${arg} (kullanım: ${usage})"; fi ;;
        esac
    done
    [[ -n "$target" ]] || error "Kullanım: ${usage}"
    local -a domains=()
    if [[ "$target" == "--all" ]]; then
        while IFS= read -r d; do if [[ -n "$d" ]]; then domains+=("$d"); fi; done < <(list_all_domains)
        if (( ${#domains[@]} == 0 )); then info "İşlenecek domain yok."; return 0; fi
    else
        domain_exists "$target" || error "Domain bulunamadı: ${target}"
        domains=("$target")
    fi
    if (( apply == 0 )); then
        info "fm-root KURU (hiçbir şey yazılmaz, nginx'e dokunulmaz; uygulamak için: --apply):"
        for d in "${domains[@]}"; do
            _domconf_fm_root_plan "$d"
            case "$_FRP_ACT" in
                none) echo "  [${d}] ${_FRP_WHY}"; n_ok=$((n_ok + 1)) ;;
                install|regen|takeover|recover) echo "  [${d}] YAPILACAK: ${_FRP_WHY}"; n_act=$((n_act + 1)) ;;
                *) echo "  [${d}] YAPILAMAZ: ${_FRP_WHY}"; n_bad=$((n_bad + 1)); rc=1 ;;
            esac
            # ayrılmış (.superseded.bk.*) yedekler (bilgi; plan/çıkış kodunu DEĞİŞTİRMEZ).
            note=$(_fmprov_superseded_note "$(safe_name "$d")")
            if [[ -n "$note" ]]; then echo "      BİLGİ: ${note}"; fi
            # acil kapatma artıkları (*.srvctl-emergency.*)
            note=$(_domconf_fm_aside_note "$(_domconf_fm_dir "$(safe_name "$d")")")
            if [[ -n "$note" ]]; then echo "      BİLGİ: ${note}"; fi
            # yarıda kalmış kenara alma artıkları (custom.d/<sname>.srvctl-new.* / .srvctl-emergency.*): UYARI (plan/çıkış kodunu DEĞİŞTİRMEZ).
            note=$(_domconf_fm_orphan_note "$d" "$(safe_name "$d")")
            if [[ -n "$note" ]]; then echo "      UYARI: ${note}"; fi
        done
        info "Toplam ${#domains[@]} alan: ${n_act} yapılacak, ${n_ok} sağlam, ${n_bad} yapılamaz"
        return $rc
    fi
    info "fm-root --apply: ${#domains[@]} alan (tek kilit; yazım gerekirse tek nginx -t + tek reload)"
    _fmprov_with_lock _domconf_fm_root_apply_locked "${domains[@]}" || rc=$?
    # Kilit katmanı kayıt dizini güvenilmezliği yüzünden başarısızsa (plan hiç koşmaz) her alan için açık olabileceği söylenir.
    if (( rc != 0 )); then
        local sn
        for d in "${domains[@]}"; do
            sn=$(safe_name "$d")
            if assert_safe_ident "$sn" && ! _fmprov_state_ok "$sn"; then _domconf_fm_untrusted_loud "$d" "$sn" "fm-root kapatma/onarım"; fi
        done
    fi
    return $rc
}

_domconf_fm_auth() {
    local usage="srvctl domain fm-auth <domain> <on|off|status> [--script=<yol>] [--region=eu|us] [--force] [--dry] [--emergency (yalnız off)] | fm-auth --capabilities"
    # Makinece okunur yetenek satırı (kurulu srvctl'in --dry'ı GERÇEKTEN uyguladığını betik
    # bununla doğrular; bu satırı basmayan sürüme 'on --dry' GÖNDERİLMEZ).
    if [[ "${1:-}" == "--capabilities" && $# -eq 1 ]]; then
        printf 'srvctl-fm-caps v1 dry=1 fm-root=1 audit-root=1 quarantine-safe=1 modsec-probe=1 add-fail-closed=1 f5-supersede=1 f6-emergency-off=1 f7-sig=1 f7-emergency-marker=1 f8-stage-gate=1 f8-closed-evidence=1 f9e-on-rc4=1 f9e-state-untrusted=1\n'
        return 0
    fi
    local domain="${1:-}" action="${2:-}" script="" region="" force=0 dry=0 emergency=0 arg
    if [[ $# -ge 2 ]]; then shift 2; else set --; fi
    for arg in "$@"; do
        case "$arg" in
            --script=*) script="${arg#--script=}"; [[ -n "$script" ]] || error "--script boş olamaz" ;;
            --region=*) region="${arg#--region=}"; [[ -n "$region" ]] || error "--region boş olamaz (eu|us)" ;;
            --force)    force=1 ;;
            --dry)      dry=1 ;;
            --emergency) emergency=1 ;;
            *) error "Bilinmeyen seçenek: ${arg} (kullanım: ${usage})" ;;
        esac
    done
    [[ -n "$domain" && -n "$action" ]] || error "Kullanım: ${usage}"
    if [[ "$emergency" == "1" && "$action" != "off" ]]; then
        error "--emergency yalnız 'off' ile kullanılır (kullanım: ${usage})"
    fi
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    [[ -n "$sname" ]] || error "Geçersiz domain adı (safe_name boş): ${domain}"
    assert_safe_ident "$sname" || error "Geçersiz domain kimliği: ${sname}"
    local dir; dir=$(_domconf_fm_dir "$sname")

    case "$action" in
        status) _domconf_fm_auth_status "$domain" "$sname" "$dir" ;;
        off)    _domconf_fm_auth_off_entry "$domain" "$sname" "$dir" "$force" "$dry" "$emergency" ;;
        on)     _domconf_fm_auth_on "$domain" "$sname" "$dir" "$script" "$region" "$dry" ;;
        *)      error "Bilinmeyen eylem: ${action} (on|off|status)" ;;
    esac
}
