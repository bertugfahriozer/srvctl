# TOKENS: DOMAIN SAFE_NAME WEB_USER WORKING_DIR WORKER_CMD DOMAIN_ROOT
# Besleyen: lib/domain.sh — _domain_render_worker_unit (satır ~2475).
# DOMAIN_ROOT = '${WEB_ROOT}/${domain}' render_template çağrısında besleniyor
# (bkz. ReadWritePaths= yorumu aşağıda — WORKING_DIR tek başına YETERSİZ).
[Unit]
Description=srvctl Worker ({{DOMAIN}} / %i)
Documentation=man:systemd.service(5)
After=network.target srvctl-fpm-{{SAFE_NAME}}.service
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User={{WEB_USER}}
Group={{WEB_USER}}

# NOT: public_html deploy'da symlink olarak DEĞİŞİR (releases/<id> veya
# releases/<id>/public). WorkingDirectory systemd tarafından SÜREÇ
# BAŞLARKEN bir kez chdir() ile çözülür — halihazırda ÇALIŞAN bir worker
# sonraki deploy'da symlink'i TAKİP ETMEZ (cwd inode'a sabitlenir; ayrıca
# PHP zaten autoload sınıflarını ilk açılışta belleğe yükler). Bu yüzden
# HER BAŞARILI DEPLOY SONRASI bu unit'in yeniden başlatılması gerekir —
# bu artık MANUEL bir adım DEĞİL: lib/deploy.sh:_deploy_restart_workers
# başarılı deploy'un (adım 9) ve rollback'in SONUNDA otomatik çağrılır.
# WorkingDirectory değeri: release KÖKÜ olmalı (public/ ALT dizini DEĞİL —
# artisan/bin/console gibi CLI giriş noktaları public/ dışında yaşar).
# Laravel/Symfony'de public_html, releases/<id>/public'e işaret eder;
# release KÖKÜNE stabil bir referans için WEB_ROOT/DOMAIN/current AYRI bir
# (release-root, public/ DEĞİL) symlink olarak zaten mevcut
# (lib/deploy.sh:_deploy_link_current, lib/domain.sh:_domain_working_dir) —
# WORKING_DIR token'ı bunu çözer.
WorkingDirectory={{WORKING_DIR}}

# ExecStart değeri framework'e göre değişir (aşağıdaki rapora bkz). '%i'
# systemd'nin instance adı (srvctl-worker-<sname>@<instance>.service) —
# aynı domain için birden fazla worker'ı (ör. farklı kuyruklar) paralel
# çalıştırmak için ExecStart komutunun içine gömülebilir.
ExecStart={{WORKER_CMD}}

Slice=srvctl-{{SAFE_NAME}}.slice
# NOT: FPM'in profili DEĞİL — worker chroot'suz host yollarında çalışır ve
# FPM'in chroot/setuid capability'lerine, socket/pid dosyalarına ihtiyacı
# YOKTUR. En az yetki için ayrı, daha dar bir profil kullanılır
# (bkz. templates/apparmor/profile-cli.tpl).
AppArmorProfile=srvctl-{{SAFE_NAME}}-cli

# ─── Sertleştirme (rapor: dalga4/O10 — systemd 249/22.04 ile 255/24.04'te
#     ORTAK yönergeler; hepsi 249'dan çok önce eklendi) ───
# ÖNCEDEN yalnız NoNewPrivileges vardı; tek MAC katmanı AppArmor'du (ve o
# da lib/domain.sh'ta warn ile atlanabiliyordu — fail-open, ayrı rapor).
# Aşağıdaki systemd sandbox yönergeleri İKİNCİ, bağımsız bir katman ekler.
#
# {{DOMAIN_ROOT}}: ReadWritePaths= için domain'in TÜM ağacına (WEB_ROOT/
# <domain> — current/releases/shared/logs/tmp/sessions hepsi bunun
# ALTINDA) ihtiyaç var; WORKING_DIR token'ı TEK BAŞINA YETERSİZDİR çünkü
# yalnız 'current' (tek bir release) sembolik linkini kapsar —
# 'shared/writable', 'shared/storage', üst düzey 'logs/', 'tmp/',
# 'sessions/' bunun DIŞINDA, KARDEŞ dizinlerdir (profile-cli.tpl'deki
# eşdeğer AppArmor izinleriyle karşılaştırın). ProtectSystem=strict altında
# yalnız 'current' RW yapılırsa bu kardeş dizinlere yazma READ-ONLY
# namespace'e çarpar. DOMAIN_ROOT lib/domain.sh:_domain_render_worker_unit
# tarafından 'DOMAIN_ROOT=${WEB_ROOT}/${domain}' olarak beslenir
# (render_template çağrısı); render SONRASI leftover-token guard'ı
# (_domain_assert_no_leftover_tokens) bunu ayrıca doğrular.
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=-{{DOMAIN_ROOT}}
# PrivateTmp: worker'ın SİSTEM /tmp'ini (uygulamanın kendi
# WEB_ROOT/<domain>/tmp'i DEĞİL) izole eder. Framework/kütüphane
# 'sys_get_temp_dir()'/php.ini 'upload_tmp_dir' gibi ayarlarla SİSTEM
# /tmp'ine yazıyorsa ve bu dosyaların BAŞKA bir süreçle (ör. FPM) host
# /tmp üzerinden PAYLAŞILMASINA güveniliyorsa etkilenir — ama FPM zaten
# chroot()'lu olduğundan kendi /tmp görünümü (WEB_ROOT/<domain>/tmp)
# ile sınırlı; host /tmp'i hiç görmüyor, dolayısıyla FPM↔worker arası
# PAYLAŞILAN bir host-/tmp bağımlılığı olması BEKLENMEZ. Yine de HOST'ta
# gerçek bir queue:work/schedule:run koşusuyla doğrulanmalı.
PrivateTmp=yes
RestrictSUIDSGID=true
SystemCallFilter=~kexec_load kexec_file_load reboot swapon swapoff mount umount2 pivot_root init_module finit_module delete_module create_module query_module unshare setns userfaultfd perf_event_open bpf add_key request_key keyctl ptrace process_vm_readv process_vm_writev kcmp lookup_dcookie io_uring_setup io_uring_enter io_uring_register
SystemCallArchitectures=native
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
