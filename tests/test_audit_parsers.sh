#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

AA="apparmor module is loaded.
3 profiles are loaded.
2 profiles are in enforce mode.
   /usr/sbin/php-fpm8.3
   srvctl-example_com
1 profiles are in complain mode.
   srvctl-other_com
0 processes are unconfined"

assert_ok   _audit_aa_enforced "$AA" "srvctl-example_com"   "enforce'da → ok"
assert_fail _audit_aa_enforced "$AA" "srvctl-other_com"     "complain'de → fail"
assert_fail _audit_aa_enforced "$AA" "srvctl-yok_com"       "yok → fail"

assert_ok   _audit_seccomp_filtered "$(printf 'Name:\tphp-fpm8.3\nSeccomp:\t2\n')"  "Seccomp 2 → ok"
assert_fail _audit_seccomp_filtered "$(printf 'Seccomp:\t0\n')"                     "Seccomp 0 → fail"
assert_fail _audit_seccomp_filtered "$(printf 'Name:\tx\n')"                        "Seccomp satırı yok → fail"

assert_ok   _audit_in_slice "/srvctl.slice/srvctl-example_com.slice/srvctl-fpm-example_com.service" "srvctl-example_com.slice" "slice içinde → ok"
assert_fail _audit_in_slice "/system.slice/php8.3-fpm.service" "srvctl-example_com.slice"            "slice değil → fail"

# ─── _audit_aa_attr_enforced — /proc/<pid>/attr/current İLK SATIRI ───
# '_audit_aa_enforced' (aa-status GENEL listesi — "sistemde BİR YERDE bu
# profil enforce" sorusu) İLE TAMAMLAYICI: bu fonksiyon kernel'in SPESİFİK
# bir PID için raporladığı GERÇEK attach'ı doğrular (paylaşılan/per-domain-
# olmayan bir FPM master'da profil aa-status'te enforce görünse bile O PID
# ona hiç BAĞLI olmayabilir — 'unconfined' döner).
assert_ok   _audit_aa_attr_enforced "$(printf 'srvctl-example_com (enforce)\n')" "srvctl-example_com" "attr: enforce + doğru profil → ok"
assert_fail _audit_aa_attr_enforced "$(printf 'srvctl-example_com (complain)\n')" "srvctl-example_com" "attr: complain modu → fail"
assert_fail _audit_aa_attr_enforced "$(printf 'unconfined\n')" "srvctl-example_com" "attr: unconfined (profile hiç attach değil) → fail"
assert_fail _audit_aa_attr_enforced "$(printf 'srvctl-other_com (enforce)\n')" "srvctl-example_com" "attr: enforce ama YANLIŞ profil → fail"
assert_ok   _audit_aa_attr_enforced "$(printf 'srvctl-example_com (enforce)\nfp8.3\nextra\n')" "srvctl-example_com" "attr: yalnız İLK satır dikkate alınır (sonraki satırlar göz ardı)"
assert_fail _audit_aa_attr_enforced "" "srvctl-example_com" "attr: boş metin → fail"
assert_fail _audit_aa_attr_enforced "$(printf 'srvctl-example_com(enforce)\n')" "srvctl-example_com" "attr: profil/parantez arası boşluk EKSİKSE (biçim tam uymuyorsa) → fail"

rm -rf "$WEB_ROOT"
test_summary
