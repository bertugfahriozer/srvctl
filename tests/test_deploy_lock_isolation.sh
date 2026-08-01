#!/bin/bash
# lib/deploy.sh:_deploy_lock_dir / lib/cron.sh:_cron_lock_dir — MUTASYON
# testi (GERÇEK üretim sunucusunda ölçülen DAC/root çelişkisinin
# düzeltmesi): 'srvctl cron' job'ları
# 'flock: cannot open lock file /run/srvctl/deploy-<sname>.lock:
# Permission denied' (çıkış kodu 66) ile düşüyordu — AppArmor'da HİÇBİR
# DENIED kaydı YOKTU (MAC katmanına hiç sıra gelmiyordu). Kök neden: kilit
# dizini 700 root:root idi; cron job'u ise domain'in KENDİ kullanıcısı
# (User=web_<sname>) olarak çalışıyor ve dizine hiç GİREMİYORDU.
#
# Bu dosya görev talebindeki ÜÇ ZORUNLU şartı doğrular:
#   (a) domain cron'unun kilit yolu domainin ERİŞEBİLECEĞİ bir yerde
#       (üst dizinler 711 — geçiş serbest; domain'e özel alt dizin 700 —
#       domainin KENDİ kullanıcısına ait).
#   (b) bir domain BAŞKA domainin kilidine/dizinine ERİŞEMİYOR (izolasyon
#       KORUNUYOR — farklı sname'ler farklı, birbirinden bağımsız
#       sahiplikte alt dizinler üretiyor).
#   (c) lib/deploy.sh:_deploy_lock HÂLÂ eşzamanlı deploy'u engelliyor
#       (regresyon YOK — GERÇEK flock() semantiğiyle uçtan uca doğrulanır).
#
# DÜRÜSTLÜK NOTU (bu macOS geliştirme makinesinde ölçülemeyen şeyler):
#   1) 'web_<sname>' Linux kullanıcıları bu kutuda GERÇEKTEN YOK — chown
#      bu yüzden secure_dir/secure_file içinde '2>/dev/null || true' ile
#      SESSİZCE başarısız olur (gerçek sahiplik değişmez). Bu dosya bunun
#      yerine 'chown' fonksiyonunu GÖLGELEYİP (tests/test_secure_fs.sh'
#      taki AYNI teknik) secure_dir/secure_file'ın HANGİ hedefle chown
#      ÇAĞIRMAYA ÇALIŞTIĞINI doğrular — GERÇEK çoklu-kullanıcı DAC
#      uygulamasının kendisi burada TEST EDİLEMEZ, yalnız KOD'un doğru
#      (domain başına AYRI, birbirinden FARKLI) hedefi istediği doğrulanır.
#      Gerçek izolasyonun UÇTAN UCA doğrulanması GERÇEK bir Ubuntu
#      sunucusunda 'testjob'/'escapetest' cron'larıyla yapılmalıdır (görev
#      talebi).
#   2) macOS'ta 'flock(1)' (util-linux) YOKTUR. (c) şartını GERÇEK flock()
#      SEMANTİĞİYLE (yalnız argv'yi taklit eden sahte bir ikili DEĞİL) test
#      edebilmek için burada perl'in fcntl(3) flock() sarmalayıcısıyla
#      inherited fd üzerinde ÇALIŞAN minimal bir 'flock -n <fd>' taklidi
#      kurulur (yalnız _deploy_lock'un KULLANDIĞI fd-modu desteklenir).
#      perl mevcut değilse bu bölüm AÇIKÇA UYARILIP atlanır (sessiz
#      atlama YOK).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_LOCK_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
confirm() { return 0; }
systemctl() { return 0; }
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/deploy.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/cron.sh"

_run_isolated() { ( "$@" ); }

domA="lock-domain-a.test"
domB="lock-domain-b.test"
snameA=$(safe_name "$domA")
snameB=$(safe_name "$domB")
webA="web_${snameA}"
webB="web_${snameB}"
mkdir -p "${WEB_ROOT}/${domA}" "${WEB_ROOT}/${domB}"

# ═══════════════════════════════════════════════════════════════
# chown STUB — bkz. dosya başı DÜRÜSTLÜK NOTU (1).
# ═══════════════════════════════════════════════════════════════
chown_log="${WEB_ROOT}/.chown.log"
: > "$chown_log"
chown() { printf '%s %s\n' "$1" "$2" >> "$chown_log"; return 0; }

# ═══════════════════════════════════════════════════════════════
# flock KULLANILABİLİRLİĞİNİ GARANTİYE AL — bkz. dosya başı DÜRÜSTLÜK
# NOTU (2). Bu bloğu EN BAŞTA (aşağıdaki TÜM bölümlerden ÖNCE) kurmak
# ÖNEMLİDİR: aksi halde bu makinede (macOS, util-linux 'flock' YOK)
# _deploy_lock'un 'command -v flock' kapısına bağlı kilit DOSYASI
# testleri (bölüm 2a) SESSİZCE atlanır ve GERÇEKTE hiç çalıştırılmamış
# olur — bu, "çalıştıramadığın bir şeyi çalışıyor diye raporlama"
# ilkesine aykırı bir YANLIŞ GÜVEN yaratırdı.
# ═══════════════════════════════════════════════════════════════
FAKEBIN="$(mktemp -d)"
if command -v flock >/dev/null 2>&1; then
    : # Gerçek flock ZATEN mevcut — taklide gerek yok, PATH değişmez.
elif command -v perl >/dev/null 2>&1; then
    cat > "${FAKEBIN}/flock" <<'FLOCKEOF'
#!/usr/bin/env bash
# Test-amaçlı minimal flock(1) taklidi — YALNIZ _deploy_lock'un kullandığı
# fd-modunu ('flock -n <fd>') destekler. perl'in fcntl(3) FLOCK()
# sarmalayıcısıyla, inherited fd'yi dup'layıp GERÇEK flock() syscall'ını
# çağırır — argv'yi taklit eden sahte bir ikili DEĞİLDİR.
if [[ "${1:-}" == "-n" && "${2:-}" =~ ^[0-9]+$ ]]; then
    exec perl -e '
        use Fcntl qw(:flock);
        open(my $fh, "<&=" . $ARGV[0]) or exit 1;
        flock($fh, LOCK_EX | LOCK_NB) or exit 1;
        exit 0;
    ' "$2"
fi
exit 0
FLOCKEOF
    chmod +x "${FAKEBIN}/flock"
    export PATH="${FAKEBIN}:${PATH}"
else
    warn "UYARI: ne 'flock' ne 'perl' bulunamadı — flock GEREKTİREN tüm assertion'lar bu host'ta ATLANACAK (doğrulanamaz)"
fi

# ═══════════════════════════════════════════════════════════════
# 1) FORMÜL TUTARLILIĞI — lib/deploy.sh:_deploy_lock_dir ile
#    lib/cron.sh:_cron_lock_dir AYNI domain için AYNI yolu üretiyor mu
#    (drift YOK — flock kilidini deploy TUTAR, cron KARŞI taraftan AYNI
#    dosyayı AÇMAYA çalışır; ikisi farklı hesaplarsa cron ASLA doğru
#    dosyayı bulamaz ve koruma SESSİZCE etkisiz kalır)?
# ═══════════════════════════════════════════════════════════════
: > "$chown_log"
dirA_deploy=$(_deploy_lock_dir "$snameA" "$webA")
dirA_cron=$(_cron_lock_dir "$snameA" "$webA")
assert_eq "$dirA_deploy" "$dirA_cron" \
    "1) _deploy_lock_dir ve _cron_lock_dir AYNI domain için AYNI kilit dizinini üretiyor"
assert_eq "$dirA_deploy" "${SRVCTL_LOCK_DIR}/locks/${snameA}" \
    "1) kilit dizini beklenen yapıda: <lock_base>/locks/<sname>"

# ═══════════════════════════════════════════════════════════════
# 2) (a) DOMAIN CRON'UNUN KİLİT YOLU DOMAİNİN ERİŞEBİLECEĞİ BİR YERDE:
#    üst dizinler yalnız GEÇİŞE izin verir (711 — listeleme YOK), domain'e
#    özel alt dizin ise 700 VE domain'in KENDİ kullanıcısına chown
#    edilmeye ÇALIŞILDI mı?
# ═══════════════════════════════════════════════════════════════
assert_eq "$(_stat_mode "${SRVCTL_LOCK_DIR}" | tail -c 4)" "711" \
    "2a) kilit ANA dizini 711 (web_<sname> GEÇEBİLİR, listeleyemez)"
assert_eq "$(_stat_mode "${SRVCTL_LOCK_DIR}/locks" | tail -c 4)" "711" \
    "2a) 'locks' ara dizini 711"
assert_eq "$(_stat_mode "$dirA_deploy" | tail -c 4)" "700" \
    "2a) domain A'nın kilit alt dizini 700 (yalnız o domain + root)"
assert_contains "$(cat "$chown_log")" "${webA}:${webA} ${dirA_deploy}" \
    "2a) domain A'nın alt dizini KENDİ web kullanıcısına (web_${snameA}) chown edilmeye ÇALIŞILDI"

# _deploy_lock'un GERÇEK akışı: kilit DOSYASININ KENDİSİ de domain
# kullanıcısına ait/600 olmalı (aksi halde root'un ilk oluşturduğu dosya
# varsayılan umask'la (root:root 644) kalır ve cron'un flock(1) çağrısı —
# web_<sname> olarak — dosyayı AÇAMAZ; TAM DA bu görevin düzelttiği DAC
# hata sınıfı yeniden doğardı).
if command -v flock >/dev/null 2>&1; then
    : > "$chown_log"
    ( _deploy_lock "$domA" ) # flock varsa dosyayı OLUŞTURUR ve chown dener
    lock_file="${dirA_deploy}/deploy-${snameA}.lock"
    assert_eq "$(test -f "$lock_file" && echo VAR || echo YOK)" "VAR" \
        "2a) _deploy_lock kilit DOSYASINI gerçekten oluşturdu"
    assert_eq "$(_stat_mode "$lock_file" | tail -c 4)" "600" \
        "2a) kilit dosyası mod 600"
    assert_contains "$(cat "$chown_log")" "${webA}:${webA} ${lock_file}" \
        "2a) kilit DOSYASININ KENDİSİ de domain kullanıcısına chown edilmeye ÇALIŞILDI (cron'un flock(1) açabilmesi için ZORUNLU)"
fi

# ═══════════════════════════════════════════════════════════════
# 3) (b) BİR DOMAIN BAŞKA DOMAİNİN KİLİDİNE ERİŞEMİYOR — domain B'nin
#    dizini FARKLI bir yolda, FARKLI bir sahibe (chown hedefi) chown
#    edilmeye çalışılıyor mu (izolasyonun DAC MEKANİZMASI: mod 700 +
#    domain'e özel sahiplik farkı)?
# ═══════════════════════════════════════════════════════════════
: > "$chown_log"
dirB=$(_deploy_lock_dir "$snameB" "$webB")
assert_eq "$(_stat_mode "$dirB" | tail -c 4)" "700" \
    "3b) domain B'nin kilit alt dizini de 700"
assert_contains "$(cat "$chown_log")" "${webB}:${webB} ${dirB}" \
    "3b) domain B'nin alt dizini KENDİ (A'dan FARKLI) web kullanıcısına chown edilmeye ÇALIŞILDI"
assert_not_contains "${dirA_deploy}" "${snameB}" \
    "3b) domain A'nın kilit yolu domain B'nin adını İÇERMİYOR (yollar birbirinden BAĞIMSIZ)"
if [[ "$webA" == "$webB" ]]; then
    echo "  $(printf '\033[0;31mFAIL\033[0m') 3b) domain A/B FARKLI web kullanıcısı üretmeli"
    TESTS_FAIL=$((TESTS_FAIL + 1))
else
    echo "  $(printf '\033[0;32mPASS\033[0m') 3b) domain A/B FARKLI (web_${snameA} != web_${snameB}) kullanıcı — 700 mod ile BİRLİKTE gerçek DAC izolasyonunun temelini oluşturur"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ═══════════════════════════════════════════════════════════════
# 4) (c) EŞZAMANLI DEPLOY ENGELİ — _deploy_lock HÂLÂ çalışıyor mu
#    (regresyon YOK)? 'flock' (gerçek ya da dosya başında kurulan perl
#    köprüsü) YOKSA bu bölüm AÇIKÇA uyarılıp atlanır.
# ═══════════════════════════════════════════════════════════════
if command -v flock >/dev/null 2>&1; then
    (
        _deploy_lock "$domA"
        sleep 2
    ) &
    holder_pid=$!
    sleep 1

    assert_fail _run_isolated _deploy_lock "$domA" \
        "4c) AYNI domain'e (A) eşzamanlı İKİNCİ '_deploy_lock' REDDEDİLİYOR (deploy kilidi HÂLÂ çalışıyor — regresyon yok)"

    # İzolasyon + regresyon BİRLİKTE: A'nın kilidi TUTULUYORKEN B'nin
    # kilidi ETKİLENMEMELİ (yanlış-pozitif çapraz-domain çakışma yok).
    assert_ok _run_isolated _deploy_lock "$domB"

    wait "$holder_pid" 2>/dev/null || true
else
    echo "  UYARI: (c) eşzamanlılık testi bu host'ta ÇALIŞTIRILAMADI (flock/perl yok)"
fi

rm -rf "$WEB_ROOT" "$SRVCTL_LOCK_DIR" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR" "$FAKEBIN"
test_summary
