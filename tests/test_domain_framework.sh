#!/bin/bash
# Framework beyanı (.srvctl-meta FRAMEWORK): okuma güveni, fs iskeleti,
# .env şablonu ve vhost DENY_DIRS seçimi framework'e göre nasıl DEĞİŞİYOR.
#
# _domain_read_framework: KULLANICI KARARI ile açıkça beyan edilir (otomatik
# tespit YOK). .srvctl-meta web-yazılabilir bir dosya olduğundan ham değere
# GÜVENİLMEZ — whitelist (ci4|laravel|symfony) dışı bir değer (bozuk/saldırgan)
# sessizce 'ci4'e düşürülür (PREDİKAT değil, normalize edilmiş ad döner).
#
# _domain_fs_plan 3. argümanı (framework) OPSİYONELDİR — lib/security.sh gibi
# eski çağıranlar hâlâ 2 argümanla çağırıyor ve bu geriye-uyumluluk BOZULMAMALI.
#
# _domain_write_env_skeleton: 3 framework için doğru anahtarları üretir,
# MEVCUT .env dosyasının üzerine asla YAZMAZ (operatörün elle girdiği
# değerler kaybolmasın) ve izin her zaman 640'tır (secrets içerir).
#
# DENY_DIRS: laravel/symfony (docroot=public/) 'storage' ve 'vendor'ı vhost
# deny bloğundan ÇIKARIR (storage:link, public/vendor/livewire meşru
# yollardır); ci4/varsayılan (docroot=repo kökü) bu dizinleri deny'da TUTAR.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
source "${REPO_ROOT}/lib/domain.sh"

_run_isolated() { ( "$@" ); }
ex() { [[ -e "$1" ]] && echo var || echo yok; }

# ═══════════════════════════════ _domain_read_framework ═══════════════════════════════
if declare -F _domain_read_framework >/dev/null 2>&1; then
    mkdir -p "${WEB_ROOT}/rf-ci4.com" "${WEB_ROOT}/rf-laravel.com" "${WEB_ROOT}/rf-symfony.com" \
             "${WEB_ROOT}/rf-none.com" "${WEB_ROOT}/rf-garbage.com"

    write_meta rf-ci4.com     FRAMEWORK ci4
    write_meta rf-laravel.com FRAMEWORK laravel
    write_meta rf-symfony.com FRAMEWORK symfony

    assert_eq "$(_domain_read_framework rf-ci4.com 2>/dev/null)"     "ci4"     "geçerli değer: ci4 aynen döner"
    assert_eq "$(_domain_read_framework rf-laravel.com 2>/dev/null)" "laravel" "geçerli değer: laravel aynen döner"
    assert_eq "$(_domain_read_framework rf-symfony.com 2>/dev/null)" "symfony" "geçerli değer: symfony aynen döner"
    assert_eq "$(_domain_read_framework rf-none.com 2>/dev/null)"    "ci4"     "meta hiç yoksa varsayılan ci4"

    # Çöp/whitelist dışı değer (bozuk ya da saldırgan) -> GÜVENİLMEZ, ci4'e düşer.
    write_meta rf-garbage.com FRAMEWORK 'wordpress'
    assert_eq "$(_domain_read_framework rf-garbage.com 2>/dev/null)" "ci4" "whitelist dışı değer 'ci4'e düşürüldü"

    write_meta rf-garbage.com FRAMEWORK '$(rm -rf /)'
    assert_eq "$(_domain_read_framework rf-garbage.com 2>/dev/null)" "ci4" "komut-enjeksiyonu içeren değer de 'ci4'e düşürüldü (asla eval edilmez)"

    # Hardened + root-owned OLMAYAN meta -> tamper -> error() (exit). Sandbox'ta
    # dosya zaten test kullanıcısına ait (root değil); domain'i 'hardened' işaretleyip
    # bu durumu tetikliyoruz. error() exit ettiğinden subshell'de yakalanır.
    mkdir -p "${WEB_ROOT}/rf-hardened.com"
    write_meta rf-hardened.com FRAMEWORK laravel
    mkdir -p "${SRVCTL_STATE_DIR}/rf-hardened.com"
    touch "${SRVCTL_STATE_DIR}/rf-hardened.com/hardened"
    assert_fail _run_isolated _domain_read_framework rf-hardened.com
else
    echo "  SKIP: _domain_read_framework henüz yok"
fi

# ═══════════════════════════════════ _domain_fs_plan ═══════════════════════════════════
if declare -F _domain_fs_plan >/dev/null 2>&1; then
    base="/var/www/plan.example.com"; wu="web_plan_example_com"

    # ci4 (varsayılan / açık 3. argüman)
    out_ci4=$(_domain_fs_plan "$base" "$wu" ci4)
    assert_contains     "$out_ci4" "${base}/shared/writable|${wu}|770"        "ci4: shared/writable var"
    assert_contains     "$out_ci4" "${base}/shared/writable/uploads|${wu}|770" "ci4: shared/writable/uploads var"
    assert_not_contains "$out_ci4" "shared/storage"                          "ci4: shared/storage YOK"
    assert_not_contains "$out_ci4" "shared/var|"                             "ci4: shared/var YOK"

    # laravel
    out_laravel=$(_domain_fs_plan "$base" "$wu" laravel)
    assert_contains     "$out_laravel" "${base}/shared/storage/app/public|${wu}|770" "laravel: shared/storage/app/public var"
    assert_contains     "$out_laravel" "${base}/shared/bootstrap-cache|${wu}|770"    "laravel: shared/bootstrap-cache var"
    assert_not_contains "$out_laravel" "shared/writable"                            "laravel: shared/writable YOK"
    assert_not_contains "$out_laravel" "shared/var|"                                "laravel: shared/var YOK"

    # symfony
    out_symfony=$(_domain_fs_plan "$base" "$wu" symfony)
    assert_contains     "$out_symfony" "${base}/shared/var/cache|${wu}|770" "symfony: shared/var/cache var"
    assert_contains     "$out_symfony" "${base}/shared/var/log|${wu}|770"   "symfony: shared/var/log var"
    assert_not_contains "$out_symfony" "shared/writable"                    "symfony: shared/writable YOK"
    assert_not_contains "$out_symfony" "shared/storage"                     "symfony: shared/storage YOK"

    # GERİYE UYUMLULUK: 2 argümanlı eski çağrı (lib/security.sh böyle çağırıyor) hâlâ çalışmalı
    # ve framework verilmemiş varsayılan davranışla (ci4) AYNI olmalı.
    out_legacy=$(_domain_fs_plan "$base" "$wu")
    assert_eq "$out_legacy" "$out_ci4" "2-argümanlı eski çağrı ci4 varsayılanıyla birebir aynı"
else
    echo "  SKIP: _domain_fs_plan henüz yok"
fi

# ═══════════════════════════════ _domain_write_env_skeleton ═══════════════════════════════
if declare -F _domain_write_env_skeleton >/dev/null 2>&1; then
    envbase="$(mktemp -d)"
    mkdir -p "${envbase}/shared"

    _domain_write_env_skeleton laravel.test "$envbase" "$(whoami)" laravel \
        db_laravel usr_laravel pass_laravel redis_laravel redispass_laravel "laravel_test:" >/dev/null 2>&1
    env_laravel=$(cat "${envbase}/shared/.env")
    assert_contains "$env_laravel" "APP_KEY=base64:"        "laravel .env: APP_KEY üretildi"
    assert_contains "$env_laravel" "DB_DATABASE=db_laravel"  "laravel .env: DB_DATABASE"
    assert_contains "$env_laravel" "REDIS_PREFIX=laravel_test:" "laravel .env: REDIS_PREFIX"
    assert_contains "$env_laravel" "CACHE_STORE=redis"       "laravel .env: CACHE_STORE"
    assert_eq "$(_stat_mode "${envbase}/shared/.env")" "640" "laravel .env izni 640"
    rm -f "${envbase}/shared/.env"

    _domain_write_env_skeleton symfony.test "$envbase" "$(whoami)" symfony \
        db_sf usr_sf pass_sf redis_sf redispass_sf "symfony_test:" >/dev/null 2>&1
    env_symfony=$(cat "${envbase}/shared/.env")
    assert_contains "$env_symfony" "APP_SECRET="                                    "symfony .env: APP_SECRET üretildi"
    assert_contains "$env_symfony" "DATABASE_URL=\"mysql://usr_sf:pass_sf@127.0.0.1:3306/db_sf" "symfony .env: DATABASE_URL"
    assert_contains "$env_symfony" "REDIS_URL=\"redis://redis_sf:redispass_sf@"      "symfony .env: REDIS_URL"
    assert_eq "$(_stat_mode "${envbase}/shared/.env")" "640" "symfony .env izni 640"
    rm -f "${envbase}/shared/.env"

    _domain_write_env_skeleton ci4.test "$envbase" "$(whoami)" ci4 \
        db_ci4 usr_ci4 pass_ci4 redis_ci4 redispass_ci4 "ci4_test:" >/dev/null 2>&1
    env_ci4=$(cat "${envbase}/shared/.env")
    assert_contains "$env_ci4" "database.default.database = db_ci4" "ci4 .env: database.default.database"
    assert_contains "$env_ci4" "cache.prefix = ci4_test:"           "ci4 .env: cache.prefix"
    assert_eq "$(_stat_mode "${envbase}/shared/.env")" "640"        "ci4 .env izni 640"

    # GÜVENLİK: .env zaten VARSA üzerine YAZILMAZ (operatörün elle girdiği değer korunur).
    echo "OPERATOR_ELLE_GIRDI=deger" > "${envbase}/shared/.env"
    chmod 640 "${envbase}/shared/.env"
    _domain_write_env_skeleton ci4.test "$envbase" "$(whoami)" laravel \
        db_ci4 usr_ci4 pass_ci4 redis_ci4 redispass_ci4 "ci4_test:" >/dev/null 2>&1
    assert_eq "$(cat "${envbase}/shared/.env")" "OPERATOR_ELLE_GIRDI=deger" \
        "mevcut .env korunuyor (üzerine YAZILMADI)"

    rm -rf "$envbase"
else
    echo "  SKIP: _domain_write_env_skeleton henüz yok"
fi

# ═══════════════════════════════════ DENY_DIRS seçimi ═══════════════════════════════════
if declare -F _domain_write_vhost >/dev/null 2>&1; then
    mkdir -p "${WEB_ROOT}/deny-laravel.com" "${WEB_ROOT}/deny-symfony.com" "${WEB_ROOT}/deny-ci4.com"
    write_meta deny-laravel.com FRAMEWORK laravel
    write_meta deny-symfony.com FRAMEWORK symfony
    write_meta deny-ci4.com     FRAMEWORK ci4

    _domain_write_vhost deny-laravel.com 8.3 standard http 2>/dev/null
    deny_laravel=$(grep -F 'location ~ ^/(' "${SITES_AVAILABLE}/deny-laravel.com.conf")
    assert_not_contains "$deny_laravel" "storage" "laravel vhost: storage deny'da YOK"
    assert_not_contains "$deny_laravel" "vendor"  "laravel vhost: vendor deny'da YOK"

    _domain_write_vhost deny-symfony.com 8.3 standard http 2>/dev/null
    deny_symfony=$(grep -F 'location ~ ^/(' "${SITES_AVAILABLE}/deny-symfony.com.conf")
    assert_not_contains "$deny_symfony" "storage" "symfony vhost: storage deny'da YOK"
    assert_not_contains "$deny_symfony" "vendor"  "symfony vhost: vendor deny'da YOK"

    _domain_write_vhost deny-ci4.com 8.3 standard http 2>/dev/null
    deny_ci4=$(grep -F 'location ~ ^/(' "${SITES_AVAILABLE}/deny-ci4.com.conf")
    assert_contains "$deny_ci4" "storage" "ci4 vhost: storage deny'da VAR"
    assert_contains "$deny_ci4" "vendor"  "ci4 vhost: vendor deny'da VAR"
else
    echo "  SKIP: _domain_write_vhost henüz yok"
fi

rm -rf "$WEB_ROOT" "$SITES_AVAILABLE" "$SRVCTL_STATE_DIR"
test_summary
