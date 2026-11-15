#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F7/a1 (QL7 H1, H2, H3, M2, M4, L1, L4, L5, L11-işaret) — ACİL KAPATMA İŞARETİ, KİLİT AŞAMASI ve ÇALIŞAN DURUM. — parça 1/3: H3-1 … H3-6 (işaret, sembolik bağ, KAPALI kanıtı)
#  H3  işaret diske dokunmadan ÖNCE yazılır; kayıt dizini güvenilmezse ikinci güvenilir konuma; hiçbir yer güvenilir
#      değilse rc 6; "kayıt on + diskte yalnız srvctl 403 kökü" KAPALI kanıtıdır (fm-root/repair/php-switch AÇMAZ)
#  M2  güvenilmez kayıt dizininde HİÇBİR yazım yok (mktemp/printf/chmod/mv)
#  H1  kilit aşaması BEKLER (üst sınır, süre dolunca rc 4); _domconf_fm_tx_commit işaret varken 'on' yazmaz ve işareti
#      yalnız açık 'on' / 'off' kaydı siler; q1 / q1b NEDEN testleri
#  H2  normal 'off' çalışan durumu sınar: AÇIK → acil yol rc 3, KAPALI → rc 0, doğrulanamadı → rc 4
#  L1  acil yolda 'doğrulanamadı' ASLA rc 0 değil
#  L4  *.srvctl-emergency.* görünürlük/eşik, ad çakışmasında adli kopya, fazladan .srvctl-tampered yok
#  L5  rc≠0 dallarında çalışan durum açıkça söylenir; D01 ileti ayrımı
#  M4  domain remove önek komşusunun yedeklerini silmez
#  L11 işaret: sarkan bağ, kayıtsız alanda işaret yok, mod 0600 (umask 000 altında)
# Flock taklidi GERÇEK flock gibi bekler: FLOCK_HELD dosyası varken `-w N` N sn bekler, sonra rc 1.
# NOT: `nohup … &` SIGINT'i yok saydırır → testi ön planda koşun.
# Eski tek dosya (604 satır, 184 doğrulama; yüklü makinede 333 sn) 3 bağımsız dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f7_emergency_common.sh. Parçalar: (ad yok) H3-1 … H3-6, _2 H1, _3 H2 … D01/D02.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f7_emergency_common.sh"
echo "── H3-1: işaret diske dokunmadan ÖNCE yazılır ──"
_fm_reset; _on
eval "_orig__close_disk() $(declare -f _domconf_fm_em_close_disk | sed 1d)"
_domconf_fm_em_close_disk() {
    if _fmprov_emergency_present example_com; then echo M > "${FM_STUBS}/order"; else echo - > "${FM_STUBS}/order"; fi
    _orig__close_disk "$@"
}
rm -f "${FM_STUBS}/order"
_e --emergency; rc=$?
assert_eq "$(cat "${FM_STUBS}/order" 2>/dev/null)" "M" "H3-1: disk kapatılırken işaret ZATEN vardı (işaret önce)"
assert_eq "$rc" "0" "H3-1: normal akış rc 0"
_domconf_fm_em_close_disk() { _orig__close_disk "$@"; }
# SIGKILL penceresi K8: işaret yazıldı, disk HİÇ kapatılmadı → sonraki repair/fm-root alanı AÇMAZ, kapatır
_fm_reset; _on
_domconf_fm_em_close_disk() { kill -9 "$BASHPID"; }
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
assert_eq "$(_exists "$MARK")" "var" "H3-1/K8: SIGKILL (disk kapatılmadan) sonrası işaret DİSKTE"
assert_eq "$(_disk)" "varvarA" "H3-1/K8: disk hâlâ açık (kapatma hiç başlamadı)"
_domconf_fm_em_close_disk() { _orig__close_disk "$@"; }
_repair; rc=$?
assert_eq "$rc" "0" "H3-1/K8: sonraki repair rc 0"
assert_eq "$(_disk)|$(_st)|$(_run)" "yokyokK|off|RUN-CLOSED" "H3-1/K8: repair alanı AÇMADI, KAPATTI (işaret 'on' kaydını geçersiz kıldı)"
# SIGKILL penceresi K2: 20 → 403 kökü yazıldı, 90/21 kenara alınmadan öldü
_fm_reset; _on
eval "_orig__em_disable() $(declare -f _domconf_fm_em_disable | sed 1d)"
_domconf_fm_em_disable() { kill -9 "$BASHPID"; }
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
_domconf_fm_em_disable() { _orig__em_disable "$@"; }
assert_eq "$(_exists "$F90")$(_exists "$F21")" "varvar" "H3-1/K2: 90/21 kenara alınmadan öldü"
assert_eq "$(_exists "$MARK")" "var" "H3-1/K2: işaret diskte"
_fmroot; rc=$?
assert_eq "$rc" "0" "H3-1/K2: fm-root --apply rc 0"
assert_eq "$(_disk)|$(_st)|$(_run)" "yokyokK|off|RUN-CLOSED" "H3-1/K2: fm-root alanı AÇMADI"

echo "── H3-2: kayıt dizini SEMBOLİK BAĞ → ikinci güvenilir konum; dizin düzelince 5 yol alanı AÇMAZ ──"
_scn_symlink
assert_eq "$_SCN_RC" "0" "H3-2: acil kapatma rc 0 (disk kapalı, reload tamam, sonda KAPALI, işaret ikinci konumda)"
assert_eq "$(_exists "$AMARK")" "var" "H3-2: işaret İKİNCİ konumda yazıldı ($AMARK)"
assert_eq "$(_mode "$AMARK")|$(_mode "$ALT")" "600|700" "H3-2: işaret 0600, ikinci konum dizini 0700"
assert_contains "$(_out)" "$AMARK" "H3-2: ileti işaretin YOLUNU söyler"
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "H3-2: disk ve çalışan nginx KAPALI"
assert_eq "$(_st)" "on" "H3-2: dizin düzeltildi, kayıt hâlâ 'on' diyor (eşitlenemedi)"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "ACİL KAPATMA işareti var" "H3-2: status işareti söyler"
assert_contains "$out" "$AMARK" "H3-2: status işaretin ikinci konumdaki yolunu gösterir"
assert_not_contains "$out" "TAMPERED" "H3-2: status TAMPERED demez"
assert_not_contains "$out" "Onarım: srvctl domain fm-root" "H3-2: status 'fm-root --apply' ONARIMI önermez"
_repair; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "H3-2/repair: alanı AÇMADI, kaydı 'off'a eşitledi"
assert_eq "$(_exists "$AMARK")" "yok" "H3-2/repair: 'off' kaydı yazılınca ikinci konumdaki işaret kalktı"
_scn_symlink; _fmroot; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "H3-2/fm-root --apply (status'un eski önerisi): alanı AÇMADI"
_scn_symlink; _fmroot_all; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "H3-2/fm-root --all --apply: alanı AÇMADI"
_scn_symlink; _repair 0; rc=$?
assert_eq "$rc|$(_disk)|$(_st)" "0|yokyokK|off" "H3-2/toplu repair (reload=0): alanı AÇMADI"
_scn_symlink; _domconf_fm_auth_sock_sync example.com 8.4 >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(_disk)" "0|yokyokK" "H3-2/php-switch (sock_sync): alanı AÇMADI (rc 0 = değişiklik yok)"
_scn_symlink
mkdir -p "${SD}/.bk.example_com.ZZZZZZ"; cp -p "$MAN" "${SD}/.bk.example_com.ZZZZZZ/manifest"
cp -p "$F20" "${SD}/.bk.example_com.ZZZZZZ/" 2>/dev/null
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1
assert_eq "$(_disk)" "yokyokK" "H3-2/yarım-işlem kurtarması: alanı AÇMADI"
# aynı senaryo işaretin kendisi YOKKEN de: açık 'on' dışında hiçbir yol açmaz (kanıt kuralı aşağıda H3-4)

# kayıt dizini HÂLÂ sembolik bağken status: işaret varsa "düzelince de KAPALI", yoksa "AÇIK sayılır — önce off" uyarısı
_fm_reset; _on; mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"; _e
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "STATE-UNTRUSTED" "H3-2: bağlı dizinde status STATE-UNTRUSTED der"
assert_contains "$out" "kayıt dizini düzeltilince de bu alan KAPALI sayılır" "H3-2: işaret varsa status bunu söyler (fm-root/repair açmaz)"
rm -f "$AMARK"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "acil kapatma işareti YOK" "H3-2: işaret yoksa status uyarır"
assert_contains "$out" "srvctl domain fm-auth example.com off" "H3-2: ... ve önce 'off' koşmayı söyler"
rm -f "$SD"; mv "${SD}.real" "$SD"

echo "── H3-3: kayıt dizini SAHİP YANLIŞ / M2: güvenilmez dizinde HİÇBİR yazım yok ──"
_fm_reset; _on
MOCK_BAD_OWNER="$SD"
ls -A "$SD" > "${FM_STUBS}/sd.before"
_e; rc=$?
MOCK_BAD_OWNER=""
ls -A "$SD" > "${FM_STUBS}/sd.after"
assert_eq "$rc" "0" "H3-3: sahip yanlış: acil kapatma rc 0"
assert_eq "$(_exists "$AMARK")" "var" "H3-3: işaret ikinci konumda"
assert_eq "$(diff "${FM_STUBS}/sd.before" "${FM_STUBS}/sd.after" && echo ayni)" "ayni" "M2: güvenilmez kayıt dizinine HİÇBİR dosya eklenmedi/değişmedi (mktemp yok)"
assert_eq "$(find "$SD" -name '.example_com.emerg.*' | wc -l | tr -d ' ')" "0" "M2: '.example_com.emerg.*' geçici dosyası yok"
# M2: işaret yolu bir DİZİNE sembolik bağ + güvenilmez dizin: kurban dizine yazılmaz
_fm_reset; _on
mkdir -p "${FM_STUBS}/victim"; ln -s "${FM_STUBS}/victim" "$MARK"
MOCK_BAD_OWNER="$SD"; _e; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$(find "${FM_STUBS}/victim" -type f | wc -l | tr -d ' ')" "0" "M2: kurban dizinde root'un yazdığı dosya YOK (sembolik bağ izlenmedi)"
assert_eq "$(_exists "$AMARK")" "var" "M2: işaret yine de ikinci konumda"
# aynısı GÜVENİLİR dizinde: kurban dizin boş kalır, işaret gerçek dosya olur
_fm_reset; _on
mkdir -p "${FM_STUBS}/victim2"; ln -s "${FM_STUBS}/victim2" "$MARK"
_e --emergency
assert_eq "$(find "${FM_STUBS}/victim2" -type f | wc -l | tr -d ' ')" "0" "M2: güvenilir dizinde de kurban dizine yazılmadı"
# M2: güvenilmez dizinde bayat yedek de TAŞINMAZ (rename dahil hiçbir yazım yok)
_fm_reset; _on; mkdir -p "${SD}/.bk.example_com.MMMMMM"; echo x > "${SD}/.bk.example_com.MMMMMM/f"
MOCK_BAD_OWNER="$SD"; _e; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$(_exists "${SD}/.bk.example_com.MMMMMM")|$(_supn)" "var|0" "M2: güvenilmez dizinde bayat .bk yedeği geri yüklenmedi AMA TAŞINMADI da (hiçbir yazım yok)"
# H3-3b: kayıt BOZUK ama dizin güvenilir → işaret kayıt dizininde
_fm_reset; _on; cp -p "$MAN" "${FM_STUBS}/man.good"; printf 'garbage\n' > "$MAN"; chmod 600 "$MAN"
_e; rc=$?
assert_eq "$rc|$(_exists "$MARK")|$(_exists "$AMARK")" "0|var|yok" "H3-3b: bozuk kayıt + güvenilir dizin: işaret kayıt dizininde"
cp -p "${FM_STUBS}/man.good" "$MAN"
_repair; rc=$?
assert_eq "$rc|$(_disk)|$(_st)" "0|yokyokK|off" "H3-3b: kayıt geri konunca repair alanı AÇMADI"

echo "── H3-4: işaret HİÇBİR yere yazılamıyor → rc 6; disk YİNE kapalı; KAPALI kanıtı yine korur ──"
_fm_reset; _on
mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
mkdir -p "$ALT"; chmod 700 "$ALT"; MOCK_BAD_OWNER="$ALT"
_e; rc=$?
MOCK_BAD_OWNER=""
assert_eq "$rc" "6" "H3-4: işaret yazılamadı → rc 6 (rc 0 DEĞİL)"
assert_contains "$(_out)" "acil kapatma işareti YAZILAMADI" "H3-4: ileti nedeni söyler"
assert_contains "$(_out)" "root:root 0700 yapıp 'srvctl domain fm-auth example.com off' koşun" "H3-4: ileti çıkış yolunu söyler"
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "H3-4: disk YİNE kapatıldı (monoton), çalışan nginx KAPALI"
assert_eq "$(_exists "$AMARK")$(_exists "$MARK")" "yokyok" "H3-4: hiçbir konumda işaret yok"
rm -f "$SD"; mv "${SD}.real" "$SD"
assert_eq "$(_st)" "on" "H3-4: kayıt 'on' diyor"
_repair; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "H3-4: işaret YOK ama diskin kendisi KAPALI kanıtı → repair alanı AÇMADI"
# kilit altında işaret yeniden denenir: ilk aşamada hiçbir konuma yazılamadı (primary put 1. çağrıda düşer, ikinci konum güvenilmez),
# kilit alınınca kayıt dizini artık güvenilir → işaret yazılır (rc 6 DEĞİL), sonra kayıt 'off'a eşitlenir
_fm_reset; _on
eval "_orig__put() $(declare -f _domconf_fm_em_marker_put | sed 1d)"
mkdir -p "$ALT"; chmod 700 "$ALT"
_domconf_fm_em_marker_put() { echo x >> "${FM_STUBS}/put.calls"; if [[ "$(wc -l < "${FM_STUBS}/put.calls" | tr -d ' ')" == "1" ]]; then return 1; fi; _orig__put "$@"; }
rm -f "${FM_STUBS}/put.calls"; MOCK_BAD_OWNER="$ALT"
_e --emergency; rc=$?
MOCK_BAD_OWNER=""; _domconf_fm_em_marker_put() { _orig__put "$@"; }
assert_eq "$rc|$(wc -l < "${FM_STUBS}/put.calls" | tr -d ' ')|$(_st)" "0|2|off" "H3-4b: ilk aşamada işaret yazılamadı, kilit altında yeniden denendi → rc 0 (rc 6 DEĞİL), kayıt 'off'"
# ikinci konum dizini güvenilir değilse (mod 0755) işaret oraya YAZILMAZ → rc 6
_fm_reset; _on; mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
mkdir -p "$ALT"; chmod 755 "$ALT"
_e; rc=$?
rm -f "$SD"; mv "${SD}.real" "$SD"
assert_eq "$rc|$(_exists "$AMARK")|$(_disk)" "6|yok|yokyokK" "H3-4: ikinci konum dizini 0755 (güvenilmez) → işaret yazılmaz, rc 6, disk yine kapalı"
# rc 6 yalnız kalıcılık eksikse: normal (işareti yazılabilen) akışta rc 0 kalır
_fm_reset; _on; _e --emergency; assert_eq "$?" "0" "H3-4: işaret yazılabildiğinde rc 0"
# kayıt dizini hiç yok (kayıt yok): işaret GEREKMEZ → rc 0 (rc 6 değil)
_fm_reset; _on; rm -rf "$SD"
_e --emergency; rc=$?
assert_eq "$rc|$(_exists "$MARK")|$(_exists "$AMARK")" "0|yok|yok" "L11-B02: kayıt dizini/kaydı yok: işaret yazılmaz, rc 0"
_fm_reset; _on; rm -f "$MAN"
_e --emergency; rc=$?
assert_eq "$rc|$(_exists "$MARK")|$(_exists "$AMARK")" "0|yok|yok" "L11-B02: dizin var ama bu alanın kaydı yok: yetim işaret bırakılmaz"

echo "── H3-5: KAPALI KANITI — kayıt 'on' + diskte yalnız srvctl 403 kökü (işaret YOK) ──"
_fm_reset; _on
# acil kapanışın disk görüntüsünü işaretsiz kur: 90/21 yok, 20 = 403 kökü; kayıt 'on'
rm -f "$F90" "$F21"; _domconf_fm_render_off example_com > "$F20"; fm_sim_reload
_fmprov_load example_com; lrc=$?
assert_eq "$lrc|$_FMP_STATE|$_FMP_EMERGENCY" "0|off|2" "H3-5: _fmprov_load kaydı KAPALI sayar (kanıt = 2)"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_contains "$out" "KAPALI KANITI" "H3-5: status KAPALI kanıtını söyler"
assert_contains "$out" "fm-auth example.com off" "H3-5: status 'off' önerir"
assert_not_contains "$out" "TAMPERED" "H3-5: status TAMPERED demez"
assert_not_contains "$out" "Onarım" "H3-5: status 'fm-root --apply' ONARIMI önermez"
assert_eq "$rc" "0" "H3-5: status rc 0 (disk KAPALI, çalışan KAPALI)"
_repair; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "H3-5/repair: açmadı, kaydı 'off'a eşitledi"
for how in fmroot fmroot_all repair0 sock recover; do
    _fm_reset; _on; rm -f "$F90" "$F21"; _domconf_fm_render_off example_com > "$F20"; fm_sim_reload
    case "$how" in
        fmroot) _fmroot ;;
        fmroot_all) _fmroot_all ;;
        repair0) _repair 0 ;;
        sock) _domconf_fm_auth_sock_sync example.com 8.4 >"$OUTF" 2>&1 ;;
        recover) mkdir -p "${SD}/.bk.example_com.QQQQQQ"; cp -p "$MAN" "${SD}/.bk.example_com.QQQQQQ/manifest"; ( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1 ;;
    esac
    assert_eq "$(_disk)" "yokyokK" "H3-5/${how}: alanı AÇMADI (kanıt kuralı)"
done
# negatifler: kanıt YOK → kayıt 'on' kalır
_fm_reset; _on
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "on|0" "H3-5: sağlam AÇIK alan: kanıt yok, 'on'"
rm -f "$F21"; _domconf_fm_render_off example_com > "$F20"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "H3-5: 90 hâlâ diskte → kapalı KANITI YOK; F9b (§15/33): tanınan açık eser de değil (20 kapalı kök) → sınıf 4, kapalı sayılır (otomatik yol açmaz)"
rm -f "$F90"; printf 'location = /_fm { return 403; }\n' > "$F20"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "H3-5: 20 srvctl'in 403 kökü DEĞİL (yabancı içerik) → kanıt YOK; F9b: tanınan açık eser de değil → sınıf 4 (kapalı sayılır)"
rm -f "$F20"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "H3-5: 20 de yok → kanıt YOK; F9b: 20 eksik = tanınan açık eser değil → sınıf 4 (kapalı sayılır)"
_domconf_fm_render_off example_com > "$F20"; ln -sf "$F20" "${F20}.x"; rm -f "$F20"; ln -s "${F20}.x" "$F20"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "H3-5: 20 sembolik bağ → kanıt YOK; F9b: sınıf 4 (kapalı sayılır)"
# açık 'on' kanıtı aşar
_fm_reset; _on; rm -f "$F90" "$F21"; _domconf_fm_render_off example_com > "$F20"
_on; rc=$?
assert_eq "$rc|$(_st)" "0|on" "H3-5: açık 'fm-auth on' kanıtlı alanı yeniden AÇAR"

echo "── H3-6: ikinci konumdaki işaret kayıt 'on' kaydını geçersiz kılar; L11 B01/B02/B09 ──"
_fm_reset; _on; mkdir -p "$ALT"; chmod 700 "$ALT"; printf 'srvctl-fm-emergency v1\n' > "$AMARK"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|1" "H3-6: yalnız ikinci konumda işaret → KAPALI"
_fm_reset; _on; ln -s /nonexistent/marker "$MARK"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|1" "L11-B01: SARKAN sembolik bağ işareti de işarettir (kayıt 'on' KAPALI sayılır)"
_fm_reset; _on; ln -s /nonexistent/marker "$AMARK" 2>/dev/null || { mkdir -p "$ALT"; ln -s /nonexistent/marker "$AMARK"; }
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|1" "L11-B01: ikinci konumda sarkan bağ da işaret"
# B09: işaret modu umask'tan BAĞIMSIZ 0600
_fm_reset; _on; FLOCK_RC=1
( umask 000; _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
FLOCK_RC=0
assert_eq "$(_mode "$MARK")" "600" "L11-B09: kayıt dizinindeki işaret 0600 (umask 000 altında da)"
_fm_reset; _on; mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
( umask 000; _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
assert_eq "$(_mode "$AMARK")|$(_mode "$ALT")" "600|700" "L11-B09: ikinci konumdaki işaret 0600, dizin 0700 (umask 000 altında da)"
rm -f "$SD"

test_summary
