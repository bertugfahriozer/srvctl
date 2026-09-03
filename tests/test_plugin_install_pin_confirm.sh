#!/bin/bash
# Y4 regresyonu (haftalık denetim 2026-09): 'plugin install' HEAD'i pin/imza
# olmadan klonlayıp root olarak source/bash ediyordu; 'chown -R root:root'
# sahiplik kapılarını anlamsız kılıyordu. Artık: commit gösterilir, imzalı tag
# denenir, root çalıştırma ÖNCESİ onay istenir (--yes ile atlanır), commit
# .pinned-commit'e yazılır; dizin kaynağının sahipliği KOPYADAN ÖNCE doğrulanır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
export SRVCTL_ROOT="$(mktemp -d)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/plugin.sh"
_run() { ( "$@" ) 2>&1; }

# Yerel bir "uzak" git deposu hazırla
SRC="$(mktemp -d)"; git -C "$SRC" init -q; git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
printf 'PLUGIN_VERSION=1.2.3\nPLUGIN_DESCRIPTION="test"\n' > "$SRC/plugin.conf"
printf '#!/bin/bash\ncmd_demo() { echo demo; }\n' > "$SRC/main.sh"
git -C "$SRC" add -A; git -C "$SRC" commit -qm init
HEAD="$(git -C "$SRC" rev-parse HEAD)"
# https:// yerine yerel yol için _plugin_validate_source'u ve klonu sararız:
_plugin_validate_source() { return 0; }
git() { if [[ "$1" == "clone" ]]; then GIT_ALLOW_PROTOCOL=file command git clone -q -- "$SRC" "${@: -1}"; else command git "$@"; fi; }

# 1) onay REDDEDİLİRSE hiçbir şey kurulmaz, dizin silinir
confirm() { return 1; }
out=$(_run _plugin_install "https://example.com/demo.git")
assert_contains "$out" "Commit : ${HEAD}" "commit hash'i onaydan ÖNCE gösteriliyor"
assert_contains "$out" "imzalı tag YOK" "imza durumu gösteriliyor"
assert_contains "$out" "root olarak 'source'/'bash' EDİLECEK" "operatör uyarılıyor"
assert_contains "$out" "iptal" "ret → iptal"
assert_eq "$([[ -d "${SRVCTL_PLUGINS_DIR}/demo" ]] && echo var || echo yok)" "yok" "ret → plugin dizini kalmadı"

# 2) --yes ile onay atlanır, .pinned-commit yazılır
confirm() { echo "CONFIRM ÇAĞRILDI"; return 1; }
out=$(_run _plugin_install "https://example.com/demo.git" --yes)
assert_not_contains "$out" "CONFIRM ÇAĞRILDI" "--yes: confirm çağrılmadı"
assert_contains "$out" "Plugin yüklendi: demo" "--yes: kuruldu"
assert_eq "$(cat "${SRVCTL_PLUGINS_DIR}/demo/.pinned-commit" 2>/dev/null)" "$HEAD" ".pinned-commit HEAD hash'ini içeriyor"
assert_contains "$(_run _plugin_list)" "${HEAD:0:12}" "plugin list pinlenmiş commit'i gösteriyor"
rm -rf "${SRVCTL_PLUGINS_DIR:?}/demo"

# 3) dizin kaynağı: root'a ait olmayan / grup-yazılabilir kaynak REDDEDİLİR
DIRSRC="$(mktemp -d)"; cp "$SRC/plugin.conf" "$SRC/main.sh" "$DIRSRC/"
chmod 664 "$DIRSRC/main.sh"
assert_fail _plugin_assert_source_dir_trusted "$DIRSRC"
out=$(_run _plugin_install "$DIRSRC" --yes)
assert_contains "$out" "Plugin kaynağı reddedildi" "grup-yazılabilir dizin kaynağı reddedildi"
chmod 644 "$DIRSRC/main.sh"; chmod 755 "$DIRSRC"
assert_ok _plugin_assert_source_dir_trusted "$DIRSRC"
ln -s /etc/passwd "$DIRSRC/link"
assert_fail _plugin_assert_source_dir_trusted "$DIRSRC"   # içeride symlink → güvenilmez
rm -f "$DIRSRC/link"

# 4) imzalı tag durumu: tag var ama imza doğrulanamıyor → dürüst metin
command git -C "$SRC" tag v1 >/dev/null
assert_contains "$(_plugin_signature_state "$SRC" "$HEAD")" "DOĞRULANAMADI" "imzasız tag → 'doğrulanamadı' (asla 'doğrulandı' değil)"

# 5) eski 'chown -R root:root' artık kapıyı gölgelemiyor (yapısal)
assert_contains "$(cat "${REPO_ROOT}/lib/plugin.sh")" '_plugin_assert_source_dir_trusted "$source"' "dizin kaynağı kopyadan ÖNCE doğrulanıyor"

rm -rf "$SRVCTL_ROOT" "$WEB_ROOT" "$SRC" "$DIRSRC"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
