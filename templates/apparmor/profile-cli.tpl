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
  # DÜZELTME (rapor: dalga4/B4): önceden yalnız 'mr' verilmişti (kendi
  # metin sayfalarını mmap etmek için) ve exec ('x') İZNİ YOKTU. Ama bu
  # profil altında çalışan süreç (worker/scheduler) çoğu zaman KENDİ ALT
  # SÜRECİNİ açar — Laravel schedule:run'ın ->command()/->exec() görevleri,
  # Symfony Process bileşeni, Horizon/queue supervisor'ları hep bir alt
  # 'php ...' veya 'sh -c "php ..."' çağırır. 'x' izni olmadan bu execve
  # AppArmor'da REDDEDİLİR ama üst süreç (schedule:run) genelde yine de 0
  # ile çıkar — hata hiçbir yerde görünmez, görev sessizce hiç çalışmaz
  # (fail-open/sessiz kesinti). Bu yüzden TAM YOL (glob'suz) ile 'rix'
  # (mevcut profile INHERIT ederek exec) veriliyor; blanket
  # 'deny /usr/bin/** x' bloğu (aşağıda) KORUNUYOR — spesifik/glob'suz bir
  # allow kuralı, altındaki glob deny kuralından DAHA SPESİFİK sayıldığı
  # için öncelikli olur (apparmor.d(5) specificity matching). HOST'ta
  # doğrulanmadan enforce'a geçmeyin (bkz. rapor HOST doğrulama bölümü).
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
  # bu üçüncü bir HOST doğrulama maddesidir.
  /bin/sh rix,
  /usr/bin/dash rix,

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
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/cache/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/logs/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/session/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/uploads/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/writable/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/writable/** rw,

  # Laravel (queue:work: storage/logs, cache; schedule:run: bootstrap/cache)
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/storage/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/bootstrap/cache/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/storage/** rw,

  # Symfony (messenger:consume: var/cache, var/log)
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/var/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var/** rw,

  {{WEB_ROOT}}/{{DOMAIN}}/logs/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/tmp/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/sessions/** rw,

  # ─── Sistem Dosyaları (salt okuma) ───
  /etc/php/** r,
  /usr/lib/php/** mr,
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
  # boşluğu"). Bu yüzden aşağıdaki exec-deny kuralları burada salt
  # dokümantasyon DEĞİL, gerçek bir MAC-katmanı yedek savunmadır — bir
  # kuyruk job'ı içinden shell_exec() çağrılsa bile AppArmor kernel
  # düzeyinde reddeder.
  # NOT (B4): yukarıdaki üç TAM YOL (glob'suz) 'rix' kuralı bu blanket
  # deny'lerle ÇAKIŞMAZ görünmeli — spesifik allow, glob deny'i ezer. Bu
  # varsayım HOST'ta doğrulanmadan KESİN sayılmasın (bkz. dosya başı NOT
  # ve rapor HOST doğrulama bölümü: aa-complain + gerçek schedule:run +
  # dmesg DENIED taraması).
  deny /usr/bin/** x,
  deny /usr/sbin/** x,
  deny /bin/** x,
  deny /sbin/** x,

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
