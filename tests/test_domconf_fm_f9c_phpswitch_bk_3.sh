#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1b — php-switch (sock_sync) sınıf 4 + yarım-işlem yedeği (ARCHITECTURE §15/38): kayıt `on` + 20/21/90'dan biri tanınmıyor — parça 3/3: A[90] + A2 + B + C + D
# (sınıf 4) iken alanın yarım-işlem yedeği (.bk.*) varsa php-switch alanı AÇIK bırakıp "REDDEDİLDİ" demez; mevcut sınıf-4 kapatma
# düzeneğiyle (kurtarma: kayıt OFF sayılır -> yedek geri YÜKLENMEZ, .superseded.; sonra 403 kökü yazımı) 403 köküne kapatır, rc 10.
# Kapatılamazsa rc≠0 + "FM HÂLÂ AÇIK OLABİLİR". >=2 yedek: F9d (§15/43(b)) ile "elle inceleyin" rc≠0 KALIR ama alan da 403 köküne KAPATILIR,
# iki yedek dokunulmadan korunur (eski F9c davranışı: alan kapatılmaz/açılmaz = "belgeli sınır"; ayrıntı: test_domconf_fm_f9d_double_bk.sh).
# Eski tek dosya (152 satır, 114 doğrulama; yüklü makinede 319 sn) 3 bağımsız dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f9c_phpswitch_bk_common.sh. Parçalar: (ad yok) P + A[20], _2 A[21], _3 A[90] + A2 + B + C + D.
# Sınıf 4 DEĞİLKEN: yedek varken soket senkronu REDDEDİLİR (pozitif kontrol).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
# ═══ A. php-switch x {20,21,90 bozuk} x tek yedek türleri: rc 10, 403 kökü, 90/21 yok, kayıt off, çalışan KAPALI, yedek GERİ YÜKLENMEDİ ═══
A_HEDEF=90   # A bölümünün bozulan eser hedefi (tam küme: 20 21 90; her hedef ayrı parçada)
for t in $A_HEDEF; do
    for v in missing tamper symlink unknown unrecorded; do
        for k in none cur good off empty; do
            setup "$t" "$v" "$k"; _phpswitch; rc=$?
            n=0; [[ "$k" == none ]] || n=1
            assert_eq "$rc|$(_shut)|$(_st)|$(_run)|$(_bkn)|$(_supn)" "10|SHUT|off|RUN-CLOSED|0|${n}" "A [${t}/${v} / yedek=${k}]: php-switch sınıf 4: alan kapandı (rc 10), yedek geri yüklenmedi (.superseded=${n})"
            MOCK_BAD_OWNER=""
        done
    done
done
# A2: mesaj — "REDDEDİLDİ" DEMEZ, yedeğin geri yüklenmediğini söyler
setup 90 tamper good; _phpswitch; out=$(strip < "$OUTF")
assert_not_contains "$out" "soket senkronu REDDEDİLDİ" "A2: sınıf 4 + yedek: 'REDDEDİLDİ' DEMEZ"
assert_contains "$out" "GERİ YÜKLENMEDİ" "A2: yedeğin geri yüklenmediği söylenir"

# ═══ B. >=2 yedek (F9d, §15/43(b)): 'elle inceleyin' rc≠0 KALIR; ALAN KAPATILIR (403 kökü, kayıt off, çalışan KAPALI); iki yedek BAYT BAYT aynı ═══
for t in 20 21 90; do
    setup "$t" tamper two
    hb=$(find "$SD" -name '.bk.*' -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "${f##*/}" "$(_md5 "$f")"; done | _md5stdin)
    _phpswitch; rc=$?; out=$(strip < "$OUTF")
    ha=$(find "$SD" -name '.bk.*' -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "${f##*/}" "$(_md5 "$f")"; done | _md5stdin)
    assert_eq "$((rc != 0))|$(_bkn)|$(_supn)|$([[ "$hb" == "$ha" ]] && echo ayni)" "1|2|0|ayni" "B [${t}]: iki yedek: rc≠0, yedekler yerinde ve bayt bayt aynı"
    assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "B [${t}]: iki yedek: alan 403 köküne KAPATILDI (F9d; eskiden açık kalırdı)"
    assert_contains "$out" "elle inceleyin" "B [${t}]: 'elle inceleyin' denir"
    assert_contains "$out" "KAPATILDI" "B [${t}]: alanın KAPATILDIĞI söylenir"
    assert_not_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "B [${t}]: kapatma başarılı: 'FM HÂLÂ AÇIK OLABİLİR' DENMEZ"
done

# ═══ C. kapatılamadı: nginx -t düşer / kilit alınamaz -> rc≠0 + 'FM HÂLÂ AÇIK OLABİLİR'; açık eser diske geri KONMAZ ═══
for k in none good; do
    setup 90 tamper "$k"; NGINX_TEST_RC=1; _phpswitch; rc=$?; NGINX_TEST_RC=0; out=$(strip < "$OUTF")
    assert_eq "$((rc != 0))" "1" "C [nginx -t düşer / yedek=${k}]: rc≠0 (10 DEĞİL)"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "C [nginx -t düşer / yedek=${k}]: dürüst ileti"
    setup 21 tamper "$k"; FLOCK_RC=1; _phpswitch; rc=$?; FLOCK_RC=0; out=$(strip < "$OUTF")
    assert_eq "$((rc != 0))" "1" "C [kilit alınamaz / yedek=${k}]: rc≠0"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "C [kilit alınamaz / yedek=${k}]: dürüst ileti"
done

# ═══ D. (ARCHITECTURE §15/93(b)(2): önceki beklenti "yedek varken soket senkronu REDDEDİLİR, rc 1, yedek yerinde" idi; karar tersine döndü) — sınıf 4 DEĞİL, kayıt
#     'on' + yarım işlem yedeği: php-switch yarım açılışı TAMAMLAMAZ; repair / fm-root gibi önce yedeği KURTARIR (kesinti öncesi hâline geri yükler), sonra yazar. ═══
#     Önceki gerekçe ("yazım bayat yedeği kurtarmayla çelişir") kurtarma yazımdan ÖNCE yapıldığı için korunur; red'in bedeli ise php-switch'in arkasından gelen koşulsuz
#     `nginx -t && reload`'un yarım açılışı çalışan nginx'e YÜKLEMESİYDİ (test_domconf_fm_g13_phpswitch_on_crash.sh: KAPALI → AÇIK).
#     Burada ön durum AÇIK idi (yedek = açık alanın kopyası): kurtarma aynı açık durumu geri koyar, sonra soket senkronu çalışır (alan zaten açıktı; AÇILMAZ ki açık kalır).
for k in cur good; do
    reset_all; _on; _mk_stale_bk AAAAAA; fm_sim_reload
    _phpswitch; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$rc|$(_bkn)|$(_supn)|$(_st)|$(grep -c 'php8.4-fpm' "$F90")" "10|0|0|on|1" "D [sınıf 0 + yedek/${k}]: yedek kurtarıldı (tüketildi), soket senkronu çalıştı (rc 10), kayıt on"
    assert_not_contains "$out" "soket senkronu REDDEDİLDİ" "D [sınıf 0 + yedek/${k}]: artık 'REDDEDİLDİ' denmez"
    assert_not_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "D [sınıf 0 + yedek/${k}]: kurtarma başardı → sınıf-4/kapatılamadı iletisi basılmaz"
done
# D2: kontrol — yedek yok, sınıf 0: soket güncellenir (rc 10)
reset_all; _on; _phpswitch; rc=$?
assert_eq "$rc|$(grep -c 'php8.4-fpm' "$F90")" "10|1" "D2 kontrol: sınıf 0, yedek yok: soket güncellenir (rc 10)"
# D3: kontrol — kayıt KAPALI + yedek: senkron no-op (rc 0), yedeğe dokunmaz
reset_all; _on; _off; _mk_stale_bk AAAAAA; _phpswitch; rc=$?
assert_eq "$rc|$(_bkn)|$(_supn)" "0|1|0" "D3 kontrol: kayıt kapalı + yedek: php-switch no-op, yedeğe dokunmaz"

test_summary
