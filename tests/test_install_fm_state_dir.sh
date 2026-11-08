#!/bin/bash
# QL8-L5: FM acil durum dizini (/var/lib/srvctl/fm-emergency, root:root 0700) kurulum / init / self-update yolunda HAZIRLANIR.
# Önceden yalnız ihtiyaç anında `mkdir -p` ile doğuyordu; kurulumda hazırlanmadığı için üst dizin ya da sahiplik tam acil
# anda beklenmedik olabilir ve ikinci işaret konumu yazılamazdı (rc 6). Hazırlık TEK işlevde (lib/domconf.sh ::
# _domconf_fm_em_state_dir_prepare, a1) — burada üç çağıranın (install.sh, lib/init.sh, lib/selfupdate.sh) o işlevi
# TAZE kabukta, kurulu dosyalardan ve sözleşme adıyla çağırdığı, başarısızlıkta SESSİZ GEÇMEDİĞİ ve doğru yerde
# durduğu sınanır. İşlevin kendi davranışı (mkdir/chmod/sahiplik) domconf testlerindedir; gerçek işlevle entegrasyon
# aşağıda (bölüm F) işlev varsa koşar.
#   A  install.sh :: _install_prepare_fm_state_dir   B  lib/selfupdate.sh :: _selfupdate_prepare_fm_state_dir + _selfupdate_run sırası
#   C  lib/init.sh :: _init_prepare_fm_state_dir + cmd_init bağı   D  taşıma başarısızlığı görünür   F  gerçek işlevle entegrasyon
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Sahte kurulum kökü: core.sh boş, domconf.sh yalnız sözleşme adlı işlevi taklit eder (çağrıyı günlüğe yazar).
mkroot() {   # $1 = kök
    mkdir -p "$1/lib"
    : > "$1/lib/core.sh"
    cat > "$1/lib/domconf.sh" <<'STUB'
_domconf_fm_em_state_dir_prepare() { printf 'cagri\n' >> "$PREP_LOG"; return "${PREP_RC:-0}"; }
STUB
}
export PREP_LOG="${T}/prep.log"
calls() { grep -c . "$PREP_LOG" 2>/dev/null || true; }

echo "── A: install.sh :: _install_prepare_fm_state_dir ──"
INST_BODY="$(sed -n '/^_install_prepare_fm_state_dir() {/,/^}/p' "${REPO_ROOT}/install.sh")"
assert_contains "$INST_BODY" "_domconf_fm_em_state_dir_prepare" "A0: install.sh sözleşme adlı işlevi çağırıyor (a1: _domconf_fm_em_state_dir_prepare)"
YELLOW=''; NC=''; export YELLOW NC; INSTALL_DIR="${T}/rootA"; mkroot "$INSTALL_DIR"
eval "$INST_BODY"
: > "$PREP_LOG"; PREP_RC=0 out="$(_install_prepare_fm_state_dir "$INSTALL_DIR" 2>&1)"; rc=$?
assert_eq "$rc" "0" "A1: hazırlık başarılı → rc 0"
assert_eq "$(calls)" "1" "A1: kurulu lib/domconf.sh'taki işlev TAM BİR kez çağrıldı"
assert_eq "$out" "" "A1: başarıda ileti basılmaz"
: > "$PREP_LOG"; out="$(PREP_RC=1 _install_prepare_fm_state_dir "$INSTALL_DIR" 2>&1)"; rc=$?
assert_eq "$rc" "1" "A2: hazırlık BAŞARISIZ → rc 1 (sessiz geçilmez)"
assert_contains "$out" "FM acil durum dizini hazırlanamadı" "A2: operatöre uyarı basıldı"
assert_contains "$out" "install -d -m 700 -o root -g root /var/lib/srvctl /var/lib/srvctl/fm-emergency" "A2: elle komut basıldı"
rm -rf "${T}/rootA_yok"
out="$(_install_prepare_fm_state_dir "${T}/rootA_yok" 2>&1)"; rc=$?
assert_eq "$rc" "1" "A3: kurulu lib/ yoksa (source edilemez) rc 1 — işlev yokmuş gibi geçilmez"
assert_contains "$out" "hazırlanamadı" "A3: uyarı basıldı"
# ana akış: çağrı, log dizini adımından SONRA ve Doğrulama'dan ÖNCE; başarısızlık kurulumu durdurmaz ('|| true')
MAIN_CALL_LN="$(grep -n '^_install_prepare_fm_state_dir "' "${REPO_ROOT}/install.sh" | head -1 | cut -d: -f1)"
LOG_LN="$(grep -n 'chmod 640 "${INSTALL_DIR}/logs/srvctl.log"' "${REPO_ROOT}/install.sh" | head -1 | cut -d: -f1)"
VERIFY_LN="$(grep -n '^# ─── Doğrulama ───' "${REPO_ROOT}/install.sh" | head -1 | cut -d: -f1)"
assert_eq "$([[ -n "$MAIN_CALL_LN" && -n "$LOG_LN" && -n "$VERIFY_LN" && "$MAIN_CALL_LN" -gt "$LOG_LN" && "$MAIN_CALL_LN" -lt "$VERIFY_LN" ]] && echo sirali || echo "bozuk(${MAIN_CALL_LN:-yok}/${LOG_LN:-yok}/${VERIFY_LN:-yok})")" "sirali" "A4: ana akışta çağrı var; dosyalar kopyalandıktan (log adımı) sonra, doğrulamadan önce"
assert_contains "$(sed -n "${MAIN_CALL_LN}p" "${REPO_ROOT}/install.sh")" '|| true' "A4: başarısızlık kurulumu durdurmaz ('|| true' + işlevin kendi uyarısı)"

echo "── B: lib/selfupdate.sh :: _selfupdate_prepare_fm_state_dir ──"
SRVCTL_ROOT="${T}/rootB"; mkroot "$SRVCTL_ROOT"; mkdir -p "$SRVCTL_ROOT/bin"
source "${REPO_ROOT}/lib/selfupdate.sh"     # SRVCTL_ROOT önceden ayarlı → türetilen yollar geçici kökte
: > "$PREP_LOG"; out="$(PREP_RC=0 _selfupdate_prepare_fm_state_dir 2>&1)"; rc=$?
assert_eq "$rc" "0" "B1: hazırlık başarılı → rc 0"
assert_eq "$(calls)" "1" "B1: kurulu domconf.sh'taki işlev TAM BİR kez çağrıldı"
: > "$PREP_LOG"; out="$(PREP_RC=1 _selfupdate_prepare_fm_state_dir 2>&1)"; rc=$?
assert_eq "$rc" "1" "B2: hazırlık BAŞARISIZ → rc 1"
assert_contains "$out" "FM acil durum dizini hazırlanamadı" "B2: uyarı basıldı"
assert_contains "$out" "install -d -m 700 -o root -g root /var/lib/srvctl /var/lib/srvctl/fm-emergency" "B2: elle komut basıldı"

# _selfupdate_run SIRASI: kurulum → sağlık kontrolü → hazırlık. Sağlık kontrolü başarısızsa hazırlık HİÇ çalışmaz.
SEQ="${T}/seq.log"
git() { return 0; }
_selfupdate_validate_repo_url() { return 0; }
_selfupdate_assert_pin_owned() { return 0; }
_selfupdate_warn_if_pin_stale() { :; }
_selfupdate_backup_current() { echo "${T}/backup"; }
_selfupdate_fetch_pinned() { return 0; }
_selfupdate_verify_tag_signature() { :; }
_selfupdate_install_from_staging() { echo kurulum >> "$SEQ"; }
_selfupdate_prune_backups() { :; }
_selfupdate_offer_fm_root() { :; }
_selfupdate_restore_from_backup() { echo geri-al >> "$SEQ"; return 0; }
_selfupdate_prepare_fm_state_dir() { echo hazirlik >> "$SEQ"; return "${PREP_RC:-0}"; }
step() { :; }
SRVCTL_SELFUPDATE_PIN="${T}/pin"
# shellcheck disable=SC2034  # SRVCTL_CURRENT_COMMIT: _selfupdate_run okur
SRVCTL_CURRENT_COMMIT="${T}/current"
run_update() {   # $1 = sağlık kontrolü rc, $2 = hazırlık rc → sıra günlüğü + çıktı + rc
    : > "$SEQ"
    printf 'PINNED_COMMIT=%s\nPINNED_AT=x\nPINNED_REPO=%s\n' "$(printf 'a%.0s' $(seq 1 40))" "$SRVCTL_REPO" > "$SRVCTL_SELFUPDATE_PIN"
    local hrc="$1" prc="$2"
    ( _selfupdate_health_check() { echo saglik >> "$SEQ"; return "$hrc"; }
      export PREP_RC="$prc"
      _selfupdate_run ) > "${T}/run.out" 2>&1
    echo "rc=$?" >> "${T}/run.out"
}
run_update 0 0
assert_eq "$(tr '\n' ' ' < "$SEQ")" "kurulum saglik hazirlik " "B3: _selfupdate_run sırası kurulum → sağlık kontrolü → FM dizin hazırlığı"
assert_contains "$(cat "${T}/run.out")" "rc=0" "B3: akış rc 0 ile bitti"
run_update 0 1
assert_eq "$(tr '\n' ' ' < "$SEQ")" "kurulum saglik hazirlik " "B4: hazırlık başarısız olsa da güncelleme sürer (hazırlık çağrıldı)"
assert_contains "$(cat "${T}/run.out")" "rc=0" "B4: hazırlık başarısızlığı güncellemeyi BAŞARISIZ yapmaz (rc 0; uyarı işlevin kendisinde)"
run_update 1 0
assert_eq "$(tr '\n' ' ' < "$SEQ")" "kurulum saglik geri-al " "B5: sağlık kontrolü başarısız → geri alındı, FM dizin hazırlığı HİÇ çalışmadı"
assert_not_contains "$(cat "${T}/run.out")" "rc=0" "B5: sağlık başarısızlığı rc≠0"

echo "── C: lib/init.sh :: _init_prepare_fm_state_dir ──"
SRVCTL_ROOT="${T}/rootC"; mkroot "$SRVCTL_ROOT"
source "${REPO_ROOT}/lib/init.sh"
: > "$PREP_LOG"; out="$(PREP_RC=0 _init_prepare_fm_state_dir 2>&1)"; rc=$?
assert_eq "$rc" "0" "C1: hazırlık başarılı → rc 0"
assert_eq "$(calls)" "1" "C1: kurulu domconf.sh'taki işlev TAM BİR kez çağrıldı"
: > "$PREP_LOG"; out="$(PREP_RC=1 _init_prepare_fm_state_dir 2>&1)"; rc=$?
assert_eq "$rc" "1" "C2: hazırlık BAŞARISIZ → rc 1"
assert_contains "$out" "FM acil durum dizini hazırlanamadı" "C2: uyarı basıldı"
# cmd_init bağı: gerçek cmd_init çalıştırılır; adım işlevleri ve apt nötrlenir. Hazırlık başarısızsa init "kısmen" işaretlenir.
INIT_BODY="$(sed -n '/^cmd_init() {/,/^}/p' "${REPO_ROOT}/lib/init.sh")"
assert_contains "$INIT_BODY" "_init_prepare_fm_state_dir" "C3: cmd_init hazırlığı çağırıyor"
cmd_init_degraded() {   # $1 = hazırlık rc → "DEGRADED=<true|false> HAZIRLIK=<n>"
    local want_rc="$1"
    ( require_root() { :; }; _init_apt_noninteractive() { :; }; header() { :; }; info() { :; }; warn() { :; }
      _init_run_step() { :; }
      # cmd_init'in kuyruğu GERÇEK mkdir/secure_dir/dpkg-reconfigure çağırır: hepsi etkisiz işlevle gölgelenir (sistem değişmez)
      mkdir() { :; }; secure_dir() { :; }; dpkg-reconfigure() { :; }; log_action() { :; }
      _init_prepare_fm_state_dir() { echo hazirlik >> "$SEQ"; return "$want_rc"; }
      : > "$SEQ"
      cmd_init >/dev/null 2>&1
      echo "DEGRADED=${_INIT_ANY_DEGRADED:-yok} HAZIRLIK=$(grep -c hazirlik "$SEQ")" ) 2>/dev/null
}
# cmd_init sonunda başka işlevler (özet, log_action) çağırabilir; yalnız _INIT_ANY_DEGRADED ve çağrı sayısı ölçülür
r0="$(cmd_init_degraded 0)"; r1="$(cmd_init_degraded 1)"
assert_contains "$r0" "HAZIRLIK=1" "C4: cmd_init FM dizin hazırlığını TAM BİR kez çağırır"
assert_contains "$r0" "DEGRADED=false" "C4: hazırlık başarılı → init 'kısmen' DEĞİL"
assert_contains "$r1" "DEGRADED=true" "C5: hazırlık başarısız → init 'kısmen tamamlandı' işaretlenir"

echo "── D: tüketici bağı sözleşme adıyla (a1 işlevi yeniden adlandırırsa üç çağıran birlikte kırılır) ──"
for f in install.sh lib/init.sh lib/selfupdate.sh; do
    assert_contains "$(cat "${REPO_ROOT}/${f}")" "_domconf_fm_em_state_dir_prepare" "D: ${f} sözleşme adlı işlevi çağırıyor"
done

echo "── F: gerçek _domconf_fm_em_state_dir_prepare ile entegrasyon ──"
# Üç çağıranın TAZE kabuğu gerçek core.sh + domconf.sh'ı source eder; işlev tanımlı olmalı (127 'command not found' yok) ve
# gerçekten dizini hazırlamalı. Yön: SRVCTL_FM_EMERGENCY_DIR geçici dizine yönlendirilir (varsayılan yola YAZILMAZ; varsayılan
# yol davranışı domconf testlerindedir). Root olmayan test kullanıcısında dizin oluşur (mod 700) ama sahiplik doğrulaması
# DÜRÜSTÇE reddeder (rc 1 + 'güvenilir değil'); root'ta rc 0.
SRVCTL_ROOT="${T}/rootF"; mkdir -p "$SRVCTL_ROOT/lib"
cp "${REPO_ROOT}/lib/core.sh" "${REPO_ROOT}/lib/domconf.sh" "$SRVCTL_ROOT/lib/"
assert_contains "$(cat "${REPO_ROOT}/lib/domconf.sh")" "_domconf_fm_em_state_dir_prepare()" "F0: a1'in sözleşme adlı işlevi domconf.sh'ta tanımlı"
source "${REPO_ROOT}/lib/selfupdate.sh"      # B bölümünün taklit işlevlerini GERÇEKLERİYLE değiştirir
export SRVCTL_FM_EMERGENCY_DIR="${T}/em-dir"
out="$(_selfupdate_prepare_fm_state_dir 2>&1)"; rc=$?
assert_eq "$([[ -d "$SRVCTL_FM_EMERGENCY_DIR" ]] && echo var || echo YOK)" "var" "F1: self-update yolu gerçek işlevle dizini OLUŞTURDU"
assert_eq "$(_stat_mode "$SRVCTL_FM_EMERGENCY_DIR")" "700" "F1: dizin modu 700"
if [[ "$(id -u)" == "0" ]]; then
    assert_eq "$rc" "0" "F2: root: hazırlık başarılı → rc 0"
else
    assert_eq "$rc" "1" "F2: root olmayan kullanıcı: sahiplik doğrulaması DÜRÜSTÇE reddeder → rc 1 (sessiz geçmez)"
    assert_contains "$out" "güvenilir değil" "F2: ret nedeni a1 işlevinin iletisiyle görünür"
fi
_selfupdate_prepare_fm_state_dir >/dev/null 2>&1; rc2=$?
assert_eq "$rc2" "$rc" "F3: idempotent — ikinci çağrı aynı sonucu verir"
unset SRVCTL_FM_EMERGENCY_DIR
test_summary
