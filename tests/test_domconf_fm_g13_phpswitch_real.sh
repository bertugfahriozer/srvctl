#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# 'fm-auth on' kesintisinden sonra php-switch yarım açılışı TAMAMLAMAZ — GERÇEK nginx 1.28 laboratuvarında (ARCHITECTURE §15/93(b)(2)). nginx ya da curl YOKSA bu dosya ATLANIR.
# YALNIZ 127.0.0.1:19300–19399, geçici prefix; dış ağa istek YOK.
# Kapalı 403 kökünden (gerçek nginx 403 "srvctl-fm-closed <imza>" verir) başlayan normal `on` K. adımda (reload çağrısı dahil) SIGKILL ile ölür; ardından php-switch akışı
# (soket senkronu + koşulsuz `nginx -t && systemctl reload nginx`, domain.sh'deki gibi) koşar. Eskiden K=10–14 (yedek duruyor, kayıt on, disk açık) gerçek nginx'i KAPALI → AÇIK
# yapıyordu; şimdi gerçek nginx KAPALI kalır. Kabul edilmiş AÇIK-KORUNDU (kayıt on + disk TAM açık + yedek yok: `on` yalnız reload'u eksik) ölçüt dışıdır.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_phpswitch_bk_common.sh"
source "${REPO_ROOT}/tests/fm_g13_crash_common.sh"
source "${REPO_ROOT}/tests/fm_g13_real_common.sh"
set +e
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
g13_real_skip_if_missing
trap 'g13_lab_down; rm -rf "${G13_T:?}"; _fm_env_cleanup' EXIT
if ! g13_lab_up; then echo "  FAIL lab açılamadı"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); test_summary; exit 1; fi
KFROM="${G13_KFROM:-1}"; KTO="${G13_KTO:-99}"

g13_real_reset; G13_RELOAD_REAL=1
( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1
assert_eq "$(_shut)|$(_st)|$(g13_real_state)" "SHUT|off|REAL-CLOSED" "0a: 403 kökü kuruldu, gerçek nginx KAPALI imzası verir"
g13_snap_save rootreal
echo 0 > "$G13_CNT"; G13_K=-1; ( g13_on ) >"$OUTF" 2>&1; G13_K=0; NSTEPS=$(g13_steps)
assert_ne "$NSTEPS" "0" "0b: on adım sayacı çalışıyor (${NSTEPS} adım, reload dahil)"
assert_eq "$(g13_real_state)" "REAL-OPEN" "0c: kesintisiz on: gerçek nginx AÇIK"
(( KTO > NSTEPS )) && KTO=$NSTEPS

phpswitch_real() {   # domain.sh akışı: soket senkronu, sonra (sonucundan bağımsız) koşulsuz nginx -t + reload
    ( fm_rc=0; _domconf_fm_auth_sock_sync example.com 8.4 || fm_rc=$?
      case "$fm_rc" in
          0) ;;
          10) if [[ "${_DOMCONF_FM_SWITCH_CLOSED:-0}" == "1" ]]; then echo "fm-auth alanı KAPATILDI (403 kökü)"; else echo "fm-auth soketi php8.4'e çekildi"; fi ;;
          *) echo "fm-auth soketi güncellenemedi" ;;
      esac
      nginx -t >/dev/null 2>&1 && systemctl reload nginx
      exit "$fm_rc" ) >"$OUTF" 2>&1
    PSRC=$?
}

echo "── A: SIGKILL K=${KFROM}…${KTO} × php-switch, GERÇEK nginx ──"
for (( K = KFROM; K <= KTO; K++ )); do
    g13_real_restore rootreal; G13_RELOAD_REAL=1; systemctl reload nginx
    g13_killed "$K" g13_on; KRC=$?
    PRE="$(_shut)|$(_st)|bk=$(_bkn)|gerçek=$(g13_real_state)"
    if [[ "$(g13_real_state)" == "REAL-OPEN" ]]; then continue; fi   # ölüm reload'dan SONRA: alan kayıtlı olarak açık
    if [[ "$(_shut)|$(_st)|$(_bkn)" == "OPEN|on|0" ]]; then
        assert_eq "$KRC" "137" "A K=${K}: (kayıt on + disk tam açık + yedek yok: kabul edilmiş AÇIK-KORUNDU; ölçüt dışı) ölüm gerçekleşti"
        continue
    fi
    phpswitch_real
    assert_eq "$(g13_real_state)" "REAL-CLOSED" "A K=${K} [php-switch]: ölüm sonrası ${PRE} → rc ${PSRC}: gerçek nginx KAPALI kalır (yarım açılış yüklenmedi)"
done

test_summary
