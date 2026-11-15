#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# up-srvctl-fix1: kalite fazı bulgularının (M1 M2 M3 M4 M6 M7 M8 L1, kriter 5, günlük yeri) KIRMIZI→YEŞİL testleri.
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

echo "══ M1: köken kilidi kiracı dosyalarından ÖNCE (edge.d) ══"
TPLS="${REPO_ROOT}/templates/nginx/vhost-ssl.conf.tpl"
ln_edge=$(grep -n '^[[:space:]]*include /etc/nginx/edge\.d/{{SAFE_NAME}}/\*\.conf;' "$TPLS" | head -1 | cut -d: -f1)
ln_cust=$(grep -n '^[[:space:]]*include /etc/nginx/custom\.d/{{SAFE_NAME}}/\*\.conf;' "$TPLS" | head -1 | cut -d: -f1)
assert_ne "${ln_edge:-}" "" "vhost-ssl şablonunda edge.d include'u var"
assert_eq "$([[ -n "${ln_edge:-}" && -n "${ln_cust:-}" && "${ln_edge:-999}" -lt "${ln_cust:-0}" ]] && echo once || echo degil)" "once" "edge.d include'u custom.d include'undan ÖNCE"
assert_eq "$(grep -c 'edge\.d' "${REPO_ROOT}/templates/nginx/vhost.conf.tpl")" "0" "http (SSL'siz) şablon edge.d include ETMEZ (kilit yalnız 443)"
assert_eq "$(sed -n '1,/^}/p' "$TPLS" | grep -c 'edge\.d')" "0" "port 80 yönlendirme bloğu edge.d include etmez"
# render edilmiş gerçek vhost → _edge_vhost_check
mkdir -p "${WEB_ROOT}/example.com"
_domain_write_vhost example.com 8.3 standard ssl >/dev/null 2>&1
_edge_vhost_check example.com example_com; assert_eq "$?" "0" "şablondan üretilen vhost kontrolden geçer (edge.d önce, 443)"
# eski vhost (yalnız custom.d): reddedilir, çare söylenir
printf 'server {\n    listen 443 ssl;\n    server_name example.com;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
_edge_vhost_check example.com example_com; rc=$?
assert_eq "$rc" "2" "edge.d include'u OLMAYAN (eski) vhost: rc 2"
assert_contains "$_EDGE_WHY" "edge.d" "ileti edge.d'yi söyler"
assert_contains "$_EDGE_WHY" "rate-limit" "ileti vhost'u yeniden üretme çaresini söyler"
# edge include custom include'dan SONRA: reddedilir
printf 'server {\n    listen 443 ssl;\n    server_name example.com;\n    include /etc/nginx/custom.d/example_com/*.conf;\n    include /etc/nginx/edge.d/example_com/*.conf;\n}\n' > "$VHOST"
_edge_vhost_check example.com example_com; rc=$?
assert_eq "$rc" "5" "edge.d include'u custom.d'DEN SONRA: rc 5"
# edge include 443 olmayan blokta
printf 'server {\n    listen 80;\n    include /etc/nginx/edge.d/example_com/*.conf;\n}\nserver {\n    listen 443 ssl;\n    include /etc/nginx/edge.d/example_com/*.conf;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
_edge_vhost_check example.com example_com; assert_eq "$?" "3" "edge.d include'u port 80 bloğunda: rc 3"
# 443 bloğu custom.d include ediyor ama edge'siz, ikinci 443 bloğu doğru: reddedilir
printf 'server {\n    listen 443 ssl;\n    include /etc/nginx/edge.d/example_com/*.conf;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\nserver {\n    listen 443 ssl;\n    server_name b;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
_edge_vhost_check example.com example_com; assert_eq "$?" "5" "edge'siz custom.d include eden BAŞKA 443 bloğu: reddedilir"
# komut: kilit edge.d'ye yazılır, custom.d'ye DEĞİL
reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "on rc 0"
assert_eq "$(_exists "$ELOCK")" "var" "kilit edge.d/<safe>/05-srvctl-origin-lock.conf'a yazıldı"
assert_eq "$(_exists "${CUR_DIR}/05-srvctl-origin-lock.conf")" "yok" "custom.d'ye YAZILMADI"
assert_contains "$(cat "$EREC")" "origin-lock $(_domconf_sha256_file "$ELOCK") ${ELOCK}" "kayıt edge.d yolunu taşır"
assert_eq "$(_mode "$ELOCK")" "644" "dosya 0644"
assert_eq "$(_mode "$EDGE_SD")" "755" "edge.d/<safe> dizini 0755"
out=$( ( _edge_origin_lock_cmd example.com status ) 2>&1 ); assert_contains "$out" "AÇIK" "status AÇIK"
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1
assert_contains "$(cat "$OUTF")" "köken kilidi (tanındı)" "nginx-audit edge.d kilidini tanır"
# eski vhost üzerinde on: HİÇBİR ŞEY yazılmaz
reset_edge; geo_ok
printf 'server {\n    listen 443 ssl;\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "eski vhost (edge.d include'u yok): on REDDEDİLİR"
assert_eq "$(_exists "$ELOCK")" "yok" "yazılmadı"
assert_eq "$(_exists "$EDGE_SD")" "yok" "edge dizini de oluşturulmadı"
# off kaldırır; domain remove edge.d kilidini de kaldırır
reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1
( _edge_origin_lock_cmd example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off rc 0"
assert_eq "$(_exists "$ELOCK")" "yok" "off: edge.d kilidi silindi"
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1
_edge_purge_domain example.com
assert_eq "$(_exists "$ELOCK")" "yok" "domain remove: edge.d kilidi de temizlendi (custom.d ile gitmez)"
assert_eq "$(_exists "$EREC")" "yok" "domain remove: kayıt temizlendi"
# güvenilmez edge dizini
reset_edge; ssl_vhost; geo_ok; mkdir -p "$EDGE_SD"; MOCK_BAD_OWNER="$(cd "$EDGE_SD" && pwd -P)"
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "root'a ait olmayan edge.d/<safe>: reddedilir"
assert_eq "$(_exists "$ELOCK")" "yok" "güvenilmez dizine yazılmadı"

echo "══ M2: geo eşiği aile başına ══"
reset_edge
rm -f "$NGINX_CF_GEO_CONF"
cf_list 0 12; out=$(_trusted_apply_geo 2>&1); rc=$?
assert_eq "$rc" "1" "IPv4=0, IPv6=12 (toplam yeterli): geo YAZILMAZ"
assert_eq "$(_exists "$NGINX_CF_GEO_CONF")" "yok" "dosya oluşmadı (aksi hâlde tüm CF trafiği 444)"
assert_contains "$out" "IPv4" "uyarı IPv4'ü söyler"
cf_list 12 0; _trusted_apply_geo >/dev/null 2>&1; assert_eq "$?" "1" "IPv6=0: yazılmaz"
cf_list 9 6; _trusted_apply_geo >/dev/null 2>&1; assert_eq "$?" "1" "IPv4=9 (< 10): yazılmaz"
cf_list 12 4; _trusted_apply_geo >/dev/null 2>&1; assert_eq "$?" "1" "IPv6=4 (< 5): yazılmaz"
assert_eq "$(_exists "$NGINX_CF_GEO_CONF")" "yok" "eşik altı hiçbirinde dosya yok"
cf_list 10 5; _trusted_apply_geo >/dev/null 2>&1; assert_eq "$?" "0" "IPv4=10 + IPv6=5: yazılır"
assert_eq "$(_exists "$NGINX_CF_GEO_CONF")" "var" "eşiği geçen liste yazıldı"
cf_list 12 6; ( TRUSTED_GEO_MIN_V4=20 _trusted_apply_geo ) >/dev/null 2>&1; assert_eq "$?" "1" "TRUSTED_GEO_MIN_V4 eşiği yapılandırılabilir"
cf_list 0 12; before=$(cat "$NGINX_CF_GEO_CONF"); _trusted_apply_geo >/dev/null 2>&1
assert_eq "$(cat "$NGINX_CF_GEO_CONF")" "$before" "reddedilen listede mevcut geo DEĞİŞMEDİ"

echo "══ M6: geo yazımı fm-auth kilidini alır; ilk yazımda nginx -t düşerse kilitler tutarlı ══"
reset_edge; rm -f "$NGINX_CF_GEO_CONF"; : > "$FLOCK_LOG"
_trusted_apply_geo >/dev/null 2>&1
assert_ne "$(wc -l < "$FLOCK_LOG" | tr -d ' ')" "0" "geo yazımı kilit aldı (flock çağrıldı)"
# kilit alınamazsa YAZILMAZ
reset_edge; rm -f "$NGINX_CF_GEO_CONF"; FLOCK_RC=1; export FLOCK_RC
out=$(_trusted_apply_geo 2>&1); rc=$?; FLOCK_RC=0; export FLOCK_RC
assert_eq "$rc" "1" "kilit alınamadı: rc 1"
assert_eq "$(_exists "$NGINX_CF_GEO_CONF")" "yok" "kilit alınamadı: geo YAZILMADI"
# ilk yazım + nginx -t düşer + açık kilit var: kilit dosyası da geri alınır
reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1
assert_eq "$(_exists "$ELOCK")" "var" "(ön koşul) kilit açık"
rm -f "$NGINX_CF_GEO_CONF"
NGINX_TEST_RC=1; out=$(_trusted_apply_geo 2>&1); rc=$?; NGINX_TEST_RC=0
assert_eq "$rc" "1" "nginx -t düştü: rc 1"
assert_eq "$(_exists "$NGINX_CF_GEO_CONF")" "yok" "geo geri alındı (ilk yazımdı)"
assert_eq "$(_exists "$ELOCK")" "yok" "tanımsız \$srvctl_via_cf'ye başvuran kilit dosyası da GERİ ALINDI"
assert_eq "$(_exists "$EREC")" "yok" "kilit kaydı da"
assert_contains "$out" "example_com" "uyarı hangi alanın kilidinin kalktığını söyler"
# geo VARKEN nginx -t düşerse: önceki geo geri gelir, kilitler KALIR
reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1
NGINX_TEST_RC=1; _trusted_apply_geo >/dev/null 2>&1; NGINX_TEST_RC=0
assert_contains "$(cat "$NGINX_CF_GEO_CONF")" "127.0.0.1 1;" "önceki geo geri yüklendi"
assert_eq "$(_exists "$ELOCK")" "var" "geo geri geldiği için kilit KALIR"
# domain remove kilit altında + kayıtla eşleşme
reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on ) >/dev/null 2>&1; : > "$FLOCK_LOG"
_edge_purge_domain example.com >/dev/null 2>&1
assert_ne "$(wc -l < "$FLOCK_LOG" | tr -d ' ')" "0" "domain remove temizliği fm-auth kilidi altında"

echo "══ M3: tls-default başlık zaman aşımı ══"
reset_edge
assert_contains "$(_edge_tls_default_render)" "client_header_timeout 10s;" "tls-default bloğu client_header_timeout 10s taşır (ilk istekte etkili tek yer)"
( cmd_tls_default on ) >/dev/null 2>&1
assert_contains "$(cat "$TLSC")" "client_header_timeout 10s;" "yazılan dosyada da"

echo "══ M4: fm-up host / sertifika sahipliği ══"
reset_edge; live_cert up.example.com
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "live sertifika var ama srvctl kaydı YOK: sahiplenme REDDEDİLİR"
assert_contains "$(cat "$OUTF")" "--adopt-cert" "ileti açık bayrağı söyler"
assert_eq "$(_exists "$UPC")" "yok" "yazılmadı"
( _edge_fmup_cmd example.com on --adopt-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "--adopt-cert ile sahiplenme"
assert_contains "$(cat "$EREC")" "fm-up-cert " "sertifika kaydı yazıldı"
assert_contains "$(grep '^fm-up-cert ' "$EREC")" "up.example.com issued=0" "sahiplenilmiş: issued=0"
: > "$CB_LOG"; ( _edge_fmup_cmd example.com off --purge-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$(grep -c '^delete ' "$CB_LOG")" "0" "sahiplenilmiş sertifika certbot ile SİLİNMEZ"
reset_edge; live_cert up.example.com; ( _edge_fmup_cmd example.com on --adopt-cert ) >/dev/null 2>&1; : > "$CB_LOG"
_edge_purge_domain example.com
assert_eq "$(grep -c '^delete ' "$CB_LOG")" "0" "domain remove sahiplenilmiş (issued=0) sertifikayı SİLMEZ"
# kendi aldığı sertifika silinir
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1
assert_contains "$(grep '^fm-up-cert ' "$EREC")" "up.example.com issued=1" "kendi aldığı: issued=1"
: > "$CB_LOG"; _edge_purge_domain example.com
assert_contains "$(cat "$CB_LOG")" "delete --cert-name up.example.com" "domain remove KENDİ sertifikasını siler"
# başka bir srvctl alanı olan host
reset_edge; SAVE_DE=$(declare -f domain_exists)
domain_exists() { [[ "$1" == "example.com" || "$1" == "shop.example.com" ]]; }
( _edge_fmup_cmd example.com on --host=shop.example.com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "host başka bir srvctl alanı (domain_exists): REDDEDİLİR"
assert_eq "$(_exists "$UPC")" "yok" "yazılmadı"
eval "$SAVE_DE"
# vhost dosyası zaten var
reset_edge; printf 'server { server_name shop.example.com; }\n' > "${SITES_AVAILABLE}/shop.example.com.conf"
( _edge_fmup_cmd example.com on --host=shop.example.com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "sites-available/<host>.conf var: REDDEDİLİR"
assert_eq "$(_exists "$UPC")" "yok" "yazılmadı"
# başka alanın kaydı aynı host'u tutuyor
reset_edge; _edge_prepare_dir; _edge_rec_set other_org fm-up "$(printf 'a%.0s' $(seq 1 64))" "${CONFD}/srvctl-fmup-other_org.conf" "up.example.com https://other.org"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "host başka alanın köken kaydında: REDDEDİLİR"
# doğrudan alt alan kuralı
reset_edge
for badh in up.other.org other.org a.b.example.com "xexample.com" "up.example.com.evil.org"; do
    ( _edge_fmup_cmd example.com on "--host=${badh}" ) >/dev/null 2>&1; assert_eq "$?" "1" "yalnız doğrudan alt alan: ${badh} reddedilir"
done

echo "══ M7: --dry gerçek komutun reddedeceğini de reddeder ══"
reset_edge; ssl_vhost; geo_ok
mkdir -p "$EDGE_SD"; printf '# elle\n' > "$ELOCK"
( _edge_origin_lock_cmd example.com on --dry ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "origin-lock on --dry: kayıtsız dosya var → 1 (gerçek komut da 1)"
( _edge_origin_lock_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "(kontrol) gerçek komut da reddeder"
assert_eq "$(cat "$ELOCK")" "# elle" "dosya korundu"
SEED_TLS=0 reset_edge; ssl_vhost; geo_ok
( _edge_origin_lock_cmd example.com on --dry ) >"$OUTF" 2>&1
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_edge")" "yok" "dry kayıt dizinini OLUŞTURMAZ"
assert_eq "$(_exists "$EDGE_SD")" "yok" "dry edge dizinini OLUŞTURMAZ"
reset_edge; printf 'elle\n' > "$TLSC"
( cmd_tls_default on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "tls-default on --dry: kayıtsız dosya → 1"
( cmd_tls_default on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "(kontrol) gerçek komut da 1"
SEED_TLS=0 reset_edge; ( cmd_tls_default on --dry ) >"$OUTF" 2>&1
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_edge")" "yok" "tls-default dry kayıt dizinini oluşturmaz"
reset_edge; printf '# elle\n' > "$UPC"
( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "fm-up on --dry: kayıtsız conf → 1"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; assert_eq "$?" "1" "(kontrol) gerçek komut da 1"
reset_edge; live_cert up.example.com
( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "fm-up on --dry: yabancı sertifika sahiplenmesi → 1 (gerçekle aynı)"
reset_edge; _edge_before=$(ls -A "${SRVCTL_STATE_DIR}/_edge" | tr '\n' ' '); ( _edge_fmup_cmd example.com on --dry ) >"$OUTF" 2>&1; assert_eq "$?" "0" "fm-up on --dry temiz durumda 0"
assert_eq "$(ls -A "${SRVCTL_STATE_DIR}/_edge" | tr '\n' ' ')" "$_edge_before" "fm-up dry kayıt dizinine HİÇBİR şey eklemez (yalnız tls-default tohumu)"
assert_eq "$(_exists "$SRVCTL_ACME_ROOT")" "yok" "fm-up dry ACME kökünü oluşturmaz"
# off: kayıtsız dosya — dry da reddeder
reset_edge; printf '# elle\n' > "$UPC"
( _edge_fmup_cmd example.com off --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "fm-up off --dry: kayıtsız conf → 1"

echo "══ M8: off sonrası --purge-cert ══"
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1
( _edge_fmup_cmd example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off (purge'süz) rc 0"
assert_eq "$(_exists "$UPC")" "yok" "up bloğu kalktı"
: > "$CB_LOG"
( _edge_fmup_cmd example.com off --purge-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "off --purge-cert (kayıt tombstone'dan): rc 0"
assert_contains "$(cat "$CB_LOG")" "delete --cert-name up.example.com" "sertifika manifestten bulunup SİLİNDİ"
assert_eq "$(_exists "$EREC")" "yok" "tombstone da temizlendi"
( _edge_fmup_cmd example.com off --purge-cert ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "kayıt hiç yokken --purge-cert: rc ≠ 0"
assert_contains "$(cat "$OUTF")" "kayıt" "açık ileti"
assert_eq "$(grep -c '^delete ' "$CB_LOG")" "1" "ikinci çağrı certbot'u ÇAĞIRMADI"
reset_edge; ( _edge_fmup_cmd example.com off --purge-cert ) >"$OUTF" 2>&1; assert_eq "$?" "1" "hiç açılmamış alanda --purge-cert: rc 1 + ileti"
# off: kayıt kalırsa fm-up host listesi (ssl status/monitor) off sonrası boş, tombstone host'u raporlamaz
reset_edge; ( _edge_fmup_cmd example.com on ) >/dev/null 2>&1; ( _edge_fmup_cmd example.com off ) >/dev/null 2>&1
assert_eq "$(_edge_fmup_hosts)" "" "off sonrası up host listesi boş (tombstone izleme listesine girmez)"

echo "══ L1: ön uçuş / ucuz yanıtlar limit_req/limit_conn'a sayılır (yapısal) ══"
TPL="${REPO_ROOT}/templates/nginx/fm-up-server.conf.tpl"
T=$(grep -v '^[[:space:]]*#' "$TPL")
assert_contains "$T" "try_files /__fmup_never_exists @fmup_gate;" "kararlar PRECONTENT'te (try_files) — limit_req PREACCESS'ten SONRA"
assert_contains "$T" "location @fmup_gate {" "adlı karar location'ı"
assert_eq "$(printf '%s\n' "$T" | grep -cE '^    if \(.*\) \{ rewrite \^ /__fmup_gate last; \}')" "3" "üç sunucu-rewrite kararı da /__fmup_gate'e iç yönlendirme"
assert_eq "$(printf '%s\n' "$T" | grep -E '^    if \(' | grep -c 'return')" "0" "sunucu düzeyinde 'if … return' YOK (rewrite aşamasında biter, sayılmaz)"
assert_not_contains "$(grep -E '^[[:space:]]*#' "$TPL" | grep -i "SAYSIN" )" "rewrite … last' döner ki" "yanlış yorum kaldırıldı"

echo "══ Kriter 5: @fm_up client_body_timeout ══"
U20=$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/templates/nginx/fm-upload.conf.tpl")
fmup_blk=$(awk '/location @fm_up \{/{f=1} f{print} f&&/^}/{exit}' <<< "$U20")
assert_contains "$fmup_blk" "client_body_timeout 30s;" "@fm_up: 30s"
assert_not_contains "$U20" "client_body_timeout 120s" "120s hiçbir yerde kalmadı"

echo "══ Günlük yeri: kiracı logs/ dizinine YAZILMAZ ══"
reset_edge
out=$(_edge_fmup_render example.com up.example.com https://example.com 1 2)
assert_contains "$out" "access_log ${SRVCTL_FMUP_LOG_DIR}/srvctl-fmup-example_com.access.log fmup_example_com;" "erişim günlüğü root'a ait dizinde"
assert_contains "$out" "error_log  ${SRVCTL_FMUP_LOG_DIR}/srvctl-fmup-example_com.error.log warn;" "hata günlüğü root'a ait dizinde"
assert_contains "$out" "access_log ${SRVCTL_FMUP_LOG_DIR}/srvctl-fmup-example_com.http.log fmup_example_com;" "port 80 günlüğü de"
assert_not_contains "$out" "${WEB_ROOT}/example.com/logs" "kiracı logs/ dizini ŞABLONDA YOK"
assert_not_contains "$out" "/logs/" "hiçbir /logs/ yolu yok"
def=$(unset SRVCTL_FMUP_LOG_DIR; _edge_fmup_render example.com up.example.com https://example.com 1 2)
assert_contains "$def" "access_log /var/log/nginx/srvctl-fmup-example_com.access.log" "varsayılan /var/log/nginx"
# güvenilmez günlük dizini
reset_edge; rmdir "$SRVCTL_FMUP_LOG_DIR"; ln -s "${WEB_ROOT}/example.com/logs" "$SRVCTL_FMUP_LOG_DIR"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "günlük dizini sembolik bağ: REDDEDİLİR"
assert_eq "$(_exists "$UPC")" "yok" "yazılmadı"
rm -f "$SRVCTL_FMUP_LOG_DIR"; mkdir -p "$SRVCTL_FMUP_LOG_DIR"
reset_edge; MOCK_BAD_OWNER="$SRVCTL_FMUP_LOG_DIR"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "günlük dizini root'a ait değil: REDDEDİLİR"
reset_edge; ln -s "${WEB_ROOT}/example.com/logs/x" "$UPACC"
( _edge_fmup_cmd example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "günlük dosyası sembolik bağ: REDDEDİLİR"
rm -f "$UPACC"
# monitor yeni yolu okur
reset_edge
for i in $(seq 1 120); do echo "203.0.113.5 [x] \"PUT /_fm/up/1/$i\" 429 0 0.000" >> "$UPACC"; done
assert_eq "$(_edge_fmup_log_file example_com access)" "$UPACC" "_edge_fmup_log_file yolu"
assert_eq "$(grep -c 'srvctl-fmup\|_edge_fmup_log_file' "${REPO_ROOT}/lib/monitor.sh")" "1" "monitor yeni yolu kullanır"
assert_eq "$(grep -c '/logs/fm-up' "${REPO_ROOT}/lib/monitor.sh")" "0" "monitor kiracı logs/ yolunu OKUMAZ (root olarak tail etmez)"

echo "══ Günlük dönüşü (logrotate kapsamı) ══"
reset_edge; export SRVCTL_LOGROTATE_DIR="${WEB_ROOT}/.logrotate.d"; mkdir -p "$SRVCTL_LOGROTATE_DIR"
out=$( ( _edge_fmup_cmd example.com on --dry ) 2>&1 ); rc=$?
assert_eq "$rc" "0" "kapsam yok: yalnız UYARI (rc 0)"
assert_contains "$out" "logrotate kapsamı bulunamadı" "kapsam yoksa uyarı"
printf '%s/*.log {\n    weekly\n}\n' "$SRVCTL_FMUP_LOG_DIR" > "${SRVCTL_LOGROTATE_DIR}/nginx"
out=$( ( _edge_fmup_cmd example.com on --dry ) 2>&1 )
assert_not_contains "$out" "logrotate kapsamı bulunamadı" "dağıtım logrotate'i dizini kapsıyorsa uyarı YOK"
unset SRVCTL_LOGROTATE_DIR
test_summary
