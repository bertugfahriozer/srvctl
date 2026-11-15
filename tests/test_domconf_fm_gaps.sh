#!/bin/bash
# shellcheck disable=SC2034,SC2120  # fm_env.sh taklit bayrakları burada atanır; _on/_off isteğe bağlı argüman alır
# QL5 kilit boşlukları (qa mutantları M4=F2, M5=F3, M7=Q3 ve 17 LOW grubunun domconf.sh'taki
# parçası: P4 P6 P7 P12 S4 X1 X4 X5 X9 X11 X12 Q1 Q8 RP2) + L3 L4 L6 L7 L9 L12 davranış testleri.
# Her kilit, ilgili koşulu bozan bir mutantı (test başlığındaki kimlik) kırmızıya çevirir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# F7-H2: 'fm-auth off' çalışan durumu da sınar → bu dosya curl taklidini sim kipinde açar (çalışan görüntü reload'u izler).
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
set +e
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
IS_ROOT=0; if [[ "$(id -u)" == "0" ]]; then IS_ROOT=1; fi
list_all_domains() { printf '%s\n' example.com; }
domain_exists() { return 0; }
_on() { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_fr() { ( _domconf_fm_root_cmd "$@" ) >"$OUTF" 2>&1; }
_audit() { ( _domconf_nginx_audit "$@" ) >"$OUTF" 2>&1; }
_root() { ( _domconf_fm_root_provision example.com 0 ) >/dev/null 2>&1; }
_st() { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_pre() { why=$(_domconf_fm_root_precheck example.com); pre_rc=$?; }
_fresh_cd() { chmod -R u+rwX "$SRVCTL_NGINX_CUSTOM_DIR" 2>/dev/null; rm -rf "$CUR_DIR"; mkdir -p "$CUR_DIR"; }

echo "── A: QL5-M4 (F2) — açık alanda 90/21/20'nin HER BİRİ kurcalanır/eksilirse kayıtla uyuşmaz ve yeniden üretilir ──"
for nm in 90 21 20; do
    case "$nm" in 90) tf="$F90" ;; 21) tf="$F21" ;; *) tf="$F20" ;; esac
    for how in TAMPERED EKSIK; do
        _fm_reset; _on
        if [[ "$how" == "TAMPERED" ]]; then printf '# kurcalandi\nclient_max_body_size 1m;\n' > "$tf"; else rm -f "$tf"; fi
        rc=0; _fmprov_load example_com; _domconf_fm_files_ok example_com "$CUR_DIR" || rc=$?
        assert_eq "$rc" "1" "on/${nm} ${how}: _domconf_fm_files_ok başarısız"
        # F9c (§15/38): 21/90 bozulunca da sınıf 4 (kayıt off sayılır) → files_ok 'off' kipinde konuşur: 21/90 için durum satırı "90/21=kayıt-dışı" (yalnız dosya diskteyse)
        if [[ "$nm" == 20 ]]; then
            assert_contains "$_FMR_STATES" "${nm}=${how}" "on/${nm} ${how}: durum satırı ${nm}=${how}"
        else
            assert_contains "$_FMR_STATES" "90/21=kayıt-dışı" "on/${nm} ${how}: durum satırı 90/21=kayıt-dışı (F9c: sınıf 4, kayıt off sayılır; diskte kalan 90/21)"
        fi
        _fr example.com
        # F9b/F9c (§15/33, §15/38): 20/21/90'dan biri kurcalanmış/eksik → TANINAN açık eser DEĞİL: otomatik yol AÇMAZ ve kayıtlı parametrelerle yeniden ÜRETMEZ, 403 köküne alır
        # (F9c ÖNCESİ 21/90 için beklenti: "YAPILACAK: kayıtlı dosyalar sağlam değil" + varvarvar|on = yeniden üretim; TERSİNE ÇEVRİLDİ)
        assert_contains "$(cat "$OUTF")" "YAPILACAK: kayıt 'on' yazıyor ama 20/21/90 eserlerinden (${_DOMCONF_FM_UP_FILE}, ${_DOMCONF_FM_DL_FILE}, ${_DOMCONF_FM_AUTH_FILE}) biri TANINAN bir srvctl AÇIK eseri değil" "on/${nm} ${how}: kuru plan 403 köküne alınacağını söyler (açmaz)"
        _fr example.com --apply; assert_eq "$?" "0" "on/${nm} ${how}: --apply rc 0"
        assert_eq "$(_exists "$F90")$(_exists "$F21")$(_exists "$F20")|$(_st)" "yokyokvar|off" "on/${nm} ${how}: F9b/F9c: alan AÇILMADI (yalnız 403 kökü, durum off)"
        rc=0; _fmprov_load example_com; _domconf_fm_files_ok example_com "$CUR_DIR" || rc=$?
        assert_eq "$rc" "0" "on/${nm} ${how}: yeniden üretimden sonra sağlam"
    done
done
_fm_reset; _on; _fmprov_load example_com; _domconf_fm_files_ok example_com "$CUR_DIR"
assert_eq "$?" "0" "(kontrol) dokunulmamış açık alan sağlam"

echo "── B: QL5-M5 (F3) — KAPALI alanda kayıt-dışı 90 YA DA 21 sağlam sayılmaz ve kaldırılır ──"
for nm in 90 21; do
    case "$nm" in 90) tf="$F90" ;; *) tf="$F21" ;; esac
    _fm_reset; _root
    printf 'location = /_fm { return 200 "x"; }\n' > "$tf"
    rc=0; _fmprov_load example_com; _domconf_fm_files_ok example_com "$CUR_DIR" || rc=$?
    assert_eq "$rc" "1" "off + yalnız ${nm} diskte: files_ok başarısız"
    assert_contains "$_FMR_STATES" "90/21=kayıt-dışı" "off + ${nm}: durum 'kayıt-dışı'"
    _fr example.com; assert_contains "$(cat "$OUTF")" "YAPILACAK: kayıtlı dosyalar sağlam değil" "off + ${nm}: kuru plan yeniden üretim söyler (sağlam DEMEZ)"
    _fr example.com --apply; assert_eq "$?" "0" "off + ${nm}: --apply rc 0"
    assert_eq "$(_exists "$tf")|$(_st)" "yok|off" "off + ${nm}: kayıt-dışı dosya kaldırıldı, durum off"
done

echo "── C: QL5-M7 (Q3) — karantina reload'u başarısız → operatör bilir ──"
mk_q() { _fm_reset; _root; printf 'location /x { proxy_pass http://127.0.0.1:1; }\n' > "${CUR_DIR}/10-app.conf"; : > "$RELOAD_LOG"; }
mk_q; SYSTEMCTL_RC=1; _audit example.com --quarantine; rc=$?; SYSTEMCTL_RC=0
assert_contains "$(cat "$OUTF")" "nginx reload başarısız" "reload hatası söylenir"
assert_contains "$(cat "$OUTF")" "ÇALIŞAN nginx'te hâlâ etkin olabilir" "…taşınan dosyanın çalışan nginx'te etkin kalabileceği söylenir"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "var" "dosya diskte yine de taşındı (config geçerli)"
assert_eq "$rc" "1" "denetim sonucu hâlâ 1 (denetim anındaki ihlal)"
mk_q; _audit example.com --quarantine
assert_not_contains "$(cat "$OUTF")" "nginx reload başarısız" "(kontrol) reload başarılıysa uyarı YOK"

echo "── D: QL5-L15 P4/P6/P7/P12 — fm-root kapısı (precheck) ──"
# P4: kilit dosyası normal dosya olmalı
_fm_reset; mkdir -p "$SD"; chmod 700 "$SD"; : > "${SD}/.lock"; _pre
assert_eq "$pre_rc" "0" "(kontrol) normal kilit dosyası: kapı geçer"
rm -f "${SD}/.lock"; mkdir "${SD}/.lock"; _pre
assert_eq "$pre_rc" "1" "P4: kilit yolu DİZİN → kapı reddeder"
assert_contains "$why" "kilit dosyası normal dosya değil" "P4: neden söylenir"
rmdir "${SD}/.lock"
# P12 (+P1): köken kayıt dizini sembolik bağ — mesaj sembolik bağı adlandırmalı (assert_root_owned_path da reddeder, mesajı farklıdır)
_fm_reset; rm -rf "${FM_STUBS}/realsd"; mkdir -p "${FM_STUBS}/realsd"; chmod 700 "${FM_STUBS}/realsd"; ln -s "${FM_STUBS}/realsd" "$SD"; _pre
assert_eq "$pre_rc" "1" "P12: kayıt dizini sembolik bağ → kapı reddeder"
assert_contains "$why" "köken kayıt dizini sembolik bağ" "P12: neden 'sembolik bağ' diye adlandırılır"
rm -f "$SD"
# P6: kayıt dizini YOK + üst dizin yazılamaz (root'ta -w her zaman doğru: atlanır)
if (( IS_ROOT == 0 )); then
    _fm_reset; chmod 555 "$SRVCTL_STATE_DIR"; _pre; chmod 700 "$SRVCTL_STATE_DIR"
    assert_eq "$pre_rc" "1" "P6: kayıt dizini yok + üst dizin yazılamaz → kapı reddeder"
    assert_contains "$why" "köken kayıt dizini oluşturulamaz (üst dizin yazılamaz)" "P6: neden söylenir"
    # P7: custom.d/<sname> yok + custom.d yazılamaz
    _fm_reset; rm -rf "$CUR_DIR"; chmod 555 "$SRVCTL_NGINX_CUSTOM_DIR"; _pre; chmod 700 "$SRVCTL_NGINX_CUSTOM_DIR"; mkdir -p "$CUR_DIR"
    assert_eq "$pre_rc" "1" "P7: custom.d/<sname> yok + custom.d yazılamaz → kapı reddeder"
    assert_contains "$why" "custom.d dizini oluşturulamaz/yazılamaz" "P7: neden söylenir"
else
    echo "  (root olarak koşuluyor: P6/P7 -w denetimi atlandı)"
fi
_fm_reset; _pre; assert_eq "$pre_rc" "0" "(kontrol) temiz ortamda kapı geçer"

echo "── E: QL5-L4 — kayıt dizini YOKKEN ata zinciri güveni: 'hiçbir kaynak oluşturulmadı' sözü tutar ──"
_fm_reset; assert_eq "$(_exists "$SD")" "yok" "hazırlık: kayıt dizini yok"
MOCK_BAD_OWNER="$SRVCTL_STATE_DIR"; _pre
assert_eq "$pre_rc" "1" "ata dizin root sahipli değil: kapı reddeder"
assert_contains "$why" "üst dizin zinciri güvenilmez" "neden söylenir"
( _domconf_fm_root_provision example.com 0 ) >"$OUTF" 2>&1; prov_rc=$?
assert_eq "$prov_rc" "1" "(tutarlılık) provizyon da aynı durumda reddeder"
MOCK_BAD_OWNER=""
assert_eq "$(_exists "$CUR_DIR/$_DOMCONF_FM_UP_FILE")" "yok" "reddedilen durumda 403 kökü yazılmadı"
_fm_reset; chmod 777 "$SRVCTL_STATE_DIR"; _pre; pre_rc2=$pre_rc; why2="$why"; sd_after_pre=$(_exists "$SD")
( _domconf_fm_root_provision example.com 0 ) >"$OUTF" 2>&1; prov_rc2=$?
chmod 700 "$SRVCTL_STATE_DIR"
assert_eq "$pre_rc2" "1" "ata dizin herkese yazılabilir (0777): kapı reddeder"
assert_contains "$why2" "üst dizin zinciri güvenilmez" "…aynı neden"
assert_eq "$prov_rc2" "1" "(tutarlılık) provizyon da reddeder"
assert_eq "$sd_after_pre" "yok" "…kapı kayıt dizinini YARATMADI (yazım yapmayan kapı)"

echo "── F: QL5-L15 S4 — sonda yolu güvenli jeton değilse sonda KOŞMAZ ──"
_fm_reset; : > "$NGINX_T_LOG"
res=$( SRVCTL_STATE_DIR="${WEB_ROOT}/.st ate"; mkdir -p "${SRVCTL_STATE_DIR}/_fm-auth"; chmod 700 "${SRVCTL_STATE_DIR}/_fm-auth"
       _domconf_fm_modsec_probe 2>/dev/null; echo "rc=$?|${_DOMCONF_MODSEC_PROBE_OUT}|probe-dirs=$(find "${SRVCTL_STATE_DIR}/_fm-auth" -maxdepth 1 -name '.probe.*' | wc -l | tr -d ' ')" )
assert_contains "$res" "rc=2|sonda dizini yolu güvenle yazılamaz" "boşluklu yol: tespit YAPILAMADI (rc 2), neden söylenir"
assert_contains "$res" "probe-dirs=0" "…sonda dizini kalmadı"
assert_eq "$(grep -c '^p$' "$NGINX_T_LOG")" "0" "…nginx -t -c hiç çalışmadı (yapılandırmaya enjeksiyon yok)"
_fm_reset; mkdir -p "$SD"; chmod 700 "$SD"; _domconf_fm_modsec_probe >/dev/null 2>&1; assert_eq "$?" "0" "(kontrol) normal yolda sonda koşar"

echo "── G: QL5-L6 — sonda ana bağlamın 'user' satırını taşır ──"
PROBE_COPY="${FM_STUBS}/probe-copy.conf"
_cap_probe() { [[ "$NGINX_T_ARGS" == "-t -c "* ]] && cp "${NGINX_T_ARGS#-t -c }" "$PROBE_COPY"; return 0; }
NG="${FM_STUBS}/ngx"; mkdir -p "$NG"
_probe_with() {   # $1 = ana yapılandırma metni
    printf '%s\n' "$1" > "${NG}/nginx.conf"; _fm_reset; mkdir -p "$SD"; chmod 700 "$SD"; : > "$PROBE_COPY"
    SRVCTL_NGINX_CONF="${NG}/nginx.conf"; NGINX_T_HOOK=_cap_probe
    _domconf_fm_modsec_probe >"$OUTF" 2>&1; probe_rc=$?
    NGINX_T_HOOK=""; export SRVCTL_NGINX_CONF="${FM_STUBS}/nginx.conf"
}
_probe_with $'user www-data www-data;\nload_module /opt/m/a.so;\nevents { }\nhttp { }'
assert_eq "$probe_rc" "0" "user www-data www-data: sonda geçti"
assert_contains "$(cat "$PROBE_COPY")" "user www-data www-data;" "sonda 'user www-data www-data;' taşır"
assert_contains "$(cat "$PROBE_COPY")" "load_module /opt/m/a.so;" "…load_module yine taşınır"
_probe_with $'user nginx;\nevents { }\nhttp { }'
assert_contains "$(cat "$PROBE_COPY")" "user nginx;" "tek argümanlı user taşınır"
_probe_with $'events { }\nhttp { }'
assert_not_contains "$(cat "$PROBE_COPY")" "user " "ana yapılandırmada user yoksa sondada da YOK (canlıyla aynı varsayılan)"
_probe_with $'user "a b";\nevents { }\nhttp { }'
assert_not_contains "$(cat "$PROBE_COPY")" "user " "güvensiz jetonlu user sondaya YAZILMAZ"
assert_contains "$(cat "$OUTF")" "load_module satırları doğrulanamadı" "…doğrulanamadı uyarısı (yanılma yönü güvenli)"
unset NG

echo "── H: QL5-L7 — SIGKILL'in bıraktığı .probe.* dizinleri bir sonraki sondada temizlenir ve söylenir ──"
_fm_reset; mkdir -p "$SD"; chmod 700 "$SD"
mkdir -p "${SD}/.probe.AAAAAA/cb"; : > "${SD}/.probe.AAAAAA/probe.conf"
mkdir -p "${FM_STUBS}/decoy"; : > "${FM_STUBS}/decoy/keep"; ln -s "${FM_STUBS}/decoy" "${SD}/.probe.BBBBBB"
_domconf_fm_modsec_probe >"$OUTF" 2>&1; assert_eq "$?" "0" "sonda rc 0"
assert_eq "$(_exists "${SD}/.probe.AAAAAA")" "yok" "bayat sonda dizini silindi"
assert_eq "$(_exists "${FM_STUBS}/decoy/keep")" "var" "sembolik bağ İZLENMEDİ (hedef dizin korundu)"
assert_contains "$(cat "$OUTF")" "1 eski ModSecurity sonda dizini" "operatöre söylenir"
rm -f "${SD}/.probe.BBBBBB"
_domconf_fm_modsec_probe >"$OUTF" 2>&1
assert_not_contains "$(cat "$OUTF")" "eski ModSecurity sonda dizini" "(kontrol) bayat yoksa ileti yok"

echo "── I: QL5-L3 — fm-root <alan> ile --all birlikte: iki sırada da RET, hiçbir şey yazılmaz ──"
for argsx in "example.com --all" "--all example.com" "--all --all" "--all example.com --apply" "example.com --all --apply"; do
    _fm_reset; : > "$FLOCK_LOG"
    # shellcheck disable=SC2086
    _fr $argsx; rc=$?
    assert_eq "$rc" "1" "'${argsx}': rc 1"
    assert_contains "$(cat "$OUTF")" "Fazla argüman" "'${argsx}': neden söylenir"
    assert_eq "$(_exists "$F20")$(_exists "$SD")$(grep -c . "$FLOCK_LOG")" "yokyok0" "'${argsx}': yazım yok, kayıt dizini yok, kilit alınmadı"
done
_fr --all; assert_eq "$?" "0" "(kontrol) yalnız --all geçerli"

echo "── J: QL5-L15 X1/X4/X5/X9/X11/X12 — fm-root komut dalları ──"
# X1: --all, işlenecek alan yok → rc 0
( list_all_domains() { :; }; _domconf_fm_root_cmd --all ) >"$OUTF" 2>&1; assert_eq "$?" "0" "X1: --all ve alan yok: rc 0"
assert_contains "$(cat "$OUTF")" "İşlenecek domain yok." "X1: ileti"
# X4: ikinci alan argümanı reddedilir (son argüman kazanmaz)
_fm_reset; _fr example.com b.com; assert_eq "$?" "1" "X4: iki alan: rc 1"
assert_contains "$(cat "$OUTF")" "Fazla argüman: b.com" "X4: neden 'Fazla argüman'"
assert_eq "$(_exists "$F20")" "yok" "X4: hiçbir şey yazılmadı"
# X5: --apply sırasında reload başarısız → rc 1 + açık ileti (yazım yapılmış, config geçerli)
_fm_reset; SYSTEMCTL_RC=1; _fr example.com --apply; rc=$?; SYSTEMCTL_RC=0
assert_eq "$rc" "1" "X5: reload başarısız → rc 1"
assert_contains "$(cat "$OUTF")" "nginx reload başarısız — config GEÇERLİ" "X5: ileti"
assert_eq "$(_exists "$F20")|$(_st)" "var|off" "X5: kök yazılmış (nginx -t geçti)"
# X9: custom.d/<sname> dizin değil (dosya)
_fm_reset; rm -rf "$CUR_DIR"; printf 'x\n' > "$CUR_DIR"
_fr example.com; rc=$?
assert_eq "$rc" "1" "X9: custom.d bir DOSYA: kuru rc 1"
assert_contains "$(cat "$OUTF")" "YAPILAMAZ: custom.d/example_com dizin değil" "X9: neden söylenir"
_fr example.com --apply; assert_eq "$?" "1" "X9: --apply rc 1"
assert_eq "$([[ -f "$CUR_DIR" ]] && echo dosya)|$(_exists "$SD/example_com.manifest")" "dosya|yok" "X9: dosyaya dokunulmadı, kayıt yazılmadı"
rm -f "$CUR_DIR"; mkdir -p "$CUR_DIR"
# X11: birden çok yarım yedek → YAPILAMAZ (otomatik kurtarma yok)
_fm_reset; _root; mkdir -p "${SD}/.bk.example_com.AAAAAA" "${SD}/.bk.example_com.BBBBBB"
_fr example.com; rc=$?
assert_eq "$rc" "1" "X11: iki yedek: kuru rc 1"
assert_contains "$(cat "$OUTF")" "YAPILAMAZ: birden çok yarım işlem yedeği" "X11: YAPILAMAZ (YAPILACAK değil)"
_fr example.com --apply; assert_eq "$?" "1" "X11: --apply rc 1"
assert_eq "$(find "$SD" -maxdepth 1 -name '.bk.*' | wc -l | tr -d ' ')" "2" "X11: yedeklere dokunulmadı"
rm -rf "${SD}/.bk.example_com.AAAAAA" "${SD}/.bk.example_com.BBBBBB"
# X12: yedek kurtarılamıyor → fm-root --apply rc 1
_fm_reset; _on
# F9b (§15/33): yedek YALNIZ ön durumu tanınan açık eserse geri yüklenmeye çalışılır (üç dosya + manifest); aksi hâlde ayrılır (test_domconf_fm_f9b_never_opens_3.sh B)
mkdir -p "${SD}/.bk.example_com.CCCCCC"; cp -p "$F90" "$F21" "$F20" "${SD}/.bk.example_com.CCCCCC/"; cp -p "$MAN" "${SD}/.bk.example_com.CCCCCC/manifest"
# F9c (§15/38): eski fixture (90'ı DİZİN yap) diski tanınmaz kılıp sınıf 4'e sokar → yedek geri yüklenmeye çalışılmadan ayrılır (kurtarma hata yolu erişilmez).
# Disk TANINAN açık kalsın diye kurtarmanın başarısızlığı burada restore_entry'nin rc 1 vermesiyle zorlanır (fm-root --apply'nin hata yolunu sınar).
_orig_re=$(declare -f _domconf_fm_restore_entry)
_domconf_fm_restore_entry() { return 1; }
_fr example.com --apply; rc=$?
eval "$_orig_re"
assert_eq "$rc" "1" "X12: yedek kurtarılamadı → rc 1"
assert_contains "$(cat "$OUTF")" "YAPILAMAZ — yarım işlem yedeği kurtarılamadı" "X12: ileti"
assert_eq "$(find "$SD" -maxdepth 1 -name '.bk.*' | wc -l | tr -d ' ')" "1" "X12: yedek KORUNDU"
rm -rf "${SD}/.bk.example_com.CCCCCC"

echo "── K: QL5-L15 Q1/Q8/RP2 ──"
# Q1: kilit alındığı anda kök bozulursa karantina HİÇBİR dosya taşımadan iptal (nginx -t'ye bile gidilmez)
mk_q; : > "$NGINX_T_LOG"
( flock() { rm -f "$F20"; return 0; }; _domconf_nginx_audit example.com --quarantine ) >"$OUTF" 2>&1; rc=$?
assert_contains "$(cat "$OUTF")" "karantina İPTAL (example.com): 403 kökü artık sağlam değil — hiçbir dosya taşınmadı" "Q1: kilit altı kök yeniden denetimi iptal eder"
assert_eq "$(_exists "${CUR_DIR}/10-app.conf")$(_exists "${CUR_DIR}/10-app.conf.srvctl-rejected")" "varyok" "Q1: dosya TAŞINMADI"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")" "0" "Q1: nginx -t'ye gidilmedi (taşıma öncesi iptal)"
assert_eq "$(_reloads)" "0" "Q1: reload yok"
# Q8: STATE-UNTRUSTED denetimde 'KÖK-DOĞRULANAMADI' satırı verir
mk_q; MOCK_BAD_OWNER="$SD"; _audit example.com; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "Q8: STATE-UNTRUSTED denetim rc 1"
assert_contains "$(cat "$OUTF")" "KÖK-DOĞRULANAMADI: köken kaydı güvenilmez (STATE-UNTRUSTED)" "Q8: KÖK-DOĞRULANAMADI satırı (KÖK-SAĞLAM-DEĞİL DEĞİL)"
assert_not_contains "$(cat "$OUTF")" "KÖK-SAĞLAM-DEĞİL" "Q8: yanlış sınıf (KÖK-SAĞLAM-DEĞİL) basılmaz"
# RP2: özetler sağlam, nginx -t BAŞKA dosyada düşüyor → repair yeniden ÜRETMEZ (kilit alınmaz), dürüstçe başarısız
_fm_reset; _on; h0="$(_md5 "$F90")$(_md5 "$F21")$(_md5 "$F20")$(_md5 "$MAN")"; : > "$FLOCK_LOG"
NGINX_T_MSG='nginx: [emerg] unexpected "}" in /etc/nginx/sites-enabled/baska.conf:9'
_domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" >"$OUTF" 2>&1; rc=$?
NGINX_T_MSG=""
assert_eq "$rc" "1" "RP2: başka dosyada nginx -t hatası: repair rc 1"
assert_contains "$(cat "$OUTF")" "onarım bunu düzeltemez" "RP2: 'sağlam ama nginx -t başka yerde' iletisi"
assert_not_contains "$(cat "$OUTF")" "yeniden üretiliyor" "RP2: yeniden üretim DENENMEDİ"
assert_eq "$(grep -c . "$FLOCK_LOG")" "0" "RP2: yazım kilidi hiç alınmadı (yazım yolu çalışmadı)"
assert_eq "$(_md5 "$F90")$(_md5 "$F21")$(_md5 "$F20")$(_md5 "$MAN")" "$h0" "RP2: dosyalar+kayıt bayt bayt aynı"

echo "── L: QL5-L9 — dürüst iletiler ──"
# status KAPALI + STALE: yol hâlâ 403 verir; EKSİK/TAMPERED: CI4'e düşebilir
_fm_reset; _root
old='location = /_fm { return 403; }  # eski sablon'
printf '%s\n' "$old" > "$F20"; chmod 644 "$F20"
oh=$(_domconf_sha256_file "$F20")
_fmprov_write example_com off eu - - 0 "${oh} ${_DOMCONF_FM_UP_FILE}"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); rc=$?
assert_eq "$rc" "1" "STALE kök: status rc 1"
assert_contains "$out" "fm-auth STALE" "STALE kök: sınıf STALE"
assert_contains "$out" "yol hâlâ 403 verir" "STALE kök: yol hâlâ 403 verir (yalnız yenilenmeli)"
assert_not_contains "$out" "CI4'e düşebilir" "STALE kök: 'CI4'e düşebilir' YALANI yok"
printf 'location = /_fm { return 200 "x"; }\n' > "$F20"
out=$( (_domconf_fm_auth example.com status) 2>&1 )
assert_contains "$out" "fm-auth TAMPERED" "TAMPERED kök: sınıf TAMPERED"
assert_contains "$out" "CI4'e düşebilir" "TAMPERED kök: 'CI4'e düşebilir' denir"
rm -f "$F20"
out=$( (_domconf_fm_auth example.com status) 2>&1 )
assert_contains "$out" "EKSİK" "EKSİK kök: sınıf EKSİK"
assert_contains "$out" "CI4'e düşebilir" "EKSİK kök: 'CI4'e düşebilir' denir"
# fm-root --apply: yazım yokken "tek reload" SÖZÜ verilmez
# ARCHITECTURE §15/93(b)(1): "yazım yok → nginx -t/reload yok" YALNIZ çalışan nginx KESİN KAPALI imzası veriyorsa geçerlidir (doğrulanamayan çalışan durum "kapalı" sayılmaz ve
# diskte KAPALI kanıtı varken yeniden yüklenir). Bu dosyada canlı sonda kapalıdır; KESİN KAPALI imzası bir kanca ile verilir, kör sonda ayrı sınanır.
eval "_c13_orig_probe() $(declare -f _domconf_fm_runtime_probe | sed 1d)"
_c13_probe_closed() { _domconf_fm_runtime_probe() { _FMRT_STATE="closed"; _FMRT_DETAIL="test: kesin KAPALI imzası"; return 0; }; }
_c13_probe_blind() { _domconf_fm_runtime_probe() { _c13_orig_probe "$@"; }; }
_fm_reset; _root; : > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_c13_probe_closed
_fr example.com --apply; rc=$?
assert_eq "$rc" "0" "sağlam alan: --apply rc 0"
assert_not_contains "$(cat "$OUTF")" "tek nginx -t, tek reload" "başlık 'tek nginx -t, tek reload' SÖZÜ vermez"
assert_contains "$(cat "$OUTF")" "yazılacak bir şey yok: nginx -t / reload ÇALIŞTIRILMADI" "yazım yokken bunu açıkça söyler"
assert_eq "$(grep -c . "$NGINX_T_LOG")$(_reloads)" "00" "…ve gerçekten nginx -t/reload yok (çalışan KESİN KAPALI)"
# …sonda KÖR ise yazım olmasa da yeniden yüklenir ve ileti "reload ÇALIŞTIRILMADI" DEMEZ
_c13_probe_blind; : > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_fr example.com --apply; rc=$?
assert_eq "$rc|$(_reloads)" "0|1" "sonda kör: yazım yok ama doğrulanamayan çalışan durum → yeniden yüklenir (rc 0, tam 1 reload)"
assert_not_contains "$(cat "$OUTF")" "nginx -t / reload ÇALIŞTIRILMADI" "sonda kör: 'reload ÇALIŞTIRILMADI' DENMEZ (yeniden yükleme yapıldı)"
assert_contains "$(cat "$OUTF")" "yapılandırma yeniden yüklendi" "sonda kör: yeniden yüklemenin nedeni söylenir"
rm -f "$F20"
: > "$NGINX_T_LOG"; : > "$RELOAD_LOG"
_fr example.com --apply
assert_not_contains "$(cat "$OUTF")" "yazılacak bir şey yok" "yazım VARKEN 'yazılacak bir şey yok' denmez"
assert_eq "$(grep -c '^t$' "$NGINX_T_LOG")$(_reloads)" "11" "yazım varken tek nginx -t + tek reload"

echo "── M: QL5-L12 — vhost custom.d include etmiyorsa geniş repair ÖNERİLMEZ ──"
_fm_reset
cp -p "$VHOST" "${VHOST}.orig"; printf 'server { }\n' > "$VHOST"
_fr example.com; rc=$?
assert_eq "$rc" "1" "include'suz vhost: kuru rc 1"
assert_contains "$(cat "$OUTF")" "YAPILAMAZ: vhost custom.d/example_com/ dizinini include ETMİYOR" "neden söylenir"
assert_contains "$(cat "$OUTF")" "include /etc/nginx/custom.d/example_com/*.conf;" "doğru ve dar öneri: vhost'a include satırını elle ekleyin"
assert_contains "$(cat "$OUTF")" "fm-root vhost'u DEĞİŞTİRMEZ" "fm-root'un vhost'a dokunmadığı söylenir"
assert_not_contains "$(cat "$OUTF")" "domain repair" "geniş 'srvctl domain repair' ÖNERİLMEZ"
_fr example.com --apply; assert_eq "$?" "1" "--apply rc 1"
assert_not_contains "$(cat "$OUTF")" "domain repair" "--apply çıktısında da repair önerisi yok"
assert_eq "$(_exists "$F20")" "yok" "include yokken kök YAZILMADI"
mv -f "${VHOST}.orig" "$VHOST"

echo "── N: QL5-L8 — rezerve FM adı tespiti TEK yardımcıda; yedi çağıran aynı davranır ──"
_fm_reset; printf 'client_max_body_size 1m;\n' > "$F21"
_audit example.com; assert_contains "$(cat "$OUTF")" "KÖK-KAYITSIZ: FM adlı dosya(lar) köken kaydı OLMADAN diskte (21-srvctl-fm-download.conf)" "nginx-audit: kayıtsız ad"
out=$( (_domconf_fm_auth example.com status) 2>&1 ); assert_contains "$out" "KAYITSIZ (TAMPERED)" "status: kayıtsız ad"
_fr example.com; assert_contains "$(cat "$OUTF")" "YAPILACAK: kayıtsız FM adlı dosya(lar): 21-srvctl-fm-download.conf" "fm-root planı: devralınacak"
_on; assert_contains "$(cat "$OUTF")" "fm-auth on REDDEDİLDİ: ${CUR_DIR}/21-srvctl-fm-download.conf köken kaydı OLMADAN diskte" "fm-auth on: reddeder"
( _domconf_fm_root_provision example.com 0 ) >"$OUTF" 2>&1; assert_eq "$?" "1" "provizyon: kayıtsız ad → rc 1"
assert_contains "$(cat "$OUTF")" "${CUR_DIR}/21-srvctl-fm-download.conf köken kaydı OLMADAN diskte" "provizyon: neden"
_pre; assert_eq "$pre_rc" "1" "precheck: kayıtsız ad → rc 1"
assert_contains "$why" "${CUR_DIR}/21-srvctl-fm-download.conf köken kaydı OLMADAN diskte" "precheck: neden"
( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; assert_eq "$?" "0" "off: kayıtsız adı devralır (rc 0)"
assert_contains "$(cat "$OUTF")" "kayıtsız FM adlı dosya(lar) devralındı: 21-srvctl-fm-download.conf" "off: devralma iletisi"
# yapısal: ölü kod geri gelmesin (kod satırı bazında; yorum satırları ayrı)
code=$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/lib/domconf.sh")
assert_not_contains "$code" "_DOMCONF_FM_RECOVERED" "ölü bayrak _DOMCONF_FM_RECOVERED kodda YOK"
assert_eq "$(grep -c '_SUF_BAD[^_]' <<< "$code")" "0" "ölü değişken _SUF_BAD kodda YOK (yalnız _SUF_BAD_ARR)"
assert_eq "$(grep -c '^ *for n in "\$_DOMCONF_FM_AUTH_FILE" "\$_DOMCONF_FM_DL_FILE" "\$_DOMCONF_FM_UP_FILE"; do' <<< "$code")" "3" "3-adlı döngü: yardımcı + tx_commit + repair (6 kopya geri gelmedi)"

test_summary
