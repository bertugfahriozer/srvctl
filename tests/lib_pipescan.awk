# Boru hattı erken-çıkış tarayıcısı (tests/test_pipefail_sigpipe_class.sh için; POSIX awk).
#
# SORUN SINIFI: "üretici | tüketici" boru hattında tüketici ERKEN çıkarsa (grep -q ilk eşleşmede,
# head ilk N satırda, sed '...q', awk 'exit', read ilk satırda) üretici SIGPIPE ile ölür; pipefail
# açıkken boru hattı 141 olur → "var" olan şey "yok" sanılır (güvenlik denetiminde YANLIŞ-NEGATİF).
#
# QL3-M6: eski izin listesi SATIRDA alt dizge arıyordu ve yalnız '| grep -<harfler>q' biçimini
# tarıyordu → 'grep -E -q', '--quiet', satır sonu boru, '|&', '| head', yorumdaki izinli sözcük
# kaçıyordu. Bu tarayıcı bash SÖZCÜK kurallarına yakın bir belirteçleyicidir:
#   - '#' yorumu yalnız sözcük başında, tırnak DIŞINDA başlar (yorumdaki sözcük sayılmaz);
#   - tek/çift tırnak ve ters bölü kaçışı soyulur ('-q' tırnaklı da seçenektir);
#   - '\'+LF birleştirilir; SATIR SONU '|', '|&', '&&', '||' sonraki satırla birleşir;
#   - operatörler: |& | || && & ; ( ) ve tek başına duran { }.
# Her '|' ya da '|&' için ÜRETİCİ (öncesindeki komutun ilk iki sözcüğü) ve TÜKETİCİ (sonrası) çıkarılır;
# tüketici erken-çıkışlıysa bulgu basılır:  dosya:satır:üretici|tüketici
#   erken-çıkışlı tüketici: grep/egrep/fgrep/zgrep/rg (kısa demet içinde q|l|L|m ya da --quiet/--silent/
#   --max-count/--files-with-matches), head (her biçim), sed (q/Q komutu), awk/gawk/mawk/nawk ('exit' içeren
#   program), read (builtin), cmp -s / diff -q (ilk farkta çıkar), tee yok sayılır.
# Kullanım: awk -f tests/lib_pipescan.awk -v FN=<görünen ad> <dosya>

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Tüketici komutunun (kelime dizisi) erken çıkışlı olup olmadığı. Dönüş "" (hayır) ya da kısa ad.
function early(nw,    i, w, base, a, isq) {
    # sarmalayıcıları atla
    i = 1
    while (i <= nw) {
        w = W[i]
        if (w == "!" || w == "command" || w == "builtin" || w == "exec" || w == "time" || w == "nice" || w == "sudo" || w == "stdbuf" || w == "env") { i++; continue }
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (w ~ /^-/ && i > 1) { i++; continue }   # sarmalayıcı seçenekleri (stdbuf -oL, nice -n)
        break
    }
    if (i > nw) return ""
    base = W[i]; sub(/^.*\//, "", base)
    if (base == "head") return "head"
    if (base == "read") return "read"
    if (base == "grep" || base == "egrep" || base == "fgrep" || base == "zgrep" || base == "rg") {
        for (a = i + 1; a <= nw; a++) {
            w = W[a]
            if (w == "--") break
            if (w ~ /^--(quiet|silent|max-count|files-with-matches|files-without-match)(=|$)/) return base " --" substr(w, 3)
            if (w ~ /^-[A-Za-z0-9]*[qlLm][A-Za-z0-9]*$/ && w !~ /^--/) return base " " w
        }
        return ""
    }
    if (base == "sed") {
        for (a = i + 1; a <= nw; a++) {
            w = W[a]
            if (w ~ /^-/ && w !~ /^-[A-Za-z]*e/) continue
            if (w ~ /(^|[;{ \t0-9$\/])[qQ]($|[;} \t])/) return "sed " w
        }
        return ""
    }
    if (base == "awk" || base == "gawk" || base == "mawk" || base == "nawk") {
        for (a = i + 1; a <= nw; a++) if (W[a] ~ /(^|[^A-Za-z0-9_])exit([^A-Za-z0-9_]|$)/) return base " exit"
        return ""
    }
    if (base == "cmp") { for (a = i + 1; a <= nw; a++) if (W[a] ~ /^-[A-Za-z]*s/) return "cmp -s"; return "" }
    if (base == "diff") { for (a = i + 1; a <= nw; a++) if (W[a] ~ /^-[A-Za-z]*q/) return "diff -q"; return "" }
    return ""
}

# Bir mantıksal satırı belirteçle ve boru hatlarını denetle.
function scan(line, lno,    inbr, n, i, c, tok, have, q, nxt, ops, nw, nprod, prod, pw, k, cons, e, lastop, depthc) {
    n = length(line); tok = ""; have = 0; nw = 0; nprod = 0; lastop = ""; inbr = 0
    # W[1..nw] = geçerli komutun sözcükleri; boru görülünce üretici özeti saklanır
    i = 1
    while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\\") {                       # kaçış (tırnak dışı)
            tok = tok substr(line, i + 1, 1); have = 1; i += 2; continue
        }
        if (c == "'") {                        # tek tırnak
            have = 1; i++
            while (i <= n && substr(line, i, 1) != "'") { tok = tok substr(line, i, 1); i++ }
            i++; continue
        }
        if (c == "\"") {                       # çift tırnak ('\"' kaçışı)
            have = 1; i++
            while (i <= n && substr(line, i, 1) != "\"") {
                if (substr(line, i, 1) == "\\" && i < n) { i++ }
                tok = tok substr(line, i, 1); i++
            }
            i++; continue
        }
        if (c == "#" && !have) { break }       # yorum: sözcük başında
        if (c == " " || c == "\t") {
            if (have) {
                nw++; W[nw] = tok
                if (tok == "[[" && nw == 1) inbr = 1
                else if (tok == "]]") inbr = 0
                tok = ""; have = 0
            }
            i++; continue
        }
        if (inbr) { tok = tok c; have = 1; i++; continue }   # [[ ... ]] içinde | & ; ( ) operatör DEĞİL
        # operatörler
        ops = ""
        nxt = substr(line, i, 2)
        if (nxt == "|&") ops = "|&"
        else if (nxt == "||") ops = "||"
        else if (nxt == "&&") ops = "&&"
        else if (nxt == ";;") ops = ";;"
        else if (c == "|") ops = "|"
        else if (c == "&") { if (substr(line, i + 1, 1) == ">" || substr(line, i - 1, 1) == ">" || substr(line, i - 1, 1) == "<") ops = ""; else ops = "&" }
        else if (c == ";") ops = ";"
        else if (c == "(" || c == ")") ops = c
        if (ops != "") {
            # '>&' / '<&' / '2>&1' gibi yönlendirmelerdeki '&' operatör DEĞİLDİR (yukarıda elendi)
            if (have) { nw++; W[nw] = tok; tok = ""; have = 0 }
            if (ops == "|" || ops == "|&") {
                # üretici özeti = bu komutun ilk iki sözcüğü; sonraki komut tüketicidir
                prod = ""; pw = 0
                for (k = 1; k <= nw && pw < 2; k++) {
                    if (W[k] == "if" || W[k] == "!" || W[k] == "while" || W[k] == "until" || W[k] == "then" || W[k] == "do" || W[k] == "else" || W[k] == "elif" || W[k] == "{") continue
                    prod = prod (pw > 0 ? " " : "") W[k]; pw++
                }
                PROD_AT_PIPE = prod
                nw = 0
                pending = ops
                i += length(ops); continue
            }
            # diğer operatörler komutu bitirir
            if (pending != "" && nw > 0) { e = early(nw); if (e != "") report(lno, PROD_AT_PIPE, e, pending); pending = "" }
            nw = 0; pending = ""
            i += length(ops); continue
        }
        if (c == "{" || c == "}") {            # tek başına duran { } blok sözcüğüdür
            if (!have && (substr(line, i + 1, 1) == " " || substr(line, i + 1, 1) == "" || c == "}")) {
                i++; continue
            }
        }
        tok = tok c; have = 1; i++
    }
    if (have) { nw++; W[nw] = tok }
    if (pending != "" && nw > 0) { e = early(nw); if (e != "") report(lno, PROD_AT_PIPE, e, pending); }
    pending = ""
}

function report(lno, prod, cons, op) {
    printf "%s:%d:%s\t%s\t%s\n", FN, lno, prod, op, cons
}

BEGIN { acc = ""; accno = 0; pending = ""; PROD_AT_PIPE = "" }
{
    line = $0
    if (acc == "") accno = NR
    # '\' + LF: birleştir
    if (line ~ /\\$/ && line !~ /\\\\$/) { acc = acc substr(line, 1, length(line) - 1) " "; next }
    acc = acc line
    # satır sonu boru/&&/||: sonraki satırla birleştir (yorum/boşluk sonrası değil)
    t = acc; sub(/[ \t]+$/, "", t)
    if (t ~ /(\|&|\|\||&&|\|)$/ && t !~ /^[ \t]*#/) { acc = acc " "; next }
    scan(acc, accno)
    acc = ""
}
END { if (acc != "") scan(acc, accno) }
