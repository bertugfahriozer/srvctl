#!/bin/bash
# lib/cron.sh — zaman çevirici SAF fonksiyonların kapsamlı fixture testi.
#
# Bu, "kullanıcı dostu cron" özelliğinin EN KRİTİK parçasıdır (görev
# tanımı): üç girdi biçiminin (Türkçe kısayol / 5 alanlı cron sözdizimi /
# ham systemd) HER BİRİ, geçersiz girdilerin REDDİ ve sınır durumlar burada
# kilitlenir. Tüm çeviriciler saf fonksiyondur (yan etkisiz, girdi→çıktı) —
# gerçek systemd/dosya sistemi/servis GEREKMEZ, macOS'ta tam çalışır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/cron.sh"

# ═══════════════════════════════════════════════
#  1) TÜRKÇE KISAYOL — _cron_translate_turkish
# ═══════════════════════════════════════════════

assert_eq "$(_cron_translate_turkish 'her gün 03:00')" "*-*-* 03:00:00" \
    "Türkçe: 'her gün SS:DD' temel biçim"
assert_eq "$(_cron_translate_turkish 'her gün 3:00')" "*-*-* 03:00:00" \
    "Türkçe: tek haneli saat 2 haneye tamamlanıyor"
assert_fail _cron_translate_turkish "her gün 24:00" \
    "Türkçe: saat 24 GEÇERSİZ (0-23 aralığı)"
assert_fail _cron_translate_turkish "her gün 03:60" \
    "Türkçe: dakika 60 GEÇERSİZ (0-59 aralığı)"

assert_eq "$(_cron_translate_turkish 'her 15 dakikada')" "*-*-* *:0/15:00" \
    "Türkçe: 'her N dakikada' temel biçim"
assert_eq "$(_cron_translate_turkish 'her 1 dakikada')" "*-*-* *:0/1:00" \
    "Türkçe: N=1 sınır durumu kabul edilir"
assert_eq "$(_cron_translate_turkish 'her 59 dakikada')" "*-*-* *:0/59:00" \
    "Türkçe: N=59 sınır durumu kabul edilir"
assert_fail _cron_translate_turkish "her 0 dakikada" \
    "Türkçe: N=0 REDDEDİLİR (adım en az 1 olmalı)"
assert_fail _cron_translate_turkish "her 60 dakikada" \
    "Türkçe: N=60 REDDEDİLİR (bir saatten fazla adım anlamsız)"

assert_eq "$(_cron_translate_turkish 'her saat')" "*-*-* *:00:00" \
    "Türkçe: 'her saat' temel biçim"
assert_fail _cron_translate_turkish "her saatte" \
    "Türkçe: 'her saatte' (yanlış kelime) REDDEDİLİR"

assert_eq "$(_cron_translate_turkish 'her pazartesi 04:30')" "Mon *-*-* 04:30:00" \
    "Türkçe: 'her pazartesi SS:DD' → Mon"
assert_eq "$(_cron_translate_turkish 'her sali 10:00')" "Tue *-*-* 10:00:00" \
    "Türkçe: ASCII-katlanmış 'sali' → Tue kabul edilir"
assert_eq "$(_cron_translate_turkish 'her çarşamba 10:00')" "Wed *-*-* 10:00:00" \
    "Türkçe: 'çarşamba' → Wed"
assert_eq "$(_cron_translate_turkish 'her perşembe 10:00')" "Thu *-*-* 10:00:00" \
    "Türkçe: 'perşembe' → Thu"
assert_eq "$(_cron_translate_turkish 'her cuma 23:59')" "Fri *-*-* 23:59:00" \
    "Türkçe: 'cuma' → Fri, 23:59 sınır durumu"
assert_eq "$(_cron_translate_turkish 'her cumartesi 00:00')" "Sat *-*-* 00:00:00" \
    "Türkçe: 'cumartesi' → Sat, 00:00 sınır durumu"
assert_eq "$(_cron_translate_turkish 'her pazar 12:00')" "Sun *-*-* 12:00:00" \
    "Türkçe: 'pazar' → Sun"
assert_fail _cron_translate_turkish "her marsgünü 04:30" \
    "Türkçe: tanınmayan gün adı REDDEDİLİR"

assert_eq "$(_cron_translate_turkish "ayın 1'i 02:00")" "*-*-01 02:00:00" \
    "Türkçe: \"ayın N'i SS:DD\" temel biçim"
assert_eq "$(_cron_translate_turkish "ayın 2'si 02:00")" "*-*-02 02:00:00" \
    "Türkçe: farklı iyelik eki ('si') kabul edilir"
assert_eq "$(_cron_translate_turkish 'ayın 1 02:00')" "*-*-01 02:00:00" \
    "Türkçe: iyelik eki OLMADAN da kabul edilir (lenient)"
assert_eq "$(_cron_translate_turkish "ayın 31'i 23:59")" "*-*-31 23:59:00" \
    "Türkçe: ayın günü üst sınırı (31) kabul edilir"
assert_fail _cron_translate_turkish "ayın 32'si 10:00" \
    "Türkçe: ayın günü 32 REDDEDİLİR (1-31 aralığı dışı)"
assert_fail _cron_translate_turkish "ayın 0'ı 10:00" \
    "Türkçe: ayın günü 0 REDDEDİLİR"

assert_eq "$(_cron_translate_turkish 'hafta içi 09:00')" "Mon..Fri *-*-* 09:00:00" \
    "Türkçe: 'hafta içi SS:DD' → Mon..Fri"

# ── Reddedilmesi gereken/biçime uymayan girdiler ──
assert_fail _cron_translate_turkish "" \
    "Türkçe: boş girdi REDDEDİLİR"
assert_fail _cron_translate_turkish "Her gün 03:00" \
    "Türkçe: BÜYÜK HARF 'Her' REDDEDİLİR (küçük harf zorunlu, tasarım kararı)"
assert_fail _cron_translate_turkish "her gün" \
    "Türkçe: eksik saat kısmı REDDEDİLİR"
assert_fail _cron_translate_turkish "rastgele bir metin" \
    "Türkçe: alakasız serbest metin REDDEDİLİR"
assert_fail _cron_translate_turkish "0 3 * * *" \
    "Türkçe çevirici: standart cron sözdizimini KENDİSİ çevirmez (ayrı çevirici — çakışma yok)"

# ═══════════════════════════════════════════════
#  2) STANDART 5 ALANLI CRON SÖZDİZİMİ — _cron_translate_cron5
# ═══════════════════════════════════════════════

assert_ok  _cron_looks_like_cron5 "0 3 * * *"
assert_fail _cron_looks_like_cron5 "0 3 * *"
assert_fail _cron_looks_like_cron5 "her gün 03:00"

assert_eq "$(_cron_translate_cron5 '0 3 * * *')" "*-*-* 03:00:00" \
    "cron5: '0 3 * * *' → günlük 03:00 (görev örneği)"
assert_eq "$(_cron_translate_cron5 '*/15 * * * *')" "*-*-* *:*/15:00" \
    "cron5: dakika alanında '*/15' adımı korunur"
assert_eq "$(_cron_translate_cron5 '0 9 * * 1-5')" "Mon..Fri *-*-* 09:00:00" \
    "cron5: haftanın_günü ARALIĞI (1-5) → Mon..Fri (hafta içi ile eşdeğer)"
assert_eq "$(_cron_translate_cron5 '30 4 1 * *')" "*-*-01 04:30:00" \
    "cron5: ayın_günü=1 → *-*-01 (ayın 1'i ile eşdeğer)"
assert_eq "$(_cron_translate_cron5 '0 3 * * 0')" "Sun *-*-* 03:00:00" \
    "cron5: tekil haftanın_günü=0 → Sun (0=Pazar)"
assert_eq "$(_cron_translate_cron5 '0 3 * * 7')" "Sun *-*-* 03:00:00" \
    "cron5: haftanın_günü=7 de Pazar sayılır (0 ile eşdeğer)"
assert_eq "$(_cron_translate_cron5 '1,2,3 4 * * *')" "*-*-* 04:01,02,03:00" \
    "cron5: dakika alanında virgüllü liste korunur"

assert_fail _cron_translate_cron5 "0 3 1 * 1" \
    "cron5: ayın_günü VE haftanın_günü AYNI ANDA kısıtlıysa REDDEDİLİR (OR semantiği tek satırda ifade edilemez — bilinçli sınır)"
assert_fail _cron_translate_cron5 "60 3 * * *" \
    "cron5: dakika 60 REDDEDİLİR (0-59 aralığı dışı)"
assert_fail _cron_translate_cron5 "0 24 * * *" \
    "cron5: saat 24 REDDEDİLİR (0-23 aralığı dışı)"
assert_fail _cron_translate_cron5 "0 3 * * 8" \
    "cron5: haftanın_günü 8 REDDEDİLİR (0-7 aralığı dışı)"
assert_fail _cron_translate_cron5 "0 3 32 * *" \
    "cron5: ayın_günü 32 REDDEDİLİR (1-31 aralığı dışı)"
assert_fail _cron_translate_cron5 "0 3 * 13 *" \
    "cron5: ay 13 REDDEDİLİR (1-12 aralığı dışı)"
assert_fail _cron_translate_cron5 "abc 3 * * *" \
    "cron5: sayısal olmayan alan REDDEDİLİR"

# ─── _cron_field_translate: alt küme dışı birleşik biçimler REDDEDİLMELİ ───
assert_fail _cron_field_translate "10-20/5" 0 59 num \
    "field_translate: 'a-b/N' birleşik biçimi DESTEKLENMİYOR (bilinçli sınır)"
assert_fail _cron_field_translate "*/0" 0 59 num \
    "field_translate: '*/0' adımı REDDEDİLİR (en az 1 olmalı)"
assert_fail _cron_field_translate "*/5" 0 7 dow \
    "field_translate: haftanın_günü alanında '*/N' adımı DESTEKLENMİYOR"
assert_eq "$(_cron_field_translate '1-5' 0 7 dow)" "Mon..Fri" \
    "field_translate: haftanın_günü ARALIĞI isimlere çevrilir"
assert_eq "$(_cron_field_translate '*' 0 59 num)" "*" \
    "field_translate: '*' aynen korunur"

# ═══════════════════════════════════════════════
#  3) HAM SYSTEMD MODU — _cron_calendar_charset_ok
# ═══════════════════════════════════════════════

assert_ok  _cron_calendar_charset_ok "*-*-01 02:00:00"
assert_ok  _cron_calendar_charset_ok "Mon..Fri *-*-* 09:00:00 UTC"
assert_ok  _cron_calendar_charset_ok "*-*-* 03:00:00 Europe/Istanbul"
assert_ok  _cron_calendar_charset_ok "*-*~1 04:00:00"
assert_fail _cron_calendar_charset_ok "" \
    "ham mod: boş girdi REDDEDİLİR"
assert_fail _cron_calendar_charset_ok '*-*-* 03:00:00; rm -rf /' \
    "ham mod: ';' İÇEREN girdi REDDEDİLİR (unit dosyası enjeksiyon savunması)"
assert_fail _cron_calendar_charset_ok '*-*-* 03:00:00 = evil' \
    "ham mod: '=' İÇEREN girdi REDDEDİLİR (yeni Key=Value satırı taklidi savunması)"
assert_fail _cron_calendar_charset_ok "\$(whoami)" \
    "ham mod: kabuk komut ikamesi karakterleri REDDEDİLİR"
assert_fail _cron_calendar_charset_ok "%i" \
    "ham mod: '%' (systemd specifier) REDDEDİLİR"

# ═══════════════════════════════════════════════
#  4) DAĞITICI — _cron_resolve_schedule (üç biçim + yerel/UTC dilim kararı)
#
#  KARAR DEĞİŞTİ (GERÇEK üretim sunucusunda ölçüldü — Europe/Istanbul/+03):
#  'her gün 04:00' ESKİDEN 'OnCalendar=*-*-* 04:00:00 UTC' yazıyordu ve iş
#  sabah 07:00'de çalışıyordu. Varsayılan artık SUNUCU YEREL SAATİ (sonek
#  YOK); UTC AÇIK bir '--utc' bayrağına (tz_mode='utc') taşındı.
# ═══════════════════════════════════════════════

assert_eq "$(_cron_resolve_schedule 'her gün 03:00')" "turkish *-*-* 03:00:00" \
    "resolve: VARSAYILAN Türkçe yolda ' UTC' soneki EKLENMEZ (yerel saat — yazdığın saat çalışan saattir)"
assert_eq "$(_cron_resolve_schedule '0 3 * * *')" "cron5 *-*-* 03:00:00" \
    "resolve: VARSAYILAN cron5 yolunda da ' UTC' soneki EKLENMEZ"
assert_eq "$(_cron_resolve_schedule 'her gün 03:00' local)" "turkish *-*-* 03:00:00" \
    "resolve: tz_mode='local' AÇIKÇA verilse de sonek EKLENMEZ (varsayılanla AYNI)"
assert_eq "$(_cron_resolve_schedule 'her gün 03:00' utc)" "turkish *-*-* 03:00:00 UTC" \
    "resolve: tz_mode='utc' ('--utc') ESKİ davranışı BİREBİR geri getirir"
assert_eq "$(_cron_resolve_schedule '0 3 * * *' utc)" "cron5 *-*-* 03:00:00 UTC" \
    "resolve: cron5 + '--utc' → ' UTC' soneki yazılır"
assert_eq "$(_cron_resolve_schedule '*-*-01 02:00:00')" "raw *-*-01 02:00:00" \
    "resolve: ham yol seçilir, HİÇBİR ŞEY EKLENMEZ/DEĞİŞTİRİLMEZ (operatör sorumluluğu)"
assert_eq "$(_cron_resolve_schedule '*-*-01 02:00:00' utc)" "raw *-*-01 02:00:00" \
    "resolve: ham yolda '--utc' YOK SAYILIR — operatörün ifadesine ASLA sonek eklenmez"
assert_fail _cron_resolve_schedule "0 3 1 * 1" \
    "resolve: cron5 ŞEKLİNDE (5 alan) ama semantik olarak GEÇERSİZ girdi HAM MODA DÜŞMEZ — net hata (yanlış yorumlamaktansa)"
assert_fail _cron_resolve_schedule "" \
    "resolve: boş girdi tamamen REDDEDİLİR"
assert_fail _cron_resolve_schedule $'her gün\n03:00' \
    "resolve: girdiye gömülü satırsonu üç biçimden HİÇBİRİNE uymaz → reddedilir"

# Aynı zamanlamanın Türkçe/cron5/eşdeğerleri BİREBİR AYNI OnCalendar GÖVDESİNİ
# üretmeli (MOD alanı — 'turkish'/'cron5' — kasıtlı olarak farklıdır, yalnız
# takvim gövdesi karşılaştırılır: 'read' ile İLK alan atılır).
turkish_out=$(_cron_resolve_schedule 'hafta içi 09:00')
cron5_out=$(_cron_resolve_schedule '0 9 * * 1-5')
turkish_cal="" cron5_cal=""
read -r _ turkish_cal <<< "$turkish_out"
read -r _ cron5_cal <<< "$cron5_out"
assert_eq "$turkish_cal" "$cron5_cal" \
    "çapraz-doğrulama: 'hafta içi 09:00' ile '0 9 * * 1-5' AYNI OnCalendar gövdesini üretir"

turkish_out2=$(_cron_resolve_schedule "ayın 1'i 04:30")
cron5_out2=$(_cron_resolve_schedule '30 4 1 * *')
turkish_cal2="" cron5_cal2=""
read -r _ turkish_cal2 <<< "$turkish_out2"
read -r _ cron5_cal2 <<< "$cron5_out2"
assert_eq "$turkish_cal2" "$cron5_cal2" \
    "çapraz-doğrulama: \"ayın 1'i 04:30\" ile '30 4 1 * *' AYNI OnCalendar gövdesini üretir"

# ═══════════════════════════════════════════════
#  5) İSİM DOĞRULAMA — _cron_ident_ok (assert_safe_ident üzerine, YENİ regex YOK)
# ═══════════════════════════════════════════════

assert_ok  _cron_ident_ok "backup_1"
assert_ok  _cron_ident_ok "cacheClear"
assert_fail _cron_ident_ok "" \
    "isim: boş REDDEDİLİR"
assert_fail _cron_ident_ok "../../etc/systemd/system/evil" \
    "isim: path traversal denemesi REDDEDİLİR (KRİTİK — unit dosya adına gömülüyor)"
assert_fail _cron_ident_ok "a/b" \
    "isim: '/' İÇEREN ad REDDEDİLİR"
assert_fail _cron_ident_ok "with space" \
    "isim: boşluk İÇEREN ad REDDEDİLİR"
assert_fail _cron_ident_ok "$(printf 'a%.0s' $(seq 1 51))" \
    "isim: 51 karakter REDDEDİLİR (azami 50)"
assert_ok  _cron_ident_ok "$(printf 'a%.0s' $(seq 1 50))"

# ═══════════════════════════════════════════════
#  6) KAÇIŞ YARDIMCILARI — /bin/sh -c '...' sözleşmesi (ŞABLONLA MODÜL
#     ARASINDAKİ EN KRİTİK SINIR — koordinatör talebiyle AYRICA vurgulandı)
# ═══════════════════════════════════════════════

# NOT — SÖZLEŞME DEĞİŞTİ: eskiden komut İKİ kabuk katmanından geçiyordu
# (dıştaki 'sh -c' + içteki 'flock ... -c') ve kaçış İKİ KEZ uygulanıyordu.
# Bu, GERÇEK üretim sunucusunda ölçülen bir hataya yol açtı: birinci geçişin
# ürettiği dizi ikinci geçişte yeniden işlenip dengesiz kalıyordu —
#   komut: echo 'tirnak testi'
#   sonuç: sh: testi''''': 1: Syntax error: Unterminated quoted string (exit 2)
# Çözüm: flock artık ExecStart'ın BAŞINA prefix olarak geliyor (FLOCK_PREFIX
# token'ı), kabuk katmanı BİRE indi ve kaçış TEK KEZ uygulanıyor.
#
# Kaçış artık POSIX kabuk kuralı ('\'') DEĞİL, systemd'nin UNIT DOSYASI
# kuralı: tek tırnak içinde '\' → '\\' ve "'" → "\'". Çünkü tırnakları
# kaldıran taraf kabuk değil systemd'nin kendi ayrıştırıcısıdır.
assert_eq "$(_cron_escape_unit_squote "it's a test")" "it\\'s a test" \
    "tek-tırnak kaçışı: TEK tırnak systemd kuralıyla kaçırılıyor"
assert_eq "$(_cron_escape_unit_squote "a'b'c")" "a\\'b\\'c" \
    "tek-tırnak kaçışı: BİRDEN FAZLA tek tırnak doğru kaçırılıyor"
assert_eq "$(_cron_escape_unit_squote "no quotes here")" "no quotes here" \
    "tek-tırnak kaçışı: tırnak yoksa DEĞİŞMEZ"
assert_eq "$(_cron_escape_unit_squote 'a\b')" 'a\\b' \
    "ters bölü kaçışı: '\\' ikileniyor (systemd onu kaçış karakteri sayar)"
assert_eq "$(_cron_escape_percent "50% tamamlandı")" "50%% tamamlandı" \
    "'%' ikilemesi: literal '%' doğru ikileniyor (systemd specifier savunması)"
assert_eq "$(_cron_escape_percent "no percent")" "no percent" \
    "'%' ikilemesi: '%' yoksa DEĞİŞMEZ"

# ── Uçtan uca: tek tırnak + '%' AYNI ANDA içeren bir KOMUT (koordinatör:
# "ikisini birden içeren komut" fixture'ı AÇIKÇA istendi), _cron_add()'İN
# GERÇEKTEN uyguladığı sırayla (bkz. o fonksiyonun "Kabuk sarmalama + kaçış"
# bölümü): kullanıcının ham komutu → TEK TIRNAK kaçışı (şablonun
# 'ExecStart=/bin/sh -c '{{CRON_COMMAND}}'' bağlamı İÇİN) → '%' ikilemesi
# (EN SON adım, systemd'nin specifier genişletmesine karşı). Sonucu GERÇEK
# bir /bin/sh'a vererek (yalnız string eşitliği DEĞİL) orijinal komutun
# AYNEN çalıştığını doğruluyoruz.
# systemd'nin TEK TIRNAKLI unit argümanını açma kuralının test-yerel
# emülatörü. NEDEN ELLE YAZILDI: bu hatayı iki kez KAÇIRDIK, iki seferde de
# aynı sebeple — doğrulama sırasında araya KENDİ kabuk katmanımızı koyduk
# (bir kez testte 'sh -c "$satır"', bir kez elle SSH heredoc + bash -c ile).
# O fazladan katman, systemd'nin YAPMADIĞI bir kabuk yorumu ekleyip dizgiyi
# değiştirdiği için test/ölçüm "çalışıyor" derken üretim patlıyordu.
# Burada systemd'nin ayrıştırmasını AÇIKÇA taklit ediyoruz: tırnak içindeki
# '\\' → '\' ve "\'" → "'". Tek geçişte, soldan sağa — çünkü iki ayrı
# değiştirme yapmak '\\'' gibi dizilerde birinci geçişin çıktısını ikinci
# geçişin yeniden işlemesine yol açar (bozulan eski tasarımın aynı hatası).
_systemd_unquote_single() {
    local s="$1" out="" i=0 c n
    while (( i < ${#s} )); do
        c="${s:i:1}"
        if [[ "$c" == '\' ]]; then
            n="${s:i+1:1}"
            case "$n" in
                '\'|"'") out+="$n"; i=$((i + 2)); continue ;;
            esac
        fi
        out+="$c"; i=$((i + 1))
    done
    printf '%s' "$out"
}

raw_cmd='echo "it'"'"'s a test with 50% completion"'
# raw_cmd, GERÇEKTEN çalıştırıldığında ne üretir? (beklenen sonuç — kaçıştan
# TAMAMEN bağımsız, referans değer)
expected=$(sh -c "$raw_cmd" 2>/dev/null)
assert_eq "$expected" "it's a test with 50% completion" \
    "test fixture'ı doğru kuruldu: raw_cmd GERÇEKTEN tek tırnak + '%' içeriyor"

cron_command_value=$(_cron_escape_percent "$(_cron_escape_unit_squote "$raw_cmd")")
# systemd, ExecStart satırını ('/bin/sh -c '{{CRON_COMMAND}}'' — ŞABLONUN
# KENDİSİ, bkz. srvctl-cron.service.tpl) ayrıştırırken HEM '%' specifier
# ikilemesini GERİ ALIR HEM DE tek tırnakları KABUK-BENZERİ KURALLARLA
# kaldırıp içeriği argv[2] olarak /bin/sh'a verir. Testte gerçek systemd
# YOK — '%' geri alma ELLE simüle edilir; tek-tırnak kaldırma İSE gerçek bir
# kabuğa (dıştaki 'sh -c') DEĞERİ ŞABLONDAKİ GİBİ TEK TIRNAK İÇİNE KOYARAK
# devredilir (yalnız string manipülasyonu DEĞİL, GERÇEK kabuk ayrıştırması).
# systemd'nin ExecStart satırını işleme sırası (şablon:
# 'ExecStart={{FLOCK_PREFIX}}/bin/sh -c '{{CRON_COMMAND}}''):
#   1) '%' specifier genişletmesi — '%%' tekrar tek '%' olur
#   2) tek tırnaklı argümanın açılması — argv[2] olarak /bin/sh'a verilir
after_systemd_percent_undo="${cron_command_value//%%/%}"
argv2=$(_systemd_unquote_single "$after_systemd_percent_undo")

# ÖNCE round-trip: systemd'nin açması ham komutu BİREBİR geri vermeli.
# Bu assertion, kabuk hiç çalıştırılmadan kaçış zincirinin doğruluğunu
# kanıtlar — bozuk çift kaçış tam olarak BURADA yakalanırdı.
assert_eq "$argv2" "$raw_cmd" \
    "uçtan uca: kaçış→systemd açması round-trip'i ham komutu BİREBİR geri veriyor"

# SONRA gerçek çalıştırma: argv[2] tam olarak systemd'nin vereceği değer;
# araya BAŞKA bir kabuk yorumu KOYULMUYOR (yanlış-negatifin kaynağı buydu).
reconstructed=$(sh -c "$argv2" 2>/dev/null)
assert_eq "$reconstructed" "$expected" \
    "uçtan uca: tek-tırnak+'%' içeren komut, systemd'nin vereceği argv[2] ile GERÇEK kabukta orijinaliyle AYNI çalışıyor"

# ═══════════════════════════════════════════════
#  7) UNIT ADLANDIRMA — çakışmayan ad uzayı (cron/cronfail, syscron/syscronfail)
# ═══════════════════════════════════════════════

svc=$(_cron_svc_name "example_com" "backup")
assert_eq "$svc" "srvctl-cron-example_com-backup.service" "domain cron .service adı"
timer=$(_cron_timer_name "example_com" "backup")
assert_eq "$timer" "srvctl-cron-example_com-backup.timer" "domain cron .timer adı"
fail=$(_cron_fail_svc_name "example_com" "backup")
assert_eq "$fail" "srvctl-cronfail-example_com-backup.service" "domain cron fail-service adı"

sys_svc=$(_cron_svc_name "" "nightly")
assert_eq "$sys_svc" "srvctl-syscron-nightly.service" "sistem cron .service adı"
sys_fail=$(_cron_fail_svc_name "" "nightly")
assert_eq "$sys_fail" "srvctl-syscronfail-nightly.service" "sistem cron fail-service adı"

# 'srvctl-cron-*.service' glob'u fail-service'leri YAKALAMAMALI (liste/temizlik
# kodunun dayandığı KRİTİK varsayım — bkz. lib/cron.sh:_cron_list ve
# lib/domain.sh:_domain_purge_resources).
case "$fail" in
    srvctl-cron-*.service) glob_hit="evet" ;;
    *) glob_hit="hayir" ;;
esac
assert_eq "$glob_hit" "hayir" \
    "ad uzayı: 'srvctl-cron-*.service' glob'u fail-service ile ÇAKIŞMIYOR"
case "$sys_fail" in
    srvctl-syscron-*.service) sys_glob_hit="evet" ;;
    *) sys_glob_hit="hayir" ;;
esac
assert_eq "$sys_glob_hit" "hayir" \
    "ad uzayı: 'srvctl-syscron-*.service' glob'u sistem fail-service ile ÇAKIŞMIYOR"

# ═══════════════════════════════════════════════
#  8) AppArmor ÖN-KONTROLÜ — _cron_apparmor_flock_ok (KOORDİNATÖR HOST
#     BULGUSU — İKİ KATMAN: (1) GERÇEK Ubuntu 24.04 VM'de flock EXEC
#     AppArmor tarafından reddediliyordu (status=126) — düzeltme:
#     '/usr/bin/flock rix,'. (2) BUNDAN SONRA ölçüldü — flock çalışıyor ama
#     KİLİT DOSYASINI ('/run/srvctl/locks/<sname>/deploy-<sname>.lock')
#     açamıyordu (denied_mask="rc", DAC sorunsuzdu) — düzeltme: aynı
#     dosyaya '/run/srvctl/locks/{{SAFE_NAME}}/deploy-{{SAFE_NAME}}.lock
#     rwk,'. İKİSİ DE ŞABLONU günceller, ÖNCEDEN render edilmiş canlı
#     profiller OTOMATİK GÜNCELLENMEZ. Bu fonksiyon TEK kontrolde İKİSİNİ
#     BİRDEN doğrular. (3. HOST BULGUSU — DAC/root çelişkisi, bu İKİ
#     AppArmor katmanından SONRA ölçüldü: kilit dizini 700 root:root idi,
#     User=web_<sname> olarak çalışan cron job'u AppArmor'a hiç sıra
#     gelmeden dizine GİREMİYORDU — düzeltme lib/deploy.sh:_deploy_lock_dir
#     / lib/cron.sh:_cron_lock_dir'de: kilit artık domain BAŞINA ayrı,
#     domain'in kullanıcısına ait bir alt dizinde; bu yüzden yol BİR ALT
#     DİZİN daha kazandı — 'deploy-<sname>.lock' düz yol ARTIK GÜNCEL
#     DEĞİL sayılır, aşağıdaki 'goc_oncesi' örneği bunu doğrular.)
# ═══════════════════════════════════════════════
AA_DIR="$(mktemp -d)"
export SRVCTL_APPARMOR_DIR="$AA_DIR"

assert_fail _cron_apparmor_flock_ok "hicprofil_yok" \
    "AppArmor: profil dosyası HİÇ YOKSA (2 döner, predikat FAIL) — SESSİZCE geçilecek durum"

cat > "${AA_DIR}/srvctl-eskiprofil-cli" <<'EOF'
profile srvctl-eskiprofil-cli flags=(attach_disconnected) {
  /usr/bin/php8.3 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
}
EOF
assert_fail _cron_apparmor_flock_ok "eskiprofil" \
    "AppArmor: profil VAR ama 'flock' EXEC İZNİ DE, kilit dosyası izni de YOK (1 döner — repair GEREKİR)"

cat > "${AA_DIR}/srvctl-yarimprofil-cli" <<'EOF'
profile srvctl-yarimprofil-cli flags=(attach_disconnected) {
  /usr/bin/php8.3 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
}
EOF
assert_fail _cron_apparmor_flock_ok "yarimprofil" \
    "AppArmor: SADECE flock EXEC izni eklenmiş (2. HOST bulgusu — kilit DOSYASI kuralı hâlâ eksik) — hâlâ 1 döner, UYARI KESİLMEMELİ"

cat > "${AA_DIR}/srvctl-goc_oncesi-cli" <<'EOF'
profile srvctl-goc_oncesi-cli flags=(attach_disconnected) {
  /usr/bin/php8.3 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
  /run/srvctl/deploy-goc_oncesi.lock rwk,
}
EOF
assert_fail _cron_apparmor_flock_ok "goc_oncesi" \
    "AppArmor: GÖÇ ÖNCESİ (DAC/root çelişkisi düzeltmesinden ÖNCEKİ) düz yol ARTIK GÜNCEL DEĞİL sayılıyor — 'locks/<sname>/' alt dizini YOK"

cat > "${AA_DIR}/srvctl-guncelprofil-cli" <<'EOF'
profile srvctl-guncelprofil-cli flags=(attach_disconnected) {
  /usr/bin/php8.3 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
  /run/srvctl/locks/guncelprofil/deploy-guncelprofil.lock rwk,
}
EOF
assert_ok _cron_apparmor_flock_ok "guncelprofil" \
    "AppArmor: profil TAM GÜNCEL — hem 'flock rix,' HEM YENİ 'locks/<sname>/deploy-<sname>.lock rwk,' VAR (0 döner)"

# Kilit dosyası kuralı BAŞKA bir domain'e aitse (yanlış sname) EŞLEŞMEMELİ —
# görev talebi: "DAR olması önemli", bu izolasyonun testte de doğrulanması.
cat > "${AA_DIR}/srvctl-yanlisdomain-cli" <<'EOF'
profile srvctl-yanlisdomain-cli flags=(attach_disconnected) {
  /usr/bin/php8.3 mrix,
  /bin/sh rix,
  /usr/bin/dash rix,
  /usr/bin/flock rix,
  /run/srvctl/locks/baskadomain/deploy-baskadomain.lock rwk,
}
EOF
assert_fail _cron_apparmor_flock_ok "yanlisdomain" \
    "AppArmor: kilit dosyası kuralı BAŞKA bir domain'e aitse (sname uyuşmuyor) TANINMAZ (izolasyon — dar kapsam kilidi)"

rm -rf "$AA_DIR"
unset SRVCTL_APPARMOR_DIR

# ═══════════════════════════════════════════════
#  9) SANDBOX (systemd mount namespace) ÖN-KONTROLÜ — _cron_sandbox_probe_ok
#     (DÖRDÜNCÜ HOST BULGUSU — koordinatör, 2. tur: flock DAC/AppArmor'dan
#     geçtiği HÂLDE 'ProtectSystem=strict' + eksik 'ReadWritePaths=' YÜZÜNDEN
#     'Permission denied' (73) ile düşüyordu; bu fonksiyon koordinatörün
#     KENDİ 'systemd-run' A/B testini 'cron add' anına taşır). Dönüş kodları
#     (0/1/2) VE fail-soft/gerekli argüman kontrolleri burada İZOLE test
#     edilir — GERÇEK bir 'systemd-run'/sandbox davranışı BU MAKİNEDE
#     doğrulanamaz (bkz. fonksiyonun KENDİ DÜRÜSTLÜK NOTU), yalnız KONTROL
#     AKIŞI (argüman eksikliği/komut yokluğu/dönüş kodu eşlemesi) test
#     edilebilir.
# ═══════════════════════════════════════════════
SANDBOX_FAKEBIN="$(mktemp -d)"

# (i) 'systemd-run' PATH'te YOKSA (bu makinenin doğal durumu) — 2 döner
# (BİLİNMİYOR, "hatalı" DEĞİL — core.sh'taki AYNI missing-vs-tamper ayrımı).
if ! command -v systemd-run >/dev/null 2>&1; then
    assert_fail _cron_sandbox_probe_ok "/var/www/example.com" "/run/srvctl/locks/example_com" "root" \
        "9i) 'systemd-run' YOKSA probe ÇALIŞTIRILAMAZ (2 döner, predikat FAIL — sessizce geçilecek durum)"
else
    echo "  UYARI: bu host'ta GERÇEK 'systemd-run' VAR — (i) testi bu ortamda ANLAMSIZ, ATLANDI"
fi

# Aşağıdaki testler İÇİN sahte bir 'systemd-run' PATH'e eklenir (yalnız
# KONTROL AKIŞINI izole etmek için — argümanlarını GERÇEKTEN kullanmaz,
# yalnız önceden belirlenmiş bir kodla çıkar).
cat > "${SANDBOX_FAKEBIN}/systemd-run" <<'EOF'
#!/bin/bash
exit "${FAKE_SYSTEMD_RUN_EXIT:-0}"
EOF
chmod +x "${SANDBOX_FAKEBIN}/systemd-run"
export PATH="${SANDBOX_FAKEBIN}:${PATH}"

# (ii) Eksik argüman (boş domain_root/lock_dir/web_user) — 'systemd-run'
# VARKEN BİLE 2 döner (probe ANLAMLI bir girdi olmadan HİÇ ÇALIŞTIRILMAZ).
assert_fail _cron_sandbox_probe_ok "" "/run/srvctl/locks/example_com" "root" \
    "9ii) domain_root BOŞSA probe ÇALIŞTIRILMAZ (2 döner)"
assert_fail _cron_sandbox_probe_ok "/var/www/example.com" "" "root" \
    "9ii) lock_dir BOŞSA probe ÇALIŞTIRILMAZ (2 döner)"
assert_fail _cron_sandbox_probe_ok "/var/www/example.com" "/run/srvctl/locks/example_com" "" \
    "9ii) web_user BOŞSA probe ÇALIŞTIRILMAZ (2 döner)"

# (iii) web kullanıcısı YOKSA (gerçek bir Linux kullanıcı adı OLMAYAN bir
# dize) — 'systemd-run' VARKEN BİLE 2 döner ('id' başarısız).
assert_fail _cron_sandbox_probe_ok "/var/www/example.com" "/run/srvctl/locks/example_com" "srvctl_test_nonexistent_user_xyz" \
    "9iii) web kullanıcısı YOKSA probe ÇALIŞTIRILMAZ (2 döner — 'id' başarısız)"

# (iv) 'systemd-run' VAR + kullanıcı VAR ('root' — her POSIX sistemde
# GERÇEKTEN var olan tek kimlik, 'id root' HER YERDE başarılıdır) + sahte
# 'systemd-run' 0 ile çıkıyor → probe BAŞARILI (0 döner).
export FAKE_SYSTEMD_RUN_EXIT=0
assert_ok _cron_sandbox_probe_ok "/var/www/example.com" "/run/srvctl/locks/example_com" "root" \
    "9iv) systemd-run BAŞARILI çıkarsa probe BAŞARILI sayılır (0 döner)"

# (v) AYNI koşullar ama sahte 'systemd-run' 1 ile çıkıyor → probe ÇALIŞTI
# ama BAŞARISIZ (1 döner — GERÇEK bir tespit, 'cron add' bunu UYARIYA
# çevirir, ASLA engellemez).
export FAKE_SYSTEMD_RUN_EXIT=1
assert_fail _cron_sandbox_probe_ok "/var/www/example.com" "/run/srvctl/locks/example_com" "root" \
    "9v) systemd-run BAŞARISIZ çıkarsa probe BAŞARISIZ sayılır (1 döner — GERÇEK tespit)"
unset FAKE_SYSTEMD_RUN_EXIT

rm -f "${SANDBOX_FAKEBIN}/systemd-run"
rm -rf "$SANDBOX_FAKEBIN"

rm -rf "$WEB_ROOT"
test_summary
