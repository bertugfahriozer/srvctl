#!/bin/bash
# rev-L8: `srvctl domain` alt komutları ana yardımda VE kabuk tamamlamalarında eksiksiz.
# Kaynak = lib/domain.sh cmd_domain dağıtıcısının case etiketleri (gerçekte çalıştırılan küme).
#   A  ana yardım GERÇEKTEN işletilir (bin/srvctl help; SRVCTL_ROOT depoya çevrilmiş kopya) ve her
#      etiket "domain <etiket>" girdisiyle listelenir; yardımda dağıtıcıda olmayan girdi YOK
#   B  completions/srvctl.bash domain_cmds = dağıtıcı kümesi (bire bir)
#   C  completions/srvctl.zsh domain_cmds dizisi = dağıtıcı kümesi (bire bir)
#   D  F4'te eklenen/dokunulan komutlar ayrıca adıyla: fm-auth fm-root staging repair open-basedir nginx-audit
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
set +e
BIN="${PARITY_BIN:-${REPO_ROOT}/bin/srvctl}"        # mutasyon kancaları
LIBD="${PARITY_DOMAIN_LIB:-${REPO_ROOT}/lib/domain.sh}"
CB="${PARITY_BASH_COMP:-${REPO_ROOT}/completions/srvctl.bash}"
CZ="${PARITY_ZSH_COMP:-${REPO_ROOT}/completions/srvctl.zsh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# dağıtıcı: cmd_domain() gövdesindeki İLK case … esac bloğunun "    etiket)" satırları
labels=$(awk '/^cmd_domain\(\)/{f=1} f&&/^    case /{c=1;next} c&&/^    esac/{exit} c&&/^        [a-z][a-z|-]*\)/{l=$1; sub(/\).*/,"",l); n=split(l,a,"|"); for(i=1;i<=n;i++) print a[i]}' "$LIBD" | LC_ALL=C sort -u)
assert_eq "$(( $(printf '%s\n' "$labels" | grep -c .) >= 20 ? 1 : 0 ))" "1" "(ön koşul) dağıtıcıdan >=20 etiket çıkarıldı ($(printf '%s\n' "$labels" | grep -c .))"

echo "── A: ana yardım (işletilerek) ──"
sed "s#^SRVCTL_ROOT=\"/usr/local/srvctl\"#SRVCTL_ROOT=\"${REPO_ROOT}\"#" "$BIN" > "${T}/srvctl"
assert_eq "$(grep -c "^SRVCTL_ROOT=\"${REPO_ROOT}\"" "${T}/srvctl")" "1" "(ön koşul) kopyada SRVCTL_ROOT depoya çevrildi"
help=$(SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf" SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf" \
       bash "${T}/srvctl" help 2>&1 </dev/null | sed 's/\x1b\[[0-9;]*m//g'); hrc=$?
assert_eq "$hrc" "0" "srvctl help rc 0"
hl=$(printf '%s\n' "$help" | sed -n 's/^    domain \([a-z][a-z-]*\).*/\1/p' | LC_ALL=C sort -u)
assert_eq "$(comm -23 <(printf '%s\n' "$labels") <(printf '%s\n' "$hl") | tr '\n' ' ')" "" "dağıtıcıdaki HER domain alt komutu ana yardımda"
assert_eq "$(comm -13 <(printf '%s\n' "$labels") <(printf '%s\n' "$hl") | tr '\n' ' ')" "" "ana yardımda dağıtıcıda OLMAYAN domain girdisi yok"

echo "── B: bash tamamlama ──"
bl=$(sed -n 's/.*local domain_cmds="\([^"]*\)".*/\1/p' "$CB" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
assert_eq "$(printf '%s\n' "$bl" | grep -c .)" "$(printf '%s\n' "$labels" | grep -c .)" "bash domain_cmds sayısı = dağıtıcı"
assert_eq "$(diff <(printf '%s\n' "$labels") <(printf '%s\n' "$bl") | grep '^[<>]' | tr '\n' ' ')" "" "bash domain_cmds = dağıtıcı (bire bir)"

echo "── C: zsh tamamlama ──"
zl=$(awk '/local -a domain_cmds/{f=1;next} f&&/domain_cmds=\(/{c=1;next} c&&/^[[:space:]]*\)/{exit} c' "$CZ" | sed -n "s/^[[:space:]]*'\([a-z][a-z-]*\):.*/\1/p" | LC_ALL=C sort -u)
assert_eq "$(diff <(printf '%s\n' "$labels") <(printf '%s\n' "$zl") | grep '^[<>]' | tr '\n' ' ')" "" "zsh domain_cmds = dağıtıcı (bire bir)"

echo "── D: F4 komutları adıyla ──"
for c in fm-auth fm-root staging repair open-basedir nginx-audit; do
    assert_contains "$help" "    domain ${c} " "ana yardım: domain ${c}"
    assert_contains " $(printf '%s\n' "$bl" | tr '\n' ' ') " " ${c} " "bash tamamlama: ${c}"
    assert_contains " $(printf '%s\n' "$zl" | tr '\n' ' ') " " ${c} " "zsh tamamlama: ${c}"
done

test_summary
