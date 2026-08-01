#!/bin/bash
# AppArmor deny-gölgeleme dedektörü + exec whitelist kilidi.
#
# NEDEN VAR (gerçek Ubuntu 22.04 VM'de kanıtlanmış BUG 1): AppArmor'da
# 'deny' HER ZAMAN 'allow'u ezer — glob/tam-yol SPESİFİKLİĞİ FARK ETMEZ.
# templates/apparmor/profile.tpl'de eskiden var olan 'deny /usr/sbin/** x,'
# satırı, aynı profildeki ZORUNLU '/usr/sbin/php-fpm{{PHP_VERSION}} mrix,'
# allow kuralını EZİYORDU: php-fpm SIGUSR2 (graceful reload) aldığında
# kendini execvp ile yeniden çalıştıramıyor, exit(70) ile çöküyor, systemd
# unit'i yeniden başlatıyordu — 'systemctl reload' TÜM domain'i birkaç
# saniyeliğine düşürüyordu. Aynı sınıf hata templates/apparmor/
# profile-cli.tpl'de de vardı ('deny /usr/bin/** x,' ve 'deny /bin/** x,'
# ile worker/scheduler'ın kendi 'php'/'sh' alt-süreç exec'lerini ezmesi).
#
# Bu iki bug DÜZELTİLDİ (blanket deny'ler kaldırıldı) ama bir güvenlik
# denetimi bir GUARDRAİL KAYBINA dikkat çekti: artık biri bu profillere
# geniş bir 'x' allow'u eklerse (ya da yeni bir abstraction exec izni
# sızdırırsa), hiçbir deny kuralı bunu durdurmaz — çünkü default-deny
# ZATEN sessizce çalışıyor, deny kuralları yalnızca dokümantasyon/tespit
# katmanıdır. Cevap: ÇAKIŞMAYAN, adlandırılmış tehlikeli-binary deny
# listeleri (bkz. her iki .tpl dosyasındaki "Kaybolan guardrail'i KAPAT"
# blokları).
#
# BU TEST ÜÇ ŞEYİ statik olarak (render/apparmor_parser ÇALIŞTIRMADAN,
# macOS'ta da çalışır) kilitler:
#
#   1) DENY-GÖLGELEME DEDEKTÖRÜ: profildeki HER 'deny <glob> x' (veya
#      'audit deny <glob> x') kuralı için, AYNI profilde o glob'a eşleşen
#      bir 'x' İÇEREN allow kuralının OLMADIĞINI doğrular. Bu test daha
#      önce yazılmış olsaydı BUG 1'i (hem FPM hem CLI profilinde) render
#      hiç çalıştırılmadan, salt statik taramayla yakalardı.
#
#   2) EXEC WHITELIST KİLİDİ: 'x' izni verilen (allow) yolların TAM
#      KÜMESİNİN, FPM profilinde yalnızca php-fpm binary'si, CLI
#      profilinde yalnızca php/sh/dash/flock olduğunu doğrular. İleride
#      biri buraya geniş bir 'x' allow'u (ör. '/usr/bin/** rix,') eklerse
#      bu test KIRILIR — MADDE B'nin "guardrail" amacının ta kendisi.
#      'flock' (koordinatör bulgusu, GERÇEK Ubuntu 24.04 VM — status=126
#      "Permission denied", TÜM domain cron'ları çalışamıyordu) BİLİNÇLİ
#      OLARAK eklendi: lib/cron.sh'ın deploy-kilidi sarmalayıcısı
#      ('flock -n -E 75 <kilit> -c "<komut>"') bu profil altında (worker/
#      scheduler İLE PAYLAŞILAN srvctl-<sname>-cli) çalışır — bkz.
#      templates/apparmor/profile-cli.tpl'deki UZUN gerekçe (üç seçenek
#      değerlendirildi, whitelist'e ekleme SEÇİLDİ: kök nedeni bu modülün
#      sınırları içinde çözer, lib/deploy.sh'a dokunmayı gerektirmez).
#
#   3) DÜZ (audit'siz) EXEC-DENY İNVARİANT'I — HOST ÖLÇÜMÜYLE EKLENDİ:
#      srvctl-jammy VM'de (AppArmor 3.0.4) gerçek bir ölçüm, önceki
#      "blanket satırları düz 'deny' bırakmak audit gürültüsünü azaltır"
#      varsayımını ÇÜRÜTTÜ. Kanıt: profile içine bilinçli yerleştirilen
#      bir '/bin/sh' + '/usr/sbin/sendmail' kopyası exec edilmeye
#      çalışıldığında — bu yollar için PROFİLDE HİÇBİR KURAL YOKKEN —
#      AppArmor bunu default-deny ile engelledi VE audit.log'a
#      'type=AVC apparmor="DENIED" operation="exec"' olarak YAZDI. Yani
#      KURAL YOKLUĞU zaten loglanıyor; AppArmor'ın belgelenen davranışı
#      şudur: yalnızca AÇIK bir 'deny' kuralı (audit niteleyicisi
#      OLMADAN) audit mesajını BASTIRIR. Dolayısıyla düz 'deny' koruma
#      EKLEMEZ (default-deny zaten kapatıyor), yalnızca TESPİT SİNYALİNİ
#      SİLER. Aynı ölçümde "audit'lemek log şişirir" gerekçesi de
#      çürütüldü: 64 dakikalık gerçek işletimde (tam bir Laravel
#      deploy'u + CI4 + trafik dahil) 861 kayıttan yalnızca 3'ü
#      'operation="exec"' idi (hepsi kasıtlı prob). SONUÇ: her iki
#      profilde 'x' izni içeren HİÇBİR düz (audit'siz) 'deny' kuralı
#      OLMAMALI — TEK istisna: gerçek telemetriyle DOĞRULANMIŞ,
#      bilinen-zararsız, yüksek-frekanslı bir tekrar (şu an tek örnek:
#      profile-cli.tpl'deki '/usr/bin/stty' — Symfony Console'un
#      terminal-genişliği yoklaması, ölçülen 4 kayıt/dk/domain, 100
#      domain ölçeğinde ~576.000 kayıt/gün, GERÇEK sinyal sıfır). Bu
#      istisna GEREKÇELİ ve AÇIK bir beyaz listede tutulur (aşağıda) —
#      biri ileride sessizce üçüncü bir düz 'deny' eklerse bu test KIRILIR.
#
#   4) DÜZ (audit'siz) CAPABILITY-DENY İNVARİANT'I — DEDEKTÖR 3'ÜN AYNI
#      MANTIĞI, CAPABILITY kuralları için: HOST'ta profile.tpl için de
#      yüksek frekanslı bir denial ölçüldü ('capability="net_admin"',
#      64 dk'da 848/861 kayıt — TÜM DENIED kayıtlarının ~%98'i). Kök
#      neden eşlenik SYSCALL kaydıyla DOĞRULANDI: php-fpm master'ın
#      Type=notify sd_notify() çağrısı önce SO_SNDBUFFORCE (CAP_NET_ADMIN
#      ister) dener, reddedilince sessizce SO_SNDBUF'a düşer — unit
#      'active'/'NRestarts: 0', işlev kaybı YOK. CAP_NET_ADMIN (netfilter/
#      arayüz/promiscuous-mod yetkisi taşıdığından) BİLEREK VERİLMEDİ;
#      bunun yerine tam da 'stty' ile AYNI sınıf gerekçeyle düz
#      'deny capability net_admin,' eklendi (bkz. profile.tpl'deki
#      "ÇÖZÜLMÜŞ BULGU" bloğu). Dedektör 3 yalnızca PATH (yol) tabanlı
#      'x' kurallarını tarar — capability kuralları farklı bir sözdizimi
#      olduğundan ('deny capability <ad>,' — dosya yolu YOK) dedektör 3'ün
#      regex'iyle hiç eşleşmez; bu yüzden AYRI bir dedektör ve AYRI,
#      GEREKÇELİ bir beyaz liste gerekir (aşağıda — tek üye:
#      'profile.tpl:net_admin').
#
# KENDİ KENDİNİ DOĞRULAMA (zorunlu — bkz. CLAUDE.md/proje kuralı):
# tarayıcı sessizce hep PASS vermemeli. Sentetik fixture'larla dört
# dedektör de (gölgeleme, whitelist-kilidi, düz-exec-deny invariant'ı,
# düz-capability-deny invariant'ı) MUTASYON testine tabi tutulur (bkz.
# dosya sonu).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

PROFILE_TPL="${REPO_ROOT}/templates/apparmor/profile.tpl"
PROFILE_CLI_TPL="${REPO_ROOT}/templates/apparmor/profile-cli.tpl"

# ─── {{TOKEN}} yer tutucularını KORU (render EDİLMEDEN çalışıyoruz) ───
# '{{PHP_VERSION}}' gibi bir token, AppArmor glob sözdiziminde çift süslü
# parantez İÇERMEZ (render SONRASI düz bir değerle — ör. '8.1' — değişir).
# Ama .tpl METNİ ÜZERİNDE çalışan bu tarayıcı için '{' brace-alternation
# karakteri olduğundan '{{...}}' bloklarını ERKEN bir aşamada opak, glob-
# özel-karakter İÇERMEYEN bir yer tutucuya çevirmemiz gerekir — yoksa
# brace-expansion mantığımız token'ı yanlışlıkla bir alternation grubu
# sanır. Aynı token her iki tarafta (allow/deny) da AYNI yer tutucuya
# dönüştüğü için eşleşme mantığı bozulmaz.
_aa_protect_tokens() {
    printf '%s' "$1" | sed -E 's/\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}/TOKEN_\1_TOKEN/g'
}

# ─── AppArmor brace-alternation'ı ('{a,b,c}') genişlet ───
# Yalnızca TEK SEVİYE, tek grup destekler (bu iki dosyadaki gerçek kullanım
# deseni budur — iç içe/çoklu grup YOK). Girdi zaten '_aa_protect_tokens'
# ile işlenmiş olmalı (yoksa '{{TOKEN}}' yanlış bölünür).
_aa_expand_braces() {
    local s="$1"
    if [[ "$s" == *"{"*"}"* ]]; then
        local pre="${s%%\{*}"
        local rest="${s#*\{}"
        local group="${rest%%\}*}"
        local post="${rest#*\}}"
        local IFS=','
        local alt
        for alt in $group; do
            printf '%s\n' "${pre}${alt}${post}"
        done
    else
        printf '%s\n' "$s"
    fi
}

# ─── AppArmor path glob'unu POSIX ERE'ye çevir (çapa'lı: '^...$') ───
# '**' → herhangi bir dizi (yol ayracı '/' dahil), tek '*' → '/' HARİÇ
# herhangi bir dizi, '?' → '/' HARİÇ tek karakter. Diğer ERE özel
# karakterleri ('.', '^', '$', '(', ')', '+', '|', '[', ']', '{', '}')
# kaçırılır (brace-expansion ZATEN uygulanmış olmalı, bu yüzden kalan
# '{'/'}' varsa — olmamalı ama savunma amaçlı — literal kabul edilir).
_aa_glob_to_ere() {
    local g="$1" out
    out=$(printf '%s' "$g" | sed -E 's/([.^$()+|\[\]{}])/\\\1/g')
    out="${out//\*\*/@@DBLSTAR@@}"
    out="${out//\*/[^\/]*}"
    out="${out//@@DBLSTAR@@/.*}"
    out="${out//\?/[^\/]}"
    printf '^%s$' "$out"
}

_aa_glob_matches() {
    local glob="$1" literal="$2" ere
    ere="$(_aa_glob_to_ere "$glob")"
    [[ "$literal" =~ $ere ]]
}

# ─── ÜRETİCİ tarayıcılar: profil METNİNDEN (dosya değil, fixture'larla da
#     test edilebilsin diye) deny/allow 'x' kurallarının YOLLARINI çıkar ───
_aa_extract_deny_x_paths() {
    local text="$1"
    printf '%s\n' "$text" \
        | grep -E '^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]]+/' \
        | while IFS= read -r line; do
            local perm path
            perm=$(printf '%s' "$line" | grep -oE '[A-Za-z]+,?[[:space:]]*$' | tr -d ', \t')
            [[ "$perm" == *x* ]] || continue
            path=$(printf '%s' "$line" \
                | sed -E 's/^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]]+//; s/[[:space:]]+[A-Za-z]+,?[[:space:]]*$//')
            printf '%s\n' "$path"
        done
}

_aa_extract_allow_x_paths() {
    local text="$1"
    printf '%s\n' "$text" \
        | grep -E '^[[:space:]]*/' \
        | grep -vE '^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]]' \
        | while IFS= read -r line; do
            local perm path
            perm=$(printf '%s' "$line" | grep -oE '[A-Za-z]+,?[[:space:]]*$' | tr -d ', \t')
            [[ "$perm" == *x* ]] || continue
            path=$(printf '%s' "$line" \
                | sed -E 's/^[[:space:]]*//; s/[[:space:]]+[A-Za-z]+,?[[:space:]]*$//')
            printf '%s\n' "$path"
        done
}

# ─── DEDEKTÖR 1: deny-gölgeleme. Boş string = gölgeleme YOK. ───
_aa_shadow_findings() {
    local profile_text="$1"
    local deny_list allow_list findings=""
    deny_list="$(_aa_extract_deny_x_paths "$profile_text")"
    allow_list="$(_aa_extract_allow_x_paths "$profile_text")"

    local -a allow_arr=()
    local a
    while IFS= read -r a; do
        [[ -n "$a" ]] && allow_arr+=("$(_aa_protect_tokens "$a")")
    done <<< "$allow_list"

    local d dp expanded
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        dp="$(_aa_protect_tokens "$d")"
        while IFS= read -r expanded; do
            [[ -n "$expanded" ]] || continue
            for a in "${allow_arr[@]}"; do
                if _aa_glob_matches "$expanded" "$a"; then
                    findings+="deny '${d}' -> allow '${a}' GÖLGELENİYOR; "
                fi
            done
        done <<< "$(_aa_expand_braces "$dp")"
    done <<< "$deny_list"

    printf '%s' "$findings"
}

# ─── DEDEKTÖR 2: exec whitelist kümesi (sıralı, boşlukla ayrık) ───
_aa_exec_allow_set() {
    local text="$1"
    _aa_extract_allow_x_paths "$text" | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ─── DEDEKTÖR 3: düz (audit'siz) exec-only deny invariant'ı ───
#
# BEYAZ LİSTE — yalnızca burada GEREKÇELİ olarak listelenen "dosya
# etiketi:tam yol" çiftleri düz 'deny <yol> x,' olarak KALABİLİR. Yeni bir
# istisna eklemek isteyen biri bu listeyi GÖRMEK ZORUNDA kalır (sessizce
# üçüncü bir istisna eklenemez, bkz. dosya başı NOT).
#
#   profile-cli.tpl:/usr/bin/stty
#     HOST ölçümü (srvctl-jammy VM): worker+scheduler ilk kez ayağa
#     kaldırılıp gerçek Laravel queue:work + schedule:run ile
#     ölçüldüğünde audit.log'da SÜREKLİ bir 'operation="exec"
#     name="/usr/bin/stty"' akışı görüldü (Symfony Console'un 'stty -a'
#     terminal-genişliği yoklaması; scheduler dakikada bir tetiklendiği
#     için KALICI). Ölçülen hız: 2 dk'da 8 kayıt = 4/dk/domain; 100
#     domain hedefinde ~576.000 kayıt/gün — GERÇEK sinyal SIFIR (Symfony
#     sessizce 80x50 varsayılanına düşüyor, işlevsel etki yok). Düz
#     'deny'nin DOĞRU kullanım vakası.
#
#   NOT — 'capability net_admin' NEDEN BU LİSTEDE YOK: profile.tpl'de de
#   yüksek frekanslı bir 'capability="net_admin"' denial'ı ölçüldü ve kök
#   nedeni HOST'ta DOĞRULANDI (bkz. profile.tpl'deki "ÇÖZÜLMÜŞ BULGU"
#   bloğu) — ama bu, PATH TABANLI bir 'x' kuralı DEĞİL, bir 'capability'
#   kuralı (dosya yolu yok). Bu dedektörün regex'i yalnızca '/' ile
#   başlayan yol satırlarını tarar, capability kurallarıyla ZATEN
#   eşleşmez. O yüzden AYRI bir dedektör (DEDEKTÖR 4, aşağıda) ve AYRI,
#   GEREKÇELİ bir beyaz liste (tek üye: 'profile.tpl:net_admin') kullanılır.
_AA_KNOWN_SUPPRESSED_EXEC_DENIES="profile-cli.tpl:/usr/bin/stty"

_aa_is_known_suppressed() {
    local file_label="$1" path="$2" entry
    for entry in $_AA_KNOWN_SUPPRESSED_EXEC_DENIES; do
        [[ "$entry" == "${file_label}:${path}" ]] && return 0
    done
    return 1
}

# Verilen METİNDE, İZNİ TAM OLARAK 'x' olan (rwx gibi bileşik izinler
# KAPSAM DIŞI — bu dedektör özellikle HOST'ta ölçülen 'operation="exec"'
# sınıfını hedefler) ve önünde 'audit' OLMAYAN 'deny <yol> x,' satırlarını
# bulur; beyaz listedekiler HARİÇ. Boş string = ihlal YOK.
_aa_plain_execonly_deny_findings() {
    local file_label="$1" text="$2" findings=""
    local line perm path
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        perm=$(printf '%s' "$line" | grep -oE '[A-Za-z]+,?[[:space:]]*$' | tr -d ', \t')
        [[ "$perm" == "x" ]] || continue
        path=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*deny[[:space:]]+//; s/[[:space:]]+[A-Za-z]+,?[[:space:]]*$//')
        _aa_is_known_suppressed "$file_label" "$path" && continue
        findings+="${file_label}: ${line}; "
    done <<< "$(printf '%s\n' "$text" | grep -E '^[[:space:]]*deny[[:space:]]+/')"
    printf '%s' "$findings"
}

# Beyaz listedeki bir girdinin GERÇEKTEN dosyada, tam beklenen biçimde
# ('deny <yol> x,' — audit'siz) VAR OLDUĞUNU doğrular; böylece beyaz
# liste "hayali" bir istisnayı meşrulaştırmaz (biri satırı sessizce
# 'audit deny'e çevirir ya da silerse bu da fark edilir — o durumda
# istisna zaten gereksiz hale gelir ve beyaz liste güncellemesi gerekir).
_aa_has_plain_exec_deny_for() {
    local text="$1" path="$2" path_ere
    path_ere=$(printf '%s' "$path" | sed -E 's/[.^$*+?()[\]{}|\\]/\\&/g')
    printf '%s\n' "$text" | grep -qE "^[[:space:]]*deny[[:space:]]+${path_ere}[[:space:]]+x,?[[:space:]]*\$"
}

# ─── DEDEKTÖR 4: düz (audit'siz) CAPABILITY-deny invariant'ı ───
# DEDEKTÖR 3'ün AYNI mantığı, farklı sözdizimi için: 'deny capability
# <ad>,' satırlarının dosya yolu YOK, bu yüzden DEDEKTÖR 3'ün regex'iyle
# (yalnızca '/' ile başlayan satırları tarar) hiç eşleşmezler — AYRI bir
# tarayıcı ve AYRI bir beyaz liste gerekir.
#
# BEYAZ LİSTE — yalnızca burada GEREKÇELİ olarak listelenen "dosya
# etiketi:capability adı" çiftleri düz 'deny capability <ad>,' olarak
# KALABİLİR.
#
#   profile.tpl:net_admin
#     HOST ölçümü (srvctl-jammy VM) + eşlenik SYSCALL kaydıyla DOĞRULANAN
#     kök neden: php-fpm master'ın Type=notify sd_notify() çağrısı önce
#     setsockopt(SO_SNDBUFFORCE) dener (CAP_NET_ADMIN ister), reddedilince
#     SESSİZCE SO_SNDBUF'a düşer. Ölçülen hacim: 64 dk'da 848/861 kayıt
#     (~%98) — TÜM domain'lerdeki 'audit deny' adlandırılmış listelerinin
#     tespit sinyalini FİİLEN BOĞUYORDU. Zararsız olduğunun kanıtı: unit
#     'active', 'NRestarts: 0' (Type=notify başlatma READY=1 ile
#     BAŞARILI). CAP_NET_ADMIN (netfilter/arayüz/promiscuous-mod yetkisi
#     taşıdığından) BİLEREK VERİLMEDİ — susturma tercih edildi, capability
#     EKLEME değil (bkz. profile.tpl'deki "ÇÖZÜLMÜŞ BULGU" bloğu).
_AA_KNOWN_SUPPRESSED_CAPABILITY_DENIES="profile.tpl:net_admin"

_aa_is_known_suppressed_capability() {
    local file_label="$1" cap="$2" entry
    for entry in $_AA_KNOWN_SUPPRESSED_CAPABILITY_DENIES; do
        [[ "$entry" == "${file_label}:${cap}" ]] && return 0
    done
    return 1
}

# Verilen METİNDE, önünde 'audit' OLMAYAN 'deny capability <ad>,'
# satırlarını bulur; beyaz listedekiler HARİÇ. Boş string = ihlal YOK.
_aa_plain_capability_deny_findings() {
    local file_label="$1" text="$2" findings=""
    local line cap
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        cap=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*deny[[:space:]]+capability[[:space:]]+//; s/,?[[:space:]]*$//')
        _aa_is_known_suppressed_capability "$file_label" "$cap" && continue
        findings+="${file_label}: ${line}; "
    done <<< "$(printf '%s\n' "$text" | grep -E '^[[:space:]]*deny[[:space:]]+capability[[:space:]]+')"
    printf '%s' "$findings"
}

# Beyaz listedeki bir girdinin GERÇEKTEN dosyada var olduğunu doğrular
# (hayali istisna olmadığından emin ol — bkz. dedektör 3'teki AYNI NOT).
_aa_has_plain_capability_deny_for() {
    local text="$1" cap="$2" cap_ere
    cap_ere=$(printf '%s' "$cap" | sed -E 's/[.^$*+?()[\]{}|\\]/\\&/g')
    printf '%s\n' "$text" | grep -qE "^[[:space:]]*deny[[:space:]]+capability[[:space:]]+${cap_ere},?[[:space:]]*\$"
}

# ═══════════════════════════════════════════════════════════════
# KENDİ KENDİNİ DOĞRULAMA — MUTASYON testleri (sentetik fixture'lar)
# ═══════════════════════════════════════════════════════════════
echo "== Kendi kendini doğrulama (sentetik fixture / mutasyon) =="

# (a) BUG 1'in TAM ÖRNEĞİ: blanket deny, tam-yol allow'u gölgeliyor.
fixture_bug1='
profile p {
  /usr/sbin/php-fpm{{PHP_VERSION}} mrix,
  deny /usr/sbin/** x,
}
'
out="$(_aa_shadow_findings "$fixture_bug1")"
assert_contains "$out" "GÖLGELENİYOR" \
    "mutasyon: blanket 'deny /usr/sbin/** x' php-fpm allow'unu GÖLGELİYOR (BUG 1 sınıfı yakalandı)"

# (b) Adlandırılmış (brace) deny bir allow'u YANLIŞLIKLA kapsıyor —
#     ör. biri 'php-fpm' yerine yanlışlıkla 'php-fpm{{PHP_VERSION}}' adını
#     brace listesine EKLERSE bu da yakalanmalı.
fixture_named_conflict='
profile p {
  /usr/sbin/php-fpm{{PHP_VERSION}} mrix,
  deny /usr/sbin/{useradd,userdel,php-fpm{{PHP_VERSION}}} x,
}
'
out="$(_aa_shadow_findings "$fixture_named_conflict")"
assert_contains "$out" "GÖLGELENİYOR" \
    "mutasyon: adlandırılmış deny listesine yanlışlıkla eklenen allow adı da YAKALANIYOR"

# (c) KONTROL GRUBU — çakışmayan adlandırılmış deny (gerçek MADDE B deseni):
#     YANLIŞ POZİTİF üretmemeli.
fixture_ok='
profile p {
  /usr/sbin/php-fpm{{PHP_VERSION}} mrix,
  audit deny /usr/sbin/{useradd,userdel,visudo,chroot} x,
  deny /usr/bin/** x,
  deny /bin/** x,
  deny /sbin/** x,
}
'
out="$(_aa_shadow_findings "$fixture_ok")"
assert_eq "$out" "" \
    "kontrol grubu: çakışmayan adlandırılmış deny + kalan blanket deny'ler YANLIŞ POZİTİF üretmiyor"

# (d) Exec whitelist kilidi — beklenen kümeyle eşleşiyor mu?
fixture_whitelist='
profile p {
  /usr/sbin/php-fpm{{PHP_VERSION}} mrix,
  audit deny /usr/sbin/{useradd,chroot} x,
}
'
out="$(_aa_exec_allow_set "$fixture_whitelist")"
assert_eq "$out" "/usr/sbin/php-fpm{{PHP_VERSION}}" \
    "dedektör: exec whitelist kümesini doğru çıkarıyor (tek allow)"

# (e) MUTASYON: whitelist'e ikinci bir geniş 'x' allow'u eklenirse küme
#     BÜYÜMELİ — bu, "biri ileride geniş bir x eklerse test kırılsın"
#     gereksiniminin dedektör seviyesinde doğrulanması.
fixture_widened='
profile p {
  /usr/sbin/php-fpm{{PHP_VERSION}} mrix,
  /usr/sbin/** rix,
}
'
out="$(_aa_exec_allow_set "$fixture_widened")"
assert_contains "$out" "/usr/sbin/**" \
    "mutasyon: yeni eklenen geniş 'x' allow'u whitelist kümesine YANSIYOR (aşağıdaki gerçek-dosya kilidi bunu FAIL ettirir)"

# (f) MUTASYON — DEDEKTÖR 3: beyaz listede OLMAYAN bir düz exec-only deny
#     (ör. biri gerçek 'stty' vakasına benzeterek ikinci bir binary'yi
#     sessizce susturmaya kalkışırsa) YAKALANMALI.
fixture_plain_unlisted='
profile p {
  deny /usr/bin/curl x,
}
'
out="$(_aa_plain_execonly_deny_findings "profile-cli.tpl" "$fixture_plain_unlisted")"
assert_contains "$out" "/usr/bin/curl" \
    "mutasyon: beyaz listede OLMAYAN düz 'deny .../curl x,' YAKALANIYOR"

# (g) KONTROL GRUBU — beyaz listedeki gerçek istisna (doğru dosya
#     etiketiyle) YANLIŞ POZİTİF üretmemeli.
fixture_plain_listed='
profile p {
  deny /usr/bin/stty x,
}
'
out="$(_aa_plain_execonly_deny_findings "profile-cli.tpl" "$fixture_plain_listed")"
assert_eq "$out" "" \
    "kontrol grubu: beyaz listedeki 'profile-cli.tpl:/usr/bin/stty' istisnası YANLIŞ POZİTİF üretmiyor"

# (h) BEYAZ LİSTE DOSYAYA ÖZGÜDÜR — aynı yol YANLIŞ dosya etiketiyle
#     gelirse (ör. biri stty istisnasını profile.tpl'e de taşırsa)
#     YAKALANMALI. Ölçüm yalnız worker/scheduler (-cli) bağlamı için
#     yapıldı; FPM master bağlamına sessizce genelleştirilmemeli.
out="$(_aa_plain_execonly_deny_findings "profile.tpl" "$fixture_plain_listed")"
assert_contains "$out" "/usr/bin/stty" \
    "mutasyon: 'stty' istisnası YANLIŞ dosya etiketinde (profile.tpl) YAKALANIYOR — beyaz liste dosyaya özgü"

# (i) KONTROL GRUBU — 'audit deny' (audit'li) hiçbir zaman bu dedektöre
#     takılmamalı (zaten loglanıyor, invariant'ın ilgilendiği durum bu
#     DEĞİL).
fixture_audited='
profile p {
  audit deny /usr/bin/curl x,
}
'
out="$(_aa_plain_execonly_deny_findings "profile-cli.tpl" "$fixture_audited")"
assert_eq "$out" "" \
    "kontrol grubu: 'audit deny' asla düz-exec-deny invariant'ını ihlal etmiyor"

# (j) KONTROL GRUBU — bileşik izin ('rwx') KAPSAM DIŞI (bu dedektör
#     yalnızca HOST'ta ölçülen saf-'x' exec denial sınıfını hedefler;
#     /home, /root, /usr/local/srvctl gibi genel rwx kuralları BİLİNÇLİ
#     olarak bu invariant'ın kapsamı DIŞINDA tutulur).
fixture_compound_perm='
profile p {
  deny /home/** rwx,
}
'
out="$(_aa_plain_execonly_deny_findings "profile-cli.tpl" "$fixture_compound_perm")"
assert_eq "$out" "" \
    "kontrol grubu: bileşik izinli ('rwx') deny kuralları bu invariant'ın KAPSAMI DIŞINDA (yanlış pozitif yok)"

# (k) MUTASYON — DEDEKTÖR 4: beyaz listede OLMAYAN bir düz capability-deny
#     (ör. biri 'net_admin' örneğine benzeterek farklı bir capability'yi
#     sessizce susturmaya kalkışırsa) YAKALANMALI.
fixture_cap_unlisted='
profile p {
  deny capability sys_admin,
}
'
out="$(_aa_plain_capability_deny_findings "profile.tpl" "$fixture_cap_unlisted")"
assert_contains "$out" "sys_admin" \
    "mutasyon: beyaz listede OLMAYAN düz 'deny capability sys_admin,' YAKALANIYOR"

# (l) KONTROL GRUBU — beyaz listedeki gerçek istisna (doğru dosya
#     etiketiyle) YANLIŞ POZİTİF üretmemeli.
fixture_cap_listed='
profile p {
  deny capability net_admin,
}
'
out="$(_aa_plain_capability_deny_findings "profile.tpl" "$fixture_cap_listed")"
assert_eq "$out" "" \
    "kontrol grubu: beyaz listedeki 'profile.tpl:net_admin' istisnası YANLIŞ POZİTİF üretmiyor"

# (m) BEYAZ LİSTE DOSYAYA ÖZGÜDÜR — aynı capability YANLIŞ dosya
#     etiketiyle gelirse YAKALANMALI (ölçüm yalnız FPM master/profile.tpl
#     bağlamı için yapıldı; worker/scheduler'a sessizce genelleştirilmemeli).
out="$(_aa_plain_capability_deny_findings "profile-cli.tpl" "$fixture_cap_listed")"
assert_contains "$out" "net_admin" \
    "mutasyon: 'net_admin' istisnası YANLIŞ dosya etiketinde (profile-cli.tpl) YAKALANIYOR — beyaz liste dosyaya özgü"

# (n) KONTROL GRUBU — 'audit deny capability' hiçbir zaman bu dedektöre
#     takılmamalı.
fixture_cap_audited='
profile p {
  audit deny capability sys_admin,
}
'
out="$(_aa_plain_capability_deny_findings "profile.tpl" "$fixture_cap_audited")"
assert_eq "$out" "" \
    "kontrol grubu: 'audit deny capability' asla düz-capability-deny invariant'ını ihlal etmiyor"

# ═══════════════════════════════════════════════════════════════
# ASIL DENETİM — gerçek templates/apparmor/*.tpl dosyaları
# ═══════════════════════════════════════════════════════════════
echo ""
echo "== Gerçek templates/apparmor/profile.tpl + profile-cli.tpl denetimi =="

fpm_text="$(cat "$PROFILE_TPL")"
cli_text="$(cat "$PROFILE_CLI_TPL")"

# --- Dedektör 1: deny-gölgeleme ---
fpm_shadow="$(_aa_shadow_findings "$fpm_text")"
assert_eq "$fpm_shadow" "" \
    "profile.tpl: hiçbir 'deny ... x' kuralı bir 'x' allow'unu gölgelemiyor"
[[ -n "$fpm_shadow" ]] && printf '  %s\n' "$fpm_shadow" >&2

cli_shadow="$(_aa_shadow_findings "$cli_text")"
assert_eq "$cli_shadow" "" \
    "profile-cli.tpl: hiçbir 'deny ... x' kuralı bir 'x' allow'unu gölgelemiyor"
[[ -n "$cli_shadow" ]] && printf '  %s\n' "$cli_shadow" >&2

# --- Dedektör 2: exec whitelist kilidi (TAM küme) ---
fpm_set="$(_aa_exec_allow_set "$fpm_text")"
assert_eq "$fpm_set" "/usr/sbin/php-fpm{{PHP_VERSION}}" \
    "profile.tpl: x-izinli TAM yol kümesi yalnızca php-fpm{{PHP_VERSION}}'dan ibaret"

cli_expected="$(printf '%s\n' "/bin/sh" "/usr/bin/dash" "/usr/bin/flock" "/usr/bin/php{{PHP_VERSION}}" | sort | tr '\n' ' ' | sed 's/ *$//')"
cli_set="$(_aa_exec_allow_set "$cli_text")"
assert_eq "$cli_set" "$cli_expected" \
    "profile-cli.tpl: x-izinli TAM yol kümesi yalnızca php{{PHP_VERSION}}/sh/dash/flock'tan ibaret (flock: lib/cron.sh deploy-kilidi — koordinatör HOST bulgusu)"

# --- Dedektör 3: düz (audit'siz) exec-only deny invariant'ı ---
fpm_plain="$(_aa_plain_execonly_deny_findings "profile.tpl" "$fpm_text")"
assert_eq "$fpm_plain" "" \
    "profile.tpl: 'x' izni içeren HİÇBİR düz (audit'siz) deny kuralı yok (istisna listesi BOŞ)"
[[ -n "$fpm_plain" ]] && printf '  %s\n' "$fpm_plain" >&2

cli_plain="$(_aa_plain_execonly_deny_findings "profile-cli.tpl" "$cli_text")"
assert_eq "$cli_plain" "" \
    "profile-cli.tpl: 'x' izni içeren düz (audit'siz) deny kuralları yalnız GEREKÇELİ beyaz listedeki (stty) ile sınırlı"
[[ -n "$cli_plain" ]] && printf '  %s\n' "$cli_plain" >&2

# Beyaz listenin GERÇEKTEN dosyada var olduğunu doğrula (hayali istisna
# olmadığından emin ol — bkz. '_aa_has_plain_exec_deny_for' NOT'u).
# (assert_ok yerine elle dallanma: assert_ok komutun TÜM argümanlarını
# PASS satırında yazdırır — ikinci argüman burada koca bir profil METNİ
# olduğundan assert_ok test çıktısını okunmaz hale getirirdi.)
if _aa_has_plain_exec_deny_for "$cli_text" "/usr/bin/stty"; then
    assert_eq "var" "var" "profile-cli.tpl: beyaz listedeki '/usr/bin/stty' istisnası GERÇEKTEN düz 'deny' olarak dosyada mevcut"
else
    assert_eq "yok" "var" "profile-cli.tpl: beyaz listedeki '/usr/bin/stty' istisnası GERÇEKTEN düz 'deny' olarak dosyada mevcut"
fi

# --- Dedektör 4: düz (audit'siz) capability-deny invariant'ı ---
fpm_cap_plain="$(_aa_plain_capability_deny_findings "profile.tpl" "$fpm_text")"
assert_eq "$fpm_cap_plain" "" \
    "profile.tpl: düz (audit'siz) capability-deny kuralları yalnız GEREKÇELİ beyaz listedeki (net_admin) ile sınırlı"
[[ -n "$fpm_cap_plain" ]] && printf '  %s\n' "$fpm_cap_plain" >&2

cli_cap_plain="$(_aa_plain_capability_deny_findings "profile-cli.tpl" "$cli_text")"
assert_eq "$cli_cap_plain" "" \
    "profile-cli.tpl: düz (audit'siz) capability-deny kuralı YOK (istisna listesi bu dosya için BOŞ)"
[[ -n "$cli_cap_plain" ]] && printf '  %s\n' "$cli_cap_plain" >&2

if _aa_has_plain_capability_deny_for "$fpm_text" "net_admin"; then
    assert_eq "var" "var" "profile.tpl: beyaz listedeki 'net_admin' istisnası GERÇEKTEN düz 'deny capability' olarak dosyada mevcut"
else
    assert_eq "yok" "var" "profile.tpl: beyaz listedeki 'net_admin' istisnası GERÇEKTEN düz 'deny capability' olarak dosyada mevcut"
fi

test_summary
