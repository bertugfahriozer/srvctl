#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9d/dev — ARCHITECTURE §15/43(a): 20/21/90 adlı yol yerinde DİZİN (isdir) ise srvctl YENİ bir taşıma/silme mekanizması EKLEMEZ (yabancı nesne
# otomatik taşınmaz/silinmez/üzerine yazılmaz); kapatma yolu YÜKSEK SESLE başarısız olur: rc≠0, ileti "FM HÂLÂ AÇIK OLABİLİR" (aynen) ve
# sonraki `status` TAMPERED ve rc≠0 verir. Eski ağaçta (d0de1c0e) rc≠0 + TAMPERED zaten vardı ama ileti YALNIZ php-switch yolundaydı;
# repair / toplu repair / fm-root / fm-root --all / provision HAM `cp: … is a directory (not copied)` + genel "onarılamadı" / "sahneleme BAŞARISIZ"
# diyordu ("FM HÂLÂ AÇIK OLABİLİR" YOK). 'nginx -t' kırıkken (gerçek nginx dizini *.conf glob'unda pread() EISDIR ile reddeder) davranış aynıdır:
# sahneleme reddi 'nginx -t'den ÖNCE olur.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

source "${REPO_ROOT}/tests/fm_f9d_isdir_common.sh"

# ═══ A. kayıt ON: 20/21/90 yerinde DİZİN x nginx -t {sağlam, kırık} x yollar (kayıt off kolu: test_domconf_fm_f9d_isdir_loud_off.sh) ═══
isdir_matrix on

# ═══ B. KONTROL: dizin YOK, kurcalanmış 90 DOSYASI: alan normal kapanır, 'FM HÂLÂ AÇIK OLABİLİR' BASILMAZ ═══
for path in repair83 fmroot provision; do
    reset_all; _on; printf '# kurcalandi\n' >> "$F90"; fm_sim_reload
    runpath "$path"; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$rc|$(_shut)|$(_st)" "0|SHUT|off" "B [${path}]: kurcalanmış 90 (dizin değil): alan kapanır (rc 0)"
    assert_not_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "B [${path}]: dizin yokken alarm iletisi basılmaz"
done

test_summary
