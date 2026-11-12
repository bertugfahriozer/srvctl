#!/bin/bash
# Kurulu kod ağacı sahiplik kilidi — lib/core.sh :: srvctl_harden_code_tree, lib/selfupdate.sh :: _selfupdate_harden_tree,
# install.sh.
#
# BULGU (canlıda ölçüldü, 2026-11-09): /usr/local/srvctl altında 45 yol uid 501'e (geliştiricinin macOS kimliği) aitti.
# srvctl root olarak çalışır; 501 sonradan bir hesaba tahsis edilirse o hesap root kodunu değiştirip root'a yükselir.
# KÖK NEDEN: self-update'in 'cp -f'u var olan dosyanın sahibini korur; yedek/geri yükleme 'cp -a' uid'i taşır.
#
# Test kullanıcısı root değildir → gerçek chown root:root yapamaz. Bu yüzden: (1) tests/fixtures/ownership_chown_shim.sh
# PATH'te SAHTE chown'dur (defter + çağrı günlüğü; -h'siz bağ izleme taklit edilir), (2) _stat_ugm defterden okur
# (varsayılan "501 20" = kirli kurulum), mod GERÇEKTİR (chmod gerçek çalışır).
#   A  501'li kod ağacı → 0 root olmayan yol; B state/logs/plugins/conf/srvctl.conf DOKUNULMADI;
#   C  sembolik bağ hedefi değişmez (chown -h, chmod yok); D grup/diğer-yazma biti kalkar;
#   E  chown başarısızsa rc 1 + yol listesi; F  _selfupdate_run akışı (ön + son sertleştirme, rollback, kısa devre);
#   G  geri yükleme; H  install.sh bağlantısı; I  MUTASYONLAR (chown adımı / doğrulama / run bağı çıkarılırsa KIRMIZI).
# shellcheck disable=SC1090,SC1091,SC2329,SC2016  # dinamik source (mutantlar), alt kabukta çağrılan sahte işlevler, bilinçli tek tırnak
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "${T}/shim"
cp "${REPO_ROOT}/tests/fixtures/ownership_chown_shim.sh" "${T}/shim/chown"; chmod +x "${T}/shim/chown"
export PATH="${T}/shim:${PATH}"

# Sahte kurulum ağacı (her şey kirli: defter boş → "501 20").
mk_tree() { # $1 = kök
    local r="$1"
    mkdir -p "$r"/{bin,lib,templates/nginx/sub,completions,conf,state/dom,logs,plugins/p,.backups/20260101_000000/lib}
    : > "$r/bin/srvctl"; : > "$r/lib/core.sh"; : > "$r/lib/a.sh"; : > "$r/templates/nginx/x.tpl"; : > "$r/templates/nginx/sub/y.tpl"
    : > "$r/completions/srvctl.bash"; : > "$r/.backups/20260101_000000/lib/old.sh"; : > "$r/.current-commit"
    printf 'r\n' > "$r/conf/rate-profiles.conf"; printf 'p\n' > "$r/conf/resource-profiles.conf"
    printf 'SECRET=1\n' > "$r/conf/srvctl.conf"; chmod 664 "$r/conf/srvctl.conf"
    : > "$r/state/dom/hardened"; : > "$r/logs/srvctl.log"; : > "$r/plugins/p/x.sh"
    : > "$r/state/secret"; chmod 666 "$r/state/secret"
}
code_paths() { printf '%s\n' "$1/bin" "$1/lib" "$1/templates" "$1/completions" "$1/.backups" "$1/.current-commit" "$1/conf/rate-profiles.conf" "$1/conf/resource-profiles.conf"; }
count_code() { # $1=kök → kod yollarındaki root:root olmayan yol sayısı (macOS bash 3.2'de yerleşik dizi okuma yok)
    local p; local -a a=()
    while IFS= read -r p; do a+=("$p"); done < <(code_paths "$1")
    count_foreign "${a[@]}"
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Ortak ortam: çekirdek+selfupdate kaynağı $1,$2 (mutasyonlar için değiştirilebilir); $3 = senaryo dizin adı.
# Alt kabukta çalıştırılır; sonuçlar "anahtar=değer" satırları olarak yazılır.
scn_setup() { # $1=core $2=selfupdate $3=ad
    D="${T}/$3"; mkdir -p "$D"; R="${D}/root"; mk_tree "$R"
    export OWN_LEDGER="${D}/ledger" OWN_CALLS="${D}/calls"; : > "$OWN_LEDGER"; : > "$OWN_CALLS"; unset OWN_FAIL
    export SRVCTL_ROOT="$R"
    source "$1"
    SRVCTL_ROOT="$R"
    source "$2"
    log_action() { :; }
    step() { :; }
    _stat_owner() { echo root; }
    _stat_ugm() {
        local o m
        o="$(awk -F'\t' -v p="$1" '$1==p{o=$2" "$3} END{print o}' "$OWN_LEDGER")"
        m="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" || return 1
        echo "${o:-501 20} ${m}"
    }
}
count_foreign() { # kod yolları → root:root olmayan yol sayısı (defter üzerinden)
    local n=0 p ugm u g
    while IFS= read -r -d '' p; do
        ugm="$(_stat_ugm "$p")"; read -r u g _ <<<"$ugm"
        [[ "$u" == 0 && "$g" == 0 ]] || n=$((n + 1))
    done < <(find "$@" -xdev -print0)
    echo "$n"
}
CORE="${REPO_ROOT}/lib/core.sh"; SU="${REPO_ROOT}/lib/selfupdate.sh"

echo "── A: 501'li kod ağacı → sertleştirme sonrası 0 root olmayan yol ──"
scenario_A() { # $1=core $2=su
    scn_setup "$1" "$2" A
    echo "once=$(count_code "$R")"
    _selfupdate_harden_tree; echo "rc=$?"
    echo "sonra=$(count_code "$R")"
    echo "yeni_dosya_dahil=$(count_foreign "$R/lib/a.sh" "$R/templates/nginx/sub/y.tpl" "$R/.backups/20260101_000000/lib/old.sh")"
}
out="$(scenario_A "$CORE" "$SU")"
onceA="$(sed -n 's/^once=//p' <<<"$out")"
[[ "$onceA" -gt 10 ]] && ok_pre=1 || ok_pre=0
assert_eq "$ok_pre" "1" "A: ön koşul — sertleştirme ÖNCESİ çok sayıda 501'li yol var (${onceA})"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "0" "A: _selfupdate_harden_tree rc 0"
assert_eq "$(sed -n 's/^sonra=//p' <<<"$out")" "0" "A: sertleştirme sonrası kod ağacında root:root olmayan yol SIFIR"
assert_eq "$(sed -n 's/^yeni_dosya_dahil=//p' <<<"$out")" "0" "A: iç içe şablon dizini ve .backups altı da kapsandı"

echo "── B/C/D: kapsam dışı yollar, sembolik bağ, mod bitleri ──"
scenario_BCD() {
    scn_setup "$1" "$2" BCD
    ln -s "$R/state/secret" "$R/lib/link.sh"          # kod ağacında, state'e işaret eden bağ
    ln -s "$R/state" "$R/templates/statelink"          # dizine işaret eden bağ (içine inilmemeli)
    chmod 666 "$R/lib/a.sh"; chmod 777 "$R/templates"; chmod 664 "$R/completions/srvctl.bash"; chmod 775 "$R/.backups/20260101_000000"
    _selfupdate_harden_tree; echo "rc=$?"
    echo "state_defter=$(grep -c -F "$R/state" "$OWN_LEDGER")"
    echo "diger_defter=$(grep -c -E "$R/(logs|plugins)|srvctl\.conf" "$OWN_LEDGER")"
    echo "state_secret_mod=$(mode_of "$R/state/secret")"
    echo "conf_mod=$(mode_of "$R/conf/srvctl.conf")"
    echo "state_ugm=$(_stat_ugm "$R/state/dom/hardened" | cut -d' ' -f1-2)"
    echo "conf_ugm=$(_stat_ugm "$R/conf/srvctl.conf" | cut -d' ' -f1-2)"
    echo "link_izlendi=$(grep -c 'SYMLINK-IZLENDI' "$OWN_CALLS")"
    echo "link_h=$(grep -c -E -- "^-h root:root -- ${R}/lib/link\.sh\$" "$OWN_CALLS")"
    echo "link_defter=$(grep -c -F "$(printf '%s\t' "$R/lib/link.sh")" "$OWN_LEDGER")"
    echo "mod_a=$(mode_of "$R/lib/a.sh") mod_templates=$(mode_of "$R/templates") mod_comp=$(mode_of "$R/completions/srvctl.bash") mod_bk=$(mode_of "$R/.backups/20260101_000000")"
    echo "chown_R=$(grep -c -E -- '(^| )-[a-zA-Z]*R' "$OWN_CALLS")"
}
out="$(scenario_BCD "$CORE" "$SU")"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "0" "B: rc 0"
assert_eq "$(sed -n 's/^state_defter=//p' <<<"$out")" "0" "B: state/ altına HİÇ chown yapılmadı (bağ hedefi dahil)"
assert_eq "$(sed -n 's/^diger_defter=//p' <<<"$out")" "0" "B: logs/, plugins/, conf/srvctl.conf'a chown yapılmadı"
assert_eq "$(sed -n 's/^state_ugm=//p' <<<"$out")" "501 20" "B: state/ sahipliği DEĞİŞMEDİ"
assert_eq "$(sed -n 's/^conf_ugm=//p' <<<"$out")" "501 20" "B: conf/srvctl.conf sahipliği DEĞİŞMEDİ"
assert_eq "$(sed -n 's/^conf_mod=//p' <<<"$out")" "664" "B: conf/srvctl.conf modu DEĞİŞMEDİ (kapsam dışı)"
assert_eq "$(sed -n 's/^state_secret_mod=//p' <<<"$out")" "666" "C: bağ hedefi (state/secret) modu DEĞİŞMEDİ (chmod bağı izlemedi)"
assert_eq "$(sed -n 's/^link_izlendi=//p' <<<"$out")" "0" "C: chown hiçbir sembolik bağı İZLEMEDİ"
assert_eq "$(sed -n 's/^link_h=//p' <<<"$out")" "1" "C: bağın KENDİSİ 'chown -h' ile düzeltildi"
assert_eq "$(sed -n 's/^link_defter=//p' <<<"$out")" "1" "C: defterde bağın kendisi root:root"
assert_eq "$(sed -n 's/^chown_R=//p' <<<"$out")" "0" "C: özyinelemeli chown (-R) kullanılmadı"
assert_eq "$(sed -n 's/^mod_a=//p' <<<"$out")" "644 mod_templates=755 mod_comp=644 mod_bk=755" "D: grup/diğer yazma bitleri kalktı (666→644, 777→755, 664→644, 775→755)"

echo "── E: chown başarısız → rc 1 + kalan yollar uyarıda ──"
scenario_E() {
    scn_setup "$1" "$2" E
    export OWN_FAIL=1
    _selfupdate_harden_tree 2>"${D}/err"; echo "rc=$?"
    echo "uyari=$(grep -c "root:root olmayan" "${D}/err")"
    echo "yol=$(grep -c -F "$R/lib/a.sh" "${D}/err")"
}
out="$(scenario_E "$CORE" "$SU")"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "1" "E: onarılamayan yol varsa rc 1"
assert_eq "$(sed -n 's/^uyari=//p' <<<"$out")" "1" "E: açık güvenlik uyarısı basıldı"
assert_eq "$(sed -n 's/^yol=//p' <<<"$out")" "1" "E: kalan yol adıyla listelendi"

echo "── F: _selfupdate_run akışı ──"
scenario_F() { # $1=core $2=su $3=mod: ok | postfail | prefail
    scn_setup "$1" "$2" "F$3"
    MODE="$3"
    SEQ="${D}/seq"; : > "$SEQ"
    git() { return 0; }
    _selfupdate_validate_repo_url() { return 0; }
    _selfupdate_assert_pin_owned() { return 0; }
    _selfupdate_warn_if_pin_stale() { :; }
    _selfupdate_backup_current() { echo yedek >> "$SEQ"; echo "${D}/backup"; }
    _selfupdate_fetch_pinned() { return 0; }
    _selfupdate_verify_tag_signature() { :; }
    _selfupdate_prune_backups() { :; }
    _selfupdate_offer_fm_root() { :; }
    _selfupdate_prepare_fm_state_dir() { :; }
    _selfupdate_health_check() { echo saglik >> "$SEQ"; return 0; }
    _selfupdate_restore_from_backup() { echo geri-al >> "$SEQ"; return 0; }
    _selfupdate_install_from_staging() {
        echo kurulum >> "$SEQ"
        if [[ "$MODE" == postfail ]]; then : > "$R/lib/yeni.sh"; export OWN_FAIL=1; fi   # staging'den gelen yeni dosya, chown artık çalışmıyor
    }
    printf 'PINNED_COMMIT=%s\nPINNED_AT=x\nPINNED_REPO=%s\n' "$(printf 'a%.0s' $(seq 1 40))" "$SRVCTL_REPO" > "$SRVCTL_SELFUPDATE_PIN"
    if [[ "$MODE" == postfail ]]; then _selfupdate_harden_tree; fi         # kurulum kirli değil: ön sertleştirme geçsin
    if [[ "$MODE" == prefail ]]; then export OWN_FAIL=1; fi
    ( _selfupdate_run ) > "${D}/run.out" 2>&1; echo "rc=$?"
    echo "seq=$(tr '\n' ' ' < "$SEQ")"
    echo "yabanci=$(count_code "$R")"
}
out="$(scenario_F "$CORE" "$SU" ok)"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "0" "F1: kirli kurulumda güncelleme başarılı (rc 0)"
assert_eq "$(sed -n 's/^seq=//p' <<<"$out")" "yedek kurulum saglik " "F1: sıra yedek → kurulum → sağlık"
assert_eq "$(sed -n 's/^yabanci=//p' <<<"$out")" "0" "F1: güncelleme sonrası kod ağacında root:root olmayan yol SIFIR"
out="$(scenario_F "$CORE" "$SU" prefail)"
assert_eq "$(sed -n 's/^seq=//p' <<<"$out")" "" "F2: ön sertleştirme başarısız → yedek bile alınmadı, hiçbir adım başlamadı"
[[ "$(sed -n 's/^rc=//p' <<<"$out")" != 0 ]] && r=1 || r=0
assert_eq "$r" "1" "F2: ön sertleştirme başarısız → rc ≠ 0"
out="$(scenario_F "$CORE" "$SU" postfail)"
assert_eq "$(sed -n 's/^seq=//p' <<<"$out")" "yedek kurulum geri-al " "F3: kurulum sonrası sahiplik doğrulanamadı → sağlık kontrolü (kod çalıştırma) ATLANDI, rollback"
[[ "$(sed -n 's/^rc=//p' <<<"$out")" != 0 ]] && r=1 || r=0
assert_eq "$r" "1" "F3: güncelleme başarısız sayıldı (rc ≠ 0)"

echo "── G: geri yükleme yedeğin uid'ini geri taşımaz ──"
scenario_G() { # $1=core $2=su $3=fail?
    scn_setup "$1" "$2" "G$3"
    B="${D}/bk"; mkdir -p "$B"/{bin,lib,templates/nginx,completions,conf}
    : > "$B/bin/srvctl"; : > "$B/lib/old.sh"; : > "$B/templates/nginx/o.tpl"; : > "$B/completions/c"; : > "$B/conf/rate-profiles.conf"
    [[ "$3" == fail ]] && export OWN_FAIL=1
    _selfupdate_restore_from_backup "$B" 2>/dev/null; echo "rc=$?"
    echo "yabanci=$(count_code "$R")"
}
out="$(scenario_G "$CORE" "$SU" ok)"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "0" "G1: geri yükleme rc 0"
assert_eq "$(sed -n 's/^yabanci=//p' <<<"$out")" "0" "G1: geri yüklenen ağaçta root:root olmayan yol SIFIR"
out="$(scenario_G "$CORE" "$SU" fail)"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "1" "G2: sahiplik kurulamazsa geri yükleme başarısız (rc 1)"

echo "── H: install.sh bağlantısı (kök gerektirdiğinden yapısal) ──"
INST="$(cat "${REPO_ROOT}/install.sh")"
assert_contains "$INST" 'chown -hR root:root "${INSTALL_DIR}"' "H: install.sh chown -hR (bağlar izlenmez)"
assert_contains "$INST" 'srvctl_harden_code_tree "$1" conf/rate-profiles.conf conf/resource-profiles.conf' "H: install.sh kod ağacı kilidini çağırır"
assert_contains "$INST" 'kurulum başarısız.' "H: kilit başarısızsa kurulum başarısız sayılır"
pos_chown="$(grep -n 'chown -hR root:root' "${REPO_ROOT}/install.sh" | head -1 | cut -d: -f1)"
pos_gate="$(grep -n 'srvctl_harden_code_tree' "${REPO_ROOT}/install.sh" | head -1 | cut -d: -f1)"
pos_ok="$(grep -n 'srvctl başarıyla kuruldu' "${REPO_ROOT}/install.sh" | head -1 | cut -d: -f1)"
[[ "$pos_chown" -lt "$pos_gate" && "$pos_gate" -lt "$pos_ok" ]] && r=1 || r=0
assert_eq "$r" "1" "H: sıra chown → kilit → başarı bildirimi"
SUS="$(cat "$SU")"
assert_contains "$SUS" 'srvctl_harden_code_tree "$SRVCTL_ROOT"' "H: self-update aynı tek işlevi kullanır"

echo "── I: MUTASYONLAR — koruma çıkarılırsa test KIRMIZI ──"
# Metinsel mutasyonlar (sed -i yok; bash 3.2'de büyük dizede ${//} ikinci dereceden yavaş → perl, değişim yapılmazsa hata)
mutate() { # $1=kaynak dosya $2=eski $3=yeni $4=hedef dosya
    OLD="$2" NEW="$3" perl -0777 -pe 'BEGIN{$o=$ENV{OLD};$n=$ENV{NEW};$c=0} $c += s/\Q$o\E/$n/; END{exit($c?0:3)}' "$1" > "$4" \
        || { echo "MUTASYON UYGULANAMADI: $2" >&2; return 1; }
}
mkdir -p "${T}/mut"
# I1: chown adımı kaldırılır
mutate "$CORE" '[[ "$uid" == 0 && "$gid" == 0 ]] || chown -h root:root -- "$p" 2>/dev/null || true' ':' "${T}/mut/core_nochown.sh"
out="$(scenario_A "${T}/mut/core_nochown.sh" "$SU")"
assert_eq "$(sed -n 's/^sonra=//p' <<<"$out")" "$onceA" "I1: chown adımı kaldırılınca 501'li yollar KALIR (A testi kırmızı olurdu); doğrulama bunu yakalar → rc"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "1" "I1: chown adımı yokken doğrulama rc 1 verir (sessiz başarı YOK)"
# I2: chmod go-w kaldırılır
mutate "$CORE" 'chmod go-w -- "$p" 2>/dev/null || true' ':' "${T}/mut/core_nochmod.sh"
out="$(scenario_BCD "${T}/mut/core_nochmod.sh" "$SU")"
assert_eq "$(sed -n 's/^mod_a=//p' <<<"$out")" "666 mod_templates=777 mod_comp=664 mod_bk=775" "I2: chmod adımı kaldırılınca modlar değişmez (D testi kırmızı olurdu)"
# I3: -h kaldırılır → bağ izlenir
mutate "$CORE" 'chown -h root:root' 'chown root:root' "${T}/mut/core_noh.sh"
out="$(scenario_BCD "${T}/mut/core_noh.sh" "$SU")"
[[ "$(sed -n 's/^link_izlendi=//p' <<<"$out")" -gt 0 ]] && r=1 || r=0
assert_eq "$r" "1" "I3: '-h' kaldırılınca chown bağı İZLER (C testi kırmızı olurdu)"
# I4: doğrulama (check geçişi) sessizce 0 döner
mutate "$CORE" 'left="$(_srvctl_code_tree_pass check "${paths[@]}")" && return 0' 'left="" && return 0' "${T}/mut/core_nocheck.sh"
out="$(scenario_E "${T}/mut/core_nocheck.sh" "$SU")"
assert_eq "$(sed -n 's/^rc=//p' <<<"$out")" "0" "I4: doğrulama kaldırılınca başarısız chown sessizce 'başarı' olur (E testi kırmızı olurdu)"
# I5: run'daki kurulum-sonrası sertleştirme kaldırılır
mutate "$SU" 'if _selfupdate_harden_tree; then tree_ok=1; fi' 'tree_ok=1' "${T}/mut/su_nopost.sh"
out="$(scenario_F "$CORE" "${T}/mut/su_nopost.sh" postfail)"
assert_eq "$(sed -n 's/^seq=//p' <<<"$out")" "yedek kurulum saglik " "I5: son sertleştirme kaldırılınca sağlık kontrolü (kod çalıştırma) sahiplik doğrulanmadan koşar (F3 kırmızı olurdu)"
# I6: ön sertleştirme kaldırılır
mutate "$SU" '|| error "GÜVENLİK: kurulu kod ağacının sahipliği root:root'"'"'a çekilemedi — güncelleme başlatılmadı."' '|| true' "${T}/mut/su_nopre.sh"
out="$(scenario_F "$CORE" "${T}/mut/su_nopre.sh" prefail)"
[[ "$(sed -n 's/^seq=//p' <<<"$out")" == *yedek* ]] && r=1 || r=0
assert_eq "$r" "1" "I6: ön kapı kaldırılınca başarısız sertleştirmeye rağmen yedek/kurulum başlar (F2 kırmızı olurdu)"
# I7: restore sonundaki sertleştirme kaldırılır
mutate "$SU" '_selfupdate_harden_tree || { warn "Geri yükleme sonrası kod ağacı sahipliği doğrulanamadı."; return 1; }' ':' "${T}/mut/su_norestore.sh"
out="$(scenario_G "$CORE" "${T}/mut/su_norestore.sh" ok)"
[[ "$(sed -n 's/^yabanci=//p' <<<"$out")" -gt 0 ]] && r=1 || r=0
assert_eq "$r" "1" "I7: geri yükleme sertleştirmesi kaldırılınca 501'li yollar geri döner (G1 kırmızı olurdu)"

test_summary
