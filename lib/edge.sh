#!/bin/bash
# ═══════════════════════════════════════════════
#  edge.sh — köken kilidi, TLS varsayılan sunucusu, Cloudflare'siz yükleme adresi
#
#    srvctl domain origin-lock <alan> on|off|status [--dry]
#    srvctl tls-default on|off|status [--dry]
#    srvctl domain fm-up <alan> on|off|status [--host=up.<alan>] [--origin=https://<alan>] [--adopt-cert] [--dry] [--purge-cert]
#
#  Kaynak: up-mimari (tasarım A) + up-guvenlik (K1, K3-K11, K13). Üretilen dosyalar:
#    conf.d/srvctl-cf-origin-geo.conf        (trusted.sh üretir; $srvctl_via_cf)
#    edge.d/<safe>/05-srvctl-origin-lock.conf     (origin-lock; vhost 443 bloğu bunu custom.d'den ÖNCE include eder — kiracının
#                                                  sunucu-düzeyi rewrite/if/return kuralı kilidi DELEMEZ; root:755 dizin)
#    conf.d/00-srvctl-tls-default.conf       (tls-default)
#    conf.d/srvctl-fmup-<safe>.conf          (fm-up; templates/nginx/fm-up-server.conf.tpl)
#  KÖKEN KAYDI: ${SRVCTL_STATE_DIR}/_edge/<safe>.edge (alan başına) ve GLOBAL.edge (tls-default); root:0700 dizin, 0600 dosya,
#  her satır "<tür> <sha256> <yol> [ek]". nginx-audit yalnız kayıtla EŞLEŞEN üretilmiş dosyayı tanır (_edge_is_generated);
#  kayıtsız/değiştirilmiş '05-srvctl-origin-lock.conf' sıradan kullanıcı dosyası gibi izin listesinden geçirilir.
#  Tüm yazımlar fm-auth kilidi (_fmprov_with_lock) altında (trusted sync'in geo yazımı ve 'domain remove' temizliği dahil);
#  her adımda nginx -t, düşerse önceki hâl GERİ. Sertifika sahipliği: kayıttaki 'fm-up-cert' satırı (issued=1 kendi aldığı,
#  issued=0 --adopt-cert ile sahiplenilmiş); certbot delete YALNIZ issued=1'e uygulanır.
# ═══════════════════════════════════════════════

if ! declare -F _domconf_atomic_write >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${SRVCTL_ROOT}/lib/domconf.sh" || return 1
fi
if ! declare -F _trusted_self_ips >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${SRVCTL_ROOT}/lib/trusted.sh" || return 1
fi

_EDGE_ORIGIN_LOCK_FILE="05-srvctl-origin-lock.conf"

_edge_conf_d()        { printf '%s' "${SRVCTL_NGINX_CONF_D:-/etc/nginx/conf.d}"; }
_edge_geo_conf()      { printf '%s' "${NGINX_CF_GEO_CONF:-$(_edge_conf_d)/srvctl-cf-origin-geo.conf}"; }
_edge_tls_conf()      { printf '%s' "${SRVCTL_TLS_DEFAULT_CONF:-$(_edge_conf_d)/00-srvctl-tls-default.conf}"; }
_edge_fmup_conf()     { printf '%s/srvctl-fmup-%s.conf' "$(_edge_conf_d)" "$1"; }
_edge_acme_root()     { printf '%s' "${SRVCTL_ACME_ROOT:-/var/lib/srvctl/acme}"; }
_edge_le_live()       { printf '%s' "${SRVCTL_LE_LIVE_DIR:-/etc/letsencrypt/live}"; }
_edge_dir()           { printf '%s/_edge' "${SRVCTL_STATE_DIR}"; }
_edge_edge_d()        { printf '%s' "${SRVCTL_NGINX_EDGE_DIR:-/etc/nginx/edge.d}"; }
_edge_lock_dir()      { printf '%s/%s' "$(_edge_edge_d)" "$1"; }
_edge_lock_file()     { printf '%s/%s' "$(_edge_lock_dir "$1")" "$_EDGE_ORIGIN_LOCK_FILE"; }
# fm-up günlükleri: root'a ait dizin (varsayılan /var/log/nginx), kiracının logs/ dizini DEĞİL. $1 sname $2 access|error|http
_edge_log_dir()       { printf '%s' "${SRVCTL_FMUP_LOG_DIR:-/var/log/nginx}"; }
_edge_fmup_log_file() { printf '%s/srvctl-fmup-%s.%s.log' "$(_edge_log_dir)" "$1" "$2"; }
_edge_rec_file()      { printf '%s/%s.edge' "$(_edge_dir)" "$1"; }

# ───────────────────────────────────────────────────────────────
#  Köken kaydı
# ───────────────────────────────────────────────────────────────
# PREDİKAT: 0 = güvenilir (yok olması da güvenilir).
_edge_state_ok() {
    local sname="${1:-}" dir rec phys par
    dir=$(_edge_dir)
    if [[ -e "$dir" || -L "$dir" ]]; then
        [[ -d "$dir" && ! -L "$dir" ]] || return 1
        assert_root_owned_path "$dir" || return 1
        [[ "$(_stat_mode "$dir")" == "700" ]] || return 1
        phys=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
        par=$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P) || return 1
        [[ "$phys" == "${par}/_edge" ]] || return 1
    fi
    if [[ -n "$sname" ]]; then
        rec=$(_edge_rec_file "$sname")
        if [[ -e "$rec" || -L "$rec" ]]; then
            [[ -f "$rec" && ! -L "$rec" ]] || return 1
            assert_root_owned_path "$rec" || return 1
            [[ "$(_stat_mode "$rec")" == "600" ]] || return 1
            [[ "$(_stat_nlink "$rec")" == "1" ]] || return 1
        fi
    fi
    return 0
}

_edge_prepare_dir() {
    local dir; dir=$(_edge_dir)
    if [[ -L "$dir" ]]; then warn "köken kayıt dizini sembolik bağ: ${dir} — reddedildi"; return 1; fi
    if _fmprov_dir_untrusted_preexisting "$dir"; then
        warn "kayıt dizini güvenilmez: ${dir} — ${_FMP_PREP_WHY}. HİÇBİR ŞEY yazılmadı."
        return 1
    fi
    secure_dir "$dir" 700 || return 1
    _edge_state_ok "" || { warn "köken kayıt dizini güvenilmez (sahip/mod/yol): ${dir}"; return 1; }
    return 0
}

# Kayıt satırı oku: $1 scope (sname | GLOBAL) $2 tür. Çıktı: _ER_SHA _ER_PATH _ER_EXTRA. PREDİKAT: 0 = var.
_ER_SHA=""; _ER_PATH=""; _ER_EXTRA=""
_edge_rec_get() {
    local scope="$1" kind="$2" rec k sha path extra
    _ER_SHA=""; _ER_PATH=""; _ER_EXTRA=""
    _edge_state_ok "$scope" || return 2
    rec=$(_edge_rec_file "$scope")
    [[ -f "$rec" ]] || return 1
    while IFS=' ' read -r k sha path extra || [[ -n "$k" ]]; do
        [[ "$k" == "$kind" ]] || continue
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 2
        _ER_SHA="$sha"; _ER_PATH="$path"; _ER_EXTRA="$extra"
        return 0
    done < "$rec"
    return 1
}

# Kayıt satırını ekle/değiştir ($5 boş → satırı SİL). Dizin hazır olmalı (kilit altında çağrılır).
_edge_rec_set() {
    local scope="$1" kind="$2" sha="$3" path="$4" extra="${5:-}" rec tmp k a b c
    local dir; dir=$(_edge_dir)
    rec=$(_edge_rec_file "$scope")
    tmp=$(mktemp "${dir}/.${scope}.XXXXXX") || return 1
    {
        printf 'srvctl-edge-manifest v1\n'
        if [[ -f "$rec" ]]; then
            while IFS=' ' read -r k a b c || [[ -n "$k" ]]; do
                [[ "$k" == "srvctl-edge-manifest" || "$k" == "$kind" || -z "$k" ]] && continue
                printf '%s %s %s %s\n' "$k" "$a" "$b" "$c"
            done < "$rec"
        fi
        if [[ -n "$sha" ]]; then printf '%s %s %s %s\n' "$kind" "$sha" "$path" "$extra"; fi
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; return 1; }
    return 0
}

# Kayıt boşaldıysa dosyayı kaldır.
_edge_rec_gc() {
    local rec; rec=$(_edge_rec_file "$1")
    [[ -f "$rec" ]] || return 0
    if [[ "$(grep -vc 'srvctl-edge-manifest' "$rec" 2>/dev/null)" == "0" ]]; then rm -f -- "$rec"; fi
    return 0
}

# Üretilmiş mi? ($1 sname, $2 yol): kayıtlı özetle eşleşen, root sahipli, normal, nlink 1, g/o yazma yok.
# nginx-audit'in 05-srvctl-origin-lock.conf'u "kullanıcı dosyası" saymaması için (domconf kancası). PREDİKAT: 0 = üretilmiş.
_edge_is_generated() {
    local sname="$1" path="$2" base h
    base="${path##*/}"
    [[ "$base" == "$_EDGE_ORIGIN_LOCK_FILE" ]] || return 1
    _edge_rec_get "$sname" origin-lock || return 1
    [[ "$_ER_PATH" == "$path" ]] || return 1
    _fmprov_file_meta_ok "$path" || return 1
    h=$(_domconf_sha256_file "$path") || return 1
    [[ "$h" == "$_ER_SHA" ]]
}

# ───────────────────────────────────────────────────────────────
#  nginx yardımcıları
# ───────────────────────────────────────────────────────────────
_EDGE_NGX_OUT=""
_edge_nginx_t() {
    _EDGE_NGX_OUT=$(nginx -t 2>&1) && return 0
    return 1
}
_edge_reload() { systemctl reload nginx >/dev/null 2>&1; }

# nginx sürümü (stdout "1.24.0" ya da boş). SRVCTL_NGINX_VERSION geçersiz kılar (test).
_edge_nginx_version() {
    local o v
    if [[ -n "${SRVCTL_NGINX_VERSION:-}" ]]; then printf '%s' "$SRVCTL_NGINX_VERSION"; return 0; fi
    o=$( { nginx -v; } 2>&1 ) || true
    [[ "$o" == *nginx/* ]] || o=$( { nginx -V; } 2>&1 ) || true
    v="${o#*nginx/}"; v="${v%%[^0-9.]*}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$v"
    return 0
}
# $1 >= $2 (üç parçalı sürüm). PREDİKAT.
_edge_ver_ge() {
    local a b i
    IFS=. read -r -a a <<< "$1"; IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
        (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
    done
    return 0
}

# Dosya yaz + yedek: $1 hedef $2 içerik. Önceki hâl _EDGE_BK'ya (yoksa boş; _EDGE_HAD=0). 0644 root.
_EDGE_BK=""; _EDGE_HAD=0
_edge_backup_and_write() {
    local dest="$1" content="$2"
    _EDGE_BK=""; _EDGE_HAD=0
    [[ ! -L "$dest" ]] || { warn "hedef sembolik bağ — yazılmadı: ${dest}"; return 1; }
    if [[ -e "$dest" ]]; then
        _EDGE_HAD=1
        _EDGE_BK=$(mktemp "${dest}.srvctl-bk.XXXXXX") || return 1
        cp -p "$dest" "$_EDGE_BK" || { rm -f -- "$_EDGE_BK"; _EDGE_BK=""; return 1; }
    fi
    if ! _domconf_atomic_write "$dest" "$content"; then
        [[ -n "$_EDGE_BK" ]] && rm -f -- "$_EDGE_BK"
        _EDGE_BK=""
        return 1
    fi
    return 0
}
# Önceki hâli geri yükle ($1 hedef). Yedek varsa üzerine taşır, yoksa dosyayı siler.
_edge_restore() {
    local dest="$1"
    if (( _EDGE_HAD )) && [[ -n "$_EDGE_BK" && -e "$_EDGE_BK" ]]; then
        mv -f -- "$_EDGE_BK" "$dest"
    elif (( _EDGE_HAD == 0 )); then
        rm -f -- "$dest"
    fi
    _EDGE_BK=""
}
_edge_bk_drop() { [[ -n "$_EDGE_BK" ]] && rm -f -- "$_EDGE_BK"; _EDGE_BK=""; return 0; }

_edge_usage_flag() { case "${1:-}" in help|-h|--help) return 0 ;; esac; return 1; }

# ───────────────────────────────────────────────────────────────
#  Genel yazım çekirdeği (origin-lock / tls-default): yaz → kayıt → nginx -t → reload; düşerse geri.
#  $1 hedef yol $2 içerik $3 scope $4 tür $5 ek. rc: 0 ok | 3 nginx -t | 4 yazım/kayıt | 5 reload başarısız (config geçerli)
# ───────────────────────────────────────────────────────────────
_edge_apply_file() {
    local dest="$1" content="$2" scope="$3" kind="$4" extra="${5:-}" sha prev_sha="" prev_path="" prev_extra="" had_rec=0
    sha=$(_domconf_sha256_text "$content") || return 4
    if _edge_rec_get "$scope" "$kind"; then had_rec=1; prev_sha="$_ER_SHA"; prev_path="$_ER_PATH"; prev_extra="$_ER_EXTRA"; fi
    _edge_backup_and_write "$dest" "$content" || return 4
    if ! _edge_rec_set "$scope" "$kind" "$sha" "$dest" "$extra"; then
        _edge_restore "$dest"; return 4
    fi
    if ! _edge_nginx_t; then
        _edge_restore "$dest"
        if (( had_rec )); then _edge_rec_set "$scope" "$kind" "$prev_sha" "$prev_path" "$prev_extra" || true; else _edge_rec_set "$scope" "$kind" "" "" || true; _edge_rec_gc "$scope"; fi
        return 3
    fi
    _edge_bk_drop
    _edge_reload || return 5
    return 0
}

# Kaldırma çekirdeği: dosya + kayıt. rc: 0 | 3 | 4 | 5
_edge_remove_file() {
    local dest="$1" scope="$2" kind="$3" prev_sha="" prev_path="" prev_extra="" had_rec=0
    if _edge_rec_get "$scope" "$kind"; then had_rec=1; prev_sha="$_ER_SHA"; prev_path="$_ER_PATH"; prev_extra="$_ER_EXTRA"; fi
    _EDGE_BK=""; _EDGE_HAD=0
    if [[ -e "$dest" ]]; then
        _EDGE_HAD=1
        _EDGE_BK=$(mktemp "${dest}.srvctl-bk.XXXXXX") || return 4
        cp -p "$dest" "$_EDGE_BK" || { rm -f -- "$_EDGE_BK"; _EDGE_BK=""; return 4; }
        rm -f -- "$dest" || { _edge_bk_drop; return 4; }
    fi
    _edge_rec_set "$scope" "$kind" "" "" || { (( _EDGE_HAD )) && _edge_restore "$dest"; return 4; }
    if ! _edge_nginx_t; then
        if (( _EDGE_HAD )); then _edge_restore "$dest"; fi
        if (( had_rec )); then _edge_rec_set "$scope" "$kind" "$prev_sha" "$prev_path" "$prev_extra" || true; fi
        return 3
    fi
    _edge_bk_drop
    _edge_rec_gc "$scope"
    _edge_reload || return 5
    return 0
}

_edge_report_rc() {   # $1 rc $2 etiket
    case "$1" in
        0) return 0 ;;
        3) warn "nginx -t BAŞARISIZ — önceki hâl GERİ YÜKLENDİ, reload YAPILMADI:"; printf '%s\n' "$_EDGE_NGX_OUT" | sed 's/^/      /' >&2; return 1 ;;
        4) warn "${2}: yazım/kayıt hatası — GERİ ALINDI"; return 1 ;;
        5) warn "nginx reload BAŞARISIZ — yapılandırma GEÇERLİ ama çalışan nginx eski hâlde olabilir: systemctl status nginx; sonra: srvctl domain reload --all"; return 1 ;;
    esac
    return 1
}

# ═══════════════════════════════════════════════════════════════
#  ORIGIN-LOCK
# ═══════════════════════════════════════════════════════════════
_edge_origin_lock_render() {
    printf '%s\n' \
        "# srvctl: KÖKEN KİLİDİ (srvctl domain origin-lock <alan> on). SRVCTL ÜRETİR — elle düzenlemeyin; 'off' siler." \
        "# Cloudflare dışından (köken IP'sine doğrudan; ORİJİNAL TCP eşi CF/yerel/kendi IP değilse) gelen istek 444 ile kesilir." \
        "# \$srvctl_via_cf: conf.d/srvctl-cf-origin-geo.conf (srvctl trusted sync üretir; realip ile AYNI CF listesi)." \
        "# KONUM: edge.d/<alan>/ — vhost 443 bloğu bunu custom.d/<alan>/*.conf'tan ÖNCE include eder (sunucu-düzeyi rewrite/if/return" \
        "# yazılış sırasıyla çalışır: kiracının 'rewrite … last' kuralı kilidi ATLAYAMASIN). YALNIZ 443 sunucu bloğuna girer (on bunu" \
        "# denetler). Up (DNS-only) bloğu BU dosyayı içermez (20/90 glob'u): kilit up alt alanını kapatmaz." \
        'if ($srvctl_via_cf = 0) { return 444; }'
}

# vhost'un 443 bloklarında edge.d include'u var mı ve custom.d include'undan ÖNCE mi?
# rc 0 tamam | 2 hiçbir 443 bloğunda edge.d include'u yok (eski şablon) | 3 edge.d include'u 443 olmayan blokta |
#    4 vhost yok/çözümlenemedi | 5 edge.d include'u custom.d'DEN SONRA ya da bir 443 bloğunda eksik
_EDGE_WHY=""
_edge_vhost_check() {
    local domain="$1" sname="$2" vhost rc=0
    _EDGE_WHY=""
    vhost="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${domain}.conf"
    if [[ ! -f "$vhost" ]]; then _EDGE_WHY="vhost bulunamadı: ${vhost}"; return 4; fi
    awk -v einc="edge\\\\.d/${sname}/" -v cinc="custom\\\\.d/${sname}/" '
        function body(l) { sub(/#.*/, "", l); return l }
        BEGIN { depth = 0; inserver = 0; ok = 0; bad3 = 0; order = 0; missing = 0 }
        {
            l = body($0)
            if (depth == 0 && l ~ /^[[:space:]]*server[[:space:]]*\{/) { inserver = 1; has443 = 0; eline = 0; cline = 0 }
            if (inserver) {
                if (l ~ /^[[:space:]]*listen[[:space:]]/ && l ~ /(^|[^0-9])443([^0-9]|$)/) has443 = 1
                if (l ~ /^[[:space:]]*include[[:space:]]/ && l ~ einc && eline == 0) eline = NR
                if (l ~ /^[[:space:]]*include[[:space:]]/ && l ~ cinc && cline == 0) cline = NR
            }
            o = gsub(/\{/, "{", l); c = gsub(/\}/, "}", l)
            depth += o - c
            if (inserver && depth <= 0) {
                if (!has443 && (eline > 0 || cline > 0)) bad3++
                else if (has443) {
                    if (eline > 0 && (cline == 0 || eline < cline)) ok++
                    else if (eline > 0) order++
                    else if (cline > 0) missing++
                }
                inserver = 0; depth = 0
            }
        }
        END { if (bad3 > 0) exit 3; if (order > 0) exit 5; if (missing > 0) { if (ok == 0) exit 2; exit 5 } if (ok == 0) exit 2; exit 0 }
    ' "$vhost" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) _EDGE_WHY="vhost edge.d/${sname}/*.conf dosyasını include ETMİYOR (eski şablonla üretilmiş; ${vhost}) — kilit kiracı dosyalarından ÖNCE yüklenemez. Çare: vhost'u şablondan yeniden üretin: srvctl domain rate-limit ${domain} <mevcut-profil> (vhost'un TAMAMINI yeniden yazar: elle düzenleme kaybolur; nginx -t + reload yapar) YA DA 443 bloğunda custom.d include'unun ÜSTÜNE 'include /etc/nginx/edge.d/${sname}/*.conf;' satırını elle ekleyin (bkz. RUNBOOK-up.md)"; return 2 ;;
        3) _EDGE_WHY="edge.d/custom.d include'u 443 dinlemeyen bir sunucu bloğunda (SSL'siz vhost ya da port 80'de içerik sunan blok) — kilit o blokta GEÇERLİ olmazdı (port 80 kilitsiz kalırdı); önce SSL'i kurun / port 80 bloğunu yönlendirmeye indirin"; return 3 ;;
        5) _EDGE_WHY="edge.d include'u bir 443 bloğunda custom.d include'undan SONRA ya da eksik — kiracının sunucu-düzeyi rewrite kuralı kilidi delebilir; edge.d satırı custom.d satırının ÜSTÜNDE olmalı (${vhost})"; return 5 ;;
        *) _EDGE_WHY="vhost çözümlenemedi"; return 4 ;;
    esac
}

_edge_geo_ok() {
    local g; g=$(_edge_geo_conf)
    [[ -f "$g" && ! -L "$g" ]] || return 1
    grep -q '^geo \$realip_remote_addr \$srvctl_via_cf {' "$g"
}

# edge.d/<sname> GÜVEN KAPISI (custom.d ile aynı kural: sembolik bağ değil, tüm zincir root sahipli, g/o-yazılamaz). PREDİKAT.
_edge_lockdir_trusted() {
    local dir="$1" sname="$2"
    if _domconf_fm_dir_trusted "$dir" "$sname"; then _EDGE_WHY=""; return 0; fi
    _EDGE_WHY="${_FMD_WHY//custom.d\//edge.d/}"
    return 1
}

# Açık köken kilitlerini (kayıtlı origin-lock) tümünü kaldırır: dosya + kayıt. geo dosyası ilk yazımda geri alındığında çağrılır
# (kilitler tanımsız $srvctl_via_cf'ye başvurur). fm-auth kilidi ALTINDA çağrılmalı. stdout yok; uyarı stderr.
_edge_origin_locks_drop_all() {
    local dir rec sname k sha path extra f dropped=""
    dir=$(_edge_dir)
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    for rec in "$dir"/*.edge; do
        [[ -f "$rec" && ! -L "$rec" ]] || continue
        sname="${rec##*/}"; sname="${sname%.edge}"
        [[ "$sname" != "GLOBAL" ]] || continue
        _edge_rec_get "$sname" origin-lock || continue
        f="$_ER_PATH"
        [[ "${f##*/}" == "$_EDGE_ORIGIN_LOCK_FILE" ]] || continue
        if [[ -f "$f" && ! -L "$f" ]]; then rm -f -- "$f"; fi
        rmdir "$(dirname "$f")" 2>/dev/null || true
        _edge_rec_set "$sname" origin-lock "" "" || true
        _edge_rec_gc "$sname"
        dropped+="${dropped:+ }${sname}"
    done
    [[ -z "$dropped" ]] || warn "geo dosyası geri alındı: \$srvctl_via_cf tanımsız kaldığı için şu alanların köken kilidi de GERİ ALINDI: ${dropped} — yeniden: srvctl trusted sync; srvctl domain origin-lock <alan> on"
    return 0
}

_edge_origin_lock_on_locked() {
    local domain="$1" sname="$2" dir="$3" dry="$4" f content rc=0
    f="${dir}/${_EDGE_ORIGIN_LOCK_FILE}"
    # --dry yazmaz: dizin YARATILMAZ (salt-okur doğrulama), ama GERÇEK komutun reddedeceği her durum burada da reddedilir.
    if (( dry )); then
        _edge_state_ok "" || { warn "köken kayıt dizini güvenilmez: $(_edge_dir)"; return 1; }
    else
        _edge_prepare_dir || return 1
    fi
    content=$(_edge_origin_lock_render)
    if [[ -e "$f" || -L "$f" ]] && ! _edge_is_generated "$sname" "$f"; then
        warn "${_EDGE_ORIGIN_LOCK_FILE} VAR ama srvctl üretimi değil (kayıtsız/değiştirilmiş) — ÜZERİNE YAZILMADI: ${f}. İnceleyin: srvctl domain nginx-audit ${domain}"
        return 1
    fi
    if (( dry )); then
        info "DRY-OK (yazım yok): ${f} yazılır, nginx -t, reload. İçerik:"
        printf '%s\n' "$content" | sed 's/^/      /'
        return 0
    fi
    if [[ ! -d "$dir" ]]; then
        { mkdir -p "$(_edge_edge_d)" && chmod 755 "$(_edge_edge_d)" && mkdir -p "$dir" && chmod 755 "$dir"; } || { warn "edge.d dizini oluşturulamadı: ${dir}"; return 1; }
    fi
    _edge_apply_file "$f" "$content" "$sname" origin-lock "" || rc=$?
    _edge_report_rc "$rc" "origin-lock" || return 1
    success "Köken kilidi AÇIK: ${domain} (Cloudflare/yerel/kendi IP dışı doğrudan bağlantı 444; kilit kiracı dosyalarından ÖNCE değerlendirilir)"
    log_action "ORIGIN-LOCK ON: ${domain}"
    return 0
}

_edge_origin_lock_off_locked() {
    local domain="$1" sname="$2" dir="$3" dry="$4" f rc=0
    f="${dir}/${_EDGE_ORIGIN_LOCK_FILE}"
    if (( dry )); then
        _edge_state_ok "" || { warn "köken kayıt dizini güvenilmez: $(_edge_dir)"; return 1; }
    else
        _edge_prepare_dir || return 1
    fi
    if [[ ! -e "$f" && ! -L "$f" ]]; then
        if (( dry )); then info "DRY-OK: köken kilidi zaten KAPALI: ${domain}"; return 0; fi
        _edge_rec_get "$sname" origin-lock && { _edge_rec_set "$sname" origin-lock "" "" || true; _edge_rec_gc "$sname"; }
        info "Köken kilidi zaten KAPALI: ${domain}"
        return 0
    fi
    if ! _edge_is_generated "$sname" "$f"; then
        warn "${_EDGE_ORIGIN_LOCK_FILE} srvctl üretimi DEĞİL (kayıtsız/değiştirilmiş) — SİLİNMEDİ: ${f}. İnceleyin: srvctl domain nginx-audit ${domain}"
        return 1
    fi
    if (( dry )); then info "DRY-OK (yazım yok): ${f} silinir, nginx -t, reload"; return 0; fi
    _edge_remove_file "$f" "$sname" origin-lock || rc=$?
    _edge_report_rc "$rc" "origin-lock off" || return 1
    rmdir "$dir" 2>/dev/null || true
    success "Köken kilidi KAPALI: ${domain}"
    log_action "ORIGIN-LOCK OFF: ${domain}"
    return 0
}

_edge_origin_lock_status() {
    local domain="$1" sname="$2" dir="$3" f st="KAPALI" rc=0 geo="yok"
    f="${dir}/${_EDGE_ORIGIN_LOCK_FILE}"
    _edge_geo_ok && geo="var"
    if [[ -e "$f" || -L "$f" ]]; then
        if _edge_is_generated "$sname" "$f"; then st="AÇIK"; else st="BOZUK"; rc=1; fi
    fi
    echo "origin-lock ${domain}: ${st} (geo dosyası: ${geo}; ${f})"
    if [[ "$st" == "BOZUK" ]]; then
        echo "  ${_EDGE_ORIGIN_LOCK_FILE} VAR ama srvctl kaydıyla eşleşmiyor (kayıtsız/değiştirilmiş) — srvctl domain nginx-audit ${domain}"
    fi
    if [[ "$st" == "AÇIK" && "$geo" == "yok" ]]; then
        echo "  UYARI: geo dosyası yok — nginx bu kilitle YÜKLENEMEZ (\$srvctl_via_cf tanımsız): srvctl trusted sync"
        rc=1
    fi
    if [[ "$st" == "AÇIK" ]] && ! _edge_vhost_check "$domain" "$sname"; then
        echo "  UYARI: vhost sırası: ${_EDGE_WHY}"
        rc=1
    fi
    return "$rc"
}

_edge_origin_lock_cmd() {
    local usage="srvctl domain origin-lock <alan> <on|off|status> [--dry] | origin-lock --capabilities"
    if [[ "${1:-}" == "--capabilities" && $# -eq 1 ]]; then
        printf 'srvctl-origin-lock-caps v1 dry=1 geo-realip-remote-addr=1 audit-recognized=1 only-443=1 rollback-nginx-t=1 edge-d-before-custom=1\n'
        return 0
    fi
    if _edge_usage_flag "${1:-}"; then echo "  Kullanım: ${usage}"; return 0; fi
    local domain="${1:-}" action="${2:-}" dry=0 arg sname dir rc=0
    if [[ $# -ge 2 ]]; then shift 2; else set --; fi
    for arg in "$@"; do
        case "$arg" in
            --dry) dry=1 ;;
            *) error "Bilinmeyen seçenek: ${arg} (kullanım: ${usage})" ;;
        esac
    done
    [[ -n "$domain" && -n "$action" ]] || error "Kullanım: ${usage}"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    sname=$(safe_name "$domain")
    [[ -n "$sname" ]] && assert_safe_ident "$sname" || error "Geçersiz domain kimliği: ${domain}"
    dir=$(_edge_lock_dir "$sname")
    case "$action" in
        status)
            _edge_origin_lock_status "$domain" "$sname" "$dir" || return 1
            return 0 ;;
        on|off) ;;
        *) error "Bilinmeyen eylem: ${action} (on|off|status)" ;;
    esac
    if ! _edge_lockdir_trusted "$dir" "$sname"; then
        error "edge.d/${sname} güvenilmez: ${_EDGE_WHY} — HİÇBİR ŞEY yazılmadı"
    fi
    if [[ "$action" == "on" ]]; then
        _edge_geo_ok || error "Geo dosyası yok/geçersiz ($(_edge_geo_conf)) — önce 'srvctl trusted sync' (Cloudflare listesi alınmadan kilit açılamaz; boş liste tüm CF trafiğini keserdi)"
        _edge_vhost_check "$domain" "$sname" || error "Köken kilidi açılamaz: ${_EDGE_WHY}"
        _edge_with_lock "$dry" _edge_origin_lock_on_locked "$domain" "$sname" "$dir" "$dry" || rc=$?
    else
        _edge_with_lock "$dry" _edge_origin_lock_off_locked "$domain" "$sname" "$dir" "$dry" || rc=$?
    fi
    (( rc == 0 )) || return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  TLS-DEFAULT
# ═══════════════════════════════════════════════════════════════
# SRVCTL_TLS_DEFAULT_LISTEN: yalnız laboratuvar/test için dinleme adresi (<port> ya da <ip>:<port>); üretimde 443.
_edge_tls_default_listen() {
    local l="${SRVCTL_TLS_DEFAULT_LISTEN:-443}"
    [[ "$l" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}:)?[1-9][0-9]{0,4}$ ]] || l=443
    printf '%s' "$l"
}

_edge_tls_default_render() {
    printf '%s\n' \
        "# srvctl: 443 VARSAYILAN sunucu (srvctl tls-default on). SRVCTL ÜRETİR — elle düzenlemeyin; 'off' siler." \
        "# Bilinmeyen SNI / çıplak IP ile gelen el sıkışma REDDEDİLİR: sertifika da içerik de verilmez (nginx >= 1.19.4)." \
        "# Bilinen alanlar etkilenmez (SNI ile kendi sunucu bloğuna gider). SNI göndermeyen yerel sondalar" \
        "# 'curl --resolve <alan>:443:127.0.0.1 https://<alan>/' biçiminde olmalıdır (lib/deploy.sh bunu yapar)." \
        "server {" \
        "    listen $(_edge_tls_default_listen) ssl default_server;" \
        "    server_name _;" \
        "    ssl_reject_handshake on;" \
        "    # Bağlantının İLK isteğindeki başlık zaman aşımını bu varsayılan sunucu belirler (SNI seçimi zamanlayıcıyı sıfırlamaz);" \
        "    # değer bütün 443 alanlarının el sıkışma + ilk başlık süresidir (lab: bunsuz 60 sn, ile 10 sn). Cloudflare için yeterli." \
        "    client_header_timeout 10s;" \
        "    return 444;" \
        "}"
}

# --dry SALT-OKURDUR: kilit dosyası/dizini YARATILMAZ (kilit yalnız gerçek yazımda alınır; kuru kipte yazım olmadığından
# serileştirmeye de gerek yoktur). $1 dry (0|1); kalanı kilit altında çalışacak komut.
_edge_with_lock() {
    local dry="$1"; shift
    if [[ "$dry" == "1" ]]; then "$@"; return $?; fi
    _fmprov_with_lock "$@"
}

# tls-default AÇIK mı: srvctl üretimi dosya var, sembolik bağ değil, kayıt SHA'sı eşleşiyor. fm-up on bunu ŞART koşar
# (up bloğu 443 örtük varsayılan sunucu olmasın), tls-default off açık bir up sunucusu varken reddedilir.
_edge_tls_default_active() {
    local f; f=$(_edge_tls_conf)
    [[ -f "$f" && ! -L "$f" ]] || return 1
    _edge_rec_get GLOBAL tls-default || return 1
    [[ -n "$_ER_SHA" && "$(_domconf_sha256_file "$f" 2>/dev/null)" == "$_ER_SHA" ]]
}

# conf.d'de AÇIK bir up sunucusu (srvctl-fmup-*.conf) var mı; ilk bulunanın yolunu stdout'a yazar.
_edge_any_fmup_conf() {
    local f
    for f in "$(_edge_conf_d)"/srvctl-fmup-*.conf; do
        if [[ -e "$f" || -L "$f" ]]; then printf '%s' "$f"; return 0; fi
    done
    return 1
}

_edge_tls_default_locked() {
    local action="$1" dry="$2" f rc=0 content ver
    f=$(_edge_tls_conf)
    if (( dry )); then
        _edge_state_ok "" || { warn "köken kayıt dizini güvenilmez: $(_edge_dir)"; return 1; }
    else
        _edge_prepare_dir || return 1
    fi
    if [[ "$action" == "on" ]]; then
        ver=$(_edge_nginx_version)
        if [[ -z "$ver" ]]; then warn "nginx sürümü okunamadı — ssl_reject_handshake için >= 1.19.4 doğrulanamadı; AÇILMADI"; return 1; fi
        if ! _edge_ver_ge "$ver" "1.19.4"; then warn "nginx ${ver} < 1.19.4: ssl_reject_handshake yok — AÇILMADI"; return 1; fi
        content=$(_edge_tls_default_render)
        if [[ -e "$f" || -L "$f" ]]; then
            _edge_rec_get GLOBAL tls-default || true
            if [[ -L "$f" ]] || [[ -z "$_ER_SHA" || "$(_domconf_sha256_file "$f" 2>/dev/null)" != "$_ER_SHA" ]]; then
                warn "${f} VAR ama srvctl üretimi değil (kayıtsız/değiştirilmiş) — ÜZERİNE YAZILMADI"; return 1
            fi
        fi
        if (( dry )); then info "DRY-OK (yazım yok; nginx ${ver}): ${f} yazılır, nginx -t, reload"; printf '%s\n' "$content" | sed 's/^/      /'; return 0; fi
        _edge_apply_file "$f" "$content" GLOBAL tls-default "" || rc=$?
        _edge_report_rc "$rc" "tls-default" || return 1
        success "tls-default AÇIK: bilinmeyen SNI/çıplak IP el sıkışması reddedilir"
        info "Doğrulama: echo | openssl s_client -connect 127.0.0.1:443 2>&1 | grep -ciE 'alert|unrecognized'  (>= 1);  curl -sk -o /dev/null -w '%{http_code}' --resolve <alan>:443:127.0.0.1 https://<alan>/  (200/401)"
        log_action "TLS-DEFAULT ON"
        return 0
    fi
    local up_open
    if up_open=$(_edge_any_fmup_conf); then
        warn "tls-default KAPATILAMAZ: açık bir fm-up sunucusu var (${up_open}) — kapatılırsa up bloğu 443 örtük varsayılan sunucu olur. Önce 'srvctl domain <alan> fm-up off', sonra 'tls-default off'"
        return 1
    fi
    if [[ ! -e "$f" && ! -L "$f" ]]; then
        if (( dry )); then info "DRY-OK: tls-default zaten KAPALI"; return 0; fi
        _edge_rec_get GLOBAL tls-default && { _edge_rec_set GLOBAL tls-default "" "" || true; _edge_rec_gc GLOBAL; }
        info "tls-default zaten KAPALI"; return 0
    fi
    _edge_rec_get GLOBAL tls-default || true
    if [[ -L "$f" ]] || [[ -z "$_ER_SHA" || "$(_domconf_sha256_file "$f" 2>/dev/null)" != "$_ER_SHA" ]]; then
        warn "${f} srvctl üretimi DEĞİL (kayıtsız/değiştirilmiş) — SİLİNMEDİ"; return 1
    fi
    if (( dry )); then info "DRY-OK (yazım yok): ${f} silinir, nginx -t, reload"; return 0; fi
    _edge_remove_file "$f" GLOBAL tls-default || rc=$?
    _edge_report_rc "$rc" "tls-default off" || return 1
    success "tls-default KAPALI"
    log_action "TLS-DEFAULT OFF"
    return 0
}

_edge_tls_default_status() {
    local f st="KAPALI" rc=0 ver
    f=$(_edge_tls_conf)
    ver=$(_edge_nginx_version)
    if [[ -e "$f" || -L "$f" ]]; then
        _edge_rec_get GLOBAL tls-default || true
        if [[ ! -L "$f" && -n "$_ER_SHA" && "$(_domconf_sha256_file "$f" 2>/dev/null)" == "$_ER_SHA" ]] && _fmprov_file_meta_ok "$f"; then st="AÇIK"; else st="BOZUK"; rc=1; fi
    fi
    echo "tls-default: ${st} (nginx ${ver:-?}; ${f})"
    [[ "$st" == "BOZUK" ]] && echo "  ${f} srvctl kaydıyla eşleşmiyor (kayıtsız/değiştirilmiş)"
    return "$rc"
}

cmd_tls_default() {
    local usage="srvctl tls-default <on|off|status> [--dry] | tls-default --capabilities"
    if [[ "${1:-}" == "--capabilities" && $# -eq 1 ]]; then
        printf 'srvctl-tls-default-caps v1 dry=1 nginx-version-check=1 rollback-nginx-t=1 record=1\n'
        return 0
    fi
    if _edge_usage_flag "${1:-help}"; then echo "  Kullanım: ${usage}"; return 0; fi
    local action="${1:-}" dry=0 arg rc=0
    if [[ $# -ge 1 ]]; then shift; fi
    for arg in "$@"; do
        case "$arg" in
            --dry) dry=1 ;;
            *) error "Bilinmeyen seçenek: ${arg} (kullanım: ${usage})" ;;
        esac
    done
    case "$action" in
        status) _edge_tls_default_status || return 1; return 0 ;;
        on|off) ;;
        *) error "Kullanım: ${usage}" ;;
    esac
    require_root
    _edge_with_lock "$dry" _edge_tls_default_locked "$action" "$dry" || rc=$?
    (( rc == 0 )) || return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  FM-UP
# ═══════════════════════════════════════════════════════════════
_edge_int_conf() {   # $1 değişken adı $2 varsayılan → doğrulanmış tamsayı
    local v="${!1:-$2}"
    [[ "$v" =~ ^[1-9][0-9]{0,5}$ ]] || { warn "${1}='${v}' geçersiz — varsayılan ${2}" >&2; v="$2"; }
    printf '%s' "$v"
}

# $1 domain $2 host $3 origin $4 modsec(0|1) $5 faz (1|2). stdout: render. rc 1 hata, 2 kalan jeton.
_edge_fmup_render() {
    local domain="$1" host="$2" origin="$3" modsec="$4" phase="$5" sname rendered origin_re tpl
    sname=$(safe_name "$domain")
    assert_safe_ident "$sname" || return 1
    [[ "$modsec" == "0" || "$modsec" == "1" ]] || return 1
    origin_re="${origin//./\\.}"
    tpl="$(_domconf_fm_tpl_dir)/fm-up-server.conf.tpl"
    rendered=$(render_template "$tpl" \
        "SAFE_NAME=${sname}" "FM_UP_HOST=${host}" "FM_UP_ORIGIN=${origin}" "FM_UP_ORIGIN_RE=${origin_re}" \
        "ACME_ROOT=$(_edge_acme_root)" "LE_LIVE=$(_edge_le_live)" \
        "CUSTOM_D=${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}" \
        "EMPTY_ROOT=${SRVCTL_FMUP_EMPTY_ROOT:-/var/empty}" "LOG_DIR=$(_edge_log_dir)" \
        "MODSEC_LINE=$(_domconf_fm_modsec_line "$modsec")" \
        "RATE_IP=$(_edge_int_conf FMUP_RATE_IP 5)" "BURST_IP=$(_edge_int_conf FMUP_BURST_IP 20)" "CONN_IP=$(_edge_int_conf FMUP_CONN_IP 12)" \
        "RATE_ALL=$(_edge_int_conf FMUP_RATE_ALL 60)" "BURST_ALL=$(_edge_int_conf FMUP_BURST_ALL 120)" "CONN_ALL=$(_edge_int_conf FMUP_CONN_ALL 100)") || return 1
    [[ "$rendered" != *'{{'* ]] || return 2
    if [[ "$phase" == "1" ]]; then
        # Faz 1: '@@PHASE2' işaretinden ÖNCEKİ kısım (yalnız port 80).
        rendered="${rendered%%"# @@PHASE2"*}"
    fi
    printf '%s' "$rendered"
}

_edge_ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
# $1 = IPv4, $2 = v4 CIDR/IP. PREDİKAT.
_edge_ip_in_cidr() {
    local ip="$1" cidr="$2" net bits mask
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || return 1
    net="${cidr%/*}"; bits=32; [[ "$cidr" == */* ]] && bits="${cidr#*/}"
    (( bits >= 0 && bits <= 32 )) || return 1
    if (( bits == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF )); fi
    (( ($(_edge_ip2int "$ip") & mask) == ($(_edge_ip2int "$net") & mask) ))
}

# K18 (DNS-only doğrulaması). $1 host. stdout: bulgu satırları; rc 0 = A kaydı sunucunun kendi IPv4'ü ve CF dışı.
_EDGE_DNS_WHY=""
_edge_dns_check() {
    local host="$1" a_out aaaa_out line selfv4 pub ip cf n_a=0 own cfhit
    _EDGE_DNS_WHY=""
    if ! command -v dig >/dev/null 2>&1; then _EDGE_DNS_WHY="dig bulunamadı (dnsutils/bind-utils kurun) — DNS kaydı DOĞRULANAMADI"; return 1; fi
    a_out=$(dig +short +time=3 +tries=1 A "$host" 2>/dev/null) || a_out=""
    aaaa_out=$(dig +short +time=3 +tries=1 AAAA "$host" 2>/dev/null) || aaaa_out=""
    selfv4=""
    pub="${SRVCTL_PUBLIC_IPV4:-}"
    if [[ -n "$pub" ]]; then selfv4="$pub"; else
        for ip in $(_trusted_self_ips); do [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && selfv4+="${selfv4:+ }${ip}"; done
    fi
    [[ -n "$selfv4" ]] || { _EDGE_DNS_WHY="sunucunun kendi IPv4'ü belirlenemedi (NAT ise SRVCTL_PUBLIC_IPV4=<genel ip>)"; return 1; }
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ ! "$line" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            _EDGE_DNS_WHY="${host} A yanıtı IP değil (CNAME/çöp: '${line}') — Cloudflare proxy'si olabilir; kaydı DNS-only A kaydı yapın"; return 1
        fi
        n_a=$((n_a + 1))
        cfhit=0
        if [[ -f "${TRUSTED_STATE_DIR:-/etc/srvctl/trusted}/cloudflare.conf" ]]; then
            while IFS= read -r cf; do
                [[ -n "$cf" && "$cf" != *:* ]] || continue
                if _edge_ip_in_cidr "$line" "$cf"; then cfhit=1; break; fi
            done < "${TRUSTED_STATE_DIR:-/etc/srvctl/trusted}/cloudflare.conf"
        fi
        if (( cfhit )); then
            _EDGE_DNS_WHY="${host} → ${line}: Cloudflare aralığında (turuncu bulut AÇIK) — DNS-only (gri bulut) yapın; DURULDU"; return 1
        fi
        own=0
        for ip in $selfv4; do [[ "$ip" == "$line" ]] && own=1; done
        if (( own == 0 )); then _EDGE_DNS_WHY="${host} → ${line}: sunucunun kendi IPv4'ü DEĞİL (${selfv4})"; return 1; fi
    done <<< "$a_out"
    if (( n_a == 0 )); then _EDGE_DNS_WHY="${host} için A kaydı yok (DNS henüz açılmadı ya da yayılmadı)"; return 1; fi
    if [[ -n "$aaaa_out" ]]; then _EDGE_DNS_WHY="${host} AAAA kaydı var (${aaaa_out%%$'\n'*}) — nginx IPv6 DİNLEMİYOR; AAAA'yı silin"; return 1; fi
    return 0
}

_edge_fmup_abort_handler() {   # sinyalde yazımı geri al + çık
    local sig="$1"
    warn "sinyal alındı — fm-up yazımı GERİ ALINIYOR"
    _edge_restore "${_EDGE_FMUP_CONF:-/nonexistent}"
    # köken kaydı da başlangıç hâline (kayıt yazıldıktan sonra, reload'dan önce gelen sinyal için)
    if [[ -n "${_EDGE_FMUP_SNAME:-}" ]]; then
        if (( _EDGE_FMUP_HAD_REC )); then _edge_rec_set "$_EDGE_FMUP_SNAME" fm-up "$_EDGE_FMUP_PREV_SHA" "$_EDGE_FMUP_PREV_PATH" "$_EDGE_FMUP_PREV_EXTRA" || true
        else _edge_rec_set "$_EDGE_FMUP_SNAME" fm-up "" "" || true; _edge_rec_gc "$_EDGE_FMUP_SNAME"; fi
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    exit "$sig"
}
_EDGE_FMUP_CONF=""; _EDGE_FMUP_SNAME=""; _EDGE_FMUP_HAD_REC=0; _EDGE_FMUP_PREV_SHA=""; _EDGE_FMUP_PREV_PATH=""; _EDGE_FMUP_PREV_EXTRA=""

# fm-up günlük dizini/dosyaları güven kapısı (root'a ait; kiracının logs/ dizini DEĞİL). $1 sname. PREDİKAT; neden _EDGE_WHY.
_edge_log_ok() {
    local sname="$1" d f k
    d=$(_edge_log_dir)
    if [[ -L "$d" || ! -d "$d" ]]; then _EDGE_WHY="günlük dizini yok ya da sembolik bağ: ${d}"; return 1; fi
    if ! assert_root_owned_path "$d"; then
        _EDGE_WHY="günlük dizini root'a ait değil / grup-herkes yazabilir / yol bileşeni güvenilmez: ${d} (SRVCTL_FMUP_LOG_DIR=<root sahipli dizin>)"; return 1
    fi
    for k in access error http; do
        f=$(_edge_fmup_log_file "$sname" "$k")
        if [[ -L "$f" ]]; then _EDGE_WHY="günlük dosyası sembolik bağ: ${f}"; return 1; fi
    done
    return 0
}

# fm-up 'on' SALT-OKUR ön kapısı (--dry de GERÇEK komutla AYNI yolu kullanır). $1 domain $2 sname $3 host $4 adopt(0|1).
# Reddeder: host başka bir srvctl alanı / vhost'u var / başka alanın köken kaydında; günlük dizini güvenilmez; mevcut up conf
# srvctl üretimi değil; live sertifika var ama srvctl kaydı (fm-up-cert) yok ve --adopt-cert verilmedi.
# Kurar: _EDGE_WHY, _EDGE_CERT_ISSUED ("" = sertifika yok → certbot alacak; 0/1 = mevcut sertifikanın sahiplik bayrağı). PREDİKAT.
_EDGE_CERT_ISSUED=""
_edge_fmup_pre_check() {
    local domain="$1" sname="$2" host="$3" adopt="$4" live conf rec other k sha path extra dir
    _EDGE_WHY=""; _EDGE_CERT_ISSUED=""
    if domain_exists "$host"; then
        _EDGE_WHY="${host} başka bir srvctl alanı — fm-up o alanın vhost'unu/sertifikasını sahiplenemez (host yalnız ${domain}'in sahipsiz doğrudan alt alanı olabilir)"; return 1
    fi
    if [[ -e "${SITES_AVAILABLE:-/etc/nginx/sites-available}/${host}.conf" ]]; then
        _EDGE_WHY="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${host}.conf zaten var (o host başka bir vhost'a ait) — fm-up sahiplenmez"; return 1
    fi
    dir=$(_edge_dir)
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        for rec in "$dir"/*.edge; do
            [[ -f "$rec" && ! -L "$rec" ]] || continue
            other="${rec##*/}"; other="${other%.edge}"
            [[ "$other" != "$sname" && "$other" != "GLOBAL" ]] || continue
            while IFS=' ' read -r k sha path extra || [[ -n "$k" ]]; do
                [[ "$k" == "fm-up" || "$k" == "fm-up-cert" ]] || continue
                if [[ "${extra%% *}" == "$host" ]]; then _EDGE_WHY="${host} başka bir alanın (${other}) fm-up kaydında — sahiplenilemez"; return 1; fi
            done < "$rec"
        done
    fi
    _edge_log_ok "$sname" || return 1
    conf=$(_edge_fmup_conf "$sname")
    if [[ -e "$conf" || -L "$conf" ]]; then
        _edge_rec_get "$sname" fm-up || true
        if [[ -L "$conf" ]] || [[ -z "$_ER_SHA" || "$(_domconf_sha256_file "$conf" 2>/dev/null)" != "$_ER_SHA" ]]; then
            _EDGE_WHY="${conf} VAR ama srvctl üretimi değil (kayıtsız/değiştirilmiş) — ÜZERİNE YAZILMADI"; return 1
        fi
    fi
    live="$(_edge_le_live)/${host}"
    if [[ -s "${live}/fullchain.pem" && -s "${live}/privkey.pem" ]]; then
        if _edge_rec_get "$sname" fm-up-cert && [[ "${_ER_EXTRA%% *}" == "$host" ]]; then
            _EDGE_CERT_ISSUED="${_ER_EXTRA##*issued=}"
            [[ "$_EDGE_CERT_ISSUED" == "0" || "$_EDGE_CERT_ISSUED" == "1" ]] || _EDGE_CERT_ISSUED=0
        elif (( adopt )); then
            _EDGE_CERT_ISSUED=0
        else
            _EDGE_WHY="${live} sertifikası zaten var ama srvctl kaydında (fm-up-cert) YOK — başka bir alanın/hizmetin sertifikası olabilir; fm-up onu kendinin saymaz. Bilerek sahiplenmek için --adopt-cert (sahiplenilen sertifika 'off --purge-cert' ve 'domain remove' ile SİLİNMEZ)"; return 1
        fi
    fi
    return 0
}

# fm-up günlüklerini bir logrotate yapılandırması kapsıyor mu? (dağıtımın /etc/logrotate.d/nginx'i /var/log/nginx/*.log'u kapsar.) PREDİKAT.
_edge_logrotate_covered() {
    local d="${SRVCTL_LOGROTATE_DIR:-/etc/logrotate.d}" ld
    ld=$(_edge_log_dir)
    [[ -d "$d" ]] || return 1
    grep -qsF -e "${ld}/*.log" -e "${ld}/srvctl-fmup-" "$d"/* 2>/dev/null
}

# Sertifika sahiplik kaydı (fm-up kaydından ayrı: 'off' sonrası da kalır → '--purge-cert' sertifikayı bulur). $1 sname $2 host $3 issued(0|1)
_edge_cert_rec_set() {
    local sname="$1" host="$2" issued="$3" sha
    sha=$(_domconf_sha256_text "$host") || return 1
    _edge_rec_set "$sname" fm-up-cert "$sha" "$(_edge_le_live)/${host}" "${host} issued=${issued}"
}

# Güvenli üreticiler → rc: 0 ok | 1 hata
_edge_fmup_on_locked() {
    local domain="$1" sname="$2" host="$3" origin="$4" dry="$5" adopt="${6:-0}" conf live acme p1 p2 rc=0 modsec out cert_pre=0
    local had_rec=0 prev_sha="" prev_path="" prev_extra=""
    conf=$(_edge_fmup_conf "$sname"); _EDGE_FMUP_CONF="$conf"
    live="$(_edge_le_live)/${host}"; acme=$(_edge_acme_root)
    # --dry yazmaz (kayıt dizini/ACME kökü YARATILMAZ) ama GERÇEK komutun reddedeceği her durum burada da reddedilir.
    if (( dry )); then
        _edge_state_ok "" || { warn "köken kayıt dizini güvenilmez: $(_edge_dir)"; return 1; }
    else
        _edge_prepare_dir || return 1
    fi
    _edge_tls_default_active || { warn "fm-up AÇILMADI: tls-default AÇIK değil — önce 'srvctl tls-default on' (aksi hâlde up bloğu 443 örtük varsayılan sunucu olur: SNI'sız/bilinmeyen SNI up sertifikasını görür)"; return 1; }
    _edge_fmup_pre_check "$domain" "$sname" "$host" "$adopt" || { warn "fm-up AÇILMADI: ${_EDGE_WHY}"; return 1; }
    cert_pre="$_EDGE_CERT_ISSUED"
    _edge_logrotate_covered || warn "UYARI: $(_edge_log_dir)/srvctl-fmup-*.log için logrotate kapsamı bulunamadı (/etc/logrotate.d/*) — günlükler dönmez; ekleyin (RUNBOOK-up.md)"
    [[ -d "$(_edge_conf_d)" ]] || { warn "conf.d dizini yok: $(_edge_conf_d)"; return 1; }
    # ModSecurity yeteneği (fm-auth ile AYNI sonda): modül yoksa 'modsecurity off' satırı yorum olur.
    if _DOMCONF_PROBE_DRY="$dry" _domconf_fm_modsec_probe; then modsec="$_DOMCONF_MODSEC"; else
        warn "ModSecurity yeteneği tespit edilemedi (${_DOMCONF_MODSEC_PROBE_OUT:-?}) — fm-up AÇILMADI (up bloğunda 'modsecurity off' garanti edilemez)"; return 1
    fi
    p1=$(_edge_fmup_render "$domain" "$host" "$origin" "$modsec" 1) || { warn "faz 1 şablonu render edilemedi"; return 1; }
    p2=$(_edge_fmup_render "$domain" "$host" "$origin" "$modsec" 2) || { warn "faz 2 şablonu render edilemedi"; return 1; }
    if (( dry )); then
        info "DRY-OK (yazım yok): DNS doğrulandı, host/sertifika/günlük kapıları geçti; 1) ${conf} yalnız port 80 (ACME + 301) → nginx -t → reload; 2) certbot certonly --webroot -w ${acme} -d ${host}; 3) ${conf} TAM (80+443) → nginx -t → reload; günlükler: $(_edge_log_dir)/srvctl-fmup-${sname}.*.log"
        return 0
    fi
    if _edge_rec_get "$sname" fm-up; then had_rec=1; prev_sha="$_ER_SHA"; prev_path="$_ER_PATH"; prev_extra="$_ER_EXTRA"; fi
    _EDGE_FMUP_SNAME="$sname"; _EDGE_FMUP_HAD_REC="$had_rec"; _EDGE_FMUP_PREV_SHA="$prev_sha"; _EDGE_FMUP_PREV_PATH="$prev_path"; _EDGE_FMUP_PREV_EXTRA="$prev_extra"
    mkdir -p "$acme" && chmod 755 "$acme" || { warn "ACME kökü oluşturulamadı: ${acme}"; return 1; }
    local sha_full; sha_full=$(_domconf_sha256_text "$p2") || return 1

    trap '_edge_fmup_abort_handler 130' INT
    trap '_edge_fmup_abort_handler 143' TERM
    trap '_edge_fmup_abort_handler 129' HUP
    # TEK yedek: komutun BAŞLANGIÇ hâli (_EDGE_BK/_EDGE_HAD) — her hata/sinyalde GERİ dönülen budur (faz 1 ara hâli değil).
    if [[ ! -s "${live}/fullchain.pem" || ! -s "${live}/privkey.pem" ]]; then
        # Faz 1: yalnız port 80 (ACME + 301)
        step "1/2" "port 80 bloğu (ACME + 301) yazılıyor: ${conf}"
        _edge_backup_and_write "$conf" "$p1" || { trap - INT TERM HUP; return 1; }
        if ! _edge_nginx_t; then
            _edge_fmup_unwind "$conf"; trap - INT TERM HUP
            warn "faz 1 nginx -t BAŞARISIZ — GERİ ALINDI:"; printf '%s\n' "$_EDGE_NGX_OUT" | sed 's/^/      /' >&2; return 1
        fi
        if ! _edge_reload; then
            _edge_fmup_unwind "$conf"; trap - INT TERM HUP
            warn "faz 1 reload BAŞARISIZ — GERİ ALINDI"; return 1
        fi
        out=$(certbot certonly --webroot -w "$acme" -d "$host" --non-interactive --agree-tos -m "admin@${domain}" 2>&1) || rc=$?
        if (( rc != 0 )) || [[ ! -s "${live}/fullchain.pem" ]]; then
            _edge_fmup_unwind "$conf"; trap - INT TERM HUP
            warn "certbot BAŞARISIZ (rc=${rc}) — yapılandırma GERİ ALINDI. Çıktının sonu:"
            printf '%s\n' "$out" | tail -8 | sed 's/^/      /' >&2
            return 1
        fi
        # Sertifikayı BİZ aldık: sahiplik kaydı hemen (sonraki adım düşse bile 'off --purge-cert' sertifikayı bulur).
        _edge_cert_rec_set "$sname" "$host" 1 || warn "sertifika sahiplik kaydı yazılamadı (fm-up-cert) — 'off --purge-cert' sertifikayı bulamaz"
        step "2/2" "TAM up sunucu bloğu (80 + 443) yazılıyor: ${conf}"
        _domconf_atomic_write "$conf" "$p2" || { _edge_fmup_unwind "$conf"; trap - INT TERM HUP; warn "faz 2 yazılamadı — GERİ ALINDI"; return 1; }
    else
        info "Sertifika zaten var (${live}) — faz 1 atlandı"
        step "2/2" "TAM up sunucu bloğu (80 + 443) yazılıyor: ${conf}"
        _edge_backup_and_write "$conf" "$p2" || { trap - INT TERM HUP; return 1; }
    fi
    if ! _edge_nginx_t; then
        _edge_fmup_unwind "$conf"; trap - INT TERM HUP
        warn "faz 2 nginx -t BAŞARISIZ — önceki hâl GERİ YÜKLENDİ:"; printf '%s\n' "$_EDGE_NGX_OUT" | sed 's/^/      /' >&2; return 1
    fi
    if ! _edge_rec_set "$sname" fm-up "$sha_full" "$conf" "${host} ${origin}"; then
        _edge_fmup_unwind "$conf"; trap - INT TERM HUP
        warn "köken kaydı yazılamadı — GERİ ALINDI"; return 1
    fi
    if ! _edge_reload; then
        _edge_fmup_unwind "$conf"
        if (( had_rec )); then _edge_rec_set "$sname" fm-up "$prev_sha" "$prev_path" "$prev_extra" || true; else _edge_rec_set "$sname" fm-up "" "" || true; _edge_rec_gc "$sname"; fi
        trap - INT TERM HUP
        warn "faz 2 reload BAŞARISIZ — GERİ ALINDI"; return 1
    fi
    _edge_bk_drop
    trap - INT TERM HUP
    # Önceden var olan sertifika: sahiplik kaydı (sahiplenilmiş issued=0 ya da kayıtlı issued bayrağı) — yalnız kayıt yoksa yaz.
    if [[ "$cert_pre" == "0" || "$cert_pre" == "1" ]]; then
        _edge_cert_rec_set "$sname" "$host" "$cert_pre" || warn "sertifika sahiplik kaydı yazılamadı (fm-up-cert)"
    fi
    success "fm-up AÇIK: https://${host}/_fm/up/…  (köken: ${origin}; günlükler: $(_edge_log_dir)/srvctl-fmup-${sname}.*.log)"
    info "Sonraki adım (uygulama): fmupload.putHost=${host}; doğrulama: srvctl domain fm-up ${domain} status"
    log_action "FM-UP ON: ${domain} ${host}"
    return 0
}

# Başlangıç hâline dön: dosya geri + nginx -t geçerse reload (çalışan nginx faz dosyasını yüklediyse boşaltılır).
_edge_fmup_unwind() {
    _edge_restore "$1"
    nginx -t >/dev/null 2>&1 && _edge_reload || true
    return 0
}

_edge_fmup_off_locked() {
    local domain="$1" sname="$2" dry="$3" purge="$4" conf host="" fm_sha="" rc=0 phost="" pissued=""
    conf=$(_edge_fmup_conf "$sname")
    if (( dry )); then
        _edge_state_ok "" || { warn "köken kayıt dizini güvenilmez: $(_edge_dir)"; return 1; }
    else
        _edge_prepare_dir || return 1
    fi
    if _edge_rec_get "$sname" fm-up; then fm_sha="$_ER_SHA"; host="${_ER_EXTRA%% *}"; fi
    # --purge-cert: sertifikayı KAYITTAN (fm-up-cert; 'off' sonrası da kalır) bul; bulunamazsa HİÇBİR ŞEY yapmadan rc 1.
    if [[ "$purge" == "1" ]]; then
        if _edge_rec_get "$sname" fm-up-cert; then
            phost="${_ER_EXTRA%% *}"; pissued="${_ER_EXTRA##*issued=}"
        fi
        if [[ -z "$phost" ]] || ! validate_domain "$phost"; then
            warn "--purge-cert: ${domain} için sertifika kayıt satırı yok (köken kaydında fm-up-cert bulunamadı: kayıt yok) — HİÇBİR ŞEY yapılmadı. Sertifikayı elle silmeniz gerekiyorsa: certbot certificates; certbot delete --cert-name <host> (srvctl kaydı olmayan sertifikayı silmez)"
            return 1
        fi
    fi
    if [[ ! -e "$conf" && ! -L "$conf" ]]; then
        if (( ! dry )) && [[ -n "$fm_sha" ]]; then _edge_rec_set "$sname" fm-up "" "" || true; _edge_rec_gc "$sname"; fi
        info "fm-up zaten KAPALI: ${domain}"
    else
        if [[ -L "$conf" ]] || [[ -z "$fm_sha" || "$(_domconf_sha256_file "$conf" 2>/dev/null)" != "$fm_sha" ]]; then
            warn "${conf} srvctl üretimi DEĞİL (kayıtsız/değiştirilmiş) — SİLİNMEDİ"; return 1
        fi
        if (( dry )); then
            info "DRY-OK (yazım yok): ${conf} silinir, nginx -t, reload$([[ "$purge" == "1" ]] && printf '; certbot delete --cert-name %s (yalnız srvctl tarafından alınan sertifika: issued=%s)' "$phost" "$pissued")"
            return 0
        fi
        _edge_remove_file "$conf" "$sname" fm-up || rc=$?
        _edge_report_rc "$rc" "fm-up off" || return 1
        success "fm-up KAPALI: ${domain} (up sunucu bloğu kaldırıldı)"
    fi
    if [[ "$purge" == "1" ]]; then
        if (( dry )); then info "DRY-OK: certbot delete --cert-name ${phost} (issued=${pissued})"; return 0; fi
        if [[ "$pissued" == "1" ]]; then
            if certbot delete --cert-name "$phost" --non-interactive >/dev/null 2>&1; then
                success "up sertifikası silindi: ${phost}"
                _edge_rec_set "$sname" fm-up-cert "" "" || true; _edge_rec_gc "$sname"
            else
                warn "certbot delete başarısız: ${phost} — sertifika kaydı KORUNDU (yeniden deneyin: srvctl domain fm-up ${domain} off --purge-cert)"
                return 1
            fi
        else
            info "up sertifikası srvctl'in DEĞİL (--adopt-cert ile sahiplenilmişti): ${phost} SİLİNMEDİ; kayıt temizlendi"
            _edge_rec_set "$sname" fm-up-cert "" "" || true; _edge_rec_gc "$sname"
        fi
    else
        info "Sertifika KALDI (yenileme 80 bloğu olmadan düşer; kayıt korunur; silmek için: srvctl domain fm-up ${domain} off --purge-cert)"
    fi
    log_action "FM-UP OFF: ${domain}"
    return 0
}

_edge_fmup_status() {
    local domain="$1" sname="$2" conf st="KAPALI" rc=0 host origin h exp fmauth="?"
    conf=$(_edge_fmup_conf "$sname")
    _edge_rec_get "$sname" fm-up || true
    host="${_ER_EXTRA%% *}"; origin="${_ER_EXTRA#* }"
    if [[ -e "$conf" || -L "$conf" ]]; then
        if [[ ! -L "$conf" && -n "$_ER_SHA" ]] && _fmprov_file_meta_ok "$conf" && [[ "$(_domconf_sha256_file "$conf")" == "$_ER_SHA" ]]; then st="AÇIK"; else st="BOZUK"; rc=1; fi
    elif [[ -n "$_ER_SHA" ]]; then st="BOZUK"; rc=1
    fi
    if _fmprov_load "$sname" 2>/dev/null; then fmauth="${_FMP_STATE:-?}"; fi
    echo "fm-up ${domain}: ${st}${host:+ (host: ${host}, köken: ${origin})} — fm-auth: ${fmauth}"
    if [[ "$st" == "BOZUK" ]]; then
        echo "  ${conf} kayıtla eşleşmiyor ya da yok (kurcalanmış/silinmiş) — yeniden üretmek için: srvctl domain fm-up ${domain} on"
    fi
    if [[ "$st" == "AÇIK" && "$fmauth" != "on" ]]; then
        echo "  BİLGİ: fm-auth '${fmauth}' — up bloğu 20/90'ı glob ile içerir; fm-auth kapalıyken up yalnız 403 (kapalı kök imzası) verir"
    fi
    if [[ -n "$host" ]]; then
        h="$(_edge_le_live)/${host}/fullchain.pem"
        if [[ -f "$h" ]]; then
            exp=$(openssl x509 -enddate -noout -in "$h" 2>/dev/null | cut -d= -f2)
            echo "  sertifika: ${host} — bitiş: ${exp:-?}"
        else
            echo "  sertifika: ${host} — YOK (${h})"
        fi
        if [[ "$st" == "AÇIK" ]]; then
            if _edge_dns_check "$host"; then echo "  DNS: ${host} → sunucunun kendi IPv4'ü, Cloudflare dışı (tamam)"; else echo "  DNS UYARI: ${_EDGE_DNS_WHY}"; rc=1; fi
        fi
    fi
    return "$rc"
}

_edge_fmup_cmd() {
    local usage="srvctl domain fm-up <alan> <on|off|status> [--host=up.<alan>] [--origin=https://<alan>] [--adopt-cert] [--dry] [--purge-cert] | fm-up --capabilities"
    if [[ "${1:-}" == "--capabilities" && $# -eq 1 ]]; then
        printf 'srvctl-fm-up-caps v1 dry=1 dns-gate=1 two-phase=1 rollback=1 purge-cert=1 audit-recognized=1 ssl-status=1 remove-cleans=1 cert-ownership=1 adopt-cert=1 root-logs=1\n'
        return 0
    fi
    if _edge_usage_flag "${1:-}"; then echo "  Kullanım: ${usage}"; return 0; fi
    local domain="${1:-}" action="${2:-}" host="" origin="" dry=0 purge="" adopt=0 arg sname rc=0 label
    if [[ $# -ge 2 ]]; then shift 2; else set --; fi
    for arg in "$@"; do
        case "$arg" in
            --host=*)   host="${arg#--host=}";   [[ -n "$host" ]]   || error "--host boş olamaz" ;;
            --origin=*) origin="${arg#--origin=}"; [[ -n "$origin" ]] || error "--origin boş olamaz" ;;
            --dry)      dry=1 ;;
            --purge-cert) purge=1 ;;
            --adopt-cert) adopt=1 ;;
            *) error "Bilinmeyen seçenek: ${arg} (kullanım: ${usage})" ;;
        esac
    done
    [[ -n "$domain" && -n "$action" ]] || error "Kullanım: ${usage}"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
    sname=$(safe_name "$domain")
    [[ -n "$sname" ]] && assert_safe_ident "$sname" || error "Geçersiz domain kimliği: ${domain}"
    case "$action" in on|off|status) ;; *) error "Bilinmeyen eylem: ${action} (on|off|status)" ;; esac
    [[ -z "$purge" || "$action" == "off" ]] || error "--purge-cert yalnız 'off' ile kullanılır"
    (( ! adopt )) || [[ "$action" == "on" ]] || error "--adopt-cert yalnız 'on' ile kullanılır"
    if [[ "$action" == "on" ]]; then
        [[ -n "$host" ]] || host="up.${domain}"
        [[ -n "$origin" ]] || origin="https://${domain}"
        # host: <tek etiket>.<alan>, 'www' değil; origin: https://<alan> ya da https://www.<alan> (port/yol yok).
        label="${host%."${domain}"}"
        if [[ "$label" == "$host" || -z "$label" || ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ || "$label" == "www" ]] || ! validate_domain "$host"; then
            error "--host '${host}' geçersiz: <tek-etiket>.${domain} olmalı (küçük harf; 'www' değil)"
        fi
        case "$origin" in
            "https://${domain}"|"https://www.${domain}") ;;
            *) error "--origin '${origin}' geçersiz: https://${domain} ya da https://www.${domain} (şema https, port/yol yok)" ;;
        esac
    fi
    case "$action" in
        status) _edge_fmup_status "$domain" "$sname" || return 1; return 0 ;;
    esac
    require_root
    if [[ "$action" == "on" ]]; then
        _edge_dns_check "$host" || error "DNS kapısı: ${_EDGE_DNS_WHY}"
        _edge_with_lock "$dry" _edge_fmup_on_locked "$domain" "$sname" "$host" "$origin" "$dry" "$adopt" || rc=$?
    else
        _edge_with_lock "$dry" _edge_fmup_off_locked "$domain" "$sname" "$dry" "$purge" || rc=$?
    fi
    (( rc == 0 )) || return 1
    return 0
}

# ───────────────────────────────────────────────────────────────
#  Dış kancalar: ssl/monitor (K13), domain remove, nginx-audit
# ───────────────────────────────────────────────────────────────
# Kayıtlı up host'ları: satır başına "<domain-sname> <host>". Kayıt dizini güvenilmezse boş.
_edge_fmup_hosts() {
    local dir rec k sha path extra f
    dir=$(_edge_dir)
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    for rec in "$dir"/*.edge; do
        [[ -f "$rec" && ! -L "$rec" ]] || continue
        while IFS=' ' read -r k sha path extra || [[ -n "$k" ]]; do
            [[ "$k" == "fm-up" ]] || continue
            f="${extra%% *}"
            validate_domain "$f" && printf '%s\n' "$f"
        done < "$rec"
    done
    return 0
}

# domain remove: up bloğu + köken kilidi + kayıt + (YALNIZ srvctl'in aldığı) sertifika. fm-auth kilidi ALTINDA. Reload'u çağıran yapar.
_edge_purge_domain() {
    local domain="$1" sname rc=0
    sname=$(safe_name "$domain")
    [[ -n "$sname" ]] || return 0
    _fmprov_with_lock _edge_purge_domain_locked "$domain" "$sname" || rc=$?
    if (( rc != 0 )); then
        warn "domain remove: köken/fm-up temizliği ATLANDI ya da eksik kaldı (kilit alınamadı/hata). Kalıntı olabilir: $(_edge_fmup_conf "$sname"), $(_edge_lock_dir "$sname"), $(_edge_rec_file "$sname")"
    fi
    return 0
}

_edge_purge_domain_locked() {
    local domain="$1" sname="$2" conf lockf host="" fm_sha="" chost="" issued="" cert_ok=1
    conf=$(_edge_fmup_conf "$sname"); lockf=$(_edge_lock_file "$sname")
    if _edge_rec_get "$sname" fm-up; then fm_sha="$_ER_SHA"; host="${_ER_EXTRA%% *}"; fi
    if _edge_rec_get "$sname" fm-up-cert; then chost="${_ER_EXTRA%% *}"; issued="${_ER_EXTRA##*issued=}"; fi
    # up conf: YALNIZ kayıtla eşleşiyorsa silinir (kayıtsız dosya operatörün olabilir; nginx onu hâlâ yükler → sertifikası da silinmez)
    if [[ -e "$conf" || -L "$conf" ]]; then
        if [[ ! -L "$conf" && -n "$fm_sha" && "$(_domconf_sha256_file "$conf" 2>/dev/null)" == "$fm_sha" ]]; then
            rm -f -- "$conf"
        else
            warn "domain remove: ${conf} srvctl üretimi DEĞİL (kayıtsız/değiştirilmiş) — SİLİNMEDİ; sertifikası da silinmeyecek"
            cert_ok=0
        fi
    fi
    # köken kilidi (edge.d: custom.d silinirken GİTMEZ): yalnız srvctl üretimi
    if [[ -e "$lockf" || -L "$lockf" ]]; then
        if _edge_is_generated "$sname" "$lockf"; then rm -f -- "$lockf"; else warn "domain remove: ${lockf} srvctl üretimi DEĞİL — SİLİNMEDİ"; fi
    fi
    rmdir "$(_edge_lock_dir "$sname")" 2>/dev/null || true
    _edge_rec_set "$sname" fm-up "" "" 2>/dev/null || true
    _edge_rec_set "$sname" origin-lock "" "" 2>/dev/null || true
    # sertifika: YALNIZ srvctl'in kendi aldığı (issued=1) ve nginx artık onu içeren bir blok yüklemiyorsa
    if (( cert_ok )) && [[ "$issued" == "1" && -n "$chost" ]] && validate_domain "$chost"; then
        if _edge_nginx_t; then
            if certbot delete --cert-name "$chost" --non-interactive >/dev/null 2>&1; then
                _edge_rec_set "$sname" fm-up-cert "" "" 2>/dev/null || true
            else
                warn "domain remove: certbot delete başarısız (${chost}) — sertifika kaydı KORUNDU"
            fi
        else
            warn "domain remove: nginx -t başarısız — up sertifikası (${chost}) SİLİNMEDİ (kayıt korundu; sonra: srvctl domain fm-up ${domain} off --purge-cert)"
        fi
    elif [[ -n "$chost" && "$issued" != "1" ]]; then
        _edge_rec_set "$sname" fm-up-cert "" "" 2>/dev/null || true
    fi
    _edge_rec_gc "$sname"
    return 0
}

# nginx-audit: bu alanın kenar dosyalarını denetler (salt-okur). stdout: bulgu satırları; rc 1 = bulgu.
# $3 = custom.d/<sname> (kiracı dizini): kilit artık edge.d'de; custom.d'de 05-srvctl-origin-lock.conf ESKİ/GÜVENSİZ yerdir.
_edge_audit_domain() {
    local domain="$1" sname="$2" dir="$3" rc=0 f conf legacy
    f=$(_edge_lock_file "$sname")
    legacy="${dir}/${_EDGE_ORIGIN_LOCK_FILE}"
    if [[ -e "$legacy" || -L "$legacy" ]]; then
        echo "KENAR-KİLİT-ESKİ-YER: ${legacy} kiracı dosyalarından SONRA değerlendirilir (kiracı rewrite'ı kilidi delebilir) — sil; 'srvctl domain origin-lock ${domain} on' kilidi edge.d'ye kurar"; rc=1
    fi
    if [[ -e "$f" || -L "$f" ]]; then
        if _edge_is_generated "$sname" "$f"; then
            echo "BİLGİ: ${_EDGE_ORIGIN_LOCK_FILE}: srvctl üretimi köken kilidi (tanındı)"
        else
            echo "KENAR-KİLİT-BOZUK: ${f} srvctl kaydıyla eşleşmiyor (kayıtsız/değiştirilmiş)"; rc=1
        fi
    fi
    if _edge_rec_get "$sname" origin-lock && [[ ! -e "$f" ]]; then
        echo "KENAR-KİLİT-YOK: köken kilidi kayıtlı ama ${f} yok — yeniden: srvctl domain origin-lock ${domain} on"; rc=1
    fi
    if _edge_rec_get "$sname" origin-lock && ! _edge_vhost_check "$domain" "$sname"; then
        echo "KENAR-VHOST-SIRASI: ${_EDGE_WHY}"; rc=1
    fi
    conf=$(_edge_fmup_conf "$sname")
    if _edge_rec_get "$sname" fm-up; then
        if [[ ! -f "$conf" ]] || [[ "$(_domconf_sha256_file "$conf" 2>/dev/null)" != "$_ER_SHA" ]]; then
            echo "FM-UP-SAĞLAM-DEĞİL: ${conf} yok ya da kayıtla uyuşmuyor — yeniden üretmek için: srvctl domain fm-up ${domain} on"; rc=1
        else
            echo "BİLGİ: fm-up srvctl üretimi up sunucu bloğu (tanındı): ${_ER_EXTRA%% *}"
        fi
    fi
    return "$rc"
}
