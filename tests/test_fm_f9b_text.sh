#!/bin/bash
# F9b/a2 — §15/33 "otomatik yollar ASLA açmaz" ilkesinin OPERATÖRE DÖNÜK METİNLERİ.
# Eski iddia ("acil kapatılmış alanı repair/fm-root yeniden açabilir") F9b'den sonra YANLIŞ: repair/fm-root alanı hiçbir koşulda
# açmaz, yalnız açık `fm-auth <alan> on` açar. (1) DAVRANIŞ: fm-root --apply başarısız olunca basılan iki uyarı (self-update geçiş
# yönlendirmesi + sunum) yeni cümleyi taşır, eskisini taşımaz. (2) KAYNAK: lib/ bin/ completions/ docs/ README.md eski iddiayı içermez.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
PD="$(mktemp -d)"; trap 'rm -rf "$PD"' EXIT
warn_of() {
    ( set +e
      source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/selfupdate.sh" >/dev/null 2>&1
      confirm() { return 0; }
      cmd_domain() { return 1; }
      warn() { printf '%s\n' "$*" >> "${PD}/warns"; }
      info() { :; }
      case "$1" in
        redirect) _selfupdate_run() { _domain_selfupdate_transition_redirect; }; _selfupdate_run ;;
        offer)    _selfupdate_offer_fm_root ;;
      esac ) >/dev/null 2>&1
    cat "${PD}/warns" 2>/dev/null; rm -f "${PD}/warns"
}
NEW="repair/fm-root alanı hiçbir koşulda açmaz — yalnız açık 'fm-auth <alan> on' açar"
for sc in redirect offer; do
    W="$(warn_of "$sc")"
    assert_contains "$W" "fm-root --apply tamamlanamadı" "[$sc] başarısız --apply uyarısı basılıyor (ön koşul)"
    assert_contains "$W" "$NEW" "[$sc] yeni metin: repair/fm-root hiçbir koşulda açmaz, yalnız açık 'fm-auth <alan> on' açar"
    assert_not_contains "$W" "yeniden açabilir" "[$sc] eski 'yeniden açabilir' iddiası yok"
done
# Kaynak taraması (tests/ HARİÇ: testler eski metni ret için anar). Eski iddia: bir satırda repair/fm-root ile "yeniden aç(abilir)".
for t in lib bin completions docs README.md; do
    [[ -e "${REPO_ROOT}/${t}" ]] || continue
    hits="$(grep -rnIE 'repair/fm-root.*(yeniden aç(abilir|ar)|açabilir)' "${REPO_ROOT}/${t}" 2>/dev/null | grep -v 'AÇAMAZ' | grep -v 'açmaz')"
    if [[ -n "$hits" ]]; then printf '      %s\n' "$hits"; fi
    assert_eq "$([[ -z "$hits" ]] && echo temiz || echo eski-iddia)" "temiz" "${t}: 'repair/fm-root ... yeniden açabilir' iddiası yok"
done
assert_contains "$(cat "${REPO_ROOT}/README.md")" "$NEW" "README rc 6 satırı yeni cümleyi taşır"
test_summary
