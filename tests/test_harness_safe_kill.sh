#!/bin/bash
# tests/harness_safe.sh DAVRANIŞ testi (F9b/b): güvenli-kill yalnız kendi + hâlâ-aynı süreçlere sinyal gönderir;
# shellcheck disable=SC2034  # HS_REG/HS_T0_EPOCH harness_safe.sh (source edilen) tarafından okunur
# PID yeniden kullanımını (lstart/ppid), bayat pid dosyasını, yanlış adı, geçersiz PID'i reddeder; TMPDIR /tmp'ye alınmaz.
# Bu testin kendisi ham `kill` KULLANMAZ (yapısal test: test_harness_no_raw_kill.sh).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/tests/harness_safe.sh"
W="$(mktemp -d)"
trap 'hs_reap KILL; rm -rf "$W"' EXIT

echo "── hs_track / hs_kill: kendi çocuğumuz ──"
sleep 60 & P1=$!; hs_track "$P1"; assert_eq "$?" "0" "çocuk izlendi (rc 0)"
assert_eq "$(hs_owned "$P1" >/dev/null 2>&1; echo $?)" "0" "izlenen çocuk hs_owned"
hs_kill TERM "$P1"; assert_eq "$?" "0" "izlenen çocuğa TERM gönderildi (rc 0)"
wait "$P1" 2>/dev/null; assert_eq "$?" "143" "çocuk TERM ile öldü (143)"

echo "── izlenmeyen canlı süreç REDDEDİLİR ──"
sleep 60 & P2=$!
err="$(hs_kill TERM "$P2" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "3" "kayıtsız canlı pid: rc 3"
assert_contains "$err" "REDDEDİLDİ" "ileti: REDDEDİLDİ"
assert_eq "$(_hs_alive "$P2" >/dev/null 2>&1; echo $?)" "0" "kayıtsız süreç hâlâ canlı (sinyal gitmedi)"
hs_track "$P2"; hs_kill TERM "$P2"; wait "$P2" 2>/dev/null

echo "── PID yeniden kullanımı benzetimi: kayıttaki lstart/ppid ≠ gerçek ──"
sleep 60 & P3=$!; hs_track "$P3"
REAL_LS="$(_hs_lstart "$P3")"; REAL_PP="$(_hs_ppid "$P3")"
HS_REG="${P3}|c|${REAL_PP}|Mon Jan  1 00:00:00 2001"$'\n'
hs_kill TERM "$P3" 2>/dev/null; assert_eq "$?" "3" "lstart uyuşmuyor (PID başka sürece geçmiş) -> REDDEDİLDİ"
assert_eq "$(_hs_alive "$P3" && echo canli || echo olu)" "canli" "lstart uyuşmayan süreç hâlâ canlı (sinyal gitmedi)"
HS_REG="${P3}|c|1|${REAL_LS}"$'\n'      # lstart DOĞRU, ebeveyn farklı (yeniden ebeveynlenmiş/başkasının süreci)
hs_kill TERM "$P3" 2>/dev/null; assert_eq "$?" "3" "ppid uyuşmuyor (lstart doğru) -> REDDEDİLDİ"
assert_eq "$(_hs_alive "$P3" && echo canli || echo olu)" "canli" "ppid uyuşmayan süreç hâlâ canlı"
HS_REG="${P3}|c|${REAL_PP}|${REAL_LS}"$'\n'   # doğru kayıt: kapatılır
hs_kill TERM "$P3"; assert_eq "$?" "0" "doğru kayıtla kapatılır"; wait "$P3" 2>/dev/null
HS_REG="1|d|0|$(_hs_lstart 1)"$'\n'
hs_kill 0 1 2>/dev/null; assert_eq "$?" "3" "pid 1 KAYITLI ve lstart doğru olsa bile REDDEDİLİR (init'e asla)"
HS_REG=""

echo '── alt kabukta (komut ikamesi ve ( ... )) izleme: HS_ME gerçek pid ──'
out="$( sleep 60 & q=$!; hs_track "$q"; r1=$?; hs_kill TERM "$q"; r2=$?; wait "$q" 2>/dev/null; echo "$r1|$r2|$?" )"
assert_eq "$out" "0|0|143" "\$(...) içinde başlatılan çocuk izlenir ve kapatılır (bash 3.2: BASHPID yok -> ps ile)"
( sleep 60 & q=$!; hs_track "$q"; echo "$?" > "$W/sub.rc"; hs_kill TERM "$q"; wait "$q" 2>/dev/null )
assert_eq "$(cat "$W/sub.rc")" "0" "( ... ) alt kabuğunda izleme çalışır"

echo "── çocuk olmayan süreç izlenmez ──"
O="$( ( sleep 60 >/dev/null 2>&1 & echo $! ) )"
sleep 0.3
hs_track "$O" 2>/dev/null; assert_eq "$?" "3" "torun/yetim (ppid ≠ biz) izlenemez (rc 3)"
hs_kill TERM "$O" 2>/dev/null; assert_eq "$?" "3" "izlenemeyen torun öldürülemez"
assert_eq "$(_hs_alive "$O" >/dev/null 2>&1; echo $?)" "0" "yetim hâlâ canlı"

echo "── ölü / geçersiz PID ──"
sleep 0.1 & P4=$!; wait "$P4"
hs_kill TERM "$P4"; assert_eq "$?" "0" "zaten ölü pid: rc 0 (yapacak iş yok)"
for bad in "" 0 1 -1 abc "1 2" "9;id"; do
    hs_kill TERM "$bad" 2>/dev/null; assert_eq "$?" "3" "geçersiz pid '${bad}' REDDEDİLİR"
done
sleep 60 & E1=$!; hs_track "$E1"
hs_kill "" "$E1" 2>/dev/null; assert_eq "$?" "3" "sinyalsiz çağrı (izlenen çocukta bile) REDDEDİLİR"
assert_eq "$(_hs_alive "$E1" && echo canli || echo olu)" "canli" "sinyalsiz çağrıda süreç hâlâ canlı"
hs_kill TERM "$E1"; wait "$E1" 2>/dev/null

echo "── hs_kill_group: yalnız izlenen grup lideri ──"
set -m; sleep 60 & G1=$!; set +m
hs_track "$G1"; assert_eq "$(_hs_pgid "$G1")" "$G1" "ön koşul: set -m çocuğu kendi grubunun lideri"
hs_kill_group TERM "$G1"; assert_eq "$?" "0" "grup lideri: grup kapatıldı"; wait "$G1" 2>/dev/null
sleep 60 & G2=$!; hs_track "$G2"
hs_kill_group TERM "$G2" 2>/dev/null; assert_eq "$?" "3" "grup lideri DEĞİL (aynı grup): REDDEDİLİR (kendi grubumuzu vurmaz)"
assert_eq "$(_hs_alive "$G2" >/dev/null 2>&1; echo $?)" "0" "lider olmayan hâlâ canlı"
hs_kill TERM "$G2"; wait "$G2" 2>/dev/null

echo "── hs_kill_pidfile: ad + koşu-sonrası denetimi ──"
sleep 60 & D1=$!; hs_track "$D1"; echo "$D1" > "$W/d1.pid"
hs_kill_pidfile TERM "$W/d1.pid" 'nginx|php-fpm' 2>/dev/null; assert_eq "$?" "3" "ad uymuyor (sleep ≠ nginx): REDDEDİLİR"
assert_eq "$(_hs_alive "$D1" >/dev/null 2>&1; echo $?)" "0" "yanlış adlı hâlâ canlı"
T0_SAVE="$HS_T0_EPOCH"; HS_T0_EPOCH=$(( $(date +%s) + 1000 ))
hs_kill_pidfile TERM "$W/d1.pid" 'sleep' 2>/dev/null; assert_eq "$?" "3" "süreç koşudan ÖNCE başlamış (bayat PID): REDDEDİLİR"
HS_T0_EPOCH="$T0_SAVE"
echo "1" > "$W/bad.pid"; hs_kill_pidfile TERM "$W/bad.pid" 'sleep' 2>/dev/null; assert_eq "$?" "3" "pid 1 içeren dosya REDDEDİLİR"
echo "999999999" > "$W/none.pid"; hs_kill_pidfile TERM "$W/none.pid" 'sleep' 2>/dev/null; assert_eq "$?" "0" "var olmayan (uç) pid: yapacak iş yok (rc 0), sinyal gitmez"
printf 'abc\n' > "$W/bad2.pid"; hs_kill_pidfile TERM "$W/bad2.pid" 'sleep' 2>/dev/null; assert_eq "$?" "3" "sayı olmayan pid dosyası REDDEDİLİR"
hs_kill_pidfile TERM "$W/yok.pid" 'sleep'; assert_eq "$?" "0" "olmayan pid dosyası: yapacak iş yok (rc 0)"
: > "$W/empty.pid"; hs_kill_pidfile TERM "$W/empty.pid" 'sleep' 2>"$W/empty.err"; assert_eq "$?|$(wc -c < "$W/empty.err" | tr -d ' ')" "0|0" "boş pid dosyası: sessizce rc 0 (gürültü yok)"
hs_kill_pidfile TERM "$W/d1.pid" 'sleep'; assert_eq "$?" "0" "doğru ad + koşu sonrası başlamış: kapatıldı"
wait "$D1" 2>/dev/null; assert_eq "$?" "143" "pid dosyasındaki süreç TERM aldı"

echo "── hs_kill_port: ad + lab kanıtı ──"
PYL='import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1)
open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(60)  # TAG-HSKP'
python3 -I -c "$PYL" "$W/port1" & L1=$!
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [[ -s "$W/port1" ]] && break; sleep 0.1; done
PORT1="$(cat "$W/port1")"
hs_kill_port TERM "$PORT1" 'nginx|php-fpm' 'TAG-HSKP' 2>/dev/null; assert_eq "$?" "3" "ad uymuyor (python ≠ nginx): REDDEDİLİR"
assert_eq "$(_hs_alive "$L1" >/dev/null 2>&1; echo $?)" "0" "port sahibi hâlâ canlı"
hs_kill_port TERM "$PORT1" 'python3?|Python' 'LAB-YOK-ZZ' 2>/dev/null; assert_eq "$?" "3" "lab kanıtı yok (komutta needle yok, ebeveyn 1/izlenen değil): REDDEDİLİR"
assert_eq "$(_hs_alive "$L1" >/dev/null 2>&1; echo $?)" "0" "kanıtsız port sahibi hâlâ canlı"
hs_kill_port TERM "$PORT1" 'python3?|Python' 'TAG-HSKP'; assert_eq "$?" "0" "ad uyar + komutta needle: kapatıldı"
wait "$L1" 2>/dev/null; assert_eq "$?" "143" "port sahibi TERM aldı"
python3 -I -c "$PYL" "$W/port2" & L2=$!; hs_track "$L2"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [[ -s "$W/port2" ]] && break; sleep 0.1; done
hs_kill_port TERM "$(cat "$W/port2")" 'python3?|Python' 'LAB-YOK-ZZ'; assert_eq "$?" "0" "izlenen çocuk (kendi başlattığımız) needle'sız da kapatılır"
wait "$L2" 2>/dev/null

echo "── gerçek nginx: yeniden başlıklanan süreç adı (macOS comm='nginx: master pr') ──"
NGB="${SRVCTL_TEST_NGINX:-$(command -v nginx 2>/dev/null || true)}"
if [[ -n "$NGB" && -x "$NGB" ]]; then
    mkdir -p "$W/ng/logs"
    NP="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    printf 'pid %s/ng/n.pid;\nerror_log %s/ng/logs/e.log;\nevents { worker_connections 8; }\nhttp { access_log off; server { listen 127.0.0.1:%s; return 204; } }\n' "$W" "$W" "$NP" > "$W/ng/nginx.conf"
    "$NGB" -c "$W/ng/nginx.conf" -p "$W/ng"; sleep 0.5
    NPID="$(cat "$W/ng/n.pid" 2>/dev/null)"
    assert_eq "$(_hs_comm "$NPID")" "nginx" "ad normalleştirme: nginx ana süreci -> 'nginx'"
    hs_kill_pidfile TERM "$W/ng/n.pid" 'php-fpm' 2>/dev/null; assert_eq "$?" "3" "nginx pid dosyası, php-fpm deseniyle REDDEDİLİR"
    assert_eq "$(_hs_alive "$NPID" && echo canli || echo olu)" "canli" "reddedilen nginx hâlâ canlı"
    hs_kill_pidfile TERM "$W/ng/n.pid" 'nginx'; assert_eq "$?" "0" "doğru desenle nginx ana süreci kapatıldı"
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do _hs_alive "$NPID" || break; sleep 0.2; done
    assert_eq "$(_hs_alive "$NPID" && echo canli || echo olu)" "olu" "nginx ana süreci gerçekten öldü"
else
    echo "  ATLANDI: gerçek nginx yok (SRVCTL_TEST_NGINX=<ikili>)"
fi

echo "── hs_kill_children: yalnız izlenen ebeveynin çocukları ──"
bash -c 'sleep 60 & sleep 60 & wait' & CP=$!; hs_track "$CP"; sleep 0.5
kids="$(ps -axo pid=,ppid= | awk -v p="$CP" '$2 == p { print $1 }' | tr '\n' ' ')"
assert_eq "$(echo $kids | wc -w | tr -d ' ')" "2" "ön koşul: ebeveynin 2 çocuğu var"
hs_kill_children TERM "$CP"; assert_eq "$?" "0" "izlenen ebeveynin çocukları kapatıldı"
sleep 0.5; left=0; for k in $kids; do _hs_alive "$k" && left=$((left + 1)); done
assert_eq "$left" "0" "çocukların hiçbiri hayatta kalmadı"
hs_kill TERM "$CP"; wait "$CP" 2>/dev/null
sleep 60 & U1=$!   # izlenmeyen
bash -c 'sleep 60 & wait' & CP2=$!; sleep 0.4
hs_kill_children TERM "$CP2" 2>/dev/null; assert_eq "$?" "3" "izlenmeyen ebeveynin çocukları REDDEDİLİR"
hs_track "$CP2"; hs_kill_children TERM "$CP2"; hs_kill TERM "$CP2"; wait "$CP2" 2>/dev/null
hs_track "$U1"; hs_kill TERM "$U1"; wait "$U1" 2>/dev/null

echo "── hs_reap ──"
sleep 60 & R1=$!; hs_track "$R1"; sleep 60 & R2=$!; hs_track "$R2"
hs_reap TERM; wait "$R1" 2>/dev/null; a=$?; wait "$R2" 2>/dev/null; b=$?
assert_eq "$a|$b" "143|143" "hs_reap izlenen tüm süreçleri kapatır"
sleep 60 & R3=$!
hs_reap TERM; assert_eq "$(_hs_alive "$R3" >/dev/null 2>&1; echo $?)" "0" "hs_reap izlenmeyeni dokunmaz"
hs_track "$R3"; hs_kill TERM "$R3"; wait "$R3" 2>/dev/null

echo "── hs_tmpdir_init / hs_assert_not_tmp ──"
for bad in /tmp/hs-reject-test-$$ /var/tmp/hs-reject-test-$$ /private/""tmp/hs-reject-test-$$ /tmp; do
    ( hs_tmpdir_init t "$bad" ) 2>/dev/null; assert_eq "$?" "3" "tmpdir '${bad}' REDDEDİLİR"
done
assert_eq "$([[ -e /tmp/hs-reject-test-$$ || -e /var/tmp/hs-reject-test-$$ ]] && echo VAR || echo yok)" "yok" "reddedilen /tmp yolu OLUŞTURULMADI"
ln -s /tmp "$W/lnk"
( hs_tmpdir_init t "$W/lnk/hs-sub-$$" ) 2>/dev/null; assert_eq "$?" "3" "sembolik bağ ile /tmp'ye kaçış REDDEDİLİR"
assert_eq "$([[ -e /tmp/hs-sub-$$ ]] && echo VAR || echo yok)" "yok" "sembolik bağ üzerinden /tmp'de dizin OLUŞTURULMADI"
out="$( unset TMPDIR; hs_tmpdir_init t "$W/work" && printf '%s|%s' "$TMPDIR" "$(mktemp -d "${TMPDIR:?}/x.XXXXXX")" )"
real="$(cd -P "$W/work" && pwd)"
assert_eq "${out%%|*}" "$real" "TMPDIR = çalışma dizini (dışa aktarıldı)"
assert_contains "${out##*|}" "$real/x." "açık şablonlu mktemp çalışma dizininde açar"
assert_eq "$( TMPDIR=/tmp; export TMPDIR; hs_tmpdir_init t "$W/w2"; echo "$TMPDIR" )" "$(cd -P "$W/w2" && pwd)" "ortamdaki TMPDIR=/tmp geçersiz kılınır"

echo "── hs_signal_ancestor: yalnız kendisi/atası ──"
sleep 60 & P9=$!; hs_track "$P9"
err="$(hs_signal_ancestor TERM "$P9" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "3" "ata olmayan (kardeş çocuk) pid: rc 3"
assert_contains "$err" "REDDEDİLDİ" "ata olmayan: ileti REDDEDİLDİ"
assert_eq "$(_hs_alive "$P9" >/dev/null 2>&1; echo $?)" "0" "ata olmayan süreç hâlâ canlı (sinyal gitmedi)"
hs_kill TERM "$P9"; wait "$P9" 2>/dev/null
{ ( sh -c 'echo $PPID' > "$W/anc.pid"; hs_signal_ancestor TERM "$(cat "$W/anc.pid")" ); } 2>/dev/null; assert_eq "$?" "143" "alt kabuk kendi pid'ine (sh -c PPID) TERM: alt kabuk 143 ile ölür"
( ( sh -c 'echo $PPID' > "$W/anc2.pid" ); hs_signal_ancestor INT 1 ) 2>/dev/null; assert_eq "$?" "3" "pid 1 geçersiz/ata değil: REDDEDİLİR"
test_summary
