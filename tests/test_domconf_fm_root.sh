#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitlerinin okuduğu bayraklar (MOCK_*, NGINX_*, SYSTEMCTL_RC …) bu dosyada atanır
# HER alanda /_fm 403 kökü (kullanıcı kararı 2026-10-25): 'domain add' ve 'domain repair'
# fm-auth hiç açılmamış alanda da 20-srvctl-fm-upload.conf'u (location = /_fm + ^~ /_fm/ → 403)
# srvctl üretimi olarak yazar ve köken kaydına `state off` ile girer.
#  - fm-auth on kökün yerini alır; off kökü geri bırakır; clone hedefte kökle BAŞLAR (kaynağın
#    açık durumu kopyalanmaz); idempotent; kayıtsız FM adlı kullanıcı dosyası EZİLMEZ;
#    nginx -t başarısızsa geri alınır; güvenilmez kayıt/flock yok → yazım yok.
# Gerçek nginx 1.28 ölçümü: tests/test_domconf_nginx_real.sh "3b".
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
_prov() { ( _domconf_fm_root_provision "$@" ) >"$OUTF" 2>&1; }
OFFTXT="$(_domconf_fm_render_off example_com)"

echo "── A: taze alan → kök kurulur ──"
_fm_reset
_prov example.com 0; assert_eq "$?" "0" "provision rc 0"
assert_eq "$(ls "$CUR_DIR" | tr '\n' ' ')" "20-srvctl-fm-upload.conf " "YALNIZ 20 (90/21 yok)"
assert_eq "$(cat "$F20")" "$OFFTXT" "içerik = fm-auth off kökü (srvctl üretimi)"
assert_eq "$(grep -c '^location = /_fm { return 403 "srvctl-fm-closed [0-9a-f]\{12\}"; }$' "$F20")" "1" "location = /_fm → imzalı 403 (tam eşleşme)"
assert_eq "$(grep -c '^location \^~ /_fm/ { return 403 "srvctl-fm-closed [0-9a-f]\{12\}"; }$' "$F20")" "1" "location ^~ /_fm/ → imzalı 403"
assert_eq "$(_mode "$F20")" "644" "dosya 0644"
assert_contains "$(cat "$MAN")" "state off" "köken kaydı: state off"
assert_ok _fmprov_is_generated example_com "$F20"
assert_eq "$(_reloads)" "0" "reload=0 → reload YOK (add kendi reload'unu yapar)"
assert_eq "$(grep -c . "$NGINX_T_LOG")" "1" "nginx -t bir kez"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "KAPALI (403 kökü)" "status: KAPALI (403 kökü)"
_domconf_fm_auth example.com status >/dev/null 2>&1; assert_eq "$?" "4" "status rc 4 (sonda kör: çalışan durum doğrulanamadı; F8-L4)"
# köken kaydı sayesinde kullanıcı dosyası taramasında ihlal DEĞİL
_domconf_scan_user_files example.com example_com "$CUR_DIR" >/dev/null 2>&1; assert_eq "$?" "0" "üretilmiş kök kullanıcı taramasında ihlal sayılmaz"

echo "── B: reload=1 ve idempotens ──"
# ARCHITECTURE §15/93(b)(1): "yazım yok → nginx -t/reload yok" YALNIZ çalışan nginx KESİN KAPALI imzası veriyorsa geçerlidir (doğrulanamayan çalışan durum "kapalı" sayılmaz ve
# diskte KAPALI kanıtı varken yeniden yüklenir). Bu dosyada canlı sonda kapalıdır; KESİN KAPALI imzası bir kanca ile verilir, kör sonda ayrı sınanır.
eval "_c13_orig_probe() $(declare -f _domconf_fm_runtime_probe | sed 1d)"
_c13_probe_closed() { _domconf_fm_runtime_probe() { _FMRT_STATE="closed"; _FMRT_DETAIL="test: kesin KAPALI imzası"; return 0; }; }
_c13_probe_blind() { _domconf_fm_runtime_probe() { _c13_orig_probe "$@"; }; }
_fm_reset
_prov example.com 1; assert_eq "$(_reloads)" "1" "reload=1 → bir reload"
h1=$(_md5 "$F20"); m1=$(_md5 "$MAN"); t1=$(grep -c . "$NGINX_T_LOG")
_c13_probe_closed
_prov example.com 1; assert_eq "$?" "0" "ikinci çağrı rc 0"
assert_eq "$(_md5 "$F20")$(_md5 "$MAN")" "${h1}${m1}" "ikinci çağrı dosya+kaydı DEĞİŞTİRMEZ"
assert_eq "$(grep -c . "$NGINX_T_LOG")" "$t1" "ikinci çağrı nginx -t ÇALIŞTIRMAZ"
assert_eq "$(_reloads)" "1" "ikinci çağrı reload ETMEZ (çalışan KESİN KAPALI)"
_c13_probe_blind
_prov example.com 1; assert_eq "$?|$(_reloads)" "0|2" "ikinci çağrı, sonda kör: yazım yok ama doğrulanamayan çalışan durum → yeniden yüklenir"

echo "── C: açık alana dokunmaz; on kökün yerini alır; off kökü geri bırakır ──"
_fm_reset
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
hOn=$(_md5 "$F20"); mOn=$(_md5 "$MAN")
_prov example.com 1; assert_eq "$?" "0" "açık alanda rc 0"
assert_eq "$(_md5 "$F20")$(_md5 "$MAN")" "${hOn}${mOn}" "açık alan DEĞİŞMEDİ"
assert_contains "$(cat "$MAN")" "state on" "kayıt hâlâ on"
_fm_reset; _prov example.com 0
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1; assert_eq "$?" "4" "kök varken on başarılı (rc 4: açıldı, bu testte FM canlı sondası yok → doğrulanamadı; F9e-3 §15/47(a), eskiden 0)"
assert_contains "$(cat "$MAN")" "state on" "kök varken on: kayıt on yazıldı (reddedilmedi)"
assert_ne "$(cat "$F20")" "$OFFTXT" "on: 20 artık kök DEĞİL (gerçek yapılandırma)"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "varvar" "on: 90 ve 21 kuruldu"
assert_contains "$(cat "$MAN")" "state on" "on: kayıt on"
( _domconf_fm_auth example.com off ) >/dev/null 2>&1
assert_eq "$(cat "$F20")" "$OFFTXT" "off: kök geri"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "off: 90/21 kalktı"
assert_contains "$(_domconf_fm_auth example.com status 2>&1)" "KAPALI (403 kökü)" "off sonrası status KAPALI (403 kökü)"

echo "── D: clone hedefte kökle BAŞLAR, kaynağın açık durumu kopyalanmaz ──"
_fm_reset
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
printf 'client_max_body_size 9M;\n' > "${CUR_DIR}/00-custom.conf"
SRC_MD5=$(_md5 "$MAN")
mkdir -p "${WEB_ROOT}/hedef.com"
_domain_clone_conf_files example.com hedef.com 0 >/dev/null 2>&1
DDIR="${SRVCTL_NGINX_CUSTOM_DIR}/hedef_com"
assert_eq "$(ls "$DDIR" | tr '\n' ' ')" "00-custom.conf " "clone_conf_files hedefe 20/21/90 KOPYALAMAZ"
# 'domain add' (clone'un 1. adımı) kökü kurar:
_domconf_fm_root_provision hedef.com 0 >/dev/null 2>&1; assert_eq "$?" "0" "hedefte kök kuruldu"
assert_eq "$(cat "${DDIR}/20-srvctl-fm-upload.conf")" "$(_domconf_fm_render_off hedef_com)" "hedef 20 = HEDEFİN kendi imzalı 403 kökü"
assert_ne "$(cat "${DDIR}/20-srvctl-fm-upload.conf")" "$OFFTXT" "hedef 20 kaynağın imzasını TAŞIMAZ (alana özgü imza)"
assert_contains "$(cat "${SRVCTL_STATE_DIR}/_fm-auth/hedef_com.manifest")" "state off" "hedef kayıt: off (kaynak on)"
assert_eq "$(_md5 "$MAN")" "$SRC_MD5" "kaynak kaydı değişmedi"
assert_eq "$(_exists "${DDIR}/90-srvctl-fm-auth.conf")" "yok" "hedefte 90 yok"
assert_contains "$(_domconf_fm_auth hedef.com status 2>&1)" "KAPALI (403 kökü)" "klon status KAPALI (403 kökü)"
# remove kaydı siler
_domconf_fm_auth_forget hedef_com; assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth/hedef_com.manifest")" "yok" "forget: hedef kaydı silindi"
rm -rf "$DDIR"

echo "── E: kayıtsız FM adlı dosya (kullanıcı dosyası) EZİLMEZ ──"
_fm_reset
printf 'location = /_fm { return 200 "x"; }\n' > "$F20"; before=$(_md5 "$F20")
_prov example.com 0; assert_eq "$?" "1" "kayıtsız 20: rc 1"
assert_eq "$(_md5 "$F20")" "$before" "kullanıcının 20 dosyası EZİLMEDİ"
assert_eq "$(_exists "$MAN")" "yok" "kayıt yazılmadı"
assert_contains "$(cat "$OUTF")" "403 kökü kurulamadı" "uyarı açık"
assert_contains "$(cat "$OUTF")" "srvctl domain fm-root example.com --apply" "çıkış yolu söylenir (bilinçli devralma: fm-root)"
_fm_reset; printf 'x\n' > "$F90"
_prov example.com 0; assert_eq "$?" "1" "kayıtsız 90 da engeller"

echo "── F: nginx -t başarısız → geri alınır, çalışan yapılandırma korunur ──"
_fm_reset
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"; b0=$(_md5 "${CUR_DIR}/00-custom.conf")
NGINX_TEST_RC=1
_prov example.com 1; assert_eq "$?" "1" "nginx -t hatası rc 1"
assert_eq "$(_exists "$F20")" "yok" "dosya geri alındı"
assert_eq "$(_exists "$MAN")" "yok" "kayıt geri alındı"
assert_eq "$(_reloads)" "0" "reload YAPILMADI"
assert_eq "$(_md5 "${CUR_DIR}/00-custom.conf")" "$b0" "kullanıcı dosyası dokunulmadı"
assert_contains "$(cat "$OUTF")" "geri alındı" "geri alma raporlandı"
assert_eq "$(find "${SRVCTL_STATE_DIR}/_fm-auth" -name '.bk.*' 2>/dev/null | wc -l | tr -d ' ')" "0" "yedek dizini kalmadı"
assert_eq "$(find "$CUR_DIR" -name '*.srvctl.*' | wc -l | tr -d ' ')" "0" "geçici dosya kalmadı"
NGINX_TEST_RC=0

echo "── G: güvenilmez kayıt dizini / flock yok → yazım yok ──"
_fm_reset
mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; chmod 700 "${SRVCTL_STATE_DIR}/_fm-auth"
MOCK_BAD_OWNER="${SRVCTL_STATE_DIR}/_fm-auth"
_prov example.com 0; assert_eq "$?" "1" "kayıt dizini root'a ait değil (güvenilmez) → rc 1"
MOCK_BAD_OWNER=""
assert_eq "$(_exists "$F20")" "yok" "güvenilmez dizin: dosya YOK"
_fm_reset
FLOCK_RC=1; export FLOCK_RC
_prov example.com 0; assert_eq "$?" "1" "kilit alınamadı → rc 1"
assert_eq "$(_exists "$F20")" "yok" "kilitsiz yazım YOK"
FLOCK_RC=0; export FLOCK_RC
_fm_reset
mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; chmod 700 "${SRVCTL_STATE_DIR}/_fm-auth"
printf 'bozuk\n' > "$MAN"; chmod 600 "$MAN"
_prov example.com 0; assert_eq "$?" "1" "bozuk kayıt (STATE-UNTRUSTED) → rc 1"
assert_contains "$(cat "$OUTF")" "403 kökü kurulamadı (example.com): köken kaydı güvenilmez (STATE-UNTRUSTED)" "neden söylenir (kökün kendi iletisi)"
assert_eq "$(_exists "$F20")" "yok" "bozuk kayıtta dosya YOK"

echo "── H: repair yolu (eski alan) ve ihlalli kullanıcı dosyası ──"
_fm_reset
printf 'location /q {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"; u0=$(_md5 "${CUR_DIR}/00-custom.conf")
out=$(_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 2>&1); assert_eq "$?" "0" "eski alan + ihlalli kullanıcı dosyası: repair kökü yine kurar"
assert_contains "$out" "nginx-audit" "ihlal UYARISI basılır"
assert_eq "$(_md5 "${CUR_DIR}/00-custom.conf")" "$u0" "ihlalli dosyaya DOKUNULMADI"
assert_eq "$(cat "$F20")" "$OFFTXT" "kök kuruldu"
# repair ikinci kez: kök sağlam → değişiklik yok
h=$(_md5 "$F20"); t1=$(grep -c . "$NGINX_T_LOG")
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$?" "0" "sağlam kök: repair rc 0"
assert_eq "$(_md5 "$F20")" "$h" "sağlam kök yeniden yazılmadı"
# kök silinmiş/bozulmuş → repair yeniden üretir
rm -f "$F20"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$(cat "$F20")" "$OFFTXT" "kayıtlı ama eksik kök: repair yeniden üretir"
# nginx -t başarısız → repair dürüstçe başarısız, geri alınmış
_fm_reset; NGINX_TEST_RC=1
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$?" "1" "nginx -t başarısız: repair rc 1"
assert_eq "$(_exists "$F20")$(_exists "$MAN")" "yokyok" "…ve geri alındı"
NGINX_TEST_RC=0

echo "── I: 'domain add' bağlantısı (yapısal) ve repair'in çağrısı ──"
body=$(declare -f _domain_add)
assert_contains "$body" "_domconf_fm_root_provision" "_domain_add kökü kurar"
pos_vh=$(printf '%s\n' "$body" | grep -n '_domain_write_vhost "$domain" "$php_version" "$rate_profile" http' | head -1 | cut -d: -f1)
pos_pv=$(printf '%s\n' "$body" | grep -n '_domconf_fm_root_provision "$domain" 0' | head -1 | cut -d: -f1)
pos_nt=$(printf '%s\n' "$body" | awk -v a="${pos_pv:-0}" 'NR>a && /^    nginx_test;$/ {print NR; exit}')
assert_eq "$([[ -n "$pos_vh" && -n "$pos_pv" && -n "$pos_nt" && $pos_vh -lt $pos_pv && $pos_pv -lt $pos_nt ]] && echo sirali)" "sirali" "sıra: vhost yazımı → kök → nginx_test+reload (kök reload=0)"
assert_contains "$(declare -f _domconf_fm_auth_repair)" "_domconf_fm_root_provision" "repair kayıt yokken kökü kurar"
assert_contains "$(declare -f _domain_repair)" "_domain_repair_fm_step" "_domain_repair FM adımını çağırır"
assert_contains "$(declare -f _domain_repair_fm_step)" "_domconf_fm_auth_repair" "FM adımı fm-auth onarımını çağırır"

echo "── I2: ÇAĞIRANIN INT/TERM/HUP tuzakları korunur (_domain_add'in geri alma tuzağı silinmez) ──"
_fm_reset
out=$( trap 'echo ADDINT' INT; trap 'echo ADDTERM' TERM; trap 'echo ADDHUP' HUP
       _domconf_fm_root_provision example.com 0 >/dev/null 2>&1
       trap -p INT; trap -p TERM; trap -p HUP )
assert_contains "$out" "ADDINT" "INT tuzağı korundu"
assert_contains "$out" "ADDTERM" "TERM tuzağı korundu"
assert_contains "$out" "ADDHUP" "HUP tuzağı korundu"
out=$( _domconf_fm_root_provision example.com 0 >/dev/null 2>&1; trap -p INT; trap -p TERM; trap -p HUP )
assert_eq "$out" "" "çağıranın tuzağı yoksa provision tuzak BIRAKMAZ"
_fm_reset; NGINX_TEST_RC=1
out=$( trap 'echo ADDINT' INT; _domconf_fm_root_provision example.com 0 >/dev/null 2>&1; trap -p INT )
assert_contains "$out" "ADDINT" "hata yolunda da INT tuzağı korundu"
NGINX_TEST_RC=0

echo "── J: legacy alan status (kök henüz yok) ──"
_fm_reset
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_contains "$out" "YOK" "kök yok: YOK"
assert_contains "$out" "Kökü kurmak için: srvctl domain fm-root example.com --apply" "…ve kurma yolu (dar komut fm-root) söylenir (QL4-M4)"
assert_not_contains "$out" "domain repair example.com" "…geniş 'repair' kök için ÖNERİLMEZ"
assert_not_contains "$out" "KAPALI" "…KAPALI denmez (dürüst)"
assert_eq "$rc" "1" "QL4-M4: YOK (köksüz) status rc 1 (sessiz başarı değil)"

echo "── K: QL4-M2 — kayıt VAR ama dosya yok/bozuk → sessiz rc 0 DEĞİL: yeniden üret ya da rc 1 ──"
# K1 (G2 E1 senaryosu): açık alanın kaydı duruyor, custom.d boşaltılmış (yarım remove + yeniden add / elle silme)
_fm_reset
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
rm -rf "$CUR_DIR"; mkdir -p "$CUR_DIR"
_prov example.com 0; assert_eq "$?" "0" "K1: provision rc 0 (yeniden üretti)"
# F9b (§15/33): 20 EKSİK = tanınan açık eser yok → otomatik yol açık yapılandırma ÜRETMEZ (F8: üç dosyayı kayıttan yeniden üretip AÇARDI)
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")" "yokyokvar" "K1: kayıtlı (on) dosyalar AÇIK yeniden üretilmedi; yalnız 403 kökü"
assert_contains "$(cat "$OUTF")" "UYUŞMUYOR" "K1: neden söylenir (kayıt-dosya uyuşmazlığı)"
assert_eq "$(sed -n 's/^state //p' "$MAN" | head -1)" "off" "K1: kayıt off'a eşitlendi"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "KAPALI" "K1: status KAPALI (AÇIK değil)"
# K2: kapalı kök kaydı + 20 silinmiş
_fm_reset; _prov example.com 0; rm -f "$F20"
_prov example.com 0; assert_eq "$?" "0" "K2: provision rc 0"
assert_eq "$(cat "$F20")" "$OFFTXT" "K2: 403 kökü yeniden üretildi"
# K3: kapalı kök kaydı + 20 kurcalanmış → yeniden üretilir, eski içerik adli kopya
_fm_reset; _prov example.com 0; printf 'location = /_fm { return 200 "x"; }\n' > "$F20"
_prov example.com 0; assert_eq "$?" "0" "K3: provision rc 0"
assert_eq "$(cat "$F20")" "$OFFTXT" "K3: kurcalanmış kök yeniden üretildi"
assert_eq "$(cat "${F20}.srvctl-tampered")" 'location = /_fm { return 200 "x"; }' "K3: eski içerik <ad>.srvctl-tampered"
# K4: kayıt var, dosya yok, nginx -t başarısız → rc 1 (sessiz 0 DEĞİL), geri alındı
_fm_reset; _prov example.com 0; rm -f "$F20"; NGINX_TEST_RC=1
_prov example.com 0; assert_eq "$?" "1" "K4: yeniden üretilemedi → rc 1"
assert_eq "$(_exists "$F20")" "yok" "K4: geri alındı (yarım yazım yok)"
assert_contains "$(cat "$MAN")" "state off" "K4: kayıt eski haline döndü"
NGINX_TEST_RC=0
# K5: açık kayıt, dosyalar yok, ModSecurity sondası düşer → rc 1, HİÇBİR şey yazılmaz
# F9b/F9c (§15/33, §15/38): AÇIK yeniden üretim yalnız ÜÇ eser de tanınan açıkken (STALE şablon) olur; 20/21/90'dan biri eksik/kurcalanmışsa yeniden üretim yok, KAPATMA (sonda gerekmez; K5c).
# K5'in eski tetikleyicisi (21 sil) artık KAPATIR; sonda-düşer yolu STALE şablonla (kayıtlı bölge kayması, üç eser tanınan) sınanır.
_fm_reset; ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; m0=$(_md5 "$MAN"); h20=$(_md5 "$F20")
NGINX_PROBE_RC=1
_prov example.com 0; assert_eq "$?" "1" "K5: sonda düştü → rc 1"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_md5 "$F20")$(_md5 "$MAN")" "varvar${h20}${m0}" "K5: hiçbir şey yazılmadı, kayıt aynı"
assert_contains "$(cat "$OUTF")" "ModSecurity yetenek tespiti" "K5: neden söylenir"
# K5b (F9b): üç dosya da yok (20 eksik) → AÇIK yeniden üretim yok → sonda GEREKMEZ: ModSecurity sondası düşse de 403 kökü yazılır (kapatma yönü)
_fm_reset; ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1; rm -f "$F90" "$F21" "$F20"
NGINX_PROBE_RC=1
_prov example.com 0; assert_eq "$?" "0" "K5b: 20 eksik: sonda gerekmez, 403 kökü yazıldı (rc 0)"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")" "yokyokvar" "K5b: yalnız 403 kökü"
# K5c (F9c §15/38): yalnız 21 eksik (20/90 tanınan) → AÇIK yeniden üretim yok → sonda GEREKMEZ: ModSecurity sondası düşse de 403 kökü yazılır
_fm_reset; ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1; rm -f "$F21"
NGINX_PROBE_RC=1
_prov example.com 0; assert_eq "$?" "0" "K5c: 21 eksik: sonda gerekmez, 403 kökü yazıldı (rc 0)"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")|$(sed -n 's/^state //p' "$MAN")" "yokyokvar|off" "K5c: yalnız 403 kökü, kayıt off (alan AÇILMADI)"
NGINX_PROBE_RC=0
# K6: sağlam kayıt+dosya → dokunmaz (idempotens korunur; nginx -t yok)
_fm_reset; _prov example.com 0; h=$(_md5 "$F20"); t1=$(grep -c . "$NGINX_T_LOG")
_prov example.com 0; assert_eq "$(_md5 "$F20")$(grep -c . "$NGINX_T_LOG")" "${h}${t1}" "K6: sağlam kök: yazım ve nginx -t YOK"

test_summary
