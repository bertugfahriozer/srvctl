#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# F8/a1 — GERÇEK nginx 1.28 laboratuvarında QL8-H1 / QL8-M1 (C6d) ölçümleri. nginx ya da curl YOKSA bu dosya ATLANIR.
# YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl sarmalayıcı kalkanı; resolver 127.0.0.1:9; ana makine 'example.com'
# yalnız `curl --resolve example.com:<port>:127.0.0.1` ile çözülür). Port aralığı: 19100–19149 (F8/a1).
# Taklit EDİLEN yalnız srvctl'in çevresi (systemctl → `nginx -s reload`, nginx -t → gerçek `nginx -t -c`, flock); disk yazımları,
# köken kaydı, işaret, sonda ve kararlar srvctl'in GERÇEK kodudur; "çalışan durum" gerçek nginx'in gerçek yanıtıdır.
#  H1-A  C1x-60 (yazıcı durumu 'on' okudu; acil kapatma stage girişinde araya girer; üçüncü taraf reload sonradan): gerçek nginx KAPALI
#  H1-B  geri alma penceresinde üçüncü taraf reload AÇIK diski yükledi → geri alma sonrası reload gerçek nginx'i KAPATIR
#  H1-C  acil kapatmanın kilit aşaması: diskte değişiklik olmasa da reload (rev h1heal'in gerçek nginx karşılığı)
#  C6d   kayıt 'on' + imzasız F4-F6 kökü: 8 yolun hiçbiri gerçek nginx'i 411'e (AÇIK) çevirmez
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e

NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -z "$NG" || ! -x "$NG" ]] || ! command -v curl >/dev/null 2>&1; then
    echo "── gerçek nginx/curl yok — BU DOSYA ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi> ile çalıştırın) ──"
    test_summary
    exit 0
fi
CA=""
for c in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [[ -f "$c" ]] && { CA="$c"; break; }; done
if [[ -z "$CA" ]]; then echo "── CA paketi yok — ATLANDI ──"; test_summary; exit 0; fi
PY=""
for c in /opt/homebrew/bin/python3 /usr/bin/python3 "$(command -v python3 2>/dev/null)"; do [[ -n "$c" && -x "$c" ]] && { PY="$c"; break; }; done

T="$(mktemp -d)"; mkdir -p "$T/logs" "$T/tmp" "$T/live" "$T/extra" "$T/shim"
P=0; P2=0; HPID=""
# DIŞARI-0-İSTEK KALKANI: PATH başında curl sarmalayıcı. YALNIZ `--resolve <alan>:<port>:127.0.0.1` ile aynı <alan>:<port>
# hedefine (ya da doğrudan 127.0.0.1:<port>) izin verir; başka her hedef DENY + rc 7. Günlük: $T/shim.log.
REAL_CURL=$(command -v curl)
cat > "$T/shim/curl" <<'SHIMEOF'
#!/bin/bash
echo "$*" >> "${SHIM_LOG:?}"
orig=("$@"); res=""; url=""
while (( $# )); do
    case "$1" in
        --resolve) res="${2:-}"; shift ;;
        http://*|https://*) url="$1" ;;
    esac
    shift
done
hp="${url#*://}"; hp="${hp%%/*}"
if [[ "$hp" == 127.0.0.1:* || ( -n "$res" && "$res" == "${hp}:127.0.0.1" ) ]]; then exec "${SHIM_REAL:?}" "${orig[@]}"; fi
echo "DENY ${url:-?}" >> "$SHIM_LOG"; exit 7
SHIMEOF
chmod +x "$T/shim/curl"
SHIM_LOG="$T/shim.log"; : > "$SHIM_LOG"; export SHIM_LOG SHIM_REAL="$REAL_CURL"
export PATH="$T/shim:$PATH"

# F8-L12: bağlantı denemesiyle "port kullanımda mı" (yalnız 127.0.0.1); lab_down süreç GERÇEKTEN çıkana dek bekler (sabit sleep yok).
lab_port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
lab_down() {
    local pid i
    if [[ -f "$T/n.pid" ]]; then
        pid=$(cat "$T/n.pid"); kill "$pid" 2>/dev/null
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        rm -f "$T/n.pid"
    fi
}
holder_down() { if [[ -n "$HPID" ]]; then kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; HPID=""; fi; }
trap 'holder_down; lab_down; rm -rf "$T"; _fm_env_cleanup' EXIT
lab_fix() { sed -e "/^[[:space:]]*modsecurity off;/d" -e "s#eapi\.pcloud\.com#x.invalid#g" -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${T}/logs/#g"; }
# custom.d/example_com/*.conf → $T/live (nginx'in okuduğu kopya; yalnız laboratuvar dönüşümleri). nginx -t ve reload ÖNCESİ.
lab_sync() {
    local f
    rm -f "$T"/live/*.conf
    for f in "${CUR_DIR}"/*.conf; do [[ -f "$f" ]] && lab_fix < "$f" > "$T/live/${f##*/}"; done
    return 0
}
lab_up() {
    lab_down
    local tries=0 i
    while (( tries < 12 )); do
        P=$((19100 + RANDOM % 48)); P2=$((P + 1))
        # F8-L12: iki port (P ve P2) da boş olmalı; doluysa başka çift denenir
        if ! lab_port_free "$P" || ! lab_port_free "$P2"; then tries=$((tries + 1)); continue; fi
        cat > "$T/nginx.conf" <<EOT
pid $T/n.pid;
error_log $T/logs/e.log info;
events { worker_connections 32; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $T/tmp/b; proxy_temp_path $T/tmp/p; fastcgi_temp_path $T/tmp/f; uwsgi_temp_path $T/tmp/u; scgi_temp_path $T/tmp/s;
 server { listen 127.0.0.1:$P; server_name example.com;
   location / { return 200 "APP"; }
   include $T/live/*.conf;
 }
 include $T/extra/*.conf;
}
EOT
        : > "$T/logs/e.log"; lab_sync
        if "$NG" -t -c "$T/nginx.conf" -p "$T" >"$T/t.out" 2>&1 && "$NG" -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1; then
            for (( i = 0; i < 100; i++ )); do
                if curl -sS -q --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${P}/" 2>/dev/null; then return 0; fi
                sleep 0.05
            done
        fi
        lab_down
        tries=$((tries + 1))
    done
    sed 's/^/    [lab] /' "$T/t.out" >&2
    return 1
}
# srvctl'in çevresi → gerçek nginx
eval "_lab_orig_nginx() $(declare -f nginx | sed 1d)"
nginx() {
    if [[ "${1:-}" == "-t" && -z "${2:-}" ]]; then
        NGINX_T_ARGS="-t"; echo "t" >> "$NGINX_T_LOG"
        lab_sync
        [[ -n "${NGINX_T_HOOK:-}" ]] && "$NGINX_T_HOOK"
        "$NG" -t -c "$T/nginx.conf" -p "$T" 2>&1
        return $?
    fi
    _lab_orig_nginx "$@"
}
# nginx günlük sayaçları: "sig start exit nobind emerg_nonbind" (grep -c eşleşme yoksa exit 1 verir: || true)
lab_log_counts() {
    local f="$T/logs/e.log" a b c d e
    a=$(grep -c 'signal 1 (SIGHUP)' "$f" 2>/dev/null || true)
    b=$(grep -c 'start worker process ' "$f" 2>/dev/null || true)
    c=$(grep -c 'exited with code' "$f" 2>/dev/null || true)
    d=$(grep -c 'still could not bind()' "$f" 2>/dev/null || true)
    e=$( { grep '\[emerg\]' "$f" 2>/dev/null || true; } | grep -vc 'bind()' || true)
    echo "${a:-0} ${b:-0} ${c:-0} ${d:-0} ${e:-0}"
}
lab_reload_done() {   # $1 = reload ÖNCESİ lab_log_counts
    local -a o n
    read -r -a o <<< "$1"; read -r -a n <<< "$(lab_log_counts)"
    (( n[0] > o[0] )) || return 1
    if (( n[1] > o[1] && n[2] > o[2] )); then return 0; fi
    if (( n[3] > o[3] || n[4] > o[4] )); then return 0; fi
    return 1
}
systemctl() {
    if [[ "${1:-}" == "reload" ]]; then
        echo r >> "$RELOAD_LOG"
        [[ "${SYSTEMCTL_RC:-0}" == "0" ]] || return 1
        lab_sync
        # F8-L11: sabit `sleep 0.6` yerine nginx'in kendi günlüğünü bekle (üst sınır ~10 sn; dolarsa devam edilir, iddialar kırmızı verir):
        #   SIGHUP alındı VE ( yeni worker başladı + eski worker çıktı  YA DA  "still could not bind()"  YA DA bind-dışı [emerg] ).
        local rrc i c0
        c0=$(lab_log_counts)
        "$NG" -s reload -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1
        rrc=$?
        if (( rrc == 0 )); then
            for (( i = 0; i < 200; i++ )); do
                if lab_reload_done "$c0"; then break; fi
                sleep 0.05
            done
        fi
        return $rrc
    fi
    return 0
}
# raw: gövdesiz PUT /_fm/up/1/0 → "kod|gövde" (sondayla AYNI istek biçimi, BAĞIMSIZ ölçüm)
raw() {
    local out
    out=$(curl -s -k -o - -w '\n%{http_code}' --noproxy '*' --path-as-is --resolve "example.com:${P}:127.0.0.1" -X PUT -H 'Expect:' "http://example.com:${P}/_fm/up/1/0" 2>/dev/null)
    printf '%s|%s' "${out##*$'\n'}" "${out%$'\n'*}"
}
SIG=$(_domconf_fm_body_sig example_com)
OPEN="411|srvctl-fm-open ${SIG}"; CLOSED="403|srvctl-fm-closed ${SIG}"

OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"; ALT="${SRVCTL_FM_EMERGENCY_DIR}"; AMARK="${ALT}/example_com.emergency"
list_all_domains() { printf '%s\n' example.com; }
_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_out() { cat "$OUTF"; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_repair() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" "${1:-1}" ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
_phpswitch() { ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; }
_batch() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 0 ) >"$OUTF" 2>&1; ( systemctl reload nginx ) >/dev/null 2>&1; }
_mk_stale_bk() {   # açık pre-state yedeği (kesintiye uğramış bir yazımdan kalmış)
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" ]]; then cp -p "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
# yeni açık alan: gerçek nginx'te 411 + AÇIK imzası görülmeli (kontrol)
fresh_open() {
    _fm_reset; rm -f "$T"/extra/*.conf; holder_down
    SYSTEMCTL_RC=0
    _on
    [[ "$(raw)" == "$OPEN" ]]
}
export SRVCTL_FM_PROBE_HTTPS_PORT=off
_ld() { _fmprov_load example_com; RG="$_FMP_REGION"; SC="$_FMP_SCRIPT"; PH="$_FMP_PHP"; MS="$_FMP_MODSEC"; }
_placemark() { printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"; }
legacy_root() {   # F4-F6 imzasız kapalı kök
    printf '%s\n' '# srvctl: FileManager yükleme yolu KAPALI (srvctl domain fm-auth <alan> off). SRVCTL ÜRETİR.' \
        "# Bu 403 kökü, /_fm/ yolunun CI4'e düşmesini engeller; açmak için: fm-auth <alan> on --script=..." \
        'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }'
}
# sahneleme girişine tek seferlik kanca (durum işaretten ÖNCE okundu, sahneleme işaretten SONRA)
eval "_f8_orig_stage() $(declare -f _domconf_fm_stage | sed 1d)"
F8_PRE=""
_domconf_fm_stage() {
    if [[ -n "$F8_PRE" && ! -e "${FM_STUBS}/pre.done" ]]; then : > "${FM_STUBS}/pre.done"; "$F8_PRE"; fi
    _f8_orig_stage "$@"
}
_pre_emergency() {
    ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/pre.em.out" 2>&1
    echo "$?" > "${FM_STUBS}/pre.em.rc"
}
_third() { ( systemctl reload nginx ) >/dev/null 2>&1; }   # üçüncü taraf reload (certbot / logrotate / başka srvctl komutu)

echo "── lab ──"
lab_up; assert_eq "$?" "0" "lab ayağa kalktı (nginx $("$NG" -v 2>&1 | sed 's/.*nginx\///'), 127.0.0.1:${P})"
export SRVCTL_FM_PROBE_HTTP_PORT="$P"
fresh_open; assert_eq "$?" "0" "kontrol: srvctl'in GERÇEK ürettiği açık alan gerçek nginx'te 411 + srvctl-fm-open <imza> verir"

# F9c (§15/38): bu bölümlerin eski tetikleyicisi (90 sil) artık alanı KAPATIR ('on' yazımı yok); yarış bir 'on' YAZIMI ister → tetikleyici: STALE şablon
# (kayıtlı bölge kayması; üç eser tanınan). Beklentiler DEĞİŞMEDİ.
echo "── H1-A: C1x-60 — yazıcı 'on' okudu, acil kapatma stage girişinde araya girer, üçüncü taraf reload sonradan ──"
# yazıcının nginx -t penceresi: her nginx -t'de üçüncü taraf reload + o andaki GERÇEK yanıt kaydı (yazıcı AÇIK sahneleyip -t'ye
# ulaşırsa üçüncü taraf reload AÇIK yapılandırmayı yükler ve burada 411 görünür; kapı varken yazıcı -t'ye hiç ulaşmaz)
_t_probe() { if [[ "$NGINX_T_ARGS" == "-t" ]]; then _third; raw >> "${FM_STUBS}/mid.raw"; echo >> "${FM_STUBS}/mid.raw"; fi; }
for how in repair fmroot phpswitch; do
    fresh_open; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/pre.done" "${FM_STUBS}/pre.em.rc" "${FM_STUBS}/mid.raw"; : > "${FM_STUBS}/mid.raw"
    F8_PRE=_pre_emergency
    NGINX_T_HOOK=_t_probe
    case "$how" in
        repair) _repair ;;
        fmroot) _fmroot ;;
        phpswitch) _phpswitch ;;
    esac
    wrc=$?
    F8_PRE=""; NGINX_T_HOOK=""
    assert_eq "$(grep -c '^411|' "${FM_STUBS}/mid.raw")" "0" "H1-A [${how}]: yazıcı çalışırken ÇALIŞAN nginx HİÇBİR ANDA AÇIK (411) olmadı (üçüncü taraf reload her nginx -t'de denendi)"
    assert_eq "$(cat "${FM_STUBS}/pre.em.rc" 2>/dev/null)" "4" "H1-A [${how}]: ön koşul: eşzamanlı acil kapatma koştu (kilit yazıcıda → rc 4)"
    assert_eq "$(raw)" "$CLOSED" "H1-A [${how}]: yazıcı bitince gerçek nginx KAPALI (F7: yazıcı AÇIK sahneledi)"
    assert_eq "$(( wrc != 0 ))" "1" "H1-A [${how}]: yazıcı rc≠0"
    assert_eq "$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "yokyok" "H1-A [${how}]: diskte 90/21 YOK (yazıcının sahnelediği AÇIK dosyalar yok)"
    _third
    assert_eq "$(raw)" "$CLOSED" "H1-A [${how}]: üçüncü taraf reload'dan SONRA da gerçek nginx KAPALI (F7: +66 sn reload AÇIK yüklüyordu)"
    assert_eq "$([[ -f "$MARK" ]] && echo var || echo yok)" "var" "H1-A [${how}]: işaret yerinde"
done

echo "── H1-B: geri alma penceresinde üçüncü taraf reload AÇIK diski yükledi → geri alma sonrası reload gerçek nginx'i kapatır ──"
_h2() {
    if [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]]; then
        : > "${FM_STUBS}/hk"; _placemark; _third
        raw > "${FM_STUBS}/mid.raw"
    fi
}
fresh_open; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk" "${FM_STUBS}/mid.raw"
NGINX_T_HOOK=_h2
_repair; wrc=$?
NGINX_T_HOOK=""
assert_eq "$(cat "${FM_STUBS}/mid.raw" 2>/dev/null)" "$OPEN" "H1-B kontrol: üçüncü taraf reload yazıcının AÇIK diskini GERÇEKTEN yükledi (gerçek nginx 411 verdi)"
assert_eq "$wrc" "1" "H1-B: repair 'on' kaydı yazamadı (commit kapısı → geri alma)"
assert_eq "$(raw)" "$CLOSED" "H1-B: geri alma sonrası gerçek nginx KAPALI — geri alma reload'u (F7: AÇIK kalıyordu)"
assert_contains "$(_out)" "geri alma alanı yeniden KAPATTI" "H1-B: ileti"

echo "── H1-C: acilin kilit aşaması — diskte değişiklik yoksa da reload (rev h1heal'in gerçek nginx karşılığı) ──"
fresh_open
cp -p "$F90" "$FM_STUBS/o90"; cp -p "$F21" "$FM_STUBS/o21"; cp -p "$F20" "$FM_STUBS/o20"
_domconf_fm_render_off example_com > "$FM_STUBS/c20"
rm -f "${FM_STUBS}/hk3" "${FM_STUBS}/fl3"
# acilin İLK nginx -t'sinde disk geçici AÇIK (yazıcının geri alma penceresi): acilin kendi reload'u AÇIK yapılandırmayı yükler
_h3() { if [[ ! -e "$FM_STUBS/hk3" ]]; then : > "$FM_STUBS/hk3"; cp -p "$FM_STUBS/o90" "$F90"; cp -p "$FM_STUBS/o21" "$F21"; cp -p "$FM_STUBS/o20" "$F20"; fi; }
NGINX_T_HOOK=_h3
cat > "$FM_STUBS/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
# yazıcı kilidi bırakmadan hemen önce geri almayı bitirdi: disk kapalı
if [[ ! -e "$FM_STUBS/fl3" ]]; then : > "$FM_STUBS/fl3"; rm -f "$F90" "$F21"; cp -p "$FM_STUBS/c20" "$F20"; fi
exit 0
FLOCKEOF
chmod +x "$FM_STUBS/flock"; export FM_STUBS F90 F21 F20
_e --emergency; rc=$?
NGINX_T_HOOK=""
assert_eq "$rc" "0" "H1-C: acil kapatma rc 0 (F7: rc 3 'FM HÂLÂ AÇIK' — acilin kendi reload'u AÇIK yükledi, kilit aşaması reload etmedi)"
assert_eq "$(raw)" "$CLOSED" "H1-C: gerçek nginx KAPALI"
assert_contains "$(_out)" "kilit altında disk zaten KAPALI (değişiklik yok)" "H1-C: kilit aşaması reload'u ileti ile görünür"
cat > "$FM_STUBS/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
exit "${FLOCK_RC:-0}"
FLOCKEOF
chmod +x "$FM_STUBS/flock"

echo "── H1-D: SİNYAL İPTALİ (a1b) — yazıcının nginx -t penceresinde TERM/INT; gerçek nginx iptal sonrası KAPALI ──"
# Sinyal yazıcının kendi alt kabuğuna, KANCA İÇİNDEN gönderilir (senkron: kill dönmeden kuyruklanır, trap bekleyen `$(nginx -t)`
# bitince koşar; sleep/saniye yarışı YOK). Aynı pencerede üçüncü taraf reload diskin O ANKİ (AÇIK) halini gerçek nginx'e yükler.
PIDF="${FM_STUBS}/h1d.pid"
eval "_h1d_orig_systemctl() $(declare -f systemctl | sed 1d)"
systemctl() {
    if [[ "${1:-}" == "reload" && -e "${FM_STUBS}/sysfail" ]]; then echo r >> "$RELOAD_LOG"; return 1; fi
    _h1d_orig_systemctl "$@"
}
_hd() {
    [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hd.done" ]] || return 0
    : > "${FM_STUBS}/hd.done"
    [[ -e "${FM_STUBS}/hd.mark" ]] && _placemark
    _third
    raw > "${FM_STUBS}/mid.raw"
    [[ -e "${FM_STUBS}/hd.sysfail" ]] && : > "${FM_STUBS}/sysfail"
    kill "-${KILL_SIG}" "$KILL_TARGET"
}
_hd_reset() { rm -f "${FM_STUBS}/hd.done" "${FM_STUBS}/hd.mark" "${FM_STUBS}/hd.sysfail" "${FM_STUBS}/sysfail" "${FM_STUBS}/mid.raw" "$MARK"; NGINX_T_HOOK=""; }
_hd_run() {
    local sig="$1"; shift
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$sig"; "$@" ) >"$OUTF" 2>&1
}
_hd_repair() { _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1; }
_hd_on()     { _domconf_fm_auth example.com on "--script=${SCRIPT}"; }
# (1) işaret var + üçüncü taraf reload
for pair in TERM:143 INT:130 HUP:129; do
    SIGN="${pair%%:*}"; want="${pair##*:}"
    fresh_open; _hd_reset; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/hd.mark"
    NGINX_T_HOOK=_hd; _hd_run "$SIGN" _hd_repair; wrc=$?
    NGINX_T_HOOK=""
    assert_eq "$(cat "${FM_STUBS}/mid.raw" 2>/dev/null)" "$OPEN" "H1-D1 [${SIGN}] kontrol: üçüncü taraf reload AÇIK diski GERÇEKTEN yükledi (gerçek nginx 411)"
    assert_eq "$wrc" "$want" "H1-D1 [${SIGN}]: sinyal koduyla çıkıldı (${want})"
    assert_eq "$(raw)" "$CLOSED" "H1-D1 [${SIGN}]: iptal sonrası gerçek nginx KAPALI (a1: AÇIK kalıyordu)"
    assert_eq "$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "yokyok" "H1-D1 [${SIGN}]: diskte 90/21 yok"
    assert_contains "$(_out)" "sinyal kesintisi geri alması alanı yeniden KAPATTI" "H1-D1 [${SIGN}]: ileti"
done
# (2) işaretsiz; stage AÇIK yazdı (fm-auth on, önceki durum KAPALI)
fresh_open; ( _domconf_fm_auth example.com off ) >/dev/null 2>&1
assert_eq "$(raw)" "$CLOSED" "H1-D2: ön koşul: alan KAPALI (normal off)"
_hd_reset; NGINX_T_HOOK=_hd; _hd_run TERM _hd_on; wrc=$?
NGINX_T_HOOK=""
assert_eq "$(cat "${FM_STUBS}/mid.raw" 2>/dev/null)" "$OPEN" "H1-D2 kontrol: üçüncü taraf reload açılmış diski gerçekten yükledi (411)"
assert_eq "$wrc|$(raw)" "143|$CLOSED" "H1-D2: işaretsiz, stage AÇIK yazmıştı: iptal sonrası gerçek nginx KAPALI"
# (3) iptalin reload'u başarısız: gerçek nginx AÇIK kalır → dürüst "FM HÂLÂ AÇIK", rc≠0
fresh_open; _hd_reset; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/hd.mark"; : > "${FM_STUBS}/hd.sysfail"
NGINX_T_HOOK=_hd; _hd_run TERM _hd_repair; wrc=$?
NGINX_T_HOOK=""; rm -f "${FM_STUBS}/sysfail"
assert_eq "$wrc|$(raw)" "143|$OPEN" "H1-D3: reload bozuk: çalışan gerçekten AÇIK, rc≠0"
assert_contains "$(_out)" "FM HÂLÂ AÇIK — sinyal kesintisi geri alması sonrası example.com" "H1-D3: 'FM HÂLÂ AÇIK' söylenir (sessiz-AÇIK DEĞİL)"
_third
assert_eq "$(raw)" "$CLOSED" "H1-D3 kurtarma: sonraki reload (operatörün 'systemctl reload nginx'i) gerçek nginx'i KAPATIR — disk zaten kapalıydı"
_hd_reset

echo "── C6d: kayıt 'on' + imzasız F4-F6 kökü + 90/21 yok + işaret yok — 8 yol gerçek nginx'i AÇMAZ ──"
for path in fmroot repair83 repair84 fmrootall phpswitch repairall stalebk_fmroot stalebk_repair; do
    fresh_open
    case "$path" in stalebk_*) _mk_stale_bk AAAAAA ;; esac
    legacy_root > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"
    _third
    r=$(raw)
    assert_eq "${r%%|*}" "403" "C6d [${path}] kontrol: yazılan imzasız kök gerçek nginx'te 403 veriyor"
    case "$path" in
        fmroot|stalebk_fmroot) _fmroot ;;
        repair83) ( _domconf_fm_auth_repair example.com 8.3 1 ) >"$OUTF" 2>&1 ;;
        repair84|stalebk_repair) ( _domconf_fm_auth_repair example.com 8.4 1 ) >"$OUTF" 2>&1 ;;
        fmrootall) _fmroot_all ;;
        phpswitch) _phpswitch ;;
        repairall) _batch ;;
    esac
    _third
    r=$(raw)
    assert_eq "${r%%|*}" "403" "C6d [${path}]: yol sonrası gerçek nginx 403 (F7: 8/8 yol 411 — SESSİZ-AÇIK)"
    assert_eq "$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "yokyok" "C6d [${path}]: 90/21 diskte YOK"
done
# kontrol: açık 'fm-auth on' alanı açar
fresh_open
legacy_root > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; _third
_on; rc=$?
assert_eq "$rc|$(raw)" "0|$OPEN" "C6d kontrol: açık 'fm-auth on' kanıtlı alanı yeniden AÇAR (gerçek nginx 411)"

echo "── dışarı-0-istek ──"
assert_eq "$(grep -c '^DENY' "$SHIM_LOG")" "0" "kalkan günlüğünde DENY satırı yok (dışarı istek 0)"
HOSTS=$(grep -o 'https\{0,1\}://[^/ ]*' "$SHIM_LOG" | sed 's#.*://##; s#:.*##' | sort -u | tr '\n' ' ')
assert_eq "$HOSTS" "127.0.0.1 example.com " "kalkan: curl hedeflerinin TAMAMI yerel (127.0.0.1 / --resolve example.com; $(grep -vc '^DENY' "$SHIM_LOG") çağrı)"

test_summary
