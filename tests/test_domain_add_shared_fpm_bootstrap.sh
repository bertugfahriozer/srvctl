#!/bin/bash
# 'domain add'in paylaşılan FPM'e dayanıklılığı — HOST'ta ölçülen ikinci
# dereceden bloke edici bug (srvctl-jammy).
#
# KÖK NEDEN (eski lib/domain.sh, 'PHP-FPM Pool' adımı — 4/10):
#   systemctl reload "php${php_version}-fpm" 2>/dev/null || \
#       systemctl restart "php${php_version}-fpm"
# İkinci komutun hatası BASTIRILMAMIŞTI — 'set -e' altında bu TEK satır
# TÜM 'domain add'i düşürüyordu. HOST'ta ölçülen somut senaryo: bir
# hayalet pool.d dosyası (bkz. test_domain_fpm_purge_ghost_pools.sh) ya da
# rate-limit'e takılmış ('start request repeated too quickly') bir servis
# yüzünden 'restart' başarısız oluyor, 'domain add' 4/10. adımda ölüyor,
# rollback tetikleniyor (kısmi kaynaklar düzgün toplanıyor, ama ekleme HİÇ
# TAMAMLANAMIYOR).
#
# ÖLÇÜM (bkz. lib/domain.sh:_domain_add_bootstrap_shared_fpm başlık yorumu):
# paylaşılan servise dokunmak DOMAIN_ISOLATED_FPM=true (varsayılan)
# durumunda bile GEREKSİZ DEĞİL — lib/security.sh:_harden_fpm_apply önceki
# bir migrasyonda servisi BİLEREK durdurup devre dışı bırakmış olabilir;
# bu domain'in yazdığı geçici pool'un GERÇEKTEN yüklenmesi için servisin
# ÇALIŞIYOR olması gerekir (hem izole migrasyon başarısız olursa fallback
# olarak, hem de DOMAIN_ISOLATED_FPM=false ise KALICI olarak). Bu yüzden
# adım ATLANMADI, DAYANIKLI hale getirildi: reload → (reset-failed) →
# restart zinciri, ve HERHANGİ BİR AŞAMANIN başarısızlığı 'domain add'i
# ÖLDÜRMEZ (bu adım yalnız fonksiyon SONUNDA çağrılan
# _domain_migrate_to_isolated_fpm ile süpürülecek bir bootstrap adımıdır).
#
# Bu test üç şeyi kilitler:
#   1) 'reload' başarılıysa restart/reset-failed HİÇ denenmez, fonksiyon 0
#      döner.
#   2) 'reload' başarısız ama 'reset-failed' + 'restart' başarılıysa
#      fonksiyon YİNE 0 döner (rate-limit'e takılmış bir servis kendini
#      toparlayabiliyor).
#   3) [EN KRİTİK] HER İKİSİ de (reload VE restart) başarısız olsa bile
#      fonksiyon yalnız 1 DÖNER — 'error' ÇAĞIRMAZ, script'i DÜŞÜRMEZ; net
#      bir teşhis (warn + log_action, tam servis adı + domain adıyla)
#      basılır. Statik kilit: 'lib/domain.sh'daki tek çağrı sitesi bunu
#      'if ... ; then ... ; fi' ile GUARD'lıyor (çıplak çağrı DEĞİL) —
#      aksi halde 'set -e' altında başarısızlık TÜM 'domain add'i düşürürdü.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"

log_log="$(mktemp)"
log_action() { printf '%s\n' "$*" >> "$log_log"; }

# systemctl mock: her alt komutun davranışı ayrı bir env bayrağıyla kontrol
# edilir; hangi alt komutların GERÇEKTEN çağrıldığını da bir log'a yazar
# (reload'un restart'tan ÖNCE denendiğini, gereksiz yere restart
# çağrılmadığını doğrulamak için).
call_log="$(mktemp)"
MOCK_RELOAD_OK=1
MOCK_RESTART_OK=1
systemctl() {
    printf '%s\n' "$1" >> "$call_log"
    case "$1" in
        reload)       [[ -n "${MOCK_RELOAD_OK:-}" ]] && return 0 || return 1 ;;
        reset-failed) return 0 ;;
        restart)      [[ -n "${MOCK_RESTART_OK:-}" ]] && return 0 || return 1 ;;
        *)            return 0 ;;
    esac
}

source "${REPO_ROOT}/lib/domain.sh"

if ! declare -F _domain_add_bootstrap_shared_fpm >/dev/null 2>&1; then
    echo "  SKIP: _domain_add_bootstrap_shared_fpm tanımlı değil"
    test_summary
    exit $?
fi

echo "== domain add: paylaşılan FPM'e dayanıklı bootstrap =="

# ═══ Vaka 1: 'reload' başarılı — restart hiç denenmemeli ═══
: > "$call_log"; : > "$log_log"
MOCK_RELOAD_OK=1
rc1=0
_domain_add_bootstrap_shared_fpm "8.3" "ok.test" >/dev/null 2>&1 || rc1=$?
assert_eq "$rc1" "0" "1) 'reload' başarılıysa fonksiyon 0 döner"
assert_not_contains "$(cat "$call_log")" "restart" \
    "1) 'reload' başarılıyken 'restart' HİÇ çağrılmadı (gereksiz yeniden başlatma yok)"
assert_eq "$(cat "$log_log")" "" "1) başarı durumunda log_action ÇAĞRILMADI"

# ═══ Vaka 2: 'reload' başarısız, 'reset-failed' + 'restart' başarılı ═══
: > "$call_log"; : > "$log_log"
MOCK_RELOAD_OK="" MOCK_RESTART_OK=1
rc2=0
_domain_add_bootstrap_shared_fpm "8.3" "recovering.test" >/dev/null 2>&1 || rc2=$?
assert_eq "$rc2" "0" \
    "2) 'reload' başarısız ama 'restart' başarılıysa fonksiyon YİNE 0 döner"
assert_contains "$(cat "$call_log")" "reset-failed" \
    "2) 'restart'tan ÖNCE 'reset-failed' denendi (rate-limit sıfırlanıyor)"

# ═══ Vaka 3 [EN KRİTİK]: İKİSİ DE başarısız — script DÜŞMEMELİ, yalnız 1 dönmeli ═══
: > "$call_log"; : > "$log_log"
MOCK_RELOAD_OK="" MOCK_RESTART_OK=""
outFail=$(_domain_add_bootstrap_shared_fpm "8.3" "asla-olmasin.test" 2>&1)
rc3=$?
assert_eq "$rc3" "1" \
    "3 [KRİTİK]: her iki komut da başarısızken fonksiyon 1 döner ('error' ile script'i DÜŞÜRMEZ)"
assert_contains "$outFail" "asla-olmasin.test" \
    "3: hangi domain için başarısız olduğu AÇIKÇA söyleniyor"
assert_contains "$outFail" "php8.3-fpm" \
    "3: hangi servisin başarısız olduğu AÇIKÇA söyleniyor"
assert_contains "$outFail" "izole FPM" \
    "3: bunun yalnız bir bootstrap adımı olduğu, izole migrasyona güvenildiği AÇIKLANIYOR"
assert_contains "$(cat "$log_log")" "asla-olmasin.test" \
    "3: başarısızlık log_action'a da yazıldı (denetim izi)"

# ═══ Statik regresyon kilidi: ÇAĞRI SİTESİ guard'lı mı? ═══
# Çıplak '_domain_add_bootstrap_shared_fpm ...' çağrısı 'set -e' altında
# başarısızlıkta TÜM 'domain add'i düşürürdü — bu yüzden TEK çağrı sitesi
# 'if ... ; then' içinde olmalı.
call_site=$(grep -n '_domain_add_bootstrap_shared_fpm "\$php_version" "\$domain"' "${REPO_ROOT}/lib/domain.sh")
assert_eq "$([[ -n "$call_site" ]] && echo BULUNDU || echo YOK)" "BULUNDU" \
    "4) çağrı sitesi bulundu"
guarded_line=$(grep -B0 'if _domain_add_bootstrap_shared_fpm' "${REPO_ROOT}/lib/domain.sh")
assert_contains "$guarded_line" "if _domain_add_bootstrap_shared_fpm" \
    "4 [KRİTİK]: 'lib/domain.sh'daki TEK çağrı sitesi 'if ... ; then' ile GUARD'lı (çıplak çağrı DEĞİL)"

rm -f "$call_log" "$log_log"
rm -rf "$WEB_ROOT"
test_summary
