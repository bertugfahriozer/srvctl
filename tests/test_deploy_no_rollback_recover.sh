#!/bin/bash
# BUG C regresyon testi — sağlık kontrolü BAŞARISIZ olduğunda VE geri
# dönülecek gerçek bir önceki release YOKSA, 'public_html' HİÇBİR senaryoda
# eksik/kırık bırakılmamalı (KRİTİK DEĞİŞMEZ: fonksiyon çalıştıktan SONRA
# '<base>/public_html' HER ZAMAN gerçek bir dizin olarak VAR olmalı).
#
# GERÇEK VM BUG'I — İLK TUR (koordinatör raporu, Symfony deploy'u, Ubuntu
# 22.04):
#     ⚠  Sağlık kontrolü BAŞARISIZ (HTTP 403) — otomatik rollback!
#     ✗  Geri alınacak önceki sürüm yok (release temizlendi). Sağlık: HTTP 403
# Rollback SONRASI ölçülen son durum: 'current'/'public_html' KIRIK
# (dangling) symlink, orijinal içerik 'public_html.bak.<ts>'ye taşınmış ama
# GERİ YÜKLENMEMİŞ — domain deploy ÖNCESİNDEN DAHA KÖTÜ (kalıcı kırık
# symlink + kaybolmuş placeholder).
#
# GERÇEK VM BUG'I — İKİNCİ TUR (koordinatör HOST doğrulaması, AYNI kurulum,
# ilk düzeltmeden SONRA): kırık symlink kaldırıldı ('_deploy_no_rollback_
# recover' çalıştı) ama 'public_html' hiç YENİDEN OLUŞTURULMADI — ne dizin
# ne symlink kaldı:
#     /var/www/symfony.local/  (public_html YOK)
#       public_html.bak.1785514139/   (diskte DURUYOR, kullanılmadı)
#       releases/                    (boş)
# php-fpm pool'unun 'chdir = /public_html' direktifi bu yolun VAR OLMASINI
# ZORUNLU kılar (config-test'te doğrulanır) — yokluk TÜM dokümante edilmiş
# kurtarma yollarını (php-switch, security harden-fpm --apply, domain
# repair) FPM aktivasyon aşamasında ÇÖKERTTİ; domain elle müdahale olmadan
# KURTARILAMAZ hale geldi. Dikkat çekici: bir ÖNCEKİ başarısız deploy'un
# bıraktığı 'public_html.bak.<ts>' diskte DURUYORDU ama ilk düzeltme yalnız
# BU ÇALIŞMANIN İZLEDİĞİ yedeği (public_html_backup) biliyordu, diskteki
# eski yedeği GÖRMEDİ.
#
# DÜZELTME (üç kademeli, sırayla dene): (1) bu çalışmanın izlediği yedek
# (public_html_backup) varsa geri yükle; (2) yoksa base'teki EN YENİ
# 'public_html.bak.*'ı (dizin ADINDAKİ epoch'a göre, mtime'a GÜVENMEDEN)
# geri yükle, operatöre HANGİ yedek ve NE ZAMAN olduğunu söyler; (3) ikisi
# de yoksa doğru sahiplik/izin+ACL ile BOŞ bir public_html oluştur — 'chdir'
# invariant'ını garanti eder, domaini en azından YÖNETİLEBİLİR bırakır.
# 'current' (varsa) her durumda ayrıca temizlenir.
#
# Bu dosya git clone/health-probe/systemctl GEREKTİRMEDEN (bkz. tests/lib.sh,
# macOS'ta çalışır) doğrudan '_deploy_no_rollback_recover'ı dosya sistemi
# fixture'larıyla test eder.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_no_rollback_recover >/dev/null 2>&1; then
    echo "  SKIP: _deploy_no_rollback_recover henüz yok"
    test_summary
    rm -rf "$WEB_ROOT"
    exit 0
fi

# DİKKAT: düz '-e' KIRIK (dangling) bir symlink için YANLIŞLIKLA "yok" der
# ('-e' sembolik bağlantının HEDEFİNİ takip eder; hedef yoksa YANLIŞ döner
# — ama symlink'in KENDİSİ hâlâ diskte durur). '-L' EKLENEREK "sembolik
# bağlantının KENDİSİ var mı" da kontrol edilir (bkz. ilk mutasyon testi
# notu — bu ayrım olmadan bir mutasyon YAKALANMIYORDU).
ex() { [[ -e "$1" || -L "$1" ]] && echo var || echo yok; }
islink() { [[ -L "$1" ]] && echo evet || echo hayir; }

# KRİTİK DEĞİŞMEZ (koordinatörün istediği en önemli assertion): fonksiyon
# çalıştıktan SONRA public_dir HER ZAMAN gerçek bir dizin olarak VAR
# olmalı — ne eksik, ne (kırık ya da sağlıklı) bir symlink. php-fpm
# pool'unun 'chdir' direktifi başka türlüsünü KABUL ETMEZ.
public_html_saglam() { [[ -d "$1" && ! -L "$1" ]] && echo saglam || echo BOZUK; }

# ═══ Senaryo 1 — VM'DE BİREBİR ÖLÇÜLEN durum: İLK deploy, BU ÇALIŞMANIN
#     izlediği '.bak' VAR (1. kademe) ═══
base1="${WEB_ROOT}/symfony.local"
mkdir -p "$base1"
backup1="${base1}/public_html.bak.1785514139"
mkdir -p "$backup1"
echo "orijinal placeholder sayfasi" > "${backup1}/index.php"
ln -sfn "releases/20260731_190854_009bf1" "${base1}/public_html"   # KIRIK (hedef YOK)
ln -sfn "releases/20260731_190854_009bf1" "${base1}/current"       # KIRIK (hedef YOK)

_deploy_no_rollback_recover "$base1" "${base1}/public_html" "$backup1" "web_symfony_local"

assert_eq "$(public_html_saglam "${base1}/public_html")" "saglam" \
    "Senaryo1 [KRİTİK]: public_html fonksiyon SONRASI gerçek bir dizin olarak VAR"
assert_eq "$(islink "${base1}/public_html")" "hayir" \
    "Senaryo1: public_html artık kırık bir symlink DEĞİL"
assert_eq "$(cat "${base1}/public_html/index.php" 2>/dev/null)" "orijinal placeholder sayfasi" \
    "Senaryo1: public_html ORİJİNAL (bu çalışmanın izlediği) placeholder içeriğine geri yüklendi"
assert_eq "$(ex "$backup1")" "yok" \
    "Senaryo1: '.bak' dizini yerinden taşındı (artık eski konumunda yok — mv, cp değil)"
assert_eq "$(ex "${base1}/current")" "yok" \
    "Senaryo1: 'current' KIRIK symlink'i kaldırıldı"

# ═══ Senaryo 2 — bu çalışmanın izlediği yedek YOK, AMA diskte ÖNCEKİ bir
#     başarısız deploy'dan kalma 'public_html.bak.*' VAR (2. kademe) —
#     koordinatörün HOST'ta gözlemlediği TAM senaryo. BİRDEN FAZLA yedek
#     varsa EN YENİSİ (en büyük epoch) seçilmeli. ═══
base2="${WEB_ROOT}/eskiyedekli.example.com"
mkdir -p "$base2"
eski_bak="${base2}/public_html.bak.1700000000"
yeni_bak="${base2}/public_html.bak.1785514139"
mkdir -p "$eski_bak" "$yeni_bak"
echo "ESKI yedek (kullanilmamali)" > "${eski_bak}/index.php"
echo "YENI yedek (bu secilmeli)" > "${yeni_bak}/index.php"
ln -sfn "releases/20260101_000001" "${base2}/public_html"   # KIRIK
ln -sfn "releases/20260101_000001" "${base2}/current"       # KIRIK

out2=$(_deploy_no_rollback_recover "$base2" "${base2}/public_html" "" "web_eskiyedekli" 2>&1)

assert_eq "$(public_html_saglam "${base2}/public_html")" "saglam" \
    "Senaryo2 [KRİTİK]: bu çalışmanın izlediği yedek yoksa da public_html fonksiyon SONRASI VAR (dizin)"
assert_eq "$(cat "${base2}/public_html/index.php" 2>/dev/null)" "YENI yedek (bu secilmeli)" \
    "Senaryo2: DİSKTEKİ birden fazla '.bak'tan EN YENİSİ (en büyük epoch) geri yüklendi, eskisi DEĞİL"
assert_eq "$(ex "$yeni_bak")" "yok" "Senaryo2: seçilen yedek yerinden taşındı"
assert_eq "$(ex "$eski_bak")" "var" \
    "Senaryo2: SEÇİLMEYEN eski yedek dokunulmadan diskte kaldı (yanlışlıkla silinmedi)"
assert_contains "$out2" "public_html.bak.1785514139" \
    "Senaryo2: operatöre HANGİ yedeğin geri yüklendiği AÇIKÇA söyleniyor"
assert_eq "$(ex "${base2}/current")" "yok" "Senaryo2: current de aynı şekilde kaldırılır"

# ═══ Senaryo 3 — HİÇBİR yedek yok (ne bu çalışmanın izlediği ne diskte bir
#     '.bak') -> BOŞ public_html OLUŞTURULUR (3. kademe) — koordinatörün
#     HOST'ta yakaladığı asıl BOŞLUK: public_html tamamen YOK bırakılmıştı. ═══
base3="${WEB_ROOT}/hicyedeksiz.example.com"
mkdir -p "$base3"
ln -sfn "releases/20260101_000001" "${base3}/public_html"   # KIRIK
ln -sfn "releases/20260101_000001" "${base3}/current"       # KIRIK

out3=$(_deploy_no_rollback_recover "$base3" "${base3}/public_html" "" "web_hicyedeksiz" 2>&1)

assert_eq "$(public_html_saglam "${base3}/public_html")" "saglam" \
    "Senaryo3 [KRİTİK]: hiç yedek yoksa BİLE public_html fonksiyon SONRASI VAR (BOŞ dizin) — chdir invariant'ı"
assert_eq "$(find "${base3}/public_html" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "Senaryo3: oluşturulan public_html gerçekten BOŞ (sahte içerik uydurulmadı)"
assert_contains "$out3" "BOŞ bir public_html oluşturuldu" \
    "Senaryo3: operatöre BOŞ dizin oluşturulduğu AÇIKÇA söyleniyor"
assert_eq "$(ex "${base3}/current")" "yok" "Senaryo3: current de kaldırılır"

# ═══ Senaryo 4 — public_html_backup verilmiş ama dizin GERÇEKTE yok (ör.
#     daha önce elle silinmiş) VE diskte başka '.bak' de yok -> fail-closed:
#     var olmayan bir kaynaktan 'mv' DENENMEZ, 3. kademeye (boş dizin) düşer ═══
base4="${WEB_ROOT}/ghostbak.example.com"
mkdir -p "$base4"
ln -sfn "releases/20260101_000001" "${base4}/public_html"
assert_ok _deploy_no_rollback_recover "$base4" "${base4}/public_html" "${base4}/public_html.bak.YOK" "web_x"
assert_eq "$(public_html_saglam "${base4}/public_html")" "saglam" \
    "Senaryo4 [KRİTİK]: var olmayan bir '.bak' yolu verilse BİLE public_html SONUNDA VAR (3. kademeye düşer)"

# ═══ Senaryo 5 — public_html GERÇEK bir dizinse (symlink DEĞİL) VE backup
#     yoksa DOKUNULMAZ (yanlışlıkla canlı bir dizini silme riski YOK) ═══
base5="${WEB_ROOT}/realdir.example.com"
mkdir -p "$base5"
mkdir -p "${base5}/public_html"
echo "gercek dizin" > "${base5}/public_html/index.php"
assert_ok _deploy_no_rollback_recover "$base5" "${base5}/public_html" "" "web_x"
assert_eq "$(public_html_saglam "${base5}/public_html")" "saglam" \
    "Senaryo5 [KRİTİK]: zaten sağlam bir dizinse fonksiyon SONRASI da sağlam kalır"
assert_eq "$(cat "${base5}/public_html/index.php" 2>/dev/null)" "gercek dizin" \
    "Senaryo5: public_html GERÇEK bir dizinse (symlink değil) ve backup yoksa İÇERİĞİNE DOKUNULMAZ"

# ═══ Senaryo 6 — 'current' hiç yoktu (dosya/symlink OLARAK) — fonksiyon
#     var-olmayan bir dosya için PATLAMAMALI, public_html yine sağlam kalmalı ═══
base6="${WEB_ROOT}/nocurrent.example.com"
mkdir -p "$base6"
ln -sfn "releases/20260101_000001" "${base6}/public_html"
assert_ok _deploy_no_rollback_recover "$base6" "${base6}/public_html" "" "web_x"
assert_eq "$(public_html_saglam "${base6}/public_html")" "saglam" \
    "Senaryo6 [KRİTİK]: 'current' hiç yoktu senaryosunda da public_html sağlam kalır"

rm -rf "$WEB_ROOT"
test_summary
