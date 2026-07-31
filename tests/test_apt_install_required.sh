#!/bin/bash
# _apt_install_required (lib/init.sh) — kurulum başarısızlığında marker
# yazılmasın diye non-zero dönmesi ZORUNLU olan fail-closed kapı.
#
# NEDEN VAR: HOST BULGUSU (bkz. lib/init.sh başlık yorumu) — boot'ta
# cloud-init/unattended-upgrades apt lock'unu tuttuğu için
# 'apt-get install nginx' sessizce başarısız oldu ama _init_run_step yine de
# adımı "tamamlandı" işaretledi (marker yazıldı); ikinci 'srvctl init'
# çalıştırıldığında bu adım ATLANDI ve nginx hiç kurulmadan sistem
# "kurulum tamam" göründü. _apt_install_required BU yüzden var: apt
# başarısız olursa 1 DÖNMELİ ki çağıran (_init_step_system_update vb.)
# '|| return 1' ile zinciri kessin ve _init_run_step marker'ı YAZMASIN —
# bir sonraki 'srvctl init' adımı YENİDEN dener.
#
# Bu test gerçek apt-get'e ASLA dokunmaz: _apt_install (lib/init.sh'ın
# gerçek apt-get çağrısını yapan alt fonksiyonu) stub'lanır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/init.sh"

if ! declare -F _apt_install_required >/dev/null 2>&1; then
    echo "  SKIP: _apt_install_required henüz yok"
    rm -rf "$WEB_ROOT"
    test_summary
    exit 0
fi

# ═══════════════ Başarı: _apt_install 0 dönerse _apt_install_required da 0 döner ═══════════════
_apt_install() { return 0; }
assert_ok _apt_install_required "temel bağımlılıklar" curl wget

# ═══════════════ Başarısızlık: _apt_install 1 dönerse _apt_install_required 1 DÖNMELİ ═══════════════
# (regresyon: eskiden dönüş değeri kontrol edilmiyordu → adım "başarılı"
# sayılıp marker yazılıyordu — paket HİÇ kurulmamış olsa bile.)
_apt_install() { return 1; }
assert_fail _apt_install_required "temel bağımlılıklar" curl wget

# ═══════════════ Başarısızlıkta operatöre elle kurtarma komutu warn edilir ═══════════════
_apt_install() { return 1; }
warn_out="$(_apt_install_required "nginx" nginx 2>&1 1>/dev/null)"
assert_contains "$warn_out" "BAŞARISIZ" "başarısızlık warn mesajı üretiyor"
assert_contains "$warn_out" "apt-get install nginx" "elle kurtarma komutu warn'da gösteriliyor"

# ═══════════════ Argümanlar doğru iletiliyor: 'what' paket listesine KARIŞMIYOR ═══════════════
_apt_install_seen=""
_apt_install() { _apt_install_seen="$*"; return 0; }
_apt_install_required "temel bağımlılıklar" pkgA pkgB pkgC >/dev/null 2>&1
assert_eq "$_apt_install_seen" "pkgA pkgB pkgC" \
    "'what' (1. argüman) apt-get paket listesine karışmıyor, yalnız gerçek paketler iletiliyor"

rm -rf "$WEB_ROOT"
test_summary
