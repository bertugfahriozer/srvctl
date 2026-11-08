#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e-5 — ARCHITECTURE §15/51(a): `fm-auth <alan> on` geri alması (_domconf_fm_on_unwind_locked) KENDİSİ de başarısız olursa
# (geri almanın 'apply off'undaki nginx -t düşer) alan KAPALI bırakılır: error'dan ÖNCE acil kapatma işareti yazılır, disk acil
# kapatma yoluyla kapatılır ve _domconf_fm_fail_restore açık eseri geri koyamaz. Eski ağaçta (114e016f) disk AÇIK + kayıt 'on' + işaret
# YOK kalır; ardından repair (PHP kayması) / php-switch bunu tanınan açık eser sayıp reload ederdi (çalışan nginx AÇILIR).
# Altı otomatik yol (repair, repair84, php-switch, fm-root, fm-root --all, provision) sonrasında hem disk hem canlı mock AÇIK DEĞİL.
# S1b bölümü: _domconf_fm_tx_commit sonundaki sinyal tuzağı kaldırma ile reload arasındaki pencere (bkz. dosya sonu).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

CNT="${FM_STUBS}/f9e5_cnt"
# 2. canlı 'nginx -t' (geri almanın 'apply off'u) düşer; 1. (açan komutun kendi -t'si) geçer.
_hook_second_t_fails() {
    [[ "$NGINX_T_ARGS" == "-t" ]] || return 0
    local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT"
    if (( n >= 2 )); then NGINX_TEST_RC=1; fi
}
has9021() { if [[ -e "$F90" || -L "$F90" || -e "$F21" || -L "$F21" ]]; then echo VAR; else echo YOK; fi; }
em() { if [[ -e "${SD}/example_com.emergency" || -e "${ALTD}/example_com.emergency" ]]; then echo ISARET; else echo ISARETSIZ; fi; }
# alan "açık değil": diskte 90/21 yok, 20 = 403 kökü, çalışan mock AÇIK imzası taşımıyor
not_open() { printf '%s|%s|%s' "$(_shut)" "$(has9021)" "$(_run)"; }

# ═══ A. reload BAŞARISIZ + geri alma nginx -t BAŞARISIZ: altı yol sonrasında alan AÇIK DEĞİL ═══
for follow in repair repair84 phpswitch fmroot fmrootall provision; do
    reset_all; rm -f "$CNT"
    SYSTEMCTL_RC=1; NGINX_T_HOOK=_hook_second_t_fails
    _on; rc=$?
    SYSTEMCTL_RC=0; NGINX_T_HOOK=""; NGINX_TEST_RC=0
    out=$(strip < "$OUTF")
    assert_eq "$rc" "1" "A[$follow] 1: geri alma da düştü → 'on' tam rc 1 (4 = açıldı/doğrulanamadı değil)"
    assert_contains "$out" "açılış GERİ ALINAMADI (geri alma rc=" "A[$follow] 2: ileti 'açılış GERİ ALINAMADI (geri alma rc=<n>)' der"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "A[$follow] 3: ileti yüksek sesli"
    assert_not_contains "$out" "fm-auth AÇILDI" "A[$follow] 4: 'AÇILDI' denmez"
    assert_contains "$out" "geri alma sonrası example.com: çalışan durum" "A[$follow] 4b: geri almanın kendi yedeği işaretli alan sayıldı → geri alma sonrası kapanış/çalışan durum doğrulaması yapıldı (işaret geri almadan ÖNCE kondu)"
    assert_contains "$out" "acil kapatma işareti yazıldı" "A[$follow] 4c: ileti işaretin yazıldığını söyler"
    assert_contains "$out" "disk acil kapatma yoluyla KAPATILDI" "A[$follow] 4d: ileti diskin acil yoldan kapatıldığını söyler"
    assert_eq "$(em)" "ISARET" "A[$follow] 5: error'dan ÖNCE acil kapatma işareti yazıldı"
    assert_eq "$(_shut)|$(has9021)" "SHUT|YOK" "A[$follow] 6: disk acil kapatma yoluyla KAPATILDI (20 = 403 kökü, 90/21 yok)"
    assert_eq "$(_bkn)" "0" "A[$follow] 7: yarım işlem yedeği sızmadı"
    case "$follow" in
        repair) runpath repairall ;;
        *)      runpath "$follow" ;;
    esac
    arc=$?
    if [[ "$follow" == "repair84" || "$follow" == "phpswitch" ]]; then
        # PHP kayması yolları reload eder: eski ağaçta açılışı tamamlayan tam bunlardı
        assert_not_contains "$(_run)" "RUN-OPEN" "A[$follow] 8: PHP kayması yolu çalışan nginx'i AÇMADI"
    fi
    assert_eq "$(not_open)" "SHUT|YOK|$(_run)" "A[$follow] 9: otomatik yol sonrası disk AÇIK DEĞİL (90/21 yok)"
    assert_not_contains "$(_run)" "RUN-OPEN" "A[$follow] 10: otomatik yol sonrası canlı mock AÇIK DEĞİL"
    assert_not_contains "$(strip < "$OUTF")" "fm-auth AÇILDI" "A[$follow] 11: otomatik yol 'AÇILDI' demez"
done

# ═══ B. aynı çifte hata, 'probe' kolu: reload tamam, sonda KESİN kapalı (403) → geri alma → -t düşer ═══
for follow in repair84 phpswitch fmroot provision; do
    reset_all; rm -f "$CNT"
    FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; NGINX_T_HOOK=_hook_second_t_fails
    _on; rc=$?
    NGINX_T_HOOK=""; NGINX_TEST_RC=0; FM_PROBE_MODE=sim
    out=$(strip < "$OUTF")
    assert_eq "$rc" "1" "B[$follow] 1: sonda kolunda da çifte hata → rc 1"
    assert_contains "$out" "açılış GERİ ALINAMADI (geri alma rc=" "B[$follow] 2: ileti geri alınamadığını söyler"
    assert_eq "$(em)|$(_shut)|$(has9021)" "ISARET|SHUT|YOK" "B[$follow] 3: işaret yazıldı, disk kapatıldı"
    # probe kolunda reload başarılıydı: canlı mock zaten AÇIK imzasında (çalışan durumu düzeltmek 'off --emergency'nin işi; ileti bunu söyler).
    # Otomatik yol onu açık BIRAKABİLİR ama yeniden AÇMAZ: sonrası ya kapalı ya da öncekiyle aynı.
    pre_run=$(_run)
    runpath "$follow"
    case "$(_run)" in RUN-CLOSED|"$pre_run") r4=ok ;; *) r4="$(_run)" ;; esac
    assert_eq "$r4" "ok" "B[$follow] 4: otomatik yol canlı mock'u yeni AÇMADI (önce=${pre_run})"
    assert_eq "$(_shut)|$(has9021)" "SHUT|YOK" "B[$follow] 5: otomatik yol sonrası disk AÇIK DEĞİL"
done

# ═══ C. alan komuttan ÖNCE AÇIKTI (prev=on) + geri alma da düşer: yine kapatılır, ileti sürer ═══
reset_all; _on; fm_sim_reload; rm -f "$CNT"
SYSTEMCTL_RC=1; NGINX_T_HOOK=_hook_second_t_fails
_on; rc=$?
SYSTEMCTL_RC=0; NGINX_T_HOOK=""; NGINX_TEST_RC=0
out=$(strip < "$OUTF")
assert_eq "$rc|$(em)|$(_shut)|$(has9021)" "1|ISARET|SHUT|YOK" "C1: önceden-açık alanda çifte hata → rc 1, işaret, disk kapalı"
assert_contains "$out" "açılış GERİ ALINAMADI (geri alma rc=" "C2: ileti"
runpath phpswitch
assert_eq "$(_shut)|$(has9021)" "SHUT|YOK" "C3: php-switch sonrası disk AÇIK DEĞİL"

# ═══ D. işaret, geri alma BAŞARILI iken kalmaz (ön işaret off kaydıyla temizlenir) ═══
reset_all; SYSTEMCTL_RC=1; _on; rc=$?; SYSTEMCTL_RC=0
assert_eq "$rc|$(em)|$(_st)|$(_shut)" "1|ISARETSIZ|off|SHUT" "D1: yalnız reload hatası (geri alma başarılı) → işaret KALMAZ, kayıt off, disk kapalı"
_on; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "0|OPEN|on" "D2: nginx düzelince açık 'on' yeniden AÇAR (işaret kalıcı kilit bırakmadı)"

# ═══ E. işaret varken otomatik yol kayıt 'on' + açık eseri yeniden açmaz (sınıf 1) — çifte hata sonrası açık 'on' serbest ═══
reset_all; rm -f "$CNT"
SYSTEMCTL_RC=1; NGINX_T_HOOK=_hook_second_t_fails; _on; SYSTEMCTL_RC=0; NGINX_T_HOOK=""; NGINX_TEST_RC=0
assert_eq "$(em)" "ISARET" "E önkoşul: işaret var"
_on; rc=$?
assert_eq "$rc|$(_shut)|$(_st)|$(em)" "0|OPEN|on|ISARETSIZ" "E1: yalnız AÇIK 'fm-auth on' alanı yeniden açar ve işareti kaldırır (§15/33)"

# ═══ G. geri alma SAHNELEMEDE düşer (yedek hiç alınmaz → fail_restore çalışmaz, hiçbir şey geri yüklenmez/kapatılmaz) ═══
# Disk açılış commit'inden AÇIK kalır, kayıt 'on'. Yalnız error'dan önceki açık işaret + acil kapatma bunu kapatır (savunma derinliği).
orig_stage=$(declare -f _domconf_fm_stage)
eval "_f9e5_orig_stage() ${orig_stage#*()}"
_domconf_fm_stage() { if [[ "$3" == "off" && -n "${F9E5_FAIL_OFF_STAGE:-}" ]]; then return 4; fi; _f9e5_orig_stage "$@"; }
for follow in repair84 phpswitch fmroot provision; do
    reset_all; F9E5_FAIL_OFF_STAGE=1; SYSTEMCTL_RC=1
    _on; rc=$?
    F9E5_FAIL_OFF_STAGE=""; SYSTEMCTL_RC=0
    out=$(strip < "$OUTF")
    assert_eq "$rc" "1" "G[$follow] 1: geri alma sahnelemede düştü → rc 1"
    assert_contains "$out" "açılış GERİ ALINAMADI (geri alma rc=4)" "G[$follow] 2: ileti geri alma rc=4'ü söyler"
    assert_eq "$(em)|$(_shut)|$(has9021)" "ISARET|SHUT|YOK" "G[$follow] 3: yedek/geri yükleme olmasa da işaret yazıldı ve disk KAPATILDI"
    runpath "$follow"
    assert_eq "$(_shut)|$(has9021)" "SHUT|YOK" "G[$follow] 4: otomatik yol sonrası disk AÇIK DEĞİL"
    assert_not_contains "$(_run)" "RUN-OPEN" "G[$follow] 5: otomatik yol canlı mock'u AÇMADI"
done
eval "$orig_stage"

# ═══ F. commit ile reload arasında sinyal (INT/TERM/HUP) ═══
# _domconf_fm_tx_commit eskiden son satırında sinyal tuzağını kaldırıyordu; `systemctl reload nginx` tuzaksız koşuyordu. Bu pencerede gelen
# TERM/HUP (SSH kopması) açan süreci öldürürdü: disk AÇIK + kayıt 'on' + işaret YOK + çalışan nginx hiç yüklenmemiş — başarısız bir açılışın
# (reload düştü, geri alma düştü) bıraktığı ara durumun AYNISI; sonraki repair / php-switch bunu tamamlayıp alanı açardı. Tuzak artık reload
# BİTENE kadar ':' olarak kalır (yok sayma değil: çocuk süreçlere miras kalmaz); sinyal yutulur, açılış kendi dalıyla sonuçlanır.
SIGPID="${FM_STUBS}/f9e5_sigpid"; SIGFLAG="${FM_STUBS}/f9e5_sigflag"
eval "_f9e5_orig_systemctl() $(declare -f systemctl | sed '1d')"
_f9e5_sig_systemctl() {
    if [[ "$1" == "reload" && -n "${SIGN:-}" && ! -e "$SIGFLAG" ]]; then
        : > "$SIGFLAG"
        hs_signal_ancestor "$SIGN" "$KILL_TARGET"
    fi
    _f9e5_orig_systemctl "$@"
}
_on_sig() {   # _on_sig <SİNYAL>: açan süreç (alt kabuk) ilk reload'a girerken sinyal alır
    ( sh -c 'echo $PPID > "$0"' "$SIGPID"; KILL_TARGET=$(cat "$SIGPID"); SIGN="$1"; systemctl() { _f9e5_sig_systemctl "$@"; }
      _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1
}
for sg in TERM HUP INT; do
    reset_all; rm -f "$SIGFLAG"
    _on_sig "$sg"; rc=$?
    out=$(strip < "$OUTF")
    assert_eq "$([[ -e "$SIGFLAG" ]] && echo gonderildi || echo YOK)" "gonderildi" "F[$sg] 0: sinyal reload penceresinde gerçekten gönderildi"
    assert_eq "$rc|$(_st)|$(_shut)" "0|on|OPEN" "F[$sg] 2: açılış kendi dalıyla sonuçlandı (reload yapıldı, kayıt on, disk açık)"
    assert_eq "$(_run)" "RUN-OPEN" "F[$sg] 3: reload sinyalden sonra da tamamlandı (çalışan mock AÇIK = kayıtla tutarlı; yarım ara durum yok)"
    assert_eq "$(em)" "ISARETSIZ" "F[$sg] 4: işaret/yedek kalıntısı yok"
    assert_eq "$(_bkn)" "0" "F[$sg] 5: yarım işlem yedeği sızmadı"
done
# tuzak reload SONRASINDA kalkar (':' çağırana sızmaz): açan komutun dönüşünde INT/TERM/HUP tuzağı yok
reset_all; ( _domconf_fm_auth example.com on "--script=${SCRIPT}" >/dev/null 2>&1; echo "TRAPS=[$(trap -p INT TERM HUP)]" ) >"$OUTF" 2>&1
assert_eq "$(grep -a '^TRAPS=' "$OUTF")" "TRAPS=[]" "F7: 'on' döndükten sonra sinyal tuzağı KALMAZ (reload bitince temizlendi)"
# reload BAŞARISIZ olsa da tuzak temizlenir (rc 5 dalı da tuzak sızdırmaz)
reset_all; SYSTEMCTL_RC=1; ( _fmprov_with_lock _domconf_fm_apply example.com example_com on eu "$SCRIPT" "${DEFAULT_PHP_VERSION}" 0 1 >/dev/null 2>&1; echo "RC=$?"; echo "TRAPS=[$(trap -p INT TERM HUP)]" ) >"$OUTF" 2>&1; SYSTEMCTL_RC=0
assert_eq "$(grep -a '^RC=' "$OUTF")|$(grep -a '^TRAPS=' "$OUTF")" "RC=5|TRAPS=[]" "F8: reload başarısız (rc 5) → tuzak yine temizlenir"
# kontrol: tuzak YOKKEN aynı sinyal süreci öldürür (ölçüm düzeneği geçerli; eski davranış)
( sh -c 'echo $PPID > "$0"' "$SIGPID"; KILL_TARGET=$(cat "$SIGPID"); hs_signal_ancestor TERM "$KILL_TARGET"; echo SURDU ) >"$OUTF" 2>&1
assert_eq "$(grep -ac SURDU "$OUTF" || true)" "0" "F9: kontrol — tuzaksız alt kabuk TERM ile ölür (düzenek, tuzağın gerçekten işi olduğunu gösterir)"
test_summary
