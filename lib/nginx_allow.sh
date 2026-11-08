#!/bin/bash
# srvctl — custom.d KULLANICI dosyaları için VARSAYILAN-RET nginx izin listesi
#
# Yasak listesi (kara liste) yaklaşımının yerine geçer: dosyadaki HER direktif
# açıkça tanınıp kısıtlara uymak zorundadır; tanınmayan her şey reddedilir.
# Sözcük çözümleme _domconf_nginx_parse'ındır (lib/domconf.sh; ngx_conf_read_token
# birebir) — burada yalnız onun GERİ ÇAĞRISI vardır.
#
# Arayüz:
#   _ngxallow_scan <dosya> <domain> [<mantıksal-dosya-adı>]
#     stdout : bulgu satırları  satır:direktif:gerekçe   (gerekçe "sınıf: açıklama")
#     rc 0   : temiz
#     rc 1   : ihlal (izin listesi dışı)
#     rc 2   : çözümlenemedi / okunamadı / boyut tavanı (bayt ya da ifade sayısı) / lexer yapı hatası
#              (FAIL-CLOSED: çağıranlar 0 dışındaki HER dönüşü "reddedildi" sayar)
#   <mantıksal-dosya-adı>: dosya aday/geçici bir yoldaysa HEDEF adı (rezerve ad
#   denetimi için); verilmezse dosyanın kendi adı.
#
# Gerekçe sınıfları: lexer, boyut, kesin-ret, tanınmayan-direktif, yasak-dizgi,
#   degisken, baglam, arguman, regex, rezerve-ad, sembolik-bag.
#
# Gerekçeler (D3 + v2): gerekçe sınıfları yukarıda; her sınıfın vakaları tests/test_nginx_allowlist.sh.
# bash 3.2 uyumlu: declare -A, ${x,,}, mapfile YOK; boş dizi set -u korumalı;
# set -e altında da güvenli (if / || true ile).

_NGXALLOW_MAX_BYTES=32768
# Tarama süresi tavanları (seca-L1): ifade (direktif/blok başlığı) sayısı, {n,m} nicelik sınırı
# (POSIX RE_DUP_MAX; BSD grep zaten >255'i derlemez, GNU grep {0,m}'yi karesel açar: tek
# `[0-9]{1,32767}` 26,8 s), FM yolu sondasının red yolundaki ayrıştırma grep bütçesi.
_NGXALLOW_MAX_STMT=2048
_NGXALLOW_RX_DUP_MAX=255
_NGXALLOW_PROBE_ID_MAX=64
_NGXALLOW_CAPPED=0
_NGXALLOW_CUR_LINE=0
_NGXALLOW_CUR_DIR=""
_NGXALLOW_OUT=""
_NGXALLOW_DEFINED=" "
_NGXALLOW_TAINT=" "
_NGXALLOW_LC=""
_NGXALLOW_WHY=""
_NGXALLOW_RX_NAMES=""
_NGXALLOW_PROBES=""
_NGXALLOW_NSTMT=0

# ── küçük harfe çevirme (saf bash; fork yok) ─────────────────
_ngxallow_lc() {
    local s="$1"
    s=${s//A/a}; s=${s//B/b}; s=${s//C/c}; s=${s//D/d}; s=${s//E/e}
    s=${s//F/f}; s=${s//G/g}; s=${s//H/h}; s=${s//I/i}; s=${s//J/j}
    s=${s//K/k}; s=${s//L/l}; s=${s//M/m}; s=${s//N/n}; s=${s//O/o}
    s=${s//P/p}; s=${s//Q/q}; s=${s//R/r}; s=${s//S/s}; s=${s//T/t}
    s=${s//U/u}; s=${s//V/v}; s=${s//W/w}; s=${s//X/x}; s=${s//Y/y}
    s=${s//Z/z}
    _NGXALLOW_LC="$s"
}

_ngxallow_fail() {
    # $1=satır $2=direktif $3=gerekçe (sınıf: açıklama)
    local d="${2//$'\n'/ }" w="${3//$'\n'/ }"
    _NGXALLOW_OUT+="${1}:${d}:${w}"$'\n'
}

# ── kapalı değişken kümesi ───────────────────────────────────
# $1 = belirteç (içinde $ başvuruları olabilir)  $2 = kip:
#   out   : çıkış kanalı / set değeri — $uri, $1..$9 ve bulaşık (yakalama) değişkenler YASAK
#   iflhs : if sol işleneni — $uri/$1..$9/bulaşık serbest
#   none  : hiçbir değişken yok
# rc 0 uygun; rc 1 → _NGXALLOW_WHY dolu.
_ngxallow_vars() {
    local rest="$1" mode="$2" name lcn
    _NGXALLOW_WHY=""
    if [[ "$rest" != *'$'* ]]; then
        return 0
    fi
    if [[ "$mode" == "none" ]]; then
        _NGXALLOW_WHY="degisken: bu argümanda değişken başvurusu yasak"
        return 1
    fi
    while [[ "$rest" == *'$'* ]]; do
        rest="${rest#*\$}"
        if [[ "$rest" == '{'* ]]; then
            _NGXALLOW_WHY="degisken: \${…} biçimi yasak"
            return 1
        fi
        if [[ "$rest" =~ ^([A-Za-z0-9_]+) ]]; then
            name="${BASH_REMATCH[1]}"
        else
            _NGXALLOW_WHY="degisken: geçersiz değişken adı"
            return 1
        fi
        rest="${rest#"$name"}"
        _ngxallow_lc "$name"; lcn="$_NGXALLOW_LC"
        if [[ "$lcn" =~ ^[0-9]+$ ]]; then
            if [[ ! "$lcn" =~ ^[1-9]$ ]]; then
                _NGXALLOW_WHY="degisken: \$$name yakalama değişkeni aralığı dışı"
                return 1
            fi
            if [[ "$mode" == "out" ]]; then
                _NGXALLOW_WHY="degisken: \$$name (yakalama) çıkış kanalında yasak (CRLF)"
                return 1
            fi
            continue
        fi
        case "$lcn" in
            uri)
                if [[ "$mode" == "out" ]]; then
                    _NGXALLOW_WHY="degisken: \$uri çıkış kanalında yasak (CRLF)"
                    return 1
                fi
                ;;
            request_uri|scheme|host|server_name|args|is_args|query_string|request_method|remote_addr|http_host|http_user_agent|http_referer)
                ;;
            *)
                if [[ "$lcn" =~ ^arg_[a-z0-9_]+$ ]]; then
                    :
                elif [[ "$lcn" =~ ^u_[a-z0-9_]{1,30}$ ]]; then
                    if [[ "$_NGXALLOW_DEFINED" != *" $lcn "* ]]; then
                        _NGXALLOW_WHY="degisken: \$$name daha önce set ile tanımlanmamış"
                        return 1
                    fi
                    if [[ "$mode" == "out" && "$_NGXALLOW_TAINT" == *" $lcn "* ]]; then
                        _NGXALLOW_WHY="degisken: \$$name (yakalama kaynaklı) çıkış kanalında yasak (CRLF)"
                        return 1
                    fi
                else
                    _NGXALLOW_WHY="degisken: \$$name kapalı küme dışında"
                    return 1
                fi
                ;;
        esac
    done
    return 0
}

# ── FM yolu örnek kümesi (bir kez üretilir; satır başına bir yol) ──
# /_fm/<c>, /_fm/<ccc>, /_fm/<c>/<c>, /_fm/up/<c>…, /_fm/dl/<c> (c = harf/rakam), farklı uzunlukta rakam kuyrukları
_ngxallow_build_probes() {
    local ch len d1 d2 nl=$'\n'
    _NGXALLOW_PROBES="/_fm/${nl}/_fm/up/${nl}/_fm/dl/${nl}/_fm/up/1/2${nl}/_fm/up/12/345${nl}/_fm/x${nl}/__fm_auth${nl}/__fm_dl${nl}/_FM/up/1/2${nl}/__FM_AUTH${nl}/_fm/up/1/2?a=1"
    for len in 1 2 3 4 5 8 12 20; do
        d1=""; d2=""
        while (( ${#d1} < len )); do d1+="1"; d2+="9"; done
        _NGXALLOW_PROBES+="${nl}/_fm/up/${d1}/${d2}${nl}/_fm/up/${d2}/${d1}"
    done
    for ch in a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; do
        _NGXALLOW_PROBES+="${nl}/_fm/${ch}${nl}/_fm/${ch}${ch}${ch}${nl}/_fm/${ch}/${ch}${nl}/_fm/up/${ch}${nl}/_fm/up/${ch}${ch}${ch}${nl}/_fm/up/${ch}/${ch}${nl}/_fm/dl/${ch}${nl}/_fm/up${ch}${nl}/_fm/dl${ch}${nl}/_fm/${ch}${ch}${nl}/_fm/${ch}${ch}${ch}${ch}${nl}/_fm/${ch}.${ch}"
    done
    for ch in upload download zip list tree rename delete mkdir stat token auth; do
        _NGXALLOW_PROBES+="${nl}/_fm/${ch}${nl}/_fm/${ch}/"
    done
}
_ngxallow_build_probes

# ── regex doğrulama ──────────────────────────────────────────
# $1 = desen. rc 0 uygun; rc 1 → _NGXALLOW_WHY dolu. Adlı yakalamalar
# _NGXALLOW_RX_NAMES'e (boşluk ayraçlı) yazılır.
#  - uzunluk tavanı 200; PCRE kod/rekürsiyon/koşul/lookaround/bayrak yapıları yok
#  - iç içe / alternasyonlu nicelik sezgisi (ReDoS) ve en çok 3 sınırsız nicelik. SAYIM
#    KASITLI OLARAK belgelenen "3"ten KATIDIR: grup niceliği `)+`/`)*` İKİ sınırsız nicelik
#    sayılır (kapanış parantezi bir + niceleyici simgesi bir); `){n,}` BİR sayılır, `){n}` sınırlıdır
#    (README 'izin listesi' bölümü + tests/test_nginx_allowlist.sh grup niceliği vakaları kilitli). Gevşetme = bilinçli karar.
#  - {n,m} değerleri en çok _NGXALLOW_RX_DUP_MAX (255) ve n <= m
#  - `_` yalnız iki yanında harf/rakam olan düz karakter olarak; \x \u \N … yok;
#    `_f` dizgisi yasak (ardışık gizleme)
#  - desen ERE'ye çevrilip YASAK YOL ÖRNEKLERİNE (/_fm/…, /__fm_auth …)
#    eşleşiyorsa ret (`.fm`, `..m`, `[^a]fm`, `up/` sınıfı kaçamaklar). Sonda ERE'sinde
#    X{n,m} → X{min(n,8),} yazılır: eşleşme kümesinin ÜST kümesi (sonda yalnız DAHA ÇOK
#    reddedebilir, hiçbir eşleşmeyi kaçırmaz) ve GNU grep'in {0,m} açılımındaki karesel
#    derleme maliyeti doğmaz.
#  - _ngxallow_scan içinde (_NGXALLOW_DEFER=1) sonda ertelenir: ERE kuyruğa yazılır, tarama
#    sonunda _ngxallow_probe_flush TEK grep ile çözer (direktif başına fork YOK; seca-L1).
#    Doğrudan çağrıda (kuyruk yok) sonda burada, eskisi gibi yapılır.
_ngxallow_regex_ok() {
    local p="$1" ci="${2-0}" n i c nx j
    local -a fl=()
    local depth=0 unb=0 gflag lastq=0 plq=0 mlen=0 qn qm
    local re_ncap='^(P?)[<]([A-Za-z0-9_]+)[>]' re_quant='^[{][0-9]{1,5}(,[0-9]{0,5})?[}]' re_one='^[[][^^][]]$'
    _NGXALLOW_WHY=""
    _NGXALLOW_RX_NAMES=""
    n=${#p}
    if (( n == 0 )); then
        _NGXALLOW_WHY="regex: boş desen"; return 1
    fi
    if (( n > 200 )); then
        _NGXALLOW_WHY="regex: uzunluk tavanı (200) aşıldı"; return 1
    fi
    local ere="" prev="" nm
    i=0
    while (( i < n )); do
        c="${p:i:1}"
        plq="$lastq"; lastq=0
        case "$c" in
            '\')
                nx="${p:i+1:1}"
                if [[ -z "$nx" ]]; then
                    _NGXALLOW_WHY="regex: sonda yalın ters bölü"; return 1
                fi
                if [[ "$nx" =~ ^[A-Za-z0-9]$ ]]; then
                    case "$nx" in
                        d) ere+='[0-9]' ;;
                        w) ere+='[A-Za-z0-9_]' ;;
                        s) ere+='[[:space:]]' ;;
                        *)
                            _NGXALLOW_WHY="regex: desteklenmeyen kaçış \\$nx"; return 1 ;;
                    esac
                else
                    # ERE özel karakterleri kaçışlı kalır; diğerleri düz (glibc/BSD taşınabilirliği)
                    case "$nx" in
                        [.\[\]\\\(\)\{\}\*\+\?\|\^\$]) ere+="\\$nx" ;;
                        *) ere+="$nx" ;;
                    esac
                fi
                prev="#"
                i=$((i + 2))
                continue
                ;;
            '[')
                # karakter sınıfı: kapanışa kadar atla
                j=$((i + 1))
                if [[ "${p:j:1}" == '^' ]]; then j=$((j + 1)); fi
                if [[ "${p:j:1}" == ']' ]]; then j=$((j + 1)); fi
                while (( j < n )) && [[ "${p:j:1}" != ']' ]]; do
                    if [[ "${p:j:1}" == '\' ]]; then
                        _NGXALLOW_WHY="regex: karakter sınıfında kaçış yasak"; return 1
                    fi
                    if [[ "${p:j:1}" == '[' ]]; then
                        _NGXALLOW_WHY="regex: iç içe/POSIX karakter sınıfı yasak"; return 1
                    fi
                    j=$((j + 1))
                done
                if (( j >= n )); then
                    _NGXALLOW_WHY="regex: kapanmamış karakter sınıfı"; return 1
                fi
                nm="${p:i:j-i+1}"
                if [[ "$nm" == *_* ]]; then
                    _NGXALLOW_WHY="regex: sınıf içinde '_' yasak"; return 1
                fi
                if [[ "$nm" =~ $re_one ]]; then
                    _NGXALLOW_WHY="regex: tek karakterlik sınıf (gizleme) yasak"; return 1
                fi
                ere+="$nm"
                prev="#"
                i=$((j + 1))
                # sınıfa uygulanan nicelik
                continue
                ;;
            '(')
                if [[ "${p:i+1:1}" == '*' ]]; then
                    _NGXALLOW_WHY="regex: PCRE fiil yapısı (*…) yasak"; return 1
                fi
                if [[ "${p:i+1:1}" == '?' ]]; then
                    if [[ "${p:i+2:1}" == ':' ]]; then
                        ere+='('; i=$((i + 3))
                    elif [[ "${p:i+2}" =~ $re_ncap ]]; then
                        # BASH_REMATCH sonraki =~ ile ezilir: uzunluğu HEMEN al (ezilmiş uzunluk ayrıştırmayı yanlış ilerletir)
                        mlen=${#BASH_REMATCH[0]}
                        nm="${BASH_REMATCH[2]}"
                        if [[ ! "$nm" =~ ^u_[a-z0-9_]{1,30}$ ]]; then
                            _NGXALLOW_WHY="regex: adlı yakalama adı u_[a-z0-9_] olmalı ($nm)"; return 1
                        fi
                        if [[ "$_NGXALLOW_RX_NAMES " == *" $nm "* ]]; then
                            _NGXALLOW_WHY="regex: aynı adlı yakalama bir desende iki kez ($nm)"; return 1
                        fi
                        _NGXALLOW_RX_NAMES+=" $nm"
                        ere+='('
                        i=$((i + 2 + mlen))
                    else
                        _NGXALLOW_WHY="regex: desteklenmeyen (? yapısı"; return 1
                    fi
                else
                    ere+='('; i=$((i + 1))
                fi
                fl[depth]=0
                depth=$((depth + 1))
                if (( depth > 8 )); then
                    _NGXALLOW_WHY="regex: grup derinliği tavanı"; return 1
                fi
                prev="("
                continue
                ;;
            ')')
                if (( depth == 0 )); then
                    _NGXALLOW_WHY="regex: eşleşmeyen ')'"; return 1
                fi
                depth=$((depth - 1))
                gflag="${fl[depth]}"
                ere+=')'
                nx="${p:i+1:1}"
                case "$nx" in
                    '*'|'+'|'{')
                        if [[ "$gflag" == "1" ]]; then
                            _NGXALLOW_WHY="regex: iç içe/alternasyonlu nicelik (ReDoS)"; return 1
                        fi
                        if (( depth > 0 )); then fl[depth-1]=1; fi
                        if [[ "$nx" != '{' ]]; then unb=$((unb + 1)); fi
                        ;;
                    *)
                        if [[ "$gflag" == "1" && depth -gt 0 ]]; then fl[depth-1]=1; fi
                        ;;
                esac
                prev="#"
                i=$((i + 1))
                continue
                ;;
            '|')
                if (( depth > 0 )); then fl[depth-1]=1; fi
                ere+='|'; prev="|"
                ;;
            '*'|'+')
                if (( depth > 0 )); then fl[depth-1]=1; fi
                unb=$((unb + 1))
                ere+="$c"; prev="#"; lastq=1
                ;;
            '{')
                if [[ "${p:i}" =~ $re_quant ]]; then
                    nm="${BASH_REMATCH[0]}"
                    qn="${nm#\{}"; qn="${qn%\}}"; qm="$qn"
                    if [[ "$qn" == *,* ]]; then qm="${qn#*,}"; qn="${qn%%,*}"; fi
                    # qm boş = açık uçlu {n,}
                    if (( 10#$qn > _NGXALLOW_RX_DUP_MAX )) || { [[ -n "$qm" ]] && (( 10#$qm > _NGXALLOW_RX_DUP_MAX )); }; then
                        _NGXALLOW_WHY="regex: nicelik sınırı en çok ${_NGXALLOW_RX_DUP_MAX} (POSIX RE_DUP_MAX; büyük sınır doğrulayıcıyı kilitler)"; return 1
                    fi
                    if [[ -n "$qm" ]] && (( 10#$qn > 10#$qm )); then
                        _NGXALLOW_WHY="regex: {n,m} niceliğinde n > m"; return 1
                    fi
                    if (( depth > 0 )); then fl[depth-1]=1; fi
                    if [[ -z "$qm" ]]; then unb=$((unb + 1)); fi
                    # sonda ERE'si: X{n,m} → X{min(n,8),} (üst küme; bkz. işlev başı)
                    if (( 10#$qn < 8 )); then ere+="{$((10#$qn)),}"; else ere+="{8,}"; fi
                    prev="#"; lastq=1
                    i=$((i + ${#nm}))
                    continue
                fi
                _NGXALLOW_WHY="regex: '{' yalnız {n}/{n,m} nicelik olabilir"; return 1
                ;;
            '_')
                nx="${p:i+1:1}"
                if [[ ! "$prev" =~ ^[A-Za-z0-9]$ || ! "$nx" =~ ^[A-Za-z0-9]$ ]]; then
                    _NGXALLOW_WHY="regex: '_' iki yanı harf/rakam olan düz karakter olmalı"; return 1
                fi
                ere+="_"; prev="_"
                ;;
            '?')
                # nicelikten sonraki '?' tembel (lazy) niceliktir: ERE karşılığı yok, eşleşme kümesi aynı
                if [[ "$plq" != "1" ]]; then
                    ere+="?"
                    # (X?){n} / (X?)* sınıfı (ReDoS): grup içindeki isteğe bağlı öğe de nicelik sayılır (üst üste nicelik, üstel geri izleme yaratır)
                    if (( depth > 0 )); then fl[depth-1]=1; fi
                fi
                prev="#"
                ;;
            *)
                ere+="$c"
                prev="$c"
                ;;
        esac
        i=$((i + 1))
    done
    if (( depth != 0 )); then
        _NGXALLOW_WHY="regex: kapanmamış grup"; return 1
    fi
    if (( unb > 3 )); then
        _NGXALLOW_WHY="regex: 4+ sınırsız nicelik (ReDoS sezgisi)"; return 1
    fi
    # '_' kuralının "prev" izi: harf/rakamdan sonra '_' sonra harf/rakam — `_f` yasağı:
    _ngxallow_lc "$p"
    nm="${_NGXALLOW_LC//\\/}"
    case "$nm" in
        *_f*)
            _NGXALLOW_WHY="regex: '_f' dizgisi (FM yolu gizleme) yasak"; return 1 ;;
    esac
    # yasak yol örneklerine eşleşme (ERE'ye çevrilmiş desen); ~* için küçük harfe indirgenir
    local rc
    if [[ "$ci" == "1" ]]; then _ngxallow_lc "$ere"; ere="$_NGXALLOW_LC"; fi
    if [[ "${_NGXALLOW_DEFER:-0}" == "1" ]]; then
        # tarama içinde: sonda tarama sonunda TOPLU (_ngxallow_probe_flush); karar orada verilir
        _ngxallow_probe_defer "$ere"
        return 0
    fi
    # tek grep -E çağrısı (örnek başına =~ döngüsü çok yavaş): 0 eşleşti / 1 eşleşmedi / ≥2 desen hatası
    local hit
    rc=0
    hit=$(LC_ALL=C grep -E -m 1 -e "$ere" <<< "$_NGXALLOW_PROBES" 2>/dev/null) || rc=$?
    if (( rc == 0 )); then
        _NGXALLOW_WHY="regex: srvctl FM yoluna ($hit) eşleşir"; return 1
    elif (( rc >= 2 )); then
        _NGXALLOW_WHY="regex: doğrulayıcı ERE'ye çeviremedi (fail-closed)"; return 1
    fi
    return 0
}

# ── FM yolu sondası: ertelenmiş kuyruk + toplu çözüm (seca-L1) ──
# Kuyruk dizileri _NGXALLOW_PQ_{ERE,LINE,DIR} _ngxallow_scan'ın YERELLERİDİR (dinamik kapsam;
# taramalar arasında sızmaz). Satır/direktif _ngxallow_cb'nin o anki ifadesidir.
_ngxallow_probe_defer() {
    local k=${#_NGXALLOW_PQ_ERE[@]}
    _NGXALLOW_PQ_ERE[k]="$1"
    _NGXALLOW_PQ_LINE[k]="$_NGXALLOW_CUR_LINE"
    _NGXALLOW_PQ_DIR[k]="$_NGXALLOW_CUR_DIR"
}

# Toplu `grep -E -q -e D1 -e D2 …` rc 1 (hiçbir örnek hiçbir desene eşleşmedi VE hepsi derlendi)
# ⇔ desen başına çağrıların HEPSİ rc 1 (grep bir satırı desenlerden BİRİNE eşleşirse seçer;
# derlenemeyen tek desen bütün çağrıyı rc 2 yapar) → KABUL kararı desen başına sondayla AYNIDIR.
# rc 0/≥2 (red yolu): AYRI desenler (ilk görülme sırasıyla; awk yalnız DİZGİ eşitliğine bakar,
# regex motoru değildir) ikiye bölünerek aranır — kötü desen, önündeki temiz desenlerden
# bağımsız olarak ~2·log2(n) grep'te bulunur. Toplam grep bütçesi _NGXALLOW_PROBE_ID_MAX; bitince
# çözülmeyen desenler için TEK toplu bulgu yazılır (dosya zaten REDDEDİLİR). Toplu sonda
# eşleşme/hata bildirip ayrıştırma hiçbir şey bulamazsa da RED (tutarsızlık = fail-closed).
# Bulgular kuyruk sırasıyla, öteki bulguların ARDINA eklenir.
_ngxallow_probe_flush() {
    local np=${#_NGXALLOW_PQ_ERE[@]} k s e r hit brc=0 lo hi mid kb d=0 sp ng=0 nbad=0 unres=0 uk=-1
    (( np > 0 )) || return 0
    local -a ea=() de=() di=() slo=() shi=() skb=() be=() br=() bh=()
    for ((k = 0; k < np; k++)); do
        ea[${#ea[@]}]="-e"; ea[${#ea[@]}]="${_NGXALLOW_PQ_ERE[k]}"
    done
    LC_ALL=C grep -E -q "${ea[@]}" <<< "$_NGXALLOW_PROBES" 2>/dev/null || brc=$?
    if (( brc == 1 )); then return 0; fi
    while IFS=$'\t' read -r k e; do
        de[d]="$e"; di[d]="$k"; d=$((d + 1))
    done < <(printf '%s\n' "${_NGXALLOW_PQ_ERE[@]}" | LC_ALL=C awk '!s[$0]++ { print NR - 1 "\t" $0 }')
    if (( d == 0 )); then
        _ngxallow_fail 0 "-" "regex: toplu FM yolu sondası (rc ${brc}) eşleşme/hata bildirdi; desenler ayrıştırılamadı (fail-closed RED)"
        return 0
    fi
    # yığın: [lo,hi) aralığı + kb (1 = aralığın kötü desen içerdiği ZATEN biliniyor)
    slo[0]=0; shi[0]=$d; skb[0]=1; sp=1
    while (( sp > 0 )); do
        sp=$((sp - 1)); lo=${slo[sp]}; hi=${shi[sp]}; kb=${skb[sp]}
        if (( ng >= _NGXALLOW_PROBE_ID_MAX )); then
            unres=$((unres + hi - lo))
            if (( uk < 0 || ${di[lo]} < uk )); then uk=${di[lo]}; fi
            continue
        fi
        if (( hi - lo == 1 )); then
            ng=$((ng + 1)); r=0
            hit=$(LC_ALL=C grep -E -m 1 -e "${de[lo]}" <<< "$_NGXALLOW_PROBES" 2>/dev/null) || r=$?
            if (( r != 1 )); then
                be[${#be[@]}]="${de[lo]}"; br[${#br[@]}]="$r"; bh[${#bh[@]}]="$hit"
            fi
            continue
        fi
        if (( kb == 0 )); then
            ng=$((ng + 1)); ea=()
            for ((s = lo; s < hi; s++)); do ea[${#ea[@]}]="-e"; ea[${#ea[@]}]="${de[s]}"; done
            r=0; LC_ALL=C grep -E -q "${ea[@]}" <<< "$_NGXALLOW_PROBES" 2>/dev/null || r=$?
            if (( r == 1 )); then continue; fi
        fi
        mid=$(( (lo + hi) / 2 ))
        slo[sp]=$mid; shi[sp]=$hi; skb[sp]=0; sp=$((sp + 1))
        slo[sp]=$lo;  shi[sp]=$mid; skb[sp]=0; sp=$((sp + 1))
    done
    if (( ${#be[@]} > 0 )); then
        for ((k = 0; k < np; k++)); do
            e="${_NGXALLOW_PQ_ERE[k]}"
            for ((s = 0; s < ${#be[@]}; s++)); do
                [[ "${be[s]}" == "$e" ]] || continue
                nbad=$((nbad + 1))
                if [[ "${br[s]}" == "0" ]]; then
                    _ngxallow_fail "${_NGXALLOW_PQ_LINE[k]}" "${_NGXALLOW_PQ_DIR[k]}" "regex: srvctl FM yoluna (${bh[s]}) eşleşir"
                else
                    _ngxallow_fail "${_NGXALLOW_PQ_LINE[k]}" "${_NGXALLOW_PQ_DIR[k]}" "regex: doğrulayıcı ERE'ye çeviremedi (fail-closed)"
                fi
                break
            done
        done
    fi
    if (( unres > 0 )); then
        _ngxallow_fail "${_NGXALLOW_PQ_LINE[uk]}" "${_NGXALLOW_PQ_DIR[uk]}" "regex: FM yolu sondası ayrıştırma bütçesi (${_NGXALLOW_PROBE_ID_MAX} grep) bitti — ${unres} ayrı desen tek tek sınanmadı (bu satırdan başlayarak); toplu sonda eşleşme/hata bildirdi (fail-closed RED)"
    elif (( nbad == 0 )); then
        _ngxallow_fail 0 "-" "regex: toplu FM yolu sondası (rc ${brc}) tek tek sondayla doğrulanamadı (fail-closed RED)"
    fi
}

# ── bağlam ───────────────────────────────────────────────────
# $1 = izinli bağlam harfleri (S server/dosya, L location, I location içi if, J server düzeyi if, X limit_except)
_ngxallow_ctx_ok() {
    local nst="${#_NGX_STACK[@]}" top="" letter
    if (( nst > 0 )); then top="${_NGX_STACK[nst-1]}"; fi
    case "$top" in
        "") letter="S" ;;
        location) letter="L" ;;
        if)
            # server düzeyindeki if (altında location yok) ayrı bağlam: J
            letter="J"
            local k
            for k in "${_NGX_STACK[@]}"; do
                if [[ "$k" == "location" ]]; then letter="I"; fi
            done
            ;;
        limit_except) letter="X" ;;
        *) letter="?" ;;
    esac
    [[ "$1" == *"$letter"* ]]
}

# IPv4/IPv6/CIDR/all (allow/deny)
_ngxallow_addr_ok() {
    local a="$1" ip pre oct
    if [[ "$a" == "all" ]]; then return 0; fi
    ip="${a%%/*}"; pre=""
    if [[ "$a" == */* ]]; then pre="${a#*/}"; fi
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for oct in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            if (( 10#$oct > 255 )); then return 1; fi
        done
        if [[ -n "$pre" ]]; then
            [[ "$pre" =~ ^[0-9]{1,2}$ ]] || return 1
            (( 10#$pre <= 32 )) || return 1
        fi
        return 0
    fi
    if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]{2,39}$ && "$ip" != *:::* ]]; then
        if [[ -n "$pre" ]]; then
            [[ "$pre" =~ ^[0-9]{1,3}$ ]] || return 1
            (( 10#$pre <= 128 )) || return 1
        fi
        return 0
    fi
    return 1
}

# ── ana geri çağrı ───────────────────────────────────────────
# _domconf_nginx_parse çağrısı: <cb> stmt|open <satır> <ad> [argümanlar…]
_ngxallow_cb() {
    local kind="$1" line="$2" dir="$3"
    shift 3
    local nargs=$#
    local dl all t j nst
    _NGXALLOW_CUR_LINE="$line"; _NGXALLOW_CUR_DIR="$dir"

    _ngxallow_lc "$dir"; dl="$_NGXALLOW_LC"

    # ── KESİN RET (açık sınıflar; tanınmayan zaten varsayılan-ret) ──
    case "$dl" in
        *_pass|proxy_*|fastcgi_*|uwsgi_*|scgi_*|grpc_*|memcached_*)
            _ngxallow_fail "$line" "$dir" "kesin-ret: arka uç/proxy sınıfı (*_pass, proxy_*, fastcgi_*, uwsgi_*, scgi_*, grpc_*) kullanıcı dosyasında yasak"; return 0 ;;
        auth_request*|auth_basic*|include|root|alias|server_name|listen|disable_symlinks|modsecurity*|ssl_*|upstream|map|geo|split_clients|stream|mail|events|http|server|types|types_hash_*|error_log|error_page|internal|resolver|mirror|ssi|ssi_*|add_before_body|add_after_body|dav_*|*_store|*_path|*_file|sub_filter*|more_*|add_trailer|load_module|lua_*|*_by_*|js_*|perl*|echo*|xslt*|secure_link*|image_filter*|userid*|satisfy|charset*|default_type|gzip*|etag|autoindex*|server_tokens|limit_rate*|client_body_*|client_header_*|keepalive_*|send_timeout|large_client_header_buffers|set_real_ip_from|real_ip_*|if_modified_since|open_file_cache*|sendfile*|tcp_*|worker_*|user|pid|daemon|env|rewrite_log|log_subrequest|log_format|open_log_file_cache|ancient_browser*|referer_hash_*|valid_referers|random_index|empty_gif|flv|mp4|slice|stub_status|status|hls|fancyindex*|geoip*|vhost_traffic_status*|limit_req_zone|limit_conn_zone|limit_req_status|limit_conn_status|limit_req_log_level|limit_conn_log_level|allow_*|clean_*)
            _ngxallow_fail "$line" "$dir" "kesin-ret: '$dir' kullanıcı dosyasında yasak"; return 0 ;;
    esac

    if [[ "$dir" != "$dl" ]]; then
        _ngxallow_fail "$line" "$dir" "tanınmayan-direktif: direktif adı küçük harf olmalı"; return 0
    fi

    # ── G0: biçimsel denetimler (tüm argümanlar) ──
    if (( nargs > 16 )); then
        _ngxallow_fail "$line" "$dir" "arguman: argüman sayısı tavanı (16) aşıldı"; return 0
    fi
    nst="${#_NGX_STACK[@]}"
    if (( nst > 4 )); then
        _ngxallow_fail "$line" "$dir" "baglam: blok derinliği tavanı (4) aşıldı"; return 0
    fi
    all="$dir"
    if [[ "$dir" == *[!\ -~]* ]]; then
        _ngxallow_fail "$line" "$dir" "arguman: direktif adında kontrol karakteri/ASCII dışı bayt (BOM dahil)"; return 0
    fi
    for t in "$@"; do
        if [[ -n "$t" && "$t" == *[!\ -~]* ]]; then
            _ngxallow_fail "$line" "$dir" "arguman: kontrol karakteri/ASCII dışı bayt (CR/LF/NUL dahil) yasak"; return 0
        fi
        if (( ${#t} > 1024 )); then
            _ngxallow_fail "$line" "$dir" "arguman: belirteç uzunluk tavanı (1024)"; return 0
        fi
        all+=" $t"
    done
    _ngxallow_lc "$all"; all="${_NGXALLOW_LC//\\/}"
    case "$all" in
        *__fm_*|*/_fm/*|*_fm*|*fm_*|*@fm*|*\$fm*|*x-fm*|*x-accel*|*upstream_http*|*sent_http*|*http_authorization*|*\$cookie*|*cookie_*|*\$ssl_*|*auth_request*|*@srvctl*|*srvctl*|*fm-auth*)
            _ngxallow_fail "$line" "$dir" "yasak-dizgi: srvctl/FM/token ad uzayı ya da yasak değişken dizgisi"; return 0 ;;
    esac

    # ── direktif tablosu ──
    case "$dl" in
    client_max_body_size)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: client_max_body_size yalnız server/location ifadesi"; return 0; fi
        if (( nargs != 1 )) || [[ ! "$1" =~ ^[1-9][0-9]{0,5}[kKmMgG]?$ ]]; then
            _ngxallow_fail "$line" "$dir" "arguman: client_max_body_size ^[1-9][0-9]{0,5}[kKmMgG]?\$ (0 yasak)"; return 0
        fi
        ;;
    location)
        if [[ "$kind" != "open" ]] || ! _ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: location yalnız server/location içinde blok olarak"; return 0; fi
        local lmod="" lpat=""
        if (( nargs == 1 )); then lpat="$1"
        elif (( nargs == 2 )); then lmod="$1"; lpat="$2"
        else _ngxallow_fail "$line" "$dir" "arguman: location 1 ya da 2 argüman alır"; return 0; fi
        case "$lmod" in
            ""|"="|"^~")
                if [[ "$lpat" == @* ]]; then
                    if [[ -n "$lmod" || ! "$lpat" =~ ^@[a-z][a-z0-9_]{0,31}$ ]]; then
                        _ngxallow_fail "$line" "$dir" "arguman: adlı location @[a-z][a-z0-9_]{0,31} olmalı"; return 0
                    fi
                elif [[ ! "$lpat" =~ ^/[A-Za-z0-9._~/-]*$ || "$lpat" == *..* ]]; then
                    _ngxallow_fail "$line" "$dir" "arguman: location öneki ^/[A-Za-z0-9._~/-]*\$ olmalı (.. yasak)"; return 0
                fi
                ;;
            "~"|"~*")
                if ! _ngxallow_regex_ok "$lpat" "$([[ "$lmod" == "~*" ]] && echo 1 || echo 0)"; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
                for t in $_NGXALLOW_RX_NAMES; do
                    _NGXALLOW_DEFINED+="$t "; _NGXALLOW_TAINT+="$t "
                done
                ;;
            *) _ngxallow_fail "$line" "$dir" "arguman: location değiştirici yalnız = ^~ ~ ~*"; return 0 ;;
        esac
        ;;
    if)
        if [[ "$kind" != "open" ]] || ! _ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: if yalnız server/location içinde blok olarak"; return 0; fi
        local -a ia=("$@")
        local ifirst ilast
        if (( nargs < 1 )); then _ngxallow_fail "$line" "$dir" "arguman: boş if koşulu"; return 0; fi
        ifirst="${ia[0]}"; ilast="${ia[nargs-1]}"
        if [[ "$ifirst" != '('* ]]; then _ngxallow_fail "$line" "$dir" "arguman: if koşulu '(' ile başlamalı"; return 0; fi
        if [[ "$ilast" != *')' ]]; then _ngxallow_fail "$line" "$dir" "arguman: if koşulu ')' ile bitmeli"; return 0; fi
        # nginx ngx_http_rewrite_if_condition ile aynı soyma
        local -a ib=()
        j=0
        while (( j < nargs )); do
            t="${ia[j]}"
            if (( j == 0 )); then
                if (( ${#t} == 1 )); then j=$((j + 1)); continue; fi
                t="${t:1}"
            fi
            if (( j == nargs - 1 )); then
                if (( ${#ia[j]} == 1 )); then j=$((j + 1)); continue; fi
                t="${t%?}"
            fi
            ib[${#ib[@]}]="$t"
            j=$((j + 1))
        done
        local nib="${#ib[@]}"
        if (( nib != 1 && nib != 3 )); then
            _ngxallow_fail "$line" "$dir" "arguman: if koşulu '\$değişken' ya da '\$değişken OP değer' olmalı (dosya testleri yasak)"; return 0
        fi
        if [[ ! "${ib[0]}" =~ ^\$[A-Za-z0-9_]+$ ]]; then
            _ngxallow_fail "$line" "$dir" "arguman: if sol işleneni tek \$değişken olmalı (dosya testi / bileşik yasak)"; return 0
        fi
        if ! _ngxallow_vars "${ib[0]}" iflhs; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
        if (( nib == 3 )); then
            case "${ib[1]}" in
                "="|"!=")
                    if [[ "${ib[2]}" == *'$'* ]] || (( ${#ib[2]} > 200 )); then
                        _ngxallow_fail "$line" "$dir" "arguman: if = / != sağ işleneni değişkensiz sabit (≤200) olmalı"; return 0
                    fi
                    ;;
                "~"|"~*"|"!~"|"!~*")
                    if ! _ngxallow_regex_ok "${ib[2]}" "$([[ "${ib[1]}" == *'~*' ]] && echo 1 || echo 0)"; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
                    for t in $_NGXALLOW_RX_NAMES; do
                        _NGXALLOW_DEFINED+="$t "; _NGXALLOW_TAINT+="$t "
                    done
                    ;;
                *) _ngxallow_fail "$line" "$dir" "arguman: if işleci yalnız = != ~ ~* !~ !~*"; return 0 ;;
            esac
        fi
        ;;
    set)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLIJ; then _ngxallow_fail "$line" "$dir" "baglam: set yalnız server/location/if ifadesi"; return 0; fi
        if (( nargs != 2 )); then _ngxallow_fail "$line" "$dir" "arguman: set \$u_ad DEĞER"; return 0; fi
        if [[ ! "$1" =~ ^\$u_[a-z0-9_]{1,30}$ ]]; then
            _ngxallow_fail "$line" "$dir" "degisken: set hedefi yalnız \$u_[a-z0-9_]{1,30} (küçük harf; rezerve adlar yasak)"; return 0
        fi
        if ! _ngxallow_vars "$2" out; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
        _NGXALLOW_DEFINED+="${1#\$} "
        ;;
    return)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLIJ; then _ngxallow_fail "$line" "$dir" "baglam: return yalnız server/location/if ifadesi"; return 0; fi
        if (( nargs == 1 )); then
            if [[ "$1" =~ ^[2-5][0-9]{2}$ ]]; then
                :
            elif [[ "$1" =~ ^https?:// ]]; then
                if ! _ngxallow_vars "$1" out; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
            else
                _ngxallow_fail "$line" "$dir" "arguman: return KOD ya da http(s):// URL"; return 0
            fi
        elif (( nargs == 2 )); then
            if [[ ! "$1" =~ ^[2-5][0-9]{2}$ ]]; then _ngxallow_fail "$line" "$dir" "arguman: return kodu 200-599"; return 0; fi
            if ! _ngxallow_vars "$2" out; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
        else
            _ngxallow_fail "$line" "$dir" "arguman: return KOD [METİN|URL]"; return 0
        fi
        ;;
    add_header)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLI; then _ngxallow_fail "$line" "$dir" "baglam: add_header yalnız server/location/if ifadesi"; return 0; fi
        if (( nargs != 2 && nargs != 3 )); then _ngxallow_fail "$line" "$dir" "arguman: add_header AD DEĞER [always]"; return 0; fi
        if [[ ! "$1" =~ ^[A-Za-z][A-Za-z0-9-]{0,63}$ ]]; then _ngxallow_fail "$line" "$dir" "arguman: başlık adı ^[A-Za-z][A-Za-z0-9-]{0,63}\$"; return 0; fi
        if (( nargs == 3 )) && [[ "$3" != "always" ]]; then _ngxallow_fail "$line" "$dir" "arguman: üçüncü argüman yalnız 'always'"; return 0; fi
        if ! _ngxallow_vars "$2" out; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
        ;;
    allow|deny)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLX; then _ngxallow_fail "$line" "$dir" "baglam: $dir yalnız server/location/limit_except ifadesi"; return 0; fi
        if (( nargs != 1 )) || ! _ngxallow_addr_ok "$1"; then
            _ngxallow_fail "$line" "$dir" "arguman: $dir yalnız all / IPv4 / IPv6 / CIDR (unix: yasak)"; return 0
        fi
        ;;
    try_files)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: try_files yalnız server/location ifadesi"; return 0; fi
        if (( nargs < 2 || nargs > 8 )); then _ngxallow_fail "$line" "$dir" "arguman: try_files 2-8 argüman"; return 0; fi
        for t in "$@"; do
            if [[ "$t" == '$uri' || "$t" == '$uri/' ]]; then continue; fi
            if [[ "$t" =~ ^=[0-9]{3}$ ]]; then continue; fi
            if [[ "$t" =~ ^@[a-z][a-z0-9_]{0,31}$ ]]; then continue; fi
            if [[ "$t" =~ ^/[A-Za-z0-9._~/-]*(\?(\$args|\$query_string))?$ && "$t" != *..* ]]; then continue; fi
            _ngxallow_fail "$line" "$dir" "arguman: try_files argümanı yalnız \$uri, \$uri/, sabit yol, =KOD, @ad (ya da yol?\$args)"; return 0
        done
        ;;
    limit_req)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok L; then _ngxallow_fail "$line" "$dir" "baglam: limit_req yalnız location içinde"; return 0; fi
        local seen_z=0 seen_b=0 seen_n=0
        if (( nargs < 1 || nargs > 3 )); then _ngxallow_fail "$line" "$dir" "arguman: limit_req zone=AD [burst=N] [nodelay]"; return 0; fi
        for t in "$@"; do
            case "$t" in
                zone=rl_strict|zone=rl_standard|zone=rl_relaxed|zone=rl_api|zone=login_strict|zone=login_standard|zone=login_relaxed|zone=general|zone=login|zone=api)
                    seen_z=$((seen_z + 1)) ;;
                burst=*)
                    if [[ ! "$t" =~ ^burst=[1-9][0-9]{0,4}$ ]]; then _ngxallow_fail "$line" "$dir" "arguman: burst=N (1-99999)"; return 0; fi
                    seen_b=$((seen_b + 1)) ;;
                nodelay) seen_n=$((seen_n + 1)) ;;
                *) _ngxallow_fail "$line" "$dir" "arguman: limit_req zone kapalı kümede olmalı (rl_strict rl_standard rl_relaxed rl_api login_strict login_standard login_relaxed general login api)"; return 0 ;;
            esac
        done
        if (( seen_z != 1 || seen_b > 1 || seen_n > 1 )); then _ngxallow_fail "$line" "$dir" "arguman: limit_req tam bir zone= (tekrar yok) gerekir"; return 0; fi
        ;;
    limit_conn)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok L; then _ngxallow_fail "$line" "$dir" "baglam: limit_conn yalnız location içinde"; return 0; fi
        if (( nargs != 2 )) || [[ "$1" != "conn_per_ip" || ! "$2" =~ ^[1-9][0-9]{0,4}$ ]]; then
            _ngxallow_fail "$line" "$dir" "arguman: limit_conn conn_per_ip N"; return 0
        fi
        ;;
    limit_except)
        if [[ "$kind" != "open" ]] || ! _ngxallow_ctx_ok L; then _ngxallow_fail "$line" "$dir" "baglam: limit_except yalnız location içinde blok olarak"; return 0; fi
        if (( nargs < 1 || nargs > 8 )); then _ngxallow_fail "$line" "$dir" "arguman: limit_except yöntem listesi"; return 0; fi
        for t in "$@"; do
            case "$t" in
                GET|HEAD|POST|PUT|DELETE|OPTIONS|PATCH) ;;
                *) _ngxallow_fail "$line" "$dir" "arguman: limit_except yöntemi yalnız GET HEAD POST PUT DELETE OPTIONS PATCH"; return 0 ;;
            esac
        done
        ;;
    expires)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLI; then _ngxallow_fail "$line" "$dir" "baglam: expires yalnız server/location/if ifadesi"; return 0; fi
        local etime='^[+-]?[0-9]{1,9}(ms|s|m|h|d|w|M|y)?$'
        if (( nargs == 1 )) && [[ "$1" =~ ^(off|epoch|max)$ || "$1" =~ $etime ]]; then
            :
        elif (( nargs == 2 )) && [[ "$1" == "modified" && "$2" =~ $etime ]]; then
            :
        else
            _ngxallow_fail "$line" "$dir" "arguman: expires off|epoch|max|SÜRE|modified SÜRE"; return 0
        fi
        ;;
    log_not_found)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: log_not_found yalnız server/location ifadesi"; return 0; fi
        if (( nargs != 1 )) || [[ "$1" != "on" && "$1" != "off" ]]; then _ngxallow_fail "$line" "$dir" "arguman: log_not_found on|off"; return 0; fi
        ;;
    access_log)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLI; then _ngxallow_fail "$line" "$dir" "baglam: access_log yalnız server/location/if ifadesi"; return 0; fi
        if (( nargs != 1 )) || [[ "$1" != "off" ]]; then _ngxallow_fail "$line" "$dir" "arguman: access_log yalnız 'off' (yol alan günlük yasak)"; return 0; fi
        ;;
    index)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SL; then _ngxallow_fail "$line" "$dir" "baglam: index yalnız server/location ifadesi"; return 0; fi
        if (( nargs < 1 || nargs > 8 )); then _ngxallow_fail "$line" "$dir" "arguman: index 1-8 dosya adı"; return 0; fi
        for t in "$@"; do
            if [[ ! "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ || "$t" == *..* ]]; then
                _ngxallow_fail "$line" "$dir" "arguman: index dosya adı ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\$ (değişken/yol yasak)"; return 0
            fi
        done
        ;;
    rewrite)
        if [[ "$kind" != "stmt" ]] || ! _ngxallow_ctx_ok SLIJ; then _ngxallow_fail "$line" "$dir" "baglam: rewrite yalnız server/location/if ifadesi"; return 0; fi
        if (( nargs != 2 && nargs != 3 )); then _ngxallow_fail "$line" "$dir" "arguman: rewrite REGEX YERİNE [last|break|redirect|permanent]"; return 0; fi
        if ! _ngxallow_regex_ok "$1"; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
        for t in $_NGXALLOW_RX_NAMES; do
            _NGXALLOW_DEFINED+="$t "; _NGXALLOW_TAINT+="$t "
        done
        local rflag="${3-}"
        case "$rflag" in
            ""|last|break|redirect|permanent) ;;
            *) _ngxallow_fail "$line" "$dir" "arguman: rewrite bayrağı yalnız last|break|redirect|permanent"; return 0 ;;
        esac
        if [[ "$rflag" == "redirect" || "$rflag" == "permanent" || ( -z "$rflag" && "$2" =~ ^https?:// ) ]]; then
            if ! _ngxallow_vars "$2" out; then _ngxallow_fail "$line" "$dir" "$_NGXALLOW_WHY"; return 0; fi
        else
            if [[ ! "$2" =~ ^/[A-Za-z0-9._~/-]*(\?[A-Za-z0-9._~/=\&-]*)?$ || "$2" == *..* ]]; then
                _ngxallow_fail "$line" "$dir" "arguman: rewrite last/break/bayraksız YERİNE değişkensiz sabit yol olmalı"; return 0
            fi
        fi
        ;;
    *)
        _ngxallow_fail "$line" "$dir" "tanınmayan-direktif: '$dir' izin listesinde yok (varsayılan-ret)"
        return 0
        ;;
    esac

    # limit_except içinde yalnız allow/deny
    return 0
}

# limit_except gövdesi: yalnız allow/deny — bağlam yığını üstünden denetlenir.
# İfade tavanı (_NGXALLOW_MAX_STMT; ifade + blok başlığı): aşılınca TEK bulgu yazılır, kalan
# ifadeler denetlenmez (lexer dosyanın sonuna dek sürer; geri çağrı ucuz döner) ve tarama
# rc 2 döner (boyut tavanı = doğrulanamadı, fail-closed).
_ngxallow_cb_wrap() {
    local kind="$1" line="$2" dir="$3" nst="${#_NGX_STACK[@]}" top=""
    _NGXALLOW_NSTMT=$((_NGXALLOW_NSTMT + 1))
    if (( _NGXALLOW_NSTMT > _NGXALLOW_MAX_STMT )); then
        if (( _NGXALLOW_CAPPED == 0 )); then
            _NGXALLOW_CAPPED=1
            _ngxallow_fail "$line" "$dir" "boyut: dosya başına ifade tavanı (${_NGXALLOW_MAX_STMT}) aşıldı — kalan ifadeler denetlenmedi (fail-closed)"
        fi
        return 0
    fi
    if (( nst > 0 )); then top="${_NGX_STACK[nst-1]}"; fi
    if [[ "$top" == "limit_except" && "$dir" != "allow" && "$dir" != "deny" ]]; then
        _ngxallow_fail "$line" "$dir" "baglam: limit_except gövdesinde yalnız allow/deny"
        return 0
    fi
    if [[ "$top" == "if" && "$kind" == "open" ]]; then
        _ngxallow_fail "$line" "$dir" "baglam: if içinde blok yasak"
        return 0
    fi
    _ngxallow_cb "$@"
}

_ngxallow_reserved_name() {
    local nm="$1" lc
    _ngxallow_lc "$nm"; lc="$_NGXALLOW_LC"
    case "$lc" in
        *srvctl*|*fm*) return 0 ;;
    esac
    return 1
}

_ngxallow_scan() {
    local file="${1-}" domain="${2-}" lname="${3-}" prc=0 out rc
    local LC_ALL=C
    # FM yolu sondası kuyruğu (yereller: dinamik kapsamla _ngxallow_regex_ok'a görünür, taramalar arası sızmaz)
    local _NGXALLOW_DEFER=1
    local -a _NGXALLOW_PQ_ERE=() _NGXALLOW_PQ_LINE=() _NGXALLOW_PQ_DIR=()
    _NGXALLOW_OUT=""; _NGXALLOW_DEFINED=" "; _NGXALLOW_TAINT=" "; _NGXALLOW_NSTMT=0; _NGXALLOW_CAPPED=0
    if [[ -z "$file" || -z "$domain" ]]; then
        echo "0:-:lexer: kullanım: _ngxallow_scan <dosya> <domain>"
        return 2
    fi
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        echo "0:-:lexer: geçersiz domain adı (fail-closed)"
        return 2
    fi
    if ! declare -F _domconf_nginx_parse >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "${SRVCTL_ROOT:-/usr/local/srvctl}/lib/domconf.sh" 2>/dev/null || true
        if ! declare -F _domconf_nginx_parse >/dev/null 2>&1; then
            echo "0:-:lexer: _domconf_nginx_parse yüklenemedi (fail-closed)"
            return 2
        fi
    fi
    if [[ -L "$file" ]]; then
        echo "0:-:sembolik-bag: dosya sembolik bağ (fail-closed)"
        return 2
    fi
    if [[ -z "$lname" ]]; then lname="${file##*/}"; fi
    if _ngxallow_reserved_name "$lname"; then
        _ngxallow_fail 0 "-" "rezerve-ad: '$lname' srvctl/FM rezerve ad uzayında (srvctl-*, *srvctl*, *fm*)"
    fi
    local _DOMCONF_NGX_MAX_BYTES="$_NGXALLOW_MAX_BYTES"
    _domconf_nginx_parse "$file" _ngxallow_cb_wrap || prc=$?
    _ngxallow_probe_flush
    if (( prc != 0 )); then
        if (( prc == 3 )) && [[ "${_NGX_ERR:-}" == *"çok büyük"* ]]; then
            _ngxallow_fail "${_NGX_ERR_LINE:-0}" "-" "boyut: ${_NGX_ERR:-çözümlenemedi} (tavan ${_NGXALLOW_MAX_BYTES} bayt)"
        else
            _ngxallow_fail "${_NGX_ERR_LINE:-0}" "-" "lexer: ${_NGX_ERR:-çözümleme hatası} (fail-closed)"
        fi
        printf '%s' "$_NGXALLOW_OUT"
        return 2
    fi
    if (( _NGXALLOW_CAPPED )); then
        printf '%s' "$_NGXALLOW_OUT"
        return 2
    fi
    out="$_NGXALLOW_OUT"
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 1
    fi
    rc=0
    return "$rc"
}
