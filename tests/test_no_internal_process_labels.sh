#!/bin/bash
# Kalıcı kilit: srvctl'in KULLANICIYA gidecek metinleri (lib/*.sh, README.md, templates/** — şablonlar canlı nginx/systemd
# yapılandırmasına render edilir) ve depodaki BÜTÜN öteki test dışı dosyalar (bin/, completions/, conf/, install.sh, tools/, kök dizindeki yönerge dosyaları,
# docs/ — yalnız tests/ ve docs/superpowers/ hariç) iç süreç etiketi taşımaz.
# Etiket = denetim/tur adı (QL<n>, F<n> tur adları, F7-H1 / F8-M1 gibi bulgu etiketleri, SEC-H1 / rev-L7 / dev-L5 gibi
# öneki olan bulgu etiketleri, "fuzz bulgusu") ve karar belgesi numarası (§15/…). Bunlar bu deponun dışında anlamsızdır
# ve okuyanı yanlış yere yönlendirir. Test dosya adları ve test yorumları KAPSAM DIŞIDIR (burada denetlenmez).
#
# Desen sınıfları (her biri aşağıda pozitif kontrolle sınanır):
#   PAT_CS  büyük harfli tur/bulgu adları (harf duyarlı): F<sayı>[a-eA-E[<sayı>]][-HARF<sayı>|-<sayı>] (F0..F99, F1 / F9e / F9e11 / F9E5 / F9E-3 / F7-H1 / F8-M1),
#           QL<rakam>, "§15" ve "§ 15" (boşluklu)
#   PAT_CI  BÜYÜK/küçük harf FARKSIZ: (rev|dev|qa|inv|sec)-<harf><sayı> (SEC-H1, sec-h1, rev-L7, dev-L5), "fuzz bulgusu",
#           ql<çok haneli sayı> (ql5, Ql10, qL3-M2) ve küçük/karışık harfli tur adı f<çok haneli sayı>[a-e[<sayı>]] (f3/yol, f12, f10-h1, f9E, f9e11, f9e5);
#           $f90, -f2, f20= gibi değişken/bayrak adlarını yakalamaz (önünde $ . / { = - ya da harf/rakam olmamalı, arkasında
#           harf/rakam olmamalı)
#   PAT_X   alt çizgili/ek önekli tur adları (f9e_12, F9e_12) ve doğrulayıcı/tur-ajanı adları (verifier-A0-3, verifier-a0d, A0-3 biçimi)
#   DEĞİŞKEN ADI MUAFİYETİ (lib/*.sh, dar): f20 / f21 / f90 = FM dosya numaralarını taşıyan kabuk değişken adlarıdır (20-, 21-, 90- önekli
#           dosyalar); başka hiçbir f<n> adı muaf değildir.
#
# İZİN LİSTESİ (gerekçeli, dar): `fm-auth --capabilities` alan adları (f5-supersede, f6-emergency-off, f7-sig,
# f7-emergency-marker, f8-stage-gate, f8-closed-evidence, f9e-on-rc4, f9e-state-untrusted) PROTOKOL TANIMLAYICISIDIR: sargı betikleri
# bu adları ayrıştırır (README "Yetenek bildirimi" tablosu ve F4_CAPS_REQUIRED paritesi), yeniden adlandırılamazlar. Muafiyet
# YALNIZ bu sekiz sözcüğe ve YALNIZ onları üreten/belgeleyen üç dosyaya (lib/domconf.sh, lib/domain.sh, README.md) uygulanır;
# başka dosyada ya da başka bir f<n>-… sözcüğünde etiket sayılır. Yeni bir yetenek alanı eklemek bu listeyi bilerek güncellemeyi gerektirir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

PAT_CS='\bF[0-9]+([a-eA-E][0-9]*)?(-[A-Za-z]+[0-9]*|-[0-9]+)?\b|§[[:space:]]*15|\bQL[0-9]'
PAT_CI='(rev|dev|qa|inv|sec)-[a-z]+[0-9]+|fuzz bulgusu|(^|[^[:alnum:]_])ql[0-9]+|(^|[^[:alnum:]_$./{=-])f[0-9]+([a-e][0-9]*)?([^[:alnum:]_]|$)'
PAT_X='(^|[^[:alnum:]_$./{=-])[fF][0-9]+[a-eA-E]?[0-9]*_[0-9]+|\bverifier-[A-Za-z0-9]|\bA0-[0-9]'
CAP_STRIP='s/(^|[^[:alnum:]_])f(5-supersede|6-emergency-off|7-sig|7-emergency-marker|8-stage-gate|8-closed-evidence|9e-on-rc4|9e-state-untrusted)([^[:alnum:]_]|$)/\1\3/g'
FILE_STRIP='s/(^|[^[:alnum:]_])[fF](20|21|90)([^[:alnum:]_-]|$)/\1\3/g'

# stdin = metin, $1 = depo göreli yolu (izin listesi kapsamı). stdout = etiket taşıyan satır sayısı.
lbl_count() {
    local rel="$1" txt
    case "$rel" in
        lib/domconf.sh|lib/domain.sh) txt=$(sed -E -e "$CAP_STRIP" -e "$CAP_STRIP" -e "$FILE_STRIP" -e "$FILE_STRIP") ;;
        README.md) txt=$(sed -E -e "$CAP_STRIP" -e "$CAP_STRIP") ;;
        lib/*) txt=$(sed -E -e "$FILE_STRIP" -e "$FILE_STRIP") ;;
        *) txt=$(cat) ;;
    esac
    { printf '%s\n' "$txt" | grep -naE -- "$PAT_CS" || true
      printf '%s\n' "$txt" | grep -naiE -- "$PAT_CI" || true
      printf '%s\n' "$txt" | grep -naiE -- "$PAT_X" || true; } | cut -d: -f1 | sort -u | grep -c . || true
}

# Taranan küme: depodaki BÜTÜN test dışı dosyalar (tests/, docs/superpowers/, .git/ ve bayt-kod önbellekleri hariç). lib/*.sh ve
# README.md'nin izin listesi/muafiyetleri lbl_count'ta yolla seçilir; öteki her dosya muafiyetsiz taranır.
files=()
while IFS= read -r f; do files+=("${REPO_ROOT}/${f#./}"); done < <(cd "$REPO_ROOT" && find . -type f -not -path './.git/*' -not -path './tests/*' \
    -not -path './docs/superpowers/*' -not -path '*/__pycache__/*' -not -name '.DS_Store' | LC_ALL=C sort)
assert_ne() { TESTS_RUN=$((TESTS_RUN + 1)); if [[ "$1" != "$2" ]]; then echo "  PASS ${3:-}"; else echo "  FAIL ${3:-} ('$1' == '$2')"; TESTS_FAIL=$((TESTS_FAIL + 1)); fi; }
assert_ne "${#files[@]}" "0" "taranan küme boş değil (${#files[@]} dosya)"
for need in install.sh tools/tree-parity.sh bin/srvctl lib/domconf.sh README.md templates/nginx/fm-upload.conf.tpl; do
    case " ${files[*]} " in *" ${REPO_ROOT}/${need} "*) assert_eq "ok" "ok" "taranan kümede: ${need}" ;; *) assert_eq "yok" "ok" "taranan kümede: ${need}" ;; esac
done
for f in "${files[@]}"; do
    rel="${f#"${REPO_ROOT}"/}"
    n="$(lbl_count "$rel" < "$f")"
    assert_eq "$n" "0" "${rel}: iç süreç etiketi (QL<n>, F<n>, F7-H1, SEC-H1, rev-L7, fuzz bulgusu, §15 gibi) yok"
done

# PAT_X: alt çizgili tur adları ve doğrulayıcı adları (kilit önceki sürümde bunları kaçırıyordu)
for s in '# f9e_12 sonrası' '# F9e_12 sonrası' '# f9_3' '# verifier-A0-3 bulgusu' '# Verifier-a0d' '# A0-3 turu' '# (lab: verifier-a0c/raw/x)'; do
    for rel in lib/x.sh README.md templates/x.tpl install.sh tools/x.sh bin/srvctl; do
        assert_eq "$(printf '%s\n' "$s" | lbl_count "$rel")" "1" "pozitif kontrol PAT_X (${rel}): '${s}' etiket sayılır"
    done
done
assert_eq "$(printf '%s\n' 'verifier' 'x_12' 'a_f9_b' 'QA0-3' 'A0' 'PHP A0' | lbl_count lib/x.sh)" "0" "kontrol PAT_X: yalın 'verifier', x_12, a_f9_b, A0 yakalanmaz (yalnız 'verifier-<ad>' biçimi yakalanır)"
# kontrol: her desen sınıfı gerçekten etiketi yakalar (sahte yeşil olmasın); temiz satırı yakalamaz
assert_eq "$(printf '%s\n' '# QL5-M3: x' '# F9e-3 (§15/47)' 'F9b' 'temiz satır' | lbl_count lib/x.sh)" "3" "kontrol PAT_CS: QL/F9*/§15 satırlarını yakalar, temiz satırı yakalamaz"
assert_eq "$(printf '%s\n' '(fuzz F1)' 'F2 sınıfı' 'F10 turu' 'F0' '# F7-H1: x' '# F8-M1 — y' "F4'e ilk" 'F4-F6 biçimi' '(F8-H1(2b))' | lbl_count lib/x.sh)" "9" "kontrol PAT_CS: F0..F99 tam aralık, F1/F2/F10 ve F7-H1/F8-M1 bulgu etiketleri"
assert_eq "$(printf '%s\n' '# SEC-H1: x' 'sec-h1' 'Sec-H1' '# rev-L7: x' '# dev-L5: y' 'qa-M3' 'inv-H1 z' 'REV-l7' 'sec-S1' 'temiz satır' | lbl_count lib/x.sh)" "9" "kontrol PAT_CI: SEC-H1/sec-h1/rev-/dev-/qa-/inv- büyük-küçük harf farksız yakalanır, temiz satır yakalanmaz"
assert_eq "$(printf '%s\n' '(fuzz bulgusu F1)' 'Fuzz Bulgusu' 'fuzz bulgusu' 'fuzz testi' | lbl_count lib/x.sh)" "3" "kontrol: 'fuzz bulgusu' (büyük-küçük harf farksız) yakalanır, 'fuzz testi' yakalanmaz"
assert_eq "$(printf '%s\n' '(nginx ile ölçüldü, f3/final/x.out)' 'f9e davranışı' '(f7-h1)' 'f8 öncesi' | lbl_count templates/x.tpl)" "4" "kontrol PAT_LF: küçük harfli tur adları (f3/yol, f9e, f7-h1) yakalanır"
assert_eq "$(printf '%s\n' 'rev-parse' 'dev-null' 'sec-fetch-mode' 'qa-lab' 'devL7' 'cut -d= -f2' 'local f20 f21' 'f20="x"' '$f90' '[[ -f "$f" ]]' '${f2}' 'x.f9y' | lbl_count lib/x.sh)" "0" "kontrol: rev-parse, dev-null, cut -f2, \$f20 gibi sıradan sözcük/değişken/bayrak adları yakalanmaz"
assert_eq "$(printf '%s\n' 'AF4B' 'CF3 değeri' 'PHP 8.4' 'SHA256 ff3a 0xf3ab' 'tpl_ver 2' 'QL' | lbl_count lib/x.sh)" "0" "kontrol: sürüm dizesi, onaltılık değer ve başka sözcüklerin parçası yakalanmaz"
# harf duyarsız ve çok haneli etiketler (doğrulayıcı-2 kaçakları): her biri tek başına yakalanmalı
for s in '# (lab: ql5/qa/raw/lab-crash.out)' '# ql10 düzeltmesi' '# Ql10 düzeltmesi' '# QL10 düzeltmesi' '# qL3-M2 bulgusu' '# f12 turu' '# F12 turu' \
         '# f10-h1 bulgusu' '# F9E-3 sonrası' '# f9E sonrası' '# f9e-5 sonrası' '# §15/47' '# § 15/47' '# §  15/47' \
         '# f9e11 sonrası' '# F9e11 sonrası' '# f9e5 sonrası' '# F9E5' '# f9E11 turu' '# (lab: f9e11/raw/x.out)' '# (lab: F9e12/raw/x.out)' '# F9e5'; do
    for rel in lib/x.sh README.md templates/x.tpl; do
        assert_eq "$(printf '%s\n' "$s" | lbl_count "$rel")" "1" "pozitif kontrol (${rel}): '${s}' etiket sayılır"
    done
done
# …ve sıradan sözcükler yakalanmaz: onaltılık/sürüm dizeleri, başka sözcüklerin parçası (tiresiz tur adı kalıbı yanlış alarm vermesin)
assert_eq "$(printf '%s\n' '0xf9e11' 'af9e11' 'ff9e5' 'AF9E5' 'sha f9e11a' 'x.f9e11' '${f9e11}' '$f9e5' 'cut -f9e5' 'PHP 8.4 f' | lbl_count lib/x.sh)" "0" "kontrol: 0xf9e11, af9e11, \$f9e5, x.f9e11, f9e11a yakalanmaz"
# …ve sıradan çok haneli sözcükler yakalanmaz (sahte kırmızı olmasın)
assert_eq "$(printf '%s\n' 'cut -d: -f12' 'local f20 f21 f90' 'f20=$(x)' '"$F90"' 'ff12' 'F12AB' 'PHP 8.4 ql' 'ql' 'qlx5' 'x.f12' '${f12}' '$f12' 'grep -f10 x' '§ 1' | lbl_count lib/x.sh)" "0" "kontrol: -f12, \$f12, \${f12}, x.f12, ff12, f20/f21/f90 değişken adları yakalanmaz"
assert_eq "$(printf '%s\n' 'f20 dosyası' 'f90 dosyası' | lbl_count README.md)" "2" "değişken adı muafiyeti DAR: yalnız lib/*.sh'de; README/şablonda f20/f90 yakalanır"
# izin listesi: yalnız sekiz yetenek alanı ve yalnız üç dosyada muaf
CAPLINE='printf "srvctl-fm-caps v1 dry=1 f5-supersede=1 f6-emergency-off=1 f7-sig=1 f7-emergency-marker=1 f8-stage-gate=1 f8-closed-evidence=1 f9e-on-rc4=1 f9e-state-untrusted=1\n"'
assert_eq "$(printf '%s\n' "$CAPLINE" | lbl_count lib/domconf.sh)" "0" "izin listesi: --capabilities alan adları lib/domconf.sh'de etiket sayılmaz"
assert_eq "$(printf '%s\n' '`f5-supersede f6-emergency-off f7-sig f7-emergency-marker f8-stage-gate` bu sırayla' | lbl_count README.md)" "0" "izin listesi: README yetenek tablosunda tek boşlukla ayrık alan adları da muaf"
assert_eq "$(printf '%s\n' "$CAPLINE" | lbl_count lib/cloudflare.sh)" "1" "izin listesi DAR: aynı alan adları başka dosyada etiket sayılır"
assert_eq "$(printf '%s\n' "$CAPLINE" | lbl_count templates/nginx/x.tpl)" "1" "izin listesi DAR: şablonlarda muafiyet yok"
assert_eq "$(printf '%s\n' 'caps: f9e-yeni-alan=1' 'caps: f5-supersede=1 f8-yeni=1' 'caps: f5-supersede=1 f6-emergency-off=1' | lbl_count lib/domconf.sh)" "2" "izin listesi DAR: listede olmayan f<n>-… alanı ve karışık satırdaki yabancı alan etiket sayılır, yalnız listedekiler muaf"

test_summary
