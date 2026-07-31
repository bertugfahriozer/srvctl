#!/bin/bash
# 'domain list' hayalet dizin bug'ı — HOST'ta ölçüldü (srvctl-jammy/noble).
#
# KÖK NEDEN (lib/domain.sh:_domain_list): fonksiyon '${WEB_ROOT}/*/' üzerinde
# HAM bir glob ile numaralandırıyordu — 'security audit' (lib/security.sh)
# ve 'domain repair --all' (lib/domain.sh:_domain_repair) zaten kullandığı
# 'list_all_domains()' (lib/core.sh) sözleşmesini (validate_domain +
# '.credentials' varlığı) ATLIYORDU. HOST'ta ölçülen somut sonuç: nginx
# paketinin kendi kurduğu '/var/www/html' dizini TAMAMEN HAYALİ bir domain
# gibi listeleniyordu — 'web_html' diye bir sistem kullanıcısı YOKKEN
# çıktıda "KULLANICI: web_html" satırı basılıyor, 'Toplam: N domain' sayacı
# bunu içeriyordu. Aynı sunucuda AYNI ANDA 'security audit' bu dizini HİÇ
# görmüyordu — iki komut aynı soruya farklı cevap veriyordu.
#
# Bu test dört şeyi kilitler:
#   1) '.credentials'ı OLMAYAN bir dizin (ör. 'html') tabloda HİÇ satır
#      olarak GÖRÜNMÜYOR.
#   2) O dizin için UYDURULMUŞ bir 'web_<ad>' kullanıcı adı ASLA basılmıyor.
#   3) 'Toplam: N domain' sayacı yalnız GERÇEK ('.credentials'lı) domainleri
#      sayıyor — hayalet dizin sayaca DAHİL EDİLMİYOR.
#   4) Yönetilmeyen dizin SESSİZCE de yutulmuyor — ayrı bir DİPNOT satırında
#      "srvctl tarafından yönetilmiyor" ibaresiyle AÇIKÇA raporlanıyor (KARAR:
#      görev talebi #2 — ne sessiz gizleme ne ana tabloya karıştırma).
#
# Test-seam: WEB_ROOT (diğer domain.sh testleriyle AYNI desen).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

export WEB_ROOT="$(mktemp -d)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/domain.sh"

# ─── Fixture: iki GERÇEK domain + bir HAYALET dizin (nginx'in '/var/www/html'
# taklidi — '.credentials' YOK, web kullanıcısı YOK). ───
_setup_real_domain() {
    local domain="$1" sname
    sname=$(safe_name "$domain")
    mkdir -p "${WEB_ROOT}/${domain}"
    _domain_write_credentials "$domain" "${WEB_ROOT}/${domain}" "web_${sname}" "8.3" \
        "db_${sname}" "usr_${sname}" "cleanpassdb1234" \
        "redis_${sname}" "cleanpassredis1234" "${sname}:"
}

dOne="ci4.local"
dTwo="symfony.local"
_setup_real_domain "$dOne"
_setup_real_domain "$dTwo"

# Hayalet: nginx'in varsayılan dizini — dizin VAR ama '.credentials' YOK.
mkdir -p "${WEB_ROOT}/html"

echo "== domain list: hayalet dizin dışlanıyor =="

out=$(_domain_list 2>&1)

assert_contains "$out" "$dOne" "gerçek domain (${dOne}) tabloda GÖRÜNÜYOR"
assert_contains "$out" "$dTwo" "gerçek domain (${dTwo}) tabloda GÖRÜNÜYOR"

# EN KRİTİK assertion (görev talebi): '.credentials'ı OLMAYAN 'html' dizini
# ne satır olarak ne de UYDURULMUŞ kullanıcı adıyla listede YER ALMIYOR.
assert_not_contains "$out" "web_html" \
    "[KRİTİK] var olmayan 'web_html' kullanıcı adı ASLA uydurulmuyor/basılmıyor"

# 'html' kelimesi ne domain sütununda ne başka bir yerde bağımsız bir SATIR
# olarak geçmemeli (dipnot satırındaki 'html' referansı ayrı — bkz. aşağı).
assert_not_contains "$out" $'\n  html  ' \
    "[KRİTİK] 'html' dizini tabloya bağımsız bir SATIR olarak eklenmedi"

# Sayaç: yalnız 2 GERÇEK domain sayılmalı, hayalet dizin sayaca DAHİL DEĞİL.
assert_contains "$out" "Toplam: 2 domain" \
    "[KRİTİK] sayaç yalnız GERÇEK domainleri sayıyor (2), hayalet dizin DAHİL EDİLMEDİ"
assert_not_contains "$out" "Toplam: 3 domain" \
    "sayaç 3'e ŞİŞMEDİ (hayalet dizin sayılmadı)"

# Dipnot: sessizce gizlenmiyor — operatöre "1 dizin listelenmedi" AÇIKÇA söyleniyor.
assert_contains "$out" "1 dizin listelenmedi" \
    "yönetilmeyen dizin sayısı bir DİPNOT olarak AÇIKÇA raporlanıyor (sessiz gizleme YOK)"
assert_contains "$out" "srvctl tarafından yönetilmiyor" \
    "dipnot dizinin srvctl tarafından yönetilmediğini AÇIKÇA belirtiyor"

# Tutarlılık: 'domain list'in gördüğü küme 'list_all_domains()' ile BİREBİR
# aynı olmalı (görev talebi — üç tüketici tek sözleşmeyi paylaşmalı).
lad_count=$(list_all_domains | wc -l | tr -d '[:space:]')
assert_eq "$lad_count" "2" "list_all_domains() de AYNI 2 domain'i görüyor (tek sözleşme, tutarlı küme)"

rm -rf "$WEB_ROOT"
test_summary
