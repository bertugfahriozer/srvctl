#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  KRİTİK: deploy/cron kilit dizini üzerinden SEMBOLİK BAĞ ile ROOT'a
#  AYRICALIK YÜKSELTME — regresyon kapısı
# ═══════════════════════════════════════════════════════════════════════
#
# SÖMÜRÜ (canlı bir Ubuntu 24.04 e-ticaret sunucusunda 'web_<sname>'
# kullanıcısı olarak ÇALIŞTIRILDI ve BAŞARILI OLDU):
#
#     rm -f  /run/srvctl/locks/<sname>/deploy-<sname>.lock
#     ln -s  /tmp/HEDEF /run/srvctl/locks/<sname>/deploy-<sname>.lock
#     → 'symbolic link -> /tmp/HEDEF'   (BAŞARILI)
#
# Ölçülen izinler:
#     /run/srvctl                      drwx--x--x root:root
#     /run/srvctl/locks                drwx--x--x root:root
#     /run/srvctl/locks/<sname>        700 web_<sname>:web_<sname>  ← SORUN
#     .../deploy-<sname>.lock          644 web_<sname>:web_<sname>
#
# ('644' açıklaması: dosyayı orada 'secure_file 600' DEĞİL, cron job'unun
#  KENDİ flock(1) çağrısı yaratmıştı — O_CREAT mode 0666 & ~umask(022) =
#  0644, sahibi süreci çalıştıran web_<sname>. Yani dosya silinip domain
#  kullanıcısı tarafından yeniden yaratılabiliyordu — 'rm -f' adımının
#  doğrudan kanıtı.)
#
# ZİNCİR: dizinin SAHİBİ domain kullanıcısı olduğundan o kullanıcı dizinde
# unlink+create yapabiliyordu. Ardından ROOT olarak çalışan srvctl:
#     secure_file "$lock_path" 600 "web_x:web_x"   → chmod/chown DEREFERENCE
#     exec 9>"$lock_path"                          → hedefi TRUNCATE
# '/etc/ld.so.preload' hedeflenirse dosya yoksa root 'touch' ile YARATIR,
# 'chown' saldırgana VERİR → TAM ROOT. '/etc/shadow' hedeflenirse sıfırlanır.
#
# YAPISAL ÇÖZÜM (bu dosya onu doğrular):
#   * kilit dizini  710 root:web_<sname>  → domain kullanıcısında 'w' YOK
#   * kilit dosyası 660 root:web_<sname>  → ROOT tarafından ÖN-OLUŞTURULUR
#   * secure_file/secure_dir sembolik bağda FAIL-CLOSED + 'chown -h'
#   * '_deploy_lock' 'exec 9>' YERİNE 'exec 9>>' (TRUNCATE primitifi YOK)
#   * 'srvctl domain repair' MEVCUT (yanlış sahiplikli) kurulumları ONARIR
#   * 'srvctl security audit' yanlış sahipliği FAIL olarak RAPORLAR
#
# DÜRÜSTLÜK NOTU (macOS geliştirme kutusunda ÖLÇÜLEMEYENLER):
#   * GERÇEK 'web_<sname>' Linux kullanıcıları YOK → 'chown' gerçekten
#     uygulanamaz. Bu dosya 'chown'u GÖLGELEYİP (test_secure_fs.sh /
#     test_deploy_lock_isolation.sh ile AYNI teknik) KOD'un HANGİ sahibi
#     İSTEDİĞİNİ doğrular; sahiplik iddiası gereken yerlerde '_stat_owner'
#     de gölgelenir. GERÇEK çok-kullanıcılı DAC uygulaması yalnız gerçek
#     bir Ubuntu sunucusunda doğrulanabilir.
#   * Buna KARŞILIK, saldırının ASIL YIKICI etkileri (hedef dosyanın
#     TRUNCATE edilmesi, MODUNUN değişmesi, sarkan bağın hedefinin
#     YARATILMASI) macOS'ta da GERÇEK dosya sistemi üzerinde BİREBİR
#     ölçülebilir — aşağıdaki iddialar tam olarak bunları kontrol eder.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_LOCK_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_PHP_POOL_DIR="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
confirm() { return 0; }
systemctl() { return 0; }
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/deploy.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/cron.sh"

dom="privesc-hedef.test"
sname=$(safe_name "$dom")
web_user="web_${sname}"
mkdir -p "${WEB_ROOT}/${dom}"

# ── chown STUB (bkz. DÜRÜSTLÜK NOTU) ──
chown_log="${WEB_ROOT}/.chown.log"
: > "$chown_log"
chown() {
    [[ "${1:-}" == "-h" ]] && shift
    printf '%s %s\n' "${1:-}" "${2:-}" >> "$chown_log"
    return 0
}

# ── flock KÖPRÜSÜ: '_deploy_lock' ilk satırında 'command -v flock' kapısı
#    var; flock YOKSA fonksiyon HİÇ ÇALIŞMADAN 0 döner ve aşağıdaki tüm
#    güvenlik iddiaları SESSİZCE atlanırdı (yanlış güven). Bu bölümdeki
#    testler flock'un GERÇEK kilitleme semantiğine İHTİYAÇ DUYMAZ (hepsi
#    flock çağrılmadan ÖNCEKİ kapılarda biter) — bu yüzden basit bir
#    yer tutucu YETERLİDİR ve AÇIKÇA öyle işaretlenmiştir.
FAKEBIN="$(mktemp -d)"
if ! command -v flock >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "${FAKEBIN}/flock"
    chmod +x "${FAKEBIN}/flock"
    export PATH="${FAKEBIN}:${PATH}"
fi

# ═══════════════════════════════════════════════════════════════════════
# 1) SÖMÜRÜNÜN KENDİSİ — kilit yolu SEMBOLİK BAĞ ise '_deploy_lock'
#    FAIL-CLOSED olmalı; hedef dosya HİÇ ETKİLENMEMELİ.
# ═══════════════════════════════════════════════════════════════════════
lock_dir="${SRVCTL_LOCK_DIR}/locks/${sname}"
lock_path="${lock_dir}/deploy-${sname}.lock"

# Saldırganın hedefi ('/etc/ld.so.preload' benzeri): DEĞİŞMEMESİ gereken
# içerik + mod. GERÇEK bir dosya, GERÇEK bir dosya sisteminde.
victim="${WEB_ROOT}/etc-ld-so-preload"
printf '# ROOT-ONLY-ICERIK\n' > "$victim"
chmod 644 "$victim"
victim_before="$(cat "$victim")"

# Saldırgan (ele geçirilmiş web_<sname>) ADIMI: kilit dosyasını silip
# yerine hedefe bağ koy.
mkdir -p "$lock_dir"
chmod 700 "$lock_dir"
rm -f -- "$lock_path"
ln -s "$victim" "$lock_path"
assert_eq "$(test -L "$lock_path" && echo BAG || echo DEGIL)" "BAG" \
    "1) test kurulumu: kilit yoluna sembolik bağ YERLEŞTİRİLDİ (saldırgan adımı)"

: > "$chown_log"
assert_fail bash -c 'source "$1"; source "$2"; log_action(){ :; };
    chown(){ [[ "${1:-}" == "-h" ]] && shift; printf "%s %s\n" "${1:-}" "${2:-}" >> "$4"; return 0; };
    source "$3"; _deploy_lock "$5"' _ \
    "${REPO_ROOT}/lib/core.sh" "${REPO_ROOT}/tests/lib.sh" "${REPO_ROOT}/lib/deploy.sh" "$chown_log" "$dom" \
    "1) kilit yolu SEMBOLİK BAĞ iken _deploy_lock FAIL-CLOSED (error → sıfırdan farklı çıkış)"

assert_eq "$(cat "$victim")" "$victim_before" \
    "1) [KRİTİK] symlink HEDEFİNİN İÇERİĞİ DEĞİŞMEDİ (exec 9> ile TRUNCATE EDİLMEDİ)"
assert_eq "$(_stat_mode "$victim" | tail -c 4)" "644" \
    "1) [KRİTİK] symlink HEDEFİNİN MODU DEĞİŞMEDİ (chmod DEREFERENCE etmedi)"
assert_not_contains "$(cat "$chown_log")" "$victim" \
    "1) [KRİTİK] symlink HEDEFİ için chown HİÇ ÇAĞRILMADI (sahiplik saldırgana VERİLMEDİ)"
assert_eq "$(test -L "$lock_path" && echo BAG || echo DEGIL)" "BAG" \
    "1) srvctl bağı KENDİLİĞİNDEN silmedi (temizlik 'domain repair'in işi — sessiz düzeltme YOK)"

# ── 1b) SARKAN (dangling) BAĞ: eski kodda root 'touch' ile HEDEFİ YARATIR,
#        'chown' ile SALDIRGANA VERİRDİ — '/etc/ld.so.preload' senaryosunun
#        TAM OLARAK bu varyantı TAM ROOT'a götürüyordu.
dangling_target="${WEB_ROOT}/hic-olmayan-ld-so-preload"
rm -f -- "$lock_path"
ln -s "$dangling_target" "$lock_path"
: > "$chown_log"
assert_fail bash -c 'source "$1"; source "$2"; log_action(){ :; };
    chown(){ [[ "${1:-}" == "-h" ]] && shift; printf "%s %s\n" "${1:-}" "${2:-}" >> "$4"; return 0; };
    source "$3"; _deploy_lock "$5"' _ \
    "${REPO_ROOT}/lib/core.sh" "${REPO_ROOT}/tests/lib.sh" "${REPO_ROOT}/lib/deploy.sh" "$chown_log" "$dom" \
    "1b) SARKAN sembolik bağda da _deploy_lock FAIL-CLOSED"
assert_eq "$(test -e "$dangling_target" && echo VAR || echo YOK)" "YOK" \
    "1b) [KRİTİK] sarkan bağın HEDEFİ root tarafından YARATILMADI (touch DEREFERENCE etmedi)"
assert_not_contains "$(cat "$chown_log")" "$dangling_target" \
    "1b) [KRİTİK] sarkan bağın hedefi için chown HİÇ ÇAĞRILMADI"

# ── 1c) İKİNCİ KATMAN: dizin/dosya hazırlığı sorunsuz OLSA BİLE
#        '_deploy_lock' kendi '-L' kapısıyla reddetmeli. '_deploy_lock_dir'
#        gölgelenerek ilk katman (secure_file) DEVRE DIŞI bırakılır ve
#        yalnız ikinci kapı sınanır.
rm -f -- "$lock_path"
ln -s "$victim" "$lock_path"
# NOT: gölge fonksiyonun GÖVDESİNDE '$4' KULLANILAMAZ — bir fonksiyon
# içinde konumsal parametreler FONKSİYONUN kendi argümanlarıdır (script'in
# DEĞİL). Yol bu yüzden ortam değişkeniyle taşınır.
layer2_out="$(
    SRVCTL_TEST_LOCKDIR="$lock_dir" \
    bash -c 'source "$1"; source "$2"; log_action(){ :; };
        source "$3";
        _deploy_lock_dir() { printf "%s" "$SRVCTL_TEST_LOCKDIR"; };
        _deploy_lock "$4"' _ \
        "${REPO_ROOT}/lib/core.sh" "${REPO_ROOT}/tests/lib.sh" "${REPO_ROOT}/lib/deploy.sh" "$dom" 2>&1
)" && layer2_rc=0 || layer2_rc=$?
assert_eq "$([[ "$layer2_rc" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "1c) İKİNCİ KATMAN: _deploy_lock'un KENDİ '-L' kapısı da fail-closed"
assert_contains "$layer2_out" "SEMBOLİK BAĞ" \
    "1c) reddin GEREKÇESİ operatöre AÇIKÇA yazılıyor (sessiz başarısızlık YOK)"
assert_eq "$(cat "$victim")" "$victim_before" \
    "1c) ikinci katman devreye girdiğinde de hedef içeriği DEĞİŞMEDİ"

# ── 1d) TRUNCATE PRİMİTİFİ: kilit dosyası GERÇEK (bağ değil) olsa bile
#        '_deploy_lock' onu SIFIRLAMAMALI ('exec 9>' → 'exec 9>>').
rm -f -- "$lock_path"
rm -rf -- "$lock_dir"
lock_dir_real=$(_deploy_lock_dir "$sname" "$web_user")
printf 'BOZULMAMALI\n' > "${lock_dir_real}/deploy-${sname}.lock"
( _deploy_lock "$dom" ) >/dev/null 2>&1 || true
assert_eq "$(cat "${lock_dir_real}/deploy-${sname}.lock")" "BOZULMAMALI" \
    "1d) [KRİTİK] _deploy_lock kilit dosyasını TRUNCATE ETMİYOR ('exec 9>>' — keyfi-truncate primitifi YOK)"

# ═══════════════════════════════════════════════════════════════════════
# 2) KİLİT DİZİNİ ROOT'A AİT — 'web_<sname>'e DEĞİL
# ═══════════════════════════════════════════════════════════════════════
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks/${sname}"
: > "$chown_log"
dir_out=$(_deploy_lock_dir "$sname" "$web_user")
assert_eq "$dir_out" "$lock_dir" \
    "2) _deploy_lock_dir beklenen yolu döndürüyor"
assert_contains "$(cat "$chown_log")" "root:${web_user} ${lock_dir}" \
    "2) kilit dizini ROOT'a (grup web_<sname>) chown edilmeye ÇALIŞILDI"
assert_not_contains "$(cat "$chown_log")" "${web_user}:${web_user} ${lock_dir}" \
    "2) [REGRESYON KAPISI] kilit dizini ARTIK 'web_x:web_x'e chown EDİLMİYOR"
mode_dir=$(_stat_mode "$lock_dir" | tail -c 4)
assert_eq "$mode_dir" "710" \
    "2) kilit dizini modu 710 (grup: --x — GEÇİŞ VAR, YAZMA YOK)"
# Grup/diğer YAZMA biti KESİNLİKLE olmamalı: 'w' varsa unlink+create geri gelir.
g="${mode_dir:1:1}"; o="${mode_dir:2:1}"
assert_eq "$(( (g & 2) | (o & 2) ))" "0" \
    "2) [KRİTİK] kilit dizininde grup/diğer YAZMA biti YOK (unlink+create İMKÂNSIZ)"
assert_eq "$(( o ))" "0" \
    "2) kilit dizininde 'diğer' bitleri TAMAMEN kapalı (domainler arası izolasyon)"

# ═══════════════════════════════════════════════════════════════════════
# 3) MEVCUT KURULUMLARIN ONARIMI — 'srvctl domain repair'
#    Kod düzeltmesi TEK BAŞINA YETMEZ: üretimdeki dizinler ŞU AN
#    '700 web_x:web_x'. Bu bölüm '_domain_repair_lock_dir'in onları
#    GERÇEKTEN düzelttiğini doğrular.
# ═══════════════════════════════════════════════════════════════════════
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/domain.sh"

# 3a) Yanlış MOD (700) + yanlış SAHİP (web_x) → 710 + root'a chown
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks/${sname}"
mkdir -p "$lock_dir"
chmod 700 "$lock_dir"
: > "$chown_log"
# '_stat_owner' gölgelenir: macOS'ta dizin GERÇEKTEN web_x'e ait olamaz,
# ama onarım KODUNUN "root'a ait DEĞİL" durumunu TESPİT ettiği doğrulanır.
_stat_owner() { printf '%s' "$web_user"; }
repair_out="$( _domain_repair_lock_dir "$dom" "$sname" "$web_user" 2>&1 )" && repair_rc=0 || repair_rc=$?
unset -f _stat_owner
assert_eq "$repair_rc" "0" \
    "3a) _domain_repair_lock_dir başarıyla döndü"
assert_contains "$repair_out" "GÜVENLİK ONARIMI" \
    "3a) YANLIŞ SAHİPLİK AÇIKÇA raporlandı (sessiz düzeltme YOK)"
assert_contains "$repair_out" "$web_user" \
    "3a) rapor, dizinin HANGİ kullanıcıya ait olduğunu yazıyor"
assert_eq "$(_stat_mode "$lock_dir" | tail -c 4)" "710" \
    "3a) [KRİTİK] repair kilit dizini modunu 700 → 710 olarak DÜZELTTİ"
assert_contains "$(cat "$chown_log")" "root:${web_user} ${lock_dir}" \
    "3a) [KRİTİK] repair dizini ROOT'a chown etmeye ÇALIŞTI"
assert_eq "$(test -f "$lock_path" && echo VAR || echo YOK)" "VAR" \
    "3a) repair kilit DOSYASINI ön-oluşturdu (flock(1) artık kendisi yaratamaz)"
assert_eq "$(_stat_mode "$lock_path" | tail -c 4)" "660" \
    "3a) repair kilit dosyasını 660 yaptı"

# 3b) YERLEŞTİRİLMİŞ SEMBOLİK BAĞ → kaldırılır, HEDEFE DOKUNULMAZ
rm -f -- "$lock_path"
ln -s "$victim" "$lock_path"
: > "$chown_log"
_stat_owner() { printf 'root'; }
repair_out2="$( _domain_repair_lock_dir "$dom" "$sname" "$web_user" 2>&1 )" && repair_rc2=0 || repair_rc2=$?
unset -f _stat_owner
assert_eq "$repair_rc2" "0" \
    "3b) sembolik bağ bulunduğunda da repair BAŞARIYLA tamamlanıyor"
assert_contains "$repair_out2" "GÜVENLİK UYARISI" \
    "3b) [KRİTİK] yerleştirilmiş sembolik bağ AKTİF SALDIRI olarak raporlanıyor"
assert_contains "$repair_out2" "$victim" \
    "3b) raporda bağın HEDEFİ yazıyor (operatör ihlali inceleyebilsin)"
assert_eq "$(test -L "$lock_path" && echo BAG || echo DEGIL)" "DEGIL" \
    "3b) [KRİTİK] sembolik bağ KALDIRILDI"
assert_eq "$(test -f "$lock_path" && echo VAR || echo YOK)" "VAR" \
    "3b) yerine GERÇEK bir kilit dosyası kondu"
assert_eq "$(cat "$victim")" "$victim_before" \
    "3b) [KRİTİK] bağın HEDEFİ SİLİNMEDİ/DEĞİŞMEDİ ('rm' bağı kaldırır, hedefi DEĞİL)"

# ═══════════════════════════════════════════════════════════════════════
# 4) 'srvctl security audit' — YANLIŞ SAHİPLİK 'FAIL' OLARAK RAPORLANIYOR
# ═══════════════════════════════════════════════════════════════════════
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/security.sh"

# 4a) SAF karar fonksiyonu (yan etkisiz — tam karar tablosu)
assert_eq "$(_audit_lock_dir_verdict dizin root 710 dosya root)" "OK" \
    "4a) 710 root + kilit dosyası root → OK"
assert_eq "$(_audit_lock_dir_verdict yok '' '' yok '')" "YOK" \
    "4a) ağaç hiç yoksa → YOK (WARN; /run tmpfs, ilk deploy'da oluşur)"
assert_eq "$(_audit_lock_dir_verdict dizin root 710 yok '')" "KILIT_YOK" \
    "4a) dizin güvenli ama kilit dosyası yoksa → KILIT_YOK (işlevsel WARN)"
assert_eq "$(_audit_lock_dir_verdict symlink '' '' yok '')" "DIZIN_SYMLINK" \
    "4a) kilit DİZİNİ sembolik bağ → DIZIN_SYMLINK (FAIL)"
assert_eq "$(_audit_lock_dir_verdict dizin "$web_user" 700 dosya "$web_user")" "DIZIN_SAHIBI" \
    "4a) [KRİTİK] ÜRETİMDE ÖLÇÜLEN DURUM (700 web_x:web_x) → DIZIN_SAHIBI (FAIL)"
assert_eq "$(_audit_lock_dir_verdict dizin root 770 dosya root)" "DIZIN_YAZILIR" \
    "4a) grup YAZMA biti (770) → DIZIN_YAZILIR (FAIL)"
assert_eq "$(_audit_lock_dir_verdict dizin root 712 dosya root)" "DIZIN_YAZILIR" \
    "4a) diğer YAZMA biti (712) → DIZIN_YAZILIR (FAIL)"
assert_eq "$(_audit_lock_dir_verdict dizin root 710 symlink '')" "KILIT_SYMLINK" \
    "4a) kilit DOSYASI sembolik bağ → KILIT_SYMLINK (FAIL)"
assert_eq "$(_audit_lock_dir_verdict dizin root 710 dosya "$web_user")" "KILIT_SAHIBI" \
    "4a) [KRİTİK] ÜRETİMDE ÖLÇÜLEN DURUM (kilit dosyası web_x'e ait) → KILIT_SAHIBI (FAIL)"
assert_eq "$(_audit_lock_dir_verdict dizin root 2710 dosya root)" "OK" \
    "4a) setgid ön ekli mod (2710) doğru ayrıştırılıyor (son 3 hane)"

# 4b) Denetim sarmalayıcısı — GERÇEK dosya sistemi üzerinde, enjekte
#     edilmiş PASS/FAIL/WARN geri çağırmalarıyla (audit'in KENDİ deseni).
audit_log="${WEB_ROOT}/.audit.log"
_p() { printf 'PASS %s\n' "$1" >> "$audit_log"; }
_f() { printf 'FAIL %s\n' "$1" >> "$audit_log"; }
_w() { printf 'WARN %s\n' "$1" >> "$audit_log"; }

# ÜRETİMDEKİ (onarılmamış) durum: 700, sahibi web_x → FAIL beklenir.
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks/${sname}"
mkdir -p "$lock_dir"; chmod 700 "$lock_dir"; : > "$lock_path"
: > "$audit_log"
_stat_owner() { printf '%s' "$web_user"; }
_check_lock_dir_ownership _p _f _w "$dom" "$sname"
unset -f _stat_owner
assert_contains "$(cat "$audit_log")" "FAIL" \
    "4b) [KRİTİK] 'security audit' YANLIŞ SAHİPLİĞİ (700 web_x) FAIL olarak raporluyor"
assert_contains "$(cat "$audit_log")" "domain repair" \
    "4b) FAIL mesajı operatöre ÇÖZÜMÜ ('srvctl domain repair') söylüyor"

# Yerleştirilmiş sembolik bağ → FAIL
rm -f -- "$lock_path"; ln -s "$victim" "$lock_path"
: > "$audit_log"
_stat_owner() { printf 'root'; }
_check_lock_dir_ownership _p _f _w "$dom" "$sname"
unset -f _stat_owner
assert_contains "$(cat "$audit_log")" "FAIL" \
    "4b) [KRİTİK] kilit dosyası sembolik bağ ise FAIL"
assert_contains "$(cat "$audit_log")" "SEMBOLİK BAĞ" \
    "4b) FAIL mesajı AKTİF SALDIRI olduğunu AÇIKÇA söylüyor"

# Onarılmış durum → PASS
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks/${sname}"
: > "$chown_log"
_deploy_lock_dir "$sname" "$web_user" >/dev/null
: > "$audit_log"
_stat_owner() { printf 'root'; }
_check_lock_dir_ownership _p _f _w "$dom" "$sname"
unset -f _stat_owner
assert_contains "$(cat "$audit_log")" "PASS" \
    "4b) onarılmış (710 root + 660 root kilit) ağaç PASS veriyor"
assert_not_contains "$(cat "$audit_log")" "FAIL" \
    "4b) onarılmış ağaçta HİÇ FAIL yok (yanlış pozitif YOK)"

# Ağaç hiç yoksa → WARN (FAIL DEĞİL: '/run' tmpfs'tir, yeniden başlatmada silinir)
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks/${sname}"
: > "$audit_log"
_check_lock_dir_ownership _p _f _w "$dom" "$sname"
assert_contains "$(cat "$audit_log")" "WARN" \
    "4b) ağaç henüz yoksa WARN (FAIL DEĞİL — yanlış alarm üretilmez)"
assert_not_contains "$(cat "$audit_log")" "FAIL" \
    "4b) ağaç yokluğu FAIL sayılmıyor"

unset -f chown
rm -rf "$WEB_ROOT" "$SRVCTL_LOCK_DIR" "$SRVCTL_STATE_DIR" "$SRVCTL_SYSTEMD_DIR" \
       "$SRVCTL_FPM_DIR" "$SRVCTL_PHP_POOL_DIR" "$FAKEBIN"
test_summary
