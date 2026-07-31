# TOKENS: SAFE_NAME WEBHOOK_PORT RL_LOGIN_ZONE RL_LOGIN_BURST
# Besleyen: lib/webhook.sh — _webhook_install_nginx_location (yalnız
# 'srvctl webhook setup <domain>' çağrıldığında render edilir; OPT-IN).
#
# Bu dosya /etc/nginx/webhook.d/{{SAFE_NAME}}/location.conf olarak yazılır.
# vhost.conf.tpl / vhost-ssl.conf.tpl İÇİNDE (her domain için, HER ZAMAN)
# şu satır bulunur:
#     include /etc/nginx/webhook.d/{{SAFE_NAME}}/*.conf;
# SAFE_NAME zaten _domain_write_vhost (lib/domain.sh) tarafından besleniyordu
# — bu YENİ bir token DEĞİL. Dizin/dosya yoksa (webhook kurulmamış domain —
# ÇOĞUNLUK) nginx'te glob include sıfır eşleşmeyi HATA SAYMAZ (bkz.
# /etc/nginx/conf.d/*.conf deseni, lib/init.sh) — bu yüzden saldırı yüzeyi
# yalnız bu dosya AÇIKÇA kurulmuş domain'lerde büyür (opt-in tasarım kararı,
# DALGA 6 — her domain'e otomatik webhook uç noktası açmak gereksiz saldırı
# yüzeyi demektir).
#
# RL_LOGIN_ZONE/RL_LOGIN_BURST domain'in KENDİ rate-limit profilinden
# (.srvctl-meta → RATE_PROFILE, core.sh rate_profile_load) gelir — YENİ bir
# nginx zone TANIMLAMAZ; conf/rate-profiles.conf + lib/init.sh
# render_ratelimit_zones tarafından ZATEN global olarak tanımlanmış olan
# zone'u yeniden kullanır ('srvctl init' çalışmış olmalı).
location = /__srvctl_webhook/{{SAFE_NAME}} {
    # Yalnız POST — GitHub/GitLab webhook teslimatları POST'tur; GET/HEAD
    # keşif/probe istekleri (ör. tarayıcıdan yanlışlıkla açılması) reddedilir.
    limit_except POST {
        deny all;
    }

    # Deploy tetikleyicisi nadiren çalışır; domain'in KENDİ login/sensitive-path
    # zone'unu yeniden kullanır (bkz. yukarıdaki yorum) — yeni bir global zone
    # TANIMLAMAZ.
    limit_req zone={{RL_LOGIN_ZONE}} burst={{RL_LOGIN_BURST}} nodelay;

    # Gövde boyutu sınırı — GitHub push payload'ı (çok sayıda commit ile)
    # büyük olabilir ama SINIRSIZ olmamalı (bellek/DoS).
    client_max_body_size 1m;
    client_body_buffer_size 1m;

    # Yalnızca localhost'taki srvctl webhook listener'ına proxy — listener
    # zaten yalnız 127.0.0.1'e bind (bkz. lib/webhook.sh); burada dışa açık
    # HİÇBİR ek yüzey oluşturulmaz. Path KASITLI OLARAK listener'ın anladığı
    # '/deploy/{{SAFE_NAME}}' biçimine yeniden yazılır (proxy_pass URI'si).
    proxy_pass http://127.0.0.1:{{WEBHOOK_PORT}}/deploy/{{SAFE_NAME}};
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 10s;
    proxy_connect_timeout 5s;

    # NOT: imza/replay/delivery-id doğrulaması BURADA yapılmaz — tek karar
    # noktası listener'dadır (_webhook_verify_sig / _webhook_check_replay,
    # lib/webhook.sh). Bu location yalnız metod/rate/gövde-boyutu/yönlendirme
    # katmanıdır (defense-in-depth, tekilleştirilmiş doğrulama mantığı).
}
