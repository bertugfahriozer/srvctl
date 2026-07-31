#!/bin/bash
# ═══════════════════════════════════════════════
#  init.sh — Sunucu İlk Kurulumu (tek seferlik, kesintiye dayanıklı)
#  12 güvenlik katmanını otomatik yapılandırır
# ═══════════════════════════════════════════════

# ─── Adım tamamlanma marker'ları (root-only state) ───
# Neden: init tek bir dev script değil, 12 adımlık uzun bir zincir (apt, systemd
# restart'ları, git clone...). Ctrl+C veya bir paket hatasıyla yarıda kesilirse
# eskiden TEK çıkış yolu baştan başlamaktı — bu da firewall adımındaki
# 'ufw --force reset' yüzünden ip.sh'ın yazdığı tüm ban/whitelist kurallarını
# siliyordu. Şimdi her adım SRVCTL_STATE_DIR altında bir marker bırakır; ikinci
# çalıştırma tamamlanmış adımları ATLAR (bkz. _init_run_step). '--force' ile
# tüm marker'lar yok sayılır ve baştan başlanır.
#
# SRVCTL_STATE_DIR (core.sh) domain marker'ları için de kullanılır
# (${SRVCTL_STATE_DIR}/<domain>/hardened). Çakışmayı önlemek için ayrı bir
# '_init' alt-dizini kullanılır — validate_domain baştaki '_' karakterini asla
# kabul etmediğinden gerçek bir domain adıyla ÇAKIŞMASI imkânsızdır.
_INIT_STATE_DIR="${SRVCTL_STATE_DIR}/_init"

# Adım tamamlanmış mı? (PREDIKAT — exit YOK)
_init_step_done() {
    [[ "${SRVCTL_INIT_FORCE:-false}" == "true" ]] && return 1
    [[ -f "${_INIT_STATE_DIR}/${1}.done" ]]
}

# Adımı tamamlanmış olarak işaretle (root-only, 0600)
_init_mark_done() {
    secure_dir "${_INIT_STATE_DIR}" 700
    secure_file "${_INIT_STATE_DIR}/${1}.done" 600
    date '+%Y-%m-%d %H:%M:%S' > "${_INIT_STATE_DIR}/${1}.done" 2>/dev/null || true
}

# Bir init adımını çalıştır — zaten tamamlanmışsa (ve --force yoksa) atla.
# Kullanım: _init_run_step <current> <total> <step_id> <açıklama> <fonksiyon>
#
# DEGRADE SÖZLEŞMESİ: adım fonksiyonu (ör. _init_step_ssh_hardening,
# _init_step_composer, _init_step_advanced_security) bir alt bileşeni
# kuramadığında/etkinleştiremediğinde artık 0 DEĞİL, niyetli olarak 1 döner.
# Eskiden bu fonksiyonlar 'warn "..."; return' ile bitiyordu — 'return'
# argümansız çağrıldığında bash SON çalıştırılan komutun (warn, ki her zaman
# 0 döner) çıkış kodunu miras alır; yani "sadece uyar" fiilen "başarılı say"
# ile aynı anlama geliyordu ve _init_mark_done HER durumda çağrılıyordu.
# Sonuç: ModSecurity/SSH hardening/Composer gibi katmanlar sessizce hiç
# kurulmamış olsa bile marker yazılıyor, 'srvctl init' tekrar çalıştırılınca
# adım ATLANIYOR ve asla yeniden denenmiyor (kalıcı fail-open).
#
# Düzeltme: "$func" artık bir if koşulunda çağrılır (set -e'yi bu satırda
# devre dışı bırakır — çağıran cmd_init'in tamamı ABORT OLMAZ, yalnızca bu
# adımın markerı yazılmaz). Böylece --force'a gerek KALMADAN (ve dolayısıyla
# UFW kurallarını SIFIRLAMADAN) bir sonraki 'srvctl init' çalıştırması SADECE
# degrade/başarısız adımı otomatik olarak yeniden dener; zaten tamamlanmış
# adımlar (marker'ları duruyor) yine atlanır.
_init_run_step() {
    local current="$1" total="$2" step_id="$3" desc="$4" func="$5"
    if _init_step_done "$step_id"; then
        step "${current}/${total}" "${desc} — atlanıyor (önceki init'te tamamlanmış; yeniden çalıştırmak için: srvctl init --force)"
        return 0
    fi
    step "${current}/${total}" "$desc"
    if "$func"; then
        _init_mark_done "$step_id"
    else
        _INIT_ANY_DEGRADED=true
        warn "${desc} — TAM olarak tamamlanamadı (yukarıdaki uyarılara bakın); bu adım için marker YAZILMADI — bir sonraki 'srvctl init' çalıştırmasında (--force GEREKMEZ) otomatik olarak yeniden denenecek"
    fi
}

cmd_init() {
    require_root
    _init_apt_noninteractive

    SRVCTL_INIT_FORCE=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force) SRVCTL_INIT_FORCE=true ;;
        esac
    done

    header "srvctl init — Sunucu İlk Kurulumu"

    # _init_run_step degrade bir adımı tespit ederse bunu true'ya çeker
    # (bkz. _init_run_step yorumu) — kapanışta "Tamamlandı" yerine "Kısmen
    # Tamamlandı" banner'ı basmak ve log_action'a doğru sonucu yazmak için.
    _INIT_ANY_DEGRADED=false

    if [[ "$SRVCTL_INIT_FORCE" == "true" ]]; then
        warn "--force: TÜM adımlar yeniden çalıştırılacak (UFW kuralları sıfırlanır — ip.sh whitelist/blacklist dosyaları /etc/srvctl/ip-*.conf'ta kalır ama ufw/fail2ban'e yeniden UYGULANMAZ; gerekirse 'srvctl ip' komutlarını tekrar çalıştırın)"
    elif [[ -d "$_INIT_STATE_DIR" ]]; then
        info "Önceki init'ten tamamlanmış adımlar bulundu — yalnızca eksik/başarısız adımlar çalıştırılacak (baştan başlamak için: srvctl init --force)"
    fi

    local total=12
    local current=0

    # ─── 1. Sistem Güncellemesi ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "system_update" "Sistem güncelleniyor..." _init_step_system_update

    # ─── 2. Kernel Hardening ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "kernel_hardening" "Kernel güvenlik ayarları..." _init_step_kernel_hardening

    # ─── 3. Process izolasyonu ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "proc_isolation" "Process izolasyonu (hidepid)..." _init_step_proc_isolation

    # ─── 4. SSH Hardening ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "ssh_hardening" "SSH güvenlik ayarları (Port: ${SSH_PORT})..." _init_step_ssh_hardening

    # ─── 5. Firewall ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "firewall" "Firewall (UFW)..." _init_step_firewall

    # ─── 6. Nginx ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "nginx" "Nginx kuruluyor..." _init_step_nginx

    # ─── 7. PHP-FPM ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "php" "PHP-FPM kuruluyor..." _init_step_php

    # ─── 8. Composer ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "composer" "Composer kuruluyor..." _init_step_composer

    # ─── 9. MariaDB ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "mariadb" "MariaDB kuruluyor..." _init_step_mariadb

    # ─── 10. Redis ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "redis" "Redis kuruluyor..." _init_step_redis

    # ─── 11. Fail2Ban + auditd + cron + deployer ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "fail2ban_auditd" "Fail2Ban + auditd kuruluyor..." _init_step_fail2ban_auditd

    # ─── 12. Gelişmiş Güvenlik Katmanları ───
    current=$((current + 1))
    _init_run_step "$current" "$total" "advanced_security" "Gelişmiş güvenlik (cgroups, ModSecurity, AIDE, ClamAV, GeoIP)..." _init_step_advanced_security

    # ─── Dizinler (saf idempotent — marker gerekmez) ───
    mkdir -p "${WEB_ROOT}" "${SRVCTL_ROOT}/logs"
    # Yedek dizini sır içerir → 0700 root:root
    secure_dir "${BACKUP_DIR}" 700

    # ─── Otomatik güvenlik güncellemeleri ───
    dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true

    if [[ "$_INIT_ANY_DEGRADED" == "true" ]]; then
        header "⚠ Sunucu Kurulumu KISMEN Tamamlandı"
        warn "Bir veya daha fazla adım TAM olarak tamamlanamadı (yukarıdaki uyarılara bakın). Bu adımlar için marker yazılmadı — 'sudo srvctl init' komutunu TEKRAR çalıştırdığınızda YALNIZCA eksik/başarısız adımlar otomatik olarak yeniden denenecek (--force GEREKMEZ, UFW kuralları korunur)."
    else
        header "✅ Sunucu Kurulumu Tamamlandı!"
    fi

    echo "  SSH Port:        ${SSH_PORT}"
    echo "  MariaDB root:    /root/.my.cnf"
    echo "  Redis admin:     ${SRVCTL_CONF}"
    echo "  Web root:        ${WEB_ROOT}"
    echo "  Yedek dizini:    ${BACKUP_DIR}"
    echo ""
    # O12 (DALGA 5, bulgu sahibi yok — lib/backup.sh'ta ayrı turda ele alınacak):
    # '${BACKUP_DIR}/*/configs.tar.gz' /etc/redis/users.acl (düz metin ACL
    # parolaları) ve srvctl.conf (REDIS_ADMIN_PASS/CF_API_TOKEN) İÇERİR.
    # BACKUP_DIR burada 0700 root:root (secure_dir) ve her artefakt 0600 —
    # ama yedekler TANIM GEREĞİ sunucu dışına taşınabilir; o an bu yerel
    # koruma devre dışı kalır. README'nin "yedekler sır içermez" iddiası
    # YANLIŞ — operatörü burada, gerçek düzeltme gelene kadar uyar.
    warn "Yedekler (${BACKUP_DIR}/*/configs.tar.gz) düz metin sır içerir (Redis ACL parolaları, srvctl.conf token'ları). Dizin sunucuda 0700 root:root ile korunuyor ama yedekleri DIŞARI taşırken (rsync/scp/S3 vb.) şifreleyin — bu henüz otomatik değildir."
    echo ""
    echo -e "  ${BOLD}Sonraki adım:${NC}  sudo srvctl domain add <domain.com>"
    echo ""

    if [[ "$_INIT_ANY_DEGRADED" == "true" ]]; then
        log_action "INIT completed with degraded step(s) — retry via 'srvctl init'"
    else
        log_action "INIT completed successfully"
    fi
}

# ═══════════════════════════════════════════════
#  ADIM FONKSİYONLARI (cmd_init tarafından _init_run_step ile çağrılır)
# ═══════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  Paket kurulumu — TEK giriş noktası (PREDİKAT: 0=kuruldu 1=kurulamadı)
#
#  HOST BULGUSU (Ubuntu 24.04, gerçek VM): çekirdek paket kurulumları
#  (nginx/mariadb/redis/fail2ban) dönüş değerini KONTROL ETMİYORDU. İlk
#  boot'ta cloud-init/unattended-upgrades apt lock'unu tuttuğu için
#  'apt-get install nginx' sessizce başarısız oldu, kod devam etti,
#  '/etc/nginx/nginx.conf' yazılamadı ("No such file or directory") ve
#  hata ancak birkaç adım sonra 'nginx: command not found' olarak yüzeye
#  çıktı — yani asıl sebep kaybolmuştu. İronik olarak opsiyonel katmanlar
#  (modsecurity/aide/clamav/geoip) zaten korumalıydı; kritik olanlar değil.
#
#  'DPkg::Lock::Timeout' apt'nin kendi bekleme mekanizmasıdır (sleep+retry
#  döngüsü yazmaktan daha doğru): lock başkasındaysa N saniye bekler.
# ───────────────────────────────────────────────────────────────
_apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq -o DPkg::Lock::Timeout=300 "$@" > /dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────
#  apt'yi TAMAMEN etkileşimsiz hale getir — cmd_init'in İLK işi.
#
#  HOST BULGUSU (Ubuntu 24.04, gerçek VM): 'srvctl init' AIDE kurulumu
#  sırasında postfix'in debconf ekranında ("General mail configuration
#  type") SÜRESİZ KİLİTLENDİ. postfix doğrudan kurulmuyor — aide/fail2ban
#  bağımlılığı olarak geliyor, yani hangi adımda çıkacağı önceden belli
#  değil. Arka planda/cron/cloud-init/Ansible ile çalışan bir init'te
#  stdin YOKTUR: prompt log'a düşer, kimse cevaplayamaz, kurulum asılı
#  kalır. Tek tek 'DEBIAN_FRONTEND' export etmek yetmez — bağımlılık
#  zinciriyle gelen HER paket için garanti gerekir.
#
#  İki katman:
#   1) DEBIAN_FRONTEND=noninteractive + DEBCONF_NONINTERACTIVE_SEEN:
#      debconf hiç soru sormaz, varsayılanı kullanır.
#   2) postfix'i AÇIKÇA seedle: varsayılanı 'Internet Site'tır ve o
#      postfix'i 25/tcp'de dinletir — güvenlik-öncelikli bir sunucuda
#      istemediğimiz bir dış yüzey. 'Local only' yalnız yerel teslimat
#      yapar (cron/AIDE/fail2ban raporları root'a gider), ağdan bağlantı
#      KABUL ETMEZ.
# ───────────────────────────────────────────────────────────────
_init_apt_noninteractive() {
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export NEEDRESTART_MODE=a          # needrestart servis-yeniden-başlat ekranı
    export UCF_FORCE_CONFOLD=1         # değiştirilmiş conf dosyalarında soru sorma

    # postfix debconf seed — bağımlılık olarak gelmeden ÖNCE.
    if command -v debconf-set-selections >/dev/null 2>&1; then
        printf 'postfix postfix/main_mailer_type select Local only\npostfix postfix/mailname string %s\n' \
            "$(hostname -f 2>/dev/null || hostname)" \
            | debconf-set-selections 2>/dev/null || true
    fi
}

# Kurulum + fail-closed kapı: başarısızsa çağıran adımı düşürür (marker
# yazılmaz → sıradaki 'srvctl init' bu adımı YENİDEN dener).
_apt_install_required() {
    local what="$1"; shift
    if ! _apt_install "$@"; then
        warn "Paket kurulumu BAŞARISIZ (${what}): $* — 'apt-get install $*' ile elle deneyin"
        return 1
    fi
    return 0
}

_init_step_system_update() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -o DPkg::Lock::Timeout=300 \
        || { warn "apt-get update başarısız — ağ/kaynak listesi kontrol edin"; return 1; }
    apt-get upgrade -y -qq -o DPkg::Lock::Timeout=300 \
        || warn "apt-get upgrade kısmen başarısız — kuruluma devam ediliyor"
    _apt_install_required "temel bağımlılıklar" \
        software-properties-common curl wget gnupg2 \
        unattended-upgrades apt-listchanges \
        acl auditd audispd-plugins \
        apparmor apparmor-utils \
        logrotate rsync git jq certbot \
        python3-certbot-nginx \
        || return 1
    success "Sistem güncellendi ve bağımlılıklar kuruldu"
}

_init_step_kernel_hardening() {
    cat > /etc/sysctl.d/99-srvctl-security.conf << 'SYSCTL'
# ─── Network Security ───
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
# IPv6 kapalı
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# ─── Kernel Security ───
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.sysrq = 0
# ─── Filesystem ───
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
SYSCTL
    sysctl -p /etc/sysctl.d/99-srvctl-security.conf > /dev/null 2>&1
    success "Kernel hardening uygulandı"
}

_init_step_proc_isolation() {
    if ! grep -q "hidepid=2" /etc/fstab; then
        echo "proc /proc proc defaults,hidepid=2,gid=adm 0 0" >> /etc/fstab
    fi
    if ! grep -q "/run/shm.*noexec" /etc/fstab; then
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi
    mount -o remount /proc 2>/dev/null || true
    success "hidepid=2 aktif — process'ler izole"
}

_init_step_ssh_hardening() {
    # sshd_config.d drop-in dizini bazı minimal imajlarda GELMEZ → oluştur.
    mkdir -p /etc/ssh/sshd_config.d
    # Ana sshd_config bu dizini Include etmiyorsa EN BAŞA ekle (sshd first-match-wins;
    # drop-in ana config'teki değerleri override edebilsin). Yoksa hardening yok sayılır.
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
        cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.srvctl-bak 2>/dev/null || true
        { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat /etc/ssh/sshd_config; } \
            > /etc/ssh/sshd_config.srvctl-tmp && mv /etc/ssh/sshd_config.srvctl-tmp /etc/ssh/sshd_config
    fi
    cat > /etc/ssh/sshd_config.d/99-srvctl.conf << SSHCONF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSHCONF
    # Restart ÖNCESİ config'i doğrula: hatalı sshd config'iyle restart edip
    # kendini kilitlemeyi önle. Doğrulama başarısızsa drop-in'i geri al.
    #
    # Her iki dal da (doğrulama başarısız / restart başarısız) artık AÇIKÇA
    # 'return 1' ile biter: eskiden restart 'systemctl restart ssh || systemctl
    # restart sshd || true' idi — sondaki '|| true' iki deneme de BAŞARISIZ
    # olsa bile fonksiyonun 0 dönmesini sağlıyordu, yani hardening config'i
    # doğrulanmış ama devreye ASLA alınmamış olsa dahi "uygulandı" marker'ı
    # yazılıyordu. Artık _init_run_step bu durumu görüp adımı bir sonraki
    # 'srvctl init'te yeniden dener (bkz. _init_run_step yorumu).
    if sshd -t 2>/dev/null; then
        if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            success "SSH hardening uygulandı (Port: ${SSH_PORT})"
        else
            warn "sshd config doğrulandı ama SSH servisi yeniden BAŞLATILAMADI — hardening ayarları devreye alınmamış olabilir (bkz. journalctl -xeu ssh / journalctl -xeu sshd)"
            return 1
        fi
    else
        rm -f /etc/ssh/sshd_config.d/99-srvctl.conf
        warn "sshd config doğrulaması BAŞARISIZ — SSH hardening atlandı, mevcut SSH korundu"
        return 1
    fi
}

_init_step_firewall() {
    # 'ufw --force reset' TÜM kuralları siler (ip.sh'ın eklediği ignoreip/ban
    # kuralları dahil). Bu adım artık _init_run_step marker'ı ile korunuyor:
    # yalnızca ilk init'te veya 'srvctl init --force' ile çalışır — sıradan bir
    # yeniden çalıştırma (örn. daha sonraki bir adım hatasından kurtarma) bu
    # adımı ATLAR ve reset tekrar tetiklenmez.
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' > /dev/null 2>&1
    ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
    ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1
    ufw limit "${SSH_PORT}/tcp" > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    success "UFW aktif — sadece ${SSH_PORT}, 80, 443 açık"

    # reset TÜM ban/whitelist kurallarını sildi; /etc/srvctl/ip-*.conf diskte
    # duruyor ama onları uygulayan kimse yoktu — operatör ban listesini
    # kaybettiğini fark etmeyebilirdi. _ip_reapply_all idempotent olduğundan
    # koşulsuz çağrılır. Çapraz modül: _load_and_run tek modül source eder,
    # bu yüzden ip.sh'ı burada açıkça yüklüyoruz (yoksa exit 127).
    if source "${SRVCTL_ROOT}/lib/ip.sh" 2>/dev/null && declare -F _ip_reapply_all >/dev/null 2>&1; then
        _ip_reapply_all || warn "IP kuralları yeniden uygulanamadı — 'srvctl ip reapply' ile deneyin"
    else
        warn "lib/ip.sh yüklenemedi — ban/whitelist kuralları yeniden uygulanmadı ('srvctl ip reapply')"
    fi
}

_init_step_nginx() {
    _install_nginx
    success "Nginx kuruldu ve yapılandırıldı"
}

_init_step_php() {
    _install_php
    success "PHP-FPM kuruldu"
}

_init_step_composer() {
    if _install_composer; then
        success "Composer kuruldu: $(composer --version 2>/dev/null || echo "/usr/local/bin/composer")"
    else
        warn "Composer KURULAMADI — 'vendor/autoload.php' bekleyen deploy'lar composer olmadan HTTP 500 verecektir. Elle kurmak için: https://getcomposer.org/download/"
        # 'return 1' YOKSA bu adım marker'ı yine de yazılır ve composer bir
        # daha ASLA denenmez (bkz. _init_run_step degrade sözleşmesi) — geçici
        # bir ağ hatası kalıcı hale gelir.
        return 1
    fi
}

_init_step_mariadb() {
    _install_mariadb
    success "MariaDB kuruldu ve güvenlik ayarları yapıldı"
}

_init_step_redis() {
    # '_install_redis' artık bir sed adımında başarısız olursa 'return 1'
    # dönebiliyor (bkz. REDIS_ADMIN_PASS post-condition) — bunu bir 'if' ile
    # kontrol ETMEDEN eskisi gibi bare çağırırsak dönüş değeri SESSİZCE
    # kaybolur (bu fonksiyonun son komutu her zaman 'success' olur, ki o
    # her zaman 0 döner) ve _init_run_step degrade/retry mekanizması hiç
    # tetiklenmez. _init_step_composer ile aynı desen.
    if _install_redis; then
        success "Redis kuruldu (ACL aktif)"
    else
        warn "Redis TAM olarak yapılandırılamadı (yukarıdaki uyarılara bakın)"
        return 1
    fi
}

_init_step_fail2ban_auditd() {
    _install_fail2ban
    _install_auditd
    _setup_cron_jobs
    _create_deployer_user
    success "Fail2Ban + auditd aktif"
}

_init_step_advanced_security() {
    # NOT: _setup_cgroups'un başarısızlığı (cgroups v2 kapalı) burada
    # AYIRT EDİLMEDEN bilerek dışarıda bırakıldı — tek çözümü GRUB'a
    # 'systemd.unified_cgroup_hierarchy=1' ekleyip REBOOT etmektir; aynı
    # scripti yeniden çalıştırmak sonucu değiştirmez. Bu adımı "degrade"
    # sayıp sonsuza kadar yeniden denetmek yerine (retry hiçbir zaman
    # başarılı olamayacağından) mevcut warn+devam-et davranışı korunuyor.
    _setup_cgroups

    local failed=0
    _install_modsecurity || failed=1
    _install_aide        || failed=1
    _install_clamav      || failed=1
    _install_geoip       || failed=1

    if [[ "$failed" -eq 0 ]]; then
        success "Gelişmiş güvenlik katmanları kuruldu"
    else
        # Alt fonksiyonlardan en az biri degrade oldu (non-zero döndü) —
        # bu adımın TAMAMINI marker'sız bırak ki tüm 5 alt-adım (idempotent
        # oldukları için zaten kurulu olanlar no-op geçer) bir sonraki
        # 'srvctl init' çalıştırmasında yeniden denensin.
        warn "Gelişmiş güvenlik katmanlarından bazıları TAM kurulamadı (yukarıdaki uyarılara bakın)"
        return 1
    fi
}

# ═══════════════════════════════════════════════
#  HELPER FONKSİYONLAR
# ═══════════════════════════════════════════════

# Rate-limit kademe zone'larını üret (http context — conf.d include için).
# conn_per_ip zone'u nginx.conf'ta tanımlı olduğundan burada tekrar edilmez.
render_ratelimit_zones() {
    cat << 'RLZONES'
# srvctl — rate-limit kademe zone'ları (otomatik üretildi, elle düzenlemeyin)
limit_req_zone $binary_remote_addr zone=rl_strict:10m rate=3r/s;
limit_req_zone $binary_remote_addr zone=rl_standard:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=rl_relaxed:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=rl_api:10m rate=60r/s;
limit_req_zone $binary_remote_addr zone=login_strict:10m rate=3r/m;
limit_req_zone $binary_remote_addr zone=login_standard:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=login_relaxed:10m rate=10r/m;
limit_req_status 429;
limit_conn_status 429;
RLZONES
}

_install_nginx() {
    # Nginx'in kurulu olup olmadığını kontrol et
    if ! command -v nginx &>/dev/null; then
        _apt_install_required "nginx" nginx || return 1
    fi

    # Ana yapılandırma
    cat > /etc/nginx/nginx.conf << 'NGINXCONF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

# Dinamik modülleri yükle (ModSecurity, GeoIP vb.) — paketlerin
# /etc/nginx/modules-enabled/ altına bıraktığı load_module conf'ları. Bu satır
# olmadan 'modsecurity'/'geoip_country' direktifleri "unknown directive" verip
# nginx -t'yi patlatır (domain add step 5'te abort). Stok Ubuntu nginx.conf'ta var.
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # ─── Temel ───
    server_names_hash_bucket_size 128;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    client_max_body_size 50M;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ─── Log Format ───
    log_format security '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent" '
                        '$request_time $upstream_response_time';

    access_log /var/log/nginx/access.log security;
    error_log /var/log/nginx/error.log warn;

    # ─── Gzip ───
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml application/font-woff2;

    # ─── Rate Limiting ───
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;

    # ─── SSL ───
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ─── Symlink Koruması ───
    disable_symlinks if_not_owner;

    # ─── Bilinmeyen Domain Reddet ───
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
NGINXCONF

    # Kademe rate-limit zone'larını conf.d'ye yaz (nginx -t öncesi)
    mkdir -p /etc/nginx/conf.d
    render_ratelimit_zones > /etc/nginx/conf.d/00-srvctl-ratelimit.conf

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    # Varsayılan site'ı kaldır
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/default.conf

    systemctl enable nginx > /dev/null 2>&1

    # Guard'lı restart: eskiden 'nginx -t && systemctl restart nginx' bare
    # ifadesiydi — nginx -t stderr'e susturulmuştu, herhangi bir taraf
    # başarısız olursa 'set -e' kullanıcıya HİÇBİR mesaj vermeden init'i
    # yarıda kesiyordu. Şimdi hangi adımın neden başarısız olduğu söylenir.
    local nginx_t_err; nginx_t_err="$(mktemp /tmp/srvctl-nginx-t.XXXXXX)" || nginx_t_err="/dev/null"
    if ! nginx -t 2>"$nginx_t_err"; then
        error "Nginx yapılandırma testi başarısız (nginx -t). Detay: $(tail -n1 "$nginx_t_err" 2>/dev/null) — tam çıktı için: nginx -t"
    fi
    rm -f "$nginx_t_err"
    if ! systemctl restart nginx; then
        error "Nginx başlatılamadı (nginx -t başarılıydı ama systemctl restart nginx başarısız oldu). Detay: journalctl -xeu nginx"
    fi
}

_install_php() {
    # Ondrej PPA ('-f glob' çalışmaz — SC2144; compgen -G ile gerçek glob eşleşmesi)
    if ! compgen -G "/etc/apt/sources.list.d/ondrej-*.list" > /dev/null && ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
        apt-get update -qq
    fi

    # PHP versiyonlarını kur
    for ver in 8.2 8.3 8.4; do
        if ! php_version_exists "$ver"; then
            # Bilinçli olarak fail-open: bir PHP sürümü repo'da yoksa (24.04'te
            # php8.2 ondrej PPA gerektirir) init DÜŞMEMELİ — aşağıdaki dizin
            # kontrolü o sürümü atlar. Yalnız apt lock beklemesi eklenir.
            _apt_install \
                "php${ver}-fpm" "php${ver}-cli" "php${ver}-mysql" "php${ver}-sqlite3" "php${ver}-redis" \
                "php${ver}-curl" "php${ver}-gd" "php${ver}-mbstring" "php${ver}-xml" \
                "php${ver}-zip" "php${ver}-intl" "php${ver}-bcmath" "php${ver}-opcache" \
                "php${ver}-readline" "php${ver}-soap" \
                || warn "PHP ${ver} kurulumunda bazı paketler atlandı"
        fi

        # Kurulmadıysa (örn. Ubuntu 24.04 default repo'da php8.2 YOK — ondrej PPA
        # gerekir; PPA eklenemezse apt atlar) bu sürümü atla. Aksi halde alttaki
        # 'cat > /etc/php/${ver}/...' dizin yokluğunda set -e ile init'i patlatır.
        [[ -d "/etc/php/${ver}/fpm/conf.d" ]] || { warn "PHP ${ver} kurulu değil — atlanıyor"; continue; }

        # PHP güvenlik ayarları
        cat > "/etc/php/${ver}/fpm/conf.d/99-srvctl-security.ini" << 'PHPINI'
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,proc_close,proc_get_status,proc_nice,proc_terminate,pcntl_alarm,pcntl_exec,pcntl_fork,pcntl_get_last_error,pcntl_getpriority,pcntl_setpriority,pcntl_signal,pcntl_signal_dispatch,pcntl_strerror,pcntl_wait,pcntl_waitpid,pcntl_wexitstatus,pcntl_wifexited,pcntl_wifsignaled,pcntl_wifstopped,pcntl_wstopsig,pcntl_wtermsig,dl,putenv,show_source,highlight_file
file_uploads = On
upload_max_filesize = 50M
post_max_size = 55M
max_file_uploads = 10
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
session.cookie_samesite = Strict
session.use_only_cookies = 1
session.name = __Secure_SID
session.gc_maxlifetime = 3600
max_execution_time = 60
max_input_time = 60
memory_limit = 256M
max_input_vars = 5000
allow_url_fopen = Off
allow_url_include = Off
cgi.fix_pathinfo = 0
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.save_comments = 1
PHPINI

        # Varsayılan www pool'unu devre dışı bırak
        if [[ -f "/etc/php/${ver}/fpm/pool.d/www.conf" ]]; then
            mv "/etc/php/${ver}/fpm/pool.d/www.conf" "/etc/php/${ver}/fpm/pool.d/www.conf.disabled" 2>/dev/null || true
        fi

        systemctl enable "php${ver}-fpm" > /dev/null 2>&1
        systemctl restart "php${ver}-fpm" 2>/dev/null || true
    done
}

# ───────────────────────────────────────────────────────────────
#  Composer — resmi installer.sig SHA-384 doğrulaması ile (fail-closed)
#
#  GÜVENLİK: 'curl https://getcomposer.org/installer | php' deseni KULLANMAZ —
#  bu, indirilen kodu doğrulamadan root olarak çalıştırmak anlamına gelir
#  (tedarik zinciri saldırı yüzeyi: DNS hijack, MITM, CDN/registry ele geçirme).
#  Bunun yerine getcomposer.org'un resmi doğrulama akışı izlenir:
#    1. installer'ı indir (getcomposer.org/installer)
#    2. composer.github.io/installer.sig'ten o ANDAKİ installer'ın beklenen
#       SHA-384 özetini indir (Composer projesi bu dosyayı her installer
#       güncellemesinde günceller — bkz. getcomposer.org/download/)
#    3. yerel dosyanın sha384sum'ını hesapla ve KARŞILAŞTIR
#    4. eşleşmezse HİÇ ÇALIŞTIRMA — installer'ı sil, kurulum yapma
#  Her iki indirme de HTTPS üzerinden yapılır (curl varsayılan olarak sertifika
#  doğrular; -k/--insecure KULLANILMAZ) — bu TLS pinning'in yerini tutmaz ama
#  transport bütünlüğünü sağlar; asıl bütünlük garantisi SHA-384 karşılaştırması.
#
#  NOT (kapsam dışı bırakılan güçlendirme): tam bir tedarik-zinciri zırhı için
#  ayrıca composer.phar'ın imzalı release'lerini (tag bazlı, GPG) doğrulamak
#  gerekir — bu yalnızca composer ZATEN kuruluyken 'composer self-update
#  --update-keys' ile mümkündür, bootstrap anında değil. Bu yüzden bootstrap
#  için resmi SHA-384 akışı kullanılıyor; bu, upstream'in kendi dokümante
#  ettiği ASGARİ doğrulamadır.
#
#  Composer olmadan da nginx/php-fpm/mariadb/redis vb. ayakta kalabildiğinden
#  bu adımın başarısızlığı init'i DÜŞÜRMEZ — yalnızca belirgin bir uyarı verir
#  (çağıran _init_step_composer).
# ───────────────────────────────────────────────────────────────
_install_composer() {
    if command -v composer &>/dev/null; then
        info "Composer zaten kurulu: $(composer --version 2>/dev/null || echo "sürüm okunamadı") — atlanıyor"
        return 0
    fi

    # Composer bir PHP scripti çalıştırılarak kurulur — kurulu bir PHP CLI şart.
    local php_bin
    php_bin="$(command -v php || true)"
    if [[ -z "$php_bin" ]]; then
        php_bin="$(command -v "php${DEFAULT_PHP_VERSION}" || true)"
    fi
    if [[ -z "$php_bin" ]]; then
        warn "Composer kurulamadı: çalışan bir PHP CLI bulunamadı (PHP-FPM adımı başarısız olmuş olabilir)"
        return 1
    fi

    local tmp_installer
    tmp_installer="$(mktemp /tmp/srvctl-composer-setup.XXXXXX.php)" || return 1

    if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp_installer" https://getcomposer.org/installer; then
        rm -f "$tmp_installer"
        warn "Composer installer indirilemedi (ağ/getcomposer.org erişimi?)"
        return 1
    fi

    local expected_sig actual_sig
    expected_sig="$(curl -fsSL --proto '=https' --tlsv1.2 https://composer.github.io/installer.sig 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$expected_sig" ]]; then
        rm -f "$tmp_installer"
        warn "Composer SHA-384 referans özeti alınamadı (composer.github.io erişimi?) — GÜVENLİK NEDENİYLE kurulum yapılMADI (fail-closed)"
        return 1
    fi

    actual_sig="$(sha384sum "$tmp_installer" 2>/dev/null | awk '{print $1}')"
    if [[ -z "$actual_sig" || "$expected_sig" != "$actual_sig" ]]; then
        rm -f "$tmp_installer"
        echo -e "  ${RED}✗${NC}  GÜVENLİK: Composer installer SHA-384 doğrulaması BAŞARISIZ — beklenen=${expected_sig:0:16}... hesaplanan=${actual_sig:0:16}... Bu bir tedarik zinciri saldırısı belirtisi olabilir. Kurulum yapılMADI (fail-closed)." >&2
        log_action "SECURITY: composer installer sha384 mismatch (expected=${expected_sig} actual=${actual_sig})"
        return 1
    fi

    if ! "$php_bin" "$tmp_installer" --install-dir=/usr/local/bin --filename=composer --quiet; then
        rm -f "$tmp_installer"
        warn "Composer installer çalıştırılamadı (php hata verdi)"
        return 1
    fi
    rm -f "$tmp_installer"

    if [[ ! -x /usr/local/bin/composer ]]; then
        warn "Composer kurulum sonrası /usr/local/bin/composer bulunamadı"
        return 1
    fi

    chown root:root /usr/local/bin/composer
    chmod 755 /usr/local/bin/composer
    return 0
}

_install_mariadb() {
    if ! command -v mysql &>/dev/null; then
        _apt_install_required "MariaDB" mariadb-server mariadb-client || return 1
    fi

    # Güvenlik yapılandırması
    cat > /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf << 'MARIADB'
[mysqld]
bind-address = 127.0.0.1
local-infile = 0
symbolic-links = 0
secure-file-priv = /var/lib/mysql-files
log_error = /var/log/mysql/error.log
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
max_connections = 200
thread_cache_size = 16
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
MARIADB

    mkdir -p /var/lib/mysql-files
    systemctl enable mariadb > /dev/null 2>&1
    if ! systemctl restart mariadb; then
        error "MariaDB başlatılamadı. Detay: journalctl -xeu mariadb / systemctl status mariadb"
    fi

    # Root şifresi ayarla
    local root_pass
    root_pass=$(generate_password 32)

    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    # Root credentials dosyası (umask 077 + 0600 root:root)
    (
        umask 077
        cat > /root/.my.cnf << MYCNF
[client]
user=root
password=${root_pass}
MYCNF
    )
    secure_file /root/.my.cnf 600

    info "MariaDB root şifresi: /root/.my.cnf"
}

_install_redis() {
    if ! command -v redis-server &>/dev/null; then
        _apt_install_required "Redis" redis-server || return 1
    fi

    local redis_admin_pass
    redis_admin_pass=$(generate_password 32)

    # 'supervised' yönergesi: yetenek tespiti — systemd PID 1 ise 'systemd',
    # değilse 'no'. Ubuntu'nun stok redis-server.service'i 'Type=notify'
    # kullanır; bu yönerge YOKSA redis-server systemd'ye READY=1 bildirimini
    # ASLA göndermez → systemd TimeoutStartSec'te vazgeçer → 'systemctl restart
    # redis-server' non-zero döner → (guard'sızsa) set -e ile init'i ortada
    # bırakır. Bu, hem 22.04 hem 24.04'te aynı kök nedene sahiptir (fark
    # sürüm değil, bizim ürettiğimiz redis.conf'un eksikliğidir).
    local redis_supervised="no"
    [[ -d /run/systemd/system ]] && redis_supervised="systemd"

    # Redis yapılandırması
    cat > /etc/redis/redis.conf << REDISCONF
# ─── Ağ ───
bind 127.0.0.1
port 6379
protected-mode yes
tcp-backlog 511
timeout 300
tcp-keepalive 300

# ─── Systemd Supervision ───
# (srvctl.conf üzerinden yazıldı; bkz. lib/init.sh _install_redis)
supervised ${redis_supervised}
pidfile /run/redis/redis-server.pid

# ─── ACL ───
aclfile /etc/redis/users.acl

# ─── Tehlikeli Komutları Devre Dışı Bırak ───
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
rename-command DEBUG ""
rename-command KEYS ""

# ─── Memory ───
maxmemory 512mb
maxmemory-policy allkeys-lru

# ─── Persistence ───
save 900 1
save 300 10
save 60 10000
dir /var/lib/redis
dbfilename dump.rdb

# ─── Logging ───
loglevel notice
logfile /var/log/redis/redis-server.log
REDISCONF

    # ACL dosyası (umask 077 — parola world-readable olmasın)
    (
        umask 077
        # NOT: aclfile YORUM (#) ve boş satır KABUL ETMEZ (redis "should start with
        # user keyword" ile başlatmayı iptal eder). Yalnız 'user ...' satırları yaz.
        cat > /etc/redis/users.acl << REDISACL
user admin on >${redis_admin_pass} ~* &* +@all
user default off nopass ~* &* -@all
REDISACL
    )
    # redis.conf sır içermez (0640); users.acl parola taşır (0600), sahibi redis daemon
    chmod 640 /etc/redis/redis.conf
    chmod 600 /etc/redis/users.acl
    chown redis:redis /etc/redis/redis.conf /etc/redis/users.acl

    # Admin şifresini restart'tan ÖNCE kaydet: 'systemctl restart' set -e altında
    # non-zero dönerse (systemd notify timing) parola conf'a yazılmadan kaybolmasın
    # → domain add redis ACL adımı WRONGPASS ile patlıyordu.
    # ANCHOR şart: conf'ta '# REDIS_ADMIN_PASS=' yorum placeholder'ı var. Anchorsuz
    # grep yorumu yakalar → sed '^REDIS_ADMIN_PASS=' ile eşleşmez → no-op → parola
    # hiç yazılmaz → domain add redis ACL WRONGPASS. Yalnız AKTİF atamayı eşle.
    if grep -q "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null; then
        # Çıplak 'sed -i' YERİNE _sed_inplace (bkz. core.sh KARAR 2) — atomik +
        # portable + mod/sahiplik korumalı. Dönüş değeri artık kontrol edilir.
        if ! _sed_inplace "${SRVCTL_CONF}" "s|^REDIS_ADMIN_PASS=.*|REDIS_ADMIN_PASS=${redis_admin_pass}|"; then
            warn "REDIS_ADMIN_PASS srvctl.conf'a yazılamadı (_sed_inplace başarısız)"
            return 1
        fi
        # POST-CONDITION: _sed_inplace başarı dönse bile YANLIŞ satırı
        # değiştirmiş olabilir — yeni parolanın GERÇEKTEN yazıldığını
        # doğrula, yoksa 'domain add' redis ACL adımı WRONGPASS ile patlar
        # (bkz. yukarıdaki ANCHOR yorumu).
        if ! grep -qF "REDIS_ADMIN_PASS=${redis_admin_pass}" "${SRVCTL_CONF}" 2>/dev/null; then
            warn "REDIS_ADMIN_PASS srvctl.conf'a doğru yazılamadı (doğrulama başarısız)"
            return 1
        fi
    else
        echo "REDIS_ADMIN_PASS=${redis_admin_pass}" >> "${SRVCTL_CONF}"
    fi

    systemctl enable redis-server > /dev/null 2>&1
    if ! systemctl restart redis-server; then
        error "Redis başlatılamadı (supervised=${redis_supervised}). Detay: journalctl -xeu redis-server / systemctl status redis-server"
    fi

    info "Redis admin şifresi: ${SRVCTL_CONF}"
}

_install_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        _apt_install_required "fail2ban" fail2ban || return 1
    fi

    # [sshd] jail backend: yetenek tespiti (sürüm karşılaştırması DEĞİL).
    # Ubuntu 24.04'te rsyslog varsayılanda kurulu DEĞİL → /var/log/auth.log
    # olmayabilir → dosya tabanlı 'auto' backend [sshd] jail'ini SESSİZCE
    # başlatamaz ve SSH brute-force koruması fark edilmeden devre dışı kalır
    # (bkz. .claude/ubuntu-compat.md). /var/log/auth.log yoksa journald
    # backend'ine düş (python3-systemd paketi gerektirir).
    local sshd_backend="auto"
    if [[ ! -f /var/log/auth.log ]]; then
        apt-get install -y -qq python3-systemd > /dev/null 2>&1 \
            || warn "python3-systemd kurulamadı — fail2ban [sshd] 'systemd' backend'i başlamayabilir, journalctl -xeu fail2ban ile kontrol edin"
        sshd_backend="systemd"
    fi

    cat > /etc/fail2ban/jail.local << FAIL2BAN
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ${SSH_PORT}
backend = ${sshd_backend}
maxretry = 3
bantime = 86400

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-botsearch]
enabled = true
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2

[nginx-req-limit]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 5
FAIL2BAN

    systemctl enable fail2ban > /dev/null 2>&1
    if ! systemctl restart fail2ban; then
        error "Fail2Ban başlatılamadı (sshd backend=${sshd_backend}). Detay: journalctl -xeu fail2ban / fail2ban-client -x start"
    fi
}

_install_auditd() {
    cat > /etc/audit/rules.d/99-srvctl.rules << 'AUDIT'
# srvctl audit kuralları
-w /var/www/ -p wa -k web_changes
-w /etc/nginx/ -p wa -k nginx_config
-w /etc/php/ -p wa -k php_config
-w /etc/mysql/ -p wa -k mysql_config
-w /etc/redis/ -p wa -k redis_config
-w /etc/sudoers -p wa -k sudoers_change
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
-w /etc/ssh/ -p wa -k ssh_config
-w /usr/local/srvctl/ -p wa -k srvctl_config
AUDIT

    systemctl enable auditd > /dev/null 2>&1
    systemctl restart auditd 2>/dev/null || true
}

_setup_cron_jobs() {
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null || true)

    # SSL yenileme (günde 2 kez)
    if ! echo "$crontab_content" | grep -q "certbot renew"; then
        (echo "$crontab_content"; echo "0 3,15 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx' >> /usr/local/srvctl/logs/ssl.log 2>&1") | crontab -
    fi

    # Günlük yedekleme
    crontab_content=$(crontab -l 2>/dev/null || true)
    if ! echo "$crontab_content" | grep -q "srvctl backup"; then
        (echo "$crontab_content"; echo "0 4 * * * /usr/local/srvctl/bin/srvctl backup run >> /usr/local/srvctl/logs/backup.log 2>&1") | crontab -
    fi

    # Eski release temizliği (deploy prune) — YEDEKTEN SONRA çalışmalı: prune
    # geceki backup'tan ÖNCE tetiklenirse, henüz yedeklenmemiş bir release
    # (rollback hedefi) silinebilir. backup 04:00'te, prune 05:00'te — aradaki
    # bir saat backup'ın (rsync/tar boyuta göre uzun sürebilir) bitmesine
    # yetecek pay bırakır. --apply olmadan srvctl deploy prune varsayılan
    # dry-run olduğundan cron'da AÇIKÇA --apply verilir. --include-bak,
    # DEPLOY_PRUNE_BAK_DAYS eşiğinden eski public_html.bak.* dizinlerini de
    # (zaten gün-bazlı gecikmeli olduğundan güvenli) temizler.
    crontab_content=$(crontab -l 2>/dev/null || true)
    if ! echo "$crontab_content" | grep -q "srvctl deploy prune"; then
        (echo "$crontab_content"; echo "0 5 * * * /usr/local/srvctl/bin/srvctl deploy prune --all --apply --include-bak >> /usr/local/srvctl/logs/deploy-prune.log 2>&1") | crontab -
    fi

    # Tam durum kontrolü + alarmlar (disk/RAM/servis-down+oto-restart/domain
    # HTTP/fail2ban anomali — bkz. lib/monitor.sh _monitor_check). Bu cron
    # eklenmeden 'monitor check' hiçbir zaman tetiklenmiyordu — tüm alarm
    # katmanı fiilen ölü koddu.
    #
    # Aralık: 5 dakika seçildi (15 dakika DEĞİL). Gerekçe:
    #   - _monitor_check servis-down durumunda OTOMATİK 'systemctl restart'
    #     dener; 15 dakikalık bir aralıkta disk/RAM kritik ya da bir servis
    #     down iken bunun fark edilmesi 15 dakikaya kadar gecikebilir — kritik
    #     altyapı için kabul edilemez derecede yavaş.
    #   - 5 dakika, aynı zamanda flapping riskini sınırlar: gerçekten crash-loop
    #     yapan bir servis systemd'nin KENDİ StartLimitBurst/StartLimitInterval
    #     sınırına 5 dakikadan çok daha hızlı çarpar (systemd zaten art arda
    #     başlatmayı durdurur); cron'un 5 dakikada bir 'restart' denemesi bu
    #     sınırın ÜSTÜNE binen ekstra bir flap kaynağı olmaz.
    #   - _monitor_check kilitsiz (lock-free) çalışıyor; 1 dakika gibi çok sık
    #     bir aralık, çok sayıda domain'de curl probe'ları üst üste binen
    #     çalıştırmalar üretebilirdi. 5 dakika bu riski pratikte ortadan kaldırır.
    crontab_content=$(crontab -l 2>/dev/null || true)
    if ! echo "$crontab_content" | grep -q "srvctl monitor check"; then
        (echo "$crontab_content"; echo "*/5 * * * * /usr/local/srvctl/bin/srvctl monitor check >> /usr/local/srvctl/logs/monitor.log 2>&1") | crontab -
    fi

    # ─── Güvenilir edge-IP senkronu (Cloudflare + UptimeRobot) ───
    if [[ "${TRUSTED_SYNC_ENABLED:-true}" == "true" ]]; then
        crontab_content=$(crontab -l 2>/dev/null || true)
        if ! echo "$crontab_content" | grep -q "srvctl trusted sync"; then
            (echo "$crontab_content"; echo "30 2 * * * /usr/local/srvctl/bin/srvctl trusted sync >> /usr/local/srvctl/logs/trusted.log 2>&1") | crontab -
        fi
        # İlk senkron (ağ yoksa uyar-devam; init'i düşürme)
        # shellcheck disable=SC1090
        if source "${SRVCTL_ROOT}/lib/trusted.sh" 2>/dev/null && _trusted_sync >/dev/null 2>&1; then
            success "Güvenilir edge-IP listesi senkronize edildi"
        else
            warn "İlk güvenilir-IP senkronu yapılamadı (ağ?) — cron sonraki turda tazeleyecek"
        fi
    fi
}

_create_deployer_user() {
    if ! id "${DEPLOYER_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${DEPLOYER_USER}"
        mkdir -p "/home/${DEPLOYER_USER}/.ssh"
        chmod 700 "/home/${DEPLOYER_USER}/.ssh"
        chown -R "${DEPLOYER_USER}:${DEPLOYER_USER}" "/home/${DEPLOYER_USER}/.ssh"

        # Sudo izinleri (sadece reload)
        cat > "/etc/sudoers.d/${DEPLOYER_USER}" << SUDOERS
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php*-fpm
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl deploy *
SUDOERS
        chmod 440 "/etc/sudoers.d/${DEPLOYER_USER}"

        info "Deployer kullanıcısı: ${DEPLOYER_USER}"
        warn "SSH key ekleyin: /home/${DEPLOYER_USER}/.ssh/authorized_keys"
    fi
}

# ───────────────────────────────────────────────────────────────
#  cgroups v2 — parent slice + doğrulama
# ───────────────────────────────────────────────────────────────
_setup_cgroups() {
    # cgroups v2, Ubuntu 22.04 VE 24.04'te ortak varsayılandır (fark yok —
    # bkz. .claude/ubuntu-compat.md); bu yüzden sürüm dallanması gerekmez,
    # doğrudan yetenek kontrolü (cgroup.controllers dosyasının varlığı) yeterli.
    if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        warn "cgroups v2 aktif değil — GRUB'a systemd.unified_cgroup_hierarchy=1 ekleyin"
    fi

    # Parent slice (per-domain srvctl-*.slice bunun altına girer)
    cat > /etc/systemd/system/srvctl.slice << 'SLICE'
[Unit]
Description=srvctl domain resource parent slice
Before=slices.target

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes
SLICE

    systemctl daemon-reload 2>/dev/null || true
    systemctl start srvctl.slice 2>/dev/null || true
}

# ───────────────────────────────────────────────────────────────
#  ModSecurity v3 + OWASP Core Rule Set (nginx connector)
# ───────────────────────────────────────────────────────────────
_install_modsecurity() {
    # nginx ModSecurity connector
    apt-get install -y -qq libnginx-mod-http-modsecurity 2>/dev/null \
        || { warn "libnginx-mod-http-modsecurity bulunamadı — ModSecurity atlanıyor"; return 1; }

    # GÜVENLİK (O5 — DALGA 4/5): bu yollar templates/nginx/modsecurity.conf.tpl'te
    # SecTmpDir/SecDataDir/SecUploadDir olarak artık /var/lib/modsecurity/{tmp,
    # data,upload}'ı REFERANS EDİYOR (ops-infra tarafı hazır — bkz. şablon).
    # KÖK NEDEN KAPANDI: eskiden /tmp altındaydı; /tmp 1777 olduğundan bir
    # saldırgan bu script çalışmadan ÖNCE '/tmp/modsecurity' (veya alt
    # dizinlerinden biri) adında bir symlink ya da gevşek izinli bir dizin
    # yerleştirebiliyordu (eski 'mkdir -p' var olan dizinin İZNİNİ DEĞİŞTİRMEZ,
    # chown sahiplik değiştirir MOD değiştirmez → önceden yerleştirilmiş 0777
    # bir dizin SONSUZA KADAR dünya-yazılabilir kalabiliyordu — WAF'ın tuttuğu
    # istek gövdesi/upload verisine çapraz-kiracı erişim + WAF artefaktı
    # manipülasyonu). /var/lib zaten root:root 755 olduğundan (yalnızca root
    # yeni alt dizin/symlink oluşturabilir) BU SALDIRI YÜZEYİ /var/lib/modsecurity
    # için YAPISAL OLARAK KAPALIDIR — ama savunma-derinliği için symlink kontrolü
    # + AÇIK chmod deseni (kalıtılan/önceden ayarlanmış izne asla güvenilmez)
    # yine de korunuyor.
    #
    # GERİYE UYUMLULUK: mevcut kurulumlarda eski '/tmp/modsecurity' kalmış
    # olabilir. TAŞIMAK yerine (içerik zaten /tmp'nin 1777 diğer-yazılabilir/
    # okunabilir doğası altında potansiyel olarak dünya-okunur kalmıştır —
    # istek gövdesi/upload artefaktları oturum/form verisi gibi HASSAS içerik
    # taşıyabilir) İÇERİĞİYLE BİRLİKTE SİLİYORUZ: WAF artefaktları geçici/
    # denetim amaçlı veridir, kalıcı kullanıcı verisi DEĞİLDİR — hiçbir
    # operasyonel değeri olmayan bu veriyi yeni (ve zaten dünya-erişilemez)
    # bir konuma taşımanın riski (kopyalama sırasında ara adım, hatalı izin
    # miras alma ihtimali), faydasından fazladır.
    if [[ -e /tmp/modsecurity || -L /tmp/modsecurity ]]; then
        warn "Eski '/tmp/modsecurity' dizini bulundu (dünya-erişilebilir /tmp altında hassas WAF artefaktları kalmış olabilir) — güvenlik nedeniyle TAŞINMADAN siliniyor, yeni konum: /var/lib/modsecurity"
        rm -rf -- /tmp/modsecurity
    fi

    # Üst dizin: root sahipli, www-data GRUBU yalnızca traverse/list edebilir
    # (YAZAMAZ) — yeni dosya/alt dizin oluşturma yalnızca root'a ait kalır.
    if [[ -L /var/lib/modsecurity ]]; then
        warn "GÜVENLİK: /var/lib/modsecurity sembolik link olarak bulundu (beklenmedik) — link kaldırılıp düz dizin olarak yeniden oluşturuluyor"
        rm -f /var/lib/modsecurity
    fi
    mkdir -p /var/lib/modsecurity
    chown root:www-data /var/lib/modsecurity
    chmod 0750 /var/lib/modsecurity

    # Alt dizinler: ModSecurity (nginx worker'ı olarak www-data) BUNLARA
    # yazar — www-data:www-data sahipliği + 0700 (yalnız sahip erişebilir;
    # grup/diğer tamamen kapalı) hem işlevselliği hem izolasyonu korur.
    local _msdir
    for _msdir in /var/lib/modsecurity/tmp /var/lib/modsecurity/data /var/lib/modsecurity/upload; do
        if [[ -L "$_msdir" ]]; then
            warn "GÜVENLİK: ${_msdir} sembolik link olarak bulundu (olası önceden-yerleştirme saldırısı) — link kaldırılıp düz dizin olarak yeniden oluşturuluyor"
            rm -f "$_msdir"
        fi
        mkdir -p "$_msdir"
        chown www-data:www-data "$_msdir"
        chmod 0700 "$_msdir"
    done
    mkdir -p /etc/nginx/modsec

    # Önerilen temel modsecurity.conf (paketle gelir)
    if [[ -f /etc/modsecurity/modsecurity.conf-recommended ]]; then
        cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
        # Çıplak 'sed -i' YERİNE _sed_inplace (bkz. core.sh KARAR 2).
        if ! _sed_inplace /etc/nginx/modsec/modsecurity.conf 's/^SecRuleEngine .*/SecRuleEngine On/'; then
            warn "ModSecurity enforce moda ALINAMADI (_sed_inplace başarısız) — WAF pasif/DetectionOnly kalmış olabilir"
            return 1
        fi
        # POST-CONDITION: _sed_inplace başarı dönse bile YANLIŞ şeyi
        # değiştirmiş olabilir (beklenmedik dosya formatı vb.) — enforce
        # moda GERÇEKTEN geçildiğini doğrula, yoksa WAF sessizce
        # DetectionOnly/pasif kalır ve init yine de "kuruldu" der.
        if ! grep -q '^SecRuleEngine On' /etc/nginx/modsec/modsecurity.conf 2>/dev/null; then
            warn "ModSecurity enforce moda ALINAMADI (SecRuleEngine On doğrulanamadı) — WAF pasif/DetectionOnly kalmış olabilir"
            return 1
        fi
    else
        warn "modsecurity.conf-recommended bulunamadı (modsecurity-crs paketi eksik olabilir) — temel ModSecurity yapılandırması ATLANDI"
        return 1
    fi

    # unicode.mapping
    [[ -f /usr/share/modsecurity-crs/unicode.mapping ]] && \
        cp /usr/share/modsecurity-crs/unicode.mapping /etc/nginx/modsec/ 2>/dev/null || true

    # OWASP CRS indir
    if [[ ! -d /etc/nginx/owasp-crs ]]; then
        if ! git clone --depth 1 https://github.com/coreruleset/coreruleset /etc/nginx/owasp-crs 2>/dev/null; then
            warn "OWASP CRS indirilemedi (git/erişim) — ModSecurity kural seti eksik kalacak"
            return 1
        fi
    fi
    [[ -f /etc/nginx/owasp-crs/crs-setup.conf.example ]] && \
        cp -n /etc/nginx/owasp-crs/crs-setup.conf.example /etc/nginx/owasp-crs/crs-setup.conf 2>/dev/null || true

    # srvctl ana WAF yapılandırması (template'ten)
    if [[ -f "${SRVCTL_TEMPLATES}/nginx/modsecurity.conf.tpl" ]]; then
        cp "${SRVCTL_TEMPLATES}/nginx/modsecurity.conf.tpl" /etc/nginx/modsec/main.conf
    else
        cat > /etc/nginx/modsec/main.conf << 'MODSEC'
Include /etc/nginx/modsec/modsecurity.conf
Include /etc/nginx/owasp-crs/crs-setup.conf
Include /etc/nginx/owasp-crs/rules/*.conf
MODSEC
    fi

    # nginx.conf http bloğuna modsecurity aç (idempotent)
    if ! grep -q "modsecurity on" /etc/nginx/nginx.conf 2>/dev/null; then
        # Çıplak 'sed -i' YERİNE _sed_inplace (bkz. core.sh KARAR 2).
        if ! _sed_inplace /etc/nginx/nginx.conf \
            '/include \/etc\/nginx\/sites-enabled/i\    modsecurity on;\n    modsecurity_rules_file /etc/nginx/modsec/main.conf;'; then
            warn "'modsecurity on;' nginx.conf'a eklenemedi (_sed_inplace başarısız) — WAF devrede DEĞİL"
            return 1
        fi
        # POST-CONDITION: sed hedef deseni bulamazsa (ör. nginx.conf elle
        # değiştirilmiş) no-op olur — 'modsecurity on;' hiç eklenmemiş olabilir.
        if ! grep -q "modsecurity on" /etc/nginx/nginx.conf 2>/dev/null; then
            warn "'modsecurity on;' nginx.conf'a eklenemedi — WAF devrede DEĞİL"
            return 1
        fi
    fi

    # load_module satırı (mod paketleri genelde /etc/nginx/modules-enabled altına ekler)
    if nginx -t 2>/dev/null; then
        if ! systemctl reload nginx 2>/dev/null; then
            warn "ModSecurity yapılandırıldı ama nginx reload başarısız — devreye alınmamış olabilir"
            return 1
        fi
    else
        warn "ModSecurity sonrası nginx -t başarısız — /etc/nginx/modsec/ kontrol edin, WAF devrede DEĞİL"
        return 1
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────
#  AIDE — Dosya bütünlük kontrolü
# ───────────────────────────────────────────────────────────────
_install_aide() {
    if ! command -v aide &>/dev/null; then
        apt-get install -y -qq aide aide-common 2>/dev/null \
            || { warn "AIDE kurulamadı — atlanıyor"; return 1; }
    fi

    # İlk veritabanını arka planda oluştur (uzun sürebilir). NOT: arka plan
    # işi (aideinit/aide --init) doğası gereği ASENKRON — bu fonksiyon
    # içinden senkron olarak doğrulanamaz, dolayısıyla bu adımın
    # başarı/başarısızlığı SADECE senkron kontrol edilebilen kısımlara
    # (paket kurulumu, cron yazımı) dayanır.
    if [[ ! -f /var/lib/aide/aide.db.gz && ! -f /var/lib/aide/aide.db ]]; then
        info "AIDE veritabanı oluşturuluyor (arka planda)..."
        ( aideinit -y -f 2>/dev/null || aide --init 2>/dev/null
          [[ -f /var/lib/aide/aide.db.new.gz ]] && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
        ) &
    fi

    # Günlük bütünlük kontrolü cron'u
    local cron; cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$cron" | grep -q "aide --check"; then
        if ! (echo "$cron"; echo "30 5 * * * aide --check >> /usr/local/srvctl/logs/aide.log 2>&1") | crontab -; then
            warn "AIDE günlük kontrol cron'u eklenemedi"
            return 1
        fi
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────
#  ClamAV — Antivirüs (upload taraması)
# ───────────────────────────────────────────────────────────────
_install_clamav() {
    if ! command -v clamscan &>/dev/null; then
        apt-get install -y -qq clamav clamav-daemon 2>/dev/null \
            || { warn "ClamAV kurulamadı — atlanıyor"; return 1; }
    fi

    # İmza veritabanını güncelle. NOT: freshclam'ın kendisi başarısız olursa
    # (ör. geçici ağ hatası) bunu FATAL saymıyoruz — clamav-freshclam servisi
    # kendi zamanlayıcısıyla periyodik olarak tekrar dener; bu, composer/SSH/
    # ModSecurity gibi "bir daha ASLA denenmeyen" kalıcı bir degrade değil.
    systemctl stop clamav-freshclam 2>/dev/null || true
    freshclam 2>/dev/null || warn "freshclam güncellemesi başarısız (clamav-freshclam servisi periyodik olarak tekrar deneyecek)"
    systemctl start clamav-freshclam 2>/dev/null || true
    systemctl enable clamav-daemon 2>/dev/null || true
    if ! systemctl start clamav-daemon 2>/dev/null; then
        warn "clamav-daemon başlatılamadı — upload taraması devre dışı kalabilir"
        return 1
    fi

    # Günlük upload tarama cron'u (tüm domain uploads dizinleri)
    local cron; cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$cron" | grep -q "clamscan"; then
        if ! (echo "$cron"; echo "0 6 * * * clamscan -ri --quiet ${WEB_ROOT} >> /usr/local/srvctl/logs/clamav.log 2>&1") | crontab -; then
            warn "ClamAV günlük tarama cron'u eklenemedi"
            return 1
        fi
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────
#  GeoIP — Ülke bazlı engelleme veritabanı (ip.sh geoblock için)
# ───────────────────────────────────────────────────────────────
_install_geoip() {
    apt-get install -y -qq libnginx-mod-http-geoip geoip-database geoip-bin 2>/dev/null \
        || { warn "GeoIP paketleri bulunamadı — geoblock kısıtlı çalışır"; return 1; }

    if [[ ! -f /usr/share/GeoIP/GeoIP.dat ]]; then
        warn "GeoIP veritabanı (GeoIP.dat) bulunamadı — geoip_country eklenmedi, geoblock çalışmayacak"
        return 1
    fi

    # nginx http bloğuna GeoIP veritabanı yolu (idempotent)
    if ! grep -q "geoip_country" /etc/nginx/nginx.conf 2>/dev/null; then
        # Çıplak 'sed -i' YERİNE _sed_inplace (bkz. core.sh KARAR 2).
        if ! _sed_inplace /etc/nginx/nginx.conf \
            '/include \/etc\/nginx\/sites-enabled/i\    geoip_country /usr/share/GeoIP/GeoIP.dat;'; then
            warn "geoip_country yönergesi nginx.conf'a eklenemedi (_sed_inplace başarısız) — geoblock çalışmayacak"
            return 1
        fi
        # POST-CONDITION: sed no-op olabilir — yönergenin GERÇEKTEN eklendiğini
        # doğrula, yoksa geoblock sessizce çalışmayan bir katman olarak kalır.
        if ! grep -q "geoip_country" /etc/nginx/nginx.conf 2>/dev/null; then
            warn "geoip_country yönergesi nginx.conf'a eklenemedi — geoblock çalışmayacak"
            return 1
        fi
    fi

    if nginx -t 2>/dev/null; then
        if ! systemctl reload nginx 2>/dev/null; then
            warn "GeoIP yapılandırıldı ama nginx reload başarısız — devreye alınmamış olabilir"
            return 1
        fi
    else
        warn "GeoIP sonrası nginx -t başarısız — /etc/nginx/nginx.conf kontrol edin"
        return 1
    fi
    return 0
}
