#!/bin/bash
# templates/** — 'TOKENS:' başlık yorumu ile GERÇEK '{{...}}' kullanımı
# BİREBİR eşleşiyor mu (statik tarayıcı).
#
# HATA SINIFI (bu oturumda ÜÇ KEZ tekrarlandı — bkz. rapor): bir şablona
# yeni bir '{{TOKEN}}' eklenir (ör. DENY_DIRS, IO_WEIGHT, DOMAIN_ROOT), ama
# onu BESLEYEN lib/*.sh fonksiyonu (render_template çağrısı) güncellenmeyi
# UNUTULUR. render_template (core.sh) beslenmeyen bir token'ı SESSİZCE
# atlar ve literal '{{TOKEN}}' metnini ÇIKTIDA BIRAKIR (hata YOK) — sonuç:
# canlıda bozuk bir nginx vhost'u / systemd unit'i / php-fpm pool'u SESSİZCE
# üretilir (ör. 'ReadWritePaths=-{{DOMAIN_ROOT}}' gibi literal bir satır).
# ops-infra DALGA 5'te her şablonun başına, o şablonun BEKLEDİĞİ tüm
# token'ları listeleyen bir 'TOKENS:' yorumu ekledi (native yorum karakteri
# dosyaya göre değişir: '#', ';', '<!-- -->' — ama 'TOKENS:' anahtar kelimesi
# SABİT, bkz. grep -rn "TOKENS:" templates/).
#
# BU TEST: her 'templates/**' dosyası için (a) 'TOKENS:' yorumunda beyan
# edilen liste ile (b) dosyadaki GERÇEK '{{...}}' kullanımının kümesini
# çıkarır ve BİREBİR eşleştiğini doğrular. lib/domain.sh'taki RUNTIME
# guard'ı olan '_domain_assert_no_leftover_tokens' (render SONRASI, tek bir
# domain'in tek bir çalıştırması için kontrol eder) ile TAMAMLAYICIDIR — bu
# test STATİK olarak, hiçbir render hiç ÇALIŞTIRILMADAN, TÜM şablonları
# TEK SEFERDE tarar (bkz. lib/domain.sh:_domain_assert_no_leftover_tokens
# başlık yorumu).
#
# KENDİ KENDİNİ DOĞRULAMA (zorunlu — bkz. CLAUDE.md/proje kuralı): tarayıcı
# bozulursa bu test sessizce hep PASS vermemeli. Sonda bilerek BOZUK prob
# fixture'ları (eksik token + fazladan/beslenmeyen kullanım + çok satırlı
# 'TOKENS:' devamı) eklenir ve dedektörün bunları GERÇEKTEN yakaladığı
# assert edilir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

TEMPLATES_DIR="${REPO_ROOT}/templates"

# ─── 'TOKENS:' yorumunda beyan edilen token listesini çıkar ───
# 'TOKENS:' işaretinden sonraki metin + dosyanın GERİ KALANI tek bir kelime
# akışına dönüştürülür (çok satırlı devamları — ör. cgroups/domain.slice.tpl
# — yakalamak için); yorum işaretleri/dekorasyon ('#', ';', '<!--', '-->')
# boşluğa çevrilir. Kelime kelime taranır: TÜMÜ BÜYÜK HARF+RAKAM+ALT_ÇİZGİ
# olan İLK ARDIŞIK diziyi al, İLK UYMAYAN kelimede DUR. Bu tek kural hem
# aynı satırdaki açıklama sonekini (ör. maintenance.html: 'DOMAIN —
# Besleyen: ...') hem de SONRAKİ satırlardaki gerçek 'Besleyen: ...'
# paragrafını doğal olarak eler (ikisi de küçük harf/noktalama içerir).
_tpl_declared_tokens() {
    local file="$1"
    local rest
    rest=$(awk '
        BEGIN{found=0}
        {
            if (!found) {
                idx = index($0, "TOKENS:")
                if (idx > 0) { found=1; print substr($0, idx+7); next }
            } else {
                print
            }
        }
    ' "$file")
    rest="${rest//#/ }"; rest="${rest//;/ }"; rest="${rest//<!--/ }"; rest="${rest//-->/ }"
    local w
    local -a tokens=()
    for w in $rest; do
        if [[ "$w" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            tokens+=("$w")
        else
            break
        fi
    done
    [[ "${#tokens[@]}" -gt 0 ]] && printf '%s\n' "${tokens[@]}" | sort -u
    return 0
}

# ─── Dosyadaki GERÇEK '{{TOKEN}}' kullanımlarını çıkar ───
_tpl_used_tokens() {
    grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$1" 2>/dev/null \
        | sed -E 's/^\{\{//; s/\}\}$//' | sort -u
}

# PREDİKAT: 0=beyan edilen == kullanılan (birebir), 1=uyuşmazlık
_tpl_tokens_consistent() {
    [[ "$(_tpl_declared_tokens "$1")" == "$(_tpl_used_tokens "$1")" ]]
}

# ═══════════════════════════════════════════════════════════════
# ASIL TARAMA: templates/** altındaki TÜM dosyalar
# ═══════════════════════════════════════════════════════════════
findings=""
while IFS= read -r f; do
    if ! _tpl_tokens_consistent "$f"; then
        rel="${f#"${REPO_ROOT}"/}"
        d="$(_tpl_declared_tokens "$f" | tr '\n' ' ')"
        u="$(_tpl_used_tokens "$f" | tr '\n' ' ')"
        findings+="${rel}  (TOKENS: [${d}]  KULLANILAN: [${u}])"$'\n'
    fi
done < <(find "$TEMPLATES_DIR" -type f | sort)

assert_eq "$findings" "" "templates/** — TÜM dosyalarda 'TOKENS:' beyanı GERÇEK '{{...}}' kullanımıyla birebir eşleşiyor"
[[ -n "$findings" ]] && printf '%s' "$findings" >&2

# ═══════════════════════════════════════════════════════════════
# KENDİ KENDİNİ DOĞRULAMA — tarayıcı bozulursa SESSİZCE hep PASS vermemeli.
# Dört prob: (a) eksik kullanım, (b) beslenmeyen/fazladan kullanım,
# (c) doğru şablon (false-positive ÜRETMEMELİ), (d) çok satırlı 'TOKENS:'
# devamı (false-positive ÜRETMEMELİ — cgroups/vhost deseni).
# ═══════════════════════════════════════════════════════════════
probe_dir="$(mktemp -d)"

# (a) TOKENS'ta beyan edilen 'BAR' hiç KULLANILMIYOR (unutulmuş besleme —
#     ya da tam tersi, DALGA 5'in kapattığı sınıfın AYNASI: burada token
#     beslenmiş ama şablon ondan HİÇ bahsetmiyor, yine de tutarsızlık).
cat > "${probe_dir}/missing_usage.tpl" <<'EOF'
# TOKENS: FOO BAR
echo {{FOO}}
EOF

# (b) DALGA 5'in TAM kapattığı sınıf: şablon '{{BAZ}}' KULLANIYOR ama
#     'TOKENS:' yorumunda BEYAN EDİLMEMİŞ (besleyen fonksiyon güncellenmemiş
#     olabilir — render_template BAZ'ı SESSİZCE atlar, literal '{{BAZ}}' kalır).
cat > "${probe_dir}/undeclared_usage.tpl" <<'EOF'
# TOKENS: FOO
echo {{FOO}} {{BAZ}}
EOF

# (c) Kontrol grubu: TAM eşleşen, doğru şablon.
cat > "${probe_dir}/ok.tpl" <<'EOF'
# TOKENS: FOO BAR
echo {{FOO}} {{BAR}}
EOF

# (d) Kontrol grubu: çok satırlı 'TOKENS:' devamı (cgroups/domain.slice.tpl
#     deseni) — YANLIŞ POZİTİF üretmemeli.
cat > "${probe_dir}/multiline.tpl" <<'EOF'
# TOKENS: FOO BAR
#         BAZ
# Besleyen: probe (bu satır token listesinin PARÇASI değil, ayrıştırıcı
# burada durmalı).
echo {{FOO}} {{BAR}} {{BAZ}}
EOF

probe_findings=""
while IFS= read -r f; do
    _tpl_tokens_consistent "$f" || probe_findings+="$(basename "$f") "
done < <(find "$probe_dir" -type f | sort)

assert_contains     "$probe_findings" "missing_usage.tpl"     "dedektör: TOKENS'ta beyan edilip HİÇ KULLANILMAYAN token'ı yakalıyor"
assert_contains     "$probe_findings" "undeclared_usage.tpl"  "dedektör: DALGA 5 sınıfı — TOKENS'ta BEYAN EDİLMEYEN ama KULLANILAN token'ı yakalıyor"
assert_not_contains "$probe_findings" "ok.tpl"                "doğru/eşleşen şablon için YANLIŞ POZİTİF üretilmiyor"
assert_not_contains "$probe_findings" "multiline.tpl"         "çok satırlı 'TOKENS:' devamı doğru ayrıştırılıyor (YANLIŞ POZİTİF yok)"

rm -rf "$probe_dir"
test_summary
