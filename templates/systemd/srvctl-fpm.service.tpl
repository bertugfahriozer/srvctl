# TOKENS: DOMAIN SAFE_NAME PHP_VERSION
# Besleyen: lib/domain.sh — _domain_render_fpm_unit (satır ~522).
[Unit]
Description=srvctl PHP-FPM ({{DOMAIN}})
After=network.target
# HOST BULGUSU: 'Restart=on-failure' tek başına SINIRSIZ yeniden deneme
# demektir; config hatasıyla (status=78/CONFIG) başlayamayan unit sonsuz
# döngüye girer, journal dolar, 'systemctl enable --now' asılı kalır.
# DİKKAT: bu iki yönerge [Service] DEĞİL [Unit] bölümüne aittir — [Service]
# altında systemd "Unknown key name ... ignoring" deyip SESSİZCE yok sayar
# (24.04/systemd 255'te bizzat gözlemlendi).
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
# HOST BULGUSU (Ubuntu 24.04, gerçek VM): fpm-global.conf.tpl
# 'pid = /run/srvctl/fpm-<sname>.pid' yazıyor ve AppArmor profili bu yola
# izin veriyor, ama '/run/srvctl' dizinini HİÇBİR KOD OLUŞTURMUYORDU —
# /run bir tmpfs'tir, her boot'ta boştur. Sonuç: unit status=78/CONFIG ile
# başlayamıyordu. RuntimeDirectory systemd'ye dizini (root:root 0755)
# açtırır; Preserve=yes ise AYNI dizini paylaşan diğer domain unit'lerinden
# biri durduğunda dizinin silinmesini engeller (aksi halde bir domaini
# durdurmak diğerlerinin pid yolunu yok ederdi).
# RuntimeDirectory v211+, RuntimeDirectoryPreserve v235+ → 249/255'te mevcut.
RuntimeDirectory=srvctl
RuntimeDirectoryPreserve=yes
ExecStart=/usr/sbin/php-fpm{{PHP_VERSION}} --nodaemonize --fpm-config /etc/srvctl/fpm/{{SAFE_NAME}}.conf
ExecReload=/bin/kill -USR2 $MAINPID
Slice=srvctl-{{SAFE_NAME}}.slice
AppArmorProfile=srvctl-{{SAFE_NAME}}
Restart=on-failure
RestartSec=2
# NOT: yeniden-deneme LİMİTİ [Unit] bölümündedir (StartLimitIntervalSec/
# StartLimitBurst) — systemd'de o iki yönerge [Service]'e AİT DEĞİLDİR.

# ─── Sertleştirme (rapor: dalga4/Y4) ───
# ÖNCEDEN: seccomp/NNP/RestrictSUIDSGID/ProtectKernel* sertleştirmesi YALNIZ
# paylaşılan php<ver>-fpm.service.d/10-srvctl-seccomp.conf drop-in'inde
# vardı (bkz. lib/domain.sh _apply_seccomp_hardening). 'security harden-fpm
# --apply' bir domaini BU unit'e (farklı unit adı) taşıdığında o drop-in
# hiç uygulanmıyordu — yani "sertleştirme" komutu fiilen bu domain için
# syscall filtresini/NNP'yi KALDIRIYORDU, ve audit (lib/security.sh) hâlâ
# eski drop-in DOSYASININ varlığına baktığından PASS raporluyordu (yanlış
# yeşil). Aynı deny listesi burada STATİK olarak tekrarlanır (per-domain
# olarak DEĞİŞMEZ, bu yüzden render token'ı değil sabit metin olarak yazıldı).
#
# Liste lib/domain.sh:1707 _apply_seccomp_hardening ile BİREBİR AYNI;
# clone3 KASITLI OLARAK DIŞARIDA — glibc'nin thread oluşturma yolunda
# clone3 kullanan sürümleri/senaryoları kırılabilir (aynı gerekçe).
#
# Yalnız 249 (22.04) VE 255 (24.04)'te ORTAK, uzun süredir var olan
# yönergeler: NoNewPrivileges (systemd v187), SystemCallFilter/
# SystemCallArchitectures (v197/v210), RestrictSUIDSGID (v242),
# ProtectKernelModules/ProtectKernelTunables (v232) — hepsi 249'dan çok
# önce eklendi, iki LTS'te de güvenle kullanılabilir.
#
# KRİTİK HOST DOĞRULAMASI GEREKİYOR: master ROOT olarak başlıyor ve
# capability chown/dac_override/setuid/setgid/sys_chroot/kill ile
# chroot()+setuid() YAPARAK privilege-drop ediyor (bkz. profile.tpl).
# NoNewPrivileges=true teorik olarak yalnız YENİ ayrıcalık KAZANIMINI
# (setuid-root binary exec'i, dosya capability'siyle yetki artışı)
# engeller; halihazırda sahip olunan capability'lerle DOĞRUDAN
# setuid()/setgid()/chroot() syscall çağrılarını etkilememesi GEREKİR
# (bu bir yetki DÜŞÜRME'sidir, KAZANIM değil) — ama bu, gerçek bir
# 'domain add' + FPM worker fork/setuid akışıyla Ubuntu host'ta HENÜZ
# DOĞRULANMADI. Doğrulanmadan production domainlerine uygulamayın (bkz.
# rapor HOST doğrulama bölümü: systemd-analyze verify + gerçek domain add
# + curl ile sayfa yükleme + dmesg DENIED taraması).
#
# DALGA 5 NOTU: bu deny listesi artık İKİ yerde STATİK olarak duruyor
# (burada ve lib/domain.sh _apply_seccomp_hardening) — templates/seccomp/
# php-fpm.json KALDIRILDI (bkz. O15, aşağıda ayrı not). Uzun vadede tek
# kaynağa indirgenmesi (ör. conf/ altında paylaşılan bir veri dosyası +
# iki tüketici bunu render/sed ile işler) önerilir; şimdilik ikisi de
# manuel senkron tutulmalı.
SystemCallFilter=~kexec_load kexec_file_load reboot swapon swapoff mount umount2 pivot_root init_module finit_module delete_module create_module query_module unshare setns userfaultfd perf_event_open bpf add_key request_key keyctl ptrace process_vm_readv process_vm_writev kcmp lookup_dcookie io_uring_setup io_uring_enter io_uring_register
SystemCallArchitectures=native
NoNewPrivileges=true
RestrictSUIDSGID=true
ProtectKernelModules=true
ProtectKernelTunables=true

[Install]
WantedBy=multi-user.target
