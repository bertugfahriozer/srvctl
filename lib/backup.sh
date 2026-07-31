#!/bin/bash
# ═══════════════════════════════════════════════
#  backup.sh — Yedekleme & Geri Yükleme
# ═══════════════════════════════════════════════

cmd_backup() {
    require_root
    case "${1:-help}" in
        run)     _backup_run "${@:2}" ;;
        list)    _backup_list ;;
        restore) _backup_restore "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl backup <run|list|restore>"
            echo ""
            echo "    run [domain]                       Yedekleme çalıştır"
            echo "    list                               Yedekleri listele"
            echo "    restore <yedek_dizini> [domain] [--dry-run]"
            echo "                                       Geri yükleme (opsiyonel tek-domain filtresi)"
            echo ""
            ;;
    esac
}

# Yedek kök + per-run dizinini güvenli oluştur (0700 root:root).
# Saf yardımcı: mysql/nginx gerektirmez.
_backup_prepare_dir() {
    local run_dir="$1"
    secure_dir "$BACKUP_DIR" 700
    secure_dir "$run_dir" 700
}

# Tek bir yedek artefaktını 0600 root:root kilitle.
_backup_secure_artifact() {
    secure_file "$1" 600
}

# Restore: tek bir files tarball'ını güvenle çıkar (zip-slip/symlink reddi).
# safe_extract mutlak yol/'..'/symlink üyesi varsa çıkarmadan reddeder.
# Saf yardımcı: mysql/systemctl gerektirmez.
_backup_restore_files() {
    local tar_gz="$1" dest="$2"
    safe_extract "$tar_gz" "$dest"
}

# Per-domain dosya tarball'ı (relatif yol + sır/kontrol dosyalarını hariç tut).
# .credentials/.srvctl-meta sır/kontrol dosyalarıdır; yedek paketine girmemeli
# (paket world-readable olabilir + safe_extract restore'u için relatif yol şart).
# Saf yardımcı: mysql/nginx gerektirmez.
_backup_files_tar() {
    local domain="$1" web_root="$2" out_tar="$3"
    tar czf "$out_tar" -C "$web_root" \
        --exclude='*.log' \
        --exclude="${domain}/cache/*" \
        --exclude="${domain}/releases/*" \
        --exclude="${domain}/sessions/*" \
        --exclude="${domain}/tmp/*" \
        --exclude="${domain}/.credentials" \
        --exclude="${domain}/.srvctl-meta" \
        --exclude="${domain}/.deploy-repo" \
        "$domain"
}

# ─── configs.tar.gz — SIR İÇERMEYEN (varsayılan) varyant ───
# GÜVENLİK (denetim DALGA 6 — bkz. rapor O12): ESKİ davranış /etc/redis/
# (→ users.acl: her 'redis_<sname>' için DÜZ METİN parola) ve
# /usr/local/srvctl/conf/ (→ srvctl.conf: REDIS_ADMIN_PASS, CF_API_TOKEN)
# İÇEREN configs.tar.gz'i KOŞULSUZ üretiyordu. README "yedekler sır içermez"
# diyordu — bu, _backup_files_tar için DOĞRU (.credentials hariç tutuluyor)
# ama configs.tar.gz için YANLIŞTI.
#
# KARAR (gerekçe): tam felaket kurtarma için bu sırların yine de gerekebileceği
# kabul edilerek İKİ MOD sunulur (bkz. _backup_run çağrı yeri):
#   1) BACKUP_GPG_RECIPIENT ayarlıysa VE 'gpg' kuruluysa: sırlar DAHİL, ama
#      HİÇ plaintext olarak diske DÜŞMEDEN doğrudan GPG ile şifrelenir
#      (configs.tar.gz.gpg). Operatör recipient'ı KENDİ seçtiğinden anahtar
#      yönetimi/trust sorumluluğu ona aittir.
#   2) Aksi halde (varsayılan): bu fonksiyon çağrılır — users.acl ve
#      srvctl.conf HARİÇ tutulur, README'nin iddiasını GERÇEK kılar. Bedeli:
#      bare-metal restore sonrası Redis ACL parolaları/CF token elle
#      yeniden girilmelidir (zaten DB parolaları için de durum buydu — bkz.
#      .credentials'ın hiçbir yedeğe girmemesi — yani bu YENİ bir kayıp
#      sınıfı değil, MEVCUT tutarsız durumun giderilmesidir).
# '--exclude' basename-bazlı (slash içermez) verildi — GNU tar bu durumda
# yol ağacındaki HERHANGİ bir seviyede o basename'e sahip üyeyi eler; mutlak/
# relatif yol belirsizliğinden bağımsız, sağlam bir eşleşme sağlar.
_backup_configs_tar_no_secrets() {
    local out_tar="$1"
    tar czf "$out_tar" \
        --exclude='users.acl' \
        --exclude='srvctl.conf' \
        /etc/nginx/sites-available/ \
        /etc/php/ \
        /etc/redis/ \
        /etc/mysql/mariadb.conf.d/ \
        /etc/apparmor.d/srvctl-* \
        /etc/fail2ban/jail.local \
        /usr/local/srvctl/conf/ \
        2>/dev/null || true
}

# Hedef dizinin bulunduğu dosya sisteminde boş MB miktarı. Saf yardımcı
# (yalnız 'df' — mysql/systemctl gerektirmez).
_backup_free_mb() {
    local dir="$1"
    df -Pm "$dir" 2>/dev/null | awk 'NR==2 {print $4}'
}

_backup_run() {
    local target_domain="$1"

    # ── Eski yedekleri ÖNCE temizle (bkz. rapor: eskiden bu adım yeni yedek
    #    yazıldıktan SONRA çalışıyordu — disk doluyken bu, kesik/yarım bir
    #    arşiv üretip 'backup list'in onu SAĞLIKLI göstermesi riskini
    #    taşıyordu; alan açmak için önce temizlik yapılır). 'find'ın
    #    '-mindepth 1 -maxdepth 1' kombinasyonu BACKUP_DIR'ın KENDİSİNİ zaten
    #    hiç aday yapmaz (eski koddaki '! -name "$(basename ...)"' iş bunun
    #    için VARDI ama isim-bazlı olduğundan kırılgandı — bkz. rapor).
    secure_dir "$BACKUP_DIR" 700
    local cleaned=0
    while IFS= read -r old_backup; do
        [[ -z "$old_backup" ]] && continue
        rm -rf -- "$old_backup"
        cleaned=$((cleaned + 1))
    done < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS}" 2>/dev/null)

    # ── Boş alan kontrolü (temizlikten SONRA, yeni yedek yazılmadan ÖNCE) ──
    # BACKUP_MIN_FREE_MB yeni bir opsiyonel eşik — core.sh senin dosyan
    # olmadığından load_config'e EKLENMEDİ, yalnız '${VAR:-varsayılan}'
    # fallback'i kullanıldı (bkz. rapor: bu, load_config'e devredilmesi
    # önerilen bir config anahtarıdır).
    local min_free_mb="${BACKUP_MIN_FREE_MB:-500}"
    local free_mb; free_mb="$(_backup_free_mb "$BACKUP_DIR")"
    if [[ -n "$free_mb" ]] && validate_uint "$free_mb" && (( free_mb < min_free_mb )); then
        log_action "BACKUP ABORTED: insufficient disk space (${free_mb}MB < ${min_free_mb}MB)"
        source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
        if declare -f send_notification &>/dev/null; then
            send_notification "Yedekleme Başarısız" "Yetersiz disk alanı: ${BACKUP_DIR} üzerinde ${free_mb}MB boş (asgari ${min_free_mb}MB)" "critical"
        fi
        error "Yetersiz disk alanı: ${BACKUP_DIR} üzerinde ${free_mb}MB boş (asgari: ${min_free_mb}MB) — yedekleme BAŞLATILMADI."
    fi

    local today
    today=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/${today}"

    # Yedek kökü + per-run dizini 0700 root:root
    _backup_prepare_dir "${backup_path}"

    header "Yedekleme: ${today}"

    # ─── Veritabanı Yedekleri ───
    step "DB" "Veritabanları yedekleniyor..."
    local db_count=0 db_fail_count=0

    while IFS= read -r db; do
        [[ -z "$db" ]] && continue

        # Hedef domain varsa, sadece o domain'in DB'sini yedekle
        if [[ -n "$target_domain" ]]; then
            local target_db="db_$(safe_name "$target_domain")"
            [[ "$db" != "$target_db" ]] && continue
        fi

        # GÜVENLİK/SAĞLAMLIK (bkz. rapor): 'set -euo pipefail' GLOBAL olarak
        # aktif (bin/srvctl) — eski kod bu pipeline'ı DÜZ bir komut olarak
        # çalıştırıyordu, yani TEK bir mysqldump hatası (lock timeout vb.)
        # pipefail sayesinde TÜM script'i (set -e) o AN durdurup geri kalan
        # DB'leri/dosyaları/redis/config adımlarını HİÇ ÇALIŞTIRMADAN
        # yedeklemeyi yarıda kesiyordu. 'if' koşulu altında bir pipeline'ın
        # başarısızlığı 'set -e'yi TETİKLEMEZ — döngü bir sonraki DB'ye
        # GEÇEBİLİR.
        local dump_out="${backup_path}/${db}.sql.gz"
        if mysqldump --single-transaction --quick --lock-tables=false \
            "$db" 2>/dev/null | gzip > "$dump_out"; then
            if gzip -t "$dump_out" 2>/dev/null; then
                _backup_secure_artifact "$dump_out"
                db_count=$((db_count + 1))
            else
                warn "DB yedeği bozuk (gzip -t başarısız), siliniyor: ${db}"
                rm -f "$dump_out"
                db_fail_count=$((db_fail_count + 1))
            fi
        else
            warn "DB yedekleme hatası (mysqldump/gzip başarısız): ${db}"
            rm -f "$dump_out"
            db_fail_count=$((db_fail_count + 1))
        fi
    done < <(mysql -N -e "SHOW DATABASES" 2>/dev/null | \
        grep -vE "^(information_schema|performance_schema|mysql|sys)$")

    success "${db_count} veritabanı yedeklendi"
    [[ $db_fail_count -gt 0 ]] && warn "${db_fail_count} veritabanı yedeklenemedi (yukarıdaki uyarılara bakın)"

    # ─── Dosya Yedekleri ───
    step "FILES" "Dosyalar yedekleniyor..."
    local file_count=0 file_fail_count=0

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        # Hedef domain varsa, sadece onu yedekle
        if [[ -n "$target_domain" && "$domain" != "$target_domain" ]]; then
            continue
        fi

        local file_tar="${backup_path}/${domain}-files.tar.gz"
        # Relatif yol + .credentials/.srvctl-meta hariç (safe_extract uyumlu, sır sızdırmaz)
        if _backup_files_tar "$domain" "${WEB_ROOT}" "$file_tar" 2>/dev/null && tar -tzf "$file_tar" &>/dev/null; then
            _backup_secure_artifact "$file_tar"
            file_count=$((file_count + 1))
        else
            warn "Dosya yedeklemesinde hata (veya bozuk arşiv), siliniyor: ${domain}"
            rm -f "$file_tar"
            file_fail_count=$((file_fail_count + 1))
        fi
    done

    success "${file_count} domain dosyası yedeklendi"
    [[ $file_fail_count -gt 0 ]] && warn "${file_fail_count} domain dosyası yedeklenemedi"

    # ─── Redis Yedek ───
    step "REDIS" "Redis yedekleniyor..."
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        # Parolayı argv'den uzak tut: REDISCLI_AUTH env (ps'te görünmez).
        REDISCLI_AUTH="$redis_admin_pass" redis-cli --user admin --no-auth-warning BGSAVE 2>/dev/null || true
        sleep 2
    fi
    cp /var/lib/redis/dump.rdb "${backup_path}/redis.rdb" 2>/dev/null || true
    if [[ -f "${backup_path}/redis.rdb" ]]; then
        _backup_secure_artifact "${backup_path}/redis.rdb"
    fi
    success "Redis yedeklendi"

    # ─── Config yedek ───
    # bkz. yukarıdaki _backup_configs_tar_no_secrets başlık yorumu — karar/
    # gerekçe orada. BACKUP_GPG_RECIPIENT yeni bir opsiyonel config anahtarı
    # (core.sh'a EKLENMEDİ, '${VAR:-}' fallback'i ile okunuyor — bkz. rapor).
    step "CONFIG" "Konfigürasyonlar yedekleniyor..."
    local gpg_recipient="${BACKUP_GPG_RECIPIENT:-}"
    local configs_ok=0
    if [[ -n "$gpg_recipient" ]] && command -v gpg &>/dev/null; then
        # Plaintext'i HİÇ diske yazmadan doğrudan şifrele (process substitution
        # değil, doğrudan pipe — böylece 'configs.tar.gz' düz metin olarak
        # asla oluşmaz).
        if tar czf - \
            /etc/nginx/sites-available/ \
            /etc/php/ \
            /etc/redis/ \
            /etc/mysql/mariadb.conf.d/ \
            /etc/apparmor.d/srvctl-* \
            /etc/fail2ban/jail.local \
            /usr/local/srvctl/conf/ \
            2>/dev/null | gpg --batch --yes --trust-model always -e -r "$gpg_recipient" \
                -o "${backup_path}/configs.tar.gz.gpg" 2>/dev/null
        then
            _backup_secure_artifact "${backup_path}/configs.tar.gz.gpg"
            success "Konfigürasyonlar GPG ile şifrelenerek yedeklendi (alıcı: ${gpg_recipient}, sırlar DAHİL)"
            configs_ok=1
        else
            warn "GPG şifreleme başarısız — sırlar İÇERMEYEN düz yedeğe düşülüyor (fallback)"
        fi
    elif [[ -n "$gpg_recipient" ]]; then
        warn "BACKUP_GPG_RECIPIENT tanımlı ama 'gpg' kurulu değil — sırlar İÇERMEYEN düz yedek alınıyor"
    fi
    if [[ "$configs_ok" -eq 0 ]]; then
        _backup_configs_tar_no_secrets "${backup_path}/configs.tar.gz"
        if tar -tzf "${backup_path}/configs.tar.gz" &>/dev/null; then
            _backup_secure_artifact "${backup_path}/configs.tar.gz"
            success "Konfigürasyonlar yedeklendi (SIR İÇERMEZ: users.acl ve srvctl.conf hariç)"
            warn "Tam felaket kurtarma (Redis ACL parolaları/CF token dahil) için BACKUP_GPG_RECIPIENT ayarlayın."
        else
            warn "configs.tar.gz bozuk üretildi, siliniyor"
            rm -f "${backup_path}/configs.tar.gz"
        fi
    fi

    # ─── Toplam boyut ───
    local total_size
    total_size=$(du -sh "${backup_path}" 2>/dev/null | awk '{print $1}')

    header "✅ Yedekleme Tamamlandı"

    echo "  Dizin:    ${backup_path}"
    echo "  Boyut:    ${total_size}"
    echo "  DB:       ${db_count} adet"
    echo "  Dosya:    ${file_count} domain"
    if [[ $cleaned -gt 0 ]]; then
        echo "  Temizlik: ${cleaned} eski yedek silindi"
    fi
    echo ""

    log_action "BACKUP: ${backup_path} (size=${total_size}, dbs=${db_count}, db_fail=${db_fail_count}, files=${file_count}, file_fail=${file_fail_count})"

    # ─── Başarısızlık bildirimi (bkz. rapor: eskiden send_notification HİÇ
    #      çağrılmıyordu) ───
    if (( db_fail_count > 0 || file_fail_count > 0 )); then
        source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
        if declare -f send_notification &>/dev/null; then
            send_notification "Yedekleme Kısmen Başarısız" \
                "DB hata: ${db_fail_count}, Dosya hata: ${file_fail_count} — bkz. ${backup_path}" \
                "warning"
        fi
    fi
}

_backup_list() {
    echo ""
    echo -e "  ${BOLD}Yedekler${NC}"
    divider
    printf "  ${DIM}%-25s %-10s %-10s${NC}\n" "TARİH" "BOYUT" "İÇERİK"
    divider

    local count=0
    for dir in "${BACKUP_DIR}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name
        name=$(basename "$dir")
        local size
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        local contents
        contents=$(ls "$dir" 2>/dev/null | wc -l)

        printf "  %-25s %-10s %-10s\n" "$name" "$size" "${contents} dosya"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  Henüz yedek yok."
    fi

    divider
    echo "  Toplam: ${count} yedek"
    echo ""
}

# Kullanım: _backup_restore <yedek_dizini> [domain] [--dry-run]
# --dry-run: hiçbir şey yazmadan neyin geri yükleneceğini listeler.
# [domain]: verilirse yalnız o domain'in DB'si + dosyaları geri yüklenir
#           (redis.rdb TÜM instance'ı kapsadığından domain filtresiyle
#           ATLANIR — bkz. aşağıdaki not).
_backup_restore() {
    local backup_path="" filter_domain="" dry_run=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            *)
                if [[ -z "$backup_path" ]]; then
                    backup_path="$arg"
                else
                    filter_domain="$arg"
                fi
                ;;
        esac
    done
    [[ -z "$backup_path" ]] && error "Kullanım: srvctl backup restore <yedek_dizini> [domain] [--dry-run]"

    # Tam yol yoksa BACKUP_DIR altında ara
    if [[ ! -d "$backup_path" ]]; then
        backup_path="${BACKUP_DIR}/${backup_path}"
    fi
    [[ -d "$backup_path" ]] || error "Yedek bulunamadı: ${backup_path}"

    local title
    title="Geri Yükleme: $(basename "${backup_path}")"
    [[ "$dry_run" -eq 1 ]] && title="${title} (DRY-RUN — hiçbir şey YAZILMAYACAK)"
    header "$title"

    if [[ "$dry_run" -eq 0 ]]; then
        warn "Bu işlem mevcut verilerin ÜZERİNE yazacaktır!"
        confirm "Devam etmek istiyor musunuz?" || { info "İptal edildi."; return 0; }
    fi

    # DB geri yükleme
    for sql_gz in "${backup_path}"/*.sql.gz; do
        [[ ! -f "$sql_gz" ]] && continue
        local db_name
        db_name=$(basename "$sql_gz" .sql.gz)
        if [[ -n "$filter_domain" ]]; then
            local target_db
            target_db="db_$(safe_name "$filter_domain")"
            [[ "$db_name" != "$target_db" ]] && continue
        fi
        if [[ "$dry_run" -eq 1 ]]; then
            info "[dry-run] DB geri yüklenecekti: ${db_name} (${sql_gz})"
            continue
        fi
        step "DB" "Geri yükleniyor: ${db_name}"
        if ! gzip -t "$sql_gz" 2>/dev/null; then
            warn "Yedek bozuk (gzip -t başarısız), atlanıyor: ${db_name}"
            continue
        fi
        zcat "$sql_gz" | mysql "$db_name" 2>/dev/null && \
            success "DB geri yüklendi: ${db_name}" || \
            warn "DB geri yükleme hatası: ${db_name}"
    done

    # Dosya geri yükleme (safe_extract — zip-slip/symlink reddi, WEB_ROOT altına)
    for tar_gz in "${backup_path}"/*-files.tar.gz; do
        [[ ! -f "$tar_gz" ]] && continue
        local domain
        domain=$(basename "$tar_gz" -files.tar.gz)
        if [[ -n "$filter_domain" && "$domain" != "$filter_domain" ]]; then
            continue
        fi
        if [[ "$dry_run" -eq 1 ]]; then
            info "[dry-run] Dosyalar geri yüklenecekti: ${domain} (${tar_gz})"
            continue
        fi
        step "FILES" "Geri yükleniyor: ${domain}"
        if _backup_restore_files "$tar_gz" "${WEB_ROOT}"; then
            success "Dosyalar geri yüklendi: ${domain}"
        else
            warn "Güvenli çıkarma reddedildi (mutlak yol/.. /symlink): ${domain}"
            warn "Eski mutlak yollu yedekler için güvenilir ortamda manuel çıkarın."
        fi
    done

    # Redis — yalnız TAM (domain filtresiz) restore'da: redis.rdb tek bir
    # instance dump'ıdır, tek domain'e ait değildir.
    if [[ -z "$filter_domain" && -f "${backup_path}/redis.rdb" ]]; then
        if [[ "$dry_run" -eq 1 ]]; then
            info "[dry-run] Redis geri yüklenecekti: ${backup_path}/redis.rdb"
        else
            step "REDIS" "Redis geri yükleniyor..."
            systemctl stop redis-server 2>/dev/null || true
            cp "${backup_path}/redis.rdb" /var/lib/redis/dump.rdb
            chown redis:redis /var/lib/redis/dump.rdb
            systemctl start redis-server
            success "Redis geri yüklendi"
        fi
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        echo ""
        info "Dry-run tamamlandı — hiçbir değişiklik yapılmadı."
        return 0
    fi

    success "Geri yükleme tamamlandı"
    log_action "RESTORE: $(basename "${backup_path}")${filter_domain:+ (domain=${filter_domain})}"
}
