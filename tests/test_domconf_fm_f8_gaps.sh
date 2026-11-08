#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F8/a1 (QL8-M4, M6, L4, L5, L9, L10, L13) — davranış kilitleri
#  M4   --capabilities: sözleşmedeki 13 alan, sırasıyla; live/fm-stage0-test.sh F4_CAPS_REQUIRED ile parite
#       (live betiği bulunamazsa 2 assertion AÇIKÇA "SKIP" raporlanır ve sonda "Atlanan: 2" satırına yansır; SRVCTL_REQUIRE_LIVE=1 ise FAIL)
#  M6   _domconf_fm_em_marker_write "mevcut" dönüşü (A09), üst bileşen sembolik bağ (A03), işaret YOL iletisi (A06),
#       SRVCTL_FM_EMERGENCY_LOCK_WAIT sınırları (W01/W02/N12), SRVCTL_FM_OFF_LOCK_WAIT doğrulaması
#  L4   status rc: doğrulanamadı (sonda kör) → rc 4; rc 0 yalnız doğrulanmış KAPALI ya da kayıtla uyumlu doğrulanmış AÇIK
#  L5   _domconf_fm_em_state_dir_prepare: mkdir + 0700 + root güveni, idempotent; varsayılan yol (SRVCTL_FM_EMERGENCY_DIR yok)
#  L9   ikinci konum ret NEDENİ iletide (mod / sahip / sembolik bağ / sondaki '/' / yazılamadı)
#  L10  acil yol düz dosya YABANCI 20'yi ezmeden önce adli kopya (<ad>.srvctl-foreign.<ts>); dizin/bağ davranışı korunur
#  L13  N2 (sarkan bağ 90 kanıtı), N4 (çok girdili kapı), N6 (errexit geri yükleme), N11 (INT/TERM/HUP tuzağı geri yükleme)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
export SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"
ALT="${SRVCTL_FM_EMERGENCY_DIR}"
AMARK="${ALT}/example_com.emergency"
list_all_domains() { printf '%s\n' example.com; }

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_closed() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]]; }
_disk() { printf '%s%s%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_closed && echo K || echo A)"; }
_fcnt() { find "$CUR_DIR" -maxdepth 1 -name '*.srvctl-foreign.*' 2>/dev/null | wc -l | tr -d ' '; }
_scn_symlink() {   # kayıt dizini sembolik bağ → ikinci konum kullanılır; çağıran sonda _unsymlink ile düzeltir
    mv "$SD" "${SD}.real"; ln -s "${SD}.real" "$SD"
}
_unsymlink() { rm -f "$SD"; mv "${SD}.real" "$SD"; }

echo "── M4: --capabilities satırı ──"
CAPS_WANT="srvctl-fm-caps v1 dry=1 fm-root=1 audit-root=1 quarantine-safe=1 modsec-probe=1 add-fail-closed=1 f5-supersede=1 f6-emergency-off=1 f7-sig=1 f7-emergency-marker=1 f8-stage-gate=1 f8-closed-evidence=1 f9e-on-rc4=1 f9e-state-untrusted=1"
out=$(_domconf_fm_auth --capabilities 2>&1)
assert_eq "$out" "$CAPS_WANT" "caps: TAM satır (başlık + dry + 7 eski alan + f7-sig f7-emergency-marker f8-stage-gate f8-closed-evidence + f9e-on-rc4 f9e-state-untrusted)"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "1" "caps: tek satır"
assert_eq "$(printf '%s' "$out" | tr ' ' '\n' | grep -c '=1$')" "14" "caps: satırda 14 '=1' alanı (dry=1 AYRI + 13 sözleşme alanı: 7 eski + 4 F7/F8 + 2 F9e)"
assert_eq "$(printf '%s' "$out" | tr ' ' '\n' | grep '=1$' | grep -vc '^dry=1$')" "13" "caps: dry hariç 13 sözleşme alanı"
assert_contains "$out" " f8-closed-evidence=1 f9e-on-rc4=1 f9e-state-untrusted=1" "caps: §15/49 alanları (on rc 4 + güvenilmez kayıt dizini reddi) F8 alanlarından sonra, sözleşme sırasıyla"
# live/fm-stage0-test.sh srvctl deposunun DIŞINDA yaşar (wgart tarafı). Çözüm sırası: SRVCTL_LIVE_STAGE0 (açık yol) ->
# <depo>/live/ (varsa, depo-yerel) -> <depo>/../live/ (kardeş çalışma ağacı düzeni). Bulunamazsa sessizce geçilmez:
# SKIP satırı + SKIPPED sayacı (sonda "Atlanan: N"); SRVCTL_REQUIRE_LIVE=1 ile (kabul koşumu) eksiklik FAIL olur.
SKIPPED=0
LIVE=""
for _cand in "${SRVCTL_LIVE_STAGE0:-}" "${REPO_ROOT}/live/fm-stage0-test.sh" "${REPO_ROOT}/../live/fm-stage0-test.sh"; do
    [[ -n "$_cand" && -f "$_cand" ]] && { LIVE="$_cand"; break; }
done
if [[ -z "$LIVE" && "${SRVCTL_REQUIRE_LIVE:-0}" == "1" ]]; then
    assert_eq "live/fm-stage0-test.sh bulunamadı" "live/fm-stage0-test.sh bulundu" "caps parite: SRVCTL_REQUIRE_LIVE=1 iken live betiği ZORUNLU (SRVCTL_LIVE_STAGE0=<yol>)"
fi
if [[ -n "$LIVE" ]]; then
    req=$(sed -n 's/^F4_CAPS_REQUIRED="\(.*\)"$/\1/p' "$LIVE" | head -1)
    have=$(printf '%s' "$out" | tr ' ' '\n' | sed -n 's/^\(.*\)=1$/\1/p' | grep -v '^dry$' | tr '\n' ' ' | sed 's/ $//')
    assert_eq "$(printf '%s' "$req" | wc -w | tr -d ' ')" "13" "caps parite: live F4_CAPS_REQUIRED 13 alan"
    assert_eq "$have" "$req" "caps parite: srvctl --capabilities alanları (dry hariç) = live/fm-stage0-test.sh F4_CAPS_REQUIRED (aynı 13 alan, aynı sıra)"
else
    SKIPPED=$((SKIPPED + 2))
    echo "  SKIP caps parite (2 assertion): live/fm-stage0-test.sh bulunamadı (SRVCTL_LIVE_STAGE0=<yol> verin; kabul koşumunda SRVCTL_REQUIRE_LIVE=1)"
fi

echo "── M6/G-A06: işaretin YAZILDIĞI yol iletide (kayıt dizini) ──"
_fm_reset; _on; _e --emergency
assert_contains "$(_out)" "disk kapatılmadan ÖNCE): ${MARK}" "A06: ileti kayıt dizinindeki işaretin yolunu söyler"
assert_not_contains "$(_out)" "${AMARK}" "A06: ikinci konum yolu YAZILMADI (yazılmadı)"
_fm_reset; _on; _scn_symlink; _e --emergency; _unsymlink
assert_contains "$(_out)" "disk kapatılmadan ÖNCE): ${AMARK}" "A06: ikinci konuma yazılınca ileti ONUN yolunu söyler"

echo "── M6/G-A09: önceki işaret duruyor, ikinci konum sonradan güvenilmez → 'mevcut' korur ──"
_fm_reset; _on; _scn_symlink
_e; rc1=$?
assert_eq "$rc1|$(_exists "$AMARK")" "0|var" "A09: ilk acil kapatma ikinci konuma yazdı"
chmod 755 "$ALT"
_e --emergency; rc=$?
chmod 700 "$ALT"
assert_eq "$rc" "0" "A09: ikinci konum güvenilmez ama önceki işaret duruyor → koruma sürer, rc 0 (rc 6 DEĞİL)"
assert_contains "$(_out)" "önceden yazılmış" "A09: 'önceden yazılmış' söylenir"
_unsymlink

echo "── M6/G-A03: ikinci konumun ÜST bileşeni sembolik bağ → güvenilmez (rc 6), NEDEN iletide ──"
_fm_reset; _on; _scn_symlink
rm -rf "${WEB_ROOT}/realp" "${WEB_ROOT}/linkp"; mkdir -p "${WEB_ROOT}/realp/fm-emergency"; chmod 700 "${WEB_ROOT}/realp/fm-emergency"
ln -s "${WEB_ROOT}/realp" "${WEB_ROOT}/linkp"
( export SRVCTL_FM_EMERGENCY_DIR="${WEB_ROOT}/linkp/fm-emergency"; _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(ls "${WEB_ROOT}/realp/fm-emergency" | wc -l | tr -d ' ')" "6|0" "A03: üst bileşen sembolik bağ: işaret YAZILMADI, rc 6"
assert_contains "$(_out)" "bir bileşen sembolik bağ" "A03/L9: neden iletide: yol bileşeni sembolik bağ"
_unsymlink

echo "── L9: ikinci konum reddinin NEDENİ iletiye girer ──"
l9() {   # l9 <ad> <beklenen ifade> <hazırlık-işlevi> [env-yolu]
    local nm="$1" want="$2" prep="$3" dirpath="${4:-$ALT}"
    _fm_reset; _on; _scn_symlink
    mkdir -p "$ALT"; chmod 700 "$ALT"
    "$prep"
    ( export SRVCTL_FM_EMERGENCY_DIR="$dirpath"; _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
    assert_eq "$rc" "6" "L9 [${nm}]: işaret hiçbir yere yazılamadı → rc 6"
    assert_contains "$(_out)" "ikinci konum da güvenilir değil/yazılamadı (${dirpath}): ${want}" "L9 [${nm}]: neden iletide: ${want}"
    _unsymlink
    chmod 700 "$ALT" 2>/dev/null; rm -rf "${ALT:?}"/* 2>/dev/null; MOCK_BAD_OWNER=""
}
p_mode() { chmod 755 "$ALT"; }
p_owner() { MOCK_BAD_OWNER="$ALT"; }
p_none() { :; }
p_mktemp_fail() { mktemp() { if [[ "$*" == *".emerg."* ]]; then return 1; fi; command mktemp "$@"; }; }
p_symdir() { rm -rf "$ALT"; mkdir -p "${WEB_ROOT}/altreal"; chmod 700 "${WEB_ROOT}/altreal"; ln -s "${WEB_ROOT}/altreal" "$ALT"; }
p_missing() { rm -rf "$ALT"; }
l9 "mod 755" "mod 755 (700 bekleniyor)" p_mode
l9 "sahip" "sahip/yol zinciri root değil" p_owner
l9 "sembolik bağ" "dizin sembolik bağ" p_symdir
l9 "sondaki '/'" "yol sondaki '/' ile bitiyor" p_none "${ALT}/"
l9 "işaret dosyası yazılamadı" "dizin güvenilir ama işaret dosyası yazılamadı" p_mktemp_fail
unset -f mktemp
rm -rf "$ALT"

echo "── M6/W01-W02-N12: SRVCTL_FM_EMERGENCY_LOCK_WAIT sınırları (geçerli: 1-4 haneli; aksi varsayılan 60 + UYARI) ──"
lw() {   # lw <değer> <beklenen -w> [uyarı beklenir 0|1]
    _fm_reset; _on; : > "$FLOCK_LOG"
    ( SRVCTL_FM_EMERGENCY_LOCK_WAIT="$1" _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1
    assert_eq "$(grep -c -- "-w $2 8" "$FLOCK_LOG")" "1" "LOCK_WAIT='$1' → flock -w $2"
    if [[ "${3:-0}" == "1" ]]; then assert_contains "$(_out)" "SRVCTL_FM_EMERGENCY_LOCK_WAIT='$1' geçersiz" "LOCK_WAIT='$1': geçersiz değer UYARILIR"
    else assert_not_contains "$(_out)" "LOCK_WAIT" "LOCK_WAIT='$1': uyarı YOK"; fi
}
lw 7 7
lw 9999 9999
lw 0 0
lw 99999 60 1
lw 123456789 60 1
lw -5 60 1
lw abc 60 1
lw 12.5 60 1
lw ' 5' 60 1
lw '' 60 0
echo "── M6: SRVCTL_FM_OFF_LOCK_WAIT doğrulaması (aynı kural; çöp flock'a gitmez, yanlış 'kilit alınamadı' YOK) ──"
ow() {   # ow <değer> <beklenen -w> [uyarı]
    _fm_reset; _on; : > "$FLOCK_LOG"
    ( SRVCTL_FM_OFF_LOCK_WAIT="$1" _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; rc=$?
    assert_eq "$(grep -c -- "-w $2 8" "$FLOCK_LOG")|$rc" "1|0" "OFF_LOCK_WAIT='$1' → normal off flock -w $2, rc 0"
    assert_not_contains "$(_out)" "içinde alınamadı" "OFF_LOCK_WAIT='$1': yanlış 'kilit alınamadı' iletisi YOK"
    if [[ "${3:-0}" == "1" ]]; then assert_contains "$(_out)" "SRVCTL_FM_OFF_LOCK_WAIT='$1' geçersiz" "OFF_LOCK_WAIT='$1': geçersiz değer UYARILIR"; fi
}
ow 3 3
ow 0 0
ow abc 10 1
ow -1 10 1
ow 99999 10 1
ow '' 10 0

echo "── L4: status rc — doğrulanamadı (sonda kör) → rc 4 ──"
_fm_reset; _on; fm_sim_reload
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "L4: doğrulanmış AÇIK + kayıt AÇIK → rc 0"
_fm_reset; _on; _e; fm_sim_reload
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "0" "L4: doğrulanmış KAPALI + kayıt KAPALI → rc 0"
for mode in silent unknown; do
    FM_PROBE_MODE="$mode"
    out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
    assert_eq "$rc" "4" "L4: sonda kör (${mode}) + temiz KAPALI disk → rc 4 (rc 0 DEĞİL)"
    assert_contains "$out" "çalışan durum DOĞRULANAMADI" "L4 [${mode}]: 'doğrulanamadı' söylenir"
    assert_contains "$out" "status rc 4" "L4 [${mode}]: rc 4 anlamı iletide"
done
FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=503; FM_PROBE_CODE_HTTP=503
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "4" "L4: askıya alınmış alan (sunucu düzeyi 503, imzasız) → rc 4"
FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; FM_PROBE_BODY_HTTPS=""; FM_PROBE_BODY_HTTP=""
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "4" "L4: sunucu düzeyi imzasız 403 → rc 4 (KAPALI uydurulmaz)"
unset FM_PROBE_BODY_HTTPS FM_PROBE_BODY_HTTP; FM_PROBE_MODE=sim
# AÇIK kayıt + sonda kör → rc 4
_fm_reset; _on; fm_sim_reload; FM_PROBE_MODE=unknown
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "4" "L4: kayıt AÇIK + sonda kör → rc 4"
FM_PROBE_MODE=sim
# çekirdek durum zaten sorun bildiriyorsa (rc 1) o kod korunur; 'FM HÂLÂ AÇIK' rc 1 kalır
_fm_reset; printf 'client_max_body_size 1m;\n' > "$F20"; FM_PROBE_MODE=unknown
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "L4: kayıtsız FM dosyası (çekirdek rc 1) + sonda kör → rc 1 korunur"
FM_PROBE_MODE=sim
# disk KAPALI ama çalışan AÇIK (reload edilemedi): rc 1
_fm_reset; _on; fm_sim_reload
( SYSTEMCTL_RC=1; _domconf_fm_auth example.com off ) >/dev/null 2>&1
out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
assert_eq "$rc" "1" "L4: disk KAPALI + çalışan AÇIK ('FM HÂLÂ AÇIK') → rc 1 (rc 4'e inmez)"

echo "── L5: _domconf_fm_em_state_dir_prepare — ikinci konum dizinini önceden hazırlar ──"
assert_eq "$_DOMCONF_FM_EM_DEFAULT_DIR" "/var/lib/srvctl/fm-emergency" "L5: varsayılan yol SABİTİ /var/lib/srvctl/fm-emergency"
# NOT: assert_* alt kabukta SAYILMAZ (sayaçlar ebeveyne dönmez) → ortam burada kaydedilip geri konur.
SAVE_ENV_DIR="$SRVCTL_FM_EMERGENCY_DIR"; SAVE_DEF_DIR="$_DOMCONF_FM_EM_DEFAULT_DIR"
unset SRVCTL_FM_EMERGENCY_DIR
assert_eq "$(_fmprov_emergency_alt_dir)" "/var/lib/srvctl/fm-emergency" "L5: SRVCTL_FM_EMERGENCY_DIR YOKKEN çözülen yol varsayılan (fm_env yönlendirmesi yok)"
export SRVCTL_FM_EMERGENCY_DIR="$SAVE_ENV_DIR"
# test kancası ("fakeroot"): varsayılan sabit geçici bir kökün altına yönlendirilir; ortam değişkeni ÇÖZÜLMEMİŞ olmalı
{
  FAKE="${WEB_ROOT}/fakeroot/var/lib/srvctl"; _DOMCONF_FM_EM_DEFAULT_DIR="${FAKE}/fm-emergency"
  rm -rf "${WEB_ROOT}/fakeroot"
  unset SRVCTL_FM_EMERGENCY_DIR
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc|$(_mode "${FAKE}/fm-emergency")" "0|700" "L5: varsayılan yol: dizin yoktu → oluşturuldu, mod 0700, rc 0"
  assert_eq "$(_fmprov_emergency_alt_ok; echo $?)" "0" "L5: oluşan dizin 'güvenilir' (root zinciri, 0700, fiziksel yol eşit)"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc|$(_mode "${FAKE}/fm-emergency")" "0|700" "L5: İDEMPOTENT (ikinci çağrı rc 0, mod aynı)"
  chmod 755 "${FAKE}/fm-emergency"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc|$(_mode "${FAKE}/fm-emergency")" "0|700" "L5: gevşek mod (755) 0700'e çekilir"
  # varsayılan yol gerçekten ACİL YOLDA kullanılır
  export SRVCTL_FM_EMERGENCY_DIR="$SAVE_ENV_DIR"
  _fm_reset; _on; _scn_symlink
  unset SRVCTL_FM_EMERGENCY_DIR     # _fm_reset bu değişkeni ister → yalnız acil kapatma süresince kaldırılır
  _e --emergency; rc=$?
  export SRVCTL_FM_EMERGENCY_DIR="$SAVE_ENV_DIR"
  _unsymlink
  assert_eq "$rc|$(_exists "${FAKE}/fm-emergency/example_com.emergency")" "0|var" "L5: kayıt dizini güvenilmezken işaret VARSAYILAN yola yazıldı (env'siz)"
  assert_eq "$(_exists "$AMARK")" "yok" "L5: fm_env'in yönlendirdiği yola YAZILMADI (varsayılan çözülüyor)"
  # taze kurulum: WEB_ROOT henüz YOK → zincir denetimi '/'a kadar yapılır (WEB_ROOT'ta durmaz / WEB_ROOT yok diye RET etmez)
  eval "_f8_orig_arop() $(declare -f assert_root_owned_path | sed 1d)"
  assert_root_owned_path() { echo "$WEB_ROOT" > "${FM_STUBS}/arop.seen"; return 0; }
  rm -rf "${FAKE}/fm-emergency"; SAVE_WR="$WEB_ROOT"
  WEB_ROOT="/nonexistent-webroot-f8"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc|$(cat "${FM_STUBS}/arop.seen" 2>/dev/null)" "0|/" "L5: WEB_ROOT yokken (taze kurulum) güven zinciri '/'a kadar doğrulanır, prepare başarılı"
  WEB_ROOT="$SAVE_WR"; rm -f "${FM_STUBS}/arop.seen"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1
  assert_eq "$(cat "${FM_STUBS}/arop.seen" 2>/dev/null)" "$SAVE_WR" "L5: WEB_ROOT varsa zincir onda durur (davranış değişmedi)"
  assert_root_owned_path() { _f8_orig_arop "$@"; }
  # reddedilen durumlar (ortam yine YOK: varsayılan çözülür)
  unset SRVCTL_FM_EMERGENCY_DIR
  rm -rf "${FAKE}/fm-emergency"; mkdir -p "${WEB_ROOT}/elsewhere"; ln -s "${WEB_ROOT}/elsewhere" "${FAKE}/fm-emergency"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc" "1" "L5: dizin SEMBOLİK BAĞ → reddedilir (rc 1)"
  assert_contains "$(cat "$OUTF")" "sembolik bağ" "L5: neden iletide"
  rm -f "${FAKE}/fm-emergency"; : > "${FAKE}/fm-emergency"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc" "1" "L5: yol bir DOSYA → reddedilir"
  rm -f "${FAKE}/fm-emergency"
  MOCK_BAD_OWNER="${FAKE}/fm-emergency"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc" "1" "L5: sahip root değil → reddedilir (güven doğrulaması)"
  assert_contains "$(cat "$OUTF")" "root:root 0700 yapın" "L5: düzeltme yolu iletide"
  MOCK_BAD_OWNER=""
  _DOMCONF_FM_EM_DEFAULT_DIR="${FAKE}/fm-emergency/"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc" "1" "L5: sondaki '/' → reddedilir"
  _DOMCONF_FM_EM_DEFAULT_DIR="relative/dir"
  _domconf_fm_em_state_dir_prepare >"$OUTF" 2>&1; rc=$?
  assert_eq "$rc" "1" "L5: göreli yol → reddedilir"
}
export SRVCTL_FM_EMERGENCY_DIR="$SAVE_ENV_DIR"; _DOMCONF_FM_EM_DEFAULT_DIR="$SAVE_DEF_DIR"

echo "── L10: düz dosya YABANCI 20, acil yolda ezilmeden önce adli kopyalanır ──"
_fm_reset; _on
printf 'client_max_body_size 1m; # kullanıcı içeriği\n' > "$F20"; chmod 644 "$F20"
cp -p "$F20" "$FM_STUBS/foreign.copy"
_e --emergency; rc=$?
assert_eq "$rc|$(_disk)" "0|yokyokK" "L10: acil kapatma yabancı 20'yi 403 köküyle DEĞİŞTİRDİ (kapatma ertelenmedi)"
assert_eq "$(_fcnt)" "1" "L10: yabancı içeriğin TEK adli kopyası: <ad>.srvctl-foreign.<ts>"
ff=$(find "$CUR_DIR" -maxdepth 1 -name '*.srvctl-foreign.*' | head -1)
assert_eq "$(cat "$ff")" "$(cat "$FM_STUBS/foreign.copy")" "L10: adli kopya yabancı içeriği BAYTI BAYTINA taşır (kullanıcı verisi kaybolmadı)"
assert_eq "$(basename "$ff" | sed 's/\.srvctl-foreign\..*//')" "20-srvctl-fm-upload.conf" "L10: ad = <ad>.srvctl-foreign.<ts>"
assert_eq "$([[ "$ff" == *.conf ]] && echo conf || echo degil)" "degil" "L10: kopya *.conf glob'una UYMAZ (nginx yüklemez)"
assert_contains "$(_out)" "adli kopyalandı" "L10: ileti adli kopyayı söyler"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "adet acil kapatma artığı (*.srvctl-emergency.*)" "L10: status artık sayımı (başlık değişmedi)"
assert_contains "$out" "$(basename "$ff")" "L10: status/aside listesi yabancı kopyayı da gösterir"
# srvctl'in KENDİ AÇIK 20'si (kayıtlı özet) için adli kopya GEREKMEZ
_fm_reset; _on; _e --emergency
assert_eq "$(_fcnt)" "0" "L10: srvctl üretimi AÇIK 20 yabancı sayılmaz → kopya YOK"
# bilinen kapalı kök (eski F4-F6 imzasız) yabancı sayılmaz
_fm_reset; _on
printf '%s\n' '# srvctl: FileManager yükleme yolu KAPALI (srvctl domain fm-auth <alan> off). SRVCTL ÜRETİR.' "# Bu 403 kökü, /_fm/ yolunun CI4'e düşmesini engeller; açmak için: fm-auth <alan> on --script=..." 'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }' > "$F20"
_e --emergency
assert_eq "$(_fcnt)" "0" "L10: eski F4-F6 srvctl kökü yabancı sayılmaz"
# kayıt hiç yok + yabancı 20: kopya alınır (şüphede KAYBETME)
_fm_reset; mkdir -p "$CUR_DIR"; printf 'return 200 "kullanici";\n' > "$F20"
_e --emergency
assert_eq "$(_fcnt)|$(_closed && echo K)" "1|K" "L10: kayıtsız alan + yabancı 20: adli kopya alındı, alan KAPATILDI"
# dizin / sembolik bağ olan 20: eski kenara alma davranışı KORUNUR (yabancı kopya DEĞİL)
_fm_reset; _on; rm -f "$F20"; mkdir -p "$F20"
_e --emergency; rc=$?
assert_eq "$(_fcnt)|$(find "$CUR_DIR" -maxdepth 1 -name '20-srvctl-fm-upload.conf.srvctl-emergency.*' | wc -l | tr -d ' ')|$(_closed && echo K)" "0|1|K" "L10: 20 DİZİN → .srvctl-emergency.* kenara alındı (foreign DEĞİL), alan kapalı"
_fm_reset; _on; mv "$F20" "${F20}.x"; ln -s "${F20}.x" "$F20"
_e --emergency
assert_eq "$(_fcnt)|$(find "$CUR_DIR" -maxdepth 1 -name '20-srvctl-fm-upload.conf.srvctl-emergency.*' | wc -l | tr -d ' ')|$(_closed && echo K)" "0|1|K" "L10: 20 SEMBOLİK BAĞ → .srvctl-emergency.* kenara alındı, alan kapalı"
# aside_list yorumu: 'yabancı 20 içeriği' artık kopyayla KORUNUYOR (yorum doğru)
assert_eq "$(grep -c '= düz dosya olan YABANCI 20 içeriğinin ezilmeden önce alınan adli kopyası' "${REPO_ROOT}/lib/domconf.sh")" "1" "L10: _domconf_fm_aside_list yorumu davranışı doğru anlatır"

echo "── L13/N2: sarkan sembolik bağ olan 90/21 de KAPALI kanıtını bozar ──"
_fm_reset; _on; rm -f "$F90" "$F21"; _domconf_fm_render_off example_com > "$F20"; chmod 644 "$F20"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|2" "N2: pozitif kontrol: 90/21 yokken kanıt var"
ln -s /nonexistent/target "$F90"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "N2: SARKAN bağ olan 90 → kanıt YOK (-L denetimi; F9b: tanınan açık eser de değil → sınıf 4, kapalı sayılır)"
rm -f "$F90"; ln -s /nonexistent/target "$F21"
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "N2: SARKAN bağ olan 21 → kanıt YOK (F9b: sınıf 4)"
rm -f "$F21"

echo "── L13/N4: çok girdili işlemde kapı HER girdinin işaretine bakar ([i], [0] değil) ──"
_fm_reset; _on; _ld() { _fmprov_load example_com; RG="$_FMP_REGION"; SC="$_FMP_SCRIPT"; PH="$_FMP_PHP"; MS="$_FMP_MODSEC"; }; _ld
_domconf_fm_tx_reset
_DOMCONF_FM_TX_ACTION=repair
_domconf_fm_stage example.com example_com on "$RG" "$SC" "$PH" "$MS" >/dev/null 2>&1; r1=$?
_domconf_fm_stage other.com other_com on "$RG" "$SC" "$PH" "$MS" >/dev/null 2>&1; r2=$?
assert_eq "$r1|$r2|${#_FMT_BK[@]}" "0|0|2" "N4: iki girdili işlem sahnelendi"
# yalnız İKİNCİ girdinin alanında işaret
mkdir -p "$SD"; printf 'srvctl-fm-emergency v1\n' > "${SD}/other_com.emergency"
_domconf_fm_tx_commit >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "4" "N4: yalnız 2. girdinin alanında işaret → commit REDDEDİLİR (rc 4)"
assert_contains "$(_out)" "other_com" "N4: ileti işaretli alanı (other_com) söyler"
_domconf_fm_tx_drop_bks; _DOMCONF_FM_TX_ACTION=""; trap - INT TERM HUP
rm -f "${SD}/other_com.emergency" "${SD}/other_com.manifest"; rm -rf "${SRVCTL_NGINX_CUSTOM_DIR}/other_com"

echo "── L13/N6: normal off çağıranın errexit durumunu GERİ YÜKLER ──"
# `case` $(...) içinde bash 3.2'de ayrıştırılamaz → [[ ]] kullanılır; çağrı DOĞRUDAN (alt kabuksuz) yapılır ki bayraklar görünsün.
_fm_reset; _on
fl=$( set -e; _domconf_fm_auth_off_entry example.com example_com "$CUR_DIR" 0 0 0 >/dev/null 2>&1; [[ $- == *e* ]] && echo E || echo noE )
assert_eq "$fl" "E" "N6: set -e AÇIKKEN çağrılan normal off sonrası errexit AÇIK kaldı"
_fm_reset; _on
fl=$( set +e; _domconf_fm_auth_off_entry example.com example_com "$CUR_DIR" 0 0 0 >/dev/null 2>&1; [[ $- == *e* ]] && echo E || echo noE )
assert_eq "$fl" "noE" "N6: errexit KAPALI çağıran için AÇILMAZ"
_fm_reset; _on
fl=$( set -e; _domconf_fm_auth_off_entry example.com example_com "$CUR_DIR" 0 0 1 >/dev/null 2>&1; [[ $- == *e* ]] && echo E || echo noE )
assert_eq "$fl" "E" "N6: --emergency yolunda da errexit durumu korunur"

echo "── L13/N11: acil yol çağıranın INT/TERM/HUP tuzaklarını GERİ KURAR ──"
_fm_reset; _on
tp=$( trap 'echo MYINT' INT; trap 'echo MYTERM' TERM; trap 'echo MYHUP' HUP
      _domconf_fm_auth example.com off --emergency >/dev/null 2>&1
      trap -p INT TERM HUP )
assert_contains "$tp" "MYINT" "N11: INT tuzağı geri kuruldu"
assert_contains "$tp" "MYTERM" "N11: TERM tuzağı geri kuruldu"
assert_contains "$tp" "MYHUP" "N11: HUP tuzağı geri kuruldu"
_fm_reset; _on
tp=$( _domconf_fm_auth example.com off --emergency >/dev/null 2>&1; trap -p INT TERM HUP )
assert_eq "$tp" "" "N11: çağıranın tuzağı yoksa acil yol tuzak BIRAKMAZ"

test_summary; _sum_rc=$?
(( SKIPPED > 0 )) && echo "  Atlanan: ${SKIPPED} (SKIP — yukarıdaki SKIP satırlarına bakın)"
exit "$_sum_rc"
