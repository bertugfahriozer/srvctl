# TOKENS: DOMAIN SAFE_NAME
# Besleyen: lib/domain.sh — _domain_render_scheduler_unit (satır ~2430).
[Unit]
Description=srvctl Scheduler Timer ({{DOMAIN}}) — dakikada bir tetikler
Documentation=man:systemd.timer(5)

[Timer]
# 'minutely' = '*-*-* *:*:00' (her dakikanın 0. saniyesi) — systemd'nin
# yerleşik takvim kısaltmasıdır, 249 (22.04) ve 255 (24.04)'te de geçerli.
OnCalendar=minutely
AccuracySec=1s
# Host kapalıyken kaçırılan tetiklemeyi bir sonraki açılışta telafi et
# (Laravel schedule:run zaten idempotent/vade-kontrollüdür, zararsız).
Persistent=true
# Dosya adı kuralı (srvctl-scheduler-<sname>.timer/.service) zaten örtük
# eşleşmeyi sağlar; açıkça belirtmek DALGA 2'nin render/isimlendirme
# hatasına karşı ek güvenlik ağıdır.
Unit=srvctl-scheduler-{{SAFE_NAME}}.service

[Install]
WantedBy=timers.target
