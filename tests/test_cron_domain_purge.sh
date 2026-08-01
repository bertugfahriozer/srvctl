#!/bin/bash
# _domain_purge_resources — domain cron temizlik kancası (srvctl cron add
# <domain> ...).
#
# GEREKÇE: worker/scheduler İLE AYNI sınıf regresyon (bkz.
# tests/test_domain_purge_worker_state.sh başlık yorumu, H2 denetimi) —
# 'srvctl cron add <domain> ...' ile eklenmiş bir cron, 'domain remove'
# sonrası öksüz kalmamalı: artık var olmayan 'User=web_<sname>' ile her
# tetiklemede journal spam'i üretmemeli, unit/drop-in/fail-service/sidecar
# dosyaları diskte KALMAMALI. Bu görev tanımının AÇIKÇA istediği kancadır
# ("lib/domain.sh ŞU AN SERBEST — oraya temizlik kancasını sen ekle").
#
# Sistem geneli cron'lar ('srvctl-syscron-*') bu domain'e ÖZGÜ OLMADIĞINDAN
# 'domain remove' onlara ASLA dokunmamalı — bu, testin en kritik NEGATİF
# assertion'ıdır (kancanın AŞIRI GENİŞ bir glob kullanmadığının kanıtı).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

# ── Yan etkili komutlar stub'lanır: gerçek servise ASLA dokunulmaz ──
mysql()      { return 0; }
certbot()    { return 0; }
nginx()      { return 0; }
aa-disable() { return 0; }
userdel()    { return 0; }
groupdel()   { return 0; }

systemctl_log="${WEB_ROOT}/.systemctl.log"
: > "$systemctl_log"
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    return 0
}

source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_purge_resources >/dev/null 2>&1; then
    echo "  SKIP: _domain_purge_resources henüz yok"
    rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_STATE_DIR"
    test_summary
    exit 0
fi

ex() { [[ -e "$1" ]] && echo var || echo yok; }

d="purgecron.com"
sname=$(safe_name "$d")

# ═══ Fixture: domain cron (service + timer + OnFailure drop-in + fail-service) ═══
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.service"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.timer"
mkdir -p "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.service.d"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.service.d/override.conf"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cronfail-${sname}-backup_job.service"

# ═══ Fixture: İKİNCİ bir domain cron'u (aynı domain, farklı isim) — glob
# TÜM domain cron'larını yakalamalı, yalnız ilkini DEĞİL. ═══
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.service"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.timer"

# ═══ Fixture: sidecar (ham girdi) dosyası ═══
mkdir -p "${SRVCTL_STATE_DIR}/_cron/${sname}"
: > "${SRVCTL_STATE_DIR}/_cron/${sname}/backup_job.conf"

# ═══ Fixture: BAŞKA bir domain'in cron'u — dokunulmamalı (izolasyon) ═══
other_sname="othersite_com"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${other_sname}-keep_me.service"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${other_sname}-keep_me.timer"
mkdir -p "${SRVCTL_STATE_DIR}/_cron/${other_sname}"
: > "${SRVCTL_STATE_DIR}/_cron/${other_sname}/keep_me.conf"

# ═══ Fixture: SİSTEM GENELİ cron — bu domain'e ÖZGÜ DEĞİL, dokunulmamalı ═══
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-nightly_backup.service"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-nightly_backup.timer"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-syscronfail-nightly_backup.service"

# ═══ Fixture: minimal dosya ağacı (fonksiyonun geri kalanı için) ═══
mkdir -p "${WEB_ROOT}/${d}/public_html"
: > "${WEB_ROOT}/${d}/.credentials"

_domain_purge_resources "$d" "8.3" "0" "0" >/dev/null 2>&1

# ── Bu domain'in cron'ları TAMAMEN silindi ──
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.service")" yok \
    "domain cron .service silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.timer")" yok \
    "domain cron .timer silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-backup_job.service.d")" yok \
    "OnFailure drop-in dizini silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cronfail-${sname}-backup_job.service")" yok \
    "fail-service dosyası silindi"
assert_eq "$(ex "${SRVCTL_STATE_DIR}/_cron/${sname}")" yok \
    "sidecar durum dizini (_cron/<sname>) TAMAMEN silindi"

# ── AYNI domain'in İKİNCİ cron'u da silindi (glob TEK bir isimle sınırlı DEĞİL) ──
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.service")" yok \
    "aynı domain'in İKİNCİ cron'u (.service) da silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.timer")" yok \
    "aynı domain'in İKİNCİ cron'u (.timer) da silindi"

# ── BAŞKA domain'in cron'una DOKUNULMADI (izolasyon) ──
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${other_sname}-keep_me.service")" var \
    "BAŞKA domain'in cron .service'ine DOKUNULMADI"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${other_sname}-keep_me.timer")" var \
    "BAŞKA domain'in cron .timer'ına DOKUNULMADI"
assert_eq "$(ex "${SRVCTL_STATE_DIR}/_cron/${other_sname}")" var \
    "BAŞKA domain'in sidecar durumuna DOKUNULMADI"

# ── SİSTEM GENELİ cron'a KESİNLİKLE DOKUNULMADI (en kritik negatif assertion) ──
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-nightly_backup.service")" var \
    "sistem geneli cron .service'ine DOKUNULMADI (domain'e özgü DEĞİL)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-nightly_backup.timer")" var \
    "sistem geneli cron .timer'ına DOKUNULMADI"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-syscronfail-nightly_backup.service")" var \
    "sistem geneli fail-service'ine DOKUNULMADI"

# ── systemctl'e GERÇEKTEN devredilen (disable/stop) komutlar ──
log="$(cat "$systemctl_log")"
assert_contains "$log" "disable --now srvctl-cron-${sname}-backup_job.timer" \
    "domain cron timer için systemctl disable --now çağrıldı"
assert_contains "$log" "stop srvctl-cron-${sname}-backup_job.service" \
    "domain cron service için systemctl stop çağrıldı"
assert_contains "$log" "disable --now srvctl-cronfail-${sname}-backup_job.service" \
    "fail-service için systemctl disable --now çağrıldı"
assert_not_contains "$log" "syscron" \
    "sistem geneli cron adı systemctl log'unda HİÇ GEÇMİYOR (dokunulmadığının ek kanıtı)"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_STATE_DIR"
test_summary
