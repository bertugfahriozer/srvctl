#!/bin/bash
# QL5-L15/RP5: `domain repair --all` FM yazımı yapan alanlar için TEK toplu nginx -t + TEK reload yapar.
# 'nginx -t' reload'un ÖNKOŞULUDUR: -t başarısızsa reload ÇAĞRILMAZ (bozuk yapılandırma çalışan nginx'e yüklenmez),
# '(nginx-reload)' başarısız listesine girer, rc≠0.
#   A  -t BAŞARISIZ → systemctl reload nginx HİÇ çağrılmadı + rc≠0 + '(nginx-reload)'
#   B  -t başarılı, reload başarılı → TAM 1 reload (2 alan için) + rc 0
#   C  -t başarılı, reload BAŞARISIZ → rc≠0 + '(nginx-reload)'
#   D  hiçbir alan FM yazmadıysa (pending boş) nginx -t / reload HİÇ çağrılmaz
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
SRVCTL_LOCK_DIR="$(mktemp -d)"; export SRVCTL_LOCK_DIR
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
# shellcheck disable=SC2034  # SRVCTL_TEMPLATES: source edilen domain.sh okur
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
mysql() { return 0; }
redis-cli() { return 0; }
id() { return 0; }
EV="$(mktemp)"
NGINX_T_RC=0; RELOAD_RC=0
nginx() { echo "NGINX $*" >> "$EV"; return "$NGINX_T_RC"; }
systemctl() { echo "SYSTEMCTL $*" >> "$EV"; [[ "${1:-}" == "reload" && "${2:-}" == "nginx" ]] && return "$RELOAD_RC"; return 0; }
source "${REPO_ROOT}/lib/domain.sh"
FM_WRITES=1
_domain_load_conf_lib() { return 0; }
_domain_repair_fm_step() { if (( FM_WRITES )) && [[ -n "${_DOMAIN_REPAIR_FM_PENDING:-}" ]]; then printf '%s\n' "$1" >> "$_DOMAIN_REPAIR_FM_PENDING"; fi; return 0; }
_domain_activate_fpm_unit() { return 0; }

WEB_ROOT="$(mktemp -d)"; SRVCTL_STATE_DIR="$(mktemp -d)"; SRVCTL_FPM_DIR="$(mktemp -d)"
SRVCTL_SYSTEMD_DIR="$(mktemp -d)"; SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
export WEB_ROOT SRVCTL_STATE_DIR SRVCTL_FPM_DIR SRVCTL_SYSTEMD_DIR SRVCTL_PHP_POOL_DIR
_setup_domain() {
    local domain="$1" sname; sname=$(safe_name "$domain")
    mkdir -p "${WEB_ROOT}/${domain}"
    _domain_write_credentials "$domain" "${WEB_ROOT}/${domain}" "web_${sname}" "8.3" "db_${sname}" "usr_${sname}" "cleanpassdb1234" \
        "redis_${sname}" "cleanpassredis1234" "${sname}:"
}
_setup_domain "batch-a.test"; _setup_domain "batch-b.test"
_run() { : > "$EV"; OUT=$(_domain_repair "--all" 2>&1); RC=$?; }
_count() { grep -c -- "$1" "$EV" || true; }

echo "── A: nginx -t BAŞARISIZ → reload YOK ──"
NGINX_T_RC=1; RELOAD_RC=0; FM_WRITES=1; _run
assert_eq "$(_count '^SYSTEMCTL reload nginx')" "0" "A: nginx -t başarısızken 'systemctl reload nginx' ÇAĞRILMADI"
assert_eq "$([[ "$RC" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" "A: toplam rc≠0"
assert_contains "$OUT" "(nginx-reload)" "A: '(nginx-reload)' başarısız listesinde"
assert_contains "$OUT" "toplu 'nginx -t'/reload BAŞARISIZ" "A: operatöre açık uyarı"

echo "── B: -t ve reload başarılı → TAM BİR reload ──"
NGINX_T_RC=0; RELOAD_RC=0; FM_WRITES=1; _run
assert_eq "$(_count '^SYSTEMCTL reload nginx')" "1" "B: iki alan için TEK reload"
assert_eq "$(_count '^NGINX -t')" "1" "B: TEK nginx -t"
assert_eq "$RC" "0" "B: rc 0"
assert_contains "$OUT" "nginx TEK sefer reload edildi" "B: başarı iletisi"

echo "── C: -t başarılı, reload BAŞARISIZ ──"
NGINX_T_RC=0; RELOAD_RC=1; FM_WRITES=1; _run
assert_eq "$(_count '^SYSTEMCTL reload nginx')" "1" "C: reload denendi"
assert_eq "$([[ "$RC" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" "C: reload başarısız → rc≠0"
assert_contains "$OUT" "(nginx-reload)" "C: '(nginx-reload)' başarısız listesinde"

echo "── D: FM yazımı yok → nginx -t / reload HİÇ çağrılmaz ──"
NGINX_T_RC=0; RELOAD_RC=0; FM_WRITES=0; _run
assert_eq "$(_count '^NGINX -t')$(_count '^SYSTEMCTL reload nginx')" "00" "D: pending boş → ne -t ne reload"
assert_eq "$RC" "0" "D: rc 0"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_PHP_POOL_DIR" "$SRVCTL_LOCK_DIR" "$EV"
test_summary
