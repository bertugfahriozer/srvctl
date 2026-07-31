#!/bin/bash
# Deploy yetki düşürme (T3) sözleşmesi.
#
# shared/hooks/ ve repodan gelen composer.json web_user tarafından yazılabilir.
# Eski kod ikisini de ROOT olarak çalıştırıyordu:
#   deploy.sh:43  RELEASE_DIR=... bash "$hook_file"
#   deploy.sh:158 ( cd "$release_dir" && composer install ... )
# Yani ele geçirilmiş bir PHP uygulaması shared/hooks/post-deploy.sh yazıp bir
# sonraki deploy'da ROOT kod çalıştırabiliyordu (web_user → root yükseltme).
# README.md:116-119 aksini iddia ediyordu; kod hiç yazılmamıştı.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

probe="${WEB_ROOT}/hook-calisti"
hook="${WEB_ROOT}/pre-deploy.sh"
printf '#!/bin/bash\ntouch "%s"\n' "$probe" > "$hook"
chmod +x "$hook"

# ── 1) web_user verilmeden hook ÇALIŞTIRILMAZ (root'a düşme yok) ──
rm -f "$probe"
_run_hook "$hook" "${WEB_ROOT}/release" "example.com" >/dev/null 2>&1
assert_eq "$([[ -e "$probe" ]] && echo calisti || echo calismadi)" "calismadi" \
          "web_user'sız hook root olarak ÇALIŞTIRILMADI"

# ── 2) var olmayan kullanıcıda da çalıştırılmaz (fail-closed) ──
rm -f "$probe"
_run_hook "$hook" "${WEB_ROOT}/release" "example.com" "yokboyle_kullanici_9x" >/dev/null 2>&1
assert_eq "$([[ -e "$probe" ]] && echo calisti || echo calismadi)" "calismadi" \
          "geçersiz web_user'da hook root'a düşmedi"

# ── 3) hook dosyası yoksa sessizce 0 döner ──
assert_ok _run_hook "${WEB_ROOT}/yok.sh" "${WEB_ROOT}/release" "example.com" "web_x"

# ── 4) _deploy_privdrop predikatı ──
assert_fail _deploy_privdrop ""                       true
assert_fail _deploy_privdrop "yokboyle_kullanici_9x"  true

# ── 5) FAIL-CLOSED: runuser yoksa ROOT olarak çalıştırma ──
# (runuser'ı geçici olarak "bulunamaz" yapıp mevcut kullanıcıyla dene)
_orig_command=$(declare -f command 2>/dev/null || true)
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "runuser" ]]; then return 1; fi
    builtin command "$@"
}
rm -f "$probe"
_deploy_privdrop "$(id -un)" touch "$probe" >/dev/null 2>&1
assert_eq "$([[ -e "$probe" ]] && echo calisti || echo calismadi)" "calismadi" \
          "runuser yoksa komut root olarak çalıştırılmadı"
unset -f command
[[ -n "$_orig_command" ]] && eval "$_orig_command"

# ── 6) Kaynak kodda root çalıştırma kalıntısı kalmamalı ──
src=$(cat "${REPO_ROOT}/lib/deploy.sh")
assert_not_contains "$src" 'DOMAIN="$domain" bash "$hook_file"' "hook'un çıplak root çağrısı kaldırıldı"
assert_contains     "$src" '_deploy_privdrop "$web_user"'       "hook privdrop üzerinden çalışıyor"

# ── 7) Composer: privdrop KORUNUYOR (root olarak çalışmıyor) VE domain'in
#    PHP CLI'ıyla (php_bin) çağrılıyor — HOST'un varsayılan PHP'sine değil.
#    (bkz. gerçek VM bug'ı: composer eskiden çıplak 'composer' adıyla
#    çağrıldığından kendi shebang'ı üzerinden HOST'un varsayılan php'sini
#    seçiyordu; domain PHP 8.3'teyken host'ta php8.4 de kuruluysa composer
#    YANLIŞ sürümle platform kontrolünü geçiyor, iki adım sonra 'artisan
#    config:cache' domain'in gerçek php8.3'üyle patlıyordu.)
#    Gerçek çağrı _deploy_composer_install() içinde yaşıyor (_deploy_run'dan
#    ÇIKARILDI, bkz. tests/test_deploy_composer_php.sh); sadece o
#    fonksiyonun gövdesine bakılır — dosyanın geri kalanındaki 'composer
#    install' geçen yorumlar (ör. kök-neden anlatımı) bu assert'leri
#    YANLIŞLIKLA geçirmesin diye.
composer_block=$(awk '/^_deploy_composer_install\(\) \{/{flag=1} flag{print} /^\}/{if (flag) exit}' "${REPO_ROOT}/lib/deploy.sh")
assert_contains     "$composer_block" '_deploy_privdrop "$web_user"' \
    "composer web_user olarak (privdrop ile) çalıştırılıyor — root DEĞİL"
assert_contains     "$composer_block" '"$php_bin" "$composer_bin" install --working-dir=' \
    "composer domain'in PHP CLI'ıyla (php_bin) çağrılıyor"
assert_not_contains "$composer_block" $'\n            composer install' \
    "composer artık ÇIPLAK 'composer' komutuyla (php_bin'siz/HOST'un varsayılanıyla) çağrılmıyor"

rm -rf "$WEB_ROOT"
test_summary
