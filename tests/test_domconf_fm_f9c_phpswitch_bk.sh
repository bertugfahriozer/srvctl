#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9c/a1b — php-switch (sock_sync) sınıf 4 + yarım-işlem yedeği (ARCHITECTURE §15/38): kayıt `on` + 20/21/90'dan biri tanınmıyor — parça 1/3: P ön koşul + A[20]
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
# ═══ P. ön koşul: bozulan eser sınıf 4 verir ═══
for t in 20 21 90; do
    for v in missing tamper unknown; do
        setup "$t" "$v" none; _fmprov_load example_com
        assert_eq "$_FMP_STATE|$_FMP_EMERGENCY" "off|4" "P [${t}/${v}]: kayıt on + ${t} ${v}: sınıf 4"
        MOCK_BAD_OWNER=""
    done
done

# ═══ A. php-switch x {20,21,90 bozuk} x tek yedek türleri: rc 10, 403 kökü, 90/21 yok, kayıt off, çalışan KAPALI, yedek GERİ YÜKLENMEDİ ═══
A_HEDEF=20   # A bölümünün bozulan eser hedefi (tam küme: 20 21 90; her hedef ayrı parçada)
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

test_summary
