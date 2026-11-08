#!/usr/bin/env python3
"""Tekrarlanabilir (sabit tohum) nginx yapısı üreticisi.

Strateji karışımı (her vaka için tohumdan türeyen rastgele seçim):
  grammar  (%40) gramer-güdümlü: izinli direktif şablonları + zaman zaman kötü/kenar argümanlar
  mutate   (%30) gramer vakası + 1-4 metin/sözcük mutasyonu (kaçış, tırnak, harf, yasak dizgi …)
  seed     (%20) seeds/poc + seeds/ok dosyalarının mutasyonlu/birleşik hâlleri
  soup     (%10) rastgele direktif/argüman çorbası (yapısal bozukluklar dahil)
Kullanım: gen.py <çıktı-dizini> <adet> <tohum>   (GEN_ONLY=regex|vars: tek strateji)
"""
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

SIZES = ["1m", "100M", "64k", "2g", "0", "0m", "10", "1234567", "-1", "1.5m", "abc", "$uri", "999999", "5K", "00"]
PATHS = ["/", "/a/", "/api/", "/static/", "/a/b/", "/img/", "/_fm/up/", "/_fm/", "/__fm_auth", "/x/../y",
         "/up/", "/a b/", "/old", "/p0", "/robots.txt", "/_FM/", "/%5ffm/", "/a$b", "/.well-known/"]
REGEX = [r"\.(jpg|png|gif)$", r"^/old/[0-9]+$", r"^/a/(.*)$", r"(a+)+$", r"^/_f[m]/", r"^/.fm/up/",
         r"(a|b)*c", r"^/(?<u_id>[0-9]+)$", r"(?<id>[0-9]+)", r".*", r"^/x$", r"\.php$", r"up/",
         r"(?i)abc", r"^/[^/]+/$", r"^/p/([0-9]{1,5})$", r"^/..m/", r"[_]fm", r"\x5ffm", r"^/up/",
         r"^/\w+/$", r"^(/.*)?$", r"(x*)*", r"((a)b)+", r"^/img_[0-9]+\.png$", r"\.(css|js)$",
         r"^/(css|js|img)/", r"^/[a-z]{2}/$", r"(?:a|b)+", r"^/api/v[0-9]+/", r"^/a(?=b)", r"(*FAIL)",
         r"(?{ 1 })", r"^/\d+$", r"(a{1,9}){1,9}", r"a{x", r"^/\.git/", r"/_fm/up/1/2", r"/..m/up/"]
VARS = ["$host", "$request_uri", "$uri", "$args", "$1", "$2", "$arg_x", "$arg_url", "$u_a", "$u_b", "$u_id",
        "$UPSTREAM_HTTP_X", "$fm_auth", "$FM_AUTH", "$cookie_a", "${host}", "$http_authorization", "$remote_addr",
        "$scheme", "$FOO", "$Uri", "$URI", "$server_name", "$query_string", "$is_args", "$request_method",
        "$http_host", "$http_user_agent", "$http_referer", "$sent_http_x", "$upstream_addr", "$ssl_client_cert",
        "$request_filename", "$document_root", "$0", "$10", "$", "$u_nodef", "$binary_remote_addr", "$time_local"]
HEADERS = ["X-A", "X-Frame-Options", "X-Fm-A", "X-Accel-Redirect", "Cache-Control", "a b", "1x", "X_Y",
           "Content-Security-Policy", "x-fm-ticket", "Set-Cookie", "Location", "X-Req"]
VALS = ["v", "\"v w\"", "$host", "\"$scheme://$host$request_uri\"", "$uri", "\"$1\"", "\"a$u_a\"", "always",
        "\"max-age=3600\"", "$arg_x", "\"${host}\"", "$u_a", "\"\\n\"", "\"x\\r\\ny\""]
CODES = ["200", "301", "302", "403", "404", "444", "500", "99", "600", "abc", "0", "1000"]
ADDRS = ["all", "10.0.0.0/8", "192.168.1.1", "2001:db8::/32", "::1", "unix:/run/x.sock", "999.1.1.1",
         "1.2.3.4/33", "example.com", "127.0.0.1/8", "0.0.0.0/0", "::/0", "1.2.3"]
ZONES = ["rl_strict", "rl_standard", "rl_relaxed", "rl_api", "login_strict", "login_standard", "login_relaxed",
         "general", "login", "api", "conn_per_ip", "evil", "zone"]
TIMES = ["30d", "1h", "off", "max", "epoch", "-1", "modified", "+24h", "1x", "$uri", "100", "1ms", "10M"]
IDX = ["index.html", "index.php", "$x", "/abs.html", "..", "a/b.html", "default.htm"]
METHODS = ["GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE", "get", "PATCH", "FOO"]
FLAGS = ["last", "break", "redirect", "permanent", "", "flagx"]
TRY = ["$uri", "$uri/", "/index.php?$args", "=404", "@app", "/a.html", "@fm_up", "$uri.php", "/x$uri", "=4040",
       "/index.php?$query_string", "/a/../b", "@Bad", "=403"]
BAD_DIRS = ["proxy_pass", "proxy_set_header", "proxy_http_version", "proxy_ssl_verify", "fastcgi_pass", "fastcgi_param",
            "fastcgi_hide_header", "fastcgi_read_timeout", "uwsgi_pass", "scgi_pass", "grpc_pass", "memcached_pass",
            "auth_request", "auth_request_set", "include", "root", "alias", "server_name", "listen", "disable_symlinks",
            "modsecurity", "modsecurity_rules_file", "ssl_certificate", "ssl_verify_client", "error_log", "error_page",
            "internal", "charset", "default_type", "gzip", "etag", "autoindex", "server_tokens", "satisfy", "limit_rate",
            "client_body_timeout", "client_body_buffer_size", "client_body_temp_path", "keepalive_timeout",
            "send_timeout", "large_client_header_buffers", "auth_basic", "auth_basic_user_file", "ssi", "add_before_body",
            "add_after_body", "sub_filter", "more_set_headers", "add_trailer", "empty_gif", "mirror", "dav_methods",
            "resolver", "log_format", "set_real_ip_from", "real_ip_header", "stub_status", "limit_req_zone",
            "limit_conn_zone", "limit_req_status", "map", "geo", "split_clients", "upstream", "server", "http", "events",
            "stream", "mail", "types", "foo", "Location", "RETURN", "xslt_stylesheet", "js_content", "perl", "echo",
            "lua_code_cache", "sendfile", "tcp_nodelay", "open_file_cache", "if_modified_since", "valid_referers",
            "random_index", "slice", "secure_link", "userid", "image_filter", "worker_connections", "user", "env"]
BAD_ARGS = ["http://127.0.0.1:3000", "unix:/run/php/o.sock", "$arg_u", "/etc", "off", "on", "/tmp/x", "Authorization $http_authorization",
            "X-Fm-Ticket x", "/__fm_auth", "$upstream_http_x_fm_auth $fm_auth", "grpc://x", "1m", "*.conf", "/etc/nginx/x.conf",
            "zone=z:1m rate=1r/s", "text/plain", "utf-8", "any", "x", "{", ""]
EVIL = ["/_fm/", "__fm_auth", "@fm_up", "$fm_auth", "x_fm_auth", "$upstream_http_x_fm_auth", "$sent_http_x", "$http_authorization",
        "$cookie_a", "$ssl_client_cert", "auth_request", "srvctl", "/_FM/up/", "FM_AUTH", "\\_fm", "/\\_fm/", "_f[m]", "$FM_AUTH",
        "x-fm-auth", "x-accel-redirect", "$uri", "$1", "${host}", "../", "\r\n", "\x00", "\t", "\x7f", "é", "$", "\\$uri", "$u_fm"]
QUOTE = ['', '', '', '"', "'"]


def pick(R, xs):
    return xs[R.randrange(len(xs))]


def q(R, s, force=False):
    """Belirteci rastgele tırnakla; tırnak/kaçış çatışırsa olduğu gibi bırak."""
    if s == "" or " " in s or ";" in s or "{" in s or "}" in s or "#" in s or force:
        if '"' not in s and (force or "\\" not in s) and not re.search(r"\\[trn\\\"']", s):
            return '"%s"' % s
        if "'" not in s and "\\" not in s:
            return "'%s'" % s
        return s
    k = R.random()
    if k < 0.15 and '"' not in s and "\\" not in s:
        return '"%s"' % s
    if k < 0.2 and "'" not in s and "\\" not in s:
        return "'%s'" % s
    return s


def stmt(R, d, args, ind=""):
    return ind + " ".join([d] + [q(R, a) for a in args]) + ";"


def good_or_evil(R, good, evil_p=0.15):
    return pick(R, good)


def gen_stmt(R, ind, depth, state, evil):
    """Bir ifade/blok üret; evil → kötü argüman olasılığı."""
    kinds = ["cmb", "location", "add_header", "return", "allow", "deny", "try_files", "limit_req", "limit_conn",
             "expires", "log_not_found", "access_log", "index", "set", "if", "rewrite", "limit_except", "bad", "comment"]
    wts = [3, 9, 8, 6, 3, 3, 5, 3, 2, 4, 2, 3, 2, 6, 5, 5, 2, 3 if evil else 1, 1]
    k = R.choices(kinds, wts)[0]
    nl = "\n"
    if k == "cmb":
        return stmt(R, "client_max_body_size", [pick(R, SIZES) if R.random() < 0.5 else pick(R, ["1m", "100M", "64k"])], ind)
    if k == "comment":
        return ind + "# " + pick(R, ["yorum", "location /x { }", "proxy_pass http://x;", "set $fm_gate 1;", ""])
    if k == "location":
        mod = pick(R, ["", "", "=", "^~", "~", "~*", "@"])
        if mod in ("~", "~*"):
            pat = pick(R, REGEX)
            hdr = "location %s %s" % (mod, q(R, pat, True))
        elif mod == "@":
            hdr = "location %s" % pick(R, ["@app", "@Bad", "@fm_up", "@x1"])
        else:
            hdr = "location " + ((mod + " ") if mod else "") + q(R, pick(R, PATHS))
        body = []
        if depth < 3:
            for _ in range(R.randrange(0, 4)):
                body.append(gen_stmt(R, ind + "    ", depth + 1, state, evil))
        return ind + hdr + " {" + nl + nl.join(body) + (nl if body else "") + ind + "}"
    if k == "add_header":
        a = [pick(R, HEADERS), pick(R, VALS)]
        if R.random() < 0.4:
            a.append("always" if R.random() < 0.8 else pick(R, ["never", "x"]))
        return stmt(R, "add_header", a, ind)
    if k == "return":
        r = R.random()
        if r < 0.2:
            return stmt(R, "return", [pick(R, CODES)], ind)
        if r < 0.5:
            return stmt(R, "return", [pick(R, CODES), pick(R, VALS + ["https://$host$request_uri", "http://x/$1", "/p"])], ind)
        return stmt(R, "return", [pick(R, ["https://$host$request_uri", "http://x/$uri", "$uri", "https://example.com/"])], ind)
    if k in ("allow", "deny"):
        return stmt(R, k, [pick(R, ADDRS)], ind)
    if k == "try_files":
        return stmt(R, "try_files", [pick(R, TRY) for _ in range(R.randrange(1, 5))], ind)
    if k == "limit_req":
        a = ["zone=" + pick(R, ZONES)]
        if R.random() < 0.6:
            a.append("burst=" + pick(R, ["5", "20", "x", "123456", "0"]))
        if R.random() < 0.5:
            a.append(pick(R, ["nodelay", "delay=3"]))
        return stmt(R, "limit_req", a, ind)
    if k == "limit_conn":
        return stmt(R, "limit_conn", [pick(R, ZONES), pick(R, ["10", "0", "x", "100"])], ind)
    if k == "expires":
        a = [pick(R, TIMES)]
        if R.random() < 0.2:
            a.append(pick(R, TIMES))
        return stmt(R, "expires", a, ind)
    if k == "log_not_found":
        return stmt(R, "log_not_found", [pick(R, ["on", "off", "maybe"])], ind)
    if k == "access_log":
        return stmt(R, "access_log", [pick(R, ["off", "off", "/var/log/nginx/x.log", "off main", "../x.log", "syslog:server=1.2.3.4"])], ind)
    if k == "index":
        return stmt(R, "index", [pick(R, IDX) for _ in range(R.randrange(1, 4))], ind)
    if k == "set":
        tgt = pick(R, ["$u_a", "$u_b", "$u_id", "$u_x1", "$fm_gate", "$args", "$U_Q", "$limit_rate", "$arg_x", "$http_x",
                       "$cookie_x", "$upstream_x", "$sent_x", "$ssl_x", "$blocked_country", "$srvctl_x", "u_a", "$u_", "$u_" + "z" * 31])
        if R.random() < 0.75:
            tgt = pick(R, ["$u_a", "$u_b", "$u_id", "$u_x1"])
        return stmt(R, "set", [tgt, pick(R, VALS + VARS)], ind)
    if k == "if":
        r = R.random()
        if r < 0.4:
            cond = "(%s = %s)" % (pick(R, ["$arg_x", "$request_method", "$u_a", "$uri", "$fm_gate", "$FOO", "$http_user_agent"]),
                                    q(R, pick(R, ["1", "POST", "x", "\"\"", "$uri"])))
        elif r < 0.75:
            cond = "(%s %s %s)" % (pick(R, ["$uri", "$arg_a", "$http_user_agent", "$request_uri", "$u_id"]),
                                     pick(R, ["~", "~*", "!~", "!~*"]), q(R, pick(R, REGEX), True))
        elif r < 0.85:
            cond = "(%s)" % pick(R, ["$arg_x", "$u_a", "$foo", "-f $request_filename", "!-e $uri", "-d /etc"])
        else:
            cond = "(%s)" % pick(R, ["$a = b && $c = d", "$arg_a == b", "\"$arg_a$arg_b\" = x", ""])
        body = []
        for _ in range(R.randrange(0, 3)):
            body.append(gen_stmt(R, ind + "    ", depth + 1, state, evil) if R.random() < 0.8 else stmt(R, "return", [pick(R, CODES)], ind + "    "))
        return ind + "if " + cond.replace("(", "(", 1) + " {" + nl + nl.join(body) + (nl if body else "") + ind + "}"
    if k == "rewrite":
        a = [q(R, pick(R, REGEX), True), pick(R, ["/new", "/b", "/b/$1", "$uri", "http://evil/$1", "https://$host/y", "/b/../c", "b", "/x?a=$arg_x", "https://$host$uri"])]
        f = pick(R, FLAGS)
        if f:
            a.append(f)
        return stmt(R, "rewrite", a, ind)
    if k == "limit_except":
        body = [stmt(R, pick(R, ["deny", "allow", "return", "set"]), [pick(R, ["all", "10.0.0.0/8", "403"])], ind + "    ") for _ in range(R.randrange(1, 3))]
        return ind + "limit_except " + " ".join(pick(R, METHODS) for _ in range(R.randrange(1, 3))) + " {" + nl + nl.join(body) + nl + ind + "}"
    # bad
    d = pick(R, BAD_DIRS)
    a = [pick(R, BAD_ARGS) for _ in range(R.randrange(0, 3))]
    if d in ("map", "geo", "upstream", "server", "http", "events", "stream", "mail", "types") and R.random() < 0.6:
        return ind + d + " " + " ".join(a) + " {" + nl + ind + "}"
    return stmt(R, d, a, ind)



GOOD_RX = [r"\.(jpg|png|gif)$", r"^/old/[0-9]+$", r"^/x$", r"\.php$", r"\.(css|js)$", r"^/(css|js|img)/",
           r"^/api/v[0-9]+/", r"^/[a-z]{2}/$", r"(?:a|b)", r"^/p/([0-9]{1,5})$", r"^/img_[0-9]+\.png$", r"^/old-page$",
           r"^/blog/([a-z0-9-]+)/?$", r"^/(?<u_slug>[a-z]+)$", r"\.(woff2?|ttf)$"]
GOOD_PATHS = ["/", "/a/", "/api/", "/static/", "/img/", "/assets/", "/robots.txt", "/old", "/p0", "/.well-known/", "/blog/"]
GOOD_VALS = ["v", "v w", "$host", "$scheme://$host$request_uri", "$arg_x", "$request_method", "public, max-age=3600",
             "$remote_addr", "$http_user_agent", "$args", "$query_string", "SAMEORIGIN", "nosniff"]
GOOD_H = ["X-A", "X-Frame-Options", "Cache-Control", "X-Req", "X-Content-Type-Options", "Referrer-Policy", "Content-Security-Policy"]


def gen_good_stmt(R, ind, depth, st, in_loc):
    nl = "\n"
    k = R.choices(["cmb", "location", "add_header", "return", "allow", "deny", "try_files", "limit_req", "limit_conn",
                   "expires", "log_not_found", "access_log", "index", "set", "if", "rewrite", "limit_except", "comment"],
                  [2, 8 if depth < 2 else 0, 8, 5, 2, 2, 4 if in_loc else 0, 3 if in_loc else 0, 2 if in_loc else 0, 4, 2, 2, 2, 5, 5, 4,
                   2 if in_loc else 0, 1])[0]
    if k == "cmb":
        return stmt(R, "client_max_body_size", [pick(R, ["1m", "100M", "64k", "2g", "999999"])], ind)
    if k == "comment":
        return ind + "# " + pick(R, ["yorum", "kural", "bölüm"])
    if k == "location":
        mod = pick(R, ["", "", "=", "^~", "~", "~*"])
        if mod in ("~", "~*"):
            pat = pick(R, GOOD_RX)
            if "u_slug" in pat:
                st["def"].add("$u_slug")
            hdr = "location %s %s" % (mod, q(R, pat, True))
        else:
            hdr = "location " + ((mod + " ") if mod else "") + pick(R, GOOD_PATHS)
        body = [gen_good_stmt(R, ind + "    ", depth + 1, st, True) for _ in range(R.randrange(0, 4))]
        return ind + hdr + " {" + nl + nl.join(body) + (nl if body else "") + ind + "}"
    if k == "add_header":
        a = [pick(R, GOOD_H), pick(R, GOOD_VALS)]
        if R.random() < 0.5:
            a.append("always")
        return stmt(R, "add_header", a, ind)
    if k == "return":
        r = R.random()
        if r < 0.4:
            return stmt(R, "return", [pick(R, ["403", "404", "444", "410", "200"])], ind)
        if r < 0.7:
            return stmt(R, "return", [pick(R, ["200", "403"]), pick(R, GOOD_VALS)], ind)
        return stmt(R, "return", [pick(R, ["301", "302", "308"]), pick(R, ["https://$host$request_uri", "https://example.com/x", "/p"])], ind)
    if k in ("allow", "deny"):
        return stmt(R, k, [pick(R, ["all", "10.0.0.0/8", "192.168.1.1", "2001:db8::/32", "::1", "127.0.0.1"])], ind)
    if k == "try_files":
        return stmt(R, "try_files", [pick(R, ["$uri", "$uri/"]) for _ in range(R.randrange(1, 3))] + [pick(R, ["=404", "/index.php?$args", "/index.html", "=403"])], ind)
    if k == "limit_req":
        a = ["zone=" + pick(R, ["rl_strict", "rl_standard", "rl_relaxed", "rl_api", "login_strict", "general"])]
        if R.random() < 0.6:
            a.append("burst=" + pick(R, ["5", "20", "100"]))
        if R.random() < 0.5:
            a.append("nodelay")
        return stmt(R, "limit_req", a, ind)
    if k == "limit_conn":
        return stmt(R, "limit_conn", ["conn_per_ip", pick(R, ["5", "10", "100"])], ind)
    if k == "expires":
        return stmt(R, "expires", [pick(R, ["30d", "1h", "off", "max", "epoch", "-1", "10m"])], ind)
    if k == "log_not_found":
        return stmt(R, "log_not_found", [pick(R, ["on", "off"])], ind)
    if k == "access_log":
        return stmt(R, "access_log", ["off"], ind)
    if k == "index":
        return stmt(R, "index", [pick(R, ["index.html", "index.php", "default.htm"]) for _ in range(R.randrange(1, 3))], ind)
    if k == "set":
        nm = pick(R, ["$u_a", "$u_b", "$u_flag", "$u_x1"])
        st["def"].add(nm)
        return stmt(R, "set", [nm, pick(R, GOOD_VALS)], ind)
    if k == "if":
        r = R.random()
        defs = sorted(st["def"])
        if r < 0.4:
            cond = "(%s %s %s)" % (pick(R, ["$arg_x", "$request_method", "$http_user_agent", "$uri"] + defs), pick(R, ["=", "!="]), q(R, pick(R, ["1", "POST", "x", "TRACE", "bot"])))
        elif r < 0.85:
            cond = "(%s %s %s)" % (pick(R, ["$uri", "$arg_a", "$http_user_agent", "$request_uri"]), pick(R, ["~", "~*", "!~", "!~*"]), q(R, pick(R, GOOD_RX[:12]), True))
        else:
            cond = "(%s)" % pick(R, ["$arg_x"] + defs)
        body = [stmt(R, "return", [pick(R, ["403", "404", "410", "444"])], ind + "    ")] if R.random() < 0.7 else [gen_good_stmt(R, ind + "    ", 3, st, False) for _ in range(R.randrange(1, 3))]
        body = [b for b in body if "location" not in b.split("\n")[0] and not b.lstrip().startswith("if ")] or [stmt(R, "return", ["403"], ind + "    ")]
        return ind + "if " + cond + " {" + nl + nl.join(body) + nl + ind + "}"
    if k == "rewrite":
        fl = pick(R, ["last", "break", "redirect", "permanent", ""])
        tgt = pick(R, ["/new", "/b", "/page"]) if fl in ("last", "break", "") else pick(R, ["/new", "https://$host/y", "https://example.com/z"])
        a = [q(R, pick(R, ["^/old-page$", "^/a/([0-9]+)$", "^/x$", "^/blog/(.*)$"]), True), tgt]
        if fl:
            a.append(fl)
        return stmt(R, "rewrite", a, ind)
    if k == "limit_except":
        body = [stmt(R, pick(R, ["deny", "allow"]), [pick(R, ["all", "10.0.0.0/8"])], ind + "    ") for _ in range(R.randrange(1, 3))]
        return ind + "limit_except " + " ".join(sorted(set(pick(R, ["GET", "POST", "HEAD", "PUT"]) for _ in range(R.randrange(1, 3))))) + " {" + nl + nl.join(body) + nl + ind + "}"
    return ""


def gen_good(R):
    st = {"def": set()}
    out = []
    for _ in range(R.randrange(1, 8)):
        out.append(gen_good_stmt(R, "", 0, st, False))
    return "\n".join(o for o in out if o) + "\n"


def gen_oneflaw(R):
    good_t = gen_good(R)
    lines = good_t.split("\n")
    i = R.randrange(len(lines))
    evil = gen_stmt(R, "", 2, {}, True)
    lines.insert(i, evil)
    return "\n".join(lines)


RX_LIT = list("/_fmup-a1.x") + ["_fm", "fm", "/_", "up/", "/up", "__fm_auth", "fm_auth", "_f", "/x/", "api", "img"]
RX_ATOM = [".", "[^/]", "[a-z]", "[0-9]", "\\.", "\\d", "\\w", "\\s", "[a-z0-9]", "[_]", "[m]", "[^_]", "[^a]", "[\\w]", ".*", ".+", "[^/]+", "[0-9]+", "[A-Za-z]"]


def rx_gen(R, depth=0):
    out = []
    for _ in range(R.randrange(1, 6)):
        r = R.random()
        if r < 0.45:
            a = pick(R, RX_LIT)
        elif r < 0.75:
            a = pick(R, RX_ATOM)
        elif depth < 2:
            g = rx_gen(R, depth + 1)
            a = pick(R, ["(%s)", "(?:%s)", "(%s|b)", "(a|%s)", "(?<u_g%d>%%s)" % R.randrange(9)]) % g
        else:
            a = pick(R, RX_LIT)
        if R.random() < 0.25:
            a += pick(R, ["*", "+", "?", "{1,3}", "{2}", "{1,}", "*?"])
        out.append(a)
    t = "".join(out)
    if depth == 0:
        if R.random() < 0.5:
            t = "^" + t
        if R.random() < 0.3:
            t += "$"
    return t


def gen_regex(R):
    out = []
    for _ in range(R.randrange(1, 4)):
        rx = rx_gen(R)
        k = R.randrange(3)
        if k == 0:
            out.append("location %s %s {\n    return 403;\n}" % (pick(R, ["~", "~*"]), q(R, rx, True)))
        elif k == 1:
            out.append("if ($%s %s %s) {\n    return 403;\n}" % (pick(R, ["uri", "request_uri", "arg_x", "http_user_agent"]), pick(R, ["~", "~*", "!~", "!~*"]), q(R, rx, True)))
        else:
            out.append(("rewrite %s /new %s;" % (q(R, rx, True), pick(R, ["last", "break", "permanent", ""]))).replace(" ;", ";"))
    return "\n".join(out) + "\n"


VPOOL = ["uri", "request_uri", "scheme", "host", "server_name", "args", "is_args", "query_string", "request_method",
         "remote_addr", "http_host", "http_user_agent", "http_referer", "arg_x", "arg_", "u_a", "u_b", "u_g1", "fm_auth",
         "upstream_http_x_fm_auth", "sent_http_x_a", "cookie_a", "http_authorization", "ssl_client_cert", "document_root",
         "request_filename", "limit_rate", "binary_remote_addr", "time_local", "request_body", "http_x_forwarded_for",
         "1", "2", "9", "0", "10", "fm_up_uid", "blocked_country", "srvctl_x", "realpath_root", "args2", "arg_a1_b"]


def vcase(R, v):
    r = R.random()
    if r < 0.2:
        return v.upper()
    if r < 0.3:
        return v.swapcase()
    if r < 0.35:
        return v.capitalize()
    return v


def gen_vars(R):
    out = ["set $u_a 1;", "set $u_b $host;"]
    for _ in range(R.randrange(2, 7)):
        parts = []
        for _ in range(R.randrange(1, 4)):
            r = R.random()
            if r < 0.7:
                v = vcase(R, pick(R, VPOOL))
                parts.append(pick(R, ["$%s", "$%s", "${%s}"]) % v)
            else:
                parts.append(pick(R, ["x", "/", "://", "-", " "]))
        val = "".join(parts)
        k = R.randrange(6)
        if k == 0:
            out.append("add_header X-A %s;" % q(R, val, True))
        elif k == 1:
            out.append("return %s %s;" % (pick(R, ["200", "301", "403"]), q(R, val, True)))
        elif k == 2:
            out.append("set $%s %s;" % (pick(R, ["u_c", "u_d", "U_E", "fm_x", "args", "u_f"]), q(R, val, True)))
        elif k == 3:
            out.append("if ($%s = %s) {\n    return 403;\n}" % (vcase(R, pick(R, VPOOL)), q(R, pick(R, ["1", "x", "$uri"]), True)))
        elif k == 4:
            out.append("rewrite ^/a$ %s %s;" % (q(R, pick(R, ["/b", "/b/" + val, "https://$host/" + val]), True), pick(R, ["last", "redirect", "permanent", "break"])))
        else:
            out.append("add_header %s %s always;" % (pick(R, HEADERS), q(R, val, True)))
    return "\n".join(out) + "\n"


def gen_grammar(R, evil=False):
    n = R.randrange(1, 9)
    out = []
    for _ in range(n):
        out.append(gen_stmt(R, "", 0, {}, evil))
        if R.random() < 0.15:
            out.append("")
    return "\n".join(out) + "\n"


# ── mutasyonlar ──
def mutate(R, text):
    t = text
    for _ in range(R.randrange(1, 5)):
        op = R.randrange(14)
        if not t:
            t = "x;"
        i = R.randrange(len(t) + 1)
        if op == 0:  # evil dize ekle
            t = t[:i] + pick(R, EVIL) + t[i:]
        elif op == 1:  # harf büyüt/küçült bir bölge
            j = min(len(t), i + R.randrange(1, 12))
            t = t[:i] + t[i:j].swapcase() + t[j:]
        elif op == 2:  # ters bölü ekle
            t = t[:i] + "\\" + t[i:]
        elif op == 3:  # çift tırnak ekle
            t = t[:i] + '"' + t[i:]
        elif op == 4:  # tek tırnak ekle
            t = t[:i] + "'" + t[i:]
        elif op == 5:  # ';' sil
            k = t.find(";", i)
            if k >= 0:
                t = t[:k] + t[k + 1:]
        elif op == 6:  # '}' sil / ekle
            k = t.find("}", i)
            if op and k >= 0 and R.random() < 0.5:
                t = t[:k] + t[k + 1:]
            else:
                t = t[:i] + "}" + t[i:]
        elif op == 7:  # '$' değişkenini ${..} yap
            k = t.find("$", i)
            if k >= 0:
                m = k + 1
                while m < len(t) and (t[m].isalnum() or t[m] == "_"):
                    m += 1
                t = t[:k] + "${" + t[k + 1:m] + "}" + t[m:]
        elif op == 8:  # LF ekle
            t = t[:i] + "\n" + t[i:]
        elif op == 9:  # satır kopyala
            lines = t.split("\n")
            k = R.randrange(len(lines))
            lines.insert(R.randrange(len(lines) + 1), lines[k])
            t = "\n".join(lines)
        elif op == 10:  # bir sözcüğü değiştir
            ws = t.split(" ")
            if ws:
                ws[R.randrange(len(ws))] = pick(R, EVIL + VARS + BAD_DIRS)
                t = " ".join(ws)
        elif op == 11:  # kontrol/yüksek bayt
            t = t[:i] + pick(R, ["\x01", "\x00", "\r", "\xa0", "\xef\xbb\xbf", "\x7f"]) + t[i:]
        elif op == 12:  # '#' yorum ekle
            t = t[:i] + "#" + t[i:]
        elif op == 13:  # blok başlığına satır ekle
            k = t.find("{", i)
            if k >= 0:
                t = t[:k + 1] + "\n" + stmt(R, pick(R, BAD_DIRS), [pick(R, BAD_ARGS)]) + t[k + 1:]
    return t


def load_seeds():
    seeds = []
    for sub in ("poc", "ok"):
        d = os.path.join(HERE, "seeds", sub)
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                seeds.append(open(os.path.join(d, f), "rb").read().decode("latin-1"))
    reg = os.path.join(HERE, "regress")
    if os.path.isdir(reg):
        for f in sorted(os.listdir(reg)):
            if f.endswith(".conf"):
                seeds.append(open(os.path.join(reg, f), "rb").read().decode("latin-1"))
    return seeds


def gen_soup(R):
    parts = []
    for _ in range(R.randrange(1, 12)):
        r = R.random()
        if r < 0.5:
            parts.append(pick(R, ["location", "if", "set", "return", "add_header", "rewrite", "try_files", "allow", "limit_req"] + BAD_DIRS))
        elif r < 0.8:
            parts.append(pick(R, PATHS + VARS + EVIL + REGEX + HEADERS + VALS))
        else:
            parts.append(pick(R, [";", "{", "}", ";\n", "{\n", "}\n", "#", '"', "'", "\\", "\n", "(", ")", "~", "~*", "="]))
    return pick(R, [" ", "\n", " "]).join(parts) + pick(R, ["", ";", "\n", ";\n", "}"])


def main():
    out, count, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(out, exist_ok=True)
    R = random.Random(seed)
    seeds = load_seeds()
    strat_count = {}
    with open(os.path.join(out, "MANIFEST.tsv"), "w") as mf:
        for n in range(count):
            r = R.random()
            only = os.environ.get("GEN_ONLY", "")
            if only == "regex":
                s = "regex"; t = gen_regex(R)
                if R.random() < 0.2:
                    t = mutate(R, t)
            elif only == "vars":
                s = "vars"; t = gen_vars(R)
                if R.random() < 0.2:
                    t = mutate(R, t)
            elif r < 0.20:
                s = "good"; t = gen_good(R)
            elif r < 0.40:
                s = "oneflaw"; t = gen_oneflaw(R)
            elif r < 0.55:
                s = "mutgood"; t = mutate(R, gen_good(R))
            elif r < 0.63:
                s = "grammar"; t = gen_grammar(R, evil=R.random() < 0.5)
            elif r < 0.75 and seeds:
                s = "seed"
                a = pick(R, seeds)
                if R.random() < 0.5:
                    a = a + gen_good(R)
                t = mutate(R, a) if R.random() < 0.7 else a
            elif r < 0.87:
                s = "regex"; t = gen_regex(R)
                if R.random() < 0.3:
                    t = mutate(R, t)
            elif r < 0.95:
                s = "vars"; t = gen_vars(R)
                if R.random() < 0.3:
                    t = mutate(R, t)
            else:
                s = "soup"; t = gen_soup(R)
            strat_count[s] = strat_count.get(s, 0) + 1
            name = "c%06d.conf" % n
            with open(os.path.join(out, name), "wb") as fh:
                fh.write(t.encode("latin-1", "replace") if all(ord(c) < 256 for c in t) else t.encode("utf-8", "replace"))
            mf.write("%s\t%s\n" % (name, s))
    print("üretildi: %d vaka, tohum=%d, strateji=%s" % (count, seed, strat_count))


if __name__ == "__main__":
    main()
