#include <tunables/global>

profile srvctl-{{SAFE_NAME}} flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # ═══════════════════════════════════════════════
  #  AppArmor Profile: {{DOMAIN}}
  #  User: {{WEB_USER}}
  #  Bu profil PHP-FPM process'inin erişimini kısıtlar
  # ═══════════════════════════════════════════════

  # ─── SADECE BU DOMAIN'E ERİŞİM ───

  # Domain kök dizini (okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/ r,
  {{WEB_ROOT}}/{{DOMAIN}}/** r,

  # public_html (okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/public_html/** r,

  # private dizin (CI4 uygulama kodu — okuma)
  {{WEB_ROOT}}/{{DOMAIN}}/private/** r,

  # writable dizinleri (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/cache/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/logs/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/session/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/private/writable/uploads/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/shared/writable/** rw,
  {{WEB_ROOT}}/{{DOMAIN}}/releases/**/writable/** rw,

  # Log dizini (yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/logs/** rw,

  # Temp dizini (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/tmp/** rw,

  # Session dizini (okuma + yazma)
  {{WEB_ROOT}}/{{DOMAIN}}/sessions/** rw,

  # ─── Sistem Dosyaları (salt okuma) ───

  # PHP konfigürasyonu
  /etc/php/** r,
  /usr/lib/php/** r,

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

  # Diğer domain'ler
  deny /var/www/*/ r,

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
  network unix stream,
}
