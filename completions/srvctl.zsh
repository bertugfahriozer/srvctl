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
                        'resources:Kaynak limitleri (cgroups)'
                        'staging:Staging ortamı oluştur'
                        'migrate:Sunucular arası taşı'
                        'rate-limit:Rate-limit profili değiştir'
                        'framework:Framework beyanını değiştir/temizle'
                        'repair:Chroot kütüphaneleri tamir et'
                        'worker:Kuyruk worker yönetimi'
                        'scheduler:Zamanlanmış görev yönetimi'
                    )
                    if [[ "${words[2]:-}" == "add" && ${#words} -ge 4 ]]; then
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
