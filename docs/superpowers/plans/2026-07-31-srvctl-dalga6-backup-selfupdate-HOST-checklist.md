# DALGA 6 (release yöneticisi: lib/backup.sh + lib/selfupdate.sh) — Ubuntu Host Doğrulama Kontrol Listesi

> macOS'ta uygulanan alt-küme: `bash -n lib/backup.sh lib/selfupdate.sh`,
> `shellcheck -x lib/backup.sh lib/selfupdate.sh`, `bash tests/run.sh` — hepsi
> TEMİZ (bkz. rapor). Ayrıca `lib/selfupdate.sh`'ın git-pinning mantığı yerel
> sahte git repo'larla VE gerçek `github.com/bertugfahriozer/srvctl` ile
> (yalnız `git ls-remote`/`clone`/fetch-by-SHA, salt-okunur) macOS'ta ayrıca
> doğrulandı (bkz. rapor). **[HOST]** işaretli adımlar gerçek bir root Ubuntu
> host'ta uygulanmalıdır; macOS'ta systemd/nginx/mariadb/redis/gpg tam
> davranışıyla YOKTUR. Aşağıdaki adımlar **22.04 (jammy) VE 24.04 (noble)**
> için AYRI AYRI koşulmalıdır.

## Önkoşul

Temiz bir Ubuntu 22.04 VEYA 24.04 VM, `sudo bash install.sh && sudo srvctl init`
çalıştırılmış, en az bir domain eklenmiş (`sudo srvctl domain add test.local`).

---

## 1. [HOST] self-update: pinned-commit modeli uçtan uca

```bash
sudo srvctl self-update check
# beklenen: "Pinlendi: <hash8> — uygulamak için: sudo srvctl self-update run"
sudo cat /usr/local/srvctl/.selfupdate-pending   # PINNED_COMMIT=... PINNED_AT=... PINNED_REPO=...
stat -c '%a %U' /usr/local/srvctl/.selfupdate-pending   # beklenen: 600 root

sudo srvctl self-update run
# beklenen adımlar (1/5..5/5): pinlenmiş commit fetch, HEAD eşleşme onayı,
# dosya kopyalama, sağlık kontrolü (bash -n + nginx -t + srvctl version), tamamlandı
srvctl version                      # yeni sürümü göstermeli
cat /usr/local/srvctl/.current-commit   # PINNED_COMMIT ile aynı 40-hex hash
ls /usr/local/srvctl/.selfupdate-pending 2>&1   # beklenen: "No such file" (tüketildi)
ls -la /usr/local/srvctl/.backups/           # beklenen: en az 1 zaman damgalı dizin
```

**'run' önce 'check' olmadan reddediyor mu?**
```bash
sudo rm -f /usr/local/srvctl/.selfupdate-pending
sudo srvctl self-update run
# beklenen: "Pinlenmiş bir güncelleme yok. Önce çalıştırın: sudo srvctl self-update check"
```

**Pin dosyası tamper edilirse reddediliyor mu?**
```bash
sudo srvctl self-update check
sudo chmod 644 /usr/local/srvctl/.selfupdate-pending
sudo srvctl self-update run
# beklenen: "GÜVENLİK: ... root sahipli/izinli değil ... Reddedildi"
```

**Uydurma/bozuk pin içeriği reddediliyor mu?**
```bash
sudo srvctl self-update check
echo "PINNED_COMMIT=deadbeef" | sudo tee /usr/local/srvctl/.selfupdate-pending
sudo chmod 600 /usr/local/srvctl/.selfupdate-pending
sudo srvctl self-update run
# beklenen: "Pin dosyası bozuk (geçersiz commit hash biçimi): deadbeef"
```

## 2. [HOST] self-update: sağlık kontrolü BAŞARISIZLIĞINDA otomatik rollback

```bash
sudo srvctl self-update check
# Klonun 'run' fetch ettiği HAM kaynağı bozamayız (repo dışarıda) — ama
# 'run' sırasında dosyalar kopyalandıktan HEMEN SONRA, sağlık kontrolünden
# ÖNCE bir syntax hatası enjekte edip health-check'in bunu YAKALADIĞINI
# görmek için lib/*.sh'a geçici bir 'set -x <<<' benzeri bozukluk enjekte
# eden bir test kancası GEREKİR — bunun yerine en pratik doğrulama:
# staging'i taklit eden bir 'srvctl self-update run' ÇALIŞTIRMADAN önce
# lib/ içine kasıtlı bozuk bir dosya koyup 'sudo srvctl self-update run'ı
# tetiklemek (staging klonu TEMİZ geleceğinden bu köprüyü kurmaz) — bu
# senaryo gerçek anlamda yalnızca CI'de sahte bir upstream repo ile
# tekrarlanabilir. Asgari doğrulama:
bash -n /usr/local/srvctl/lib/*.sh /usr/local/srvctl/bin/srvctl   # hepsi 0 dönmeli
nginx -t                                                          # syntax is ok
srvctl version                                                    # çalışıyor
```
> NOT: Tam "kötü güncelleme → otomatik rollback" senaryosu yalnızca gerçek bir
> bozuk commit'i barındıran bir test/staging fork repo'suyla uçtan uca
> tekrarlanabilir. Kod yolu (`_selfupdate_health_check` başarısız →
> `_selfupdate_restore_from_backup` çağrısı → `error()`) mantık olarak macOS'ta
> sahte bir SRVCTL_ROOT üzerinde ayrı ayrı doğrulandı (bkz. rapor), ama uçtan
> uca "gerçek bozuk bir commit'i self-update ile kurmaya çalışmak" HOST'ta
> AYRICA test edilmeli — bu KOŞULMADI.

## 3. [HOST] self-update rollback (manuel)

```bash
sudo srvctl self-update rollback
# onay istemi: 'evet' yazın
srvctl version                       # bir önceki sürüme dönmüş olmalı
cat /usr/local/srvctl/.current-commit
sudo srvctl self-update rollback eski-olmayan-bir-ad
# beklenen: "Yedek bulunamadı: ..."
```

## 4. [HOST] self-update: yedek retention + conf/srvctl.conf ASLA yedeklenmiyor

```bash
for i in $(seq 1 6); do sudo srvctl self-update check && sudo srvctl self-update run <<< "hayır"; done
ls /usr/local/srvctl/.backups/ | wc -l    # beklenen: en fazla 3 (SELFUPDATE_KEEP_BACKUPS varsayılanı)
grep -rl "REDIS_ADMIN_PASS\|CF_API_TOKEN" /usr/local/srvctl/.backups/ 2>/dev/null
# beklenen: HİÇBİR eşleşme (srvctl.conf hiçbir yedekte YOK)
```

## 5. [HOST] self-update: rate-profiles.conf güncelleniyor, srvctl.conf korunuyor

```bash
sudo sed -i 's/^\(SSH_PORT=\).*/\122222/' /usr/local/srvctl/conf/srvctl.conf   # elle bir değişiklik
sudo srvctl self-update check && sudo srvctl self-update run
grep '^SSH_PORT=' /usr/local/srvctl/conf/srvctl.conf   # beklenen: 22222 (KORUNDU)
diff /usr/local/srvctl/conf/rate-profiles.conf <(git -C /path/to/srvctl-repo show HEAD:conf/rate-profiles.conf)
# beklenen: fark YOK (güncellendi)
```

## 6. [HOST] self-update sonunda 'domain repair --all' rehberliği + interaktif tetik

```bash
sudo srvctl self-update check && sudo srvctl self-update run
# beklenen: "ÖNEMLİ — CONFIG DRIFT: ... sudo srvctl domain repair --all" net uyarısı
# ardından "Şimdi 'srvctl domain repair --all' çalıştırılsın mı?" istemi
# 'evet' derseniz cmd_domain repair --all GERÇEKTEN tetiklenmeli (domain.sh
# çıktısı görünmeli); 'hayır' derseniz yalnızca hatırlatma basılmalı.
```

## 7. [HOST] backup run: disk alanı preflight

```bash
# Küçük bir tmpfs bağlayıp BACKUP_DIR'i oraya yönlendirerek düşük alan simüle et
sudo mount -t tmpfs -o size=50M tmpfs /mnt/tinybackup
sudo sed -i "s#^BACKUP_DIR=.*#BACKUP_DIR=/mnt/tinybackup#" /usr/local/srvctl/conf/srvctl.conf
sudo srvctl backup run
# beklenen: "Yetersiz disk alanı: ... yedekleme BAŞLATILMADI" (BACKUP_MIN_FREE_MB varsayılan 500)
sudo umount /mnt/tinybackup
```

## 8. [HOST] backup run: tek bozuk DB tüm yedeklemeyi KESMİYOR

```bash
# Bozuk/kilitli bir DB simüle et (ör. yetkisiz bir kullanıcıyla mysqldump çağrısı
# başarısız olacak şekilde bir DB'nin grant'ini geçici kısıtlayın) VEYA
# basitçe 'mysqldump' PATH'ini geçici olarak bozup TEK seferlik başarısızlık
# üretecek bir wrapper koyun, sonra geri alın.
sudo srvctl backup run
# beklenen: "N veritabanı yedeklenemedi" uyarısı basılır AMA komut devam eder;
# Dosya/Redis/Config adımları YİNE DE çalışır (log'da bkz.):
sudo tail -5 /usr/local/srvctl/logs/srvctl.log | grep BACKUP
# beklenen: 'db_fail=' alanı > 0 olsa bile 'files=' ve config adımı TAMAMLANMIŞ
```

## 9. [HOST] backup run: configs.tar.gz artık SIR İÇERMİYOR (varsayılan)

```bash
sudo srvctl backup run
LATEST=$(ls -t /backups | head -1)
sudo tar -tzf "/backups/${LATEST}/configs.tar.gz" | grep -c users.acl    # beklenen: 0
sudo tar -tzf "/backups/${LATEST}/configs.tar.gz" | grep -c 'srvctl.conf$'  # beklenen: 0
sudo tar -tzf "/backups/${LATEST}/configs.tar.gz" | grep -c redis.conf   # beklenen: >=1 (diğer redis config'leri hâlâ var)
```

## 10. [HOST] backup run: BACKUP_GPG_RECIPIENT opt-in şifreleme

```bash
sudo apt-get install -y gnupg
sudo -u root gpg --batch --passphrase '' --quick-gen-key "srvctl-backup-test" default default
RECIPIENT=$(sudo gpg --list-keys --with-colons "srvctl-backup-test" | awk -F: '/^fpr/{print $10; exit}')
echo "BACKUP_GPG_RECIPIENT=${RECIPIENT}" | sudo tee -a /usr/local/srvctl/conf/srvctl.conf
sudo srvctl backup run
LATEST=$(ls -t /backups | head -1)
ls "/backups/${LATEST}/" | grep configs.tar.gz    # beklenen: configs.tar.gz.gpg (plaintext YOK)
sudo gpg --decrypt "/backups/${LATEST}/configs.tar.gz.gpg" 2>/dev/null | tar -tzf - | grep -c users.acl
# beklenen: >=1 (bu modda sırlar DAHİL — operatör bilerek opt-in oldu)
```
> NOT: `conf/srvctl.conf`/`lib/core.sh` benim dosyam DEĞİL — `BACKUP_GPG_RECIPIENT`
> şu an yalnızca `${BACKUP_GPG_RECIPIENT:-}` fallback'iyle okunuyor,
> `load_config`'e KALICI bir varsayılan olarak EKLENMEDİ. Bu HOST testinde
> `srvctl.conf`'a elle eklendi — kalıcı hale getirilmesi core.sh sahibine
> devredilmiştir (bkz. rapor).

## 11. [HOST] backup restore --dry-run + tek-domain filtresi

```bash
sudo srvctl backup restore "$(ls /backups | tail -1)" --dry-run
# beklenen: '[dry-run] DB geri yüklenecekti: ...' / hiçbir mysql/cp komutu ÇALIŞMADI
sudo srvctl backup restore "$(ls /backups | tail -1)" test.local
# beklenen: yalnızca 'db_test_local' ve 'test.local-files.tar.gz' işlenir,
# redis.rdb ATLANIR ("yalnız TAM restore'da" notu)
```

## 12. [HOST] Ubuntu 22.04 vs 24.04 farkları — özellikle izlenmesi gerekenler

- **MariaDB istemci adlandırması**: Ubuntu 24.04'ün MariaDB 10.11/11.x
  paketlerinde `mysqldump`/`mysql` ikili adları resmi olarak `mariadb-dump`/
  `mariadb`'a taşınıyor (geriye uyumluluk symlink'leri genelde hâlâ mevcut,
  ama garanti değil — paket sürümüne göre değişir). `_backup_run`/
  `_backup_restore` DOĞRUDAN `mysqldump`/`mysql` çağırıyor (bu, benim bu
  turda değiştirmediğim ÖNCEDEN VAR OLAN bir bağımlılıktır). **HOST'ta HER
  İKİ sürümde de doğrulanmalı:** `command -v mysqldump && command -v mysql`.
  24.04'te symlink yoksa `srvctl backup run` SESSİZCE "0 veritabanı
  yedeklendi" der (mysqldump: command not found → `db_fail_count`
  ARTAR ama script `set -e` altında `command -v` kontrolü OLMADIĞI için
  şu anki kodda bu durum yalnızca 'if' bloğu içinde yakalanır — DAVRANIŞ:
  yedekleme devam eder, hatalar loglanır, ama operatör "0 DB yedeklendi"yi
  fark etmezse SESSİZ bir veri kaybı riski oluşur). Bu, DALGA 6 kapsamı
  DIŞINDA bırakılan bir bulgu olarak rapor edilmiştir (bkz. rapor "Ertelendi").
- **git sürümü**: `_selfupdate_fetch_pinned`'in birincil yolu (fetch-by-SHA)
  GitHub.com'un SUNUCU tarafı desteğine dayanır (istemci git sürümünden
  BAĞIMSIZ çalışır — `git fetch origin <sha>` eski git istemcilerinde de
  çalışır). Yine de 22.04'ün git paketi (2.34) ile 24.04'ün (2.43) arasında
  davranış farkı OLMAMALI; her ikisinde de test edilmesi önerilir.
- **gpg sürümü**: 22.04 gpg 2.2.x, 24.04 gpg 2.4.x — `--pinentry-mode loopback`
  gerektirebilecek anahtar üretim adımları sürümler arası farklılık
  gösterebilir (HOST checklist madde 10 HER İKİSİNDE ayrı ayrı denenmeli).

---

## Başarı kriteri

1. Pinned-commit modeli `check`/`run` ayrımını ZORUNLU kılıyor; tamper edilmiş
   veya bozuk pin dosyası fail-closed reddediliyor.
2. Sağlık kontrolü mantığı (bash -n/nginx -t/srvctl version) çalışıyor;
   TAM "kötü commit → otomatik rollback" ucu-uca senaryosu ayrı bir
   staging-repo testiyle DOĞRULANMALI (bu listede yalnızca kısmi doğrulandı).
3. Manuel `self-update rollback` çalışıyor ve sağlık kontrolünü tekrar koşuyor.
4. Yedek sayısı sınırlı (varsayılan 3) ve `conf/srvctl.conf` HİÇBİR yedekte
   bulunmuyor.
5. `conf/rate-profiles.conf` güncelleniyor, `conf/srvctl.conf` korunuyor.
6. `domain repair --all` rehberliği net + interaktif tetik çalışıyor.
7. Disk alanı yetersizken yedekleme başlamıyor.
8. Tek bir bozuk DB tüm yedeklemeyi KESMİYOR, yalnız o DB atlanıyor.
9. `configs.tar.gz` varsayılan olarak `users.acl`/`srvctl.conf` İÇERMİYOR.
10. `BACKUP_GPG_RECIPIENT` ayarlıyken sırlar yalnızca şifreli (.gpg) olarak
    diske düşüyor, plaintext ARA dosya asla oluşmuyor.
11. `restore --dry-run` hiçbir şey yazmıyor; tek-domain filtresi doğru
    dosya/DB alt kümesini seçiyor.
12. 22.04 VE 24.04'te `mysqldump`/`mysql` komutları GERÇEKTEN mevcut
    (24.04'te symlink garantisi yok — ayrı doğrulanmalı).

Bu liste henüz gerçek bir host'ta KOŞULMADI — yalnızca macOS'ta statik olarak
doğrulanabilenler (`bash -n`, `shellcheck -x`, `bash tests/run.sh`, yerel git
repo + gerçek GitHub.com'a karşı salt-okunur fetch-by-SHA testleri, bkz.
rapor) çalıştırıldı. Yukarıdaki tüm [HOST] adımları MANUEL doğrulama bekliyor.
