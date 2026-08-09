#!/bin/bash
# ═══════════════════════════════════════════════
#  selfupdate.sh — srvctl Self-Update
# ═══════════════════════════════════════════════
#
# GÜVENLİK MODELİ (denetim DALGA 6 — bkz. rapor Y2/O13 KRİTİK):
#
# ESKİ DAVRANIŞ neydi: 'git clone --depth 1 "$SRVCTL_REPO" /tmp/srvctl-update'
# ile HER ZAMAN uzak default branch'in O ANKİ HEAD'i çekilip HİÇBİR bütünlük
# doğrulaması yapılmadan (imza yok, checksum yok, pinned commit yok) doğrudan
# 'cp -f' ile ROOT olarak /usr/local/srvctl'e yazılıyordu. Bu, GitHub
# hesabının/repo'nun ele geçirilmesini "self-update çalıştıran her sunucuda
# anında root" haline getiren bir tedarik zinciri deliğiydi; üstüne '/tmp'
# sabit yolu K4 sınıfı bir symlink/pre-plant riski taşıyordu.
#
# YENİ MODEL — pinned-commit + iki adımlı TOFU (Trust-On-First-Use):
#   1) 'srvctl self-update check' uzak HEAD'in TAM (40 hex) commit hash'ini
#      OKUR ve root-only bir state dosyasına ("pin") YAZAR. Bu, operatörün
#      "ŞU AN gördüğüm bu" dediği andır.
#   2) 'srvctl self-update run' o pin dosyasını okur ve klonu SADECE o TAM
#      hash'e sabitler — "ne varsa getir" DEĞİL, "TAM OLARAK BU hash'i getir,
#      başka hiçbir şeyi KABUL ETME". HEAD karşılaştırması ile TEKRAR
#      doğrulanır; uyuşmazlıkta HİÇBİR DOSYA kuruluma kopyalanmaz (fail-closed).
#   3) Pinlenmiş commit bir git tag'ine karşılık geliyorsa VE o tag GPG imzalı
#      ise ('git tag -v') bu ayrıca doğrulanır (best-effort katman — repo şu an
#      imzalı tag YAYINLAMIYORSA yalnızca bilgilendirici bir uyarı basılır,
#      engellemez; maintainer ileride imzalı tag yayınlamaya başlarsa kod
#      DEĞİŞMEDEN otomatik sıkılaşır).
#
# DÜRÜST SINIR: bu GERÇEK bir imza zinciri (GPG/Sigstore) DEĞİLDİR. Repo/GitHub
# hesabı 'check' anından ÖNCE zaten ele geçirilmişse bu katman bunu YAKALAMAZ
# (imzasız git'in doğası budur). Kazanılan şey: (a) "check" ile "run" arasındaki
# pencerede içerik SESSİZCE değişemez — repo ele geçirilip force-push edilse
# bile 'run' hâlâ operatörün GÖRDÜĞÜ eski/iyi commit'i kurar; (b) "her zaman
# en son HEAD'i kör kur" davranışı tamamen kaldırıldı, açık bir operatör
# onayı (check) ZORUNLU hale getirildi; (c) tag imzalama başladığında sıfır
# kod değişikliğiyle gerçek kriptografik doğrulamaya geçilir.
#
# '/tmp' KULLANILMAZ: git klon çalışma alanı SRVCTL_ROOT İÇİNDE
# ('mktemp -d "${SRVCTL_ROOT}/.selfupdate-clone.XXXXXX"') oluşturulur.
# SRVCTL_ROOT (755 root:root — install.sh'ın varsayılan umask'ıyla) yalnızca
# root tarafından yazılabilir; bu, Debian/Ubuntu'da '/usr/local'ın KENDİSİNİN
# 'root:staff 2775' (grup-yazılabilir) olmasından BAĞIMSIZDIR — bir alt
# dizinin yazılabilirliği kendi modundan gelir, ebeveynin grup-yazılabilirliği
# alt dizine SIZMAZ. Bu yüzden yedekler de ('.backups/') ve pin dosyası da
# SRVCTL_ROOT altında tutulur; '/usr/local/srvctl.backup.*' gibi bir SIBLING
# isim KULLANILMAZ (o, tam da '/usr/local'ın grup-yazılabilirliğine maruz
# kalırdı — aynı K4 sınıfının incelikli bir varyantı).
# ───────────────────────────────────────────────────────────────

SRVCTL_REPO="https://github.com/bertugfahriozer/srvctl.git"

# 'check' burayı YAZAR, 'run' burayı OKUR (root-only, 600).
SRVCTL_SELFUPDATE_PIN="${SRVCTL_ROOT}/.selfupdate-pending"
# Yalnız self-update'in dokunduğu yollar burada yedeklenir (bkz. O12 notu:
# conf/srvctl.conf ASLA buraya kopyalanmaz).
SRVCTL_SELFUPDATE_BACKUPS="${SRVCTL_ROOT}/.backups"
SRVCTL_CURRENT_COMMIT="${SRVCTL_ROOT}/.current-commit"

cmd_selfupdate() {
    require_root
    case "${1:-run}" in
        check)     _selfupdate_check ;;
        run)       _selfupdate_run ;;
        rollback)  _selfupdate_rollback "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl self-update [check|run|rollback]"
            echo ""
            echo "    check              Yeni sürüm var mı kontrol et ve PİNLE"
            echo "    run                Pinlenmiş güncellemeyi uygula (varsayılan)"
            echo "    rollback [ad]      Son (veya belirtilen) yedeğe geri dön"
            echo ""
            echo "  NOT: 'run', ÖNCE 'check' çalıştırılmasını ZORUNLU kılar —"
            echo "  klon her zaman 'check' anında görülen TAM commit hash'ine sabitlenir."
            echo ""
            echo "  NEDEN İKİ AŞAMALI: indirilecek içerik önce ('check' ile) görülüp TAM"
            echo "  commit hash'ine SABİTLENMEDEN kurulmaz — aksi halde 'check' ile 'run'"
            echo "  arasındaki pencerede repo ele geçirilip içerik SESSİZCE değiştirilebilirdi."
            echo "  Pin dosyası yoksa 'run' HİÇBİR ŞEY KURMADAN durur ve bunu açıkça bildirir."
            echo ""
            ;;
    esac
}

# ─── URL şema doğrulaması (defense-in-depth) ───
# SRVCTL_REPO şu an sabit bir https:// sabiti olsa da, gelecekte
# yapılandırılabilir hale gelirse (ör. kurumsal bir fork/mirror) bu kapı
# ext::/file::/option-injection sınıfı git RCE'lerini baştan reddeder —
# bkz. lib/deploy.sh:_deploy_validate_repo_url (aynı desen, o dosyaya
# DOKUNMADAN burada bağımsız bir kopyası tutulur — cross-module fonksiyon
# çağrısı yalnızca guard'lı source ile mümkündür, gereksiz bağımlılık
# eklenmez).
_selfupdate_validate_repo_url() {
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

# Pin dosyasının sahiplik/izin kontrolü. core.sh'ın assert_root_owned_path'i
# KULLANILAMAZ — o yürüyüşü WEB_ROOT'a kadar yapar (domain credentials/meta
# için tasarlanmış); bizim dosyamız SRVCTL_ROOT altında, WEB_ROOT'un dışında.
# Tek seviyeli kendi kontrolümüz: hem SRVCTL_ROOT hem dosyanın kendisi root
# sahipli, symlink değil, grup/diğer yazılabilir DEĞİL olmalı.
_selfupdate_assert_pin_owned() {
    local f="$1"
    [[ -e "$f" && ! -L "$f" ]] || return 1
    [[ "$(_stat_owner "$f")" == "root" ]] || return 1
    local mode last2 grp oth
    mode="$(_stat_mode "$f")"
    last2="${mode: -2}"
    grp="${last2:0:1}"; oth="${last2:1:1}"
    (( (grp & 2) == 0 )) || return 1
    (( (oth & 2) == 0 )) || return 1
    [[ ! -L "$SRVCTL_ROOT" ]] || return 1
    [[ "$(_stat_owner "$SRVCTL_ROOT")" == "root" ]] || return 1
    return 0
}

_selfupdate_check() {
    header "srvctl Güncelleme Kontrolü"

    _selfupdate_validate_repo_url "$SRVCTL_REPO" \
        || error "Güvensiz SRVCTL_REPO reddedildi: ${SRVCTL_REPO}"

    # Kanonik sürüm kaynağı: lib/core.sh HER ZAMAN bin/srvctl tarafından
    # önce source edilmiştir — SRVCTL_VERSION burada hazır bir global'dir.
    # ESKİ davranış bin/srvctl'in '# Versiyon: X' YORUMUNU grep ediyordu;
    # bu yorum ile lib/core.sh:SRVCTL_VERSION senkron kalacağının garantisi
    # yoktu (bkz. rapor). Artık TEK kaynak core.sh.
    info "Mevcut sürüm: ${SRVCTL_VERSION}"

    # BUG (bu düzeltmeyle KAPATILDI): 'git ls-remote' ağ hatasıyla (nonzero)
    # başarısız olduğunda, 'set -euo pipefail' altında salt '$(...)' ataması
    # ('|| true' OLMADAN) errexit'i TETİKLER — script hiçbir mesaj basmadan
    # çıplak bir exit koduyla SESSİZCE ölür; aşağıdaki "Uzak repo'ya
    # erişilemedi" uyarısı hiçbir zaman ÇALIŞTIRILAMAZDI (dead code). Aynı
    # sessiz-ölüm sınıfı, pin dosyası eksikken 'run'ın yaşadığı sorunla
    # BİREBİR aynıdır — burada da '|| true' ile öldürülüyor.
    local remote_hash
    remote_hash=$(GIT_ALLOW_PROTOCOL='https:ssh:git' git ls-remote "$SRVCTL_REPO" HEAD 2>/dev/null | awk '{print $1}') || true
    if [[ -z "$remote_hash" ]]; then
        warn "Uzak repo'ya erişilemedi. İnternet bağlantınızı kontrol edin."
        return 1
    fi
    if [[ ! "$remote_hash" =~ ^[0-9a-f]{40}$ ]]; then
        warn "Uzak repodan beklenmeyen bir yanıt geldi (geçerli bir commit hash değil) — pinlemedi."
        return 1
    fi

    if [[ -f "$SRVCTL_CURRENT_COMMIT" ]] && [[ "$(cat "$SRVCTL_CURRENT_COMMIT" 2>/dev/null)" == "$remote_hash" ]]; then
        success "srvctl güncel. (${remote_hash:0:8})"
    else
        info "Yeni sürüm mevcut olabilir!"
        if [[ -f "$SRVCTL_CURRENT_COMMIT" ]]; then
            info "  Yerel:  $(cut -c1-8 "$SRVCTL_CURRENT_COMMIT" 2>/dev/null)"
        else
            info "  Yerel:  bilinmiyor (yerel sürüm kaydı yok)"
        fi
        info "  Uzak:   ${remote_hash:0:8}"
    fi

    # ── GÜVENLİK: pinned-commit yaz (TOFU) — bkz. dosya başı GÜVENLİK MODELİ ──
    (
        umask 077
        printf 'PINNED_COMMIT=%s\nPINNED_AT=%s\nPINNED_REPO=%s\n' \
            "$remote_hash" "$(date '+%Y-%m-%d %H:%M:%S')" "$SRVCTL_REPO" \
            > "$SRVCTL_SELFUPDATE_PIN"
    )
    chown root:root "$SRVCTL_SELFUPDATE_PIN" 2>/dev/null || true
    chmod 600 "$SRVCTL_SELFUPDATE_PIN"

    echo ""
    info "Pinlendi: ${remote_hash:0:8} — uygulamak için: sudo srvctl self-update run"
    echo ""
}

# Pin BAYAT mı? — yalnız UYARIR, ENGELLEMEZ (bkz. dosya başı GÜVENLİK MODELİ
# ve _selfupdate_run'daki çağrı noktasındaki gerekçe). Ağ erişilemezse veya
# yanıt geçerli bir 40-hex hash değilse SESSİZCE atlanır (best-effort — asıl
# bütünlük garantisi zaten _selfupdate_fetch_pinned'deki hash eşleşmesidir,
# bu fonksiyon yalnız bir operatör-bilgilendirme katmanıdır).
_selfupdate_warn_if_pin_stale() {
    local repo_url="$1" pinned_commit="$2"
    # '|| true': ağ erişilemezse 'git ls-remote' nonzero döner — 'set -e'
    # altında '|| true' OLMADAN bu atama _selfupdate_run'ı SESSİZCE
    # sonlandırırdı (bkz. _selfupdate_check'teki AYNI sınıf düzeltme, birkaç
    # satır yukarıda). Bu fonksiyon zaten best-effort'tur: hata durumunda
    # 'remote_head_now' boş kalır, aşağıdaki koşul false olur, sessizce devam edilir.
    local remote_head_now
    remote_head_now=$(GIT_ALLOW_PROTOCOL='https:ssh:git' git ls-remote "$repo_url" HEAD 2>/dev/null | awk '{print $1}') || true
    if [[ "$remote_head_now" =~ ^[0-9a-f]{40}$ ]] && [[ "$remote_head_now" != "$pinned_commit" ]]; then
        warn "NOT: pinlendiğinden beri uzak repo ilerlemiş (uzak HEAD şimdi: ${remote_head_now:0:8})."
        warn "Bu çalıştırma yine de PİNLENMİŞ commit'i (${pinned_commit:0:8}) kuracak — TOFU modelinin gereği."
        warn "En güncel commit'i almak isterseniz: sudo srvctl self-update check (yeniden pinler)"
    fi
    return 0
}

# ─── Pinlenmiş TAM commit hash'ini staging'e getirir + doğrular ───
# Birincil yol: 'fetch <sha>' — GitHub.com (uploadpack.allowReachableSHA1InWant)
# rastgele erişilebilir SHA'ları fetch etmeye izin verir. Bu durumda bütünlük
# git'in KENDİ nesne hash doğrulamasından gelir: sunucu farklı bir içerik
# verirse fetch/unpack sırasında hash uyuşmazlığı ile BAŞARISIZ olur — yani
# "bu hash'i iste" == "bu TAM baytları al ya da hiç alma". Sunucu SHA-fetch'i
# desteklemiyorsa (nadir) tam geçmişe düşülür. HER İKİ yolda da sonunda
# 'rev-parse HEAD' PINNED_COMMIT ile AÇIKÇA karşılaştırılır; uyuşmazlıkta 1
# döner ve çağıran (yalnız _selfupdate_run) hiçbir dosyayı kopyalamaz.
_selfupdate_fetch_pinned() {
    local repo_url="$1" pinned_commit="$2" dest="$3"

    GIT_ALLOW_PROTOCOL='https:ssh:git' git clone -q --depth 1 -- "$repo_url" "$dest" 2>/dev/null \
        || { warn "Klon başarısız (ağ/repo erişimi?)"; return 1; }

    if ! GIT_ALLOW_PROTOCOL='https:ssh:git' git -C "$dest" fetch -q --depth 1 origin "$pinned_commit" 2>/dev/null; then
        warn "SHA-bazlı fetch desteklenmiyor/başarısız — tüm geçmiş çekiliyor..."
        GIT_ALLOW_PROTOCOL='https:ssh:git' git -C "$dest" fetch -q --unshallow origin 2>/dev/null \
            || GIT_ALLOW_PROTOCOL='https:ssh:git' git -C "$dest" fetch -q origin 2>/dev/null \
            || { warn "Tam geçmiş de çekilemedi."; return 1; }
    fi

    if ! git -C "$dest" checkout -q "$pinned_commit" 2>/dev/null; then
        warn "Pinlenmiş commit uzak repoda bulunamadı (force-push/rebase olmuş olabilir)."
        warn "Yeniden pinlemek için: sudo srvctl self-update check"
        return 1
    fi

    local actual_head
    actual_head="$(git -C "$dest" rev-parse HEAD 2>/dev/null)"
    if [[ "$actual_head" != "$pinned_commit" ]]; then
        warn "GÜVENLİK: klonun HEAD'i (${actual_head:0:8}) pinlenmiş commit (${pinned_commit:0:8}) ile EŞLEŞMİYOR"
        log_action "SECURITY: selfupdate hash mismatch expected=${pinned_commit} actual=${actual_head}"
        return 1
    fi
    return 0
}

# Best-effort: pinlenmiş commit bir git tag'ine karşılık geliyorsa VE o tag
# GPG imzalıysa doğrula. Opsiyoneldir — bulunamazsa/doğrulanamazsa yalnız
# UYARIR, ENGELLEMEZ (asıl bütünlük garantisi yukarıdaki pinned-commit
# eşleşmesidir).
_selfupdate_verify_tag_signature() {
    local dest="$1" pinned_commit="$2"
    GIT_ALLOW_PROTOCOL='https:ssh:git' git -C "$dest" fetch -q --tags origin 2>/dev/null || true
    local tag
    # '|| true': 'git tag' başarısız olursa (nadir), 'set -e' altında bu
    # best-effort fonksiyonu SESSİZCE ÇÖKERTİP _selfupdate_run'ı yarıda
    # keserdi — aynı sınıf düzeltme (bkz. _selfupdate_check/_selfupdate_warn_if_pin_stale).
    tag="$(git -C "$dest" tag --points-at "$pinned_commit" 2>/dev/null | head -1)" || true
    if [[ -z "$tag" ]]; then
        info "Bu commit'e karşılık gelen bir git tag'i yok — imza doğrulaması atlandı (yalnız pinned-commit eşleşmesi uygulandı)."
        return 0
    fi
    if git -C "$dest" tag -v "$tag" &>/dev/null; then
        success "GPG imzalı tag doğrulandı: ${tag}"
    else
        warn "Tag '${tag}' bulundu ama GPG imzası doğrulanamadı (imzasız tag veya güvenilir anahtar yok) — yalnız pinned-commit eşleşmesine güveniliyor."
    fi
}

# ───────────────────────────────────────────────────────────────
#  self-update'in yönettiği VERİ config'leri (kullanıcı AYARI DEĞİL).
#
#  Ayrım şudur: conf/srvctl.conf OPERATÖRÜN dosyasıdır (sırlar/ayarlar) ve
#  self-update ona ASLA dokunmaz. Buradaki dosyalar ise srvctl'in KENDİ veri
#  tabloları — sürümle birlikte gelirler ve install.sh her kurulumda üzerine
#  yazar (bkz. install.sh:170 ve :209 yorumları).
#
#  NEDEN LİSTE (tek satır yerine): bu dosyalar ÜÇ ayrı yerde ele alınmalı —
#  yedekle, kur, geri yükle. Üçü elle senkron tutulduğunda asimetri kaçınılmaz
#  oldu: 'rate-profiles.conf' üçünde de vardı ama 'resource-profiles.conf'
#  HİÇBİRİNDE yoktu. Sonuç sessizdi — install.sh ile kuranlar profil dosyasını
#  alıyor, 'self-update' ile güncelleyenler ALMIYORDU; profil değerleri
#  değiştiğinde bu ikinci grup sessizce eski tabloda kalır ve
#  resource_profile_load (lib/core.sh) dosya bulunamadığında gömülü
#  varsayılanlara düşerek farkı GİZLERDİ. Yeni bir veri config'i eklenirken
#  yalnız bu diziye eklemek yeterlidir.
_SELFUPDATE_DATA_CONFS=(rate-profiles.conf resource-profiles.conf)

# Yalnız self-update'in DOKUNDUĞU yolları yedekler: bin/lib/templates/
# completions + conf/ veri tabloları + .current-commit. conf/srvctl.conf
# ASLA yedeklenmez (bkz. O12: eski davranış REDIS_ADMIN_PASS/CF_API_TOKEN
# içeren srvctl.conf'u her güncellemede yeni bir '.backup.*' kopyasına
# TAŞIYIP HİÇBİRİNİ silmiyordu → sınırsız sır birikimi). Yedek SRVCTL_ROOT/
# .backups/<ts>/ altında (root-only, secure_dir 700).
_selfupdate_backup_current() {
    local ts dir
    ts="$(date +%Y%m%d_%H%M%S)"
    dir="${SRVCTL_SELFUPDATE_BACKUPS}/${ts}"
    secure_dir "$SRVCTL_SELFUPDATE_BACKUPS" 700
    secure_dir "$dir" 700

    # KULLANILABİLİRLİK DÜZELTMESİ: eskiden 'cp -a ... 2>/dev/null || return 1'
    # cp'nin KENDİ hata mesajını da yutuyordu — çağıran (_selfupdate_run) yalnız
    # "Yedekleme başarısız — güncelleme iptal edildi." diyordu, HANGİ alt dizinin
    # NEDEN kopyalanamadığı (disk dolu/izin) hiçbir yerde görünmüyordu. Artık
    # başarısızlık öncesi 'warn' ile teşhis basılıyor (STDOUT'taki 'error' özeti
    # ile birlikte okununca eksiksiz bir tanı verir).
    local sub
    for sub in bin lib templates completions; do
        if [[ -d "${SRVCTL_ROOT}/${sub}" ]]; then
            if ! cp -a "${SRVCTL_ROOT}/${sub}" "${dir}/${sub}" 2>/dev/null; then
                warn "Yedekleme başarısız: '${sub}' → '${dir}/${sub}' kopyalanamadı (disk dolu veya izin sorunu olabilir)."
                return 1
            fi
        fi
    done
    local dataconf
    for dataconf in "${_SELFUPDATE_DATA_CONFS[@]}"; do
        if [[ -f "${SRVCTL_ROOT}/conf/${dataconf}" ]]; then
            mkdir -p "${dir}/conf"
            cp -a "${SRVCTL_ROOT}/conf/${dataconf}" "${dir}/conf/${dataconf}" 2>/dev/null || true
        fi
    done
    if [[ -f "$SRVCTL_CURRENT_COMMIT" ]]; then
        cp -a "$SRVCTL_CURRENT_COMMIT" "${dir}/.current-commit" 2>/dev/null || true
    fi
    chmod -R go-rwx "$dir" 2>/dev/null || true
    echo "$dir"
}

# staging'den canlı kuruluma dosyaları kopyalar. conf/srvctl.conf'a
# KESİNLİKLE DOKUNULMAZ (ayarlar/sırlar korunur). conf/ altındaki VERİ
# tabloları (_SELFUPDATE_DATA_CONFS — kullanıcı ayarı DEĞİL) install.sh ile
# aynı tutarlılıkla güncellenir; hangi dosyaların bu sınıfa girdiği ve neden
# tek bir listeden yönetildiği için bkz. o dizinin başlık yorumu.
_selfupdate_install_from_staging() {
    local staging="$1"

    cp -f "${staging}/bin/srvctl" "${SRVCTL_ROOT}/bin/srvctl"
    chmod +x "${SRVCTL_ROOT}/bin/srvctl"

    cp -f "${staging}/lib/"*.sh "${SRVCTL_ROOT}/lib/" 2>/dev/null || true
    chmod +x "${SRVCTL_ROOT}"/lib/*.sh 2>/dev/null || true

    if [[ -d "${staging}/templates" ]]; then
        cp -rf "${staging}/templates/"* "${SRVCTL_ROOT}/templates/" 2>/dev/null || true
    fi

    if [[ -d "${staging}/completions" ]]; then
        cp -f "${staging}/completions/"* "${SRVCTL_ROOT}/completions/" 2>/dev/null || true
    fi

    local dataconf
    for dataconf in "${_SELFUPDATE_DATA_CONFS[@]}"; do
        if [[ -f "${staging}/conf/${dataconf}" ]]; then
            mkdir -p "${SRVCTL_ROOT}/conf"
            cp -f "${staging}/conf/${dataconf}" "${SRVCTL_ROOT}/conf/${dataconf}" 2>/dev/null || true
        fi
    done
}

# Kurulum sonrası duman testi. Herhangi biri başarısız olursa 1 döner —
# çağıran (_selfupdate_run) bunu OTOMATİK rollback tetiklemek için kullanır.
_selfupdate_health_check() {
    local f rc=0

    for f in "${SRVCTL_ROOT}"/lib/*.sh "${SRVCTL_ROOT}/bin/srvctl"; do
        [[ -f "$f" ]] || continue
        bash -n "$f" 2>/dev/null || { warn "Sözdizimi hatası: ${f}"; rc=1; }
    done

    if command -v nginx &>/dev/null; then
        nginx -t &>/dev/null || { warn "'nginx -t' başarısız."; rc=1; }
    fi

    if ! "${SRVCTL_ROOT}/bin/srvctl" version &>/dev/null; then
        warn "'srvctl version' çalışmıyor."
        rc=1
    fi

    return "$rc"
}

# Son N (varsayılan 3) hariç .backups/* dizinlerini siler. SELFUPDATE_KEEP_BACKUPS
# ortam değişkeniyle override edilebilir — bkz. rapor: bu bir load_config
# adayı, core.sh senin dosyan olmadığından kalıcı config anahtarı EKLENMEDİ,
# yalnız '${VAR:-varsayılan}' fallback deseni kullanıldı.
_selfupdate_prune_backups() {
    local keep="${SELFUPDATE_KEEP_BACKUPS:-3}"
    [[ -d "$SRVCTL_SELFUPDATE_BACKUPS" ]] || return 0

    local idx=0 name full
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        idx=$((idx + 1))
        (( idx <= keep )) && continue
        full="${SRVCTL_SELFUPDATE_BACKUPS}/${name}"
        [[ -L "$full" ]] && continue
        [[ -d "$full" ]] || continue
        rm -rf -- "$full"
    done < <(find "$SRVCTL_SELFUPDATE_BACKUPS" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -r)
}

# Bir yedek dizininden bin/lib/templates/completions/conf/rate-profiles.conf/
# .current-commit'i canlı kuruluma geri yazar. Hem otomatik (sağlık kontrolü
# başarısız → _selfupdate_run) hem manuel ('self-update rollback') yoldan
# çağrılır. Alt dizinler ÖNCE SİLİNİR SONRA kopyalanır (basit overlay DEĞİL) —
# aksi halde kötü güncellemenin EKLEDİĞİ ama yedekte OLMAYAN dosyalar (ör. yeni
# bir lib/*.sh) rollback sonrası kurulumda KALIRDI.
_selfupdate_restore_from_backup() {
    local dir="$1"
    [[ -d "$dir" && ! -L "$dir" ]] || { warn "Yedek dizini geçersiz: ${dir}"; return 1; }
    [[ "$(_stat_owner "$dir")" == "root" ]] || { warn "GÜVENLİK: yedek root sahipli değil, reddedildi: ${dir}"; return 1; }

    local sub
    for sub in bin lib templates completions; do
        if [[ -d "${dir}/${sub}" ]]; then
            rm -rf "${SRVCTL_ROOT:?}/${sub:?}"
            cp -a "${dir}/${sub}" "${SRVCTL_ROOT}/${sub}"
        fi
    done
    chmod +x "${SRVCTL_ROOT}/bin/srvctl" 2>/dev/null || true
    chmod +x "${SRVCTL_ROOT}"/lib/*.sh 2>/dev/null || true

    local dataconf
    for dataconf in "${_SELFUPDATE_DATA_CONFS[@]}"; do
        if [[ -f "${dir}/conf/${dataconf}" ]]; then
            cp -a "${dir}/conf/${dataconf}" "${SRVCTL_ROOT}/conf/${dataconf}"
        fi
    done
    if [[ -f "${dir}/.current-commit" ]]; then
        cp -a "${dir}/.current-commit" "$SRVCTL_CURRENT_COMMIT"
    fi
    return 0
}

_selfupdate_run() {
    header "srvctl Güncelleme"

    command -v git &>/dev/null || error "git kurulu değil. Kurun: apt install git"
    _selfupdate_validate_repo_url "$SRVCTL_REPO" \
        || error "Güvensiz SRVCTL_REPO reddedildi: ${SRVCTL_REPO}"

    local current_version="${SRVCTL_VERSION}"
    info "Mevcut sürüm: ${current_version}"

    # ── 1. Pinlenmiş commit'i oku (GÜVENLİK: 'check' ÖNCE çalıştırılmış olmalı) ──
    # KULLANILABİLİRLİK DÜZELTMESİ (üretimde ölçüldü — bkz. rapor): bu dal
    # önceden yalnız 'error' ile TEK satırlık bir mesaj basıyordu. 'error'
    # STDERR'e yazar (bkz. core.sh) ve script burada exit 1 ile durur; yalnız
    # STDOUT'u yakalayan bir log/izleme kurulumunda ('srvctl self-update run
    # >> log.txt' — '2>&1' OLMADAN) operatör "Mevcut sürüm: X" satırından
    # sonra HİÇBİR ŞEY görmüyor, NEDENİNİ asla öğrenemiyordu. Düzeltme: asıl
    # açıklama artık STDOUT'a ('info') basılıyor — hangi akış yakalanırsa
    # yakalansın görünür olsun diye — son satır yine 'error' ile hem STDERR'e
    # tekrarlanıp hem de exit 1 ile script sonlandırılıyor.
    if [[ ! -f "$SRVCTL_SELFUPDATE_PIN" ]]; then
        echo ""
        info "Pinlenmiş bir güncelleme bulunamadı — 'run' HİÇBİR DOSYAYI DEĞİŞTİRMEDEN durdu."
        info "self-update İKİ AŞAMALI çalışır (bilinçli güvenlik tasarımı):"
        info "  1) sudo srvctl self-update check   → uzak HEAD'in TAM commit hash'ini okur ve PİNLER"
        info "  2) sudo srvctl self-update run     → SADECE o pinlenmiş hash'i indirir, doğrular, kurar"
        info "Neden: indirilecek içerik önce ('check' ile) görülüp SABİTLENMEDEN kurulursa,"
        info "'check' ile 'run' arasında repo ele geçirilip içerik SESSİZCE değiştirilebilirdi."
        echo ""
        error "Önce çalıştırın: sudo srvctl self-update check"
    fi
    _selfupdate_assert_pin_owned "$SRVCTL_SELFUPDATE_PIN" \
        || error "GÜVENLİK: ${SRVCTL_SELFUPDATE_PIN} root sahipli/izinli değil (tamper olabilir). Reddedildi — 'sudo srvctl self-update check' ile yeniden pinleyin."

    local PINNED_COMMIT="" PINNED_AT="" PINNED_REPO=""
    read_kv_file "$SRVCTL_SELFUPDATE_PIN" PINNED_COMMIT PINNED_AT PINNED_REPO
    [[ -n "$PINNED_COMMIT" ]] \
        || error "Pin dosyası bozuk (PINNED_COMMIT eksik). 'sudo srvctl self-update check' ile yeniden pinleyin."
    [[ "$PINNED_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
        || error "Pin dosyası bozuk (geçersiz commit hash biçimi): ${PINNED_COMMIT}. 'sudo srvctl self-update check' ile yeniden pinleyin."
    if [[ -n "$PINNED_REPO" && "$PINNED_REPO" != "$SRVCTL_REPO" ]]; then
        error "GÜVENLİK: pin farklı bir repo için alınmış (${PINNED_REPO} ≠ ${SRVCTL_REPO}). Reddedildi — 'sudo srvctl self-update check' ile yeniden pinleyin."
    fi

    info "Pinlenmiş commit uygulanacak: ${PINNED_COMMIT:0:8} (pinlendi: ${PINNED_AT:-bilinmiyor})"
    # ── Bilgilendirme: pin BAYAT olabilir mi? (uzak HEAD pinlendiğinden beri
    #    ilerlemiş olabilir). Bu SADECE bilgilendirmedir — ENGELLEMEZ: TOFU
    #    modelinin özü "operatörün 'check' anında GÖRDÜĞÜ TAM O commit'i kur"
    #    olduğundan, pin bayat diye sessizce en yeni HEAD'e ATLAMAK TOFU'yu
    #    by-pass eder, pin bayat diye kurulumu DURDURMAK ise operatörün zaten
    #    onayladığı bir işlemi gereksiz yere engeller. Doğru davranış: haber
    #    ver, kararı operatöre bırak (bkz. dosya başı GÜVENLİK MODELİ).
    _selfupdate_warn_if_pin_stale "$PINNED_REPO" "$PINNED_COMMIT"

    # ── 2. Mevcut kurulumun YEDEĞİ (staging oluşturulmadan ÖNCE — bkz. aşağıdaki
    #      not: staging '.selfupdate-clone.*' adı hiçbir kopyalama globuna
    #      uymadığından zaten yedeğe karışmazdı, ama önce almak daha temiz:
    #      yedek her zaman "son bilinen iyi durum"u yansıtır). ──
    local backup_dir
    backup_dir="$(_selfupdate_backup_current)" || error "Yedekleme başarısız — güncelleme iptal edildi."
    info "Mevcut kurulum yedeklendi → ${backup_dir}"

    # ── 3. Root-only klon çalışma dizini (GÜVENLİK: '/tmp' KULLANILMAZ) ──
    # bkz. dosya başı GÜVENLİK MODELİ notu.
    local staging
    staging="$(mktemp -d "${SRVCTL_ROOT}/.selfupdate-clone.XXXXXX")" \
        || error "Geçici klon dizini oluşturulamadı."
    chmod 700 "$staging"
    # shellcheck disable=SC2064
    trap "rm -rf -- '${staging}'" EXIT INT TERM

    # ── 4. Pinlenmiş commit'i klonla + doğrula ──
    step "1/5" "Pinlenmiş commit çekiliyor: ${PINNED_COMMIT:0:8}..."
    if ! _selfupdate_fetch_pinned "$PINNED_REPO" "$PINNED_COMMIT" "$staging"; then
        error "Pinlenmiş commit çekilemedi/doğrulanamadı — güncelleme iptal edildi (fail-closed). Hiçbir dosya değiştirilmedi."
    fi
    success "Doğrulandı: klonun HEAD'i pinlenmiş commit ile TAM eşleşiyor (${PINNED_COMMIT:0:8})"
    _selfupdate_verify_tag_signature "$staging" "$PINNED_COMMIT"

    # ── 5. Dosyaları kopyala ──
    step "2/5" "Dosyalar güncelleniyor..."
    _selfupdate_install_from_staging "$staging"

    # ── 6. Sağlık kontrolü — başarısızsa OTOMATİK rollback (fail-closed) ──
    step "3/5" "Sağlık kontrolü çalıştırılıyor (bash -n, nginx -t, srvctl version)..."
    if ! _selfupdate_health_check; then
        warn "Sağlık kontrolü BAŞARISIZ — otomatik geri alınıyor (rollback)..."
        if _selfupdate_restore_from_backup "$backup_dir"; then
            log_action "SECURITY: self-update health check failed, auto-rolled-back (pinned=${PINNED_COMMIT})"
            error "Güncelleme geri alındı. Kurulum ÖNCEKİ sürüme (${current_version}) döndürüldü. Yedek: ${backup_dir}"
        else
            log_action "SECURITY: self-update health check failed AND rollback failed (pinned=${PINNED_COMMIT}, backup=${backup_dir})"
            error "KRİTİK: sağlık kontrolü başarısız VE otomatik rollback de başarısız oldu. Manuel müdahale gerekli — yedek: ${backup_dir}"
        fi
    fi
    success "Sağlık kontrolü geçti."

    # ── 7. Commit hash'i + pin dosyasını finalize et ──
    echo "$PINNED_COMMIT" > "$SRVCTL_CURRENT_COMMIT"
    rm -f "$SRVCTL_SELFUPDATE_PIN"

    # '|| true': 'grep -m1' EŞLEŞME BULAMAZSA nonzero döner — 'set -e' altında
    # bu, dosyalar ZATEN başarıyla kurulmuş VE sağlık kontrolünden geçmiş
    # olsa BİLE, script'i tam bu noktada SESSİZCE keserdi: "Tamamlandı" banner'ı,
    # yedek temizliği, changelog kaydı ve 'domain repair --all' daveti HİÇ
    # ÇALIŞMAZ; operatör güncellemenin BAŞARISIZ olduğunu SANIR (oysa dosyalar
    # kuruludur). Aşağıdaki "[[ -n ]] || bilinmiyor" düşme-yolu tam da bunun
    # için vardı ama '|| true' olmadan asla ÇALIŞTIRILAMAZDI.
    local new_version
    new_version="$(grep -m1 '^SRVCTL_VERSION=' "${SRVCTL_ROOT}/lib/core.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')" || true
    [[ -n "$new_version" ]] || new_version="bilinmiyor"

    step "4/5" "Eski yedekler temizleniyor (son ${SELFUPDATE_KEEP_BACKUPS:-3} tutulur)..."
    _selfupdate_prune_backups

    # Cross-module: yalnız guard'lı source (bkz. CLAUDE.md deseni,
    # lib/domain.sh:_domain_purge_resources'un backup.sh'ı source etmesiyle
    # aynı desen). ESKİ kod var olmayan 'changelog_write' adında bir fonksiyonu
    # çağırıyordu (gerçek adı 'log_to_changelog'dur) — bu 'declare -f' kontrolü
    # HER ZAMAN false dönüyordu, yani changelog kaydı hiçbir zaman yazılmıyordu.
    # Düzeltildi.
    source "${SRVCTL_ROOT}/lib/changelog.sh" 2>/dev/null || true
    if declare -f log_to_changelog &>/dev/null; then
        log_to_changelog "SELF-UPDATE: ${current_version} → ${new_version} (${PINNED_COMMIT:0:8})"
    fi
    log_action "SELF-UPDATE: ${current_version} -> ${new_version} (${PINNED_COMMIT})"

    step "5/5" "Tamamlandı"
    success "srvctl güncellendi!"
    info "  Eski: ${current_version}"
    info "  Yeni: ${new_version} (${PINNED_COMMIT:0:8})"
    info "  Yedek: ${backup_dir}"
    echo ""
    warn "NOT: conf/srvctl.conf ayarlarınıza/sırlarınıza dokunulmadı."
    warn "NOT: conf/rate-profiles.conf güncellendi (veri dosyasıdır, kullanıcı ayarı değil)."
    echo ""
    warn "ÖNEMLİ — CONFIG DRIFT: şablonlar (nginx/apparmor/php-fpm/systemd) güncellenmiş"
    warn "olabilir ama MEVCUT domain config'leri OTOMATİK yeniden üretilmez. Bir güvenlik"
    warn "düzeltmesinin TÜM domain'lere ulaşması için ÇALIŞTIRIN:"
    warn "  sudo srvctl domain repair --all"
    echo ""

    # Mümkünse otomatik çağır — ama unattended/cron tetiklemeli bir
    # self-update'te 'domain repair --all' servis yeniden başlatmaları
    # tetikleyebileceğinden (nginx reload, FPM pool restart vb.) bunu operatör
    # ONAYI olmadan ZORLA çalıştırmak sürpriz bir kesintiye yol açabilir.
    # Interaktif değilse (stdin tty değil) 'confirm' zaten 'hayır' sayar ve
    # yukarıdaki NET talimat operatöre kalır.
    if confirm "Şimdi 'srvctl domain repair --all' çalıştırılsın mı?"; then
        source "${SRVCTL_ROOT}/lib/domain.sh" 2>/dev/null || true
        if declare -f cmd_domain &>/dev/null; then
            cmd_domain repair --all
        else
            warn "lib/domain.sh yüklenemedi — manuel çalıştırın: sudo srvctl domain repair --all"
        fi
    else
        info "Atlandı. Unutmayın: sudo srvctl domain repair --all"
    fi
}

_selfupdate_rollback() {
    header "srvctl Rollback"

    [[ -d "$SRVCTL_SELFUPDATE_BACKUPS" ]] \
        || error "Hiç yedek bulunamadı: ${SRVCTL_SELFUPDATE_BACKUPS}"

    local target="${1:-}" name dir
    if [[ -n "$target" ]]; then
        # Path traversal reddi: yalnız basename benzeri bir ad kabul edilir.
        [[ "$target" =~ ^[0-9A-Za-z_.-]+$ ]] || error "Geçersiz yedek adı: ${target}"
        dir="${SRVCTL_SELFUPDATE_BACKUPS}/${target}"
        [[ -d "$dir" ]] || error "Yedek bulunamadı: ${dir}"
    else
        # '|| true': 'find' nadir bir I/O hatasıyla başarısız olursa bile bu
        # atama script'i SESSİZCE kesmesin — aşağıdaki "[[ -n ]] || error"
        # zaten hem "boş sonuç" hem "find başarısız" durumunu AÇIK bir mesajla
        # ele alıyor (aynı sınıf düzeltme, dosya geneli).
        name="$(find "$SRVCTL_SELFUPDATE_BACKUPS" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -r | head -1)" || true
        [[ -n "$name" ]] || error "Hiç yedek bulunamadı."
        dir="${SRVCTL_SELFUPDATE_BACKUPS}/${name}"
    fi

    info "Geri dönülecek yedek: ${dir}"
    confirm "Bu, mevcut bin/lib/templates/completions'ı bu yedekle DEĞİŞTİRECEK. Devam?" \
        || { info "İptal edildi."; return 0; }

    _selfupdate_restore_from_backup "$dir" || error "Rollback başarısız."

    if _selfupdate_health_check; then
        success "Rollback tamamlandı ve sağlık kontrolü geçti."
    else
        warn "Rollback tamamlandı AMA sağlık kontrolü YİNE başarısız — manuel inceleme gerekli."
    fi

    log_action "SELF-UPDATE ROLLBACK: restored from ${dir}"
    source "${SRVCTL_ROOT}/lib/changelog.sh" 2>/dev/null || true
    if declare -f log_to_changelog &>/dev/null; then
        log_to_changelog "SELF-UPDATE ROLLBACK: ${dir}"
    fi

    echo ""
    warn "Rollback şablonları/kodu geri aldı — domain config'lerini de eski haline"
    warn "döndürmek isterseniz: sudo srvctl domain repair --all"
    echo ""
}
