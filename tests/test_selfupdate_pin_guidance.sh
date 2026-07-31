#!/bin/bash
# GERÇEK ÜRETİM KULLANILABİLİRLİK KUSURU (koordinatör raporu):
#
#   sudo srvctl self-update run
#     ═══════════════════════════════════════════════
#       srvctl Güncelleme
#     ═══════════════════════════════════════════════
#     ℹ  Mevcut sürüm: 2.0.0
#   EXIT=1
#   (hiçbir şey daha — log burada bitiyor)
#
# Kök neden: 'run', 'self-update check'in yazdığı pin dosyasına ('.selfupdate-
# pending') ihtiyaç duyar; pin yoksa eskiden TEK satırlık 'error' mesajı
# STDERR'e basılıp çıkılıyordu — yalnız STDOUT'u yakalayan bir log/izleme
# kurulumunda ('srvctl self-update run >> log.txt', '2>&1' OLMADAN) operatör
# NEDENİ asla göremiyordu; mesaj da yalnız "ne yap"ı söylüyordu, "NEDEN iki
# aşamalı" olduğunu AÇIKLAMIYORDU.
#
# Bu dosya, lib/selfupdate.sh'a eklenen KULLANILABİLİRLİK düzeltmelerini
# doğrular:
#   1) [KRİTİK/ZORUNLU] pin yokken 'run': açıklama STDOUT'a ('info') basılır
#      (hangi akış yakalanırsa yakalansın görünür), 'self-update check'
#      önerisini VE iki-aşamalı NEDENİ içerir, çıktı ASLA boş değildir.
#   2) Bozuk pin dalları (repo eşleşmiyor / geçersiz hash biçimi) da artık
#      'self-update check' ile yeniden pinleme önerisi içeriyor (eskiden
#      bu iki dal sessizce "ne yapılacağı" söylenmeden duruyordu).
#   3) BAŞKA bir sınıf sessiz-çöküş: 'set -euo pipefail' altında
#      'x=$(git ... | awk ...)' ('|| true' OLMADAN) git başarısız olduğunda
#      script'i HİÇBİR MESAJ basmadan çökertiyordu (errexit) — bu, "aşağıdaki
#      warn/fallback hiçbir zaman ÇALIŞTIRILAMAZ" anlamına geliyordu. Bu sınıf
#      _selfupdate_check, _selfupdate_warn_if_pin_stale (pin bayat mı bilgisi)
#      ve finalize adımında (new_version tespiti) düzeltildi.
#   4) Pin BAYAT ise (uzak HEAD ilerlemiş): 'run' SESSİZCE en yeni HEAD'e
#      atlamaz, kurulumu da DURDURMAZ — yalnız UYARIR (TOFU modelinin gereği).
#   5) Yedekleme (_selfupdate_backup_current) alt dizin kopyalama hatasında
#      artık HANGİ alt dizinin NEDEN kopyalanamadığını 'warn' ile bildiriyor
#      (eskiden 'cp -a ... 2>/dev/null || return 1' teşhisi tamamen yutuyordu).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

log_action() { :; }   # gerçek log dosyasına yazmayı engelle (bkz. AYNI desen: test_deploy_framework_declared_build.sh)

# lib/selfupdate.sh KAYNAKLANMADAN ÖNCE SRVCTL_ROOT'u geçici bir dizine
# yönlendiriyoruz — SRVCTL_SELFUPDATE_PIN/.BACKUPS/.CURRENT_COMMIT dosya
# başında (source anında) SRVCTL_ROOT'tan TÜRETİLİR (core.sh'ın SRVCTL_ROOT'u
# SABİT '/usr/local/srvctl'e atamasının AKSİNE — bkz. CLAUDE.md "repo ≠
# kurulum"), bu yüzden override sourcing'den ÖNCE yapılmalı.
SRVCTL_ROOT="$(mktemp -d)"
mkdir -p "${SRVCTL_ROOT}/bin" "${SRVCTL_ROOT}/lib" "${SRVCTL_ROOT}/conf"
source "${REPO_ROOT}/lib/selfupdate.sh"

# error() ile exit eden çağrıları güvenle yapmak için subshell'de çalıştır
# (bkz. AYNI desen: test_deploy_framework_declared_build.sh, test_deploy_clone_target.sh).
_run_isolated() { ( "$@" ); }

_write_pin() {
    local commit="$1" repo="${2:-$SRVCTL_REPO}"
    printf 'PINNED_COMMIT=%s\nPINNED_AT=2026-01-01 00:00:00\nPINNED_REPO=%s\n' "$commit" "$repo" \
        > "$SRVCTL_SELFUPDATE_PIN"
    chmod 600 "$SRVCTL_SELFUPDATE_PIN"
}

FAKE_HASH_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FAKE_HASH_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

echo "== 1) [KRİTİK] pin dosyası YOKKEN 'self-update run' =="
rm -f "$SRVCTL_SELFUPDATE_PIN" 2>/dev/null || true

out1=$(_run_isolated _selfupdate_run 2>&1)
rc1=$?

assert_eq "$rc1" "1" "pin yokken 'run' exit 1 ile durur (kurulum değiştirilmez)"
assert_eq "$([[ -n "$out1" ]] && echo dolu || echo bos)" "dolu" \
    "[KRİTİK] pin yokken çıktı BOŞ DEĞİL (üretimde ölçülen 'hiçbir şey daha' regresyonu KAPANDI)"
assert_contains "$out1" "self-update check" \
    "[KRİTİK] çıktıda 'self-update check' önerisi GEÇİYOR"
assert_contains "$out1" "İKİ AŞAMALI" \
    "çıktı NEDEN iki aşamalı olduğunu açıklıyor"
assert_contains "$out1" "Mevcut sürüm" \
    "çıktı, üretimde gözlenen 'Mevcut sürüm' başlığını da içeriyor (rapordaki TAM sahne)"

echo "== 2) Bozuk pin dalları da artık 'yeniden pinleyin' önerisi veriyor =="
# _selfupdate_assert_pin_owned macOS/non-root test ortamında HER ZAMAN
# reddeder (dosya gerçek root sahipli olamaz) — burada test edilen AŞAĞI
# akış (repo eşleşmesi / hash biçimi) olduğundan, bu YUKARI akış kapıyı
# no-op'a indirgiyoruz (bkz. AYNI desen: tests/test_no_undefined_functions.sh
# 'require_root() { :; }').
_selfupdate_assert_pin_owned() { return 0; }

_write_pin "$FAKE_HASH_A" "https://example.invalid/baska-bir-repo.git"
out2=$(_run_isolated _selfupdate_run 2>&1)
rc2=$?
assert_eq "$rc2" "1" "repo eşleşmeyen pin reddedilir"
assert_contains "$out2" "farklı bir repo için alınmış" "repo uyuşmazlığı AÇIKÇA raporlanıyor"
assert_contains "$out2" "self-update check" \
    "repo uyuşmazlığında da 'self-update check' ile yeniden pinleme önerisi VAR (eskiden bu dalda YOKTU)"

_write_pin "not-a-valid-sha"
out3=$(_run_isolated _selfupdate_run 2>&1)
rc3=$?
assert_eq "$rc3" "1" "geçersiz hash biçimi reddedilir"
assert_contains "$out3" "geçersiz commit hash biçimi" "hash biçimi hatası AÇIKÇA raporlanıyor"
assert_contains "$out3" "self-update check" \
    "geçersiz hash biçiminde de 'self-update check' ile yeniden pinleme önerisi VAR (eskiden bu dalda YOKTU)"

rm -f "$SRVCTL_SELFUPDATE_PIN" 2>/dev/null || true

echo "== 3) _selfupdate_warn_if_pin_stale: bayat pin UYARIR, ENGELLEMEZ =="
# 'git'i shadow'luyoruz (bkz. AYNI desen: test_deploy_health_visibility_chain.sh)
git() {
    if [[ "${1:-}" == "ls-remote" ]]; then
        printf '%s\tHEAD\n' "$FAKE_HASH_B"
        return 0
    fi
    return 1
}
out4=$(_selfupdate_warn_if_pin_stale "https://example.invalid/x.git" "$FAKE_HASH_A" 2>&1)
assert_contains "$out4" "pinlendiğinden beri uzak repo ilerlemiş" \
    "pin BAYAT ise operatör UYARILIYOR"
assert_contains "$out4" "self-update check" \
    "bayat pin uyarısı yeniden pinleme yolunu da gösteriyor"
unset -f git

echo "== 3b) _selfupdate_warn_if_pin_stale: pin GÜNCEL ise sessiz (spam yok) =="
git() {
    if [[ "${1:-}" == "ls-remote" ]]; then
        printf '%s\tHEAD\n' "$FAKE_HASH_A"
        return 0
    fi
    return 1
}
out5=$(_selfupdate_warn_if_pin_stale "https://example.invalid/x.git" "$FAKE_HASH_A" 2>&1)
assert_eq "$out5" "" "pin GÜNCEL ise hiçbir uyarı basılmıyor (gereksiz gürültü yok)"
unset -f git

echo "== 3c) [MUTASYON-DUYARLI] ağ erişilemezken 'set -e' altında SESSİZCE ÇÖKMÜYOR =="
# Bu, DALGA 6'nın bıraktığı AYRI bir sessiz-çöküş sınıfını doğrular: prodüksiyonda
# selfupdate.sh HER ZAMAN 'set -euo pipefail' altında çalışır (bkz. bin/srvctl:9,
# sourcing ile miras alınır). 'x=$(git ... | awk ...)' ('|| true' OLMADAN) git
# başarısız olduğunda BU satırın kendisi errexit'i tetikler — fonksiyon aşağıdaki
# "TAMAMLANDI" satırına ASLA ulaşamaz. tests/lib.sh yalnız 'set -uo pipefail'
# kullandığından (errexit YOK) bunu üretim koşuluyla BİREBİR aynı şekilde test
# etmek için burada AÇIKÇA bir 'set -e' alt-shell'i kuruyoruz.
git() { return 1; }
out6=$(set -euo pipefail; _selfupdate_warn_if_pin_stale "https://example.invalid/x.git" "$FAKE_HASH_A" 2>&1; echo "TAMAMLANDI")
assert_contains "$out6" "TAMAMLANDI" \
    "[MUTASYON-DUYARLI] ağ hatasında 'set -e' altında fonksiyon YİNE DE TAMAMLANIYOR ('|| true' düzeltmesi olmadan bu FAIL verir)"
unset -f git

echo "== 3d) [MUTASYON-DUYARLI] _selfupdate_check: aynı sınıf, aynı düzeltme =="
git() { return 1; }
out7=$(set -euo pipefail; _selfupdate_check 2>&1)
unset -f git
assert_contains "$out7" "Uzak repo'ya erişilemedi" \
    "[MUTASYON-DUYARLI] 'check' ağ hatasında AÇIK mesaj basıyor (errexit ile SESSİZCE çökmüyor — '|| true' düzeltmesi olmadan bu mesaj HİÇ basılmaz)"

echo "== 4) _selfupdate_backup_current: kopyalama hatasında HANGİ alt dizin/NEDEN artık görünür =="
if [[ "$EUID" -eq 0 ]]; then
    echo "  SKIP: bu test root olmayan bir kullanıcı gerektirir (chmod 000 root'u durdurmaz)"
else
    BACKUP_ROOT="$(mktemp -d)"
    mkdir -p "${BACKUP_ROOT}/bin" "${BACKUP_ROOT}/lib" "${BACKUP_ROOT}/conf"
    # 'lib' alt dizini İÇİNDE okunamaz bir dosya -> 'cp -a' bu dosyada başarısız olur.
    printf '#!/bin/bash\n' > "${BACKUP_ROOT}/lib/unreadable.sh"
    chmod 000 "${BACKUP_ROOT}/lib/unreadable.sh"

    # shellcheck disable=SC2030,SC2031,SC2034
    # (bilinçli: alt-shell'e ÖZEL override — _selfupdate_backup_current bu
    # globalleri KENDİ dosyasında (lib/selfupdate.sh, burada zaten source
    # edilmiş) okur; shellcheck fonksiyonlar-arası kullanımı GÖREMEZ.)
    (
        SRVCTL_ROOT="$BACKUP_ROOT"
        SRVCTL_SELFUPDATE_BACKUPS="${BACKUP_ROOT}/.backups"
        SRVCTL_CURRENT_COMMIT="${BACKUP_ROOT}/.current-commit"
        out8=$(_selfupdate_backup_current 2>&1 1>/dev/null)
        rc8=$?
        echo "$rc8" > "${BACKUP_ROOT}/.rc"
        echo "$out8" > "${BACKUP_ROOT}/.stderr"
    )
    rc8="$(cat "${BACKUP_ROOT}/.rc")"
    out8="$(cat "${BACKUP_ROOT}/.stderr")"

    assert_eq "$rc8" "1" "kopyalama hatasında _selfupdate_backup_current 1 döner"
    assert_contains "$out8" "'lib'" \
        "[teşhis] hangi alt dizinin kopyalanamadığı ('lib') artık AÇIKÇA görünüyor (eskiden 2>/dev/null HER ŞEYİ yutuyordu)"

    chmod 700 "${BACKUP_ROOT}/lib/unreadable.sh" 2>/dev/null || true
    rm -rf "$BACKUP_ROOT"
fi

echo "== 5) 'srvctl self-update <bilinmeyen>' yardımı iki-aşamalı NEDENİ anlatıyor =="
require_root() { :; }   # bkz. AYNI desen: tests/test_no_undefined_functions.sh
out9=$(cmd_selfupdate boyle-bir-alt-komut-yok 2>&1)
assert_contains "$out9" "NEDEN İKİ AŞAMALI" \
    "'self-update <geçersiz>' yardımı NEDEN iki aşamalı olduğunu açıklıyor"
assert_contains "$out9" "ÖNCE 'check' çalıştırılmasını ZORUNLU" \
    "yardım metni 'run'ın ÖNCE 'check' gerektirdiğini söylüyor"

rm -rf "$SRVCTL_ROOT"
test_summary
