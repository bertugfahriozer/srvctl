#!/bin/bash
# QL4-M1: 'domain add' /_fm 403 kökünü kuramıyorsa FAIL-CLOSED.
#  (1) ÖN KOŞUL KAPISI — HİÇBİR alan kaynağı yaratılmadan: QL4 dev labının (ql4/dev/raw/m2.out)
#      /_fm=200 veren 12 modunun HEPSİ + kalıntı kayıt/yarım yedek → add rc≠0, kaynak YOK, kayıt YOK.
#      Kaynak "tuzağı": groupadd (add'in İLK kaynak yaratan komutu) çağrılırsa test 99 ile düşer.
#  (2) KAPI SONRASI — kök kurulumu yine de başarısız olursa (nginx -t, yarış, domconf yüklenemez):
#      add 'error' → EXIT tuzağı → _domain_add_rollback; vhost CANLIYA (nginx_test+reload) ve SSL'e
#      HİÇ gidilmez; alan dizini/custom.d/kayıt kalmaz.
#  (3) 'domain clone' / 'domain staging' aynı kapıdan geçer.
# Gerçek nginx 1.28 labında /_fm davranışı: tests/test_domconf_fm_probe_real.sh ve tests/test_domconf_fm_f7_real.sh (gerçek nginx kullanır).
# shellcheck disable=SC2034  # MOCK_BAD_OWNER: fm_env.sh _stat_owner taklidi okur (bu dosyada atanır, orada okunur)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
RES_LOG="${FM_STUBS}/res.log"
D=newsite.com; S=newsite_com
NDIR="${SRVCTL_NGINX_CUSTOM_DIR}/${S}"; NMAN="${SRVCTL_STATE_DIR}/_fm-auth/${S}.manifest"; SD="${SRVCTL_STATE_DIR}/_fm-auth"
php_version_exists() { return 0; }
_domain_capacity_check() { :; }
mysql() { echo "mysql $*" >> "$RES_LOG"; return 1; }
certbot() { echo "certbot $*" >> "$RES_LOG"; return 1; }
# Kaynak TUZAĞI: kapı geçilirse add'in ilk kaynak komutu → alt kabuk 99 ile biter (başka hiçbir adım koşmaz).
groupadd() { echo "RESOURCE groupadd $*" >> "$RES_LOG"; exit 99; }
_add() { : > "$RES_LOG"; ( _domain_add "$D" --no-ssl ) >"$OUTF" 2>&1; }
_gate_reset() {
    _fm_reset
    rm -rf -- "${NDIR:?}" "${SD:?}" "${WEB_ROOT:?}/${D}" "${SRVCTL_STATE_DIR:?}/${D}" "${SITES_AVAILABLE:?}/${D}.conf"
    chmod 755 "$SRVCTL_NGINX_CUSTOM_DIR" 2>/dev/null
}
# Kapı reddi: rc≠0, tuzak tetiklenmedi, alan dizini/kayıt yok, ileti açık.
_assert_gate_refused() {
    local tag="$1" rc="$2" pre_cd="$3" pre_man="$4"
    assert_eq "$([[ "$rc" != 0 && "$rc" != 99 ]] && echo red || echo "rc=$rc")" "red" "${tag}: add rc≠0 (tuzaktan ÖNCE durdu)"
    assert_eq "$(grep -c '^RESOURCE' "$RES_LOG")" "0" "${tag}: HİÇBİR kaynak komutu çalışmadı"
    assert_eq "$(_exists "${WEB_ROOT}/${D}")$(_exists "${SRVCTL_STATE_DIR}/${D}")" "yokyok" "${tag}: alan dizini / hardened işareti YOK"
    assert_eq "$(_ls_sig "$NDIR")" "$pre_cd" "${tag}: custom.d/${S} değişmedi"
    assert_eq "$(_man_sig)" "$pre_man" "${tag}: köken kaydı değişmedi (yazılmadı)"
    assert_contains "$(cat "$OUTF")" "domain add DURDURULDU (hiçbir kaynak oluşturulmadı)" "${tag}: ileti"
}
_ls_sig() { if [[ -e "$1" || -L "$1" ]]; then ( ls -la "$1" 2>/dev/null | awk '{print $1, $NF}' | grep -v ' \.$\| \.\.$'; [[ -d "$1" && ! -L "$1" ]] && find "$1" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort ) | cksum; else echo yok; fi; }
_man_sig() { if [[ -e "$NMAN" || -L "$NMAN" ]]; then { _mode "$NMAN"; cksum < "$NMAN" 2>/dev/null; } | tr '\n' ' '; else echo yok; fi; }   # _mode: fm_env (GNU önce, BSD yedek)

echo "── 0: pozitif kontrol — sağlıklı durumda kapı GEÇER ve tuzak tetiklenir (test kör değil) ──"
_gate_reset
_add; rc=$?
assert_eq "$rc" "99" "sağlıklı: kapı geçti, ilk kaynak komutuna (tuzak) ulaşıldı"
assert_eq "$(grep -c '^RESOURCE groupadd' "$RES_LOG")" "1" "tuzak bir kez"
_gate_reset; mkdir -p "$SD"; chmod 700 "$SD"; : > "${SD}/.lock"
_add; assert_eq "$?" "99" "sağlıklı (kayıt dizini + kilit dosyası var): kapı geçer"

echo "── 1: m2.out'un /_fm=200 veren 12 modu → kapı REDDİ ──"
# S2: kilit alınamıyor (kilit dosyası var, flock rc 1)
_gate_reset; mkdir -p "$SD"; chmod 700 "$SD"; : > "${SD}/.lock"; FLOCK_RC=1; export FLOCK_RC
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?; FLOCK_RC=0; export FLOCK_RC
_assert_gate_refused "S2 kilit alınamıyor" "$rc" "$pc" "$pm"
assert_contains "$(cat "$OUTF")" "kilidi alınamadı" "S2: neden"
# S2b: kayıt dizini yokken de flock çalışmıyorsa (/dev/null sondası)
_gate_reset; FLOCK_RC=1; export FLOCK_RC; pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?; FLOCK_RC=0; export FLOCK_RC
_assert_gate_refused "S2b flock çalışmıyor (dizin yok)" "$rc" "$pc" "$pm"
# S3: flock YOK
_gate_reset
NOFL="$(mktemp -d)"
for c in mktemp sed tr cat cp mv rm chmod stat awk mkdir dirname basename cmp cut wc grep ls find head tail sort shasum sha256sum date readlink printf env bash sh id uname openssl; do
    p=$(PATH="${PATH//${FM_STUBS}:/}" command -v "$c" 2>/dev/null) && [[ -n "$p" && "$p" == /* ]] && ln -sf "$p" "${NOFL}/${c}"
done
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); : > "$RES_LOG"; ( PATH="$NOFL"; _domain_add "$D" --no-ssl ) >"$OUTF" 2>&1; rc=$?
_assert_gate_refused "S3 flock YOK" "$rc" "$pc" "$pm"
assert_contains "$(cat "$OUTF")" "flock bulunamadı" "S3: neden"
rm -rf "${NOFL:?}"
# S4: kayıt dizini sahibi root değil
_gate_reset; mkdir -p "$SD"; chmod 700 "$SD"; MOCK_BAD_OWNER="$SD"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?; MOCK_BAD_OWNER=""
_assert_gate_refused "S4 kayıt dizini root sahipli değil" "$rc" "$pc" "$pm"
assert_contains "$(cat "$OUTF")" "güvenilmez" "S4: neden"
# S6: kayıt dizini sembolik bağ
_gate_reset; mkdir -p "${FM_STUBS}/elsewhere"; ln -s "${FM_STUBS}/elsewhere" "$SD"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "S6 kayıt dizini sembolik bağ" "$rc" "$pc" "$pm"
assert_eq "$(ls -A "${FM_STUBS}/elsewhere" | wc -l | tr -d ' ')" "0" "S6: bağ hedefine hiçbir şey yazılmadı"
rm -f "$SD"
# S7/S8: FM adlı KAYITSIZ kullanıcı dosyası (20 / 90)
for spec in "S7|20-srvctl-fm-upload.conf" "S8|90-srvctl-fm-auth.conf"; do
    tag="${spec%%|*}"; fn="${spec#*|}"
    _gate_reset; mkdir -p "$NDIR"; printf 'location = /user { return 200 "u"; }\n' > "${NDIR}/${fn}"
    pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
    _assert_gate_refused "${tag} kayıtsız ${fn}" "$rc" "$pc" "$pm"
    assert_contains "$(cat "$OUTF")" "${fn} köken kaydı OLMADAN diskte" "${tag}: neden"
done
# S9: FM adlı SARKAN sembolik bağ (21)
_gate_reset; mkdir -p "$NDIR"; ln -s /nonexistent-fm-gate "${NDIR}/21-srvctl-fm-download.conf"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "S9 sarkan bağ 21" "$rc" "$pc" "$pm"
# S10: custom.d/<sname> yazılamaz (0555) — root olmayan test kullanıcısında ölçülebilir
_gate_reset; mkdir -p "$NDIR"; chmod 555 "$NDIR"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
if [[ "$(id -u)" != 0 ]]; then
    _assert_gate_refused "S10 custom.d yazılamaz" "$rc" "$pc" "$pm"
    assert_contains "$(cat "$OUTF")" "yazılamaz" "S10: neden"
fi
chmod 755 "$NDIR"
# S11: custom.d/<sname> bir DOSYA
_gate_reset; : > "$NDIR"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "S11 custom.d/<sname> dosya" "$rc" "$pc" "$pm"
assert_contains "$(cat "$OUTF")" "dizin değil" "S11: neden"
rm -f "$NDIR"
# S13/S14/S15: bozuk / boş / 0666 köken kaydı (bu alan için kalıntı)
for spec in "S13|garbage|600" "S14||600" "S15||666"; do
    IFS='|' read -r tag body mode <<< "$spec"
    _gate_reset; mkdir -p "$SD"; chmod 700 "$SD"; printf '%s' "$body" > "$NMAN"; chmod "$mode" "$NMAN"
    pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
    _assert_gate_refused "${tag} kayıt (${body:-boş}, ${mode})" "$rc" "$pc" "$pm"
    assert_contains "$(cat "$OUTF")" "KALINTI köken kaydı" "${tag}: neden"
done
echo "── 1b: ek kapı modları — geçerli kalıntı kayıt (M2 add yolu), yarım işlem yedeği, custom.d bağ ──"
_gate_reset; ( _domconf_fm_root_provision "$D" 0 ) >/dev/null 2>&1; rm -rf "$NDIR"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "geçerli kalıntı kayıt (state off), custom.d yok" "$rc" "$pc" "$pm"
_gate_reset; mkdir -p "${SD}/.bk.${S}.Ab12Cd"; chmod 700 "$SD"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "yarım işlem yedeği" "$rc" "$pc" "$pm"
assert_contains "$(cat "$OUTF")" "yarım işlem yedeği" "yarım yedek: neden"
_gate_reset; mkdir -p "${FM_STUBS}/cd-target"; ln -s "${FM_STUBS}/cd-target" "$NDIR"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "custom.d/<sname> sembolik bağ" "$rc" "$pc" "$pm"
rm -f "$NDIR"
_gate_reset; mkdir -p "$SD"; ln -s /etc/hosts "${SD}/.lock"; chmod 700 "$SD"
pc=$(_ls_sig "$NDIR"); pm=$(_man_sig); _add; rc=$?
_assert_gate_refused "kilit dosyası sembolik bağ" "$rc" "$pc" "$pm"
rm -f "${SD}/.lock"

echo "── 2: KAPI SONRASI kök kurulamazsa FAIL-CLOSED (iki kol) — canlıya/SSL'e gidilmez, geri alınır ──"
# Ağır adımlar taklit; groupadd artık tuzak değil (kayıt tutar).
_post_stubs() {
    groupadd() { echo "res groupadd $*" >> "$RES_LOG"; }
    useradd() { echo "res useradd $*" >> "$RES_LOG"; }
    usermod() { :; }
    mknod() { :; }
    setfacl() { :; }
    _domain_apply_fs_ownership() { :; }
    _domain_fs_plan() { :; }
    _apply_chroot_php_deps() { :; }
    _domain_fpm_purge_ghost_pools() { :; }
    _domain_add_bootstrap_shared_fpm() { return 0; }
    render_template() { :; }
    _domain_write_vhost() { printf 'server {\n    include /etc/nginx/custom.d/%s/*.conf;\n}\n' "$(safe_name "$1")" > "${SITES_AVAILABLE}/$1.conf"; echo "vhost $1 $4" >> "$RES_LOG"; }
    nginx_test() { echo "ADD_NGINX_TEST" >> "$RES_LOG"; return 0; }
    aa-disable() { :; }
    userdel() { :; }
    groupdel() { :; }
}
_post_add() { : > "$RES_LOG"; : > "$RELOAD_LOG"; ( _post_stubs; eval "$1"; _domain_add "$D" ) >"$OUTF" 2>&1; }
_assert_post_failclosed() {
    local tag="$1" rc="$2"
    assert_eq "$([[ "$rc" != 0 ]] && echo red || echo rc0)" "red" "${tag}: add rc≠0"
    assert_eq "$(grep -c '^vhost ' "$RES_LOG")" "1" "${tag}: (kontrol) kapı geçti, vhost aşamasına gelindi"
    assert_eq "$(grep -c '^ADD_NGINX_TEST' "$RES_LOG")" "0" "${tag}: add'in nginx_test+reload adımına (canlıya) GİDİLMEDİ"
    assert_eq "$(grep -c '^certbot --nginx' "$RES_LOG")" "0" "${tag}: SSL'e (certbot) GİDİLMEDİ"
    assert_contains "$(cat "$OUTF")" "Kısmi kaynaklar geri alındı" "${tag}: geri alma çalıştı"
    assert_eq "$(_exists "${WEB_ROOT}/${D}")$(_exists "$NDIR")$(_exists "$NMAN")$(_exists "${SRVCTL_STATE_DIR}/${D}")" "yokyokyokyok" "${tag}: alan dizini / custom.d / kayıt / işaret kalmadı"
}
# 2a: kök kurulumunda nginx -t başarısız
_gate_reset; _post_add 'NGINX_TEST_RC=1'; rc=$?
_assert_post_failclosed "2a nginx -t" "$rc"
assert_contains "$(cat "$OUTF")" "/_fm 403 kökü KURULAMADI" "2a: ileti"
# 2b: provision başka nedenle (yarış) başarısız
_gate_reset; _post_add '_domconf_fm_root_provision() { return 1; }'; rc=$?
_assert_post_failclosed "2b provision rc 1" "$rc"
# 2c: 'else' kolu — domconf modülü bu noktada yüklenemiyor
_gate_reset; _post_add '_domain_load_conf_lib() { [[ -e "${SITES_AVAILABLE}/'"$D"'.conf" ]] && return 1; return 0; }'; rc=$?
_assert_post_failclosed "2c domconf yüklenemez" "$rc"
assert_contains "$(cat "$OUTF")" "domconf modülü yüklenemedi" "2c: ileti"
# kontrol: kök kurulabiliyorsa add ilerler (nginx_test'e ulaşır) — fail-closed yalnız başarısızlıkta
_gate_reset; _post_add 'nginx_test() { echo ADD_NGINX_TEST >> "$RES_LOG"; exit 42; }'; rc=$?
assert_eq "$rc" "42" "kontrol: kök kuruldu → add canlı adıma (nginx_test) ilerledi"
assert_eq "$(_exists "$NMAN")" "yok" "kontrol: (rollback sonrası) kayıt temizlendi"

echo "── 3: clone / staging aynı kapıdan geçer ──"
_gate_reset
SRC=kaynak.com; mkdir -p "${WEB_ROOT}/${SRC}" "${SRVCTL_NGINX_CUSTOM_DIR}/kaynak_com"
mkdir -p "$NDIR"; printf 'location = /user { return 200 "u"; }\n' > "${NDIR}/20-srvctl-fm-upload.conf"
: > "$RES_LOG"; ( _domain_clone "$SRC" "$D" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$([[ "$rc" != 0 && "$rc" != 99 ]] && echo red || echo "rc=$rc")" "red" "clone: hedefte kayıtsız 20 → kapı reddi"
assert_eq "$(grep -c '^RESOURCE' "$RES_LOG")" "0" "clone: hiçbir kaynak komutu çalışmadı"
assert_contains "$(cat "$OUTF")" "domain add DURDURULDU" "clone: kapı iletisi"
_gate_reset
SDOM="staging.${SRC}"; SNDIR="${SRVCTL_NGINX_CUSTOM_DIR}/$(safe_name "$SDOM")"
mkdir -p "$SNDIR"; ln -s /nonexistent-fm-gate "${SNDIR}/90-srvctl-fm-auth.conf"
: > "$RES_LOG"; ( _domain_staging "$SRC" ) >"$OUTF" 2>&1; rc=$?
assert_eq "$([[ "$rc" != 0 && "$rc" != 99 ]] && echo red || echo "rc=$rc")" "red" "staging: hedefte sarkan 90 → kapı reddi"
assert_eq "$(grep -c '^RESOURCE' "$RES_LOG")" "0" "staging: hiçbir kaynak komutu çalışmadı"
rm -rf -- "${SNDIR:?}" "${WEB_ROOT:?}/${SRC:?}" "${SRVCTL_NGINX_CUSTOM_DIR:?}/kaynak_com"

test_summary
