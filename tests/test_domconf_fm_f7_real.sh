#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# F7/a1 — GERÇEK nginx 1.28 laboratuvarında acil kapatma işareti / kilit / çalışan durum ölçümleri.
# nginx ya da curl YOKSA bu dosya ATLANIR, kırmızı vermez (ikili: $SRVCTL_TEST_NGINX ya da PATH'te 'nginx').
# YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl sarmalayıcı kalkanı; resolver 127.0.0.1:9; ana makine
# 'example.com' yalnız `curl --resolve example.com:<port>:127.0.0.1` ile çözülür). Port aralığı: 18950–18999 (F7/a1).
#
# Taklit EDİLEN yalnız srvctl'in çevresi (systemctl → `nginx -s reload`, nginx -t → gerçek `nginx -t -c`, flock);
# disk yazımları, köken kaydı, işaret, sonda ve kararlar srvctl'in GERÇEK kodudur. "Çalışan durum" gerçek nginx'in
# gerçek yanıtıdır (gövdesiz PUT /_fm/up/1/0: 411 + srvctl-fm-open <imza> | 403 + srvctl-fm-closed <imza>).
#
#  R   QL7-H3 (qalab R03×3, NOMARK repair/fm_root_apply/fm_root_all/php_switch/stale_bk_fmroot/stale_bk_repair/
#      repair_all_batch, K8, K2): acil kapatma sonrası 403'ten 411'e dönen 7+ yol artık 403'te kalır
#  H2  gerçek nginx "[emerg] still could not bind()" senaryosu: reload rc 0 ama master eski yapılandırmada →
#      normal off rc 3 "FM HÂLÂ AÇIK" (F6'da rc 0 "kapatıldı")
#  Q   q1b'nin gerçek nginx karşılığı (repair'in nginx -t'si sırasında acil kapatma, kilit alınamıyor)
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
        P=$((18950 + RANDOM % 48)); P2=$((P + 1))
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

echo "── lab ──"
lab_up; assert_eq "$?" "0" "lab ayağa kalktı (nginx $("$NG" -v 2>&1 | sed 's/.*nginx\///'), 127.0.0.1:${P})"
export SRVCTL_FM_PROBE_HTTP_PORT="$P"
fresh_open; assert_eq "$?" "0" "kontrol: srvctl'in GERÇEK ürettiği açık alan gerçek nginx'te 411 + srvctl-fm-open <imza> verir"
assert_eq "$(raw)" "$OPEN" "kontrol: ham yanıt"
assert_eq "$(grep -q 'auth_request' "$F20" && echo var)" "var" "kontrol: 20 gerçek açık şablon (auth_request)"

echo "── R1: kayıt dizini sembolik bağ (qalab R03 ×3: off / off --force / off --emergency) → 4 yol zinciri 403'te kalır ──"
chain() {   # fm-root → repair → fm-root --all → php-switch; her adımdan sonra GERÇEK nginx 403 olmalı
    local tag="$1"
    _fmroot;      assert_eq "$(raw)" "$CLOSED" "${tag}: fm-root --apply sonrası gerçek nginx KAPALI (F6: 411)"
    _repair;      assert_eq "$(raw)" "$CLOSED" "${tag}: repair sonrası gerçek nginx KAPALI (F6: 411)"
    _fmroot_all;  assert_eq "$(raw)" "$CLOSED" "${tag}: fm-root --all --apply sonrası gerçek nginx KAPALI (F6: 411)"
    _phpswitch;   assert_eq "$(raw)" "$CLOSED" "${tag}: php-switch sonrası gerçek nginx KAPALI (F6: 411)"
}
for how in "off" "off --force" "off --emergency"; do
    fresh_open
    mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
    # shellcheck disable=SC2086
    _e ${how#off}; rc=$?
    assert_eq "$rc" "0" "R03 [${how}]: rc 0 (disk kapalı, reload tamam, sonda KAPALI imzası, işaret ikinci konumda)"
    assert_eq "$(raw)" "$CLOSED" "R03 [${how}]: gerçek nginx KAPALI"
    assert_eq "$([[ -f "$AMARK" ]] && echo var || echo yok)" "var" "R03 [${how}]: işaret ikinci güvenilir konumda"
    rm -f "$SD"; mv "${SD}.real" "$SD"
    chain "R03 [${how}]"
done

echo "── R2: işaret HİÇBİR yere yazılamıyor (qalab NOMARK) → rc 6; diskin kendisi KAPALI kanıtı 7 yolu da tutar ──"
nomark() {   # kayıt dizini sembolik bağ + ikinci konum güvenilmez → hiçbir yerde işaret yok
    mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
    mkdir -p "$ALT"; chmod 700 "$ALT"; MOCK_BAD_OWNER="$ALT"
    _e; NM_RC=$?
    MOCK_BAD_OWNER=""
    rm -f "$SD"; mv "${SD}.real" "$SD"
}
for path in repair fm_root_apply fm_root_all php_switch stale_bk_fmroot stale_bk_repair repair_all_batch; do
    fresh_open
    case "$path" in stale_bk_fmroot|stale_bk_repair) _mk_stale_bk AAAAAA ;; esac
    nomark
    assert_eq "$NM_RC" "6" "NOMARK [${path}]: işaret yazılamadı → rc 6"
    assert_eq "$(raw)" "$CLOSED" "NOMARK [${path}]: acil kapatmadan hemen sonra gerçek nginx KAPALI"
    case "$path" in
        repair|stale_bk_repair) _repair ;;
        fm_root_apply|stale_bk_fmroot) _fmroot ;;
        fm_root_all) _fmroot_all ;;
        php_switch) _phpswitch ;;
        repair_all_batch) _batch ;;
    esac
    assert_eq "$(raw)" "$CLOSED" "NOMARK [${path}]: işaret YOK ama diskin KAPALI kanıtı alanı AÇMADI (F6: 403→411)"
done

echo "── R3: SIGKILL pencereleri — K8 (işaret yazıldı, disk kapatılmadı) ve K2 (20 kapandı, 90/21 kenara alınmadan) ──"
fresh_open
eval "_lab_orig_close() $(declare -f _domconf_fm_em_close_disk | sed 1d)"
_domconf_fm_em_close_disk() { kill -9 "$BASHPID"; }
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
_domconf_fm_em_close_disk() { _lab_orig_close "$@"; }
assert_eq "$([[ -f "$MARK" ]] && echo var || echo yok)|$(raw)" "var|$OPEN" "K8: SIGKILL sonrası işaret DİSKTE, alan henüz AÇIK (kapatma başlamadı)"
_repair; assert_eq "$(raw)" "$CLOSED" "K8: repair alanı AÇMADI, KAPATTI (gerçek nginx 403)"
fresh_open
eval "_lab_orig_disable() $(declare -f _domconf_fm_em_disable | sed 1d)"
_domconf_fm_em_disable() { kill -9 "$BASHPID"; }
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
_domconf_fm_em_disable() { _lab_orig_disable "$@"; }
assert_eq "$([[ -f "$F90" ]] && echo 90var || echo 90yok)|$([[ -f "$MARK" ]] && echo var || echo yok)" "90var|var" "K2: 90 kenara alınmadan öldü, işaret diskte"
_fmroot; assert_eq "$(raw)" "$CLOSED" "K2: fm-root --apply alanı AÇMADI, KAPATTI (gerçek nginx 403)"
_repair; assert_eq "$(raw)" "$CLOSED" "K2: sonraki repair da KAPALI"

echo "── H2: gerçek nginx 'still could not bind()' — reload rc 0 ama master ESKİ yapılandırmada ──"
if [[ -z "$PY" ]]; then
    echo "  (python3 yok — port tutucu kurulamadı; H2 gerçek-nginx senaryosu ATLANDI)"
else
    fresh_open
    PF="$T/py.pid" "$PY" -I -B -c 'import socket,time,os,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); open(os.environ["PF"],"w").write(str(os.getpid())); time.sleep(120)' "$P2" &
    HPID=$!
    for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/py.pid" ]] && break; sleep 0.3; done
    # reload SIRASINDA yeni bir vhost meşgul porta listen eder: nginx -t geçer, 'nginx -s reload' rc 0 verir, master bind() edemez
    printf 'server { listen 127.0.0.1:%s; server_name other.invalid; return 200; }\n' "$P2" > "$T/extra/busy.conf"
    : > "$T/logs/e.log"
    _e; rc=$?
    assert_eq "$rc" "3" "H2-gerçek: normal off rc 3 (F6: rc 0 'kapatıldı')"
    assert_contains "$(_out)" "FM HÂLÂ AÇIK" "H2-gerçek: 'FM HÂLÂ AÇIK' söylenir"
    assert_contains "$(_out)" "reload sessizce uygulanmamış olabilir" "H2-gerçek: normal yolun nedeni söylenir"
    assert_eq "$([[ -f "$F90" ]] && echo var || echo yok)$([[ -f "$F21" ]] && echo var || echo yok)" "yokyok" "H2-gerçek: disk KAPALI (90/21 yok)"
    assert_eq "$(raw)" "$OPEN" "H2-gerçek: çalışan nginx hâlâ AÇIK (411 + srvctl-fm-open)"
    for (( _i = 0; _i < 100; _i++ )); do grep -q 'still could not bind()' "$T/logs/e.log" && break; sleep 0.05; done
    assert_contains "$(cat "$T/logs/e.log")" "still could not bind()" "H2-gerçek: nginx error.log '[emerg] still could not bind()' (ölçüm kanıtı)"
    assert_eq "$(raw)" "$OPEN" "H2-gerçek: master eski yapılandırmada kaldı"
    holder_down; rm -f "$T/extra/busy.conf"
    ( systemctl reload nginx ) >/dev/null 2>&1
    assert_eq "$(raw)" "$CLOSED" "H2-gerçek: tutucu bırakılıp reload edilince alan KAPALI"
    # kontrol: meşgul port yoksa aynı akış rc 0 ve KAPALI
    fresh_open
    _e; rc=$?
    assert_eq "$rc|$(raw)" "0|$CLOSED" "H2-gerçek kontrol: sağlıklı reload → normal off rc 0, gerçek nginx KAPALI"
    # --emergency aynı sessiz hatada rc 3
    fresh_open
    PF="$T/py.pid" "$PY" -I -B -c 'import socket,time,os,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); open(os.environ["PF"],"w").write(str(os.getpid())); time.sleep(120)' "$P2" &
    HPID=$!
    for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/py.pid" ]] && break; sleep 0.3; done
    printf 'server { listen 127.0.0.1:%s; server_name other.invalid; return 200; }\n' "$P2" > "$T/extra/busy.conf"
    _e --emergency; rc=$?
    assert_eq "$rc" "3" "H2-gerçek: --emergency aynı sessiz hatada rc 3"
    assert_contains "$(_out)" "reload başarılı görünüyor ama sonda AÇIK imzası verdi" "H2-gerçek: acil yolun rc 3 iletisi"
    holder_down; rm -f "$T/extra/busy.conf"; ( systemctl reload nginx ) >/dev/null 2>&1
    assert_eq "$(raw)" "$CLOSED" "H2-gerçek: temizlik sonrası KAPALI"
fi

echo "── Q: q1b'nin gerçek nginx karşılığı (repair'in nginx -t'si sırasında acil kapatma; kilit alınamıyor) ──"
# F9c (§15/38): eski tetikleyici (90 sil) artık alanı KAPATIR ('on' yazımı yok); kapı-B yarışı bir 'on' YAZIMI ister → tetikleyici: STALE şablon (kayıtlı bölge kayması; üç eser tanınan). Beklentiler DEĞİŞMEDİ.
fresh_open; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
_hook_q1b() {
    if [[ ! -e "${FM_STUBS}/hk" ]]; then
        : > "${FM_STUBS}/hk"
        ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/q1.emerg.out" 2>&1
        echo "emergency rc=$?" >> "${FM_STUBS}/q1.emerg.out"
    fi
}
rm -f "${FM_STUBS}/hk"; NGINX_T_HOOK='_hook_q1b'
_repair; rc=$?
NGINX_T_HOOK=""
assert_contains "$(cat "${FM_STUBS}/q1.emerg.out")" "emergency rc=4" "q1b-gerçek: acil kapatma rc 4 (kilit alınamadı → kapanış DOĞRULANAMAZ)"
assert_eq "$rc" "1" "q1b-gerçek: repair 'on' kaydı yazamadı"
assert_eq "$(raw)" "$CLOSED" "q1b-gerçek: gerçek nginx KAPALI"
assert_eq "$([[ -f "$MARK" ]] && echo var || echo yok)" "var" "q1b-gerçek: repair'in commit'i işareti SİLMEDİ"
_repair
assert_eq "$(raw)" "$CLOSED" "q1b-gerçek: sonraki düz repair alanı AÇMADI (F6: 411)"
assert_eq "$(_st)" "off" "q1b-gerçek: kayıt 'off'a eşitlendi"

echo "── dışarı-0-istek ──"
assert_eq "$(grep -c '^DENY' "$SHIM_LOG")" "0" "kalkan günlüğünde DENY satırı yok (dışarı istek 0)"
HOSTS=$(grep -o 'https\{0,1\}://[^/ ]*' "$SHIM_LOG" | sed 's#.*://##; s#:.*##' | sort -u | tr '\n' ' ')
assert_eq "$HOSTS" "127.0.0.1 example.com " "kalkan: curl hedeflerinin TAMAMI yerel (127.0.0.1 / --resolve example.com; $(grep -vc '^DENY' "$SHIM_LOG") çağrı)"

test_summary
