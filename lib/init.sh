#!/bin/bash
# ═══════════════════════════════════════════════
#  init.sh — Sunucu İlk Kurulumu (tek seferlik)
#  12 güvenlik katmanını otomatik yapılandırır
# ═══════════════════════════════════════════════

cmd_init() {
    require_root

    header "srvctl init — Sunucu İlk Kurulumu"

    local total=11
    local current=0

    # ─── 1. Sistem Güncellemesi ───
    current=$((current + 1))
    step "${current}/${total}" "Sistem güncelleniyor..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        software-properties-common curl wget gnupg2 \
        unattended-upgrades apt-listchanges \
        acl auditd audispd-plugins \
        apparmor apparmor-utils \
        logrotate rsync git jq certbot \
        python3-certbot-nginx \
        > /dev/null 2>&1
    success "Sistem güncellendi ve bağımlılıklar kuruldu"

    # ─── 2. Kernel Hardening ───
    current=$((current + 1))
    step "${current}/${total}" "Kernel güvenlik ayarları..."
    cat > /etc/sysctl.d/99-srvctl-security.conf << 'SYSCTL'
# ─── Network Security ───
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
# IPv6 kapalı
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# ─── Kernel Security ───
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.sysrq = 0
# ─── Filesystem ───
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
SYSCTL
    sysctl -p /etc/sysctl.d/99-srvctl-security.conf > /dev/null 2>&1
    success "Kernel hardening uygulandı"

    # ─── 3. Process izolasyonu ───
    current=$((current + 1))
    step "${current}/${total}" "Process izolasyonu (hidepid)..."
    if ! grep -q "hidepid=2" /etc/fstab; then
        echo "proc /proc proc defaults,hidepid=2,gid=adm 0 0" >> /etc/fstab
    fi
    if ! grep -q "/run/shm.*noexec" /etc/fstab; then
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi
    mount -o remount /proc 2>/dev/null || true
    success "hidepid=2 aktif — process'ler izole"

    # ─── 4. SSH Hardening ───
    current=$((current + 1))
    step "${current}/${total}" "SSH güvenlik ayarları (Port: ${SSH_PORT})..."
    # sshd_config.d drop-in dizini bazı minimal imajlarda GELMEZ → oluştur.
    mkdir -p /etc/ssh/sshd_config.d
    # Ana sshd_config bu dizini Include etmiyorsa EN BAŞA ekle (sshd first-match-wins;
    # drop-in ana config'teki değerleri override edebilsin). Yoksa hardening yok sayılır.
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
        cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.srvctl-bak 2>/dev/null || true
        { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat /etc/ssh/sshd_config; } \
            > /etc/ssh/sshd_config.srvctl-tmp && mv /etc/ssh/sshd_config.srvctl-tmp /etc/ssh/sshd_config
    fi
    cat > /etc/ssh/sshd_config.d/99-srvctl.conf << SSHCONF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSHCONF
    # Restart ÖNCESİ config'i doğrula: hatalı sshd config'iyle restart edip
    # kendini kilitlemeyi önle. Doğrulama başarısızsa drop-in'i geri al.
    if sshd -t 2>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        success "SSH hardening uygulandı (Port: ${SSH_PORT})"
    else
        rm -f /etc/ssh/sshd_config.d/99-srvctl.conf
        warn "sshd config doğrulaması BAŞARISIZ — SSH hardening atlandı, mevcut SSH korundu"
    fi

    # ─── 5. Firewall ───
    current=$((current + 1))
    step "${current}/${total}" "Firewall (UFW)..."
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' > /dev/null 2>&1
    ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
    ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1
    ufw limit "${SSH_PORT}/tcp" > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    success "UFW aktif — sadece ${SSH_PORT}, 80, 443 açık"

    # ─── 6. Nginx ───
    current=$((current + 1))
    step "${current}/${total}" "Nginx kuruluyor..."
    _install_nginx
    success "Nginx kuruldu ve yapılandırıldı"

    # ─── 7. PHP-FPM ───
    current=$((current + 1))
    step "${current}/${total}" "PHP-FPM kuruluyor..."
    _install_php
    success "PHP-FPM kuruldu"

    # ─── 8. MariaDB ───
    current=$((current + 1))
    step "${current}/${total}" "MariaDB kuruluyor..."
    _install_mariadb
    success "MariaDB kuruldu ve güvenlik ayarları yapıldı"

    # ─── 9. Redis ───
    current=$((current + 1))
    step "${current}/${total}" "Redis kuruluyor..."
    _install_redis
    success "Redis kuruldu (ACL aktif)"

    # ─── 10. Fail2Ban + auditd ───
    current=$((current + 1))
    step "${current}/${total}" "Fail2Ban + auditd kuruluyor..."
    _install_fail2ban
    _install_auditd
    _setup_cron_jobs
    _create_deployer_user
    success "Fail2Ban + auditd aktif"

    # ─── 11. Gelişmiş Güvenlik Katmanları ───
    current=$((current + 1))
    step "${current}/${total}" "Gelişmiş güvenlik (cgroups, ModSecurity, AIDE, ClamAV, GeoIP)..."
    _setup_cgroups
    _install_modsecurity
    _install_aide
    _install_clamav
    _install_geoip
    success "Gelişmiş güvenlik katmanları kuruldu"

    # ─── Dizinler ───
    mkdir -p "${WEB_ROOT}" "${SRVCTL_ROOT}/logs"
    # Yedek dizini sır içerir → 0700 root:root
    secure_dir "${BACKUP_DIR}" 700

    # ─── Otomatik güvenlik güncellemeleri ───
    dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true

    header "✅ Sunucu Kurulumu Tamamlandı!"

    echo "  SSH Port:        ${SSH_PORT}"
    echo "  MariaDB root:    /root/.my.cnf"
    echo "  Redis admin:     ${SRVCTL_CONF}"
    echo "  Web root:        ${WEB_ROOT}"
    echo "  Yedek dizini:    ${BACKUP_DIR}"
    echo ""
    echo -e "  ${BOLD}Sonraki adım:${NC}  sudo srvctl domain add <domain.com>"
    echo ""

    log_action "INIT completed successfully"
}

# ═══════════════════════════════════════════════
#  HELPER FONKSİYONLAR
# ═══════════════════════════════════════════════

# Rate-limit kademe zone'larını üret (http context — conf.d include için).
# conn_per_ip zone'u nginx.conf'ta tanımlı olduğundan burada tekrar edilmez.
render_ratelimit_zones() {
    cat << 'RLZONES'
# srvctl — rate-limit kademe zone'ları (otomatik üretildi, elle düzenlemeyin)
limit_req_zone $binary_remote_addr zone=rl_strict:10m rate=3r/s;
limit_req_zone $binary_remote_addr zone=rl_standard:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=rl_relaxed:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=rl_api:10m rate=60r/s;
limit_req_zone $binary_remote_addr zone=login_strict:10m rate=3r/m;
limit_req_zone $binary_remote_addr zone=login_standard:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=login_relaxed:10m rate=10r/m;
limit_req_status 429;
limit_conn_status 429;
RLZONES
}

_install_nginx() {
    # Nginx'in kurulu olup olmadığını kontrol et
    if ! command -v nginx &>/dev/null; then
        apt-get install -y -qq nginx > /dev/null 2>&1
    fi

    # Ana yapılandırma
    cat > /etc/nginx/nginx.conf << 'NGINXCONF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

# Dinamik modülleri yükle (ModSecurity, GeoIP vb.) — paketlerin
# /etc/nginx/modules-enabled/ altına bıraktığı load_module conf'ları. Bu satır
# olmadan 'modsecurity'/'geoip_country' direktifleri "unknown directive" verip
# nginx -t'yi patlatır (domain add step 5'te abort). Stok Ubuntu nginx.conf'ta var.
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # ─── Temel ───
    server_names_hash_bucket_size 128;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    client_max_body_size 50M;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ─── Log Format ───
    log_format security '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent" '
                        '$request_time $upstream_response_time';

    access_log /var/log/nginx/access.log security;
    error_log /var/log/nginx/error.log warn;

    # ─── Gzip ───
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml application/font-woff2;

    # ─── Rate Limiting ───
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;

    # ─── SSL ───
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ─── Symlink Koruması ───
    disable_symlinks if_not_owner;

    # ─── Bilinmeyen Domain Reddet ───
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
NGINXCONF

    # Kademe rate-limit zone'larını conf.d'ye yaz (nginx -t öncesi)
    mkdir -p /etc/nginx/conf.d
    render_ratelimit_zones > /etc/nginx/conf.d/00-srvctl-ratelimit.conf

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    # Varsayılan site'ı kaldır
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/default.conf

    systemctl enable nginx > /dev/null 2>&1
    nginx -t 2>/dev/null && systemctl restart nginx
}

_install_php() {
    # Ondrej PPA
    if [[ ! -f /etc/apt/sources.list.d/ondrej-*.list ]] && ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
        apt-get update -qq
    fi

    # PHP versiyonlarını kur
    for ver in 8.2 8.3 8.4; do
        if ! php_version_exists "$ver"; then
            apt-get install -y -qq \
                "php${ver}-fpm" "php${ver}-cli" "php${ver}-mysql" "php${ver}-redis" \
                "php${ver}-curl" "php${ver}-gd" "php${ver}-mbstring" "php${ver}-xml" \
                "php${ver}-zip" "php${ver}-intl" "php${ver}-bcmath" "php${ver}-opcache" \
                "php${ver}-readline" "php${ver}-soap" \
                > /dev/null 2>&1 || warn "PHP ${ver} kurulumunda bazı paketler atlandı"
        fi

        # Kurulmadıysa (örn. Ubuntu 24.04 default repo'da php8.2 YOK — ondrej PPA
        # gerekir; PPA eklenemezse apt atlar) bu sürümü atla. Aksi halde alttaki
        # 'cat > /etc/php/${ver}/...' dizin yokluğunda set -e ile init'i patlatır.
        [[ -d "/etc/php/${ver}/fpm/conf.d" ]] || { warn "PHP ${ver} kurulu değil — atlanıyor"; continue; }

        # PHP güvenlik ayarları
        cat > "/etc/php/${ver}/fpm/conf.d/99-srvctl-security.ini" << 'PHPINI'
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,proc_close,proc_get_status,proc_nice,proc_terminate,pcntl_alarm,pcntl_exec,pcntl_fork,pcntl_get_last_error,pcntl_getpriority,pcntl_setpriority,pcntl_signal,pcntl_signal_dispatch,pcntl_strerror,pcntl_wait,pcntl_waitpid,pcntl_wexitstatus,pcntl_wifexited,pcntl_wifsignaled,pcntl_wifstopped,pcntl_wstopsig,pcntl_wtermsig,dl,putenv,show_source,highlight_file
file_uploads = On
upload_max_filesize = 50M
post_max_size = 55M
max_file_uploads = 10
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
session.cookie_samesite = Strict
session.use_only_cookies = 1
session.name = __Secure_SID
session.gc_maxlifetime = 3600
max_execution_time = 60
max_input_time = 60
memory_limit = 256M
max_input_vars = 5000
allow_url_fopen = Off
allow_url_include = Off
cgi.fix_pathinfo = 0
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.save_comments = 1
PHPINI

        # Varsayılan www pool'unu devre dışı bırak
        if [[ -f "/etc/php/${ver}/fpm/pool.d/www.conf" ]]; then
            mv "/etc/php/${ver}/fpm/pool.d/www.conf" "/etc/php/${ver}/fpm/pool.d/www.conf.disabled" 2>/dev/null || true
        fi

        systemctl enable "php${ver}-fpm" > /dev/null 2>&1
        systemctl restart "php${ver}-fpm" 2>/dev/null || true
    done
}

_install_mariadb() {
    if ! command -v mysql &>/dev/null; then
        apt-get install -y -qq mariadb-server mariadb-client > /dev/null 2>&1
    fi

    # Güvenlik yapılandırması
    cat > /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf << 'MARIADB'
[mysqld]
bind-address = 127.0.0.1
local-infile = 0
symbolic-links = 0
secure-file-priv = /var/lib/mysql-files
log_error = /var/log/mysql/error.log
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
max_connections = 200
thread_cache_size = 16
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
MARIADB

    mkdir -p /var/lib/mysql-files
    systemctl enable mariadb > /dev/null 2>&1
    systemctl restart mariadb

    # Root şifresi ayarla
    local root_pass
    root_pass=$(generate_password 32)

    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    # Root credentials dosyası (umask 077 + 0600 root:root)
    (
        umask 077
        cat > /root/.my.cnf << MYCNF
[client]
user=root
password=${root_pass}
MYCNF
    )
    secure_file /root/.my.cnf 600

    info "MariaDB root şifresi: /root/.my.cnf"
}

_install_redis() {
    if ! command -v redis-server &>/dev/null; then
        apt-get install -y -qq redis-server > /dev/null 2>&1
    fi

    local redis_admin_pass
    redis_admin_pass=$(generate_password 32)

    # Redis yapılandırması
    cat > /etc/redis/redis.conf << REDISCONF
# ─── Ağ ───
bind 127.0.0.1
port 6379
protected-mode yes
tcp-backlog 511
timeout 300
tcp-keepalive 300

# ─── ACL ───
aclfile /etc/redis/users.acl

# ─── Tehlikeli Komutları Devre Dışı Bırak ───
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
rename-command DEBUG ""
rename-command KEYS ""

# ─── Memory ───
maxmemory 512mb
maxmemory-policy allkeys-lru

# ─── Persistence ───
save 900 1
save 300 10
save 60 10000
dir /var/lib/redis
dbfilename dump.rdb

# ─── Logging ───
loglevel notice
logfile /var/log/redis/redis-server.log
REDISCONF

    # ACL dosyası (umask 077 — parola world-readable olmasın)
    (
        umask 077
        # NOT: aclfile YORUM (#) ve boş satır KABUL ETMEZ (redis "should start with
        # user keyword" ile başlatmayı iptal eder). Yalnız 'user ...' satırları yaz.
        cat > /etc/redis/users.acl << REDISACL
user admin on >${redis_admin_pass} ~* &* +@all
user default off nopass ~* &* -@all
REDISACL
    )
    # redis.conf sır içermez (0640); users.acl parola taşır (0600), sahibi redis daemon
    chmod 640 /etc/redis/redis.conf
    chmod 600 /etc/redis/users.acl
    chown redis:redis /etc/redis/redis.conf /etc/redis/users.acl

    # Admin şifresini restart'tan ÖNCE kaydet: 'systemctl restart' set -e altında
    # non-zero dönerse (systemd notify timing) parola conf'a yazılmadan kaybolmasın
    # → domain add redis ACL adımı WRONGPASS ile patlıyordu.
    # ANCHOR şart: conf'ta '# REDIS_ADMIN_PASS=' yorum placeholder'ı var. Anchorsuz
    # grep yorumu yakalar → sed '^REDIS_ADMIN_PASS=' ile eşleşmez → no-op → parola
    # hiç yazılmaz → domain add redis ACL WRONGPASS. Yalnız AKTİF atamayı eşle.
    if grep -q "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null; then
        sed -i "s|^REDIS_ADMIN_PASS=.*|REDIS_ADMIN_PASS=${redis_admin_pass}|" "${SRVCTL_CONF}"
    else
        echo "REDIS_ADMIN_PASS=${redis_admin_pass}" >> "${SRVCTL_CONF}"
    fi

    systemctl enable redis-server > /dev/null 2>&1
    systemctl restart redis-server

    info "Redis admin şifresi: ${SRVCTL_CONF}"
}

_install_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        apt-get install -y -qq fail2ban > /dev/null 2>&1
    fi

    cat > /etc/fail2ban/jail.local << FAIL2BAN
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 3
bantime = 86400

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-botsearch]
enabled = true
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2

[nginx-req-limit]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 5
FAIL2BAN

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
}

_install_auditd() {
    cat > /etc/audit/rules.d/99-srvctl.rules << 'AUDIT'
# srvctl audit kuralları
-w /var/www/ -p wa -k web_changes
-w /etc/nginx/ -p wa -k nginx_config
-w /etc/php/ -p wa -k php_config
-w /etc/mysql/ -p wa -k mysql_config
-w /etc/redis/ -p wa -k redis_config
-w /etc/sudoers -p wa -k sudoers_change
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
-w /etc/ssh/ -p wa -k ssh_config
-w /usr/local/srvctl/ -p wa -k srvctl_config
AUDIT

    systemctl enable auditd > /dev/null 2>&1
    systemctl restart auditd 2>/dev/null || true
}

_setup_cron_jobs() {
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null || true)

    # SSL yenileme (günde 2 kez)
    if ! echo "$crontab_content" | grep -q "certbot renew"; then
        (echo "$crontab_content"; echo "0 3,15 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx' >> /usr/local/srvctl/logs/ssl.log 2>&1") | crontab -
    fi

    # Günlük yedekleme
    crontab_content=$(crontab -l 2>/dev/null || true)
    if ! echo "$crontab_content" | grep -q "srvctl backup"; then
        (echo "$crontab_content"; echo "0 4 * * * /usr/local/srvctl/bin/srvctl backup run >> /usr/local/srvctl/logs/backup.log 2>&1") | crontab -
    fi

    # ─── Güvenilir edge-IP senkronu (Cloudflare + UptimeRobot) ───
    if [[ "${TRUSTED_SYNC_ENABLED:-true}" == "true" ]]; then
        crontab_content=$(crontab -l 2>/dev/null || true)
        if ! echo "$crontab_content" | grep -q "srvctl trusted sync"; then
            (echo "$crontab_content"; echo "30 2 * * * /usr/local/srvctl/bin/srvctl trusted sync >> /usr/local/srvctl/logs/trusted.log 2>&1") | crontab -
        fi
        # İlk senkron (ağ yoksa uyar-devam; init'i düşürme)
        # shellcheck disable=SC1090
        if source "${SRVCTL_ROOT}/lib/trusted.sh" 2>/dev/null && _trusted_sync >/dev/null 2>&1; then
            success "Güvenilir edge-IP listesi senkronize edildi"
        else
            warn "İlk güvenilir-IP senkronu yapılamadı (ağ?) — cron sonraki turda tazeleyecek"
        fi
    fi
}

_create_deployer_user() {
    if ! id "${DEPLOYER_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${DEPLOYER_USER}"
        mkdir -p "/home/${DEPLOYER_USER}/.ssh"
        chmod 700 "/home/${DEPLOYER_USER}/.ssh"
        chown -R "${DEPLOYER_USER}:${DEPLOYER_USER}" "/home/${DEPLOYER_USER}/.ssh"

        # Sudo izinleri (sadece reload)
        cat > "/etc/sudoers.d/${DEPLOYER_USER}" << SUDOERS
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php*-fpm
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl deploy *
SUDOERS
        chmod 440 "/etc/sudoers.d/${DEPLOYER_USER}"

        info "Deployer kullanıcısı: ${DEPLOYER_USER}"
        warn "SSH key ekleyin: /home/${DEPLOYER_USER}/.ssh/authorized_keys"
    fi
}
# ═══════════════════════════════════════════════════════════════
#  init.sh — EK BLOK (Faz 1: Gelişmiş Güvenlik Katmanları)
#
#  Bu blok mevcut lib/init.sh dosyanızın SONUNA eklenir.
#  cmd_init() içine bir "step 11" eklenmeli (bkz. INTEGRATION.md):
#
#      current=$((current + 1))
#      step "${current}/${total}" "Gelişmiş güvenlik katmanları..."
#      _setup_cgroups
#      _install_modsecurity
#      _install_aide
#      _install_clamav
#      _install_geoip
#      success "Gelişmiş güvenlik katmanları kuruldu"
#
#  ...ve cmd_init başındaki  total=10  →  total=11  yapılmalı.
# ═══════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  cgroups v2 — parent slice + doğrulama
# ───────────────────────────────────────────────────────────────
_setup_cgroups() {
    # Ubuntu 22.04 varsayılan olarak cgroups v2 kullanır
    if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        warn "cgroups v2 aktif değil — GRUB'a systemd.unified_cgroup_hierarchy=1 ekleyin"
    fi

    # Parent slice (per-domain srvctl-*.slice bunun altına girer)
    cat > /etc/systemd/system/srvctl.slice << 'SLICE'
[Unit]
Description=srvctl domain resource parent slice
Before=slices.target

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes
SLICE

    systemctl daemon-reload 2>/dev/null || true
    systemctl start srvctl.slice 2>/dev/null || true
}

# ───────────────────────────────────────────────────────────────
#  ModSecurity v3 + OWASP Core Rule Set (nginx connector)
# ───────────────────────────────────────────────────────────────
_install_modsecurity() {
    # nginx ModSecurity connector
    apt-get install -y -qq libnginx-mod-http-modsecurity 2>/dev/null \
        || { warn "libnginx-mod-http-modsecurity bulunamadı — ModSecurity atlanıyor"; return; }

    mkdir -p /etc/nginx/modsec /tmp/modsecurity/{tmp,data,upload}
    chown -R www-data:www-data /tmp/modsecurity 2>/dev/null || true

    # Önerilen temel modsecurity.conf (paketle gelir)
    if [[ -f /etc/modsecurity/modsecurity.conf-recommended ]]; then
        cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
        sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf
    fi

    # unicode.mapping
    [[ -f /usr/share/modsecurity-crs/unicode.mapping ]] && \
        cp /usr/share/modsecurity-crs/unicode.mapping /etc/nginx/modsec/ 2>/dev/null || true

    # OWASP CRS indir
    if [[ ! -d /etc/nginx/owasp-crs ]]; then
        git clone --depth 1 https://github.com/coreruleset/coreruleset /etc/nginx/owasp-crs 2>/dev/null \
            || warn "OWASP CRS indirilemedi (git/erişim)"
    fi
    [[ -f /etc/nginx/owasp-crs/crs-setup.conf.example ]] && \
        cp -n /etc/nginx/owasp-crs/crs-setup.conf.example /etc/nginx/owasp-crs/crs-setup.conf 2>/dev/null || true

    # srvctl ana WAF yapılandırması (template'ten)
    if [[ -f "${SRVCTL_TEMPLATES}/nginx/modsecurity.conf.tpl" ]]; then
        cp "${SRVCTL_TEMPLATES}/nginx/modsecurity.conf.tpl" /etc/nginx/modsec/main.conf
    else
        cat > /etc/nginx/modsec/main.conf << 'MODSEC'
Include /etc/nginx/modsec/modsecurity.conf
Include /etc/nginx/owasp-crs/crs-setup.conf
Include /etc/nginx/owasp-crs/rules/*.conf
MODSEC
    fi

    # nginx.conf http bloğuna modsecurity aç (idempotent)
    if ! grep -q "modsecurity on" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/include \/etc\/nginx\/sites-enabled/i\    modsecurity on;\n    modsecurity_rules_file /etc/nginx/modsec/main.conf;' \
            /etc/nginx/nginx.conf 2>/dev/null || true
    fi

    # load_module satırı (mod paketleri genelde /etc/nginx/modules-enabled altına ekler)
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null \
        || warn "ModSecurity sonrası nginx -t başarısız — /etc/nginx/modsec/ kontrol edin"
}

# ───────────────────────────────────────────────────────────────
#  AIDE — Dosya bütünlük kontrolü
# ───────────────────────────────────────────────────────────────
_install_aide() {
    if ! command -v aide &>/dev/null; then
        apt-get install -y -qq aide aide-common 2>/dev/null \
            || { warn "AIDE kurulamadı — atlanıyor"; return; }
    fi

    # İlk veritabanını arka planda oluştur (uzun sürebilir)
    if [[ ! -f /var/lib/aide/aide.db.gz && ! -f /var/lib/aide/aide.db ]]; then
        info "AIDE veritabanı oluşturuluyor (arka planda)..."
        ( aideinit -y -f 2>/dev/null || aide --init 2>/dev/null
          [[ -f /var/lib/aide/aide.db.new.gz ]] && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
        ) &
    fi

    # Günlük bütünlük kontrolü cron'u
    local cron; cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$cron" | grep -q "aide --check"; then
        (echo "$cron"; echo "30 5 * * * aide --check >> /usr/local/srvctl/logs/aide.log 2>&1") | crontab -
    fi
}

# ───────────────────────────────────────────────────────────────
#  ClamAV — Antivirüs (upload taraması)
# ───────────────────────────────────────────────────────────────
_install_clamav() {
    if ! command -v clamscan &>/dev/null; then
        apt-get install -y -qq clamav clamav-daemon 2>/dev/null \
            || { warn "ClamAV kurulamadı — atlanıyor"; return; }
    fi

    # İmza veritabanını güncelle
    systemctl stop clamav-freshclam 2>/dev/null || true
    freshclam 2>/dev/null || warn "freshclam güncellemesi başarısız (sonra tekrar deneyin)"
    systemctl start clamav-freshclam 2>/dev/null || true
    systemctl enable clamav-daemon 2>/dev/null || true
    systemctl start clamav-daemon 2>/dev/null || true

    # Günlük upload tarama cron'u (tüm domain uploads dizinleri)
    local cron; cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$cron" | grep -q "clamscan"; then
        (echo "$cron"; echo "0 6 * * * clamscan -ri --quiet ${WEB_ROOT} >> /usr/local/srvctl/logs/clamav.log 2>&1") | crontab -
    fi
}

# ───────────────────────────────────────────────────────────────
#  GeoIP — Ülke bazlı engelleme veritabanı (ip.sh geoblock için)
# ───────────────────────────────────────────────────────────────
_install_geoip() {
    apt-get install -y -qq libnginx-mod-http-geoip geoip-database geoip-bin 2>/dev/null \
        || { warn "GeoIP paketleri bulunamadı — geoblock kısıtlı çalışır"; return; }

    # nginx http bloğuna GeoIP veritabanı yolu (idempotent)
    if [[ -f /usr/share/GeoIP/GeoIP.dat ]] && ! grep -q "geoip_country" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/include \/etc\/nginx\/sites-enabled/i\    geoip_country /usr/share/GeoIP/GeoIP.dat;' \
            /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
}
