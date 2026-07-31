# TOKENS: (yok) — sabit içerik, per-domain bir değişken YOK: geoblock
# server-çapında TEK bir karardır ('srvctl ip geoblock add <ülke>' hiçbir
# domain parametresi ALMAZ), bu yüzden TÜM domainler AYNI dosyayı glob ile
# include eder (bkz. templates/nginx/vhost.conf.tpl / vhost-ssl.conf.tpl,
# 'include /etc/nginx/geoblock.d/*.conf;') — DALGA 7.
#
# BESLEME (RAPOR EDİLMESİ GEREKEN İŞ — templates/** sahibi bu dosyayı
# üretti ama HİÇBİR lib kodu henüz YAZMIYOR): lib/ip.sh:_update_nginx_geoblock
# şu an yalnız '/etc/nginx/conf.d/srvctl-geoblock.conf' içindeki
# 'map $geoip_country $blocked_country {...}' haritasını üretiyor/siliyor.
# AYNI fonksiyon bu dosyayı (render_template ile ya da düz 'cp' ile — token
# olmadığından ikisi eşdeğer) '/etc/nginx/geoblock.d/enforce.conf' olarak
# YAZMALI/SİLMELİ, TAM OLARAK map dosyasıyla AYNI var/yok döngüsünde:
#   - geoblock.conf BOŞ/yoksa   → enforce.conf de SİLİNMELİ (mevcut
#     'rm -f -- "$conf"' erken-dönüş dalıyla BİREBİR aynı yerde/sırada).
#     AKSİ HALDE: harita silinmişken bu dosya hâlâ '$blocked_country'ye
#     başvurursa TÜM domainlerde (map yoksa nginx değişkeni de tanımıyor)
#     'nginx -t' BAŞARISIZ olur — yani geoblock'u KAPATMAK sunucuyu
#     tamamen DÜŞÜRÜR (fail-closed'ın EN KÖTÜ hali, tam kesinti).
#   - geoblock.conf'ta ≥1 ülke varsa → enforce.conf map dosyasıyla BİRLİKTE
#     yazılmalı, 'nginx -t' başarı kontrolünden SONRA reload edilmeli
#     (mevcut kod zaten bu sırayı map dosyası için uyguluyor).
# Dizin bilerek 'webhook.d/<safe_name>' gibi PER-DOMAIN DEĞİL — TEK bir
# (NOT: yukarıdaki yol örneğinde token adı BİLEREK süslü parantezsiz yazıldı.
#  render_template kör string-replace yapar; bir YORUM içindeki çift-süslü
#  token yazımı da gerçek kullanım gibi değiştirilir ve
#  tests/test_template_tokens.sh onu TOKENS beyanıyla uyuşmayan gerçek
#  kullanım sayar — bkz. DALGA 5'te systemd şablonlarında düzeltilen aynı hata.)
# paylaşılan 'geoblock.d/enforce.conf' yeterli; yeni bir domain eklendiğinde
# vhost.conf.tpl'deki include satırı SABİT olduğundan ekstra wiring
# GEREKMEDEN aynı global durumu otomatik devralır.
#
# GÜVENLİ 'if' KULLANIMI: bu dosya vhost.conf.tpl/vhost-ssl.conf.tpl'in
# 'server{}' bloğunun İÇİNE include edilir, bir 'location{}' bloğunun DEĞİL.
# nginx'in "if is evil" uyarısı yalnız 'location' bağlamındaki 'if'ler için
# geçerlidir (birden fazla directive/rewrite zincirlemesi orada öngörülemez
# davranışa yol açabilir); 'server' bağlamında doğrudan 'return' İÇEREN tek
# satırlık bir 'if' resmi olarak güvenli kabul edilen istisnalardan biridir.
if ($blocked_country) {
    return 403;
}
