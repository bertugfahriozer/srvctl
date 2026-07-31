#!/bin/bash
# read_credentials (core.sh) — O2 regresyonu: alanlar çağrılar arası SIZIYORDU.
#
# ESKİ KOD: read_kv_file "eksik anahtar → değişkene DOKUNMA" sözleşmesine
# sahiptir (bilerek — eksik bir anahtar önceki değeri EZMEMELİ). Ama
# read_credentials KENDİSİ çağrı başına alanları SIFIRLAMIYORDU. Sonuç:
# 'srvctl domain repair --all' gibi bir döngüde A domaini için okunan
# DB_PASS/REDIS_PASS/PHP_VERSION GLOBAL değişkenlerde kalıyordu; hemen
# ardından B domaini için read_credentials çağrılıp B'nin '.credentials'ı
# EKSİK/BOZUKSA (ör. henüz hardened değil, kısmi yazılmış, ya da saldırgan
# tarafından budanmış), o eksik alanlar için A'YA AİT ESKİ değerler SESSİZCE
# yeniden kullanılıyordu — pratikte "usr_b" parolası A'nın DB parolasıyla
# senkronlanmış GÖRÜNÜYORDU (kiracılar arası parola/ayar bulaşması, B
# domaini işletmecisi A'nın DB'sine A'nın parolasıyla giriş yapabilir HALE
# gelebiliyordu).
#
# DÜZELTME: read_credentials her çağrıda ÖNCE TÜM alanları boşa sıfırlar,
# SONRA dosyadan okur — eksik bir alan artık HER ZAMAN boş kalır, önceki
# çağrıdan miras KALMAZ (bkz. core.sh:read_credentials başlık yorumu).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# ═══ Domain A: TAM '.credentials' ═══
mkdir -p "${WEB_ROOT}/a.example.com"
cat > "${WEB_ROOT}/a.example.com/.credentials" <<'EOF'
DOMAIN=a.example.com
SAFE_NAME=a_example_com
WEB_USER=web_a_example_com
PHP_VERSION=8.2
DB_NAME=db_a_example_com
DB_USER=usr_a_example_com
DB_PASS=SecretA_DBPASS
REDIS_USER=redis_a_example_com
REDIS_PASS=SecretA_REDISPASS
REDIS_PREFIX=a_example_com
EOF

# ═══ Domain B: EKSİK/KISMİ '.credentials' — DB_PASS/REDIS_PASS/PHP_VERSION YOK ═══
mkdir -p "${WEB_ROOT}/b.example.com"
cat > "${WEB_ROOT}/b.example.com/.credentials" <<'EOF'
DOMAIN=b.example.com
SAFE_NAME=b_example_com
WEB_USER=web_b_example_com
DB_NAME=db_b_example_com
DB_USER=usr_b_example_com
EOF

# ── 1) Önce A okunur: A'nın kendi değerleri set olmalı (kontrol grubu) ──
read_credentials a.example.com 2>/dev/null
assert_eq "${DB_PASS:-}"      "SecretA_DBPASS"    "A: DB_PASS kendi dosyasından okundu"
assert_eq "${REDIS_PASS:-}"   "SecretA_REDISPASS" "A: REDIS_PASS kendi dosyasından okundu"
assert_eq "${PHP_VERSION:-}"  "8.2"               "A: PHP_VERSION kendi dosyasından okundu"

# ── 2) 'repair --all' döngüsünü simüle et: HEMEN ARDINDAN B okunur ──
#    B'nin dosyasında DB_PASS/REDIS_PASS/PHP_VERSION YOK — bu alanlar A'dan
#    SIZMAMALI, BOŞ kalmalı (O2 regresyonu tam olarak buydu).
read_credentials b.example.com 2>/dev/null
assert_eq "${DB_NAME:-}"      "db_b_example_com"  "B: kendi DB_NAME'i doğru okundu"
assert_eq "${DB_USER:-}"      "usr_b_example_com" "B: kendi DB_USER'ı doğru okundu"
assert_eq "${DB_PASS:-}"      ""                  "O2: B'de DB_PASS YOK → A'dan SIZMADI (boş)"
assert_eq "${REDIS_PASS:-}"   ""                  "O2: B'de REDIS_PASS YOK → A'dan SIZMADI (boş)"
assert_eq "${PHP_VERSION:-}"  ""                  "O2: B'de PHP_VERSION YOK → A'nın 8.2'si SIZMADI (boş)"
assert_eq "${REDIS_USER:-}"   ""                  "O2: B'de REDIS_USER YOK → A'dan SIZMADI (boş)"
assert_eq "${REDIS_PREFIX:-}" ""                  "O2: B'de REDIS_PREFIX YOK → A'dan SIZMADI (boş)"
# B'nin DOMAIN'i kendi değeri olmalı, A'nınki değil
assert_eq "${DOMAIN:-}"       "b.example.com"     "B: DOMAIN kendi değeri (A'dan sızmadı)"

# ── 3) Tersi sırayla da doğrula: önce B (eksik), sonra A (tam) — A'nın
#    alanları B'nin BOŞLUĞUNDAN etkilenmeden doğru dolmalı ──
read_credentials b.example.com 2>/dev/null
read_credentials a.example.com 2>/dev/null
assert_eq "${DB_PASS:-}"     "SecretA_DBPASS"    "ters sıra: B (eksik) sonrası A yine kendi DB_PASS'ini doğru okuyor"
assert_eq "${PHP_VERSION:-}" "8.2"               "ters sıra: B (eksik) sonrası A yine kendi PHP_VERSION'ını doğru okuyor"

# ── 4) Hiç '.credentials' olmayan bir domain: TÜM alanlar boş olmalı, önceki
#    (A'ya ait) değerler MİRAS KALMAMALI ──
mkdir -p "${WEB_ROOT}/c.example.com"
read_credentials c.example.com 2>/dev/null
assert_eq "${DB_PASS:-}"     "" "C: .credentials hiç yok → DB_PASS boş (A'dan miras kalmadı)"
assert_eq "${PHP_VERSION:-}" "" "C: .credentials hiç yok → PHP_VERSION boş (A'dan miras kalmadı)"
assert_eq "${DOMAIN:-}"      "" "C: .credentials hiç yok → DOMAIN boş (A'dan miras kalmadı)"

rm -rf "$WEB_ROOT"
test_summary
