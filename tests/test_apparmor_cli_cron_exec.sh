#!/bin/bash
# CLI/worker AppArmor profilinin CRON EXEC YÜZEYİ regresyon testi.
#
# NEDEN VAR (GERÇEK Ubuntu 24.04 üretim sunucusunda ölçülmüş bulgu):
# 'srvctl cron add <domain> --command="echo '\''x'\'' && date +%Y"' unit'i
# DOĞRU render ediliyordu, ama çalıştırınca:
#     Result: exit-code    ExecMainStatus: 126
# Gerçek 'srvctl-<sname>-cli' profili altında TEK TEK ölçüldü: php8.4 rc=0,
# flock rc=0 — ama date/cat/echo/tar/mysqldump/git rc=126 (profilde HİÇBİR
# kural yok → default-deny), find/curl rc=126 (BİLİNÇLİ 'audit deny'
# listesinde).
#
# ÖLÇÜM BİÇİMİ KRİTİK — üretimde kanıtlandı, yanlış biçim HER İKİLİYİ geçirir:
#     aa-exec -p <profil> -- <ikili>                     → date 0, wc 0, curl 0
#     aa-exec -p <profil> -- /bin/sh -c 'exec <ikili>'   → date 126, wc 126, curl 126
# Birinci biçimde exec'in KENDİSİ profile geçiş anıdır (change_onexec) ve
# profilin exec kuralları o ana UYGULANMAZ; açıkça 'audit deny' edilmiş curl
# bile rc=0 verir. Yani birinci biçimle doğrulama yapan biri, düzeltme HİÇ
# yapılmamışken bile "geçti" görür. Cron unit'i ikinci biçimle aynı davranır
# ('AppArmorProfile=' ile başlayan süreç zaten profil İÇİNDEDİR, exec oradan
# yapılır). lib/cron.sh'ın prob fonksiyonu bu yüzden ikinci biçimi kullanır.
#
# GÖZLEMLENEBİLİRLİK: denial'lar journald'a DÜŞMEZ. Aynı deneyde
# 'journalctl -k' = 0 satır, ama '/var/log/audit/audit.log' içinde
# 'apparmor="DENIED" operation="exec" name="/usr/bin/curl"' vardı (auditd
# aktif). İpucu var ama operatörün bakmayacağı yerde.
#
# KÖK SEBEP: templates/apparmor/profile-cli.tpl DEPLOY akışı (php+composer+
# git) düşünülerek yazılmıştı; 'srvctl cron' ise KULLANICININ YAZDIĞI
# SERBEST kabuk komutunu AYNI profil altında çalıştırıyor
# (srvctl-cron.service.tpl: 'AppArmorProfile=srvctl-{{SAFE_NAME}}-cli' +
# 'ExecStart={{FLOCK_PREFIX}}/bin/sh -c '<komut>''). Meşru cron komutları
# coreutils'e ihtiyaç duyar.
#
# BU TEST BEŞ ŞEYİ statik olarak (render/apparmor_parser ÇALIŞTIRMADAN —
# macOS geliştirme makinesinde de çalışır) kilitler:
#
#   1) İZİN KİLİDİ: cron için gerekli, egress'SİZ her coreutils/DB-dump
#      ikilisi için profilde 'ix' İÇEREN bir kural VAR — hem '/usr/bin/'
#      hem '/bin/' varyantıyla (usrmerge sembolik link tuzağı).
#   2) DENY POLİTİKASI KİLİDİ: egress/interpreter/gadget listesi (bash,
#      curl, wget, nc, socat, python3, perl, node, find, xargs, env, ...)
#      AYNEN yerinde ve bu ikililerden HİÇBİRİ yanlışlıkla allow EDİLMEMİŞ.
#   3) PROFİL KAÇIŞI KİLİDİ: hiçbir kuralda 'ux'/'Ux'/'px'/'Px' YOK. Bu
#      MADDENİN TAMAMI bu değişikliğin güvenlik gerekçesidir: 'ix' profili
#      DEVRALIR (exec edilen ikili AYNI dosya kurallarının içinde kalır,
#      başka domain'in dosyalarına erişemez), 'ux'/'px' ise profilden
#      ÇIKARIR — hapsi ZAYIFLATAN tek şey odur.
#   4) FPM İZOLASYONU: templates/apparmor/profile.tpl (web isteği yolu) bu
#      coreutils'in HİÇBİRİNİ exec edemez. Cron yüzeyi asla web yüzeyine
#      SIZMAMALI.
#   5) DİZİN PARİTESİ: '/usr/bin/' ve '/bin/' whitelist'leri BİREBİR AYNI
#      ikili kümesini tanımlar (tek dizini eksik bırakmak sessiz bir kapsam
#      boşluğudur).
#
# KENDİ KENDİNİ DOĞRULAMA (zorunlu proje kuralı): tarayıcı sessizce hep
# PASS vermemeli — beş dedektörün hepsi sentetik fixture'larla MUTASYON
# testine tabi tutulur (aşağıda).
set -uo pipefail
# GLOBBING KAPALI: politika listeleri AppArmor glob'ları içerir ('[[]',
# 'gcc*', 'python3*', 'nc.*'). Bunlar 'for b in $bins' gibi tırnaksız
# genişletmelerde kabuk tarafından DOSYA ADI olarak yorumlanabilir ve
# çalışma dizinindeki dosyalara göre SESSİZCE farklı sonuç üretirdi.
set -f
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/tests/lib.sh"

PROFILE_TPL="${REPO_ROOT}/templates/apparmor/profile.tpl"
PROFILE_CLI_TPL="${REPO_ROOT}/templates/apparmor/profile-cli.tpl"

# ═══════════════════════════════════════════════════════════════
#  POLİTİKA VERİSİ — tek doğruluk kaynağı (şablon bununla kilitlenir)
# ═══════════════════════════════════════════════════════════════

# ─── İZİN VERİLEN (ix) — egress'SİZ coreutils ───
# NOT — '[[]' NEDEN BÖYLE YAZILIYOR: bu, 'test' komutunun ikinci adı olan
# '[' ikilisidir. AppArmor'da '[' bir KARAKTER SINIFI açar; '/usr/bin/['
# yazmak TÜM profili parse edilemez hale getirir ("Regex grouping error:
# Unclosed grouping or character class") ve profil HİÇ YÜKLENMEZ — yani
# sertleştirme yerine MAC'siz çalışma. Literal '[' tek karakterlik bir
# sınıf olarak yazılır: '[[]'. GERÇEK apparmor_parser ile HER İKİ LTS'te
# doğrulandı (jammy 3.0.4 / noble 4.0.1, 'apparmor_parser -Q'):
# '/usr/bin/[[]' OK, '/usr/bin/[' FAIL, tırnaklı '"/usr/bin/["' de FAIL.
# '--dump=rule-exprs' anlamı da doğruladı: '/usr/bin/[[] -> /usr/bin/[\[]'.
_CRON_ALLOW_BINS="date cat mkdir rm cp mv ls touch sed grep egrep fgrep
awk gawk mawk sort head tail wc cut tr uniq tee tar gzip gunzip zcat sleep
mktemp dirname basename realpath stat du df echo printf test [[] true false
xz zstd mysqldump mysql mariadb-dump mariadb"

# ─── DEĞİŞMEYECEK DENY POLİTİKASI ───
# Egress (curl/wget/nc/socat/ssh/scp/rsync), yorumlayıcılar (bash/python3/
# perl/ruby/node), tek-binary kaçış kitleri (busybox), encode/decode
# (base64/xxd), derleyici/linker (gcc/ld), process-spawn/persist
# primitifleri (find -exec/xargs/env/setsid/nohup) ve zamanlanmış görev
# mekanizmaları (at/crontab). Bu küme ŞABLONDAKİ 'audit deny' satırlarıyla
# BİREBİR eşleşmeli — biri politikayı sessizce gevşetirse test KIRILIR.
_CRON_DENY_BINS="bash curl wget nc nc.* ncat socat python3* perl ruby node
ssh scp rsync busybox base64 xxd gcc* ld find xargs env setsid nohup at
crontab"

# '/usr/bin' tarafında AYRICA tek bir düz (audit'siz) 'deny ... x' kuralı
# vardır: '/usr/bin/stty'. Bu, HOST telemetrisiyle GEREKÇELENDİRİLMİŞ,
# tests/test_apparmor_deny_shadow.sh'da AÇIK beyaz listede tutulan tek
# istisnadır (Symfony Console'un terminal-genişliği yoklaması: ~4 kayıt/dk/
# domain, gerçek sinyal sıfır). Kümeye burada da yazılır ki biri sessizce
# İKİNCİ bir susturma eklerse bu test de kırılsın.
_CRON_DENY_EXTRA_USRBIN="stty"

# '/bin' whitelist'inde '/usr/bin' karşılığı ARANMAYACAK tek ad: 'sh'.
# '/bin/sh' Ubuntu'da '/usr/bin/dash'e bağlıdır ve '/usr/bin' tarafındaki
# karşılığı ZATEN 'dash' olarak ayrı bir kuralla tanımlıdır (bkz.
# profile-cli.tpl'deki "kabuk exec whitelist'i" bloğu) — '/usr/bin/sh'
# diye bir dosya yoktur.
_CRON_PARITY_EXEMPT="sh"

# ═══════════════════════════════════════════════════════════════
#  TARAYICILAR — hepsi profil METNİ üzerinde çalışır (fixture'la test
#  edilebilsin diye dosya yolu DEĞİL, metin alırlar)
# ═══════════════════════════════════════════════════════════════

# '{{TOKEN}}' yer tutucularını opak, glob-özel-karakter içermeyen bir
# forma çevir (yoksa brace mantığı '{{PHP_VERSION}}'ı alternation sanar).
_cx_protect_tokens() {
    printf '%s' "$1" | sed -E 's/\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}/TOKEN_\1_TOKEN/g'
}

# Tek seviyeli, tek gruplu AppArmor brace-alternation'ını genişlet.
# Girdi '_cx_protect_tokens'tan geçmiş olmalı.
_cx_expand_braces() {
    local s="$1"
    case "$s" in
        *"{"*"}"*)
            local pre rest group post alt
            pre="${s%%\{*}"; rest="${s#*\{}"
            group="${rest%%\}*}"; post="${rest#*\}}"
            local IFS=','
            for alt in $group; do printf '%s\n' "${pre}${alt}${post}"; done
            ;;
        *) printf '%s\n' "$s" ;;
    esac
}

# Yorum satırlarını/sondaki yorumları at, yalnız KURAL satırlarını bırak.
# '{' ile başlayan satırlar da alınır: '{{WEB_ROOT}}/...' kuralları da
# taranmalı (oraya konacak bir 'ux' de gerçek bir profil kaçışıdır).
_cx_rule_lines() {
    printf '%s\n' "$1" \
        | sed -E 's/[[:space:]]*#.*$//' \
        | grep -E '^[[:space:]]*(audit[[:space:]]+)?(deny[[:space:]]+)?[/{]'
}

_cx_perm_of() { printf '%s' "$1" | grep -oE '[A-Za-z]+,?[[:space:]]*$' | tr -d ', \t'; }

_cx_path_of() {
    printf '%s' "$1" \
        | sed -E 's/^[[:space:]]*(audit[[:space:]]+)?(deny[[:space:]]+)?//; s/[[:space:]]+[A-Za-z]+,?[[:space:]]*$//'
}

# ALLOW tarafındaki, izni 'ix' İÇEREN kuralların brace-GENİŞLETİLMİŞ
# somut yolları (satır başına bir yol).
_cx_ix_allow_paths() {
    local text="$1" line perm path
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        perm="$(_cx_perm_of "$line")"
        [[ "$perm" == *i*x* ]] || continue
        path="$(_cx_protect_tokens "$(_cx_path_of "$line")")"
        _cx_expand_braces "$path"
    done <<< "$(_cx_rule_lines "$text" | grep -vE '^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]]')"
}

# ALLOW tarafındaki, izni 'x' İÇEREN (kip fark etmeksizin) somut yollar.
_cx_any_x_allow_paths() {
    local text="$1" line perm path
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        perm="$(_cx_perm_of "$line")"
        [[ "$perm" == *x* ]] || continue
        path="$(_cx_protect_tokens "$(_cx_path_of "$line")")"
        _cx_expand_braces "$path"
    done <<< "$(_cx_rule_lines "$text" | grep -vE '^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]]')"
}

# DENY tarafındaki 'x' kurallarının brace-GENİŞLETİLMİŞ yolları.
_cx_deny_x_paths() {
    local text="$1" line perm path
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        perm="$(_cx_perm_of "$line")"
        [[ "$perm" == *x* ]] || continue
        path="$(_cx_protect_tokens "$(_cx_path_of "$line")")"
        _cx_expand_braces "$path"
    done <<< "$(_cx_rule_lines "$text" | grep -E '^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]]')"
}

# ─── DEDEKTÖR 1: izin kilidi (ix + iki dizin varyantı) ───
# Boş string = eksik YOK.
_cx_missing_allows() {
    local text="$1" dirs="$2" bins="$3" findings="" paths b d
    paths="$(_cx_ix_allow_paths "$text")"
    for b in $bins; do
        for d in $dirs; do
            printf '%s\n' "$paths" | grep -qxF "${d}/${b}" || findings+="${d}/${b} EKSİK; "
        done
    done
    printf '%s' "$findings"
}

# ─── DEDEKTÖR 2a: deny politikası kümesi (belirli bir dizin için) ───
_cx_deny_set_for_dir() {
    local text="$1" dir="$2"
    _cx_deny_x_paths "$text" \
        | grep -E "^${dir}/[^/]+\$" \
        | sed -E "s#^${dir}/##" \
        | sort | tr '\n' ' ' | sed 's/ *$//'
}

# ─── DEDEKTÖR 2b: deny listesindeki bir ad yanlışlıkla allow EDİLMİŞ mi? ───
# AppArmor glob'unu ('nc.*', 'python3*', 'gcc*') POSIX ERE'ye çevirip
# GENİŞLETİLMİŞ allow yollarıyla karşılaştırır.
_cx_glob_to_ere() {
    local g="$1" out
    # shellcheck disable=SC2016  # sed betiği; kabuk genişletmesi İSTENMİYOR
    out=$(printf '%s' "$g" | sed -E 's/([.^$()+|\[\]{}])/\\\1/g')
    out="${out//\*\*/@@DBL@@}"
    out="${out//\*/[^\/]*}"
    out="${out//@@DBL@@/.*}"
    out="${out//\?/[^\/]}"
    printf '^%s$' "$out"
}

_cx_denied_but_allowed() {
    local text="$1" dirs="$2" bins="$3" findings="" paths b d ere p
    paths="$(_cx_any_x_allow_paths "$text")"
    for b in $bins; do
        for d in $dirs; do
            ere="$(_cx_glob_to_ere "${d}/${b}")"
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                [[ "$p" =~ $ere ]] && findings+="${d}/${b} -> allow '${p}' İLE AÇILMIŞ; "
            done <<< "$paths"
        done
    done
    printf '%s' "$findings"
}

# ─── DEDEKTÖR 3: profil kaçışı (ux/Ux/px/Px — ve cx/Cx) ───
# 'u'/'U'/'p'/'P'/'c'/'C' AppArmor'da YALNIZCA exec-transition kipidir
# (dosya izin harfleri: r w a l k m x) — bu yüzden 'x' içeren bir izin
# dizgesinde görülmeleri kesin bir ihlaldir, yanlış pozitif riski yok.
_cx_escape_mode_findings() {
    local text="$1" want="$2" line perm findings=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        perm="$(_cx_perm_of "$line")"
        [[ "$perm" == *x* ]] || continue
        case "$perm" in
            *[$want]*) findings+="${line}; " ;;
        esac
    done <<< "$(_cx_rule_lines "$text")"
    printf '%s' "$findings"
}

# ─── DEDEKTÖR 5: '/usr/bin' ↔ '/bin' parite kümesi ───
_cx_ix_set_for_dir() {
    local text="$1" dir="$2"
    _cx_ix_allow_paths "$text" \
        | grep -E "^${dir}/[^/]+\$" \
        | sed -E "s#^${dir}/##" \
        | sort | tr '\n' ' ' | sed 's/ *$//'
}

# ═══════════════════════════════════════════════════════════════
#  KENDİ KENDİNİ DOĞRULAMA — MUTASYON testleri (sentetik fixture)
# ═══════════════════════════════════════════════════════════════
echo "== Kendi kendini doğrulama (sentetik fixture / mutasyon) =="

fix_good='
profile p {
  /usr/bin/{date,cat} rix,
  /bin/{date,cat} rix,
  audit deny /usr/bin/{curl,find} x,
  audit deny /bin/{curl,find} x,
}
'

# (a) KONTROL GRUBU — tam/doğru fixture eksik bildirmemeli.
out="$(_cx_missing_allows "$fix_good" "/usr/bin /bin" "date cat")"
assert_eq "$out" "" "kontrol grubu: eksiksiz whitelist'te 'EKSİK' bulgusu YOK"

# (b) MUTASYON — '/bin' varyantı eksikse YAKALANMALI (usrmerge tuzağı:
#     tek dizini eksik bırakmak sessiz bir kapsam boşluğudur).
fix_only_usrbin='
profile p {
  /usr/bin/{date,cat} rix,
}
'
out="$(_cx_missing_allows "$fix_only_usrbin" "/usr/bin /bin" "date cat")"
assert_contains "$out" "/bin/date EKSİK" \
    "mutasyon: '/bin' varyantı eksik olduğunda dedektör 1 YAKALIYOR"

# (c) MUTASYON — kural VAR ama izni 'ix' DEĞİL ('r' gibi) → exec edilemez,
#     dedektör 1 bunu EKSİK saymalı.
fix_no_ix='
profile p {
  /usr/bin/{date,cat} r,
  /bin/{date,cat} r,
}
'
out="$(_cx_missing_allows "$fix_no_ix" "/usr/bin /bin" "date")"
assert_contains "$out" "/usr/bin/date EKSİK" \
    "mutasyon: 'ix' İÇERMEYEN (yalnız 'r') kural EKSİK sayılıyor"

# (d) KONTROL GRUBU — deny listesindeki adlar allow'a SIZMAMIŞ.
out="$(_cx_denied_but_allowed "$fix_good" "/usr/bin /bin" "curl find")"
assert_eq "$out" "" "kontrol grubu: deny listesi allow'a sızmamış (yanlış pozitif yok)"

# (e) MUTASYON — biri 'find'i sessizce whitelist'e eklerse YAKALANMALI.
fix_leak='
profile p {
  /usr/bin/{date,find} rix,
}
'
out="$(_cx_denied_but_allowed "$fix_leak" "/usr/bin" "find")"
assert_contains "$out" "/usr/bin/find" \
    "mutasyon: deny politikasındaki 'find' whitelist'e sızarsa YAKALANIYOR"

# (f) MUTASYON — glob'lu deny adı ('python3*') da eşleşmeli.
fix_leak_glob='
profile p {
  /usr/bin/python3.12 rix,
}
'
out="$(_cx_denied_but_allowed "$fix_leak_glob" "/usr/bin" "python3*")"
assert_contains "$out" "/usr/bin/python3*" \
    "mutasyon: glob'lu deny adı ('python3*') sızan somut yolu ('python3.12') YAKALIYOR"

# (g) MUTASYON — profil kaçışı: 'ux' YAKALANMALI.
fix_ux='
profile p {
  /usr/bin/date ux,
}
'
out="$(_cx_escape_mode_findings "$fix_ux" "uUpP")"
assert_contains "$out" "ux" "mutasyon: 'ux' (unconfined exec) YAKALANIYOR"

# (h) MUTASYON — 'Px' (büyük harf, scrub'lı profil geçişi) de YAKALANMALI.
fix_px='
profile p {
  /usr/bin/tar Px,
}
'
out="$(_cx_escape_mode_findings "$fix_px" "uUpP")"
assert_contains "$out" "Px" "mutasyon: 'Px' (profil geçişi) YAKALANIYOR"

# (i) KONTROL GRUBU — 'rix'/'mrix' asla kaçış sayılmamalı.
fix_ix_only='
profile p {
  /usr/bin/php8.3 mrix,
  /usr/bin/date rix,
  deny /home/** rwx,
}
'
out="$(_cx_escape_mode_findings "$fix_ix_only" "uUpP")"
assert_eq "$out" "" "kontrol grubu: 'rix'/'mrix' yanlış pozitif üretmiyor ('rwx' deny de kapsam dışı)"

# (j) KONTROL GRUBU + MUTASYON — dizin paritesi.
out="$(_cx_ix_set_for_dir "$fix_good" "/usr/bin")"
assert_eq "$out" "cat date" "dedektör: '/usr/bin' ix kümesini doğru çıkarıyor"
out="$(_cx_ix_set_for_dir "$fix_only_usrbin" "/bin")"
assert_eq "$out" "" "mutasyon: '/bin' kuralı olmayan fixture'da parite kümesi BOŞ (parite ihlali görünür)"

# (k) MUTASYON — deny politikası kümesi tarayıcısı gerçekten kümeyi çıkarıyor.
out="$(_cx_deny_set_for_dir "$fix_good" "/usr/bin")"
assert_eq "$out" "curl find" "dedektör: '/usr/bin' audit-deny kümesini doğru çıkarıyor"

# ═══════════════════════════════════════════════════════════════
#  ASIL DENETİM — gerçek templates/apparmor/*.tpl
# ═══════════════════════════════════════════════════════════════
echo ""
echo "== Gerçek templates/apparmor/profile-cli.tpl (cron exec yüzeyi) =="

cli_text="$(cat "$PROFILE_CLI_TPL")"
fpm_text="$(cat "$PROFILE_TPL")"

# --- Dedektör 1: izin kilidi ---
missing="$(_cx_missing_allows "$cli_text" "/usr/bin /bin" "$_CRON_ALLOW_BINS")"
assert_eq "$missing" "" \
    "profile-cli.tpl: cron için gereken TÜM coreutils/DB ikilileri 'ix' ile ve HEM '/usr/bin/' HEM '/bin/' varyantıyla izinli"
[[ -n "$missing" ]] && printf '  %s\n' "$missing" >&2

# Görev şartı: 'mariadb-dump' varyantı AÇIKÇA mevcut (24.04'te
# '/usr/bin/mysqldump' → '/usr/bin/mariadb-dump' sembolik linktir; AppArmor
# d_path ile NİHAİ hedefi denetlediğinden yalnız 'mysqldump' yazmak 24.04'te
# İŞE YARAMAZ — 22.04/MariaDB 10.6'da symlink yönü TERSTİR).
assert_contains "$cli_text" "mariadb-dump" \
    "profile-cli.tpl: 24.04 symlink hedefi 'mariadb-dump' AÇIKÇA yazılmış"
assert_contains "$cli_text" "mysqldump" \
    "profile-cli.tpl: 22.04 varyantı 'mysqldump' de AÇIKÇA yazılmış (çift-LTS)"

# '[' özel sözdizimi: literal '[' YALNIZCA '[[]' biçiminde yazılabilir.
# ÇIPLAK '/usr/bin/[' TÜM profili parse edilemez yapar (gerçek
# apparmor_parser 3.0.4 + 4.0.1 ile doğrulandı) → profil HİÇ yüklenmez →
# sertleştirme yerine MAC'siz çalışma. Bu satır o regresyonu kilitler.
if printf '%s\n' "$cli_text" | grep -qE '^[[:space:]]*/(usr/)?bin/\[[[:space:]]'; then
    assert_eq "var" "yok" "profile-cli.tpl: ÇIPLAK '/usr/bin/[' kuralı YOK (profili parse edilemez yapar)"
else
    assert_eq "yok" "yok" "profile-cli.tpl: ÇIPLAK '/usr/bin/[' kuralı YOK (profili parse edilemez yapar)"
fi

# --- Dedektör 2a: deny politikası AYNEN duruyor mu? ---
# Tırnaksız genişletme KASITLI: politika listeleri boşluk/satırsonu ile
# ayrılmış ADLARDIR, kelime bölünmesi TAM OLARAK istenen davranıştır.
# Glob riski YOK — dosya başında 'set -f' ile pathname expansion kapalı.
# shellcheck disable=SC2086
deny_expected_bin="$(printf '%s\n' $_CRON_DENY_BINS | sort | tr '\n' ' ' | sed 's/ *$//')"
# shellcheck disable=SC2086
deny_expected_usrbin="$(printf '%s\n' $_CRON_DENY_BINS $_CRON_DENY_EXTRA_USRBIN | sort | tr '\n' ' ' | sed 's/ *$//')"

got="$(_cx_deny_set_for_dir "$cli_text" "/usr/bin")"
assert_eq "$got" "$deny_expected_usrbin" \
    "profile-cli.tpl: '/usr/bin' egress/interpreter/gadget deny listesi AYNEN duruyor (+gerekçeli 'stty' susturması; sessizce gevşetilmemiş)"

got="$(_cx_deny_set_for_dir "$cli_text" "/bin")"
assert_eq "$got" "$deny_expected_bin" \
    "profile-cli.tpl: '/bin' egress/interpreter/gadget deny listesi AYNEN duruyor (sessizce gevşetilmemiş)"

# --- Dedektör 2b: deny listesindeki hiçbir ad allow'a sızmamış ---
leak="$(_cx_denied_but_allowed "$cli_text" "/usr/bin /bin" "$_CRON_DENY_BINS")"
assert_eq "$leak" "" \
    "profile-cli.tpl: deny politikasındaki HİÇBİR ikili yanlışlıkla allow edilmemiş (BUG 1 'deny allow'u ezer' tuzağı da tetiklenmez)"
[[ -n "$leak" ]] && printf '  %s\n' "$leak" >&2

# --- Dedektör 3: profil kaçışı ---
# 'ix' = profil DEVRALINIR: exec edilen ikili AYNI dosya kurallarının içinde
# kalır, başka domain'in dosyalarına ERİŞEMEZ. 'ux'/'Ux' (unconfined) ve
# 'px'/'Px' (başka profile geçiş) tam da bu hapsi KIRAR — cron unit'i
# 'NoNewPrivileges=true' ile çalıştığından bu geçişler çekirdek tarafından
# zaten reddedilir, yani hem güvenlik hem işlevsellik açısından 'ix' TEK
# doğru kiptir.
esc_cli="$(_cx_escape_mode_findings "$cli_text" "uUpP")"
assert_eq "$esc_cli" "" \
    "profile-cli.tpl: HİÇBİR kuralda 'ux'/'Ux'/'px'/'Px' YOK — tüm exec'ler profili DEVRALIR ('ix')"
[[ -n "$esc_cli" ]] && printf '  %s\n' "$esc_cli" >&2

esc_fpm="$(_cx_escape_mode_findings "$fpm_text" "uUpP")"
assert_eq "$esc_fpm" "" \
    "profile.tpl: HİÇBİR kuralda 'ux'/'Ux'/'px'/'Px' YOK"
[[ -n "$esc_fpm" ]] && printf '  %s\n' "$esc_fpm" >&2

# 'cx'/'Cx' (alt profile geçiş) de yasak: bu şablonlarda TANIMLI bir alt
# profil YOKTUR, 'cx' yazmak profili yüklenemez hale getirir (ve niyet
# olarak da yine profil DEVRALMA değil, geçiştir).
cx_cli="$(_cx_escape_mode_findings "$cli_text" "cC")"
assert_eq "$cx_cli" "" \
    "profile-cli.tpl: 'cx'/'Cx' (tanımsız alt profile geçiş) kullanılmamış"

# --- Dedektör 4: FPM (web isteği) profili bu coreutils'i exec EDEMEZ ---
fpm_leak="$(_cx_denied_but_allowed "$fpm_text" "/usr/bin /bin" "$_CRON_ALLOW_BINS")"
assert_eq "$fpm_leak" "" \
    "profile.tpl (FPM/web isteği): cron coreutils'inin HİÇBİRİ exec edilemez — cron yüzeyi web yüzeyine SIZMAMIŞ"
[[ -n "$fpm_leak" ]] && printf '  %s\n' "$fpm_leak" >&2

# --- Dedektör 5: '/usr/bin' ↔ '/bin' paritesi ---
set_usrbin="$(_cx_ix_set_for_dir "$cli_text" "/usr/bin")"
set_bin="$(_cx_ix_set_for_dir "$cli_text" "/bin")"
# '/usr/bin' fazladan 'dash', 'flock' ve 'php{{PHP_VERSION}}' içerir (bunlar
# cron bloğundan ÖNCE de vardı ve gerekçeleri şablonda belgeli). Buradaki
# invariant tek yönlüdür: '/bin' whitelist'indeki HER ad '/usr/bin'
# tarafında da tanımlı OLMALI — tersi (yalnız '/usr/bin'de olan ad) meşru.
# TEK muafiyet '_CRON_PARITY_EXEMPT' ile belgelenmiştir ('sh' → 'dash').
parity_missing=""
for b in $set_bin; do
    [[ " $_CRON_PARITY_EXEMPT " == *" $b "* ]] && continue
    [[ " $set_usrbin " == *" $b "* ]] || parity_missing+="/bin/${b} '/usr/bin' tarafında YOK; "
done
assert_eq "$parity_missing" "" \
    "profile-cli.tpl: '/bin' whitelist'indeki her ikili '/usr/bin' tarafında da tanımlı (usrmerge paritesi)"
[[ -n "$parity_missing" ]] && printf '  %s\n' "$parity_missing" >&2

test_summary
