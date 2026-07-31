#!/bin/bash
# _deploy_prune_one güvenlik guard'ları.
# Eski kod: ( cd releases && ls -t | tail -n +6 | xargs -r rm -rf )
#   - canlı release koruması YOK
#   - mtime'a güveniyor: releases/ web_user yazılabilir ve FPM open_basedir'ı
#     içinde → ele geçirilmiş uygulama PHP touch() ile ileri tarihli sahte
#     dizinler üretip CANLI release'i sildirebiliyordu (anında tam kesinti)
#   - 'rm' argümanlarında '--' yok, 'ls' parse ediliyor
#
# Y1 DÜZELTMESİ (bu dosyanın 2. nesli): "yalnız biçim" beyaz listesi
# (^[0-9]{8}_[0-9]{6}$) TEK BAŞINA yetersizdi — 'releases/99999999_999999'
# bu deseni geçiyor VE 'sort -r' onu HER ZAMAN en başa koyuyordu. web_user
# (releases/ yazılabilir, FPM open_basedir içinde) bunu ekleyip prune'un
# keep-penceresini sahte girdiyle doldurarak GERÇEK eski release'lerin
# (rollback hedeflerinin) kalıcı silinmesine yol açabiliyordu
# (anti-forensics/persistence: operatör rollback yapamaz hale gelir).
# _deploy_is_release_id artık hem takvimsel ALAN ARALIĞINI (ay 1-12, gün
# 1-31...) hem de "GELECEK TARİH" reddini kontrol ediyor — bu dosya hem
# ESKİ senaryoyu (karışık sahte+gerçek, tek fixture) hem YENİ saldırı
# senaryosunu (izole, "5 sahte + 4 gerçek" — bkz. aşağı) hem de
# _deploy_is_release_id'nin kendisini doğrudan test ediyor.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

# assert_ok/assert_fail komutu argv olarak çalıştırır (mesaj parametresi YOK),
# bu yüzden varlık kontrolünü stringe çevirip assert_eq ile karşılaştırıyoruz.
ex() { [[ -d "$1" ]] && echo var || echo yok; }

d="example.com"; base="${WEB_ROOT}/${d}"
mkdir -p "${base}/releases"
for id in 20260101_000001 20260102_000002 20260103_000003 \
          20260104_000004 20260105_000005 20260106_000006 20260107_000007; do
    mkdir -p "${base}/releases/${id}/public"
done

# Saldırgan artefaktları: desene uymayan dizin + ileri tarihli sahte release
mkdir -p "${base}/releases/sahte_release"
mkdir -p "${base}/releases/99999999_999999"

# CANLI = EN ESKİ release (rollback sonrası gerçek senaryo), mtime'ı da en eski
ln -sfn "releases/20260101_000001/public" "${base}/public_html"
touch -t 200001010000 "${base}/releases/20260101_000001" 2>/dev/null || true

_deploy_prune_one "$d" 3 apply false >/dev/null 2>&1

assert_eq "$(ex "${base}/releases/20260101_000001")" var "CANLI release korundu (keep dışı + en eski mtime)"
assert_eq "$(ex "${base}/releases/sahte_release")"   var "desene uymayan dizine dokunulmadı"
assert_eq "$(ex "${base}/releases/99999999_999999")" var "en yeni 3 korundu (1/3)"
assert_eq "$(ex "${base}/releases/20260107_000007")" var "en yeni 3 korundu (2/3)"
assert_eq "$(ex "${base}/releases/20260106_000006")" var "en yeni 3 korundu (3/3)"
# NOT: '99999999_999999' _deploy_is_release_id tarafından (gelecek tarih —
# ay=99 zaten takvimsel olarak geçersiz) aday listesinden TAMAMEN çıkarılıyor;
# bu yüzden keep=3 penceresi GERÇEK 3 release'i (07,06,05) kapsıyor ve
# 20260105_000005 artık HAYATTA KALIYOR (eski beklenti 'yok' idi — Y1
# düzeltmesinden ÖNCEKİ, sahte girdinin pencereyi işgal ettiği yanlış
# davranışı doğruluyordu; bkz. bu dosyanın başlık yorumu).
assert_eq "$(ex "${base}/releases/20260105_000005")" var "en yeni 3'e giren gerçek release korundu (sahte artık pencereyi işgal edemiyor)"
assert_eq "$(ex "${base}/releases/20260104_000004")" yok "keep dışındaki eski release silindi (1/2)"
assert_eq "$(ex "${base}/releases/20260103_000003")" yok "keep dışındaki eski release silindi (2/2)"
assert_eq "$(ex "${base}/releases/20260102_000002")" yok "keep dışındaki eski release silindi (canlının bir üstü)"

# ── Fail-closed: public_html çözümlenemiyorsa HİÇBİR ŞEY silinmez ──
d2="fail.example.com"; base2="${WEB_ROOT}/${d2}"
mkdir -p "${base2}/releases"
for id in 20260101_000001 20260102_000002 20260103_000003 20260104_000004; do
    mkdir -p "${base2}/releases/${id}"
done
# public_html YOK
_deploy_prune_one "$d2" 2 apply false >/dev/null 2>&1
assert_eq "$(ex "${base2}/releases/20260101_000001")" var "public_html yoksa prune reddedildi (1/2)"
assert_eq "$(ex "${base2}/releases/20260102_000002")" var "public_html yoksa prune reddedildi (2/2)"

# ── Dry-run hiçbir şeyi silmez ──
d3="dry.example.com"; base3="${WEB_ROOT}/${d3}"
mkdir -p "${base3}/releases"
for id in 20260101_000001 20260102_000002 20260103_000003 20260104_000004; do
    mkdir -p "${base3}/releases/${id}"
done
ln -sfn "releases/20260104_000004" "${base3}/public_html"
out=$(_deploy_prune_one "$d3" 2 dry false 2>&1)
assert_eq "$(ex "${base3}/releases/20260101_000001")" var "dry-run silmedi"
assert_contains "$out" "silinecek: releases/20260101_000001" "dry-run adayı raporladı"

# ── keep alt sınırı: 2'nin altı güvenli varsayılana düşer ──
out2=$(_deploy_prune "$d3" --keep=0 2>&1)
assert_contains "$out2" "5 kullanılıyor" "keep<2 reddedilip güvenli varsayılana düşüldü"

# ── Traversal: domain_exists artık validate_domain kapısından geçiyor ──
out3=$(_deploy_prune_one "../../etc" 2 apply false 2>&1)
assert_contains "$out3" "Domain yok" "'../..' domain adı reddedildi"

# ══════════════════════════════════════════════════════════════════
# İZOLE SALDIRI SENARYOSU (Y1): "5 sahte gelecek-tarihli + 4 gerçek release"
# Yukarıdaki karma fixture (7 gerçek + 1 sahte + 1 desen-dışı) düzeltmeyi
# doğruluyor ama saldırının TAM etkisini göstermiyor. Burada saf hâliyle:
# operatör keep=3 istiyor, releases/ 4 GERÇEK release içeriyor (biri canlı,
# en eski — tipik rollback-sonrası durum) + saldırganın önceden yerleştirdiği
# 5 adet '99999999_99999{1..5}' (web_user tarafından yazılabilir, ör. ele
# geçirilmiş bir PHP endpoint'i ile).
#
# ESKİ (yalnız-biçim) kodda: 'sort -r' STRING sıralaması sahteleri
# ('99999999...') HER ZAMAN gerçek release'lerin ('2026...') ÖNÜNE koyar.
# keep=3 penceresi 3 sahteyle dolar; idx>3 olan TÜM gerçek release'ler
# (canlı olan HARİÇ — o ayrı bir guard'la korunur) SİLİNİR. Yani operatör
# "son 3'ü tut" derken fiilen "canlı hariç HİÇBİRİNİ tutma" sonucunu alırdı.
#
# YENİ kodda: sahteler _deploy_is_release_id'de eleniyor (gelecek tarih),
# _deploy_release_ids çıktısına HİÇ girmiyorlar → ne "tutulan" ne "silinen"
# sayılıyorlar, dokunulmadan releases/ altında kalıyorlar (ayrı bir temizlik
# gerektirir — bu testin kapsamı DEĞİL, yalnızca "gerçek release'leri
# çalmasınlar" garantisi). keep=3 penceresi artık SADECE 4 gerçek release
# üzerinden hesaplanıyor: en yeni 3'ü pencereyle, en eski (canlı) olanı
# ayrı guard'la korunuyor → SIFIR gerçek release silinir.
d4="attack.example.com"; base4="${WEB_ROOT}/${d4}"
mkdir -p "${base4}/releases"
for id in 99999999_999991 99999999_999992 99999999_999993 \
          99999999_999994 99999999_999995; do
    mkdir -p "${base4}/releases/${id}"
done
for id in 20260201_000001 20260202_000002 20260203_000003 20260204_000004; do
    mkdir -p "${base4}/releases/${id}"
done
# Canlı = en eski gerçek release (rollback sonrası tipik durum)
ln -sfn "releases/20260201_000001" "${base4}/public_html"

_deploy_prune_one "$d4" 3 apply false >/dev/null 2>&1

assert_eq "$(ex "${base4}/releases/20260201_000001")" var "SALDIRI: canlı (en eski gerçek) korundu"
assert_eq "$(ex "${base4}/releases/20260202_000002")" var "SALDIRI: gerçek release korundu — sahteler pencereyi işgal edemedi (1/3)"
assert_eq "$(ex "${base4}/releases/20260203_000003")" var "SALDIRI: gerçek release korundu — sahteler pencereyi işgal edemedi (2/3)"
assert_eq "$(ex "${base4}/releases/20260204_000004")" var "SALDIRI: gerçek release korundu — sahteler pencereyi işgal edemedi (3/3)"
for i in 1 2 3 4 5; do
    assert_eq "$(ex "${base4}/releases/99999999_99999${i}")" var "SALDIRI: sahte gelecek-tarihli dizin dokunulmadı (desen dışı sayıldığı için, ${i}/5)"
done

# ══════════════════════════════════════════════════════════════════
# _deploy_is_release_id DOĞRUDAN TESTLERİ
# Y1'in gerçek düzeltmesi burada: biçim + takvimsel alan aralığı + gelecek-
# tarih reddi. '_deploy_civil_epoch' SAF bash aritmetiğidir ('date -d' GNU-
# only, macOS'ta yok) — bu testlerin macOS'ta PASS vermesi, algoritmanın
# hiçbir GNU-özel araca ihtiyaç duymadığının kanıtıdır.
assert_ok   _deploy_is_release_id "20260115_143022"        # geçerli, sonesiz
assert_ok   _deploy_is_release_id "20260115_143022_a1b2c3" # geçerli + sonek (geriye dönük uyumluluk)
assert_fail _deploy_is_release_id "20261301_000000"        # ay=13 takvimsel olarak geçersiz
assert_fail _deploy_is_release_id "20260132_000000"        # gün=32 takvimsel olarak geçersiz
assert_fail _deploy_is_release_id "99991231_235959"        # biçim+alan aralığı GEÇERLİ ama gelecek tarih — reddedilir
assert_fail _deploy_is_release_id "sahte_release"          # biçim dışı
assert_fail _deploy_is_release_id "2026011_143022"         # tarih kısmı 7 haneli (8 olmalı) — biçim dışı
assert_fail _deploy_is_release_id "20260115_14302"         # saat kısmı 5 haneli (6 olmalı) — biçim dışı
assert_fail _deploy_is_release_id ""                       # boş girdi

# _deploy_civil_epoch: SABİT/bilinen takvim noktalarıyla doğrulama (harici
# 'date' aracına bağımlı OLMADAN — Unix epoch tanımı gereği 1970-01-01
# 00:00:00 = 0; ikinci değer Python 'datetime.timestamp()' ile bağımsız
# doğrulandı, bkz. rapor).
assert_eq "$(_deploy_civil_epoch 1970 1 1 0 0 0)"    "0"          "_deploy_civil_epoch: Unix epoch başlangıcı"
assert_eq "$(_deploy_civil_epoch 2026 1 1 0 0 0)"    "1767225600" "_deploy_civil_epoch: bilinen referans tarih (2026-01-01 UTC)"
assert_eq "$(_deploy_civil_epoch 2026 7 15 14 30 22)" "1784125822" "_deploy_civil_epoch: bilinen referans tarih+saat (2026-07-15 14:30:22 UTC)"

rm -rf "$WEB_ROOT"
test_summary
