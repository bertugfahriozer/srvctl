#!/bin/bash
# harness_safe.sh — test/lab düzeneklerinin ORTAK güvenli-kill ve geçici-dizin yardımcısı (F9b/b).
# Çalıştırılabilir test DEĞİLDİR (tests/run.sh yalnız test_*.sh'i koşar); `. harness_safe.sh` ile alınır.
# live/test/harness-safe.sh bunun BAYTI BAYTINA kopyasıdır (tests/test_harness_no_raw_kill.sh R7 bayt paritesini denetler).
#
# NEDEN (uçucu tam-süit koşusu): tests/test_domconf_fm_f8_stage.sh H1-2'de bir kez
#   "line 56: 11609 Terminated: 15  ( _domconf_fm_auth_repair ... )" -> rc 143. Kodda kill yok; dışarıdan TERM.
#   Bu makinede PID sayacı ~1 300 PID/sn ilerler (ölçüm: PID sayacı örneklemesi), yani 99999 PID ~80 sn'de DÖNER:
#   BAYAT bir PID'e (pid dosyası, $! kaydı, lsof listesi) 80 sn sonra `kill` göndermek, aynı numarayı almış
#   BAŞKA bir sürece (başka ajanın test alt kabuğuna) sinyal göndermektir. Bu yardımcı o sınıfı kapatır:
#   bir PID'e yalnız (1) bu kabuğun kendi başlattığı çocuk VE hâlâ aynı süreç (lstart aynı, ppid aynı) ise
#   ya da (2) bu koşu sırasında başlamış, adı beklenen desene uyan, pid dosyasından okunmuş bir artalan süreci
#   ise sinyal gönderilir. Aksi halde REDDEDER (rc 3), nedenini stderr'e ve HS_LOG'a yazar. `pkill -f` yok.
#
# KULLANIM
#   . harness_safe.sh
#   sleep 60 & p=$!; hs_track "$p"   # `&` sonrası HEMEN ($! önce değişkene); çocuk değilse/bitmişse izlenmez
#   hs_kill TERM "$pid"               # izlenmiyorsa ya da PID yeniden kullanılmışsa REDDEDER
#   hs_kill_group TERM "$pid"         # yalnız izlenen + kendi grubunun lideri ise `kill -TERM -- -pid`
#   hs_kill_pidfile TERM f.pid 'nginx|php-fpm'   # artalan süreci: bu koşuda başlamış + ad uyuyor
#   hs_kill_port TERM 19300 'nginx|php-fpm|python' "$LAB_ROOT"   # port dinleyicisi: ad + koşu-sonrası + lab yolu/ebeveyn
#   hs_kill_children SIG "$pid"      # izlenen ebeveynin doğrudan çocukları (nginx işçileri)
#   hs_signal_ancestor SIG PID       # PID bu kabuğun KENDİSİ ya da atası ise (öz-sinyal: test edilen alt kabuğu kesen kanca)
#   hs_reap [SIG]                     # izlenen, hâlâ bize ait tüm süreçleri kapatır (EXIT tuzağında)
#   hs_tmpdir_init <ad> [taban]       # TMPDIR'i kendi çalışma dizinine alır; /tmp, /var/tmp altı REDDEDİLİR
# UYARI ($!): bash 3.2'de hs_track `$!`'i DEĞİŞTİREBİLİR (ebeveyni bulmak için geçici çocuk başlatır). `cmd & p=$!; hs_track "$p"` yazın;
#   `hs_track "$!"; x+=($!)` YANLIŞTIR (yapısal test: test_harness_no_raw_kill.sh bu kalıbı da reddeder).
# KISIT: kayıt kabuk DEĞİŞKENİDİR; $(...)/( ... ) alt kabuğunda yapılan hs_track üst kabuğa dönmez.
#   Süreci başlatan kabukta izle, aynı kabukta kapat. bash 3.2 uyumlu (ilişkisel dizi yok).

HS_T0_EPOCH="${HS_T0_EPOCH:-$(date +%s)}"
HS_REG=""            # satır: pid|tür(c=çocuk,d=artalan)|ppid|lstart
HS_LOG="${HS_LOG:-}"
HS_LAST_PID=""

_hs_say() { printf '%s\n' "harness_safe: $*" >&2; if [[ -n "$HS_LOG" ]]; then printf '%s harness_safe: %s\n' "$(date +%H:%M:%S)" "$*" >> "$HS_LOG" 2>/dev/null; fi; return 0; }
_hs_valid_pid() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && [[ "$1" -gt 1 ]]; }
_hs_lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'; }
_hs_ppid()   { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
_hs_pgid()   { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
# Ad normalleştirme: macOS'ta yeniden başlıklandıran süreçlerin (nginx/php-fpm) `comm`'u "nginx: master pr" ya da yol içeren
# bir başlık olur (F9b/b gerçek nginx ile ölçüldü; kör `##*/` "tmp.XXXX" üretti). İlk sözcük, sondaki ':' atılır, yol ise taban adı.
_hs_comm()   { local c; c="$(ps -o comm= -p "$1" 2>/dev/null)"; c="${c%% *}"; c="${c%:}"; c="${c##*/}"; printf '%s' "$c"; }
_hs_args()   { ps -o command= -p "$1" 2>/dev/null; }
_hs_alive()  { [[ -n "$(LC_ALL=C ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" ]] && [[ "$(LC_ALL=C ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" != Z* ]]; }
# etime ([[dd-]hh:]mm:ss) -> saniye
_hs_age() {
    local e d=0 h=0 m=0 s=0
    e="$(LC_ALL=C ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
    [[ -n "$e" ]] || return 1
    if [[ "$e" == *-* ]]; then d="${e%%-*}"; e="${e#*-}"; fi
    case "$e" in
        *:*:*) h="${e%%:*}"; e="${e#*:}"; m="${e%%:*}"; s="${e#*:}" ;;
        *:*)   m="${e%%:*}"; s="${e#*:}" ;;
        *)     s="$e" ;;
    esac
    printf '%s' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}
_hs_started_after_t0() {   # süreç bu koşudan (HS_T0_EPOCH) SONRA başladı mı (1 sn payla)
    local a now; a="$(_hs_age "$1")" || return 1
    now="$(date +%s)"
    [[ "$a" -le $(( now - HS_T0_EPOCH + 1 )) ]]
}
_hs_find() { printf '%s' "$HS_REG" | grep -m1 "^${1}|" ; }

# _hs_set_me — HS_ME = bu kabuğun GERÇEK pid'i (alt kabuk/$(...) dahil). `$(_hs_me)` biçimi YANLIŞTIR (komut ikamesi kendi alt kabuğunu açar).
#   bash>=4: BASHPID. bash 3.2: geçici bir çocuk başlatılır, ebeveyni (= çocuğu `&` ile doğuran kabuk) ps ile okunur.
_hs_set_me() {
    local pr
    if [[ -n "${BASHPID:-}" ]]; then HS_ME="$BASHPID"; return 0; fi
    sleep 30 & pr=$!
    HS_ME="$(ps -o ppid= -p "$pr" 2>/dev/null | tr -d ' ')"
    kill "$pr" 2>/dev/null; wait "$pr" 2>/dev/null || true
    return 0
}

# hs_track PID — kendi çocuğumuzu kaydet (`cmd & p=$!; hs_track "$p"`). Çocuk değilse / yoksa kaydetmez.
hs_track() {
    local p="${1:-}" pp ls me; _hs_set_me; me="$HS_ME"
    _hs_valid_pid "$p" || { _hs_say "track REDDEDİLDİ: geçersiz pid '${p}'"; return 2; }
    pp="$(_hs_ppid "$p")"; ls="$(_hs_lstart "$p")"
    [[ -n "$pp" && -n "$ls" ]] || return 1
    if [[ "$pp" != "$me" ]]; then _hs_say "track REDDEDİLDİ: pid ${p} bu kabuğun (${me}) çocuğu değil (ppid ${pp})"; return 3; fi
    HS_REG="${HS_REG}${p}|c|${pp}|${ls}"$'\n'
    return 0
}

# hs_owned PID — kayıtlı VE aynı süreç (lstart aynı) VE (çocuksa) ppid aynı mı
hs_owned() {
    local p="${1:-}" rec kind ppid ls now_ls now_pp
    _hs_valid_pid "$p" || return 1
    rec="$(_hs_find "$p")" || return 1
    kind="$(printf '%s' "$rec" | cut -d'|' -f2)"; ppid="$(printf '%s' "$rec" | cut -d'|' -f3)"; ls="$(printf '%s' "$rec" | cut -d'|' -f4-)"
    now_ls="$(_hs_lstart "$p")"; [[ -n "$now_ls" && "$now_ls" == "$ls" ]] || return 1
    if [[ "$kind" == c ]]; then now_pp="$(_hs_ppid "$p")"; [[ "$now_pp" == "$ppid" ]] || return 1; fi
    return 0
}

# hs_kill SIG PID — rc 0: gönderildi ya da süreç zaten yok; rc 3: REDDEDİLDİ (bize ait değil / PID yeniden kullanılmış)
hs_kill() {
    local sig="${1:-}" p="${2:-}"
    sig="${sig#-}"
    [[ -n "$sig" ]] || { _hs_say "kill REDDEDİLDİ: sinyal yok"; return 3; }
    _hs_valid_pid "$p" || { _hs_say "kill REDDEDİLDİ: geçersiz pid '${p}'"; return 3; }
    _hs_alive "$p" || return 0
    if ! hs_owned "$p"; then
        _hs_say "kill ${sig} REDDEDİLDİ pid=${p}: kayıtsız ya da PID yeniden kullanılmış (komut: $(_hs_args "$p" | cut -c1-80))"
        return 3
    fi
    kill "-${sig}" "$p" 2>/dev/null
    return 0
}

# hs_kill_group SIG PID — izlenen VE kendi grubunun lideri (setsid/set -m/setpgid ile başlatılmış) ise grubu kapat
hs_kill_group() {
    local sig="${1:-}" p="${2:-}"
    sig="${sig#-}"
    _hs_valid_pid "$p" || { _hs_say "kill_group REDDEDİLDİ: geçersiz pid '${p}'"; return 3; }
    _hs_alive "$p" || return 0
    if ! hs_owned "$p"; then _hs_say "kill_group ${sig} REDDEDİLDİ pid=${p}: kayıtsız ya da PID yeniden kullanılmış"; return 3; fi
    if [[ "$(_hs_pgid "$p")" != "$p" ]]; then _hs_say "kill_group REDDEDİLDİ pid=${p}: grup lideri değil (pgid $(_hs_pgid "$p"))"; return 3; fi
    kill "-${sig}" -- "-${p}" 2>/dev/null
    return 0
}

# hs_track_pidfile FILE COMMRE — artalan sürecini pid dosyasından kaydet. HS_LAST_PID'e yazar.
#   Kabul: pid geçerli, süreç canlı, adı COMMRE'ye uyar, BU KOŞUDAN SONRA başlamış (bayat dosya/eski PID reddedilir).
hs_track_pidfile() {
    local f="${1:-}" re="${2:-}" p c ls
    HS_LAST_PID=""
    [[ -n "$re" ]] || { _hs_say "pidfile REDDEDİLDİ: ad deseni zorunlu"; return 3; }
    [[ -f "$f" ]] || return 1
    p="$(head -1 "$f" 2>/dev/null | tr -d ' \r')"
    [[ -n "$p" ]] || return 1          # boş pid dosyası (süreç temiz çıkmış / henüz yazılmamış): yapacak iş yok
    _hs_valid_pid "$p" || { _hs_say "pidfile REDDEDİLDİ: ${f}: geçersiz içerik"; return 3; }
    _hs_alive "$p" || return 1
    c="$(_hs_comm "$p")"
    if ! [[ "$c" =~ ^($re)$ ]]; then _hs_say "pidfile REDDEDİLDİ pid=${p}: ad '${c}' ~ '${re}' değil (bayat dosya/PID yeniden kullanılmış)"; return 3; fi
    if ! _hs_started_after_t0 "$p"; then _hs_say "pidfile REDDEDİLDİ pid=${p}: süreç bu koşudan ÖNCE başlamış (bayat PID)"; return 3; fi
    ls="$(_hs_lstart "$p")"; [[ -n "$ls" ]] || return 1
    HS_REG="${HS_REG}${p}|d|$(_hs_ppid "$p")|${ls}"$'\n'
    HS_LAST_PID="$p"
    return 0
}
hs_kill_pidfile() {   # SIG FILE COMMRE
    local sig="${1:-}" f="${2:-}" re="${3:-}" rc=0
    hs_track_pidfile "$f" "$re"; rc=$?
    [[ "$rc" -eq 0 ]] || { [[ "$rc" -eq 1 ]] && return 0; return "$rc"; }
    hs_kill "$sig" "$HS_LAST_PID"
}

# hs_kill_port SIG PORT COMMRE [NEEDLE] — PORT'u dinleyen süreçlerden YALNIZ: adı uyan + bu koşudan sonra başlamış +
#   (komutu ya da ebeveyninin komutu NEEDLE içeriyor VEYA ebeveyn 1 (yetim işçi) VEYA ebeveyni izlenen).
#   Başka biri (ör. aynı portu paralel kullanan başka ajan) REDDEDİLİR.
hs_kill_port() {
    local sig="${1:-}" port="${2:-}" re="${3:-}" needle="${4:-}" p c pp rc=0 ok
    sig="${sig#-}"
    [[ "$port" =~ ^[1-9][0-9]*$ && -n "$re" ]] || { _hs_say "kill_port REDDEDİLDİ: port/ad deseni geçersiz"; return 3; }
    for p in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
        _hs_valid_pid "$p" || continue
        c="$(_hs_comm "$p")"; ok=0
        if [[ "$c" =~ ^($re)$ ]] && _hs_started_after_t0 "$p"; then
            pp="$(_hs_ppid "$p")"
            if [[ -n "$needle" && "$(_hs_args "$p")" == *"$needle"* ]]; then ok=1
            elif [[ -n "$needle" && -n "$pp" && "$(_hs_args "$pp")" == *"$needle"* ]]; then ok=1
            elif [[ "$pp" == 1 ]]; then ok=1
            elif hs_owned "$p" || hs_owned "$pp"; then ok=1; fi
        fi
        if [[ "$ok" -eq 1 ]]; then
            HS_REG="${HS_REG}${p}|d|$(_hs_ppid "$p")|$(_hs_lstart "$p")"$'\n'
            hs_kill "$sig" "$p" || rc=3
        else
            _hs_say "kill_port ${sig} REDDEDİLDİ port=${port} pid=${p} (${c}): bu lab'a ait olduğu kanıtlanamadı"; rc=3
        fi
    done
    return "$rc"
}

# hs_kill_children SIG PID — PID bize ait (hs_owned) ise YALNIZ doğrudan çocuklarına sinyal (ör. izlenen nginx ana süreci -> işçiler).
#   Çocuk listesi anlık alınır; her çocuk için kill'den hemen önce ebeveynin hâlâ PID olduğu yeniden doğrulanır.
hs_kill_children() {
    local sig="${1:-}" p="${2:-}" c rc=0
    sig="${sig#-}"
    _hs_valid_pid "$p" || { _hs_say "kill_children REDDEDİLDİ: geçersiz pid '${p}'"; return 3; }
    _hs_alive "$p" || return 0
    if ! hs_owned "$p"; then _hs_say "kill_children ${sig} REDDEDİLDİ pid=${p}: ebeveyn kayıtsız ya da PID yeniden kullanılmış"; return 3; fi
    for c in $(ps -axo pid=,ppid= 2>/dev/null | awk -v p="$p" '$2 == p { print $1 }'); do
        _hs_valid_pid "$c" || continue
        [[ "$(_hs_ppid "$c")" == "$p" ]] || continue
        kill "-${sig}" "$c" 2>/dev/null || rc=1
    done
    return 0
}

# hs_signal_ancestor SIG PID — PID bu kabuğun KENDİSİ ya da CANLI bir atasıysa sinyal gönderir (öz-sinyal: "test edilen alt kabuğu kesen
#   kanca"). Atalık ppid zincirinden DOĞRULANIR (en çok 64 basamak): bayat/yeniden kullanılmış bir PID bu kabuğun atası olamaz
#   (ata ölürse biz yetim kalır, zincir 1'e çıkar) -> başka sürece sinyal yolu kapalı. Atası olmayan PID'e REDDEDER (rc 3).
hs_signal_ancestor() {
    local sig="${1:-}" p="${2:-}" cur n=0
    sig="${sig#-}"
    [[ -n "$sig" ]] || { _hs_say "signal_ancestor REDDEDİLDİ: sinyal yok"; return 3; }
    _hs_valid_pid "$p" || { _hs_say "signal_ancestor REDDEDİLDİ: geçersiz pid '${p}'"; return 3; }
    _hs_set_me; cur="$HS_ME"
    while _hs_valid_pid "$cur" && [[ "$n" -lt 64 ]]; do
        if [[ "$cur" == "$p" ]]; then kill "-${sig}" "$p" 2>/dev/null; return 0; fi
        cur="$(_hs_ppid "$cur")"; n=$((n + 1))
    done
    _hs_say "signal_ancestor ${sig} REDDEDİLDİ pid=${p}: bu kabuğun (${HS_ME}) kendisi/atası değil"
    return 3
}

# hs_reap [SIG] — kayıtlı ve hâlâ bize ait olan her süreci kapatır (EXIT tuzağı için; hata vermez)
hs_reap() {
    local sig="${1:-TERM}" line p
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        p="${line%%|*}"
        hs_kill "$sig" "$p" 2>/dev/null || true
    done <<< "$HS_REG"
    return 0
}

# hs_tmpdir_init AD [TABAN] — TMPDIR'i bu düzeneğin kendi çalışma dizinine alır ve dışa aktarır.
#   Taban: $2 > $HARNESS_WORK_BASE > <çağıran betik dizini>/../.work. /tmp, /var/tmp, /private/tmp, /private/var/tmp altı REDDEDİLİR.
#   Dönüş: TMPDIR = <taban>; mktemp'ler `mktemp -d "${TMPDIR:?}/<önek>.XXXXXX"` biçiminde açık şablon kullanır.
hs_tmpdir_init() {
    local name="${1:-harness}" base="${2:-${HARNESS_WORK_BASE:-}}" real
    if [[ -z "$base" ]]; then
        base="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")/.." 2>/dev/null && pwd)/.work"
    fi
    # ÖNCE doğrula (en yakın var olan atayı çözümle: sembolik bağ /tmp'ye çıkıyorsa mkdir ÇALIŞMAZ), SONRA oluştur
    hs_assert_not_tmp "$base" || { _hs_say "tmpdir REDDEDİLDİ (${name}): ${base}"; return 3; }
    mkdir -p "$base" 2>/dev/null || { _hs_say "tmpdir REDDEDİLDİ: ${base} oluşturulamadı"; return 3; }
    real="$(cd -P "$base" 2>/dev/null && pwd)" || return 3
    hs_assert_not_tmp "$real" || return 3
    [[ -w "$real" ]] || { _hs_say "tmpdir REDDEDİLDİ: ${real} yazılamıyor"; return 3; }
    TMPDIR="$real"; export TMPDIR
    HS_WORK_BASE="$real"; export HS_WORK_BASE
    return 0
}
# hs_assert_not_tmp YOL — YOL (çözümlenmiş) /tmp benzeri bir yerdeyse rc 3
hs_assert_not_tmp() {
    local p="${1:-}" real d
    d="$p"; while [[ ! -e "$d" && "$d" != / && -n "$d" ]]; do d="$(dirname "$d")"; done
    real="$(cd -P "$d" 2>/dev/null && pwd)" || return 3
    case "$real" in
        /tmp|/tmp/*|/private/"tmp"|/private/"tmp"/*|/var/tmp|/var/tmp/*|/private/var/tmp|/private/var/tmp/*) _hs_say "yazım REDDEDİLDİ: ${p} -> ${real}"; return 3 ;;
    esac
    return 0
}
