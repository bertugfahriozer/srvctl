#!/bin/bash
# lib/cron.sh — komut yüzeyi (cron add/list/show/remove) MUTASYON testi.
#
# tests/test_cron_schedule.sh saf zaman çeviricilerini izole test eder; bu
# dosya _cron_add()'in GERÇEK şablonları (templates/systemd/srvctl-cron*.tpl,
# srvctl-syscron*.tpl — AYRI görevde yazıldı) render_template İLE GERÇEKTEN
# render ettiğini, kaçış sözleşmesinin (tek tırnak + '%') UÇTAN UCA
# uygulandığını, OnFailure drop-in + fail-service çiftinin doğru
# üretildiğini ve isim doğrulamasının (path traversal) _cron_add ÇAĞRI
# ZİNCİRİNDE GERÇEKTEN uygulandığını (yalnız izole _cron_ident_ok testi
# DEĞİL) doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_LOCK_DIR="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
confirm() { return 0; }   # her onay isteğinde 'evet' say
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/cron.sh"

_run_isolated() { ( "$@" ); }
ex() { [[ -e "$1" ]] && echo var || echo yok; }

# ═══════════════════════════════════════════════════════════════
# systemd'nin GERÇEK ExecStart= tokenizer'ının (systemd.syntax(7)
# "Quoting" bölümü) MİNİMAL bir modeli — GERÇEK üretim sunucusunda ölçülen
# çift-kaçış hatasının test harness'inin KENDİSİ tarafından maskelendiği
# bir ÖNCEKİ turdan sonra ZORUNLU kılındı: "gerçek /bin/sh ile test ettim"
# denemesi, test harness'inin KENDİ ekstra 'sh -c "$satır"' katmanı YÜZÜNDEN
# yanlış-negatif vermişti (systemd ARA bir kabuk KULLANMAZ, KENDİ
# tokenizer'ıyla doğrudan argv üretir). Bu fonksiyon systemd'nin KENDİ
# davranışını taklit eder: ExecStart= değerini (specifier '%%' ikilemesi
# ÇÖZÜLMÜŞ hâliyle) boşluğa göre böler, tek/çift tırnağı TOGGLE eder, VE —
# POSIX kabuğun AKSİNE — ters-eğik-çizgiyi TEK TIRNAK İÇİNDE BİLE bir kaçış
# karakteri sayar (C-tarzı kaçış tablosunun bu testte gereken alt kümesi:
# '\\','\'',\",\\s,\\n,\\t,\\r — bkz. lib/cron.sh:_cron_escape_unit_squote
# yorumu). Sonuç, ARA bir kabuk KULLANILMADAN (namerefs 'local -n' macOS
# /bin/bash 3.2'de YOK — bkz. lib/deploy.sh:_deploy_php_parse_token
# yorumu) GLOBAL 'REPLY_ARGV' dizisine yazılır; çağıran bunu DOĞRUDAN
# "${REPLY_ARGV[@]}" olarak çalıştırabilir (execve benzeri, yeniden
# ayrıştırma YOK).
REPLY_ARGV=()
_systemd_split_execstart() {
    local val="$1"
    REPLY_ARGV=()
    local n=${#val} i=0 c nc
    local cur="" have_cur=0
    local in_squote=0 in_dquote=0
    while (( i < n )); do
        c="${val:i:1}"
        if [[ $in_squote -eq 0 && $in_dquote -eq 0 ]]; then
            if [[ "$c" == ' ' || "$c" == $'\t' ]]; then
                if (( have_cur )); then
                    REPLY_ARGV+=("$cur")
                    cur="" have_cur=0
                fi
                i=$((i+1))
                continue
            fi
        fi
        have_cur=1
        if [[ "$c" == '\' && $((i+1)) -lt $n ]]; then
            nc="${val:i+1:1}"
            case "$nc" in
                '\') cur+='\' ;;
                "'") cur+="'" ;;
                '"') cur+='"' ;;
                s) cur+=' ' ;;
                n) cur+=$'\n' ;;
                t) cur+=$'\t' ;;
                r) cur+=$'\r' ;;
                *) cur+="$nc" ;;
            esac
            i=$((i+2))
            continue
        fi
        if [[ "$c" == "'" && $in_dquote -eq 0 ]]; then
            if (( in_squote )); then in_squote=0; else in_squote=1; fi
            i=$((i+1))
            continue
        fi
        if [[ "$c" == '"' && $in_squote -eq 0 ]]; then
            if (( in_dquote )); then in_dquote=0; else in_dquote=1; fi
            i=$((i+1))
            continue
        fi
        cur+="$c"
        i=$((i+1))
    done
    if (( have_cur )); then
        REPLY_ARGV+=("$cur")
    fi
}

# Verilen .service dosyasından ExecStart= satırını okuyup GERÇEK systemd
# argv'sine ayırır (yukarıdaki tokenizer ile) — sonuç GLOBAL REPLY_ARGV'de.
_extract_execstart_argv() {
    local svc_file="$1" line val
    line=$(grep -m1 '^ExecStart=' "$svc_file" 2>/dev/null)
    val="${line#ExecStart=}"
    # systemd specifier '%%' ikilemesinin GERİ ALINMASI — ExecStart satırının
    # TAMAMINDA, tırnak/kaçış ayrıştırmasından BAĞIMSIZ bir ÖN adım (bkz.
    # lib/cron.sh dosya başı yorumu: '%' hiçbir kaçış üretmez/tüketmez).
    val="${val//%%/%}"
    _systemd_split_execstart "$val"
}

systemctl_log="${WEB_ROOT}/.systemctl.log"
: > "$systemctl_log"
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    return 0
}

FAKEBIN="$(mktemp -d)"
export PATH="${FAKEBIN}:${PATH}"

d="example.com"
sname=$(safe_name "$d")
mkdir -p "${WEB_ROOT}/${d}"
: > "${WEB_ROOT}/${d}/.credentials"

# ═══════════════════════════════════════════════════════════════
# 1) Domain-kapsamlı BAŞARILI ekleme — flock/systemd-analyze YOK (bu dev
#    kutusunda ikisi de doğal olarak bulunmuyor; fail-safe/graceful-degrade
#    yollarını GERÇEKTEN tetikler).
# ═══════════════════════════════════════════════════════════════
out1=$(_cron_add "$d" --name=cache_clear --schedule="her gün 03:00" \
    --command="echo \"it's 50% done\"" --description="Cache temizligi" --timeout=120 2>&1)
rc1=$?
assert_eq "$rc1" "0" "1) domain cron add BAŞARILI (exit 0)"

svc="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.service"
timer="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.timer"
assert_eq "$(ex "$svc")" "var" "1) .service dosyası oluşturuldu"
assert_eq "$(ex "$timer")" "var" "1) .timer dosyası oluşturuldu"

svc_content=$(cat "$svc" 2>/dev/null)
assert_not_contains "$svc_content" "{{" "1) .service içinde leftover token YOK"
assert_contains "$svc_content" "Description=srvctl Cron (${d} / cache_clear): Cache temizligi" "1) Description doğru render edildi"
assert_contains "$svc_content" "WorkingDirectory=${WEB_ROOT}/${d}/current" "1) WorkingDirectory = WEB_ROOT/<domain>/current"
assert_contains "$svc_content" "User=web_${sname}" "1) domain kullanıcısı olarak çalışıyor"
assert_contains "$svc_content" "TimeoutStartSec=120" "1) --timeout RUNTIME_MAX'a doğru geçti (TimeoutStartSec — oneshot'ta ETKİN olan yönerge, 90sn tuzağı bertaraf)"
# 'RuntimeMaxSec=' KALDIRILDI (üretim: systemd Type=oneshot ile yok sayıp
# HER çalıştırmada journal'a uyarı basıyordu). RUNTIME_MAX token'ı duruyor,
# yalnız TimeoutStartSec'i besliyor.
assert_eq "$(printf '%s\n' "$svc_content" | grep -c '^RuntimeMaxSec=')" "0" \
    "1) [REGRESYON KAPISI] render edilmiş unit'te AKTİF RuntimeMaxSec= satırı YOK"
# Kaçış sözleşmesi: tek tırnak + '%' AYNI ANDA içeren komut doğru kaçırıldı mı?
# Beklenen değer ELLE YAZILMAZ (kırılgan/hataya açık) — _cron_add'in KENDİ
# kullandığı GERÇEK fonksiyonlarla (test_cron_schedule.sh'taki uçtan uca
# testle AYNI mantık) hesaplanır.
expected_execstart="ExecStart=/bin/sh -c '$(_cron_escape_percent "$(_cron_escape_unit_squote 'echo "it'"'"'s 50% done"')")'"
assert_contains "$svc_content" "$expected_execstart" \
    "1) ExecStart: tek tırnak + '%' ikilemesi UÇTAN UCA doğru kaçırıldı"

timer_content=$(cat "$timer" 2>/dev/null)
assert_not_contains "$timer_content" "{{" "1) .timer içinde leftover token YOK"
assert_contains "$timer_content" "OnCalendar=*-*-* 03:00:00" "1) OnCalendar Türkçe kısayoldan doğru hesaplandı"
# ZAMAN DİLİMİ VARSAYILANI DEĞİŞTİ (GERÇEK üretim ölçümü, Europe/Istanbul/+03:
# 'her gün 04:00' → unit'te '04:00:00 UTC' → systemd 07:00'de ateşliyordu).
# Artık sonek YOK: systemd soneksiz OnCalendar'ı SİSTEM YEREL saatinde
# yorumlar — yazdığın saat, çalışan saattir.
assert_not_contains "$timer_content" "OnCalendar=*-*-* 03:00:00 UTC" \
    "1) VARSAYILAN: OnCalendar'da ' UTC' soneki YOK (sunucu yerel saati)"
assert_contains "$timer_content" "RandomizedDelaySec=${CRON_DEFAULT_RANDOMIZED_DELAY}" "1) RandomizedDelaySec varsayılanı uygulandı"
assert_contains "$timer_content" "Unit=srvctl-cron-${sname}-cache_clear.service" "1) timer doğru .service'e bağlanıyor"

dropin="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-cache_clear.service.d/override.conf"
assert_eq "$(ex "$dropin")" "var" "1) OnFailure drop-in dosyası oluşturuldu"
assert_contains "$(cat "$dropin" 2>/dev/null)" "OnFailure=srvctl-cronfail-${sname}-cache_clear.service" \
    "1) drop-in doğru fail-service'e işaret ediyor"

failsvc="${SRVCTL_SYSTEMD_DIR}/srvctl-cronfail-${sname}-cache_clear.service"
assert_eq "$(ex "$failsvc")" "var" "1) fail-service dosyası oluşturuldu"
assert_contains "$(cat "$failsvc" 2>/dev/null)" "cron _on-failure ${d} cache_clear" \
    "1) fail-service doğru argümanlarla '_on-failure'ı çağırıyor"

sidecar="${SRVCTL_STATE_DIR}/_cron/${sname}/cache_clear.conf"
assert_eq "$(ex "$sidecar")" "var" "1) sidecar (ham girdi) dosyası oluşturuldu"
assert_contains "$(cat "$sidecar" 2>/dev/null)" "SCHEDULE_RAW=her gün 03:00" \
    "1) sidecar orijinal Türkçe girdiyi SAKLIYOR (systemd'den geri çevrilemeyen tek bilgi)"

assert_contains "$(cat "$systemctl_log")" "daemon-reload" "1) systemctl daemon-reload çağrıldı"
assert_contains "$(cat "$systemctl_log")" "enable --now srvctl-cron-${sname}-cache_clear.timer" \
    "1) timer enable --now ile etkinleştirildi"

assert_contains "$out1" "flock bulunamadı" \
    "1) flock YOKKEN operatör AÇIKÇA uyarılıyor (deploy kilidi korumasız)"
assert_contains "$out1" "systemd-analyze bulunamadı" \
    "1) systemd-analyze YOKKEN fail-safe uyarısı basılıyor (sessizce geçilmiyor)"
assert_contains "$timer_content" "Persistent=false" \
    "1) --catch-up-on-boot VERİLMEDEN varsayılan Persistent=false (crontab-parity)"

# ═══════════════════════════════════════════════════════════════
# 1b) --catch-up-on-boot VERİLİRSE Persistent=true olmalı (CRON_PERSISTENT
#     per-job token — koordinatör geri bildirimiyle SABİT değerden per-job'a
#     dönüştürüldü, bkz. srvctl-cron.timer.tpl başlık yorumu).
# ═══════════════════════════════════════════════════════════════
_cron_add "$d" --name=nightly_dump --schedule="her gün 04:00" \
    --command="echo yedek" --catch-up-on-boot >/dev/null 2>&1
catchup_timer_content=$(cat "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-nightly_dump.timer" 2>/dev/null)
assert_contains "$catchup_timer_content" "Persistent=true" \
    "1b) --catch-up-on-boot VERİLİNCE Persistent=true"
_cron_remove "$d" nightly_dump >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════
# 2) Path traversal denemesi — İSİM DOĞRULAMASI _cron_add ÇAĞRI ZİNCİRİNDE
#    GERÇEKTEN uygulanıyor mu? (koordinatör: "ZORUNLU", ayrıca vurgulandı)
# ═══════════════════════════════════════════════════════════════
: > "$systemctl_log"
assert_fail _run_isolated _cron_add "$d" --name="../../etc/systemd/system/evil" \
    --schedule="her gün 03:00" --command="echo hi" \
    "2) '../../etc/...' adı _cron_add TARAFINDAN REDDEDİLİYOR (path traversal)"
assert_eq "$(cat "$systemctl_log")" "" "2) reddedilen istekte HİÇBİR systemctl çağrısı yapılmadı (render'a hiç gidilmedi)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-evil.service")" "yok" \
    "2) traversal denemesi sonrası sysd_dir İÇİNDE beklenmedik bir dosya OLUŞMADI"
# Traversal'ın GERÇEK hedefi (sysd_dir DIŞI) da kirlenmemiş olmalı.
assert_eq "$(ex "/etc/systemd/system/evil.service")" "yok" \
    "2) traversal denemesi GERÇEKTEN sysd_dir dışına YAZMADI"

# ═══════════════════════════════════════════════════════════════
# 3) Olmayan domain REDDEDİLİR
# ═══════════════════════════════════════════════════════════════
assert_fail _run_isolated _cron_add "olmayan-domain.test" --name=x \
    --schedule="her saat" --command="echo hi" \
    "3) olmayan domain REDDEDİLİYOR"

# ═══════════════════════════════════════════════════════════════
# 4) İsim çakışması — AYNI isimle ikinci 'add' REDDEDİLİR (idempotency guard)
# ═══════════════════════════════════════════════════════════════
assert_fail _run_isolated _cron_add "$d" --name=cache_clear \
    --schedule="her saat" --command="echo baska" \
    "4) AYNI isimle ikinci 'cron add' REDDEDİLİYOR (önce 'remove' gerekir)"

# ═══════════════════════════════════════════════════════════════
# 5) Sistem kapsamlı ekleme — flock sarmalaması OLMAMALI, WEB_USER/
#    WorkingDirectory token'ları YOK (syscron TOKENS kontratı zaten bunları
#    içermiyor).
# ═══════════════════════════════════════════════════════════════
: > "$systemctl_log"
_cron_add --system --name=nightly_backup --schedule="0 2 * * *" \
    --command="/usr/local/bin/backup.sh --full" --timeout=3600 >/dev/null 2>&1
rc5=$?
assert_eq "$rc5" "0" "5) sistem cron add BAŞARILI (exit 0)"

sys_svc="${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-nightly_backup.service"
sys_timer="${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-nightly_backup.timer"
assert_eq "$(ex "$sys_svc")" "var" "5) sistem .service oluşturuldu"
sys_content=$(cat "$sys_svc" 2>/dev/null)
assert_not_contains "$sys_content" "{{" "5) sistem .service içinde leftover token YOK"
assert_contains "$sys_content" "ExecStart=/bin/sh -c '/usr/local/bin/backup.sh --full'" \
    "5) sistem cron: flock SARMALAMASI YOK (domain'e özgü, sistem cron'da anlamsız)"
# Satır-başı çapalı arama: şablon 'User= BELİRTİLMEZ' gibi AÇIKLAYICI yorum
# satırlarında KASITLI olarak literal 'User=' metnini içerir (bkz.
# srvctl-syscron.service.tpl) — düz assert_not_contains bu yorumu YANLIŞ
# POZİTİF sayardı; yalnız satır BAŞINDAKİ AKTİF yönerge aranır (bkz.
# tests/test_cron_systemd_templates.sh:_has_active_directive İLE AYNI desen).
if printf '%s\n' "$sys_content" | grep -Eq '^User='; then user_active="evet"; else user_active="hayir"; fi
assert_eq "$user_active" "hayir" "5) sistem cron: AKTİF 'User=' satırı YOK (systemd varsayılanı root)"

sys_timer_content=$(cat "$sys_timer" 2>/dev/null)
assert_contains "$sys_timer_content" "OnCalendar=*-*-* 02:00:00" \
    "5) sistem cron: standart cron sözdizimi ('0 2 * * *') doğru çevrildi"
assert_not_contains "$sys_timer_content" "OnCalendar=*-*-* 02:00:00 UTC" \
    "5) sistem cron da VARSAYILAN olarak sunucu yerel saatinde (' UTC' soneki YOK)"

sys_fail="${SRVCTL_SYSTEMD_DIR}/srvctl-syscronfail-nightly_backup.service"
assert_eq "$(ex "$sys_fail")" "var" "5) sistem fail-service oluşturuldu"
assert_contains "$(cat "$sys_fail" 2>/dev/null)" "cron _on-failure --system nightly_backup" \
    "5) sistem fail-service doğru argümanlarla çağırıyor"

# ═══════════════════════════════════════════════════════════════
# 6) PHP sürüm uyarısı — 'php' ile (sürüm eki OLMADAN) başlayan komut
#    domain kapsamında UYARILIR (engellenmez).
# ═══════════════════════════════════════════════════════════════
: > "$systemctl_log"
out6=$(_cron_add "$d" --name=artisan_sched --schedule="her saat" --command="php artisan schedule:run" 2>&1)
assert_contains "$out6" "VARSAYILAN php ikili dosyasını kullanır" \
    "6) bare 'php' komutu domain kapsamında AÇIKÇA uyarılıyor (host'un varsayılan PHP'si riski)"

# ═══════════════════════════════════════════════════════════════
# 7) flock MEVCUTKEN — deploy kilidi sarmalaması ExecStart'a GERÇEKTEN giriyor mu?
# ═══════════════════════════════════════════════════════════════
cat > "${FAKEBIN}/flock" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${FAKEBIN}/flock"

: > "$systemctl_log"
out7=$(_cron_add "$d" --name=locked_job --schedule="her saat" --command="echo calisti" 2>&1)
rc7=$?
assert_eq "$rc7" "0" "7) flock VARKEN add yine BAŞARILI"
locked_svc="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-locked_job.service"
locked_content=$(cat "$locked_svc" 2>/dev/null)
assert_contains "$locked_content" "flock -n -E 75" \
    "7) flock VARKEN ExecStart deploy-kilidi sarmalamasını İÇERİYOR (-E 75 sentinel)"
assert_contains "$locked_content" "locks/${sname}/deploy-${sname}.lock" \
    "7) kilit dosyası deploy.sh:_deploy_lock İLE AYNI (domain'e özel alt dizinli) yolu kullanıyor"

# DAC/root çelişkisi düzeltmesi (görev): kilit dizin AĞACI GERÇEKTEN
# oluşturuldu mu ve mod bitleri BEKLENEN (711/711/710) mi? Domain'e özel
# alt dizin cron'un çalıştığı web_<sname> kullanıcısına GİRİLEBİLİR
# olmalı, üst dizinler İSE yalnız GEÇİŞE izin vermeli (711).
#
# ⚠ 700 → 710 (KRİTİK GÜVENLİK DÜZELTMESİ): alt dizin ESKİDEN '700
# web_<sname>:web_<sname>' idi — SAHİBİ domain kullanıcısı olduğundan o
# kullanıcı kilit dosyasını UNLINK edip yerine sembolik bağ koyabiliyordu
# ve root olarak çalışan deploy bunu dereference edip KEYFİ bir dosyayı
# chown/truncate ediyordu (canlı üretimde SÖMÜRÜLDÜ). Yeni model '710
# root:web_<sname>': grup 'x' ile GEÇİŞ VAR, 'w' YOK. Sahiplik
# test_deploy_lock_isolation.sh'ta chown-stub İLE ayrıca doğrulanır.
assert_eq "$(_stat_mode "${SRVCTL_LOCK_DIR}" | tail -c 4)" "711" \
    "7) kilit ANA dizini 711 (geçiş serbest, listeleme YOK)"
assert_eq "$(_stat_mode "${SRVCTL_LOCK_DIR}/locks" | tail -c 4)" "711" \
    "7) kilit 'locks' ara dizini 711"
assert_eq "$(_stat_mode "${SRVCTL_LOCK_DIR}/locks/${sname}" | tail -c 4)" "710" \
    "7) domain'e ÖZEL kilit alt dizini 710 root:web_<sname> (geçiş VAR, YAZMA YOK — symlink primitifi kapalı)"
assert_eq "$(test -f "${SRVCTL_LOCK_DIR}/locks/${sname}/deploy-${sname}.lock" && echo VAR || echo YOK)" "VAR" \
    "7) kilit DOSYASI 'cron add' sırasında ROOT tarafından ÖN-OLUŞTURULDU (flock(1) O_CREAT'ı artık dizinde 'w' olmadığından işe yaramaz)"
assert_eq "$(_stat_mode "${SRVCTL_LOCK_DIR}/locks/${sname}/deploy-${sname}.lock" | tail -c 4)" "660" \
    "7) kilit dosyası 660 (grup=web_<sname> okuyabilir — flock(1) O_RDONLY ile açar)"
assert_contains "$out7" "Deploy kilidi entegrasyonu aktif" \
    "7) flock VARKEN operatöre entegrasyon AÇIKÇA bildiriliyor"

# ═══════════════════════════════════════════════════════════════
# 7b) AppArmor ÖN-KONTROLÜ (KOORDİNATÖR HOST BULGUSU — İKİ KATMAN: (1)
#     GERÇEK Ubuntu 24.04 VM'de flock EXEC izni OLMADIĞI için 126 ile
#     REDDEDİLİYORDU; (2) bu düzeltildikten SONRA ölçüldü — flock çalışıyor
#     ama kilit DOSYASINI ('/run/srvctl/locks/<sname>/deploy-<sname>.lock')
#     AppArmor yüzünden açamıyordu, DAC sorunsuzdu. 'cron add' artık canlı
#     profili okuyup İKİ katmanı da TEK kontrolde tespit ediyor mu?
# ═══════════════════════════════════════════════════════════════
export SRVCTL_APPARMOR_DIR="$(mktemp -d)"

# (i) ESKİ (flock'suz) profil — tam olarak koordinatörün İLK ölçtüğü
# kümeyle (php/dash/sh) — UYARI basılmalı.
cat > "${SRVCTL_APPARMOR_DIR}/srvctl-${sname}-cli" <<EOF
profile srvctl-${sname}-cli flags=(attach_disconnected) {
  /usr/bin/php8.4 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
}
EOF
out7b=$(_cron_add "$d" --name=stale_aa_job --schedule="her saat" --command="echo x" 2>&1)
assert_contains "$out7b" "AppArmor profili GÜNCEL DEĞİL" \
    "7b) ESKİ (flock'suz) canlı AppArmor profili tespit edilip UYARILIYOR"
assert_contains "$out7b" "srvctl domain repair ${d}" \
    "7b) uyarı, düzeltme için somut komutu ('srvctl domain repair') İÇERİYOR"
_cron_remove "$d" stale_aa_job >/dev/null 2>&1

# (i-b) YARIM düzeltilmiş profil — koordinatörün İKİNCİ ölçtüğü durum:
# flock EXEC izni VAR ama kilit DOSYASI kuralı YOK — UYARI YİNE basılmalı
# (tek kontrol, iki katmanı da kapsıyor mu?).
cat > "${SRVCTL_APPARMOR_DIR}/srvctl-${sname}-cli" <<EOF
profile srvctl-${sname}-cli flags=(attach_disconnected) {
  /usr/bin/php8.4 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
}
EOF
out7bb=$(_cron_add "$d" --name=half_fixed_job --schedule="her saat" --command="echo x" 2>&1)
assert_contains "$out7bb" "AppArmor profili GÜNCEL DEĞİL" \
    "7b-ikinci-katman) flock EXEC VAR ama kilit dosyası kuralı YOKSA UYARI YİNE basılıyor (2. HOST bulgusu kapsanıyor)"
_cron_remove "$d" half_fixed_job >/dev/null 2>&1

# (i-c) ESKİ (göç ÖNCESİ, DAC/root çelişkisi düzeltmesinden ÖNCEKİ) düz
# yol kuralı — 'flock rix' VE bir kilit satırı VAR ama YOL FORMATI eski
# ('/run/srvctl/deploy-<sname>.lock', 'locks/<sname>/' alt dizini YOK).
# Göç sonrası bu ARTIK GÜNCEL DEĞİL sayılmalı (sessizce 'tam' kabul
# edilirse operatör 'srvctl domain repair' çalıştırmaz ve cron GERÇEK
# üretimde AYNI DAC hatasıyla düşmeye devam eder).
cat > "${SRVCTL_APPARMOR_DIR}/srvctl-${sname}-cli" <<EOF
profile srvctl-${sname}-cli flags=(attach_disconnected) {
  /usr/bin/php8.4 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
  /run/srvctl/deploy-${sname}.lock rwk,
}
EOF
out7bc=$(_cron_add "$d" --name=premigration_job --schedule="her saat" --command="echo x" 2>&1)
assert_contains "$out7bc" "AppArmor profili GÜNCEL DEĞİL" \
    "7b-üçüncü-katman) göç ÖNCESİ düz yol kuralı ARTIK GÜNCEL DEĞİL sayılıyor (yeni 'locks/<sname>/' yolu bekleniyor)"
_cron_remove "$d" premigration_job >/dev/null 2>&1

# (ii) TAM GÜNCEL profil (flock rix, HEM YENİ domain'e özel alt dizinli
# deploy kilidi rwk, satırı — 'srvctl domain repair' sonrası beklenen
# NİHAİ durum) — UYARI basılMAMALI.
cat > "${SRVCTL_APPARMOR_DIR}/srvctl-${sname}-cli" <<EOF
profile srvctl-${sname}-cli flags=(attach_disconnected) {
  /usr/bin/php8.4 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
  /run/srvctl/locks/${sname}/deploy-${sname}.lock rwk,
}
EOF
out7c=$(_cron_add "$d" --name=fresh_aa_job --schedule="her saat" --command="echo x" 2>&1)
assert_not_contains "$out7c" "AppArmor profili GÜNCEL DEĞİL" \
    "7c) TAM GÜNCEL (flock + YENİ yollu kilit dosyası İKİSİ DE VAR) profilde UYARI basılMIYOR (yanlış pozitif yok)"
_cron_remove "$d" fresh_aa_job >/dev/null 2>&1

# (iii) Profil hiç YOKSA (ör. domain henüz hardened değil) — SESSİZCE
# geçilmeli, UYARI basılMAMALI (missing ≠ tamper/eksik — core.sh'taki AYNI
# ayrım ilkesi, bkz. _cron_apparmor_flock_ok yorumu).
rm -f "${SRVCTL_APPARMOR_DIR}/srvctl-${sname}-cli"
out7d=$(_cron_add "$d" --name=nohardening_job --schedule="her saat" --command="echo x" 2>&1)
assert_not_contains "$out7d" "AppArmor profili GÜNCEL DEĞİL" \
    "7d) profil HİÇ YOKSA sessizce geçilir, UYARI basılMIYOR (yanlış alarm yok)"
_cron_remove "$d" nohardening_job >/dev/null 2>&1

unset SRVCTL_APPARMOR_DIR
rm -f "${FAKEBIN}/flock"

# ═══════════════════════════════════════════════════════════════
# 8) systemd-analyze GEÇERSİZ bulursa — cron EKLENMEMELİ (fail-closed)
# ═══════════════════════════════════════════════════════════════
cat > "${FAKEBIN}/systemd-analyze" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "${FAKEBIN}/systemd-analyze"

: > "$systemctl_log"
assert_fail _run_isolated _cron_add "$d" --name=rejected_job --schedule="her saat" --command="echo x" \
    "8) systemd-analyze GEÇERSİZ derse cron REDDEDİLİYOR (fail-closed)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-rejected_job.service")" "yok" \
    "8) reddedilen zamanlama için dosya OLUŞTURULMADI"
rm -f "${FAKEBIN}/systemd-analyze"

# ═══════════════════════════════════════════════════════════════
# 9) cron list / cron show — çökmeden çalışıyor, temel alanları gösteriyor
#    (systemctl stub'u boş çıktı verdiğinden canlı alanlar 'bilinmiyor'
#    gösterilmeli — UYDURMA YOK).
# ═══════════════════════════════════════════════════════════════
list_out=$(_cron_list "$d" 2>&1)
assert_contains "$list_out" "cache_clear" "9) 'cron list <domain>' eklenen cron'u gösteriyor"
# Görev sözleşmesi ('cron list' alanları): ad, açıklama, zaman, son çalışma,
# sonraki çalışma, son çıkış kodu, etkin/devre dışı — HEPSİ mevcut olmalı.
assert_contains "$list_out" "Cache temizligi" "9) 'cron list' AÇIKLAMAYI gösteriyor"
assert_contains "$list_out" "her gün 03:00" "9) 'cron list' ZAMANI (insan okunur, orijinal girdi) gösteriyor"
assert_contains "$list_out" "Son çalışma" "9) 'cron list' SON ÇALIŞMA alanını gösteriyor"
assert_contains "$list_out" "Sonraki çalışma" "9) 'cron list' SONRAKİ ÇALIŞMA alanını gösteriyor"
assert_contains "$list_out" "Son çıkış kodu" "9) 'cron list' SON ÇIKIŞ KODU alanını gösteriyor"
assert_contains "$list_out" "bilinmiyor" "9) 'cron list': systemctl'den okunamayan canlı alanlar UYDURULMUYOR, 'bilinmiyor' gösteriliyor"

show_out=$(_cron_show "$d" cache_clear 2>&1)
assert_contains "$show_out" "Cache temizligi" "9) 'cron show' açıklamayı GERÇEK unit dosyasından okuyor"
assert_contains "$show_out" "her gün 03:00" "9) 'cron show' orijinal girilen zamanlamayı sidecar'dan gösteriyor"
assert_contains "$show_out" "OnCalendar       : *-*-* 03:00:00" "9) 'cron show' hesaplanmış OnCalendar'ı gösteriyor"
assert_contains "$show_out" "telafi edilmez" "9) 'cron show' catch-up-on-boot DAVRANIŞINI (varsayılan: telafi edilmez) AÇIKÇA gösteriyor"
assert_contains "$show_out" "bilinmiyor" "9) 'cron show': systemctl'den okunamayan canlı alanlar UYDURULMUYOR, 'bilinmiyor' gösteriliyor"

# ═══════════════════════════════════════════════════════════════
# 10) cron remove — tüm üretilen dosyalar (service/timer/drop-in/fail/sidecar)
#     GERÇEKTEN kaldırılıyor.
# ═══════════════════════════════════════════════════════════════
_cron_remove "$d" cache_clear >/dev/null 2>&1
assert_eq "$(ex "$svc")" "yok" "10) remove: .service silindi"
assert_eq "$(ex "$timer")" "yok" "10) remove: .timer silindi"
assert_eq "$(ex "$dropin")" "yok" "10) remove: OnFailure drop-in silindi"
assert_eq "$(ex "$failsvc")" "yok" "10) remove: fail-service silindi"
assert_eq "$(ex "$sidecar")" "yok" "10) remove: sidecar dosyası silindi"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR" "$SRVCTL_LOCK_DIR" "$FAKEBIN"
test_summary
