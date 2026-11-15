#!/bin/bash
# BLOKER (up-guvenlik K3): tls-default (ssl_reject_handshake) açıkken SNI'sız yerel sonda 000 verir ve http'ye düşüp
# 301 görürdü. _deploy_http_code artık HER ZAMAN alan adıyla ve `--resolve <alan>:<port>:127.0.0.1` ile çağırır (SNI gider);
# URL'de çıplak IP (https://127.0.0.1/) KALMAZ. curl taklidi çağrıları günlükler.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
STUBS="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"
trap 'rm -rf "${WEB_ROOT:?}" "${STUBS:?}"' EXIT

CURL_LOG="${STUBS}/curl.log"; : > "$CURL_LOG"
# SNI'sız (çıplak IP URL'li) çağrı → "000" (tls-default el sıkışmayı reddeder); alanlı + --resolve → CURL_CODE
curl() {
    local a url="" res="" prev=""
    echo "$*" >> "$CURL_LOG"
    for a in "$@"; do
        [[ "$prev" == "--resolve" ]] && res="$a"
        case "$a" in http://*|https://*) url="$a" ;; esac
        prev="$a"
    done
    case "$url" in
        https://127.0.0.1*|http://127.0.0.1*) printf '000'; return 7 ;;
    esac
    if [[ "$url" == https://* && "$res" == "example.com:443:127.0.0.1" ]]; then printf '%s' "${CURL_CODE_HTTPS:-200}"; return 0; fi
    if [[ "$url" == http://* && "$res" == "example.com:80:127.0.0.1" ]]; then printf '%s' "${CURL_CODE_HTTP:-301}"; return 0; fi
    printf '000'; return 7
}

echo "── A: tls-default benzetimi: SNI'sız IP çağrısı 000, alanlı --resolve çağrısı 200 ──"
assert_eq "$(_deploy_http_code example.com)" "200" "https sondası SNI ile (--resolve) 200 alır"
assert_contains "$(cat "$CURL_LOG")" "--resolve example.com:443:127.0.0.1" "https çağrısı --resolve <alan>:443:127.0.0.1 taşır"
assert_contains "$(cat "$CURL_LOG")" "https://example.com/" "URL alan adıdır"
assert_not_contains "$(cat "$CURL_LOG")" "https://127.0.0.1" "çıplak IP'li https URL'si KALMADI (SNI gitmezdi)"

echo "── B: 443 dinlemiyor (SSL'siz alan) → http'ye düşer, o da --resolve ile ──"
: > "$CURL_LOG"
curl() {
    local a url="" res="" prev=""
    echo "$*" >> "$CURL_LOG"
    for a in "$@"; do [[ "$prev" == "--resolve" ]] && res="$a"; case "$a" in http://*|https://*) url="$a" ;; esac; prev="$a"; done
    if [[ "$url" == http://example.com/ && "$res" == "example.com:80:127.0.0.1" ]]; then printf '200'; return 0; fi
    printf '000'; return 7
}
assert_eq "$(_deploy_http_code example.com)" "200" "https 000 → http --resolve düşüşü 200"
assert_contains "$(cat "$CURL_LOG")" "--resolve example.com:80:127.0.0.1" "http düşüşü de --resolve <alan>:80:127.0.0.1"
assert_not_contains "$(cat "$CURL_LOG")" "http://127.0.0.1" "çıplak IP'li http URL'si KALMADI"

echo "── C: güvensiz alan adı sondaya HİÇ ulaşmaz ──"
: > "$CURL_LOG"
assert_eq "$(_deploy_http_code 'a b;c')" "000" "geçersiz alan → 000"
assert_eq "$(wc -c < "$CURL_LOG" | tr -d ' ')" "0" "geçersiz alanda curl çağrılmadı"

echo "── D: yapısal — lib genelinde 127.0.0.1 hedefli SNI'sız curl yok ──"
bad=$(grep -nE 'curl[^|]*https?://127\.0\.0\.1' "${REPO_ROOT}"/lib/*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)
assert_eq "$bad" "" "lib/*.sh içinde 'curl … http(s)://127.0.0.1' kalmadı"
test_summary
