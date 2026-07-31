#!/bin/bash
# read_kv_file (core.sh) — '^KEY=' anchor'ının zehirlenme direnci (O1).
#
# O1 DÜZELTMESİ (denetim DALGA 4, bkz. core.sh:read_kv_file başlık yorumu):
# eski kod yorumda '^KEY=' diyordu ama fiili eşleşme 'grep -F "${k}="' idi —
# SATIR BAŞINA SABİTLENMEMİŞTİ. write_meta() ise anahtarı SİLERKEN
# 'grep -v "^${key}="' ile SABİTLİ arıyordu (okuma/yazma ASİMETRİSİ). Web-
# yazılabilir (henüz hardened olmayan) bir meta/credentials dosyasına
# saldırgan şu satırlardan birini eklerse:
#   ' KEY=değer'      (baştaki boşluk)
#   '#KEY=değer'       (yorum satırı gibi görünen ama gerçekte okunan satır)
#   'KEY_alt=değer'    (anahtar önekiyle başlayan FARKLI bir anahtar)
# eski davranışta bu satırlar YİNE okunuyordu (grep -F satır içinde HERHANGİ
# yerde arar) ama write_meta onu SİLEMİYORDU (anchor'lı grep -v eşleşmiyor)
# — 'harden-fs --apply' dosyayı root:root yapsa bile İÇERİK temizlenmediği
# için zehirlenme KALICI oluyordu. Bu test üç zehirlenme satırının da ARTIK
# HİÇ eşleşmediğini (read_kv_file tarafında) ve yalnız GERÇEK '^KEY='
# satırının okunduğunu doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# ═══ 1) Baştaki boşluk: ' KEY=değer' okunmamalı ═══
f1="${WEB_ROOT}/leading_space.kv"
cat > "$f1" <<'EOF'
 FRAMEWORK=laravel
EOF
unset FRAMEWORK
read_kv_file "$f1" FRAMEWORK
assert_eq "${FRAMEWORK:-UNSET}" "UNSET" "baştaki boşluklu ' KEY=değer' satırı OKUNMADI (anchor satır başına sabit)"

# ═══ 2) '#' önekli satır: yorum gibi görünen ama 'KEY=' içeren satır okunmamalı ═══
f2="${WEB_ROOT}/hash_prefix.kv"
cat > "$f2" <<'EOF'
#FRAMEWORK=laravel
EOF
unset FRAMEWORK
read_kv_file "$f2" FRAMEWORK
assert_eq "${FRAMEWORK:-UNSET}" "UNSET" "'#KEY=değer' satırı OKUNMADI"

# ═══ 3) Anahtar-önekli FARKLI anahtar: 'KEY_alt=değer' 'KEY' için eşleşmemeli ═══
f3="${WEB_ROOT}/key_alt.kv"
cat > "$f3" <<'EOF'
FRAMEWORK_alt=poisoned
EOF
unset FRAMEWORK
read_kv_file "$f3" FRAMEWORK
assert_eq "${FRAMEWORK:-UNSET}" "UNSET" "'FRAMEWORK_alt=değer' 'FRAMEWORK' anahtarıyla EŞLEŞMEDİ"

# ═══ 4) Kontrol grubu: gerçek '^KEY=' satırı doğru okunur ═══
f4="${WEB_ROOT}/valid.kv"
cat > "$f4" <<'EOF'
FRAMEWORK=laravel
EOF
unset FRAMEWORK
read_kv_file "$f4" FRAMEWORK
assert_eq "${FRAMEWORK:-UNSET}" "laravel" "gerçek '^FRAMEWORK=' satırı doğru okundu (kontrol grubu — anchor'ın kendisi kırık değil)"

# ═══ 5) ÜÇÜ BİRDEN aynı dosyada, GERÇEK satırla karışık — yalnız gerçek satır kazanır ═══
# Fixture sırası KASITLI: zehirli satırlar gerçek satırdan ÖNCE gelir, yani
# 'head -1' bir anchor regresyonunda YANLIŞLIKLA "doğru" sonucu vermez —
# zehirli satırlardan biri eşleşseydi (regresyon), head -1 ONU seçerdi.
f5="${WEB_ROOT}/mixed.kv"
cat > "$f5" <<'EOF'
 FRAMEWORK=leading_space_poison
#FRAMEWORK=hash_poison
FRAMEWORK_alt=alt_key_poison
FRAMEWORK=laravel
EOF
unset FRAMEWORK
read_kv_file "$f5" FRAMEWORK
assert_eq "${FRAMEWORK:-UNSET}" "laravel" "karışık zehirli+gerçek dosyada YALNIZ '^FRAMEWORK=' satırı okundu"

# ═══ 6) write_meta/read_kv_file SİMETRİSİ: write_meta bu zehirli satırları
#    da temizleyebiliyor mu? (O1 yorumundaki asimetri düzeltmesinin ikinci
#    yarısı — okuma/yazma AYNI anchor'ı kullanmalı) ═══
mkdir -p "${WEB_ROOT}/example.com"
meta="${WEB_ROOT}/example.com/.srvctl-meta"
cat > "$meta" <<'EOF'
 FRAMEWORK=leading_space_poison
#FRAMEWORK=hash_poison
FRAMEWORK_alt=alt_key_poison
FRAMEWORK=laravel
EOF
write_meta example.com FRAMEWORK symfony
content="$(cat "$meta")"
assert_contains   "$content" "FRAMEWORK=symfony" "write_meta yeni değeri yazdı"
assert_not_contains "$content" "FRAMEWORK=laravel" "write_meta eski GERÇEK '^FRAMEWORK=' satırını sildi (anchor'lı grep -v ile simetrik)"
assert_eq "$(grep -c '^FRAMEWORK=' "$meta")" "1" "write_meta sonrası TEK bir '^FRAMEWORK=' satırı var (duplicate yok)"
# Zehirli satırlar write_meta'nın hedefi DEĞİL (onlar zaten hiç okunmuyor,
# 'anchor'lı grep -v "^FRAMEWORK="' onlara dokunmaz) — dosyada ölü/zararsız
# satırlar olarak kalmaları BEKLENEN davranıştır (harden-fs --apply /
# _meta_rewrite_whitelist ayrı bir katmanda bunları TAMAMEN temizler,
# bkz. tests/test_meta.sh ve lib/security.sh:_meta_rewrite_whitelist).
unset FRAMEWORK
read_kv_file "$meta" FRAMEWORK
assert_eq "${FRAMEWORK:-UNSET}" "symfony" "write_meta sonrası read_kv_file GÜNCEL değeri okuyor (zehirli satırlar hâlâ etkisiz)"

rm -rf "$WEB_ROOT"
test_summary
