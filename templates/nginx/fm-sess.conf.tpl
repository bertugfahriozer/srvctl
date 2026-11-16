# TOKENS: (yok)
# Besleyen: lib/domconf.sh — _domconf_fm_render_sess / _domconf_fm_sess_conf_ensure ('srvctl domain fm-auth <alan> on' ve
# 'fm-root <alan> --apply' 20 (yükleme) dosyasını yazmadan ÖNCE). Dosya /etc/nginx/conf.d/srvctl-fmsess.conf olarak yazılır
# (root:root 644, SRVCTL ÜRETİR, HOST BAŞINA TEK DOSYA; alan başına dosya yok ⇒ ad çakışması ve alan kaldırmada temizlik yok).
# 'fm-auth off' ve 'domain remove' bu dosyaya DOKUNMAZ: bölge kullanılmıyorsa zararsızdır (20 kapalıyken kimse başvurmaz).
#
# NE (E66): yükleme OTURUMU (uploadid + bilet) başına tek eşzamanlı PUT. 20'deki 'limit_conn srvctl_fmsess 1' bu bölgeyi kullanır.
#   Uygulamanın bilet ucu sıradaki ofseti yetkilendirme anında ilerletir; değiştirilmiş bir istemci aynı oturumun ardışık
#   ofsetlerini PARALEL gönderebilir (pCloud 2068 ile reddeder) ama nginx her uçuştaki istek için @fm_up'ta ≤4 MiB tampon tutar.
#   Meşru istemci parçaları zaten ARDIŞIK gönderir (bir PUT'un yanıtı gelmeden sonrakini başlatmaz) ⇒ yanlış red yok.
#
# ANAHTAR = '<uploadid>:<biletin ilk 32 hanesi>'. YALNIZ 'PUT' + 20'nin biçim kapısıyla AYNI yol (/_fm/up/<rakam 1-20>/<rakam 1-20>, sorgu/'%'/'..'
#   yok) + uygulamanın kabul ettiği biçimde bilet (X-Fm-Ticket: tam 64 küçük hex) için DOLU. Başka her istek (biçimsiz yol, GET/OPTIONS/…,
#   bilet YOK ya da biçimce geçersiz) boş anahtar alır ve nginx boş anahtarı SAYMAZ (limit_conn belgesi) ⇒ o istekler 20'nin kendi
#   403/411 kapılarına düşer ve HİÇBİR yuva tutamaz.
#   NEDEN BİLET: limit_conn PREACCESS aşamasında, auth_request'ten (ACCESS) ÖNCE koşar; yani sayım auth sonucunu BİLMEZ. Anahtar yalnız uploadid
#   olsaydı, uploadid'i bilen yetkisiz biri (biletsiz, 403 alan ama gövdeyi damla damla yollayarak ~30 sn yaşayan istek) meşru oturumun
#   yuvasını tutabilirdi (B1, CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:N/A:L = 3.7). Biletle anahtarlanınca saldırgan kendi (sahte) anahtarını
#   tüketir; bileti bilmeden meşru oturumun anahtarına ulaşamaz. Bilet oturum boyunca SABİTTİR (init'te verilir; istemci her parçada ve
#   resume'dan sonra aynı biletle gönderir) ⇒ yanlış red yok.
#   SUNUCU ADI ANAHTARDA YOK: ana alan ve 'up.<alan>' (fm-up) sunucusu AYNI bölgeyi/anahtarı paylaşır ⇒ oturum başına tek PUT iki sunucu
#   toplamında geçerlidir (B2). Farklı alanların (farklı pCloud hesabı) aynı sayısal uploadid'i, biletleri farklı olduğundan çakışmaz.
#   IP ANAHTARDA YOK: kota oturum başına TEK (IP değiştirerek ikinci uçuş açılamaz).
#   BİLET GÜNLÜĞE SIZMAZ: limit_conn'un hata günlüğü satırı yalnız bölge adını ve istek satırını yazar, anahtarı yazmaz (tests/test_edge_up_sess_real.sh
#   bölüm 9: nginx 1.28 hata günlüğünde bilet/öneki 0 eşleşme); anahtar yalnız paylaşılan bellektedir ve biletin yalnız ilk 32 hanesini (128 bit) içerir.
#   Anahtar uzunluğu ≤ 20 + 1 + 32 = 53 bayt (limit_conn anahtar sınırı 255).
#
# map ve limit_conn_zone YALNIZ http bağlamındadır (20 sunucu bağlamında include edilir) — bu yüzden ayrı bir conf.d dosyası.
map "$request_method|$request_uri|$http_x_fm_ticket" $srvctl_fmsess_key {
    default "";
    "~^PUT\|/_fm/up/([0-9]{1,20})/[0-9]{1,20}\|([0-9a-f]{32})[0-9a-f]{32}$" "$1:$2";
}

limit_conn_zone $srvctl_fmsess_key zone=srvctl_fmsess:10m;
