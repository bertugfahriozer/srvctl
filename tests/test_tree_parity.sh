#!/bin/bash
# QL7-M9: tools/tree-parity.sh davranış testi. Betik git'siz da koşturulur (--ls-files-from/--status-from) ve sentetik
# ağaçlarla sınanır: self-update'in kurmayacağı gerekli dosya, izlenmeyen çalışma zamanı dosyası, çıkarılamayan kural ve
# olmayan dosyaya sabit başvuru FAIL verir; temiz ağaç rc 0. GERÇEK ağaç için git'siz parite (diskteki her çalışma
# zamanı dosyası "izleniyor" sayılır) rc 0 olmalı: yani bugünkü ağaçta self-update'in kurmayacağı gerekli dosya YOK.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
TP="${REPO_ROOT}/tools/tree-parity.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
assert_eq "$([[ -f "$TP" ]] && echo var || echo YOK)" "var" "(ön koşul) tools/tree-parity.sh var"

mk() {   # $1 = kök dizin → temiz mini ağaç (selfupdate.sh GERÇEK dosyadan; kurulum kuralları gerçek)
    local d="$1"
    mkdir -p "$d"/{bin,lib,templates/nginx,completions,conf,tests}
    cp "${REPO_ROOT}/lib/selfupdate.sh" "$d/lib/selfupdate.sh"
    printf '#!/bin/bash\n' > "$d/bin/srvctl"; for _l in core domconf changelog domain; do printf "x\n" > "$d/lib/${_l}.sh"; done
    printf 'x\n' > "$d/templates/nginx/a.tpl"; printf 'x\n' > "$d/completions/srvctl.bash"
    printf 'x\n' > "$d/conf/srvctl.conf"; printf 'x\n' > "$d/conf/rate-profiles.conf"; printf 'x\n' > "$d/conf/resource-profiles.conf"
    printf 'x\n' > "$d/tests/test_a.sh"; : > "$d/install.sh"
}
lsfiles() { ( cd "$1" && find . -type f | sed 's#^\./##' | LC_ALL=C sort ); }
run() {   # $1 = kök, $2 = status dosyası içeriği ("" = temiz), $3.. = ek bayraklar → çıktı + RC=
    local root="$1" st="$2"; shift 2
    lsfiles "$root" > "${T}/ls.$$"
    # status ile bildirilen izlenmeyen yollar izlenen listeden ÇIKARILIR
    printf '%s' "$st" > "${T}/st.$$"
    awk -F' ' '/^\?\? /{print $2}' "${T}/st.$$" | LC_ALL=C sort > "${T}/untr.$$"
    LC_ALL=C comm -23 "${T}/ls.$$" "${T}/untr.$$" > "${T}/ls2.$$"
    bash "$TP" --root "$root" --ls-files-from "${T}/ls2.$$" --status-from "${T}/st.$$" "$@" 2>&1
    echo "RC=$?"
}
rc_of() { local o="$1"; echo "${o##*RC=}"; }

echo "── A: temiz mini ağaç ──"
mk "${T}/a"
out=$(run "${T}/a" "")
assert_eq "$(rc_of "$out")" "0" "A1: temiz ağaç rc 0"
assert_contains "$out" "PARITE: TUTARLI" "A1: tutarlı özet"
assert_contains "$out" "bin/srvctl=1  lib/*.sh(düz)=1  templates/**(özyinelemeli)=1  completions/*(düz)=1" "A1: kurulum kuralları GERÇEK selfupdate.sh'tan çıkarıldı"
assert_contains "$out" "rate-profiles.conf resource-profiles.conf" "A1: veri tabloları dizisi çıkarıldı"
assert_contains "$out" "conf/srvctl.conf	TEMIZ	girer (değişiklik yok)	KASITLI" "A1: conf/srvctl.conf kasıtlı muaf"

echo "── B: izlenmeyen çalışma zamanı dosyası ──"
printf 'x\n' > "${T}/a/lib/nginx_allow.sh"
out=$(run "${T}/a" $'?? lib/nginx_allow.sh\n')
assert_eq "$(rc_of "$out")" "0" "B1: varsayılanda izlenmeyen dosya FAIL değil (commit öncesi ölçüm)"
assert_contains "$out" "lib/nginx_allow.sh	IZLENMIYOR	GİRMEZ — git add gerekir	kurar" "B1: izlenmeyen dosya 'GİRMEZ' + 'self-update kurar' olarak raporlanır"
assert_contains "$out" "İZLENMEYEN ÇALIŞMA ZAMANI DOSYALARI" "B1: ayrı bölümde listelenir"
out=$(run "${T}/a" $'?? lib/nginx_allow.sh\n' --strict-tracked)
assert_eq "$(rc_of "$out")" "1" "B2: --strict-tracked ile izlenmeyen çalışma zamanı dosyası FAIL (rc 1)"
assert_contains "$out" "izlenmeyen/ignore'lu çalışma zamanı dosyası: lib/nginx_allow.sh" "B2: FAIL satırı dosyayı adlandırır"
out=$(run "${T}/a" $'!! lib/nginx_allow.sh\n' --strict-tracked)
assert_contains "$out" "GİRMEZ — .gitignore'lu" "B3: ignore'lu çalışma zamanı dosyası 'GİRMEZ'"
rm -f "${T}/a/lib/nginx_allow.sh"

echo "── C: yeni testler ve artefakt ayrı listelenir ──"
printf 'x\n' > "${T}/a/tests/test_new.sh"; mkdir -p "${T}/a/tests/fuzz/__pycache__"; printf 'x\n' > "${T}/a/tests/fuzz/__pycache__/m.pyc"
out=$(run "${T}/a" $'?? tests/test_new.sh\n?? tests/fuzz/__pycache__/m.pyc\n')
assert_contains "$out" "YENİ (izlenmeyen): 1" "C1: yeni test sayıldı (artefakt sayılmadı)"
assert_contains "$out" "   tests/test_new.sh" "C1: yeni test listede"
sec_art="$(sed -n '/ARTEFAKT/,/SABİT/p' <<< "$out")"
assert_contains "$sec_art" "tests/fuzz/__pycache__/m.pyc" "C2: .pyc ARTEFAKT bölümünde"
assert_eq "$(rc_of "$(run "${T}/a" $'?? tests/fuzz/__pycache__/m.pyc\n' --strict-tracked)")" "1" "C3: --strict-tracked artefaktta FAIL"
rm -rf "${T}/a/tests/test_new.sh" "${T}/a/tests/fuzz"

echo "── D: self-update'in kurmayacağı gerekli dosya ──"
for f in lib/sub/x.sh lib/notes.txt conf/extra.conf completions/sub/x.bash; do
    rm -rf "${T}/d"; mk "${T}/d"; mkdir -p "$(dirname "${T}/d/${f}")"; printf 'x\n' > "${T}/d/${f}"
    out=$(run "${T}/d" "")
    assert_eq "$(rc_of "$out")" "1" "D[$f]: kurulmayacak gerekli dosya → rc 1"
    assert_contains "$out" "kurulmayacak ama gerekli çalışma zamanı dosyası: ${f}" "D[$f]: FAIL satırı dosyayı adlandırır"
done
rm -rf "${T}/d"; mk "${T}/d"; mkdir -p "${T}/d/templates/nginx/deep/er"; printf 'x\n' > "${T}/d/templates/nginx/deep/er/t.tpl"
assert_eq "$(rc_of "$(run "${T}/d" "")")" "0" "D5: templates/ altı DERİN alt dizin kurulur (özyinelemeli kopya) → rc 0"

echo "── E: kural çıkarılamazsa fail-closed ──"
rm -rf "${T}/e"; mk "${T}/e"
sed -i.orig 's#cp -f "\${staging}/lib/"\*\.sh#cp -f "${staging}/lib/"core.sh#' "${T}/e/lib/selfupdate.sh"; rm -f "${T}/e/lib/selfupdate.sh.orig"
out=$(run "${T}/e" "")
assert_eq "$(rc_of "$out")" "1" "E1: lib/*.sh kopya satırı değişirse kural çıkarılamaz → rc 1 (sessizce 'kurar' varsayılmaz)"
assert_contains "$out" "kural çıkarılamadı: lib/*.sh kopyası" "E1: FAIL nedeni"

echo "── F: olmayan dosyaya sabit başvuru ──"
rm -rf "${T}/f"; mk "${T}/f"
printf 'source "${SRVCTL_ROOT}/lib/ghost.sh"\n' >> "${T}/f/lib/domconf.sh"
out=$(run "${T}/f" "")
assert_eq "$(rc_of "$out")" "1" "F1: kodda sabit başvurulan lib/ghost.sh YOK → rc 1"
assert_contains "$out" "kodda sabit başvuru var ama dosya YOK: lib/ghost.sh" "F1: FAIL satırı"
printf 'source "${SRVCTL_ROOT}/lib/core.sh"\n' >> "${T}/f/lib/domconf.sh"; sed -i.orig '/ghost/d' "${T}/f/lib/domconf.sh"; rm -f "${T}/f/lib/domconf.sh.orig"
assert_eq "$(rc_of "$(run "${T}/f" "")")" "0" "F2: var olan dosyaya başvuru FAIL değil"

echo "── G: GERÇEK ağaç (git'siz): diskteki her çalışma zamanı dosyası self-update ile kurulabilir ──"
( cd "$REPO_ROOT" && for d in bin lib templates conf completions; do [[ -d "$d" ]] && find "$d" -type f ! -name '.DS_Store'; done; echo install.sh; find tests -maxdepth 1 -type f -name 'test_*.sh' ) | LC_ALL=C sort > "${T}/real.ls"
: > "${T}/real.st"
out=$(bash "$TP" --root "$REPO_ROOT" --ls-files-from "${T}/real.ls" --status-from "${T}/real.st" 2>&1; echo "RC=$?")
assert_eq "$(rc_of "$out")" "0" "G1: gerçek ağaç — kurulmayacak gerekli dosya / çıkarılamayan kural / olmayan başvuru YOK (rc 0)"
assert_contains "$out" "lib/nginx_allow.sh" "G1: yeni çalışma zamanı dosyası (nginx_allow.sh) ölçüme dahil"
assert_contains "$out" "templates/nginx/fm-upload.conf.tpl" "G1: FM şablonları ölçüme dahil"
assert_contains "$out" "bin/srvctl=1  lib/*.sh(düz)=1" "G1: gerçek selfupdate.sh kuralları çıkarıldı"
echo "── H: girdi doğrulaması ──"
: > "${T}/empty.ls"
out=$(bash "$TP" --root "${T}/a" --ls-files-from "${T}/empty.ls" --status-from "${T}/real.st" 2>&1; echo "RC=$?")
assert_eq "$(rc_of "$out")" "2" "H1: izlenen dosya listesi BOŞSA ölçüm reddedilir (rc 2; boş listeyle 'her şey izlenmiyor' sessizce geçmez)"
out=$(bash "$TP" --root "${T}/nope" 2>&1; echo "RC=$?")
assert_eq "$(rc_of "$out")" "2" "H2: var olmayan kök → rc 2"
out=$(bash "$TP" --zzz 2>&1; echo "RC=$?")
assert_eq "$(rc_of "$out")" "2" "H3: bilinmeyen seçenek → rc 2"
echo "── I: QL8-L7 şablon/modül adı başvurusu — diskten SİLİNEN dosya (izlenmeyen ya da izlenen) yakalanır ──"
mkref() {   # $1 = kök → fm-auth şablonuna DİNAMİK (SRVCTL_ROOT'suz) başvuran kod + şablonun kendisi
    mk "$1"
    printf 'x\n' > "$1/templates/nginx/fm-auth.conf.tpl"
    printf 'r=$(render_template "$(_tpl_dir)/fm-auth.conf.tpl" A=1)\n' >> "$1/lib/domconf.sh"
}
rm -rf "${T}/i"; mkref "${T}/i"
out=$(run "${T}/i" "")
assert_eq "$(rc_of "$out")" "0" "I0: şablon diskte var → rc 0 (kontrol)"
assert_contains "$out" "taranan şablon adı: 1 " "I0: dinamik başvurulu şablon adı TARANDI (sayaç 1)"
rm -f "${T}/i/templates/nginx/fm-auth.conf.tpl"
out=$(run "${T}/i" $'?? templates/nginx/fm-auth.conf.tpl\n')
assert_eq "$(rc_of "$out")" "1" "I1: izlenmeyen şablon diskten silindi → rc 1 (eski betik rc 0 verirdi)"
assert_contains "$out" "kodda adı geçen şablon diskte YOK: fm-auth.conf.tpl" "I1: FAIL satırı şablonu adlandırır"
# izlenen ama silinmiş: izlenen listede VAR, diskte YOK
lsfiles "${T}/i" > "${T}/i.ls"; echo templates/nginx/fm-auth.conf.tpl >> "${T}/i.ls"; LC_ALL=C sort -o "${T}/i.ls" "${T}/i.ls"; : > "${T}/i.st"
out=$(bash "$TP" --root "${T}/i" --ls-files-from "${T}/i.ls" --status-from "${T}/i.st" 2>&1; echo "RC=$?")
assert_eq "$(rc_of "$out")" "1" "I2: İZLENEN şablon diskten silindi → rc 1"
assert_contains "$out" "kodda adı geçen şablon diskte YOK: fm-auth.conf.tpl" "I2: FAIL satırı"
# yalnız yorumda anılan / dinamik parçalı ad başvuru sayılmaz
rm -rf "${T}/i"; mk "${T}/i"
printf '# bkz. ghost-yorum.conf.tpl (yalnız yorum)\nx=$(render_template "${d}/${n}.conf.tpl")\ny="fm-*.tpl"\n' >> "${T}/i/lib/domconf.sh"
out=$(run "${T}/i" "")
assert_eq "$(rc_of "$out")" "0" "I3: yorumdaki ad, dinamik parçalı ad ve yer tutuculu ad başvuru SAYILMAZ → rc 0"
assert_contains "$out" "taranan şablon adı: 0 " "I3: hiçbiri taranmadı (sayaç 0)"
# modül: _load_and_run <ad> → lib/<ad>.sh
rm -rf "${T}/i"; mk "${T}/i"
printf '    ghost) _load_and_run ghost cmd_ghost "${@:2}" ;;\n' >> "${T}/i/bin/srvctl"
out=$(run "${T}/i" "")
assert_eq "$(rc_of "$out")" "1" "I4: _load_and_run ghost ama lib/ghost.sh YOK → rc 1"
assert_contains "$out" "modül diskte YOK: lib/ghost.sh" "I4: FAIL satırı"
printf 'x\n' > "${T}/i/lib/ghost.sh"
assert_eq "$(rc_of "$(run "${T}/i" "")")" "0" "I5: lib/ghost.sh eklenince rc 0"
printf '# _load_and_run phantom cmd_x\n' >> "${T}/i/bin/srvctl"
assert_eq "$(rc_of "$(run "${T}/i" "")")" "0" "I6: yorum satırındaki _load_and_run başvuru SAYILMAZ → rc 0"
echo "── I7: şablon yalnız templates/** dışında bir yerde varsa SAYILMAZ ──"
rm -rf "${T}/i"; mkref "${T}/i"
rm -f "${T}/i/templates/nginx/fm-auth.conf.tpl"; mkdir -p "${T}/i/tests/fixtures"; printf 'x\n' > "${T}/i/tests/fixtures/fm-auth.conf.tpl"
out=$(run "${T}/i" "")
assert_eq "$(rc_of "$out")" "1" "I7: aynı adlı dosya templates/** dışında (tests/fixtures) → şablon yine EKSİK sayılır (rc 1)"
echo "── J: QL8 — üretilen Python önbelleği .gitignore'da ──"
GI="$(cat "${REPO_ROOT}/.gitignore")"
assert_contains "$GI" "__pycache__/" "J1: .gitignore __pycache__/ içeriyor (tests/fuzz önbelleği commit listesine girmez)"
assert_contains "$GI" "*.pyc" "J1: .gitignore *.pyc içeriyor"
test_summary