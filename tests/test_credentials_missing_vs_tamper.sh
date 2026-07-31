#!/bin/bash
# KUSUR 2 regresyon testi (designwestgate.art HOST bulgusu): read_credentials
# hardened bir domainde '.credentials' EKSİK olduğunda ve GERÇEKTEN TAMPER
# olduğunda AYNI "(tamper). Okuma reddedildi." mesajını basıyordu. Üretimde
# dosya sadece hiç oluşturulmamıştı (eski bir srvctl sürümü) — operatör bunu
# görünce sunucusunda kötü niyetli bir müdahale olduğunu SANIRDI (yanlış
# alarm), ve bu gerçek bir tamper olayının ciddiyetini de aşındırırdı.
#
# Bu test üç şeyi kilitler:
#   1) EKSİK (.credentials hiç yok) + hardened → mesaj "eksik" der,
#      "tamper" DEMEZ, ve 'domain repair' öner.
#   2) TAMPER (.credentials var ama root-owned değil) + hardened → mevcut
#      "tamper" mesajı KORUNUR (bu durumda doğru).
#   3) _require_owned_or_warn'ın kendisi üç durumu da doğru kod ile ayırır:
#      0=devam (hardened değil), 1=tamper (var+bozuk), 2=eksik (yok).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

echo "== _require_owned_or_warn: 0/1/2 dönüş kodu ayrımı =="

mkdir -p "${WEB_ROOT}/missing.example"
missing_file="${WEB_ROOT}/missing.example/.credentials"   # HİÇ OLUŞTURULMADI
mkdir -p "${WEB_ROOT}/tampered.example"
tampered_file="${WEB_ROOT}/tampered.example/.credentials"
echo "DB_PASS=x" > "$tampered_file"   # macOS/CI'da kullanıcı-sahipli -> root-owned DEĞİL

# Marker YOK (henüz hardened değil) → ikisi de yalnız warn + 0 (devam)
rc=0; _require_owned_or_warn missing.example "$missing_file"  || rc=$?
assert_eq "$rc" "0" "hardened DEĞİLKEN + eksik dosya → 0 (devam, warn ile)"
rc=0; _require_owned_or_warn tampered.example "$tampered_file" || rc=$?
assert_eq "$rc" "0" "hardened DEĞİLKEN + bozuk sahiplik → 0 (devam, warn ile — migrate edilmemiş domain kırılmaz)"

# Marker VAR (hardened) → ayrım burada devreye girer
mkdir -p "${SRVCTL_STATE_DIR}/missing.example";  : > "${SRVCTL_STATE_DIR}/missing.example/hardened"
mkdir -p "${SRVCTL_STATE_DIR}/tampered.example"; : > "${SRVCTL_STATE_DIR}/tampered.example/hardened"

rc=0; _require_owned_or_warn missing.example "$missing_file" || rc=$?
assert_eq "$rc" "2" "hardened + dosya HİÇ YOK → 2 (eksik, tamper DEĞİL)"

rc=0; _require_owned_or_warn tampered.example "$tampered_file" || rc=$?
assert_eq "$rc" "1" "hardened + dosya VAR ama sahiplik bozuk → 1 (gerçek tamper)"

echo ""
echo "== read_credentials: doğru mesaj, doğru durum (uçtan uca) =="

err_missing="$( (read_credentials missing.example) 2>&1 1>/dev/null )"
rc=0; (read_credentials missing.example) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "eksik .credentials + hardened → read_credentials error() ile çıkar (exit 1)"
assert_contains "$err_missing" "eksik" "eksik durumda mesaj 'eksik' diyor"
assert_not_contains "$err_missing" "tamper" "eksik durumda mesaj 'tamper' DEMİYOR (yanlış alarm önlendi)"
assert_contains "$err_missing" "domain repair" "eksik durumda mesaj kurtarma yolunu (domain repair) öneriyor"

err_tampered="$( (read_credentials tampered.example) 2>&1 1>/dev/null )"
rc=0; (read_credentials tampered.example) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "gerçek tamper + hardened → read_credentials error() ile çıkar (exit 1)"
assert_contains "$err_tampered" "tamper" "gerçek tamper durumunda mesaj HÂLÂ 'tamper' diyor (regresyon yok)"
assert_not_contains "$err_tampered" "eksik" "gerçek tamper durumunda mesaj yanlışlıkla 'eksik' DEMİYOR"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
