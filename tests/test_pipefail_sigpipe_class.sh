#!/bin/bash
# SIGPIPE/pipefail yarış SINIFI: 'üretici | grep -q' / '| head' / '| sed q' / '| awk exit' / '| read'
# pipefail altında, tüketici erken çıkınca üreticiyi SIGPIPE ile öldürür → boru hattı 141 →
# "var" olan şey "yok" sanılır (güvenlik denetiminde YANLIŞ-NEGATİF).
#
# QL3-M6 sonrası YENİDEN YAZILDI. Eski izin listesi satırda alt dizge arıyor, yalnız
# '| grep -<harfler>q' biçimini tarıyordu → 'grep -E -q', '--quiet', satır sonu boru, '|&', '| head',
# yorumdaki izinli sözcük kaçıyordu. Şimdi:
#   A) tarayıcı (tests/lib_pipescan.awk) bash SÖZCÜK kurallarına yakın belirteçleyicidir;
#      KENDİSİ vektör fixture'larıyla sınanır (pozitif VE negatif);
#   B) depodaki TÜM erken-çıkışlı boru hatları DEĞİŞMEZ, gerekçeli bir izin listesine
#      (dosya|üretici|operatör|tüketici → adet) bağlanır; hem yeni bulgu hem bayat girdi kırmızıdır;
#   C) davranış: çıktı değişkene alınan işlevler büyük girdide yanlış-negatif vermez.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
WEB_ROOT="$(mktemp -d)"; SRVCTL_NGINX_CUSTOM_DIR="$(mktemp -d)"
SRVCTL_PHP_INI_DIR="$(mktemp -d)"; SITES_AVAILABLE="$(mktemp -d)"
export WEB_ROOT SRVCTL_NGINX_CUSTOM_DIR SRVCTL_PHP_INI_DIR SITES_AVAILABLE
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"; export SRVCTL_ROOT
log_action() { :; }
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/security.sh"
source "${REPO_ROOT}/lib/cron.sh"
set +e
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SCAN="${REPO_ROOT}/tests/lib_pipescan.awk"
scan_text() { printf '%s\n' "${1//§/$'\n'}" > "${TMP}/probe.sh"; awk -f "$SCAN" -v FN=probe "${TMP}/probe.sh"; }   # § = satır sonu
count_text() { scan_text "$1" | wc -l | tr -d ' '; }

echo "── A: tarayıcı sondaları — POZİTİF (erken çıkışlı tüketici BULUNMALI) ──"
while IFS= read -r probe; do
    [[ -z "$probe" ]] && continue
    assert_eq "$(count_text "$probe")" "1" "bulunur: ${probe}"
done <<'PROBES'
x | grep -q y
x | grep -E -q y
x | grep -qE y
x | grep -Eq y
x | grep -xq -- y
x | grep --quiet y
x | grep --silent y
x | grep -m1 y
x | grep --max-count=1 y
x | grep -l y
x |& grep -q y
x |& head -n1
x | head
x | head -1
x | head -c 16
x | sed 1q
x | sed -n '/a/{p;q}'
x | awk '{print; exit}'
x | read -r a
x | cmp -s - f
x | diff -q - f
x | "grep" "-q" y
x | 'grep' '-q' y
x | command grep -q y
x | env LC_ALL=C grep -q y
x | LC_ALL=C grep -q y
x | /usr/bin/grep -q y
x | /bin/head -1
if x | grep -q y; then :; fi
if ! x | grep -q y; then :; fi
a=$(x | grep -q y)
a=$(x | head -1)
{ x | grep -q y; }
(x | grep -q y)
x | y | grep -q z
x | grep -q -e a -e b
x | egrep -q y
x | zgrep -q y
x | rg -q y
x |\§  grep -q y
x | \§  grep -q y
x \§  | grep -q y
x |§  grep -q y
x |&§  head -1
x |  §grep -q y
x &&§  y | head -1
PROBES

echo "── A2: tarayıcı sondaları — NEGATİF (bulunMAMALI) ──"
while IFS= read -r probe; do
    [[ -z "$probe" ]] && continue
    assert_eq "$(count_text "$probe")" "0" "bulunmaz: ${probe}"
done <<'PROBES'
x | grep -v y
x | grep y
x | grep -E y
x | grep -c y
x | grep -n y
x | grep -o y
x | grep -F -- -q
# x | grep -q y
x # | grep -q y
echo "a | grep -q"
echo 'x | head'
echo "x | head -1" > f
x || grep -q y
x && head -1
x; head -1
x 2>&1 | tee f
x | tee f
x | sort
a=$(cat f | sort)
grep -q y <<< "$z"
x | awk '{print $1}'
x | sed 's/a/b/'
x | sed -n '1,5p'
x | tr -d '\n'
x | wc -l
x | cat
x | cut -d: -f1
f() { grep -q y "$1"; }
x > /dev/null 2>&1 && grep -q y
[[ "$a" =~ (b|head) ]]
case "$a" in b|c) : ;; esac
PROBES
# yorumda "izinli" sözcük: eski tarayıcının alt dizge izin listesini yanıltırdı; yeni tarayıcı yorumu görmez
assert_eq "$(count_text 'x | grep -q y   # bash -c ss -lxH echo "$cron" |')" "1" "yorum satır sonunda: gerçek boru yine bulunur (izinli sözcük muaf ETMEZ)"
assert_eq "$(count_text 'x | grep -q "bash -c"')" "1" "tırnak içindeki izinli sözcük muaf ETMEZ"
assert_eq "$(count_text 'bash -c "x | grep -q y"')" "0" "tırnak içindeki boru bulunmaz (bash -c içi ayrı sözcük akışı: bilinen sınır, izin listesinde gerekçeli)"

echo "── B: depodaki TÜM erken-çıkışlı boru hatları DEĞİŞMEZ izin listesinde ──"
# Anahtar: dosya|üretici|operatör|tüketici → adet (operatör: P = '|', PA = '|&'). Satır numarası YOKTUR
# (kayma bozmaz).
# GEREKÇELER (her biri ayrı; yeni bir örnek eklenirse test kırmızı olur ve gözden geçirilir):
#  - $(...) içinde, KÜÇÜK ve SINIRLI çıktı: tüketici çıkmadan üretici yazımını bitirir (boru tamponu 64K ≫ çıktı)
#    ya da çıktı zaten tek satırdır (rate/resource profil satırı, redis INFO, ss tek soket, cron satırı).
#  - echo "$var" | grep -q : echo yerleşik komuttur, tek write; $var (crontab/cron) birkaç KB.
#  - tr|cmp -s (domconf.sh NUL denetimi): girdi 32 KiB tavanından ÖNCE sınırlanır (< boru tamponu).
#  - sort|head (monitor.sh): insan okunur rapor; sonuç güvenlik kararı DEĞİL.
#  - cloudflare/deploy/user/status/core 'head': değer seçimi (ilk eleman), güvenlik denetimi DEĞİL.
ALLOW='lib/cloudflare.sh|jq -r|P|head=1
lib/core.sh|tr -d|P|head=1
lib/core.sh|grep -v|P|head=2
lib/core.sh|REDISCLI_AUTH=$redis_admin_pass redis-cli|P|grep -m1=1
lib/core.sh|redis-cli INFO|P|grep -m1=1
lib/core.sh|systemctl list-units|P|grep -q=1
lib/deploy.sh|grep -rl|P|head=1
lib/deploy.sh|_deploy_release_ids $releases|P|head=1
lib/domain.sh|mysql -N|P|grep -qx=1
lib/domconf.sh|LC_ALL=C tr|P|cmp -s=1
lib/init.sh|echo $crontab_content|P|grep -q=5
lib/init.sh|echo $cron|P|grep -q=2
lib/monitor.sh|sort -rn|P|head=3
lib/security.sh|ss -lxH|P|grep -q=2
lib/status.sh|ls -td|P|head=1
lib/user.sh|base32|P|head=1'
# gerçek bulgular → "dosya|üretici|op|tüketici" say
real=""
for f in "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}/bin/srvctl" "${REPO_ROOT}/install.sh"; do
    rel="${f#"${REPO_ROOT}"/}"
    real+="$(awk -f "$SCAN" -v FN="$rel" "$f")"$'\n'
done
total=$(printf '%s' "$real" | grep -c .)
assert_eq "$([[ $total -ge 20 ]] && echo yeterli || echo az)" "yeterli" "tarama gerçekten bulgu üretiyor (toplam=${total}; boş-çıktı sahte yeşili olmasın)"
got=$(printf '%s\n' "$real" | grep . | awk -F'\t' '{ split($1, a, ":"); f=a[1]; p=$1; sub(/^[^:]*:[0-9]+:/, "", p); op=($2 == "|&") ? "PA" : "P"; print f "|" p "|" op "|" $3 }' | sort | uniq -c | awk '{c=$1; $1=""; sub(/^ /,""); print $0 "=" c}' | sort)
want=$(printf '%s\n' "$ALLOW" | sort)
echo "$got" > "${TMP}/got.txt"; echo "$want" > "${TMP}/want.txt"
new=$(comm -13 "${TMP}/want.txt" "${TMP}/got.txt")
stale=$(comm -23 "${TMP}/want.txt" "${TMP}/got.txt")
assert_eq "$new" "" "izin listesi DIŞI erken-çıkışlı boru hattı YOK"
assert_eq "$stale" "" "izin listesinde BAYAT girdi YOK (kaldırılan/değişen site)"

echo "── B2: güvenlik yolu dosyalarında izin listesi dışı bulgu SIFIR ──"
for f in lib/domconf.sh lib/cron.sh lib/security.sh lib/nginx_allow.sh; do
    [[ -f "${REPO_ROOT}/${f}" ]] || continue
    c=$(awk -f "$SCAN" -v FN="$f" "${REPO_ROOT}/${f}" | wc -l | tr -d ' ')
    case "$f" in
        lib/domconf.sh)  exp=1 ;;   # tr|cmp -s (32 KiB sınırlı NUL denetimi)
        lib/security.sh) exp=2 ;;   # ss -lxH | grep -q . (tek soket çıktısı)
        *)               exp=0 ;;
    esac
    assert_eq "$c" "$exp" "${f}: beklenen erken-çıkışlı boru sayısı (${exp})"
done

echo "── B3: eski tarayıcının kör noktaları — cron.sh/domain.sh/domconf.sh'ta 'aa-status | grep' YOK ──"
for f in lib/cron.sh lib/domain.sh lib/security.sh lib/domconf.sh; do
    c=$(awk -f "$SCAN" -v FN="$f" "${REPO_ROOT}/${f}" | grep -c 'aa-status')
    assert_eq "$c" "0" "${f}: 'aa-status | <erken çıkışlı>' yok"
done

echo "── C: davranış — çıktı değişkene alınan işlevler büyük girdide yanlış-negatif vermez ──"
for fn in _cron_profile_loaded _domain_aa_profile_loaded _audit_aa_attr_enforced; do
    body="$(declare -f "$fn")"
    assert_not_contains "$body" "| grep" "${fn}: borulu grep yok"
    assert_not_contains "$body" "| head" "${fn}: '| head' yok"
done
BIG="srvctl-example_com (enforce)"$'\n'"$(seq 1 20000 | sed 's/.*/dolgu satiri &/')"
n=0; for ((i = 0; i < 200; i++)); do _audit_aa_attr_enforced "$BIG" srvctl-example_com || n=$((n + 1)); done
assert_eq "$n" "0" "_audit_aa_attr_enforced: 200 denemede 0 yanlış-negatif (20000 satırlık metin)"
_audit_aa_attr_enforced "unconfined"$'\n'"x" srvctl-example_com; assert_eq "$?" "1" "unconfined → 1 (pozitif yön korunur)"
_audit_aa_attr_enforced "srvctl-example_com (complain)" srvctl-example_com; assert_eq "$?" "1" "complain → 1"
_audit_aa_attr_enforced "srvctl-example_com (enforce)" srvctl-example_com; assert_eq "$?" "0" "tek satır (LF'siz) enforce → 0"
_audit_aa_attr_enforced $'\n'"srvctl-example_com (enforce)" srvctl-example_com; assert_eq "$?" "1" "ilk satır BOŞ ise ikinci satır sayılmaz (head -n1 ile aynı)"
# _domain_aa_profile_loaded: sahte aa-status (400 satır, aranan profil İLK sırada)
{ echo '#!/bin/bash'; echo 'echo "apparmor module is loaded."'; echo 'echo "   srvctl-example_com"'
  for i in $(seq 1 400); do echo "echo \"   srvctl-dolgu_${i}_com dolgu dolgu dolgu dolgu dolgu dolgu dolgu dolgu\""; done; } > "${TMP}/aa-status"
chmod +x "${TMP}/aa-status"
n=0; ( export PATH="${TMP}:${PATH}"; for ((i = 0; i < 100; i++)); do _domain_aa_profile_loaded srvctl-example_com || exit 1; done ) || n=1
assert_eq "$n" "0" "_domain_aa_profile_loaded: 100 denemede 0 yanlış-negatif"
( export PATH="${TMP}:${PATH}"; _domain_aa_profile_loaded srvctl-yok_com ); assert_eq "$?" "1" "olmayan profil → 1"

test_summary
