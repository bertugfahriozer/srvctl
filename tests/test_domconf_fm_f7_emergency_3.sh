#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F7/a1 (QL7 H1, H2, H3, M2, M4, L1, L4, L5, L11-işaret) — ACİL KAPATMA İŞARETİ, KİLİT AŞAMASI ve ÇALIŞAN DURUM. — parça 3/3: H2 … D01/D02 (çalışan durum, L1, L5, L4, M4, ileti)
#  H3  işaret diske dokunmadan ÖNCE yazılır; kayıt dizini güvenilmezse ikinci güvenilir konuma; hiçbir yer güvenilir
#      değilse rc 6; "kayıt on + diskte yalnız srvctl 403 kökü" KAPALI kanıtıdır (fm-root/repair/php-switch AÇMAZ)
#  M2  güvenilmez kayıt dizininde HİÇBİR yazım yok (mktemp/printf/chmod/mv)
#  H1  kilit aşaması BEKLER (üst sınır, süre dolunca rc 4); _domconf_fm_tx_commit işaret varken 'on' yazmaz ve işareti
#      yalnız açık 'on' / 'off' kaydı siler; q1 / q1b NEDEN testleri
#  H2  normal 'off' çalışan durumu sınar: AÇIK → acil yol rc 3, KAPALI → rc 0, doğrulanamadı → rc 4
#  L1  acil yolda 'doğrulanamadı' ASLA rc 0 değil
#  L4  *.srvctl-emergency.* görünürlük/eşik, ad çakışmasında adli kopya, fazladan .srvctl-tampered yok
#  L5  rc≠0 dallarında çalışan durum açıkça söylenir; D01 ileti ayrımı
#  M4  domain remove önek komşusunun yedeklerini silmez
#  L11 işaret: sarkan bağ, kayıtsız alanda işaret yok, mod 0600 (umask 000 altında)
# Flock taklidi GERÇEK flock gibi bekler: FLOCK_HELD dosyası varken `-w N` N sn bekler, sonra rc 1.
# NOT: `nohup … &` SIGINT'i yok saydırır → testi ön planda koşun.
# Eski tek dosya (604 satır, 184 doğrulama; yüklü makinede 333 sn) 3 bağımsız dosyaya bölündü; hiçbir doğrulama silinmedi ya da gevşetilmedi.
# Ortak düzenek: tests/fm_f7_emergency_common.sh. Parçalar: (ad yok) H3-1 … H3-6, _2 H1, _3 H2 … D01/D02.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_MOCK_CURL=1
FM_PROBE_MODE_DEFAULT=sim
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domconf.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/tests/fm_f7_emergency_common.sh"
# Özgün em_disable işlevi (eski tek dosyada H3-1 bölümünde yakalanırdı); L5 bölümü onu geri koymak için kullanır:
eval "_orig__em_disable() $(declare -f _domconf_fm_em_disable | sed 1d)"
echo "── H2: normal 'off' çalışan durumu sınar ──"
_fm_reset; _on; : > "$CURL_LOG"
_e; rc=$?
assert_eq "$rc" "0" "H2-1: normal off, sonda KAPALI imzası → rc 0"
assert_not_contains "$(_out)" "ACİL" "H2-1: acil yola düşülmedi"
assert_contains "$(_out)" "kapanış çalışan nginx'te doğrulandı" "H2-1: ileti çalışan durumu söyler"
assert_eq "$(grep -c ALLOW "$CURL_LOG")" "1" "H2-1: normal off sondayı ÇALIŞTIRDI (tek istek, 127.0.0.1)"
assert_eq "$(grep -c DENY "$CURL_LOG")" "0" "H2-1: dışarı istek 0"
# H2-2: sessiz reload hatası (systemctl rc 0 ama çalışan görüntü yenilenmiyor) → normal off AÇIK görür → acil yol rc 3
_sys_normal() {
    systemctl() {
        [[ "$1" == "reload" ]] && { echo r >> "$RELOAD_LOG"; }
        [[ "${SYSTEMCTL_RC:-0}" == "0" ]] || return 1
        [[ "$1" == "reload" ]] && fm_sim_reload
        return 0
    }
}
_sys_silent() { systemctl() { [[ "$1" == "reload" ]] && echo r >> "$RELOAD_LOG"; return 0; }; }
_fm_reset; _on
_sys_silent
_e; rc=$?
assert_eq "$rc" "3" "H2-2: reload rc 0 ama master eski yapılandırmada: normal off rc 3 (rc 0 DEĞİL)"
assert_contains "$(_out)" "FM HÂLÂ AÇIK" "H2-2: 'FM HÂLÂ AÇIK' söylenir"
assert_contains "$(_out)" "reload sessizce uygulanmamış olabilir" "H2-2: normal yolun nedeni söylenir"
assert_contains "$(_out)" "reload başarılı görünüyor ama sonda AÇIK imzası verdi" "H2-2: acil yolun rc 3 iletisi (A04 kolu)"
assert_eq "$(_disk)" "yokyokK" "H2-2: disk KAPALI"
# A04: acil yol, reload ok + sonda 411 → rc 3 (reloadst == ok kolu)
_sys_normal; _fm_reset; _on; _sys_silent
_e --emergency; rc=$?
assert_eq "$rc" "3" "A04: --emergency, reload ok + sonda AÇIK → rc 3"
assert_contains "$(_out)" "reload başarılı görünüyor ama sonda AÇIK imzası verdi" "A04: ileti"
_sys_normal
# A04 (sabit kod): FM_PROBE_MODE=fixed 411 + SYSTEMCTL_RC=0
_fm_reset; _on; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=411; FM_PROBE_CODE_HTTP=411; SYSTEMCTL_RC=0
_e --emergency; rc=$?
assert_eq "$rc" "3" "A04: sabit 411 + reload rc 0 → rc 3"
assert_contains "$(_out)" "reload başarılı görünüyor" "A04: reload ok kolunun iletisi (reload başarısız kolu DEĞİL)"
# H2-3: normal off + doğrulanamadı → rc 4, KAPALI sayılmaz
_fm_reset; FM_PROBE_MODE=unknown; _on
_e; rc=$?
assert_eq "$rc" "4" "H2-3: normal off, sonda doğrulanamadı → rc 4 (rc 0 DEĞİL)"
assert_contains "$(_out)" "DOĞRULANAMADI" "H2-3: ileti"
assert_contains "$(_out)" "KAPALI SAYILMAZ" "H2-3: 'doğrulanamadı' KAPALI sayılmaz"
assert_contains "$(_out)" "FM HÂLÂ AÇIK OLABİLİR" "H2-3: ileti 'açık olabilir' der"
assert_contains "$(_out)" "srvctl-fm-closed" "H2-3: elle sınama komutu imzayı söyler"
assert_eq "$(_disk)|$(_st)" "yokyokK|off" "H2-3: disk ve kayıt yine KAPALI (rc 4 yalnız doğrulanamadığı için)"
# imzasız 403 (sunucu düzeyi 403) → doğrulanamadı → rc 4
_fm_reset; _on; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; FM_PROBE_BODY_HTTPS=""; FM_PROBE_BODY_HTTP=""
_e; rc=$?
assert_eq "$rc" "4" "H2-3: imzasız 403 → doğrulanamadı → rc 4"
# normal off dry: sonda ÇALIŞMAZ
_fm_reset; _on; : > "$CURL_LOG"
_e --dry; rc=$?
assert_eq "$rc|$(grep -c ALLOW "$CURL_LOG")|$(_disk)" "0|0|varvarA" "H2-4: --dry sondayı çalıştırmaz, hiçbir şey yazmaz"

# H2-5: reload sonrası worker'lar henüz yenilenmemiş: ilk sonda 411, ikincisi 403 → settled yeniden dener, acil yola DÜŞMEZ
_fm_reset; _on; : > "$RELOAD_LOG"; : > "$CURL_LOG"   # F9e: `on` artık bir sonda atar; sayım yalnız off'unkini görsün
printf '411\n403\n403\n' > "${FM_STUBS}/seq"
FM_PROBE_MODE=fixed FM_PROBE_SEQ="${FM_STUBS}/seq" SRVCTL_FM_PROBE_RETRY_SLEEP=0 _e; rc=$?
FM_PROBE_MODE=sim
assert_eq "$rc|$(_reloads)" "0|1" "H2-5: ilk sonda 411 (worker yenilenmedi), ikincisi 403 → rc 0, acil yola düşülmedi (tek reload: normal off'unki)"
assert_not_contains "$(_out)" "ACİL" "H2-5: acil yol iletisi yok"
assert_eq "$(grep -c ALLOW "$CURL_LOG")" "2" "H2-5: iki sonda isteği (yeniden deneme)"

echo "── L1: acil yolda doğrulanamadı rc 0 DEĞİL ──"
_fm_reset; _on; FM_PROBE_MODE=unknown
_e --emergency; rc=$?
assert_eq "$rc" "4" "L1: disk kapalı + reload ok + sonda doğrulanamadı → rc 4"
assert_contains "$(_out)" "KAPALI SAYILMAZ" "L1: 'doğrulanamadı' KAPALI sayılmaz"
assert_not_contains "$(_out)" "ACİL KAPATILDI" "L1: 'ACİL KAPATILDI' başarı iletisi BASILMAZ"
assert_eq "$(_disk)" "yokyokK" "L1: disk yine kapalı"
FM_PROBE_MODE=sim

echo "── L5: rc≠0 dallarında çalışan durum açıkça söylenir; D01 ──"
# rc 5: disk kapatılamadı; çalışan 411 yazdırılır
_fm_reset; _on
eval "_orig__atomic_write() $(declare -f _domconf_atomic_write | sed 1d)"
_domconf_atomic_write() { return 1; }
_domconf_fm_em_disable() { return 1; }
_e --emergency; rc=$?
_domconf_atomic_write() { _orig__atomic_write "$@"; }
_domconf_fm_em_disable() { _orig__em_disable "$@"; }
assert_eq "$rc" "5" "L5: disk kapatılamadı → rc 5"
assert_contains "$(_out)" "çalışan durum: AÇIK imzası (411) — FM HÂLÂ AÇIK" "L5: rc 5 iletisi çalışan 411'i ve 'FM HÂLÂ AÇIK'ı söyler"
# rc 4 kısmen
_fm_reset; _on
_domconf_atomic_write() { return 1; }
_e --emergency; rc=$?
_domconf_atomic_write() { _orig__atomic_write "$@"; }
assert_eq "$rc" "4" "L5: disk KISMEN → rc 4"
assert_contains "$(_out)" "çalışan durum:" "L5: KISMEN iletisi çalışan durumu söyler"
# KISMEN + sonda doğrulanamadı: çalışan durum satırı 'KAPALI SAYILMAZ, FM HÂLÂ AÇIK OLABİLİR' der
_fm_reset; _on; FM_PROBE_MODE=unknown
_domconf_atomic_write() { return 1; }
_e --emergency; rc=$?
_domconf_atomic_write() { _orig__atomic_write "$@"; }
FM_PROBE_MODE=sim
assert_eq "$rc" "4" "L5: KISMEN + sonda doğrulanamadı → rc 4"
assert_contains "$(_out)" "çalışan durum: DOĞRULANAMADI — KAPALI SAYILMAZ, FM HÂLÂ AÇIK OLABİLİR" "L5: çalışan durum satırı 'doğrulanamadı = KAPALI sayılmaz' der"
# rc 4 ayrışık: reload başarısız + sonda KAPALI
_fm_reset; _on; _e --emergency; : > "$OUTF"
_fm_reset; _on; FM_PROBE_MODE=fixed; FM_PROBE_CODE_HTTPS=403; FM_PROBE_CODE_HTTP=403; SYSTEMCTL_RC=1
_e --emergency; rc=$?
SYSTEMCTL_RC=0
assert_eq "$rc" "4" "L5: reload başarısız + sonda KAPALI → rc 4 (ayrışık)"
assert_contains "$(_out)" "kapanış DOĞRULANMIŞ SAYILMAZ" "L5: ayrışık iletisi kapanışın doğrulanmadığını söyler"
FM_PROBE_MODE=sim
# D01: kilit altında kapanış TAMAMLANAMADI ('yeniden yapıldı' DENMEZ)
if [[ "$(id -u)" != "0" ]]; then
    _fm_reset; _on; chmod 0555 "$CUR_DIR"
    _e --emergency; rc=$?
    chmod 0755 "$CUR_DIR"
    assert_contains "$(_out)" "kilit altında kapanış yeniden DENENDİ ama TAMAMLANAMADI" "D01: ileti 'TAMAMLANAMADI' (yanıltıcı 'yeniden yapıldı' DEĞİL)"
    assert_not_contains "$(_out)" "YENİDEN yapıldı" "D01: 'YENİDEN yapıldı' denmez"
    assert_eq "$rc" "5" "D01: disk kapatılamadı → rc 5"
    # D01: ilk aşamada kapanamadı (0555), kilit beklerken izin düzeldi → "TAMAMLANDI (ilk aşamada … kalmıştı)", 'arada biri açmıştı' DEĞİL
    _fm_reset; _on; chmod 0555 "$CUR_DIR"; : > "$HELD"
    : > "$FLOCK_LOG"
    ( _wait_flock_call '-w 20 8'; chmod 0755 "$CUR_DIR"; rm -f "$HELD" ) &
    HPID=$!
    ( SRVCTL_FM_EMERGENCY_LOCK_WAIT=20 _domconf_fm_auth example.com off --emergency ) >"$OUTF" 2>&1; rc=$?
    wait "$HPID"; chmod 0755 "$CUR_DIR"
    assert_eq "$rc|$(_disk)|$(_run)" "0|yokyokK|RUN-CLOSED" "D01: ilk aşama yarım, kilit altında tamamlandı → rc 0, disk ve çalışan KAPALI"
    assert_contains "$(_out)" "kilit altında kapanış TAMAMLANDI (ilk aşamada failed kalmıştı)" "D01: ileti 'TAMAMLANDI' (ilk aşamada kalan durum söylenir)"
    assert_not_contains "$(_out)" "arada biri açmıştı" "D01: 'arada biri açmıştı' denmez (kimse açmadı)"
else
    echo "  (root: chmod 0555 etkisiz — D01 ATLANDI)"
fi

echo "── L4: *.srvctl-emergency.* görünürlük, eşik, adli kopya ──"
_fm_reset; _on; _e --emergency
assert_eq "$(_asn)" "2" "L4: acil kapatma 2 artık bıraktı"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "2 adet acil kapatma artığı (*.srvctl-emergency.*)" "L4: status artıkları SAYAR"
assert_not_contains "$out" "SAYI EŞİĞİ" "L4: 2 artık eşiği aşmaz"
out=$(_domconf_fm_root_cmd example.com 2>&1)
assert_contains "$out" "2 adet acil kapatma artığı" "L4: fm-root planı (kuru) artıkları gösterir"
out=$(_domconf_nginx_audit example.com 2>&1)
assert_contains "$out" "BİLGİ: 2 adet acil kapatma artığı" "L4: nginx-audit sayı özeti verir"
for i in 1 2 3 4 5 6 7 8; do : > "${CUR_DIR}/20-srvctl-fm-upload.conf.srvctl-emergency.1.${i}"; done
assert_eq "$(_asn)" "10" "L4: tam eşik sayısı (10 dosya)"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_not_contains "$out" "SAYI EŞİĞİ" "L4: 10 dosya (= eşik) UYARI DEĞİL"
: > "${CUR_DIR}/20-srvctl-fm-upload.conf.srvctl-emergency.1.9"
out=$(_domconf_fm_auth example.com status 2>&1)
assert_contains "$out" "SAYI EŞİĞİ (10) AŞILDI" "L4: 11 dosya eşiği aşar → UYARI"
err=$(_domconf_fm_auth example.com status 2>&1 >/dev/null)
assert_contains "$err" "SAYI EŞİĞİ (10) AŞILDI" "L4: eşik aşımı UYARI (stderr), bilgi (stdout) DEĞİL"
out=$(_domconf_nginx_audit example.com 2>&1)
assert_contains "$out" "UYARI: 11 adet acil kapatma artığı" "L4: nginx-audit eşik uyarısı"
out=$(_domconf_fm_root_cmd example.com --apply 2>&1)
assert_contains "$out" "11 adet acil kapatma artığı" "L4: fm-root --apply artıkları gösterir"
assert_eq "$(_asn)" "11" "L4: hiçbir artık OTOMATİK silinmedi"
# ad çakışması: aside adı önceden var → YENİ ad denenir, eski adli kopya EZİLMEZ/SİLİNMEZ
_fm_reset; _on
RANDOM=4242; r1=$RANDOM; r2=$RANDOM
echo "eski-adli-kopya" > "${F90}.srvctl-emergency.$$.${r1}"
RANDOM=4242
_domconf_fm_em_disable "$F90"; rc=$?
assert_eq "$rc|$(_exists "$F90")" "0|yok" "L4: çakışmada da 90 kaldırıldı"
assert_eq "$(cat "${F90}.srvctl-emergency.$$.${r1}")" "eski-adli-kopya" "L4: çakışan ADLİ KOPYA silinmedi/ezilmedi"
assert_eq "$(_exists "${F90}.srvctl-emergency.$$.${r2}")" "var" "L4: 90 İKİNCİ rastgele ad altında saklandı (yeni ad denendi)"
assert_eq "$(find "$CUR_DIR" -maxdepth 1 -name '90-srvctl-fm-auth.conf.srvctl-emergency.*' | wc -l | tr -d ' ')" "2" "L4: çakışma sonrası İKİ adli kopya var (eski + yeni)"

echo "── M4: domain remove önek komşusunun yedeklerini silmez (R06) ──"
_fm_reset; _on
mkdir -p "${SD}/.superseded.bk.example_com.AAAAAA" "${SD}/.superseded.bk.example_com_tr.BBBBBB" "${SD}/.bk.example_com_tr.CCCCCC" "${SD}/.superseded.bk.example_comx.DDDDDD"
echo own > "${SD}/.superseded.bk.example_com.AAAAAA/f"; echo nb > "${SD}/.superseded.bk.example_com_tr.BBBBBB/f"
_domconf_fm_auth_forget example_com >/dev/null 2>&1
assert_eq "$(_exists "${SD}/.superseded.bk.example_com.AAAAAA")" "yok" "M4: kendi .superseded yedeği silindi"
assert_eq "$(_exists "${SD}/.superseded.bk.example_com_tr.BBBBBB")" "var" "M4: önek komşusu (example_com_tr) .superseded yedeği DURUYOR"
assert_eq "$(_exists "${SD}/.bk.example_com_tr.CCCCCC")" "var" "M4: önek komşusunun .bk yedeği DURUYOR"
assert_eq "$(_exists "${SD}/.superseded.bk.example_comx.DDDDDD")" "var" "M4: harf-önek komşusu (example_comx) DURUYOR"
assert_eq "$(_exists "$MAN")" "yok" "M4: kendi kaydı silindi"
# forget iki konumdaki işareti de siler
_fm_reset; _on; _e --emergency; FLOCK_RC=1; _fm_reset; _on
mkdir -p "$ALT"; chmod 700 "$ALT"; printf 'x\n' > "$AMARK"; printf 'x\n' > "$MARK"
FLOCK_RC=0; _domconf_fm_auth_forget example_com >/dev/null 2>&1
assert_eq "$(_exists "$MARK")$(_exists "$AMARK")" "yokyok" "H1: domain remove iki konumdaki işareti de kaldırır"

echo "── D01/D02 (L11): include iletileri ──"
_fm_reset; _on
printf 'server {\n    include /etc/nginx/custom.d/example_com2/*.conf;\n}\n' > "$VHOST"
out=$(_domconf_fm_auth example.com on "--script=${SCRIPT}" 2>&1); rc=$?
assert_eq "$rc" "1" "L11-D02: yalnız komşunun (example_com2) include'u olan vhost reddedilir"
assert_contains "$out" "custom.d dizinini include ETMİYOR" "L11-D02: ileti"
assert_contains "$out" "include /etc/nginx/custom.d/example_com/*.conf;" "L11-D02: ileti doğru include satırını söyler"
out=$(_domconf_fm_root_cmd example.com 2>&1)
assert_contains "$out" "sonra fm-root'u yeniden çalıştırın" "L11-D01: fm-root planının 'include ETMİYOR' iletisi yeniden çalıştırmayı söyler"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"

test_summary
