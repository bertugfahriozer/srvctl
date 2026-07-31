#!/bin/bash
# FPM izolasyon durumu audit'i — koordinatör bulgusu + takip bulgusu.
#
# BULGU 1: 'security audit' bir domainin PAYLAŞILAN php-fpm havuzunda mı
# yoksa izole unit'te (srvctl-fpm-<sname>.service) mi çalıştığını hiç
# kontrol etmiyordu. AppArmorProfile=/SystemCallFilter=/NoNewPrivileges=
# YALNIZ per-domain unit'te tanımlıdır — paylaşılan havuza düşen bir domain
# MAC/seccomp/NNP katmanının TAMAMINI SESSİZCE kaybeder (Chankro zincirinin
# 'exec deny'i buna dayanır: disable_functions CLI'da uygulanmaz).
#
# BULGU 2 (takip — bu turda kapatıldı): İLK sürüm yalnız GLOBAL
# DOMAIN_ISOLATED_FPM'e bakıyordu; bir domain kendi '.srvctl-meta'sında
# BİLİNÇLİ olarak ISOLATED_FPM=false taşısa bile (global true iken) bu
# kontrol onu FAIL ediyordu — "bilinçli tercihi sessiz sapmadan ayır"
# ilkesinin bir seviye aşağıda İHLALİYDİ. Koordinatör gerçek VM'de
# doğruladı: '.srvctl-meta' root:root 644 — domain'in KENDİ web kullanıcısı
# YAZAMAZ (Permission denied), yani bu okumaya güvenmek GÜVENLİDİR.
# _check_fpm_isolation artık lib/domain.sh:_domain_isolated_fpm_effective'i
# (guard'lı source — _security_load_domain_lib, bu dosyada ZATEN kurulu
# konvansiyon) kullanarak EFEKTİF değeri (meta override > global) okur.
#
# Bu dosya _check_fpm_isolation'ın wiring'ini SRVCTL_FPM_DIR/
# SRVCTL_SYSTEMD_DIR test-seam'leriyle + 'systemctl' stub'ıyla doğrular.
# Saf karar mantığı (_audit_fpm_isolation_verdict) tests/test_audit_parsers.sh'ta
# fixture'la ayrıca doğrulanmıştır.
#
# SIRALAMA ÖNEMLİ: 'lib/domain.sh' BİLEREK GEÇ (BÖLÜM B'den önce) source
# edilir. _security_load_domain_lib'in erken-dönüş kontrolü ('declare -F
# _domain_fs_plan') sourcing'i BİR KEZ yapıp process boyunca kalıcı kılar —
# bu yüzden BÖLÜM A (domain.sh HENÜZ YOK) ile BÖLÜM B (domain.sh YÜKLÜ)
# senaryolarını AYNI process'te, yalnız SIRAYA dikkat ederek test
# edebiliyoruz (ayrı alt-process'e gerek yok). BÖLÜM A ayrıca gerçek
# ortamı yansıtır: SRVCTL_ROOT core.sh'ta '/usr/local/srvctl'e SABİTTİR
# (test-seam YOK) — bu geliştirme makinesinde o yol yoktur, yani
# _security_load_domain_lib domain.sh'ı BİZ EXPLICIT source etmeden asla
# kendiliğinden bulamaz.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

SNAME="example_com"
DOMAIN="example.com"
mkdir -p "${WEB_ROOT}/${DOMAIN}"

pass_n=0; fail_n=0; warn_n=0
_t_pass() { pass_n=$((pass_n + 1)); }
_t_fail() { fail_n=$((fail_n + 1)); }
_t_warn() { warn_n=$((warn_n + 1)); }

systemctl() { return 1; }   # varsayılan: hiçbir unit aktif değil

# ═══════════════════════════════════════════════════════════════
#  BÖLÜM A — domain.sh HENÜZ source EDİLMEDİ (bu makinede zaten olduğu
#  gibi: SRVCTL_ROOT gerçek yol, mevcut değil).
# ═══════════════════════════════════════════════════════════════

# (a) İZOLE + AKTİF → PASS. Bu dal isolated_setting'e HİÇ BAKMAZ (kısa
#     devre — bkz. _check_fpm_isolation yorumu), bu yüzden domain.sh
#     yüklü OLMASA BİLE çalışır.
: > "${SRVCTL_FPM_DIR}/${SNAME}.conf"
systemctl() { [[ "$1" == "is-active" && "$3" == "srvctl-fpm-${SNAME}.service" ]] && return 0; return 1; }
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "1 0 0" \
    "config VAR + unit AKTİF → PASS (gerçek izolasyon mevcut, domain.sh'a bağımlı DEĞİL)"
rm -f "${SRVCTL_FPM_DIR}/${SNAME}.conf"

# (b) PAYLAŞILAN HAVUZ + domain.sh YÜKLENEMEDİ (bu makinenin GERÇEK hâli —
#     _security_load_domain_lib '/usr/local/srvctl/lib/domain.sh' arar,
#     burada YOK) → WARN ("kanıt yok"), FAIL DEĞİL. Bu, attr-okunamadı
#     yarış durumundaki AYNI fail-closed/kanıt ayrımının FPM izolasyon
#     tarafındaki karşılığıdır.
systemctl() { return 1; }
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 1" \
    "paylaşılan havuzda + domain.sh yüklenemedi → WARN (kanıt yok — SESSİZCE FAIL'e YÜKSELTİLMEZ)"

# ═══════════════════════════════════════════════════════════════
#  BÖLÜM B — 'lib/domain.sh' ARTIK source EDİLİYOR (_domain_isolated_fpm_
#  effective + _domain_fs_plan vb. process boyunca kalıcı tanımlı olacak;
#  _security_load_domain_lib bundan sonra HER ÇAĞRIDA erken-dönüşle 0
#  döner — gerçek '/usr/local/srvctl' yoluna hiç bakmaz).
# ═══════════════════════════════════════════════════════════════
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_isolated_fpm_effective >/dev/null 2>&1; then
    echo "  SKIP: _domain_isolated_fpm_effective henüz yok (lib/domain.sh paralel değişiyor olabilir) — BÖLÜM B atlandı"
    rm -rf "$WEB_ROOT" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR"
    test_summary
    exit 0
fi

# (c) PAYLAŞILAN HAVUZ + meta YOK + global DOMAIN_ISOLATED_FPM=true
#     (varsayılan) → FAIL (SESSİZ SAPMA — asıl hedef, koordinatörün AÇIKÇA
#     istediği "meta yok + global true + paylaşılan → FAIL" senaryosu).
DOMAIN_ISOLATED_FPM="true"
systemctl() { return 1; }
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 1 0" \
    "meta YOK + global DOMAIN_ISOLATED_FPM=true + paylaşılan → FAIL (sessiz sapma, domain.sh yüklü olunca artık GÜVENİLİR biçimde ayırt edilebiliyor)"

# (d) PAYLAŞILAN HAVUZ + meta YOK + global DOMAIN_ISOLATED_FPM=false
#     (operatör GLOBAL olarak AÇIKÇA ayarlamış) → WARN.
DOMAIN_ISOLATED_FPM="false"
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 1" \
    "meta YOK + global DOMAIN_ISOLATED_FPM=false (AÇIKÇA) + paylaşılan → WARN (bilinçli GLOBAL tercih)"
DOMAIN_ISOLATED_FPM="true"

# (e) — KOORDİNATÖRÜN AÇIKÇA İSTEDİĞİ SENARYO: PAYLAŞILAN HAVUZ + bu
#     domain'in KENDİ '.srvctl-meta'sında ISOLATED_FPM=false (BİLİNÇLİ
#     per-domain tercih) + global true → WARN, FAIL DEĞİL. Düzeltmeden
#     ÖNCE bu senaryo YANLIŞLIKLA FAIL üretiyordu (global'e sessizce
#     düşülüyordu, per-domain override GÖRMEZDEN GELİNİYORDU).
write_meta "$DOMAIN" ISOLATED_FPM false
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 1" \
    "[TAKİP BULGUSU] meta ISOLATED_FPM=false (per-domain BİLİNÇLİ tercih) + global true + paylaşılan → WARN (FAIL DEĞİL)"

# (f) simetrik doğrulama: meta ISOLATED_FPM=true (domain KENDİSİ izolasyon
#     İSTİYOR) + global false + paylaşılan → FAIL. Per-domain override
#     global'i EZER — burada da ezip GERÇEK bir sapmayı ortaya çıkarmalı
#     (global gevşek olsa bile bu domain açıkça izolasyon BEKLİYOR).
write_meta "$DOMAIN" ISOLATED_FPM true
DOMAIN_ISOLATED_FPM="false"
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 1 0" \
    "meta ISOLATED_FPM=true (per-domain BİLİNÇLİ tercih) + global false + paylaşılan → FAIL (override GLOBAL'i EZER, sessiz sapma gizlenmez)"
DOMAIN_ISOLATED_FPM="true"

# (g) yarı-izolasyon: config VAR ama unit AKTİF DEĞİL (ör. servis çökmüş/
#     durdurulmuş) → PASS SAYILMAZ; meta override (false) yine de WARN'a
#     düşürür (gerçek MAC attach YOK ama bu YİNE bilinçli bir tercih).
: > "${SRVCTL_FPM_DIR}/${SNAME}.conf"
systemctl() { return 1; }   # unit aktif değil (config olsa bile)
write_meta "$DOMAIN" ISOLATED_FPM false
pass_n=0; fail_n=0; warn_n=0
_check_fpm_isolation _t_pass _t_fail _t_warn "$DOMAIN" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 1" \
    "yarı-izolasyon (config var, unit aktif değil) + meta ISOLATED_FPM=false → PASS SAYILMAZ, WARN (bilinçli tercih hâlâ geçerli)"
rm -f "${SRVCTL_FPM_DIR}/${SNAME}.conf"

rm -rf "$WEB_ROOT" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR"
test_summary
