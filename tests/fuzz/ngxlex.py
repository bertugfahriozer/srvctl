#!/usr/bin/env python3
"""nginx 1.28 ngx_conf_read_token BAĞIMSIZ referans sözcük çözümleyicisi.

lib/domconf.sh:_domconf_nginx_parse (bash) ile AYNI koddan türemez: C
kaynağındaki durum makinesinden (start/ham dilim + sonda kaçış çözme) yazılmıştır.
Çıktı: olaylar [(tür 'stmt'|'open', başlangıç_satırı, [sözcükler])], hata (str|None)
"""
import sys

WS = b" \t\r\n"


def tokenize(data: bytes):
    events = []
    err = None
    depth = 0
    line = 1
    args = []
    start = None
    start_line = 1
    stmt_line = 1
    found = need_space = False
    last_space = True
    sharp = variable = quoted = s_quoted = d_quoted = False
    n = len(data)
    i = 0

    def unescape(raw: bytes) -> bytes:
        out = bytearray()
        j = 0
        while j < len(raw):
            c = raw[j]
            if c == 0x5C and j + 1 < len(raw):  # backslash
                nx = raw[j + 1]
                if nx in (0x22, 0x27, 0x5C):
                    j += 1
                elif nx == 0x74:
                    out.append(0x09); j += 2; continue
                elif nx == 0x72:
                    out.append(0x0D); j += 2; continue
                elif nx == 0x6E:
                    out.append(0x0A); j += 2; continue
            out.append(raw[j])
            j += 1
        return bytes(out)

    while i < n:
        ch = data[i]
        i += 1
        if ch == 0x0A:
            line += 1
            if sharp:
                sharp = False
        if sharp:
            continue
        if quoted:
            quoted = False
            continue
        if need_space:
            if ch in WS:
                last_space = True
                need_space = False
                continue
            if ch == 0x3B:  # ;
                events.append(("stmt", stmt_line, args)); args = []
                need_space = False; last_space = True
                continue
            if ch == 0x7B:  # {
                events.append(("open", stmt_line, args)); args = []
                depth += 1
                need_space = False; last_space = True
                continue
            if ch == 0x29:  # )
                last_space = True
                need_space = False
            else:
                return events, "kapanan tırnaktan sonra beklenmeyen karakter (satır %d)" % line
        if last_space:
            start = i - 1
            start_line = line
            if ch in WS:
                continue
            if ch in (0x3B, 0x7B):
                if not args:
                    return events, "ifadesiz '%s' (satır %d)" % (chr(ch), line)
                if ch == 0x7B:
                    events.append(("open", stmt_line, args)); depth += 1
                else:
                    events.append(("stmt", stmt_line, args))
                args = []
                continue
            if ch == 0x7D:
                if args:
                    return events, "ifade içinde '}' (satır %d)" % line
                if depth == 0:
                    return events, "dosya düzeyinde '}' (satır %d)" % line
                depth -= 1
                continue
            if ch == 0x23:
                sharp = True
                continue
            if not args:
                stmt_line = line
            if ch == 0x5C:
                quoted = True; last_space = False
                continue
            if ch == 0x22:
                start += 1; d_quoted = True; last_space = False
                continue
            if ch == 0x27:
                start += 1; s_quoted = True; last_space = False
                continue
            if ch == 0x24:
                variable = True; last_space = False
                continue
            last_space = False
        else:
            if ch == 0x7B and variable:
                continue
            variable = False
            if ch == 0x5C:
                quoted = True
                continue
            if ch == 0x24:
                variable = True
                continue
            if d_quoted:
                if ch == 0x22:
                    d_quoted = False; need_space = True; found = True
            elif s_quoted:
                if ch == 0x27:
                    s_quoted = False; need_space = True; found = True
            elif ch in b" \t\r\n;{":
                last_space = True; found = True
            if found:
                raw = data[start:i - 1]
                args.append(unescape(raw).decode("latin-1"))
                found = False
                if ch == 0x3B:
                    events.append(("stmt", stmt_line, args)); args = []
                elif ch == 0x7B:
                    events.append(("open", stmt_line, args)); args = []
                    depth += 1
    if args or not last_space:
        return events, "dosya sonunda ';' ile bitmeyen ifade / açık tırnak"
    if depth:
        return events, "dosya sonunda kapanmamış blok"
    return events, None


if __name__ == "__main__":
    ev, er = tokenize(open(sys.argv[1], "rb").read())
    for k, l, a in ev:
        print(k, l, a)
    print("ERR", er)
