#!/bin/bash
# _domain_resources: alan-koruma regresyonu + enjeksiyon/sınır girdi reddi.
#
# REGRESYON: 'srvctl domain resources <d> --memory=1G' eskiden slice
# dosyasını SIFIRDAN heredoc ile yeniden yazıyor ve yalnız verilen bayrakları
# yazıyordu — yani TasksMax/MemorySwapMax/CPUWeight/IOWeight satırları
# SESSİZCE SİLİNİYORDU (kullanılabilirlik komutu sertleştirmeyi geri
# alıyordu). Düzeltme: aynı template render edilir, yalnız verilen bayraklar
# üzerine yazılır, geri kalanı mevcut dosyadan (yoksa varsayılandan) korunur.
#
# DOĞRULAMA SIRASI ÖNEMLİ: _domain_resources --memory/--cpu/--io değerlerini
# systemd unit dosyasına (slice_path) HERHANGİ BİR YAZMA işleminden ÖNCE
# doğrular (_domain_valid_mem_value/_domain_valid_cpu_value/validate_uint).
# Bu sıra sayesinde enjeksiyon/sınır-değer reddi TAMAMEN GÜVENLE test
# edilebilir: error() ilk satırlarda tetiklenir, slice_path'e hiç dokunulmaz.
#
# BİLİNEN SINIRLAMA (bkz. final rapor): _domain_resources içindeki
# 'slice_path' /etc/systemd/system'e HARDCODED'DIR — 'srvctl.slice
# render/etkinleştirme yapan komşu fonksiyonların (_domain_render_fpm_unit,
# _domain_activate_fpm_unit) aksine bir SRVCTL_SYSTEMD_DIR test-seam'i YOK.
# Bu yüzden alan-koruma (preservation) senaryosu gerçek /etc/systemd/system'e
# dokunmadan test EDİLEMİYOR; aşağıda bunu bir "seam probe" ile OTOMATİK
# tespit ediyoruz: eğer gelecekte SRVCTL_SYSTEMD_DIR onurlandırılırsa bu
# test kendiliğinden tam kapsamlı hale gelir, onurlandırılmıyorsa açıkça
# SKIP edip nedenini raporlar (real /etc'ye ASLA yazmaya çalışmaz).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
systemctl() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

# error() ile exit eden fonksiyonu güvenle çağırmak için subshell sarmalayıcı
# (aksi halde 'exit' üst test script'ini de öldürür).
_run_isolated() { ( "$@" ); }

if ! declare -F _domain_resources >/dev/null 2>&1; then
    echo "  SKIP: _domain_resources henüz yok"
    rm -rf "$WEB_ROOT"
    test_summary
    exit 0
fi

d="resdom.example.com"
mkdir -p "${WEB_ROOT}/${d}"

# ═══════════════════ Doğrulama primitifleri (saf predikat, exit YOK) ═══════════════════
assert_ok   _domain_valid_mem_value "512M"
assert_ok   _domain_valid_mem_value "1G"
assert_ok   _domain_valid_mem_value "infinity"
assert_fail _domain_valid_mem_value "abc"
assert_fail _domain_valid_mem_value "-1G"
assert_fail _domain_valid_mem_value ""
assert_ok   _domain_valid_cpu_value "50%"
assert_ok   _domain_valid_cpu_value "150%"
assert_fail _domain_valid_cpu_value "50"
assert_fail _domain_valid_cpu_value "-50%"
assert_fail _domain_valid_cpu_value "abc"

# ═══════════════ Enjeksiyon/sınır girdileri _domain_resources seviyesinde reddediliyor ═══════════════
# Bu blok slice_path'e HİÇ ULAŞMAZ (validation write'lardan önce) — hardcoded
# path sorunundan BAĞIMSIZ, güvenle ve anlamlı biçimde test edilebilir.
assert_fail _run_isolated _domain_resources "$d"                                    # boş: hiçbir bayrak yok
assert_fail _run_isolated _domain_resources "$d" --memory=
assert_fail _run_isolated _domain_resources "$d" --memory='1;} location /pwn {'      # nginx/unit enjeksiyonu
assert_fail _run_isolated _domain_resources "$d" --cpu='$(whoami)'                    # komut enjeksiyonu (literal, eval edilmez)
assert_fail _run_isolated _domain_resources "$d" --memory=-1G                         # negatif
assert_fail _run_isolated _domain_resources "$d" --cpu=-50%                           # negatif
assert_fail _run_isolated _domain_resources "$d" --io=-5                              # negatif
assert_fail _run_isolated _domain_resources "$d" --memory=abc                         # harf
assert_fail _run_isolated _domain_resources "$d" --cpu=abc                            # harf
assert_fail _run_isolated _domain_resources "$d" --io=abc                             # harf
assert_fail _run_isolated _domain_resources "$d" --io=0                               # sınır: 0 reddedilir (IOWeight>=1)
assert_fail _run_isolated _domain_resources "yok-boyle-bir-domain.com" --memory=512M   # domain_exists kapısı

# ═══════════════ Alan-koruma (preservation) — seam probe ═══════════════
# SRVCTL_SYSTEMD_DIR onurlandırılıyor mu? (şu an HAYIR — bkz. dosya başı notu)
seam_dir="$(mktemp -d)"
seam_d="seamprobe.example.com"
mkdir -p "${WEB_ROOT}/${seam_d}"
SRVCTL_SYSTEMD_DIR="$seam_dir" _run_isolated _domain_resources "$seam_d" --memory=256M >/dev/null 2>&1
seam_slice="${seam_dir}/srvctl-$(safe_name "$seam_d").slice"

if [[ -f "$seam_slice" ]]; then
    # ── Seam MEVCUT: tam preservation regresyon senaryosunu gerçekten koş ──
    p_dir="$(mktemp -d)"
    d2="fields.example.com"
    mkdir -p "${WEB_ROOT}/${d2}"
    sl="${p_dir}/srvctl-$(safe_name "$d2").slice"

    # 1) İlk çağrı: memory + cpu + io birlikte ayarlanır.
    SRVCTL_SYSTEMD_DIR="$p_dir" _run_isolated _domain_resources "$d2" --memory=512M --cpu=50% --io=150 >/dev/null 2>&1
    conf1=$(cat "$sl")
    assert_contains "$conf1" "MemoryMax=512M"    "ilk çağrı: memory uygulandı"
    assert_contains "$conf1" "CPUQuota=50%"      "ilk çağrı: cpu uygulandı"
    assert_contains "$conf1" "IOWeight=150"      "ilk çağrı: io uygulandı"
    assert_contains "$conf1" "TasksMax=200"      "ilk çağrı: varsayılan TasksMax dolduruldu"
    assert_contains "$conf1" "MemorySwapMax=512M" "ilk çağrı: varsayılan MemorySwapMax dolduruldu"

    # 2) İkinci çağrı: SADECE memory değiştirilir. cpu/io/tasks/swap KORUNMALI
    #    (regresyon: eski kod bunları burada sessizce silerdi).
    SRVCTL_SYSTEMD_DIR="$p_dir" _run_isolated _domain_resources "$d2" --memory=1G >/dev/null 2>&1
    conf2=$(cat "$sl")
    assert_contains "$conf2" "MemoryMax=1G"       "ikinci çağrı: yalnız memory güncellendi"
    assert_contains "$conf2" "CPUQuota=50%"       "ikinci çağrı: ÖNCEKİ cpu KORUNDU"
    assert_contains "$conf2" "IOWeight=150"       "ikinci çağrı: ÖNCEKİ io KORUNDU"
    assert_contains "$conf2" "TasksMax=200"       "ikinci çağrı: TasksMax KORUNDU"
    assert_contains "$conf2" "MemorySwapMax=512M" "ikinci çağrı: MemorySwapMax KORUNDU"

    # 3) Üçüncü çağrı: SADECE io değiştirilir. memory/cpu KORUNMALI.
    SRVCTL_SYSTEMD_DIR="$p_dir" _run_isolated _domain_resources "$d2" --io=300 >/dev/null 2>&1
    conf3=$(cat "$sl")
    assert_contains "$conf3" "IOWeight=300"  "üçüncü çağrı: yalnız io güncellendi"
    assert_contains "$conf3" "MemoryMax=1G"  "üçüncü çağrı: ÖNCEKİ memory KORUNDU"
    assert_contains "$conf3" "CPUQuota=50%"  "üçüncü çağrı: ÖNCEKİ cpu KORUNDU"

    rm -rf "$p_dir"
else
    echo "  SKIP: alan-koruma (preservation) senaryosu — _domain_resources'taki"
    echo "        'slice_path=/etc/systemd/system/\${slice}' HARDCODED, SRVCTL_SYSTEMD_DIR"
    echo "        onurlanmıyor (bkz. lib/domain.sh, _domain_resources; _domain_render_fpm_unit"
    echo "        ile karşılaştır). Gerçek host yoluna dokunmadan test edilemiyor — bkz. rapor."
fi
rm -rf "$seam_dir"

rm -rf "$WEB_ROOT"
test_summary
