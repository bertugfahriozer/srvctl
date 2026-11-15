#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; lab işlevleri dolaylı çağrılır
# F9e-9 — GERÇEK nginx 1.28 laboratuvarında `fm-auth <alan> on` GERİ ALMASI başarısız olduğunda alanın KAPALI kaldığının kalıcı kanıtı.
# nginx ya da curl YOKSA bu dosya ATLANIR (mock karşılıkları: test_domconf_fm_f9e5_unwind_fail_closes.sh, ..._f9e6_unwind_no_record_closes.sh).
# YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl sarmalayıcı kalkanı; resolver 127.0.0.1:9). Port aralığı: 19450–19498.
# Taklit EDİLEN yalnız srvctl'in çevresi (systemctl → `nginx -s reload`, nginx -t → gerçek `nginx -t -c`, flock); disk yazımları,
# köken kaydı, işaret, sonda ve kararlar srvctl'in GERÇEK kodudur; "çalışan durum" gerçek nginx'in gerçek yanıtıdır.
#  A  ÇİFTE HATA: açan komutun reload'u düşer VE geri almanın `nginx -t`'si de düşer (önceki durum kapalı + açık): rc 1, işaret diskte,
#     90/21 yok, 20 = 403 kökü; altı otomatik yol (repair, repair84, php-switch, fm-root, fm-root --all, provision) + üçüncü taraf
#     reload sonrası gerçek nginx 403 (kapalı imzası). Önceki durum açıkken düşüşten hemen sonra çalışan nginx hâlâ AÇIK (ileti doğru).
#  B  UNWIND lrc≠0: geri alma sırasında köken kaydı güvenilmez / bozuk / yok: rc 1, "FM HÂLÂ AÇIK OLABİLİR", disk acil yoldan kapalı,
#     kayıt dizinine HİÇBİR ŞEY yazılmaz, işaret yalnız kayıt dizininin dışındaki ikinci konumda (kayıt yoksa işaret gerekmez); aynı kapanış kanıtı.
#  C  custom.d/<sname> sembolik bağ (kiracının dizinine): sembolik bağ üzerinden AÇIK servis ('off' öncesi kanıt), 'off' girdiyi kenara alır ve
#     gerçek nginx KAPANIR; kiracının dizini değişmez; 'on' sembolik bağa yazmaz.
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

T="$(mktemp -d)"; mkdir -p "$T/logs" "$T/tmp" "$T/live" "$T/extra" "$T/shim"
P=0; P2=0
# DIŞARI-0-İSTEK KALKANI: PATH başında curl sarmalayıcı; yalnız `--resolve <alan>:<port>:127.0.0.1` ile aynı hedefe (ya da doğrudan
# 127.0.0.1:<port>) izin verir, başka her hedef DENY + rc 7.
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

lab_port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
lab_down() {
    local pid i
    if [[ -f "$T/n.pid" ]]; then
        pid=$(cat "$T/n.pid"); "$NG" -s quit -c "$T/nginx.conf" -p "$T" >/dev/null 2>&1
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        rm -f "$T/n.pid"
    fi
}
trap 'lab_down; rm -rf "$T"; _fm_env_cleanup' EXIT
lab_fix() { sed -e "/^[[:space:]]*modsecurity off;/d" -e "s#eapi\.pcloud\.com#x.invalid#g" -e "s#/etc/ssl/certs/ca-certificates\.crt#${CA}#g" -e "s#/var/log/nginx/#${T}/logs/#g"; }
# custom.d/example_com/*.conf → $T/live (nginx'in okuduğu kopya; sembolik bağlı dizin de glob'la izlenir). nginx -t ve reload ÖNCESİ.
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
        P=$((19450 + RANDOM % 48)); P2=$((P + 1))
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
lab_log_counts() {
    local f="$T/logs/e.log" a b c d e
    a=$(grep -c 'signal 1 (SIGHUP)' "$f" 2>/dev/null || true)
    b=$(grep -c 'start worker process ' "$f" 2>/dev/null || true)
    c=$(grep -c 'exited with code' "$f" 2>/dev/null || true)
    d=$(grep -c 'still could not bind()' "$f" 2>/dev/null || true)
    e=$( { grep '\[emerg\]' "$f" 2>/dev/null || true; } | grep -vc 'bind()' || true)
    echo "${a:-0} ${b:-0} ${c:-0} ${d:-0} ${e:-0}"
}
lab_reload_done() {
    local -a o n
    read -r -a o <<< "$1"; read -r -a n <<< "$(lab_log_counts)"
    (( n[0] > o[0] )) || return 1
    if (( n[1] > o[1] && n[2] > o[2] )); then return 0; fi
    if (( n[3] > o[3] || n[4] > o[4] )); then return 0; fi
    return 1
}
# srvctl'in `systemctl reload nginx`i → gerçek nginx. İki kanca: ARM_BREAK (dosyası varsa) reload'a girerken köken kaydını bozar ve reload'u DÜŞÜRÜR;
# SYSTEMCTL_RC≠0 reload'u düşürür (gerçek nginx'e dokunmadan).
BRK_ARM="${FM_STUBS}/brk.arm"; BRK_MODE=""; DIG1="${FM_STUBS}/dig1"
sd_digest() {
    local f
    printf 'DIR %s\n' "$(_mode "$SD")"
    find "$SD" -mindepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -f "$f" && ! -L "$f" ]]; then printf '%s %s %s\n' "$f" "$(_mode "$f")" "$(cksum < "$f")"; else printf '%s %s -\n' "$f" "$(_mode "$f")"; fi
    done
}
break_record() {
    case "$1" in
        untrusted) chmod 755 "$SD" ;;
        corrupt)   printf 'cop\n' > "$MAN" ;;
        missing)   rm -f -- "$MAN" ;;
    esac
    sd_digest > "$DIG1"
}
systemctl() {
    if [[ "${1:-}" == "reload" ]]; then
        echo r >> "$RELOAD_LOG"
        if [[ -e "$BRK_ARM" ]]; then rm -f "$BRK_ARM"; break_record "$BRK_MODE"; return 1; fi
        [[ "${SYSTEMCTL_RC:-0}" == "0" ]] || return 1
        lab_sync
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
# gövdesiz PUT /_fm/up/1/0 → "kod|gövde" (sondayla AYNI istek biçimi, BAĞIMSIZ ölçüm)
raw() {
    local out
    out=$(curl -s -k -o - -w '\n%{http_code}' --noproxy '*' --path-as-is --resolve "example.com:${P}:127.0.0.1" -X PUT -H 'Expect:' "http://example.com:${P}/_fm/up/1/0" 2>/dev/null)
    printf '%s|%s' "${out##*$'\n'}" "${out%$'\n'*}"
}
SIG=$(_domconf_fm_body_sig example_com)
OPEN="411|srvctl-fm-open ${SIG}"; CLOSED="403|srvctl-fm-closed ${SIG}"

OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"; AMARK="${SRVCTL_FM_EMERGENCY_DIR}/example_com.emergency"
BROKEN="$T/extra/zz-broken.conf"; TCNT="${FM_STUBS}/tcnt"
list_all_domains() { printf '%s\n' example.com; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; }
_off() { ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
_third() { ( systemctl reload nginx ) >/dev/null 2>&1; }   # üçüncü taraf reload (certbot / logrotate / başka srvctl komutu)
disk() {
    local a b c
    a=$([[ -e "$F90" || -L "$F90" ]] && echo var || echo yok); b=$([[ -e "$F21" || -L "$F21" ]] && echo var || echo yok)
    if [[ -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]]; then c=KOK403; elif grep -q 'proxy_pass' "$F20" 2>/dev/null; then c=ACIK20; else c=DIGER; fi
    printf '90=%s 21=%s 20=%s' "$a" "$b" "$c"
}
mark() { if [[ -e "$MARK" ]]; then echo state; elif [[ -e "$AMARK" ]]; then echo ikinci; else echo yok; fi; }
heal() { : > "$BROKEN"; NGINX_T_HOOK=""; SYSTEMCTL_RC=0; rm -f "$BRK_ARM"; echo 0 > "$TCNT"; }
# 2. ve sonraki canlı `nginx -t` gerçek nginx'te düşer (geri almanın `apply off`u); 1. (açan komutun kendi -t'si) geçer.
hook_2nd_t_breaks() { local n; [[ "$NGINX_T_ARGS" == "-t" ]] || return 0; n=$(cat "$TCNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$TCNT"; if (( n >= 2 )); then printf 'f9e9_gecersiz_yonerge;\n' > "$BROKEN"; fi; }
start_closed() { _fm_reset; heal; _fmroot; _third; }
start_open() { _fm_reset; heal; _on; }
six() {   # $1 = senaryo etiketi; her yol + üçüncü taraf reload sonrası gerçek nginx KAPALI
    local w
    for w in repair repair84 phpswitch fmroot fmrootall provision; do
        case "$w" in
            repair)    ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1 ) >"$OUTF" 2>&1 ;;
            repair84)  ( _domconf_fm_auth_repair example.com 8.4 1 ) >"$OUTF" 2>&1 ;;
            phpswitch) ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1 ;;
            fmroot)    _fmroot ;;
            fmrootall) _fmroot_all ;;
            provision) ( _domconf_fm_root_provision example.com 1 ) >"$OUTF" 2>&1 ;;
        esac
        _third
        assert_eq "$(raw)" "$CLOSED" "[$1] ${w} + üçüncü taraf reload sonrası GERÇEK nginx KAPALI imzası (403 + srvctl-fm-closed)"
        assert_eq "$([[ -e "$F90" || -e "$F21" ]] && echo VAR || echo yok)" "yok" "[$1] ${w} sonrası diskte 90/21 yok"
    done
}

echo "── lab ──"
lab_up; assert_eq "$?" "0" "lab ayağa kalktı (nginx $("$NG" -v 2>&1 | sed 's/.*nginx\///'), 127.0.0.1:${P})"
export SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$P" SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
start_open; assert_eq "$(raw)" "$OPEN" "kontrol: srvctl'in GERÇEK ürettiği açık alan gerçek nginx'te 411 + srvctl-fm-open <imza> verir"
start_closed; assert_eq "$(raw)" "$CLOSED" "kontrol: 403 kökü gerçek nginx'te 403 + srvctl-fm-closed <imza> verir"

echo "── A: çifte hata — açan komutun reload'u düşer VE geri almanın nginx -t'si düşer (gerçek nginx) ──"
for PREV in closed open; do
    if [[ "$PREV" == closed ]]; then start_closed; else start_open; assert_eq "$(raw)" "$OPEN" "[A/${PREV}] başlangıç: çalışan nginx AÇIK"; fi
    heal; SYSTEMCTL_RC=1; NGINX_T_HOOK=hook_2nd_t_breaks; echo 0 > "$TCNT"
    _on; rc=$?
    NGINX_T_HOOK=""; SYSTEMCTL_RC=0
    msg=$(strip < "$OUTF")
    assert_eq "$(grep -c f9e9_gecersiz "$BROKEN")" "1" "[A/${PREV}] kontrol: geri almanın nginx -t'si GERÇEK nginx'te düştü"
    assert_eq "$rc" "1" "[A/${PREV}] 'on' TAM rc 1"
    assert_contains "$msg" "açılış GERİ ALINAMADI (geri alma rc=" "[A/${PREV}] ileti: açılış GERİ ALINAMADI"
    assert_contains "$msg" "FM HÂLÂ AÇIK OLABİLİR" "[A/${PREV}] ileti: FM HÂLÂ AÇIK OLABİLİR"
    assert_contains "$msg" "acil kapatma işareti yazıldı" "[A/${PREV}] ileti: acil kapatma işareti yazıldı"
    assert_not_contains "$msg" "fm-auth AÇILDI" "[A/${PREV}] 'AÇILDI' denmez"
    assert_eq "$(disk)" "90=yok 21=yok 20=KOK403" "[A/${PREV}] disk: 90/21 yok, 20 = 403 kökü"
    assert_eq "$([[ "$(mark)" != yok ]] && echo ISARET || echo ISARETSIZ)" "ISARET" "[A/${PREV}] acil kapatma işareti diskte"
    if [[ "$PREV" == open ]]; then
        assert_eq "$(raw)" "$OPEN" "[A/${PREV}] düşüşten hemen sonra çalışan nginx hâlâ AÇIK (iletinin 'FM HÂLÂ AÇIK OLABİLİR' dediği durum gerçek)"
    fi
    heal; _third
    assert_eq "$(raw)" "$CLOSED" "[A/${PREV}] onarım + üçüncü taraf reload: GERÇEK nginx KAPALI imzası"
    six "A/${PREV}"
done
heal; _off; _on
assert_eq "$(raw)" "$OPEN" "A kontrol: yalnız açık 'fm-auth on' alanı yeniden açar (işaret kalıcı kilit bırakmadı)"

echo "── B: geri alma sırasında köken kaydı GÜVENİLMEZ / BOZUK / YOK (unwind lrc≠0, gerçek nginx) ──"
for PREV in closed open; do
    for BM in untrusted corrupt missing; do
        tag="B/${PREV}/${BM}"
        if [[ "$PREV" == closed ]]; then start_closed; else start_open; fi
        heal; rm -f "$DIG1"; : > "$BRK_ARM"; BRK_MODE="$BM"
        _on; rc=$?
        msg=$(strip < "$OUTF")
        assert_eq "$([[ -e "$DIG1" ]] && echo bozuldu || echo YOK)" "bozuldu" "[${tag}] kontrol: kayıt reload sırasında gerçekten bozuldu"
        assert_eq "$rc" "1" "[${tag}] 'on' TAM rc 1"
        assert_contains "$msg" "açılış GERİ ALINAMADI (köken kaydı" "[${tag}] ileti: geri alınamadı (köken kaydı …)"
        assert_contains "$msg" "FM HÂLÂ AÇIK OLABİLİR" "[${tag}] ileti: FM HÂLÂ AÇIK OLABİLİR"
        assert_contains "$msg" "kayıt dizinine hiçbir şey yazılmadı" "[${tag}] ileti: kayıt dizinine hiçbir şey yazılmadı"
        assert_eq "$(disk)" "90=yok 21=yok 20=KOK403" "[${tag}] disk: 90/21 yok, 20 = 403 kökü (acil yoldan kapatıldı)"
        assert_eq "$(sd_digest)" "$(cat "$DIG1")" "[${tag}] kayıt dizininin özeti bozma anında ve sonra AYNI (hiçbir şey yazılmadı)"
        case "$BM" in
            missing) assert_eq "$(mark)" "yok" "[${tag}] kayıt yok → işaret gerekmez" ;;
            *)       assert_eq "$(mark)" "ikinci" "[${tag}] işaret YALNIZ kayıt dizininin dışındaki ikinci konumda" ;;
        esac
        heal; _third
        assert_eq "$(raw)" "$CLOSED" "[${tag}] üçüncü taraf reload: GERÇEK nginx KAPALI imzası"
        six "$tag"
    done
done

echo "── C: custom.d/<sname> sembolik bağ → kiracının dizini (gerçek nginx) ──"
TEN="${FM_STUBS}/tenant-owned"
snap() { ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do if [[ -f "$f" && ! -L "$f" ]]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s -\n' "$f"; fi; done ); }
to_symlink() { rm -rf "$TEN"; mv "$CUR_DIR" "$TEN"; ln -s "$TEN" "$CUR_DIR"; }
start_open; to_symlink; _third
assert_eq "$(raw)" "$OPEN" "[C1] kanıt: sembolik bağ üzerinden kiracının dizinindeki AÇIK dosyalar gerçek nginx'e yükleniyor (411)"
before=$(snap "$TEN")
_off; rc=$?
msg=$(strip < "$OUTF")
assert_eq "$rc" "0" "[C1] 'off' rc 0 (kapandı ve çalışan nginx'te doğrulandı)"
assert_contains "$msg" "kenara alındı" "[C1] ileti: girdi kenara alındı"
assert_eq "$(raw)" "$CLOSED" "[C1] 'off' sonrası GERÇEK nginx KAPALI imzası"
assert_eq "$([[ -d "$CUR_DIR" && ! -L "$CUR_DIR" ]] && echo gercek-dizin || echo DEGIL)" "gercek-dizin" "[C1] custom.d/example_com artık gerçek dizin"
assert_eq "$(disk)" "90=yok 21=yok 20=KOK403" "[C1] yeni dizinde 20 = 403 kökü, 90/21 yok"
assert_eq "$(snap "$TEN")" "$before" "[C1] kiracının dizini DEĞİŞMEDİ (açık dosyalar aynen duruyor; yazım 0)"
_third; assert_eq "$(raw)" "$CLOSED" "[C1] üçüncü taraf reload sonrası da KAPALI (kenara alınan bağ nginx'e görünmez)"
start_closed; to_symlink; _third; before=$(snap "$TEN")
_on; rc=$?
assert_eq "$rc" "1" "[C2] sembolik bağlı dizinde 'on' TAM rc 1"
assert_contains "$(strip < "$OUTF")" "YAPILAMAZ" "[C2] ileti: YAPILAMAZ"
assert_eq "$(snap "$TEN")" "$before" "[C2] 'on' kiracının dizinine YAZMADI"
_third; assert_eq "$(raw)" "$CLOSED" "[C2] 'on' reddi sonrası gerçek nginx KAPALI"
test_summary
