#!/bin/bash
# _ask (install.sh) — TTY yokken yön-bazlı etkileşimsiz varsayılan.
#
# NEDEN VAR: HOST BULGUSU (Ubuntu 24.04, gerçek VM) — install.sh mevcut bir
# kurulumun üzerine çalıştırıldığında "Üzerine yazmak istiyor musunuz?" diye
# SORUYORDU. stdin'i olmayan her ortamda (CI, Ansible, cron, 'srvctl
# self-update' sonrası, arka plan) bu soru SÜRESİZ ASILI KALIYORDU. Düzeltme:
# TTY yoksa (ya da '--yes' verilmişse) soru sorulmaz ama varsayılan YÖNE GÖRE
# ayrılır:
#   • "üzerine yaz" (rutin, conf zaten korunuyor)         → EVET
#   • "desteklenmeyen OS'ta devam et" (fail-closed karar) → HAYIR
# Bu iki varsayılanın YANLIŞLIKLA birbirine karışması/ters dönmesi ciddi
# sonuç doğurur: "üzerine yaz"ın varsayılanı hayır olursa install.sh her
# yeniden çalıştırmada (CI/otomasyonda) asılı kalmaya GERİ döner; "desteklenmeyen
# OS"un varsayılanı evet olursa install.sh bilinmeyen/test edilmemiş bir
# dağıtıma SESSİZCE kurulum yapar.
#
# install.sh KENDİSİ root kontrolü + 'set -euo pipefail' + gerçek mkdir/cp/
# chown içeren TAM bir script'tir — source EDİLEMEZ (root gerektirir, yan
# etkili). Bu yüzden yalnız '_ask' fonksiyonunun GÖVDESİ metinsel olarak
# çıkarılıp (sed ile — GNU/BSD sed'de aynı davranan basit bir adres aralığı)
# izole bir alt-kabukta tanımlanır; script'in geri kalanı HİÇ ÇALIŞTIRILMAZ.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

_ask_body="$(sed -n '/^_ask() {/,/^}/p' "${REPO_ROOT}/install.sh")"

if [[ -z "$_ask_body" ]]; then
    echo "  SKIP: install.sh içinde _ask() fonksiyonu bulunamadı (imza değişmiş olabilir)"
    test_summary
    exit 0
fi

eval "$_ask_body"

if ! declare -F _ask >/dev/null 2>&1; then
    echo "  SKIP: _ask çıkarıldı ama tanımlanamadı"
    test_summary
    exit 0
fi

# ═══════════════ TTY YOK (ASSUME_YES=true) — gerçek install.sh'ın '[[ -t 0 ]] || ASSUME_YES=true' sonrası hali ═══════════════
ASSUME_YES=true

# "üzerine yaz" → varsayılan 'evet' → devam ET (0)
assert_ok   _ask "Üzerine yazmak istiyor musunuz?" "evet"
# "desteklenmeyen OS" → varsayılan 'hayir' → İPTAL (1)
assert_fail _ask "Desteklenmeyen sürümde devam etmek istiyor musunuz?" "hayir"
# Ubuntu-olmayan dağıtım uyarısı da aynı 'hayir' varsayılanını kullanıyor
assert_fail _ask "Devam etmek istiyor musunuz?" "hayir"

# ═══════════════ TTY VAR (ASSUME_YES=false) — okuma stdin'den yapılır, varsayılan YOK SAYILIR ═══════════════
ASSUME_YES=false
ask_with_input() {
    local input="$1"; shift
    printf '%s\n' "$input" | _ask "$@"
}
assert_ok   ask_with_input "evet"  "Üzerine yazmak istiyor musunuz?" "hayir"   # kullanıcı açıkça 'evet' derse varsayılan önemsiz
assert_fail ask_with_input "hayır" "Üzerine yazmak istiyor musunuz?" "evet"    # kullanıcı açıkça reddederse varsayılan önemsiz
assert_fail ask_with_input ""      "Üzerine yazmak istiyor musunuz?" "evet"    # boş cevap = hayır (yalnız tam 'evet' kabul)
assert_fail ask_with_input "EVET"  "Üzerine yazmak istiyor musunuz?" "evet"    # büyük harf kabul EDİLMEZ (tam string eşleşmesi)

# ═══════════════ Regresyon kilidi: gerçek çağrı siteleri hâlâ doğru varsayılanı kullanıyor ═══════════════
# _ask'in KENDİSİ doğru çalışsa bile, çağıran taraf yanlışlıkla
# '"Üzerine yazmak istiyor musunuz?" "hayir"' ya da
# '"...desteklenmeyen sürümde..." "evet"' yazarsa yukarıdaki güvenlik
# gerekçesi SESSİZCE tersine döner — bu yüzden gerçek satırlar da sabitlenir.
install_src="$(cat "${REPO_ROOT}/install.sh")"
assert_contains "$install_src" '_ask "Üzerine yazmak istiyor musunuz?" "evet"' \
    "gerçek çağrı: 'üzerine yaz' hâlâ varsayılan 'evet' ile çağrılıyor"
assert_contains "$install_src" '_ask "Desteklenmeyen sürümde devam etmek istiyor musunuz?" "hayir"' \
    "gerçek çağrı: 'desteklenmeyen sürüm' hâlâ varsayılan 'hayir' ile çağrılıyor"
assert_contains "$install_src" '_ask "Devam etmek istiyor musunuz?" "hayir"' \
    "gerçek çağrı: 'Ubuntu değil' uyarısı hâlâ varsayılan 'hayir' ile çağrılıyor"

test_summary
