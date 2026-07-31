#!/bin/bash
# _domain_purge_resources — worker/scheduler unit + per-domain state dir +
# dosya ağacı temizliği.
#
# REGRESYON (H2, denetim DALGA 5 — bkz. lib/domain.sh _domain_purge_resources
# başlık yorumu): 'domain worker enable' + 'domain scheduler enable' + 'domain
# remove' sırayla çalıştırılırsa, ESKİ kod yalnız 'rollback'in bildiği
# kaynakları (DB/Redis/sertifika/dosya ağacı) temizliyordu — worker template
# unit'i (srvctl-worker-<sname>@.service), onun 'multi-user.target.wants'
# altındaki enable sembolik bağı, scheduler service+timer'ı ve
# SRVCTL_STATE_DIR/<domain> hiç bilinmiyordu. Sonuç: 'web_<sname>' userdel
# edilip '/var/www/<domain>' silinse bile scheduler TIMER'ı systemd'de
# enable+aktif kalıyor, her dakika artık var olmayan 'User=web_<sname>' ile
# tetiklenip "Failed to determine user credentials" ile sonsuz journal spam
# üretiyordu; domain yeniden eklenince de eski framework'ün ExecStart'ıyla
# BAYAT unit dosyası orada duruyordu.
#
# Bu test _domain_purge_resources'ı GERÇEKTEN çalıştırır (SRVCTL_SYSTEMD_DIR/
# SRVCTL_FPM_DIR/SRVCTL_STATE_DIR test-seam'leriyle izole edilmiş fixture'lar
# üzerinde) ve hem GERÇEK dosya silme işlemlerini (rm -f/-rf) hem de
# systemctl'e verilen komutları (stub log'u üzerinden) doğrular.
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

# assert_ok/assert_fail argv olarak çalıştırır (mesaj parametresi YOK) —
# varlık kontrolünü stringe çevirip assert_eq ile karşılaştırıyoruz.
ex() { [[ -e "$1" ]] && echo var || echo yok; }

d="purgetest.com"
sname=$(safe_name "$d")

# ═══ Fixture: worker template unit + enable sembolik bağı ═══
mkdir -p "${SRVCTL_SYSTEMD_DIR}/multi-user.target.wants"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-worker-${sname}@.service"
: > "${SRVCTL_SYSTEMD_DIR}/multi-user.target.wants/srvctl-worker-${sname}@default.service"

# ═══ Fixture: scheduler service + timer ═══
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-scheduler-${sname}.service"
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-scheduler-${sname}.timer"

# ═══ Fixture: per-domain FPM unit + config ═══
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-fpm-${sname}.service"
: > "${SRVCTL_FPM_DIR}/${sname}.conf"

# ═══ Fixture: cgroups slice ═══
: > "${SRVCTL_SYSTEMD_DIR}/srvctl-${sname}.slice"

# ═══ Fixture: per-domain state dir (hardened marker) ═══
mkdir -p "${SRVCTL_STATE_DIR}/${d}"
: > "${SRVCTL_STATE_DIR}/${d}/hardened"

# ═══ Fixture: dosya ağacı ═══
mkdir -p "${WEB_ROOT}/${d}/public_html" "${WEB_ROOT}/${d}/releases/20260101_000000"
: > "${WEB_ROOT}/${d}/.credentials"

_domain_purge_resources "$d" "8.3" "0" "0" >/dev/null 2>&1

# ── Gerçek 'rm' ile silinen dosyalar (systemctl'e delege EDİLMEYEN kısım) ──
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-worker-${sname}@.service")"       yok "worker template unit dosyası silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-scheduler-${sname}.service")"    yok "scheduler service dosyası silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-scheduler-${sname}.timer")"      yok "scheduler timer dosyası silindi (H2 regresyonu — eskiden hiç bilinmiyordu)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-fpm-${sname}.service")"          yok "per-domain FPM unit dosyası silindi"
assert_eq "$(ex "${SRVCTL_FPM_DIR}/${sname}.conf")"                            yok "per-domain FPM config dosyası silindi"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-${sname}.slice")"                yok "cgroups slice dosyası silindi"
assert_eq "$(ex "${SRVCTL_STATE_DIR}/${d}")"                                   yok "SRVCTL_STATE_DIR/<domain> silindi (H2 regresyonu — eskiden öksüz kalıyordu)"
assert_eq "$(ex "${WEB_ROOT}/${d}")"                                           yok "dosya ağacı (WEB_ROOT/<domain>) tamamen silindi"

# ── systemctl'e GERÇEKTEN devredilen (disable/stop/daemon-reload) komutlar ──
log="$(cat "$systemctl_log")"
assert_contains "$log" "disable --now srvctl-worker-${sname}@default.service" "worker enable sembolik bağı için systemctl disable --now çağrıldı"
assert_contains "$log" "list-units --all --no-legend --plain srvctl-worker-${sname}@*.service" "diğer aktif worker instance'ları için systemctl list-units sorgulandı"
assert_contains "$log" "disable --now srvctl-scheduler-${sname}.timer"        "scheduler timer için systemctl disable --now çağrıldı"
assert_contains "$log" "stop srvctl-scheduler-${sname}.service"               "scheduler service için systemctl stop çağrıldı"
assert_contains "$log" "disable --now srvctl-fpm-${sname}.service"            "per-domain FPM unit için systemctl disable --now çağrıldı"
assert_contains "$log" "stop srvctl-${sname}.slice"                           "cgroups slice için systemctl stop çağrıldı"
assert_contains "$log" "daemon-reload"                                        "systemctl daemon-reload çağrıldı"

# ═══════════════════════════════════════════════════════════════
# Güvenlik guard'ı: base (WEB_ROOT/<domain>) bir SYMLINK ise 'rm -rf'
# İLE İZLENMEZ (kod: '[[ -e "$base" && ! -L "$base" ]]') — symlink hedefi
# domain dışına (ör. /) işaret edebilir; kör 'rm -rf' zip-slip/traversal
# benzeri bir yıkıma yol açardı.
# ═══════════════════════════════════════════════════════════════
: > "$systemctl_log"
d2="symlinked.com"
real_target="$(mktemp -d)"
: > "${real_target}/onemli_dosya"
ln -s "$real_target" "${WEB_ROOT}/${d2}"

_domain_purge_resources "$d2" "8.3" "0" "0" >/dev/null 2>&1

assert_eq "$(ex "${WEB_ROOT}/${d2}")" var "base symlink ise kendisi silinmiyor (fail-closed)"
assert_eq "$(ex "${real_target}/onemli_dosya")" var "symlink hedefindeki gerçek dosyaya dokunulmadı"

rm -rf "$real_target"

# ═══════════════════════════════════════════════════════════════
# Boş domain argümanı: hiçbir yan etki üretmeden erken dönmeli
# (kod: '[[ -n "$domain" ]] || return 0').
# ═══════════════════════════════════════════════════════════════
: > "$systemctl_log"
assert_ok _domain_purge_resources ""
assert_eq "$(cat "$systemctl_log")" "" "boş domain argümanında systemctl HİÇ çağrılmadı (erken dönüş)"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_STATE_DIR"
test_summary
