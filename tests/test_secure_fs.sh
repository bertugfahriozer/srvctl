#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# secure_file: yoksa oluşturur, varsayılan 600
f="${WEB_ROOT}/secret.cred"
assert_ok secure_file "$f"
assert_eq "$(test -f "$f" && echo VAR || echo YOK)" "VAR" "secure_file oluşturdu"
assert_eq "$(_stat_mode "$f" | tail -c 4)" "600" "secure_file varsayılan mod 600"

# secure_file: özel mod
f2="${WEB_ROOT}/secret2.cred"
secure_file "$f2" 640
assert_eq "$(_stat_mode "$f2" | tail -c 4)" "640" "secure_file özel mod 640"

# secure_file: var olan dosyanın modunu düzeltir
f3="${WEB_ROOT}/loose.cred"; : > "$f3"; chmod 666 "$f3"
secure_file "$f3"
assert_eq "$(_stat_mode "$f3" | tail -c 4)" "600" "secure_file gevşek modu sıkılaştırır"

# REGRESYON: secure_file MEVCUT İÇERİĞİ KORUMALI (truncate ETMEMELİ) —
# aksi halde /root/.my.cnf, yedek artefaktları, migrate credentials boşalır.
f4="${WEB_ROOT}/withdata.cred"; printf 'DB_PASS=gizli123\nX=y\n' > "$f4"
secure_file "$f4" 600
assert_eq "$(cat "$f4")" "$(printf 'DB_PASS=gizli123\nX=y')" "secure_file içeriği korur (truncate etmez)"
assert_eq "$(_stat_mode "$f4" | tail -c 4)" "600" "içerikli dosyada da mod 600"

# secure_dir: yoksa oluşturur, varsayılan 700
d="${WEB_ROOT}/vault"
assert_ok secure_dir "$d"
assert_eq "$(test -d "$d" && echo VAR || echo YOK)" "VAR" "secure_dir oluşturdu"
assert_eq "$(_stat_mode "$d" | tail -c 4)" "700" "secure_dir varsayılan mod 700"

# secure_dir: özel mod + iç içe (mkdir -p)
d2="${WEB_ROOT}/a/b/c"
secure_dir "$d2" 750
assert_eq "$(test -d "$d2" && echo VAR || echo YOK)" "VAR" "secure_dir iç içe oluşturdu"
assert_eq "$(_stat_mode "$d2" | tail -c 4)" "750" "secure_dir özel mod 750"

# ═══════════════════════════════════════════════════════════════
# 3. parametre 'owner' (görev: /run/srvctl deploy-kilidi DAC/root
# çelişkisi düzeltmesi — bkz. lib/deploy.sh:_deploy_lock_dir /
# lib/cron.sh:_cron_lock_dir). chown GERÇEK Linux kullanıcı adlarına
# İHTİYAÇ duyduğundan (bu macOS dev kutusunda 'web_ornek' yok) gerçek
# sahiplik burada DOĞRULANAMAZ — bunun yerine 'chown' bir FONKSİYON ile
# GÖLGELENİR (bkz. tests/test_cron_add.sh'taki 'systemctl' stub deseniyle
# AYNI teknik) ve secure_file/secure_dir'in İSTEDİĞİ sahiplik dizgesini
# DOĞRU ARGÜMANLARLA çağırdığı doğrulanır — mod bitleri (chmod GERÇEKTEN
# çalışır, macOS'ta ayrıcalık gerektirmez) AYRICA gerçek stat ile kontrol
# edilir.
# ═══════════════════════════════════════════════════════════════
chown_log="${WEB_ROOT}/.chown.log"
: > "$chown_log"
chown() { printf '%s %s\n' "$1" "$2" >> "$chown_log"; return 0; }

# secure_dir: owner VERİLMEDEN — GERİYE DÖNÜK UYUMLULUK REGRESYONU: hiçbir
# mevcut çağrı yeri (init.sh/backup.sh/webhook.sh/domain.sh/security.sh/
# selfupdate.sh/plugin.sh — 9+ çağrı) 3. argüman VERMEZ; varsayılan HÂLÂ
# 'root:root' OLMALI.
: > "$chown_log"
d3="${WEB_ROOT}/default-owner-dir"
secure_dir "$d3" 700
assert_eq "$(cat "$chown_log")" "root:root ${d3}" \
    "secure_dir: owner verilmezse VARSAYILAN 'root:root' (geriye dönük uyum)"

# secure_dir: owner AÇIKÇA VERİLİRSE o kullanıcıya chown edilmeye ÇALIŞILIR
: > "$chown_log"
d4="${WEB_ROOT}/domain-owned-dir"
secure_dir "$d4" 700 "web_ornek:web_ornek"
assert_eq "$(cat "$chown_log")" "web_ornek:web_ornek ${d4}" \
    "secure_dir: 3. parametre ile İSTENEN sahibe chown ÇAĞRILIYOR"
assert_eq "$(_stat_mode "$d4" | tail -c 4)" "700" \
    "secure_dir: owner verilse BİLE mod bitleri (700) DOĞRU uygulanıyor"

# secure_file: AYNI owner parametresi — deploy kilidi DOSYASININ KENDİSİ
# İÇİN (bkz. lib/deploy.sh:_deploy_lock) gereklidir.
: > "$chown_log"
f5="${WEB_ROOT}/domain-owned-file"
secure_file "$f5" 600 "web_ornek:web_ornek"
assert_eq "$(cat "$chown_log")" "web_ornek:web_ornek ${f5}" \
    "secure_file: 3. parametre ile İSTENEN sahibe chown ÇAĞRILIYOR"
assert_eq "$(_stat_mode "$f5" | tail -c 4)" "600" \
    "secure_file: owner verilse BİLE mod bitleri (600) DOĞRU uygulanıyor"

: > "$chown_log"
f6="${WEB_ROOT}/default-owner-file"
secure_file "$f6" 600
assert_eq "$(cat "$chown_log")" "root:root ${f6}" \
    "secure_file: owner verilmezse VARSAYILAN 'root:root' (geriye dönük uyum)"

unset -f chown

rm -rf "$WEB_ROOT"
test_summary
