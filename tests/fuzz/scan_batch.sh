#!/bin/bash
# Fuzz sürücüsü: bir dosya LİSTESİ üzerinde lib/nginx_allow.sh tarayıcısını koşar.
# Kullanım: scan_batch.sh <liste-dosyası> <çıktı-dosyası>
#   çıktı: "@@ <yol> <tarayıcı_rc> <lexer_rc>" + "E <tür> <satır> <sözcük>\t<sözcük>…" (olaylar)
#          + "F <bulgu>" satırları. Sözcükler: \ → \\, LF → \n, CR → \r, TAB → \t.
# SRVCTL_NGXALLOW_LIB: mutant/alternatif kütüphane yolu (varsayılan lib/nginx_allow.sh)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"; export SRVCTL_ROOT
source "${REPO_ROOT}/lib/domconf.sh"
# shellcheck source=/dev/null
source "${SRVCTL_NGXALLOW_LIB:-${REPO_ROOT}/lib/nginx_allow.sh}"
list="$1"; out="$2"
: > "$out"
_enc() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
_ev_cb() {
    local t first=1 rec="E ${1} ${2} "
    shift 2
    for t in "$@"; do
        if (( first )); then first=0; else rec+=$'\t'; fi
        rec+="$(_enc "$t")"
    done
    printf '%s\n' "$rec" >> "$out"
    return 0
}
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rc=0; fo=$(_ngxallow_scan "$f" example.com 10-site.conf 2>&1) || rc=$?
    lrc=0; printf '@@ %s %s ' "$f" "$rc" >> "$out"
    # lexer olaylarını bir ara dosyaya yazdır: önce başlık satırını tamamla
    _tmp_ev="${out}.ev.$$"
    : > "$_tmp_ev"
    _save_out="$out"; out="$_tmp_ev"
    _domconf_nginx_parse "$f" _ev_cb || lrc=$?
    out="$_save_out"
    printf '%s\n' "$lrc" >> "$out"
    cat "$_tmp_ev" >> "$out"
    if [[ -n "$fo" ]]; then
        while IFS= read -r l; do printf 'F %s\n' "$l" >> "$out"; done <<< "$fo"
    fi
done < "$list"
rm -f "${out}.ev.$$"
