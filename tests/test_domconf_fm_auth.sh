#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitlerinin okuduğu bayraklar (MOCK_*, NGINX_*, SYSTEMCTL_RC …) bu dosyada atanır
# 'domain fm-auth' — on/off/status akışı, yazım sırası, geri alma, sinyal, flock,
# kullanıcı dosyası taraması (nginx -t'den ÖNCE), repair / php-switch / remove.
# Şablon İÇERİĞİ tests/test_domconf_fm_templates.sh'ta (yorum-dışı yapısal kilit);
# köken kaydı ayrıntıları tests/test_domconf_fm_provenance.sh'ta; gerçek nginx
# davranışı tests/test_domconf_nginx_real.sh'ta.
#
# umask 077: dosya modu testin sahte geçmesini engellesin — mktemp/yeni dosya
# 0600 doğar, 644 yalnız koddaki chmod ile olur (umask 022'de sahte geçerdi).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# F7-H2: 'fm-auth off' çalışan durumu da sınar → bu dosya curl taklidini sim kipinde açar (çalışan görüntü reload'u izler).
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
OUTF="${FM_STUBS}/out.txt"
_leftovers() { find "$CUR_DIR" -name '*.srvctl.*' 2>/dev/null | wc -l | tr -d ' '; }
_bkdirs() { find "${SRVCTL_STATE_DIR}/_fm-auth" -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }

echo "── A: bayrak kapalıyken HİÇBİR ŞEY render edilmez ──"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "YOK" "status: hiç açılmamış = YOK"
assert_eq "$(_reloads)" "0" "status reload etmez"
_domain_provision_conf_skeletons example.com >/dev/null 2>&1
assert_eq "$(find "$CUR_DIR" -name '*srvctl-fm*' | wc -l | tr -d ' ')" "0" "iskelet üretimi (domain add yolu) FM dosyası üretmez"
assert_eq "$(_exists "$MAN")" "yok" "köken kaydı yok"
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "yok" "status kayıt dizinini YARATMAZ"

echo "── B: parametre doğrulama (sname/region/script/host tablosu) ──"
( _domconf_fm_auth example.com on ) >/dev/null 2>&1; assert_eq "$?" "1" "--script yoksa reddedilir"
for bad in "/current/public/x.php" "/current/writable/x.php" "/current/../etc/x.php" "/current/a//b.php" \
           "/public_html/x.php" "/current/a.txt" "relative/x.php" "/current/a b.php" '/current/a;b.php' '/current/a$b.php' \
           "/current/modules/./Auth/x.php" "/current/modules/FileManager/./Auth/x.php" \
           "/current/modules/FileManager/Auth/../../x.php" "/current/modules/FileManager/Auth/x.php.txt" \
           "/current/modules/FileManager/Auth/x.phtml" "/current/modules/FileManager/Auth/x.php;id" \
           "/current/modules/FileManager/Auth/sub/x.php" "/current/modules/FileManager/Other/x.php" \
           "/current/modules/Auth/x.php" "/current/index.php" "/current/modules//Auth/x.php" \
           "x/current/modules/FileManager/Auth/x.php" "/current/modules/FileManager/Auth/x.php
"; do
    ( _domconf_fm_auth example.com on "--script=${bad}" ) >/dev/null 2>&1
    assert_eq "$?" "1" "geçersiz script reddedilir: ${bad//$'\n'/\\n}"
    assert_fail _domconf_fm_auth_script_ok "$bad"
done
assert_ok _domconf_fm_auth_script_ok "/current/modules/FileManager/Auth/fm-auth.php"
assert_ok _domconf_fm_auth_script_ok "/current/modules/File_Manager-2/Auth/fm_auth-1.php"
assert_eq "$(_exists "$F20")" "yok" "reddedilince dosya yazılmadı"
assert_eq "$(_exists "$MAN")" "yok" "reddedilince köken kaydı yazılmadı"
for badr in xx EU "eu;rm" "eapi.pcloud.com" "" " eu"; do
    ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "--region=${badr}" ) >/dev/null 2>&1
    assert_eq "$?" "1" "geçersiz --region reddedilir: '${badr}'"
done
assert_eq "$(_exists "$F20")" "yok" "geçersiz region: dosya yok"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" --bilinmeyen ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek reddedilir"
( _domconf_fm_auth example.com bogus ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen eylem reddedilir"
( _domconf_fm_auth nonexistent.test status ) >/dev/null 2>&1; assert_eq "$?" "1" "olmayan alan reddedilir"
( _domconf_fm_auth ) >/dev/null 2>&1; assert_eq "$?" "1" "argümansız çağrı reddedilir"
# (iii) domain adı / sname kapıları: düşman adlar on/off'a ULAŞAMAZ, hiçbir şey yazılmaz
for bad in '../etc' 'a b.com' 'x;y.com' '-a.com' 'a.com/../b' $'a.com\nb' 'a$(id).com'; do
    for act in on off; do
        ( _domconf_fm_auth "$bad" "$act" "--script=${SCRIPT}" ) >/dev/null 2>&1
        assert_eq "$?" "1" "düşman alan adı reddedilir (${act}): ${bad//$'\n'/\\n}"
    done
done
assert_eq "$(_exists "$F20")$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "yokyok" "düşman adlar: 20 dosyası ve kayıt dizini YOK"
# sname kapısı: domain_exists geçse bile safe_name boş/güvensiz ise ret (safe_name taklit edilir)
eval "_orig_$(declare -f safe_name)"
eval "_orig_$(declare -f domain_exists)"
domain_exists() { return 0; }
for badsn in '' 'a/../b' 'a b' 'a;b'; do
    safe_name() { printf '%s' "$badsn"; }
    for act in on off status; do
        ( _domconf_fm_auth example.com "$act" "--script=${SCRIPT}" ) >"$OUTF" 2>&1
        assert_eq "$?" "1" "güvensiz sname reddedilir (${act}): '${badsn}'"
    done
done
eval "$(declare -f _orig_safe_name | sed '1s/.*/safe_name ()/')"
eval "$(declare -f _orig_domain_exists | sed '1s/.*/domain_exists ()/')"
assert_eq "$(_exists "$F20")$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "yokyok" "güvensiz sname: hiçbir şey yazılmadı"
printf 'server {\n    listen 80;\n}\n' > "$VHOST"
out=$( _domconf_fm_auth example.com on "--script=${SCRIPT}" 2>&1 ); rc=$?
assert_eq "$rc" "1" "vhost custom.d include etmiyorsa durur"
assert_contains "$out" "repair" "kurtarma yolu önerilir"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
# public/ yoksa docroot release köküdür → uyarı
mkdir -p "${WEB_ROOT}/example.com/current"
out=$( _domconf_fm_auth example.com on "--script=${SCRIPT}" 2>&1 )
assert_contains "$out" "public/ yok" "release'te public/ yoksa betik erişilebilir uyarısı"
_fm_reset
mkdir -p "${WEB_ROOT}/example.com/current/public"
out=$( _domconf_fm_auth example.com on "--script=${SCRIPT}" 2>&1 )
assert_not_contains "$out" "public/ yok" "public/ varsa uyarı yok"
_fm_reset
rm -rf "${WEB_ROOT}/example.com/current"
# betik sembolik bağ / alan ağacı dışı
mkdir -p "${WEB_ROOT}/example.com/current/modules/FileManager/Auth" "${WEB_ROOT}/outside"
echo '<?php' > "${WEB_ROOT}/outside/evil.php"
ln -s "${WEB_ROOT}/outside/evil.php" "${WEB_ROOT}/example.com/current/modules/FileManager/Auth/fm-auth.php"
_on; assert_eq "$?" "1" "betik sembolik bağ ise reddedilir"
rm -f "${WEB_ROOT}/example.com/current/modules/FileManager/Auth/fm-auth.php"
rm -rf "${WEB_ROOT}/example.com/current/modules/FileManager/Auth"
ln -s "${WEB_ROOT}/outside" "${WEB_ROOT}/example.com/current/modules/FileManager/Auth"
echo '<?php' > "${WEB_ROOT}/outside/fm-auth.php"
_on; assert_eq "$?" "1" "betik dizini alan ağacı DIŞINA sembolik bağ ise reddedilir"
rm -rf "${WEB_ROOT}/example.com/current" "${WEB_ROOT}/outside"
assert_eq "$(_exists "$F20")" "yok" "betik reddinde dosya yok"
_fm_reset

echo "── C: on → üç dosya, mod, kayıt, SIRA ──"
# yazım sırası: atomik yazımı sarmala ve sırayı kaydet
eval "_orig_$(declare -f _domconf_atomic_write)"
WRITE_LOG="${FM_STUBS}/writes.log"; : > "$WRITE_LOG"
_domconf_atomic_write() {
    local b="${1##*/}"
    echo "$b 90=$(_exists "$F90") 21=$(_exists "$F21") 20=$(_exists "$F20")" >> "$WRITE_LOG"
    _orig__domconf_atomic_write "$@"
}
_on; rc=$?
assert_eq "$rc" "0" "on başarılı"
assert_eq "$(awk '{print $1}' "$WRITE_LOG" | tr '\n' ' ')" "90-srvctl-fm-auth.conf 21-srvctl-fm-download.conf 20-srvctl-fm-upload.conf " "yazım sırası 90 → 21 → 20 (yükleme yolu EN SON açılır)"
assert_contains "$(sed -n 3p "$WRITE_LOG")" "90=var 21=var" "20 yazılırken 90 ve 21 ZATEN var"
assert_contains "$(sed -n 1p "$WRITE_LOG")" "20=yok" "90 yazılırken 20 henüz yok"
for f in "$F90" "$F21" "$F20"; do
    assert_eq "$(_exists "$f")" "var" "dosya var: ${f##*/}"
    assert_eq "$(_mode "$f")" "644" "mod 644: ${f##*/}"
done
assert_eq "$(_mode "$MAN")" "600" "köken kaydı 600"
assert_eq "$(_mode "${SRVCTL_STATE_DIR}/_fm-auth")" "700" "köken dizini 700"
assert_eq "$(_leftovers)" "0" "geçici (*.srvctl.*) dosya artığı yok"
assert_eq "$(_bkdirs)" "0" "yedek dizini artığı yok"
assert_eq "$(_exists "${CUR_DIR}/srvctl-fm-upload-modsec.inc")" "yok" ".inc/kapı dosyası ÜRETİLMEZ (include düzeneği kalktı)"
assert_eq "$(_reloads)" "1" "tek reload"
assert_contains "$(cat "$FLOCK_LOG")" "-w 30 8" "flock alındı (serileştirme)"
m="$(cat "$MAN")"
assert_contains "$m" "srvctl-fm-auth-manifest v1" "kayıt başlığı"
assert_contains "$m" "state on" "kayıt: state on"
assert_contains "$m" "region eu" "kayıt: region eu (varsayılan)"
assert_contains "$m" "script ${SCRIPT}" "kayıt: script"
assert_contains "$m" "php_version ${DEFAULT_PHP_VERSION}" "kayıt: php_version"
assert_contains "$m" "tpl_ver ${_DOMCONF_FM_TPL_VER}" "kayıt: tpl_ver (güncel şablon sürümü)"
assert_eq "$(grep -c '^sha256 ' "$MAN")" "3" "kayıt: tam 3 özet satırı (aşama 2: yalnız yeni)"
h90=$(_domconf_sha256_file "$F90"); assert_contains "$m" "sha256 ${h90} 90-srvctl-fm-auth.conf" "kayıt özeti dosyayla eşit (90)"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "AÇIK" "status: AÇIK"
assert_contains "$out" "bölge: eu" "status bölgeyi gösterir"
# idempotent: ikinci on aynı içerik
c1="$(cat "$F20")$(cat "$F90")$(cat "$F21")"
_on; assert_eq "$?" "0" "on ikinci kez başarılı (idempotent)"
assert_eq "$(cat "$F20")$(cat "$F90")$(cat "$F21")" "$c1" "ikinci on içeriği değiştirmez"
assert_eq "$(grep -c '^sha256 ' "$MAN")" "3" "ikinci on sonrası yine tam 3 özet"
# --dry
_fm_reset
: > "$WRITE_LOG"
_on --dry; assert_eq "$?" "0" "--dry başarılı"
assert_contains "$(cat "$OUTF")" "DRY-OK" "--dry DRY-OK basar"
assert_eq "$(_exists "$F20")$(_exists "$MAN")$(_exists "${SRVCTL_STATE_DIR}/_fm-auth/.lock")" "yokyokyok" "--dry dosya/kayıt/KİLİT YAZMAZ"
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "yok" "--dry köken KAYIT DİZİNİNİ OLUŞTURMAZ (salt-okur)"
assert_eq "$(wc -l < "$WRITE_LOG" | tr -d ' ')" "0" "--dry atomik yazım yapmaz"
_tree_sig() { { find "$SRVCTL_STATE_DIR" "$CUR_DIR" 2>/dev/null | LC_ALL=C sort; find "$SRVCTL_STATE_DIR" "$CUR_DIR" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort; } | cksum; }
_fm_reset; sig0=$(_tree_sig); _on --dry; assert_eq "$?" "0" "--dry (taze alan) başarılı"
_dry_t1=$(grep -c . "$NGINX_T_LOG")
assert_eq "$(_tree_sig)" "$sig0" "--dry: state+custom.d ağacı BİT-BİT aynı (dosya/dizin/içerik)"
# kayıt dizini ZATEN varsa (önceki on): --dry onu değiştirmez, kilit dosyası da oluşmaz/değişmez
_fm_reset; _on; rm -f "${SRVCTL_STATE_DIR}/_fm-auth/.lock"; sig1=$(_tree_sig); : > "$NGINX_T_LOG"
_on --dry; assert_eq "$?" "0" "--dry (açık alan) başarılı"
assert_eq "$(_tree_sig)" "$sig1" "--dry (kayıt dizini var): ağaç aynı, .lock yeniden YARATILMAZ"
( _domconf_fm_auth example.com off --dry ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off --dry (açık alan) başarılı"
assert_contains "$(cat "$OUTF")" "DRY-OK" "off --dry DRY-OK basar"
assert_eq "$(_tree_sig)" "$sig1" "off --dry: ağaç BİT-BİT aynı (90/21 silinmez, kök yazılmaz)"
# (A devri) NGINX_T_CALLS taklitte artar ama _on/( … ) ALT KABUKTA koşar → ebeveynde hep 0 (boş kilit);
# sayım alt kabuktan sağ çıkan NGINX_T_LOG'dan yapılır (t = canlı -t, p = sonda -t -c, T = -T)
assert_eq "${_dry_t1}/$(grep -c . "$NGINX_T_LOG")" "0/0" "--dry (taze + açık alan) ve off --dry: nginx -t / sonda / -T HİÇ çağrılmaz (NGINX_T_LOG)"

echo "── D: --region=us ──"
_fm_reset
_on --region=us; assert_eq "$?" "0" "on --region=us"
fm_collect "$F20"
assert_ok fm_has 'location @fm_up' 'proxy_pass https://api.pcloud.com/upload_write?uploadid=$fm_up_uid&uploadoffset=$fm_up_off'
assert_contains "$(cat "$MAN")" "region us" "kayıt: region us"
_on; assert_eq "$?" "0" "region verilmeden tekrar on"
assert_contains "$(cat "$MAN")" "region us" "region verilmezse KAYITLI bölge korunur"
_on --region=eu; assert_contains "$(cat "$MAN")" "region eu" "açık --region=eu bölgeyi değiştirir"

echo "── E: nginx -t hatası → dosyalar+kayıt GERİ ──"
_fm_reset
NGINX_TEST_RC=1
_on; assert_eq "$?" "1" "nginx -t hatasında on başarısız"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")$(_exists "$MAN")" "yokyokyokyok" "temiz durumdan geri alındı: hiçbir dosya/kayıt yok"
assert_eq "$(_reloads)" "0" "hatada reload YOK"
assert_eq "$(_bkdirs)" "0" "yedek dizini temizlendi"
assert_eq "$(_leftovers)" "0" "geçici artık yok"
NGINX_TEST_RC=0
echo "── E2: geri alma BAŞARISIZSA dürüst mesaj (QL3-L9): 'geri alındı' DENMEZ, yedek diskte KALIR ──"
_fm_reset; NGINX_TEST_RC=1
( _domconf_fm_restore_from_bk() { return 1; }; _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "nginx -t hatası + geri alma hatası: on başarısız"
assert_contains "$(cat "$OUTF")" "GERİ ALMA BAŞARISIZ" "mesaj: geri alma başarısız"
assert_not_contains "$(cat "$OUTF")" "geri alındı, reload YAPILMADI" "…'geri alındı' yalanı YOK"
assert_eq "$(_bkdirs)" "1" "yedek dizini diskte KALDI (elle kurtarma)"
find "$SRVCTL_STATE_DIR" "$CUR_DIR" -name '.bk.*' -exec rm -rf {} + 2>/dev/null
_fm_reset; NGINX_TEST_RC=1
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1
assert_contains "$(cat "$OUTF")" "geri alındı" "kontrol: geri alma BAŞARILIYSA eski mesaj"
assert_eq "$(_bkdirs)" "0" "…yedek temizlendi"
NGINX_TEST_RC=0; _fm_reset
_on --region=us; assert_eq "$?" "0" "önce us ile açık"
snap="$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")"
NGINX_TEST_RC=1
_on --region=eu; assert_eq "$?" "1" "açıkken değiştirme denemesi nginx -t'de başarısız"
assert_eq "$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")" "$snap" "ÖNCEKİ dosyalar+kayıt bayt bayt geri yüklendi"
assert_eq "$(_domconf_sha256_file "$F20")" "$(sed -n 's/^sha256 \([0-9a-f]*\) 20-srvctl-fm-upload.conf$/\1/p' "$MAN")" "geri yüklenen 20 hâlâ kayıtla eşleşir"
NGINX_TEST_RC=0
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "AÇIK" "geri alma sonrası status AÇIK"
# İKİ-AŞAMALI GEÇİŞ: nginx -t sırasında kayıt ESKİ+YENİ özetleri birlikte taşır (çökme penceresi)
_snap_man() { cp "$MAN" "${FM_STUBS}/man.during"; }
_fm_reset; _on --region=us
old20=$(sed -n 's/^sha256 \([0-9a-f]*\) 20-srvctl-fm-upload.conf$/\1/p' "$MAN")
NGINX_T_HOOK=_snap_man; _on --region=eu; NGINX_T_HOOK=""
new20=$(sed -n 's/^sha256 \([0-9a-f]*\) 20-srvctl-fm-upload.conf$/\1/p' "$MAN")
assert_ne "$old20" "$new20" "sondaj: region değişimi 20'nin özetini değiştirdi"
assert_contains "$(cat "${FM_STUBS}/man.during")" "sha256 ${old20} 20-srvctl-fm-upload.conf" "nginx -t sırasındaki kayıt ESKİ özeti taşır"
assert_contains "$(cat "${FM_STUBS}/man.during")" "sha256 ${new20} 20-srvctl-fm-upload.conf" "nginx -t sırasındaki kayıt YENİ özeti taşır"
assert_not_contains "$(cat "$MAN")" "$old20" "nihai kayıtta eski özet YOK"
_fm_reset; _on --region=us
snap="$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")"
# off sırasında nginx -t hatası: 90/21 geri gelir
NGINX_TEST_RC=1
# F6-M1: 'fm-auth off' artık başarısız olunca ACİL yola düşer (tests/test_domconf_fm_emergency.sh); bu bölüm NORMAL
# yolun (_domconf_fm_auth_off) kendi sözleşmesini kilitler: nginx -t hatasında geri alır.
( _domconf_fm_auth_off example.com example_com "$CUR_DIR" 0 0 ) >/dev/null 2>&1; assert_eq "$?" "1" "off (normal yol): nginx -t hatasında başarısız"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "varvar" "off hatasında 90 ve 21 GERİ geldi"
assert_eq "$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")" "$snap" "off hatasında HER ŞEY eski haline döndü"
NGINX_TEST_RC=0
# yazım hatası ortada: 21 yazılırken hata → 90 geri alınır
_fm_reset
_domconf_atomic_write() { if [[ "${1##*/}" == "21-srvctl-fm-download.conf" ]]; then return 1; fi; _orig__domconf_atomic_write "$@"; }
_on; assert_eq "$?" "1" "ortada yazım hatası: on başarısız"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")$(_exists "$MAN")" "yokyokyokyok" "yarım yazım: 90 GERİ alındı, hiçbir şey kalmadı"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "0" "yazım hatasında canlı nginx -t çağrılmadı (NGINX_T_LOG)"
_domconf_atomic_write() { local b="${1##*/}"; echo "$b 90=$(_exists "$F90") 21=$(_exists "$F21") 20=$(_exists "$F20")" >> "$WRITE_LOG"; _orig__domconf_atomic_write "$@"; }

echo "── F: ModSecurity modülü yoksa ('unknown directive') satırsız varyant ──"
_fm_reset
NGINX_FAIL_ON_MODSEC=1
# QL4-M3: her nginx -t anında CANLI dizinde 'modsecurity off;' (modül yokken geçersiz) var mı?
M3W="${FM_STUBS}/m3watch.log"; : > "$M3W"
_m3_watch() { if grep -qsE '^[[:space:]]*modsecurity off;' "${CUR_DIR}"/*.conf; then echo "GECERSIZ-DISKTE ${NGINX_T_ARGS}" >> "$M3W"; else echo "temiz ${NGINX_T_ARGS}" >> "$M3W"; fi; }
NGINX_T_HOOK=_m3_watch
out=$( ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) 2>&1 ); rc=$?
NGINX_T_HOOK=""
assert_eq "$(grep -c '^GECERSIZ-DISKTE' "$M3W")" "0" "M3: hiçbir nginx -t anında canlı dizinde geçersiz 'modsecurity off;' varyantı YOK (tespit diske yazmadan)"
assert_eq "$(grep -c '^temiz -t -c ' "$M3W")" "1" "M3: tespit BAĞIMSIZ sonda ile (nginx -t -c <aday>) — bir kez"
assert_eq "$(find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.probe.*' | wc -l | tr -d ' ')" "0" "M3: sonda dizini temizlendi"
assert_eq "$rc" "0" "modül yokken on yine de başarılı (satırsız varyant)"
assert_contains "$out" "ModSecurity modülü yüklü değil" "uyarı verilir"
fm_collect "$F20"; assert_fail fm_has 'location ^~ /_fm/up/' 'modsecurity off'
assert_fail fm_has 'location @fm_up' 'modsecurity off'
fm_collect "$F90"; assert_fail fm_has 'location = /__fm_auth' 'modsecurity off'
assert_contains "$(cat "$MAN")" "modsec 0" "kayıt: modsec 0"
assert_contains "$(cat "$F20")" "# ModSecurity yüklü değil" "yorum satırı yazıldı"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "1" "canlı yapılandırmada TEK nginx -t (deneme-yanılma YOK; QL4-M3)"
assert_eq "$(grep -c '^p$' "$NGINX_T_LOG")" "1" "…ve tek sonda (nginx -t -c)"
NGINX_FAIL_ON_MODSEC=0
# modül yüklü: modsecurity off her üç dosyada (20'de iki yerde)
_fm_reset
_on; fm_collect "$F20"
assert_ok fm_has 'location ^~ /_fm/up/' 'modsecurity off'
assert_ok fm_has 'location @fm_up' 'modsecurity off'
assert_contains "$(cat "$MAN")" "modsec 1" "kayıt: modsec 1"
# başka DOSYADAKİ / başka ALANIN dizinindeki 'unknown directive "modsecurity"': satırsız varyanta DÜŞÜLMEZ
for msg in 'nginx: [emerg] unknown directive "modsecurity" in /etc/nginx/conf.d/baska.conf:3' \
           "nginx: [emerg] unknown directive \"modsecurity\" in ${SRVCTL_NGINX_CUSTOM_DIR}/baska_com/90-x.conf:2" \
           "nginx: [emerg] unknown directive \"modsecurity\" in ${SRVCTL_NGINX_CUSTOM_DIR}/example_comX/90-x.conf:2"; do
    _fm_reset; NGINX_T_MSG="$msg"
    _on; assert_eq "$?" "1" "başka dosyadaki modsecurity hatası → dur: ${msg##*in }"
    assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "1" "…tek nginx -t (satırsız yeniden deneme YOK)"
    assert_eq "$(_exists "$F20")" "yok" "…dosyalar geri alındı"
done
NGINX_T_MSG=""
# bizim dizinimizdeki dosya: satırsız varyanta düşer
_fm_reset; NGINX_T_MSG=""; NGINX_FAIL_ON_MODSEC=1; _on; assert_eq "$?" "0" "kontrol: kendi dizinimizdeki hata satırsız varyantla geçer"; NGINX_FAIL_ON_MODSEC=0
# modsecurity ile İLGİSİZ nginx -t hatası: satırsız varyanta DÜŞÜLMEZ
_fm_reset
NGINX_TEST_RC=1
_on; assert_eq "$?" "1" "ilgisiz nginx -t hatasında dur"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "1" "ilgisiz hatada tek nginx -t (yeniden deneme yok)"
NGINX_TEST_RC=0

echo "── G: reload hatası ──"
_fm_reset
SYSTEMCTL_RC=1
_on; assert_eq "$?" "1" "reload hatasında komut başarısız"
# F9e (§15/44(b)) TERSİNE DÖNEN BEKLENTİ: eskiden reload hatasında dosyalar yerinde + kayıt 'state on' kalırdı (disk AÇIK + kayıt on).
# Şimdi açılış GERİ ALINIR: 403 kökü, kayıt 'state off', 90/21 yok (ayrıntı: test_domconf_fm_f9e_on_atomic.sh).
assert_contains "$(cat "$OUTF")" "reload" "reload hatası söylenir"
assert_contains "$(cat "$OUTF")" "GERİ ALINDI" "reload hatasında açılış geri alınır"
assert_eq "$(_exists "$F90")" "yok" "geri alma: 90 yok (disk açık kalmaz)"
assert_contains "$(cat "$MAN")" "state off" "geri alma: kayıt off (kayıt-disk tutarlı)"
SYSTEMCTL_RC=0

echo "── H: kullanıcı dosyaları HER nginx -t'den ÖNCE taranır; ihlalde on REDDEDİLİR ──"
_fm_reset
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"
_on; assert_eq "$?" "1" "ihlalli 00-custom.conf varken on REDDEDİLİR"
assert_contains "$(cat "$OUTF")" "proxy_pass" "bulgu direktifi gösterilir"
assert_eq "$(grep -c . "$NGINX_T_LOG")" "0" "tarama nginx -t'den ÖNCE: reddedilince hiç nginx -t / sonda çağrılmadı (NGINX_T_LOG)"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")$(_exists "$MAN")" "yokyokyokyok" "ihlalde hiçbir şey yazılmadı"
assert_eq "$(cat "${CUR_DIR}/00-custom.conf" | wc -l | tr -d ' ')" "3" "kullanıcı dosyasına DOKUNULMADI"
# rezerve ad (benign içerik bile)
rm -f "${CUR_DIR}/00-custom.conf"
printf 'client_max_body_size 10m;\n' > "${CUR_DIR}/99-fm-extra.conf"
_on; assert_eq "$?" "1" "rezerve ad (*fm*) kullanıcı dosyası → on reddedilir"
assert_contains "$(cat "$OUTF")" "rezerve" "gerekçe: rezerve ad"
rm -f "${CUR_DIR}/99-fm-extra.conf"
printf 'client_max_body_size 10m;\n' > "${CUR_DIR}/srvctl-extra.conf"
_on; assert_eq "$?" "1" "rezerve ad (srvctl-*) → on reddedilir"
rm -f "${CUR_DIR}/srvctl-extra.conf"
# kayıtsız FM adı
printf 'client_max_body_size 10m;\n' > "$F20"
_on; assert_eq "$?" "1" "köken kaydı OLMADAN 20-srvctl-fm-upload.conf diskte → on reddedilir"
assert_contains "$(cat "$OUTF")" "köken kaydı OLMADAN" "kayıtsız ad gerekçesi"
assert_eq "$(cat "$F20")" "client_max_body_size 10m;" "kayıtsız dosya silinmedi/ezilmedi"
rm -f "$F20"
# temiz kullanıcı dosyası (iskelet) + izin listesine uyan: on geçer
_domconf_nginx_skeleton example.com > "${CUR_DIR}/00-custom.conf"
printf 'client_max_body_size 100M;\n' >> "${CUR_DIR}/00-custom.conf"
_on; assert_eq "$?" "0" "temiz kullanıcı dosyası varken on başarılı"
# doğrulanamayan (rc 2) → ret: izin listesi stub'ı
_fm_reset
printf 'client_max_body_size 10m;\n' > "${CUR_DIR}/00-custom.conf"
_domconf_load_allow_lib
eval "_real_$(declare -f _ngxallow_scan)"
_ngxallow_scan() { echo "0:-:stub: doğrulanamadı"; return 2; }
_on; assert_eq "$?" "1" "izin listesi doğrulayamazsa (rc 2) on REDDEDİLİR (fail-closed)"
assert_eq "$(grep -c . "$NGINX_T_LOG")" "0" "doğrulanamayınca nginx -t / sonda çağrılmadı (NGINX_T_LOG)"
_ngxallow_scan() { echo "0:-:stub: beklenmeyen"; return 7; }
assert_eq "$(_domconf_user_scan "${CUR_DIR}/00-custom.conf" example.com >/dev/null; echo $?)" "2" "beklenmeyen çıkış kodu (7) → 2 (fail-closed)"
eval "$(declare -f _real__ngxallow_scan | sed '1s/.*/_ngxallow_scan ()/')"
# kitaplık yoksa
( unset -f _ngxallow_scan; SRVCTL_ROOT="$(mktemp -d "${FM_STUBS}/noroot.XXXXXX")"; _domconf_user_scan "${CUR_DIR}/00-custom.conf" example.com >/dev/null; exit $? ); assert_eq "$?" "2" "kitaplık yüklenemezse → 2 (fail-closed)"
_fm_reset

echo "── I: flock ──"
FLOCK_RC=1; export FLOCK_RC
_on; assert_eq "$?" "1" "kilit alınamazsa on başarısız"
assert_eq "$(_exists "$F20")$(_exists "$MAN")" "yokyok" "kilit yokken hiçbir şey yazılmadı"
assert_contains "$(cat "$OUTF")" "kilidi" "kilit hatası söylenir"
FLOCK_RC=0
# flock ikilisi yoksa FAIL-CLOSED
NOFL="$(mktemp -d)"
for c in mktemp sed tr cat cp mv rm chmod stat awk mkdir dirname basename cmp cut wc grep ls find head tail sort shasum sha256sum date readlink printf env bash sh id uname; do
    p=$(PATH="${PATH//${FM_STUBS}:/}" command -v "$c" 2>/dev/null) && [[ -n "$p" && "$p" == /* ]] && ln -sf "$p" "${NOFL}/${c}"
done
( PATH="$NOFL"; _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; assert_eq "$?" "1" "flock YOKSA on başarısız (fail-closed)"
assert_contains "$(cat "$OUTF")" "flock bulunamadı" "flock yok uyarısı (genel 'komut yok' hatası DEĞİL, srvctl'in kendi denetimi)"
assert_eq "$(_exists "$F20")$(_exists "$MAN")" "yokyok" "flock yokken hiçbir şey yazılmadı"
_fm_reset
( PATH="$NOFL"; _domconf_fm_auth example.com on "--script=${SCRIPT}" --dry ) >"$OUTF" 2>&1; assert_eq "$?" "1" "flock YOKSA --dry de başarısız (gerçek on'u DÜRÜSTÇE öngörür)"
assert_not_contains "$(cat "$OUTF")" "DRY-OK" "…ve DRY-OK basmaz"
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "yok" "…ve kayıt dizinini yaratmaz"
rm -rf "${NOFL:?}"

echo "── J: SİNYAL (TERM) ortada → geri al, yedek dizini temizle ──"
_fm_reset
_on; snapJ="$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")"
KILL_TARGET=""
# Yalnız CANLI nginx -t anında (dosyalar yazılmış, kayıt aşama 1) — sonda (-t -c) anında değil.
_kill_hook() { [[ "$NGINX_T_ARGS" == "-t" ]] || return 0; kill -TERM "$KILL_TARGET"; sleep 0.3; }
PIDF="${FM_STUBS}/pid.txt"
( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_kill_hook; _domconf_fm_auth example.com on "--script=${SCRIPT}" --region=us ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "143" "TERM → 143 (128+SIGTERM) ile çıkıldı"
assert_eq "$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")" "$snapJ" "sinyalde dosyalar+kayıt ÖNCEKİ haline döndü"
assert_eq "$(_bkdirs)" "0" "sinyalde yedek dizini temizlendi"
# QL4-M3: sonda anında TERM → canlı dizine hiçbir şey yazılmamış, sonda dizini temizlenmiş
_kill_probe() { [[ "$NGINX_T_ARGS" == "-t -c "* ]] || return 0; kill -TERM "$KILL_TARGET"; sleep 0.3; }
( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_kill_probe; _domconf_fm_auth example.com on "--script=${SCRIPT}" --region=us ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "143" "sonda anında TERM → 143"
assert_eq "$(cat "$F20")|$(cat "$F90")|$(cat "$F21")|$(cat "$MAN")" "$snapJ" "sonda anında TERM: canlı dosyalar+kayıt DEĞİŞMEDİ"
assert_eq "$(find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.probe.*' | wc -l | tr -d ' ')$(_bkdirs)" "00" "…sonda dizini ve yedek kalmadı"
NGINX_T_HOOK=""
# rev-L1: sinyalde GERİ ALMA BAŞARISIZSA yedek SİLİNMEZ (elle kurtarma)
( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_kill_hook
  _domconf_fm_restore_from_bk() { return 1; }
  _domconf_fm_auth example.com on "--script=${SCRIPT}" --region=us ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "143" "rev-L1: geri alma başarısız + TERM → 143"
assert_eq "$(_bkdirs)" "1" "rev-L1: geri alma başarısızsa yedek diskte KALDI"
assert_contains "$(cat "$OUTF")" "yedek diskte korunuyor" "rev-L1: dürüst ileti"
find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.bk.*' -exec rm -rf {} + 2>/dev/null
NGINX_T_HOOK=""

echo "── K: off → 403 kökü, 90/21 silinir, SIRA ──"
_fm_reset
_on
: > "$WRITE_LOG"
( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off başarılı"
assert_eq "$(awk '{print $1}' "$WRITE_LOG")" "20-srvctl-fm-upload.conf" "off: tek yazım = 20 (403 kökü)"
assert_contains "$(cat "$WRITE_LOG")" "90=var 21=var" "off: 20 403-köküyle değişirken 90/21 HÂLÂ var (yol hiç açık kalmaz)"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")" "yokyokvar" "off: 90/21 silindi, 20 (403 kökü) kaldı"
fm_collect "$F20"
assert_ok fm_has "" 'location ^~ /_fm/'
assert_ok fm_has 'location ^~ /_fm/' "return 403 srvctl-fm-closed $(_domconf_fm_body_sig example_com)"
assert_eq "$(grep -cE '^[0-9]+\|' <<< "$_FM_COLL")" "7" "403 kökü: tam yedi ifade/blok (üç location + iki imzalı return + yakalayıcının internal + return 403; şablon sürümü 4: /__fm_ ad alanı yakalayıcısı)"
assert_ok fm_has "" 'location ^~ /__fm_'
assert_ok fm_has 'location ^~ /__fm_' 'internal'
assert_ok fm_has 'location ^~ /__fm_' 'return 403'
assert_ok fm_has "" 'location = /_fm'
assert_ok fm_has 'location = /_fm' "return 403 srvctl-fm-closed $(_domconf_fm_body_sig example_com)"
assert_eq "$(cat "$F20")" "$(_domconf_fm_render_off example_com)" "off: 20 dosyasının içeriği BAYT-BAYT 403 kökü şablonu (başka hiçbir direktif yok)"
assert_eq "$(grep -c 'proxy_pass\|auth_request\|fastcgi\|include' "$F20")" "0" "off: 20'de proxy_pass/auth_request/fastcgi/include YOK"
assert_eq "$(grep -c '^state off$' "$MAN")" "1" "kayıt: tek 'state off' satırı"
assert_contains "$(cat "$MAN")" "state off" "kayıt: state off"
assert_eq "$(grep -c '^sha256 ' "$MAN")" "1" "off: tek özet (yalnız 20)"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "KAPALI (403 kökü)" "status: KAPALI (403 kökü)"
assert_not_contains "$out" "AÇIK" "status KAPALI iken 'AÇIK' basılmaz (QL3-L9: önce AÇIK sonra KAPALI yazılıyordu)"
assert_eq "$(_reloads)" "2" "on + off = iki reload"
# tekrar on
_on; assert_eq "$?" "0" "off sonrası on yeniden açar"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")" "varvarvar" "tekrar on: üç dosya"
# eski .inc artığı off/on ile temizlenir
printf 'set $fm_gate 1;\n' > "${CUR_DIR}/srvctl-fm-upload-modsec.inc"
( _domconf_fm_auth example.com off ) >/dev/null 2>&1
assert_eq "$(_exists "${CUR_DIR}/srvctl-fm-upload-modsec.inc")" "yok" "eski srvctl-fm-upload-modsec.inc artığı off ile silinir"
# hiç açılmamış alanda off: 403 kökü yazar
_fm_reset
( _domconf_fm_auth example.com off ) >/dev/null 2>&1; assert_eq "$?" "0" "hiç açılmamış alanda off başarılı"
assert_eq "$(_exists "$F20")$(_exists "$F90")" "varyok" "hiç açılmamışta off 403 kökünü yazar"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "KAPALI (403 kökü)" "…ve status KAPALI"
# off referans koruması
_fm_reset
_on
printf 'location /y {\n    rewrite ^ /__fm_auth last;\n}\n' > "${CUR_DIR}/10-ref.conf"
( _domconf_fm_auth_off example.com example_com "$CUR_DIR" 0 0 ) >"$OUTF" 2>&1; assert_eq "$?" "1" "off (normal yol): FM adına başvuran kullanıcı dosyası varken --force ister"
assert_contains "$(cat "$OUTF")" "10-ref.conf" "başvuran dosya adı gösterilir"
assert_eq "$(_exists "$F90")" "var" "reddedilen off hiçbir şeyi silmedi"
( _domconf_fm_auth example.com off --dry ) >"$OUTF" 2>&1
( _domconf_fm_auth example.com off --force ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off --force geçer"
assert_eq "$(_exists "${CUR_DIR}/10-ref.conf")" "var" "--force kullanıcı dosyasını SİLMEZ"
assert_eq "$(_exists "$F90")" "yok" "--force sonrası 90 silindi"
printf 'location /z {\n    return 204; # sadece yorum: /__fm_auth\n}\n' > "${CUR_DIR}/10-ref.conf"
( _domconf_fm_auth example.com off ) >/dev/null 2>&1; assert_eq "$?" "0" "yorumdaki '/__fm_auth' referans SAYILMAZ"
_fm_reset

echo "── L: repair / php-switch / remove ──"
_fm_reset
_on
# php-switch: soket yeni sürüme, kayıt güncel, sed YOK
_domconf_fm_auth_sock_sync example.com 8.4; assert_eq "$?" "10" "sock_sync: güncellendi → 10"
assert_contains "$(cat "$F90")" "fastcgi_pass unix:/run/php/php8.4-fpm-example_com.sock;" "90 yeni sürümün soketini taşır"
assert_contains "$(cat "$MAN")" "php_version 8.4" "kayıt php_version 8.4"
assert_eq "$(_domconf_sha256_file "$F90")" "$(sed -n 's/^sha256 \([0-9a-f]*\) 90-srvctl-fm-auth.conf$/\1/p' "$MAN")" "kayıtlı özet yeni 90 ile eşit (üretilmiş tanınır)"
assert_ok _fmprov_is_generated example_com "$F90"
_domconf_fm_auth_sock_sync example.com 8.4; assert_eq "$?" "0" "aynı sürüm → 0 (değişiklik yok)"
_domconf_fm_auth_sock_sync example.com 8; assert_eq "$?" "1" "geçersiz sürüm → 1"
_domconf_fm_auth_sock_sync example.com '8.4;x'; assert_eq "$?" "1" "enjeksiyonlu sürüm → 1"
assert_eq "$(_reloads)" "1" "sock_sync reload ETMEZ (php-switch kendisi reload eder)"
NGINX_TEST_RC=1
snapL="$(cat "$F90")|$(cat "$MAN")"
_domconf_fm_auth_sock_sync example.com 8.1; assert_eq "$?" "1" "nginx -t hatasında sock_sync → 1"
assert_eq "$(cat "$F90")|$(cat "$MAN")" "$snapL" "…ve eski haline döndü"
NGINX_TEST_RC=0
_fm_reset
_domconf_fm_auth_sock_sync example.com 8.4; assert_eq "$?" "0" "fm-auth açılmamış alanda sock_sync no-op"
assert_eq "$(_exists "$F90")$(_exists "$MAN")" "yokyok" "…ve dosya YARATMAZ"
( _domconf_fm_auth example.com off ) >/dev/null 2>&1
_domconf_fm_auth_sock_sync example.com 8.4; assert_eq "$?" "0" "KAPALI durumda sock_sync no-op"
assert_eq "$(_exists "$F90")" "yok" "KAPALI durumda 90 yaratılmaz"
# repair: sağlam → dokunmaz
_fm_reset; _on
before="$(cat "$F20")$(cat "$MAN")"; : > "$RELOAD_LOG"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}"; assert_eq "$?" "0" "sağlam: repair 0"
assert_eq "$(cat "$F20")$(cat "$MAN")" "$before" "sağlam: dosya/kayıt değişmez"
assert_eq "$(_reloads)" "0" "sağlam: reload yok"
# EKSİK
rm -f "$F21"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "EKSİK" "status: EKSİK"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$?" "0" "EKSİK → repair alanı KAPATIR (F9c §15/38; eskiden: onarır)"
assert_eq "$(_exists "$F21")|$(_exists "$F90")|$(sed -n 's/^state //p' "$MAN")" "yok|yok|off" "F9c TERSİNE: 21 EKSİK (20/90 tanınan) → 21 yeniden üretilmez; alan KAPANDI (90/21 yok, kayıt off)"
# TAMPERED (taze AÇIK durum: yukarıdaki repair alanı kapattı)
_fm_reset; _on
printf '# kurcalandi\n' >> "$F90"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "TAMPERED" "status: TAMPERED"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$?" "0" "TAMPERED → repair yeniden üretir"
assert_not_contains "$(cat "$F90")" "kurcalandi" "kurcalanmış içerik yok edildi"
assert_contains "$(cat "${F90}.srvctl-tampered")" "kurcalandi" "kurcalanmış içerik adli inceleme için .srvctl-tampered olarak saklandı (nginx yüklemez)"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "KAPALI" "F9c TERSİNE: kurcalanmış 90 onarımı sonrası alan KAPALI (eskiden: AÇIK)"
assert_eq "$(_exists "$F90")|$(_exists "$F21")" "yok|yok" "F9c TERSİNE: kurcalanmış 90 → yeniden üretilmez; 90/21 yok"
# STALE: şablon sürüm kayması (hash kayıtla eşit, taze render farklı) — taze AÇIK durum
_fm_reset; _on
cp -R "${REPO_ROOT}/templates" "${FM_STUBS}/tpl2"
printf '# yeni yorum\n' >> "${FM_STUBS}/tpl2/nginx/fm-download.conf.tpl"
out=$( SRVCTL_TEMPLATES="${FM_STUBS}/tpl2" _domconf_fm_auth example.com status 2>&1 )
assert_contains "$out" "STALE" "status: STALE (şablon kayması)"
assert_not_contains "$out" "TAMPERED" "STALE ≠ TAMPERED"
( SRVCTL_TEMPLATES="${FM_STUBS}/tpl2"; _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" ) >/dev/null 2>&1
assert_contains "$(cat "$F21")" "yeni yorum" "STALE → repair yeni şablonla yeniler"
rm -rf "${FM_STUBS}/tpl2"
# repair php sürümü kayması
_domconf_fm_auth_repair example.com 8.4 >/dev/null 2>&1; assert_eq "$?" "0" "php kayması → repair"
assert_contains "$(cat "$F90")" "php8.4-fpm-example_com.sock" "repair 90'ı alanın GERÇEK havuzuna çeker"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1
# repair nginx -t başarısız → 1 ve geri
rm -f "$F21"; NGINX_TEST_RC=1
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$?" "1" "nginx -t başarısız → repair 1"
assert_eq "$(_exists "$F21")" "yok" "başarısız onarım geri alındı"
NGINX_TEST_RC=0
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1
# KAPALI durumda repair 403 kökünü korur
( _domconf_fm_auth example.com off ) >/dev/null 2>&1
rm -f "$F20"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1; assert_eq "$?" "0" "KAPALI + 403 kökü eksik → repair yeniden yazar"
assert_eq "$(_exists "$F20")$(_exists "$F90")" "varyok" "repair KAPALI durumda yalnız 403 kökünü yazar"
# opt-in yok: repair YALNIZ 403 kökünü kurar (90/21 yok; kayıt state off) — kullanıcı kararı 2026-10-25
_fm_reset
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}"; assert_eq "$?" "0" "opt-in yok: repair 0"
assert_eq "$(ls "$CUR_DIR" | tr '\n' ' ')" "20-srvctl-fm-upload.conf " "opt-in yok: repair YALNIZ 403 kökünü (20) yazar"
assert_eq "$(_exists "$MAN")" "var" "opt-in yok: 403 kökü köken kaydında"
assert_contains "$(cat "$MAN")" "state off" "opt-in yok: kayıt durumu off"
# ihlalli kullanıcı dosyası: repair kırmaz/silmez
_fm_reset; _on
printf 'location /q {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"; ubefore=$(_md5 "${CUR_DIR}/00-custom.conf")
rm -f "$F21"
out=$(_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 2>&1); assert_eq "$?" "0" "ihlalli kullanıcı dosyası repair'i ENGELLEMEZ"
assert_contains "$out" "nginx-audit" "…ama UYARI basılır (nginx -t'den önce tarama)"
assert_eq "$(_md5 "${CUR_DIR}/00-custom.conf")" "$ubefore" "ihlalli kullanıcı dosyasına repair DOKUNMAZ"
assert_eq "$(_exists "$F21")|$(_exists "$F90")" "yok|yok" "F9c TERSİNE: 21 eksik → FM dosyası yeniden üretilmez, alan KAPANDI (eskiden: onarıldı)"
# remove: kayıt+dizin
_domain_purge_conf_files example.com
assert_eq "$(_exists "$MAN")" "yok" "domain remove köken kaydını siler"
assert_eq "$(_exists "$CUR_DIR")" "yok" "…ve custom.d dizinini"
mkdir -p "$CUR_DIR"

echo "── M: _domconf_fm_auth_forget güvenliği ──"
_fm_reset; _on
mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; : > "${SRVCTL_STATE_DIR}/_fm-auth/baska_com.manifest"
_domconf_fm_auth_forget ""; assert_eq "$(_exists "$MAN")" "var" "boş sname hiçbir şey silmez"
_domconf_fm_auth_forget "../x"; assert_eq "$(_exists "$MAN")" "var" "yol enjeksiyonlu sname hiçbir şey silmez"
_domconf_fm_auth_forget example_com; assert_eq "$(_exists "$MAN")" "yok" "doğru sname kendi kaydını siler"
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth/baska_com.manifest")" "var" "komşu alanın kaydına dokunulmadı"

echo "── N: QL4 LOW'lar — dev-L2/L4/L5, rev-L6, H1 ileti tutarlılığı ──"
# dev-L2: STATE-UNTRUSTED'da off önce --force İSTEMEZ; doğrudan doğru nedenle reddeder
_fm_reset; _on; MOCK_BAD_OWNER="${SRVCTL_STATE_DIR}/_fm-auth"
( _domconf_fm_auth_off example.com example_com "$CUR_DIR" 0 0 ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "dev-L2: STATE-UNTRUSTED off (normal yol): rc 1"
assert_contains "$(cat "$OUTF")" "STATE-UNTRUSTED" "dev-L2: neden STATE-UNTRUSTED"
assert_not_contains "$(cat "$OUTF")" "off --force" "dev-L2: yanıltıcı '--force' önerisi YOK"
( _domconf_fm_auth_off example.com example_com "$CUR_DIR" 1 0 ) >"$OUTF" 2>&1; assert_eq "$?" "1" "dev-L2: --force da aşmaz (normal yol; acil yol ayrı: test_domconf_fm_emergency.sh)"
assert_contains "$(cat "$OUTF")" "--force bunu AŞMAZ" "dev-L2: ileti açık"
MOCK_BAD_OWNER=""
# dev-L4: makinece okunur yetenek satırı
out=$(_domconf_fm_auth --capabilities 2>&1); rc=$?
assert_eq "$rc" "0" "dev-L4: --capabilities rc 0"
assert_contains "$out" "srvctl-fm-caps v1 dry=1" "dev-L4: yetenek satırı (dry)"
assert_contains "$out" "fm-root=1" "dev-L4: yetenek satırı (fm-root)"
( _domconf_fm_auth --capabilities fazla ) >/dev/null 2>&1; assert_eq "$?" "1" "dev-L4: fazla argümanla yetenek satırı basılmaz"
# dev-L5: kayıtsız FM adı — KAPATAN eylem (off) devralır (adli kopya + ileti), örtük/açan eylemler reddeder
_fm_reset; printf 'location = /user { return 200 "u"; }\n' > "$F20"
( _domconf_fm_root_provision example.com 0 ) >"$OUTF" 2>&1; assert_eq "$?" "1" "dev-L5: provision (örtük) kayıtsız 20'yi EZMEZ"
assert_contains "$(cat "$OUTF")" "srvctl domain fm-root example.com --apply" "dev-L5: provision bilinçli devralma yolunu söyler"
_on; assert_eq "$?" "1" "dev-L5: on (açan) kayıtsız 20 ile reddeder"
assert_contains "$(cat "$OUTF")" "fm-root example.com --apply" "dev-L5: on reddi fm-root yolunu söyler"
( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "dev-L5: off (kapatan) devralır"
assert_eq "$(cat "$F20")" "$(_domconf_fm_render_off example_com)" "dev-L5: off sonrası 20 = 403 kökü"
assert_eq "$(cat "${F20}.srvctl-tampered")" 'location = /user { return 200 "u"; }' "dev-L5: eski içerik adli kopyada"
assert_contains "$(cat "$OUTF")" "kayıtsız FM adlı dosya(lar) devralındı" "dev-L5: devralma açıkça söylenir"
# rev-L6: forget kilit ALTINDA; kilit alınamazsa SİLMEZ (fail-closed) ve uyarır
_fm_reset; _on; : > "$FLOCK_LOG"
_domconf_fm_auth_forget example_com; assert_eq "$(_exists "$MAN")$(grep -c . "$FLOCK_LOG")" "yok1" "rev-L6: forget kilit aldı ve sildi"
_fm_reset; _on; FLOCK_RC=1; export FLOCK_RC
out=$(_domconf_fm_auth_forget example_com 2>&1); rc=$?; FLOCK_RC=0; export FLOCK_RC
assert_eq "$rc$(_exists "$MAN")" "1var" "rev-L6: kilitsiz forget kaydı SİLMEZ (rc 1)"
assert_contains "$out" "SİLİNEMEDİ" "rev-L6: uyarı"
_fm_reset; mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.Qw12Er"; chmod 700 "${SRVCTL_STATE_DIR}/_fm-auth"
_domconf_fm_auth_forget example_com; assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.Qw12Er")" "yok" "rev-L6: forget bu alanın yarım yedeğini de temizler"
_fm_reset; : > "$FLOCK_LOG"; _domconf_fm_auth_forget example_com; assert_eq "$(grep -c . "$FLOCK_LOG")$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "0yok" "rev-L6: silinecek bir şey yoksa kilit/dizin yaratılmaz"
# rev-L6: 'domain nginx' yazımı kilit ALTINDA; kilitsizse hiçbir şey yazılmaz
_fm_reset; printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"; c0=$(_md5 "${CUR_DIR}/00-custom.conf")
printf 'client_max_body_size 9m;\n' > "${FM_STUBS}/new.conf"; : > "$FLOCK_LOG"
( _domconf_edit_nginx example.com --file "${FM_STUBS}/new.conf" ) >"$OUTF" 2>&1; assert_eq "$?$(grep -c . "$FLOCK_LOG")" "01" "rev-L6: domain nginx kilit aldı"
assert_eq "$(cat "${CUR_DIR}/00-custom.conf")" "client_max_body_size 9m;" "rev-L6: yazım uygulandı"
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"; FLOCK_RC=1; export FLOCK_RC
( _domconf_edit_nginx example.com --file "${FM_STUBS}/new.conf" ) >"$OUTF" 2>&1; rc=$?; FLOCK_RC=0; export FLOCK_RC
assert_eq "$rc$(_md5 "${CUR_DIR}/00-custom.conf")" "1${c0}" "rev-L6: kilitsiz 'domain nginx' HİÇBİR şey yazmaz"
assert_contains "$(cat "$OUTF")" "UYGULANMADI" "rev-L6: ileti"
# H1: on reddi karantinayı DOĞRU koşullarla önerir (README ile tutarlı)
_fm_reset; ( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"
_on; assert_eq "$?" "1" "H1: ihlalde on reddi"
assert_contains "$(cat "$OUTF")" "nginx-audit example.com --quarantine" "H1: karantina komutu tam"
assert_contains "$(cat "$OUTF")" "yalnız 403 kökü SAĞLAM alanda ve yalnız kullanıcı dosyalarında" "H1: karantinanın sınırı söylenir"
assert_contains "$(cat "$OUTF")" "fm-root example.com --apply" "H1: kök yoksa fm-root"
_fm_reset

test_summary
