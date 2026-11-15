#!/bin/bash
# shellcheck disable=SC2034  # fm_env.sh'nin (source) okuduğu bayraklar (FM_MOCK_CURL, FM_PROBE_MODE_DEFAULT)
# QL4 qa2 LOW test boşlukları (srvctl tarafı) — her vaka, o satırın mutantını AYIRT EDEN gözlemle:
#   N21  status: kayıt yok ama FM adlı dosya diskte (KAYITSIZ) → rc 1 (başarı DEĞİL)
#   N23  status: AÇIK + kayıtlı PHP ≠ havuzun PHP'si (kayma) → rc 1, iki sürüm de gösterilir
#   N24  status: KAPALI ama 90/21 diskte (kayıt dışı) → rc 1 (403 kökü sağlam olsa da)
#   N05  nginx-audit --quarantine: taşınacak dosya YOKSA nginx -t / reload / kilit / "Karantinaya alınan" YOK
#   N18  repair: KAPALI + artakalan 90 → onarım GEREKİR (90 kaldırılır, status temizlenir)
#   Q54  kök kurulumu: kayıtsız FM adında SARKAN sembolik bağ → kurulum REDDEDİLİR, bağ ezilmez, kayıt yazılmaz
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# F8-L4: status "temiz" (rc 0) YALNIZ çalışan durum doğrulanınca; sonda kör ise rc 4. Pozitif kontroller doğrulanmış durumda koşsun.
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
mkdir -p "${WEB_ROOT}/example.com/current/modules/FileManager/Auth"
echo '<?php' > "${WEB_ROOT}/example.com/current/modules/FileManager/Auth/fm-auth.php"
_on()     { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >"$OUTF" 2>&1; }
_off()    { ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; }
_status() { ( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; }
_cnt()    { printf '%s/%s/%s' "$(grep -c '^t$' "$NGINX_T_LOG")" "$(_reloads)" "$(grep -c . "$FLOCK_LOG")"; }

echo "── N21: KAYITSIZ (kayıt yok, FM adı diskte) → status rc 1 ──"
_fm_reset; _status; assert_eq "$?" "1" "(pozitif kontrol) hiçbir şey yok → YOK, rc 1"
_fm_reset; printf 'client_max_body_size 1m;\n' > "$F20"
_status; rc=$?
assert_eq "$rc" "1" "kayıtsız 20 dosyası varken status rc 1"
assert_contains "$(cat "$OUTF")" "fm-auth KAYITSIZ (TAMPERED)" "…KAYITSIZ iletisi"

echo "── N23: AÇIK + PHP kayması → status rc 1 ──"
_fm_reset; _on; assert_eq "$?" "0" "(ön koşul) on başarılı"
rec=$(_fmprov_load example_com; printf '%s' "$_FMP_PHP")
other="8.1"; [[ "$rec" == "8.1" ]] && other="8.2"
_status; assert_eq "$?" "0" "(pozitif kontrol) kaymasız AÇIK → rc 0"
( _derive_php() { echo "$other"; }; _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "havuz php${other} ≠ kayıt php${rec} → status rc 1"
assert_contains "$(cat "$OUTF")" "(havuz: php${other}, kayıt: php${rec})" "…iki sürüm de gösterilir"
( _derive_php() { echo "$rec"; }; _domconf_fm_auth example.com status ) >"$OUTF" 2>&1
assert_eq "$?" "0" "(pozitif kontrol) havuz = kayıt → rc 0"

echo "── N24: KAPALI + artakalan 90/21 → status rc 1 ──"
_fm_reset; _on; cp "$F90" "${FM_STUBS}/f90.keep"; cp "$F21" "${FM_STUBS}/f21.keep"; _off
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "(ön koşul) off 90/21'i kaldırdı"
_status; assert_eq "$?" "0" "(pozitif kontrol) temiz KAPALI → rc 0"
cp "${FM_STUBS}/f90.keep" "$F90"; chmod 644 "$F90"
_status; rc=$?
assert_eq "$rc" "1" "KAPALI ama 90 diskte → rc 1"
assert_contains "$(cat "$OUTF")" "fm-auth TAMPERED: durum KAPALI ama 90/21 dosyaları diskte" "…TAMPERED iletisi"
rm -f "$F90"; cp "${FM_STUBS}/f21.keep" "$F21"; chmod 644 "$F21"
_status; assert_eq "$?" "1" "KAPALI ama 21 diskte → rc 1"

echo "── N18: repair — KAPALI + artakalan 90 → onarım gerekir ──"
rm -f "$F21"; cp "${FM_STUBS}/f90.keep" "$F90"; chmod 644 "$F90"
: > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
( _domconf_fm_auth_repair example.com "$rec" 1 ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "repair rc 0"
assert_eq "$(_exists "$F90")" "yok" "repair artakalan 90'ı kaldırdı (onarım YAPILDI)"
assert_eq "$(( $(grep -c '^t$' "$NGINX_T_LOG") >= 1 ? 1 : 0 ))$(_reloads)" "11" "…nginx -t + tek reload (yeniden üretim yolu)"
_status; assert_eq "$?" "0" "…sonra status temiz KAPALI (rc 0)"
: > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
( _domconf_fm_auth_repair example.com "$rec" 1 ) >"$OUTF" 2>&1
assert_eq "$?/$(_reloads)" "0/0" "(pozitif kontrol) temiz KAPALI'da repair yeniden üretmez, reload YOK"

echo "── N05: nginx-audit --quarantine — taşınacak dosya yoksa yan etki YOK ──"
_fm_reset; _on; _domconf_nginx_skeleton example.com > "${CUR_DIR}/00-custom.conf"
: > "$NGINX_T_LOG"; : > "$RELOAD_LOG"; : > "$FLOCK_LOG"
( _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "0" "temiz alan: audit --quarantine rc 0"
assert_eq "$(_cnt)" "0/0/0" "…nginx -t / reload / kilit YOK (t/reload/flock)"
assert_not_contains "$(cat "$OUTF")" "Karantinaya alınan dosya" "…'Karantinaya alınan' satırı YOK"
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/10-bad.conf"
: > "$NGINX_T_LOG"; : > "$RELOAD_LOG"; : > "$FLOCK_LOG"
( _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1
assert_eq "$(_exists "${CUR_DIR}/10-bad.conf.srvctl-rejected")" "var" "(pozitif kontrol) ihlalli dosya taşındı"
assert_eq "$(_cnt | cut -d/ -f1-2)" "1/1" "(pozitif kontrol) taşıyınca tek nginx -t + tek reload"

echo "── Q54: kök kurulumu — kayıtsız FM adında SARKAN sembolik bağ ──"
_fm_reset; ln -s "${WEB_ROOT}/yok/hedef.conf" "$F20"
( _domconf_fm_root_provision example.com 0 ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "sarkan bağ varken kök kurulumu rc 1"
assert_eq "$([[ -L "$F20" ]] && echo bag || echo DEGISTI)$(_exists "$MAN")" "bagyok" "…bağ EZİLMEDİ, köken kaydı YAZILMADI"
assert_contains "$(cat "$OUTF")" "köken kaydı OLMADAN diskte" "…gerekçe"
assert_eq "$(_exists "${WEB_ROOT}/yok/hedef.conf")" "yok" "…bağın hedefine YAZILMADI"
rm -f "$F20"
( _domconf_fm_root_provision example.com 0 ) >"$OUTF" 2>&1
assert_eq "$?/$(_exists "$F20")/$(_exists "$MAN")" "0/var/var" "(pozitif kontrol) bağ kalkınca kök kurulur"

echo "── N30: clone ön denetimi — aday kopya (cp) başarısızsa RED (boş aday 'temiz' sayılmaz) ──"
_fm_reset; printf 'client_max_body_size 5m;\n' > "${CUR_DIR}/00-custom.conf"
( _domain_clone_conf_scan example.com hedef.example.com "" 0 ) >"$OUTF" 2>&1
assert_eq "$?" "0" "(pozitif kontrol) temiz kaynak, cp çalışıyor → rc 0"
( cp() { return 1; }; _domain_clone_conf_scan example.com hedef.example.com "" 0 ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "aday kopya başarısız → rc 1 (klon DURUR)"
printf 'location /x {\n    proxy_pass http://127.0.0.1:3000;\n}\n' > "${CUR_DIR}/00-custom.conf"
( _domain_clone_conf_scan example.com hedef.example.com "" 0 ) >"$OUTF" 2>&1
assert_eq "$?" "1" "(pozitif kontrol) ihlalli kaynak → rc 1"

test_summary
