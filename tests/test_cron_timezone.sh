#!/bin/bash
# lib/cron.sh — ZAMAN DİLİMİ regresyon testi (varsayılan yerel saat + '--utc').
#
# ═══ NEDEN VAR (GERÇEK üretim sunucusunda ÖLÇÜLDÜ) ═══
# Ubuntu 24.04, canlı e-ticaret, sunucu dilimi Europe/Istanbul (+03):
#     kullanıcı yazdı  : srvctl cron add ... --schedule="her gün 04:00"
#     srvctl unit'e yazdı: OnCalendar=*-*-* 04:00:00 UTC
#     systemd ateşledi : Sun 2026-08-02 07:00:00 +03
# Gece bakımı için kurulan iş SABAH TRAFİĞİNİN AÇILDIĞI saatte çalıştı.
# Bu kozmetik DEĞİL: yedek/DB-optimize/cache-warm gibi ağır işlerin 3 saat
# kayması operasyonel bir tehlikedir. "UTC daha güvenli çünkü DST" savunması
# Türkiye'de GEÇERSİZ (2016'dan beri kalıcı +03, yaz saati YOK).
#
# BU TESTİN KİLİTLEDİĞİ SÖZLEŞME:
#   1) VARSAYILAN: hesaplanan OnCalendar'da ' UTC' soneki YOKTUR (systemd
#      soneksiz ifadeyi SİSTEM YEREL saatinde yorumlar).
#   2) '--utc': sonek VARDIR (eski davranış, AÇIK tercih olarak korunur).
#   3) Diskte duran ESKİ (' UTC' sonekli) unit'ler SESSİZCE KAYDIRILMAZ ve
#      SESSİZCE GÖRMEZDEN de GELİNMEZ — 'list'/'show' onları işaretler ve
#      YEREL karşılığını ("04:00 UTC → 07:00") gösterir.
#   4) 'Açıklama' alanı systemd 'Description=' ÖNEKİNDEN arınmış görünür.
#   5) Saat dilimi tespiti 'timedatectl' YOKKEN (bu macOS makinesinin doğal
#      durumu) ÇÖKMEZ.
#
# TEST TOHUMU: 'SRVCTL_TIMEZONE' (projenin SRVCTL_*_DIR desenine uyar) —
# gerçek 'timedatectl' olmadan hem "+03" hem "UTC" senaryosu kurulabilir.
# Ofset, dilim ADINDAN 'TZ=<ad> date +%z' ile türetilir; bunu GNU date DE
# BSD/macOS date DE onurlandırır, bu yüzden testler her iki ortamda AYNI
# sonucu verir (Europe/Istanbul yaz saati UYGULAMAZ — mevsime bağlı
# kırılganlık YOK; ikinci senaryo olarak da sabit 'UTC' kullanılır).
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

ex() { [[ -e "$1" ]] && echo var || echo yok; }

# ═══════════════════════════════════════════════
#  1) SAF OFSET AYRIŞTIRMA/BİÇİMLEME (_cron_parse_offset_minutes / _cron_offset_label)
# ═══════════════════════════════════════════════
assert_eq "$(_cron_parse_offset_minutes '+0300')" "180" \
    "1) '+0300' → 180 dakika (Türkiye)"
assert_eq "$(_cron_parse_offset_minutes '+03:00')" "180" \
    "1) iki nokta üst üsteli biçim ('+03:00') da kabul edilir"
assert_eq "$(_cron_parse_offset_minutes '+0000')" "0" \
    "1) '+0000' → 0 (sunucu UTC'de)"
assert_eq "$(_cron_parse_offset_minutes '-0430')" "-270" \
    "1) negatif + yarım saatli ofset ('-0430') → -270"
assert_eq "$(_cron_parse_offset_minutes '+0545')" "345" \
    "1) çeyrek saatli ofset ('+0545', Nepal) → 345"
assert_fail _cron_parse_offset_minutes "" \
    "1) boş girdi REDDEDİLİR (uydurma ofset YOK)"
assert_fail _cron_parse_offset_minutes "0300" \
    "1) işaretsiz girdi REDDEDİLİR"
assert_fail _cron_parse_offset_minutes "+03" \
    "1) eksik dakika alanı REDDEDİLİR"

assert_eq "$(_cron_offset_label 180)" "+03:00"  "1) 180 → '+03:00'"
assert_eq "$(_cron_offset_label 0)" "+00:00"    "1) 0 → '+00:00'"
assert_eq "$(_cron_offset_label -270)" "-04:30" "1) -270 → '-04:30'"
assert_eq "$(_cron_offset_label 345)" "+05:45"  "1) 345 → '+05:45'"
assert_fail _cron_offset_label "abc" \
    "1) sayı olmayan ofset etiketlenmez (predikat FAIL)"

# ═══════════════════════════════════════════════
#  2) SAF SAAT KAYDIRMA (_cron_shift_hhmm) — üretim senaryosunun ÇEKİRDEĞİ
# ═══════════════════════════════════════════════
assert_eq "$(_cron_shift_hhmm '04:00' 180)" "07:00" \
    "2) ÜRETİM SENARYOSU: 04:00 UTC + 3 saat = 07:00 yerel (ölçülen hata)"
assert_eq "$(_cron_shift_hhmm '03:00' 180)" "06:00" \
    "2) 03:00 UTC → 06:00 yerel"
assert_eq "$(_cron_shift_hhmm '23:30' 180)" "02:30 (ertesi gün)" \
    "2) gün TAŞMASI açıkça işaretleniyor (23:30 UTC → 02:30 ertesi gün)"
assert_eq "$(_cron_shift_hhmm '01:00' -180)" "22:00 (bir önceki gün)" \
    "2) negatif ofsette geriye taşma da işaretleniyor"
assert_eq "$(_cron_shift_hhmm '10:00' 0)" "10:00" \
    "2) ofset 0 ise saat DEĞİŞMEZ"
assert_eq "$(_cron_shift_hhmm '09:15' 345)" "15:00" \
    "2) çeyrek saatli ofset dakikayı da doğru kaydırıyor (09:15 + 05:45)"
assert_fail _cron_shift_hhmm "abc" 180 \
    "2) geçersiz saat REDDEDİLİR"
assert_fail _cron_shift_hhmm "04:00" "xyz" \
    "2) geçersiz ofset REDDEDİLİR (BASH_REMATCH ezilme tuzağı — 'set -u' altında ölmemeli)"

# ═══════════════════════════════════════════════
#  3) OnCalendar AYRIŞTIRMA (_cron_calendar_tz_suffix / _body / _fixed_hhmm)
# ═══════════════════════════════════════════════
assert_eq "$(_cron_calendar_tz_suffix '*-*-* 04:00:00 UTC')" "UTC" \
    "3) ' UTC' soneki tanınıyor"
assert_eq "$(_cron_calendar_tz_suffix '*-*-* 04:00:00')" "" \
    "3) soneksiz ifade → sonek YOK (yerel saat)"
assert_eq "$(_cron_calendar_tz_suffix '*-*-* 04:00:00 Europe/Istanbul')" "Europe/Istanbul" \
    "3) IANA dilim adı soneki tanınıyor"
assert_eq "$(_cron_calendar_tz_suffix '*-*-* *:0/15:00')" "" \
    "3) TUZAK: 'her 15 dakikada' ifadesindeki '/' dilim adı SANILMIYOR"
assert_eq "$(_cron_calendar_tz_suffix 'Mon..Fri *-*-* 09:00:00 UTC')" "UTC" \
    "3) haftanın günü önekli ifadede de sonek doğru bulunuyor"
assert_eq "$(_cron_calendar_tz_suffix '')" "" \
    "3) boş ifade ÇÖKMEDEN boş sonek veriyor"

assert_eq "$(_cron_calendar_body '*-*-* 04:00:00 UTC')" "*-*-* 04:00:00" \
    "3) gövde = sonek çıkarılmış ifade"
assert_eq "$(_cron_calendar_body '*-*-* 04:00:00')" "*-*-* 04:00:00" \
    "3) soneksiz ifadenin gövdesi DEĞİŞMEZ"

assert_eq "$(_cron_calendar_fixed_hhmm '*-*-* 04:00:00 UTC')" "04:00" \
    "3) sabit saat çıkarılıyor (04:00)"
assert_eq "$(_cron_calendar_fixed_hhmm 'Mon..Fri *-*-* 09:30:00')" "09:30" \
    "3) haftanın günü önekli ifadeden de sabit saat çıkarılıyor"
assert_eq "$(_cron_calendar_fixed_hhmm '*-*-* *:0/15:00 UTC')" "" \
    "3) 'her 15 dakikada' için sabit saat YOK → BOŞ (uydurma yerel karşılık basılmaz)"
assert_eq "$(_cron_calendar_fixed_hhmm '*-*-* *:00:00 UTC')" "" \
    "3) 'her saat' için sabit saat YOK → BOŞ"

# ═══════════════════════════════════════════════
#  4) SAAT DİLİMİ TESPİTİ — test tohumu + yetenek tespiti (timedatectl YOK)
# ═══════════════════════════════════════════════
# (i) SRVCTL_TIMEZONE tohumu her şeyi ezer (testler böylece HOST'un GERÇEK
#     dilimine BAĞIMLI DEĞİLDİR).
SRVCTL_TIMEZONE="Europe/Istanbul"
assert_eq "$(_cron_server_timezone)" "Europe/Istanbul" \
    "4i) SRVCTL_TIMEZONE tohumu doğrudan kullanılıyor"
assert_eq "$(_cron_tz_offset_minutes)" "180" \
    "4i) Europe/Istanbul → +180 dakika (TZ + 'date +%z' — GNU ve BSD date'te AYNI)"
assert_eq "$(_cron_tz_display)" "Europe/Istanbul, UTC+03:00" \
    "4i) dilim etiketi hem AD hem OFSET içeriyor"

SRVCTL_TIMEZONE="UTC"
assert_eq "$(_cron_tz_offset_minutes)" "0" \
    "4ii) sunucu UTC'deyse ofset 0"
assert_eq "$(_cron_tz_display)" "UTC, UTC+00:00" \
    "4ii) UTC sunucuda etiket de UTC gösteriyor"

# (iii) Kötü niyetli/bozuk tohum: IANA ad karakter kümesi dışındaki değer
#       GÜVENİLMEZ sayılır (bu değer hem ekrana basılır hem 'TZ=' olur).
SRVCTL_TIMEZONE='Europe/Istanbul; rm -rf /'
assert_eq "$(_cron_server_timezone)" "" \
    "4iii) karakter kümesi dışı dilim adı REDDEDİLİYOR (boş dönüyor)"

# (iv) 'timedatectl' YOKKEN (bu macOS makinesinin DOĞAL durumu) tespit
#      zinciri ÇÖKMEZ — /etc/timezone → /etc/localtime symlink'i denenir,
#      hiçbiri yoksa BOŞ döner ve gösterim 'bilinmiyor' basar.
unset SRVCTL_TIMEZONE
if command -v timedatectl >/dev/null 2>&1; then
    echo "  UYARI: bu host'ta GERÇEK 'timedatectl' VAR — (4iv) 'yok' senaryosu ANLAMSIZ, ATLANDI"
else
    assert_ok _cron_server_timezone \
        "4iv) 'timedatectl' YOKKEN _cron_server_timezone ÇÖKMÜYOR (exit 0)"
    assert_ok _cron_tz_offset_minutes \
        "4iv) 'timedatectl' YOKKEN _cron_tz_offset_minutes ÇÖKMÜYOR (exit 0)"
    tzd_nodetect=$(_cron_tz_display)
    tzd_nonempty="hayir"; [[ -n "$tzd_nodetect" ]] && tzd_nonempty="evet"
    assert_eq "$tzd_nonempty" "evet" \
        "4iv) 'timedatectl' YOKKEN bile gösterim BOŞ kalmıyor (en kötü ihtimalle 'bilinmiyor')"
fi

# (v) 'timedatectl' VARMIŞ gibi davranan sahte ikili — Ubuntu'daki BİRİNCİ
#     tespit dalı GERÇEKTEN çalışıyor mu? (bu makinede o dal aksi hâlde HİÇ
#     çalıştırılamazdı — "ölç, tahmin etme").
TZ_FAKEBIN="$(mktemp -d)"
cat > "${TZ_FAKEBIN}/timedatectl" <<'EOF'
#!/bin/bash
# 'timedatectl show -p Timezone --value' taklidi (Ubuntu 22.04 ve 24.04'te
# AYNI sözdizimi — systemd 239+).
if [[ "${1:-}" == "show" ]]; then
    echo "Europe/Istanbul"
    exit 0
fi
exit 1
EOF
chmod +x "${TZ_FAKEBIN}/timedatectl"
OLD_PATH="$PATH"
export PATH="${TZ_FAKEBIN}:${PATH}"
assert_eq "$(_cron_server_timezone)" "Europe/Istanbul" \
    "4v) 'timedatectl' VARSA dilim ONDAN okunuyor (Ubuntu'daki birincil dal)"
assert_eq "$(_cron_tz_offset_minutes)" "180" \
    "4v) timedatectl'den gelen dilimden ofset doğru türetiliyor"
export PATH="$OLD_PATH"
rm -rf "$TZ_FAKEBIN"

# ═══════════════════════════════════════════════
#  5) GÖRÜNTÜLEME NOTU (_cron_schedule_tz_note) — dilim ASLA belirsiz kalmaz
# ═══════════════════════════════════════════════
SRVCTL_TIMEZONE="Europe/Istanbul"

note_local=$(_cron_schedule_tz_note '*-*-* 04:00:00')
assert_contains "$note_local" "sunucu yerel saati" \
    "5) soneksiz ifade 'sunucu yerel saati' diye NET biçimde etiketleniyor"
assert_contains "$note_local" "Europe/Istanbul" \
    "5) yerel notta sunucunun GERÇEK dilim adı da var"

note_utc=$(_cron_schedule_tz_note '*-*-* 04:00:00 UTC')
assert_contains "$note_utc" "UTC'de zamanlanmış" \
    "5) ESKİ (UTC'li) ifade AÇIKÇA işaretleniyor"
assert_contains "$note_utc" "07:00" \
    "5) ÜRETİM SENARYOSU: 04:00 UTC'nin YEREL karşılığı (07:00) gösteriliyor"

note_utc_dyn=$(_cron_schedule_tz_note '*-*-* *:0/15:00 UTC')
assert_contains "$note_utc_dyn" "UTC'de zamanlanmış" \
    "5) sabit saati OLMAYAN UTC ifadesi de işaretleniyor"
assert_not_contains "$note_utc_dyn" "denk geliyor" \
    "5) sabit saat yoksa YEREL KARŞILIK UYDURULMUYOR"

note_named=$(_cron_schedule_tz_note '*-*-* 04:00:00 Europe/Berlin')
assert_contains "$note_named" "Europe/Berlin" \
    "5) ham modda operatörün yazdığı dilim adı olduğu gibi gösteriliyor"

SRVCTL_TIMEZONE="UTC"
note_utc_on_utc=$(_cron_schedule_tz_note '*-*-* 04:00:00 UTC')
assert_contains "$note_utc_on_utc" "saat farkı YOK" \
    "5) sunucu UTC'deyse 'fark yok' denir (yanlış alarm üretilmez)"
SRVCTL_TIMEZONE="Europe/Istanbul"

assert_eq "$(_cron_schedule_tz_note '')" "bilinmiyor" \
    "5) OnCalendar okunamadıysa 'bilinmiyor' (uydurma YOK)"

# ═══════════════════════════════════════════════
#  6) AÇIKLAMA ÖNEKİ SOYMA (_cron_desc_user_part) — üretimde görülen kusur
# ═══════════════════════════════════════════════
assert_eq "$(_cron_desc_user_part 'srvctl Cron (dev.designwestgate.art / escapetest): Kacis+ampersand')" \
    "Kacis+ampersand" \
    "6) ÜRETİM ÖRNEĞİ: domain kapsamlı Description öneki SOYULUYOR"
assert_eq "$(_cron_desc_user_part 'srvctl Sistem Cron (nightly_backup): Gecelik yedek')" \
    "Gecelik yedek" \
    "6) sistem kapsamlı Description öneki de soyuluyor"
assert_eq "$(_cron_desc_user_part 'srvctl Cron Timer (example.com / job): Aciklama')" \
    "Aciklama" \
    "6) .timer dosyasının Description öneki de soyuluyor"
assert_eq "$(_cron_desc_user_part 'srvctl Cron (example.com / job): a): b')" \
    "a): b" \
    "6) KULLANICI metnindeki '): ' KORUNUYOR (yalnız İLK ayraca kadar soyulur)"
assert_eq "$(_cron_desc_user_part 'Elle yazılmış açıklama')" \
    "Elle yazılmış açıklama" \
    "6) srvctl öneki OLMAYAN açıklamaya DOKUNULMUYOR"
assert_eq "$(_cron_desc_user_part 'srvctl Cron (example.com / job): 50%% tamamlandi')" \
    "50% tamamlandi" \
    "6) systemd '%%' ikilemesi gösterimde GERİ ALINIYOR"
assert_eq "$(_cron_desc_user_part 'srvctl Cron (example.com / job): Kacis & ampersand')" \
    "Kacis & ampersand" \
    '6) & İÇEREN açıklama BOZULMUYOR (bash 5.2 desen-değiştirme tuzağı: replacement içindeki & EŞLEŞEN METNE genişler)'
assert_eq "$(_cron_desc_user_part '')" "" \
    "6) boş Description ÇÖKMEDEN boş dönüyor"

# ═══════════════════════════════════════════════
#  7) EPOCH → YEREL SAAT (_cron_fmt_epoch_usec) — 'Sonraki çalışma' alanı
# ═══════════════════════════════════════════════
# systemd sürümüne göre 'NextElapseUSecRealtime' HAM mikrosaniye gelebilir;
# operatöre ham sayı basmak "sonraki çalışma" sorusuna CEVAP DEĞİLDİR.
fmt_out=$(_cron_fmt_epoch_usec 1754110800000000)
if command -v date >/dev/null 2>&1; then
    assert_contains "$fmt_out" "2025-08-02" \
        "7) ham epoch mikrosaniye okunabilir YEREL damgaya çevriliyor"
fi
assert_eq "$(_cron_fmt_epoch_usec 'Sun 2026-08-02 07:00:00 +03')" "" \
    "7) zaten insan-okunur bir değer sayısal SANILMIYOR (boş döner, çağıran ham basar)"
assert_eq "$(_cron_fmt_epoch_usec '0')" "" \
    "7) sıfır damga çevrilmez (bilinmiyor demektir)"
assert_ok _cron_fmt_epoch_usec "" \
    "7) boş girdide ÇÖKMÜYOR (exit 0)"

# ═══════════════════════════════════════════════
#  8) UÇTAN UCA — 'cron add' VARSAYILANI vs '--utc'
# ═══════════════════════════════════════════════
systemctl_log="${WEB_ROOT}/.systemctl.log"
: > "$systemctl_log"
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    return 0
}

d="example.com"
sname=$(safe_name "$d")
mkdir -p "${WEB_ROOT}/${d}"
: > "${WEB_ROOT}/${d}/.credentials"

# (a) VARSAYILAN — sonek OLMAMALI. Ayrıca operatör, ekleme anında hangi
#     dilimde iş kurduğunu GÖRMELİ.
out_local=$(_cron_add "$d" --name=gece_bakim --schedule="her gün 04:00" \
    --command="echo bakim" --description="Gece bakimi" 2>&1)
rc_local=$?
assert_eq "$rc_local" "0" "8a) varsayılan (yerel) cron add BAŞARILI"
timer_local="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-gece_bakim.timer"
tc_local=$(cat "$timer_local" 2>/dev/null)
assert_contains "$tc_local" "OnCalendar=*-*-* 04:00:00" \
    "8a) OnCalendar doğru hesaplandı"
assert_not_contains "$tc_local" "UTC" \
    "8a) VARSAYILAN: unit dosyasında ' UTC' soneki HİÇ YOK (yerel saat)"
assert_contains "$out_local" "SUNUCUNUN YEREL saatine göre" \
    "8a) 'cron add' hangi dilimde kurulduğunu AÇIKÇA bildiriyor"
assert_contains "$out_local" "Europe/Istanbul" \
    "8a) bildirimde sunucunun GERÇEK dilimi yazıyor"
assert_contains "$out_local" "--utc" \
    "8a) UTC'ye sabitleme seçeneği operatöre HATIRLATILIYOR"

# (b) '--utc' — ESKİ davranış AÇIK tercih olarak geri geliyor VE operatör
#     yerel karşılık konusunda UYARILIYOR (sürpriz bırakılmaz).
out_utc=$(_cron_add "$d" --name=global_job --schedule="her gün 04:00" \
    --command="echo global" --description="Cok bolgeli is" --utc 2>&1)
rc_utc=$?
assert_eq "$rc_utc" "0" "8b) '--utc' ile cron add BAŞARILI"
timer_utc="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-global_job.timer"
tc_utc=$(cat "$timer_utc" 2>/dev/null)
assert_contains "$tc_utc" "OnCalendar=*-*-* 04:00:00 UTC" \
    "8b) '--utc' verilince ' UTC' soneki unit'e GERÇEKTEN yazılıyor"
assert_contains "$out_utc" "UTC'ye SABİTLENDİ" \
    "8b) 'cron add' UTC'ye sabitlendiğini AÇIKÇA söylüyor"
assert_contains "$out_utc" "07:00" \
    "8b) '--utc' seçilince YEREL karşılık (07:00) UYARI olarak basılıyor — üretim sürprizinin panzehiri"

# (c) Ham modda '--utc' YOK SAYILIR (ve bu SESSİZ değildir).
out_raw=$(_cron_add "$d" --name=ham_job --schedule='*-*-01 02:00:00' \
    --command="echo ham" --utc 2>&1)
timer_raw="${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-ham_job.timer"
tc_raw=$(cat "$timer_raw" 2>/dev/null)
assert_contains "$tc_raw" "OnCalendar=*-*-01 02:00:00" \
    "8c) ham ifade OLDUĞU GİBİ yazılıyor"
assert_not_contains "$tc_raw" "02:00:00 UTC" \
    "8c) ham modda srvctl ifadeye sonek EKLEMİYOR"
assert_contains "$out_raw" "YOK SAYILDI" \
    "8c) ham modda '--utc'nin yok sayıldığı AÇIKÇA uyarılıyor (sessiz atlama YOK)"

# (d) Bilinmeyen bayrak hâlâ reddediliyor (bayrak ayrıştırıcısı bozulmadı).
# '_run_isolated' KASITLI (tests/test_cron_add.sh İLE AYNI desen): _cron_add
# içindeki 'error' EXIT eder — alt kabuk olmadan test dosyasının KENDİSİ ölürdü.
_run_isolated() { ( "$@" ); }
assert_fail _run_isolated _cron_add "$d" --name=bilinmeyen_bayrak \
    --schedule="her saat" --command="echo x" --utcx \
    "8d) benzer görünümlü bilinmeyen bayrak ('--utcx') hâlâ REDDEDİLİYOR"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-bilinmeyen_bayrak.timer")" "yok" \
    "8d) reddedilen bayrak için HİÇBİR unit dosyası oluşmadı"

# ═══════════════════════════════════════════════
#  9) ESKİ (UTC'li) CRON'LAR — SESSİZCE KAYDIRILMIYOR, AÇIKÇA İŞARETLENİYOR
# ═══════════════════════════════════════════════
# (i) Görüntüleme komutları unit dosyasını ASLA yeniden yazmaz (görev şartı:
#     "var olan bir cron'un zamanlamasını sessizce yeniden yazma").
before_utc=$(cat "$timer_utc")
_cron_list "$d" >/dev/null 2>&1
_cron_show "$d" global_job >/dev/null 2>&1
after_utc=$(cat "$timer_utc")
assert_eq "$after_utc" "$before_utc" \
    "9i) 'list'/'show' ESKİ (UTC'li) unit dosyasını DEĞİŞTİRMİYOR — sessiz kaydırma YOK"

# (ii) 'cron list' hem sunucu dilimini hem UTC işaretini gösteriyor.
list_out=$(_cron_list "$d" 2>&1)
assert_contains "$list_out" "sunucu saat dilimi: Europe/Istanbul, UTC+03:00" \
    "9ii) 'cron list' başlığı sunucunun GERÇEK dilimini basıyor (eski 'UTC'ye göre' başlığı KALKTI)"
assert_not_contains "$list_out" "zamanlama UTC'ye göre" \
    "9ii) YANILTICI eski başlık metni ARTIK YOK"
assert_contains "$list_out" "Zaman dilimi" \
    "9ii) her cron satırında ayrı bir 'Zaman dilimi' alanı var"
assert_contains "$list_out" "UTC'de zamanlanmış" \
    "9ii) UTC'li cron 'cron list'te AÇIKÇA işaretleniyor"
assert_contains "$list_out" "07:00" \
    "9ii) UTC'li cron'un YEREL karşılığı (04:00 UTC → 07:00) listede görünüyor"
assert_contains "$list_out" "1 cron UTC'ye SABİTLENMİŞ" \
    "9ii) 'cron list' sonunda kaç cron'un eski varsayılanla kurulduğu ÖZETLENİYOR"

# (iii) Yerel (yeni varsayılan) cron YANLIŞLIKLA 'UTC' diye işaretlenmiyor.
show_local=$(_cron_show "$d" gece_bakim 2>&1)
assert_contains "$show_local" "sunucu yerel saati" \
    "9iii) yerel cron 'cron show'da 'sunucu yerel saati' diye etiketleniyor"
assert_not_contains "$show_local" "UTC'de zamanlanmış" \
    "9iii) yerel cron YANLIŞLIKLA UTC işareti ALMIYOR (yanlış pozitif yok)"

# (iv) 'cron show' UTC'li cron için yerel karşılığı da basıyor.
show_utc=$(_cron_show "$d" global_job 2>&1)
assert_contains "$show_utc" "OnCalendar       : *-*-* 04:00:00 UTC" \
    "9iv) 'cron show' ham OnCalendar'ı (UTC sonekiyle) gösteriyor"
assert_contains "$show_utc" "UTC'de zamanlanmış" \
    "9iv) 'cron show' UTC'ye sabitlenmiş cron'u işaretliyor"
assert_contains "$show_utc" "07:00" \
    "9iv) 'cron show' yerel karşılığı (07:00) gösteriyor"
assert_contains "$show_utc" "Sunucu dilimi    : Europe/Istanbul, UTC+03:00" \
    "9iv) 'cron show' sunucunun dilimini AYRI bir alanda basıyor"

# (v) Sunucu dilimi UTC olsaydı aynı unit 'fark yok' derdi — gösterim
#     SUNUCUYA GÖRE doğru uyarlanıyor (sabit metin DEĞİL).
SRVCTL_TIMEZONE="UTC"
show_utc_on_utc=$(_cron_show "$d" global_job 2>&1)
assert_contains "$show_utc_on_utc" "saat farkı YOK" \
    "9v) sunucu UTC'deyken AYNI unit için 'fark yok' deniyor (gösterim sunucuya uyarlanıyor)"
SRVCTL_TIMEZONE="Europe/Istanbul"

# ═══════════════════════════════════════════════
#  10) AÇIKLAMA ALANI — ÖNEK SOYULMUŞ hâliyle görünüyor (üretim kusuru)
# ═══════════════════════════════════════════════
assert_contains "$list_out" "Açıklama       : Gece bakimi" \
    "10) 'cron list' YALNIZ kullanıcının açıklamasını basıyor"
assert_not_contains "$list_out" "Açıklama       : srvctl Cron" \
    "10) systemd 'Description=' ÖNEKİ artık 'cron list'te GÖRÜNMÜYOR (ölçülen kusur)"
assert_contains "$show_local" "Açıklama         : Gece bakimi" \
    "10) 'cron show' de yalnız kullanıcının açıklamasını basıyor"
assert_not_contains "$show_local" "Açıklama         : srvctl Cron" \
    "10) 'cron show' açıklamasında da önek YOK"

# ═══════════════════════════════════════════════
#  11) ERREXIT DUMANI — GERÇEK çalışma koşulu 'set -euo pipefail'
# ═══════════════════════════════════════════════
# bin/srvctl 'set -euo pipefail' ile başlar; bu test dosyası İSE (diğerleri
# gibi) yalnız 'set -uo pipefail' kullanır. Aradaki fark GERÇEK bir hata
# sınıfını gizler: 1 dönen bir yardımcıya yapılan ÇIPLAK 'var=$(...)' ataması
# errexit ALTINDA çağıranı ÖLDÜRÜR ama errexit'siz testte SESSİZCE geçer
# (_cron_offset_label/_cron_shift_hhmm/_cron_parse_offset_minutes ÜÇÜ DE
# tanınmayan girdide 1 döner). Bu blok tüm dilim/gösterim zincirini
# GERÇEKTEN errexit altında çalıştırır.
_errexit_probe() {
    (
        set -euo pipefail
        SRVCTL_TIMEZONE="Europe/Istanbul"
        _cron_tz_display >/dev/null
        _cron_schedule_tz_note '*-*-* 04:00:00 UTC' >/dev/null
        _cron_schedule_tz_note '*-*-* 04:00:00' >/dev/null
        _cron_schedule_tz_note '*-*-* *:0/15:00 UTC' >/dev/null
        _cron_schedule_tz_note '' >/dev/null
        _cron_next_run "srvctl-cron-yok.timer" >/dev/null
        _cron_desc_user_part 'srvctl Cron (a.com / j): x' >/dev/null
        # Dilim HİÇ tespit edilemediğinde de (boş ad + boş ofset) zincir
        # ölmemeli — 'bilinmiyor' basıp devam etmeli.
        SRVCTL_TIMEZONE=""
        PATH="/nonexistent-srvctl-test" _cron_tz_display >/dev/null
        _cron_list "$1" >/dev/null
        _cron_show "$1" gece_bakim >/dev/null
    )
}
assert_ok _errexit_probe "$d" \
    "11) tüm dilim/gösterim zinciri 'set -euo pipefail' ALTINDA da çökmüyor (çıplak atama tuzağı)"

_errexit_add_probe() {
    (
        set -euo pipefail
        SRVCTL_TIMEZONE="Europe/Istanbul"
        _cron_add "$1" --name=errexit_job --schedule="her gün 04:00" \
            --command="echo x" --description="Errexit" >/dev/null 2>&1
    )
}
assert_ok _errexit_add_probe "$d" \
    "11) 'cron add' (yerel varsayılan yolu) errexit altında BAŞARILI"

_errexit_add_utc_probe() {
    (
        set -euo pipefail
        SRVCTL_TIMEZONE="Europe/Istanbul"
        _cron_add "$1" --name=errexit_utc_job --schedule="her gün 04:00" \
            --command="echo x" --description="Errexit UTC" --utc >/dev/null 2>&1
    )
}
assert_ok _errexit_add_utc_probe "$d" \
    "11) 'cron add --utc' (yerel karşılık uyarısı dahil) errexit altında BAŞARILI"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR" "$SRVCTL_LOCK_DIR"
test_summary
