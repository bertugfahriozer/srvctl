#!/bin/bash
# resource_profile_load (lib/core.sh) — cgroups slice + FPM pool boyutlandırmasının
# TEK doğruluk kaynağı. Bu oturumda eklendi, HİÇ testi yoktu.
#
# NEDEN VAR: eskiden pool.conf.tpl'nin (pm.max_children=16, memory_limit=256M)
# hardcoded değerleri ile lib/domain.sh:_domain_cgroups_defaults'ın hardcoded
# "4096M 4608M 512M 200" sabiti İKİ AYRI KAYNAKTI — biri değişip diğeri
# unutulunca (drift) domain'in gerçek FPM worker tavanı ile cgroups
# MemoryMax'i SESSİZCE ayrışıyor, ya gereksiz throttle ya da worker havuzunun
# cgroups limitini aşıp OOM-kill yemesi riski doğuyordu. Artık conf/
# resource-profiles.conf TEK kaynak; MemoryHigh/Max/SwapMax + pm.start/
# min_spare/max_spare_servers HER OKUMADA buradan türetiliyor. Bu test:
#   1) 4 gerçek profilin türetilmiş değerlerini conf dosyasındaki 5 alana
#      (profil:pm_mode:max_children:memory_limit_mb:tasks_max) karşı sabitler
#      — conf dosyası elle değiştirilirse (drift) bu test KIRILIR ve
#      tests/test_domain_resources_preserve.sh'taki beklentilerin de
#      güncellenmesi gerektiğini hatırlatır.
#   2) Bilinmeyen/boş profil adının 'standard'a düşüp warn ürettiğini,
#   3) conf dosyası HİÇ YOKSA dahili fail-closed güvenlik ağının (ondemand:
#      8:256:120 — 'standard' sözleşmesiyle BİREBİR) devreye girdiğini,
#   4) Tek bir alanı bozuk/saldırgan (harf, negatif, eksik) bir profil
#      satırının o alan için AYRI AYRI fail-closed varsayılana düştüğünü
#      (bir alanın bozulması diğerlerini etkilememeli),
#   5) pm.min_spare/start/max_spare_servers sıralamasının HER PROFİLDE
#      (gerçek 4 profil + sınır-değer max_children=1/2 sentetik profiller)
#      'min ≤ start ≤ max_spare ≤ max_children' INVARIANT'ını KORUDUĞUNU
#      doğrular — php-fpm bu sıralama ihlal edilirse 'php-fpm -t' başarısız
#      olur (status=78/CONFIG) ve TÜM pool devre dışı kalır (bkz. .claude/
#      ubuntu-compat.md).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# pm.min/start/max_spare_servers sıralama invariant'ı (PREDİKAT).
_inv_ok() {
    local min="$1" start="$2" max_spare="$3" max_children="$4"
    (( min <= start && start <= max_spare && max_spare <= max_children ))
}
inv_check() { _inv_ok "$@" && echo ok || echo bad; }

# ═══════════════ 1) Gerçek 4 profilin türetilmiş değerleri (tablo) ═══════════════
# NOT: bash 3.2 (macOS varsayılan /bin/bash) 'declare -A' (assoc array)
# DESTEKLEMEZ — case tabanlı bir "beklenen değerler" tablosu kullanılıyor.
_expected_for_profile() {
    # çıktı: mode:maxch:high:max:swap:tasks:min:start:spare
    case "$1" in
        micro)     echo "ondemand:4:512:576:64:60:1:1:2" ;;
        standard)  echo "ondemand:8:2048:2304:256:120:1:2:4" ;;
        ecommerce) echo "dynamic:16:8192:9216:1024:300:2:4:8" ;;
        heavy)     echo "dynamic:32:24576:27648:3072:500:4:8:16" ;;
    esac
}

for p in micro standard ecommerce heavy; do
    resource_profile_load "$p"
    exp_mode="" exp_maxch="" exp_high="" exp_max="" exp_swap="" exp_tasks="" exp_min="" exp_start="" exp_spare=""
    IFS=: read -r exp_mode exp_maxch exp_high exp_max exp_swap exp_tasks exp_min exp_start exp_spare \
        <<< "$(_expected_for_profile "$p")"

    assert_eq "$RES_PROFILE"          "$p"           "${p}: RES_PROFILE"
    assert_eq "$RES_PM_MODE"          "$exp_mode"    "${p}: pm_mode"
    assert_eq "$RES_MAX_CHILDREN"     "$exp_maxch"   "${p}: max_children"
    assert_eq "$RES_MEMORY_HIGH_MB"   "$exp_high"    "${p}: MemoryHigh (MB)"
    assert_eq "$RES_MEMORY_MAX_MB"    "$exp_max"     "${p}: MemoryMax (MB)"
    assert_eq "$RES_MEMORY_SWAP_MB"   "$exp_swap"    "${p}: MemorySwapMax (MB)"
    assert_eq "$RES_MEMORY_HIGH"      "${exp_high}M" "${p}: MemoryHigh (M sonekli)"
    assert_eq "$RES_MEMORY_MAX"       "${exp_max}M"  "${p}: MemoryMax (M sonekli)"
    assert_eq "$RES_MEMORY_SWAP"      "${exp_swap}M" "${p}: MemorySwapMax (M sonekli)"
    assert_eq "$RES_TASKS_MAX"        "$exp_tasks"   "${p}: TasksMax"
    assert_eq "$RES_PM_MIN_SPARE_SERVERS"  "$exp_min"   "${p}: pm.min_spare_servers"
    assert_eq "$RES_PM_START_SERVERS"      "$exp_start" "${p}: pm.start_servers"
    assert_eq "$RES_PM_MAX_SPARE_SERVERS"  "$exp_spare" "${p}: pm.max_spare_servers"
    assert_eq "$(inv_check "$RES_PM_MIN_SPARE_SERVERS" "$RES_PM_START_SERVERS" "$RES_PM_MAX_SPARE_SERVERS" "$RES_MAX_CHILDREN")" \
        "ok" "${p}: min≤start≤max_spare≤max_children invariant"
done

# ═══════════════ 2) Bilinmeyen/boş profil → 'standard'a düş + warn (stderr) ═══════════════
assert_eq "$(resource_profile_resolve 'bilinmeyen-profil' 2>/dev/null)" "standard" "bilinmeyen profil → standard"
assert_eq "$(resource_profile_resolve '' 2>/dev/null)"                  "standard" "boş profil → standard"
warn_out="$(resource_profile_resolve 'saldirgan; rm -rf /' 2>&1 1>/dev/null)"
assert_contains "$warn_out" "Bilinmeyen kaynak profili" "bilinmeyen profil warn mesajı üretiyor"

resource_profile_load 'bilinmeyen-profil' 2>/dev/null
assert_eq "$RES_PROFILE" "standard" "resource_profile_load: bilinmeyen profil → RES_PROFILE=standard"
assert_eq "$RES_MEMORY_MAX_MB" "2304" "resource_profile_load: bilinmeyen profil → standard'ın türevleri"

# ═══════════════ 3) conf dosyası HİÇ YOKSA → dahili fail-closed güvenlik ağı ═══════════════
noconf_dir="$(mktemp -d)"
(
    export SRVCTL_RESOURCE_PROFILES="${noconf_dir}/does-not-exist/resource-profiles.conf"
    source "${REPO_ROOT}/lib/core.sh"
    resource_profile_load "ecommerce" >/dev/null 2>&1
    echo "PM_MODE=${RES_PM_MODE} MAXCH=${RES_MAX_CHILDREN} MEMLIM=${RES_MEMORY_LIMIT_MB} TASKS=${RES_TASKS_MAX} MEMMAX=${RES_MEMORY_MAX_MB}"
) > "${WEB_ROOT}/noconf.out" 2>/dev/null
assert_eq "$(cat "${WEB_ROOT}/noconf.out")" "PM_MODE=ondemand MAXCH=8 MEMLIM=256 TASKS=120 MEMMAX=2304" \
    "conf dosyası yok → dahili 'standard' güvenlik ağı (ondemand:8:256:120) devrede"
rm -rf "$noconf_dir"

# ═══════════════ 4) Alan-bazlı fail-closed (bozuk/saldırgan tek alan) ═══════════════
fixture_dir="$(mktemp -d)"
fixture_conf="${fixture_dir}/resource-profiles.conf"
cat > "$fixture_conf" << 'EOF'
badmode:turbo:8:256:120
badchildren:ondemand:abc:256:120
negchildren:ondemand:-5:256:120
zeromem:ondemand:8:0:120
missingtasks:ondemand:8:256
EOF

(
    export SRVCTL_RESOURCE_PROFILES="$fixture_conf"
    source "${REPO_ROOT}/lib/core.sh"

    resource_profile_load badmode 2>/dev/null
    echo "badmode:${RES_PM_MODE}"

    resource_profile_load badchildren 2>/dev/null
    echo "badchildren:${RES_MAX_CHILDREN}"

    resource_profile_load negchildren 2>/dev/null
    echo "negchildren:${RES_MAX_CHILDREN}"

    resource_profile_load zeromem 2>/dev/null
    echo "zeromem:${RES_MEMORY_LIMIT_MB}"

    resource_profile_load missingtasks 2>/dev/null
    echo "missingtasks:${RES_TASKS_MAX}"
) > "${WEB_ROOT}/fields.out" 2>/dev/null

assert_contains "$(cat "${WEB_ROOT}/fields.out")" "badmode:ondemand"        "tanınmayan pm_mode ('turbo') → 'ondemand'a düşer"
assert_contains "$(cat "${WEB_ROOT}/fields.out")" "badchildren:8"           "harf içeren max_children → varsayılan 8'e düşer"
assert_contains "$(cat "${WEB_ROOT}/fields.out")" "negchildren:8"           "negatif max_children → varsayılan 8'e düşer"
assert_contains "$(cat "${WEB_ROOT}/fields.out")" "zeromem:256"             "0 memory_limit_mb → varsayılan 256'ya düşer"
assert_contains "$(cat "${WEB_ROOT}/fields.out")" "missingtasks:120"        "eksik tasks_max alanı → varsayılan 120'ye düşer"
rm -rf "$fixture_dir"

# ═══════════════ 5) Sınır değerler: max_children=1/2 için invariant hâlâ korunuyor ═══════════════
edge_dir="$(mktemp -d)"
edge_conf="${edge_dir}/resource-profiles.conf"
cat > "$edge_conf" << 'EOF'
tiny1:ondemand:1:64:10
tiny2:ondemand:2:64:10
EOF
(
    export SRVCTL_RESOURCE_PROFILES="$edge_conf"
    source "${REPO_ROOT}/lib/core.sh"
    for prof in tiny1 tiny2; do
        resource_profile_load "$prof" 2>/dev/null
        echo "${prof}:${RES_PM_MIN_SPARE_SERVERS}:${RES_PM_START_SERVERS}:${RES_PM_MAX_SPARE_SERVERS}:${RES_MAX_CHILDREN}"
    done
) > "${WEB_ROOT}/edge.out" 2>/dev/null

while IFS=: read -r prof mn st mx mc; do
    [[ -n "$prof" ]] || continue
    assert_eq "$(inv_check "$mn" "$st" "$mx" "$mc")" "ok" "${prof} (max_children=${mc}): sınır değerde invariant korunuyor"
done < "${WEB_ROOT}/edge.out"
rm -rf "$edge_dir"

rm -rf "$WEB_ROOT"
test_summary
