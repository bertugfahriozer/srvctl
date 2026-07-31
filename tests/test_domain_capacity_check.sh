#!/bin/bash
# _domain_capacity_check / _domain_capacity_read_profile (lib/domain.sh) —
# 100-domain kapasite planlayıcısı: RAM taahhüdü aşılırsa UYARIR, ASLA
# ENGELLEMEZ (overcommit meşru bir operatör tercihidir; her domain zaten
# cgroups MemoryMax ile ayrı ayrı sınırlanıyor — bkz. dosya başı yorumu).
#
# BİLİNEN SINIRLAMA (bu dosyada bilerek dokümante ediliyor —
# tests/test_domain_resources_preserve.sh'taki SRVCTL_SYSTEMD_DIR "seam
# probe" deseniyle AYNI ruh): _domain_capacity_check '/proc/meminfo'yu
# HARDCODED okur, SRVCTL_SYSTEMD_DIR gibi bir test-seam'i YOK. macOS
# geliştirme kutusunda (ve '/proc' olmayan her ortamda) bu dosya hiç
# yoktur — fonksiyon '[[ -r /proc/meminfo ]] || return 0' ile SESSİZCE
# erken döner. Bu test iki moda ADAPTİF davranır:
#   • /proc/meminfo OKUNAMIYORSA (macOS, çoğu container): yalnız bu
#     fail-open sözleşmeyi doğrular (hiç çökmez, hiç engellemez, çıktı
#     üretmez) — GERÇEK eşik/uyarı mantığı bu ortamda test EDİLEMİYOR.
#   • /proc/meminfo OKUNABİLİYORSA (gerçek Linux): gerçek fiziksel RAM'i
#     bilmeden de deterministik bir "aşım" senaryosu üretmek için yeteri
#     kadar (30×) 'heavy' profilli sahte domain eklenir — 30×27648MB ≈
#     829GB, gerçekçi hiçbir sunucunun fiziksel RAM'ini AŞMAMASI
#     beklenmez; bu sayede gerçek MemTotal değerine bakmadan "uyarı
#     verildi ama ENGELLENMEDİ" iddiası güvenle doğrulanabilir.
#
# _domain_capacity_read_profile (yumuşak/warn-only kopya) TAMAMEN portable
# ve /proc/meminfo'ya bağlı DEĞİL — ana regresyon (tamper durumunda error()
# ile EXIT ETMEMESİ, _domain_read_resource_profile'ın SERT kopyasından
# FARKLI olması) her platformda tam kapsamlı test edilir.
#
# PARALEL AGENT NOTU: lib/domain.sh şu anda db-redis-specialist tarafından
# değiştiriliyor — fonksiyonlar yoksa/adı değiştiyse SKIP edilir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
source "${REPO_ROOT}/lib/domain.sh"

_run_isolated() { ( "$@" ); }
mk_domain() {
    # Sahte domain: list_all_domains'in tanıması için .credentials marker'ı yeterli.
    mkdir -p "${WEB_ROOT}/${1}"
    : > "${WEB_ROOT}/${1}/.credentials"
    [[ -n "${2:-}" ]] && write_meta "$1" RESOURCE_PROFILE "$2"
}

# ═══════════════ _domain_capacity_read_profile — tamamen portable ═══════════════
if declare -F _domain_capacity_read_profile >/dev/null 2>&1; then
    mk_domain cr-none.com
    mk_domain cr-micro.com micro
    mk_domain cr-garbage.com
    write_meta cr-garbage.com RESOURCE_PROFILE 'yok-boyle-profil'

    assert_eq "$(_domain_capacity_read_profile cr-none.com 2>/dev/null)"    "standard" "meta yok → standard"
    assert_eq "$(_domain_capacity_read_profile cr-micro.com 2>/dev/null)"   "micro"    "geçerli profil aynen döner"
    assert_eq "$(_domain_capacity_read_profile cr-garbage.com 2>/dev/null)" "standard" "whitelist dışı → standard"

    # Hardened + root-owned OLMAYAN meta (tamper) → _domain_read_resource_profile'IN
    # AKSİNE error() ile EXIT ETMEZ: yalnız warn + 'standard'. Kapasite tahmini bir
    # güvenlik sınırı DEĞİL (salt bilgi amaçlı); BAŞKA bir domainin tamper'ı YENİ
    # domain ekleme akışını ASLA engellememeli (bkz. dosya başı yorumu).
    mk_domain cr-hardened.com heavy
    mkdir -p "${SRVCTL_STATE_DIR}/cr-hardened.com"
    touch "${SRVCTL_STATE_DIR}/cr-hardened.com/hardened"
    assert_ok _run_isolated _domain_capacity_read_profile cr-hardened.com
    assert_eq "$(_domain_capacity_read_profile cr-hardened.com 2>/dev/null)" "standard" \
        "hardened+tampered meta → error() DEĞİL, warn + standard'a düşer"
else
    echo "  SKIP: _domain_capacity_read_profile henüz yok (lib/domain.sh paralel değişiyor olabilir)"
fi

# ═══════════════ _domain_capacity_check ═══════════════
if declare -F _domain_capacity_check >/dev/null 2>&1; then
    if [[ ! -r /proc/meminfo ]]; then
        # ── /proc/meminfo YOK (macOS/çoğu container): yalnız fail-open sözleşme ──
        assert_ok _run_isolated _domain_capacity_check standard
        out="$(_domain_capacity_check standard 2>&1)"
        assert_eq "$out" "" "/proc/meminfo okunamıyorsa sessizce döner (çıktı yok, engelleme yok)"
        echo "  SKIP: gerçek eşik/uyarı senaryosu — bu ortamda /proc/meminfo yok (bkz. dosya başı notu)"
    else
        # ── /proc/meminfo VAR (gerçek Linux): deterministik aşım senaryosu ──
        i=1
        while [[ "$i" -le 30 ]]; do
            mk_domain "cap-heavy-${i}.example.com" heavy
            i=$((i + 1))
        done

        DOMAIN_ISOLATED_FPM=false
        out_over="$(_domain_capacity_check heavy 2>&1)"
        rc_over=0; _run_isolated _domain_capacity_check heavy >/dev/null 2>&1 || rc_over=$?
        assert_eq "$rc_over" "0" "aşım senaryosunda BİLE fonksiyon 0 döner (ASLA engellemez)"
        assert_contains "$out_over" "AŞIYOR" "30×heavy domain gerçekçi hiçbir sunucu RAM'ini aşmadan geçemez → uyarı üretilir"
        assert_contains "$out_over" "Kapasite uyarısı" "uyarı başlığı üretiliyor"
        assert_not_contains "$out_over" "per-domain FPM master" \
            "DOMAIN_ISOLATED_FPM=false iken FPM master ek yükü satırı YOK"

        DOMAIN_ISOLATED_FPM=true
        out_over_isolated="$(_domain_capacity_check heavy 2>&1)"
        assert_contains "$out_over_isolated" "per-domain FPM master" \
            "DOMAIN_ISOLATED_FPM=true iken FPM master ek yükü satırı VAR"
        DOMAIN_ISOLATED_FPM=true
    fi
else
    echo "  SKIP: _domain_capacity_check henüz yok (lib/domain.sh paralel değişiyor olabilir)"
fi

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
