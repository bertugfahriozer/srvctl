#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  lib/cron.sh — GÜVENLİK DENETİMİ BULGULARI (O-2 / O-3 / O-4 + yan-birim)
# ═══════════════════════════════════════════════════════════════════════
#
# Kapsam:
#   O-2  Unit/timer/drop-in/yan-birim/sidecar dosyaları 640 root:root
#        (üretimde 644 = WORLD-READABLE ölçüldü) + komutta düz metin parola
#        tespiti (argv sızıntısı — /proc/<pid>/cmdline).
#   O-3  Yaz saati (DST): yerel saate bağlanmış SABİT saatli işlerde uyarı;
#        DST'siz dilimde (Türkiye) YANLIŞ ALARM YOK. Görüntülemede anlık
#        ofsete dayanan karşılıkların "YAKLAŞIK" diye etiketlenmesi.
#   O-4  'name' doğrulaması add DIŞINDAKİ ALTI giriş noktasında da var mı —
#        özellikle 'rm -rf' içeren _cron_remove'da. Yol geçişinin GERÇEKTEN
#        mümkün olduğu (varlık kapısının tesadüfen kurtardığı) bir kurulum
#        elle inşa edilip doğrulamanın YÜK TAŞIDIĞI kanıtlanır.
#   Ek   'cronfail' yan-birimi sertleştirmesi (savunma derinliği/tutarlılık).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_LOCK_DIR="$(mktemp -d)"
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
source "${REPO_ROOT}/lib/cron.sh"

ex() { [[ -e "$1" ]] && echo var || echo yok; }
mode3() { _stat_mode "$1" 2>/dev/null | tail -c 4; }

d="example.com"
sname=$(safe_name "$d")
mkdir -p "${WEB_ROOT}/${d}"

# ═══════════════════════════════════════════════════════════════════════
# 1) O-2 — UNIT DOSYASI İZİNLERİ (üretimde 644 ölçüldü, 640 olmalı)
# ═══════════════════════════════════════════════════════════════════════
# umask'ı BİLEREK gevşek bırakıyoruz: kusurun kök nedeni tam olarak root'un
# 022 umask'ıyla '> "$svc_file"' yönlendirmesiydi. secure_file bunu telafi
# ETMEZSE test FAIL verir.
umask 022

_cron_add "$d" --name=perm_test --schedule="her gün 03:00" \
    --command="php artisan cache:clear" --timeout=120 >/dev/null 2>&1
assert_eq "$?" "0" "1) izin testi için cron eklendi"

svc="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-perm_test.service"
timer="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-perm_test.timer"
dropin="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-perm_test.service.d/override.conf"
failsvc="${SRVCTL_SYSTEMD_DIR}/srvctl-cronfail-${sname}-perm_test.service"
sidecar="${SRVCTL_STATE_DIR}/_cron/${sname}/perm_test.conf"

assert_eq "$(ex "$svc")"     "var" "1) .service yazıldı"
assert_eq "$(ex "$timer")"   "var" "1) .timer yazıldı"
assert_eq "$(ex "$dropin")"  "var" "1) OnFailure drop-in yazıldı"
assert_eq "$(ex "$failsvc")" "var" "1) cronfail yan-birimi yazıldı"
assert_eq "$(ex "$sidecar")" "var" "1) sidecar yazıldı"

assert_eq "$(mode3 "$svc")"     "640" "1) [O-2] .service 640 (üretimde 644 ÖLÇÜLDÜ — world-readable)"
assert_eq "$(mode3 "$timer")"   "640" "1) [O-2] .timer 640"
assert_eq "$(mode3 "$dropin")"  "640" "1) [O-2] drop-in override.conf 640"
assert_eq "$(mode3 "$failsvc")" "640" "1) [O-2] cronfail yan-birimi 640"
assert_eq "$(mode3 "$sidecar")" "640" "1) [O-2] sidecar 640"

# 'diğer' (other) bitleri KESİNLİKLE kapalı olmalı — asıl güvenlik iddiası
# budur (mod dizgesinin son hanesi 0).
for f in "$svc" "$timer" "$dropin" "$failsvc" "$sidecar"; do
    m=$(mode3 "$f")
    assert_eq "${m:2:1}" "0" "1) [KRİTİK] '$(basename "$f")' için 'diğer' izin bitleri TAMAMEN kapalı"
done

# systemd birim DİZİNİNE DOKUNULMAMALI: gerçek hedef '/etc/systemd/system'dir
# ve 755 olmalıdır. secure_dir ile sertleştirilseydi 700'e düşerdi. Ölçüm
# ÖNCE/SONRA karşılaştırmasıyla yapılır (mktemp -d zaten 700 üretir, bu
# yüzden mutlak bir mod iddiası YANILTICI olurdu).
chmod 755 "${SRVCTL_SYSTEMD_DIR}"
dir_mode_before=$(mode3 "${SRVCTL_SYSTEMD_DIR}")
_cron_add "$d" --name=dir_mode --schedule="her gün 05:00" --command="echo x" >/dev/null 2>&1
assert_eq "$(mode3 "${SRVCTL_SYSTEMD_DIR}")" "$dir_mode_before" \
    "1) unit DİZİNİNİN modu DEĞİŞTİRİLMEDİ (755 korunur — /etc/systemd/system daraltılmamalı)"

# ═══════════════════════════════════════════════════════════════════════
# 2) Ek — 'cronfail' yan-birimi SERTLEŞTİRİLDİ
# ═══════════════════════════════════════════════════════════════════════
fail_content=$(cat "$failsvc")
assert_contains "$fail_content" "NoNewPrivileges=true"  "2) cronfail: NoNewPrivileges"
assert_contains "$fail_content" "ProtectSystem=strict"  "2) cronfail: ProtectSystem=strict"
assert_contains "$fail_content" "ProtectHome=yes"       "2) cronfail: ProtectHome"
assert_contains "$fail_content" "PrivateTmp=yes"        "2) cronfail: PrivateTmp"
assert_contains "$fail_content" "RestrictSUIDSGID=true" "2) cronfail: RestrictSUIDSGID"
# ProtectSystem=strict altında srvctl'in KENDİ log dizini yazılabilir
# kalmalı — yoksa '_on-failure'ın log_action'ı EROFS ile sessizce düşerdi
# (bu oturumda avladığımız hata sınıfının ta kendisi).
assert_contains "$fail_content" "ReadWritePaths=-${SRVCTL_ROOT}/logs" \
    "2) [KRİTİK] cronfail: srvctl log dizini ReadWritePaths'te (aksi halde bildirim kaydı EROFS ile düşerdi)"

# ═══════════════════════════════════════════════════════════════════════
# 3) O-2 (ikinci yarı) — KOMUTTA DÜZ METİN PAROLA: karar tablosu (SAF)
# ═══════════════════════════════════════════════════════════════════════
p_yes() { _cron_command_has_inline_password "$1" && echo VAR || echo YOK; }

assert_eq "$(p_yes "mysqldump -u usr_x -pGIZLI db_x | gzip > /y.gz")" "VAR" \
    "3) mysqldump '-pGIZLI' → tespit (üretimdeki tipik yedek cron'u)"
assert_eq "$(p_yes "mariadb-dump --password=GIZLI db_x")" "VAR" \
    "3) '--password=GIZLI' → tespit"
assert_eq "$(p_yes "psql --pass=GIZLI -c 'select 1'")" "VAR" \
    "3) '--pass=GIZLI' → tespit"
assert_eq "$(p_yes "PGPASSWORD=gizli pg_dump db")" "VAR" \
    "3) 'PGPASSWORD=' → tespit (araçtan bağımsız ortam-değişkeni biçimi)"
assert_eq "$(p_yes "MYSQL_PWD=gizli mysqldump db")" "VAR" \
    "3) 'MYSQL_PWD=' → tespit"

# ── YANLIŞ ALARM KORUMASI (bir tespit katmanı yanlış alarm verirse
#    operatör tüm katmana güvenmeyi bırakır) ──
assert_eq "$(p_yes "mkdir -p /var/www/example.com/tmp")" "YOK" \
    "3) [YANLIŞ ALARM] 'mkdir -p...' parola SANILMIYOR (mysql aracı yok)"
assert_eq "$(p_yes "cp -pr /a /b && tar -pcf /y.tar /b")" "YOK" \
    "3) [YANLIŞ ALARM] 'cp -pr' / 'tar -pcf' parola SANILMIYOR"
assert_eq "$(p_yes "mysqldump -u usr_x -p db_x")" "YOK" \
    "3) [YANLIŞ ALARM] çıplak '-p' (parolayı SOR) sır DEĞİL — uyarı YOK"
assert_eq "$(p_yes "mysql --defaults-extra-file=/root/.my.cnf -e 'select 1'")" "YOK" \
    "3) [ÖNERİLEN BİÇİM] '--defaults-extra-file=' uyarı ÜRETMİYOR"
assert_eq "$(p_yes "php artisan queue:work --sleep=3")" "YOK" \
    "3) [YANLIŞ ALARM] sıradan artisan komutu temiz"
assert_eq "$(p_yes "mysqldump --password= db_x")" "YOK" \
    "3) [YANLIŞ ALARM] boş '--password=' (sor) sır DEĞİL"

# ── UYARI GERÇEKTEN BASILIYOR ve ekleme ENGELLENMİYOR ──
out_pw=$(_cron_add "$d" --name=pw_warn --schedule="her gün 04:00" \
    --command="mysqldump -u usr_x -pGIZLI db_x > /tmp/y.sql" 2>&1)
rc_pw=$?
assert_eq "$rc_pw" "0" "3) parola uyarısı ENGEL DEĞİL (cron eklendi, exit 0)"
assert_contains "$out_pw" "DÜZ METİN parola" "3) parola uyarısı operatöre basıldı"
assert_contains "$out_pw" "defaults-extra-file" "3) uyarı SOMUT çözümü ('--defaults-extra-file=') gösteriyor"
assert_contains "$out_pw" "cmdline" "3) uyarı argv/proc sızıntısını AÇIKÇA anlatıyor"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-pw_warn.service")" "var" \
    "3) uyarıya rağmen unit GERÇEKTEN yazıldı (engelleme YOK)"

# ═══════════════════════════════════════════════════════════════════════
# 4) O-4 — 'name' DOĞRULAMASI: rm -rf yolunda YÜK TAŞIYOR MU?
# ═══════════════════════════════════════════════════════════════════════
# Yol geçişinin GERÇEKTEN çalıştığı bir kurulum ELLE inşa edilir: normalde
# '..' bileşeni işe yaramaz çünkü 'srvctl-cron-<sname>-<name>' bir DİZİN
# değildir. Burada o dizini AÇIKÇA yaratıyoruz — böylece
# "${sysd_dir}/srvctl-cron-<sname>-sub/../CANARY.service" GERÇEKTEN
# "${sysd_dir}/CANARY.service" hedefine çözülür ve varlık kapısı da geçilir.
# Doğrulama OLMASAYDI 'rm -rf -- "${sysd_dir}/${svc}.d"' CANARY.service.d'yi
# SİLERDİ. Bu iddia, kapının tesadüf değil GERÇEK bir savunma olduğunu
# kanıtlar.
mkdir -p "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-sub"
mkdir -p "${SRVCTL_SYSTEMD_DIR}/CANARY.service.d"
printf 'KANIT\n' > "${SRVCTL_SYSTEMD_DIR}/CANARY.service.d/kanit.conf"
printf '[Unit]\n'  > "${SRVCTL_SYSTEMD_DIR}/CANARY.service"
printf '[Unit]\n'  > "${SRVCTL_SYSTEMD_DIR}/CANARY.timer"

# Ön koşul: geçiş yolu GERÇEKTEN çözülüyor mu? (test kurulumunun kendisi
# doğru mu — yanlış-negatif kalkanı)
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-sub/../CANARY.service")" "var" \
    "4) test kurulumu: yol geçişi GERÇEKTEN çözülüyor (kapı yük taşıyor olmalı)"

trav="sub/../CANARY"
rm_out=$( ( _cron_remove "$d" "$trav" ) 2>&1 ); rm_rc=$?
assert_eq "$([[ "$rm_rc" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "4) [KRİTİK] _cron_remove yol geçişi içeren adı REDDEDİYOR"
assert_contains "$rm_out" "Geçersiz cron adı" \
    "4) red gerekçesi operatöre açıkça yazılıyor"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/CANARY.service.d/kanit.conf")" "var" \
    "4) [KRİTİK] 'rm -rf' HİÇ çalışmadı — CANARY.service.d KORUNDU"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/CANARY.service")" "var" \
    "4) [KRİTİK] CANARY.service silinmedi"

# Kalan beş giriş noktası — hepsi AYNI kapıyı uygulamalı.
for sub in show run logs; do
    o=$( ( _cron_"$sub" "$d" "$trav" ) 2>&1 ); r=$?
    assert_eq "$([[ "$r" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
        "4) cron ${sub}: yol geçişi içeren ad REDDEDİLDİ"
    assert_contains "$o" "Geçersiz cron adı" "4) cron ${sub}: gerekçe yazılıyor"
done
for want in true false; do
    o=$( ( _cron_set_enabled "$want" "$d" "$trav" ) 2>&1 ); r=$?
    assert_eq "$([[ "$r" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
        "4) cron $([[ "$want" == true ]] && echo enable || echo disable): yol geçişi REDDEDİLDİ"
done

# Aşırı uzun ad (51 karakter) — unit dosya adı hijyeni
longname=$(printf 'a%.0s' $(seq 1 51))
o=$( ( _cron_remove "$d" "$longname" ) 2>&1 ); r=$?
assert_eq "$([[ "$r" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "4) 51 karakterlik ad REDDEDİLDİ (azami 50)"
# 50 karakter SINIRDA kabul edilmeli (kapı fazla dar olmamalı) — burada
# 'bulunamadı' hatası beklenir, 'geçersiz ad' DEĞİL.
okname=$(printf 'a%.0s' $(seq 1 50))
o=$( ( _cron_remove "$d" "$okname" ) 2>&1 ) || true
assert_not_contains "$o" "Geçersiz cron adı" \
    "4) 50 karakterlik ad KABUL ediliyor (sınırda yanlış red YOK)"

# Boş ad — kullanım mesajıyla durmalı
o=$( ( _cron_remove "$d" "" ) 2>&1 ); r=$?
assert_eq "$([[ "$r" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "4) boş ad REDDEDİLDİ"

# ═══════════════════════════════════════════════════════════════════════
# 5) --description satırsonu/CR (simetri)
# ═══════════════════════════════════════════════════════════════════════
o=$( ( _cron_add "$d" --name=desc_nl --schedule="her gün 03:00" \
        --command="echo x" --description=$'iyi\nkotu' ) 2>&1 ); r=$?
assert_eq "$([[ "$r" -ne 0 ]] && echo NONZERO || echo ZERO)" "NONZERO" \
    "5) --description satırsonu içeren değer REDDEDİLDİ"
assert_contains "$o" "--description satırsonu/CR içeremez" \
    "5) red mesajı HANGİ girdinin sorunlu olduğunu söylüyor"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-desc_nl.service")" "yok" \
    "5) fail-closed: yarım unit dosyası kalmadı"

# ═══════════════════════════════════════════════════════════════════════
# 6) O-3 — YAZ SAATİ (DST) TESPİTİ (SAF PREDİKAT)
# ═══════════════════════════════════════════════════════════════════════
dst() { _cron_tz_has_dst "$1"; echo $?; }
assert_eq "$(dst Europe/Berlin)"   "0" "6) Europe/Berlin → DST VAR (0)"
assert_eq "$(dst Europe/Istanbul)" "1" "6) [YANLIŞ ALARM] Europe/Istanbul → DST YOK (1) — Türkiye 2016'dan beri kalıcı +03"
assert_eq "$(dst UTC)"             "1" "6) UTC → DST YOK"
assert_eq "$(dst America/New_York)" "0" "6) America/New_York → DST VAR"
assert_eq "$(dst Australia/Sydney)" "0" "6) Australia/Sydney → DST VAR (güney yarımküre de yakalanıyor)"
assert_eq "$(dst "")"              "2" "6) dilim bilinmiyorsa 2 (BİLİNMİYOR — uydurma YOK)"

# ── 'cron add' sırasında uyarı: DST'li dilimde VAR, DST'siz dilimde YOK ──
o=$(SRVCTL_TIMEZONE=Europe/Berlin _cron_add "$d" --name=dst_on \
    --schedule="her gün 03:00" --command="echo x" 2>&1)
assert_contains "$o" "YAZ SAATİ (DST) UYARISI" \
    "6) [O-3] DST'li dilimde SABİT saatli yerel iş için uyarı BASILIYOR"
assert_contains "$o" "--utc" \
    "6) [O-3] uyarı somut çözümü ('--utc') öneriyor"

o=$(SRVCTL_TIMEZONE=Europe/Istanbul _cron_add "$d" --name=dst_off \
    --schedule="her gün 03:00" --command="echo x" 2>&1)
assert_not_contains "$o" "YAZ SAATİ (DST) UYARISI" \
    "6) [KRİTİK/YANLIŞ ALARM] Türkiye'de (DST YOK) uyarı BASILMIYOR"

# Aralık işleri (sabit saat YOK) uyarı üretmemeli — gürültü kontrolü
o=$(SRVCTL_TIMEZONE=Europe/Berlin _cron_add "$d" --name=dst_interval \
    --schedule="her 15 dakikada" --command="echo x" 2>&1)
assert_not_contains "$o" "YAZ SAATİ (DST) UYARISI" \
    "6) ARALIK işinde (sabit saat yok) uyarı BASILMIYOR (gürültü kontrolü)"

# '--utc' verilmişse iş zaten mutlak zamanda — uyarı üretilmemeli
o=$(SRVCTL_TIMEZONE=Europe/Berlin _cron_add "$d" --name=dst_utc \
    --schedule="her gün 03:00" --command="echo x" --utc 2>&1)
assert_not_contains "$o" "YAZ SAATİ (DST) UYARISI" \
    "6) '--utc' ile kurulan işte DST uyarısı BASILMIYOR (mutlak zaman)"

# ═══════════════════════════════════════════════════════════════════════
# 7) O-3 (ikinci yarı) — GÖRÜNTÜLEMEDE ANLIK OFSET DÜRÜSTLÜĞÜ
# ═══════════════════════════════════════════════════════════════════════
note=$(SRVCTL_TIMEZONE=Europe/Berlin _cron_schedule_tz_note "*-*-* 01:00:00 UTC")
assert_contains "$note" "YAKLAŞIK" \
    "7) [O-3] UTC→yerel karşılığı 'YAKLAŞIK' diye etiketleniyor"
assert_contains "$note" "şu anki ofsete göre" \
    "7) [O-3] karşılığın ANLIK ofsetten geldiği açıkça yazılıyor"
assert_contains "$note" "YAZ SAATİ" \
    "7) [O-3] DST'li dilimde '1 saat kayar' notu ekleniyor"

note_tr=$(SRVCTL_TIMEZONE=Europe/Istanbul _cron_schedule_tz_note "*-*-* 01:00:00 UTC")
assert_contains "$note_tr" "YAKLAŞIK" \
    "7) Türkiye'de de karşılık 'YAKLAŞIK' (anlık ofset dürüstlüğü evrensel)"
assert_not_contains "$note_tr" "YAZ SAATİ" \
    "7) [YANLIŞ ALARM] Türkiye'de DST notu EKLENMİYOR"

note_local=$(SRVCTL_TIMEZONE=Europe/Istanbul _cron_schedule_tz_note "*-*-* 03:00:00")
assert_contains "$note_local" "sunucu yerel saati" \
    "7) sonek yoksa 'sunucu yerel saati' deniyor (davranış korundu)"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR" "$SRVCTL_LOCK_DIR"
test_summary
