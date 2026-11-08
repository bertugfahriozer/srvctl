#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9d/dev — (kayıt OFF kolu) ARCHITECTURE §15/43(a): 20/21/90 adlı yol yerinde DİZİN (isdir) ise srvctl YENİ bir taşıma/silme mekanizması EKLEMEZ (yabancı nesne
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

# ═══ A. kayıt OFF: 20/21/90 yerinde DİZİN x nginx -t {sağlam, kırık} x yollar (php-switch kayıt off iken no-op: atlanır) ═══
isdir_matrix off

# ═══ C. BİRİM: _domconf_fm_stage_dir_report ═══
reset_all; _on
d="${CUR_DIR}/dizin.conf"; mkdir "$d"
out=$(strip < <(_domconf_fm_stage_dir_report example.com off "$d" 2>&1))
assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "C1: kapatma yönü (off) + dizin: 'FM HÂLÂ AÇIK OLABİLİR'"
assert_contains "$out" "taşımaz, silmez, üzerine yazmaz" "C1: yeni taşıma/silme mekanizması olmadığı söylenir"
out=$(strip < <(_domconf_fm_stage_dir_report example.com on "$d" 2>&1))
assert_not_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "C2: açma yönü (on) + dizin: 'AÇIK OLABİLİR' DENMEZ (yazım reddi)"
assert_contains "$out" "yerinde DİZİN" "C2: yine de nedeni söyler"
out=$(_domconf_fm_stage_dir_report example.com off "$F20" 2>&1)
assert_eq "$out" "" "C3: dizin DEĞİL (normal dosya): sessiz"
ln -s "$d" "${CUR_DIR}/bag.conf"
out=$(_domconf_fm_stage_dir_report example.com off "${CUR_DIR}/bag.conf" 2>&1)
assert_eq "$out" "" "C4: dizine sembolik bağ: bu rapor işlevi sessiz (bağ ayrı sınıf)"
out=$(_domconf_fm_stage_dir_report example.com off "${CUR_DIR}/yok.conf" 2>&1)
assert_eq "$out" "" "C5: olmayan yol: sessiz"

test_summary
