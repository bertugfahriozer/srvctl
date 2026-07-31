#!/bin/bash
# Framework-farkında deploy yardımcıları: tespit (raporlama-amaçlı), göreli
# shared/ symlink derinliği ve shared/ bağlama güvenlik kapısı.
#
# _deploy_detect_framework SADECE raporlama/uyarı içindir — izin/izolasyon
# kararı operatörün 'domain add --framework' beyanına (.srvctl-meta) göre
# alınır; bu fonksiyonun dönüşü hiçbir güvenlik kararını etkilemez (bkz.
# lib/deploy.sh yorumu). Yine de yanlış tespit operatöre yanlış uyarı
# verdirir, bu yüzden 3 framework + 'none' vakası test edilir.
#
# _deploy_shared_rel: release_dir = base/releases/<id> olduğundan '../..'
# taban dizine çıkar; rel_path'teki HER '/' bir seviye daha derinliğe iner.
# KRİTİK REGRESYON VAKASI: Laravel 'bootstrap/cache' İKİ seviye derindir
# (bootstrap/cache -> 1 '/' -> depth=3 -> '../../../') ama 'shared/bootstrap-cache'
# adı TEK kelimedir — depth hesabı rel_path'in kendi derinliğine göre yapılır,
# hedef ad (shared_subdir) buna dahil DEĞİLDİR. Bu ayrım kolayca karıştırılıp
# yanlış '../../' üretilebilir (symlink kırık kalır, "No input file specified").
#
# _deploy_link_shared: _deploy_assert_safe_shared kapısı HER shared artefaktı
# (CI4 'writable', Laravel 'storage'/'bootstrap-cache', Symfony 'var') için
# ZORUNLUDUR — shared/<ad> bir symlink'e (örn. /etc) işaret ederse ve deploy
# bunun üzerine 'chown -R'/rm -rf release_target' yaparsa, web_user gerçek
# hedefi (örn. /etc) ele geçirebilir (yetki yükseltme). error() ile exit
# ettiğinden SUBSHELL'de çalıştırıp exit kodu yakalanır (aksi halde exit
# tüm test script'ini öldürür).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/deploy.sh"

# error() ile exit eden fonksiyonları güvenle çağırmak için: subshell'de
# çalıştır, exit kodu subshell'i öldürür — üst test script'i hayatta kalır.
_run_isolated() { ( "$@" ); }

# ═══════════════════════════ _deploy_detect_framework ═══════════════════════════
if declare -F _deploy_detect_framework >/dev/null 2>&1; then
    d="$(mktemp -d)"
    touch "${d}/artisan"
    assert_eq "$(_deploy_detect_framework "$d")" "laravel" "artisan -> laravel"
    rm -f "${d}/artisan"

    touch "${d}/spark"
    assert_eq "$(_deploy_detect_framework "$d")" "ci4" "spark -> ci4"
    rm -f "${d}/spark"

    mkdir -p "${d}/bin"
    touch "${d}/bin/console"
    assert_eq "$(_deploy_detect_framework "$d")" "symfony" "bin/console -> symfony"
    rm -rf "${d}/bin"

    assert_eq "$(_deploy_detect_framework "$d")" "none" "hiçbiri -> none"

    rm -rf "$d"
else
    echo "  SKIP: _deploy_detect_framework henüz yok"
fi

# ═══════════════════════════════ _deploy_shared_rel ═══════════════════════════════
if declare -F _deploy_shared_rel >/dev/null 2>&1; then
    # Tek seviye (CI4 'writable', Symfony 'var'): depth=2 -> '../../shared/<ad>'
    assert_eq "$(_deploy_shared_rel "writable" "writable")" "../../shared/writable" \
        "tek seviye (writable) -> ../../shared/writable"
    assert_eq "$(_deploy_shared_rel "storage" "storage")" "../../shared/storage" \
        "tek seviye (storage) -> ../../shared/storage"
    assert_eq "$(_deploy_shared_rel "var" "var")" "../../shared/var" \
        "tek seviye (var) -> ../../shared/var"

    # KRİTİK: Laravel bootstrap/cache İKİ seviye derinde -> bir '../' fazladan.
    assert_eq "$(_deploy_shared_rel "bootstrap/cache" "bootstrap-cache")" "../../../shared/bootstrap-cache" \
        "iki seviye (bootstrap/cache) -> ../../../shared/bootstrap-cache"

    # Üç seviye derinlik de tutarlı artmalı (a/b/c -> depth=5).
    assert_eq "$(_deploy_shared_rel "a/b/c" "x")" "../../../../shared/x" \
        "üç seviye derinlik (a/b/c) -> 4x '../'"
else
    echo "  SKIP: _deploy_shared_rel henüz yok"
fi

# ═══════════════════════════════ _deploy_link_shared ═══════════════════════════════
if declare -F _deploy_link_shared >/dev/null 2>&1 && declare -F _deploy_assert_safe_shared >/dev/null 2>&1; then
    base="${WEB_ROOT}/example.com"
    release="${base}/releases/20260101_000001"
    shared="${base}/shared"
    mkdir -p "$release" "$shared"

    # ── Mutlu yol: shared/ tarafı henüz yok, release içinde mevcut -> bootstrap edilir ──
    mkdir -p "${release}/storage/app"
    echo "veri" > "${release}/storage/app/dosya.txt"
    assert_ok _deploy_link_shared "$release" "$shared" "storage" "storage"
    ex() { [[ -e "$1" ]] && echo var || echo yok; }
    assert_eq "$(ex "${shared}/storage/app/dosya.txt")" "var" "release içeriği shared'e taşındı (bootstrap)"
    assert_eq "$(readlink "${release}/storage")" "../../shared/storage" "release/storage GÖRELİ symlink oldu (bkz. not)"
    # NOT: _deploy_shared_rel 'storage' (depth=2) için '../../shared/storage' üretir
    # (release_dir=base/releases/<id> KÖKÜNE göre); ln -sf ise CWD'ye göre DEĞİL
    # release_target'ın (release/storage) kendi konumuna göre çözülür — ikisi
    # birbiriyle TUTARLI olmalı: release/storage'tan '../../shared/storage' ARADA
    # bir seviye eksik kalırsa symlink kırık olur; bu yüzden gerçek dosya
    # erişimiyle (aşağıdaki satır) doğrulanır, yalnız string eşleşmesiyle değil.
    assert_eq "$(cat "${release}/storage/app/dosya.txt" 2>/dev/null)" "veri" \
        "symlink ÜZERİNDEN gerçek dosyaya erişilebiliyor (derinlik doğru)"

    # ── shared/ hedefi SYMLINK ise REDDEDİLİR (yetki yükseltme kapısı) ──
    base2="${WEB_ROOT}/evil.example.com"
    release2="${base2}/releases/20260101_000001"
    shared2="${base2}/shared"
    mkdir -p "$release2" "$shared2"
    ln -s /etc "${shared2}/writable"   # saldırgan: shared/writable -> /etc
    mkdir -p "${release2}/writable"
    assert_fail _run_isolated _deploy_link_shared "$release2" "$shared2" "writable" "writable"
    assert_eq "$(ex "${release2}/writable")" "var" \
        "reddedilince release içindeki orijinal dizin SİLİNMEDİ (rm -rf tetiklenmedi)"

    # ── shared/ hedefi ZATEN VARSA ve symlink'se de aynı şekilde reddedilir ──
    base3="${WEB_ROOT}/evil2.example.com"
    release3="${base3}/releases/20260101_000001"
    shared3="${base3}/shared"
    mkdir -p "$release3" "$shared3"
    ln -s /etc "${shared3}/bootstrap-cache"
    assert_fail _run_isolated _deploy_link_shared "$release3" "$shared3" "bootstrap/cache" "bootstrap-cache"

    # ── Ne shared/ ne release/ tarafında hedef var -> 2 döner (atlanır, hata değil) ──
    base4="${WEB_ROOT}/yok.example.com"
    release4="${base4}/releases/20260101_000001"
    shared4="${base4}/shared"
    mkdir -p "$release4" "$shared4"
    _deploy_link_shared "$release4" "$shared4" "storage" "storage" >/dev/null 2>&1
    rc_missing=$?
    assert_eq "$rc_missing" "2" "ikisi de yoksa 2 döner (atlanır, error() TETİKLENMEZ)"
else
    echo "  SKIP: _deploy_link_shared / _deploy_assert_safe_shared henüz yok"
fi

rm -rf "$WEB_ROOT"
test_summary
