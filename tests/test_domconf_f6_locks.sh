#!/bin/bash
# shellcheck disable=SC2034,SC2120  # fm_env.sh taklit bayrakları burada atanır; _on/_off isteğe bağlı argüman alır
# QL6 kilit boşlukları (F6 / a3) — DAVRANIŞ testleri; her biri mutantla sınanmıştır (f6/a3/raw/mut-*.txt).
#  M4  (QA12) _domconf_fm_restore_entry: yedek DİZİN değilse reddeder, alanın FM dosyalarını SİLMEZ.
#  M5  (QA09) _domconf_fm_auth_off_locked: kapatma kayıtlı region/script/php/modsec'i korur; sonraki
#             --region'suz 'on' aynı bölgeyi kullanır.
#  L13 QA01 .superseded ad çakışması soneki | QA02 supersede sembolik-bağ yedeğini reddeder |
#      QA07 yedek yokken sahte "ayrılamadı" uyarısı yok | QA13 yedekteki sembolik bağ bağ olarak döner |
#      QA18 probe süpürmesi sembolik bağlı kayıt dizinine dokunmaz | QA21 karantina hata dönüşünde
#      tuzak kalmaz | QA37 fail_restore hata dalında tuzak kalmaz | QA10 LEGACY_INC geri yüklenir/silinir.
# NOT: LV06/LV09 live/fm-stage0-test.sh içindedir (b'nin dosyası) → f6/a3/raw/LV-vakalari.md.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# F7-H2: 'fm-auth off' çalışan durumu da sınar → bu dosya curl taklidini sim kipinde açar (çalışan görüntü reload'u izler).
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
BK="${SD}/.bk.example_com.AAAAAA"
SUPD="${SD}/.superseded.bk.example_com.AAAAAA"
LEG="${CUR_DIR}/${_DOMCONF_FM_LEGACY_INC}"
list_all_domains() { printf '%s\n' example.com; }
domain_exists() { return 0; }
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_off() { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_fr() { ( _domconf_fm_root_cmd "$@" ) >"$OUTF" 2>&1; }
_st() { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_mf() { sed -n "s/^$1 //p" "$MAN" 2>/dev/null | head -1; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_mk_stale_bk() {
    rm -rf "$BK"; mkdir -p "$BK"
    local f
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" ]]; then cp -p "$f" "${BK}/"; fi; done
    cp -p "$MAN" "${BK}/manifest"
}
# işleme tek girdi (yedek yolu verilir) yükler
_tx1() { _domconf_fm_tx_reset; _FMT_BK=("$1"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR"); }
_snap4() { printf '%s|%s|%s|%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_exists "$F20")" "$(_exists "$MAN")"; }

echo "── M4 (QA12): yedek DİZİN değilse geri yükleme REDDEDİLİR, dosyalar yerinde kalır ──"
_fm_reset; _on; assert_eq "$(_snap4)" "var|var|var|var" "hazırlık: 90/21/20/kayıt var"
_tx1 "${SD}/.bk.example_com.YOKTUR"
_domconf_fm_restore_entry 0; assert_eq "$?" "1" "var olmayan yedek: restore_entry rc 1"
assert_eq "$(_snap4)" "var|var|var|var" "…90/21/20/kayıt YERİNDE (hiçbiri silinmedi)"
: > "${SD}/.bk.example_com.DOSYA"
_tx1 "${SD}/.bk.example_com.DOSYA"
_domconf_fm_restore_entry 0; assert_eq "$?" "1" "yedek düz DOSYA: rc 1"
assert_eq "$(_snap4)" "var|var|var|var" "…yedek dosya ise de hiçbir şey silinmedi"
_tx1 ""
_domconf_fm_restore_entry 0; assert_eq "$?" "1" "boş yedek yolu: rc 1"
assert_eq "$(_snap4)" "var|var|var|var" "…boş yolda da hiçbir şey silinmedi"
_domconf_fm_restore_from_bk; assert_eq "$?" "1" "restore_from_bk: reddedilen girdi → rc 1"
assert_eq "$(_snap4)" "var|var|var|var" "…toplu geri yüklemede de dosyalar yerinde"
# kontrol: geçerli yedek hâlâ geri yükler (ret koşulu fazla geniş değil)
_mk_stale_bk; rm -f -- "$F90" "$F21"
_tx1 "$BK"; _domconf_fm_restore_entry 0; assert_eq "$?" "0" "kontrol: geçerli yedek rc 0"
assert_eq "$(_snap4)" "var|var|var|var" "kontrol: silinen 90/21 yedekten geri geldi"

echo "── QA37: fail_restore hata dalı (geri alma başarısız → rc 6) yedeği korur ve tuzağı SÖKER ──"
_fm_reset; _on
_tx1 "${SD}/.bk.example_com.YOKTUR"
out=$( trap 'echo DUMMY' INT TERM HUP; _domconf_fm_fail_restore 4 >/dev/null 2>&1; rc=$?; echo "rc=${rc}"; echo "izler=[$(trap -p INT TERM HUP | tr '\n' ' ')]" )
assert_contains "$out" "rc=6" "geri alma başarısız: rc 6 (verilen kod 4 DEĞİL)"
assert_contains "$out" "izler=[]" "hata dalından dönünce INT/TERM/HUP tuzağı kalmadı"
assert_eq "$(_snap4)" "var|var|var|var" "…ve başarısız geri alma dosyaları silmedi"
out=$( _fm_reset; _on; _mk_stale_bk; trap 'echo DUMMY' INT TERM HUP; _tx1 "$BK"; _domconf_fm_fail_restore 4 >/dev/null 2>&1; rc=$?; echo "rc=${rc}"; echo "izler=[$(trap -p INT TERM HUP | tr '\n' ' ')]" )
assert_contains "$out" "rc=4" "kontrol: geri alma BAŞARILI → verilen kod 4"
assert_contains "$out" "izler=[]" "kontrol: başarılı dalda da tuzak kalmadı"

echo "── M5 (QA09): kapatma kayıtlı region/script/php/modsec'i KORUR ──"
_fm_reset; _on --region=us; assert_eq "$?" "0" "hazırlık: on --region=us rc 0"
on_snap="$(_mf region)|$(_mf script)|$(_mf php_version)|$(_mf modsec)"
assert_eq "$on_snap" "us|${SCRIPT}|8.3|1" "hazırlık: kayıt us|script|8.3|modsec 1"
assert_contains "$(cat "$F20")" "proxy_pass https://api.pcloud.com/" "hazırlık: 20 dosyası us bölgesine bakar"
_off; assert_eq "$?" "0" "off rc 0"
assert_eq "$(_st)" "off" "off sonrası durum off"
assert_eq "$(_mf region)|$(_mf script)|$(_mf php_version)|$(_mf modsec)" "$on_snap" "off kayıttaki region/script/php_version/modsec'i AYNEN korudu"
_on; assert_eq "$?" "0" "--region'suz on rc 0"
assert_eq "$(_mf region)" "us" "sonraki --region'suz on AYNI bölgeyi (us) kullandı"
assert_contains "$(cat "$F20")" "proxy_pass https://api.pcloud.com/" "…20 dosyası us (proxy_pass api.pcloud.com)"
assert_not_contains "$(cat "$F20")" "proxy_pass https://eapi.pcloud.com/" "…eu'ya DÖNMEDİ (proxy_pass eapi yok)"
# modsec=0 kaydı da korunur (yalnız '1' sabitlenmiş olamaz)
_fm_reset; NGINX_FAIL_ON_MODSEC=1; _on --region=us; assert_eq "$(_mf modsec)" "0" "hazırlık: modül yok → modsec 0"
_off; assert_eq "$(_mf modsec)|$(_mf region)" "0|us" "off modsec 0 ve region us'u korudu"
NGINX_FAIL_ON_MODSEC=0
# kayıt YOKKEN varsayılanlar (kontrol: korumanın koşulu kayıt varlığına bağlı)
_fm_reset; _off; assert_eq "$?" "0" "kayıtsız off rc 0"
assert_eq "$(_mf region)|$(_mf script)|$(_mf php_version)|$(_mf modsec)" "eu|-|-|0" "kayıt yokken varsayılan eu|-|-|0"

echo "── QA01: .superseded ad çakışması → sonek, mevcut adli kopyaya DOKUNULMAZ ──"
_fm_reset; _on; _mk_stale_bk; mkdir -p "$SUPD"; echo eski > "${SUPD}/adli-isaret"
_off; assert_eq "$?" "0" "off rc 0 (çakışma kapatmayı engellemez)"
assert_eq "$(_st)|$(_bkn)|$(_supn)" "off|0|2" "bayat yedek ayrıldı: .bk 0, .superseded 2 (eski + soneklisi)"
assert_eq "$(cat "${SUPD}/adli-isaret" 2>/dev/null)" "eski" "mevcut .superseded kopyası ve içeriği DEĞİŞMEDİ"
assert_not_contains "$(cat "$OUTF")" "ayrılamadı" "çakışmada 'ayrılamadı' uyarısı YOK"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENMEYECEK biçimde ayrıldı" "…ayrılma bildirimi var"
sufn=$(find "$SD" -maxdepth 1 -name '.superseded.bk.example_com.AAAAAA.*' | wc -l | tr -d ' ')
assert_eq "$sufn" "1" "ikinci kopya '.superseded.bk.example_com.AAAAAA.<sonek>' adında"
assert_eq "$(_exists "$(find "$SD" -maxdepth 1 -name '.superseded.bk.example_com.AAAAAA.*' | head -1)/${_DOMCONF_FM_AUTH_FILE}")" "var" "…içeriği (90) yedekten taşındı"
: > "$RELOAD_LOG"; _fr example.com --apply
assert_eq "$(_st)|$(_exists "$F90")|$(_exists "$F21")|$(_bkn)" "off|yok|yok|0" "çakışma sonrası fm-root --apply kapatmayı GERİ AÇMADI"

echo "── QA02: supersede sembolik-bağ yedeğini REDDEDER (bağın hedefi taşınmaz) ──"
_fm_reset; _on; mkdir -p "$SD/realdir"; echo x > "$SD/realdir/isaret"; ln -s "$SD/realdir" "$SD/.bk.example_com.BBBBBB"
_fmprov_bk_supersede "$SD/.bk.example_com.BBBBBB"; assert_eq "$?" "1" "sembolik bağ yedek: supersede rc 1"
assert_eq "$([[ -L "$SD/.bk.example_com.BBBBBB" ]] && echo bag || echo yok)" "bag" "…bağ yerinde"
assert_eq "$(_exists "$SD/.superseded.bk.example_com.BBBBBB")" "yok" "….superseded adı OLUŞMADI"
assert_eq "$(_exists "$SD/realdir/isaret")" "var" "…hedef dizin içeriği yerinde"
assert_eq "${_FMP_SUPERSEDED:-}" "" "…_FMP_SUPERSEDED boş"
mkdir -p "$SD/.bk.example_com.CCCCCC"; _fmprov_bk_supersede "$SD/.bk.example_com.CCCCCC"
assert_eq "$?|$(_exists "$SD/.superseded.bk.example_com.CCCCCC")" "0|var" "kontrol: gerçek dizin ayrılır"

echo "── QA07: bayat yedek YOKKEN 'ayrılamadı' / 'bayat' uyarısı üretilmez ──"
_fm_reset; _on; _off; assert_eq "$?" "0" "off rc 0 (bayat yedek yok)"
assert_not_contains "$(cat "$OUTF")" "ayrılamadı" "sahte 'ayrılamadı' uyarısı YOK"
assert_not_contains "$(cat "$OUTF")" "bayat yarım işlem" "…hiçbir 'bayat yarım işlem' uyarısı YOK"
assert_eq "$(_bkn)|$(_supn)" "0|0" "….bk ve .superseded oluşmadı"
assert_contains "$(cat "$OUTF")" "fm-auth kapatıldı" "kontrol: kapatma başarı iletisi var"

echo "── QA13: yedekteki SEMBOLİK BAĞ geri yüklenince bağ olarak kalır ──"
_fm_reset; _on; _mk_stale_bk
echo hedef > "${FM_STUBS}/target.txt"
B21="${BK}/$(basename "$F21")"
rm -f -- "${B21:?}"; ln -s "${FM_STUBS}/target.txt" "${B21:?}"
rm -f -- "${F21:?}"
# F9c (§15/38): yedeğin 21'i sembolik bağ = tanınan açık eser DEĞİL → restore_entry bu ön durumu diske AÇIK geri KOYMAZ, diski kapatır (önceki beklenti:
# restore_entry bağı olarak geri koyar). Bağ-sadakati ARTIK dosya düzeyinde (_domconf_fm_restore_file) sınanır; entry düzeyi kapatmayı sınar.
_domconf_fm_restore_file "$B21" "$F21"; assert_eq "$?" "0" "restore_file rc 0"
assert_eq "$([[ -L "$F21" ]] && echo bag || echo duz)" "bag" "21 SEMBOLİK BAĞ olarak geri geldi (hedef içerikle çözülmedi; dosya düzeyi)"
assert_eq "$(readlink "$F21")" "${FM_STUBS}/target.txt" "…bağ hedefi aynı"
rm -f -- "${F21:?}"
_tx1 "$BK"; _domconf_fm_restore_entry 0; assert_eq "$?" "0" "restore_entry rc 0"
assert_eq "$(_exists "$F21")|$(_exists "$F90")" "yok|yok" "F9c TERSİNE: bağ-21'li (tanınmayan) ön durum restore_entry ile AÇIK geri konmaz: disk 403 köküne kapatıldı (90/21 yok)"

echo "── QA10: LEGACY_INC geri yüklenir; yedekte yoksa diskten SİLİNİR ──"
_fm_reset; _on; _mk_stale_bk
printf 'legacy-yedek\n' > "${BK}/${_DOMCONF_FM_LEGACY_INC}"
rm -f -- "$LEG"
_tx1 "$BK"; _domconf_fm_restore_entry 0; assert_eq "$?" "0" "yedekte legacy inc var: rc 0"
assert_eq "$(cat "$LEG" 2>/dev/null)" "legacy-yedek" "legacy inc YEDEKTEN geri geldi"
rm -f -- "${BK}/${_DOMCONF_FM_LEGACY_INC}"; printf 'sonradan-eklendi\n' > "$LEG"
_tx1 "$BK"; _domconf_fm_restore_entry 0; assert_eq "$?" "0" "yedekte legacy inc yok: rc 0"
assert_eq "$(_exists "$LEG")" "yok" "yedekte olmayan legacy inc diskten KALDIRILDI"

echo "── QA18: probe süpürmesi sembolik bağlı kayıt dizinine DOKUNMAZ ──"
_fm_reset
E="${WEB_ROOT}/baska-yer"; mkdir -p "${E}/.probe.AAAAAA"
rm -rf -- "${SD:?}"; ln -s "$E" "$SD"
( _domconf_fm_probe_sweep ) >"$OUTF" 2>&1; assert_eq "$?" "0" "sembolik bağlı kayıt dizini: sweep rc 0"
assert_eq "$(_exists "${E}/.probe.AAAAAA")" "var" "bağın hedefindeki .probe.AAAAAA SİLİNMEDİ"
assert_not_contains "$(cat "$OUTF")" "temizlendi" "…'temizlendi' uyarısı yok"
rm -f -- "$SD"; mkdir -p "${SD}/.probe.AAAAAA"
( _domconf_fm_probe_sweep ) >"$OUTF" 2>&1
assert_eq "$(_exists "${SD}/.probe.AAAAAA")" "yok" "kontrol: gerçek kayıt dizinindeki bayat .probe.* silinir"
assert_contains "$(cat "$OUTF")" "1 eski ModSecurity sonda dizini" "kontrol: silinen sayısı bildirilir"

echo "── QA21: karantina HATA dönüşlerinde INT/TERM/HUP tuzağı kalmaz ──"
_q_prep() { _fm_reset; ( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1
            printf 'location /x { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/10-app.conf"; : > "$RELOAD_LOG"; }
_q_prep
out=$( _Q_DOM=(example.com); _Q_SRC=("${CUR_DIR}/10-app.conf"); _Q_DST=(); NGINX_TEST_RC=1
       _domconf_quarantine_locked >/dev/null 2>&1; rc=$?; echo "rc=${rc}"; echo "izler=[$(trap -p INT TERM HUP | tr '\n' ' ')]"
       echo "dosya=$(_exists "${CUR_DIR}/10-app.conf")" )
assert_contains "$out" "rc=3" "nginx -t başarısız: karantina rc 3 (geri alındı)"
assert_contains "$out" "izler=[]" "…dönüşte tuzak KALMADI"
assert_contains "$out" "dosya=var" "…dosya yerinde"
_q_prep; rm -f -- "$F20"
out=$( _Q_DOM=(example.com); _Q_SRC=("${CUR_DIR}/10-app.conf"); _Q_DST=()
       _domconf_quarantine_locked >/dev/null 2>&1; rc=$?; echo "rc=${rc}"; echo "izler=[$(trap -p INT TERM HUP | tr '\n' ' ')]"
       echo "dosya=$(_exists "${CUR_DIR}/10-app.conf")" )
assert_contains "$out" "rc=4" "403 kökü sağlam değil: karantina rc 4"
assert_contains "$out" "izler=[]" "…bu hata dönüşünde de tuzak KALMADI"
assert_contains "$out" "dosya=var" "…hiçbir dosya taşınmadı"
_q_prep
out=$( _Q_DOM=(example.com); _Q_SRC=("${CUR_DIR}/10-app.conf"); _Q_DST=()
       _domconf_quarantine_locked >/dev/null 2>&1; rc=$?; echo "rc=${rc}"; echo "izler=[$(trap -p INT TERM HUP | tr '\n' ' ')]"
       echo "dosya=$(_exists "${CUR_DIR}/10-app.conf")" )
assert_contains "$out" "rc=0" "kontrol: başarılı karantina rc 0"
assert_contains "$out" "izler=[]" "kontrol: başarıda da tuzak kalmadı"
assert_contains "$out" "dosya=yok" "kontrol: dosya karantinaya alındı"

test_summary
