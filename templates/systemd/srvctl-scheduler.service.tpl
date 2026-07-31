# TOKENS: DOMAIN SAFE_NAME WEB_USER WORKING_DIR SCHEDULER_CMD DOMAIN_ROOT
# Besleyen: lib/domain.sh — _domain_render_scheduler_unit (satır ~2506).
# DOMAIN_ROOT = '${WEB_ROOT}/${domain}' render_template çağrısında besleniyor
# (bkz. ReadWritePaths= yorumu — worker.service.tpl ile AYNI gerekçe).
[Unit]
Description=srvctl Scheduler ({{DOMAIN}})
Documentation=man:systemd.service(5)
After=network.target srvctl-fpm-{{SAFE_NAME}}.service

[Service]
Type=oneshot
User={{WEB_USER}}
Group={{WEB_USER}}

# NOT: worker unit'teki WorkingDirectory/deploy-restart notuyla AYNI
# kısıt geçerlidir — bkz. srvctl-worker.service.tpl. Scheduler'ın kendisi
# 'oneshot' olduğundan (her tetiklemede yeniden fork/exec edilir) aslında
# HER ÇALIŞMADA güncel symlink'i baştan çözer; bu yüzden restart ihtiyacı
# worker'daki kadar kritik DEĞİLDİR (bir sonraki dakikalık tetiklemede
# otomatik güncel release'i görür). Yine de release KÖKÜ'ne stabil
# referans için worker unit'teki ile aynı WorkingDirectory önerisi geçerli.
WorkingDirectory={{WORKING_DIR}}

# ExecStart değeri framework'e göre değişir (rapora bkz):
#   Laravel: php artisan schedule:run
#   Symfony: (yerleşik scheduler yok — messenger:consume worker'a devredilir
#            ya da uygulamaya özgü bir komuta)
#   CI4:     php spark tasks:run
ExecStart={{SCHEDULER_CMD}}

Slice=srvctl-{{SAFE_NAME}}.slice
# NOT: worker unit'teki ile AYNI gerekçeyle FPM'in profili DEĞİL, ayrı ve
# daha dar bir CLI profili kullanılır (bkz. templates/apparmor/profile-cli.tpl).
AppArmorProfile=srvctl-{{SAFE_NAME}}-cli

# 'schedule:run' tek çalışmada tüm vadesi gelen görevleri tetikleyip
# çıkar; uzun süren bir görev sonraki dakikalık tetiklemeyle ÇAKIŞMASIN
# diye üst sınır konur (framework'ün kendi arka plana atma mekanizması
# --queue kullanılmıyorsa devreye girer; DALGA 2 bu değeri gözden geçirmeli).
TimeoutStartSec=300

# ─── Sertleştirme (rapor: dalga4/O10) — worker.service.tpl ile AYNI blok
# ve AYNI gerekçe; bkz. o dosyadaki uzun yorum (DOMAIN_ROOT token'ı,
# PrivateTmp caveat'ı). DOMAIN_ROOT lib/domain.sh:_domain_render_scheduler_unit
# tarafından 'DOMAIN_ROOT=${WEB_ROOT}/${domain}' olarak beslenir
# (render_template çağrısı, worker unit'teki ile BİREBİR aynı desen).
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=-{{DOMAIN_ROOT}}
PrivateTmp=yes
RestrictSUIDSGID=true
SystemCallFilter=~kexec_load kexec_file_load reboot swapon swapoff mount umount2 pivot_root init_module finit_module delete_module create_module query_module unshare setns userfaultfd perf_event_open bpf add_key request_key keyctl ptrace process_vm_readv process_vm_writev kcmp lookup_dcookie io_uring_setup io_uring_enter io_uring_register
SystemCallArchitectures=native
NoNewPrivileges=true
