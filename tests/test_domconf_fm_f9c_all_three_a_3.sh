#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1c — ARCHITECTURE §15/38 "ÜÇÜ DE TANINMALI" (mock; davranış kapalı yön), parça a_3/12: C kontrol, E geri alma, R toplu repair
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
# ═══ C. KONTROL: üçü de TANINAN açık eser → bakım açık durumu KORUR (açmaz ama kapatmaz) ═══
for path in fmroot fmrootall repair83 repair84 repairall phpswitch; do
    reset_all; _on; m20=$(_md5 "$F20"); runpath "$path"; rc=$?
    assert_eq "$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_md5 "$F20")|$(_run)" "varvar|on|${m20}|RUN-OPEN" "C [${path}]: üçü de tanınan açık: açık durum korunur (20 aynen, çalışan AÇIK)"
done
reset_all; _on; _repair 8.4; rc=$?
assert_eq "$rc|$(grep -c 'php8.4-fpm' "$F90")" "0|1" "C1: tanınan açık + PHP kayması: repair soketi günceller (rc 0)"
reset_all; _on; _phpswitch; rc=$?
assert_eq "$rc|$(grep -c 'php8.4-fpm' "$F90")" "10|1" "C2: tanınan açık + php-switch: soket güncellenir (rc 10)"
# C6: 20/90/21'in özeti kayıtta (eski şablon) ama güncel render'dan farklı (STALE): hâlâ tanınan, bakım açık durumu korur
reset_all; _on; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; _fmroot; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)" "0|varvar|on" "C6: üçü tanınan + bayat (STALE) şablon: yeniden üretilir, açık durum korunur"
# C7: açan TEK yol açık 'fm-auth on' — kapatılan alan yalnız o komutla yeniden açılır
reset_all; _on; apply_target 90 tamper; _fmroot; _on; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_run)" "0|varvar|on|RUN-OPEN" "C7: 90 kurcalanıp kapatılan alan yalnız açık 'fm-auth on' ile yeniden açılır"

# ═══ E. geri alma: kapatma yazımı nginx -t'de düşerse tanınmayan açık ön durum diske GERİ KONMAZ, disk 403 köküyle kapalı kalır ═══
for t in 90 21; do
    reset_all; _on; apply_target "$t" tamper; NGINX_TEST_RC=1; _repair 8.3; NGINX_TEST_RC=0
    assert_eq "$(_shut)" "SHUT" "E [${t}]: nginx -t düşünce 20 tanınan + ${t} kurcalanmış ön durum geri KONMAZ, disk 403 köküyle kapalı"
    assert_eq "$(grep -c 'kurcalandi' "$F20" "$F90" "$F21" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" "0" "E [${t}]: kurcalanmış içerik diskte kalmadı"
done
# E2: kontrol — üçü tanınan açık: nginx -t düşünce ön durum aynen geri konur (açık durum korunur)
reset_all; _on; NGINX_TEST_RC=1; _repair 8.4; NGINX_TEST_RC=0
assert_eq "$(_st)|$(_exists "$F90")$(_exists "$F21")" "on|varvar" "E2 kontrol: tanınan açık ön durum: geri alma aynen geri koyar"

# ═══ R. F9b qalab2 g3 `repairall` (LOW 2.3): iki yarım-işlem yedeği + sınıf 4 → toplu repair adımı rc≠0 (alan açık kalıp rc 0 DÖNMEZ) ═══
#   Kök neden: ürün (`_domain_repair_fm_step` → `_domain_repair` → `--all` döngüsü failed_domains) rc 1 verir; lab'ın f_batch sarmalayıcısı
#   son komutunun (`if [[ -s PENDING ]]`) durumunu döndürüyordu. Bu bölüm ürün davranışını kilitler (regresyon): adım rc'sini yutmak kırar.
for base in t20 t90 t21; do
    reset_all; _on
    case "$base" in t20) printf '# kurcalandi\n' >> "$F20" ;; t90) printf '# kurcalandi\n' >> "$F90" ;; t21) printf '# kurcalandi\n' >> "$F21" ;; esac
    _mk_stale_bk AAAAAA; _mk_stale_bk BBBBBB; fm_sim_reload
    _batch; rc=$?
    assert_eq "$((rc != 0))" "1" "R [${base} + 2 yedek]: toplu repair adımı rc≠0 (işini tamamlayamadı: birden çok yedek)"
    assert_eq "$(_bkn)" "2" "R [${base} + 2 yedek]: yedekler yerinde (otomatik kurtarma yapılmadı)"
    out=$(strip < "$OUTF")
    assert_contains "$out" "fm-auth onarılamadı" "R [${base} + 2 yedek]: 'onarılamadı' söylenir"
done
# R2: alanı kapatan toplu repair adımı rc 0 verir VE PENDING'e yazar (tek toplu reload alanı gerçekten kapatır)
for base in t90 t21; do
    reset_all; _on
    case "$base" in t90) printf '# kurcalandi\n' >> "$F90" ;; t21) printf '# kurcalandi\n' >> "$F21" ;; esac
    fm_sim_reload; _batch; rc=$?
    assert_eq "$rc|$(_shut)|$(_st)|$(_run)|$(wc -l < "$PEND" | tr -d ' ')" "0|SHUT|off|RUN-CLOSED|1" "R2 [${base}]: toplu repair adımı alanı kapattı: rc 0, PENDING'de alan, toplu reload sonrası çalışan KAPALI"
    out=$(strip < "$OUTF")
    assert_contains "$out" "alanı KAPATTI" "R2 [${base}]: ileti 'alanı KAPATTI' der"
    assert_not_contains "$out" "yeniden üretildi" "R2 [${base}]: 'kayıtlı parametrelerle yeniden üretildi' DEMEZ (sessiz yeniden üretim yok)"
done
# R3: fm-root --apply sınıf 4'te 'alan KAPATILDI' der, 'yeniden üretildi' demez
reset_all; _on; apply_target 90 tamper; _fmroot; out=$(strip < "$OUTF")
assert_contains "$out" "alan KAPATILDI" "R3: fm-root --apply sınıf 4: 'alan KAPATILDI' der"
assert_not_contains "$out" "kayıtlı parametrelerle yeniden üretildi" "R3: fm-root --apply sınıf 4: 'yeniden üretildi' DEMEZ"
# R4: kontrol — üçü tanınan açık STALE: yeniden üretim iletisi korunur
reset_all; _on; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; _fmroot; out=$(strip < "$OUTF")
assert_contains "$out" "kayıtlı parametrelerle yeniden üretildi" "R4 kontrol: tanınan açık eser bakımı yeniden üretildi iletisini korur"

test_summary
