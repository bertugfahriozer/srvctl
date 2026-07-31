#!/bin/bash
# KUSUR 1 regresyon testi (üretim izlemesi: 'srvctl security harden-fpm
# designwestgate.art --apply' çıktı üretmeden EXIT=1 döndü).
#
# BULGU: core.sh:error() zaten stderr'e yazıyor (bkz. tests/test_warn_stderr.sh
# — bu depoda İLK COMMIT'ten beri böyle, git blame ile doğrulandı) — yani
# "error() stdout'a yazıyor" iddiası bu depo için YANLIŞ (muhtemelen
# üretimdeki KURULU (/usr/local/srvctl) kopya bu depodan/branch'ten daha
# ESKİydi — 'Repo ≠ kurulum', bkz. CLAUDE.md). Gerçek, doğrulanmış risk
# FARKLI: 'php_ver=$(_derive_php ...)' gibi ÇIPLAK bir komut ikamesi ataması
# ('local' İLE AYNI SATIRDA DEĞİL, ayrı satır — bkz. lib/security.sh
# _harden_fpm_apply) içinde error() (=exit) tetiklenirse, bu exit SADECE o
# komut ikamesinin alt-kabuğunu bitirir; 'set -e' ataması BAŞARISIZ sayıp
# TÜM script'i (ve '--all' modunda KALAN TÜM domainleri) SESSİZCE durdurur —
# tek görünür iz o TEK stderr satırıdır. lib/domain.sh:_domain_repair'in
# '--all' bloğu bunu ZATEN alt-kabuk izolasyonuyla çözmüştü; bu test AYNI
# düzeltmenin lib/security.sh:_security_harden_fpm/_security_harden_fs
# '--all' yollarına da uygulandığını kilitler.
#
# Bu test iki şeyi kilitler:
#   1) error() bir komut ikamesinin İÇİNDEN (php_ver=$(...) deseni) çağrılsa
#      bile mesaj STDOUT'a SIZMAZ, STDERR'e ulaşır (KULLANICIYA görünür) —
#      ve çağıran fonksiyon 'set -e' ile beklendiği gibi hemen durur.
#   2) 'security harden-fpm --all' TEK bir domain'in error()/exit'i
#      yüzünden KALAN domainleri işlemeden sessizce ölmez (subshell
#      izolasyonu) — başarısız olanlar özetlenir, dönüş kodu dürüsttür.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
id() { return 0; }   # ghost-check nötrlensin (bu testin konusu DEĞİL)
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/security.sh"

echo "== 1) error(), 'php_ver=\$(...)' desenindeki bir zincirin İÇİNDEN çağrılsa bile stderr'e ulaşır =="

# lib/security.sh:_harden_fpm_apply'daki GERÇEK deseni birebir taklit et:
# 'local domain sname php_ver' (ayrı satır) + SONRA çıplak 'php_ver=$(...)'.
_mimic_harden_fpm_apply_shape() {
    local domain="$1" php_ver
    php_ver=$(_derive_php "$domain" "8.3")
    echo "ULASILMAMALI:php_ver=${php_ver}"
}

d="tampered-chain.example"
mkdir -p "${WEB_ROOT}/${d}"
mkdir -p "${SRVCTL_STATE_DIR}/${d}"; : > "${SRVCTL_STATE_DIR}/${d}/hardened"
# '.credentials' HİÇ YOK + hardened → read_credentials (core.sh) error() ile
# çıkar (KUSUR 2 mesajı: "eksik"). _domain_ensure_credentials (KUSUR 3
# kurtarması) BİLEREK devre dışı bırakıldı — bu test SADECE KUSUR 1'i
# (error()'ın $( ) içinde kaybolup kaybolmadığını) izole ölçer.
_domain_ensure_credentials() { :; }

out="$( ( set -euo pipefail; _mimic_harden_fpm_apply_shape "$d" ) 2>/dev/null )"
err="$( ( set -euo pipefail; _mimic_harden_fpm_apply_shape "$d" ) 2>&1 1>/dev/null )"
# NOT: rc '( ... ) ... || rc=$?' İLE YAKALANMIYOR — macOS'un eski bash 3.2'sinde
# 'set -e'li bir alt-kabuk '||' listesinin SOL tarafındayken exit status'u
# YANLIŞ raporluyor (doğrulanmış dev-makine tuhaflığı, Ubuntu'nun modern
# bash'inde YOK). Dış script zaten '-e' TAŞIMIYOR (yalnız 'set -uo pipefail'),
# bu yüzden '$?' doğrudan, '||' OLMADAN güvenle okunabilir.
( set -euo pipefail; _mimic_harden_fpm_apply_shape "$d" ) >/dev/null 2>&1
rc=$?

assert_eq "$out" "" "error() mesajı STDOUT'A SIZMADI (komut ikamesi içindeyken bile)"
assert_not_contains "$out" "ULASILMAMALI" "'php_ver=\$(...)' başarısız olunca fonksiyon devam ETMEDİ (set -e beklendiği gibi durdu)"
assert_contains "$err" "eksik" "error() mesajı STDERR'de görünür (kullanıcıya ULAŞIYOR)"
assert_eq "$rc" "1" "zincir set -e ile EXIT=1 verdi (üretimde ölçülen davranışla tutarlı)"

echo ""
echo "== 2) 'security harden-fpm --all': TEK domain'in error()'ı KALAN domainleri YUTMAZ =="

# KUSUR 3 kurtarmasını geri aç (bu bölüm onun etkileşimini test ETMİYOR).
unset -f _domain_ensure_credentials

mkdir -p "${WEB_ROOT}/a.test" "${WEB_ROOT}/b.test" "${WEB_ROOT}/c.test"

# '_harden_fpm_dry'ı, YALNIZ 'b.test' için error() fırlatacak biçimde
# override et — bu, '_security_harden_fpm'in kendi döngü/subshell-izolasyon
# sözleşimini, derin FPM/systemd mekaniğinden BAĞIMSIZ olarak test eder.
_harden_fpm_dry() {
    local domain="$1"
    echo "PROCESSED:${domain}"
    if [[ "$domain" == "b.test" ]]; then
        error "simüle edilmiş hata: ${domain}"
    fi
    return 0
}

out_all="$( _security_harden_fpm --all 2>/dev/null )"
err_all="$( _security_harden_fpm --all 2>&1 1>/dev/null )"
rc_all=0; _security_harden_fpm --all >/dev/null 2>&1 || rc_all=$?

assert_contains "$out_all" "PROCESSED:a.test" "a.test İŞLENDİ (b.test'in hatasından ÖNCE)"
assert_contains "$out_all" "PROCESSED:c.test" "c.test de İŞLENDİ (b.test'in hatası KALANLARI YUTMADI — asıl regresyon)"
assert_contains "$err_all" "TAMAMLANAMADI" "başarısız domain(ler) özetlendi (sessiz değil)"
assert_contains "$err_all" "b.test" "özet HANGİ domain'in başarısız olduğunu söylüyor"
assert_eq "$rc_all" "1" "en az bir domain başarısızken '--all' dönüş kodu DÜRÜST (sıfırdan farklı)"

echo ""
echo "== 3) 'security harden-fs --all': AYNI izolasyon (BİREBİR AYNI kod deseni) =="

_harden_fs_dry() {
    local domain="$1"
    echo "PROCESSED:${domain}"
    if [[ "$domain" == "b.test" ]]; then
        error "simüle edilmiş hata: ${domain}"
    fi
    return 0
}

out_fs="$( _security_harden_fs --all 2>/dev/null )"
err_fs="$( _security_harden_fs --all 2>&1 1>/dev/null )"
rc_fs=0; _security_harden_fs --all >/dev/null 2>&1 || rc_fs=$?

assert_contains "$out_fs" "PROCESSED:a.test" "harden-fs: a.test İŞLENDİ"
assert_contains "$out_fs" "PROCESSED:c.test" "harden-fs: c.test de İŞLENDİ (b.test'in hatası KALANLARI YUTMADI)"
assert_contains "$err_fs" "TAMAMLANAMADI" "harden-fs: başarısız domain(ler) özetlendi"
assert_eq "$rc_fs" "1" "harden-fs: '--all' dönüş kodu DÜRÜST"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
