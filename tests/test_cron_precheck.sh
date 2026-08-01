#!/bin/bash
# lib/cron.sh — ALTINCI HOST BULGUSU: 'cron add' KOMUT ÖN-DOĞRULAMASI +
# 126/127/75 ÇIKIŞ KODU TEŞHİSİ regresyon testi.
#
# GERÇEK üretim sunucusunda (Ubuntu 24.04) ölçülen hata: 'cron add ...
# --command="echo '\''x'\'' && date +%Y"' EXIT=0 ile "Cron eklendi" diyordu,
# ama 04:00'te 'ExecMainStatus: 126' ile düşüyordu — '-cli' AppArmor profili
# date/cat/tar/curl/git/find/mysqldump'ı exec ETTİRMİYORDU ve red SESSİZDİ
# (çekirdekte 'apparmor.*DENIED' satırı SAYISI = 0).
#
# Bu dosya ön-doğrulamanın DÖRT sınırını birden çiviler:
#   (a) builtin'ler ('echo' — dash'te hiç exec EDİLMEZ) YANLIŞ ALARM VERMEZ,
#   (b) profil tarafından engellenen ikili (rc=126) EKLEMEYİ DURDURUR ve
#       geriye YARIM dosya BIRAKMAZ,
#   (c) izinli ikili (rc=0) sorunsuz geçer,
#   (d) prob HİÇ ÇALIŞTIRILAMIYORSA (aa-exec yok / profil yüklü değil /
#       profil altında temel kabuk denemesi bile başarısız) ekleme
#       ENGELLENMEZ — YALNIZ uyarılır (FAIL-SOFT sınırı; fail-closed
#       yapılsaydı AppArmor'suz sistemlerde 'cron add' tamamen ölürdü).
#
# GERÇEK 'aa-exec' bu macOS geliştirme makinesinde YOKTUR — prob, üretim
# kodundaki SRVCTL_CRON_PROBE_FN test-seam'i ile enjekte edilir; aday ÇÖZÜMÜ
# (PATH araması) ve "hangi dizinler çalıştırılarak denenebilir" filtresi ise
# GERÇEKTEN çalışır (SRVCTL_CRON_PROBE_DIRS sahte bir dizine kilitlenir, ki
# test hermetik olsun ve host'un /usr/bin içeriğine BAĞLI OLMASIN).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
export SRVCTL_LOCK_DIR="$(mktemp -d)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
confirm() { return 0; }   # her onay isteğinde 'evet' say
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/cron.sh"

_run_isolated() { ( "$@" ); }
ex() { [[ -e "$1" ]] && echo var || echo yok; }

systemctl_log="$(mktemp -d)/systemctl.log"
: > "$systemctl_log"
systemctl() { printf '%s\n' "$*" >> "$systemctl_log"; return 0; }

# ─── Sahte ikili dizinleri ───
# FAKEBIN  : PATH'te VE prob dizinlerinde → GERÇEKTEN "çalıştırılarak" denenir.
# OUTBIN   : PATH'te AMA prob dizinlerinde DEĞİL → yan etki riski nedeniyle
#            DENENMEZ (operatörün kendi betiğini 'cron add' anında çalıştırmayız).
FAKEBIN="$(mktemp -d)"
OUTBIN="$(mktemp -d)"
export PATH="${FAKEBIN}:${OUTBIN}:${PATH}"
export SRVCTL_CRON_PROBE_DIRS="${FAKEBIN}"

# 'date' stub'ı GERÇEK /bin/date'e devreder — sidecar CREATED_AT gibi
# yerlerde core.sh'ın kendi 'date' çağrıları BOZULMASIN.
cat > "${FAKEBIN}/date" <<'EOF'
#!/bin/bash
exec /bin/date "$@"
EOF
# DİKKAT: test harness'inin KENDİ kullandığı araçlar ('cat', 'grep', 'wc' ...)
# BİLİNÇLİ OLARAK stub'lanMAZ — 'hash -r' sonrası PATH'in başındaki sahte bir
# 'cat', '$(cat "$PROBE_LOG")' gibi harness çağrılarını sessizce BOŞ döndürüp
# YANLIŞ POZİTİF üretirdi (ilk turda GERÇEKTEN oldu).
for b in curl tar php8.3 slowtool; do
    printf '#!/bin/bash\nexit 0\n' > "${FAKEBIN}/${b}"
done
printf '#!/bin/bash\nexit 0\n' > "${OUTBIN}/backup.sh"
chmod +x "${FAKEBIN}"/* "${OUTBIN}"/*
# 'hash -r' ZORUNLU: bash bulduğu komut yollarını HASH TABLOSUNDA tutar ve
# 'command -v' de (üretim kodundaki _cron_resolve_bin dahil) O TABLOYA bakar.
# Yukarıdaki 'cat > ...' satırı stub'lar OLUŞTURULMADAN ÖNCE '/bin/cat'i
# hash'lediğinden, temizlenmezse test '/bin/cat' çözerdi ve YANLIŞ NEGATİF
# verirdi (ampirik olarak bu testin ilk turunda GERÇEKTEN oldu).
hash -r 2>/dev/null || true

# ─── Enjekte edilen prob (GERÇEK 'aa-exec' yerine) ───
# Sözleşme: <profil> <mutlak-ikili-yol|"">  → rc.  Boş ikili = TEMEL
# (self-check) denemesi. 126 = profil engelledi.
PROBE_BLOCKED="curl tar"
PROBE_TIMEOUT=""      # bu ikili(ler) için prob 124 döner ('timeout' kesti)
PROBE_SELFCHECK_RC=0
# Prob çağrıları DOSYAYA yazılır: '_cron_add' çıktısı '$(...)' ile
# yakalandığında ALT KABUKTA çalışır, değişken atamaları dışarı SIZMAZ
# (CLAUDE.md'deki bilinen bash tuzağı).
export PROBE_LOG="$(mktemp)"
: > "$PROBE_LOG"
fake_probe() {
    local profile="$1" bin="${2:-}" base
    printf '%s:%s\n' "$profile" "$bin" >> "$PROBE_LOG"
    [[ -n "$bin" ]] || return "$PROBE_SELFCHECK_RC"
    base="${bin##*/}"
    case " ${PROBE_TIMEOUT} " in
        *" ${base} "*) return 124 ;;
    esac
    case " ${PROBE_BLOCKED} " in
        *" ${base} "*) return 126 ;;
    esac
    return 0
}
export SRVCTL_CRON_PROBE_FN=fake_probe

d="example.com"
sname=$(safe_name "$d")
profile="srvctl-${sname}-cli"
mkdir -p "${WEB_ROOT}/${d}"
: > "${WEB_ROOT}/${d}/.credentials"

# Bir ekleme denemesinin GERİYE HİÇBİR ŞEY bırakmadığını doğrular.
assert_no_artifacts() {
    local n="$1" label="$2"
    assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-${n}.service")" "yok" "${label}: .service OLUŞMADI"
    assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-${n}.timer")" "yok" "${label}: .timer OLUŞMADI"
    assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-${n}.service.d")" "yok" "${label}: OnFailure drop-in OLUŞMADI"
    assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cronfail-${sname}-${n}.service")" "yok" "${label}: fail-service OLUŞMADI"
    assert_eq "$(ex "${SRVCTL_STATE_DIR}/_cron/${sname}/${n}.conf")" "yok" "${label}: sidecar OLUŞMADI"
}

# ═══════════════════════════════════════════════════════════════
# 1) SAF AYRIŞTIRMA — komut, kabuk operatörlerinden parçalanıyor ve HER
#    parçanın İLK kelimesi aday sayılıyor mu? (görev şartı: '&&' '||' '|'
#    ';' '&' HEPSİ)
# ═══════════════════════════════════════════════════════════════
parts=$(_cron_split_command "a && b || c | d ; e & f")
assert_eq "$(printf '%s' "$parts" | wc -l | tr -d ' ')" "5" \
    "1) '&& || | ; &' ayraçlarının HEPSİ parçalıyor (6 parça = 5 satırsonu)"

cands=$(_cron_command_candidates "/bin/one && two || three | four ; five & six")
for w in /bin/one two three four five six; do
    assert_contains "$cands" "aday ${w}" "1) çok parçalı komutta '${w}' aday olarak çıkarıldı"
done

# Tırnak İÇİNDEKİ operatör ayraç SAYILMAMALI (yoksa uydurma adaylar üretirdik).
assert_eq "$(_cron_split_command 'echo "a && b"' | wc -l | tr -d ' ')" "1" \
    "1) tırnak içindeki '&&' ayraç SAYILMIYOR (tek parça)"

# Değişken ataması ve gruplama önekleri atlanıp GERÇEK komut bulunuyor mu?
assert_eq "$(_cron_part_first_word 'FOO=1 BAR=2 /usr/bin/git pull')" "/usr/bin/git" \
    "1) 'VAR=deger' önekleri atlanıp gerçek komut bulunuyor"
assert_eq "$(_cron_part_first_word '(cd /tmp')" "cd" \
    "1) yapışık '(' gruplama karakteri soyuluyor"

# ═══════════════════════════════════════════════════════════════
# 2) BUILTIN YANLIŞ ALARMI YOK — 'echo' dash'te builtin'dir, HİÇ exec
#    edilmez. (HOST ölçümünde '/bin/echo' rc=126 verdi ama "sh -c 'echo x'"
#    sorunsuz çalışır — bu ayrım yapılmazsa çalışan cron'lar REDDEDİLİRDİ.)
# ═══════════════════════════════════════════════════════════════
assert_contains "$(_cron_command_candidates "echo merhaba")" "builtin echo" \
    "2) 'echo' BUILTIN sınıfında (aday DEĞİL)"
for b in printf test '[' cd : true false read export exit eval trap umask; do
    assert_ok _cron_is_shell_builtin "$b"
done

: > "$PROBE_LOG"
out2=$(_cron_add "$d" --name=builtin_only --schedule="her saat" --command="echo merhaba ; cd /tmp" 2>&1)
rc2=$?
assert_eq "$rc2" "0" "2) yalnız builtin içeren komut EKLENİYOR (exit 0)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-builtin_only.service")" "var" \
    "2) builtin komut için .service GERÇEKTEN oluşturuldu"
assert_not_contains "$out2" "ÇALIŞTIRILAMIYOR" "2) builtin komutta ENGEL hatası YOK (yanlış alarm yok)"
assert_not_contains "$out2" "ön-doğrulaması YAPILAMADI" \
    "2) builtin komutta prob HİÇ ÇALIŞTIRILMADI (gereksiz 'doğrulanamadı' uyarısı da YOK)"
assert_eq "$(cat "$PROBE_LOG")" "" "2) builtin-only komut için prob HİÇ çağrılmadı (self-check bile)"
_cron_remove "$d" builtin_only >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════
# 3) İZİNLİ İKİLİ GEÇER — HOST'ta 126 veren 'date', profilde izinliyse
#    (prob rc=0) ekleme SORUNSUZ tamamlanmalı.
# ═══════════════════════════════════════════════════════════════
: > "$PROBE_LOG"
out3=$(_cron_add "$d" --name=date_job --schedule="her gün 04:00" --command="echo 'x' && date +%Y" 2>&1)
rc3=$?
probe_calls=$(cat "$PROBE_LOG")
assert_eq "$rc3" "0" "3) izinli ikili ('date') içeren komut EKLENİYOR (exit 0)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-date_job.service")" "var" \
    "3) .service oluşturuldu"
assert_contains "$out3" "ön-doğrulaması GEÇTİ" "3) operatöre ön-doğrulamanın GEÇTİĞİ bildiriliyor"
assert_contains "$probe_calls" "${profile}:${FAKEBIN}/date" \
    "3) prob GERÇEKTEN domain profili + MUTLAK ikili yolu ile çağrıldı"
assert_contains "$probe_calls" "${profile}:
" "3) prob önce TEMEL (self-check) denemesini yaptı (boş ikili)"
_cron_remove "$d" date_job >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════
# 4) ENGELLENEN İKİLİ — NET hata + HİÇBİR dosya kalmamalı (asıl görev).
# ═══════════════════════════════════════════════════════════════
: > "$systemctl_log"
out4=$(_run_isolated _cron_add "$d" --name=egress_job --schedule="her gün 04:00" \
    --command="echo baslangic && curl -s https://ornek.test/ping" 2>&1)
rc4=$?
assert_eq "$([[ "$rc4" -ne 0 ]] && echo hata || echo basarili)" "hata" \
    "4) profilin engellediği ikili ('curl') EKLEMEYİ DURDURUYOR (exit != 0)"
assert_contains "$out4" "ÇALIŞTIRILAMIYOR" "4) hata mesajı NET ('... ÇALIŞTIRILAMIYOR')"
assert_contains "$out4" "${FAKEBIN}/curl" "4) hata HANGİ ikilinin engellendiğini söylüyor"
assert_contains "$out4" "$profile" "4) hata HANGİ profilin engellediğini söylüyor"
assert_contains "$out4" "srvctl domain repair ${d}" "4) hata SOMUT bir çözüm komutu içeriyor"
assert_contains "$out4" "cron add --system" "4) hata alternatif kapsamı (sistem cron) da söylüyor"
assert_no_artifacts "egress_job" "4"
assert_eq "$(cat "$systemctl_log")" "" \
    "4) engellenen eklemede HİÇBİR systemctl çağrısı yapılmadı (render'a hiç gidilmedi)"

# ═══════════════════════════════════════════════════════════════
# 5) ÇOK PARÇALI KOMUT — engellenen ikili SON parçada/farklı ayraçların
#    ARKASINDA olsa bile yakalanmalı (yalnız İLK parçaya bakan bir
#    uygulama bu testte düşer).
# ═══════════════════════════════════════════════════════════════
out5=$(_run_isolated _cron_add "$d" --name=pipeline_job --schedule="her saat" \
    --command="date ; echo x | php8.3 -v ; date && tar -czf /tmp/a.tgz ." 2>&1)
rc5=$?
assert_eq "$([[ "$rc5" -ne 0 ]] && echo hata || echo basarili)" "hata" \
    "5) engellenen ikili SON parçada olsa bile yakalanıyor"
assert_contains "$out5" "${FAKEBIN}/tar" "5) yakalanan ikili 'tar' (';' + '|' + '&&' zincirinin sonunda)"
assert_no_artifacts "pipeline_job" "5"

# Aynı komutta İKİ engelli ikili varsa İKİSİ DE raporlanmalı (ilkinde
# durup diğerini gizlemek operatörü iki tur bekletirdi).
out5b=$(_run_isolated _cron_add "$d" --name=two_blocked --schedule="her saat" \
    --command="curl -s https://a/ | tar xz" 2>&1)
assert_contains "$out5b" "${FAKEBIN}/curl" "5b) birinci engelli ikili raporlandı"
assert_contains "$out5b" "${FAKEBIN}/tar" "5b) İKİNCİ engelli ikili de AYNI mesajda raporlandı"
assert_no_artifacts "two_blocked" "5b"

# ═══════════════════════════════════════════════════════════════
# 6) FAIL-SOFT SINIRI — prob KULLANILAMIYORSA ekleme ENGELLENMEZ.
#    (6a) enjekte prob YOK + 'aa-exec' YOK (bu makine) + profil dosyası boş
#         → "YAPILAMADI" uyarısı, ama cron EKLENİR.
# ═══════════════════════════════════════════════════════════════
saved_probe_fn="$SRVCTL_CRON_PROBE_FN"
unset SRVCTL_CRON_PROBE_FN
export SRVCTL_AA_PROFILES_FILE="$(mktemp)"   # okunabilir AMA profil listesi BOŞ
: > "$SRVCTL_AA_PROFILES_FILE"
out6=$(_cron_add "$d" --name=noprobe_job --schedule="her saat" --command="curl -s https://a/" 2>&1)
rc6=$?
assert_eq "$rc6" "0" "6a) prob YOKKEN ekleme ENGELLENMİYOR (FAIL-SOFT — exit 0)"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-cron-${sname}-noprobe_job.service")" "var" \
    "6a) prob YOKKEN .service GERÇEKTEN oluşturuldu"
assert_contains "$out6" "ön-doğrulaması YAPILAMADI" \
    "6a) doğrulanamadığı AÇIKÇA söyleniyor (sessizce 'geçti' sayılmıyor)"
assert_contains "$out6" "srvctl cron run ${d}" \
    "6a) operatöre elle doğrulama yolu ('cron run') gösteriliyor"
assert_not_contains "$out6" "ÇALIŞTIRILAMIYOR" "6a) prob yokken ENGEL hatası ÜRETİLMİYOR"
_cron_remove "$d" noprobe_job >/dev/null 2>&1
unset SRVCTL_AA_PROFILES_FILE
export SRVCTL_CRON_PROBE_FN="$saved_probe_fn"

# (6b) Prob VAR ama TEMEL (self-check) denemesi başarısız — "aa-exec var,
#      çekirdek geçişi reddediyor" (konteyner/LSM kapalı) sınıfı. Bu
#      durumda 126 yorumlamak YANLIŞ olurdu: engel DEĞİL, uyarı beklenir.
PROBE_SELFCHECK_RC=1
out6b=$(_cron_add "$d" --name=selfcheck_job --schedule="her saat" --command="curl -s https://a/" 2>&1)
rc6b=$?
PROBE_SELFCHECK_RC=0
assert_eq "$rc6b" "0" "6b) temel prob denemesi başarısızsa ekleme ENGELLENMİYOR (exit 0)"
assert_contains "$out6b" "temel kabuk denemesi başarısız" \
    "6b) uyarı SEBEBİ söylüyor (aa-exec rc)"
assert_not_contains "$out6b" "ÇALIŞTIRILAMIYOR" \
    "6b) güvenilmez prob sonucundan ENGEL kararı ÜRETİLMİYOR"
_cron_remove "$d" selfcheck_job >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════
# 7) SESSİZ GEÇİŞ YOK — çözülemeyen/denetlenmeyen adaylar RAPORLANIR.
# ═══════════════════════════════════════════════════════════════
# (7a) Değişkenli komut: uydurma YOK, "denetlenmedi" denir, ekleme sürer.
out7a=$(_cron_add "$d" --name=dynamic_job --schedule="her saat" --command='$MY_CMD --calis' 2>&1)
assert_eq "$?" "0" "7a) değişkenli komut EKLENİYOR (çözülemez ≠ hatalı)"
assert_contains "$out7a" "ÇÖZÜLEMEDİ ve DENETLENMEDİ" "7a) çözülemeyen parça AÇIKÇA bildiriliyor"
_cron_remove "$d" dynamic_job >/dev/null 2>&1

# (7b) PATH'te olmayan komut: 127 riski UYARILIR ama ENGELLENMEZ (unit'in
#      PATH'i ve WorkingDirectory'si ilk deploy'dan sonra değişebilir).
out7b=$(_cron_add "$d" --name=missing_job --schedule="her saat" --command="zzz_olmayan_komut --x" 2>&1)
assert_eq "$?" "0" "7b) PATH'te bulunmayan komut EKLEMEYİ DURDURMUYOR"
assert_contains "$out7b" "PATH'te BULUNAMADI" "7b) 127 riski AÇIKÇA uyarılıyor"
_cron_remove "$d" missing_job >/dev/null 2>&1

# (7c) Sistem ikili dizinlerinin DIŞINDAKİ yol ÇALIŞTIRILARAK denenmez —
#      'cron add' operatörün KENDİ betiğini (ör. gerçek yedek alan
#      backup.sh) yan etkileriyle birlikte çalıştırmamalıdır. Prob bu
#      ikiliyi engelli SAYSA BİLE ekleme sürer (denenmediği için karar
#      verilemez) ve durum AÇIKÇA bildirilir.
PROBE_BLOCKED="curl tar backup.sh"
: > "$PROBE_LOG"
out7c=$(_cron_add "$d" --name=outside_job --schedule="her saat" --command="backup.sh --full" 2>&1)
rc7c=$?
PROBE_BLOCKED="curl tar"
assert_eq "$rc7c" "0" "7c) prob dizinleri DIŞINDAKİ betik EKLEMEYİ DURDURMUYOR"
assert_contains "$out7c" "ÇALIŞTIRILARAK denenmedi" "7c) denenmediği AÇIKÇA bildiriliyor"
assert_contains "$out7c" "${OUTBIN}/backup.sh" "7c) hangi yolun denenmediği söyleniyor"
assert_not_contains "$(cat "$PROBE_LOG")" "${OUTBIN}/backup.sh" \
    "7c) operatörün KENDİ betiği 'cron add' anında ÇALIŞTIRILMADI (yan etki riski alınmadı)"
_cron_remove "$d" outside_job >/dev/null 2>&1

# (7d) Prob ZAMAN AŞIMINA uğrarsa ('--version'ı yok sayıp stdin bekleyen bir
#      ikili) sonuç 124'tür — 126 DEĞİLDİR. "Ölçülemedi" denir ve ekleme
#      SÜRER; 124'ü engel saymak yanlış pozitif üretirdi.
PROBE_TIMEOUT="slowtool"
out7d=$(_cron_add "$d" --name=slow_job --schedule="her saat" --command="slowtool /tmp/x" 2>&1)
rc7d=$?
PROBE_TIMEOUT=""
assert_eq "$rc7d" "0" "7d) prob zaman aşımı EKLEMEYİ DURDURMUYOR (124 ≠ 126)"
assert_contains "$out7d" "ÖLÇÜLEMEDİ" "7d) ölçülemediği AÇIKÇA bildiriliyor"
assert_not_contains "$out7d" "ÇALIŞTIRILAMIYOR" "7d) zaman aşımı ENGEL olarak yorumlanMIYOR"
_cron_remove "$d" slow_job >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════
# 8) SİSTEM KAPSAMI — '--system' cron'u root olarak, HİÇBİR CLI profiline
#    bağlı OLMADAN çalışır; ön-doğrulama uygulanMAMALI (yanlış alarm olurdu).
# ═══════════════════════════════════════════════════════════════
out8=$(_cron_add --system --name=sys_egress --schedule="her saat" --command="curl -s https://a/" 2>&1)
rc8=$?
assert_eq "$rc8" "0" "8) '--system' cron'da engelli ikili EKLEMEYİ DURDURMUYOR"
assert_not_contains "$out8" "ÇALIŞTIRILAMIYOR" "8) '--system' kapsamında ön-doğrulama UYGULANMIYOR"
assert_eq "$(ex "${SRVCTL_SYSTEMD_DIR}/srvctl-syscron-sys_egress.service")" "var" \
    "8) sistem cron'u GERÇEKTEN oluşturuldu"

# ═══════════════════════════════════════════════════════════════
# 9) ÇIKIŞ KODU TEŞHİSİ (126/127/75) — TEK kaynak, dört yerde AYNI metin.
# ═══════════════════════════════════════════════════════════════
h126=$(_cron_exit_hint 126 "$profile")
assert_contains "$h126" "izin reddedildi" "9) 126 → 'izin reddedildi'"
assert_contains "$h126" "AppArmor" "9) 126 → AppArmor sebebi söyleniyor"
assert_contains "$h126" "$profile" "9) 126 → SUÇLANAN profil adı ('srvctl-<safe>-cli') geçiyor"

h126s=$(_cron_exit_hint 126 "")
assert_contains "$h126s" "izin reddedildi" "9) sistem kapsamında da 126 açıklanıyor"
assert_not_contains "$h126s" "AppArmor profili (" \
    "9) profil YOKKEN (sistem cron) olmayan bir profil SUÇLANMIYOR"

assert_contains "$(_cron_exit_hint 127 "$profile")" "komut bulunamadı" "9) 127 → 'komut bulunamadı'"
assert_contains "$(_cron_exit_hint 127 "$profile")" "PATH" "9) 127 → PATH/yazım hatası deniyor"
h75=$(_cron_exit_hint 75 "$profile")
assert_contains "$h75" "deploy kilidi" "9) 75 → deploy kilidi açıklaması"
assert_contains "$h75" "ATLANDI" "9) 75 → 'atlandı' (gerçek başarısızlık DEĞİL)"
assert_eq "$(_cron_exit_hint 0 "$profile")" "" "9) 0 için teşhis UYDURULMUYOR (boş)"
assert_eq "$(_cron_exit_hint 42 "$profile")" "" "9) bilinmeyen kod için teşhis UYDURULMUYOR (boş)"
assert_eq "$(_cron_exit_hint "" "$profile")" "" "9) boş kod için teşhis UYDURULMUYOR (boş)"

# ═══════════════════════════════════════════════════════════════
# 10) TEŞHİS GÖRÜNÜRLÜĞÜ — 'cron list' / 'cron show' / 'cron run' ham
#     sayı yerine AÇIKLAMA gösteriyor mu? (systemctl stub'u ExecMainStatus
#     olarak 126 döndürür.)
# ═══════════════════════════════════════════════════════════════
_cron_add "$d" --name=diag_job --schedule="her saat" --command="date" >/dev/null 2>&1

systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    if [[ "${1:-}" == "show" ]]; then
        case "$*" in
            *ExecMainStatus*) printf '126\n' ;;
            *Result*)         printf 'exit-code\n' ;;
            *)                printf '\n' ;;
        esac
    fi
    return 0
}

list_out=$(_cron_list "$d" 2>&1)
assert_contains "$list_out" "Son çıkış kodu : 126" "10) 'cron list' ham kodu HÂLÂ gösteriyor"
assert_contains "$list_out" "izin reddedildi" "10) 'cron list' 126'yı AÇIKLIYOR"
assert_contains "$list_out" "$profile" "10) 'cron list' açıklamasında domain profili adı geçiyor"

show_out=$(_cron_show "$d" diag_job 2>&1)
assert_contains "$show_out" "Teşhis" "10) 'cron show' ayrı bir 'Teşhis' satırı basıyor"
assert_contains "$show_out" "izin reddedildi" "10) 'cron show' 126'yı AÇIKLIYOR"

run_out=$(_cron_run "$d" diag_job 2>&1)
assert_contains "$run_out" "izin reddedildi" "10) 'cron run' 126'yı AÇIKLIYOR"
assert_contains "$run_out" "srvctl cron logs ${d} diag_job" "10) 'cron run' log komutunu göstermeye DEVAM ediyor"

# 75 (deploy kilidi) — 'atlandı' olarak anlamlandırılmalı, hata gibi DEĞİL.
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    if [[ "${1:-}" == "show" ]]; then
        case "$*" in
            *ExecMainStatus*) printf '75\n' ;;
            *Result*)         printf 'exit-code\n' ;;
            *)                printf '\n' ;;
        esac
    fi
    return 0
}
run75_out=$(_cron_run "$d" diag_job 2>&1)
assert_contains "$run75_out" "deploy kilidi" "10) 'cron run' 75'i deploy kilidi olarak anlamlandırıyor"

# ═══════════════════════════════════════════════════════════════
# 11) BİLDİRİM — OnFailure bildirimi teşhisi İÇERMELİ (operatör e-postada
#     ham '126' yerine SEBEBİ görmeli).
# ═══════════════════════════════════════════════════════════════
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    if [[ "${1:-}" == "show" ]]; then
        case "$*" in
            *ExecMainStatus*) printf '126\n' ;;
            *Result*)         printf 'exit-code\n' ;;
            *)                printf '\n' ;;
        esac
    fi
    return 0
}
NOTIFY_BODY=""
send_notification() { NOTIFY_BODY="$2"; return 0; }
_cron_on_failure "$d" diag_job >/dev/null 2>&1
assert_contains "$NOTIFY_BODY" "Teşhis:" "11) bildirim gövdesinde 'Teşhis:' satırı VAR"
assert_contains "$NOTIFY_BODY" "izin reddedildi" "11) bildirim 126'nın SEBEBİNİ içeriyor"
assert_contains "$NOTIFY_BODY" "$profile" "11) bildirim suçlanan profili adıyla söylüyor"
assert_contains "$NOTIFY_BODY" "Çıkış kodu: 126" "11) bildirim ham kodu da korumaya devam ediyor"

# 75 → bildirim GÖNDERİLMEZ (mevcut davranış korunuyor: deploy sırasında
# her dakika bildirim spam'i istenmez).
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    if [[ "${1:-}" == "show" ]]; then
        case "$*" in
            *ExecMainStatus*) printf '75\n' ;;
            *Result*)         printf 'exit-code\n' ;;
            *)                printf '\n' ;;
        esac
    fi
    return 0
}
NOTIFY_BODY=""
_cron_on_failure "$d" diag_job >/dev/null 2>&1
assert_eq "$NOTIFY_BODY" "" "11) 75 (deploy kilidi) için bildirim GÖNDERİLMİYOR (mevcut davranış korundu)"

rm -rf "$WEB_ROOT" "$SRVCTL_SYSTEMD_DIR" "$SRVCTL_STATE_DIR" "$SRVCTL_LOCK_DIR" "$FAKEBIN" "$OUTBIN"
test_summary
