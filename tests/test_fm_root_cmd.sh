#!/bin/bash
# QL4-M4: 'srvctl domain fm-root <alan>|--all [--apply]' — YALNIZ /_fm 403 kökü ve FM dosyaları.
#  - varsayılan KURU: hiçbir dosya/dizin yazmaz, nginx -t/reload çağırmaz, planı basar
#  - --apply: TEK kilit, tüm alanlar TEK işlemde → TEK nginx -t → hata: HEPSİ geri, reload YOK;
#    başarı: köken kaydı (state off / kayıtlı durum) + TEK reload
#  - eylemler: YOK→kur, kayıtlı ama bozuk→kayıtlı parametrelerle yeniden üret, kayıtsız FM adı→devral
#    (<ad>.srvctl-tampered), yarım işlem yedeği→kesinti öncesine geri yükle; YAPILAMAZ: STATE-UNTRUSTED,
#    vhost custom.d include etmiyor, custom.d sembolik bağ
#  - repair'in geniş yan etkileri YOK (FPM/AppArmor/DB/Redis çağrısı yapmaz)
#  - status/selfupdate/README fm-root'a yönlendirir; README repair kapsamı doğru
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
DOMS="example.com b.com c.com"
list_all_domains() { local d; for d in $DOMS; do printf '%s\n' "$d"; done; }
for d in b.com c.com; do mkdir -p "${WEB_ROOT}/${d}"; printf 'server {\n    include /etc/nginx/custom.d/%s/*.conf;\n}\n' "$(safe_name "$d")" > "${SITES_AVAILABLE}/${d}.conf"; done
BDIR="${SRVCTL_NGINX_CUSTOM_DIR}/b_com"; CDIR2="${SRVCTL_NGINX_CUSTOM_DIR}/c_com"
BMAN="${SRVCTL_STATE_DIR}/_fm-auth/b_com.manifest"; CMAN="${SRVCTL_STATE_DIR}/_fm-auth/c_com.manifest"
_fr() { ( _domconf_fm_root_cmd "$@" ) >"$OUTF" 2>&1; }
_reset_all() { _fm_reset; rm -rf -- "${BDIR:?}" "${CDIR2:?}"; mkdir -p "$BDIR" "$CDIR2"; }
_tsig() { { find "$SRVCTL_STATE_DIR" "$SRVCTL_NGINX_CUSTOM_DIR" 2>/dev/null | LC_ALL=C sort; find "$SRVCTL_STATE_DIR" "$SRVCTL_NGINX_CUSTOM_DIR" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort; } | cksum; }
OFFTXT="$(_domconf_fm_render_off example_com)"
# F7-M1: kapalı kök alan adına özgü imza taşır → her alanın beklenen metni KENDİ sname'iyle üretilir.
OFFTXT_B="$(_domconf_fm_render_off b_com)"; OFFTXT_C="$(_domconf_fm_render_off c_com)"

echo "── A: KURU varsayılan — salt-okur, plan basar ──"
_reset_all
printf 'client_max_body_size 1m;\n' > "${CDIR2}/21-srvctl-fm-download.conf"
s0=$(_tsig)
_fr --all; rc=$?
assert_eq "$rc" "0" "kuru: hepsi uygulanabilir → 0"
assert_eq "$(_tsig)" "$s0" "kuru: state + custom.d ağacı BİT-BİT aynı"
assert_eq "$(grep -c . "$NGINX_T_LOG")$(_reloads)$(grep -c . "$FLOCK_LOG")" "000" "kuru: nginx -t / reload / kilit YOK"
assert_eq "$(_exists "${SRVCTL_STATE_DIR}/_fm-auth")" "yok" "kuru: kayıt dizini YARATILMAZ"
out=$(cat "$OUTF")
assert_contains "$out" "[example.com] YAPILACAK: 403 kökü YOK" "kuru: YOK alan listelenir"
assert_contains "$out" "[c.com] YAPILACAK: kayıtsız FM adlı dosya(lar): 21-srvctl-fm-download.conf" "kuru: kayıtsız FM adı listelenir"
assert_contains "$out" "Toplam 3 alan: 3 yapılacak, 0 sağlam, 0 yapılamaz" "kuru: özet"
assert_contains "$out" "--apply" "kuru: uygulama yolu söylenir"

echo "── B: --apply — tek kilit, tek nginx -t, tek reload, köken kaydı ──"
_fr --all --apply; rc=$?
assert_eq "$rc" "0" "apply: rc 0"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "1" "apply: TEK nginx -t (3 alan)"
assert_eq "$(_reloads)" "1" "apply: TEK reload"
assert_eq "$(grep -c . "$FLOCK_LOG")" "1" "apply: TEK kilit"
assert_eq "$(cat "$F20")|$(cat "${BDIR}/20-srvctl-fm-upload.conf")|$(cat "${CDIR2}/20-srvctl-fm-upload.conf")" "${OFFTXT}|${OFFTXT_B}|${OFFTXT_C}" "apply: üç alanda KENDİ imzasıyla 403 kökü"
assert_contains "$(cat "$MAN")$(cat "$BMAN")$(cat "$CMAN")" "state off" "apply: köken kaydı state off"
assert_ok _fmprov_is_generated example_com "$F20"
assert_ok _fmprov_is_generated c_com "${CDIR2}/20-srvctl-fm-upload.conf"
assert_eq "$(_exists "${CDIR2}/21-srvctl-fm-download.conf")$(cat "${CDIR2}/21-srvctl-fm-download.conf.srvctl-tampered")" "yokclient_max_body_size 1m;" "apply: kayıtsız 21 devralındı (adli kopya)"
assert_eq "$(find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.bk.*' | wc -l | tr -d ' ')" "0" "apply: yedek kalmadı"
out=$( (_domconf_fm_auth c.com status) 2>&1 ); assert_contains "$out" "KAPALI (403 kökü)" "apply sonrası status KAPALI"
# ARCHITECTURE §15/93(b)(1): "yazım yok → nginx -t/reload yok" YALNIZ çalışan nginx KESİN KAPALI imzası veriyorsa geçerlidir (doğrulanamayan çalışan durum "kapalı" sayılmaz ve
# diskte KAPALI kanıtı varken yeniden yüklenir). Bu dosyada canlı sonda kapalıdır; KESİN KAPALI imzası bir kanca ile verilir, kör sonda ayrı sınanır.
eval "_c13_orig_probe() $(declare -f _domconf_fm_runtime_probe | sed 1d)"
_c13_probe_closed() { _domconf_fm_runtime_probe() { _FMRT_STATE="closed"; _FMRT_DETAIL="test: kesin KAPALI imzası"; return 0; }; }
_c13_probe_blind() { _domconf_fm_runtime_probe() { _c13_orig_probe "$@"; }; }
s1=$(_tsig); : > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_c13_probe_closed
_fr --all --apply; assert_eq "$?" "0" "idempotens: ikinci apply rc 0"
assert_eq "$(_tsig)$(grep -c . "$NGINX_T_LOG")$(_reloads)" "${s1}00" "idempotens: hiçbir şey yazılmaz, nginx -t/reload YOK (çalışan KESİN KAPALI)"
_c13_probe_blind
assert_contains "$(cat "$OUTF")" "sağlam: KAPALI (403 kökü)" "idempotens: sağlam denir"

echo "── C: tek nginx -t başarısız → TÜM alanlar geri, reload YOK ──"
_reset_all; NGINX_TEST_RC=1; s0=$(_tsig)
_fr --all --apply; rc=$?
assert_eq "$rc" "1" "nginx -t hatası: rc 1"
assert_eq "$(_exists "$F20")$(_exists "${BDIR}/20-srvctl-fm-upload.conf")$(_exists "${CDIR2}/20-srvctl-fm-upload.conf")" "yokyokyok" "hiçbir alanda kök kalmadı (hepsi geri)"
assert_eq "$(_exists "$MAN")$(_exists "$BMAN")$(_exists "$CMAN")" "yokyokyok" "hiçbir köken kaydı kalmadı"
assert_eq "$(_reloads)" "0" "reload YOK"
assert_eq "$(find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.bk.*' | wc -l | tr -d ' ')" "0" "yedekler temizlendi"
assert_contains "$(cat "$OUTF")" "TÜMÜ geri alındı" "dürüst ileti"
# shellcheck disable=SC2034  # NGINX_TEST_RC: fm_env.sh nginx taklidi okur
NGINX_TEST_RC=0

echo "── D: yeniden üretim (kayıtlı durum) + açık alan açık kalır ──"
_reset_all
# F9c (§15/38): eski tetikleyici (90/21 sil) artık alanı KAPATIR (aşağıda D2); "açık alan yeniden üretilir, açık kalır" yolu STALE şablonla (kayıtlı bölge kayması, üç eser tanınan) sınanır.
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1; sed -i.b 's/^region eu/region us/' "$MAN"; rm -f "${MAN}.b"
( _domconf_fm_root_provision b.com 0 ) >/dev/null 2>&1; printf 'location = /_fm { return 200 "x"; }\n' > "${BDIR}/20-srvctl-fm-upload.conf"
DOMS="example.com b.com"; : > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_fr --all; assert_contains "$(cat "$OUTF")" "[example.com] YAPILACAK: kayıtlı dosyalar sağlam değil" "kuru: STALE açık alan → yeniden üretim"
_fr --all --apply; assert_eq "$?" "0" "regen apply: rc 0"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "varvar" "açık alan: 90/21 kayıtlı parametrelerle yenilendi (STALE)"
assert_contains "$(cat "$MAN")" "state on" "açık alan AÇIK kaldı (kayıt on)"
assert_eq "$(cat "${BDIR}/20-srvctl-fm-upload.conf")" "$OFFTXT_B" "kurcalanmış kök yeniden üretildi (b.com kendi imzasıyla)"
assert_eq "$(grep -c '^p$' "$NGINX_T_LOG")$(grep -c '^t$' "$NGINX_T_LOG")$(_reloads)" "111" "tek sonda (açık alan için), tek nginx -t, tek reload"
# D2 (F9c §15/38 TERSİNE): açık alanda 90/21 EKSİK → kayıtlı parametrelerle yeniden üretilMEZ; 403 köküne KAPANIR (eskiden: yeniden üretilir, açık kalır)
_reset_all
( _domconf_fm_auth example.com on "--script=${SCRIPT}" ) >/dev/null 2>&1; rm -f "$F90" "$F21"
DOMS="example.com"; : > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_fr --all; assert_contains "$(cat "$OUTF")" "[example.com] YAPILACAK: kayıt 'on' yazıyor ama 20/21/90 eserlerinden" "D2 kuru: 90/21 EKSİK açık alan → 403 köküne alınacak (yeniden üretim DEĞİL)"
_fr --all --apply; assert_eq "$?" "0" "D2 apply: rc 0"
assert_eq "$(_exists "$F90")$(_exists "$F21")" "yokyok" "D2: 90/21 yeniden üretilmedi"
assert_contains "$(cat "$MAN")" "state off" "D2: alan KAPANDI (kayıt off)"
assert_contains "$(cat "$OUTF")" "alan KAPATILDI" "D2: ileti 'alan KAPATILDI' (yeniden üretildi DEĞİL)"
DOMS="example.com b.com c.com"

echo "── E: YAPILAMAZ durumları ──"
_reset_all; MOCK_BAD_OWNER="${SRVCTL_STATE_DIR}/_fm-auth"; mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; chmod 700 "${SRVCTL_STATE_DIR}/_fm-auth"
_fr example.com; rc=$?
assert_eq "$rc" "1" "STATE-UNTRUSTED kuru: rc 1"
assert_contains "$(cat "$OUTF")" "YAPILAMAZ: köken kaydı/dizini güvenilmez (STATE-UNTRUSTED)" "STATE-UNTRUSTED söylenir"
_fr example.com --apply; assert_eq "$?" "1" "STATE-UNTRUSTED apply: rc 1"
assert_eq "$(_exists "$F20")" "yok" "STATE-UNTRUSTED: hiçbir şey yazılmadı"
# shellcheck disable=SC2034  # MOCK_BAD_OWNER: fm_env.sh _stat_owner taklidi okur
MOCK_BAD_OWNER=""
_reset_all; printf 'server { }\n' > "${SITES_AVAILABLE}/b.com.conf"
_fr b.com --apply; rc=$?
assert_eq "$rc" "1" "vhost include yok: rc 1"
assert_contains "$(cat "$OUTF")" "include ETMİYOR" "neden söylenir"
assert_eq "$(_exists "${BDIR}/20-srvctl-fm-upload.conf")" "yok" "include yokken kök YAZILMADI"
printf 'server {\n    include /etc/nginx/custom.d/b_com/*.conf;\n}\n' > "${SITES_AVAILABLE}/b.com.conf"
# bir alan YAPILAMAZ, diğerleri uygulanır; çıkış 1
_reset_all; rm -rf "$BDIR"; ln -s "${FM_STUBS}" "$BDIR"
_fr --all --apply; rc=$?
assert_eq "$rc" "1" "karışık: bir alan yapılamaz → rc 1"
assert_eq "$(_exists "$F20")$(_exists "${CDIR2}/20-srvctl-fm-upload.conf")" "varvar" "karışık: diğer alanlar uygulandı"
assert_eq "$(_exists "${FM_STUBS}/20-srvctl-fm-upload.conf")" "yok" "sembolik bağ hedefine YAZILMADI"
rm -f "$BDIR"; mkdir -p "$BDIR"
( _domconf_fm_root_cmd ) >/dev/null 2>&1; assert_eq "$?" "1" "argümansız: kullanım hatası"
( _domconf_fm_root_cmd example.com --bilinmeyen ) >/dev/null 2>&1; assert_eq "$?" "1" "bilinmeyen seçenek"
( _domconf_fm_root_cmd yok.test ) >/dev/null 2>&1; assert_eq "$?" "1" "olmayan alan"

echo "── F: yarım işlem yedeği → kesinti öncesine geri, sonra yeniden değerlendir ──"
_reset_all; DOMS="example.com"
( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1
# SIGKILL ortası benzetimi: on işleminin aşama-1'i — yedek (eski kök + eski kayıt) kaldı, diskte yarım on
bk="${SRVCTL_STATE_DIR}/_fm-auth/.bk.example_com.Zz9Yy8"; mkdir -p "$bk"; cp -p "$F20" "${bk}/20-srvctl-fm-upload.conf"; cp -p "$MAN" "${bk}/manifest"
_domconf_fm_render_auth example_com 8.3 "$SCRIPT" 0 > "$F90"; printf 'garbage-yarim\n' > "$F20"
_fr example.com; assert_contains "$(cat "$OUTF")" "YAPILACAK: yarım işlem yedeği" "kuru: yarım işlem görülür"
: > "$RELOAD_LOG"
_fr example.com --apply; rc=$?
assert_eq "$rc" "0" "kurtarma apply: rc 0"
assert_eq "$(_reloads)" "1" "kurtarma (başka iş yok): çalışan nginx diske hizalandı — TEK reload"
assert_eq "$(cat "$F20")" "$OFFTXT" "kurtarma: 403 kökü kesinti öncesi haline döndü"
assert_eq "$(_exists "$F90")$(_exists "$bk")" "yokyok" "kurtarma: yarım 90 ve yedek kalmadı"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); assert_contains "$out" "KAPALI (403 kökü)" "kurtarma sonrası status KAPALI"
assert_not_contains "$out" "YARIM" "…YARIM İŞLEM uyarısı kalmadı"
DOMS="example.com b.com c.com"

echo "── G: kilit + repair'in geniş yan etkileri YOK ──"
_reset_all; FLOCK_RC=1; export FLOCK_RC
_fr --all --apply; assert_eq "$?" "1" "kilit alınamazsa apply rc 1"
assert_eq "$(_exists "$F20")" "yok" "kilitsiz yazım YOK"
FLOCK_RC=0; export FLOCK_RC
body="$(declare -f _domconf_fm_root_cmd _domconf_fm_root_apply_locked _domconf_fm_root_plan)"
for w in _domain_repair systemctl\ restart php-fpm mysql redis _redis_acl_load _domain_render_fpm_unit aa-; do
    assert_not_contains "$body" "$w" "fm-root '${w}' çağırmaz (repair'in geniş yan etkisi yok)"
done
_reset_all
( _domconf_fm_root_cmd --all --apply ) >/dev/null 2>&1
assert_eq "$(grep -c '^r$' "$RELOAD_LOG")" "1" "systemctl yalnız 'reload nginx' (tek)"

echo "── H: yönlendirmeler — cmd_domain, status, selfupdate, help, README ──"
assert_contains "$(declare -f cmd_domain)" "_domconf_fm_root_cmd" "cmd_domain fm-root yönlendirir"
assert_contains "$(declare -f cmd_domain)" "fm-root <domain>|--all [--apply]" "domain yardımı fm-root'u listeler"
assert_contains "$(cat "${REPO_ROOT}/bin/srvctl")" "domain fm-root" "ana yardım fm-root'u listeler"
assert_contains "$(cat "${REPO_ROOT}/completions/srvctl.bash")" "fm-root" "bash tamamlama"
assert_contains "$(cat "${REPO_ROOT}/completions/srvctl.zsh")" "fm-root" "zsh tamamlama"
SU="$(cat "${REPO_ROOT}/lib/selfupdate.sh")"
assert_contains "$SU" "cmd_domain fm-root --all --apply" "selfupdate onaylı adım fm-root --apply"
assert_not_contains "$SU" "cmd_domain repair --all" "selfupdate artık repair --all'u OTOMATİK çalıştırmaz"
# selfupdate'in onay kolu DAVRANIŞTA: önce KURU plan, 'evet' → fm-root --all --apply; başka yanıt → apply YOK
SUL="${FM_STUBS}/su.log"
for ans in evet hayir; do
    : > "$SUL"
    ( source "${REPO_ROOT}/lib/selfupdate.sh" 2>/dev/null
      cmd_domain() { echo "cmd_domain $*" >> "$SUL"; }
      confirm() { [[ "$ANS" == "evet" ]]; }
      ANS="$ans" _selfupdate_offer_fm_root ) >/dev/null 2>&1
    if [[ "$ans" == evet ]]; then
        assert_eq "$(tr '\n' '|' < "$SUL")" "cmd_domain fm-root --all|cmd_domain fm-root --all --apply|" "selfupdate 'evet': kuru plan + fm-root --all --apply (repair YOK)"
    else
        assert_eq "$(tr '\n' '|' < "$SUL")" "cmd_domain fm-root --all|" "selfupdate 'hayır': yalnız kuru plan, apply YOK"
    fi
done
RM="$(cat "${REPO_ROOT}/README.md")"
assert_not_contains "$RM" "repair\` her alana yalnız \`/_fm\` 403 kökünü ekler" "README: yanlış 'repair yalnız kökü ekler' cümlesi YOK"
assert_contains "$RM" "srvctl domain fm-root --all" "README: kök için fm-root önerilir"
assert_contains "$RM" "Redis ACL" "README: repair'in geniş kapsamı (Redis ACL) yazılı"
assert_contains "$RM" "KÖK-YOK" "README: denetimin kök satırları belgeli"

test_summary
