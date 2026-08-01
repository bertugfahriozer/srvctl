#!/bin/bash
# ═══════════════════════════════════════════════
#  cron.sh — Kullanıcı Dostu Cron (arka planda systemd timer)
# ═══════════════════════════════════════════════
#
# NEDEN crontab DEĞİL: bir crontab satırı root'un cron daemon'ından PROFİLSİZ
# doğar — srvctl'in domain başına kurduğu tüm izolasyonu (AppArmor, cgroup
# slice, seccomp, NoNewPrivileges, domain kullanıcısı) DELER. Bu modül
# yerine systemd timer + oneshot service kurar; şablonlar (templates/systemd/
# srvctl-cron*.tpl, srvctl-syscron*.tpl — AYRI bir görevde yazıldı) domain
# kapsamlı cron'u worker/scheduler İLE AYNI izolasyon katmanlarına
# (AppArmorProfile, Slice, seccomp deny listesi) bağlar.
#
# KAPSAM (kullanıcı kararı): HEM domain-bazlı HEM sistem geneli cron'lar.
#   - Domain:  srvctl-cron-<sname>-<ad>.service/.timer     (web_<sname> olarak çalışır)
#   - Sistem:  srvctl-syscron-<ad>.service/.timer          (root olarak çalışır)
#
# BAŞARISIZLIK (kullanıcı kararı): bildir + kaydet, OTOMATİK TEKRAR YOK.
# srvctl-cron*.service.tpl BİLİNÇLİ OLARAK 'Restart=' KULLANMAZ (bkz. o
# şablonların başlık yorumu) — bir sonraki planlı zamanda timer zaten kendi
# kendine tekrar dener, bu YETERLİDİR. "Bildir + kaydet" burada systemd'nin
# 'OnFailure=' mekanizmasıyla uygulanır: her cron unit'i için bir DROP-IN
# ('<unit>.service.d/override.conf', BU MODÜL tarafından, TOKENS kontratlı
# ana şablonlara DOKUNMADAN üretilir) 'OnFailure=srvctl-cron(fail)-...'
# adında KÜÇÜK, KENDİMİZE AİT, statik bir bildirim unit'ine işaret eder — bu
# unit ROOT olarak çalışır (User= YOK) ve log_action + send_notification'ı
# ('lib/notify.sh', guard'lı source — CLAUDE.md deseni) tetikler. Cron
# job'unun KENDİSİ web_<sname> (izole/yetkisiz) olarak çalıştığından, log/
# bildirim işini AYRI, root'ta çalışan bir unit'e devretmek permission
# sorunlarından (srvctl.log root:root'a ait) kaçınmanın TEK temiz yoludur.
#
# ZAMAN DİLİMİ (kullanıcı kararı, AÇIKÇA burada belgeleniyor):
#   - Türkçe kısayol VE 5 alanlı cron sözdizimi çevirileri HER ZAMAN UTC'ye
#     SABİTLENİR (hesaplanan OnCalendar ifadesinin sonuna her zaman ' UTC'
#     eklenir) — sunucunun /etc/localtime ayarından TAMAMEN BAĞIMSIZ,
#     öngörülebilir/tekrarlanabilir davranış için BİLİNÇLİ bir tasarım
#     kararıdır. 'cron list'/'cron show' bunu HER ZAMAN görünür kılar
#     (OnCalendar çıktısında literal 'UTC' vardır).
#   - Ham systemd modu ("uzman kullanımı") OLDUĞU GİBİ geçer — HİÇBİR ŞEY
#     eklenmez/değiştirilmez. Dilim belirtilmemişse systemd'nin KENDİ
#     varsayılanı (sunucunun yerel saati) geçerlidir; bu 'cron add' sırasında
#     AÇIKÇA uyarılır.
#
# KOMUT/ENJEKSİYON SÖZLEŞMESİ (ÇOK ÖNEMLİ — şablonların KENDİ başlık
# yorumunda da belgelenmiştir, bkz. srvctl-cron.service.tpl):
#   ExecStart=/bin/sh -c '{{CRON_COMMAND}}'  — yani CRON_COMMAND KASITLI
#   OLARAK bir KABUK dizgesidir (crontab satırındaki komut kısmıyla AYNI
#   semantik: '&&'/'|'/';'/yönlendirme/'$DEĞİŞKEN' BEKLENİR — aksi halde
#   crontab'tan taşınan hiçbir gerçek iş çalışmazdı). systemd'nin Exec
#   satırı ayrıştırıcısı KABUK DEĞİLDİR (yalnız boşlukla böler) — bu yüzden
#   '/bin/sh -c' sarmalaması şablonun KENDİSİNDE sabit. render_template
#   (core.sh) yalnız satırsonu/CR'yi reddeder; tek/çift tırnak, '$',
#   backtick gibi kabuk metakarakterlerini KAÇIRMAZ (bilerek — genel bir
#   string-replace katmanıdır). Bu yüzden İKİ kaçış adımı TAMAMEN BU MODÜLE
#   (aşağıdaki _cron_escape_* fonksiyonları) YÜKLENİR:
#     1) TEK TIRNAK kaçışı (POSIX ' → '\''): CRON_COMMAND, şablonda TEK
#        TIRNAK içine yerleştirildiğinden (ExecStart=/bin/sh -c '...'),
#        ham metindeki HER tek tırnak bu desenle genişletilmek ZORUNDADIR —
#        aksi halde metin ERKEN sonlanır ve geri kalanı systemd'nin Exec
#        satırı sözdizimine SIZAR (en kötü durumda unit YÜKLENEMEZ/parse
#        hatası verir; render_template'in newline/CR reddi sayesinde YENİ
#        bir '[Section]'/'Key=' satırı ASLA enjekte edilemez — blast radius
#        Exec satırının KENDİSİYLE sınırlıdır).
#     2) '%' İKİLEMESİ: systemd, kabuğu görmeden ÖNCE ExecStart= (VE
#        Description=) satırının TAMAMINDA KENDİ '%' specifier
#        genişletmesini yapar (ör. '%h','%i') — ham komutta/açıklamada
#        literal '%' varsa BU MODÜL onu '%%' olarak İKİLEMEK ZORUNDADIR.
#   Bu iki adım _cron_add()'de UYGULANIR (bkz. o fonksiyonun "Kabuk
#   sarmalama + kaçış" bölümü) — sıra: (a) [yalnız domain+flock] komut
#   flock ile sarmalanır (bkz. aşağıdaki DEPLOY KİLİDİ notu, kendi İÇ
#   tek-tırnak kaçışıyla), (b) TÜM gövdeye TEK TIRNAK kaçışı (dış bağlam
#   için), (c) EN SON adım olarak '%' ikilemesi (hiçbir kaçış '%' üretmez/
#   tüketmez, bu yüzden sıralama güvenlidir).
#
# DEPLOY KİLİDİ (görev talebi — deploy sürerken domain cron'u ÇALIŞMAMALI):
#   lib/deploy.sh:_deploy_lock 'flock -n 9' ile ${SRVCTL_LOCK_DIR:-/run/srvctl}/
#   deploy-<sname>.lock dosyasını kilitler. Bu modül AYNI kilit dosyasını
#   KARŞI taraftan kullanır: domain cron'unun kabuk gövdesi
#   'flock -n -E 75 <kilit-dosyası> -c '<komut>'' İLE SARMALANIR — kilit
#   deploy tarafından TUTULUYORSA flock komutu HİÇ ÇALIŞTIRMADAN 75
#   (sysexits.h EX_TEMPFAIL — "geçici, yeniden dene") ile çıkar. '_on-failure'
#   handler'ı bu KODU ÖZEL OLARAK tanır: log_action ile KAYDEDER ama
#   send_notification ÇAĞIRMAZ (bu bir GERÇEK başarısızlık DEĞİL, beklenen
#   bir atlama — deploy sırasında HER dakika bildirim spam'i istenmez). Bir
#   SONRAKİ planlı tetiklemede (deploy muhtemelen bitmiş olacağından) normal
#   şekilde tekrar dener — 'otomatik tekrar YOK' kuralına AYKIRI DEĞİLDİR
#   (bu, systemd timer'ın zaten planlanmış BİR SONRAKİ çalışmasıdır, ekstra
#   bir retry DEĞİL). 'flock' yoksa (çok minimal bir imaj) bu koruma
#   ATLANIR ve operatör 'cron add' sırasında AÇIKÇA uyarılır (lib/deploy.sh
#   ile AYNI graceful-degrade deseni). Sistem cron'ları ('--system') bir
#   domain'e bağlı OLMADIĞINDAN bu sarmalamayı HİÇ ALMAZ.
#
# YAZMA İZNİ (ProtectSystem=strict + ReadWritePaths=): domain cron'u
# WORKING_DIR (WEB_ROOT/<domain>/current) DEĞİL, DOMAIN_ROOT'un TAMAMINA
# (WEB_ROOT/<domain> — current/releases/shared/logs/tmp/sessions HEPSİ)
# yazabilir — worker/scheduler İLE AYNI desen (bkz. srvctl-cron.service.tpl
# başlık yorumu). İLK sürümde yalnız WORKING_DIR kullanılıyordu ve bu,
# 'writable/'/'storage/' gibi KARDEŞ dizinlere yazan HER TİPİK cron işini
# (cache temizliği, log rotasyonu) EROFS ile kırıyordu — TOKENS kontratı
# DOMAIN_ROOT eklenerek genişletildi, bu modül şimdi her domain cron
# render'ında besliyor.
#
# CATCH-UP-ON-BOOT (Persistent=): sunucu kapalıyken kaçan bir çalışmanın
# açılışta telafi edilip edilmeyeceği (systemd 'Persistent=') SABİT bir
# değer OLAMAZ — bir cache temizliği için 'false' (kaçırılırsa zararsız,
# tekrar SÜRPRİZ olur) doğruyken, gecelik bir yedekleme için 'true'
# (kaçırılırsa VERİ KAYBI riski) doğrudur; ikisi TAM TERS varsayılan ister.
# Karar operatöre bırakılır: 'srvctl cron add ... --catch-up-on-boot'
# vermeden varsayılan 'false' (crontab-parity, en az sürpriz); bayrak
# verilirse 'true'. 'cron add' hangi davranışın seçildiğini AÇIKÇA bildirir.
#
# PHP SÜRÜMÜ: komut 'php' ile (sürüm eki OLMADAN) başlıyorsa systemd bunu
# $PATH'te arar — bu, domain'in yapılandırılmış PHP sürümüyle AYNI OLMAYABİLİR
# (bu oturumda composer'ın host PHP'siyle çalışması TAM BU SINIF bir hataydı).
# 'cron add' bunu domain kapsamında AÇIKÇA uyarır (engellemez — yalnız uyarır).
set -uo pipefail 2>/dev/null || true

# ─── Varsayılanlar (env ile override edilebilir — test-seam) ───
CRON_DEFAULT_TIMEOUT="${CRON_DEFAULT_TIMEOUT:-3600}"                 # RUNTIME_MAX varsayılanı (sn)
CRON_DEFAULT_RANDOMIZED_DELAY="${CRON_DEFAULT_RANDOMIZED_DELAY:-30}" # RANDOMIZED_DELAY varsayılanı (sn)

# ═══════════════════════════════════════════════
#  GİRİŞ NOKTASI
# ═══════════════════════════════════════════════
cmd_cron() {
    case "${1:-help}" in
        add)         require_root; _cron_add "${@:2}" ;;
        list)        _cron_list "${@:2}" ;;
        show)        _cron_show "${@:2}" ;;
        run)         require_root; _cron_run "${@:2}" ;;
        enable)      require_root; _cron_set_enabled true "${@:2}" ;;
        disable)     require_root; _cron_set_enabled false "${@:2}" ;;
        remove)      require_root; _cron_remove "${@:2}" ;;
        logs)        _cron_logs "${@:2}" ;;
        # Dahili — YALNIZ 'OnFailure=' drop-in'i tarafından çağrılır, elle
        # çalıştırılmak İÇİN DEĞİLDİR (bkz. _cron_write_failure_hook).
        # Bilinçli olarak help metninde/completions'ta LİSTELENMEZ.
        _on-failure) _cron_on_failure "${@:2}" ;;
        *)
            _cron_help
            ;;
    esac
}

_cron_help() {
    echo ""
    echo -e "  ${BOLD}srvctl cron${NC} — kullanıcı dostu cron (arka planda systemd timer)"
    echo ""
    echo "  Kullanım:"
    echo "    srvctl cron add <domain>|--system --name=<ad> --schedule=<zaman> \\"
    echo "        --command=<komut> [--description=<açıklama>] [--timeout=<sn>] \\"
    echo "        [--catch-up-on-boot]"
    echo "    srvctl cron list [<domain>|--system]"
    echo "    srvctl cron show <domain>|--system <ad>"
    echo "    srvctl cron run <domain>|--system <ad>          (şimdi bir kez çalıştır — test)"
    echo "    srvctl cron enable|disable <domain>|--system <ad>"
    echo "    srvctl cron remove <domain>|--system <ad>"
    echo "    srvctl cron logs <domain>|--system <ad> [-n N]"
    echo ""
    echo "  --schedule üç biçimi kabul eder:"
    echo "    1) Türkçe kısayol (küçük harf yazılmalı):"
    echo "         'her gün SS:DD'            (ör. 'her gün 03:00')"
    echo "         'her N dakikada'           (ör. 'her 15 dakikada')"
    echo "         'her saat'"
    echo "         'her <gün> SS:DD'          (pazartesi/salı/çarşamba/perşembe/cuma/cumartesi/pazar)"
    echo "         'ayın N'i SS:DD'           (ör. \"ayın 1'i 02:00\")"
    echo "         'hafta içi SS:DD'          (pazartesi-cuma)"
    echo "    2) Standart 5 alanlı cron sözdizimi: 'dakika saat ayın_günü ay haftanın_günü'"
    echo "         (ör. '0 3 * * *') — 'ayın_günü' VE 'haftanın_günü' AYNI ANDA"
    echo "         kısıtlanamaz (birini '*' bırakın)."
    echo "    3) Ham systemd takvim ifadesi (uzman kullanımı, ör. '*-*-01 02:00:00')"
    echo ""
    echo "  Zamanlama UTC'ye göre hesaplanır (1 ve 2. biçimler); ham modda (3) dilim"
    echo "  belirtilmemişse SUNUCUNUN yerel saati kullanılır — 'cron add' bunu uyarır."
    echo ""
    echo "  --catch-up-on-boot: sunucu kapalıyken kaçan bir çalışma AÇILIŞTA telafi"
    echo "  edilsin mi (systemd Persistent=)? Varsayılan HAYIR (crontab-parity, en az"
    echo "  sürpriz). Yedekleme gibi 'mutlaka çalışmalı' işler için bu bayrağı verin."
    echo ""
}

# ═══════════════════════════════════════════════
#  SAF ZAMANLAMA ÇEVİRİCİLERİ (girdi→çıktı, yan etkisiz — kapsamlı test edilir)
# ═══════════════════════════════════════════════

# Türkçe gün adı → systemd haftanın-günü kısaltması. PREDİKAT değil, ÜRETİCİ:
# başarıda stdout'a yazar (0), tanınmayan girdide 1 döner (stdout boş).
_cron_tr_daynum() {
    case "$1" in
        pazartesi)     echo "Mon" ;;
        sali|salı)     echo "Tue" ;;
        carsamba|çarşamba) echo "Wed" ;;
        persembe|perşembe) echo "Thu" ;;
        cuma)          echo "Fri" ;;
        cumartesi)     echo "Sat" ;;
        pazar)         echo "Sun" ;;
        *) return 1 ;;
    esac
}

# Cron alanı 0-7 (0 VE 7 = Pazar) → systemd gün adı.
_cron_dow_name() {
    case "$1" in
        0|7) echo "Sun" ;;
        1)   echo "Mon" ;;
        2)   echo "Tue" ;;
        3)   echo "Wed" ;;
        4)   echo "Thu" ;;
        5)   echo "Fri" ;;
        6)   echo "Sat" ;;
        *) return 1 ;;
    esac
}

# "SS:DD" → doğrulanmış, 2 haneye tamamlanmış "SS DD" (read ile parse edilir).
# 10# öneki: '08'/'09' gibi girdilerin sekizlik sanılmasını ÖNLER (core.sh:
# validate_http_code İLE AYNI gerekçe).
_cron_hhmm_parts() {
    local t="$1"
    [[ "$t" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]] || return 1
    local hh="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}"
    (( 10#$hh <= 23 )) || return 1
    (( 10#$mm <= 59 )) || return 1
    printf '%02d %02d' "$((10#$hh))" "$((10#$mm))"
}

# Türkçe kısayolu systemd takvim GÖVDESİNE (henüz 'UTC' EKLENMEMİŞ) çevirir.
# Girdi kelimelere bölünerek (bash IFS word-splitting) işlenir — Türkçe'ye
# özgü harfleri (ç/ğ/ı/ö/ş/ü) İÇEREN sabit anahtar kelimeler ('ayın', 'içi')
# yalnız '==' İLE (glob/regex DEĞİL) karşılaştırılır: bash '[[ == ]]' salt
# BAYT-düzeyinde literal karşılaştırma yapar, UTF-8 karakter sınıfı/locale
# belirsizliğine BAĞIMLI DEĞİLDİR (bir regex karakter sınıfının aksine).
# Başarıda stdout'a gövdeyi yazar (0), tanınmayan/geçersiz girdide 1 döner
# (stdout boş).
_cron_translate_turkish() {
    local input="$1"
    local -a w
    read -ra w <<< "$input"
    local n="${#w[@]}"
    local hhmm hh mm

    # (1) "her gün SS:DD"
    if (( n == 3 )) && [[ "${w[0]}" == "her" && "${w[1]}" == "gün" ]]; then
        hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
        read -r hh mm <<< "$hhmm"
        printf '*-*-* %s:%s:00' "$hh" "$mm"
        return 0
    fi

    # (2) "her N dakikada"
    if (( n == 3 )) && [[ "${w[0]}" == "her" && "${w[2]}" == "dakikada" && "${w[1]}" =~ ^[0-9]+$ ]]; then
        local step="$((10#${w[1]}))"
        (( step >= 1 && step <= 59 )) || return 1
        printf '*-*-* *:0/%d:00' "$step"
        return 0
    fi

    # (3) "her saat"
    if (( n == 2 )) && [[ "${w[0]}" == "her" && "${w[1]}" == "saat" ]]; then
        printf '*-*-* *:00:00'
        return 0
    fi

    # (4) "her <gün> SS:DD"
    if (( n == 3 )) && [[ "${w[0]}" == "her" ]]; then
        local dname
        if dname=$(_cron_tr_daynum "${w[1]}"); then
            hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
            read -r hh mm <<< "$hhmm"
            printf '%s *-*-* %s:%s:00' "$dname" "$hh" "$mm"
            return 0
        fi
    fi

    # (5) "ayın N'i SS:DD" (Türkçe iyelik eki serbest — yalnız baştaki
    # rakamlar okunur: '1'i'/'2'si'/'3'ü'/düz '1' hepsi kabul edilir).
    if (( n == 3 )) && [[ "${w[0]}" == "ayın" || "${w[0]}" == "ayin" ]]; then
        [[ "${w[1]}" =~ ^([0-9]{1,2}) ]] || return 1
        local daynum="$((10#${BASH_REMATCH[1]}))"
        (( daynum >= 1 && daynum <= 31 )) || return 1
        hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
        read -r hh mm <<< "$hhmm"
        printf '*-*-%02d %s:%s:00' "$daynum" "$hh" "$mm"
        return 0
    fi

    # (6) "hafta içi SS:DD" (Pazartesi-Cuma)
    if (( n == 3 )) && [[ "${w[0]}" == "hafta" ]] && [[ "${w[1]}" == "içi" || "${w[1]}" == "ici" ]]; then
        hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
        read -r hh mm <<< "$hhmm"
        printf 'Mon..Fri *-*-* %s:%s:00' "$hh" "$mm"
        return 0
    fi

    return 1
}

# Girdi tam olarak 5 boşlukla ayrılmış alan mı? (PREDİKAT — cron sözdizimine
# 'BENZİYOR mu' sorusuna cevap verir; alanların İÇERİĞİNİ doğrulamaz).
_cron_looks_like_cron5() {
    local -a f
    read -ra f <<< "$1"
    (( ${#f[@]} == 5 ))
}

# Tek bir cron alanını systemd takvim söz dizimine çevirir.
# kind: 'num' (düz sayı — dakika/saat/ayın_günü/ay) | 'dow' (haftanın günü,
# 0-7 → Mon..Sun). Desteklenen alt küme (BİLİNÇLİ SINIRLAMA — bkz. dosya
# başı yorumu, 'a-b/N' birleşik biçimi desteklenmez, reddedilir):
#   '*' | 'N' | 'N,M,...' | 'a-b' | '*/N' (yalnız kind=num).
_cron_field_translate() {
    local field="$1" min="$2" max="$3" kind="$4"
    [[ -n "$field" ]] || return 1

    if [[ "$field" == "*" ]]; then
        printf '*'
        return 0
    fi

    if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
        [[ "$kind" == "dow" ]] && return 1
        local step="$((10#${BASH_REMATCH[1]}))"
        (( step >= 1 && step <= max )) || return 1
        printf '*/%d' "$step"
        return 0
    fi

    if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="$((10#${BASH_REMATCH[1]}))" b="$((10#${BASH_REMATCH[2]}))"
        (( a >= min && a <= max )) || return 1
        (( b >= min && b <= max )) || return 1
        (( a <= b )) || return 1
        if [[ "$kind" == "dow" ]]; then
            local an bn
            an=$(_cron_dow_name "$a") || return 1
            bn=$(_cron_dow_name "$b") || return 1
            printf '%s..%s' "$an" "$bn"
        else
            printf '%02d..%02d' "$a" "$b"
        fi
        return 0
    fi

    # Tek sayı da bu dalın özel bir hâlidir (sıfır virgüllü liste).
    if [[ "$field" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        local -a items
        IFS=',' read -ra items <<< "$field"
        local out="" it v dn
        for it in "${items[@]}"; do
            [[ "$it" =~ ^[0-9]+$ ]] || return 1
            v="$((10#$it))"
            (( v >= min && v <= max )) || return 1
            if [[ "$kind" == "dow" ]]; then
                dn=$(_cron_dow_name "$v") || return 1
                out="${out:+${out},}${dn}"
            else
                out="${out:+${out},}$(printf '%02d' "$v")"
            fi
        done
        printf '%s' "$out"
        return 0
    fi

    return 1
}

# Standart 5 alanlı cron ifadesini systemd takvim GÖVDESİNE çevirir (henüz
# 'UTC' EKLENMEMİŞ). BİLİNÇLİ SINIRLAMA: POSIX cron'da 'ayın_günü' VE
# 'haftanın_günü' AYNI ANDA kısıtlanırsa anlam "YA DA" (OR) olur — systemd
# OnCalendar bunu TEK SATIRDA ifade EDEMEZ (her zaman AND) ve render_template
# newline/CR'yi reddettiğinden (ON_CALENDAR TEK bir token) birden fazla
# 'OnCalendar=' satırı da bu sözleşmede MÜMKÜN DEĞİL. Bu kombinasyon
# YANLIŞ yorumlamaktansa NET biçimde REDDEDİLİR.
_cron_translate_cron5() {
    local input="$1"
    _cron_looks_like_cron5 "$input" || return 1
    local -a f
    read -ra f <<< "$input"

    if [[ "${f[2]}" != "*" && "${f[4]}" != "*" ]]; then
        return 1
    fi

    local min_t hour_t dom_t month_t dow_t
    min_t=$(_cron_field_translate "${f[0]}" 0 59 num)   || return 1
    hour_t=$(_cron_field_translate "${f[1]}" 0 23 num)  || return 1
    dom_t=$(_cron_field_translate "${f[2]}" 1 31 num)   || return 1
    month_t=$(_cron_field_translate "${f[3]}" 1 12 num) || return 1
    dow_t=$(_cron_field_translate "${f[4]}" 0 7 dow)    || return 1

    local prefix=""
    [[ "${f[4]}" != "*" ]] && prefix="${dow_t} "
    printf '%s*-%s-%s %s:%s:00' "$prefix" "$month_t" "$dom_t" "$hour_t" "$min_t"
}

# Ham systemd takvim ifadesi için İZİN VERİLEN karakter kümesi (PREDİKAT).
# Amaç sözdizimini DOĞRULAMAK DEĞİL (bu iş 'systemd-analyze calendar'a
# bırakılır, bkz. _cron_add) — unit dosyası satırını KIRABİLECEK/render_
# template'in newline/CR reddiyle BİRLİKTE tek-satır bütünlüğünü tehlikeye
# atabilecek karakterleri (= { } [ ] ; tırnak ters-eğik-çizgi $ vb.) baştan
# elemektir. IANA dilim adları ('Europe/Istanbul') ve systemd'nin '~' (ayın
# son günü) sözdizimi İÇİN gerekli karakterler BİLİNÇLİ OLARAK dahildir.
_cron_calendar_charset_ok() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    # Regex bir DEĞİŞKENDE tutulur (core.sh:assert_regex_safe İLE AYNI
    # desen) — '[[ =~ ]]' RHS'i tırnaksız yazılırsa bazı karakter sınıfı
    # bileşimlerinde ('~ -' gibi) bash'in KENDİ ayrıştırıcısı "syntax error
    # in conditional expression" verebiliyor; değişken dolaylılığı bunu
    # tamamen ortadan kaldırır.
    local re='^[A-Za-z0-9*:,./_+~ -]+$'
    [[ "$v" =~ $re ]]
}

# ─── Üç biçimi sırayla dener; başarıda "MOD GÖVDE..." (tek satır, 'read'
# ile ayrıştırılır — GÖVDE boşluk içerebileceğinden 'read'in SON değişkeni
# TÜM kalanı yutar, bkz. lib/domain.sh:_domain_unit_common_ctx İLE AYNI
# desen) yazar. MOD ∈ {turkish, cron5, raw}. ÖNCELİK SIRASI ÖNEMLİ DEĞİL
# (biçimler yapısal olarak ÇAKIŞMAZ — bkz. her çeviricinin kendi yorumu)
# ama cron5 'BENZİYORSA' (tam 5 alan) VE çeviri BAŞARISIZSA ham moda ASLA
# DÜŞÜLMEZ: yanlış yorumlamaktansa net bir hata tercih edilir.
# ═══════════════════════════════════════════════
_cron_resolve_schedule() {
    local input="$1"
    local body

    if body=$(_cron_translate_turkish "$input"); then
        printf 'turkish %s UTC' "$body"
        return 0
    fi

    if _cron_looks_like_cron5 "$input"; then
        if body=$(_cron_translate_cron5 "$input"); then
            printf 'cron5 %s UTC' "$body"
            return 0
        fi
        return 1
    fi

    if _cron_calendar_charset_ok "$input"; then
        printf 'raw %s' "$input"
        return 0
    fi

    return 1
}

# ═══════════════════════════════════════════════
#  KİMLİK / UNIT ADI YARDIMCILARI
# ═══════════════════════════════════════════════

# Cron adı doğrulaması — YENİ bir regex YAZILMADI, mevcut assert_safe_ident
# (core.sh) KULLANILIYOR (görev talebi). Ek olarak makul bir uzunluk sınırı
# (unit dosya adı hijyeni — diğer kimliklerle AYNI konvansiyon).
_cron_ident_ok() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    (( ${#name} <= 50 )) || return 1
    assert_safe_ident "$name"
}

# sname="" → sistem kapsamı; sname="<safe_name>" → domain kapsamı.
_cron_svc_name() {
    if [[ -z "$1" ]]; then
        printf 'srvctl-syscron-%s.service' "$2"
    else
        printf 'srvctl-cron-%s-%s.service' "$1" "$2"
    fi
}
_cron_timer_name() {
    if [[ -z "$1" ]]; then
        printf 'srvctl-syscron-%s.timer' "$2"
    else
        printf 'srvctl-cron-%s-%s.timer' "$1" "$2"
    fi
}
_cron_fail_svc_name() {
    if [[ -z "$1" ]]; then
        printf 'srvctl-syscronfail-%s.service' "$2"
    else
        printf 'srvctl-cronfail-%s-%s.service' "$1" "$2"
    fi
}

# ═══════════════════════════════════════════════
#  KAÇIŞ YARDIMCILARI (bkz. dosya başındaki UZUN sözleşme yorumu)
# ═══════════════════════════════════════════════

# POSIX tek-tırnak kaçışı: her ' → '\'' (4 karakter). Değişkenler tek
# başlarına birer karakter TUTAR — nested tırnak/backslash karmaşasından
# kaçınmak için (bu dosyada bu tuzağa birden fazla kez düşüldü) doğrudan
# harf harf birleştirilir, hiçbir yerde iç içe tırnak AÇILMAZ.
_cron_escape_singlequote() {
    local s="$1" q="'" bs='\'
    local repl="${q}${bs}${q}${q}"
    printf '%s' "${s//$q/$repl}"
}

# systemd '%' specifier ikilemesi (ExecStart= VE Description= için).
_cron_escape_percent() {
    printf '%s' "${1//%/%%}"
}

# ═══════════════════════════════════════════════
#  RENDER SONRASI GÜVENLİK AĞI (domain.sh:_domain_assert_no_leftover_tokens
#  İLE AYNI mantığın KENDİ İÇİNDE tutulan kopyası — çapraz modül bağımlılığı
#  KURULMAMASI için, CLAUDE.md deseni: cross-module çağrı yalnızca GEREKTİĞİNDE)
# ═══════════════════════════════════════════════
_cron_assert_no_leftover_tokens() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if grep -q '{{' "$file" 2>/dev/null; then
        local leftover
        leftover=$(grep -oE '\{\{[A-Z_]+\}\}' "$file" 2>/dev/null | sort -u | tr '\n' ' ')
        rm -f -- "$file"
        error "Şablon render hatası: ${file} içinde beslenmeyen token kaldı (${leftover:-'{{...}}'}) — dosya silindi, işlem durduruldu."
    fi
}

# ═══════════════════════════════════════════════
#  systemctl SORGU YARDIMCILARI (macOS/test-seam: systemctl yoksa 'bilinmiyor')
# ═══════════════════════════════════════════════
_cron_unit_prop() {
    command -v systemctl >/dev/null 2>&1 || { printf ''; return 0; }
    systemctl show "$1" -p "$2" --value 2>/dev/null || true
}
_cron_is_enabled() {
    command -v systemctl >/dev/null 2>&1 || { printf 'bilinmiyor'; return 0; }
    local st
    st=$(systemctl is-enabled "$1" 2>/dev/null) || true
    printf '%s' "${st:-bilinmiyor}"
}
_cron_active_state() {
    command -v systemctl >/dev/null 2>&1 || { printf 'bilinmiyor'; return 0; }
    local st
    st=$(systemctl is-active "$1" 2>/dev/null) || true
    printf '%s' "${st:-bilinmiyor}"
}
_cron_last_run() {
    local v
    v=$(_cron_unit_prop "$1" ExecMainStartTimestamp)
    if [[ -n "$v" ]]; then printf '%s' "$v"; else printf 'hiç çalışmadı / bilinmiyor'; fi
}
_cron_next_run() {
    local v
    v=$(_cron_unit_prop "$1" NextElapseUSecRealtime)
    if [[ -n "$v" && "$v" != "0" ]]; then printf '%s' "$v"; else printf 'bilinmiyor'; fi
}
_cron_last_exit() {
    local v r
    v=$(_cron_unit_prop "$1" ExecMainStatus)
    r=$(_cron_unit_prop "$1" Result)
    if [[ -n "$v" ]]; then printf '%s (%s)' "$v" "${r:-bilinmiyor}"; else printf 'bilinmiyor'; fi
}

# safe_name → gerçek domain adı (yalnız GÖRÜNTÜLEME amaçlı, 'cron list'
# TÜM domain'leri tararken). Bulunamazsa 1 döner — çağıran taraf safe_name'i
# parantez içinde göstermeye düşer (UYDURMA YOK).
_cron_domain_from_sname() {
    local target="$1" d s
    while IFS= read -r d; do
        s=$(safe_name "$d")
        if [[ "$s" == "$target" ]]; then
            printf '%s' "$d"
            return 0
        fi
    done < <(list_all_domains)
    return 1
}

# ═══════════════════════════════════════════════
#  SIDECAR (yalnız kullanıcının GİRDİĞİ ham metni saklar — tek doğruluk
#  kaynağı UNIT DOSYALARIdır; burası yalnız systemd'den GERİ ÇEVRİLEMEYEN
#  TEK bilgiyi — operatörün orijinal ifadesini — tutar, 'bilinmeyeni
#  uydurma' ilkesiyle uyumlu).
# ═══════════════════════════════════════════════
_cron_sidecar_dir() {
    printf '%s/_cron/%s' "${SRVCTL_STATE_DIR}" "${1:-_system}"
}
_cron_write_sidecar() {
    local sname="$1" name="$2" raw="$3" mode="$4"
    local dir
    dir=$(_cron_sidecar_dir "$sname")
    secure_dir "$dir" 700
    local sidecar_file="${dir}/${name}.conf"
    {
        printf 'SCHEDULE_RAW=%s\n' "$raw"
        printf 'SCHEDULE_MODE=%s\n' "$mode"
        printf 'CREATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$sidecar_file"
    chmod 644 "$sidecar_file" 2>/dev/null || true
    chown root:root "$sidecar_file" 2>/dev/null || true
}

# ═══════════════════════════════════════════════
#  OnFailure DROP-IN + BİLDİRİM UNIT'İ (bkz. dosya başı sözleşme yorumu)
# ═══════════════════════════════════════════════
_cron_write_failure_hook() {
    local sysd_dir="$1" svc_name="$2" fail_name="$3" domain="$4" name="$5" is_system="$6"

    local dropin_dir="${sysd_dir}/${svc_name}.d"
    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/override.conf" <<EOF
# srvctl tarafından otomatik üretildi (srvctl cron add) — elle düzenlemeyin.
# Bu drop-in ana şablona (TOKENS kontratı SABİT) DOKUNMADAN "bildir + kaydet,
# otomatik tekrar YOK" davranışını ekler (bkz. lib/cron.sh dosya başı yorumu).
[Unit]
OnFailure=${fail_name}
EOF
    chmod 644 "${dropin_dir}/override.conf" 2>/dev/null || true

    local target_arg
    if [[ "$is_system" == "true" ]]; then
        target_arg="--system"
    else
        target_arg="$domain"
    fi
    # target_arg/name burada TIRNAKSIZ gömülür: domain (validate_domain) ve
    # name (assert_safe_ident) ZATEN boşluk/özel-karakter İÇEREMEZ — tek
    # argv kelimesi olarak güvenle gömülebilirler (ek tırnaklama gerekmez).
    cat > "${sysd_dir}/${fail_name}" <<EOF
# srvctl tarafından otomatik üretildi (srvctl cron add) — elle düzenlemeyin.
[Unit]
Description=srvctl cron basarisizlik bildirimi (${name})

[Service]
Type=oneshot
ExecStart=${SRVCTL_ROOT}/bin/srvctl cron _on-failure ${target_arg} ${name}
EOF
    chmod 644 "${sysd_dir}/${fail_name}" 2>/dev/null || true
}

# 'OnFailure=' tarafından tetiklenir — YALNIZ INTERNAL kullanım. Exit kodu
# 75 (flock -E 75 sentinel'i — bkz. dosya başı DEPLOY KİLİDİ yorumu) ÖZEL
# olarak "atlandı" sayılır: kaydedilir ama bildirim GÖNDERİLMEZ.
_cron_on_failure() {
    local scope_arg="${1:-}" name="${2:-}"
    if [[ -z "$scope_arg" || -z "$name" ]]; then
        log_action "CRON _on-failure: eksik argüman (bu bir dahili çağrıdır, elle çalıştırılmamalıdır)"
        return 0
    fi

    local sname="" scope_label unit
    if [[ "$scope_arg" == "--system" ]]; then
        scope_label="sistem geneli"
        unit=$(_cron_svc_name "" "$name")
    else
        sname=$(safe_name "$scope_arg")
        scope_label="domain: ${scope_arg}"
        unit=$(_cron_svc_name "$sname" "$name")
    fi

    local exit_code result
    exit_code=$(_cron_unit_prop "$unit" ExecMainStatus); exit_code="${exit_code:-bilinmiyor}"
    result=$(_cron_unit_prop "$unit" Result); result="${result:-bilinmiyor}"

    if [[ "$exit_code" == "75" ]]; then
        log_action "CRON ATLANDI (deploy kilidi aktifti, GERÇEK başarısızlık DEĞİL): ${scope_label} / ${name} — unit=${unit}"
        return 0
    fi

    log_action "CRON BAŞARISIZ: ${scope_label} / ${name} — unit=${unit} exit=${exit_code} result=${result}"

    # Çapraz modül bildirim (CLAUDE.md deseni) — notify.sh yoksa sessizce atlanır.
    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
    if declare -f send_notification &>/dev/null; then
        send_notification "Cron Görevi Başarısız" \
"Görev: ${name}
Kapsam: ${scope_label}
Unit: ${unit}
Çıkış kodu: ${exit_code}
Sonuç: ${result}

Otomatik tekrar YOK — bir sonraki planlı zamanda yeniden denenecek.
Loglar: journalctl -u ${unit}" \
            "critical" || true
    fi
    return 0
}

# ═══════════════════════════════════════════════
#  cron add <domain>|--system --name= --schedule= --command= [--description=] [--timeout=]
# ═══════════════════════════════════════════════
_cron_add() {
    local scope_arg="${1:-}"
    if [[ -z "$scope_arg" ]]; then
        error "Kullanım: srvctl cron add <domain>|--system --name=<ad> --schedule=<zaman> --command=<komut> [--description=...] [--timeout=<sn>] [--catch-up-on-boot]"
    fi
    shift

    local is_system=false domain="" sname=""
    if [[ "$scope_arg" == "--system" ]]; then
        is_system=true
    else
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
    fi

    local name="" schedule="" command="" description="" timeout="$CRON_DEFAULT_TIMEOUT"
    local catchup="false"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --name=*)        name="${arg#--name=}" ;;
            --schedule=*)    schedule="${arg#--schedule=}" ;;
            --command=*)     command="${arg#--command=}" ;;
            --description=*) description="${arg#--description=}" ;;
            --timeout=*)     timeout="${arg#--timeout=}" ;;
            --catch-up-on-boot) catchup="true" ;;
            *) error "Bilinmeyen seçenek: ${arg}" ;;
        esac
    done
    # CRON_PERSISTENT (Persistent=) — PER-JOB, sabit DEĞİL (koordinatör
    # geri bildirimi — bkz. srvctl-cron.timer.tpl başlık yorumu): "cache
    # temizliği" (kaçırılırsa ZARARSIZ) ile "gecelik yedekleme" (kaçırılırsa
    # VERİ KAYBI riski) TAM TERS varsayılan ister, tek sabit değer ikisini
    # AYNI ANDA doğru karşılayamaz. Varsayılan 'false' (crontab-parity, EN AZ
    # SÜRPRİZ — şablonun kendi önerisi); operatör AÇIKÇA '--catch-up-on-boot'
    # vermeden 'true' OLMAZ. Değer burada literal "true"/"false" olarak
    # ÜRETİLDİĞİNDEN (kullanıcı serbest metni DEĞİL) doğal olarak güvenlidir;
    # yine de şablonun istediği "kaynak taraf validasyonu" için savunma
    # amaçlı normalize edilir.
    validate_bool "$catchup" || catchup="false"

    _cron_ident_ok "$name" || error "Geçersiz cron adı: '${name}' (yalnız harf/rakam/alt çizgi, azami 50 karakter)"
    [[ -n "$schedule" ]] || error "--schedule zorunlu"
    [[ "$schedule" != *$'\n'* && "$schedule" != *$'\r'* ]] || error "--schedule satırsonu/CR içeremez"
    [[ -n "$command" ]] || error "--command zorunlu"
    [[ "$command" != *$'\n'* && "$command" != *$'\r'* ]] || error "--command satırsonu/CR içeremez"
    validate_uint "$timeout" 86400 || error "Geçersiz --timeout: ${timeout} (1-86400 saniye)"
    (( timeout >= 1 )) || error "--timeout en az 1 saniye olmalı"
    [[ -n "$description" ]] || description="$name"

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc_name timer_name fail_name
    svc_name=$(_cron_svc_name "$sname" "$name")
    timer_name=$(_cron_timer_name "$sname" "$name")
    fail_name=$(_cron_fail_svc_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc_name}" ]] && error "Bu isimde bir cron zaten var: ${svc_name} (önce 'srvctl cron remove' ile silin ya da farklı bir --name seçin)"

    if [[ "$is_system" != "true" ]]; then
        local first="${command%% *}"
        if [[ "$first" == "php" ]]; then
            warn "Komut 'php' ile başlıyor — bu, \$PATH üzerindeki VARSAYILAN php ikili dosyasını kullanır ve domain'in yapılandırılmış PHP sürümüyle AYNI OLMAYABİLİR. Domain'in PHP'sini garanti etmek için 'php<sürüm>' (ör. php8.3) ya da mutlak yol (/usr/bin/php8.3) kullanmanız önerilir."
        fi
    fi

    local resolved
    if ! resolved=$(_cron_resolve_schedule "$schedule"); then
        error "Zamanlama ifadesi anlaşılamadı: '${schedule}'
  Desteklenen biçimler ('srvctl cron' yardımına bkz: srvctl cron):
    1) Türkçe kısayol (küçük harf): 'her gün SS:DD', 'her N dakikada', 'her saat',
       'her <gün> SS:DD', \"ayın N'i SS:DD\", 'hafta içi SS:DD'
    2) Standart 5 alanlı cron sözdizimi (ör. '0 3 * * *') — ayın_günü VE
       haftanın_günü AYNI ANDA kısıtlanamaz.
    3) Ham systemd takvim ifadesi (ör. '*-*-01 02:00:00')"
    fi

    local mode calendar
    read -r mode calendar <<< "$resolved"

    if [[ "$mode" == "raw" ]]; then
        warn "Ham mod: zaman dilimi ifadenin İÇİNDE belirtilmemişse SUNUCUNUN yerel saatine göre yorumlanır (systemd varsayılanı). Belirli bir dilim istiyorsanız ifadenin sonuna 'UTC' ya da 'Europe/Istanbul' gibi bir IANA adı ekleyin."
    else
        info "Zamanlama UTC saatine göre hesaplandı (sunucunun yerel saat dilimi ayarından BAĞIMSIZ): ${calendar}"
    fi

    # Persistent= — PER-JOB (CRON_PERSISTENT), sabit DEĞİL (bkz. yukarıdaki
    # 'catchup' değişkeninin yorumu). Operatöre AÇIKÇA hangi davranışın
    # seçildiği söylenir — sessizce varsayılana güvenilmez.
    if [[ "$catchup" == "true" ]]; then
        info "Not: '--catch-up-on-boot' verildi — sunucu kapalıyken kaçan bir çalışma AÇILIŞTA telafi edilecek (Persistent=true)."
    else
        info "Not: sunucu kapalıyken kaçan bir çalışma OTOMATİK TELAFİ EDİLMEZ (Persistent=false — crontab davranışıyla uyumlu varsayılan). Yedekleme gibi 'mutlaka çalışmalı' işler için '--catch-up-on-boot' kullanın."
    fi

    echo ""
    info "Hesaplanan OnCalendar ifadesi: ${calendar}"
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze calendar "$calendar" --iterations=3; then
            error "systemd-analyze bu ifadeyi GEÇERSİZ buldu — cron eklenmedi: ${calendar}"
        fi
    else
        warn "systemd-analyze bulunamadı — zamanlama sözdizimi DOĞRULANAMADI (fail-safe: yukarıdaki ifadeyi GÖZLE kontrol edin)"
    fi
    echo ""

    if ! confirm "Bu zamanlamayla '${name}' cron'u eklensin mi?"; then
        info "İptal edildi."
        return 0
    fi

    # ── Kabuk sarmalama + kaçış (bkz. dosya başındaki UZUN sözleşme yorumu) ──
    local shell_body
    if [[ "$is_system" != "true" ]]; then
        local lock_dir="${SRVCTL_LOCK_DIR:-/run/srvctl}"
        if command -v flock >/dev/null 2>&1; then
            secure_dir "$lock_dir" 700
            local inner lockfile_q
            inner=$(_cron_escape_singlequote "$command")
            lockfile_q=$(_cron_escape_singlequote "${lock_dir}/deploy-${sname}.lock")
            shell_body="flock -n -E 75 '${lockfile_q}' -c '${inner}'"
            info "Deploy kilidi entegrasyonu aktif: 'srvctl deploy ${domain}' sürerken bu cron ÇALIŞMAZ (çıkış kodu 75 ile sessizce atlanır, bildirim GÖNDERİLMEZ)."
        else
            shell_body="$command"
            warn "flock bulunamadı — bu cron deploy ile ÇAKIŞMAYA KARŞI KORUNMUYOR (lib/deploy.sh:_deploy_lock ile AYNI sınırlama)"
        fi
    else
        shell_body="$command"
    fi

    local cron_command_final description_final
    cron_command_final=$(_cron_escape_percent "$(_cron_escape_singlequote "$shell_body")")
    description_final=$(_cron_escape_percent "$description")

    mkdir -p "$sysd_dir"
    local svc_file="${sysd_dir}/${svc_name}" timer_file="${sysd_dir}/${timer_name}"

    if [[ "$is_system" == "true" ]]; then
        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-syscron.service.tpl" \
            "CRON_NAME=${name}" "CRON_DESCRIPTION=${description_final}" \
            "CRON_COMMAND=${cron_command_final}" "RUNTIME_MAX=${timeout}" \
            > "$svc_file"
        _cron_assert_no_leftover_tokens "$svc_file"

        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-syscron.timer.tpl" \
            "CRON_NAME=${name}" "CRON_DESCRIPTION=${description_final}" \
            "ON_CALENDAR=${calendar}" "RANDOMIZED_DELAY=${CRON_DEFAULT_RANDOMIZED_DELAY}" \
            "CRON_PERSISTENT=${catchup}" \
            > "$timer_file"
        _cron_assert_no_leftover_tokens "$timer_file"
    else
        local web_user="web_${sname}"
        # WEB_ROOT/<domain>/current — _domain_working_dir (lib/domain.sh) İLE
        # BİREBİR AYNI sözleşme; çapraz modül bağımlılığı KURULMADAN (tek
        # satırlık formül) burada yeniden üretilir.
        local working_dir="${WEB_ROOT}/${domain}/current"
        # DOMAIN_ROOT: ReadWritePaths= için domain'in TÜM ağacı gerekir
        # (yalnız WORKING_DIR/'current' DEĞİL — worker/scheduler İLE AYNI
        # gerekçe, bkz. srvctl-cron.service.tpl başlık yorumu: 'writable/',
        # 'storage/', üst düzey 'logs/' gibi KARDEŞ dizinler de dahil).
        local domain_root="${WEB_ROOT}/${domain}"

        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.service.tpl" \
            "SAFE_NAME=${sname}" "DOMAIN=${domain}" "WEB_USER=${web_user}" \
            "WORKING_DIR=${working_dir}" "CRON_NAME=${name}" \
            "CRON_DESCRIPTION=${description_final}" "CRON_COMMAND=${cron_command_final}" \
            "RUNTIME_MAX=${timeout}" "DOMAIN_ROOT=${domain_root}" \
            > "$svc_file"
        _cron_assert_no_leftover_tokens "$svc_file"

        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.timer.tpl" \
            "SAFE_NAME=${sname}" "DOMAIN=${domain}" "CRON_NAME=${name}" \
            "CRON_DESCRIPTION=${description_final}" "ON_CALENDAR=${calendar}" \
            "RANDOMIZED_DELAY=${CRON_DEFAULT_RANDOMIZED_DELAY}" \
            "CRON_PERSISTENT=${catchup}" \
            > "$timer_file"
        _cron_assert_no_leftover_tokens "$timer_file"

        [[ -d "$working_dir" ]] || warn "WorkingDirectory henüz yok: ${working_dir} (ilk 'srvctl deploy ${domain}' bekleniyor — timer tetiklendiğinde çalışmayabilir)"
    fi

    _cron_write_failure_hook "$sysd_dir" "$svc_name" "$fail_name" "$domain" "$name" "$is_system"
    _cron_write_sidecar "$sname" "$name" "$schedule" "$mode"

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$timer_name" >/dev/null 2>&1 || true

    success "Cron eklendi ve etkinleştirildi: ${name} (${timer_name})"
    log_action "CRON ADD: isim=${name} kapsam=${domain:---system} zamanlama='${schedule}' -> ${calendar}"
}

# ═══════════════════════════════════════════════
#  cron list [<domain>|--system]
# ═══════════════════════════════════════════════
# Görev sözleşmesi ("cron list çıktısı: ad, açıklama, zaman, son çalışma,
# sonraki çalışma, son çıkış kodu, etkin/devre dışı") YEDİ alanı gerektirir —
# bu, tek satırlık bir tabloya SIĞDIRILAMAYACAK kadar geniştir (okunaklılık
# kaybı). Bunun yerine cron başına ÇOK SATIRLI, kompakt bir blok basılır
# (domain_list'in tek-satır tablo desenine göre bu veri hacmi için daha
# uygun — 'git log' ile 'git log --oneline' farkına benzer bir karar).
# Bilinmeyen alan HER ZAMAN 'bilinmiyor' basar, ASLA UYDURULMAZ.
_cron_print_row() {
    local sname="$1" name="$2" domain_display="$3"
    local svc timer scope_col
    svc=$(_cron_svc_name "$sname" "$name")
    timer=$(_cron_timer_name "$sname" "$name")
    if [[ -z "$sname" ]]; then scope_col="sistem"; else scope_col="$domain_display"; fi

    local description
    description=$(grep -m1 '^Description=' "${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}/${svc}" 2>/dev/null | cut -d= -f2-)

    local raw=""
    local sidecar_dir
    sidecar_dir=$(_cron_sidecar_dir "$sname")
    if [[ -f "${sidecar_dir}/${name}.conf" ]]; then
        local SCHEDULE_RAW=""
        read_kv_file "${sidecar_dir}/${name}.conf" SCHEDULE_RAW
        raw="$SCHEDULE_RAW"
    fi

    local enabled exitc last_run next_run
    enabled=$(_cron_is_enabled "$timer")
    exitc=$(_cron_unit_prop "$svc" ExecMainStatus); exitc="${exitc:-bilinmiyor}"
    last_run=$(_cron_last_run "$svc")
    next_run=$(_cron_next_run "$timer")

    echo -e "  ${BOLD}${name}${NC}  ${DIM}[${scope_col}]${NC}  (${enabled})"
    echo "    Açıklama       : ${description:-bilinmiyor}"
    echo "    Zaman          : ${raw:-bilinmiyor}"
    echo "    Son çalışma    : ${last_run}"
    echo "    Sonraki çalışma: ${next_run}"
    echo "    Son çıkış kodu : ${exitc}"
}

_cron_list() {
    local filter="${1:-}"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"

    echo ""
    echo -e "  ${BOLD}Cron Görevleri${NC}  ${DIM}(zamanlama UTC'ye göre — ham modda sunucu yerel saati)${NC}"
    divider

    local count=0
    local f base rest sname name domain_display

    if [[ -z "$filter" || "$filter" == "--system" ]]; then
        for f in "${sysd_dir}"/srvctl-syscron-*.service; do
            [[ -e "$f" ]] || continue
            base=$(basename "$f" .service)
            name="${base#srvctl-syscron-}"
            _cron_print_row "" "$name" "--system"
            divider
            count=$((count + 1))
        done
    fi

    if [[ "$filter" != "--system" ]]; then
        if [[ -n "$filter" ]]; then
            domain_exists "$filter" || error "Domain bulunamadı: ${filter}"
            sname=$(safe_name "$filter")
            for f in "${sysd_dir}/srvctl-cron-${sname}-"*.service; do
                [[ -e "$f" ]] || continue
                base=$(basename "$f" .service)
                name="${base#srvctl-cron-"${sname}"-}"
                _cron_print_row "$sname" "$name" "$filter"
                divider
                count=$((count + 1))
            done
        else
            for f in "${sysd_dir}"/srvctl-cron-*.service; do
                [[ -e "$f" ]] || continue
                base=$(basename "$f" .service)
                rest="${base#srvctl-cron-}"
                sname="${rest%%-*}"
                name="${rest#*-}"
                if ! domain_display=$(_cron_domain_from_sname "$sname"); then
                    domain_display="(${sname})"
                fi
                _cron_print_row "$sname" "$name" "$domain_display"
                divider
                count=$((count + 1))
            done
        fi
    fi

    echo "  Toplam: ${count} cron"
    echo ""
}

# ═══════════════════════════════════════════════
#  cron show <domain>|--system <ad>
# ═══════════════════════════════════════════════
_cron_show() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron show <domain>|--system <ad>"

    local sname="" scope_label domain=""
    if [[ "$scope_arg" == "--system" ]]; then
        scope_label="sistem geneli"
    else
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
        scope_label="domain: ${domain}"
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc timer
    svc=$(_cron_svc_name "$sname" "$name")
    timer=$(_cron_timer_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc}" ]] || error "Cron bulunamadı: ${name} (${scope_label})"

    local description on_calendar persistent
    description=$(grep -m1 '^Description=' "${sysd_dir}/${svc}" 2>/dev/null | cut -d= -f2-)
    on_calendar=$(grep -m1 '^OnCalendar=' "${sysd_dir}/${timer}" 2>/dev/null | cut -d= -f2-)
    # CRON_PERSISTENT (koordinatör talebi): operatörün bilmesi gereken bir
    # DAVRANIŞ ("kaçan çalışma açılışta telafi edilir mi?") — .timer
    # dosyasının KENDİSİNDEN okunur (tek doğruluk kaynağı, sidecar'da AYRICA
    # tutulmaz).
    persistent=$(grep -m1 '^Persistent=' "${sysd_dir}/${timer}" 2>/dev/null | cut -d= -f2-)

    local raw="" created=""
    local sidecar_dir
    sidecar_dir=$(_cron_sidecar_dir "$sname")
    if [[ -f "${sidecar_dir}/${name}.conf" ]]; then
        local SCHEDULE_RAW="" CREATED_AT=""
        read_kv_file "${sidecar_dir}/${name}.conf" SCHEDULE_RAW CREATED_AT
        raw="$SCHEDULE_RAW"; created="$CREATED_AT"
    fi

    header "Cron: ${name}"
    echo "  Kapsam           : ${scope_label}"
    echo "  Açıklama         : ${description:-bilinmiyor}"
    echo "  Girilen zamanlama: ${raw:-bilinmiyor}"
    echo "  OnCalendar       : ${on_calendar:-bilinmiyor}"
    echo "  Kaçan çalışma    : $([[ "$persistent" == "true" ]] && echo "AÇILIŞTA telafi edilir (--catch-up-on-boot)" || echo "telafi edilmez (crontab-parity varsayılanı)")"
    echo "  Oluşturma        : ${created:-bilinmiyor}"
    echo "  Etkin mi         : $(_cron_is_enabled "$timer")"
    echo "  Aktif durum      : $(_cron_active_state "$svc")"
    echo "  Son çalışma      : $(_cron_last_run "$svc")"
    echo "  Sonraki çalışma  : $(_cron_next_run "$timer")"
    echo "  Son çıkış kodu   : $(_cron_last_exit "$svc")"
    if [[ -n "$domain" ]]; then
        echo "  Loglar           : srvctl cron logs ${domain} ${name}"
    else
        echo "  Loglar           : srvctl cron logs --system ${name}"
    fi
    echo ""
}

# ═══════════════════════════════════════════════
#  cron run <domain>|--system <ad>   (şimdi bir kez çalıştır — test)
# ═══════════════════════════════════════════════
_cron_run() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron run <domain>|--system <ad>"

    local sname="" domain=""
    if [[ "$scope_arg" != "--system" ]]; then
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc
    svc=$(_cron_svc_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc}" ]] || error "Cron bulunamadı: ${name}"

    info "Şimdi çalıştırılıyor (test): ${svc} ..."
    systemctl start "$svc" 2>/dev/null || true
    local code logs_target
    code=$(_cron_unit_prop "$svc" ExecMainStatus)
    logs_target="--system"; [[ -n "$domain" ]] && logs_target="$domain"
    if [[ "$code" == "0" ]]; then
        success "Çalıştırıldı, çıkış kodu: 0"
    else
        warn "Çalıştırıldı, çıkış kodu: ${code:-bilinmiyor} — ayrıntı: srvctl cron logs ${logs_target} ${name}"
    fi
    log_action "CRON RUN (manuel test): ${name} (${svc}) exit=${code:-bilinmiyor}"
}

# ═══════════════════════════════════════════════
#  cron enable|disable <domain>|--system <ad>
# ═══════════════════════════════════════════════
_cron_set_enabled() {
    local want_enabled="$1" scope_arg="${2:-}" name="${3:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron enable|disable <domain>|--system <ad>"

    local sname="" domain=""
    if [[ "$scope_arg" != "--system" ]]; then
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local timer
    timer=$(_cron_timer_name "$sname" "$name")
    [[ -e "${sysd_dir}/${timer}" ]] || error "Cron bulunamadı: ${name}"

    if [[ "$want_enabled" == "true" ]]; then
        systemctl enable --now "$timer" >/dev/null 2>&1 || true
        success "Etkinleştirildi: ${name}"
        log_action "CRON ENABLE: ${name} (${timer})"
    else
        systemctl disable --now "$timer" >/dev/null 2>&1 || true
        success "Devre dışı bırakıldı: ${name}"
        log_action "CRON DISABLE: ${name} (${timer})"
    fi
}

# ═══════════════════════════════════════════════
#  cron remove <domain>|--system <ad>
# ═══════════════════════════════════════════════
_cron_remove() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron remove <domain>|--system <ad>"

    local sname="" domain="" scope_label
    if [[ "$scope_arg" == "--system" ]]; then
        scope_label="sistem geneli"
    else
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
        scope_label="domain: ${domain}"
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc timer fail
    svc=$(_cron_svc_name "$sname" "$name")
    timer=$(_cron_timer_name "$sname" "$name")
    fail=$(_cron_fail_svc_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc}" || -e "${sysd_dir}/${timer}" ]] || error "Cron bulunamadı: ${name} (${scope_label})"

    if ! confirm "'${name}' (${scope_label}) cron'u kalıcı olarak silinsin mi?"; then
        info "İptal edildi."
        return 0
    fi

    systemctl disable --now "$timer" >/dev/null 2>&1 || true
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable --now "$fail" >/dev/null 2>&1 || true

    rm -f -- "${sysd_dir}/${timer}" "${sysd_dir}/${svc}" "${sysd_dir}/${fail}"
    rm -rf -- "${sysd_dir}/${svc}.d"
    rm -f -- "$(_cron_sidecar_dir "$sname")/${name}.conf"

    systemctl daemon-reload >/dev/null 2>&1 || true

    success "Cron silindi: ${name} (${scope_label})"
    log_action "CRON REMOVE: ${name} (${scope_label})"
}

# ═══════════════════════════════════════════════
#  cron logs <domain>|--system <ad> [-n N]
# ═══════════════════════════════════════════════
_cron_logs() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron logs <domain>|--system <ad> [-n N]"

    local n=50
    local -a rest=("${@:3}")
    local idx=0 a
    while (( idx < ${#rest[@]} )); do
        a="${rest[$idx]}"
        case "$a" in
            -n)
                idx=$((idx + 1))
                n="${rest[$idx]:-50}"
                ;;
            -n*)
                n="${a#-n}"
                ;;
        esac
        idx=$((idx + 1))
    done
    validate_uint "$n" 100000 || n=50

    local sname=""
    if [[ "$scope_arg" != "--system" ]]; then
        domain_exists "$scope_arg" || error "Domain bulunamadı: ${scope_arg}"
        sname=$(safe_name "$scope_arg")
    fi
    local svc
    svc=$(_cron_svc_name "$sname" "$name")

    command -v journalctl >/dev/null 2>&1 || error "journalctl bulunamadı — loglar okunamıyor"
    journalctl -u "$svc" -n "$n" --no-pager
}
