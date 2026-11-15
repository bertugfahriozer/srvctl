#!/bin/bash
# ORTAK nginx lexer'ı (_domconf_nginx_parse; ngx_conf_read_token birebir) — birim vektörleri.
#
# F3: eski yasak-listesi/include/proxy_pass tarayıcıları KALDIRILDI (bkz. lib/nginx_allow.sh ve
# tests/test_nginx_allowlist.sh); lexer AYNEN kalır ve izin listesi ile 'fm-auth off' referans
# taramasını besler. Bu dosya yalnız lexer sözleşmesini kilitler (tırnak yalnız sözcük başında,
# kaçışlar, '#' yalnız sözcük başında, ${var}, '}' kuralları, fail-closed yapı hataları, 32 KiB
# varsayılan boyut tavanı). Gerçek nginx ile diferansiyel karşılaştırma: test_domconf_nginx_real.sh.
set -uo pipefail
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; _fm_env_cleanup' EXIT   # rev-L9: fm_env temizliği zincirde
F="${TMP}/t.conf"
_w() { printf '%s' "$1" > "$F"; }
# lexer sonucu: her sözcük [..] içinde, ifade ';' (stmt) ya da '{' (open) ile biter
_LEX=""
_lex_cb() { local kind="$1"; shift 2; local out="" t; for t in "$@"; do out+="[${t}]"; done
            [[ "$kind" == "open" ]] && out+="{" || out+=";"; _LEX+="${out}"; return 0; }
_lex() { _w "$1"; _LEX=""; _domconf_nginx_parse "$F" _lex_cb; _LEX_RC=$?; printf '%s' "$_LEX"; }
_lex_rc() { _w "$1"; _domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1; echo $?; }

echo "── A: lexer = nginx sözcük kuralları ──"
assert_eq "$(_lex 'add_header X-A a"; foo b;')" '[add_header][X-A][a"];[foo][b];' "token-ortası \" tırnak AÇMAZ (QL2-M1 vektörü)"
assert_eq "$(_lex 'set $v \" ; foo;')" '[set][$v]["];[foo];' "kaçışlı \" düz karakter, ifadeyi bölmez (rev vektörü)"
assert_eq "$(_lex '"fastcgi_pass" unix:/x;')" '[fastcgi_pass][unix:/x];' "tırnaklı direktif adı soyulur"
assert_eq "$(_lex "'a b' \"c d\";")" '[a b][c d];' "tek/çift tırnaklı sözcükler"
assert_eq "$(_lex 'foo "a;b{c}" d;')" '[foo][a;b{c}][d];' "tırnak içindeki ; { } yapı karakteri DEĞİL"
assert_eq "$(_lex 'a#b c;')" '[a#b][c];' "'#' sözcük ortasında yorum DEĞİL"
assert_eq "$(_lex 'foo; # yorum
bar;')" '[foo];[bar];' "'#' sözcük başında yorum, LF ile biter"
assert_eq "$(_lex 'set $x ${y}; foo;')" '[set][$x][${y}];[foo];' "\${var} içindeki { blok açmaz"
assert_eq "$(_lex 'location /x{ foo; }')" '[location][/x]{[foo];' "'/x{' → sözcük + blok"
assert_eq "$(_lex 'foo a\;b;')" '[foo][a\;b];' "kaçışlı ; sözcüğün parçası"
assert_eq "$(_lex 'foo a\\b;')" '[foo][a\b];' "\\\\ → tek ters bölü"
assert_eq "$(_lex 'foo a}b;')" '[foo][a}b];' "'}' sözcük ortasında düz karakter"
assert_eq "$(_lex 'if ($a = "x") { foo; }')" '[if][($a][=][x][)]{[foo];' "if (…) biçimi: kapanan tırnaktan sonra ')' yeni sözcük"
assert_eq "$(_lex 'foo "";')" '[foo][];' "boş tırnaklı sözcük korunur"
assert_eq "$(_lex 'foo
  bar
  baz;')" '[foo][bar][baz];' "çok satırlı ifade"
assert_eq "$(_lex $'foo a\tb\r;')" '[foo][a][b];' "sekme/CR boşluk"
assert_eq "$(_lex 'foo a;;')" '[foo][a];' "(öncül) tek ';' ifadesi"
assert_eq "$(_lex_rc 'foo a;;')" "2" "boş ifade ';;' nginx gibi HATA"
assert_eq "$(_lex_rc 'foo "x"y;')" "2" "kapanan tırnaktan sonra bitişik karakter HATA"
assert_eq "$(_lex_rc 'foo "abc;')" "2" "dosya sonunda açık tırnak HATA"
assert_eq "$(_lex_rc "foo 'abc;")" "2" "dosya sonunda açık tek tırnak HATA"
assert_eq "$(_lex_rc '"abc;')" "2" "ifadenin İLK sözcüğü açık çift tırnakla biter → HATA (ntok=0 dalı)"
assert_eq "$(_lex_rc "'abc")" "2" "ifadenin ilk sözcüğü açık tek tırnak → HATA"
assert_eq "$(_lex_rc '\')" "2" "tek başına yarım kaçış → HATA"
assert_eq "$(_lex_rc 'foo a')" "2" "';' ile bitmeyen son ifade HATA"
assert_eq "$(_lex_rc 'foo a\')" "2" "dosya sonunda yarım kaçış HATA"
assert_eq "$(_lex_rc 'location /x { foo;')" "2" "dosya sonunda açık blok HATA"
assert_eq "$(_lex_rc '}')" "2" "dosya düzeyinde '}' (üst bloğu kapatma) HATA"
assert_eq "$(_lex_rc 'location /x { foo; } }')" "2" "fazla '}' HATA"
assert_eq "$(_lex_rc 'foo a }')" "2" "ifade ortasında '}' HATA"
assert_eq "$(_lex_rc '{ foo; }')" "2" "ifadesiz '{' HATA"
assert_eq "$(_lex_rc 'location /x { foo; }')" "0" "dengeli blok temiz"
assert_eq "$(_lex_rc '')" "0" "boş dosya temiz"
assert_eq "$(_lex_rc '# yalniz yorum')" "0" "yalnız yorum (LF'siz) temiz"
printf 'foo\000bar;\n' > "$F"
_domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1; assert_eq "$?" "3" "NUL bayt → reddedilir (bash değişkeni NUL taşıyamaz)"
_domconf_nginx_parse "${TMP}/yok.conf" _lex_cb >/dev/null 2>&1; assert_eq "$?" "3" "okunamayan/yok dosya → 3"
mkdir -p "${TMP}/dir.conf"; _domconf_nginx_parse "${TMP}/dir.conf" _lex_cb >/dev/null 2>&1; assert_eq "$?" "3" "dizin → 3"
_w "$(printf 'foo bar baz %.0s' 1 2 3 4 5 6 7 8);"
_DOMCONF_NGX_MAX_BYTES=50; _domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1; assert_eq "$?" "3" "boyut tavanını aşan dosya → 3 (fail-closed, DoS/gizleme yolu yok)"
_DOMCONF_NGX_MAX_BYTES=100000; _domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1; assert_eq "$?" "0" "tavan altında aynı dosya çözümlenir (pozitif kontrol)"
unset _DOMCONF_NGX_MAX_BYTES
# yığın bağlamı: geri çağrı tepe bloğu görür
_STK=""; _stk_cb() { local d=${#_NGX_STACK[@]} top=""; (( d > 0 )) && top="${_NGX_STACK[d-1]}"; _STK+="${3}@${top:-ROOT}/${d} "; return 0; }
_w 'location /a { if ($x) { foo; } bar; } baz;'
_domconf_nginx_parse "$F" _stk_cb; assert_eq "$_STK" "location@ROOT/0 if@location/1 foo@if/2 bar@location/1 baz@ROOT/0 " "'}' yığını boşaltır (tepe geri döner)"


echo "── A2: varsayılan boyut tavanı 32 KiB ──"
unset _DOMCONF_NGX_MAX_BYTES
head -c 32000 /dev/zero | tr '\0' 'a' > "${TMP}/big.txt"
{ printf 'foo '; cat "${TMP}/big.txt"; printf ';\n'; } > "$F"
_domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1; assert_eq "$?" "0" "32000 baytlık dosya çözümlenir"
{ printf 'foo '; cat "${TMP}/big.txt"; cat "${TMP}/big.txt"; printf ';\n'; } > "$F"
_domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1; assert_eq "$?" "3" "64000 baytlık dosya VARSAYILAN tavanda reddedilir (rc 3)"
assert_contains "$_NGX_ERR" "32768" "hata metni tavanı söyler"

echo "── A2b: geçersiz UTF-8 bayt (macOS tr yerel ayar kusuru; A1→A2 notu 4) ──"
printf 'foo \377\376 bar;\n' > "$F"
_LEX=""; ( unset LC_ALL; export LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8; _domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1 ); assert_eq "$?" "0" "geçersiz UTF-8 baytlı dosya UTF-8 yerel ayarında çözümlenir (rc 0, tr 'Illegal byte sequence' DEĞİL)"
printf 'foo \000 bar;\n' > "$F"
( unset LC_ALL; export LC_CTYPE=en_US.UTF-8; _domconf_nginx_parse "$F" _lex_cb >/dev/null 2>&1 ); assert_eq "$?" "3" "NUL bayt yine rc 3 (UTF-8 yerel ayarında da)"

echo "── A3: kaldırılan işlevler gerçekten yok (yasak-listesi mimarisi geri gelmesin) ──"
for fn in _domconf_scan_nginx _domconf_scan_includes _domconf_scan_proxy_pass _domconf_nginx_deny_class _domconf_nginx_deny_reason \
          _domconf_scan_cb_deny _domconf_scan_cb_inc _domconf_scan_track_vars _domconf_proxy_guard_regex_ok _domconf_scan_proxy_vars_check \
          _domconf_scan_nginx_dump _domain_clone_nginx_candidate; do
    assert_eq "$(declare -F "$fn" >/dev/null && echo var || echo yok)" "yok" "kaldırıldı: ${fn}"
done
for v in _DOMCONF_NGINX_DENY _DOMCONF_PP_CORPUS _DOMCONF_SCAN_OWN _DOMCONF_SCAN_OWN_SNAME _DCM_GV; do
    assert_eq "$(declare -p "$v" >/dev/null 2>&1 && echo var || echo yok)" "yok" "kaldırıldı: ${v}"
done

test_summary
