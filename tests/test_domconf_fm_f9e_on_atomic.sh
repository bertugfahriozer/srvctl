#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9e/dev — ARCHITECTURE §15/44(b): `fm-auth <alan> on` YARIM KALMAZ. Açan komutun nginx reload'u ya da çalışan-durum sondası başarısız olursa
# disk 403 köküne geri alınır (90/21 kalkar, 20 = srvctl'in 403 kökü), kayıt 'off' yazılır (kayıt-disk tutarlı), rc≠0 ve ileti gerçeği söyler.
# Sonradan koşan repair / toplu repair / fm-root / fm-root --all / provision / php-switch o başarısız açılışı "tamamlayıp" alanı AÇMAZ.
# Eski ağaçta (af7e4ad7): reload hatasında dosyalar+kayıt 'on' commit edilmiş kalırdı (disk AÇIK + kayıt on; "nginx reload başarısız" der, geri almazdı);
# `on` sonrası çalışan-durum sondası HİÇ YOKTU (reload sessizce uygulanmasa da "AÇILDI" denirdi).
# Sonda kararı: YALNIZ KESİN 'closed' (403 + alan imzası) geri aldırır; 'doğrulanamadı' geri ALDIRMAZ (sondası çalışmayan alan açılamaz olurdu).
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
reloads() { grep -c '^r$' "$RELOAD_LOG" 2>/dev/null || true; }
has90_21() { if [[ -e "$F90" || -L "$F90" || -e "$F21" || -L "$F21" ]]; then echo VAR; else echo YOK; fi; }
# tutarlı-KAPALI durumu: disk 403 kökü (20 = render_off, 90/21 yok) + kayıt 'off' + yedek/ayrılmış yedek sızıntısı yok
closed_state() { printf '%s|%s|%s|bk=%s|sup=%s' "$(_shut)" "$(_st)" "$(has90_21)" "$(_bkn)" "$(_supn)"; }
CLOSED="SHUT|off|YOK|bk=0|sup=0"
# başarısız açılıştan SONRA koşan tüm "tamamlayıcı" yollar alanı AÇMAZ
afterwards() {   # <etiket> [norun]: norun = çalışan nginx zaten eski AÇIK yapılandırmada (reload'u düzeltmek operatöre ait; araç yazmadıkça yeniden yüklemez)
    local tag="$1" norun="${2:-}" p rc out
    for p in repair83 repairall fmroot fmrootall provision phpswitch; do
        runpath "$p"; rc=$?; out=$(strip < "$OUTF")
        assert_eq "$(closed_state)" "$CLOSED" "${tag} → ${p}: alan AÇILMADI (disk 403 kökü, kayıt off, 90/21 yok)"
        if [[ -z "$norun" ]]; then assert_not_contains "$(_run)" "RUN-OPEN" "${tag} → ${p}: çalışan nginx de açık değil"; fi
        assert_not_contains "$out" "AÇILDI" "${tag} → ${p}: 'AÇILDI' denmez"
    done
}

# ═══ A. reload BAŞARISIZ (taze alan): geri alınır ═══
reset_all; SYSTEMCTL_RC=1; _on; rc=$?; SYSTEMCTL_RC=0; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "A1: reload hatası → TAM rc 1 (geri alındı; 4 = açıldı/doğrulanamadı DEĞİL)"
assert_eq "$(closed_state)" "$CLOSED" "A2: disk 403 köküne geri alındı, kayıt 'off', 90/21 yok, yedek sızmadı"
assert_contains "$out" "AÇILMADI" "A3: ileti 'AÇILMADI' der"
assert_contains "$out" "GERİ ALINDI" "A3: ileti geri alındığını söyler"
assert_contains "$out" "reload yeniden denendi" "A3: reload'un yeniden denendiğini söyler"
assert_not_contains "$out" "$LOUD" "A4: yeni açılış yüklenemedi → '${LOUD}' DENMEZ (önceki durum açık değildi)"
assert_not_contains "$out" "fm-auth AÇILDI" "A5: 'AÇILDI' denmez"
assert_eq "$(reloads)" "2" "A6: reload iki kez denendi (açan komutun reload'u + geri almanın yeniden denemesi)"
assert_not_contains "$(_run)" "RUN-OPEN" "A7: çalışan nginx açık değil (açılış hiç yüklenmedi)"
afterwards "A reload-hatası"
# yeniden açmak serbest: nginx düzelince açık 'on' alanı açar (geri alma kalıcı bir kilit bırakmaz)
reset_all; SYSTEMCTL_RC=1; _on; SYSTEMCTL_RC=0; _on; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "0|OPEN|on" "A8: nginx düzelince açık 'on' alanı AÇAR (geri alma kalıcı kilit bırakmaz)"

# ═══ B. reload GEÇİCİ başarısız (ilk reload düşer, yeniden deneme başarılı) ═══
orig_systemctl=$(declare -f systemctl)
systemctl() {
    if [[ "$1" == "reload" ]]; then
        echo r >> "$RELOAD_LOG"
        if (( $(grep -c '^r$' "$RELOAD_LOG") <= ${RELOAD_FAIL_FIRST:-0} )); then return 1; fi
        fm_sim_reload
    fi
    return 0
}
reset_all; RELOAD_FAIL_FIRST=1; _on; rc=$?; RELOAD_FAIL_FIRST=0; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "B1: ilk reload düştü → TAM rc 1 (geri alma yeniden yükledi ama açılış yine de AÇILMADI)"
assert_eq "$(closed_state)" "$CLOSED" "B2: kapalı"
assert_contains "$out" "KAPALI imzası (403)" "B3: yeniden yükleme başarılı → çalışan durum KAPALI imzası söylenir"
assert_not_contains "$out" "$LOUD" "B4: '${LOUD}' DENMEZ"
assert_eq "$(_run)" "RUN-CLOSED" "B5: çalışan nginx kapalı"
# B2: alan komuttan ÖNCE AÇIKTI + ilk reload düşer + geri almanın yeniden denemesi BAŞARILI: "Alan komuttan önce AÇIKTI … onu KAPATTI" iletisi
# (prev_state yakalanmazsa bu cümle hiç çıkmaz; C bölümü reload'u hep düşürdüğü için bu dalı görmez)
reset_all; RELOAD_FAIL_FIRST=0; _on; fm_sim_reload
assert_eq "$(_shut)|$(_st)" "OPEN|on" "B2 önkoşul: alan açık"
RELOAD_FAIL_FIRST=2; _on; rc=$?; RELOAD_FAIL_FIRST=0; out=$(strip < "$OUTF")
assert_eq "$rc|$(closed_state)" "1|${CLOSED}" "B2a: açık alanda yeniden 'on' + ilk reload düştü → rc 1, geri alındı (disk 403 kökü, kayıt off)"
assert_contains "$out" "Alan komuttan önce AÇIKTI; bu başarısız yeniden 'on' onu KAPATTI" "B2b: önceki durum 'on' idi → ileti alanın komuttan önce AÇIK olduğunu ve KAPATILDIĞINI söyler"
assert_not_contains "$out" "Yeni açılış nginx'e hiç yüklenmedi" "B2c: önceki durum açıkken 'hiç yüklenmedi' DENMEZ"
# B3: aynı koşul, alan komuttan önce KAPALIYDI → o cümle YOK
reset_all; RELOAD_FAIL_FIRST=1; _on; rc=$?; RELOAD_FAIL_FIRST=0; out=$(strip < "$OUTF")
assert_eq "$rc|$(closed_state)" "1|${CLOSED}" "B3a: kapalı alanda 'on' + ilk reload düştü → rc 1, kapalı"
assert_not_contains "$out" "Alan komuttan önce AÇIKTI" "B3b: önceki durum kapalıyken 'komuttan önce AÇIKTI' DENMEZ"
eval "$orig_systemctl"

# ═══ C. alan komuttan ÖNCE AÇIKTI (başarısız yeniden 'on'): geri alma onu KAPATIR, açık olabileceği söylenir ═══
reset_all; _on; fm_sim_reload
assert_eq "$(_shut)|$(_st)" "OPEN|on" "C önkoşul: alan açık"
SYSTEMCTL_RC=1; _on; rc=$?; SYSTEMCTL_RC=0; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "C1: reload hatası → TAM rc 1"
assert_eq "$(closed_state)" "$CLOSED" "C2: disk 403 köküne, kayıt 'off' (otomatik yol YALNIZ kapatma yönünde)"
assert_contains "$out" "GERİ ALINDI" "C3: geri alındı"
assert_contains "$out" "FM HÂLÂ AÇIK" "C4: çalışan nginx eski AÇIK yapılandırmayı sunuyor → 'FM HÂLÂ AÇIK' (dürüst)"
assert_contains "$out" "AÇIKTI" "C5: alanın komuttan önce açık olduğunu söyler"
afterwards "C önceden-açık" norun

# ═══ D. reload BAŞARILI ama sonda KAPALI imzası: açılış çalışan yapılandırmaya yansımadı → geri alınır ═══
reset_all; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; _on; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc" "1" "D1: reload tamam + sonda KAPALI → TAM rc 1"
assert_eq "$(closed_state)" "$CLOSED" "D2: disk 403 köküne geri alındı, kayıt 'off', 90/21 yok"
assert_contains "$out" "AÇILMADI" "D3: 'AÇILMADI'"
assert_contains "$out" "GERİ ALINDI" "D3: geri alındı"
assert_contains "$out" "KAPALI imzası (403)" "D4: çalışan durumu söyler"
assert_not_contains "$out" "fm-auth AÇILDI" "D5: 'AÇILDI' denmez"
assert_not_contains "$out" "$LOUD" "D6: '${LOUD}' DENMEZ (çalışan nginx kapalı)"
FM_PROBE_MODE=sim
afterwards "D sonda-KAPALI"

# ═══ E. sonda DOĞRULANAMADI (curl yok / bağlantı yok): geri ALINMAZ (sondası çalışmayan alan açılamaz olurdu) ═══
# F9e-3 (§15/47(a)): geri alma YİNE yok, ama sessiz başarı da yok: yüksek sesli ileti + AYRI rc 4 (status'un doğrulanamadı koduyla aynı anlam).
LOGF="${FM_STUBS}/action.log"; log_action() { printf '%s\n' "$*" >> "$LOGF"; }   # fm_env.sh log_action'ı boşaltır; denetim kaydını burada yakala
reset_all; : > "$LOGF"; FM_PROBE_MODE=unknown; _on; rc=$?; out=$(strip < "$OUTF")
assert_contains "$(cat "$LOGF")" "DOMAIN FM-AUTH on: example.com" "E1-log: denetim kaydı yazıldı"
assert_contains "$(cat "$LOGF")" "unverified=rc4" "E1-log: doğrulanamayan açılış denetim kaydında 'unverified=rc4' taşır"
reset_all; FM_PROBE_MODE=unknown; _on; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(_shut)|$(_st)" "4|OPEN|on" "E1: sonda doğrulanamadı → açılış KORUNUR (kayıt on, disk açık) AMA rc 4 (sessiz 0 değil)"
assert_contains "$out" "AÇILDI, canlıda DOĞRULANAMADI (" "E2: ileti 'AÇILDI, canlıda DOĞRULANAMADI (<neden>)'"
assert_contains "$out" "sonda 127.0.0.1" "E2: nedeni (sonda ayrıntısı) parantez içinde söyler"
assert_contains "$out" "GERİ ALINMADI" "E2: geri alınmadığını söyler"
assert_contains "$out" "fm-auth example.com status" "E2: doğrulama komutunu gösterir"
assert_not_contains "$out" "AÇILMADI" "E2: 'AÇILMADI' (geri alma) DENMEZ"
assert_eq "$(reloads)" "1" "E2b: geri alma yok → reload yalnız açan komutun 1 kez"
# status ile AYNI anlam: aynı koşulda status da rc 4
( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; src=$?
assert_eq "$src" "4" "E2c: aynı sonda koşulunda status rc 4 (on'un rc 4'ü ile aynı anlam)"
FM_PROBE_MODE=sim
# sonda AÇIK imzası: normal başarı (rc 0, doğrulanamadı iletisi YOK)
reset_all; _on; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(_shut)|$(_st)" "0|OPEN|on" "E3: sonda AÇIK → rc 0, alan açık, kayıt on"
assert_contains "$out" "fm-auth AÇILDI: example.com" "E3: doğrulanmış başarı iletisi"
assert_not_contains "$out" "DOĞRULANAMADI" "E3: doğrulanmış açılışta 'DOĞRULANAMADI' DENMEZ"
reset_all; : > "$LOGF"; _on >/dev/null 2>&1
assert_not_contains "$(cat "$LOGF")" "unverified=rc4" "E3-log: doğrulanmış açılış denetim kaydında 'unverified=rc4' TAŞIMAZ"
# --dry sondaya girmez: rc 0
reset_all; FM_PROBE_MODE=unknown; _on --dry; rc=$?
assert_eq "$rc|$(_st)" "0|" "E4: --dry yazım/sonda yok → rc 0, kayıt oluşmadı"
FM_PROBE_MODE=sim
# yeniden açma: sonda doğrulanamadı olsa da önceki 'on' alanda rc 4 (kayıt on, disk açık korunur)
reset_all; _on; fm_sim_reload; FM_PROBE_MODE=unknown; _on; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "4|OPEN|on" "E5: zaten açık alanda yeniden 'on' + sonda doğrulanamadı → rc 4, açık korunur"
FM_PROBE_MODE=sim

# ═══ F. acil kapatma işaretli alan: reload hatası → yine kapalı + tutarlı ═══
reset_all; _on; ( _domconf_fm_auth example.com off --emergency ) >/dev/null 2>&1; fm_sim_reload
assert_eq "$(_shut)" "SHUT" "F önkoşul: acil kapatılmış"
SYSTEMCTL_RC=1; _on; rc=$?; SYSTEMCTL_RC=0
assert_eq "${rc}|$(closed_state)" "1|${CLOSED}" "F1: işaretli alanda açık 'on' + reload hatası → kapalı, kayıt off"
afterwards "F acil-işaretli"

# ═══ G. mevcut 'AÇILMADI' dalları bozulmadı ═══
# G1: nginx -t BAŞARISIZ → (mevcut) dosya+kayıt geri alındı, reload YOK
reset_all; NGINX_TEST_RC=1; _on; rc=$?; NGINX_TEST_RC=0; out=$(strip < "$OUTF")
assert_eq "${rc}|$(has90_21)|$(_st)|$(reloads)" "1|YOK||0" "G1: nginx -t hatası: rc≠0, 90/21 yok, kayıt oluşmadı, reload yok"
assert_contains "$out" "nginx -t BAŞARISIZ" "G1: mevcut ileti"
# G2: acil kapatılmış alanı sağlam nginx ile açık 'on' AÇAR (F7-H1 kapıları dokunulmadı)
reset_all; _on; ( _domconf_fm_auth example.com off --emergency ) >/dev/null 2>&1
assert_eq "$(_shut)" "SHUT" "G2 önkoşul"
_on; rc=$?
assert_eq "$rc|$(_shut)|$(_st)" "0|OPEN|on" "G2: açık 'on' (nginx sağlam) acil kapatılmış alanı AÇAR (F7-H1 kapısı bozulmadı)"

# ═══ H. çalışan-durum sondası YENİDEN DENER (reload sonrası worker'lar yenilenene dek KAPALI imzası, sonra AÇIK) ═══
# fm_f9c_common.sh yeniden denemeyi 1'e sabitler; burada varsayılan 3'e açılır. Tek denemeye inen sonda ilk 403'te açılışı GERİ ALIRDI.
SEQF="${FM_STUBS}/probe.seq"
reset_all; SRVCTL_FM_PROBE_RETRIES=3; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403
printf '403\n403\n411\n' > "$SEQF"; FM_PROBE_SEQ="$SEQF"   # her sonda tek HTTPS çağrısı: 1. ve 2. deneme KAPALI, 3. AÇIK
_on; rc=$?; out=$(strip < "$OUTF")
assert_eq "$rc|$(_shut)|$(_st)" "0|OPEN|on" "H1: ilk deneme 403, sonraki AÇIK (411) → yeniden deneme sayesinde açılış KORUNUR (rc 0)"
assert_contains "$out" "fm-auth AÇILDI: example.com" "H1: 'AÇILDI'"
assert_not_contains "$out" "AÇILMADI" "H1: geri alma yok"
# sınır: yeniden deneme SONSUZ DEĞİL — hep 403 ise 3 denemeden sonra geri alınır
reset_all; SRVCTL_FM_PROBE_RETRIES=3; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; unset FM_PROBE_SEQ
: > "$CURL_LOG"; _on; rc=$?
assert_eq "$rc|$(closed_state)" "1|${CLOSED}" "H2: hep KAPALI imzası → deneme bitince geri alınır (rc 1, kapalı)"
n3=$(grep -c '^ALLOW' "$CURL_LOG"); : > "$CURL_LOG"
reset_all; SRVCTL_FM_PROBE_RETRIES=1; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; _on >/dev/null 2>&1
n1=$(grep -c '^ALLOW' "$CURL_LOG")
assert_eq "$((n3 > n1))" "1" "H3: SRVCTL_FM_PROBE_RETRIES=3 → sonda çağrıları (${n3}) =1 olandan (${n1}) FAZLA (ayar gerçekten kullanılıyor)"
export SRVCTL_FM_PROBE_RETRIES=1
FM_PROBE_MODE=sim

test_summary
