#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# FM KAPALIYKEN uygulama X-Accel-Redirect ile `/__fm_dl`e yönlendirirse istek uygulamaya (CI4) DÜŞMEZ (ARCHITECTURE §15/93(b)(6); §15/80(c)'nin indirme yolu eşi).
# GERÇEK nginx 1.28 laboratuvarı; nginx ya da curl ya da openssl YOKSA bu dosya ATLANIR. YALNIZ 127.0.0.1:19300–19399; dış ağa istek YOK.
# Düzenek: 'location = /dl' ikinci bir dinleyiciye (uygulama taklidi) vekiller; o uç `X-Accel-Redirect: /__fm_dl?u=https://p-lab1.pcloud.com/cfile/video.bin basar.
# 'location /' = CI4 taklidi: erişim günlüğü logs/app.log (her satır "uygulama koştu"). Sahte pCloud: kendinden imzalı TLS dinleyicisi (nginx 'upstream p-lab1.pcloud.com');
# pCloud'a giden TLS doğrulaması YALNIZ bu lab'da kapatılır (G13_SSL_VERIFY_OFF); öteki yapılandırma srvctl'in kendi render çıktısıdır.
#  A  FM KAPALI (srvctl'in 403 kökü; 90/21 yok): GET /dl → 403, uygulama günlüğü 0 (eskiden iç istek 'location /'e düşer: uygulama koşardı); dışarıdan /__fm_dl,
#     /__fm_auth, /__fm_x → 404 (internal), uygulama 0; kapalı kök imzası sondada hâlâ "KAPALI".
#  B  FM AÇIK (pozitif kontrol): GET /dl → 200 (gövde sahte pCloud'dan), Range ile 206 + Content-Range, uygulama günlüğü 0.
#  C  FM yeniden KAPATILINCA (off) A'daki sonuç geri gelir.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
source "${REPO_ROOT}/tests/fm_g13_real_common.sh"
set +e
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
g13_real_skip_if_missing
if ! command -v openssl >/dev/null 2>&1; then echo "── openssl yok — BU DOSYA ATLANDI ──"; test_summary; exit 0; fi
trap 'g13_lab_down; rm -rf "${G13_T:?}"; _fm_env_cleanup' EXIT

# uygulama taklidi (X-Accel basar) + sahte pCloud (TLS) — yer tutucular g13_lab_up'ta doldurulur
SERVER_EXTRA='location = /dl { proxy_pass http://127.0.0.1:@P2@/xdl; }'
HTTP_EXTRA='
 upstream p-lab1.pcloud.com { server 127.0.0.1:@P3@; }
 server { listen 127.0.0.1:@P2@;
   location = /xdl { add_header X-Accel-Redirect "/__fm_dl?u=https://p-lab1.pcloud.com/cfile/video.bin" always; add_header Content-Disposition "attachment; filename=\"video.bin\"" always; return 200 "xaccel"; }
 }
 server { listen 127.0.0.1:@P3@ ssl; server_name p-lab1.pcloud.com;
   ssl_certificate @T@/pki/srv.crt; ssl_certificate_key @T@/pki/srv.key;
   location /cfile/ { root @T@/pcloud; access_log @T@/logs/pcloud.log; }
 }'
# lab dizinine (G13_T) PKI + sahte pCloud dosyası üretir (g13_lab_up çağırır)
g13_lab_prepare() {
    mkdir -p "$G13_T/pki" "$G13_T/pcloud/cfile"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$G13_T/pki/srv.key" -out "$G13_T/pki/srv.crt" -days 2 -subj "/CN=p-lab1.pcloud.com" >/dev/null 2>&1
    [[ -s "$G13_T/pki/srv.crt" ]] || return 1
    head -c 4096 /dev/urandom > "$G13_T/pcloud/cfile/video.bin" 2>/dev/null
    return 0
}
G13_SSL_VERIFY_OFF=1
if ! g13_lab_up "$SERVER_EXTRA" "$HTTP_EXTRA"; then echo "  FAIL lab açılamadı (openssl sertifika/port/nginx -t)"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; fi

lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# kalan = curl bağımsız değişkenleri (URL son). Çıktı: "<kod> app=<n>"
req() {
    local app0 code
    app0=$(lines "$G13_T/logs/app.log")
    code=$(curl -sS -q --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' -H 'Host: example.com' "${@}" 2>/dev/null)
    printf '%s app=%s' "$code" "$(( $(lines "$G13_T/logs/app.log") - app0 ))"
}
DL="http://127.0.0.1:${G13_P}/dl"

echo "── A: FM KAPALI (srvctl 403 kökü) — X-Accel /__fm_dl uygulamaya düşmez ──"
g13_real_reset; G13_RELOAD_REAL=1
( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1
assert_eq "$(_shut)|$(_st)|$(g13_real_state)" "SHUT|off|REAL-CLOSED" "A0: 403 kökü kuruldu (90/21 yok), kayıt off, gerçek nginx KAPALI imzası verir"
assert_eq "$(req "$DL")" "403 app=0" "A1: kapalı alan: X-Accel /__fm_dl → 403, uygulama günlüğü 0"
assert_eq "$(req -H 'Range: bytes=100-1099' "$DL")" "403 app=0" "A2: Range ile de 403, uygulama 0"
for p in /__fm_dl "/__fm_dl?u=https://p-lab1.pcloud.com/cfile/video.bin" /__fm_auth /__fm_x /__fm_; do
    assert_eq "$(req "http://127.0.0.1:${G13_P}${p}")" "404 app=0" "A3: dışarıdan GET ${p} → 404 (internal), uygulama 0"
done
assert_eq "$(g13_real_state)" "REAL-CLOSED" "A4: kapalı kök imzası sondada hâlâ KAPALI (yakalayıcı imzalı 403'ü bozmadı)"

echo "── B: FM AÇIK (pozitif kontrol) — indirme çalışmaya devam eder ──"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1
if [[ "$(g13_real_state)" != "REAL-OPEN" ]]; then strip < "$OUTF" | sed 's/^/    [on] /' >&2; fi
assert_eq "$(g13_real_state)" "REAL-OPEN" "B0: on: gerçek nginx 411 AÇIK imzası"
assert_eq "$(req "$DL")" "200 app=0" "B1: açık alan: X-Accel /__fm_dl → 200 (sahte pCloud'dan), uygulama 0"
assert_eq "$(req -H 'Range: bytes=100-1099' "$DL")" "206 app=0" "B2: Range → 206, uygulama 0"
rng=$(curl -sS -q --noproxy '*' --max-time 10 -D - -o "$G13_T/part.bin" -H 'Host: example.com' -H 'Range: bytes=100-1099' "$DL" 2>/dev/null | tr -d '\r' | grep -i '^content-range:')
assert_contains "$rng" "bytes 100-1099/4096" "B3: Content-Range pCloud'dan olduğu gibi akar"
assert_eq "$(dd if="$G13_T/pcloud/cfile/video.bin" bs=1 skip=100 count=1000 2>/dev/null | cmp - "$G13_T/part.bin" && echo EŞİT)" "EŞİT" "B4: 206 gövdesi kaynak baytlarıyla birebir"

echo "── C: yeniden KAPATILINCA A'daki sonuç geri gelir ──"
( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1
assert_eq "$(_shut)|$(g13_real_state)" "SHUT|REAL-CLOSED" "C0: off: disk 403 kökü, gerçek nginx KAPALI"
assert_eq "$(req "$DL")" "403 app=0" "C1: off sonrası X-Accel /__fm_dl → 403, uygulama 0"
assert_eq "$(grep -c DENY "$SHIM_LOG")" "0" "D: dış ağa istek yok (kalkan DENY 0)"

test_summary
