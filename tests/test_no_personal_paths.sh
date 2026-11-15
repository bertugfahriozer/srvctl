#!/bin/bash
# QL8-L8: PR'a girecek dosyalarda kişisel yol / iç lab / geçici çalışma alanı göndermesi YOK.
# Yerel makine yolları (ev dizini, çalışma kopyası, ajan geçici alanı) ve iç tasarım defterine "bkz." atıfları
# kullanıcının deposunda anlamsızdır ve bir kişiyi/ortamı ifşa eder. Tarama TÜM ağaçta yapılır (git gerekmez:
# kopya ağaçlarda .git yoktur); tek istisna, depoda ZATEN commit'li (73be92f) tarihsel bir plan belgesidir —
# PR yüzeyinde değildir. Desenler parçalı kurulur ki bu dosyanın kendisi eşleşmesin.
# Pozitif kontrol: aynı tarayıcı geçici bir ağaçta bilerek konan her desen için bulgu VERMELİ (boş tarama sahte yeşil olmasın);
# kontrol dosyaları desen DEĞİŞKENLERİNDEN değil bağımsız literallerden üretilir (desen bozulursa kontrol de sessizce uyumlanmasın).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

_P_USERS="/Use""rs/"
_P_PTMP="/private/""tmp/"
_P_WORK="wgart""-work"
_P_DEVB="devil""box"
_P_SCRATCH="scratch""pad/"
PATTERN="${_P_USERS}|${_P_PTMP}|${_P_WORK}|${_P_DEVB}|${_P_SCRATCH}"
LEGACY_REL="docs/superpowers/plans/2026-06-30-srvctl-security-hardening-phase1.md"

# $1 = ağaç kökü → eşleşen göreli dosya yolları (satır başına bir)
scan_tree() {
    local root="$1" f rel
    while IFS= read -r f; do
        rel="${f#"${root}"/}"
        [[ "$rel" == "$LEGACY_REL" ]] && continue
        [[ "$rel" == tests/test_no_personal_paths.sh ]] && continue
        if grep -Iq -E -e "$PATTERN" -- "$f" 2>/dev/null; then
            printf '%s\n' "$rel"
        fi
    done < <(find "$root" \( -name .git -o -name __pycache__ \) -prune -o -type f -print | sort)
}

echo "── A: pozitif kontrol — tarayıcı her deseni yakalar ──"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "${T}/lib" "${T}/tests/fuzz/seeds/poc" "${T}/.git" "${T}/docs/superpowers/plans"
printf '# bkz. %s\n' "/Use""rs/biri/x" > "${T}/lib/a.sh"
printf 'include %sclaude-501/x;\n' "/private/""tmp/" > "${T}/tests/fuzz/seeds/poc/b.conf"
printf '# ~/%s/pcloud-v2\n' "wgart""-work" > "${T}/lib/c.sh"
printf '# %s/data/www\n' "devil""box" > "${T}/lib/d.sh"
printf '# bkz. %stask/context.md\n' "scratch""pad/" > "${T}/lib/e.sh"
printf 'temiz satır\n' > "${T}/lib/temiz.sh"
printf '%s\n' "/Use""rs/gizli" > "${T}/.git/config"            # .git taranmaz
printf '%s\n' "/Use""rs/tarihsel" > "${T}/${LEGACY_REL}"        # tarihsel commit'li belge atlanır
GOT="$(scan_tree "$T" | tr '\n' ' ')"
assert_eq "$GOT" "lib/a.sh lib/c.sh lib/d.sh lib/e.sh tests/fuzz/seeds/poc/b.conf " "pozitif: 5 deseni yakalar; .git, tarihsel belge ve temiz dosya dışarıda"

echo "── B: gerçek ağaç — PR yüzeyinde kişisel yol / iç göndermesi 0 ──"
REAL="$(scan_tree "$REPO_ROOT")"
assert_eq "$REAL" "" "kişisel yol / iç lab göndermesi içeren dosya yok (bulunan: ${REAL//$'\n'/ })"
for s in ql12-vec-dev-lab-zz-test ql12-vec-work-attack ql3-m1-include-any-location; do
    assert_ok test -f "${REPO_ROOT}/tests/fuzz/seeds/poc/${s}.conf"
done
test_summary
