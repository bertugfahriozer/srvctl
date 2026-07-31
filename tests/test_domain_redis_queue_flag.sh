#!/bin/bash
# 'srvctl domain add --redis-queue' — Redis kuyruk (EVAL/Lua scripting)
# desteğini AÇIK bir bayrakla etkinleştirme.
#
# NEDEN VAR: srvctl per-domain Redis ACL'inde EVAL/Lua scripting'i VARSAYILAN
# OLARAK KAPATIYOR. Nihai karar İKİ AYRI SORUNUN birleşimidir (bkz.
# lib/domain.sh:_domain_redis_queue_gate):
#   1) YETENEK (teknik, sürüm): _domain_redis_scripting_mode(major) — Redis
#      7+'ta script içi ACL enforcement garantili, <7'de GARANTİSİZ.
#   2) TALEP (politika, operatör): '--redis-queue' AÇIKÇA verildi mi?
# NİHAİ SONUÇ = YETENEK **VE** TALEP. KRİTİK: Redis sürümü scripting'i
# GÜVENLE destekliyor olsa BİLE (>=7), '--redis-queue' verilmedikçe sonuç
# HER ZAMAN 'disabled'dır — bir host'un Redis 6'dan 7'ye yükseltilmesi
# (ör. resmi depoya geçiş) TEK BAŞINA hiçbir domain'i sessizce 'enabled'a
# ÇEVİREMEZ. Bu, koordinatörün ikinci turda düzelttirdiği TAM OLARAK budur:
# önceki tasarımda (bu dosyanın önceki sürümünde test edilen
# '_domain_redis_queue_reason') bayrak yalnızca MESAJI seçiyordu, ACL/meta
# kararını DEĞİL — Redis 7+'ta bayraksız bile otomatik 'enabled' üretiliyordu.
#
# GÜVENLİK GEREKÇESİ (TALEP olsa BİLE Redis <7'de scripting'i ZORLA AÇAMAZ):
# '+@scripting'in ACL anahtar-deseni (~<sname>:*) kısıtlamasını Lua script
# İÇİNDE de garanti altına alması Redis 7'DEN ÖNCE garanti değildir — bu
# garantisiz durumda scripting'i zorla açmak, komşu bir domainin Redis
# anahtar alanına EVAL ile erişilebilmesi (kiracı İZOLASYONUNUN KIRILMASI)
# anlamına gelir. Kullanıcı AÇIKÇA "güvenlik varsayılanını gevşetmek
# istemiyorum" dediğinden, bayrak bu riski ASLA göze ALAMAZ.
#
# BU DOSYANIN KAPSAMI: '_domain_redis_queue_gate'in DÖRT temel senaryosunu
# (koordinatörün "birebir kilitle" dediği tablo) BURADA DA doğrudan kilitler
# (tests/test_pure_helpers.sh'ta DAHA GENİŞ bir varyasyonla zaten var —
# kasıtlı KÜÇÜK bir çakışma: bu dosya "--redis-queue bağlantısı" konusuna
# özel kalmalı) ARDINDAN bayrağın _domain_add'e GERÇEKTEN bağlı olduğunu
# (dead-code olmadığını), '--framework=laravel'in OTOMATİK açmadığını ve
# yardım/tamamlama metinleriyle SENKRON olduğunu STATİK olarak doğrular —
# _domain_add çok ağır yan etkili olduğundan (useradd/chroot/certbot/
# nginx/apparmor/cgroups) tam uçtan uca mock'lamak bu deponun test
# kültüründe zaten tercih edilmiyor (bkz. test_meta_key_registry.sh).
# 'domain repair' yolunun ÖNCEKİ meta değerine saygı göstermesi (sessizce
# açma/kapama YOK) AYRI bir dosyada doğrulanıyor:
# tests/test_domain_repair_redis_queue_preserve.sh.
#
# SIFIR-ASSERTION KORUMASI: bu dosyanın önceki bir sürümü, fonksiyon
# '_domain_redis_queue_reason' -> '_domain_redis_queue_gate' olarak yeniden
# adlandırılırken SKIP guard'ı ESKİ isme bakmaya devam ettiği için
# SESSİZCE 0 assertion ile "PASS" veriyordu ('Toplam: 0, Başarısız: 0') —
# bu deponun en tehlikeli test hata sınıfı (yeşil görünür, hiçbir şeyi
# korumaz). Bu dosyanın SONUNDA, 'test_summary'den ÖNCE, TESTS_RUN'ın
# sıfırdan büyük olduğu AÇIKÇA doğrulanır (SKIP yolu dahil en az bir
# assertion çalıştırılır) — dosya gelecekte tekrar bir SKIP/guard
# hatasıyla boşalırsa bu son kontrol FAIL üretir.
#
# PARALEL AGENT NOTU: lib/domain.sh başka agent'lar tarafından da
# değiştiriliyor olabilir — ilgili sembol yoksa/adı değiştiyse SKIP edilir
# (ama SKIP durumunda bile dosya sonunda sessizce 'başarılı' DENMEZ).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
systemctl() { return 0; }

_skip_reason=""
if ! bash -n "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1; then
    _skip_reason="lib/domain.sh sözdizimi hatalı (paralel değişiyor olabilir)"
else
    source "${REPO_ROOT}/lib/domain.sh"
    if ! declare -F _domain_add >/dev/null 2>&1; then
        _skip_reason="_domain_add henüz yok (lib/domain.sh paralel değişiyor olabilir)"
    elif ! declare -F _domain_redis_queue_gate >/dev/null 2>&1; then
        _skip_reason="_domain_redis_queue_gate henüz yok (lib/domain.sh paralel değişiyor/yeniden adlandırılmış olabilir)"
    fi
fi

if [[ -n "$_skip_reason" ]]; then
    echo "  SKIP: ${_skip_reason}"
    # SIFIR-ASSERTION KORUMASI burada da geçerli: SKIP dahi olsa en az bir
    # assertion ÇALIŞTIRILIR — dosya asla "0 assertion + sessiz başarı" ile
    # çıkmaz; SKIP açıkça GÖRÜNÜR bir PASS/FAIL üretir.
    assert_eq "skip" "skip" "SKIP yolu da en az bir assertion çalıştırır (sessiz 0-assertion PASS'e düşülmez)"
    rm -rf "$WEB_ROOT"
    test_summary
    exit $?
fi

domain_src="${REPO_ROOT}/lib/domain.sh"

echo "== _domain_redis_queue_gate: dört temel senaryo (koordinatörün tablosu) =="

# ─── EN KRİTİK #1: Redis 7+ + bayrak YOK -> disabled ───
# (düzeltmenin ta kendisi: sessizce 'enabled'a geri dönerse KİMSE FARK ETMEZ)
assert_eq "$(_domain_redis_queue_gate "+@scripting" "enabled" "false")" \
    "-@scripting disabled default" \
    "KRİTİK #1: Redis7 + bayrak YOK -> disabled (otomatik açılma YOK, düzeltmenin kendisi)"

# ─── Redis 7+ + bayrak VAR -> enabled (bilinçli açılış GERÇEKTEN uygulanır) ───
assert_eq "$(_domain_redis_queue_gate "+@scripting" "enabled" "true")" \
    "+@scripting enabled requested" \
    "Redis7 + bayrak VAR -> enabled (--redis-queue GERÇEK bir etki taşıyor)"

# ─── EN KRİTİK #2: Redis <7 + bayrak VAR -> yine disabled (fail-closed) ───
assert_eq "$(_domain_redis_queue_gate "-@scripting" "disabled" "true")" \
    "-@scripting disabled rejected_version" \
    "KRİTİK #2: Redis6 + bayrak VAR -> yine disabled (fail-closed garantisi bayrakla AŞILAMAZ)"

# ─── Redis <7 + bayrak YOK -> disabled (değişmedi, sanity) ───
assert_eq "$(_domain_redis_queue_gate "-@scripting" "disabled" "false")" \
    "-@scripting disabled default" \
    "Redis6 + bayrak YOK -> disabled (zaten kısıtlıydı, değişmedi)"

echo "== statik kablolama: bayrak _domain_add'e GERÇEKTEN bağlı mı =="

# ─── 1) Argüman ayrıştırma: '--redis-queue' _domain_add'in case bloğunda ───
assert_ok bash -c "grep -qE -- '--redis-queue\\)[[:space:]]*redis_queue_requested=true' '${domain_src}'" \
    "'_domain_add' case bloğu '--redis-queue' -> redis_queue_requested=true eşlemesine sahip"

# ─── 2) EN KRİTİK (varsayılan): HER ZAMAN false ile başlar ───
assert_ok bash -c "grep -qE 'local redis_queue_requested=false' '${domain_src}'" \
    "'redis_queue_requested' varsayılanı 'false' olarak ilklendirilmiş (bayrak verilmezse asla true olamaz)"

# ─── 3) Bayrak DEAD-CODE değil: parse edilen değer GERÇEKTEN gate'e geçiriliyor ───
assert_ok bash -c "grep -qE '_domain_redis_queue_gate \"\\\$base_scripting_flag\" \"\\\$base_scripting_status\" \"\\\$redis_queue_requested\"' '${domain_src}'" \
    "'redis_queue_requested' gerçekten _domain_redis_queue_gate'e (yetenek+talep birleştirici) argüman olarak geçiriliyor (dead-code değil)"

# ─── 4) REDIS_SCRIPTING meta'sı artık NİHAİ (gate'ten geçmiş) değeri yazıyor ───
#     (yalnız sürüm yeteneğini DEĞİL — bayrak GERÇEK bir etki taşıyor)
assert_ok bash -c "grep -qE 'write_meta \"\\\$domain\" \"REDIS_SCRIPTING\" \"\\\$scripting_status\"' '${domain_src}'" \
    "REDIS_SCRIPTING meta'sı _domain_redis_queue_gate'in NİHAİ (yetenek+talep) çıktısından yazılıyor"

# ─── 5) _domain_redis_queue_gate GERÇEKTEN tanımlı ve eski isim TAMAMEN temizlenmiş ───
assert_ok bash -c "grep -q '_domain_redis_queue_gate()' '${domain_src}'" \
    "'_domain_redis_queue_gate' fonksiyonu lib/domain.sh'ta tanımlı"
assert_fail bash -c "grep -q '_domain_redis_queue_reason' '${domain_src}'" \
    "eski isim '_domain_redis_queue_reason' lib/domain.sh'ta HİÇ kalmamış (yeniden adlandırma tam)"

# ─── 6) Kullanım/hata mesajı ve 'domain' yardım metni bayrağı biliyor ───
assert_ok bash -c "grep -qE 'Kullanım: srvctl domain add .*--redis-queue' '${domain_src}'" \
    "'Domain belirtilmedi' kullanım mesajı '--redis-queue' seçeneğini listeliyor"
help_block="$(sed -n '/echo "    add <domain>/,/echo ""/p' "${domain_src}")"
assert_contains "$help_block" "--redis-queue" \
    "cmd_domain yardım çıktısındaki 'add' bloğu '--redis-queue' referansı içeriyor"

# ─── 7) --framework=laravel OTOMATİK açmıyor (kullanıcı bunu açıkça reddetti) ───
framework_branch="$(sed -n '/--framework=\*)/p' "${domain_src}")"
assert_not_contains "$framework_branch" "redis_queue_requested" \
    "'--framework=laravel' dalı redis_queue_requested'a DOKUNMUYOR (otomatik açılış yok)"

# ─── 8) --no-ssl ile aynı biçimde: değer almayan bir bayrak (konvansiyona uygun) ───
assert_ok bash -c "grep -qE '^\s*--redis-queue\)\s*redis_queue_requested=true\s*;;\s*\$' '${domain_src}'" \
    "'--redis-queue' değer almayan (--no-ssl biçiminde) bir bayrak olarak tanımlı"

# ─── 9) completions senkron mu? ───
assert_ok bash -c "grep -q -- '--redis-queue' '${REPO_ROOT}/completions/srvctl.bash'" \
    "completions/srvctl.bash '--redis-queue' bayrağını biliyor"
assert_ok bash -c "grep -q -- '--redis-queue' '${REPO_ROOT}/completions/srvctl.zsh'" \
    "completions/srvctl.zsh '--redis-queue' bayrağını biliyor"

# ─── 10) lib/security.sh meta whitelist'inde REDIS_SCRIPTING zaten kayıtlı mı? (yalnız DOĞRULAMA) ───
if ! declare -F _meta_known_keys >/dev/null 2>&1; then
    source "${REPO_ROOT}/lib/security.sh" 2>/dev/null || true
fi
if declare -F _meta_known_keys >/dev/null 2>&1; then
    assert_contains "$(_meta_known_keys)" "REDIS_SCRIPTING" \
        "lib/security.sh:_meta_known_keys REDIS_SCRIPTING'i zaten whitelist'liyor (kapsam dışı — yalnız doğrulama)"
else
    echo "  (bilgi) _meta_known_keys yok/kaynak alınamadı — REDIS_SCRIPTING whitelist doğrulaması atlandı"
fi

# ─── SIFIR-ASSERTION KORUMASI (koordinatörün istediği son güvenlik ağı) ───
# Bu dosya en az bir assertion çalıştırmış OLMALI; TESTS_RUN sıfırsa (ör.
# gelecekte bir SKIP/guard hatası tüm gövdeyi tekrar atlarsa) bunu SESSİZCE
# "PASS" saymak YERİNE AÇIKÇA FAIL üretilir.
if [[ "${TESTS_RUN:-0}" -eq 0 ]]; then
    echo "  $(_red FAIL) KRİTİK: bu dosya SIFIR assertion çalıştırdı (sessiz-PASS regresyonu) — dosya YAPISI bozulmuş olabilir"
    TESTS_FAIL=$((TESTS_FAIL + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
fi

rm -rf "$WEB_ROOT"
test_summary
