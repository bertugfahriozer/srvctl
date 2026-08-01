#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  SESSİZ FAIL-CLOSED — GÖRÜNÜRLÜK REGRESYON KAPISI
# ═══════════════════════════════════════════════════════════════════════
#
# tests/test_lock_symlink_privesc.sh sömürünün ENGELLENDİĞİNİ kanıtlar.
# BU DOSYA farklı bir soruyu sorar: engellendiğini OPERATÖR ÖĞRENİYOR MU?
#
# ÜRETİMDE ÖLÇÜLEN SEMPTOM (Ubuntu 24.04, gerçek sunucu — kilit yolu
# sembolik bağ yapıldıktan sonra):
#     srvctl deploy dev.designwestgate.art
#       → rc=1                                   (fail-closed: DOĞRU)
#       → stdout'a 0 karakter                    (ÖLÇÜLDÜ)
#       → /usr/local/srvctl/logs/srvctl.log'a 0 satır   (ÖLÇÜLDÜ)
# Yani red DOĞRUYDU ama olay hiçbir KALICI iz bırakmıyordu: terminal
# kapandıktan sonra "biri root'a keyfi chown/truncate primitifi denedi"
# bilgisi TAMAMEN kayboluyordu. Bu bir kozmetik eksik DEĞİL, bir GÜVENLİK
# OLAYININ KAYDEDİLMEMESİDİR.
#
# KÖK NEDEN (bu depoda ölçülerek elendi — tahmin DEĞİL):
#   * errexit'in 'warn'dan ÖNCE öldürmesi: HAYIR. 'lock_dir=$(...) || error'
#     biçimi atamayı errexit'ten MUAF kılar (bkz. lib/deploy.sh).
#   * warn'ın stderr'inin komut ikamesinde kaybolması: HAYIR. '$( )' YALNIZ
#     stdout yakalar; stderr çağırana geçer (bu dosya bunu ÖLÇER).
#   * '|| return 0' yutması: _deploy_lock'ta 'exec 9>>... || return 0' vardı
#     ve GERÇEKTEN sessiz bir fail-OPEN idi (kilitsiz devam) — düzeltildi.
#   * ASIL NEDEN: bu yolun HİÇBİR yerinde 'log_action' YOKTU ve tüm çıktı
#     YALNIZ stderr'de yaşıyordu. stdout'u toplayan/stderr'i atan HER
#     tüketici (otomasyon, webhook, kayıt altına alan wrapper) sıfır görür.
#
# BU TESTİN SÖZLEŞMESİ — sadece çıkış kodunu test etmek TAM DA BU HATAYI
# KAÇIRAN test olurdu (mevcut privesc testi 'assert_fail' ile yalnız rc'ye
# bakıyor ve çıktıyı /dev/null'a atıyor). Burada ÜÇ şey birden istenir:
#   (a) fail-closed (rc != 0),
#   (b) stderr'de TANINABİLİR + EYLEME DÖNÜŞTÜRÜLEBİLİR bir mesaj
#       (ne oldu / hangi yol / ne yapmalı),
#   (c) 'log_action' ÇAĞRILMASI ve srvctl loguna 'GÜVENLİK' izinin düşmesi.
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

dom="gorunurluk.test"
sname=$(safe_name "$dom")
web_user="web_${sname}"
mkdir -p "${WEB_ROOT}/${dom}"

# ── flock KÖPRÜSÜ: '_deploy_lock' ilk satırında 'command -v flock' kapısı
#    var; flock YOKSA fonksiyon HİÇ ÇALIŞMADAN 0 döner ve aşağıdaki tüm
#    iddialar SESSİZCE atlanırdı (test_lock_symlink_privesc.sh ile AYNI
#    gerekçe/teknik). Bu testler flock'un GERÇEK semantiğine ihtiyaç
#    DUYMAZ — hepsi flock çağrılmadan ÖNCEKİ kapılarda biter.
FAKEBIN="$(mktemp -d)"
if ! command -v flock >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "${FAKEBIN}/flock"
    chmod +x "${FAKEBIN}/flock"
    export PATH="${FAKEBIN}:${PATH}"
fi

# GERÇEK bir srvctl log dosyası — 'log_action' stub'lanMAZ, çünkü test
# edilen şey tam olarak "olay LOGA DÜŞÜYOR MU" sorusudur.
export SRVCTL_LOG="${WEB_ROOT}/srvctl.log"

victim="${WEB_ROOT}/etc-ld-so-preload"
printf '# ROOT-ONLY-ICERIK\n' > "$victim"

lock_dir="${SRVCTL_LOCK_DIR}/locks/${sname}"
lock_path="${lock_dir}/deploy-${sname}.lock"

# Üç akışı da AYNI biçimde ölçen tek yardımcı: stdout / stderr / log AYRI
# AYRI toplanır (birleştirilmez — üretimde ölçülen semptomun tam da
# "stdout 0, log 0" olması bu ayrımı ZORUNLU kılıyor).
OUT=""; ERR=""; LOGD=""; RC=0
run_measured() {
    local out_f err_f
    out_f=$(mktemp); err_f=$(mktemp)
    : > "$SRVCTL_LOG"
    RC=0
    (
        set -euo pipefail
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/core.sh"
        SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
        # core.sh SRVCTL_LOG'u KOŞULSUZ olarak '${SRVCTL_ROOT}/logs/...'
        # yapar (üretimde DOĞRU olan budur — log yolu ortam değişkeniyle
        # SAPTIRILAMAMALI). Bu yüzden test kendi yolunu source'tan SONRA
        # geri koyar; üretim semantiği DEĞİŞMEZ.
        SRVCTL_LOG="${WEB_ROOT}/srvctl.log"
        # chown macOS'ta gerçek web_* kullanıcısı olmadığından no-op'lanır
        # (test_lock_symlink_privesc.sh ile AYNI teknik).
        chown() { return 0; }
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/deploy.sh"
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/domain.sh"
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/cron.sh"
        confirm() { return 0; }
        systemctl() { return 0; }
        "$@"
    ) > "$out_f" 2> "$err_f" || RC=$?
    OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); LOGD=$(cat "$SRVCTL_LOG" 2>/dev/null)
    rm -f -- "$out_f" "$err_f"
}

# ═══════════════════════════════════════════════════════════════════════
# 1) DEPLOY — kilit DOSYASI sembolik bağ (üretimde ölçülen senaryo)
# ═══════════════════════════════════════════════════════════════════════
mkdir -p "$lock_dir"
rm -f -- "$lock_path"
ln -s "$victim" "$lock_path"

run_measured _deploy_lock "$dom"

assert_eq "$([[ "$RC" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "1) deploy FAIL-CLOSED (rc != 0) — mevcut davranış KORUNUYOR"

# (b) Operatör NE OLDUĞUNU görüyor mu?
assert_contains "$ERR" "SEMBOLİK BAĞ" \
    "1) [SESSİZLİK KAPISI] stderr'de TANINABİLİR bir ret mesajı VAR (ne oldu)"
assert_contains "$ERR" "$lock_path" \
    "1) [SESSİZLİK KAPISI] stderr HANGİ YOLUN sembolik bağ olduğunu yazıyor"
assert_contains "$ERR" "$victim" \
    "1) [SESSİZLİK KAPISI] stderr bağın HEDEFİNİ yazıyor (ihlal incelenebilsin)"
assert_contains "$ERR" "srvctl domain repair ${dom}" \
    "1) [SESSİZLİK KAPISI] stderr NE YAPILACAĞINI yazıyor (domain repair <domain>)"

# (c) Olay KALICI iz bırakıyor mu? — üretimde ölçülen '0 satır' düzeltmesi.
assert_eq "$([[ -n "$LOGD" ]] && echo DOLU || echo BOS)" "DOLU" \
    "1) [KRİTİK] srvctl.log'a EN AZ BİR satır yazıldı (üretimde 0 satırdı)"
assert_contains "$LOGD" "GÜVENLİK" \
    "1) [KRİTİK] log satırı 'GÜVENLİK' etiketiyle greplenebilir"
assert_contains "$LOGD" "$lock_path" \
    "1) [KRİTİK] log satırı olayın YOLUNU içeriyor (sonradan kanıt)"
assert_contains "$LOGD" "$dom" \
    "1) [KRİTİK] log satırı HANGİ DOMAIN olduğunu içeriyor"

# Hedef dosyaya DOKUNULMADIĞI (privesc testinin özü) burada da bir kez daha
# doğrulanır — görünürlük düzeltmesi savunmayı BOZMAMIŞ olmalı.
assert_eq "$(cat "$victim")" "# ROOT-ONLY-ICERIK" \
    "1) görünürlük düzeltmesi savunmayı BOZMADI: hedef içeriği DEĞİŞMEDİ"

# Ölçülen semptomun DİĞER yarısı: stdout BOŞ. Bu, bir HATA değil TASARIM
# (warn/error stderr'e gider — CLAUDE.md 'stderr routing' kararı). Test bunu
# KİLİTLER ki gelecekte biri 'stdout boştu, oraya da basalım' diye
# _deploy_prune'un stdout sözleşmesini bozmasın; asıl telafi LOG'dur.
assert_eq "$OUT" "" \
    "1) stdout BİLEREK boş (warn/error stderr sözleşmesi) — telafi LOG tarafında"

# ═══════════════════════════════════════════════════════════════════════
# 1b) DEPLOY — kilit DİZİNİ sembolik bağ (aynı sözleşme, farklı katman)
# ═══════════════════════════════════════════════════════════════════════
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks"
mkdir -p "${SRVCTL_LOCK_DIR}/locks" "${WEB_ROOT}/sahte-kilit-dizini"
ln -s "${WEB_ROOT}/sahte-kilit-dizini" "$lock_dir"

run_measured _deploy_lock "$dom"

assert_eq "$([[ "$RC" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "1b) kilit DİZİNİ sembolik bağ → fail-closed"
assert_contains "$ERR" "SEMBOLİK BAĞ" \
    "1b) [SESSİZLİK KAPISI] dizin katmanında da stderr'de mesaj VAR"
assert_contains "$LOGD" "GÜVENLİK" \
    "1b) [KRİTİK] dizin katmanında da log izi VAR"

# ═══════════════════════════════════════════════════════════════════════
# 2) CRON ADD — AYNI kilit ağacı, AYNI sessizlik riski
# ═══════════════════════════════════════════════════════════════════════
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks"
mkdir -p "$lock_dir"
rm -f -- "$lock_path"
ln -s "$victim" "$lock_path"

run_measured _cron_add "$dom" --name=gorunurluk --schedule="her gün 03:00" \
    --command="echo test"

assert_eq "$([[ "$RC" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "2) cron add FAIL-CLOSED (rc != 0)"
assert_contains "$ERR" "SEMBOLİK BAĞ" \
    "2) [SESSİZLİK KAPISI] cron add stderr'inde TANINABİLİR ret mesajı VAR"
assert_contains "$ERR" "srvctl domain repair ${dom}" \
    "2) [SESSİZLİK KAPISI] cron add NE YAPILACAĞINI yazıyor"
assert_contains "$LOGD" "GÜVENLİK" \
    "2) [KRİTİK] cron add reddi srvctl loguna iz bıraktı"
assert_eq "$(ex_unit() { [[ -e "$1" ]] && echo var || echo yok; }; ex_unit "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-gorunurluk.service")" "yok" \
    "2) fail-closed GERÇEK: geriye YARIM bir unit dosyası KALMADI"

# ═══════════════════════════════════════════════════════════════════════
# 3) DOMAIN REPAIR — onarım yolu da SESSİZ OLMAMALI
# ═══════════════════════════════════════════════════════════════════════
rm -rf -- "${SRVCTL_LOCK_DIR:?}/locks"
mkdir -p "$lock_dir"
rm -f -- "$lock_path"
ln -s "$victim" "$lock_path"

run_measured _domain_repair_lock_dir "$dom" "$sname" "$web_user"

assert_eq "$RC" "0" \
    "3) repair sembolik bağ bulunca da BAŞARIYLA tamamlanıyor (onarım işi budur)"
assert_contains "$ERR" "SEMBOLİK BAĞ" \
    "3) [SESSİZLİK KAPISI] repair AKTİF SALDIRIYI stderr'e bildiriyor"
assert_contains "$LOGD" "GÜVENLİK" \
    "3) [KRİTİK] repair bulgusu srvctl loguna iz bıraktı (sessiz düzeltme YOK)"
assert_contains "$LOGD" "$victim" \
    "3) [KRİTİK] log satırı bağın HEDEFİNİ içeriyor"
assert_eq "$(test -L "$lock_path" && echo BAG || echo DEGIL)" "DEGIL" \
    "3) repair bağı KALDIRDI"
assert_eq "$(cat "$victim")" "# ROOT-ONLY-ICERIK" \
    "3) bağın HEDEFİ SİLİNMEDİ/DEĞİŞMEDİ"

# ═══════════════════════════════════════════════════════════════════════
# 4) log_action'ın KENDİSİ — yan etki asla akışı düşürmemeli
# ═══════════════════════════════════════════════════════════════════════
# GEREKÇE: log_action artık güvenlik yolunun İÇİNDEN (secure_file/secure_dir
# → _reject_symlink) çağrılıyor. Yazılamayan bir log dizini, ASIL komutu
# öldürmemeli VE stderr'i ham 'mkdir: Permission denied' ile kirletmemeli.
la_err=$(SRVCTL_LOG="/kesinlikle/olmayan/dizin/srvctl.log" \
    bash -c 'source "$1"; log_action "deneme"; echo "DEVAM"' _ "${REPO_ROOT}/lib/core.sh" 2>&1)
la_rc=$?
assert_eq "$la_rc" "0" \
    "4) log yazılamadığında log_action akışı DÜŞÜRMÜYOR (errexit tuzağı kapalı)"
assert_contains "$la_err" "DEVAM" \
    "4) log yazılamadığında bile çağıran DEVAM ediyor"
assert_not_contains "$la_err" "Permission denied" \
    "4) log yazılamadığında ham 'Permission denied' gürültüsü stderr'e SIZMIYOR"

# ═══════════════════════════════════════════════════════════════════════
# 5) SAF SÖZLEŞME — security_event / security_error
# ═══════════════════════════════════════════════════════════════════════
: > "$SRVCTL_LOG"
se_err=$(security_event "deneme olayi" 2>&1)
se_rc=$?
assert_eq "$se_rc" "0" \
    "5) security_event 0 döner (akış devam eder — 'warn' semantiği)"
assert_contains "$se_err" "deneme olayi" \
    "5) security_event mesajı stderr'e yazıyor"
assert_contains "$(cat "$SRVCTL_LOG")" "GÜVENLİK OLAYI: deneme olayi" \
    "5) security_event mesajı loga 'GÜVENLİK OLAYI' önekiyle yazıyor"

: > "$SRVCTL_LOG"
serr_out=$( ( security_error "olumcul olay" ) 2>&1 ) && serr_rc=0 || serr_rc=$?
assert_eq "$([[ "$serr_rc" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "5) security_error ÇIKAR (error semantiği — akış durur)"
assert_contains "$serr_out" "olumcul olay" \
    "5) security_error mesajı stderr'e yazıyor"
assert_contains "$(cat "$SRVCTL_LOG")" "GÜVENLİK REDDİ: olumcul olay" \
    "5) security_error mesajı loga 'GÜVENLİK REDDİ' önekiyle yazıyor (exit'ten ÖNCE)"

rm -rf "$WEB_ROOT" "$SRVCTL_LOCK_DIR" "$SRVCTL_STATE_DIR" "$SRVCTL_SYSTEMD_DIR" \
       "$SRVCTL_FPM_DIR" "$SRVCTL_PHP_POOL_DIR" "$FAKEBIN"
test_summary
