#!/usr/bin/env python3
"""lib/nginx_allow.sh için hedefli mutasyon testi (R6). YALNIZ KOPYALARDA çalışır.

Her mutant:  <mut-dizini>/<id>/nginx_allow.sh (orijinalin kopyası + TEK değişiklik)
  1) birim testi   : SRVCTL_NGXALLOW_LIB=<kopya> bash tests/test_nginx_allowlist.sh
  2) (yaşarsa) fuzz: run.py --lib <kopya> (aynı tohum) → kabul∧güvensiz ya da lexer farkı
  3) konumsal geri alma: kopyada [ofset, ofset+len(yeni)) yeni ile eşleşmeli; eski metin geri yazılır;
     md5 orijinalle EŞİT olmalı (yoksa HATA)
Orijinal dosyaya YAZILMAZ (yalnız okunur; md5 başta/sonda doğrulanır).
Kullanım: mutate.py <mut-dizini> [--fuzz-count N] [--seed S] [--only id,id]
"""
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
LIB = os.path.join(REPO, "lib", "nginx_allow.sh")

# (id, sınıf, açıklama, eski, yeni[, n-inci geçiş (0 tabanlı)])
M = [
 ("M01", "kapali-kume-genislet", "kapalı değişken kümesine $document_root/$upstream_addr ekle",
  "request_uri|scheme|host|server_name|args|is_args|query_string|request_method|remote_addr|http_host|http_user_agent|http_referer)",
  "request_uri|scheme|host|server_name|args|is_args|query_string|request_method|remote_addr|http_host|http_user_agent|http_referer|document_root|upstream_addr)"),
 ("M02", "kisit-gevsetme", "client_max_body_size 0'a izin ver",
  '[[ ! "$1" =~ ^[1-9][0-9]{0,5}[kKmMgG]?$ ]]', '[[ ! "$1" =~ ^[0-9][0-9]{0,5}[kKmMgG]?$ ]]'),
 ("M03", "uri-yasagi-kaldir", "$uri çıkış kanalı yasağını kaldır",
  'uri)\n                if [[ "$mode" == "out" ]]; then', 'uri)\n                if [[ "$mode" == "outx" ]]; then'),
 ("M04", "kucuk-harf-cikar", "değişken adı küçük harf dönüşümünü çıkar",
  '_ngxallow_lc "$name"; lcn="$_NGXALLOW_LC"', 'lcn="$name"'),
 ("M05", "kucuk-harf-cikar", "G0 yasak dizgi taramasında küçük harf dönüşümünü çıkar",
  '_ngxallow_lc "$all"; all="${_NGXALLOW_LC//\\\\/}"', 'all="${all//\\\\/}"'),
 ("M06", "kacis-soyma-cikar", "G0 taramasında ters bölü soymayı çıkar",
  'all="${_NGXALLOW_LC//\\\\/}"', 'all="${_NGXALLOW_LC}"'),
 ("M07", "rezerve-ad", "set hedefi u_ önekini zorunlu kılma",
  '[[ ! "$1" =~ ^\\$u_[a-z0-9_]{1,30}$ ]]', '[[ ! "$1" =~ ^\\$[a-z0-9_]{1,30}$ ]]'),
 ("M08", "boyut-tavani", "32 KiB tavanını 128 KiB yap",
  "_NGXALLOW_MAX_BYTES=32768", "_NGXALLOW_MAX_BYTES=131072"),
 ("M09", "baglam-yigini", "location'ı if içinde de kabul et",
  '_ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: location yalnız',
  '_ngxallow_ctx_ok SLIJX; then _ngxallow_fail "$line" "$dir" "baglam: location yalnız'),
 ("M10", "varsayilan-ret", "tanınmayan direktifi kabul et (varsayılan-ret kalksın)",
  '''_ngxallow_fail "$line" "$dir" "tanınmayan-direktif: '$dir' izin listesinde yok (varsayılan-ret)"''', ':'),
 ("M11", "kesin-ret-liste", "kesin-ret'ten *_pass sınıfını çıkar (varsayılan-ret yakalar → sınıf testi)",
  "        *_pass|proxy_*|fastcgi_*", "        proxy_*|fastcgi_*"),
 ("M12", "kesin-ret-liste", "kesin-ret'ten include çıkar",
  "auth_request*|auth_basic*|include|root|", "auth_request*|auth_basic*|root|"),
 ("M13", "cikis-kanali", "add_header değerini iflhs kipinde denetle ($uri serbest)",
  '''"arguman: üçüncü argüman yalnız 'always'"; return 0; fi\n        if ! _ngxallow_vars "$2" out;''',
  '''"arguman: üçüncü argüman yalnız 'always'"; return 0; fi\n        if ! _ngxallow_vars "$2" iflhs;'''),
 ("M14", "cikis-kanali", "return 2. argümanını iflhs kipinde denetle",
  '''"arguman: return kodu 200-599"; return 0; fi\n            if ! _ngxallow_vars "$2" out;''',
  '''"arguman: return kodu 200-599"; return 0; fi\n            if ! _ngxallow_vars "$2" iflhs;'''),
 ("M15", "regex-tavan", "regex uzunluk tavanını 200 → 2000",
  "if (( n > 200 )); then", "if (( n > 2000 )); then"),
 ("M16", "regex-ic-ice", "iç içe nicelik reddini etkisizleştir",
  'if [[ "$gflag" == "1" ]]; then\n                            _NGXALLOW_WHY="regex: iç içe', 'if [[ "$gflag" == "9" ]]; then\n                            _NGXALLOW_WHY="regex: iç içe'),
 ("M17", "regex-yasak-yol", "FM yolu örnek eşleşmesi reddini etkisizleştir",
  "if (( rc == 0 )); then", "if (( rc == 99 )); then"),
 ("M18", "regex-ci", "~* için küçük harfe indirgemeyi kapat",
  'if [[ "$ci" == "1" ]]; then', 'if [[ "$ci" == "9" ]]; then'),
 ("M19", "kapali-zone", "limit_conn zone kısıtını kaldır",
  '[[ "$1" != "conn_per_ip" ||', '[[ false ||'),
 ("M20", "lexer-failclosed", "lexer hatalarını (rc≤5) kabul say",
  "if (( prc != 0 )); then", "if (( prc > 5 )); then"),
 ("M21", "sembolik-bag", "sembolik bağ reddini kaldır",
  'if [[ -L "$file" ]]; then', 'if false; then'),
 ("M22", "rezerve-dosya-adi", "'fm' içeren dosya adı rezervini kaldır",
  "*srvctl*|*fm*) return 0 ;;", "*srvctl*) return 0 ;;"),
 ("M23a", "bulasik-izleme", "location adlı yakalamayı bulaşık işaretleme",
  '_NGXALLOW_DEFINED+="$t "; _NGXALLOW_TAINT+="$t "', '_NGXALLOW_DEFINED+="$t "', 0),
 ("M23b", "bulasik-izleme", "if regex adlı yakalamayı bulaşık işaretleme",
  '_NGXALLOW_DEFINED+="$t "; _NGXALLOW_TAINT+="$t "', '_NGXALLOW_DEFINED+="$t "', 1),
 ("M23c", "bulasik-izleme", "rewrite regex adlı yakalamayı bulaşık işaretleme",
  '_NGXALLOW_DEFINED+="$t "; _NGXALLOW_TAINT+="$t "', '_NGXALLOW_DEFINED+="$t "', 2),
 ("M24", "durum-sifirla", "taramalar arası DEFINED/TAINT sıfırlamayı kaldır",
  '_NGXALLOW_OUT=""; _NGXALLOW_DEFINED=" "; _NGXALLOW_TAINT=" "; _NGXALLOW_NSTMT=0', '_NGXALLOW_OUT=""; _NGXALLOW_NSTMT=0'),
 ("M25", "kontrol-karakter", "argümanlarda LF'ye izin ver",
  'if [[ -n "$t" && "$t" == *[!\\ -~]* ]]; then', "if [[ -n \"$t\" && \"$t\" == *[!\\ -~$'\\n']* ]]; then"),
 ("M26", "derinlik-tavani", "blok derinliği tavanı 4 → 400",
  "if (( nst > 4 )); then", "if (( nst > 400 )); then"),
 ("M27", "g0-dizgi-listesi", "G0 listesinden *srvctl* çıkar",
  "*@srvctl*|*srvctl*|*fm-auth*)", "*@srvctl*|*fm-auth*)"),
 ("M28", "rewrite-yol", "rewrite YERİNE '..' reddini kaldır",
  '''|| "$2" == *..* ]]; then\n                _ngxallow_fail "$line" "$dir" "arguman: rewrite last''', ''']]; then\n                _ngxallow_fail "$line" "$dir" "arguman: rewrite last'''),
 ("M29", "access-log", "access_log yalnız 'off' kısıtını kaldır",
  '[[ "$1" != "off" ]]; then _ngxallow_fail "$line" "$dir" "arguman: access_log', 'false; then _ngxallow_fail "$line" "$dir" "arguman: access_log'),
 ("M30", "baslik-adi", "add_header ad regex'ini gevşet",
  '[[ ! "$1" =~ ^[A-Za-z][A-Za-z0-9-]{0,63}$ ]]; then _ngxallow_fail "$line" "$dir" "arguman: başlık adı', '[[ ! "$1" =~ ^.+$ ]]; then _ngxallow_fail "$line" "$dir" "arguman: başlık adı'),
 ("M31", "adres", "IPv4 sekizli > 255 denetimini gevşet",
  "if (( 10#$oct > 255 )); then return 1; fi", "if (( 10#$oct > 2550 )); then return 1; fi"),
 ("M32", "burst", "burst regex'ini gevşet (0 ve sınırsız hane)",
  "^burst=[1-9][0-9]{0,4}$", "^burst=[0-9]+$"),
 ("M33", "if-kosul", "if işlenen sayısı denetimini gevşet (dosya testi biçimleri)",
  "if (( nib != 1 && nib != 3 )); then", "if (( nib < 1 )); then"),
 ("M34", "regex-yol-ornekleri", "rakam kuyruğu uzunluklarını 1'e indir (uzun sayısal kuyruk örnekleri kalkar)",
  "    for len in 1 2 3 4 5 8 12 20; do", "    for len in 1; do"),
 ("M35", "g0-dizgi-listesi", "G0 listesinden *upstream_http* çıkar (kapalı küme yakalar → sınıf testi)",
  "*x-accel*|*upstream_http*|", "*x-accel*|"),
 ("M36", "arguman-sayisi", "argüman sayısı tavanı 16 → 160",
  "if (( nargs > 16 )); then", "if (( nargs > 160 )); then"),
 ("M37", "try-files", "try_files $uri/ biçimine ek kalıp (herhangi bir sözcük)",
  "if [[ \"$t\" == '$uri' || \"$t\" == '$uri/' ]]; then continue; fi", "if [[ \"$t\" == '$uri'* ]]; then continue; fi"),
 ("M38", "regex-alt-cizgi", "regex '_' komşuluk kuralını kaldır",
  "if [[ ! \"$prev\" =~ ^[A-Za-z0-9]$ || ! \"$nx\" =~ ^[A-Za-z0-9]$ ]]; then", "if false; then"),
 ("M39", "regex-tek-sinif", "tek karakterlik sınıf (gizleme) reddini kaldır",
  'if [[ "$nm" =~ $re_one ]]; then', 'if false; then'),
 ("M40", "dir-ascii", "direktif adında ASCII dışı bayt denetimini kaldır",
  'if [[ "$dir" == *[!\\ -~]* ]]; then', 'if false; then'),
 ("M41", "regex-tembel", "tembel (lazy) nicelik '?' atlamayı kaldır (ERE derlenemez → fail-closed yanlış-ret)",
  'if [[ "$plq" != "1" ]]; then\n                    ere+="?"', 'if true; then\n                    ere+="?"'),
 ("M42", "regex-kacis-tasinabilirlik", "ERE özel olmayan kaçışları düz yazma (glibc taşınabilirliği)",
  '                        *) ere+="$nx" ;;', '                        *) ere+="\\$nx" ;;'),
 ("M43", "baglam-J", "add_header server düzeyi if içinde de kabul",
  '_ngxallow_ctx_ok SLI; then _ngxallow_fail "$line" "$dir" "baglam: add_header', '_ngxallow_ctx_ok SLIJ; then _ngxallow_fail "$line" "$dir" "baglam: add_header'),
 ("M44", "baglam-J", "server düzeyi if'i location içi if say",
  'letter="J"\n', 'letter="I"\n'),
 ("M45", "regex-ci-if", "if ~* için küçük harfe indirgemeyi kapat",
  "== *'~*' ]]", "== *'~9' ]]"),
 ("M46", "cikis-kanali", "set değerini iflhs kipinde denetle ($uri/yakalama laundering)",
  'if ! _ngxallow_vars "$2" out; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi\n        _NGXALLOW_DEFINED+="${1#\\$} "',
  'if ! _ngxallow_vars "$2" iflhs; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi\n        _NGXALLOW_DEFINED+="${1#\\$} "'),
 ("M47", "adli-yakalama-ofset", "adlı yakalama ofsetini ezilmiş BASH_REMATCH ile hesapla (fuzz F1 hatası)",
  "i=$((i + 2 + mlen))", "i=$((i + 2 + ${#nm}))"),
 ("M48", "regex-opsiyonel-nicelik", "grup içi '?' nicelik sayılmasın (fuzz F2 hatası)",
  "if (( depth > 0 )); then fl[depth-1]=1; fi\n                fi\n                prev=\"#\"", "true\n                fi\n                prev=\"#\""),
 ("M49", "adli-yakalama-tekrar", "aynı desende yinelenen adlı yakalama reddini kaldır",
  'if [[ "$_NGXALLOW_RX_NAMES " == *" $nm "* ]]; then', 'if false; then'),
 ("M50", "regex-yol-ornekleri", "/_fm/up/ ve /_fm/dl/ kök örneklerini çıkar",
  "/_fm/${nl}/_fm/up/${nl}/_fm/dl/${nl}", "/_fm/${nl}"),
 ("M51", "regex-grep-hata", "grep rc≥2 (desen derlenemedi) dalını kabul et",
  "elif (( rc >= 2 )); then", "elif (( rc >= 20 )); then"),
 ("M52", "regex-ereye-ci", "ci kipinde ERE'yi küçük harfe çevirmeden probla",
  'if [[ "$ci" == "1" ]]; then _ngxallow_lc "$ere"; ere="$_NGXALLOW_LC"; fi', ':'),
]


def md5(b):
    return hashlib.md5(b).hexdigest()


def run(cmd, env, timeout=900):
    p = subprocess.run(cmd, env=env, capture_output=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")


def main():
    mdir = os.path.abspath(sys.argv[1])
    fuzz_count = int(sys.argv[sys.argv.index("--fuzz-count") + 1]) if "--fuzz-count" in sys.argv else 3000
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 20261024
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    orig = open(LIB, "rb").read()
    orig_md5 = md5(orig)
    print("orijinal md5 (başta): %s" % orig_md5)
    os.makedirs(mdir, exist_ok=True)
    rows = []
    for ent in M:
        mid, cls, desc, old, new = ent[:5]
        nth = ent[5] if len(ent) > 5 else None
        if only and mid not in only:
            continue
        ob, nb = old.encode(), new.encode()
        cnt = orig.count(ob)
        if nth is None and cnt != 1:
            print("%s: HATA — eski metin %d kez geçiyor (1 olmalı)" % (mid, cnt)); rows.append((mid, cls, desc, "HATA-konum", "", "")); continue
        if nth is not None and cnt <= nth:
            print("%s: HATA — eski metin %d kez geçiyor, n=%d" % (mid, cnt, nth)); rows.append((mid, cls, desc, "HATA-konum", "", "")); continue
        off = -1
        for _ in range((nth or 0) + 1):
            off = orig.find(ob, off + 1)
        d = os.path.join(mdir, mid)
        os.makedirs(d, exist_ok=True)
        mut = orig[:off] + nb + orig[off + len(ob):]
        mp = os.path.join(d, "nginx_allow.sh")
        open(mp, "wb").write(mut)
        sx, _ = run(["/bin/bash", "-n", mp], os.environ)
        env = dict(os.environ)
        env["SRVCTL_NGXALLOW_LIB"] = mp
        rc, out = run(["/bin/bash", os.path.join(REPO, "tests", "test_nginx_allowlist.sh")], env)
        open(os.path.join(d, "unit.out"), "w").write(out)
        m = re.search(r"Toplam: (\d+), Başarısız: (\d+)", out)
        fails = int(m.group(2)) if m else 9999
        res_unit = "ÖLDÜ(birim:%d)" % fails if (rc != 0 or fails) else "yaşadı"
        res_fuzz = ""
        if res_unit == "yaşadı":
            wd = os.path.join(d, "fuzz")
            subprocess.run(["rm", "-rf", wd])
            rc2, out2 = run([sys.executable, os.path.join(HERE, "run.py"), "--count", str(fuzz_count), "--seed", str(seed),
                             "--work", wd, "--lib", mp], os.environ)
            open(os.path.join(d, "fuzz.out"), "w").write(out2)
            m = re.search(r'"ihlal_kabul_ve_guvensiz": (\d+)', out2)
            viol = int(m.group(1)) if m else -1
            lx = re.search(r'"lexer_FARKLI": (\d+)', out2)
            res_fuzz = "ÖLDÜ(fuzz: kabul∧güvensiz=%d)" % viol if viol > 0 else ("YAŞADI(fuzz)" if viol == 0 else "fuzz-HATA")
        # konumsal geri alma
        cur = open(mp, "rb").read()
        okpos = cur[off:off + len(nb)] == nb
        restored = cur[:off] + ob + cur[off + len(nb):]
        eq = md5(restored) == orig_md5
        open(os.path.join(d, "restored.md5"), "w").write("%s  %s (orijinal %s) %s\n" % (md5(restored), mid, orig_md5, "ESIT" if eq else "FARKLI"))
        rows.append((mid, cls, desc, res_unit, res_fuzz, "ESIT" if (eq and okpos) else "HATA"))
        print("%-5s %-22s %-14s %-34s md5:%s  | %s" % (mid, cls, res_unit, res_fuzz, "ESIT" if (eq and okpos) else "HATA", desc))
        sys.stdout.flush()
    end_md5 = md5(open(LIB, "rb").read())
    print("orijinal md5 (sonda): %s  %s" % (end_md5, "ESIT" if end_md5 == orig_md5 else "FARKLI!"))
    with open(os.path.join(mdir, "TABLO.tsv"), "w") as fh:
        for r in rows:
            fh.write("\t".join(r) + "\n")


if __name__ == "__main__":
    main()
