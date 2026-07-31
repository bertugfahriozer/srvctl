#!/bin/bash
# _init_run_step (lib/init.sh) — B2/Y3 regresyonu: degrade adım marker'ı
# KALICI olarak yazılıyordu.
#
# ESKİ KOD: adım fonksiyonu (ör. composer kurulamadı, 'sshd -t' patladı) hata
# durumunda 'warn "..."; return' ile bitiyordu. Argümansız 'return' bash'ta
# SON çalıştırılan komutun (warn, HER ZAMAN 0 döner) çıkış kodunu miras alır
# — yani "sadece uyar" fiilen "başarılı say" ile AYNI anlama geliyordu.
# _init_run_step bu dönüş değerine bakıp marker'ı KOŞULSUZ yazıyordu. Sonuç:
# ModSecurity/SSH hardening/Composer gibi katmanlar SESSİZCE hiç kurulmamış
# olsa bile marker dosyası oluşuyor; bir sonraki 'srvctl init' çalıştırması
# bu adımı (marker VAR diye) ATLIYOR ve BİR DAHA ASLA yeniden denemiyordu
# (--force verilmeden düzeltilemeyen KALICI fail-open; --force ise UFW
# kurallarını SIFIRLADIĞI için ayrı bir risk taşıyordu — operatör iki kötü
# seçenek arasında sıkışıyordu).
#
# DÜZELTME: adım fonksiyonu artık 'if "$func"; then ... else ... fi' ile
# çağrılır — GERÇEK dönüş değeri (0/1) kullanılır; yalnız 0 dönerse marker
# yazılır, 1 dönerse marker YAZILMAZ ve _INIT_ANY_DEGRADED=true olur (bir
# sonraki çalıştırmada --force GEREKMEDEN otomatik yeniden denenir).
#
# Bu test _init_run_step'i GERÇEK ama sahte/kontrollü adım fonksiyonlarıyla,
# izole bir SRVCTL_STATE_DIR üzerinde çağırır — gerçek 'srvctl init' HİÇ
# ÇALIŞTIRILMAZ (apt/systemctl/sshd/ufw gibi hiçbir gerçek servise dokunulmaz;
# SRVCTL_STATE_DIR core.sh'ta test-seam'lidir: 'SRVCTL_STATE_DIR="${SRVCTL_STATE_DIR:-...}"').
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/init.sh"

marker() { echo "${SRVCTL_STATE_DIR}/_init/${1}.done"; }
ex() { [[ -f "$1" ]] && echo var || echo yok; }

# ÖNEMLİ: _init_run_step çağrısını '$( ... )' İÇİNE ALMIYORUZ — komut ikamesi
# bir SUBSHELL forklar; sahte adım fonksiyonlarımızın içindeki sayaç
# ('_probe_*_calls') artışları o subshell'de kalır, üst kabuğa YANSIMAZ
# (aynı sınıf tuzak: bkz. test_deploy_health_ok.sh'taki dosya-tabanlı sayaç
# notu). Bu yüzden çağrı DOĞRUDAN (subshell'siz) yapılır, çıktısı bir
# DOSYAYA yönlendirilir; sayaç GERÇEKTEN üst kabukta artar, mesaj da
# ayrıca 'cat' ile okunur.
_out_file="$(mktemp)"

# ═══ 1) Adım fonksiyonu 0 döner → marker YAZILMALI ═══
_probe_ok_calls=0
_probe_step_ok() { _probe_ok_calls=$((_probe_ok_calls + 1)); return 0; }
SRVCTL_INIT_FORCE=false
_INIT_ANY_DEGRADED=false
_init_run_step 1 1 "probe_ok" "Test adımı (başarılı)" _probe_step_ok >/dev/null 2>&1
assert_eq "$(ex "$(marker probe_ok)")" var  "adım 0 döndü → marker YAZILDI"
assert_eq "$_probe_ok_calls"           "1" "adım fonksiyonu tam olarak 1 kez çağrıldı"
assert_eq "$_INIT_ANY_DEGRADED"        "false" "başarılı adımda _INIT_ANY_DEGRADED true olmadı"

# ═══ 2) Adım fonksiyonu 1 döner (degrade) → marker YAZILMAMALI ═══
_probe_fail_calls=0
_probe_step_fail() { _probe_fail_calls=$((_probe_fail_calls + 1)); warn "sahte başarısızlık"; return 1; }
_INIT_ANY_DEGRADED=false
_init_run_step 1 1 "probe_fail" "Test adımı (degrade)" _probe_step_fail > "$_out_file" 2>&1
out_fail="$(cat "$_out_file")"
assert_eq "$(ex "$(marker probe_fail)")" yok  "REGRESYON KAPANDI: adım 1 döndü (degrade) → marker YAZILMADI"
assert_eq "$_probe_fail_calls"            "1" "degrade adım fonksiyonu yine de 1 kez çağrıldı (denendi)"
assert_eq "$_INIT_ANY_DEGRADED"           "true" "degrade adımda _INIT_ANY_DEGRADED true'ya çekildi"
assert_contains "$out_fail" "TAM olarak tamamlanamadı" "degrade adımda operatöre yeniden deneme mesajı basıldı"

# ═══ 3) Marker VARSA adım fonksiyonu HİÇ ÇAĞRILMAMALI (atlanır) ═══
_probe_ok_calls=0
_INIT_ANY_DEGRADED=false
_init_run_step 1 1 "probe_ok" "Test adımı (tekrar)" _probe_step_ok > "$_out_file" 2>&1
out_skip="$(cat "$_out_file")"
assert_eq "$_probe_ok_calls" "0" "marker VARKEN adım fonksiyonu ÇAĞRILMADI (atlandı)"
assert_contains "$out_skip" "atlanıyor" "atlanan adım için doğru mesaj basıldı"

# ═══ 4) Degrade sonrası TEKRAR çalıştırma: marker hâlâ yok → fonksiyon
#    --force OLMADAN TEKRAR denenir — B2/Y3'ün asıl vaat ettiği davranış ═══
_probe_fail_calls=0
_INIT_ANY_DEGRADED=false
_init_run_step 1 1 "probe_fail" "Test adımı (tekrar degrade)" _probe_step_fail >/dev/null 2>&1
assert_eq "$_probe_fail_calls" "1" "--force OLMADAN degrade adım bir sonraki çalıştırmada TEKRAR denendi"
assert_eq "$(ex "$(marker probe_fail)")" yok "hâlâ degrade → marker hâlâ yok"

# 4b) Bu sefer adım fonksiyonu DÜZELİP 0 dönerse (aynı step_id) marker
#     artık yazılmalı — retry başarılı.
_probe_step_fail_then_ok() { return 0; }
_init_run_step 1 1 "probe_fail" "Test adımı (düzeldi)" _probe_step_fail_then_ok >/dev/null 2>&1
assert_eq "$(ex "$(marker probe_fail)")" var "retry BAŞARILI olunca marker artık yazıldı"

# ═══ 5) --force: marker varken bile adım YENİDEN çalıştırılır ═══
_probe_ok_calls=0
SRVCTL_INIT_FORCE=true
_init_run_step 1 1 "probe_ok" "Test adımı (force)" _probe_step_ok >/dev/null 2>&1
assert_eq "$_probe_ok_calls" "1" "--force ile marker varken bile adım YENİDEN çalıştırıldı"
SRVCTL_INIT_FORCE=false

# ═══ 6) marker dosyasının kendisi root-only (0600) + dizin (0700) olarak
#    oluşturuluyor mu? (_init_mark_done -> secure_dir/secure_file) ═══
m="$(marker probe_ok)"
assert_eq "$(_stat_mode "$m")" "600" "marker dosyası 0600 (secure_file)"
assert_eq "$(_stat_mode "$(dirname "$m")")" "700" "_init state dizini 0700 (secure_dir)"

rm -f "$_out_file"
rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
