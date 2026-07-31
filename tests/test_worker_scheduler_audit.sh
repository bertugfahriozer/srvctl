#!/bin/bash
# Worker/scheduler '-cli' profili AppArmor audit'i — entegrasyon/wiring testleri.
#
# BULGU (denetim): 'security audit' worker/scheduler süreçlerinin AppArmor
# profilini HİÇ kontrol etmiyordu ('grep -n "worker\|scheduler"
# lib/security.sh' sıfır sonuç veriyordu). '-cli' profili worker/scheduler
# için TEK gerçek MAC kısıtıdır (CLI SAPI'de disable_functions UYGULANMAZ).
# Bu dosya, lib/security.sh'a eklenen kontrolün (_audit_unit_mainpid,
# _audit_domain_active_worker_units, _check_worker_aa, _check_scheduler_aa)
# GERÇEK ÇAĞRI/KARAR AKIŞINI 'systemctl' (ve gerekirse 'aa-status') stub'larıyla
# doğrular.
#
# KAPSAM SINIRI (macOS geliştirme makinesi): '/proc/<pid>/attr/current'
# yalnız gerçek Linux+AppArmor HOST'unda vardır. lib/security.sh bu yolu
# artık '_audit_proc_attr_path()' ÜZERİNDEN okur — SRVCTL_PROC_DIR test-seam'i
# (SRVCTL_SYSTEMD_DIR/SRVCTL_FPM_DIR ile AYNI desen) sayesinde bu dosyada
# GERÇEK '/proc' okuması yerine fixture bir dizin kullanılabiliyor; bu da
# "PID bulundu + attr enforce/complain/boş" dallarının ÜÇÜNÜN de macOS'ta
# TAM doğrulanmasını sağlıyor (aşağıda §5/§6). Scheduler'ın PID-yok (asıl/
# normal durum) dalı zaten 'aa-status'a (harici komut, bash fonksiyonu
# olarak stub'lanabilir) DOLAYLI düşüyor.
#
# YARIŞ DURUMU DÜZELTMESİ (koordinatör bulgusu, gerçek VM ölçümüyle
# doğrulandı): PID yakalanıp attr okunmaya çalışılırken süreç TAM ARADA
# ölebilir (scheduler oneshot'ta <1sn çalışıyor, worker'da Restart=
# on-failure ile yeniden başlarken dar bir pencere). Düzeltmeden ÖNCE bu,
# attr'ı BOŞ bırakıp doğrudan FAIL üretiyordu — 100 domain sıralı
# denetlenirken HER audit koşusunda rastgele bir domaine sahte FAIL düşme
# olasılığı ihmal edilebilir değildi. §5/§6 bu ayrımı ("attr hiç okunamadı"
# → FAIL DEĞİL/dolaylıya düş, "attr okundu ve enforce DEĞİL" → GERÇEK FAIL)
# kilitler.
#
# HOST'TA AYRICA DOĞRULANMASI GEREKENLER (bu dosyanın KAPSAMI DIŞINDA):
#   - Birden fazla worker instance'ı (ör. 'default' + 'queue2') aynı anda
#     koşarken HER İKİSİNİN de ayrı ayrı denetlendiği.
#   - Gerçek bir worker/scheduler süreci yeniden başlarken (Restart=
#     on-failure) yarış durumunun GERÇEKTEN tetiklendiği (burada yalnız
#     fixture'la SİMÜLE ediliyor).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

SNAME="example_com"

# ═══════════════════════════════════════════════════════════════
#  1) _audit_unit_mainpid — systemctl stub ile
# ═══════════════════════════════════════════════════════════════
systemctl() {
    case "$*" in
        "show -p MainPID --value srvctl-worker-${SNAME}@default.service") echo "4242" ;;
        "show -p MainPID --value srvctl-worker-${SNAME}@dead.service")    echo "0" ;;
        "show -p MainPID --value srvctl-scheduler-${SNAME}.service")      echo "" ;;
        *) echo "" ;;
    esac
}
assert_eq "$(_audit_unit_mainpid "srvctl-worker-${SNAME}@default.service")" "4242" \
    "_audit_unit_mainpid: MainPID doğru dönüyor"
assert_fail _audit_unit_mainpid "srvctl-worker-${SNAME}@dead.service" \
    "_audit_unit_mainpid: MainPID=0 → fail (unit çalışmıyor demektir)"
assert_fail _audit_unit_mainpid "srvctl-scheduler-${SNAME}.service" \
    "_audit_unit_mainpid: MainPID boş → fail (unit çalışmıyor demektir)"

# ═══════════════════════════════════════════════════════════════
#  2) _audit_domain_active_worker_units — systemctl list-units stub ile
# ═══════════════════════════════════════════════════════════════

# senaryo A: worker HİÇ başlatılmamış (her domain kuyruk kullanmaz — NORMAL)
systemctl() { :; }   # list-units boş çıktı + rc=0 döner
assert_fail _audit_domain_active_worker_units "$SNAME" \
    "hiç worker instance'ı yoksa → fail (NORMAL durum, worker kullanılmıyor)"
out="$(_audit_domain_active_worker_units "$SNAME" 2>/dev/null || true)"
assert_eq "$out" "" "hiç worker instance'ı yoksa çıktı boş"

# senaryo B: bir aktif ('default'), bir failed ('stale') instance
systemctl() {
    if [[ "$1" == "list-units" ]]; then
        cat <<EOF
srvctl-worker-${SNAME}@default.service loaded active running srvctl Worker (example.com / default)
srvctl-worker-${SNAME}@stale.service loaded failed failed srvctl Worker (example.com / stale)
EOF
    fi
}
assert_ok _audit_domain_active_worker_units "$SNAME" \
    "en az bir aktif instance varsa → ok"
out="$(_audit_domain_active_worker_units "$SNAME")"
assert_eq "$out" "srvctl-worker-${SNAME}@default.service" \
    "yalnız ACTIVE instance döner, failed('stale') olan ELENİR"

# glob domain.sh'taki İSİM ŞEMASIYLA (srvctl-worker-<sname>@*.service,
# _domain_worker'daki unit_glob ile AYNI) BİREBİR eşleşmeli — aksi halde
# audit HİÇBİR instance'ı bulamaz (sessiz tespit boşluğu geri döner).
# NOT: 'systemctl' stub'ı '_audit_domain_active_worker_units' içinde bir
# KOMUT İKAMESİ ('$(...)') altında çağrılır — bu bir ALT KABUKTUR (bkz.
# CLAUDE.md bash tuzakları: 'cmd | while read' ile AYNI sınıf). Stub İÇİNDE
# doğrudan bir DEĞİŞKENE yazmak (captured_call="$*") ALT KABUKTA kalır ve
# ana test script'ine SIZMAZ — bu yüzden bir DOSYAYA yazıyoruz (dosya G/Ç'si
# alt kabuk sınırını aşar).
glob_capture_file="$(mktemp)"
systemctl() { [[ "$1" == "list-units" ]] && printf '%s\n' "$*" > "$glob_capture_file"; }
_audit_domain_active_worker_units "$SNAME" >/dev/null 2>&1 || true
assert_contains "$(cat "$glob_capture_file" 2>/dev/null || true)" "srvctl-worker-${SNAME}@*.service" \
    "worker glob'u domain.sh unit_glob şemasıyla TAM eşleşiyor"
rm -f "$glob_capture_file"

# ═══════════════════════════════════════════════════════════════
#  3) _check_worker_aa — pass/fail/warn callback sayaçları
#     (_security_run_check ile AYNI explicit-injection deseni; _security_audit
#     hiç çalıştırılmadan doğrudan test edilir)
# ═══════════════════════════════════════════════════════════════
pass_n=0; fail_n=0; warn_n=0
_t_pass() { pass_n=$((pass_n + 1)); }
_t_fail() { fail_n=$((fail_n + 1)); }
_t_warn() { warn_n=$((warn_n + 1)); }

# (a) worker HİÇ ÇALIŞMIYOR → PASS/FAIL/WARN ÜRETİLMEZ (kritik BULGU şartı:
#     "worker hiç çalışmıyorsa FAIL ÜRETMEZ" — burada FAIL DAHİL HİÇBİRİ yok).
systemctl() { :; }
pass_n=0; fail_n=0; warn_n=0
_check_worker_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 0" \
    "worker hiç aktif değilse _check_worker_aa PASS/FAIL/WARN üretmez (NORMAL)"

# (b) worker AKTİF ama MainPID alınamıyor (anomali) → WARN (FAIL DEĞİL) —
#     bu dal /proc'a HİÇ ULAŞMADAN 'devam et' kararını verir, macOS'ta da
#     tam doğrulanabilir.
systemctl() {
    if [[ "$1" == "list-units" ]]; then
        echo "srvctl-worker-${SNAME}@default.service loaded active running x"
    elif [[ "$1" == "show" ]]; then
        echo ""   # MainPID alınamadı
    fi
}
pass_n=0; fail_n=0; warn_n=0
_check_worker_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 1" \
    "worker aktif ama PID okunamıyorsa WARN üretir (FAIL değil — anomali, henüz kanıt yok)"

# ═══════════════════════════════════════════════════════════════
#  4) _check_scheduler_aa — pass/fail/warn callback sayaçları
# ═══════════════════════════════════════════════════════════════

# (a) scheduler timer HİÇ AKTİF DEĞİL → PASS/FAIL/WARN ÜRETİLMEZ (NORMAL).
systemctl() { [[ "$1" == "is-active" ]] && return 1; return 0; }
pass_n=0; fail_n=0; warn_n=0
_check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 0" \
    "scheduler timer aktif değilse PASS/FAIL/WARN üretilmez (NORMAL — çoğu domain zamanlayıcı kullanmaz)"

# (b) timer AKTİF + servis o an ÖLÜ (has_pid=0, asıl/normal senaryo — oneshot
#     dakikada bir tetiklenir) + aa-status YOK (macOS'ta gerçekten yok, ayrı
#     bir stub'a gerek duymadan doğal olarak test edilir) → WARN.
if ! command -v aa-status >/dev/null 2>&1; then
    systemctl() {
        case "$1" in
            is-active) return 0 ;;   # timer aktif
            show)      echo "" ;;    # servis PID'i yok (o an ölü)
        esac
    }
    pass_n=0; fail_n=0; warn_n=0
    _check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
    assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 0 1" \
        "timer aktif + servis ölü + aa-status YOK → doğrulanamadı (WARN), FAIL DEĞİL"
else
    echo "  SKIP: bu ortamda GERÇEK bir aa-status ikili dosyası var — 'aa-status yok' dalı test edilemiyor"
fi

# (c) timer AKTİF + servis o an ÖLÜ (has_pid=0) + aa-status STUB'landı
#     (bash fonksiyonu — 'command -v' bunu da bulur) + profil ENFORCE → PASS.
#     Bu dal /proc'a HİÇ dokunmaz (PID zaten yok) — macOS'ta TAM doğrulanır.
aa-status() {
    cat <<'EOF'
apparmor module is loaded.
1 profiles are loaded.
1 profiles are in enforce mode.
   srvctl-example_com-cli
0 profiles are in complain mode.
0 processes are unconfined
EOF
}
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        show)      echo "" ;;
    esac
}
pass_n=0; fail_n=0; warn_n=0
_check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "1 0 0" \
    "timer aktif + servis ölü + aa-status enforce → PASS (dolaylı doğrulama)"

# (d) AYNI durum ama profil COMPLAIN modda → FAIL (kritik BULGU şartı:
#     "complain olan FAIL üretir").
aa-status() {
    cat <<'EOF'
apparmor module is loaded.
1 profiles are loaded.
0 profiles are in enforce mode.
1 profiles are in complain mode.
   srvctl-example_com-cli
0 processes are unconfined
EOF
}
pass_n=0; fail_n=0; warn_n=0
_check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 1 0" \
    "timer aktif + servis ölü + aa-status complain → FAIL (sessiz güvenlik kaybı artık SESSİZ DEĞİL)"

unset -f aa-status

# ═══════════════════════════════════════════════════════════════
#  5) YARIŞ DURUMU DÜZELTMESİ — _check_scheduler_aa (koordinatör bulgusu,
#     gerçek VM ölçümüyle doğrulandı). SRVCTL_PROC_DIR test-seam'i ile
#     GERÇEK bir '/proc/<pid>/attr/current' fixture'ı kurulup PID
#     '_audit_unit_mainpid'ten DÖNERKEN, attr dosyası ÜÇ farklı durumda
#     test edilir: (a) hiç yok (yarış — süreç kayboldu), (b) enforce,
#     (c) complain. Bu, DAHA ÖNCE HOST-only sayılan "PID bulundu" dalını
#     macOS'ta da TAM doğrulanabilir kılıyor.
# ═══════════════════════════════════════════════════════════════
PROC_DIR="$(mktemp -d)"
export SRVCTL_PROC_DIR="$PROC_DIR"

# (5a) PID YAKALANDI ama attr dosyası HİÇ YOK (yarış — süreç tam o an
#      bitti/kayboldu) + aa-status ENFORCE → FAIL DEĞİL (aksine PASS —
#      dolaylı doğrulamaya geri çekilir). BU, DÜZELTMEDEN ÖNCE mevcut
#      kodda FAIL ÜRETEN TAM SENARYODUR (mutasyon testiyle aşağıda ayrıca
#      doğrulanır).
rm -rf "${PROC_DIR:?}"/*
aa-status() { printf '1 profiles are in enforce mode.\n   srvctl-example_com-cli\n'; }
systemctl() {
    case "$1" in
        is-active) return 0 ;;                # timer aktif
        show)      echo "9101" ;;              # PID YAKALANDI (attr dosyası fixture'da YOK)
    esac
}
pass_n=0; fail_n=0; warn_n=0
_check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "1 0 0" \
    "[YARIŞ] scheduler: PID var + attr dosyası YOK (okunamadı) → FAIL ÜRETMEZ, dolaylıya (aa-status enforce) düşüp PASS verir"

# (5b) AYNI PID yakalama + attr dosyası GERÇEKTEN VAR ve içinde 'complain'
#      yazıyor → GERÇEK KANIT var, bu yüzden FAIL doğru sonuçtur (aksi
#      halde her şeyi dolaylıya kaçırıp gerçek complain'i de KAÇIRIRDIK).
mkdir -p "${PROC_DIR}/9102/attr"
printf 'srvctl-example_com-cli (complain)\n' > "${PROC_DIR}/9102/attr/current"
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        show)      echo "9102" ;;
    esac
}
pass_n=0; fail_n=0; warn_n=0
_check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 1 0" \
    "[YARIŞ] scheduler: PID var + attr OKUNDU ve complain → GERÇEK bulgu, FAIL üretir"

# (5c) AYNI PID yakalama + attr dosyası GERÇEKTEN VAR ve 'enforce' yazıyor
#      → GERÇEK KANIT + doğru profil → PASS (artık HOST'a gerek kalmadan
#      macOS'ta da doğrulanabiliyor).
mkdir -p "${PROC_DIR}/9103/attr"
printf 'srvctl-example_com-cli (enforce)\n' > "${PROC_DIR}/9103/attr/current"
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        show)      echo "9103" ;;
    esac
}
pass_n=0; fail_n=0; warn_n=0
_check_scheduler_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "1 0 0" \
    "[YARIŞ] scheduler: PID var + attr OKUNDU ve enforce → GERÇEK kanıt, PASS üretir"

unset -f aa-status

# ═══════════════════════════════════════════════════════════════
#  6) YARIŞ DURUMU DÜZELTMESİ — _check_worker_aa (AYNI mantık, worker
#     uzun ömürlü olduğundan pencere daha dar ama Restart=on-failure ile
#     aynı duruma düşebilir — koordinatörün AÇIKÇA istediği ikinci fonksiyon).
# ═══════════════════════════════════════════════════════════════
rm -rf "${PROC_DIR:?}"/*

# (6a) worker AKTİF, PID YAKALANDI ama attr dosyası HİÇ YOK (yarış) +
#      aa-status ENFORCE → FAIL DEĞİL, PASS (dolaylı doğrulama).
aa-status() { printf '1 profiles are in enforce mode.\n   srvctl-example_com-cli\n'; }
systemctl() {
    if [[ "$1" == "list-units" ]]; then
        echo "srvctl-worker-${SNAME}@default.service loaded active running x"
    elif [[ "$1" == "show" ]]; then
        echo "9201"   # PID YAKALANDI (attr dosyası fixture'da YOK)
    fi
}
pass_n=0; fail_n=0; warn_n=0
_check_worker_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "1 0 0" \
    "[YARIŞ] worker: PID var + attr dosyası YOK (okunamadı) → FAIL ÜRETMEZ, dolaylıya (aa-status enforce) düşüp PASS verir"

# (6b) AYNI PID yakalama + attr dosyası GERÇEKTEN VAR ve 'complain' →
#      GERÇEK bulgu, FAIL üretir.
mkdir -p "${PROC_DIR}/9202/attr"
printf 'srvctl-example_com-cli (complain)\n' > "${PROC_DIR}/9202/attr/current"
systemctl() {
    if [[ "$1" == "list-units" ]]; then
        echo "srvctl-worker-${SNAME}@default.service loaded active running x"
    elif [[ "$1" == "show" ]]; then
        echo "9202"
    fi
}
pass_n=0; fail_n=0; warn_n=0
_check_worker_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "0 1 0" \
    "[YARIŞ] worker: PID var + attr OKUNDU ve complain → GERÇEK bulgu, FAIL üretir"

# (6c) AYNI PID yakalama + attr dosyası GERÇEKTEN VAR ve 'enforce' → PASS.
mkdir -p "${PROC_DIR}/9203/attr"
printf 'srvctl-example_com-cli (enforce)\n' > "${PROC_DIR}/9203/attr/current"
systemctl() {
    if [[ "$1" == "list-units" ]]; then
        echo "srvctl-worker-${SNAME}@default.service loaded active running x"
    elif [[ "$1" == "show" ]]; then
        echo "9203"
    fi
}
pass_n=0; fail_n=0; warn_n=0
_check_worker_aa _t_pass _t_fail _t_warn "example.com" "$SNAME"
assert_eq "${pass_n} ${fail_n} ${warn_n}" "1 0 0" \
    "[YARIŞ] worker: PID var + attr OKUNDU ve enforce → GERÇEK kanıt, PASS üretir"

unset -f aa-status
unset SRVCTL_PROC_DIR
rm -rf "$PROC_DIR"

rm -rf "$WEB_ROOT"
test_summary
