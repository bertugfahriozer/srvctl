#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F8/a1 (QL8-H1, QL8-M5) — EŞZAMANLI YAZICI ACİL İŞARETTEN SONRA AÇIK SAHNELEMEZ; geri alma çalışan nginx'i KAPATIR.
#  H1-1  _domconf_fm_stage: kilit altında, diske yazmadan ÖNCE işareti yeniden okur; `on` + açık `fm-auth on` DEĞİL → ret,
#        mevcut (kapalı) diske DOKUNULMAZ (repair / fm-root / fm-root --all / php-switch; kapı B: yedek kopyalama penceresi)
#  H1-2  _domconf_fm_fail_restore: işaretli alanın geri alması diski kapattıktan sonra nginx'i yeniden yükler + sonda yapar;
#        AÇIK/doğrulanamadı → "FM HÂLÂ AÇIK" (rc≠0)
#  H1-3  acil kapatmanın kilit aşaması: kilidi alınca diskte değişiklik olmasa da BİR kez reload + sonda (rev h1heal)
#  H1-4  kilit zaman aşımı iletisi "disk KAPALI" demez: "FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir)"
#  H1-5  C1x-60 (yavaş yazıcı + üçüncü taraf reload) ve q1c-yavaş-stage (fm-root --apply) vakalarının mock karşılığı:
#        sıralama bayrak dosyası/FLOCK_LOG ile senkron (saniye yarışı YOK)
#  M5    _domconf_fm_restore_entry içindeki yeniden kapatma hatası yutulmaz: rc 6 + yarım-işlem yedeği KORUNUR
# Flock taklidi GERÇEK flock gibi bekler: FLOCK_HELD dosyası varken `-w N` N sn bekler, sonra rc 1.
set -uo pipefail
# F9c (§15/38): bu dosyadaki eski "yazıcının işi olsun" tetikleyicisi (90 sil; 20 tanınan) artık kayıtlı parametreyle AÇIK yeniden üretim değil KAPATMA üretir; kapı/geri alma yarışları
# bir 'on' YAZIMI ister → tetikleyici STALE şablon (kayıtlı bölge kayması, üç eser tanınan). Beklentiler DEĞİŞMEDİ.
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
list_all_domains() { printf '%s\n' example.com; }

cat > "${FM_STUBS}/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
w=0
while (( $# )); do case "$1" in -w) w="${2:-0}"; shift ;; esac; shift; done
if [[ "${FLOCK_RC:-0}" != "0" ]]; then exit "$FLOCK_RC"; fi
if [[ -n "${FLOCK_HELD:-}" && -e "$FLOCK_HELD" ]]; then
    t=0
    while [[ -e "$FLOCK_HELD" ]] && (( t < w * 10 )); do sleep 0.1; t=$((t + 1)); done
    if [[ -e "$FLOCK_HELD" ]]; then exit 1; fi
fi
exit 0
FLOCKEOF
chmod +x "${FM_STUBS}/flock"
HELD="${FM_STUBS}/lock.held"; export FLOCK_HELD="$HELD"

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
# kilidi eşzamanlı yazıcı tutuyor: acil kapatma kilit aşamasında zaman aşımına uğrar (rc 4) ve İŞARET YERİNDE KALIR
_e_nolock() { ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_closed() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" && ! -L "$F20" && "$(cat "$F20")" == "$(_domconf_fm_render_off example_com)" ]]; }
_disk() { printf '%s%s%s' "$(_exists "$F90")" "$(_exists "$F21")" "$(_closed && echo K || echo A)"; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_bkn() { find "$SD" -maxdepth 1 -name '.bk.*' 2>/dev/null | wc -l | tr -d ' '; }
_tn() { grep -c '^t$' "$NGINX_T_LOG"; }
_ls20() { ls -A "$CUR_DIR" | tr '\n' ' '; }
_repair() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" "${1:-1}" ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
_phpswitch() { ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; }
_ld() { _fmprov_load example_com; RG="$_FMP_REGION"; SC="$_FMP_SCRIPT"; PH="$_FMP_PHP"; MS="$_FMP_MODSEC"; }
_placemark() { printf 'srvctl-fm-emergency v1\n' > "$MARK"; chmod 600 "$MARK"; }

# sahneleme girişine tek seferlik kanca: "durum ('on') işaretten ÖNCE okundu, sahneleme işaretten SONRA" (QL8-H1 zaman çizelgesi).
# reload'u dosya bayrağıyla başarısız kıl (kancalar $(...) / alt kabukta koşar: DEĞİŞKEN ataması ebeveyne dönmez)
eval "_f8_orig_systemctl() $(declare -f systemctl | sed 1d)"
systemctl() {
    if [[ "${1:-}" == "reload" && -e "${FM_STUBS}/sysfail" ]]; then echo r >> "$RELOAD_LOG"; return 1; fi
    _f8_orig_systemctl "$@"
}
# ilk düz `nginx -t`'yi (yazıcının) başarısız kıl: bayrak DOSYASI (kancalar/$(...) alt kabukta koşar)
eval "_f8_orig_nginx() $(declare -f nginx | sed 1d)"
nginx() {
    if [[ "${1:-}" == "-t" && -z "${2:-}" && -e "${FM_STUBS}/ngxfail1" ]]; then
        rm -f "${FM_STUBS}/ngxfail1"; echo t >> "$NGINX_T_LOG"; echo "nginx: [emerg] mock: ilk nginx -t hatası"; return 1
    fi
    _f8_orig_nginx "$@"
}
# yedek işi sayacı: cp / mktemp çağrıları (kapı A, yedek işinden ÖNCE reddeder; kapı B yedeği alıp sonra siler)
CPLOG="${FM_STUBS}/cp.log"; : > "$CPLOG"
cp() { echo "cp $*" >> "$CPLOG"; command cp "$@"; }
mktemp() { echo "mktemp $*" >> "$CPLOG"; command mktemp "$@"; }
eval "_f8_orig_stage() $(declare -f _domconf_fm_stage | sed 1d)"
F8_PRE=""
_domconf_fm_stage() {
    if [[ -n "$F8_PRE" && ! -e "${FM_STUBS}/pre.done" ]]; then : > "${FM_STUBS}/pre.done"; "$F8_PRE"; fi
    _f8_orig_stage "$@"
}
# eşzamanlı acil kapatma: kilidi tutan yazıcı yüzünden kilit aşaması zaman aşımına uğrar (rc 4); diski kapatır, nginx'i yükler, işaret koyar
_pre_emergency() {
    ( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/pre.em.out" 2>&1
    echo "$?" > "${FM_STUBS}/pre.em.rc"
}
_pre_reset() { rm -f "${FM_STUBS}/pre.done" "${FM_STUBS}/pre.em.rc" "${FM_STUBS}/pre.em.out"; F8_PRE=""; }

echo "── H1-1: sahneleme kapısı — işaretten sonra sahneleyen yazıcı AÇIK yazmaz ──"
# doğrudan: acil kapatma BİTMİŞ, yazıcı ÖNCEDEN okuduğu 'on' ile sahneliyor (repair eylemi)
_pre_reset; _fm_reset; _on; fm_sim_reload; _ld
_e_nolock; erc=$?
assert_eq "$erc|$(_disk)|$(_run)|$(_exists "$MARK")" "4|yokyokK|RUN-CLOSED|var" "H1-1: ön koşul: acil kapatma (kilit yazıcıda) rc 4: disk ve çalışan KAPALI, işaret yerinde"
m20=$(_md5 "$F20"); mman=$(_md5 "$MAN"); l0=$(_ls20); t0=$(_tn); r0=$(_reloads)
: > "$CPLOG"
_DOMCONF_FM_TX_ACTION=repair
( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
assert_eq "$wrc" "4" "H1-1: işaret varken 'on' sahnelemesi REDDEDİLİR (rc 4)"
assert_contains "$(_out)" "SAHNELENMEDİ" "H1-1: ileti: sahnelenmedi, kapalı diske dokunulmadı"
assert_eq "$(_disk)" "yokyokK" "H1-1: disk KAPALI kaldı (90/21 yok, 20 = 403 kökü) — F7: varvar (AÇIK sahnelendi)"
assert_eq "$(_md5 "$F20")|$(_md5 "$MAN")|$(_ls20)" "${m20}|${mman}|${l0}" "H1-1: 20, kayıt ve dizin içeriği BAYTI BAYTINA aynı (mevcut diske dokunulmadı)"
assert_eq "$(_bkn)" "0" "H1-1: yedek dizini bırakılmadı (hiçbir şey yazılmadan reddedildi)"
assert_eq "$(grep -c . "$CPLOG")" "0" "H1-1: reddi YEDEK İŞİNDEN ÖNCE (kapı A): cp / mktemp çağrısı 0 (kapı yalnız B olsaydı yedek alınıp silinirdi)"
assert_eq "$(( $(_tn) - t0 )),$(( $(_reloads) - r0 ))" "0,0" "H1-1: yazıcı nginx -t / reload ÇALIŞTIRMADI (reddi yazımdan ÖNCE)"
assert_eq "$(_exists "$MARK")" "var" "H1-1: işaret yerinde"
# açık 'fm-auth on' kapıdan geçer (kapı yalnız örtük/geniş eylemleri durdurur)
_DOMCONF_FM_TX_ACTION=on
( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
assert_eq "$wrc|$(_disk)|$(_run)" "0|varvarA|RUN-OPEN" "H1-1: açık 'fm-auth on' eylemi kapıdan geçer ve alanı AÇAR (tek yol)"
# 'off' sahnelemesi kapıya takılmaz
_fm_reset; _on; _ld; _placemark
_DOMCONF_FM_TX_ACTION=repair
( _domconf_fm_apply example.com example_com off "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
assert_eq "$wrc|$(_disk)" "0|yokyokK" "H1-1: işaret varken 'off' sahnelemesi kapıya takılmaz (kapatma yönü)"

echo "── H1-1b: dört yazıcı yolu (repair / fm-root / fm-root --all / php-switch) — acil kapatma stage girişinde araya girer ──"
for how in repair fmroot fmroot_all phpswitch; do
    _pre_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"   # yazıcının yapacak işi olsun (STALE şablon; F9c §15/38: eski tetikleyici '90 EKSİK' artık alanı KAPATIR)
    F8_PRE=_pre_emergency
    t0=$(_tn)
    case "$how" in
        repair) _repair; wrc=$? ;;
        fmroot) _fmroot; wrc=$? ;;
        fmroot_all) _fmroot_all; wrc=$? ;;
        phpswitch) _phpswitch; wrc=$? ;;
    esac
    F8_PRE=""
    assert_eq "$(cat "${FM_STUBS}/pre.em.rc" 2>/dev/null)" "4" "H1-1b [${how}]: ön koşul: eşzamanlı acil kapatma koştu (kilit zaman aşımı → rc 4)"
    assert_eq "$(_disk)|$(_run)|$(_exists "$MARK")" "yokyokK|RUN-CLOSED|var" "H1-1b [${how}]: yazıcı AÇIK sahnelemedi: disk ve çalışan KAPALI, işaret yerinde (F7: varvarA)"
    assert_eq "$(( wrc != 0 ))" "1" "H1-1b [${how}]: yazıcı rc≠0 (rc ${wrc}) — işlem yapılamadı"
    assert_eq "$(_bkn)" "0" "H1-1b [${how}]: yedek dizini kalmadı"
    assert_eq "$(( $(_tn) - t0 ))" "1" "H1-1b [${how}]: nginx -t yalnız acilin kendisi (1); yazıcı nginx -t'ye hiç ulaşmadı (açık yapılandırmayı doğrulatmadı)"
done

echo "── H1-1c: kapı B — yedek kopyalama penceresinde konan işaret (yazılmadan ve girdi eklenmeden ret) ──"
_pre_reset; _fm_reset; _on; fm_sim_reload; _ld
m20=$(_md5 "$F20"); mman=$(_md5 "$MAN"); l0=$(_ls20)
cp() {
    echo "cp $*" >> "$CPLOG"
    if [[ "${*: -1}" == */manifest && ! -e "${FM_STUBS}/b.done" ]]; then : > "${FM_STUBS}/b.done"; _placemark; fi
    command cp "$@"
}
_domconf_fm_tx_reset
_DOMCONF_FM_TX_ACTION=repair
_domconf_fm_stage example.com example_com on "$RG" "$SC" "$PH" "$MS" >"$OUTF" 2>&1; wrc=$?
_DOMCONF_FM_TX_ACTION=""
cp() { echo "cp $*" >> "$CPLOG"; command cp "$@"; }
assert_eq "$wrc" "4" "H1-1c: yedek kopyalanırken işaret kondu → sahneleme rc 4"
assert_eq "$(_bkn)|${#_FMT_BK[@]}" "0|0" "H1-1c: yedek dizini silindi ve işleme girdi EKLENMEDİ (geri yüklenecek bir şey yok)"
assert_eq "$(_md5 "$F20")|$(_md5 "$MAN")|$(_ls20)" "${m20}|${mman}|${l0}" "H1-1c: diske / kayda DOKUNULMADI"
assert_eq "$(trap -p INT TERM HUP)" "" "H1-1c: sinyal tuzağı kurulmadı (ret yazımdan ÖNCE)"

echo "── H1-2: geri alma sonrası nginx yeniden yüklenir ve sonda yapılır ──"
# yazıcı sahneledi (işaret yoktu); nginx -t sırasında işaret konuyor ve üçüncü bir reload yazıcının AÇIK diskini yüklüyor (QL8 C1x-60 mekanizması)
_h2() {
    if [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]]; then : > "${FM_STUBS}/hk"; _placemark; fm_sim_reload; fi
}
_pre_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk"
NGINX_T_HOOK=_h2; r0=$(_reloads)
_repair; wrc=$?
NGINX_T_HOOK=""
assert_eq "$wrc" "1" "H1-2: repair 'on' kaydı yazamadı (commit kapısı rc 4 → geri alma)"
assert_eq "$(_disk)" "yokyokK" "H1-2: geri alma diski yeniden KAPATTI"
assert_eq "$(_run)" "RUN-CLOSED" "H1-2: ÇALIŞAN nginx KAPALI — geri alma sonrası reload üçüncü tarafın yüklediği AÇIK yapılandırmayı düzeltti (F7: RUN-OPEN)"
assert_eq "$(( $(_reloads) - r0 ))" "1" "H1-2: tam BİR geri-alma reload'u"
assert_contains "$(_out)" "geri alma alanı yeniden KAPATTI" "H1-2: ileti: yeniden kapatıldı, çalışan durum KAPALI imzası"
# reload başarısız: çalışan AÇIK kalır → dürüst "FM HÂLÂ AÇIK", rc≠0
_h2b() {
    if [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]]; then : > "${FM_STUBS}/hk"; _placemark; fm_sim_reload; : > "${FM_STUBS}/sysfail"; fi
}
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk" "${FM_STUBS}/sysfail"
NGINX_T_HOOK=_h2b
_repair; wrc=$?
NGINX_T_HOOK=""; rm -f "${FM_STUBS}/sysfail"
assert_eq "$wrc|$(_disk)|$(_run)" "1|yokyokK|RUN-OPEN" "H1-2b: reload başarısız: disk KAPALI ama çalışan AÇIK, rc≠0"
assert_contains "$(_out)" "FM HÂLÂ AÇIK — geri alma sonrası example.com" "H1-2b: 'FM HÂLÂ AÇIK' söylenir (sessiz değil)"
assert_contains "$(_out)" "reload: failed" "H1-2b: reload durumu iletide"
# sonda kör: doğrulanamadı KAPALI sayılmaz
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk"
NGINX_T_HOOK=_h2; FM_PROBE_MODE=silent
_repair; wrc=$?
NGINX_T_HOOK=""; FM_PROBE_MODE=sim
assert_eq "$wrc" "1" "H1-2c: rc≠0"
assert_contains "$(_out)" "geri alma sonrası example.com: çalışan durum DOĞRULANAMADI" "H1-2c: sonda kör → 'doğrulanamadı'"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "H1-2c: 'FM HÂLÂ AÇIK OLABİLİR' (KAPALI uydurulmaz)"
# işaretsiz alanın geri alması DEĞİŞMEZ: ek reload yok
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk"
: > "${FM_STUBS}/ngxfail1"; r0=$(_reloads)
_repair; wrc=$?
rm -f "${FM_STUBS}/ngxfail1"
assert_eq "$wrc|$(( $(_reloads) - r0 ))" "1|0" "H1-2d: işaretsiz alanın nginx -t hatası (rc 3) geri almasında reload YOK (davranış değişmedi; ilk -t gerçekten düştü)"
assert_contains "$(_out)" "mock: ilk nginx -t hatası" "H1-2d: kontrol: yazıcının nginx -t hatası dalı GERÇEKTEN koştu (çıktı iletide)"

echo "── M5: yeniden kapatma hatası YUTULMAZ — rc 6 + yarım-işlem yedeği KORUNUR ──"
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk"
eval "_f8_orig_close() $(declare -f _domconf_fm_em_close_disk | sed 1d)"
_domconf_fm_em_close_disk() { _FME_DISK=failed; _FME_REMAIN="taklit: kapatılamadı"; return 1; }
_apply_on() { ( _domconf_fm_apply example.com example_com on "$RG" "$SC" "$PH" "$MS" 1 ) >"$OUTF" 2>&1; }
_ld; NGINX_T_HOOK=_h2; r0=$(_reloads)
_DOMCONF_FM_TX_ACTION=repair; _apply_on; wrc=$?; _DOMCONF_FM_TX_ACTION=""
NGINX_T_HOOK=""
assert_eq "$wrc" "6" "M5: geri alma sırasında yeniden kapatma BAŞARISIZ → rc 6 ('geri alındı' DENMEZ)"
assert_eq "$(_bkn)" "1" "M5: yarım-işlem yedeği diskte KORUNDU (silinmedi)"
assert_eq "$(( $(_reloads) - r0 ))" "0" "M5: geri alma başarısızken nginx YENİDEN YÜKLENMEZ (yarım diski yüklememek için)"
assert_contains "$(_out)" "FM HÂLÂ AÇIK" "M5: yine de çalışan durum söylenir (AÇIK imzası)"
# aynı mantık apply_check'in iletisi: 'GERİ ALMA BAŞARISIZ'
( _domconf_fm_apply_check 6 on ) >"$OUTF" 2>&1
assert_contains "$(_out)" "GERİ ALMA BAŞARISIZ" "M5: rc 6 iletisi 'GERİ ALMA BAŞARISIZ'"
_domconf_fm_em_close_disk() { _f8_orig_close "$@"; }
# kontrol: gerçek yeniden kapatma çalışınca rc 4 ve yedek silinir
_fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk"
_ld; NGINX_T_HOOK=_h2
_DOMCONF_FM_TX_ACTION=repair; _apply_on; wrc=$?; _DOMCONF_FM_TX_ACTION=""
NGINX_T_HOOK=""
assert_eq "$wrc|$(_bkn)|$(_disk)" "4|0|yokyokK" "M5 kontrol: yeniden kapatma çalışınca rc 4, yedek silindi, disk KAPALI"

# 0555 dizin: geri yükleme VE yeniden kapatma yazılamaz → gerçek (taklitsiz) em_close_disk hatası da rc 6 + yedek KORUNUR
if [[ "$(id -u)" != "0" ]]; then
    _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; rm -f "${FM_STUBS}/hk"
    _h5() { if [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/hk" ]]; then : > "${FM_STUBS}/hk"; _placemark; chmod 0555 "$CUR_DIR"; fi; }
    _ld; NGINX_T_HOOK=_h5
    _DOMCONF_FM_TX_ACTION=repair; _apply_on; wrc=$?; _DOMCONF_FM_TX_ACTION=""
    NGINX_T_HOOK=""; chmod 0755 "$CUR_DIR"
    assert_eq "$wrc|$(_bkn)" "6|1" "M5 (0555 dizin): geri alma/yeniden kapatma yazılamıyor → rc 6, yarım-işlem yedeği KORUNDU"
else
    echo "  (root: chmod 0555 etkisiz — M5 0555 vakası ATLANDI)"
fi

echo "── H1-3: kilit aşamasında değişiklik YOKSA da bir kez reload + sonda (rev h1heal) ──"
# acilin İLK reload'u sırasında disk geçici AÇIK (yazıcının geri alma penceresi) → reload AÇIK yapılandırmayı yükler;
# yazıcı kilidi bırakmadan hemen önce diski yeniden kapatır → kilit aşamasında _FME_CHANGED=0 (F7: reload YOK → AÇIK kalır).
_fm_reset; _on; fm_sim_reload
cp -p "$F90" "$FM_STUBS/o90"; cp -p "$F21" "$FM_STUBS/o21"; cp -p "$F20" "$FM_STUBS/o20"
_domconf_fm_render_off example_com > "$FM_STUBS/c20"
_h3() { if [[ ! -e "$FM_STUBS/hk3" ]]; then : > "$FM_STUBS/hk3"; cp -p "$FM_STUBS/o90" "$F90"; cp -p "$FM_STUBS/o21" "$F21"; cp -p "$FM_STUBS/o20" "$F20"; fi; }
NGINX_T_HOOK=_h3
cat > "$FM_STUBS/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
# yazıcı kilidi bırakmadan hemen önce geri almayı bitirdi: disk kapalı
if [[ ! -e "$FM_STUBS/fl3" ]]; then : > "$FM_STUBS/fl3"; rm -f "$F90" "$F21"; cp -p "$FM_STUBS/c20" "$F20"; fi
exit 0
FLOCKEOF
chmod +x "$FM_STUBS/flock"; export FM_STUBS F90 F21 F20
: > "$FLOCK_LOG"; r0=$(_reloads)
_e --emergency; rc=$?
NGINX_T_HOOK=""
assert_eq "$rc" "0" "H1-3: acil kapatma rc 0 — çalışan durum sonda ile KAPALI doğrulandı (F7: rc 3 'FM HÂLÂ AÇIK')"
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "H1-3: disk KAPALI, çalışan KAPALI"
assert_eq "$(( $(_reloads) - r0 ))" "2" "H1-3: iki reload: ilk aşama + kilit aşaması (değişiklik olmasa da)"
assert_contains "$(_out)" "kilit altında disk zaten KAPALI (değişiklik yok)" "H1-3: ileti"
# flock taklidini geri koy
cat > "${FM_STUBS}/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
w=0
while (( $# )); do case "$1" in -w) w="${2:-0}"; shift ;; esac; shift; done
if [[ "${FLOCK_RC:-0}" != "0" ]]; then exit "$FLOCK_RC"; fi
if [[ -n "${FLOCK_HELD:-}" && -e "$FLOCK_HELD" ]]; then
    t=0
    while [[ -e "$FLOCK_HELD" ]] && (( t < w * 10 )); do sleep 0.1; t=$((t + 1)); done
    if [[ -e "$FLOCK_HELD" ]]; then exit 1; fi
fi
exit 0
FLOCKEOF
chmod +x "${FM_STUBS}/flock"

echo "── H1-4: kilit zaman aşımı iletisi 'disk KAPALI' DEMEZ ──"
_fm_reset; _on; fm_sim_reload
( FLOCK_RC=1; _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "4" "H1-4: kilit alınamadı → rc 4"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir)" "H1-4: 'FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir)'"
assert_contains "$(_out)" "kayıt eşitlenmedi; yazıcı diski yeniden açmış olabilir (FM HÂLÂ AÇIK OLABİLİR)" "H1-4: ilk satır da 'yazıcı diski yeniden açmış olabilir' der"
assert_contains "$(_out)" "yazıcı bitince 'srvctl domain fm-auth example.com off'" "H1-4: çıkış yolu: yazıcı bitince off"
assert_not_contains "$(_out)" "disk KAPALI," "H1-4: 'disk KAPALI' iddiası YOK (eski ileti)"
assert_not_contains "$(_out)" "ACİL KAPATMA TAMAMLANDI" "H1-4: 'TAMAMLANDI' denmez"

echo "── H1-5: C1x-60 mock — yavaş yazıcı + üçüncü taraf reload; senkron bayrak/FLOCK_LOG, saniye yarışı YOK ──"
# Yazıcı (repair) durumu 'on' diye okudu; ACİL KAPATMA onun stage girişinde araya giriyor ve kilidi tutan yazıcıyı BEKLİYOR
# (flock taklidi HELD varken gerçekten bekler; bekleme üst sınırı 1 sn); bekleme dolunca rc 4. Yazıcı sonra sahnelemeye devam eder.
_pre_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
_pre_emergency_wait() {
    : > "$HELD"; : > "$FLOCK_LOG"
    ( SRVCTL_FM_EMERGENCY_LOCK_WAIT=1 _domconf_fm_auth example.com off --emergency ) > "${FM_STUBS}/pre.em.out" 2>&1
    echo "$?" > "${FM_STUBS}/pre.em.rc"
}
F8_PRE=_pre_emergency_wait
# üçüncü taraf reload (certbot kancası): yazıcının nginx -t penceresinde çalışan nginx'e diskin O ANKİ halini yükletir
_third() { if [[ "$NGINX_T_ARGS" == "-t" ]]; then fm_sim_reload; fi; }
NGINX_T_HOOK=_third
_repair; wrc=$?
NGINX_T_HOOK=""; F8_PRE=""
rm -f "$HELD"
assert_eq "$(cat "${FM_STUBS}/pre.em.rc")" "4" "C1x-60: acil kapatma bekleme süresi dolunca rc 4 (kilidi yazıcı tutuyor)"
assert_eq "$(grep -c -- '-w 1 8' "$FLOCK_LOG")" "1" "C1x-60: kilit aşaması flock -w 1 ile bekledi (senkron: FLOCK_LOG)"
assert_contains "$(cat "${FM_STUBS}/pre.em.out")" "FM HÂLÂ AÇIK OLABİLİR (eşzamanlı yazıcı diski yeniden açmış olabilir)" "C1x-60: acil rc 4 iletisi dürüst (disk KAPALI demez)"
assert_eq "$(_disk)|$(_run)|$(_exists "$MARK")" "yokyokK|RUN-CLOSED|var" "C1x-60: nihai durum KAPALI (disk ve çalışan), işaret yerinde — SESSİZ-AÇIK DEĞİL"
assert_eq "$(( wrc != 0 ))" "1" "C1x-60: yazıcı rc≠0"
# yazıcı bitti: acil kapatma yeniden koşunca (kilit boş) kapanışı doğrular, kaydı eşitler
( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(_run)|$(_st)|$(_exists "$MARK")" "0|RUN-CLOSED|off|yok" "C1x-60: yazıcı bitince 'off' kapanışı doğrular (rc 0), kayıt 'off', işaret kalktı"

echo "── H1-5b: q1c-yavaş-stage — fm-root --apply, stage girişinde acil kapatma ──"
_pre_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
F8_PRE=_pre_emergency
_fmroot; wrc=$?
F8_PRE=""
assert_eq "$(cat "${FM_STUBS}/pre.em.rc")" "4" "q1c-yavaş-stage: acil kapatma rc 4"
assert_eq "$(_disk)|$(_run)|$(_exists "$MARK")" "yokyokK|RUN-CLOSED|var" "q1c-yavaş-stage: fm-root --apply AÇIK sahnelemedi: disk/çalışan KAPALI, işaret yerinde"
_fmroot; wrc=$?
assert_eq "$wrc|$(_disk)|$(_st)|$(_run)" "0|yokyokK|off|RUN-CLOSED" "q1c-yavaş-stage: sonraki düz fm-root --apply alanı AÇMAZ; kaydı 'off'a eşitler"
_pre_reset

echo "── H1-6: SİNYAL İPTALİ (INT/TERM/HUP) kapı reddiyle AYNI sözleşme — kapat → reload → settled sonda; AÇIK/doğrulanamadı → FM HÂLÂ AÇIK ──"
# Sinyal, yazıcının CANLI `nginx -t` penceresinde (stage açık yazmış, kayıt aşama 1) YAZICININ KENDİNE gönderilir; aynı pencerede üçüncü
# bir reload (certbot kancası) çalışan nginx'e diskin O ANKİ (AÇIK) halini yüklüyor. Senkron: kanca bayrak dosyası, sleep YOK
# (kill dönmeden sinyal bekleyen kabuğa kuyruklanır; trap, bekleyen `$(nginx -t)` bitince koşar).
PIDF6="${FM_STUBS}/h6.pid"
# $1 = sinyal; kalan = çalıştırılacak komut. Alt kabuk KENDİ PID'ine sinyal alır (PPID hilesi, test_domconf_fm_auth.sh bölüm J ile aynı).
_sig_run() {
    local sig="$1"; shift
    ( sh -c 'echo $PPID > "$0"' "$PIDF6"; KILL_TARGET=$(cat "$PIDF6"); KILL_SIG="$sig"; "$@" ) >"$OUTF" 2>&1
}
# kanca: ilk canlı nginx -t'de (1) isteğe bağlı işaret (2) üçüncü taraf reload (3) isteğe bağlı reload bozma (4) sinyal
_h6() {
    [[ "$NGINX_T_ARGS" == "-t" && ! -e "${FM_STUBS}/h6.done" ]] || return 0
    : > "${FM_STUBS}/h6.done"
    [[ -e "${FM_STUBS}/h6.mark" ]] && _placemark
    fm_sim_reload
    [[ -e "${FM_STUBS}/h6.sysfail" ]] && : > "${FM_STUBS}/sysfail"
    kill "-${KILL_SIG}" "$KILL_TARGET"
}
_h6_reset() { rm -f "${FM_STUBS}/h6.done" "${FM_STUBS}/h6.mark" "${FM_STUBS}/h6.sysfail" "${FM_STUBS}/sysfail" "$MARK"; NGINX_T_HOOK=""; }
_h6_repair() { _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 1; }
_h6_on()     { _domconf_fm_auth example.com on "--script=${SCRIPT}"; }

# (a) işaret VAR + üçüncü taraf reload; her üç sinyal
for pair in INT:130 TERM:143 HUP:129; do
    SIG="${pair%%:*}"; want="${pair##*:}"
    _h6_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/h6.mark"
    NGINX_T_HOOK=_h6; r0=$(_reloads)
    _sig_run "$SIG" _h6_repair; wrc=$?
    NGINX_T_HOOK=""
    assert_eq "$wrc" "$want" "H1-6a [${SIG}]: sinyal koduyla çıkıldı (${want}, 0 DEĞİL)"
    assert_eq "$(_disk)|$(_run)|$(_exists "$MARK")|$(_bkn)" "yokyokK|RUN-CLOSED|var|0" "H1-6a [${SIG}]: disk KAPALI, ÇALIŞAN nginx KAPALI (F8-a1: RUN-OPEN), işaret yerinde, yedek temiz"
    assert_eq "$(( $(_reloads) - r0 ))" "1" "H1-6a [${SIG}]: tam BİR systemctl reload = iptalin geri-alma reload'u (üçüncü taraf fm_sim_reload ile systemctl'e uğramaz)"
    assert_contains "$(_out)" "sinyal kesintisi geri alması alanı yeniden KAPATTI" "H1-6a [${SIG}]: ileti: iptal yolu yeniden kapattı ve çalışan durumu KAPALI imzasıyla doğruladı"
done
# (b) işaret YOK ama stage AÇIK yazdı (fm-auth on, önceki durum KAPALI) + üçüncü taraf reload
_h6_reset; _fm_reset; _on; fm_sim_reload; ( _domconf_fm_auth example.com off ) >/dev/null 2>&1
assert_eq "$(_disk)|$(_run)" "yokyokK|RUN-CLOSED" "H1-6b: ön koşul: alan KAPALI (normal off)"
NGINX_T_HOOK=_h6; r0=$(_reloads)
_sig_run TERM _h6_on; wrc=$?
NGINX_T_HOOK=""
assert_eq "$wrc|$(_disk)|$(_run)|$(_bkn)" "143|yokyokK|RUN-CLOSED|0" "H1-6b: işaretsiz ama stage AÇIK yazmıştı: iptal diski kapattı, ÇALIŞAN nginx KAPALI"
assert_eq "$(( $(_reloads) - r0 ))" "1" "H1-6b: iptal geri-alma reload'u (systemctl) yapıldı"
# (c) reload BAŞARISIZ → dürüst "FM HÂLÂ AÇIK", çıkış kodu sinyal kodu
_h6_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/h6.mark"; : > "${FM_STUBS}/h6.sysfail"
NGINX_T_HOOK=_h6
_sig_run TERM _h6_repair; wrc=$?
NGINX_T_HOOK=""; rm -f "${FM_STUBS}/sysfail"
assert_eq "$wrc|$(_disk)|$(_run)" "143|yokyokK|RUN-OPEN" "H1-6c: reload bozuk: disk KAPALI ama ÇALIŞAN AÇIK, rc≠0"
assert_contains "$(_out)" "FM HÂLÂ AÇIK — sinyal kesintisi geri alması sonrası example.com" "H1-6c: 'FM HÂLÂ AÇIK' söylenir (sessiz-AÇIK değil)"
assert_contains "$(_out)" "reload: failed" "H1-6c: reload durumu iletide"
# (d) sonda kör → 'doğrulanamadı' KAPALI sayılmaz
_h6_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/h6.mark"
NGINX_T_HOOK=_h6; FM_PROBE_MODE=silent
_sig_run INT _h6_repair; wrc=$?
NGINX_T_HOOK=""; FM_PROBE_MODE=sim
assert_eq "$wrc" "130" "H1-6d: INT → 130"
assert_contains "$(_out)" "sinyal kesintisi geri alması sonrası example.com: çalışan durum DOĞRULANAMADI" "H1-6d: sonda kör → 'doğrulanamadı'"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "H1-6d: 'FM HÂLÂ AÇIK OLABİLİR' (KAPALI uydurulmaz)"
# (e) geri alma BAŞARISIZ: yedek KORUNUR, reload YOK (yarım diski yüklememek için), yine de çalışan durum söylenir
_h6_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/h6.mark"
eval "_h6_orig_rfb() $(declare -f _domconf_fm_restore_from_bk | sed 1d)"
_domconf_fm_restore_from_bk() { return 1; }
NGINX_T_HOOK=_h6; r0=$(_reloads)
_sig_run TERM _h6_repair; wrc=$?
NGINX_T_HOOK=""
_domconf_fm_restore_from_bk() { _h6_orig_rfb "$@"; }
assert_eq "$wrc|$(_bkn)|$(( $(_reloads) - r0 ))" "143|1|0" "H1-6e: geri alma başarısız: yedek KORUNDU, iptal reload YAPMADI (yarım diski yüklememek için)"
assert_contains "$(_out)" "yedek diskte korunuyor" "H1-6e: dürüst ileti"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR — sinyal kesintisi geri alması sonrası example.com" "H1-6e: çalışan durum yine söylenir (F9: geri alma yürütülemedi → diskte kapalı-kök kanıtı yok → 'OLABİLİR')"
assert_contains "$(_out)" "diskte KAPALI KÖK KANITI YOK" "H1-6e: neden: kapalı-disk kanıtı yok (yalnız 'disk yeniden KAPATILDI' denmez)"
find "$SD" -maxdepth 1 -name '.bk.*' -exec rm -rf {} + 2>/dev/null
# (f) GEREKSİZ reload yok: işaretsiz + zaten AÇIK alanın onarımı (yedekte 90 var) iptali
_h6_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
NGINX_T_HOOK=_h6; r0=$(_reloads)
_sig_run TERM _h6_repair; wrc=$?
NGINX_T_HOOK=""
assert_eq "$wrc|$(_bkn)|$(( $(_reloads) - r0 ))" "143|0|0" "H1-6f: iptal 143, yedek temiz; iptal GEREKSİZ reload yapmadı (işaretsiz + zaten açık alan)"
assert_not_contains "$(_out)" "KAPATTI" "H1-6f: 'yeniden KAPATTI' iletisi yok"
# (g) sinyalsiz kontrol: bayraklar aynı, kanca sinyal göndermiyor → repair marker'a takılır (kapı), iptal yolu devreye GİRMEZ
_h6_reset; _fm_reset; _on; fm_sim_reload; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; : > "${FM_STUBS}/h6.mark"
KILL_SIG=0; KILL_TARGET=$$
NGINX_T_HOOK=_h6
_h6_repair >"$OUTF" 2>&1; wrc=$?
NGINX_T_HOOK=""
assert_not_contains "$(_out)" "sinyal kesintisi" "H1-6g: sinyalsiz koşuda iptal ileti yolu çalışmaz (kontrol)"
_h6_reset

test_summary
