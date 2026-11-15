# tests/test_no_tenant_nginx_copy.sh C bölümünün çözümleyicisi (rev-L10).
# Eski C kilidi TEK SATIRLIK bir regex'ti: '\\' devam satırı, sekme, değişkenle aklama
# (src="${WEB_ROOT}/…"; cp "$src" "$dir/…"), 'cat … >' ve '$(cat …)' ile atomik yazım kaçıyordu.
# Kullanım: LC_ALL=C awk -f tests/lib_nocopy_scan.awk <dosya>…  → bulgu: <dosya>:<satır>: <bölüt>
# Yalnız POSIX awk (BWK/mawk/gawk); bash 3.2 dışında bağımlılık yok.
# Mantıksal satır = '\' devamları ve satır sonu | |& && || birleşik, yorumlar (tırnak dışı) atılmış. İşlev başına (sütun 0 'ad() {' … '}')
# değişken lekesi: SRC = değeri WEB_ROOT ya da SRC değişkeni içeren atama; DST = değeri custom.d hedefi içeren atama.
# Bulgu: yazıcı komut (cp mv install rsync ln cat tee dd tar cpio _domconf_atomic_write; 'tee H < K' tee ile) ya da '$(cat'
# içeren bölüt, AYNI bölütte hem kaynak (WEB_ROOT|SRC) hem hedef (custom.d|DST) taşıyorsa.
function reset_fn(   k) { for (k in SRC) delete SRC[k]; for (k in DST) delete DST[k] }
function has_var(s, set,   k) { for (k in set) { if (index(s, "$" k) || index(s, "${" k "}") || index(s, "${" k ":")) return 1 } return 0 }
function is_src(s) { return (index(s, "WEB_ROOT") > 0) || has_var(s, SRC) }
function is_dst(s) { return (s ~ /custom\.d|SRVCTL_NGINX_CUSTOM_DIR|CUR_DIR|\$\{?c?dir\}?/) || has_var(s, DST) }
function cmdword(seg,   n, w, i, x) {
    n = split(seg, w, /[ \t]+/)
    for (i = 1; i <= n; i++) {
        x = w[i]; sub(/^[({!]+/, "", x); sub(/^\$\(/, "", x)
        if (x == "" || x ~ /^(if|then|else|elif|do|while|until|command|sudo|exec|time|local|export|readonly|declare)$/) continue
        if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        return x
    }
    return ""
}
function scan_logical(L, ln,   nseg, seg, i, s, cw, nm, val, n, a, j) {
    # atamalar (local/export/declare dahil): ad=değer — lekeyi yay
    n = split(L, a, /[ \t;]+/)
    for (j = 1; j <= n; j++) {
        if (a[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            nm = a[j]; sub(/=.*/, "", nm); val = substr(L, index(L, a[j]) + length(nm) + 1)
            if (is_src(val)) SRC[nm] = 1
            if (is_dst(val)) DST[nm] = 1
        }
    }
    # boru hattı TEK birimdir (veri '|' üstünden akar: 'cat KAYNAK | tee HEDEF'); yalnız ; && || böler
    nseg = split(L, seg, /;|&&|\|\|/)
    for (i = 1; i <= nseg; i++) {
        s = seg[i]; cw = cmdword(s)
        if (cw ~ /^(cp|mv|install|rsync|ln|cat|tee|dd|tar|cpio|_domconf_atomic_write)$/ || index(s, "$(cat ")) {
            if (is_src(s) && is_dst(s)) printf "%s:%d: %s\n", FILENAME, ln, s
        }
    }
}
# Tırnak-duyarlı satır sonu yorumu ayıklama: tırnak DIŞINDA, sözcük başındaki '#' yorumdur
# (tırnak içindeki " #" komut gizlemeye yol açmasın diye kaba kesme YOK).
function strip_comment(l,   i, c, q, out, prev) {
    q = ""; out = ""; prev = " "
    for (i = 1; i <= length(l); i++) {
        c = substr(l, i, 1)
        if (q == "") {
            if (c == "\\") { out = out c substr(l, i + 1, 1); i++; prev = "x"; continue }
            if (c == "'" || c == "\"") q = c
            else if (c == "#" && (prev == " " || prev == "\t" || prev == ";")) return out
        } else if (q == "\"" && c == "\\") { out = out c substr(l, i + 1, 1); i++; prev = "x"; continue }
        else if (c == q) q = ""
        out = out c; prev = c
    }
    return out
}
FNR == 1 { reset_fn(); buf = ""; start = 0 }
/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ { reset_fn() }
{
    line = $0
    if (line ~ /^[ \t]*#/) next
    line = strip_comment(line)
    if (buf == "") start = FNR
    if (line ~ /\\$/) { buf = buf substr(line, 1, length(line) - 1) " "; next }
    # satır sonu '|', '|&', '&&', '||' sonraki satırla birleşir (lib_pipescan.awk ile aynı kural)
    if (line ~ /(\||&&)[ \t]*$/) { buf = buf line " "; next }
    buf = buf line
    scan_logical(buf, start)
    buf = ""
}
/^}/ { reset_fn() }
