#!/bin/bash
# QL5-M3: bilinmeyen alt komut kullanımı basar AMA rc≠0 döner (eskiden 0: eski kurulu srvctl'de olmayan bir alt komutu —
# ör. `domain fm-root` — çağıran betik sahte başarı görüyordu). Açık yardım istekleri (help/-h/--help) rc 0 KALIR.
# Kapsam: kullanım dağıtıcısı `*)` dalı olan TÜM cmd_* (deploy hariç: onun `*)` dalı bir domain deploy'udur).
#   A  <cmd> zzz-bilinmeyen-alt-komut → rc≠0 + kullanım metni basıldı + "Bilinmeyen" uyarısı
#   B  <cmd> help | -h | --help → rc 0 + kullanım metni
#   D  <cmd> (argümansız) → rc 0 + kullanım metni, "Bilinmeyen" yok (14 dağıtıcı; self-update hariç) — QL6-M7
#   C  (domain/selfupdate dışı) kapsam kilidi: her lib/<modül>.sh dağıtıcısının `*)` dalında `return "$_usage_rc"` VAR
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="${T}/www" SRVCTL_STATE_DIR="${T}/state"
mkdir -p "$WEB_ROOT" "$SRVCTL_STATE_DIR"

# modül:cmd_fonksiyonu:kullanım-metninde-geçen-belirteç
CASES="domain:cmd_domain:Kullanım: srvctl domain
selfupdate:cmd_selfupdate:Kullanım: srvctl self-update
backup:cmd_backup:Kullanım: srvctl backup
changelog:cmd_changelog:Kullanım: srvctl changelog
cloudflare:cmd_cloudflare:Kullanım: srvctl cloudflare
cron:cmd_cron:srvctl cron
ip:cmd_ip:Kullanım: srvctl ip
notify:cmd_notify:Kullanım: srvctl notify
plugin:cmd_plugin:Kullanım: srvctl plugin
ssl:cmd_ssl:Kullanım: srvctl ssl
monitor:cmd_monitor:Kullanım: srvctl monitor
user:cmd_user:Kullanım: srvctl user
webhook:cmd_webhook:Kullanım: srvctl webhook
security:cmd_security:Kullanım: srvctl security
trusted:cmd_trusted:Kullanım: srvctl trusted"

n=0; nd=0
while IFS=: read -r mod fn marker; do
    [[ -n "$mod" ]] || continue
    n=$((n+1))
    run() {   # $1.. = cmd_ argümanları; çıktı+rc
        ( set +e
          source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
          SRVCTL_ROOT="${T}/root"; mkdir -p "$SRVCTL_ROOT/lib" "$SRVCTL_ROOT/conf"
          export CF_API_TOKEN="test-token-asla-kullanilmaz"   # cmd_cloudflare dağıtımdan ÖNCE token ister (önceden var olan sıra)
          log_action() { :; }; require_root() { :; }
          # shellcheck source=/dev/null
          source "${REPO_ROOT}/lib/${mod}.sh" >/dev/null 2>&1
          "$fn" "$@" 2>&1 </dev/null
          echo "RC=$?" )
    }
    out=$(run zzz-bilinmeyen-alt-komut)
    rc="${out##*RC=}"
    assert_eq "$([[ "$rc" =~ ^[0-9]+$ && "$rc" -ne 0 ]] && echo NONZERO || echo "ZERO($rc)")" "NONZERO" "A[$mod]: bilinmeyen alt komut rc≠0"
    assert_contains "$out" "$marker" "A[$mod]: kullanım metni yine basıldı"
    assert_contains "$out" "Bilinmeyen" "A[$mod]: bilinmeyen alt komut uyarısı (stderr) yazıldı"
    for h in help -h --help; do
        out=$(run "$h"); rc="${out##*RC=}"
        assert_eq "$rc" "0" "B[$mod]: '$h' rc 0 (açık yardım isteği hata sayılmaz)"
        assert_contains "$out" "$marker" "B[$mod]: '$h' kullanım metnini basar"
    done
    # QL6-M7: ARGÜMANSIZ çağrı = örtük help → rc 0 + kullanım metni, "Bilinmeyen" uyarısı YOK. (self-update hariç:
    # onun argümansız varsayılanı `run`, yani güncellemeyi çalıştırır — kullanım dağıtıcısı değildir.)
    if [[ "$mod" != "selfupdate" ]]; then
        out=$(run); rc="${out##*RC=}"
        assert_eq "$rc" "0" "D[$mod]: argümansız çağrı rc 0 (örtük help hata sayılmaz)"
        assert_contains "$out" "$marker" "D[$mod]: argümansız çağrı kullanım metnini basar"
        assert_not_contains "$out" "Bilinmeyen" "D[$mod]: argümansız çağrı 'Bilinmeyen' uyarısı vermez"
        nd=$((nd+1))
    fi
done <<< "$CASES"
assert_eq "$n" "15" "(ön koşul) 15 dağıtıcı sınandı"
assert_eq "$nd" "14" "(ön koşul) 14 dağıtıcıda argümansız çağrı sınandı (self-update hariç)"

echo "── C: kapsam kilidi — dağıtıcıların * dalı rc'yi taşıyor ──"
for mod in domain selfupdate backup changelog cloudflare cron ip notify plugin ssl monitor user webhook security trusted; do
    c=$(grep -c 'return "\$_usage_rc"' "${REPO_ROOT}/lib/${mod}.sh" || true)
    assert_eq "$c" "1" "C[$mod]: lib/${mod}.sh * dalında tek 'return \"\$_usage_rc\"'"
done
echo "── D: README kuralı belgeli ──"
assert_contains "$(cat "${REPO_ROOT}/README.md")" "**Bilinmeyen alt komut:**" "D: README: bilinmeyen alt komut → rc 1 kuralı"
test_summary
