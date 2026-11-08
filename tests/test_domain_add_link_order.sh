#!/bin/bash
# QL5-L2: `domain add` vhost'u ETKİNLEŞTİREN bağı (sites-enabled) /_fm 403 kökü KURULDUKTAN SONRA oluşturur.
# Eskiden bağ kökten ÖNCEydi: provizyon beklerken/SIGKILL'de bağımsız bir reload köksüz vhost'u canlıya çıkarırdı.
#   A  başarılı add: olay sırası = vhost yazıldı → kök provizyonu → bağ → nginx_test (canlı adım)
#   B  provizyon BAŞARISIZ: bağ HİÇ oluşturulmadı, nginx_test/certbot'a gidilmedi, geri alma çalıştı (rollback bütünlüğü)
#   C  kök provizyonu SIRASINDA (kilit beklemesi/SIGKILL penceresi benzetimi) bağ henüz YOK
# `ln` taklidi yalnız sites-enabled bağını günlüğe alır (gerçek /etc'e dokunulmaz); diğer ln çağrıları gerçek.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"; EV="${FM_STUBS}/events.log"
D=ordersite.com; S=ordersite_com
NDIR="${SRVCTL_NGINX_CUSTOM_DIR}/${S}"
php_version_exists() { return 0; }
_domain_capacity_check() { :; }
mysql() { return 0; }
certbot() { echo "CERTBOT_${1}" >> "$EV"; return 1; }   # --nginx = SSL alma; delete = rollback temizliği
groupadd() { :; }; useradd() { :; }; usermod() { :; }; mknod() { :; }; setfacl() { :; }
_domain_apply_fs_ownership() { :; }; _domain_fs_plan() { :; }; _apply_chroot_php_deps() { :; }
_domain_fpm_purge_ghost_pools() { :; }; _domain_add_bootstrap_shared_fpm() { return 0; }
render_template() { :; }; aa-disable() { :; }; userdel() { :; }; groupdel() { :; }
_domain_write_vhost() { printf 'server {\n    include /etc/nginx/custom.d/%s/*.conf;\n}\n' "$(safe_name "$1")" > "${SITES_AVAILABLE}/$1.conf"; echo "VHOST" >> "$EV"; }
nginx_test() { echo "NGINX_TEST" >> "$EV"; exit 42; }          # canlı adım: ulaşıldığında add'i durdur
ln() {
    local a hit=false
    for a in "$@"; do [[ "$a" == */etc/nginx/sites-enabled/* ]] && hit=true; done
    if $hit; then echo "LINK $*" >> "$EV"; return 0; fi
    command ln "$@"
}
_real_provision="$(declare -f _domconf_fm_root_provision)"
# NOT: komut yerine-koyma $(…) İÇİNDE çağrılmaz — add'in EXIT-trap geri alması yerel değişkenleri orada görmez (domain: unbound)
_run() { : > "$EV"; ( eval "$1"; _domain_add "$D" --no-ssl ) >"$OUTF" 2>&1; RC=$?; }
_reset() { rm -rf -- "${NDIR:?}" "${SRVCTL_STATE_DIR:?}/_fm-auth" "${WEB_ROOT:?}/${D}" "${SRVCTL_STATE_DIR:?}/${D}" "${SITES_AVAILABLE:?}/${D}.conf"; }
_seq() { grep -v '^CERTBOT_delete' "$EV" | tr '\n' ' ' | sed 's/LINK [^ ]* [^ ]* [^ ]*/LINK/; s/ *$//'; }

echo "── A: başarılı add — sıra: VHOST → PROVISION → LINK → NGINX_TEST ──"
_reset
_run '_domconf_fm_root_provision() { echo PROVISION >> "$EV"; return 0; }'; rc=$RC
assert_eq "$rc" "42" "A: add canlı adıma (nginx_test) ulaştı (kontrol: akış sona kadar gitti)"
assert_eq "$(_seq)" "VHOST PROVISION LINK NGINX_TEST" "A: bağ, kök provizyonundan SONRA ve canlı adımdan ÖNCE"

echo "── B: provizyon başarısız — bağ HİÇ yok, canlıya/SSL'e gidilmedi, geri alma çalıştı ──"
_reset
_run '_domconf_fm_root_provision() { echo PROVISION >> "$EV"; return 1; }'; rc=$RC
assert_eq "$([[ "$rc" != 0 && "$rc" != 42 ]] && echo red || echo "rc=$rc")" "red" "B: add rc≠0 (canlı adıma ulaşmadan)"
assert_eq "$(_seq)" "VHOST PROVISION" "B: bağ OLUŞTURULMADI, nginx_test/certbot'a gidilmedi"
assert_contains "$(cat "$OUTF")" "Kısmi kaynaklar geri alındı" "B: rollback çalıştı"

echo "── C: provizyon SIRASINDA (kilit beklemesi / SIGKILL penceresi) bağ henüz YOK ──"
_reset
_run '_domconf_fm_root_provision() { if grep -q "^LINK" "$EV"; then echo "LINK_BEFORE_ROOT" >> "$EV"; else echo "NO_LINK_YET" >> "$EV"; fi; return 0; }'; rc=$RC
assert_contains "$(cat "$EV")" "NO_LINK_YET" "C: provizyon koşarken sites-enabled bağı yok"
assert_not_contains "$(cat "$EV")" "LINK_BEFORE_ROOT" "C: bağ kökten önce kurulmadı"

test_summary
