#!/bin/bash
# YAPISAL kilit (F9b/b): test/lab düzeneklerinde HAM sinyal, kontrolsüz arka plan ve /tmp yazımı kalmasın.
#  Kök neden notu: tests/harness_safe.sh başlığı. Bu makinede PID sayacı ~1 300/sn -> 99999 PID ~80 sn'de döner; BAYAT bir PID'e `kill`
#  başka sürece (ör. başka ajanın test alt kabuğuna) sinyal demektir (test_domconf_fm_f8_stage H1-2'deki bir kez görülen rc 143).
#  Kurallar (tarayıcı: tests/lib_harness_scan.awk; her kural iki yönlü: önce tarayıcı kendi vakalarıyla denenir):
#   R1  pkill/killall/nohup/disown/setsid HİÇBİR yerde yok.
#   R2  ham `kill` (kill -0 yoklaması hariç): dosya bazlı SABİTLENMİŞ sayı (izin tablosu, gerekçeli); tabloda olmayan dosyada 0.
#       Yeni bir ham kill eklemek bu testi kırar -> tests/harness_safe.sh (hs_kill/hs_kill_group/hs_kill_pidfile/hs_kill_port) kullanılır.
#   R3  `&` ile arka plan: aynı satırda ya da sonraki 2 satırda `hs_track` yoksa izin tablosunda olmalı.
#   R4  `hs_track "$!"` yasak ($! hs_track içinde bozulabilir): `p=$!; hs_track "$p"`.
#   R5  (canlı test takımları live/test/*.sh) ${TMPDIR:-/tmp} yok; mktemp açık "${TMPDIR:?}/…" şablonlu; ilk mktemp'ten ÖNCE hs_tmpdir_init;
#       /tmp /var/tmp sabit yolları yalnız gerekçeli izin tablosunda (veri/ret girdisi, salt-okur başvuru).
#   R6  python düzenekleri: os.kill/killpg/terminate()/kill()/send_signal sabit sayı.
#   R7  tests/harness_safe.sh == live/test/harness-safe.sh (bayt bayt); hs_ kullanan live betiği yardımcıyı source eder.
# Canlı dizin (live/) yoksa R2-R7'nin live kısmı AÇIKÇA ATLANIR (SRVCTL_REQUIRE_LIVE=1 ile FAIL).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
AWK="${REPO_ROOT}/tests/lib_harness_scan.awk"
LIVE="${SRVCTL_LIVE_DIR:-${REPO_ROOT}/../live}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

_scan() { awk -v FILE="$1" -f "$AWK" "$1"; }

echo "── tarayıcı öz-sınaması (kırmızı/yeşil vakalar) ──"
cat > "$W/s.sh" <<'SNIP'
kill "$p"
kill -0 "$p"
echo "kill me"
x && kill -TERM $p
# kill $p
sleep 1 &
a && b
cmd 2>&1
cmd &>/dev/null
( work ) &
cat <<'EOT'
kill $q
sleep 9 &
EOT
pkill -f x
nohup y
echo $(( a & 2 ))
mktemp -d
mktemp -d "${TMPDIR:?}/x.XXXXXX"
d="${TMPDIR:-/tmp}/z"
if x; then kill $p; fi
echo 'kill $p'
v="$(kill $p)"
trap 'kill $p' EXIT
echo hi | xargs kill -9
p="/tmp/yaz"
cmd |& tee
SNIP
OUT="$(_scan "$W/s.sh")"
_has() { printf '%s\n' "$OUT" | grep -q "^$1|s.sh|$2|"; }
exp() { # <kind> <satır> <açıklama>
    assert_eq "$(_has "$1" "$2" && echo VAR || echo yok)" "VAR" "tarayıcı: $3 -> $1"
}
_scan_s() { awk -v FILE=s.sh -f "$AWK" "$W/s.sh"; }; OUT="$(_scan_s)"
exp KILL 1 'ham kill "$p"'
exp KILL 4 '&& kill -TERM'
exp BG 6 'sleep 1 &'
exp BG 10 '( work ) &'
exp PKILL 15 'pkill -f'
exp DETACH 16 'nohup'
exp MKTEMP 18 'şablonsuz mktemp'
exp TMPFALL 20 '${TMPDIR:-/tmp}'
exp KILL 21 'then kill'
exp KILL 23 'komut ikamesi içinde kill'
exp KILL 24 "trap 'kill …'"
exp KILL 25 'xargs kill'
exp TMPLIT 26 'sabit /tmp yolu'
for ln in 2 3 5 7 8 9 12 13 17 19 22 27; do
    assert_eq "$(printf '%s\n' "$OUT" | grep -c "|s.sh|${ln}|")" "0" "tarayıcı: satır ${ln} (kill -0/dizge/yorum/&&/2>&1/&>/heredoc/aritmetik/şablonlu mktemp/tek tırnak/|&) TEMİZ"
done

# izin tablosu: "<dosya-göreli>:<tür>=<sayı>" -> gerekçe. Tabloda olmayan (dosya,tür) için beklenen 0.
declare_allow() { ALLOW_KEYS="${ALLOW_KEYS:-}${1}"$'\n'; }
ALLOW_KEYS=""
# tests/ -- yardımcının kendisi
declare_allow "tests/harness_safe.sh:KILL=5"                    # hs_kill/hs_kill_group/hs_kill_children/hs_signal_ancestor'daki kill + _hs_set_me probe çocuğu: DOĞRULAMADAN SONRA tek gönderim noktaları
declare_allow "tests/harness_safe.sh:BG=1"                      # _hs_set_me: bash 3.2'de kabuk pid'i için geçici `sleep 30 &` (hemen kapatılır, wait edilir)
declare_allow "tests/harness_safe.sh:TMPLIT=1"                  # hs_assert_not_tmp RED LİSTESİ (yazım değil)
# tests/ -- a1 sahipli domconf testleri (F9b/b kapsamı dışı dosyalar; açık iş: harness_safe'e taşınacak)
for pair in test_domconf_fm_auth:2 test_domconf_fm_crash:1 test_domconf_fm_f7_emergency:2 test_domconf_fm_f7_real:4 test_domconf_fm_f8_real:3 \
            test_domconf_fm_f8_stage:1 test_domconf_fm_f9_closure:2 test_domconf_fm_f9_real:1 test_domconf_fm_f9_real_3:1 fm_f9_real_common:2 test_domconf_fm_f9_soft:1 test_domconf_fm_probe_real:1 test_domconf_fm_stale_bk:3; do
    declare_allow "tests/${pair%%:*}.sh:KILL=${pair##*:}"       # öz-sinyal (kanca, test edilen alt kabuğun KENDİ pid'ine: PPID/BASHPID anında yakalanır) ya da lab nginx pid dosyası/holder; sahibi a1
done
declare_allow "tests/test_harness_safe_kill.sh:BG=4"            # BİLİNÇLİ izlenmeyen süreçler: yardımcının REDDETMESİ gereken vakaları (kayıtsız canlı pid, sahte lstart/ppid, grup lideri değil); her biri sonra hs_track + hs_kill ile kapatılır, EXIT'te hs_reap
declare_allow "tests/test_domconf_fm_f7_emergency_2.sh:BG=1"    # kilit tutucu alt kabuğu (H1); test içinde wait'li (a1 sahipli; eski tek dosyada BG=2, bölününce 1+1)
declare_allow "tests/test_domconf_fm_f7_emergency_3.sh:BG=1"    # yarış alt kabuğu (L5/D01); test içinde wait'li (a1 sahipli)
declare_allow "tests/test_domconf_fm_f7_real.sh:BG=2"           # python soket tutucu (PF pid dosyasıyla izlenir; holder_down); a1 sahipli
# live/ -- canlıya DEPLOY edilen betikler (sunucuda koşar; harness-safe.sh dağıtılmaz; mutate.py/stage0-test.sh metne pinli)
for pair in fm-buffer-test:4:3 fm-nginx-test:2:1 fm-stage0-test:4:3 fm-stream-test:2:1 pc-stream-test:1:1; do
    n="${pair%%:*}"; r="${pair#*:}"; k="${r%%:*}"; b="${r##*:}"
    declare_allow "live/${n}.sh:KILL=${k}"                      # yalnız kendi `\$!` çocukları (SAMPLER_PID/CURL_PID/RECV_PID/HELPER_PID); cleanup trap'inde
    declare_allow "live/${n}.sh:BG=${b}"                        # örnekleyici/curl/alıcı: PID değişkenine alınır, cleanup'ta kapatılır
done
declare_allow "live/fm-buffer-test.sh:MKTEMP=2"                 # canlı sunucu betiği: /var/tmp (README-stage0: yerelde koşmaz)
declare_allow "live/fm-buffer-test.sh:TMPLIT=5"
declare_allow "live/fm-nginx-test.sh:MKTEMP=1"
declare_allow "live/fm-nginx-test.sh:TMPLIT=1"
declare_allow "live/fm-stream-test.sh:MKTEMP=1"
declare_allow "live/fm-stream-test.sh:TMPLIT=1"
declare_allow "live/fm-stage0-test.sh:MKTEMP=5"
declare_allow "live/fm-stage0-test.sh:TMPLIT=3"
declare_allow "live/pc-api-test.sh:MKTEMP=1"
declare_allow "live/pc-stream-test.sh:MKTEMP=1"
# live/test -- takım düzenekleri
declare_allow "live/test/harness-safe.sh:KILL=5"
declare_allow "live/test/harness-safe.sh:BG=1"
declare_allow "live/test/harness-safe.sh:TMPLIT=1"
declare_allow "live/test/int-root-guard-test.sh:TMPLIT=1"       # `try "çok kısa (/tmp/x)" "/tmp/x"`: korumanın REDDETMESİ gereken GİRDİ (hiçbir şey yazılmaz)
declare_allow "live/test/integration-srvctl.sh:TMPLIT=2"        # "$ROOT"/var/tmp/fmstage0* : lab kökü İÇİNDEKİ var/tmp (gerçek /var/tmp değil)
declare_allow "live/test/stage0-test.sh:TMPLIT=2"               # `ln -s /tmp …` sembolik-bağ RED vakası (hedef okunur, yazılmaz) + betik metni denetimi ("/var/tmp" sözcüğü)
declare_allow "live/test/stage0-test.sh:MKTEMP=1"               # araç adı listesi (`for t in … mktemp …`), çağrı değil

_allowed() { printf '%s' "$ALLOW_KEYS" | grep -x -F -- "$1:$2=$3" >/dev/null; }

_check_file() {   # <göreli ad> <yol> <türler...>
    local rel="$1" path="$2"; shift 2
    local out kind n
    out="$(_scan "$path" | sed "s#|$path|#|$rel|#")"
    for kind in "$@"; do
        n="$(printf '%s\n' "$out" | grep -c "^${kind}|")"
        if [[ "$n" -eq 0 ]]; then
            # izin tablosunda var ama 0 ise tablo bayat: sıkılaştırılmalı
            if printf '%s' "$ALLOW_KEYS" | grep -q -F -- "${rel}:${kind}="; then
                assert_eq "bayat izin" "temiz" "${rel}: ${kind} izin tablosunda ama artık 0 -> girdiyi SİL (sıkılaştır)"
            fi
            continue
        fi
        if [[ "$kind" == BG ]]; then   # izlenen (hs_track) arka plan satırları sayılmaz
            n=0; local ln
            while IFS='|' read -r _k _f ln _rest; do
                [[ -n "$ln" ]] || continue
                if ! sed -n "${ln},$((ln + 2))p" "$path" | grep -q 'hs_track'; then n=$((n + 1)); fi
            done < <(printf '%s\n' "$out" | grep '^BG|')
            [[ "$n" -eq 0 ]] && continue
        fi
        if _allowed "$rel" "$kind" "$n"; then
            assert_eq "izinli" "izinli" "${rel}: ${kind}=${n} izin tablosuyla EŞİT"
        else
            assert_eq "${kind}=${n}" "izin-tablosunda-yok" "${rel}: ${kind}=${n} izin tablosunda YOK (ham sinyal/izlenmeyen arka plan -> tests/harness_safe.sh kullan)"
        fi
    done
}

echo "── R1-R4: srvctl-fm/tests (kill / & / nohup) ──"
for f in "${REPO_ROOT}"/tests/*.sh; do
    rel="tests/$(basename "$f")"
    case "$rel" in tests/test_harness_no_raw_kill.sh) continue ;; esac
    _check_file "$rel" "$f" KILL PKILL DETACH BG
done
# R4: hs_track "$!" yasak
for f in "${REPO_ROOT}"/tests/*.sh; do
    case "$f" in */test_harness_no_raw_kill.sh) continue ;; esac
    n="$(grep -v '^[[:space:]]*#' "$f" | grep -cE 'hs_track[[:space:]]+"?\$!"?([[:space:];]|$)')"
    [[ "$n" -eq 0 ]] || assert_eq "$n" "0" "R4: $(basename "$f"): hs_track \"\$!\" yasak (p=\$!; hs_track \"\$p\")"
done
assert_eq "$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/tests/run.sh" | grep -o 'hs_kill_group' | wc -l | tr -d ' ')" "3" "run.sh düşüş yolu hs_kill_group kullanır (bekçi TERM+KILL, ana TERM)"
assert_eq "$(_scan "${REPO_ROOT}/tests/run.sh" | grep -c '^KILL')" "0" "run.sh: ham kill YOK (pkill -f ve bayat grup kill'i kapandı)"

echo "── R2-R6: canlı takımlar ──"
if [[ ! -d "$LIVE/test" ]]; then
    if [[ "${SRVCTL_REQUIRE_LIVE:-0}" == "1" ]]; then
        assert_eq "yok" "var" "live dizini bulunamadı: ${LIVE} (SRVCTL_REQUIRE_LIVE=1)"
    else
        echo "  ATLANDI: live dizini yok (${LIVE}); SRVCTL_REQUIRE_LIVE=1 ile FAIL olur"
    fi
else
    for f in "$LIVE"/test/*.sh "$LIVE"/*.sh; do
        [[ -f "$f" ]] || continue
        rel="live/${f#"$LIVE"/}"
        _check_file "$rel" "$f" KILL PKILL DETACH BG
        n="$(grep -v '^[[:space:]]*#' "$f" | grep -cE 'hs_track[[:space:]]+"?\$!"?([[:space:];]|$)')"
        [[ "$n" -eq 0 ]] || assert_eq "$n" "0" "R4: ${rel}: hs_track \"\$!\" yasak"
    done
    # R5: yalnız live/test takım betikleri
    for f in "$LIVE"/test/*.sh; do
        rel="live/test/$(basename "$f")"
        _check_file "$rel" "$f" TMPFALL MKTEMP TMPLIT
        [[ "$(basename "$f")" == harness-safe.sh ]] && continue
        fm="$(grep -n '^[^#]*mktemp' "$f" | grep -v 'for t in' | head -1 | cut -d: -f1)"
        if [[ -n "$fm" ]]; then
            fi_="$(grep -n 'hs_tmpdir_init' "$f" | head -1 | cut -d: -f1)"
            assert_eq "$([[ -n "$fi_" && "$fi_" -lt "$fm" ]] && echo once || echo SONRA-ya-da-yok)" "once" "R5: $(basename "$f"): hs_tmpdir_init (satır ${fi_:-yok}) ilk mktemp'ten (satır ${fm}) ÖNCE"
        fi
        if grep -q 'hs_\(track\|kill\|reap\|tmpdir_init\)' "$f"; then
            assert_eq "$(grep -c '^\. "\${HERE}/harness-safe.sh"' "$f")" "1" "R7: $(basename "$f"): hs_ kullanıyor -> harness-safe.sh source edilir"
        fi
    done
    # R6: python
    for f in "$LIVE"/test/*.py; do
        [[ -f "$f" ]] || continue
        n="$(grep -v '^[[:space:]]*#' "$f" | grep -cE 'os\.kill|killpg|\.terminate\(\)|\.kill\(\)|send_signal')"
        exp_n=0; [[ "$(basename "$f")" == ptydrive.py ]] && exp_n=1   # ptydrive.py: kendi fork'ladığı pty çocuğuna os.kill(pid, 9) (tek)
        assert_eq "$n" "$exp_n" "R6: $(basename "$f"): python sinyal çağrısı sayısı sabit (ptydrive.py=1 gerekçeli, diğerleri 0)"
    done
    # R7: parite
    assert_eq "$(cmp -s "${REPO_ROOT}/tests/harness_safe.sh" "$LIVE/test/harness-safe.sh" && echo ayni || echo FARKLI)" "ayni" "R7: tests/harness_safe.sh == live/test/harness-safe.sh (bayt bayt)"
fi
test_summary
