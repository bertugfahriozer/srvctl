#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e-3/dev — ARCHITECTURE §15/47(b): VAR OLAN köken kayıt dizini (SRVCTL_STATE_DIR/_fm-auth) yabancı sahipli ya da grup/herkes YAZILABİLİR ise
# `fm-root`, `fm-root --all` ve provision modu sessizce 0700'e çekip DEVAM ETMEZ: yazım 0 (disk, kayıt, yedek, reload, nginx -t aynı), rc≠0,
# "kayıt dizini güvenilmez" + düzeltme ipucu; alan açık olabiliyorsa §15/44(a)'nın "FM HÂLÂ AÇIK OLABİLİR" iletisi. Dizinin HİÇ olmadığı ilk kurulum muaftır.
# Eski ağaçta (domconf md5 184ba35d): _fmprov_prepare_dir secure_dir ile modu/sahibi sessizce onarıp rc 0 ile yazardı (m777 gözlemi, F9e-2 lab).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

LOUD="FM HÂLÂ AÇIK OLABİLİR"
listing() { ( cd "$CUR_DIR" && find . | LC_ALL=C sort | tr '\n' ' ' ); }
reloads() { grep -c '^r$' "$RELOAD_LOG" 2>/dev/null || true; }
ngxt() { grep -c '^t$' "$NGINX_T_LOG" 2>/dev/null || true; }
# yazım izi: custom.d listesi + 20/21/90 özetleri + kayıt özeti + kayıt dizini listesi + yedek sayısı + reload ve nginx -t sayısı (hiçbiri DEĞİŞMEMELİ)
snap() {
    local f out=""
    for f in "$F90" "$F21" "$F20" "$MAN"; do if [[ -f "$f" ]]; then out+="$(_md5 "$f"),"; else out+="yok,"; fi; done
    printf '%s|%s|sd=%s|bk=%s|r=%s|t=%s' "$(listing)" "$out" "$( ( cd "$SD" && find . | LC_ALL=C sort | tr '\n' ' ' ) )" "$(_bkn)" "$(reloads)" "$(ngxt)"
}
# kayıt dizinini <open|closed> hazırla (kayıt var), sonra bozuk moda sok
prep() {   # <open|closed>
    reset_all; _on; fm_sim_reload
    if [[ "$1" == "closed" ]]; then ( _domconf_fm_auth example.com off ) >/dev/null 2>&1; fm_sim_reload; fi
}
PATHS3="fmroot fmrootall provision"

# ═══ A. grup/herkes yazılabilir modlar (0777, 0770, 0775, 0707): sessiz onarım YOK ═══
for mode in 777 770 775 707; do
  for st in open closed; do
    for path in $PATHS3; do
        prep "$st"; chmod "$mode" "$SD"; s0=$(snap)
        runpath "$path"; rc=$?; out=$(strip < "$OUTF"); tag="A [mod ${mode} / ${st} / ${path}]"
        assert_eq "$rc" "1" "${tag}: tam rc 1 (ret; 4 = açıldı/doğrulanamadı değil)"
        assert_contains "$out" "kayıt dizini güvenilmez" "${tag}: ileti 'kayıt dizini güvenilmez'"
        assert_contains "$out" "chmod 700" "${tag}: düzeltme ipucu (chown root:root … && chmod 700 …)"
        assert_eq "$(_mode "$SD")" "$mode" "${tag}: mod SESSİZCE 0700'e çekilmedi"
        assert_eq "$(snap)" "$s0" "${tag}: YAZIM YAPILMADI (custom.d, 20/21/90, kayıt, kayıt dizini, yedek, reload, nginx -t aynı)"
        if [[ "$st" == "open" ]]; then
            assert_contains "$out" "$LOUD" "${tag}: alan açık olabilir → '${LOUD}'"
            assert_eq "$(_shut)" "OPEN" "${tag}: disk değişmedi (hâlâ açık: ileti yalan değil)"
        else
            assert_not_contains "$out" "$LOUD" "${tag}: diskte KAPALI kanıtı var → '${LOUD}' DENMEZ"
            assert_eq "$(_shut)" "SHUT" "${tag}: alan kapalı kaldı"
        fi
    done
  done
done

# ═══ B. yabancı sahip (stat-shim: MOCK_BAD_OWNER), mod 0700: sessiz onarım YOK ═══
for st in open closed; do
  for path in $PATHS3; do
    prep "$st"; s0=$(snap)
    MOCK_BAD_OWNER="$SD"; runpath "$path"; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF"); tag="B [yabancı sahip / ${st} / ${path}]"
    assert_eq "$rc" "1" "${tag}: tam rc 1 (ret)"
    assert_contains "$out" "kayıt dizini güvenilmez" "${tag}: ileti 'kayıt dizini güvenilmez'"
    assert_contains "$out" "yabancı sahipli" "${tag}: nedeni söyler (yabancı sahipli)"
    assert_contains "$out" "chown root:root" "${tag}: düzeltme ipucu (chown root:root)"
    assert_eq "$(snap)" "$s0" "${tag}: YAZIM YAPILMADI"
    if [[ "$st" == "open" ]]; then assert_contains "$out" "$LOUD" "${tag}: alan açık olabilir → '${LOUD}'"
    else assert_not_contains "$out" "$LOUD" "${tag}: kapalı kanıtı var → '${LOUD}' DENMEZ"; fi
  done
done

# ═══ C. dizin HİÇ YOK + ilk kurulum: oluşturma MUAF (rc 0, dizin 0700, 403 kökü kuruldu, kayıt off) ═══
for path in $PATHS3; do
    reset_all
    assert_eq "$([[ -e "$SD" ]] && echo VAR || echo YOK)" "YOK" "C [${path}] önkoşul: kayıt dizini yok"
    runpath "$path"; rc=$?; out=$(strip < "$OUTF"); tag="C [dizin yok / ${path}]"
    assert_eq "$rc" "0" "${tag}: ilk kurulum rc 0"
    assert_eq "$(_mode "$SD")" "700" "${tag}: kayıt dizini 0700 OLUŞTURULDU"
    assert_eq "$(_shut)|$(_st)" "SHUT|off" "${tag}: 403 kökü kuruldu, kayıt off"
    assert_not_contains "$out" "kayıt dizini güvenilmez" "${tag}: güvensizlik iletisi yok"
done

# ═══ D. DEĞİŞMEYENLER: root sahipli, yazılamaz-gevşek mod (0755, 0750) ESKİSİ GİBİ 0700'e sıkılaştırılır; 0700 normal ═══
for mode in 755 750 700; do
  for path in $PATHS3; do
    prep closed; chmod "$mode" "$SD"
    runpath "$path"; rc=$?; out=$(strip < "$OUTF"); tag="D [mod ${mode} / ${path}]"
    assert_eq "$rc|$(_mode "$SD")" "0|700" "${tag}: yazılamaz-gevşek/normal mod: rc 0, 0700'e sıkılaştırıldı (davranış değişmedi)"
    assert_not_contains "$out" "kayıt dizini güvenilmez" "${tag}: güvensizlik iletisi yok"
  done
done

# ═══ E. düzeltme ipucu İŞE YARAR: dizin root:root 0700 yapılınca aynı komut yazar ═══
prep closed; chmod 777 "$SD"; runpath fmroot; rc=$?
assert_eq "$rc" "1" "E1: 0777 → fm-root reddedildi (tam rc 1)"
chmod 700 "$SD"; runpath fmroot; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "0|SHUT|off" "E2: dizin 0700 yapılınca fm-root yazar (rc 0)"

# ═══ F. kapsam sınırı: 'on' ve 'off' ═══
# on: güvenilmez dizinde açma reddedilir, mod onarılmaz, yazım yok
prep closed; chmod 777 "$SD"; s0=$(snap)
_on; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(_mode "$SD")|$(snap)" "1|777|${s0}" "F1: 0777 kayıt dizininde 'on' reddedilir (tam rc 1), mod onarılmaz, yazım yok"
assert_contains "$out" "kayıt dizini güvenilmez" "F1: ileti"
assert_not_contains "$out" "$LOUD" "F1b: diskte KAPALI kanıtı var → 'on' iletisi '${LOUD}' DEMEZ"
# K2: alan AÇIK olabiliyorken `on` da diğer yollarla AYNI yüksek sesli ifadeyi söyler (tüm yollarda aynı ifade)
for mode in 777 770 775 707; do
    prep open; chmod "$mode" "$SD"; s0=$(snap)
    _on; rc=$?; out=$(strip < "$OUTF")
    assert_eq "$rc|$(_mode "$SD")|$(snap)" "1|${mode}|${s0}" "F3 [mod ${mode}]: açık alanda 'on' reddedilir (rc 1), mod onarılmaz, yazım yok"
    assert_contains "$out" "$LOUD" "F3 [mod ${mode}]: alan açık olabilir → 'on' da '${LOUD}' der"
    assert_contains "$out" "chmod 700" "F3 [mod ${mode}]: düzeltme ipucu"
    assert_contains "$out" "off --emergency" "F3 [mod ${mode}]: kayıttan bağımsız kapatma ipucu"
    assert_eq "$(_shut)" "OPEN" "F3 [mod ${mode}]: disk değişmedi (ileti yalan değil)"
done
prep open; MOCK_BAD_OWNER="$SD"; _on; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "F4: yabancı sahipli kayıt dizininde açık alanda 'on' → rc 1"
assert_contains "$out" "$LOUD" "F4: yabancı sahip → 'on' da '${LOUD}' der"
prep closed; MOCK_BAD_OWNER="$SD"; _on; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "F5: yabancı sahipli kayıt dizininde kapalı alanda 'on' → rc 1"
assert_not_contains "$out" "$LOUD" "F5: diskte KAPALI kanıtı var → '${LOUD}' DENMEZ"
# kayıt DOSYASI güvenilmez (dizin sağlam): kilit altı yol (STATE-UNTRUSTED) da aynı ifadeyi söyler
prep open; MOCK_BAD_OWNER="$MAN"; _on; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "F6: güvenilmez kayıt dosyası + açık alan → 'on' rc 1"
assert_contains "$out" "$LOUD" "F6: kilit altı STATE-UNTRUSTED dalı da '${LOUD}' der"
# off: kayıttan bağımsız kapatma çalışmaya devam eder (kapatma yönü)
prep open; chmod 777 "$SD"
( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(_shut)" "0|SHUT" "F2: 0777 kayıt dizininde 'off' yine KAPATIR (rc 0, 403 kökü)"

# ═══ G. BİRİM: _fmprov_prepare_dir kapısı kendi başına rc verir (kilit altı yolların hepsi buradan geçer) ═══
for mode in 777 770 775 707; do
    prep closed; chmod "$mode" "$SD"
    ( _fmprov_prepare_dir ) >"$OUTF" 2>&1; rc=$?
    assert_eq "$rc|$(_mode "$SD")" "1|${mode}" "G1 [mod ${mode}]: prepare_dir rc 1, mod onarılmadı"
done
prep closed; MOCK_BAD_OWNER="$SD"; ( _fmprov_prepare_dir ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$rc" "1" "G2: yabancı sahip → prepare_dir rc 1"
reset_all; ( _fmprov_prepare_dir ) >"$OUTF" 2>&1; rc=$?
assert_eq "$rc|$(_mode "$SD")" "0|700" "G3: dizin yok → oluşturur (rc 0, 0700) — ilk kurulum muaf"
for mode in 755 750 700; do
    prep closed; chmod "$mode" "$SD"; ( _fmprov_prepare_dir ) >"$OUTF" 2>&1; rc=$?
    assert_eq "$rc|$(_mode "$SD")" "0|700" "G4 [mod ${mode}]: yazılamaz-gevşek/normal → rc 0, 0700'e sıkılaştırıldı"
done
# G5: modu OKUNAMAYAN kayıt dizini GÜVENİLMEZ sayılır (fail-closed): güvenilir sayılsaydı ileti "mod okunamadı" yerine genel
# "köken kayıt dizini güvenilmez (sahip/mod/yol)" olur ve yazım yoluna girilirdi
prep closed
orig_stat_mode=$(declare -f _stat_mode)
_stat_mode() { if [[ "$1" == "$SD" ]]; then echo "x?"; return 0; fi; stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
( _fmprov_prepare_dir ) >"$OUTF" 2>&1; rc=$?
eval "$orig_stat_mode"
assert_eq "$rc" "1" "G5: mod okunamayınca prepare_dir rc 1 (fail-closed)"
assert_contains "$(strip < "$OUTF")" "mod okunamadı" "G5: ileti NEDENİ söyler ('mod okunamadı'); sessiz 'güvenilir' sayılmadı"
assert_contains "$(strip < "$OUTF")" "HİÇBİR ŞEY YAZILMADI" "G5: yazım yapılmadığı söylenir"

test_summary
