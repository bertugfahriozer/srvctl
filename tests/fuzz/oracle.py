#!/usr/bin/env python3
"""GÜVENLİK KAHİNİ — tarayıcıdan (lib/nginx_allow.sh) BAĞIMSIZ, basit 'güvenli küme'.

Girdi: nginx'in `-T` dökümünden alınan (ya da nginx reddetmişse ham) kullanıcı dosyası.
Sözcük çözümleme tests/fuzz/ngxlex.py (C durum makinesinden); ağaç buradan çıkar.
Kahin bir İZİN LİSTESİ değil, ETKİ SINIFLARI tanımıdır:
  net   : ağ hedefi / arka uç / dış etki      (*_pass, proxy_*, fastcgi_*, mirror, resolver, js/lua/perl/xslt…)
  file  : dosya sistemi / yol / dahil etme    (root, alias, include, *_path, *_file, log yolları, ssl_*…)
  topo  : kimlik / topoloji                   (server, listen, server_name, upstream, map, geo, http…)
  waf   : koruma devre dışı / kimlik doğrulama (modsecurity*, disable_symlinks, auth_basic*, satisfy…)
  token : srvctl FM ad uzayı / token yakalama (upstream_http, sent_http, fm_auth, $fm…, /_fm/ …)
  var   : kapalı olmayan değişken / yazılan yerleşik değişken
  crlf  : $uri / yakalama kaynaklı değişken çıkış kanalında (başlık/redirect/return)
  regex : FM yoluna eşleşen ya da ReDoS'a açık düzenli ifade (Python re + sre_parse AST'si)
  val   : değer sınıfı (sınırsız gövde, geçersiz adres, ASCII dışı bayt, yol alan günlük …)
  unk   : bilinmeyen direktif (kahin tanımadığı her şeyi GÜVENSİZ sayar)
unsafe(data) -> [(sınıf, açıklama), ...]   (boş liste = güvenli)
"""
import ipaddress
import re
import signal
import sys

try:
    import re._parser as sre_parse  # Python >= 3.11
except Exception:  # pragma: no cover
    import sre_parse

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import ngxlex  # noqa: E402

NET = re.compile(r"(_pass$|^(proxy|fastcgi|uwsgi|scgi|grpc|memcached)_|^mirror$|^resolver$|^js_|^perl|^lua_|_by_lua|^xslt|^ssi|^sub_filter|^dav_|^echo|^more_|^add_(before|after)_body$|^add_trailer$|^empty_gif$|^stub_status$)")
FILE = re.compile(r"(^root$|^alias$|^include$|^load_module$|^error_log$|_path$|_file$|^ssl_|_store|^client_body_temp_path$|^log_format$|^open_log_file_cache$|^types$)")
TOPO = re.compile(r"^(server|server_name|listen|upstream|map|geo|split_clients|stream|mail|events|http|limit_req_zone|limit_conn_zone|set_real_ip_from|real_ip_header|real_ip_recursive)$")
WAF = re.compile(r"^(modsecurity|disable_symlinks|satisfy|auth_basic|auth_request|internal|error_page)")
BENIGN = {"client_max_body_size", "location", "if", "set", "return", "add_header", "allow", "deny",
          "try_files", "limit_req", "limit_conn", "limit_except", "expires", "log_not_found",
          "access_log", "index", "rewrite"}
TOKEN_SUBSTR = ["upstream_http", "sent_http", "http_authorization", "auth_request", "fm_auth",
                "$fm", "@fm", "_fm", "fm_", "x-fm", "x-accel", "$cookie", "cookie_", "$ssl_",
                "srvctl"]
SAFE_VARS = {"request_uri", "scheme", "host", "server_name", "args", "is_args", "query_string",
             "request_method", "remote_addr", "http_host", "http_user_agent", "http_referer"}
FM_URIS = ["/_fm/", "/_fm/up/1/2", "/_fm/up/12/345", "/_fm/x", "/__fm_auth", "/__fm_dl",
           "/_fm/up/1/2?a=1", "/_fm/up/", "/_fm/dl/", "/_fm/dl/1", "/_fm/zip", "/_fm/up/0/0",
           "/_fm/upload", "/_fm/a/b/c", "/_fm/up/123456789/987654321", "/_fm/up/99999999999999999999/11111111111111111111"]
for _c in "abcdefghijklmnopqrstuvwxyz0123456789":
    FM_URIS += ["/_fm/%s" % _c, "/_fm/%s%s%s" % (_c, _c, _c), "/_fm/%s/%s" % (_c, _c), "/_fm/up/%s" % _c,
                "/_fm/up/%s%s%s" % (_c, _c, _c), "/_fm/up/%s/%s" % (_c, _c), "/_fm/dl/%s" % _c]
ZONES = {"rl_strict", "rl_standard", "rl_relaxed", "rl_api", "login_strict", "login_standard",
         "login_relaxed", "general", "login", "api"}


def _vars_in(tok):
    """Belirteçteki $-başvuruları: [(ad, ham_biçim_mi)] — ${…} ya da geçersiz → None."""
    out = []
    i = 0
    while True:
        i = tok.find("$", i)
        if i < 0:
            return out
        rest = tok[i + 1:]
        if rest.startswith("{"):
            return None
        m = re.match(r"[A-Za-z0-9_]+", rest)
        if not m:
            return None
        out.append(m.group(0))
        i += 1 + len(m.group(0))


def _regex_findings(pat, icase):
    res = []
    if len(pat) > 200:
        res.append(("regex", "uzunluk > 200"))
    if re.search(r"\(\*|\(\?\{|\(\?C|\(\?R|\(\?[0-9+-]|\(\?&|\(\?P[>=]|\(\?\(|\(\?\||\\[1-9gkQ]", pat):
        res.append(("regex", "PCRE özel yapı (kod/rekürsiyon/geri başvuru/koşul)"))
    p2 = re.sub(r"\(\?<([A-Za-z0-9_]+)>", r"(?P<\1>", pat)
    flags = re.I if icase else 0
    try:
        rx = re.compile(p2, flags)
    except Exception as e:  # noqa: BLE001
        res.append(("regex", "Python re derleyemedi: %s" % e))
        return res, []
    cands = list(FM_URIS)
    if icase:
        cands += [u.upper() for u in FM_URIS]
    class _TO(Exception):
        pass

    def _alarm(signum, frame):
        raise _TO()

    old_h = signal.signal(signal.SIGALRM, _alarm)
    try:
        for u in cands:
            signal.setitimer(signal.ITIMER_REAL, 0.25)
            try:
                hit = rx.search(u)
            except _TO:
                res.append(("regex", "Python re arama zaman aşımı (ReDoS): %s" % u))
                break
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
            if hit:
                res.append(("regex", "FM yoluna eşleşir: %s" % u))
                break
    finally:
        signal.signal(signal.SIGALRM, old_h)
    # ReDoS: AST — sınırsız/çok tekrarlı tekrar içinde tekrar ya da dal
    try:
        tree = sre_parse.parse(p2, flags)
    except Exception as e:  # noqa: BLE001
        res.append(("regex", "sre_parse: %s" % e))
        return res, []
    names = list(rx.groupindex.keys())

    def walk(sub, in_rep):
        bad = False
        for op, av in sub:
            name = str(op)
            if name in ("MAX_REPEAT", "MIN_REPEAT", "POSSESSIVE_REPEAT"):
                lo, hi, inner = av
                big = hi is sre_parse.MAXREPEAT or hi > 1
                if in_rep and big:
                    bad = True
                if big and _has_rep_or_branch(inner):
                    bad = True
                if walk(inner, in_rep or big):
                    bad = True
            elif name == "SUBPATTERN":
                if walk(av[-1], in_rep):
                    bad = True
            elif name == "BRANCH":
                for br in av[1]:
                    if walk(br, in_rep):
                        bad = True
            elif name in ("ASSERT", "ASSERT_NOT"):
                if walk(av[1], in_rep):
                    bad = True
        return bad

    def _has_rep_or_branch(sub):
        for op, av in sub:
            name = str(op)
            if name in ("MAX_REPEAT", "MIN_REPEAT", "POSSESSIVE_REPEAT", "BRANCH"):
                return True
            if name == "SUBPATTERN" and _has_rep_or_branch(av[-1]):
                return True
        return False

    if walk(tree, False):
        res.append(("regex", "iç içe/alternasyonlu tekrar (ReDoS)"))
    unbounded = len(re.findall(r"(?<!\\)[*+]|\{\d+,\}", pat))
    if unbounded > 4:
        res.append(("regex", "5+ sınırsız nicelik"))
    return res, names


def unsafe(data):
    ev, err = ngxlex.tokenize(data)
    res = []
    if err:
        res.append(("lex", "çözümlenemez: " + err))
    defined = set()
    tainted = set()
    stack = []
    for kind, line, toks in ev:
        name = toks[0]
        args = toks[1:]
        low = name.lower()
        # ASCII dışı / kontrol
        for t in toks:
            if re.search(r"[^\x20-\x7e]", t):
                res.append(("val", "%s: kontrol/ASCII dışı bayt" % name))
                break
        # sınıf
        if name not in BENIGN:
            if NET.search(low):
                res.append(("net", name))
            elif FILE.search(low):
                res.append(("file", name))
            elif TOPO.match(low):
                res.append(("topo", name))
            elif WAF.match(low):
                res.append(("waf", name))
            else:
                res.append(("unk", name))
        # token ad uzayı
        joined = " ".join(toks).replace("\\", "").lower()
        for s in TOKEN_SUBSTR:
            if s in joined:
                res.append(("token", "%s ∋ %s" % (name, s)))
                break
        # bağlam: limit_except gövdesi
        if kind == "stmt" and name not in BENIGN:
            pass
        regex_idx = set()
        icase = False
        if name == "location" and len(args) == 2 and args[0] in ("~", "~*"):
            regex_idx = {1}; icase = args[0] == "~*"
        if name == "rewrite" and args:
            regex_idx = {0}
        cond = None
        if name == "if":
            a = list(args)
            if a and a[0].startswith("("):
                a[0] = a[0][1:]
                if a[0] == "":
                    a.pop(0)
            if a and a[-1].endswith(")"):
                a[-1] = a[-1][:-1]
                if a[-1] == "":
                    a.pop()
            cond = a
            if len(a) == 3 and a[1] in ("~", "~*", "!~", "!~*"):
                regex_idx = {("if", 2)}; icase = a[1].endswith("*")
        # regex denetimi
        rx_targets = []
        if name == "location" and 1 in regex_idx:
            rx_targets.append(args[1])
        if name == "rewrite" and args:
            rx_targets.append(args[0])
        if name == "if" and cond and len(cond) == 3 and cond[1] in ("~", "~*", "!~", "!~*"):
            rx_targets.append(cond[2])
        for pat in rx_targets:
            f, names = _regex_findings(pat, icase)
            res.extend(f)
            for nm in names:
                if not re.match(r"^u_[a-z0-9_]{1,30}$", nm):
                    res.append(("var", "yakalama adı u_ değil: " + nm))
                defined.add(nm)
                tainted.add(nm)
        # değişken başvuruları (regex olmayan argümanlar)
        skip_vals = set()
        if name == "location":
            skip_vals = {args[1]} if len(args) == 2 and args[0] in ("~", "~*") else set()
        if name == "rewrite" and args:
            skip_vals = {args[0]}
        if name == "if" and cond and len(cond) == 3 and cond[1] in ("~", "~*", "!~", "!~*"):
            skip_vals = {cond[2]}
        out_channel = []
        if name == "add_header" and len(args) >= 2:
            out_channel = [args[1]]
        elif name == "return":
            out_channel = args[1:] if (args and re.match(r"^\d+$", args[0]) and len(args) > 1) else (args if args and not re.match(r"^\d+$", args[0]) else [])
        elif name == "rewrite" and len(args) >= 2:
            flag = args[2] if len(args) > 2 else ""
            if flag in ("redirect", "permanent") or re.match(r"^https?://", args[1]):
                out_channel = [args[1]]
            else:
                if "$" in args[1]:
                    res.append(("crlf", "rewrite last/break YERİNE değişken"))
        elif name == "set" and len(args) == 2:
            out_channel = [args[1]]
        scan_args = cond if (name == "if" and cond is not None) else args
        for ti, t in enumerate(scan_args):
            if t in skip_vals and t != "":
                continue
            if name == "set" and ti == 0:
                continue
            vs = _vars_in(t)
            if vs is None:
                res.append(("var", "%s: ${…}/geçersiz $" % name))
                continue
            for v in vs:
                lv = v.lower()
                is_out = t in out_channel
                if re.fullmatch(r"[0-9]+", lv):
                    if not re.fullmatch(r"[1-9]", lv):
                        res.append(("var", "$%s aralık dışı" % v))
                    elif is_out:
                        res.append(("crlf", "$%s çıkış kanalında" % v))
                elif lv == "uri":
                    if is_out:
                        res.append(("crlf", "$uri çıkış kanalında"))
                elif lv in SAFE_VARS or re.fullmatch(r"arg_[a-z0-9_]+", lv):
                    pass
                elif lv in defined:
                    if is_out and lv in tainted:
                        res.append(("crlf", "$%s (bulaşık) çıkış kanalında" % v))
                else:
                    res.append(("var", "$%s kapalı küme dışı/tanımsız" % v))
        # direktife özgü değer sınıfları
        if name == "set" and len(args) == 2:
            tgt = args[0]
            if not re.fullmatch(r"\$u_[a-z0-9_]{1,30}", tgt):
                res.append(("var", "set hedefi u_ değil: " + tgt))
            else:
                src_taint = False
                for v in (_vars_in(args[1]) or []):
                    lv = v.lower()
                    if lv == "uri" or re.fullmatch(r"[0-9]", lv) or lv in tainted:
                        src_taint = True
                defined.add(tgt[1:])
                if src_taint:
                    tainted.add(tgt[1:])
        if name == "client_max_body_size" and args and re.fullmatch(r"0+[kKmMgG]?", args[0]):
            res.append(("val", "client_max_body_size 0 (sınırsız)"))
        if name == "access_log" and args != ["off"]:
            res.append(("val", "access_log yol/biçim"))
        if name in ("allow", "deny") and len(args) == 1 and args[0] != "all":
            try:
                ipaddress.ip_network(args[0], strict=False)
            except Exception:  # noqa: BLE001
                res.append(("val", "geçersiz adres: " + args[0]))
        if name in ("limit_req",):
            z = [a for a in args if a.startswith("zone=")]
            if not z or z[0][5:] not in ZONES:
                res.append(("val", "limit_req zone kapalı kümede değil"))
        if name == "limit_conn":
            if not args or args[0] != "conn_per_ip":
                res.append(("val", "limit_conn zone kapalı kümede değil"))
        if name == "add_header" and args:
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{0,63}", args[0]):
                res.append(("val", "başlık adı"))
        if kind == "open":
            stack.append(name)
    return res


if __name__ == "__main__":
    r = unsafe(open(sys.argv[1], "rb").read())
    for c, d in r:
        print("%s: %s" % (c, d))
    sys.exit(1 if r else 0)
