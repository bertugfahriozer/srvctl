#!/bin/bash
# AppArmor shared/media kuralı kilidi — kalıcı medya yüklemeleri için.
#
# NEDEN VAR: site pre-deploy hook'u (shared/hooks/pre-deploy.sh) her release'in
# public/media'sını '../../../shared/media'ya symlink'ler. AppArmor symlink'i
# çözüp GERÇEK (shared) yolu denetler; 'public_html/** r' yalnız okuma verir,
# bu yüzden shared/media/** için ayrı bir 'rwk' kuralı olmazsa elFinder'ın
# mkdir/touch/rename çağrıları DAC yazılabilir görünse bile EACCES alır.
#
# Bu test (test_apparmor_shared_dirs.sh gibi) apparmor_parser ÇALIŞTIRMAZ —
# macOS'ta yok; tamamen metin taramasıdır. Yani kuralın SÖZDİZİMİNİ değil
# VARLIĞINI ve KAPSAMINI kilitler; sözdizimi canlıda 'apparmor_parser -r'
# (veya -Q) ile doğrulanır.
#
# Üç şeyi kilitler:
#   1. profile.tpl'de 'shared/media/**' kuralı VAR ve w + k içerir.
#   2. Kural exec/mmap/link (x, m, l) İÇERMEZ ve kapsam genişlemez:
#      'shared/**', 'shared/media**', 'public_html/** w' gibi daha geniş bir
#      yazma kuralı yok.
#   3. Yalnız YORUM dışı satırlar sayılır — açıklama metni kuralı "var" gibi
#      gösteremesin (bir yorumdaki dize sahte geçiş üretirdi).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

PROFILE_TPL="${REPO_ROOT}/templates/apparmor/profile.tpl"

# Yorum satırlarını ve boş satırları at; girdi METİN (fixture'lanabilir).
_aa_rules_only() {
    printf '%s\n' "$1" | grep -vE '^[[:space:]]*(#|$)'
}

# Verilen yol deseni için izin harflerini döndürür (ör. 'rwk'); yoksa boş.
# Desen TAM satır başı eşleşmesiyle aranır ('shared/media/**' ≠ 'shared/media/**/x').
_aa_perm_for() {
    local rules="$1" path="$2"
    printf '%s\n' "$rules" \
        | awk -v p="$path" '{ gsub(/^[ \t]+/, "") } $1 == p { gsub(/,$/, "", $2); print $2; exit }'
}

# Bir kural satırı yazma (w) izni veriyor mu VE yol shared/ ya da public_html/
# altında mı — media dışı geniş yazma kuralı dedektörü. 'media/**' ve mevcut
# 'shared/<bilinen>/**' kuralları hariç tutulur (beyaz liste).
_aa_broad_shared_write() {
    local rules="$1"
    printf '%s\n' "$rules" | awk '
        /^[ \t]*\{\{WEB_ROOT\}\}\/\{\{DOMAIN\}\}\/(shared|public_html)/ {
            path=$1; perm=$2; gsub(/,$/, "", perm)
            if (perm !~ /w/) next
            if (path ~ /\/shared\/(writable|storage|bootstrap-cache|var|var-log|var-sessions|media)\/\*\*$/) next
            print path
        }'
}

PREFIX='{{WEB_ROOT}}/{{DOMAIN}}'
MEDIA="${PREFIX}/shared/media/**"

# ═══════════════════════════════════════════════════════════════
# Kendi kendini doğrulama (sentetik fixture)
# ═══════════════════════════════════════════════════════════════
echo "== Kendi kendini doğrulama (sentetik fixture) =="

fx_ok="  ${MEDIA} rwk,"
assert_eq "$(_aa_perm_for "$(_aa_rules_only "$fx_ok")" "$MEDIA")" "rwk" \
    "dedektör: 'rwk' kuralını okuyor"

fx_comment="  # ${MEDIA} rwk,"
assert_eq "$(_aa_perm_for "$(_aa_rules_only "$fx_comment")" "$MEDIA")" "" \
    "dedektör: YORUM satırındaki kuralı saymıyor (sahte geçiş yok)"

fx_nolock="  ${MEDIA} rw,"
assert_not_contains "$(_aa_perm_for "$(_aa_rules_only "$fx_nolock")" "$MEDIA")" "k" \
    "dedektör: 'k' eksikliğini yakalıyor"

fx_broad="  ${PREFIX}/shared/** rwk,"
assert_eq "$(_aa_broad_shared_write "$(_aa_rules_only "$fx_broad")")" "${PREFIX}/shared/**" \
    "geniş-kural dedektörü: 'shared/**' yazma kuralını yakalıyor"

fx_broad2="  ${PREFIX}/public_html/** rw,"
assert_eq "$(_aa_broad_shared_write "$(_aa_rules_only "$fx_broad2")")" "${PREFIX}/public_html/**" \
    "geniş-kural dedektörü: 'public_html/** rw' yakalıyor"

fx_legit="  ${PREFIX}/public_html/** r,
  ${PREFIX}/shared/writable/** rwk,
  ${MEDIA} rwk,"
assert_eq "$(_aa_broad_shared_write "$(_aa_rules_only "$fx_legit")")" "" \
    "geniş-kural dedektörü: meşru kurallarda YANLIŞ POZİTİF üretmiyor"

# ═══════════════════════════════════════════════════════════════
# Gerçek profil şablonu
# ═══════════════════════════════════════════════════════════════
echo ""
echo "== Gerçek templates/apparmor/profile.tpl denetimi =="

if [[ ! -f "$PROFILE_TPL" ]]; then
    assert_eq "eksik" "var" "templates/apparmor/profile.tpl bulunamadı"
    test_summary
    exit $?
fi

rules="$(_aa_rules_only "$(cat "$PROFILE_TPL")")"
perm="$(_aa_perm_for "$rules" "$MEDIA")"

assert_contains "$perm" "w" "profile.tpl: 'shared/media/**' için yazma (w) kuralı var"
assert_contains "$perm" "r" "profile.tpl: 'shared/media/**' için okuma (r) izni var"
assert_contains "$perm" "k" "profile.tpl: 'shared/media/**' için kilit (k) izni var (flock/LOCK_EX)"
assert_not_contains "$perm" "x" "profile.tpl: 'shared/media/**' exec (x) İÇERMİYOR"
assert_not_contains "$perm" "m" "profile.tpl: 'shared/media/**' mmap-exec (m) İÇERMİYOR"
assert_not_contains "$perm" "l" "profile.tpl: 'shared/media/**' hard-link (l) İÇERMİYOR"

# Kural tam bir kez geçmeli (çift tanım = kopyala-yapıştır bozulması).
count="$(printf '%s\n' "$rules" | grep -cF "$MEDIA")"
assert_eq "$count" "1" "profile.tpl: 'shared/media/**' kuralı tam 1 kez tanımlı"

# Kapsam genişlemedi: media dışında shared/ ya da public_html/ altına yeni
# bir yazma kuralı sızmadı.
broad="$(_aa_broad_shared_write "$rules")"
assert_eq "$broad" "" "profile.tpl: shared/ ve public_html/ altında beklenmeyen geniş yazma kuralı yok"

# public_html salt-okunur kalmalı (kök neden burada: yazma release yolundan değil
# shared'dan geçer; public_html'e w eklemek AppArmor'un amacını bozar).
ph="$(_aa_perm_for "$rules" "${PREFIX}/public_html/**")"
assert_eq "$ph" "r" "profile.tpl: 'public_html/**' hâlâ yalnız 'r'"

# Kural, deny kurallarıyla ezilmemeli: shared/media'ya değen bir deny yok.
deny_hit="$(printf '%s\n' "$rules" | grep -E '^[[:space:]]*(audit[[:space:]]+)?deny[[:space:]].*shared' || true)"
assert_eq "$deny_hit" "" "profile.tpl: shared/ yoluna değen bir 'deny' kuralı yok (allow'u ezmez)"

test_summary
