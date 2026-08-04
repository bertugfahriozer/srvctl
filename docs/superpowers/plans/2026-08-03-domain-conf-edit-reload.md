# `domain reload` + per-domain `.ini` / nginx `.conf` düzenleme — Uygulama Planı

> **Agentic worker'lar için:** ZORUNLU ALT-SKILL: Bu planı task-task uygulamak için `superpowers:subagent-driven-development` (önerilen) veya `superpowers:executing-plans` kullan. Adımlar takip için checkbox (`- [ ]`) sözdizimi kullanır.

**Hedef:** Operatörün per-domain PHP ve nginx ayarlarını, bir sonraki `repair`de sessizce kaybolmayacak biçimde düzenleyebilmesi ve doğru FPM unit'ini tek komutla reload edebilmesi.

**Mimari:** Kullanıcı girdisinin *kaynağı* render'ın dışında (`/etc/srvctl/php.d/<sname>.ini`, `/etc/nginx/custom.d/<sname>/00-custom.conf`), *uygulanması* render'ın içinde. Böylece pool/vhost üreten her yol (add, repair, php-switch, harden-fpm) override'ları otomatik yeniden uygular. Yeni komutlar `lib/domconf.sh`'ta; ortak servis helper'ları `lib/core.sh`'ta.

**Tech Stack:** Bash 5.x, systemd, php-fpm, nginx. Test harness: `tests/lib.sh` (saf bash assert'ler, harici bağımlılık yok).

**Spec:** [2026-08-03-domain-conf-edit-reload-design.md](../specs/2026-08-03-domain-conf-edit-reload-design.md)

## Global Constraints

- **Tüm kullanıcıya görünen metin ve tüm kod yorumları Türkçe.** İstisnasız.
- Her script `set -euo pipefail` ile çalışır; hata dönmesi beklenen komutlara `|| true` eklenir.
- `error` **exit eder**; `warn` **stderr**'e, `info`/`success` **stdout**'a yazar.
- `nginx_test` (core.sh) başarısızlıkta `error` ile **exit eder** — döngü içinde kullanılamaz; toplu akışta doğrudan `nginx -t` çağrılır.
- Yeni sabit yollar test seam'i üzerinden okunur: `${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}`, `${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}`, mevcut `${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}`, `${SITES_AVAILABLE:-/etc/nginx/sites-available}`.
- Yeni fonksiyon adlandırması: `lib/domconf.sh` içindekiler `_domconf_<eylem>`, `lib/domain.sh` içindekiler `_domain_<eylem>`, `lib/core.sh` içindekiler `_` öneki olmadan (paylaşılan kontrat).
- Testler `bash tests/test_<ad>.sh` ile tek tek, `bash tests/run.sh` ile toplu koşar. Her test `set -uo pipefail` (yalnız `-e` **yok** — assert'ler hata döndürebilmeli) ile başlar.
- **`assert_ok` / `assert_fail` mesaj parametresi ALMAZ.** `tests/lib.sh`'taki implementasyon `if "$@"` ile **tüm** argümanları komut olarak çalıştırır. Sonuna mesaj eklemek onu test edilen fonksiyona argüman olarak geçirir — `_domconf_edit_ini` gibi son konumsal argümanı `domain` sayan fonksiyonlarda bu, testi **sessizce yanlış şeyi ölçer** hale getirir (`test -f X "mesaj"` ise "too many arguments" ile patlar). Mesaj gerektiğinde çıkış kodunu yakala:
  ```bash
  komut arg1 arg2 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "açıklayıcı mesaj"
  ```
  Argüman almayan predikatlarda (`declare -F x`, `test -d "$dir"`) mesajsız `assert_ok` kullanmak sorunsuzdur — mevcut testlerin baskın deseni bu.
- Her commit mesajı `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` satırıyla biter.
- **macOS'ta uygulanıyor.** `systemctl`, `php-fpm`, `nginx` yok — testler bunları fonksiyon override ile mock'lar. Gerçek servis davranışı Task 10'daki HOST kontrol listesine bırakılır.

---

## Dosya yapısı

| Dosya | Sorumluluk |
|---|---|
| `lib/core.sh` (mevcut) | `domain_fpm_unit`, `reload_domain_fpm`, `parse_php_ini_overrides` — hem `domain.sh` hem `domconf.sh` tarafından kullanılan paylaşılan kontrat |
| `lib/domconf.sh` (**yeni**) | Kullanıcı arayüzü: `_domconf_reload`, `_domconf_edit_ini`, `_domconf_edit_nginx`, tarama ve rapor fonksiyonları |
| `lib/domain.sh` (mevcut) | `_domain_render_php_overrides` + `_domain_render_fpm_unit` filtreleme; dispatcher case; yaşam döngüsü kancaları |
| `lib/deploy.sh` (mevcut) | `_deploy_reload_fpm` core.sh helper'larına indirgenir |
| `templates/nginx/vhost.conf.tpl`, `vhost-ssl.conf.tpl` | `custom.d` include satırı |

`parse_php_ini_overrides` **core.sh'a** konur, `domconf.sh`'a değil: hem `domain.sh`'ın render'ı hem `domconf.sh`'ın doğrulaması aynı parse'a ihtiyaç duyar, ve `_load_and_run` yalnız tek modül source ettiği için `domain.sh → domconf.sh` yönünde bir zorunlu bağımlılık yaratmak istemiyoruz (exit 127 sınıfı hata riski).

---

### Task 1: core.sh — FPM unit çözümleme ve reload

**Files:**
- Modify: `lib/core.sh` (dosya sonuna, `_derive_php`'den sonra)
- Test: `tests/test_domain_fpm_unit_resolve.sh`

**Interfaces:**
- Produces:
  - `domain_fpm_unit <sname> <php_version>` → stdout'a unit adı (`srvctl-fpm-<sname>.service` veya `php<ver>-fpm`), her zaman exit 0
  - `reload_domain_fpm <sname> <php_version>` → PREDİKAT: 0=servis ayakta, 1=değil. Çağıran fail-closed davranmalı (`error`)
- Consumes: `safe_name` (mevcut), `warn` (mevcut)

**Neden sname, domain değil:** `_deploy_reload_fpm`'in mevcut çağrı biçimi `(php_version, sname)`. `domain` alsaydık `_derive_php` → `read_credentials` zincirini tetiklerdik; o zincir global değişkenleri (`DB_PASS` vb.) ezer ve reload gibi masum bir işlemde istenmeyen bir yan etkidir.

- [ ] **Step 1: Testi yaz (başarısız olacak)**

`tests/test_domain_fpm_unit_resolve.sh`:

```bash
#!/bin/bash
# domain_fpm_unit / reload_domain_fpm — hangi unit hedefleniyor ve reload
# başarısızlığı fail-closed mı?
#
# KÖK NEDEN (bkz. lib/deploy.sh:_deploy_reload_fpm host bulgusu): izole FPM'li
# bir kurulumda paylaşılan php<ver>-fpm servisi havuzsuz kaldığı için BİLEREK
# durdurulmuştur. Yanlış unit'i reload etmek sessizce başarısız olur ve
# opcache.validate_timestamps=0 yüzünden site SÜRESİZ eski bytecode servis eder.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

# ─── systemctl mock ───
# MOCK_ISOLATED=1 → izole unit systemd'ye kayıtlı görünür
# MOCK_RELOAD_RC / MOCK_RESTART_RC / MOCK_ACTIVE_RC → ilgili alt komutun rc'si
MOCK_ISOLATED=0; MOCK_RELOAD_RC=0; MOCK_RESTART_RC=0; MOCK_ACTIVE_RC=0
systemctl() {
    case "$1" in
        list-units)
            [[ "$MOCK_ISOLATED" == "1" ]] && echo "srvctl-fpm-example_com.service loaded active running"
            return 0 ;;
        reload)  return "$MOCK_RELOAD_RC" ;;
        restart) return "$MOCK_RESTART_RC" ;;
        is-active) return "$MOCK_ACTIVE_RC" ;;
    esac
    return 0
}

echo "── Bölüm A: unit çözümleme ──"
MOCK_ISOLATED=1
assert_eq "$(domain_fpm_unit example_com 8.3)" "srvctl-fpm-example_com.service" \
    "izole unit kayıtlıysa o seçilir"
MOCK_ISOLATED=0
assert_eq "$(domain_fpm_unit example_com 8.3)" "php8.3-fpm" \
    "izole unit yoksa paylaşılan servise düşer"

echo "── Bölüm B: reload fail-closed ──"
MOCK_ISOLATED=1; MOCK_RELOAD_RC=0; MOCK_ACTIVE_RC=0
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "reload başarılı + aktif → 0"

MOCK_RELOAD_RC=1; MOCK_RESTART_RC=0; MOCK_ACTIVE_RC=0
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "reload başarısız → restart kurtarır → 0"

MOCK_RELOAD_RC=1; MOCK_RESTART_RC=1
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reload+restart başarısız → 1"

# EN KRİTİK: reload 0 döner ama servis AKTİF DEĞİL (sessiz başarısızlık).
# Bu tam olarak 'süresiz eski bytecode' senaryosu — restart'a düşülmeli.
MOCK_RELOAD_RC=0; MOCK_ACTIVE_RC=1; MOCK_RESTART_RC=1
reload_domain_fpm example_com 8.3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reload rc=0 ama is-active başarısız → 1"

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_domain_fpm_unit_resolve.sh`
Expected: FAIL — `domain_fpm_unit: command not found`

- [ ] **Step 3: Minimal implementasyonu yaz**

`lib/core.sh` sonuna:

```bash
# ───────────────────────────────────────────────────────────────
#  Per-domain FPM servis katmanı (paylaşılan kontrat)
#
#  HOST BULGUSU (gerçek Laravel deploy'u, Ubuntu 22.04 — lib/deploy.sh'tan
#  taşındı): izole domainde (DOMAIN_ISOLATED_FPM=true — varsayılan) paylaşılan
#  php<ver>-fpm servisi havuzsuz kaldığı için BİLEREK durdurulmuş durumdadır;
#  onu reload/restart etmek başarısız olur. Domain'in GERÇEKTEN kullandığı
#  unit'i hedeflemek gerekir.
#
#  sname/php_version alır, domain ALMAZ: domain alsaydık _derive_php →
#  read_credentials zinciri tetiklenir, o da DB_PASS/REDIS_PASS gibi global
#  değişkenleri ezerdi (bkz. read_credentials başlık yorumu, O2 düzeltmesi).
# ───────────────────────────────────────────────────────────────
domain_fpm_unit() {
    local sname="$1" php_version="$2"
    local iso="srvctl-fpm-${sname}.service"
    if systemctl list-units --all --plain --no-legend "$iso" 2>/dev/null | grep -q .; then
        printf '%s\n' "$iso"
    else
        printf 'php%s-fpm\n' "$php_version"
    fi
}

# reload → başarısızsa restart → her iki durumda da is-active TEYİDİ.
# PREDİKAT: 0=servis ayakta, 1=değil. Çağıran fail-closed davranmalıdır.
#
# is-active teyidi neden şart: lib/init.sh 'opcache.validate_timestamps = 0'
# set eder. 'systemctl reload' sıfır dönüp servis yine de ölmüşse worker'lar
# YENİ kodu ASLA görmez ve site SÜRESİZ eski bytecode servis eder — komutun
# hata vermemesi yeterli kanıt DEĞİLDİR.
reload_domain_fpm() {
    local sname="$1" php_version="$2"
    local unit; unit=$(domain_fpm_unit "$sname" "$php_version")

    if systemctl reload "$unit" 2>/dev/null; then
        systemctl is-active --quiet "$unit" && return 0
        warn "${unit} reload sıfır döndü ama servis aktif değil — 'restart' deneniyor..."
    else
        warn "${unit} reload başarısız — 'restart' deneniyor..."
    fi

    if systemctl restart "$unit" 2>/dev/null && systemctl is-active --quiet "$unit"; then
        warn "${unit} restart ile kurtarıldı — reload'un neden başarısız olduğu araştırılmalı (systemctl status ${unit})"
        return 0
    fi
    return 1
}
```

- [ ] **Step 4: Testi koş, geçtiğini doğrula**

Run: `bash tests/test_domain_fpm_unit_resolve.sh`
Expected: PASS — tüm assert'ler geçmeli (test_summary FAIL=0 basmalı)

- [ ] **Step 5: Commit**

```bash
git add lib/core.sh tests/test_domain_fpm_unit_resolve.sh
git commit -m "core: FPM unit çözümleme + fail-closed reload helper'ları

Doğru unit'i hedeflemek uzman bilgisi gerektiriyordu; izole kurulumda
'systemctl reload php8.3-fpm' sessizce hiçbir şey yapmıyor. is-active
teyidi opcache.validate_timestamps=0 yüzünden zorunlu.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: deploy.sh'ı core.sh helper'larına indirge

**Files:**
- Modify: `lib/deploy.sh:1198-1222` (`_deploy_reload_fpm` gövdesi)

**Interfaces:**
- Consumes: `reload_domain_fpm` (Task 1)
- Produces: davranış değişikliği **yok** — `_deploy_reload_fpm <php_version> <sname>` imzası ve `error` ile exit davranışı aynı kalır

**Bu bir davranış değişikliği değil, tekilleştirme.** Mevcut host-bulgusu yorumları Task 1'de core.sh'a taşındı; burada kalan yorum onlara işaret eder.

- [ ] **Step 1: Mevcut davranışın regresyon testini yaz**

`tests/test_deploy_reload_fpm_delegation.sh`:

```bash
#!/bin/bash
# _deploy_reload_fpm artık core.sh'a delege ediyor — SÖZLEŞMESİ değişmedi:
# (php_version, sname) alır ve başarısızlıkta error ile EXIT eder.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

MOCK_RC=0
reload_domain_fpm() { return "$MOCK_RC"; }
source "${REPO_ROOT}/lib/deploy.sh"

MOCK_RC=0
_deploy_reload_fpm 8.3 example_com >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "reload_domain_fpm 0 → başarılı"

# error exit ettiği için alt kabukta koş
MOCK_RC=1
out=$( _deploy_reload_fpm 8.3 example_com 2>&1 ); rc=$?
assert_eq "$rc" "1" "reload_domain_fpm 1 → exit 1 (fail-closed)"
assert_contains "$out" "ÇALIŞMIYOR OLABİLİR" "operatöre manuel müdahale yönlendirmesi veriliyor"

test_summary
```

- [ ] **Step 2: Testi koş — mevcut kodla geçmeli**

Run: `bash tests/test_deploy_reload_fpm_delegation.sh`
Expected: FAIL — mevcut kod `reload_domain_fpm` çağırmıyor, kendi `systemctl` zincirini kullanıyor; mock devreye girmediği için `systemctl` bulunamaz

- [ ] **Step 3: `_deploy_reload_fpm` gövdesini değiştir**

`lib/deploy.sh` içinde, mevcut fonksiyon gövdesini (satır ~1198'den `error "${unit} restart de başarısız...` satırının sonuna kadar) şununla değiştir. **Fonksiyonun üstündeki mevcut yorum bloğu korunur**, sonuna aşağıdaki not eklenir:

```bash
# NOT (2026-08-03): unit çözümleme ve reload→restart→is-active zinciri
# lib/core.sh'taki 'domain_fpm_unit' / 'reload_domain_fpm' fonksiyonlarına
# taşındı — 'srvctl domain reload' komutu da AYNI zinciri kullanıyor, iki
# kopya sürüklemek istemiyoruz. Buradaki fail-closed 'error' politikası
# (deploy yarıda kalmasın) KORUNDU; core.sh helper'ı yalnız predikat döndürür.
_deploy_reload_fpm() {
    local php_version="$1" sname="${2:-}"
    if [[ -z "$sname" ]]; then
        # Eski çağrı biçimi: sname verilmemişse paylaşılan servisi hedefle.
        systemctl reload "php${php_version}-fpm" 2>/dev/null && return 0
        systemctl restart "php${php_version}-fpm" 2>/dev/null && return 0
        error "php${php_version}-fpm reload/restart başarısız — PHP-FPM ÇALIŞMIYOR OLABİLİR, site 502/503 dönüyor olabilir. Manuel müdahale: systemctl status php${php_version}-fpm"
    fi
    reload_domain_fpm "$sname" "$php_version" && return 0
    error "$(domain_fpm_unit "$sname" "$php_version") reload/restart başarısız — PHP-FPM ÇALIŞMIYOR OLABİLİR, site 502/503 dönüyor olabilir. Manuel müdahale: systemctl status $(domain_fpm_unit "$sname" "$php_version") / journalctl -u $(domain_fpm_unit "$sname" "$php_version")"
}
```

- [ ] **Step 4: Testi koş + tüm suite'i koş**

Run: `bash tests/test_deploy_reload_fpm_delegation.sh && bash tests/run.sh`
Expected: yeni test PASS; **mevcut testlerin hiçbiri kırılmamalı** (bu adımın asıl amacı)

- [ ] **Step 5: Commit**

```bash
git add lib/deploy.sh tests/test_deploy_reload_fpm_delegation.sh
git commit -m "deploy: reload zincirini core.sh helper'ına delege et

Aynı reload→restart→is-active mantığının iki kopyasını sürüklememek için.
Sözleşme ve fail-closed error politikası aynı.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `srvctl domain reload` komutu

**Files:**
- Create: `lib/domconf.sh`
- Modify: `lib/domain.sh` (`cmd_domain` case bloğu + `_domain_load_conf_lib`)
- Test: `tests/test_domconf_reload.sh`

**Interfaces:**
- Consumes: `reload_domain_fpm`, `domain_fpm_unit` (Task 1); `domain_exists`, `list_all_domains`, `safe_name`, `_derive_php`, `log_action` (mevcut core.sh)
- Produces: `_domconf_reload <domain>|--all [--fpm|--nginx]`; `_domain_load_conf_lib` (domain.sh)

- [ ] **Step 1: Testi yaz**

`tests/test_domconf_reload.sh`:

```bash
#!/bin/bash
# 'domain reload' — hedef seçimi, --all'da devam-et politikası, nginx'in
# BİR KEZ reload edilmesi.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }

mkdir -p "${WEB_ROOT}/a.com" "${WEB_ROOT}/b.com"
touch "${WEB_ROOT}/a.com/.credentials" "${WEB_ROOT}/b.com/.credentials"

_derive_php() { echo "8.3"; }
NGINX_RELOADS=0
NGINX_TEST_RC=0
nginx() { [[ "$1" == "-t" ]] && return "$NGINX_TEST_RC"; return 0; }
systemctl() { [[ "$1" == "reload" && "$2" == "nginx" ]] && NGINX_RELOADS=$((NGINX_RELOADS+1)); return 0; }

FAIL_FOR=""
reload_domain_fpm() { [[ "$1" == "$FAIL_FOR" ]] && return 1; return 0; }
domain_fpm_unit() { echo "srvctl-fpm-$1.service"; }

source "${REPO_ROOT}/lib/domconf.sh"

echo "── Bölüm A: tek domain ──"
NGINX_RELOADS=0
_domconf_reload a.com >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "sağlıklı domain → 0"
assert_eq "$NGINX_RELOADS" "1" "varsayılanda nginx de reload edilir"

NGINX_RELOADS=0
_domconf_reload a.com --fpm >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--fpm → yalnız FPM, exit 0"
assert_eq "$NGINX_RELOADS" "0" "--fpm ile nginx reload edilmez"

FAIL_FOR="a_com"
out=$( _domconf_reload a.com 2>&1 ); rc=$?
assert_eq "$rc" "1" "FPM reload başarısız → exit 1"
FAIL_FOR=""

echo "── Bölüm B: --all devam-et politikası ──"
# b.com başarısız olsa BİLE a.com işlenmeli; komut yine non-zero dönmeli.
FAIL_FOR="b_com"
NGINX_RELOADS=0
out=$( _domconf_reload --all 2>&1 ); rc=$?
assert_eq "$rc" "1" "--all: bir domain başarısızsa exit 1"
assert_contains "$out" "b.com" "başarısız domain özette adıyla raporlanır"
assert_eq "$NGINX_RELOADS" "1" "--all: nginx domain başına DEĞİL, BİR KEZ reload edilir"
FAIL_FOR=""

echo "── Bölüm C: nginx -t başarısız ──"
NGINX_TEST_RC=1; NGINX_RELOADS=0
out=$( _domconf_reload --all 2>&1 ); rc=$?
assert_eq "$NGINX_RELOADS" "0" "nginx -t başarısızsa reload denenmez"
assert_eq "$rc" "1" "nginx -t başarısız → exit 1"
NGINX_TEST_RC=0

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_domconf_reload.sh`
Expected: FAIL — `lib/domconf.sh: No such file or directory`

- [ ] **Step 3: `lib/domconf.sh`'ı oluştur**

```bash
#!/bin/bash
# ═══════════════════════════════════════════════
#  domconf.sh — Per-domain yapılandırma düzenleme ve reload
#
#  Bu modül KULLANICI ARAYÜZÜNÜ sahiplenir (editör, doğrulama, tarama,
#  rollback, reload tetikleme). Override'ların pool config'ine BASILMASI
#  render zincirinin parçasıdır ve lib/domain.sh'ta kalır
#  (_domain_render_php_overrides) — böylece repair/php-switch/harden-fpm
#  gibi pool'u yeniden üreten HER yol override'ları bedavaya uygular.
#
#  cmd_domain tarafından _domain_load_conf_lib ile source edilir.
# ═══════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  srvctl domain reload <domain>|--all [--fpm|--nginx]
#
#  nginx TEK bir master process'tir — domain başına nginx reload diye bir şey
#  YOKTUR. Bu yüzden '--all' akışında nginx BİR KEZ reload edilir.
#
#  '--all' HATADA DURMAZ: 100 domainli bir sunucuda tek bozuk domain, 99
#  sağlıklı domaini reload edilmemiş bırakmamalı. Başarısızlar sonda
#  özetlenir ve komut non-zero döner.
# ───────────────────────────────────────────────────────────────
_domconf_reload() {
    local target="" do_fpm=1 do_nginx=1 arg
    for arg in "$@"; do
        case "$arg" in
            --all)    target="--all" ;;
            --fpm)    do_nginx=0 ;;
            --nginx)  do_fpm=0 ;;
            -*)       error "Bilinmeyen seçenek: ${arg} (kullanım: srvctl domain reload <domain>|--all [--fpm|--nginx])" ;;
            *)        target="$arg" ;;
        esac
    done
    [[ -z "$target" ]] && error "Kullanım: srvctl domain reload <domain>|--all [--fpm|--nginx]"

    local -a domains=()
    if [[ "$target" == "--all" ]]; then
        while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(list_all_domains)
        [[ ${#domains[@]} -eq 0 ]] && { info "Reload edilecek domain yok."; return 0; }
    else
        domain_exists "$target" || error "Domain bulunamadı: ${target}"
        domains=("$target")
    fi

    local -a failed=()
    local d sname php_ver
    if [[ "$do_fpm" == "1" ]]; then
        for d in "${domains[@]}"; do
            sname=$(safe_name "$d")
            php_ver=$(_derive_php "$d" "${DEFAULT_PHP_VERSION}")
            if reload_domain_fpm "$sname" "$php_ver"; then
                success "FPM reload: ${d} ($(domain_fpm_unit "$sname" "$php_ver"))"
            else
                failed+=("$d")
                warn "FPM reload BAŞARISIZ: ${d} — systemctl status $(domain_fpm_unit "$sname" "$php_ver")"
            fi
        done
    fi

    local nginx_failed=0
    if [[ "$do_nginx" == "1" ]]; then
        # nginx_test() BAŞARISIZLIKTA EXIT EDER — burada döngü sonrası özet
        # basmamız gerektiği için doğrudan 'nginx -t' çağrılıyor.
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 \
                && success "nginx reload edildi" \
                || { warn "nginx reload başarısız"; nginx_failed=1; }
        else
            warn "nginx -t BAŞARISIZ — nginx reload edilmedi. 'nginx -t' ile hatayı görün."
            nginx_failed=1
        fi
    fi

    log_action "DOMAIN RELOAD: ${target} (fpm=${do_fpm} nginx=${do_nginx} başarısız=${#failed[@]})"

    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Reload edilemeyen domainler (${#failed[@]}): ${failed[*]}"
        return 1
    fi
    [[ "$nginx_failed" == "1" ]] && return 1
    return 0
}
```

- [ ] **Step 4: Testi koş, geçtiğini doğrula**

Run: `bash tests/test_domconf_reload.sh`
Expected: PASS — tüm assert'ler geçmeli (test_summary FAIL=0 basmalı)

- [ ] **Step 5: Dispatcher'a bağla**

`lib/domain.sh` içinde, diğer `_domain_load_*` helper'larının yanına:

```bash
# domconf.sh'ı talep üzerine yükler (CLAUDE.md cross-module deseni).
# _load_and_run yalnız TEK modül source ettiği için, guard'sız bir çağrı
# çalışma zamanında 'command not found' (exit 127) verirdi.
_domain_load_conf_lib() {
    declare -F _domconf_reload >/dev/null 2>&1 && return 0
    source "${SRVCTL_ROOT}/lib/domconf.sh" || return 1
}
```

`cmd_domain`'in case bloğuna (`resources)` satırının yanına):

```bash
        reload)   _domain_load_conf_lib || error "domconf modülü yüklenemedi"; _domconf_reload "${@:2}" ;;
```

- [ ] **Step 6: Modül sınırı testini güncelle ve koş**

`tests/test_no_undefined_functions.sh` içindeki modül bağımlılık haritasına `domain.sh → domconf.sh` kenarını ekle (dosyadaki mevcut harita yapısını izle).

Run: `bash tests/test_no_undefined_functions.sh && bash tests/run.sh`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/domconf.sh lib/domain.sh tests/test_domconf_reload.sh tests/test_no_undefined_functions.sh
git commit -m "domain reload: doğru FPM unit'ini tek komutla reload et

Operatörün elinde bir komut yoktu; izole kurulumda refleks olarak
çalıştırılan 'systemctl reload php8.3-fpm' sessizce hiçbir şey yapmıyor.
--all hatada durmaz, sonda özetler.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `.ini` sözdizimi doğrulama (core.sh)

**Files:**
- Modify: `lib/core.sh` (Task 1'de eklenen bloğun altına)
- Test: `tests/test_parse_php_ini_overrides.sh`

**Interfaces:**
- Produces: `parse_php_ini_overrides <file>` → geçerli satırları `anahtar=değer` biçiminde stdout'a basar; PREDİKAT: 0=geçerli, 1=sözdizimi hatası (mesaj stderr'e, satır numaralı)

**Güvenlik kritik:** Değer doğrudan pool config'ine basılacak. Değerde CR/LF olması `user = root` gibi keyfi bir FPM direktifi enjekte ettirir. `read -r` LF'i zaten engeller; CR açıkça reddedilir.

- [ ] **Step 1: Testi yaz**

`tests/test_parse_php_ini_overrides.sh`:

```bash
#!/bin/bash
# parse_php_ini_overrides — per-domain .ini sözdizimi kapısı.
#
# GÜVENLİK: değer pool config'ine DOĞRUDAN basılıyor. Değerde satır sonu
# karakteri kabul edilirse operatör (ya da .ini'yi yazabilen herhangi bir
# şey) 'user = root' gibi KEYFİ bir FPM direktifi enjekte edebilir.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

TMP="$(mktemp -d)"
w() { printf '%b' "$1" > "${TMP}/t.ini"; }

echo "── Bölüm A: geçerli girdi ──"
w 'memory_limit = 512M\n; yorum\n\nmax_execution_time=120\n'
out=$(parse_php_ini_overrides "${TMP}/t.ini"); rc=$?
assert_eq "$rc" "0" "geçerli dosya kabul edilir"
assert_contains "$out" "memory_limit=512M" "değer boşluk kırpılarak çıkar"
assert_contains "$out" "max_execution_time=120" "boşluksuz '=' kabul edilir"
assert_not_contains "$out" "yorum" "; yorumları atlanır"

w '# diyez yorumu\nopcache.memory_consumption = 256\n'
out=$(parse_php_ini_overrides "${TMP}/t.ini")
assert_contains "$out" "opcache.memory_consumption=256" "noktalı anahtar kabul edilir"
assert_not_contains "$out" "diyez" "# yorumları atlanır"

echo "── Bölüm B/C: güvenlik ve sözdizimi reddi ──"
# Her satır: <girdi>|<açıklama>. Hepsi 1 (reddedildi) dönmeli.
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    w "$payload"
    parse_php_ini_overrides "${TMP}/t.ini" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "$desc"
done <<'CASES'
memory_limit = 512M\ruser = root\n|değerde CR → reddedilir (direktif enjeksiyonu)
memory_limit = {{PM_MODE}}\n|değerde '{{' → reddedilir (token karışması)
[www]\nmemory_limit = 512M\n|[section] başlığı reddedilir
memory_limit\n|'=' içermeyen satır reddedilir
memory_limit =\n|boş değer reddedilir
memory_limit = 512M\nmemory_limit = 256M\n|çift anahtar reddedilir
1invalid = x\n|rakamla başlayan anahtar reddedilir
CASES

echo "── Bölüm D: kenar durumlar ──"
: > "${TMP}/t.ini"
out=$(parse_php_ini_overrides "${TMP}/t.ini"); rc=$?
assert_eq "$rc" "0" "boş dosya geçerli"
assert_eq "$out" "" "boş dosya boş çıktı verir"

w '; sadece yorum\n'
out=$(parse_php_ini_overrides "${TMP}/t.ini")
assert_eq "$out" "" "yalnız yorum içeren dosya boş çıktı verir"

# Son satırda newline YOK — 'read' bu satırı kaybetmemeli
printf 'memory_limit = 512M' > "${TMP}/t.ini"
out=$(parse_php_ini_overrides "${TMP}/t.ini")
assert_contains "$out" "memory_limit=512M" "son satırda newline olmasa da okunur"

# Hata mesajı satır numarası içermeli (operatör hangi satırı düzeltecek?)
w 'memory_limit = 512M\n[www]\n'
err=$(parse_php_ini_overrides "${TMP}/t.ini" 2>&1 >/dev/null)
assert_contains "$err" "satır 2" "hata mesajı satır numarası içerir"

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_parse_php_ini_overrides.sh`
Expected: FAIL — `parse_php_ini_overrides: command not found`

- [ ] **Step 3: Implementasyonu yaz**

`lib/core.sh`'a:

```bash
# ───────────────────────────────────────────────────────────────
#  Per-domain PHP .ini override parse'ı (paylaşılan kontrat)
#
#  Neden core.sh: hem lib/domain.sh'ın pool render'ı hem lib/domconf.sh'ın
#  düzenleme akışı AYNI parse'a ihtiyaç duyuyor. domconf.sh'a koysaydık
#  domain.sh → domconf.sh yönünde zorunlu bir bağımlılık doğardı ve
#  _load_and_run tek modül source ettiği için exit 127 riski oluşurdu.
#
#  Çıktı biçimi: her geçerli satır için 'anahtar=değer' (tek satır).
#  PREDİKAT: 0=geçerli, 1=sözdizimi hatası (mesaj stderr'e, satır numaralı).
#
#  GÜVENLİK: değer, pool config'ine 'php_admin_value[anahtar] = değer'
#  olarak DOĞRUDAN basılır. Değerde satır sonu karakteri kabul edilirse
#  'user = root' gibi KEYFİ bir FPM direktifi enjekte edilebilir — 'read -r'
#  LF'i zaten satır sınırında keser, CR ise BURADA açıkça reddedilir.
# ───────────────────────────────────────────────────────────────
parse_php_ini_overrides() {
    local file="$1"
    local line key val lineno=0
    local -a seen=()
    local s

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        # CRLF dosyalarında satır sonu CR'ını kırp (değere sızmasın)
        line="${line%$'\r'}"

        # boş satır / yorum
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*[\;\#] ]] && continue

        if [[ "$line" =~ ^[[:space:]]*\[ ]]; then
            printf 'satır %d: [section] başlığı desteklenmiyor — pool config'"'"'ine çevrilemez\n' "$lineno" >&2
            return 1
        fi

        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=(.*)$ ]]; then
            printf 'satır %d: '"'"'anahtar = değer'"'"' biçiminde değil: %s\n' "$lineno" "$line" >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # baş/son boşluk kırp
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"

        if [[ -z "$val" ]]; then
            printf 'satır %d: '"'"'%s'"'"' için değer boş\n' "$lineno" "$key" >&2
            return 1
        fi
        if [[ "$val" == *$'\r'* || "$val" == *$'\n'* ]]; then
            printf 'satır %d: değer satır sonu karakteri içeremez (config enjeksiyonu koruması)\n' "$lineno" >&2
            return 1
        fi
        if [[ "$val" == *'{{'* ]]; then
            printf 'satır %d: değer '"'"'{{'"'"' içeremez (şablon token'"'"'ı ile karışır)\n' "$lineno" >&2
            return 1
        fi

        for s in ${seen[@]+"${seen[@]}"}; do
            if [[ "$s" == "$key" ]]; then
                printf 'satır %d: '"'"'%s'"'"' birden fazla kez tanımlanmış\n' "$lineno" "$key" >&2
                return 1
            fi
        done
        seen+=("$key")

        printf '%s=%s\n' "$key" "$val"
    done < "$file"
    return 0
}
```

- [ ] **Step 4: Testi koş**

Run: `bash tests/test_parse_php_ini_overrides.sh`
Expected: PASS — tüm assert'ler geçmeli (test_summary FAIL=0 basmalı)

- [ ] **Step 5: Commit**

```bash
git add lib/core.sh tests/test_parse_php_ini_overrides.sh
git commit -m "core: per-domain .ini parse'ı + config enjeksiyonu kapısı

Değer pool config'ine doğrudan basılacağı için değerde CR/LF reddediliyor
(aksi halde 'user = root' gibi keyfi FPM direktifi enjekte edilebilirdi).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `.ini` override'larını pool'a enjekte et

**Files:**
- Modify: `lib/domain.sh:1661-1712` (`_domain_render_fpm_unit`) + yeni `_domain_render_php_overrides`
- Test: `tests/test_domain_php_overrides_render.sh`

**Interfaces:**
- Consumes: `parse_php_ini_overrides` (Task 4)
- Produces: `_domain_render_php_overrides <parsed_ini> <ini_file>` → `parse_php_ini_overrides` çıktısını `php_admin_value[...]` satırlarına çevirip stdout'a basar. `<parsed_ini>` boşsa hiçbir şey basmaz (exit 0). **Parse'ı kendisi yapmaz** — çağıran (`_domain_render_fpm_unit`) parse sonucuna filtreleme için zaten ihtiyaç duyduğundan, iki kez parse etmemek için sonuç dışarıdan verilir.

**Kritik tasarım kararı — filtreleme, çift tanım değil.** Override edilen bir anahtar pool şablonunda da tanımlıysa, şablondan gelen satır çıktıdan **düşürülür**. Alternatif ("ikisini de bas, sonuncusu kazanır") php-fpm'in belgelenmemiş bir davranışına bağımlılık yaratırdı.

**Regex tuzağı:** Anahtar adları `.` içerebilir (`opcache.memory_consumption`, `cgi.fix_pathinfo`). `grep` deseninde `.` "herhangi bir karakter" demektir; filtreleme deseninde kaçırılmalıdır.

- [ ] **Step 1: Testi yaz**

`tests/test_domain_php_overrides_render.sh`:

```bash
#!/bin/bash
# Per-domain .ini → pool config enjeksiyonu.
#
# EN KRİTİK KİLİT: override edilen anahtar pool'da TEK KEZ görünmeli.
# Şablondan gelen satır düşürülmezse php-fpm'in çift tanımda hangi değeri
# seçtiğine bağımlı hale gelirdik (belgelenmemiş davranış).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export SRVCTL_RESOURCE_PROFILES="${REPO_ROOT}/conf/resource-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
export SRVCTL_PHP_INI_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
log_action() { :; }
id() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"
POOL="${SRVCTL_FPM_DIR}/example_com.conf"

echo "── Bölüm A: .ini yokken davranış değişmez ──"
rm -f "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_render_fpm_unit example.com 8.3
base_lines=$(grep -c 'php_admin_value\[memory_limit\]' "$POOL")
assert_eq "$base_lines" "1" ".ini yokken memory_limit şablondan tek kez gelir"
assert_not_contains "$(cat "$POOL")" "per-domain override" "override başlığı basılmaz"

echo "── Bölüm B: override şablon satırını DÜŞÜRÜR ──"
printf 'memory_limit = 512M\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_render_fpm_unit example.com 8.3
pool=$(cat "$POOL")
assert_eq "$(grep -c 'php_admin_value\[memory_limit\]' "$POOL")" "1" \
    "memory_limit pool'da TEK KEZ görünür (şablon satırı düşürüldü)"
assert_contains "$pool" "php_admin_value[memory_limit] = 512M" "override değeri yürürlükte"
assert_not_contains "$pool" "php_admin_value[memory_limit] = 256M" "şablon değeri kalmadı"
assert_contains "$pool" "per-domain override" "override bloğu kendini tanıtır"

echo "── Bölüm C: noktalı anahtar (regex tuzağı) ──"
printf 'opcache.memory_consumption = 256\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_render_fpm_unit example.com 8.3
assert_contains "$(cat "$POOL")" "php_admin_value[opcache.memory_consumption] = 256" \
    "noktalı anahtar basılır"

echo "── Bölüm D: şablonda OLMAYAN anahtar eklenir ──"
printf 'max_file_uploads = 30\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_render_fpm_unit example.com 8.3
assert_contains "$(cat "$POOL")" "php_admin_value[max_file_uploads] = 30" \
    "şablonda olmayan anahtar eklenir"

echo "── Bölüm E: token kalıntısı yok ──"
printf 'memory_limit = 512M\nmax_execution_time = 120\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_render_fpm_unit example.com 8.3
assert_not_contains "$(cat "$POOL")" "{{" "render sonrası token kalıntısı yok"

echo "── Bölüm F: bozuk .ini render'ı DURDURUR ──"
printf '[www]\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
out=$( _domain_render_fpm_unit example.com 8.3 2>&1 ); rc=$?
assert_eq "$rc" "1" "geçersiz .ini → render fail-closed durur"

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_domain_php_overrides_render.sh`
Expected: FAIL — Bölüm B'de memory_limit iki kez (veya override hiç basılmamış)

- [ ] **Step 3: `_domain_render_php_overrides`'ı ekle**

`lib/domain.sh`'a, `_domain_render_fpm_unit`'in hemen üstüne:

```bash
# Per-domain .ini override'larını 'php_admin_value[...]' satırlarına çevirir.
# Dosya yoksa HİÇBİR ŞEY basmaz (çıktı bugünküyle birebir aynı kalır).
# Geçersiz .ini'de 1 döner — çağıran fail-closed durmalıdır.
#
# Neden hepsi php_admin_value (php_value değil): bu değerlerin uygulama
# içinden ini_set() ile değiştirilebilir olması İSTENMİYOR.
_domain_render_php_overrides() {
    local parsed="$1" ini_file="$2"
    [[ -n "$parsed" ]] || return 0
    printf '\n; ─── per-domain override (%s) ───\n' "$ini_file"
    local kv
    while IFS= read -r kv; do
        [[ -z "$kv" ]] && continue
        printf 'php_admin_value[%s] = %s\n' "${kv%%=*}" "${kv#*=}"
    done <<< "$parsed"
}
```

- [ ] **Step 4: `_domain_render_fpm_unit`'i filtreleme yapacak şekilde değiştir**

Mevcut `{ render_template ...; render_template ...; } > "$fpm_conf"` bloğunu şununla değiştir:

```bash
    # ─── Per-domain .ini override'ları (2026-08-03) ───
    # Kaynak render'ın DIŞINDA (/etc/srvctl/php.d/<sname>.ini), uygulanması
    # render'ın İÇİNDE — böylece repair/php-switch/harden-fpm gibi pool'u
    # yeniden üreten HER yol override'ları otomatik yeniden uygular.
    local ini_file="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}/${sname}.ini"
    local parsed_ini=""
    if [[ -f "$ini_file" ]]; then
        parsed_ini=$(parse_php_ini_overrides "$ini_file") \
            || error "Geçersiz per-domain PHP ini: ${ini_file} — yukarıdaki satırı düzeltin ('srvctl domain ini ${domain}')"
    fi

    local pool_out
    pool_out=$( {
        render_template "${SRVCTL_TEMPLATES}/php-fpm/fpm-global.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}"
        render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}" \
            "PHP_VERSION=${php_version}" "WEB_USER=${web_user}" \
            "PM_MODE=${RES_PM_MODE}" "PM_MAX_CHILDREN=${RES_MAX_CHILDREN}" \
            "PM_START_SERVERS=${RES_PM_START_SERVERS}" \
            "PM_MIN_SPARE_SERVERS=${RES_PM_MIN_SPARE_SERVERS}" \
            "PM_MAX_SPARE_SERVERS=${RES_PM_MAX_SPARE_SERVERS}" \
            "MEMORY_LIMIT=${RES_MEMORY_LIMIT_MB}M" \
            "DISABLE_FUNCTIONS=$(_domain_disable_functions_for "$unit_fw_declared")"
    } )

    # Override edilen anahtarların ŞABLON satırlarını düş — böylece pool'da
    # her anahtar TEK KEZ görünür ve php-fpm'in çift tanımda hangi değeri
    # seçtiğine (belgelenmemiş davranış) bağımlı kalmayız.
    # '.' karakteri grep deseninde 'herhangi bir karakter' demek —
    # 'opcache.memory_consumption' gibi anahtarlar için KAÇIRILMALI.
    if [[ -n "$parsed_ini" ]]; then
        local ov_key ov_esc
        while IFS= read -r ov_key; do
            [[ -z "$ov_key" ]] && continue
            ov_key="${ov_key%%=*}"
            ov_esc="${ov_key//./\\.}"
            pool_out=$(grep -v "^php_admin_value\[${ov_esc}\][[:space:]]*=" <<< "$pool_out" || true)
        done <<< "$parsed_ini"
    fi

    {
        printf '%s\n' "$pool_out"
        _domain_render_php_overrides "$parsed_ini" "$ini_file"
    } > "$fpm_conf"
```

- [ ] **Step 5: Testi koş**

Run: `bash tests/test_domain_php_overrides_render.sh && bash tests/run.sh`
Expected: yeni test PASS (10 assert); mevcut FPM render testleri kırılmamalı

- [ ] **Step 6: Commit**

```bash
git add lib/domain.sh tests/test_domain_php_overrides_render.sh
git commit -m "domain: per-domain .ini override'larını pool render'ına enjekte et

Kaynak render dışında, uygulama render içinde — repair/php-switch/
harden-fpm override'ları artık ezmiyor, yeniden uyguluyor. Şablon satırı
düşürülerek her anahtar pool'da tek kez bırakılıyor.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `srvctl domain ini` — tarama, düzenleme, rollback

**Files:**
- Modify: `lib/domconf.sh`, `lib/domain.sh` (case bloğu)
- Test: `tests/test_domconf_ini.sh`

**Interfaces:**
- Consumes: `parse_php_ini_overrides` (Task 4), `_domain_render_fpm_unit` (Task 5), `reload_domain_fpm` (Task 1)
- Produces: `_domconf_edit_ini <domain> [--show] [--file <path>] [--force]`, `_domconf_scan_ini <file>` (PREDİKAT: 0=temiz, 1=bulgu), `_domconf_ini_skeleton <domain>`

- [ ] **Step 1: Testi yaz**

`tests/test_domconf_ini.sh`:

```bash
#!/bin/bash
# 'domain ini' — reddedilen anahtar taraması, --force kaçış kapısı,
# ve ROLLBACK BÜTÜNLÜĞÜ (bozuk .ini yalnız kendini değil, türettiği pool'u
# da geri almalı — aksi halde bozuk pool diskte kalır ve bir sonraki
# repair/reload onu canlıya alır).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_PHP_INI_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
send_notification() { :; }
mkdir -p "${WEB_ROOT}/example.com"

_derive_php() { echo "8.3"; }
RENDER_CALLS=0
_domain_render_fpm_unit() {
    RENDER_CALLS=$((RENDER_CALLS+1))
    # Pool'u .ini'den türet — rollback'in pool'u da geri aldığını görebilelim
    local sname; sname=$(safe_name "$1")
    cat "${SRVCTL_PHP_INI_DIR}/${sname}.ini" > "${SRVCTL_FPM_DIR}/${sname}.conf" 2>/dev/null || true
}
_domain_load_conf_lib() { return 0; }
FPM_TEST_RC=0
_domconf_fpm_config_test() { return "$FPM_TEST_RC"; }
reload_domain_fpm() { return 0; }
domain_fpm_unit() { echo "srvctl-fpm-$1.service"; }
source "${REPO_ROOT}/lib/domconf.sh"

INI="${SRVCTL_PHP_INI_DIR}/example_com.ini"
POOL="${SRVCTL_FPM_DIR}/example_com.conf"
TMP="$(mktemp -d)"

echo "── Bölüm A: reddedilen anahtar taraması ──"
for key in extension zend_extension open_basedir disable_functions \
           disable_classes sendmail_path allow_url_fopen allow_url_include \
           cgi.fix_pathinfo; do
    printf '%s = x\n' "$key" > "${TMP}/scan.ini"
    _domconf_scan_ini "${TMP}/scan.ini" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "reddedilen anahtar yakalanır: ${key}"
done

printf 'memory_limit = 512M\nopcache.enable = 1\n' > "${TMP}/scan.ini"
_domconf_scan_ini "${TMP}/scan.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "masum anahtarlar temiz geçer"

printf '; extension = evil.so\n# open_basedir = /\n' > "${TMP}/scan.ini"
_domconf_scan_ini "${TMP}/scan.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "YORUM içindeki reddedilen anahtar yakalanmaz"

printf 'extension = evil.so\n' > "${TMP}/scan.ini"
out=$(_domconf_scan_ini "${TMP}/scan.ini" 2>&1 || true)
assert_contains "$out" "satır 1" "bulgu satır numarasıyla raporlanır"
assert_contains "$out" "root" "gerekçe metni gösterilir"

echo "── Bölüm B: --file ile uygulama ──"
printf 'memory_limit = 512M\n' > "${TMP}/new.ini"
_domconf_edit_ini example.com --file "${TMP}/new.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "geçerli .ini uygulanır"
assert_contains "$(cat "$INI")" "memory_limit = 512M" "içerik canlı dosyaya yazıldı"

echo "── Bölüm C: reddedilen anahtar --force olmadan UYGULANMAZ ──"
cp "$INI" "${TMP}/before.ini"
printf 'extension = evil.so\n' > "${TMP}/bad.ini"
_domconf_edit_ini example.com --file "${TMP}/bad.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reddedilen anahtar → exit 1"
assert_eq "$(cat "$INI")" "$(cat "${TMP}/before.ini")" "canlı .ini DEĞİŞMEDİ"

echo "── Bölüm D: --force geçer ──"
_domconf_edit_ini example.com --file "${TMP}/bad.ini" --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--force ile uygulanır"
assert_contains "$(cat "$INI")" "extension = evil.so" "--force içeriği yazdı"

echo "── Bölüm E: ROLLBACK BÜTÜNLÜĞÜ ──"
printf 'memory_limit = 512M\n' > "${TMP}/good.ini"
_domconf_edit_ini example.com --file "${TMP}/good.ini" >/dev/null 2>&1
cp "$INI" "${TMP}/before.ini"; cp "$POOL" "${TMP}/before.conf"

# php-fpm -t başarısız olacak
FPM_TEST_RC=1
printf 'max_execution_time = 999\n' > "${TMP}/next.ini"
_domconf_edit_ini example.com --file "${TMP}/next.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "php-fpm -t başarısız → exit 1"
assert_eq "$(cat "$INI")" "$(cat "${TMP}/before.ini")" "rollback: .ini eski halinde"
assert_eq "$(cat "$POOL")" "$(cat "${TMP}/before.conf")" "rollback: POOL da eski halinde"
FPM_TEST_RC=0

echo "── Bölüm F: sözdizimi hatası hiçbir şey yazmaz ──"
cp "$INI" "${TMP}/before.ini"
printf '[www]\n' > "${TMP}/syn.ini"
_domconf_edit_ini example.com --file "${TMP}/syn.ini" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "sözdizimi hatası → exit 1"
assert_eq "$(cat "$INI")" "$(cat "${TMP}/before.ini")" "sözdizimi hatasında .ini değişmedi"

echo "── Bölüm G: değişiklik yoksa reload edilmez ──"
RENDER_CALLS=0
cp "$INI" "${TMP}/same.ini"
_domconf_edit_ini example.com --file "${TMP}/same.ini" >/dev/null 2>&1
assert_eq "$RENDER_CALLS" "0" "içerik aynıysa render/reload yapılmaz"

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_domconf_ini.sh`
Expected: FAIL — `_domconf_scan_ini: command not found`

- [ ] **Step 3: `lib/domconf.sh`'a tarama + düzenleme akışını ekle**

```bash
# ───────────────────────────────────────────────────────────────
#  Reddedilen PHP ini anahtarları — izolasyonu DELEN ayarlar.
#  "Ayağına sıkma" kategorisi (display_errors vb.) BİLİNÇLİ OLARAK
#  listede DEĞİL; buradaki ölçüt "srvctl'in güvenlik modelini deler mi".
# ───────────────────────────────────────────────────────────────
_DOMCONF_INI_DENY=(
    extension zend_extension
    open_basedir disable_functions disable_classes
    sendmail_path
    allow_url_fopen allow_url_include
    cgi.fix_pathinfo
)

_domconf_ini_deny_reason() {
    case "$1" in
        extension|zend_extension)
            echo "FPM master ROOT olarak başlar — keyfi .so yükleme = root kod çalıştırma" ;;
        open_basedir)
            echo "chroot içi dosya erişim sınırını gevşetir" ;;
        disable_functions|disable_classes)
            echo "hardening listesini gevşetir (bkz. pool.conf.tpl BUG 2 notu)" ;;
        sendmail_path)
            echo "mail() üzerinden komut çalıştırma — pool bu anahtarı set etmiyor" ;;
        allow_url_fopen|allow_url_include)
            echo "RFI/SSRF" ;;
        cgi.fix_pathinfo)
            echo "klasik PHP-FPM arbitrary-exec vektörü" ;;
        *)  echo "izolasyon politikası" ;;
    esac
}

# PREDİKAT: 0=temiz, 1=reddedilen anahtar bulundu (rapor stdout'a).
_domconf_scan_ini() {
    local file="$1"
    local line key deny lineno=0 found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*[\;\#] ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*= ]] || continue
        key="${BASH_REMATCH[1]}"
        for deny in "${_DOMCONF_INI_DENY[@]}"; do
            if [[ "$key" == "$deny" ]]; then
                echo "    satır ${lineno}: ${key} — $(_domconf_ini_deny_reason "$key")"
                found=1
            fi
        done
    done < "$file"
    return $found
}

# php-fpm config testi — ayrı fonksiyon, testte mock'lanabilsin diye.
# PREDİKAT: 0=geçerli. php-fpm binary yoksa test ATLANIR (0 döner).
_domconf_fpm_config_test() {
    local php_version="$1" conf="$2"
    local bin="/usr/sbin/php-fpm${php_version}"
    [[ -x "$bin" ]] || { warn "php-fpm binary yok: ${bin} — config testi atlandı"; return 0; }
    local err
    if ! err=$("$bin" --fpm-config "$conf" -t 2>&1); then
        warn "FPM config testi başarısız: ${conf}"
        [[ -n "$err" ]] && echo "$err" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

_domconf_ini_skeleton() {
    local domain="$1"
    cat <<EOF
; ═══════════════════════════════════════════════
;  srvctl per-domain PHP ayarları — ${domain}
; ═══════════════════════════════════════════════
;
; Buradaki satırlar FPM pool config'ine 'php_admin_value[...]' olarak
; enjekte edilir ve ŞABLONDAKİ aynı isimli ayarı EZER.
; Bu dosya render'ın DIŞINDADIR: 'domain repair', 'php-switch' ve
; 'security harden-fpm' onu EZMEZ, her seferinde yeniden uygular.
;
; Düzenledikten sonra:  srvctl domain reload ${domain}
; (Bu komut kaydettiğinizde zaten reload eder — elle gerek yok.)
;
; ─── Sık kullanılan ayarlar (yorumu kaldırıp değiştirin) ───
; memory_limit = 512M
; max_execution_time = 120
; max_input_time = 120
; upload_max_filesize = 100M
; post_max_size = 105M
; max_input_vars = 10000
; opcache.memory_consumption = 256
;
; ─── REDDEDİLEN anahtarlar (--force olmadan uygulanmaz) ───
;   extension, zend_extension  → FPM master ROOT'tur, keyfi .so = root RCE
;   open_basedir               → chroot içi erişim sınırını gevşetir
;   disable_functions          → hardening listesini gevşetir
;   sendmail_path              → mail() üzerinden komut çalıştırma
;   allow_url_fopen/_include   → RFI/SSRF
;   cgi.fix_pathinfo           → PHP-FPM arbitrary-exec vektörü
;
; Biçim: 'anahtar = değer'. [section] başlığı ve çok satırlı değer YOKTUR.
EOF
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain ini <domain> [--show] [--file <path>] [--force]
#
#  ROLLBACK BÜTÜNLÜĞÜ: doğrulama başarısız olduğunda yalnız .ini değil,
#  ondan TÜREtİLMİŞ pool da eski haline döner. Aksi halde bozuk pool
#  diskte kalır ve bir sonraki 'repair'/reload onu CANLIYA ALIR — hata,
#  kendisini tetikleyen komuttan çok sonra patlar.
# ───────────────────────────────────────────────────────────────
_domconf_edit_ini() {
    local domain="" src_file="" show=0 force=0 arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --show)  show=1 ;;
            --force) force=1 ;;
            --file)  shift; src_file="${1:-}"; [[ -n "$src_file" ]] || error "--file bir yol gerektirir" ;;
            --file=*) src_file="${arg#--file=}" ;;
            -*)      error "Bilinmeyen seçenek: ${arg}" ;;
            *)       domain="$arg" ;;
        esac
        shift
    done
    [[ -n "$domain" ]] || error "Kullanım: srvctl domain ini <domain> [--show] [--file <yol>] [--force]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local ini_dir="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}"
    local ini="${ini_dir}/${sname}.ini"
    mkdir -p "$ini_dir"
    [[ -f "$ini" ]] || { _domconf_ini_skeleton "$domain" > "$ini"; chmod 644 "$ini"; }

    if [[ "$show" == "1" ]]; then
        cat "$ini"
        return 0
    fi

    # ─── Aday içeriği elde et ───
    local cand; cand=$(mktemp)
    if [[ -n "$src_file" ]]; then
        [[ -f "$src_file" ]] || { rm -f "$cand"; error "Dosya bulunamadı: ${src_file}"; }
        cp "$src_file" "$cand"
    else
        cp "$ini" "$cand"
        "${EDITOR:-nano}" "$cand" || { rm -f "$cand"; error "Editör hata döndürdü — değişiklik uygulanmadı"; }
    fi

    if cmp -s "$cand" "$ini"; then
        rm -f "$cand"
        info "Değişiklik yok — hiçbir şey yapılmadı."
        return 0
    fi

    # ─── Doğrulama: sözdizimi ───
    if ! parse_php_ini_overrides "$cand" >/dev/null; then
        rm -f "$cand"
        error "Sözdizimi hatası — değişiklik UYGULANMADI (yukarıdaki satırı düzeltin)"
    fi

    # ─── Doğrulama: reddedilen anahtarlar ───
    local findings
    if ! findings=$(_domconf_scan_ini "$cand"); then
        if [[ "$force" != "1" ]]; then
            rm -f "$cand"
            warn "REDDEDİLDİ — izolasyonu delen ayar(lar):"
            echo "$findings" >&2
            error "Değişiklik UYGULANMADI. Bilerek yapıyorsanız: srvctl domain ini ${domain} --force"
        fi
        warn "UYARI: izolasyon override edildi (--force) — ${domain}"
        echo "$findings" >&2
        log_action "DOMAIN INI --force: ${domain} — izolasyon override edildi"
        source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
        declare -F send_notification >/dev/null 2>&1 \
            && send_notification "srvctl: ${domain} PHP ini izolasyon override (--force)" || true
    fi

    # ─── Uygula (yedekle → yerleştir → render → test) ───
    local backup; backup=$(mktemp)
    cp "$ini" "$backup"
    cat "$cand" > "$ini"
    chmod 644 "$ini"
    rm -f "$cand"

    local php_ver; php_ver=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    local pool="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}/${sname}.conf"

    if ! _domain_render_fpm_unit "$domain" "$php_ver"; then
        cat "$backup" > "$ini"; rm -f "$backup"
        _domain_render_fpm_unit "$domain" "$php_ver" || true
        error "Pool render başarısız — .ini ve pool eski haline döndürüldü"
    fi

    if ! _domconf_fpm_config_test "$php_ver" "$pool"; then
        cat "$backup" > "$ini"; rm -f "$backup"
        _domain_render_fpm_unit "$domain" "$php_ver" || true
        error "php-fpm config testi başarısız — .ini VE pool eski haline döndürüldü, reload YAPILMADI"
    fi
    rm -f "$backup"

    reload_domain_fpm "$sname" "$php_ver" \
        || error "$(domain_fpm_unit "$sname" "$php_ver") reload/restart başarısız — config GEÇERLİ, sorun servis katmanında. systemctl status $(domain_fpm_unit "$sname" "$php_ver")"

    success "PHP ayarları uygulandı ve FPM reload edildi: ${domain}"
    log_action "DOMAIN INI: ${domain}"
}
```

- [ ] **Step 4: `domain.sh` case bloğuna ekle**

```bash
        ini)      _domain_load_conf_lib || error "domconf modülü yüklenemedi"; _domconf_edit_ini "${@:2}" ;;
```

- [ ] **Step 5: Testi koş**

Run: `bash tests/test_domconf_ini.sh && bash tests/run.sh`
Expected: PASS — tüm assert'ler geçmeli (test_summary FAIL=0 basmalı)

- [ ] **Step 6: Commit**

```bash
git add lib/domconf.sh lib/domain.sh tests/test_domconf_ini.sh
git commit -m "domain ini: per-domain PHP ayarlarını düzenle, doğrula, reload et

Reddedilen anahtarlar --force olmadan uygulanmaz. Rollback bütünlüğü:
bozuk .ini yalnız kendini değil türettiği pool'u da geri alır.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `srvctl domain nginx` + vhost include

**Files:**
- Modify: `templates/nginx/vhost.conf.tpl`, `templates/nginx/vhost-ssl.conf.tpl`, `lib/domconf.sh`, `lib/domain.sh`
- Test: `tests/test_domconf_nginx.sh`

**Interfaces:**
- Consumes: `nginx -t` (mock'lanabilir), `_domconf_reload` (Task 3)
- Produces: `_domconf_edit_nginx <domain> [--show] [--file <path>] [--force]`, `_domconf_scan_nginx <file>`, `_domconf_nginx_skeleton <domain>`

- [ ] **Step 1: Testi yaz**

`tests/test_domconf_nginx.sh`:

```bash
#!/bin/bash
# 'domain nginx' — reddedilen direktifler, include ÖN KOŞUL kapısı, rollback.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_NGINX_CUSTOM_DIR="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
log_action() { :; }
send_notification() { :; }
mkdir -p "${WEB_ROOT}/example.com"

NGINX_TEST_RC=0
nginx() { [[ "$1" == "-t" ]] && return "$NGINX_TEST_RC"; return 0; }
systemctl() { return 0; }
source "${REPO_ROOT}/lib/domconf.sh"

CUSTOM="${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf"
VHOST="${SITES_AVAILABLE}/example.com.conf"
TMP="$(mktemp -d)"

echo "── Bölüm A: reddedilen direktifler ──"
for d in "fastcgi_pass unix:/run/php/other.sock;" \
         "root /etc/passwd;" \
         "alias /root/;" \
         "server_name evil.com;" \
         "listen 8080;" \
         "disable_symlinks off;" \
         "modsecurity off;" \
         "modsecurity_rules_file /dev/null;"; do
    echo "$d" > "${TMP}/scan.conf"
    _domconf_scan_nginx "${TMP}/scan.conf" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1" "reddedilir: ${d}"
done

# En incelikli vektör: nginx üzerinden PHP ayarı enjeksiyonu.
echo 'fastcgi_param PHP_ADMIN_VALUE "open_basedir=";' > "${TMP}/scan.conf"
_domconf_scan_nginx "${TMP}/scan.conf" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "fastcgi_param PHP_ADMIN_VALUE reddedilir"
echo 'fastcgi_param PHP_VALUE "memory_limit=9G";' > "${TMP}/scan.conf"
_domconf_scan_nginx "${TMP}/scan.conf" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "fastcgi_param PHP_VALUE reddedilir"

echo "── Bölüm B: serbest bırakılanlar ──"
while IFS='|' read -r payload desc; do
    [[ -z "$payload" ]] && continue
    printf '%b' "$payload" > "${TMP}/scan.conf"
    _domconf_scan_nginx "${TMP}/scan.conf" >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "0" "$desc"
done <<'CASES'
client_max_body_size 100M;\n|client_max_body_size serbest
location /api/ {\n    proxy_pass http://127.0.0.1:3000;\n}\n|proxy_pass BİLİNÇLİ olarak serbest
# root /etc/passwd;\n|yorum içindeki direktif yakalanmaz
    fastcgi_param SCRIPT_FILENAME $doc;\n|masum fastcgi_param serbest
CASES

echo "── Bölüm C: include ÖN KOŞUL kapısı ──"
printf 'server {\n    listen 80;\n}\n' > "$VHOST"
printf 'client_max_body_size 100M;\n' > "${TMP}/new.conf"
out=$( _domconf_edit_nginx example.com --file "${TMP}/new.conf" 2>&1 ); rc=$?
assert_eq "$rc" "1" "vhost'ta include yoksa fail-closed durur"
assert_contains "$out" "repair" "kurtarma yolu (domain repair) önerilir"

echo "── Bölüm D: include varken uygulanır ──"
printf 'server {\n    include /etc/nginx/custom.d/example_com/*.conf;\n}\n' > "$VHOST"
_domconf_edit_nginx example.com --file "${TMP}/new.conf" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "include varsa uygulanır"
assert_contains "$(cat "$CUSTOM")" "client_max_body_size 100M;" "içerik yazıldı"

echo "── Bölüm E: rollback ──"
cp "$CUSTOM" "${TMP}/before.conf"
NGINX_TEST_RC=1
printf 'client_max_body_size 200M;\n' > "${TMP}/next.conf"
_domconf_edit_nginx example.com --file "${TMP}/next.conf" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "nginx -t başarısız → exit 1"
assert_eq "$(cat "$CUSTOM")" "$(cat "${TMP}/before.conf")" "rollback: dosya eski halinde"
NGINX_TEST_RC=0

echo "── Bölüm F: --force ──"
printf 'root /tmp;\n' > "${TMP}/bad.conf"
_domconf_edit_nginx example.com --file "${TMP}/bad.conf" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "reddedilen direktif → exit 1"
_domconf_edit_nginx example.com --file "${TMP}/bad.conf" --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--force geçer"

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_domconf_nginx.sh`
Expected: FAIL — `_domconf_scan_nginx: command not found`

- [ ] **Step 3: Şablonlara include satırını ekle**

`templates/nginx/vhost.conf.tpl` — mevcut `include /etc/nginx/webhook.d/{{SAFE_NAME}}/*.conf;` satırının hemen üstüne:

```nginx
    # ─── Operatör override'ları (srvctl domain nginx <domain>) ───
    # SONDA include ediliyor: nginx'te regex location'lar TANIM SIRASINA göre
    # eşleşir, yani yukarıdaki deny kuralları (/\., \.env$, spark, …) HER ZAMAN
    # önce değerlendirilir — buraya eklenen bir regex onları BYPASS EDEMEZ.
    # Glob include sıfır eşleşmeyi hatasız kabul eder (bkz. webhook.d notu).
    include /etc/nginx/custom.d/{{SAFE_NAME}}/*.conf;
```

`templates/nginx/vhost-ssl.conf.tpl` — aynı satırı, oradaki webhook include'unun üstüne ekle. **İki dosyada da `SAFE_NAME` zaten TOKENS listesinde**, değişiklik gerekmez.

- [ ] **Step 4: `lib/domconf.sh`'a nginx tarafını ekle**

```bash
# ───────────────────────────────────────────────────────────────
#  Reddedilen nginx direktifleri.
#  'proxy_pass' BİLİNÇLİ OLARAK LİSTEDE DEĞİL: bu dosyayı yalnız root
#  düzenler, yani tehdit modeli "saldırgan" değil "operatörün ayağına
#  sıkması". Node/websocket servisine proxy meşru ve yaygın; reddetmek
#  operatörü srvctl'i baypas edip vhost'u ELLE düzenlemeye iter — o
#  değişiklik de ilk 'repair'de sessizce kaybolur.
# ───────────────────────────────────────────────────────────────
_DOMCONF_NGINX_DENY=(
    fastcgi_pass root alias server_name listen
    disable_symlinks modsecurity modsecurity_rules modsecurity_rules_file
)

_domconf_nginx_deny_reason() {
    case "$1" in
        fastcgi_pass)  echo "başka domainin FPM socket'ine yönlenme — domainler arası izolasyon ihlali" ;;
        root|alias)    echo "docroot/chroot dışı dosya servisi" ;;
        server_name)   echo "başka bir domaini kapma" ;;
        listen)        echo "vhost/port çakışması" ;;
        disable_symlinks) echo "symlink koruması kapatma" ;;
        modsecurity*)  echo "WAF bypass" ;;
        *)             echo "izolasyon politikası" ;;
    esac
}

# PREDİKAT: 0=temiz, 1=reddedilen direktif bulundu (rapor stdout'a).
#
# Tarama SATIR BAZLIDIR: '#' yorumları çıkarılır, baştaki boşluk kırpılır,
# satırın ilk kelimesi direktif adı sayılır. String literali içinde geçen
# bir direktif adı yanlış pozitif üretebilir — BİLİNÇLİ ödünleşim: yanlış
# pozitifin maliyeti '--force', yanlış negatifin maliyeti SESSİZ izolasyon
# ihlali.
_domconf_scan_nginx() {
    local file="$1"
    local line first deny lineno=0 found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" ]] && continue
        first="${line%%[[:space:];]*}"

        # Özel durum: nginx üzerinden PHP ayarı enjeksiyonu.
        # 'fastcgi_param PHP_ADMIN_VALUE "open_basedir="' ile chroot
        # izolasyonu delinebilir; ne 'nginx -t' ne 'php-fpm -t' itiraz eder.
        if [[ "$first" == "fastcgi_param" ]]; then
            if [[ "$line" == *PHP_ADMIN_VALUE* || "$line" == *PHP_VALUE* ]]; then
                echo "    satır ${lineno}: fastcgi_param PHP_(ADMIN_)VALUE — nginx üzerinden PHP ayarı enjeksiyonu (open_basedir buradan boşaltılabilir)"
                found=1
            fi
            continue
        fi

        for deny in "${_DOMCONF_NGINX_DENY[@]}"; do
            if [[ "$first" == "$deny" ]]; then
                echo "    satır ${lineno}: ${first} — $(_domconf_nginx_deny_reason "$first")"
                found=1
            fi
        done
    done < "$file"
    return $found
}

_domconf_nginx_skeleton() {
    local domain="$1"
    cat <<EOF
# ═══════════════════════════════════════════════
#  srvctl per-domain nginx override — ${domain}
# ═══════════════════════════════════════════════
#
# Bu dosya vhost'un server{} bloğuna, EN SONDA include edilir.
# Render'ın DIŞINDADIR: 'domain repair' onu EZMEZ.
#
# ─── ÖNEMLİ KISIT ───
# Bir include dosyası mevcut direktifleri EZEMEZ — nginx çoğu direktifte
# "is duplicate" hatası verir. Buraya EKLEME yapılır, override değil.
# ('client_max_body_size' vhost'ta tanımlı DEĞİL, yani serbestçe eklenebilir.)
#
# ─── add_header TUZAĞI ───
# Bir location{} bloğu İÇİNDE add_header kullanırsanız, o location için üst
# bloğun TÜM güvenlik başlıkları (HSTS, X-Frame-Options, Referrer-Policy…)
# SESSİZCE düşer. Kullanacaksanız üsttekileri de o blokta TEKRARLAYIN.
#
# ─── REDDEDİLEN direktifler (--force olmadan uygulanmaz) ───
#   fastcgi_pass   → başka domainin FPM socket'ine yönlenme
#   root, alias    → docroot/chroot dışı dosya servisi
#   server_name    → başka bir domaini kapma
#   listen         → vhost/port çakışması
#   disable_symlinks, modsecurity*  → koruma kapatma
#   fastcgi_param PHP_VALUE / PHP_ADMIN_VALUE → PHP ayarı enjeksiyonu
#
# ─── Örnek ───
# client_max_body_size 100M;
#
# location /uzun-islem/ {
#     fastcgi_read_timeout 300s;
# }
EOF
}

# ───────────────────────────────────────────────────────────────
#  srvctl domain nginx <domain> [--show] [--file <path>] [--force]
# ───────────────────────────────────────────────────────────────
_domconf_edit_nginx() {
    local domain="" src_file="" show=0 force=0 arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --show)  show=1 ;;
            --force) force=1 ;;
            --file)  shift; src_file="${1:-}"; [[ -n "$src_file" ]] || error "--file bir yol gerektirir" ;;
            --file=*) src_file="${arg#--file=}" ;;
            -*)      error "Bilinmeyen seçenek: ${arg}" ;;
            *)       domain="$arg" ;;
        esac
        shift
    done
    [[ -n "$domain" ]] || error "Kullanım: srvctl domain nginx <domain> [--show] [--file <yol>] [--force]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname; sname=$(safe_name "$domain")
    local dir="${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}/${sname}"
    local conf="${dir}/00-custom.conf"
    mkdir -p "$dir"
    [[ -f "$conf" ]] || { _domconf_nginx_skeleton "$domain" > "$conf"; chmod 644 "$conf"; }

    if [[ "$show" == "1" ]]; then
        cat "$conf"
        return 0
    fi

    # ─── ÖN KOŞUL: vhost bu dizini include ediyor mu? ───
    # Bu spec'ten ÖNCE oluşturulmuş domainlerin vhost'unda include satırı
    # YOKTUR. Kontrol olmasaydı: operatör düzenler, 'nginx -t' temiz geçer,
    # reload başarılı görünür ve HİÇBİR ŞEY DEĞİŞMEZ — düzeltmeye
    # çalıştığımız sessiz-kayıp probleminin aynısı.
    local vhost="${SITES_AVAILABLE:-/etc/nginx/sites-available}/${domain}.conf"
    if [[ -f "$vhost" ]] && ! grep -q "custom\.d/${sname}/" "$vhost"; then
        error "Bu domainin vhost'u custom.d dizinini include etmiyor (${vhost}) — düzenleme ETKİSİZ kalırdı. Önce: srvctl domain repair ${domain}"
    fi

    local cand; cand=$(mktemp)
    if [[ -n "$src_file" ]]; then
        [[ -f "$src_file" ]] || { rm -f "$cand"; error "Dosya bulunamadı: ${src_file}"; }
        cp "$src_file" "$cand"
    else
        cp "$conf" "$cand"
        "${EDITOR:-nano}" "$cand" || { rm -f "$cand"; error "Editör hata döndürdü — değişiklik uygulanmadı"; }
    fi

    if cmp -s "$cand" "$conf"; then
        rm -f "$cand"
        info "Değişiklik yok — hiçbir şey yapılmadı."
        return 0
    fi

    local findings
    if ! findings=$(_domconf_scan_nginx "$cand"); then
        if [[ "$force" != "1" ]]; then
            rm -f "$cand"
            warn "REDDEDİLDİ — izolasyonu delen direktif(ler):"
            echo "$findings" >&2
            error "Değişiklik UYGULANMADI. Bilerek yapıyorsanız: srvctl domain nginx ${domain} --force"
        fi
        warn "UYARI: izolasyon override edildi (--force) — ${domain}"
        echo "$findings" >&2
        log_action "DOMAIN NGINX --force: ${domain} — izolasyon override edildi"
        source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
        declare -F send_notification >/dev/null 2>&1 \
            && send_notification "srvctl: ${domain} nginx izolasyon override (--force)" || true
    fi

    local backup; backup=$(mktemp)
    cp "$conf" "$backup"
    cat "$cand" > "$conf"
    chmod 644 "$conf"
    rm -f "$cand"

    if ! nginx -t >/dev/null 2>&1; then
        cat "$backup" > "$conf"; rm -f "$backup"
        warn "nginx -t BAŞARISIZ — dosya eski haline döndürüldü, reload YAPILMADI. Hata:"
        nginx -t 2>&1 | sed 's/^/    /' >&2 || true
        error "nginx yapılandırma hatası"
    fi
    rm -f "$backup"

    systemctl reload nginx >/dev/null 2>&1 \
        || error "nginx reload başarısız — config GEÇERLİ, sorun servis katmanında. systemctl status nginx"

    success "nginx override uygulandı ve reload edildi: ${domain}"
    log_action "DOMAIN NGINX: ${domain}"
}
```

- [ ] **Step 5: `domain.sh` case bloğuna ekle**

```bash
        nginx)    _domain_load_conf_lib || error "domconf modülü yüklenemedi"; _domconf_edit_nginx "${@:2}" ;;
```

- [ ] **Step 6: Testi koş**

Run: `bash tests/test_domconf_nginx.sh && bash tests/run.sh`
Expected: PASS — tüm assert'ler geçmeli (test_summary FAIL=0 basmalı). `bash tests/run.sh` içindeki mevcut vhost render testleri de geçmeli (yeni include satırı token kalıntısı üretmemeli).

- [ ] **Step 7: Commit**

```bash
git add templates/nginx/vhost.conf.tpl templates/nginx/vhost-ssl.conf.tpl \
        lib/domconf.sh lib/domain.sh tests/test_domconf_nginx.sh
git commit -m "domain nginx: per-domain vhost override'ı düzenle, doğrula, reload et

include SONDA: mevcut deny location'ları her zaman önce değerlendirilir.
Vhost include etmiyorsa fail-closed durur — sessizce etkisiz kalmasın.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Yaşam döngüsü — add / remove / clone

**Files:**
- Modify: `lib/domain.sh` (`_domain_add`, `_domain_purge_resources`, `_domain_clone`)
- Test: `tests/test_domconf_lifecycle.sh`

**Interfaces:**
- Consumes: `_domconf_ini_skeleton`, `_domconf_nginx_skeleton` (Task 6/7) — `_domain_load_conf_lib` ile guard'lı yüklenir
- Produces: yaşam döngüsü davranışı; yeni fonksiyon yok

- [ ] **Step 1: Testi yaz**

`tests/test_domconf_lifecycle.sh`:

```bash
#!/bin/bash
# Yaşam döngüsü: add iskelet üretir, remove temizler, clone kopyalar.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_PHP_INI_DIR="$(mktemp -d)"
export SRVCTL_NGINX_CUSTOM_DIR="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_ROOT="${REPO_ROOT}"
log_action() { :; }
systemctl() { return 0; }
nginx() { return 0; }
id() { return 0; }
source "${REPO_ROOT}/lib/domain.sh"

echo "── Bölüm A: iskelet üretimi ──"
mkdir -p "${WEB_ROOT}/example.com"
_domain_provision_conf_skeletons example.com
test -f "${SRVCTL_PHP_INI_DIR}/example_com.ini"; assert_eq "$?" "0" ".ini iskeleti oluşturuldu"
test -f "${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf"; assert_eq "$?" "0" "nginx iskeleti oluşturuldu"
assert_contains "$(cat "${SRVCTL_PHP_INI_DIR}/example_com.ini")" "REDDEDİLEN" ".ini iskeleti reddedilenleri anlatıyor"
assert_contains "$(cat "${SRVCTL_NGINX_CUSTOM_DIR}/example_com/00-custom.conf")" "add_header" "nginx iskeleti add_header tuzağını anlatıyor"

# İskelet ÜZERİNE YAZMAZ (mevcut ayarları silmemeli)
printf 'memory_limit = 512M\n' > "${SRVCTL_PHP_INI_DIR}/example_com.ini"
_domain_provision_conf_skeletons example.com
assert_contains "$(cat "${SRVCTL_PHP_INI_DIR}/example_com.ini")" "memory_limit = 512M" \
    "mevcut .ini üzerine YAZILMAZ"

echo "── Bölüm B: temizlik ──"
_domain_purge_conf_files example.com
test -f "${SRVCTL_PHP_INI_DIR}/example_com.ini"; assert_eq "$?" "1" ".ini silindi"
test -d "${SRVCTL_NGINX_CUSTOM_DIR}/example_com"; assert_eq "$?" "1" "nginx custom dizini silindi"

echo "── Bölüm C: klonlama ──"
mkdir -p "${WEB_ROOT}/kaynak.com" "${WEB_ROOT}/hedef.com"
_domain_provision_conf_skeletons kaynak.com
printf 'memory_limit = 777M\n' > "${SRVCTL_PHP_INI_DIR}/kaynak_com.ini"
printf 'client_max_body_size 77M;\n' > "${SRVCTL_NGINX_CUSTOM_DIR}/kaynak_com/00-custom.conf"
_domain_clone_conf_files kaynak.com hedef.com
assert_contains "$(cat "${SRVCTL_PHP_INI_DIR}/hedef_com.ini")" "memory_limit = 777M" ".ini klonlandı"
assert_contains "$(cat "${SRVCTL_NGINX_CUSTOM_DIR}/hedef_com/00-custom.conf")" "client_max_body_size 77M;" \
    "nginx override klonlandı"

test_summary
```

- [ ] **Step 2: Testi koş, başarısız olduğunu doğrula**

Run: `bash tests/test_domconf_lifecycle.sh`
Expected: FAIL — `_domain_provision_conf_skeletons: command not found`

- [ ] **Step 3: Üç yaşam döngüsü helper'ını `lib/domain.sh`'a ekle**

```bash
# ───────────────────────────────────────────────────────────────
#  Per-domain conf dosyaları — yaşam döngüsü kancaları
#  (domain add / remove / clone tarafından çağrılır)
# ───────────────────────────────────────────────────────────────

# İskeletleri oluşturur. MEVCUT dosyanın ÜZERİNE YAZMAZ — operatörün
# ayarlarını silmek, bu özelliğin çözmeye çalıştığı problemin ta kendisi olurdu.
_domain_provision_conf_skeletons() {
    local domain="$1"
    local sname; sname=$(safe_name "$domain")
    _domain_load_conf_lib || { warn "domconf modülü yüklenemedi — conf iskeletleri oluşturulmadı"; return 0; }

    local ini_dir="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}"
    local ini="${ini_dir}/${sname}.ini"
    mkdir -p "$ini_dir"
    if [[ ! -f "$ini" ]]; then
        _domconf_ini_skeleton "$domain" > "$ini"
        chmod 644 "$ini"
    fi

    local ng_dir="${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}/${sname}"
    local ng="${ng_dir}/00-custom.conf"
    mkdir -p "$ng_dir"
    if [[ ! -f "$ng" ]]; then
        _domconf_nginx_skeleton "$domain" > "$ng"
        chmod 644 "$ng"
    fi
}

_domain_purge_conf_files() {
    local domain="$1"
    local sname; sname=$(safe_name "$domain")
    [[ -n "$sname" ]] || return 0
    rm -f -- "${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}/${sname}.ini"
    rm -rf -- "${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}/${sname}"
}

_domain_clone_conf_files() {
    local src="$1" dst="$2"
    local s_sname; s_sname=$(safe_name "$src")
    local d_sname; d_sname=$(safe_name "$dst")
    local ini_dir="${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}"
    local ng_root="${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}"

    mkdir -p "$ini_dir" "${ng_root}/${d_sname}"
    [[ -f "${ini_dir}/${s_sname}.ini" ]] \
        && { cp "${ini_dir}/${s_sname}.ini" "${ini_dir}/${d_sname}.ini"; chmod 644 "${ini_dir}/${d_sname}.ini"; }
    [[ -f "${ng_root}/${s_sname}/00-custom.conf" ]] \
        && { cp "${ng_root}/${s_sname}/00-custom.conf" "${ng_root}/${d_sname}/00-custom.conf"; chmod 644 "${ng_root}/${d_sname}/00-custom.conf"; }
    return 0
}
```

- [ ] **Step 4: Üç çağrı noktasını bağla**

1. `_domain_add` içinde, FPM pool/unit render adımından **önce** (böylece ilk render iskeleti zaten görür):
```bash
    _domain_provision_conf_skeletons "$domain"
```

2. `_domain_purge_resources` içinde, "5. Nginx vhost" adımının hemen ardından:
```bash
    # 5.5. Per-domain conf override'ları (.ini + nginx custom.d)
    _domain_purge_conf_files "$domain"
```

3. `_domain_clone` içinde, hedef domain oluşturulduktan sonra:
```bash
    _domain_clone_conf_files "$source" "$target"
```
(Değişken adlarını `_domain_clone`'un kendi yerel adlarıyla eşleştir.)

- [ ] **Step 5: Testi koş**

Run: `bash tests/test_domconf_lifecycle.sh && bash tests/run.sh`
Expected: PASS — tüm assert'ler geçmeli (test_summary FAIL=0 basmalı)

- [ ] **Step 6: Commit**

```bash
git add lib/domain.sh tests/test_domconf_lifecycle.sh
git commit -m "domain: conf override dosyalarını add/remove/clone yaşam döngüsüne bağla

İskelet mevcut dosyanın üzerine YAZMAZ — operatörün ayarını silmek tam da
bu özelliğin çözdüğü problemdi.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Yardım metni, completion, README

**Files:**
- Modify: `bin/srvctl` (help), `lib/domain.sh` (modül help), `completions/srvctl.bash`, `completions/srvctl.zsh`, `README.md`

**Interfaces:** Yok — kullanıcıya görünen dokümantasyon.

- [ ] **Step 1: `bin/srvctl` help metnine ekle**

`domain resources` satırının altına:

```bash
        echo -e "    ${CYAN}domain reload${NC} <domain>|--all      PHP-FPM + nginx reload (doğru unit'i kendi bulur)"
        echo -e "    ${CYAN}domain ini${NC} <domain>               Domaine özel PHP ayarları (\$EDITOR; sudo -E gerekir)"
        echo -e "    ${CYAN}domain nginx${NC} <domain>             Domaine özel nginx ayarları (\$EDITOR; sudo -E gerekir)"
```

- [ ] **Step 2: `cmd_domain`'in kendi help bloğuna aynı üç satırı ekle**

`lib/domain.sh` içindeki `help)` dalında, mevcut biçimi izleyerek.

- [ ] **Step 3: Completion dosyalarını güncelle**

`completions/srvctl.bash` — `domain` alt-komut listesine `reload ini nginx` ekle; bayrak tamamlaması:
```bash
        reload) COMPREPLY=($(compgen -W "--all --fpm --nginx $(_srvctl_domains)" -- "$cur")) ;;
        ini|nginx) COMPREPLY=($(compgen -W "--show --file --force $(_srvctl_domains)" -- "$cur")) ;;
```
(Dosyadaki mevcut yardımcı fonksiyon adını kullan — `_srvctl_domains` yoksa oradaki karşılığı.)

`completions/srvctl.zsh` — aynı üç alt-komutu ve bayrakları o dosyanın kendi biçiminde ekle.

- [ ] **Step 4: README.md'ye komut referansı + `sudo -E` notu ekle**

Domain komutları tablosuna üç satır, ve altına:

```markdown
> **`sudo -E` notu:** `sudo` varsayılan olarak `env_reset` uygular ve `$EDITOR`'ü
> temizler. `sudo srvctl domain ini example.com` bu yüzden sizin editörünüzü
> değil `nano`'yu açar. Kendi editörünüzü kullanmak için `sudo -E srvctl domain
> ini example.com` çalıştırın.

> **Override dosyaları nerede:**
> - PHP: `/etc/srvctl/php.d/<safe_name>.ini` → pool config'ine `php_admin_value` olarak enjekte edilir
> - nginx: `/etc/nginx/custom.d/<safe_name>/00-custom.conf` → vhost'un server bloğuna en sonda include edilir
>
> Her ikisi de render'ın dışındadır: `domain repair`, `php-switch` ve
> `security harden-fpm` bunları **ezmez**, her seferinde yeniden uygular.
```

- [ ] **Step 5: Tüm suite'i koş**

Run: `bash tests/run.sh`
Expected: tüm testler PASS

- [ ] **Step 6: Commit**

```bash
git add bin/srvctl lib/domain.sh completions/ README.md
git commit -m "docs: domain reload/ini/nginx komutlarını help, completion ve README'ye ekle

sudo -E tuzağı açıkça belgelendi (env_reset \$EDITOR'ü temizler).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: HOST doğrulama kontrol listesi

**Files:**
- Create: `docs/superpowers/plans/2026-08-03-domain-conf-edit-reload-HOST-checklist.md`

macOS'ta doğrulanamayan her şey burada toplanır. Proje konvansiyonu: uygulama macOS'ta biter, gerçek doğrulama Ubuntu host'ta yapılır.

- [ ] **Step 1: Kontrol listesini yaz**

Aşağıdaki maddeleri, her biri için **çalıştırılacak komut** ve **beklenen çıktı** ile birlikte yaz:

1. **İzole FPM reload** — izole unit'li bir domainde `srvctl domain reload <d> --fpm`; `systemctl status srvctl-fpm-<sname>.service` ile "reloaded" ve aktif teyidi
2. **Paylaşılan FPM reload** — `DOMAIN_ISOLATED_FPM=false` kurulumda aynı komut `php<ver>-fpm`'i hedefliyor
3. **`.ini` GERÇEKTEN etkili mi** — `srvctl domain ini <d> --file` ile `memory_limit = 512M`; ardından domainde `<?php echo ini_get('memory_limit');` → **512M** dönmeli. *Bu, RC3'ün (php_admin_value sessizce ezer) gerçekleşmediğinin tek kanıtıdır*
4. **repair override'ı korur** — 3. adımdan sonra `srvctl domain repair <d>`; pool'da `memory_limit` hâlâ 512M ve **tek satır**
5. **php-switch override'ı korur** — `srvctl domain php-switch <d> <başka_ver>`; override yeni pool'da da var
6. **nginx override çalışıyor** — `client_max_body_size 100M;` ekle, 60MB'lık bir dosya yükle → 413 almamalı
7. **Eski domainde include kapısı** — bu spec'ten önce oluşturulmuş bir domainde `srvctl domain nginx <d>` → fail-closed durmalı; `srvctl domain repair <d>` sonrası çalışmalı
8. **`--force` yolu** — `srvctl domain ini <d> --force` ile `open_basedir` set et; `logs/` altındaki srvctl log'unda ve bildirim kanalında kayıt görünmeli
9. **Rollback servis kesintisi yaratmıyor** — bozuk `.ini` uygula; komut hata versin, `curl` ile site **200 dönmeye devam etsin**, pool dosyası eski halinde olsun
10. **`sudo` vs `sudo -E`** — `sudo srvctl domain ini <d>` nano açar; `sudo -E` operatörün `$EDITOR`'ünü açar
11. **`--all` ölçek davranışı** — birden fazla domainli host'ta `srvctl domain reload --all`; nginx **bir kez** reload edilmeli (`journalctl -u nginx` ile teyit)
12. **Her iki LTS'te** — 1-11 arası maddeler Ubuntu 22.04 **ve** 24.04'te ayrı ayrı

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-03-domain-conf-edit-reload-HOST-checklist.md
git commit -m "docs: domain conf düzenleme için HOST doğrulama kontrol listesi

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Öz-denetim notları

**Spec kapsaması:** Spec'in §3 (mimari) → Task 1/2/3; §4 (reload) → Task 3; §5 (.ini) → Task 4/5/6; §6 (nginx) → Task 7; §7 (yaşam döngüsü) → Task 8; §8 (hata/rollback) → Task 6 Bölüm E-F ve Task 7 Bölüm E; §9.1 (unit testler) → her task'ın test adımı; §9.2 (HOST) → Task 10; §10 (`sudo -E`) → Task 9.

**Tip tutarlılığı:** `domain_fpm_unit` ve `reload_domain_fpm` her yerde `(sname, php_version)` sırasıyla çağrılır — `_deploy_reload_fpm`'in kendi `(php_version, sname)` sırası korunur çünkü o mevcut bir dış sözleşmedir. `parse_php_ini_overrides` çıktısı her tüketicide `anahtar=değer` satır biçimindedir. `_domconf_scan_*` fonksiyonlarının tümü "0=temiz, 1=bulgu" predikatıdır (bash konvansiyonunun tersi gibi görünür ama `if ! findings=$(...)` deyimiyle doğal okunur).

**Bilinen sınır:** `_domconf_scan_nginx` satır bazlıdır ve blok-farkında değildir; `add_header` inheritance tuzağını yakalayamaz (spec §6.1'de gerekçelendirildi, iskelet dosyasında operatöre anlatılır).
