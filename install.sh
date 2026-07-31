#!/bin/bash
# ═══════════════════════════════════════════════
#  srvctl — Kurulum Script'i
#  Ubuntu 22.04 / 24.04 LTS üzerinde srvctl'yi kurar
#
#  Kullanım: sudo bash install.sh
# ═══════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/usr/local/srvctl"

# ─── Root kontrolü ───
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗${NC}  Bu script root olarak çalıştırılmalıdır."
    echo "  Kullanım: sudo bash install.sh"
    exit 1
fi

# ─── Etkileşimsiz mod ───
# HOST BULGUSU (Ubuntu 24.04, gerçek VM): install.sh mevcut bir kurulumun
# üzerine çalıştırıldığında "Üzerine yazmak istiyor musunuz?" diye SORUYORDU.
# CLAUDE.md'nin kendi talimatı "değişiklikler için 'sudo bash install.sh'
# yeniden çalıştırılır" — yani bu RUTİN bir işlem. stdin olmayan her ortamda
# (CI, Ansible, cron, 'srvctl self-update' sonrası, arka plan) kurulum
# SÜRESİZ ASILI KALIYORDU; VM testinde üst üste üç kez gözlemlendi.
#
# Kural: TTY varsa davranış aynı (soru sorulur). TTY yoksa ya da '--yes'
# verilmişse soru sorulmaz — ama varsayılanlar YÖNE GÖRE ayrılır:
#   • "üzerine yaz"  → EVET  (kurulumun asıl amacı; conf zaten korunuyor)
#   • "desteklenmeyen OS'ta devam" → HAYIR (fail-closed; bilinmeyen bir
#     dağıtıma sessizce kurulum yapmak güvenlik açısından yanlış olur)
ASSUME_YES=false
for _arg in "$@"; do
    case "$_arg" in
        --yes|-y) ASSUME_YES=true ;;
    esac
done
[[ -t 0 ]] || ASSUME_YES=true   # stdin bir terminale bağlı değil

# Onay sorusu (PREDİKAT: 0=devam, 1=iptal). $2 = etkileşimsiz varsayılan.
_ask() {
    local prompt="$1" noninteractive_default="$2" answer
    if $ASSUME_YES; then
        [[ "$noninteractive_default" == "evet" ]] && return 0 || return 1
    fi
    read -rp "  ${prompt} (evet/hayır): " answer
    [[ "$answer" == "evet" ]]
}

# ─── OS kontrolü ───
# Desteklenen sürümler: 22.04 (jammy) ve 24.04 (noble) — bkz. .claude/ubuntu-compat.md.
# NOT: bu KAPI, "hangi Ubuntu LTS'yiz" sorusuna cevap verdiğinden doğası gereği
# bir sürüm karşılaştırmasıdır (yetenek tespitiyle ikame edilemez); asıl kural
# olan "yetenek tespiti > sürüm karşılaştırması" srvctl'nin RUNTIME modüllerine
# (paket adları, config yönergeleri vb.) uygulanır — bkz. lib/core.sh
# _os_version_id()/_os_is_supported_ubuntu(). install.sh henüz /usr/local/srvctl
# altına HİÇBİR ŞEY kurulmamışken çalıştığından core.sh'ı source EDEMEZ; bu
# yüzden burada AYNI ayrıştırma mantığının küçük, kendi kendine yeten bir
# kopyasını tutar (tek satırlık grep+cut — modüllere dağılmış bir parser
# DEĞİL, tek seferlik bootstrap istisnası).
#
# Davranış: 22.04/24.04 sessizce geçer. Başka bir Ubuntu sürümü (ör. 20.04,
# 25.04) FAIL-CLOSED değil UYARI-TABANLI ele alınır — kullanıcı 'evet' derse
# devam eder (kilitlenmez, sadece bilgilendirilir). Ubuntu olmayan dağıtımlarda
# mevcut davranış (uyarı + onay) korunur.
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        echo -e "${YELLOW}⚠${NC}  Bu script Ubuntu için tasarlanmıştır. (Tespit: ${ID:-bilinmiyor})"
        _ask "Devam etmek istiyor musunuz?" "hayir" || exit 0
    else
        case "${VERSION_ID:-}" in
            22.04|24.04)
                : # desteklenen LTS — sessizce devam
                ;;
            *)
                echo -e "${YELLOW}⚠${NC}  srvctl Ubuntu 22.04 / 24.04 LTS üzerinde test edilmiştir. (Tespit: Ubuntu ${VERSION_ID:-bilinmiyor})"
                _ask "Desteklenmeyen sürümde devam etmek istiyor musunuz?" "hayir" || exit 0
                ;;
        esac
    fi
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  srvctl — Kurulum${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

# ─── Kaynak dizini tespit et ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Eski kurulumu kontrol et ───
if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "${YELLOW}⚠${NC}  Mevcut kurulum tespit edildi: ${INSTALL_DIR}"
    if ! _ask "Üzerine yazmak istiyor musunuz?" "evet"; then
        echo "  Kurulum iptal edildi."
        exit 0
    fi
    # Mevcut conf dosyasını koru
    # GÜVENLİK: yedek KESİNLİKLE /tmp altına yazılmaz. /tmp 1777'dir — web_*
    # dahil herhangi bir yerel kullanıcı bu script çalışmadan ÖNCE
    # '/tmp/srvctl.conf.bak' adında bir symlink yerleştirebilir:
    #   1) Sızıntı: symlink hedefi saldırganın kendi dosyası olursa, aşağıdaki
    #      cp REDIS_ADMIN_PASS/CF_API_TOKEN içeren srvctl.conf'u oraya yazar.
    #   2) Root RCE: temiz kurulumda (INSTALL_DIR/conf/srvctl.conf yok) bu blok
    #      hiç çalışmaz ama restore adımı '/tmp/srvctl.conf.bak' varsa onu
    #      OKUR — saldırgan önceden kendi içeriğini oraya koyduysa, bu dosya
    #      load_config() tarafından 'source' edilen srvctl.conf'un yerine geçer
    #      → sonraki her 'srvctl' çağrısında root olarak keyfi kod.
    # Bunun yerine yedek INSTALL_DIR İÇİNDE tutulur: INSTALL_DIR mkdir'in
    # varsayılan umask'ı ve (tamamlanmış önceki kurulumlarda) açık 'chmod 700'
    # sayesinde diğer yerel kullanıcılar tarafından YAZILAMAZ — /tmp'nin
    # aksine burada symlink önceden yerleştirme saldırısı mümkün değildir.
    BACKUP_CONF="${INSTALL_DIR}/conf/srvctl.conf.bak"
    if [[ -f "${INSTALL_DIR}/conf/srvctl.conf" ]]; then
        # Yarım kalmış önceki bir kurulumdan gevşek izin kalmış olabilir —
        # yedeği yazmadan ÖNCE sahiplik/izni tazele (defans-in-depth).
        chown root:root "${INSTALL_DIR}" 2>/dev/null || true
        chmod 700 "${INSTALL_DIR}" 2>/dev/null || true
        # Hedef önceden bir symlink olarak bırakılmışsa (kuram dışı ama ucuz
        # bir kontrol) izlemeden kaldır; 'rm -f' link'in KENDİSİNİ siler,
        # hedefi DEĞİL.
        [[ -L "$BACKUP_CONF" ]] && rm -f "$BACKUP_CONF"
        install -m 600 -o root -g root "${INSTALL_DIR}/conf/srvctl.conf" "$BACKUP_CONF"
        echo -e "${GREEN}✓${NC}  Mevcut yapılandırma yedeklendi: ${BACKUP_CONF}"
    fi
fi

# ─── 1. Dizin yapısı ───
# NOT: 'seccomp' alt dizini bilerek YOK — templates/seccomp/php-fpm.json
# kaldırıldı (hiçbir kod okumuyordu; OCI/Docker seccomp JSON şemasındaydı,
# systemd 'SystemCallFilter=' ise düz syscall listesi bekler — format zaten
# yanlıştı; gerçek seccomp sertleştirmesi lib/domain.sh:_apply_seccomp_hardening
# tarafından doğrudan üretiliyor, hiçbir template dosyası OKUMUYOR). Boş bir
# 'seccomp' dizini oluşturup kopya döngüsünde no-op bırakmanın hiçbir
# operasyonel faydası yok — ölü referans tamamen temizlendi.
echo -e "  ${CYAN}[1/5]${NC} Dizin yapısı oluşturuluyor..."
mkdir -p "${INSTALL_DIR}"/{bin,lib,templates,conf,logs,completions}
mkdir -p "${INSTALL_DIR}/templates"/{nginx,php-fpm,apparmor,logrotate,systemd,cgroups}

# ─── 2. Dosyaları kopyala ───
echo -e "  ${CYAN}[2/5]${NC} Dosyalar kopyalanıyor..."

# bin/
cp "${SCRIPT_DIR}/bin/srvctl" "${INSTALL_DIR}/bin/srvctl"
chmod +x "${INSTALL_DIR}/bin/srvctl"

# lib/
for lib_file in "${SCRIPT_DIR}"/lib/*.sh; do
    [[ -f "$lib_file" ]] && cp "$lib_file" "${INSTALL_DIR}/lib/"
done
chmod +x "${INSTALL_DIR}"/lib/*.sh

# templates/ (seccomp KASITLI OLARAK yok — bkz. yukarıdaki [1/5] yorumu)
for tpl_dir in nginx php-fpm apparmor logrotate systemd cgroups; do
    if [[ -d "${SCRIPT_DIR}/templates/${tpl_dir}" ]]; then
        cp "${SCRIPT_DIR}/templates/${tpl_dir}/"* "${INSTALL_DIR}/templates/${tpl_dir}/" 2>/dev/null || true
    fi
done

# conf/ (mevcut conf varsa koruyarak) — bkz. yukarıdaki BACKUP_CONF yorumu:
# yedek artık '/tmp' altında DEĞİL, INSTALL_DIR içinde (root-only).
BACKUP_CONF="${BACKUP_CONF:-${INSTALL_DIR}/conf/srvctl.conf.bak}"
if [[ -f "$BACKUP_CONF" ]]; then
    # Kaynağın gerçekten root sahipli, düz bir dosya olduğunu doğrula.
    # load_config() bu hedefi 'source' EDER — symlink ya da başka bir
    # kullanıcıya ait bir dosyayı sorgusuz sualsiz kopyalamak, aradaki adımda
    # (INSTALL_DIR zaten root-only olduğundan pratikte imkânsız olsa da)
    # root olarak keyfi kod çalıştırma yolunu FAIL-CLOSED kapatır.
    _backup_owner=""
    if [[ ! -L "$BACKUP_CONF" ]]; then
        _backup_owner="$(stat -c%U "$BACKUP_CONF" 2>/dev/null || stat -f%Su "$BACKUP_CONF" 2>/dev/null || true)"
    fi
    if [[ -L "$BACKUP_CONF" || "$_backup_owner" != "root" ]]; then
        echo -e "${RED}✗${NC}  GÜVENLİK: ${BACKUP_CONF} root sahipli düz bir dosya değil — RESTORE EDİLMEDİ, varsayılan yapılandırma kurulacak."
        rm -f "$BACKUP_CONF"
        cp "${SCRIPT_DIR}/conf/srvctl.conf" "${INSTALL_DIR}/conf/srvctl.conf"
    else
        install -m 600 -o root -g root "$BACKUP_CONF" "${INSTALL_DIR}/conf/srvctl.conf"
        rm -f "$BACKUP_CONF"
        echo -e "${GREEN}✓${NC}  Mevcut yapılandırma korundu"
    fi
    unset _backup_owner
elif [[ ! -f "${INSTALL_DIR}/conf/srvctl.conf" ]]; then
    cp "${SCRIPT_DIR}/conf/srvctl.conf" "${INSTALL_DIR}/conf/srvctl.conf"
fi

# rate-profiles.conf VERİ dosyasıdır (kullanıcı config'i değil) — her kurulumda güncellenir.
cp "${SCRIPT_DIR}/conf/rate-profiles.conf" "${INSTALL_DIR}/conf/rate-profiles.conf" 2>/dev/null || true
# resource-profiles.conf da VERİ dosyasıdır (micro/standard/ecommerce/heavy
# kaynak profilleri; MemoryHigh/Max/SwapMax ve pm.* değerleri buradan TÜRETİLİR).
# Kopyalanmazsa lib/core.sh:resource_profile_load dahili 'standard' güvenlik
# ağına düşer ve operatörün profil seçimi sessizce yok sayılır.
cp "${SCRIPT_DIR}/conf/resource-profiles.conf" "${INSTALL_DIR}/conf/resource-profiles.conf" 2>/dev/null || true

# completions/ — daha önce hiç kopyalanmıyordu: lib/selfupdate.sh güncellemede
# "${SRVCTL_ROOT}/completions/"e kopyalamayı DENİYOR ama dizin hiç kurulumda
# oluşmadığından '|| true' bunu sessizce yutuyor ve completion HİÇ kurulmuyordu.
if [[ -d "${SCRIPT_DIR}/completions" ]]; then
    cp "${SCRIPT_DIR}/completions/"* "${INSTALL_DIR}/completions/" 2>/dev/null || true
fi
# Sistem geneli shell completion — best-effort, idempotent (cp -f), hedef
# dizin yoksa (ör. zsh kurulu değil / minimal imaj) sessizce atlanır.
if [[ -d /etc/bash_completion.d ]]; then
    cp -f "${SCRIPT_DIR}/completions/srvctl.bash" /etc/bash_completion.d/srvctl 2>/dev/null || true
fi
if [[ -d /usr/share/zsh/vendor-completions ]]; then
    cp -f "${SCRIPT_DIR}/completions/srvctl.zsh" /usr/share/zsh/vendor-completions/_srvctl 2>/dev/null || true
fi

# ─── 3. Symlink ───
echo -e "  ${CYAN}[3/5]${NC} PATH'e ekleniyor..."
ln -sf "${INSTALL_DIR}/bin/srvctl" /usr/local/bin/srvctl

# ─── 4. İzinler ───
echo -e "  ${CYAN}[4/5]${NC} İzinler ayarlanıyor..."
chmod 700 "${INSTALL_DIR}"
chmod 600 "${INSTALL_DIR}/conf/srvctl.conf"
chmod 750 "${INSTALL_DIR}/bin" "${INSTALL_DIR}/lib"
chown -R root:root "${INSTALL_DIR}"

# ─── 5. Log dizini ───
echo -e "  ${CYAN}[5/5]${NC} Log dizini hazırlanıyor..."
mkdir -p "${INSTALL_DIR}/logs"
touch "${INSTALL_DIR}/logs/srvctl.log"
chmod 640 "${INSTALL_DIR}/logs/srvctl.log"

# ─── Doğrulama ───
echo ""
if command -v srvctl &>/dev/null; then
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ srvctl başarıyla kuruldu!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo ""
    echo "  Versiyon:  $(srvctl version 2>/dev/null || echo 'bilinmiyor')"
    echo "  Konum:     ${INSTALL_DIR}"
    echo "  Komut:     srvctl"
    echo ""
    echo "  Yapılandırma:"
    echo "    ${INSTALL_DIR}/conf/srvctl.conf"
    echo ""
    echo -e "  ${BOLD}Sonraki adımlar:${NC}"
    echo ""
    echo "    1. Yapılandırmayı düzenleyin:"
    echo "       nano ${INSTALL_DIR}/conf/srvctl.conf"
    echo ""
    echo "    2. SSH key'inizi ayarlayın (PasswordAuth kapatılacak!):"
    echo "       ssh-copy-id -p 2222 user@server"
    echo ""
    echo "    3. Sunucuyu hazırlayın:"
    echo "       sudo srvctl init"
    echo ""
    echo "    4. İlk domain'i ekleyin:"
    echo "       sudo srvctl domain add example.com"
    echo ""
else
    echo -e "${RED}✗${NC}  Kurulum başarısız olmuş olabilir."
    echo "  Kontrol edin: ls -la ${INSTALL_DIR}/bin/srvctl"
    exit 1
fi
