#!/bin/bash
# shellcheck disable=SC2034,SC2120  # fm_env.sh taklit bayrakları burada atanır; _on/_off isteğe bağlı argüman alır
# QL5-M1/M6/L5/L9 — bayat "yarım işlem" yedeği ve acil kapatma.
#  - Kapatma (fm-auth off) bayat yedek varken ASLA reddedilmez ama kapatmadan SONRA hiçbir kurtarma
#    komutu (fm-root --apply, repair, status önerisi) kapatmayı geri açamaz: yedek geri yüklenmeden
#    '.superseded.' adıyla ayrılır.
#  - Kayıt durumu KAPALI iken bir yedek ASLA geri yüklenmez (kuru plan bunu söyler).
#  - fm-auth on ve php-switch soket senkronu yarım yedek varken yazmaz.
#  - Geri yükleme İDEMPOTENT: ortada ölen kurtarma ikinci turda dosyaları silmez, 'on' durumunu kaybetmez.
#  - Sinyal çıkış kodları: INT 130, TERM 143, HUP 129 (karantina dahil).
# NOT: `nohup … &` / arka plan başlatması SIGINT/SIGHUP'ı YOK SAYDIRIR (yok sayılan sinyal yakalanamaz) →
#  F ve G bölümleri sahte FAIL verir; testi ön planda ya da sinyalleri varsayılana alan bir sürücüyle koşun.
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
list_all_domains() { printf '%s\n' example.com; }
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_off() { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_off_normal() { ( _domconf_fm_auth_off example.com example_com "$CUR_DIR" 0 0 ) >"$OUTF" 2>&1; }
_fr() { ( _domconf_fm_root_cmd "$@" ) >"$OUTF" 2>&1; }
_st() { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_supn() { find "$SD" -maxdepth 1 -name '.superseded.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
# Açık durumun (90/21/20 + kayıt) kopyasını bayat yarım-işlem yedeği olarak bırakır.
_mk_stale_bk() {
    rm -rf "$BK"; mkdir -p "$BK"
    local f
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" ]]; then cp -p "$f" "${BK}/"; fi; done
    cp -p "$MAN" "${BK}/manifest"
}
_snap() { printf '%s|%s|%s|%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_st)" "$(_bkn)"; }

echo "── A: QL5-M1 — bayat yedek + off → fm-root --apply / repair kapatmayı GERİ AÇAMAZ ──"
_fm_reset; _on; assert_eq "$(_st)" "on" "hazırlık: durum on"
_mk_stale_bk
_off; assert_eq "$?" "0" "off: bayat yedek varken de KAPATIR (rc 0)"
assert_eq "$(_st)" "off" "off sonrası kayıt: off"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "off sonrası 90/21 yok"
assert_eq "$(_bkn)" "0" "bayat .bk. yedeği artık 'yarım işlem' olarak DURMUYOR"
assert_eq "$(_supn)" "1" "…silinmedi: .superseded.bk.* olarak ayrıldı (adli)"
assert_eq "$(_exists "${SUPD}/${_DOMCONF_FM_AUTH_FILE}")" "var" "…içeriği korundu"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENMEYECEK biçimde ayrıldı" "off: operatöre söylenir"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); rc=$?
assert_eq "$rc" "0" "status: KAPALI rc 0"
assert_not_contains "$out" "YARIM İŞLEM" "status: 'YARIM İŞLEM' ve 'fm-root --apply ile kurtar' önerisi KALMADI"
_fr example.com; assert_contains "$(cat "$OUTF")" "sağlam: KAPALI (403 kökü)" "fm-root kuru: sağlam KAPALI (kurtarma planlanmaz)"
: > "$RELOAD_LOG"
_fr example.com --apply; assert_eq "$?" "0" "fm-root --apply: rc 0"
assert_eq "$(_st)|$(_exists "$F90")|$(_exists "$F21")" "off|yok|yok" "fm-root --apply KAPATMAYI GERİ AÇMADI (state off, 90/21 yok)"
assert_eq "$(_reloads)" "0" "…ve yazım olmadığından reload yok"
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; assert_eq "$?" "0" "repair: rc 0"
assert_eq "$(_st)|$(_exists "$F90")|$(_exists "$F21")" "off|yok|yok" "repair KAPATMAYI GERİ AÇMADI"

echo "── A2: off başarısızsa (nginx -t) geri alınır, bayat yedek DOKUNULMAZ ──"
_fm_reset; _on; _mk_stale_bk; NGINX_TEST_RC=1
_off_normal; assert_eq "$?" "1" "off (NORMAL yol) + nginx -t hatası: rc 1"
NGINX_TEST_RC=0
assert_eq "$(_st)|$(_exists "$F90")|$(_bkn)|$(_supn)" "on|var|1|0" "başarısız NORMAL kapatma: durum on, bayat yedek yerinde (ayrılmadı)"
# F6-M1: giriş ('fm-auth off') normal yol düşünce ACİL yola geçer: disk kapanır, bayat yedek geri yüklenmeden ayrılır.
_fm_reset; _on; _mk_stale_bk; NGINX_TEST_RC=1
_off; assert_eq "$?" "3" "off (giriş) + nginx -t hatası: acil yol disk KAPALI, çalışan nginx eski AÇIK yapılandırmada (sim) → rc 3"
NGINX_TEST_RC=0
assert_eq "$(_st)|$(_exists "$F90")|$(_bkn)|$(_supn)" "off|yok|0|1" "acil kapatma: durum off, 90 yok, bayat yedek geri yüklenmeden AYRILDI"

echo "── B: kayıt KAPALIYKEN yedek ASLA geri yüklenmez (kurtarma yolları) ──"
_fm_reset; _on; _mk_stale_bk
# eski kodun/yarışın bıraktığı durum: kayıt off ama pre-state 'on' yedeği duruyor (supersede'siz kapatma)
( _fmprov_with_lock _domconf_fm_apply example.com example_com off eu - - 0 0 ) >/dev/null 2>&1
assert_eq "$(_st)|$(_exists "$F90")|$(_bkn)" "off|yok|1" "hazırlık: kayıt off, 90 yok, pre-state=on yedeği duruyor"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); rc=$?
assert_eq "$rc" "1" "kayıt off + bayat yedek: status rc 1 (YARIM İŞLEM)"
assert_contains "$out" "fm-root --apply bu yedeği GERİ YÜKLEMEZ" "status: KAPALI kayıtta kurtarmanın geri yüklemeyeceğini söyler"
_fr example.com; rc=$?
assert_eq "$rc" "0" "kuru plan: rc 0"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENMEYECEK: kayıt durumu KAPALI" "kuru plan açıkça söyler: yedek geri yüklenmeyecek"
assert_not_contains "$(cat "$OUTF")" "kesinti öncesine geri yüklenecek" "kuru plan 'geri yüklenecek' DEMEZ"
: > "$RELOAD_LOG"
_fr example.com --apply; rc=$?
assert_eq "$rc" "0" "fm-root --apply: rc 0"
assert_eq "$(_st)|$(_exists "$F90")|$(_exists "$F21")|$(_bkn)|$(_supn)" "off|yok|yok|0|1" "KAPALI korundu; yedek ayrıldı"
assert_eq "$(_reloads)" "1" "diskte değişiklik olabilirdi: TEK reload"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENMEDİ: kayıt durumu KAPALI" "uyarı basılır"
# repair yolu
_fm_reset; _on; _mk_stale_bk
( _fmprov_with_lock _domconf_fm_apply example.com example_com off eu - - 0 0 ) >/dev/null 2>&1
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "repair (kayıt off + bayat on yedeği): rc 0"
assert_eq "$(_st)|$(_exists "$F90")|$(_exists "$F21")|$(_bkn)|$(_supn)" "off|yok|yok|0|1" "repair kapatmayı GERİ AÇMADI"
# güvenilmez kayıtta hiçbir şey geri yüklenmez (yedek korunur)
_fm_reset; _on; _mk_stale_bk; MOCK_BAD_OWNER="$MAN"      # kayıt DOSYASI güvenilmez (dizin sağlam: kilit alınır, kurtarma gövdesi koşar)
h20=$(_md5 "$F20")
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1; rc=$?
MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "STATE-UNTRUSTED kayıt: kurtarma reddedilir (rc 1)"
assert_contains "$(cat "$OUTF")" "köken kaydı güvenilmez (STATE-UNTRUSTED)" "…neden söylenir (kilit reddi değil, kurtarma gövdesi)"
assert_eq "$(_bkn)|$(_md5 "$F20")" "1|${h20}" "…yedek KORUNDU, dosyalara dokunulmadı"
# kayıt AÇIKken yedek hâlâ geri yüklenir (kesinti öncesine dönüş korunmuş davranış)
_fm_reset; _on; _mk_stale_bk
# F9c (§15/38) TERSİNE: eski fixture (yalnız 90 bozuk, 20 tanınan) artık kaydı OFF sayar (üç eser tanınmalı) → yedek geri yüklenmez (aşağıda). Geri yükleme kontrolü: disk de tanınan açık.
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "kayıt on: kurtarma rc 0"
assert_contains "$(cat "$OUTF")" "kesinti ÖNCESİ haline geri yüklendi" "kayıt on: geri yüklendi"
_fm_reset; _on; _mk_stale_bk
printf 'garbage\n' > "$F90"          # F9c: 20 tanınan ama 90 bozuk → kayıt off sayılır → yedek GERİ YÜKLENMEZ, ayrılır
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(_bkn)|$(_supn)" "0|0|1" "F9c TERSİNE: 90 bozuk (20 tanınan): kurtarma yedeği geri yüklemez, ayırır"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENMEDİ: kayıt durumu KAPALI" "F9c TERSİNE: neden söylenir (sınıf 4 = kayıt KAPALI sayıldı)"
assert_eq "$(_st)|$(_exists "$F90")|$(_bkn)" "on|var|0" "…önceki (on) hâl geldi, yedek silindi"
# F9b (§15/33): 20 tanınan açık eser DEĞİLSE (kayıt 'on' görünse de sınıf 4: kapalı sayılır) kurtarma ön durumu GERİ YÜKLEMEZ, yedeği ayırır
_fm_reset; _on; _mk_stale_bk
printf 'garbage\n' > "$F20"
( _fmprov_with_lock _fmprov_recover_locked example.com example_com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "F9b: 20 tanınmayan: kurtarma rc 0"
assert_contains "$(cat "$OUTF")" "GERİ YÜKLENMEDİ" "F9b: 20 tanınmayan: geri yüklenmedi söylenir"
assert_eq "$(_bkn)|$(_supn)" "0|1" "F9b: 20 tanınmayan: yedek adli olarak ayrıldı"

echo "── B2: alan SİLİNİRKEN ayrılmış (.superseded.) yedekler de aynı alanın kalıntısı olarak gider ──"
_fm_reset; _on; _mk_stale_bk; _off
mkdir -p "${SD}/.superseded.bk.baska_com.ZZZZZZ"        # başka bir alanın ayrılmış yedeği: DOKUNULMAZ
assert_eq "$(_supn)" "2" "hazırlık: iki ayrılmış yedek (example_com + baska_com)"
_domconf_fm_auth_forget example_com; assert_eq "$?" "0" "forget rc 0"
assert_eq "$(_exists "$SUPD")$(_exists "${SD}/.superseded.bk.baska_com.ZZZZZZ")$(_exists "$MAN")" "yokvaryok" "yalnız example_com'un ayrılmış yedeği + kaydı silindi; başka alanınki durur"
rm -rf "${SD}/.superseded.bk.baska_com.ZZZZZZ"

echo "── C: QL5-M6 — fm-auth on yarım yedek varken YAZMAZ ──"
_fm_reset; _on; _mk_stale_bk; s0=$(_snap); : > "$NGINX_T_LOG"
_on --region=us; rc=$?
assert_eq "$rc" "1" "on + yarım yedek: rc 1"
assert_contains "$(cat "$OUTF")" "fm-auth on REDDEDİLDİ: bu alanın yarım kalmış bir FM yazımı var" "gerekçe söylenir"
assert_eq "$(_snap)" "$s0" "hiçbir şey değişmedi (yedek yerinde, durum aynı)"
assert_eq "$(grep -c . "$NGINX_T_LOG")" "0" "nginx -t / sonda ÇALIŞMADI"
rm -rf "$BK"
_on --region=us; assert_eq "$?" "0" "(kontrol) yedek yokken aynı komut başarılı"

echo "── D: php-switch soket senkronu yarım yedek varken yedeği ÖNCE kurtarır (§15/93(b)(2); önceden: REDDEDİLİR, yedek yerinde) ──"
_fm_reset; _on; _mk_stale_bk
_domconf_fm_auth_sock_sync example.com 8.4 >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "10" "sock_sync + yarım yedek: kurtarma + senkron, rc 10"
assert_eq "$(grep -c 'php8.4-fpm' "$F90")|$(_bkn)" "1|0" "90 yeni sokete çekildi, yedek tüketildi (kesinti öncesi hâline geri yüklendi)"
assert_not_contains "$(cat "$OUTF")" "soket senkronu REDDEDİLDİ" "artık 'REDDEDİLDİ' denmez"
_fm_reset; _on
_domconf_fm_auth_sock_sync example.com 8.4 >/dev/null 2>&1; assert_eq "$?" "10" "(kontrol) yedek yokken sock_sync güncelledi (10)"

echo "── E: QL5-L5 — geri yükleme İDEMPOTENT (ortada ölen kurtarma) ──"
_fm_reset; _on; _mk_stale_bk
printf 'garbage\n' > "$F20"
_domconf_fm_tx_reset; _FMT_BK=("$BK"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR")
_domconf_fm_restore_entry 0; assert_eq "$?" "0" "1. geri yükleme rc 0"
s1="$(_md5 "$F90")$(_md5 "$F21")$(_md5 "$F20")$(_md5 "$MAN")"
assert_eq "$(find "$BK" -type f | wc -l | tr -d ' ')" "4" "yedek TÜKETİLMEDİ (4 dosya hâlâ yedekte)"
_domconf_fm_restore_entry 0; assert_eq "$?" "0" "2. geri yükleme rc 0"
assert_eq "$(_md5 "$F90")$(_md5 "$F21")$(_md5 "$F20")$(_md5 "$MAN")" "$s1" "2. geri yükleme AYNI sonucu verir (90/21/20/kayıt silinmedi)"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")$(_exists "$MAN")" "varvarvarvar" "dosyalar ve kayıt yerinde"
_domconf_fm_tx_reset
# tam akış: kurtarma bk silinmeden öldü → fm-root --apply ikinci kez: 'on' korunur, ileti doğru
: > "$RELOAD_LOG"
_fr example.com --apply; rc=$?
assert_eq "$rc" "0" "ikinci kurtarma (fm-root --apply): rc 0"
assert_eq "$(_st)|$(_exists "$F90")|$(_exists "$F21")|$(_exists "$F20")|$(_bkn)" "on|var|var|var|0" "'on' durumu KAYBOLMADI, dosyalar duruyor, yedek temizlendi"
assert_contains "$(cat "$OUTF")" "kesinti ÖNCESİ haline geri yüklendi" "ileti gerçeği söyler"
assert_contains "$(cat "$OUTF")" "sağlam: AÇIK" "sonuç: sağlam AÇIK"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); assert_contains "$out" "fm-auth AÇIK" "status: AÇIK"
# yedekte olmayan (kayıtsız) dosya geri yüklemede silinir (kesinti öncesinde yoktu)
_fm_reset; _domconf_fm_root_provision example.com 0 >/dev/null 2>&1
rm -rf "$BK"; mkdir -p "$BK"; cp -p "$F20" "${BK}/"; cp -p "$MAN" "${BK}/manifest"
printf 'yarim\n' > "$F90"
_domconf_fm_tx_reset; _FMT_BK=("$BK"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR")
_domconf_fm_restore_entry 0; assert_eq "$(_exists "$F90")$(_exists "$F20")" "yokvar" "yedekte olmayan yarım 90 silindi, 20 geri geldi"
_domconf_fm_tx_reset; rm -rf "$BK"
# hedef dizinse geri yükleme reddeder (mv hedef-dizin tuzağı)
_fm_reset; _domconf_fm_root_provision example.com 0 >/dev/null 2>&1
rm -rf "$BK"; mkdir -p "$BK"; cp -p "$F20" "${BK}/"; cp -p "$MAN" "${BK}/manifest"; cp -p "$F20" "${BK}/${_DOMCONF_FM_AUTH_FILE}"
mkdir "$F90"
_domconf_fm_tx_reset; _FMT_BK=("$BK"); _FMT_SNAME=(example_com); _FMT_DIR=("$CUR_DIR")
_domconf_fm_restore_entry 0; assert_eq "$?" "1" "hedef bir DİZİN ise geri yükleme rc 1 (dizinin içine taşımaz)"
assert_eq "$(find "$F90" -type f | wc -l | tr -d ' ')" "0" "…dizinin içine dosya konmadı"
_domconf_fm_tx_reset; rm -rf "$F90" "$BK"

echo "── F: QL5-L9 — sinyal çıkış kodları (INT 130, TERM 143, HUP 129) ──"
_fm_reset; _on
PIDF="${FM_STUBS}/pid.txt"
_sig_hook() { [[ "$NGINX_T_ARGS" == "-t" ]] || return 0; kill -"$SIG" "$KILL_TARGET"; sleep 0.3; }
for pair in INT:130 TERM:143 HUP:129; do
    SIG="${pair%%:*}"; want="${pair##*:}"
    snapF="$(cat "$F20")|$(cat "$F90")|$(cat "$MAN")"
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_sig_hook; _domconf_fm_auth example.com on "--script=${SCRIPT}" --region=us ) >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "$want" "fm-auth on + ${SIG} → ${want}"
    assert_eq "$(cat "$F20")|$(cat "$F90")|$(cat "$MAN")|$(_bkn)" "${snapF}|0" "${SIG}: geri alındı, yedek temizlendi"
done
NGINX_T_HOOK=""
# sonda anında HUP/INT
_sigp_hook() { [[ "$NGINX_T_ARGS" == "-t -c "* ]] || return 0; kill -"$SIG" "$KILL_TARGET"; sleep 0.3; }
for pair in INT:130 HUP:129; do
    SIG="${pair%%:*}"; want="${pair##*:}"
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_sigp_hook; _domconf_fm_auth example.com on "--script=${SCRIPT}" --region=us ) >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "$want" "sonda anında ${SIG} → ${want}"
    assert_eq "$(find "$SD" -maxdepth 1 -name '.probe.*' | wc -l | tr -d ' ')" "0" "${SIG}: sonda dizini temizlendi"
done
NGINX_T_HOOK=""
# varsayılan (argümansız) kod 130
( _domconf_fm_apply_abort ) >/dev/null 2>&1; assert_eq "$?" "130" "apply_abort argümansız: 130"
( _domconf_fm_apply_abort 143 ) >/dev/null 2>&1; assert_eq "$?" "143" "apply_abort 143"

echo "── G: QL5-L9 — karantina INT/TERM tuzağı: taşımalar geri alınır, sinyal koduyla çıkılır ──"
mk_q() { _fm_reset; ( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1
         printf 'location /x { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/10-app.conf"; : > "$RELOAD_LOG"; }
domain_exists() { return 0; }
for pair in INT:130 TERM:143 HUP:129; do
    SIG="${pair%%:*}"; want="${pair##*:}"
    mk_q
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); NGINX_T_HOOK=_sig_hook; _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1; rc=$?
    assert_eq "$rc" "$want" "karantina sırasında ${SIG} → ${want}"
    assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "varyok" "${SIG}: taşıma GERİ alındı (dosya yerinde, karantina adı yok)"
    assert_eq "$(_reloads)" "0" "${SIG}: reload YOK"
done
NGINX_T_HOOK=""
mk_q; _domconf_nginx_audit example.com --quarantine >"$OUTF" 2>&1
assert_eq "$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")$(_reloads)" "var1" "(kontrol) sinyalsiz karantina tamamlanır, tek reload"
# reload BAŞLADIKTAN sonra gelen sinyal taşımaları GERİ ALMAZ (tuzak reload'dan önce kalkar):
# geri alma, çalışan nginx (yeni yapılandırmayı yükledi) ile diski ayrıştırırdı.
mk_q
( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF")
  systemctl() { if [[ "$1" == "reload" ]]; then kill -TERM "$KILL_TARGET"; sleep 0.3; fi; return 0; }
  _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "143" "reload sırasında TERM: sinyal koduyla çıkıldı (143)"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "yokvar" "reload sırasında TERM: taşıma GERİ ALINMADI (tuzak reload'dan önce kalktı)"
# tuzak sızıntısı yok: karantina bittikten sonra INT/TERM/HUP tuzağı kalmaz
mk_q; ( _domconf_nginx_audit example.com --quarantine >/dev/null 2>&1; trap -p INT TERM HUP ) > "$OUTF" 2>&1
assert_eq "$(grep -c . "$OUTF")" "0" "karantina sonrası kabukta INT/TERM/HUP tuzağı KALMADI"

test_summary
