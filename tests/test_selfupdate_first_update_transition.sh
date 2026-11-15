#!/bin/bash
# QL5-M2: F4'e İLK self-update geçişi. Eski (F4 öncesi, taban 4411744) _selfupdate_run gövdesi BELLEKTE koşar;
# dosyalar kopyalanınca "Şimdi 'srvctl domain repair --all'" diye sorar, 'evet' alırsa YENİ lib/domain.sh'ı source
# edip 'cmd_domain repair --all' çağırır. Bu test eski gövdeyi (tests/fixtures/selfupdate_pre_f4_run.body, taban
# 4411744'ten BİREBİR) gerçekten işletir; yeni domain.sh'ın o çağrıyı geniş repair'e DÖNÜŞTÜRMEDİĞİNİ kilitler.
#   A  eski gövde + 'evet' → geniş repair'in İLK yan etkisi (list_all_domains) ÇALIŞMAZ; fm-root kuru plan + (ikinci
#      onay 'evet' ise) fm-root --all --apply çağrılır; ikinci onay 'hayır' ise apply YOK
#   B  kontrol: operatörün elle yazdığı 'cmd_domain repair --all' (zincirde _selfupdate_run YOK) HÂLÂ geniş repair'e gider
#   C  eski gövde onayı reddedilirse (hayır) hiçbir şey çalışmaz
#   D  kontrol hücresi: fixture gerçekten ESKİ gövde ('repair --all' sorusu + cmd_domain repair --all çağrısı içerir)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
LOG="${T}/calls.log"
SRVCTL_ROOT="${T}/root"; mkdir -p "${SRVCTL_ROOT}/lib" "${SRVCTL_ROOT}/bin"
cp "${REPO_ROOT}/lib/domain.sh" "${SRVCTL_ROOT}/lib/domain.sh"      # cp -f sonrası YENİ dosya
source "${REPO_ROOT}/lib/selfupdate.sh"                              # SRVCTL_ROOT önceden ayarlı → türetilen yollar geçici kökte
require_root() { :; }
# bellekteki ESKİ gövde: fixture, yeni selfupdate.sh'ın _selfupdate_run'ını GEÇERSİZ KILAR
FIX="${REPO_ROOT}/tests/fixtures/selfupdate_pre_f4_run.body"
FIXBODY="$(cat "$FIX")"

echo "── D: kontrol hücresi — fixture gerçekten ESKİ gövde ──"
assert_contains "$FIXBODY" "Şimdi 'srvctl domain repair --all' çalıştırılsın mı?" "D: eski gövde geniş repair --all SORUYOR"
assert_contains "$FIXBODY" "cmd_domain repair --all" "D: eski gövde cmd_domain repair --all ÇAĞIRIYOR"
assert_not_contains "$FIXBODY" "_selfupdate_offer_fm_root" "D: eski gövde fm-root teklifini BİLMİYOR"

# ağ/kurulum parçalarını nötrle; eski gövdenin geri kalanı (pin, repair sorusu) gerçek çalışır
git() { return 0; }
_selfupdate_validate_repo_url() { return 0; }
_selfupdate_assert_pin_owned() { return 0; }
_selfupdate_warn_if_pin_stale() { :; }
_selfupdate_backup_current() { echo "${T}/backup"; }
_selfupdate_fetch_pinned() { return 0; }
_selfupdate_verify_tag_signature() { :; }
_selfupdate_install_from_staging() { :; }            # dosyalar zaten (yeni) kopyalı: yukarıdaki cp
_selfupdate_health_check() { return 0; }
_selfupdate_prune_backups() { :; }
step() { :; }
SRVCTL_SELFUPDATE_PIN="${T}/pin"
_write_pin() { printf 'PINNED_COMMIT=%s\nPINNED_AT=x\nPINNED_REPO=%s\n' "$(printf 'a%.0s' $(seq 1 40))" "$SRVCTL_REPO" > "$SRVCTL_SELFUPDATE_PIN"; }
# shellcheck disable=SC2034  # SRVCTL_CURRENT_COMMIT: eski _selfupdate_run gövdesi okur (eval)
SRVCTL_CURRENT_COMMIT="${T}/current"
# geniş repair'in İLK yan etkileri + fm-root yolu — hepsi izlenir
list_all_domains()   { echo "list_all_domains" >> "$LOG"; }
domain_exists()      { echo "domain_exists $*" >> "$LOG"; return 1; }
_domconf_reload()    { :; }                          # _domain_load_conf_lib "yüklü" saysın
_domconf_fm_root_cmd() { echo "fm-root $*" >> "$LOG"; return 0; }

run_old_body() {   # $1 = eski gövde onayı (evet/hayir), $2 = fm-root onayı
    : > "$LOG"; _write_pin                           # eski gövde başarıda pini siler
    local first="$1" second="$2"
    (
        eval "$FIXBODY"                              # eski _selfupdate_run bellekte
        _n=0
        confirm() { _n=$((_n+1)); local a; if [[ "$_n" == 1 ]]; then a="$first"; else a="$second"; fi; [[ "$a" == evet ]]; }
        _selfupdate_run
    ) >"${T}/out.txt" 2>&1
    echo "rc=$?" >> "${T}/out.txt"
}
# eski gövdenin source ettiği domain.sh AYNI süreçte yeni kopya: yeni dosyayı gerçekten source ettirmek için
# 'source "${SRVCTL_ROOT}/lib/domain.sh"' eski gövdede zaten var → geçici kökteki YENİ kopya yüklenir.

echo "── A: eski gövde 'evet' → geniş repair ÇALIŞMAZ, fm-root yoluna yönlenir ──"
run_old_body evet evet
L="$(cat "$LOG")"; O="$(cat "${T}/out.txt")"
assert_not_contains "$L" "list_all_domains" "A: geniş repair --all'ın numaralandırması (list_all_domains) ÇALIŞMADI"
assert_not_contains "$L" "domain_exists" "A: tek-alan repair yan etkisi (domain_exists) ÇALIŞMADI"
assert_contains "$L" "fm-root --all" "A: fm-root KURU plan çağrıldı"
assert_contains "$L" "fm-root --all --apply" "A: ikinci onay 'evet' → fm-root --all --apply"
# QL6-M6: alt dize araması '--apply --force' gibi EK argümanı kaçırırdı (gerçek _domconf_fm_root_cmd onu
# "Bilinmeyen seçenek" diye reddeder → ilk güncelleme geçişi bozulur). TAM argüman satırı eşitliği:
assert_eq "$L" "$(printf 'fm-root --all\nfm-root --all --apply')" "A: fm-root çağrıları TAM olarak [kuru: '--all'] + [apply: '--all --apply'] (ek/eksik argüman yok)"
assert_eq "$(grep -c '^fm-root ' "$LOG")" "2" "A: tam iki fm-root çağrısı (kuru + apply)"
assert_contains "$O" "GEÇİŞ KORUMASI" "A: operatöre geçiş koruması AÇIKÇA bildirildi"
assert_contains "$O" "rc=0" "A: akış rc 0 ile bitti"
echo "── A2: eski gövde 'evet', fm-root onayı 'hayır' → apply YOK ──"
run_old_body evet hayir
L="$(cat "$LOG")"
assert_not_contains "$L" "list_all_domains" "A2: geniş repair ÇALIŞMADI"
assert_contains "$L" "fm-root --all" "A2: kuru plan çağrıldı"
assert_not_contains "$L" "--apply" "A2: ikinci onay reddedilince fm-root --apply ÇALIŞMADI"
assert_eq "$L" "fm-root --all" "A2: fm-root çağrısı TAM olarak yalnız kuru '--all' (QL6-M6)"

echo "── C: eski gövde onayı 'hayır' → hiçbir şey çalışmaz ──"
run_old_body hayir hayir
assert_eq "$(wc -c < "$LOG" | tr -d ' ')" "0" "C: hayır → ne repair ne fm-root"

echo "── B: kontrol — elle 'cmd_domain repair --all' (zincirde _selfupdate_run YOK) geniş repair'e GİDER ──"
: > "$LOG"
( source "${SRVCTL_ROOT}/lib/domain.sh"; require_root() { :; }; list_all_domains() { echo "list_all_domains" >> "$LOG"; }
  _domain_load_conf_lib() { return 0; }; cmd_domain repair --all ) >/dev/null 2>&1
assert_contains "$(cat "$LOG")" "list_all_domains" "B: operatörün elle repair --all'ı yönlendirilMEZ (geniş repair'e ulaşır)"

echo "── E: README geçiş notu kodla uyumlu ──"
RM="$(cat "${REPO_ROOT}/README.md")"
assert_contains "$RM" "FM destekli sürüme İLK güncellemede soruya HAYIR deyin" "E: README: ilk güncellemede soruya HAYIR"
assert_contains "$RM" "GEÇİŞ KORUMASI" "E: README: yeni kodun geçiş koruması anlatılıyor (kodda aynı ifade var)"
assert_contains "$(cat "${REPO_ROOT}/lib/domain.sh")" "GEÇİŞ KORUMASI" "E: kod: koruma iletisi README ile aynı"
assert_not_contains "$RM" "otomatik adım da artık yalnız \`fm-root --all --apply\`'dır" "E: README: geçiş için YANLIŞ olan eski cümle kalmadı"
assert_not_contains "$RM" "Hiçbir karantina yolu \`/_fm\`'i 200'e düşürmez" "E: README: kanıttan geniş 'hiçbir karantina yolu' iddiası daraltıldı"
assert_contains "$RM" "KALINTI köken kaydı" "E: README: sürüm geri dönüşü KALINTI notu (QL5-L13)"
assert_contains "$RM" "şablon kayması: \`fm-root <alan> --apply\`" "E: README: STALE → şablon kayması fm-root (QL5-L14, Deploy README ile hizalı)"

test_summary
