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

# ─── _audit_parse_active_units — 'systemctl list-units --all --no-legend
# --plain <glob>' METNİNİ parse eder (worker instance keşfi, BULGU kapanışı).
# Yalnız ACTIVE sütunu (3.) 'active' olan unit adları (1. sütun) döner —
# 'failed'/'inactive' instance'lar (ör. eski/çökmüş bir worker) ELENİR: bu
# instance'lar için PID aranıp FAIL üretilmemesi gerekir (çalışmıyor olmaları
# hata DEĞİLDİR).
UNITS="srvctl-worker-example_com@default.service loaded active running srvctl Worker (example.com / default)
srvctl-worker-example_com@stale.service loaded failed failed srvctl Worker (example.com / stale)
srvctl-worker-example_com@queue2.service loaded active running srvctl Worker (example.com / queue2)"

assert_eq "$(_audit_parse_active_units "$UNITS")" \
    "$(printf 'srvctl-worker-example_com@default.service\nsrvctl-worker-example_com@queue2.service')" \
    "yalnız ACTIVE instance'lar döner, failed olan elenir"
assert_eq "$(_audit_parse_active_units "")" "" "boş metin → boş çıktı"
assert_eq "$(_audit_parse_active_units "srvctl-worker-example_com@stale.service loaded failed failed x")" "" \
    "tek satır ve o da failed ise → boş çıktı (hiçbiri aktif değil)"

# ─── _audit_scheduler_enforced — scheduler enforcement KARARI (saf; BULGU
# kapanışı). Scheduler oneshot+timer'dır — servis çoğu zaman ölüdür, bu
# yüzden PID VARSA gerçek attach (attr) tercih edilir, PID YOKSA (normal
# durum) sistem genelindeki aa-status enforce durumuna DOLAYLI bakılır.
SCHED_CLI="srvctl-example_com-cli"
AA_STATUS_ENFORCE="apparmor module is loaded.
1 profiles are loaded.
1 profiles are in enforce mode.
   ${SCHED_CLI}
0 profiles are in complain mode.
0 processes are unconfined"
AA_STATUS_COMPLAIN="apparmor module is loaded.
1 profiles are loaded.
0 profiles are in enforce mode.
1 profiles are in complain mode.
   ${SCHED_CLI}
0 processes are unconfined"

assert_ok   _audit_scheduler_enforced "1" "$(printf '%s (enforce)\n' "$SCHED_CLI")" "" "$SCHED_CLI" \
    "PID var + attr enforce → ok (gerçek attach tercih edilir)"
assert_fail _audit_scheduler_enforced "1" "$(printf '%s (complain)\n' "$SCHED_CLI")" "$AA_STATUS_ENFORCE" "$SCHED_CLI" \
    "PID var + attr complain → fail (aa-status enforce göstermesi FARK ETMEZ — GERÇEK attach esas alınır)"
assert_ok   _audit_scheduler_enforced "0" "" "$AA_STATUS_ENFORCE" "$SCHED_CLI" \
    "PID yok (servis o an ölü — NORMAL) + aa-status enforce → ok (dolaylı doğrulama)"
assert_fail _audit_scheduler_enforced "0" "" "$AA_STATUS_COMPLAIN" "$SCHED_CLI" \
    "PID yok + aa-status complain → fail (profil sessizce complain'e düşmüş)"
assert_fail _audit_scheduler_enforced "0" "" "" "$SCHED_CLI" \
    "PID yok + aa-status metni boş (aa-status hiç çalışmamış/profil hiç yüklü değil) → fail"

# ─── YARIŞ DURUMU DÜZELTMESİ (koordinatör bulgusu) — çağıranın
# (_check_worker_aa/_check_scheduler_aa) attr BOŞ geldiğinde has_pid=0 İLE
# çağırdığını doğrular: "PID yakalandı ama attr okunamadı" (yarış) artık
# has_pid=1+attr="" OLARAK DEĞİL, has_pid=0 OLARAK modellenir — yani
# doğrudan _audit_aa_attr_enforced'a DÜŞMEZ, dolaylı aa-status'e gider.
assert_ok   _audit_scheduler_enforced "0" "" "$AA_STATUS_ENFORCE" "$SCHED_CLI" \
    "[YARIŞ] PID yakalandı ama attr boş geldiğinde çağıran has_pid=0 verir → aa-status enforce ile ok (FAIL DEĞİL)"
assert_fail _audit_scheduler_enforced "0" "" "$AA_STATUS_COMPLAIN" "$SCHED_CLI" \
    "[YARIŞ] aynı durum ama aa-status complain → hâlâ fail (dolaylı doğrulama sessiz kaybı YİNE yakalar)"

# ─── _audit_fpm_isolation_verdict — FPM izolasyon KARARI (saf; koordinatör
# bulgusu: audit bir domainin paylaşılan havuzda mı izole unit'te mi
# çalıştığını hiç kontrol etmiyordu). Girdi: <config_exists> <unit_active>
# <isolated_setting>. Çıktı: PASS|WARN|FAIL.
assert_eq "$(_audit_fpm_isolation_verdict "1" "1" "true")"  "PASS" \
    "config var + unit aktif → PASS (izolasyon setting'den BAĞIMSIZ — gerçek izolasyon zaten var)"
assert_eq "$(_audit_fpm_isolation_verdict "1" "1" "false")" "PASS" \
    "config var + unit aktif → PASS (DOMAIN_ISOLATED_FPM=false olsa BİLE fiilen izole çalışıyorsa ödüllendirilir)"
assert_eq "$(_audit_fpm_isolation_verdict "0" "0" "true")"  "FAIL" \
    "paylaşılan havuzda + DOMAIN_ISOLATED_FPM=true (varsayılan) → FAIL (sessiz sapma — izolasyon başarısız/hiç denenmemiş)"
assert_eq "$(_audit_fpm_isolation_verdict "0" "0" "false")" "WARN" \
    "paylaşılan havuzda + DOMAIN_ISOLATED_FPM=false (AÇIKÇA ayarlanmış) → WARN (bilinçli operatör tercihi, FAIL DEĞİL ama görünmez de DEĞİL)"
assert_eq "$(_audit_fpm_isolation_verdict "1" "0" "true")"  "FAIL" \
    "config VAR ama unit AKTİF DEĞİL → FAIL sayılır (yarı-izolasyon, gerçek MAC attach YOK)"
assert_eq "$(_audit_fpm_isolation_verdict "0" "1" "true")"  "FAIL" \
    "config YOK ama unit bir şekilde aktif (anomali) → FAIL sayılır (config kalıcı değil, restart'ta kaybolur)"
assert_eq "$(_audit_fpm_isolation_verdict "1" "0" "false")" "WARN" \
    "yarı-izolasyon + DOMAIN_ISOLATED_FPM=false → yine WARN (bilinçli tercih sinyali FAIL'i her koşulda bastırır)"

rm -rf "$WEB_ROOT"
test_summary
