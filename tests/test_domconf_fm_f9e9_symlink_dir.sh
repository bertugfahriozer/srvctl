#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar dolaylı çağrılır
# F9e-9 — custom.d/<sname> sembolik bağ ya da root'a ait olmayan / g-o-yazılabilir dizin İZLENMEZ (ARCHITECTURE §15/8 genel ilke).
# FM yazıcıları (on, repair, provision, php-switch, fm-root, fm-root --all) bu girdiye YAZMAZ: yazım 0, rc ≠ 0, yüksek sesli ileti.
# Kapatma yönü ('off', 'off --emergency') yine KAPATIR ama hedefe yazmadan: girdinin KENDİSİ (sembolik bağ ya da yabancı dizin)
# yeni dizinin içine '<sname>.srvctl-emergency.<pid>.<rastgele>' adıyla kenara alınır, yerine root sahipli dizin + 403 kökü kurulur.
# Eski ağaçta (dfcbf5dd) on → 20/21/90, off/--emergency/repair/provision → 20 kiracının dizinine yazılıyordu (CVSS 1.9 AV:L/AC:H/PR:H).
# Matris: 8 komut × 4 girdi türü (sembolik bağ / tenant'a ait dizin / grup-yazılabilir dizin / normal). Gerçek nginx karşılığı:
# test_domconf_fm_f9e9_double_fail_real.sh (bölüm C).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f9c_common.sh"

TEN="${FM_STUBS}/tenant-owned"
# "tenant'a ait dizin" benzetimi: yol değil İNODE işaretlenir (dizin kenara alınınca da kiracının kalır; yerine kurulan yeni dizin root'a ait görünür).
TINO=""
_stat_owner() {
    if [[ -n "$TINO" && "$(ls -di "$1" 2>/dev/null | awk '{print $1}')" == "$TINO" ]]; then printf 'web_x'; else printf 'root'; fi
}
_e()  { ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; }
_em() { ( _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; }
# dizin içeriğinin özeti: göreli yol + içerik toplamı (dosya) / '-' (diğer)
snap() {
    local d="$1" f
    [[ -d "$d" ]] || { echo "YOK"; return 0; }
    ( cd "$d" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -f "$f" && ! -L "$f" ]]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s -\n' "$f"; fi
    done )
}
# ön durum: komuta göre kayıt+dosyalar (açık) ya da boş alan
prep() {
    local cmd="$1"
    TINO=""
    reset_all
    case "$cmd" in
        on|provision) ;;
        *) _on; fm_sim_reload ;;
    esac
}
# girdi türü: normal | sym (sembolik bağ → TEN) | tenant (gerçek dizin, tenant'a ait) | gw (gerçek dizin, grup-yazılabilir)
turn() {
    local kind="$1"
    case "$kind" in
        normal) ;;
        sym)    rm -rf "$TEN"; mv "$CUR_DIR" "$TEN"; ln -s "$TEN" "$CUR_DIR" ;;
        tenant) TINO=$(ls -di "$CUR_DIR" | awk '{print $1}') ;;
        gw)     chmod 775 "$CUR_DIR" ;;
    esac
    printf 'kiracının kendi dosyası\n' > "$(if [[ "$kind" == sym ]]; then echo "$TEN"; else echo "$CUR_DIR"; fi)/tenant-note.txt"
    fm_sim_reload
}
run_cmd() {
    case "$1" in
        on)        _on ;;
        off)       _e ;;
        emergency) _em ;;
        repair)    _repair 8.4 ;;
        provision) _provision ;;
        phpswitch) _phpswitch ;;
        fmroot)    _fmroot ;;
        fmrootall) _fmroot_all ;;
        repair0)   _repair ;;
        provisionf) _provision ;;
        status)    ( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1 ;;
        audit)     ( _domconf_nginx_audit example.com ) >"$OUTF" 2>&1 ;;
    esac
}
# beklenen TAM rc (açma yönü yazıcıları: reddedildi → 1; kapatma yönü: sondası kapalı imzasını gördü → 0)
exp_rc() { case "$1" in off|emergency) echo 0 ;; *) echo 1 ;; esac; }

# F9e-10 (§15/56(a)): repair0 = KAYMASIZ repair (PHP sürümü aynı, dosyalar kayıtla eşit → yazım gerekmez); provisionf = DOLU durumdan
# (kayıt + dosyalar yerinde) provision; status ve audit (nginx-audit). Dosyalar kayıtla eşleşse bile güvenilmeyen custom.d/<sname> için
# BAŞARI BİLDİRİLMEZ: rc 1 + yüksek sesli ileti, yazım 0 (eskiden: repair/provision rc 0 sessiz, status "AÇIK", audit "temiz").
for cmd in on repair provision phpswitch fmroot fmrootall repair0 provisionf status audit off emergency; do
    for kind in sym tenant gw normal; do
        tag="${cmd}/${kind}"
        prep "$cmd"
        if [[ "$kind" == normal ]]; then turn normal; else turn "$kind"; fi
        if [[ "$kind" == sym ]]; then WATCH="$TEN"; else WATCH="$CUR_DIR"; fi
        before=$(snap "$WATCH")
        run_cmd "$cmd"; rc=$?
        out=$(strip < "$OUTF")
        if [[ "$kind" == normal ]]; then
            case "$cmd" in
                on)  assert_eq "$rc|$(_shut)|$(_st)" "0|OPEN|on" "[$tag] kontrol: normal dizinde 'on' açar (rc 0)" ;;
                off|emergency) assert_eq "$rc|$(_shut)" "0|SHUT" "[$tag] kontrol: normal dizinde kapatır (rc 0, 20 = 403 kökü, 90/21 yok)" ;;
                provision) assert_eq "$rc|$(_shut)" "0|SHUT" "[$tag] kontrol: normal dizinde 403 kökü kurulur" ;;
                repair0|provisionf) assert_eq "$rc|$(_st)|$(_shut)" "0|on|OPEN" "[$tag] kontrol: normal dizinde rc 0, açık alan açık kalır" ;;
                status) assert_contains "$out" "fm-auth AÇIK" "[$tag] kontrol: normal dizinde status AÇIK der"
                        assert_not_contains "$out" "GÜVENİLMEZ" "[$tag] kontrol: normal dizinde GÜVENİLMEZ demez" ;;
                audit)  assert_contains "$out" "[example.com]" "[$tag] kontrol: normal dizinde audit alanı denetler"
                        assert_not_contains "$out" "GÜVENİLMEZ" "[$tag] kontrol: normal dizinde GÜVENİLMEZ demez" ;;
                *) assert_eq "$([[ "$rc" == 0 || "$rc" == 10 ]] && echo tamam || echo "rc=$rc")" "tamam" "[$tag] kontrol: normal dizinde komut çalışır" ;;
            esac
            continue
        fi
        case "$cmd" in
            off|emergency)
                assert_eq "$rc" "0" "[$tag] kapatma yönü: rc 0 (kapandı ve doğrulandı)"
                assert_contains "$out" "kenara alındı" "[$tag] ileti: girdi kenara alındı"
                assert_eq "$([[ -d "$CUR_DIR" && ! -L "$CUR_DIR" ]] && echo gercek-dizin || echo DEGIL)" "gercek-dizin" "[$tag] custom.d/example_com artık sembolik bağ DEĞİL, gerçek dizin"
                assert_eq "$(_shut)" "SHUT" "[$tag] yeni dizinde 20 = 403 kökü, 90/21 yok"
                assert_eq "$(_run)" "RUN-CLOSED" "[$tag] çalışan görüntü (reload sonrası) KAPALI"
                if [[ "$kind" == sym ]]; then assert_eq "$(snap "$TEN")" "$before" "[$tag] kiracının dizini DEĞİŞMEDİ (yazım 0; içerik aynı)"; fi
                aside=$(find "$CUR_DIR" -maxdepth 1 -name 'example_com.srvctl-emergency.*' | head -1)
                assert_eq "$([[ -n "$aside" ]] && echo var || echo YOK)" "var" "[$tag] kenara alınan girdi yeni dizinin içinde (example_com.srvctl-emergency.*)"
                shown=$(sed -n 's/.*girdi kenara alındı (\([^)]*\)).*/\1/p' <<< "$out" | head -1)
                assert_eq "$([[ -n "$shown" && "$shown" == "$aside" && "$shown" != *.srvctl-new.* ]] && echo gercek-yol || echo "YANLIS:${shown}")" "gercek-yol" "[$tag] ileti: yazdırılan kenara alma yolu işlem SONRASI gerçek yoldur (geçici '.srvctl-new.' yolu değil)"
                if [[ "$kind" == sym ]]; then
                    assert_eq "$([[ -L "$aside" ]] && echo baglanti || echo DEGIL)" "baglanti" "[$tag] kenara alınan SEMBOLİK BAĞIN kendisidir (hedef taşınmadı)"
                else
                    assert_eq "$(snap "$aside")" "$before" "[$tag] kenara alınan yabancı dizin içeriğiyle aynen duruyor"
                fi
                ;;
            *)
                assert_eq "$rc" "$(exp_rc "$cmd")" "[$tag] TAM rc $(exp_rc "$cmd") (reddedildi)"
                assert_eq "$(snap "$WATCH")" "$before" "[$tag] kiracının dizinine YAZILMADI (içerik aynı: yazım 0)"
                case "$cmd" in
                    status|audit)
                        assert_contains "$out" "GÜVENİLMEZ" "[$tag] ileti: GÜVENİLMEZ (başarı/AÇIK/temiz bildirilmez)"
                        assert_not_contains "$out" "fm-auth AÇIK" "[$tag] 'fm-auth AÇIK' DEMEZ"
                        assert_not_contains "$out" "  temiz" "[$tag] 'temiz' DEMEZ" ;;
                    fmroot|fmrootall) assert_contains "$out" "YAPILAMAZ" "[$tag] ileti: YAPILAMAZ" ;;
                    *) assert_contains "$out" "YAPILAMAZ" "[$tag] ileti: YAPILAMAZ — girdi izlenmedi" ;;
                esac
                if [[ "$kind" == sym ]]; then
                    assert_eq "$([[ -L "$CUR_DIR" ]] && echo baglanti || echo DEGIL)" "baglanti" "[$tag] girdi OLDUĞU GİBİ (açma yönü yazıcıları taşımaz/silmez)"
                fi
                ;;
        esac
    done
done

# kapatma yapılamıyorsa (üst dizin yazılamaz → kenara alma imkânsız): "FM HÂLÂ AÇIK OLABİLİR" + rc ≠ 0, hedefe yine yazılmaz
for cmd in off emergency; do
    prep "$cmd"; turn sym
    before=$(snap "$TEN")
    chmod 555 "$SRVCTL_NGINX_CUSTOM_DIR"
    run_cmd "$cmd"; rc=$?
    chmod 755 "$SRVCTL_NGINX_CUSTOM_DIR"
    out=$(strip < "$OUTF")
    assert_eq "$([[ "$rc" != 0 ]] && echo sifirdan-farkli || echo "rc=$rc")" "sifirdan-farkli" "[$cmd/yapilamaz] kenara alma imkânsız → rc ≠ 0"
    assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "[$cmd/yapilamaz] ileti: FM HÂLÂ AÇIK OLABİLİR"
    assert_eq "$(snap "$TEN")" "$before" "[$cmd/yapilamaz] kiracının dizinine yine YAZILMADI"
    assert_eq "$([[ -L "$CUR_DIR" ]] && echo baglanti || echo DEGIL)" "baglanti" "[$cmd/yapilamaz] girdi dokunulmadan duruyor"
done

# otomatik yollar asla açmaz: kapatma sonrası (kenara alınmış girdi + yeni dizin) altı yol alanı AÇMAZ
prep off; turn sym; _e
for follow in repair84 phpswitch fmroot fmrootall provision; do
    runpath "$follow"
    assert_eq "$(_shut)" "SHUT" "[otomatik/$follow] kapatma sonrası otomatik yol alanı AÇMADI (§15/33)"
done
test_summary
