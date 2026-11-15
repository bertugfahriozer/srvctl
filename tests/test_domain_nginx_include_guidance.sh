#!/bin/bash
# QL6-M2: "vhost custom.d'yi include ETMİYOR" durumunda operatöre `domain repair` önerilmesi YANLIŞTI: `repair` vhost
# yazmaz (vhost'u yalnız `domain add` ve `domain rate-limit` üretir). Doğru metin: elle include + nginx -t
# (ya da rate-limit ile şablondan yeniden üretim; yan etkisi söylenerek).
#   A  ÖNCÜL kilidi: _domain_write_vhost'u yalnız _domain_add ve _domain_rate_limit çağırır; _domain_repair çağırmaz
#      (repair bir gün vhost yazarsa bu test kırılır → yönlendirme metinleri gözden geçirilmeli)
#   B  srvctl README: eski yanlış cümle YOK; doğru yönlendirme (elle include, rate-limit yan etkisi) VAR
#   C  `domain help` nginx girdisi doğru yönlendirmeyi söyler
#   D  domconf.sh'ın "include ETMİYOR" hata iletileri (domain nginx, fm-auth on) repair'e YÖNLENDİRMEZ ve elle include söyler
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "── A: önçül — vhost'u kim yazar ──"
callers=$(awk '/^_[a-zA-Z0-9_]+\(\) *\{/{fn=$1} /^[[:space:]]*_domain_write_vhost[[:space:]]+"/{print fn}' "${REPO_ROOT}"/lib/*.sh | sort -u | tr '\n' ' ')
assert_eq "$callers" "_domain_add() _domain_rate_limit() " "A: _domain_write_vhost çağıranlar yalnız add + rate-limit"
rep_body=$(awk '/^_domain_repair\(\)/{f=1} f{print} f&&/^}/{exit}' "${REPO_ROOT}/lib/domain.sh")
assert_contains "$rep_body" "_domain_load_conf_lib" "A: (ön koşul) _domain_repair gövdesi çıkarıldı"
assert_not_contains "$rep_body" "_domain_write_vhost" "A: _domain_repair gövdesi vhost YAZMIYOR (önerme gerekçesi)"
assert_not_contains "$rep_body" "vhost.conf.tpl" "A: _domain_repair vhost şablonunu render etmiyor"

echo "── B: srvctl README ──"
RM="$(cat "${REPO_ROOT}/README.md")"
assert_not_contains "$RM" 'srvctl domain repair
> <domain>` önerir' "B: eski yanlış cümle (include yoksa repair öner) README'de YOK"
assert_contains "$RM" '`domain repair` bunun çaresi DEĞİLDİR' "B: README repair'in çare olmadığını söylüyor"
assert_contains "$RM" 'include /etc/nginx/custom.d/<safe_name>/*.conf;' "B: README elle include satırını veriyor"
assert_contains "$RM" 'domain rate-limit <domain> <mevcut-profil>' "B: README rate-limit yolunu anıyor"
assert_contains "$RM" 'vhost'"'"'taki tüm elle düzenlemeler kaybolur' "B: README rate-limit yan etkisini yazıyor"

echo "── C: domain help (nginx girdisi) ──"
H=$(
  set +e
  source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
  require_root() { :; }
  source "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1
  cmd_domain help 2>&1
)
assert_contains "$H" "'repair' vhost YAZMAZ" "C: help: repair vhost yazmaz"
assert_contains "$H" "/etc/nginx/custom.d/<safe_name>/*.conf;' ekleyip nginx -t" "C: help: elle include + nginx -t"

echo "── D: domconf iletileri ──"
DC="$(cat "${REPO_ROOT}/lib/domconf.sh")"
n_msgs=$(grep -c "include ETMİYOR" <<< "$DC")
assert_eq "$([[ "$n_msgs" -ge 3 ]] && echo ok || echo "n=$n_msgs")" "ok" "D: (ön koşul) include-yok iletileri bulundu (>=3: domain nginx, fm-auth on, fm-root planı)"
bad=$(grep "include ETMİYOR" <<< "$DC" | grep -c "srvctl domain repair")
assert_eq "$bad" "0" "D: hiçbir include-yok iletisi 'srvctl domain repair' önermiyor"
nohint=$(grep "include ETMİYOR" <<< "$DC" | grep -vc "include /etc/nginx/custom.d/")
assert_eq "$nohint" "0" "D: her include-yok iletisi elle eklenecek include satırını söylüyor"

test_summary
