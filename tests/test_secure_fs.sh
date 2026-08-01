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
#
# GÜNCELLEME (KRİTİK güvenlik düzeltmesi — symlink dereference): secure_file/
# secure_dir ARTIK 'chown -h' çağırır (sembolik bağın KENDİSİNİ değiştirir,
# HEDEFİNİ DEĞİL). Stub bu bayrağı AYRI bir günlüğe alır ki (a) mevcut
# "hangi sahip isteniyor" iddiaları AYNEN kalabilsin, (b) '-h'nin GERÇEKTEN
# verildiği AYRICA doğrulanabilsin.
chown_log="${WEB_ROOT}/.chown.log"
chown_flag_log="${WEB_ROOT}/.chown-flag.log"
: > "$chown_log"
: > "$chown_flag_log"
chown() {
    local hflag="HAYIR"
    if [[ "${1:-}" == "-h" ]]; then hflag="EVET"; shift; fi
    printf '%s\n' "$hflag" >> "$chown_flag_log"
    printf '%s %s\n' "${1:-}" "${2:-}" >> "$chown_log"
    return 0
}

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

# ═══════════════════════════════════════════════════════════════
# 'chown -h' — SYMLINK DEREFERENCE KARŞITI (KRİTİK)
# 'chown' (bayraksız) bir sembolik bağın HEDEFİNİ sahiplendirir; canlı
# üretimde SÖMÜRÜLEN zincirin tam da bu adımı root'a '/etc/ld.so.preload'
# gibi keyfi bir dosyayı saldırgana VERDİRİYORDU. '-h' bağın KENDİSİNİ
# hedefler — dereference primitifi kökten yok olur.
# ═══════════════════════════════════════════════════════════════
: > "$chown_flag_log"
f7="${WEB_ROOT}/hflag-file"
secure_file "$f7" 600
assert_eq "$(cat "$chown_flag_log")" "EVET" \
    "secure_file: chown '-h' İLE çağrılıyor (symlink DEREFERENCE etmez)"

: > "$chown_flag_log"
d5="${WEB_ROOT}/hflag-dir"
secure_dir "$d5" 700
assert_eq "$(cat "$chown_flag_log")" "EVET" \
    "secure_dir: chown '-h' İLE çağrılıyor (symlink DEREFERENCE etmez)"

# ═══════════════════════════════════════════════════════════════
# FAIL-CLOSED: hedef yolun KENDİSİ sembolik bağ ise HİÇBİR ŞEY YAPILMAZ
#
# ÖLÇÜLEN ÜRETİM SALDIRISI (Ubuntu 24.04): domain kullanıcısı kilit
# dosyasını silip yerine '/tmp/HEDEF'e bağ koydu; root olarak çalışan
# secure_file bağı DEREFERENCE edip HEDEFİ chown/chmod etti (ve çağıran
# 'exec 9>' ile TRUNCATE etti). Aşağıdaki iddialar bu primitifin ARTIK
# ÜRETİLEMEDİĞİNİ gösterir: hedefin ne İÇERİĞİ ne MODU değişir, chown
# HİÇ ÇAĞRILMAZ ve fonksiyon SIFIRDAN FARKLI döner.
# ═══════════════════════════════════════════════════════════════
victim="${WEB_ROOT}/kurban.txt"
printf 'GİZLİ-İÇERİK\n' > "$victim"
chmod 644 "$victim"
link="${WEB_ROOT}/kotu.link"
ln -s "$victim" "$link"

: > "$chown_log"
: > "$chown_flag_log"
assert_fail secure_file "$link" 600 "web_ornek:web_ornek" \
    "secure_file: hedef SEMBOLİK BAĞ ise 1 döner (fail-closed)"
assert_eq "$(cat "$victim")" "GİZLİ-İÇERİK" \
    "secure_file: symlink HEDEFİNİN içeriği DEĞİŞMEDİ (truncate YOK)"
assert_eq "$(_stat_mode "$victim" | tail -c 4)" "644" \
    "secure_file: symlink HEDEFİNİN modu DEĞİŞMEDİ (chmod dereference YOK)"
assert_eq "$(cat "$chown_log")" "" \
    "secure_file: symlink hedefine chown HİÇ ÇAĞRILMADI"

# Sarkan (dangling) bağ: eski kod 'touch' ile HEDEFİ root olarak YARATIRDI.
dangling_target="${WEB_ROOT}/hic-olmayan.txt"
dangling="${WEB_ROOT}/sarkan.link"
ln -s "$dangling_target" "$dangling"
assert_fail secure_file "$dangling" 600 \
    "secure_file: SARKAN sembolik bağda da 1 döner"
assert_eq "$(test -e "$dangling_target" && echo VAR || echo YOK)" "YOK" \
    "secure_file: sarkan bağın HEDEFİ root tarafından YARATILMADI (touch dereference YOK)"

# secure_dir: dizin hedefli bağ
victim_dir="${WEB_ROOT}/kurban-dizin"
mkdir -p "$victim_dir"; chmod 755 "$victim_dir"
dlink="${WEB_ROOT}/kotu-dizin.link"
ln -s "$victim_dir" "$dlink"
: > "$chown_log"
assert_fail secure_dir "$dlink" 700 "web_ornek:web_ornek" \
    "secure_dir: hedef SEMBOLİK BAĞ ise 1 döner (fail-closed)"
assert_eq "$(_stat_mode "$victim_dir" | tail -c 4)" "755" \
    "secure_dir: symlink HEDEF DİZİNİNİN modu DEĞİŞMEDİ"
assert_eq "$(cat "$chown_log")" "" \
    "secure_dir: symlink hedefine chown HİÇ ÇAĞRILMADI"

unset -f chown

rm -rf "$WEB_ROOT"
test_summary
