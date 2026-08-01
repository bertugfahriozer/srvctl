# TOKENS: DOMAIN SAFE_NAME WEB_ROOT WEB_USER PHP_VERSION
# Besleyen: lib/domain.sh — _domain_add (satır ~1299) ve _domain_repair
# (satır ~215), render_template'e her ikisi de yukarıdaki 5 token'ı verir.
abi <abi/3.0>,

#include <tunables/global>

# ═══════════════════════════════════════════════
#  AppArmor Profile (CLI/worker): {{DOMAIN}}
#  User: {{WEB_USER}}
#  Bu profil srvctl-worker-{{SAFE_NAME}}@*.service ve
#  srvctl-scheduler-{{SAFE_NAME}}.service/.timer unit'lerine uygulanır.
#
#  NEDEN AYRI PROFİL (srvctl-{{SAFE_NAME}} DEĞİL)?
#  FPM (profile.tpl) chroot()+setuid ile privilege-drop yapan bir MASTER
#  süreci kapsar; bunun için capability (chown/dac_override/setuid/setgid/
#  sys_chroot/kill) ve FPM'e özgü pid/socket/config dosyalarına ihtiyaç
#  duyar. Worker/scheduler ise systemd User={{WEB_USER}} ile DAHA BAŞTAN
#  unprivileged UID olarak execve edilir (chroot YOK, in-process setuid
#  YOK) — bu capability'lerin HİÇBİRİNE ihtiyaç duymaz. En az yetki
#  ilkesi gereği aynı (daha geniş) profili paylaşmak yerine ayrı, dar bir
#  profil kullanılır. BEDELİ: framework yazma yollarını EKLERKEN bu dosya
#  ile profile.tpl'in ilgili bloğu PARALEL güncellenmeli (aşağıdaki
#  yorumlar birbirine referans verir) — DALGA 2/3, yeni bir yazma yolu
#  eklerken İKİ dosyayı da değiştirmeyi unutmamalı.
# ═══════════════════════════════════════════════

profile srvctl-{{SAFE_NAME}}-cli flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # ─── PHP CLI binary'si (php-fpm DEĞİL — /usr/sbin/php-fpm{{PHP_VERSION}}
  #     FPM'e özgüdür, worker /usr/bin/php{{PHP_VERSION}} çalıştırır) ───
  # DÜZELTME (rapor: dalga4/B4, DOĞRULANDI BUG 1 kanıtıyla): önceden yalnız
  # 'mr' verilmişti (kendi metin sayfalarını mmap etmek için) ve exec ('x')
  # İZNİ YOKTU. Ama bu profil altında çalışan süreç (worker/scheduler) çoğu
  # zaman KENDİ ALT SÜRECİNİ açar — Laravel schedule:run'ın
  # ->command()/->exec() görevleri, Symfony Process bileşeni, Horizon/queue
  # supervisor'ları hep bir alt 'php ...' veya 'sh -c "php ..."' çağırır.
  # 'x' izni olmadan bu execve AppArmor'da REDDEDİLİR ama üst süreç
  # (schedule:run) genelde yine de 0 ile çıkar — hata hiçbir yerde
  # görünmez, görev sessizce hiç çalışmaz (fail-open/sessiz kesinti). Bu
  # yüzden TAM YOL (glob'suz) ile 'rix' (mevcut profile INHERIT ederek
  # exec) veriliyor.
  #
  # ÖNCEDEN "blanket 'deny /usr/bin/** x' spesifik allow'dan daha az
  # öncelikli, HOST'ta doğrulanmalı" diye belirsiz bırakılmıştı — BUG 1
  # gerçek VM kanıtı bu varsayımı ÇÜRÜTTÜ: AppArmor'da 'deny' HER ZAMAN
  # 'allow'u ezer, glob/tam-yol SPESİFİKLİĞİNE bakılmaksızın (profile.tpl'de
  # php-fpm'in kendi reload-exec'i TAM DA bu yüzden kırılıyordu). Bu yüzden
  # aşağıdaki 'deny /usr/bin/** x,' ve 'deny /bin/** x,' satırları TAMAMEN
  # KALDIRILDI (bkz. dosya sonundaki NOT) — belirsizliğe güvenmek yerine
  # çakışmayı kökünden kaldırdık.
  /usr/bin/php{{PHP_VERSION}} mrix,

  # ─── B4: kabuk exec whitelist'i — yalnız TAM YOL, glob YOK ───
  # 'Process::fromShellCommandline()' (Symfony/Laravel) alt süreci HER ZAMAN
  # '/bin/sh -c "..."' ile açar. Ubuntu 22.04/24.04 merged-usr düzeninde
  # /bin, usr/bin'e sembolik linktir VE /bin/sh genelde /usr/bin/dash'e
  # bağlıdır; AppArmor path çözümü sembolik linkin nihai HEDEFİNE göre
  # çalıştığından (kernel d_path çözümü) HER İKİ yol da (sembolik link yolu
  # + gerçek hedef) whitelist'e eklendi — hangisinin eşleştiği HOST'ta
  # doğrulanmalı ('readlink -f /bin/sh'). Sistemde /bin/sh farklı bir
  # kabuğa (ör. bash) yeniden bağlanmışsa (dpkg-reconfigure dash → hayır)
  # bu whitelist YETERSİZ kalır — bash'i BİLİNÇLİ OLARAK whitelist'e
  # EKLEMİYORUZ (tam interaktif kabuk exec yüzeyini genişletmemek için);
  # böyle bir host'ta scheduler yine B4'teki gibi sessizce kırılabilir,
  # bu HÂLÂ bir HOST doğrulama maddesidir (BUG 1'in çözdüğü yalnızca
  # deny/allow çakışması, sembolik link hedefi belirsizliği DEĞİL).
  /bin/sh rix,
  /usr/bin/dash rix,

  # ─── /usr/bin/flock — cron deploy-kilidi sarmalayıcısı (lib/cron.sh) ───
  # HOST BULGUSU (koordinatör, Ubuntu 24.04, gerçek sertleştirilmiş domain):
  # 'srvctl cron add <domain> ...' domain kapsamlı cron'ları, deploy sürerken
  # çakışmayı önlemek için 'flock -n -E 75 <kilit> -c "<komut>"' ile sarmalar
  # (bkz. lib/cron.sh dosya başı "DEPLOY KİLİDİ" yorumu) — bu unit de bu
  # profille (srvctl-cron.service.tpl: AppArmorProfile=srvctl-{{SAFE_NAME}}-cli)
  # çalışır. 'flock' whitelist'te YOKTU ('mrix'/'rix' izinli hiçbir satırda
  # geçmiyordu) — sonuç GERÇEK VM'de ölçüldü: 'ExecStart' '/bin/sh: 1: flock:
  # Permission denied' ile status=126 veriyordu, TÜM domain cron'ları (bu
  # sarmalamayı alan HER iş) sessizce çalışamıyordu ('srvctl cron list' bunu
  # dürüstçe 'Son çıkış kodu: 126' ile raporluyordu — dedektör DOĞRU
  # çalışıyordu, kök neden AppArmor'daydı).
  #
  # KARAR (üç seçenek değerlendirildi — coordinator notu): (a) flock'u
  # whitelist'e ekle [SEÇİLDİ], (b) flock'suz kilit kontrolü [flock(1)
  # olmadan bir '/bin/sh' alt-sürecinin tuttuğu POSIX dosya kilidini
  # doğrudan sorgulamanın pratik bir yolu YOK — terk edildi], (c) deploy
  # tarafında bir 'çalışıyor' işaretçi dosyası + 'ExecCondition=' [lib/
  # deploy.sh'a dokunmayı GEREKTİRİR — bu profilin/kütüphanenin sahibi
  # DEĞİL, ayrı bir görev/onay gerektirir]. (a) TEK BAŞINA bu MODÜLÜN
  # (lib/cron.sh + bu profil) sınırları İÇİNDE çözülebilen, kök nedeni
  # (whitelist eksikliği) DOĞRUDAN gideren seçenektir.
  #
  # RİSK DEĞERLENDİRMESİ (bu profil worker/scheduler İLE DE PAYLAŞILDIĞINDAN
  # — dosya başı "NEDEN AYRI PROFİL?" notuna bkz. — flock'a erişim onlara da
  # AÇILIR): flock(1) TEK işlevi POSIX 'flock()' syscall'ını sarmalamak ve
  # (isteğe bağlı) bir alt komut exec etmektir — YENİ bir dosya/ağ/kimlik
  # yeteneği EKLEMEZ (kilit tuttuğu dosyaya zaten '-c' argümanındaki komutun
  # KENDİSİ erişebilir durumda olmalı; flock'un kendisi bu erişimi
  # GENİŞLETMEZ). Ele geçirilmiş bir worker/scheduler için marjinal risk:
  # saldırgan flock'u ARAÇ olarak kullanabilir (ör. kendi kalıcılık
  # mekanizmasını serileştirmek için) ama bu, zaten whitelist'te olan
  # php{{PHP_VERSION}}/sh/dash ile ULAŞABİLECEĞİ yetenekleri AŞMAZ — net
  # risk artışı DÜŞÜK, root neden (100% ölü cron özelliği HER sertleştirilmiş
  # domainde) İLE KIYASLANAMAYACAK kadar küçüktür.
  #
  # 'rix' (php{{PHP_VERSION}}/sh/dash İLE AYNI izin — mmap 'm' GEREKMEZ,
  # flock paylaşımlı kütüphane olarak yüklenmiyor, yalnız exec ediliyor):
  # merged-usr'de '/bin/flock' aynı dosyaya işaret eder (kernel d_path
  # çözümü '/usr/bin/flock'u verir — coordinator'ın GERÇEK VM ölçümüyle
  # BİREBİR eşleşir: "flock ise /usr/bin/flock'ta"); '/bin/sh'+'/usr/bin/
  # dash' çiftindeki gibi İKİ AYRI ada ihtiyaç YOK (flock'un 'sh' gibi bir
  # alternatif adı/sembolik link zinciri yok) — TEK satır yeterli.
  #
  # ÖNEMLİ — MEVCUT SERTLEŞTİRİLMİŞ DOMAINLER OTOMATİK GÜNCELLENMEZ: bu
  # profil yalnızca ŞABLONDUR; disk üzerindeki '/etc/apparmor.d/srvctl-
  # <sname>-cli' zaten render EDİLMİŞ domainlerde bu satırı İÇERMEZ.
  # 'srvctl domain repair <domain>' (profili yeniden render edip
  # 'apparmor_parser -r' ile yeniden yükler) ÇALIŞTIRILMADAN bu düzeltme
  # o domainlerde ETKİN OLMAZ — bu bir HOST doğrulama/rollout maddesidir.
  /usr/bin/flock rix,

  # ─── Deploy kilidi DOSYASI — AYNI HOST BULGUSUNUN İKİNCİ KATMANI ───
  # HOST BULGUSU 2 (koordinatör, aynı Ubuntu 24.04 domain, 'flock' exec
  # düzeltmesinden SONRA ölçüldü): exec artık geçiyor ama flock kendisi
  # 'cannot open lock file /run/srvctl/deploy-{{SAFE_NAME}}.lock: Permission
  # denied' ile başarısız oluyordu. DAC (dosya izinleri — root:root 644)
  # sorunsuzdu; koordinatör audit.log'da kanıtı buldu:
  #   apparmor="DENIED" operation="open"
  #   name="/run/srvctl/deploy-{{SAFE_NAME}}.lock" denied_mask="rc"
  # yani profilde '/run/srvctl' için HİÇBİR KURAL YOKTU (default-deny bu
  # sistem yoluna hiç dokunmuyordu — domain ağacı DIŞINDA, srvctl'in kendi
  # runtime dizini).
  #
  # SEÇİLEN İZİN — 'rwk,' (bu profildeki HER flock() gerektiren yol İLE
  # BİREBİR AYNI desen, bkz. aşağıdaki "Dosya kilidi ('k')" bloğu): 'k'
  # (flock() syscall'ı) 'rw'DEN AYRI bir izindir — yalnız 'r' vermek LOCK_EX
  # için YETMEZDİ (bu oturumda PHP tarafında "Exclusive locks are not
  # supported for this stream" olarak TAM BU sınıf hata zaten görülmüştü).
  # 'w' + 'r' GNU flock(1)'ün kendi belgelenmiş açma davranışından gelir:
  # bir dosya YOLU (fd numarası DEĞİL) argüman olarak verildiğinde flock(1)
  # dosyayı 'O_RDWR|O_CREAT' ile açar (kilit dosyası YOKSA kendisi
  # oluşturabilsin diye — bu domainin durumunda dosya zaten root tarafından
  # ÖNCEDEN var edilmiş olsa da açma çağrısı YİNE DE bu bayraklarla yapılır;
  # AppArmor mediation kararını dosyanın GERÇEKTEN var olup olmadığından
  # BAĞIMSIZ, açma isteğinin KENDİSİNE göre verir — ölçülen 'denied_mask=
  # "rc"' bunun R/O_CREAT tarafını yansıtıyor olabilir).
  #
  # DÜRÜSTLÜK NOTU (görev talebi — "ölç, tahmin etme"): bu macOS geliştirme
  # makinesinde GERÇEK bir AppArmor çekirdeği YOK, bu yüzden 'rwk,'nın TAM
  # OLARAK yeterli/gerekli en dar küme olduğu BURADAN doğrulanamadı — seçim
  # (1) bu profildeki HER flock()-gerektiren yolun ZATEN kullandığı, HOST'ta
  # daha önce doğrulanmış 'rwk,' desenine UYMASI ve (2) GNU flock(1)'ün
  # belgelenmiş 'O_RDWR|O_CREAT' açma davranışına DAYANIYOR — ampirik bir
  # HOST ölçümü DEĞİL. 'srvctl domain repair <domain>' sonrası GERÇEK
  # denemede 'rwk,' YETERSİZ ya da FAZLA geniş çıkarsa (ör. yalnız 'r'+'k'
  # yeterliyse), lütfen tam 'denied_mask' çıktısını paylaşın — bu satır
  # buna göre daraltılır.
  #
  # KAPSAM — TEK domain'in TEK dosyası (görev talebi: "DAR olması önemli"):
  # '{{SAFE_NAME}}' token'ı ile domain'in KENDİ kilit dosyasına SABİTLENİR;
  # '/run/srvctl/*' gibi bir glob KASITLI OLARAK YAZILMAZ — böyle bir kural
  # bir domainin BAŞKA domainlerin deploy kilit dosyalarını açabilmesi
  # (varlığını/durumunu sezebilmesi) anlamına gelirdi ve bu profilin TEK
  # var oluş nedeni olan domainler-arası izolasyon sınırını delerdi.
  /run/srvctl/deploy-{{SAFE_NAME}}.lock rwk,

  # ─── Domain ağacı — FPM profiliyle AYNI okuma/yazma yolları ───
  # (framework yazma yolu eklerken profile.tpl'deki eşdeğer bloğu da
  # güncelleyin — bkz. dosya başı NOT)
  {{WEB_ROOT}}/{{DOMAIN}}/ r,
  {{WEB_ROOT}}/{{DOMAIN}}/** r,

  # current symlink (release KÖKÜ — WorkingDirectory buradan çözülür).
  # NOT: yukarıdaki '**' zaten 'current'ı (ve hedef release'i) kapsar;
  # bu satır salt okunurluk/dokümantasyon amaçlıdır.
  {{WEB_ROOT}}/{{DOMAIN}}/current r,

  {{WEB_ROOT}}/{{DOMAIN}}/private/** r,

  # ─── Dosya kilidi ('k') — flock()/LOCK_EX (bkz. profile.tpl AYNI NOT,
  #     kanıt: gerçek Ubuntu 22.04 VM) ───
  # queue:work/schedule:run AYNI Illuminate\Filesystem API'sini kullanır
  # (Laravel Cache/dosya session sürücüleri, Blade derleme, Symfony cache
  # warmup); 'k' olmadan LOCK_EX reddedilir ("Exclusive locks are not
  # supported for this stream"). Aşağıdaki TÜM domain-içi yazma kuralları
  # bu yüzden 'rwk,'dir — gerekçe/güvenlik analizi profile.tpl'dekiyle
  # BİREBİR aynıdır (yeni bir yola erişim AÇMAZ, yalnız zaten 'rw' verilmiş
  # bir yolda kilit almaya izin verir).
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/cache/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/logs/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/session/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/uploads/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/writable/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/writable/** rwk,

  # Laravel (queue:work: storage/logs, cache; schedule:run: bootstrap/cache)
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/storage/** rwk,
  # DÜZELTME (lib/deploy.sh — bkz. profile.tpl'deki AYNI NOT, birebir aynı
  # gerekçe): bootstrap/cache ARTIK PAYLAŞILMIYOR (composer/artisan cache
  # komutları release'in MUTLAK yolunu gömüyordu — Symfony var/cache ile
  # AYNI sınıf bug, HOST'ta ölçüldü). Her release KENDİ bootstrap/cache'ini
  # kullanır — bu yüzden aşağıdaki satır GERÇEKTEN aktif (symlink YOK,
  # release-yerel gerçek dizin).
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/bootstrap/cache/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/storage/** rwk,
  # DEPRECATED/LEGACY-COMPAT (bkz. profile.tpl'deki AYNI NOT — birebir aynı
  # gerekçe): lib/deploy.sh ARTIK üretmiyor, ama henüz yeniden deploy
  # EDİLMEMİŞ eski siteler hâlâ bu dizine symlink'li olabilir; kaldırmak
  # deploy'dan BAĞIMSIZ, SESSİZ bir kesinti riski doğurur (lib/deploy.sh'ın
  # "ölü yol tespit et, OTOMATİK SİLME" kararıyla tutarlı). Operatör elle
  # temizleyip yeniden deploy edince kaldırılabilir.
  {{WEB_ROOT}}/{{DOMAIN}}/shared/bootstrap-cache/** rwk,

  # Symfony (messenger:consume: var/cache, var/log, var/sessions)
  # var/cache ARTIK PAYLAŞILMIYOR (HOST ölçümü — bkz. profile.tpl'deki AYNI
  # NOT: paylaşılan cache'te ölü release yolları birikip canlı siteyi
  # bozuyordu); her release kendi var/cache'ini kullanır — aşağıdaki
  # 'releases/**/var/**' bu yüzden GERÇEKTEN aktif. Yalnız 'var/log' ve
  # 'var/sessions' PAYLAŞILIYOR (tire'li 'var-log'/'var-sessions' adlarıyla
  # — bkz. profile.tpl'deki AYNI NOT, lib/deploy.sh 'shared_pairs'); AppArmor
  # symlink'i çözüp gerçek shared yolu denetlediğinden bu ikisi için AYRI
  # kurallar gerekir.
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/var/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var-log/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var-sessions/** rwk,
  # DEPRECATED/LEGACY-COMPAT (bkz. profile.tpl'deki AYNI NOT — birebir aynı
  # gerekçe: eski 'var:var' şemasından kalma, henüz yeniden deploy
  # EDİLMEMİŞ siteler için geçiş süresince korunuyor, OTOMATİK SİLİNMİYOR).
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var/** rwk,

  {{WEB_ROOT}}/{{DOMAIN}}/logs/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/tmp/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/sessions/** rwk,

  # ─── Sistem Dosyaları (salt okuma) ───
  /etc/php/** r,
  /usr/lib/php/** mr,

  # ─── Chroot kütüphaneleri ('m') — PARİTE/DEFANS-İÇİNDE-DEFANS ───
  # (profile.tpl'deki AYNI blokla PARALEL tutulur — dosya başı NOT: "yeni
  # bir yazma yolu eklerken İKİ dosyayı da değiştirmeyi unutmamalı".)
  #
  # BU PROFİL (worker/scheduler) chroot'SUZ host yollarında çalışır — systemd
  # 'User={{WEB_USER}}' ile DAHA BAŞTAN unprivileged UID olarak execve edilir,
  # chroot() syscall'ı YOK (bkz. templates/systemd/srvctl-worker.service.tpl
  # satır ~41 NOT'u ve bu dosyanın başındaki "NEDEN AYRI PROFİL?" bloğu). Bu
  # yüzden worker/scheduler süreci normal işleyişte NSS/glibc paylaşımlı
  # kütüphanelerini GERÇEK HOST yollarından yükler ('#include <abstractions/
  # base>' zaten bunu kapsıyor) — aşağıdaki kurallar bu sürecin GÜNLÜK
  # İŞLEYİŞİ için ZORUNLU DEĞİLDİR.
  #
  # YİNE DE EKLENDİ: ÖLÇÜLEN kanıt profile.tpl'de (bkz. o dosyadaki
  # 'operation="file_mmap" name=".../lib/x86_64-linux-gnu/libnss_systemd.so.2"
  # denied_mask="m"' bulgusu — kök neden lib/domain.sh:_apply_chroot_php_deps).
  # Yukarıdaki '{{WEB_ROOT}}/{{DOMAIN}}/** r,' bloğu bu profilde de aynı
  # chroot kütüphane kopyalarını OKUMAYA zaten izin veriyor (yalnız 'r', 'm'
  # yok) — iki profilin domain-ağacı bloklarını TUTARLI tutmak ve ileride bu
  # iki profilin birleştirilmesi/worker'ın bir chroot varyantı alması gibi
  # bir değişiklikte aynı boşluğun SESSİZCE yeniden keşfedilmesini önlemek
  # için AYNI 'mr' kuralları burada da tanımlanır. Zarar YOK: bu yollar
  # zaten '** r,' ile OKUNABİLİR durumda, yalnızca 'm' (mmap) EKLENİYOR —
  # YAZMA ('w') ya da YÜRÜTME ('x') YOK (gerekçe profile.tpl'dekiyle BİREBİR
  # aynı: kütüphaneler root:root salt-okunur kalmalı, bu ağaçta yürütülebilir
  # bir dosya OLMAMALI).
  {{WEB_ROOT}}/{{DOMAIN}}/lib/x86_64-linux-gnu/** mr,
  {{WEB_ROOT}}/{{DOMAIN}}/lib64/** mr,
  {{WEB_ROOT}}/{{DOMAIN}}/usr/lib/php/** mr,
  {{WEB_ROOT}}/{{DOMAIN}}/usr/lib/x86_64-linux-gnu/** mr,

  /etc/ssl/certs/** r,
  /usr/share/ca-certificates/** r,
  /usr/share/zoneinfo/** r,
  /etc/resolv.conf r,
  /etc/hosts r,
  /etc/nsswitch.conf r,
  /etc/localtime r,
  /etc/ld.so.cache r,

  /dev/null rw,
  /dev/urandom r,
  /dev/zero r,

  # ─── DİĞER HER ŞEYE ERİŞİM ENGELLE (default-deny zaten kapalı; bu
  #     satırlar defense-in-depth/dokümantasyon amaçlıdır) ───
  #
  # ÖNEMLİ: 'disable_functions' (pool.conf.tpl) yalnız FPM SAPI'sini
  # kapsar — CLI SAPI'de exec/shell_exec/proc_open vb. şu an php.ini
  # düzeyinde KAPALI OLMAYABİLİR (bkz. rapor: "CLI SAPI disable_functions
  # boşluğu"). Bu yüzden AppArmor'ın default-deny (whitelist) modeli burada
  # GERÇEK bir MAC-katmanı yedek savunmadır: profilde 'x' izni AÇIKÇA
  # verilmemiş HİÇBİR binary zaten exec edilemez — bir kuyruk job'ı içinden
  # shell_exec("curl ...") çağrılsa bile (curl'e x izni YOK) kernel düzeyinde
  # reddedilir.
  #
  # DÜZELTME (BUG 1 kanıtıyla ÇÖZÜLDÜ — eskiden burada 'deny /usr/bin/** x,'
  # ve 'deny /bin/** x,' vardı): AppArmor'da 'deny' HER ZAMAN 'allow'u ezer
  # (specificity FARK ETMEZ — BUG 1'in gerçek VM kanıtı bunu doğruladı: bir
  # glob deny, aynı dosyaya tanımlı TAM YOL bir allow'u da geçersiz kılıyordu).
  # Bu iki satır yukarıdaki ZORUNLU 'rix' izinleriyle (php CLI kendi
  # kendini yeniden çalıştırma + Process/schedule alt kabuğu için /bin/sh,
  # /usr/bin/dash) ÇAKIŞIYORDU — kaldırılmaları saldırı yüzeyini
  # GENİŞLETMEZ: default-deny zaten /usr/bin/** ve /bin/** altındaki
  # WHITELIST'TE OLMAYAN (curl, wget, nc, python3, bash, ...) hiçbir
  # binary'ye 'x' vermiyor; bu iki satır yalnız audit log'unu susturan
  # dokümantasyondu, gerçek bir ek kısıtlama SAĞLAMIYORDU. '/usr/sbin/**' ve
  # '/sbin/**' için böyle bir çakışma YOK (bu profilde o yollara hiçbir
  # allow verilmedi) — o iki satır KORUNUYOR, ama bu turda 'audit deny'e
  # ÇEVRİLDİ (bkz. profile.tpl'deki HOST ölçümü notu — AYNI gerekçe:
  # kural yokluğu zaten loglanıyor, düz 'deny' yalnızca tespit sinyalini
  # SİLİYORDU, koruma EKLEMİYORDU).
  audit deny /usr/sbin/** x,
  audit deny /sbin/** x,

  # ─── BİLİNÇLİ SUSTURMA: '/usr/bin/stty' (HOST ölçümü, srvctl-jammy VM) ───
  # Yukarıdaki mantığın TEK istisnası. worker/scheduler ilk kez ayağa
  # kaldırılıp ('srvctl domain worker ... start', 'srvctl domain
  # scheduler ... start') gerçek Laravel queue:work + schedule:run ile
  # ölçüldüğünde audit.log'da SÜREKLİ bir akış görüldü: 'operation="exec"
  # name="/usr/bin/stty" comm="php{{PHP_VERSION}}"' (bazı kayıtlarda
  # comm="sh" — yani '/bin/sh' allow'u DOĞRU çalışıyor, sh kendi İÇİNDE
  # stty'yi çağırmaya çalışıyor). Kaynak: Symfony Console'un terminal
  # genişliğini yoklaması ('stty -a' — scheduler dakikada bir tetiklendiği
  # için KALICI bir kaynak). Ölçülen hız: 2 dakikada 8 kayıt = dakikada 4,
  # TEK domain için. Hedef ölçek 100 domain'de: 4/dk × 100 = 400 kayıt/dk
  # ≈ 576.000 kayıt/gün — GERÇEK sinyal SIFIR (Symfony sessizce 80x50
  # varsayılanına düşüyor; queue:work/schedule:run işlevsel olarak
  # ETKİLENMİYOR). Bu tam olarak düz 'deny'nin DOĞRU kullanım vakasıdır:
  # bilinen-zararsız + yüksek frekanslı + işlevsel olarak önemsiz bir
  # tekrarı susturup audit kanalını (ve 100-domain ölçekte disk/rotate
  # baskısını) temiz tutmak. 'stty'ye meşru bir ihtiyaç YOK (yalnızca
  # terminal genişliği sorgusu; bilgi sızdırmıyor, ayrıcalık kazandırmıyor)
  # — allow VERMEK yerine SUSTURMAK tercih edildi: 'x' izni verilseydi
  # exec whitelist'i (tests/test_apparmor_deny_shadow.sh dedektör 2)
  # gereksiz yere genişlerdi. Bu istisna tests/test_apparmor_deny_shadow.sh
  # içinde AÇIKÇA (gerekçeli) beyaz listeye alınmıştır — biri farklı bir
  # binary için sessizce ikinci bir düz 'deny' eklerse test KIRILIR.
  deny /usr/bin/stty x,

  # ─── Kaybolan guardrail'i KAPAT: adlandırılmış /usr/bin + /bin deny
  #     listesi (güvenlik denetimi bulgusu) ───
  # Yukarıdaki paragrafta anlatıldığı gibi 'deny /usr/bin/** x,' ve
  # 'deny /bin/** x,' TAMAMEN kaldırıldı (BUG 1 — php{{PHP_VERSION}}
  # kendi-kendini-exec ve /bin/sh, /usr/bin/dash kabuk alt-süreçleriyle
  # ÇAKIŞIYORDU). Bu, teknik olarak DOĞRU bir düzeltmeydi ama bir yan etki
  # yarattı: bu iki dizin artık HİÇBİR deny kuralıyla korunmuyor —
  # ileride biri bu profile geniş bir 'x' allow'u (ör. bir abstraction
  # include) eklerse hiçbir şey onu durdurmaz. Aşağıdaki liste bu boşluğu,
  # mevcut 'rix'/'mrix' allow'larıyla ÇAKIŞMAYAN adlandırılmış binary'lerle
  # kapatır: worker/scheduler ele geçirilirse (Laravel queue:work /
  # schedule:run kod yürütme zinciri üzerinden) en çok tercih edilecek
  # "living-off-the-land" araçları — interaktif/ters kabuklar (bash),
  # veri sızdırma/ters bağlantı araçları (curl, wget, nc/nc.*/ncat, socat,
  # rsync, ssh, scp), betik yorumlayıcılar (python3*, perl, ruby, node —
  # alternatif payload çalıştırma yolu), tek-binary çok-araçlı kaçış
  # kitleri (busybox), encode/decode yardımcıları (base64, xxd — payload
  # gizleme), derleyici/linker (gcc*, ld — yerinde exploit derleme),
  # process-spawn/persist primitifleri (find -exec, xargs, env, setsid,
  # nohup — kısıtlı kabuktan kaçış ve arka planda kalıcılık) ve
  # zamanlanmış görev mekanizmaları (at, crontab — srvctl'in KENDİ
  # zamanlayıcısı systemd timer'dır, bunlara ihtiyaç YOKTUR).
  #
  # ÇAKIŞMA YOK: listede 'sh', 'dash' ya da 'php' ile başlayan hiçbir ad
  # YOK — yukarıdaki üç 'rix'/'mrix' allow'uyla (php{{PHP_VERSION}},
  # /bin/sh, /usr/bin/dash) kesişmez; BUG 1'deki 'deny her zaman allow'u
  # ezer' tuzağına TEKRAR düşülmez (statik kilit:
  # tests/test_apparmor_deny_shadow.sh). '/bin' Ubuntu 22.04/24.04'te
  # merged-usr ile '/usr/bin'e sembolik linktir (kernel d_path çözümü
  # gerçek hedefi verir); yine de aynı listeyi HER İKİ yol için de
  # tanımlıyoruz — defense-in-depth ve olası merge-dışı/legacy düzenlerle
  # uyum için (tek bir dizinde eksik bırakmak sessiz bir kapsam boşluğu
  # doğurur).
  #
  # 'audit deny' KULLANILDI, düz 'deny' DEĞİL — TEK istisna yukarıdaki
  # ölçülmüş '/usr/bin/stty' vakasıdır. Diğer TÜM isimler için: bu isimler
  # zaten default-deny ile kapalı; amaç SESSİZCE engellemek değil, bir
  # sömürü denemesini TESPİT ETMEKTİR — HOST ölçümü (bkz. profile.tpl'deki
  # NOT) "audit'lemek gürültü yaratır" varsayımını BU PROFİLİN blanket
  # satırları (/usr/sbin/**, /sbin/** — yukarıda 'audit deny'e ÇEVRİLDİ)
  # için ÇÜRÜTTÜ (64 dk'da yalnızca 3 exec denial, hepsi kasıtlı prob);
  # 'stty' TEK gerçek yüksek-frekanslı/zararsız istisnadır ve YUKARIDA
  # AYRI, gerekçeli bir düz 'deny' satırıyla ele alındı — bu listenin
  # kendisinde düz 'deny' YOKTUR.
  audit deny /usr/bin/{bash,curl,wget,nc,nc.*,ncat,socat,python3*,perl,ruby,node,ssh,scp,rsync,busybox,base64,xxd,gcc*,ld,find,xargs,env,setsid,nohup,at,crontab} x,
  audit deny /bin/{bash,curl,wget,nc,nc.*,ncat,socat,python3*,perl,ruby,node,ssh,scp,rsync,busybox,base64,xxd,gcc*,ld,find,xargs,env,setsid,nohup,at,crontab} x,

  deny /home/** rwx,
  deny /root/** rwx,
  deny /etc/shadow r,
  deny /etc/gshadow r,
  deny /etc/passwd w,
  deny /etc/sudoers r,
  deny /etc/sudoers.d/** r,
  deny /etc/ssh/** r,
  deny /usr/local/srvctl/** rwx,

  # ─── Ağ Erişimi (DB/Redis unix socket + dış API çağrıları) ───
  network inet stream,
  network inet dgram,
  network inet6 stream,
  network unix stream,
  network unix dgram,
}
