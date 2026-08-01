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
        framework) _domain_framework "${@:2}" ;;
        repair)    _domain_repair "${@:2}" ;;
        worker)    _domain_worker "${@:2}" ;;
        scheduler) _domain_scheduler "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl domain <komut>"
            echo ""
            echo "  Temel:"
            echo "    add <domain> [--php=8.3] [--framework=ci4|laravel|symfony]"
            echo "        [--resources=micro|standard|ecommerce|heavy] [--redis-queue]"
            echo "                                     Yeni domain ekle (framework varsayılan: ci4,"
            echo "                                     kaynak profili varsayılan: standard)"
            echo "                                     --redis-queue: Laravel Redis kuyruk sürücüsü/"
            echo "                                     Horizon için EVAL/Lua scripting'i AÇIKÇA iste"
            echo "                                     (varsayılan HER ZAMAN kapalı — Redis 7+ olsa"
            echo "                                     BİLE bu bayrak olmadan açılmaz; yalnız Redis 7+"
            echo "                                     VE bu bayrakla onaylanır, bkz. çıktıdaki uyarı)"
            echo "    remove <domain>                 Domain kaldır"
            echo "    list                            Tüm domain'leri listele"
            echo "    info <domain> [--show-secrets]  Domain bilgisi (parolalar varsayılan gizli)"
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
            echo "    framework <domain> <ci4|laravel|symfony|none>"
            echo "                                     Mevcut domain'in framework beyanını değiştir/temizle"
            echo "                                     ('ci4' putenv'i AÇAR — bilinçli güvenlik ödünü, bkz."
            echo "                                     çıktıdaki uyarı); sonrasında 'domain repair' ÖNERİLİR"
            echo "                                     (disable_functions'ın fiilen render edilmesi için)"
            echo "    repair <domain>|--all           Eksik chroot kütüphanelerini onarır"
            echo "    worker <domain> <eylem> [ad]    Kuyruk worker'ı yönet (start/stop/status/enable/disable)"
            echo "    scheduler <domain> <eylem>      Zamanlanmış görev yönet (start/stop/status/enable/disable)"
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

# ─── AppArmor profilini parse edip enforce moda al (fail-closed) ───
# PREDİKAT: 0=profil gerçekten parse edildi VE enforce modda, 1=değil.
# ESKİDEN: 'apparmor_parser ... 2>/dev/null || true' ile parse hatası
# YUTULUYOR ve çağıran taraf KOŞULSUZ "enforce modda" başarı mesajı
# basıyordu — profil aslında hiç yüklenmemiş olsa bile. Bu, 'srvctl security
# audit' çıktısına da yansıyan YANLIŞ bir güvenceydi (T7b fail-closed audit
# ilkesiyle çelişir: varlık kontrolü ≠ gerçek enforcement kontrolü). Şimdi
# apparmor_parser'ın GERÇEK exit code'u kontrol ediliyor; hata mesajı
# stderr'e (uyarı olarak) yazdırılıyor, çağıran 1 dönünce KENDİSİ warn basar
# (bu fonksiyon "success" YALANI söylemez).
# Her iki AppArmor profilini (FPM + CLI/worker) verilen PHP sürümüyle yeniden
# render eder ve fail-closed yükler. PREDİKAT: 0=ikisi de enforce, 1=değil.
#
# HOST BULGUSU (gerçek Laravel deploy'u, Ubuntu 22.04): PHP sürümü profil
# İÇERİĞİNE GÖMÜLÜDÜR — hem binary yolu (/usr/sbin/php-fpm<ver>) hem SOCKET
# yolu (/run/php/php<ver>-fpm-<sname>.sock). 'domain php-switch' profili
# yenilemediği için 8.3→8.4 geçişinde unit şununla ölüyordu:
#   ERROR: unable to bind listening socket '/run/php/php8.4-fpm-<sname>.sock':
#          Permission denied (13)
# Yani AppArmor, profilde yazmayan yeni socket yolunu reddediyordu.
_domain_render_apparmor_profiles() {
    local domain="$1" php_ver="$2"
    local sname; sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local rc=0

    render_template "${SRVCTL_TEMPLATES}/apparmor/profile.tpl" \
        "SAFE_NAME=${sname}" "DOMAIN=${domain}" "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" "PHP_VERSION=${php_ver}" \
        > "/etc/apparmor.d/srvctl-${sname}"
    _domain_load_apparmor_profile "/etc/apparmor.d/srvctl-${sname}" "srvctl-${sname}" || rc=1

    render_template "${SRVCTL_TEMPLATES}/apparmor/profile-cli.tpl" \
        "SAFE_NAME=${sname}" "DOMAIN=${domain}" "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" "PHP_VERSION=${php_ver}" \
        > "/etc/apparmor.d/srvctl-${sname}-cli"
    _domain_load_apparmor_profile "/etc/apparmor.d/srvctl-${sname}-cli" "srvctl-${sname}-cli" || rc=1

    return $rc
}

_domain_load_apparmor_profile() {
    local profile_path="$1" profile_name="$2"
    local parser_err
    if ! parser_err=$(apparmor_parser -r "$profile_path" 2>&1); then
        warn "AppArmor profili PARSE/YÜKLEME hatası: ${profile_name} — profil ENFORCE MODDA DEĞİL"
        [[ -n "$parser_err" ]] && echo "$parser_err" | sed 's/^/    /' >&2
        return 1
    fi
    if ! aa-enforce "$profile_path" >/dev/null 2>&1; then
        warn "aa-enforce başarısız: ${profile_name} — profil parse edildi ama enforce moda alınamadı"
        return 1
    fi
    return 0
}

# ─── Hayalet/kalıntı domain tespiti (GÜVENLİK DENETİMİ EKİ — kendi kendini
# sahiplenme döngüsünün kırılması) ───
# HOST bulgusu (srvctl-jammy): nginx paketi kendi '/var/www/html' dizinini
# kurar. 'list_all_domains()' (lib/core.sh) bunu '.credentials' varlığına
# bakarak eler — AMA '_domain_repair'in KENDİSİ o dizine (DB/Redis adımı
# atlanıp fonksiyon sonunda) '.credentials' YAZIYOR ve bir AppArmor profili
# YÜKLÜYORDU. Yani BİR KEZ 'repair --all' çalıştıktan sonra '/var/www/html'
# ARTIK 'list_all_domains()'e göre de MEŞRU bir domain oluyordu: işaret,
# onu YARATAN komut tarafından tüketiliyordu (kendi kendini doğrulayan bir
# döngü — 'repair' kendi ürettiği kalıntıyı bir sonraki çalıştırmada
# "onarılacak domain" sanıyordu).
#
# NEDEN '.srvctl-meta' DEĞİL, 'web_<sname>' LİNUX KULLANICISI SEÇİLDİ: ilk
# akla gelen çözüm '.srvctl-meta' varlığını da şart koşmaktı (repair bu
# dosyayı YALNIZCA Redis ACL adımı DB/Redis parolaları GERÇEKTEN
# üretilmişse yazar — bkz. aşağıdaki Redis bloğu — boş parola için hiç
# tetiklenmez, bu yüzden '.srvctl-meta' de repair'in kendi kendine
# üretemeyeceği bir işarettir). AMA '.srvctl-meta' Faz 2'de eklenen GÖRECELİ
# YENİ bir dosya: bu özellikten ÖNCE '_domain_add' ile eklenmiş MEŞRU/eski
# bir domain bu kontrolde YANLIŞLIKLA hayalet sayılıp '--all' dışında
# bırakılırdı — sessiz bir regresyon. 'web_<sname>' Linux sistem kullanıcısı
# ise '_domain_add'in EN İLK adımından beri (bu dosyada 'useradd' YALNIZCA
# BİR YERDE çağrılır — '_domain_add'in adım 1'i, aşağıda ARANDI ve
# doğrulandı) HER domain için oluşturulur ve _domain_repair bunu ASLA
# oluşturmaz (bu fonksiyon hiçbir yerde 'useradd'/'groupadd' ÇAĞIRMAZ) —
# yani geriye dönük yanlış pozitif üretmeyen, repair'in kendi eylemleriyle
# ASLA taklit edilemeyen tek sinyal budur.
#
# PREDİKAT: 0=hayalet (domain GİBİ görünmüyor), 1=gerçek domain gibi görünüyor.
_domain_repair_is_ghost() {
    local domain="$1"
    local sname web_user
    sname=$(safe_name "$domain")
    web_user="web_${sname}"
    ! id "$web_user" &>/dev/null
}

# Hayalet/kalıntı teşhisini AÇIKÇA raporlar — sessizce atlamak YOK, otomatik
# silme YOK (karar operatöre bırakılır; '.credentials' içinde üretilmiş
# gerçek parolalar olabilir ve/veya operatörün GERÇEK ama bozuk bir domaini
# olabilir — bkz. görev talebi).
_domain_repair_ghost_report() {
    local domain="$1"
    local base="${WEB_ROOT}/${domain}"
    local sname web_user
    sname=$(safe_name "$domain")
    web_user="web_${sname}"
    local has_creds="YOK" has_meta="YOK"
    [[ -f "${base}/.credentials" ]] && has_creds="VAR"
    [[ -f "${base}/.srvctl-meta" ]] && has_meta="VAR"
    warn "'${domain}' (${base}) srvctl tarafından yönetilen GERÇEK bir domain gibi GÖRÜNMÜYOR:"
    warn "    Linux sistem kullanıcısı '${web_user}': YOK  |  .credentials: ${has_creds}  |  .srvctl-meta: ${has_meta}"
    if [[ "$has_creds" == "VAR" ]]; then
        warn "    (.credentials VAR ama web kullanıcısı YOK — muhtemelen DAHA ÖNCEKİ bir 'repair --all' çalıştırmasının bıraktığı bir KALINTI; ör. nginx'in varsayılan '/var/www/html' dizini yanlışlıkla domain sanılmış olabilir.)"
    fi
    warn "    'domain repair' bu dizine DOKUNMADI (otomatik silme YAPILMAZ). Elle karar verin:"
    warn "      - Meşru ama bozuk bir domainse: eksik Linux kullanıcısını oluşturup (groupadd/useradd '${web_user}') tekrar deneyin."
    warn "      - Hayalet bir kalıntıysa (ör. nginx varsayılan dizini): '${base}' içeriğini inceleyip gerekiyorsa elle kaldırın."
}

# ─── public_html / current onarımı (GÜVENLİK DENETİMİ EKİ — KARAR REVİZYONU) ───
# İLK KARAR (bu fonksiyonun önceki sürümü) yalnız TEŞHİS koyuyordu:
# "kök neden deploy tarafında, releases/ boşken yönlendirilecek geçerli
# hedef yok" gerekçesiyle onarmıyordu. HOST'ta (srvctl-jammy) elde edilen
# YENİ kanıt bu gerekçeyi geçersiz kıldı: deploy tarafının kendi kurtarma
# kodu (BUG C düzeltmesi, lib/deploy.sh:_deploy_no_rollback_recover, bu
# görevin kapsamı DIŞI — DOKUNULMADI) çalışıp kırık symlink'i KALDIRDI ve
# arkasında 'public_html.bak.<epoch>/' adlı GERÇEK, kurtarılabilir bir yedek
# BIRAKTI. Yani "yönlendirilecek geçerli hedef yok" iddiası artık DOĞRU
# DEĞİL. Ayrıca ölçüldü: 'public_html' TAMAMEN YOKKEN (ne dizin ne symlink)
# 'domain repair', 'php-switch', 'security harden-fpm --apply' — YANİ TÜM
# belgelenmiş kurtarma yolları — FPM config-test aşamasında BAŞARISIZ
# oluyordu ('chdir = /public_html', chroot'a göreli, pool.conf.tpl DOĞRU —
# sorun şablonda değil, YOLUN YOKLUĞUNDA). Repair'in "domainimi düzelt"
# komutu olması ve kendi önerdiği kurtarma yolunun (harden-fpm --apply) AYNI
# nedenle çalışmaması bu döngüyü ACİL kılıyor: repair'in onaramadığı tek
# şey, repair'in ÇALIŞMASINI ENGELLEYEN şeyin ta kendisiydi — bu yüzden
# artık KENDİSİ onarıyor.
#
# SIRALAMA SÖZLEŞMESİ: çağıran (_domain_repair) bunu FPM config-test/
# aktivasyon adımından (2/4) ÖNCE çağırmalı — aksi halde 'chdir' invariant'ı
# hâlâ bozukken config-test yine düşer.
#
# 'current' İÇİN AYRI karar: 'current' bir release'e işaret ETMEK
# ZORUNDADIR — geçerli bir release yoksa SAHTE bir hedef ÜRETMEK YANLIŞ
# olur. lib/deploy.sh:_deploy_no_rollback_recover İLE AYNI karar (o
# fonksiyonun başlık yorumu: "'current' İÇİN AYRI bir yedek YOKTUR ...
# systemd WorkingDirectory'si için 'current'ın VAR OLMASI ZORUNLU
# DEĞİLDİR"). Bu yüzden kırık 'current' YALNIZCA KALDIRILIR, ASLA yeniden
# ÜRETİLMEZ.
#
# YAN ETKİLİ — PREDİKAT DEĞİL: her zaman koşulsuz döner (bir sonraki adımın
# — FPM config-test — kendi başarı/başarısızlığı ZATEN doğru sinyali verir;
# bu fonksiyonun kendi başarısızlığını AYRICA izlemek gereksiz tekrar olurdu).
_domain_repair_fix_docroot() {
    local target="$1" base="$2" web_user="$3"

    # 'current': kırıksa kaldır, UYDURMA (bkz. yukarı).
    if [[ -L "${base}/current" && ! -e "${base}/current" ]]; then
        local cur_target
        cur_target=$(readlink "${base}/current" 2>/dev/null)
        rm -f "${base}/current"
        warn "'${target}': 'current' kırık bir symlink'ti (hedef: ${cur_target:-?}) — kaldırıldı. 'current' YENİDEN ÜRETİLMEDİ (geçerli bir release'e işaret etmesi ZORUNLU; sahte bir hedef üretmek yanlış olur) — 'srvctl deploy' ile yeni bir release yayınlayın."
    fi

    # 'public_html' zaten sağlıklıysa (gerçek dizin ya da hedefi mevcut bir
    # symlink) dokunma. '-e' kırık symlink'te YANLIŞ döner (hedefi takip
    # eder) — bu yüzden bu tek satır hem "yok" hem "kırık" durumunu birlikte
    # yakalar.
    [[ -e "${base}/public_html" ]] && return 0

    # Kırık symlink varsa aşağıdaki kademelere geçmeden önce temizle.
    [[ -L "${base}/public_html" ]] && rm -f "${base}/public_html"

    # 1) Diskteki EN YENİ 'public_html.bak.<epoch>' dizinini geri yükle.
    # lib/deploy.sh:_deploy_no_rollback_recover İLE AYNI desen/gerekçe: epoch
    # dizin ADINDAN okunur (mtime'DAN DEĞİL) — 'base' root:root 751
    # olduğundan (T1 fs-ownership modeli) web_user base İÇİNE YENİ bir
    # '.bak.<epoch>' dizini YARATAMAZ, bu yüzden isimdeki epoch güvenilirdir.
    local newest_epoch="" newest_bak="" epoch
    while IFS= read -r epoch; do
        [[ -z "$epoch" ]] && continue
        newest_epoch="$epoch"
    done < <(find "$base" -maxdepth 1 -type d -name 'public_html.bak.*' 2>/dev/null \
                 | sed 's#.*/public_html\.bak\.##' \
                 | grep -E '^[0-9]+$' \
                 | sort -n)
    if [[ -n "$newest_epoch" ]]; then
        newest_bak="${base}/public_html.bak.${newest_epoch}"
        if [[ -d "$newest_bak" && ! -L "$newest_bak" ]]; then
            local bak_human
            bak_human=$(date -r "$newest_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || date -d "@${newest_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || echo "epoch ${newest_epoch}")
            mv "$newest_bak" "${base}/public_html"
            warn "'${target}': 'public_html' eksik/kırıktı — diskte bulunan ÖNCEKİ bir yedek geri yüklendi: $(basename "$newest_bak") (tarih: ${bak_human}). Bu içerik BAYAT olabilir, kontrol edin."
        fi
    fi

    # 2) Hâlâ yoksa: BOŞ bir public_html oluştur (chdir invariant'ı için
    # ZORUNLU) — sahiplik/izin '_domain_fs_plan' (TEK doğruluk kaynağı,
    # harden-fs'in de kullandığı) İLE TUTARLI. Framework argümanı burada
    # ÖNEMSİZ: 'public_html' satırı _domain_fs_plan'ın TABAN listesindedir
    # (framework'e özgü case bloğunun DIŞINDA), bu yüzden hangi framework
    # verilirse verilsin AYNI değeri döner.
    if [[ ! -e "${base}/public_html" ]]; then
        mkdir -p "${base}/public_html"
        local pub_mode
        pub_mode=$(_domain_fs_plan "${base}" "${web_user}" "ci4" | awk -F'|' '$1=="public_html"{print $3}')
        [[ -n "$pub_mode" ]] || pub_mode=750
        chown "${web_user}:${web_user}" "${base}/public_html" 2>/dev/null || true
        chmod "$pub_mode" "${base}/public_html" 2>/dev/null || true
        if command -v setfacl &>/dev/null; then
            setfacl -m "u:www-data:rx" "${base}/public_html" 2>/dev/null || true
            setfacl -d -m "u:www-data:rx" "${base}/public_html" 2>/dev/null || true
        fi
        warn "'${target}': 'public_html' YOKTU ve geri yüklenecek bir yedek bulunamadı — BOŞ bir 'public_html' oluşturuldu (PHP-FPM 'chdir' invariant'ı için ZORUNLU; aksi halde domain HİÇBİR komutla — php-switch/harden-fpm/repair dahil — kurtarılamazdı). 'srvctl deploy' ile içerik yayınlayın."
    fi
}

# ─── PHP sürümünü DOSYA SİSTEMİNDEN türet ('.credentials' YOKKEN) ───
# _domain_ensure_credentials (aşağıda) tarafından kullanılır: '.credentials'
# hiç yoksa PHP_VERSION'ı öğrenmenin tek yolu gözlemlenebilir duruma bakmaktır
# ('.credentials'a zaten güvenilemez — konu bu). Sıra: izole per-domain FPM
# unit'inin ExecStart'ı (php-fpm<ver> — bkz. templates/systemd/
# srvctl-fpm.service.tpl) → paylaşılan pool.d'nin bulunduğu sürüm dizini.
# İkisi de bulunamazsa DEFAULT_PHP_VERSION'a düşer — bu bir TAHMİNDİR, gerçek
# kurulu sürüm DEĞİL; çağırana ve operatöre açıkça warn edilir.
#
# GÜVENLİK NOTU: doğrulama 'php_version_exists' (bu MAKİNEDE gerçekten kurulu
# mu) İLE DEĞİL, '_derive_php'İLE (core.sh) BİREBİR AYNI 'assert_php_version'
# (yalnız BİÇİM: ^[0-9]+\.[0-9]+$) ile yapılır — kaynak (kendi ürettiğimiz
# systemd unit'i / pool.d dizin adı) '.credentials' kadar güvenilir DEĞİLDİR
# ama rastgele saldırgan girdisi de DEĞİLDİR; asıl güvenlik sınırı zaten
# downstream'de (unit render/aktivasyon gerçek kurulumu doğrular) sağlanır.
# Bu ayrıca test edilebilirliği sağlar: macOS/CI'da '/usr/sbin/php-fpm*'
# hiç yoktur, 'php_version_exists' burada kullanılsaydı HER ZAMAN false
# dönüp bu fonksiyonu fiilen test edilemez kılardı.
# PREDİKAT DEĞİL — her zaman bir sürüm string'i basar (stdout), asla boş
# dönmez.
_domain_detect_installed_php() {
    local sname="$1"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local unit_file="${sysd_dir}/srvctl-fpm-${sname}.service"
    local ver=""

    if [[ -f "$unit_file" ]]; then
        ver="$(grep -oE 'php-fpm[0-9]+\.[0-9]+' "$unit_file" 2>/dev/null | head -1 \
                 | grep -oE '[0-9]+\.[0-9]+')" || true
        if [[ -n "$ver" ]] && assert_php_version "$ver"; then
            echo "$ver"
            return 0
        fi
        ver=""
    fi

    # Paylaşılan havuz: /etc/php/<ver>/fpm/pool.d/<sname>.conf. Test-seam
    # YOK — mevcut kod tabanında bu yol zaten her yerde hardcoded (ör.
    # lib/security.sh '_harden_fpm_apply', bu dosyada '_domain_php_switch');
    # macOS/CI'da '/etc/php' bulunmadığından glob sessizce eşleşmez, hataya
    # düşmez (aşağıdaki döngü hiç çalışmaz).
    local pool_dir
    for pool_dir in /etc/php/*/fpm/pool.d; do
        [[ -f "${pool_dir}/${sname}.conf" ]] || continue
        ver="$(basename "$(dirname "$(dirname "$pool_dir")")")"
        if assert_php_version "$ver"; then
            echo "$ver"
            return 0
        fi
        ver=""
    done

    warn "'${sname}' için kurulu PHP sürümü dosya sisteminden tespit edilemedi — varsayılan (${DEFAULT_PHP_VERSION}) kullanılacak, DOĞRULAYIP gerekiyorsa 'domain php-switch' ile düzeltin"
    echo "${DEFAULT_PHP_VERSION}"
    return 0
}

# ─── '.credentials' KURTARMA (GÜVENLİK DENETİMİ EKİ — designwestgate.art
#     sınıfı, HOST'ta ölçüldü) ───
# _domain_repair_fix_docroot İLE AYNI SINIF sorunu çözer: repair'in (ve
# 'security harden-fpm --apply'ın) KENDİSİ, düzelteceği domain'in eksik bir
# ön-koşulu YÜZÜNDEN çalışamıyordu. Buradaki ön-koşul 'public_html' değil
# '.credentials': eski bir srvctl sürümünde eklenmiş ya da yarıda kesilmiş
# bir 'domain add'de bu dosya HİÇ YAZILMAMIŞ olabilir. Domain GERÇEKTEN
# hardened ise (bkz. _domain_is_hardened, core.sh) read_credentials/
# _derive_php bu eksikliği fail-closed 'tamper' sayıp error() ile ÇIKARDI —
# yani audit'in FAIL dediği domain'i düzeltecek TEK komutların (repair,
# harden-fpm --apply) kendisi de çalışamıyordu (çıkmaz). KUSUR 2 mesaj
# ayrımı (core.sh:_require_owned_or_warn) bu çıkmazı GÖRÜNÜR kıldı ama TEK
# BAŞINA ÇÖZMEDİ — operatör hâlâ dosyayı ELLE üretmek zorundaydı. Bu
# fonksiyon onu OTOMATİK yapar.
#
# İKİ SERT KURAL (görev talebi):
#  1) VAR OLAN bir '.credentials'a ASLA dokunulmaz — üretim SADECE dosya
#     GERÇEKTEN yoksa ('-e' testi) tetiklenir.
#  2) DB/Redis parolası UYDURULMAZ. DB_NAME/DB_USER identifier'ları BİLE
#     yazılmaz — '_domain_repair' zaten bunları HER ZAMAN safe_name'den
#     yeniden türetir, '.credentials'taki değerlere GÜVENMEZ (bkz.
#     _domain_repair başlık yorumu); domain'in GERÇEKTEN bir veritabanı/
#     Redis ACL kullanıcısı olup olmadığı BİLİNMİYORSA var olduğunu iddia
#     eden bir isim yazmak yanıltıcı olurdu. Altı alanın (DB_NAME/DB_USER/
#     DB_PASS/REDIS_USER/REDIS_PASS/REDIS_PREFIX) TÜMÜ boş bırakılır —
#     '_domain_repair'in kendi DB/Redis provizyon blokları zaten
#     '-n "$db_pass"'/'-n "$redis_pass"' şartıyla GATED'tır (bkz. o
#     fonksiyondaki ilgili bloklar): boş parola bu adımları GÜVENLE atlar,
#     YANLIŞ bir parola ÜRETMEZ/UYGULAMAZ.
#
# ÇAĞRI YERİ SÖZLEŞMESİ: yalnız GERÇEK domainler için çağrılmalıdır —
# çağıranlar ('_domain_repair', 'security harden-fpm') zaten kendi hayalet
# tespitini yapmış olmalı; bu fonksiyon 'id web_<sname>' ile KENDİ savunma-
# derinliği kapısını da taşır (ghost bir dizine credentials üretmez).
#
# PREDİKAT DEĞİL — yan etkili. Dosya zaten varsa ya da domain hayaletse
# hiçbir şey YAPMADAN 0 döner.
_domain_ensure_credentials() {
    local domain="$1"
    local base="${WEB_ROOT}/${domain}"
    local creds_file="${base}/.credentials"

    [[ -e "$creds_file" ]] && return 0

    local sname; sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    id "$web_user" &>/dev/null || return 0

    local php_ver; php_ver=$(_domain_detect_installed_php "$sname")

    warn "'${domain}': '.credentials' eksik (muhtemelen eski bir srvctl sürümünde eklenmiş domain — TAMPER DEĞİL) — gözlemlenen durumdan yeniden üretiliyor"
    _domain_write_credentials "$domain" "$base" "$web_user" "$php_ver" \
        "" "" "" "" "" ""
    warn "'${domain}': '.credentials' yeniden üretildi (PHP=${php_ver}). DB_NAME/DB_USER/DB_PASS ve REDIS_* alanları BİLİNMİYOR, BOŞ bırakıldı — bu domain bir veritabanı/Redis kullanıyorsa parolaları ELLE belirleyip dosyaya yazmanız gerekir (aksi halde 'domain repair' bu adımları sessizce atlar); kullanmıyorsa (ör. statik site) boş kalması ZARARSIZDIR."
    log_action "domain repair/harden-fpm: '.credentials' yeniden üretildi (${domain}, php=${php_ver}, DB/Redis alanları boş)"
    return 0
}

# ─── Hayalet FPM pool.d dosyalarının temizliği (GÜVENLİK DENETİMİ EKİ —
# ikinci dereceden hasar: hayalet domain düzeltmesi kaynağı kapattı ama
# ZATEN ÜRETİLMİŞ kalıntı filoyu bloke etmeye devam ediyordu) ───
# HOST bulgusu (srvctl-jammy): önceki bir 'repair --all' çalıştırması,
# hayalet '/var/www/html' için 'user = web_html' (VAR OLMAYAN bir sistem
# kullanıcısı) içeren bir 'pool.d/html.conf' YAZMIŞTI (hayalet-tespiti
# eklenmeden ÖNCE — bkz. _domain_repair_is_ghost). php-fpm böyle bir havuzu
# KABUL ETMEZ — TEK bu dosya yüzünden paylaşılan php<ver>-fpm.service HİÇ
# BAŞLAYAMIYOR ('Restart=on-failure' döngüsü → "start request repeated too
# quickly" rate-limit). Sonuç: o php sürümünü kullanan HİÇBİR YENİ domain
# eklenemiyordu — 'domain add' 4/10. adımda (PHP-FPM pool) ölüyordu.
# Hayalet-tespiti kaynağı KAPATTI (yeni kalıntı ÜRETİLMEZ) ama zaten var
# olan kalıntıyı TEMİZLEMİYORDU — kullanıcı komut satırından çıkamayacağı
# bir çıkmaza düşüyordu ('domain add' çalışmıyor, eski 'repair' de bu
# dosyayı kaldırmıyordu).
#
# KARAR — burada OTOMATİK SİL, '.credentials' kararından (yalnız raporla,
# silme) BİLİNÇLİ olarak FARKLI: bir pool.d/*.conf dosyası SAF altyapı
# konfigürasyonudur — hiçbir sır/parola/kullanıcı verisi İÇERMEZ (bkz.
# templates/php-fpm/pool.conf.tpl — DB/Redis kimlikleri '.credentials'ta,
# BURADA değil) ve 'user = <var olmayan sistem kullanıcısı>' HİÇBİR meşru
# senaryoda geçerli olamaz: gerçek bir domain'in web_user'ı _domain_add'in
# İLK adımından beri HER ZAMAN var olur (AYNI sinyal —
# _domain_repair_is_ghost başlık yorumuna bkz., o fonksiyonda da 'id
# web_<sname>' kullanılıyor). '.credentials'ta kaybedilecek YENİDEN
# ÜRETİLEMEZ bir değer (üretilmiş parola) varken, burada YOK; buna karşın
# BIRAKMANIN bedeli somut ve yüksek: TEK bir kalıntı dosya o php sürümünü
# paylaşan TÜM filonun 'domain add'ini kilitler. Yine de SESSİZ değil:
# silinen HER dosyanın TAM YOLU hem kullanıcıya (warn) hem log_action'a
# yazılır.
#
# PREDİKAT DEĞİL — yan etkili, koşulsuz döner (bir php sürümünün pool.d'si
# henüz yoksa/boşsa bu HATA değildir).
_domain_fpm_purge_ghost_pools() {
    local php_version="$1"
    local pool_dir="${SRVCTL_PHP_POOL_DIR:-/etc/php/${php_version}/fpm/pool.d}"
    [[ -d "$pool_dir" ]] || return 0

    local conf pool_user
    for conf in "${pool_dir}"/*.conf; do
        [[ -f "$conf" ]] || continue
        # 'www.conf'(.disabled) bu taramanın kapsamı DIŞI — srvctl-yönetimli
        # değil, init.sh tarafından zaten devre dışı bırakılıp yönetiliyor
        # (bkz. lib/init.sh:_install_php).
        [[ "$(basename "$conf")" == "www.conf" ]] && continue
        pool_user=$(grep -m1 -E '^[[:space:]]*user[[:space:]]*=' "$conf" 2>/dev/null \
            | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
        [[ -n "$pool_user" ]] || continue
        if ! id "$pool_user" &>/dev/null; then
            warn "Hayalet FPM havuzu bulundu ve KALDIRILDI: ${conf} (var olmayan sistem kullanıcısı: '${pool_user}' — bu dosya TEK BAŞINA paylaşılan php${php_version}-fpm servisinin hiç başlamamasına yol açabiliyordu)"
            log_action "hayalet pool.d dosyası kaldırıldı: ${conf} (user=${pool_user} sistemde yok)"
            rm -f -- "$conf"
        fi
    done
}

_domain_repair() {
    local target="$1"
    [[ -z "$target" ]] && error "Kullanım: srvctl domain repair <domain> | --all"

    if [[ "$target" == "--all" ]]; then
        header "Tüm Domainler Onarılıyor..."
        # ─── GÜVENLİK DENETİMİ EKİ (fail-open raporlama düzeltmesi) ───
        # ESKİDEN: '_domain_repair "$domain"' çıplak çağrılıyordu (dönüş
        # değeri YOK SAYILIYORDU) ve döngü sonunda KOŞULSUZ
        # 'success "Tüm domainler onarıldı."' + implicit EXIT=0 basılıyordu.
        # HOST'ta ölçüldü (srvctl-jammy): FPM unit aktif edilemeyen bir
        # domain'de bile (izole unit durdurulmuş/disable edilmiş, site
        # KAPALI) çıktı "✓ Domain onarıldı." + "✓ Tüm domainler onarıldı." +
        # EXIT=0 basıyordu — bir cron/betik yalnız exit kodunu kontrol
        # ederse her şeyin yolunda olduğunu SANIR (composer/privdrop'ta
        # yakalanan sınıfla AYNI). Artık her domain'in GERÇEK dönüş değeri
        # toplanır; TEK bir domain başarısız olsa bile DÖNGÜ DEVAM EDER
        # (toplu iş yarıda kesilmez) ama SONUÇ dürüst: kaç domain başarısız
        # olduğu yazılır ve en az biri başarısızsa fonksiyon SIFIRDAN FARKLI
        # döner. NOT: 'set -e' altında çıplak '_domain_repair "$domain"'
        # çağrısı, fonksiyon 1 dönünce TÜM döngüyü/'--all' komutunu
        # KOŞULSUZ sonlandırırdı (bkz. CLAUDE.md/proje kuralı — koşul
        # olmayan bağlamda non-zero exit script'i düşürür); bu yüzden çağrı
        # 'if ! ...' ile GUARD'lanır.
        #
        # GÜVENLİK DENETİMİ EKİ (kendi kendini sahiplenme döngüsü — HOST'ta
        # ölçüldü): buradaki numaralandırma ESKİDEN '${WEB_ROOT}/*/' üzerinde
        # HAM bir glob'du — 'domain list'/'security audit' gibi diğer
        # tüketicilerin kullandığı 'list_all_domains()' (lib/core.sh)
        # sözleşmesini ATLIYORDU. Artık AYNI sözleşme kullanılıyor (tekilleşme)
        # VE ONA EK OLARAK 'list_all_domains()'in çıktısı
        # '_domain_repair_is_ghost' ile bir kez daha süzülüyor — yalnız
        # 'list_all_domains()'e geçmek TEK BAŞINA yetmezdi: o fonksiyonun
        # işareti '.credentials' ve repair'in KENDİSİ tam olarak bu dosyayı
        # üretiyor (bkz. '_domain_repair_is_ghost' başlık yorumu — kendi
        # kendini doğrulayan döngü). Hayalet bulunan her dizin AÇIKÇA
        # raporlanır (bkz. '_domain_repair_ghost_report') ve ATLANIR — ne
        # 'failed_domains'e ne de 'repair_total'e sayılır: bu, gerçek
        # domain başarısızlıklarını sabit bir "nginx varsayılan dizini"
        # gürültüsünden AYIRIR (bu ayrım olmadan düzeltmenin dürüst
        # exit-kodu değeri, HER standart sunucuda '/var/www/html' yüzünden
        # SIFIRLANIRDI).
        local -a failed_domains=()
        local -a ghost_domains=()
        local repair_total=0
        while IFS= read -r domain; do
            [[ -n "$domain" ]] || continue
            if _domain_repair_is_ghost "$domain"; then
                ghost_domains+=("$domain")
                _domain_repair_ghost_report "$domain"
                continue
            fi
            repair_total=$((repair_total + 1))
            # GÜVENLİK DENETİMİ EKİ (MADDE 1 yan bulgusu — list_all_domains'in
            # ikinci kapısı açıldıktan SONRA ortaya çıkan yeni bir çökme yolu):
            # '_domain_repair' tek bir domain için 'read_credentials'/
            # '_domain_read_framework'/'_domain_framework_declared' (core.sh)
            # üzerinden 'error()' çağırabilir — hardened bir domain'de
            # '.credentials'/'.srvctl-meta' root-owned DEĞİLSE (tamper) bu
            # fonksiyonlar KOŞULSUZ 'exit 1' eder. 'error()' bir RETURN değil,
            # gerçek bir 'exit'tir; çıplak (subshell'siz) bir çağrıda bu
            # yalnız BU domain'in onarımını değil, TÜM '--all' SÜRECİNİ
            # (döngünün geri kalanını) SESSİZCE yarıda keserdi — HOST mutasyon
            # testiyle doğrulandı: hardened+'.credentials'sız bir domain'den
            # SONRA gelen alfabetik sırada bir domain HİÇ işlenmiyordu, ne
            # "TAMAMLANAMADI" özeti ne de dönüş değeri asla basılmıyordu
            # (process anında ölüyordu). Bu yol ÖNCEDEN ulaşılamazdı — böyle
            # bir domain '.credentials' yokluğu yüzünden 'list_all_domains()'
            # tarafından zaten ELENİYORDU; ikinci kapı (web_<sname> kullanıcı
            # varlığı) bu domainleri artık GÖRÜNÜR kıldığından bu çökme yolu
            # '--all' için YENİ ortaya çıktı. Çözüm: her domain'in onarımı
            # bir ALT-KABUKTA ('( ... )') çalıştırılır — 'exit' yalnız o alt
            # kabuğu sonlandırır, DÖNÜŞ KODU normal şekilde '$?' ile geri
            # gelir ve 'if !' bunu her zamanki gibi 'başarısız' sayar; döngü
            # KESİLMEDEN devam eder (tek domain kaybı, toplu iş KAYBOLMAZ).
            if ! ( _domain_repair "$domain" ); then
                failed_domains+=("$domain")
            fi
        done < <(list_all_domains)
        if [[ "${#failed_domains[@]}" -eq 0 ]]; then
            if [[ "${#ghost_domains[@]}" -gt 0 ]]; then
                success "Tüm GERÇEK domainler onarıldı (${repair_total}/${repair_total}) — ${#ghost_domains[@]} hayalet kalıntı ATLANDI (yukarıya bakın): ${ghost_domains[*]}"
            else
                success "Tüm domainler onarıldı (${repair_total}/${repair_total})."
            fi
            return 0
        else
            warn "Onarım TAMAMLANAMADI: ${#failed_domains[@]}/${repair_total} domain başarısız: ${failed_domains[*]}"
            warn "Her biri için ayrıntılı hata yukarıda — tek tek 'srvctl domain repair <domain>' ile tekrar deneyin."
            return 1
        fi
    fi

    domain_exists "$target" || error "Domain bulunamadı: ${target}"
    # GÜVENLİK DENETİMİ EKİ: doğrudan 'srvctl domain repair <ad>' çağrısı da
    # AYNI hayalet kontrolünden geçer — 'domain_exists' yalnız dizin+ad
    # sözdizimini doğrular (bkz. core.sh), nginx'in '/var/www/html' gibi
    # srvctl-DIŞI bir dizinini ELEMEZ. Bu kontrol olmadan operatör elle de
    # olsa bir hayalet dizine '.credentials'/AppArmor profili YAZDIRABİLİRDİ.
    if _domain_repair_is_ghost "$target"; then
        _domain_repair_ghost_report "$target"
        error "'${target}' bir srvctl domain'i gibi görünmüyor (web kullanıcısı yok) — onarım İPTAL EDİLDİ, yukarıya bakın."
    fi
    # KUSUR 3 (designwestgate.art): ghost DEĞİLSE ama '.credentials' hiç
    # yoksa, aşağıdaki 'read_credentials' hardened bir domainde fail-closed
    # 'tamper' reddi verip repair'in KENDİSİNİ bloke ederdi — bkz.
    # _domain_ensure_credentials başlık yorumu. Yalnız dosya GERÇEKTEN
    # eksikse üretir, var olana DOKUNMAZ.
    _domain_ensure_credentials "$target"
    read_credentials "$target"
    local base="${WEB_ROOT}/${target}"
    # PHP sürümü _derive_php ile DOĞRULANMIŞ biçimde alınır (assert_php_version) —
    # ham '.credentials' değeri path/komut enjekte edemesin (O2/K3 sertleştirmesi;
    # _domain_remove/_domain_clone zaten aynı deseni kullanıyordu, repair atlanmıştı).
    local php_ver; php_ver=$(_derive_php "$target" "${DEFAULT_PHP_VERSION}")
    # Kimlikler (sname/web_user/db_name/db_user) HER ZAMAN safe_name'den türetilir;
    # .credentials içindeki SAFE_NAME/WEB_USER/DB_NAME/DB_USER alanlarına GÜVENİLMEZ.
    # Henüz hardened olmayan (harden-fs uygulanmamış) bir domainde bu dosya
    # web_<domain> tarafından tamper edilebilirse, dosyadan okunan bir DB adı/
    # kullanıcısı ele geçirilmiş kiracının BAŞKA bir kiracının şemasına
    # CREATE USER/GRANT almasına yol açar (Faz 1/T2 tehdit modeli).
    local sname; sname=$(safe_name "$target")
    local web_user="web_${sname}"
    local db_name="db_${sname}"
    local db_user="usr_${sname}"
    local redis_user="redis_${sname}"
    local redis_prefix="${REDIS_PREFIX:-${sname}:}"
    # ─── K3 DÜZELTMESİ (denetim DALGA 4 — KRİTİK) ───
    # db_pass/redis_pass kimlik/grant KAPSAMINI belirlemez ama artık DOĞRUDAN
    # SQL heredoc'una ve tek satırlık Redis ACL metnine GÖMÜLÜYOR — ikisi de
    # birer string-enjeksiyon sink'i. Henüz hardened olmayan bir domainde
    # .credentials web_user tarafından silinip YENİDEN YAZILABİLİR
    # (_require_owned_or_warn bu durumda yalnız warn verip 0 döner — core.sh).
    # Saldırgan ör. DB_PASS="x'; GRANT ALL PRIVILEGES ON *.* TO 'usr_evil'@'127.0.0.1' ...; --"
    # ya da REDIS_PASS="x ~* &* +@all" yazarsa root MySQL oturumuna SQL enjekte
    # edebilir ya da Redis ACL satırına (boşlukla ayrılmış token'lar — printf
    # TEK satır üretir) fazladan token ekleyip '~*' ile TÜM anahtarlara
    # erişebilirdi. generate_password() yalnızca [A-Za-z0-9] üretir (core.sh) —
    # bu karakter seti, kullanmadan ÖNCE beyaz liste olarak uygulanır; uymayan
    # (tampered) bir değer ASLA SQL/ACL'e akmaz — bunun yerine YENİ bir parola
    # üretilip fonksiyon sonunda .credentials'a GERİ YAZILIR (dosya bu
    # vesileyle kanonik hale döner; sonraki 'domain repair' aynı tamper'ı
    # tekrar bulmaz).
    local db_pass="${DB_PASS:-}"
    if [[ -n "$db_pass" ]] && ! [[ "$db_pass" =~ ^[A-Za-z0-9]+$ ]]; then
        warn "DB_PASS beklenmeyen karakter içeriyor (${target}) — tamper şüphesi, yeni parola üretiliyor"
        db_pass=$(generate_password 24)
    fi
    local redis_pass="${REDIS_PASS:-}"
    if [[ -n "$redis_pass" ]] && ! [[ "$redis_pass" =~ ^[A-Za-z0-9]+$ ]]; then
        warn "REDIS_PASS beklenmeyen karakter içeriyor (${target}) — tamper şüphesi, yeni parola üretiliyor"
        redis_pass=$(generate_password 24)
    fi

    header "Domain Onarılıyor: ${target}"

    # ─── GÜVENLİK DENETİMİ EKİ: genel başarı takibi ───
    # 'repair' birden fazla BAĞIMSIZ alt-sistemi (chroot, FPM, AppArmor,
    # DB/Redis, credentials) yeniden kurar; bunlardan biri başarısız olsa
    # bile KALAN adımlar mümkün olduğunca çalışmaya devam eder — bu KASITLI
    # (kısmi onarım, hiç onarım yapmamaktan iyidir). Ama fonksiyon SONUNDA
    # koşulsuz "✓ Domain onarıldı" basmak YANLIŞ GÜVENCE üretir — HOST'ta
    # ölçüldü (srvctl-jammy): FPM unit aktif edilemeyen (site fiilen KAPALI)
    # bir domain'de bile bu mesaj + EXIT=0 basılıyordu. 'repair_failed'
    # aşağıdaki adımlar boyunca gerçek durumu izler; fonksiyon sonunda mesaj
    # VE dönüş değeri buna göre seçilir (bkz. fonksiyon sonu).
    local repair_failed=false

    # ─── public_html / current onarımı (KARAR REVİZYONU — artık BURADA
    # ONARILIYOR, bkz. _domain_repair_fix_docroot başlık yorumu) ───
    # FPM config-test/aktivasyon adımından (2/4) ÖNCE çağrılır ki 'chdir'
    # invariant'ı düzeltilmiş olarak o adıma girilsin.
    _domain_repair_fix_docroot "$target" "$base" "$web_user"

    step "1/4" "Chroot kütüphaneleri güncelleniyor (PHP ${php_ver})..."
    _apply_chroot_php_deps "${base}" "${php_ver}"
    
    step "2/4" "PHP-FPM Pool ve AppArmor yapılandırmaları yenileniyor..."
    # ─── İZOLASYON-FARKINDA POOL HEDEFİ (BLOKE EDİCİ düzeltme — gerçek Ubuntu
    #     22.04 VM'de kanıtlandı) ───
    # ESKİDEN bu adım KOŞULSUZ paylaşılan pool.d/'ye yazıyordu. Domain
    # DOMAIN_ISOLATED_FPM=true (varsayılan) ile per-domain unit'e
    # (srvctl-fpm-<sname>.service, config: ${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/
    # <sname>.conf) geçmişse, bu koşulsuz yazım pool tanımını PAYLAŞILAN
    # master'a GERİ KOYUYORDU: aynı unix socket'i artık İKİ master (izole unit
    # + paylaşılan master) tanımlıyor; izole unit socket'i zaten bind ettiğinden
    # paylaşılan master 'status=78' (config hatası) ile ölüyor ve BİR SONRAKİ
    # 'domain add' (önce paylaşılan pool'a yazıp master'ı başlatan akış) bu
    # noktadan itibaren HER ZAMAN başarısız oluyordu (VM'de ölçülen belirti:
    # "php8.3-fpm.service failed... Main PID ... status=78").
    # 'Kullanılıyor mu' durumu META TERCİHİNE bakılarak DEĞİL (o yalnız
    # BEYANDIR — _domain_isolated_fpm_effective; migrasyon başarısız kalmış
    # olabilir) dosya sisteminin GERÇEK haline bakılarak belirlenir —
    # _domain_php_switch'teki (satır ~2551) AYNI desen.
    local php_pool_dir="${SRVCTL_PHP_POOL_DIR:-/etc/php/${php_ver}/fpm/pool.d}"
    local isolated_conf="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"
    local shared_pool="${php_pool_dir}/${sname}.conf"
    local using_isolated_fpm=false
    [[ -f "$isolated_conf" ]] && using_isolated_fpm=true

    # GÜVENLİK DENETİMİ EKİ: bu domain'in kendi işini yapmadan ÖNCE, aynı php
    # sürümünün pool.d'sindeki hayalet kalıntıları temizle — bkz.
    # _domain_fpm_purge_ghost_pools başlık yorumu. Bu, operatörün
    # 'srvctl domain repair --all' ile fleet'i PROAKTİF temizleyebilmesini
    # sağlar (bir sonraki 'domain add' bu temizliğe muhtaç kalmadan önce).
    _domain_fpm_purge_ghost_pools "$php_ver"

    if $using_isolated_fpm; then
        info "Domain izole FPM unit kullanıyor (srvctl-fpm-${sname}.service) — pool tanımı paylaşılan pool.d/'ye DEĞİL izole hedefe yazılacak"
        # Unit'i ÖNCE durdur ki render+activate ESKİ config'le çalışır kalmasın
        # (zaten aktif bir unit'te 'enable --now' no-op'tur, yeni config'i
        # YÜKLEMEZ — _domain_php_switch'teki AYNI desen).
        systemctl stop "srvctl-fpm-${sname}.service" 2>/dev/null || true
        _domain_render_fpm_unit "$target" "$php_ver"
        if _domain_activate_fpm_unit "$target"; then
            success "İzole FPM unit yenilendi: srvctl-fpm-${sname}.service"
        else
            # GÜVENLİK DENETİMİ EKİ: HOST'ta doğrulandı — bu dal başarısız
            # olduğunda '_domain_activate_fpm_unit' unit'i ZATEN disable+stop
            # etmiş durumda (fail-closed — kendi başlık yorumuna bkz.).
            # Yukarıda BİZ de repair başlamadan unit'i durdurmuştuk; yani
            # BURADAN itibaren domain'in FPM'i KESİN KAPALI ve bu 'repair'
            # çağrısı onu GERİ AÇAMADI. Eskiden bu yalnız "elle deneyin" diye
            # warn ediyordu ve fonksiyon sonunda yine de "✓ Domain onarıldı"
            # basıyordu — kullanıcı sitenin şu an tamamen KAPALI olduğunu
            # buradan ASLA öğrenemiyordu (Bulgu 1 — journalctl'de doğrulandı:
            # unit repair ÖNCESİ aktifken repair SONRASI 'inactive').
            repair_failed=true
            warn "İzole FPM unit AKTİF EDİLEMEDİ — bu domain ŞU AN KAPALI kaldı (unit durduruldu, eskisi gibi ÇALIŞMIYOR): srvctl-fpm-${sname}.service"
            warn "Elle deneyin: srvctl security harden-fpm ${target} --apply"
        fi

        # ─── Kalıntı temizliği (madde 3 — bozuk MEVCUT kurulumları onar) ───
        # Bu bug'a DAHA ÖNCE çarpmış bir sunucuda "izole unit VAR + pool.d'de
        # AYNI isimde kalıntı VAR" durumu kalmış olabilir (yukarıdaki dal bunu
        # artık ÜRETMEZ, ama GEÇMİŞTE üretilmiş olabilir). Kalıntı paylaşılan
        # master'ın socket çakışmasıyla 'status=78' ile ölmeye devam etmesine
        # yol açar — kaldırılıp master toparlanır.
        if [[ -f "$shared_pool" ]]; then
            warn "Paylaşılan pool.d'de kalıntı bulundu (${shared_pool}) — izole unit'le socket çakışması yaratıyordu, kaldırılıyor"
            rm -f -- "$shared_pool"
            if compgen -G "${php_pool_dir}/*.conf" > /dev/null 2>&1; then
                systemctl reset-failed "php${php_ver}-fpm" 2>/dev/null || true
                systemctl reload "php${php_ver}-fpm" 2>/dev/null || systemctl restart "php${php_ver}-fpm" 2>/dev/null || true
                info "Paylaşılan php${php_ver}-fpm başka domain(ler) için hâlâ havuz barındırıyor — yeniden yüklendi"
            else
                systemctl stop "php${php_ver}-fpm" 2>/dev/null || true
                systemctl disable "php${php_ver}-fpm" 2>/dev/null || true
                systemctl reset-failed "php${php_ver}-fpm" 2>/dev/null || true
                info "Paylaşılan php${php_ver}-fpm havuzsuz kaldı — durduruldu (tüm domainler izole unit'lerde)"
            fi
            log_action "domain repair: pool.d kalıntısı temizlendi (${target}) — izole unit socket çakışması onarıldı"
        fi
    else
        mkdir -p "$php_pool_dir" 2>/dev/null || true
        # Kaynak profili domain'in KENDİ meta beyanından (RESOURCE_PROFILE) okunur
        # — repair, 'domain add' anındaki '--resources=' seçimini sessizce
        # 'standard'a DÜŞÜRMEMELİ (bkz. _domain_render_fpm_unit ile AYNI desen).
        local repair_resource_profile; repair_resource_profile=$(_domain_read_resource_profile "$target")
        resource_profile_load "$repair_resource_profile"
        # BUG 2: disable_functions listesi framework'e göre türetilir (ci4'te
        # 'putenv' hariç) — bkz. _domain_disable_functions_for başlık yorumu.
        local repair_framework; repair_framework=$(_domain_read_framework "$target")
        # disable_functions gevşetmesi AÇIK beyan ister (bkz. _domain_framework_declared)
        local repair_fw_declared; repair_fw_declared=$(_domain_framework_declared "$target")
        render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
            "SAFE_NAME=${sname}" \
            "DOMAIN=${target}" \
            "WEB_USER=${web_user}" \
            "WEB_ROOT=${WEB_ROOT}" \
            "PHP_VERSION=${php_ver}" \
            "PM_MODE=${RES_PM_MODE}" "PM_MAX_CHILDREN=${RES_MAX_CHILDREN}" \
            "PM_START_SERVERS=${RES_PM_START_SERVERS}" \
            "PM_MIN_SPARE_SERVERS=${RES_PM_MIN_SPARE_SERVERS}" \
            "PM_MAX_SPARE_SERVERS=${RES_PM_MAX_SPARE_SERVERS}" \
            "MEMORY_LIMIT=${RES_MEMORY_LIMIT_MB}M" \
            "DISABLE_FUNCTIONS=$(_domain_disable_functions_for "$repair_fw_declared")" \
            > "$shared_pool"
    fi

    render_template "${SRVCTL_TEMPLATES}/apparmor/profile.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${target}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_ver}" \
        > "/etc/apparmor.d/srvctl-${sname}"
    if _domain_load_apparmor_profile "/etc/apparmor.d/srvctl-${sname}" "srvctl-${sname}"; then
        success "AppArmor (FPM) profili enforce modda: srvctl-${sname}"
    else
        warn "AppArmor (FPM) profili enforce modda DEĞİL — 'aa-status' ile kontrol edin"
    fi

    # CLI/worker profili (dar; sys_chroot/setuid capability'leri YOK — bkz.
    # profile-cli.tpl başlık yorumu). Worker/scheduler unit'leri bu profile
    # referans veriyor (AppArmorProfile=srvctl-<sname>-cli); yüklenmemişse
    # systemd 'domain worker/scheduler start' komutunu reddeder.
    render_template "${SRVCTL_TEMPLATES}/apparmor/profile-cli.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${target}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_ver}" \
        > "/etc/apparmor.d/srvctl-${sname}-cli"
    if _domain_load_apparmor_profile "/etc/apparmor.d/srvctl-${sname}-cli" "srvctl-${sname}-cli"; then
        success "AppArmor (CLI/worker) profili enforce modda: srvctl-${sname}-cli"
    else
        warn "AppArmor (CLI/worker) profili enforce modda DEĞİL — worker/scheduler başlamayabilir"
    fi

    step "3/4" "Veritabanı yetkileri, parola senkronu ve Redis ACL yenileniyor..."
    if [[ -n "$db_name" && -n "$db_user" && -n "$db_pass" ]]; then
        # CREATE USER IF NOT EXISTS mevcut kullanıcıda no-op'tur — parola ESKİ
        # kalır. ALTER USER ile HER onarımda .credentials'taki parolaya
        # idempotent senkronlanır (aksi halde eski parola kalıp yeni DB
        # grant'i ile karışır → teşhisi zor bağlantı hatası).
        mysql --force << SQL
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    fi

    # Redis ACL: TEK KAYNAK olan _domain_build_redis_acl_line ile _domain_add
    # ile BİREBİR AYNI mantıkla yeniden üretilir (iki yerde ayrışma riski yok).
    # Bu, ör. 'redis-server' yeniden kurulumu sonrası kaybolan ACL girdisinin
    # onarılmasını sağlar.
    #
    # İKİ YÖNLÜ SESSİZ DEĞİŞİM KORUMASI (kullanıcı kararı — ÖLÇÜM: repair
    # ÖNCEDEN scripting_status'u DOĞRUDAN _domain_redis_scripting_mode(major)
    # çıktısından, o ÇALIŞTIRMADAKİ sürümle SIFIRDAN hesaplıyordu — domainin
    # '.srvctl-meta'sındaki ÖNCEKİ değere HİÇ bakmıyordu. Bu, host Redis 6→7'ye
    # yükseltildiğinde (ör. resmi depo geçişiyle) HİÇBİR '--redis-queue'
    # talebi olmayan domainlerin repair çalıştığında SESSİZCE 'enabled'a
    # dönmesine yol açardı — 'domain add'deki TAM OLARAK aynı sınıf regresyon,
    # bkz. _domain_redis_queue_gate. Düzeltme: repair bir CLI bayrağı ALMAZ
    # (idempotent bakım komutu); bunun yerine domainin BU çalıştırmadan
    # ÖNCEKİ REDIS_SCRIPTING meta değeri "operatör daha önce AÇIKÇA istedi
    # mi" sinyali olarak kullanılır — önceden 'enabled' ise kalıcı bir istek
    # gibi ele alınır (sürüm hâlâ izin veriyorsa AÇIK kalır, SESSİZCE
    # KAPANMAZ); önceden 'disabled'/'unknown'/meta hiç yoksa istek YOK
    # sayılır (sürüm sonradan izin verse bile SESSİZCE AÇILMAZ).
    if [[ -n "$redis_user" && -n "$redis_pass" ]]; then
        local prev_scripting_status
        prev_scripting_status=$(_domain_read_redis_scripting_status "$target")
        local redis_queue_prev_requested=false
        [[ "$prev_scripting_status" == "enabled" ]] && redis_queue_prev_requested=true

        _sed_inplace /etc/redis/users.acl "/^user ${redis_user} /d" 2>/dev/null || true
        local redis_major="" redis_minor="" base_scripting_flag base_scripting_status channel_status
        read -r redis_major redis_minor <<< "$(_redis_version_pair)"
        read -r base_scripting_flag base_scripting_status <<< "$(_domain_redis_scripting_mode "$redis_major")"
        channel_status=$(_redis_channel_isolation_mode "$redis_major" "$redis_minor")

        local scripting_flag scripting_status redis_queue_reason
        read -r scripting_flag scripting_status redis_queue_reason <<< \
            "$(_domain_redis_queue_gate "$base_scripting_flag" "$base_scripting_status" "$redis_queue_prev_requested")"

        local acl_line
        acl_line=$(_domain_build_redis_acl_line "$redis_user" "$redis_pass" "$sname" "$scripting_flag" "$channel_status")
        echo "$acl_line" >> /etc/redis/users.acl

        local redis_admin_pass
        redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
        if [[ -n "$redis_admin_pass" ]]; then
            # GÜVENLİK DENETİMİ EKİ (BUG 3 — core.sh sahibi agent'ın bulgusu):
            # 'redis-cli', sunucudan HERHANGİ bir yanıt aldığı sürece —
            # yanıt bir HATA METNİ olsa bile — genellikle 0 ile çıkar. Çıplak
            # 'ACL LOAD ... || systemctl restart' zinciri bu yüzden ACL'in
            # CANLI kural kümesine GERÇEKTEN uygulanıp uygulanmadığını HİÇ
            # ÖLÇMÜYORDU. HOST'ta ölçüldü: 'ACL LOAD' "ERR .../users.acl:5:
            # Syntax error" ile çöktü, Redis "no change to the previously
            # active ACL rules was performed" dedi — ama repair "✓ Domain
            # onarıldı" + EXIT=0 basıyordu. Sonuç: bu domainin Redis kanal
            # izolasyonu (komşu domainin pub/sub kanalını dinlemesini/yayın
            # yapmasını ENGELLEYEN kontrol) hiç yürürlüğe girmemişti —
            # fonksiyonel testte domain A, domain B'nin kanalına hem
            # PUBLISH hem SUBSCRIBE yapabiliyordu.
            #
            # '_redis_acl_load' (core.sh, paylaşılan sarmalayıcı) hem dönüş
            # kodunu HEM çıktının TAM OLARAK 'OK' olduğunu kontrol eder;
            # başarısızlıkta Redis'in kendi teşhis metnini zaten stderr'e
            # basar. Dönüş değeri ARTIK YUTULMUYOR — bu turda repair için
            # kurulan dürüst raporlama mekanizmasına ('repair_failed')
            # bağlanıyor: ACL LOAD başarısızlığı da FPM aktivasyon
            # başarısızlığı gibi "✓ Domain onarıldı" YALANINI engeller.
            #
            # 'systemctl restart redis-server' fallback'i BİLEREK KALDIRILDI
            # (yalnız bu dalda — 'redis_admin_pass' YOKSA aşağıdaki 'else'
            # dalı hâlâ restart'a başvurur, o farklı bir senaryo): ACL LOAD
            # başarısızlığının en olası nedeni /etc/redis/users.acl'deki bir
            # SÖZDİZİMİ HATASIDIR (HOST'ta doğrulandı) — Redis, ACL dosyası
            # bozukken BAŞLAMAYI REDDEDER. Bu durumda 'restart' denemek TEK
            # domainin izolasyon eksikliğini TÜM domainlerin Redis'e hiç
            # erişememesine (Redis'in tamamen çökmesine) çevirebilirdi — bu
            # daha büyük bir hasardır. Bunun yerine operatör AÇIKÇA uyarılır.
            if ! _redis_acl_load "$redis_admin_pass"; then
                repair_failed=true
                warn "GÜVENLİK: Redis ACL bu domain için CANLI kural kümesine UYGULANMADI (${target}) — anahtar alanı VE kanal izolasyonu kontrolleri YÜRÜRLÜKTE DEĞİL, komşu domainler bu domainin Redis verilerine/pub-sub kanallarına erişebilir. Redis'in kendi hata metni yukarıda. 'systemctl restart redis-server' BİLEREK DENENMEDİ (ACL dosyası bozuksa restart TÜM domainlerin Redis'ini çökertebilir) — önce /etc/redis/users.acl'i elle inceleyip düzeltin, sonra 'srvctl domain repair ${target}' ile tekrar deneyin."
            fi
        else
            systemctl restart redis-server
        fi

        write_meta "$target" "REDIS_SCRIPTING" "$scripting_status"
        if [[ "$scripting_status" != "enabled" ]]; then
            if [[ "$prev_scripting_status" == "enabled" ]]; then
                # DÜŞÜŞ: domain daha önce AÇIKTI, artık Redis ${redis_major}
                # bunu güvenle DESTEKLEMİYOR (ör. downgrade/yeniden kurulum) —
                # fail-closed korunur ama bu SESSİZ bir kapanma DEĞİL.
                warn "Redis scripting (EVAL/Lua) bu domainde DAHA ÖNCE AÇIKTI, artık Redis ${redis_major:-bilinmiyor} bunu güvenle desteklemediği için KAPATILDI — Laravel Redis kuyruk sürücüsü/Horizon ÇALIŞMAYABİLİR."
            else
                warn "Redis scripting (EVAL/Lua) bu domainde KAPALI (${scripting_status}) — Laravel Redis kuyruk sürücüsü/Horizon ÇALIŞMAZ; QUEUE_CONNECTION=database kullanın."
            fi
        fi

        write_meta "$target" "REDIS_CHANNEL_ISOLATION" "$channel_status"
        case "$channel_status" in
            unsupported)
                warn "Redis ${redis_major}.${redis_minor} tespit edildi (6.2 altı) — pub/sub KANAL izolasyonu ACL ile YAPILAMIYOR: bu domain diğer domainlerin kanallarını görebilir/yayın yapabilir. İzolasyon için Redis'i 6.2+'a yükseltin ya da domain başına ayrı Redis instance'ı kullanın."
                ;;
            unknown)
                warn "Redis sürümü tespit edilemedi — fail-closed: pub/sub KANAL izolasyon token'ları ACL'e EKLENMEDİ (izolasyonsuz ama çalışan Redis, hiç başlamayan Redis'e tercih edildi). 'redis-cli ACL GETUSER ${redis_user}' ile doğrulayın."
                ;;
        esac
    fi

    # ─── .credentials'ı KANONİK hale getir (K3 kapanışı) ───
    # Kimlikler safe_name'den, sırlar yukarıdaki beyaz liste/regen adımından
    # sonraki GEÇERLİ değerlerden yazılır — 'repair', .credentials'ı kendi
    # kendini onaran bir dosyaya çevirir: bir sonraki çalıştırmada dosya
    # tampered değilse aynı değerler korunur, tampered ise yeniden tespit
    # edilip düzeltilir.
    _domain_write_credentials "$target" "$base" "$web_user" "$php_ver" \
        "$db_name" "$db_user" "$db_pass" \
        "$redis_user" "$redis_pass" "$redis_prefix"

    step "4/4" "PHP-FPM yeniden başlatılıyor..."
    # ─── 100 domain ölçeğinde önemli fark ───
    # ESKİDEN bu adım İZOLASYON DURUMUNDAN BAĞIMSIZ paylaşılan php${php_ver}-fpm
    # master'ını restart ediyordu — izole bir domain'in 'repair'i bile o anda
    # paylaşılan pool'da çalışan TÜM DİĞER domainleri kısa bir kesintiye
    # sokuyordu (ve zaten havuzsuzsa 'harden-fpm'in bilerek durdurduğu ölü
    # servisi anlamsızca yeniden başlatmaya çalışıyordu). İzole domain kendi
    # unit'inde adım 2/4'te zaten yenilendi; paylaşılan master'a burada
    # DOKUNULMAZ.
    if $using_isolated_fpm; then
        info "İzole FPM unit zaten yenilendi (adım 2/4) — paylaşılan php${php_ver}-fpm'e dokunulmadı (bu domain onu kullanmıyor)"
    else
        # GÜVENLİK DENETİMİ EKİ: 'restart ... || true' izole daldaki AYNI
        # fail-open sınıfıydı — paylaşılan master'ın restart'ı başarısız
        # olursa SESSİZCE yutuluyordu. Artık gerçek durum izlenir ve
        # 'repair_failed' üzerinden fonksiyon sonucuna yansır.
        if ! systemctl restart "php${php_ver}-fpm" 2>/dev/null; then
            repair_failed=true
            warn "Paylaşılan php${php_ver}-fpm yeniden BAŞLATILAMADI — bu domain (ve aynı master'ı paylaşan diğer domainler) ETKİLENMİŞ olabilir: 'systemctl status php${php_ver}-fpm' ile kontrol edin"
        fi
    fi

    # ─── GÜVENLİK DENETİMİ EKİ: dürüst sonuç raporlama ───
    # Yukarıdaki adımlardan HERHANGİ biri 'repair_failed'i true yaptıysa
    # (izole/paylaşılan FPM aktivasyonu) koşulsuz "✓ Domain onarıldı" ARTIK
    # BASILMAZ — bu tam olarak HOST'ta yakalanan fail-open bulgusuydu
    # (Bulgu 1). Fonksiyon de SIFIRDAN FARKLI döner ki '--all' dalı VE
    # doğrudan tek-domain çağrısı gerçek durumu (ve doğru exit kodunu)
    # yansıtsın.
    if $repair_failed; then
        warn "Domain KISMEN onarıldı — yukarıdaki hata(lar)a bakın: ${target}"
        return 1
    fi
    success "Domain onarıldı: ${target}"
    return 0
}


# Bir domain için HEDEF dosya-sahiplik/izin modelini (uygulamadan) yazar.
# Çıktı: "<path>|<owner>|<mode>" satırları. Saf fonksiyon — chown/chmod YOK.
# harden-fs dry-run (Task 4) ve unit-testler bunu kullanır.
# 3. argüman (framework) OPSİYONELDİR — geriye uyumluluk için varsayılan 'ci4'
# (mevcut 2-argümanlı çağıranlar — security.sh/testler — davranışı DEĞİŞMEZ).
# shared/ altındaki framework'e özgü alt dizinler burada da listelenir ki
# harden-fs (security.sh) dry-run/apply çıktısı gerçek dizin yapısıyla
# tutarlı kalsın (var olmayan yollar zaten çağıran tarafta [[ -e ]] ile atlanır).
_domain_fs_plan() {
    local base="$1" web_user="$2" framework="${3:-ci4}"
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
        "shared/.env|${web_user}|640"
    )
    case "$framework" in
        laravel)
            rows+=(
                "shared/storage|${web_user}|770"
                "shared/storage/app|${web_user}|770"
                "shared/storage/app/public|${web_user}|770"
                "shared/storage/framework|${web_user}|770"
                "shared/storage/framework/cache|${web_user}|770"
                "shared/storage/framework/sessions|${web_user}|770"
                "shared/storage/framework/views|${web_user}|770"
                "shared/storage/logs|${web_user}|770"
                "shared/bootstrap-cache|${web_user}|770"
            )
            ;;
        symfony)
            rows+=(
                "shared/var|${web_user}|770"
                "shared/var/cache|${web_user}|770"
                "shared/var/log|${web_user}|770"
            )
            ;;
        *)
            rows+=(
                "shared/writable|${web_user}|770"
                "shared/writable/cache|${web_user}|770"
                "shared/writable/logs|${web_user}|770"
                "shared/writable/session|${web_user}|770"
                "shared/writable/uploads|${web_user}|770"
            )
            ;;
    esac
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
#
# ─── _domain_fs_plan İLE İLİŞKİSİ (O7 kalıntısı — denetim DALGA 5'te
#     DEĞERLENDİRİLDİ, BİLİNÇLİ OLARAK BİRLEŞTİRİLMEDİ) ───
# İki ayrı sahiplik uygulayıcısı var: bu fonksiyon (RECURSIVE, chroot-iskelet
# odaklı, framework'ten BAĞIMSIZ) ve _domain_fs_plan (FLAT/declarative,
# framework-farkında, tek-yol-başına satır modeli — hem apply hem dry-run/
# audit'in TEK doğruluk kaynağı). Her iki çağıran (_domain_add,
# _harden_fs_apply) BU fonksiyonu ÖNCE, _domain_fs_plan döngüsünü HEMEN
# ARDINDAN çalıştırır — bu yüzden basit birleştirme (yalnız _domain_fs_plan
# satırlarını uygulamak) YANLIŞ olur, çünkü:
#   1) _domain_fs_plan satır modeli TEK bir yolu hedefler (recursive DEĞİL).
#      Chroot sistem dizinleri (dev/etc/lib/lib64/usr) İÇİNDEKİ yüzlerce
#      kopyalanmış kütüphane/binary dosyasının ayrı ayrı satır olması
#      pratik değil — bunlar yalnız BURADA 'chown -R'/'chmod -R' ile
#      toplu olarak root'a alınır.
#   2) 'private/writable/{cache,logs,session,uploads}' (chroot içinde,
#      _domain_add'in mkdir -p ile oluşturduğu) _domain_fs_plan'da HİÇ SATIR
#      OLARAK YOK — yalnız üst 'private/writable' satırı var. Bu alt
#      dizinlerin 770 moduna kavuşması TAMAMEN aşağıdaki 'chmod -R 770
#      private/writable' satırına bağlıdır; bu satır _domain_fs_plan'ın
#      ARDINDAN çalışan döngüsüyle KESİNLİKLE REDÜNDANT DEĞİLDİR — kaldırılırsa
#      bu alt dizinler mkdir'in varsayılan umask'ından kalan modda (tipik 755:
#      group/other r-x) kalır; sahiplik chown -R ile web_user olsa bile bu,
#      group/other'a gereksiz OKUMA erişimi bırakır (en-az-yetki ihlali).
#   3) Yukarıdaki public_html/private/logs/tmp/sessions üst-düzey chmod'ları
#      İSE gerçekten _domain_fs_plan'ın aynı satırlarıyla ÇAKIŞIR (idempotent
#      overlap) — BİLEREK korunuyor: bu fonksiyon _domain_fs_plan'sız TEK
#      BAŞINA çağrılsa bile (ör. ileride yeni bir çağıran eklenirse) taban
#      model uygulanmış olsun diye savunma katmanıdır, hata DEĞİLDİR.
# SONUÇ: birleştirme _domain_fs_plan'ın "satır = tek yol, recursive yok"
# sözleşmesini (dry-run/audit çıktı formatını da) değiştirmeyi gerektirir —
# bu DALGA 5 kapanış oturumunun kapsamı dışında bırakıldı; ayrı kalmaları
# BİLİNÇLİ bir tasarım kararıdır, unutulmuş bir TODO değil.
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

# Domain'in framework beyanını (.srvctl-meta) BEYAZ LİSTEDEN geçirerek oku.
# KULLANICI KARARI: framework yalnızca 'domain add --framework=' ile açıkça
# beyan edilir — otomatik tespit YOK. .srvctl-meta web-yazılabilir olduğundan
# ham FRAMEWORK değerine GÜVENİLMEZ: read_meta (core.sh) yalnız RATE_PROFILE/
# SENSITIVE_PATHS okuduğundan burada aynı sahiplik kapısı (_require_owned_or_warn,
# core.sh) elle uygulanır — hardened bir domain'de dosya root-owned değilse
# (tamper) sert hata; migrate edilmemiş eski domain'de warn+oku (read_meta ile
# birebir aynı politika). Değer whitelist'te değilse (bozuk/saldırgan) 'ci4'e
# düşülür + warn — PREDİKAT DEĞİL, normalize edilmiş framework adını yazdırır.
_domain_read_framework() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local FRAMEWORK=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" FRAMEWORK
        else
            error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
        fi
    fi
    case "${FRAMEWORK:-}" in
        ci4|laravel|symfony) echo "$FRAMEWORK" ;;
        "") echo "ci4" ;;
        *)
            warn "Geçersiz FRAMEWORK meta değeri (${domain}): '${FRAMEWORK}' — 'ci4' kullanılıyor"
            echo "ci4"
            ;;
    esac
}

# Domain'in AÇIKÇA BEYAN EDİLMİŞ framework'ünü oku — _domain_read_framework'ün
# aksine varsayılana DÜŞMEZ: beyan yoksa/geçersizse BOŞ döner.
#
# NEDEN AYRI BİR OKUYUCU VAR (güvenlik denetimi bulgusu): _domain_read_framework
# "beyan yok" ile "beyan = ci4"u AYIRT ETMEZ, ikisinde de 'ci4' döndürür. Bu
# fallback vhost/dizin yapısı için doğru (dizin şeması zaten CI4 varsayımlı),
# ama GÜVENLİK GEVŞETMESİNİ beslerse fail-open olur: _domain_disable_functions_for
# 'ci4' dalında 'putenv'i açtığından, '--framework' verilmeden eklenmiş HER
# domain ve meta'sı olmayan TÜM eski domainler sessizce 'putenv' AÇIK pool
# alırdı — oysa gevşetme yalnız gerçekten CI4 çalıştıran domainler için
# amaçlanmıştı.
#
# KURAL: bir güvenlik kontrolünü gevşeten her karar AÇIK BEYAN istemeli;
# "beyan yok / okunamadı / geçersiz" durumu HER ZAMAN sıkı tarafa düşmeli.
# Bu yüzden disable_functions kararı _domain_read_framework'ü DEĞİL bunu
# kullanır (bkz. tests/test_disable_functions_sync.sh — zinciri test eder).
_domain_framework_declared() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local FRAMEWORK=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" FRAMEWORK
        else
            error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
        fi
    fi
    case "${FRAMEWORK:-}" in
        ci4|laravel|symfony) echo "$FRAMEWORK" ;;
        *) echo "" ;;   # beyan yok / geçersiz → sıkı tarafa düş
    esac
}

# BUG 2 düzeltmesi: pool.conf.tpl'nin {{DISABLE_FUNCTIONS}} token'ını
# framework'e göre üretir. TABAN liste lib/init.sh'daki global
# 99-srvctl-security.ini ile BİREBİR AYNIDIR — TEK BİLİNÇLİ İSTİSNA:
# FRAMEWORK=ci4 domainlerde 'putenv' listeden ÇIKARILIR.
#
# KÖK NEDEN: CodeIgniter 4'ün DotEnv sınıfı (system/Config/DotEnv.php)
# .env yüklerken putenv() çağırır, alternatifi YOKTUR; 'putenv' devre dışıyken
# framework hiç boot edemiyordu ('Call to undefined function putenv()',
# HTTP 500 — CI4 appstarter deploy'unda kanıtlandı). Laravel/Symfony
# etkilenmiyor (vlucas/phpdotenv ve Symfony Dotenv putenv()'i opsiyonel/hiç
# kullanmaz) — bu yüzden istisna yalnız ci4'e ÖZGÜ, diğer TÜM framework'ler
# (ve framework beyan edilmemiş domainler) 'putenv' DAHİL sıkı listeyi alır.
#
# NEDEN İSTİSNA POOL'DA, GLOBAL'DE DEĞİL: 'disable_functions' tek yönlüdür —
# global 99-srvctl-security.ini'de listelenen fonksiyon php.ini işlenirken
# tablodan silinir ve pool'un php_admin_value'u onu GERİ AÇAMAZ, yalnızca
# listeyi UZATABİLİR. Ubuntu 22.04'te ölçüldü: pool listesinde 'putenv' YOKKEN
# bile global'de olduğu için function_exists('putenv') = false döndü. Bu yüzden
# 'putenv' global tabandan ÇIKARILDI ve sıkılaştırma buraya taşındı; böylece
# per-domain granülerlik gerçekten uygulanabiliyor.
#
# TEHDİT MODELİ (ci4'te putenv'i açık bırakmak neden düşük risk): putenv()'in
# tek başına gerçek riski putenv("LD_PRELOAD=...") ile YENİ bir process spawn
# edildiğinde ortaya çıkar (env yalnız fork+exec'te İNHERİT edilir, hâlihazırda
# çalışan process'i RETROAKTİF etkilemez). Process-spawn primitifleri (exec,
# shell_exec, system, passthru, proc_open, popen, pcntl_exec, pcntl_fork) bu
# listede FRAMEWORK FARK ETMEKSİZİN HER ZAMAN kapalı — putenv tek başına bir
# sömürü zincirini TAMAMLAYAMAZ (LD_PRELOAD'ı devreye sokacak bir spawn yolu
# yok). Bu yüzden marjinal risk düşük, CI4'ün TAMAMEN boot edememesi ise
# kritik bir fonksiyonel kırılma — güvenlik kazancı bu dar kullanım
# kaybından ağır basmıyor, dar bir istisna yeterli.
#
# ─── GÜVENLİK DENETİMİ EKİ (2. TUR — HOST ÖLÇÜMÜYLE DÜZELTİLDİ): mail-ailesi
# fonksiyonlar + LD_PRELOAD zinciri, ve asıl kesen katmanın ne olduğu ───
# Bu yorumun İLK sürümü "mail()'i disable_functions'a eklemek yeterli, çünkü
# chroot'ta zaten sendmail/sh yok, zincir zaten kırık" diyordu. HOST ölçümü
# (srvctl-jammy, Ubuntu 22.04, PHP 8.3) bunun İKİ noktada YANLIŞ/eksik
# olduğunu gösterdi — aşağıda düzeltilmiş hâli.
#
# HATA 1 — 'mail' TEK BAŞINA yeterli değil (mail-ailesi başka fonksiyonlar
# var): disable_functions yalnız LİSTELENEN Zend fonksiyon tablosu girişini
# kapatır. mbstring'in mb_send_mail()'i ve imap eklentisinin imap_mail()'i
# mail() ile AYNI dahili popen(sendmail_path) yolunu kullanır ve
# disable_functions'taki 'mail' girişinden ETKİLENMEZ (ayrı fonksiyon tablosu
# girdileri). HOST'ta doğrulandı: 'mail' disable_functions'tayken bile
# sendmail_path marker-yazan bir betiğe yönlendirildi ve
# @mb_send_mail("a@b.c","s","b") GERÇEKTEN spawn etti (argv=-t -i). Bu yüzden
# 'mb_send_mail' ve 'imap_mail' de 'mail' ile AYNI gerekçeyle (hiçbir
# framework boot'ta ihtiyaç duymaz → istisnasız) TABANA eklendi — bkz.
# aşağıdaki 'base'. imap_mail eklentisi bugün kurulu olmasa da eklendi:
# disable_functions'a var olmayan bir fonksiyon adı yazmak PHP'yi hataya
# düşürmez (php -d ile doğrulandı — ini işlenirken yalnızca fonksiyon
# tabloda BULUNURSA silinir, bulunamazsa sessizce yok sayılır); yani operatör
# ileride 'php-imap' kurarsa liste SESSİZCE delinmez.
#
# HATA 2 — DAHA ÖNEMLİSİ, "chroot boşluğu zinciri kapatıyor" savunması TEK
# BAŞINA GÜVENİLMEZ: HOST mutasyon testi canlı ci4.local chroot'una elle bir
# /bin/sh (dash) VE /usr/sbin/sendmail YERLEŞTİRDİ, sonra web üzerinden bir
# spawn tetikleyici (error_log($m,1,...) — aşağıya bkz.) çağrıldı. Spawn YİNE
# olmadı; auditd sebebi:
#   apparmor="DENIED" operation="exec" profile="srvctl-ci4_local"
#   name="/var/www/ci4.local/bin/sh" requested_mask="x" denied_mask="x"
# Yani zinciri fiilen kesen katman chroot'un BOŞLUĞU DEĞİL, AppArmor
# profilinin exec İZİN VERMEMESİDİR (web kökü altındaki hiçbir yola 'x' izni
# yok — templates/apparmor/*, bu görevin kapsamı DIŞI). Chroot boşluğu
# İKİNCİL/ek bir katman: chroot İÇERİĞİNİ deploy/build adımları
# yazabildiğinden (bkz. lib/deploy.sh, kapsam dışı) TEK BAŞINA dayanılacak
# bir kontrol DEĞİLDİR — "chroot boş, o yüzden güvenli" varsayımı YANLIŞ
# GÜVENCE üretir.
#
# SONUÇ — bu fonksiyonun ürettiği disable_functions listesi BEST-EFFORT'TUR,
# TEK/YETERLİ KATMAN DEĞİL: yalnız BİLİNEN "mail ailesi" PHP fonksiyonlarını
# (mail, mb_send_mail, imap_mail) kapatabilir. Asıl/güvenilir kontrol
# AppArmor'ın exec deny'i ve — ondan bağımsız, ikincil bir katman olarak —
# chroot'un fiilen boş tutulmasıdır. PAYLAŞILAN pool'daki (AppArmor attach
# EDİLMEYEN — bkz. _domain_isolated_fpm_effective) domainlerde bu liste
# pratikte TEK giriş engelidir; framework istisnası olmadan GENİŞ tutulması
# bu yüzden daha da önemli.
#
# error_log KASITLI OLARAK EKLENMEDİ — KAPATILAMAYAN KALICI BİR DELİK:
# error_log($msg, 1, $to) (message_type=1) AYNI dahili sendmail yolunu
# kullanır ve HOST'ta doğrulandı: 'mail' disable_functions'tayken bile
# GERÇEKTEN spawn etti (error_log kendi popen çağrısını mail()/
# mb_send_mail()'in disable durumuna BAKMADAN yapar — ayrı bir C-seviyesi
# çağrı yolu). error_log ise Laravel/CI4/Monolog'un TEMEL hata loglama
# altyapısına gömülüdür; disable_functions'a eklemek framework'ü ÇALIŞAMAZ
# hale getirir (fonksiyonel kırılma, kabul edilemez). BU YÜZDEN
# error_log disable_functions'a EKLENMEDİ ve EKLENMEMELİDİR — bir sonraki
# okuyucu "tutarlılık" adına eklemeye kalkışmasın. Bu satırın anlamı:
# disable_functions'ın 'mail ailesi' kapsamı error_log'u KAPSAMAZ; error_log
# üzerinden AYNI sınıf (popen→/bin/sh→LD_PRELOAD) spawn PAYLAŞILAN pool'da
# (AppArmor'sız) teorik olarak HÂLÂ mümkündür — bunu durduran TEK katman
# yine AppArmor exec deny'idir (yukarıdaki HATA 2). php_admin_value
# [sendmail_path] override'ı da bunu ÇÖZMEZ: popen() glibc içinde HER
# ZAMAN '/bin/sh -c "<komut>"' exec eder — sendmail_path yalnız <komut>
# dizesini değiştirir, /bin/sh'in KENDİSİNİN exec edilmesini ENGELLEMEZ; bu
# yüzden sendmail_path override'ı BİLİNÇLİ OLARAK EKLENMEDİ (gerçek koruma
# yine exec'i reddeden AppArmor'dur, komut dizesini kısıtlamak değil).
_domain_disable_functions_for() {
    local framework="$1"
    # TABAN: lib/init.sh:99-srvctl-security.ini'deki disable_functions satırıyla
    # BİREBİR AYNI olmalı ('putenv' ikisinde de YOK; 'mail'/'mb_send_mail'/
    # 'imap_mail' ikisinde de VAR; 'error_log' İKİSİNDE DE YOK — kasıtlı,
    # yukarı bkz.). Sapmayı tests/test_disable_functions_sync.sh yakalar.
    local base="exec,passthru,shell_exec,system,proc_open,popen,proc_close,proc_get_status,proc_nice,proc_terminate,pcntl_alarm,pcntl_exec,pcntl_fork,pcntl_get_last_error,pcntl_getpriority,pcntl_setpriority,pcntl_signal,pcntl_signal_dispatch,pcntl_strerror,pcntl_wait,pcntl_waitpid,pcntl_wexitstatus,pcntl_wifexited,pcntl_wifsignaled,pcntl_wifstopped,pcntl_wstopsig,pcntl_wtermsig,dl,show_source,highlight_file,mail,mb_send_mail,imap_mail"
    if [[ "$framework" == "ci4" ]]; then
        echo "$base"
    else
        echo "${base},putenv"
    fi
}

# Domain'in kaynak (cgroups/FPM pool) profili beyanını (.srvctl-meta)
# whitelist'ten geçirerek oku. _domain_read_framework İLE AYNI KAPI/DESEN
# (core.sh read_meta yalnız RATE_PROFILE/SENSITIVE_PATHS bilir) — .srvctl-meta
# web-yazılabilir olduğundan ham RESOURCE_PROFILE değerine GÜVENİLMEZ;
# resource_profile_resolve (core.sh, conf/resource-profiles.conf'a karşı)
# ile doğrulanır, tanınmayan/boş değer 'standard'a düşer. Hardened bir
# domain'de dosya root-owned değilse (tamper) sert hata — bu fonksiyon
# yalnız OPERATÖR tarafından çağrılan çalışma-zamanı komutlarında
# (_domain_resources, _domain_render_fpm_unit) kullanılır; 'domain add'
# İÇİNDE KULLANILMAZ (add zaten CLI'dan gelen doğrulanmış değeri elinde
# tutar — bkz. _domain_capacity_read_profile, KAPASİTE taraması için ayrı
# ve YUMUŞAK/warn-only bir kopya kullanır, başka bir domainin tamper'ı BU
# domain add'i asla engellememeli).
_domain_read_resource_profile() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local RESOURCE_PROFILE=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" RESOURCE_PROFILE
        else
            error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
        fi
    fi
    resource_profile_resolve "${RESOURCE_PROFILE:-standard}"
}

# _domain_read_resource_profile'ın YUMUŞAK kopyası — yalnız kapasite
# planlayıcı (_domain_capacity_check) TÜM domainleri tararken kullanır.
# Tamper durumunda 'error' ile EXIT ETMEZ (yalnız warn + 'standard'a düşer):
# kapasite tahmini bir GÜVENLİK SINIRI değildir (config/unit'e akmaz, salt
# bilgi amaçlı toplam gösterir) — BAŞKA bir domainin tampered meta'sı, o an
# eklenmekte olan YENİ domainin 'domain add' akışını ASLA engellememeli.
_domain_capacity_read_profile() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local RESOURCE_PROFILE=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" RESOURCE_PROFILE
        else
            warn "Kapasite tahmini: ${domain} meta dosyası root-owned değil (tamper şüphesi) — 'standard' varsayılıyor"
        fi
    fi
    resource_profile_resolve "${RESOURCE_PROFILE:-standard}"
}

# DOMAIN_ISOLATED_FPM efektif değerini döndürür (stdout: "true"|"false").
# Öncelik: .srvctl-meta ISOLATED_FPM > global DOMAIN_ISOLATED_FPM
# (conf/srvctl.conf, core.sh load_config zaten validate_bool ile doğruladı).
#
# DÜZELTME (HOST'ta ölçüldü, Ubuntu 22.04, dört domain): '.srvctl-meta'
# WEB-YAZILABİLİR DEĞİLDİR — bu yorumun önceki sürümü ("web-yazılabilir →
# validate_bool ile doğrulanır") yanlıştı. Gerçek sahiplik/izin: dosya
# root:root 644, üst dizin (${WEB_ROOT}/<domain>) root:root 751 (T1/
# _domain_apply_fs_ownership — 'domain add' anında doğuştan hardened).
# Gerçek tamper denemesiyle doğrulandı: domain'in KENDİ web kullanıcısı
# olarak ('sudo -u web_ci4_local bash -c "echo TAMPER=1 >>
# .../.srvctl-meta"') PERMISSION DENIED alındı — ne dosyanın kendisi
# değiştirilebiliyor ne de üst dizin 751 (o+x, o-w) olduğundan yerine yeni
# bir dosya konulabiliyor. Yani bu ISOLATED_FPM override'ı için tehdit
# modeli "düşman-kontrollü web kullanıcısı" DEĞİLDİR — bu vektör zaten
# dosya-sistemi izinleriyle KAPALI.
#
# 'validate_bool' NEDEN HÂLÂ VAR (yanlış gerekçe düzeltildi, kontrolün
# kendisi KALDIRILMADI): bu, adversarial girdiye karşı değil, OPERATÖRÜN
# ELLE DÜZENLEMESİNDEKİ YAZIM HATALARINA karşı bir korumadır (ör.
# 'ISOLATED_FPM=Yes' ya da 'ISOLATED_FPM=1' — yalnız 'true'/'false'
# bekleniyor). Bu meşru ve korunması gereken bir savunma katmanıdır.
#
# Aşağıdaki '_require_owned_or_warn' çağrısı AYRI bir katmandır ve bu
# yüzden KALDIRILMADI: henüz T1 sahiplik modeline geçmemiş/hardened
# OLMAYAN (ör. eski/migrate edilmemiş) bir domainde meta'nın GERÇEKTEN
# web-yazılabilir kalabileceği residual senaryoya karşı savunma-derinliği
# sağlıyor — normal/hardened bir domainde (yukarıdaki ölçüm) bu dal zaten
# tetiklenmiyor (ownership her zaman root).
#
# Meta değeri eksik/geçersizse SESSİZCE global değere düşülür — hatalı/
# yanlış yazılmış bir meta satırı varsayılanı ASLA override edemez
# (fail-closed: bkz. rapor — lib/security.sh:_meta_known_keys
# whitelist'ine ISOLATED_FPM eklenmesi gerekir, o dosya bu görevin
# kapsamı dışında).
_domain_isolated_fpm_effective() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local ISOLATED_FPM=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" ISOLATED_FPM
        else
            warn "Güvenlik: ${meta_file} root-owned değil (tamper) — ISOLATED_FPM override YOK SAYILIYOR, global değer kullanılıyor"
        fi
    fi
    if [[ -n "$ISOLATED_FPM" ]] && validate_bool "$ISOLATED_FPM"; then
        echo "$ISOLATED_FPM"
    else
        [[ -n "$ISOLATED_FPM" ]] && warn "Geçersiz ISOLATED_FPM meta değeri (${domain}): '${ISOLATED_FPM}' — global değer (${DOMAIN_ISOLATED_FPM}) kullanılıyor"
        echo "${DOMAIN_ISOLATED_FPM}"
    fi
}

# ─── Per-domain FPM izolasyonuna OTOMATİK GEÇİŞ (Faz 2/T7a — Seçenek C) ───
# 'domain add' sonunda çağrılır. Migrasyon mantığı BURADA KOPYALANMAZ:
# lib/security.sh:_harden_fpm_apply zaten fail-closed davranışı sağlıyor
# (eski paylaşılan pool'u yedekler, yeni unit aktifleşmezse GERİ YÜKLER —
# bkz. o fonksiyonun başlık yorumu). '_load_and_run' (bin/srvctl) YALNIZ
# dispatch edilen TEK modülü source ettiğinden (bkz. CLAUDE.md) burada
# AÇIKÇA + GUARD'LI 'source' edilir — eksik/bozuk security.sh domain add'i
# ÖLDÜRMEMELİ, yalnız izolasyonu atlayıp uyarmalı.
# KRİTİK SÖZLEŞME: bu fonksiyon HİÇBİR KOŞULDA 'error' ile exit ETMEZ —
# dönüş değeri her zaman 0'dır; migrasyon başarısızlığı 'domain add'in
# genel başarısını ASLA etkilemez (çağıran taraf bu invariantı 'trap - EXIT'
# SONRASI çağırarak da garanti eder — bkz. _domain_add).
_domain_migrate_to_isolated_fpm() {
    local domain="$1"
    local effective; effective=$(_domain_isolated_fpm_effective "$domain")
    [[ "$effective" == "true" ]] || return 0

    # shellcheck disable=SC1091
    source "${SRVCTL_ROOT}/lib/security.sh" 2>/dev/null || {
        warn "lib/security.sh yüklenemedi — per-domain FPM izolasyonu ATLANDI (${domain}). Elle deneyin: srvctl security harden-fpm ${domain} --apply"
        return 0
    }
    if ! declare -F _harden_fpm_apply >/dev/null 2>&1; then
        warn "_harden_fpm_apply bulunamadı — per-domain FPM izolasyonu ATLANDI (${domain})"
        return 0
    fi

    info "Per-domain FPM izolasyonuna geçiliyor (DOMAIN_ISOLATED_FPM=true)..."
    if _harden_fpm_apply "$domain"; then
        success "Domain per-domain FPM unit'e taşındı: srvctl-fpm-$(safe_name "$domain")"
    else
        warn "Per-domain FPM izolasyonu BAŞARISIZ — domain PAYLAŞILAN pool'da çalışmaya devam ediyor: ${domain}"
        warn "Elle deneyin: srvctl security harden-fpm ${domain} --apply"
    fi
    return 0
}

# ─── Kapasite planlayıcı (100 domain hedefi) ───
# 'domain add' ÖNCESİ toplam taahhüdü fiziksel RAM ile karşılaştırır ve
# aşarsa UYARIR — ENGELLEMEZ (overcommit meşru bir operatör tercihidir,
# cgroups zaten MemoryMax ile HER domaini ayrı ayrı sınırlar) ama SESSİZ
# KALMAZ. Ölçülen gerçek sabit (bkz. rapor — Ubuntu 24.04 gerçek VM):
# DOMAIN_ISOLATED_FPM=true iken her per-domain FPM master'ı ~35 MB KALICI
# RSS ekler — bu, cgroups MemoryMax'ten (worker havuzunun TEPE talebi)
# BAĞIMSIZ, master sürecinin KENDİ sabit yüküdür.
_SRVCTL_FPM_MASTER_RSS_MB=35

_domain_capacity_check() {
    local new_profile="$1"

    # Test-seam: _domain_resources'taki SRVCTL_SYSTEMD_DIR ile aynı desen.
    # Yol sabitken eşik/uyarı mantığı YALNIZ gerçek Linux'ta test edilebiliyordu
    # (macOS'ta fonksiyon erken return 0 yapıp sessizce atlanıyordu). Üretimde
    # davranış değişmez — varsayılan hâlâ /proc/meminfo.
    local meminfo="${SRVCTL_MEMINFO:-/proc/meminfo}"
    [[ -r "$meminfo" ]] || return 0
    local mem_total_kb
    mem_total_kb=$(grep -m1 '^MemTotal:' "$meminfo" 2>/dev/null | awk '{print $2}')
    validate_uint "${mem_total_kb:-}" || return 0
    local mem_total_mb=$(( mem_total_kb / 1024 ))

    resource_profile_load "$new_profile"
    local total_commit_mb=$RES_MEMORY_MAX_MB
    local domain_count=1
    local d prof
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        prof=$(_domain_capacity_read_profile "$d")
        resource_profile_load "$prof"
        total_commit_mb=$(( total_commit_mb + RES_MEMORY_MAX_MB ))
        domain_count=$(( domain_count + 1 ))
    done < <(list_all_domains)

    # Per-domain FPM master RSS'i yalnız izolasyon fiilen AÇIKSA kalıcı ek yüktür.
    local master_overhead_mb=0
    if [[ "${DOMAIN_ISOLATED_FPM}" == "true" ]]; then
        master_overhead_mb=$(( domain_count * _SRVCTL_FPM_MASTER_RSS_MB ))
    fi
    local grand_total_mb=$(( total_commit_mb + master_overhead_mb ))

    if (( grand_total_mb > mem_total_mb )); then
        warn "Kapasite uyarısı: bu ekleme dahil ${domain_count} domain, profil bazlı MemoryMax taahhüdü ~${total_commit_mb}MB"
        if [[ "${DOMAIN_ISOLATED_FPM}" == "true" ]]; then
            warn "  + per-domain FPM master kalıcı yükü: ${domain_count} × ${_SRVCTL_FPM_MASTER_RSS_MB}MB ≈ ${master_overhead_mb}MB"
        fi
        warn "  Toplam taahhüt ~${grand_total_mb}MB, fiziksel RAM ${mem_total_mb}MB'yi AŞIYOR (overcommit)"
        warn "  Öneri: bu domain için daha düşük profil (--resources=micro|standard) seçin ya da RAM artırın"
    else
        info "Kapasite: ${domain_count} domain, taahhüt ~${grand_total_mb}MB / fiziksel RAM ${mem_total_mb}MB"
    fi
}

# ─── Render sonrası leftover-token guard'ı (DALGA 5 — BLOKE EDİCİ kapanışı) ───
# render_template (core.sh) beslenmeyen bir token'ı SESSİZCE atlar ve literal
# '{{TOKEN}}' metnini ÇIKTIDA BIRAKIR (hata YOK) — bu sınıf boşluk bu
# oturumda ÜÇÜNCÜ kez tekrarlandı (önce DENY_DIRS, sonra IO_WEIGHT, şimdi
# DOMAIN_ROOT — bkz. rapor). Her render-yazan fonksiyon YAZDIĞI DOSYAYI bu
# guard'dan geçirir. PREDİKAT DEĞİL: literal '{{' bulursa dosyayı SİLER
# (bozuk unit/config — ör. geçersiz bir yola işaret eden ReadWritePaths=
# — canlı sistemde kalıcı kalmasın) ve 'error' ile EXIT eder (fail-closed;
# bir sonraki adım — systemctl daemon-reload/nginx reload — bu bozuk
# dosyayla ASLA çalışmamalı). Dosya yoksa (render zaten başarısız olup
# 'error' ile çıkmışsa) sessizce 0 döner.
_domain_assert_no_leftover_tokens() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if grep -q '{{' "$file" 2>/dev/null; then
        local leftover
        leftover=$(grep -oE '\{\{[A-Z_]+\}\}' "$file" 2>/dev/null | sort -u | tr '\n' ' ')
        rm -f -- "$file"
        error "Şablon render hatası: ${file} içinde beslenmeyen token kaldı (${leftover:-'{{...}}'}) — güvenlik için dosya silindi, işlem durduruldu."
    fi
    return 0
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

    # ─── DENY_DIRS: framework beyanına göre seçilir (ops-infra sözleşmesi) ───
    # GENİŞ (CI4/legacy, docroot=repo kökü): app/system/vendor/... docroot
    # İÇİNDE ve gerçekten tehlikelidir — bu yüzden CI4 ve bilinmeyen/varsayılan
    # durum için GENİŞ liste kullanılır (güvenli taraf). NOT: modern public/
    # tabanlı bir CI4 layout'u da mümkündür ama vhost yalnız 'domain add'
    # anında bir kez render edilir; bu ayrımı 'deploy' zamanında yeniden render
    # ederek keskinleştirmek deploy-specialist'in işidir (bkz. rapor).
    # DAR (Laravel/Symfony, docroot=public/): 'storage' ve 'vendor' MEŞRU genel
    # alt dizinlerdir (storage:link → public/storage; public/vendor/livewire/
    # livewire.js gibi Livewire/Filament asset'leri) — geniş liste bunları
    # 404'lerdi, bu yüzden ikisi DAR listeden çıkarılmıştır.
    local deny_dirs_wide='app|system|vendor|modules|writable|private|tests|node_modules|\.composer|storage|bootstrap|config|database|routes|resources|var'
    local deny_dirs_narrow='app|system|modules|writable|private|tests|node_modules|\.composer|bootstrap|config|database|routes|resources|var'
    local framework; framework=$(_domain_read_framework "$domain")
    local deny_dirs="$deny_dirs_wide"
    [[ "$framework" == "laravel" || "$framework" == "symfony" ]] && deny_dirs="$deny_dirs_narrow"
    # Savunma katmanı: hardcoded sabitler bile render'a gitmeden önce nginx
    # regex charset'ine karşı doğrulanır (gelecekte bu değerler meta/override
    # ile genişletilirse sessizce bozuk config üretilmesin).
    if ! assert_regex_safe "$deny_dirs"; then
        warn "DENY_DIRS güvenli karakter setine uymuyor (${domain}) — geniş liste kullanılıyor"
        deny_dirs="$deny_dirs_wide"
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
        "DENY_DIRS=${deny_dirs}" \
        > "${sites}/${domain}.conf"
    _domain_assert_no_leftover_tokens "${sites}/${domain}.conf"
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
    local fpm_conf="${fpm_dir}/${sname}.conf"
    local unit_file="${sysd_dir}/srvctl-fpm-${sname}.service"

    # ─── Kaynak profili (GÖREV 2 — ops-infra sözleşmesi) ───
    # Domain'in KENDİ meta beyanından (RESOURCE_PROFILE) okunur — harden-fpm
    # migrasyonu 'domain add' anındaki '--resources=' seçimini KORUMALI,
    # sessizce 'standard'a düşürmemeli. PM_MODE/PM_MAX_CHILDREN/
    # PM_START_SERVERS/PM_MIN_SPARE_SERVERS/PM_MAX_SPARE_SERVERS/
    # MEMORY_LIMIT token adları pool.conf.tpl'nin kendi TOKENS beyanıyla
    # (ops-infra) BİREBİR eşleşir. pm.process_idle_timeout TOKEN DEĞİL —
    # pool.conf.tpl içine sabit '10s' olarak gömülü, buradan BESLENMEZ.
    local resource_profile; resource_profile=$(_domain_read_resource_profile "$domain")
    resource_profile_load "$resource_profile"
    # BUG 2: disable_functions listesi framework'e göre türetilir (ci4'te
    # 'putenv' hariç) — bkz. _domain_disable_functions_for başlık yorumu.
    # .srvctl-meta henüz yazılmamışsa (ör. birim testleri) 'ci4' varsayılanına
    # düşer — _domain_read_framework'ün kendi güvenli fallback'i.
    local unit_framework; unit_framework=$(_domain_read_framework "$domain")
    # disable_functions gevşetmesi AÇIK beyan ister (bkz. _domain_framework_declared)
    local unit_fw_declared; unit_fw_declared=$(_domain_framework_declared "$domain")

    # config = [global] + pool (pool.conf.tpl TEK kaynak, kopyalanmaz)
    {
        render_template "${SRVCTL_TEMPLATES}/php-fpm/fpm-global.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}"
        render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}" \
            "PHP_VERSION=${php_version}" "WEB_USER=${web_user}" \
            "PM_MODE=${RES_PM_MODE}" "PM_MAX_CHILDREN=${RES_MAX_CHILDREN}" \
            "PM_START_SERVERS=${RES_PM_START_SERVERS}" \
            "PM_MIN_SPARE_SERVERS=${RES_PM_MIN_SPARE_SERVERS}" \
            "PM_MAX_SPARE_SERVERS=${RES_PM_MAX_SPARE_SERVERS}" \
            "MEMORY_LIMIT=${RES_MEMORY_LIMIT_MB}M" \
            "DISABLE_FUNCTIONS=$(_domain_disable_functions_for "$unit_fw_declared")"
    } > "$fpm_conf"
    _domain_assert_no_leftover_tokens "$fpm_conf"
    render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-fpm.service.tpl" \
        "DOMAIN=${domain}" "SAFE_NAME=${sname}" "PHP_VERSION=${php_version}" \
        > "$unit_file"
    _domain_assert_no_leftover_tokens "$unit_file"
}

# Render edilmiş per-domain FPM unit'ini ETKİNLEŞTİRİR (systemctl — [HOST]).
# PREDİKAT: 0=unit gerçekten aktif, 1=değil. Çağıran (harden-fpm) 1'de eski
# shared pool'u SİLMEMELİ — fail-closed. Başarısızlıkta unit durdurulup
# disable edilir ki systemd Restart=on-failure ile döngüye girmesin.
_domain_activate_fpm_unit() {
    local domain="$1"
    local sname; sname=$(safe_name "$domain")
    local unit="srvctl-fpm-${sname}.service"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local fpm_dir="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}"
    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")

    [[ -f "${sysd_dir}/${unit}" ]] \
        || { warn "Unit dosyası yok: ${sysd_dir}/${unit}"; return 1; }
    [[ -f "${fpm_dir}/${sname}.conf" ]] \
        || { warn "FPM config yok: ${fpm_dir}/${sname}.conf"; return 1; }

    # 1. Config sözdizimi kontrolü — systemd'yi bozuk config'le uğraştırma.
    #
    # GÜVENLİK DENETİMİ EKİ (HOST'ta ölçüldü, srvctl-jammy): eskiden bu test
    # '>/dev/null 2>&1' ile TÜM çıktıyı (php-fpm'in kendi ERROR satırlarını
    # DAHİL) yutuyor, kullanıcıya yalnız "FPM config testi başarısız" diyordu.
    # Gerçek bir kırık deploy'da (releases/ boş, public_html/current hedefi
    # silinmiş symlink) php-fpm'in asıl hatası şuydu:
    #   ERROR: [pool <sname>] the chdir path '/public_html' within the
    #          chroot path '<WEB_ROOT>/<domain>' (...) does not exist or is
    #          not a directory
    # — bu satır doğrudan çözüme (kırık symlink) götürüyor, ama önceki
    # kod BUNU YUTUYORDU; operatör kök nedeni yalnız php-fpm'i ELLE
    # çalıştırarak bulabiliyordu. Artık gerçek stdout+stderr YAKALANIP
    # (girintili) kullanıcıya gösteriliyor — _domain_load_apparmor_profile'daki
    # 'parser_err' deseniyle AYNI.
    local fpm_bin="/usr/sbin/php-fpm${php_version}"
    if [[ -x "$fpm_bin" ]]; then
        local fpm_test_err
        if ! fpm_test_err=$("$fpm_bin" --fpm-config "${fpm_dir}/${sname}.conf" -t 2>&1); then
            warn "FPM config testi başarısız: ${fpm_dir}/${sname}.conf"
            [[ -n "$fpm_test_err" ]] && echo "$fpm_test_err" | sed 's/^/    /' >&2
            return 1
        fi
    else
        warn "php-fpm binary yok: ${fpm_bin} — config testi atlandı"
    fi

    # 2. AppArmor profili yüklü mü? Unit'teki AppArmorProfile= yüklü olmayan bir
    #    profile işaret ederse systemd start'ı reddeder; önceden söyle.
    if command -v aa-status &>/dev/null; then
        aa-status 2>/dev/null | grep -q "srvctl-${sname}" \
            || warn "AppArmor profili yüklü değil: srvctl-${sname} (unit başlamayabilir)"
    fi

    # 3. Etkinleştir
    systemctl daemon-reload 2>/dev/null \
        || { warn "systemctl daemon-reload başarısız"; return 1; }

    if ! systemctl enable --now "$unit" >/dev/null 2>&1; then
        warn "Unit başlatılamadı: ${unit}"
        systemctl status "$unit" --no-pager -l 2>/dev/null | tail -20 >&2 || true
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        # GÜVENLİK DENETİMİ EKİ: yukarıdaki 'disable --now' bu unit'i FİİLEN
        # durdurup devre dışı bırakıyor — çağıran taraf (_domain_repair vb.)
        # bunu yalnız "elle deneyin" diye warn edip sanki hafif bir aksaklıkmış
        # gibi geçiştirebiliyordu. Kullanıcı burada AÇIKÇA bilsin: bu domain
        # şu an FPM'siz kaldı.
        warn "SONUÇ: ${unit} DURDURULDU/devre dışı bırakıldı — bu domain'in PHP-FPM'i şu an ÇALIŞMIYOR"
        return 1
    fi

    # 4. Fail-closed teyit: enable başarılı dönse de gerçekten aktif mi?
    if ! systemctl is-active --quiet "$unit"; then
        warn "Unit aktif değil: ${unit}"
        systemctl status "$unit" --no-pager -l 2>/dev/null | tail -20 >&2 || true
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        warn "SONUÇ: ${unit} DURDURULDU/devre dışı bırakıldı — bu domain'in PHP-FPM'i şu an ÇALIŞMIYOR"
        return 1
    fi

    success "Per-domain FPM unit aktif: ${unit}"
    return 0
}

# Sihirbaz: girdileri toplar, WIZ_* global değişkenlerine yazar. İptalde 1 döner.
_domain_wizard_collect() {
    WIZ_DOMAIN=""; WIZ_PHP=""; WIZ_PROFILE=""; WIZ_SSL="evet"; WIZ_SENSITIVE=""; WIZ_FRAMEWORK="ci4"
    local domain php_version profile ssl_ans sensitive framework

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

    # 6. Framework (KULLANICI KARARI: açık beyan, otomatik tespit YOK — bkz. CLAUDE.md).
    # Belirlenen değer shared/ iskeletini, vhost DENY_DIRS'ini ve worker/
    # scheduler komut varsayılanlarını etkiler.
    while :; do
        read -rp "  Framework [ci4/laravel/symfony] (varsayılan: ci4): " framework
        framework="${framework:-ci4}"
        case "$framework" in
            ci4|laravel|symfony) break ;;
            *) warn "Geçersiz framework: ${framework} (ci4|laravel|symfony)" ;;
        esac
    done

    # Özet
    divider
    echo "  Domain:    ${domain}"
    echo "  PHP:       ${php_version}"
    echo "  Profil:    ${profile}"
    echo "  SSL:       ${ssl_ans}"
    echo "  Hassas:    ${sensitive}"
    echo "  Framework: ${framework}"
    divider

    WIZ_DOMAIN="$domain"; WIZ_PHP="$php_version"; WIZ_PROFILE="$profile"
    WIZ_SSL="$ssl_ans"; WIZ_SENSITIVE="$sensitive"; WIZ_FRAMEWORK="$framework"

    confirm "Bu ayarlarla devam edilsin mi?" || return 1
    return 0
}

# Sihirbaz: girdi toplar ve _domain_add'i kurulu argümanlarla çağırır.
_domain_add_wizard() {
    header "Yeni Domain — İnteraktif Kurulum"
    _domain_wizard_collect || { info "İptal edildi."; return 1; }

    local args=("$WIZ_DOMAIN" "--php=${WIZ_PHP}" "--rate=${WIZ_PROFILE}" "--sensitive=${WIZ_SENSITIVE}" "--framework=${WIZ_FRAMEWORK}")
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

# ─── shared/.env iskeleti (framework'e göre DB/Redis kimlikleri önceden dolu) ───
# db-redis-specialist (DALGA 1) sözleşmesi: REDIS_PREFIX değeri her zaman
# '<safe_name>:' biçimindedir.
#   - Laravel: config/database.php doğrudan env('REDIS_PREFIX') okur — ek kod
#     gerekmez, .env'e REDIS_PREFIX=<değer> yazmak yeterlidir.
#   - CI4: TEK bir 'redis.prefix' anahtarı YOKTUR — iki ayrı yerde ayarlanır:
#     cache.prefix = <değer> VE (Redis session kullanılıyorsa)
#     App\Config\Session::$savePath bir DSN'dir → 'tcp://127.0.0.1:6379?prefix=<değer>'.
#   - Symfony: KRİTİK UYUMSUZLUK — RedisAdapter ad alanını (namespace) MD5 HASH
#     olarak üretir, literal '<sname>:' ile BAŞLAMAZ; Redis ACL'i '~<sname>:*'
#     ile kısıtlı olduğundan cache NOPERM ile patlar. cache.prefix.seed YETMEZ
#     (yine hash türetir). Çözüm: adapter'a LİTERAL namespace geçirmek ya da
#     phpredis'te Redis::OPT_PREFIX kullanmak — aşağıdaki .env'de yorum olarak
#     örneklenir.
# GÜVENLİK: .env zaten VARSA üzerine YAZILMAZ (operatörün elle girdiği değerler
# kaybolmasın). Sahiplik/izin: web_user:web_user 640 (root:root DEĞİL — PHP-FPM
# chroot içinde aynı web_user olarak çalışır ve dosyayı okuyabilmelidir).
# NOT: generate_password/openssl çıktısı yalnızca [A-Za-z0-9+/=] setinden gelir
# (bkz. core.sh generate_password '/+=\n' filtresi) — heredoc'ta değişken
# genişlemesi güvenlidir; yalnız yorum içindeki PHP '$' işaretleri '\$' ile
# literal tutulur (aksi halde shell bunları değişken sanıp boşaltırdı).
_domain_write_env_skeleton() {
    local domain="$1" base="$2" web_user="$3" framework="$4"
    local db_name="$5" db_user="$6" db_pass="$7"
    local redis_user="$8" redis_pass="$9" redis_prefix="${10}"
    local env_file="${base}/shared/.env"

    if [[ -e "$env_file" ]]; then
        info "shared/.env zaten mevcut — dokunulmadı: ${env_file}"
        return 0
    fi

    # ─── H3 DÜZELTMESİ (denetim DALGA 4) ───
    # İçerik yazılmadan ÖNCE dosya 0600 root:root ile ÖN-OLUŞTURULUR
    # (_domain_write_credentials ile BİREBİR aynı desen). Eskiden aşağıdaki
    # 'cat > "$env_file"' YENİ dosyayı varsayılan umask ile (tipik 0644
    # root:root) oluşturuyordu ve dosya BU HALİYLE — herkes tarafından
    # okunabilir — birkaç adım sonraki 'chown/chmod 640' satırına kadar
    # kalıyordu; o pencerede BAŞKA bir domainin web_user'ı DB_PASSWORD/APP_KEY
    # gibi sırları okuyabilirdi. secure_file hedef modu (600) umask'tan
    # BAĞIMSIZ chmod ile garanti eder; aşağıdaki '(umask 077; cat > ...)'
    # sarmalaması ise bu adım ile secure_file arasında dosyanın silinip
    # yeniden oluşturulması (TOCTOU) ihtimaline karşı ek savunma katmanıdır.
    secure_file "$env_file" 600

    case "$framework" in
        laravel)
            local app_key; app_key="base64:$(openssl rand -base64 32)"
            ( umask 077; cat > "$env_file" << ENVEOF
# srvctl tarafından üretildi — ${domain} (framework: laravel)
# DİKKAT: bu dosya secrets içerir — web_user:${web_user} 640.
APP_NAME="${domain}"
APP_ENV=production
APP_DEBUG=false
APP_KEY=${app_key}
APP_URL=https://${domain}

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${db_name}
DB_USERNAME=${db_user}
DB_PASSWORD=${db_pass}

# Laravel'in config/database.php'si REDIS_PREFIX'i env('REDIS_PREFIX') ile
# doğrudan okur — ek kod GEREKMEZ (db-redis-specialist sözleşmesi).
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_USERNAME=${redis_user}
REDIS_PASSWORD=${redis_pass}
REDIS_PREFIX=${redis_prefix}

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
ENVEOF
            )
            ;;
        symfony)
            local app_secret; app_secret=$(openssl rand -hex 16)
            ( umask 077; cat > "$env_file" << ENVEOF
# srvctl tarafından üretildi — ${domain} (framework: symfony)
# DİKKAT: bu dosya secrets içerir — web_user:${web_user} 640.
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=${app_secret}

DATABASE_URL="mysql://${db_user}:${db_pass}@127.0.0.1:3306/${db_name}?serverVersion=8.0.32&charset=utf8mb4"

# ─── KRİTİK: Symfony RedisAdapter ad alanı (namespace) UYUMSUZLUĞU ───
# Symfony\\Component\\Cache\\Adapter\\RedisAdapter/RedisTagAwareAdapter
# namespace'i VARSAYILAN olarak MD5 HASH'tir (adapter sınıf adından türetilir);
# literal '${redis_prefix}' ile BAŞLAMAZ. Redis ACL'i '~${redis_prefix}*' ile
# kısıtlı olduğundan cache TAMAMEN NOPERM ile patlar. 'cache.prefix.seed' bu
# sorunu ÇÖZMEZ (o da yalnız hash'in TOHUMUNU değiştirir — üretilen ad yine
# hash'tir, '${redis_prefix}' ile başlamaz). Yalnızca yorumla uyarmak
# YETERSİZDİR eğer havuz gerçekten bu şekilde tanımlanmazsa — bu .env'i
# srvctl yazar ama config/packages/cache.yaml UYGULAMA KODUNA aittir; bu
# yüzden burada GERÇEKTEN ÇALIŞAN, doğrudan kopyalanabilir resmi Symfony
# mekanizması (framework.cache.pools.<ad>.namespace) veriliyor — deploy
# sırasında geliştirici/deploy-specialist bunu app koduna eklemelidir:
#   # config/packages/cache.yaml
#   framework:
#       cache:
#           default_redis_provider: '%env(REDIS_URL)%'
#           pools:
#               cache.app:
#                   adapter: cache.adapter.redis
#                   namespace: '%env(REDIS_PREFIX)%'   # <-- LİTERAL prefix, hash DEĞİL
# Cache bileşeni dışında (ör. doğrudan phpredis kullanan özel kod) için
# alternatif:
#   \$redis->setOption(Redis::OPT_PREFIX, getenv('REDIS_PREFIX'));
REDIS_URL="redis://${redis_user}:${redis_pass}@127.0.0.1:6379"
REDIS_PREFIX=${redis_prefix}
ENVEOF
            )
            ;;
        *)
            ( umask 077; cat > "$env_file" << ENVEOF
# srvctl tarafından üretildi — ${domain} (framework: ci4)
# DİKKAT: bu dosya secrets içerir — web_user:${web_user} 640.
CI_ENVIRONMENT = production

database.default.hostname = 127.0.0.1
database.default.database = ${db_name}
database.default.username = ${db_user}
database.default.password = ${db_pass}
database.default.DBDriver = MySQLi
database.default.port = 3306

# CI4'te TEK bir 'redis.prefix' anahtarı YOKTUR — iki ayrı yerde ayarlanır:
cache.prefix = ${redis_prefix}
# Redis SESSION kullanılıyorsa (App\\Config\\Session içinde
# \$driver = RedisHandler::class) \$savePath bir DSN'dir; DSN üzerinden
# ayarlamak için aşağıdaki satırı açın (varsayılan: FileHandler, KAPALI):
# session.savePath = 'tcp://127.0.0.1:6379?auth[user]=${redis_user}&auth[pass]=${redis_pass}&prefix=${redis_prefix}'
ENVEOF
            )
            ;;
    esac

    chown "${web_user}:${web_user}" "$env_file" 2>/dev/null || true
    chmod 640 "$env_file"
    success "shared/.env iskeleti oluşturuldu (framework: ${framework})"
}

# ─── Redis EVAL/Lua (scripting) ACL kararı — SÜRÜM KOŞULLU (lider/kullanıcı kararı) ───
# GEREKÇE: Redis 7+'ta bir Lua script içinden yapılan redis.call() çağrıları
# ÇAĞIRAN KULLANICININ ACL'ine (key pattern kısıtı dahil) tabidir — bu yüzden
# scripting AÇIK bırakılabilir; kiracı izolasyonu Redis 7'de zaten korunur ve
# Laravel'in Redis kuyruk sürücüsü (RedisQueue/LuaScripts) ve atomik cache
# kilitleri (RedisLock::release) çalışmaya devam eder. Redis <7'de bu garanti
# YOKTUR (script içi anahtar erişiminin her zaman ACL'e tabi tutulduğu garanti
# değildir) — scripting kapalı kalır ve operatöre QUEUE_CONNECTION=database
# uyarısı verilir. Sürüm tespit edilemezse FAIL-CLOSED: kısıtlı taraf seçilir.
# .claude/ubuntu-compat.md kuralı "yetenek tespiti > çıplak sürüm karşılaştırması"
# der; burada davranış farkı ('Lua script'in ACL'e tabi olması) bir "komut/paket
# var mı" sorusu değil, çalışma zamanı semantiği olduğundan yetenekle tespit
# edilemiyor — sürüm okuması burada meşru istisnadır.

# NOT (kapsam genişletmesi): '_redis_version_pair' ve '_redis_major_version'
# (redis-server/redis-cli sürüm tespiti) artık BURADA DEĞİL, lib/core.sh'ta
# tanımlı. Neden: lib/init.sh (sunucu-geneli admin/default Redis ACL
# kullanıcıları, bkz. _install_redis) de AYNI sürüm tespitine ihtiyaç
# duyuyor ve '_load_and_run' (bin/srvctl) YALNIZ dispatch edilen TEK modülü
# source ettiğinden domain.sh'ta kalsalardı init.sh'tan çağrısı "command not
# found" (127) verirdi — resource_profile_*/rate_profile_* İLE AYNI gerekçeyle
# core.sh (her modülde her zaman mevcut) doğru ev. domain.sh BURADAN sonra
# bu iki fonksiyonu core.sh'un genel sözleşmesinden (her zaman ilk source
# edilir) KULLANMAYA DEVAM EDER; çağrı yerleri DEĞİŞMEDİ.

# Saf karar fonksiyonu (macOS'ta argüman enjeksiyonuyla unit-test edilebilir,
# gerçek redis-server gerekmez): major sürüm girdisine göre ACL scripting
# bayrağını ve operatöre/meta'ya yazılacak durum kodunu üretir.
# Çıktı: "<acl_bayrağı> <durum_kodu>" (durum_kodu: enabled|disabled|unknown)
_domain_redis_scripting_mode() {
    local major="$1"
    if [[ "$major" =~ ^[0-9]+$ ]]; then
        if (( major >= 7 )); then
            echo "+@scripting enabled"
        else
            echo "-@scripting disabled"
        fi
    else
        echo "-@scripting unknown"
    fi
}

# '--redis-queue' (ya da 'domain repair'de eşdeğeri — bkz. aşağıdaki NOT)
# bayrağının nihai ACL/meta KARARINI üreten SAF fonksiyon. İKİ AYRI SORUYU
# BİLİNÇLİ OLARAK AYRI TUTAR (birinin gerekçesi TEKNİK, diğerininki POLİTİKA
# — birbirine KARIŞTIRILMAZ):
#   1) YETENEK (teknik): bu Redis sürümü scripting'i GÜVENLE sunabilir mi?
#      → _domain_redis_scripting_mode(major) yanıtlar. BU FONKSİYON O
#        FONKSİYONUN DAVRANIŞINI DEĞİŞTİRMEZ/TEKRAR HESAPLAMAZ — onun
#        ürettiği 'base_flag'/'base_status' (enabled|disabled|unknown) İKİ
#        GİRDİDEN biri olarak AYNEN alınır.
#   2) TALEP (politika): operatör bunu AÇIKÇA istedi mi (--redis-queue)?
#      → 'requested' parametresiyle temsil edilir.
# NİHAİ KARAR = YETENEK **VE** TALEP — ikisi de 'evet' olmadıkça scripting
# KAPALI kalır. KRİTİK: Redis sürümü scripting'i GÜVENLE destekse BİLE
# (major>=7, base_status=enabled), TALEP yoksa (requested != true) sonuç
# YİNE disabled'dır — sürüm YÜKSELTMESİ (ör. Ubuntu 22.04'te Redis'in resmi
# depodan 7.x'e taşınması) HİÇBİR domain'i, operatörün bilinçli bir
# '--redis-queue' talebi OLMADAN, sessizce 'enabled'a ÇEVİREMEZ. Kullanıcı
# "framework=laravel gibi dolaylı bir ipuncundan otomatik açma" seçeneğini
# AÇIKÇA reddetti; sürüm-tabanlı otomatik açma da AYNI sınıfa girer
# (operatörün bilinçli tercihi olmadan güvenlik yüzeyinin genişlemesi).
#
# GÜVENLİK GEREKÇESİ (TALEP olsa BİLE Redis <7'de scripting'i ZORLA AÇAMAZ):
# '+@scripting'in ACL anahtar-deseni (~<sname>:*) kısıtlamasını Lua script
# İÇİNDE de garanti altına alması Redis 7'DEN ÖNCE garanti değildir (bkz.
# yukarıdaki _domain_redis_scripting_mode notu). Bu garantisiz durumda
# scripting'i zorla açmak, komşu bir domainin Redis anahtar alanına EVAL ile
# erişilebilmesi — yani kiracı İZOLASYONUNUN KIRILMASI — anlamına gelir; bu
# yüzden TALEP tek başına YETERSİZDİR, YETENEK de ZORUNLUDUR.
#
# NOT ('domain repair' için 'requested' KAYNAĞI): repair bir CLI bayrağı
# ALMAZ (idempotent bir bakım komutudur) — bunun yerine domainin '.srvctl-
# meta'sındaki (BU çalıştırmadan ÖNCEKİ) REDIS_SCRIPTING değeri "operatör
# daha önce AÇIKÇA istedi mi" sinyali olarak kullanılır: önceden 'enabled'
# ise kalıcı bir istek gibi ele alınır (bkz. _domain_repair çağrı sitesi).
#
# Girdi: base_flag/base_status (_domain_redis_scripting_mode çıktısı),
#        requested ("true" ise açık talep VAR demektir)
# Çıktı: "<nihai_acl_bayrağı> <nihai_durum_kodu> <sebep_kodu>"
#   nihai_durum_kodu: enabled|disabled|unknown (meta'ya YAZILACAK gerçek değer)
#   sebep_kodu (yalnız MESAJLAŞMA için, karara DAHİL DEĞİL):
#     default          : talep yok — sonuç HER ZAMAN disabled/unknown'dır
#                        (yetenek 'enabled' olsa BİLE talep yoksa düşürülür).
#     requested        : talep VAR ve yetenek de VAR → onaylandı, açıldı.
#     rejected_version : talep VAR ama yetenek YOK (Redis <7/tespit
#                        edilemedi) → reddedildi, fail-closed korunur.
_domain_redis_queue_gate() {
    local base_flag="$1" base_status="$2" requested="${3:-false}"
    if [[ "$requested" != "true" ]]; then
        if [[ "$base_status" == "enabled" ]]; then
            # KRİTİK: yetenek VAR (Redis 7+) ama talep YOK — otomatik AÇILMAZ.
            echo "-@scripting disabled default"
        else
            # Zaten kısıtlıydı (disabled/unknown) — davranış DEĞİŞMEDİ.
            echo "${base_flag} ${base_status} default"
        fi
        return 0
    fi
    if [[ "$base_status" == "enabled" ]]; then
        echo "${base_flag} enabled requested"
    else
        echo "${base_flag} ${base_status} rejected_version"
    fi
}

# NOT (kapsam genişletmesi): 'Redis kanal (pub/sub) izolasyonu ACL kararı'
# saf fonksiyonu da ('_domain_redis_channel_isolation_mode' idi) artık BURADA
# DEĞİL, lib/core.sh'ta '_redis_channel_isolation_mode(major, minor)' adıyla
# tanımlı — aynı çapraz-modül gerekçesi (lib/init.sh:_install_redis, sunucu-
# geneli admin/default ACL kullanıcıları için AYNI karara ihtiyaç duyuyor).
# Kaynak referanslı GEREKÇE (Redis 6.2.0'da eklenen 'resetchannels'/
# '&pattern'/'allchannels' token'larının 6.0.x'te parser'da HİÇ TANIMLI
# olmaması, ACL "Syntax error"ı ve Ubuntu 22.04=6.0.16 / 24.04=7.0.15 paket
# eşlemesi) core.sh'taki tanımın başlık yorumunda BİREBİR KORUNDU.

# Redis ACL kullanıcı satırını üretir — TEK KAYNAK: hem _domain_add hem
# _domain_repair bunu çağırır, ACL mantığının iki yerde ayrışması/birbirinden
# kopması riski kalmaz. Saf string üretici — redis-cli/redis-server ÇAĞIRMAZ,
# dosya YAZMAZ, macOS'ta unit-test edilebilir.
# 5. argüman (channel_status) OPSİYONELDİR, varsayılan 'unsupported' —
# verilmezse/tanınmazsa FAIL-CLOSED (kanal token'ları eklenmez); yalnız tam
# olarak 'supported' değeriyle 'resetchannels &<sname>:*' satıra eklenir.
# Değer core.sh:_redis_channel_isolation_mode'dan gelir (bkz. yukarıdaki not).
# Redis 6.0'da bu token'lar sözdizimi hatasına yol açtığından (yukarıdaki
# gerekçe) burada KOŞULSUZ eklemek YERİNE sürüm bilgisine bağlanmıştır.
_domain_build_redis_acl_line() {
    local redis_user="$1" redis_pass="$2" sname="$3" scripting_flag="$4"
    local channel_status="${5:-unsupported}"
    local line="user ${redis_user} on >${redis_pass} ~${sname}:*"
    if [[ "$channel_status" == "supported" ]]; then
        line+=" resetchannels &${sname}:*"
    fi
    line+=" +@all -@dangerous ${scripting_flag} +INFO -CONFIG -DEBUG -KEYS -SCAN -RANDOMKEY -FLUSHALL -FLUSHDB -SHUTDOWN"
    printf '%s' "$line"
}

# Domain'in Redis EVAL/Lua (scripting) durumunu (.srvctl-meta) BEYAZ LİSTEDEN
# geçirerek okur — sahiplik/tamper politikası _domain_read_framework ile
# birebir aynıdır (core.sh'un read_meta'sı yalnız RATE_PROFILE/SENSITIVE_PATHS
# okur; whitelist'i genişletmek core.sh'a dokunmayı gerektirirdi — bunun
# yerine aynı desen, read_kv_file + _require_owned_or_warn, burada tekrarlanır).
# 'unknown': ya meta hiç yazılmamış (eski domain — 'srvctl domain repair'
# çalıştırılınca yazılır) ya da değer whitelist dışı.
_domain_read_redis_scripting_status() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local REDIS_SCRIPTING=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" REDIS_SCRIPTING
        else
            error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
        fi
    fi
    case "${REDIS_SCRIPTING:-}" in
        enabled|disabled) echo "$REDIS_SCRIPTING" ;;
        *) echo "unknown" ;;
    esac
}

# Domain'in Redis pub/sub KANAL İZOLASYONU durumunu (.srvctl-meta) BEYAZ
# LİSTEDEN geçirerek okur — desen _domain_read_redis_scripting_status ile
# birebir aynıdır (aynı gerekçe: core.sh'un read_meta'sı bu anahtarı
# tanımıyor). 'unknown': meta hiç yazılmamış (eski domain — 'srvctl domain
# repair' ile yazılır) ya da değer whitelist dışı.
_domain_read_redis_channel_status() {
    local domain="$1"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    local REDIS_CHANNEL_ISOLATION=""
    if [[ -f "$meta_file" ]]; then
        if _require_owned_or_warn "$domain" "$meta_file"; then
            read_kv_file "$meta_file" REDIS_CHANNEL_ISOLATION
        else
            error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
        fi
    fi
    case "${REDIS_CHANNEL_ISOLATION:-}" in
        supported|unsupported) echo "$REDIS_CHANNEL_ISOLATION" ;;
        *) echo "unknown" ;;
    esac
}

# ─── Paylaşılan php-fpm'e dayanıklı reload/restart (GÜVENLİK DENETİMİ EKİ) ───
# HOST bulgusu: bu adım eskiden ÇIPLAK 'systemctl restart' çağrısıydı —
# hatası BASTIRILMAMIŞTI, 'set -e' altında TÜM 'domain add'i düşürüyordu
# (rollback tetiklenip kısmi kaynaklar düzgün temizleniyordu, ama ekleme
# HİÇ TAMAMLANAMIYORDU — geri alma mekanizması sağlıklı olsa bile, "hiç
# eklenemeyen domain" 100-domain hedefine giden yolda kabul edilemez).
#
# ÖLÇÜM — paylaşılan servise dokunmak DOMAIN_ISOLATED_FPM=true (varsayılan)
# durumunda bile GEREKSİZ DEĞİLDİR: lib/security.sh:_harden_fpm_apply'ın
# kendi başlık yorumu tam tersini varsayıyor ("Geri dönüş: 'domain add'
# paylaşılan havuza yeni bir pool yazdığında 'systemctl reload || systemctl
# restart' zincirini kullanır; restart durmuş/disable servisi yeniden
# ayağa kaldırır"). Yani: bir önceki migrasyon paylaşılan servisi BİLEREK
# durdurup devre dışı bırakmış olabilir (havuzsuz kalınca — bkz.
# _harden_fpm_apply); bu domain'in BİRAZDAN yazdığı geçici pool'un
# GERÇEKTEN yüklenmesi (yalnız diskte durması değil) için servisin şu an
# ÇALIŞIYOR olması gerekir — hem izole migrasyon başarısız olursa fallback
# olarak (bkz. _domain_migrate_to_isolated_fpm), hem de
# DOMAIN_ISOLATED_FPM=false ise KALICI üretim mekanizması olarak. Bu
# yüzden adım TAMAMEN ATLANMIYOR — üç somut sorunu çözecek şekilde
# DAYANIKLI hale getirildi:
#   1) Servis 'failed'/rate-limited durumdaysa çıplak 'restart' da
#      başarısız olurdu ("start request repeated too quickly") —
#      'reset-failed' şimdi restart'tan ÖNCE deneniyor.
#   2) Servis 'inactive' ise 'reload'un "Unit cannot be reloaded because it
#      is inactive" hatası NORMAL bir durumdur, hata değil — zaten
#      '|| restart' zincirine düşülüyor, ekstra dallanma gerekmiyor.
#   3) BAŞARISIZLIK ARTIK 'domain add'i ÖLDÜRMÜYOR: bu adım yalnız bir
#      ARA/bootstrap adımdır (fonksiyon SONUNDA çağrılan
#      _domain_migrate_to_isolated_fpm — trap temizlendikten SONRA, yani
#      domain add'in genel başarısını ASLA etkilemez — bu domain'i
#      birazdan izole unit'e taşıyacaktır).
#
# Kendi fonksiyonuna ÇIKARILDI (test edilebilirlik — _domain_activate_fpm_unit
# ile AYNI desen): çağıran taraf ('if ... ; then success ... ; fi') bir
# bare/unguarded çağrı DEĞİL, bu yüzden 'set -e' altında başarısızlık
# fonksiyonu/'domain add'i DÜŞÜRMEZ (bkz. CLAUDE.md/proje kuralı — koşul
# bağlamı 'set -e'den muaftır).
# PREDİKAT: 0=servis reload/restart ile ayakta (ya da zaten öyleydi), 1=değil
# (başarısızlıkta kendi içinde warn+log_action yapar; ÇAĞIRAN bunu ASLA
# fatal saymaz — yalnız _domain_add'in bu adımı, bkz. çağrı yeri).
_domain_add_bootstrap_shared_fpm() {
    local php_version="$1" domain="$2"
    if systemctl reload "php${php_version}-fpm" 2>/dev/null; then
        return 0
    fi
    systemctl reset-failed "php${php_version}-fpm" 2>/dev/null || true
    if systemctl restart "php${php_version}-fpm" 2>/dev/null; then
        return 0
    fi
    warn "Paylaşılan php${php_version}-fpm yeniden başlatılamadı (${domain}) — bu yalnız GEÇİCİ bir bootstrap adımıdır: domain birazdan izole FPM unit'ine taşınacak (DOMAIN_ISOLATED_FPM=${DOMAIN_ISOLATED_FPM}, bkz. _domain_migrate_to_isolated_fpm). İzolasyon da başarısız olursa domain paylaşılan pool'da ÇALIŞMAZ kalabilir — 'systemctl status php${php_version}-fpm' ile inceleyip 'srvctl domain repair ${domain}' ile tekrar deneyin."
    log_action "domain add: paylaşılan php${php_version}-fpm reload/restart başarısız (${domain}) — izole FPM migrasyonuna güveniliyor"
    return 1
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
    # KULLANICI KARARI: framework yalnızca açık --framework= beyanıyla
    # belirlenir — otomatik tespit YOK. Belirtilmezse 'ci4' (mevcut dizin
    # yapısı zaten CI4 varsayımlıydı — geriye uyumlu varsayılan).
    local framework="ci4"
    # AÇIK BEYAN İZİ: '--framework=' GERÇEKTEN verildi mi? $framework tek
    # başına bunu söyleyemez (varsayılanı da 'ci4'). disable_functions
    # gevşetmesi bu ize bakar — bkz. _domain_framework_declared.
    local framework_declared=""
    # GÖREV 2: kaynak (cgroups/FPM pool) profili — resource_profile_load
    # deseninin CLI kapısı (rate_profile ile AYNI YUMUŞAK desen: tanınmayan
    # değer sessizce 'standard'a düşer + warn, hard error DEĞİL).
    local resource_profile="standard"
    # KULLANICI KARARI: Redis EVAL/Lua (scripting) — Laravel Redis kuyruk
    # sürücüsü/Horizon'un ihtiyaç duyduğu özellik — VARSAYILAN OLARAK KAPALI
    # kalır ve bu HER ZAMAN GEÇERLİDİR: Redis sürümü bunu güvenle destekliyor
    # olsa BİLE (>=7), '--redis-queue' verilmedikçe scripting AÇILMAZ (bkz.
    # _domain_redis_queue_gate — yetenek VE talep birlikte gerekir; sürüm
    # yükseltmesi TEK BAŞINA hiçbir domain'i sessizce açamaz). '--redis-queue'
    # bunu AÇIKÇA istemenin TEK yoludur; framework=laravel gibi dolaylı bir
    # ipucundan OTOMATİK türetilmez (operatör bilinçli bir güvenlik ödünü
    # vermeli). Nihai karar (ACL flag'i/meta) Redis sürüm YETENEĞİYLE
    # BİRLEŞTİRİLİR, bkz. _domain_redis_queue_gate.
    local redis_queue_requested=false

    # Argümanları parse et
    for arg in "$@"; do
        case "$arg" in
            --php=*)       php_version="${arg#--php=}" ;;
            --rate=*)      rate_profile="${arg#--rate=}" ;;
            --sensitive=*) sensitive_paths="${arg#--sensitive=}" ;;
            --framework=*) framework="${arg#--framework=}"; framework_declared="$framework" ;;
            --resources=*) resource_profile="${arg#--resources=}" ;;
            --no-ssl)      do_ssl=false ;;
            --redis-queue) redis_queue_requested=true ;;
            -*) warn "Bilinmeyen seçenek: ${arg}" ;;
            *) domain="$arg" ;;
        esac
    done

    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain add example.com [--php=8.3] [--rate=standard] [--framework=ci4|laravel|symfony] [--resources=micro|standard|ecommerce|heavy] [--redis-queue]"
    _domain_add_validate_gate "$domain" || error "Geçersiz domain adı: ${domain}"
    domain_exists "$domain" && error "Domain zaten mevcut: ${domain}"
    php_version_exists "$php_version" || error "PHP ${php_version} kurulu değil. Önce kurun."
    rate_profile="$(rate_profile_resolve "$rate_profile")"
    resource_profile="$(resource_profile_resolve "$resource_profile")"
    # --framework BEYAZ LİSTE: CLI girdisi (meta'dan farklı olarak) doğrudan
    # kullanıcı tarafından verilir ama yine de serbest bırakılmaz — geçersiz
    # değer sessizce 'ci4'e düşmez, açıkça reddedilir (kullanıcı hatası erken yakalanır).
    case "$framework" in
        ci4|laravel|symfony) : ;;
        *) error "Geçersiz --framework değeri: ${framework} (ci4|laravel|symfony)" ;;
    esac

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

    # ─── B3 DÜZELTMESİ (denetim DALGA 4 — BLOKE EDİCİ) ───
    # Rollback'in DROP DATABASE / certbot delete çağırıp ÇAĞIRMAYACAĞINI
    # belirlemek için bu ÇALIŞTIRMADAN ÖNCE DB/sertifikanın zaten var olup
    # olmadığı KAYDEDİLİR. Senaryo: '/var/www/${domain}' yok ama 'db_${sname}'
    # (ör. yedekten 'zcat | mysql' ile ELLE geri yüklenmiş) VAR; 'domain add'
    # adım 8'de 'CREATE DATABASE IF NOT EXISTS' bu DB'ye DOKUNMAZ ama sonraki
    # bir adım (ör. redis restart) başarısız olup rollback tetiklenirse eski
    # kod KOŞULSUZ 'DROP DATABASE' çalıştırıyordu — geri yüklenmiş üretim
    # verisi yok oluyordu. Aynı sınıf: certbot sertifikayı bu çalıştırmada hiç
    # ALMAMIŞ olsa bile 'certbot delete' onu silerdi. Bayraklar rollback
    # kapanışında (bkz. _domain_add_rollback) kontrol edilir; bu ÇALIŞTIRMADA
    # gerçekten OLUŞTURULMAYAN kaynaklara rollback ASLA dokunmaz.
    local _db_preexisted=0
    if mysql -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${db_name}';" 2>/dev/null \
        | grep -qx -- "${db_name}"; then
        _db_preexisted=1
    fi
    local _cert_preexisted=0
    [[ -d "/etc/letsencrypt/live/${domain}" ]] && _cert_preexisted=1

    # ─── GÖREV 3: kapasite planlayıcı — ENGELLEMEZ, sadece uyarır ───
    _domain_capacity_check "$resource_profile"

    header "Yeni Domain: ${domain}"

    # ─── Rollback güvenlik ağı (yarım kalmış domain önleme) ───
    # _domain_add ORTASINDA bir adım başarısız olursa ('error' exit eder ya da
    # 'set -e' guard'sız bir komutta tetiklenirse) geride yarım kalmış kaynaklar
    # (linux user, dizin ağacı, chroot kütüphaneleri, FPM pool, vhost) kalırdı;
    # domain_exists artık true döner ama .credentials YOKTUR — sonraki
    # 'domain add' "zaten mevcut" der, 'domain remove' ise eksik .credentials
    # ile çalışır. EXIT trap'i (bash'te dinamik scope sayesinde bu fonksiyonun
    # local'lerini görebilir) süreç sonlanırken geri-alma zincirini tetikler;
    # BAŞARI yolunda en sonda 'trap - EXIT' ile temizlenir. Guard zinciri
    # (_deploy_prune'daki desenle aynı fikir): boş değişken kontrolü, base'in
    # gerçekten WEB_ROOT/domain'e eşit olduğu kontrolü, symlink reddi — var
    # olmayan kaynak sessizce atlanır, WEB_ROOT dışına asla taşılmaz.
    _DOMAIN_ADD_ROLLBACK_DONE=0
    _domain_add_rollback() {
        [[ "${_DOMAIN_ADD_ROLLBACK_DONE:-0}" == "1" ]] && return 0
        _DOMAIN_ADD_ROLLBACK_DONE=1
        warn "Domain add tamamlanamadı — kısmi kaynaklar geri alınıyor: ${domain}"

        [[ -n "${domain:-}" ]] || return 0
        [[ -n "${base:-}" && "$base" == "${WEB_ROOT}/${domain}" ]] || return 0
        [[ -n "${sname:-}" ]] || return 0

        # H2 DÜZELTMESİ (denetim DALGA 5): tüm sunucu-tarafı kaynak temizliği
        # artık TEK KAYNAK olan _domain_purge_resources'ta — bkz. o fonksiyonun
        # başlık yorumu (eskiden bu closure ile _domain_remove'un kendi kopyası
        # ayrışmıştı; _domain_remove worker/scheduler/per-domain-FPM-unit/
        # state-dir'i HİÇ BİLMİYORDU).
        _domain_purge_resources "$domain" "${php_version:-}" "${_db_preexisted:-0}" "${_cert_preexisted:-0}"

        log_action "DOMAIN ADD ROLLBACK: ${domain}"
        warn "Kısmi kaynaklar geri alındı: ${domain}"
    }
    # M8 DÜZELTMESİ: yalnız EXIT değil, INT/TERM için de trap kurulur.
    # 'trap ... EXIT' TEK BAŞINA Ctrl-C/SIGTERM'de çalışacağını GARANTİ ETMEZ
    # (certbot/apt gibi bir alt-süreç sinyali yutabilir ya da script INT/TERM
    # sonrası varsayılan olarak KALDIĞI yerden devam edebilir — bash sinyal
    # trap'ı çağırdıktan SONRA script'i kendiliğinden sonlandırmaz). Burada
    # INT/TERM handler'ları rollback'i çalıştırdıktan SONRA açıkça 'exit' eder
    # (geleneksel 128+sinyal kodlarıyla); '_domain_add_rollback' idempotent
    # olduğundan (bkz. _DOMAIN_ADD_ROLLBACK_DONE guard) ardından tetiklenen
    # EXIT trap'i no-op'tur.
    trap _domain_add_rollback EXIT
    trap '_domain_add_rollback; exit 130' INT
    trap '_domain_add_rollback; exit 143' TERM

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

    # ─── shared/ iskeleti: framework beyanına göre (deploy.sh her release'de
    # bu dizinleri release köküne symlink/bind eder). shared/.env de burada
    # (framework'e göre DB/Redis kimlikleri önceden dolu) üretilir — deploy
    # anında '.env bulunamadı' uyarısıyla geçilip Laravel/Symfony'nin 500 ile
    # patlaması (encryption key/APP_SECRET eksik) önlenir.
    case "$framework" in
        laravel)
            mkdir -p "${base}/shared/storage"/{app/public,framework/{cache,sessions,views},logs}
            mkdir -p "${base}/shared/bootstrap-cache"
            ;;
        symfony)
            mkdir -p "${base}/shared/var"/{cache,log}
            ;;
        *)
            mkdir -p "${base}/shared/writable"/{cache,logs,session,uploads}
            ;;
    esac

    # Chroot için gerekli dizinler
    mkdir -p "${base}"/{dev,etc,lib,lib64}
    mkdir -p "${base}/usr"/{lib,share/zoneinfo}
    mkdir -p "${base}/etc/ssl/certs"

    # İzinler — Yeni sahiplik modeli (T1, RC1): base root:root 751, leaf'ler web_user.
    # NOT: eski 'chmod o-rwx' + 'setfacl o::---' KALDIRILDI — base artık root:root ve
    # web_user "other" olarak o+x (traverse) iznine ihtiyaç duyar; www-data da öyle.
    _domain_apply_fs_ownership "${base}" "${web_user}"

    # ─── O7 DÜZELTMESİ (denetim DALGA 4) ───
    # '_domain_apply_fs_ownership' yalnız T1/RC1'in İSKELET izinlerini
    # uyguluyordu — 'releases'/'shared'ın KENDİSİ (750) ve framework'e özgü
    # shared alt dizinleri (ör. Laravel 'shared/storage/*' → 770) EKSİK
    # kalıyordu; 'mkdir -p' bunları varsayılan umask ile 755 bırakır. Aşağıdaki
    # marker'ın HEMEN yazılması bu domaini "hardened" ilan ediyordu ama plan
    # TAM uygulanmadan — base 751 (o+x) olduğundan tam yolu bilen KOMŞU bir
    # kiracı 'shared/' içine traverse edip 755 dizini listeleyebilir ve 644
    # varsayılan izinli dosyaları okuyabilirdi. _domain_fs_plan (harden-fs'in
    # de TEK doğruluk kaynağı) burada da uygulanır; marker ANCAK bundan SONRA
    # yazılır — "hardened" artık gerçekten TAMAMLANMIŞ bir plan anlamına gelir.
    while IFS='|' read -r _plan_path _plan_owner _plan_mode; do
        [[ -e "$_plan_path" ]] || continue
        if [[ "$_plan_owner" == "root" ]]; then
            chown root:root "$_plan_path" 2>/dev/null || true
        else
            chown "${_plan_owner}:${_plan_owner}" "$_plan_path" 2>/dev/null || true
        fi
        chmod "$_plan_mode" "$_plan_path" 2>/dev/null || true
    done < <(_domain_fs_plan "${base}" "${web_user}" "${framework}")

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
    step "${current}/${total}" "PHP-FPM pool (chroot jail, kaynak profili: ${resource_profile})..."

    # GÖREV 2: kaynak profili buradan itibaren PM_* token'larını besler
    # (RES_* değişkenleri resource_profile_load ile doldu — bkz. yukarısı).
    resource_profile_load "$resource_profile"
    # BUG 2: disable_functions listesi framework'e göre türetilir (ci4'te
    # 'putenv' hariç) — bkz. _domain_disable_functions_for başlık yorumu.
    # '$framework' burada zaten CLI'dan (--framework=) çözülmüş durumda
    # (write_meta ile .srvctl-meta'ya yazılması AŞAĞIDA gerçekleşir).

    # GÜVENLİK DENETİMİ EKİ (ikinci dereceden hasar — bkz.
    # _domain_fpm_purge_ghost_pools başlık yorumu): render'dan ÖNCE aynı php
    # sürümünün pool.d'sindeki hayalet kalıntılar temizlenir. HOST'ta
    # ölçüldü: önceki (hayalet-tespitinden ÖNCEKİ) bir 'repair --all'ın
    # bıraktığı 'user = web_html' (var olmayan kullanıcı) içeren bir
    # 'pool.d/html.conf' TEK BAŞINA paylaşılan php-fpm servisinin hiç
    # başlamamasına yol açıyordu — bu da aşağıdaki reload/restart'ı
    # (dolayısıyla TÜM 'domain add'i) bloke ediyordu. Kaynağı kapatan
    # hayalet-tespiti (bkz. _domain_repair_is_ghost) YENİ kalıntı üretilmesini
    # önlüyor ama ZATEN var olan kalıntıyı temizlemiyordu; bu çağrı BİR
    # SONRAKİ domain add'in aynı tuzağa düşmesini engeller.
    _domain_fpm_purge_ghost_pools "$php_version"

    render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        "PM_MODE=${RES_PM_MODE}" "PM_MAX_CHILDREN=${RES_MAX_CHILDREN}" \
        "PM_START_SERVERS=${RES_PM_START_SERVERS}" \
        "PM_MIN_SPARE_SERVERS=${RES_PM_MIN_SPARE_SERVERS}" \
        "PM_MAX_SPARE_SERVERS=${RES_PM_MAX_SPARE_SERVERS}" \
        "MEMORY_LIMIT=${RES_MEMORY_LIMIT_MB}M" \
        "DISABLE_FUNCTIONS=$(_domain_disable_functions_for "$framework_declared")" \
        > "/etc/php/${php_version}/fpm/pool.d/${sname}.conf"

    # GÜVENLİK DENETİMİ EKİ: dayanıklı reload/restart — kendi fonksiyonuna
    # ÇIKARILDI (test edilebilirlik + _domain_activate_fpm_unit ile AYNI
    # desen), bkz. _domain_add_bootstrap_shared_fpm başlık yorumu. Bu 'if'
    # çağrısı BİLİNÇLİ: bare/unguarded bir çağrı 'set -e' altında
    # başarısızlıkta TÜM 'domain add'i düşürürdü.
    if _domain_add_bootstrap_shared_fpm "$php_version" "$domain"; then
        success "PHP-FPM pool aktif (chroot: ${base})"
    fi

    # ─── 5. Nginx Vhost ───
    current=$((current + 1))
    step "${current}/${total}" "Nginx vhost oluşturuluyor... (profil: ${rate_profile})"

    write_meta "$domain" "RATE_PROFILE" "$rate_profile"
    write_meta "$domain" "SENSITIVE_PATHS" "$sensitive_paths"
    # FRAMEWORK meta'ya YALNIZ açık '--framework=' beyanı varsa yazılır.
    # Beyan yokken varsayılan 'ci4'ü yazmak, 'domain add' (sıkı liste) ile
    # sonraki 'domain repair' (meta'da 'ci4' görüp GEVŞEK liste) arasında
    # tutarsızlık yaratırdı — repair sessizce fail-open olurdu.
    # Beyan yoksa _domain_read_framework zaten 'ci4' fallback'i uygular
    # (dizin/vhost şeması için doğru davranış); _domain_framework_declared ise
    # boş döndürerek disable_functions'ı sıkı tarafta tutar.
    # NOT: 'set -e' altında '[[ ]] && cmd' kalıbı koşul yanlışken tüm komutu
    # başarısız sayıp script'i düşürür — bu yüzden açık 'if' kullanılıyor.
    if [[ -n "$framework_declared" ]]; then
        write_meta "$domain" "FRAMEWORK" "$framework"
    fi
    # GÖREV 2: RESOURCE_PROFILE zaten resource_profile_resolve ile whitelist'ten
    # geçirildi — write_meta'ya doğrulanmamış ham CLI girdisi ASLA gitmez.
    # RAPOR: lib/security.sh:_meta_known_keys whitelist'ine RESOURCE_PROFILE
    # eklenmesi gerekir (o dosya bu görevin kapsamı dışında) — aksi halde
    # 'harden-fs --apply' bu satırı SESSİZCE atar (bkz. _meta_rewrite_whitelist).
    write_meta "$domain" "RESOURCE_PROFILE" "$resource_profile"

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

    # ─── 7. AppArmor Profilleri (FPM master + CLI/worker) ───
    current=$((current + 1))
    step "${current}/${total}" "AppArmor profilleri (enforce)..."

    render_template "${SRVCTL_TEMPLATES}/apparmor/profile.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/apparmor.d/srvctl-${sname}"

    if _domain_load_apparmor_profile "/etc/apparmor.d/srvctl-${sname}" "srvctl-${sname}"; then
        success "AppArmor (FPM) profili enforce modda: srvctl-${sname}"
    else
        warn "AppArmor (FPM) profili enforce modda DEĞİL — manuel kontrol edin ('aa-status')"
    fi

    # CLI/worker profili — worker/scheduler unit'leri buna referans veriyor
    # (AppArmorProfile=srvctl-<sname>-cli, bkz. templates/systemd/srvctl-worker*.tpl).
    # Ayrı/dar profil: worker systemd User= ile exec'ten ÖNCE unprivileged UID'ye
    # düşer, FPM'in chroot/setuid capability'lerine ihtiyaç duymaz (bkz.
    # profile-cli.tpl başlık yorumu — en-az-yetki ilkesi).
    render_template "${SRVCTL_TEMPLATES}/apparmor/profile-cli.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/apparmor.d/srvctl-${sname}-cli"

    if _domain_load_apparmor_profile "/etc/apparmor.d/srvctl-${sname}-cli" "srvctl-${sname}-cli"; then
        success "AppArmor (CLI/worker) profili enforce modda: srvctl-${sname}-cli"
    else
        warn "AppArmor (CLI/worker) profili enforce modda DEĞİL — 'domain worker/scheduler start' başlamayabilir"
    fi

    # ─── 8. MariaDB ───
    current=$((current + 1))
    step "${current}/${total}" "Veritabanı oluşturuluyor..."

    # B3: operatör şeffaflığı — DB bu çalıştırmadan ÖNCE de varsa (ör. yedekten
    # elle geri yüklenmiş), 'CREATE DATABASE IF NOT EXISTS' ona dokunmadan yeni
    # kullanıcıya GRANT eder; bunu operatöre açıkça bildir.
    [[ "${_db_preexisted}" == "1" ]] && \
        warn "Veritabanı zaten mevcuttu: ${db_name} — içeriğine dokunulmadı, '${db_user}' bu şemaya yetkilendirildi"

    # Parolayı argv'den uzak tut: SQL stdin heredoc ile beslenir (ps/cmdline'da sır görünmez).
    # Root kimliği /root/.my.cnf'ten gelir (0600 root:root).
    # --force: yeni kullanıcıda REVOKE ALL PRIVILEGES hata verse bile sonraki SQL'ler çalışır.
    # ALTER USER: CREATE USER IF NOT EXISTS aynı isimde eski (ör. daha önce
    # remove edilip DROP edilmemiş @127.0.0.1) bir kullanıcı bulursa no-op
    # kalır ve parola ESKİ haliyle kalır; ALTER USER ile HER add'de parola
    # .credentials'ta üretilen yeni değere idempotent senkronlanır.
    mysql --force << SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

    success "DB: ${db_name} / User: ${db_user}"

    # ─── 9. Redis ACL ───
    current=$((current + 1))
    step "${current}/${total}" "Redis ACL ekleniyor..."

    # Mevcut ACL'den aynı kullanıcıyı sil (varsa) — KARAR 2: atomik/portable
    # _sed_inplace (bkz. core.sh) ile, çıplak GNU-only 'sed -i' yerine.
    _sed_inplace /etc/redis/users.acl "/^user ${redis_user} /d" 2>/dev/null || true

    # ─── ACL daraltma gerekçesi (domain/Redis/DB güvenlik incelemesi) ───
    # 1) '&*' → 'resetchannels &${sname}:*': eski satır TÜM pub/sub kanallarına
    #    izin veriyordu; domain A, domain B'nin Laravel broadcasting/Horizon/
    #    queue event kanallarına SUBSCRIBE/PUBLISH yapabiliyordu (domainler
    #    arası veri sızıntısı + mesaj enjeksiyonu). 'resetchannels', kanalları
    #    önce sıfırlayıp yalnız kendi prefix'ini ekler — AMA bu iki token
    #    SÜRÜM KOŞULLUDUR (bkz. core.sh:_redis_channel_isolation_mode üstündeki
    #    kaynak referanslı gerekçe): Redis 6.2.0'da eklendi, 6.0.x'in kendi
    #    parser'ında (src/acl.c) HİÇ TANIMLI DEĞİL — koşulsuz eklenirse ACL
    #    dosyası "Syntax error" ile REDDEDİLİR ve Redis HİÇ BAŞLAMAZ (Ubuntu
    #    22.04 = redis-server 6.0.16'da gerçek VM'de gözlemlendi). Redis <6.2
    #    ya da sürüm belirlenemezse token'lar ATLANIR + operatör UYARILIR.
    # 2) scripting: İKİ AŞAMALI — (a) YETENEK: SÜRÜM KOŞULLU (bkz.
    #    _domain_redis_scripting_mode üstündeki ayrıntılı gerekçe) — Redis
    #    7+'ta script içi ACL enforcement garantili, <7'de veya sürüm
    #    belirlenemezse GARANTİSİZ. (b) TALEP: operatör '--redis-queue' ile
    #    AÇIKÇA istedi mi (bkz. _domain_redis_queue_gate). NİHAİ '+@scripting'
    #    yalnız İKİSİ DE 'evet' ise yazılır — sürüm 7+ olsa BİLE talep yoksa
    #    '-@scripting' kalır (izolasyon önceliklidir, otomatik açılma YOK).
    # 3) '-SCAN -RANDOMKEY': ACL key pattern'i SCAN/RANDOMKEY sonuçlarını
    #    filtrelemez (yalnız sonrasında yapılan GET gibi komutlar NOPERM ile
    #    engellenir) → komşu domainlerin key adları numaralandırılabilirdi.
    #    '-KEYS' zaten vardı; aynı sınıf riski taşıyan SCAN/RANDOMKEY eklendi.
    # 4) '+INFO': '-@dangerous' INFO komutunu da kapsar — bu Laravel Horizon'un
    #    metrik/monitoring ekranını kırardı. INFO yalnız sunucu-geneli agregat
    #    istatistik döndürür (başka domainin key adı/değerini sızdırmaz), bu
    #    yüzden geri açıldı — Horizon dashboard'u çalışmaya devam eder.
    local redis_major="" redis_minor="" base_scripting_flag base_scripting_status channel_status
    read -r redis_major redis_minor <<< "$(_redis_version_pair)"
    read -r base_scripting_flag base_scripting_status <<< "$(_domain_redis_scripting_mode "$redis_major")"
    channel_status=$(_redis_channel_isolation_mode "$redis_major" "$redis_minor")

    # Nihai karar: YETENEK (base_scripting_status, sürüm) VE TALEP
    # (redis_queue_requested, '--redis-queue') BİRLEŞTİRİLİR — bkz.
    # _domain_redis_queue_gate üstündeki gerekçe. redis_queue_reason
    # yalnız MESAJLAŞMA için (karara dahil değil).
    local scripting_flag scripting_status redis_queue_reason
    read -r scripting_flag scripting_status redis_queue_reason <<< \
        "$(_domain_redis_queue_gate "$base_scripting_flag" "$base_scripting_status" "$redis_queue_requested")"

    local acl_line
    acl_line=$(_domain_build_redis_acl_line "$redis_user" "$redis_pass" "$sname" "$scripting_flag" "$channel_status")
    echo "$acl_line" >> /etc/redis/users.acl

    # ACL'i yeniden yükle
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        # GÜVENLİK DENETİMİ EKİ (BUG 3 — _domain_repair'daki AYNI düzeltme,
        # bkz. o çağrı sitesindeki tam gerekçe): 'redis-cli' sunucudan
        # HERHANGİ bir yanıt aldığı sürece — hata metni olsa bile —
        # genellikle 0 ile çıkar; çıplak '|| systemctl restart' zinciri ACL
        # LOAD'ın CANLI kural kümesine GERÇEKTEN uygulanıp uygulanmadığını
        # HİÇ ÖLÇMÜYORDU. 'domain add' burada 'repair' gibi bir
        # 'add_failed'/dürüst-exit-kodu mekanizmasına sahip DEĞİL (bu
        # görevin kapsamı bu iş için yeni bir mekanizma icat etmek değil) —
        # ama SESSİZCE geçilmiyor: dönüş değeri kontrol edilir, başarısızlık
        # AÇIKÇA warn+log_action edilir (domain'in geri kalanı —DB, vhost,
        # dosyalar— yine de başarıyla oluşturulduğundan tüm eklemeyi
        # ÖLDÜRMEZ, ama operatör Redis izolasyonunun eksik olduğunu BİLİR).
        # 'restart redis-server' fallback'i BİLEREK KALDIRILDI — ACL dosyası
        # sözdizimi hatası içeriyorsa restart TÜM domainlerin Redis'ini
        # çökertebilir (bkz. _domain_repair'daki AYNI gerekçe).
        if ! _redis_acl_load "$redis_admin_pass"; then
            warn "GÜVENLİK: Redis ACL bu domain için CANLI kural kümesine UYGULANMADI (${domain}) — anahtar alanı VE kanal izolasyonu kontrolleri YÜRÜRLÜKTE DEĞİL. Redis'in kendi hata metni yukarıda. 'systemctl restart redis-server' BİLEREK DENENMEDİ (ACL dosyası bozuksa restart TÜM domainlerin Redis'ini çökertebilir) — /etc/redis/users.acl'i elle inceleyip 'srvctl domain repair ${domain}' ile tekrar deneyin."
            log_action "domain add: Redis ACL LOAD başarısız (${domain}) — kanal izolasyonu YÜRÜRLÜKTE DEĞİL"
        fi
    else
        systemctl restart redis-server
    fi

    # Scripting durumunu meta'ya yaz (web-yazılabilir ama SIR değil — 'srvctl
    # domain info' bunu okuyup operatöre gösterir) — bu, NİHAİ (yetenek+talep
    # birleştirilmiş) değerdir, yalnız sürüm yeteneği DEĞİL.
    write_meta "$domain" "REDIS_SCRIPTING" "$scripting_status"

    case "$scripting_status" in
        enabled)
            success "Redis ACL: ${redis_user} → ${sname}:* (Redis ${redis_major}: scripting AÇIK)"
            if [[ "$redis_queue_reason" == "requested" ]]; then
                warn "--redis-queue: bu domain için Redis EVAL/Lua script çalıştırma AÇILDI (Laravel Redis kuyruk sürücüsü/Horizon bunu kullanır). Bu, varsayılan olarak KAPALI tutulan bir yetenektir; ACL yine de bu domaini kendi anahtar alanıyla (${sname}:*) sınırlar."
            fi
            ;;
        disabled)
            success "Redis ACL: ${redis_user} → ${sname}:*"
            if [[ "$redis_queue_reason" == "rejected_version" ]]; then
                warn "--redis-queue istendi ama REDDEDİLDİ: Redis ${redis_major}, script içindeki anahtar erişiminin ACL ile sınırlandığını garanti etmiyor (7.0 altı) — açılırsa komşu domainlerin anahtar alanına EVAL ile erişilebilir. Bu riski göze alamayız; Redis'i 7+'a yükseltin (bayrak olmadan yine AÇILMAZ, '--redis-queue' gerekir) ya da QUEUE_CONNECTION=database kullanın."
            elif [[ "$base_scripting_status" == "enabled" ]]; then
                # KRİTİK: Redis EVAL/Lua'yı GÜVENLE destekliyor (7+) ama
                # operatör AÇIKÇA istemedi — artık burada OTOMATİK
                # AÇILMIYOR (bilinçli tasarım kararı, bkz. _domain_redis_queue_gate).
                warn "Redis ${redis_major} EVAL/Lua scripting'i güvenle destekliyor ama bu domainde VARSAYILAN OLARAK KAPALI bırakıldı — Laravel Redis kuyruk sürücüsü/Horizon için 'srvctl domain add ... --redis-queue' ile AÇIKÇA isteyin, ya da QUEUE_CONNECTION=database kullanın."
            else
                warn "Redis ${redis_major} tespit edildi — scripting (EVAL/Lua) bu domainde KAPALI. Laravel Redis kuyruk sürücüsü/Horizon ÇALIŞMAZ; QUEUE_CONNECTION=database kullanın."
            fi
            ;;
        *)
            success "Redis ACL: ${redis_user} → ${sname}:*"
            warn "Redis sürümü tespit edilemedi — fail-closed: scripting (EVAL/Lua) KAPALI. Laravel Redis kuyruk sürücüsü/Horizon ÇALIŞMAZ; QUEUE_CONNECTION=database kullanın."
            if [[ "$redis_queue_reason" == "rejected_version" ]]; then
                warn "--redis-queue istendi ama REDDEDİLDİ: Redis sürümü tespit edilemediğinden fail-closed kural gereği scripting açılmadı."
            fi
            ;;
    esac

    # Kanal (pub/sub) izolasyon durumunu meta'ya yaz ve desteklenmiyorsa/
    # belirsizse operatörü AÇIKÇA uyar — sessiz izolasyonsuzluk YOK: operatör
    # komşu kiracıların pub/sub kanallarını görebildiğini bilmeli.
    write_meta "$domain" "REDIS_CHANNEL_ISOLATION" "$channel_status"
    case "$channel_status" in
        supported)
            success "Redis ACL: ${redis_user} → kanal izolasyonu AÇIK (Redis ${redis_major}.${redis_minor} ≥ 6.2, yalnız ${sname}:* kanalları)"
            ;;
        unsupported)
            warn "Redis ${redis_major}.${redis_minor} tespit edildi (6.2 altı) — pub/sub KANAL izolasyonu ACL ile YAPILAMIYOR: bu domain diğer domainlerin pub/sub kanallarını görebilir/yayın yapabilir. İzolasyon için Redis'i 6.2+'a yükseltin ya da domain başına ayrı Redis instance'ı kullanın."
            ;;
        *)
            warn "Redis sürümü tespit edilemedi — fail-closed: pub/sub KANAL izolasyon token'ları ACL'e EKLENMEDİ (izolasyonsuz ama çalışan Redis, hiç başlamayan Redis'e tercih edildi). 'redis-cli ACL GETUSER ${redis_user}' ile doğrulayın."
            ;;
    esac

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
    _apply_cgroups_slice "${domain}" "${sname}" "${resource_profile}"
    _apply_seccomp_hardening "${php_version}"
    success "cgroups slice + seccomp uygulandı"

    # ─── Credentials Dosyası (umask 077 + 0600 root:root) ───
    _domain_write_credentials "$domain" "$base" "$web_user" "$php_version" \
        "$db_name" "$db_user" "$db_pass" \
        "$redis_user" "$redis_pass" "${sname}:"

    # ─── shared/.env iskeleti (framework'e göre; zaten varsa dokunulmaz) ───
    _domain_write_env_skeleton "$domain" "$base" "$web_user" "$framework" \
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

    # ─── Başarı: rollback güvenlik ağını devre dışı bırak ───
    # Buraya kadar tüm adımlar tamamlandı; bundan sonraki olası bir hata
    # (ör. log_action) TAM kurulu bir domain'i geri almamalı. M8: INT/TERM
    # trap'ları da EXIT ile birlikte temizlenir (aksi halde başarıdan SONRA
    # bir Ctrl-C hâlâ artık anlamsız rollback'i tetiklemeye çalışırdı).
    trap - EXIT INT TERM
    _DOMAIN_ADD_ROLLBACK_DONE=1
    unset -f _domain_add_rollback 2>/dev/null || true

    # ─── GÖREV 1: per-domain FPM izolasyonuna otomatik geçiş (Seçenek C) ───
    # Trap TEMİZLENDİKTEN SONRA çağrılır: domain bu noktada zaten TAM
    # kurulu ve çalışır durumda (paylaşılan pool üzerinde) — migrasyon
    # başarısız olsa bile 'domain add' rollback'i TEKRAR TETİKLEMEZ ve
    # BAŞARISIZ SAYILMAZ (bkz. _domain_migrate_to_isolated_fpm).
    _domain_migrate_to_isolated_fpm "$domain"

    # ─── Sonuç ───
    header "✅ Domain başarıyla eklendi: ${domain}"

    echo "  Web root:       ${base}/public_html"
    echo "  Private:        ${base}/private"
    echo "  PHP:            ${php_version} (chroot: ${base})"
    divider
    echo "  DB Name:        ${db_name}"
    echo "  DB User:        ${db_user}"
    # Parolalar yalnız doğrudan/interaktif CLI çağrısında gösterilir.
    # _DOMAIN_ADD_QUIET_SECRETS=1 ile çağrılırsa (ör. _domain_clone'un
    # programatik çağrısı) stdout'a basılmaz — terminal scrollback, CI logu
    # veya webhook logu gibi klon çıktısını yakalayan hiçbir yere sızmasın.
    if [[ "${_DOMAIN_ADD_QUIET_SECRETS:-0}" == "1" ]]; then
        echo "  DB Pass:        [gizli — ${base}/.credentials dosyasından okuyun]"
    else
        echo "  DB Pass:        ${db_pass}"
    fi
    divider
    echo "  Redis User:     ${redis_user}"
    if [[ "${_DOMAIN_ADD_QUIET_SECRETS:-0}" == "1" ]]; then
        echo "  Redis Pass:     [gizli — ${base}/.credentials dosyasından okuyun]"
    else
        echo "  Redis Pass:     ${redis_pass}"
    fi
    echo "  Redis Prefix:   ${sname}:"
    divider
    echo "  Credentials:    ${base}/.credentials"
    echo ""
    echo -e "  ${BOLD}Sonraki adım:${NC}  srvctl deploy ${domain}"
    echo ""

    log_action "DOMAIN ADD: ${domain} (user=${web_user}, php=${php_version}, db=${db_name})"
}

# ═══════════════════════════════════════════════
#  DOMAIN PURGE — TEK KAYNAK sunucu-tarafı kaynak temizliği (H2 kapanışı,
#  denetim DALGA 5)
#
#  _domain_add_rollback (yarım kalmış 'add') VE _domain_remove (tam silme)
#  BU fonksiyonu çağırır. ESKİDEN aynı temizlik mantığı İKİ AYRI KOPYA
#  halindeydi ve _domain_remove kopyası worker/scheduler/per-domain-FPM-unit/
#  state-dir'i HİÇ BİLMİYORDU: 'domain worker enable' + 'domain scheduler
#  enable' + 'domain remove' sırasıyla çalıştırılırsa 'web_<sname>' userdel
#  edilip '/var/www/<domain>' silinse bile scheduler TIMER'ı enable+aktif
#  kalıyor, her dakika artık var olmayan 'User=web_<sname>' ile tetiklenip
#  "Failed to determine user credentials" ile sonsuz journal spam üretiyordu;
#  domain yeniden eklenince de eski framework'ün ExecStart'ıyla BAYAT unit
#  dosyası orada duruyordu (bu tam olarak bu oturumda tekrarlanan "iki
#  yerde, biri güncel" hata sınıfı).
#
#  Argümanlar: domain php_version [db_preexisted=0] [cert_preexisted=0]
#  db_preexisted/cert_preexisted YALNIZ rollback'in B3 davranışı içindir:
#  '1' ise bu ÇALIŞTIRMADAN ÖNCE zaten var olan DB/sertifika SİLİNMEZ (olası
#  geri yüklenmiş üretim verisi/sertifika korunur). 'domain remove' HER ZAMAN
#  '0 0' geçer — bilinçli TAM silme talebidir, B3 ayrımı yalnız yarım kalmış
#  'add'e özgüdür. Dosya sistemi ağacı ve linux kullanıcısı da BU fonksiyonda
#  silinir; çağıran taraf yalnız kendine özgü ön-adımları (ör. _domain_remove
#  'son yedek') üstlenir.
# ═══════════════════════════════════════════════
_domain_purge_resources() {
    local domain="$1" php_version="${2:-}" db_preexisted="${3:-0}" cert_preexisted="${4:-0}"
    [[ -n "$domain" ]] || return 0

    local sname; sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local base="${WEB_ROOT}/${domain}"
    local db_name="db_${sname}"
    local db_user="usr_${sname}"
    local redis_user="redis_${sname}"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local fpm_dir="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}"

    # 1. Kuyruk worker'ları (H2): enable/wants sembolik bağları + systemd'nin
    #    hâlâ bildiği TÜM instance'lar, sonra template unit dosyasının kendisi.
    local wants_dir="${sysd_dir}/multi-user.target.wants"
    local f unit
    for f in "${wants_dir}/srvctl-worker-${sname}@"*".service"; do
        [[ -e "$f" ]] || continue
        systemctl disable --now "$(basename "$f")" >/dev/null 2>&1 || true
    done
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done < <(systemctl list-units --all --no-legend --plain "srvctl-worker-${sname}@*.service" 2>/dev/null | awk '{print $1}')
    rm -f -- "${sysd_dir}/srvctl-worker-${sname}@.service"

    # 2. Scheduler (H2): timer ÖNCE (aktivasyon hedefi timer'dır), sonra service.
    systemctl disable --now "srvctl-scheduler-${sname}.timer" >/dev/null 2>&1 || true
    systemctl stop "srvctl-scheduler-${sname}.service" >/dev/null 2>&1 || true
    rm -f -- "${sysd_dir}/srvctl-scheduler-${sname}.timer" "${sysd_dir}/srvctl-scheduler-${sname}.service"

    # 2.5. Domain cron görevleri (srvctl cron add <domain> ...) — worker/
    #      scheduler İLE AYNI gerekçe (H2): 'domain remove' sonrası bu
    #      unit'ler öksüz kalmasın (kullanıcısı silinmiş bir 'User=' ile her
    #      tetiklemede journal spam'i üretmesinler). Sistem geneli cron'lar
    #      ('srvctl-syscron-*') bu domain'e ÖZGÜ DEĞİLDİR — buraya ASLA
    #      dokunulmaz. lib/cron.sh'ı SOURCE ETMİYORUZ (CLAUDE.md deseni:
    #      çapraz modül çağrısı yalnızca fonksiyon GERÇEKTEN gerektiğinde
    #      guard'lı source edilir) — worker/scheduler'ın KENDİSİ de aynı
    #      şekilde başka bir modülü çağırmadan doğrudan systemctl/rm
    #      kullanıyor, cron temizliği de AYNI stile uyar. Ad uzayı ayrımı
    #      ('srvctl-cron-<sname>-*' vs 'srvctl-cronfail-<sname>-*') KASITLI
    #      farklı önek kullanır (bkz. lib/cron.sh:_cron_fail_svc_name) — bu
    #      glob'lar birbirini YAKALAMAZ.
    local cf
    for cf in "${sysd_dir}/srvctl-cron-${sname}-"*".timer"; do
        [[ -e "$cf" ]] || continue
        systemctl disable --now "$(basename "$cf")" >/dev/null 2>&1 || true
    done
    for cf in "${sysd_dir}/srvctl-cron-${sname}-"*".service"; do
        [[ -e "$cf" ]] || continue
        systemctl stop "$(basename "$cf")" >/dev/null 2>&1 || true
    done
    for cf in "${sysd_dir}/srvctl-cronfail-${sname}-"*".service"; do
        [[ -e "$cf" ]] || continue
        systemctl disable --now "$(basename "$cf")" >/dev/null 2>&1 || true
    done
    rm -rf -- "${sysd_dir}/srvctl-cron-${sname}-"*".service.d"
    rm -f -- "${sysd_dir}/srvctl-cron-${sname}-"*".timer" \
             "${sysd_dir}/srvctl-cron-${sname}-"*".service" \
             "${sysd_dir}/srvctl-cronfail-${sname}-"*".service"
    rm -rf -- "${SRVCTL_STATE_DIR:-/nonexistent}/_cron/${sname}" 2>/dev/null || true

    # 3. Per-domain FPM unit (T7a/harden-fpm) + config (H2: eskiden yalnız rollback biliyordu).
    systemctl disable --now "srvctl-fpm-${sname}.service" >/dev/null 2>&1 || true
    rm -f -- "${sysd_dir}/srvctl-fpm-${sname}.service" "${fpm_dir}/${sname}.conf"

    # 4. cgroups slice
    systemctl stop "srvctl-${sname}.slice" >/dev/null 2>&1 || true
    rm -f -- "${sysd_dir}/srvctl-${sname}.slice"

    systemctl daemon-reload >/dev/null 2>&1 || true

    # 5. Nginx vhost
    rm -f -- "/etc/nginx/sites-enabled/${domain}.conf" "/etc/nginx/sites-available/${domain}.conf"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true

    # 6. Paylaşılan PHP-FPM pool (harden-fpm hiç uygulanmamış domainler için)
    if [[ -n "$php_version" ]]; then
        rm -f -- "/etc/php/${php_version}/fpm/pool.d/${sname}.conf"
        systemctl reload "php${php_version}-fpm" >/dev/null 2>&1 || true
    fi

    # 7. AppArmor (FPM master + CLI/worker — bkz. profile-cli.tpl)
    aa-disable "/etc/apparmor.d/srvctl-${sname}" >/dev/null 2>&1 || true
    rm -f -- "/etc/apparmor.d/srvctl-${sname}"
    aa-disable "/etc/apparmor.d/srvctl-${sname}-cli" >/dev/null 2>&1 || true
    rm -f -- "/etc/apparmor.d/srvctl-${sname}-cli"

    # 8. Logrotate
    rm -f -- "/etc/logrotate.d/srvctl-${sname}"

    # 9. MariaDB — HER İKİ host için DROP USER (localhost + 127.0.0.1) HER ZAMAN;
    #    DROP DATABASE yalnız bu çalıştırmadan ÖNCE VAR DEĞİLSE (B3).
    if [[ "$db_preexisted" != "1" ]]; then
        mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" >/dev/null 2>&1 || true
    else
        warn "DB '${db_name}' bu çalıştırmadan ÖNCE de vardı — DROP DATABASE ATLANDI (mevcut veri korunuyor)"
    fi
    mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" >/dev/null 2>&1 || true
    mysql -e "DROP USER IF EXISTS '${db_user}'@'127.0.0.1';" >/dev/null 2>&1 || true
    mysql -e "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true

    # 10. Redis ACL — KARAR 2: atomik/portable _sed_inplace (bkz. core.sh).
    _sed_inplace /etc/redis/users.acl "/^user ${redis_user} /d" >/dev/null 2>&1 || true
    systemctl restart redis-server >/dev/null 2>&1 || true

    # 11. SSL sertifikası — yalnız bu çalıştırmadan ÖNCE VAR DEĞİLSE (B3).
    if [[ "$cert_preexisted" != "1" ]]; then
        certbot delete --cert-name "${domain}" --non-interactive >/dev/null 2>&1 || true
    else
        warn "SSL sertifikası '${domain}' bu çalıştırmadan ÖNCE de vardı — SİLİNMEDİ"
    fi

    # 12. Dosya ağacı + hardened state (H2: eskiden yalnız rollback biliyordu).
    if [[ -e "$base" && ! -L "$base" ]]; then
        rm -rf -- "$base"
    fi
    rm -rf -- "${SRVCTL_STATE_DIR:-/nonexistent}/${domain}" 2>/dev/null || true

    # 13. Linux kullanıcısı
    userdel "${web_user}" >/dev/null 2>&1 || true
    groupdel "${web_user}" >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════
#  DOMAIN REMOVE
# ═══════════════════════════════════════════════
_domain_remove() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local base="${WEB_ROOT}/${domain}"

    echo ""
    warn "⚠️  ${domain} ve TÜM VERİLERİ silinecek!"
    warn "Bu işlem geri alınamaz."
    echo ""

    if ! confirm "Silmek istediğinizden emin misiniz?"; then
        info "İptal edildi."
        return 0
    fi

    # PHP sürümü _derive_php ile doğrulanmış biçimde alınır. NOT: eskiden burada
    # 'local php_version=DEFAULT' + ayrı bir 'read_credentials' çağrısı vardı;
    # ancak read_credentials BÜYÜK harfli global 'PHP_VERSION'ı set ediyor —
    # küçük harfli yerel 'php_version' hiç güncellenmiyordu. Sonuç: domain
    # örn. 8.2 kullanıyor olsa bile DEFAULT_PHP_VERSION'ın (ör. 8.3) pool'u
    # silinmeye çalışılıyor, gerçek 8.2 pool'u öksüz/ölü kalıyordu.
    local php_version
    php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")

    info "Son yedek alınıyor..."
    mkdir -p "${BACKUP_DIR}"
    tar czf "${BACKUP_DIR}/${domain}-final-$(date +%Y%m%d_%H%M%S).tar.gz" \
        "${base}" 2>/dev/null || true

    # ─── H2 DÜZELTMESİ (denetim DALGA 5) ───
    # Tüm sunucu tarafı kaynak temizliği artık TEK KAYNAK olan
    # _domain_purge_resources ile yapılır (_domain_add_rollback ile
    # PAYLAŞILIR) — worker/scheduler/per-domain FPM unit'leri + state dir
    # dahil (eskiden yalnız rollback bunları biliyordu, 'domain remove'
    # sonrası öksüz kalıyorlardı; bkz. fonksiyonun başlık yorumu). db/cert
    # 'preexisted' bayrakları burada HER ZAMAN 0 (koşulsuz sil) — 'remove'
    # bilinçli TAM silme talebidir, B3'teki "bu çalıştırma öncesi var mıydı"
    # ayrımı yalnız yarım kalmış 'add' rollback'ine özgüdür.
    _domain_purge_resources "$domain" "$php_version" 0 0

    success "Domain kaldırıldı: ${domain}"
    info "Son yedek: ${BACKUP_DIR}/${domain}-final-*.tar.gz"

    log_action "DOMAIN REMOVE: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  Tek domain dizini için liste satırı üret (saf, parse-not-source)
#  Çıktı: domain|php|user|ssl|chroot
#
#  GÜVENLİK DENETİMİ EKİ (MADDE 1 — designwestgate.art HOST bulgusu): PHP
#  sütunu ESKİDEN '.credentials' yoksa/PHP_VERSION alanı eksik/geçersizse
#  koşulsuz 'DEFAULT_PHP_VERSION'a düşüyordu — bu bir UYDURMA değerdi (tam
#  olarak 'web_html' kullanıcı adının uydurulması bug'ıyla AYNI SINIF: bir
#  şeyin GERÇEKTEN doğrulanmış olduğu izlenimini veren, aslında hiç
#  doğrulanmamış bir varsayılan). list_all_domains artık '.credentials'sız
#  ama 'web_<sname>' kullanıcısı VAR olan gerçek domainleri de döndürdüğünden
#  ('.credentials' eksik = PHP versiyonu operatöre BİLİNMİYOR demektir) bu
#  fallback burada 'bilinmiyor' — KULLANICI sütunu ise fabrikasyon DEĞİL:
#  'web_<sname>' her iki kapıdan (.credentials VEYA gerçek sistem kullanıcısı)
#  geçmiş bir domain için zaten DOĞRU/doğrulanmış kimliktir (safe_name'den
#  türetilir — _domain_add'in useradd'ı da AYNI kuralı kullanır).
# ───────────────────────────────────────────────────────────────
_domain_row() {
    local dir="$1"
    local domain sname php_ver user ssl chroot
    domain=$(basename "$dir")
    sname=$(safe_name "$domain")
    php_ver="bilinmiyor"
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

    # Chroot kontrolü — İZOLASYON-FARKINDA (sistematik denetim bulgusu, bkz.
    # rapor): izole bir domain'in pool tanımı artık paylaşılan pool.d/'de
    # DEĞİL, ${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/<sname>.conf'ta yaşıyor
    # (bkz. _domain_render_fpm_unit) — yalnız pool.d'ye bakmak, izolasyona
    # geçmiş (yani DAHA GÜVENLİ) domainleri yanlışlıkla "chroot yok" gösterirdi.
    # _security_audit (lib/security.sh) zaten AYNI iki-yol desenini kullanıyor.
    # PHP versiyonu 'bilinmiyor' ise (yukarı bkz.) paylaşılan pool.d yolu
    # KURULAMAZ — uydurma bir sürüm numarasıyla var-olmayan bir yola bakıp
    # SESSİZCE "❌" dönmek, gerçek bir kontrolmüş gibi görünmesin diye php_ver
    # önce doğrulanır (assert_php_version); izole yol zaten PHP sürümünden
    # BAĞIMSIZ olduğundan bu kısıtlamadan ETKİLENMEZ.
    local pool_conf="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"
    if [[ ! -f "$pool_conf" ]] && assert_php_version "$php_ver"; then
        pool_conf="${SRVCTL_PHP_POOL_DIR:-/etc/php/${php_ver}/fpm/pool.d}/${sname}.conf"
    fi
    if [[ -f "$pool_conf" ]]; then
        grep -q "chroot" "$pool_conf" 2>/dev/null && chroot="✅"
    fi

    printf '%s|%s|%s|%s|%s\n' "$domain" "$php_ver" "$user" "$ssl" "$chroot"
}

# ═══════════════════════════════════════════════
#  DOMAIN LIST
# ═══════════════════════════════════════════════
# GÜVENLİK DENETİMİ EKİ (HOST'ta ölçüldü, srvctl-jammy): bu fonksiyon
# ESKİDEN '${WEB_ROOT}/*/' üzerinde HAM bir glob ile numaralandırıyordu —
# 'security audit' (lib/security.sh) ve 'domain repair --all' zaten
# kullandığı 'list_all_domains()' (lib/core.sh) sözleşmesini ATLIYORDU. Bu
# tutarsızlık nginx paketinin kendi kurduğu '/var/www/html' dizinini
# TAMAMEN HAYALİ bir domain gibi gösteriyordu: 'web_html' diye bir sistem
# kullanıcısı YOKKEN çıktıda "KULLANICI: web_html" satırı basılıyordu ve
# 'Toplam: N domain' sayacı bunu içeriyordu — aynı sunucuda AYNI ANDA
# 'security audit' bu dizini HİÇ görmüyordu (iki komut aynı soruya farklı
# cevap veriyordu). Artık TEK sözleşme: 'list_all_domains()' (kapı:
# validate_domain + ('.credentials' VAR OLMASI VEYA 'web_<sname>' sistem
# kullanıcısının VARLIĞI) — üç tüketici (list/audit/repair --all) AYNI
# kümeyi görür.
#
# GÜVENLİK DENETİMİ EKİ (MADDE 1 — designwestgate.art HOST bulgusu): ikinci
# kapı eklendiğinden beri bu tablo artık '.credentials'ı OLMAYAN ama GERÇEK
# (web kullanıcısı var) domainleri de gösterebilir — bu durumda PHP sütunu
# 'bilinmiyor' basar (bkz. _domain_row başlık yorumu, uydurma değer YOK) ve
# aşağıda AYRI bir dipnotla operatöre '.credentials' eksikliğinin onarılması
# gerektiği AÇIKÇA söylenir (sessizce geçilmez).
_domain_list() {
    echo ""
    echo -e "  ${BOLD}Kayıtlı Domain'ler${NC}"
    divider
    printf "  ${DIM}%-30s %-8s %-15s %-6s %-8s${NC}\n" "DOMAIN" "PHP" "KULLANICI" "SSL" "CHROOT"
    divider

    local count=0
    local -a missing_creds=()
    local domain dir row php_ver user ssl chroot
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        dir="${WEB_ROOT}/${domain}/"
        row=$(_domain_row "$dir")
        IFS='|' read -r domain php_ver user ssl chroot <<< "$row"
        printf "  %-30s %-8s %-15s %-6s %-8s\n" "$domain" "$php_ver" "$user" "$ssl" "$chroot"
        count=$((count + 1))
        [[ -f "${dir}.credentials" ]] || missing_creds+=("$domain")
    done < <(list_all_domains)

    divider
    echo "  Toplam: ${count} domain"

    # KARAR (görev talebi — WEB_ROOT altında domain OLMAYAN dizinler ne
    # olacak): SESSİZCE gizlemiyoruz AMA tabloya da HİÇBİR ZAMAN satır
    # olarak eklemiyoruz. Gerekçe: bu tür bir dizin için PHP/KULLANICI/SSL/
    # CHROOT üretmenin bir anlamı yok — '.credentials' yoksa bu değerler
    # tamamen UYDURULMUŞ olur (tam olarak bu görevin bulgusu — 'web_html'
    # diye bir kullanıcı YOKKEN öyle gösterilmesi) ve otomasyon 'domain
    # list' çıktısını ayrıştırıyorsa var olmayan bir domain üzerinde işlem
    # yapmaya kalkışabilir. Ama TAMAMEN sessiz kalmak da yanlış: operatör
    # '/var/www' altında gördüğü bir dizinin neden listede YOK olduğunu
    # merak eder (bu görevin bizzat kendisi böyle bir gözlemle başladı).
    # Orta yol: yönetilmeyen dizin SAYISI ayrı, açıkça etiketlenmiş bir
    # DİPNOT olarak gösterilir — ana tabloya KARIŞTIRILMAZ, sayaca DAHİL
    # EDİLMEZ. Sayım 'list_all_domains()'in iki-kapılı testini (validate_
    # domain + .credentials) TEKRAR YAZMADAN, WEB_ROOT altındaki TOPLAM
    # dizin sayısından yönetilen domain sayısını (yukarıdaki 'count')
    # ÇIKARARAK yapılır — böylece tek doğruluk kaynağı yine 'list_all_
    # domains()' kalır, burada yalnız bir fark alınır.
    local total_dirs=0 d
    for d in "${WEB_ROOT}"/*/; do
        [[ -d "$d" ]] || continue
        total_dirs=$((total_dirs + 1))
    done
    local unmanaged=$((total_dirs - count))
    if [[ "$unmanaged" -gt 0 ]]; then
        echo "  (${unmanaged} dizin listelenmedi: srvctl tarafından yönetilmiyor — ör. nginx'in varsayılan '/var/www/html' dizini. Ayrıntı için: ls ${WEB_ROOT})"
    fi

    # GÜVENLİK DENETİMİ EKİ (MADDE 1 — designwestgate.art HOST bulgusu): tabloda
    # görünen ama '.credentials'ı OLMAYAN domainler AYRICA raporlanır — bu,
    # yarım kalmış bir 'domain add' veya kaybolmuş/silinmiş bir '.credentials'
    # işaretidir ve sessizce geçilmemesi gereken bir onarım ihtiyacıdır (PHP
    # sütununda gösterilen 'bilinmiyor' bunun DOĞRUDAN sonucudur).
    if [[ "${#missing_creds[@]}" -gt 0 ]]; then
        warn "${#missing_creds[@]} domain '.credentials' dosyasına SAHİP DEĞİL (PHP sütununda 'bilinmiyor' bu yüzden gösteriliyor) — yarım kalmış bir kurulum/kayıp dosya işareti olabilir: ${missing_creds[*]}"
        warn "  Onarım için: 'srvctl domain repair <domain>' (her biri için tek tek) veya 'srvctl domain repair --all'"
    fi
    echo ""
}

# ═══════════════════════════════════════════════
#  DOMAIN INFO
# ═══════════════════════════════════════════════
_domain_info() {
    # O8 DÜZELTMESİ (denetim DALGA 4): DB parolası artık VARSAYILAN olarak
    # GİZLENİR — yalnızca açık '--show-secrets' ile gösterilir. 'developer'
    # rolünün sudoers'ında 'srvctl domain info *' bulunduğundan (lib/user.sh)
    # eskiden HER developer HER domainin DB parolasını doğrudan okuyabiliyor,
    # çıktı terminal scrollback/CI logunda kalabiliyordu (_domain_add'deki
    # _DOMAIN_ADD_QUIET_SECRETS deseniyle birebir aynı gerekçe).
    local domain="" show_secrets=0
    local _a
    for _a in "$@"; do
        case "$_a" in
            --show-secrets) show_secrets=1 ;;
            -*) warn "Bilinmeyen seçenek: ${_a}" ;;
            *) domain="$_a" ;;
        esac
    done
    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain info <domain> [--show-secrets]"
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
        if [[ "$show_secrets" == "1" ]]; then
            echo "  DB Pass:        ${DB_PASS:-[credentials dosyasından okunabilir]}"
        else
            echo "  DB Pass:        [gizli — '--show-secrets' ile göster ya da ${base}/.credentials dosyasından okuyun]"
        fi
        divider
        echo -e "  ${CYAN}Redis${NC}"
        echo "  Redis User:     ${REDIS_USER:-redis_${sname}}"
        echo "  Redis Prefix:   ${REDIS_PREFIX:-${sname}:}"
        # Scripting (EVAL/Lua) durumu YETENEK (sürüm) VE TALEP (--redis-queue)
        # birleşimiyle belirlenir (bkz. _domain_redis_queue_gate) — operatör
        # Horizon/Redis queue neden çalışmadığını (ya da çalıştığını)
        # buradan anlayabilir. 'kapalı' Redis <7'DEN OLABİLECEĞİ GİBİ (yetenek
        # yok) Redis 7+ olup '--redis-queue' hiç İSTENMEMİŞ olmasından da
        # (talep yok) kaynaklanabilir — meta bu ikisini AYIRT ETMEZ (yalnız
        # nihai durumu tutar), bu yüzden mesaj HER İKİ olasılığı da kapsar.
        local scripting_status
        scripting_status=$(_domain_read_redis_scripting_status "$domain")
        case "$scripting_status" in
            enabled)
                echo -e "  Redis Scripting: ${GREEN}✅ açık${NC} (Redis 7+ VE '--redis-queue' ile AÇIKÇA istendi — EVAL/Lua ACL kısıtına tabi, Laravel queue/Horizon çalışır)"
                ;;
            disabled)
                echo -e "  Redis Scripting: ${YELLOW}⚠️  kapalı${NC} (Laravel Redis kuyruk sürücüsü/Horizon ÇALIŞMAZ — Redis <7 ise hiçbir zaman açılamaz; Redis 7+ ise 'srvctl domain add ... --redis-queue' ile açıkça istenmeliydi; QUEUE_CONNECTION=database kullanın)"
                ;;
            *)
                echo -e "  Redis Scripting: ${YELLOW}⚠️  bilinmiyor${NC} (henüz belirlenmedi — 'srvctl domain repair ${domain}' çalıştırın)"
                ;;
        esac
        # Kanal (pub/sub) izolasyon durumu — operatör komşu kiracıların
        # pub/sub kanallarını neden görebildiğini (ya da göremediğini)
        # buradan anlayabilir (bkz. core.sh:_redis_channel_isolation_mode).
        local channel_status
        channel_status=$(_domain_read_redis_channel_status "$domain")
        case "$channel_status" in
            supported)
                echo -e "  Redis Kanal İzolasyonu: ${GREEN}✅ açık${NC} (Redis 6.2+ — yalnız ${sname}:* kanalları)"
                ;;
            unsupported)
                echo -e "  Redis Kanal İzolasyonu: ${YELLOW}⚠️  yok${NC} (Redis <6.2 — pub/sub kanalları ACL ile kısıtlanamıyor, kiracılar birbirinin kanallarını görebilir; Redis 6.2+ ya da domain başına ayrı Redis instance gerekir)"
                ;;
            *)
                echo -e "  Redis Kanal İzolasyonu: ${YELLOW}⚠️  bilinmiyor${NC} (henüz belirlenmedi — 'srvctl domain repair ${domain}' çalıştırın)"
                ;;
        esac
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

    # PHP-FPM pool — izole unit varsa oradan oku, yoksa paylaşılan pool.d'ye
    # düş (bkz. _domain_row başlık yorumu — aynı sistematik denetim bulgusu:
    # izole domainler yalnız pool.d kontrolüyle yanlışlıkla "pool yok" görünürdü).
    local pool_conf="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"
    local pool_kind="izole unit"
    if [[ ! -f "$pool_conf" ]]; then
        pool_conf="${SRVCTL_PHP_POOL_DIR:-/etc/php/${php_ver}/fpm/pool.d}/${sname}.conf"
        pool_kind="paylaşılan"
    fi
    local pool_status="${RED}❌ Yok${NC}"
    if [[ -f "$pool_conf" ]]; then
        if grep -q "chroot" "$pool_conf" 2>/dev/null; then
            pool_status="${GREEN}✅ Aktif (chroot, ${pool_kind})${NC}"
        else
            pool_status="${YELLOW}⚠️  Aktif (chroot yok, ${pool_kind})${NC}"
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
#  ARTIK SABİT DEĞİL — profil tabanlı (GÖREV 2, kapasite planlama).
#  TEK türetme kaynağı lib/core.sh:resource_profile_load'dur (conf/
#  resource-profiles.conf sözleşmesi: profil:pm_mode:max_children:
#  memory_limit_mb:tasks_max). Burada BAĞIMSIZ bir sabit/formül YOKTUR —
#  eskiden "4096M 4608M 512M 200" hardcoded'dı ve pool.conf.tpl'nin
#  hardcoded pm.max_children=16/memory_limit=256M değerleriyle ELLE
#  senkronize tutuluyordu (bugünkü drift'in kök nedeni tam olarak buydu).
#  Argüman: kaynak profili adı (ör. "ecommerce"); verilmezse/boşsa/tanınmaz
#  ise resource_profile_load kendi içinde 'standard'a düşer.
#  Çıktı: "MEM_HIGH MEM_MAX MEM_SWAP_MAX TASKS_MAX" (M sonekli, sabit sıra —
#  eski çağıranlarla (_apply_cgroups_slice/_domain_resources) AYNI sözleşme).
# ───────────────────────────────────────────────────────────────
_domain_cgroups_defaults() {
    local profile="${1:-standard}"
    resource_profile_load "$profile"
    echo "${RES_MEMORY_HIGH} ${RES_MEMORY_MAX} ${RES_MEMORY_SWAP} ${RES_TASKS_MAX}"
}

# ───────────────────────────────────────────────────────────────
#  Helper: Per-domain cgroups v2 slice oluştur (Faz 1)
#  systemd "srvctl-<sname>.slice" otomatik olarak srvctl.slice altına girer.
#  3. argüman (profile) OPSİYONELDİR — verilmezse 'standard' (geriye uyumlu
#  varsayılan; mevcut 2-argümanlı çağıranların davranışı değişmez).
# ───────────────────────────────────────────────────────────────
_apply_cgroups_slice() {
    local domain="$1" sname="$2" profile="${3:-standard}"
    local slice_file="/etc/systemd/system/srvctl-${sname}.slice"
    local mem_high mem_max mem_swap tasks_max
    read -r mem_high mem_max mem_swap tasks_max <<< "$(_domain_cgroups_defaults "$profile")"

    # Template varsa kullan, yoksa güvenli varsayılanlarla üret.
    if [[ -f "${SRVCTL_TEMPLATES}/cgroups/domain.slice.tpl" ]]; then
        render_template "${SRVCTL_TEMPLATES}/cgroups/domain.slice.tpl" \
            "DOMAIN=${domain}" \
            "CPU_QUOTA=100%" \
            "MEMORY_MAX=${mem_max}" \
            "MEMORY_HIGH=${mem_high}" \
            "MEMORY_SWAP_MAX=${mem_swap}" \
            "IO_READ_MAX=" \
            "IO_WRITE_MAX=" \
            "IO_WEIGHT=100" \
            "TASKS_MAX=${tasks_max}" \
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
MemoryHigh=${mem_high}
MemoryMax=${mem_max}
MemorySwapMax=${mem_swap}
TasksMax=${tasks_max}
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
    # Programatik çağrı: parolalar klon çıktısına (terminal scrollback/CI
    # logu/webhook logu) sızmasın diye _domain_add'in "Sonuç" bloğunda
    # gizlenir; gerçek parola yalnızca ${dst_base}/.credentials içinde
    # (root:600) kalır.
    _DOMAIN_ADD_QUIET_SECRETS=1 _domain_add "$dst" "--php=${src_php}"

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
        # KARAR 2: atomik/portable _sed_inplace (bkz. core.sh) — bu dosyalar
        # DB_PASSWORD/APP_KEY gibi sırlar içerir, atomik yazım önemlidir.
        [[ -f "$envf" ]] && { _sed_inplace "$envf" "s|${src}|${dst}|g" || true; }
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

    # Bakım bloğunu vhost'a idempotent ekle (KARAR 2: atomik/portable
    # _sed_inplace — bkz. core.sh — çıplak GNU-only 'sed -i' yerine).
    if ! grep -q "srvctl-maintenance-block" "$vhost"; then
        _sed_inplace "$vhost" "/server_name ${domain}/a\\
    # srvctl-maintenance-block\\
    error_page 503 @srvctl_maintenance;\\
    location @srvctl_maintenance { root ${base}/public_html; rewrite ^ /maintenance.html break; }\\
    if (-f ${base}/.suspended) { return 503; }"
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

    # HOST BULGUSU (gerçek Laravel deploy'u, Ubuntu 22.04): bu fonksiyon
    # TAMAMEN paylaşılan havuz varsayımıyla yazılmıştı ve izole domainlerde
    # "Mevcut pool bulunamadı: /etc/php/8.3/fpm/pool.d/<sname>.conf" ile
    # ölüyordu. DOMAIN_ISOLATED_FPM=true (varsayılan) ile havuz artık
    # /etc/srvctl/fpm/<sname>.conf'ta ve PHP sürümü unit'in ExecStart'ında
    # gömülü — yani İZOLE BİR DOMAİNİN PHP SÜRÜMÜ HİÇ DEĞİŞTİRİLEMİYORDU.
    # (audit ve harden-fpm'de düzelttiğimiz "eski yola bakan kod" sınıfının
    #  üçüncü örneği.)
    local isolated_unit="srvctl-fpm-${sname}.service"
    local isolated_conf="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"
    local is_isolated=false
    [[ -f "$isolated_conf" ]] && is_isolated=true

    local old_pool="/etc/php/${old_ver}/fpm/pool.d/${sname}.conf"
    local new_pool="/etc/php/${new_ver}/fpm/pool.d/${sname}.conf"
    if ! $is_isolated && [[ ! -f "$old_pool" ]]; then
        error "Mevcut pool bulunamadı: ${old_pool} (izole unit de yok: ${isolated_conf})"
    fi

    header "PHP Sürüm Değişimi: ${old_ver} → ${new_ver} (${domain})"
    $is_isolated && info "Domain izole FPM unit'inde (${isolated_unit}) — config+unit yeniden üretilecek"

    step "1/5" "Chroot kütüphaneleri (php${new_ver}-fpm)..."
    # PHP-FPM, Eklentiler (Extensions) ve Shared Libraries
    _apply_chroot_php_deps "${base}" "${new_ver}"
    success "Chroot kütüphaneleri güncellendi"

    step "2/5" "PHP-FPM pool taşınıyor..."
    if $is_isolated; then
        # Unit'i durdur → config+unit'i YENİ sürümle yeniden render et →
        # fail-closed aktive et. _domain_render_fpm_unit hem
        # /etc/srvctl/fpm/<sname>.conf'u hem systemd unit'ini (ExecStart'taki
        # php-fpm<ver> dahil) üretir; socket adı pool.conf.tpl'den geldiği için
        # otomatik olarak php<new_ver>-fpm-<sname>.sock olur.
        systemctl stop "$isolated_unit" 2>/dev/null || true
        # AppArmor profilleri ÖNCE: socket/binary yolu sürüme bağlı, profil
        # yenilenmezse yeni unit socket'i bind edemez (Permission denied).
        _domain_render_apparmor_profiles "$domain" "$new_ver" \
            || warn "AppArmor profilleri php${new_ver} için enforce edilemedi"
        _domain_render_fpm_unit "$domain" "$new_ver"
        if _domain_activate_fpm_unit "$domain"; then
            success "İzole unit yeni sürümde: ${isolated_unit} (php${new_ver})"
        else
            # Geri al: profil + config + unit'i ESKİ sürümle yeniden üret.
            warn "Yeni sürümle başlatılamadı — ${old_ver} sürümüne GERİ DÖNÜLÜYOR"
            _domain_render_apparmor_profiles "$domain" "$old_ver" || true
            _domain_render_fpm_unit "$domain" "$old_ver"
            _domain_activate_fpm_unit "$domain" \
                || warn "Geri dönüş de başarısız — 'srvctl domain repair ${domain}' çalıştırın"
            error "PHP ${new_ver} geçişi başarısız: ${domain} (php${old_ver}'te bırakıldı)"
        fi
    else
        sed "s|php${old_ver}-fpm-${sname}.sock|php${new_ver}-fpm-${sname}.sock|g" "$old_pool" > "$new_pool"
        rm -f "$old_pool"
        systemctl reload "php${old_ver}-fpm" 2>/dev/null || true
        systemctl reload "php${new_ver}-fpm" 2>/dev/null || systemctl restart "php${new_ver}-fpm"
        success "Pool: php${new_ver}-fpm-${sname}"
    fi

    step "3/5" "Seccomp hardening (yeni sürüm)..."
    _apply_seccomp_hardening "$new_ver"
    success "Seccomp uygulandı"

    step "4/5" "Nginx fastcgi_pass güncelleniyor..."
    # KARAR 2: atomik/portable _sed_inplace (bkz. core.sh).
    _sed_inplace "/etc/nginx/sites-available/${domain}.conf" \
        "s|php${old_ver}-fpm-${sname}.sock|php${new_ver}-fpm-${sname}.sock|g"
    nginx_test && systemctl reload nginx
    success "Nginx güncellendi"

    step "5/5" "Kayıt güncelleniyor..."
    # KARAR 2: .credentials SIR içerir — atomik yazım + mod/sahiplik (600
    # root:root) korunumu için _sed_inplace (çıplak 'sed -i' YERİNE).
    _sed_inplace "${base}/.credentials" "s|^PHP_VERSION=.*|PHP_VERSION=${new_ver}|"
    success "Domain artık PHP ${new_ver}"
    log_action "DOMAIN PHP-SWITCH: ${domain} (${old_ver} -> ${new_ver})"
}

# systemd bellek değeri: tamsayı + isteğe bağlı K/M/G/T soneki, ya da 'infinity'.
# (PREDİKAT: 0=geçerli 1=geçersiz; exit YOK — çağıran karar verir.)
_domain_valid_mem_value() {
    [[ "$1" == "infinity" ]] && return 0
    [[ "$1" =~ ^[0-9]+[KMGT]?$ ]]
}

# systemd CPUQuota değeri: tamsayı yüzde, sonunda '%' zorunlu (örn. 50%, 150%).
_domain_valid_cpu_value() {
    [[ "$1" =~ ^[0-9]+%$ ]]
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
    # Komşu render fonksiyonlarıyla aynı test-seam'i kullan. Sabit host yolu
    # olduğunda fonksiyon root olmayan ortamda hiçbir şey yazmadan sessizce
    # "başarılı" dönüyordu — alan-koruma regresyonu test edilemez hale geliyordu.
    local slice_path="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}/${slice}"
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

    # ─── Doğrulama — unit dosyasına yazılmadan ÖNCE ───
    # systemd'nin anlamadığı bir değer TÜM slice'ı reddedebilir (bkz.
    # .claude/ubuntu-compat.md: "bilinmeyen yönerge unit'i tamamen bozar") —
    # yani domain'in cgroups koruması sessizce düşer. Eskiden bu değerler
    # doğrulanmadan doğrudan unit dosyasına yazılıyordu.
    [[ -n "$mem" ]] && { _domain_valid_mem_value "$mem" || error "Geçersiz --memory değeri: ${mem} (örn. 512M, 1G, 50K, infinity)"; }
    [[ -n "$cpu" ]] && { _domain_valid_cpu_value "$cpu" || error "Geçersiz --cpu değeri: ${cpu} (örn. 50%, 150%)"; }
    [[ -n "$io"  ]] && { (validate_uint "$io" 10000 && [[ "$io" != "0" ]]) || error "Geçersiz --io değeri: ${io} (1-10000 arası tamsayı — IOWeight)"; }

    info "Kaynak limitleri uygulanıyor: ${domain}"

    # ─── Mevcut değerleri koru (drift düzeltmesi) ───
    # Eski davranış: slice dosyası SIFIRDAN heredoc ile yeniden yazılıyor ve
    # yalnız verilen bayraklar yazılıyordu → TasksMax/MemorySwapMax/CPUWeight/
    # IOWeight satırları SESSİZCE SİLİNİYORDU (kullanılabilirlik komutu
    # sertleştirmeyi geri alıyordu). Artık _apply_cgroups_slice ile AYNI
    # template render edilir; yalnız verilen bayraklar üzerine yazılır, geri
    # kalan anahtarlar mevcut dosyadan (yoksa _domain_cgroups_defaults'tan) korunur.
    # Varsayılan artık domain'in KENDİ kaynak profilinden (.srvctl-meta
    # RESOURCE_PROFILE) gelir — sabit değil (GÖREV 2).
    local resources_profile; resources_profile=$(_domain_read_resource_profile "$domain")
    local mem_high_def mem_max_def mem_swap_def tasks_def
    read -r mem_high_def mem_max_def mem_swap_def tasks_def <<< "$(_domain_cgroups_defaults "$resources_profile")"

    local cur_mem_max cur_mem_high cur_swap cur_tasks cur_cpu cur_io
    cur_mem_max=$(grep -m1  '^MemoryMax='      "$slice_path" 2>/dev/null | cut -d= -f2)
    cur_mem_high=$(grep -m1 '^MemoryHigh='     "$slice_path" 2>/dev/null | cut -d= -f2)
    cur_swap=$(grep -m1     '^MemorySwapMax=' "$slice_path" 2>/dev/null | cut -d= -f2)
    cur_tasks=$(grep -m1    '^TasksMax='      "$slice_path" 2>/dev/null | cut -d= -f2)
    cur_cpu=$(grep -m1      '^CPUQuota='      "$slice_path" 2>/dev/null | cut -d= -f2)
    cur_io=$(grep -m1       '^IOWeight='      "$slice_path" 2>/dev/null | cut -d= -f2)

    local mem_max mem_high
    if [[ -n "$mem" ]]; then
        # Manuel --memory override: ESKİ davranışla uyumlu — Max ve High AYNI
        # değere ayarlanır (yüksek/tepe ayrımı manuel override'da korunmaz).
        mem_max="$mem"
        mem_high="$mem"
    else
        mem_max="${cur_mem_max:-$mem_max_def}"
        mem_high="${cur_mem_high:-$mem_high_def}"
    fi
    local mem_swap="${cur_swap:-$mem_swap_def}"
    local tasks="${cur_tasks:-$tasks_def}"
    local cpu_q="${cpu:-${cur_cpu:-100%}}"
    local io_weight="${io:-${cur_io:-100}}"

    render_template "${SRVCTL_TEMPLATES}/cgroups/domain.slice.tpl" \
        "DOMAIN=${domain}" \
        "CPU_QUOTA=${cpu_q}" \
        "MEMORY_MAX=${mem_max}" \
        "MEMORY_HIGH=${mem_high}" \
        "MEMORY_SWAP_MAX=${mem_swap}" \
        "IO_READ_MAX=" \
        "IO_WRITE_MAX=" \
        "IO_WEIGHT=${io_weight}" \
        "TASKS_MAX=${tasks}" \
        > "${slice_path}.tmp"
    grep -vE 'IO(Read|Write)BandwidthMax=\s*$' "${slice_path}.tmp" > "$slice_path"
    rm -f "${slice_path}.tmp"

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

# ═══════════════════════════════════════════════════════════════
#  DOMAIN FRAMEWORK — mevcut bir domain'in framework beyanını DEĞİŞTİR
#
#  GÜVENLİK DENETİMİ EKİ (MADDE 2 — HOST'ta ölçülen KESİNTİ, Ubuntu 24.04,
#  v1.0.0→v2.0.0 yükseltmesi): v1.0.0'da 'FRAMEWORK' anahtarı hiç YOKTU; bu
#  yüzden yükseltme sonrası HİÇBİR eski domain'in '.srvctl-meta'sında bu
#  anahtar yoktu. '_domain_framework_declared' beyan yokken BOŞ döner ve
#  '_domain_disable_functions_for ""' SIKI listeyi (putenv DAHİL) uygular.
#  CodeIgniter 4'ün DotEnv sınıfı (system/Config/DotEnv.php) putenv()
#  KULLANIR, alternatifi YOKTUR — ölçülen sonuç:
#    PHP Fatal error: Uncaught Error: Call to undefined function
#    CodeIgniter\Config\putenv() ... DotEnv.php:98
#  Site geri gelsin diye '.srvctl-meta'ya ELLE 'FRAMEWORK=ci4' yazmak
#  ZORUNDA kalındı — 'domain' alt komutları arasında BUNU YAPAN bir komut
#  YOKTU (add zaten 'add' anında sorar; mevcut bir domain için beyanı
#  SONRADAN değiştirecek/düzeltecek hiçbir yol yoktu). Bu komut o boşluğu
#  kapatır.
#
#  KARAR — repair'i BURADAN OTOMATİK ÇAĞIRMA: beyan değişikliği TEK BAŞINA
#  hiçbir şeyi YENİDEN RENDER ETMEZ ('.srvctl-meta' yazmak pool.conf'u
#  değiştirmez) — pool'un 'disable_functions'ının GERÇEKTEN uygulanması için
#  'srvctl domain repair <domain>' ÇALIŞTIRILMALIDIR. Bu komut BUNU KENDİSİ
#  yapmaz (yalnız AÇIKÇA önerir): 'domain repair' PHP-FPM'i (izole unit ya da
#  paylaşılan master) YENİDEN BAŞLATIR — bir metadata komutunun operatörün
#  hiç beklemediği bir anda servis kesintisine yol açması SÜRPRİZ olur (aynı
#  'rate-limit'in nginx reload'ı GİBİ görünse de, o komut zaten sonunda
#  KENDİSİ reload ediyor çünkü rate-limit değişikliği doğrudan vhost'a
#  yazılıyor — burada ise iki ayrı komut/iki ayrı karar anı bilinçli olarak
#  AYRILDI: "beyanı değiştir" ve "servisi yeniden başlat" operatörün AYRI
#  AYRI onayladığı iki eylem olmalı).
_domain_framework() {
    local domain="${1:-}" value="${2:-}"
    if [[ -z "$domain" || -z "$value" ]]; then
        error "Kullanım: srvctl domain framework <domain> <ci4|laravel|symfony|none>"
    fi
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    case "$value" in
        ci4|laravel|symfony)
            write_meta "$domain" "FRAMEWORK" "$value"
            log_action "domain framework ${domain} → ${value}"
            success "Framework beyanı güncellendi: ${domain} → ${value}"
            if [[ "$value" == "ci4" ]]; then
                warn "GÜVENLİK ÖDÜNÜ: 'ci4' beyanı bu domain'in PHP-FPM pool'unda 'putenv' fonksiyonunu AÇAR (disable_functions listesinden ÇIKARILIR) — bkz. _domain_disable_functions_for başlık yorumu: CodeIgniter 4'ün DotEnv sınıfı putenv() olmadan boot edemez, alternatifi yoktur. Bu BİLİNÇLİ bir ödün olarak kabul edilmiştir (process-spawn primitifleri framework fark etmeksizin HER ZAMAN kapalı kalır) — domain GERÇEKTEN CI4 ÇALIŞTIRMIYORSA bu beyanı yapmayın."
            fi
            ;;
        none)
            write_meta "$domain" "FRAMEWORK" ""
            log_action "domain framework ${domain} → (temizlendi)"
            success "Framework beyanı TEMİZLENDİ: ${domain} (artık AÇIK bir beyan YOK)"
            warn "Beyan yokken 'disable_functions' SIKI listeye döner (putenv DAHİL kapalı) — domain gerçekten CI4 çalıştırıyorsa boot HATASI verebilir; bu durumda 'srvctl domain framework ${domain} ci4' ile yeniden beyan edin."
            ;;
        *)
            error "Geçersiz framework: '${value}' (ci4|laravel|symfony|none olmalı)"
            ;;
    esac

    warn "Bu beyan yalnız '.srvctl-meta'ya yazıldı — PHP-FPM pool'undaki 'disable_functions' listesinin fiilen değişmesi için YENİDEN RENDER edilmesi gerekiyor: 'srvctl domain repair ${domain}' çalıştırın. NOT: 'repair' PHP-FPM'i YENİDEN BAŞLATIR (kısa kesinti) — bu yüzden burada OTOMATİK çağrılmadı, operatör AYRI bir adımda onaylamalı."
}

# ═══════════════════════════════════════════════════════════════
#  DOMAIN WORKER / SCHEDULER — kuyruk + zamanlanmış görev yönetimi (Faz 2)
#  ops-infra şablonları: templates/systemd/srvctl-worker.service.tpl (@ instance
#  template unit), srvctl-scheduler.service.tpl (oneshot), srvctl-scheduler.timer.tpl.
# ═══════════════════════════════════════════════════════════════

# Fail-closed doğrulama: _domain_activate_fpm_unit ile AYNI sözleşme — 0=unit
# gerçekten is-active, 1=değil. Başarısızlıkta unit disable --now edilir ki
# systemd Restart=on-failure ile döngüye girmesin.
_domain_unit_verify_active() {
    local unit="$1"
    if ! systemctl is-active --quiet "$unit"; then
        warn "Unit aktif değil: ${unit}"
        systemctl status "$unit" --no-pager -l 2>/dev/null | tail -20 >&2 || true
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# Release KÖKÜ için STABİL referans (public_html'in AKSİNE 'public/' alt
# dizinine değil release köküne işaret eder — artisan/bin/console orada
# yaşar). WorkingDirectory systemd tarafından süreç başlarken BİR KEZ chdir()
# ile çözülür; bu yüzden bu isim SABİT kalmalı ve her deploy'da sembolik bağın
# HEDEFİ güncellenmelidir (bkz. rapor — deploy-specialist sözleşmesi). Bu
# symlink'in oluşturulması/güncellenmesi lib/deploy.sh'ın sorumluluğundadır;
# burada yalnızca ADI/yolu sabitlenir.
_domain_working_dir() {
    printf '%s/%s/current\n' "${WEB_ROOT}" "$1"
}

# Framework'e göre TAM worker komutunu üretir (PHP CLI mutlak yol + framework
# komutu — komut satırı argümanları WorkingDirectory'e GÖRELİ çözülür).
# Çıktı boşsa (framework worker desteklemiyor) 1 döner; warn() zaten stderr'e
# yazar (KARAR 1) — stdout çağıran tarafta $() ile temiz yakalanır.
_domain_worker_cmd() {
    local framework="$1" php_bin="$2"
    case "$framework" in
        laravel) echo "${php_bin} artisan queue:work --sleep=3 --tries=3" ;;
        symfony) echo "${php_bin} bin/console messenger:consume async" ;;
        *)
            warn "Framework '${framework}' için varsayılan worker komutu tanımlı değil (yalnız laravel/symfony destekleniyor)"
            return 1
            ;;
    esac
}

# Framework'e göre TAM scheduler komutunu üretir (bkz. _domain_worker_cmd notu).
_domain_scheduler_cmd() {
    local framework="$1" php_bin="$2"
    case "$framework" in
        laravel) echo "${php_bin} artisan schedule:run" ;;
        ci4)     echo "${php_bin} spark tasks:run" ;;
        *)
            warn "Framework '${framework}' için yerleşik scheduler komutu yok (Symfony: messenger worker'a devredilir, ci4/laravel destekleniyor)"
            return 1
            ;;
    esac
}

# Worker/scheduler render için ORTAK ön koşullar (domain var mı, PHP CLI
# binary'si kurulu mu). Çıktı: "sname web_user php_bin framework" (tek satır,
# 'read' ile parse edilir). Framework whitelist'ten geçmiş biçimde döner
# (_domain_read_framework zaten normalize eder).
_domain_unit_common_ctx() {
    local domain="$1"
    local sname; sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    local php_bin="/usr/bin/php${php_version}"
    [[ -x "$php_bin" ]] || { warn "PHP CLI bulunamadı: ${php_bin} (php${php_version}-cli kurulu mu?)"; return 1; }
    local framework; framework=$(_domain_read_framework "$domain")
    printf '%s %s %s %s\n' "$sname" "$web_user" "$php_bin" "$framework"
}

# ─── Render: worker template unit (srvctl-worker-<sname>@.service) ───
_domain_render_worker_unit() {
    local domain="$1"
    local ctx; ctx=$(_domain_unit_common_ctx "$domain") || return 1
    local sname web_user php_bin framework
    read -r sname web_user php_bin framework <<< "$ctx"

    local app_cmd; app_cmd=$(_domain_worker_cmd "$framework" "$php_bin") || return 1

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    mkdir -p "$sysd_dir"
    local unit_file="${sysd_dir}/srvctl-worker-${sname}@.service"
    # DOMAIN_ROOT: ops-infra'nın systemd sandbox'ı (ProtectSystem=strict +
    # ReadWritePaths=-{{DOMAIN_ROOT}}) domain'in TÜM ağacını (WEB_ROOT/domain —
    # current/releases/shared/logs/tmp/sessions hepsi bunun ALTINDA) yazılabilir
    # kılmayı bekler. WORKING_DIR (WEB_ROOT/domain/current) YETERSİZ — yalnız
    # release sembolik linkini kapsar, kardeş dizinleri (shared/, logs/, tmp/,
    # sessions/) KAPSAMAZ (bkz. templates/systemd/srvctl-worker.service.tpl
    # başlıktaki DALGA 5 notu). Beslenmezse render_template SESSİZCE literal
    # '{{DOMAIN_ROOT}}' bırakırdı — bu yüzden aşağıdaki guard zorunlu.
    render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-worker.service.tpl" \
        "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_USER=${web_user}" \
        "WORKING_DIR=$(_domain_working_dir "$domain")" \
        "DOMAIN_ROOT=${WEB_ROOT}/${domain}" \
        "WORKER_CMD=${app_cmd}" \
        > "$unit_file"
    _domain_assert_no_leftover_tokens "$unit_file"
    systemctl daemon-reload 2>/dev/null || true
    return 0
}

# ─── Render: scheduler unit + timer (srvctl-scheduler-<sname>.service/.timer) ───
_domain_render_scheduler_unit() {
    local domain="$1"
    local ctx; ctx=$(_domain_unit_common_ctx "$domain") || return 1
    local sname web_user php_bin framework
    read -r sname web_user php_bin framework <<< "$ctx"

    local app_cmd; app_cmd=$(_domain_scheduler_cmd "$framework" "$php_bin") || return 1

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    mkdir -p "$sysd_dir"
    local svc_file="${sysd_dir}/srvctl-scheduler-${sname}.service"
    local timer_file="${sysd_dir}/srvctl-scheduler-${sname}.timer"
    # DOMAIN_ROOT: worker unit'teki AYNI gerekçe (bkz. _domain_render_worker_unit
    # yorumu) — scheduler da ProtectSystem=strict altında domain'in TÜM
    # ağacına ReadWritePaths= ihtiyacı duyar.
    render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-scheduler.service.tpl" \
        "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_USER=${web_user}" \
        "WORKING_DIR=$(_domain_working_dir "$domain")" \
        "DOMAIN_ROOT=${WEB_ROOT}/${domain}" \
        "SCHEDULER_CMD=${app_cmd}" \
        > "$svc_file"
    _domain_assert_no_leftover_tokens "$svc_file"
    render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-scheduler.timer.tpl" \
        "DOMAIN=${domain}" "SAFE_NAME=${sname}" \
        > "$timer_file"
    _domain_assert_no_leftover_tokens "$timer_file"
    systemctl daemon-reload 2>/dev/null || true
    return 0
}

# ═══════════════════════════════════════════════
#  domain worker <domain> <start|stop|status|enable|disable> [instance]
#  instance: aynı domain için birden fazla worker'ı (ör. farklı kuyruklar)
#  paralel çalıştırmak için systemd template-unit instance adı (varsayılan:
#  'default'). Yalnız güvenli tanımlayıcı karakterleri kabul edilir (unit adı
#  enjeksiyonu/glob'dan kaçınmak için — assert_safe_ident, core.sh).
# ═══════════════════════════════════════════════
_domain_worker() {
    local domain="${1:-}" action="${2:-status}" instance="${3:-default}"
    [[ -z "$domain" ]] && error "Kullanım: srvctl domain worker <domain> <start|stop|status|enable|disable> [instance]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    assert_safe_ident "$instance" || error "Geçersiz worker instance adı: ${instance}"

    local sname; sname=$(safe_name "$domain")
    local unit="srvctl-worker-${sname}@${instance}.service"
    local unit_glob="srvctl-worker-${sname}@*.service"

    case "$action" in
        start|enable)
            require_root
            _domain_render_worker_unit "$domain" \
                || error "Worker unit render edilemedi (framework/PHP CLI kontrolü — yukarıdaki uyarıya bakın)."
            local wd; wd=$(_domain_working_dir "$domain")
            [[ -d "$wd" ]] || warn "WorkingDirectory henüz yok: ${wd} (ilk 'srvctl deploy ${domain}' bekleniyor — unit başlamayabilir)"
            # AppArmor CLI profili yüklü mü? Unit AppArmorProfile=srvctl-<sname>-cli
            # referans veriyor — yüklü değilse systemd start'ı REDDEDER (aynı
            # ön-kontrol deseni: _domain_activate_fpm_unit).
            if command -v aa-status &>/dev/null; then
                aa-status 2>/dev/null | grep -q "srvctl-${sname}-cli" \
                    || warn "AppArmor CLI profili yüklü değil: srvctl-${sname}-cli (unit başlamayacak — 'srvctl domain repair ${domain}' ile yükleyin)"
            fi
            if [[ "$action" == "enable" ]]; then
                systemctl enable --now "$unit" >/dev/null 2>&1 || true
            else
                systemctl start "$unit" >/dev/null 2>&1 || true
            fi
            _domain_unit_verify_active "$unit" || return 1
            success "Worker aktif: ${unit}"
            log_action "DOMAIN WORKER ${action}: ${domain} (${unit})"
            ;;
        stop|disable)
            require_root
            if [[ "$action" == "disable" ]]; then
                systemctl disable --now "$unit" 2>/dev/null || true
            else
                systemctl stop "$unit" 2>/dev/null || true
            fi
            success "Worker durduruldu: ${unit}"
            log_action "DOMAIN WORKER ${action}: ${domain} (${unit})"
            ;;
        status)
            systemctl status "$unit_glob" --no-pager 2>/dev/null \
                || info "Worker unit bulunamadı/aktif değil: ${unit_glob}"
            ;;
        *)
            error "Bilinmeyen eylem: ${action}. Kullanım: srvctl domain worker <domain> <start|stop|status|enable|disable> [instance]"
            ;;
    esac
}

# ═══════════════════════════════════════════════
#  domain scheduler <domain> <start|stop|status|enable|disable>
#  Aktivasyon hedefi TIMER'dır (oneshot service kendisi tetiklenip bitince
#  'inactive (dead)' görünür — is-active kontrolü bu yüzden timer'a uygulanır).
# ═══════════════════════════════════════════════
_domain_scheduler() {
    local domain="${1:-}" action="${2:-status}"
    [[ -z "$domain" ]] && error "Kullanım: srvctl domain scheduler <domain> <start|stop|status|enable|disable>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local timer="srvctl-scheduler-${sname}.timer"
    local svc="srvctl-scheduler-${sname}.service"

    case "$action" in
        start|enable)
            require_root
            _domain_render_scheduler_unit "$domain" \
                || error "Scheduler unit render edilemedi (framework/PHP CLI kontrolü — yukarıdaki uyarıya bakın)."
            local wd; wd=$(_domain_working_dir "$domain")
            [[ -d "$wd" ]] || warn "WorkingDirectory henüz yok: ${wd} (ilk 'srvctl deploy ${domain}' bekleniyor — timer tetiklendiğinde çalışmayabilir)"
            # AppArmor CLI profili yüklü mü? (bkz. _domain_worker aynı kontrol)
            if command -v aa-status &>/dev/null; then
                aa-status 2>/dev/null | grep -q "srvctl-${sname}-cli" \
                    || warn "AppArmor CLI profili yüklü değil: srvctl-${sname}-cli (unit başlamayacak — 'srvctl domain repair ${domain}' ile yükleyin)"
            fi
            if [[ "$action" == "enable" ]]; then
                systemctl enable --now "$timer" >/dev/null 2>&1 || true
            else
                systemctl start "$timer" >/dev/null 2>&1 || true
            fi
            _domain_unit_verify_active "$timer" || return 1
            success "Scheduler aktif: ${timer}"
            log_action "DOMAIN SCHEDULER ${action}: ${domain} (${timer})"
            ;;
        stop|disable)
            require_root
            if [[ "$action" == "disable" ]]; then
                systemctl disable --now "$timer" 2>/dev/null || true
            else
                systemctl stop "$timer" 2>/dev/null || true
            fi
            success "Scheduler durduruldu: ${timer}"
            log_action "DOMAIN SCHEDULER ${action}: ${domain} (${timer})"
            ;;
        status)
            systemctl status "$timer" "$svc" --no-pager 2>/dev/null \
                || info "Scheduler unit bulunamadı/aktif değil: ${timer}"
            ;;
        *)
            error "Bilinmeyen eylem: ${action}. Kullanım: srvctl domain scheduler <domain> <start|stop|status|enable|disable>"
            ;;
    esac
}
