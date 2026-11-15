#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitlerinin okuduğu bayraklar (MOCK_*, NGINX_*, SYSTEMCTL_RC …) bu dosyada atanır
# FM KÖKEN KAYDI (provenance): tarama muafiyeti YALNIZ kayda bağlıdır.
#
# Üretilmiş dosya = ad sabit kümede + normal dosya (sembolik bağ/hardlink değil) + root
# sahipli + g/o yazma yok + sha256 kayıtla eşit. Kayıt dizini/dosyası: root, sembolik bağ
# değil, tam 0700/0600, nlink==1, g/o yazılabilir zincir yok. Aksi → STATE-UNTRUSTED: HİÇBİR
# dosya "üretilmiş" tanınmaz (hepsi kullanıcı dosyası → izin listesi). İçerik kalıbıyla
# muafiyet YOKTUR (eski _DOMCONF_SCAN_OWN kaldırıldı).
#
# macOS'ta dosyalar root'a ait değildir: tests/fm_env.sh `_stat_owner`'ı taklit eder
# (MOCK_BAD_OWNER listesindekiler 'web_x'); SRVCTL_STATE_DIR WEB_ROOT ALTINDADIR
# (emsal tests/test_lock_symlink_privesc.sh).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_gen() { _fmprov_is_generated example_com "$1"; }
SD="${SRVCTL_STATE_DIR}/_fm-auth"

echo "── A: temel — üretilmiş tanınır, ad kümesi dışı tanınmaz ──"
_fm_reset; _on
for f in "$F90" "$F21" "$F20"; do assert_ok _gen "$f"; done
cp "$F90" "${CUR_DIR}/22-srvctl-fm-extra.conf"
assert_fail _gen "${CUR_DIR}/22-srvctl-fm-extra.conf"
cp "$F90" "${CUR_DIR}/90-srvctl-fm-auth.conf.bak"
assert_fail _gen "${CUR_DIR}/90-srvctl-fm-auth.conf.bak"
assert_fail _gen "${CUR_DIR}/yok.conf"
# başka alanın dizinindeki AYNI ADLI, AYNI İÇERİKLİ dosya bu alanın kaydıyla tanınmaz (özet başka alanın soketini taşır)
mkdir -p "${SRVCTL_NGINX_CUSTOM_DIR}/baska_com"
cp "$F90" "${SRVCTL_NGINX_CUSTOM_DIR}/baska_com/90-srvctl-fm-auth.conf"
_fmprov_is_generated baska_com "${SRVCTL_NGINX_CUSTOM_DIR}/baska_com/90-srvctl-fm-auth.conf"; assert_eq "$?" "1" "başka alan: kayıt yok → üretilmiş DEĞİL"
rm -rf "${SRVCTL_NGINX_CUSTOM_DIR}/baska_com" "${CUR_DIR}/22-srvctl-fm-extra.conf" "${CUR_DIR}/90-srvctl-fm-auth.conf.bak"

echo "── B: özet uyuşmazlığı ──"
cp "$F90" "${FM_STUBS}/f90.orig"
printf '# bir bayt\n' >> "$F90"
assert_fail _gen "$F90"
cp "${FM_STUBS}/f90.orig" "$F90"; chmod 644 "$F90"
assert_ok _gen "$F90"
# tek harf değişikliği
sed 's/internal;/internol;/' "${FM_STUBS}/f90.orig" > "$F90"; chmod 644 "$F90"
assert_fail _gen "$F90"
cp "${FM_STUBS}/f90.orig" "$F90"; chmod 644 "$F90"
# içerik KALIBI muafiyeti yok: aynı içerik, kayıtta olmayan özet → tanınmaz
printf '%s\n' "$(cat "${FM_STUBS}/f90.orig")" > "$F90"
printf '\n\n' >> "$F90"
assert_fail _gen "$F90"
cp "${FM_STUBS}/f90.orig" "$F90"; chmod 644 "$F90"
# qa2-Q40: özet AD'a bağlıdır — kayıtlı BAŞKA bir FM dosyasının içeriği (özeti kayıtta, ama başka adla)
# yanlış yuvaya (root sahipli, 644 kopya) konursa üretilmiş SAYILMAZ; durum TAMPERED (STALE değil)
cp "$F21" "${FM_STUBS}/f21.orig"
cp "${FM_STUBS}/f21.orig" "$F90"; chmod 644 "$F90"
assert_contains "$(cat "$MAN")" "$(_domconf_sha256_file "$F90") 21-srvctl-fm-download.conf" "(ön koşul) yuvadaki içeriğin özeti kayıtta VAR — ama 21 adıyla"
assert_fail _gen "$F90"
assert_eq "$(_fmprov_load example_com; _fmprov_file_state example_com 90-srvctl-fm-auth.conf "$F90")" "TAMPERED" "21 içeriği 90 yuvasında: TAMPERED (özet-ad bağı)"
cp "${FM_STUBS}/f90.orig" "$F21"; chmod 644 "$F21"
assert_fail _gen "$F21"
cp "${FM_STUBS}/f21.orig" "$F21"; chmod 644 "$F21"; cp "${FM_STUBS}/f90.orig" "$F90"; chmod 644 "$F90"
assert_ok _gen "$F90"; assert_ok _gen "$F21"

echo "── C: sembolik bağ / hardlink ──"
cp "$F20" "${FM_STUBS}/f20.copy"
rm -f "$F20"; ln -s "${FM_STUBS}/f20.copy" "$F20"
assert_fail _gen "$F20"
rm -f "$F20"; cp "${FM_STUBS}/f20.copy" "$F20"; chmod 644 "$F20"
assert_ok _gen "$F20"
ln "$F20" "${FM_STUBS}/f20.hard"
assert_eq "$(_stat_nlink "$F20")" "2" "sondaj: hardlink gerçekten oluştu (nlink=2)"
assert_fail _gen "$F20"
rm -f "${FM_STUBS}/f20.hard"
assert_ok _gen "$F20"
assert_eq "$(_stat_nlink "$F20")" "1" "hardlink silinince nlink=1"

echo "── D: mod (g/o yazma) ──"
for m in 666 664 646 622 662 626 777 775 757 664; do
    chmod "$m" "$F21"; assert_fail _gen "$F21"
done
for m in 644 640 600 444 400 755 750; do
    chmod "$m" "$F21"; assert_ok _gen "$F21"
done
chmod 644 "$F21"

echo "── E: sahip ──"
MOCK_BAD_OWNER="$F21"; assert_fail _gen "$F21"; assert_ok _gen "$F20"
MOCK_BAD_OWNER=""; assert_ok _gen "$F21"

echo "── F: köken kaydı GÜVENİLMEZ → STATE-UNTRUSTED, hiçbir dosya tanınmaz ──"
check_untrusted() { # $1=etiket
    assert_fail _gen "$F90"
    assert_fail _gen "$F20"
    _fmprov_load example_com; assert_eq "$?" "2" "$1: _fmprov_load rc=2 (güvenilmez)"
    out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "STATE-UNTRUSTED" "$1: status STATE-UNTRUSTED"
}
restore_ok() { chmod 600 "$MAN"; chmod 700 "$SD"; chmod 755 "${SRVCTL_STATE_DIR}"; MOCK_BAD_OWNER=""; }
# manifest modu 644
chmod 644 "$MAN"; check_untrusted "manifest 0644"; restore_ok; assert_ok _gen "$F90"
chmod 660 "$MAN"; check_untrusted "manifest 0660"; restore_ok
chmod 400 "$MAN"; check_untrusted "manifest 0400 (tam 0600 şart)"; restore_ok
# manifest sahibi
MOCK_BAD_OWNER="$MAN"; check_untrusted "manifest sahibi root değil"; restore_ok
# manifest hardlink
ln "$MAN" "${FM_STUBS}/man.hard"; check_untrusted "manifest hardlink"; rm -f "${FM_STUBS}/man.hard"; assert_ok _gen "$F90"
# manifest sembolik bağ
cp "$MAN" "${FM_STUBS}/man.copy"; rm -f "$MAN"; ln -s "${FM_STUBS}/man.copy" "$MAN"; chmod 600 "${FM_STUBS}/man.copy"
check_untrusted "manifest sembolik bağ"
rm -f "$MAN"; cp "${FM_STUBS}/man.copy" "$MAN"; chmod 600 "$MAN"; assert_ok _gen "$F90"
# dizin modu
chmod 755 "$SD"; check_untrusted "kayıt dizini 0755"; restore_ok
chmod 770 "$SD"; check_untrusted "kayıt dizini 0770"; restore_ok
# dizin sahibi
MOCK_BAD_OWNER="$SD"; check_untrusted "kayıt dizini sahibi root değil"; restore_ok
# üst dizin (state) grup-yazılabilir → zincir güvenilmez
chmod 775 "${SRVCTL_STATE_DIR}"; check_untrusted "üst dizin (state) grup-yazılabilir"; restore_ok
chmod 777 "${SRVCTL_STATE_DIR}"; check_untrusted "üst dizin (state) herkes-yazılabilir"; restore_ok
# üst dizin sahibi
MOCK_BAD_OWNER="${SRVCTL_STATE_DIR}"; check_untrusted "üst dizin sahibi root değil"; restore_ok
# kayıt dizini sembolik bağ
mv "$SD" "${SRVCTL_STATE_DIR}/_fm-auth.real"; ln -s "${SRVCTL_STATE_DIR}/_fm-auth.real" "$SD"
check_untrusted "kayıt dizini sembolik bağ"
rm -f "$SD"; mv "${SRVCTL_STATE_DIR}/_fm-auth.real" "$SD"; assert_ok _gen "$F90"
# untrusted iken izin listesi taraması dosyaları kullanıcı dosyası sayar → audit ihlal
chmod 644 "$MAN"
out=$(_domconf_nginx_audit example.com 2>&1); rc=$?
assert_eq "$rc" "1" "STATE-UNTRUSTED: üretilmiş dosyalar kullanıcı dosyası sayılır → audit İHLAL (1)"
assert_contains "$out" "STATE-UNTRUSTED" "audit STATE-UNTRUSTED der"
assert_contains "$out" "90-srvctl-fm-auth.conf" "…ve 90 dosyasını ihlal olarak listeler"
restore_ok
# untrusted iken yazım reddedilir
chmod 644 "$MAN"
snapF="$(cat "$F20")"
_on; assert_eq "$?" "1" "STATE-UNTRUSTED: on reddedilir"
assert_contains "$(cat "$OUTF")" "STATE-UNTRUSTED" "…gerekçe STATE-UNTRUSTED (genel 'yazım hatası' DEĞİL)"
assert_eq "$(cat "$F20")" "$snapF" "…dosyalar ezilmedi"
# F6-M1: NORMAL yol reddeder; 'fm-auth off' (giriş) ise acil yola düşüp KAPATIR (tests/test_domconf_fm_emergency.sh).
( _domconf_fm_auth_off example.com example_com "$CUR_DIR" 0 0 ) >/dev/null 2>&1; assert_eq "$?" "1" "STATE-UNTRUSTED: off (normal yol) reddedilir"
_domconf_fm_auth_repair example.com 8.3 >/dev/null 2>&1; assert_eq "$?" "1" "STATE-UNTRUSTED: repair 1"
_domconf_fm_auth_sock_sync example.com 8.4; assert_eq "$?" "1" "STATE-UNTRUSTED: sock_sync 1"
restore_ok

# kayıt dizini var ama MANİFEST YOK (ilk 'on'): dizin sahibi/modu kendi başına denetlenir (yalnız
# manifest zinciri dolaylı olarak örtmez)
_fm_reset; mkdir -p "$SD"; chmod 700 "$SD"
MOCK_BAD_OWNER="$SD"; _on; assert_eq "$?" "1" "kayıt dizini root değil + manifest YOK: on reddedilir"
assert_eq "$(_exists "$F20")" "yok" "…hiçbir dosya yazılmadı"
MOCK_BAD_OWNER=""; chmod 755 "$SD"; _on; assert_eq "$?" "4" "kayıt dizini 0755 + manifest YOK: secure_dir modu 0700'e DÜZELTİR, on başarılı (rc 4: açıldı, FM canlı sondası bu testte doğrulanamadı; F9e-3 §15/47(a), eskiden 0)"
assert_eq "$(_mode "$SD")" "700" "…dizin modu 0700'e çekildi"
_fm_reset; _on

echo "── G: bozuk/sahte kayıt içeriği ──"
cp "$MAN" "${FM_STUBS}/man.good"
# NOT: boru hattının sağındaki işlev ALT KABUKTA çalışır ve assert sayaçları kaybolur (sahte yeşil);
# bu yüzden her vaka önce DOSYAYA yazılır, try_man dosya alır.
try_man() { # $1=etiket $2=yeni kayıt içeriği dosyası
    cp "$2" "$MAN"; chmod 600 "$MAN"
    _fmprov_load example_com; assert_eq "$?" "2" "$1: rc=2"
    assert_fail _gen "$F90"
}
mk() { # $1=dosya, stdin yok: içerik argümanlardan
    local f="$1"; shift; cat > "$f"; }
V="${FM_STUBS}/variant.txt"
sed 's/^state on/state ?/' "${FM_STUBS}/man.good" > "$V"; try_man "geçersiz state" "$V"
sed 's/^region eu/region xx/' "${FM_STUBS}/man.good" > "$V"; try_man "geçersiz region" "$V"
sed 's#^script .*#script /current/public/x.php#' "${FM_STUBS}/man.good" > "$V"; try_man "geçersiz script" "$V"
sed 's/^php_version .*/php_version 8/' "${FM_STUBS}/man.good" > "$V"; try_man "geçersiz php" "$V"
sed 's/^modsec 1/modsec 2/' "${FM_STUBS}/man.good" > "$V"; try_man "geçersiz modsec" "$V"
sed "s/^tpl_ver ${_DOMCONF_FM_TPL_VER}/tpl_ver x/" "${FM_STUBS}/man.good" > "$V"; try_man "geçersiz tpl_ver" "$V"
{ cat "${FM_STUBS}/man.good"; echo "sha256 $(printf 'a%.0s' $(seq 1 64)) 99-evil.conf"; } > "$V"; try_man "ad kümesi dışı girdi" "$V"
{ cat "${FM_STUBS}/man.good"; echo "sha256 zzzz 90-srvctl-fm-auth.conf"; } > "$V"; try_man "geçersiz özet" "$V"
{ cat "${FM_STUBS}/man.good"; echo "bilinmeyen satir"; } > "$V"; try_man "tanınmayan satır" "$V"
grep -v '^srvctl-fm-auth-manifest' "${FM_STUBS}/man.good" > "$V"; try_man "başlık yok" "$V"
grep -v '^region ' "${FM_STUBS}/man.good" > "$V"; try_man "eksik alan (region)" "$V"
grep -v '^script ' "${FM_STUBS}/man.good" > "$V"; try_man "eksik alan (script)" "$V"
grep -v '^modsec ' "${FM_STUBS}/man.good" > "$V"; try_man "eksik alan (modsec)" "$V"
grep -v '^tpl_ver ' "${FM_STUBS}/man.good" > "$V"; try_man "eksik alan (tpl_ver)" "$V"
sed 's/^script .*/script -/' "${FM_STUBS}/man.good" > "$V"; try_man "state on iken script '-' (yalnız off'ta olabilir)" "$V"
{ cat "${FM_STUBS}/man.good"; echo "state off"; echo "state on"; } > "$V"; cp "$V" "$MAN"; chmod 600 "$MAN"
_fmprov_load example_com; assert_eq "$?" "0" "yinelenen state satırı son değeri alır (belgeli)"
# bozuk kayıt: üretilmiş dosyalar kullanıcı dosyası, status UNTRUSTED
{ cat "${FM_STUBS}/man.good"; echo "bilinmeyen satir"; } > "$V"; cp "$V" "$MAN"; chmod 600 "$MAN"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "STATE-UNTRUSTED" "bozuk kayıt: status STATE-UNTRUSTED"
_domconf_fm_auth example.com status >/dev/null 2>&1; assert_eq "$?" "1" "bozuk kayıt: status çıkış kodu 1 (AÇIK gibi 0 DEĞİL)"
cp "${FM_STUBS}/man.good" "$MAN"; chmod 600 "$MAN"; assert_ok _gen "$F90"
# boş kayıt
: > "$MAN"; chmod 600 "$MAN"; _fmprov_load example_com; assert_eq "$?" "2" "boş kayıt: rc=2"
cp "${FM_STUBS}/man.good" "$MAN"; chmod 600 "$MAN"

echo "── H: iki-aşamalı geçiş — eski+yeni özet birlikte kabul ──"
_fm_reset; _on --region=eu
old20="$(cat "$F20")"; oldh=$(_domconf_sha256_file "$F20")
# yeni içeriği (us) AÇIKÇA üret ve kayda ikisini birden yaz: çökme penceresinin taklidi
new20=$(_domconf_fm_render_upload us 1 example_com); newh=$(_domconf_sha256_text "$new20")
hashes="$(sed -n 's/^sha256 //p' "$MAN")"$'\n'"${newh} 20-srvctl-fm-upload.conf"
_fmprov_load example_com
_fmprov_write example_com on eu "$SCRIPT" "$_FMP_PHP" 1 "$hashes"
assert_ok _gen "$F20"
printf '%s\n' "$new20" > "$F20"; chmod 644 "$F20"
assert_ok _gen "$F20"
printf '%s\n' "$old20" > "$F20"; chmod 644 "$F20"
assert_ok _gen "$F20"
printf '%s\n' "$new20" > "$F20"; chmod 644 "$F20"
# yarım geçişte status: yeni içerik = kayıtlı parametrelerle (eu) taze render'dan FARKLI → STALE, TAMPERED DEĞİL
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "STALE" "yarım geçiş: STALE (TAMPERED değil)"
assert_not_contains "$out" "TAMPERED" "yarım geçişte kullanıcı dosyası zannedilmez"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >/dev/null 2>&1
assert_eq "$(grep -c '^sha256 ' "$MAN")" "3" "repair kaydı birleştirir: tam 3 özet"
out=$(_domconf_fm_auth example.com status 2>&1); assert_contains "$out" "AÇIK" "repair sonrası AÇIK"
# normal on: aşama 2'de eski özetler düşer
_on --region=us
assert_eq "$(grep -c '^sha256 ' "$MAN")" "3" "on sonrası eski özetler düştü"
assert_not_contains "$(cat "$MAN")" "$oldh" "eski özet kayıttan çıktı"
# kayıt aşama 1'de GERİ ALMA: nginx -t başarısızsa kayıt eski içeriğe döner (aşama-1 özetleri kalmaz)
snapM="$(cat "$MAN")"
NGINX_TEST_RC=1; _on --region=eu; NGINX_TEST_RC=0
assert_eq "$(cat "$MAN")" "$snapM" "başarısız geçişte kayıt aşama-1 özetleriyle KALMAZ"

echo "── I: tarama muafiyeti SADECE kayda bağlı (içerik kalıbı muafiyeti YOK) ──"
_fm_reset
# kayıt YOK; birebir şablon içeriği olan 90 dosyası → kullanıcı dosyası → izin listesi RED (fastcgi_pass)
_domconf_fm_render_auth example_com 8.3 "$SCRIPT" 1 > "$F90"; chmod 644 "$F90"
out=$(_domconf_nginx_audit example.com 2>&1); rc=$?
assert_eq "$rc" "1" "kayıtsız birebir-şablon 90 → İHLAL"
assert_contains "$out" "fastcgi_pass" "…fastcgi_pass gerekçesiyle"
assert_contains "$out" "rezerve" "…ve rezerve ad gerekçesiyle"
rm -f "$F90"
# kayıt VAR ve eşleşiyor → tarama atlar
_on
out=$(_domconf_nginx_audit example.com 2>&1); rc=$?
assert_eq "$rc" "0" "kayıtlı üretilmiş dosyalar → audit temiz"
# tek baytlık kurcalama → İHLAL
printf '#\n' >> "$F90"
out=$(_domconf_nginx_audit example.com 2>&1); rc=$?
assert_eq "$rc" "1" "kurcalanmış 90 → audit İHLAL"
assert_contains "$out" "90-srvctl-fm-auth.conf" "…hangi dosya olduğu söylenir"

test_summary
