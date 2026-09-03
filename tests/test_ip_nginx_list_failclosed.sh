#!/bin/bash
# O4 regresyonu (haftalık denetim 2026-09): nginx whitelist/blacklist yazımı
# 'nginx -t && reload || true' ile sonucu yutuyor, bozuk conf diskte kalıyor,
# çağıran "engellendi" diyordu; dosyadaki IP'ler doğrulanmıyordu.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
source "${REPO_ROOT}/lib/ip.sh"
WORK="$(mktemp -d)"
SRC="${WORK}/list.conf"; CONF="${WORK}/out.conf"
printf '1.2.3.4\nnot-an-ip\n10.0.0.0/8\n\n' > "$SRC"

NGINX_T_RC=0; RELOAD_MARK="${WORK}/reloaded"
nginx() { return "$NGINX_T_RC"; }
systemctl() { [[ "$1" == "reload" ]] && : > "$RELOAD_MARK"; return 0; }
_run() { ( "$@" ) 2>&1; }

# 1) nginx -t OK → dosya yazılır, geçersiz satır atlanır, reload olur
out=$(_ip_render_nginx_list deny "$SRC" "$CONF" "IP blacklist" 2>&1); rc=$?
assert_eq "$rc" "0" "nginx -t OK → 0"
assert_contains "$(cat "$CONF")" "deny 1.2.3.4;" "geçerli IP yazıldı"
assert_contains "$(cat "$CONF")" "deny 10.0.0.0/8;" "CIDR yazıldı"
assert_not_contains "$(cat "$CONF")" "not-an-ip" "geçersiz satır ATLANDI"
assert_contains "$out" "geçersiz IP atlandı" "geçersiz satır için uyarı"
assert_eq "$([[ -e "$RELOAD_MARK" ]] && echo 1 || echo 0)" "1" "reload çağrıldı"
GOOD="$(cat "$CONF")"

# 2) nginx -t BAŞARISIZ → 1 döner, ESKİ dosya geri gelir, reload YOK
printf '5.6.7.8\n' > "$SRC"; NGINX_T_RC=1; rm -f "$RELOAD_MARK"
out=$(_ip_render_nginx_list deny "$SRC" "$CONF" "IP blacklist" 2>&1); rc=$?
assert_eq "$rc" "1" "nginx -t başarısız → 1 (artık yutulmuyor)"
assert_eq "$(cat "$CONF")" "$GOOD" "önceki geçerli conf GERİ ALINDI"
assert_eq "$([[ -e "$RELOAD_MARK" ]] && echo 1 || echo 0)" "0" "başarısız testte reload YOK"
assert_contains "$out" "geri alındı" "operatöre açık uyarı"
assert_eq "$(ls "$WORK" | grep -c 'out.conf\.')" "0" "geçici/bak dosyası kalmadı"

# 3) nginx -t başarısız ve ÖNCEDEN dosya YOK → dosya bırakılmaz
NGINX_T_RC=1; rm -f "$CONF"
_ip_render_nginx_list allow "$SRC" "$CONF" "IP whitelist" >/dev/null 2>&1
assert_eq "$([[ -e "$CONF" ]] && echo var || echo yok)" "yok" "bozuk conf diskte BIRAKILMADI"

# 4) çağıranlar sonucu ele alıyor (yapısal)
src="$(cat "${REPO_ROOT}/lib/ip.sh")"
assert_eq "$(grep -cE '^\s*_update_nginx_(whitelist|blacklist)\s*$' "${REPO_ROOT}/lib/ip.sh")" "0" "hiçbir çağrı sonucu yutmuyor"
assert_contains "$src" 'if ufw insert 1 deny from "$ip"' "_ip_ban: ufw çıkış kodu kontrol ediliyor"
assert_not_contains "$src" 'nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
}

_update_nginx_blacklist' "eski '|| true' deseni kalmadı"

rm -rf "$WORK"
echo ""
echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
[[ "$TESTS_FAIL" -eq 0 ]]
