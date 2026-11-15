#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9d/dev (parça b/2: B-G; ÇEKİRDEK matris A: test_domconf_fm_f9d_double_bk.sh) — ARCHITECTURE §15/43(b): bir alanda >=2 yarım-işlem yedeği (.bk.*) varsa kurtarma YAPILMAZ (hangisinin doğru olduğu bilinemez)
# AMA alan AÇIK BIRAKILMAZ: §15/38 ile hizalı olarak kayıt `off` sayılır ve alan 403 köküne KAPATILIR; İKİ YEDEK DOKUNULMADAN korunur
# (içerik/md5 aynı, silinmez/taşınmaz/ayrılmaz/yeniden adlandırılmaz); rc≠0 ve "elle inceleyin". Eski ağaçta (d0de1c0e) bu durumda alan
# kapatılmaz ve açılmaz (GÖZLEM-ÇİFT-YEDEK): 2 yedek + açık alan => alan AÇIK kalırdı. Kapsam: yarım-işlem kurtarmasına giren her yol
# (repair 8.3/8.4, toplu repair, fm-root, fm-root --all, php-switch [soket yazacağı zaman], provision) + status (salt-okur).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

source "${REPO_ROOT}/tests/fm_f9d_double_bk_common.sh"

# ═══ B. ZATEN KAPALI (kayıt off + 403 kökü + 90/21 yok): kapatma yazımı YOK (disk/kayıt/reload aynı), yedekler aynı, rc≠0 ═══
for path in repair83 repair84 repairall fmroot fmrootall provision; do
    setup KOFF; s0=$(snap); d0=$(diskfp); r0=$(_reloads)
    runpath "$path"; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$((rc != 0))|$(snap)|$(diskfp)|$(_reloads)" "1|${s0}|${d0}|${r0}" "B [KOFF / ${path}]: zaten kapalı: rc≠0, yedekler/disk/kayıt aynı, gereksiz reload YOK"
    assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "B [KOFF / ${path}]: alan kapalı kalır"
    assert_contains "$out" "elle inceleyin" "B [KOFF / ${path}]: 'elle inceleyin' denir"
done
setup KOFF; s0=$(snap); runpath repair83 >/dev/null; out=$(strip < "$OUTF")
assert_contains "$out" "zaten KAPALI" "B2: repair 'alan zaten KAPALI' der (kapatma yazımı gerekmedi)"
# B3: php-switch kayıt off iken no-op (kurtarmaya girmez): yedekler ve alan aynı
setup KOFF; s0=$(snap); d0=$(diskfp); _phpswitch; rc=$?
assert_eq "$rc|$(snap)|$(diskfp)" "0|${s0}|${d0}" "B3 [KOFF / phpswitch]: kayıt off: php-switch no-op (belgeli sınır), yedekler ve disk aynı"

# ═══ C. İDEMPOTENS: kapatmadan SONRA aynı komut tekrar: yeni yazım/reload YOK, yedekler aynı, rc≠0, alan kapalı ═══
for path in repair83 fmroot provision; do
    setup K0; runpath "$path"; s1=$(snap); d1=$(diskfp); r1=$(_reloads)
    runpath "$path"; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$((rc != 0))|$(snap)|$(diskfp)|$(_reloads)|$(_shut)" "1|${s1}|${d1}|${r1}|SHUT" "C [${path}] 2. koşu: rc≠0, yedekler/disk/kayıt aynı, reload YOK, alan kapalı kalır"
    assert_contains "$out" "elle inceleyin" "C [${path}] 2. koşu: 'elle inceleyin' sürer"
done

# ═══ D. KAPATILAMADI -> yüksek sesle: nginx -t düşerse ön durum geri alınır, rc≠0, "FM HÂLÂ AÇIK OLABİLİR", yedekler aynı ═══
for sc in K0 K4_90; do
    for path in repair83 repairall fmroot fmrootall phpswitch provision; do
        setup "$sc"; s0=$(snap)
        NGINX_TEST_RC=1; runpath "$path"; rc=$?; NGINX_TEST_RC=0; out=$(strip < "$OUTF")
        assert_eq "$((rc != 0))|$(snap)" "1|${s0}" "D [${sc} / nginx -t düşer / ${path}]: rc≠0, yedekler aynı"
        assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "D [${sc} / nginx -t düşer / ${path}]: 'FM HÂLÂ AÇIK OLABİLİR' (kapatılamadı)"
        assert_eq "$(_bkn)|$(_supn)" "2|0" "D [${sc} / nginx -t düşer / ${path}]: 2 yedek, geçici kapatma yedeği silindi"
    done
done
# D2: K0'da nginx -t düşünce ön durum aynen geri konur (kapatma uygulanmadı): kayıt on, çalışan AÇIK
setup K0; d0=$(diskfp); NGINX_TEST_RC=1; runpath repair83 >/dev/null; NGINX_TEST_RC=0
assert_eq "$(diskfp)|$(_st)|$(_run)" "${d0}|on|RUN-OPEN" "D2: nginx -t düşünce disk/kayıt ön durumda (kapatma yarım kalmadı), çalışan hâlâ AÇIK (dürüstçe söylendi)"
# D3: reload başarısız (disk KAPATILDI ama çalışan nginx eski): rc≠0 + "FM HÂLÂ AÇIK OLABİLİR"
for path in repair83 fmroot provision; do
    setup K0; s0=$(snap); SYSTEMCTL_RC=1; runpath "$path"; rc=$?; SYSTEMCTL_RC=0; out=$(strip < "$OUTF")
    assert_eq "$((rc != 0))|$(snap)|$(_shut)|$(_run)" "1|${s0}|SHUT|RUN-OPEN" "D3 [reload düşer / ${path}]: rc≠0, yedekler aynı, disk KAPALI ama çalışan nginx eski (AÇIK)"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "D3 [reload düşer / ${path}]: dürüst ileti"
done
# D3b: köken kaydı AŞAMA 2 yazılamaz (commit): işlem geri alınır, reload YOK, kapatılamadığı yüksek sesle söylenir; iki yedek aynı
orig_fmprov_write=$(declare -f _fmprov_write)
WCNT="${FM_STUBS}/wcnt"
_fmprov_write() {   # 1. çağrı (aşama 1, sahneleme) geçer; 2. çağrı (commit, aşama 2) düşer
    local n; n=$(cat "$WCNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$WCNT"
    if (( n >= 2 )); then return 1; fi
    _f9e5_orig_fmprov_write "$@"
}
eval "_f9e5_orig_fmprov_write() ${orig_fmprov_write#*()}"
for path in fmroot fmrootall; do
    setup K0; s0=$(snap); r0=$(_reloads); rm -f "$WCNT"
    runpath "$path"; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$rc|$(snap)|$(_reloads)" "1|${s0}|${r0}" "D3b [aşama 2 yazılamaz / ${path}]: rc 1, yedekler aynı, reload YOK"
    assert_contains "$out" "köken kaydı aşama 2 yazılamadı" "D3b [${path}]: neden söylenir"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "D3b [${path}]: çift yedekli alan kapatılamadı → 'FM HÂLÂ AÇIK OLABİLİR'"
done
eval "$orig_fmprov_write"
# D4: kayıt dizini güvenilmez (STATE-UNTRUSTED): kilit/yazım reddedilir; yedekler dokunulmaz, rc≠0 (kayıt güvenilmezken alan kapatılamaz)
for path in repair83 fmroot provision; do
    setup K0; s0=$(snap); MOCK_BAD_OWNER="$SD"; runpath "$path"; rc=$?; MOCK_BAD_OWNER=""
    assert_eq "$((rc != 0))|$(snap)" "1|${s0}" "D4 [STATE-UNTRUSTED / ${path}]: rc≠0, yedekler aynı"
done

# ═══ E. STATUS (salt-okur): rc≠0, birden çok yedek söylenir, HİÇBİR şey değişmez ═══
for sc in K0 K4_90 KOFF; do
    setup "$sc"; s0=$(snap); d0=$(diskfp); r0=$(_reloads)
    _status; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$((rc != 0))|$(snap)|$(diskfp)|$(_reloads)" "1|${s0}|${d0}|${r0}" "E [${sc} / status]: rc≠0 ve salt-okur (yedek/disk/kayıt/reload değişmedi)"
    assert_contains "$out" "BİRDEN ÇOK YEDEK" "E [${sc} / status]: birden çok yedek söylenir"
    assert_contains "$out" "KAPATIR" "E [${sc} / status]: otomatik yolların alanı KAPATTIĞI söylenir"
done
# E2: kapatmadan SONRA status: yedekler duruyor => rc≠0 (kayıt off, kapalı)
setup K0; runpath repair83 >/dev/null; _status; rc=$?; out=$(strip < "$OUTF")
assert_eq "$((rc != 0))|$(_st)|$(_shut)" "1|off|SHUT" "E2: kapatmadan sonra status: yedekler yerinde => rc≠0; kayıt off, disk kapalı"

# ═══ F. KONTROLLER ═══
# F1: TEK yedek davranışı DEĞİŞMEDİ (kurtarma geri yükler): rc 0, yedek tüketilir, 'birden çok' DEMEZ
reset_all; _on; _mk_stale_bk AAAAAA; fm_sim_reload; _repair; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(_bkn)|$(_supn)" "0|0|0" "F1: tek yedek: kurtarma yedeği geri yükler (rc 0, yedek tüketildi) — davranış değişmedi"
assert_not_contains "$out" "birden çok yarım işlem yedeği" "F1: tek yedekte 'birden çok' iletisi basılmaz"
# F1b: aynı tek yedek, provision yolunda: eşik "> 1" (iki ve fazlası); tek yedek KAPATMA yoluna sapmaz, kurtarma geri yükler
reset_all; _on; _mk_stale_bk AAAAAA; fm_sim_reload; _provision; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(_supn)|$(_st)|$(_shut)" "0|0|on|OPEN" "F1b: provision + TEK yedek: rc 0, yedek ayrılmadı, kayıt on, alan AÇIK kalır (kapatma yoluna SAPMAZ; sapsaydı rc 1 + kapalı olurdu)"
assert_not_contains "$out" "birden çok yarım işlem yedeği" "F1b: tek yedekte provision 'birden çok' DEMEZ"
# F2: üç yedek de aynı kuralı izler (>=2)
setup K0; _mk_stale_bk CCCCCC; s0=$(snap); _repair 8.3; rc=$?
assert_eq "$((rc != 0))|$(snap)|$(_shut)|$(_st)|$(_bkn)" "1|${s0}|SHUT|off|3" "F2: üç yedek: alan KAPATILIR, üç yedek aynı, rc≠0"
# F3: açık operatör komutu `fm-auth off` hâlâ iki yedeği geri yüklemeden AYIRIR (otomatik yol değil; mevcut belgeli davranış)
setup K0; _off; rc=$?
assert_eq "$rc|$(_bkn)|$(_supn)|$(_shut)" "0|0|2|SHUT" "F3: fm-auth off (açık operatör komutu) iki yedeği .superseded olarak AYIRIR, alan kapalı"
# F4: `fm-auth on` iki yedek varken REDDEDİLİR (yedekler aynı, alan açılmaz)
setup KOFF; s0=$(snap); _on; rc=$?
assert_eq "$((rc != 0))|$(snap)|$(_st)" "1|${s0}|off" "F4: fm-auth on iki yedek varken reddedilir; yedekler aynı, kayıt off"
# F5: kapatılan alanı yalnız açık 'fm-auth on' açar — yedekler elle kaldırıldıktan sonra
setup K0; runpath repair83 >/dev/null; mv "${SD}/.bk.example_com.AAAAAA" "${FM_STUBS}/elle.A"; mv "${SD}/.bk.example_com.BBBBBB" "${FM_STUBS}/elle.B"
_on; rc=$?
assert_eq "$rc|$(_st)|$(_exists "$F90")" "0|on|var" "F5: yedekler elle kaldırıldıktan sonra açık 'fm-auth on' alanı yeniden açar"

# ═══ G. fm-root KURU: iki yedek 'YAPILAMAZ' (rc 1; kurtarma yok) ama neyin yapılacağını söyler; HİÇBİR şey yazmaz ═══
setup K0; s0=$(snap); d0=$(diskfp); r0=$(_reloads)
( _domconf_fm_root_cmd example.com ) >"$OUTF" 2>&1; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(snap)|$(diskfp)|$(_reloads)" "1|${s0}|${d0}|${r0}" "G: fm-root kuru: rc 1, hiçbir şey yazılmadı"
assert_contains "$out" "YAPILAMAZ: birden çok yarım işlem yedeği" "G: kurtarma YAPILAMAZ"
assert_contains "$out" "KAPATIR" "G: --apply'ın alanı KAPATACAĞI söylenir"
assert_contains "$out" "DOKUNULMAZ" "G: yedeklere dokunulmayacağı söylenir"

test_summary
