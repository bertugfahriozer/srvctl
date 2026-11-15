#!/usr/bin/env python3
"""Diferansiyel fuzz sürücüsü (R6).

Her vaka için üç hüküm:
  (1) lib/nginx_allow.sh  _ngxallow_scan   → KABUL (rc 0) / RET (rc 1,2)
  (2) gerçek nginx -T (yalnız test, dinleme yok) → KABUL / RET  + dökümden AST
  (3) oracle.py güvenlik kahini            → GÜVENLİ / GÜVENSİZ (+ sınıflar)
Ölçüt: tarayıcı KABUL ∧ kahin GÜVENSİZ = 0.  Ek olarak lexer diferansiyeli:
bash lexer olayları ↔ ngxlex.py (C durum makinesi) ↔ nginx hata konumu.

Kullanım: run.py --count N --seed S --work DIR [--lib yol/nginx_allow.sh] [--shards 4]
"""
import argparse
import collections
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ngxlex  # noqa: E402
import oracle  # noqa: E402

NGINX = os.environ.get("NGINX_BIN", os.path.expanduser("~/Library/PhpWebStudy/app/nginx-1.28.0/sbin/nginx"))


def dec(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t", "\\": "\\"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c); i += 1
    return "".join(out)


def parse_results(path):
    res = collections.OrderedDict()
    cur = None
    with open(path, "rb") as fh:
        for raw in fh:
            line = raw.decode("latin-1").rstrip("\n")
            if line.startswith("@@ "):
                _, name, rc, lrc = line.split(" ", 3)
                cur = res.setdefault(name, {"rc": int(rc), "lrc": int(lrc), "ev": [], "find": []})
            elif line.startswith("E ") and cur is not None:
                _, kind, ln, rest = line.split(" ", 3)
                cur["ev"].append((kind, int(ln), [dec(t) for t in rest.split("\t")]))
            elif line.startswith("F ") and cur is not None:
                cur["find"].append(line[2:])
    return res


def nginx_conf(work, case_path, i):
    zones = "".join("limit_req_zone $binary_remote_addr zone=%s:1m rate=5r/s;\n" % z for z in
                    ["rl_strict", "rl_standard", "rl_relaxed", "rl_api", "login_strict", "login_standard", "login_relaxed",
                     "general", "login", "api"])
    conf = os.path.join(work, "nx", "n%06d.conf" % i)
    with open(conf, "w") as fh:
        fh.write("""pid %(w)s/nx/n.pid;
error_log %(w)s/nx/e.log;
events {}
http {
  access_log off;
  client_body_temp_path %(w)s/nx/t; proxy_temp_path %(w)s/nx/t; fastcgi_temp_path %(w)s/nx/t; uwsgi_temp_path %(w)s/nx/t; scgi_temp_path %(w)s/nx/t;
  resolver 127.0.0.1:9;
  %(z)s
  limit_conn_zone $binary_remote_addr zone=conn_per_ip:1m;
  server {
    listen 127.0.0.1:18997;
    server_name x.invalid;
    root %(w)s/nx/root;
    location ^~ /_fm/up/ { return 200 up; }
    location ^~ /_fm/ { return 403; }
    location = /__fm_auth { internal; return 200; }
    location @fm_up { return 200; }
    include %(c)s;
  }
}
""" % {"w": work, "z": zones, "c": case_path})
    return conf


def run_nginx(work, case_path, i):
    conf = nginx_conf(work, case_path, i)
    p = subprocess.run([NGINX, "-T", "-p", os.path.join(work, "nx"), "-c", conf, "-e", os.path.join(work, "nx", "e.log")],
                       capture_output=True, timeout=60)
    os.unlink(conf)
    return p.returncode, p.stdout, p.stderr.decode("latin-1")


def section(dump, case_path):
    hdr = ("# configuration file %s:\n" % case_path).encode()
    k = dump.find(hdr)
    if k < 0:
        return None
    k += len(hdr)
    e = dump.find(b"\n# configuration file ", k)
    return dump[k:] if e < 0 else dump[k:e + 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=20261024)
    ap.add_argument("--work", required=True)
    ap.add_argument("--lib", default="")
    ap.add_argument("--shards", type=int, default=4)
    ap.add_argument("--keep-bad", default="")
    a = ap.parse_args()
    work = os.path.abspath(a.work)
    os.makedirs(os.path.join(work, "cases"), exist_ok=True)
    os.makedirs(os.path.join(work, "nx", "t"), exist_ok=True)
    os.makedirs(os.path.join(work, "nx", "root"), exist_ok=True)
    cases = os.path.join(work, "cases")
    print(subprocess.run([sys.executable, os.path.join(HERE, "gen.py"), cases, str(a.count), str(a.seed)],
                         capture_output=True, text=True).stdout.strip())
    names = sorted(f for f in os.listdir(cases) if f.endswith(".conf"))
    strat = dict(l.rstrip("\n").split("\t") for l in open(os.path.join(cases, "MANIFEST.tsv")))
    # 1) tarayıcı (kabuk, paralel parçalar)
    shards = [names[i::a.shards] for i in range(a.shards)]
    procs, outs = [], []
    env = dict(os.environ)
    if a.lib:
        env["SRVCTL_NGXALLOW_LIB"] = os.path.abspath(a.lib)
    for si, sh in enumerate(shards):
        lst = os.path.join(work, "shard%d.lst" % si)
        open(lst, "w").write("\n".join(os.path.join(cases, n) for n in sh) + "\n")
        o = os.path.join(work, "shard%d.out" % si)
        outs.append(o)
        procs.append(subprocess.Popen(["/bin/bash", os.path.join(HERE, "scan_batch.sh"), lst, o], env=env,
                                      stdout=subprocess.DEVNULL, stderr=open(os.path.join(work, "shard%d.err" % si), "w")))
    # 2) nginx -T paralel
    nx = {}
    with cf.ThreadPoolExecutor(max_workers=4) as ex:
        futs = {ex.submit(run_nginx, work, os.path.join(cases, n), i): n for i, n in enumerate(names)}
        for f in cf.as_completed(futs):
            nx[futs[f]] = f.result()
    for p in procs:
        p.wait()
    scan = {}
    for o in outs:
        for k, v in parse_results(o).items():
            scan[os.path.basename(k)] = v
    # 3) kahin + karşılaştırma
    stats = collections.Counter()
    viol, nxrej_accept, lexdiff, consist = [], [], [], []
    by_class = collections.Counter()
    for n in names:
        sc = scan.get(n)
        if sc is None:
            stats["tarayici_sonuc_yok"] += 1
            continue
        raw = open(os.path.join(cases, n), "rb").read()
        nrc, dump, nerr = nx[n]
        data = raw
        if nrc == 0:
            sec = section(dump, os.path.join(cases, n))
            if sec is None:
                stats["dokumde_bolum_yok"] += 1
            elif sec != raw and sec != raw + b"\n":
                consist.append(n)
                data = sec
            else:
                stats["dokum_ham_ile_esit"] += 1
        unsafe = oracle.unsafe(data)
        stats["toplam"] += 1
        accept = sc["rc"] == 0
        stats["tarayici_kabul" if accept else ("tarayici_ret_rc1" if sc["rc"] == 1 else "tarayici_ret_rc2")] += 1
        stats["nginx_kabul" if nrc == 0 else "nginx_ret"] += 1
        stats["kahin_guvensiz" if unsafe else "kahin_guvenli"] += 1
        stats["strateji_" + strat[n]] += 1
        if accept and unsafe:
            viol.append((n, unsafe, strat[n]))
            for c, _ in unsafe:
                by_class[c] += 1
        if accept and nrc != 0:
            em = re.search(r"\[emerg\] (.*?)(?: in /|$)", nerr, re.M)
            nxrej_accept.append((n, em.group(1) if em else nerr.strip()[-120:]))
        if accept and not unsafe and nrc == 0:
            stats["kabul_guvenli_nginx_kabul"] += 1
        if (not accept) and (not unsafe) and nrc == 0:
            stats["asiri_siki(ret∧guvenli∧nginx_kabul)"] += 1
        # lexer diferansiyeli
        ref_ev, ref_err = ngxlex.tokenize(raw)
        sc_ev = [(k, l, t) for k, l, t in sc["ev"]]
        ref_ev2 = [(k, l, [x for x in t]) for k, l, t in ref_ev]
        if sc["lrc"] == 0 and ref_err is None:
            if sc_ev == ref_ev2:
                stats["lexer_ozdes"] += 1
            else:
                stats["lexer_FARKLI"] += 1
                lexdiff.append((n, "olaylar farklı"))
        elif sc["lrc"] == 0 and ref_err is not None:
            stats["lexer_bash_KABUL_ref_RED"] += 1
            lexdiff.append((n, "bash lexer kabul / referans ret: %s" % ref_err))
        elif sc["lrc"] == 3 and b"\0" in raw:
            stats["lexer_NUL_bash_ret_beklenen"] += 1
        elif sc["lrc"] != 0 and ref_err is None:
            stats["lexer_bash_RED_ref_kabul"] += 1
            lexdiff.append((n, "bash lexer ret (rc=%d) / referans kabul" % sc["lrc"]))
        else:
            stats["lexer_ikisi_de_ret"] += 1
        # nginx ground truth: ref lexer yapısal hata ise nginx de reddetmeli
        if ref_err is not None and nrc == 0:
            stats["nginx_kabul_ama_ref_lexer_RED"] += 1
            lexdiff.append((n, "nginx KABUL / referans lexer RED: %s" % ref_err))
        if nrc != 0:
            m = re.search(r'unknown directive "((?:[^"\\]|\\.)*)" in', nerr) or re.search(r'invalid number of arguments in "([^"]*)" directive', nerr) or re.search(r'"([^"]*)" directive is not allowed here', nerr)
            if m and sc["lrc"] == 0:
                names_sc = {t[0] for _, _, t in sc["ev"] if t}
                if m.group(1) not in names_sc:
                    stats["nginx_hata_adi_bash_olaylarinda_YOK"] += 1
                    lexdiff.append((n, "nginx '%s' direktifini raporladı; bash lexer olaylarında yok" % m.group(1)))
                else:
                    stats["nginx_hata_adi_eslesti"] += 1
    rep = {"seed": a.seed, "count": a.count, "stats": dict(stats), "ihlal_kabul_ve_guvensiz": len(viol),
           "ihlal_sinif": dict(by_class), "kabul_nginx_ret_bilgi": len(nxrej_accept),
           "lexdiff_sayi": len(lexdiff), "dokum_farkli": consist}
    json.dump(rep, open(os.path.join(work, "rapor.json"), "w"), indent=1, ensure_ascii=False)
    with open(os.path.join(work, "ihlaller.txt"), "w") as fh:
        for n, u, s in viol:
            fh.write("== %s [%s]\n%s\n--\n%s\n" % (n, s, "; ".join("%s:%s" % x for x in u),
                                                    open(os.path.join(cases, n), "rb").read().decode("latin-1")))
    with open(os.path.join(work, "lexdiff.txt"), "w") as fh:
        for n, d in lexdiff:
            fh.write("%s: %s\n" % (n, d))
    with open(os.path.join(work, "kabul_nginx_ret.txt"), "w") as fh:
        for n, e in nxrej_accept:
            fh.write("%s: %s\n" % (n, e))
    print(json.dumps(rep, indent=1, ensure_ascii=False))
    if a.keep_bad:
        os.makedirs(a.keep_bad, exist_ok=True)
        for n, u, s in viol:
            open(os.path.join(a.keep_bad, "%d-%s" % (a.seed, n)), "wb").write(open(os.path.join(cases, n), "rb").read())
    return 1 if viol else 0


if __name__ == "__main__":
    sys.exit(main())
