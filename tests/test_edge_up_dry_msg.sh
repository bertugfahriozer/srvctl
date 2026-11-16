#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# fm-up off --dry iletisi: "certbot delete" yalnız --purge-cert ile geçer. Gerçek nginx gerekmez.
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
export TRUSTED_STATE_DIR="${WEB_ROOT}/.trusted"; mkdir -p "$TRUSTED_STATE_DIR"
export SRVCTL_ACME_ROOT="${WEB_ROOT}/.acme"
export SRVCTL_LE_LIVE_DIR="${WEB_ROOT}/.le-live"
export SRVCTL_SELF_IPS="198.51.100.7"
export SRVCTL_NGINX_EDGE_DIR="${WEB_ROOT}/.edge.d"
export SRVCTL_FMUP_LOG_DIR="${WEB_ROOT}/.varlog"; mkdir -p "$SRVCTL_FMUP_LOG_DIR"
mkdir -p "${WEB_ROOT}/example.com/logs"
cf_list() { local i; : > "${TRUSTED_STATE_DIR}/cloudflare.conf"; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "10.0.${i}.0/24" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; for i in 1 2 3 4 5 6; do printf '2400:cb0%x::/32\n' "$i" >> "${TRUSTED_STATE_DIR}/cloudflare.conf"; done; }
cf_list
LOCK="${SRVCTL_NGINX_EDGE_DIR}/example_com/05-srvctl-origin-lock.conf"
EREC="${SRVCTL_STATE_DIR}/_edge/example_com.edge"
GREC="${SRVCTL_STATE_DIR}/_edge/GLOBAL.edge"
UPC="${CONFD}/srvctl-fmup-example_com.conf"
TLSC="${CONFD}/00-srvctl-tls-default.conf"
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
tcount() { local n; n=$(grep -c '^t$' "$NGINX_T_LOG" 2>/dev/null); echo "${n:-0}"; }
require_root() { return 0; }   # birim test: root olmadan
# SSL'li vhost (custom.d yalnız 443 bloğunda)
ssl_vhost() { printf 'server {\n    listen 80;\n    server_name example.com;\n    return 301 https://$server_name$request_uri;\n}\nserver {\n    listen 443 ssl http2;\n    server_name example.com;\n    include /etc/nginx/edge.d/example_com/*.conf;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"; }
geo_ok() { printf '# srvctl\ngeo $realip_remote_addr $srvctl_via_cf {\n    default 0;\n    127.0.0.1 1;\n}\n' > "$NGINX_CF_GEO_CONF"; }

# certbot / dig taklitleri (PATH başı; ham çağrılar günlüğe)
CB_LOG="${FM_STUBS}/certbot.log"; : > "$CB_LOG"
cat > "${FM_STUBS}/certbot" <<'CBEOF'
#!/bin/bash
echo "$*" >> "${CB_LOG:?}"
host=""; prev=""
for a in "$@"; do [[ "$prev" == "-d" || "$prev" == "--cert-name" ]] && host="$a"; prev="$a"; done
if [[ "$1" == "delete" ]]; then echo "DELETE ${host}" >> "$CB_LOG"; exit 0; fi
# çağrı ANINDA conf.d içeriği: faz 1 mi (443 yok), tam mı?
f="${SRVCTL_NGINX_CONF_D}/srvctl-fmup-example_com.conf"
if [[ -f "$f" ]]; then if grep -q 'listen 443' "$f"; then echo "AT-CERTBOT has443=1" >> "$CB_LOG"; else echo "AT-CERTBOT has443=0 has80=$(grep -c 'listen 80' "$f")" >> "$CB_LOG"; fi; else echo "AT-CERTBOT conf-yok" >> "$CB_LOG"; fi
[[ "${CERTBOT_FAIL:-0}" == "1" ]] && { echo "Challenge failed" >&2; exit 1; }
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
export CB_LOG SRVCTL_NGINX_CONF_D SRVCTL_LE_LIVE_DIR
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
    cf_list
    [[ "${SEED_TLS:-1}" == "1" ]] && tls_seed
}

echo "══ fm-up off --dry: certbot delete iletisi yalnız --purge-cert ile ══"
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1; : > "$CB_LOG"
( _edge_fmup_cmd example.com off --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off --dry rc 0"
assert_contains "$(cat "$OUTF")" "DRY-OK" "off --dry: DRY-OK basıldı"
assert_not_contains "$(cat "$OUTF")" "certbot delete" "off --dry (--purge-cert YOK): 'certbot delete' GEÇMEZ"
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1; : > "$CB_LOG"
( _edge_fmup_cmd example.com off --purge-cert --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off --purge-cert --dry rc 0"
assert_contains "$(cat "$OUTF")" "certbot delete --cert-name up.example.com" "off --purge-cert --dry: 'certbot delete' GEÇER"
assert_eq "$(wc -l < "$CB_LOG" | tr -d ' ')" "0" "dry: certbot çağrılmadı"
# kayıtlı ama purge=0 ile doğrudan çağrı (iç işlev sözleşmesi: 0 = purge yok)
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1
( _edge_with_lock 1 _edge_fmup_off_locked example.com example_com 1 0 ) >"$OUTF" 2>&1
assert_not_contains "$(cat "$OUTF")" "certbot delete" "purge=0 (iç çağrı): 'certbot delete' GEÇMEZ"
test_summary
