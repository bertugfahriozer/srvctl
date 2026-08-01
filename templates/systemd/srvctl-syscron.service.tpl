# TOKENS: CRON_NAME CRON_DESCRIPTION CRON_COMMAND RUNTIME_MAX
# Besleyen: lib/cron.sh (ayrı bir görevde yazılıyor) — SİSTEM KAPSAMLI
# (root) cron; domain izolasyonu YOK (bkz. aşağıdaki KAPSAM KARARI bloğu).
# TOKEN listesi görev tanımının SÖZLEŞMESİDİR — tek taraflı GENİŞLETİLMEMELİ.
#
# ADLANDIRMA SÖZLEŞMESİ: srvctl-syscron-{{CRON_NAME}}.service (+ .timer).
# CRON_NAME dosya ADINA gömülür — srvctl-cron.service.tpl başlığındaki AYNI
# path-traversal uyarısı burada da geçerlidir: lib/cron.sh, CRON_NAME'i
# assert_safe_ident (core.sh) ile DOĞRULAMAK ZORUNDADIR.
[Unit]
Description=srvctl Sistem Cron ({{CRON_NAME}}): {{CRON_DESCRIPTION}}
Documentation=man:systemd.service(5)

[Service]
Type=oneshot
# User= BELİRTİLMEZ → systemd varsayılanı root'tur; bu KASITLI bir
# seçimdir. Sistem-kapsamlı cron'un tipik kullanım alanı (apt/upgrade,
# certbot yenileme, yedekleme, log/rotasyon, disk/servis bakımı) root
# yetkisi GEREKTİRİR. Per-job kullanıcı override'ı bu TOKENS kontratında
# YOK — böyle bir ihtiyaç çıkarsa ayrı bir USER token'ı (ve muhtemelen
# domain cron'a yönlendirme önerisi) bir TAKİP maddesidir.
#
# ÇAKIŞMA ENGELİ / ZAMAN AŞIMI: srvctl-cron.service.tpl'deki (domain
# kapsamlı) AYNI gerekçe BİREBİR geçerlidir — Type=oneshot + tekil unit adı
# job coalescing sağlar (systemd.unit(5) "Merging of jobs"), RuntimeMaxSec
# İLE TimeoutStartSec'in AYNI değere sabitlenmesi Type=oneshot'un
# 'DefaultTimeoutStartSec' (varsayılan ~90s) tuzağını (uzun süren bir job'un
# RUNTIME_MAX'a ulaşmadan 90. saniyede sessizce öldürülmesi) bertaraf eder.
RuntimeMaxSec={{RUNTIME_MAX}}
TimeoutStartSec={{RUNTIME_MAX}}

# ─── ExecStart: kabuk sarmalama + komut enjeksiyonu SÖZLEŞMESİ ───
# srvctl-cron.service.tpl başlığındaki UZUN yorumla BİREBİR AYNI sözleşme
# geçerlidir (özet): (1) CRON_COMMAND TEK TIRNAK içine yerleştirilir —
# lib/cron.sh, ham komuttaki HER '\' karakterini ÖNCE '\\' olarak, SONRA
# HER "'" karakterini "\'" olarak kaçırmak ZORUNDADIR
# (_cron_escape_unit_squote — systemd.syntax(7)'nin C-tarzı kaçış tablosu;
# POSIX kabuğun "' → '\''" deseni systemd'nin KENDİ tokenizer'ında ÇALIŞMAZ
# — GERÇEK üretim sunucusunda 'Unterminated quoted string' ile ÖLÇÜLDÜ,
# bkz. srvctl-cron.service.tpl). (2) systemd, ExecStart satırının
# TAMAMINDA KENDİ '%' specifier genişletmesini YAPAR (kabuktan BAĞIMSIZ) —
# ham komutta literal '%' varsa lib/cron.sh bunu '%%' olarak İKİLEMELİDİR.
# render_template (core.sh) yalnız satırsonu/CR'yi reddeder, bu kaçışları
# YAPMAZ — SORUMLULUK lib/cron.sh'TADIR. Sistem cron'u FLOCK_PREFIX
# TAŞIMAZ (bir domain'e bağlı olmadığından deploy kilidi anlamsızdır — bkz.
# lib/cron.sh dosya başı yorumu) — ExecStart HER ZAMAN doğrudan '/bin/sh'
# ile başlar.
ExecStart=/bin/sh -c '{{CRON_COMMAND}}'

# Restart= BİLİNÇLİ OLARAK KULLANILMIYOR (görev tanımı madde 5) — domain
# cron İLE AYNI gerekçe: "bildir + kaydet, OTOMATİK TEKRAR YOK", YAN ETKİLİ
# root komutlarında (ör. bir paket yükseltmesi/bildirim) TEKRAR ZARARLI
# olabilir. RemainAfterExit=yes İLE AYNI gerekçe (srvctl-cron.service.tpl'e
# bkz: ExecMainStatus zaten bağımsız okunur, RemainAfterExit yalnız BAŞARILI
# çalışmayı 'active (exited)' olarak KALICI kılıp inactive/active/failed
# ÜÇ durumunu 'is-active' düzeyinde ayırt edilebilir yapar).
RemainAfterExit=yes

# ÇIKTI (görev tanımı madde 9) — domain cron İLE AYNI gerekçe: varsayılan
# zaten journal'dır, AÇIKÇA yazmak niyeti belgeler ve bir üst düzey
# drop-in'in sessizce StandardOutput=null YAPMASINA karşı korur.
# journalctl -u srvctl-syscron-<ad>.service lib/cron.sh 'log' alt
# komutunun veri kaynağıdır.
StandardOutput=journal
StandardError=journal

# ═══════════════════════════════════════════════════════════════════
# KAPSAM KARARI — SERTLEŞTİRME DENGESİ (görev tanımı madde 7): "Root
# cron'un neyi yapması gerektiği BİLİNMEDİĞİNDEN aşırı kısıtlama
# kırılganlık yaratır." Aşağıdaki blok bu dengeyi İKİ KATMANA ayırır:
#   (A) ÇEKİRDEK-İÇİ davranışları kısıtlayan yönergeler — NEREDEYSE HİÇBİR
#       admin/backup/bakım script'inin ihtiyaç DUYMADIĞI (modül yükleme,
#       saat/hostname/cgroup/kernel-log değiştirme, gerçek-zamanlı
#       zamanlama) — bunlar EKLENDİ, kırılma riski ÇOK DÜŞÜK.
#   (B) DOSYA SİSTEMİ/YETKİ kısıtlayan yönergeler — hedef komut/yol
#       BİLİNMEDİĞİNDEN (bu TOKENS kontratında bir dizin/capability
#       token'ı YOK) BİLİNÇLİ OLARAK ATLANDI; aşağıda TEK TEK gerekçeyle
#       listelenir.
# ═══════════════════════════════════════════════════════════════════
NoNewPrivileges=true
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictRealtime=yes
SystemCallArchitectures=native

# SystemCallFilter: domain cron/worker/scheduler'daki KAPSAMLI deny
# listesinin BİLİNÇLİ OLARAK DARALTILMIŞ bir alt kümesi. YALNIZ neredeyse
# SIFIR meşru admin-script kullanımı olan, YÜKSEK istismar değerli çekirdek
# ilkellikleri (kernel kodu/modül DEĞİŞTİRME, kexec, en yeni/az-denetlenmiş
# arayüzler) kapatılır:
SystemCallFilter=~kexec_load kexec_file_load init_module finit_module delete_module create_module query_module pivot_root bpf io_uring_setup io_uring_enter io_uring_register
#
# DOMAIN LİSTESİNDEN BİLİNÇLİ OLARAK ÇIKARILANLAR (izin verilenler) —
# root'un GERÇEK dünyadaki meşru kullanım senaryolarıyla ÇATIŞTIĞI İÇİN:
#   mount/umount2/swapon/swapoff → yedekleme script'leri harici/ağ depolama
#                                   bağlayabilir (NFS/CIFS hedefi, LUKS/
#                                   loop-mount arşiv açma).
#   reboot                        → planlı bakım yeniden başlatması meşru
#                                   bir root-cron senaryosudur.
#   ptrace/process_vm_readv/write → izleme/tanılama script'leri (ör. bir
#                                   servisin bellek/durum denetimi, coredump
#                                   analizi).
#   unshare/setns                 → konteyner/izolasyon araçları (ör. bir
#                                   yedekleme script'i kendi chroot/namespace
#                                   'ı içinde çalışabilir) — AYRICA bkz.
#                                   RestrictNamespaces'in KASITLI
#                                   KULLANILMAMA notu altta (bu izinle
#                                   ÇELİŞMEMESİ İÇİN).
#   perf_event_open/keyctl/...    → performans ölçümü/kimlik-bilgisi
#                                   anahtarlığı (ör. CIFS mount kimlik
#                                   bilgisi) kullanan nadir ama meşru
#                                   araçlar.

# PrivateTmp: root cron'da TARİHSEL bir açık sınıfına (öngörülebilir
# PAYLAŞILAN /tmp dosya adı + sembolik link/yarış saldırısı — klasik "root
# cron + /tmp" CVE deseni) karşı ucuz ve NEREDEYSE HİÇ script'i BOZMAYAN
# bir önlemdir. NADİR istisna: başka bir process'le HOST /tmp'i ÜZERİNDEN
# KASITLI dosya paylaşan bir script — böyle bir job için
# 'systemctl edit srvctl-syscron-<ad>.service' ile 'PrivateTmp=no' drop-in'i
# eklenmelidir (şablonun İLERİDE per-unit drop-in ile GEÇERSİZ kılınabilir
# olması BİLİNÇLİ bir tasarımdır).
PrivateTmp=yes

# ═══ ATLANANLAR (kasıtlı — kırılganlık riski > güvenlik kazancı) ═══
#  - ProtectSystem=/ProtectHome=: hedef yol BİLİNMİYOR (bu TOKENS
#    kontratında bir dizin token'ı YOK) — 'strict' altında ReadWritePaths=
#    olmadan NEREDEYSE HER root script'i (log yazma, /etc güncelleme,
#    /root altını okuma — ör. '~/.my.cnf' veritabanı kimlik bilgisi
#    dosyası) KIRILIR.
#  - RestrictSUIDSGID: 'apt upgrade' gibi bir root-cron paket yükseltmesi,
#    bir paketin postinst script'inde meşru bir 'chmod u+s' çağrısı
#    yapabilir (ör. sudo/ping paketleri) — bu yönerge o çağrıyı EPERM ile
#    KIRAR.
#  - CapabilityBoundingSet: hangi capability'lerin gerektiği BİLİNMİYOR.
#  - MemoryDenyWriteExecute: Node.js/V8 ve PHP JIT (opcache.jit) gibi
#    JIT-derleyen çalışma zamanları bu yönergeyle SIGSYS ile ÇÖKER — kök
#    komut KEYFİ olduğundan (bir 'node script.js' cron'u OLASI), bu yönerge
#    DAHİL EDİLMEDİ.
#  - RestrictNamespaces: yukarıdaki SystemCallFilter'da unshare/setns
#    BİLİNÇLİ OLARAK izinliyken bu yönergeyi de eklemek AYNI davranışı
#    FARKLI bir mekanizmayla tekrar ENGELLERDİ (çelişkili/gereksiz) —
#    KULLANILMADI.

[Install]
WantedBy=multi-user.target
