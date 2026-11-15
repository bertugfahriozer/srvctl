#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9b/a1 — §15/33 "OTOMATİK YOLLAR ASLA AÇMAZ" ilkesi (mock; bu ilkeye özgü gerçek-nginx dosyası YOK — gerçek nginx kapsamı test_domconf_fm_f9_real.sh ve test_domconf_fm_probe_real.sh'ta; burada davranış mock'ta, kapalı yön), parça 5/7: B yarım-işlem kurtarması + G çökme penceresi
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
# ═══ B. yarım-işlem kurtarması: yedek tanınmayan AÇIK ön durum taşıyorsa GERİ YÜKLENMEZ (yalnız kapatma yönü) ═══
# B1: MEVCUT disk tanınan AÇIK, yedek (kesintiden kalma) tanınmayan bir açık ön durum taşıyor → yedek ayrılır, açık içerik geri gelmez
for v in fake_proxy9021 garbage open_tamper open_foreign; do
    for path in fmroot fmrootall repair84 repairall; do
        reset_all; _on
        cp -p "$F90" "${FM_STUBS}/s90"; cp -p "$F21" "${FM_STUBS}/s21"; cp -p "$F20" "${FM_STUBS}/s20"; cp -p "$MAN" "${FM_STUBS}/sman"
        unrec "$v"; _mk_stale_bk AAAAAA
        cp -p "${FM_STUBS}/s90" "$F90"; cp -p "${FM_STUBS}/s21" "$F21"; cp -p "${FM_STUBS}/s20" "$F20"; cp -p "${FM_STUBS}/sman" "$MAN"; fm_sim_reload
        runpath "$path"
        assert_eq "$(_bkn)|$(_supn)" "0|1" "B1 [${v} / ${path}]: tanınmayan açık ön durum yedeği GERİ YÜKLENMEDİ, adli olarak ayrıldı"
        assert_eq "$(grep -c '127.0.0.1:9;\|return 200 "kullanici"\|# kurcalandi\|srvctl-fm-open 000000000000' "$F20" "$F90" "$F21" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" "0" "B1 [${v} / ${path}]: diskte tanınmayan içerik YOK"
    done
done
# B2: MEVCUT disk 20'siz (kayıt on), yedek tanınan AÇIK eser taşıyor → yedek ayrılır, alan AÇILMAZ (mevcut disk tanınan açık değil)
for path in fmroot repair84; do
    reset_all; _on; _mk_stale_bk AAAAAA; unrec fake_proxy
    runpath "$path"
    assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "B2 [${path}]: mevcut disk tanınmayan; yedek (tanınan açık) alanı GERİ AÇMADI"
done
# B3: yedek tanınmayan 20 + kayıt `on` taşıyor, mevcut kayıt da `on`, mevcut disk eksik → AÇILMAZ
for path in fmroot repair84 fmrootall; do
    reset_all; _on; unrec garbage; _mk_stale_bk AAAAAA; rm -f "$F20" "$F90" "$F21"; fm_sim_reload
    runpath "$path"
    assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "B3 [${path}]: tanınmayan açık yedek + eksik disk: yalnız 403 kökü"
done
# B4: kontrol — yedek TANINAN AÇIK ön durum ve mevcut disk de tanınan açık (kesinti öncesine dönüş) → açık durum KORUNUR
reset_all; _on; cp -p "$F20" "${FM_STUBS}/s20"; _mk_stale_bk AAAAAA; printf '# yarim\n' >> "$F90"; _fmroot
# F9c (§15/38) TERSİNE: mevcut disk 90'ı kurcalanmış (yarım) → kayıt off sayılır; sağlam yedek bile geri yüklenmez, alan KAPANIR (eskiden: yedek geri yüklenir, açık korunur).
# Yedeğin geri yüklenip açık korunduğu kontrol, mevcut diskin de tanınan açık olduğu durumda: tests/test_domconf_fm_f9c_all_three_f.sh B5.
assert_eq "$(_bkn)|$(_exists "$F90")$(_exists "$F21")|$(_st)" "0|yokyok|off" "B4 kontrol (F9c TERSİNE): mevcut disk 90 kurcalanmış → sağlam yedek bile geri yüklenmez; alan KAPANIR"

# B5: yedeğin manifesti `off` ama yedekte AÇIK 90/21 var (tutarsız/kurcalanmış ön durum) → geri YÜKLENMEZ (yalnız ayrılır)
for path in fmroot repair84; do
    reset_all; _on
    cp -p "$F90" "${FM_STUBS}/s90"; cp -p "$F21" "${FM_STUBS}/s21"; cp -p "$F20" "${FM_STUBS}/s20"; cp -p "$MAN" "${FM_STUBS}/sman"
    ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1
    b="${SD}/.bk.example_com.AAAAAA"; mkdir -p "$b"; cp -p "$MAN" "${b}/manifest"; cp -p "${FM_STUBS}/s90" "${b}/90-srvctl-fm-auth.conf"; cp -p "${FM_STUBS}/s21" "${b}/21-srvctl-fm-download.conf"
    cp -p "$F20" "${b}/20-srvctl-fm-upload.conf"      # yedekte 20 tanınan KAPALI kök (off manifest ile tutarlı); tek tutarsızlık: AÇIK 90/21 de duruyor
    cp -p "${FM_STUBS}/s90" "$F90"; cp -p "${FM_STUBS}/s21" "$F21"; cp -p "${FM_STUBS}/s20" "$F20"; cp -p "${FM_STUBS}/sman" "$MAN"; fm_sim_reload
    runpath "$path"
    assert_eq "$(_bkn)|$(_supn)" "0|1" "B5 [${path}]: yedek off manifestli ama AÇIK 90/21 taşıyor: geri YÜKLENMEDİ, ayrıldı"
done

# B6: kuru plan (fm-root bayraksız) geri yüklenmeyecek yedeği ve nedenini söyler, hiçbir şey yazmaz
reset_all; _on; cp -p "$F20" "${FM_STUBS}/s20"; unrec garbage; _mk_stale_bk AAAAAA; cp -p "${FM_STUBS}/s20" "$F20"; fm_sim_reload
out=$( ( _domconf_fm_root_cmd example.com ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "ön durum tanınan bir srvctl eseri değil" "B6 kuru plan: yedeğin geri yüklenmeyeceğini ve nedenini söyler"
assert_eq "$(_bkn)|$(_supn)" "1|0" "B6 kuru plan: hiçbir şey yazmaz (yedek yerinde)"

# B7: manifestsiz yedek + AÇIK 90 (kayıt yokken açık dosya geri koymak) → geri YÜKLENMEZ
for path in fmroot repair84; do
    reset_all; _on; cp -p "$F90" "${FM_STUBS}/s90"
    b="${SD}/.bk.example_com.AAAAAA"; mkdir -p "$b"; cp -p "${FM_STUBS}/s90" "${b}/90-srvctl-fm-auth.conf"
    runpath "$path"
    assert_eq "$(_bkn)|$(_supn)" "0|1" "B7 [${path}]: manifestsiz yedek AÇIK 90 taşıyor: geri YÜKLENMEDİ, ayrıldı"
done

# ═══ G. iki-aşamalı geçişte çökme penceresi: kayıt (on: yeni 90/21/20-açık + ESKİ kapalı kök özeti), diskte 90/21 yazılmış, 20 hâlâ ESKİ kapalı kök ═══
# 20'nin özeti kayıtta (eski kapalı kök) ama AÇIK eser değil → tanınan AÇIK eser SAYILMAZ (kayıttaki kapalı özet "açık" kanıtı olmasın); otomatik yol AÇMAZ
gsetup() {
    reset_all; _on
    cp -p "$F90" "${FM_STUBS}/s90"; cp -p "$F21" "${FM_STUBS}/s21"; cp -p "$MAN" "${FM_STUBS}/sman"
    ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1
    cp -p "${FM_STUBS}/s90" "$F90"; cp -p "${FM_STUBS}/s21" "$F21"
    h20=$(_domconf_sha256_file "$F20")
    cp -p "${FM_STUBS}/sman" "$MAN"; printf 'sha256 %s %s\n' "$h20" "20-srvctl-fm-upload.conf" >> "$MAN"
    fm_sim_reload
}
for path in fmroot fmrootall repair83 repair84 repairall phpswitch provision; do
    gsetup; _fmprov_load example_com; pre="$_FMP_STATE|$_FMP_EMERGENCY"
    runpath "$path"
    assert_eq "$pre|$(_shut)|$(_st)|$(_run)" "off|4|SHUT|off|RUN-CLOSED" "G [${path}]: çökme penceresi (kayıttaki ESKİ kapalı kök özeti açık eser SAYILMAZ): alan AÇILMADI"
done

test_summary
