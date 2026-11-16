# TOKENS: SAFE_NAME FM_UP_HOST FM_UP_ORIGIN FM_UP_ORIGIN_RE ACME_ROOT LE_LIVE CUSTOM_D EMPTY_ROOT LOG_DIR MODSEC_LINE
#         RATE_IP BURST_IP CONN_IP RATE_ALL BURST_ALL CONN_ALL
# Besleyen: lib/edge.sh — _edge_fmup_render (yalnız 'srvctl domain fm-up <alan> on --host=up.<alan> --origin=https://<alan>'
# çağrıldığında; OPT-IN, varsayılan KAPALI). Dosya /etc/nginx/conf.d/srvctl-fmup-<safe>.conf olarak yazılır (root:644, SRVCTL ÜRETİR).
#
# NE: Cloudflare'siz (DNS-only) yükleme adresi. Tarayıcı parçaları (PUT /_fm/up/<id>/<ofs>) Cloudflare'in ~100 sn/tampon
# sınırı ve ~0,4 MiB/sn yolu yerine doğrudan bu sunucu bloğuna gönderir. Tasarım A: AYRI sunucu bloğu; alanın 20 (yükleme) ve
# 90 (auth) dosyaları glob ile İÇERİLİR — kapılar TEK KAYNAK: 'fm-auth off' / acil kapanış bu yüzü KENDİLİĞİNDEN kapatır
# (20 bir 403 köküne döner, 90 silinir). 21 (indirme) ve kiracının 00-custom.conf'u BU bloğa GİRMEZ.
#
# İKİ FAZ (K10): '@@PHASE1' ile '@@PHASE2' arası YALNIZ port 80'dir (ACME http-01 + kalanı 301). Faz 1 tek başına yazılır,
# certbot sertifikayı alır, sonra TAM dosya (faz 1 + faz 2) yazılır. Faz 1 SUNUCU DÜZEYİNDE 'return' İÇERMEZ: sunucu-rewrite
# aşaması location seçiminden ÖNCE çalışır, 'certbot renew' sessizce düşerdi (yalnız location içinde return vardır).
#
# KONTROLLER (up-guvenlik): K4 yüzey yalnız /_fm/up/ (diğer her yol 404), K5 bilet biçimi ön denetimi, K6 gövde sınırı,
# K7 zaman aşımları, K8 limit_req/limit_conn, K9 CORS tam köken, K10 HSTS+ACME, K11 günlük/ModSecurity.
#
# add_header YALNIZ SUNUCU DÜZEYİNDE: 20/90 dosyalarında add_header YOKTUR (üst bloğu düşürürdü) ve burada da location
# içinde add_header yoktur; böylece her yanıt (200/204/403/404/411/413/429/502 …) bu başlıkları 'always' ile taşır.
#
# K5 YERİ: bilet biçimi denetimi (^[0-9a-f]{64}$) YALNIZ bu up bloğunda, sunucu-rewrite aşamasında 'map' ile yapılır; 20
# şablonuna KONMADI. Gerekçe: 20 ana alan vhost'unda da koşar ve 'fm-auth status' / acil-kapat sondası ORADA biletsiz
# gövdesiz PUT atıp 411 + "srvctl-fm-open <imza>" bekler — 20'ye bilet kapısı koymak sondayı 403'e çevirip "AÇIK"ı
# "doğrulanamadı" yapar ve şablon sürümünü (imzayı) değiştirirdi. Auth ucu (/__fm_auth) ise FPM'de aynı biçimi zaten uygular.
#
# ÖN UÇUŞ (OPTIONS) ve ucuz RET yanıtları: karar map ile verilir (tam Origin + Access-Control-Request-Method: PUT +
# ^/_fm/up/[0-9]{1,20}/[0-9]{1,20}$ → 204; başka her OPTIONS → 403; yüzey dışı yol → 404; biçimsiz bilet → 403). Sunucu-rewrite
# aşamasındaki 'return' limit_req/limit_conn'dan (PREACCESS) ÖNCE biter ve SAYILMAZ (lab ölçümü: 10 ön uçuşta 0×429); bu yüzden
# aşama yalnız 'rewrite … last' ile /__fmup_gate'e iç yönlendirir; orada 'try_files' (PRECONTENT, PREACCESS'ten SONRA)
# adlı @fmup_gate'e düşer ve karar 'return' ile orada verilir: HER yanıt limitlere sayılır (en katı seçenek). Sınır aşılırsa 429 gelir.
# 20'nin 411 kapısından ve limit_except'ten önce çözülür.
#
# MODSECURITY: 'modsecurity off' (sunucu düzeyi). Gerekçe: incelenecek girdi yok (yüzey tek yol, gövde pCloud'a akar), CRS
# varsayılanı PUT'u izinli saymaz ve SecAuditLogParts'in B bölümü 4xx'te X-Fm-Ticket'ı denetim günlüğüne yazardı.
# Günlük: ayrı log_format — başlık, bilet, $fm_auth, $upstream_http_*, $sent_http_* YOK.
# GÜNLÜK YERİ: root'a ait dizin ({{LOG_DIR}}, varsayılan /var/log/nginx; SRVCTL_FMUP_LOG_DIR). Kiracıya ait site dizinindeki logs klasörüne YAZILMAZ:
# kök nginx süreci (açma/yeniden açma/logrotate) kiracının yerleştirdiği sembolik bağı izleyip kiracı yoluna root olarak yazardı
# (CVE-2016-1247 sınıfı). fail2ban bu dosyalara bağlanabilir; kiracı dizinindeki günlüğe ASLA.

# @@PHASE1
# K11: ayrı log_format (faz 1'de de gerekir: 80 bloğu kullanır). Başlık/bilet/$fm_auth/$upstream_http_*/$sent_http_* YOK.
# İlk 6 alan SIRASI DEĞİŞMEZ (lib/monitor.sh _monitor_up_abuse_count 3. tırnak sonrası ilk sözcüğü okur); yavaşlık ayrımı için SONA eklenenler:
#   $server_protocol (HTTP/2.0|HTTP/1.1), $request_length (istek satırı+başlık+gövde bayt), $upstream_response_time ve $upstream_status
#   (auth alt isteği + @fm_up iç yönlendirmesi ⇒ ', ' ya da ' : ' ile birden çok değer; iç yönlendirmede ' : ' önce gelen grubu ayırır).
#   $request_time ≫ $upstream_response_time ⇒ yavaşlık kullanıcı hattında; ikisi de büyükse pCloud bacağında. Bunlar sayı/durum: sır taşımaz.
log_format fmup_{{SAFE_NAME}} '$remote_addr [$time_local] "$request_method $request_uri" $status $body_bytes_sent $request_time $server_protocol $request_length $upstream_response_time $upstream_status';

server {
    listen 80;
    server_name {{FM_UP_HOST}};

    access_log {{LOG_DIR}}/srvctl-fmup-{{SAFE_NAME}}.http.log fmup_{{SAFE_NAME}};

    location ^~ /.well-known/acme-challenge/ {
        root {{ACME_ROOT}};
        default_type text/plain;
    }

    location / {
        return 301 https://{{FM_UP_HOST}}$request_uri;
    }
}
# @@PHASE2
# K9: tam köken. Yansıtma, joker, null ya da * YOK; ACAO sabit yapılandırma değeridir. Anahtar çapalı düzenli ifadedir
# (tam metin anahtar map hash kovasına girer; uzun köken varsayılan map_hash_bucket_size ile nginx -t'yi düşürür).
map $http_origin $fmup_acao_{{SAFE_NAME}} {
    default "";
    "~^{{FM_UP_ORIGIN_RE}}$" "{{FM_UP_ORIGIN}}";
}
map $fmup_acao_{{SAFE_NAME}} $fmup_acam_{{SAFE_NAME}} { default ""; "~." "PUT"; }
map $fmup_acao_{{SAFE_NAME}} $fmup_acah_{{SAFE_NAME}} { default ""; "~." "X-Fm-Ticket, Content-Type"; }
map $fmup_acao_{{SAFE_NAME}} $fmup_acma_{{SAFE_NAME}} { default ""; "~." "600"; }

# Ön uçuş kararı: 1 = izinli (204), 2 = başka her OPTIONS (403), 0 = OPTIONS değil.
map "$request_method|$http_origin|$http_access_control_request_method|$request_uri" $fmup_pre_{{SAFE_NAME}} {
    default 0;
    "~^OPTIONS\|{{FM_UP_ORIGIN_RE}}\|PUT\|/_fm/up/[0-9]{1,20}/[0-9]{1,20}$" 1;
    "~^OPTIONS\|" 2;
}

# K4: istek hedefi (ORİJİNAL satır — auth alt isteğinde de aynıdır) yalnız /_fm/up/ ise 1.
map $request_uri $fmup_route_{{SAFE_NAME}} {
    default 0;
    "~^/_fm/up/" 1;
}

# K5: PUT /_fm/up/… isteğinde bilet 64 küçük hex değilse 1 (403). Başka yöntemler 20'nin kapılarına düşer.
map "$request_method|$request_uri|$http_x_fm_ticket" $fmup_tkt_{{SAFE_NAME}} {
    default 0;
    "~^PUT\|/_fm/up/[0-9]{1,20}/[0-9]{1,20}\|[0-9a-f]{64}$" 0;
    "~^PUT\|/_fm/up/" 1;
}

# K8: alana özgü bölge adları (başka alanın bölgesiyle çakışmaz).
limit_req_zone  $binary_remote_addr zone=fmup_ip_{{SAFE_NAME}}:10m rate={{RATE_IP}}r/s;
limit_req_zone  $server_name        zone=fmup_all_{{SAFE_NAME}}:1m rate={{RATE_ALL}}r/s;
limit_conn_zone $binary_remote_addr zone=fmup_cip_{{SAFE_NAME}}:10m;
limit_conn_zone $server_name        zone=fmup_call_{{SAFE_NAME}}:1m;

server {
    listen 443 ssl http2;
    server_name {{FM_UP_HOST}};

    ssl_certificate     {{LE_LIVE}}/{{FM_UP_HOST}}/fullchain.pem;
    ssl_certificate_key {{LE_LIVE}}/{{FM_UP_HOST}}/privkey.pem;

    {{MODSEC_LINE}}

    # K4: boş kök — dosya sunulmaz ('try_files /__fm_never_exists' 20'de bu dizinde hiç var olmaz).
    root {{EMPTY_ROOT}};

    # K11: ayrı günlük; hata günlüğü warn (info/debug başlıkları döker).
    access_log {{LOG_DIR}}/srvctl-fmup-{{SAFE_NAME}}.access.log fmup_{{SAFE_NAME}};
    error_log  {{LOG_DIR}}/srvctl-fmup-{{SAFE_NAME}}.error.log warn;

    # K6/K7: sunucu düzeyinde gövde 1k (yalnız 20 ve 90 kendi 33m'lerini koyar); kısa zaman aşımları.
    # NOT: 20'nin @fm_up location'ı da 'client_body_timeout 30s' taşır (iki OKUMA arası; ana alan ve up için TEK değer) — location
    # içi değer sunucu düzeyini ezer, ikisi aynıdır. Canlı 256 MiB e2e'de meşru 408 görülürse HER İKİSİ 60s'e çıkarılır (RUNBOOK §geri dönüş).
    client_max_body_size 1k;
    client_header_timeout 10s;
    client_body_timeout 30s;
    send_timeout 30s;
    keepalive_timeout 15s;
    lingering_time 10s;
    large_client_header_buffers 4 4k;

    # K8: IP başına + toplam. 429, yanıtı ACAO ile döndürür (always) → istemci "ağ hatası" yerine 429'u görür.
    limit_req_status 429;
    limit_conn_status 429;
    limit_req  zone=fmup_ip_{{SAFE_NAME}}  burst={{BURST_IP}}  nodelay;
    limit_req  zone=fmup_all_{{SAFE_NAME}} burst={{BURST_ALL}} nodelay;
    limit_conn fmup_cip_{{SAFE_NAME}}  {{CONN_IP}};
    limit_conn fmup_call_{{SAFE_NAME}} {{CONN_ALL}};

    # K9/K10: BÜTÜN yanıtlarda (always). ACAC (Allow-Credentials) KASITLI YOK.
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "no-store" always;
    add_header Vary "Origin" always;
    add_header Access-Control-Allow-Origin  $fmup_acao_{{SAFE_NAME}} always;
    add_header Access-Control-Allow-Methods $fmup_acam_{{SAFE_NAME}} always;
    add_header Access-Control-Allow-Headers $fmup_acah_{{SAFE_NAME}} always;
    add_header Access-Control-Max-Age       $fmup_acma_{{SAFE_NAME}} always;

    # Sunucu-rewrite aşaması (location seçiminden ÖNCE): sıra önemlidir.
    # Üçü de /__fmup_gate'e iç yönlendirir (karar orada, limitlerden SONRA — bkz. ÖN UÇUŞ notu).
    if ($fmup_pre_{{SAFE_NAME}}) { rewrite ^ /__fmup_gate last; }
    if ($fmup_route_{{SAFE_NAME}} = 0) { rewrite ^ /__fmup_gate last; }
    if ($fmup_tkt_{{SAFE_NAME}}) { rewrite ^ /__fmup_gate last; }

    location = /__fmup_gate {
        internal;
        try_files /__fmup_never_exists @fmup_gate;
    }

    location @fmup_gate {
        if ($fmup_pre_{{SAFE_NAME}} = 1) { return 204; }
        if ($fmup_pre_{{SAFE_NAME}} = 2) { return 403; }
        if ($fmup_route_{{SAFE_NAME}} = 0) { return 404; }
        return 403;
    }

    # Kapılar TEK KAYNAK: alanın KENDİ 20 (yükleme) ve 90 (auth) dosyaları. 'con[f]' glob'u dosya yokken hatasız sıfır
    # eşleşme verir (fm-auth hiç açılmadıysa blok yalnız 404 verir). 21 ve 00-custom.conf BİLEREK içerilmez.
    include {{CUSTOM_D}}/{{SAFE_NAME}}/20-srvctl-fm-upload.con[f];
    include {{CUSTOM_D}}/{{SAFE_NAME}}/90-srvctl-fm-auth.con[f];

    # Kalan her yol.
    location / { return 404; }
}
