#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça b/6: A (hedef 90 x varyant x yol) + D status
# Eski tek dosya (test_domconf_fm_f9c_all_three.sh, 677 doğrulama, tam süitte >600 sn) 6 bağımsız dosyaya, sonra yük altında 300 sn'yi aşan a/e/f 12 dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f9c_common.sh. Parçalar: _a (P/A5), _a_2 (A6/G), _a_3 (C/E/R), _b (A[90]+D), _c (A[21]), _d (A[both]), _e (A1b: ilk 5 varyant), _e_2 (A1b: kalan 5 varyant), _e_3 (A2/A3/A4), _f (B1/B1b/B1c + B2[90]), _f_2 (B2[21]), _f_3 (B2[both] + B3..B6).
# İlkenin açıklaması (üçü de tanınmalı; sınıf 4 yolları): test_domconf_fm_f9c_all_three_a.sh başlığında.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"
A_TARGETS="90"
# ═══ A. hedef x varyant x yol: hiçbir otomatik yol bozulan 21/90 için sessiz yeniden üretmez: 403 kökü, 90/21 yok, kayıt off, çalışan KAPALI ═══
for t in $A_TARGETS; do
    for v in $AVARS; do
        for path in $PATHS; do
            reset_all; _on; apply_target "$t" "$v"
            runpath "$path"
            assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "A [${t}/${v} / ${path}]: 20 tanınan açık + ${t} ${v}: 403 kökü yazıldı, 90/21 yok, kayıt off, çalışan KAPALI (sessiz yeniden üretim YOK)"
            MOCK_BAD_OWNER=""
        done
    done
done
# ═══ D. status: TAMPERED, 20/21/90'dan biri tanınmıyor der, rc≠0; 'fm-root --apply' ÖNERMEZ; yalnız açık 'fm-auth on' açar ═══
for t in $TARGETS; do
    for v in missing tamper symlink badowner unknown unrecorded; do
        reset_all; _on; apply_target "$t" "$v"
        out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); src=$?; out=$(strip <<< "$out")
        assert_contains "$out" "TAMPERED" "D status [${t}/${v}]: TAMPERED der"
        assert_contains "$out" "TANINMAYAN AÇIK ESER" "D status [${t}/${v}]: tanınmayan açık eseri adıyla raporlar"
        assert_contains "$out" "20/21/90 (20-srvctl-fm-upload.conf, 21-srvctl-fm-download.conf, 90-srvctl-fm-auth.conf) eserlerinden en az biri tanınan" "D status [${t}/${v}]: 'üç eserden (20/21/90) en az biri tanınmıyor' der"
        dw=TANINMAYAN; [[ "$v" == missing ]] && dw="EKSİK"
        case "$t" in
            90)   assert_contains "$out" "90: ${dw}" "D status [${t}/${v}]: 90 eserinin durumu (${dw}) adıyla söylenir" ;;
            21)   assert_contains "$out" "21: ${dw}" "D status [${t}/${v}]: 21 eserinin durumu (${dw}) adıyla söylenir" ;;
            both) assert_contains "$out" "90: ${dw}" "D status [${t}/${v}]: 90 eserinin durumu (${dw}) adıyla söylenir"
                  assert_contains "$out" "21: ${dw}" "D status [${t}/${v}]: 21 eserinin durumu (${dw}) adıyla söylenir" ;;
        esac
        assert_not_contains "$out" "srvctl domain fm-root example.com --apply" "D status [${t}/${v}]: alanı etkileyen 'fm-root --apply' ÖNERİLMEZ"
        assert_contains "$out" "fm-auth example.com on --script" "D status [${t}/${v}]: yalnız AÇIK 'fm-auth on' açar diye söyler"
        assert_eq "$((src != 0))" "1" "D status [${t}/${v}]: rc≠0"
        MOCK_BAD_OWNER=""
    done
done
# D2: kuru plan alanı AÇACAK bir iş ÖNERMEZ; hiçbir şey yazmaz
for t in 90 21; do
    reset_all; _on; apply_target "$t" tamper; b20=$(_md5 "$F20"); b90=$(_md5 "$F90"); b21=$(_md5 "$F21")
    out=$( ( _domconf_fm_root_cmd example.com ) 2>&1 ); out=$(strip <<< "$out")
    assert_contains "$out" "AÇILMAZ" "D2 [${t}] kuru plan: alanın AÇILMAYACAĞINI söyler"
    assert_eq "$(_md5 "$F20")|$(_md5 "$F90")|$(_md5 "$F21")" "${b20}|${b90}|${b21}" "D2 [${t}] kuru plan: diske yazmaz"
done
# D3: çekirdek durum yükleminin kendisi sınıf 4'te rc 1 verir
reset_all; _on; apply_target 21 missing
( _domconf_fm_auth_status_core example.com example_com "$CUR_DIR" ) >"$OUTF" 2>&1; crc=$?
assert_eq "$crc" "1" "D3 status çekirdeği: kayıt on + 21 eksik → rc 1"
# D4: kontrol — üçü tanınan açık: status AÇIK, rc 0
reset_all; _on
out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); src=$?; out=$(strip <<< "$out")
assert_eq "$src" "0" "D4 kontrol: üçü tanınan açık: status rc 0"
assert_not_contains "$out" "TANINMAYAN AÇIK ESER" "D4 kontrol: üçü tanınan açık: TANINMAYAN AÇIK ESER demez"

test_summary
