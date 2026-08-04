# TOKENS: DOMAIN SAFE_NAME WEB_ROOT PHP_VERSION RL_REQ_ZONE RL_REQ_BURST
#         RL_LOGIN_ZONE RL_LOGIN_BURST RL_CONN RL_SENSITIVE_PATHS DENY_DIRS
# Besleyen: lib/domain.sh — _domain_write_vhost (satır ~489). RL_* değerleri
# rate_profile_load (core.sh) tarafından global değişken olarak set edilir;
# RL_SENSITIVE_PATHS/DENY_DIRS önce assert_regex_safe ile doğrulanır.
#
# NOT (DALGA 6): aşağıdaki 'include .../webhook.d/{{SAFE_NAME}}/*.conf' satırı
# SAFE_NAME'i YENİDEN kullanır — YENİ bir token DEĞİL. Webhook OPT-IN'dir,
# bkz. o satırın yanındaki yorum.
#
# NOT (DALGA 7): 'include /etc/nginx/geoblock.d/*.conf;' satırı da YENİ bir
# token GEREKTİRMEZ (literal/sabit yol, tüm domainlerde AYNI — geoblock
# per-domain değil server-çapında bir karardır). Detay ve besleme durumu
# için templates/nginx/geoblock-enforce.conf.tpl'e bakın.
server {
    listen 80;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    root {{WEB_ROOT}}/{{DOMAIN}}/public_html;
    index index.php index.html index.htm;

    access_log {{WEB_ROOT}}/{{DOMAIN}}/logs/access.log security;
    error_log  {{WEB_ROOT}}/{{DOMAIN}}/logs/error.log warn;

    # ─── GeoIP Engelleme (OPT-IN, global — DALGA 7) ───
    # 'srvctl ip geoblock add <ülke>' hiç ÇAĞRILMADIYSA (ya da GeoIP modülü
    # kurulu değilse) bu satır HİÇBİR ŞEY yapmaz: /etc/nginx/geoblock.d/
    # dizini/dosyası yoksa nginx'te glob include sıfır eşleşmeyi hatasız
    # kabul eder (webhook.d İLE AYNI desen — bkz.
    # templates/nginx/webhook-location.conf.tpl). Diğer tüm güvenlik
    # kontrollerinden (rate limit, hassas dosya/dizin engelleri) ÖNCE
    # yerleştirilmiştir — engellenen bir ülkeden gelen istek mümkün olduğunca
    # erken reddedilsin, limit_req sayaçları/CPU boşuna tüketilmesin diye.
    # İçerik ve besleme durumu için templates/nginx/geoblock-enforce.conf.tpl.
    include /etc/nginx/geoblock.d/*.conf;

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

    # Bağımlılık manifest dosyaları (isim-bazlı, KÖR '.json$' DEĞİL):
    # composer.json versiyon kısıtlarını sızdırır (composer.lock zaten .lock$
    # ile engelli); package.json/package-lock.json npm bağımlılık ağacını
    # sızdırır. Genel '.json' uzantı engeli Laravel'in public/manifest.json,
    # public/build/manifest.json (Vite) gibi MEŞRU dosyalarını kırar — bu
    # yüzden yalnız bilinen hassas dosya adları engellenir.
    location ~ ^/(composer\.json|package\.json|package-lock\.json)$ {
        deny all;
        return 404;
    }

    # Uygulama dizinleri (docroot içinde kalmamalı) — framework/layout'a göre
    # değişir: CI4 legacy'de (docroot=repo kökü) bu dizinler docroot İÇİNDE ve
    # gerçekten tehlikelidir; public/ tabanlı layout'ta (Laravel/Symfony/modern
    # CI4) 'storage' ve 'vendor' MEŞRU public alt dizinleridir (storage:link,
    # vendor:publish) — {{DENY_DIRS}} değeri framework beyanına göre seçilir.
    location ~ ^/({{DENY_DIRS}})/ {
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

    # ─── Webhook auto-deploy (OPT-IN, DALGA 6) ───
    # 'srvctl webhook setup {{DOMAIN}}' ÇAĞRILMADIĞI sürece bu satır
    # HİÇBİR ŞEY yapmaz: /etc/nginx/webhook.d/{{SAFE_NAME}}/ dizini/dosyası
    # yoksa nginx'te glob include sıfır eşleşmeyi hatasız kabul eder (bkz.
    # /etc/nginx/conf.d/*.conf deseni, lib/init.sh) — yani her domain'e
    # otomatik bir webhook uç noktası AÇILMAZ, saldırı yüzeyi yalnız
    # webhook AÇIKÇA kurulmuş domain'lerde büyür. İçerik ve gerekçe için
    # templates/nginx/webhook-location.conf.tpl'e bakın.
    include /etc/nginx/webhook.d/{{SAFE_NAME}}/*.conf;

    # ─── Operatör override'ları (srvctl domain nginx <domain>) ───
    # EN SONDA include ediliyor ve bu KASITLI: nginx'te regex location'lar
    # TANIM SIRASINA göre eşleşir, yani yukarıdaki deny kuralları (/\.,
    # \.(env|git|...)$, spark, composer.json) HER ZAMAN önce değerlendirilir —
    # buraya eklenen bir regex location onları BYPASS EDEMEZ. Prefix
    # location'lar en-uzun-eşleşme ile çalıştığından meşru kullanım
    # (ör. 'location /api/') bu sıralamadan ETKİLENMEZ.
    # Glob include sıfır eşleşmeyi hatasız kabul eder (webhook.d ile aynı
    # gerekçe — dizin hiç oluşmamışsa vhost yine geçerlidir).
    include /etc/nginx/custom.d/{{SAFE_NAME}}/*.conf;
}
