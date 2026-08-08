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
#
# GÜNCELLEME (kaynak profilleri): "varsayılan doldurulan" TasksMax/
# MemorySwapMax değerleri artık _domain_cgroups_defaults'taki SABİT
# "4096M 4608M 512M 200" DEĞİL — domain'in kaynak profilinden (.srvctl-meta
# RESOURCE_PROFILE, yoksa 'standard') resource_profile_load (core.sh) ile
# TÜRETİLİYOR (bkz. conf/resource-profiles.conf). Meta yoksa profil
# 'standard' (ondemand:8:256:120) olur: MemoryHigh=8×256=2048M,
# MemoryMax=2048×9/8=2304M, MemorySwapMax=2048/8=256M, TasksMax=120 (bu
# profilden DOĞRUDAN okunur, formülle türetilmez). Bu testteki domain'in
# hiç meta'sı yok, dolayısıyla aşağıdaki "varsayılan dolduruldu/KORUNDU"
# beklentileri 'standard' profilinin bu türevleridir — SABİT DEĞİL, profil
# dosyası değişirse bu test de güncellenmeli (bkz. tests/test_resource_profile_load.sh
# profilin kendisini ayrıca doğrular).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
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

# ═══ _domain_mem_to_mb — birim dönüşümü (systemd'de SONEKSİZ = BAYT tuzağı) ═══
assert_eq "$(_domain_mem_to_mb 512M)"    "512"     "512M → 512 MB"
assert_eq "$(_domain_mem_to_mb 1G)"      "1024"    "1G → 1024 MB"
assert_eq "$(_domain_mem_to_mb 2G)"      "2048"    "2G → 2048 MB"
assert_eq "$(_domain_mem_to_mb 1T)"      "1048576" "1T → 1048576 MB"
assert_eq "$(_domain_mem_to_mb 1048576K)" "1024"   "1048576K → 1024 MB"
# KRİTİK: soneksiz değer systemd'de BAYT'tır. '2048' 2 GB DEĞİL 2 KB'dır;
# MB sanılsaydı slice'a bin kat yanlış bir limit yazılırdı. Taban 1M devreye girer.
assert_eq "$(_domain_mem_to_mb 2048)"    "1"       "soneksiz 2048 = 2048 BAYT → taban 1M"
assert_eq "$(_domain_mem_to_mb 1073741824)" "1024" "soneksiz 1073741824 bayt → 1024 MB"
# NOT: assert_ok/assert_fail mesaj parametresi ALMAZ — tüm argümanlar komuta
# geçer. Bu yüzden bu üç satırda açıklama yorum olarak duruyor:
assert_fail _domain_mem_to_mb "infinity"    # 'infinity' çevrilemez (çağıran özel ele alır)
assert_fail _domain_mem_to_mb "abc"         # geçersiz biçim reddedilir
assert_fail _domain_mem_to_mb "512X"        # bilinmeyen sonek reddedilir

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
    assert_contains "$conf1" "TasksMax=120"      "ilk çağrı: varsayılan (standard profili) TasksMax dolduruldu"
    # DAVRANIŞ DEĞİŞİKLİĞİ (bilinçli): --memory verildiğinde MemoryHigh ve
    # MemorySwapMax artık dosyadaki/profildeki değerden DEĞİL, verilen TAVANDAN
    # türetilir — High=Max×8/9, Swap=High/8. Eski davranışta High, Max'a EŞİTLENİYOR
    # (throttle aşaması atlanıyor → doğrudan OOM-kill) ve Swap dosyadaki eski
    # değeriyle (eski slice'larda '0') SONSUZA KADAR kalıyordu.
    # 512M → High=512×8/9=455M, Swap=455/8=56M
    assert_contains "$conf1" "MemoryHigh=455M"   "ilk çağrı: High tavandan türetildi (Max'a EŞİT DEĞİL)"
    assert_contains "$conf1" "MemorySwapMax=56M" "ilk çağrı: SwapMax High'tan türetildi (0 DEĞİL)"

    # 2) İkinci çağrı: SADECE memory değiştirilir. cpu/io/tasks/swap KORUNMALI
    #    (regresyon: eski kod bunları burada sessizce silerdi).
    SRVCTL_SYSTEMD_DIR="$p_dir" _run_isolated _domain_resources "$d2" --memory=1G >/dev/null 2>&1
    conf2=$(cat "$sl")
    assert_contains "$conf2" "MemoryMax=1G"       "ikinci çağrı: yalnız memory güncellendi (yazılan biçim korunur)"
    assert_contains "$conf2" "CPUQuota=50%"       "ikinci çağrı: ÖNCEKİ cpu KORUNDU"
    assert_contains "$conf2" "IOWeight=150"       "ikinci çağrı: ÖNCEKİ io KORUNDU"
    assert_contains "$conf2" "TasksMax=120"       "ikinci çağrı: TasksMax KORUNDU"
    # 1G = 1024M → High=1024×8/9=910M, Swap=910/8=113M (yeni tavandan yeniden türetilir)
    assert_contains "$conf2" "MemoryHigh=910M"    "ikinci çağrı: High YENİ tavandan türetildi"
    assert_contains "$conf2" "MemorySwapMax=113M" "ikinci çağrı: SwapMax YENİ tavandan türetildi"

    # 3) Üçüncü çağrı: SADECE io değiştirilir. memory/cpu KORUNMALI.
    SRVCTL_SYSTEMD_DIR="$p_dir" _run_isolated _domain_resources "$d2" --io=300 >/dev/null 2>&1
    conf3=$(cat "$sl")
    assert_contains "$conf3" "IOWeight=300"  "üçüncü çağrı: yalnız io güncellendi"
    assert_contains "$conf3" "MemoryMax=1G"  "üçüncü çağrı: ÖNCEKİ memory KORUNDU"
    assert_contains "$conf3" "CPUQuota=50%"  "üçüncü çağrı: ÖNCEKİ cpu KORUNDU"
    # --memory VERİLMEDİĞİNDE türetme YAPILMAZ; alan-koruma mantığı aynen sürer.
    assert_contains "$conf3" "MemoryHigh=910M"    "üçüncü çağrı: ÖNCEKİ High KORUNDU (yeniden türetilmedi)"
    assert_contains "$conf3" "MemorySwapMax=113M" "üçüncü çağrı: ÖNCEKİ SwapMax KORUNDU"

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
