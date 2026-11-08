#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitlerinin okuduğu bayraklar (MOCK_*, NGINX_*, SYSTEMCTL_RC …) bu dosyada atanır
# QL4-M3: ModSecurity tespiti CANLI dosyaya yazmadan (bağımsız sonda: nginx -t -c <aday>) +
# kesinti (SIGKILL) penceresinde geçersiz yapılandırma diskte KALMAZ; yarım işlem status/audit/
# repair/fm-root tarafından doğru raporlanır ve kurtarılır. Eski kodun bıraktığı "kayıt AÇIK der
# ama nginx -t düşer" durumu status'ta görünür, repair yeniden üretir. rev-L7: repair --all tek reload.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; }
PROBE_COPY="${FM_STUBS}/probe-copy.conf"
_cap_probe() { [[ "$NGINX_T_ARGS" == "-t -c "* ]] && cp "${NGINX_T_ARGS#-t -c }" "$PROBE_COPY"; return 0; }
_bkn() { find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_probedirs() { find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.probe.*' 2>/dev/null | wc -l | tr -d ' '; }

echo "── A: sonda içeriği — yalnız GÜVENİLİR ana bağlam load_module; kiracı dosyası okunmaz ──"
NG="${FM_STUBS}/ngx"; mkdir -p "${NG}/modules-enabled" "${NG}/conf.d"
cat > "${NG}/nginx.conf" <<EOF
load_module modules/ngx_http_modsecurity_module.so;
include modules-enabled/*.conf;
events { }
http {
    include ${NG}/conf.d/*.conf;
    include ${SRVCTL_NGINX_CUSTOM_DIR}/example_com/*.conf;
}
EOF
printf 'load_module /usr/lib/nginx/modules/ngx_stream_module.so;\n' > "${NG}/modules-enabled/50-stream.conf"
printf 'map $x $y { default "load_module /tmp/evil-conf.so;"; }\nload_module /tmp/evil-httpinc.so;\n' > "${NG}/conf.d/evil.conf"
_fm_reset; printf 'location /x { return 200 "load_module /tmp/evil-tenant.so;"; }\n' > "${CUR_DIR}/00-custom.conf"
SRVCTL_NGINX_CONF="${NG}/nginx.conf"; NGINX_T_HOOK=_cap_probe; : > "$PROBE_COPY"
_on; rc=$?
NGINX_T_HOOK=""
# F9e-3 (§15/47(a)): bu testte çalışan-durum (FM) sondası yoktur → on AÇILDI ama canlıda DOĞRULANAMADI = rc 4 (eskiden 0). ModSec sondası "geçti" = 0/4 dışı rc (1) OLMAMALI.
assert_eq "$rc" "4" "on (sonda geçti): rc 4 (açıldı, FM canlı sondası doğrulanamadı)"
pc="$(cat "$PROBE_COPY")"
assert_contains "$pc" "load_module modules/ngx_http_modsecurity_module.so;" "sonda: ana dosyanın load_module satırı"
assert_contains "$pc" "load_module /usr/lib/nginx/modules/ngx_stream_module.so;" "sonda: ana bağlam include (göreli desen) izlendi"
assert_not_contains "$pc" "evil" "sonda: http içi include / kiracı dosyası ASLA okunmaz"
assert_contains "$pc" "modsecurity off;" "sonda: modsecurity off;"
assert_contains "$pc" "pid ${SRVCTL_STATE_DIR}/_fm-auth/.probe." "sonda: kendi pid yolu (kayıt dizini altında)"
assert_contains "$(cat "$MAN")" "modsec 1" "sonda geçti → modsec 1"
assert_eq "$(_probedirs)" "0" "sonda dizini temizlendi"
# güvenilmez ana yapılandırma (root sahipli değil) → load_module'süz sonda + uyarı (yanılma yönü güvenli)
_fm_reset; MOCK_BAD_OWNER="$(cd "$NG" && pwd -P)/nginx.conf"; NGINX_T_HOOK=_cap_probe; : > "$PROBE_COPY"
_on; rc=$?; NGINX_T_HOOK=""; MOCK_BAD_OWNER=""
assert_eq "$rc" "4" "güvenilmez ana yapılandırma: on yine de sonuçlanır (rc 4: açıldı, FM canlı sondası doğrulanamadı; F9e-3)"
assert_not_contains "$(cat "$PROBE_COPY")" "load_module" "güvenilmez dosyadan load_module ALINMAZ"
assert_contains "$(cat "$OUTF")" "load_module satırları doğrulanamadı" "uyarı basılır"
# --conf-path nginx -V'den; --without-http_uwsgi_module → sondada uwsgi_temp_path yok
_fm_reset; unset SRVCTL_NGINX_CONF
printf 'load_module /opt/m/alt.so;\nevents { }\nhttp { }\n' > "${NG}/alt.conf"
NGINX_V_OUT="nginx version: nginx/1.28.0
configure arguments: --prefix=/usr/share/nginx --conf-path=${NG}/alt.conf --without-http_uwsgi_module"
NGINX_T_HOOK=_cap_probe; : > "$PROBE_COPY"; _on; NGINX_T_HOOK=""
assert_contains "$(cat "$PROBE_COPY")" "load_module /opt/m/alt.so;" "conf-path 'nginx -V'den okundu"
assert_not_contains "$(cat "$PROBE_COPY")" "uwsgi_temp_path" "--without-http_uwsgi_module → uwsgi_temp_path yazılmaz"
assert_contains "$(cat "$PROBE_COPY")" "scgi_temp_path" "…scgi derlenmiş: scgi_temp_path var"
NGINX_V_OUT=""; export SRVCTL_NGINX_CONF="${FM_STUBS}/nginx.conf"

echo "── B: sonda sınıflandırması — başka dosyadaki hata / başka sonda hatası → FAIL-CLOSED, hiçbir şey yazılmaz ──"
for msg in 'nginx: [emerg] unknown directive "modsecurity" in /etc/nginx/conf.d/x.conf:1' \
           'nginx: [emerg] dlopen() "/usr/share/nginx/modules/ngx_http_modsecurity_module.so" failed'; do
    _fm_reset; NGINX_PROBE_MSG="$msg"
    _on; rc=$?
    assert_eq "$rc" "1" "sonda hatası (${msg:16:40}…) → on başarısız"
    assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")$(_exists "$MAN")" "yokyokyokyok" "…canlı dizine ve kayda HİÇBİR şey yazılmadı"
    assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "0" "…canlı nginx -t hiç koşmadı"
    assert_contains "$(cat "$OUTF")" "ModSecurity yetenek tespiti YAPILAMADI" "…ileti"
    assert_eq "$(_probedirs)" "0" "…sonda dizini temizlendi"
done
NGINX_PROBE_MSG=""

echo "── C: SIGKILL penceresi (canlı nginx -t anında) — geçersiz yapılandırma YOK, yarım işlem raporlanır, kurtarılır ──"
_fm_reset; NGINX_FAIL_ON_MODSEC=1   # ModSecurity modülü YOK (QL4 dev lab m15'in koşulu)
( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1; root0="$(cat "$F20")"; man0="$(cat "$MAN")"
# nginx -t komut ikamesi ($(...)) içinde koşar: hedef PID alt kabuğun BAŞINDA yakalanır (J testindeki gibi).
PIDF="${FM_STUBS}/pid.txt"
_sigkill_at_live() { [[ "$NGINX_T_ARGS" == "-t" ]] && kill -9 "$KILL_TARGET"; sleep 0.3; return 0; }
( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_sigkill_at_live; _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "137" "SIGKILL ile öldü (137)"
assert_eq "$(grep -lsE '^[[:space:]]*modsecurity off;' "${CUR_DIR}"/*.conf | wc -l | tr -d ' ')" "0" "kesinti sonrası diskte 'modsecurity off;' (modül yokken GEÇERSİZ) satırı YOK"
( nginx -t ) >/dev/null 2>&1; assert_eq "$?" "0" "kesinti sonrası canlı nginx -t GEÇER (host genelinde yüklenebilir)"
assert_eq "$(_bkn)" "1" "yarım işlem yedeği diskte (.bk.example_com.*)"
assert_eq "$(find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.bk.example_com.*' | wc -l | tr -d ' ')" "1" "…yedeğin adı alanı taşır"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); rc=$?
assert_eq "$rc" "1" "status: YARIM İŞLEM → rc 1 (AÇIK/KAPALI demez)"
assert_contains "$out" "YARIM İŞLEM" "status: YARIM İŞLEM"
( domain_exists() { return 0; }; list_all_domains() { echo example.com; }; _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "nginx-audit: yarım işlem → rc 1"
assert_contains "$(cat "$OUTF")" "YARIM-İŞLEM" "nginx-audit: YARIM-İŞLEM satırı"
: > "$RELOAD_LOG"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "repair: rc 0"
assert_contains "$(cat "$OUTF")" "kesinti ÖNCESİ haline geri yüklendi" "repair: yedekten kurtardı"
assert_eq "$(cat "$F20")|$(cat "$MAN")" "${root0}|${man0}" "repair: kesinti öncesi (403 kökü + kayıt) bayt bayt geri"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_bkn)" "yokyok0" "repair: yarım 90/21 ve yedek kalmadı"
assert_eq "$(_reloads)" "1" "repair: kurtarma sonrası çalışan nginx diske hizalandı (reload 1)"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); assert_contains "$out" "KAPALI (403 kökü)" "kurtarma sonrası status KAPALI"
NGINX_FAIL_ON_MODSEC=0
# İki yarım yedek → otomatik kurtarma YOK (elle)
_fm_reset; ( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1
mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.AAAAAA" "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.BBBBBB"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "iki yarım yedek: repair rc 1"
assert_eq "$(_bkn)" "2" "…yedeklere dokunulmadı"
assert_contains "$(cat "$OUTF")" "birden çok yarım işlem yedeği" "…neden"
rm -rf "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.AAAAAA" "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.BBBBBB"

echo "── D: eski kodun bıraktığı durum — kayıt 'AÇIK' der ama canlı nginx -t BU alanın dosyasında düşer ──"
_fm_reset; _on; assert_contains "$(cat "$MAN")" "modsec 1" "hazırlık: modsec 1 ile açık"
NGINX_FAIL_ON_MODSEC=1   # modül artık yok (ya da eski deneme-yanılma SIGKILL'i): 'modsecurity off;' geçersiz
mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth/.bk.ZzZz12"   # eski biçim (adsız) yarım yedek
out=$( (_domconf_fm_auth example.com status) 2>&1 ); rc=$?
assert_eq "$rc" "1" "status: özetler OK ama nginx -t düşüyor → rc 1"
assert_contains "$out" "nginx -t BAŞARISIZ ve hata BU alanın custom.d dosyasında" "status: gerçeği söyler"
assert_contains "$out" "sahibi bilinmeyen (eski biçim)" "status: eski biçim yedek raporlanır"
( domain_exists() { return 0; }; _domconf_nginx_audit example.com ) >"$OUTF" 2>&1
assert_contains "$(cat "$OUTF")" "UYARI: sahibi bilinmeyen (eski biçim) yarım işlem yedeği" "audit: eski biçim yedek UYARI"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "repair: rc 0 (nginx -t'nin bu alanda düştüğünü gördü, yeniden üretti)"
assert_contains "$(cat "$OUTF")" "nginx -t bu alanın custom.d dosyasında düşüyor" "repair: nedeni söyler"
assert_eq "$(grep -lsE '^[[:space:]]*modsecurity off;' "${CUR_DIR}"/*.conf | wc -l | tr -d ' ')" "0" "repair sonrası 'modsecurity off;' kalmadı (sonda: modül yok)"
assert_contains "$(cat "$MAN")" "modsec 0" "repair sonrası kayıt modsec 0"
( nginx -t ) >/dev/null 2>&1; assert_eq "$?" "0" "repair sonrası canlı nginx -t GEÇER"
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth/.bk.ZzZz12")" "var" "eski biçim yedeğe DOKUNULMADI (sahibi bilinmez)"
rm -rf "${SRVCTL_STATE_DIR}/_fm-auth/.bk.ZzZz12"
# başka dosyada nginx -t hatası: repair dürüstçe başarısız, dosyalara dokunmaz
_fm_reset; NGINX_FAIL_ON_MODSEC=0; _on; s0="$(cat "$F20")|$(cat "$F90")|$(cat "$MAN")"
NGINX_T_MSG='nginx: [emerg] unexpected "}" in /etc/nginx/sites-enabled/baska.conf:9'
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "başka dosyada nginx -t hatası: repair rc 1 (sessiz 0 değil)"
assert_eq "$(cat "$F20")|$(cat "$F90")|$(cat "$MAN")" "$s0" "…FM dosyalarına dokunulmadı"
NGINX_T_MSG=""

echo "── E: rev-L7 — repair --all FM adımında alan başına reload YOK, sonda TEK reload ──"
_fm_reset
for d in a.com b.com c.com; do mkdir -p "${WEB_ROOT}/${d}" "${SRVCTL_NGINX_CUSTOM_DIR}/$(safe_name "$d")"; printf 'server {\n    include /etc/nginx/custom.d/%s/*.conf;\n}\n' "$(safe_name "$d")" > "${SITES_AVAILABLE}/${d}.conf"; done
eval "$(declare -f _domain_repair | sed '1s/^_domain_repair /_orig_domain_repair /')"
_domain_repair() { if [[ "$1" == "--all" ]]; then _orig_domain_repair --all; else _domain_repair_fm_step "$1" "${DEFAULT_PHP_VERSION}"; fi; }
list_all_domains() { printf '%s\n' a.com b.com c.com; }
_domain_repair_is_ghost() { return 1; }
: > "$RELOAD_LOG"; : > "$NGINX_T_LOG"
( _domain_repair --all ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "repair --all (FM adımı): rc 0"
assert_eq "$(_reloads)" "1" "3 alan kök kurdu, TEK reload"
assert_eq "$(ls "${SRVCTL_NGINX_CUSTOM_DIR}"/{a,b,c}_com/20-srvctl-fm-upload.conf 2>/dev/null | wc -l | tr -d ' ')" "3" "üç alanda 403 kökü"
assert_contains "$(cat "$OUTF")" "nginx TEK sefer reload edildi" "tek reload söylenir"
# Yazım yoksa reload yoktur — çalışan durum KESİN KAPALI imzası veriyorsa (ARCHITECTURE §15/93(b)(1): doğrulanamayan çalışan durum "kapalı" sayılmaz ve disk KAPALI
# iken yeniden yüklenir; bu test dosyasında canlı sonda kapalıdır (FM_MOCK_CURL yok) → kesin kapalı imza bir kanca ile verilir, yazım-yok yolu ayrı sınanır).
eval "_c13_orig_probe() $(declare -f _domconf_fm_runtime_probe | sed 1d)"
_domconf_fm_runtime_probe() { _FMRT_STATE="closed"; _FMRT_DETAIL="test: kesin KAPALI imzası"; return 0; }
: > "$RELOAD_LOG"; ( _domain_repair --all ) >"$OUTF" 2>&1
assert_eq "$(_reloads)" "0" "ikinci --all: yazım yok, çalışan KESİN KAPALI → reload YOK"
_domain_repair_fm_step a.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$(_reloads)" "0" "(kontrol) tek alan, değişiklik yok, çalışan KESİN KAPALI: reload yok"
# …ama sonda KÖR (doğrulanamıyor) ise yazım olmasa da yeniden yüklenir (alan başına değil, --all'da döngü sonunda TEK sefer)
_domconf_fm_runtime_probe() { _c13_orig_probe "$@"; }
: > "$RELOAD_LOG"; ( _domain_repair --all ) >"$OUTF" 2>&1
assert_eq "$(_reloads)" "1" "ikinci --all, sonda kör: yazım yok ama doğrulanamayan çalışan durum → döngü sonunda TEK reload"
rm -f "${SRVCTL_NGINX_CUSTOM_DIR}/a_com/20-srvctl-fm-upload.conf"; : > "$RELOAD_LOG"
( _domain_repair_fm_step a.com "${DEFAULT_PHP_VERSION}" ) >/dev/null 2>&1; assert_eq "$(_reloads)" "1" "tek alan repair (--all dışı): kendi reload'u (1)"
unset -f _domain_repair _orig_domain_repair

test_summary
