# srvctl — Yeni Özellik ve İyileştirme Önerileri (Eylül 2026)

Haftalık inceleme turundan çıkan beş öneri. Hiçbiri güvenliği zayıflatmaz; ilk ikisi
aynı zamanda `guvenlik/haftalik-denetim-2026-09` dalındaki bulguların kalıcı regresyon
kapısı işlevini görür. Her madde: gerekçe → tasarım taslağı → güvenlik etkisi → efor.

Karşılaştırma bağlamı: HestiaCP, CyberPanel, CloudPanel ve OpenPanel'in hiçbiri domain
başına AppArmor + chroot + izole FPM unit'ini srvctl kadar ileri götürmüyor — OpenPanel
konteyner tabanlı, diğerleri dosya izni + `open_basedir` düzeyinde kalıyor. srvctl'in
asıl farklılaştırıcısı bu; aşağıdaki öneriler o farkı **koruyup ölçülebilir** kılmayı
hedefliyor.

---

## 1. `srvctl audit` — dahili öz-denetim komutu

**Gerekçe.** Denetim raporlarının bulguları koda tek tek yamayla giriyor ama çalışan
sunucunun **canlı durumunu** aynı değişmezlere karşı sınayan bir kapı yok. Son turun
Kritik ve Yüksek bulgularının ortak teması şuydu: "başka bir dosyada zaten kapatılmış
bir sınıf, bu dosyada kapatılmamış". `tests/` bunu kaynak kodu düzeyinde yakalıyor;
`srvctl audit` aynı şeyi **kurulu sistem** düzeyinde yakalar.

**Taslak.** `lib/security.sh`'taki `_security_run_check` / `_check` altyapısı (argv
doğrudan, eval yok) yeniden kullanılır. İlk kontrol seti:

| Kontrol | Ne bakar | Kaynak bulgu |
|---|---|---|
| `home-symlinks` | `/home/*/.ssh`, `authorized_keys`, `.google_authenticator` symlink mi | K1 |
| `sudoers-wildcard` | `/etc/sudoers.d/srvctl-*` içinde ` *` biten satır var mı | Y1 |
| `trusted-cidr-width` | `trusted/*.conf` içinde v4 `/8`'den, v6 `/16`'dan geniş aralık | Y2 |
| `realip-scope` | `srvctl-cloudflare-realip.conf`'ta `set_real_ip_from 0.0.0.0/0` | Y2 |
| `hidepid-live` | `/proc/mounts`'ta `hidepid=2` gerçekten var mı | O2 |
| `creds-mode` | dünya-okunur `.credentials` / `.srvctl-meta` | mevcut testler |
| `plugin-pins` | `.pinned-commit` ile `git rev-parse HEAD` uyuşuyor mu | Y4 |
| `tmp-artifacts` | `/tmp/srvctl-*`, `/tmp/modsecurity` kalıntıları | O1 |
| `unit-hardening` | `srvctl-*.service`'lerde `NoNewPrivileges`/`ProtectSystem` eksik mi | O3 |

Çıktı: `_security_audit` ile aynı PASS/WARN/FAIL biçimi + `--json`. `--fix` yok;
her bulgu için "şu komutu çalıştırın" satırı basılır (`domain repair`, `user key`
vb.). Cron'a `srvctl audit --quiet` eklenir, FAIL varsa `send_notification`.

**Güvenlik etkisi.** Doğrudan olumlu — salt-okuma, hiçbir yetki genişlemez, tespit
katmanı ekler.
**Efor.** Orta (~300 satır + testler; altyapı hazır).

---

## 2. RBAC'ı sudoers'tan CLI'ya taşıyın

**Gerekçe.** sudoers'ın `fnmatch` argüman eşleşmesi yetkilendirme için yanlış
katman: `*` boşluk dahil her şeyi eşleştirdiği için bayrak dışlamak imkânsız.
Güvenlik dalı `require_role` / `require_domain_grant` kapılarını ekledi; bu öneri o
kapıyı **tek karar noktası** hâline getirip sudoers'ı tek satıra indirir.

**Taslak.**
- `bin/srvctl` dispatch'inde, `cmd_*` çağrısından **önce** merkezi bir
  `rbac_check <komut> <altkomut> <domain?>` çağrısı. İzin matrisi tek yerde
  (`conf/rbac.conf`, `read_kv_file` ile okunur — `source` YOK):
  ```
  viewer:    status domain.list domain.info ssl.status
  developer: +deploy.* backup.run monitor.* domain.ini domain.nginx
  admin:     *
  ```
- `_update_sudoers` her rol için `srvctl *` yazar; yetki kararı CLI'da.
- Geçiş: iki sürüm boyunca hem sudoers hem CLI kapısı birlikte çalışır
  (`SRVCTL_RBAC_LEGACY_SUDOERS=true`), sonra sudoers daraltılır.
- `srvctl user info` artık **etkin** izinleri gösterir (matris × DOMAINS).

**Güvenlik etkisi.** Belirgin olumlu — bugün dekoratif olan çok-kiracılı izolasyon
gerçek olur. Dikkat: sudoers'ı `srvctl *`'a genişletmek yalnızca CLI kapısı **aynı
commit'te** giriyorsa güvenlidir; geçiş bayrağı bu yüzden var.
**Efor.** Orta.

---

## 3. Tedarik zinciri: `trusted` için depoda taşınan taban liste + plugin `update`

**Gerekçe.** Y2 ve Y4'ün ortak kökü, dışarıdan gelen içeriğe bütünlük doğrulaması
olmadan güvenilmesi. Güvenlik dalı genişlik tavanı ve onay/pin ekledi; bu öneri
"neye göre doğru?" sorusuna referans verir.

**Taslak.**
- `conf/trusted-baseline/cloudflare-v4.conf`, `-v6.conf`, `uptimerobot.conf`:
  depoda versiyonlanan, `install.sh`/`selfupdate` ile taşınan taban listeler.
- `_trusted_sync`: çekilen liste tabanla `< %50` örtüşüyorsa **reddet** ("kaynak
  değişmiş ya da ele geçirilmiş"); fetch tamamen başarısızsa tabana düş.
- `srvctl trusted list`: "taban liste yaşı: N gün" satırı; 180 günü geçince WARN.
- `srvctl plugin update <isim>`: `.pinned-commit` ile uzak HEAD'i karşılaştırır,
  fark varsa diff özetini gösterip **yeniden onay** ister (selfupdate'in TOFU akışı).

**Güvenlik etkisi.** Olumlu; taban listenin bayatlaması riski yaş uyarısıyla yönetilir.
**Efor.** Küçük–Orta.

---

## 4. Kurcalamaya dayanıklı, yapılandırılmış denetim günlüğü

**Gerekçe.** `changelog.log` root'un serbestçe yazıp silebildiği düz `ts|user|action`
metni — bir ihlal sonrası ilk silinecek şey. Proje zaten `auditd` kuruyor; iki
denetim izinin ayrı formatta olması korelasyonu zorlaştırıyor.

**Taslak.**
- `log_to_changelog` → JSON satırı (`{"ts","user","cmd","argv","rc","host"}`),
  ek olarak `logger -p authpriv.notice -t srvctl` ile journald'a.
- `chattr +a` (append-only) — `srvctl init` uygular, `srvctl audit` doğrular.
- `srvctl changelog export --json --since 7d`; O1 düzeltmesinin üstüne, dışa
  aktarma yerine journald sorgusu birincil yol olur.
- Uzak gönderim için hazır: `journal-upload`/rsyslog örnek konfigürasyonu `docs/`'a.

**Güvenlik etkisi.** Olumlu — adli inceleme kabiliyeti, tamper-evidence.
**Efor.** Orta.

---

## 5. Deploy hook'ları için sandbox

**Gerekçe.** Zincirde tek boşluk: `composer install` ve kullanıcı tanımlı deploy
hook'ları web kullanıcısı olarak çalışsa da AppArmor profiliyle **sınırlanmıyor**.
Ele geçirilmiş bir composer paketi bugün `WEB_ROOT/<domain>` dışına yazamaz ama
ağ erişimi ve `/tmp` serbest.

**Taslak.**
- `bwrap` (bubblewrap) ya da `systemd-run --scope -p ...` ile hook'lar: yalnız
  `release_dir` + `shared/` yazılabilir, ağ yalnız paket kayıtlarına
  (`packagist.org`, `registry.npmjs.org` — allowlist `conf/deploy-egress.conf`),
  `PrivateTmp`, `NoNewPrivileges`, `MemoryMax` domain'in resource-profile'ından.
- Aşamalı: önce `--sandbox=report` (ihlalleri sadece loglar), sonra `enforce`;
  `--sandbox=off` kaçış valfi ve `.srvctl-meta: DEPLOY_SANDBOX=` kalıcı tercihi.
- `srvctl deploy --dry-run` sandbox raporunu da basar.

**Güvenlik etkisi.** Belirgin olumlu; risk, aşırı dar profilin meşru build'leri
kırması — bu yüzden `report` modu önce gelir.
**Efor.** Büyük.

---

## Önerilen sıra

1. **#2 RBAC** — güvenlik dalındaki kapıların doğal devamı, tasarım kararı gerektirir.
2. **#1 audit** — #2 ile aynı sprintte; kapıları canlıda doğrular.
3. **#3 taban liste** — küçük, bağımsız.
4. **#4 günlük**, sonra **#5 sandbox**.
