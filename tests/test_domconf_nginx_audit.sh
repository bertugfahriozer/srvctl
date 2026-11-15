#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitlerinin okuduğu bayraklar (MOCK_*, NGINX_*, SYSTEMCTL_RC …) bu dosyada atanır
# 'domain nginx-audit [<domain>|--all] [--quarantine]' — SALT-OKUR denetim.
#  - disk-glob (custom.d/<sname>/*.conf); nginx -t / -T / reload ÇALIŞTIRMAZ
#  - çıkış kodu: 0 temiz | 1 ihlal | 2 doğrulanamadı; '--json' yok
#  - salt-okurluk: dosya md5'leri (kullanıcı dosyaları + üretilmiş + kayıt) DEĞİŞMEZ
#  - '--quarantine' yalnız açık bayrakla; <ad>.srvctl-rejected, nginx -t, reload, hatada geri
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
_audit() { ( _domconf_nginx_audit "$@" ) >"$OUTF" 2>&1; }
_tree_md5() { ( cd "$1" && find . -type f -o -type l | sort | while read -r f; do printf '%s %s\n' "$f" "$(_md5 "$f" 2>/dev/null || echo link)"; done ) | { if command -v md5sum >/dev/null; then md5sum; else md5; fi; }; }
mk_dom() { mkdir -p "${WEB_ROOT}/$1"; : > "${WEB_ROOT}/$1/.credentials"; mkdir -p "${SRVCTL_NGINX_CUSTOM_DIR}/$(safe_name "$1")"; }
# QL4-M4: denetim 403 kökünü de denetler — "temiz" (0) yalnız kökü kurulu alanda.
_root() { ( _domconf_fm_root_provision "${1:-example.com}" 0 ) >/dev/null 2>&1; }

echo "── A: çıktı + çıkış kodları ──"
_audit example.com; assert_eq "$?" "1" "QL4-M4: kökü olmayan alan (boş dizin): 1"
assert_contains "$(cat "$OUTF")" "KÖK-YOK" "…KÖK-YOK satırı"
assert_contains "$(cat "$OUTF")" "srvctl domain fm-root example.com --apply" "…çözüm: fm-root"
_root
_audit example.com; assert_eq "$?" "0" "boş dizin + 403 kökü: 0"
assert_contains "$(cat "$OUTF")" "temiz" "…temiz basar"
printf 'client_max_body_size 10m;\n' > "${CUR_DIR}/00-custom.conf"
_audit example.com; assert_eq "$?" "0" "temiz dosya: 0"
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/10-app.conf"
_audit example.com; assert_eq "$?" "1" "ihlal: 1"
out="$(cat "$OUTF")"
assert_contains "$out" "10-app.conf:2:proxy_pass:" "çıktı dosya:satır:direktif:gerekçe biçiminde"
assert_contains "$out" "[example.com]" "alan başlığı"
assert_contains "$out" "İHLAL VAR" "özet"
assert_not_contains "$out" "00-custom.conf:" "temiz dosya listelenmez"
assert_eq "$(grep -c 'proxy_pass' <<< "$out")" "1" "tek ihlal tek satır"
# doğrulanamadı: çözümlenemeyen dosya
printf 'location /x {\n    return 204;\n' > "${CUR_DIR}/20-bozuk.conf"
_audit example.com; assert_eq "$?" "2" "çözümlenemeyen dosya: 2 (ihlal de varken 2 öncelikli)"
assert_contains "$(cat "$OUTF")" "10-app.conf:2:proxy_pass" "…ihlal satırları yine basılır"
assert_contains "$(cat "$OUTF")" "20-bozuk.conf" "…bozuk dosya adı basılır"
assert_contains "$(cat "$OUTF")" "DOĞRULANAMADI" "…özet"
rm -f "${CUR_DIR}/20-bozuk.conf" "${CUR_DIR}/10-app.conf"
# .conf olmayan dosya: BİLGİ
printf 'proxy_pass http://x;\n' > "${CUR_DIR}/notes.txt"
_audit example.com; assert_eq "$?" "0" ".conf olmayan dosya ihlal sayılmaz (nginx yüklemez)"
assert_contains "$(cat "$OUTF")" "BILGI notes.txt" "…ama BİLGİ satırı basılır"
rm -f "${CUR_DIR}/notes.txt"
# sembolik bağ *.conf
printf 'client_max_body_size 5m;\n' > "${FM_STUBS}/target.conf"; ln -s "${FM_STUBS}/target.conf" "${CUR_DIR}/30-link.conf"
_audit example.com; assert_eq "$?" "1" "sembolik bağ *.conf: ihlal"
assert_contains "$(cat "$OUTF")" "30-link.conf:0:sembolik-bağ" "…gerekçe"
rm -f "${CUR_DIR}/30-link.conf"
# rezerve ad
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/99-fm.conf"
_audit example.com; assert_eq "$?" "1" "rezerve ad: ihlal"
assert_contains "$(cat "$OUTF")" "rezerve" "…gerekçe rezerve"
rm -f "${CUR_DIR}/99-fm.conf"
# kullanım hataları
( _domconf_nginx_audit ) >/dev/null 2>&1; assert_eq "$?" "1" "argümansız: kullanım hatası"
( _domconf_nginx_audit example.com --json ) >/dev/null 2>&1; assert_eq "$?" "1" "--json YOK"
( _domconf_nginx_audit yok.test ) >/dev/null 2>&1; assert_eq "$?" "1" "olmayan alan"
( _domconf_nginx_audit example.com --bilinmeyen ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek"
# custom.d dizini olmayan alan
mkdir -p "${WEB_ROOT}/nodir.com"; _audit nodir.com; assert_eq "$?" "1" "QL4-M4: custom.d dizini olmayan alan: 1 (403 kökü yok)"
assert_contains "$(cat "$OUTF")" "dizini yok" "…söylenir"
assert_contains "$(cat "$OUTF")" "KÖK-YOK" "…KÖK-YOK"

echo "── B: FM üretilmiş dosyaları atlanır; kurcalananlar ihlaldir ──"
_fm_reset
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
_audit example.com; assert_eq "$?" "0" "açık fm-auth: üretilmiş dosyalar atlanır → temiz"
printf '#x\n' >> "$F21"
_audit example.com; assert_eq "$?" "1" "kurcalanmış 21: ihlal"
assert_contains "$(cat "$OUTF")" "21-srvctl-fm-download.conf" "…hangisi"
_fm_reset

echo "── C: SALT-OKUR — hiçbir dosya değişmez, nginx -t/-T/reload çağrılmaz ──"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
printf 'location /x { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/10-app.conf"
printf 'client_max_body_size 10m;\n' > "${CUR_DIR}/00-custom.conf"
printf 'x\n' > "${CUR_DIR}/n.txt"
b1=$(_tree_md5 "$CUR_DIR"); b2=$(_tree_md5 "${SRVCTL_STATE_DIR}"); : > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_audit example.com; assert_eq "$?" "1" "ihlalli denetim"
_audit --all; _audit example.com
assert_eq "$(_tree_md5 "$CUR_DIR")" "$b1" "custom.d ağacı DEĞİŞMEDİ (md5)"
assert_eq "$(_tree_md5 "${SRVCTL_STATE_DIR}")" "$b2" "state ağacı DEĞİŞMEDİ (md5)"
assert_eq "$(wc -l < "$NGINX_T_LOG" | tr -d ' ')" "0" "nginx -t/-T HİÇ çağrılmadı"
assert_eq "$(_reloads)" "0" "reload yok"
assert_eq "$(find "$CUR_DIR" -name '*srvctl-rejected' | wc -l | tr -d ' ')" "0" "karantina dosyası yok (varsayılan kapalı)"
# 'audit' kodu 'domain nginx --show' yolunu (iskelet YAZAN) kullanmaz
body="$(declare -f _domconf_nginx_audit)"
assert_not_contains "$body" "_domconf_edit_nginx" "audit _domconf_edit_nginx'i çağırmaz"
assert_not_contains "$body" "_domconf_nginx_skeleton" "audit iskelet YAZMAZ"
assert_not_contains "$body" "nginx -T" "audit nginx -T çalıştırmaz"
# yeni alan (custom.d dizini + iskelet yok) audit sonrası YARATILMAMIŞ olmalı
mkdir -p "${WEB_ROOT}/nodir2.com"
_audit nodir2.com
assert_eq "$([[ -e "${SRVCTL_NGINX_CUSTOM_DIR}/nodir2_com" ]] && echo var || echo yok)" "yok" "audit custom.d dizinini YARATMAZ"
assert_eq "$([[ -e "${SRVCTL_STATE_DIR}/_fm-auth" ]] && echo var || echo yok)" "var" "(kontrol) önceki on kayıt dizinini yaratmıştı"
_fm_reset

echo "── D: --all ──"
mk_dom a.com; mk_dom b.com
printf 'client_max_body_size 10m;\n' > "${SRVCTL_NGINX_CUSTOM_DIR}/a_com/00-custom.conf"
printf 'rewrite ^ /__fm_auth last;\n' > "${SRVCTL_NGINX_CUSTOM_DIR}/b_com/00-custom.conf"
_audit --all; assert_eq "$?" "1" "--all: bir alanda ihlal → 1"
out="$(cat "$OUTF")"
assert_contains "$out" "[a.com]" "--all: a.com denetlendi"
assert_contains "$out" "[b.com]" "--all: b.com denetlendi"
assert_contains "$out" "00-custom.conf:1:rewrite" "--all: b.com bulgusu"
rm -rf "${WEB_ROOT}/a.com" "${WEB_ROOT}/b.com" "${SRVCTL_NGINX_CUSTOM_DIR}/a_com" "${SRVCTL_NGINX_CUSTOM_DIR}/b_com"

echo "── E: --quarantine ──"
_fm_reset; _root
printf 'location /x { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/10-app.conf"
printf 'client_max_body_size 10m;\n' > "${CUR_DIR}/00-custom.conf"
: > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_audit example.com --quarantine; assert_eq "$?" "1" "karantina: sonuç hâlâ 1 (denetim anındaki ihlal)"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")" "yok" "ihlalli dosya taşındı"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "var" "…<ad>.srvctl-rejected"
assert_eq "$(cat "${CUR_DIR}/10-app.conf.srvctl-rejected")" 'location /x { proxy_pass http://127.0.0.1:1; }' "…içerik korundu"
assert_eq "$(_exists "${CUR_DIR}/00-custom.conf")" "var" "temiz dosya yerinde"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "1" "karantina sonrası nginx -t"
assert_eq "$(_reloads)" "1" "…ve reload"
_audit example.com; assert_eq "$?" "0" "karantina sonrası denetim temiz"
# .srvctl-rejected nginx glob'una (*.conf) girmez
rej="10-app.conf.srvctl-rejected"
case "$rej" in *.conf) echo "  FAIL ad *.conf ile biter"; TESTS_FAIL=$((TESTS_FAIL+1));; *) echo "  PASS .srvctl-rejected adı *.conf glob'una GİRMEZ"; TESTS_RUN=$((TESTS_RUN+1));; esac
# nginx -t başarısız → geri al
mv "${CUR_DIR}/10-app.conf.srvctl-rejected" "${CUR_DIR}/10-app.conf"
NGINX_TEST_RC=1; : > "$RELOAD_LOG"
_audit example.com --quarantine; rc=$?
assert_eq "$rc" "1" "karantina + nginx -t hatası: başarısız"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")" "var" "…dosya GERİ alındı"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "yok" "…karantina adı kalmadı"
assert_eq "$(_reloads)" "0" "…reload yok"
NGINX_TEST_RC=0
# doğrulanamayan dosya (rc 2) karantinaya ALINMAZ (yalnız ihlalli rc 1 taşınır)
printf 'location /x {\n    return 204;\n' > "${CUR_DIR}/20-bozuk.conf"
_audit example.com --quarantine
assert_eq "$(_exists "${CUR_DIR}/20-bozuk.conf")" "var" "doğrulanamayan dosya karantinaya alınmaz"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "var" "…ihlalli olan alınır"
# izin listesi kitaplığı yoksa hiçbir şey taşınmaz (hepsi doğrulanamadı)
mv "${CUR_DIR}/10-app.conf.srvctl-rejected" "${CUR_DIR}/10-app.conf"; rm -f "${CUR_DIR}/20-bozuk.conf"
( unset -f _ngxallow_scan; SRVCTL_ROOT="$(mktemp -d "${FM_STUBS}/noroot.XXXXXX")"; _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "2" "kitaplık yoksa: 2"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(_exists "${CUR_DIR}/00-custom.conf")" "varvar" "kitaplık yoksa HİÇBİR dosya karantinaya alınmaz"
# üretilmiş FM dosyaları karantinaya alınmaz
_fm_reset
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
printf 'location /x { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/10-app.conf"
_audit example.com --quarantine
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")" "varvarvar" "karantina üretilmiş FM dosyalarına DOKUNMAZ"
_fm_reset

echo "── F: QL4-H1 — karantina srvctl üretimine ASLA dokunmaz, köksüz/güvenilmez alanda YAPILMAZ ──"
BADU='location /x { proxy_pass http://127.0.0.1:1; }'
# F1: kayıtlı 403 kökü KURCALANMIŞ (TAMPERED 20) + ihlalli kullanıcı dosyası
_fm_reset; _root
printf 'location = /_fm { return 200 "x"; }\nproxy_pass http://x;\n' > "$F20"; t20=$(_md5 "$F20")
printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"
_audit example.com --quarantine; rc=$?
assert_eq "$rc" "1" "F1: TAMPERED 20 + ihlal: rc 1"
assert_eq "$(_exists "$F20")$(_md5 "$F20")" "var${t20}" "F1: 20 (srvctl adı) TAŞINMADI, içerik aynı"
assert_eq "$(_exists "${F20}.srvctl-rejected")" "yok" "F1: 20.srvctl-rejected YOK"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")" "var" "F1: kök sağlam değilken kullanıcı dosyası da TAŞINMAZ"
assert_contains "$(cat "$OUTF")" "KARANTİNA YAPILMADI" "F1: karantina yapılmadı denir"
assert_contains "$(cat "$OUTF")" "srvctl domain fm-root example.com --apply" "F1: fm-root önerilir"
assert_contains "$(cat "$OUTF")" "KÖK-SAĞLAM-DEĞİL" "F1: kök sorunu raporlanır"
assert_eq "$(_reloads)" "0" "F1: reload YOK"
# F2: STATE-UNTRUSTED (kayıt dizini root'a ait değil) — kök dosyası olsa da HİÇBİR şey taşınmaz
_fm_reset; _root; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"; h20=$(_md5 "$F20")
MOCK_BAD_OWNER="${SRVCTL_STATE_DIR}/_fm-auth"
_audit example.com --quarantine; rc=$?
MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "F2: STATE-UNTRUSTED: rc 1"
assert_eq "$(_exists "$F20")$(_md5 "$F20")" "var${h20}" "F2: 403 kökü YERİNDE (taşınmadı)"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(find "$CUR_DIR" -name '*srvctl-rejected*' | wc -l | tr -d ' ')" "var0" "F2: hiçbir dosya taşınmadı"
assert_contains "$(cat "$OUTF")" "KARANTİNA YAPILMADI: STATE-UNTRUSTED" "F2: neden söylenir"
assert_contains "$(cat "$OUTF")" "fm-root" "F2: fm-root yolu söylenir"
# F3: kök sağlam; kayıt-dışı 90 (rezerve ad) + ihlalli kullanıcı dosyası → 90 TAŞINMAZ, kullanıcı dosyası taşınır
_fm_reset; _root; printf 'client_max_body_size 1m;\n' > "$F90"; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"; : > "$RELOAD_LOG"
_audit example.com --quarantine
assert_eq "$(_exists "$F90")$(_exists "${F90}.srvctl-rejected")" "varyok" "F3: rezerve adlı 90 TAŞINMADI"
assert_contains "$(cat "$OUTF")" "KARANTİNAYA ALINMADI: 90-srvctl-fm-auth.conf" "F3: neden söylenir"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "yokvar" "F3: kullanıcı dosyası karantinada"
assert_eq "$(_exists "$F20")" "var" "F3: 403 kökü yerinde"
assert_eq "$(_reloads)" "1" "F3: tek reload"
# F4: kökü olmayan (YOK) alanda karantina YAPILMAZ
_fm_reset; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"
_audit example.com --quarantine; rc=$?
assert_eq "$rc" "1" "F4: YOK + ihlal: rc 1"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")" "var" "F4: köksüz alanda kullanıcı dosyası TAŞINMAZ"
assert_contains "$(cat "$OUTF")" "KARANTİNA YAPILMADI: 403 kökü sağlam değil" "F4: neden söylenir"
# F5: nginx -t sırasında kök bozulursa (yarış) → karantina GERİ, reload YOK
_fm_reset; _root; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"; : > "$RELOAD_LOG"
_break_root() { [[ "$NGINX_T_ARGS" == "-t" ]] && rm -f "$F20"; return 0; }
NGINX_T_HOOK=_break_root; _audit example.com --quarantine; rc=$?; NGINX_T_HOOK=""
assert_eq "$rc" "1" "F5: karantina sonrası kök sağlam değil → başarısız"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "varyok" "F5: taşıma GERİ alındı"
assert_eq "$(_reloads)" "0" "F5: reload YOK"
assert_contains "$(cat "$OUTF")" "GERİ ALIN" "F5: geri alındığı söylenir"

echo "── G: rev-L5/L6 — atomiklik, sarkan bağ, satır sonlu ad, benzersiz ad, kilit ──"
# G1: sarkan sembolik bağ *.conf (ihlal) → taşınır (eskiden [[ -f ]] yüzünden sessizce kalıyordu)
_fm_reset; _root; ln -s "${FM_STUBS}/yok-boyle-bir-hedef" "${CUR_DIR}/30-dangle.conf"
_audit example.com --quarantine
assert_eq "$(_exists "${CUR_DIR}/30-dangle.conf")$(_exists "${CUR_DIR}/30-dangle.conf.srvctl-rejected")" "yokvar" "G1: sarkan bağ karantinaya alındı"
# G2: satır sonu içeren ad
_fm_reset; _root; NLN="${CUR_DIR}/40-a"$'\n'"b.conf"; printf '%s\n' "$BADU" > "$NLN"
_audit example.com --quarantine
assert_eq "$(_exists "$NLN")$(_exists "${NLN}.srvctl-rejected")" "yokvar" "G2: satır sonlu ad karantinaya alındı"
# G3: önceki karantina kanıtının ÜZERİNE yazılmaz
_fm_reset; _root; printf 'eski-kanit\n' > "${CUR_DIR}/10-app.conf.srvctl-rejected"; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"
_audit example.com --quarantine
assert_eq "$(cat "${CUR_DIR}/10-app.conf.srvctl-rejected")" "eski-kanit" "G3: eski karantina dosyası korundu"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected.1")$(_exists "${CUR_DIR}/10-app.conf")" "varyok" "G3: yeni karantina benzersiz adla (.1)"
# G4: ortada mv hatası → ÖNCEKİ taşımalar geri (hepsi-ya-hiçbiri)
_fm_reset; _root; printf '%s\n' "$BADU" > "${CUR_DIR}/10-a.conf"; printf '%s\n' "$BADU" > "${CUR_DIR}/11-b.conf"; : > "$RELOAD_LOG"
( mv() { if [[ "${3:-}" == *"/11-b.conf" ]]; then return 1; fi; command mv "$@"; }; _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "G4: taşıma hatası → başarısız"
assert_eq "$(_exists "${CUR_DIR}/10-a.conf")$(_exists "${CUR_DIR}/11-b.conf")$(find "$CUR_DIR" -name '*srvctl-rejected*' | wc -l | tr -d ' ')" "varvar0" "G4: önceki taşıma GERİ alındı, karantina adı kalmadı"
assert_eq "$(_reloads)" "0" "G4: reload YOK"
# G5: karantina fm-auth kilidi ALTINDA; kilit alınamazsa hiçbir şey taşınmaz
_fm_reset; _root; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"; : > "$FLOCK_LOG"
_audit example.com --quarantine
assert_eq "$(grep -c . "$FLOCK_LOG")" "1" "G5: karantina flock aldı"
_fm_reset; _root; printf '%s\n' "$BADU" > "${CUR_DIR}/10-app.conf"; FLOCK_RC=1; export FLOCK_RC
_audit example.com --quarantine; rc=$?; FLOCK_RC=0; export FLOCK_RC
assert_eq "$rc" "1" "G5: kilit yok → başarısız"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")" "var" "G5: kilitsiz taşıma YOK"

echo "── H: QL4-M4/M3 — kök ve yarım işlem raporu (salt-okur) ──"
_fm_reset; _root; rm -f "$F20"
_audit example.com; assert_eq "$?" "1" "H1: kayıt var + 20 yok: 1"
assert_contains "$(cat "$OUTF")" "KÖK-SAĞLAM-DEĞİL" "H1: KÖK-SAĞLAM-DEĞİL"
_fm_reset; printf 'client_max_body_size 1m;\n' > "$F21"
_audit example.com; assert_eq "$?" "1" "H2: kayıtsız FM adı: 1"
assert_contains "$(cat "$OUTF")" "KÖK-KAYITSIZ" "H2: KÖK-KAYITSIZ"
_fm_reset; _root; mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.AbC123"
b1=$(_tree_md5 "$CUR_DIR"); b2=$(_tree_md5 "${SRVCTL_STATE_DIR}")
_audit example.com; assert_eq "$?" "1" "H3: yarım işlem yedeği: 1"
assert_contains "$(cat "$OUTF")" "YARIM-İŞLEM" "H3: YARIM-İŞLEM satırı"
assert_eq "$(_tree_md5 "$CUR_DIR")$(_tree_md5 "${SRVCTL_STATE_DIR}")" "${b1}${b2}" "H3: denetim salt-okur (yedek de dosyalar da değişmedi)"
rm -rf "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.AbC123"
# custom.d/<sname> sembolik bağ: dosyalar YİNE taranır (gerileme yok), kök doğrulanamadı → ≥1
_fm_reset; rm -rf "$CUR_DIR"; LT="${FM_STUBS}/linked-cd"; mkdir -p "$LT"; ln -s "$LT" "$CUR_DIR"
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${LT}/10-app.conf"
_audit example.com; assert_eq "$?" "1" "H4: bağlı custom.d: 1"
assert_contains "$(cat "$OUTF")" "10-app.conf:2:proxy_pass" "H4: bağ üzerinden dosyalar YİNE taranır"
assert_contains "$(cat "$OUTF")" "KÖK-DOĞRULANAMADI: custom.d/example_com sembolik bağ" "H4: kök doğrulanamadı denir"
rm -f "$CUR_DIR"; rm -rf "$LT"; mkdir -p "$CUR_DIR"
_fm_reset

test_summary
