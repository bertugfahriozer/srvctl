#!/bin/bash
# O5 + O2 regresyonları (haftalık denetim 2026-09)
#
# O5: notify.sh/cloudflare.sh'taki kopya '_update_conf', değeri kaçışsız olarak
#     sed RHS'ine ('&' → eşleşme, '|' → ayırıcı) ve 'source' edilen srvctl.conf'a
#     yazıyordu → '$(...)' içeren bir değer sonraki her srvctl çağrısında root
#     olarak çalışırdı. Artık core.sh'ta tek kopya: allowlist + tırnaklı yazım.
# O2: Telegram bot token URL'de (argv), CF token '-H Authorization' ile argv'de
#     idi. Artık 'curl --config -' ile stdin'den; argv'de sır kalmaz.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/notify.sh"

WORK="$(mktemp -d)"
export SRVCTL_CONF="${WORK}/srvctl.conf"
printf '# test\nNOTIFY_EMAIL=old@example.com\nOTHER=1\n' > "$SRVCTL_CONF"
_run() { ( "$@" ) 2>&1; }

# ── O5: '&' ve '|' içeren Discord URL'si BOZULMADAN yazılır ──
URL='https://discord.com/api/webhooks/1/abc?wait=true&thread_id=9'
_run _update_conf NOTIFY_DISCORD_WEBHOOK "$URL" >/dev/null
assert_contains "$(cat "$SRVCTL_CONF")" "NOTIFY_DISCORD_WEBHOOK='${URL}'" "yeni anahtar: & içeren URL tırnaklı ve bozulmadan eklendi"
# güncelleme yolu (sed RHS): '&' eşleşmenin tamamına GENİŞLEMEMELİ
URL2='https://discord.com/api/webhooks/2/xyz?a=1&b=2'
_run _update_conf NOTIFY_DISCORD_WEBHOOK "$URL2" >/dev/null
assert_contains     "$(cat "$SRVCTL_CONF")" "NOTIFY_DISCORD_WEBHOOK='${URL2}'" "güncelleme: & sed'de genişlemedi"
assert_not_contains "$(cat "$SRVCTL_CONF")" "$URL" "güncelleme: eski değer gitti"
assert_eq "$(grep -c '^NOTIFY_DISCORD_WEBHOOK=' "$SRVCTL_CONF")" "1" "anahtar tek satır"
# source edildiğinde değer birebir geri gelir
val="$(bash -c "source '$SRVCTL_CONF'; printf '%s' \"\$NOTIFY_DISCORD_WEBHOOK\"")"
assert_eq "$val" "$URL2" "source sonrası değer birebir"
# mevcut anahtar güncelleme (e-posta)
_run _update_conf NOTIFY_EMAIL "new@example.com" >/dev/null
assert_contains "$(cat "$SRVCTL_CONF")" "NOTIFY_EMAIL='new@example.com'" "mevcut anahtar güncellendi"
assert_contains "$(cat "$SRVCTL_CONF")" "OTHER=1" "diğer satırlar korundu"

# ── O5: komut-substitution / tırnak / boşluk içeren değer REDDEDİLİR ──
before="$(cat "$SRVCTL_CONF")"
for bad in 'x$(id)y' 'x`id`y' "a'b" 'a"b' 'a b' 'a;b' 'a|b' $'a\nb'; do
    assert_fail _run _update_conf NOTIFY_SLACK_WEBHOOK "$bad"
done
assert_eq "$(cat "$SRVCTL_CONF")" "$before" "reddedilen değerler dosyaya DOKUNMADI"
assert_fail _run _update_conf 'BAD KEY' "x"
assert_fail _run _update_conf 'A;B' "x"

# ── O2: Telegram — token argv'de değil, curl config satırlarında; kaçışlama ──
NOTIFY_TELEGRAM_TOKEN='123:SECRET"tok'; NOTIFY_TELEGRAM_CHAT_ID="42"
lines="$(_curl_cfg_lines_telegram $'Merhaba "dünya" & a=b\nikinci\\son')"
assert_contains "$lines" 'url = "https://api.telegram.org/bot123:SECRET\"tok/sendMessage"' "url satırı: token kaçışlanmış"
assert_contains "$lines" 'data-urlencode = "chat_id=42"' "chat_id satırı"
assert_contains "$lines" 'data-urlencode = "text=Merhaba \"dünya\" & a=b\nikinci\\son"' "text: tırnak/yeni satır/backslash kaçışlandı"
assert_contains "$lines" 'data-urlencode = "parse_mode=Markdown"' "parse_mode satırı"
# _send_telegram'ın kendisi token'ı argv'ye KOYMAZ (yapısal)
src="$(declare -f _send_telegram)"
assert_not_contains "$src" 'bot${NOTIFY_TELEGRAM_TOKEN}' "_send_telegram: token URL argümanında DEĞİL"
assert_contains     "$src" -- '--config -' "_send_telegram: --config - kullanıyor"

# ── O2: Cloudflare — Authorization header argv'de değil ──
cf_src="$(cat "${REPO_ROOT}/lib/cloudflare.sh")"
assert_not_contains "$cf_src" '-H "Authorization: Bearer ${CF_API_TOKEN}"' "cloudflare: token -H argv'sinde DEĞİL"
assert_not_contains "$cf_src" '-H "Authorization: Bearer ${token}"'        "cloudflare setup: token -H argv'sinde DEĞİL"
assert_eq "$(grep -c "header = \"Authorization: Bearer %s\"" "${REPO_ROOT}/lib/cloudflare.sh")" "2" "cloudflare: iki çağrı da --config - ile"
# kopya _update_conf'lar gitti
assert_eq "$(grep -c '^_update_conf()' "${REPO_ROOT}/lib/notify.sh" "${REPO_ROOT}/lib/cloudflare.sh" | awk -F: '{s+=$2} END{print s}')" "0" "kopya _update_conf tanımları kaldırıldı"

rm -rf "$WORK"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
