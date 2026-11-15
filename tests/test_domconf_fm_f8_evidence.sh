#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F8/a1 (QL8-M1) — KAPALI KANITI sürümden bağımsız (+ C6d kalıcı testi) ve gövde imzası bağımsız ikinci doğrulaması (L13).
#  M1-a  srvctl'in ürettiği HER 403 kökü biçimi KAPALI kanıtıdır: güncel / önceki / GELECEK tpl_ver imzası ve eski F4-F6 imzasız biçim
#        (özeti bilinen ya da köken kaydında kayıtlı); tpl_ver artışı kanıtı bozmaz
#  M1-b  YAPISAL ve KATI: ek direktif / include / proxy_pass / ek location / bozuk imza / karışık biçim / sembolik bağ / sert bağ /
#        yabancı sahip / yazılabilir mod / NUL bayt → kanıt DEĞİL
#  M1-c  status bu durumda 'off' önerir (TAMPERED / 'fm-root --apply' ONARIMI değil)
#  C6d   kayıt 'on' + imzasız F4-F6 kökü + 90/21 yok + işaret yok: 8 yolun hiçbiri alanı AÇMAZ
#        (fmroot, repair 8.3/8.4, fmrootall, phpswitch, repairall, stalebk_fmroot, stalebk_repair)
#  L13   imza/gövde sözleşmesinin BAĞIMSIZ ikinci kilidi (probe_contract'tan ayrı dosya, ayrı yollar)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
export SRVCTL_FM_PROBE_RETRIES=1 SRVCTL_FM_PROBE_RETRY_SLEEP=0
OUTF="${FM_STUBS}/out.txt"
SD="${SRVCTL_STATE_DIR}/_fm-auth"
MARK="${SD}/example_com.emergency"
list_all_domains() { printf '%s\n' example.com; }

_on()  { ( _domconf_fm_auth example.com on "--script=${SCRIPT}" "$@" ) >"$OUTF" 2>&1; }
_e()   { ( _domconf_fm_auth example.com off "$@" ) >"$OUTF" 2>&1; }
_st()  { sed -n 's/^state //p' "$MAN" 2>/dev/null | head -1; }
_out() { cat "$OUTF"; }
_run() { if [[ -f "$FM_RUNNING/20-srvctl-fm-upload.conf" ]]; then grep -q auth_request "$FM_RUNNING/20-srvctl-fm-upload.conf" && echo RUN-OPEN || echo RUN-CLOSED; else echo RUN-NONE; fi; }
_tamp() { find "$CUR_DIR" -maxdepth 1 -name '*.srvctl-tampered' 2>/dev/null | wc -l | tr -d ' '; }
# "kapalı": 90/21 yok ve 20 yalnız 403 (auth_request YOK) — eski/yeni imzalı kök fark etmez
_shut() { [[ ! -e "$F90" && ! -L "$F90" && ! -e "$F21" && ! -L "$F21" && -f "$F20" ]] && ! grep -q 'auth_request' "$F20" && grep -q 'return 403' "$F20"; }
_sh() { _shut && echo SHUT || echo OPEN; }
_repair() { ( _domconf_fm_auth_repair example.com "${1:-${DEFAULT_PHP_VERSION}}" 1 ) >"$OUTF" 2>&1; }
_fmroot() { ( _domconf_fm_root_cmd example.com --apply ) >"$OUTF" 2>&1; }
_fmroot_all() { ( _domconf_fm_root_cmd --all --apply ) >"$OUTF" 2>&1; }
_phpswitch() { ( _domconf_fm_auth_sock_sync example.com 8.4 ) >"$OUTF" 2>&1; }
_batch() { ( _domconf_fm_auth_repair example.com "${DEFAULT_PHP_VERSION}" 0 ) >"$OUTF" 2>&1; ( systemctl reload nginx ) >/dev/null 2>&1; }
_mk_stale_bk() {   # açık pre-state yedeği (kesintiye uğramış bir yazımdan kalmış)
    local b="${SD}/.bk.example_com.${1:-AAAAAA}" f
    rm -rf "$b"; mkdir -p "$b"
    for f in "$F90" "$F21" "$F20"; do if [[ -e "$f" ]]; then cp -p "$f" "${b}/"; fi; done
    cp -p "$MAN" "${b}/manifest"
}
# kök biçimleri
off_ver() { ( _DOMCONF_FM_TPL_VER="$1"; _domconf_fm_render_off example_com ); }       # tpl_ver=$1 imzalı kapalı kök
legacy_root() {                                                                        # F4-F6 imzasız kapalı kök (heredoc çıktısı)
    printf '%s\n' '# srvctl: FileManager yükleme yolu KAPALI (srvctl domain fm-auth <alan> off). SRVCTL ÜRETİR.' \
        "# Bu 403 kökü, /_fm/ yolunun CI4'e düşmesini engeller; açmak için: fm-auth <alan> on --script=..." \
        'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }'
}
# 'on' sonrası diski "kayıt on + diskte yalnız $1 kök" durumuna getir (işaret YOK)
mk_state() {   # mk_state <old-ver N | legacy | text> [metin]
    _fm_reset; _on
    case "$1" in
        ver) off_ver "$2" > "$F20" ;;
        legacy) legacy_root > "$F20" ;;
        text) printf '%s\n' "${@:2}" > "$F20" ;;
    esac
    chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
}
ev() { _fmprov_load example_com; printf '%s|%s' "$_FMP_STATE" "$_FMP_EMERGENCY"; }

SIG=$(_domconf_fm_body_sig example_com)
SIG_IND=$(printf 'srvctl-fm-sig:v%s:%s' "$_DOMCONF_FM_TPL_VER" example_com | shasum -a 256 | cut -c1-12)

echo "── L13: imza/gövde sözleşmesi — BAĞIMSIZ ikinci kilit (probe_contract'tan ayrı yollar) ──"
assert_eq "$SIG" "$SIG_IND" "imza = ilk 12 hex(sha256('srvctl-fm-sig:v'+tpl_ver+':'+sname)) — testte shasum ile BAĞIMSIZ hesap"
assert_eq "${#SIG}" "12" "imza TAM 12 hex"
assert_eq "$(_domconf_fm_body_sig other_com)" "$(printf 'srvctl-fm-sig:v%s:%s' "$_DOMCONF_FM_TPL_VER" other_com | shasum -a 256 | cut -c1-12)" "ikinci alan için de bağımsız hesapla eşit"
assert_eq "$([[ "$SIG" != "$(_domconf_fm_body_sig other_com)" ]] && echo ayrik)" "ayrik" "farklı alan = farklı imza"
assert_eq "$(( $(off_ver 1 | grep -c 'srvctl-fm-closed') ))" "2" "kapalı kök: İKİ konumda da gövde imzası"
assert_eq "$(_domconf_fm_render_off example_com | grep -c "return 403 \"srvctl-fm-closed ${SIG}\"; }")" "2" "kapalı kök: TAM gövde 'srvctl-fm-closed <imza>'"
assert_eq "$(_domconf_fm_render_off example_com | grep -c 'location = /_fm {\|location \^~ /_fm/ {')" "2" "kapalı kök: iki konum (= /_fm, ^~ /_fm/)"
assert_eq "$(_domconf_fm_render_upload eu 0 example_com | grep -c "return 411 \"srvctl-fm-open ${SIG}\";")" "1" "açık şablon: 411 gövdesi 'srvctl-fm-open <imza>' (TEK yer)"
assert_eq "$(_domconf_fm_render_upload eu 0 example_com | grep -c 'return [0-9]* "srvctl-fm-open')" "1" "açık şablon: 'srvctl-fm-open' gövdesi yalnız Content-Length'siz 411 kolunda"
assert_eq "$(_domconf_fm_render_upload eu 0 example_com | grep -c 'return [0-9]* "srvctl-fm-closed')" "0" "açık şablonda kapalı imzalı return YOK"
_fm_reset; _on; fm_sim_reload
assert_contains "$(cat "$F20")" "return 411 \"srvctl-fm-open ${SIG}\";" "fm-auth on diske AÇIK imzayı yazdı"
_domconf_fm_runtime_probe example.com
assert_eq "$_FMRT_STATE" "open" "sonda: on sonrası AÇIK (411 + tam açık imza)"
_e --emergency; rc=$?; fm_sim_reload
assert_eq "$(cat "$F20")" "$(_domconf_fm_render_off example_com)" "acil kapatma diske TAM render_off yazdı"
assert_contains "$(cat "$F20")" "srvctl-fm-closed ${SIG}" "acil kapalı kök gövdesi bağımsız hesaplanan imzayı taşır"
_domconf_fm_runtime_probe example.com
assert_eq "$_FMRT_STATE" "closed" "sonda: acil kapatma sonrası KAPALI (403 + tam kapalı imza)"
FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403
FM_PROBE_BODY_HTTPS="srvctl-fm-closed ${SIG:0:11}"; FM_PROBE_BODY_HTTP="$FM_PROBE_BODY_HTTPS"
_domconf_fm_runtime_probe example.com; assert_eq "$_FMRT_STATE" "unknown" "sonda: 11 haneli (kesik) imza KAPALI sayılmaz"
FM_PROBE_BODY_HTTPS="srvctl-fm-closed ${SIG} "; FM_PROBE_BODY_HTTP="$FM_PROBE_BODY_HTTPS"
_domconf_fm_runtime_probe example.com; assert_eq "$_FMRT_STATE" "unknown" "sonda: imzanın SONUNA eklenen karakter KAPALI sayılmaz (önek eşleşmesi YOK)"
FM_PROBE_BODY_HTTPS="x srvctl-fm-closed ${SIG}"; FM_PROBE_BODY_HTTP="$FM_PROBE_BODY_HTTPS"
_domconf_fm_runtime_probe example.com; assert_eq "$_FMRT_STATE" "unknown" "sonda: imzanın ÖNÜNE eklenen karakter KAPALI sayılmaz"
FM_PROBE_BODY_HTTPS="srvctl-fm-closed $(_domconf_fm_body_sig other_com)"; FM_PROBE_BODY_HTTP="$FM_PROBE_BODY_HTTPS"
_domconf_fm_runtime_probe example.com; assert_eq "$_FMRT_STATE" "unknown" "sonda: BAŞKA alanın imzası KAPALI sayılmaz"
FM_PROBE_CODE_HTTPS=411; FM_PROBE_CODE_HTTP=411
FM_PROBE_BODY_HTTPS="srvctl-fm-closed ${SIG}"; FM_PROBE_BODY_HTTP="$FM_PROBE_BODY_HTTPS"
_domconf_fm_runtime_probe example.com; assert_eq "$_FMRT_STATE" "unknown" "sonda: 411 + KAPALI imza = tutarsız → unknown (kod ve imza BİRLİKTE)"
FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403
FM_PROBE_BODY_HTTPS="srvctl-fm-open ${SIG}"; FM_PROBE_BODY_HTTP="$FM_PROBE_BODY_HTTPS"
_domconf_fm_runtime_probe example.com; assert_eq "$_FMRT_STATE" "unknown" "sonda: 403 + AÇIK imza = tutarsız → unknown"
unset FM_PROBE_BODY_HTTPS FM_PROBE_BODY_HTTP; FM_PROBE_MODE=sim

echo "── M1-a: KAPALI KANITI srvctl'in ürettiği HER kapalı-kök biçimini tanır ──"
mk_state ver "$_DOMCONF_FM_TPL_VER"
assert_eq "$(ev)" "off|2" "güncel tpl_ver imzalı kök → kanıt (kayıt 'on' KAPALI sayılır)"
mk_state ver 1
assert_eq "$(ev)" "off|2" "ÖNCEKİ tpl_ver (1) imzalı kök → kanıt"
mk_state ver 99
assert_eq "$(ev)" "off|2" "GELECEK tpl_ver (99) imzalı kök → kanıt"
assert_eq "$([[ "$(off_ver 1)" != "$(off_ver 2)" ]] && echo farkli)" "farkli" "(kontrol) tpl_ver 1 ve 2 kökleri GERÇEKTEN farklı imzalı"
mk_state legacy
assert_eq "$(ev)" "off|2" "eski F4-F6 imzasız kök (özeti BİLİNEN srvctl üretimi) → kanıt"
# tpl_ver artışı kanıtı bozmaz: kök 2 ile yazıldı, sonra kod tpl_ver=3'e çıktı
mk_state ver 2
_DOMCONF_FM_TPL_VER=3
assert_eq "$(ev)" "off|2" "tpl_ver YAPAY ARTIRILDI (3): v2 imzalı kök hâlâ kanıt (F7: kanıt kayboluyordu)"
_DOMCONF_FM_TPL_VER=2
# imzasız ama özeti BİLİNMEYEN (yorum satırı farklı): köken kaydında yoksa kanıt DEĞİL; kayıtlıysa kanıt
mk_state text '# başka bir yorum' 'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }'
assert_eq "$(ev)" "off|3" "imzasız, özeti BİLİNMEYEN/KAYITSIZ 403 kökü → kanıt DEĞİL (|2 değil) ama KAPALI GÖRÜNÜMLÜ (|3): kayıt 'on' KAPALI sayılır, hiçbir yol AÇMAZ (F9 qalab9-I2; F8: on|0 idi)"
vh=$(_domconf_sha256_file "$F20")
_fmprov_load example_com; _rec="$_FMP_HASHES"
_fmprov_write example_com on "$_FMP_REGION" "$_FMP_SCRIPT" "$_FMP_PHP" "$_FMP_MODSEC" "${_rec}${vh} ${_DOMCONF_FM_UP_FILE}"$'\n'
assert_eq "$(ev)" "off|2" "aynı kök, özeti KÖKEN KAYDINDA kayıtlıysa → kanıt"
# 90 ya da 21 diskte → kanıt YOK (mevcut kural korunur)
mk_state ver 1
: > "$F21"
assert_eq "$(ev)" "off|4" "21 diskte → kanıt YOK (eski biçimli kök olsa bile); F9b: kayıt on + tanınan açık eser DEĞİL → kapalı sayılır (sınıf 4, otomatik yol açmaz)"
rm -f "$F21"

echo "── M1-b: yapısal ve KATI — başka her şey kanıt DEĞİL ──"
SG="srvctl-fm-closed ${SIG}"
neg() {   # neg <ad> <satırlar…>
    local nm="$1"; shift
    mk_state text "$@"
    assert_eq "$(ev)" "off|4" "negatif: ${nm} → kanıt DEĞİL (F9b: tanınan açık eser de DEĞİL → sınıf 4, kapalı sayılır; otomatik yol açmaz)"
}
EQ="location = /_fm { return 403 \"${SG}\"; }"
PR="location ^~ /_fm/ { return 403 \"${SG}\"; }"
mk_state text "$EQ" "$PR"; assert_eq "$(ev)" "off|2" "pozitif kontrol: iki doğru satır → kanıt"
neg "ek proxy_pass direktifi" "$EQ" "$PR" 'proxy_pass http://127.0.0.1:9;'
neg "ek include" "$EQ" "$PR" 'include /etc/nginx/x.conf;'
neg "ek location bloğu" "$EQ" "$PR" 'location /x { return 200; }'
neg "bir konum eksik (yalnız = /_fm)" "$EQ"
neg "bir konum eksik (yalnız ^~ /_fm/)" "$PR"
neg "aynı konum iki kez" "$EQ" "$EQ" "$PR"
neg "imza 11 hex" "location = /_fm { return 403 \"srvctl-fm-closed ${SIG:0:11}\"; }" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG:0:11}\"; }"
neg "imza 13 hex" "location = /_fm { return 403 \"srvctl-fm-closed ${SIG}a\"; }" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed ${SIG}a\"; }"
neg "büyük harfli imza" 'location = /_fm { return 403 "srvctl-fm-closed ABCDEF012345"; }' 'location ^~ /_fm/ { return 403 "srvctl-fm-closed ABCDEF012345"; }'
neg "hex olmayan imza" 'location = /_fm { return 403 "srvctl-fm-closed zzzzzzzzzzzz"; }' 'location ^~ /_fm/ { return 403 "srvctl-fm-closed zzzzzzzzzzzz"; }'
neg "iki satırda FARKLI imza" "$EQ" "location ^~ /_fm/ { return 403 \"srvctl-fm-closed $(_domconf_fm_body_sig other_com)\"; }"
neg "imzalı + imzasız karışık" "$EQ" 'location ^~ /_fm/ { return 403; }'
neg "return 404" "location = /_fm { return 404 \"${SG}\"; }" "location ^~ /_fm/ { return 404 \"${SG}\"; }"
neg "return 200" "location = /_fm { return 200 \"${SG}\"; }" "location ^~ /_fm/ { return 200 \"${SG}\"; }"
neg "başka gövde metni" 'location = /_fm { return 403 "closed"; }' 'location ^~ /_fm/ { return 403 "closed"; }'
neg "satırlar tek satırda birleşik + ek include" "${EQ} include /x;" "$PR"
neg3() {   # neg3 <ad> <satırlar…>  — kanıt DEĞİL ama kapalı görünümlü (F9 qalab9-I2): kayıt 'on' KAPALI sayılır (off|3)
    local nm="$1"; shift
    mk_state text "$@"
    assert_eq "$(ev)" "off|3" "kozmetik sapma: ${nm} → kanıt DEĞİL (|2 değil), KAPALI GÖRÜNÜMLÜ (|3): alan AÇILMAZ"
}
neg3 "baştaki boşluk" " ${EQ}" "$PR"
neg "satır sonu ';' eksik" "location = /_fm { return 403 \"${SG}\" }" "$PR"
neg "aynı satırda ikinci blok" "$EQ $PR"
neg "boş dosya"
mk_state text "$EQ" "$PR"; : > "$F20"
assert_eq "$(ev)" "off|4" "negatif: 0 bayt dosya → kanıt DEĞİL (F9b: sınıf 4)"
# dosya özellikleri
mk_state text "$EQ" "$PR"; printf '\0' >> "$F20"
assert_eq "$(ev)" "off|4" "negatif: NUL baytlı dosya → kanıt DEĞİL (read NUL'u sessizce atardı; F9b: sınıf 4)"
mk_state text "$EQ" "$PR"; mv "$F20" "${F20}.real"; ln -s "${F20}.real" "$F20"
assert_eq "$(ev)" "off|4" "negatif: 20 sembolik bağ → kanıt DEĞİL (F9b: sınıf 4)"
rm -f "$F20" "${F20}.real"
mk_state text "$EQ" "$PR"; ln "$F20" "${F20}.hard"
assert_eq "$(ev)" "off|3" "kozmetik sapma: sert bağlı (nlink 2) → kanıt DEĞİL (|2 değil), KAPALI GÖRÜNÜMLÜ (|3)"
rm -f "${F20}.hard"
mk_state text "$EQ" "$PR"; MOCK_BAD_OWNER="$F20"
assert_eq "$(ev)" "off|3" "kozmetik sapma: root olmayan sahip → kanıt DEĞİL (|2 değil), KAPALI GÖRÜNÜMLÜ (|3)"
MOCK_BAD_OWNER=""
mk_state text "$EQ" "$PR"; chmod 666 "$F20"
assert_eq "$(ev)" "off|3" "kozmetik sapma: g/o yazılabilir (666) → kanıt DEĞİL (|2 değil), KAPALI GÖRÜNÜMLÜ (|3)"
chmod 644 "$F20"
mk_state text "$EQ" "$PR"; rm -f "$F20"; mkdir "$F20"
assert_eq "$(ev)" "off|4" "negatif: 20 bir DİZİN → kanıt DEĞİL (F9b: sınıf 4)"
rmdir "$F20"
# yorum / boş satırlar tanımayı bozmaz (nginx için yok hükmünde)
mk_state text '# yorum' '' "$EQ" '#   başka yorum' "$PR" ''
assert_eq "$(ev)" "off|2" "pozitif: yalnız '#' yorum ve boş satırlar eklenmiş kök → kanıt"

echo "── M1-c: status bu durumda 'off' önerir (TAMPERED / fm-root ONARIMI değil) ──"
for how in "ver 1" "ver 99" "legacy"; do
    # shellcheck disable=SC2086
    mk_state $how
    out=$(_domconf_fm_auth example.com status 2>&1); rc=$?
    assert_contains "$out" "KAPALI KANITI" "status [${how}]: KAPALI KANITI söylenir"
    assert_contains "$out" "fm-auth example.com off" "status [${how}]: 'off' önerir"
    assert_not_contains "$out" "TAMPERED" "status [${how}]: TAMPERED DEMEZ"
    assert_not_contains "$out" "Onarım" "status [${how}]: 'fm-root --apply' ONARIMI önermez"
    assert_not_contains "$out" "srvctl domain fm-root example.com --apply" "status [${how}]: 'srvctl domain fm-root example.com --apply' komutu HİÇ önerilmez (STALE yenileme önerisi dahil)"
    assert_eq "$(( rc != 0 ))" "1" "status [${how}]: rc≠0 (kayıt 'on' ama disk kapalı: eşitlenmemiş)"
done

echo "── C6d: kayıt 'on' + eski kök + 90/21 yok + işaret yok → 8 yolun hiçbiri alanı AÇMAZ ──"
c6d() {   # c6d <kök-türü: "legacy" | "ver N"> [yol…]  (varsayılan: 8 yolun hepsi)
    local kind="$1" path tag; shift
    local paths="${*:-fmroot repair83 repair84 fmrootall phpswitch repairall stalebk_fmroot stalebk_repair}"
    for path in $paths; do
        tag="${kind} / ${path}"
        # shellcheck disable=SC2086
        _fm_reset; _on
        case "$path" in stalebk_*) _mk_stale_bk AAAAAA ;; esac
        case "$kind" in legacy) legacy_root > "$F20" ;; ver*) off_ver "${kind#ver }" > "$F20" ;; esac
        chmod 644 "$F20"; rm -f "$F90" "$F21"; fm_sim_reload
        case "$path" in
            fmroot|stalebk_fmroot) _fmroot ;;
            repair83) _repair 8.3 ;;
            repair84|stalebk_repair) _repair 8.4 ;;
            fmrootall) _fmroot_all ;;
            phpswitch) _phpswitch ;;
            repairall) _batch ;;
        esac
        assert_eq "$(_sh)|$(_run)" "SHUT|RUN-CLOSED" "C6d [${tag}]: alan AÇILMADI (F7: 8/8 yol 90/21+AÇIK yazdı)"
        assert_eq "$(_tamp)" "0" "C6d [${tag}]: srvctl'in KENDİ eski kökü .srvctl-tampered olarak saklanmadı"
    done
}
c6d legacy
c6d "ver 1" fmroot repair84 fmrootall stalebk_repair
c6d "ver 99" fmroot repair84 phpswitch
# kontrol: AÇIK yazan tek yol açık 'fm-auth on'
mk_state legacy
_on; rc=$?
assert_eq "$rc|$(_exists "$F90")$(_exists "$F21")|$(_st)|$(_run)" "0|varvar|on|RUN-OPEN" "C6d kontrol: açık 'fm-auth on' kanıtlı alanı yeniden AÇAR (tek yol)"
# kontrol: kanıt YOKSA (yabancı 403-benzeri kök): F9b (§15/33) — fm-root onarımı AÇMAZ (F8/F9: AÇARDI); 403 kökü yazılır, yabancı kök adli kopyalanır
mk_state text 'location = /_fm { return 403; }' 'location ^~ /_fm/ { return 403; }' 'proxy_pass http://127.0.0.1:9;'
_fmroot
assert_eq "$(_exists "$F90")$(_exists "$F21")|$(_tamp)|$(_st)|$(_run)" "yokyok|1|off|RUN-CLOSED" "C6d kontrol: HASMANE (ek direktifli) yabancı kök → F9b (§15/33): alan AÇILMAZ (F8: kök kayda göre yeniden üretilir, 90/21+AÇIK yazılırdı), 403 kökü yazıldı, kayıt off, yabancı içerik .srvctl-tampered"

echo "── M1-d: kanıtlı alanda 'off' kökü güncel imzaya yeniler, kaydı eşitler ──"
mk_state legacy
_e; rc=$?
assert_eq "$rc|$(_st)|$(cat "$F20")" "0|off|$(_domconf_fm_render_off example_com)" "off: rc 0, kayıt 'off', 20 = güncel imzalı render_off"
mk_state ver 99
_e --emergency; rc=$?
assert_eq "$rc|$(cat "$F20")" "0|$(_domconf_fm_render_off example_com)" "acil kapatma: gelecek imzalı kök GÜNCEL imzayla yenilendi (sonda yalnız güncel imzayı tanır)"
assert_eq "$(_run)" "RUN-CLOSED" "acil kapatma sonrası çalışan KAPALI"

test_summary
