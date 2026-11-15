#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e/dev — ARCHITECTURE §15/44(a): köken kayıt dizini GÜVENİLMEZKEN (STATE-UNTRUSTED) YAZIM YAPILMAZ (değişmez: disk, kayıt, yedek, reload, nginx -t
# hiç değişmez/çalışmaz) AMA alan AÇIK olabiliyorsa ileti "FM HÂLÂ AÇIK OLABİLİR" der + çözüm (kayıt dizinini root:root 0700 yap;
# `fm-auth <alan> off --emergency`) ve rc≠0 olur. Eski ağaçta (af7e4ad7) repair / toplu repair / fm-root / fm-root --all / provision / php-switch / status
# yalnız "kayıt dizinini root:root 0700 yapın" diyordu (php-switch hiçbir şey söylemiyordu); 'FM HÂLÂ AÇIK OLABİLİR' YOKTU.
# Doğru olan dallar BOZULMAZ: diskte KAPALI kanıtı varsa "AÇIK OLABİLİR" DENMEZ; `off`/`off --emergency` kayıttan bağımsız kapatır (rc 0);
# açma yönü ('on') reddi sessiz değildir ama "AÇIK OLABİLİR" demez (isteğin kendisi açmak; ret = değişiklik yok).
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
# yazım izi: custom.d listesi + 20/21/90 özetleri + kayıt özeti + yedek sayısı + reload ve nginx -t sayısı (hiçbiri DEĞİŞMEMELİ)
snap() {
    local f out=""
    for f in "$F90" "$F21" "$F20" "$MAN"; do if [[ -f "$f" ]]; then out+="$(_md5 "$f"),"; else out+="yok,"; fi; done
    printf '%s|%s|bk=%s|r=%s|t=%s' "$(listing)" "$out" "$(_bkn)" "$(reloads)" "$(ngxt)"
}

# ═══ A. kayıt 'on' + disk AÇIK + kayıt dizini güvenilmez: kapatma/onarım yolları ═══
for path in repair83 repairall fmroot fmrootall provision phpswitch; do
    reset_all; _on; fm_sim_reload; s0=$(snap)
    MOCK_BAD_OWNER="$SD"; runpath "$path"; rc=$?; MOCK_BAD_OWNER=""
    out=$(strip < "$OUTF"); tag="A [açık disk / ${path}]"
    assert_eq "$rc" "1" "${tag}: TAM rc 1"
    assert_contains "$out" "$LOUD" "${tag}: ileti '${LOUD}' (aynen)"
    assert_contains "$out" "STATE-UNTRUSTED" "${tag}: nedeni söyler: STATE-UNTRUSTED"
    assert_contains "$out" "root:root 0700" "${tag}: çözüm: kayıt dizinini root:root 0700 yap"
    assert_contains "$out" "off --emergency" "${tag}: çözüm: fm-auth <alan> off --emergency"
    assert_eq "$(snap)" "$s0" "${tag}: YAZIM YAPILMADI (custom.d, 20/21/90, kayıt, yedek, reload ve nginx -t aynı)"
    assert_eq "$(_shut)" "OPEN" "${tag}: disk değişmedi (hâlâ açık: ileti yalan değil)"
done

# ═══ B. kayıt 'on' + disk AÇIK: sınıf-4 benzeri (20 tanınmayan) — yine açık olabilir ═══
reset_all; _on; mut20 unknown; s0=$(snap)
MOCK_BAD_OWNER="$SD"; runpath repair83; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "B: 20 tanınmayan + güvenilmez kayıt: TAM rc 1"
assert_contains "$out" "$LOUD" "B: ileti '${LOUD}'"
assert_eq "$(snap)" "$s0" "B: yazım yok"

# ═══ C. BİRİM: _domconf_fm_apply off, kayıt güvenilmez ═══
# stage'in 'off' kolu: yazım reddedilir (rc 4) AMA ileti açık olabileceğini söyler; 'on' kolu: bu ileti DEĞİL (açma reddi).
reset_all; _on; fm_sim_reload; s0=$(snap)
MOCK_BAD_OWNER="$SD"
out=$( { _domconf_fm_apply example.com example_com off eu - - 0 1; echo "rc=$?"; } 2>&1 ); MOCK_BAD_OWNER=""; out=$(strip <<< "$out")
assert_contains "$out" "rc=4" "C1: apply off (güvenilmez kayıt): rc 4 (yazım reddedildi)"
assert_contains "$out" "yazım reddedildi" "C1: mevcut ret iletisi korunur"
assert_contains "$out" "$LOUD" "C1: kapatma yönü reddi '${LOUD}' der"
assert_eq "$(snap)" "$s0" "C1: yazım yapılmadı"
MOCK_BAD_OWNER="$SD"
out=$( { _domconf_fm_apply example.com example_com on eu "$SCRIPT" 8.3 0 1; echo "rc=$?"; } 2>&1 ); MOCK_BAD_OWNER=""; out=$(strip <<< "$out")
assert_contains "$out" "rc=4" "C2: apply on (güvenilmez kayıt): rc 4"
assert_not_contains "$out" "$LOUD" "C2: açma yönü reddi '${LOUD}' DEMEZ"
assert_eq "$(snap)" "$s0" "C2: yazım yapılmadı"

# ═══ D. KAPALI KANITI VAR (kayıt off, disk 403 kökü): 'AÇIK OLABİLİR' DENMEZ ama ret sessiz değil ═══
for path in repair83 repairall fmroot fmrootall provision phpswitch; do
    reset_all; _on; ( _domconf_fm_auth example.com off ) >/dev/null 2>&1; fm_sim_reload; s0=$(snap)
    assert_eq "$(_shut)" "SHUT" "D [${path}] önkoşul: alan kapalı"
    MOCK_BAD_OWNER="$SD"; runpath "$path"; rc=$?; MOCK_BAD_OWNER=""
    out=$(strip < "$OUTF"); tag="D [kapalı disk / ${path}]"
    assert_eq "$rc" "1" "${tag}: TAM rc 1 (kayıt güvenilmezken yazım yok)"
    assert_not_contains "$out" "$LOUD" "${tag}: diskte KAPALI kanıtı var → '${LOUD}' DENMEZ"
    assert_contains "$out" "KAPALI kanıtı var" "${tag}: kapalı kanıtını söyler"
    assert_eq "$(snap)" "$s0" "${tag}: yazım yok"
done

# ═══ E. acil kapatma işareti + KAPALI disk: 'alan KAPALI kalır' dalı bozulmaz ═══
reset_all; _on; ( _domconf_fm_auth example.com off --emergency ) >/dev/null 2>&1; fm_sim_reload; s0=$(snap)
assert_eq "$(_shut)" "SHUT" "E önkoşul: acil kapatma sonrası kapalı"
for path in repair83 fmroot provision; do
    MOCK_BAD_OWNER="$SD"; runpath "$path"; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
    assert_eq "$rc" "1" "E [${path}]: TAM rc 1"
    assert_not_contains "$out" "$LOUD" "E [${path}]: işaretli + kapalı disk: '${LOUD}' DENMEZ"
    assert_eq "$(_shut)" "SHUT" "E [${path}]: alan kapalı kaldı"
done

# ═══ F. acil kapatma işareti VAR ama disk AÇIK (kapatma yarım): alan açık olabilir → yüksek sesle ═══
reset_all; _on; fm_sim_reload; mkdir -p "$ALTD"; : > "${ALTD}/example_com.emergency"; chmod 600 "${ALTD}/example_com.emergency"; s0=$(snap)
MOCK_BAD_OWNER="$SD"; runpath repair83; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "F: işaret var + disk açık: TAM rc 1"
assert_contains "$out" "$LOUD" "F: işaret var ama diskte KAPALI kanıtı yok → '${LOUD}'"
assert_eq "$(snap)" "$s0" "F: yazım yok"

# ═══ G. status: rc≠0; açık diskte '${LOUD}', kapalı diskte yok ═══
reset_all; _on; fm_sim_reload
MOCK_BAD_OWNER="$SD"; ( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "G1: status (açık disk, güvenilmez kayıt): TAM rc 1"
assert_contains "$out" "$LOUD" "G1: status '${LOUD}' der"
reset_all; _on; ( _domconf_fm_auth example.com off ) >/dev/null 2>&1; fm_sim_reload
MOCK_BAD_OWNER="$SD"; ( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "G2: status (kapalı disk, güvenilmez kayıt): TAM rc 1"
assert_not_contains "$out" "$LOUD" "G2: kapalı diskte '${LOUD}' DENMEZ"

# ═══ H. fm-root KURU (plan): YAPILAMAZ nedeni açık olabileceğini söyler (salt-okur; kapalı diskte söylemez) ═══
reset_all; _on; fm_sim_reload
MOCK_BAD_OWNER="$SD"; ( _domconf_fm_root_cmd example.com ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "H1: fm-root kuru (açık disk, güvenilmez kayıt): TAM rc 1"
assert_contains "$out" "YAPILAMAZ" "H1: YAPILAMAZ"
assert_contains "$out" "$LOUD" "H1: kuru plan nedeni '${LOUD}' der"
reset_all; _on; ( _domconf_fm_auth example.com off ) >/dev/null 2>&1; fm_sim_reload
MOCK_BAD_OWNER="$SD"; ( _domconf_fm_root_cmd example.com ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
assert_not_contains "$out" "$LOUD" "H2: kapalı diskte kuru plan '${LOUD}' DEMEZ"

# ═══ I. DEĞİŞMEYENLER: kapatma yolları kayıttan bağımsız çalışır ═══
for act in "off" "off --emergency"; do
    reset_all; _on; fm_sim_reload
    MOCK_BAD_OWNER="$SD"; ( _domconf_fm_auth example.com $act ) >"$OUTF" 2>&1; rc=$?; MOCK_BAD_OWNER=""; out=$(strip < "$OUTF")
    assert_eq "$rc|$(_shut)" "0|SHUT" "I [${act}]: güvenilmez kayıtta da alan KAPANIR (rc 0, 403 kökü)"
    assert_not_contains "$out" "$LOUD" "I [${act}]: kapatma başarılı → '${LOUD}' DENMEZ"
done
# açma yönü: reddedilir (rc≠0), hiçbir şey değişmez
reset_all; _on; fm_sim_reload; s0=$(snap)
MOCK_BAD_OWNER="$SD"; _on; rc=$?; MOCK_BAD_OWNER=""
assert_eq "$rc|$(snap)" "1|${s0}" "I [on]: güvenilmez kayıtta 'on' reddedilir (TAM rc 1), yazım yok"

test_summary
