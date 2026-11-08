#!/bin/bash
# shellcheck disable=SC2034,SC2317,SC2329  # fm_env.sh bayrakları; işlevler dolaylı çağrılır
# F9e-9 — ci4ms worker/scheduler varyant tespiti: `_domain_ci4_has_command` (release içindeki modules/*/Commands/*.php dosyalarında
# `$name = 'komut'` atamasını STATİK arar), `_domain_worker_cmd` / `_domain_scheduler_cmd` varyantları ve iki unit üreticisinin seçimi.
#  - varyant VAR (Commands/Worker.php 'ci4ms:worker', Commands/Run.php 'cronjobs:run') → ci4ms komutları
#  - varyant YOK / BOŞ release (modules yok, Commands yok) → rc 1; worker üretilmez (ci4 için varsayılan worker yok), scheduler 'tasks:run'
#  - yorum satırı, `$usage` ve başka komut adı eşleşmez; modules sembolik bağsa ret; geçersiz komut adı ret
# Ayrıcalık düşürme (setpriv/runuser/su) testte yok: `_domain_run_as_web_user` test seam'i (komutu olduğu gibi çalıştırır).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/fm_env.sh"
source "${REPO_ROOT}/lib/domain.sh"
set +e
_domain_run_as_web_user() { shift; "$@"; }

TMO=$(_domain_timeout_bin)
mk() {   # mk <alan> <modül> <dosya> <içerik>: release ağacında modules/<modül>/Commands/<dosya>
    local m="${WEB_ROOT}/$1/current/modules/$2/Commands"
    mkdir -p "$m"; printf '%s' "$4" > "${m}/$3"
}
php_cmd() { printf '<?php\nclass C\n{\n    %s\n}\n' "$1"; }

if [[ -z "$TMO" ]]; then
    echo "── timeout/gtimeout yok: güvenli geri çekilme sınanır, varyant dalları ATLANDI ──"
    mk w1.example Backend Worker.php "$(php_cmd "protected \$name = 'ci4ms:worker';")"
    _domain_ci4_has_command w1.example ci4ms:worker; assert_eq "$?" "1" "timeout aracı yok → rc 1 (varyant seçilmez, eski davranış korunur)"
    test_summary
    exit 0
fi

# ── boş release ──
_domain_ci4_has_command empty.example ci4ms:worker; assert_eq "$?" "1" "release YOK (modules dizini yok): ci4ms:worker rc 1"
mkdir -p "${WEB_ROOT}/nomod.example/current"
_domain_ci4_has_command nomod.example ci4ms:worker; assert_eq "$?" "1" "release var ama modules/ yok: rc 1"
mkdir -p "${WEB_ROOT}/emptymods.example/current/modules/Backend"
_domain_ci4_has_command emptymods.example ci4ms:worker; assert_eq "$?" "1" "modules/ var ama Commands/ yok: rc 1"
mkdir -p "${WEB_ROOT}/emptycmd.example/current/modules/Backend/Commands"
_domain_ci4_has_command emptycmd.example ci4ms:worker; assert_eq "$?" "1" "Commands/ var ama boş: rc 1"
_domain_ci4_has_command emptycmd.example cronjobs:run; assert_eq "$?" "1" "Commands/ boş: cronjobs:run rc 1"

# ── varyant VAR ──
mk w.example Backend Worker.php "$(php_cmd "protected \$name = 'ci4ms:worker';")"
mk w.example Cronjobs Run.php "$(php_cmd "protected \$name = \"cronjobs:run\";")"
_domain_ci4_has_command w.example ci4ms:worker; assert_eq "$?" "0" "Commands/Worker.php \$name = 'ci4ms:worker' (tek tırnak): rc 0"
_domain_ci4_has_command w.example cronjobs:run; assert_eq "$?" "0" "Commands/Run.php \$name = \"cronjobs:run\" (çift tırnak): rc 0"
_domain_ci4_has_command w.example tasks:run; assert_eq "$?" "1" "ağaçta olmayan başka komut adı: rc 1"
mk vis.example Backend Worker.php "$(php_cmd "public \$name   =   'ci4ms:worker';")"
_domain_ci4_has_command vis.example ci4ms:worker; assert_eq "$?" "0" "görünürlük + serbest boşluk (public \$name   =   '…'): rc 0"

# ── eşleşmemesi gerekenler ──
mk c.example Backend Worker.php "$(php_cmd "// \$name = 'ci4ms:worker';")"
_domain_ci4_has_command c.example ci4ms:worker; assert_eq "$?" "1" "yorum satırındaki atama eşleşmez"
mk u.example Backend Worker.php "$(php_cmd "protected \$usage = 'ci4ms:worker';")"
_domain_ci4_has_command u.example ci4ms:worker; assert_eq "$?" "1" "\$usage içindeki komut adı eşleşmez"
mk p.example Backend Worker.php "$(php_cmd "protected \$name = 'ci4ms:worker-extra';")"
_domain_ci4_has_command p.example ci4ms:worker; assert_eq "$?" "1" "önek eşleşmesi: 'ci4ms:worker-extra' != 'ci4ms:worker'"
mkdir -p "${WEB_ROOT}/ncmd.example/current/modules/Backend/Other"
printf '%s' "$(php_cmd "protected \$name = 'ci4ms:worker';")" > "${WEB_ROOT}/ncmd.example/current/modules/Backend/Other/Worker.php"
_domain_ci4_has_command ncmd.example ci4ms:worker; assert_eq "$?" "1" "Commands/ dışındaki dosya aranmaz"
mkdir -p "${WEB_ROOT}/txt.example/current/modules/Backend/Commands"
printf '%s' "$(php_cmd "protected \$name = 'ci4ms:worker';")" > "${WEB_ROOT}/txt.example/current/modules/Backend/Commands/Worker.txt"
_domain_ci4_has_command txt.example ci4ms:worker; assert_eq "$?" "1" "yalnız *.php dosyaları aranır"

# ── güvenlik ──
_domain_ci4_has_command w.example 'x;y'; assert_eq "$?" "1" "geçersiz komut adı (x;y): rc 1"
_domain_ci4_has_command w.example 'ci4ms worker'; assert_eq "$?" "1" "geçersiz komut adı (boşluk): rc 1"
_domain_ci4_has_command w.example ''; assert_eq "$?" "1" "boş komut adı: rc 1"
mkdir -p "${WEB_ROOT}/lnk.example/current" "${FM_STUBS}/elsewhere/Backend/Commands"
printf '%s' "$(php_cmd "protected \$name = 'ci4ms:worker';")" > "${FM_STUBS}/elsewhere/Backend/Commands/Worker.php"
ln -s "${FM_STUBS}/elsewhere" "${WEB_ROOT}/lnk.example/current/modules"
_domain_ci4_has_command lnk.example ci4ms:worker; assert_eq "$?" "1" "modules/ sembolik bağ: REDDEDİLİR (rc 1)"
mkdir -p "${WEB_ROOT}/inner.example/current/modules/Backend/Commands"
ln -s "${FM_STUBS}/elsewhere/Backend/Commands/Worker.php" "${WEB_ROOT}/inner.example/current/modules/Backend/Commands/Worker.php"
_domain_ci4_has_command inner.example ci4ms:worker; assert_eq "$?" "1" "ağaç içindeki dosya sembolik bağı izlenmez (find -P -type f)"
mkdir -p "${WEB_ROOT}/big.example/current/modules/Backend/Commands"
{ php_cmd "protected \$name = 'ci4ms:worker';"; head -c 600000 /dev/zero | tr '\0' ' '; } > "${WEB_ROOT}/big.example/current/modules/Backend/Commands/Worker.php"
_domain_ci4_has_command big.example ci4ms:worker; assert_eq "$?" "1" "512k üstü dosya aranmaz (-size tavanı)"

# ── komut üreticileri ──
PHPB=/usr/bin/php8.3
assert_eq "$(_domain_worker_cmd ci4 "$PHPB" ci4ms)" "$PHPB spark ci4ms:worker" "worker ci4 + ci4ms varyantı: spark ci4ms:worker"
_domain_worker_cmd ci4 "$PHPB" >/dev/null 2>&1; assert_eq "$?" "1" "worker ci4 + varyant YOK: rc 1 (genel CI4'ün kuyruğu yok)"
assert_eq "$(_domain_worker_cmd ci4 "$PHPB" 2>/dev/null)" "" "worker ci4 + varyant YOK: stdout BOŞ"
assert_contains "$(_domain_worker_cmd ci4 "$PHPB" 2>&1 >/dev/null)" "ci4ms:worker" "worker ci4 + varyant YOK: uyarı komutun release'de bulunamadığını söyler"
assert_eq "$(_domain_worker_cmd laravel "$PHPB")" "$PHPB artisan queue:work --sleep=3 --tries=3" "worker laravel değişmedi"
assert_eq "$(_domain_scheduler_cmd ci4 "$PHPB" cronjobs)" "$PHPB spark cronjobs:run" "scheduler ci4 + cronjobs varyantı: spark cronjobs:run"
assert_eq "$(_domain_scheduler_cmd ci4 "$PHPB")" "$PHPB spark tasks:run" "scheduler ci4 + varyant YOK: eski spark tasks:run (geriye uyum)"
assert_eq "$(_domain_scheduler_cmd laravel "$PHPB")" "$PHPB artisan schedule:run" "scheduler laravel değişmedi"

# ── unit üreticilerinin seçimi (release → varyant → unit dosyası) ──
SRVCTL_SYSTEMD_DIR="$(mktemp -d)"; export SRVCTL_SYSTEMD_DIR
_FM_ENV_DIRS="${_FM_ENV_DIRS}"$'\n'"${SRVCTL_SYSTEMD_DIR}"
systemctl() { return 0; }
FW=ci4
_domain_unit_common_ctx() { printf '%s %s %s %s\n' "$(safe_name "$1")" "web_$(safe_name "$1")" "$PHPB" "$FW"; }
_domain_render_worker_unit w.example >/dev/null 2>&1; assert_eq "$?" "0" "worker unit: ci4ms varyantı olan release → rc 0"
assert_eq "$(grep -c "spark ci4ms:worker" "${SRVCTL_SYSTEMD_DIR}/srvctl-worker-w_example@.service")" "1" "worker unit: ExecStart 'spark ci4ms:worker' içerir"
_domain_render_worker_unit empty.example >/dev/null 2>&1; assert_eq "$?" "1" "worker unit: BOŞ release → rc 1 (komut yok; crash-loop'lu unit üretilmez)"
assert_eq "$([[ -e "${SRVCTL_SYSTEMD_DIR}/srvctl-worker-empty_example@.service" ]] && echo VAR || echo yok)" "yok" "worker unit: BOŞ release için unit dosyası YAZILMADI"
_domain_render_scheduler_unit w.example >/dev/null 2>&1; assert_eq "$?" "0" "scheduler unit: cronjobs varyantı olan release → rc 0"
assert_eq "$(grep -c "^ExecStart=.* spark cronjobs:run\$" "${SRVCTL_SYSTEMD_DIR}/srvctl-scheduler-w_example.service")" "1" "scheduler unit: ExecStart 'spark cronjobs:run' içerir"
_domain_render_scheduler_unit empty.example >/dev/null 2>&1; assert_eq "$?" "0" "scheduler unit: BOŞ release → rc 0 (geriye uyum: tasks:run)"
assert_eq "$(grep -c "^ExecStart=.* spark tasks:run\$" "${SRVCTL_SYSTEMD_DIR}/srvctl-scheduler-empty_example.service")" "1" "scheduler unit: BOŞ release ExecStart 'spark tasks:run' içerir"
FW=laravel
_domain_render_worker_unit lv.example >/dev/null 2>&1; assert_eq "$?" "0" "worker unit: laravel varyantsız → rc 0 (ci4 dalı değişmedi)"
test_summary
