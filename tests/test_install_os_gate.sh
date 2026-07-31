#!/bin/bash
# install.sh OS kontrolü (VERSION_ID case bloğu) — Ubuntu 24.04'ün 22.04 ile
# birlikte BİRİNCİ SINIF desteklendiğinin regresyon kilidi.
#
# NEDEN VAR: install.sh'ın OS kapısı yalnızca "ID != ubuntu" kontrolü
# yaparken (VERSION_ID hiç bakılmıyordu), her Ubuntu sürümü (14.04 dahil)
# sessizce kabul ediliyordu. Şimdiki davranış: 22.04/24.04 SESSİZCE geçer;
# başka bir Ubuntu sürümü UYARI + 'evet' onayı ister (fail-closed DEĞİL —
# kilitlemez); Ubuntu olmayan dağıtımda da aynı şekilde uyarı+onay (mevcut
# davranış korunur). Bu test dördünü de gerçek install.sh kaynağından
# çıkarılan case bloğuyla, sahte bir os-release dosyasıyla doğrular.
#
# install.sh KENDİSİ root + gerçek mkdir/cp/chown içerdiğinden source
# EDİLEMEZ. Bu yüzden yalnız OS-kontrolü bloğu (bkz. install.sh
# "# ─── OS kontrolü ───" ... kapanış 'fi') metinsel olarak çıkarılıp izole
# bir alt-kabukta 'eval' edilir; script'in geri kalanı HİÇ ÇALIŞTIRILMAZ.
# Alt-kabuk kullanılmasının nedeni: blok içinde '_ask ... || exit 0' var —
# gerçek bir 'exit' test script'inin tamamını erken bitirir; alt-kabukta
# yalnız o alt-kabuğu bitirir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

_gate_body="$(sed -n '/^# ─── OS kontrolü ───/,/^fi$/p' "${REPO_ROOT}/install.sh")"

if [[ -z "$_gate_body" ]]; then
    echo "  SKIP: install.sh içinde OS kontrolü bloğu bulunamadı (yapı değişmiş olabilir)"
    test_summary
    exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/srvctl-os-gate-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

ASK_LOG="${WORKDIR}/ask.log"

# install.sh'ın üst kısmında tanımlı renk değişkenleri (blok bunları
# referans alıyor; testte boş yeterli — çıktı rengi test edilmiyor).
RED=''; YELLOW=''; NC=''

_write_os_release() {
    local file="$1" id="$2" ver="$3"
    if [[ -n "$ver" ]]; then
        printf 'ID=%s\nVERSION_ID="%s"\n' "$id" "$ver" > "$file"
    else
        # VERSION_ID satırı HİÇ yok — bozuk/eksik os-release senaryosu
        printf 'ID=%s\n' "$id" > "$file"
    fi
}

# $1 = os-release dosya yolu (yoksa boş string -> dosya hiç yaratılmaz)
# Dönüş: alt-kabuğun exit kodu. Yan etki: ASK_LOG'a "_ask" çağrıları yazılır.
_run_gate() {
    local os_release_path="$1"
    : > "$ASK_LOG"
    (
        SRVCTL_OS_RELEASE_FILE="$os_release_path"
        _ask() { echo "CALLED|$1|$2" >> "$ASK_LOG"; return 0; }
        eval "$_gate_body"
    )
}

# ═══════════════ 22.04/24.04 — sessizce geçmeli (birinci sınıf destek) ═══════════════
_write_os_release "${WORKDIR}/os-jammy" ubuntu 22.04
_run_gate "${WORKDIR}/os-jammy" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "" "Ubuntu 22.04: _ask hiç çağrılmadı (sessiz geçiş)"

_write_os_release "${WORKDIR}/os-noble" ubuntu 24.04
_run_gate "${WORKDIR}/os-noble" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "" "Ubuntu 24.04: _ask hiç çağrılmadı (sessiz geçiş — birinci sınıf destek)"

# ═══════════════ Desteklenmeyen Ubuntu sürümü — uyarı + onay (fail-closed DEĞİL) ═══════════════
_write_os_release "${WORKDIR}/os-old" ubuntu 20.04
_run_gate "${WORKDIR}/os-old" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "CALLED|Desteklenmeyen sürümde devam etmek istiyor musunuz?|hayir" \
    "Ubuntu 20.04: _ask 'desteklenmeyen sürüm' mesajıyla ve varsayılan 'hayir' ile çağrıldı"

_write_os_release "${WORKDIR}/os-future" ubuntu 25.04
_run_gate "${WORKDIR}/os-future" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "CALLED|Desteklenmeyen sürümde devam etmek istiyor musunuz?|hayir" \
    "Ubuntu 25.04: _ask 'desteklenmeyen sürüm' mesajıyla çağrıldı (henüz test edilmemiş sürüm de aynı yolu izler)"

# Bozuk/eksik os-release: ID=ubuntu ama VERSION_ID satırı yok -> '*' dalına düşmeli (fail-closed'a değil, uyarıya)
_write_os_release "${WORKDIR}/os-noversion" ubuntu ""
_run_gate "${WORKDIR}/os-noversion" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "CALLED|Desteklenmeyen sürümde devam etmek istiyor musunuz?|hayir" \
    "VERSION_ID eksik: bilinmeyen sürüm sayılıp uyarı yolu izleniyor (sessizce geçilmiyor)"

# ═══════════════ Ubuntu olmayan dağıtım — mevcut davranış (uyarı + onay) korunmalı ═══════════════
_write_os_release "${WORKDIR}/os-debian" debian 12
_run_gate "${WORKDIR}/os-debian" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "CALLED|Devam etmek istiyor musunuz?|hayir" \
    "Debian: _ask 'Ubuntu değil' mesajıyla ve varsayılan 'hayir' ile çağrıldı"

# ═══════════════ /etc/os-release hiç yoksa — blok hiç çalışmamalı (mevcut davranış) ═══════════════
_run_gate "${WORKDIR}/does-not-exist" >/dev/null 2>&1
assert_eq "$(cat "$ASK_LOG")" "" "os-release dosyası yok: blok atlanır, _ask çağrılmaz"

test_summary
