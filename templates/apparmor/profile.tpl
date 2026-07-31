# TOKENS: DOMAIN SAFE_NAME WEB_ROOT WEB_USER PHP_VERSION
# Besleyen: lib/domain.sh — _domain_add (satır ~1280) ve _domain_repair
# (satır ~198), render_template'e her ikisi de yukarıdaki 5 token'ı verir.
abi <abi/3.0>,

#include <tunables/global>

profile srvctl-{{SAFE_NAME}} flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # ═══════════════════════════════════════════════
  #  AppArmor Profile: {{DOMAIN}}
  #  User: {{WEB_USER}}
  #  Bu profil, systemd'nin AppArmorProfile= yönergesiyle YALNIZCA
  #  srvctl-fpm-{{SAFE_NAME}}.service sürecine (FPM master + kendi
  #  forkladığı chroot'lu/setuid düşürülmüş worker'lar — php-fpm'in İÇ
  #  worker havuzu, ayrı bir systemd unit'i DEĞİL) uygulanır.
  #
  #  DÜZELTME (güvenlik denetimi bulgusu): bu blokta ÖNCEDEN "Aynı profil
  #  worker/scheduler unit'lerine de (srvctl-worker/srvctl-scheduler)
  #  atanır" YAZIYORDU — bu YANLIŞTI ve denetçiyi yanıltıyordu. Gerçekte
  #  srvctl-worker-{{SAFE_NAME}}@*.service ve srvctl-scheduler-{{SAFE_NAME}}
  #  .service/.timer (Laravel queue:work / schedule:run gibi systemd
  #  job'ları) AYRI bir profil kullanır: srvctl-{{SAFE_NAME}}-cli (bkz.
  #  templates/apparmor/profile-cli.tpl ve templates/systemd/
  #  srvctl-worker.service.tpl / srvctl-scheduler.service.tpl'deki
  #  'AppArmorProfile=srvctl-<safe>-cli' yönergesi). BU profil (tiresiz
  #  'srvctl-{{SAFE_NAME}}') YALNIZ FPM master unit'inin
  #  'AppArmorProfile=srvctl-<safe>' yönergesiyle eşleşir.
  #  Bu ayrım kritiktir: aşağıdaki 'capability chown/dac_override/setuid/
  #  setgid/sys_chroot/kill' SADECE FPM master'ın chroot+privilege-drop
  #  için ZORUNLU olduğu BU profildedir — worker/scheduler'ın -cli
  #  profilinde bu capability'lerin HİÇBİRİ YOKTUR (en az yetki ilkesi,
  #  bkz. profile-cli.tpl başlık notu "NEDEN AYRI PROFİL?"). Eski (yanlış)
  #  yorum "worker zaten aynı capability'lere sahip, ayrıca kısıtlamaya
  #  gerek yok" gibi hatalı bir güvenlik kararına yol açabilirdi.
  # ═══════════════════════════════════════════════

  # ─── Capability: chroot+privilege-drop için ZORUNLU ───
  # Bunlar olmadan php-fpm master worker'ı chroot'a sokup web_user'a
  # düşüremez (setuid/setgid/chroot syscall'ları AppArmor'da capability
  # izni olmadan REDDEDİLİR — process root olsa bile). Master root olarak
  # ExecStart edilir (systemd unit'te User= YOK, bilinçli); bu yüzden
  # capability'ler burada, DAC/UID katmanında değil MAC katmanında kısıtlanır.
  capability chown,
  capability dac_override,
  capability setuid,
  capability setgid,
  capability sys_chroot,
  capability kill,

  # ─── ÇÖZÜLMÜŞ BULGU: periyodik 'capability net_admin' denial'ı SUSTURULDU
  #     (HOST ölçümü, srvctl-jammy VM, AppArmor 3.0.4 — kök neden DOĞRULANDI) ───
  # ÖNCEKİ sürümde bu blok "AÇIK ARAŞTIRMA NOTU" idi (kök neden HOST'ta
  # doğrulanmadan susturulmamıştı). HOST'ta eşlenik SYSCALL kaydı (AYNI
  # audit event id) incelenerek kök neden KESİN olarak teşhis edildi:
  #
  #   type=AVC     apparmor="DENIED" operation="capable" profile="srvctl-<sname>"
  #                pid=<master> comm="php-fpm{{PHP_VERSION}}" capability=12 capname="net_admin"
  #   type=SYSCALL syscall=208 SYSCALL=setsockopt success=no exit=-1
  #                a0=b a1=1 a2=20 ... exe="/usr/sbin/php-fpm{{PHP_VERSION}}" ppid=1 uid=0
  #
  # Çözümleme: a1=1 = SOL_SOCKET, a2=0x20 = 32 = SO_SNDBUFFORCE — bu soket
  # seçeneği çekirdekte AÇIKÇA CAP_NET_ADMIN ister (SO_SNDBUF'ın rlimit'i
  # AŞABİLEN "force" varyantı). ÖNCEKİ hipotez (glibc getaddrinfo()/
  # __check_pf() → chroot'ta /proc yokluğu → netlink) ÇÜRÜTÜLDÜ: denial'ı
  # üreten süreç FPM MASTER'ın KENDİSİ ('master=..., chroot=/' — chroot'lu
  # DEĞİL) ve syscall socket/bind/connect değil setsockopt'tur.
  #
  # GERÇEK KAYNAK: unit 'Type=notify' (NotifyAccess=main); php-fpm master
  # systemd'ye sd_notify() ile durum bildirir (php-fpm'in 'systemd_interval'
  # global direktifi, varsayılan 10 sn — ilk gözlemlenen ~10 sn'lik ritmin
  # kaynağı budur). sd_notify'ın soket tamponu büyütme yardımcısı ÖNCE
  # SO_SNDBUFFORCE dener, izin reddedilince SESSİZCE SO_SNDBUF'a düşer.
  #
  # ZARARSIZ OLDUĞUNUN KANITI: unit 'active', 'NRestarts: 0' — Type=notify
  # başlatma BAŞARILI (READY=1 systemd'ye ulaşmasaydı unit 'activating'de
  # takılı kalırdı, TimeoutStartSec sonunda 'failed' olurdu). Yani reddedilen
  # çağrının fallback'i ÇALIŞIYOR, işlev kaybı YOK. Ölçülen hacim: 64
  # dakikada 848 kayıt — TÜM AppArmor DENIED kayıtlarının ~%98'i; bu akış
  # aşağıdaki adlandırılmış 'audit deny' listelerinin tespit sinyalini
  # FİİLEN BOĞUYORDU.
  #
  # CAP_NET_ADMIN NEDEN VERİLMİYOR (susturuluyor ama İZİN VERİLMİYOR):
  # bu capability netfilter/iptables kurallarını değiştirme, ağ arayüzü
  # yapılandırma, promiscuous mod açma gibi yetkiler taşır — bir web
  # sunucusu sürecinde GERÇEK bir yetki yükseltme yüzeyidir. Tek ihtiyaç
  # zararsız bir soket-tamponu optimizasyonudur ve KENDİ FALLBACK'İ zaten
  # var (SO_SNDBUF); capability vermek riski ödülsüz büyütür. BİRİ İLERİDE
  # "denial var, capability ekleyelim" diye düzeltmeye kalkarsa: HAYIR —
  # doğru hareket bu satırı SUSTURMAK, capability EKLEMEK DEĞİL.
  #
  # 'deny' (audit'siz) KULLANILDI, 'audit deny' DEĞİL — bu, profile-cli.tpl
  # 'deki '/usr/bin/stty' ile TAM AYNI sınıf: bilinen kök neden + yüksek
  # frekans (848/861, ölçülen ~%98) + sıfır işlevsel etki (fallback var) +
  # aşağıdaki tespit katmanını (adlandırılmış 'audit deny' listeleri)
  # boğan gürültü. Düz 'deny'nin DOĞRU kullanım vakası (bkz. dosya
  # sonundaki 'deny' vs 'audit deny' NOTU). Statik kilit: tests/
  # test_apparmor_deny_shadow.sh'taki CAPABILITY-deny beyaz listesi
  # (dosyaya özgü, tek üye: 'profile.tpl:net_admin') — biri farklı bir
  # capability için sessizce ikinci bir düz deny eklerse test KIRILIR.
  deny capability net_admin,

  # ─── Kendi binary'si — reload (SIGUSR2) için 'x' (inherit-execute) ZORUNLU ───
  # DÜZELTME (kanıt: gerçek Ubuntu 22.04 VM). Önceki analiz "AppArmorProfile=
  # onexec ile zorlanır, exec-transition kuralı GEREKMEZ" diye YANLIŞ
  # varsayıyordu — bu yalnız İLK execve (systemd'nin ExecStart'ı) için
  # geçerli. PHP-FPM master SIGUSR2 (graceful reload) aldığında KENDİSİNİ
  # execvp(saved_argv[0], saved_argv) ile yeniden exec eder (fpm_pctl_exec,
  # sapi/fpm/fpm/fpm_pctl.c) — bu İKİNCİ execve, AppArmor'da AYRI bir syscall
  # olarak değerlendirilir ve kendi 'x' iznine ihtiyaç duyar. Yalnız 'mr'
  # (mmap+read) verilmişken bu execvp REDDEDİLİYOR, php-fpm exit(FPM_EXIT_
  # SOFTWARE)=70 ile çöküyor, systemd restart ediyor: 'systemctl reload'
  # TÜM domain'i 2-3 sn'liğine düşürüyordu. Doğrulama: aa-complain modunda
  # PID DEĞİŞMİYOR (reload başarılı), aa-enforce modunda PID DEĞİŞİYOR
  # (master ölüyor) — kök neden kesin olarak AppArmor'dı.
  #
  # 'ix' (inherit-execute) kullanılıyor, 'ux'/'px'/'Ux' DEĞİL: 'ix' aynı
  # AppArmor profilinde KALIR (profil geçişi/kaçışı YOK, capability seti
  # değişmez) — bu execve systemd'nin zaten attach ettiği 'srvctl-{{SAFE_NAME}}'
  # profilinin DIŞINA çıkmaz. 'ux' process'i TAMAMEN MAC dışına çıkarır
  # (ayrıcalık yükseltme kapısı olurdu), 'px' farklı bir profile geçiş
  # yapar (bu zaten en dar/doğru profil — kendine geçiş anlamsız ek
  # karmaşıklık katardı). Bu yüzden yalnız 'ix' güvenli seçimdir.
  /usr/sbin/php-fpm{{PHP_VERSION}} mrix,

  # ─── SADECE BU DOMAIN'E ERİŞİM ───

  # Domain kök dizini (okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/ r,
  {{WEB_ROOT}}/{{DOMAIN}}/** r,

  # public_html (okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/public_html/** r,

  # private dizin (CI4 uygulama kodu — okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/private/** r,

  # ─── Dosya kilidi ('k') — flock()/LOCK_EX (kanıt: gerçek Ubuntu 22.04 VM) ───
  # Aşağıdaki TÜM domain-içi yazma kuralları 'rw,' DEĞİL 'rwk,' kullanır.
  # DÜZELTME (aynı Laravel HTTP 500 zincirinin İKİNCİ halkası — bkz.
  # shared/bootstrap-cache düzeltmesiyle AYNI VM oturumu): 'rw' TEK BAŞINA
  # dosya İÇERİĞİ okuma/yazmayı açar ama AppArmor'da dosya KİLİTLEME
  # (flock(2)/fcntl(F_SETLK)) AYRI bir izin harfidir ('k'). 'rw' verilmiş
  # bir dosyada bile LOCK_EX reddedilir; PHP'de bu genelde "Exclusive locks
  # are not supported for this stream" hatası olarak görünür
  # (Illuminate\Filesystem\Filesystem::put($path,$contents,$lock=true) →
  # file_put_contents(..., LOCK_EX)). Blade view derleme, dosya tabanlı
  # cache/session sürücüleri (Laravel), writable/cache yazımı (CI4), cache
  # warmup (Symfony) hep bu yolu kullanır — 'k' eksikse HTTP 500 ya da
  # (daha sinsi) kilitsiz eşzamanlı yazma yarışı (sessiz veri bozulması)
  # olur. Doğrulama: VM'de domain-içi kurallar 'rwk,' yapılınca aynı istek
  # HTTP 200 döndü, uygulama log'u boş kaldı, view cache dosyaları oluştu.
  #
  # GÜVENLİK: 'k' YALNIZCA zaten 'rw' verilmiş bir yolda kilit ALMAYA izin
  # verir; YENİ bir yola erişim AÇMAZ, domain sınırını GENİŞLETMEZ — kapsam
  # her satırın kendi yol deseniyle (glob) AYNEN sınırlı kalır.
  # /run/srvctl, /run/php, soket ve /dev/null kuralları BİLEREK 'k' ALMADI:
  # bunlar FPM MASTER'ın kendi kontrol dosyalarıdır (PHP uygulama kodunun
  # flock() çağırdığı domain içeriği DEĞİL); soketlerde zaten flock(2)
  # anlamsızdır.

  # writable dizinleri (okuma + yazma) — CI4
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/cache/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/logs/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/session/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/uploads/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/writable/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/writable/** rwk,

  # Laravel yazma yolları (storage/framework/views, bootstrap/cache vb.)
  # render_template değer'lerinde newline yasak olduğundan framework'e göre
  # koşullu blok ENJEKTE EDİLEMEZ — bu yüzden üç framework'ün yolları da
  # statik/koşulsuz olarak dahil edilir (kullanılmayan yol = boş/no-op,
  # ek saldırı yüzeyi doğurmaz). Bkz. rapor: "Render escaping" notu.
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/storage/** rwk,
  # NOT (kanıt: gerçek Ubuntu 22.04 VM, HTTP 500 + tempnam() hatası): 'srvctl
  # deploy' HER release'de bootstrap/cache'i shared/bootstrap-cache'e
  # symlink'ler (bkz. lib/deploy.sh:_deploy_link_shared, shared_pairs).
  # AppArmor symlink'i ÇÖZER ve GERÇEK (shared) yolu denetler — bu yüzden
  # aşağıdaki 'releases/**/bootstrap/cache/**' kuralı srvctl deploy ile
  # yönetilen release'lerde ASLA eşleşmez (ölü kural). Yine de KORUNUYOR:
  # operatör symlink'i kaldırıp bootstrap/cache'i GERÇEK bir dizin olarak
  # kullanırsa (srvctl deploy dışı/manuel bir dağıtım) bu satır devreye
  # girer; kullanılmıyorken boş/no-op olduğundan ek saldırı yüzeyi
  # doğurmaz. Asıl çalışan kural bir alt satırdaki 'shared/bootstrap-cache/**'tir.
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/bootstrap/cache/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/storage/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/bootstrap-cache/** rwk,

  # Symfony yazma yolları (var/cache, var/log, var/sessions vb.)
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/var/** rwk,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var/** rwk,

  # Log dizini (yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/logs/** rwk,

  # Temp dizini (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/tmp/** rwk,

  # Session dizini (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/sessions/** rwk,

  # ─── FPM master kontrol dosyaları (chroot DIŞI, gerçek host yolları) ───

  # Kendi fpm-config'i (ExecStart --fpm-config ile açılır)
  /etc/srvctl/fpm/{{SAFE_NAME}}.conf r,

  # PID dosyası (fpm-global.conf.tpl: pid = /run/srvctl/fpm-<sname>.pid)
  /run/srvctl/ rw,
  /run/srvctl/fpm-{{SAFE_NAME}}.pid rw,

  # Socket dizini — dosyanın kendisi aşağıda ayrı satırda; ama socket'i
  # oluşturmak/silmek (bind/unlink) için DİZİNE de 'w' gerekir.
  /run/php/ rw,

  # ─── HEDGE bloğu KALDIRILDI (rapor: dalga4/O4) ───
  # Önceki sürümde burada "AppArmor path çözümü chroot-GÖRELİ olabilir"
  # belirsizliğine karşı /public_html/**, /private/**, /tmp/**, /logs/**,
  # /sessions/** gibi HOST KÖKÜNE göre yorumlanan bir hedge bloğu vardı.
  # İki bağımsız değerlendirme (code-reviewer + security-auditor) path
  # çözümünün GERÇEKTEN host köküne göre yapıldığını (chroot() tek başına
  # yeni bir mount/path namespace açmadığından AppArmor'ın d_path çözümü
  # gerçek host köküne göre çalışır) yüksek güvenle doğruladı. Bu durumda
  # hedge bloğu net bir REGRESYONDU: '/tmp/** rw' ve '/logs/** rw' HOST'ta
  # GERÇEKTEN VAR OLAN yollardır (özellikle /tmp) — FPM master'a host
  # /tmp'sine TAM rw erişimi açıyordu (DAC'ı aşmasa da — /tmp zaten 1777 —
  # MAC yedek savunmasını kaldırıyordu ve O5 bulgusuyla /tmp/modsecurity
  # üzerinden birleşiyordu). '/public_html/**' gibi diğer yollar host
  # kökünde normalde mevcut olmadığından pratikte no-op'tu.
  #
  # KRİTİK HOST DOĞRULAMASI GEREKİYOR: yukarıdaki analiz YANLIŞSA (yani
  # AppArmor bu profilde path'leri chroot-GÖRELİ çözüyorsa) FPM chroot
  # içinde HİÇBİR ŞEYE YAZAMAZ (writable/cache/logs/session/uploads dahil)
  # — bu bir fail-CLOSED hatadır (güvenlik açığı DEĞİL ama tam kesinti).
  # Bu yüzden bu değişiklik CANLIYA ALINMADAN ÖNCE bir test domain'inde
  # complain modda gerçek bir HTTP isteğiyle (dosya yazan bir endpoint)
  # doğrulanmalı; başarısız olursa hedge'i GERİ GETİRMEK yerine gerçek kök
  # nedeni (chroot mount namespace davranışı) araştırın — bkz. rapor HOST
  # doğrulama bölümü.

  # ─── Sistem Dosyaları (salt okuma) ───

  # PHP konfigürasyonu ve eklentileri ('m' — dlopen edilen .so'lar için
  # mmap-exec şart; salt 'r' extension yüklemesini AppArmor'da sessizce
  # DENIED bırakabilir)
  /etc/php/** r,
  /usr/lib/php/** mr,

  # SSL sertifikaları (harici API çağrıları için)
  /etc/ssl/certs/** r,
  /usr/share/ca-certificates/** r,

  # Zaman dilimi
  /usr/share/zoneinfo/** r,

  # DNS çözümleme
  /etc/resolv.conf r,
  /etc/hosts r,
  /etc/nsswitch.conf r,
  /etc/localtime r,
  /etc/ld.so.cache r,

  # ─── Cihazlar ───
  /dev/null rw,
  /dev/urandom r,
  /dev/zero r,

  # ─── Socket ───
  /run/php/php{{PHP_VERSION}}-fpm-{{SAFE_NAME}}.sock rw,

  # ─── DİĞER HER ŞEYE ERİŞİM ENGELLE ───
  # NOT: AppArmor default-deny/whitelist modelidir — burada listelenmeyen
  # HİÇBİR yola zaten erişim YOKTUR. Aşağıdaki 'deny' satırları saf
  # dokümantasyon/defense-in-depth amaçlıdır; hiçbiri yukarıdaki 'allow'
  # kurallarıyla ÇAKIŞMAMALIDIR (deny her zaman allow'u ezer).
  #
  # DÜZELTME: eski, WEB_ROOT'u sabit '/var/www' varsayan 'deny /var/www/*/ r,'
  # kuralı KALDIRILDI — bu glob, WEB_ROOT=/var/www olduğu (varsayılan) her
  # kurulumda BU DOMAIN'İN KENDİ kökünü de eşliyordu; deny her zaman allow'u
  # ezdiğinden yukarıdaki '{{WEB_ROOT}}/{{DOMAIN}}/ r,' izni PROFİLİN
  # KENDİSİ TARAFINDAN iptal ediliyordu. Diğer domainlere erişim zaten
  # default-deny ile kapalı; ayrıca bir 'deny' kuralına gerek yok.

  # Home dizinleri
  deny /home/** rwx,

  # Root dizini
  deny /root/** rwx,

  # Hassas sistem dosyaları
  deny /etc/shadow r,
  deny /etc/gshadow r,
  deny /etc/passwd w,
  deny /etc/sudoers r,
  deny /etc/sudoers.d/** r,
  deny /etc/ssh/** r,

  # srvctl yönetim dosyaları
  deny /usr/local/srvctl/** rwx,

  # Paket yöneticisi
  # DÜZELTME (BUG 1 — kanıt: gerçek Ubuntu 22.04 VM): 'deny /usr/sbin/** x,'
  # satırı BURADAN KALDIRILDI. Bu glob, yukarıda ZORUNLU olarak eklenen
  # '/usr/sbin/php-fpm{{PHP_VERSION}} mrix' allow kuralıyla ÇAKIŞIYORDU —
  # AppArmor'da 'deny' HER ZAMAN 'allow'u ezer (specificity/tam-yol vs. glob
  # FARK ETMEZ); bu satır enforce modda php-fpm'in kendi SIGUSR2 reload
  # exec'ini REDDEDİYOR, master exit(70) ile ÇÖKÜYORDU — kanıtlanmış kök
  # neden. Bu satırı php-fpm'i dışlayacak şekilde 'daraltmak' yerine
  # TAMAMEN KALDIRMAYI tercih ettik: dosya başındaki NOT'ta (yukarı) zaten
  # belgelendiği gibi AppArmor varsayılan-red (whitelist) modelidir —
  # profilde 'x' izni AÇIKÇA verilmemiş HİÇBİR /usr/sbin/** binary'si zaten
  # exec edilemez. Bu satır yalnızca audit log'unu susturan dokümantasyon
  # amaçlıydı, gerçek bir güvenlik katmanı SAĞLAMIYORDU; kaldırılması
  # saldırı yüzeyini GENİŞLETMEZ (tek allow hâlâ yalnızca
  # php-fpm{{PHP_VERSION}} binary'sinin TAM YOLUNA, glob'suz tanımlı).
  # '/usr/bin/**', '/bin/**', '/sbin/**' için böyle bir çakışma YOK (bu
  # profilde o yollara hiçbir allow verilmedi) — üç satır KORUNUYOR, ama
  # bu turda 'audit deny'e ÇEVRİLDİ (bkz. aşağıdaki HOST ölçümü notu).
  audit deny /usr/bin/** x,
  audit deny /bin/** x,
  audit deny /sbin/** x,

  # ─── Kaybolan guardrail'i KAPAT + HOST ölçümüyle DÜZELTME: 'deny'
  #     YERİNE 'audit deny' (güvenlik denetimi bulgusu) ───
  # Yukarıdaki 'deny /usr/sbin/** x,' satırının TAMAMEN kaldırılması (BUG
  # 1 düzeltmesi, yukarıdaki NOT) teknik olarak DOĞRUYDU ama bir yan etki
  # yarattı: bu dizin artık HİÇBİR deny kuralıyla korunmuyordu — ileride
  # biri bu profile geniş bir 'x' allow'u (ör. yeni bir abstraction
  # include) eklerse hiçbir şey onu durdurmaz. Aşağıdaki liste bu boşluğu,
  # php-fpm ile ÇAKIŞMAYAN adlandırılmış binary'lerle kapatır — bu unit
  # privdrop ÖNCESİ root çalıştığından (üstteki NOT) /usr/sbin altında ele
  # geçirilmiş bir root süreç için en yüksek riski taşıyan araçlar seçildi:
  # kullanıcı/grup yönetimi (useradd/userdel/usermod/groupadd/groupdel/
  # groupmod/adduser/deluser — kalıcı erişim için yeni hesap/grup üyeliği
  # açar), parola/sudoers dosyalarını DOĞRUDAN düzenleyen araçlar
  # (visudo/vipw/vigr/chpasswd/newusers), ağ keşfi (tcpdump), güvenlik
  # duvarı manipülasyonu (iptables/ip6tables/ufw), posta rölesi üzerinden
  # dışarı sızdırma/spam (sendmail/exim4/postfix) ve coreutils 'chroot'
  # binary'si (php-fpm'in kendi chroot() SYSCALL'ıyla karıştırılmasın —
  # bu, ayrı bir kaçış/pivot aracı olarak dışlanıyor).
  #
  # ÇAKIŞMA YOK: listedeki hiçbir ad 'php-fpm' ile başlamıyor/eşleşmiyor —
  # bu yüzden yukarıdaki (satır ~55) tek 'x' allow'umuzla kesişmez; BUG
  # 1'deki 'deny her zaman allow'u ezer' tuzağına TEKRAR düşülmez (statik
  # kilit: tests/test_apparmor_deny_shadow.sh).
  #
  # 'deny' vs 'audit deny' — HOST ÖLÇÜMÜYLE DÜZELTİLEN KARAR (bu şablonun
  # ÖNCEKİ sürümü burada YANLIŞTI): srvctl-jammy VM'de (AppArmor 3.0.4)
  # gerçek bir ölçüm yapıldı — chroot'a bilinçli olarak yerleştirilmiş bir
  # '/bin/sh' + '/usr/sbin/sendmail' kopyası exec edilmeye çalışıldı.
  # Sonuç: AppArmor bunu default-deny (bu iki yol için PROFİLDE HİÇBİR
  # KURAL YOK) ile engelledi VE audit.log'a 'type=AVC apparmor="DENIED"
  # operation="exec"' olarak YAZDI. Yani KURAL YOKLUĞU zaten loglanıyor —
  # AppArmor'ın belgelenen davranışı şudur: yalnızca AÇIK bir 'deny'
  # kuralı (audit niteleyicisi OLMADAN) audit mesajını BASTIRIR; kural
  # yokluğu normal implicit-deny yoludur ve LOGLANIR. Önceki sürümdeki
  # gerekçe ("blanket satırları düz deny'de bırakmak audit gürültüsünü
  # azaltır") bu yüzden TERSİNE İŞLİYORDU: '/usr/bin/**' vb. için var olan
  # düz 'deny' kuralları, KURAL HİÇ OLMASAYDI zaten loglanacak exec
  # denemelerini SESSİZLEŞTİRİYORDU — koruma EKLEMİYOR (default-deny
  # zaten kapatıyor), yalnızca TESPİT SİNYALİNİ SİLİYORDU; tam da
  # korumak istediğimiz yerde.
  #
  # "Audit'lemek log şişirir" gerekçesi de aynı VM ölçümünde ÇÜRÜTÜLDÜ: 64
  # dakikalık gerçek işletimde (tam bir Laravel deploy'u + CI4 + trafik
  # dahil) toplam 861 AppArmor kaydından yalnızca 3'ü 'operation="exec"'
  # idi — ve o 3'ü de bu ölçüm için BİLİNÇLİ yerleştirilen probe'du. Yani
  # BU PROFİLDE normal işletimde exec denial hacmi PRATİKTE SIFIR; bu
  # satırları 'audit deny'e çevirmenin ölçülebilir bir log-hacmi maliyeti
  # YOK. (Karşı örnek profile-cli.tpl'de VAR — worker/scheduler'da
  # Symfony Console'un 'stty -a' yoklaması yüksek frekanslı, GERÇEK
  # gürültü üretiyor; bkz. o dosyadaki '/usr/bin/stty' istisnası. Ölçüm
  # olmadan "gürültü" varsayımı YAPILMAMALI — bazen doğru çıkar (stty),
  # bazen tersine çıkar (bu profildeki eski blanket satırlar).)
  #
  # SONUÇ: bu şablonda PATH-tabanlı ('x' izni içeren) düz (audit'siz)
  # 'deny' kuralı YOKTUR — görmek istediğimiz her şey ya 'audit deny' ya
  # da kuralın TAMAMEN YOKLUĞUdur (statik kilit: tests/
  # test_apparmor_deny_shadow.sh, path-tabanlı "plain exec-deny"
  # invariant'ı — bu profil için istisna listesi BOŞTUR). TEK istisna
  # PATH-tabanlı DEĞİL, CAPABILITY-tabanlıdır: yukarıdaki 'deny capability
  # net_admin,' — kök nedeni HOST'ta DOĞRULANMIŞ (SO_SNDBUFFORCE/
  # sd_notify, fallback var), bilinen-zararsız, yüksek frekanslı bir
  # denial (bkz. capability bloğundaki ÇÖZÜLMÜŞ BULGU). Bu da ayrı bir
  # CAPABILITY-deny beyaz listesiyle (tests/test_apparmor_deny_shadow.sh,
  # tek üye: 'profile.tpl:net_admin') statik olarak kilitlenmiştir.
  audit deny /usr/sbin/{useradd,userdel,usermod,groupadd,groupdel,groupmod,adduser,deluser,visudo,vipw,vigr,chpasswd,newusers,tcpdump,iptables,ip6tables,ufw,sendmail,exim4,postfix,chroot} x,

  # ─── Ağ Erişimi ───
  network inet stream,
  network inet dgram,
  network inet6 stream,
  network unix stream,
  network unix dgram,

  # ─── systemd Type=notify READY sinyali ───
  # HOST BULGUSU (Ubuntu 24.04, gerçek VM): unit 'Type=notify' kullanıyor;
  # php-fpm master hazır olduğunda systemd'ye "READY=1" mesajını
  # /run/systemd/notify DGRAM socket'ine YAZARAK bildirir. 'network unix
  # dgram' TEK BAŞINA YETMEZ — AppArmor socket'in DOSYA YOLUNA da yazma
  # izni ister. İzin yokken master sorunsuz başlıyor ama sinyal gönderemiyor,
  # systemd TimeoutStartSec (90 sn) boyunca bekleyip unit'i "Result: timeout"
  # ile öldürüyordu. Teşhis: profil complain moduna alındığında unit ANINDA
  # 'active' oldu (pid alındı) — yani tek engel buydu.
  # NOT: /run/systemd/notify yalnız YAZILIR (okunmaz), 'w' yeterlidir.
  /run/systemd/notify w,
  # AppArmor 3.0+ ayrıntılı unix kuralı: adresi olmayan (soyut olmayan)
  # dgram peer'a gönderim. 22.04 (3.0) ve 24.04 (4.0) ikisinde de geçerli.
  unix (send) type=dgram addr=none,
}
