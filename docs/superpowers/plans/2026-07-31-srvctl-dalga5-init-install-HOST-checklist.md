# DALGA 5 (release yöneticisi: lib/init.sh + install.sh) — Ubuntu Host Doğrulama Kontrol Listesi

> macOS'ta uygulanan alt-küme: `bash -n lib/init.sh install.sh`, `shellcheck -x
> lib/init.sh install.sh`, `bash tests/run.sh` — hepsi TEMİZ (bkz. rapor).
> **[HOST]** işaretli adımlar gerçek bir root Ubuntu host'ta uygulanmalıdır;
> macOS'ta hiçbiri gerçekten koşturulamaz (BSD sed farklı davranır, systemd/
> nginx/redis/ModSecurity yok). Aşağıdaki adımlar **22.04 (jammy) VE 24.04
> (noble)** için AYRI AYRI koşulmalıdır — biri diğerini garanti etmez.

## Önkoşul

Temiz bir Ubuntu 22.04 VEYA 24.04 VM/konteyner, root erişim, `sudo bash
install.sh && sudo srvctl init` çalıştırılabilir durumda.

---

## 1. [HOST] `_sed_inplace` dönüşümü sonrası nginx.conf/redis.conf bozulmadı

```bash
sudo srvctl init
nginx -t                                   # beklenen: "syntax is ok" / "test is successful"
grep -c "modsecurity on;" /etc/nginx/nginx.conf            # beklenen: 1
grep -c "modsecurity_rules_file" /etc/nginx/nginx.conf     # beklenen: 1
grep -c "geoip_country" /etc/nginx/nginx.conf              # beklenen: 1 (GeoIP.dat bulunduysa)
grep -c "^SecRuleEngine On" /etc/nginx/modsec/modsecurity.conf  # beklenen: 1

# redis.conf İÇERİĞİ sed ile DEĞİŞTİRİLMİYOR artık (REDIS_ADMIN_PASS artık
# yalnızca srvctl.conf'a yazılıyor) — burada asıl kontrol srvctl.conf:
grep "^REDIS_ADMIN_PASS=" /usr/local/srvctl/conf/srvctl.conf   # beklenen: dolu bir parola, tek satır
redis-cli -a "$(grep REDIS_ADMIN_PASS /usr/local/srvctl/conf/srvctl.conf | cut -d= -f2)" \
    --user admin --no-auth-warning PING            # beklenen: PONG (ACL parolası GERÇEKTEN eşleşiyor)
```

**Kritik regresyon testi — idempotent ikinci çalıştırma:**
```bash
sudo srvctl init --force
nginx -t                                   # HÂLÂ syntax ok olmalı (çift injection/duplicate directive YOK)
grep -c "modsecurity on;" /etc/nginx/nginx.conf            # HÂLÂ 1 olmalı (2 DEĞİL — idempotent grep -q guard)
```

## 2. [HOST] ModSecurity GERÇEKTEN enforce modda (DetectionOnly değil)

```bash
sudo srvctl domain add example.com --php=8.3
curl -sk -H "Host: example.com" \
    "https://127.0.0.1/?x=<script>alert(1)</script>" \
    -o /dev/null -w '%{http_code}\n'
# beklenen: 403 (OWASP CRS XSS kuralı BLOKLADI — SecRuleEngine On ise böyle
# olmalı; DetectionOnly kalsaydı 200 dönerdi ve WAF SESSİZCE pasif olurdu)

tail -5 /var/log/nginx/modsecurity-audit.log   # beklenen: az önceki isteğin audit kaydı
```

## 3. [HOST] `/var/lib/modsecurity` dizin yapısı ve izinleri

```bash
stat -c '%U:%G %a' /var/lib/modsecurity            # beklenen: root:www-data 750
stat -c '%U:%G %a' /var/lib/modsecurity/tmp        # beklenen: www-data:www-data 700
stat -c '%U:%G %a' /var/lib/modsecurity/data       # beklenen: www-data:www-data 700
stat -c '%U:%G %a' /var/lib/modsecurity/upload     # beklenen: www-data:www-data 700

# Fonksiyonellik: ModSecurity GERÇEKTEN bu dizinlere yazabiliyor mu?
# (SecTmpDir dolu bir istek gövdesinde kullanılır — büyük POST ile tetikle)
curl -sk -X POST -H "Host: example.com" \
    -d "$(head -c 200000 /dev/urandom | base64)" \
    "https://127.0.0.1/" -o /dev/null -w '%{http_code}\n'
# beklenen: 200/403 (isteğin İŞLENDİĞİNİ gösterir) — nginx error.log'da
# "Permission denied" / "SecTmpDir" hatası OLMAMALI:
grep -i "modsecurity" /var/log/nginx/error.log | tail -5
```

## 4. [HOST] Eski `/tmp/modsecurity` geriye-uyum temizliği

```bash
# Simüle et: eski sürümden kalmış gibi göster
sudo mkdir -p /tmp/modsecurity/upload && sudo chmod 0777 /tmp/modsecurity
sudo touch /tmp/modsecurity/upload/sahte-hassas-veri.bin

sudo srvctl init --force        # veya: sadece _install_modsecurity'yi tetikleyen adım
ls -la /tmp/modsecurity 2>&1    # beklenen: "No such file or directory" (silindi)
ls -la /var/lib/modsecurity     # beklenen: yeni, doğru izinli dizin ağacı var
```

## 5. [HOST] `install.sh` — ölü seccomp referansı temizliği

```bash
sudo bash install.sh            # yeniden kurulum (idempotent)
ls /usr/local/srvctl/templates/ | grep -c seccomp     # beklenen: 0
ls /usr/local/srvctl/templates/                       # beklenen: apparmor cgroups logrotate nginx php-fpm systemd (seccomp YOK)
```

## 6. [HOST] `install.sh` OS kapısı — 22.04/24.04 sessiz geçiş

```bash
lsb_release -rs      # 22.04 veya 24.04 olmalı
sudo bash install.sh # beklenen: sürüm/onay istemi ÇIKMAMALI (sessizce devam)
```
Farklı bir Ubuntu sürümünde (ör. bir 20.04/25.04 VM'i varsa) test edilirse:
```bash
sudo bash install.sh
# beklenen: "⚠ srvctl Ubuntu 22.04 / 24.04 LTS üzerinde test edilmiştir..." uyarısı
# + 'evet' istemi (fail-closed DEĞİL — 'hayır' derse çıkar, 'evet' derse devam eder)
```

## 7. [HOST] `srvctl init` idempotency — genel regresyon

```bash
sudo srvctl init          # 1. çalıştırma — 12 adım da tamamlanmalı
sudo srvctl init          # 2. çalıştırma — TÜM adımlar "atlanıyor" demeli (marker'lar sayesinde)
echo $?                    # beklenen: 0
```

## 8. [HOST] Yedek-sır uyarısı gerçekten görünüyor

```bash
sudo srvctl init 2>&1 | grep -i "düz metin sır içerir"
# beklenen: 'srvctl init' çıktısının sonunda BACKUP_DIR uyarısı görünür
```

---

## Başarı kriteri

- 1: `_sed_inplace` dönüşümü sonrası nginx.conf/redis-admin-parola akışı hem
  İLK hem İKİNCİ `init` çalıştırmasında BOZULMADAN çalışıyor (duplicate
  injection yok, `nginx -t` her zaman yeşil, ACL parolası GERÇEKTEN eşleşiyor).
- 2: ModSecurity `SecRuleEngine On` yalnızca dosyada değil, GERÇEK bir istekte
  CRS kuralını tetikleyip 403 döndürerek de doğrulanmış (enforce, DetectionOnly
  DEĞİL).
- 3: `/var/lib/modsecurity` ağacı doğru sahiplik/izinle oluşuyor VE nginx
  worker'ı fonksiyonel olarak yazabiliyor (permission denied YOK).
- 4: Eski `/tmp/modsecurity` içeriğiyle birlikte temizleniyor, yeni konum
  sorunsuz devreye giriyor.
- 5: `install.sh` artık `templates/seccomp/` oluşturmuyor/kopyalamıyor.
- 6: OS kapısı 22.04/24.04'te sessiz, diğer sürümlerde uyarı-tabanlı (fail-closed
  DEĞİL).
- 7: `srvctl init` ikinci çalıştırmada idempotent (marker'lar çalışıyor).
- 8: Operatör, yedeklerin sır içerdiği konusunda `init` çıktısında açıkça
  uyarılıyor (gerçek düzeltme `lib/backup.sh`'ta ayrı turda ele alınacak — bkz.
  rapor madde 4).

Hepsi yeşilse bu dalganın `lib/init.sh`/`install.sh` kapsamı hem 22.04 hem
24.04'te production'a hazırdır. Bu liste henüz gerçek bir host'ta KOŞULMADI —
yalnızca macOS'ta statik olarak doğrulanabilenler (`bash -n`, `shellcheck -x`,
`bash tests/run.sh`) çalıştırıldı; yukarıdaki tüm [HOST] adımları hâlâ MANUEL
doğrulama bekliyor.
