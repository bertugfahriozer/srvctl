#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# GERÇEK nginx laboratuvarı — test_domconf_fm_g13_*_real*.sh için ORTAK (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran önce fm_env.sh (FM_MOCK_CURL TANIMLAMADAN: sonda gerçek curl'le gider), harness_safe.sh, lib/domconf.sh, lib/domain.sh'yi source eder, sonra bunu.
# nginx ya da curl YOKSA çağıran g13_real_skip_if_missing ile dosyayı ATLAR. YALNIZ 127.0.0.1, geçici prefix; dış ağa istek YOK (curl sarmalayıcı kalkanı;
# resolver 127.0.0.1:9). Port aralığı: 19300–19399 (rastgele boş port; çakışırsa yeniden dener).
#
# Düzenek: srvctl'in KENDİ render ettiği FM dosyaları (custom.d/example_com) gerçek nginx'in vhost'una include edilir. fm_env.sh'ın `nginx -t` ve
# `systemctl reload nginx` taklitleri GERÇEK nginx'e bağlanır (yalnız bu iki çağrı; `nginx -t -c <aday>` ModSecurity sondası taklit kalır, modül yok).
# G13_RELOAD_REAL=0 iken reload YAPILMAZ (kayıt/disk yazılır, çalışan nginx eskisinde kalır: "commit ile reload arası kesinti" benzetimi, rc 0);
# G13_RELOAD_REAL=fail iken reload yapılmaz ve rc 1 döner (systemctl reload başarısız; çalışan nginx eskisinde kalır).
# Lab düzeltmesi YALNIZ yol/CA: render_template çıktısında CA paketi ve günlük dizini lab yollarına çevrilir; yapılandırma satırları aynıdır.
g13_real_skip_if_missing() {
    G13_NG="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
    if [[ -z "$G13_NG" || ! -x "$G13_NG" ]] || ! command -v curl >/dev/null 2>&1; then
        echo "── gerçek nginx/curl yok — BU DOSYA ATLANDI (SRVCTL_TEST_NGINX=<nginx ikilisi> ile çalıştırın) ──"
        test_summary
        exit 0
    fi
    G13_CA=""
    local c
    for c in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [[ -f "$c" ]] && { G13_CA="$c"; break; }; done
    if [[ -z "$G13_CA" ]]; then echo "── CA paketi yok — ATLANDI ──"; test_summary; exit 0; fi
}

G13_T=""; G13_P=0; G13_RELOAD_REAL=1
g13_port_free() { ! ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }
g13_lab_counts() { local f="${G13_T}/logs/e.log"; printf '%s %s %s' "$(grep -c 'signal 1 (SIGHUP)' "$f" 2>/dev/null)" "$(grep -c 'start worker process ' "$f" 2>/dev/null)" "$(grep -c 'exited with code' "$f" 2>/dev/null)"; }
g13_wait_reload() {
    local i o n
    read -r -a o <<< "$1"
    for (( i = 0; i < 400; i++ )); do
        read -r -a n <<< "$(g13_lab_counts)"
        if (( ${n[0]:-0} > ${o[0]:-0} && ${n[1]:-0} > ${o[1]:-0} && ${n[2]:-0} > ${o[2]:-0} )); then return 0; fi
        sleep 0.05
    done
    return 1
}
G13_SSL_VERIFY_OFF=0
g13_lab_fix() {
    if [[ "$G13_SSL_VERIFY_OFF" == 1 ]]; then   # yalnız sahte pCloud'a (kendinden imzalı sertifika) bağlanan lab: pCloud'a giden TLS doğrulaması kapatılır
        sed -e "s#/etc/ssl/certs/ca-certificates\.crt#${G13_CA}#g" -e "s#/var/log/nginx/#${G13_T}/logs/#g" -e "s#proxy_ssl_verify on;#proxy_ssl_verify off;#"
    else
        sed -e "s#/etc/ssl/certs/ca-certificates\.crt#${G13_CA}#g" -e "s#/var/log/nginx/#${G13_T}/logs/#g"
    fi
}

# $1 = ek server-içi yapılandırma, $2 = ek http-düzeyi yapılandırma (isteğe bağlı: uygulama/pCloud taklidi vb.; G13_P2 = G13_P+1, G13_P3 = G13_P+2 boş portlardır).
# custom.d/example_com/*.conf include edilir. `location /` = uygulama (CI4) taklidi: erişim günlüğü logs/app.log (satır sayısı = "uygulama koştu").
g13_lab_up() {
    local tries=0 i shim extra="${1:-}" hextra="${2:-}"
    G13_T="$(mktemp -d)"; mkdir -p "$G13_T/logs" "$G13_T/tmp" "$G13_T/shim"
    if declare -F g13_lab_prepare >/dev/null; then g13_lab_prepare || return 1; fi   # test tanımlarsa: lab dizinine PKI/sahte yanıt dosyaları üretir
    shim="$G13_T/shim/curl"
    cat > "$shim" <<'SHIMEOF'
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
    chmod +x "$shim"
    SHIM_LOG="$G13_T/shim.log"; : > "$SHIM_LOG"; export SHIM_LOG
    SHIM_REAL="$(command -v curl)"; export SHIM_REAL
    export PATH="$G13_T/shim:$PATH"
    while (( tries < 12 )); do
        G13_P=$((19300 + RANDOM % 97)); G13_P2=$((G13_P + 1)); G13_P3=$((G13_P + 2))
        if ! g13_port_free "$G13_P" || ! g13_port_free "$G13_P2" || ! g13_port_free "$G13_P3"; then tries=$((tries + 1)); continue; fi
        # ek yapılandırmadaki yer tutucular: @P2@ @P3@ @T@
        extra="${extra//@P2@/$G13_P2}"; extra="${extra//@P3@/$G13_P3}"; extra="${extra//@T@/$G13_T}"
        hextra="${hextra//@P@/$G13_P}"; hextra="${hextra//@P2@/$G13_P2}"; hextra="${hextra//@P3@/$G13_P3}"; hextra="${hextra//@T@/$G13_T}"
        cat > "$G13_T/nginx.conf" <<EOT
pid $G13_T/n.pid;
error_log $G13_T/logs/e.log info;
events { worker_connections 32; }
http {
 access_log off;
 default_type text/plain;
 resolver 127.0.0.1:9; resolver_timeout 1s;
 client_body_temp_path $G13_T/tmp/b; proxy_temp_path $G13_T/tmp/p; fastcgi_temp_path $G13_T/tmp/f; uwsgi_temp_path $G13_T/tmp/u; scgi_temp_path $G13_T/tmp/s;
 server { listen 127.0.0.1:$G13_P; server_name example.com;
   location / { access_log $G13_T/logs/app.log; return 200 "APP-FALLBACK"; }
   ${extra}
   include ${CUR_DIR}/*.conf;
 }
 ${hextra}
}
EOT
        : > "$G13_T/logs/e.log"; : > "$G13_T/logs/app.log"
        if "$G13_NG" -t -c "$G13_T/nginx.conf" -p "$G13_T" >"$G13_T/t.out" 2>&1 && "$G13_NG" -c "$G13_T/nginx.conf" -p "$G13_T" >/dev/null 2>&1; then
            for (( i = 0; i < 100; i++ )); do
                if curl -sS -q --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${G13_P}/" 2>/dev/null; then break; fi
                sleep 0.05
            done
            # fm_env.sh taklitleri → gerçek nginx
            if ! declare -F _g13_orig_nginx >/dev/null; then eval "_g13_orig_nginx() $(declare -f nginx | sed 1d)"; fi
            nginx() {
                if [[ "${1:-}" == "-t" && -z "${2:-}" ]]; then echo "t" >> "$NGINX_T_LOG"; "$G13_NG" -t -c "$G13_T/nginx.conf" -p "$G13_T" 2>&1; return $?; fi
                _g13_orig_nginx "$@"
            }
            systemctl() {
                if [[ "${1:-}" == "reload" ]]; then
                    if declare -F _g13_boom >/dev/null; then _g13_boom; fi   # SIGKILL düzeneği (fm_g13_crash_common.sh) varsa reload çağrısı bir adımdır
                    echo r >> "$RELOAD_LOG"
                    if [[ "$G13_RELOAD_REAL" == fail ]]; then return 1; fi
                    if [[ "$G13_RELOAD_REAL" == 1 ]]; then
                        local c0 rr; c0=$(g13_lab_counts)
                        "$G13_NG" -s reload -c "$G13_T/nginx.conf" -p "$G13_T" >/dev/null 2>&1; rr=$?
                        (( rr == 0 )) && g13_wait_reload "$c0"
                        return $rr
                    fi
                    return 0
                fi
                return 0
            }
            eval "_g13_orig_rt() $(declare -f render_template | sed 1d)"
            render_template() { _g13_orig_rt "$@" | g13_lab_fix; }
            export SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT="$G13_P" SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
            NGINX_FAIL_ON_MODSEC=1
            return 0
        fi
        g13_lab_down
        tries=$((tries + 1))
    done
    sed 's/^/    [lab] /' "$G13_T/t.out" >&2
    return 1
}
g13_lab_down() {
    local pid i
    if [[ -n "$G13_T" && -f "$G13_T/n.pid" ]]; then
        pid=$(cat "$G13_T/n.pid"); "$G13_NG" -s quit -c "$G13_T/nginx.conf" -p "$G13_T" >/dev/null 2>&1
        for (( i = 0; i < 100; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    fi
}
# Gerçek nginx'in şu anki PUT /_fm/up/1/0 (gövdesiz) yanıtı: "<gövde>|<kod>" — kapalı: "srvctl-fm-closed <sig>|403", açık: "srvctl-fm-open <sig>|411".
g13_probe_real() {
    curl -s -o - -w '|%{http_code}' --noproxy '*' --path-as-is --max-time 3 -X PUT -H 'Expect:' -H 'Host: example.com' "http://127.0.0.1:${G13_P}/_fm/up/1/0"
}
g13_real_state() {
    local r sig; sig=$(_domconf_fm_body_sig example_com)
    r=$(g13_probe_real)
    case "$r" in
        "srvctl-fm-closed ${sig}|403") echo REAL-CLOSED ;;
        "srvctl-fm-open ${sig}|411") echo REAL-OPEN ;;
        *) echo "REAL-OTHER(${r})" ;;
    esac
}
# fm_env.sh'ın _fm_reset'i NGINX_FAIL_ON_MODSEC'i sıfırlar; lab'da modsecurity modülü YOKTUR (gerçek nginx 'unknown directive' der) → her sıfırlamadan sonra yeniden kurulur.
g13_real_reset() { reset_all; NGINX_FAIL_ON_MODSEC=1; }
g13_real_restore() { g13_snap_restore "$1"; NGINX_FAIL_ON_MODSEC=1; }
