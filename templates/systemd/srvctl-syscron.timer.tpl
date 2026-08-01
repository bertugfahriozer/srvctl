# TOKENS: CRON_NAME CRON_DESCRIPTION ON_CALENDAR RANDOMIZED_DELAY
#         CRON_PERSISTENT
# Besleyen: lib/cron.sh — srvctl-syscron.service.tpl İLE EŞLENİK render
# edilir (aynı CRON_NAME ile). CRON_NAME dosya ADINA gömülür —
# srvctl-cron.service.tpl başlığındaki AYNI path-traversal uyarısı burada
# da geçerlidir. CRON_PERSISTENT: srvctl-cron.timer.tpl İLE AYNI sözleşme
# (systemd boolean 'true'/'false', lib/cron.sh tarafından doğrulanmalı) —
# root cron'un tipik örneği (gecelik yedekleme) bu kararın TAM ORTASINDA
# durduğundan (bkz. Persistent= yorumu altta) SABİT bir değer YERİNE
# per-job token seçildi.
[Unit]
Description=srvctl Sistem Cron Timer ({{CRON_NAME}}): {{CRON_DESCRIPTION}}
Documentation=man:systemd.timer(5)

[Timer]
# ON_CALENDAR: srvctl-cron.timer.tpl İLE AYNI gerekçe — kullanıcının
# klasik crontab ifadesi lib/cron.sh tarafından systemd calendar-event söz
# dizimine ÇEVRİLİR; bu şablon çeviriyi YAPMAZ, ÇEVRİLMİŞ değeri OLDUĞU
# GİBİ basar.
OnCalendar={{ON_CALENDAR}}
AccuracySec=1s

# RASTGELE GECİKME (görev tanımı madde 3): sistem cron'ları AZ SAYIDA
# olsa da (100 domain'in her biri KENDİ cron'una sahipken sistem cron'u
# TEK bir host-geneli listedir) AYNI ON_CALENDAR'a sahip birden fazla
# sistem job'unun (ör. birden fazla yedekleme betiği aynı saatte) DİSK/AĞ
# I/O'sunu aynı anda katlaması İSTENMEZ — domain cron İLE AYNI gerekçe.
RandomizedDelaySec={{RANDOMIZED_DELAY}}

# ÇAKIŞMA ENGELİ (görev tanımı madde 1) — TIMER TARAFI: srvctl-cron.timer.tpl
# İLE BİREBİR AYNI gerekçe. Bu timer HERHANGİ bir tekilleştirme mantığı
# TAŞIMAZ; garanti TAMAMEN eşlenik .service'in Type=oneshot + TEKİL unit adı
# seçiminden gelir (job coalescing — bkz. o dosyadaki yorum).
#
# KAÇIRILAN ÇALIŞMALAR (görev tanımı madde 4) — PER-JOB TOKEN, SABİT DEĞER
# DEĞİL (srvctl-cron.timer.tpl İLE AYNI karar değişikliği/gerekçe — bkz. o
# dosyadaki UZUN yorum). ÖZETLE: root cron'un EN TİPİK örneği BİLE (gecelik
# yedekleme — bu dosyanın kendi CRON_NAME örneği: 'nightly-backup') bu
# kararın TAM ORTASINDA durur: host kapalıyken kaçan bir yedekleme SESSİZCE
# ATLANIRSA bu bir VERİ KAYBI RİSKİDİR (Persistent=true İSTENİR), ama AYNI
# host'ta çalışan bir bildirim/cache-temizliği job'u için AYNI davranış
# SÜRPRİZ bir tekrara yol açar (Persistent=false İSTENİR). TEK bir sabit
# değer bu ikisini AYNI ANDA doğru KARŞILAYAMAZ — karar kullanıcıya
# (srvctl cron add'ın bir bayrağına) bırakılır.
Persistent={{CRON_PERSISTENT}}

# Unit=: dosya adı deseni (srvctl-syscron-<ad>.service/.timer) zaten örtük
# eşleşmeyi sağlar; AÇIKÇA belirtilir (render/isimlendirme hatasına karşı
# ek güvenlik ağı — domain cron İLE AYNI gerekçe).
Unit=srvctl-syscron-{{CRON_NAME}}.service

[Install]
WantedBy=timers.target
