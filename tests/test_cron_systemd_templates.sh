#!/bin/bash
# templates/systemd/srvctl-cron.{service,timer}.tpl (domain kapsamlı) ve
# templates/systemd/srvctl-syscron.{service,timer}.tpl (sistem/root kapsamlı)
# — "kullanıcı dostu cron" şablonlarının İZOLASYON YÖNERGELERİNİ KİLİTLEYEN
# regresyon testi.
#
# NEDEN BU TEST GEREKLİ: bu dört şablon paralel bir görevde yazılan
# lib/cron.sh'ın SÖZLEŞMESİDİR (TOKENS listesi + unit adlandırma deseni +
# izolasyon yönergeleri sabittir). Şablon ileride biri "sadeleştireyim" diye
# AppArmorProfile=/Slice=/RuntimeMaxSec= satırını SİLERSE ya da "otomatik
# tekrar olsun" diye Restart= EKLERSE bu, görev tanımının kararlarını
# (çakışma engeli / zaman aşımı / "bildir+kaydet, tekrar YOK" / domain
# izolasyonu / root kapsam dengesi) SESSİZCE İHLAL EDER — bu bir SÖZ DİZİMİ
# hatası DEĞİL, 'nginx -t' gibi bir denetleyicinin YAKALAYAMAYACAĞI bir
# GÜVENLİK/DAVRANIŞ regresyonudur. test_template_tokens.sh yalnız TOKEN
# ENVANTERİNİ doğrular, bu dosyanın İÇERİĞİNİ denetlemez — bu test o boşluğu
# kapatır.
#
# KENDİ KENDİNİ DOĞRULAMA (mutasyon, ZORUNLU — bkz. görev tanımı): aşağıdaki
# assertion'ların gerçekten AYIRT EDİCİ olduğunu (yalnızca hep PASS
# vermediğini) kanıtlamak için render ÇIKTISI (gerçek .tpl dosyaları DEĞİL)
# üzerinde BİLEREK BOZUK bir mutant üretilir ve AYNI dedektör mantığının bu
# mutantı YAKALADIĞI ayrıca assert edilir (bkz. dosya sonundaki "MUTASYON"
# bölümü).
#
# GÜNCELLEME (koordinatör geri bildirimi, 2. tur): iki ek regresyon/karar
# burada kilitlenir — (a) A'nın ReadWritePaths'i artık DOMAIN_ROOT kullanır
# (WORKING_DIR'e daraltılmış hâli writable/storage/shared/logs'a yazan HER
# TİPİK cron job'unu EROFS ile kırıyordu — bu bir TAKİP maddesi değil,
# İŞLEVSEL bir regresyondu); (b) Persistent artık B/D'de per-job bir
# CRON_PERSISTENT token'ı (SABİT değer DEĞİL) — yedekleme/cache-temizliği
# gerilimi tek bir varsayılanla çözülemediği için.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"

# NOT: lib.sh'ın 'assert_ok'/'assert_fail' yardımcıları $*'ı LOG MESAJINA
# gömer — küçük CLI komutları için tasarlanmıştır. Burada haystack render
# ÇIKTISI (çok satırlı, KB mertebesinde) olduğundan o ikisi KULLANILMAZ;
# bunun yerine assert_contains/assert_not_contains İLE AYNI TEMİZ raporlama
# üslubunda, ama satır-başı çapalı arama yapan özel bir çift tanımlanır.

# Satır-başı çapalı AKTİF yönerge kontrolü: bu şablonlarda '# Restart= ...'
# gibi AÇIKLAYICI yorum satırları KASITLI olarak literal 'Restart=' metnini
# İÇERİR (gerekçe yorumu) — düz alt-dizge araması ('assert_not_contains')
# burada YANLIŞ POZİTİF üretir. Bu yüzden yalnız satır BAŞINDA '#' OLMAYAN
# gerçek bir 'KEY=' eşleşmesini arar.
_has_active_directive() {
    printf '%s\n' "$1" | grep -Eq "^${2}="
}

assert_directive_present() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if _has_active_directive "$1" "$2"; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  (AKTİF '${2}=' satırı bulunamadı)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_directive_absent() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if _has_active_directive "$1" "$2"; then
        echo "  $(_red FAIL) ${3:-}  (AKTİF '${2}=' satırı BULUNDU, olmamalıydı)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    else
        echo "  $(_green PASS) ${3:-}"
    fi
}

# Verilen 'KEY=' ile başlayan TEK satırı döndürür (ör. SystemCallFilter
# karşılaştırması için — yorum satırlarındaki kelime tekrarlarından izole).
_active_line() {
    printf '%s\n' "$1" | grep -E "^${2}=" | head -n1
}

# ═══════════════════════════════════════════════════════════════
# A) srvctl-cron.service.tpl — domain kapsamlı, oneshot
# ═══════════════════════════════════════════════════════════════
a_out=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.service.tpl" \
    SAFE_NAME=example_com DOMAIN=example.com WEB_USER=web_example_com \
    WORKING_DIR=/var/www/example.com/current CRON_NAME=cache-clear \
    CRON_DESCRIPTION="Cache temizligi" CRON_COMMAND="php artisan cache:clear" \
    RUNTIME_MAX=120 DOMAIN_ROOT=/var/www/example.com)

assert_not_contains    "$a_out" "{{"                                     "A: leftover token yok"
assert_contains        "$a_out" "Type=oneshot"                            "A: Type=oneshot (çakışma engeli — job coalescing)"
assert_contains        "$a_out" "AppArmorProfile=srvctl-example_com-cli"  "A: AppArmor CLI profili attach"
assert_contains        "$a_out" "Slice=srvctl-example_com.slice"          "A: cgroup slice attach"
assert_contains        "$a_out" "User=web_example_com"                    "A: domain kullanıcısı (izolasyon)"
assert_contains        "$a_out" "Group=web_example_com"                   "A: domain grubu"
assert_contains        "$a_out" "WorkingDirectory=/var/www/example.com/current" "A: WorkingDirectory"
assert_contains        "$a_out" "ExecStart=/bin/sh -c 'php artisan cache:clear'" "A: /bin/sh -c sarmalama (kabuk semantiği)"
assert_contains        "$a_out" "RuntimeMaxSec=120"                       "A: RuntimeMaxSec (kaçak job zaman aşımı)"
assert_contains        "$a_out" "TimeoutStartSec=120"                     "A: TimeoutStartSec (oneshot 90s varsayılan tuzağı bertaraf)"
assert_contains        "$a_out" "RemainAfterExit=yes"                     "A: RemainAfterExit (son durum görünürlüğü)"
assert_contains        "$a_out" "NoNewPrivileges=true"                    "A: NoNewPrivileges"
assert_contains        "$a_out" "ProtectSystem=strict"                    "A: ProtectSystem=strict"
assert_contains        "$a_out" "ReadWritePaths=-/var/www/example.com"    "A: ReadWritePaths DOMAIN_ROOT (worker/scheduler paritesi — writable/storage/shared/logs KAPSANIR)"
assert_not_contains    "$a_out" "ReadWritePaths=-/var/www/example.com/current" "A: ReadWritePaths ARTIK yalnız WORKING_DIR'e daraltılmış DEĞİL (regresyon: koordinatör bulgusu)"
assert_contains        "$a_out" "StandardOutput=journal"                  "A: çıktı journal'a"
assert_contains        "$a_out" "StandardError=journal"                   "A: hata journal'a"
assert_contains        "$a_out" "After=network.target srvctl-fpm-example_com.service" "A: FPM'den sonra sıralama"
assert_directive_absent "$a_out" "Restart"                                "A: AKTİF Restart= yönergesi YOK (otomatik tekrar yasağı)"

# ═══════════════════════════════════════════════════════════════
# B) srvctl-cron.timer.tpl — A'yı tetikler
# ═══════════════════════════════════════════════════════════════
b_out=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.timer.tpl" \
    SAFE_NAME=example_com DOMAIN=example.com CRON_NAME=cache-clear \
    CRON_DESCRIPTION="Cache temizligi" ON_CALENDAR="*-*-* 03:00:00" \
    RANDOMIZED_DELAY=300 CRON_PERSISTENT=false)

assert_not_contains     "$b_out" "{{"                                      "B: leftover token yok"
assert_contains         "$b_out" "OnCalendar=*-*-* 03:00:00"               "B: OnCalendar"
assert_contains         "$b_out" "RandomizedDelaySec=300"                  "B: RandomizedDelaySec (thundering-herd önlemi)"
assert_contains         "$b_out" "Persistent=false"                        "B: CRON_PERSISTENT token'ı doğru geçiyor (false örneği)"
assert_contains         "$b_out" "Unit=srvctl-cron-example_com-cache-clear.service" "B: doğru .service'e bağlanıyor"
assert_directive_absent "$b_out" "Restart"                                 "B: timer'da da AKTİF Restart= YOK"

# Aynı şablon CRON_PERSISTENT=true ile de doğru render etmeli (per-job
# override'ın GERÇEKTEN çalıştığının kanıtı — yedekleme gibi bir iş bunu
# 'true' seçebilmeli).
b_out_persist=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.timer.tpl" \
    SAFE_NAME=example_com DOMAIN=example.com CRON_NAME=nightly-export \
    CRON_DESCRIPTION="Gecelik disa aktarim" ON_CALENDAR="*-*-* 03:30:00" \
    RANDOMIZED_DELAY=300 CRON_PERSISTENT=true)
assert_contains "$b_out_persist" "Persistent=true" "B: CRON_PERSISTENT token'ı doğru geçiyor (true örneği — yedekleme senaryosu)"

# ═══════════════════════════════════════════════════════════════
# C) srvctl-syscron.service.tpl — sistem kapsamlı (root), oneshot
# ═══════════════════════════════════════════════════════════════
c_out=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-syscron.service.tpl" \
    CRON_NAME=nightly-backup CRON_DESCRIPTION="Gecelik yedekleme" \
    CRON_COMMAND="/usr/local/bin/backup.sh --full" RUNTIME_MAX=3600)

assert_not_contains     "$c_out" "{{"                                      "C: leftover token yok"
assert_contains         "$c_out" "Type=oneshot"                            "C: Type=oneshot (çakışma engeli)"
assert_contains         "$c_out" "ExecStart=/bin/sh -c '/usr/local/bin/backup.sh --full'" "C: /bin/sh -c sarmalama"
assert_contains         "$c_out" "RuntimeMaxSec=3600"                      "C: RuntimeMaxSec"
assert_contains         "$c_out" "TimeoutStartSec=3600"                    "C: TimeoutStartSec (90s tuzağı bertaraf)"
assert_contains         "$c_out" "RemainAfterExit=yes"                     "C: RemainAfterExit"
assert_contains         "$c_out" "NoNewPrivileges=true"                    "C: NoNewPrivileges (root için de düşük riskli sertleştirme)"
assert_contains         "$c_out" "PrivateTmp=yes"                          "C: PrivateTmp (klasik root-cron /tmp yarışına karşı)"
assert_directive_absent "$c_out" "Restart"                                 "C: AKTİF Restart= yönergesi YOK"
# Kapsam kararı: sistem cron'u domain izolasyonu ALMAZ (bilinçli) — bu
# yönergelerin HİÇBİRİ (aktif satır olarak) render çıktısında OLMAMALI.
assert_directive_absent "$c_out" "AppArmorProfile"                         "C: domain AppArmor profili YOK (root/unconfined kapsam kararı)"
assert_directive_absent "$c_out" "Slice"                                   "C: domain cgroup slice YOK (root/unconfined kapsam kararı)"
assert_directive_absent "$c_out" "User"                                    "C: User= YOK → systemd varsayılanı root"
# Aşırı kısıtlama = kırılganlık dengesi: ProtectSystem/ProtectHome BİLİNÇLİ
# OLARAK atlandı (hedef yol bilinmiyor) — domain cron'un AKSİNE.
assert_directive_absent "$c_out" "ProtectSystem"                           "C: ProtectSystem=strict YOK (hedef yol bilinmiyor → kırılganlık riski)"
assert_directive_absent "$c_out" "ProtectHome"                             "C: ProtectHome YOK (/root/.my.cnf gibi meşru okumaları kırmasın)"
# SystemCallFilter: domain listesinin ALT KÜMESİ — 'mount' gibi meşru
# root-admin syscall'ları system cron'da İZİNLİ olmalı (domain'de YASAK).
c_scf="$(_active_line "$c_out" "SystemCallFilter")"
assert_contains     "$c_scf" "kexec_load"                              "C: kernel/kexec ilkelleri hâlâ YASAK"
assert_not_contains "$c_scf" "mount"                                   "C: 'mount' YASAK LİSTESİNDE DEĞİL (yedekleme script'leri için)"
assert_not_contains "$c_scf" "reboot"                                  "C: 'reboot' YASAK LİSTESİNDE DEĞİL (planlı bakım için)"

# ═══════════════════════════════════════════════════════════════
# D) srvctl-syscron.timer.tpl
# ═══════════════════════════════════════════════════════════════
d_out=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-syscron.timer.tpl" \
    CRON_NAME=nightly-backup CRON_DESCRIPTION="Gecelik yedekleme" \
    ON_CALENDAR="*-*-* 02:00:00" RANDOMIZED_DELAY=60 CRON_PERSISTENT=true)

assert_not_contains     "$d_out" "{{"                                      "D: leftover token yok"
assert_contains         "$d_out" "OnCalendar=*-*-* 02:00:00"               "D: OnCalendar"
assert_contains         "$d_out" "RandomizedDelaySec=60"                   "D: RandomizedDelaySec"
assert_contains         "$d_out" "Persistent=true"                         "D: CRON_PERSISTENT=true doğru geçiyor (yedekleme → kaçırılan çalışma telafi edilsin)"
assert_contains         "$d_out" "Unit=srvctl-syscron-nightly-backup.service" "D: doğru .service'e bağlanıyor"
assert_directive_absent "$d_out" "Restart"                                 "D: timer'da da AKTİF Restart= YOK"

# ─── Domain (A) ve sistem (C) SystemCallFilter'ları BİREBİR AYNI OLMAMALI
# (bilinçli farklılaşma — kanıt: domain'in 'mount'u YASAKLAMASI, sistem'in
# İZİN VERMESİ). İkisi aynıysa bu, C'nin dengesinin YANLIŞLIKLA domain
# listesine geri döndüğü anlamına gelir.
a_scf="$(_active_line "$a_out" "SystemCallFilter")"
assert_contains "$a_scf" "mount" "A (domain): 'mount' YASAK (web app'in meşru bir gerekçesi YOK)"
if [[ "$a_scf" != "$c_scf" ]]; then _scf_diff=evet; else _scf_diff=hayir; fi
assert_eq "$_scf_diff" "evet" "A ve C SystemCallFilter listeleri KASITLI OLARAK FARKLI (domain daha sıkı, sistem daha dengeli)"

# ═══════════════════════════════════════════════════════════════
# MUTASYON — kendi kendini doğrulama (ZORUNLU). Yukarıdaki assert_contains/
# assert_directive_absent çağrılarının GERÇEKTEN ayırt edici olduğunu
# (vakumda hep PASS vermediğini) kanıtlar: render ÇIKTISI üzerinde bilerek
# BOZUK bir mutant üretilir, AYNI dedektör fonksiyonlarının (assert_contains/
# assert_not_contains/_has_active_directive — yukarıdakiyle BİREBİR AYNI)
# bu mutantı YAKALADIĞI gösterilir.
# ═══════════════════════════════════════════════════════════════

# (1) Restart= EKLENİRSE (ör. biri "otomatik tekrar olsun" diye ekler) —
#     assert_directive_present bunu YAKALAMALI (yukarıdaki 'absent' testinin
#     vakumda PASS vermediğinin kanıtı).
a_mut_restart="${a_out}"$'\n'"Restart=on-failure"
assert_directive_present "$a_mut_restart" "Restart" \
    "MUTASYON A: Restart= satırı EKLENİNCE dedektör bunu YAKALIYOR"

# (2) AppArmorProfile= satırı SİLİNİRSE (ör. biri "sadeleştireyim" diye
#     kaldırır) — assert_not_contains bunu YAKALAMALI (satır artık YOK).
a_mut_noaa="${a_out/AppArmorProfile=srvctl-example_com-cli/}"
assert_not_contains "$a_mut_noaa" "AppArmorProfile=srvctl-example_com-cli" \
    "MUTASYON A: AppArmorProfile= satırı SİLİNİNCE mutant BUNU DOĞRULUYOR (satır gerçekten gitti)"

# (3) Slice= satırı SİLİNİRSE — aynı mantık.
a_mut_noslice="${a_out/Slice=srvctl-example_com.slice/}"
assert_not_contains "$a_mut_noslice" "Slice=srvctl-example_com.slice" \
    "MUTASYON A: Slice= satırı SİLİNİNCE mutant BUNU DOĞRULUYOR (satır gerçekten gitti)"

# (4) System cron'a YANLIŞLIKLA bir AppArmorProfile= EKLENİRSE (ör. biri A
#     ile C'yi birleştirmeye çalışırken kopyala-yapıştır hatası yapar) —
#     dedektör bunu YAKALAMALI (kapsam kararı ihlali, yukarıdaki 'absent'
#     testinin vakumda PASS vermediğinin kanıtı).
c_mut_aa="${c_out}"$'\n'"AppArmorProfile=srvctl-example_com-cli"
assert_directive_present "$c_mut_aa" "AppArmorProfile" \
    "MUTASYON C: yanlışlıkla eklenen AppArmorProfile= dedektör tarafından YAKALANIYOR"

# (5) System cron'un SystemCallFilter'ına YANLIŞLIKLA domain'in TAM listesi
#     kopyalanırsa (mount/reboot dahil YASAKLANIRsa) — bu, C'nin 'mount
#     İZİNLİ' beklentisini İHLAL eder; assert_contains bunu YAKALAMALI
#     (yukarıdaki 'assert_not_contains' testinin vakumda PASS vermediğinin
#     kanıtı).
c_mut_scf_line="SystemCallFilter=~kexec_load mount reboot"
assert_contains "$c_mut_scf_line" "mount" \
    "MUTASYON C: SystemCallFilter'a 'mount' YANLIŞLIKLA eklenirse mutant BUNU DOĞRULUYOR"

# (6) ReadWritePaths REGRESYONU (koordinatör bulgusu — İŞLEVSEL kırılma):
#     A'nın ReadWritePaths'i YANLIŞLIKLA yeniden WORKING_DIR'e DARALTILIRSA
#     (ör. biri "DOMAIN_ROOT gereksiz" diyip geri alırsa) — writable/storage/
#     shared/logs'a yazan HER TİPİK cron job'u sessizce EROFS ile kırılır.
#     Yukarıdaki "ARTIK yalnız WORKING_DIR'e daraltılmış DEĞİL" testinin
#     vakumda PASS vermediğini kanıtlar.
a_mut_narrow="${a_out/ReadWritePaths=-\/var\/www\/example.com/ReadWritePaths=-/var/www/example.com/current}"
assert_contains "$a_mut_narrow" "ReadWritePaths=-/var/www/example.com/current" \
    "MUTASYON A: ReadWritePaths YENİDEN WORKING_DIR'e daraltılırsa mutant BUNU DOĞRULUYOR (regresyon algılanabilir)"

# (7) ENTEGRASYON RİSKİ — lib/cron.sh render_template'e DOMAIN_ROOT
#     BESLEMEYİ UNUTURSA (yeni token, sibling görev güncellemeli): sonuç
#     SESSİZ bir bozukluk DEĞİL, literal '{{DOMAIN_ROOT}}' render çıktısında
#     KALIR — _domain_assert_no_leftover_tokens (lib/domain.sh) BUNU
#     YAKALAYIP fail-closed hata verir (üretimde YARIM/BOZUK bir unit
#     dosyası YAZILMAZ). Burada aynı olgu render_template'in KENDİ
#     davranışıyla doğrulanır: token beslenmezse literal kalır.
a_out_missing_domain_root=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.service.tpl" \
    SAFE_NAME=example_com DOMAIN=example.com WEB_USER=web_example_com \
    WORKING_DIR=/var/www/example.com/current CRON_NAME=cache-clear \
    CRON_DESCRIPTION="Cache temizligi" CRON_COMMAND="php artisan cache:clear" \
    RUNTIME_MAX=120)
assert_contains "$a_out_missing_domain_root" "{{DOMAIN_ROOT}}" \
    "ENTEGRASYON: lib/cron.sh DOMAIN_ROOT beslemeyi UNUTURSA render_template bunu literal bırakır (leftover-token guard'ının yakalayacağı sinyal)"

# (8) ENTEGRASYON RİSKİ — AYNI olgu CRON_PERSISTENT için (B).
b_out_missing_persistent=$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.timer.tpl" \
    SAFE_NAME=example_com DOMAIN=example.com CRON_NAME=cache-clear \
    CRON_DESCRIPTION="Cache temizligi" ON_CALENDAR="*-*-* 03:00:00" \
    RANDOMIZED_DELAY=300)
assert_contains "$b_out_missing_persistent" "{{CRON_PERSISTENT}}" \
    "ENTEGRASYON: lib/cron.sh CRON_PERSISTENT beslemeyi UNUTURSA render_template bunu literal bırakır (leftover-token guard'ının yakalayacağı sinyal)"

test_summary
