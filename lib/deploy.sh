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

# Switch ÖNCESİ başarısız olan bir release'i diskten kaldırır (trap'ten
# çağrılır). Guard zinciri _deploy_prune_one ile aynı disiplinde: boş değer,
# releases/ dışı yol, symlink ve kök dizinler reddedilir — trap bağlamında
# çalıştığı için buradaki bir hata sessizce yıkıcı olmamalı.
_deploy_discard_release() {
    local base="$1" rel="$2"
    [[ -n "$base" && -n "$rel" ]] || return 0
    [[ -d "$rel" && ! -L "$rel" ]] || return 0
    local releases_real rel_real
    releases_real=$(cd "${base}/releases" 2>/dev/null && pwd -P) || return 0
    rel_real=$(cd "$rel" 2>/dev/null && pwd -P) || return 0
    [[ "$rel_real" == "${releases_real}/"* ]] || return 0
    [[ "$rel_real" == "$releases_real" || "$rel_real" == "$base" || "$rel_real" == "/" ]] && return 0
    rm -rf -- "$rel_real"
    warn "Başarısız release diskten kaldırıldı: $(basename "$rel_real")"
}

# ───────────────────────────────────────────────────────────────
#  BUG C DÜZELTMESİ (gerçek VM bug'ı, koordinatör raporu, Symfony deploy'u,
#  Ubuntu 22.04): sağlık kontrolü BAŞARISIZ olduğunda VE geri dönülecek
#  gerçek bir ÖNCEKİ release YOKSA (ör. bu İLK deploy denemesiyse),
#  _deploy_run adım 7'de 'public_html'/'current' ZATEN bu (şimdi silinen)
#  release'e çevrilmişti — release silinince bu iki symlink KIRIK
#  (dangling) kalıyor, domain KALICI 404/500'e düşüyordu. VM'de ölçülen son
#  durum:
#      current      -> releases/<id>   (KIRIK symlink)
#      public_html  -> releases/<id>   (KIRIK symlink)
#      releases/    -> BOŞ
#      public_html.bak.<ts>/  (orijinal içerik BURADA duruyor, GERİ
#                              YÜKLENMİYOR)
#  Yani domain deploy ÖNCESİNDEN DAHA KÖTÜ bir durumda kalıyordu (deploy
#  öncesi çalışan bir placeholder sayfası vardı; sonrasında kalıcı kırık
#  symlink).
#
#  _deploy_run'dan AYRI bir fonksiyona ÇIKARILDI (bkz. _deploy_composer_
#  install/_deploy_build ile AYNI desen) ki tests/ gerçek git clone/health-
#  probe/systemctl OLMADAN, düz dosya sistemi fixture'larıyla bu kurtarma
#  mantığını doğrudan çağırıp test edebilsin (bkz.
#  tests/test_deploy_no_rollback_recover.sh).
#
#  BOŞLUK BULUNDU (koordinatör, HOST doğrulaması): yukarıdaki ilk sürüm
#  'public_html_backup' (bu ÇALIŞMANIN izlediği yedek) yoksa yalnız KIRIK
#  symlink'i kaldırıyordu — ama bu, 'public_html'i TAMAMEN YOK bırakıyordu
#  (ne dizin, ne symlink). pool.conf.tpl'nin 'chdir = /public_html'
#  direktifi bu yolun VAR OLMASINI ZORUNLU kılar (php-fpm config-test
#  aşamasında doğrular); yokluk 'php-switch', 'security harden-fpm',
#  'domain repair' dahil TÜM kurtarma yollarını FPM aktivasyon aşamasında
#  çökertiyordu — domain elle müdahale olmadan KURTARILAMAZ hale geliyordu.
#  Ayrıca VM'de gözlemlendi: bir ÖNCEKİ başarısız deploy'un bıraktığı
#  'public_html.bak.<ts>' diskte DURUYORDU ama bu ÇALIŞMANIN kendi
#  'public_html_backup' değişkeni onu bilmiyordu (yalnız AYNI çalışmada
#  üretileni izliyordu) — o içerik görmezden geliniyordu.
#
#  Karar (ÜÇ kademeli, sırayla dene, ilk başarılı olan kazanır):
#   1) 'public_html_backup' (adım 7'nin BU çalışmada ürettiği '.bak' yolu)
#      varsa GERİ YÜKLE — en güvenilir kaynak (bu deploy'un başında
#      public_html'in KESİN olarak ne olduğunu bilir).
#   2) Yoksa, base'teki EN YENİ 'public_html.bak.*' dizinini (varsa, ÖNCEKİ
#      bir başarısız deploy'dan kalmış olabilir) geri yükle. Bu içerik
#      domain'e AİTTİR ve kaybı GERİ ALINAMAZ; bayat olma riski, kalıcı
#      404/500 + TÜM kurtarma komutlarının çökmesi riskinden EHVENDİR.
#      Hangi yedeğin ve ne zamanki olduğu operatöre AÇIKÇA söylenir (warn).
#      Epoch sırası dizin ADINDAN (mtime'DAN DEĞİL) okunur: release id'lerin
#      aksine (bkz. _deploy_is_release_id yorumu — releases/ web_user
#      tarafından yazılabilir 750'dir) base/'in kendisi 'root:root 751'dir
#      (T1 fs-ownership modeli) — web_user base İÇİNE YENİ bir '.bak.<epoch>'
#      dizini YARATAMAZ, bu yüzden dizin adındaki epoch GÜVENİLİRDİR.
#   3) İkisi de yoksa (hiç yedek bulunamadı) BOŞ bir 'public_html' dizini
#      OLUŞTUR (doğru sahiplik/izin + ACL ile) — bu, pool.conf.tpl'nin
#      'chdir' invariant'ını GARANTİ eder ve domaini en azından
#      YÖNETİLEBİLİR (php-switch/harden-fpm/repair çalışabilir) bırakır.
#
#  'current' İÇİN AYRI bir yedek YOKTUR (ilk deploy'dan önce 'current' hiç
#  VAR OLMAZ — bkz. lib/domain.sh:_domain_working_dir, yalnız bir YOL
#  üretir, dosya/symlink OLUŞTURMAZ) — systemd WorkingDirectory'si için
#  'current'ın VAR OLMASI ZORUNLU DEĞİLDİR (worker/scheduler unit'i yoksa
#  hiç okunmaz); bu yüzden 'current' için tek doğru hareket, kırıksa
#  KALDIRMAKTIR — public_html'deki gibi bir 'chdir' invariant'ı YOKTUR.
#
#  PREDİKAT DEĞİL — yan etkili bir düzeltme adımıdır, exit ETMEZ (çağıran
#  _deploy_run kendi error()'unu ayrıca çağırır). FONKSİYON HER ZAMAN
#  KOŞULSUZ 'return 0' ile biter (bkz. aşağıdaki yorum — dosya-geneli kural:
#  '[[ ]] && cmd' bir ifadenin SONUCU olarak kullanıldığında koşul yanlışsa
#  TÜM ifade başarısız sayılır; bu fonksiyon 'set -e' altında çıplak bir
#  ifade olarak çağrılır, yanlışlıkla 1 dönerse TÜM deploy betiği SESSİZCE
#  sonlanırdı — bkz. K2/H6 yorumları).
# ───────────────────────────────────────────────────────────────
_deploy_no_rollback_recover() {
    local base="$1" public_dir="$2" public_html_backup="${3:-}" web_user="${4:-}"

    # 'current' public_html kararından BAĞIMSIZDIR — en başta hallet.
    if [[ -L "${base}/current" ]]; then
        rm -f "${base}/current"
    fi

    # 1) Bu ÇALIŞMANIN izlediği yedek.
    if [[ -n "$public_html_backup" && -d "$public_html_backup" ]]; then
        rm -f "$public_dir"
        mv "$public_html_backup" "$public_dir"
        info "public_html deploy ÖNCESİNDEKİ (placeholder) haline geri yüklendi: ${public_html_backup}"
        return 0
    fi

    # Kırık (dangling) symlink varsa kaldır — 2/3. kademeye geçmeden önce.
    if [[ -L "$public_dir" ]]; then
        rm -f "$public_dir"
        warn "public_html KIRIK (dangling) symlink'ti — kaldırıldı (bu çalışmanın izlediği bir yedek yoktu)"
    fi

    # 2) Diskteki EN YENİ 'public_html.bak.*' (ÖNCEKİ bir başarısız
    #    deploy'dan kalmış olabilir — bkz. yukarıdaki BOŞLUK notu).
    if [[ ! -e "$public_dir" ]]; then
        local newest_epoch="" newest_bak="" epoch
        while IFS= read -r epoch; do
            [[ -z "$epoch" ]] && continue
            newest_epoch="$epoch"
        done < <(find "$base" -maxdepth 1 -type d -name 'public_html.bak.*' 2>/dev/null \
                     | sed 's#.*/public_html\.bak\.##' \
                     | grep -E '^[0-9]+$' \
                     | sort -n)
        if [[ -n "$newest_epoch" ]]; then
            newest_bak="${base}/public_html.bak.${newest_epoch}"
            if [[ -d "$newest_bak" && ! -L "$newest_bak" ]]; then
                local bak_human
                bak_human=$(date -r "$newest_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || date -d "@${newest_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || echo "epoch ${newest_epoch}")
                mv "$newest_bak" "$public_dir"
                warn "public_html YOKTU — diskte bulunan ÖNCEKİ bir yedek geri yüklendi: $(basename "$newest_bak") (tarih: ${bak_human}). Bu içerik BAYAT olabilir, kontrol edin."
            fi
        fi
    fi

    # 3) Hâlâ yoksa (hiç yedek bulunamadı): BOŞ bir public_html oluştur —
    #    php-fpm pool'unun 'chdir = /public_html' invariant'ı bu yolun VAR
    #    OLMASINI ZORUNLU kılar (yoksa config-test çöker, TÜM kurtarma
    #    komutları — php-switch/harden-fpm/repair — FPM aktivasyonunda
    #    başarısız olur). Sahiplik/izin komşu release/.bak dizinleriyle
    #    TUTARLI (web_user:web_user 750 + www-data ACL, bkz. adım 3 —
    #    _deploy_run'daki İzinler bloğu).
    if [[ ! -e "$public_dir" ]]; then
        mkdir -p "$public_dir"
        if [[ -n "$web_user" ]] && id "$web_user" &>/dev/null; then
            chown "${web_user}:${web_user}" "$public_dir" 2>/dev/null || true
        fi
        chmod 750 "$public_dir" 2>/dev/null || true
        if command -v setfacl &>/dev/null; then
            setfacl -m "u:www-data:rx" "$public_dir" 2>/dev/null || true
            setfacl -d -m "u:www-data:rx" "$public_dir" 2>/dev/null || true
        fi
        warn "public_html YOKTU ve geri yüklenecek bir yedek bulunamadı — BOŞ bir public_html oluşturuldu (PHP-FPM 'chdir' invariant'ı için ZORUNLU; aksi halde domain php-switch/harden-fpm/repair dahil HİÇBİR komutla kurtarılamaz)."
    fi

    return 0
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

# PREDİKAT (0=operatör framework'ü AÇIKÇA beyan etmiş VE bu beyan
# 'expected' ile eşleşiyor; 1=beyan yok/okunamıyor/farklı). lib/domain.sh'ın
# '_domain_framework_declared' KONTRATINI kullanır (aynı çapraz-modül,
# fail-soft desen — bkz. _deploy_read_framework yukarısı): O fonksiyon
# "beyan yok" ile "beyan=ci4" durumlarını AYIRT EDER (ikisinde de
# _deploy_read_framework/_domain_read_framework 'ci4' döndürür — bu yüzden
# bu ayrım İÇİN AYRI bir okuyucu şart).
#
# GERÇEK VM BUG'I (BUG B, koordinatör raporu, Symfony deploy'u): domain
# '--framework=symfony' ile AÇIKÇA kurulmuştu ama composer/build zinciri
# kırıldığından release'de 'bin/console' YOKTU; _deploy_build bunu sadece
# 'info' ile atlıyordu — kırık bir framework build'i "framework'süz normal
# bir PHP app" ile AYIRT EDİLEMİYORDU, deploy SESSİZCE "başarılı" görünüyordu
# (health probe 200/302 dönerse). _deploy_build artık bu predikatı kullanıp
# YALNIZ AÇIKÇA beyan edilmiş bir framework'ün entry dosyası eksikse
# error() ile durur; beyan yoksa (varsayılan/ci4'e düşülmüş) ESKİ yumuşak
# davranış (info+atla) KORUNUR — çünkü o durumda bunun gerçekten kırık bir
# framework mi yoksa framework KULLANMAYAN sıradan bir PHP uygulaması mı
# olduğunu BİLEMEYİZ (bkz. dosya-geneli kural: bir güvenlik/doğrulama
# kararını SIKILAŞTIRMAK AÇIK BEYAN ister, "beyan yok/okunamadı" HER ZAMAN
# yumuşak/varsayılan tarafa düşer).
_deploy_framework_declared() {
    local domain="$1" expected="$2"
    local declared=""
    if source "${SRVCTL_ROOT}/lib/domain.sh" 2>/dev/null && command -v _domain_framework_declared &>/dev/null; then
        declared=$(_domain_framework_declared "$domain" 2>/dev/null) || declared=""
    fi
    [[ -n "$declared" && "$declared" == "$expected" ]]
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

# ───────────────────────────────────────────────────────────────
#  shared/.env koruması ve mükerrer-anahtar teşhisi — GERÇEK VM BUG'I
#  (koordinatör raporu, symfony/demo + PHP 8.4, tam commit'lenmiş repo,
#  Ubuntu 22.04):
#
#      [4/9] Composer install ...
#      Script cache:clear returned with error code 255
#      !! Uncaught Error: Class "Symfony\Bundle\DebugBundle\DebugBundle" not found
#      ✗ Composer install başarısız — deploy durduruldu
#
#  Kök neden ESKİDEN release/.env'in shared/.env'e SYMLINK olmasıydı (aşağı
#  bkz. _deploy_run adım 2) — composer/symfony-flex'in "henüz uygulanmamış"
#  sandığı bir recipe .env'e YAZINCA (flex'in configurator adımı, KENDİ
#  başına ZARARSIZ bir davranış) bu yazı SYMLINK ÜZERİNDEN doğrudan KALICI
#  shared/.env'e SIZIYORDU:
#      ###> symfony/framework-bundle ###
#      APP_ENV=dev
#      APP_SECRET=
#      ###< symfony/framework-bundle ###
#  Dotenv (Symfony/Laravel) dosya İÇİNDE SON tanımın KAZANDIĞI kurala göre
#  çalıştığından, bu blok dosyanın SONUNA eklenince ÜRETİMDE GEÇERLİ olan
#  değerler 'APP_ENV=dev' ve BOŞ 'APP_SECRET' oluyordu — KALICI (shared/
#  deploy'lar arası yaşar), her SONRAKİ deploy bozuk dosyayı DEVRALIYORDU.
#  APP_ENV=dev üretimde profiler/web-debug-toolbar'ı VE tam stack trace'leri
#  (dosya yolları, sorgu detayları) açığa çıkarır; boş APP_SECRET CSRF token
#  üretimi/imzalı URI'ler/"remember me" çerezleri için kullanılan anahtarın
#  BOŞ olması demektir — SESSİZCE, hiçbir uyarı ÜRETMEDEN.
# ───────────────────────────────────────────────────────────────

# shared/.env içinde MÜKERRER (aynı KEY= birden fazla kez) anahtar var mı?
# Varsa HER biri için 'KEY:satır1,satır2,...' biçiminde bir satır YAZAR
# (yorum '#' ve boş satırlar hariç). GNU awk'a ÖZGÜ 3-argümanlı match()
# KULLANILMAZ (macOS'un /usr/bin/awk'ında — one-true-awk — YOK; bkz.
# _deploy_composer_php_constraint'in AYNI kısıtı) — split+gsub ile portable
# yazılmıştır.
_deploy_env_duplicate_keys() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) next
            n = split(line, parts, "=")
            key = parts[1]
            gsub(/[[:space:]]+$/, "", key)
            count[key]++
            if (lines[key] == "") { lines[key] = NR } else { lines[key] = lines[key] "," NR }
        }
        END {
            for (k in count) if (count[k] > 1) print k ":" lines[k]
        }
    ' "$env_file" 2>/dev/null
}

# Bir .env anahtarı GÜVENLİK-KRİTİK mi? (mükerrer olduğunda operatöre
# ESKALASYON edilir — koordinatörün özellikle adlandırdığı APP_ENV/
# APP_DEBUG/APP_SECRET dahil, makul bir genelleme ile).
_deploy_env_key_is_critical() {
    case "$1" in
        APP_ENV|APP_DEBUG|APP_SECRET|APP_KEY|DB_PASSWORD|DB_PASS|REDIS_PASSWORD|REDIS_PASS|JWT_SECRET_KEY|JWT_PASSPHRASE)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Bir .env anahtarının DEĞERİ log/uyarı çıktısına yazılabilir mi? (0=YAZMA,
# yalnız anahtar adı+satır numarası göster). PAROLA/SIR ASLA mesaja
# konulmaz (bkz. _deploy_notify yorumu — AYNI disiplin). APP_ENV/APP_DEBUG
# gibi bayraklar SIR DEĞİLDİR (yalnız prod/dev, true/false) — bunların
# değeri GÖSTERİLİR (operatöre somut teşhis için gereklidir).
_deploy_env_key_is_secret() {
    case "$1" in
        *SECRET*|*PASSWORD*|*PASS|*_KEY|*TOKEN*|*DSN*|*PASSPHRASE*) return 0 ;;
        *) return 1 ;;
    esac
}

# shared/.env'de tespit edilen HER mükerrer anahtarı operatöre AÇIKÇA
# bildirir (bkz. yukarıdaki BUG özeti). OTOMATİK SİLME YAPMAZ — mükerrer
# blok operatörün BİLİNÇLİ bir eklemesi olabilir; karar operatöre bırakılır.
# 'warn' kullanılır (deploy'u BLOKE ETMEZ — composer/build zaten adım 4/6'da
# kendi bağımsız kapılarından geçer, bkz. _deploy_composer_install/
# _deploy_build_env_overrides; bu fonksiyon yalnız TEŞHİS/GÖRÜNÜRLÜK
# katmanıdır).
_deploy_env_check_duplicates() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0
    local line key lines_str last_line level val
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        key="${line%%:*}"
        lines_str="${line#*:}"
        last_line="${lines_str##*,}"
        level="bilgi"
        _deploy_env_key_is_critical "$key" && level="GÜVENLİK-KRİTİK"
        if _deploy_env_key_is_secret "$key"; then
            val="(gizli değer — log'a yazılmadı)"
        else
            val=$(sed -n "${last_line}p" "$env_file" 2>/dev/null | sed -E 's/^[^=]*=//')
        fi
        warn "shared/.env içinde MÜKERRER anahtar [${level}]: '${key}' satır(lar) ${lines_str}'da tekrarlanmış — dosya-yükleyicide (Dotenv vb.) GEÇERLİ olan SON tanımdır: satır ${last_line} ('${key}=${val}'). srvctl OTOMATİK SİLME YAPMAZ — muhtemelen bir composer/flex reçetesinin eklediği fazlalık bloğu ELLE kaldırın: ${env_file}"
    done < <(_deploy_env_duplicate_keys "$env_file")
}

# release/.env'i shared/.env'e BAĞLAR — KOPYALAR, symlink DEĞİL (bkz.
# fonksiyon üstü GERÇEK VM BUG'I özeti). ESKİDEN 'ln -sf' kullanılıyordu:
# composer/flex/npm gibi web_user olarak çalışan HERHANGİ bir sürecin
# .env'e yaptığı yazı doğrudan KALICI shared/.env'e SIZIYORDU (symfony/
# flex'in bir recipe'i "uygulanmamış" sanıp APP_ENV=dev + boş APP_SECRET
# eklemesi gibi) — 'shared/' deploy'lar arası YAŞADIĞINDAN bu bozulma
# KALICIYDI, her sonraki deploy bozuk dosyayı DEVRALIYORDU. Kopya bu sınıf
# açığı TAMAMEN kapatır: release içinden yapılan yazılar yalnız bu
# DİSPOSABLE kopyayı etkiler (release prune'da silinir), KALICI shared/.env
# HİÇBİR ZAMAN açılıp yazılmaz.
#
# ALTERNATİF DEĞERLENDİRİLDİ VE REDDEDİLDİ (composer boyunca shared/.env'i
# salt-okunur yapmak): (a) exit ile ölen error() yollarında izinleri GERİ
# ALMAK için trap gerektirir (ek karmaşıklık/kırılma riski — bir bug
# izinleri kalıcı salt-okunur bırakabilir, TÜM gelecek deploy'ları/manuel
# .env düzenlemelerini kırar), (b) chmod yalnız dosyanın KENDİSİNİ korur —
# shared/ dizini web_user için yazılabilirse bir araç dosyayı unlink+yeniden
# yaratabilir (chmod'u TAMAMEN BYPASS EDER, directory permission dosya
# permission'ından ÜSTÜNDÜR); kopya bu sınıf açığın TAMAMEN dışındadır
# (release'in kopyası shared'e HİÇBİR ŞEKİLDE bağlı değildir, unlink+
# yeniden yaratma release TARAFINDA olsa bile shared'i ETKİLEMEZ).
#
# _deploy_run'dan (adım 2) AYRI bir fonksiyona ÇIKARILDI ki (bkz. diğer
# _deploy_* extraction'ları ile AYNI desen) tests/ doğrudan çağırıp test
# edebilsin. Dönüş: 0=kopyalandı, 1=shared/.env symlink/güvensiz (reddedildi)
# ya da kopyalama başarısız, 2=shared/.env yok (atlanır, hata değil).
_deploy_env_link() {
    local shared_dir="$1" release_dir="$2"
    if [[ -e "${shared_dir}/.env" ]] && _deploy_assert_safe_shared "${shared_dir}/.env"; then
        if cp -- "${shared_dir}/.env" "${release_dir}/.env"; then
            success ".env kopyalandı (shared/.env korunuyor — release içi yazılar kalıcı dosyayı etkilemez)"
            return 0
        fi
        warn ".env kopyalanamadı: ${shared_dir}/.env -> ${release_dir}/.env"
        return 1
    elif [[ -L "${shared_dir}/.env" ]]; then
        warn "shared/.env bir symlink — güvenlik nedeniyle atlandı"
        return 1
    fi
    warn ".env bulunamadı: ${shared_dir}/.env"
    return 2
}

# Symfony'nin ESKİ 'var:var' paylaşım şemasından (bkz. yukarıdaki shared_pairs
# yorumu — GERÇEK VM bug'ı: paylaşılan var/cache ölü bir release'in mutlak
# yolunu kalıcı olarak taşıyıp sonraki HER deploy'u ve hatta CANLI siteyi
# zehirliyordu) kalma bir 'shared/var/cache' varsa VE içinde 'releases/'
# geçen (muhtemelen ÖLÜ bir release'e ait) bir yol bulunuyorsa operatöre
# AÇIKÇA bildirir.
#
# OTOMATİK SİLME YAPMAZ — bilinçli karar: 'var/cache' TANIMI GEREĞİ yeniden
# üretilebilir olduğundan silmek TEK BAŞINA savunulabilir olurdu, ama ESKİ
# şemada 'shared/var/' aynı çatı altında (varsa) operatörün DEĞERLİ 'var/log'
# ve 'var/sessions' TARİHÇESİNİ de barındırıyor olabilir (yeni şema bunları
# AYRI 'shared/var-log'/'shared/var-sessions' adlarına taşıdı, ama ESKİ
# kurulumlarda hâlâ 'shared/var/log' altında olabilirler). Kör bir
# 'rm -rf shared/var/cache' BİLE (yalnız 'cache' alt dizinini hedeflese de)
# operatörün BEKLEMEDİĞİ bir otomasyonun kendi shared/ içeriğine dokunması
# anlamına gelir — bu projenin GENEL disiplini (bkz. _deploy_env_check_
# duplicates/_deploy_no_rollback_recover) paylaşılan/kalıcı veri söz konusu
# olduğunda TEŞHİS+YÖNLENDİRME'yi, OTOMATİK SİLMEYE HER ZAMAN tercih eder.
#
# PREDİKAT DEĞİL — yan etkisi YOK (yalnız warn), exit ETMEZ.
_deploy_symfony_detect_poisoned_shared_var() {
    local shared_dir="$1"
    local legacy_cache_dir="${shared_dir}/var/cache"
    [[ -d "$legacy_cache_dir" ]] || return 0
    local hit
    hit=$(grep -rl "releases/" -- "$legacy_cache_dir" 2>/dev/null | head -1)
    [[ -n "$hit" ]] || return 0
    warn "shared/var/cache içinde ESKİ (muhtemelen ÖLÜ bir release'e ait) mutlak yol(lar) bulundu — ör. ${hit}. Bu, srvctl'in ARTIK KULLANMADIĞI 'var:var' paylaşım şemasından kalma bir kalıntıdır (bkz. deploy adım 2 yorumu) ve 'MappingException'/'Class DebugBundle not found' sınıfı hatalara yol açabilir. srvctl bunu OTOMATİK SİLMEZ (shared/var/ içinde değerli var/log ya da var/sessions tarihçesi de OLABİLİR). ÖNERİ: değerli bir tarihçe varsa 'shared/var/log' ve 'shared/var/sessions' içeriğini ELLE 'shared/var-log' ve 'shared/var-sessions'a taşıyın, SONRA 'rm -rf ${legacy_cache_dir}' (ya da tamamı için 'rm -rf ${shared_dir}/var') ile eski, artık hiçbir release'e bağlı OLMAYAN paylaşılan cache'i temizleyin."
}

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
    local php_version="$1" sname="${2:-}"
    local unit="php${php_version}-fpm"

    # HOST BULGUSU (gerçek Laravel deploy'u, Ubuntu 22.04): bu fonksiyon HER
    # ZAMAN paylaşılan php<ver>-fpm servisini reload ediyordu. İzole domainde
    # (DOMAIN_ISOLATED_FPM=true — varsayılan) o servis havuzsuz kaldığı için
    # BİLEREK durdurulmuş durumdadır; reload da restart da başarısız olur ve
    # deploy, aslında SORUNSUZ tamamlanmış bir switch'ten sonra "PHP-FPM
    # çalışmıyor olabilir" diyerek error ile ölüyordu. Domainin gerçekte
    # kullandığı unit'i reload etmek gerekiyor.
    if [[ -n "$sname" ]] && systemctl list-units --all --plain --no-legend \
            "srvctl-fpm-${sname}.service" 2>/dev/null | grep -q .; then
        unit="srvctl-fpm-${sname}.service"
    fi
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

# ───────────────────────────────────────────────────────────────
#  Chroot algılama — _deploy_build'in build SONUNDA mutlak-host-yolu gömen
#  framework cache/manifest artefaktlarını temizleyip temizlemeyeceğine karar
#  vermek için. PREDİKAT: 0=chroot aktif, 1=değil.
#
#  KÖK NEDEN (gerçek Laravel 13.x deploy'u, Ubuntu 22.04 — VM'de ölçüldü):
#  build adımı (composer install + artisan config:cache/route:cache/...)
#  HOST'ta, chroot'un DIŞINDA, web_user olarak (runuser ile) çalışır.
#  Laravel'in composer 'post-autoload-dump' script'i (package:discover) ve
#  'artisan config:cache' HOST'un mutlak yolunu (ör.
#  /var/www/laravel.local/releases/<id>/...) 'bootstrap/cache/*.php'ye GÖMER.
#  FPM chroot'lu çalıştığından (pool.conf.tpl: 'chroot = {{WEB_ROOT}}/{{DOMAIN}}')
#  ve open_basedir chroot-GÖRELİ yollarla sınırlı olduğundan, bu gömülü HOST
#  yolu asla ÇÖZÜLEMEZ → 'is_dir(): open_basedir restriction in effect' ile
#  HTTP 500 (gerçek hata mesajı ve dosya yolu rapor edilmiştir).
#
#  BELİRSİZLİKTE YÖN (bu dosyadaki diğer fail-closed kurallarının BİLİNÇLİ bir
#  İSTİSNASI): srvctl'in normal 'domain add' akışı HER domain'i KOŞULSUZ
#  chroot'lar (pool.conf.tpl'de opsiyonel bir anahtar YOK) — yani bu fonksiyon
#  pratikte neredeyse HER ZAMAN "aktif" döner. Yine de körlemesine varsaymak
#  yerine GERÇEK pool config'ini okur (lib/domain.sh/_domain_row ve
#  lib/security.sh'ın zaten kullandığı AYNI 'grep chroot' deseniyle AYNI
#  politika). Pool dosyası HİÇ bulunamazsa (elle kurulum, henüz 'domain add'
#  çalışmamış, test ortamı) belirsizlik "chroot aktif" YÖNÜNE düşürülür —
#  çünkü iki yanlış yönün maliyeti SİMETRİK DEĞİL: chroot'u "yok" sanıp
#  mutlak host yolu gömülü cache'i canlıya almak KATASTROFİK (bu fonksiyonun
#  düzelttiği asıl bug — open_basedir 500); chroot'u "var" sanıp cache'i
#  temizlemek framework'ün onu ÇALIŞMA ZAMANINDA (aynı, doğru ortamda) yeniden
#  üretmesine yol açar — yalnız ilk isteğin soğuk-cache gecikmesi, ZARARSIZ.
# ───────────────────────────────────────────────────────────────
_deploy_chroot_active() {
    local sname="$1" php_version="$2"
    local pool_conf="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"
    [[ -f "$pool_conf" ]] || pool_conf="${SRVCTL_PHP_POOL_DIR:-/etc/php/${php_version}/fpm/pool.d}/${sname}.conf"
    [[ -f "$pool_conf" ]] || return 0
    grep -q "^[[:space:]]*chroot[[:space:]]*=" "$pool_conf" 2>/dev/null
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
#
# 5. parametre 'chroot_active' (bkz. _deploy_chroot_active): "true" ise,
# yukarıdaki cache adımlarının HOST'ta ürettiği ve mutlak HOST yolu gömen
# Laravel 'bootstrap/cache/*.php' (ve VM'DE AYRICA DOĞRULANAN Symfony
# 'var/cache/<env>') artefaktları build SONUNDA silinir — framework onları
# ÇALIŞMA ZAMANINDA, chroot İÇİNDE (bu kez doğru yollarla) yeniden üretir.
# Her iki artefakt da (bootstrap/cache, var/cache) ARTIK release-yerel bir
# dizindir (bkz. _deploy_run'daki shared_pairs yorumu — eskiden ikisi de
# shared/'e symlink'ti ve bu silme fiilen PAYLAŞILAN dizini boşaltıyordu;
# bu, canlı-site-bozulması + ölü-release-yolu-kalıcılığı sınıfı bug'lara yol
# açtığından PAYLAŞIMDAN ÇIKARILDI) — bu yüzden bu satır artık YALNIZ
# ÇAĞRILAN release'i etkiler. CI4 bu sınıftan ETKİLENMEZ (gerçek deploy'da
# HTTP 200, open_basedir hatası sıfır — bkz. rapor) — CI4 dalına KASITLI
# olarak dokunulmadı.
_deploy_build() {
    local framework="$1" release_dir="$2" web_user="$3" php_bin="$4"
    local chroot_active="${5:-true}" framework_declared="${6:-false}"

    # GÜVENLİK: release_dir boş/yok İSE aşağıdaki 'rm -rf --
    # "${release_dir}/var/cache/prod/"*' gibi temizlik satırları
    # '"${release_dir}"' boş string'e çözülürse (ör. bir çağıran satırı
    # 'set -u'suz bir bağlamda unutkanlıkla boş geçerse) '/var/cache/prod/*'
    # gibi HOST'un GERÇEK kök dizinine sızabilirdi. release_dir HER ZAMAN
    # _deploy_run tarafından dolu geçirilir (bu erken çıkış normal akışı
    # DEĞİŞTİRMEZ) — bu yalnız savunma-derinliği katmanıdır.
    [[ -n "$release_dir" && -d "$release_dir" ]] \
        || { warn "_deploy_build: release_dir geçersiz/boş — build atlandı: '${release_dir}'"; return 1; }

    # GÜVENLİK DÜZELTMESİ (bkz. _deploy_build_env_overrides yorumu — gerçek
    # VM bug'ı, symfony/demo + PHP 8.4): artisan/console çağrılarına da AYNI
    # GERÇEK ortam değişkeni zorlaması uygulanır — yalnız composer'ın KENDİ
    # çağrısını değil, _deploy_build'in AYRICA çalıştırdığı cache:clear/
    # config:cache gibi build adımlarını da shared/.env'in (ÖNCEDEN bozulmuş
    # olsa BİLE) etkilemesinden korur.
    local -a fw_env=()
    local _fw_env_kv
    while IFS= read -r _fw_env_kv; do
        [[ -n "$_fw_env_kv" ]] && fw_env+=("$_fw_env_kv")
    done < <(_deploy_build_env_overrides "$framework")

    case "$framework" in
        laravel)
            if [[ ! -f "${release_dir}/artisan" ]]; then
                # BUG B (bkz. _deploy_framework_declared yorumu, gerçek VM
                # bulgusu): domain AÇIKÇA 'laravel' beyan edilmişse entry
                # dosyasının eksikliği NORMAL bir durum DEĞİL — kırık bir
                # composer/build zincirinin (ör. BUG A: composer.json
                # gereksinimleri çözülemedi) kanıtıdır; sessizce 'info'
                # ile atlanıp deploy'un "başarılı" görünmesine izin
                # VERİLMEZ. Beyan yoksa (framework varsayılan/ci4'e
                # düşülmüşse) eski yumuşak davranış korunur.
                if [[ "$framework_declared" == "true" ]]; then
                    error "Domain 'laravel' framework'üyle AÇIKÇA beyan edilmiş ama release'de 'artisan' YOK — deploy durduruldu (kırık bir build canlıya alınmaz). Composer install çıktısını ve repo'yu kontrol edin: ${release_dir}"
                fi
                info "artisan bulunamadı — Laravel build adımları atlanıyor"
            else
                local step_name
                for step_name in config:cache route:cache view:cache event:cache; do
                    _deploy_privdrop "$web_user" \
                        env HOME="$release_dir" ${fw_env[@]+"${fw_env[@]}"} "$php_bin" "${release_dir}/artisan" "$step_name" --no-interaction \
                        || error "artisan ${step_name} başarısız — deploy durduruldu (bozuk önbellek canlıya alınmaz)"
                done

                # BUG DÜZELTMESİ (chroot ↔ host yol uzayı çatışması — bkz.
                # _deploy_chroot_active yorumu, gerçek Laravel 13.x deploy'unda
                # ölçüldü): yukarıdaki 'config:cache' vb. HOST'ta (chroot'un
                # DIŞINDA) çalıştığından ürettiği 'bootstrap/cache/*.php' mutlak
                # HOST yolu gömer; chroot'lu FPM bunu asla çözemez (open_basedir
                # reddi → HTTP 500). VM'DE KANITLANAN çözüm: bu artefaktları SİL
                # — Laravel onları ÇALIŞMA ZAMANINDA, chroot İÇİNDE (bu kez
                # DOĞRU, chroot-göreli yollarla) yeniden üretir. Bedel: deploy
                # sonrası ilk istek soğuk-cache ile karşılaşır (bilinçli kabul
                # edilmiş bir maliyet). 'bootstrap/cache' HER release'de
                # 'shared/bootstrap-cache'e symlink'tir (adım 2, _deploy_link_shared)
                # — bu silme aynı zamanda ESKİ bir release'in ürettiği manifest'in
                # YENİ release'e SIZMASINI da engeller (paylaşılan dizin HER
                # deploy'da fiilen boşaltılır, bkz. koordinatör notu 4).
                # Chroot AKTİF DEĞİLSE dokunulmaz: o zaman 'config:cache' zaten
                # HOST ile AYNI ortamda servis edildiğinden ürettiği yol doğrudur
                # ve gerçek bir performans kazancıdır — körlemesine kaldırılmaz.
                # GÜNCELLEME (bkz. _deploy_run'daki shared_pairs yorumu):
                # 'bootstrap/cache' ARTIK PAYLAŞILMIYOR (eskiden
                # 'bootstrap/cache:bootstrap-cache' ile shared/bootstrap-
                # cache'e symlink'ti — bu, YENİ release'in build'i henüz
                # CANLI olmadan shared'i kendi mutlak yoluyla ezip AYNI ANDA
                # CANLI olan ESKİ release'i de bozabiliyordu). Bu satır artık
                # YALNIZ bu release'in KENDİ yerel dizinini temizler —
                # başka bir release'e/paylaşılan bir dizine ASLA dokunmaz.
                if [[ "$chroot_active" == "true" ]]; then
                    rm -f -- "${release_dir}/bootstrap/cache/"*.php 2>/dev/null || true
                    info "Chroot aktif — bootstrap/cache manifest'leri temizlendi (framework chroot içinde yeniden üretecek)"
                fi

                # storage:link: public/storage -> storage/app/public. HER release
                # yeni bir dizin olduğundan bu symlink HER seferinde yeniden kurulmalı.
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" ${fw_env[@]+"${fw_env[@]}"} "$php_bin" "${release_dir}/artisan" storage:link --no-interaction \
                    || warn "artisan storage:link başarısız — public/storage bağlanmamış olabilir (devam ediliyor)"
            fi
            ;;
        ci4)
            if [[ ! -f "${release_dir}/spark" ]]; then
                # BUG B — bkz. laravel dalındaki AYNI gerekçe.
                if [[ "$framework_declared" == "true" ]]; then
                    error "Domain 'ci4' framework'üyle AÇIKÇA beyan edilmiş ama release'de 'spark' YOK — deploy durduruldu (kırık bir build canlıya alınmaz). Composer install çıktısını ve repo'yu kontrol edin: ${release_dir}"
                fi
                info "spark bulunamadı — CI4 build adımları atlanıyor"
            else
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" "$php_bin" "${release_dir}/spark" cache:clear \
                    || warn "spark cache:clear başarısız (devam ediliyor — en kötü ihtimalle stale cache servis edilir)"
            fi
            ;;
        symfony)
            if [[ ! -f "${release_dir}/bin/console" ]]; then
                # BUG B — bkz. laravel dalındaki AYNI gerekçe. VM'DE
                # DOĞRULANDI (Symfony deploy'u): 'bin/console' aslında
                # symfony/skeleton'ın git deposunda DEĞİL, symfony/flex'in
                # 'composer install' SIRASINDA recipe olarak ürettiği bir
                # dosyadır — composer'ın kendisi 'başarılı' (çıkış kodu 0)
                # görünse bile flex'in İÇ 'composer update'i güvenlik
                # danışmanlığı (advisory) engeliyle çökerse bu recipe hiç
                # UYGULANMAZ ve 'bin/console' asla oluşmaz (bkz. BUG A /
                # _deploy_composer_install). Yani bu dal genelde BUG A'nın
                # DOĞRUDAN sonucudur; yine de framework build'in KENDİ
                # başına da bunu yakalaması gerekir (savunma-derinliği —
                # composer'ın kendi kontrolünü BYPASS eden başka bir yol
                # bulunursa).
                if [[ "$framework_declared" == "true" ]]; then
                    error "Domain 'symfony' framework'üyle AÇIKÇA beyan edilmiş ama release'de 'bin/console' YOK — deploy durduruldu (kırık bir build canlıya alınmaz). Composer install çıktısını ve repo'yu kontrol edin: ${release_dir}"
                fi
                info "bin/console bulunamadı — Symfony build adımları atlanıyor"
            else
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" ${fw_env[@]+"${fw_env[@]}"} "$php_bin" "${release_dir}/bin/console" cache:clear --env=prod --no-interaction \
                    || error "bin/console cache:clear başarısız — deploy durduruldu (bozuk önbellek canlıya alınmaz)"
                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" ${fw_env[@]+"${fw_env[@]}"} "$php_bin" "${release_dir}/bin/console" cache:warmup --env=prod --no-interaction \
                    || warn "bin/console cache:warmup başarısız (devam ediliyor)"

                # HİPOTEZ VM'DE DOĞRULANDI (bkz. _deploy_run'daki shared_pairs
                # yorumu — gerçek koordinatör raporu): Symfony'nin derlenmiş
                # DI container'ı (var/cache/prod/App_KernelProdContainer.php),
                # route eşleyici ve Doctrine mapping meta'sı BUILD ANINDA
                # release'in MUTLAK yolunu gömer — Laravel'in bootstrap/
                # cache'iyle AYNI sınıf hata (chroot'lu FPM bu HOST yolunu
                # asla çözemez). Aynı savunma-derinliği: chroot aktifse
                # derlenmiş cache SİLİNİR; Symfony prod'da container eksikse
                # HATA VERMEZ, ilk istekte lazily (bu kez chroot İÇİNDE,
                # doğru yollarla) yeniden derler.
                #
                # GÜNCELLEME: 'var/cache' ARTIK PAYLAŞILMIYOR (eskiden
                # 'var:var' ile shared/var'a symlink'ti — bu satır o zaman
                # aslında PAYLAŞILAN dizini temizliyordu, ama bu temizlik
                # YENİ release'in build'i shared'i EZDİKTEN SONRA çalıştığı
                # için ARADA bir pencere kalıyordu VE bazı ortamlarda
                # chroot_active'ın YANLIŞ tespit edilmesi/edilmemesi bu
                # temizliğin hiç çalışmamasına yol açabiliyordu — VM'de
                # tam olarak bu şekilde ölü bir release'in yolu shared cache'te
                # KALICI olarak bulundu; bu da CANLI SİTEYİ "Class DebugBundle
                # not found" ile bozdu). Artık release-yerel bir dizin
                # olduğundan bu satır YALNIZ bu release'i etkiler — yapısal
                # olarak başka bir release'e/canlı siteye SIZMA İMKANSIZ.
                if [[ "$chroot_active" == "true" ]]; then
                    rm -rf -- "${release_dir}/var/cache/prod/"* 2>/dev/null || true
                    info "Chroot aktif — Symfony var/cache/prod temizlendi (framework chroot içinde yeniden üretecek)"
                fi

                _deploy_privdrop "$web_user" \
                    env HOME="$release_dir" ${fw_env[@]+"${fw_env[@]}"} "$php_bin" "${release_dir}/bin/console" assets:install --no-interaction "${release_dir}/public" \
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
#  Composer PHP sürüm uyumluluğu — ERKEN ön kontrol (bkz. gerçek VM bug'ı,
#  koordinatör raporu: Laravel 13.x >=8.4.1 gerektiriyordu, domain PHP
#  8.3'teydi, host'ta php8.4 de kuruluydu; composer HOST'un php8.4'üyle
#  platform kontrolünü YANLIŞLIKLA geçti, İKİ ADIM SONRA 'artisan
#  config:cache' domain'in php8.3'üyle patladı — kök neden operatöre
#  GÖRÜNMEDİ, bkz. iki adım aşağıdaki _deploy_run adım 4 yorumu). Aşağıdaki
#  iki fonksiyon composer'dan ÖNCE, ${release_dir} ZATEN klonlanmışken
#  çalışır: composer.json'daki 'require.php' kısıtını okur ve domain'in
#  PHP sürümüyle KABACA karşılaştırır.
# ───────────────────────────────────────────────────────────────

# composer.json içindeki 'require' bloğundan 'php' kısıtını çıkarır.
# jq VARSA onu kullanır (en güvenilir — CLAUDE.md gereği jq bir BAĞIMLILIK
# olarak EKLENMEZ, yalnız zaten kuruluysa TERCİH edilir); YOKSA satır-tabanlı
# bir awk ile 'require' bloğunun açılışı ile ilk kapanan '}' arasında
# '"php": "..."' arar. Bulunamazsa/ayrıştırılamazsa BOŞ string döner (çağıran
# bunu "kısıt yok/bilinmiyor" sayıp kontrolü sessizce atlar — jq'suz ortamda
# minified/tek-satır composer.json bu awk'ın kaçırabileceği nadir bir
# biçimdir; bu KABUL EDİLEBİLİR bir sınırlamadır, tam bir JSON parser
# YAZILMAZ; composer'ın kendisi zaten dosyayı asıl doğru şekilde ayrıştırıp
# gerekirse kendi hatasını verecektir — burası yalnız ERKEN UYARI katmanıdır).
_deploy_composer_php_constraint() {
    local composer_json="$1"
    [[ -f "$composer_json" ]] || return 0
    if command -v jq &>/dev/null; then
        jq -r '.require.php // empty' "$composer_json" 2>/dev/null
        return 0
    fi
    awk '
        /"require"[[:space:]]*:[[:space:]]*\{/ && !done { in_req=1; next }
        in_req && /^[[:space:]]*\}/ { in_req=0 }
        in_req && match($0, /"php"[[:space:]]*:[[:space:]]*"[^"]*"/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^"php"[[:space:]]*:[[:space:]]*"/, "", s)
            sub(/"$/, "", s)
            print s
            done = 1
            exit
        }
    ' "$composer_json" 2>/dev/null
}

# Tek bir kısıt token'ını (>=8.4.1, ^8.2, ~8.2, 8.2.*, 8.2 gibi) ayrıştırır.
# Sonucu GLOBAL 'reply_*' değişkenlerine yazar (bash 3.2 uyumluluğu için —
# macOS'un sevk ettiği /bin/bash 3.2'de 'local -n'/nameref YOK; bu proje
# macOS'ta test edilir, bkz. CLAUDE.md). DÖNÜŞ: 0=token TANINDI, 1=TANINMADI.
_deploy_php_parse_token() {
    local tok="$1" ver
    reply_op="" reply_vmaj="" reply_vmin="" reply_wildcard=0
    if [[ "$tok" =~ ^\>=(.+)$ ]]; then reply_op=">="; ver="${BASH_REMATCH[1]}"
    elif [[ "$tok" =~ ^\<=(.+)$ ]]; then reply_op="<="; ver="${BASH_REMATCH[1]}"
    elif [[ "$tok" =~ ^\>(.+)$ ]]; then reply_op=">"; ver="${BASH_REMATCH[1]}"
    elif [[ "$tok" =~ ^\<(.+)$ ]]; then reply_op="<"; ver="${BASH_REMATCH[1]}"
    elif [[ "$tok" =~ ^\^(.+)$ ]]; then reply_op="^"; ver="${BASH_REMATCH[1]}"
    elif [[ "$tok" =~ ^~(.+)$ ]]; then reply_op="~"; ver="${BASH_REMATCH[1]}"
    elif [[ "$tok" =~ ^([0-9]+)(\.([0-9]+|\*))?(\.(\*|[0-9]+))?$ ]]; then
        reply_op="=="; ver="$tok"
    else
        return 1
    fi

    local vmaj vmin
    IFS='.' read -r vmaj vmin _ <<<"$ver"
    [[ "$vmaj" =~ ^[0-9]+$ ]] || return 1
    if [[ -z "${vmin:-}" || "$vmin" == "*" ]]; then
        reply_wildcard=1; vmin=0
    elif [[ ! "$vmin" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    reply_vmaj=$((10#$vmaj))
    reply_vmin=$((10#$vmin))
    return 0
}

# Tek bir AND grubundaki (boşluk/virgülle ayrılmış token'lar) kısıtların
# TÜMÜNÜN domain PHP sürümüyle (major*1000+minor biçiminde 'dmm') uyumlu
# olup olmadığını değerlendirir. DÖNÜŞ: 0=uyumlu, 1=KESİN uyumsuz,
# 2=belirsiz (tanınmayan/ayrıştırılamayan bir token — çağıran bunu hataya
# DEĞİL uyarıya çevirir, bkz. _deploy_php_satisfies).
#
# İKİ GEÇİŞLİ değerlendirme ZORUNLU (bkz. rapor): hyphen-range gibi kısmen
# tanınan bir ifadede (ör. '5.6 - 7.0' -> token'lar '5.6', '-', '7.0') TEK
# GEÇİŞLİ bir değerlendirme '5.6' token'ını TEK BAŞINA geçerli bir "çıplak
# sürüm" sanıp domain'le KARŞILAŞTIRABİLİR ve '-' token'ına hiç ULAŞMADAN
# erken 'KESİN uyumsuz' (1) dönebilirdi — oysa bu ifadenin BÜTÜNÜ (bir
# ARALIK) yanlış yorumlanmıştır ve BELİRSİZ (2) sayılması gerekir. Bu yüzden
# ÖNCE tüm token'ların tanınırlığı kontrol edilir (birinin bile tanınmaması
# TÜM grubu belirsiz yapar), SONRA (ve YALNIZ hepsi tanınıyorsa) gerçek
# karşılaştırma yapılır.
_deploy_php_constraint_group_ok() {
    local dmm="$1" dmaj_n="$2" group="$3" tok

    for tok in $group; do
        [[ -z "$tok" ]] && continue
        _deploy_php_parse_token "$tok" || return 2
    done

    for tok in $group; do
        [[ -z "$tok" ]] && continue
        _deploy_php_parse_token "$tok" || return 2
        local vmm=$(( reply_vmaj * 1000 + reply_vmin ))
        case "$reply_op" in
            ">=") (( dmm >= vmm )) || return 1 ;;
            ">")  (( dmm >  vmm )) || return 1 ;;
            "<=") (( dmm <= vmm )) || return 1 ;;
            "<")  (( dmm <  vmm )) || return 1 ;;
            "^")
                (( dmaj_n == reply_vmaj )) || return 1
                (( dmm >= vmm )) || return 1
                ;;
            "~")
                if [[ "$reply_wildcard" == "1" ]]; then
                    (( dmaj_n == reply_vmaj )) || return 1
                else
                    (( dmm == vmm )) || return 1
                fi
                ;;
            "==")
                if [[ "$reply_wildcard" == "1" ]]; then
                    (( dmaj_n == reply_vmaj )) || return 1
                else
                    (( dmm == vmm )) || return 1
                fi
                ;;
        esac
    done
    return 0
}

# composer.json 'require.php' kısıtını (ör. '>=8.4.1', '^8.2', '>=8.1 <9.0',
# '8.2.*') domain'in PHP sürümüyle KABACA karşılaştırır. Yalnız major.minor
# ÇÖZÜNÜRLÜĞÜNDE çalışır — _derive_php zaten bundan FAZLASINI bilmiyor (ör.
# domain "8.3" olarak /etc/php/8.3'e karşılık gelir, gerçek patch sürümü
# host'ta neyse odur); bu yüzden kısıtlardaki patch bileşeni (ör. '8.4.1'
# içindeki '.1') KIRPILIR. TAM bir semver çözücü DEĞİLDİR: '||' (OR) ve
# boşluk/virgülle AND edilmiş yaygın biçimleri kapsar; hyphen-range
# ('5.6 - 7.0' gibi) ve dev-branch takma adları gibi nadir biçimler
# TANINMAZ.
#
# DÖNÜŞ: 0=uyumlu (kısıt yok/'*' dahil), 1=KESİN uyumsuz, 2=belirsiz (en az
# bir OR grubu tanınmadı VE hiçbir grup KESİN uyumlu bulunamadı). Çağıran
# (bkz. _deploy_run adım 4a) 1'i error (deploy composer'dan ÖNCE durur),
# 2'yi warn+devam olarak ele alır — belirsizlikte kısıt SESSİZCE "uyumlu"
# SAYILMAZ (fail-open değil, görünür bir uyarı bırakılır), ama sağlam bir
# deploy'u yanlış-pozitifle BLOKE de ETMEZ.
_deploy_php_satisfies() {
    local domain_php="$1" constraint="$2"
    constraint="$(printf '%s' "$constraint" | tr -d '\r\n')"
    constraint="${constraint#"${constraint%%[![:space:]]*}"}"
    constraint="${constraint%"${constraint##*[![:space:]]}"}"
    [[ -z "$constraint" || "$constraint" == "*" ]] && return 0

    local dmaj dmin
    IFS='.' read -r dmaj dmin _ <<<"$domain_php"
    [[ "$dmaj" =~ ^[0-9]+$ ]] || return 2
    [[ "$dmin" =~ ^[0-9]+$ ]] || dmin=0
    local dmm=$((10#$dmaj * 1000 + 10#$dmin))
    local dmaj_n=$((10#$dmaj))

    # '||' (OR) üzerinden GRUPLARA ayır. NOT: bash 3.2'de (macOS'un sevk
    # ettiği /bin/bash — bu proje macOS'ta test edilir, bkz. CLAUDE.md)
    # 'IFS=$'\x01' read -ra arr <<<"$x"' biçimi kontrol karakteriyle
    # GÜVENİLİR ÇALIŞMIYOR (ölçüldü: dizi HİÇ bölünmüyor) — bu yüzden saf
    # parametre genişletmesiyle (sentinel/IFS'siz) elle bölünür.
    local rest="$constraint" group rc uncertain=0
    while [[ "$rest" == *"||"* ]]; do
        group="${rest%%||*}"
        rest="${rest#*||}"
        group="${group//,/ }"
        rc=0
        _deploy_php_constraint_group_ok "$dmm" "$dmaj_n" "$group" || rc=$?
        [[ "$rc" == "0" ]] && return 0
        [[ "$rc" == "2" ]] && uncertain=1
    done
    group="${rest//,/ }"
    rc=0
    _deploy_php_constraint_group_ok "$dmm" "$dmaj_n" "$group" || rc=$?
    [[ "$rc" == "0" ]] && return 0
    [[ "$rc" == "2" ]] && uncertain=1

    [[ "$uncertain" == "1" ]] && return 2
    return 1
}

# composer ikili dosyasının bir PHP betiği/phar mı yoksa başka bir tür
# sarmalayıcı (shell script, native binary) mı olduğunu tahmin eder.
# PREDİKAT: 0=PHP betiği/phar (güvenle "${php_bin} ${bin}" olarak
# çağrılabilir), 1=değil/emin değil.
#
# ARAŞTIRMA (koordinatör VM ölçümü, Ubuntu 22.04, srvctl-jammy):
#   composer yolu       : /usr/local/bin/composer
#   composer türü       : "a /usr/bin/env php script executable"
#   ilk satır           : #!/usr/bin/env php
#   doğrulanan çağrı    : 'php8.3 /usr/local/bin/composer --version' ÇALIŞIYOR
# Yani composer (get.composer.org kurulumu VE Ubuntu/Debian 'composer'
# paketi ikisi de) ÇIPLAK bir PHP phar'ıdır; PHP CLI bir dosyayı
# çalıştırırken başında '#!' varsa o satırı YORUM sayıp atlar (CGI/shebang
# ile aynı davranış), yani '"$php_bin" "$composer_bin"' shebang'daki
# 'env php' çözümlemesini TAMAMEN BY-PASS EDER ve İSTENEN sürümü zorlar —
# bu, getcomposer.org'un resmi olarak belgelediği "farklı bir PHP sürümüyle
# çalıştırma" biçimidir.
#
# Composer BİR ŞEKİLDE (nadir; bu VM'de GÖZLEMLENMEDİ) php-olmayan bir
# sarmalayıcı (ör. bir dağıtımın 'update-alternatives' shell script'i)
# olarak paketlenmişse bu fonksiyon 1 döner; çağıran (_deploy_run adım 4)
# o durumda PATH'e ${php_bin}'e işaret eden bir 'php' shim'i koyup composer'ı
# KENDİ adıyla çalıştırır (sarmalayıcı içeride PATH'ten 'php' arıyorsa bizim
# sürümü bulur).
_deploy_composer_is_php_script() {
    local bin="$1" head
    [[ -r "$bin" ]] || return 1
    head=$(head -c 256 -- "$bin" 2>/dev/null) || return 1
    [[ "$head" == '<?php'* ]] && return 0
    if [[ "$head" == '#!'* ]]; then
        local first_line="${head%%$'\n'*}"
        [[ "$first_line" == *php* ]] && return 0
    fi
    return 1
}

# Beyan edilmiş framework başına, composer'ın GERÇEKTEN kurmuş OLMASI
# gereken paket dizinini döndürür (boş = bu framework için bilinen bir
# işaretçi yok, kontrol atlanır). BUG A (bkz. _deploy_composer_install
# yorumu) için: 'vendor/autoload.php var mı' sorusu YETERSİZ — composer bir
# ALT bağımlılığı (ör. symfony/flex) kurup KENDİ İÇ 'composer update'i
# başarısız olduğunda bile autoload.php ÜRETİLMİŞ olabilir. Paket adları
# framework BEYANINDAN türetilir, repo içeriğinden TAHMİN EDİLMEZ (deploy'un
# genel sözleşmesiyle tutarlı, bkz. _deploy_link_shared/_deploy_build).
_deploy_composer_expected_vendor_pkg() {
    case "$1" in
        laravel) echo "laravel/framework" ;;
        symfony) echo "symfony/framework-bundle" ;;
        ci4)     echo "codeigniter4/framework" ;;
        *)       echo "" ;;
    esac
}

# Framework'e özgü, BUILD ZAMANI (composer install + artisan/console
# çağrıları) için GERÇEK ortam değişkeni olarak zorlanacak APP_ENV/
# APP_DEBUG çiftini satır satır YAZAR (boşsa hiçbir şey yazmaz). Her satır
# 'KEY=VALUE' biçimindedir; çağıran bunu bir diziye okuyup 'env' çağrısına
# ekler.
#
# GERÇEK VM BUG'I (bkz. _deploy_env_check_duplicates yorumu — symfony/demo,
# PHP 8.4): shared/.env symfony/flex tarafından bozulup 'APP_ENV=dev' kazanınca
# composer'ın KENDİ 'post-install-cmd' hook'u (flex'in dahili
# 'cache:clear'i) dev-only bir bundle (DebugBundle) arayıp ÇÖKTÜ. Symfony'nin
# Dotenv'i (ve Laravel'in vlucas/phpdotenv'i) ZATEN VAR OLAN bir GERÇEK
# ortam değişkenini .env'deki değerle ASLA EZMEZ — yani burada 'env
# APP_ENV=prod APP_DEBUG=0 composer install ...' biçiminde GERÇEK ortam
# değişkeni olarak geçirilirse, .env'İN İÇERİĞİ NE OLURSA OLSUN (bozuk/
# mükerrer olsa BİLE) bu değerler KAZANIR. Bu, Symfony'nin resmi deploy
# dokümantasyonunun BİREBİR ÖNERDİĞİ biçimdir ('APP_ENV=prod APP_DEBUG=0
# composer install --no-dev --optimize-autoloader'); Laravel'in karşılığı
# ('APP_ENV=production') aynı sebeple (vlucas/phpdotenv de ayNI şekilde
# ZATEN-VAR-OLAN gerçek env'i EZMEZ) uygulanır — savunma-derinliği, Laravel'de
# flex-benzeri bir .env-yazan recipe sistemi OLMASA da bu ZARARSIZ ve UCUZ
# bir ek güvencedir.
#
# CI4'e KASITLI OLARAK dokunulmadı: flex-tarzı bir "recipe .env'e otomatik
# yazar" mekanizması YOK (koordinatör taramasında ci4.local ETKİLENMEDİ);
# CI4'ün .env okuma biçimi de (putenv, farklı bir kural seti) FARKLI —
# test edilmemiş/gereksiz bir davranış EKLEMEMEK için bilinen bug'ın
# kapsamı dışına ÇIKILMADI.
_deploy_build_env_overrides() {
    case "$1" in
        laravel) printf '%s\n%s\n' "APP_ENV=production" "APP_DEBUG=false" ;;
        symfony) printf '%s\n%s\n' "APP_ENV=prod" "APP_DEBUG=0" ;;
        *) : ;;
    esac
}

# ───────────────────────────────────────────────────────────────
#  Composer'ı DAİMA domain'in PHP sürümüyle (${php_bin}), web_user olarak
#  (root DEĞİL) kurar. composer.json repodan gelir; root çalıştırmak kötü
#  niyetli bir lifecycle script'ine root verirdi. _deploy_run'dan (adım 4)
#  ayrı bir fonksiyona ÇIKARILDI ki (bkz. _deploy_build/_deploy_link_shared
#  ile AYNI desen) tests/ gerçek git clone/network OLMADAN, sahte bir
#  composer/php ikili dosyasıyla bu mantığı doğrudan çağırıp test edebilsin.
#
#  KÖK NEDEN DÜZELTMESİ (gerçek VM bug'ı, Laravel 13.x, Ubuntu 22.04):
#  composer ÇIPLAK 'composer' adıyla çağrıldığında kendi shebang'ı
#  ('#!/usr/bin/env php') üzerinden HOST'un PATH'indeki VARSAYILAN php'yi
#  seçiyordu — domain'in FPM'de kullandığı sürümle (ör. 8.3) DEĞİL. VM'de
#  host'ta php8.4 de kuruluyken bu composer'ın 8.4'ün platform kontrolünü
#  sessizce geçmesine yol açıyordu ('✓ Composer paketleri yüklendi'); İKİ
#  ADIM SONRA (framework build) 'artisan config:cache' domain'in GERÇEK
#  php8.3'üyle "Composer detected issues in your platform: ... PHP version
#  '>= 8.4.1' ... You are running 8.3.33" hatasıyla patlıyordu — operatöre
#  görünen hata kök nedenden iki adım geride ve YANILTICIYDI. VM'de
#  composer'ın çıplak bir PHP betiği/phar olduğu doğrulandı (bkz.
#  _deploy_composer_is_php_script yorumu) — bu yüzden composer artık açıkça
#  ${php_bin} ile çağrılır.
#
#  Argümanlar: release_dir web_user php_bin php_version domain composer_home
#                                                                 framework
#  error() ile exit eder (uyumsuz PHP kısıtı / composer eksik / kurulum
#  başarısız / composer 'başarılı' ama beklenen framework paketi eksik) —
#  çağıran (_deploy_run) bunu ZATEN error-exit-eden komşu adımlarla (ör.
#  _deploy_link_shared) AYNI şekilde ele alır.
#
#  BUG A (gerçek VM bug'ı, koordinatör raporu, Symfony 7.3 skeleton, Ubuntu
#  22.04): 'composer install' ÖNCE yalnız symfony/flex'i kurup (rc=0) SONRA
#  flex'in KENDİ İÇ 'composer update'ini tetikliyor; bu ikinci adım composer
#  2.10'un 'policy.advisories.block' davranışı yüzünden ("Your requirements
#  could not be resolved to an installable set of packages ... affected by
#  security advisories") ÇÖKÜYOR — ama flex zaten kurulduğundan
#  'vendor/autoload.php' VARDI ve eski guard bunu "başarılı" sayıyordu
#  ('✓ Composer paketleri yüklendi' yazdırıp devam ediyordu). Bu yüzden
#  autoload.php kontrolüne İKİ bağımsız katman eklendi (aşağıda): (1)
#  composer'ın kendi çıktısında bilinen "could not be resolved" ifadesi
#  aranır — bulunursa KOŞULSUZ hata (composer'ın KENDİ ifadesi, en güvenilir
#  sinyal); (2) framework BEYANINA göre beklenen bir vendor paketinin
#  (ör. symfony/framework-bundle) GERÇEKTEN kurulu olup olmadığı doğrulanır.
#  srvctl composer'ın güvenlik-danışmanlığı politikasını KENDİLİĞİNDEN
#  GEVŞETMEZ (advisory'li bir paketi sessizce kurmak bu projenin tehdit
#  modeline aykırıdır) — yalnız durumu NET bir Türkçe mesajla yüzeye çıkarır,
#  kararı operatöre bırakır.
# ───────────────────────────────────────────────────────────────
_deploy_composer_install() {
    local release_dir="$1" web_user="$2" php_bin="$3" php_version="$4" \
          domain="$5" composer_home="$6" framework="${7:-}"

    # 4a. ERKEN ön kontrol: composer.json'daki 'require.php' kısıtı domain'in
    #     PHP sürümüyle KESİN uyumsuzsa deploy BURADA durur — composer'ın
    #     YANLIŞ PHP'yle sessizce "başarılı" görünüp asıl patlamanın
    #     framework build adımında geç ve belirsiz bir mesajla üretilmesi
    #     ENGELLENİR (bkz. yukarıdaki kök-neden notu).
    local php_constraint; php_constraint=$(_deploy_composer_php_constraint "${release_dir}/composer.json")
    if [[ -n "$php_constraint" ]]; then
        local php_req_rc=0
        _deploy_php_satisfies "$php_version" "$php_constraint" || php_req_rc=$?
        case "$php_req_rc" in
            0) : ;;
            1) error "composer.json PHP ${php_constraint} istiyor, domain PHP ${php_version} kullanıyor — 'srvctl domain php-switch ${domain} <sürüm>' ile uygun PHP sürümüne geçin (deploy composer'dan ÖNCE durduruldu)" ;;
            *) warn "composer.json PHP kısıtı ('${php_constraint}') otomatik doğrulanamadı (karmaşık/tanınmayan ifade) — domain PHP ${php_version} ile devam ediliyor. Composer/artisan sonradan bir platform hatası verirse composer.json 'require.php' kısıtını elle kontrol edin." ;;
        esac
    fi

    local composer_bin
    composer_bin=$(command -v composer) \
        || error "composer.json var ama composer kurulu değil — deploy reddedildi (vendor/ olmadan release canlıya alınamaz)"

    mkdir -p "${composer_home}/cache"
    chown -R "${web_user}:${web_user}" "${composer_home}"

    # composer'ın TAM çıktısı (stdout+stderr) 'tee' ile HEM operatöre CANLI
    # gösterilir HEM de bir log dosyasına yakalanır — BUG A'nın "could not
    # be resolved" imzasını aşağıda arayabilmek için (bkz. fonksiyon üstü
    # yorum). mktemp başarısız olursa (nadir) /dev/null'a düşülür: canlı
    # akış (tee'nin stdout'u) ETKİLENMEZ, yalnız programatik arama atlanır —
    # asıl exit-kodu/vendor-paket kontrolleri BUNA bağımlı DEĞİLDİR (fail-open
    # YOK). pipefail (bin/srvctl'de 'set -euo pipefail') sayesinde
    # aşağıdaki 'if ! pipeline' composer'ın KENDİ çıkış kodunu yansıtır
    # (tee neredeyse her zaman 0 döner).
    local composer_log
    composer_log=$(mktemp "${composer_home}/.composer-log.XXXXXX" 2>/dev/null) || composer_log="/dev/null"

    # GÜVENLİK DÜZELTMESİ (bkz. _deploy_build_env_overrides yorumu — gerçek
    # VM bug'ı, symfony/demo + PHP 8.4): APP_ENV/APP_DEBUG'ı GERÇEK ortam
    # değişkeni olarak zorla — shared/.env (kopya olsa da, ÖNCEDEN bozulmuş
    # olabilir) NE İÇERİRSE İÇERSİN composer'ın (ve onun flex gibi dahili
    # 'post-install-cmd' hook'larının) her zaman doğru ortamda çalışması
    # GARANTİ edilir. Dotenv ZATEN VAR olan bir gerçek env değişkenini ASLA
    # EZMEZ (bkz. yorum) — bu yüzden .env'in içeriği burada ÖNEMSİZDİR.
    local -a fw_env=()
    local _fw_env_kv
    while IFS= read -r _fw_env_kv; do
        [[ -n "$_fw_env_kv" ]] && fw_env+=("$_fw_env_kv")
    done < <(_deploy_build_env_overrides "$framework")

    if _deploy_composer_is_php_script "$composer_bin"; then
        if ! _deploy_privdrop "$web_user" \
                env HOME="$composer_home" COMPOSER_HOME="$composer_home" \
                    COMPOSER_CACHE_DIR="${composer_home}/cache" \
                    ${fw_env[@]+"${fw_env[@]}"} \
                "$php_bin" "$composer_bin" install --working-dir="${release_dir}" \
                    --no-dev --optimize-autoloader --no-interaction --no-progress \
                2>&1 | tee "$composer_log"
        then
            rm -f "$composer_log"
            error "Composer install başarısız — deploy durduruldu (release canlıya alınmadı: ${release_dir})"
        fi
    else
        # NADİR YOL (VM'de GÖZLEMLENMEDİ — composer orada çıplak phar'dı,
        # bkz. _deploy_composer_is_php_script yorumu): composer tanınan bir
        # PHP betiği/phar DEĞİLSE '"$php_bin" "$composer_bin"' çalışmayabilir
        # (ör. bash sarmalayıcıyı PHP olarak yorumlamaya çalışırdı). Böyle
        # bir sarmalayıcı genelde KENDİ İÇİNDE PATH'ten 'php' arar — bu
        # yüzden web_user'ın PATH'inin BAŞINA, yalnız bu çağrı için,
        # ${php_bin}'e işaret eden bir 'php' sembolik bağlantısı (shim)
        # koyulur.
        warn "composer ikili dosyası tanınan bir PHP betiği/phar değil (${composer_bin}) — PHP sürümü PATH shim ile zorlanıyor"
        local composer_shim
        composer_shim=$(mktemp -d "${composer_home}/.php-shim.XXXXXX" 2>/dev/null) \
            || error "Composer PHP-sürüm shim dizini oluşturulamadı"
        ln -sf "$php_bin" "${composer_shim}/php"
        chown -R "${web_user}:${web_user}" "$composer_shim"
        if ! _deploy_privdrop "$web_user" \
                env HOME="$composer_home" COMPOSER_HOME="$composer_home" \
                    COMPOSER_CACHE_DIR="${composer_home}/cache" \
                    PATH="${composer_shim}:${PATH}" \
                    ${fw_env[@]+"${fw_env[@]}"} \
                "$composer_bin" install --working-dir="${release_dir}" \
                    --no-dev --optimize-autoloader --no-interaction --no-progress \
                2>&1 | tee "$composer_log"
        then
            rm -rf -- "$composer_shim"
            rm -f "$composer_log"
            error "Composer install başarısız — deploy durduruldu (release canlıya alınmadı: ${release_dir})"
        fi
        rm -rf -- "$composer_shim"
    fi

    # BUG A (bkz. fonksiyon üstü yorum) — İKİ bağımsız doğrulama katmanı,
    # 'vendor/autoload.php var mı' sorusundan DAHA GÜÇLÜ:
    #
    # (1) composer'ın KENDİ çıktısında bilinen başarısızlık imzası ara.
    #     composer exit-kodu 0 döndürse BİLE (flex'in kurulumu gibi bir ALT
    #     adım başarılı olduğundan) bu ifade varsa GERÇEK bağımlılık ağacı
    #     ÇÖZÜLEMEMİŞTİR — composer'ın KENDİ ifadesi olduğundan en güvenilir
    #     sinyal budur, KOŞULSUZ hataya çevrilir.
    if grep -q "could not be resolved to an installable set of packages" "$composer_log" 2>/dev/null; then
        rm -f "$composer_log"
        error "Composer 'başarılı' göründü (çıkış kodu 0) ama kendi çıktısında 'could not be resolved' hatası var — composer.json bağımlılıkları GERÇEKTEN çözülemedi. Bu genellikle composer 2.10+'ın güvenlik-danışmanlığı (security advisory) politikasının ('policy.advisories.block') bir paket sürümünü KURULMASINI ENGELLEMESİNDEN kaynaklanır. srvctl bu politikayı KENDİLİĞİNDEN GEVŞETMEZ (danışmanlığı olan bir paketi sessizce kurmak bu projenin tehdit modeline aykırıdır) — composer.json/composer.lock'taki sürüm kısıtlarını güvenli bir sürüme güncelleyip tekrar deneyin. Deploy durduruldu, release canlıya alınmadı: ${release_dir}"
    fi
    rm -f "$composer_log"

    [[ -f "${release_dir}/vendor/autoload.php" ]] \
        || error "Composer çalıştı ama vendor/autoload.php üretilmedi — deploy durduruldu"

    # (2) framework BEYANINA göre beklenen bir vendor paketinin GERÇEKTEN
    #     kurulu olduğunu doğrula (bkz. _deploy_composer_expected_vendor_pkg).
    #     VM'DE KANITLANDI (Symfony skeleton): symfony/flex yalnız 'kendisi'
    #     kurulup KENDİ İÇ güncellemesi çökebiliyordu — bu durumda
    #     'vendor/autoload.php' VAR ama 'vendor/symfony/framework-bundle'
    #     YOKTU (çünkü flex'in normalde kuracağı asıl framework paketleri
    #     hiç kurulmamıştı). Framework beyan EDİLMEMİŞSE (boş 'framework'
    #     ya da bilinmeyen bir değer) bu kontrol ATLANIR — operatörün açıkça
    #     bildirmediği bir varsayımla deploy'u durdurmak fail-closed'ın YANLIŞ
    #     yönü olurdu (bkz. _deploy_framework_declared'daki AYNI disiplin).
    local expected_pkg; expected_pkg=$(_deploy_composer_expected_vendor_pkg "$framework")
    if [[ -n "$expected_pkg" && ! -d "${release_dir}/vendor/${expected_pkg}" ]]; then
        error "Composer 'başarılı' göründü (çıkış kodu 0, vendor/autoload.php var) ama beklenen framework paketi eksik: vendor/${expected_pkg} (framework beyanı: '${framework}'). composer.json bağımlılıklarının GERÇEKTEN çözüldüğünü doğrulayın (composer.lock, composer install çıktısı). Deploy durduruldu, release canlıya alınmadı: ${release_dir}"
    fi

    success "Composer paketleri yüklendi (PHP ${php_version})"
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

    # Build/migration VE composer adımları için sürüm-doğru PHP CLI ikili
    # dosyası ZORUNLUDUR (Ondřej PPA 'php8.1'/'php8.3' gibi versiyonlu ikili
    # sağlar). ESKİDEN php${php_version} bulunamazsa PATH'teki genel 'php'ye
    # (ya da o da yoksa çıplak "php" adına) SESSİZCE düşülüyordu.
    #
    # GERÇEK VM BUG'I (koordinatör raporu, Ubuntu 22.04, Laravel 13.x): host'ta
    # hem php8.3 hem php8.4 kuruluyken, composer domain'in php8.3'ü YERİNE
    # host'un varsayılan php8.4'üyle çalışıp platform kontrolünü YANLIŞLIKLA
    # geçiyordu ('✓ Composer paketleri yüklendi'); İKİ ADIM SONRA 'artisan
    # config:cache' domain'in GERÇEK php8.3'üyle "Composer detected issues in
    # your platform: ... PHP version '>= 8.4.1' ... You are running 8.3.33"
    # hatasıyla patlıyordu — operatöre görünen hata kök nedenden iki adım
    # geride ve YANILTICIYDI. Composer artık AŞAĞIDA (adım 4) açıkça bu
    # ${php_bin} ile çağrılıyor; bu yüzden ${php_bin}'in GERÇEKTEN domain'in
    # sürümüne ait olduğu (host'un rastgele bir başka PHP'sine SESSİZCE
    # düşülmediği) burada, en başta, GARANTİ edilmeli — aksi halde aynı sınıf
    # hata composer çağrısında da tekrarlanırdı.
    local php_bin
    php_bin=$(command -v "php${php_version}" 2>/dev/null) || php_bin=""
    [[ -n "$php_bin" && -x "$php_bin" ]] \
        || error "Domain PHP sürümü için CLI ikili dosyası bulunamadı: php${php_version} (kurulum: apt install php${php_version}-cli). Host'un varsayılan 'php'sine SESSİZCE düşülmüyor — composer/artisan'ın domain'den FARKLI bir PHP sürümüyle çalışmasını önlemek için bu kontrol ZORUNLUDUR."

    # Chroot'lu FPM ↔ chroot'suz build arasındaki yol uzayı çatışması (bkz.
    # _deploy_chroot_active yorumu): build adımı (composer/artisan) HER ZAMAN
    # host'ta, chroot'un DIŞINDA çalışır; _deploy_build bu bayrağa göre
    # mutlak-host-yolu gömen cache artefaktlarını temizleyip temizlemeyeceğine
    # karar verir.
    local chroot_active="false"
    _deploy_chroot_active "$sname" "$php_version" && chroot_active="true"

    # ── Per-domain meta: FRAMEWORK/RUN_MIGRATIONS/KEEP_GIT (KULLANICI KARARI) ──
    # Meta web-yazılabilir olabildiğinden (hardened olmayan domain) GÜVENİLMEZ;
    # her biri beyaz liste/validate_bool ile doğrulanır, geçersizse güvenli
    # varsayılana düşülür (fail-closed: bilinmeyen framework -> ci4, migration
    # kapalı, .git kaldırılır).
    # FRAMEWORK: TEK KAYNAK — lib/domain.sh/_domain_read_framework varsa onu
    # kullan (aynı whitelist+tamper-gate _deploy_read_framework içinde fail-soft
    # olarak uygulanır, bkz. o fonksiyonun yorumu).
    local FRAMEWORK; FRAMEWORK=$(_deploy_read_framework "$domain")

    # BUG B ön-koşulu (bkz. _deploy_framework_declared yorumu): framework
    # AÇIKÇA beyan edilmiş mi (yalnızca bu durumda _deploy_build entry
    # dosyası eksikliğini HATA sayar; beyan yoksa eski yumuşak davranış).
    local framework_declared="false"
    _deploy_framework_declared "$domain" "$FRAMEWORK" && framework_declared="true"

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
    #
    # GÜVENLİK/DOĞRULUK DÜZELTMESİ (gerçek VM bug'ı, koordinatör raporu,
    # symfony/demo, Ubuntu 22.04): ESKİDEN symfony için TÜM 'var/' paylaşılıyordu
    # ('var:var'). Symfony'nin derlenmiş DI container'ı (var/cache/prod/
    # App_KernelProdContainer.php), route eşleyici ve Doctrine mapping meta'sı
    # BUILD ANINDA release'in MUTLAK YOLUNU koda/meta'ya GÖMER (Laravel'in
    # bootstrap/cache'iyle AYNI sınıf — bkz. _deploy_build/_deploy_chroot_
    # active yorumu). 'var/cache' PAYLAŞILINCA bu sürekli bir zehirlenmeye
    # dönüşüyordu: release N'in cache'i shared'e yazılıyor, release N+1'in
    # build'i BAŞLAMADAN ÖNCE (henüz canlıya ALINMAMIŞKEN) o SHARED cache'i
    # KENDİ (henüz canlı OLMAYAN) mutlak yoluyla EZİYORDU — ama release N HÂLÂ
    # CANLIYSA ve AYNI shared/var'ı okuyorsa, bu ÇALIŞAN SİTEYİ deploy
    # SIRASINDA bozabiliyordu (Laravel'in bootstrap/cache paylaşımından bile
    # DAHA KÖTÜ bir risk — bkz. aşağıdaki laravel notu). VM'de KANITLANDI:
    # release N silinince release N+1'in build'i "MappingException: [.../
    # releases/<N>/src/Entity] seems to be incorrect" ile ÇÖKTÜ (ÖLÜ bir
    # release'in yolu shared cache'te kalıcı olarak GÖMÜLÜYDÜ) ve CANLI site
    # "Class DebugBundle not found" ile 500 veriyordu (paylaşılan cache'te
    # DEV ortamında derlenmiş bir container --no-dev kurulumunda ARANAN
    # DebugBundle'ı bulamıyordu).
    #
    # DÜZELTME: 'var/cache' ARTIK PAYLAŞILMAZ — her release KENDİ 'var/cache'ini
    # (composer/console'un o release içinde ürettiği, chroot-göreli) kullanır;
    # _deploy_build'deki mevcut 'chroot_active ise var/cache/prod/* sil'
    # temizliği artık yalnız BU release'in KENDİ yerel dizinini etkiler,
    # ASLA paylaşılan/başka bir release'in dizinini DEĞİL. Yalnız 'var/log'
    # (deploy'lar arası tarihçe için) ve 'var/sessions' (Symfony flex
    # iskeletinin varsayılan framework.yaml'ı session save_path'i
    # '%kernel.project_dir%/var/sessions/%kernel.environment%' yapar —
    # oturum SÜREKLİLİĞİ için paylaşılmalı) PAYLAŞILIR — ikisi de yalnız
    # DÜZ VERİ (log satırları/serialize edilmiş oturum verisi) İÇERİR,
    # release'in mutlak yolunu GÖMMEZ. shared_subdir'ler 'var-log'/
    # 'var-sessions' (tire ile) OLARAK adlandırıldı — 'bootstrap-cache' ile
    # AYNI kural (nested rel_path'lerde düz isim yerine belirtik önek) — ki
    # gelecekte YANLIŞLIKLA bir 'cache' paylaşımı eklenirse isim ÇAKIŞMASIN.
    #
    # ARAŞTIRILDI (kod okumasıyla, HOST'ta ÇALIŞTIRILMADI — bkz. rapor):
    # koordinatörün gözlemlediği 'var/dart-sass', 'var/sass', 'var/share'
    # muhtemelen symfonycasts/sass-bundle (Symfony UX AssetMapper'ın Sass
    # derleyicisi) tarafından üretiliyor — 'dart-sass' indirilen derleyici
    # İKİLİ dosyasının önbelleği, 'sass' derlenmiş CSS çıktısı. İkisi de
    # release'in mutlak yolunu GÖMMEZ (yalnız harici bir aracın önbelleği/
    # derlenmiş STATİK dosya) — bu yüzden KASITLI OLARAK ne paylaşılıyor ne
    # de dokunuluyor: eski 'var:var' şemasından kalma bu dizinler
    # shared/var/ altında YETİM (artık hiçbir shared_pairs eşlemesinin
    # hedeflemediği) kalacak, ama ZARARSIZDIR (release'e symlink OLMADIKLARI
    # için sızma/zehirlenme riski YOK). Operatör isterse elle temizleyebilir.
    #
    # LARAVEL — AYNI SINIF BUG, KONTROL EDİLDİ: 'bootstrap/cache' de PAYLAŞIM
    # LİSTESİNDEN ÇIKARILDI. Composer'ın post-autoload-dump'ı VE 'artisan
    # config:cache/route:cache/event:cache' bootstrap/cache/*.php'ye
    # release'in MUTLAK yolunu gömer (ör. config('filesystems.disks.local.root')
    # gibi 'storage_path()' çağrıları BUILD ANINDA ÇÖZÜLÜP sonuç STRING
    # olarak cache'e YAZILIR) — 'var/cache' ile TAMAMEN AYNI risk sınıfı.
    # PAYLAŞILDIĞINDA risk Symfony'dekinden bile DAHA CİDDİYDİ: build adımı
    # (composer/artisan) HER ZAMAN atomik switch'TEN ÖNCE (adım 6, switch
    # adım 7'de) çalışır — yani YENİ release'in build'i shared/bootstrap-cache'i
    # KENDİ (henüz canlı OLMAYAN) mutlak yoluyla EZERKEN, O ANDA CANLI OLAN
    # ESKİ release de AYNI shared/bootstrap-cache'i okuyordu (ikisi de
    # sembolik bağlıydı) — yani ÇALIŞAN SİTE deploy SIRASINDA, atomik switch'e
    # ULAŞILMADAN bile bozulabiliyordu. 'storage:storage' PAYLAŞIMI KORUNDU
    # (güvenli — storage/app kullanıcı yüklemeleri, storage/logs/storage/
    # framework/sessions düz veri; storage/framework/views'ın önbellek
    # ANAHTARI kaynak dosyanın mutlak yoluna bağlıdır ama bu yalnız zararsız
    # bir cache-miss'e yol açar, Symfony'nin derlenmiş container'ı/Laravel'in
    # config cache'i gibi FONKSİYONEL bir çökmeye DEĞİL).
    local shared_pairs=()
    case "$FRAMEWORK" in
        ci4)     shared_pairs=("writable:writable") ;;
        laravel) shared_pairs=("storage:storage") ;;
        symfony) shared_pairs=("var/log:var-log" "var/sessions:var-sessions") ;;
    esac

    # Önceki sürüm: doğrulama için mutlak yol, geri dönüş için GÖRELİ symlink
    # hedefi. Eski (4374021 öncesi) mutlak link'ler de burada göreliye çevrilir.
    # prev_root_link: 'current' (worker/scheduler WorkingDirectory'si) için —
    # HER ZAMAN release KÖKÜ, '/public' YOK ('%/public' ile atılır; public/
    # içermeyen release'lerde zaten no-op).
    local prev_target="" prev_rel_link="" prev_root_link=""
    if [[ -L "$public_dir" ]]; then
        # HOST BULGUSU (gerçek Laravel deploy'u): public_html DANGLING bir
        # symlink ise (release'i elle silinmiş / yarım kalmış müdahale)
        # 'readlink -f' BOŞ döner VE non-zero çıkar; 'set -e' deploy'u
        # HİÇBİR MESAJ VERMEDEN öldürüyordu (operatör yalnız rc=1 görüyordu).
        # Boş değer zaten aşağıdaki fail-closed mantığı tetikler.
        prev_target=$(readlink -f "$public_dir" 2>/dev/null) || prev_target=""
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

    # HOST BULGUSU (gerçek Laravel deploy'u, Ubuntu 22.04): switch'ten ÖNCEKİ
    # hata yollarında (clone/composer/hook/build/izin) release dizini DİSKTE
    # KALIYORDU. Laravel 13'ün PHP 8.4 gereksinimi yüzünden 'artisan
    # config:cache' patladığında iki ardışık denemeden ~100'er MB'lık iki ölü
    # release kaldı (vendor/ dahil). Webhook ile sürekli başarısız olan bir
    # branch'te bu disk dolmasına gider; prune yalnız BAŞARILI deploy sonunda
    # çalıştığı için de temizlenmez.
    # Trap switch başarılı olunca kaldırılır (o noktadan sonra release CANLIDIR).
    trap '_deploy_discard_release "$base" "$release_dir"' EXIT INT TERM
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
    # GÜVENLİK DÜZELTMESİ — bkz. _deploy_env_link yorumu: release/.env artık
    # shared/.env'e SYMLINK DEĞİL, bir KOPYADIR.
    _deploy_env_link "$shared_dir" "$release_dir" || true
    # GÜVENLİK: shared/.env'de (ÖNCEKİ bir bozulmadan kalma) MÜKERRER bir
    # anahtar varsa operatöre AÇIKÇA bildir — kopya yeni yazılmayı
    # ENGELLESE de, ZATEN BOZULMUŞ kurulumlarda dosya hâlâ bozuk kalabilir
    # (bu fonksiyon TEŞHİS içindir, otomatik düzeltme YAPMAZ).
    _deploy_env_check_duplicates "${shared_dir}/.env"
    # DOĞRULUK: Symfony'de ESKİ 'var:var' paylaşım şemasından (bkz.
    # yukarıdaki shared_pairs yorumu) kalma ZEHİRLENMİŞ bir 'shared/var/cache'
    # varsa operatöre AÇIKÇA bildir (bu fonksiyon da TEŞHİS içindir, otomatik
    # SİLME yapmaz).
    if [[ "$FRAMEWORK" == "symfony" ]]; then
        _deploy_symfony_detect_poisoned_shared_var "$shared_dir"
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

    # 4. Composer — DAİMA domain'in PHP sürümüyle (${php_bin}), web_user
    #    olarak (root DEĞİL). Mantığın tamamı _deploy_composer_install'da
    #    (bkz. o fonksiyonun yorumu: kök-neden, VM bulgusu, shim düşüş yolu).
    step "4/9" "Composer install (kullanıcı: ${web_user}, PHP: ${php_version})..."
    if [[ -f "${release_dir}/composer.json" ]]; then
        _deploy_composer_install "$release_dir" "$web_user" "$php_bin" "$php_version" "$domain" "${base}/tmp/composer" "$FRAMEWORK"
    else
        info "composer.json yok — atlanıyor"
    fi

    # 5. Pre-deploy hook — web_user olarak (shared/hooks/ web-yazılabilir)
    step "5/9" "Pre-deploy hook..."
    _run_hook "${shared_dir}/hooks/pre-deploy.sh" "${release_dir}" "${domain}" "${web_user}"

    # 6. Framework build (cache/asset) — switch'ten ÖNCE, web_user olarak.
    step "6/9" "Framework build (${FRAMEWORK})..."
    _deploy_build "$FRAMEWORK" "$release_dir" "$web_user" "$php_bin" "$chroot_active" "$framework_declared"

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
    # 'public_html_backup' KAYDEDİLİR (bkz. BUG C, adım 9): sağlık kontrolü
    # BAŞARISIZ olur VE geri dönülecek gerçek bir önceki release YOKSA (ör.
    # BU İLK deploy denemesiyse) bu orijinal içerik (domain.sh'ın kurduğu
    # placeholder) GERİ YÜKLENEBİLSİN diye — aksi halde kalıcı olarak
    # kaybolurdu.
    local public_html_backup=""
    if [[ -d "$public_dir" && ! -L "$public_dir" ]]; then
        public_html_backup="${base}/public_html.bak.$(date +%s)"
        mv "$public_dir" "$public_html_backup" 2>/dev/null || public_html_backup=""
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
    # Release artık CANLI — bundan sonraki hatalarda onu silmek yanlış olur
    # (health-check dalı kendi rollback/temizlik mantığını uygular).
    trap - EXIT INT TERM
    _deploy_reload_fpm "$php_version" "$sname"
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
            _deploy_reload_fpm "$php_version" "$sname"
            rm -rf "${release_dir}"
            _deploy_notify "Deploy Otomatik Geri Alındı: ${domain}" "Branch: ${branch}. Sağlıksız release (HTTP ${code}) geri alındı. Geri dönülen: ${prev_rel_link}" "critical"
            error "Deploy geri alındı. Önceki sürüm geri yüklendi: ${prev_rel_link}"
        else
            # Başarısız release'i diskte bırakma — aksi halde her başarısız
            # webhook deploy'u kalıcı olarak birikirdi.
            rm -rf "${release_dir}"

            # BUG C DÜZELTMESİ — bkz. _deploy_no_rollback_recover yorumu:
            # release YUKARIDA silindiği için adım 7'de ZATEN bu release'e
            # çevrilmiş olan 'public_html'/'current' symlink'leri KIRIK
            # (dangling) kalmasın diye ya deploy-öncesi haline GERİ YÜKLENİR
            # ya da temizlenir.
            _deploy_no_rollback_recover "$base" "$public_dir" "$public_html_backup" "$web_user"

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

    # _deploy_reload_fpm'e geçilir: izole domainde paylaşılan php<ver>-fpm
    # yerine srvctl-fpm-<sname>.service reload edilmeli (set -u altında
    # tanımsız bırakılamaz).
    local sname; sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"
    local public_dir="${base}/public_html"
    local releases="${base}/releases"
    [[ -d "$releases" ]] || error "Release dizini yok: ${releases}"

    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")

    local current_real=""; [[ -L "$public_dir" ]] && current_real=$(readlink -f "$public_dir" 2>/dev/null || true)
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
    _deploy_reload_fpm "$php_version" "$sname"

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
    [[ -L "${base}/public_html" ]] && current_real=$(readlink -f "${base}/public_html" 2>/dev/null || true)
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
    local current_real=""; [[ -L "${base}/public_html" ]] && current_real=$(readlink -f "${base}/public_html" 2>/dev/null || true)
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
