#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# up-srvctl-fix2: (K6) --dry taze durum dizininde HİÇBİR dosya/dizin (fm-auth kilidi dahil) yaratmaz; (gözlem) fm-up on tls-default AÇIK
# ister, tls-default off açık fm-up sunucusu varken reddedilir.
# Komut davranışı (nginx/systemctl/certbot/dig TAKLİT) + yapısal şablon kilitleri. Gerçek nginx davranışı:
# tests/test_edge_up_real.sh (bölüm 8b, 9b, 11).
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/edge.sh"
source "${REPO_ROOT}/lib/monitor.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
CONFD="${WEB_ROOT}/.conf.d"; mkdir -p "$CONFD"
export SRVCTL_NGINX_CONF_D="$CONFD"
export NGINX_CF_GEO_CONF="${CONFD}/srvctl-cf-origin-geo.conf"
export NGINX_CF_REALIP_CONF="${CONFD}/srvctl-cloudflare-realip.conf"
export TRUSTED_STATE_DIR="${WEB_ROOT}/.trusted"; mkdir -p "$TRUSTED_STATE_DIR"
export SRVCTL_ACME_ROOT="${WEB_ROOT}/.acme"
export SRVCTL_LE_LIVE_DIR="${WEB_ROOT}/.le-live"
export SRVCTL_NGINX_EDGE_DIR="${WEB_ROOT}/.edge.d"
export SRVCTL_FMUP_LOG_DIR="${WEB_ROOT}/.varlog"; mkdir -p "$SRVCTL_FMUP_LOG_DIR"
export SRVCTL_SELF_IPS="198.51.100.7"
export FAIL2BAN_JAIL_LOCAL="${WEB_ROOT}/jail.local"
mkdir -p "${WEB_ROOT}/example.com/logs"
cf_list() { local n4="$1" n6="$2" i; : > "${TRUSTED_STATE_DIR}/cloudflare.conf"; for ((i = 1; i <= n4; i++)); do echo "10.0.${i}.0/24" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; for ((i = 1; i <= n6; i++)); do printf '2400:cb0%x::/32\n' "$i" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; }
cf_list 12 6
EDGE_SD="${SRVCTL_NGINX_EDGE_DIR}/example_com"
ELOCK="${EDGE_SD}/05-srvctl-origin-lock.conf"
EREC="${SRVCTL_STATE_DIR}/_edge/example_com.edge"
GREC="${SRVCTL_STATE_DIR}/_edge/GLOBAL.edge"
UPC="${CONFD}/srvctl-fmup-example_com.conf"
TLSC="${CONFD}/00-srvctl-tls-default.conf"
UPACC="${SRVCTL_FMUP_LOG_DIR}/srvctl-fmup-example_com.access.log"
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
require_root() { return 0; }
ssl_vhost() { printf 'server {\n    listen 80;\n    server_name example.com;\n    return 301 https://$server_name$request_uri;\n}\nserver {\n    listen 443 ssl http2;\n    server_name example.com;\n    include /etc/nginx/edge.d/example_com/*.conf;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"; }
geo_ok() { printf '# srvctl\ngeo $realip_remote_addr $srvctl_via_cf {\n    default 0;\n    127.0.0.1 1;\n}\n' > "$NGINX_CF_GEO_CONF"; }
CB_LOG="${FM_STUBS}/certbot.log"; : > "$CB_LOG"
cat > "${FM_STUBS}/certbot" <<'CBEOF'
#!/bin/bash
echo "$*" >> "${CB_LOG:?}"
host=""; prev=""
for a in "$@"; do [[ "$prev" == "-d" || "$prev" == "--cert-name" ]] && host="$a"; prev="$a"; done
if [[ "$1" == "delete" ]]; then echo "DELETE ${host}" >> "$CB_LOG"; exit 0; fi
mkdir -p "${SRVCTL_LE_LIVE_DIR}/${host}"
echo CERT > "${SRVCTL_LE_LIVE_DIR}/${host}/fullchain.pem"; echo KEY > "${SRVCTL_LE_LIVE_DIR}/${host}/privkey.pem"
exit 0
CBEOF
cat > "${FM_STUBS}/dig" <<'DGEOF'
#!/bin/bash
t="A"; for a in "$@"; do case "$a" in A|AAAA) t="$a" ;; esac; done
if [[ "$t" == "A" ]]; then printf '%b' "${DIG_A:-}"; else printf '%b' "${DIG_AAAA:-}"; fi
exit 0
DGEOF
chmod +x "${FM_STUBS}/certbot" "${FM_STUBS}/dig"
export CB_LOG SRVCTL_LE_LIVE_DIR
# fm-up on, tls-default AÇIK olmasını ŞART koşar: kapıyı yalnız durum olarak kur (reload/nginx -t yok). SEED_TLS=0 → kapalı.
tls_seed() {
    local f sha; f=$(_edge_tls_conf)
    mkdir -p "$(dirname "$f")"; printf '%s\n' "$(_edge_tls_default_render)" > "$f"
    _edge_prepare_dir && sha=$(_domconf_sha256_file "$f") && _edge_rec_set GLOBAL tls-default "$sha" "$f" ""
}
reset_edge() {
    _fm_reset
    rm -rf "${SRVCTL_STATE_DIR:?}/_edge" "${CONFD:?}"/* "${SRVCTL_LE_LIVE_DIR:?}" "${SRVCTL_ACME_ROOT:?}" "${SRVCTL_NGINX_EDGE_DIR:?}" "${SRVCTL_FMUP_LOG_DIR:?}" 2>/dev/null
    mkdir -p "$CONFD" "$CUR_DIR" "$SRVCTL_FMUP_LOG_DIR"; : > "$CB_LOG"
    unset CERTBOT_FAIL; DIG_A="198.51.100.7\n"; DIG_AAAA=""; export DIG_A DIG_AAAA
    NGINX_V_OUT="nginx version: nginx/1.24.0 (Ubuntu)"; unset SRVCTL_NGINX_VERSION
    cf_list 12 6
    [[ "${SEED_TLS:-1}" == "1" ]] && tls_seed
}
live_cert() { mkdir -p "${SRVCTL_LE_LIVE_DIR}/$1"; echo C > "${SRVCTL_LE_LIVE_DIR}/$1/fullchain.pem"; echo K > "${SRVCTL_LE_LIVE_DIR}/$1/privkey.pem"; }


snap() { find "${SRVCTL_STATE_DIR}" -mindepth 1 2>/dev/null | LC_ALL=C sort | tr '\n' '|'; }
FMA="${SRVCTL_STATE_DIR}/_fm-auth"

echo "══ K6: --dry taze durum dizininde dosya/dizin YARATMAZ ══"
run_dry() {  # $1 etiket; kalan: komut. Taze (boş) durum dizini, tls tohumu yok.
    local label="$1"; shift
    SEED_TLS=0 reset_edge; ssl_vhost; geo_ok
    rm -rf "${SRVCTL_STATE_DIR:?}"/* "${SRVCTL_STATE_DIR:?}"/.[!.]* 2>/dev/null; mkdir -p "$SRVCTL_STATE_DIR"
    local before after; before=$(snap)
    ( "$@" ) >"$OUTF" 2>&1; local rc=$?
    after=$(snap)
    assert_eq "$after" "$before" "${label}: durum dizini içeriği DEĞİŞMEDİ (rc ${rc})"
    assert_eq "$(_exists "$FMA")" "yok" "${label}: _fm-auth dizini/.lock yaratılmadı"
}
run_dry "origin-lock on --dry" _edge_origin_lock_cmd example.com on --dry
run_dry "tls-default on --dry" cmd_tls_default on --dry
run_dry "tls-default off --dry" cmd_tls_default off --dry
# fm-up dry: kapı için tls-default AÇIK olmalı → tohum durumu (_edge) önceden kurulur; _fm-auth yine YOK olmalı
SEED_TLS=0 reset_edge; ssl_vhost; geo_ok; tls_seed
rm -rf "${SRVCTL_STATE_DIR:?}/_fm-auth"
b=$(snap); ( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "fm-up on --dry (tls-default açık) rc 0"
assert_eq "$(snap)" "$b" "fm-up on --dry: durum dizini içeriği DEĞİŞMEDİ"
assert_eq "$(_exists "$FMA")" "yok" "fm-up on --dry: _fm-auth yaratılmadı"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "0" "(kontrol) gerçek fm-up on rc 0"
assert_eq "$(_exists "${FMA}/.lock")" "var" "(kontrol) gerçek yazım kilidi ALIR (.lock var)"
b=$(snap); ( _edge_fmup_cmd example.com off --dry ) >"$OUTF" 2>&1; assert_eq "$?" "0" "fm-up off --dry rc 0"
assert_eq "$(snap)" "$b" "fm-up off --dry: durum dizini içeriği DEĞİŞMEDİ"
# fm-up off --dry, _fm-auth hiç yokken
rm -rf "${SRVCTL_STATE_DIR:?}/_fm-auth"; b=$(snap); ( _edge_fmup_cmd example.com off --dry ) >"$OUTF" 2>&1
assert_eq "$(_exists "$FMA")" "yok" "fm-up off --dry: _fm-auth yaratılmadı"

echo "══ GÖZLEM: fm-up on tls-default AÇIK ister ══"
SEED_TLS=0 reset_edge
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "tls-default KAPALI: fm-up on reddedilir"
assert_contains "$(cat "$OUTF")" "tls-default on" "ileti: önce tls-default on"
assert_eq "$(_exists "$UPC")" "yok" "red: up conf yazılmadı"
assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "red: certbot çağrılmadı"
( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "tls-default KAPALI: --dry de reddeder (gerçekle aynı)"
# tls dosyası var ama srvctl üretimi/kayıtlı değil → AÇIK sayılmaz
SEED_TLS=0 reset_edge; printf 'elle\n' > "$TLSC"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "kayıtsız elle tls dosyası AÇIK sayılmaz"
reset_edge
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "0" "tls-default AÇIK: fm-up on kabul"

echo "══ GÖZLEM: tls-default off açık fm-up varken reddedilir ══"
( cmd_tls_default off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "fm-up AÇIKKEN tls-default off reddedilir"
assert_contains "$(cat "$OUTF")" "fm-up off" "ileti: önce fm-up off"
assert_eq "$(_exists "$TLSC")" "var" "red: tls-default dosyası durur"
( cmd_tls_default off --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "--dry de reddeder"
( _edge_fmup_cmd example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "fm-up off"
( cmd_tls_default off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "fm-up kapalıyken tls-default off kabul"
assert_eq "$(_exists "$TLSC")" "yok" "tls-default dosyası kalktı"
test_summary
