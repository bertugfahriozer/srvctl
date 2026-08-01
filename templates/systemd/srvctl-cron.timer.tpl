# TOKENS: SAFE_NAME DOMAIN CRON_NAME CRON_DESCRIPTION ON_CALENDAR
#         RANDOMIZED_DELAY CRON_PERSISTENT
# Besleyen: lib/cron.sh — srvctl-cron.service.tpl İLE EŞLENİK render edilir
# (aynı SAFE_NAME + CRON_NAME çiftiyle). Bu dosyanın TOKEN listesi de o
# dosyayla AYNI sözleşme kapsamındadır — bkz. srvctl-cron.service.tpl
# başlığındaki CRON_NAME/dosya-adı path-traversal notu (aynı risk burada
# da geçerlidir, çünkü CRON_NAME bu dosyanın da ADINA gömülür).
# CRON_PERSISTENT: systemd boolean değeri ('true'/'false') — lib/cron.sh
# BUNU DOĞRULAMALI/NORMALİZE ETMELİDİR (render_template yalnız CRLF
# reddeder, boolean sözdizimini KONTROL ETMEZ; geçersiz bir değer systemd
# tarafında unit YÜKLEME hatası olarak fail-closed ortaya çıkar, sessiz bir
# güvenlik açığı DEĞİL — ama yine de kaynak taraf validasyonu gerekir).
# Aşağıdaki Persistent= yorumuna bkz.: bu token SONRADAN eklendi (koordinatör
# talebi — "yedekleme mi/cache-temizliği mi" gerilimi TEK bir sabit
# değerle ÇÖZÜLEMEZ).
[Unit]
Description=srvctl Cron Timer ({{DOMAIN}} / {{CRON_NAME}}): {{CRON_DESCRIPTION}}
Documentation=man:systemd.timer(5)

[Timer]
# ON_CALENDAR: kullanıcının klasik 5 alanlı crontab ifadesi lib/cron.sh
# tarafından systemd calendar-event söz dizimine ÇEVRİLİR (ör.
# '*/5 * * * *' → '*-*-* *:0/5:00'); bu şablon çeviriyi YAPMAZ, ÇEVRİLMİŞ
# değeri OLDUĞU GİBİ basar.
OnCalendar={{ON_CALENDAR}}
AccuracySec=1s

# RASTGELE GECİKME (görev tanımı madde 3): 100 domain hedefinde HEPSİ aynı
# ON_CALENDAR değerine (ör. günlük 03:00) sahipse tetikleme anı TAM ÇAKIŞIR
# — CPU/DB/disk I/O aynı saniyede yüz kat katlanır (thundering herd).
# RandomizedDelaySec, HER timer INSTANCE'ı için 0..DEĞER arasında (systemd
# tarafından unit adına göre TUTARLI biçimde türetilen, ama insan için
# ÖNGÖRÜLEMEZ) bir gecikme ekler. Değerin BÜYÜKLÜĞÜ (ör. dakikalık işler
# için birkaç saniye, günlük/ağır işler için birkaç dakika) lib/cron.sh'ın
# 'srvctl cron add' arayüzüne/varsayılanına BIRAKILMIŞTIR — bu şablon salt
# geleni basar.
RandomizedDelaySec={{RANDOMIZED_DELAY}}

# ÇAKIŞMA ENGELİ (görev tanımı madde 1) — TIMER TARAFI: bu timer'IN
# KENDİSİ herhangi bir "tekilleştirme" mantığı TAŞIMAZ/TAŞIMAK ZORUNDA
# DEĞİLDİR. Bir önceki tetiklemenin service'i HÂLÂ çalışıyorsa, bu timer'ın
# bir SONRAKİ elapse'i yalnızca 'systemctl start <service>' ÇAĞIRIR —
# service ZATEN 'activating' durumundaysa systemd bu çağrıyı MEVCUT job'a
# MERGE EDER (yeni süreç FORK ETMEDEN no-op'a iner). Garanti TAMAMEN
# srvctl-cron.service.tpl'deki Type=oneshot + TEKİL unit adı SEÇİMİNDEN
# gelir (bkz. o dosyadaki uzun yorum).
#
# KAÇIRILAN ÇALIŞMALAR (görev tanımı madde 4) — PER-JOB TOKEN (CRON_PERSISTENT),
# SABİT bir değer DEĞİL. KARAR DEĞİŞİKLİĞİ (koordinatör geri bildirimi):
# İLK sürüm burada Persistent=false'u SABİT basıyordu ("crontab-parity"
# gerekçesiyle). Bu YETERSİZDİ çünkü gerilim GERÇEK ve TEK bir varsayılanla
# ÇÖZÜLEMEZ: CRON_COMMAND'ın idempotent mi (ör. bir cache temizliği — TEKRAR
# ZARARSIZ, false DOĞRU) yoksa host kapalıyken kaçarsa MUTLAKA telafi
# edilmesi gereken bir iş mi (ör. gecelik yedekleme — true DOĞRU, false
# SESSİZCE bir günlük yedeği ATLAR) olduğu HİÇ BİLİNMEZ; bu iki senaryo
# TAM TERS varsayılan ister. Enumerasyon/tahmin yerine KARAR kullanıcıya
# (srvctl cron add'ın bir bayrağına) BIRAKILIR — bu şablon salt geleni basar.
#
# lib/cron.sh İÇİN ÖNERİ (bağlayıcı DEĞİL, koordinatöre iletilecek): kullanıcı
# AÇIKÇA belirtmezse varsayılan 'false' kalsın (crontab'tan taşınan bir işin
# EN AZ SÜRPRİZ vereni budur — klasik crontab da anacron olmadan kaçırılan
# çalışmayı TELAFİ ETMEZ); yedekleme gibi işler için kullanıcı bunu AÇIKÇA
# 'true' yapmalı (ör. '--catch-up-on-boot' gibi bir bayrak). CRON_PERSISTENT
# değeri lib/cron.sh tarafından 'true'/'false' dışına DÜŞMEYECEK şekilde
# doğrulanmalıdır (bkz. başlıktaki TOKENS notu).
Persistent={{CRON_PERSISTENT}}

# Unit=: dosya adı deseni (srvctl-cron-<sname>-<ad>.service/.timer) zaten
# örtük eşleşmeyi sağlar; worker/scheduler İLE AYNI gerekçeyle AÇIKÇA
# belirtilir (render/isimlendirme hatasına karşı ek güvenlik ağı).
Unit=srvctl-cron-{{SAFE_NAME}}-{{CRON_NAME}}.service

[Install]
WantedBy=timers.target
