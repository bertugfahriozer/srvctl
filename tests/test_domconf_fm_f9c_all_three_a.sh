#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça a/12: P ön koşul, A5 adli kopya
# Eski tek dosya (test_domconf_fm_f9c_all_three.sh, 677 doğrulama, tam süitte >600 sn) 6 bağımsız dosyaya, sonra yük altında 300 sn'yi aşan a/e/f 12 dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f9c_common.sh. Parçalar: _a (P/A5), _a_2 (A6/G), _a_3 (C/E/R), _b (A[90]+D), _c (A[21]), _d (A[both]), _e (A1b: ilk 5 varyant), _e_2 (A1b: kalan 5 varyant), _e_3 (A2/A3/A4), _f (B1/B1b/B1c + B2[90]), _f_2 (B2[21]), _f_3 (B2[both] + B3..B6).
#
# Kayıt `on` iken 20-srvctl-fm-upload.conf, 21-srvctl-fm-download.conf ve 90-srvctl-fm-auth.conf eserlerinden HERHANGİ BİRİ eksik,
# kurcalanmış ya da kayıtla eşleşmeyen (sembolik bağ, yabancı sahip/mod, nlink!=1, boş, dizin, bilinmeyen içerik, kayıtta özeti yok)
# ise alan sınıf 4 (_FMP_EMERGENCY=4) ile aynı yoldan 403 köküne kapanır: fm-root, fm-root --all, repair (PHP kayması dahil), toplu repair,
# php-switch, provision, yarım-işlem kurtarması. Kayıtlı parametreyle sessiz yeniden üretim YOKTUR. Üçü de tanınan açık eserse bakım
# açık durumu korur (pozitif kontrol). Yarım-işlem yedeğinde (manifest 'on') 90/21 de kayıtlı özetle eşleşmezse yedek geri YÜKLENMEZ.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"
# ═══ P. ÖN KOŞUL (ham sınıflandırma): 20 TANINAN AÇIK, 21/90 bozuk → _fmprov_load kaydı off + sınıf 4 sayar ═══
for t in $TARGETS; do
    for v in $VARS; do
        reset_all; _on; apply_target "$t" "$v"
        _fmprov_load example_com
        assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "P [${t}/${v}]: kayıt on + 20 tanınan açık + ${t} ${v}: _fmprov_load kaydı OFF sayar, sınıf 4"
        MOCK_BAD_OWNER=""
    done
done
# P2: karışık bozulmalar (21 ve 90 farklı biçimde)
for combo in "missing:tamper" "tamper:symlink" "badowner:missing" "unknown:mode666" "unrecorded:hardlink"; do
    reset_all; _on
    mutf "$F90" "$N90" "$MAN" "${combo%%:*}"; mutf "$F21" "$N21" "$MAN" "${combo##*:}"; fm_sim_reload
    _fmprov_load example_com
    assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "P2 [90=${combo%%:*}/21=${combo##*:}]: karışık bozulma: sınıf 4"
    MOCK_BAD_OWNER=""
done
# P5: 20 tek başına tanınmıyor (21/90 tanınan): sınıf 4 (F9b ölçütü korunur; 21/90 bunu kurtarmaz)
for v in $VARS20; do
    reset_all; _on; mut20 "$v"; _fmprov_load example_com
    assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "P5 [20/${v}]: 20 tek başına tanınmıyor (21/90 tanınan): sınıf 4"
    MOCK_BAD_OWNER=""
done
# P3: kontrol — üçü de tanınan açık eser: kayıt on kalır, sınıf 0
reset_all; _on; _fmprov_load example_com
assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "on|0" "P3 kontrol: üç eser de tanınan açık: kayıt ON, sınıf 0"
# P4: kontrol — 20 bozuk + 90 bozuk (zaten sınıf 4 idi): sınıf 4 korunur
reset_all; _on; printf '# kurcalandi\n' >> "$F20"; rm -f "$F90"; fm_sim_reload; _fmprov_load example_com
assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "P4: 20 kurcalanmış + 90 eksik: sınıf 4"

# ═══ A5. kurcalanmış 90/21 kapatma yolunda adli kopya bırakır (içerik sessizce silinmez) ═══
for t in 90 21; do
    reset_all; _on; case "$t" in 90) tf="$F90" ;; 21) tf="$F21" ;; esac
    apply_target "$t" tamper; _fmroot
    assert_eq "$(_shut)|$(_st)|$(find "$CUR_DIR" -maxdepth 1 -name "${tf##*/}.srvctl-tampered" | wc -l | tr -d ' ')" "SHUT|off|1" "A5 [${t}]: kurcalanmış ${t}: kapatıldı, adli kopya (.srvctl-tampered) bırakıldı"
done

test_summary
