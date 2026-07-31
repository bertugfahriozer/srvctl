#!/bin/bash
# _user_key — B5 regresyonu: 'remove' dalında username doğrulama YOKTU.
#
# ESKİ KOD: 'srvctl user key add <u> <pubkey>' dalında hem validate_username
# HEM DE kullanıcı conf'unun varlık kontrolü vardı, ama 'remove' dalında
# İKİSİ DE EKSİKTİ. 'srvctl user key remove ../../root' çağrıldığında:
#   auth_keys="/home/../../root/.ssh/authorized_keys"  # == /root/.ssh/authorized_keys
#   : > "$auth_keys" 2>/dev/null || true
# — yani ROOT'un GERÇEK SSH authorized_keys dosyası SESSİZCE (2>/dev/null
# yuttuğu için hata da GÖRÜNMEDEN) SIFIRLANIYOR, üstüne "Tüm SSH key'ler
# kaldırıldı: ../../root" gibi bir "başarılı" mesajı basılıyordu. Aynı yol
# traversal deseni herhangi bir kullanıcının .ssh dizinine de uygulanabilirdi.
#
# DÜZELTME: validate_username kapısı artık 'action' dalına GİRMEDEN, HER İKİ
# dal için de ORTAK ve ERKEN uygulanıyor (domain_exists'teki validate_domain
# kapısıyla birebir aynı desen — bkz. lib/user.sh:_user_key başlık yorumu).
#
# GÜVENLİK NOTU: '_user_key' gerçek '/home/<user>/.ssh/authorized_keys'
# yoluna yazar; bu yol için (WEB_ROOT/SRVCTL_USERS_DIR'ın aksine) test-seam'i
# YOKTUR — kod '/home/${username}/...' olarak HARDCODED'dır. Bu dosyadaki
# TÜM '_user_key'/'_user_grant'/'_user_revoke'/'_user_2fa' çağrıları BİLEREK
# yalnız GEÇERSİZ (validate_username'i geçmeyen) veya conf'u OLMAYAN
# kullanıcı adlarıyla yapılır — kaynak kodu incelemesi (bkz. yukarıdaki
# fonksiyonlar) doğrulama kapısının HER İKİ durumda da herhangi bir
# '/home/...' dosya işleminden ÖNCE 'error()' ile exit ettiğini gösterir;
# yani bu test GERÇEK /root'a veya başka bir gerçek kullanıcının home'una
# ASLA dokunmadan (kod yolu oraya hiç ulaşmadan) B5 regresyonunu doğrular.
# Mutlu yol (gerçek key add/remove) HOME tabanı override edilemediğinden bu
# dosyanın kapsamı DIŞINDADIR.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_USERS_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/user.sh"

# error() ile exit eden fonksiyonu güvenle çağırmak için subshell sarmalayıcı
# (aksi halde 'exit' üst test script'ini de öldürür — bkz. test_domain_resources_preserve.sh).
_run_isolated() { ( "$@" ) 2>&1; }

# ═══════════════════════════════════════════════════════════════
# 1) validate_username DOĞRUDAN — kapının kendisi (predicate seviyesi)
# ═══════════════════════════════════════════════════════════════
assert_fail validate_username "../../root"                          # path traversal
assert_fail validate_username "/etc"                                 # mutlak yol
assert_fail validate_username ""                                     # boş
assert_fail validate_username "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # 35 > 32
assert_fail validate_username "Admin"                                 # büyük harf
assert_ok   validate_username "deployer"                              # geçerli (kontrol grubu)

# ═══════════════════════════════════════════════════════════════
# 2) _user_key — B5'İN TAM REGRESYON SENARYOSU: 'remove' dalı, path traversal
# ═══════════════════════════════════════════════════════════════
out=$(_run_isolated _user_key remove "../../root")
assert_fail _run_isolated _user_key remove "../../root"
assert_contains "$out" "Geçersiz kullanıcı adı" "'user key remove ../../root' artık gate'te reddediliyor (B5)"

out=$(_run_isolated _user_key remove "/etc")
assert_contains "$out" "Geçersiz kullanıcı adı" "'user key remove /etc' (mutlak yol) reddediliyor"

out=$(_run_isolated _user_key add "../../root" "ssh-ed25519 AAAA...")
assert_contains "$out" "Geçersiz kullanıcı adı" "'user key add ../../root <pubkey>' da aynı kapıdan reddediliyor"

# ── Conf varlık kapısı: geçerli AD FORMATI ama kullanıcı hiç yok ──
assert_fail _run_isolated _user_key remove "hicboyle_kullanici"
out2=$(_run_isolated _user_key remove "hicboyle_kullanici")
assert_contains "$out2" "Kullanıcı bulunamadı" "geçerli formatlı ama var olmayan kullanıcı conf kapısında reddediliyor"

# ═══════════════════════════════════════════════════════════════
# 3) Argümansız/eksik-argüman çağrı — P0 REGRESYONU KORUNUYOR MU?
#    Eski hata: set -u altında 3. argüman (pubkey) hiç verilmeden 'user key
#    remove <ad>' çağrılınca "$3: unbound variable" ile KOMUT DÜŞÜYORDU.
#    Bu test dosyası zaten 'set -uo pipefail' altında çalıştığından (üstteki
#    'set -uo pipefail' satırı) ortam TAM OLARAK orijinal hatayı tetikleyen
#    kabuk modundadır.
# ═══════════════════════════════════════════════════════════════
out3=$(_run_isolated _user_key remove "hicboyle_kullanici")   # 3. argüman (pubkey) YOK
assert_not_contains "$out3" "unbound variable" "3. argüman (pubkey) verilmeden çağrı 'unbound variable' vermiyor (P0 korunuyor)"

out4=$(_run_isolated _user_key)                                # hiç argüman yok
assert_fail _run_isolated _user_key
assert_not_contains "$out4" "unbound variable" "argümansız çağrı 'unbound variable' vermiyor (P0 korunuyor)"
assert_contains "$out4" "Kullanım" "argümansız çağrı kullanım mesajı basıyor (crash değil)"

# ═══════════════════════════════════════════════════════════════
# 4) _user_grant / _user_revoke / _user_2fa — AYNI KAPIDAN geçiyor mu?
#    (bkz. lib/user.sh: her üçü de 'validate_username "$username" || error'
#    satırını _user_grant üzerindeki gerekçeyle paylaşır)
# ═══════════════════════════════════════════════════════════════
g_out=$(_run_isolated _user_grant "../../root" "example.com")
assert_fail _run_isolated _user_grant "../../root" "example.com"
assert_contains "$g_out" "Geçersiz kullanıcı adı" "_user_grant path traversal kullanıcı adını reddediyor"

r_out=$(_run_isolated _user_revoke "../../root" "example.com")
assert_fail _run_isolated _user_revoke "../../root" "example.com"
assert_contains "$r_out" "Geçersiz kullanıcı adı" "_user_revoke path traversal kullanıcı adını reddediyor"

f_out=$(_run_isolated _user_2fa "setup" "../../root")
assert_fail _run_isolated _user_2fa "setup" "../../root"
assert_contains "$f_out" "Geçersiz kullanıcı adı" "_user_2fa path traversal kullanıcı adını reddediyor"

# Büyük harf / 32+ karakter de aynı kapıdan _user_grant için reddedilsin
assert_fail _run_isolated _user_grant "Admin" "example.com"
assert_fail _run_isolated _user_grant "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "example.com"

rm -rf "$WEB_ROOT" "$SRVCTL_USERS_DIR"
test_summary
