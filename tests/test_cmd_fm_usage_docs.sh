#!/bin/bash
# QL7-L3: `fm-auth` kullanım yüzeyleri koddaki seçenek ayrıştırıcısıyla AYNI olmalı. Eskiden bin/srvctl kullanım satırı
# `--force`/`--emergency`'i anmıyordu, `domain help` "off hepsini kaldırır" diyordu (acil yolda 90/21 SİLİNMİYOR,
# `*.srvctl-emergency.*` adıyla kenara alınıyor). Kaynak: `_domconf_fm_auth` içindeki `case "$arg"` seçenekleri (YORUM HARİÇ).
# Yüzeyler: (1) `srvctl help` (bin/srvctl'in GERÇEK çıktısı; SRVCTL_ROOT kopyada repoya çevrilir), (2) `domain help`,
# (3) bash tamamlama, (4) zsh tamamlama. Bir seçenek koda eklenir de bir yüzeyde eksik kalırsa test kırılır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- kod: seçenek ayrıştırıcısı (yorum hariç; tırnak-bilinçli) ---
FN="$(awk '/^_domconf_fm_auth\(\)/{f=1} f{print} f&&/^}/{exit}' "${REPO_ROOT}/lib/domconf.sh" | grep -vE '^[[:space:]]*#')"
FLAGS="$(grep -oE '^[[:space:]]+--[a-z]+[=)*]' <<< "$FN" | tr -d ' \t=)*' | sort -u | tr '\n' ' ')"
assert_eq "$FLAGS" "--dry --emergency --force --region --script " "(ön koşul) ayrıştırıcıdaki seçenekler çıkarıldı (kod: _domconf_fm_auth)"

# --- (1) bin/srvctl help: gerçek çıktı ---
sed "s#^SRVCTL_ROOT=\"/usr/local/srvctl\"#SRVCTL_ROOT=\"${REPO_ROOT}\"#" "${REPO_ROOT}/bin/srvctl" > "${T}/srvctl"
HELP="$(bash "${T}/srvctl" help 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
LINE="$(grep 'domain fm-auth' <<< "$HELP" | head -1)"
assert_contains "$LINE" "domain fm-auth" "(ön koşul) srvctl help fm-auth satırını basıyor"
for f in $FLAGS; do assert_contains "$LINE" "$f" "srvctl help: fm-auth satırı ${f} seçeneğini anıyor"; done

# --- (2) domain help ---
DH="$(
  set +e
  source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
  require_root() { :; }
  source "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1
  cmd_domain help 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
)"
BLK="$(awk '/fm-auth <domain> <on\|off\|status>/{f=1} /fm-root <domain>\|--all/{f=0} f' <<< "$DH")"
assert_contains "$BLK" "FileManager (OPT-IN" "(ön koşul) domain help fm-auth bloğu çıkarıldı"
for f in $FLAGS; do assert_contains "$BLK" "$f" "domain help: fm-auth bloğu ${f} seçeneğini anıyor"; done
assert_not_contains "$BLK" "hepsini kaldırır" "domain help: 'off hepsini kaldırır' YOK (acil yolda kenara alınır)"
assert_contains "$BLK" "srvctl-emergency" "domain help: acil yolun kenara alma adı anılıyor"
assert_contains "$BLK" ".superseded.bk" "domain help: ayrılmış yarım-işlem yedeği anılıyor"
assert_contains "$BLK" "srvctl-tampered" "domain help: kayıtsız FM adının devralınması anılıyor"

# --- (3) bash tamamlama: fm-auth seçenek listesi (gerçek çalıştırma) ---
BC="$(bash -c '
  source "$1/completions/srvctl.bash"
  COMP_WORDS=(srvctl domain fm-auth example.com off -); COMP_CWORD=5
  _srvctl_completions
  printf "%s\n" "${COMPREPLY[@]}"' _ "$REPO_ROOT" 2>&1)"
for f in $FLAGS; do
    case "$f" in --script|--region) want="${f}=" ;; *) want="$f" ;; esac
    assert_contains "$BC" "$want" "bash tamamlama: ${want}"
done

# --- (4) zsh tamamlama: gerçek çalıştırma (zsh yoksa gerekçeli atla) ---
if command -v zsh >/dev/null 2>&1; then
    Z="$(ZSHC="${REPO_ROOT}/completions/srvctl.zsh" zsh -f -c '
      compdef() { :; }; _arguments() { state=args; return 0; }
      _describe() { local a; for a in "${(@P)2}"; do print -r -- "ENTRY $a"; done; }
      words=(domain fm-auth example.com off); source "$ZSHC"' 2>&1)"
    for f in $FLAGS; do
        case "$f" in --script|--region) want="ENTRY ${f}=:" ;; *) want="ENTRY ${f}:" ;; esac
        assert_contains "$Z" "$want" "zsh tamamlama: ${f}"
    done
else
    echo "  SKIP zsh bulunamadı: zsh tamamlama seçenek denetimi atlandı (koşturulacak yorumlayıcı yok)"
fi
test_summary
