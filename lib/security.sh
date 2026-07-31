#!/bin/bash
# ═══════════════════════════════════════════════
#  security.sh — Güvenlik Denetimi
#  Tüm katmanları kontrol edip skor verir
# ═══════════════════════════════════════════════

# ─── Audit enforcement parser'ları (saf; fixture ile test edilebilir) ───
# aa-status metninde <profil> "enforce mode" bölümünde listeli mi? (0=evet)
_audit_aa_enforced() {
    local text="$1" profile="$2"
    awk -v p="$profile" '
        /enforce mode\.$/ { sec=1; next }
        / mode\.$/        { sec=0 }
        /processes are/   { sec=0 }
        sec==1 { l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l); if (l==p) f=1 }
        END { exit(f?0:1) }
    ' <<< "$text"
}

# /proc/<pid>/status metninde Seccomp == 2 (filter mode) mı? (0=evet)
_audit_seccomp_filtered() {
    local val
    val=$(grep -E '^Seccomp:' <<< "$1" | awk '{print $2}')
    [[ "$val" == "2" ]]
}

# ControlGroup metni <slice>'ı içeriyor mu? (0=evet)
_audit_in_slice() {
    [[ "$1" == *"$2"* ]]
}

# systemctl list-units (--all --no-legend --plain <glob>) METNİNİ parse eder;
# yalnız ACTIVE sütunu (3.) 'active' olan unit adlarını (1. sütun) basar.
# Saf: systemctl'e DOKUNMAZ, yalnız METNİ işler — worker/scheduler audit'i
# (aşağıda) template/instance unit'lerin (srvctl-worker-<sname>@*.service)
# HANGİLERİNİN gerçekten koştuğunu bu parser üzerinden bulur; 'failed'/
# 'inactive' instance'lar (ör. eski/çökmüş bir kuyruk) elenir — bunlar için
# PID aranıp FAIL üretilmemeli, çünkü çalışmıyor olmaları bir hata değildir.
_audit_parse_active_units() {
    awk '$3=="active"{print $1}' <<< "$1"
}

# /proc/<pid>/attr/current İLK SATIRI TAM OLARAK '<profile> (enforce)' mi?
# (0=evet). Format: 'srvctl-example_com (enforce)\n' (complain modunda
# '(complain)', hiç attach değilse 'unconfined\n'). _audit_aa_enforced (aa-status
# GENEL listesini parse eder — "sistemde BİR YERDE bu profil enforce" sorusuna
# cevap verir) ile TAMAMLAYICIDIR: BU fonksiyon kernel'in SPESİFİK bir PID için
# raporladığı GERÇEK attach'ı doğrular — paylaşılan/per-domain-olmayan bir FPM
# master'da profil aa-status'te enforce görünse bile BU PID ona hiç BAĞLI
# olmayabilir ('unconfined' döner). _security_audit bu fonksiyonu gerçek FPM
# master PID'i üzerinden çağırır (bkz. _audit_domain_fpm_pid).
_audit_aa_attr_enforced() {
    local text="$1" profile="$2"
    local first_line
    first_line="$(printf '%s' "$text" | head -n1)"
    [[ "$first_line" == "${profile} (enforce)" ]]
}

# ─── Scheduler enforcement KARARI (saf; BULGU kapanışı — worker/scheduler
# audit'i hiç yoktu) ───
# Scheduler unit'i (srvctl-scheduler-<sname>.service) 'oneshot'tur ve TIMER
# tarafından dakikada bir tetiklenir (bkz. templates/systemd/srvctl-scheduler.
# service.tpl/.timer.tpl) — servis çoğu zaman 'inactive (dead)' görünür, bu
# yüzden "FPM'deki gibi canlı bir PID bekle" yaklaşımı YANLIŞ olur: timer
# aktifken servis PID'i neredeyse HER ZAMAN yoktur ve bu bir arıza DEĞİLDİR.
#
# KARAR: PID mevcutsa (audit tam da tetiklenme anına denk geldiyse) GERÇEK
# attach (/proc/<pid>/attr/current) tercih edilir — bu en güçlü kanıttır.
# PID yoksa (asıl/normal durum), DOLAYLI doğrulamaya düşülür: profilin
# sistem genelinde enforce modda YÜKLÜ olup olmadığına (aa-status metni)
# bakılır. Bu meşrudur çünkü AppArmor'da enforce/complain modu PROFİLİN
# kendisinin özelliğidir (belirli bir PID'in DEĞİL) — profil enforce modda
# yüklüyse, timer bir sonraki tetiklemede exec ettiği süreci de o profille
# (ve o modda) confine eder. "Servis o an ölü" ile "hiç doğrulanamadı"
# farklı şeylerdir: PID yokluğu FAIL üretmez, ama profil complain'e düşmüşse
# (ya da hiç yüklü değilse) dolaylı kontrol de FAIL üretir.
#
# PREDİKAT: 0=enforce doğrulandı, 1=değil. Girdi olarak GERÇEK PID/aa-status
# ÇAĞRISI YAPMAZ — çağıran (_check_scheduler_aa) veriyi toplar, bu fonksiyon
# yalnız KARARI verir (test edilebilirlik için ayrıştırıldı).
#
# YARIŞ DURUMU DÜZELTMESİ (koordinatör bulgusu, gerçek VM ölçümü): worker DA
# artık bu fonksiyonu kullanıyor (bkz. _check_worker_aa) — isim tarihsel
# olarak 'scheduler' ama karar tamamen GENELDİR ("PID var mı" + "varsa attr
# OKUNABİLDİ Mİ"). Sebep: PID yakalanıp attr okunmaya çalışılırken süreç
# tam ARADA ölebilir (scheduler oneshot'ta saniyeden kısa çalıştığı için bu
# YAYGIN; worker'da Restart=on-failure ile YENİDEN BAŞLARKEN dar ama mümkün
# bir pencere). Bu durumda attr_text BOŞ gelir — has_pid=1 + attr_text=""
# ile çağrılırsa _audit_aa_attr_enforced boş metni "enforce DEĞİL" sayar ve
# YANLIŞ FAIL üretilirdi (100 domain sıralı denetlenirken bu her audit
# koşusunda tekrarlanabilir bir gürültü kaynağıydı). ÇÖZÜM ÇAĞIRANDA: attr
# okunamazsa çağıran has_pid=0 İLE çağırır (aşağıdaki case'e düşer) — yani
# "attr HİÇ okunamadı" (kanıt yok, süreç kaçırıldı) ile "attr okundu ve
# enforce DEĞİL" (gerçek bulgu) BURADA KARIŞMAZ; ayrım çağıranın has_pid
# değerini NASIL belirlediğinde yatar (bkz. _check_worker_aa/
# _check_scheduler_aa: attr boşsa has_pid=0'a DÜŞÜLÜR, 1 OLARAK KALMAZ).
_audit_scheduler_enforced() {
    local has_pid="$1" attr_text="$2" aa_status_text="$3" profile="$4"
    if [[ "$has_pid" == "1" ]]; then
        _audit_aa_attr_enforced "$attr_text" "$profile"
    else
        _audit_aa_enforced "$aa_status_text" "$profile"
    fi
}

# ─── FPM izolasyon durumu KARARI (saf; koordinatör bulgusu — audit hiçbir
# domainin PAYLAŞILAN havuzda mı yoksa izole unit'te mi çalıştığını
# kontrol etmiyordu) ───
# GEREKÇE: AppArmorProfile=/SystemCallFilter=/NoNewPrivileges= YALNIZ
# 'srvctl-fpm-<sname>.service' (per-domain, T7a) unit'inde tanımlıdır.
# Paylaşılan 'php<ver>-fpm.service' dağıtımın KENDİ unit'idir — bunların
# HİÇBİRİNİ taşımaz. Bir domain paylaşılan havuza düşerse (izolasyon hiç
# denenmemiş/başarısız olmuş/eski bir domain hiç migrate edilmemiş) MAC
# katmanının TAMAMINI SESSİZCE kaybeder (Chankro zincirindeki 'exec deny'
# tam olarak buna dayanır — disable_functions CLI'da uygulanmaz, onu
# durduran TEK şey AppArmor'ın exec deny'idir).
#
# ÜÇ YOLDAN BİRİYLE bu duruma düşülür: (a) operatör conf/srvctl.conf'ta
# DOMAIN_ISOLATED_FPM=false vermiş (BİLİNÇLİ tercih), (b) 'domain add'
# sırasında izolasyon başarısız olmuş (lib/domain.sh: "Per-domain FPM
# izolasyonu BAŞARISIZ..." — akış DEVAM eder, domain paylaşılan pool'da
# kalır), (c) T7a öncesi eklenip hiç migrate edilmemiş eski domainler.
# (a) BİLİNÇLİ bir tercihtir — kullanıcı kendi kararını FAIL olarak
# GÖRMEMELİ (ama görünmez de olmamalı, bu yüzden WARN). (b)/(c) SESSİZ
# SAPMADIR — bunlar asıl hedeftir, FAIL üretilir.
#
# KARAR: izole (config VAR + unit AKTİF) → "PASS". Değilse (paylaşılan
# havuzda) → operatör DOMAIN_ISOLATED_FPM=false'ı AÇIKÇA vermişse "WARN",
# aksi halde (varsayılan true iken sessizce izole OLAMAMIŞ) "FAIL".
#
# Girdi: <config_exists:0|1> <unit_active:0|1> <isolated_setting:true|false>
# Çıktı (stdout): "PASS"|"WARN"|"FAIL" — çağıran (_check_fpm_isolation)
# bunu _pass/_fail/_warn_result'a yönlendirir. Saf: systemctl/dosya
# sistemine DOKUNMAZ (fixture ile test edilir, bkz. tests/test_audit_parsers.sh).
_audit_fpm_isolation_verdict() {
    local config_exists="$1" unit_active="$2" isolated_setting="$3"
    if [[ "$config_exists" == "1" && "$unit_active" == "1" ]]; then
        echo "PASS"
    elif [[ "$isolated_setting" == "false" ]]; then
        echo "WARN"
    else
        echo "FAIL"
    fi
}

# ─── Domain'in GERÇEK FPM master PID'ini tespit eder (fail-closed) ───
# PREDİKAT DEĞİL: stdout'a PID basar (0), bulunamazsa stdout boş + 1 döner.
# Per-domain unit (harden-fpm --apply sonrası, T7a) varsa ONU tercih eder —
# gerçek AppArmor/seccomp/cgroups attach'ı bu sürece aittir. Yoksa paylaşılan
# php<ver>-fpm master'ına düşer; bu durumda AppArmor per-domain profiline
# BAĞLI DEĞİLDİR ve _security_audit bunu BİLEREK FAIL eder (bkz. o
# fonksiyonun yorumu — "davranış değişikliği" notu).
_audit_domain_fpm_pid() {
    local sname="$1" php_ver="$2"
    local unit="srvctl-fpm-${sname}.service" pid
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "$pid"
            return 0
        fi
    fi
    pid="$(systemctl show -p MainPID --value "php${php_ver}-fpm.service" 2>/dev/null)"
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        echo "$pid"
        return 0
    fi
    return 1
}

# Verilen PID için '/proc/<pid>/attr/current' yolunu üretir (stdout). Test-
# seam: SRVCTL_PROC_DIR override edilebilir — SRVCTL_SYSTEMD_DIR/SRVCTL_FPM_DIR
# ile AYNI desen (bkz. CLAUDE.md "Test-seams for macOS dev"). Varsayılan
# GERÇEK '/proc' — HOST'ta davranış DEĞİŞMEZ. Worker/scheduler'ın YARIŞ
# DURUMU düzeltmesi (bkz. _check_worker_aa/_check_scheduler_aa) bu sayede
# fixture'la test edilebiliyor: gerçek Linux'ta '/proc/<pid>' PID süreç
# çıktıktan hemen sonra kaybolur — macOS'ta '/proc' hiç YOKTUR, bu yüzden
# gerçek 'complain' senaryosu SRVCTL_PROC_DIR olmadan test edilemezdi.
_audit_proc_attr_path() {
    printf '%s/%s/attr/current\n' "${SRVCTL_PROC_DIR:-/proc}" "$1"
}

# Verilen systemd unit'inin MainPID'ini döner (stdout, 0=bulundu). Boş/'0'
# ise unit çalışmıyor demektir (predikat: 1). _audit_domain_fpm_pid ile AYNI
# ilkel katman — worker instance'ları VE scheduler service'i için ORTAK
# kullanılır (bkz. _check_worker_aa/_check_scheduler_aa, _security_audit).
_audit_unit_mainpid() {
    local unit="$1" pid
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
    [[ -n "$pid" && "$pid" != "0" ]] || return 1
    printf '%s\n' "$pid"
}

# ─── Domain'in ÇALIŞAN worker instance unit adlarını tespit eder ───
# (fail-closed; BULGU kapanışı). PREDİKAT DEĞİL: satır satır unit adı basar
# (0=en az bir instance aktif), hiçbiri aktif değilse boş çıktı + 1 döner —
# bu NORMAL bir durumdur (her domain kuyruk worker'ı kullanmaz; bkz.
# _check_worker_aa'nın bunu FAIL SAYMAMASI).
#
# TÜM aktif instance'lar döner (TEK BİRİ DEĞİL): worker template unit'i TEK
# bir dosyadır (srvctl-worker-<sname>@.service) ve AppArmorProfile= yönergesi
# o dosyada BİR KEZ tanımlıdır, ama AppArmor attach'ı exec() ANINDA sabitlenir
# — bir instance, unit dosyası (ör. 'domain repair' ile profil enforce'a
# alınmadan ÖNCE) başlatılmış olabilir ve o PID'in mevcut attr'ı, SONRADAN
# başlatılan bir instance'tan FARKLI olabilir (profil dosyası aynı olsa bile,
# eski instance'ın exec-time confinement'ı DEĞİŞMEZ). Tek instance'a bakmak bu
# drift'i KAÇIRIR — bu yüzden glob'daki HEPSİ kontrol edilir.
_audit_domain_active_worker_units() {
    local sname="$1"
    local glob="srvctl-worker-${sname}@*.service" out
    out="$(systemctl list-units --all --no-legend --plain "$glob" 2>/dev/null || true)"
    local units
    units="$(_audit_parse_active_units "$out")"
    [[ -n "$units" ]] || return 1
    printf '%s\n' "$units"
}

# ───────────────────────────────────────────────────────────────
#  Eval'siz kontrol çalıştırıcı (saf, test edilebilir).
#  Kullanım: _security_run_check <on_ok_fn> <on_bad_fn> <label> <cmd...>
#  cmd argv olarak DOĞRUDAN çalıştırılır — asla eval/string-expand edilmez.
# ───────────────────────────────────────────────────────────────
_security_run_check() {
    local on_ok="$1" on_bad="$2" label="$3"
    shift 3
    if "$@" >/dev/null 2>&1; then
        "$on_ok" "$label"
    else
        "$on_bad" "$label"
    fi
}

# ───────────────────────────────────────────────────────────────
#  Worker/scheduler '-cli' profili AppArmor enforcement — BULGU kapanışı.
#  ÖNCEDEN: audit worker/scheduler süreçlerini HİÇ görmüyordu ('grep -n
#  "worker\|scheduler" lib/security.sh' sıfır sonuç veriyordu). '-cli' profili
#  worker/scheduler için TEK gerçek MAC kısıtıdır — CLI SAPI'de
#  'disable_functions' UYGULANMAZ (global ini yalnız fpm/conf.d/'ye yazılır,
#  cli/php.ini'de bu direktif BOŞTUR). Profil sessizce complain moda düşerse
#  worker/scheduler fiilen konfine olmaz ve hiçbir çıktı bunu söylemezdi
#  (sessiz güvenlik kaybı). Aşağıdaki iki fonksiyon FPM bloğuyla AYNI deseni
#  (PID → /proc/<pid>/attr/current → _audit_aa_attr_enforced) worker/
#  scheduler'a özgü ÜÇ farkla uygular:
#
#    1) Worker template/instance'tır — TÜM aktif instance'lar kontrol edilir,
#       tek biri DEĞİL (bkz. _audit_domain_active_worker_units yorumu:
#       exec-time attach drift'i tek-instance kontrolünü kaçırır).
#    2) Scheduler oneshot+timer'dır — servis çoğu zaman ölüdür (dead).
#       "PID bekle" burada YANLIŞ olur; timer aktifse ama PID yoksa DOLAYLI
#       doğrulamaya (aa-status — bkz. _audit_scheduler_enforced) düşülür.
#    3) YARIŞ DURUMU (koordinatör bulgusu, gerçek VM ölçümüyle doğrulandı):
#       PID yakalanıp '/proc/<pid>/attr/current' okunmaya çalışılırken süreç
#       TAM ARADA ölebilir — scheduler oneshot'ta bu YAYGINDIR (ölçülen
#       gerçek çalışma süresi <1sn), worker'da Restart=on-failure ile
#       yeniden başlarken DAHA DAR ama yine de mümkündür. Bu durumda attr
#       BOŞ gelir; "attr HİÇ okunamadı" (kanıt yok, süreç kaçırıldı) ile
#       "attr okundu ve enforce DEĞİL" (gerçek bulgu) KARIŞTIRILMAMALIDIR —
#       aksi halde 100 domain sıralı denetlenirken HER audit koşusunda
#       rastgele bir domaine YANLIŞ FAIL ("... repair çalıştırın" — ki
#       repair hiçbir şeyi düzeltmez) düşme olasılığı ihmal edilebilir
#       değildir. ÇÖZÜM: attr boşsa (dosya okunamadı/süreç orada değil)
#       has_pid=0'A DÜŞÜLÜR — yani "PID hiç yokmuş gibi" DOLAYLI aa-status
#       doğrulamasına geri çekilir (bkz. _audit_scheduler_enforced —
#       AppArmor'da enforce/complain PROFİLİN özelliğidir, PID'in değil, bu
#       yüzden bu geri çekiliş sessiz güvenlik kaybını YİNE yakalar). Yalnız
#       attr GERÇEKTEN okunup profil UYUŞMUYORSA (complain/başka profil)
#       FAIL üretilir.
#
#  HER İKİSİNDE DE: worker/scheduler HİÇ tanımlı/aktif DEĞİLSE (çoğu domain
#  kuyruk/zamanlayıcı KULLANMAZ) bu NORMALDİR — FAIL/WARN ÜRETİLMEZ, sessizce
#  atlanır. Ama "unit tanımlı VE aktif ama profil enforce DEĞİL" durumu
#  KESİNLİKLE FAIL'dir.
#
#  Kullanım: _check_worker_aa/_check_scheduler_aa <on_pass_fn> <on_fail_fn>
#            <on_warn_fn> <domain> <sname>
#  _security_run_check ile AYNI eval'siz/explicit-injection deseni: TOP-LEVEL
#  (modül kapsamında, _security_audit'e nested DEĞİL) tanımlanmıştır ki
#  _security_audit'i (tüm OS/servis kontrolleriyle) hiç çalıştırmadan,
#  doğrudan kendi sayaç/callback'leriyle birim test edilebilsin (bkz.
#  tests/test_worker_scheduler_audit.sh).
# ───────────────────────────────────────────────────────────────
_check_worker_aa() {
    local on_pass="$1" on_fail="$2" on_warn="$3" domain="$4" sname="$5"
    local cli_profile="srvctl-${sname}-cli"
    local units
    units="$(_audit_domain_active_worker_units "$sname")" || return 0   # aktif instance yok — NORMAL, sessizce atla

    local unit
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        local raw_pid=""
        if ! raw_pid="$(_audit_unit_mainpid "$unit")"; then
            "$on_warn" "${domain}: worker PID alınamadı (${unit}) — AppArmor doğrulanamadı"
            continue
        fi

        local pid="" has_pid=0 attr="" aa_text=""
        attr="$(cat "$(_audit_proc_attr_path "$raw_pid")" 2>/dev/null || true)"
        if [[ -n "$attr" ]]; then
            has_pid=1
            pid="$raw_pid"
        fi
        # attr BOŞSA (yarış — bkz. yukarıdaki (3) numaralı madde): has_pid=0
        # KALIR, DOLAYLI (aa-status) doğrulamaya GERİ ÇEKİLİR. "PID hiç
        # alınamadı" (yukarıdaki on_warn dalı) İLE KARIŞTIRILMASIN: BURADA
        # PID ALINDI, yalnız attr okunamadı — bu daha da güçlü bir "süreç
        # tam o an kayboldu" kanıtıdır, yine de WARN/FAIL yerine dolaylı
        # kontrole düşmek sessiz güvenlik kaybını hâlâ yakalar.
        if [[ "$has_pid" == "0" ]]; then
            if command -v aa-status &>/dev/null; then
                aa_text="$(aa-status 2>/dev/null || true)"
            else
                "$on_warn" "${domain}: worker AppArmor doğrulanamadı (${unit}, PID ${raw_pid} attr okunamadı, aa-status yok)"
                continue
            fi
        fi

        if _audit_scheduler_enforced "$has_pid" "$attr" "$aa_text" "$cli_profile"; then
            if [[ "$has_pid" == "1" ]]; then
                "$on_pass" "${domain}: worker AppArmor enforce (${unit}, PID ${pid})"
            else
                "$on_pass" "${domain}: worker AppArmor profili enforce modda (dolaylı doğrulama — ${unit}, PID ${raw_pid} attr okunamadı)"
            fi
        else
            if [[ "$has_pid" == "1" ]]; then
                "$on_fail" "${domain}: worker AppArmor enforce DEĞİL (${unit}, PID ${pid}: '${attr}') — 'srvctl domain repair ${domain}' çalıştırın"
            else
                "$on_fail" "${domain}: worker AppArmor profili enforce modda DEĞİL (${unit}) — 'srvctl domain repair ${domain}' çalıştırın"
            fi
        fi
    done <<< "$units"
}

_check_scheduler_aa() {
    local on_pass="$1" on_fail="$2" on_warn="$3" domain="$4" sname="$5"
    local cli_profile="srvctl-${sname}-cli"
    local timer="srvctl-scheduler-${sname}.timer" svc="srvctl-scheduler-${sname}.service"
    systemctl is-active --quiet "$timer" 2>/dev/null || return 0   # timer aktif değil — NORMAL

    local pid="" has_pid=0 attr="" aa_text=""
    local svc_pid=""
    if svc_pid="$(_audit_unit_mainpid "$svc")"; then
        attr="$(cat "$(_audit_proc_attr_path "$svc_pid")" 2>/dev/null || true)"
        if [[ -n "$attr" ]]; then
            has_pid=1
            pid="$svc_pid"
        fi
        # attr BOŞSA (yarış — PID yakalandı ama oneshot servis /proc
        # okunmadan ÖNCE bitti, bkz. yukarıdaki büyük yorumun (3) numaralı
        # maddesi): has_pid=0 KALIR, aşağıda DOLAYLI (aa-status) doğrulamaya
        # GERİ ÇEKİLİR — "attr hiç okunamadı" (kanıt yok) FAIL SAYILMAZ.
    fi

    if [[ "$has_pid" == "0" ]]; then
        if command -v aa-status &>/dev/null; then
            aa_text="$(aa-status 2>/dev/null || true)"
        else
            "$on_warn" "${domain}: scheduler AppArmor doğrulanamadı (aa-status yok, servis şu an ölü/PID yakalanamadı)"
            return 0
        fi
    fi

    if _audit_scheduler_enforced "$has_pid" "$attr" "$aa_text" "$cli_profile"; then
        if [[ "$has_pid" == "1" ]]; then
            "$on_pass" "${domain}: scheduler AppArmor enforce (PID ${pid} doğrulandı)"
        else
            "$on_pass" "${domain}: scheduler AppArmor profili enforce modda (dolaylı doğrulama — timer aktif, servis şu an ölü/yakalanamadı)"
        fi
    else
        if [[ "$has_pid" == "1" ]]; then
            "$on_fail" "${domain}: scheduler AppArmor enforce DEĞİL (PID ${pid}: '${attr}') — 'srvctl domain repair ${domain}' çalıştırın"
        else
            "$on_fail" "${domain}: scheduler AppArmor profili enforce modda DEĞİL (timer aktif) — 'srvctl domain repair ${domain}' çalıştırın"
        fi
    fi
}

# ───────────────────────────────────────────────────────────────
#  FPM izolasyon durumu kontrolü — koordinatör bulgusu (bkz.
#  _audit_fpm_isolation_verdict başlık yorumu — GEREKÇE/skor mantığı
#  orada). Kullanım: _check_fpm_isolation <on_pass_fn> <on_fail_fn>
#  <on_warn_fn> <domain> <sname> — AYNI explicit-injection deseni.
#
#  Test-seam: SRVCTL_FPM_DIR/SRVCTL_SYSTEMD_DIR — lib/domain.sh'taki AYNI
#  desen (_domain_render_fpm_unit vb.) — varsayılan '/etc/srvctl/fpm' /
#  '/etc/systemd/system', HOST'ta davranış DEĞİŞMEZ.
# ───────────────────────────────────────────────────────────────
_check_fpm_isolation() {
    local on_pass="$1" on_fail="$2" on_warn="$3" domain="$4" sname="$5"
    local fpm_dir="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}"
    local conf="${fpm_dir}/${sname}.conf"
    local unit="srvctl-fpm-${sname}.service"

    local config_exists=0 unit_active=0
    [[ -f "$conf" ]] && config_exists=1
    systemctl is-active --quiet "$unit" 2>/dev/null && unit_active=1

    # Gerçekten izole + aktifse EFEKTİF ayara hiç bakmaya GEREK YOK — PASS
    # verilir (bkz. _audit_fpm_isolation_verdict: bu dal isolated_setting'DEN
    # BAĞIMSIZDIR). Domain.sh'ı (bir sonraki adım) YÜKLEMEDEN önce bu kısa
    # devreyi yapmak, 100 domainlik bir kurulumda ZATEN izole olan
    # (çoğunluk) domainler için gereksiz cross-module sourcing'i atlar.
    if [[ "$config_exists" == "1" && "$unit_active" == "1" ]]; then
        "$on_pass" "${domain}: FPM izole unit'te çalışıyor (srvctl-fpm-${sname}.service — AppArmor/seccomp/NoNewPrivileges kapsamında)"
        return 0
    fi

    # İZOLE DEĞİL — WARN/FAIL ayrımı artık EFEKTİF ayara dayanır: GLOBAL
    # DOMAIN_ISOLATED_FPM > per-domain '.srvctl-meta' ISOLATED_FPM override
    # (bkz. _audit_effective_isolated_fpm başlık yorumu — koordinatör VM'de
    # meta'nın root:root 644 olup web kullanıcısınca YAZILAMADIĞINI, yani
    # bu okumaya güvenmenin GÜVENLİ olduğunu doğruladı).
    #
    # domain.sh yüklenemezse (bozuk kurulum — normalde BEKLENMEZ) efektif
    # değer BİLİNMEZ: SESSİZCE global değere düşüp per-domain override'ı
    # görmezden GELMEK, bilinçli bir WARN'ı FAIL'e yükseltebilir — bu yüzden
    # burada "kanıt yok" WARN üretilir, FAIL DEĞİL (attr-okunamadı yarış
    # durumundaki AYNI fail-closed/kanıt ayrımı — bkz. _check_worker_aa).
    local isolated_setting=""
    if ! isolated_setting="$(_audit_effective_isolated_fpm "$domain")"; then
        "$on_warn" "${domain}: FPM paylaşılan havuzda görünüyor ama efektif izolasyon ayarı doğrulanamadı (domain.sh yüklenemedi — global/.srvctl-meta ISOLATED_FPM override okunamadı, kanıt yok) — 'srvctl security harden-fpm ${domain} --apply' önerilir"
        return 0
    fi

    case "$(_audit_fpm_isolation_verdict "$config_exists" "$unit_active" "$isolated_setting")" in
        WARN)
            "$on_warn" "${domain}: FPM PAYLAŞILAN havuzda çalışıyor (efektif ISOLATED_FPM=false — global veya bu domain'in '.srvctl-meta'sında BİLİNÇLİ olarak ayarlanmış — bu domain için AppArmor/seccomp/NoNewPrivileges YOK)"
            ;;
        *)
            "$on_fail" "${domain}: FPM PAYLAŞILAN havuzda çalışıyor — AppArmor/seccomp/NoNewPrivileges kaybı (paylaşılan php-fpm master'ında bunların HİÇBİRİ tanımlı değil) — 'srvctl security harden-fpm ${domain} --apply' çalıştırın"
            ;;
    esac
}

# ───────────────────────────────────────────────────────────────
#  Cross-module yükleyici: harden-fs/harden-fpm domain.sh'taki
#  _domain_fs_plan / _domain_apply_fs_ownership / _fs_record_before /
#  _fs_revert / _domain_render_fpm_unit / _domain_activate_fpm_unit /
#  _domain_ensure_credentials fonksiyonlarına muhtaç. bin/srvctl `_load_and_run` YALNIZ tek modülü
#  source ettiğinden bu fonksiyonlar runtime'da tanımsızdı (command not
#  found → 127). Testler her iki modülü de source ettiği için bunu
#  göremiyordu. PREDİKAT: 0=yüklendi, 1=yüklenemedi (çağıran error eder).
# ───────────────────────────────────────────────────────────────
_security_load_domain_lib() {
    declare -F _domain_fs_plan >/dev/null 2>&1 \
        && declare -F _domain_render_fpm_unit >/dev/null 2>&1 \
        && return 0
    local lib="${SRVCTL_ROOT}/lib/domain.sh"
    [[ -f "$lib" ]] || return 1
    # shellcheck disable=SC1090
    source "$lib" || return 1
    declare -F _domain_fs_plan >/dev/null 2>&1 \
        && declare -F _domain_render_fpm_unit >/dev/null 2>&1
}

# ─── Domain'in EFEKTİF DOMAIN_ISOLATED_FPM değerini döner (koordinatör
# takibi — _check_fpm_isolation'ın kapsam sınırının kapanışı) ───
# ÖNCEDEN _check_fpm_isolation yalnız GLOBAL DOMAIN_ISOLATED_FPM'e
# bakıyordu; bir domain kendi '.srvctl-meta'sında BİLİNÇLİ olarak
# ISOLATED_FPM=false taşısa bile (global true iken) bu onu FAIL ediyordu —
# "bilinçli tercihi sessiz sapmadan ayır" ilkesinin bir seviye aşağıda
# İHLALİYDİ. Koordinatör gerçek VM'de doğruladı: '.srvctl-meta' root:root
# 644 — domain'in KENDİ web kullanıcısı bu dosyaya YAZAMAZ (Permission
# denied), yani meta'ya güvenmek (validate_bool ile doğrulanmış OKUMA)
# GÜVENLİDİR; kendi FAIL'ini WARN'a düşürecek bir saldırı yüzeyi AÇMAZ.
#
# lib/domain.sh:_domain_isolated_fpm_effective TEK doğruluk kaynağıdır:
# .srvctl-meta ISOLATED_FPM override > global DOMAIN_ISOLATED_FPM. Cross-
# module erişim _security_load_domain_lib (bu dosyada ZATEN kurulu
# konvansiyon, bkz. harden-fs/harden-fpm) ile guard'lı source edilir.
#
# PREDİKAT: 0=efektif değer GÜVENİLİR biçimde okundu (stdout: true|false).
# 1=domain.sh yüklenemedi/fonksiyon tanımsız — bu durumda stdout BOŞTUR ve
# ÇAĞIRAN (_check_fpm_isolation) bunu "kanıt yok" sayıp WARN üretmelidir;
# SESSİZCE global değere düşüp per-domain override'ı görmezden GELMEMELİDİR
# (aksi halde bilerek bir WARN durumunu FAIL'e yükseltmiş oluruz).
_audit_effective_isolated_fpm() {
    local domain="$1"
    _security_load_domain_lib || return 1
    declare -F _domain_isolated_fpm_effective >/dev/null 2>&1 || return 1
    _domain_isolated_fpm_effective "$domain"
}

# ─── .srvctl-meta beyaz liste (O1 TAM kapanışı — denetim DALGA 5) ───
# GEREKÇE: read_kv_file artık satır başına sabit anchor kullanıyor ('^KEY=')
# ve assert_safe_ident kapısı var (bkz. core.sh) — ama bu yalnız OKUMAYI
# süzer. Dosyanın İÇERİĞİ hardened-öncesi bir domainde saldırgan tarafından
# kirletilebilir (ör. baştaki boşlukla ' FRAMEWORK=laravel' ya da
# '#FRAMEWORK=...') ve 'harden-fs --apply' dosyayı root:root 644 yapsa bile
# bu satır write_meta'nın anchor'lı 'grep -v "^KEY="'i ile ASLA silinemediği
# için KALICI olarak dosyada kalıyordu (artık okunmuyor ama ölü/kirli satır
# olarak duruyor). Aşağıdaki fonksiyonlar dosyayı SIFIRDAN, yalnız bilinen
# anahtarların GEÇERLİ değerlerini yazarak yeniden üretir.
#
# TEK doğruluk kaynağı: srvctl'in '.srvctl-meta'ya YAZDIĞI TÜM anahtarlar
# burada olmalı (bkz. lib/domain.sh write_meta çağrıları: RATE_PROFILE/
# SENSITIVE_PATHS/FRAMEWORK/REDIS_SCRIPTING; lib/deploy.sh: RUN_MIGRATIONS/
# KEEP_GIT). Yeni bir 'write_meta domain KEY value' eklerken KEY buraya da
# eklenmelidir — aksi halde harden-fs --apply o anahtarı SESSİZCE atar.
_meta_known_keys() {
    # ISOLATED_FPM / RESOURCE_PROFILE bu oturumda eklendi (seçenek C + kaynak
    # profilleri). Whitelist'te olmazlarsa 'harden-fs --apply' meta'yı yeniden
    # yazarken bu iki satırı SESSİZCE atar → domain bir sonraki repair/add'de
    # varsayılana döner (izolasyon kapanır, profil 'standard'a düşer).
    #
    # HEALTH_OK_CODES: RUN_MIGRATIONS/KEEP_GIT/ISOLATED_FPM ile AYNI kategori
    # — kod hiçbir zaman 'write_meta' ile YAZMAZ, yalnız operatör elle
    # '.srvctl-meta'ya koyar ve lib/deploy.sh:_deploy_health_codes OKUR
    # (per-domain deploy sağlık kontrolü kabul listesi override'ı — ör. Basic
    # auth arkasındaki staging site 401 döndüğünde). Whitelist'te olmazsa
    # 'harden-fs --apply' bu satırı SESSİZCE atar, operatörün ayarı kaybolur
    # ve bir sonraki deploy YİNE otomatik rollback tetikler.
    echo "RATE_PROFILE SENSITIVE_PATHS FRAMEWORK RUN_MIGRATIONS KEEP_GIT REDIS_SCRIPTING REDIS_CHANNEL_ISOLATION ISOLATED_FPM RESOURCE_PROFILE HEALTH_OK_CODES"
}

# Anahtar bilinen listede mi? (PREDİKAT: 0=evet)
_meta_key_known() {
    local key="$1" k
    for k in $(_meta_known_keys); do
        [[ "$key" == "$k" ]] && return 0
    done
    return 1
}

# Bilinen bir anahtarın DEĞERİNİ KENDİ doğrulayıcısından geçirir (PREDİKAT:
# 0=geçerli). Doğrulayıcılar: RATE_PROFILE → rate_profile_line (core.sh,
# conf/rate-profiles.conf'ta tanımlı mı), SENSITIVE_PATHS → assert_regex_safe
# (core.sh, nginx regex charset'i — _domain_write_vhost'un sink-doğrulamasıyla
# AYNI), FRAMEWORK → ci4|laravel|symfony whitelist (_domain_read_framework ile
# AYNI liste), RUN_MIGRATIONS/KEEP_GIT → validate_bool (core.sh, lib/deploy.sh
# okuma yeriyle AYNI), REDIS_SCRIPTING → enabled|disabled|unknown ('unknown'
# _domain_redis_scripting_mode'un kendisinin ürettiği MEŞRU bir değerdir),
# HEALTH_OK_CODES → boşlukla ayrılmış HTTP kodu listesi; HER öğe
# core.sh/validate_http_code'dan geçmeli — lib/deploy.sh/_deploy_health_codes_valid
# ile AYNI doğrulayıcı (yeni regex uydurulmadı). Boş değer GEÇERSİZDİR: boş
# liste hiçbir kodu kabul etmez ve HER deploy'u sessizce geri aldırırdı.
_meta_validate_value() {
    local key="$1" value="$2"
    case "$key" in
        RATE_PROFILE)    [[ -n "$(rate_profile_line "$value")" ]] ;;
        SENSITIVE_PATHS) assert_regex_safe "$value" ;;
        FRAMEWORK)       [[ "$value" == "ci4" || "$value" == "laravel" || "$value" == "symfony" ]] ;;
        RUN_MIGRATIONS)  validate_bool "$value" ;;
        KEEP_GIT)        validate_bool "$value" ;;
        REDIS_SCRIPTING) [[ "$value" == "enabled" || "$value" == "disabled" || "$value" == "unknown" ]] ;;
        # Redis kanal (pub/sub) izolasyonu — 'resetchannels &<sname>:*' yalnız
        # Redis 6.2+ sözdizimidir; 22.04'ün 6.0.16'sında ACL parser bunu
        # tanımaz ve Redis HİÇ BAŞLAMAZ. Durum per-domain kalıcı kaydedilir.
        REDIS_CHANNEL_ISOLATION) [[ "$value" == "supported" || "$value" == "unsupported" || "$value" == "unknown" ]] ;;
        # Per-domain FPM izolasyonu override'ı (global DOMAIN_ISOLATED_FPM'i ezer)
        ISOLATED_FPM)    validate_bool "$value" ;;
        # Kaynak profili — conf/resource-profiles.conf'ta TANIMLI olmalı.
        # RATE_PROFILE ile aynı desen: profil satırı yoksa değer geçersiz sayılır.
        RESOURCE_PROFILE) [[ -n "$(resource_profile_line "$value" 2>/dev/null)" ]] ;;
        # Per-domain deploy sağlık kontrolü kabul listesi override'ı —
        # lib/deploy.sh:_deploy_health_codes_valid ile AYNI doğrulama: her
        # öğe validate_http_code'dan geçmeli, boş değer REDDEDİLİR (boş
        # liste hiçbir kodu kabul etmez → her deploy geri alınır).
        HEALTH_OK_CODES)
            local c
            [[ -n "$value" ]] || return 1
            for c in $value; do
                validate_http_code "$c" || return 1
            done
            return 0
            ;;
        *)               return 1 ;;
    esac
}

# '.srvctl-meta' dosyasını BEYAZ LİSTE ile yeniden yazar — yalnız bilinen VE
# geçerli anahtar=değer satırları hayatta kalır; tanınmayan anahtar, geçersiz
# değer, yorum satırı, boş satır ya da 'KEY=' öncesi boşluk/karakter içeren
# HER satır atılır. Saf-a-yakın yardımcı: yalnız TEK dosya üzerinde çalışır,
# çağıranın chown/chmod'una karışmaz (dosya zaten root:root olmalı — apply
# akışında _domain_apply_fs_ownership bunu ÖNCEDEN garanti eder).
# Çıktı: "<korunan satır sayısı> <atılan satır sayısı>" (tek satır, 'read' ile
# parse edilir — operatöre raporlamak çağıranın işidir).
_meta_rewrite_whitelist() {
    local meta_file="$1"
    [[ -f "$meta_file" ]] || { echo "0 0"; return 0; }

    local kept=0 dropped=0
    local -a kept_lines=()
    local key value line

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" != *=* ]]; then
            dropped=$((dropped + 1)); continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if assert_safe_ident "$key" && _meta_key_known "$key" && _meta_validate_value "$key" "$value"; then
            kept_lines+=("${key}=${value}")
            kept=$((kept + 1))
        else
            dropped=$((dropped + 1))
        fi
    done < "$meta_file"

    : > "$meta_file"
    local kl
    for kl in "${kept_lines[@]:-}"; do
        [[ -n "$kl" ]] && printf '%s\n' "$kl" >> "$meta_file"
    done
    echo "${kept} ${dropped}"
}

cmd_security() {
    require_root
    case "${1:-help}" in
        audit)      _security_audit ;;
        harden-fs)  _security_harden_fs "${@:2}" ;;
        harden-fpm) _security_harden_fpm "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl security audit"
            echo "            srvctl security harden-fs <domain>|--all [--apply|--revert]"
            echo "            srvctl security harden-fpm <domain>|--all [--apply]"
            echo ""
            ;;
    esac
}

_security_audit() {
    header "🔒 Güvenlik Denetimi"

    local pass=0
    local fail=0
    local warn_count=0

    # ─── Check fonksiyonları ───
    _pass() { echo -e "  ${GREEN}✅ PASS${NC}  $1"; pass=$((pass + 1)); }
    _fail() { echo -e "  ${RED}❌ FAIL${NC}  $1"; fail=$((fail + 1)); }
    _warn_result() { echo -e "  ${YELLOW}⚠️  WARN${NC}  $1"; warn_count=$((warn_count + 1)); }

    # Kullanım: _check "<etiket>" <cmd> <arg...>   (eval YOK — argv doğrudan çalışır)
    _check() {
        local label="$1"; shift
        _security_run_check _pass _fail "$label" "$@"
    }

    _warn_check() {
        local label="$1"; shift
        _security_run_check _pass _warn_result "$label" "$@"
    }

    # ═══ OS GÜVENLİĞİ ═══
    echo ""
    echo -e "  ${CYAN}── OS Güvenliği ──${NC}"
    _check "UFW firewall aktif" \
        bash -c "ufw status 2>/dev/null | grep -q 'Status: active'"
    _check "SSH root login kapalı" \
        bash -c "grep -rq 'PermitRootLogin no' /etc/ssh/sshd_config.d/ 2>/dev/null"
    _check "SSH şifre auth kapalı" \
        bash -c "grep -rq 'PasswordAuthentication no' /etc/ssh/sshd_config.d/ 2>/dev/null"
    _check "SSH varsayılan port değil" \
        bash -c "! grep -rq 'Port 22\$' /etc/ssh/sshd_config.d/ 2>/dev/null"
    _check "hidepid=2 aktif" \
        grep -q hidepid=2 /etc/fstab
    _check "Kernel hardening aktif" \
        test -f /etc/sysctl.d/99-srvctl-security.conf
    _check "symlink koruması (sysctl)" \
        bash -c "sysctl -n fs.protected_symlinks 2>/dev/null | grep -q '1'"
    _check "ASLR aktif (randomize_va_space=2)" \
        bash -c 'test "$(sysctl -n kernel.randomize_va_space 2>/dev/null)" -eq 2'
    _warn_check "Otomatik güvenlik güncellemeleri" \
        systemctl is-enabled unattended-upgrades

    # ═══ SERVİSLER ═══
    echo ""
    echo -e "  ${CYAN}── Servisler ──${NC}"
    _check "Nginx çalışıyor" systemctl is-active nginx
    # HOST BULGUSU (her iki LTS, gerçek VM): bu kontrol YALNIZ paylaşılan
    # php<ver>-fpm servisine bakıyordu. DOMAIN_ISOLATED_FPM=true (varsayılan)
    # ile her domain kendi srvctl-fpm-<sname>.service unit'ine taşınır ve
    # havuzu pool.d/'den kaldırılır; www.conf da init tarafından zaten
    # devre dışı bırakılmıştır. Sonuç: paylaşılan master'ın HİÇ HAVUZU KALMAZ,
    # php-fpm havuzsuz başlayamaz ('failed' + restart döngüsü) ve bu kontrol
    # SAHTE FAIL verirdi — yani tam izolasyon uygulanmış bir sunucu, izolasyon
    # yüzünden cezalandırılıyordu. Doğru soru "PHP-FPM çalışıyor mu" değil,
    # "PHP isteklerini karşılayan EN AZ BİR master var mı".
    _check "PHP-FPM çalışıyor (paylaşılan ya da per-domain)" \
        bash -c "systemctl is-active --quiet 'php${DEFAULT_PHP_VERSION}-fpm' \
                 || systemctl list-units --state=active --no-legend --plain 'srvctl-fpm-*.service' 2>/dev/null | grep -q ."
    _check "MariaDB çalışıyor" systemctl is-active mariadb
    _check "Redis çalışıyor" systemctl is-active redis-server
    _check "Fail2Ban çalışıyor" systemctl is-active fail2ban
    _check "auditd çalışıyor" systemctl is-active auditd
    _check "AppArmor çalışıyor" systemctl is-active apparmor

    # ═══ NGİNX ═══
    echo ""
    echo -e "  ${CYAN}── Nginx ──${NC}"
    _check "server_tokens off" \
        grep -q 'server_tokens off' /etc/nginx/nginx.conf
    _check "Varsayılan site kapalı" \
        bash -c "! test -f /etc/nginx/sites-enabled/default"
    _check "disable_symlinks aktif" \
        grep -q disable_symlinks /etc/nginx/nginx.conf
    _check "Rate limiting tanımlı" \
        grep -q limit_req_zone /etc/nginx/nginx.conf

    # ═══ MariaDB ═══
    echo ""
    echo -e "  ${CYAN}── MariaDB ──${NC}"
    _check "Sadece localhost dinliyor" \
        grep -q 'bind-address = 127.0.0.1' /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf
    _check "local-infile kapalı" \
        grep -q 'local-infile = 0' /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf
    _check "symbolic-links kapalı" \
        grep -q 'symbolic-links = 0' /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf
    _check "Root şifresi ayarlı" \
        test -f /root/.my.cnf
    _warn_check "Anonim kullanıcı yok" \
        bash -c "! mysql -N -e \"SELECT User FROM mysql.user WHERE User=''\" 2>/dev/null | grep -q '.'"

    # ═══ Redis ═══
    echo ""
    echo -e "  ${CYAN}── Redis ──${NC}"
    _check "Sadece localhost dinliyor" \
        grep -q 'bind 127.0.0.1' /etc/redis/redis.conf
    _check "Protected mode açık" \
        grep -q 'protected-mode yes' /etc/redis/redis.conf
    _check "ACL dosyası mevcut" \
        test -f /etc/redis/users.acl
    _check "Default kullanıcı kapalı" \
        grep -q 'user default off' /etc/redis/users.acl
    _check "FLUSHALL devre dışı" \
        grep -q 'rename-command FLUSHALL' /etc/redis/redis.conf

    # ═══ PHP GÜVENLİĞİ ═══
    echo ""
    echo -e "  ${CYAN}── PHP Güvenliği ──${NC}"
    local php_ini="/etc/php/${DEFAULT_PHP_VERSION}/fpm/conf.d/99-srvctl-security.ini"
    _check "expose_php = Off" \
        grep -q 'expose_php = Off' "${php_ini}"
    _check "display_errors = Off" \
        grep -q 'display_errors = Off' "${php_ini}"
    _check "allow_url_fopen = Off" \
        grep -q 'allow_url_fopen = Off' "${php_ini}"
    _check "allow_url_include = Off" \
        grep -q 'allow_url_include = Off' "${php_ini}"
    _check "disable_functions tanımlı" \
        grep -q disable_functions "${php_ini}"
    _check "Varsayılan www pool kapalı" \
        bash -c "! test -f /etc/php/${DEFAULT_PHP_VERSION}/fpm/pool.d/www.conf"

    # ═══ DOMAİN İZOLASYONU ═══
    echo ""
    echo -e "  ${CYAN}── Domain İzolasyonu ──${NC}"
    local domain_count=0

    # HOST BULGUSU: eskiden '${WEB_ROOT}/*/' ham taranıyordu; nginx'in kurduğu
    # '/var/www/html' domain sanılıp sahte FAIL üretiyordu. list_all_domains
    # artık '.credentials' kapısıyla yalnız gerçek srvctl domainlerini döndürür.
    local _domain_list
    mapfile -t _domain_list < <(list_all_domains)
    local domain
    for domain in "${_domain_list[@]}"; do
        [[ -n "$domain" ]] || continue
        local dir="${WEB_ROOT}/${domain}/"
        [[ -d "$dir" ]] || continue
        local sname php_ver PHP_VERSION
        sname=$(safe_name "$domain")
        php_ver="${DEFAULT_PHP_VERSION}"

        # Credentials'tan PHP versiyon bilgisini parse et (source DEĞİL); her döngüde sıfırla
        if [[ -f "${dir}.credentials" ]]; then
            PHP_VERSION=""
            read_kv_file "${dir}.credentials" PHP_VERSION
            if [[ -n "$PHP_VERSION" ]] && assert_php_version "$PHP_VERSION"; then
                php_ver="$PHP_VERSION"
            fi
        fi

        # Chroot kontrol — HOST BULGUSU: yalnız PAYLAŞILAN havuz yoluna
        # bakılıyordu. 'security harden-fpm --apply' domaini per-domain unit'e
        # taşıdığında config '/etc/srvctl/fpm/<sname>.conf'a geçer ve eski yol
        # SİLİNİR → sertleştirilmiş domain "chroot aktif DEĞİL" diye FAIL
        # alıyordu (sertleştirmenin cezalandırılması). İki yolu da kabul et.
        _check "${domain}: chroot aktif" \
            bash -c "grep -q chroot '/etc/srvctl/fpm/${sname}.conf' 2>/dev/null || grep -q chroot '/etc/php/${php_ver}/fpm/pool.d/${sname}.conf' 2>/dev/null"

        # FPM izolasyon durumu (koordinatör bulgusu — bkz. _check_fpm_isolation
        # tanım yorumu): PAYLAŞILAN havuza düşmüş bir domain AppArmor/seccomp/
        # NoNewPrivileges'in TAMAMINI sessizce kaybeder; bu HİÇBİR kontrol
        # tarafından yakalanmıyordu.
        _check_fpm_isolation _pass _fail _warn_result "$domain" "$sname"

        # ─── AppArmor/seccomp/cgroups — GERÇEK enforcement (T7b, denetim
        #     DALGA 5 — K1/Y4 kapanışı) ───
        # ÖNCEDEN: yalnız 'aa-status | grep' (VARLIK testi — bu profil
        # sistemde BİR YERDE yüklü mü — attach'a da, enforce/complain moduna
        # da bakmıyordu) ve _warn_check (yani WARN, FAIL DEĞİL). README bunun
        # AKSİNİ iddia ediyordu ("audit artık AppArmor/seccomp/cgroups'u
        # gerçek enforce durumuyla kontrol eder... enforce değilse FAIL
        # verir"). Aşağıdaki blok, dosya başında yazılmış+testli (bkz.
        # tests/test_audit_parsers.sh) ama eskiden HİÇ ÇAĞRILMAYAN saf
        # parser'ları (_audit_aa_attr_enforced/_audit_seccomp_filtered/
        # _audit_in_slice) domain'in GERÇEK FPM master PID'i üzerinden
        # bağlar — fail-closed: PID bulunamazsa (servis çalışmıyor) FAIL
        # DEĞİL, açıkça "doğrulanamadı" (WARN); PID bulunup attach YOKSA
        # FAIL (WARN DEĞİL).
        #
        # ⚠ DAVRANIŞ DEĞİŞİKLİĞİ: varsayılan 'domain add' yolu per-domain FPM
        # unit KULLANMAZ (paylaşılan php<ver>-fpm master'ı) — bu durumda
        # AppArmor/seccomp/cgroups slice bu domain'in sürecine HİÇ ATTACH
        # DEĞİLDİR ve aşağıdaki üç kontrol FAIL verir. Bu DOĞRU bir sonuçtur
        # (README'nin iddiasıyla tutarlı) ama SERT — mevcut kurulumların
        # skorunu düşürür. Operatöre açıkça 'srvctl security harden-fpm
        # <domain> --apply' önerilir (aşağıdaki FAIL mesajları bunu söyler).
        local _fpm_pid=""
        _fpm_pid=$(_audit_domain_fpm_pid "$sname" "$php_ver") || _fpm_pid=""

        if [[ -z "$_fpm_pid" ]]; then
            _warn_result "${domain}: FPM süreci bulunamadı — AppArmor/seccomp/cgroups enforcement DOĞRULANAMADI"
        else
            local _aa_attr _seccomp_status _cgroup_info
            _aa_attr="$(cat "/proc/${_fpm_pid}/attr/current" 2>/dev/null || true)"
            if [[ -n "$_aa_attr" ]] && _audit_aa_attr_enforced "$_aa_attr" "srvctl-${sname}"; then
                _pass "${domain}: AppArmor enforce (PID ${_fpm_pid} doğrulandı)"
            else
                _fail "${domain}: AppArmor enforce DEĞİL (PID ${_fpm_pid}: '${_aa_attr:-okunamadı}') — 'srvctl security harden-fpm ${domain} --apply' çalıştırın"
            fi

            _seccomp_status="$(cat "/proc/${_fpm_pid}/status" 2>/dev/null || true)"
            if [[ -n "$_seccomp_status" ]] && _audit_seccomp_filtered "$_seccomp_status"; then
                _pass "${domain}: seccomp filter aktif (PID ${_fpm_pid} doğrulandı)"
            else
                _fail "${domain}: seccomp filter DEĞİL/doğrulanamadı (PID ${_fpm_pid})"
            fi

            _cgroup_info="$(cat "/proc/${_fpm_pid}/cgroup" 2>/dev/null || true)"
            if [[ -n "$_cgroup_info" ]] && _audit_in_slice "$_cgroup_info" "srvctl-${sname}.slice"; then
                _pass "${domain}: cgroups slice attach (PID ${_fpm_pid} doğrulandı)"
            else
                _fail "${domain}: cgroups slice attach DEĞİL (PID ${_fpm_pid})"
            fi
        fi

        # Worker/scheduler '-cli' profili enforcement (BULGU kapanışı — bkz.
        # yukarıdaki (_security_run_check yanındaki) _check_worker_aa/
        # _check_scheduler_aa tanım yorumu). Her ikisi de kendi domain/
        # kuyruk-tanımsızlık durumunu SESSİZCE atlar; burada FAIL/WARN sayımı
        # yalnız "tanımlı+aktif ama enforce değil" durumunda artar.
        _check_worker_aa _pass _fail _warn_result "$domain" "$sname"
        _check_scheduler_aa _pass _fail _warn_result "$domain" "$sname"

        # Dosya izinleri
        local perm
        # HOST BULGUSU: audit 750 bekliyordu ama T1 dosya-sahiplik modeli base
        # dizin için 751 tanımlıyor (_domain_fs_plan: "." → root|751;
        # _domain_apply_fs_ownership: chmod 751 "$base"). 751'in 'o+x' biti
        # KASITLIDIR — www-data'nın (domain grubunda DEĞİL) alt yollara
        # traverse edebilmesi için gerekir; 'o+r' verilmediğinden dizin
        # LİSTELENEMEZ. Yani audit kendi tasarımıyla çelişip her hardened
        # domaine sahte FAIL veriyordu. Doğru beklenen değer 751.
        perm=$(stat -c %a "${dir}" 2>/dev/null)
        if [[ "$perm" == "751" ]]; then
            _pass "${domain}: dosya izinleri 751 (T1 modeli)"
        else
            _fail "${domain}: dosya izinleri ${perm} (751 olmalı — 'srvctl security harden-fs ${domain} --apply')"
        fi

        # Socket izinleri
        _check "${domain}: FPM socket mevcut" \
            test -S "/run/php/php${php_ver}-fpm-${sname}.sock"

        domain_count=$((domain_count + 1))
    done

    if [[ $domain_count -eq 0 ]]; then
        info "Henüz domain eklenmemiş"
    fi

    # ═══ Fail2Ban ═══
    echo ""
    echo -e "  ${CYAN}── Fail2Ban ──${NC}"
    local total_banned=0
    while IFS= read -r jail; do
        jail=$(echo "$jail" | xargs)
        [[ -z "$jail" ]] && continue
        local banned
        banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        total_banned=$((total_banned + ${banned:-0}))
        info "${jail}: ${banned:-0} banned IP"
    done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g')

    # ═══════════════════════════════════════════════════════════════
    #  security.sh — EK KONTROL BLOĞU (Faz 1/7 yeni katmanlar)
    #
    #  Aşağıdaki bloğu lib/security.sh içindeki _security_audit
    #  fonksiyonunda "═══ SONUÇ ═══" satırının HEMEN ÜSTÜNE ekleyin.
    #  (_check/_pass/_fail yardımcıları o fonksiyon kapsamında tanımlı.)
    # ═══════════════════════════════════════════════════════════════

    # ═══ GELİŞMİŞ KATMANLAR (Faz 1) ═══
    echo ""
    echo -e "  ${CYAN}── Gelişmiş Güvenlik ──${NC}"

    _warn_check "ModSecurity WAF aktif" \
        grep -q 'modsecurity on' /etc/nginx/nginx.conf
    _warn_check "OWASP CRS yüklü" \
        test -d /etc/nginx/owasp-crs/rules
    _warn_check "AIDE veritabanı mevcut" \
        bash -c "test -f /var/lib/aide/aide.db.gz -o -f /var/lib/aide/aide.db"
    _warn_check "ClamAV daemon çalışıyor" \
        systemctl is-active clamav-daemon
    _warn_check "cgroups v2 aktif" \
        test -f /sys/fs/cgroup/cgroup.controllers
    _warn_check "srvctl parent slice tanımlı" \
        test -f /etc/systemd/system/srvctl.slice
    _warn_check "PHP-FPM seccomp hardening (SystemCallFilter)" \
        test -f "/etc/systemd/system/php${DEFAULT_PHP_VERSION}-fpm.service.d/10-srvctl-seccomp.conf"
    _warn_check "GeoIP veritabanı mevcut" \
        test -f /usr/share/GeoIP/GeoIP.dat


    # ═══ SONUÇ ═══
    echo ""
    divider
    local total=$((pass + fail + warn_count))
    local score=0
    [[ $total -gt 0 ]] && score=$(( (pass * 100) / total ))

    printf "  ${GREEN}PASS: %-5s${NC}  ${RED}FAIL: %-5s${NC}  ${YELLOW}WARN: %-5s${NC}\n" "$pass" "$fail" "$warn_count"

    local score_color="$RED"
    if [[ $score -ge 90 ]]; then
        score_color="$GREEN"
    elif [[ $score -ge 70 ]]; then
        score_color="$YELLOW"
    fi

    echo ""
    echo -e "  Güvenlik Skoru: ${BOLD}${score_color}${score}/100${NC}"

    if [[ $fail -gt 0 ]]; then
        echo ""
        warn "FAIL olan kontrolleri düzeltin ve tekrar çalıştırın."
    fi

    if [[ $total_banned -gt 0 ]]; then
        echo ""
        info "Toplam ${total_banned} IP banned (Fail2Ban)"
    fi

    echo ""

    log_action "SECURITY AUDIT: pass=${pass} fail=${fail} warn=${warn_count} score=${score}/100"
}

# ─── Dosya-sahiplik sertleştirme (T1) ───
# Kullanım: harden-fs <domain>|--all [--apply|--revert]  (varsayılan: dry-run)
_security_harden_fs() {
    _security_load_domain_lib \
        || error "domain.sh yüklenemedi — harden-fs kullanılamaz (${SRVCTL_ROOT}/lib/domain.sh)"
    local domain="" mode="dry" all=false arg
    for arg in "$@"; do
        case "$arg" in
            --apply)  mode="apply" ;;
            --revert) mode="revert" ;;
            --all)    all=true ;;
            -*)       error "Bilinmeyen seçenek: ${arg}" ;;
            *)        domain="$arg" ;;
        esac
    done

    # GÜVENLİK DENETİMİ EKİ (KUSUR 1 İLE AYNI SINIF — bkz. _security_harden_fpm
    # ve lib/domain.sh:_domain_repair '--all' bloğundaki BİREBİR AYNI gerekçe):
    # '_harden_fs_dry/apply' -> '_domain_read_framework' -> 'read_meta' zinciri,
    # hardened+tamper'lı bir '.srvctl-meta'da error() (=exit) çağırabilir.
    # Çıplak çağrıda bu TÜM '--all' toplu işlemini sessizce yarıda keser — bir
    # sonraki domain hiç işlenmez, özet asla basılmaz. Alt-kabuk ('( ... )')
    # 'exit'i kabuğa hapseder; dönüş kodu normal şekilde '$?' ile gelir, döngü
    # KESİLMEDEN devam eder. Tek-domain çağrısı BİLEREK subshell'siz bırakıldı
    # (orada koşulsuz exit zaten doğru/beklenen davranıştır).
    if $all; then
        # 'mapfile' YERİNE 'while read < <(...)' (lib/domain.sh:_domain_repair
        # '--all' bloğuyla AYNI idiom, bkz. CLAUDE.md "Bash tuzakları" —
        # 'cmd | while read' subshell'de çalışır ama '< <(cmd)' çalışmaz):
        # 'mapfile' bash 4+ builtin'idir; Ubuntu 22.04/24.04'te sorun yok ama
        # bu tekilleştirme ayrıca kodu macOS dev makinesinin eski bash 3.2'sinde
        # de test edilebilir kılar (repoda BAŞKA hiçbir yerde 'mapfile'a
        # gerek yoktu, bkz. domain.sh).
        local -a failed=()
        local total=0 d
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            total=$((total + 1))
            case "$mode" in
                dry)    ( _harden_fs_dry "$d" )    || failed+=("$d") ;;
                apply)  ( _harden_fs_apply "$d" )  || failed+=("$d") ;;
                revert) ( _harden_fs_revert "$d" ) || failed+=("$d") ;;
            esac
        done < <(list_all_domains)
        if [[ "${#failed[@]}" -gt 0 ]]; then
            warn "harden-fs TAMAMLANAMADI: ${#failed[@]}/${total} domain başarısız: ${failed[*]}"
            warn "Her biri için ayrıntılı hata yukarıda — tek tek 'srvctl security harden-fs <domain> --apply' ile tekrar deneyin."
            return 1
        fi
        return 0
    fi

    [[ -z "$domain" ]] && error "Kullanım: srvctl security harden-fs <domain>|--all [--apply|--revert]"
    case "$mode" in
        dry)    _harden_fs_dry "$domain" ;;
        apply)  _harden_fs_apply "$domain" ;;
        revert) _harden_fs_revert "$domain" ;;
    esac
}

# Dry-run: hedef modeli + mevcut durumu yaz, hiçbir şeye dokunma.
# _domain_fs_plan'a framework (_domain_read_framework, domain.sh) 3. argüman
# olarak geçirilir — aksi halde Laravel shared/storage, Symfony shared/var ve
# shared/.env satırları plana hiç girmez, yani bu domainler için harden-fs
# denetimi framework-özel yolları GÖRMEZ (sessizce eksik denetim).
_harden_fs_dry() {
    local domain="$1" base="${WEB_ROOT}/${1}" web_user
    web_user="web_$(safe_name "$domain")"
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    local framework; framework=$(_domain_read_framework "$domain")
    echo "  ── ${domain} (dry-run; uygulamak için --apply) ──"
    local path owner mode
    while IFS='|' read -r path owner mode; do
        [[ -e "$path" ]] || continue
        printf '    %s -> %s:%s %s  (mevcut: %s %s)\n' \
            "$path" "$owner" "$owner" "$mode" "$(_stat_owner "$path")" "$(_stat_mode "$path")"
    done < <(_domain_fs_plan "$base" "$web_user" "$framework")
}

# Apply: hedef sahiplik modelini uygula. Önce mevcut durumu state dizinine
# kaydeder (revert güvenlik ağı), sonra 'hardened' marker'ını yazar — marker
# _require_owned_or_warn'ı warn'dan fail'e yükseltir, bu yüzden EN SON yazılır.
_harden_fs_apply() {
    local domain="$1" base="${WEB_ROOT}/${1}" web_user
    web_user="web_$(safe_name "$domain")"
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }

    local state_dir="${SRVCTL_STATE_DIR}/${domain}"
    secure_dir "$state_dir" 700
    local rec="${state_dir}/fs-before"

    # Mevcut kaydın üzerine YAZMA: ikinci kez --apply çalıştırmak ilk (gerçek)
    # önceki durumu silip hardened durumu "önceki" diye kaydederdi → revert no-op.
    if [[ -f "$rec" ]]; then
        info "Mevcut geri-alma kaydı korunuyor: ${rec}"
    else
        _fs_record_before "$base" "$rec"
        chmod 600 "$rec" 2>/dev/null || true
    fi

    # 1. Taban model (T1/RC1): base root:root 751 + chroot sistem dizinleri +
    #    kontrol dosyaları + genel leaf'ler (public_html/private/logs/tmp/
    #    sessions/private/writable).
    _domain_apply_fs_ownership "$base" "$web_user"

    # 2. Framework'e özgü shared/ satırları (Laravel storage/, Symfony var/,
    #    CI4 writable/, .env). _domain_apply_fs_ownership bunları HARDCODED
    #    adım listesinde İÇERMEZ (o fonksiyon yalnız T1 taban modelini
    #    uygular) — _domain_fs_plan'daki TAM hedef model (framework-farkında)
    #    burada satır satır uygulanır, aksi halde bu yollar dry-run'da
    #    GÖRÜNÜR ama --apply hiçbir zaman KURMAZ (denetlenip uygulanmama
    #    boşluğu). Var olmayan yol sessizce atlanır.
    local framework; framework=$(_domain_read_framework "$domain")
    local path owner mode
    while IFS='|' read -r path owner mode; do
        [[ -e "$path" ]] || continue
        chown "${owner}:${owner}" "$path" 2>/dev/null || true
        chmod "$mode" "$path" 2>/dev/null || true
    done < <(_domain_fs_plan "$base" "$web_user" "$framework")

    # 3. '.srvctl-meta' İÇERİĞİNİ beyaz liste ile yeniden yaz (O1 TAM kapanışı).
    #    Yalnız sahiplik/izin (chown/chmod, yukarıdaki adım 1) DEĞİL, İÇERİK de
    #    sertleştirilir — aksi halde hardened-öncesi bir tamper (ör. baştaki
    #    boşluklu/'#' önekli satır) dosyada KALICI olarak dururdu (bkz.
    #    _meta_rewrite_whitelist başlık yorumu). ': >' ile YERİNDE (in-place)
    #    truncate edildiğinden dosyanın sahiplik/izni (yukarıda zaten root:root
    #    644 yapıldı) KORUNUR — silinip yeniden oluşturulmaz.
    local meta_file="${base}/.srvctl-meta"
    if [[ -f "$meta_file" ]]; then
        local _meta_stats _meta_kept _meta_dropped
        _meta_stats=$(_meta_rewrite_whitelist "$meta_file")
        read -r _meta_kept _meta_dropped <<< "$_meta_stats"
        if [[ "${_meta_dropped:-0}" != "0" ]]; then
            warn ".srvctl-meta temizlendi: ${_meta_dropped} tanınmayan/geçersiz satır ATILDI, ${_meta_kept} satır korundu (${domain}) — tamper şüphesi"
        else
            info ".srvctl-meta doğrulandı: ${_meta_kept} satır korundu, atılan yok (${domain})"
        fi
    fi

    secure_file "${state_dir}/hardened" 600

    success "harden-fs uygulandı: ${domain} (framework: ${framework})"
    log_action "harden-fs apply: ${domain} (framework=${framework}, meta_kept=${_meta_kept:-0}, meta_dropped=${_meta_dropped:-0})"
}

# Revert: kaydedilmiş sahiplik/izinleri geri yükle ve marker'ı kaldır.
_harden_fs_revert() {
    local domain="$1"
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }

    local state_dir="${SRVCTL_STATE_DIR}/${domain}"
    local rec="${state_dir}/fs-before"
    [[ -f "$rec" ]] || { warn "Geri alma kaydı yok: ${rec} — revert atlandı"; return 0; }

    # Marker'ı ÖNCE kaldır: _fs_revert yarıda kalırsa domain 'hardened' işaretli
    # kalmamalı, aksi halde _require_owned_or_warn her komutu tamper sayar.
    rm -f "${state_dir}/hardened"
    _fs_revert "$rec"
    rm -f "$rec"

    success "harden-fs geri alındı: ${domain}"
    log_action "harden-fs revert: ${domain}"
}

# ─── Shared-pool → per-domain FPM unit migrasyonu (T7a) ───
# Kullanım: harden-fpm <domain>|--all [--apply]   (varsayılan: dry-run)
_security_harden_fpm() {
    _security_load_domain_lib \
        || error "domain.sh yüklenemedi — harden-fpm kullanılamaz (${SRVCTL_ROOT}/lib/domain.sh)"
    local domain="" mode="dry" all=false arg
    for arg in "$@"; do
        case "$arg" in
            --apply) mode="apply" ;;
            --all)   all=true ;;
            -*)      error "Bilinmeyen seçenek: ${arg}" ;;
            *)       domain="$arg" ;;
        esac
    done
    # NOT: 'cond && apply || dry' YAZMA — bu yapı `set -e`'yi tüm çağrı zinciri
    # boyunca devre dışı bırakır (apply içindeki her hata sessizce yutulur).

    # GÜVENLİK DENETİMİ EKİ (KUSUR 1 — designwestgate.art, bkz.
    # lib/domain.sh:_domain_repair '--all' bloğundaki BİREBİR AYNI gerekçe):
    # '_harden_fpm_apply' -> '_derive_php' -> 'read_credentials' zinciri,
    # hardened+'.credentials'sız bir domainde error() (=exit) çağırabilir
    # (KUSUR 3 kurtarması '_domain_ensure_credentials' eklendikten SONRA bile
    # — ör. domain.sh yüklenemezse, ya da GERÇEK bir tamper). Çıplak çağrıda
    # bu TÜM '--all' toplu işlemini sessizce yarıda keser: bir sonraki domain
    # hiç işlenmez, "TAMAMLANAMADI" özeti asla basılmaz (tam olarak
    # 'set -euo pipefail' altında korunmasız '$(...)' başarısızlığının
    # davranışı). Alt-kabuk ('( ... )') 'exit'i kabuğa hapseder; dönüş kodu
    # normal şekilde '$?' ile gelir, döngü KESİLMEDEN devam eder. Tek-domain
    # çağrısı (aşağıda) BİLEREK subshell'siz bırakıldı — orada koşulsuz exit
    # zaten doğru/beklenen davranıştır (bkz. lib/domain.sh:_domain_repair'in
    # tekil yolu — AYNI ayrım).
    if $all; then
        # 'mapfile' YERİNE 'while read < <(...)' — bkz. _security_harden_fs'teki
        # BİREBİR AYNI gerekçe (lib/domain.sh:_domain_repair '--all' idiomu;
        # 'mapfile' bash 4+ gerektirir, bu tekilleştirme macOS dev makinesinin
        # eski bash 3.2'sinde de test edilebilirliği korur).
        local -a failed=()
        local total=0 d
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            total=$((total + 1))
            if [[ "$mode" == "apply" ]]; then
                ( _harden_fpm_apply "$d" ) || failed+=("$d")
            else
                ( _harden_fpm_dry "$d" ) || failed+=("$d")
            fi
        done < <(list_all_domains)
        if [[ "${#failed[@]}" -gt 0 ]]; then
            warn "harden-fpm TAMAMLANAMADI: ${#failed[@]}/${total} domain başarısız: ${failed[*]}"
            warn "Her biri için ayrıntılı hata yukarıda — tek tek 'srvctl security harden-fpm <domain> --apply' ile tekrar deneyin."
            return 1
        fi
        return 0
    fi

    [[ -z "$domain" ]] && error "Kullanım: srvctl security harden-fpm <domain>|--all [--apply]"
    if [[ "$mode" == "apply" ]]; then
        _harden_fpm_apply "$domain"
    else
        _harden_fpm_dry "$domain"
    fi
}

# Dry-run: ne oluşturulacağını yaz, dokunma.
_harden_fpm_dry() {
    local domain="$1" sname; sname=$(safe_name "$domain")
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    echo "  ── ${domain} (dry-run; uygulamak için --apply) ──"
    echo "    oluştur: /etc/srvctl/fpm/${sname}.conf"
    echo "    oluştur: /etc/systemd/system/srvctl-fpm-${sname}.service (Slice + AppArmorProfile)"
    echo "    kaldır:  /etc/php/<ver>/fpm/pool.d/${sname}.conf (eski shared pool)"
    echo "    systemctl enable --now srvctl-fpm-${sname}"
}

# Apply: per-domain FPM unit oluştur, eski shared pool'u kaldır. [SADECE HOST]
_harden_fpm_apply() {
    local domain="$1" sname php_ver
    sname=$(safe_name "$domain")
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    # KUSUR 3 (designwestgate.art): '.credentials' hiç yoksa aşağıdaki
    # '_derive_php' -> 'read_credentials' (core.sh) hardened bir domainde
    # fail-closed 'tamper' reddi verip error() ile ÇIKAR — bu tam olarak
    # audit'in FAIL dediği domain'i sertleştirecek komutun KENDİSİNİ bloke
    # ediyordu (bkz. lib/domain.sh:_domain_ensure_credentials başlık yorumu).
    # Yalnız dosya GERÇEKTEN eksikse üretir, var olana DOKUNMAZ. Cross-module
    # çağrı: bu fonksiyonun tek çağıranı '_security_harden_fpm', başında
    # '_security_load_domain_lib' ile lib/domain.sh'ı ZATEN yüklemiş olur
    # (aşağıdaki '_domain_render_fpm_unit' çağrısıyla AYNI ön-koşul).
    _domain_ensure_credentials "$domain"
    php_ver=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    _domain_render_fpm_unit "$domain" "$php_ver"

    # ─── SOCKET DEVRİ (HOST BULGUSU, Ubuntu 24.04 gerçek VM) ───
    # Eski sıra "önce yeni unit'i başlat, sonra eski pool'u sil" idi ve bu
    # YAPISAL OLARAK İMKÂNSIZDI: paylaşılan php<ver>-fpm master'ı domainin
    # havuzunu hâlâ ayakta tuttuğu için aynı unix socket'i dinliyordu:
    #   ERROR: Another FPM instance seems to already listen on
    #          /run/php/php8.3-fpm-<sname>.sock
    #   status=78/CONFIG
    # Yani harden-fpm HİÇBİR ZAMAN başarılı olamıyordu; fail-closed koruma
    # her seferinde devreye girip "shared pool korundu" diyordu (site kurtuluyordu
    # ama migration hiç gerçekleşmiyordu).
    #
    # Doğru sıra: pool'u ÖNCE kaldır + reload et (socket serbest kalsın),
    # SONRA yeni unit'i başlat. Başarısızsa pool'u GERİ KOY ve reload et —
    # fail-closed davranış korunur, domain 502'ye düşmez.
    local pool_file="/etc/php/${php_ver}/fpm/pool.d/${sname}.conf"
    local pool_bak=""
    if [[ -f "$pool_file" ]]; then
        pool_bak="$(mktemp "/etc/srvctl/fpm/${sname}.pool.bak.XXXXXX")" \
            || { warn "Geçici yedek oluşturulamadı — harden-fpm iptal: ${domain}"; return 1; }
        cat "$pool_file" > "$pool_bak"
        rm -f "$pool_file"
        systemctl reload "php${php_ver}-fpm" 2>/dev/null \
            || systemctl restart "php${php_ver}-fpm" 2>/dev/null || true

        # HOST BULGUSU: reload master'ın havuzu kapatmasını BEKLEMEZ ve
        # php-fpm kapanan havuzun unix socket DOSYASINI silmez. Yeni unit o
        # ölü dosyayı görüp "Another FPM instance seems to already listen"
        # diyerek status=78 ile ölüyordu. Önce havuzun gerçekten kapanmasını
        # bekle, sonra ARTIK DİNLENMEYEN socket dosyasını temizle.
        local sock="/run/php/php${php_ver}-fpm-${sname}.sock" i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [[ -S "$sock" ]] || break
            # Hâlâ dinleyen var mı? (ss yoksa bu adımı atla — sadece bekle)
            if command -v ss >/dev/null 2>&1 && ! ss -lxH "src = ${sock}" 2>/dev/null | grep -q .; then
                break
            fi
            sleep 1
        done
        if [[ -S "$sock" ]] && command -v ss >/dev/null 2>&1 \
           && ! ss -lxH "src = ${sock}" 2>/dev/null | grep -q .; then
            rm -f -- "$sock"   # ölü socket dosyası: dinleyen yok
        fi
    fi

    if ! _domain_activate_fpm_unit "$domain"; then
        # Geri al: pool'u restore et, paylaşılan master'ı tekrar yükle.
        if [[ -n "$pool_bak" && -f "$pool_bak" ]]; then
            cat "$pool_bak" > "$pool_file"
            rm -f "$pool_bak"
            systemctl reload "php${php_ver}-fpm" 2>/dev/null \
                || systemctl restart "php${php_ver}-fpm" 2>/dev/null || true
        fi
        warn "Per-domain FPM unit başlatılamadı — eski shared pool GERİ YÜKLENDİ: ${domain}"
        log_action "harden-fpm apply BAŞARISIZ (rollback: shared pool geri yüklendi): ${domain}"
        return 1
    fi

    rm -f "$pool_bak" 2>/dev/null || true
    # ─── Havuzsuz kalan paylaşılan master'ı düzgünce durdur ───
    # HOST BULGUSU (her iki LTS): bu domainin havuzu pool.d/'den kaldırıldıktan
    # sonra orada AKTİF havuz kalmayabilir (www.conf init tarafından zaten
    # 'www.conf.disabled' yapılıyor). php-fpm HAVUZSUZ BAŞLAYAMAZ: servis
    # 'failed' olur, systemd Restart=on-failure ile döngüye girer
    # ("Start request repeated too quickly", restart counter 5) ve journal
    # sürekli hata basar. Bu bir arıza değil, izolasyonun DOĞAL SONUCUDUR —
    # o yüzden servisi bırakıp çırpınmasına izin vermek yerine açıkça
    # durdurup devre dışı bırakıyoruz.
    # Geri dönüş: 'domain add' paylaşılan havuza yeni bir pool yazdığında
    # 'systemctl reload || systemctl restart' zincirini kullanır; restart
    # durmuş/disable servisi yeniden ayağa kaldırır (lib/domain.sh).
    local pool_dir="/etc/php/${php_ver}/fpm/pool.d"
    if ! compgen -G "${pool_dir}/*.conf" > /dev/null 2>&1; then
        systemctl stop    "php${php_ver}-fpm" 2>/dev/null || true
        systemctl disable "php${php_ver}-fpm" 2>/dev/null || true
        systemctl reset-failed "php${php_ver}-fpm" 2>/dev/null || true
        info "Paylaşılan php${php_ver}-fpm havuzsuz kaldı — durduruldu (tüm domainler izole unit'lerde)"
        log_action "harden-fpm: paylaşılan php${php_ver}-fpm durduruldu (havuz kalmadı)"
    fi

    success "harden-fpm uygulandı: ${domain}"
    log_action "harden-fpm apply: ${domain}"
}
