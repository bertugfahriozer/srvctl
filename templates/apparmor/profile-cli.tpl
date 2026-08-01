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

  # ═══════════════════════════════════════════════════════════════
  #  CRON KOMUT YÜZEYİ — egress'SİZ coreutils + DB dump istemcileri
  # ═══════════════════════════════════════════════════════════════
  # HOST BULGUSU (koordinatör, GERÇEK Ubuntu 24.04 üretim sunucusu, gerçek
  # 'srvctl-dev_designwestgate_art-cli' profili altında 'aa-exec -p <profil>'
  # ile TEK TEK ölçüldü):
  #     php8.4  rc=0    flock  rc=0
  #     date    rc=126  cat    rc=126  echo(/bin/echo)  rc=126
  #     tar     rc=126  git    rc=126  mysqldump        rc=126
  #     find    rc=126  curl   rc=126
  # 'srvctl cron add <domain> --command="echo '\''x'\'' && date +%Y"' unit'i
  # DOĞRU render ediliyor, ama çalışınca 'Result: exit-code /
  # ExecMainStatus: 126' veriyordu. Üstelik aynı 8 dakikada kernel'de
  # 'apparmor.*DENIED' satırı sayısı = 0 ölçüldü: deny SESSİZDİ, operatör
  # 126'nın sebebini HİÇBİR YERDE göremiyordu.
  #
  # KÖK SEBEP (tasarım boşluğu, bir "bug" değil): bu profil DEPLOY akışı
  # düşünülerek yazılmıştı — php + composer + git zinciri. Ama 'srvctl cron'
  # alt-komutu KULLANICININ YAZDIĞI SERBEST kabuk komutunu AYNI profil
  # altında çalıştırıyor (srvctl-cron.service.tpl:118
  # 'AppArmorProfile=srvctl-{{SAFE_NAME}}-cli' + satır 111
  # 'ExecStart=<FLOCK_PREFIX>/bin/sh -c <komut>'). FLOCK_PREFIX token'ı
  # burada BİLEREK süslü parantezsiz yazıldı: BU dosya render EDİLİYOR ve
  # başka bir şablonun token'ı buraya çift-süslü biçimde yazılırsa
  # BESLENMEYEN bir yer tutucu olarak çıktıya sızardı (bkz.
  # lib/domain.sh:_domain_assert_no_leftover_tokens). Meşru bir cron komutu
  # ('date', 'tar -czf ... ', 'mysqldump ... | gzip > ...') coreutils'e
  # ihtiyaç duyar; profilde bu ikililer için HİÇBİR kural yoktu →
  # default-deny → execve EACCES → kabuk 126 ile çıkar. Yani cron özelliği
  # HER sertleştirilmiş domainde fiilen 'php' + 'sh' dışında hiçbir şey
  # çalıştıramıyordu.
  #
  # ───────────────────────────────────────────────────────────────
  #  NEDEN 'ix' DOSYA HAPSİNİ ZAYIFLATMAZ (bu bloğun ANA gerekçesi)
  # ───────────────────────────────────────────────────────────────
  # 'ix' = INHERIT execute: exec edilen ikili MEVCUT profilin İÇİNDE kalır,
  # yeni bir profile GEÇMEZ. Yani '/usr/bin/date'e exec izni vermek, date'e
  # "kendi hakları" vermez — date bu profilin AYNI dosya kuralları altında
  # çalışır: '{{WEB_ROOT}}/{{DOMAIN}}/**' okur, izinli writable yollara
  # yazar, BAŞKA bir domain'in dizinine DOKUNAMAZ, '/etc/shadow' okuyamaz,
  # '/root'a giremez. Tehdit modelinin sınırı "HANGİ İKİLİ çalıştı" değil
  # "HANGİ DOSYAYA dokunuldu"dur; bu blok DOSYA kurallarının HİÇBİRİNİ
  # değiştirmez, dolayısıyla domainler-arası izolasyon sınırı AYNEN durur.
  #
  # Bunun somut sonucu: 'tar --use-compress-program=...', 'awk system()',
  # GNU 'sed s///e', 'mysql \!' gibi bu araçların KENDİ komut-çalıştırma
  # gadget'ları da profil İÇİNDE kalır — açtıkları alt süreç yine yalnızca
  # bu whitelist'teki ikilileri exec edebilir (default-deny geri kalan HER
  # ŞEYİ kapatır) ve yine yalnızca bu profilin dosya kurallarını görür. Bu
  # araçlar "kabuk erişimi" kazandırmaz; zaten '/bin/sh' bu profilde
  # BAŞTAN BERİ (Symfony/Laravel Process bileşeni için) izinlidir.
  #
  # 'ux'/'Ux'/'px'/'Px' KESİNLİKLE KULLANILMAZ (statik kilit:
  # tests/test_apparmor_cli_cron_exec.sh dedektör 3): bunlar süreci
  # profilin DIŞINA çıkarır ('ux'/'Ux' = unconfined, 'px'/'Px' = başka bir
  # profile geçiş) — hapsi ZAYIFLATAN tek şey tam olarak budur. Ek olarak
  # cron unit'i 'NoNewPrivileges=true' ile çalışır
  # (srvctl-cron.service.tpl:217); NNP altında çekirdek profil GEÇİŞLERİNİ
  # zaten reddeder — 'ix' NNP ile uyumlu TEK exec kipidir, yani doğru
  # seçim hem güvenlik hem işlevsellik açısından aynı yere çıkar.
  #
  # NEDEN 'rix', düz 'ix' DEĞİL: Ubuntu'da '/usr/bin/egrep', '/usr/bin/
  # fgrep', '/usr/bin/gunzip' ve '/usr/bin/zcat' derlenmiş ikili DEĞİL,
  # '#!/bin/sh' başlıklı sarmalayıcı BETİKtir (ÖLÇÜLDÜ: dördünün de ilk
  # satırı jammy ve noble'da '#!/bin/sh'). Bir betiği exec etmek için
  # çekirdek betiğe 'x', yorumlayıcıya 'x' İSTER, ARDINDAN yorumlayıcı
  # betiği OKUR — 'r' olmadan bu okuma reddedilir ve aynı 126 sınıfı hata
  # geri gelir. 'r' bir sistem ikilisi için ek saldırı yüzeyi AÇMAZ (bu
  # dosyalar root:root salt-okunur) ve dosyanın mevcut TÜM exec kuralları
  # ('/bin/sh rix', '/usr/bin/dash rix', '/usr/bin/flock rix') zaten AYNI
  # deseni kullanır. 'm' (mmap) BİLİNÇLİ OLARAK VERİLMEZ — bu ikililer
  # paylaşımlı kütüphane olarak yüklenmiyor, yalnızca exec ediliyor.
  #
  # ÇİFT-LTS / SEMBOLİK LİNK NOTLARI (bu proje bu tuzağa DAHA ÖNCE düştü —
  # bkz. yukarıdaki '/bin/sh' + '/usr/bin/dash' çifti). Aşağıdaki dört
  # madde VARSAYIM DEĞİL, gerçek jammy + noble kök dosya sistemlerinde
  # 'readlink -f' ile ÖLÇÜLDÜ (bkz. her maddedeki ölçüm satırı):
  #   1) usrmerge: HER İKİ LTS'te de '/bin' → 'usr/bin' sembolik linktir
  #      (ölçüldü: 'readlink /bin' = 'usr/bin', 22.04 ve 24.04). AppArmor
  #      kararını kernel d_path çözümüne (GERÇEK hedef yola) göre verdiği
  #      için ASIL eşleşen kural '/usr/bin/...' olanıdır — '/bin/date' tek
  #      başına yazılsaydı ETKİSİZ kalırdı. Yine de '/bin/...' varyantı da
  #      yazılır: dosyanın mevcut 'audit deny' listelerindeki (aşağıda)
  #      AYNI defense-in-depth kararı — merge dışı/legacy bir düzende tek
  #      dizini eksik bırakmak SESSİZ bir kapsam boşluğu doğurur.
  #   2) 'awk' bir alternatives sembolik linkidir ('/usr/bin/awk' →
  #      '/etc/alternatives/awk' → '/usr/bin/mawk' ya da '/usr/bin/gawk';
  #      ölçüldü: gawk kuruluyken her iki LTS'te de '/usr/bin/gawk',
  #      Ubuntu minimal'de varsayılan 'mawk'tır). d_path çözümü NİHAİ
  #      hedefi verdiğinden yalnız 'awk' yazmak İŞE YARAMAZ — üç ad da
  #      ('awk', 'gawk', 'mawk') listelenir.
  #   3) DB dump istemcisi: ÖLÇÜM (mariadb-client, varsayılan depolar) HER
  #      İKİ LTS'te de AYNI yönü verdi — '/usr/bin/mysqldump' →
  #      '/usr/bin/mariadb-dump' ve '/usr/bin/mysql' → '/usr/bin/mariadb'
  #      (yani GERÇEK dosya 22.04/MariaDB 10.6'da da 'mariadb-*'). Yani
  #      YALNIZ 'mysqldump' yazmak HER İKİ LTS'te de ETKİSİZ olurdu; asıl
  #      gerekli ad 'mariadb-dump'tır. Buna rağmen ESKİ adlar da yazılır:
  #      MySQL (Oracle) 'mysql-client' paketi kuruluysa '/usr/bin/mysqldump'
  #      GERÇEK dosyadır ve o durumda 'mariadb-dump' hiç bulunmaz — dört
  #      adın hepsi ancak birlikte her iki dağıtım kombinasyonunu kapsar.
  #      (Bu madde önceki turda "yön LTS'e göre TERSİNE döner" diye
  #      VARSAYILMIŞTI; ölçüm bunu ÇÜRÜTTÜ — dört adı birden yazma kararı
  #      değişmedi, ama GEREKÇESİ artık ölçüme dayanıyor.)
  #   4) "Peki neden bunca ismi tek bir '/usr/bin/** rix' ile geçmiyoruz?"
  #      Çünkü o kural, aşağıdaki 'audit deny' listesindeki (curl, wget,
  #      nc, socat, python3, perl, bash, base64, gcc, ...) TÜM egress/
  #      interpreter/gadget araçlarını da açardı ve BUG 1'deki
  #      'deny her zaman allow'u ezer' tuzağıyla birleşince öngörülemez bir
  #      profil doğururdu. Adlandırılmış whitelist, bu profilin TEK
  #      savunulabilir biçimidir.
  #
  # DENY POLİTİKASI DEĞİŞMEDİ: aşağıdaki 'audit deny /usr/bin/{bash,curl,
  # wget,nc,...,find,xargs,env,setsid,nohup,at,crontab} x,' listesine
  # DOKUNULMADI. Bu blokta o listeyle KESİŞEN TEK BİR AD YOKTUR (statik
  # kilit: tests/test_apparmor_deny_shadow.sh dedektör 1 + tests/
  # test_apparmor_cli_cron_exec.sh dedektör 2) — BUG 1'in
  # 'deny her zaman allow'u ezer' tuzağına TEKRAR düşülmez.
  #
  # ÖNEMLİ — MEVCUT DOMAINLER OTOMATİK GÜNCELLENMEZ: bu dosya yalnızca
  # ŞABLONDUR. Disk üzerindeki '/etc/apparmor.d/srvctl-<sname>-cli' zaten
  # render EDİLMİŞ domainlerde bu satırları İÇERMEZ; 'srvctl domain repair
  # <domain>' (profili yeniden render edip 'apparmor_parser -r' ile
  # yeniden yükler) çalıştırılmadan düzeltme ETKİN OLMAZ — HOST rollout
  # maddesi (yukarıdaki flock notuyla AYNI).

  # (a) dosya/dizin işlemleri, zaman, kabuk-yardımcıları
  /usr/bin/{date,cat,mkdir,rm,cp,mv,ls,touch,sleep,mktemp,dirname,basename,realpath,stat,du,df,echo,printf,test,true,false} rix,
  /bin/{date,cat,mkdir,rm,cp,mv,ls,touch,sleep,mktemp,dirname,basename,realpath,stat,du,df,echo,printf,test,true,false} rix,

  # (b) metin işleme (egrep/fgrep Ubuntu'da '#!/bin/sh' sarmalayıcı BETİK —
  #     'r' bu yüzden ZORUNLU, bkz. yukarıdaki "NEDEN 'rix'" notu)
  /usr/bin/{sed,grep,egrep,fgrep,awk,gawk,mawk,sort,head,tail,wc,cut,tr,uniq,tee} rix,
  /bin/{sed,grep,egrep,fgrep,awk,gawk,mawk,sort,head,tail,wc,cut,tr,uniq,tee} rix,

  # (c) arşiv/sıkıştırma — yedek alan cron'ların çekirdeği
  #     (gunzip/zcat de sarmalayıcı BETİKtir → 'r' zorunlu)
  /usr/bin/{tar,gzip,gunzip,zcat,xz,zstd} rix,
  /bin/{tar,gzip,gunzip,zcat,xz,zstd} rix,

  # (d) '[' (test'in ikinci adı) — DİKKAT, ÖZEL SÖZDİZİMİ:
  #     AppArmor'da '[' bir KARAKTER SINIFI açar; '/usr/bin/[ rix,' yazmak
  #     TÜM PROFİLİ parse edilemez hale getirir ("Regex grouping error:
  #     Unclosed grouping or character class") ve profil HİÇ YÜKLENMEZ —
  #     yani bir "sertleştirme" denemesi tam kesintiye/MAC'siz çalışmaya
  #     dönerdi. Literal '[' TEK karakterlik bir sınıf olarak yazılır:
  #     '[[]'. GERÇEK apparmor_parser ile HER İKİ LTS'te DOĞRULANDI
  #     (jammy 3.0.4 ve noble 4.0.1 konteynerlerinde 'apparmor_parser -Q'):
  #     '/usr/bin/[[]' OK, '/usr/bin/[' FAIL, '"/usr/bin/["' (tırnaklı) da
  #     FAIL. '--dump=rule-exprs' çıktısı anlamı da doğruladı:
  #     '/usr/bin/[[]  ->  /usr/bin/[\[]' (literal '[' içeren sınıf).
  #     NOT: pratikte 'test'/'[' dash ve bash'te DAHİLİ komuttur, bu yüzden
  #     bu satırın tetiklenmesi nadirdir — yine de eksiksizlik ve "aynı
  #     hatayı bir daha teşhis etmemek" için eklendi.
  /usr/bin/[[] rix,
  /bin/[[] rix,

  # (e) DB yedeği — istemci adı SEMBOLİK LİNK zinciriyle çözülür ve gerçek
  #     hedef kurulu pakete göre değişir ('mariadb-client' → 'mariadb-*',
  #     Oracle 'mysql-client' → 'mysql*'); bu yüzden dört ad da yazılır
  #     (ölçüm ve gerekçe: yukarıdaki ÇİFT-LTS notu, madde 3).
  #     Ağ erişimi bu profilde
  #     ZATEN açıktı (dosya sonundaki 'network inet stream' — dış API
  #     çağrıları için); bu satır YENİ bir egress yeteneği AÇMAZ, yalnızca
  #     yereldeki DB'ye bağlanacak ikilinin exec'ine izin verir.
  /usr/bin/{mysqldump,mysql,mariadb-dump,mariadb} rix,
  /bin/{mysqldump,mysql,mariadb-dump,mariadb} rix,

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
  # 'r' + O_CREAT'in ('c') gerekliliği flock(1)'ün KAYNAKTAN ÖLÇÜLEN açma
  # davranışından gelir — util-linux 'sys-utils/flock.c', open_file():
  #     int fl = *flags == 0 ? O_RDONLY : *flags;
  #     fl |= O_NOCTTY | O_CREAT;
  #     fd = open(filename, fl, 0666);
  # yani bir dosya YOLU (fd numarası DEĞİL) verildiğinde varsayılan açış
  # 'O_RDONLY | O_CREAT | O_NOCTTY'dir — 'O_RDWR' DEĞİL (bu satırın ESKİ
  # yorumu 'O_RDWR|O_CREAT' diyordu, YANLIŞTI; Ubuntu 22.04'ün v2.37.2 ve
  # 24.04'ün v2.39.3 etiketlerinde kod BİREBİR AYNI). 'O_RDWR' YALNIZCA
  # flock() EIO/EBADF döndüren NFS yolunda ikinci bir deneme olarak
  # kullanılır. Ölçülen 'denied_mask="rc"' de tam olarak bunu (r + create)
  # gösteriyordu.
  #
  # 'w' bu yüzden STRİKT olarak GEREKLİ DEĞİLDİR; yine de bırakılıyor çünkü
  # (1) bu profildeki HER flock()-gerektiren yol ZATEN 'rwk,' kullanıyor
  # (HOST'ta doğrulanmış desen), (2) yukarıdaki NFS geri-çekilme yolu 'w'
  # ister, (3) 'w' TEK BAŞINA hiçbir yetenek AÇMAZ: kilit dosyasının İÇERİĞİ
  # anlamsızdır (flock yalnız fd'yi kullanır) ve DİZİN artık domain
  # kullanıcısına yazılabilir OLMADIĞINDAN dosya SİLİNEMEZ/YERİNE
  # KONULAMAZ (aşağıdaki "HOST BULGUSU 3 + SAHİPLİK DÜZELTMESİ" notu).
  #
  # DÜRÜSTLÜK NOTU (görev talebi — "ölç, tahmin etme"): bu macOS geliştirme
  # makinesinde GERÇEK bir AppArmor çekirdeği YOK, bu yüzden 'rwk,'nın TAM
  # OLARAK yeterli/gerekli en dar küme olduğu BURADAN doğrulanamadı; DAR
  # olma tarafı (yalnız TEK dosya, glob YOK) doğrulanabilir, GENİŞLİK tarafı
  # HOST'a bırakılmıştır. 'rwk,' FAZLA geniş çıkarsa (ör. 'rk,' yetiyorsa)
  # tam 'denied_mask' çıktısıyla daraltılabilir.
  #
  # KAPSAM — TEK domain'in TEK dosyası (görev talebi: "DAR olması önemli"):
  # '{{SAFE_NAME}}' token'ı ile domain'in KENDİ kilit dosyasına SABİTLENİR;
  # '/run/srvctl/*' gibi bir glob KASITLI OLARAK YAZILMAZ — böyle bir kural
  # bir domainin BAŞKA domainlerin deploy kilit dosyalarını açabilmesi
  # (varlığını/durumunu sezebilmesi) anlamına gelirdi ve bu profilin TEK
  # var oluş nedeni olan domainler-arası izolasyon sınırını delerdi.
  #
  # GÜNCELLEME — HOST BULGUSU 3 (DAC/root ÇELİŞKİSİ, bu İKİ AppArmor
  # katmanından SONRA ölçüldü): yukarıdaki İKİ düzeltme TAM UYGULANDIKTAN
  # SONRA BİLE cron job'ları AYNI hatayla ('Permission denied', çıkış 66)
  # düşmeye devam etti — bu SEFER audit.log'da HİÇBİR 'apparmor="DENIED"'
  # kaydı YOKTU (MAC katmanına hiç sıra gelmiyordu). Kök neden: kilit
  # dizini ('/run/srvctl', bkz. lib/deploy.sh:_deploy_lock) 700 root:root
  # idi — bu SADECE root olarak çalışan '_deploy_lock' İÇİN doğruydu;
  # domain cron job'u ise User=web_{{SAFE_NAME}} olarak çalıştığından o
  # dizine AppArmor'dan ÖNCE, saf DAC seviyesinde hiç GİREMİYORDU. Kilit
  # artık domain BAŞINA ayrı bir alt dizinde yaşıyor
  # ('/run/srvctl/locks/{{SAFE_NAME}}/' — bkz. lib/deploy.sh:_deploy_lock_dir /
  # lib/cron.sh:_cron_lock_dir / lib/core.sh:_srvctl_lock_ensure) — bu satır
  # BİR ALT DİZİN daha ekleyerek güncellendi; "TEK domain'in TEK dosyası,
  # glob YOK" prensibi AYNEN KORUNDU. Üst dizinlerin (üst dizin + 'locks/' +
  # domain alt dizini) KENDİSİ için AppArmor kuralı GEREKMEZ — AppArmor path
  # mediation'ı DOSYANIN TAM YOLUNA göre çalışır, POSIX dizin 'x' (traverse)
  # izni gibi ARA dizin kuralı İSTEMEZ (o ayrım saf DAC'ın konusu; üst
  # dizinlerin 711 ve domain alt dizininin 710 root:{{WEB_USER}} olması
  # buradan bağımsız ayrıca sağlanır).
  #
  # ⚠ SAHİPLİK DÜZELTMESİ (KRİTİK — bu satırın izinlerini DEĞİŞTİRMEZ ama
  # NEDEN hâlâ çalıştığını açıklar): alt dizin ÖNCE '700
  # {{WEB_USER}}:{{WEB_USER}}' idi; SAHİBİ {{WEB_USER}} olduğu için o
  # kullanıcı kilit dosyasını UNLINK edip yerine KEYFİ bir hedefe sembolik
  # bağ koyabiliyordu (canlı Ubuntu 24.04 üretim sunucusunda SÖMÜRÜLDÜ) ve
  # root olarak çalışan 'srvctl deploy' bunu dereference edip hedefi
  # chown/chmod/truncate ediyordu. Dizin ARTIK '710 root:{{WEB_USER}}' —
  # {{WEB_USER}}'da yalnız 'x' (geçiş) var, 'w' YOK: dosya SİLİNEMEZ/YERİNE
  # KONULAMAZ. Kilit DOSYASI ise '660 root:{{WEB_USER}}' olarak ROOT
  # tarafından ÖN-OLUŞTURULUR; {{WEB_USER}} grup üzerinden 'rw' ile AÇABİLİR
  # — yani aşağıdaki 'rwk,' kuralı DAC tarafında karşılığını BULMAYA DEVAM
  # EDER (bu satırın değişmesine GEREK YOKTUR).
  /run/srvctl/locks/{{SAFE_NAME}}/deploy-{{SAFE_NAME}}.lock rwk,

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
