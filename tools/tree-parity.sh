#!/bin/bash
# tools/tree-parity.sh — "test edilen ağaç" ile "commit/PR'a girecek ağaç" ve "self-update'in KURACAĞI ağaç" eşitliğini ÖLÇER.
# commit/add/push ATMAZ; yalnız okur (git --no-optional-locks ls-files|status). Yan etkisi yok.
#
# Neden: çalışma zamanı dosyası (lib/**, templates/**, bin/**, conf/**, completions/**) izlenmiyorsa (`??`) ve commit listesine
# eklenmezse PR onsuz birleşir; self-update o dosyayı KURMAZ ve `srvctl version` gibi sağlık kontrolleri bunu yakalamaz
# (lib/nginx_allow.sh ve templates/nginx/fm-*.conf.tpl böyle izlenmiyordu). Ayrıca kopyalanma kuralı (self-update)
# bir dosyayı kapsamıyorsa (ör. lib/ altı alt dizin) o dosya canlıya hiç ulaşmaz.
#
# Kullanım:  tools/tree-parity.sh [--root DIR] [--strict-tracked] [--ls-files-from F --status-from F]
#   --root DIR          ağaç kökü (varsayılan: bu betiğin üst dizini)
#   --strict-tracked    izlenmeyen/ignore'lu ÇALIŞMA ZAMANI dosyası da FAIL sayılır (commit listesi hazırlandıktan sonra kapı)
#   --ls-files-from F   `git ls-files` yerine bu dosya (testler/git'siz kopya için); --status-from F: `git status --porcelain -uall --ignored`
# Çıkış: 0 = tutarlı · 1 = FAIL (kurulmayacak-ama-gerekli dosya, çıkarılamayan kural, olmayan dosyaya sabit referans,
# --strict-tracked ile izlenmeyen çalışma zamanı dosyası) · 2 = kullanım/ortam hatası.
set -uo pipefail

ROOT=""; STRICT=0; LSF=""; STF=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)            ROOT="${2:-}"; shift 2 || { echo "--root değer ister" >&2; exit 2; } ;;
        --strict-tracked)  STRICT=1; shift ;;
        --ls-files-from)   LSF="${2:-}"; shift 2 || { echo "--ls-files-from değer ister" >&2; exit 2; } ;;
        --status-from)     STF="${2:-}"; shift 2 || { echo "--status-from değer ister" >&2; exit 2; } ;;
        -h|--help)         sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "bilinmeyen seçenek: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$ROOT" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$ROOT" && pwd)" || { echo "kök yok: $ROOT" >&2; exit 2; }
[[ -f "${ROOT}/lib/selfupdate.sh" ]] || { echo "lib/selfupdate.sh yok: ${ROOT} (srvctl ağacı değil)" >&2; exit 2; }

W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT
FAILS=0
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }

# ── girdiler: izlenen yollar, durum satırları ──
if [[ -n "$LSF" ]]; then cp "$LSF" "${W}/tracked"; else git -C "$ROOT" --no-optional-locks ls-files > "${W}/tracked" 2>/dev/null || { echo "git ls-files başarısız" >&2; exit 2; }; fi
if [[ -n "$STF" ]]; then cp "$STF" "${W}/status"; else git -C "$ROOT" --no-optional-locks status --porcelain -uall --ignored > "${W}/status" 2>/dev/null || { echo "git status başarısız" >&2; exit 2; }; fi
sort -u "${W}/tracked" -o "${W}/tracked"
# durum: yol → kod (XY). Yeniden adlandırma "R  a -> b" ise hedef alınır.
sed -e 's/^\(..\) \(.* -> \)\{0,1\}\(.*\)$/\1\t\3/' "${W}/status" | sed 's/^\(..\)\t"\(.*\)"$/\1\t\2/' > "${W}/status.tsv"
if [[ ! -s "${W}/tracked" ]]; then echo "izlenen dosya listesi BOŞ: ölçüm anlamsız" >&2; exit 2; fi

# ── diskteki çalışma zamanı dosyaları ──
( cd "$ROOT" && for d in bin lib templates conf completions; do [[ -d "$d" ]] && find "$d" -type f ! -name '.DS_Store' ! -name '*.bak' ! -name '*.tmp' ! -name '*.log'; done; [[ -f install.sh ]] && echo install.sh ) | LC_ALL=C sort -u > "${W}/disk.rt"
grep -E '^(bin|lib|templates|conf|completions)/|^install\.sh$' "${W}/tracked" | LC_ALL=C sort -u > "${W}/tracked.rt"
LC_ALL=C sort -u "${W}/disk.rt" "${W}/tracked.rt" > "${W}/all.rt"

status_of() {   # yol → XY kodu (yoksa "  " = temiz izlenen)
    local p="$1" c
    c="$(awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "${W}/status.tsv")"
    printf '%s' "${c:-  }"
}
commit_class() {   # yol → TAKİP SINIFI
    local p="$1" xy; xy="$(status_of "$p")"
    if [[ "$xy" == "??" ]]; then echo "IZLENMIYOR"; return; fi
    if [[ "$xy" == "!!" ]]; then echo "IGNORE"; return; fi
    if ! grep -qxF -- "$p" "${W}/tracked"; then echo "IZLENMIYOR"; return; fi
    if [[ ! -e "${ROOT}/${p}" ]]; then echo "SILINMIS"; return; fi
    case "$xy" in "  ") echo "TEMIZ" ;; *) echo "DEGISMIS" ;; esac
}

# ── self-update kurulum kuralları: lib/selfupdate.sh :: _selfupdate_install_from_staging (yorumsuz gövde) ──
BODY="$(awk '/^_selfupdate_install_from_staging\(\)/{f=1} f{print} f&&/^}/{exit}' "${ROOT}/lib/selfupdate.sh" | grep -vE '^[[:space:]]*#')"
R_BIN=0; R_LIB=0; R_TPL=0; R_CMP=0
grep -qE 'cp -f "\$\{staging\}/bin/srvctl"' <<< "$BODY" && R_BIN=1
grep -qE 'cp -f "\$\{staging\}/lib/"\*\.sh' <<< "$BODY" && R_LIB=1
grep -qE 'cp -rf "\$\{staging\}/templates/"\*' <<< "$BODY" && R_TPL=1
grep -qE 'cp -f "\$\{staging\}/completions/"\*' <<< "$BODY" && R_CMP=1
DATACONFS="$(sed -n 's/^_SELFUPDATE_DATA_CONFS=(\(.*\))[[:space:]]*$/\1/p' "${ROOT}/lib/selfupdate.sh" | head -1)"
grep -qE 'for dataconf in "\$\{_SELFUPDATE_DATA_CONFS\[@\]\}"' <<< "$BODY" || DATACONFS=""
echo "== self-update kurulum kuralları (lib/selfupdate.sh :: _selfupdate_install_from_staging) =="
echo "   bin/srvctl=${R_BIN}  lib/*.sh(düz)=${R_LIB}  templates/**(özyinelemeli)=${R_TPL}  completions/*(düz)=${R_CMP}  conf veri tabloları=[${DATACONFS}]"
[[ "$R_BIN" == 1 ]] || fail "kural çıkarılamadı: bin/srvctl kopyası (selfupdate.sh değişti; bu betik güncellenmeli)"
[[ "$R_LIB" == 1 ]] || fail "kural çıkarılamadı: lib/*.sh kopyası"
[[ "$R_TPL" == 1 ]] || fail "kural çıkarılamadı: templates/ özyinelemeli kopya"
[[ "$R_CMP" == 1 ]] || fail "kural çıkarılamadı: completions/* kopyası"
[[ -n "$DATACONFS" ]] || fail "kural çıkarılamadı: _SELFUPDATE_DATA_CONFS dizisi"

installs() {   # yol → 0 = self-update bu dosyayı kurar
    local p="$1" d
    case "$p" in
        bin/srvctl) [[ "$R_BIN" == 1 ]] ;;
        lib/*)      [[ "$R_LIB" == 1 && "$p" != */*/* && "$p" == *.sh ]] ;;
        templates/*) [[ "$R_TPL" == 1 ]] ;;
        completions/*) [[ "$R_CMP" == 1 && "$p" != */*/* ]] ;;
        conf/*)     for d in $DATACONFS; do [[ "$p" == "conf/${d}" ]] && return 0; done; return 1 ;;
        *) return 1 ;;
    esac
}
exempt_reason() {   # kasıtlı kurulmayan dosyalar
    case "$1" in
        conf/srvctl.conf) echo "KASITLI: canlı ayarlar/sırlar korunur (self-update dokunmaz)" ;;
        install.sh)       echo "KASITLI: kurulum betiği, çalışma zamanı dosyası değil" ;;
        *) return 1 ;;
    esac
}

echo
echo "== ÇALIŞMA ZAMANI DOSYALARI: takip sınıfı · commit listesine girer mi · self-update kurar mı =="
printf '%s\t%s\t%s\t%s\n' "YOL" "TAKİP" "COMMIT LİSTESİ" "SELF-UPDATE"
N_RT=0; N_UNTR=0; N_MOD=0; N_NOINST=0
: > "${W}/untracked.rt"
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    N_RT=$((N_RT + 1))
    cls="$(commit_class "$p")"
    case "$cls" in
        TEMIZ)       cl="girer (değişiklik yok)" ;;
        DEGISMIS)    cl="GİRER (git add -u)"; N_MOD=$((N_MOD + 1)) ;;
        IZLENMIYOR)  cl="GİRMEZ — git add gerekir"; N_UNTR=$((N_UNTR + 1)); echo "$p" >> "${W}/untracked.rt" ;;
        IGNORE)      cl="GİRMEZ — .gitignore'lu"; N_UNTR=$((N_UNTR + 1)); echo "$p" >> "${W}/untracked.rt" ;;
        SILINMIS)    cl="SİLİNİR (izlenen ama diskte yok)" ;;
    esac
    if installs "$p"; then inst="kurar"
    elif r="$(exempt_reason "$p")"; then inst="$r"
    else inst="KURMAZ"; N_NOINST=$((N_NOINST + 1)); fail "kurulmayacak ama gerekli çalışma zamanı dosyası: ${p} (self-update kuralı kapsamıyor)"; fi
    [[ "$cls" == "SILINMIS" ]] && inst="-"
    printf '%s\t%s\t%s\t%s\n' "$p" "$cls" "$cl" "$inst"
done < "${W}/all.rt"

echo
echo "== İZLENMEYEN ÇALIŞMA ZAMANI DOSYALARI (commit listesine EKLENMELİ; eklenmezse self-update bunları kurmaz) =="
if [[ -s "${W}/untracked.rt" ]]; then
    sed 's/^/   /' "${W}/untracked.rt"
    if [[ "$STRICT" == 1 ]]; then while IFS= read -r p; do fail "izlenmeyen/ignore'lu çalışma zamanı dosyası: ${p}"; done < "${W}/untracked.rt"; fi
else echo "   (yok)"; fi

echo
echo "== TESTLER =="
grep -E '^tests/' "${W}/tracked" | wc -l | tr -d ' ' > "${W}/n.tracked.tests"
awk -F'\t' '$1 == "??" && $2 ~ /^tests\// {print $2}' "${W}/status.tsv" | LC_ALL=C sort > "${W}/untracked.tests.all"
# üretilen artefaktlar (derleme/önbellek) commit listesine GİRMEMELİ: ayrı listelenir
grep -E '(^|/)__pycache__/|\.pyc$|\.DS_Store$|\.swp$' "${W}/untracked.tests.all" > "${W}/artefacts" || true
grep -vE '(^|/)__pycache__/|\.pyc$|\.DS_Store$|\.swp$' "${W}/untracked.tests.all" > "${W}/untracked.tests" || true
awk -F'\t' '$1 != "??" && $1 != "!!" && $1 != "  " && $2 ~ /^tests\// {print $2}' "${W}/status.tsv" | LC_ALL=C sort > "${W}/modified.tests"
echo "   izlenen test dosyası: $(cat "${W}/n.tracked.tests") · değişmiş izlenen: $(wc -l < "${W}/modified.tests" | tr -d ' ') · YENİ (izlenmeyen): $(wc -l < "${W}/untracked.tests" | tr -d ' ')"
echo "   -- YENİ testler/yardımcılar (commit listesine eklenmeli) --"
if [[ -s "${W}/untracked.tests" ]]; then sed 's/^/   /' "${W}/untracked.tests"; else echo "   (yok)"; fi
echo "   -- ARTEFAKT (üretilmiş; commit listesine EKLENMEMELİ, .gitignore'a alınmalı) --"
if [[ -s "${W}/artefacts" ]]; then
    sed 's/^/   /' "${W}/artefacts"
    if [[ "$STRICT" == 1 ]]; then while IFS= read -r p; do fail "üretilmiş artefakt izlenmiyor ama ignore'da da değil: ${p}"; done < "${W}/artefacts"; fi
else echo "   (yok)"; fi
# yeni testin kaynakladığı yardımcı/çalışma zamanı dosyası diskte VAR mı (eksik yardımcı = test başka makinede kırılır)
: > "${W}/missingref"
while IFS= read -r t; do
    [[ -f "${ROOT}/${t}" ]] || continue
    case "$t" in tests/*.sh) ;; *) continue ;; esac
    grep -oE 'source "\$\{REPO_ROOT\}/[A-Za-z0-9_./-]+"' "${ROOT}/${t}" 2>/dev/null | sed 's/^source "${REPO_ROOT}\///; s/"$//' | while IFS= read -r ref; do
        [[ -e "${ROOT}/${ref}" ]] || echo "${t} -> ${ref}" >> "${W}/missingref"
    done
done < <(cat "${W}/untracked.tests" "${W}/modified.tests"; grep -E '^tests/test_.*\.sh$' "${W}/tracked")
if [[ -s "${W}/missingref" ]]; then while IFS= read -r l; do fail "test olmayan dosyayı source ediyor: ${l}"; done < "${W}/missingref"; fi

echo
echo "== SABİT SRVCTL_ROOT BAŞVURULARI: olmayan dosya var mı =="
( cd "$ROOT" && grep -rhoE '\$\{?SRVCTL_ROOT\}?/(lib|templates|conf|completions|bin)/[A-Za-z0-9_./-]+' bin lib install.sh 2>/dev/null ) \
    | sed -E 's#^\$\{?SRVCTL_ROOT\}?/##; s#[.]+$##' | LC_ALL=C sort -u > "${W}/refs"
NREF=0
while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    case "$r" in */) continue ;; esac
    NREF=$((NREF + 1))
    [[ -e "${ROOT}/${r}" ]] || echo "$r" >> "${W}/refs.missing"
done < "${W}/refs"
echo "   taranan sabit başvuru: ${NREF}"
if [[ -s "${W}/refs.missing" ]]; then
    while IFS= read -r r; do
        # çalışma zamanında OLUŞAN yollar (kayıt/log/yedek) FAIL değil: yalnız kaynak ağaçta bulunması gereken dizinler sınanır
        case "$r" in
            lib/*.sh|templates/*|completions/*|bin/*) fail "kodda sabit başvuru var ama dosya YOK: ${r}" ;;
            *) echo "   BİLGİ (çalışma zamanında oluşur / ağaçta beklenmez): ${r}" ;;
        esac
    done < "${W}/refs.missing"
fi

echo
# Şablon adları kodda DİNAMİK kurulur ($(_domconf_fm_tpl_dir)/fm-auth.conf.tpl, render_template "$dir/x.tpl"), yani
# yukarıdaki SRVCTL_ROOT taraması onları görmez; diskten SİLİNMİŞ bir şablon (izlenmeyen ya da izlenen) "beklenen liste"de
# olmadığı için sessizce geçiyordu ("PARITE: TUTARLI" iken fm-auth.conf.tpl yoktu). Beklenen liste artık TARAMA tabanlı:
# yorum satırları atılmış bin/ lib/ install.sh içinde ADI geçen her `*.tpl` ve her `_load_and_run <modül>` hedefi
# (lib/<modül>.sh) diskte (templates/** altında / lib/ altında) VAR olmalı. Dinamik parça içeren (`${x}.conf.tpl`)
# ya da yer tutuculu (`fm-*.tpl`) adlar tam ad olmadığından alınmaz.
echo "== ŞABLON ve MODÜL ADI BAŞVURULARI: kodda adı geçen çalışma zamanı dosyası diskte var mı =="
: > "${W}/names.missing"
( cd "$ROOT" && for d in bin lib; do [[ -d "$d" ]] && find "$d" -type f -print0; done | xargs -0 cat 2>/dev/null; [[ -f install.sh ]] && cat install.sh ) \
    | grep -v '^[[:space:]]*#' > "${W}/code.nocomment" || true
grep -oE '(^|[^A-Za-z0-9_.-])[A-Za-z0-9][A-Za-z0-9_.-]*\.tpl\b' "${W}/code.nocomment" | sed -E 's/^[^A-Za-z0-9]//' | LC_ALL=C sort -u > "${W}/tplnames" || true
grep -oE '_load_and_run [a-z][a-z0-9_-]*' "${W}/code.nocomment" | awk '{print $2}' | LC_ALL=C sort -u > "${W}/modnames" || true
NTPL=0; NMOD=0
while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    NTPL=$((NTPL + 1))
    if [[ -z "$(find "${ROOT}/templates" -type f -name "$t" 2>/dev/null | head -1)" ]]; then
        echo "templates/**/${t}" >> "${W}/names.missing"
        fail "kodda adı geçen şablon diskte YOK: ${t} (templates/** altında bulunamadı; silinmiş olabilir)"
    fi
done < "${W}/tplnames"
while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    NMOD=$((NMOD + 1))
    if [[ ! -f "${ROOT}/lib/${m}.sh" ]]; then
        echo "lib/${m}.sh" >> "${W}/names.missing"
        fail "bin/lib '_load_and_run ${m}' diyor ama modül diskte YOK: lib/${m}.sh"
    fi
done < "${W}/modnames"
echo "   taranan şablon adı: ${NTPL} · taranan modül adı: ${NMOD} · eksik: $(grep -c . "${W}/names.missing" 2>/dev/null || true)"

echo
echo "== ÖZET =="
echo "   çalışma zamanı dosyası: ${N_RT} · izlenmeyen/ignore: ${N_UNTR} · değişmiş izlenen: ${N_MOD} · self-update'in kurmayacağı gerekli dosya: ${N_NOINST}"
if (( FAILS == 0 )); then echo "PARITE: TUTARLI (FAIL 0)"; exit 0; fi
echo "PARITE: TUTARSIZ (FAIL ${FAILS})"
exit 1
