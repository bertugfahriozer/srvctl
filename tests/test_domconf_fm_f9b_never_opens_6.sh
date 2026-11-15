#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9b/a1 — §15/33 "OTOMATİK YOLLAR ASLA AÇMAZ" ilkesi (mock; bu ilkeye özgü gerçek-nginx dosyası YOK — gerçek nginx kapsamı test_domconf_fm_f9_real.sh ve test_domconf_fm_probe_real.sh'ta; burada davranış mock'ta, kapalı yön), parça 6/7: C kontrol + D status + E geri alma + F idempotans
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
# ═══ C. KONTROL: TANINAN açık eser üzerinde bakım açık durumu KORUR (açmaz ama kapatmaz) ═══
reset_all; _on; _repair 8.4; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(grep -c 'php8.4-fpm' "$F90")" "0|varvar|on|1" "C1: tanınan açık + PHP kayması: repair soketi günceller, alan AÇIK kalır"
reset_all; _on; _phpswitch; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(grep -c 'php8.4-fpm' "$F90")" "10|varvar|on|1" "C2: tanınan açık + php-switch: soket güncellenir (rc 10), alan AÇIK kalır"
reset_all; _on; _fmroot; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_run)" "0|varvar|on|RUN-OPEN" "C3: tanınan açık + sağlam: fm-root dokunmaz"
reset_all; _on; rm -f "$F21"; _fmroot; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)" "0|yokyok|off" "C4 (F9c §15/38 TERSİNE): tanınan açık 20 + 21 eksik: yeniden ÜRETİLMEZ, alan KAPANIR (eskiden: yeniden üretilir, açık korunur)"
reset_all; _on; printf '# kurcalandi\n' >> "$F90"; _repair 8.3; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)" "0|yokyok|off" "C5 (F9c §15/38 TERSİNE): tanınan açık 20 + 90 kurcalanmış: yeniden ÜRETİLMEZ, alan KAPANIR (eskiden: kayıtlı parametrelerle yeniden üretilir, açık korunur)"
# C6: 20'nin özeti kayıtta (eski şablon) ama güncel render'dan farklı (STALE): tanınan eser, bakım açık durumu korur
reset_all; _on; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"; _fmroot; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)" "0|varvar|on" "C6: tanınan açık 20 + bayat (STALE) şablon: yeniden üretilir, açık durum korunur"
# C7: açan TEK yol açık 'fm-auth on' (tanınmayan 20 üzerinde bile, tüm kapılardan geçerse)
reset_all; _on; unrec garbage; rm -f "$F20"; _on; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)" "0|varvar|on" "C7: AÇAN tek yol: açık 'fm-auth on' (kullanıcı kararı)"
# C8: açık 'on' sonrası otomatik yollar açık durumu bozmaz (kapı: emsal doğrulama)
reset_all; _on; unrec fake_proxy; _fmroot; _on; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_run)" "0|varvar|on|RUN-OPEN" "C8: tanınmayan kök kapatıldı; sonra açık 'fm-auth on' alanı yeniden AÇAR (tek yol)"

# ═══ D. status: TAMPERED/doğrulanamadı raporlar, yalnız AÇIK 'fm-auth on' (ya da kayıt eşitleme 'off') önerir, 'fm-root --apply' önermez ═══
for v in missing20 fake_proxy fake_proxy9021 badsig garbage empty symlink open_tamper open_foreign closed_with9021 gone; do
    reset_all; _on; unrec "$v"; MOCK_BAD_OWNER=""
    out=$( ( _domconf_fm_auth example.com status ) 2>&1 ); src=$?; out=$(strip <<< "$out")
    assert_contains "$out" "TAMPERED" "D status [${v}]: TAMPERED der"
    assert_contains "$out" "TANINMAYAN AÇIK ESER" "D status [${v}]: tanınmayan açık eseri adıyla raporlar"
    assert_not_contains "$out" "srvctl domain fm-root example.com --apply" "D status [${v}]: alanı etkileyen 'fm-root --apply' ÖNERİLMEZ"
    assert_contains "$out" "fm-auth example.com on --script" "D status [${v}]: yalnız AÇIK 'fm-auth on' açar diye söyler"
    assert_eq "$((src != 0))" "1" "D status [${v}]: rc≠0"
done
# D3: çekirdek durum yükleminin kendisi sınıf 4'te rc 1 verir (genel status rc'si sonda/proof kollarıyla da ≠ 0 olabilir: çekirdek ayrı sınanır)
reset_all; _on; unrec fake_proxy
( _domconf_fm_auth_status_core example.com example_com "$CUR_DIR" ) >"$OUTF" 2>&1; crc=$?
assert_eq "$crc" "1" "D3 status çekirdeği: kayıt on + tanınmayan 20 → rc 1"
# D2: kuru plan (fm-root bayraksız) alanı AÇACAK bir iş ÖNERMEZ; hiçbir şey yazmaz
reset_all; _on; unrec fake_proxy; before=$(_md5 "$F20")
out=$( ( _domconf_fm_root_cmd example.com ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "AÇILMAZ" "D2 kuru plan: alanın AÇILMAYACAĞINI söyler"
assert_eq "$(_md5 "$F20")" "$before" "D2 kuru plan: diske yazmaz"

# ═══ E. geri alma: kapatma (403 kökü) nginx -t'de düşerse ön durum geri konur (kimlik); YENİ açık üretilmez ═══
for v in garbage fake_proxy; do
    reset_all; _on; unrec "$v"; NGINX_TEST_RC=1; _repair 8.3; NGINX_TEST_RC=0
    # F9b/a3 (BLOKER-1): ön durum AÇIK/belirsiz (garbage: 90/21 duruyor; fake_proxy: proxy_pass) ve tanınan srvctl eseri DEĞİL → geri alma
    # onu diske GERİ KOYMAZ; disk 403 köküyle kapalı kalır (önceki beklenti: ön durum aynen geri konur = AÇIK sahte kök).
    assert_eq "$(_shut)|$(_exists "$F90")|$(_exists "$F21")" "SHUT|yok|yok" "E [${v}]: nginx -t düşünce AÇIK/belirsiz tanınmayan ön durum geri KONMAZ, disk 403 köküyle kapalı kalır"
    assert_eq "$(grep -c 'auth_request' "$F20")" "0" "E [${v}]: tanınmayan 20 'açık şablona' ÇEVRİLMEDİ"
done

# ═══ F. her yol sonrası iki-aşamalı kayıt tutarlı: kayıt off, imza 403 kökü, bir sonraki repair sağlam (idempotent) ═══
reset_all; _on; unrec fake_proxy; _fmroot; _repair 8.4; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "0|SHUT|off" "F: kapatılmış alanda tekrar repair idempotent (yeniden AÇMAZ)"
reset_all; _on; unrec fake_proxy; _fmroot; out=$( ( _domconf_fm_root_cmd example.com ) 2>&1 ); out=$(strip <<< "$out")
assert_contains "$out" "sağlam: KAPALI" "F: kapatıldıktan sonra fm-root planı 'sağlam: KAPALI' der"

test_summary
