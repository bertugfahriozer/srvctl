# lib_harness_scan.awk — test/lab düzeneği yapısal tarayıcı (F9b/b). Kullanım:
#   awk -v FILE=<ad> -f tests/lib_harness_scan.awk <dosya>      (her dosya için ayrı çağrılır)
# Çıktı satırı: KIND|<ad>|<satır no>|<ham satır (kırpılmış)>
#   KILL    komut konumunda ham `kill` (`kill -0` yoklaması ve `kill -l` hariç)
#   PKILL   pkill / killall
#   BG      tırnak/yorum dışı tek `&` (arka plan); `&&`, `>&`, `&>`, `<&`, `|&` sayılmaz
#   DETACH  nohup / disown / setsid komut konumunda
#   TMPFALL ${TMPDIR:-/tmp} biçimi (TMPDIR ayarsızsa /tmp'ye düşer)
#   MKTEMP  açık "${TMPDIR:?}/…" şablonu OLMAYAN mktemp çağrısı
#   TMPLIT  tırnak içi dahil /tmp, /var/tmp, /private/tmp sabit yolu (veri/ret girdisi olabilir -> izin tablosu gerekçeli)
# Sınırlar: heredoc gövdeleri atlanır (gömülü python/sahte betik gövdeleri); çok satırlı tırnak durumu satırlar arası taşınır.
BEGIN { sp = 0; ctx[0] = "C"; hd = "" }
function strip_arith(t,   out, i, j, d, c) {   # $(( ... )) ve (( ... )) içindeki & (bit işlemi) arka plan sayılmasın
    out = ""; i = 1
    while (i <= length(t)) {
        if (substr(t, i, 3) == "$((" || (substr(t, i, 2) == "((" && (i == 1 || substr(t, i - 1, 1) !~ /[$]/))) {
            j = i + (substr(t, i, 1) == "$" ? 1 : 0); d = 0
            while (j <= length(t)) {
                c = substr(t, j, 1)
                if (c == "(") d++
                else if (c == ")") { d--; if (d == 0) break }
                j++
            }
            out = out " "; i = j + 1; continue
        }
        out = out substr(t, i, 1); i++
    }
    return out
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
{
    raw = $0
    if (hd != "") {
        t = raw; sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        next
    }
    if (DEBUG && sp > 0) print "STK|" sp "|" ctx[sp] "|" NR "|" substr(raw, 1, 70)
    n = length(raw); s1 = ""; s2 = ""; s3 = raw; prev = " "
    for (i = 1; i <= n; i++) {
        c = substr(raw, i, 1); nx = substr(raw, i + 1, 1); top = ctx[sp]
        if (top == "S") {                      # tek tırnak: ham
            if (c == "'") sp--
            s1 = s1 (c == "'" ? "'" : " "); s2 = s2 (c == "'" ? "'" : " "); prev = c; continue
        }
        if (top == "A") {                      # $'...' : ters bölü sonraki karakteri kaçırır
            if (c == "\\") { s1 = s1 "  "; s2 = s2 "  "; i++; continue }
            if (c == "'") sp--
            s1 = s1 (c == "'" ? "'" : " "); s2 = s2 (c == "'" ? "'" : " "); prev = c; continue
        }
        if (top == "D") {                      # çift tırnak: $( ) içeriği koddur
            if (c == "\\") { s1 = s1 c nx; s2 = s2 "  "; i++; continue }
            if (c == "\"") { sp--; s1 = s1 "\""; s2 = s2 "\""; prev = c; continue }
            if (c == "$" && nx == "(") { sp++; ctx[sp] = "C"; cd[sp] = 1; s1 = s1 "$("; s2 = s2 "$("; i++; prev = "("; continue }
            s1 = s1 c; s2 = s2 " "; prev = c; continue
        }
        # kod
        if (c == "\\") { s1 = s1 "  "; s2 = s2 "  "; i++; prev = " "; continue }
        if (c == "#" && (prev == " " || prev == "\t" || prev == ";" || prev == "(" || prev == "")) { s3 = substr(raw, 1, i - 1); break }
        if (c == "$" && nx == "'") { sp++; ctx[sp] = "A"; s1 = s1 "$'"; s2 = s2 "$'"; i++; prev = "'"; continue }
        if (c == "'") { sp++; ctx[sp] = "S"; s1 = s1 "'"; s2 = s2 "'"; prev = c; continue }
        if (c == "\"") { sp++; ctx[sp] = "D"; s1 = s1 "\""; s2 = s2 "\""; prev = c; continue }
        if (c == "$" && nx == "(") { sp++; ctx[sp] = "C"; cd[sp] = 1; s1 = s1 "$("; s2 = s2 "$("; i++; prev = "("; continue }
        if (sp > 0) {
            if (c == "(") cd[sp]++
            else if (c == ")") { cd[sp]--; if (cd[sp] == 0) { sp--; s1 = s1 ")"; s2 = s2 ")"; prev = ")"; continue } }
        }
        s1 = s1 c; s2 = s2 c; prev = c
    }
    # heredoc başlangıcı: `<<` tırnak/yorum DIŞINDA (s2 üzerinde konum, ham satırdan sınırlayıcı); here-string <<< hariç
    p2 = index(s2, "<<")
    if (p2 > 0 && substr(s2, p2, 3) != "<<<" && substr(s2, p2 - 1, 3) != "<<<") {
        d = substr(raw, p2 + 2); sub(/^-/, "", d); sub(/^[ \t]*\\?['"]?/, "", d)
        if (match(d, /^[A-Za-z_][A-Za-z0-9_]*/)) hd = substr(d, RSTART, RLENGTH)
    }
    line = trim(raw)
    # KILL
    t = s1; killed = 0
    while (match(t, /(^|[;&|({`!]|\$\(|[ \t](then|do|else|elif))[ \t]*(command[ \t]+|builtin[ \t]+)?kill([ \t]|$)/)) {
        rest = substr(t, RSTART + RLENGTH)
        t = rest
        if (rest ~ /^[ \t]*-(0|l|L)([ \t]|$)/) continue
        print "KILL|" FILE "|" NR "|" line; killed = 1
        break
    }
    if (!killed && match(raw, /trap[ \t]+['"]([^'"]*[ ;&|(])?kill[ \t]+/)) {   # trap '...kill ...' dizgesi içindeki kill
        rest = substr(raw, RSTART + RLENGTH)
        if (rest !~ /^-(0|l|L)([ \t]|$)/) { print "KILL|" FILE "|" NR "|" line; killed = 1 }
    }
    if (!killed && raw ~ /(xargs|-exec|eval)[ \t]+(-[^ \t]+[ \t]+)*["']?kill[ \t]/) { print "KILL|" FILE "|" NR "|" line; killed = 1 }
    if (s1 ~ /(^|[;&|({`!]|\$\(|[ \t](then|do|else))[ \t]*(pkill|killall)([ \t]|$)/) print "PKILL|" FILE "|" NR "|" line
    if (s1 ~ /(^|[;&|({`!]|\$\(|[ \t](then|do|else))[ \t]*(nohup|disown|setsid)([ \t]|$)/) print "DETACH|" FILE "|" NR "|" line
    # BG
    b = strip_arith(s2)
    gsub(/&&/, "  ", b); gsub(/[0-9]*>&[0-9-]*/, "  ", b); gsub(/&>>?/, "  ", b); gsub(/<&[0-9-]*/, "  ", b); gsub(/\|&/, "  ", b)
    if (b ~ /&/) print "BG|" FILE "|" NR "|" line
    # tmp
    if (index(s1, "${TMPDIR:-") > 0 && s1 ~ /\$\{TMPDIR:-[^}]*\}/) print "TMPFALL|" FILE "|" NR "|" line
    if (s1 ~ /(^|[^A-Za-z0-9_.-])mktemp([ \t]|$)/ && s1 !~ /\$\{TMPDIR:\?\}\/[^ ]*XXXXXX/ ) print "MKTEMP|" FILE "|" NR "|" line
    if (s3 ~ /(^|[^A-Za-z0-9_])(\/private)?(\/var)?\/tmp(\/|[^A-Za-z0-9_.-]|$)/) print "TMPLIT|" FILE "|" NR "|" line
}
