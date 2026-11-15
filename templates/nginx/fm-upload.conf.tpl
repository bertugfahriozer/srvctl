# TOKENS: PCLOUD_HOST MODSEC_LINE FM_SIG
# Besleyen: lib/domconf.sh — _domconf_fm_render_upload (yalnız 'srvctl domain
# fm-auth <domain> on --script=... [--region=eu|us]' çağrıldığında render edilir;
# OPT-IN, varsayılan KAPALI). PCLOUD_HOST sabit tablodan gelir (eu: eapi.pcloud.com,
# us: api.pcloud.com) — dosyadan/ortamdan okunmaz. MODSEC_LINE 'modsecurity off;'
# ya da (modül yüklü değilse) bir yorum satırıdır. FM_SIG = alan adına özgü gövde imzası
# (_domconf_fm_body_sig; yalnız Content-Length'siz 411 gövdesinde).
#
# Bu dosya /etc/nginx/custom.d/<safe_name>/20-srvctl-fm-upload.conf olarak yazılır
# (root:root 644, SRVCTL ÜRETİR; köken kaydı: ${SRVCTL_STATE_DIR}/_fm-auth/).
# Operatör düzenlemez; 'fm-auth off' bunu iki satırlık 403 köküyle değiştirir.
#
# Sözleşme (canlı ölçüm: yükleme parçası 32 MiB, HTTP/1.1 ve HTTP/2):
#  - Yol: /_fm/up/UPLOADID/OFFSET — yalnız rakam/rakam, UZANTI YOK. Biçim
#    denetimi HAM istek satırı ($request_uri) üzerindedir: sorgu dizesi, '%'
#    kodlaması, '..', '//' ve uzantı içeren her yol 403 alır.
#  - Yalnız PUT + Content-Length (chunked pCloud'a ham veri olarak yazılırdı).
#  - Gövde nginx'te tamponlanmaz (proxy_request_buffering off).
#  - OAuth belirteci YALNIZ başlıkta: auth alt isteği X-Fm-Auth döner,
#    Authorization olarak pCloud'a verilir. Sorgu dizesinde ASLA.
#  - pCloud'a giden başlıklar İZİN LİSTESİdir (proxy_pass_request_headers off).
#  - pCloud yanıtındaki X-Accel-* başlıkları yok sayılır ve iletilmez.
#  - Bu dosyada add_header YOK (üst bloğun güvenlik başlıklarını düşürürdü).
#
# KONUM ÖNCELİĞİ: yükleme location'ı ÖNEK-kesin ('^~') eşleşmedir.
# '^~' önek eşleşmesi kazanınca nginx regex location'lara BAKMAZ: vhost'un statik/PHP
# regex'leri ve kiracı custom.d dosyasındaki regex location'ları bu yolda devre dışıdır.
# Kalan her /_fm/ yolu ('^~ /_fm/') 403 verir.
#
# İKİ KAPI: (1) auth_request (fm-auth açıkken auth ucu 2xx döner, aksi 403; auth ucu bu şablonun '/__fm_' yakalayıcısına düşerse 403,
# FPM soketi/betiği hata verirse nginx 500 verir ve 'error_page 500 =403' bunu 403'e çevirir);
# (2) KAPI 2 = @fm_up içinde boş/biçimsiz belirteç 403'ü: auth ucu yok olsa bile (2xx + başlıksız) pCloud'a gitme.
# '/__fm_' AD ALANI: 90 (auth) yokken auth alt isteği uygulamaya (CI4) DÜŞMEZ; bu dosyadaki '^~ /__fm_' yakalayıcısı
# ('internal; return 403;') onu 403'e bağlar, uygulama kodu kullanıcı çerezleriyle çalışmaz. 90'ın tam eşleşen '= /__fm_auth'
# ve 21'in '= /__fm_dl' location'ları yakalayıcıdan önceliklidir (tam eşleşme önek eşleşmesinden önce kazanır).
# KAPI 2 YAPISAL olarak kilitlidir (tests/test_domconf_fm_auth.sh). Dosya yazım sırası (90 → 21 → 20) ve
# 'off' sırası (20'yi 403 köküyle değiştir → 90/21 sil) yarım durumda yolun açık
# kalmamasını sağlar.
#
# İKİ AŞAMA (KAPI 2): auth_request ERİŞİM aşamasında çalışır, 'if' ise ondan ÖNCE
# (rewrite aşaması). Bu yüzden asıl location auth'u yapar, 'try_files' ile ADLI
# location'a (@fm_up) iç yönlendirir; orada rewrite aşaması yeniden çalışır ve
# $fm_auth doludur.

location ^~ /_fm/up/ {
    {{MODSEC_LINE}}

    # Biçim kapısı: tam olarak rakam/rakam. Başka her şey 403.
    if ($request_uri !~ "^/_fm/up/[0-9]{1,20}/[0-9]{1,20}$") { return 403; }

    # Yalnız PUT. (GET boş gövdeyle pCloud'da upload_write'ı tetiklerdi.)
    limit_except PUT { deny all; }

    # Content-Length zorunlu (rewrite aşaması: auth_request'ten ÖNCE çalışır).
    # 411 gövdesi alan adına özgü AÇIK imzasıdır: `srvctl domain fm-auth <alan> status` ve acil
    # yolun sondası yalnız (411 + tam "srvctl-fm-open <sig>") yanıtını "AÇIK" sayar. İmza lib/domconf.sh
    # _domconf_fm_body_sig üretir; bu satırı değiştirmek _DOMCONF_FM_TPL_VER'i artırmayı gerektirir.
    if ($http_content_length = "") { return 411 "srvctl-fm-open {{FM_SIG}}"; }

    # Parça 32 MiB; auth alt isteği KENDİ location'ının sınırını da uygular
    # (/__fm_auth: 33m), ikisi birlikte olmalı.
    client_max_body_size 33m;

    # FAIL-CLOSED 403: auth alt isteği 2xx/401/403 dışında dönerse (auth betiği 5xx verir, FPM soketi yok …) auth_request bunu
    # 500'e çevirir (auth dosyası 90 yokken alt istek '^~ /__fm_' yakalayıcısında 403 alır, uygulamaya düşmez); 500 burada 403'e eşlenir (pCloud'a
    # istek 0). Hedef ADLI location'dır (@fm_deny): URI'ye iç yönlendirme gövde sınırını (client_max_body_size, varsayılan 1m)
    # yeniden uygular ve 32 MiB'lık parça 403 yerine 413 alırdı; adlı location bu denetimden geçmez.
    error_page 500 =403 @fm_deny;

    auth_request /__fm_auth;
    auth_request_set $fm_auth $upstream_http_x_fm_auth;

    # Auth geçtiyse adlı location'a iç yönlendir (dosya hiçbir zaman var olmaz).
    try_files /__fm_never_exists @fm_up;
}

# Kalan her /_fm/ yolu: fail-closed. Eğik çizgisiz '/_fm' de (CI4'ün catch-all GET rotasına
# düşerdi) TAM EŞLEŞMEYLE kapatılır; '^~ /_fm' ÖNEKİ BİLEREK kullanılmaz: '/_fmx', '/_fm_rapor'
# gibi ilgisiz kiracı yollarını da yutardı (nginx 1.28 ile ölçüldü).
# Bu iki 403 BİLEREK imzasızdır: "kapalı" imzası (srvctl-fm-closed) yalnız 'fm-auth off' kökünde
# (_domconf_fm_render_off) bulunur; AÇIK şablondan hiçbir yanıt "KAPALI" kanıtı sayılamaz.
location = /_fm { return 403; }
location ^~ /_fm/ { return 403; }

# auth_request hata eşlemesinin (error_page 500 =403) hedefi; imzasız 403, başka yoldan erişilemez (adlı location).
location @fm_deny { return 403; }

# '/__fm_' ad alanı yakalayıcısı: srvctl'in iç location'ları (= /__fm_auth: 90, = /__fm_dl: 21) tam eşleşmedir ve bu önekten
# ÖNCE kazanır. İlgili dosya yokken (90 silinmiş/üretilmemiş, 21 yok) bu yol uygulamaya (CI4) düşmez: iç istek (auth alt isteği,
# X-Accel-Redirect) 403 alır, dışarıdan gelen istek 'internal' gereği 404 alır. '^~' regex location'lara BAKTIRMAZ (vhost'un .php
# işleyicisi bu yolda devre dışıdır). Bu dosya yalnız fm-auth AÇIKKEN bulunur; 403 kökü (kapalı) AYNI satırı taşır (lib/domconf.sh _domconf_fm_render_off): alan kapalıyken
# uygulamanın X-Accel-Redirect ile '/__fm_dl'e yönlendirmesi de CI4'e düşmez.
location ^~ /__fm_ { internal; return 403; }

location @fm_up {
    # ModSecurity: try_files iç yönlendirmesi rewrite/access fazlarını YENİDEN koşar
    # ve gövdeyi proxy'leyen asıl location BURASIDIR; burada da kapanmalı.
    {{MODSEC_LINE}}

    # KAPI 2: boş/biçimsiz belirteçle pCloud'a ASLA gitme. Değer 'Bearer ' + RFC 6750
    # b64token olmalı (boşluk/kontrol karakteri/tırnak yok).
    if ($fm_auth !~ "^Bearer [A-Za-z0-9._~+/=-]+$") { return 403; }

    client_max_body_size 33m;

    # uploadid/offset: kapıdan geçen HAM yoldan düz değişkenlere. DİKKAT (nginx 1.28
    # ile ölçüldü): içinden dönmeyen ('set' yapan) bir 'if' eşleşince istek if-bloğunun
    # konum yapılandırmasına geçer ve 'try_files' MİRAS KALMAZ (PUT → 405). Bu yüzden
    # bu çıkarma asıl location'da DEĞİL, proxy_pass'in (miras kalan) bulunduğu bu adlı
    # location'dadır.
    set $fm_up_uid "";
    set $fm_up_off "";
    if ($request_uri ~ "^/_fm/up/([0-9]{1,20})/([0-9]{1,20})$") {
        set $fm_up_uid $1;
        set $fm_up_off $2;
    }
    if ($fm_up_uid = "") { return 403; }

    proxy_http_version 1.1;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_max_temp_file_size 0;

    # Sabit pCloud ana makinesi (bölge tablosundan). DEĞİŞKEN HOST YOK.
    proxy_ssl_server_name on;
    proxy_ssl_name {{PCLOUD_HOST}};
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 3;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;

    # İZİN LİSTESİ: istemci başlıklarının HİÇBİRİ otomatik geçmez.
    proxy_pass_request_headers off;
    proxy_set_header Host {{PCLOUD_HOST}};
    proxy_set_header Authorization $fm_auth;
    proxy_set_header Content-Type $http_content_type;
    proxy_set_header Connection "";

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
    proxy_hide_header Set-Cookie;

    # 32 MiB'ı yavaş bir hat gönderebilir; zaman aşımı iki okuma arası içindir.
    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;
    client_body_timeout 120s;

    # Değişkenli proxy_pass: çalışma anında ad çözümü → global 'resolver' ŞART
    # (srvctl lib/init.sh: resolver 1.1.1.1 8.8.8.8). Yoksa her parça 502.
    proxy_pass https://{{PCLOUD_HOST}}/upload_write?uploadid=$fm_up_uid&uploadoffset=$fm_up_off;
}
