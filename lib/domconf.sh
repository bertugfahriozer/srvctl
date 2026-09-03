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
#  Reddedilen nginx direktifleri.
#  'proxy_pass' BİLİNÇLİ OLARAK LİSTEDE DEĞİL: bu dosyayı yalnız root
#  düzenler, yani tehdit modeli "saldırgan" değil "operatörün ayağına
#  sıkması". Node/websocket servisine proxy meşru ve yaygın; reddetmek
#  operatörü srvctl'i baypas edip vhost'u ELLE düzenlemeye iter — o
#  değişiklik de ilk 'repair'de sessizce kaybolur (çözmeye çalıştığımız
#  problemin ta kendisi).
# ───────────────────────────────────────────────────────────────
_DOMCONF_NGINX_DENY=(
    fastcgi_pass root alias server_name listen
    disable_symlinks modsecurity modsecurity_rules modsecurity_rules_file
)

_domconf_nginx_deny_reason() {
    case "$1" in
        fastcgi_pass)  echo "başka domainin FPM socket'ine yönlenme — domainler arası izolasyon ihlali" ;;
        root|alias)    echo "docroot/chroot dışı dosya servisi" ;;
        server_name)   echo "başka bir domaini kapma" ;;
        listen)        echo "vhost/port çakışması" ;;
        disable_symlinks) echo "symlink koruması kapatma" ;;
        modsecurity|modsecurity_rules|modsecurity_rules_file) echo "WAF bypass" ;;
        *)             echo "izolasyon politikası" ;;
    esac
}

# PREDİKAT: 0=temiz, 1=reddedilen direktif bulundu (rapor stdout'a).
#
# Tarama SATIR BAZLIDIR: '#' yorumları çıkarılır, baştaki boşluk kırpılır,
# satırın ilk kelimesi direktif adı sayılır. String literali içinde geçen
# bir direktif adı yanlış pozitif üretebilir — BİLİNÇLİ ödünleşim: yanlış
# pozitifin maliyeti '--force', yanlış negatifin maliyeti SESSİZ izolasyon
# ihlalidir.
#
# BİLİNEN SINIR: blok-farkında DEĞİL, bu yüzden 'add_header' tuzağını
# (location içinde add_header → üst bloğun TÜM güvenlik başlıkları o
# location'da düşer) yakalayamaz. Bunu güvenilir yakalamak gerçek bir
# parser ister; iskelet dosyasının yorumlarında operatöre AÇIKÇA anlatılır.
_domconf_scan_nginx() {
    local file="$1"
    local line first deny lineno=0 found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" ]] && continue
        first="${line%%[[:space:];]*}"

        # Özel durum: nginx üzerinden PHP ayarı enjeksiyonu.
        # 'fastcgi_param PHP_ADMIN_VALUE "open_basedir="' ile chroot
        # izolasyonu delinebilir; ne 'nginx -t' ne 'php-fpm -t' itiraz eder.
        if [[ "$first" == "fastcgi_param" ]]; then
            if [[ "$line" == *PHP_ADMIN_VALUE* || "$line" == *PHP_VALUE* ]]; then
                echo "    satır ${lineno}: fastcgi_param PHP_(ADMIN_)VALUE — nginx üzerinden PHP ayarı enjeksiyonu (open_basedir buradan boşaltılabilir)"
                found=1
            fi
            continue
        fi

        for deny in "${_DOMCONF_NGINX_DENY[@]}"; do
            if [[ "$first" == "$deny" ]]; then
                echo "    satır ${lineno}: ${first} — $(_domconf_nginx_deny_reason "$first")"
                found=1
            fi
        done
    done < "$file"
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
# ─── REDDEDİLEN direktifler (--force olmadan uygulanmaz) ───
#   fastcgi_pass   → başka domainin FPM socket'ine yönlenme
#   root, alias    → docroot/chroot dışı dosya servisi
#   server_name    → başka bir domaini kapma
#   listen         → vhost/port çakışması
#   disable_symlinks, modsecurity*  → koruma kapatma
#   fastcgi_param PHP_VALUE / PHP_ADMIN_VALUE → PHP ayarı enjeksiyonu
#
# ─── Örnek ───
# client_max_body_size 100M;
#
# location /uzun-islem/ {
#     fastcgi_read_timeout 300s;
# }
EOF
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain nginx <domain> [--show] [--file <path>] [--force]
# ───────────────────────────────────────────────────────────────
_domconf_edit_nginx() {
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
    [[ -n "$domain" ]] || error "Kullanım: srvctl domain nginx <domain> [--show] [--file <yol>] [--force]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local dir="${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}/${sname}"
    local conf="${dir}/00-custom.conf"
    mkdir -p "$dir"
    [[ -f "$conf" ]] || { _domconf_nginx_skeleton "$domain" > "$conf"; chmod 644 "$conf"; }

    if [[ "$show" == "1" ]]; then
        cat "$conf"
        return 0
    fi

    # ─── ÖN KOŞUL: vhost bu dizini include ediyor mu? ───
    # Bu özellikten ÖNCE oluşturulmuş domainlerin vhost'unda include satırı
    # YOKTUR. Kontrol olmasaydı: operatör düzenler, 'nginx -t' temiz geçer,
    # reload başarılı görünür ve HİÇBİR ŞEY DEĞİŞMEZ — düzeltmeye
    # çalıştığımız sessiz-kayıp probleminin aynısı.
    local vhost="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${domain}.conf"
    if [[ -f "$vhost" ]] && ! grep -q "custom\.d/${sname}/" "$vhost"; then
        error "Bu domainin vhost'u custom.d dizinini include ETMİYOR (${vhost}) — düzenleme ETKİSİZ kalırdı. Önce: srvctl domain repair ${domain}"
    fi

    local cand; cand=$(mktemp)
    # Düşük (denetim 2026-09): 'error' (exit) ya da Ctrl+C ile kesintide aday/
    # yedek dosya /tmp'te kalmasın (M8 deseni: EXIT tek başına INT'i garanti etmez).
    trap 'rm -f -- "${cand:-}" "${backup:-}"' EXIT
    trap 'rm -f -- "${cand:-}" "${backup:-}"; exit 130' INT TERM
    if [[ -n "$src_file" ]]; then
        [[ -f "$src_file" ]] || { rm -f "$cand"; error "Dosya bulunamadı: ${src_file}"; }
        cp "$src_file" "$cand"
    else
        cp "$conf" "$cand"
        # 'sudo' env_reset ile $EDITOR'ü temizler — 'sudo -E' gerekir (README).
        "${EDITOR:-nano}" "$cand" || { rm -f "$cand"; error "Editör hata döndürdü — değişiklik uygulanmadı"; }
    fi

    if cmp -s "$cand" "$conf"; then
        rm -f "$cand"
        info "Değişiklik yok — hiçbir şey yapılmadı."
        return 0
    fi

    local findings
    if ! findings=$(_domconf_scan_nginx "$cand"); then
        if [[ "$force" != "1" ]]; then
            rm -f "$cand"
            warn "REDDEDİLDİ — izolasyonu delen direktif(ler):"
            echo "$findings" >&2
            error "Değişiklik UYGULANMADI. Bilerek yapıyorsanız: srvctl domain nginx ${domain} --force"
        fi
        warn "UYARI: izolasyon override edildi (--force) — ${domain}"
        echo "$findings" >&2
        log_action "DOMAIN NGINX --force: ${domain} — izolasyon override edildi"
        _domconf_notify "srvctl: izolasyon override (${domain})" \
            "nginx override dosyasında izolasyonu delen bir direktif --force ile uygulandı: ${domain}"
    fi

    local backup; backup=$(mktemp)
    trap 'rm -f -- "${cand:-}" "${backup:-}"' EXIT
    trap 'rm -f -- "${cand:-}" "${backup:-}"; exit 130' INT TERM
    cp "$conf" "$backup"
    cat "$cand" > "$conf"
    chmod 644 "$conf"
    rm -f "$cand"

    if ! nginx -t >/dev/null 2>&1; then
        cat "$backup" > "$conf"; rm -f "$backup"
        warn "nginx -t BAŞARISIZ — dosya eski haline döndürüldü, reload YAPILMADI. nginx'in kendi çıktısı:"
        nginx -t 2>&1 | sed 's/^/    /' >&2 || true
        error "nginx yapılandırma hatası"
    fi
    rm -f "$backup"

    systemctl reload nginx >/dev/null 2>&1 \
        || error "nginx reload başarısız — config GEÇERLİ, sorun servis katmanında. systemctl status nginx"

    success "nginx override uygulandı ve reload edildi: ${domain}"
    log_action "DOMAIN NGINX: ${domain}"
}
