#!/bin/bash
# 'domain staging' (F3b): clone ile AYNI custom.d kapısı.
#  - varsayılan: kaynağın 00-custom.conf'u izin listesine uymuyorsa DUR (hiçbir şey oluşturulmaz)
#  - --skip-custom-d: clone'a AÇIKÇA geçer (taranmaz, kopyalanmaz)
#  - argüman işleme: bayrak sırası serbest, bilinmeyen seçenek/fazla argüman reddedilir
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
STG="staging.example.com"

echo "── A: argüman işleme (clone stub'ı çağrıyı kaydeder) ──"
_domain_clone() { echo "CLONE_ARGS:$*"; }
( _domain_staging example.com ) >"$OUTF" 2>&1; assert_contains "$(cat "$OUTF")" "CLONE_ARGS:example.com staging.example.com" "varsayılan: bayraksız clone"
assert_not_contains "$(cat "$OUTF")" "--skip-custom-d" "varsayılan: bayrak GEÇİRİLMEZ"
( _domain_staging example.com --skip-custom-d ) >"$OUTF" 2>&1; assert_contains "$(cat "$OUTF")" "CLONE_ARGS:example.com staging.example.com --skip-custom-d" "bayrak clone'a geçer"
( _domain_staging --skip-custom-d example.com ) >"$OUTF" 2>&1; assert_contains "$(cat "$OUTF")" "CLONE_ARGS:example.com staging.example.com --skip-custom-d" "bayrak başta da çalışır"
( _domain_staging example.com --bilinmeyen ) >"$OUTF" 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek reddedilir"
assert_not_contains "$(cat "$OUTF")" "CLONE_ARGS" "…ve clone çağrılmaz"
( _domain_staging example.com fazla ) >"$OUTF" 2>&1; assert_eq "$?" "1" "fazla argüman reddedilir"
assert_contains "$(cat "$OUTF")" "Fazla argüman: fazla" "…'Fazla argüman' iletisiyle (olmayan-kaynak reddi DEĞİL)"
# qa2-N26: ikinci argüman da VAR OLAN bir alan — "son kazanır" olsaydı clone ilerlerdi (yukarıdaki vaka ayırt etmez)
( _domain_staging example.com example.com ) >"$OUTF" 2>&1; assert_eq "$?" "1" "fazla argüman (ikisi de var olan alan) reddedilir"
assert_not_contains "$(cat "$OUTF")" "CLONE_ARGS" "…ve clone çağrılmaz"
( _domain_staging ) >"$OUTF" 2>&1; assert_eq "$?" "1" "argümansız: kullanım"
( _domain_staging --skip-custom-d ) >"$OUTF" 2>&1; assert_eq "$?" "1" "yalnız bayrak: kullanım"
( _domain_staging yok.example.org ) >"$OUTF" 2>&1; assert_eq "$?" "1" "olmayan kaynak reddedilir"
# qa2-N25: hedef staging alanı ZATEN varsa clone'a hiç gidilmez (staging düzeyinde, kısmi iş yok)
mkdir -p "${WEB_ROOT}/${STG}"
( _domain_staging example.com ) >"$OUTF" 2>&1; assert_eq "$?" "1" "hedef staging zaten var → rc 1"
assert_contains "$(cat "$OUTF")" "Staging zaten mevcut: ${STG}" "…'Staging zaten mevcut' iletisi"
assert_not_contains "$(cat "$OUTF")" "CLONE_ARGS" "…ve clone ÇAĞRILMAZ"
rm -rf -- "${WEB_ROOT:?}/${STG}"
assert_contains "$(declare -f _domain_staging)" "skip-custom-d" "_domain_staging bayrağı işler"

echo "── B: GERÇEK _domain_clone ile uçtan uca (ağır adım _domain_add stub) ──"
unset -f _domain_clone
source "${REPO_ROOT}/lib/domain.sh"
_domain_add() { echo "ADD_CALLED:$*"; exit 77; }
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"
( _domain_staging example.com ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "ihlalli kaynak: staging DURUR (rc 1)"
assert_contains "$(cat "$OUTF")" "proxy_pass" "ihlal gösterilir"
assert_contains "$(cat "$OUTF")" "domain staging example.com --skip-custom-d" "staging için çıkış yolu söylenir"
assert_not_contains "$(cat "$OUTF")" "ADD_CALLED" "hedef domain OLUŞTURULMAYA başlanmadı"
assert_eq "$([[ -e "${WEB_ROOT}/${STG}" ]] && echo var || echo yok)" "yok" "hiçbir hedef dizin yok"
( _domain_staging example.com --skip-custom-d ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "77" "--skip-custom-d: tarama atlandı, klon ilerledi (_domain_add'e ulaştı)"
assert_contains "$(cat "$OUTF")" "ADD_CALLED:${STG}" "hedef staging.example.com"
# temiz kaynak: bayraksız ilerler
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"
( _domain_staging example.com ) >"$OUTF" 2>&1; assert_eq "$?" "77" "temiz kaynak: bayraksız ilerler"

test_summary
