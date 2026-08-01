# TOKENS: SAFE_NAME DOMAIN WEB_USER WORKING_DIR CRON_NAME CRON_DESCRIPTION
#         CRON_COMMAND RUNTIME_MAX DOMAIN_ROOT FLOCK_PREFIX
# Besleyen: lib/cron.sh (ayrı bir görevde yazılıyor) — bu şablonun TOKEN
# listesi görev tanımının SÖZLEŞMESİDİR, tek taraflı GENİŞLETİLMEMELİDİR.
# FLOCK_PREFIX (GERÇEK üretim sunucusunda ölçülen bir kaçış hatasından
# SONRA EKLENDİ — bkz. ExecStart= yorumu): ya boş dizgedir (sistem cron'u
# taşımaz, ya da flock yoksa) ya da "/usr/bin/flock -n -E 75
# '<kaçırılmış-kilit-yolu>' " (sonda BOŞLUK VAR — '/bin/sh'den önce ayraç).
# DOMAIN_ROOT = '${WEB_ROOT}/${domain}' — worker.service.tpl/
# scheduler.service.tpl İLE BİREBİR AYNI besleme deseni (bkz.
# lib/domain.sh:_domain_render_worker_unit). BU TOKEN SONRADAN EKLENDİ
# (HOST bulgusu — bkz. aşağıdaki ReadWritePaths= yorumu): ilk sürüm yalnız
# WORKING_DIR kullanıyordu ve bu, 'writable/'/'storage/'/'shared/' gibi
# KARDEŞ dizinlere yazan HER TİPİK cron işini (cache temizliği, log
# rotasyonu) EROFS ile KIRIYORDU — bir TAKİP maddesi değil, İŞLEVSEL bir
# regresyondu; bu yüzden token kontratı GENİŞLETİLDİ.
#
# ADLANDIRMA SÖZLEŞMESİ (lib/cron.sh bu adı üretir/kullanır):
#   srvctl-cron-{{SAFE_NAME}}-{{CRON_NAME}}.service (+ eşlenik .timer)
# CRON_NAME dosya ADINA gömülür — render_template yalnız satırsonu/CR'yi
# reddeder, '/' veya '..' KARAKTERİNİ ENGELLEMEZ. lib/cron.sh, CRON_NAME'i
# assert_safe_ident (core.sh) ile DOĞRULAMAK ZORUNDADIR; aksi halde
# '../../etc/cron.d/x' türü bir CRON_NAME systemd unit dizini DIŞINA yazan
# bir yol geçişine (path traversal) dönüşür. Bu şablon bunu KENDİSİ
# ENGELLEYEMEZ (dosya adı render'dan ÖNCE, çağıran tarafta belirlenir).
[Unit]
Description=srvctl Cron ({{DOMAIN}} / {{CRON_NAME}}): {{CRON_DESCRIPTION}}
Documentation=man:systemd.service(5)
# srvctl-worker/scheduler İLE AYNI ordering: FPM master unit domain'in
# slice/cgroup ağacını kurar (bkz. srvctl-fpm.service.tpl), cron da AYNI
# srvctl-{{SAFE_NAME}}.slice'a bağlanır (altta) — bu yüzden ondan SONRA
# başlaması yarım kalmış bir slice durumuna düşmeyi önler. network.target,
# CRON_COMMAND'ın bir webhook/health-check gibi ağ çağrısı yapabileceği
# varsayımıyla eklenir (scheduler/worker şablonlarıyla BİREBİR aynı desen).
After=network.target srvctl-fpm-{{SAFE_NAME}}.service

[Service]
Type=oneshot
# ÇAKIŞMA ENGELİ (görev tanımı madde 1): 'oneshot' + TEKİL unit adı ikilisi
# doğal bir kilit sağlar. Timer bir SONRAKİ tetiklemede yalnızca
# 'systemctl start <bu-unit>' çağırır; bu unit HÂLÂ 'activating'
# durumundaysa (önceki çalışma bitmemiş) systemd bu ikinci start job'unu
# MEVCUT job'a MERGE EDER (job coalescing, bkz. systemd.unit(5) "Merging
# of jobs") — YENİ bir süreç FORK EDİLMEZ, üst üste binme (overlap)
# OLUŞMAZ. Bu davranış systemd'nin job kuyruğunun EN TEMEL parçasıdır;
# 249 (22.04) ile 255 (24.04) arasında FARK YOKTUR — ayrı bir kilit
# dosyası/mekanizması GEREKMEZ.
User={{WEB_USER}}
Group={{WEB_USER}}

# Bu unit HER TETIKLEMEDE yeniden fork/exec edildiğinden (worker'daki
# UZUN ÖMÜRLÜ süreç gibi DEĞİL) WorkingDirectory HER ÇALIŞMADA güncel
# 'current' sembolik linkini baştan çözer — worker.service.tpl'deki
# "deploy sonrası restart şart" sorunu burada YOKTUR (scheduler.service.tpl
# ile AYNI gerekçe).
WorkingDirectory={{WORKING_DIR}}

# ─── ExecStart: kabuk sarmalama + komut enjeksiyonu SÖZLEŞMESİ ───
# CRON_COMMAND, kullanıcının klasik crontab satırındaki KOMUT kısmıdır —
# '&&' / '|' / ';' / yönlendirme / '$DEĞİŞKEN' gibi KABUK semantiği
# BEKLENİR (aksi halde crontab'tan taşınan hiçbir gerçek iş çalışmaz).
# systemd'nin ExecStart= ayrıştırıcısı bir KABUK DEĞİLDİR (KENDİ
# tokenizer'ıyla ayrıştırır — bkz. systemd.syntax(7) "Quoting"; redirection/
# pipe/'&&' TANIMAZ) — bu yüzden '/bin/sh -c' SARMALAMA ZORUNLUDUR.
#
# GERÇEK üretim sunucusunda ÖLÇÜLEN HOST BULGUSU: TEK TIRNAK İÇEREN her
# komut ('echo tirnak testi' gibi) 'sh: Unterminated quoted string'
# (status=2) ile ÇÖKÜYORDU — tırnaksız komutlar SORUNSUZDU, yani AppArmor/
# DAC değil, SAF bir kaçış hatasıydı. Kök neden: systemd'nin OWN
# tokenizer'ı, POSIX kabuğun AKSİNE, ters-eğik-çizgiyi TEK TIRNAK İÇİNDE
# BİLE bir kaçış karakteri sayar (C-tarzı kaçış tablosu — '\\'→'\',
# "\\'"→"'", ...) — POSIX'in "' → '\''" deseni bu tokenizer'da FARKLI
# yorumlanıp tırnağı dengesiz bırakıyordu. Bunun ÜZERİNE eski tasarım
# flock'u KENDİ '-c' bayrağıyla (İKİNCİ bir iç kabuk çağrısı) sarmaladığı
# İÇİN aynı (yanlış) kaçış İKİ KEZ uygulanıyordu — İKİ ayrı hata üst üste
# binmişti (yanlış algoritma + gereksiz ikinci katman).
#
# render_template (core.sh) yalnız değerin satırsonu/CR içermediğini
# doğrular; TEK/ÇİFT TIRNAK, '$', ters-eğik-çizgi, backtick gibi KABUK
# METAKARAKTERLERİNİ KAÇIRMAZ (bilerek — core.sh generic bir string-replace
# katmanıdır, şablon-özel kaçış mantığı TAŞIMAZ). Bu yüzden aşağıdaki
# SARMALAMA SÖZLEŞMESİ lib/cron.sh'A YÜKLENİR:
#   1) FLOCK_PREFIX (yeni token — bkz. dosya başı TOKENS notu): flock artık
#      KENDİ '-c'siyle DEĞİL, exec-form ile çağrılır ('flock <bayraklar>
#      <kilit-dosyası> <komut> [argüman...]') — flock hiçbir metni yeniden
#      AYRIŞTIRMAZ, argv'yi OLDUĞU GİBİ execve() eder. Böylece TEK bir
#      "metni kabuk bağlamına göm" noktası kalır: aşağıdaki '/bin/sh -c
#      '...''. FLOCK_PREFIX boşsa (sistem cron'u/flock yok) satır doğrudan
#      '/bin/sh' ile başlar.
#   2) CRON_COMMAND burada TEK TIRNAK içine yerleştirilir. lib/cron.sh,
#      kullanıcıdan aldığı HAM komuttaki HER '\' karakterini ÖNCE '\\'
#      olarak, SONRA HER "'" karakterini "\'" olarak kaçırmak ZORUNDADIR
#      (_cron_escape_unit_squote — systemd.syntax(7)'nin C-tarzı kaçış
#      tablosu; POSIX'in "'\''" deseni YUKARIDAKİ HOST bulgusu nedeniyle
#      KULLANILMAZ). FLOCK_PREFIX içindeki kilit dosyası yolu da AYNI
#      fonksiyonla, KENDİ tek-tırnak span'i için AYRICA kaçırılır.
#   3) systemd, kabuğu görmeden ÖNCE ExecStart= satırının TAMAMINDA KENDİ
#      '%' SPECIFIER genişletmesini yapar (ör. '%h', '%i') — bu şablondan
#      BAĞIMSIZ, systemd.unit(5)'in temel davranışıdır ve yalnız
#      ExecStart'a değil Description= gibi diğer değerlere de UYGULANIR.
#      Ham komutta/açıklamada literal '%' varsa lib/cron.sh bunu '%%'
#      olarak İKİLEMELİDİR — aksi halde unit YÜKLENEMEZ (systemd tanınmayan
#      specifier'da fail-closed davranır) ya da specifier YANLIŞ genişler.
# Bu kaçış adımları render_template'in string-replace doğasıyla BU
# ŞABLONDA UYGULANAMAZ — bu yüzden SÖZLEŞME olarak burada belgeleniyor.
ExecStart={{FLOCK_PREFIX}}/bin/sh -c '{{CRON_COMMAND}}'

Slice=srvctl-{{SAFE_NAME}}.slice
# worker/scheduler İLE AYNI gerekçe: FPM'in chroot/setuid'li profili
# DEĞİL, ayrı ve daha dar bir CLI profili (bkz. templates/apparmor/
# profile-cli.tpl) — cron job'unun FPM'in socket/pid dosyalarına ya da
# chroot capability'lerine ihtiyacı YOKTUR.
AppArmorProfile=srvctl-{{SAFE_NAME}}-cli

# ZAMAN AŞIMI (görev tanımı madde 2): kaçak/asılı bir job SUNUCUYU
# TÜKETMEDEN öldürülmeli. NOT — Type=oneshot İÇİN BİLİNEN bir tuzak: eğer
# yalnız RuntimeMaxSec ayarlanır da TimeoutStartSec varsayılanında
# (DefaultTimeoutStartSec, tipik olarak 90s) bırakılırsa, oneshot bir
# servis "başlangıcı" ExecStart TAMAMEN BİTENE kadar 'activating' sayılır
# — yani RUNTIME_MAX 90 saniyeden BÜYÜKSE job SESSİZCE 90. saniyede
# TimeoutStartSec tarafından öldürülür, RuntimeMaxSec HİÇ DEVREYE GİRMEDEN
# (systemd sürümüne göre RuntimeMaxSec'in oneshot'un 'activating' evresini
# kapsayıp kapsamadığı belirsizdir — bu şablon HER İKİ mekanizmayı da AYNI
# değere sabitleyerek bu belirsizliğe bel BAĞLAMAZ). Bu yüzden İKİSİ BİRDEN
# ayarlanır:
RuntimeMaxSec={{RUNTIME_MAX}}
TimeoutStartSec={{RUNTIME_MAX}}

# ─── Sertleştirme — worker/scheduler İLE BİREBİR AYNI blok/gerekçe ───
ProtectSystem=strict
ProtectHome=yes
# DÜZELTME (koordinatör bulgusu — bu bir TAKİP maddesi DEĞİL, İŞLEVSEL bir
# kırılmaydı): İLK sürüm burada yalnızca WORKING_DIR kullanıyordu ('current'
# sembolik linki — TEK BİR release'i kapsar). Ama gerçek cron işlerinin
# NEREDEYSE TAMAMI (CI4: writable/ — cache/logs/session/uploads; Laravel:
# storage/ — logs/cache/sessions; her ikisi: domain'in üst düzey logs/;
# deploy'un shared/writable, shared/storage, shared/var-log alanları)
# 'current' DIŞINDA, KARDEŞ dizinlerdedir (release içindeki writable/
# storage zaten shared/'a symlink — bkz. lib/deploy.sh). WORKING_DIR TEK
# BAŞINA bunları KAPSAMAZ; ProtectSystem=strict altında bu yollara yazma
# EROFS ile BAŞARISIZ OLUR — yani "her gece cache temizle"/"log rotasyonu"
# gibi EN TİPİK cron işleri ÇALIŞMAZDI.
#
# KARAR — PARİTE (worker/scheduler İLE AYNI DOMAIN_ROOT deseni), alt
# dizinleri TEK TEK SAYMAK YERİNE:
#   1) DAR/enumerasyon yaklaşımı (yalnız 'writable+storage+logs' gibi
#      BİLİNEN adları ReadWritePaths='a ekle) FRAMEWORK'E BAĞIMLIDIR ve bu
#      şablonun (render_template'in KOŞULSUZ string-replace doğası
#      gereği) BİLEMEYECEĞİ bir bilgiye ihtiyaç duyar; yeni bir framework
#      dizini (ör. Symfony'nin var/, WordPress'in wp-content/) eklendiğinde
#      SESSİZCE aynı EROFS sınıfını YENİDEN üretir — CLAUDE.md'nin
#      belgelediği 'token/yol eksik besleme' hata sınıfının BİR BAŞKA
#      görünümü.
#   2) DOMAIN_ROOT'un TAMAMINI (WEB_ROOT/<domain> — current/releases/
#      shared/logs/tmp/sessions HEPSİ) yazılabilir kılmak GÜVENLİK
#      SINIRINI GERÇEKTEN GENİŞLETMEZ: bu dizin zaten AYNI Linux
#      kullanıcısına ({{WEB_USER}}) ait (DAC sahipliği — chown), AppArmor
#      CLI profili ve AYRI UID zaten BAŞKA domainlere/host'un geri kalanına
#      sızmayı engelliyor (asıl izolasyon SINIRI domain'İN KENDİ ağacı
#      DEĞİL, domainLER ARASI sınırdır). ProtectSystem=strict burada İKİNCİ
#      bir savunma katmanıdır (yanlışlıkla/istismarla /etc, /usr, host
#      /home gibi DOMAIN DIŞI yollara yazılmasını engellemek için) — bunu
#      korurken domain'in KENDİ verisine tam erişim vermek güvenlik
#      kaybı DEĞİLDİR.
#   3) worker.service.tpl/scheduler.service.tpl İLE AYNI deseni kullanmak
#      (üç NEREDEYSE ÖZDEŞ systemd şablonu arasında) bakım yükünü ve
#      gelecekteki sürüklenme riskini AZALTIR.
# DOMAIN_ROOT lib/domain.sh:_domain_render_worker_unit İLE AYNI şekilde
# 'DOMAIN_ROOT=${WEB_ROOT}/${domain}' olarak beslenmelidir; render SONRASI
# leftover-token guard'ı (_domain_assert_no_leftover_tokens) bunu ayrıca
# doğrular.
ReadWritePaths=-{{DOMAIN_ROOT}}
# PrivateTmp: worker.service.tpl'deki AYNI caveat geçerlidir (SİSTEM
# /tmp'ini izole eder, uygulamanın kendi WEB_ROOT/<domain>/tmp'ini DEĞİL) —
# ayrıca cron script'lerinde TARİHSEL bir açık sınıfına (öngörülebilir
# paylaşılan /tmp dosya adı + sembolik link/yarış saldırısı) karşı ucuz bir
# önlemdir.
PrivateTmp=yes
RestrictSUIDSGID=true
SystemCallFilter=~kexec_load kexec_file_load reboot swapon swapoff mount umount2 pivot_root init_module finit_module delete_module create_module query_module unshare setns userfaultfd perf_event_open bpf add_key request_key keyctl ptrace process_vm_readv process_vm_writev kcmp lookup_dcookie io_uring_setup io_uring_enter io_uring_register
SystemCallArchitectures=native
NoNewPrivileges=true

# Restart= BİLİNÇLİ OLARAK KULLANILMIYOR (görev tanımı madde 5 — kullanıcı
# kararı: "bildir + kaydet, OTOMATİK TEKRAR YOK"). Bir cron job'u
# başarısız olduğunda systemd'nin kendiliğinden yeniden denemesi, YAN
# ETKİLİ komutlarda (ör. bir e-posta/webhook/ödeme bildirimi gönderen bir
# job) TEKRARLANMIŞ yan etkiye yol açabilir. Bildirim/kayıt lib/cron.sh
# tarafında yapılacaktır (muhtemelen bir OnFailure= hook ya da periyodik
# 'systemctl is-failed' taraması ile) — bu şablonun sorumluluğu yalnızca
# BAŞARISIZLIĞIN DOĞRU RAPORLANMASINI garanti etmektir:
#
# RemainAfterExit=yes: ExecMainStatus/ExecMainCode/Result zaten
# RemainAfterExit'TEN BAĞIMSIZ olarak systemd tarafından SON çalışmanın
# çıkış kodunu tutar ('systemctl show -p ExecMainStatus,ExecMainCode,
# Result' HER ZAMAN okunabilir). RemainAfterExit=yes'in KATTIĞI şey
# FARKLIDIR: varsayılan (no) ile BAŞARILI bir çalışma sonrası ActiveState
# ANINDA 'inactive (dead)' olur — bu durum, job'un "HİÇ ÇALIŞMAMIŞ"
# durumuyla 'systemctl is-active' düzeyinde GÖRSEL OLARAK AYIRT
# EDİLEMEZ hale gelir. RemainAfterExit=yes ile başarılı çalışma 'active
# (exited)' olarak KALICI hale gelir; böylece TEK bir 'is-active'/
# 'is-failed' taramasıyla ÜÇ durum ayırt edilebilir: inactive (hiç
# çalışmadı) / active (son çalışma BAŞARILI) / failed (son çalışma
# BAŞARISIZ — bu zaten RemainAfterExit'ten bağımsız oluşur). lib/cron.sh'ın
# "kaydet" akışı bu sinyali kullanabilir.
RemainAfterExit=yes

# ÇIKTI (görev tanımı madde 9): stdout/stderr AÇIKÇA journal'a
# yönlendirilir — systemd'nin varsayılanı zaten budur, ama bu depoda
# "varsayılana güvenme, niyeti YAZ" kuralına uyularak açıkça belirtilir
# (ör. bir üst düzey drop-in ileride StandardOutput=null OLURSA bu satır
# sessiz bir davranış değişikliğini ÖNLER). journalctl -u
# srvctl-cron-<sname>-<ad>.service ile hem CRON_COMMAND'ın çıktısı hem de
# systemd'nin kendi yaşam döngüsü mesajları TEK YERDEN okunur — lib/cron.sh
# 'log' alt komutunun veri kaynağı budur.
StandardOutput=journal
StandardError=journal
