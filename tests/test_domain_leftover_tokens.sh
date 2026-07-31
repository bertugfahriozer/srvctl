#!/bin/bash
# _domain_assert_no_leftover_tokens (lib/domain.sh) — render sonrası
# "beslenmeyen token" guard'ı.
#
# GEREKÇE (DALGA 5 kapanışı — bkz. lib/domain.sh başlık yorumu): render_template
# (core.sh) beslenmeyen bir '{{TOKEN}}'ı SESSİZCE atlar ve literal metni
# ÇIKTIDA BIRAKIR (hata YOK) — bu sınıf boşluk bir oturumda ÜÇ KEZ
# tekrarlandı (önce DENY_DIRS, sonra IO_WEIGHT, sonra DOMAIN_ROOT). Her
# render-yazan fonksiyon yazdığı dosyayı bu guard'dan geçirir: PREDİKAT
# DEĞİLDİR — literal '{{' bulursa dosyayı SİLER (bozuk unit/config canlı
# sistemde kalıcı KALMASIN) ve 'error' ile EXIT eder (fail-closed; bir
# sonraki adım — systemctl daemon-reload/nginx reload — bu bozuk dosyayla
# ASLA çalışmamalı).
#
# Bu test lib/template_tokens statik tarayıcısının (tests/test_template_tokens.sh)
# RUNTIME TAMAMLAYICISIDIR — o dosya şablonları HİÇ render ETMEDEN tarar, bu
# dosya ise guard fonksiyonunun kendisini GERÇEKTEN çalıştırıp dosya
# silme + hata + exit davranışını doğrular.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/domain.sh"

# error() ile exit eden fonksiyonu güvenle çağırmak için subshell sarmalayıcı
# (aksi halde 'exit' üst test script'ini de öldürür — bkz. test_domain_resources_preserve.sh).
_run_isolated() { ( "$@" ) 2>&1; }

ex() { [[ -f "$1" ]] && echo var || echo yok; }

work="$(mktemp -d)"

# ═══ 1) Leftover '{{' YOK → dosya DOKUNULMADAN kalır, hata YOK, 0 döner ═══
clean="${work}/clean.conf"
printf 'DOMAIN=example.com\nWEB_ROOT=/var/www\n' > "$clean"
assert_ok _domain_assert_no_leftover_tokens "$clean"
assert_eq "$(ex "$clean")" var "leftover token yokken dosya SİLİNMEDİ"
assert_eq "$(cat "$clean")" "$(printf 'DOMAIN=example.com\nWEB_ROOT=/var/www')" "leftover token yokken içerik DEĞİŞMEDİ"

# ═══ 2) Leftover '{{TOKEN}}' VAR → dosya SİLİNMELİ + error() ile exit (fail-closed) ═══
dirty="${work}/dirty.conf"
printf 'DOMAIN=example.com\nReadWritePaths=-{{DOMAIN_ROOT}}\nWEB_USER=web_example_com\n' > "$dirty"
out=$(_run_isolated _domain_assert_no_leftover_tokens "$dirty")
assert_eq "$(ex "$dirty")" yok "REGRESYON KAPANDI: leftover token'lı bozuk dosya SİLİNDİ (canlı sistemde kalmadı)"
assert_contains "$out" "beslenmeyen token kaldı" "hata mesajı beslenmeyen-token uyarısını içeriyor"
assert_contains "$out" "DOMAIN_ROOT" "hata mesajı HANGİ token'ın kaldığını raporluyor (DOMAIN_ROOT)"
assert_contains "$out" "silindi" "hata mesajı dosyanın güvenlik için silindiğini bildiriyor"

# Aynı senaryo, exit kodu (fail-closed) açısından ayrıca doğrulanır — dosya
# yukarıdaki çağrıyla zaten silindiğinden burada YENİDEN oluşturulur.
dirty_retry="${work}/dirty_retry.conf"
printf 'X={{Y}}\n' > "$dirty_retry"
assert_fail _run_isolated _domain_assert_no_leftover_tokens "$dirty_retry"

# ═══ 3) BİRDEN FAZLA farklı leftover token → hepsi mesajda raporlanmalı ═══
multi="${work}/multi.conf"
printf 'A={{FOO}}\nB={{BAR}}\n' > "$multi"
out_multi=$(_run_isolated _domain_assert_no_leftover_tokens "$multi")
assert_contains "$out_multi" "FOO" "birden fazla leftover: FOO raporlandı"
assert_contains "$out_multi" "BAR" "birden fazla leftover: BAR raporlandı"
assert_eq "$(ex "$multi")" yok "birden fazla leftover token'lı dosya da silindi"

# ═══ 4) Dosya hiç yoksa → sessizce 0 döner (render zaten error ile durmuş olabilir) ═══
assert_ok _domain_assert_no_leftover_tokens "${work}/hic-yok-boyle-dosya.conf"

# ═══ 5) '{{' içeren ama TOKEN DESENİNE uymayan içerik (ör. gerçek nginx/CSS
#    içinde tesadüfen '{{' geçmesi) — grep -q '{{' yine de HERHANGİ bir
#    '{{' varlığında tetiklenir (guard'ın kasıtlı olarak KATI davranışı:
#    "belirsizlik durumunda güvenli tarafta kal"). Mesaj formatı bulunamazsa
#    varsayılan '{{...}}' ile raporlanır.
weird="${work}/weird.conf"
printf 'value={{ not_a_valid_TOKEN_pattern\n' > "$weird"
out_weird=$(_run_isolated _domain_assert_no_leftover_tokens "$weird")
assert_eq "$(ex "$weird")" yok "TOKEN desenine tam uymayan ama '{{' içeren dosya da KATI biçimde silindi (güvenli taraf)"
assert_contains "$out_weird" "{{...}}" "desene uymayan leftover için varsayılan '{{...}}' ile raporlandı"

rm -rf "$work" "$WEB_ROOT"
test_summary
