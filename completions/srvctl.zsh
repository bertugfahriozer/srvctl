#compdef srvctl
# ═══════════════════════════════════════════════
#  srvctl Zsh Auto-Completion
#  Kurulum: cp completions/srvctl.zsh /usr/share/zsh/vendor-completions/_srvctl
# ═══════════════════════════════════════════════

_srvctl() {
    local -a commands
    commands=(
        'init:Sunucu ilk kurulumu'
        'domain:Domain yönetimi'
        'cron:Kullanıcı dostu cron (systemd timer)'
        'deploy:Zero-downtime deploy'
        'backup:Yedekleme ve geri yükleme'
        'ssl:SSL sertifika yönetimi'
        'security:Güvenlik denetimi'
        'status:Sunucu durum özeti'
        'monitor:İzleme ve alarmlar'
        'notify:Bildirim yapılandırması'
        'cloudflare:Cloudflare API'
        'ip:IP engelleme/izin listesi'
        'trusted:Güvenilir edge IP senkronizasyonu'
        'user:Kullanıcı yönetimi (RBAC)'
        'plugin:Plugin sistemi'
        'webhook:Auto-deploy webhook'
        'changelog:Değişiklik kaydı'
        'version:Versiyon bilgisi'
        'help:Yardım'
    )

    _arguments -C \
        '1: :->command' \
        '*:: :->args'

    case "$state" in
        command)
            _describe 'srvctl komutu' commands
            ;;
        args)
            case "${words[1]}" in
                domain)
                    local -a domain_cmds
                    domain_cmds=(
                        'add:Yeni domain ekle'
                        'remove:Domain kaldır'
                        'list:Tüm domainleri listele'
                        'info:Domain detay bilgisi'
                        'clone:Domain klonla'
                        'suspend:Bakım moduna al'
                        'unsuspend:Bakım modundan çıkar'
                        'php-switch:PHP versiyonu değiştir'
                        'resources:Kaynak limitleri (cgroups) — --reset ile profile döner'
                        'reload:PHP-FPM + nginx reload (doğru unit otomatik bulunur)'
                        'ini:Domaine özel PHP ayarları (sudo -E)'
                        'nginx:Domaine özel nginx ayarları (sudo -E)'
                        'open-basedir:open_basedir aç/kapat (kapalı = sınır chroot)'
                        'staging:Staging ortamı oluştur'
                        'migrate:Sunucular arası taşı'
                        'rate-limit:Rate-limit profili değiştir'
                        'framework:Framework beyanını değiştir/temizle'
                        'repair:Chroot kütüphaneleri tamir et'
                        'worker:Kuyruk worker yönetimi'
                        'scheduler:Zamanlanmış görev yönetimi'
                    )
                    if [[ "${words[2]:-}" == "reload" && ${#words} -ge 4 ]]; then
                        local -a reload_flags
                        reload_flags=(
                            '--all:Tüm domainler (hatada durmaz, sonda özetler)'
                            '--fpm:Yalnız PHP-FPM'
                            '--nginx:Yalnız nginx'
                        )
                        _describe 'domain reload seçeneği' reload_flags
                    elif [[ "${words[2]:-}" == "resources" && ${#words} -ge 4 ]]; then
                        local -a res_flags
                        res_flags=(
                            '--memory=:Bellek TAVANI (High/SwapMax ondan türetilir)'
                            '--cpu=:CPUQuota (ör. 200%)'
                            '--io=:IOWeight (1-10000)'
                            '--reset:Bellek üçlüsü + TasksMax profile döner (CPU/IO korunur)'
                            '--show:Yürürlükteki limitleri göster'
                        )
                        _describe 'domain resources seçeneği' res_flags
                    elif [[ "${words[2]:-}" == "open-basedir" && ${#words} -ge 4 ]]; then
                        local -a ob_flags
                        ob_flags=(
                            'on:Şablon varsayılanına dön (open_basedir yürürlükte)'
                            'off:Ayarı tamamen kaldır — sınır chroot olarak kalır'
                            '--all:Tüm domainler (hatada durmaz, sonda özetler)'
                            '--show:Durumu listele, değişiklik yapma'
                        )
                        _describe 'domain open-basedir seçeneği' ob_flags
                    elif [[ ( "${words[2]:-}" == "ini" || "${words[2]:-}" == "nginx" ) && ${#words} -ge 4 ]]; then
                        local -a conf_flags
                        conf_flags=(
                            '--show:İçeriği göster, düzenleme'
                            '--file=:İçeriği bu dosyadan al (editör açma)'
                            '--force:İzolasyonu delen ayarı yine de uygula (loglanır)'
                        )
                        _describe 'seçenek' conf_flags
                    elif [[ "${words[2]:-}" == "add" && ${#words} -ge 4 ]]; then
                        local -a add_flags
                        add_flags=(
                            '--php=:PHP versiyonu (ör. 8.3)'
                            '--rate=:Rate-limit profili'
                            '--sensitive=:Hassas path listesi'
                            '--framework=:Framework (ci4|laravel|symfony)'
                            '--resources=:Kaynak profili (micro|standard|ecommerce|heavy)'
                            '--no-ssl:SSL kurulumunu atla'
                            '--redis-queue:Redis EVAL/Lua scripting AÇIKÇA iste (Laravel kuyruk/Horizon; Redis 7+ gerekir, bayraksız HER ZAMAN kapalı)'
                        )
                        _describe 'domain add seçeneği' add_flags
                    elif [[ "${words[2]:-}" == "framework" && ${#words} -ge 4 ]]; then
                        local -a framework_values
                        framework_values=(
                            'ci4:CodeIgniter 4 (putenv AÇIK — bilinçli güvenlik ödünü)'
                            'laravel:Laravel'
                            'symfony:Symfony'
                            'none:Beyanı temizle (sıkı disable_functions listesine dön)'
                        )
                        _describe 'framework değeri' framework_values
                    else
                        _describe 'domain işlemi' domain_cmds
                    fi
                    ;;
                cron)
                    local -a cron_cmds
                    cron_cmds=(
                        'add:Yeni cron görevi ekle'
                        'list:Cron görevlerini listele'
                        'show:Cron detay bilgisi'
                        'run:Şimdi bir kez çalıştır (test)'
                        'enable:Etkinleştir'
                        'disable:Devre dışı bırak'
                        'remove:Cron görevini kaldır'
                        'logs:Cron loglarını göster'
                    )
                    if [[ "${words[2]:-}" == "add" && ${#words} -ge 4 ]]; then
                        local -a cron_add_flags
                        cron_add_flags=(
                            '--name=:Cron adı (harf/rakam/alt çizgi)'
                            '--schedule=:Zamanlama (Türkçe kısayol|cron sözdizimi|ham systemd)'
                            '--command=:Çalıştırılacak komut'
                            '--description=:Açıklama'
                            '--timeout=:Azami çalışma süresi (sn)'
                            '--catch-up-on-boot:Kaçan çalışmayı açılışta telafi et'
                            '--utc:Zamanlamayı UTC'\''ye sabitle (varsayılan: sunucu yerel saati)'
                        )
                        _describe 'cron add seçeneği' cron_add_flags
                    else
                        _describe 'cron işlemi' cron_cmds
                        _srvctl_domains
                    fi
                    ;;
                deploy)
                    local -a deploy_cmds
                    deploy_cmds=(
                        'rollback:Bir önceki sürüme dön'
                        'health:Sağlık kontrolü çalıştır'
                        'list:Release’leri listele'
                        'prune:Eski release’leri temizle (varsayılan dry-run)'
                    )
                    _describe 'deploy işlemi' deploy_cmds
                    _srvctl_domains
                    ;;
                backup)
                    local -a backup_cmds
                    backup_cmds=('run:Yedekleme çalıştır' 'list:Yedekleri listele' 'restore:Geri yükle')
                    _describe 'backup işlemi' backup_cmds
                    ;;
                ssl)
                    local -a ssl_cmds
                    ssl_cmds=('renew:Sertifikaları yenile' 'status:Sertifika durumları')
                    _describe 'ssl işlemi' ssl_cmds
                    ;;
                security)
                    local -a security_cmds
                    security_cmds=(
                        'audit:Tam güvenlik denetimi'
                        'harden-fs:Dosya-sahiplik modelini uygula/önizle'
                        'harden-fpm:Per-domain FPM unit oluştur/uygula'
                    )
                    _describe 'güvenlik işlemi' security_cmds
                    ;;
                monitor)
                    local -a mon_cmds
                    mon_cmds=('live:Canlı izleme' 'domains:Domain kaynakları' 'uptime:Uptime kontrolü' 'check:Durum kontrolü' 'traffic:Trafik analizi')
                    _describe 'monitor işlemi' mon_cmds
                    ;;
                cloudflare)
                    local -a cf_cmds
                    cf_cmds=('setup:API yapılandır' 'dns:DNS yönetimi' 'purge:Cache temizle' 'waf:WAF kontrol' 'ddos:DDoS koruması' 'status:Domain durumu')
                    _describe 'cloudflare işlemi' cf_cmds
                    ;;
                ip)
                    local -a ip_cmds
                    ip_cmds=('ban:IP engelle' 'unban:Engel kaldır' 'whitelist:Beyaz liste' 'blacklist:Kara liste' 'list:Listele' 'geoblock:Ülke engeli' 'reapply:Kuralları yeniden uygula')
                    _describe 'ip işlemi' ip_cmds
                    ;;
                trusted)
                    local -a trusted_cmds
                    trusted_cmds=('sync:Senkronize et' 'list:Güvenilir IPleri listele')
                    _describe 'trusted işlemi' trusted_cmds
                    ;;
                user)
                    local -a user_cmds
                    user_cmds=('add:Kullanıcı ekle' 'remove:Kullanıcı sil' 'list:Listele' 'info:Detay' 'grant:Erişim ver' 'revoke:Erişim kaldır' 'key:SSH key' '2fa:İki faktörlü doğrulama' 'audit:İşlem geçmişi')
                    _describe 'user işlemi' user_cmds
                    ;;
                plugin)
                    local -a plugin_cmds
                    plugin_cmds=('install:Plugin kur' 'remove:Plugin kaldır' 'list:Listele' 'enable:Aktifleştir' 'disable:Devre dışı bırak' 'create:Yeni plugin oluştur')
                    _describe 'plugin işlemi' plugin_cmds
                    ;;
                webhook)
                    local -a wh_cmds
                    wh_cmds=('start:Başlat' 'stop:Durdur' 'status:Durum' 'setup:Yapılandır')
                    _describe 'webhook işlemi' wh_cmds
                    ;;
                changelog)
                    local -a cl_cmds
                    cl_cmds=('show:Göster' 'tail:Canlı takip' 'search:Ara' 'export:Dışa aktar')
                    _describe 'changelog işlemi' cl_cmds
                    ;;
            esac
            ;;
    esac
}

_srvctl_domains() {
    local web_root="/var/www"
    if [[ -d "$web_root" ]]; then
        local -a domains
        domains=(${(f)"$(find "$web_root" -maxdepth 1 -type d ! -name "$(basename "$web_root")" -printf "%f\n" 2>/dev/null)"})
        _describe 'domain' domains
    fi
}

_srvctl
