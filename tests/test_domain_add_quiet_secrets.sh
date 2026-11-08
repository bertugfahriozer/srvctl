#!/bin/bash
# QL6-P2: `domain clone` hedefi `_DOMAIN_ADD_QUIET_SECRETS=1 _domain_add ...` ile kurar; _domain_add'in "Sonuç" bloğu o
# bayrakla DB/Redis PAROLASINI ekrana basmaz (terminal scrollback / CI / webhook logu klon çıktısını yakalar).
# Eskiden tests/'te bu bayrağa hiç başvuru yoktu: clone çağrısından bayrağı silen mutant (QB10) tüm süitte yaşıyordu.
#   A  _domain_clone → _domain_add'i bayrak '1' iken çağırır
#   B  _domain_add "Sonuç" bloğu (kaynaktan çıkarılır, gerçek metin): bayrak=1 → parolalar BASILMAZ, "[gizli" yazar
#   C  kontrol: bayrak yok/0 → parolalar BASILIR (doğrudan CLI davranışı değişmedi)
#   D  kapsam kilidi: Sonuç bloğunda parola basan satırların HEPSİ bayrak koşulunun içinde
# NOT B/C neden çıkarım: tam _domain_add root + /etc/redis + systemctl ister; blok metni kaynaktan alınıp aynı
# yerel değişkenlerle işletilir (blok değişirse çıkarım sınırları kırılır → ön koşul assert'leri kırmızı verir).
# shellcheck disable=SC2034  # render_block'taki yerel değişkenleri eval ile çalışan Sonuç bloğu okur
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"
log_action() { :; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
set +e

echo "── A: clone → _domain_add bayrak=1 ile çağrılır ──"
domain_exists()  { [[ "$1" == "kaynak.com" ]]; }
_derive_php()    { echo "8.3"; }
_domain_clone_conf_scan() { return 0; }
header() { :; }; step() { :; }
_domain_add() { echo "ADD_CALLED args=$* QS=${_DOMAIN_ADD_QUIET_SECRETS-UNSET}"; exit 0; }
out=$( _domain_clone kaynak.com hedef.com 2>&1 )
assert_contains "$out" "ADD_CALLED args=hedef.com --php=8.3 QS=1" "A: clone, hedefi _DOMAIN_ADD_QUIET_SECRETS=1 ile kuruyor"

echo "── B/C: _domain_add Sonuç bloğu ──"
BLOCK="$(awk '/^    # ─── Sonuç ───$/{f=1} f{print} f && /log_action "DOMAIN ADD:/{exit}' "${REPO_ROOT}/lib/domain.sh")"
assert_contains "$BLOCK" 'header "✅ Domain başarıyla eklendi: ${domain}"' "ön koşul: blok Sonuç başlığıyla başlıyor"
assert_contains "$BLOCK" 'log_action "DOMAIN ADD:' "ön koşul: blok log_action ile bitiyor"
DBP="DBPASS-gizli-0123456789"; RDP="REDISPASS-gizli-9876543210"
render_block() {   # $1 = bayrak ("" = tanımsız)
    (
        if [[ -n "$1" ]]; then export _DOMAIN_ADD_QUIET_SECRETS="$1"; else unset _DOMAIN_ADD_QUIET_SECRETS; fi
        domain="x.com"; base="${T}/base"; web_user="web_x_com"; php_version="8.3"; sname="x_com"
        db_name="db_x_com"; db_user="usr_x_com"; db_pass="$DBP"; redis_user="redis_x_com"; redis_pass="$RDP"
        eval "$BLOCK"
    ) 2>&1
}
q=$(render_block 1)
assert_not_contains "$q" "$DBP" "B: bayrak=1 → DB parolası BASILMADI"
assert_not_contains "$q" "$RDP" "B: bayrak=1 → Redis parolası BASILMADI"
assert_eq "$(grep -c '\[gizli' <<< "$q")" "2" "B: bayrak=1 → iki parola satırı da '[gizli' yer tutucusu (DB + Redis)"
assert_contains "$q" "DB Name:" "B: sonuç bloğu yine de basıldı (kontrol: eval gerçekten koştu)"
for flag in "" 0; do
    c=$(render_block "$flag")
    assert_contains "$c" "$DBP" "C[bayrak='${flag:-yok}']: DB parolası BASILIR (doğrudan CLI)"
    assert_contains "$c" "$RDP" "C[bayrak='${flag:-yok}']: Redis parolası BASILIR"
    assert_not_contains "$c" "[gizli" "C[bayrak='${flag:-yok}']: yer tutucu YOK"
done

echo "── D: kapsam kilidi — parola basan her satır bayrak koşuluna bağlı ──"
assert_eq "$(grep -c 'echo "  DB Pass:        \${db_pass}"' <<< "$BLOCK")" "1" "D: DB parolası yalnız TEK satırda basılıyor"
assert_eq "$(grep -c 'echo "  Redis Pass:     \${redis_pass}"' <<< "$BLOCK")" "1" "D: Redis parolası yalnız TEK satırda basılıyor"
assert_eq "$(grep -c '_DOMAIN_ADD_QUIET_SECRETS:-0}" == "1"' <<< "$BLOCK")" "2" "D: iki bayrak koşulu (DB + Redis)"

test_summary
