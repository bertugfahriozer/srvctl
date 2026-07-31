#!/bin/bash
# Chroot içi PHP-FPM kütüphaneleri için 'm' (mmap) izni — regresyon kilidi.
#
# NEDEN VAR (GERÇEK üretim sunucusu, Ubuntu 24.04, iki canlı domain —
# per-domain FPM unit'i enforce moda alındıktan SONRA /var/log/audit/
# audit.log'da SÜREKLİ tekrarlayan bulgu):
#
#   apparmor="DENIED" operation="file_mmap"
#   name="/var/www/dev.designwestgate.art/lib/x86_64-linux-gnu/libnss_systemd.so.2"
#   denied_mask="m"  comm="php-fpm8.4"
#
# KÖK NEDEN (lib/domain.sh:_apply_chroot_php_deps'ten okundu): FPM'in
# chroot() jail kökü '{{WEB_ROOT}}/{{DOMAIN}}'in KENDİSİDİR (pool.conf.tpl
# 'chroot = {{WEB_ROOT}}/{{DOMAIN}}'; lib/domain.sh'ta HER çağrı sitesinde
# 'base="${WEB_ROOT}/${domain}"'). '_apply_chroot_php_deps' bu kökün İÇİNE
# php-fpm binary'sinin 'ldd' bağımlılıklarını + ld-linux yükleyicisini, PHP
# eklenti (.so) dosyalarını + bağımlılıklarını ve NSS/resolv modüllerini
# kopyalar — hedefler 'lib/x86_64-linux-gnu/', 'lib64/', 'usr/lib/php/<api>/'
# (ve muhtemelen 'usr/lib/x86_64-linux-gnu/'). Eskiden profil bu chroot
# kopyaları için yalnız HOST karşılıklarına izin veriyordu (ör.
# '/usr/lib/php/** mr,'); chroot ÖNEKLİ (WEB_ROOT/DOMAIN) yollar yalnız
# genel '{{WEB_ROOT}}/{{DOMAIN}}/** r,' bloğuna dahildi — bu YALNIZ 'r'
# veriyordu, 'm' (mmap) İÇERMİYORDU. dlopen(3) ile ÇALIŞMA ZAMANINDA
# yüklenen NSS modülleri (libnss_systemd, libnss_files vb.) bu yüzden
# REDDEDİLİYORDU. 'libnss_systemd' isteğe bağlı olduğundan site ayakta
# kalıyordu (SESSİZ bozulma) — ama kullanıcı/grup çözümlemesi gereken bir
# kod yolu (posix_getpwuid()/getent) gerçek bir kırılma üretebilirdi.
#
# templates/apparmor/profile.tpl + profile-cli.tpl'e bu boşluğu kapatan
# 'mr' (yazma/yürütme YOK) kuralları eklendi. BU TEST o kuralların:
#   1) VAR OLDUĞUNU,
#   2) 'm' VE 'r' İKİSİNİ DE verdiğini,
#   3) 'w' (yazma) VERMEDİĞİNİ (chroot kütüphaneleri root:root salt-okunur
#      kalmalı — 'w' web_user'ın kendi paylaşımlı kütüphanelerini
#      değiştirmesine/zehirli bir '.so' enjekte etmesine kapı açar),
#   4) 'x' (yürütme) VERMEDİĞİNİ (chroot'ta çalıştırılabilir dosya
#      OLMAMALI — HOST'ta ölçüldü: usr/sbin, usr/bin, bin BOŞ; 'x' vermek
#      tests/test_apparmor_deny_shadow.sh'ın exec-whitelist kilidinin
#      (Dedektör 2) KORUMAK istediği tam sınıfı gereksiz yere genişletirdi
#      olacaktı — bu değişiklik o testi kırMAYACAK biçimde, yalnız 'mr'
#      ile yapıldı; bkz. aynı PR'de o testin 0-fail çalıştığı doğrulama)
# olarak KİLİTLER.
#
# ÜRETİCİ/TÜKETİCİ DRİFT DEDEKTÖRÜ (test_apparmor_shared_dirs.sh İLE AYNI
# DESEN): '_apply_chroot_php_deps'in TEK TAM SABİT (literal, ldd/php -i
# çıktısına bağlı OLMAYAN) kopya hedefi — NSS/resolv modülleri için
# 'mkdir -p "${base}/lib/x86_64-linux-gnu"' — koddan çıkarılır ve profil
# dosyalarındaki karşılığıyla karşılaştırılır. Biri ileride bu hardcoded
# yolu değiştirirse (ör. farklı bir mimari/dizin şemasına geçilirse) bu
# test, AppArmor kurallarının da güncellenmesi GEREKTİĞİNİ görünür kılar.
#
# KENDİ KENDİNİ DOĞRULAMA (zorunlu — bkz. CLAUDE.md/proje kuralı): sentetik
# fixture'larla MUTASYON testi — kural eksik/w-eklenmiş/x-eklenmiş
# durumların GERÇEKTEN yakalandığı, doğru kuralın YANLIŞ POZİTİF
# üretmediği ayrı ayrı doğrulanır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

DOMAIN_SH="${REPO_ROOT}/lib/domain.sh"
PROFILE_TPL="${REPO_ROOT}/templates/apparmor/profile.tpl"
PROFILE_CLI_TPL="${REPO_ROOT}/templates/apparmor/profile-cli.tpl"

# ─── TÜKETİCİ tarayıcı: verilen profil METNİNDE (dosya değil — fixture'larla
#     test edilebilsin diye) '{{WEB_ROOT}}/{{DOMAIN}}/<relpath>/**' yazma/
#     okuma kuralının izin harflerini döndürür; kural yoksa boş döner. ───
_aa_chroot_lib_rule_perm() {
    local text="$1" relpath="$2"
    printf '%s\n' "$text" \
        | grep -F "{{WEB_ROOT}}/{{DOMAIN}}/${relpath}/**" \
        | grep -oE '[a-zA-Z]+,[[:space:]]*$' \
        | head -1 \
        | tr -d ', \t'
}

# ─── ÜRETİCİ tarayıcı: lib/domain.sh METNİNDEN '_apply_chroot_php_deps'in
#     TEK TAM SABİT kopya hedefini çıkarır — 'libnss_*' kopyalayan 'cp -u'
#     satırının HEDEF (ikinci) argümanı, '${base}' öneki atılmış hali. Bu
#     satır mimariye/arch-string'e göre DEĞİL, 'libnss_' ADINA göre
#     seçildiğinden mimari değişse (ör. x86_64 -> aarch64) BİLE doğru
#     satırı bulur (drift'i YAKALAR, körleşmez). Girdi METİN'dir
#     (fixture'larla da test edilebilir). ───
_domain_chroot_nss_hardcoded_target() {
    local text="$1"
    printf '%s\n' "$text" \
        | awk '/^_apply_chroot_php_deps\(\) \{/,/^\}/' \
        | grep -oE 'cp -u [^"]*libnss_\* "\$\{base\}[^"]+"' \
        | head -1 \
        | grep -oE '"\$\{base\}[^"]+"' \
        | sed -E 's/^"\$\{base\}//; s/\/?"$//'
}

# Kilit altına alınan dört chroot kütüphane hedefi (yukarıdaki NOT'ta
# gerekçelendirildi — profile.tpl/profile-cli.tpl'de aynı dört yol).
_AA_CHROOT_LIB_RELPATHS="lib/x86_64-linux-gnu lib64 usr/lib/php usr/lib/x86_64-linux-gnu"

# ═══════════════════════════════════════════════════════════════
# KENDİ KENDİNİ DOĞRULAMA — MUTASYON testleri (sentetik fixture'lar)
# ═══════════════════════════════════════════════════════════════
echo "== Kendi kendini doğrulama (sentetik fixture / mutasyon) =="

# (a) MUTASYON: kural TAMAMEN eksik — dedektör boş dönmeli.
fixture_missing='
  {{WEB_ROOT}}/{{DOMAIN}}/lib64/** mr,
'
perm_missing="$(_aa_chroot_lib_rule_perm "$fixture_missing" "lib/x86_64-linux-gnu")"
assert_eq "$perm_missing" "" \
    "mutasyon: 'lib/x86_64-linux-gnu' kuralı HİÇ yokken boş dönüyor (BULGU üretir)"

# (b) MUTASYON: kural var ama yalnız 'r' — 'm' EKSİK (ÖLÇÜLEN bulgunun
#     TAM KENDİSİ — denied_mask="m").
fixture_no_mmap='
  {{WEB_ROOT}}/{{DOMAIN}}/lib/x86_64-linux-gnu/** r,
'
perm_no_mmap="$(_aa_chroot_lib_rule_perm "$fixture_no_mmap" "lib/x86_64-linux-gnu")"
assert_eq "$perm_no_mmap" "r" "dedektör: 'r' (m'siz) kuralı doğru okuyor"
assert_not_contains "$perm_no_mmap" "m" \
    "mutasyon: 'm' eksikliği doğru tespit ediliyor (ÖLÇÜLEN denied_mask=\"m\" sınıfı)"

# (c) MUTASYON: kurala YANLIŞLIKLA yazma ('w') eklenmiş — YAKALANMALI
#     (chroot kütüphaneleri salt-okunur kalmalı).
fixture_extra_write='
  {{WEB_ROOT}}/{{DOMAIN}}/lib/x86_64-linux-gnu/** mrw,
'
perm_extra_write="$(_aa_chroot_lib_rule_perm "$fixture_extra_write" "lib/x86_64-linux-gnu")"
assert_contains "$perm_extra_write" "w" \
    "mutasyon: yanlışlıkla eklenen 'w' izni dedektör tarafından doğru okunuyor (asıl testte assert_not_contains bunu FAIL ettirir)"

# (d) MUTASYON: kurala YANLIŞLIKLA yürütme ('x') eklenmiş — YAKALANMALI
#     (chroot'ta çalıştırılabilir dosya OLMAMALI; exec-whitelist'i
#     gereksiz genişletir).
fixture_extra_exec='
  {{WEB_ROOT}}/{{DOMAIN}}/lib/x86_64-linux-gnu/** mrx,
'
perm_extra_exec="$(_aa_chroot_lib_rule_perm "$fixture_extra_exec" "lib/x86_64-linux-gnu")"
assert_contains "$perm_extra_exec" "x" \
    "mutasyon: yanlışlıkla eklenen 'x' izni dedektör tarafından doğru okunuyor (asıl testte assert_not_contains bunu FAIL ettirir)"

# (e) KONTROL GRUBU: doğru kural ('mr', w/x YOK) — YANLIŞ POZİTİF üretmemeli.
fixture_ok='
  {{WEB_ROOT}}/{{DOMAIN}}/lib/x86_64-linux-gnu/** mr,
'
perm_ok="$(_aa_chroot_lib_rule_perm "$fixture_ok" "lib/x86_64-linux-gnu")"
assert_contains "$perm_ok" "m" "kontrol grubu: 'mr' kuralında mmap izni bulunuyor"
assert_contains "$perm_ok" "r" "kontrol grubu: 'mr' kuralında okuma izni bulunuyor"
assert_not_contains "$perm_ok" "w" "kontrol grubu: 'mr' kuralında yazma izni YOK (beklenen)"
assert_not_contains "$perm_ok" "x" "kontrol grubu: 'mr' kuralında yürütme izni YOK (beklenen)"

# (f) ÜRETİCİ tarayıcı MUTASYONU: sentetik '_apply_chroot_php_deps' bloğunda
#     hardcoded NSS hedefi doğru çıkarılıyor mu?
fixture_producer='
_apply_chroot_php_deps() {
    local base="$1" php_ver="$2"
    mkdir -p "${base}/lib/x86_64-linux-gnu"
    cp -u /lib/x86_64-linux-gnu/libnss_* "${base}/lib/x86_64-linux-gnu/" 2>/dev/null || true
}
'
producer_out="$(_domain_chroot_nss_hardcoded_target "$fixture_producer")"
assert_eq "$producer_out" "/lib/x86_64-linux-gnu" \
    "üretici tarayıcı: sentetik '_apply_chroot_php_deps' bloğundan doğru hardcoded NSS hedefini çıkarıyor"

# (g) MUTASYON: hardcoded hedef DEĞİŞTİRİLİRSE (ör. farklı bir mimari/dizin
#     şemasına geçilirse) tarayıcı bunu da doğru yakalamalı (drift sinyali).
fixture_producer_drifted='
_apply_chroot_php_deps() {
    local base="$1" php_ver="$2"
    mkdir -p "${base}/lib/aarch64-linux-gnu"
    cp -u /lib/aarch64-linux-gnu/libnss_* "${base}/lib/aarch64-linux-gnu/" 2>/dev/null || true
}
'
producer_drifted="$(_domain_chroot_nss_hardcoded_target "$fixture_producer_drifted")"
assert_eq "$producer_drifted" "/lib/aarch64-linux-gnu" \
    "mutasyon: hardcoded hedef değişince tarayıcı YENİ değeri raporluyor (drift GÖRÜNÜR olur)"

# ═══════════════════════════════════════════════════════════════
# ASIL DENETİM — gerçek lib/domain.sh + templates/apparmor/*.tpl
# ═══════════════════════════════════════════════════════════════
echo ""
echo "== Gerçek lib/domain.sh + templates/apparmor/*.tpl denetimi =="

domain_text="$(cat "$DOMAIN_SH")"
nss_target="$(_domain_chroot_nss_hardcoded_target "$domain_text")"

assert_eq "$nss_target" "/lib/x86_64-linux-gnu" \
    "lib/domain.sh:_apply_chroot_php_deps'in hardcoded NSS hedefi HÂLÂ '/lib/x86_64-linux-gnu' (drift YOK)"

# Üretici hedef (baştaki '/' atılmış hali), kilitlenen dört relpath'in
# İÇİNDE olmalı — yoksa AppArmor kuralları koddan SAPMIŞ demektir.
nss_relpath="${nss_target#/}"
case " ${_AA_CHROOT_LIB_RELPATHS} " in
    *" ${nss_relpath} "*) assert_eq "var" "var" "üretici hedef '${nss_relpath}' kilitlenen relpath listesinde MEVCUT" ;;
    *) assert_eq "yok" "var" "üretici hedef '${nss_relpath}' kilitlenen relpath listesinde MEVCUT" ;;
esac

for tpl in "$PROFILE_TPL" "$PROFILE_CLI_TPL"; do
    rel="${tpl#"${REPO_ROOT}"/}"
    if [[ ! -f "$tpl" ]]; then
        assert_eq "eksik" "var" "${rel} dosyası bulunamadı"
        continue
    fi
    tpl_text="$(cat "$tpl")"
    for relpath in $_AA_CHROOT_LIB_RELPATHS; do
        perm="$(_aa_chroot_lib_rule_perm "$tpl_text" "$relpath")"
        assert_contains "$perm" "m" \
            "${rel}: '${relpath}/**' için mmap (m) izni var (ÖLÇÜLEN denied_mask=\"m\" bulgusunun düzeltmesi)"
        assert_contains "$perm" "r" \
            "${rel}: '${relpath}/**' için okuma (r) izni var"
        assert_not_contains "$perm" "w" \
            "${rel}: '${relpath}/**' için yazma (w) izni YOK (chroot kütüphaneleri salt-okunur kalmalı)"
        assert_not_contains "$perm" "x" \
            "${rel}: '${relpath}/**' için yürütme (x) izni YOK (chroot'ta çalıştırılabilir dosya yok; exec-whitelist genişlemesin)"
    done
done

test_summary
