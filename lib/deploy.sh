#!/bin/bash
# ═══════════════════════════════════════════════
#  deploy.sh — Git-based Zero-Downtime Deploy (v2)
#  Atomic symlink switch + dry-run + pre/post hook
#  + health check (otomatik rollback) + rollback
#  + framework-farkında shared/build/migration + bildirim
# ═══════════════════════════════════════════════
# shellcheck disable=SC2153
# Yukarıdaki dosya-geneli disable KASITLI: 'shellcheck -x' bu dosyadaki
# 'source "${SRVCTL_ROOT}/lib/domain.sh"' (çapraz modül, _deploy_read_framework)
# satırını çalıştırma dizini repo kökü olduğunda ŞANSA BAĞLI olarak
# çözebiliyor ve domain.sh'ı (ve onun kendi source ettiği backup.sh'ı)
# analize dahil ediyor — bu da domain.sh/backup.sh içindeki KENDİ dosyalarım
# OLMAYAN yerel değişkenlerle WEB_ROOT arasında sahte "possible misspelling"
# (SC2153) uyarısı üretiyor. Bu dosyanın kendi WEB_ROOT kullanımlarında
# gerçek bir yazım hatası YOK (bkz. core.sh/load_config — WEB_ROOT orada
# atanır); uyarı tamamen -x'in dinamik source takibinin yan etkisidir.

cmd_deploy() {
    require_root
    case "${1:-}" in
        rollback) _deploy_rollback "${@:2}" ;;
        health)   _deploy_health "${@:2}" ;;
        list)     _deploy_list "${@:2}" ;;
        prune)
            # Standalone 'srvctl deploy prune' çağrısı (deploy sonundaki OTOMATİK
            # prune'dan AYRI): --apply verilmişse operatöre gerçek sonucu bildir.
            # (webhook.sh'ın koşulsuz "success" bildirim hatasına karşı deploy.sh
            # kendi doğru bildirimini üretir — bkz. rapor.)
            local _prune_out _prune_apply=0 _a
            for _a in "${@:2}"; do [[ "$_a" == "--apply" ]] && _prune_apply=1; done
            _prune_out=$(_deploy_prune "${@:2}" 2>&1)
            [[ -n "$_prune_out" ]] && echo "$_prune_out"
            if [[ "$_prune_apply" == "1" ]]; then
                _deploy_notify "srvctl: manuel prune çalıştırıldı" "${_prune_out:-(silinecek bir şey yoktu)}" "info"
            fi
            ;;
        ""|help|-h|--help)
            echo ""
            echo "  Kullanım: srvctl deploy <domain> [branch] [--dry-run]"
            echo ""
            echo "    <domain> [branch]      Deploy et (varsayılan branch: main)"
            echo "    --dry-run              Sadece dene, canlıya geçirme"
            echo "    rollback <domain>      Bir önceki sürüme dön"
            echo "    health <domain>        Sağlık kontrolü çalıştır"
            echo "    list <domain>          Mevcut release'leri listele"
            echo "    prune <domain>|--all   Eski release'leri temizle (varsayılan: dry-run)"
            echo "        --keep=N           Tutulacak release sayısı (varsayılan: ${DEPLOY_KEEP_RELEASES:-5}, min 2)"
            echo "        --apply            Gerçekten sil"
            echo "        --include-bak      public_html.bak.* dizinlerini de temizle"
            echo ""
            echo "  Framework davranışı: 'srvctl domain add --framework=ci4|laravel|symfony'"
            echo "  ile beyan edilir (.srvctl-meta: FRAMEWORK). Deploy bu beyana göre"
            echo "  shared/ bağlar ve build/migration adımlarını çalıştırır; repo"
            echo "  içeriğine göre OTOMATİK DEĞİŞMEZ (uyuşmazlıkta yalnız uyarır)."
            echo ""
            ;;
        *) _deploy_run "$@" ;;
    esac
}

# bin/srvctl 'rollback' komutunu doğrudan buraya yönlendirir
cmd_rollback() {
    require_root
    _deploy_rollback "$@"
}

# ───────────────────────────────────────────────────────────────
#  Yetki düşürme (T3): repodan/shared'den gelen KOD asla root çalışmaz.
#  shared/hooks/ ve composer.json web_user tarafından yazılabildiğinden
#  root çalıştırmak doğrudan web_user → root yetki yükseltmesidir.
#  FAIL-CLOSED: runuser yoksa root'a düşmek yerine hata ver.
# ───────────────────────────────────────────────────────────────
_deploy_privdrop() {
    local web_user="$1"; shift
    [[ -n "$web_user" ]] || { warn "privdrop: web_user boş"; return 1; }
    id "$web_user" &>/dev/null || { warn "privdrop: kullanıcı yok: ${web_user}"; return 1; }
    command -v runuser &>/dev/null \
        || { warn "privdrop: 'runuser' bulunamadı (util-linux) — root çalıştırma reddedildi"; return 1; }
    runuser -u "$web_user" -- "$@"
}

# ───────────────────────────────────────────────────────────────
#  Yardımcı: hook çalıştır (varsa) — DAİMA web_user olarak
#  ${base}/shared/hooks/pre-deploy.sh  ve  post-deploy.sh
#  Root gerektiren işler için hook'tan `sudo srvctl ...` çağırın
#  (deployer sudoers girdileri bunun için var).
# ───────────────────────────────────────────────────────────────
_run_hook() {
    local hook_file="$1" release="$2" domain="$3" web_user="${4:-}"
    [[ -f "$hook_file" ]] || return 0
    [[ -n "$web_user" ]] || { warn "Hook atlandı (web_user verilmedi): $(basename "$hook_file")"; return 0; }
    info "Hook çalıştırılıyor: $(basename "$hook_file") (kullanıcı: ${web_user})"
    _deploy_privdrop "$web_user" \
        env RELEASE_DIR="$release" DOMAIN="$domain" HOME="$release" \
        bash "$hook_file" \
        || warn "Hook hata döndürdü: $(basename "$hook_file")"
}

# ───────────────────────────────────────────────────────────────
#  Çapraz modül bildirim (CLAUDE.md deseni): notify.sh yoksa/kurulu
#  değilse sessizce atlanır. PAROLA/SIR ASLA mesaja konulmaz — yalnız
#  domain/branch/release-id/HTTP kodu gibi sır-olmayan alanlar geçer.
#  webhook.sh:249 deploy'un çıkış kodunu KONTROL ETMEDEN her zaman
#  "success" bildirimi yolluyor (bu dosyanın dışında, ayrıca raporlandı);
#  deploy.sh burada KENDİ doğru bildirimini üretir ki gerçek sonuç
#  (başarı/otomatik-rollback/başarısızlık) operatöre sessizce kaybolmasın.
# ───────────────────────────────────────────────────────────────
_deploy_notify() {
    local title="$1" message="$2" level="${3:-info}"
    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || return 0
    command -v send_notification &>/dev/null || return 0
    send_notification "$title" "$message" "$level" 2>/dev/null || true
}

# ───────────────────────────────────────────────────────────────
#  Sağlık kontrolü — tek atış HTTP probe (retry YOK). localhost'a Host
#  header ile istek. Çıktı: HTTP kodu.
# ───────────────────────────────────────────────────────────────
# GÜVENLİK/SAĞLAMLIK (bkz. rapor H6): 'code=$(curl ...)' bir ATAMA
# ifadesidir; 'local code=$(...)' biçiminden FARKLI olarak (o biçimde
# 'local' builtin'inin KENDİ dönüşü curl'ünkini MASKELER, bkz. shellcheck
# SC2155) burada 'local' ayrı bir satırda olduğundan atamanın dönüş DEĞERİ
# curl'ün KENDİ çıkış koduna EŞİTTİR (doğrulandı: 'code=$(cmd_rc7)' altında
# 'set -e' ile İMMEDİATELY exit eder — 'local var=$(...)' aksine burada
# maskeleme YOK, tam tersi bir sorun var: curl bağlantı REDDİNDE (rc=7,
# ör. '--no-ssl' ile eklenmiş bir domain'de 443 dinlemiyorsa) '"%{http_code}"'
# ile "000" YAZAR ama kendi çıkış kodu 7'dir; bu atama İSTİSNASIZ bir ifade
# olduğundan ('if'/'while' koşulu DEĞİL, başka bir '&&'/'||' tarafından da
# TEST EDİLMİYOR) 'set -e' HEMEN devreye girer ve fonksiyon/betik BURADA
# SESSİZCE ölür — aşağıdaki http düşüş bloğu ve _deploy_run'daki TÜM
# health-check/otomatik-rollback mantığı HİÇ ÇALIŞMAZ (atomic switch'ten
# SONRA, hiçbir rollback/bildirim olmadan). '|| code="000"' ekleyerek bu
# atama artık '||' tarafından TEST EDİLİYOR — curl'ün başarısızlığı
# EXEMPT edilir, script devam eder.
_deploy_http_code() {
    local domain="$1"
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 10 -H "Host: ${domain}" "https://127.0.0.1/" 2>/dev/null) || code="000"
    if [[ -z "$code" || "$code" == "000" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 10 -H "Host: ${domain}" "http://127.0.0.1/" 2>/dev/null) || code="000"
    fi
    echo "${code:-000}"
}

# Kabul edilen HTTP kodu mu? PREDİKAT (0=kabul 1=değil). DEPLOY_HEALTH_OK_CODES
# (core.sh/load_config, boşlukla ayrılmış) TEK doğruluk kaynağıdır — üç çağrı
# yerinde de (deploy/rollback/health) burası kullanılır; hardcoded regex YOK.
# 404/403 KASITLI OLARAK varsayılanda yok (composer/vendor kurulmamış bir
# release nginx 404 dönebilir ve "sağlıklı" sayılıp canlıya alınabilirdi).
_deploy_health_ok() {
    local code="$1" c
    for c in ${DEPLOY_HEALTH_OK_CODES:-200 301 302}; do
        if [[ "$code" == "$c" ]]; then
            return 0
        fi
    done
    return 1
}

# Sağlık kontrolü — RETRY'lı. 'systemctl reload' asenkron döner ve
# 'pm = ondemand' ile ilk worker soğuk başlar; TEK atış probe bu yüzden
# yanlış-negatif üretip SAĞLAM bir deploy'u gereksiz otomatik rollback'e
# sürükleyebiliyordu. İlk denemeden önce kısa sabit bekleme (reload'un
# işlemesi için), sonra DEPLOY_HEALTH_RETRIES kez dene, denemeler arası
# DEPLOY_HEALTH_INTERVAL saniye. İlk kabul edilen kodda hemen çıkar; tüm
# denemeler başarısızsa SON görülen kodu yazdırır.
_health_probe() {
    local domain="$1"
    local retries="${DEPLOY_HEALTH_RETRIES:-5}"
    local interval="${DEPLOY_HEALTH_INTERVAL:-2}"
    local code="000" attempt=1

    sleep 1 2>/dev/null || true

    while true; do
        # '|| code="000"' savunma-derinliği içindir (bkz. H6): _deploy_http_code
        # artık kendi içinde curl başarısızlıklarını yutuyor ve HER ZAMAN 0 ile
        # dönüyor, ama bu çağrı yine de aynı errexit-maskeleme sınıfına karşı
        # kendi başına sağlam olsun diye korunuyor.
        code=$(_deploy_http_code "$domain") || code="000"
        if _deploy_health_ok "$code"; then
            break
        fi
        if (( attempt >= retries )); then
            break
        fi
        sleep "$interval" 2>/dev/null || true
        attempt=$((attempt + 1))
    done
    echo "$code"
}

# Repo URL güvenlik kapısı (PREDIKAT: 0=güvenli 1=güvensiz; exit YOK).
# .deploy-repo web-kullanıcısına ait dizinde olabildiğinden içeriği GÜVENİLMEZ.
# Yalnız https://, ssh://, git@host:path şemaları; ext::/fd::/file:: transport
# helper'ları (git RCE vektörü), baştaki '-' (option-injection), boşluk/'::' reddedilir.
_deploy_validate_repo_url() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    [[ "$url" == -* ]] && return 1
    [[ "$url" =~ [[:space:]] ]] && return 1
    [[ "$url" == *"::"* ]] && return 1
    [[ "$url" == file://* ]] && return 1
    [[ "$url" =~ ^https://[A-Za-z0-9._~:/@%?=\&-]+$ ]] && return 0
    [[ "$url" =~ ^ssh://[A-Za-z0-9._~:/@%-]+$ ]] && return 0
    [[ "$url" =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$ ]] && return 0
    return 1
}

# https URL'sinde userinfo (kullanıcı:token@host) var mı? PREDİKAT (0=var).
# REDDETMİYORUZ (mevcut kurulumları kırar, SSH/credential-helper'a geçiş için
# escape yolu yok) — yalnız net uyarı. Risk: 'git clone' argv'sinde URL
# görünür; clone süresince YEREL herhangi bir kullanıcı 'ps aux' ile token'ı
# okuyabilir.
_deploy_url_has_userinfo() {
    [[ "$1" =~ ^https://[^/[:space:]]*@ ]]
}

# shared/ artefaktı root operasyonu (ln/chown -R) için güvenli mi?
# PREDİKAT: 0=güvenli, 1=güvensiz. Symlink (dangling dahil) reddedilir —
# yoksa web_user 'shared/writable'ı /etc'ye symlink yapıp 'chown -R' ile
# /etc'yi ele geçirebilir (yetki yükseltme). Var olmayan yol da güvensiz sayılır.
# Bu kapı deploy.sh'ın bağladığı HER shared artefaktı için zorunludur:
# 'writable' (CI4), 'storage'/'bootstrap-cache' (Laravel), 'var' (Symfony).
_deploy_assert_safe_shared() {
    local path="$1"
    [[ -L "$path" ]] && return 1
    [[ -e "$path" ]] || return 1
    return 0
}

# Bir takvim tarihinin (y/m/g sa:dk:sn) POSIX epoch'a YAKLAŞIK karşılığını SAF
# bash aritmetiğiyle hesaplar (Howard Hinnant'ın 'days_from_civil' algoritması,
# proleptic Gregorian). 'date -d' KASITLI OLARAK KULLANILMAZ: GNU'ya özgüdür,
# macOS/BSD date'te YOK — bu proje macOS'ta test edilir (bkz. CLAUDE.md/tests,
# tests/run.sh). Yalnız SIRALAMA/GELECEK-TARİH kıyası için kullanılır; gerçek
# saat dilimi/artık-saniye hassasiyeti GEREKMEZ — hem id hem 'şimdi' AYNI
# dönüşümden geçtiği için tutarlıdır (bkz. _deploy_is_release_id).
_deploy_civil_epoch() {
    local y="$1" m="$2" d="$3" h="$4" mi="$5" s="$6"
    (( m <= 2 )) && y=$((y - 1))
    local era
    if (( y >= 0 )); then era=$((y / 400)); else era=$(( (y - 399) / 400 )); fi
    local yoe=$((y - era * 400))
    local mp=$(( (m + 9) % 12 ))
    local doy=$(( (153 * mp + 2) / 5 + d - 1 ))
    local doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    local days=$(( era * 146097 + doe - 719468 ))
    echo $(( days * 86400 + h * 3600 + mi * 60 + s ))
}

# Release ID biçimi: deploy'un ürettiği YYYYmmdd_HHMMSS[_hexhex] (sonek: bkz.
# K2/_deploy_rand_suffix — eski, soneksiz id'ler de KABUL edilir, geriye
# dönük uyumluluk için). Beyaz liste — prune yalnız bu desene uyan VE
# takvimsel olarak ANLAMLI VE 'şimdi'nin GELECEĞİNDE olmayan dizinleri
# SİLMEYE/SAYMAYA aday sayar.
#
# YALNIZCA biçim (^[0-9]{8}_[0-9]{6}$) YETERSİZDİ (bkz. rapor Y1):
# 'releases/99999999_999999' bu deseni geçiyordu ve 'sort -r' ile HER ZAMAN
# en başa oturuyordu — web_user (releases/ yazılabilir, FPM open_basedir
# içinde) bunu ekleyip prune'un keep-penceresini sahte girdiyle doldurarak
# GERÇEK eski release'lerin (rollback hedeflerinin) kalıcı silinmesine yol
# açabiliyordu (anti-forensics/persistence). Bu yüzden burada hem alan
# aralığı (ay 1-12, gün 1-31, saat/dakika/saniye geçerli) hem de "gelecek
# tarih" reddi var: gerçek id'ler HER ZAMAN üretim anındaki 'şimdi'nin
# gerisindedir (deploy id'yi üretir, prune dakikalar SONRA çalışır); 120sn
# tolerans yalnız saat senkron sapması için — ötesi sahte sayılır.
_deploy_is_release_id() {
    local id="$1"
    [[ "$id" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})(_[0-9a-f]{6})?$ ]] || return 1
    local y=$((10#${BASH_REMATCH[1]})) mo=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
    local h=$((10#${BASH_REMATCH[4]})) mi=$((10#${BASH_REMATCH[5]})) s=$((10#${BASH_REMATCH[6]}))

    (( mo >= 1 && mo <= 12 )) || return 1
    (( d  >= 1 && d  <= 31 )) || return 1
    (( h  <= 23 )) || return 1
    (( mi <= 59 )) || return 1
    (( s  <= 59 )) || return 1

    local now_y now_mo now_d now_h now_mi now_s
    now_y=$((10#$(date +%Y))); now_mo=$((10#$(date +%m))); now_d=$((10#$(date +%d)))
    now_h=$((10#$(date +%H))); now_mi=$((10#$(date +%M))); now_s=$((10#$(date +%S)))
    local id_epoch now_epoch
    id_epoch=$(_deploy_civil_epoch "$y" "$mo" "$d" "$h" "$mi" "$s")
    now_epoch=$(_deploy_civil_epoch "$now_y" "$now_mo" "$now_d" "$now_h" "$now_mi" "$now_s")
    (( id_epoch <= now_epoch + 120 ))
}

# Bir domain'in releases/ dizinindeki GEÇERLİ release id'lerini (bkz.
# _deploy_is_release_id) en yeniden en eskiye sıralar. mtime'a GÜVENMEZ —
# 'ls -t' releases/'in web_user tarafından yazılabilir ve FPM open_basedir'ı
# içinde olması nedeniyle touch() ile manipüle edilebilir (bkz. Y1/Y2/H4).
# _deploy_prune_one, _deploy_rollback ve _deploy_list AYNI kaynağı kullanır —
# TEK sözleşme (önceden iki farklı ajan aynı dosyada iki farklı desen
# uygulamıştı: prune find+sort-r+whitelist, rollback/list 'ls -t').
_deploy_release_ids() {
    local releases_dir="$1" name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _deploy_is_release_id "$name" && printf '%s\n' "$name"
    done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -r)
}

# Release id'sine rastgele sonek (6 hex karakter, ~24 bit). id SALT
# 'date +%Y%m%d_%H%M%S' olduğunda tamamen ÖNGÖRÜLEBİLİRDİ: saldırgan (web_user,
# releases/ yazılabilir) önümüzdeki saat için 3600 sembolik bağlantı önceden
# hazırlayıp ('symlink("/usr/local/srvctl/plugins", "releases/<tahmin>")' gibi)
# doğru saniyeyi yakalayabiliyordu — ardından ROOT'un 'git clone'u o hedefe
# yazardı (bkz. K2 — root RCE zinciri). ASIL kapı _deploy_run'daki ATOMİK
# 'mkdir' (parolasız, TOCTOU'suz) — bu sonek yalnız İKİNCİL savunma: mkdir
# tek başına saldırıyı RCE'den fail-closed DoS'a indirger (deploy hata verir,
# kod ÇALIŞMAZ); sonek bu DoS'un pratik uygulanabilirliğini de (3600 tahmin
# yerine 3600*2^24) düşürür.
_deploy_rand_suffix() {
    local out
    out=$(openssl rand -hex 3 2>/dev/null) && [[ "$out" =~ ^[0-9a-f]{6}$ ]] && { echo "$out"; return 0; }
    out=$( { od -An -tx1 -N3 /dev/urandom 2>/dev/null || true; } | tr -d ' \n')
    [[ "$out" =~ ^[0-9a-f]{6}$ ]] && { echo "$out"; return 0; }
    # Son çare: openssl/urandom yoksa $RANDOM'dan türet — kriptografik değil
    # ama ASIL güvenlik zaten atomik mkdir'de (yukarıya bkz.), burası yalnız
    # tahmin maliyetini artıran ek bir katman.
    printf '%06x\n' $(( (RANDOM * RANDOM + RANDOM) % 16777216 ))
}

# Mutlak bir release yolunu GÖRELİ symlink hedefine çevirir:
#   /var/www/x/releases/<id>[/public]  ->  releases/<id>[/public]
# Chroot'lu FPM (chroot=/var/www/<domain>) mutlak host yolunu ÇÖZEMEZ;
# public_html mutlak symlink olursa tüm PHP istekleri "No input file
# specified" döner. base/releases altında değilse 1 döner (çağıran reddeder).
_deploy_relative_link() {
    local base="$1" target="$2"
    [[ -n "$target" ]] || return 1
    local prefix="${base}/releases/"
    [[ "$target" == "${prefix}"* ]] || return 1
    local rest="${target#"$prefix"}"
    [[ -n "$rest" && "$rest" != *".."* ]] || return 1
    printf 'releases/%s\n' "$rest"
}

# 'public_html' (veya 'current') symlink'ini ATOMİK olarak değiştirir.
# ln -sfn atomik DEĞİLDİR (unlink()+symlink(); arada linkin var olmadığı bir
# pencere vardır → o an gelen istekler 404/500, ya da worker/scheduler için
# WorkingDirectory çözülemez). mv -T rename(2) kullanır; ayrıca hedef gerçek
# bir DİZİN ise başarısız olur, yani 'rm -rf' gerekmez (yanlışlıkla site
# silme riski kapanır).
# link_name (3. param, varsayılan 'public_html'): hangi symlink'in
# değiştirileceği. GENELLEŞTİRİLDİ (T3 sonrası koordinatör notu) ki 'current'
# (worker/scheduler WorkingDirectory'si, release KÖKÜNE bakar — bkz.
# lib/domain.sh:_domain_working_dir) AYNI atomik/guard yoldan geçsin.
# Varsayılan çağrı (2 argümanla) ESKİ davranışla BİREBİR AYNI — tmp adı da
# dahil ('.public_html.new.$$') — tests/test_deploy_link.sh sözleşmesini
# BOZMAZ.
_deploy_link_current() {
    local base="$1" rel_link="$2" link_name="${3:-public_html}"
    local target_link="${base}/${link_name}"
    [[ -n "$rel_link" ]] || { warn "Boş symlink hedefi reddedildi"; return 1; }
    [[ "$rel_link" == /* ]] && { warn "Mutlak symlink hedefi reddedildi (chroot): ${rel_link}"; return 1; }

    local tmp="${base}/.${link_name}.new.$$"
    rm -f "$tmp"
    ln -sfn "$rel_link" "$tmp" || return 1
    if mv -T "$tmp" "$target_link" 2>/dev/null; then
        return 0
    fi
    # mv -T BAŞARISIZ oldu. GÜVENLİK (bkz. rapor B1): hedef GERÇEK bir dizinse
    # (symlink DEĞİL — ör. ilk deploy öncesi domain.sh'ın oluşturduğu düz
    # public_html/current, ya da elle yapılmış bir kurulum) aşağıdaki eski
    # 'ln -sfn' düşüş yolu linki dizinin İÇİNE (ör. public_html/<id>) koyar ve
    # 0 DÖNER — yani "atomik switch başarılı" sanılır ama site hâlâ eski/bozuk
    # haldedir; _deploy_rollback'teki '|| error' hiç tetiklenmez, "Rollback
    # başarılı" yazılır ama canlı sürüm değişmemiştir. Bu yüzden bu durumda
    # KESİN reddet, asla sessizce devam etme. Düşüş yolu YALNIZCA "mv -T
    # desteklenmiyor" (BSD/macOS mv, -T bayrağı yok) durumunu kapsamalıdır —
    # o durumda target_link ya YOK ya da (zaten bizim ürettiğimiz) bir
    # symlink'tir, gerçek bir dizin DEĞİLDİR.
    if [[ -d "$target_link" && ! -L "$target_link" ]]; then
        rm -f "$tmp"
        warn "Atomik switch başarısız: ${target_link} GERÇEK bir dizin (symlink değil) — üzerine yazma reddedildi"
        return 1
    fi
    rm -f "$tmp"
    ln -sfn "$rel_link" "$target_link"
}

# Per-domain deploy kilidi (flock). Aynı domain'e eş zamanlı iki deploy
# aynı release_dir adını üretebilir, birbirinin symlink'ini ezebilir ve
# birinin prune'u diğerinin doldurmakta olduğu dizini silebilir.
# fd 9'u tutar; kilit süreç bitince otomatik serbest kalır.
_deploy_lock() {
    local domain="$1" sname; sname=$(safe_name "$domain")
    local lock_dir="${SRVCTL_LOCK_DIR:-/run/srvctl}"
    command -v flock &>/dev/null || { warn "flock yok — eşzamanlılık koruması devre dışı"; return 0; }
    secure_dir "$lock_dir" 700
    exec 9>"${lock_dir}/deploy-${sname}.lock" || return 0
    flock -n 9 \
        || error "Bu domain için bir deploy zaten çalışıyor: ${domain}"
}

# ───────────────────────────────────────────────────────────────
#  Per-domain meta okuyucu (deploy'a özgü anahtarlar).
#  core.sh/read_meta yalnız RATE_PROFILE/SENSITIVE_PATHS okur; core.sh bu
#  fazda PARALEL bir agent tarafından da değiştirilebiliyor olabileceğinden
#  (dosya sahipliği: core.sh benim alanım DEĞİL) read_meta'nın anahtar
#  listesini oradan genişletmek yerine deploy.sh kendi okuyucusunu tutar.
#  Sahiplik kapısı AYNI: root-owned/hardened kontrolü _require_owned_or_warn
#  ile (core.sh) — .srvctl-meta web-yazılabilir olabildiğinden (hardened
#  olmayan domain) GÜVENİLMEZ, tamper'da (hardened + root-owned değil) error.
# ───────────────────────────────────────────────────────────────
_deploy_read_meta() {
    local domain="$1"; shift
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    [[ -f "$meta_file" ]] || return 0
    _require_owned_or_warn "$domain" "$meta_file" \
        || error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
    read_kv_file "$meta_file" "$@"
}

# ───────────────────────────────────────────────────────────────
#  Framework okuma — TEK KAYNAK tercihi (koordinatör notu).
#  lib/domain.sh artık '_domain_read_framework' sağlıyor (whitelist +
#  tamper-gate zaten orada uygulanmış, ci4|laravel|symfony döndürür).
#  Çapraz modül deseni (CLAUDE.md): guard'lı source. domain.sh bu FAZDA
#  PARALEL bir agent tarafından değiştirilebildiğinden (dosya sahipliği
#  bende DEĞİL) SERT bağımlılık KURULMAZ — source/fonksiyon yoksa ya da
#  çıktı boşsa deploy.sh'ın kendi bağımsız okuyucusuna (_deploy_read_meta)
#  fail-soft düşülür. Her iki yol da AYNI whitelist politikasını uygular
#  (ci4|laravel|symfony; geçersiz/eksikte 'ci4').
# ───────────────────────────────────────────────────────────────
# ÖNEMLİ: core.sh/warn() STDOUT'a yazar (stderr'e DEĞİL). Bu fonksiyon
# HER ZAMAN '$(...)' ile çağrılır (bkz. _deploy_run: FRAMEWORK=$(...)) —
# yani gövdesinde stdout'a giden HERHANGİ bir warn çıktısı FRAMEWORK
# değerine KARIŞIRDI. Bu yüzden buradaki (ve _domain_read_framework'ün
# kendi) uyarı satırları AÇIKÇA '>&2' ile stderr'e yönlendirilir — tıpkı
# core.sh/rate_profile_resolve ve lib/domain.sh/_domain_read_framework'ün
# zaten yaptığı gibi.
_deploy_read_framework() {
    local domain="$1"
    local fw=""
    if source "${SRVCTL_ROOT}/lib/domain.sh" 2>/dev/null && command -v _domain_read_framework &>/dev/null; then
        # 2>/dev/null YOK: _domain_read_framework kendi uyarılarını zaten
        # '>&2' ile ayırıyor, burada susturmuyoruz (operatör görsün).
        fw=$(_domain_read_framework "$domain") || fw=""
    fi
    if [[ -z "$fw" ]]; then
        local FRAMEWORK=""
        _deploy_read_meta "$domain" FRAMEWORK
        case "${FRAMEWORK:-}" in
            ci4|laravel|symfony) fw="$FRAMEWORK" ;;
            "") fw="ci4" ;;
            *)
                warn "Geçersiz FRAMEWORK meta değeri: '${FRAMEWORK}' — 'ci4' varsayılanına düşülüyor"
                fw="ci4"
                ;;
        esac
    fi
    echo "$fw"
}

# Release içeriğinden framework TESPİTİ — SADECE raporlama/uyarı içindir.
# İzin/izolasyon kararları operatörün 'srvctl domain add --framework' ile
# beyan ettiği (.srvctl-meta FRAMEWORK) değere göre alınır; ele geçirilmiş
# bir repo sahte 'artisan'/'spark' dosyası koyarak farklı bir yazma
# profili TETİKLEYEMEZ (bu fonksiyonun dönüşü hiçbir güvenlik kararını
# etkilemez).
_deploy_detect_framework() {
    local dir="$1"
    if [[ -f "${dir}/artisan" ]]; then
        echo "laravel"; return 0
    fi
    if [[ -f "${dir}/spark" ]]; then
        echo "ci4"; return 0
    fi
    if [[ -f "${dir}/bin/console" ]]; then
        echo "symfony"; return 0
    fi
    echo "none"
}

# release_dir'e göre bir alt yolun (rel_path) shared/'e GÖRELİ symlink
# hedefini üretir. Derinlik = rel_path'teki '/' sayısı + 2 ('release_dir'
# köküne göre ../.. + shared/<ad>; release_dir = base/releases/<id> olduğundan
# ../.. taban dizine çıkar). Örn: 'storage' -> '../../shared/storage',
# 'bootstrap/cache' -> '../../../shared/bootstrap-cache' (Laravel bootstrap/
# cache iki seviye derinde olduğundan bir '../' fazladan gerekir).
_deploy_shared_rel() {
    local rel_path="$1" shared_subdir="$2" depth=2 rest="$1" up="" i
    while [[ "$rest" == */* ]]; do
        depth=$((depth + 1))
        rest="${rest#*/}"
    done
    for ((i = 0; i < depth; i++)); do
        up="${up}../"
    done
    printf '%sshared/%s\n' "$up" "$shared_subdir"
}

# release_dir içindeki bir alt yolu (rel_path) shared/ altındaki karşılığına
# (shared_subdir) bağlar. CI4 'writable', Laravel 'storage' ve
# 'bootstrap/cache' -> 'bootstrap-cache', Symfony 'var' için kullanılır.
# _deploy_assert_safe_shared kapısı HER ÇAĞRIDA zorunlu — shared_subdir
# HERHANGİ BİR symlink'e (örn. /etc) işaret ediyorsa deploy TAMAMEN
# REDDEDİLİR (chown -R yetki-yükseltme vektörü; bkz. shared/writable
# tarihçesi). İlk deploy'da (shared tarafı henüz yoksa) release içindeki
# mevcut içerik shared'e taşınır (bootstrap). Dönüş: 0=bağlandı,
# 2=ikisi de yok (atlanır, hata değil). Güvenlik ihlalinde error() (exit).
# GÜVENLİK (bkz. rapor H1) — bu fonksiyon ':716'da
# '_deploy_link_shared ... || rc=$?' biçiminde çağrılır. Bash'te bir fonksiyon
# çağrısı '||'/'if'in TEST EDİLEN tarafındaysa, 'set -e' o fonksiyonun TÜM
# GÖVDESİ için devre dışı kalır (doğrulandı: 'f() { false; echo sonra; }; f ||
# rc=$?' içinde 'echo sonra' HER ZAMAN çalışır). Yani bu fonksiyonun içindeki
# HİÇBİR komut errexit'e güvenemez — her potansiyel başarısızlık AÇIKÇA
# '|| error'/kontrol edilmelidir; aşağıdaki her adım bunu yapar.
_deploy_link_shared() {
    local release_dir="$1" shared_dir="$2" rel_path="$3" shared_subdir="$4"
    local shared_target="${shared_dir}/${shared_subdir}"
    local release_target="${release_dir}/${rel_path}"

    if [[ -d "$shared_target" ]]; then
        _deploy_assert_safe_shared "$shared_target" \
            || error "shared/${shared_subdir} bir symlink — deploy reddedildi (chown -R yetki-yükseltme riski)"
        rm -rf -- "$release_target"
    elif [[ -d "$release_target" ]]; then
        # KAPI SIRASI: güvenlik kontrolü kopyalamadan ÖNCE. shared_target bu
        # daldayken '-d' DEĞİLDİR (üstteki 'if' zaten elendi) ama yine de VAR
        # olabilir: sarkan (dangling) bir symlink, bir symlink-to-file, ya da
        # düz bir dosya — hepsi 'chown -R'/root operasyonları için güvensizdir.
        # ESKİ kod önce 'cp -r' yapıp assert'i SONRA çalıştırıyordu; yani
        # shared/storage sarkan bir symlink ise kopyalama kapıdan HİÇ
        # geçmeden gerçekleşiyordu.
        if [[ -e "$shared_target" || -L "$shared_target" ]]; then
            error "shared/${shared_subdir} beklenmeyen bir öğe (symlink/dosya, dizin değil) — deploy reddedildi (chown -R yetki-yükseltme riski)"
        fi
        mkdir -p "$(dirname "$shared_target")" \
            || error "shared/${shared_subdir} için üst dizin oluşturulamadı"
        # 'cp -r' dönüş değeri ARTIK kontrol ediliyor (bkz. H1): eskiden
        # (errexit devre dışı olduğundan) disk dolarsa/izin hatası olursa
        # KISMİ bir kopya sessizce bırakılıp devam ediliyor, sonra orijinal
        # (release_target) SİLİNİYORDU — veri kaybı, "success" ile raporlanan
        # bir deploy'da.
        cp -r -- "$release_target" "$shared_target" \
            || error "shared/${shared_subdir} bootstrap kopyalaması başarısız (disk dolu olabilir) — deploy durduruldu, release SİLİNMEDİ: ${release_target}"
        _deploy_assert_safe_shared "$shared_target" \
            || error "shared/${shared_subdir} kopyalama sonrası symlink'e dönüştü (TOCTOU?) — deploy reddedildi"
        rm -rf -- "$release_target"
    else
        return 2
    fi

    mkdir -p "$(dirname "$release_target")" \
        || error "shared/${shared_subdir} bağlanamadı: ${release_target} için üst dizin oluşturulamadı"
    ln -sf "$(_deploy_shared_rel "$rel_path" "$shared_subdir")" "$release_target" \
        || error "shared/${shared_subdir} symlink'i kurulamadı: ${release_target}"
    return 0
}

# PHP-FPM reload sonucu SESSİZCE yutulmamalı: lib/init.sh'ta
# opcache.validate_timestamps=0 olduğundan reload başarısız olursa worker'lar
# YENİ release'i asla görmez — deploy "başarılı" raporlanır ama site
# SÜRESİZ eski bytecode'u servis eder. reload başarısızsa 'restart' ile
# kurtarmayı dene; o da başarısızsa fail-closed dur (PHP-FPM muhtemelen
# çalışmıyordur — sessiz eski-sürüm servisi yerine gürültülü hata tercih
# edilir).
_deploy_reload_fpm() {
    local php_version="$1"
    local unit="php${php_version}-fpm"
    if systemctl reload "$unit" 2>/dev/null; then
        return 0
    fi
    warn "${unit} reload başarısız — 'restart' deneniyor..."
    if systemctl restart "$unit" 2>/dev/null; then
        warn "${unit} restart ile kurtarıldı — reload'un neden başarısız olduğu araştırılmalı (systemctl status ${unit})"
        return 0
    fi
    error "${unit} restart de başarısız — PHP-FPM ÇALIŞMIYOR OLABİLİR, site 502/503 dönüyor olabilir. Manuel müdahale: systemctl status ${unit} / journalctl -u ${unit}"
}

# Framework'e özgü build/cache adımları. DAİMA web_user (privdrop) —
# artisan/spark/console repodan gelir ve lifecycle kod çalıştırır, root
# ASLA. Switch'ten ÖNCE çağrılır (bkz. _deploy_run 6/9): cache/asset
# canlıya alınmadan ÖNCE hazır olsun, ilk isteğin soğuk cache'e denk
# gelmesi engellensin.
#
# Hata politikası: config:cache (Laravel) ve cache:clear (Symfony) o
# framework'ün BOOTSTRAP'ı için kritiktir — sonraki route/view/event
# cache adımları ya da her bir istek zaten bu önbelleğe bağımlıdır;
# bozuk/patlamış bir önbellek canlıya alınırsa sessiz 500 üretir. Bu
# yüzden bunlar (ve onlara bağımlı route:cache/view:cache/event:cache)
# başarısız olursa deploy DURUR (error, exit). storage:link (Laravel),
# spark cache:clear (CI4) ve cache:warmup/assets:install (Symfony)
# PERİFERİK'tir (yalnız statik varlık/performans) — başarısızlıkları
# yalnız warn ile bildirilir, deploy durmaz (en kötü ihtimalle STALE
# cache servis edilir; bu risk zaten OPcache validate_timestamps=0 ile
# kabul edilmiş bir modeldir, bkz. rapor).
_deploy_build() {
    local framework="$1" release_dir="$2" web_user="$3" php_bin="$4"

    case "$framework" in
        laravel)
            if [[ ! -f "${release_dir}/artisan" ]]; then
                info "artisan bulunamadı — Laravel build adımları atlanıyor"
            else
                local step_name
                for step_name in config:cache route:cache view:cache event:cache; do
                    _deploy_privdrop "$web_user" \
                        env HOME="$release_dir" "$php_bin" "${release_dir}/artisan" "$step_name" --no-interaction \
                        || error "artisan ${step_name} başarısız — deploy durduruldu (bozuk önbellek canlıya alınmaz)"
                done
                # storage:link: public/storage -> storage/app/public. HER release
                # yeni bir dizin olduğundan bu symlink HER seferinde yeniden kurulmalı.
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" "$php_bin" "${release_dir}/artisan" storage:link --no-interaction \
                    || warn "artisan storage:link başarısız — public/storage bağlanmamış olabilir (devam ediliyor)"
            fi
            ;;
        ci4)
            if [[ ! -f "${release_dir}/spark" ]]; then
                info "spark bulunamadı — CI4 build adımları atlanıyor"
            else
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" "$php_bin" "${release_dir}/spark" cache:clear \
                    || warn "spark cache:clear başarısız (devam ediliyor — en kötü ihtimalle stale cache servis edilir)"
            fi
            ;;
        symfony)
            if [[ ! -f "${release_dir}/bin/console" ]]; then
                info "bin/console bulunamadı — Symfony build adımları atlanıyor"
            else
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" "$php_bin" "${release_dir}/bin/console" cache:clear --env=prod --no-interaction \
                    || error "bin/console cache:clear başarısız — deploy durduruldu (bozuk önbellek canlıya alınmaz)"
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" "$php_bin" "${release_dir}/bin/console" cache:warmup --env=prod --no-interaction \
                    || warn "bin/console cache:warmup başarısız (devam ediliyor)"
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" "$php_bin" "${release_dir}/bin/console" assets:install --no-interaction "${release_dir}/public" \
                    || warn "bin/console assets:install başarısız (devam ediliyor)"
            fi
            ;;
        *)
            info "Bilinmeyen framework (${framework}) — build adımları atlanıyor"
            ;;
    esac

    if [[ "${DEPLOY_NPM_BUILD:-false}" == "true" ]]; then
        if [[ -f "${release_dir}/package.json" ]]; then
            command -v npm &>/dev/null \
                || error "DEPLOY_NPM_BUILD=true ama 'npm' kurulu değil — deploy durduruldu"
            _deploy_privdrop "$web_user" \
                env HOME="$release_dir" npm --prefix "$release_dir" ci \
                || error "npm ci başarısız — deploy durduruldu"
            _deploy_privdrop "$web_user" \
                env HOME="$release_dir" npm --prefix "$release_dir" run build \
                || error "npm run build başarısız — deploy durduruldu"
        else
            info "package.json yok — npm build atlanıyor (DEPLOY_NPM_BUILD=true)"
        fi
    fi
}

# Deploy sonrası worker/scheduler restart (yalnız sağlık OK'ten sonra çağrılır).
# systemd 'WorkingDirectory' süreç başlarken BİR KEZ çözülür — public_html
# symlink'i değişse de ÇALIŞAN worker eski release'de kalır (eski kodu
# çalıştırmaya devam eder). systemctl restart'ın glob'u sürüme göre farklı
# davranabileceğinden (bkz. .claude/ubuntu-compat.md: yetenek tespiti >
# sürüm karşılaştırması) glob'a GÜVENMİYORUZ: 'list-units' ile YÜKLÜ birimleri
# numaralandırıp TEK TEK restart ediyoruz. Unit yoksa (domain'de worker/
# scheduler kurulu değilse) sessizce geçilir.
_deploy_restart_workers() {
    local domain="$1" sname; sname=$(safe_name "$domain")
    command -v systemctl &>/dev/null || return 0

    local unit
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        if systemctl restart -- "$unit" 2>/dev/null; then
            info "Yeniden başlatıldı: ${unit}"
        else
            warn "Yeniden başlatılamadı: ${unit}"
        fi
    done < <(systemctl list-units --all --plain --no-legend \
                 "srvctl-worker-${sname}@*.service" "srvctl-scheduler-${sname}.service" 2>/dev/null \
             | awk '{print $1}')
}

# ───────────────────────────────────────────────────────────────
#  deploy <domain> [branch] [--dry-run]
# ───────────────────────────────────────────────────────────────
_deploy_run() {
    local domain="" branch="main" dry_run=0
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --*) warn "Bilinmeyen seçenek: ${arg}" ;;
            *) if [[ -z "$domain" ]]; then domain="$arg"; else branch="$arg"; fi ;;
        esac
    done

    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy <domain> [branch] [--dry-run]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    _deploy_lock "$domain"

    local sname
    sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"
    local release_dir; release_dir="${base}/releases/$(date +%Y%m%d_%H%M%S)_$(_deploy_rand_suffix)"
    local shared_dir="${base}/shared"
    local public_dir="${base}/public_html"

    # Kimlikleri safe_name'den türet; PHP'yi doğrula (web-owned .credentials'a güvenme)
    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    local web_user="web_${sname}"

    # Build/migration adımları için sürüm-doğru PHP CLI ikili dosyasını
    # tercih et (Ondřej PPA 'php8.1'/'php8.3' gibi versiyonlu ikili sağlar;
    # yoksa PATH'teki 'php'ye düş). Domain'in FPM'de kullandığı sürümle
    # tutarsız bir CLI, "CLI'de çalışıyor ama FPM'de çalışmıyor" sınıfı
    # sorunlara yol açabilir.
    local php_bin
    php_bin=$(command -v "php${php_version}" 2>/dev/null) || php_bin=""
    [[ -z "$php_bin" ]] && php_bin=$(command -v php 2>/dev/null)
    [[ -z "$php_bin" ]] && php_bin="php"

    # ── Per-domain meta: FRAMEWORK/RUN_MIGRATIONS/KEEP_GIT (KULLANICI KARARI) ──
    # Meta web-yazılabilir olabildiğinden (hardened olmayan domain) GÜVENİLMEZ;
    # her biri beyaz liste/validate_bool ile doğrulanır, geçersizse güvenli
    # varsayılana düşülür (fail-closed: bilinmeyen framework -> ci4, migration
    # kapalı, .git kaldırılır).
    # FRAMEWORK: TEK KAYNAK — lib/domain.sh/_domain_read_framework varsa onu
    # kullan (aynı whitelist+tamper-gate _deploy_read_framework içinde fail-soft
    # olarak uygulanır, bkz. o fonksiyonun yorumu).
    local FRAMEWORK; FRAMEWORK=$(_deploy_read_framework "$domain")

    local RUN_MIGRATIONS="" KEEP_GIT=""
    _deploy_read_meta "$domain" RUN_MIGRATIONS KEEP_GIT

    local run_migrations="${DEPLOY_RUN_MIGRATIONS}"
    if [[ -n "${RUN_MIGRATIONS:-}" ]]; then
        if validate_bool "$RUN_MIGRATIONS"; then
            run_migrations="$RUN_MIGRATIONS"
        else
            warn "Geçersiz .srvctl-meta RUN_MIGRATIONS değeri: '${RUN_MIGRATIONS}' — global ayar (${DEPLOY_RUN_MIGRATIONS}) kullanılıyor"
        fi
    fi

    local keep_git="false"
    if [[ -n "${KEEP_GIT:-}" ]]; then
        if validate_bool "$KEEP_GIT"; then
            keep_git="$KEEP_GIT"
        else
            warn "Geçersiz .srvctl-meta KEEP_GIT değeri: '${KEEP_GIT}' — .git kaldırılacak (varsayılan)"
        fi
    fi

    # Framework'e göre shared eşleştirmesi: 'release-yolu:shared-adı'.
    # KULLANICI BEYANINA (${FRAMEWORK}) göre — repodan TESPİT EDİLENE göre
    # DEĞİL (bkz. _deploy_detect_framework yorumu).
    local shared_pairs=()
    case "$FRAMEWORK" in
        ci4)     shared_pairs=("writable:writable") ;;
        laravel) shared_pairs=("storage:storage" "bootstrap/cache:bootstrap-cache") ;;
        symfony) shared_pairs=("var:var") ;;
    esac

    # Önceki sürüm: doğrulama için mutlak yol, geri dönüş için GÖRELİ symlink
    # hedefi. Eski (4374021 öncesi) mutlak link'ler de burada göreliye çevrilir.
    # prev_root_link: 'current' (worker/scheduler WorkingDirectory'si) için —
    # HER ZAMAN release KÖKÜ, '/public' YOK ('%/public' ile atılır; public/
    # içermeyen release'lerde zaten no-op).
    local prev_target="" prev_rel_link="" prev_root_link=""
    if [[ -L "$public_dir" ]]; then
        prev_target=$(readlink -f "$public_dir")
        # $base KANONİKLEŞTİRİLİR (bkz. O9): WEB_ROOT (ya da üstü) symlink
        # olabilir (VPS'lerde '/var' başka bir diske bağlanmış olabilir; macOS
        # test ortamında '/var' zaten '/private/var'a symlink'tir). $prev_target
        # 'readlink -f' ile ZATEN kanonik geldiğinden, ham (kanonik OLMAYAN)
        # $base ile prefix karşılaştırması SESSİZCE eşleşmeyip boş dönebilir —
        # bu da aşağıdaki otomatik-rollback dalını (adım 9) devre dışı bırakıp
        # SAĞLIKSIZ release SİLİNİRKEN public_html hâlâ ona işaret eder hale
        # getirebilir (dangling symlink, tam kesinti). _deploy_prune_one AYNI
        # kanonikleştirmeyi zaten yapıyor (bkz. 'releases_real' orada).
        local base_real; base_real=$(cd "$base" 2>/dev/null && pwd -P) || base_real="$base"
        prev_rel_link=$(_deploy_relative_link "$base_real" "$prev_target") || prev_rel_link=""
        prev_root_link=$(_deploy_relative_link "$base_real" "${prev_target%/public}") || prev_root_link=""
    fi

    header "Deploy: ${domain} (branch: ${branch}, framework: ${FRAMEWORK})"
    [[ "$dry_run" == "1" ]] && warn "DRY-RUN modu: değişiklik canlıya YANSIMAYACAK."

    # Git repo URL
    local repo_url="" repo_file="${base}/.deploy-repo"
    [[ -f "$repo_file" ]] && repo_url=$(cat "$repo_file")
    if [[ -z "$repo_url" ]]; then
        read -rp "  Git repo URL'si: " repo_url
        [[ -z "$repo_url" ]] && error "Repo URL'si boş olamaz."
        echo "$repo_url" > "$repo_file"
        chmod 600 "$repo_file"; chown root:root "$repo_file"
        info "Repo kaydedildi: ${repo_file}"
    fi

    # Sahiplik kapısı: dosya varsa root-owned kontrolü (T1 bütünlük kapısı).
    # repo_file yoksa interaktif sorulur (kapıya gerek yok, henüz oluşmadı).
    # GÜVENLİK (bkz. rapor O3): önceki '[[ -f ]] && _require_owned_or_warn ||
    # true' biçimi operatör önceliği yüzünden HER ZAMAN 0 dönüyordu (A && B ||
    # true => B başarısız olsa bile son terim 'true' olduğundan sonuç asla
    # başarısız SAYILMIYORDU) — yani hardened bir domain'de tamper edilmiş
    # '.deploy-repo' hiçbir zaman hata ÜRETMİYORDU. Aşağıdaki
    # _deploy_validate_repo_url yalnız URL'nin BİÇİMİNİ doğruluyor, tamper'ın
    # KENDİSİNİ değil (ör. saldırgan geçerli biçimli ama KENDİ repo'suna işaret
    # eden bir URL yazabilirdi) — bu yüzden sahiplik kapısı burada AÇIKÇA ve
    # KOŞULSUZ olarak uygulanır.
    if [[ -f "$repo_file" ]]; then
        _require_owned_or_warn "$domain" "$repo_file" \
            || error "Güvenlik: ${repo_file} root-owned değil (tamper). Deploy reddedildi."
    fi

    # Güvenlik: web-yazılabilir .deploy-repo'dan gelen URL'yi ve branch'i clone'dan
    # önce doğrula (ext::/file:: git RCE + option-injection reddi).
    _deploy_validate_repo_url "$repo_url" \
        || error "Güvensiz repo URL'si reddedildi: ${repo_url} (yalnız https://, ssh://, git@host:path)"
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$branch" != -* ]] \
        || error "Geçersiz branch adı: ${branch}"

    # userinfo@ (https://user:token@host/...) REDDEDİLMİYOR (mevcut kurulumları
    # kırar, escape yolu yok) ama clone SIRASINDA argv'de görünüp YEREL 'ps aux'
    # ile okunabileceğinden net uyarı veriliyor.
    if _deploy_url_has_userinfo "$repo_url"; then
        warn "Repo URL'sinde userinfo (kullanıcı:token@) var — clone sırasında 'ps aux' ile YEREL kullanıcılar görebilir. SSH anahtarı/credential-helper kullanmayı değerlendirin."
    fi

    # 1. Clone
    step "1/9" "Git clone (branch: ${branch})..."
    mkdir -p "${base}/releases"
    # GÜVENLİK (bkz. rapor K2 — root RCE): 'release_dir' öngörülebilir bir ada
    # sahipti (yalnız tarih/saat; artık rastgele sonekli, bkz. _deploy_rand_suffix)
    # ve ARADA [[ -e ]]/[[ -L ]] kontrolü YOKTU. releases/ web_user tarafından
    # yazılabilir (750 web_user:web_user, FPM open_basedir içinde) — saldırgan
    # tahmin ettiği/floodladığı bir release id'sine ROOT'un YAZABİLECEĞİ ama
    # web_user'ın YAZAMAYACAĞI, VAR OLAN BOŞ bir dizine (ör.
    # /usr/local/srvctl/plugins/<ad> ya da /var/spool/cron/crontabs) sembolik
    # bağlantı koyabiliyordu: 'git clone' symlink'i ÇÖZER ve hedef boşsa
    # KLONLAR (git yalnız "var ve boş değil" durumunda reddeder — dangling
    # symlink'te EEXIST ile başarısız olur, doğrulandı) → ROOT olarak çalışan
    # bu 'git clone' saldırganın deposunu o ayrıcalıklı konuma yazardı (ör.
    # plugins/<ad>/.enabled + main.sh → her srvctl çağrısında ROOT olarak
    # source edilir, bkz. lib/plugin.sh:load_plugins).
    # Aşağıdaki 'mkdir' (parolasız, -p YOK) ATOMİKTİR: hedefte HERHANGİ bir şey
    # (symlink — dangling ya da değil —, dosya, dizin) zaten varsa mkdir(2)
    # EEXIST ile başarısız olur; TOCTOU penceresi YOK. Bu tek satır saldırıyı
    # RCE'den fail-closed bir deploy hatasına indirger.
    mkdir -- "$release_dir" \
        || error "Release dizini oluşturulamadı (zaten var — sembolik bağlantı saldırısı olabilir): ${release_dir}"
    GIT_ALLOW_PROTOCOL='https:ssh:git' git clone --depth 1 --branch "${branch}" -- "${repo_url}" "${release_dir}" 2>/dev/null \
        || error "Git clone başarısız. Repo URL'si ve branch'i kontrol edin."
    success "Clone tamamlandı"

    # .git kaldırma: '.git/config' release içinde kalırsa web_user'a chown
    # edilir ve open_basedir '/releases/' içerdiğinden bir dosya-okuma açığı
    # gömülü token'ı ifşa edebilir. nginx 'location ~ /\.' tek katmanlı
    # savunma — bu ikinci katman. Varsayılan KALDIR; '.srvctl-meta'
    # KEEP_GIT=true ile devre dışı bırakılabilir.
    if [[ "$keep_git" == "true" ]]; then
        warn ".git dizini KORUNDU (KEEP_GIT=true) — .git/config token/kimlik içerebilir, dosya-okuma açıklarına karşı korumasız"
    else
        rm -rf "${release_dir}/.git"
    fi

    # Framework doğrulama: SADECE raporlama. İzin/izolasyon kararları
    # operatörün beyanına (${FRAMEWORK}) göre alınır, repo içeriğine göre
    # DEĞİL.
    local detected_fw; detected_fw=$(_deploy_detect_framework "$release_dir")
    if [[ "$detected_fw" != "$FRAMEWORK" ]]; then
        case "$FRAMEWORK" in
            laravel) warn "meta 'laravel' diyor ama repoda 'artisan' yok (tespit: ${detected_fw}) — 'srvctl domain add --framework' beyanını kontrol edin" ;;
            ci4)     warn "meta 'ci4' diyor ama repoda 'spark' yok (tespit: ${detected_fw}) — 'srvctl domain add --framework' beyanını kontrol edin" ;;
            symfony) warn "meta 'symfony' diyor ama repoda 'bin/console' yok (tespit: ${detected_fw}) — 'srvctl domain add --framework' beyanını kontrol edin" ;;
        esac
    fi

    # 2. Shared dosyalar — composer'dan ÖNCE: Laravel'in post-autoload-dump
    #    (package:discover) ve Symfony'nin auto-scripts (cache:clear) adımları
    #    .env olmadan patlar; Laravel'in composer post-autoload-dump'ı ayrıca
    #    bootstrap/cache/packages.php üretir — o yüzden bootstrap-cache da
    #    composer'dan ÖNCE bağlanmalı.
    step "2/9" "Shared dosyalar bağlanıyor (framework: ${FRAMEWORK})..."
    mkdir -p "${shared_dir}"
    if [[ -e "${shared_dir}/.env" ]] && _deploy_assert_safe_shared "${shared_dir}/.env"; then
        ln -sf "../../shared/.env" "${release_dir}/.env"
        success ".env bağlandı"
    elif [[ -L "${shared_dir}/.env" ]]; then
        warn "shared/.env bir symlink — güvenlik nedeniyle atlandı"
    else
        warn ".env bulunamadı: ${shared_dir}/.env"
    fi

    local pair rel_path shared_subdir rc
    for pair in "${shared_pairs[@]}"; do
        rel_path="${pair%%:*}"; shared_subdir="${pair#*:}"
        rc=0
        _deploy_link_shared "$release_dir" "$shared_dir" "$rel_path" "$shared_subdir" || rc=$?
        if [[ "$rc" == "0" ]]; then
            success "shared/${shared_subdir} bağlandı"
        fi
        # rc=2: release/shared'de bu artefakt yok (ör. ilk deploy'dan önce
        # domain.sh henüz shared/ altını hazırlamamış) — sessizce atlanır.
    done

    # 3. İzinler — composer/hook'lardan ÖNCE (T3): yetki düşürülmüş süreçlerin
    #    release dizinine yazabilmesi için sahiplik burada devredilir.
    #    chown -Rh: symlink'in KENDİSİNİ sahiplen, hedefini değil — aksi halde
    #    release/.env üzerinden shared/.env'in sahipliği değişirdi.
    step "3/9" "İzinler ayarlanıyor..."
    chown -Rh "${web_user}:${web_user}" "${release_dir}"
    chmod -R 750 "${release_dir}"
    # ACL — www-data (nginx) release içeriğini okuyabilsin (bkz. rapor Y5).
    # 'srvctl domain add' yalnız İLK KURULUMDAKİ gerçek public_html'e setfacl
    # uyguluyor (lib/domain.sh:_domain_fs_plan) — o an public_html henüz düz
    # bir dizin. İLK 'srvctl deploy'dan SONRA public_html bir SYMLINK'e
    # dönüşür ve hedefi (releases/<id>) her seferinde YENİ, yalnız
    # web_user:web_user 750 olan bir dizindir; www-data'nın buna okuma hakkı
    # YOKTUR. vhost.conf.tpl'in statik dosya bloğunda 'try_files' YOK — nginx
    # css/js/img dosyalarını DOĞRUDAN açmaya çalışır → EACCES → 403 (TÜM statik
    # varlıklar). '/' istekleri 'index.php'ye düşüp 200 döndüğünden
    # _health_probe bunu YAKALAMAZ ("sağlıklı" der) — operatör bunu genelde
    # 'chmod -R 755' ile "çözer", bu da release içeriğini KOMŞU kiracıların
    # web_* kullanıcılarına okunur hale getirir (izolasyon ihlali). Doğru çözüm:
    # her deploy'da release'e de aynı ACL'i (+ varsayılan ACL, sonradan
    # oluşan dosyalar için) uygulamak.
    if command -v setfacl &>/dev/null; then
        setfacl -R -m "u:www-data:rx" "${release_dir}" 2>/dev/null \
            || warn "setfacl release'e uygulanamadı — nginx statik dosyaları (css/js/img) 403 dönebilir"
        setfacl -R -d -m "u:www-data:rx" "${release_dir}" 2>/dev/null || true
    else
        warn "'setfacl' bulunamadı (acl paketi kurulu değil) — nginx statik dosyaları 403 dönebilir. Kurulum: apt install acl"
    fi
    for pair in "${shared_pairs[@]}"; do
        shared_subdir="${pair#*:}"
        if [[ -d "${shared_dir}/${shared_subdir}" ]]; then
            _deploy_assert_safe_shared "${shared_dir}/${shared_subdir}" \
                || error "shared/${shared_subdir} bir symlink — deploy reddedildi (chown -R yetki-yükseltme riski)"
            chmod -R 770 "${shared_dir}/${shared_subdir}"
            chown -Rh "${web_user}:${web_user}" "${shared_dir}/${shared_subdir}"
        fi
    done
    success "İzinler ayarlandı"

    # 4. Composer — web_user olarak (root DEĞİL). composer.json repodan gelir;
    #    root çalıştırmak kötü niyetli bir lifecycle script'ine root verirdi.
    step "4/9" "Composer install (kullanıcı: ${web_user})..."
    if [[ -f "${release_dir}/composer.json" ]]; then
        command -v composer &>/dev/null \
            || error "composer.json var ama composer kurulu değil — deploy reddedildi (vendor/ olmadan release canlıya alınamaz)"
        local composer_home="${base}/tmp/composer"
        mkdir -p "${composer_home}/cache"
        chown -R "${web_user}:${web_user}" "${composer_home}"
        _deploy_privdrop "$web_user" \
            env HOME="$composer_home" COMPOSER_HOME="$composer_home" \
                COMPOSER_CACHE_DIR="${composer_home}/cache" \
            composer install --working-dir="${release_dir}" \
                --no-dev --optimize-autoloader --no-interaction --no-progress \
            || error "Composer install başarısız — deploy durduruldu (release canlıya alınmadı: ${release_dir})"
        [[ -f "${release_dir}/vendor/autoload.php" ]] \
            || error "Composer çalıştı ama vendor/autoload.php üretilmedi — deploy durduruldu"
        success "Composer paketleri yüklendi"
    else
        info "composer.json yok — atlanıyor"
    fi

    # 5. Pre-deploy hook — web_user olarak (shared/hooks/ web-yazılabilir)
    step "5/9" "Pre-deploy hook..."
    _run_hook "${shared_dir}/hooks/pre-deploy.sh" "${release_dir}" "${domain}" "${web_user}"

    # 6. Framework build (cache/asset) — switch'ten ÖNCE, web_user olarak.
    step "6/9" "Framework build (${FRAMEWORK})..."
    _deploy_build "$FRAMEWORK" "$release_dir" "$web_user" "$php_bin"

    # DRY-RUN: burada dur
    if [[ "$dry_run" == "1" ]]; then
        echo ""
        warn "DRY-RUN: Release hazırlandı ama canlıya geçirilmedi:"
        echo "    ${release_dir}"
        rm -rf "${release_dir}"
        info "Gerçek deploy için --dry-run olmadan çalıştırın."
        return
    fi

    # 7. Atomic switch
    step "7/9" "Atomic switch (zero-downtime)..."
    if [[ -d "$public_dir" && ! -L "$public_dir" ]]; then
        mv "$public_dir" "${base}/public_html.bak.$(date +%s)" 2>/dev/null || true
    fi
    local rel_id; rel_id=$(basename "${release_dir}")
    local new_link="releases/${rel_id}"
    [[ -d "${release_dir}/public" ]] && new_link="releases/${rel_id}/public"
    # 'current': worker/scheduler systemd unit'lerinin WorkingDirectory'si
    # (lib/domain.sh:_domain_working_dir → ${base}/current) HER ZAMAN release
    # KÖKÜNE bakar, public/ DEĞİL — artisan/spark/bin-console orada yaşar.
    # WorkingDirectory systemd tarafından süreç başlarken BİR KEZ çözülür;
    # bu yüzden her deploy'da hedefi güncellenmeli (aksi halde worker/
    # scheduler unit'leri hiç başlamaz — bkz. koordinatör notu).
    local current_link="releases/${rel_id}"
    # Sıra: ÖNCE public_html (yüksek frekanslı web trafiği), SONRA current
    # (düşük frekanslı worker/scheduler). İki 'mv -T' arasındaki mikrosaniyelik
    # pencerede 'current' hâlâ ESKİ (kanıtlanmış çalışan) release'e bakar —
    # zararsız. Ters sıra olsaydı (current önce), aynı pencerede bir scheduler
    # timer tick'i migration'dan (adım 8) ÖNCE YENİ kodu ESKİ şemaya karşı
    # çalıştırabilirdi (daha riskli). Ayrıca zaten-çalışan worker'lar
    # WorkingDirectory'yi yalnız süreç başında çözer; aralarındaki fark onları
    # HİÇ etkilemez — restart'ı biz adım 9'da current tamamen yerleştikten
    # SONRA açıkça tetikliyoruz.
    _deploy_link_current "$base" "$new_link" \
        || error "Atomic switch başarısız: ${public_dir}"
    _deploy_link_current "$base" "$current_link" "current" \
        || error "Atomic switch (current) başarısız: ${base}/current (worker/scheduler WorkingDirectory'si)"
    _deploy_reload_fpm "$php_version"
    success "Atomic switch tamamlandı"

    # 8. Migration — OPT-IN (KULLANICI KARARI, varsayılan kapalı). Switch'ten
    #    SONRA, sağlık kontrolünden ÖNCE çalışır: yeni kod eski şemayla
    #    çalışmaya çalışmak (switch'ten önce migrate) yerine, yeni kod +
    #    yeni şema birlikte devreye girer (framework'lerin migration'ları
    #    zaten "yeni kodun beklediği şema" varsayımıyla yazılır). Health
    #    check'ten ÖNCE olması gerekir ki migration'ın DB'ye ekleyebileceği
    #    gecikme/kilit sağlık probe'unu yanıltmasın.
    #    BAŞARISIZLIKTA KODU OTOMATİK GERİ ALMIYORUZ: rollback yalnız kodu
    #    geri alır, şemayı almaz; yarım kalmış bir migration + geri alınmış
    #    kod = sessiz veri bozulması. Bunun yerine net 'error' + manuel
    #    müdahale talimatı.
    step "8/9" "Migration..."
    local migrated_this_deploy=false
    if [[ "$run_migrations" == "true" ]]; then
        case "$FRAMEWORK" in
            laravel)
                if [[ -f "${release_dir}/artisan" ]]; then
                    if _deploy_privdrop "$web_user" env HOME="$release_dir" "$php_bin" "${release_dir}/artisan" migrate --force --no-interaction; then
                        migrated_this_deploy=true
                        success "Migration tamamlandı (artisan migrate)"
                    else
                        _deploy_notify "Migration BAŞARISIZ: ${domain}" "artisan migrate başarısız. Kod ZATEN canlıda, KOD OTOMATİK GERİ ALINMADI. Release: ${rel_id}" "critical"
                        error "Migration başarısız (artisan migrate) — KOD OTOMATİK GERİ ALINMADI (şema yarım kalmış olabilir). Manuel müdahale: (1) hatayı inceleyin, (2) düzeltip migration'ı tekrar deneyin ya da (3) DBA ile kontrollü geri alma yapın. Release: ${release_dir}"
                    fi
                else
                    warn "RUN_MIGRATIONS açık ama artisan yok — migration atlandı"
                fi
                ;;
            ci4)
                if [[ -f "${release_dir}/spark" ]]; then
                    if _deploy_privdrop "$web_user" env HOME="$release_dir" "$php_bin" "${release_dir}/spark" migrate; then
                        migrated_this_deploy=true
                        success "Migration tamamlandı (spark migrate)"
                    else
                        _deploy_notify "Migration BAŞARISIZ: ${domain}" "spark migrate başarısız. Kod ZATEN canlıda, KOD OTOMATİK GERİ ALINMADI. Release: ${rel_id}" "critical"
                        error "Migration başarısız (spark migrate) — KOD OTOMATİK GERİ ALINMADI. Manuel müdahale gerekli. Release: ${release_dir}"
                    fi
                else
                    warn "RUN_MIGRATIONS açık ama spark yok — migration atlandı"
                fi
                ;;
            symfony)
                if [[ -f "${release_dir}/bin/console" ]]; then
                    if _deploy_privdrop "$web_user" env HOME="$release_dir" "$php_bin" "${release_dir}/bin/console" doctrine:migrations:migrate --no-interaction; then
                        migrated_this_deploy=true
                        success "Migration tamamlandı (doctrine:migrations:migrate)"
                    else
                        _deploy_notify "Migration BAŞARISIZ: ${domain}" "doctrine:migrations:migrate başarısız. Kod ZATEN canlıda, KOD OTOMATİK GERİ ALINMADI. Release: ${rel_id}" "critical"
                        error "Migration başarısız (doctrine:migrations:migrate) — KOD OTOMATİK GERİ ALINMADI. Manuel müdahale gerekli. Release: ${release_dir}"
                    fi
                else
                    warn "RUN_MIGRATIONS açık ama bin/console yok — migration atlandı"
                fi
                ;;
        esac
    else
        info "Migration atlandı (RUN_MIGRATIONS kapalı — global: ${DEPLOY_RUN_MIGRATIONS})"
    fi

    # 9. Health check + gerekirse otomatik rollback
    step "9/9" "Sağlık kontrolü..."
    local code; code=$(_health_probe "$domain")
    if _deploy_health_ok "$code"; then
        success "Sağlık kontrolü OK (HTTP ${code})"
        _run_hook "${shared_dir}/hooks/post-deploy.sh" "${release_dir}" "${domain}" "${web_user}"
        _deploy_restart_workers "$domain"
    else
        if [[ "$migrated_this_deploy" == "true" ]]; then
            # Bu deploy'da migration ÇALIŞTI ve muhtemelen şemayı ileri
            # taşıdı. Kodu otomatik geri almak = ileri migrate edilmiş şema +
            # eski kod = sessiz veri bozulması riski (bkz. adım 8 gerekçesi).
            # Bu yüzden burada OTOMATİK ROLLBACK YAPMIYORUZ.
            _deploy_notify "Deploy Sağlıksız (migration sonrası): ${domain}" "HTTP ${code}. Bu deploy'da migration çalıştı — KOD OTOMATİK GERİ ALINMADI (şema+kod tutarlılığı için). Release: ${rel_id}" "critical"
            error "Sağlık kontrolü BAŞARISIZ (HTTP ${code}) ve bu deploy'da migration çalıştı — OTOMATİK ROLLBACK YAPILMADI. Manuel müdahale gerekli: şema/kod uyumunu değerlendirip ya ileri doğru düzeltin ya da DBA ile kontrollü geri alma yapın. Release: ${release_dir}"
        fi
        warn "Sağlık kontrolü BAŞARISIZ (HTTP ${code}) — otomatik rollback!"
        # prev_rel_link GÖRELİ olmalı. Eskiden burada mutlak yol yazılıyordu
        # ($prev_target) → chroot'lu FPM çözemiyordu; yani kurtarma yolu da
        # bozuktu. prev_rel_link boşsa (releases/ dışı hedef) rollback yapma.
        if [[ -n "$prev_rel_link" && -d "$prev_target" ]]; then
            _deploy_link_current "$base" "$prev_rel_link" \
                || error "Rollback symlink'i kurulamadı. Manuel müdahale: ${public_dir}"
            # 'current'ı da geri al — aksi halde adım 7'de zaten YENİ (sağlıksız)
            # release'e çevrilmiş olan current, bir sonraki scheduler timer
            # tick'inde YENİ (bozuk) kodu çalıştırmaya devam ederdi. Uzun süredir
            # çalışan worker'lar bundan etkilenmez (WorkingDirectory'yi yalnız
            # başlangıçta çözerler ve bu deploy'da HİÇ restart edilmediler —
            # restart yalnız adım 9'un BAŞARI dalında tetiklenir); bu yüzden
            # burada _deploy_restart_workers ÇAĞRILMIYOR (zaten eski release'i
            # çalıştırıyorlar, dokunmaya gerek yok).
            if [[ -n "$prev_root_link" ]]; then
                _deploy_link_current "$base" "$prev_root_link" "current" \
                    || error "Rollback (current) symlink'i kurulamadı. Manuel müdahale: ${base}/current"
            fi
            _deploy_reload_fpm "$php_version"
            rm -rf "${release_dir}"
            _deploy_notify "Deploy Otomatik Geri Alındı: ${domain}" "Branch: ${branch}. Sağlıksız release (HTTP ${code}) geri alındı. Geri dönülen: ${prev_rel_link}" "critical"
            error "Deploy geri alındı. Önceki sürüm geri yüklendi: ${prev_rel_link}"
        else
            # Başarısız release'i diskte bırakma — aksi halde her başarısız
            # webhook deploy'u kalıcı olarak birikirdi.
            rm -rf "${release_dir}"
            _deploy_notify "Deploy BAŞARISIZ: ${domain}" "Branch: ${branch}. Sağlık kontrolü başarısız (HTTP ${code}) ve geri alınacak önceki sürüm yok." "critical"
            error "Geri alınacak önceki sürüm yok (release temizlendi). Sağlık: HTTP ${code}"
        fi
    fi

    # Eski release temizliği
    local prune_out
    prune_out=$(_deploy_prune "$domain" "${DEPLOY_KEEP_RELEASES}" apply 2>&1)
    [[ -n "$prune_out" ]] && echo "$prune_out"

    header "✅ Deploy Tamamlandı: ${domain}"
    echo "  Release:        $(basename "${release_dir}")"
    echo "  Branch:         ${branch}"
    echo "  Framework:      ${FRAMEWORK}"
    echo "  public_html →   $(readlink -f "$public_dir" 2>/dev/null)"
    echo "  HTTP:           ${code}"
    echo ""
    log_action "DEPLOY: ${domain} (branch=${branch}, framework=${FRAMEWORK}, http=${code}, release=$(basename "${release_dir}"))"
    _deploy_notify "Deploy Başarılı: ${domain}" "Branch: ${branch}
Framework: ${FRAMEWORK}
Release: $(basename "${release_dir}")
HTTP: ${code}
${prune_out:-Eski release temizliği: silinecek bir şey yoktu.}" "success"
}

# ───────────────────────────────────────────────────────────────
#  deploy rollback <domain>  /  srvctl rollback <domain>
# ───────────────────────────────────────────────────────────────
_deploy_rollback() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && error "Kullanım: srvctl rollback <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    _deploy_lock "$domain"

    local base="${WEB_ROOT}/${domain}"
    local public_dir="${base}/public_html"
    local releases="${base}/releases"
    [[ -d "$releases" ]] || error "Release dizini yok: ${releases}"

    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")

    local current_real=""; [[ -L "$public_dir" ]] && current_real=$(readlink -f "$public_dir")
    local current_rel="${current_real%/public}"

    # Mevcut release'den bir öncekini bul. GÜVENLİK (bkz. rapor Y2/H4):
    # ESKİDEN burada 'ls -t' (mtime) parse ediliyordu — releases/ web_user
    # tarafından yazılabilir (FPM open_basedir içinde), ele geçirilmiş bir
    # uygulama 'touch()' ile mtime sırasını bozup rollback'i keyfi bir
    # dizine yönlendirebilirdi (yetki kazanımı yok, zaten web_user, ama
    # "temiz sürüme dön" operasyonunu etkisizleştirir). _deploy_prune_one bunu
    # zaten find+sort-r+whitelist ile çözmüştü; burası (ve _deploy_list) AYNI
    # TEK kaynağı (_deploy_release_ids) kullanır.
    local prev="" found=0
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        local full="${releases}/${r}"
        if [[ "$found" == "1" ]]; then prev="$full"; break; fi
        [[ "$full" == "$current_rel" ]] && found=1
    done < <(_deploy_release_ids "$releases")

    if [[ -z "$prev" ]]; then
        # current_rel geçerli release id listesinde bulunamadı (ör.
        # public_html srvctl dışı bir hedefe işaret ediyor, ya da hiç
        # deploy edilmemiş) — mtime TAHMİNİ YOK (Y2/H4); bunun yerine
        # listedeki EN YENİ geçerli release denenir.
        local newest; newest=$(_deploy_release_ids "$releases" | head -n1)
        [[ -n "$newest" ]] && prev="${releases}/${newest}"
    fi
    [[ -n "$prev" && -d "$prev" ]] || error "Geri alınacak önceki release bulunamadı."

    header "Rollback: ${domain} → $(basename "$prev")"
    # 'rm -rf "$public_dir"' YOK: public_html symlink değil de gerçek bir dizinse
    # (srvctl dışı kurulum, elle geri yükleme) tüm site silinirdi. _deploy_link_current
    # mv -T kullanır; gerçek dizinin üzerine yazmayı reddeder.
    local prev_name; prev_name=$(basename "$prev")
    local prev_link="releases/${prev_name}"
    [[ -d "${prev}/public" ]] && prev_link="releases/${prev_name}/public"
    # 'current' (worker/scheduler WorkingDirectory'si, release KÖKÜ) da geri
    # alınmalı — aksi halde manuel rollback sonrası kod geri döner ama
    # restart edilen worker/scheduler YENİ (rollback edilen) release'de kalır.
    # Sıra: public_html (web) önce, current (worker/scheduler) sonra — bkz.
    # _deploy_run adım 7 yorumu (aynı gerekçe).
    local current_link="releases/${prev_name}"
    _deploy_link_current "$base" "$prev_link" \
        || error "Rollback symlink'i kurulamadı: ${public_dir} (gerçek dizin olabilir)"
    _deploy_link_current "$base" "$current_link" "current" \
        || error "Rollback (current) symlink'i kurulamadı: ${base}/current"
    _deploy_reload_fpm "$php_version"

    local code; code=$(_health_probe "$domain")
    if _deploy_health_ok "$code"; then
        success "Rollback başarılı: $(basename "$prev") (HTTP ${code})"
        _deploy_restart_workers "$domain"
        _deploy_notify "Manuel Rollback: ${domain}" "$(basename "$prev") sürümüne dönüldü (HTTP ${code})." "info"
    else
        warn "Rollback yapıldı ama sağlık kontrolü zayıf (HTTP ${code})"
        _deploy_notify "Manuel Rollback (zayıf sağlık): ${domain}" "$(basename "$prev") sürümüne dönüldü ama sağlık kontrolü zayıf (HTTP ${code})." "warning"
    fi
    log_action "ROLLBACK: ${domain} -> $(basename "$prev")"
}

# ───────────────────────────────────────────────────────────────
#  deploy health <domain>
# ───────────────────────────────────────────────────────────────
_deploy_health() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy health <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    local code; code=$(_health_probe "$domain")
    if _deploy_health_ok "$code"; then
        success "${domain} sağlıklı (HTTP ${code})"
    else
        error "${domain} sağlıksız (HTTP ${code})"
    fi
}

# ───────────────────────────────────────────────────────────────
#  deploy prune <domain>|--all [--keep=N] [--apply] [--include-bak]
#  Varsayılan DRY-RUN (security harden-fs konvansiyonu).
#  İç çağrı biçimi: _deploy_prune <domain> <keep> apply
# ───────────────────────────────────────────────────────────────
_deploy_prune() {
    local domain="" keep="" mode="dry" all=false include_bak=false arg
    for arg in "$@"; do
        case "$arg" in
            --apply|apply) mode="apply" ;;
            --all)         all=true ;;
            --include-bak) include_bak=true ;;
            --keep=*)      keep="${arg#--keep=}" ;;
            -*)            warn "Bilinmeyen seçenek: ${arg}" ;;
            *)
                if   [[ -z "$domain" ]]; then domain="$arg"
                elif [[ -z "$keep"   ]]; then keep="$arg"
                fi ;;
        esac
    done

    # Asla ölümcül olma: prune deploy'un SONUNDA çağrılıyor, site çoktan canlıda.
    keep="${keep:-${DEPLOY_KEEP_RELEASES:-5}}"
    if ! validate_uint "$keep" 1000 || (( keep < 2 )); then
        warn "Geçersiz keep değeri '${keep}' — 5 kullanılıyor (rollback için min 2)"
        keep=5
    fi

    # PORTATİFLİK: 'mapfile'/'readarray' bash 4+ builtin'idir, macOS'un
    # varsayılan /bin/bash'i (3.2, GPLv3 lisans engeli nedeniyle
    # yükseltilmemiş) bunu TANIMAZ ("mapfile: command not found") — bu proje
    # macOS'ta test edilir (bkz. CLAUDE.md/tests). Portatif 'while read' ile
    # doğrudan işlenir; ayrıca boş dizi durumunda '"${targets[@]}"' bash
    # 3.2'de 'set -u' altında "unbound variable" fırlatabildiğinden (bkz.
    # değişiklik geçmişi) dizi HİÇ MATERYALİZE EDİLMEZ.
    if $all; then
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            _deploy_prune_one "$d" "$keep" "$mode" "$include_bak"
        done < <(list_all_domains)
    else
        [[ -z "$domain" ]] && error "Kullanım: srvctl deploy prune <domain>|--all [--keep=N] [--apply] [--include-bak]"
        _deploy_prune_one "$domain" "$keep" "$mode" "$include_bak"
    fi
}

_deploy_prune_one() {
    local domain="$1" keep="$2" mode="$3" include_bak="$4"
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }

    local base="${WEB_ROOT}/${domain}"
    local releases="${base}/releases"
    [[ -d "$releases" && ! -L "$releases" ]] || return 0

    # KANONİK kök: canlı release 'readlink -f' ile kanonikleşiyor. WEB_ROOT'un
    # herhangi bir üst dizini symlink ise (macOS /var, ya da /var/www'yi başka
    # bir diske link'lemiş bir kurulum) kanonik-olmayan yolla karşılaştırmak
    # canlı-release korumasını SESSİZCE devre dışı bırakırdı. Her iki tarafı da
    # kanonikleştir.
    local releases_real
    releases_real=$(cd "$releases" 2>/dev/null && pwd -P) || return 0

    # ── Canlı release tespiti: çözülemezse HİÇBİR ŞEY silme (fail-closed) ──
    local current_real="" current_rel=""
    [[ -L "${base}/public_html" ]] && current_real=$(readlink -f "${base}/public_html")
    current_rel="${current_real%/public}"
    if [[ -z "$current_rel" ]]; then
        warn "${domain}: public_html çözümlenemedi — prune reddedildi (canlı release korunamaz)"
        return 0
    fi

    [[ "$mode" == "dry" ]] && echo "  ── ${domain} (dry-run; uygulamak için --apply) ──"

    # ── Aday listesi ──
    # 'ls -t' PARSE ETME: mtime'a güvenilemez. releases/ web_user tarafından
    # yazılabilir ve FPM open_basedir'ı içindedir; ele geçirilmiş bir uygulama
    # PHP touch() ile ileri tarihli sahte dizinler üretip canlı release'i
    # sıralamanın sonuna itebilirdi. Sıralama/filtreleme TEK kaynaktan
    # (_deploy_release_ids — _deploy_rollback/_deploy_list ile PAYLAŞILIR,
    # bkz. Y2/H4); desene uymayan isimler için operatöre özel uyarı burada
    # (yalnız prune'da anlamlı) ayrıca üretilir. PORTATİFLİK: 'mapfile'
    # (bash 4+) KULLANILMAZ — dizi hiç materyalize edilmez, tek geçişli
    # 'while read' ile doğrudan işlenir (bkz. _deploy_prune'daki aynı not;
    # 'sort -r' zaten TÜM find çıktısını tükettikten SONRA yazdığından, bu
    # döngü sırasında aşağıdaki 'rm -rf' ile releases/ ağacını değiştirmek
    # find'ın halihazırda tamamlanmış taramasını ETKİLEMEZ).
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _deploy_is_release_id "$name" && continue
        warn "${domain}: release adı desene uymuyor, dokunulmuyor: releases/${name}"
    done < <(find "$releases" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -r)

    local removed=0 kept=0 idx=0 id full real
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        idx=$((idx + 1))
        full="${releases_real}/${id}"

        # GUARD 1: canlı release — sırası ne olursa olsun ASLA silinmez
        if [[ "$full" == "$current_rel" || "$full" == "$current_real" ]]; then
            kept=$((kept + 1)); continue
        fi
        # GUARD 2: tutma penceresi
        if (( idx <= keep )); then
            kept=$((kept + 1)); continue
        fi
        # GUARD 3: symlink değil, gerçek dizin
        [[ -L "$full" ]] && { warn "${domain}: symlink atlandı: releases/${id}"; continue; }
        [[ -d "$full" ]] || continue
        # GUARD 4: prefix kilidi — gerçek yol releases/ altında mı?
        real=$(cd "$full" 2>/dev/null && pwd -P) || continue
        [[ "$real" == "${releases_real}/"* ]] \
            || { warn "${domain}: releases dışına çözümlendi, atlandı: ${full}"; continue; }
        # GUARD 5: kök dizinleri asla
        [[ "$real" == "$releases_real" || "$real" == "$base" || "$real" == "$WEB_ROOT" || "$real" == "/" ]] && continue

        if [[ "$mode" == "apply" ]]; then
            rm -rf -- "$real"
        else
            echo "    silinecek: releases/${id}"
        fi
        removed=$((removed + 1))
    done < <(_deploy_release_ids "$releases")

    # ── public_html.bak.* (atomic switch'in bıraktığı eski gerçek docroot) ──
    local bak
    if [[ "$include_bak" == "true" ]]; then
        while IFS= read -r bak; do
            [[ -z "$bak" ]] && continue
            [[ -L "$bak" ]] && continue
            [[ -d "$bak" ]] || continue
            if [[ "$mode" == "apply" ]]; then
                rm -rf -- "$bak"
            else
                echo "    silinecek: $(basename "$bak")"
            fi
            removed=$((removed + 1))
        done < <(find "$base" -maxdepth 1 -type d -name 'public_html.bak.*' \
                     -mtime "+${DEPLOY_PRUNE_BAK_DAYS:-7}" 2>/dev/null)
    fi

    if (( removed > 0 )); then
        if [[ "$mode" == "apply" ]]; then
            info "${domain}: ${removed} eski release silindi, ${kept} korundu (keep=${keep})"
            log_action "DEPLOY PRUNE: ${domain} (silinen=${removed}, korunan=${kept}, keep=${keep})"
        fi
    elif [[ "$mode" == "dry" ]]; then
        echo "    (silinecek bir şey yok — ${kept} release korunuyor)"
    fi
}

# ───────────────────────────────────────────────────────────────
#  deploy list <domain>
# ───────────────────────────────────────────────────────────────
_deploy_list() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy list <domain>"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    local base="${WEB_ROOT}/${domain}"
    local current_real=""; [[ -L "${base}/public_html" ]] && current_real=$(readlink -f "${base}/public_html")
    header "Release'ler: ${domain}"
    # GÜVENLİK (bkz. Y2/H4): 'ls -t' (mtime) DEĞİL — _deploy_prune_one/
    # _deploy_rollback ile PAYLAŞILAN TEK kaynak (_deploy_release_ids).
    local r full marker
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        full="${base}/releases/${r}"; marker="  "
        [[ "$current_real" == "${full}/public" || "$current_real" == "$full" ]] && marker="${GREEN}→ ${NC}"
        echo -e "  ${marker}${r}"
    done < <(_deploy_release_ids "${base}/releases")
    # Desene UYMAYAN dizinler — prune bunlara ASLA dokunmaz/saymaz (bkz. Y1);
    # operatör görsün diye ayrıca listelenir (mtime manipülasyonu/sahte dizin
    # göstergesi olabilir).
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _deploy_is_release_id "$name" && continue
        echo -e "  ${YELLOW}⚠ ${name}${NC} (desene uymuyor — prune dokunmaz, elle inceleyin)"
    done < <(find "${base}/releases" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    echo ""
}
