#!/bin/bash
# 'domain clone' ve custom.d (F3):
#  - FM dosyaları (20/21/90) ve köken kaydı KOPYALANMAZ → klon fm-auth KAPALI başlar
#  - kaynağın 00-custom.conf'u KOPYADAN ÖNCE izin listesinden geçer; ihlalde varsayılan DUR
#  - --skip-custom-d: custom.d AÇIKÇA atlanır (taranmaz, kopyalanmaz)
#  - eski include-çeviri kodu (_domain_clone_nginx_candidate) SİLİNDİ
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
SRC=example.com; DST=hedef.com
mkdir -p "${WEB_ROOT}/${DST}"
DST_DIR="${SRVCTL_NGINX_CUSTOM_DIR}/hedef_com"
_fm_clean_dst() { rm -rf "${DST_DIR:?}" "${SRVCTL_PHP_INI_DIR:?}"/*; }

echo "── A: include-çeviri kodu silindi ──"
assert_eq "$(declare -F _domain_clone_nginx_candidate >/dev/null && echo var || echo yok)" "yok" "_domain_clone_nginx_candidate yok"
assert_eq "$(grep -c 'srvctl-fm-upload' "${REPO_ROOT}/lib/domain.sh")" "0" "domain.sh'ta srvctl-fm-upload (.inc) başvurusu kalmadı"

echo "── B: FM dosyaları + kayıt KOPYALANMAZ ──"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
printf 'client_max_body_size 77M;\n' > "${CUR_DIR}/00-custom.conf"
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/10-extra.conf"
_domain_clone_conf_files "$SRC" "$DST" 0 >"$OUTF" 2>&1; assert_eq "$?" "0" "temiz kaynak: kopyalama başarılı"
# rev-L4: 00-custom.conf dışındaki kaynak dosyaları SESSİZCE kalmaz — BİLGİ satırı
assert_contains "$(cat "$OUTF")" "BİLGİ: kaynağın şu custom.d dosyaları KOPYALANMADI (yalnız 00-custom.conf taşınır): 10-extra.conf" "rev-L4: kopyalanmayan kullanıcı dosyası söylenir"
assert_contains "$(cat "$OUTF")" "BİLGİ: kaynağın FM dosyaları (" "rev-L4: FM dosyalarının kopyalanmadığı söylenir"
assert_contains "$(cat "$OUTF")" "20-srvctl-fm-upload.conf" "rev-L4: …FM adı listede"
assert_eq "$(cat "${DST_DIR}/00-custom.conf")" "client_max_body_size 77M;" "00-custom.conf kopyalandı"
assert_eq "$(ls "$DST_DIR" | tr '\n' ' ')" "00-custom.conf " "hedefte YALNIZ 00-custom.conf (20/21/90 ve diğer dosyalar yok)"
assert_eq "$([[ -e "${SRVCTL_STATE_DIR}/_fm-auth/hedef_com.manifest" ]] && echo var || echo yok)" "yok" "hedef için köken kaydı YOK (klon kapalı başlar)"
_domain_load_conf_lib
st_out=$(_domconf_fm_auth hedef.com status 2>&1); st_rc=$?
assert_contains "$st_out" "YOK" "klonda fm-auth durumu YOK (kapalı; kökü 'domain add' kurar)"
assert_eq "$st_rc" "1" "QL4-M4: YOK (köksüz) durumu rc 1 — sessiz başarı değil"
_fm_clean_dst

echo "── C: ihlalli kaynak → DUR ──"
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"
_domain_clone_conf_scan "$SRC" "$DST" "" 0 >"$OUTF" 2>&1; assert_eq "$?" "1" "scan: ihlalde 1"
assert_contains "$(cat "$OUTF")" "proxy_pass" "ihlal gösterilir"
assert_contains "$(cat "$OUTF")" "--skip-custom-d" "çıkış yolu söylenir"
_domain_clone_conf_files "$SRC" "$DST" 0 >"$OUTF" 2>&1; assert_eq "$?" "1" "kopyalama ihlalde DURUR"
assert_eq "$([[ -e "${DST_DIR}/00-custom.conf" ]] && echo var || echo yok)" "yok" "ihlal TAŞINMADI"
# doğrulanamayan (çözümlenemeyen) → DUR
printf 'location /x {\n    return 204;\n' > "${CUR_DIR}/00-custom.conf"
_domain_clone_conf_scan "$SRC" "$DST" "" 0 >/dev/null 2>&1; assert_eq "$?" "1" "çözümlenemeyen kaynak: DUR (fail-closed)"
# eski kod yolunda "kendi include'unu çevir": include artık ihlal
printf 'location /x {\n    include /etc/nginx/custom.d/example_com/srvctl-fm-upload-*.inc;\n}\n' > "${CUR_DIR}/00-custom.conf"
_domain_clone_conf_scan "$SRC" "$DST" "" 0 >/dev/null 2>&1; assert_eq "$?" "1" "eski include düzeneği artık ihlal (çeviri yok)"

echo "── C2: aday adı rezerve uzayında olsa da mantıksal ad (00-custom.conf) kullanılır ──"
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"
cp "${CUR_DIR}/00-custom.conf" "${FM_STUBS}/srvctl-fm-cand.x"
_domain_clone_conf_scan "$SRC" "$DST" "${FM_STUBS}/srvctl-fm-cand.x" 0 >/dev/null 2>&1; assert_eq "$?" "0" "clone scan: 'srvctl-fm-cand.x' adayı yanlış-ret ALMAZ (3. argüman 00-custom.conf)"

echo "── D: --skip-custom-d ──"
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"
printf 'memory_limit = 333M\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_clone_conf_scan "$SRC" "$DST" "" 1 >/dev/null 2>&1; assert_eq "$?" "0" "scan: --skip-custom-d ile ihlal atlanır"
_domain_clone_conf_files "$SRC" "$DST" 1 >/dev/null 2>&1; assert_eq "$?" "0" "kopyalama: --skip-custom-d"
assert_eq "$([[ -e "${DST_DIR}/00-custom.conf" ]] && echo var || echo yok)" "yok" "custom.d KOPYALANMADI"
assert_contains "$(cat "${SRVCTL_PHP_INI_DIR}/hedef_com.ini")" "memory_limit = 333M" ".ini yine kopyalanır"
_fm_clean_dst

echo "── E: .ini taraması aynen sürer ──"
printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"
printf 'open_basedir = /\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_clone_conf_scan "$SRC" "$DST" "" 0 >/dev/null 2>&1; assert_eq "$?" "1" "yasak .ini anahtarı klonu durdurur"
rm -f "${SRVCTL_PHP_INI_DIR}/example_com.ini"

echo "── F: _domain_clone argüman işleme ──"
# Gövde: tarama başarısız olunca 'error' ile durur → hiçbir ağır işlem yapılmaz.
_domain_clone_conf_scan() { echo "SCAN_ARGS:$*"; return 1; }
( _domain_clone example.com yeni.com ) >"$OUTF" 2>&1; assert_contains "$(cat "$OUTF")" "SCAN_ARGS:example.com yeni.com  0" "varsayılan: skip=0"
( _domain_clone example.com yeni.com --skip-custom-d ) >"$OUTF" 2>&1; assert_contains "$(cat "$OUTF")" "SCAN_ARGS:example.com yeni.com  1" "--skip-custom-d: skip=1 (argüman sırasından bağımsız)"
( _domain_clone --skip-custom-d example.com yeni.com ) >"$OUTF" 2>&1; assert_contains "$(cat "$OUTF")" "SCAN_ARGS:example.com yeni.com  1" "bayrak başta da çalışır"
( _domain_clone example.com yeni.com --bilinmeyen ) >"$OUTF" 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek reddedilir"
( _domain_clone example.com yeni.com fazla ) >"$OUTF" 2>&1; assert_eq "$?" "1" "fazla argüman reddedilir"
( _domain_clone example.com ) >"$OUTF" 2>&1; assert_eq "$?" "1" "hedef yok: kullanım"
assert_contains "$(declare -f _domain_clone)" "skip_custom_d" "_domain_clone bayrağı işler"

test_summary
