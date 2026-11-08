#!/bin/bash
# QL5-L15/C2: `domain clone` — hedef domain OLUŞTURULDUKTAN SONRA override dosyaları kopyalanamazsa klon DURUR
# (error → rc≠0; dosya/DB kopyasına GEÇİLMEZ), sessizce sürmez. Hedef zaten oluştuğu için ileti 'domain remove' yolunu söyler.
#   A  conf_files rc 1 → klon rc≠0, ileti 'override dosyaları kopyalanmadı' + 'domain remove', rsync (adım 2/4) ÇALIŞMADI
#   B  pozitif kontrol: conf_files rc 0 → akış adım 2/4'e (rsync) ULAŞIR (A'nın "rsync yok" sonucu anlamlı)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export WEB_ROOT="${T}/www"; mkdir -p "${WEB_ROOT}/kaynak.test/public_html"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/domain.sh"
set +e
EV="${T}/ev.log"
domain_exists() { [[ "$1" == "kaynak.test" ]]; }
_derive_php() { echo "8.3"; }
_domain_clone_conf_scan() { return 0; }
_domain_add() { echo "ADD $*" >> "$EV"; mkdir -p "${WEB_ROOT}/${1}"; }
rsync() { echo "RSYNC" >> "$EV"; exit 77; }
CF_RC=1
_domain_clone_conf_files() { return "$CF_RC"; }
_run() { : > "$EV"; ( _domain_clone kaynak.test hedef.test ) >"${T}/out.txt" 2>&1; echo $? > "${T}/rc"; }

echo "── A: override kopyalama BAŞARISIZ → klon durur ──"
CF_RC=1; _run
assert_eq "$([[ "$(cat "${T}/rc")" != 0 && "$(cat "${T}/rc")" != 77 ]] && echo red || echo "rc=$(cat "${T}/rc")")" "red" "A: klon rc≠0 (rsync tuzağı 77 değil)"
assert_contains "$(cat "${T}/out.txt")" "override dosyaları kopyalanmadı" "A: neden söylendi"
assert_contains "$(cat "${T}/out.txt")" "srvctl domain remove hedef.test" "A: oluşmuş hedef için çıkış yolu söylendi"
assert_contains "$(cat "$EV")" "ADD hedef.test" "A: (kontrol) hedef domain oluşturuldu — hata bundan SONRA"
assert_not_contains "$(cat "$EV")" "RSYNC" "A: dosya kopyalama (adım 2/4) ÇALIŞMADI"

echo "── B: pozitif kontrol — kopyalama başarılıysa adım 2/4'e ulaşılır ──"
CF_RC=0; _run
assert_eq "$(cat "${T}/rc")" "77" "B: rsync tuzağına ulaşıldı (akış sürdü)"
assert_contains "$(cat "$EV")" "RSYNC" "B: adım 2/4 çalıştı"

test_summary
