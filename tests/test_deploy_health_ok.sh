#!/bin/bash
# _deploy_health_ok / _health_probe — sağlık kontrolü kabul politikası.
#
# REGRESYON: eski kod HTTP kodunu hardcoded bir regex/liste ile
# değerlendiriyordu ve 404/403'ü de "sağlıklı" sayıyordu. Composer/vendor
# kurulmamış (veya nginx yanlış yapılandırılmış) bir release bu durumda
# nginx'ten 404/403 alır, "sağlıklı" damgası yer ve canlıya alınırdı — yani
# BOZUK bir release otomatik rollback tetiklemeden yayına girerdi. Düzeltme:
# DEPLOY_HEALTH_OK_CODES (core.sh/load_config, varsayılan "200 301 302")
# TEK doğruluk kaynağı; 404/403 KASITLI OLARAK listede yok.
#
# _health_probe ayrıca RETRY'lı: 'systemctl reload' asenkron döner, ilk
# istek soğuk worker'a denk gelip yanlış-negatif üretebilir; bu yüzden ilk
# kabul edilen kodda ERKEN çıkar, hepsi başarısızsa SON kodu döner.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_health_ok >/dev/null 2>&1; then
    echo "  SKIP: _deploy_health_ok henüz yok"
    test_summary
    rm -rf "$WEB_ROOT"
    exit 0
fi

# ─── _deploy_health_ok: varsayılan liste (config'ten load_config ile gelir) ───
assert_eq "${DEPLOY_HEALTH_OK_CODES}" "200 301 302" "varsayılan DEPLOY_HEALTH_OK_CODES (load_config)"

assert_ok   _deploy_health_ok "200"
assert_ok   _deploy_health_ok "301"
assert_ok   _deploy_health_ok "302"
assert_fail _deploy_health_ok "404"   # REGRESYON: eskiden kabul ediliyordu
assert_fail _deploy_health_ok "403"   # REGRESYON: eskiden kabul ediliyordu
assert_fail _deploy_health_ok "500"
assert_fail _deploy_health_ok "000"
assert_fail _deploy_health_ok ""

# ─── Config'ten okunan liste GERÇEKTEN etkili mi? ───
# DEPLOY_HEALTH_OK_CODES daraltılırsa (yalnız 200) 301 artık reddedilmeli —
# hardcoded bir liste olsaydı bu değişmezdi.
(
    DEPLOY_HEALTH_OK_CODES="200"
    assert_ok   _deploy_health_ok "200"
    assert_fail _deploy_health_ok "301"
)

# ─── _health_probe: retry + erken çıkış + son kod döner ───
# DEPLOY_HEALTH_INTERVAL=0 ile testi hızlı tut (gerçek sleep'e girmeden).
#
# ÖNEMLİ: _health_probe kendi İÇİNDE 'code=$(_deploy_http_code ...)' ile bir
# komut ikamesi (nested subshell) kullanıyor ve BİZ de _health_probe'u
# 'out=$(_health_probe ...)' ile çağırıyoruz (çift iç içe subshell). Sıradan
# bir shell DEĞİŞKENİ sayaç kullanılırsa her iç subshell kendi kopyasını
# artırıp atar — üst kabuğa hiçbir artış YANSIMAZ (sayaç sonsuza dek 0'da
# kalır, dizi hep 0. elemanı döner). Bu yüzden sayaç bir DOSYADA tutulur
# (kernel düzeyinde paylaşılan durum, subshell sınırlarını aşar).
_probe_counter_file="$(mktemp)"
_probe_sequence=()

# Sıradaki kodu döndüren sahte _deploy_http_code (gerçek curl/ağ YOK).
_deploy_http_code() {
    local n
    n=$(<"$_probe_counter_file")
    n=$((n + 1))
    echo "$n" > "$_probe_counter_file"
    echo "${_probe_sequence[$((n - 1))]:-000}"
}

# 1) İlk denemede kabul edilen kod gelirse ERKEN çıkar (tekrar denemez).
echo 0 > "$_probe_counter_file"
_probe_sequence=(200 301 301)
DEPLOY_HEALTH_RETRIES=5 DEPLOY_HEALTH_INTERVAL=0 out=$(_health_probe example.com)
assert_eq "$out" "200" "ilk denemede sağlıklı kod hemen kabul edildi"
assert_eq "$(cat "$_probe_counter_file")" "1" "erken çıkış: sadece 1 kez çağrıldı"

# 2) İlk N-1 deneme başarısız, N. denemede sağlıklı -> o noktada erken çıkar.
echo 0 > "$_probe_counter_file"
_probe_sequence=(000 500 302 200)
DEPLOY_HEALTH_RETRIES=5 DEPLOY_HEALTH_INTERVAL=0 out=$(_health_probe example.com)
assert_eq "$out" "302" "3. denemede sağlıklı kod bulunur bulunmaz erken çıkıldı"
assert_eq "$(cat "$_probe_counter_file")" "3" "erken çıkış: yalnızca sağlıklı koda kadar denendi (3/5)"

# 3) Tüm denemeler başarısızsa SON görülen kod döner (retries kadar denenir).
echo 0 > "$_probe_counter_file"
_probe_sequence=(500 500 404 403 000)
DEPLOY_HEALTH_RETRIES=5 DEPLOY_HEALTH_INTERVAL=0 out=$(_health_probe example.com)
assert_eq "$out" "000" "tüm denemeler başarısız -> SON kod döndü"
assert_eq "$(cat "$_probe_counter_file")" "5" "tüm denemeler tüketildi (retries=5)"

rm -f "$_probe_counter_file"

# ═══════════════════════════════════════════════════════════════
# H6: _deploy_http_code — curl bağlantı hatası (rc=7) fonksiyonu ÇÖKERTMEMELİ,
# HER ZAMAN kullanılabilir bir HTTP kodu ("000") döndürmeli.
#
# Yukarıdaki testler _deploy_http_code'u SAHTE bir fonksiyonla EZDİ (yalnız
# _health_probe'un retry/erken-çıkış mantığını izole test etmek için).
# Burada GERÇEK _deploy_http_code'u geri getiriyoruz ve bu sefer GERÇEK
# 'curl' KOMUTUNU (ağa hiç çıkmadan, rc=7 — bağlantı reddi/timeout sınıfı
# hata) stub'luyoruz.
#
# METODOLOJİ NOTU: lib/deploy.sh'taki H6 yorumu bu durumu 'set -e altında
# script SESSİZCE ölür' olarak anlatır ('code=$(curl ...)' bir ATAMA
# ifadesidir; '||' ile test edilmezse errexit devreye girebilir). Bu iddiayı
# doğrudan '(set -e; ...)' alt-kabuğu ile ampirik olarak DOĞRULAMAYA
# ÇALIŞTIK: bash'ın komut ikamesi '$( ... )' KENDİ forkladığı alt-kabuk
# için errexit'i (inherit_errexit opt-in edilmediği sürece — srvctl bunu
# HİÇBİR YERDE açmıyor) VARSAYILAN OLARAK KAPATTIĞI VE bu davranışın komut
# ikamesinin İÇİNDE tek bir shell-fonksiyonu çağrısı olup olmamasına göre
# (fork optimizasyonu) TUTARSIZ sonuçlar ürettiği görüldü — yani "set -e
# altında çöküyor mu" sorusunun cevabı bash'ın belgelenmemiş iç
# optimizasyonlarına bağlı, DETERMİNİSTİK biçimde test edilemez (ve
# gerçek çağrı zinciri — bkz. lib/deploy.sh:1082/1213/1232, '_health_probe'
# HER ZAMAN 'code=$(_health_probe ...)' ile, o da İÇİNDE '_deploy_http_code'u
# yine '$(...)' ile çağırır — bu iç içe komut-ikamesi zinciri zaten her
# seviyede errexit'i kapatır). Bu yüzden bu test 'set -e altında ölmüyor'
# GİBİ kanıtlanamaz bir iddiayı DEĞİL, ÇAĞIRANIN GERÇEKTEN önemsediği
# GÖZLENEBİLİR SÖZLEŞMEYİ doğrular: curl ne olursa olsun dönüş değeri HER
# ZAMAN geçerli bir 3 haneli koddur ("000" dahil), ASLA boş/çökme değildir.
unset -f _deploy_http_code
source "${REPO_ROOT}/lib/deploy.sh"

curl() { return 7; }   # bağlantı reddi/timeout — ağa HİÇ çıkılmaz

code=$(_deploy_http_code "example.com")
assert_eq "$code" "000" "curl rc=7 (bağlantı hatası) → GERÇEK _deploy_http_code çökmeden '000' döndürdü"
assert_ok _deploy_http_code "example.com"   # çağıranın gördüğü çıkış kodu her zaman 0 (kendi başarısızlığını YUTAR)

# _health_probe da (GERÇEK _deploy_http_code + stub curl ile) tüm denemeleri
# tükettikten sonra asılı kalmadan (sonsuz döngüye girmeden) '000' ile
# dönmeli — DEPLOY_HEALTH_RETRIES sınırı gerçekten sonlandırıyor.
probe_out=$(DEPLOY_HEALTH_RETRIES=3 DEPLOY_HEALTH_INTERVAL=0 _health_probe example.com)
assert_eq "$probe_out" "000" "curl sürekli rc=7 dönerse _health_probe tüm denemeler sonrası '000' ile döndü (asılı kalmadı, çökmedi)"

unset -f curl

rm -rf "$WEB_ROOT"
test_summary
