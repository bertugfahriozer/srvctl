#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F7/a1 (QL7 H1, H2, H3, M2, M4, L1, L4, L5, L11-işaret) — ACİL KAPATMA İŞARETİ, KİLİT AŞAMASI ve ÇALIŞAN DURUM. — parça 2/3: H1 (kilit aşaması bekler, tx_commit kapısı)
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
echo "── H1: kilit aşaması BEKLER; süre dolarsa rc 4; tx_commit işaret varken 'on' yazmaz ──"
# F9c (§15/38): eski tetikleyici (90 sil) artık alanı KAPATIR ('on' yazımı yok); kapı-B yarışı bir 'on' YAZIMI ister → tetikleyici: STALE şablon (kayıtlı bölge kayması; üç eser tanınan). Beklentiler DEĞİŞMEDİ.
# q1 (NEDEN): repair kilit altında (modsec sondası) sırasında acil kapatma; acil kilit aşaması alınamıyor
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
_hook_q1() {
    if [[ ! -e "${FM_STUBS}/hk" ]]; then
        : > "${FM_STUBS}/hk"
        ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/q1.emerg.out" 2>&1
        echo "emergency rc=$?" >> "${FM_STUBS}/q1.emerg.out"
    fi
}
rm -f "${FM_STUBS}/hk"; NGINX_T_HOOK='_hook_q1'
_repair; rc=$?
NGINX_T_HOOK=""
assert_contains "$(cat "${FM_STUBS}/q1.emerg.out")" "emergency rc=4" "q1: acil kapatma rc 4 (kilit alınamadı → kapanış DOĞRULANAMAZ), rc 0 DEĞİL"
assert_contains "$(cat "${FM_STUBS}/q1.emerg.out")" "kapanış DOĞRULANAMAZ: eşzamanlı bir srvctl yazıcısı" "q1: ileti eşzamanlı yazıcıyı söyler"
assert_eq "$(_exists "$MARK")" "var" "q1 NEDEN: repair'in commit'i acil işaretini SİLMEDİ (F6'da siliyordu)"
assert_eq "$rc" "1" "q1 NEDEN: repair 'on' kaydı yazamadı → rc 1"
assert_contains "$(_out)" "acil kapatma işareti var" "q1: repair kapıyı söyler"
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "q1 NEDEN: repair'in geri alması diski AÇMADI (yedek açıktı; işaret varken geri alma yeniden kapatır)"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_not_contains "$out" "AÇIK imzası (411)" "q1: sonraki status çalışan AÇIK görmez"
_repair; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_exists "$MARK")|$(_run)" "0|yokyokK|off|yok|RUN-CLOSED" "q1: sonraki düz repair alanı AÇMAZ; kaydı 'off'a eşitler, işareti kaldırır"
# q1b (NEDEN): acil kapatma repair'in stage'i ile commit'i arasında (nginx -t), kilit alınamıyor
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
_hook_q1b() {
    if [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]]; then
        : > "${FM_STUBS}/hk"
        ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/q1.emerg.out" 2>&1
        echo "emergency rc=$?" >> "${FM_STUBS}/q1.emerg.out"
    fi
}
rm -f "${FM_STUBS}/hk"; NGINX_T_HOOK='_hook_q1b'
_repair; rc=$?
NGINX_T_HOOK=""
assert_contains "$(cat "${FM_STUBS}/q1.emerg.out")" "emergency rc=4" "q1b: acil kapatma rc 4"
assert_eq "$(_exists "$MARK")" "var" "q1b NEDEN: commit işareti SİLMEDİ"
assert_eq "$rc" "1" "q1b NEDEN: repair 'on' kaydı yazamadı (commit kapısı)"
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "q1b NEDEN: disk kapalı kaldı, çalışan KAPALI"
_repair; rc=$?
assert_eq "$rc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "q1b: sonraki düz repair alanı AÇMAZ (F6'da RUN-OPEN)"
# q1c: aynı yarış, fm-root --apply ile
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
rm -f "${FM_STUBS}/hk"; NGINX_T_HOOK='_hook_q1b'
_fmroot; rc=$?
NGINX_T_HOOK=""
assert_eq "$(_exists "$MARK")|$(_disk)|$(_run)" "var|yokyokK|RUN-CLOSED" "q1c: fm-root --apply yarışında da işaret durur, alan kapalı"
_fmroot; assert_eq "$(_disk)|$(_st)" "yokyokK|off" "q1c: sonraki fm-root alanı AÇMAZ"

# Kilit aşaması BEKLER: kilidi başka bir yazıcı tutuyor, 1.5 sn sonra bırakıyor; bu arada diski AÇIYOR (yeniden kapatma)
_fm_reset; _on; : > "$HELD"; : > "$FLOCK_LOG"
cp -p "$F20" "${FM_STUBS}/open20"; cp -p "$F90" "${FM_STUBS}/open90"; cp -p "$F21" "${FM_STUBS}/open21"
( _wait_flock_call '-w 20 8'; echo "$?" > "${FM_STUBS}/sync.rc"; cp -p "${FM_STUBS}/open90" "$F90"; cp -p "${FM_STUBS}/open21" "$F21"; cp -p "${FM_STUBS}/open20" "$F20"; rm -f "$HELD" ) &
HPID=$!
( SRVCTL_FM_EMERGENCY_LOCK_WAIT=20 _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
wait "$HPID"
assert_eq "$(cat "${FM_STUBS}/sync.rc")" "0" "H1-bekle: senkron: arka plan yazıcı acilin kilit aşamasına GELDİĞİNİ FLOCK_LOG'dan gördü (sleep yok)"
assert_eq "$rc" "0" "H1-bekle: kilit alınınca kapanış yeniden doğrulandı → rc 0"
assert_eq "$(grep -c -- '-w 20 8' "$FLOCK_LOG")" "1" "H1-bekle: kilit aşaması kilidi alana dek BEKLEDİ (flock -w 20, tek çağrı; arada açılma ancak bekleme sırasında yazılabildi)"
assert_contains "$(_out)" "kilit altında kapanış YENİDEN yapıldı (arada biri açmıştı)" "H1-bekle: arada açılmayı yakalayıp yeniden kapattı (D01: önceki aşama kapalıydı)"
assert_eq "$(_disk)|$(_run)|$(_st)|$(_exists "$MARK")" "yokyokK|RUN-CLOSED|off|yok" "H1-bekle: disk KAPALI, çalışan KAPALI, kayıt 'off', işaret kalktı"
assert_eq "$(_reloads)" "3" "H1-bekle: reload: on + ilk kapanış + yeniden kapanış"
# Kilit hiç bırakılmıyor: üst sınır ENV ile (2 sn) → rc 4, DOĞRULANAMAZ, işaret DURUR, disk kapalı
_fm_reset; _on; : > "$HELD"; : > "$FLOCK_LOG"
( SRVCTL_FM_EMERGENCY_LOCK_WAIT=2 _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
rm -f "$HELD"
assert_eq "$rc" "4" "H1-sınır: kilit bırakılmıyor → rc 4 (rc 0 DEĞİL)"
# F8-L11: üst sınır SÜRE ÖLÇÜLEREK değil çağrı satırından denetlenir (`el <= 6` saniye yarışıydı): flock -w 2 + flock taklidi -w kadar bekleyip rc 1 verir.
assert_contains "$(_out)" "kapanış DOĞRULANAMAZ: eşzamanlı bir srvctl yazıcısı fm-auth kilidini 2 sn boyunca bırakmadı" "H1-sınır: ileti"
assert_contains "$(_out)" "ACİL KAPATMA DOĞRULANAMADI — FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir)" "H1-sınır: karar bloğu rc 4 diyor (F8-H1(4): 'disk KAPALI' DEMEZ)"
assert_not_contains "$(_out)" "ACİL KAPATMA TAMAMLANDI" "H1-sınır: zaman aşımı 'TAMAMLANDI' demez (F8-H1(4))"
assert_not_contains "$(_out)" "disk KAPALI," "H1-sınır: zaman aşımı iletisi 'disk KAPALI' iddiası taşımaz (F8-H1(4))"
assert_eq "$(_disk)|$(_run)|$(_exists "$MARK")" "yokyokK|RUN-CLOSED|var" "H1-sınır: disk ve çalışan KAPALI, işaret durur (yazıcı bitince açamaz)"
assert_eq "$(grep -c -- '-w 2 8' "$FLOCK_LOG")" "1" "H1-sınır: flock -w 2 ile çağrıldı"
# L4 (tampered): kilit zaman aşımından sonra fm-root --apply fazladan .srvctl-tampered BIRAKMAZ
_fmroot; rc=$?
assert_eq "$rc|$(_tamp)|$(_disk)|$(_st)" "0|0|yokyokK|off" "L4: kilit zaman aşımı sonrası fm-root --apply: .srvctl-tampered 0, alan kapalı"
# Varsayılan üst sınır 60 sn (çağrı satırından)
_fm_reset; _on; : > "$FLOCK_LOG"
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
assert_eq "$(grep -c -- '-w 60 8' "$FLOCK_LOG")" "1" "H1-sınır: varsayılan üst sınır 60 sn"
_fm_reset; _on; : > "$FLOCK_LOG"
( SRVCTL_FM_EMERGENCY_LOCK_WAIT=abc _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
assert_eq "$(grep -c -- '-w 60 8' "$FLOCK_LOG")" "1" "H1-sınır: geçersiz değer varsayılana döner"
# kayıt dizini güvenilmez / flock yok: eşzamanlı yazıcı OLAMAZ (tüm yazımlar reddedilir) → bekleme yok, rc 0
_fm_reset; _on; mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"; : > "$FLOCK_LOG"
_e; rc=$?
assert_eq "$rc|$(grep -c . "$FLOCK_LOG")" "0|0" "H1: sembolik bağ dizin: kilit aşaması atlanır (flock çağrısı 0), rc 0"
rm -f "$SD"; mv "${SD}.real" "$SD"

# tx_commit kapısı: işaret varken 'on' kaydı yazılmaz; açık 'on' yazar ve işareti kaldırır
_fm_reset; _on
printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"
_fmprov_load example_com
_fmprov_with_lock _domconf_fm_regen_recorded_locked example.com example_com 0 >"$OUTF" 2>&1
_fmprov_load example_com
assert_eq "$(_st)|$(_exists "$MARK")" "off|yok" "H1-kapı: işaret altında yeniden üretim KAPALI kayıt yazdı (off kaydı işareti kaldırır)"
_fm_reset; _on
_domconf_fm_tx_reset
_domconf_fm_stage example.com example_com on eu "$SCRIPT" "${DEFAULT_PHP_VERSION}" 0 >/dev/null 2>&1
# F8-H1(1): sahneleme artık işareti yeniden okur; commit kapısını sınamak için işaret SAHNELEMEDEN SONRA konur (yarış: nginx -t sırasında)
printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"
_domconf_fm_tx_commit >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "4" "H1-kapı: işaret varken 'on' commit'i REDDEDİLİR (rc 4)"
assert_contains "$(_out)" "'on' kaydı YAZILMADI" "H1-kapı: ileti"
assert_eq "$(_exists "$MARK")" "var" "H1-kapı: reddedilen commit işareti KALDIRMADI"
_domconf_fm_fail_restore 4 >/dev/null 2>&1
assert_eq "$(_disk)" "yokyokK" "H1-kapı: geri alma (yedek AÇIKTI) diski yeniden KAPATTI"
_fm_reset; _on
printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"
_domconf_fm_tx_reset
_DOMCONF_FM_TX_ACTION="on"
_domconf_fm_stage example.com example_com on eu "$SCRIPT" "${DEFAULT_PHP_VERSION}" 0 >/dev/null 2>&1
_domconf_fm_tx_commit >"$OUTF" 2>&1; rc=$?; _DOMCONF_FM_TX_ACTION=""
assert_eq "$rc|$(_exists "$MARK")|$(_st)" "0|yok|on" "H1-kapı: açık 'on' commit'i geçer, işareti kaldırır"
# uçtan uca: işaret varken açık 'fm-auth on' alanı açar (tek yol) ve işaret kalkar
_fm_reset; _on; _e --emergency
printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"
_on; rc=$?
assert_eq "$rc|$(_st)|$(_exists "$MARK")|$(_run)" "0|on|yok|RUN-OPEN" "H1-kapı: açık 'fm-auth on' (işaret altında) alanı AÇAR, işaret kalkar"

test_summary
