#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; kancalar (mv/mkdir/_fire) dolaylı çağrılır
# F9e-10 (D) — güvenilmeyen custom.d/<sname> girdisini KENARA ALMA penceresi.
#  (i)   normal 'fm-auth off' yolunda kenara alma sinyal korumalıdır: pencerede (mkdir sonrası / 1. mv sonrası / 2. mv sonrası) gelen
#        HUP/TERM/INT yarım durum bırakmaz — kenara alma TAMAMLANIR (alan KAPALI, 403 kökü yerinde), yetim '<sname>.srvctl-new.*' dizini
#        kalmaz, süreç sinyalin çıkış koduyla (129/143/130) temiz çıkar. (Eski: HUP → rc 129, custom.d/<sname> YOK, yetim .srvctl-new dizini,
#        çalışan nginx AÇIK görüntüde.)
#  (i-b) 2. mv başarısız olursa eski girdi YERİNE GERİ KONUR (sembolik bağ/yabancı dizin olduğu gibi), yetim dizin kalmaz,
#        "FM HÂLÂ AÇIK OLABİLİR" + rc ≠ 0.
#  (ii)  yarıda kalmış kenara alma artıkları (SIGKILL ya da geri koyma da düştüyse) status, nginx-audit (tekil ve --all) ve fm-root kuru
#        çıktısında YETİM olarak raporlanır; temiz durumda rapor YOK.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

TEN="${FM_STUBS}/tenant-owned"
PIDF="${FM_STUBS}/pid"
TINO=""
_stat_owner() {
    if [[ -n "$TINO" && "$(ls -di "$1" 2>/dev/null | awk '{print $1}')" == "$TINO" ]]; then printf 'web_x'; else printf 'root'; fi
}
HOOK_AT=""; KILL_SIG=""; KILL_TARGET=""
_fire() {
    local s="$KILL_SIG"
    HOOK_AT=""; KILL_SIG=""
    # Sinyal, kancanın çalıştığı SÜRECE gider (tuzakları tutan süreç; fm-auth çağrısı kendi çocuk sürecinde çalışır, KILL_TARGET onun
    # atasıdır). Terminal HUP'u zaten tüm süreç grubuna gider; burada kilidi/kenara almayı tutan süreç sınanır.
    if [[ -n "$s" ]]; then _hs_set_me; hs_signal_ancestor "$s" "$HS_ME"; fi
}
# kancalar: yalnız HOOK_AT kuruluyken etkindir; aksi halde gerçek komuta düşer
mkdir() {
    command mkdir "$@"; local rc=$?
    if [[ "$HOOK_AT" == mkdir && "$*" == *".srvctl-new."* ]]; then _fire; fi
    return $rc
}
mv() {
    local src="${*: -2:1}" dst="${*: -1}"
    # *-fail: 2. mv (yeni dizin -> custom.d/example_com) başarısız taklit edilir; *-failall: geri koyma mv'si de düşer
    if [[ "$dst" == "$CUR_DIR" ]]; then
        case "$HOOK_AT" in
            second-fail)    [[ "$src" == *".srvctl-new."* && "$src" != */example_com.srvctl-emergency.* ]] && return 1 ;;
            second-failall) return 1 ;;
        esac
    fi
    command mv "$@"; local rc=$?
    if [[ "$HOOK_AT" == first && "$dst" == *".srvctl-new."*"/example_com.srvctl-emergency."* ]]; then _fire; fi
    if [[ "$HOOK_AT" == second && "$dst" == "$CUR_DIR" && "$src" == *".srvctl-new."* ]]; then _fire; fi
    return $rc
}
turn() {   # sym: sembolik bağ -> kiracı dizini | tenant: gerçek dizin, kiracıya ait (inode ile)
    TINO=""
    case "$1" in
        sym)    rm -rf "$TEN"; command mv "$CUR_DIR" "$TEN"; ln -s "$TEN" "$CUR_DIR"; printf 'kiracının dosyası\n' > "$TEN/tenant-note.txt" ;;
        tenant) TINO=$(ls -di "$CUR_DIR" | awk '{print $1}'); printf 'kiracının dosyası\n' > "$CUR_DIR/tenant-note.txt" ;;
    esac
    fm_sim_reload
}
prep() { rm -rf "${SRVCTL_NGINX_CUSTOM_DIR}"/example_com.srvctl-*; reset_all; _on; fm_sim_reload; turn "$1"; }
snap() {
    local d="$1" f
    [[ -d "$d" ]] || { echo "YOK"; return 0; }
    ( cd "$d" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -f "$f" && ! -L "$f" ]]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s -\n' "$f"; fi
    done )
}
n_new() { find "$SRVCTL_NGINX_CUSTOM_DIR" -maxdepth 1 -name 'example_com.srvctl-new.*' | wc -l | tr -d ' '; }
n_aside() { find "$CUR_DIR" -maxdepth 1 -name 'example_com.srvctl-emergency.*' 2>/dev/null | wc -l | tr -d ' '; }
# _sig_run <HOOK_AT> <SİNYAL|-> : 'fm-auth example.com off'u alt kabukta koşar; kanca kurulan noktada alt kabuğa sinyal gönderir
_sig_run() {
    local at="$1" sig="$2"
    ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); HOOK_AT="$at"; if [[ "$sig" != "-" ]]; then KILL_SIG="$sig"; fi
      _domconf_fm_auth example.com off ) >"$OUTF" 2>&1
}

echo "── (i) pencerede sinyal: kenara alma TAMAMLANIR, yarım durum / yetim dizin yok ──"
# Arka planda başlatılmış bir koşucuda SIGINT başlangıçtan yok sayılabilir (kabuk onu yakalayamaz); o zaman INT hücreleri açıkça ATLANIR.
INT_OK=$( ( _hs_set_me; trap 'printf got' INT; hs_signal_ancestor INT "$HS_ME" ) 2>/dev/null )
SIGS="HUP TERM"
if [[ "$INT_OK" == got ]]; then SIGS="HUP TERM INT"; else echo "  ATLANDI: bu koşucuda SIGINT yok sayılıyor — INT hücreleri koşulmadı"; fi
for kind in sym tenant; do
    for at in mkdir first second; do
        for sig in $SIGS; do
            case "$sig" in HUP) code=129 ;; TERM) code=143 ;; INT) code=130 ;; esac
            tag="${kind}/${at}/${sig}"
            prep "$kind"
            if [[ "$kind" == sym ]]; then watch="$TEN"; else watch=""; fi
            before=""; if [[ -n "$watch" ]]; then before=$(snap "$watch"); fi
            tenant_inode_before="$TINO"
            _sig_run "$at" "$sig"; rc=$?
            out=$(strip < "$OUTF")
            # sinyal alt sürece (kilidi/kenara almayı tutan süreç) gider; üst kabuğun rc'si bu süreç modelinde anlamlı değildir —
            # sinyalin çıkış kodu iletide doğrulanır ve kenara alma sonrası apply_abort yoluyla çıkılır
            assert_contains "$out" "kesinti (sinyal ${code})" "[$tag] kesinti sinyal koduyla (${code}) bildirildi ve temiz çıkıldı"
            assert_eq "$([[ -d "$CUR_DIR" && ! -L "$CUR_DIR" ]] && echo gercek-dizin || echo YOK-ya-da-bag)" "gercek-dizin" "[$tag] custom.d/example_com YERİNDE ve gerçek dizin (pencerede eksik kalmadı)"
            assert_eq "$(n_new)" "0" "[$tag] yetim 'example_com.srvctl-new.*' dizini YOK"
            assert_eq "$(_shut)" "SHUT" "[$tag] 20 = 403 kökü, 90/21 yok (alan KAPALI)"
            assert_eq "$(n_aside)" "1" "[$tag] kenara alınan girdi yeni dizinin içinde (example_com.srvctl-emergency.*)"
            fm_sim_reload
            assert_eq "$(_run)" "RUN-CLOSED" "[$tag] çalışan görüntü KAPALI (reload sonrası)"
            assert_contains "$out" "kenara alma TAMAMLANDI" "[$tag] ileti: kenara alma TAMAMLANDI (sinyal ertelendi)"
            if [[ -n "$watch" ]]; then assert_eq "$(snap "$watch")" "$before" "[$tag] kiracının dizini DEĞİŞMEDİ (yazım 0)"; fi
        done
    done
done

echo "── (i-b) 2. mv düşerse eski girdi geri konur, yetim yok, FM HÂLÂ AÇIK OLABİLİR ──"
for kind in sym tenant; do
    prep "$kind"
    if [[ "$kind" == sym ]]; then before=$(snap "$TEN"); else before=$(snap "$CUR_DIR"); fi
    _sig_run second-fail -; rc=$?
    out=$(strip < "$OUTF")
    tag="geri-koyma/${kind}"
    assert_eq "$([[ "$rc" != 0 ]] && echo sifirdan-farkli || echo "rc=$rc")" "sifirdan-farkli" "[$tag] rc ≠ 0"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "[$tag] ileti: FM HÂLÂ AÇIK OLABİLİR"
    assert_eq "$(n_new)" "0" "[$tag] yetim 'example_com.srvctl-new.*' dizini YOK (hazırlanan dizin kaldırıldı)"
    if [[ "$kind" == sym ]]; then
        assert_eq "$([[ -L "$CUR_DIR" ]] && echo baglanti || echo DEGIL)" "baglanti" "[$tag] eski girdi (sembolik bağ) OLDUĞU GİBİ geri kondu"
        assert_eq "$(snap "$TEN")" "$before" "[$tag] kiracının dizini DEĞİŞMEDİ"
    else
        assert_eq "$(snap "$CUR_DIR")" "$before" "[$tag] eski girdi (yabancı dizin) içeriğiyle OLDUĞU GİBİ geri kondu"
    fi
done

echo "── (ii) yarıda kalmış kenara alma artıkları status / nginx-audit / fm-root kuru çıktısında raporlanır ──"
prep sym
_sig_run second-failall -; rc=$?
out=$(strip < "$OUTF")
assert_contains "$out" "YARIM DURUM" "[yarim] ileti: YARIM DURUM (elle incelenmeli)"
assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "[yarim] ileti: FM HÂLÂ AÇIK OLABİLİR (normal yol başarısız)"
assert_eq "$(n_new)" "1" "[yarim] yetim 'example_com.srvctl-new.*' dizini duruyor (silinmedi)"
# normal yol başarısız olunca acil kapatma yolu, custom.d/example_com YOKKEN yeni dizini kurup 403 kökünü yazar: alan KAPALI kalır
assert_contains "$out" "ACİL KAPATILDI" "[yarim] acil kapatma yolu alanı yine de KAPATTI"
assert_eq "$(_shut)" "SHUT" "[yarim] custom.d/example_com yeniden kuruldu: 20 = 403 kökü, 90/21 yok"
HOOK_AT=""
( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; rc=$?; out=$(strip < "$OUTF")
assert_contains "$out" "YETİM kenara alma dizini" "[yarim/status] YETİM raporlanır"
assert_contains "$out" "srvctl-new" "[yarim/status] yetim dizinin adı anılır"
assert_eq "$([[ "$rc" != 0 ]] && echo sifirdan-farkli || echo "rc=$rc")" "sifirdan-farkli" "[yarim/status] rc ≠ 0"
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; rc=$?; out=$(strip < "$OUTF")
assert_contains "$out" "YETİM kenara alma dizini" "[yarim/audit] YETİM raporlanır"
assert_contains "$out" "srvctl-new" "[yarim/audit] yetim dizinin adı anılır"
assert_eq "$([[ "$rc" != 0 ]] && echo sifirdan-farkli || echo "rc=$rc")" "sifirdan-farkli" "[yarim/audit] rc ≠ 0"
( _domconf_nginx_audit --all ) >"$OUTF" 2>&1; rc=$?; out=$(strip < "$OUTF")
assert_contains "$out" "YETİM kenara alma dizini" "[yarim/audit --all] YETİM raporlanır"
assert_eq "$([[ "$rc" != 0 ]] && echo sifirdan-farkli || echo "rc=$rc")" "sifirdan-farkli" "[yarim/audit --all] rc ≠ 0"
( _domconf_fm_root_cmd example.com ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_contains "$out" "YETİM kenara alma dizini" "[yarim/fm-root kuru] YETİM raporlanır"
( _domconf_fm_root_cmd --all ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_contains "$out" "YETİM kenara alma dizini" "[yarim/fm-root --all kuru] YETİM raporlanır"
assert_eq "$(n_new)" "1" "[yarim] raporlar SALT-OKUR: yetim dizin hâlâ duruyor"

# kardeş '<sname>.srvctl-emergency.*' artığı da raporlanır; temiz durumda rapor YOK
rm -rf "${SRVCTL_NGINX_CUSTOM_DIR}"/example_com.srvctl-*
reset_all; _on; fm_sim_reload
( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_not_contains "$out" "YETİM" "[temiz/status] artık yokken YETİM raporu YOK"
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_not_contains "$out" "YETİM" "[temiz/audit] artık yokken YETİM raporu YOK"
( _domconf_fm_root_cmd --all ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_not_contains "$out" "YETİM" "[temiz/fm-root kuru] artık yokken YETİM raporu YOK"
command mkdir -m 755 "${SRVCTL_NGINX_CUSTOM_DIR}/example_com.srvctl-emergency.4242.777"
( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_contains "$out" "example_com.srvctl-emergency.4242.777" "[kardeş-emergency/status] kardeş '.srvctl-emergency.*' artığı raporlanır"
( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1; out=$(strip < "$OUTF")
assert_contains "$out" "example_com.srvctl-emergency.4242.777" "[kardeş-emergency/audit] kardeş '.srvctl-emergency.*' artığı raporlanır"
test_summary
