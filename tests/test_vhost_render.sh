#!/bin/bash
# vhost.conf.tpl / vhost-ssl.conf.tpl render testi.
#
# Bu test render_template'i _domain_write_vhost'u BYPASS ederek DOĞRUDAN
# çağırıyor (saf template-render testi) — bu yüzden şablona her yeni token
# eklendiğinde burada da elle beslenmesi gerekiyor. Şablona {{DENY_DIRS}}
# eklendiğinde bu test unutulmuştu: render_template boş kalan token'ı
# literal '{{DENY_DIRS}}' olarak bırakıyordu ve "leftover token yok" ile
# "blocked-dir" assertion'ları FAIL veriyordu (8'de 3).
#
# lib/domain.sh:_domain_write_vhost DENY_DIRS değerini framework beyanına
# göre seçer:
#   - GENİŞ (ci4/varsayılan/legacy): docroot repo köküdür, bu yüzden
#     app/system/vendor/storage/bootstrap/config/... docroot İÇİNDE ve
#     gerçekten tehlikelidir.
#   - DAR (laravel/symfony): docroot public/'tır; 'storage' ve 'vendor' bu
#     düzende MEŞRU public alt yollardır (storage:link -> public/storage;
#     public/vendor/livewire/livewire.js gibi Livewire/Filament asset'leri)
#     — GENİŞ liste bunları 404'lerdi, bu yüzden ikisi DAR listeden çıkarılmıştır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

rate_profile_load strict

# lib/domain.sh:_domain_write_vhost içindeki iki sabit listenin BİREBİR
# kopyası (kod tekrarı kasıtlı — bu test template render'ını izole test
# ediyor, _domain_write_vhost entegrasyonu tests/test_domain_framework.sh'ta).
DENY_WIDE='app|system|vendor|modules|writable|private|tests|node_modules|\.composer|storage|bootstrap|config|database|routes|resources|var'
DENY_NARROW='app|system|modules|writable|private|tests|node_modules|\.composer|bootstrap|config|database|routes|resources|var'

out=$(render_template "${REPO_ROOT}/templates/nginx/vhost.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}" \
    "DENY_DIRS=${DENY_WIDE}")

assert_contains "$out" "limit_req zone=rl_strict burst=10 nodelay;" "general limit_req"
assert_contains "$out" "limit_conn conn_per_ip 20;"                 "conn limit"
assert_contains "$out" "limit_req zone=login_strict burst=3 nodelay;" "login limit_req"
assert_contains "$out" 'wp-login\.php'                              "hassas yol regex"
assert_contains "$out" "storage|bootstrap|config"                  "geniş (ci4) deny listesinde storage var"
assert_contains "$out" "location ~ ^/(${DENY_WIDE})/ {"             "geniş deny bloğu tam render edildi"
assert_not_contains "$out" "{{"                                     "leftover token yok"

# SSL template aynı token'ları çözer (GENİŞ liste)
out_ssl=$(render_template "${REPO_ROOT}/templates/nginx/vhost-ssl.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}" \
    "DENY_DIRS=${DENY_WIDE}")
assert_contains "$out_ssl" "limit_req zone=rl_strict burst=10 nodelay;" "ssl general limit_req"
assert_not_contains "$out_ssl" "{{" "ssl leftover token yok"

# ── DAR liste (laravel/symfony): storage/vendor deny bloğunda OLMAMALI ──
out_narrow=$(render_template "${REPO_ROOT}/templates/nginx/vhost.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}" \
    "DENY_DIRS=${DENY_NARROW}")
# Yalnız deny bloğu satırını izole et (dosyanın başka yerinde 'storage'/'vendor'
# geçebilir; asıl kontrol edilmesi gereken '^/(...)/'' regex grubunun içeriği).
deny_line=$(printf '%s\n' "$out_narrow" | grep -F 'location ~ ^/(')
assert_not_contains "$deny_line" "storage"  "dar (laravel/symfony) liste storage'ı DIŞLAR (public/storage meşru)"
assert_not_contains "$deny_line" "vendor"   "dar (laravel/symfony) liste vendor'ı DIŞLAR (public/vendor/livewire meşru)"
assert_contains     "$deny_line" "bootstrap" "dar liste diğer tehlikeli dizinleri hâlâ engelliyor"
assert_not_contains "$out_narrow" "{{"      "narrow leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
