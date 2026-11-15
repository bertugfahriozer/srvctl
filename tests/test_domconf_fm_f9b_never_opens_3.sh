#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9b/a1 — §15/33 "OTOMATİK YOLLAR ASLA AÇMAZ" ilkesi (mock; bu ilkeye özgü gerçek-nginx dosyası YOK — gerçek nginx kapsamı test_domconf_fm_f9_real.sh ve test_domconf_fm_probe_real.sh'ta; burada davranış mock'ta, kapalı yön), parça 3/7: A bölümü, sınıflar 9-11 (nul … open_badowner)
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
# ═══ A. sınıf x yol: kayıt `on` + TANINMAYAN 20 → hiçbir otomatik yol AÇIK üretmez ═══
for v in $CLASSES_3; do
    for path in $PATHS; do
        reset_all; _on; unrec "$v"
        runpath "$path"
        assert_eq "$(_shut)|$(_st)|$(_run)" "SHUT|off|RUN-CLOSED" "A [${v} / ${path}]: 403 kökü yazıldı, 90/21 yok, kayıt off, çalışan KAPALI (KD-YOL-AÇTI = 0)"
        MOCK_BAD_OWNER=""
    done
done

test_summary
