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
  #  Bu profil, systemd'nin AppArmorProfile= yönergesiyle TÜM
  #  srvctl-fpm-{{SAFE_NAME}}.service sürecine (master + chroot'lu/setuid
  #  düşürülmüş worker'lar) uygulanır. Aynı profil worker/scheduler
  #  unit'lerine de (srvctl-worker/srvctl-scheduler) atanır.
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

  # ─── Kendi binary'si (execve sonrası mmap-exec için 'm' şart) ───
  # NOT: AppArmorProfile= systemd tarafından onexec ile zorlanır; bu yüzden
  # exec-transition kuralı (px/ix) GEREKMEZ, ama process kendi text
  # sayfalarını PROT_EXEC ile map edebilmek için 'm' iznine ihtiyaç duyar
  # (distro daemon profillerinde standart desen). HOST'ta doğrulanmalı.
  /usr/sbin/php-fpm{{PHP_VERSION}} mr,

  # ─── SADECE BU DOMAIN'E ERİŞİM ───

  # Domain kök dizini (okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/ r,
  {{WEB_ROOT}}/{{DOMAIN}}/** r,

  # public_html (okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/public_html/** r,

  # private dizin (CI4 uygulama kodu — okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/private/** r,

  # writable dizinleri (okuma + yazma) — CI4
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/cache/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/logs/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/session/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/uploads/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/writable/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/writable/** rw,

  # Laravel yazma yolları (storage/framework/views, bootstrap/cache vb.)
  # render_template değer'lerinde newline yasak olduğundan framework'e göre
  # koşullu blok ENJEKTE EDİLEMEZ — bu yüzden üç framework'ün yolları da
  # statik/koşulsuz olarak dahil edilir (kullanılmayan yol = boş/no-op,
  # ek saldırı yüzeyi doğurmaz). Bkz. rapor: "Render escaping" notu.
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/storage/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/bootstrap/cache/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/storage/** rw,

  # Symfony yazma yolları (var/cache, var/log, var/sessions vb.)
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/var/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/var/** rw,

  # Log dizini (yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/logs/** rw,

  # Temp dizini (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/tmp/** rw,

  # Session dizini (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/sessions/** rw,

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
  deny /usr/bin/** x,
  deny /usr/sbin/** x,
  deny /bin/** x,
  deny /sbin/** x,

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
