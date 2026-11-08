# TOKENS: SAFE_NAME
# Besleyen: lib/domconf.sh — _domconf_fm_render_download (yalnız 'srvctl domain
# fm-auth <domain> on ...' çağrıldığında render edilir; OPT-IN, varsayılan KAPALI).
#
# Bu dosya /etc/nginx/custom.d/<safe_name>/21-srvctl-fm-download.conf olarak yazılır
# (root:root 644, SRVCTL ÜRETİR).
#
# CI4 yetkiyi verir, yanıtı 'X-Accel-Redirect: /__fm_dl?u=<pcloud-link>' ile nginx'e
# devreder; Range/206 pCloud'dan olduğu gibi akar, PHP RAM'i ~0. 'internal':
# dışarıdan çağrılamaz (404). Hedef YALNIZ https://<etiket>.pcloud.com/ — açık proxy
# değildir ($arg_u deseni aşağıda).
#
# Bu location'da add_header YOK: eklense üst bloğun HSTS/nosniff/CSP başlıkları düşer.
# Content-Type pCloud'a getfilelink(contenttype=...) ile söylenir; Content-Disposition'ı
# PHP kurar, pCloud'unki gizlenir.
#
# pCloud'a giden başlıklar İZİN LİSTESİdir (proxy_pass_request_headers off).
#
# HATA GÜNLÜĞÜ SINIRI: pCloud bağlantısının yolu bir erişim kimliğidir ve nginx upstream
# hatalarında error.log'a yazılır. Bu location'ın günlüğü ayrı dosyaya ve crit düzeyine
# alınır. Hata ayıklamak için düzeyi geçici error'a çekersen bağlantı yolları o DOSYAYA
# düşer; işin bitince crit'e geri al.

location = /__fm_dl {
    internal;
    limit_except GET HEAD { deny all; }

    error_log /var/log/nginx/{{SAFE_NAME}}-fm-dl.error.log crit;

    set $fm_u "";
    set $fm_h "";
    # Ana makine: en az bir etiket + '.pcloud.com'; etiket harf/rakamla başlar ve biter,
    # 'localhost' etiketi yasak; yolda '..' yasak. Yol: harf/rakam/'._~:/-' ve YÜZDE-KODLU
    # baytlar; '%00-%1F' (kontrol), '%25', '%2E', '%2F', '%5C', '%7F' reddedilir.
    # Regex '{2}' içerir ve tırnaklıdır (kural).
    if ($arg_u ~ "^https://((?!(?:[a-z0-9-]+\.)*localhost\.)(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+pcloud\.com)/(?!.*\.\.)(?:[A-Za-z0-9._~:/-]|%(?!0[0-9A-Fa-f]|1[0-9A-Fa-f]|2[5EeFf]|5[Cc]|7[Ff])[0-9A-Fa-f]{2})+$") {
        set $fm_u $arg_u;
        set $fm_h $1;
    }
    if ($fm_u = "") { return 403; }

    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_max_temp_file_size 0;
    proxy_intercept_errors off;

    proxy_ssl_server_name on;
    proxy_ssl_name $fm_h;
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 3;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;

    # İZİN LİSTESİ: istemci başlıkları otomatik GEÇMEZ.
    proxy_pass_request_headers off;
    proxy_set_header Host $fm_h;
    proxy_set_header Range $http_range;
    proxy_set_header If-Range $http_if_range;
    proxy_set_header Connection "";
    # Savunma derinliği: izin listesi bozulup proxy_pass_request_headers açılsa bile
    # bilet pCloud'a gitmesin.
    proxy_set_header X-Fm-Ticket "";

    # pCloud yanıtı: X-Accel-* etkisiz ve istemciye iletilmez; CORS ve çerez başlıkları
    # gizlenir.
    proxy_ignore_headers X-Accel-Redirect X-Accel-Expires X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset;
    proxy_hide_header X-Accel-Redirect;
    proxy_hide_header X-Accel-Expires;
    proxy_hide_header X-Accel-Limit-Rate;
    proxy_hide_header X-Accel-Buffering;
    proxy_hide_header X-Accel-Charset;
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Credentials;
    proxy_hide_header Access-Control-Expose-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Max-Age;
    proxy_hide_header Content-Disposition;
    proxy_hide_header Set-Cookie;

    proxy_connect_timeout 10s;
    proxy_read_timeout 300s;
    proxy_send_timeout 60s;

    # Değişken proxy_pass: çalışma anında ad çözümü → global 'resolver' ŞART.
    proxy_pass $fm_u;
}
