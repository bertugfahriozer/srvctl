#!/bin/bash
# shellcheck disable=SC2034
# E66 — yükleme oturumu başına tek eşzamanlı PUT: http düzeyi bölge dosyası (fm-sess) + 20'deki sunucu düzeyi limit_conn.
# Gerçek nginx davranışı tests/test_edge_up_sess_real.sh'ta; burada yapısal kilit + yazıcı akışı (sıra, idempotans, geri alma, kapalı yön).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
domain_exists() { return 0; }
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"${FM_STUBS}/out.txt" 2>&1; }
ZONE="${SRVCTL_NGINX_CONF_D}/srvctl-fmsess.conf"
TPL_DIR="$(_domconf_fm_tpl_dir)"
strip() { grep -v '^[[:space:]]*#' "$1"; }

echo "── A: bölge şablonu (yorum-dışı yapısal kilit) ──"
S=$(strip "${TPL_DIR}/fm-sess.conf.tpl")
assert_contains "$S" 'map "$request_method|$request_uri|$http_x_fm_ticket" $srvctl_fmsess_key {' "anahtar: yöntem + HAM istek hedefi + bilet başlığı (B1)"
assert_not_contains "$S" 'server_name' "sunucu adı anahtarda YOK: ana alan ve up.<alan> sunucusu AYNI kotayı paylaşır (B2)"
assert_contains "$S" 'default "";' "varsayılan anahtar BOŞ (boş anahtar limit_conn'a sayılmaz)"
assert_contains "$S" '"~^PUT\|/_fm/up/([0-9]{1,20})/[0-9]{1,20}\|([0-9a-f]{32})[0-9a-f]{32}$" "$1:$2";' "yalnız PUT + 20'nin biçim kapısıyla AYNI yol + uygulamanın kabul ettiği bilet biçimi (64 küçük hex); anahtar = uploadid:bilet[0..32)"
assert_contains "$S" 'limit_conn_zone $srvctl_fmsess_key zone=srvctl_fmsess:10m;' "bölge srvctl_fmsess"
assert_eq "$(grep -c 'limit_conn_zone' <<< "$S")" "1" "tek bölge"
assert_not_contains "$S" 'binary_remote_addr' "IP anahtarda YOK (IP değiştirerek ikinci uçuş açılamaz)"
assert_not_contains "$(_domconf_fm_render_sess)" '{{' "render: çözülmemiş jeton yok"
U20=$(strip "${TPL_DIR}/fm-upload.conf.tpl")
gate=$(grep -o '\^/_fm/up/\[0-9\]{1,20}/\[0-9\]{1,20}\$' <<< "$U20" | head -1)
assert_eq "$gate" '^/_fm/up/[0-9]{1,20}/[0-9]{1,20}$' "20 biçim kapısı beklenen kalıpta"
assert_contains "$S" '/_fm/up/([0-9]{1,20})/[0-9]{1,20}\|' "bölge anahtarı kalıbı 20'nin kapısıyla aynı rakam sınırlarını taşır"

echo "── B: 20 şablonu — limit_conn SUNUCU düzeyinde, @fm_up'ta DEĞİL ──"
depth0=$(awk '{ line=$0; if (depth==0 && line ~ /^limit_conn[ \t]/) print line; n=gsub(/\{/,"{",line); m=gsub(/\}/,"}",line); depth+=n-m }' <<< "$U20")
assert_eq "$depth0" "limit_conn srvctl_fmsess 1;" "sunucu düzeyinde (süslü parantez derinliği 0) tam bir limit_conn srvctl_fmsess 1;"
assert_eq "$(grep -c 'limit_conn srvctl_fmsess' <<< "$U20")" "1" "limit_conn srvctl_fmsess YALNIZ bir kez"
FMUP_BLK=$(awk '/location @fm_up \{/{f=1} f{print} f&&/^}/{exit}' <<< "$U20")
assert_not_contains "$FMUP_BLK" "limit_conn" "@fm_up içinde limit_conn YOK (nginx istek başına yalnız ilk location'da değerlendirir; orada hiç koşmazdı)"
MAIN_BLK=$(awk '/location \^~ \/_fm\/up\/ \{/{f=1} f{print} f&&/^}/{exit}' <<< "$U20")
assert_contains "$MAIN_BLK" "limit_conn_status 503;" "ilk location: red 503 (istemci putError 5xx'i yeniden dener; 429 ölümcül)"
assert_not_contains "$MAIN_BLK" "limit_conn srvctl_fmsess" "ilk location kendi limit_conn'unu koymaz (sunucu düzeyindekini ezip conn_per_ip'i düşürürdü)"
assert_not_contains "$(_domconf_fm_render_off example_com)" "limit_conn" "kapalı kök (403) limit_conn taşımaz"

echo "── C: yazıcı — ensure ──"
assert_eq "$(_exists "$ZONE")" "yok" "başlangıçta bölge dosyası yok"
_domconf_fm_sess_conf_ensure; assert_eq "$?" "0" "ensure rc 0"
assert_eq "$(_exists "$ZONE")" "var" "bölge dosyası yazıldı"
assert_eq "$(cat "$ZONE")" "$(_domconf_fm_render_sess)" "içerik şablonun render'ı ile AYNI"
assert_eq "$(stat -f '%Lp' "$ZONE" 2>/dev/null || stat -c '%a' "$ZONE")" "644" "kip 644"
ino1=$(stat -f '%i' "$ZONE" 2>/dev/null || stat -c '%i' "$ZONE")
_domconf_fm_sess_conf_ensure; ino2=$(stat -f '%i' "$ZONE" 2>/dev/null || stat -c '%i' "$ZONE")
assert_eq "$ino2" "$ino1" "ikinci çağrı dosyaya DOKUNMAZ (idempotent: aynı inode)"
printf 'bozuk\n' > "$ZONE"; _domconf_fm_sess_conf_ensure
assert_eq "$(cat "$ZONE")" "$(_domconf_fm_render_sess)" "kurcalanmış/eski içerik şablona geri yazılır"
assert_eq "$(find "$SRVCTL_NGINX_CONF_D" -name '*.srvctl.*' | wc -l | tr -d ' ')" "0" "geçici dosya sızıntısı yok"
( SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.yok-dizin"; _domconf_fm_sess_conf_ensure ) >/dev/null 2>&1; assert_eq "$?" "1" "conf.d yoksa rc 1 (yazıcı dizin YARATMAZ)"
mkdir -p "${WEB_ROOT}/.hedef"; ln -s "${WEB_ROOT}/.hedef" "${WEB_ROOT}/.bag"
( SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.bag"; _domconf_fm_sess_conf_ensure ) >/dev/null 2>&1; assert_eq "$?" "1" "conf.d sembolik bağsa rc 1"
assert_eq "$(find "${WEB_ROOT}/.hedef" -type f | wc -l | tr -d ' ')" "0" "sembolik bağ hedefine HİÇBİR şey yazılmadı"

echo "── D: açma yönü — bölge dosyası 20'den ÖNCE yazılır; kapatma yönü dokunmaz ──"
_zone_probe() { echo "zone=$(_exists "$ZONE") f20=$(_exists "$F20")" >> "${FM_STUBS}/order.log"; }
# bölge dosyasını yok say: ikinci kurulum 'on' ile yeniden yaratmalı. (silme yerine yeni bir temiz conf.d)
export SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.conf.d2"; mkdir -p "$SRVCTL_NGINX_CONF_D"; ZONE="${SRVCTL_NGINX_CONF_D}/srvctl-fmsess.conf"
: > "${FM_STUBS}/order.log"; NGINX_T_HOOK=_zone_probe
_on; assert_eq "$?" "0" "fm-auth on başarılı"
NGINX_T_HOOK=""
assert_eq "$(_exists "$ZONE")" "var" "fm-auth on bölge dosyasını yazdı"
assert_eq "$(_exists "$F20")" "var" "20 yazıldı"
assert_contains "$(cat "${FM_STUBS}/order.log")" "zone=var f20=var" "nginx -t anında bölge dosyası VE 20 birlikte hazır (bölge 20'den sonra gelmez)"
assert_contains "$(strip "$F20" | grep -c 'limit_conn srvctl_fmsess 1;')" "1" "diskteki 20 sunucu düzeyi oturum kapısını taşır"

echo "── E: bölge yazılamazsa açma REDDEDİLİR, 20 yazılmaz ──"
( _domconf_fm_auth example.com off ) >/dev/null 2>&1
export SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.conf.d-yok"
before=$(cat "$F20")
_on; rc=$?
assert_ne "$rc" "0" "bölge yazılamayınca fm-auth on başarısız"
assert_eq "$(cat "$F20")" "$before" "20 (kapalı kök) DEĞİŞMEDİ — yarım açık durum yok"
assert_not_contains "$(strip "$F20")" "limit_conn srvctl_fmsess" "kapalı kök hâlâ 403 kökü"

echo "── F: 'fm-auth off' bölge dosyasına dokunmaz (host başına ortak dosya) ──"
export SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.conf.d2"; ZONE="${SRVCTL_NGINX_CONF_D}/srvctl-fmsess.conf"
_on; ( _domconf_fm_auth example.com off ) >/dev/null 2>&1
assert_eq "$(_exists "$ZONE")" "var" "off sonrası bölge dosyası yerinde (kullanılmayan bölge zararsız)"
echo "── G: şablon yükseltmesi (E66 öncesi AÇIK alan): fm-root kuru → STALE/YAPILACAK, --apply bölge + yeni 20'yi yazar ──"
_fm_reset
OLDT="${FM_STUBS}/oldtpl"; mkdir -p "${OLDT}/nginx"; cp "${REPO_ROOT}"/templates/nginx/*.tpl "${OLDT}/nginx/"
grep -v '^limit_conn srvctl_fmsess 1;$' "${TPL_DIR}/fm-upload.conf.tpl" > "${OLDT}/nginx/fm-upload.conf.tpl"
NEWT="$SRVCTL_TEMPLATES"
export SRVCTL_TEMPLATES="$OLDT"
export SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.conf.d3"; mkdir -p "$SRVCTL_NGINX_CONF_D"; ZONE="${SRVCTL_NGINX_CONF_D}/srvctl-fmsess.conf"
_on; assert_eq "$?" "0" "(önkoşul) eski şablonla alan AÇILDI"
assert_not_contains "$(strip "$F20")" "limit_conn srvctl_fmsess" "(önkoşul) eski 20'de oturum kapısı YOK (yorum-dışı)"
export SRVCTL_NGINX_CONF_D="${WEB_ROOT}/.conf.d4"; mkdir -p "$SRVCTL_NGINX_CONF_D"; ZONE="${SRVCTL_NGINX_CONF_D}/srvctl-fmsess.conf"   # E66 öncesi canlı: bölge dosyası hiç yoktu
export SRVCTL_TEMPLATES="$NEWT"
h0=$(_md5 "$F20")
dry=$(_domconf_fm_root_cmd example.com 2>&1)
echo "$dry" | sed 's/^/    [kuru] /'
assert_contains "$dry" "[example.com] YAPILACAK:" "kuru: yükseltme YAPILACAK olarak görünür"
assert_contains "$dry" "STALE" "kuru: 20 STALE (kayıtlı özet eski şablonun, taze render yeni)"
assert_contains "$dry" "Toplam 1 alan: 1 yapılacak, 0 sağlam, 0 yapılamaz" "kuru: özet satırı"
assert_eq "$(_md5 "$F20")" "$h0" "kuru: 20'ye DOKUNULMADI"
assert_eq "$(_exists "$ZONE")" "yok" "kuru: bölge dosyası YAZILMADI"
: > "$RELOAD_LOG"
app=$(_domconf_fm_root_cmd example.com --apply 2>&1); arc=$?
echo "$app" | sed 's/^/    [apply] /'
assert_eq "$arc" "0" "--apply rc 0"
assert_eq "$(_exists "$ZONE")" "var" "--apply bölge dosyasını yazdı"
assert_contains "$(strip "$F20")" "limit_conn srvctl_fmsess 1;" "--apply yeni 20'yi yazdı (yorum-dışı)"
assert_eq "$(_reloads)" "1" "tek reload"
dry2=$(_domconf_fm_root_cmd example.com 2>&1)
assert_contains "$dry2" "sağlam: AÇIK" "--apply sonrası kuru: sağlam AÇIK"
assert_contains "$dry2" "1 sağlam" "özet: 1 sağlam"
printf 'bozuk\n' > "$ZONE"
dry3=$(_domconf_fm_root_cmd example.com 2>&1)
assert_contains "$dry3" "bölge dosyası eksik/eski" "bölge dosyası bozulursa kuru YAPILACAK der (20 sağlam olsa da)"
_domconf_fm_root_cmd example.com --apply >/dev/null 2>&1
assert_eq "$(cat "$ZONE")" "$(_domconf_fm_render_sess)" "--apply bölge dosyasını şablona geri yazdı"
dry4=$(_domconf_fm_root_cmd example.com 2>&1); assert_contains "$dry4" "sağlam: AÇIK" "onarım sonrası sağlam"
st=$(_domconf_fm_auth example.com status 2>&1); echo "$st" | sed 's/^/    [status] /'
assert_contains "$st" "AÇIK" "fm-auth status: alan AÇIK (yükseltme sonrası)"

echo "── H: K4 — sözdizimi GEÇERLİ ama anlamsal bozuk bölge dosyası (anahtar hep boş ⇒ sınır sessizce kalkar): status ve nginx-audit GÖRÜR ──"
st0=$(_domconf_fm_auth example.com status 2>&1); rc0=$?
assert_eq "$rc0" "0" "(önkoşul) sağlam bölge dosyasıyla status rc 0"
assert_not_contains "$st0" "bölge dosyası" "(önkoşul) sağlam durumda bölge uyarısı yok"
au0=$(_domconf_nginx_audit example.com 2>&1); arc0=$?
assert_eq "$arc0" "0" "(önkoşul) sağlam bölge dosyasıyla nginx-audit rc 0"
printf 'map "$request_method|$request_uri|$http_x_fm_ticket" $srvctl_fmsess_key {\n    default "";\n}\nlimit_conn_zone $srvctl_fmsess_key zone=srvctl_fmsess:10m;\n' > "$ZONE"
st=$(_domconf_fm_auth example.com status 2>&1); src=$?
echo "$st" | sed 's/^/    [status] /'
assert_ne "$src" "0" "anlamsal bozuk bölge: status rc ≠ 0 (eskiden 0 ve 'AÇIK … OK')"
assert_contains "$st" "oturum kotası bölge dosyası" "status bölge dosyasını adıyla uyarır"
assert_contains "$st" "fm-root example.com --apply" "status onarım komutunu söyler"
au=$(_domconf_nginx_audit example.com 2>&1); arc=$?
echo "$au" | sed 's/^/    [audit] /'
assert_ne "$arc" "0" "nginx-audit rc ≠ 0 (eskiden 'temiz' rc 0)"
assert_contains "$au" "oturum kotası bölge dosyası" "nginx-audit bölge dosyasını adıyla uyarır"
assert_not_contains "$au" "  temiz" "nginx-audit 'temiz' DEMEZ"
_domconf_fm_root_cmd example.com --apply >/dev/null 2>&1
assert_eq "$(cat "$ZONE")" "$(_domconf_fm_render_sess)" "onarım: --apply bölge dosyasını şablona geri yazdı"
st2=$(_domconf_fm_auth example.com status 2>&1); assert_eq "$?" "0" "onarım sonrası status rc 0"
# KAPALI alan: bölge dosyası kullanılmıyor ⇒ bozukluğu uyarı/ret sebebi DEĞİL (20 kapalıyken kimse başvurmaz)
( _domconf_fm_auth example.com off ) >/dev/null 2>&1
printf 'bozuk\n' > "$ZONE"
st3=$(_domconf_fm_auth example.com status 2>&1)
assert_not_contains "$st3" "oturum kotası bölge dosyası" "KAPALI alanda bozuk bölge dosyası status'u kirletmez"
test_summary
