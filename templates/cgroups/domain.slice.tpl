# TOKENS: DOMAIN CPU_QUOTA MEMORY_MAX MEMORY_HIGH MEMORY_SWAP_MAX IO_WEIGHT
#         IO_READ_MAX IO_WRITE_MAX TASKS_MAX
# Besleyen: lib/domain.sh — _apply_cgroups_slice (satır ~1885, domain add
# yolu) ve resource-güncelleme fonksiyonu (satır ~2199, 'domain resources'
# komutu). İkisi de bugün SABİT '_domain_cgroups_defaults()' çıktısını
# (4096M/4608M/512M/200) kullanıyor — DALGA 5 (100-domain e-ticaret ölçeği)
# bunu conf/resource-profiles.conf'tan profil-türetilmiş değerlere taşımayı
# gerektiriyor (bkz. o dosyanın başlık yorumu ve MEMORY_HIGH/MEMORY_MAX/
# MEMORY_SWAP_MAX formülleri altta); '_domain_cgroups_defaults' bir PROFİL
# argümanı almalı (henüz yapılmadı — bkz. ops-infra raporu). IO_READ_MAX/
# IO_WRITE_MAX bilinçli olarak BOŞ string ile beslenir (device path olmadan
# IOReadBandwidthMax= geçersiz olur) — render SONRASI
# 'grep -vE IO(Read|Write)BandwidthMax=\s*$' ile bu boş satırlar temizlenir;
# yani bu iki token her zaman render_template'e verilir ama çıktı dosyasında
# GÖRÜNMEYEBİLİR (bu kasıtlıdır, eksik besleme değildir).
[Unit]
Description=Resource limits for {{DOMAIN}}
Documentation=man:systemd.resource-control(5)

[Slice]
# ─── CPU Limitleri ───
# CPUQuota: 100% = 1 tam core
CPUQuota={{CPU_QUOTA}}
CPUWeight=100

# ─── Bellek Limitleri ───
# TEK KAYNAK artık conf/resource-profiles.conf (pm_mode:max_children:
# memory_limit_mb:tasks_max) — pool.conf.tpl'deki pm.max_children/
# memory_limit ile BURADAKİ MemoryHigh/MemoryMax AYNI profil satırından
# türediği için ARTIK YAPISAL OLARAK senkron kalır (iki ayrı elle-senkron
# sabit yerine): MemoryHigh = max_children × memory_limit_mb; MemoryMax =
# round(MemoryHigh × 1.125) (%12,5 OOM payı); MemorySwapMax =
# max(256, round(MemoryHigh × 0.125)) (0 DEĞİL — MemorySwapMax=0 iken iki
# eşzamanlı ağır istek OOM-kill'e yol açtığı DOĞRULANMIŞTI). Bu üçü
# BAŞKA HİÇBİR YERDE SAKLANMAZ, besleyen fonksiyon her çağrıda yeniden
# hesaplamalı — sabit sayı gömersen drift kaçınılmaz geri gelir.
# render_template bu değerleri BOŞ bırakmaz, çağıran KEY=value ile
# MEMORY_MAX/MEMORY_HIGH/MEMORY_SWAP_MAX sağlamalıdır (aksi halde render
# edilen dosyada literal '{{...}}' kalır ve systemd unit'i reddedebilir —
# bkz. lib/domain.sh:_domain_assert_no_leftover_tokens).
MemoryMax={{MEMORY_MAX}}
MemoryHigh={{MEMORY_HIGH}}
MemorySwapMax={{MEMORY_SWAP_MAX}}

# ─── I/O Limitleri ───
IOWeight={{IO_WEIGHT}}
IOReadBandwidthMax={{IO_READ_MAX}}
IOWriteBandwidthMax={{IO_WRITE_MAX}}

# ─── Process Limitleri ───
TasksMax={{TASKS_MAX}}
