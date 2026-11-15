#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9b/a1 — §15/33 "OTOMATİK YOLLAR ASLA AÇMAZ" ilkesi (mock; bu ilkeye özgü gerçek-nginx dosyası YOK — gerçek nginx kapsamı test_domconf_fm_f9_real.sh ve test_domconf_fm_probe_real.sh'ta; burada davranış mock'ta, kapalı yön), parça 7/7: H yarıda kesilen yazıcı (INT/TERM, gerçek sinyal) + I bayat yedek + J ipucu metinleri
# Eski tek dosya (373 satır, 392 doğrulama, yüklü makinede dosya başı süre sınırının ~%95'i) 7 bağımsız dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f9b_never_opens_common.sh. Parçalar: (ad yok) A sınıf 1-4, _2 A sınıf 5-8, _3 A sınıf 9-11, _4 A sınıf 12-14, _5 B+G, _6 C+D+E+F, _7 H+I+J.
# İlke: kayıt `on` + diskteki 20-srvctl-fm-upload.conf TANINAN bir srvctl AÇIK eseri DEĞİLSE (eksik, yapısal sahte kök, bozuk imza,
# bilinmeyen içerik, boş, sembolik bağ, kurcalanmış açık şablon, yabancı sahip/mod, yabancı imza, 90/21'li kapalı kök) hiçbir otomatik yol
# (fm-root, fm-root --all [self-update geçişi], repair [PHP kayması dahil], toplu repair, php-switch soket güncellemesi, provision, yarım-işlem
# kurtarması) AÇIK yapılandırma üretmez: 403 kökü yazılır, 90/21 kaldırılır, kayıt `off`, `status` TAMPERED der ve yalnız AÇIK 'fm-auth on'u önerir.
# F9c (§15/38): "tanınan açık eser" = 20 VE 21 VE 90 (üçü); bkz. tests/test_domconf_fm_f9c_all_three_{a..f}.sh (ortak düzenek tests/fm_f9c_common.sh).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9b_never_opens_common.sh"
# ═══ H. F9b/a3 BLOKER-1: yazıcı yarıda kesilir, ön durum = kayıt `on` + diskte kayıtsız AÇIK sahte kök → geri alma o AÇIK kökü diske GERİ KOYMAZ ═══
#   (qalab9 A1B-O: f_openup / f_proxy × repair84 / fm-root × INT / TERM; öncesi: 130/143, hiç ileti yok, reload yok, disk AÇIK / çalışan KAPALI-iletisiz)
PIDF="${FM_STUBS}/pid"; CNT="${FM_STUBS}/cnt"
_sig_run() { ( sh -c 'echo $PPID > "$0"' "$PIDF"; KILL_TARGET=$(cat "$PIDF"); KILL_SIG="$1"; shift; "$@" ) >"$OUTF" 2>&1; }
_hook_h3() {   # üçüncü taraf reload'u: staged diski yükler, sonra sinyal ("_hook_${...}" ile DİNAMİK çağrılır; ölü sanılmasın)
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT"
    if (( n == 1 )); then fm_sim_reload; hs_signal_ancestor "$KILL_SIG" "$KILL_TARGET"; fi
}
_hook_h0() {   # üçüncü taraf yok: yalnız sinyal
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT"
    if (( n == 1 )); then hs_signal_ancestor "$KILL_SIG" "$KILL_TARGET"; fi
}
_runh() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -Eq 'auth_request|proxy_pass' "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_noclose() { _domconf_fm_em_close_disk() { _FME_DISK="failed"; return 1; }; "$@"; }
fake_open() {   # kayıt `on`; 20 = srvctl kapalı kökü + AÇIK vekil, 90/21 yok (qalab: f_openup / f_proxy)
    local v="$1" good; good=$(_domconf_fm_render_off example_com)
    case "$v" in
        f_openup) { printf '%s\n' "$good"; echo 'location ^~ /_fm/up/ { proxy_pass http://127.0.0.1:9/upload_write; }'; } > "$F20" ;;
        f_proxy)  { printf '%s\n' "$good"; echo 'location /zzz { proxy_pass http://127.0.0.1:9/x; }'; } > "$F20" ;;
    esac
    chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
}
for v in f_openup f_proxy; do
  for sig in INT TERM; do
    for w in repair84 fmroot; do
      for third in 3 0; do
        reset_all; _on; fake_open "$v"; rm -f "$CNT"
        _fmprov_load example_com
        assert_eq "$_FMP_STATE|$_FMP_EMERGENCY|$(_runh)" "off|4|RUN-OPEN" "H [${v}/${sig}/${w}/h${third}]: ön koşul: sınıf 4 (kayıt on + tanınmayan 20), çalışan nginx AÇIK vekili yüklü"
        NGINX_T_HOOK=_hook_h${third}
        case "$w" in
            repair84) _sig_run "$sig" _domconf_fm_auth_repair example.com 8.4 1 ;;
            fmroot)   _sig_run "$sig" _domconf_fm_root_cmd example.com --apply ;;
        esac; wrc=$?
        NGINX_T_HOOK=""
        want=130; [[ "$sig" == TERM ]] && want=143
        h=$(strip <<< "$(_out)")
        assert_eq "$wrc" "$want" "H [${v}/${sig}/${w}/h${third}]: çıkış kodu sinyal kodu"
        assert_eq "$(_shut)" "SHUT" "H [${v}/${sig}/${w}/h${third}]: geri alma sahte AÇIK kökü diske GERİ KOYMADI: 403 kökü, 90/21 yok (disk düzeyinde KAPALI)"
        assert_eq "$(grep -c 'proxy_pass' "$F20")" "0" "H [${v}/${sig}/${w}/h${third}]: diskteki 20'de açık vekil yok"
        assert_eq "$(_runh)" "RUN-CLOSED" "H [${v}/${sig}/${w}/h${third}]: ÇALIŞAN nginx KAPALI (yeniden yüklendi)"
        assert_contains "$h" "yeniden KAPATTI" "H [${v}/${sig}/${w}/h${third}]: kapanış SÖYLENDİ (sessiz değil)"
        assert_not_contains "$h" "FM HÂLÂ AÇIK" "H [${v}/${sig}/${w}/h${third}]: kapatıldı: 'FM HÂLÂ AÇIK' iletisi yok"
      done
    done
  done
done
# H2: kapatılamıyorsa yüksek sesle: disk AÇIK kalır → "FM HÂLÂ AÇIK OLABİLİR", reload YOK, rc sinyal kodu (≠ 0)
for w in repair84 fmroot; do
    reset_all; _on; fake_open f_openup; rm -f "$CNT"; NGINX_T_HOOK=_hook_h0
    case "$w" in
        repair84) _sig_run INT _noclose _domconf_fm_auth_repair example.com 8.4 1 ;;
        fmroot)   _sig_run INT _noclose _domconf_fm_root_cmd example.com --apply ;;
    esac; wrc=$?
    NGINX_T_HOOK=""; h=$(strip <<< "$(_out)")
    assert_eq "$wrc" "130" "H2 [${w}]: kapatılamadı: çıkış kodu sinyal kodu (≠ 0)"
    assert_contains "$h" "FM HÂLÂ AÇIK OLABİLİR" "H2 [${w}]: kapatılamayan açık ön durum YÜKSEK SESLE bildirilir"
done
# H3: kontrol — tanınan AÇIK eser üzerinde yarıda kesilen onarım açık durumu KORUR (kapatmaz): ön durum tanınıyor
reset_all; _on; rm -f "$CNT"; NGINX_T_HOOK=_hook_h0
_sig_run INT _domconf_fm_auth_repair example.com 8.3 1; wrc=$?
NGINX_T_HOOK=""
assert_eq "$wrc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_runh)" "130|varvar|on|RUN-OPEN" "H3 kontrol: tanınan açık eser + yarıda kesme: açık durum aynen geri gelir (tanınan ön durum kapatılmaz)"
# H4: kayıt on + KAPALI-görünümlü sahte kök (f_extraloc türü, disk zaten 403): geri alma sonucu tek satırla söyler (kapalı kaldı)
reset_all; _on; { _domconf_fm_render_off example_com; echo 'location /other { return 200 "x"; }'; } > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload; rm -f "$CNT"
NGINX_T_HOOK=_hook_h0; _sig_run INT _domconf_fm_auth_repair example.com 8.4 1; wrc=$?; NGINX_T_HOOK=""
h=$(strip <<< "$(_out)")
assert_eq "$wrc|$(_exists "$F90")$(_exists "$F21")|$(_runh)" "130|yokyok|RUN-CLOSED" "H4: sahte kapalı kök: 90/21 yok, çalışan KAPALI"
assert_contains "$h" "disk AÇIK DEĞİL" "H4: geri alma 'kapalı kaldı' sonucunu tek satırla söyler (iletisiz değil)"
assert_contains "$h" "KAPALI imzası (403)" "H4: çalışan durum KAPALI imzası söylenir"

# H5: kayıt on + 403 kökü ama 90/21 duruyor (qalab o_auth / o_dl: yarım kapalı) → geri alma 90/21'i diske GERİ KOYMAZ, kapanış söylenir
for w in repair84 fmroot; do
    reset_all; _on; _domconf_fm_render_off example_com > "$F20"; chmod 644 "$F20"; fm_sim_reload; rm -f "$CNT"
    NGINX_T_HOOK=_hook_h0
    case "$w" in
        repair84) _sig_run INT _domconf_fm_auth_repair example.com 8.4 1 ;;
        fmroot)   _sig_run INT _domconf_fm_root_cmd example.com --apply ;;
    esac; wrc=$?
    NGINX_T_HOOK=""; h=$(strip <<< "$(_out)")
    assert_eq "$wrc|$(_shut)|$(_runh)" "130|SHUT|RUN-CLOSED" "H5 [${w}]: 403 kökü + 90/21 (yarım kapalı) ön durumu: geri alma 90/21'i geri KOYMADI, disk kapalı, çalışan KAPALI"
    assert_contains "$h" "yeniden KAPATTI" "H5 [${w}]: kapanış SÖYLENDİ"
done

# H6: birim — _domconf_fm_restore_entry: açık/belirsiz tanınmayan ön durumda kapatır (rc 0); kapatılamazsa rc 1 (sessiz geçmez)
reset_all; _on; unrec fake_proxy; _mk_stale_bk AAAAAA
_FMT_BK=("${SD}/.bk.example_com.AAAAAA"); _FMT_SNAME=(example_com); _FMT_DIR=("$(dirname "$F20")")
( _domconf_fm_restore_entry 0 ) >/dev/null 2>&1; rrc=$?
assert_eq "$rrc|$(_shut)" "0|SHUT" "H6: restore_entry: tanınmayan AÇIK ön durum geri konmaz, disk kapatılır (rc 0)"
reset_all; _on; unrec fake_proxy; _mk_stale_bk AAAAAA
( _domconf_fm_em_close_disk() { return 1; }; _domconf_fm_restore_entry 0 ) >/dev/null 2>&1; rrc=$?
assert_eq "$rrc|$(_shut)" "1|OPEN" "H6: restore_entry: kapatılamazsa rc 1 (disk AÇIK kaldı: çağıran yüksek sesle bildirir)"
_FMT_BK=(); _FMT_SNAME=(); _FMT_DIR=()

# ═══ I. F9b/a3 BULGU-2: tanınan AÇIK taban + manifestsiz YALNIZ 20 içeren bayat yedek GERİ YÜKLENMEZ (kayıtsız yarım-açık üretmez) ═══
for path in fmroot fmrootall repair83 repair84 repairall; do
    reset_all; _on
    b="${SD}/.bk.example_com.AAAAAA"; mkdir -p "$b"; cp -p "$F20" "${b}/20-srvctl-fm-upload.conf"
    m20=$(_md5 "$F20"); m90=$(_md5 "$F90"); mman=$(_md5 "$MAN")
    runpath "$path"
    assert_eq "$(_bkn)|$(_supn)" "0|1" "I [${path}]: manifestsiz YALNIZ-20 yedek (açık 20) geri YÜKLENMEDİ, adli olarak ayrıldı"
    [[ "$path" == repair84 ]] && m90=$(_md5 "$F90")   # repair84 PHP kaymasını meşru olarak 90'a işler (kayıtlı parametrelerle yeniden üretim)
    assert_eq "$(_st)|$(_exists "$F90")$(_exists "$F21")|$(_md5 "$F20")|$(_md5 "$F90")" "on|varvar|${m20}|${m90}" "I [${path}]: kayıt on, 90/21 ve 20 AYNEN (açık/kayıt tutarlılığı bozulmadı)"
    [[ "$path" == fmroot ]] && assert_eq "$(_md5 "$MAN")" "$mman" "I [${path}]: kayıt dosyası değişmedi"
done
# I2: kontrol — yedek manifestsiz, 20 AÇIK imzasız (kullanıcı 20'si) → (i) dalı eskisi gibi geri yüklenir
printf 'x\n' > "${FM_STUBS}/victim"   # eski tek dosyada A'nın 'symlink' sınıfı üretirdi; I2'nin sembolik-bağ hedefi (bu parçada A yok)
reset_all; _domconf_fm_auth_forget example.com >/dev/null 2>&1; _fm_reset
b="${SD}/.bk.example_com.AAAAAA"; mkdir -p "$b"; printf 'location = /_fm { return 403; }\n' > "${b}/20-srvctl-fm-upload.conf"
assert_eq "$(_fmprov_bk_restore_allowed "$b" example_com; echo $?)" "0" "I2 kontrol: açık imzasız manifestsiz 20 yedeği geri yüklenebilir (davranış değişmedi)"
printf 'location ^~ /_fm/up/ { proxy_pass http://127.0.0.1:9/x; }\n' > "${b}/20-srvctl-fm-upload.conf"
assert_eq "$(_fmprov_bk_restore_allowed "$b" example_com; echo $?)" "1" "I2: açık imzalı (proxy_pass) manifestsiz 20 yedeği geri yüklenemez"
printf 'location ^~ /_fm/up/ { auth_request /x; }\n' > "${b}/20-srvctl-fm-upload.conf"
assert_eq "$(_fmprov_bk_restore_allowed "$b" example_com; echo $?)" "1" "I2: açık imzalı (auth_request) manifestsiz 20 yedeği geri yüklenemez"
rm -f "${b}/20-srvctl-fm-upload.conf"; ln -s "${FM_STUBS}/victim" "${b}/20-srvctl-fm-upload.conf"
assert_eq "$(_fmprov_bk_restore_allowed "$b" example_com; echo $?)" "1" "I2: sembolik bağ manifestsiz 20 yedeği geri yüklenemez"

# ═══ J. F9b/a3 DÜŞÜK-1: sınıf 4'te hiçbir status/ipucu çıktısı 'fm-root --apply' önermez; kapatan 'fm-auth off', açan açık 'fm-auth on' ═══
reset_all; _on; unrec nul
NGINX_TEST_RC=1; out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); NGINX_TEST_RC=0; out=$(strip <<< "$out")
assert_contains "$out" "nginx -t BAŞARISIZ" "J1 [nul + nginx -t hatası]: nginx -t hatası raporlanır"
assert_not_contains "$out" "fm-root example.com --apply" "J1 [nul + nginx -t hatası]: sınıf 4'te 'fm-root --apply' ÖNERİLMEZ"
assert_not_contains "$out" "fm-root --apply" "J1 [nul + nginx -t hatası]: 'fm-root --apply' metni hiç geçmez"
# J1b: nginx -t hatası BU alanın custom.d dosyasında (hata yolu alanın dizinini içerir): 'Onarım' ipucu sınıf 4'te kapatan 'fm-auth off' der
for v in nul fake_proxy; do
    reset_all; _on; unrec "$v"
    NGINX_T_MSG="nginx: [emerg] unexpected token in ${F20}:1"; NGINX_TEST_RC=0
    out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); NGINX_T_MSG=""; out=$(strip <<< "$out")
    assert_contains "$out" "BU alanın custom.d dosyasında" "J1b [${v}]: nginx -t hatası alanın dosyasında: dal çalıştı"
    assert_not_contains "$out" "fm-root example.com --apply" "J1b [${v}]: sınıf 4'te nginx -t onarım ipucu 'fm-root --apply' önermez"
    assert_contains "$out" "fm-auth example.com off" "J1b [${v}]: kapatmak için 'fm-auth off' önerilir"
done
for v in nul fake_proxy garbage missing20; do
    reset_all; _on; unrec "$v"; _mk_stale_bk AAAAAA
    out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); out=$(strip <<< "$out")
    assert_contains "$out" "YARIM İŞLEM" "J2 [${v} + bayat yedek]: yarım işlem bildirilir"
    assert_not_contains "$out" "fm-root example.com --apply" "J2 [${v} + bayat yedek]: sınıf 4'te YARIM İŞLEM ipucu 'fm-root --apply' önermez"
    assert_not_contains "$out" "fm-root --apply" "J2 [${v} + bayat yedek]: 'fm-root --apply' metni hiç geçmez"
    assert_contains "$out" "fm-auth example.com off" "J2 [${v} + bayat yedek]: kapatmak için 'fm-auth off' önerilir"
    assert_contains "$out" "fm-auth example.com on --script" "J2 [${v} + bayat yedek]: AÇAN tek komut açık 'fm-auth on' diye söylenir"
done
# J3: kontrol — sınıf 4 DEĞİLSE (kayıt off) eski ipucu korunur
reset_all; _on; ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; _mk_stale_bk AAAAAA
out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "fm-root example.com --apply" "J3 kontrol: kayıt KAPALI + bayat yedek: kurtarma ipucu (fm-root --apply, yedeği geri yüklemez) korunur"

test_summary
