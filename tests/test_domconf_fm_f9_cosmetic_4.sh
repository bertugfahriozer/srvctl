#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9/a1 (qalab9-I2) — kayıt 'on' + kozmetik bozuk ama srvctl adlı kapalı kök: 8 yolun HİÇBİRİ alanı AÇMAZ (mock; gerçek nginx: test_domconf_fm_f9_real.sh). Parça 4/4: ikinci I2 döngüsü, kontroller, status.
# (Diğer F9 testleri: test_domconf_fm_f9_closure.sh.)
# Eski tek dosya (136 satır) yük altında 300 sn'yi aştığı için dört dosyaya bölündü (hiçbir doğrulama silinmedi ya da gevşetilmedi); ortak düzenek: tests/fm_f9_cosmetic_common.sh. Parçalar: (ad yok) I2 döngüsü crlf/trailing/mode664, _2 hardlink/wstab/wstab1, _3 wstabbody/wsmulti/wsquote, _4 ikinci I2 döngüsü + kontroller + status.
#  I2    kayıt `on` + kozmetik bozuk ama srvctl adlı kapalı kök (CRLF, mod 664, sondaki boşluk, sert bağ …): 8 yolun HİÇBİRİ alanı AÇMAZ;
#        status kurcalama raporlar, 'fm-root --apply' önermez
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9_cosmetic_common.sh"
for v in inlinecmt leading mode666 foreign unsigned_unknown; do
    for path in fmroot repair84 phpswitch; do
        reset_all; _on; MOCK_BAD_OWNER=""
        cosmetic "$v"
        runpath "$path"
        assert_eq "$(_sh)|$(_run)" "SHUT|RUN-CLOSED" "I2 [${v} / ${path}]: alan AÇILMADI"
        MOCK_BAD_OWNER=""
    done
done
# kontrol: AÇAN tek yol açık 'fm-auth on'
reset_all; _on; cosmetic crlf; _on; orc=$?
assert_eq "$orc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_run)" "0|varvar|on|RUN-OPEN" "I2 kontrol: açık 'fm-auth on' kozmetik bozuk alanı AÇAR (tek yol)"
# kontrol: HASMANE (ek direktifli) kök kozmetik DEĞİL → F9b (§15/33): F8 beyanı KALDIRILDI — kayıt 'on' + tanınmayan 20 = sınıf 4 (kapalı sayılır, hiçbir yol açmaz)
reset_all; _on; printf '%s\n' "$EQ" "$PR" 'proxy_pass http://127.0.0.1:9;' > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "I2 kontrol: ek direktifli (proxy_pass) kök kapalı görünümlü DEĞİL → F9b (§15/33): sınıf 4 (kapalı sayılır; KD-YOL-AÇTI = 0)"
# kontrol: gövdede imza DEĞERİ bozuksa (11 hex / farklı imza) lookalike DEĞİL — F8 beyanı (yapısal sahte) sürer
for bad in 'ab12cd34ef5' '000000000000'; do
    reset_all; _on; printf '%s\n' "location = /_fm { return 403 \"srvctl-fm-closed${bad}\"; }" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${bad}\"; }" > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
    _fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "I2 kontrol: bozuk/bitişik imza (${bad}) kozmetik DEĞİL → F9b: sınıf 4 (kapalı sayılır; F8 beyanı kaldırıldı)"
done
reset_all; _on; printf '%s\n' "location = /_fm { return 403 \"srvctl-fm-closed	${SIG}\"; }" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed 000000000000\"; }" > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
_fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "I2 kontrol: tab'lı gövde AMA iki satırın (geçerli 12 hex) imzası farklı: kozmetik DEĞİL → F9b sınıf 4"
# kontrol: tab'lı gövde + imza UZUNLUĞU yanlış (11 / 13 hex, her iki satırda aynı) → kozmetik DEĞİL (bozuk imza yapısal sahte kalır: F8 beyanı)
for sg in "${SIG:0:11}" "${SIG}a"; do
    reset_all; _on; printf '%s\n' "location = /_fm { return 403 \"srvctl-fm-closed	${sg}\"; }" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed	${sg}\"; }" > "$F20"; chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
    _fmprov_load example_com; assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "I2 kontrol: tab'lı gövde AMA imza ${#sg} hex (12 değil): kozmetik DEĞİL → F9b sınıf 4"
done
# status: kurcalama raporlar, 'fm-root --apply' ÖNERMEZ, yalnız açık 'on' / 'off' önerir
for v in crlf mode664 hardlink wstab wstab1 wstabbody wsmulti; do
    reset_all; _on; MOCK_BAD_OWNER=""; cosmetic "$v"
    out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); src=$?; out=$(strip <<< "$out")
    assert_contains "$out" "KAPALI GÖRÜNÜMLÜ KÖK" "I2 status [${v}]: kurcalamayı raporlar"
    assert_contains "$out" "TAMPERED" "I2 status [${v}]: TAMPERED der"
    assert_not_contains "$out" "srvctl domain fm-root example.com --apply" "I2 status [${v}]: alanı AÇAN 'fm-root --apply' ÖNERİLMEZ"
    assert_contains "$out" "fm-auth example.com on --script" "I2 status [${v}]: yalnız AÇIK 'fm-auth on' açar diye söyler"
    assert_eq "$((src != 0))" "1" "I2 status [${v}]: rc≠0"
    rm -f "${F20}.hard"; MOCK_BAD_OWNER=""
done

test_summary
