server {
    listen 80;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    root {{WEB_ROOT}}/{{DOMAIN}}/public_html;
    index index.php index.html index.htm;

    access_log {{WEB_ROOT}}/{{DOMAIN}}/logs/access.log security;
    error_log  {{WEB_ROOT}}/{{DOMAIN}}/logs/error.log warn;

    # ─── Güvenlik ───
    disable_symlinks if_not_owner from=$document_root;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;

    # ─── Rate Limiting ───
    limit_req zone={{RL_REQ_ZONE}} burst={{RL_REQ_BURST}} nodelay;
    limit_conn conn_per_ip {{RL_CONN}};

    # ─── Hassas dosya/dizinleri engelle ───
    # Gizli dosyalar (.env, .git, .htaccess vb.)
    location ~ /\. {
        deny all;
        return 404;
    }

    # Tehlikeli uzantılar
    location ~ \.(env|git|svn|htaccess|htpasswd|ini|log|sh|sql|bak|config|yml|yaml|toml|lock|dist)$ {
        deny all;
        return 404;
    }

    # CI4 uygulama dizinleri (public_html dışında kalmalı)
    location ~ ^/(app|system|vendor|modules|writable|private|tests|node_modules|\.composer|storage|bootstrap|config|database|routes|resources|var)/ {
        deny all;
        return 404;
    }

    # CI4 spark CLI
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
        # Sadece var olan dosyaları çalıştır
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

        # PHP bilgisini gizle
        fastcgi_hide_header X-Powered-By;

        # Timeout
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }

    # ─── Login/admin sayfaları için ekstra rate limit ───
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

    # Favicon
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    # Robots
    location = /robots.txt {
        log_not_found off;
        access_log off;
    }
}
