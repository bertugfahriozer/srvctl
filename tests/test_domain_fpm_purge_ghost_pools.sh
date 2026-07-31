#!/bin/bash
# 'domain add'i tamamen bloke eden ikinci dereceden hasar — HOST'ta ölçüldü
# (srvctl-jammy).
#
# ZİNCİR: önceki (hayalet-tespitinden ÖNCEKİ) bir 'repair --all' çalıştırması
# hayalet '/var/www/html' için 'user = web_html' (VAR OLMAYAN bir sistem
# kullanıcısı) içeren bir 'pool.d/html.conf' yazmıştı. php-fpm böyle bir
# havuzu KABUL ETMEZ — TEK bu dosya yüzünden paylaşılan php<ver>-fpm.service
# hiç başlayamıyordu (Restart=on-failure döngüsü → "start request repeated
# too quickly" rate-limit). Sonuç: o php sürümünü paylaşan HİÇBİR YENİ
# domain eklenemiyordu — 'domain add' 4/10. adımda (PHP-FPM pool) ölüyordu.
#
# Hayalet-tespiti (bkz. test_domain_repair_reporting.sh Bölüm E) kaynağı
# KAPATTI (yeni kalıntı ÜRETİLMEZ) ama zaten var olan kalıntıyı
# TEMİZLEMİYORDU. '_domain_fpm_purge_ghost_pools' (lib/domain.sh) bu ikinci
# dereceden hasarı, '.credentials' kararından BİLİNÇLİ olarak farklı bir
# kararla giderir: pool.d/*.conf SAF altyapı konfigürasyonudur (sır İÇERMEZ)
# ve 'user = <var olmayan kullanıcı>' HİÇBİR meşru senaryoda geçerli
# olamaz — bu yüzden burada OTOMATİK SİLİNİR (yalnız SESSİZCE değil: her
# silinen dosyanın TAM YOLU raporlanır).
#
# Bu test dört şeyi kilitler:
#   1) Var olmayan kullanıcıya işaret eden havuz dosyası KALDIRILIR, TAM
#      yol içeren bir uyarı basılır.
#   2) Gerçek kullanıcıya işaret eden sağlıklı bir havuz DOKUNULMAZ.
#   3) 'www.conf' (srvctl-yönetimli değil, init.sh'ın kendi alanı) tarayıcının
#      kapsamı DIŞI — kullanıcısı geçersiz olsa BİLE dokunulmaz.
#   4) Kenar durumlar çökertmez: pool dizini yok / boş / 'user =' satırı
#      olmayan bozuk bir dosya.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }

# 'id' mock: yalnız 'web_good' VARDIR; 'web_html'/'web_ghost' gibi diğer her
# şey YOKTUR (HOST'taki gerçek hayalet kullanıcı adını birebir taklit eder).
id() { [[ "$1" == "web_good" ]] && return 0 || return 1; }

source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_fpm_purge_ghost_pools >/dev/null 2>&1; then
    echo "  SKIP: _domain_fpm_purge_ghost_pools tanımlı değil"
    test_summary
    exit $?
fi

echo "== hayalet FPM pool.d dosyalarının temizliği =="

# ═══════════ Vaka 1: karma dizin — hayalet + sağlıklı + www.conf ═══════════
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"

cat > "${SRVCTL_PHP_POOL_DIR}/html.conf" << 'EOF'
[html]
user = web_html
group = web_html
listen = /run/php/php8.3-fpm-html.sock
EOF

cat > "${SRVCTL_PHP_POOL_DIR}/good.conf" << 'EOF'
[good]
user = web_good
group = web_good
listen = /run/php/php8.3-fpm-good.sock
EOF

# 'www.conf' — bilerek GEÇERSİZ bir kullanıcıyla: tarayıcının kapsamı DIŞI
# olduğu için YİNE DE dokunulmamalı (init.sh'ın kendi alanı).
cat > "${SRVCTL_PHP_POOL_DIR}/www.conf" << 'EOF'
[www]
user = web_gecersiz_kullanici
group = web_gecersiz_kullanici
listen = /run/php/php8.3-fpm.sock
EOF

out1=$(_domain_fpm_purge_ghost_pools "8.3" 2>&1)

assert_eq "$(test -f "${SRVCTL_PHP_POOL_DIR}/html.conf" && echo VAR || echo YOK)" "YOK" \
    "1) Var olmayan kullanıcıya ('web_html') işaret eden havuz KALDIRILDI"
assert_contains "$out1" "${SRVCTL_PHP_POOL_DIR}/html.conf" \
    "1) Kaldırılan dosyanın TAM YOLU raporlandı"
assert_contains "$out1" "web_html" \
    "1) Hangi kullanıcının bulunamadığı raporlandı"
assert_eq "$(test -f "${SRVCTL_PHP_POOL_DIR}/good.conf" && echo VAR || echo YOK)" "VAR" \
    "2) Sağlıklı havuz ('web_good' — gerçekten var) DOKUNULMADI"
assert_eq "$(cat "${SRVCTL_PHP_POOL_DIR}/good.conf")" "$(printf '[good]\nuser = web_good\ngroup = web_good\nlisten = /run/php/php8.3-fpm-good.sock')" \
    "2) Sağlıklı havuzun İÇERİĞİ birebir aynı kaldı"
assert_eq "$(test -f "${SRVCTL_PHP_POOL_DIR}/www.conf" && echo VAR || echo YOK)" "VAR" \
    "3) 'www.conf' geçersiz kullanıcıya işaret etse BİLE DOKUNULMADI (kapsam dışı)"

rm -rf "$SRVCTL_PHP_POOL_DIR"

# ═══════════ Vaka 2: kenar durumlar — dizin yok / boş / bozuk dosya ═══════════
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)/hic-yok"
assert_ok _domain_fpm_purge_ghost_pools "8.1" \
    "4a) Pool dizini hiç YOKSA hata VERMEZ (koşulsuz 0 döner)"

export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
assert_ok _domain_fpm_purge_ghost_pools "8.2" \
    "4b) Pool dizini BOŞSA hata VERMEZ"

cat > "${SRVCTL_PHP_POOL_DIR}/bozuk.conf" << 'EOF'
[bozuk]
; 'user =' satırı YOK — bozuk/eksik bir pool dosyası
listen = /run/php/php8.2-fpm-bozuk.sock
EOF
_domain_fpm_purge_ghost_pools "8.2" >/dev/null 2>&1
assert_eq "$(test -f "${SRVCTL_PHP_POOL_DIR}/bozuk.conf" && echo VAR || echo YOK)" "VAR" \
    "4c) 'user =' satırı OLMAYAN bozuk bir dosya çökertmez, DOKUNULMAZ (bilinmeyen durum -> atla)"

rm -rf "$SRVCTL_PHP_POOL_DIR"
rm -rf "$WEB_ROOT"
test_summary
