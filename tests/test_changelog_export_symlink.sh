#!/bin/bash
# O1 regresyonu (haftalık denetim 2026-09): 'changelog export' varsayılanı
# öngörülebilir '/tmp/srvctl-changelog-YYYYMMDD.txt' idi; root 'cp' symlink'i
# izleyip hedefi ÜZERİNE YAZIYORDU. Artık: symlink/düz-dosya/sahiplik kapısı,
# varsayılan yol SRVCTL_ROOT/logs, umask 077 + 0600.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
export SRVCTL_ROOT="$(mktemp -d)"
mkdir -p "${SRVCTL_ROOT}/logs"
source "${REPO_ROOT}/lib/changelog.sh"
printf '2026-09-01 10:00:00|root|DOMAIN ADD: a.com\n' > "$CHANGELOG_FILE"
_run() { ( "$@" ) 2>&1; }
WORK="$(mktemp -d)"

# 1) sembolik bağ hedef → REDDEDİLİR, hedef dokunulmaz
SENT="${WORK}/sentinel"; printf 'ORIJINAL\n' > "$SENT"
ln -s "$SENT" "${WORK}/export.txt"
out=$(_run _changelog_export "${WORK}/export.txt")
assert_fail _run _changelog_export "${WORK}/export.txt"
assert_contains "$out" "sembolik bağ" "symlink hedef reddedildi"
assert_eq "$(cat "$SENT")" "ORIJINAL" "symlink hedefi ÜZERİNE YAZILMADI"

# 2) mevcut düz dosya ama root'a ait DEĞİL (saldırganın önceden koyduğu 0666) → reddedilir
PRE="${WORK}/pre.txt"; : > "$PRE"; chmod 666 "$PRE"
if chown nobody "$PRE" 2>/dev/null; then
    assert_fail _run _changelog_export "$PRE"
    assert_eq "$(wc -c < "$PRE")" "0" "root'a ait olmayan mevcut dosyaya yazılmadı"
else
    echo "  (chown nobody mümkün değil — sahiplik senaryosu atlandı)"
fi

# 3) dizin hedef → reddedilir
assert_fail _run _changelog_export "$WORK"

# 4) varsayılan yol artık /tmp DEĞİL, SRVCTL_ROOT/logs altında ve 0600
out=$(_run _changelog_export)
assert_contains "$out" "${SRVCTL_ROOT}/logs/changelog-" "varsayılan çıktı SRVCTL_ROOT/logs altında"
assert_not_contains "$out" "/tmp/srvctl-changelog" "varsayılan artık /tmp'de değil"
f="$(ls "${SRVCTL_ROOT}"/logs/changelog-*.txt | head -1)"
assert_eq "$(stat -c %a "$f")" "600" "dışa aktarılan dosya 0600"
assert_contains "$(cat "$f")" "DOMAIN ADD: a.com" "içerik doğru"

# 5) kontrol: açıkça verilen yeni düz yol çalışır
assert_ok _run _changelog_export "${WORK}/ok.txt"
assert_eq "$(stat -c %a "${WORK}/ok.txt")" "600" "açık yol: 0600"

rm -rf "$WORK" "$SRVCTL_ROOT"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
