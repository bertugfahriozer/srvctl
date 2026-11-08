#!/bin/bash
# rev-L9: tests/fm_env.sh'nin iki geçici dizini (WEB_ROOT, FM_STUBS) çıkışta silinir.
# Kilitlenenler:
#   A  kaynaklayan kabuk çıkınca iki dizin YOK (yalın çıkış, exit 3, salt-okur alt dizin)
#   B  test kendi EXIT tuzağını kurup _fm_env_cleanup'ı zincirlerse ikisi de çalışır
#   C  güvenlik: yalnız fm_env'in OLUŞTURDUĞU dizinler silinir (WEB_ROOT sonradan değişse bile)
#   D  yapısal: fm_env.sh'yi kaynaklayıp kendi EXIT tuzağını kuran HER test _fm_env_cleanup'ı
#      tuzağa ekler ve tuzağı kaynaklamadan SONRA kurar (önce kurulan tuzağı fm_env ezer)
#   E  davranış: seçili gerçek testler mktemp taklidiyle koşulur; ürettikleri HİÇBİR geçici
#      yol çıkışta kalmaz (macOS mktemp -d şablonsuzken TMPDIR'ı yok saydığından sayım
#      TMPDIR ile değil, mktemp'in döndürdüğü yolların günlüğüyle yapılır)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

_child() { # $1 = fm_env kaynaklandıktan sonra koşacak bash kodu → stdout: WEB_ROOT|FM_STUBS
    bash -c 'source "$1/tests/fm_env.sh" >/dev/null 2>&1; printf "%s|%s\n" "$WEB_ROOT" "$FM_STUBS"; eval "$2"' _ "$REPO_ROOT" "$1" 2>/dev/null
}
_gone() { # $1 = "a|b" → "yokyok" beklenir
    local a="${1%%|*}" b="${1#*|}"
    { [[ -n "$a" && ! -e "$a" ]] && echo yok || echo "VAR(${a})"; } | tr -d '\n'
    { [[ -n "$b" && ! -e "$b" ]] && echo yok || echo "VAR(${b})"; } | tr -d '\n'
}

echo "── A: çıkışta iki dizin silinir ──"
p=$(_child 'exit 0')
assert_contains "$p" "|" "(ön koşul) alt kabuk iki yolu bildirdi"
assert_eq "$(_gone "$p")" "yokyok" "yalın çıkış: WEB_ROOT ve FM_STUBS silindi"
p=$(_child 'exit 3')
assert_eq "$(_gone "$p")" "yokyok" "exit 3: ikisi de silindi"
p=$(_child 'mkdir -p "$WEB_ROOT/ro/x"; echo a > "$WEB_ROOT/ro/x/f"; chmod 000 "$WEB_ROOT/ro/x" "$WEB_ROOT/ro"; exit 0')
assert_eq "$(_gone "$p")" "yokyok" "salt-okur (000) alt dizin olsa da silindi"
p=$(_child 'false')
assert_eq "$(_gone "$p")" "yokyok" "son komut başarısız: yine silindi"

echo "── B: testin kendi EXIT tuzağıyla zincir ──"
p=$(_child 'X="$(mktemp -d "${FM_STUBS}/own.XXXXXX")"; echo "$X" > "'"$T"'/own.path"; trap '"'"'rm -rf "$X"; _fm_env_cleanup'"'"' EXIT; exit 0')
assert_eq "$(_gone "$p")" "yokyok" "zincirli tuzak: fm_env dizinleri silindi"
assert_eq "$([[ -e "$(cat "${T}/own.path")" ]] && echo var || echo yok)" "yok" "zincirli tuzak: testin kendi dizini de silindi"
# zincirlemeyen test (tuzağı ezer) sızdırır — D'nin yapısal kilidinin NEDENİ (pozitif kontrol)
p=$(_child 'trap ":" EXIT; exit 0')
_a="${p%%|*}"; _b="${p#*|}"
assert_eq "$(_gone "$p")" "VAR(${_a})VAR(${_b})" "(pozitif kontrol) tuzağı ezen test iki dizini SIZDIRIR"
rm -rf -- "${_a:?}" "${_b:?}"

echo "── C: yalnız fm_env'in oluşturduğu dizinler silinir ──"
mkdir -p "${T}/tmp.keep"; echo k > "${T}/tmp.keep/k"
p=$(_child 'WEB_ROOT="'"$T"'/tmp.keep"; FM_STUBS="'"$T"'/tmp.keep"; exit 0')
assert_eq "$(_gone "$p")" "yokyok" "WEB_ROOT/FM_STUBS sonradan değişse de ÖZGÜN iki dizin silindi"
assert_eq "$(cat "${T}/tmp.keep/k" 2>/dev/null)" "k" "sonradan atanan WEB_ROOT/FM_STUBS (tmp.* adlı olsa da) SİLİNMEDİ"
_lf=$(grep -n '_FM_ENV_DIRS=' "${REPO_ROOT}/tests/fm_env.sh" | head -1 | cut -d: -f1)
_lw=$(grep -n '^WEB_ROOT="$(mktemp -d)"' "${REPO_ROOT}/tests/fm_env.sh" | head -1 | cut -d: -f1)
_ls=$(grep -n '^FM_STUBS="$(mktemp -d)"' "${REPO_ROOT}/tests/fm_env.sh" | head -1 | cut -d: -f1)
assert_eq "$(( _lf > _lw && _lf > _ls ? 1 : 0 ))" "1" "silinecek yollar iki mktemp'ten SONRA saklanır (satır ${_lw}/${_ls} < ${_lf})"

echo "── D: yapısal — fm_env kaynaklayan testler tuzağı zincirler ──"
_bad=""; _nsrc=0; _ntrap=0
for f in "${REPO_ROOT}"/tests/test_*.sh; do
    ls_=$(grep -n '^[[:space:]]*source[[:space:]].*tests/fm_env\.sh' "$f" | head -1 | cut -d: -f1)
    [[ -n "$ls_" ]] || continue
    _nsrc=$((_nsrc + 1))
    while IFS=: read -r ln rest; do
        [[ -z "$ln" ]] && continue
        case "$rest" in *"trap -p"*|*"trap - "*) continue ;; esac
        _ntrap=$((_ntrap + 1))
        if [[ "$rest" != *_fm_env_cleanup* ]]; then _bad+="${f##*/}:${ln} (zincir yok) "; fi
        if (( ln < ls_ )); then _bad+="${f##*/}:${ln} (fm_env'den ÖNCE) "; fi
    done < <(grep -n '^[^#]*trap[[:space:]].*EXIT' "$f")
done
assert_eq "$(( _nsrc >= 13 ? 1 : 0 ))" "1" "fm_env kaynaklayan test sayısı (>=13): ${_nsrc}"
assert_eq "$(( _ntrap >= 3 ? 1 : 0 ))" "1" "kendi EXIT tuzağı olan test sayısı (>=3): ${_ntrap}"
assert_eq "$_bad" "" "her EXIT tuzağı _fm_env_cleanup içerir ve fm_env'den sonra kurulur"

echo "── E: gerçek testler (mktemp taklidi) hiçbir geçici yol bırakmaz ──"
SHIM="${T}/shim"; mkdir -p "$SHIM"; _real_mktemp="$(command -v mktemp)"
cat > "${SHIM}/mktemp" <<SHIMEOF
#!/bin/bash
out=\$("${_real_mktemp}" "\$@") || exit \$?
printf '%s\n' "\$out" >> "\${MKLOG:?}"
printf '%s\n' "\$out"
SHIMEOF
chmod +x "${SHIM}/mktemp"
for t in test_domconf_lexer test_domain_staging test_domconf_fm_templates test_domconf_nginx_audit; do
    MKLOG="${T}/${t}.mk"; : > "$MKLOG"
    ( cd "$REPO_ROOT" && PATH="${SHIM}:${PATH}" MKLOG="$MKLOG" bash "tests/${t}.sh" >/dev/null 2>&1 </dev/null ); trc=$?
    n=$(grep -c . "$MKLOG"); left=""
    while IFS= read -r q; do [[ -n "$q" && ( -e "$q" || -L "$q" ) ]] && left+="$q "; done < "$MKLOG"
    assert_eq "$trc" "0" "${t}: test yeşil (mktemp taklidi altında)"
    assert_eq "$(( n >= 2 ? 1 : 0 ))" "1" "${t}: (pozitif kontrol) mktemp en az 2 kez çağrıldı (${n})"
    assert_eq "$left" "" "${t}: mktemp'in döndürdüğü ${n} yolun HİÇBİRİ kalmadı"
    for q in $left; do rm -rf -- "${q:?}"; done
done

test_summary
