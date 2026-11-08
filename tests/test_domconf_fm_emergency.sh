#!/bin/bash
# shellcheck disable=SC2034,SC2120  # fm_env.sh taklit bayrakları burada atanır; yardımcılar isteğe bağlı argüman alır
# F6-M1 (QL6-M1) — MONOTON ACİL KAPATMA YOLU ve ÇALIŞAN DURUM SONDASI.
#  - 'fm-auth off' normal yolu HER nedenle başarısız olursa OTOMATİK acil yola düşer; 'off --emergency' normal yolu atlar.
#  - Acil yol kayıt / kilit / custom.d başvurusu / 'nginx -t' geri almasından BAĞIMSIZ yalnız KAPATIR; hiçbir hata
#    yolunda 90/21'i ya da eski 20'yi geri koymaz; GERÇEĞİ söyler: rc 0 KAPALI | 3 "FM HÂLÂ AÇIK" | 4 doğrulanamadı/kısmen |
#    5 disk kapatılamadı.
#  - 'status' diskin yanında ÇALIŞAN durumu da sınar (yalnız 127.0.0.1; curl taklidi dışarı isteği DENY eder).
#  - Acil işaret (<sname>.emergency): kayıt yazılamasa bile sonraki repair / fm-root / php-switch / kurtarma kapatmayı
#    geri AÇAMAZ; yalnız açık 'fm-auth on' açar.
#  Normal yolun kendi sözleşmesi tests/test_domconf_fm_auth.sh'ta (_domconf_fm_auth_off doğrudan).
# NOT: `nohup … &` / arka plan başlatması SIGINT'i YOK SAYDIRIR (yok sayılan sinyal yakalanamaz) → D9 (tuzak) sahte FAIL verir;
#  testi ön planda koşun (test_domconf_fm_stale_bk.sh ile aynı kural).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"
_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_closed() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]]; }
_disk() { printf '%s%s%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_closed && echo K || echo A)"; }
_mk_stale_bk() {
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" ]]; then cp -p "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
list_all_domains() { printf '%s\n' example.com; }
OFF_TXT="$(_domconf_fm_render_off example_com)"

echo "── A: kontrol — normal off başarılıysa acil yola DÜŞÜLMEZ ──"
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$CURL_LOG"   # F9e: `on` artık bir sonda atar; sayım yalnız off'unkini görsün
_e; assert_eq "$?" "0" "A1: normal off rc 0"
assert_not_contains "$(_out)" "ACİL" "A1: normal başarıda acil yola düşülmedi"
assert_eq "$(_disk)" "yokyokK" "A1: 90/21 yok, 20 = 403 kökü"
assert_eq "$(_st)" "off" "A1: kayıt off"
assert_eq "$(_reloads)" "2" "A1: reload: on + off (acil yol fazladan reload etmedi)"
assert_eq "$(grep -c ALLOW "$CURL_LOG")" "1" "A1: F7-H2 — normal başarı yolu ÇALIŞAN durumu sınar (tek sonda isteği, 127.0.0.1)"
assert_eq "$(grep -c DENY "$CURL_LOG")" "0" "A1: sonda dışarı istek atmaz (DENY 0)"
assert_contains "$(_out)" "kapanış çalışan nginx'te doğrulandı" "A1: ileti çalışan KAPALI imzasını söyler"

echo "── B: 'off --emergency' normal yolu ATLAR ──"
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$RELOAD_LOG"
_e --emergency; rc=$?
assert_eq "$rc" "0" "B1: acil kapatma rc 0 (disk kapalı, reload tamam, sonda 403)"
assert_contains "$(_out)" "ACİL KAPATMA" "B1: ileti acil yolu söyler"
assert_contains "$(_out)" "sonda 403" "B1: çalışan durum KAPALI (sonda 403) söylenir"
assert_eq "$(_disk)" "yokyokK" "B1: 90/21 yok, 20 = 403 kökü"
assert_eq "$(_st)" "off" "B1: kayıt kilit altında off'a eşitlendi"
assert_eq "$(_exists "$MARK")" "yok" "B1: kayıt eşitlendi → acil işareti kaldırıldı"
assert_eq "$(find "$CUR_DIR" -maxdepth 1 -name '*srvctl-emergency*' | wc -l | tr -d ' ')" "2" "B1: 90 ve 21 '.srvctl-emergency.*' adıyla kenara alındı (silinmedi; *.conf glob'una UYMAZ)"
assert_eq "$(find "$CUR_DIR" -maxdepth 1 -name '*srvctl-fm*.conf' | wc -l | tr -d ' ')" "1" "B1: nginx'in göreceği srvctl-fm *.conf yalnız 20"
assert_not_contains "$(_out)" "HÂLÂ AÇIK" "B1: kapalıyken 'HÂLÂ AÇIK' denmez"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "B1: status rc 0 (disk + çalışan KAPALI)"
assert_contains "$out" "KAPALI imzası (403)" "B1: status çalışan durumu da söyler"
assert_eq "$(_leftovers 2>/dev/null || find "$CUR_DIR" -name '*.srvctl.*' | wc -l | tr -d ' ')" "0" "B1: geçici atomik-yazım artığı yok"
_e --emergency; assert_eq "$?" "0" "B2: ikinci acil kapatma idempotent (rc 0)"
assert_eq "$(_disk)" "yokyokK" "B2: durum aynı"
_e --emergency --dry; assert_eq "$?" "0" "B3: --emergency --dry rc 0"
assert_contains "$(_out)" "DRY-OK" "B3: kuru ileti"
_fm_reset; _on; : > "$RELOAD_LOG"; _e --emergency --dry
assert_eq "$(_disk)" "varvarA" "B3: --dry HİÇBİR şey yazmaz (açık kalır)"
assert_eq "$(_reloads)" "0" "B3: --dry reload etmez"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" --emergency ) >"$OUTF" 2>&1; assert_eq "$?" "1" "B4: --emergency yalnız off ile (on reddedilir)"
assert_contains "$(_out)" "yalnız 'off'" "B4: ileti"

echo "── C: otomatik düşüş — normal off'u BAŞARISIZ kılan HER durum kapatır ──"
# C1 (O05) nginx -t düşer; çalışan nginx AÇIK (sim) → "FM HÂLÂ AÇIK", rc 3, disk YİNE KAPALI
_fm_reset; FM_PROBE_MODE=sim; _on; NGINX_TEST_RC=1
_e; rc=$?
assert_eq "$rc" "3" "C1: nginx -t düştü + çalışan nginx eski yapılandırmada AÇIK → rc 3"
assert_contains "$(_out)" "FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla" "C1: 'FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla' iletisi"
assert_contains "$(_out)" "'nginx -t' BAŞARISIZ, reload denenmedi" "C1: neden nginx -t"
assert_contains "$(_out)" "normal 'fm-auth off' BAŞARISIZ" "C1: normal yolun düştüğü söylenir"
assert_eq "$(_disk)" "yokyokK" "C1: disk yine KAPALI (nginx -t geri alması kapatmayı bozmadı)"
assert_eq "$(_st)" "off" "C1: kayıt off"
assert_eq "$(_reloads)" "1" "C1: nginx -t düşünce reload DENENMEDİ (yalnız on'un reload'u)"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "C1: status HÂLÂ AÇIK için rc 1 (disk KAPALI ama çalışan AÇIK)"
assert_contains "$out" "FM HÂLÂ AÇIK" "C1: status 'FM HÂLÂ AÇIK' der"
NGINX_TEST_RC=0; systemctl reload nginx
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "C1: reload sonrası status rc 0"
assert_not_contains "$out" "HÂLÂ AÇIK" "C1: reload sonrası 'HÂLÂ AÇIK' yok"
# C2 aynısı ama sonda yapılamıyor (unknown): "HÂLÂ AÇIK OLABİLİR", rc 4
_fm_reset; _on; NGINX_TEST_RC=1
_e; rc=$?
assert_eq "$rc" "4" "C2: nginx -t düştü + sonda doğrulayamıyor → rc 4"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "C2: kanıtlanmamış durumda 'OLABİLİR'"
assert_not_contains "$(_out)" "ACİL KAPATILDI" "C2: başarı iletisi YOK"
assert_eq "$(_disk)" "yokyokK" "C2: disk yine KAPALI"
NGINX_TEST_RC=0
# C3 (O06) reload başarısız: çalışan nginx AÇIK
_fm_reset; FM_PROBE_MODE=sim; _on; SYSTEMCTL_RC=1
_e; rc=$?
assert_eq "$rc" "3" "C3: reload başarısız + çalışan AÇIK → rc 3"
assert_contains "$(_out)" "'systemctl reload nginx' BAŞARISIZ" "C3: neden reload"
assert_contains "$(_out)" "FM HÂLÂ AÇIK" "C3: HÂLÂ AÇIK"
assert_eq "$(_disk)" "yokyokK" "C3: disk KAPALI"
SYSTEMCTL_RC=0
# C3b reload başarısız ama çalışan nginx zaten KAPALI imzası veriyor: rc 4 (ayrışık), 'HÂLÂ AÇIK' DEMEZ
_fm_reset; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; _on >/dev/null 2>&1; SYSTEMCTL_RC=1
_e --emergency; rc=$?
assert_eq "$rc" "4" "C3b: reload başarısız + sonda 403 → rc 4"
assert_not_contains "$(_out)" "FM HÂLÂ AÇIK" "C3b: çalışan KAPALI iken 'HÂLÂ AÇIK' demez"
assert_contains "$(_out)" "ayrışık" "C3b: disk/çalışan ayrışıklığı söylenir"
SYSTEMCTL_RC=0
# C4 (O04) kilit alınamıyor: kapanış YİNE olur, kayıt eşitlenmez, acil İŞARETİ kalır
_fm_reset; FM_PROBE_MODE=sim; _on; FLOCK_RC=1
_e; rc=$?
assert_eq "$rc" "4" "C4: F7-H1 — kilit alınamadı: disk KAPALI, reload tamam AMA kapanış kilit altında doğrulanamaz → rc 4 (rc 0 DEĞİL)"
assert_contains "$(_out)" "kapanış DOĞRULANAMAZ: eşzamanlı bir srvctl yazıcısı" "C4: kilit aşaması uyarısı (eşzamanlı yazıcı)"
assert_eq "$(_disk)" "yokyokK" "C4: disk KAPALI"
assert_eq "$(_st)" "on" "C4: kayıt yazılamadı → hâlâ 'state on' (kilitsiz yazılmaz)"
assert_eq "$(_exists "$MARK")" "var" "C4: acil işareti yazıldı (kilitsiz, atomik)"
FLOCK_RC=0
# C5 (O02) kayıt dizini güvenilmez; --force da gerekmez
_fm_reset; FM_PROBE_MODE=sim; _on; MOCK_BAD_OWNER="$SD"
_e; rc=$?
assert_eq "$rc" "0" "C5: STATE-UNTRUSTED'da acil kapatma başarılı"
assert_eq "$(_disk)" "yokyokK" "C5: disk KAPALI"
assert_contains "$(_out)" "normal 'fm-auth off' BAŞARISIZ" "C5: normal yol reddetti, acil yol kapattı"
MOCK_BAD_OWNER=""
# C6 (O10) flock yok
_fm_reset; FM_PROBE_MODE=sim; _on
( command() { if [[ "${1:-}" == "-v" && "${2:-}" == "flock" ]]; then return 1; fi; builtin command "$@"; }; _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "C6: flock yokken acil kapatma başarılı"
assert_eq "$(_disk)" "yokyokK" "C6: disk KAPALI"
# C7 (O11) kayıt dizini sembolik bağ: bağ üzerinden YAZILMAZ
_fm_reset; FM_PROBE_MODE=sim; _on; mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
_e; rc=$?
assert_eq "$rc" "0" "C7: kayıt dizini sembolik bağ: acil kapatma başarılı"
assert_eq "$(_disk)" "yokyokK" "C7: disk KAPALI"
assert_eq "$(_exists "${SD}.real/example_com.emergency")" "yok" "C7: sembolik bağın hedefine acil işareti YAZILMADI"
assert_eq "$(sed -n 's/^state //p' "${SD}.real/example_com.manifest")" "on" "C7: bağın hedefindeki kayıta dokunulmadı"
rm -f "$SD"; mv "${SD}.real" "$SD"
# C8 (O12) custom.d başvurusu --force'suz
_fm_reset; FM_PROBE_MODE=sim; _on; printf 'location /y {\n    rewrite ^ /__fm_auth last;\n}\n' > "${CUR_DIR}/10-ref.conf"
_e; rc=$?
assert_eq "$rc" "0" "C8: FM adına başvuran dosya + --force YOK: acil kapatma yine kapatır"
assert_eq "$(_disk)" "yokyokK" "C8: disk KAPALI"
assert_eq "$(_exists "${CUR_DIR}/10-ref.conf")" "var" "C8: kullanıcı dosyası SİLİNMEDİ"
# C9 (O13) kayıt yok + 90/21/20 diskte
_fm_reset; FM_PROBE_MODE=sim; _on; rm -f "$MAN"
_e; rc=$?
assert_eq "$rc" "0" "C9: kayıtsız FM dosyaları: acil kapatma başarılı"
assert_eq "$(_disk)" "yokyokK" "C9: disk KAPALI"
assert_eq "$(_exists "$MAN")" "yok" "C9: olmayan kayıt yaratılmadı"
# C10 (O14) kayıt bozuk
_fm_reset; FM_PROBE_MODE=sim; _on; printf 'garbage\n' > "$MAN"; chmod 600 "$MAN"
_e; rc=$?
assert_eq "$rc" "0" "C10: bozuk kayıt: acil kapatma başarılı"
assert_eq "$(_disk)" "yokyokK" "C10: disk KAPALI"
assert_eq "$(cat "$MAN")" "garbage" "C10: bozuk kayda dokunulmadı (güvenilmez kayıt yazılmaz)"
# C11 (O07/O08/O09) bayat yedekler
_fm_reset; FM_PROBE_MODE=sim; _on; _mk_stale_bk AAAAAA; _mk_stale_bk BBBBBB; mkdir -p "${SD}/.superseded.bk.example_com.AAAAAA"; echo x > "${SD}/.superseded.bk.example_com.AAAAAA/old"
# F9 (QL9-S1): kilit TUTULUYORSA (FLOCK_RC=1: sahibi sürüyor) yedekler sürmekte olan yazıcının geri alma girdisidir → DOKUNULMAZ.
FLOCK_RC=1; _e; rc=$?; FLOCK_RC=0
assert_eq "$rc" "4" "C11a: iki yedek + kilit TUTULUYOR: disk kapalı, kapanış kilit altında doğrulanamaz → rc 4 (F7-H1)"
assert_eq "$(_bkn)|$(_supn)" "2|1" "C11a: kilit sahibi SÜRÜYOR: iki .bk'ya DOKUNULMADI (F9 QL9-S1: eskiden ayrılırdı; eski .superseded yerinde)"
# sahibi ÖLÜ (kilit serbest): kilit aşaması yedekleri geri yüklemeden ayırır
_fm_reset; FM_PROBE_MODE=sim; _on; _mk_stale_bk AAAAAA; _mk_stale_bk BBBBBB; mkdir -p "${SD}/.superseded.bk.example_com.AAAAAA"; echo x > "${SD}/.superseded.bk.example_com.AAAAAA/old"
_e; rc=$?
assert_eq "$rc" "0" "C11: iki bayat yedek + ad çakışması + kilit SERBEST (sahibi ölü): acil kapatma rc 0"
assert_eq "$(_bkn)|$(_supn)" "0|3" "C11: iki .bk da GERİ YÜKLENMEDEN ayrıldı (eski .superseded korundu; çakışmada sonek)"
assert_eq "$(cat "${SD}/.superseded.bk.example_com.AAAAAA/old")" "x" "C11: var olan .superseded içeriği EZİLMEDİ"
# C12 kayıt yok + bayat yedek ('on' pre-state kayıt dahil): kurtarma yedeği GERİ YÜKLEYİP açabilirdi
_fm_reset; FM_PROBE_MODE=sim; _on; _mk_stale_bk AAAAAA; rm -f "$MAN"
_e --emergency
assert_eq "$(_bkn)|$(_supn)" "0|1" "C12: kayıt yokken de bayat yedek geri yüklenmeden ayrıldı"
_fm_reset; _on; _mk_stale_bk AAAAAA; rm -f "$MAN"; _e --emergency
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >/dev/null 2>&1
assert_eq "$(_disk)" "yokyokK" "C12: sonraki kurtarma denemesi açamadı"

echo "── C2: kilit bekleme süreleri (acil durumda 30 sn beklenmez) ──"
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$FLOCK_LOG"
( _domconf_fm_auth example.com off --emergency >/dev/null 2>&1; echo "$_FMP_LOCK_WAIT" > "${FM_STUBS}/lw.after" )
assert_eq "$(cat "${FM_STUBS}/lw.after")" "30" "C2a: acil yoldan sonra kilit bekleme değişkeni 30'a geri kuruldu"
assert_eq "$(grep -c -- '-w 60 8' "$FLOCK_LOG")" "1" "C2a: F7-H1 — acil kilit aşaması kilidi alana dek bekler (varsayılan üst sınır 60 sn)"
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$FLOCK_LOG"
( SRVCTL_FM_EMERGENCY_LOCK_WAIT=7; _domconf_fm_auth example.com off --emergency >/dev/null 2>&1 )
assert_eq "$(grep -c -- '-w 7 8' "$FLOCK_LOG")" "1" "C2b: SRVCTL_FM_EMERGENCY_LOCK_WAIT uygulanır"
# C2e: bekleme iletisi "yalnız raporu geciktirir" DEMEZ (yanlıştı): bekleme sürerken bir yazıcı diski yeniden açmış olabilir
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_fm_reset; FM_PROBE_MODE=sim; _on
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
assert_contains "$(strip_ansi < "$OUTF")" "kayıt/kilit aşaması bekleniyor" "C2e: bekleme iletisi basıldı"
assert_contains "$(strip_ansi < "$OUTF")" "diski yeniden açmış olabilir, kapanış kilit altında doğrulanana dek kesin değildir" "C2e: bekleme riski doğru söylenir"
assert_not_contains "$(strip_ansi < "$OUTF")" "yalnız RAPORU geciktirir" "C2e: 'bekleme yalnız RAPORU geciktirir' cümlesi KALKTI"
_fm_reset; FM_PROBE_MODE=sim; _on; FLOCK_RC=1; : > "$FLOCK_LOG"
( _domconf_fm_auth example.com off >/dev/null 2>&1; echo "$_FMP_LOCK_WAIT" > "${FM_STUBS}/lw.after" ); FLOCK_RC=0
assert_eq "$(grep -c -- '-w 10 8' "$FLOCK_LOG")|$(grep -c -- '-w 60 8' "$FLOCK_LOG")" "1|1" "C2c: normal deneme 10 sn + acil kilit aşaması 60 sn (normal deneme 30 sn BEKLEMEZ)"
assert_eq "$(cat "${FM_STUBS}/lw.after")" "30" "C2c: normal deneme sonrası da 30'a geri kuruldu"
_fm_reset; FM_PROBE_MODE=sim; _on; FLOCK_RC=1; : > "$FLOCK_LOG"
( SRVCTL_FM_OFF_LOCK_WAIT=3; _domconf_fm_auth example.com off >/dev/null 2>&1 ); FLOCK_RC=0
assert_eq "$(grep -c -- '-w 3 8' "$FLOCK_LOG")" "1" "C2d: SRVCTL_FM_OFF_LOCK_WAIT uygulanır (normal deneme)"

echo "── D: MONOTONLUK — hiçbir hata yolu açık duruma geri dönmez ──"
# D1 20 yazılamıyor (atomik yazım hatası): vekil devre dışı → KISMEN (rc 4), 90/21 yok, ASLA eski açık içerik
_fm_reset; FM_PROBE_MODE=sim; _on
eval "_orig__domconf_atomic_write() $(declare -f _domconf_atomic_write | sed 1d)"
_domconf_atomic_write() { return 1; }
_e --emergency; rc=$?
_domconf_atomic_write() { _orig__domconf_atomic_write "$@"; }
assert_eq "$rc" "4" "D1: 403 kökü yazılamadı → KISMEN (rc 4)"
assert_contains "$(_out)" "ACİL KAPATMA KISMEN" "D1: ileti"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")" "yokyokyok" "D1: 90/21 yok, açık 20 devre dışı (açık içerik KALMADI)"
assert_eq "$(grep -l 'auth_request' "$CUR_DIR"/*.conf 2>/dev/null | wc -l | tr -d ' ')" "0" "D1: nginx'in göreceği hiçbir *.conf auth_request taşımıyor"
# D2 yazım da devre dışı bırakma da başarısız → rc 5, iletide elle yol
_fm_reset; FM_PROBE_MODE=sim; _on
_domconf_atomic_write() { return 1; }
eval "_orig__domconf_fm_em_disable() $(declare -f _domconf_fm_em_disable | sed 1d)"
_domconf_fm_em_disable() { return 1; }
_e --emergency; rc=$?
_domconf_atomic_write() { _orig__domconf_atomic_write "$@"; }
_domconf_fm_em_disable() { _orig__domconf_fm_em_disable "$@"; }
assert_eq "$rc" "5" "D2: disk KAPATILAMADI → rc 5"
assert_contains "$(_out)" "ACİL KAPATMA BAŞARISIZ: disk KAPATILAMADI" "D2: ileti"
assert_contains "$(_out)" "ELLE kaldırın" "D2: elle yol söylenir"
# D3 20 bir DİZİN: dizinin İÇİNE düşmez; kenara alınır, yerine dosya yazılır
_fm_reset; FM_PROBE_MODE=sim; _on; rm -f "$F20"; mkdir "$F20"; echo keep > "$F20/içerik"
_e --emergency; rc=$?
assert_eq "$rc" "0" "D3: 20 dizinken de kapatır"
assert_eq "$([[ -f "$F20" && ! -L "$F20" ]] && echo dosya)" "dosya" "D3: 20 artık normal dosya"
assert_eq "$(cat "$F20")" "$OFF_TXT" "D3: içerik = 403 kökü (dizinin içine düşmedi)"
assert_eq "$(cat "$CUR_DIR"/20-srvctl-fm-upload.conf.srvctl-emergency.*/içerik 2>/dev/null)" "keep" "D3: eski dizin kenarda"
# D4 20 bir sembolik bağ: hedefe YAZILMAZ, bağ değiştirilir
_fm_reset; FM_PROBE_MODE=sim; _on; echo "hedef-icerik" > "${FM_STUBS}/victim"; rm -f "$F20"; ln -s "${FM_STUBS}/victim" "$F20"
_e --emergency; rc=$?
assert_eq "$rc" "0" "D4: 20 sembolik bağken kapatır"
assert_eq "$(cat "${FM_STUBS}/victim")" "hedef-icerik" "D4: sembolik bağın HEDEFİ ezilmedi"
assert_eq "$([[ -L "$F20" ]] && echo bag || echo dosya)" "dosya" "D4: 20 artık gerçek dosya"
# D5 90 ve 21 sembolik bağ (sarkan dahil)
_fm_reset; FM_PROBE_MODE=sim; _on; rm -f "$F90" "$F21"; ln -s /nonexistent/x "$F90"; ln -s "${FM_STUBS}/victim" "$F21"
_e --emergency; rc=$?
assert_eq "$rc" "0" "D5: 90/21 sembolik bağken kapatır"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "D5: bağlar kalktı (sarkan dahil)"
assert_eq "$(cat "${FM_STUBS}/victim")" "hedef-icerik" "D5: bağ hedefi korundu"
# D6 custom.d/<sname> dizini hiç yok → oluşturulur, 403 kökü yazılır
_fm_reset; FM_PROBE_MODE=sim; rm -rf "$CUR_DIR"
_e --emergency; rc=$?
assert_eq "$rc" "0" "D6: dizin yokken kapatır"
assert_eq "$(_closed && echo K)" "K" "D6: dizin oluşturuldu, 403 kökü yazıldı"
# D7 20 zaten bozuk/kurcalı içerik → 403 köküne ÇEVRİLİR
_fm_reset; FM_PROBE_MODE=sim; _on; printf 'location ^~ /_fm/up/ { proxy_pass http://x; }\n' > "$F20"
_e --emergency
assert_eq "$(_closed && echo K)" "K" "D7: kurcalı 20 → 403 kökü"
# D8 kayıt / kilit / nginx -t / custom.d başvurusu / bayat yedek AYNI ANDA bozuk: yine kapanır
_fm_reset; FM_PROBE_MODE=sim; _on; _mk_stale_bk AAAAAA; MOCK_BAD_OWNER="$SD"; FLOCK_RC=1; NGINX_TEST_RC=1
printf 'location /y {\n    rewrite ^ /__fm_auth last;\n}\n' > "${CUR_DIR}/10-ref.conf"
_e; rc=$?
MOCK_BAD_OWNER=""; FLOCK_RC=0; NGINX_TEST_RC=0
assert_eq "$rc" "3" "D8: her şey bozukken disk KAPALI, çalışan nginx AÇIK → dürüst rc 3"
assert_eq "$(_disk)" "yokyokK" "D8: disk yine KAPALI"
# D9 sinyaller acil yol sırasında YOK SAYILIR, çağıranın tuzakları geri kurulur
_fm_reset; FM_PROBE_MODE=sim; _on
NGINX_T_HOOK='_t_hook'; _t_hook() { trap -p INT TERM HUP > "${FM_STUBS}/traps.during"; }
( trap 'echo cagiran' INT; _domconf_fm_auth example.com off --emergency >/dev/null 2>&1; trap -p INT > "${FM_STUBS}/traps.after" )
NGINX_T_HOOK=""
assert_contains "$(cat "${FM_STUBS}/traps.during")" "trap -- '' SIGINT" "D9: acil yol sırasında INT yok sayılır"
assert_contains "$(cat "${FM_STUBS}/traps.during")" "trap -- '' SIGTERM" "D9: acil yol sırasında TERM yok sayılır"
assert_contains "$(cat "${FM_STUBS}/traps.during")" "trap -- '' SIGHUP" "D9: acil yol sırasında HUP yok sayılır"
assert_contains "$(cat "${FM_STUBS}/traps.after")" "echo cagiran" "D9: çağıranın INT tuzağı geri kuruldu"
# D10 ATOMİK yazım: 20 rename ile yerine konur (yarım dosya hiçbir an görünmez)
_fm_reset; FM_PROBE_MODE=sim; _on; MV_LOG="${FM_STUBS}/mv.log"; : > "$MV_LOG"
mv() { echo "$*" >> "$MV_LOG"; command mv "$@"; }
_e --emergency
unset -f mv
# (acil yol fiziksel yolla yazar: /var → /private/var; bu yüzden yol SONEKLERİ karşılaştırılır)
assert_eq "$(grep -c -- '^-f -- .*/20-srvctl-fm-upload\.conf\.srvctl\.[A-Za-z0-9]* .*/20-srvctl-fm-upload\.conf$' "$MV_LOG")" "1" "D10: 20 geçici dosyadan (…conf.srvctl.XXXXXX) mv ile yerine kondu (atomik)"
# D11 eşzamanlı yazıcı (nginx -t sırasında 90'ı geri yazar) → kilit altında kapanış YENİDEN doğrulanır
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$RELOAD_LOG"
_t_reopen() { if [[ ! -e "${FM_STUBS}/reopened" ]]; then : > "${FM_STUBS}/reopened"; printf 'location = /__fm_auth { internal; }\n' > "$F90"; fi; }
NGINX_T_HOOK='_t_reopen'
_e --emergency; rc=$?
NGINX_T_HOOK=""
assert_eq "$rc" "0" "D11: eşzamanlı yazıcıya rağmen son durum KAPALI (rc 0)"
assert_eq "$(_exists "$F90")" "yok" "D11: arada geri yazılan 90 kilit altında yeniden kaldırıldı"
assert_contains "$(_out)" "YENİDEN yapıldı" "D11: yeniden kapatma söylenir"
assert_eq "$(_reloads)" "2" "D11: yeniden kapatma sonrası ikinci reload"

echo "── E: ACİL İŞARET — kayıt eşitlenemese bile sonraki komutlar kapatmayı GERİ AÇAMAZ ──"
mk_marked() { _fm_reset; FM_PROBE_MODE=sim; _on; FLOCK_RC=1; _e --emergency; FLOCK_RC=0; : > "$RELOAD_LOG"; }
mk_marked
assert_eq "$(_st)|$(_exists "$MARK")" "on|var" "E0: hazırlık: kayıt 'on' + acil işareti"
( _fmprov_load example_com; echo "$_FMP_STATE/$_FMP_EMERGENCY" ) > "${FM_STUBS}/ld.txt" 2>&1
assert_eq "$(cat "${FM_STUBS}/ld.txt")" "off/1" "E1: _fmprov_load işaretli 'on' kaydını KAPALI sayar"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "ACİL KAPATMA işareti var" "E2: status işareti söyler"
assert_contains "$out" "fm-auth KAPALI (403 kökü)" "E2: işaretliyken srvctl'in kendi acil 403 kökü 'üretilmiş' tanınır (KAPALI)"
out=$(_domconf_nginx_audit example.com 2>&1); rc=$?
assert_eq "$rc" "0" "E2: nginx-audit: acil kök kullanıcı dosyası/ihlal DEĞİL (rc 0)"
assert_contains "$out" "temiz" "E2: nginx-audit temiz"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; assert_eq "$?" "0" "E3: repair rc 0"
assert_eq "$(_disk)" "yokyokK" "E3: repair kapatmayı GERİ AÇMADI"
assert_eq "$(_st)|$(_exists "$MARK")" "off|yok" "E3: repair kaydı 'off'a eşitledi, işaret kalktı"
mk_marked
( _fm_root_all() { _domconf_fm_root_cmd "$@"; }; _fm_root_all example.com --apply ) >"$OUTF" 2>&1
assert_eq "$(_disk)" "yokyokK" "E4: fm-root --apply kapatmayı GERİ AÇMADI"
assert_eq "$(_st)" "off" "E4: fm-root kaydı 'off'a eşitledi"
mk_marked
_domconf_fm_auth_sock_sync example.com 8.4; assert_eq "$?" "0" "E5: php-switch senkronu işaretliyken 90 yazmaz (rc 0)"
assert_eq "$(_disk)" "yokyokK" "E5: php-switch kapatmayı GERİ AÇMADI"
mk_marked; _mk_stale_bk AAAAAA
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1; assert_eq "$?" "0" "E6: yarım-işlem kurtarma rc 0"
assert_eq "$(_disk)" "yokyokK" "E6: bayat 'on' yedeği işaretliyken GERİ YÜKLENMEDİ"
assert_eq "$(_bkn)|$(_supn)" "0|1" "E6: yedek ayrıldı (silinmedi)"
mk_marked
_on; assert_eq "$?" "0" "E7: açık 'fm-auth on' (tüm kapılardan geçerek) yeniden AÇAR"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "varvar" "E7: 90/21 geri geldi"
assert_eq "$(_st)|$(_exists "$MARK")" "on|yok" "E7: kayıt on, işaret kaldırıldı"
mk_marked
_e; assert_eq "$?" "0" "E8: işaretliyken 'fm-auth off' başarılı"
assert_eq "$(_st)|$(_exists "$MARK")" "off|yok" "E8: off kaydı yazılınca işaret kalkar"
mk_marked
_domconf_fm_auth_forget example_com
assert_eq "$(_exists "$MARK")$(_exists "$MAN")" "yokyok" "E9: domain remove (forget) işareti de siler"
# işaretin kendisi başka alanı etkilemez
mk_marked; mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; : > "${SD}/baska_com.emergency"
_domconf_fm_auth_forget example_com
assert_eq "$(_exists "${SD}/baska_com.emergency")" "var" "E10: komşu alanın işaretine dokunulmadı"
rm -f "${SD}/baska_com.emergency"

echo "── F: status — ÇALIŞAN durum sondası ──"
_fm_reset; FM_PROBE_MODE=sim; _on
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "F1: AÇIK disk + AÇIK çalışan: rc 0"
assert_contains "$out" "AÇIK imzası (411)" "F1: çalışan durum söylenir"
# disk KAPALI ama reload başarısız → çalışan AÇIK
_fm_reset; FM_PROBE_MODE=sim; _on; SYSTEMCTL_RC=1
( _fmprov_with_lock _domconf_fm_apply example.com example_com off eu - - 0 1 ) >/dev/null 2>&1
SYSTEMCTL_RC=0
assert_eq "$(_disk)" "yokyokK" "F2: hazırlık: disk KAPALI (reload başarısızdı)"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "F2: disk KAPALI + çalışan AÇIK: status rc 1"
assert_contains "$out" "FM HÂLÂ AÇIK" "F2: 'FM HÂLÂ AÇIK'"
assert_contains "$out" "off --emergency" "F2: çıkış yolu söylenir"
# disk AÇIK ama çalışan nginx KAPALI (reload bekliyor)
_fm_reset; FM_PROBE_MODE=sim; _on; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403   # F9e: sonda KAPALI iken `on` geri alır; açık diski önce sim ile kur
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "4" "F3: disk AÇIK + çalışan KAPALI: rc 4 (QL9-M2: 'kayıtla uyumlu doğrulanmış AÇIK' değil → rc 0 verilmez; güvenli yön, uyarı)"
assert_contains "$out" "reload bekliyor" "F3: uyarı"
# sonda yapılamıyor → doğrulanamadı bilgisi; F8-L4: rc 4
_fm_reset; _on; _domconf_fm_auth example.com off >/dev/null 2>&1
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "4" "F4: sonda yokken (kör) KAPALI disk rc 4 = doğrulanamadı (F8-L4: rc 0 yalnız doğrulanmış KAPALI / kayıtla uyumlu AÇIK)"
assert_contains "$out" "çalışan durum DOĞRULANAMADI" "F4: 'doğrulanamadı' söylenir (KAPALI uydurulmaz)"
# kayıt yok + çalışan AÇIK imzası: alarm
_fm_reset; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=411
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "F5: kayıtsız alanda çalışan AÇIK imzası → rc 1"
assert_contains "$out" "FM HÂLÂ AÇIK" "F5: alarm"
# https ulaşılamaz → http'ye düşer
_fm_reset; FM_PROBE_MODE=sim; FM_SIM_SCHEMES="http"; _on
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "AÇIK imzası (411)" "F6: https yoksa http sondası"
assert_contains "$(cat "$CURL_LOG")" "https://example.com:443/_fm/up/1/0" "F6: önce https denendi"
assert_contains "$(cat "$CURL_LOG")" "http://example.com:80/_fm/up/1/0" "F6: sonra http"
# port ortamı
_fm_reset; FM_PROBE_MODE=sim; _on; : > "$CURL_LOG"
( SRVCTL_FM_PROBE_HTTPS_PORT=18701; _domconf_fm_auth example.com status ) >/dev/null 2>&1
assert_contains "$(cat "$CURL_LOG")" "https://example.com:18701/_fm/up/1/0 put=1 resolve=example.com:18701:127.0.0.1" "F7: SRVCTL_FM_PROBE_HTTPS_PORT --resolve ile birlikte uygulanır"
# SARMALAYICI KANITI: sonda curl'ü taklitten geçti, yalnız 127.0.0.1'e çözüldü, DENY 0
assert_eq "$(grep -c '^DENY' "$CURL_LOG")" "0" "F8: sondanın DENY edilen isteği 0 (dışarı istek yok)"
assert_eq "$(grep -v 'resolve=[^ ]*:127.0.0.1$' "$CURL_LOG" | grep -c .)" "0" "F8: her sonda isteği --resolve …:127.0.0.1 taşıyor"
out=$(curl -s https://evil.example/x 2>&1); rc=$?
assert_eq "$rc" "7" "F9: taklit, --resolve'suz/dış hedefi REDDEDER (kalkan çalışıyor)"
assert_contains "$(tail -1 "$CURL_LOG")" "DENY https://evil.example/x" "F9: DENY günlüğe yazıldı"
# düşman alan adı sondaya HİÇ ulaşmaz
: > "$CURL_LOG"; _domconf_fm_runtime_probe 'a;b.com'; assert_eq "$_FMRT_STATE|$(grep -c . "$CURL_LOG")" "unknown|0" "F10: güvensiz alan adı: curl çağrılmaz"
_domconf_fm_runtime_probe '-oevil'; assert_eq "$_FMRT_STATE|$(grep -c . "$CURL_LOG")" "unknown|0" "F10: '-' ile başlayan alan adı: curl çağrılmaz"

echo "── G: yetenek beyanı (L4) ──"
out=$(_domconf_fm_auth --capabilities 2>&1)
assert_contains "$out" " f5-supersede=1" "G1: f5-supersede=1"
assert_contains "$out" " f6-emergency-off=1" "G1: f6-emergency-off=1"
assert_contains "$out" "srvctl-fm-caps v1 dry=1 fm-root=1" "G1: eski alanlar duruyor"
assert_contains "$out" " f6-emergency-off=1 f7-sig=1 f7-emergency-marker=1 f8-stage-gate=1 f8-closed-evidence=1 f9e-on-rc4=1 f9e-state-untrusted=1" "G1: F7/F8/F9e alanları sözleşme sırasıyla sonda (M4, §15/49)"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "1" "G1: tek satır"

echo "── H: L1 — .superseded.bk.* görünür, sayılır, yetim kalmaz ──"
_fm_reset; _on; _domconf_fm_auth example.com off >/dev/null 2>&1
_domconf_fm_auth example.com status >/dev/null 2>&1; rc0=$?
mkdir -p "${SD}/.superseded.bk.example_com.AAAAAA"
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "$rc0" "H1: ayrılmış yedek status rc'sini DEĞİŞTİRMEZ (yedeksiz rc ${rc0} ile aynı)"
assert_contains "$out" "1 adet ayrılmış (.superseded.bk.*)" "H1: status sayıyı söyler"
assert_contains "$out" "SİLMEZ" "H1: politika (otomatik silmez) söylenir"
assert_not_contains "$out" "EŞİĞİ" "H1: eşik altında eşik uyarısı yok"
for i in BBBBBB CCCCCC DDDDDD EEEEEE FFFFFF; do mkdir -p "${SD}/.superseded.bk.example_com.${i}"; done
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "6 adet" "H2: 6 adet sayılır"
assert_contains "$out" "SAYI EŞİĞİ (5) AŞILDI" "H2: eşik üstü uyarı"
mkdir -p "${SD}/.superseded.bk.example_com2.ZZZZZZ"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "6 adet" "H3: önek-komşu alan (example_com2) sayıma KARIŞMAZ"
out=$(_domconf_nginx_audit example.com 2>&1)
assert_contains "$out" "BİLGİ: 6 adet ayrılmış (.superseded.bk.*)" "H4: nginx-audit anar"
out=$(_domconf_fm_root_cmd example.com 2>&1)
assert_contains "$out" "BİLGİ: 6 adet ayrılmış (.superseded.bk.*)" "H5: fm-root planı (kuru) anar"
out=$(_domconf_fm_root_cmd example.com --apply 2>&1)
assert_contains "$out" "6 adet ayrılmış (.superseded.bk.*)" "H6: fm-root --apply anar"
assert_eq "$(_supn)" "7" "H7: hiçbiri OTOMATİK silinmedi"
# yalnız .superseded kalmışsa forget yetim bırakmaz
_fm_reset; mkdir -p "${SD}"; mkdir -p "${SD}/.superseded.bk.example_com.AAAAAA" "${SD}/.superseded.bk.baska_com.AAAAAA"
assert_eq "$(_exists "$MAN")|$(_bkn)" "yok|0" "H8: hazırlık: kayıt yok, .bk yok, yalnız .superseded"
_domconf_fm_auth_forget example_com
assert_eq "$(_exists "${SD}/.superseded.bk.example_com.AAAAAA")" "yok" "H8: yalnız .superseded kalmışsa forget temizler (eskiden yetim)"
assert_eq "$(_exists "${SD}/.superseded.bk.baska_com.AAAAAA")" "var" "H8: komşu alanın .superseded'ına dokunulmadı"
# yalnız acil işareti kalmışsa da
_fm_reset; mkdir -p "$SD"; : > "$MARK"
_domconf_fm_auth_forget example_com
assert_eq "$(_exists "$MARK")" "yok" "H9: yalnız acil işareti kalmışsa forget temizler"

echo "── I: L2 — restore_file dizin-hedefli sembolik bağı reddeder ──"
_fm_reset; mkdir -p "${FM_STUBS}/tdir"; echo "src" > "${FM_STUBS}/srcf"; ln -s "${FM_STUBS}/tdir" "${FM_STUBS}/dstlink"
_domconf_fm_restore_file "${FM_STUBS}/srcf" "${FM_STUBS}/dstlink"; assert_eq "$?" "1" "I1: hedef dizine sembolik bağ → rc 1"
assert_eq "$(ls -A "${FM_STUBS}/tdir" | wc -l | tr -d ' ')" "0" "I1: hedef dizinin İÇİNE dosya düşmedi"
mkdir -p "${FM_STUBS}/realdir"; _domconf_fm_restore_file "${FM_STUBS}/srcf" "${FM_STUBS}/realdir"; assert_eq "$?" "1" "I2: gerçek dizin hedef → rc 1"
echo "orig" > "${FM_STUBS}/filetarget"; ln -s "${FM_STUBS}/filetarget" "${FM_STUBS}/filelink"
_domconf_fm_restore_file "${FM_STUBS}/srcf" "${FM_STUBS}/filelink"; assert_eq "$?" "0" "I3: dosyaya sembolik bağ hedef → bağ değiştirilir (rc 0)"
assert_eq "$(cat "${FM_STUBS}/filetarget")" "orig" "I3: bağın hedefi EZİLMEDİ"
assert_eq "$([[ -L "${FM_STUBS}/filelink" ]] && echo bag || echo dosya)" "dosya" "I3: bağın yerine gerçek dosya"

echo "── J: L3 — iki .bk iletisi 'fm-auth off' yolunu gösterir ──"
_fm_reset; _on; _mk_stale_bk AAAAAA; _mk_stale_bk BBBBBB
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1; assert_eq "$?" "1" "J1: iki yedek: kurtarma rc 1"
assert_contains "$(_out)" "srvctl domain fm-auth example.com off" "J1: kurtarma iletisi 'fm-auth off' der"
_domconf_fm_root_plan example.com
assert_contains "$_FRP_WHY" "srvctl domain fm-auth example.com off" "J2: fm-root planı 'fm-auth off' der"
_domconf_fm_auth example.com off >/dev/null 2>&1
assert_eq "$(_bkn)|$(_supn)" "0|2" "J3: 'fm-auth off' iki yedeği de AYIRIR"

echo "── K: M2 — 'vhost include ETMİYOR' hatası doğru çıkışı gösterir ──"
_fm_reset; printf 'server {\n    server_name example.com;\n}\n' > "$VHOST"
_on; assert_eq "$?" "1" "K1: include'suz vhost: fm-auth on reddedilir"
msg="$(_out)"
assert_contains "$msg" "include /etc/nginx/custom.d/example_com/*.conf;" "K1: doğru metin: elle include satırı"
assert_contains "$msg" "nginx -t" "K1: nginx -t ile doğrula"
assert_contains "$msg" "rate-limit example.com <mevcut-profil>" "K1: vhost'u yeniden üreten komut anılır"
assert_contains "$msg" "TAMAMINI şablondan yeniden yazar" "K1: yan etkisi yazılı"
assert_not_contains "$msg" "Önce: srvctl domain repair" "K1: etkisiz 'repair' önerisi KALKTI"
assert_contains "$msg" "'repair' vhost YAZMAZ, çare DEĞİLDİR" "K1: neden repair değil"
printf 'x\n' > "${FM_STUBS}/cand.conf"
( _domconf_edit_nginx example.com --file "${FM_STUBS}/cand.conf" ) >"$OUTF" 2>&1; assert_eq "$?" "1" "K2: domain nginx de include'suz vhost'u reddeder"
assert_contains "$(_out)" "include /etc/nginx/custom.d/example_com/*.conf;" "K2: aynı doğru metin"
assert_not_contains "$(_out)" "Önce: srvctl domain repair" "K2: etkisiz 'repair' önerisi KALKTI"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"

test_summary
