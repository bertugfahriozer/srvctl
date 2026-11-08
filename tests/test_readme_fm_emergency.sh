#!/bin/bash
# QL6-M1/L1 belge↔kod parite kilidi: README'nin "Acil kapatma" ve ".superseded.bk" bölümlerinde adı geçen, operatörün
# yazacağı/arayacağı HER somut dizge (bayrak, ortam değişkeni, dosya adı, ileti, sonda yolu, çıkış kodu) kodda da
# bulunmalı. Kod değişir ve belge eski kalırsa bu test kırılır. (Davranış testleri domconf tarafında: a1/a2.)
# QL7-M6: dizge araması YORUM SATIRLARINI SAYMAZ (kod gövdesi: tırnak-bilinçli yorum atma, aşağıda); bir ortam
# değişkeninin yalnız yorumda anılması "kodda var" sayılmaz. Ayrıca README'nin vaat ettiği ayarlar (ortam
# değişkenleri) GERÇEK DAVRANIŞLA sınanır: yalnız adın kodda geçmesi, değişkenin okunduğunu kanıtlamaz (QL7 mutantları Q1:
# adı ölü bir atamada bırakıp değeri yok saymak; Q2: değişkeni koddan silip yorumda bırakmak).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
# tırnak-bilinçli yorum atıcı: tam satır yorumu ve tırnak dışı " #..." atılır; '#' tırnak içindeyse korunur.
# Durum her işlev sınırında (sütun 0 '}' ya da 'ad() {') sıfırlanır (çok satırlı tırnaksız metin yayılmasın).
strip_comments() {
    awk '
    { line = $0
      if (line ~ /^(\}|[A-Za-z_][A-Za-z0-9_]*\(\) *\{)/) { sq = 0; dq = 0 }
      out = ""; n = length(line); esc = 0
      for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if (sq) { out = out c; if (c == "\047") sq = 0; continue }
          if (esc) { out = out c; esc = 0; continue }
          if (c == "\\") { out = out c; esc = 1; continue }
          if (dq) { out = out c; if (c == "\"") dq = 0; continue }
          if (c == "\047") { sq = 1; out = out c; continue }
          if (c == "\"") { dq = 1; out = out c; continue }
          if (c == "#") { p = (i == 1) ? " " : substr(line, i - 1, 1); if (p ~ /[ \t;&|(]/) break }
          out = out c
      }
      print out }' "$1"
}
RM="$(cat "${REPO_ROOT}/README.md")"
DC="$(strip_comments "${REPO_ROOT}/lib/domconf.sh")"
# (ön koşul) yorum atıcı çalışıyor: yorumda geçen ama kodda olmayan bir dizge raw'da VAR, kod gövdesinde YOK
BEH_DIR="$(mktemp -d)"; trap 'rm -rf "$BEH_DIR"' EXIT
printf '%s\n' 'x=1  # YORUM_ANAHTARI' "y='a # b'" '# TAM_SATIR_YORUMU' > "${BEH_DIR}/sc.sh"
SC_OUT="$(strip_comments "${BEH_DIR}/sc.sh")"
assert_not_contains "$SC_OUT" "YORUM_ANAHTARI" "(ön koşul) satır sonu yorumu atılır"
assert_not_contains "$SC_OUT" "TAM_SATIR_YORUMU" "(ön koşul) tam satır yorumu atılır"
assert_contains "$SC_OUT" "a # b" "(ön koşul) tırnak içindeki # korunur"
n=0
while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    n=$((n+1))
    assert_contains "$RM" "$tok" "README anıyor: ${tok}"
    assert_contains "$DC" "$tok" "kodda var (YORUM HARİÇ): ${tok}"
done <<'TOKENS'
off --emergency
SRVCTL_FM_EMERGENCY_LOCK_WAIT
SRVCTL_FM_PROBE_HTTPS_PORT
SRVCTL_FM_PROBE_HTTP_PORT
.emergency
srvctl-emergency
FM HÂLÂ AÇIK
FM HÂLÂ AÇIK OLABİLİR
/_fm/up/1/0
SRVCTL_FM_PROBE_RETRIES
SRVCTL_FM_PROBE_RETRY_SLEEP
SRVCTL_FM_OFF_LOCK_WAIT
f5-supersede=1
f6-emergency-off=1
srvctl-fm-closed
srvctl-fm-open
--noproxy
ACİL KAPATMA:
fm-auth ACİL KAPATILDI:
.superseded.bk.
TOKENS
assert_eq "$n" "20" "(ön koşul) 20 dizge sınandı"
# çıkış kodları: README 3/4/5 diyor → acil işlevde rc=3/4/5 atamaları var
EM="$(strip_comments "${REPO_ROOT}/lib/domconf.sh" | awk '/^_domconf_fm_auth_off_emergency\(\)/{f=1} f{print} f&&/^}/{exit}')"
assert_contains "$EM" "_domconf_fm_auth_off_emergency" "(ön koşul) acil işlev gövdesi çıkarıldı"
for c in 3 4 5 6; do assert_contains "$EM" "rc=${c}" "acil işlev rc=${c} döndürüyor (README çıkış kodu tablosu)"; done
# QL7-L1: rc 0'ın TANIMI belgede açık: yalnız KAPALI imzası; rc 4 = doğrulanamadı (kodla aynı: sonda imzasız → 0 DEĞİL)
assert_contains "$RM" 'rc 0 = disk KAPALI + reload tamam + sonda KAPALI imzası verdi' "README rc 0 tanımı: KAPALI imzası şart"
assert_contains "$RM" 'başka hiçbir durum rc 0 değildir' "README: rc 0 yalnız KAPALI imzası"
assert_contains "$RM" '| `0` | disk KAPALI, nginx yeniden yüklendi, sonda `srvctl-fm-closed <sig>` |' "README çıkış kodu tablosu: rc 0 satırı"
assert_contains "$RM" '| `4` | disk KAPALI ama çalışan durum **doğrulanamadı**' "README rc 4 = doğrulanamadı"
assert_contains "$RM" '| `6` | disk KAPALI + çalışan KAPALI, AMA acil işaret hiçbir güvenilir yere **yazılamadı**' "README rc 6 = işaret yazılamadı"
# QL7-c2: sayısal/yol vaatleri README ↔ kod (yorum hariç): kilit bekleme 60/10 sn, kalıntı eşiği 10, ikinci işaret konumu
# QL8-L13: yazım biçimine bağlanmaz (`${VAR:-60}` ya da `_domconf_fm_lock_wait_env VAR 60` ikisi de varsayılan 60'ı taşır)
assert_eq "$(( $(grep -cE 'SRVCTL_FM_EMERGENCY_LOCK_WAIT(:-| )60([^0-9]|$)' <<< "$DC") >= 1 ))" "1" "kod: acil kilit bekleme varsayılanı 60 sn (biçimden bağımsız)"
assert_contains "$RM" 'SRVCTL_FM_EMERGENCY_LOCK_WAIT`, varsayılan **60 sn**' "README: acil kilit bekleme varsayılanı 60 sn"
assert_eq "$(( $(grep -cE 'SRVCTL_FM_OFF_LOCK_WAIT(:-| )10([^0-9]|$)' <<< "$DC") >= 1 ))" "1" "kod: normal off kilit bekleme varsayılanı 10 sn (biçimden bağımsız)"
assert_contains "$RM" '`SRVCTL_FM_OFF_LOCK_WAIT`, 10 sn' "README: normal off kilit bekleme 10 sn"
assert_contains "$DC" '_FME_ASIDE_WARN=10' "kod: *.srvctl-emergency.* uyarı eşiği 10"
assert_contains "$DC" '(( n > _FME_ASIDE_WARN ))' "kod: eşik sıkı '>' (10 bilgi, 11 UYARI)"
assert_contains "$RM" '10 dosyaya kadar bilgi, 11. dosyadan itibaren UYARI' "README: eşik 10 bilgi / 11 UYARI"
alt_dir() { ( set +e; source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1; source "${REPO_ROOT}/lib/domconf.sh" >/dev/null 2>&1
              if [[ "$1" == unset ]]; then unset SRVCTL_FM_EMERGENCY_DIR; else export SRVCTL_FM_EMERGENCY_DIR="$1"; fi
              _fmprov_emergency_alt_dir ) 2>/dev/null; }
assert_eq "$(alt_dir unset)" "/var/lib/srvctl/fm-emergency" "davranış: SRVCTL_FM_EMERGENCY_DIR ayarsızken ikinci işaret konumu = belgedeki yol"
assert_eq "$(alt_dir /x/y)" "/x/y" "davranış: SRVCTL_FM_EMERGENCY_DIR verilirse o yol"
assert_contains "$RM" '${SRVCTL_FM_EMERGENCY_DIR:-/var/lib/srvctl/fm-emergency}/<safe_name>.emergency' "README: ikinci işaret konumu"
assert_contains "$RM" 'rc 6 döner' "README: işaret yazılamazsa rc 6"
assert_not_contains "$RM" 'rc≠0 döner ve' "README: eski belirsiz 'rc≠0' işaret cümlesi yok"
# L1 ".superseded.bk" belge iddiaları: ad biçimi README'de TAM yazılı; "yalnız domain remove siler" kodda doğru
# (silen tek işlev _domconf_fm_superseded_drop, tek çağrı yeri alan-silme temizliği); otomatik silme/tavan yok.
assert_contains "$RM" '.superseded.bk.<safe_name>.XXXXXX' "L1: README ayrılmış yedeğin tam adını yazıyor"
assert_contains "$RM" 'Yalnız `domain remove` siler; otomatik silme/tavan YOKTUR' "L1: README silme politikasını yazıyor"
assert_eq "$(grep -c '_domconf_fm_superseded_drop ' <<< "$DC")" "1" "L1: _domconf_fm_superseded_drop çağrı yeri TEK (alan-silme temizliği; yorum hariç)"
FORGET="$(strip_comments "${REPO_ROOT}/lib/domconf.sh" | awk '/^_domconf_fm_auth_forget_locked\(\)/{f=1} f{print} f&&/^}/{exit}')"
assert_contains "$FORGET" "_domconf_fm_superseded_drop" "L1: tek çağrı yeri _domconf_fm_auth_forget_locked (domain remove)"
# ── QL7-M6 DAVRANIŞ: README'nin vaat ettiği SONDA ayarları gerçekten OKUNUR ──
# Çalışan sonda işlevleri gerçek domconf.sh'tan yüklenir; curl, sleep ve iç sonda bir İŞLEV olarak taklit edilir
# (işlev PATH'ten önce çözülür → hiçbir gerçek ağ isteği YOK; taklit çağrı argümanlarını yazar).
beh() {   # $1 = senaryo kodu; geri kalan: ortam atamaları (env KEY=VAL ...) → sonuç BEH_DIR/out'a
    local mode="$1"; shift
    ( set +e
      source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/domconf.sh" >/dev/null 2>&1
      for kv in "$@"; do declare -x "${kv%%=*}=${kv#*=}"; done
      : > "${BEH_DIR}/calls"; : > "${BEH_DIR}/sleeps"; : > "${BEH_DIR}/seq"; : > "${BEH_DIR}/state"
      case "$mode" in
        curl)   # gerçek sonda; curl taklidi argümanları yazar, 000 döner (hiçbir şema "sonuç" vermez → tüm şemalar denenir)
                curl() { printf '%s\n' "$*" >> "${BEH_DIR}/calls"; printf '000'; return 7; }
                _domconf_fm_runtime_probe "probe.example.invalid" ;;
        sig)    # QL8-L1: sonda yanıtı şemaya göre taklit edilir (gövde imzası + durum kodu). SIG_HTTPS / SIG_HTTP:
                # "real" = bu alanın KAPALI imzası, "foreign" = başka alanın imzası, "none" = imzasız, "open" = AÇIK imzası
                local real
                real="$(_domconf_fm_body_sig "$(safe_name probe.example.invalid)")"
                curl() {
                    local url="${*: -1}" kind
                    printf '%s\n' "$url" >> "${BEH_DIR}/calls"
                    case "$url" in https://*) kind="$SIG_HTTPS" ;; *) kind="$SIG_HTTP" ;; esac
                    case "$kind" in
                        real)    printf 'srvctl-fm-closed %s\n403' "$real" ;;
                        open)    printf 'srvctl-fm-open %s\n411' "$real" ;;
                        foreign) printf 'srvctl-fm-closed 000000000000\n403' ;;
                        s503)    printf '\n503' ;;
                        none)    printf '\n403' ;;
                        *)       printf '000'; return 7 ;;
                    esac
                }
                _domconf_fm_runtime_probe "probe.example.invalid"
                printf '%s' "$_FMRT_STATE" > "${BEH_DIR}/state" ;;
        nocurl) # curl yok: PATH boş dizin (işlev DEĞİL, gerçekten bulunamıyor)
                mkdir -p "${BEH_DIR}/nobin"; export PATH="${BEH_DIR}/nobin"
                _domconf_fm_runtime_probe "probe.example.invalid"
                printf '%s' "$_FMRT_STATE" > "${BEH_DIR}/state" ;;
        settled) # gerçek settled; iç sonda hep "open" (yeniden deneme döngüsünü çalıştırır)
                _domconf_fm_runtime_probe() { echo x >> "${BEH_DIR}/calls"; echo P >> "${BEH_DIR}/seq"; _FMRT_STATE=open; }
                sleep() { echo "$1" >> "${BEH_DIR}/sleeps"; echo "S:$1" >> "${BEH_DIR}/seq"; }
                _domconf_fm_runtime_probe_settled "probe.example.invalid" ;;
      esac ) >/dev/null 2>&1
}
calls() { grep -c . "${BEH_DIR}/calls" 2>/dev/null || true; }
# QL8-L13: davranış SIRASI sınanır (sonda/bekleme dizisi); son denemeden SONRA bir bekleme daha eklemek (N05) davranışı
# bozmaz, yalnız geciktirir → dizinin SONUNDAKİ bekleme yok sayılır. Kilitlenen: her sonda arası tam bir bekleme,
# bekleme süresi ayardan gelir, ilk sondadan ÖNCE bekleme olmaz, deneme sayısı ayardır.
seq_norm() { tr '\n' ' ' < "${BEH_DIR}/seq" | sed -E 's/( S:[0-9]+)+ $//; s/ +$//'; }
beh settled SRVCTL_FM_PROBE_RETRIES=5 SRVCTL_FM_PROBE_RETRY_SLEEP=7
assert_eq "$(calls)" "5" "ayar: SRVCTL_FM_PROBE_RETRIES=5 → 5 sonda denemesi (açık görüldükçe)"
assert_eq "$(seq_norm)" "P S:7 P S:7 P S:7 P S:7 P" "ayar: sonda/bekleme sırası P(S:7 P)×4 — denemeler arası n-1 = 4 bekleme, bekleme süresi RETRY_SLEEP=7"
assert_eq "$(sort -u "${BEH_DIR}/sleeps")" "7" "ayar: SRVCTL_FM_PROBE_RETRY_SLEEP=7 → her bekleme 7 sn"
beh settled SRVCTL_FM_PROBE_RETRIES=2
assert_eq "$(calls)" "2" "ayar: SRVCTL_FM_PROBE_RETRIES=2 → 2 sonda denemesi (Q1: sabit 3 olurdu)"
beh settled SRVCTL_FM_PROBE_RETRIES=abc
assert_eq "$(calls)" "3" "ayar: geçersiz SRVCTL_FM_PROBE_RETRIES → varsayılan 3 (belgedeki varsayılan)"
# QL8-L13/D1: README'nin yazdığı VARSAYILANLAR gerçek varsayılanla aynı (ayarsız koşum: 3 deneme, 1 sn bekleme)
beh settled
assert_eq "$(seq_norm)" "P S:1 P S:1 P" "varsayılan (ayarsız): 3 sonda, aralarda 1 sn bekleme"
assert_contains "$RM" 'SRVCTL_FM_PROBE_RETRIES` (3)' "D1: README varsayılan deneme sayısı 3 (davranışla eşit)"
assert_contains "$RM" 'SRVCTL_FM_PROBE_RETRY_SLEEP` (1 sn' "D1: README varsayılan bekleme 1 sn (davranışla eşit)"
beh settled SRVCTL_FM_PROBE_RETRIES=1
assert_eq "$(calls)" "1" "ayar: SRVCTL_FM_PROBE_RETRIES=1 → tek sonda, bekleme yok"
assert_eq "$(seq_norm)" "P" "ayar: tek denemede ilk sondadan ÖNCE/arada bekleme yok (yalnız P)"
beh curl SRVCTL_FM_PROBE_HTTPS_PORT=18123 SRVCTL_FM_PROBE_HTTP_PORT=18124
assert_contains "$(cat "${BEH_DIR}/calls")" "--resolve probe.example.invalid:18123:127.0.0.1" "ayar: SRVCTL_FM_PROBE_HTTPS_PORT sonda --resolve'una girer"
assert_contains "$(cat "${BEH_DIR}/calls")" "--resolve probe.example.invalid:18124:127.0.0.1" "ayar: SRVCTL_FM_PROBE_HTTP_PORT sonda --resolve'una girer (Q2: 80 olurdu)"
assert_not_contains "$(cat "${BEH_DIR}/calls")" ":443:" "ayar: HTTPS_PORT verilince 443'e gidilmez"
assert_not_contains "$(cat "${BEH_DIR}/calls")" ":80:" "ayar: HTTP_PORT verilince 80'e gidilmez"
beh curl SRVCTL_FM_PROBE_HTTPS_PORT=18123 SRVCTL_FM_PROBE_HTTP_PORT=off
assert_eq "$(calls)" "1" "ayar: SRVCTL_FM_PROBE_HTTP_PORT=off → http şeması atlanır (yalnız https denenir)"
assert_contains "$(cat "${BEH_DIR}/calls")" "https://probe.example.invalid:18123/" "ayar: tek deneme https"
beh curl SRVCTL_FM_PROBE_HTTPS_PORT=off SRVCTL_FM_PROBE_HTTP_PORT=off
assert_eq "$(calls)" "0" "ayar: iki şema da off → curl HİÇ çağrılmaz"
beh curl SRVCTL_FM_PROBE_HTTPS_PORT=0 SRVCTL_FM_PROBE_HTTP_PORT=abc
assert_eq "$(calls)" "0" "ayar: port 0 ya da sayısal olmayan değer geçersiz → o şema atlanır (curl çağrılmaz)"
# ── QL8-L1: "SSL'siz alan → normal off rc 4" iddiası YANLIŞTI; belge ve gerçek sonda davranışı ──
assert_not_contains "$RM" "SSL'siz alanın 443'te başka vhost'a düşmesi" "L1: README'de yanlış 'SSL'siz alan → doğrulanamadı' gerekçesi YOK"
assert_contains "$RM" "SSL'siz alan rc 4 sebebi DEĞİLDİR" "L1: README SSL'siz alanın rc 4 sebebi olmadığını söylüyor"
assert_contains "$RM" "askıya alınmış alan" "L1: README gerçek kör noktayı anıyor (askı → sunucu düzeyi 503)"
beh sig SIG_HTTPS=foreign SIG_HTTP=real
assert_eq "$(cat "${BEH_DIR}/state")" "closed" "L1 davranış: 443'te yabancı imza + :80'de KAPALI imzası → KAPALI (SSL'siz alan rc 4 vermez)"
assert_eq "$(grep -c . "${BEH_DIR}/calls")" "2" "L1 davranış: yabancı imzada sonda :80'e GEÇTİ (iki istek)"
beh sig SIG_HTTPS=foreign SIG_HTTP=foreign
assert_eq "$(cat "${BEH_DIR}/state")" "unknown" "L1 kör nokta: iki şemada da yabancı imza → doğrulanamadı"
beh sig SIG_HTTPS=s503 SIG_HTTP=s503
assert_eq "$(cat "${BEH_DIR}/state")" "unknown" "L1 kör nokta: sunucu düzeyi 503 (askıdaki alan) → doğrulanamadı"
beh sig SIG_HTTPS=none SIG_HTTP=none
assert_eq "$(cat "${BEH_DIR}/state")" "unknown" "L1 kör nokta: imzasız 403 (IP/basic-auth/UA/WAF/v1 şablon) → doğrulanamadı"
beh sig SIG_HTTPS=none SIG_HTTP=open
assert_eq "$(cat "${BEH_DIR}/state")" "open" "L1 kontrol: :80'de AÇIK imzası → AÇIK (kör nokta AÇIK'ı gizlemez)"
beh sig SIG_HTTPS=down SIG_HTTP=down
assert_eq "$(cat "${BEH_DIR}/state")" "unknown" "L1 kör nokta: iki portta da bağlanılamıyor → doğrulanamadı"
beh nocurl
assert_eq "$(cat "${BEH_DIR}/state")" "unknown" "L1 kör nokta: curl yok → doğrulanamadı"
# ── QL8-L4: status çıkış kodu sözleşmesi belgede (kod tarafı: domconf testleri) ──
assert_contains "$RM" '`status` çıkış kodu:**' "L4: README status çıkış kodu sözleşmesini anlatıyor"
assert_contains "$RM" 'Sonda KÖR ise (çalışan durum "doğrulanamadı") `rc 4`' "L4: sonda kör → status rc 4"
assert_contains "$RM" '"FM HÂLÂ AÇIK" (kayıt/disk KAPALI ama sonda AÇIK imzası) `rc 1` kalır' "L4: FM HÂLÂ AÇIK status rc 1"
assert_contains "$RM" 'Sonda-kör alan ve karar kuralı:**' "L4: README sonda-kör alan karar kuralını içeriyor"
assert_contains "$RM" "f7-sig=1" "M4: README caps listesi f7-sig"
assert_contains "$RM" "f8-closed-evidence=1" "M4: README caps listesi f8-closed-evidence"
# ── QL8-L5: ikinci konum dizini kurulum/init/self-update'te hazırlanır — belge ↔ kod ──
assert_contains "$RM" "İkinci konum dizini önceden hazırlanır:**" "L5: README dizin hazırlığını anlatıyor"
for f in install.sh lib/init.sh lib/selfupdate.sh; do
    assert_contains "$RM" "$(basename "$f" .sh)" "(ön koşul) README ${f} yolunu anıyor"
    assert_contains "$(strip_comments "${REPO_ROOT}/${f}")" "_domconf_fm_em_state_dir_prepare" "L5: ${f} kodunda (yorum hariç) hazırlık işlevi çağrılıyor"
done
# ── QL7-L2: "nginx -t düşerse reload DENENMEZ" — belge ve kod AYNI şeyi söylesin (eski belge "reload denenir" diyordu) ──
assert_not_contains "$RM" 'düşse de reload denenir' "L2: README'de yanlış 'nginx -t düşse de reload denenir' cümlesi YOK"
assert_contains "$RM" 'reload' "(ön koşul) README reload'dan söz ediyor"
assert_contains "$RM" 'DENENMEZ' "L2: README 'nginx -t düşerse reload DENENMEZ' diyor"
em_reload() {   # $1 = nginx -t sonucu (0|1) → "RELOAD=<durum> SYSTEMCTL_CAGRI=<n>"
    ( set +e
      source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
      source "${REPO_ROOT}/lib/domconf.sh" >/dev/null 2>&1
      : > "${BEH_DIR}/sysctl"
      nginx() { return "$NGXT_RC"; }
      systemctl() { echo "$*" >> "${BEH_DIR}/sysctl"; return 0; }
      export NGXT_RC="$1"
      _domconf_fm_em_reload
      echo "RELOAD=${_FME_RELOAD} SYSTEMCTL_CAGRI=$(grep -c . "${BEH_DIR}/sysctl")" ) 2>/dev/null
}
assert_eq "$(em_reload 1)" "RELOAD=invalid SYSTEMCTL_CAGRI=0" "L2 davranış: nginx -t BAŞARISIZ → reload denenmez (systemctl çağrısı 0), durum 'invalid'"
assert_eq "$(em_reload 0)" "RELOAD=ok SYSTEMCTL_CAGRI=1" "L2 davranış: nginx -t geçerli → reload edilir (kontrol hücresi)"
test_summary
