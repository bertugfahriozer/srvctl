#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e-6 — ARCHITECTURE §15/53(a): `fm-auth <alan> on` geri almasında (_domconf_fm_on_unwind_locked) köken kaydı OKUNAMAZ ya da GÜVENİLMEZ
# olursa (`_fmprov_load` rc≠0) alan yine KAPATILIR: disk acil kapatma yoluyla (nginx custom.d dosyaları) kapatılır, "FM HÂLÂ AÇIK OLABİLİR"
# denir ve kayıt dizinine HİÇBİR ŞEY yazılmaz (kayıt güvenilmezken yazım yok, §15/44(a)). Acil işaret bu dalda kayıt dizinine yazılmaz;
# kayıt güvenilmezse yalnız kayıt dizininin dışındaki ikinci konuma yazılır.
# Eski ağaçta (domconf.sh e13ece9a) bu dal diske ve işarete dokunmadan çıkardı: disk AÇIK + kayıt 'on' kalırdı.
# Kayıt, `on` commit'i ile geri alma arasında bozulur: reload sırasında (reload kolu) ya da ilk sonda isteğinde (probe kolu).
# Altı otomatik yol (repair, repair84, php-switch, fm-root, fm-root --all, provision) sonrasında alan AÇILMAZ.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

DIG1="${FM_STUBS}/f9e6_dig1"; BRKFLAG="${FM_STUBS}/f9e6_brkflag"
has9021() { if [[ -e "$F90" || -L "$F90" || -e "$F21" || -L "$F21" ]]; then echo VAR; else echo YOK; fi; }
em_state() { if [[ -e "${SD}/example_com.emergency" || -L "${SD}/example_com.emergency" ]]; then echo VAR; else echo YOK; fi; }
em_alt() { if [[ -e "${ALTD}/example_com.emergency" ]]; then echo VAR; else echo YOK; fi; }
# kayıt dizininin özeti: dizin modu + her girdinin yolu, modu, içerik toplamı
sd_digest() {
    local f
    printf 'DIR %s\n' "$(_stat_mode "$SD")"
    find "$SD" -mindepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -f "$f" && ! -L "$f" ]]; then printf '%s %s %s\n' "$f" "$(_stat_mode "$f")" "$(cksum < "$f")"; else printf '%s %s -\n' "$f" "$(_stat_mode "$f")"; fi
    done
}
# kayıt bozma: untrusted = dizin 0755 (güvenilmez) | corrupt = manifest çöp (okunamaz) | missing = manifest yok
break_record() {
    case "$1" in
        untrusted) chmod 755 "$SD" ;;
        corrupt)   printf 'cop\n' > "$MAN" ;;
        missing)   rm -f -- "$MAN" ;;
    esac
    sd_digest > "$DIG1"
}
eval "_f9e6_orig_systemctl() $(declare -f systemctl | sed '1d')"
eval "_f9e6_orig_curl() $(declare -f curl | sed '1d')"
systemctl() {   # reload kolu: reload sırasında (commit'ten SONRA) kayıt bozulur
    if [[ "$1" == "reload" && -n "${F9E6_BREAK_AT:-}" && "${F9E6_BREAK_AT}" == "reload" && ! -e "$BRKFLAG" ]]; then
        : > "$BRKFLAG"; break_record "$F9E6_BREAK"
    fi
    _f9e6_orig_systemctl "$@"
}
curl() {        # probe kolu: ilk sonda isteğinde (kayıt-sonrası kontrolden SONRA) kayıt bozulur
    if [[ -n "${F9E6_BREAK_AT:-}" && "${F9E6_BREAK_AT}" == "probe" && ! -e "$BRKFLAG" ]]; then
        : > "$BRKFLAG"; break_record "$F9E6_BREAK"
    fi
    _f9e6_orig_curl "$@"
}

# unwind: <mod: untrusted|corrupt|missing> <kol: reload|probe>; sonra altı yol
unwind_cell() {
    local brk="$1" at="$2" follow rc out tag="$1/$2"
    reset_all; rm -f "$BRKFLAG" "$DIG1"
    F9E6_BREAK="$brk"; F9E6_BREAK_AT="$at"
    if [[ "$at" == "reload" ]]; then
        SYSTEMCTL_RC=1
    else
        FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403
    fi
    _on; rc=$?
    F9E6_BREAK_AT=""; SYSTEMCTL_RC=0; FM_PROBE_MODE=sim
    out=$(strip < "$OUTF")
    assert_eq "$([[ -e "$BRKFLAG" ]] && echo bozuldu || echo YOK)" "bozuldu" "U[$tag] 0: kayıt commit'ten sonra gerçekten bozuldu (düzenek)"
    assert_eq "$rc" "1" "U[$tag] 1: geri alma kaydı okuyamadı → 'on' tam rc 1"
    assert_contains "$out" "açılış GERİ ALINAMADI (köken kaydı" "U[$tag] 2: ileti geri alınamadığını ve nedenini (kayıt) söyler"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "U[$tag] 3: ileti yüksek sesli"
    assert_contains "$out" "kayıt dizinine hiçbir şey yazılmadı" "U[$tag] 4: ileti kayıt dizinine yazılmadığını söyler"
    assert_contains "$out" "disk acil kapatma yoluyla KAPATILDI" "U[$tag] 5: ileti diskin acil yoldan kapatıldığını söyler"
    assert_not_contains "$out" "fm-auth AÇILDI" "U[$tag] 6: 'AÇILDI' denmez"
    assert_eq "$(_shut)|$(has9021)" "SHUT|YOK" "U[$tag] 7: disk KAPATILDI (20 = 403 kökü, 90/21 yok)"
    assert_eq "$(sd_digest)" "$(cat "$DIG1")" "U[$tag] 8: kayıt dizininin özeti geri almadan önce ve sonra AYNI (hiçbir şey yazılmadı)"
    assert_eq "$(em_state)" "YOK" "U[$tag] 9: acil işaret KAYIT dizinine yazılmadı"
    case "$brk" in
        untrusted|corrupt) assert_eq "$(em_alt)" "VAR" "U[$tag] 10: kayıt güvenilmez → işaret yalnız ikinci konumda (kayıt dizininin dışında)" ;;
        missing)           assert_eq "$(em_alt)" "YOK" "U[$tag] 10: kayıt hiç yok → 'on' diye okunacak bir şey yok, yetim işaret bırakılmaz" ;;
    esac
    if [[ "$brk" == "untrusted" ]]; then chmod 700 "$SD"; fi   # operatör dizini düzeltir
    for follow in repairall repair84 phpswitch fmroot fmrootall provision; do
        # probe kolunda reload zaten başarılıydı (canlı mock o an AÇIK imzasında; çalışan durumu düzeltmek 'off --emergency'nin işi,
        # ileti bunu söyler): otomatik yol onu açık BIRAKABİLİR ama yeniden AÇMAZ → sonrası kapalı ya da öncekiyle aynı.
        pre_run=$(_run)
        runpath "$follow"
        assert_eq "$(_shut)|$(has9021)" "SHUT|YOK" "U[$tag/$follow] 11: otomatik yol sonrası disk AÇIK DEĞİL"
        case "$(_run)" in RUN-CLOSED|RUN-NONE|"$pre_run") r12=ok ;; *) r12="$(_run)" ;; esac
        assert_eq "$r12" "ok" "U[$tag/$follow] 12: otomatik yol canlı mock'u yeni AÇMADI (önce=${pre_run})"
        if [[ "$at" == "reload" ]]; then assert_not_contains "$(_run)" "RUN-OPEN" "U[$tag/$follow] 12b: reload kolunda canlı mock hiç AÇIK imzasında değil"; fi
        assert_not_contains "$(strip < "$OUTF")" "fm-auth AÇILDI" "U[$tag/$follow] 13: otomatik yol 'AÇILDI' demez"
    done
}
for brk in untrusted corrupt missing; do unwind_cell "$brk" reload; done
unwind_cell untrusted probe
unwind_cell corrupt probe

# ═══ N. kayıt SAĞLAM iken (lrc=0) davranış değişmez: tek hata → geri alma başarılı, rc 1, işaret kalmaz ═══
reset_all; SYSTEMCTL_RC=1; _on; rc=$?; SYSTEMCTL_RC=0
out=$(strip < "$OUTF")
assert_eq "$rc|$(_shut)|$(_st)|$(em_state)|$(em_alt)" "1|SHUT|off|YOK|YOK" "N1: kayıt sağlam: reload hatası → geri alma başarılı (kayıt off, disk kapalı, işaret yok)"
assert_contains "$out" "açılış GERİ ALINDI" "N2: kayıt sağlam: ileti 'GERİ ALINDI' der"
assert_not_contains "$out" "köken kaydı" "N3: kayıt sağlam: yeni dal çalışmadı"
test_summary
