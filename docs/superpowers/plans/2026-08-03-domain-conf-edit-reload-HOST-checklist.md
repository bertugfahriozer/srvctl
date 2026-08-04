# `domain reload` / `domain ini` / `domain nginx` — Ubuntu HOST Doğrulama Kontrol Listesi

> **Tarih:** 2026-08-03
> **Kapsam:** [2026-08-03-domain-conf-edit-reload.md](2026-08-03-domain-conf-edit-reload.md) planının macOS'ta doğrulanamayan kısımları.
> **Neden ayrı:** Uygulama macOS'ta yapıldı; `systemctl`, `php-fpm -t`, `nginx -t` ve gerçek HTTP davranışı orada mock'lanır. Aşağıdakiler **gerçek bir root Ubuntu host'ta** çalıştırılmalıdır.
> **Her iki LTS:** Tüm maddeler Ubuntu **22.04** ve **24.04**'te ayrı ayrı yürütülmelidir (dual-LTS kuralı).

Kurulum: `sudo bash install.sh` (repo değişiklikleri `/usr/local/srvctl`'e kopyalanmadan hiçbir madde geçerli değildir).

---

## 1. İzole FPM'de reload doğru unit'i hedefliyor

```bash
sudo srvctl domain reload example.com --fpm
systemctl status srvctl-fpm-example_com.service --no-pager | head -5
journalctl -u srvctl-fpm-example_com.service --since "1 min ago" | tail -5
```

**Beklenen:** Çıktıda `FPM reload: example.com (srvctl-fpm-example_com.service)`. Unit `active (running)` kalır, journal'da reload kaydı görünür. **`php8.3-fpm` HİÇ dokunulmamış olmalı.**

## 2. Paylaşılan FPM kurulumunda doğru unit

`conf/srvctl.conf` içinde `DOMAIN_ISOLATED_FPM=false` ile eklenmiş bir domainde:

```bash
sudo srvctl domain reload paylasilan.com --fpm
```

**Beklenen:** Çıktı `php<ver>-fpm` unit adını gösterir, izole unit adını değil.

## 3. `.ini` GERÇEKTEN etkili mi — **en kritik madde**

Bu, spec'teki RC3'ün (pool'daki `php_admin_value` sessizce ezer) gerçekleşmediğinin tek kanıtıdır.

```bash
printf 'memory_limit = 512M\n' | sudo tee /tmp/t.ini >/dev/null
sudo srvctl domain ini example.com --file /tmp/t.ini

# Pool'da TEK satır olmalı:
grep -c '^php_admin_value\[memory_limit\]' /etc/srvctl/fpm/example_com.conf   # → 1
grep '^php_admin_value\[memory_limit\]' /etc/srvctl/fpm/example_com.conf      # → 512M

# Ve GERÇEKTEN yürürlükte mi:
echo '<?php echo ini_get("memory_limit");' | sudo tee /var/www/example.com/public_html/_t.php >/dev/null
curl -s https://example.com/_t.php    # → 512M
sudo rm /var/www/example.com/public_html/_t.php
```

**Beklenen:** `grep -c` **1** döner (şablon satırı düşürülmüş), curl **512M** döner.
**Başarısızsa:** `256M` (veya profil varsayılanı) dönerse enjeksiyon çalışmıyor demektir — filtreleme mantığı (`_domain_render_fpm_unit`) incelenmeli.

## 4. `repair` override'ı korur

```bash
sudo srvctl domain repair example.com
grep '^php_admin_value\[memory_limit\]' /etc/srvctl/fpm/example_com.conf   # → hâlâ 512M
grep -c '^php_admin_value\[memory_limit\]' /etc/srvctl/fpm/example_com.conf # → hâlâ 1
```

**Beklenen:** Değer korunur. Bu, tüm özelliğin varlık sebebidir — eskiden burada kaybolurdu.

## 5. `php-switch` override'ı korur

```bash
sudo srvctl domain php-switch example.com 8.2
grep '^php_admin_value\[memory_limit\]' /etc/srvctl/fpm/example_com.conf   # → 512M
sudo srvctl domain php-switch example.com 8.3   # geri al
```

## 6. `security harden-fpm` override'ı korur

```bash
sudo srvctl security harden-fpm example.com --apply
grep '^php_admin_value\[memory_limit\]' /etc/srvctl/fpm/example_com.conf   # → 512M
```

## 7. nginx override çalışıyor

```bash
printf 'client_max_body_size 100M;\n' | sudo tee /tmp/t.conf >/dev/null
sudo srvctl domain nginx example.com --file /tmp/t.conf
nginx -T 2>/dev/null | grep -A2 "custom.d/example_com"

# 60MB'lık yükleme 413 ALMAMALI:
head -c 60M /dev/urandom > /tmp/big.bin
curl -s -o /dev/null -w '%{http_code}\n' -F "f=@/tmp/big.bin" https://example.com/upload.php
```

**Beklenen:** `nginx -T` çıktısında override görünür; yükleme **413 dönmez**.

## 8. Include ön koşul kapısı (eski domainler)

Bu sürümden önce oluşturulmuş, vhost'unda `custom.d` include satırı olmayan bir domainde:

```bash
sudo srvctl domain nginx eski.com --file /tmp/t.conf ; echo "rc=$?"
```

**Beklenen:** `rc=1`, mesaj "vhost'u custom.d dizinini include ETMİYOR … Önce: srvctl domain repair eski.com".

```bash
sudo srvctl domain repair eski.com
grep custom.d /etc/nginx/sites-available/eski.com.conf   # → include satırı geldi
sudo srvctl domain nginx eski.com --file /tmp/t.conf ; echo "rc=$?"   # → rc=0
```

## 9. `--force` yolu — bildirim ve log

**Bu madde bir üretim bug'ının regresyon testidir:** `send_notification` imzası `(başlık, mesaj, [seviye])`; tek argümanla çağrılırsa `set -u` altında `$2: unbound variable` ile patlar. `_domconf_notify` bunu kapatıyor, ama gerçek notify kanalıyla doğrulanmalı.

```bash
sudo srvctl notify setup      # bir kanal yapılandırılmış olmalı
printf 'open_basedir = /\n' | sudo tee /tmp/bad.ini >/dev/null

sudo srvctl domain ini example.com --file /tmp/bad.ini ; echo "rc=$?"      # → rc=1, UYGULANMADI
sudo srvctl domain ini example.com --file /tmp/bad.ini --force ; echo "rc=$?"  # → rc=0

tail -5 /usr/local/srvctl/logs/*.log | grep "izolasyon override"
```

**Beklenen:** `--force` olmadan reddedilir ve dosya değişmez; `--force` ile uygulanır, log kaydı düşer, bildirim kanalına mesaj **hatasız** gider (traceback/unbound variable YOK).

Sonra temizle: `sudo srvctl domain ini example.com --file /tmp/t.ini`

## 10. Rollback servis kesintisi yaratmıyor

```bash
# Geçerli sözdizimi ama php-fpm'in reddedeceği bir değer:
printf 'memory_limit = 512Z\n' | sudo tee /tmp/broken.ini >/dev/null
cp /etc/srvctl/fpm/example_com.conf /tmp/pool.before

sudo srvctl domain ini example.com --file /tmp/broken.ini ; echo "rc=$?"

diff /tmp/pool.before /etc/srvctl/fpm/example_com.conf && echo "POOL AYNI"
curl -s -o /dev/null -w '%{http_code}\n' https://example.com/    # → 200
```

**Beklenen:** `rc=1`, php-fpm'in kendi hata satırı girintili olarak gösterilir, **pool dosyası birebir aynı**, site **200 dönmeye devam eder** (reload hiç denenmemiştir).

## 11. `--all` ölçek davranışı

Birden fazla domainli host'ta:

```bash
sudo srvctl domain reload --all
journalctl -u nginx --since "1 min ago" | grep -c "reload"
```

**Beklenen:** Her domain için bir FPM satırı; **nginx yalnız BİR KEZ** reload edilir (domain başına değil).

Bir domaini kasıtlı bozup (`systemctl mask srvctl-fpm-<sname>.service`) tekrar çalıştır:

**Beklenen:** Bozuk domain raporlanır, **diğerleri yine de reload edilir**, komut non-zero döner. (Sonra `systemctl unmask` ile geri al.)

## 12. `sudo` vs `sudo -E`

```bash
export EDITOR=vim
sudo srvctl domain ini example.com      # → nano açılır (env_reset)
sudo -E srvctl domain ini example.com   # → vim açılır
```

**Beklenen:** README'de belgelenen davranış birebir gözlenir.

## 13. Yaşam döngüsü

```bash
sudo srvctl domain add yeni.com --php=8.3
ls -l /etc/srvctl/php.d/yeni_com.ini /etc/nginx/custom.d/yeni_com/00-custom.conf   # → ikisi de var, 644 root:root
grep custom.d /etc/nginx/sites-available/yeni.com.conf                            # → include satırı var

sudo srvctl domain clone yeni.com klon.com
diff /etc/srvctl/php.d/yeni_com.ini /etc/srvctl/php.d/klon_com.ini                 # → aynı

sudo srvctl domain remove klon.com
ls /etc/srvctl/php.d/klon_com.ini /etc/nginx/custom.d/klon_com 2>&1                # → ikisi de YOK
```

## 14. Deploy regresyonu (Task 2 refactor'ı)

`_deploy_reload_fpm` core.sh helper'ına delege edildi; davranışın değişmediği gerçek bir deploy ile doğrulanmalı.

```bash
sudo srvctl deploy example.com
```

**Beklenen:** Deploy sorunsuz tamamlanır, FPM reload adımı geçer. Özellikle izole FPM'li domainde "PHP-FPM çalışmıyor olabilir" hatası **alınmamalıdır** (bu, refactor'dan önce düzeltilmiş olan host bulgusunun geri gelmediğinin kanıtı).

---

## Sonuç kaydı

| # | Madde | 22.04 | 24.04 | Not |
|---|---|---|---|---|
| 1 | İzole FPM reload | ☐ | ☐ | |
| 2 | Paylaşılan FPM reload | ☐ | ☐ | |
| 3 | `.ini` gerçekten etkili | ☐ | ☐ | **kritik** |
| 4 | `repair` korur | ☐ | ☐ | **kritik** |
| 5 | `php-switch` korur | ☐ | ☐ | |
| 6 | `harden-fpm` korur | ☐ | ☐ | |
| 7 | nginx override çalışıyor | ☐ | ☐ | |
| 8 | Include ön koşul kapısı | ☐ | ☐ | |
| 9 | `--force` + bildirim | ☐ | ☐ | regresyon |
| 10 | Rollback kesintisiz | ☐ | ☐ | **kritik** |
| 11 | `--all` ölçek | ☐ | ☐ | |
| 12 | `sudo -E` | ☐ | ☐ | |
| 13 | Yaşam döngüsü | ☐ | ☐ | |
| 14 | Deploy regresyonu | ☐ | ☐ | regresyon |
