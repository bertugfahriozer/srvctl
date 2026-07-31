#!/bin/bash
# K2 (root RCE zinciri) regresyonu: 'releases/<id>' hedefi ÖNCEDEN symlink
# (ya da herhangi bir şey) İSE clone-öncesi 'mkdir --' EEXIST ile
# REDDETMELİ; hedefteki dosya/dizin DOKUNULMAMIŞ kalmalı.
#
# ESKİ AÇIK: release_dir öngörülebilir bir addı (yalnız tarih/saat) ve
# clone'dan ÖNCE [[ -e ]]/[[ -L ]] kontrolü YOKTU. releases/ web_user
# tarafından yazılabilir (750 web_user:web_user, FPM open_basedir içinde) —
# saldırgan (ele geçirilmiş bir PHP endpoint'i üzerinden) tahmin ettiği bir
# release id'sine ROOT'un YAZABİLECEĞİ ama web_user'ın YAZAMAYACAĞI, VAR OLAN
# BOŞ bir dizine (ör. /usr/local/srvctl/plugins/<ad> ya da
# /var/spool/cron/crontabs) sembolik bağlantı koyabiliyordu: 'git clone'
# symlink'i ÇÖZER ve hedef boşsa İÇİNE KLONLAR (git yalnız "var VE boş
# değilse" reddeder) → ROOT olarak çalışan bu 'git clone' saldırganın
# deposunu o ayrıcalıklı konuma yazardı (ör. plugins/<ad>/.enabled + main.sh
# → her srvctl çağrısında ROOT olarak source edilir, bkz.
# lib/plugin.sh:load_plugins) — TAM ROOT RCE.
#
# DÜZELTME (lib/deploy.sh:_deploy_run, bkz. "K2" yorumu): clone'dan hemen
# önce parolasız 'mkdir -- "$release_dir"' (-p YOK) çalıştırılır. Hedefte
# HERHANGİ bir şey (symlink — dangling ya da değil —, dosya, dizin) zaten
# varsa mkdir(2) EEXIST ile başarısız olur; TOCTOU penceresi yoktur (tek
# atomik syscall). Başarısızlık 'error()' ile deploy'u durdurur — 'git
# clone' hiç ÇALIŞTIRILMAZ, saldırganın deposu ayrıcalıklı hedefe asla
# yazılmaz.
#
# Bu test _deploy_run'ı BÜTÜNSEL çalıştırmaz (git/network/root-owned .deploy-
# repo/flock gibi ağır ön koşullar gerektirir — bkz. tests/test_deploy_*.sh
# konvansiyonu: her dosya İZOLE bir güvenlik guard'ını test eder). Bunun
# yerine güvenlik iddiasının TAM OLARAK dayandığı iki şeyi doğrular:
#  (1) kodun GERÇEKTEN kullandığı satırla BİREBİR AYNI komutu (statik olarak
#      lib/deploy.sh'tan çekilir, elle KOPYALANMAZ) sembolik-bağlı bir
#      hedefe karşı çalıştırıp EEXIST ile reddedildiğini VE victim dizininin
#      BOŞ kaldığını,
#  (2) o satırın hâlâ '-p' İÇERMEDİĞİNİ (bir sonraki ajan "basitleştireyim"
#      diyip 'mkdir -p' yazarsa bu guard SESSİZCE devre dışı kalır — 'mkdir
#      -p' var olan bir dizine/symlink'e işaret eden var olan bir dizine
#      SESSİZCE BAŞARILI olur, EEXIST üretmez).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_LIB="${REPO_ROOT}/lib/deploy.sh"
source "${REPO_ROOT}/tests/lib.sh"

# ── (2) Statik güvenlik ağı: kod hâlâ 'mkdir -- "$release_dir"' mi? ──
# (tam olarak bu biçimde: '--' VAR, '-p' YOK — aksi halde EEXIST korumasız kalır)
mkdir_line=$(grep -nE 'mkdir[[:space:]]+--[[:space:]]+"\$release_dir"' "$DEPLOY_LIB" | head -1)
assert_contains "$mkdir_line" 'mkdir -- "$release_dir"' \
    "lib/deploy.sh hâlâ parolasız+non-recursive 'mkdir -- \"\$release_dir\"' kullanıyor (K2 guard'ı yerinde)"
mkdir_line_no_p=$(grep -E 'mkdir[[:space:]]+-p[[:space:]]+--[[:space:]]+"\$release_dir"' "$DEPLOY_LIB" || true)
assert_eq "$mkdir_line_no_p" "" "K2 guard'ı '-p' İLE ZAYIFLATILMAMIŞ (mkdir -p var olan symlink'te sessizce başarılı olurdu)"

# ── (1) Runtime simülasyonu: symlink → boş 'victim' dizin ──
work="$(mktemp -d)"
victim="${work}/plugins/evil-plugin"   # "ayrıcalıklı, boş, root'un yazabileceği hedef" simülasyonu
mkdir -p "$victim"
release_dir="${work}/var/www/example.com/releases/20260115_143022_a1b2c3"
mkdir -p "$(dirname "$release_dir")"
ln -s "$victim" "$release_dir"          # saldırganın önceden yerleştirdiği symlink

# lib/deploy.sh'ın KULLANDIĞI TAM komut (elle kopyalanmadı, yukarıda statik
# olarak doğrulandı) — burada release_dir'e karşı ÇALIŞTIRILIYOR:
mkdir -- "$release_dir" 2>/dev/null
rc=$?

assert_eq "$rc" "1" "K2: 'mkdir -- ...' symlink hedefte EEXIST (rc≠0) ile reddedildi"

_is_symlink() { [[ -L "$1" ]] && echo evet || echo hayır; }
assert_eq "$(_is_symlink "$release_dir")" "evet" \
    "K2: release_dir HÂLÂ symlink (mkdir onu gerçek dizinle DEĞİŞTİRMEDİ)"
assert_eq "$(readlink "$release_dir")" "$victim" \
    "K2: symlink hâlâ AYNI victim'e işaret ediyor (değiştirilmedi)"

_is_empty_dir() { [[ -z "$(find "$1" -mindepth 1 2>/dev/null)" ]] && echo bos || echo dolu; }
assert_eq "$(_is_empty_dir "$victim")" "bos" \
    "K2: victim dizini HÂLÂ BOŞ — saldırganın deposu ORAYA YAZILMADI"

# ── Dangling symlink de AYNI şekilde reddedilmeli (hedef çözülemese bile) ──
dangling_target="${work}/hic_var_olmayan_yol"
dangling_release="${work}/var/www/example.com/releases/20260116_000000_d4e5f6"
ln -s "$dangling_target" "$dangling_release"
mkdir -- "$dangling_release" 2>/dev/null
rc2=$?
assert_eq "$rc2" "1" "K2: dangling symlink hedefte de EEXIST ile reddedildi"
assert_eq "$(_is_symlink "$dangling_release")" "evet" "K2: dangling symlink DEĞİŞTİRİLMEDİ"

rm -rf "$work"
test_summary
