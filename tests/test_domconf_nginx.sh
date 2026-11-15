#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh taklitleri (MOCK_DUMP_MODE, NGINX_TEST_RC) bu dosyada atanır
# 'domain nginx --file' — İZİN LİSTESİ (varsayılan ret) taraması, '--force' YOK, include ÖN KOŞUL
# kapısı, rollback, nginx -T son denetimi (yalnız ÜRETİLMİŞ-OLMAYAN dosyalar).
# Tarama aday dosyada, nginx -t'den ÖNCE yapılır. Gerçek izin listesi (lib/nginx_allow.sh)
# kullanılır; stub'lar yalnız "doğrulanamadı" yolları içindir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
CUSTOM="${CUR_DIR}/00-custom.conf"
OUTF="${FM_STUBS}/out.txt"
TMP="$(mktemp -d)"
_edit() { ( _domconf_edit_nginx example.com --file "$1" ) >"$OUTF" 2>&1; }
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }

echo "── A: reddedilen yapılar (izin listesi dışı) — nginx -t'den ÖNCE, dosya DEĞİŞMEZ ──"
printf 'client_max_body_size 5m;\n' > "$CUSTOM"; base_md5=$(_md5 "$CUSTOM")
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    printf '%b' "$payload" > "${TMP}/cand.conf"
    : > "$NGINX_T_LOG"
    _edit "${TMP}/cand.conf"; rc=$?
    assert_eq "$rc" "1" "RED: $desc"
    assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "…dosya değişmedi: $desc"
    assert_eq "$(wc -l < "$NGINX_T_LOG" | tr -d ' ')" "0" "…nginx -t/-T HİÇ çağrılmadı (tarama önce): $desc"
done <<'CASES'
location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n|proxy_pass (belgeli 127.0.0.1:PORT kullanımı da: kırıcı değişiklik)
fastcgi_pass unix:/run/php/other.sock;\n|fastcgi_pass başka alanın soketi
root /etc;\n|root
alias /root/;\n|alias
server_name evil.com;\n|server_name
listen 8080;\n|listen
modsecurity off;\n|modsecurity
include /etc/nginx/custom.d/baska_com/90-srvctl-fm-auth.conf;\n|başka alanın dosyasını include
include /etc/nginx/custom.d/example_com/*.conf;\n|kendi dizinini include
auth_request /__fm_auth;\n|auth_request
location ~ "^/_fm/up/" {\n    return 204;\n}\n|/_fm/up/ üzerinde regex location (SEC-H1)
location /_fm/ {\n    return 204;\n}\n|/_fm/ prefix
add_header X-T $upstream_http_x_fm_auth;\n|token değişkeni sızıntısı
access_log /var/log/nginx/../../etc/cron.d/x;\n|access_log yol (../ ile keyfi dosya)
error_log /tmp/x debug;\n|error_log
location /a {\n    mirror /__fm_auth;\n}\n|mirror
if ($fm_auth = "") {\n    return 204;\n}\n|fm_auth değişkeni
set $fm_gate 1;\n|rezerve değişken adı
location /a {\n    rewrite ^ /__fm_auth last;\n}\n|/__fm_auth'a rewrite
location /a {\n  return 204;\n|dengesiz blok (çözümlenemez = ret)
"unterminated\n|açık tırnak
CASES

echo "── B: --force YOKTUR ──"
printf 'proxy_pass http://127.0.0.1:3000;\n' > "${TMP}/cand.conf"
( _domconf_edit_nginx example.com --file "${TMP}/cand.conf" --force ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "--force reddedilir"
assert_contains "$(cat "$OUTF")" "kaldırıldı" "--force kaldırıldı mesajı"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "--force ile de dosya DEĞİŞMEDİ"
assert_eq "$(_reloads)" "0" "reload yok"

echo "── C: izin verilen yapılar uygulanır ──"
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    printf '%b' "$payload" > "${TMP}/cand.conf"
    printf 'client_max_body_size 5m;\n' > "$CUSTOM"; : > "$RELOAD_LOG"
    _edit "${TMP}/cand.conf"; rc=$?
    assert_eq "$rc" "0" "KABUL: $desc"
    assert_eq "$(_md5 "$CUSTOM")" "$(_md5 "${TMP}/cand.conf")" "…uygulandı: $desc"
    assert_eq "$(_reloads)" "1" "…reload edildi: $desc"
done <<'CASES'
client_max_body_size 100M;\n|client_max_body_size
# root /etc/passwd;\n|yorum içindeki direktif yakalanmaz
location /api/ {\n    expires 1h;\n}\n|expires
location = /robots.txt {\n    return 200 "User-agent: *";\n}\n|sabit return
CASES

echo "── D: doğrulanamayan (rc 2) → ret ──"
_domconf_load_allow_lib
eval "_real_$(declare -f _ngxallow_scan)"
_ngxallow_scan() { echo "0:-:stub: doğrulanamadı"; return 2; }
printf 'client_max_body_size 5m;\n' > "$CUSTOM"; base_md5=$(_md5 "$CUSTOM")
printf 'client_max_body_size 9m;\n' > "${TMP}/cand.conf"
_edit "${TMP}/cand.conf"; assert_eq "$?" "1" "izin listesi doğrulayamazsa (rc 2) ret"
assert_contains "$(cat "$OUTF")" "DOĞRULANAMADI" "gerekçe: doğrulanamadı"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "dosya değişmedi"
eval "$(declare -f _real__ngxallow_scan | sed '1s/.*/_ngxallow_scan ()/')"

echo "── E: nginx -t hatası → rollback ──"
printf 'client_max_body_size 5m;\n' > "$CUSTOM"; base_md5=$(_md5 "$CUSTOM")
printf 'client_max_body_size 9m;\n' > "${TMP}/cand.conf"
NGINX_TEST_RC=1; : > "$RELOAD_LOG"
_edit "${TMP}/cand.conf"; assert_eq "$?" "1" "nginx -t hatasında başarısız"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "dosya eski haline döndü"
assert_eq "$(_reloads)" "0" "reload yok"
NGINX_TEST_RC=0

echo "── F: nginx -T son denetimi ──"
MOCK_DUMP_MODE=fail; _edit "${TMP}/cand.conf"; assert_eq "$?" "1" "nginx -T başarısız → ret (fail-closed)"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "…geri alındı"
MOCK_DUMP_MODE=empty; _edit "${TMP}/cand.conf"; assert_eq "$?" "1" "nginx -T çıktısı boş → ret"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "…geri alındı"
MOCK_DUMP_MODE=dupmarker; _edit "${TMP}/cand.conf"; assert_eq "$?" "1" "nginx -T başlık sahteciliği (çift başlık) → ret"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "…geri alındı"
MOCK_DUMP_MODE=mismatch; _edit "${TMP}/cand.conf"; assert_eq "$?" "1" "nginx -T bölümü diskten FARKLI (sahte/eşzamanlı) → ret"
assert_eq "$(_md5 "$CUSTOM")" "$base_md5" "…geri alındı"
MOCK_DUMP_MODE=""
# _domconf_dump_check birim: DÜZENLENEN dosya diskte ihlalliyse (aday taramasından kaçmış olsa bile) rc 1
printf 'location /e { proxy_pass http://127.0.0.1:1; }\n' > "$CUSTOM"
dfind=$(_domconf_dump_check example.com example_com 00-custom.conf); drc=$?
assert_eq "$drc" "1" "dump_check: düzenlenen dosyada ihlal → 1"
assert_contains "$dfind" "00-custom.conf:1:proxy_pass" "…bulgu dosya:satır:direktif"
dfind=$(_domconf_dump_check example.com example_com baska.conf); drc=$?
assert_eq "$drc" "0" "dump_check: ihlal DÜZENLENMEYEN dosyadaysa rc 0 (yalnız UYARI)"
assert_contains "$dfind" "UYARI 00-custom.conf" "…UYARI satırı"
MOCK_DUMP_MODE=mismatch; dfind=$(_domconf_dump_check example.com example_com 00-custom.conf); drc=$?
assert_eq "$drc" "2" "dump_check: bölüm diskle uyuşmuyor → 2 (doğrulanamadı)"
MOCK_DUMP_MODE=""
printf 'client_max_body_size 5m;\n' > "$CUSTOM"
# başka (düzenlenmeyen) dosyadaki MEVCUT ihlal: yazımı engellemez, UYARI basar
printf 'location /e { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/50-eski.conf"
: > "$RELOAD_LOG"
_edit "${TMP}/cand.conf"; assert_eq "$?" "0" "başka dosyadaki mevcut ihlal düzenlemeyi ENGELLEMEZ"
assert_contains "$(cat "$OUTF")" "UYARI" "…UYARI basılır"
assert_contains "$(cat "$OUTF")" "50-eski.conf" "…hangi dosya olduğu söylenir"
assert_eq "$(cat "${CUR_DIR}/50-eski.conf")" 'location /e { proxy_pass http://127.0.0.1:1; }' "…o dosyaya DOKUNULMADI"
assert_eq "$(_reloads)" "1" "…reload edildi"
rm -f "${CUR_DIR}/50-eski.conf"
# üretilmiş (kayıtlı) FM dosyaları nginx -T denetiminde muaf: açıkken düzenleme çalışır
printf 'client_max_body_size 5m;\n' > "$CUSTOM"
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1
printf 'client_max_body_size 11m;\n' > "${TMP}/cand.conf"; : > "$RELOAD_LOG"
_edit "${TMP}/cand.conf"; assert_eq "$?" "0" "fm-auth açıkken (üretilmiş 90/21/20 var) düzenleme çalışır"
assert_not_contains "$(cat "$OUTF")" "UYARI" "…üretilmiş dosyalar için UYARI yok (nginx -T'de yalnız ÜRETİLMİŞ-OLMAYANlar)"
# …ama kayıt GÜVENİLMEZSE aynı dosyalar kullanıcı dosyası sayılır → UYARI
chmod 644 "$MAN"; printf 'client_max_body_size 12m;\n' > "${TMP}/cand.conf"
_edit "${TMP}/cand.conf"; assert_eq "$?" "0" "kayıt güvenilmezken de düzenleme çalışır (diğer dosyalar yalnız uyarı)"
assert_contains "$(cat "$OUTF")" "UYARI" "…ama üretilmiş dosyalar artık kullanıcı dosyası sayılır: UYARI"
chmod 600 "$MAN"
_fm_reset

echo "── G: vhost include ön koşulu, --show, değişiklik yok ──"
printf 'server {\n    listen 80;\n}\n' > "$VHOST"
printf 'client_max_body_size 9m;\n' > "${TMP}/cand.conf"
_edit "${TMP}/cand.conf"; assert_eq "$?" "1" "vhost custom.d include etmiyorsa durur"
assert_contains "$(cat "$OUTF")" "repair" "kurtarma yolu önerilir"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
out=$( _domconf_edit_nginx example.com --show ); assert_contains "$out" "İZİN LİSTESİ" "--show iskeleti izin listesini anlatır"
assert_not_contains "$out" "--force olmadan" "iskelette ölü '--force olmadan' yok"
assert_not_contains "$out" "fastcgi_read_timeout" "iskelette ölü fastcgi_read_timeout örneği yok"
assert_not_contains "$out" "REDDEDİLEN direktifler" "iskelette eski yasak-listesi bölümü yok"
cp "$CUSTOM" "${TMP}/same.conf"; : > "$RELOAD_LOG"
_edit "${TMP}/same.conf"; assert_eq "$?" "0" "aynı içerik: değişiklik yok"
assert_eq "$(_reloads)" "0" "…reload yok"
_edit "${TMP}/yok.conf"; assert_eq "$?" "1" "olmayan --file reddedilir"
( _domconf_edit_nginx example.com --bilinmeyen ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek"
( _domconf_edit_nginx ) >/dev/null 2>&1; assert_eq "$?" "1" "alan adı yok"
( _domconf_edit_nginx yok.test --show ) >/dev/null 2>&1; assert_eq "$?" "1" "olmayan alan"
# iskeletin KENDİSİ izin listesinden geçer (kullanıcıya verilen şablon reddedilmemeli)
_domconf_nginx_skeleton example.com > "${TMP}/skel.conf"
_domconf_user_scan "${TMP}/skel.conf" example.com 00-custom.conf >/dev/null; assert_eq "$?" "0" "00-custom.conf iskeleti izin listesinden temiz geçer"
printf 'client_max_body_size 100M;\n' >> "${TMP}/skel.conf"
_domconf_user_scan "${TMP}/skel.conf" example.com 00-custom.conf >/dev/null; assert_eq "$?" "0" "iskelet + iskeletteki örnek temiz"

echo "── G: aday/geçici dosyada mantıksal ad (A1→A2 notu 3): mktemp adı 'fm' içerse bile yanlış-ret YOK ──"
MOCK_DUMP_MODE=""; NGINX_TEST_RC=0
printf 'client_max_body_size 5m;\n' > "$CUSTOM"
printf 'client_max_body_size 9m;\n' > "${TMP}/cand.conf"; : > "$RELOAD_LOG"
( mktemp() { if (( $# )); then command mktemp "$@"; else command mktemp "${TMP}/srvctl-fm-cand.XXXXXX"; fi; }
  _domconf_edit_nginx example.com --file "${TMP}/cand.conf" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "aday dosya adı 'srvctl-fm-cand.*' (rezerve uzayında): 00-custom.conf mantıksal adıyla temiz geçer"
assert_eq "$(_md5 "$CUSTOM")" "$(_md5 "${TMP}/cand.conf")" "…uygulandı"
cp "${TMP}/cand.conf" "${TMP}/srvctl-fm-cand.x"
_domconf_user_scan "${TMP}/srvctl-fm-cand.x" example.com >/dev/null; assert_eq "$?" "1" "kontrol: mantıksal ad VERİLMEZSE aynı dosya rezerve-ad ile reddedilir"
_domconf_user_scan "${TMP}/srvctl-fm-cand.x" example.com 00-custom.conf >/dev/null; assert_eq "$?" "0" "…mantıksal adla temiz"
_domconf_user_scan "${TMP}/cand.conf" example.com 90-srvctl-fm-auth.conf >/dev/null; assert_eq "$?" "1" "…hedef ad rezerve ise (temiz içerik) ret"

rm -rf "$TMP"
test_summary
