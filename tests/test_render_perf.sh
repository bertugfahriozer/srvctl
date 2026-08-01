#!/bin/bash
# render_template PERFORMANS REGRESYON KİLİDİ.
#
# HOST BULGUSU (bu oturumda, macOS bash 3.2 test ortamında ÖLÇÜLDÜ): eski
# uygulama ('${content//pattern/replacement}' — bash'in KENDİ glob motoru,
# TÜM içerik string'i üzerinde token başına TAM TARAMA yapar) 16KB'lık TEK
# bir gerçek şablonda (templates/systemd/srvctl-cron.service.tpl, 11 token)
# TEK render_template ÇAĞRISI başına ~1.7 SANİYEYE kadar çıkıyordu; 100
# domain'i benzeten bir döngü (aynı şablonu 100 kez render etmek) 2 DAKİKADA
# BİLE BİTMEDİ (timeout). Kullanıcının hedefi 100 domain olduğundan ('domain
# repair --all' / 'security audit' gibi TOPLU komutlar HER domain için
# BİRDEN FAZLA şablon render eder) bu davranış ÜRETİMDE tolere edilemezdi.
#
# DÜZELTME (core.sh:render_template): yerine koyma artık TEK bir awk
# alt-süreciyle (ENVIRON üzerinden aktarılan değerler, index()/substr() ile
# SAF bayt-bayt arama/birleştirme — regex/gsub YOK) yapılıyor; maliyet
# render_template ÇAĞRISI başına TEK fork'a düşüyor, token sayısından
# NEREDEYSE bağımsız. Bu test o iyileşmeyi KİLİTLER — GNU/BSD 'date' saat
# damgası farklarına bağımlı olmamak için bash'in KENDİ '$SECONDS'
# değişkeni (portable, harici komut GEREKTİRMEZ) kullanılır; eşikler
# GERÇEK ölçümün (tek render ~0.01s, 100 render ~0.5s) ÇOK ÜZERİNDE,
# yalnızca eski patolojik (>>saniyeler/timeout) davranışa DÖNÜŞÜ yakalayacak
# kadar CÖMERT tutulmuştur (yavaş CI/host'larda YANLIŞ ALARM ÜRETMEMEK
# için).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

assert_lt() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if (( $1 < $2 )); then
        echo "  $(_green PASS) ${3:-} (${1}s < ${2}s)"
    else
        echo "  $(_red FAIL) ${3:-} (${1}s >= ${2}s eşiği — REGRESYON)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

TPL="${REPO_ROOT}/templates/systemd/srvctl-cron.service.tpl"

# ── Tek render: gerçekçi 11-token'lı 16KB'lık şablon ──
start=$SECONDS
out=$(render_template "$TPL" \
    "SAFE_NAME=example_com" "DOMAIN=example.com" "WEB_USER=web_example_com" \
    "WORKING_DIR=/var/www/example.com/current" "CRON_NAME=test" \
    "CRON_DESCRIPTION=aciklama" "CRON_COMMAND=echo bir && echo iki" \
    "RUNTIME_MAX=60" "DOMAIN_ROOT=/var/www/example.com" \
    "LOCK_DIR=/run/srvctl/locks/example_com" "FLOCK_PREFIX=")
elapsed=$((SECONDS - start))
assert_lt "$elapsed" 5 "TEK render_template çağrısı (16KB şablon, 11 token) makul sürede bitiyor"
assert_not_contains "$out" "{{" "tek render'da leftover token yok"

# ── 100 domain benzetimi: AYNI şablon 100 kez render edilir ──
# (koordinatörün 'domain repair --all'/'security audit' TOPLU akışlarının
# kabaca benzetimi — GERÇEK akış nginx/php-fpm/apparmor/logrotate/systemd
# şablonlarının HEPSİNİ render eder, burada TEK şablonla TEKRAR SAYISI
# temsil edilir).
start=$SECONDS
for i in $(seq 1 100); do
    render_template "$TPL" \
        "SAFE_NAME=example_com${i}" "DOMAIN=example${i}.com" "WEB_USER=web_example_com${i}" \
        "WORKING_DIR=/var/www/example${i}.com/current" "CRON_NAME=test${i}" \
        "CRON_DESCRIPTION=aciklama${i}" "CRON_COMMAND=echo bir && echo iki ${i}" \
        "RUNTIME_MAX=60" "DOMAIN_ROOT=/var/www/example${i}.com" \
        "LOCK_DIR=/run/srvctl/locks/example_com${i}" "FLOCK_PREFIX=" > /dev/null
done
elapsed=$((SECONDS - start))
assert_lt "$elapsed" 30 "100 domain benzetimi (100x render_template, 16KB şablon) makul sürede bitiyor"

test_summary
