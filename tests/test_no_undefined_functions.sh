#!/bin/bash
# Modül-farkında tanımsız/çapraz-modül _fonksiyon çağrısı dedektörü.
#
# BU DOSYA v2'DİR. v1 (P0) şu sınıfı bulmak için yazılmıştı: lib/security.sh
# lib/domain.sh'taki fonksiyonları çağırıyordu ve bazıları (_domain_activate_
# fpm_unit / _harden_fs_apply / _harden_fs_revert) HİÇ YAZILMAMIŞTI — bin/srvctl
# `_load_and_run` YALNIZ TEK modülü source ettiğinden bunlar runtime'da
# "command not found" (127) veriyordu. v1 bunu TÜM lib/*.sh'i tek "tanımlı"
# havuzunda birleştirerek yakaladı.
#
# code-reviewer v1'in ÜÇ KÖR NOKTASINI buldu (ve doğrulandı):
#
#  1) ÇAPRAZ-MODÜL KONTROLÜ YOK. v1 tüm dosyaları tek havuzda erittiğinden
#     "security.sh domain.sh'ın bir fonksiyonunu ÇAĞIRIYOR ama domain.sh'ı
#     SOURCE ETMİYOR" durumunu hiç göremiyordu — fonksiyon SOMEWHERE
#     tanımlıysa PASS veriyordu, gerçek çalışma zamanı topolojisini (hangi
#     dosya hangi dosyayı GERÇEKTEN source ediyor) modellemiyordu. v1'in tüm
#     varlık sebebi olan orijinal P0 hatası, eğer security.sh domain.sh'ı
#     source ETMEDEN çağırsaydı, v1 tarafından YAKALANAMAZDI.
#  2) ARGÜMANSIZ/SATIR-SONU ÇAĞRILAR GÖRÜNMÜYOR. v1'in regex'i çağrı
#     sonrası [[:space:]] şart koşuyordu; satır sonundaki ya da ')'/'}' ile
#     biten çağrılar (ör. `$(_domain_foo)`, ya da lib/init.sh'taki
#     `_init_run_step ... _init_step_php` zincirinin adım fonksiyonu adları)
#     hiç eşleşmiyordu — repoda 20+ böyle çağrı var.
#  3) DOLAYLI ÇAĞRILAR DIŞARIDA. `_init_run_step "$func"` deseni 12 adım
#     fonksiyonunu STRING argüman olarak alıp `if "$func"` ile dolaylı
#     çağırıyor; isim yanlış yazılırsa adım sessizce hiç tamamlanmaz
#     (`if` koşulu olduğundan 'set -e' devreye girmez), marker asla
#     yazılmaz — hiçbir statik regex bunu doğal olarak yakalamaz.
#
# v2 ÇÖZÜMÜ:
#  (1) için: her lib/<m>.sh için İZİNLİ KÜME = kendi tanımları + core.sh
#      (her zaman ilk source edilir) + o dosyanın GERÇEKTEN source ettiği
#      modüllerin tanımları (doğrudan `source .../lib/X.sh` VEYA tek-hop
#      dolaylı: bir değişkene atanan 'lib/X.sh' yolu + o değişkenle source —
#      bkz. lib/security.sh:_security_load_domain_lib). Bu kümenin dışına
#      çıkan her çağrı BULGU sayılır.
#  (2) için: çağrı regex'i artık "güvenli AYRAÇ kümesi" (boşluk ; & | ( { \`
#      veya satır başı) ÖNCESİ / (boşluk ; & | ) } \` tırnak veya satır
#      SONU) sonrası arıyor — "herhangi bir alfanümerik-olmayan" DEĞİL:
#      bu kodun tüm yorum/mesajları TÜRKÇE olduğundan (ı ş ğ ü ö ç gibi
#      ASCII-dışı harfler) "her alfanümerik-olmayan" yaklaşımı Türkçe kelime
#      sınırlarını sahte çağrı sanıyordu (ör. 'pubkey_dosyası_veya_string'
#      -> hayalet '_veya_string' çağrısı; ayrıca saf yorum satırları da
#      ayrıca elenir).
#  (3) için: lib/init.sh'ı GERÇEKTEN source edip _init_run_step çağrılarına
#      geçirilen fonksiyon adlarını 'declare -F' ile bash'ın GERÇEK fonksiyon
#      tablosunda arıyoruz — regex belirsizliğine bağımlı değil.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

LIB_DIR="${REPO_ROOT}/lib"
CORE="${LIB_DIR}/core.sh"

# ── Fonksiyon TANIMLARI: üst düzey + girintili iç içe (ör. _security_audit
# içindeki _pass/_fail/_check gibi girintili tanımlanan yardımcılar). ──
_defs_in() {
    grep -hoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)' "$1" 2>/dev/null \
        | tr -d '() \t' | sort -u
}

# Saf yorum satırlarını (ilk anlamlı karakteri '#') at.
_nocomments() {
    grep -vE '^[[:space:]]*#' "$1" 2>/dev/null
}

# ── '_' önekli ÇAĞRILAR: güvenli ayraç ÖNCESİ / güvenli ayraç ya da satır
# sonu SONRASI. Bkz. başlık yorumu (2) — Türkçe kelime sınırı false-positive
# sınıfını burada kapatıyoruz.
_calls_in() {
    _nocomments "$1" \
        | grep -hoE '(^|[[:space:];&|(){`])_[a-z][a-z0-9_]*([[:space:];&|)}`'"'"'"]|$)' \
        | grep -oE '_[a-z][a-z0-9_]*'
}

# '$_x' / '${_x}' değişken referansları (fonksiyon DEĞİL).
_vars_in() {
    grep -hoE '\$\{?_[a-z][a-z0-9_]*' "$1" 2>/dev/null | grep -oE '_[a-z][a-z0-9_]*'
}

# ── Bu dosyanın GERÇEKTEN source ettiği diğer lib/<isim>.sh modülleri. ──
# Doğrudan: 'source' + 'lib/İSİM.sh' AYNI SATIRDA (bkz. notify.sh/backup.sh/
# trusted.sh guard'lı deseni: 'source ".../lib/notify.sh" 2>/dev/null || true').
# Dolaylı tek-hop: bir değişkene atanan 'lib/İSİM.sh' yolu, SONRA o
# değişkenle yapılan 'source' (bkz. lib/security.sh:_security_load_domain_lib
# -> local lib="${SRVCTL_ROOT}/lib/domain.sh"; source "$lib").
_sourced_modules_in() {
    local f="$1" self
    self="$(basename "$f" .sh)"
    {
        grep -E '(^|[^A-Za-z0-9_])source[[:space:]]' "$f" 2>/dev/null \
            | grep -oE 'lib/[A-Za-z0-9_-]+\.sh' \
            | sed -E 's#^lib/##; s#\.sh$##'

        while IFS=: read -r varname name; do
            [[ -z "$varname" ]] && continue
            grep -qE "source[[:space:]]+\"?\\\$\{?${varname}\}?\"?" "$f" 2>/dev/null && echo "$name"
        done < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*=[^;&|]*lib/[A-Za-z0-9_-]+\.sh' "$f" 2>/dev/null \
                  | sed -E 's#^([A-Za-z_][A-Za-z0-9_]*)=.*lib/([A-Za-z0-9_-]+)\.sh.*#\1:\2#')
    } | sort -u | grep -vx "$self"
}

core_defs=$(_defs_in "$CORE")
findings=""

for f in "${LIB_DIR}"/*.sh; do
    base="$(basename "$f" .sh)"
    [[ "$base" == "core" ]] && continue

    own_defs=$(_defs_in "$f")
    allowed="${core_defs}
${own_defs}"

    for mod in $(_sourced_modules_in "$f"); do
        modfile="${LIB_DIR}/${mod}.sh"
        [[ -f "$modfile" ]] && allowed="${allowed}
$(_defs_in "$modfile")"
    done
    allowed=$(sort -u <<< "$allowed")
    file_vars=$(_vars_in "$f")

    while IFS= read -r fn; do
        [[ -z "$fn" ]] && continue
        grep -qx -- "$fn" <<< "$allowed"   && continue
        grep -qx -- "$fn" <<< "$file_vars" && continue
        loc=$(grep -n -- "$fn" "$f" | head -1)
        findings+="${f}:${loc%%:*}  ${fn}"$'\n'
    done < <(_calls_in "$f" | sort -u)
done

assert_eq "${findings}" "" "modül-farkında: her _fonksiyon çağrısı kendi dosyasında/core.sh'ta/gerçekten source edilen modülde tanımlı"
[[ -n "$findings" ]] && printf '%s' "$findings" >&2

# ───────────────────────────────────────────────────────────────
#  (3) _init_run_step'e geçirilen adım fonksiyonları — declare -F ile
#  GERÇEK bash fonksiyon tablosunda doğrulanır (regex DEĞİL). Kullanım:
#  _init_run_step <current> <total> <step_id> <açıklama> <fonksiyon>
#  — <fonksiyon> STRING argüman olarak alınır, 'if "$func"' ile dolaylı
#  çağrılır (bkz. lib/init.sh:_init_run_step). Yazım hatası burada 'command
#  not found' (127) üretir ama 'if' içinde olduğundan set -e'yi TETİKLEMEZ —
#  adım sessizce sonsuza dek "tamamlanamadı" kalır, marker asla yazılmaz.
init_missing=$(
    export WEB_ROOT="$(mktemp -d)"
    source "$CORE" >/dev/null 2>&1
    require_root() { :; }
    log_action() { :; }
    # shellcheck disable=SC1090
    source "${LIB_DIR}/init.sh" >/dev/null 2>&1
    missing=""
    while IFS= read -r stepfn; do
        [[ -z "$stepfn" ]] && continue
        declare -F "$stepfn" >/dev/null 2>&1 || missing+="${stepfn} "
    done < <(grep -oE '_init_run_step[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
                 "${LIB_DIR}/init.sh" | grep -oE '[A-Za-z_][A-Za-z0-9_]*$')
    rm -rf "$WEB_ROOT"
    printf '%s' "${missing% }"
)
assert_eq "$init_missing" "" "_init_run_step'e geçirilen tüm adım fonksiyonları gerçekten tanımlı (declare -F)"

# ═══════════════════════════════════════════════════════════════
#  KENDİ KENDİNİ DOĞRULAMA — tarayıcı bozulursa bu test SESSİZCE hep PASS
#  vermemeli. Üç probe: (a) v1'den kalan basit tanımsız-çağrı probe'u,
#  (b) ÇAPRAZ-MODÜL kör noktası için YENİ probe (A modülü B'nin fonksiyonunu
#  source ETMEDEN çağırıyor — v1'in hiç yakalayamadığı sınıf), (c) guard'lı
#  meşru source deseninin FALSE POSITIVE ÜRETMEMESİ gerektiği probe'u.
# ═══════════════════════════════════════════════════════════════
probe_dir=$(mktemp -d)

# (a) Basit tanımsız çağrı — aynı dosya içinde.
cat > "${probe_dir}/probe_a.sh" <<'EOF'
foo() {
    _kesinlikle_tanimsiz_fn "$1"
}
EOF

# (b) ÇAPRAZ-MODÜL kör noktası: probe_b1.sh, probe_b2.sh'ta tanımlı bir
# fonksiyonu ÇAĞIRIYOR ama probe_b2.sh'ı source ETMİYOR (ne doğrudan ne
# dolaylı). Bu TAM OLARAK v1'in gördüğü ama v2'nin GÖRMEMESİ GEREKEN
# senaryonun tersidir: v1 (tek havuz) bunu PASS sayardı çünkü fonksiyon
# "bir yerlerde" tanımlıydı; v2 bunu YAKALAMALI.
cat > "${probe_dir}/probe_b1.sh" <<'EOF'
_b1_do_something() {
    _b2_helper_fn "$1"
}
EOF
cat > "${probe_dir}/probe_b2.sh" <<'EOF'
_b2_helper_fn() {
    echo "$1"
}
EOF

# (c) Meşru guard'lı cross-source: probe_c1.sh, probe_c2.sh'ı GERÇEKTEN
# (dolaylı, değişken üzerinden — security.sh:_security_load_domain_lib
# deseniyle birebir) source ediyor. FALSE POSITIVE ÜRETMEMELİ.
cat > "${probe_dir}/probe_c1.sh" <<'EOF'
_c1_load_c2() {
    local lib="${SRVCTL_ROOT}/lib/probe_c2.sh"
    source "$lib"
}
_c1_do_something() {
    _c1_load_c2
    _c2_helper_fn "$1"
}
EOF
cat > "${probe_dir}/probe_c2.sh" <<'EOF'
_c2_helper_fn() {
    echo "$1"
}
EOF

_probe_scan() {
    local dir="$1" core_d="" f base own allowed vars fn loc hit=""
    for f in "${dir}"/*.sh; do
        base="$(basename "$f" .sh)"
        own=$(_defs_in "$f")
        allowed="${core_d}
${own}"
        for mod in $(_sourced_modules_in "$f"); do
            local modfile="${dir}/${mod}.sh"
            [[ -f "$modfile" ]] && allowed="${allowed}
$(_defs_in "$modfile")"
        done
        allowed=$(sort -u <<< "$allowed")
        vars=$(_vars_in "$f")
        while IFS= read -r fn; do
            [[ -z "$fn" ]] && continue
            grep -qx -- "$fn" <<< "$allowed" && continue
            grep -qx -- "$fn" <<< "$vars"    && continue
            hit+="${base}:${fn} "
        done < <(_calls_in "$f" | sort -u)
    done
    printf '%s' "${hit% }"
}

# (a) probe: yalnız probe_a.sh taransın (tek dosyalık izole ortam)
a_dir=$(mktemp -d)
cp "${probe_dir}/probe_a.sh" "$a_dir/"
a_hit=$(_probe_scan "$a_dir")
assert_eq "$a_hit" "probe_a:_kesinlikle_tanimsiz_fn" "dedektör basit tanımsız çağrıyı yakalıyor (v1 probe'u)"
rm -rf "$a_dir"

# (b) probe: probe_b1.sh + probe_b2.sh birlikte (source EDİLMEDEN çapraz çağrı)
b_dir=$(mktemp -d)
cp "${probe_dir}/probe_b1.sh" "${probe_dir}/probe_b2.sh" "$b_dir/"
b_hit=$(_probe_scan "$b_dir")
assert_eq "$b_hit" "probe_b1:_b2_helper_fn" "dedektör ÇAPRAZ-MODÜL kör noktasını yakalıyor (source edilmeyen modülün fonksiyonu çağrılıyor — v1'in KAÇIRDIĞI sınıf)"
rm -rf "$b_dir"

# (c) probe: probe_c1.sh + probe_c2.sh (GERÇEKTEN, dolaylı source edilmiş —
# false positive ÜRETMEMELİ)
c_dir=$(mktemp -d)
cp "${probe_dir}/probe_c1.sh" "${probe_dir}/probe_c2.sh" "$c_dir/"
c_hit=$(_probe_scan "$c_dir")
assert_eq "$c_hit" "" "dedektör guard'lı/dolaylı meşru cross-source'ta FALSE POSITIVE üretmiyor"
rm -rf "$c_dir"

rm -rf "$probe_dir"

test_summary
