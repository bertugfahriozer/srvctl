# TOKENS: SAFE_NAME PHP_VERSION AUTH_SCRIPT MODSEC_LINE
# Besleyen: lib/domconf.sh — _domconf_fm_render_auth (yalnız 'srvctl domain fm-auth
# <domain> on --script=...' çağrıldığında render edilir; OPT-IN, varsayılan KAPALI).
#
# Bu dosya /etc/nginx/custom.d/{{SAFE_NAME}}/90-srvctl-fm-auth.conf olarak
# yazılır — vhost'ta ZATEN bulunan 'include .../custom.d/{{SAFE_NAME}}/*.conf'
# satırı sayesinde vhost şablonu DEĞİŞMEZ. Dosya SRVCTL ÜRETİR (root:644):
# 00-custom.conf'un tersine operatör düzenlemez, 'fm-auth off' siler.
#
# NEDEN srvctl render ediyor: kiracı custom.d dosyasında 'fastcgi_pass' (ve her *_pass)
# izin listesi dışındadır (lib/nginx_allow.sh) — başka alanın FPM soketine yönlenme.
# auth_request alt isteğinin FPM'e GÖVDESİZ gitmesi gerekir; vhost'un .php location'ına
# rewrite ile düşmek 'fastcgi_pass_request_body'yi açık bırakır ve FPM 32 MiB
# CONTENT_LENGTH bekleyip asılırdı. Soket yolu YALNIZ bu domainin KENDİ FPM havuzudur
# (şablonda sabit, parametre değil).
#
# Yükleme location'ı (20-srvctl-fm-upload.conf) 'auth_request /__fm_auth' kullanır ve
# belirteci KAPI 2 ile (boş/biçimsiz → 403) ayrıca denetler; bu dosya elle silinse bile
# belirteçsiz istek pCloud'a ulaşmaz. Include / kapı değişkeni düzeneği YOKTUR.
# Auth betiği: FPM chroot'u İÇİNDE, docroot (/public_html) DIŞINDA, release İÇİNDE sabit
# bir yol — dışarıdan doğrudan çağrılamaz.

location = /__fm_auth {
    internal;

    # WAF bu alt istekte de kapalı (ModSecurity-nginx'in alt istekleri işleyip
    # işlemediği ölçülmedi — savunma derinliği). Modül YOKSA satır yorum olur
    # (srvctl 'nginx -t' probu ile tespit eder).
    {{MODSEC_LINE}}

    fastcgi_pass unix:/run/php/php{{PHP_VERSION}}-fpm-{{SAFE_NAME}}.sock;
    fastcgi_pass_request_body off;

    # Auth alt isteği KENDİ location'ının sınırını uygular (canlı ölçüm N2:
    # 'client intended to send too large body … subrequest', 413→500).
    client_max_body_size 33m;

    # fastcgi_params DAHİL EDİLMEZ: aynı adlı parametre iki kez gönderilirdi
    # (CONTENT_LENGTH ""). Gerekenler tek tek, açıkça yazılır.
    # SCRIPT_FILENAME chroot-GÖRELİ (vhost .php location'ı ile aynı gerekçe).
    fastcgi_param SCRIPT_FILENAME {{AUTH_SCRIPT}};
    # SCRIPT_NAME sabit: custom.d kaybolup istek CI4'ün index.php'sine düşerse
    # SCRIPT_NAME '/index.php' olur — auth betiği ikisini birden şart koşar.
    fastcgi_param SCRIPT_NAME /__fm_auth;
    fastcgi_param DOCUMENT_ROOT /public_html;
    fastcgi_param GATEWAY_INTERFACE CGI/1.1;
    fastcgi_param SERVER_PROTOCOL $server_protocol;
    fastcgi_param SERVER_NAME $server_name;
    fastcgi_param REQUEST_METHOD $request_method;
    fastcgi_param REQUEST_URI $request_uri;
    fastcgi_param QUERY_STRING "";
    fastcgi_param REMOTE_ADDR $remote_addr;
    fastcgi_param HTTPS $https if_not_empty;
    fastcgi_param CONTENT_LENGTH "";
    fastcgi_param CONTENT_TYPE "";
    # İstemcinin bildirdiği gövde uzunluğu (alt istekte CONTENT_LENGTH boş).
    fastcgi_param FM_CLIENT_CONTENT_LENGTH $http_content_length;
    # Bu location'dan geçtiğinin işareti (SABİT değer, değişken değil). İstemci
    # başlıkları FPM'e yalnız 'HTTP_' önekiyle ulaşır; 'FM_AUTH_SUBREQ' adlı bir
    # CGI değişkenini istemci KURAMAZ. Auth betiği (Aşama 3) bunu şart koşarak
    # vhost'un genel .php işleyicisinden (SCRIPT_NAME/FM_AUTH_SUBREQ yok) doğrudan
    # çağrılmayı reddeder. SINIR: 'rewrite … /__fm_auth last' gadget'ı da bu
    # location'a düşer — bu işaret alt isteği ana isteğin iç yönlendirmesinden
    # AYIRMAZ (o yol 'internal' + hide_header ile kapalı tutulur).
    fastcgi_param FM_AUTH_SUBREQ 1;

    fastcgi_connect_timeout 3s;
    fastcgi_send_timeout 10s;
    fastcgi_read_timeout 10s;
    fastcgi_hide_header X-Powered-By;
    # Token başlığı istemciye ASLA gitmesin: 'rewrite … /__fm_auth' ile ana
    # isteğe düşülse bile yanıttan düşer. 'auth_request_set $fm_auth
    # $upstream_http_x_fm_auth' bundan ETKİLENMEZ (nginx 1.28 ile ölçüldü).
    fastcgi_hide_header X-Fm-Auth;
}
