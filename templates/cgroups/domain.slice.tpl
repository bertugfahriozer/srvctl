# TOKENS: DOMAIN CPU_QUOTA MEMORY_MAX MEMORY_HIGH MEMORY_SWAP_MAX IO_WEIGHT
#         IO_READ_MAX IO_WRITE_MAX TASKS_MAX
# Besleyen: lib/domain.sh — _apply_cgroups_slice (satır ~1815, domain add
# yolu) ve resource-güncelleme fonksiyonu (satır ~2148, 'domain resources'
# komutu). IO_READ_MAX/IO_WRITE_MAX bilinçli olarak BOŞ string ile beslenir
# (device path olmadan IOReadBandwidthMax= geçersiz olur) — render SONRASI
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
# NOT (Faz 1 bulgusu): pool.conf.tpl pm.max_children=16 x memory_limit=256M
# ile teorik tepe talep 4096M'dir; MemoryMax bunun ALTINDAYSA swap grace'i
# olmadan (MemorySwapMax=0) iki eşzamanlı ağır istek OOM-kill'e yol açar.
# MEMORY_MAX/MEMORY_HIGH değerlerini bu çarpımla TUTARLI seçin (bkz. rapor:
# "cgroups slice limitleri" önerisi). MemorySwapMax artık TOKEN'laştırıldı —
# 0 yerine küçük bir grace payı (ör. 256M) önerilir; render_template bu
# değeri BOŞ bırakmaz, çağıran KEY=value ile MEMORY_SWAP_MAX sağlamalıdır
# (aksi halde render edilen dosyada literal '{{MEMORY_SWAP_MAX}}' kalır ve
# systemd unit'i bozuk değerle reddedebilir).
MemoryMax={{MEMORY_MAX}}
MemoryHigh={{MEMORY_HIGH}}
MemorySwapMax={{MEMORY_SWAP_MAX}}

# ─── I/O Limitleri ───
IOWeight={{IO_WEIGHT}}
IOReadBandwidthMax={{IO_READ_MAX}}
IOWriteBandwidthMax={{IO_WRITE_MAX}}

# ─── Process Limitleri ───
TasksMax={{TASKS_MAX}}
