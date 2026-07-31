#!/bin/bash
# ZİNCİR testi — koordinatör bulgusu (GERÇEK HOST, dev.designwestgate.art).
#
# ÖNCEKİ HATA SINIFI (bu oturumda tekrar yaşandı — "izole halka yeşil,
# gerçek zincir sessiz"): tests/test_deploy_health_per_domain.sh
# '_deploy_health_report_override'ı İZOLE çağırıyordu ve doğru çıktı
# üretiyordu — bu YANLIŞ bir güven verdi. Gerçek üretimde per-domain
# HEALTH_OK_CODES İŞLEVSEL olarak doğru çalıştı (401 kabul edildi, rollback
# tetiklenmedi) ama görünürlük satırı ('... KABUL EDİLEN kod olarak
# yapılandırılmış') deploy/health çıktısının TAMAMINDA HİÇ görünmedi —
# çünkü probe+görünürlük çağrısı ÜÇ AYRI yerde (_deploy_run/_deploy_rollback/
# _deploy_health) elle TEKRARLANIYORDU: "bir yerde eklendi, güncel değil/
# unutuldu" riski YAPISAL olarak vardı, izole bir fonksiyon testi bunu
# YAKALAYAMAZ (aynı sınıf: bu oturumdaki putenv fail-open ve APT pin
# regresyonları da "halka" testinde görünmüyordu).
#
# DÜZELTME (lib/deploy.sh): probe+görünürlük TEK bir fonksiyona
# (_deploy_health_gate) konsolide edildi; üç çağrı yeri de ARTIK bunu
# çağırıyor. Bu, "görünürlük bir call-site'da unutuldu" sınıfı regresyonu
# YAPISAL olarak imkansız kılar — değiştirilecek TEK yer var.
#
# BU TEST İKİ KATMANDA doğrular (sadece halka DEĞİL, zincir):
#   0) STATİK: ÜÇ çağrı yeri de GERÇEKTEN _deploy_health_gate kullanıyor mu
#      (kaynak-inceleme, tests/test_deploy_privdrop.sh'taki awk-blok
#      izolasyonu deseniyle AYNI).
#   1) DİNAMİK: 'srvctl deploy health <domain>' KOMUTUNUN KENDİSİNİ
#      (_deploy_health — gerçek komut girişi) çalıştırıp TAM (stdout+stderr)
#      çıktıda görünürlüğün var olduğunu doğrular.
#   2) DİNAMİK: 'srvctl rollback <domain>' KOMUTUNUN KENDİSİNİ (_deploy_rollback)
#      sahte systemctl/http_code ile çalıştırıp AYNI şeyi doğrular.
#   3) DİNAMİK: 'srvctl deploy <domain>' TAM ZİNCİRİNİ (_deploy_run — git
#      clone'dan health check'e kadar HER adım) sahte git/chown/systemctl/php
#      ile GERÇEKTEN çalıştırıp koordinatörün HOST'ta ölçtüğü SENARYOYU
#      (401 dönen, Basic-auth korumalı bir staging sitesi) birebir tekrarlar
#      ve görünürlüğün TAM deploy çıktısında yer aldığını doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

if ! declare -F _deploy_health_gate >/dev/null 2>&1; then
    echo "  SKIP: _deploy_health_gate henüz yok"
    test_summary
    rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# 0) STATİK KİLİT: üç çağrı yeri de GATE üzerinden geçiyor mu?
#    (bkz. tests/test_deploy_privdrop.sh:74 AYNI awk-blok-izolasyon deseni)
# ═══════════════════════════════════════════════════════════════
echo "== 0) Statik kilit: _deploy_run / _deploy_rollback / _deploy_health GATE'i çağırıyor =="
run_block=$(awk '/^_deploy_run\(\) \{/{flag=1} flag{print} /^\}/{if (flag) exit}' "${REPO_ROOT}/lib/deploy.sh")
rollback_block=$(awk '/^_deploy_rollback\(\) \{/{flag=1} flag{print} /^\}/{if (flag) exit}' "${REPO_ROOT}/lib/deploy.sh")
health_block=$(awk '/^_deploy_health\(\) \{/{flag=1} flag{print} /^\}/{if (flag) exit}' "${REPO_ROOT}/lib/deploy.sh")

assert_contains "$run_block"      '_deploy_health_gate "$domain"' "_deploy_run adım 9 GATE'i çağırıyor"
assert_contains "$rollback_block" '_deploy_health_gate "$domain"' "_deploy_rollback GATE'i çağırıyor"
assert_contains "$health_block"   '_deploy_health_gate "$domain"' "_deploy_health GATE'i çağırıyor"
# Eski elle-tekrarlanan iki-satırlı desen GERİ GELMEMELİ (tek kaynak ilkesi).
assert_not_contains "$run_block"      '_deploy_health_report_override "$domain" "$code"' "_deploy_run raporu artık ELLE TEKRARLAMIYOR"
assert_not_contains "$rollback_block" '_deploy_health_report_override "$domain" "$code"' "_deploy_rollback raporu artık ELLE TEKRARLAMIYOR"
assert_not_contains "$health_block"   '_deploy_health_report_override "$domain" "$code"' "_deploy_health raporu artık ELLE TEKRARLAMIYOR"

# ═══════════════════════════════════════════════════════════════
# 1) ZİNCİR: 'srvctl deploy health <domain>' — gerçek komut girişi
# ═══════════════════════════════════════════════════════════════
echo "== 1) Zincir: _deploy_health (gerçek komut girişi) =="

dom_health="dev.designwestgate.test"
mkdir -p "${WEB_ROOT}/${dom_health}"
printf 'HEALTH_OK_CODES=200 301 302 401\n' > "${WEB_ROOT}/${dom_health}/.srvctl-meta"
_deploy_http_code() { echo "401"; }

# Koordinatörün HOST'ta yaptığı GİBİ: stdout+stderr TEK bir akışta ('> log 2>&1').
out_health=$(DEPLOY_HEALTH_RETRIES=1 DEPLOY_HEALTH_INTERVAL=0 _deploy_health "$dom_health" 2>&1)
rc_health=$?
assert_eq "$rc_health" "0" "'deploy health': HTTP 401 bu domain için BAŞARILI sayıldı (işlevsel taraf — bozulmadı)"
assert_contains "$out_health" "sağlıklı (HTTP 401)" "'deploy health' başarı mesajı HTTP 401 gösteriyor"
assert_contains "$out_health" "HEALTH_OK_CODES" \
    "'deploy health' GERÇEK çıktısında override görünürlüğü VAR (koordinatörün HOST'ta 'HİÇBİR EŞLEŞME' bulduğu tam senaryo)"
assert_contains "$out_health" "KABUL EDİLEN kod olarak yapılandırılmış" \
    "'deploy health' çıktısı 401'in bu domain için ÖZEL kabul edildiğini AÇIKÇA söylüyor"

# Override YOKSA (başka bir domain, AYNI kod yolu): hem 401 hâlâ reddedilir
# HEM DE görünürlük mesajı SESSİZDİR (gürültü yok) — izolasyon zincirde de geçerli.
dom_plain="plain.designwestgate.test"
mkdir -p "${WEB_ROOT}/${dom_plain}"
out_health2=$(DEPLOY_HEALTH_RETRIES=1 DEPLOY_HEALTH_INTERVAL=0 _deploy_health "$dom_plain" 2>&1)
rc_health2=$?
assert_eq "$([[ "$rc_health2" != "0" ]] && echo basarisiz || echo basarili)" "basarisiz" \
    "override YOKKEN 'deploy health' 401'i hâlâ BAŞARISIZ sayıyor (global gevşemedi)"
assert_not_contains "$out_health2" "HEALTH_OK_CODES" "override yokken çıktı GERÇEKTEN sessiz"

# ═══════════════════════════════════════════════════════════════
# 2) ZİNCİR: 'srvctl rollback <domain>' — gerçek komut girişi
# ═══════════════════════════════════════════════════════════════
echo "== 2) Zincir: _deploy_rollback (gerçek komut girişi) =="

dom_rb="rb.designwestgate.test"
base_rb="${WEB_ROOT}/${dom_rb}"
mkdir -p "${base_rb}/releases/20260101_000001/public" "${base_rb}/releases/20260101_000002/public"
printf 'HEALTH_OK_CODES=200 301 302 401\n' > "${base_rb}/.srvctl-meta"
# En yeni release (000002) CANLI gibi kurulur — rollback bir öncekine (000001) döner.
_deploy_link_current "$base_rb" "releases/20260101_000002/public" >/dev/null 2>&1
_deploy_link_current "$base_rb" "releases/20260101_000002" "current" >/dev/null 2>&1

systemctl() { return 0; }
_deploy_http_code() { echo "401"; }

out_rb=$(DEPLOY_HEALTH_RETRIES=1 DEPLOY_HEALTH_INTERVAL=0 _deploy_rollback "$dom_rb" 2>&1)
rc_rb=$?
assert_eq "$rc_rb" "0" "'rollback': 401 bu domain için kabul edildi, rollback BAŞARILI raporlandı"
assert_contains "$out_rb" "Rollback başarılı" "rollback başarı mesajı basıldı"
assert_contains "$out_rb" "HEALTH_OK_CODES" "rollback GERÇEK çıktısında override görünürlüğü VAR"
assert_contains "$out_rb" "KABUL EDİLEN kod olarak yapılandırılmış" "rollback çıktısı 401'in ÖZEL kabul edildiğini AÇIKÇA söylüyor"
unset -f systemctl

# ═══════════════════════════════════════════════════════════════
# 3) TAM ZİNCİR: 'srvctl deploy <domain> <branch>' — _deploy_run baştan sona.
#    Koordinatörün HOST'ta ölçtüğü TAM senaryo: git clone -> ... -> [9/9]
#    sağlık kontrolü (401 kabul) -> "Deploy Tamamlandı". Hiçbir gerçek git/
#    systemd/kök yetkisi GEREKMEZ — hepsi sahte (fonksiyon override).
# ═══════════════════════════════════════════════════════════════
echo "== 3) TAM ZİNCİR: _deploy_run (git clone'dan [9/9]'a KADAR HER adım) =="

# runuser gerektirmeden test etmek için privdrop'u stub'la (composer.json/
# hook/migration bu testte HİÇ YOK, ama build adımı yine de privdrop
# ÇAĞIRMAYA çalışabilir — bkz. framework beyan edilmemiş -> soft-skip).
_deploy_privdrop() { local _u="$1"; shift; "$@"; }

# Fake PHP CLI ikili dosyası — _deploy_run 'php${php_version}'ı PATH'te ARAR
# (bkz. dosya-geneli yorum: host'un varsayılan php'sine SESSİZCE düşülmez).
export DEFAULT_PHP_VERSION="8.3"
FAKE_BIN_DIR="$(mktemp -d)"
cat > "${FAKE_BIN_DIR}/php8.3" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${FAKE_BIN_DIR}/php8.3"
export PATH="${FAKE_BIN_DIR}:${PATH}"

# 'git clone --depth 1 --branch <branch> -- <url> <target>' — sahte: hedefi
# oluşturur, gerçek ağ/deponun yerini alır.
git() {
    if [[ "$1" == "clone" ]]; then
        local target="${*: -1}"
        mkdir -p "$target"
        return 0
    fi
    return 0
}

# 'chown -Rh web_x:web_x ...' — sahte web_user sistemde YOK, gerçek chown
# başarısız olurdu (root gerektirir); no-op'a indirgenir (fonksiyonel etkisi
# YOK — release zaten test kullanıcısına ait).
chown() { return 0; }

# systemctl — reload/restart/list-units HEPSİ başarıyla döner, list-units
# BOŞ çıktı verir (hiç unit yok varsayımı; _deploy_reload_fpm bu durumda
# paylaşılan 'php8.3-fpm'e düşer ve reload 'başarılı' sayılır).
systemctl() { [[ "$1" == "list-units" ]] && return 0; return 0; }

_deploy_http_code() { echo "401"; }

dom_run="run.designwestgate.test"
mkdir -p "${WEB_ROOT}/${dom_run}"
printf 'https://example.invalid/devgate-repo.git\n' > "${WEB_ROOT}/${dom_run}/.deploy-repo"
chmod 600 "${WEB_ROOT}/${dom_run}/.deploy-repo"
printf 'HEALTH_OK_CODES=200 301 302 401\n' > "${WEB_ROOT}/${dom_run}/.srvctl-meta"

out_run=$(DEPLOY_HEALTH_RETRIES=1 DEPLOY_HEALTH_INTERVAL=0 DEPLOY_RUN_MIGRATIONS=false \
    _deploy_run "$dom_run" "main" 2>&1)
rc_run=$?

assert_eq "$rc_run" "0" \
    "TAM ZİNCİR: 'deploy' komutu 401 döndüren DevGate benzeri bir siteyi BAŞARIYLA tamamladı (koordinatörün HOST'ta doğruladığı işlevsel sonuç)"
assert_contains "$out_run" "Sağlık kontrolü OK (HTTP 401)" "[9/9] adımı HTTP 401'i OK olarak raporladı"
assert_contains "$out_run" "Deploy Tamamlandı" "deploy TAMAMLANDI (otomatik rollback TETİKLENMEDİ)"
assert_contains "$out_run" "HEALTH_OK_CODES" \
    "TAM ZİNCİRİN GERÇEK ÇIKTISINDA override görünürlüğü VAR — koordinatörün HOST'ta 'grep ... HİÇBİR EŞLEŞME' bulduğu TAM senaryo artık kapatıldı"
assert_contains "$out_run" "KABUL EDİLEN kod olarak yapılandırılmış" \
    "TAM ZİNCİR çıktısı 401'in bu domain için ÖZEL kabul edildiğini AÇIKÇA söylüyor"

unset -f git chown systemctl
rm -rf "$FAKE_BIN_DIR"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
