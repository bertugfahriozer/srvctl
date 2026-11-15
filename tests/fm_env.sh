#!/bin/bash
# shellcheck disable=SC2034  # değişkenler bu dosyayı source eden testlerce kullanılır
# FM (fm-auth / köken kaydı / nginx-audit / clone) testleri için ORTAK iskele.
# Çalıştırılabilir test DEĞİLDİR (tests/run.sh yalnız test_*.sh'i koşar); ilgili testler
# 'source "${REPO_ROOT}/tests/fm_env.sh"' ile alır.
#
# Sağladıkları:
#  - geçici WEB_ROOT / custom.d / sites-available / SRVCTL_STATE_DIR (WEB_ROOT ALTINDA:
#    assert_root_owned_path zinciri WEB_ROOT'ta biter — emsal tests/test_lock_symlink_privesc.sh)
#  - _stat_owner taklidi: macOS'ta dosyalar root'a ait değildir. MOCK_BAD_OWNER (boşlukla
#    ayrık yollar) listesindeki yollar 'web_x' sahipli görünür, geri kalan 'root'.
#  - flock taklidi (PATH başında): çağrıları FLOCK_LOG'a yazar; FLOCK_RC≠0 ise kilit ALINAMAZ.
#  - nginx / systemctl taklitleri (işlev): -t sonucu NGINX_TEST_RC; modsecurity modülü yoksa
#    (NGINX_FAIL_ON_MODSEC=1) üretilmiş dosyadaki 'modsecurity off;' için gerçek mesaj biçimi.
#  - alan: example.com (sname example_com), vhost custom.d'yi include eder.
umask 077
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
WEB_ROOT="$(mktemp -d)"
export WEB_ROOT
export SRVCTL_NGINX_CUSTOM_DIR="${WEB_ROOT}/.custom.d"
export SITES_AVAILABLE="${WEB_ROOT}/.sites-available"
export SRVCTL_STATE_DIR="${WEB_ROOT}/.state"
# F7-H3: acil kapatma işaretinin İKİNCİ güvenilir konumu (kayıt dizininden bağımsız); dizin ilk ihtiyaçta oluşturulur.
export SRVCTL_FM_EMERGENCY_DIR="${WEB_ROOT}/.fm-emergency"
export SRVCTL_PHP_INI_DIR="${WEB_ROOT}/.php.d"
mkdir -p "$SRVCTL_NGINX_CUSTOM_DIR" "$SITES_AVAILABLE" "$SRVCTL_STATE_DIR" "$SRVCTL_PHP_INI_DIR"
FM_STUBS="$(mktemp -d)"
FLOCK_LOG="${FM_STUBS}/flock.log"; : > "$FLOCK_LOG"
cat > "${FM_STUBS}/flock" <<'FLOCKEOF'
#!/bin/bash
echo "$*" >> "${FLOCK_LOG:?}"
exit "${FLOCK_RC:-0}"
FLOCKEOF
chmod +x "${FM_STUBS}/flock"
export FLOCK_LOG
export PATH="${FM_STUBS}:${PATH}"
# rev-L9: iki geçici dizin çıkışta silinir (önceden her test 2 dizin sızdırıyordu; GNU mktemp +
# TMPDIR ile ölçüldü — macOS mktemp -d şablonsuzken TMPDIR'ı yok sayar). Yollar oluşturulduğu
# anda saklanır: test WEB_ROOT'u sonradan değiştirse de yalnız BU dizinler silinir. bash'te EXIT
# tuzağı tektir: kendi EXIT tuzağını kuran test '_fm_env_cleanup'ı o tuzağa EKLEMELİDİR
# (tests/test_fm_env_cleanup.sh bunu yapısal olarak denetler). Ara dosya/dizin üretmek isteyen
# alt kabuklar FM_STUBS altında üretmelidir (birlikte silinir).
_FM_ENV_DIRS="${WEB_ROOT}"$'\n'"${FM_STUBS}"
_fm_env_cleanup() {
    local d
    while IFS= read -r d; do
        [[ -n "$d" && "${d##*/}" == tmp.* && -d "$d" && ! -L "$d" ]] || continue
        chmod -R u+rwX -- "$d" 2>/dev/null || true
        rm -rf -- "${d:?}"
    done <<< "${_FM_ENV_DIRS:-}"
    return 0
}
trap '_fm_env_cleanup' EXIT

source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
export SRVCTL_ROOT SRVCTL_TEMPLATES
log_action() { :; }
send_notification() { :; }

MOCK_BAD_OWNER=""
_stat_owner() {
    case " ${MOCK_BAD_OWNER} " in
        *" $1 "*) printf 'web_x' ;;
        *) printf 'root' ;;
    esac
}

NGINX_TEST_RC=0
NGINX_FAIL_ON_MODSEC=0
# NGINX_T_CALLS KALDIRILDI: alt kabukta (_on, ( … )) artan sayaç ebeveyne dönmez → boş kilit üretiyordu.
# Çağrı sayımı NGINX_T_LOG'dan yapılır (t / p / T satırları).
NGINX_PROBE_RC=0
NGINX_PROBE_MSG=""
NGINX_T_ARGS=""
NGINX_T_LOG="${FM_STUBS}/nginx-t.log"; : > "$NGINX_T_LOG"
CUR_DIR="${SRVCTL_NGINX_CUSTOM_DIR}/example_com"
# Ana nginx yapılandırması (ModSecurity sondasının load_module kaynağı; QL4-M3). Saptama
# yolunu sınayan testler bunu kendisi değiştirir/kaldırır.
printf 'events { }\nhttp { }\n' > "${FM_STUBS}/nginx.conf"
export SRVCTL_NGINX_CONF="${FM_STUBS}/nginx.conf"
# 'nginx -t' taklidi: NGINX_TEST_RC≠0 → hata; NGINX_FAIL_ON_MODSEC=1 iken üretilmiş dosyalardan
# birinde 'modsecurity off;' varsa gerçek nginx'in modül-yok mesajı. NGINX_T_HOOK: her -t'de çağrılır
# (NGINX_T_ARGS = o çağrının argümanları).
# 'nginx -t -c <dosya>' = srvctl'in BAĞIMSIZ ModSecurity sondası (canlı yapılandırma DEĞİL): günlüğe
# 'p' yazılır; NGINX_TEST_RC/NGINX_T_MSG (canlı yapılandırma kusurları) ona UYGULANMAZ; modül yokken
# (NGINX_FAIL_ON_MODSEC=1) sonda dosyasındaki 'modsecurity' için gerçek mesaj; NGINX_PROBE_RC/MSG
# sondanın başka nedenle düşmesi. 'nginx -V' → NGINX_V_OUT (stderr).
nginx() {
    if [[ "$1" == "-t" && "${2:-}" == "-c" && -n "${3:-}" ]]; then
        NGINX_T_ARGS="$*"
        echo "p" >> "$NGINX_T_LOG"
        [[ -n "${NGINX_T_HOOK:-}" ]] && "$NGINX_T_HOOK"
        [[ -n "${NGINX_PROBE_MSG:-}" ]] && { echo "$NGINX_PROBE_MSG"; return 1; }
        [[ "${NGINX_PROBE_RC:-0}" != "0" ]] && { echo "nginx: [emerg] mock sonda hatası"; return 1; }
        if [[ "$NGINX_FAIL_ON_MODSEC" == "1" ]]; then
            local pl
            pl=$(grep -n 'modsecurity' "$3" 2>/dev/null | head -1 | cut -d: -f1)
            if [[ -n "$pl" ]]; then echo "nginx: [emerg] unknown directive \"modsecurity\" in ${3}:${pl}"; return 1; fi
        fi
        return 0
    fi
    if [[ "$1" == "-V" ]]; then
        printf '%s\n' "${NGINX_V_OUT:-nginx version: nginx/mock}" >&2
        return 0
    fi
    if [[ "$1" == "-t" ]]; then
        NGINX_T_ARGS="$*"
        echo "t" >> "$NGINX_T_LOG"
        [[ -n "${NGINX_T_HOOK:-}" ]] && "$NGINX_T_HOOK"
        [[ "$NGINX_TEST_RC" != "0" ]] && { echo "nginx: [emerg] mock hata"; return 1; }
        [[ -n "${NGINX_T_MSG:-}" ]] && { echo "$NGINX_T_MSG"; return 1; }
        if [[ "$NGINX_FAIL_ON_MODSEC" == "1" ]]; then
            local f
            for f in "${CUR_DIR}"/*.conf; do
                [[ -f "$f" ]] || continue
                if grep -qE '^[[:space:]]*modsecurity off;' "$f"; then
                    echo "nginx: [emerg] unknown directive \"modsecurity\" in ${f}:1"
                    return 1
                fi
            done
        fi
        return 0
    fi
    if [[ "$1" == "-T" ]]; then
        echo "T" >> "$NGINX_T_LOG"
        [[ "${MOCK_DUMP_MODE:-}" == "fail" ]] && return 1
        local f
        [[ "${MOCK_DUMP_MODE:-}" == "empty" ]] && return 0
        printf '# configuration file /etc/nginx/nginx.conf:\nevents {}\n\n'
        for f in "${CUR_DIR}"/*.conf; do
            [[ -f "$f" ]] || continue
            printf '# configuration file %s:\n' "$f"
            cat "$f"
            [[ "${MOCK_DUMP_MODE:-}" == "mismatch" ]] && printf 'return 204;\n'
            printf '\n'
        done
        if [[ "${MOCK_DUMP_MODE:-}" == "dupmarker" ]]; then
            printf '# configuration file %s:\nevents {}\n' "${CUR_DIR}/00-custom.conf"
        fi
        return 0
    fi
    return 0
}
RELOAD_LOG="${FM_STUBS}/reload.log"; : > "$RELOAD_LOG"
# F6-M1: "çalışan nginx" benzetimi — son BAŞARILI reload'un o anki custom.d içeriği (gerçek nginx de yalnız
# reload'da diski yeniden okur). Başarısız reload (SYSTEMCTL_RC≠0) çalışan görüntüyü DEĞİŞTİRMEZ. Disk bir
# testte elle kurulursa fm_sim_reload ile "reload edilmiş" gibi görüntülenir.
FM_RUNNING="${FM_STUBS}/running"; mkdir -p "$FM_RUNNING"
fm_sim_reload() {
    rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"
    local f
    for f in "${CUR_DIR}"/*.conf; do [[ -f "$f" ]] && cp -p "$f" "$FM_RUNNING/"; done
    return 0
}
systemctl() {
    [[ "$1" == "reload" ]] && { echo r >> "$RELOAD_LOG"; }
    [[ "${SYSTEMCTL_RC:-0}" == "0" ]] || return 1
    [[ "$1" == "reload" ]] && fm_sim_reload
    return 0
}

# F6-M1/F7-M1: curl taklidi (çalışan-durum sondası). SARMALAYICI KANITI: her çağrı CURL_LOG'a "ALLOW|DENY <url> resolve=<…>"
# yazılır; YALNIZ `--resolve <alan>:<port>:127.0.0.1` ile aynı <alan>:<port> hedefine izin verilir, başka her hedef
# (dış ad/IP, resolve'suz) DENY + rc 7 olur — sondanın dışarı istek atmadığı test edilebilir. Her çağrının TAM argüman
# satırı CURL_ARGS_LOG'a yazılır (bayrak kilitleri: --noproxy '*', zaman aşımları, --path-as-is, -X PUT …).
# ETKİNLEŞTİRME: yalnız FM_MOCK_CURL=1 iken (source'tan ÖNCE atanır) — gerçek curl'e ihtiyaç duyan testler
# (test_domconf_nginx_real.sh) bozulmasın. Etkin DEĞİLSE çalışan-durum sondası KAPATILIR (portlar "off"; hiçbir
# curl çağrılmaz, durum "doğrulanamadı").
# YANIT BİÇİMİ gerçek curl gibidir: `-o -` ise gövde stdout'a, `-o /dev/null` ise atılır; `-w` biçimi HER ZAMAN yazılır
# (%{http_code} → kod, \n → satırsonu; bağlantı hatasında bile "000"). --max-filesize N: gövde N bayttan uzunsa curl
# gövdeyi VERMEZ ve rc 63 döner (kod yine yazılır). Bağlantı yok (kod 000) → rc 7.
# FM_PROBE_MODE_DEFAULT (F7/a1): FM_PROBE_MODE'un başlangıç ve _fm_reset sonrası değeri (varsayılan unknown); 'fm-auth off'
#   ÇALIŞAN durumu da sınadığı için (F7-H2) off koşan testler FM_MOCK_CURL=1 FM_PROBE_MODE_DEFAULT=sim ile açar.
# FM_PROBE_MODE: silent (curl hiçbir şey yazmadan rc 28 ile düşer) | unknown (varsayılan: bağlantı yok → kod 000) | sim (FM_RUNNING görüntüsüne göre: açık şablon → 411 +
#   dosyadaki 411 gövdesi; imzalı/imzasız 403 kökü → 403 + dosyadaki 403 gövdesi; dosya yok → 404) |
#   fixed (FM_PROBE_CODE_HTTPS / FM_PROBE_CODE_HTTP sabit kodlar; GÖVDE: FM_PROBE_BODY_HTTPS / FM_PROBE_BODY_HTTP
#   TANIMLIYSA (boş dize dahil) aynen o; tanımlı DEĞİLSE otomatik: 403 → "srvctl-fm-closed <sig>", 411 →
#   "srvctl-fm-open <sig>" [sig = sorgulanan alan için _domconf_fm_body_sig], diğer kodlar → boş gövde).
CURL_LOG="${FM_STUBS}/curl.log"; : > "$CURL_LOG"
CURL_ARGS_LOG="${FM_STUBS}/curl-args.log"; : > "$CURL_ARGS_LOG"
FM_PROBE_MODE="${FM_PROBE_MODE_DEFAULT:-unknown}"; FM_PROBE_CODE_HTTPS="000"; FM_PROBE_CODE_HTTP="000"
if [[ "${FM_MOCK_CURL:-0}" != "1" ]]; then
    export SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT=off
else
curl() {
    local url="" resolve="" put=0 code="000" body="" scheme hostport host f20 outt="" wfmt="" maxfs="" crc=0 line a pat
    echo "$*" >> "$CURL_ARGS_LOG"
    while (( $# )); do
        case "$1" in
            --resolve) resolve="${2:-}"; shift ;;
            -X) [[ "${2:-}" == "PUT" ]] && put=1; shift ;;
            -o) outt="${2:-}"; shift ;;
            -o-) outt="-" ;;
            -w) wfmt="${2:-}"; shift ;;
            --max-filesize) maxfs="${2:-}"; shift ;;
            --connect-timeout|--max-time|--noproxy|-H) shift ;;
            http://*|https://*) url="$1" ;;
        esac
        shift
    done
    scheme="${url%%://*}"; hostport="${url#*://}"; hostport="${hostport%%/*}"; host="${hostport%%:*}"
    if [[ -z "$url" || "$resolve" != "${hostport}:127.0.0.1" ]]; then
        echo "DENY ${url:-?} resolve=${resolve:-yok}" >> "$CURL_LOG"
        pat='%{http_code}'; line="${wfmt//"$pat"/000}"; printf '%s' "${line//'\n'/$'\n'}"
        return 7
    fi
    echo "ALLOW ${url} put=${put} resolve=${resolve}" >> "$CURL_LOG"
    case "${FM_PROBE_MODE:-unknown}" in
        silent) return 28 ;;   # curl hiçbir şey yazmadan düşer (-w bile basılmaz): sondanın savunması
        fixed)
            if [[ "$scheme" == "https" ]]; then
                code="${FM_PROBE_CODE_HTTPS}"
                if [[ -n "${FM_PROBE_BODY_HTTPS+x}" ]]; then body="$FM_PROBE_BODY_HTTPS"; fi
                a="${FM_PROBE_BODY_HTTPS+set}"
            else
                code="${FM_PROBE_CODE_HTTP}"
                if [[ -n "${FM_PROBE_BODY_HTTP+x}" ]]; then body="$FM_PROBE_BODY_HTTP"; fi
                a="${FM_PROBE_BODY_HTTP+set}"
            fi
            # FM_PROBE_SEQ=<dosya>: her çağrı dosyanın İLK satırını kod olarak tüketir (çağrılar arası değişen
            # durum: ör. reload sonrası worker'lar yenilenene dek 411, sonra 403). Boşalınca son kod geçerli kalır.
            if [[ -n "${FM_PROBE_SEQ:-}" && -s "$FM_PROBE_SEQ" ]]; then
                code=$(head -1 "$FM_PROBE_SEQ"); sed -i.sq 1d "$FM_PROBE_SEQ" 2>/dev/null; rm -f "${FM_PROBE_SEQ}.sq"
                a=""
            fi
            if [[ -z "$a" ]]; then
                case "$code" in
                    403) body="srvctl-fm-closed $(_domconf_fm_body_sig "$(safe_name "$host")")" ;;
                    411) body="srvctl-fm-open $(_domconf_fm_body_sig "$(safe_name "$host")")" ;;
                esac
            fi ;;
        sim)
            case " ${FM_SIM_SCHEMES:-https http} " in
                *" ${scheme} "*)
                    f20="${FM_RUNNING}/20-srvctl-fm-upload.conf"
                    if [[ ! -f "$f20" ]]; then code="404"
                    elif grep -q 'auth_request' "$f20"; then
                        code="411"; body=$(sed -n 's/.*return 411 "\([^"]*\)".*/\1/p' "$f20" | head -1)
                    elif grep -q 'return 403' "$f20"; then
                        code="403"; body=$(sed -n 's/^location \^~ \/_fm\/ { return 403 "\([^"]*\)"; }$/\1/p' "$f20" | head -1)
                    else code="404"; fi ;;
            esac ;;
    esac
    if [[ "$code" == "000" ]]; then body=""; crc=7; fi
    if [[ -n "$maxfs" && ${#body} -gt $maxfs ]]; then body=""; crc=63; fi
    if [[ "$outt" == "-" ]]; then printf '%s' "$body"; fi
    if [[ -n "$wfmt" ]]; then
        pat='%{http_code}'; line="${wfmt//"$pat"/$code}"
        printf '%s' "${line//'\n'/$'\n'}"
    fi
    return $crc
}
fi
# Alt kabuklarda ( ... ) sayaç kaybolur → reload'lar DOSYAYA yazılır.
_reloads() { wc -l < "$RELOAD_LOG" | tr -d ' '; }

mkdir -p "${WEB_ROOT}/example.com"
VHOST="${SITES_AVAILABLE}/example.com.conf"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
SCRIPT="/current/modules/FileManager/Auth/fm-auth.php"
F90="${CUR_DIR}/90-srvctl-fm-auth.conf"
F21="${CUR_DIR}/21-srvctl-fm-download.conf"
F20="${CUR_DIR}/20-srvctl-fm-upload.conf"
MAN="${SRVCTL_STATE_DIR}/_fm-auth/example_com.manifest"
mkdir -p "$CUR_DIR"

_exists() { [[ -e "$1" || -L "$1" ]] && echo var || echo yok; }
_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
_md5() { if command -v md5sum >/dev/null 2>&1; then md5sum < "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
_fm_reset() {
    # Tüm FM durumunu sıfırla (dosyalar + köken kaydı + sayaçlar + taklit bayrakları).
    rm -rf -- "${CUR_DIR:?}" "${SRVCTL_STATE_DIR:?}/_fm-auth" "${SRVCTL_FM_EMERGENCY_DIR:?}"
    mkdir -p "$CUR_DIR"
    NGINX_TEST_RC=0; NGINX_FAIL_ON_MODSEC=0; NGINX_T_HOOK=""; MOCK_DUMP_MODE=""; MOCK_BAD_OWNER=""
    NGINX_PROBE_RC=0; NGINX_PROBE_MSG=""; NGINX_T_ARGS=""
    FLOCK_RC=0; export FLOCK_RC; SYSTEMCTL_RC=0; NGINX_T_MSG=""
    : > "$RELOAD_LOG"; : > "$FLOCK_LOG"; : > "$NGINX_T_LOG"
    FM_PROBE_MODE="${FM_PROBE_MODE_DEFAULT:-unknown}"; FM_PROBE_CODE_HTTPS="000"; FM_PROBE_CODE_HTTP="000"; FM_SIM_SCHEMES="https http"
    unset FM_PROBE_BODY_HTTPS FM_PROBE_BODY_HTTP FM_PROBE_SEQ
    : > "$CURL_ARGS_LOG"; : > "$CURL_LOG"; rm -rf "${FM_RUNNING:?}"; mkdir -p "$FM_RUNNING"
}

# ── Yorum-DIŞI yapısal denetim (lexer tabanlı; QL3-M5 sınıfı) ───────────────────────
# fm_collect <dosya>: dosyayı _domconf_nginx_parse ile çözümler; yorumlar lexer'da ZATEN
# yoktur. Her ifade/blok başlığı _FM_COLL'a "<satır>|<üst blok yolu>|<ad> <argümanlar>" olarak
# eklenir. Üst blok yolu bloklarının başlıkları " > " ile birleşir ('' = dosya düzeyi).
# fm_has <üst yol> <direktif>: tam eşleşme (argüman jetonları tek boşlukla birleşik).
_FM_COLL=""
_FM_PATHS=()
_fm_coll_cb() {
    local kind="$1" line="$2"; shift 2
    local d=${#_NGX_STACK[@]} path="" i name="$1"; shift
    for ((i = 0; i < d; i++)); do
        if [[ -n "$path" ]]; then path+=" > "; fi
        path+="${_FM_PATHS[i]}"
    done
    local args="$*"
    _FM_COLL+="${line}|${path}|${name}${args:+ ${args}}"$'\n'
    if [[ "$kind" == "open" ]]; then
        _FM_PATHS[d]="${name}${args:+ ${args}}"
    fi
    return 0
}
fm_collect() {
    _FM_COLL=""; _FM_PATHS=()
    local rc=0
    _domconf_nginx_parse "$1" _fm_coll_cb || rc=$?
    return $rc
}
fm_has() {
    case $'\n'"${_FM_COLL}" in
        *$'\n'[0-9]*"|${1}|${2}"$'\n'*) return 0 ;;
    esac
    return 1
}
# fm_line <üst yol> <direktif> → ilk satır numarası (bulunamazsa boş)
fm_line() {
    local l
    while IFS= read -r l; do
        case "$l" in
            *"|${1}|${2}") printf '%s' "${l%%|*}"; return 0 ;;
        esac
    done <<< "$_FM_COLL"
    return 1
}
