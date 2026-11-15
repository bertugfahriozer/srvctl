#!/bin/bash
# QL4-M7 (qa2-Q64): fm-auth --script betiğinin GERÇEK yolu alanın KENDİ ağacında kalmalı.
# _domconf_fm_auth_host_script_check'in `case "${rd}/" in "${rb}/"*)` çapası kilitlenir:
# "${rb}"* (eğik çizgisiz) olsaydı ÖNEK-KARDEŞ dizin (example.com → example.com.evil: başka
# kiracının ağacı) kabul edilir ve 90 dosyası o betiğe yetki verirdi.
#   A  işlev düzeyi: önek-kardeşe göreli/mutlak/ara dizin bağı RED (gerekçe iletisiyle)
#   B  uçtan uca: fm-auth on reddedilir; 90/21/20 ve köken kaydı YAZILMAZ
#   C  meşru düzen KABUL: current → releases/N (alan içi bağ), betik alan kökünde (rd == rb sınırı)
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
DOM="${WEB_ROOT}/example.com"
EVIL="${WEB_ROOT}/example.com.evil"
AUTH_REL="modules/FileManager/Auth"
_chk() { _CHK_RC=0; _CHK_OUT=$(_domconf_fm_auth_host_script_check example.com "$1" 2>&1) || _CHK_RC=$?; }
_on() { ( _domconf_fm_auth example.com on "--script=$1" ) >"$OUTF" 2>&1; }
_clean() { _fm_reset; rm -rf -- "${DOM:?}/current" "${DOM:?}/releases" "${DOM:?}/fm-auth.php" "${EVIL:?}"; mkdir -p "$DOM"; }
_evil_tree() { mkdir -p "${EVIL}/${AUTH_REL}" "${EVIL}/current/${AUTH_REL}"; echo '<?php' > "${EVIL}/${AUTH_REL}/fm-auth.php"; }

echo "── A: önek-kardeş (example.com.evil) — işlev düzeyi ──"
_clean; _evil_tree
ln -s ../example.com.evil "${DOM}/current"
_chk "/current/${AUTH_REL}/fm-auth.php"
assert_eq "$_CHK_RC" "1" "current → ../example.com.evil (göreli, önek-kardeş) RED"
assert_contains "$_CHK_OUT" "alanın ağacı DIŞINDA: " "gerekçe: ağaç dışı"
assert_contains "$_CHK_OUT" "example.com.evil/${AUTH_REL} (alan: " "…gerçek yol (kardeş ağaç; pwd -P) gösterilir"
_clean; _evil_tree
ln -s "$EVIL" "${DOM}/current"
_chk "/current/${AUTH_REL}/fm-auth.php"
assert_eq "$_CHK_RC" "1" "current → ${EVIL} (mutlak, önek-kardeş) RED"
_clean; _evil_tree
mkdir -p "${DOM}/current/modules/FileManager"
ln -s ../../../../example.com.evil/modules/FileManager/Auth "${DOM}/current/${AUTH_REL}"
assert_eq "$([[ -f "${DOM}/current/${AUTH_REL}/fm-auth.php" ]] && echo var || echo yok)" "var" "(ön koşul) ara dizin bağı ÇÖZÜLÜR (sarkan bağ değil)"
_chk "/current/${AUTH_REL}/fm-auth.php"
assert_eq "$_CHK_RC" "1" "ara dizin (Auth) → kardeş ağaç RED"
# kardeş adın tamamı alanın önekini taşıyor: example.comx (nokta yok) da aynı sınıf
_clean; mkdir -p "${WEB_ROOT}/example.comx/${AUTH_REL}"; echo '<?php' > "${WEB_ROOT}/example.comx/${AUTH_REL}/fm-auth.php"
ln -s ../example.comx "${DOM}/current"
_chk "/current/${AUTH_REL}/fm-auth.php"
assert_eq "$_CHK_RC" "1" "current → ../example.comx (noktasız önek-kardeş) RED"
rm -rf -- "${WEB_ROOT:?}/example.comx"

echo "── B: uçtan uca fm-auth on — önek-kardeş betik REDDEDİLİR, hiçbir şey yazılmaz ──"
_clean; _evil_tree
ln -s ../example.com.evil "${DOM}/current"
_on "/current/${AUTH_REL}/fm-auth.php"; rc=$?
assert_eq "$rc" "1" "fm-auth on (önek-kardeş betik) rc 1"
assert_contains "$(cat "$OUTF")" "alanın ağacı DIŞINDA" "…gerekçe kullanıcıya gösterilir"
assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")$(_exists "$MAN")" "yokyokyokyok" "…90/21/20 ve köken kaydı YAZILMADI"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")$(_reloads)" "00" "…nginx -t / reload YOK"

echo "── C: meşru düzenler KABUL ──"
_clean
mkdir -p "${DOM}/releases/7/${AUTH_REL}"; echo '<?php' > "${DOM}/releases/7/${AUTH_REL}/fm-auth.php"
ln -s releases/7 "${DOM}/current"
_chk "/current/${AUTH_REL}/fm-auth.php"
assert_eq "$_CHK_RC" "0" "current → releases/7 (alan İÇİ bağ) KABUL"
_on "/current/${AUTH_REL}/fm-auth.php"; rc=$?
assert_eq "$rc" "4" "…uçtan uca fm-auth on başarılı (rc 4: açıldı, FM canlı sondası bu testte doğrulanamadı; F9e-3 §15/47(a), eskiden 0)"
assert_eq "$(_exists "$F90")" "var" "…90 yazıldı (pozitif kontrol: B'deki 'yok' tarama hatası değil)"
# sınır: betik alan kökünde → gerçek dizin = alan kökü (rd == rb; "${rd}/" eğik çizgisi bunu kabul ettirir)
_clean; echo '<?php' > "${DOM}/fm-auth.php"
_chk "/fm-auth.php"
assert_eq "$_CHK_RC" "0" "betik alan kökünde (gerçek dizin = alan kökü) KABUL"
_clean
_chk "/current/${AUTH_REL}/yok.php"
assert_eq "$_CHK_RC" "0" "betik henüz yoksa 0 (çağıran 'deploy sonrası var olmalı' uyarır)"

echo "── D: --script verilmezse AÇIK ileti (qa2-Q70: biçim reddine düşmesi davranışça eşdeğerdi, iletiyle ayırt edilir) ──"
_clean
( _domconf_fm_auth example.com on ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc" "1" "fm-auth on (--script yok) rc 1"
assert_contains "$(cat "$OUTF")" "--script=<yol> zorunlu" "…'--script=<yol> zorunlu' iletisi (biçim reddi DEĞİL)"
assert_eq "$(_exists "$F90")$(_exists "$F20")$(_exists "$MAN")" "yokyokyok" "…hiçbir şey yazılmadı"

test_summary
