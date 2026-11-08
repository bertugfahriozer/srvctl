#!/bin/bash
# QL6-L6: "tek nginx -t + tek reload" üst sınırı KOŞULSUZ yazılmıştı. Gerçek davranış (kod + tests/test_domconf_fm_gaps.sh
# "yazılacak bir şey yok: nginx -t / reload ÇALIŞTIRILMADI"): yazılacak iş YOKSA nginx -t hiç koşmaz. Söz, yalnız
# "yazılacak iş varsa" koşuluyla verilir. Bu kilit operatöre dönük 3 yüzeyi tarar: lib/domain.sh (geçiş koruması
# istemi + yardım), lib/selfupdate.sh (onay istemi + başlık), README.md. "tek reload"/"tek nginx -t" geçen HER satırın
# kendisinde ya da önceki 2 satırında koşul belirteci bulunmalı.
# QL7-M6: iki katman. (1) DAVRANIŞ: operatörün GERÇEKTE gördüğü iki onay istemi (domain.sh geçiş koruması ve selfupdate.sh
# _selfupdate_offer_fm_root) `confirm` taklidiyle yakalanır ve yakalanan METİN doğrulanır: koşul "yazılacak iş varsa",
# söz ONDAN SONRA ve "yoksa ikisi de çalışmaz" ile birlikte gelir, koşulsuzlaştıran ifade yoktur. (2) Kaynak/belge
# taraması: koşul belirteci "tek …" ifadesinden ÖNCE gelmeli (eski sürüm belirteci herhangi bir yerde kabul ediyordu:
# "her zaman tek nginx -t + tek reload (yazılacak iş sayılmaz)" geçiyordu — QL7 mutantı Q3).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
PD="$(mktemp -d)"; trap 'rm -rf "$PD"' EXIT
prompt_of() {   # $1 = senaryo (redirect|offer) → yakalanan confirm metni
    ( set +e
      source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/selfupdate.sh" >/dev/null 2>&1
      confirm() { printf '%s' "$1" > "${PD}/prompt"; return 1; }
      cmd_domain() { :; }
      case "$1" in
        redirect) _selfupdate_run() { _domain_selfupdate_transition_redirect; }; _selfupdate_run ;;
        offer)    _selfupdate_offer_fm_root ;;
      esac ) >/dev/null 2>&1
    cat "${PD}/prompt" 2>/dev/null; rm -f "${PD}/prompt"
}
for sc in redirect offer; do
    P="$(prompt_of "$sc")"
    assert_contains "$P" "fm-root --all --apply" "[$sc] istem yakalandı ve fm-root --apply'yi anıyor (ön koşul)"
    assert_contains "$P" "yazılacak iş varsa tek nginx -t + tek reload, yoksa ikisi de çalışmaz" "[$sc] söz KOŞULLU ve tam cümle: iş varsa tek -t + tek reload, yoksa ikisi de çalışmaz"
    assert_not_contains "$P" "her zaman" "[$sc] 'her zaman' koşulsuzlaştırması yok"
    assert_not_contains "$P" "sayılmaz" "[$sc] 'yazılacak iş sayılmaz' ifadesi yok"
    assert_eq "$(grep -o 'tek nginx -t' <<< "$P" | wc -l | tr -d ' ')" "1" "[$sc] 'tek nginx -t' tam bir kez ve koşullu cümlenin içinde"
done
# QL7-c2 (H3 kurtarma metni): fm-root --apply BAŞARISIZ olursa operatörün gördüğü uyarı, kayıt dizini güvensizse ÖNCE
# root:root 0700 yapıp `fm-auth <alan> off` koşmayı söyler (F9b: repair/fm-root alanı hiçbir koşulda açmaz — yalnız açık 'fm-auth <alan> on' açar). İki yüzey,
# GERÇEK çağrı: confirm "evet", cmd_domain başarısız, warn yakalanır.
warn_of() {   # $1 = redirect|offer → yakalanan warn metinleri
    ( set +e
      source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/selfupdate.sh" >/dev/null 2>&1
      confirm() { return 0; }
      cmd_domain() { return 1; }
      warn() { printf '%s\n' "$*" >> "${PD}/warns"; }
      info() { :; }
      case "$1" in
        redirect) _selfupdate_run() { _domain_selfupdate_transition_redirect; }; _selfupdate_run ;;
        offer)    _selfupdate_offer_fm_root ;;
      esac ) >/dev/null 2>&1
    cat "${PD}/warns" 2>/dev/null; rm -f "${PD}/warns"
}
for sc in redirect offer; do
    W="$(warn_of "$sc")"
    assert_contains "$W" "fm-root --apply tamamlanamadı" "[$sc] başarısız --apply uyarısı basılıyor (ön koşul)"
    assert_contains "$W" "kayıt dizini güvensizse ÖNCE root:root 0700 yapıp 'sudo srvctl domain fm-auth <alan> off' koşun" "[$sc] kurtarma metni: önce dizin 0700 + fm-auth <alan> off (H3)"
    assert_not_contains "$W" "(kayıt dizini güvensizse root:root 0700 yapın)" "[$sc] eski, 'off'suz kurtarma metni yok"
done
COND='iş varsa|boş değilse|yazılacak iş|yazım gerekirse|yazılacak bir şey|yazım yoksa|yazılacak şey'
total=0
for f in lib/domain.sh lib/selfupdate.sh README.md; do
    # tek reload / tek `nginx -t` / tek nginx -t geçen operatör metni; "tek reload" alan başına YAZIM sayısını anlatan
    # repair --all cümleleri de bu kapsamdadır (varsa koşul ister)
    out=$(awk -v cond="$COND" '
        { l[NR]=$0 }
        END {
            for (i=1;i<=NR;i++) {
                if (l[i] ~ /(tek|TEK) (reload|`?nginx -t`?)/ && l[i] !~ /^[[:space:]]*#.*QL5-L9/) {
                    # koşul "tek …"ten ÖNCE gelmeli (aynı satırda önce, ya da önceki 2 satırda) ve koşulsuzlaştırıcı olmamalı
                    pre = l[i]; sub(/(tek|TEK) (reload|`?nginx -t`?).*/, "", pre)
                    ok = (pre ~ cond) || (i>1 && l[i-1] ~ cond) || (i>2 && l[i-2] ~ cond)
                    if (l[i] ~ /her zaman|koşulsuz|sayılmaz/) ok = 0
                    printf "%s\t%s\t%d\t%s\n", (ok ? "OK" : "KOŞULSUZ"), FILENAME, i, substr(l[i],1,100)
                }
            }
        }' "${REPO_ROOT}/${f}")
    n=$(grep -c . <<< "$out")
    bad=$(grep -c '^KOŞULSUZ' <<< "$out")
    total=$((total + n))
    if [[ "$bad" != 0 ]]; then grep '^KOŞULSUZ' <<< "$out" | sed 's/^/      /'; fi
    assert_eq "$bad" "0" "${f}: koşulsuz 'tek nginx -t / tek reload' cümlesi YOK (taranan satır: ${n})"
done
assert_eq "$([[ "$total" -ge 6 ]] && echo ok || echo "toplam=$total")" "ok" "(ön koşul) tarama gerçekten cümle buldu (>=6: koşullu olanlar dahil)"
test_summary
