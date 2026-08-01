#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

tpl="${WEB_ROOT}/v.tpl"
printf 'server_name {{DOMAIN}};\nlocation ~ /{{PATHS}} { return 403; }\n' > "$tpl"

# ── Temiz değerler: substitution çalışır, çıktı doğru ──
out="$(render_template "$tpl" DOMAIN=example.com PATHS='login|admin')"
assert_contains "$out" "server_name example.com;" "temiz DOMAIN yerleşti"
assert_contains "$out" "/login|admin {"           "temiz PATHS yerleşti"
assert_not_contains "$out" "{{DOMAIN}}"           "token kalmadı"

# ── newline içeren değer: render_template EXIT eder (error) ──
# error exit ettiği için ALT-KABUKTA çalıştır; non-zero exit beklenir.
bad_nl="$(printf 'evil\ninjected')"
assert_fail bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="evil
injected"
'
# daha net: değişkenle geçir
assert_fail env BADVAL="$bad_nl" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="$BADVAL"
'

# ── CR içeren değer de reddedilir ──
bad_cr="$(printf 'evil\rinjected')"
assert_fail env BADVAL="$bad_cr" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" PATHS="$BADVAL"
'

# ── newline reddi çıktı üretmeden olur (dosyaya yazılmaz) ──
out2="$(env BADVAL="$bad_nl" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="$BADVAL"
' 2>/dev/null)" || true
assert_not_contains "$out2" "injected" "newline değeri çıktıya sızmadı"


# ═══════════════════════════════════════════════════════════════
# GERÇEK ÜRETİM SUNUCUSUNDA İZOLE EDİLEN KUSUR (A/B/C testi): 'srvctl cron
# add ... --command="echo bir && echo iki"' EXIT=1 ile 'beslenmeyen token
# kaldı ({{CRON_COMMAND}})' veriyordu; '&' İÇERMEYEN komutlar sorunsuzdu.
# Kök neden analizi (sed'in DEĞİŞTİRME tarafında '&' = "eşleşen metnin
# tamamı") bu fonksiyon İÇİN doğrulanmadı (render_template repo tarihi
# boyunca hiç sed KULLANMADI), ama render_template YİNE DE "değeri bir
# yerine-koyma motoruna teslim etme" riskine karşı SAĞLAMLAŞTIRILDI (bkz.
# core.sh'taki fonksiyon başlığı: artık awk index()/substr() ile SAF
# bayt-bayt değiştirme yapılıyor, hiçbir yorumlayıcıya değer teslim
# edilmiyor). AŞAĞIDAKİ FIXTURE'LAR bu garantiyi KİLİTLER: değer İÇİNDEKİ
# HİÇBİR karakter (özellikle '&', ama '\', '|', '/', '%', tırnaklar, '$',
# backtick VE bunların kombinasyonları) render sonrası ÇIKTIDA
# YORUMLANMAMALI/DEĞİŞMEMELİDİR — BİREBİR aynı bayt dizisi olarak
# görünmelidir.
# ═══════════════════════════════════════════════════════════════
tpl2="${WEB_ROOT}/mutasyon.tpl"
printf 'DEGER=[{{V}}]\n' > "$tpl2"

_assert_literal_roundtrip() {
    local value="$1" label="$2" out
    out=$(render_template "$tpl2" "V=${value}")
    assert_contains "$out" "DEGER=[${value}]" "birebir korunuyor: ${label}"
    assert_not_contains "$out" "{{V}}" "leftover token yok: ${label}"
}

# ÜRETİMDE İZOLE EDİLEN TAM SENARYO (A): tetikleyici komutun kendisi.
_assert_literal_roundtrip 'echo bir && echo iki' "üretim A senaryosu ('&&' iceren komut)"
# B/C senaryoları (zaten çalışıyordu — regresyon kilidi için burada da var).
_assert_literal_roundtrip 'date +%Y'              "üretim B senaryosu ('%' iceren komut)"
_assert_literal_roundtrip 'echo merhaba'           "üretim C senaryosu (düz komut)"

# Tekil kritik karakterler.
_assert_literal_roundtrip 'a & b'                  "tek '&'"
_assert_literal_roundtrip 'a && b'                 "'&&'"
_assert_literal_roundtrip 'a \ b'                  "tek ters eğik çizgi"
_assert_literal_roundtrip 'a \\ b'                 "çift ters eğik çizgi"
_assert_literal_roundtrip 'a | b'                  "boru (pipe)"
_assert_literal_roundtrip 'a/b/c'                  "eğik çizgi (sed ayracı adayı)"
_assert_literal_roundtrip 'a;b'                    "noktalı virgül"
_assert_literal_roundtrip '%s %d %%'               "yüzde/format specifier'ları"
_assert_literal_roundtrip "tek tırnak ' içeride"    "tek tırnak"
_assert_literal_roundtrip 'çift tırnak " içeride'   "çift tırnak"
_assert_literal_roundtrip 'dolar $HOME degisken'    "dolar işareti"
_assert_literal_roundtrip 'backtick `date` komut'   "backtick"
_assert_literal_roundtrip 'wp-login\.php|wp-admin'  "nginx hassas-yol regex deseni (backslash+pipe)"

# Kombinasyon: yukarıdaki KARAKTERLERİN TAMAMI TEK bir değerde.
_assert_literal_roundtrip "kombinasyon: a && b | c \\ d \$HOME \`x\` 'y' \"z\" % / ; son" \
    "tüm kritik karakterlerin kombinasyonu"

# ── Aynı token, template içinde BİRDEN FAZLA yerde geçiyorsa HEPSİ değişmeli ──
tpl3="${WEB_ROOT}/tekrar.tpl"
printf '{{X}}-{{X}}-{{X}}\n' > "$tpl3"
out3=$(render_template "$tpl3" 'X=a & b')
assert_eq "$out3" "a & b-a & b-a & b" "aynı token'ın tüm tekrarları '&' içeren değerle doğru değişiyor"

rm -rf "$WEB_ROOT"
test_summary
