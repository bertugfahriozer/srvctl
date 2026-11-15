#!/bin/bash
# _cron_profile_loaded: 'aa-status | grep -q' kalıbı pipefail altında SIGPIPE YARIŞIDIR (F2b, M6 ile aynı sınıf).
#
# Neden: grep -q ilk eşleşmede çıkar; aa-status hâlâ yazıyorsa (çok profilli bir sunucuda
# çıktı tek tamponu aşar) SIGPIPE ile ölür → boru hattı 141 → YÜKLÜ profil "yok" sanılır
# (yanlış-negatif). Cron ön denetimi "profil yüklü değil" derse güvenlik sandbox'ı yanlışlıkla
# atlanır/yanlış raporlanır. Düzeltme: çıktı önce DEĞİŞKENE alınır, grep ayrı çalışır.
#
# Bu test: (1) NEGATİF KONTROL — eski kalıp aynı sahte aa-status ile yanlış-negatif ÜRETİR
# (test duyarlı), (2) gerçek işlev N denemede SIFIR yanlış-negatif verir, (3) olmayan profil
# 1 döner (pozitif yön), (4) securityfs dosyası yolu bozulmadı.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"; export SRVCTL_ROOT
log_action() { :; }
source "${REPO_ROOT}/lib/cron.sh"
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PROFILE="srvctl-example_com-cli"
# Sahte aa-status: ilk sırada aranan profil, ardından 400 satır (her biri AYRI yazma → SIGPIPE hedefi)
{ echo '#!/bin/bash'
  echo 'echo "apparmor module is loaded."'
  echo "echo \"   ${PROFILE}\""
  for i in $(seq 1 400); do echo "echo \"   srvctl-dolgu_${i}_com-cli dolgu dolgu dolgu dolgu dolgu dolgu dolgu dolgu\""; done
} > "${TMP}/aa-status"
chmod +x "${TMP}/aa-status"
export PATH="${TMP}:${PATH}"
export SRVCTL_AA_PROFILES_FILE="${TMP}/yok-securityfs"   # okunamaz → aa-status dalı
N=${RACE_N:-300}

old_fn=0; new_fn=0
for ((i = 0; i < N; i++)); do
    # ESKİ kalıp (satır satır aynı): borulu grep -q, pipefail açık
    if aa-status 2>/dev/null | grep -q -- "$PROFILE"; then :; else old_fn=$((old_fn + 1)); fi
    _cron_profile_loaded "$PROFILE"; [[ $? -eq 0 ]] || new_fn=$((new_fn + 1))
done
echo "  N=${N}: ESKİ kalıp yanlış-negatif=${old_fn}  YENİ _cron_profile_loaded yanlış-negatif=${new_fn}"
assert_eq "$([[ $old_fn -gt 0 ]] && echo yarisvar || echo yarisyok)" "yarisvar" "NEGATİF KONTROL: eski borulu kalıp bu sahte aa-status ile yanlış-negatif ÜRETİR (test duyarlı)"
assert_eq "$new_fn" "0" "YENİ _cron_profile_loaded: ${N} denemede 0 yanlış-negatif (yüklü profil her zaman bulunur)"

_cron_profile_loaded "srvctl-yok_com-cli"; assert_eq "$?" "1" "yüklü OLMAYAN profil → 1 (pozitif yön korunur)"
# Not: eşleşme alt dizgedir (grep -- "$profile") — davranış değişmedi.
PF="${TMP}/profiles"; printf 'srvctl-example_com-cli (enforce)\n' > "$PF"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-example_com-cli"; assert_eq "$?" "0" "securityfs dosyası yolu: yüklü profil → 0"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-yok_com-cli"; assert_eq "$?" "1" "securityfs dosyası yolu: olmayan profil → 1"
# QL3-M6: securityfs dosyası yolundaki '^' ÇAPASI ve sondaki boşluk (profil adı TAM eşleşmeli;
# '^' kaldırılırsa alt dizge/sonek/önek eşleşmeleri "yüklü" sayılırdı → sahte yeşil).
printf 'xsrvctl-example_com-cli (enforce)\n' > "$PF"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-example_com-cli"; assert_eq "$?" "1" "çapa: ÖNEKLİ ad ('xsrvctl-…') yüklü SAYILMAZ"
printf '  srvctl-example_com-cli (enforce)\n' > "$PF"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-example_com-cli"; assert_eq "$?" "1" "çapa: satır başı boşluklu ad yüklü SAYILMAZ"
printf 'srvctl-example_com-cli-baska (enforce)\n' > "$PF"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-example_com-cli"; assert_eq "$?" "1" "çapa+boşluk: SONEKLİ ad ('…-cli-baska') yüklü SAYILMAZ"
printf 'baska\nsrvctl-example_com-cli (enforce)\n' > "$PF"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-example_com-cli"; assert_eq "$?" "0" "ikinci satırdaki tam ad yüklü SAYILIR (pozitif yön)"
printf 'srvctl-example_com-cli(enforce)\n' > "$PF"
SRVCTL_AA_PROFILES_FILE="$PF" _cron_profile_loaded "srvctl-example_com-cli"; assert_eq "$?" "1" "ad ile parantez arasında boşluk YOKSA tam ad değil"
# yapısal: '^' çapası kodda duruyor (konum bağımsız, yorum-dışı satırda)
body="$(declare -f _cron_profile_loaded)"
assert_contains "$body" 'grep -q "^${profile} " "$pf"' "securityfs yolunda '^<profil> ' çapalı grep"
# Yapısal kilit: işlevde borulu 'aa-status | grep' kalmadı
body="$(declare -f _cron_profile_loaded)"
assert_not_contains "$body" "aa-status 2>/dev/null | grep" "işlev gövdesinde borulu 'aa-status | grep -q' YOK"
assert_contains "$body" 'aa_out=$(aa-status' "çıktı önce değişkene alınıyor"

test_summary
