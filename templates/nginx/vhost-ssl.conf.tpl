# TOKENS: DOMAIN SAFE_NAME WEB_ROOT PHP_VERSION RL_REQ_ZONE RL_REQ_BURST
#         RL_LOGIN_ZONE RL_LOGIN_BURST RL_CONN RL_SENSITIVE_PATHS DENY_DIRS
# Besleyen: lib/domain.sh — _domain_write_vhost (satır ~489, mode=ssl).
# RL_* değerleri rate_profile_load (core.sh) tarafından set edilir;
# RL_SENSITIVE_PATHS/DENY_DIRS önce assert_regex_safe ile doğrulanır.
#
# NOT (DALGA 6): aşağıdaki 'include .../webhook.d/{{SAFE_NAME}}/*.conf' satırı
# SAFE_NAME'i YENİDEN kullanır — YENİ bir token DEĞİL. Webhook OPT-IN'dir,
# bkz. o satırın yanındaki yorum (vhost.conf.tpl ile birebir aynı gerekçe).
server {
    listen 80;
    server_name {{DOMAIN}} www.{{DOMAIN}};
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    # ─── SSL ───
    ssl_certificate     /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;
    ssl_stapling        on;
    ssl_stapling_verify on;

    root {{WEB_ROOT}}/{{DOMAIN}}/public_html;
    index index.php index.html index.htm;

    access_log {{WEB_ROOT}}/{{DOMAIN}}/logs/access.log security;
    error_log  {{WEB_ROOT}}/{{DOMAIN}}/logs/error.log warn;

    # ─── Güvenlik ───
    disable_symlinks if_not_owner from=$document_root;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' https:; connect-src 'self' https:; frame-ancestors 'self';" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;

    # ─── Rate Limiting ───
    limit_req zone={{RL_REQ_ZONE}} burst={{RL_REQ_BURST}} nodelay;
    limit_conn conn_per_ip {{RL_CONN}};

    # ─── Hassas dosya/dizinleri engelle ───
    location ~ /\. {
        deny all;
        return 404;
    }

    location ~ \.(env|git|svn|htaccess|htpasswd|ini|log|sh|sql|bak|config|yml|yaml|toml|lock|dist)$ {
        deny all;
        return 404;
    }

    # Bağımlılık manifest dosyaları (isim-bazlı, KÖR '.json$' DEĞİL) —
    # gerekçe için vhost.conf.tpl'deki yorumu bkz.
    location ~ ^/(composer\.json|package\.json|package-lock\.json)$ {
        deny all;
        return 404;
    }

    # Uygulama dizinleri — {{DENY_DIRS}} framework beyanına göre seçilir
    # (bkz. vhost.conf.tpl yorumu).
    location ~ ^/({{DENY_DIRS}})/ {
        deny all;
        return 404;
    }

    location ~ ^/spark$ {
        deny all;
        return 404;
    }

    # ─── CI4 Rewrite ───
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # ─── PHP-FPM ───
    location ~ [^/]\.php(/|$) {
        try_files $uri =404;

        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php{{PHP_VERSION}}-fpm-{{SAFE_NAME}}.sock;
        fastcgi_index index.php;
        # NOT: php-fpm chroot'lu (chroot = WEB_ROOT/DOMAIN; docroot chroot İÇİNDE
        # /public_html). SCRIPT_FILENAME chroot-GÖRELİ olmalı — $document_root (host
        # yolu) verilirse php-fpm chroot içinde bulamaz → "No input file specified"
        # (hiçbir PHP çalışmaz). DOCUMENT_ROOT da chroot-içi yola set edilir.
        fastcgi_param SCRIPT_FILENAME /public_html$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT /public_html;
        include fastcgi_params;

        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }

    # ─── Login rate limit ───
    location ~ ^/({{RL_SENSITIVE_PATHS}}) {
        limit_req zone={{RL_LOGIN_ZONE}} burst={{RL_LOGIN_BURST}} nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }

    # ─── Statik dosyalar ───
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|eot|svg|webp|avif|mp4|webm)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
        log_not_found off;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; }

    # ─── Webhook auto-deploy (OPT-IN, DALGA 6) — bkz. vhost.conf.tpl yorumu ───
    include /etc/nginx/webhook.d/{{SAFE_NAME}}/*.conf;

    # ─── Operatör override'ları (srvctl domain nginx <domain>) ───
    # EN SONDA include ediliyor ve bu KASITLI: nginx'te regex location'lar
    # TANIM SIRASINA göre eşleşir, yani yukarıdaki deny kuralları HER ZAMAN
    # önce değerlendirilir — buraya eklenen bir regex location onları BYPASS
    # EDEMEZ. Prefix location'lar en-uzun-eşleşme ile çalıştığından meşru
    # kullanım (ör. 'location /api/') bu sıralamadan ETKİLENMEZ.
    # Glob include sıfır eşleşmeyi hatasız kabul eder (webhook.d ile aynı gerekçe).
    include /etc/nginx/custom.d/{{SAFE_NAME}}/*.conf;
}
