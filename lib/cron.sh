#!/bin/bash
# ═══════════════════════════════════════════════
#  cron.sh — Kullanıcı Dostu Cron (arka planda systemd timer)
# ═══════════════════════════════════════════════
#
# NEDEN crontab DEĞİL: bir crontab satırı root'un cron daemon'ından PROFİLSİZ
# doğar — srvctl'in domain başına kurduğu tüm izolasyonu (AppArmor, cgroup
# slice, seccomp, NoNewPrivileges, domain kullanıcısı) DELER. Bu modül
# yerine systemd timer + oneshot service kurar; şablonlar (templates/systemd/
# srvctl-cron*.tpl, srvctl-syscron*.tpl — AYRI bir görevde yazıldı) domain
# kapsamlı cron'u worker/scheduler İLE AYNI izolasyon katmanlarına
# (AppArmorProfile, Slice, seccomp deny listesi) bağlar.
#
# KAPSAM (kullanıcı kararı): HEM domain-bazlı HEM sistem geneli cron'lar.
#   - Domain:  srvctl-cron-<sname>-<ad>.service/.timer     (web_<sname> olarak çalışır)
#   - Sistem:  srvctl-syscron-<ad>.service/.timer          (root olarak çalışır)
#
# BAŞARISIZLIK (kullanıcı kararı): bildir + kaydet, OTOMATİK TEKRAR YOK.
# srvctl-cron*.service.tpl BİLİNÇLİ OLARAK 'Restart=' KULLANMAZ (bkz. o
# şablonların başlık yorumu) — bir sonraki planlı zamanda timer zaten kendi
# kendine tekrar dener, bu YETERLİDİR. "Bildir + kaydet" burada systemd'nin
# 'OnFailure=' mekanizmasıyla uygulanır: her cron unit'i için bir DROP-IN
# ('<unit>.service.d/override.conf', BU MODÜL tarafından, TOKENS kontratlı
# ana şablonlara DOKUNMADAN üretilir) 'OnFailure=srvctl-cron(fail)-...'
# adında KÜÇÜK, KENDİMİZE AİT, statik bir bildirim unit'ine işaret eder — bu
# unit ROOT olarak çalışır (User= YOK) ve log_action + send_notification'ı
# ('lib/notify.sh', guard'lı source — CLAUDE.md deseni) tetikler. Cron
# job'unun KENDİSİ web_<sname> (izole/yetkisiz) olarak çalıştığından, log/
# bildirim işini AYRI, root'ta çalışan bir unit'e devretmek permission
# sorunlarından (srvctl.log root:root'a ait) kaçınmanın TEK temiz yoludur.
#
# ZAMAN DİLİMİ — KARAR DEĞİŞTİ (GERÇEK üretim sunucusunda ölçüldü):
#   ESKİ DAVRANIŞ (v2.0.0'a kadar): Türkçe kısayol VE 5 alanlı cron
#   sözdizimi çevirileri HER ZAMAN UTC'ye SABİTLENİYORDU (hesaplanan
#   OnCalendar'ın sonuna KOŞULSUZ ' UTC' ekleniyordu). Gerekçe "sunucunun
#   /etc/localtime ayarından bağımsız, tekrarlanabilir davranış" idi.
#
#   ÖLÇÜM (Ubuntu 24.04, canlı e-ticaret, sunucu dilimi Europe/Istanbul/+03):
#       kullanıcı yazdı  : --schedule="her gün 04:00"
#       unit'e yazıldı   : OnCalendar=*-*-* 04:00:00 UTC
#       systemd ateşledi : Sun 2026-08-02 07:00:00 +03
#   Yani gece bakımı için kurulan iş, sabah trafiğinin açıldığı saatte
#   çalıştı. Bu KOZMETİK bir sorun DEĞİL: yedek/DB-optimize/cache-warm gibi
#   ağır işlerin 3 saat kayması operasyonel bir tehlikedir.
#
#   YENİ VARSAYILAN — SUNUCU YEREL SAATİ (sonek YOK). Gerekçeler:
#     1) En az şaşırtma: operatörün YAZDIĞI saat, işin ÇALIŞACAĞI saattir.
#     2) Klasik "UTC daha güvenli çünkü DST" savunması Türkiye'de GEÇERSİZ —
#        2016'dan beri kalıcı +03, yaz saati uygulaması YOK.
#     3) Sunucu zaten Europe/Istanbul'a ayarlı; yönetici mantığı yerel saat
#        (crontab'ın da davranışı budur — crontab-parity).
#   systemd, SONEKSİZ bir OnCalendar'ı sistem yerel saatinde yorumlar.
#
#   AÇIK TERCİH: 'srvctl cron add ... --utc' verilirse ESKİ davranış birebir
#   geri gelir (' UTC' soneki yazılır) — çok sunuculu/çok bölgeli kurulumlar
#   için MEŞRU bir ihtiyaçtır, bu yüzden kaldırılmadı, AÇIK BAYRAĞA taşındı.
#
#   GERİYE DÖNÜK ETKİ — YOK (KASITLI): bu değişiklik YALNIZCA 'cron add'in
#   BUNDAN SONRA YAZACAĞI unit'leri etkiler. Diskte hâlihazırda duran
#   unit'lerin İÇİNDE AÇIK ' UTC' soneki YAZILIDIR; systemd onları AYNEN
#   yorumlamaya devam eder. HİÇBİR mevcut cron SESSİZCE KAYDIRILMAZ —
#   bu modül var olan bir cron'un zamanlamasını ASLA yeniden yazmaz. Ama
#   sessizce GÖRMEZDEN de gelinmez: 'cron list'/'cron show' her cron için
#   dilimi AÇIKÇA basar ve UTC'ye sabitlenmiş olanların YEREL karşılığını
#   ("04:00 UTC → 07:00 yerel") gösterir; 'cron list' ayrıca kaç tanesinin
#   eski varsayılanla kurulduğunu özetler (bkz. _cron_schedule_tz_note).
#
#   - Ham systemd modu ("uzman kullanımı") OLDUĞU GİBİ geçer — HİÇBİR ŞEY
#     eklenmez/değiştirilmez ('--utc' bu modda YOK SAYILIR ve bu AÇIKÇA
#     uyarılır). Dilim ifadenin İÇİNDE belirtilmemişse systemd'nin KENDİ
#     varsayılanı (sunucunun yerel saati) geçerlidir.
#
# KOMUT/ENJEKSİYON SÖZLEŞMESİ (ÇOK ÖNEMLİ — şablonların KENDİ başlık
# yorumunda da belgelenmiştir, bkz. srvctl-cron.service.tpl):
#   ExecStart={{FLOCK_PREFIX}}/bin/sh -c '{{CRON_COMMAND}}'  — yani
#   CRON_COMMAND KASITLI OLARAK bir KABUK dizgesidir (crontab satırındaki
#   komut kısmıyla AYNI semantik: '&&'/'|'/';'/yönlendirme/'$DEĞİŞKEN'
#   BEKLENİR — aksi halde crontab'tan taşınan hiçbir gerçek iş çalışmazdı).
#   '/bin/sh -c' sarmalaması şablonun KENDİSİNDE sabit.
#
#   ÜÇÜNCÜ HOST BULGUSU (GERÇEK üretim sunucusunda ölçüldü — ÖNCEKİ İKİ
#   AppArmor katmanından SONRA): 'echo tirnak testi' benzeri, TEK TIRNAK
#   İÇEREN her komut 'sh[...]: Unterminated quoted string' (status=2) ile
#   ÇÖKÜYORDU; tırnaksız komutlar (ör. 'php -v') SORUNSUZ çalışıyordu — yani
#   hata AppArmor/DAC değil, SAF bir kaçış (escaping) hatasıydı. Kök neden
#   İKİ KATLIYDI:
#     (a) systemd'nin ExecStart= AYRIŞTIRICISI bir KABUK DEĞİLDİR (systemd
#         bunu KENDİ tokenizer'ıyla, systemd.syntax(7) "Quoting" bölümünün
#         kurallarına göre parse eder) AMA "yalnız boşlukla böler" DE
#         DEĞİLDİR — tek VE çift tırnağı destekler, VE (POSIX kabuğun
#         AKSİNE) '\' ters-eğik-çizgiyi tek tırnak İÇİNDE bile bir kaçış
#         karakteri olarak işler (C-tarzı kaçış tablosu: '\\'→'\', "\\'"→
#         "'", '\"'→'"', '\s'→boşluk, ...). ESKİ kod, POSIX kabuğun
#         "' → '\''" (kapat/kaçırılmış-tırnak/aç) desenini kullanıyordu —
#         bu systemd'nin KENDİ tokenizer'ında farklı yorumlanıyor (systemd
#         '\'' içindeki '\''i "kaçırılmış tek tırnak" sanıp tırnağı
#         KAPATMIYOR), bu yüzden ÇIKTI systemd tarafında dengesiz/bozuk
#         kalıyordu.
#     (b) ESKİ tasarım flock'u KENDİ '-c' bayrağıyla çağırıyordu
#         ('flock ... -c '<komut>''  — flock'un '-c'si komutu KENDİSİ
#         '/bin/sh -c' ile çalıştırır), bu da şablonun DIŞ '/bin/sh -c'sı
#         İLE BİRLİKTE İKİ İÇ İÇE "kabuk betiği gömme" bağlamı yaratıyordu —
#         bu modül de (yanlış) POSIX kaçışını İKİ KEZ uyguluyordu. Katman
#         sayısı yanlış olmasaydı bile (a)'daki algoritma hatası TEK
#         KATMANDA DA bozuk sonuç üretirdi (bkz. tests/test_cron_add.sh /
#         test_cron_schedule.sh HOST-doğrulama testleri — GERÇEK systemd
#         tokenizer'ını taklit eder, ara bir 'sh -c "$satır"' KULLANMAZ; bir
#         ÖNCEKİ turda tam da bu ara kabuk katmanı YANLIŞ-NEGATİF üretmişti).
#
#   DÜZELTME — KATMAN SAYISI 2→1 VE DOĞRU ALGORİTMA:
#     flock artık KENDİ '-c' bayrağıyla DEĞİL, exec-form ile çağrılır:
#     'flock [-n] [-E kod] <kilit-dosyası> <komut> [argüman...]' — bu formda
#     flock HİÇBİR METNİ YENİDEN AYRIŞTIRMAZ, kendisine VERİLEN argv'yi
#     OLDUĞU GİBİ execve() eder (fork+exec+wait, exit kodunu devralır). Bu,
#     flock'un KENDİ iç kabuk çağrısını TAMAMEN ORTADAN KALDIRIR — geriye
#     TEK bir "metni bir kabuk bağlamına göm" noktası kalır: şablonun dış
#     '/bin/sh -c '{{CRON_COMMAND}}''. FLOCK_PREFIX token'ı (_cron_add
#     tarafından üretilir) ya boş dizgedir (sistem cron'u VEYA flock
#     yoksa — satır doğrudan '/bin/sh' ile başlar) ya da
#     "/usr/bin/flock -n -E 75 '<kaçırılmış-kilit-yolu>' " (sondaki BOŞLUK
#     KASITLI — '/bin/sh'den ÖNCE ayraç).
#
#   render_template (core.sh) yalnız satırsonu/CR'yi reddeder; tek/çift
#   tırnak, '$', backtick gibi kabuk metakarakterlerini KAÇIRMAZ (bilerek —
#   genel bir string-replace katmanıdır). Bu yüzden kaçış TAMAMEN BU MODÜLE
#   (aşağıdaki _cron_escape_* fonksiyonları) YÜKLENİR:
#     1) _cron_escape_unit_squote: CRON_COMMAND (VE FLOCK_PREFIX'in İÇİNDEKİ
#        kilit yolu) şablonda TEK TIRNAK içine yerleştirildiğinden
#        (ExecStart=...'/bin/sh -c '...''), ham metin systemd'nin KENDİ
#        C-tarzı kaçış kurallarına göre kaçırılmak ZORUNDADIR: ÖNCE HER '\'
#        → '\\' (aksi halde systemd, SONRAKİ karakteri KENDİ kaçış
#        tablosuna göre yanlış yorumlar), SONRA HER "'" → "\'" (systemd'nin
#        TEK bilinen tek-tırnak kaçışı — POSIX'in "'\''" deseni SYSTEMD'DE
#        ÇALIŞMAZ, yukarıdaki HOST bulgusu). Sıra ÖNEMLİDİR: ters-eğik-çizgi
#        ÖNCE kaçırılmazsa, ikinci adımda ÜRETİLEN yeni '\' karakterleri
#        YANLIŞLIKLA tekrar işlenirdi.
#     2) '%' İKİLEMESİ (_cron_escape_percent): systemd, kabuğu görmeden ÖNCE
#        ExecStart= (VE Description=) satırının TAMAMINDA KENDİ '%'
#        specifier genişletmesini yapar (ör. '%h','%i') — ham komutta/
#        açıklamada literal '%' varsa BU MODÜL onu '%%' olarak İKİLEMEK
#        ZORUNDADIR. Bu adım tek-tırnak kaçışından SONRA uygulanır (1)
#        hiçbir '\'/"'" üretmez/tüketmez, (2) hiçbir '%' üretmez/tüketmez —
#        bu yüzden sıralama güvenlidir/commütatiftir).
#   Her iki adım da _cron_add()'de UYGULANIR (bkz. o fonksiyonun "Kabuk
#   sarmalama + kaçış" bölümü) — CRON_COMMAND ve (varsa) kilit yolu HER
#   BİRİ KENDİ tek-tırnak span'i İÇİN AYRI AYRI, ama TEK KEZ kaçırılır.
#
# DEPLOY KİLİDİ (görev talebi — deploy sürerken domain cron'u ÇALIŞMAMALI):
#   lib/deploy.sh:_deploy_lock 'flock -n 9' ile ${SRVCTL_LOCK_DIR:-/run/srvctl}/
#   locks/<sname>/deploy-<sname>.lock dosyasını kilitler. Bu modül AYNI kilit
#   dosyasını KARŞI taraftan kullanır: ExecStart, FLOCK_PREFIX ile
#   'flock -n -E 75 '<kilit-dosyası>' /bin/sh -c '<komut>'' ŞEKLİNDE
#   SARMALANIR — kilit deploy tarafından TUTULUYORSA flock komutu HİÇ
#   ÇALIŞTIRMADAN 75 (sysexits.h EX_TEMPFAIL — "geçici, yeniden dene") ile
#   çıkar. '_on-failure' handler'ı bu KODU ÖZEL OLARAK tanır: log_action ile
#   KAYDEDER ama send_notification ÇAĞIRMAZ (bu bir GERÇEK başarısızlık
#   DEĞİL, beklenen bir atlama — deploy sırasında HER dakika bildirim
#   spam'i istenmez). Bir SONRAKİ planlı tetiklemede (deploy muhtemelen
#   bitmiş olacağından) normal şekilde tekrar dener — 'otomatik tekrar YOK'
#   kuralına AYKIRI DEĞİLDİR (bu, systemd timer'ın zaten planlanmış BİR
#   SONRAKİ çalışmasıdır, ekstra bir retry DEĞİL). 'flock' yoksa (çok
#   minimal bir imaj) bu koruma ATLANIR (FLOCK_PREFIX boş kalır) ve operatör
#   'cron add' sırasında AÇIKÇA uyarılır (lib/deploy.sh ile AYNI
#   graceful-degrade deseni). Sistem cron'ları ('--system') bir domain'e
#   bağlı OLMADIĞINDAN bu sarmalamayı HİÇ ALMAZ (FLOCK_PREFIX her zaman
#   boştur).
#
#   DAC/root ÇELİŞKİSİ DÜZELTMESİ (GERÇEK üretim sunucusunda ölçüldü —
#   AppArmor'a hiç sıra gelmeden 'flock: cannot open lock file ...:
#   Permission denied', çıkış 66): kilit dizini ESKİDEN düz
#   '${SRVCTL_LOCK_DIR:-/run/srvctl}/deploy-<sname>.lock' ve 700 root:root
#   idi — bu, root olarak çalışan _deploy_lock İÇİN doğruydu ama bu cron
#   job'u User=web_<sname> olarak çalıştığından o dizine hiç GİREMİYORDU.
#   Şimdi kilit domain BAŞINA ayrı bir alt dizinde
#   ('${SRVCTL_LOCK_DIR:-/run/srvctl}/locks/<sname>/', 710, sahibi
#   root:web_<sname>) yaşıyor — bkz. _cron_lock_dir (bu dosyada) /
#   _deploy_lock_dir (lib/deploy.sh) / core.sh:_srvctl_lock_ensure yorumu.
#   Üst dizinler (711) yalnız GEÇİŞE izin verir, domain'in KENDİ alt dizini
#   ise BAŞKA hiçbir domain kullanıcısına AÇIK DEĞİLDİR — domainler arası
#   izolasyon KORUNUR.
#
#   ⚠ SAHİPLİK DÜZELTMESİ (KRİTİK, sonraki tur): alt dizin ÖNCE '700
#   web_<sname>:web_<sname>' idi; SAHİBİ domain kullanıcısı olduğu için o
#   kullanıcı kilit dosyasını SİLİP yerine sembolik bağ koyabiliyordu ve
#   root olarak çalışan _deploy_lock bunu dereference edip KEYFİ bir dosyayı
#   chown/truncate ediyordu (canlı üretimde kanıtlandı). Artık '710
#   root:web_<sname>' — geçiş VAR, yazma YOK; kilit dosyası '660
#   root:web_<sname>' olarak ROOT tarafından ÖN-OLUŞTURULUR (flock(1)'ün
#   O_CREAT'ı artık dosyayı yaratamaz, bu yüzden ön-oluşturma ZORUNLUDUR).
#
# YAZMA İZNİ (ProtectSystem=strict + ReadWritePaths=): domain cron'u
# WORKING_DIR (WEB_ROOT/<domain>/current) DEĞİL, DOMAIN_ROOT'un TAMAMINA
# (WEB_ROOT/<domain> — current/releases/shared/logs/tmp/sessions HEPSİ)
# yazabilir — worker/scheduler İLE AYNI desen (bkz. srvctl-cron.service.tpl
# başlık yorumu). İLK sürümde yalnız WORKING_DIR kullanılıyordu ve bu,
# 'writable/'/'storage/' gibi KARDEŞ dizinlere yazan HER TİPİK cron işini
# (cache temizliği, log rotasyonu) EROFS ile kırıyordu — TOKENS kontratı
# DOMAIN_ROOT eklenerek genişletildi, bu modül şimdi her domain cron
# render'ında besliyor.
#
# CATCH-UP-ON-BOOT (Persistent=): sunucu kapalıyken kaçan bir çalışmanın
# açılışta telafi edilip edilmeyeceği (systemd 'Persistent=') SABİT bir
# değer OLAMAZ — bir cache temizliği için 'false' (kaçırılırsa zararsız,
# tekrar SÜRPRİZ olur) doğruyken, gecelik bir yedekleme için 'true'
# (kaçırılırsa VERİ KAYBI riski) doğrudur; ikisi TAM TERS varsayılan ister.
# Karar operatöre bırakılır: 'srvctl cron add ... --catch-up-on-boot'
# vermeden varsayılan 'false' (crontab-parity, en az sürpriz); bayrak
# verilirse 'true'. 'cron add' hangi davranışın seçildiğini AÇIKÇA bildirir.
#
# PHP SÜRÜMÜ: komut 'php' ile (sürüm eki OLMADAN) başlıyorsa systemd bunu
# $PATH'te arar — bu, domain'in yapılandırılmış PHP sürümüyle AYNI OLMAYABİLİR
# (bu oturumda composer'ın host PHP'siyle çalışması TAM BU SINIF bir hataydı).
# 'cron add' bunu domain kapsamında AÇIKÇA uyarır (engellemez — yalnız uyarır).
set -uo pipefail 2>/dev/null || true

# ─── Varsayılanlar (env ile override edilebilir — test-seam) ───
CRON_DEFAULT_TIMEOUT="${CRON_DEFAULT_TIMEOUT:-3600}"                 # RUNTIME_MAX varsayılanı (sn)
CRON_DEFAULT_RANDOMIZED_DELAY="${CRON_DEFAULT_RANDOMIZED_DELAY:-30}" # RANDOMIZED_DELAY varsayılanı (sn)

# 'cron list' sırasında görülen, UTC'ye SABİTLENMİŞ (eski varsayılanla ya da
# '--utc' ile kurulmuş) cron sayacı. BURADA da tanımlanır ki _cron_print_row
# '_cron_list' DIŞINDAN çağrıldığında 'set -u' altında ölmesin.
_CRON_UTC_SEEN=0

# ═══════════════════════════════════════════════
#  GİRİŞ NOKTASI
# ═══════════════════════════════════════════════
cmd_cron() {
    case "${1:-help}" in
        add)         require_root; _cron_add "${@:2}" ;;
        list)        _cron_list "${@:2}" ;;
        show)        _cron_show "${@:2}" ;;
        run)         require_root; _cron_run "${@:2}" ;;
        enable)      require_root; _cron_set_enabled true "${@:2}" ;;
        disable)     require_root; _cron_set_enabled false "${@:2}" ;;
        remove)      require_root; _cron_remove "${@:2}" ;;
        logs)        _cron_logs "${@:2}" ;;
        # Dahili — YALNIZ 'OnFailure=' drop-in'i tarafından çağrılır, elle
        # çalıştırılmak İÇİN DEĞİLDİR (bkz. _cron_write_failure_hook).
        # Bilinçli olarak help metninde/completions'ta LİSTELENMEZ.
        _on-failure) _cron_on_failure "${@:2}" ;;
        *)
            _cron_help
            ;;
    esac
}

_cron_help() {
    echo ""
    echo -e "  ${BOLD}srvctl cron${NC} — kullanıcı dostu cron (arka planda systemd timer)"
    echo ""
    echo "  Kullanım:"
    echo "    srvctl cron add <domain>|--system --name=<ad> --schedule=<zaman> \\"
    echo "        --command=<komut> [--description=<açıklama>] [--timeout=<sn>] \\"
    echo "        [--catch-up-on-boot] [--utc]"
    echo "    srvctl cron list [<domain>|--system]"
    echo "    srvctl cron show <domain>|--system <ad>"
    echo "    srvctl cron run <domain>|--system <ad>          (şimdi bir kez çalıştır — test)"
    echo "    srvctl cron enable|disable <domain>|--system <ad>"
    echo "    srvctl cron remove <domain>|--system <ad>"
    echo "    srvctl cron logs <domain>|--system <ad> [-n N]"
    echo ""
    echo "  --schedule üç biçimi kabul eder:"
    echo "    1) Türkçe kısayol (küçük harf yazılmalı):"
    echo "         'her gün SS:DD'            (ör. 'her gün 03:00')"
    echo "         'her N dakikada'           (ör. 'her 15 dakikada')"
    echo "         'her saat'"
    echo "         'her <gün> SS:DD'          (pazartesi/salı/çarşamba/perşembe/cuma/cumartesi/pazar)"
    echo "         'ayın N'i SS:DD'           (ör. \"ayın 1'i 02:00\")"
    echo "         'hafta içi SS:DD'          (pazartesi-cuma)"
    echo "    2) Standart 5 alanlı cron sözdizimi: 'dakika saat ayın_günü ay haftanın_günü'"
    echo "         (ör. '0 3 * * *') — 'ayın_günü' VE 'haftanın_günü' AYNI ANDA"
    echo "         kısıtlanamaz (birini '*' bırakın)."
    echo "    3) Ham systemd takvim ifadesi (uzman kullanımı, ör. '*-*-01 02:00:00')"
    echo ""
    echo "  ZAMAN DİLİMİ — varsayılan SUNUCUNUN YEREL SAATİ: yazdığınız saat, işin"
    echo "  çalışacağı saattir ('her gün 04:00' → sunucuda 04:00). 1 ve 2. biçimlerde"
    echo "  OnCalendar'a HİÇBİR dilim soneki eklenmez; systemd soneksiz ifadeyi sistem"
    echo "  yerel saatinde yorumlar. Ham modda (3) dilim ifadenin İÇİNDE belirtilmemişse"
    echo "  yine sunucunun yerel saati geçerlidir — 'cron add' bunu uyarır."
    echo ""
    echo "  --utc: zamanlamayı UTC'ye SABİTLER (OnCalendar sonuna ' UTC' yazılır). Çok"
    echo "  sunuculu/çok bölgeli kurulumlarda tüm sunucuları AYNI mutlak anda tetiklemek"
    echo "  için kullanın. Ham modda (3) YOK SAYILIR (uyarılır) — orada dilimi ifadenin"
    echo "  içine kendiniz yazarsınız."
    echo ""
    echo "  NOT (davranış değişikliği): srvctl 2.0.0'a kadar 1 ve 2. biçimler HER ZAMAN"
    echo "  UTC'ye sabitleniyordu. Diskte duran ESKİ cron'lar DEĞİŞTİRİLMEDİ (unit"
    echo "  dosyalarındaki açık ' UTC' soneki korunur); 'cron list'/'cron show' onları"
    echo "  AÇIKÇA işaretler ve yerel karşılıklarını gösterir."
    echo ""
    echo "  --catch-up-on-boot: sunucu kapalıyken kaçan bir çalışma AÇILIŞTA telafi"
    echo "  edilsin mi (systemd Persistent=)? Varsayılan HAYIR (crontab-parity, en az"
    echo "  sürpriz). Yedekleme gibi 'mutlaka çalışmalı' işler için bu bayrağı verin."
    echo ""
    echo "  KOMUT ÖN-DOĞRULAMASI (domain kapsamı): 'cron add', komuttaki çalıştırılabilir"
    echo "  adayları domain'in AppArmor profili ('srvctl-<safe>-cli') altında EKLEME"
    echo "  ANINDA gerçekten çalıştırmayı dener. Profil bir ikiliyi engelliyorsa (çıkış"
    echo "  kodu 126) cron EKLENMEZ — ilk planlı çalışmada sessizce düşmesi yerine hata"
    echo "  hemen verilir. Kabuk builtin'leri (echo, printf, cd, test ...) hiç exec"
    echo "  edilmediğinden denetlenmez; değişken/tırnak içeren parçalar çözülemez ve"
    echo "  'denetlenmedi' olarak bildirilir. Prob çalıştırılamıyorsa (aa-exec yok,"
    echo "  AppArmor kapalı, profil yüklü değil, root değilsiniz) ekleme ENGELLENMEZ,"
    echo "  yalnız uyarı basılır."
    echo ""
    echo "  Çıkış kodu teşhisi: 126 = izin reddedildi (çoğunlukla AppArmor profili bir"
    echo "  ikiliyi engelliyor), 127 = komut bulunamadı, 75 = deploy kilidi meşguldü"
    echo "  (atlandı, gerçek hata değil). 'cron run/list/show/logs' bu açıklamayı basar."
    echo ""
}

# ═══════════════════════════════════════════════
#  SAF ZAMANLAMA ÇEVİRİCİLERİ (girdi→çıktı, yan etkisiz — kapsamlı test edilir)
# ═══════════════════════════════════════════════

# Türkçe gün adı → systemd haftanın-günü kısaltması. PREDİKAT değil, ÜRETİCİ:
# başarıda stdout'a yazar (0), tanınmayan girdide 1 döner (stdout boş).
_cron_tr_daynum() {
    case "$1" in
        pazartesi)     echo "Mon" ;;
        sali|salı)     echo "Tue" ;;
        carsamba|çarşamba) echo "Wed" ;;
        persembe|perşembe) echo "Thu" ;;
        cuma)          echo "Fri" ;;
        cumartesi)     echo "Sat" ;;
        pazar)         echo "Sun" ;;
        *) return 1 ;;
    esac
}

# Cron alanı 0-7 (0 VE 7 = Pazar) → systemd gün adı.
_cron_dow_name() {
    case "$1" in
        0|7) echo "Sun" ;;
        1)   echo "Mon" ;;
        2)   echo "Tue" ;;
        3)   echo "Wed" ;;
        4)   echo "Thu" ;;
        5)   echo "Fri" ;;
        6)   echo "Sat" ;;
        *) return 1 ;;
    esac
}

# "SS:DD" → doğrulanmış, 2 haneye tamamlanmış "SS DD" (read ile parse edilir).
# 10# öneki: '08'/'09' gibi girdilerin sekizlik sanılmasını ÖNLER (core.sh:
# validate_http_code İLE AYNI gerekçe).
_cron_hhmm_parts() {
    local t="$1"
    [[ "$t" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]] || return 1
    local hh="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}"
    (( 10#$hh <= 23 )) || return 1
    (( 10#$mm <= 59 )) || return 1
    printf '%02d %02d' "$((10#$hh))" "$((10#$mm))"
}

# Türkçe kısayolu systemd takvim GÖVDESİNE (henüz 'UTC' EKLENMEMİŞ) çevirir.
# Girdi kelimelere bölünerek (bash IFS word-splitting) işlenir — Türkçe'ye
# özgü harfleri (ç/ğ/ı/ö/ş/ü) İÇEREN sabit anahtar kelimeler ('ayın', 'içi')
# yalnız '==' İLE (glob/regex DEĞİL) karşılaştırılır: bash '[[ == ]]' salt
# BAYT-düzeyinde literal karşılaştırma yapar, UTF-8 karakter sınıfı/locale
# belirsizliğine BAĞIMLI DEĞİLDİR (bir regex karakter sınıfının aksine).
# Başarıda stdout'a gövdeyi yazar (0), tanınmayan/geçersiz girdide 1 döner
# (stdout boş).
_cron_translate_turkish() {
    local input="$1"
    local -a w
    read -ra w <<< "$input"
    local n="${#w[@]}"
    local hhmm hh mm

    # (1) "her gün SS:DD"
    if (( n == 3 )) && [[ "${w[0]}" == "her" && "${w[1]}" == "gün" ]]; then
        hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
        read -r hh mm <<< "$hhmm"
        printf '*-*-* %s:%s:00' "$hh" "$mm"
        return 0
    fi

    # (2) "her N dakikada"
    if (( n == 3 )) && [[ "${w[0]}" == "her" && "${w[2]}" == "dakikada" && "${w[1]}" =~ ^[0-9]+$ ]]; then
        local step="$((10#${w[1]}))"
        (( step >= 1 && step <= 59 )) || return 1
        printf '*-*-* *:0/%d:00' "$step"
        return 0
    fi

    # (3) "her saat"
    if (( n == 2 )) && [[ "${w[0]}" == "her" && "${w[1]}" == "saat" ]]; then
        printf '*-*-* *:00:00'
        return 0
    fi

    # (4) "her <gün> SS:DD"
    if (( n == 3 )) && [[ "${w[0]}" == "her" ]]; then
        local dname
        if dname=$(_cron_tr_daynum "${w[1]}"); then
            hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
            read -r hh mm <<< "$hhmm"
            printf '%s *-*-* %s:%s:00' "$dname" "$hh" "$mm"
            return 0
        fi
    fi

    # (5) "ayın N'i SS:DD" (Türkçe iyelik eki serbest — yalnız baştaki
    # rakamlar okunur: '1'i'/'2'si'/'3'ü'/düz '1' hepsi kabul edilir).
    if (( n == 3 )) && [[ "${w[0]}" == "ayın" || "${w[0]}" == "ayin" ]]; then
        [[ "${w[1]}" =~ ^([0-9]{1,2}) ]] || return 1
        local daynum="$((10#${BASH_REMATCH[1]}))"
        (( daynum >= 1 && daynum <= 31 )) || return 1
        hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
        read -r hh mm <<< "$hhmm"
        printf '*-*-%02d %s:%s:00' "$daynum" "$hh" "$mm"
        return 0
    fi

    # (6) "hafta içi SS:DD" (Pazartesi-Cuma)
    if (( n == 3 )) && [[ "${w[0]}" == "hafta" ]] && [[ "${w[1]}" == "içi" || "${w[1]}" == "ici" ]]; then
        hhmm=$(_cron_hhmm_parts "${w[2]}") || return 1
        read -r hh mm <<< "$hhmm"
        printf 'Mon..Fri *-*-* %s:%s:00' "$hh" "$mm"
        return 0
    fi

    return 1
}

# Girdi tam olarak 5 boşlukla ayrılmış alan mı? (PREDİKAT — cron sözdizimine
# 'BENZİYOR mu' sorusuna cevap verir; alanların İÇERİĞİNİ doğrulamaz).
_cron_looks_like_cron5() {
    local -a f
    read -ra f <<< "$1"
    (( ${#f[@]} == 5 ))
}

# Tek bir cron alanını systemd takvim söz dizimine çevirir.
# kind: 'num' (düz sayı — dakika/saat/ayın_günü/ay) | 'dow' (haftanın günü,
# 0-7 → Mon..Sun). Desteklenen alt küme (BİLİNÇLİ SINIRLAMA — bkz. dosya
# başı yorumu, 'a-b/N' birleşik biçimi desteklenmez, reddedilir):
#   '*' | 'N' | 'N,M,...' | 'a-b' | '*/N' (yalnız kind=num).
_cron_field_translate() {
    local field="$1" min="$2" max="$3" kind="$4"
    [[ -n "$field" ]] || return 1

    if [[ "$field" == "*" ]]; then
        printf '*'
        return 0
    fi

    if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
        [[ "$kind" == "dow" ]] && return 1
        local step="$((10#${BASH_REMATCH[1]}))"
        (( step >= 1 && step <= max )) || return 1
        printf '*/%d' "$step"
        return 0
    fi

    if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="$((10#${BASH_REMATCH[1]}))" b="$((10#${BASH_REMATCH[2]}))"
        (( a >= min && a <= max )) || return 1
        (( b >= min && b <= max )) || return 1
        (( a <= b )) || return 1
        if [[ "$kind" == "dow" ]]; then
            local an bn
            an=$(_cron_dow_name "$a") || return 1
            bn=$(_cron_dow_name "$b") || return 1
            printf '%s..%s' "$an" "$bn"
        else
            printf '%02d..%02d' "$a" "$b"
        fi
        return 0
    fi

    # Tek sayı da bu dalın özel bir hâlidir (sıfır virgüllü liste).
    if [[ "$field" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        local -a items
        IFS=',' read -ra items <<< "$field"
        local out="" it v dn
        for it in "${items[@]}"; do
            [[ "$it" =~ ^[0-9]+$ ]] || return 1
            v="$((10#$it))"
            (( v >= min && v <= max )) || return 1
            if [[ "$kind" == "dow" ]]; then
                dn=$(_cron_dow_name "$v") || return 1
                out="${out:+${out},}${dn}"
            else
                out="${out:+${out},}$(printf '%02d' "$v")"
            fi
        done
        printf '%s' "$out"
        return 0
    fi

    return 1
}

# Standart 5 alanlı cron ifadesini systemd takvim GÖVDESİNE çevirir (henüz
# 'UTC' EKLENMEMİŞ). BİLİNÇLİ SINIRLAMA: POSIX cron'da 'ayın_günü' VE
# 'haftanın_günü' AYNI ANDA kısıtlanırsa anlam "YA DA" (OR) olur — systemd
# OnCalendar bunu TEK SATIRDA ifade EDEMEZ (her zaman AND) ve render_template
# newline/CR'yi reddettiğinden (ON_CALENDAR TEK bir token) birden fazla
# 'OnCalendar=' satırı da bu sözleşmede MÜMKÜN DEĞİL. Bu kombinasyon
# YANLIŞ yorumlamaktansa NET biçimde REDDEDİLİR.
_cron_translate_cron5() {
    local input="$1"
    _cron_looks_like_cron5 "$input" || return 1
    local -a f
    read -ra f <<< "$input"

    if [[ "${f[2]}" != "*" && "${f[4]}" != "*" ]]; then
        return 1
    fi

    local min_t hour_t dom_t month_t dow_t
    min_t=$(_cron_field_translate "${f[0]}" 0 59 num)   || return 1
    hour_t=$(_cron_field_translate "${f[1]}" 0 23 num)  || return 1
    dom_t=$(_cron_field_translate "${f[2]}" 1 31 num)   || return 1
    month_t=$(_cron_field_translate "${f[3]}" 1 12 num) || return 1
    dow_t=$(_cron_field_translate "${f[4]}" 0 7 dow)    || return 1

    local prefix=""
    [[ "${f[4]}" != "*" ]] && prefix="${dow_t} "
    printf '%s*-%s-%s %s:%s:00' "$prefix" "$month_t" "$dom_t" "$hour_t" "$min_t"
}

# Ham systemd takvim ifadesi için İZİN VERİLEN karakter kümesi (PREDİKAT).
# Amaç sözdizimini DOĞRULAMAK DEĞİL (bu iş 'systemd-analyze calendar'a
# bırakılır, bkz. _cron_add) — unit dosyası satırını KIRABİLECEK/render_
# template'in newline/CR reddiyle BİRLİKTE tek-satır bütünlüğünü tehlikeye
# atabilecek karakterleri (= { } [ ] ; tırnak ters-eğik-çizgi $ vb.) baştan
# elemektir. IANA dilim adları ('Europe/Istanbul') ve systemd'nin '~' (ayın
# son günü) sözdizimi İÇİN gerekli karakterler BİLİNÇLİ OLARAK dahildir.
_cron_calendar_charset_ok() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    # Regex bir DEĞİŞKENDE tutulur (core.sh:assert_regex_safe İLE AYNI
    # desen) — '[[ =~ ]]' RHS'i tırnaksız yazılırsa bazı karakter sınıfı
    # bileşimlerinde ('~ -' gibi) bash'in KENDİ ayrıştırıcısı "syntax error
    # in conditional expression" verebiliyor; değişken dolaylılığı bunu
    # tamamen ortadan kaldırır.
    local re='^[A-Za-z0-9*:,./_+~ -]+$'
    [[ "$v" =~ $re ]]
}

# ═══════════════════════════════════════════════
#  SAAT DİLİMİ — TESPİT (yetenek tabanlı) + SAF DÖNÜŞTÜRÜCÜLER
# ═══════════════════════════════════════════════
# Varsayılan artık SUNUCU YEREL SAATİ (bkz. dosya başı "ZAMAN DİLİMİ" bloğu),
# bu yüzden 'cron add/list/show' sunucunun dilimini GERÇEKTEN bilmek ve
# operatöre BASMAK zorundadır — "sanırım yereldir" demek yetmez.
#
# YETENEK TESPİTİ > SÜRÜM KARŞILAŞTIRMASI (CLAUDE.md dual-LTS kuralı):
# 'timedatectl' 22.04'te de 24.04'te de vardır ama bir konteynerde/minimal
# imajda OLMAYABİLİR; bu yüzden sırayla timedatectl → /etc/timezone →
# /etc/localtime symlink'i denenir ve HİÇBİRİ yoksa BOŞ dönülür ("bilinmiyor"
# basılır — UYDURMA YOK). macOS geliştirme makinesinde 'timedatectl' HİÇ
# YOKTUR: bu zincir orada da ÇÖKMEDEN boş/None sonuç üretir.
#
# TEST TOHUMU (projenin SRVCTL_*_DIR deseniyle aynı): 'SRVCTL_TIMEZONE'
# verilirse tespit HİÇ ÇALIŞTIRILMAZ, o değer kullanılır — testler böylece
# GERÇEK 'timedatectl' olmadan hem "+03" hem "UTC" senaryosunu kurabilir.
_cron_server_timezone() {
    local tz="${SRVCTL_TIMEZONE:-}"
    if [[ -z "$tz" ]] && command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null) || tz=""
    fi
    if [[ -z "$tz" && -r /etc/timezone ]]; then
        tz=$(head -n1 /etc/timezone 2>/dev/null) || tz=""
    fi
    if [[ -z "$tz" && -L /etc/localtime ]]; then
        local link=""
        link=$(readlink /etc/localtime 2>/dev/null) || link=""
        case "$link" in
            */zoneinfo/*) tz="${link#*/zoneinfo/}" ;;
        esac
    fi
    # IANA dilim adı karakter kümesi — dışında bir şey gelirse GÜVENME (bu
    # değer hem ekrana basılır hem 'TZ=' ortam değişkenine konur).
    local re='^[A-Za-z0-9_/+.-]+$'
    [[ "$tz" =~ $re ]] || tz=""
    printf '%s' "$tz"
}

# '+0300' / '+03:00' / '-0430' → dakika (180 / 180 / -270). SAF fonksiyon;
# tanınmayan girdide 1 döner (stdout boş) — hesap yapılamayınca ekranda
# "bilinmiyor" görünür, YANLIŞ bir saat ASLA uydurulmaz.
_cron_parse_offset_minutes() {
    local v="${1:-}"
    local re='^([+-])([0-9]{2}):?([0-9]{2})$'
    [[ "$v" =~ $re ]] || return 1
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
    local total=$(( 10#$hh * 60 + 10#$mm ))
    if [[ "$sign" == "-" ]]; then total=$(( -total )); fi
    printf '%s' "$total"
}

# Dakika → insan okunur ofset etiketi (180 → '+03:00', -270 → '-04:30'). SAF.
_cron_offset_label() {
    local m="${1:-}"
    local re='^-?[0-9]+$'
    [[ "$m" =~ $re ]] || return 1
    local sign="+"
    if (( m < 0 )); then sign="-"; m=$(( -m )); fi
    printf '%s%02d:%02d' "$sign" "$(( m / 60 ))" "$(( m % 60 ))"
}

# Sunucunun ŞU ANKİ UTC ofseti (dakika). Dilim adı biliniyorsa onun üzerinden
# ('TZ=<ad> date +%z' — GNU VE BSD date'in İKİSİ DE bu ortam değişkenini
# onurlandırır, macOS'ta da çalışır), bilinmiyorsa süreç dilimiyle hesaplanır.
# DÜRÜSTLÜK NOTU: bu ANLIK ofsettir. Yaz saati uygulayan bir dilimde yılın
# diğer yarısında DEĞİŞİR — hedef ortam (Türkiye) 2016'dan beri kalıcı +03
# olduğundan pratikte sabittir, ama gösterim metinleri bunu "şu an" diye
# değil, dilim ADIYLA BİRLİKTE basar ki operatör kaynağı görebilsin.
_cron_tz_offset_minutes() {
    local tz z=""
    tz=$(_cron_server_timezone)
    if [[ -n "$tz" ]]; then
        z=$(TZ="$tz" date +%z 2>/dev/null) || z=""
    fi
    if [[ -z "$z" ]]; then
        z=$(date +%z 2>/dev/null) || z=""
    fi
    _cron_parse_offset_minutes "$z" || printf ''
}

# "Europe/Istanbul, UTC+03:00" — tek satırlık, ekrana basılabilir dilim
# etiketi. İkisinden biri bilinmiyorsa bilinen kısmı, hiçbiri bilinmiyorsa
# 'bilinmiyor' basar.
_cron_tz_display() {
    local name off lbl="" ol=""
    name=$(_cron_server_timezone)
    off=$(_cron_tz_offset_minutes)
    # '|| ol=""' KASITLI: _cron_offset_label tanınmayan girdide 1 döner ve
    # çıplak bir 'ol=$(...)' ataması errexit altında çağıranı ÖLDÜRÜRDÜ.
    if [[ -n "$off" ]]; then
        ol=$(_cron_offset_label "$off") || ol=""
        [[ -z "$ol" ]] || lbl="UTC${ol}"
    fi
    if [[ -n "$name" && -n "$lbl" ]]; then
        printf '%s, %s' "$name" "$lbl"
    elif [[ -n "$name" ]]; then
        printf '%s' "$name"
    elif [[ -n "$lbl" ]]; then
        printf '%s' "$lbl"
    else
        printf 'bilinmiyor'
    fi
}

# Bir OnCalendar ifadesindeki AÇIK zaman dilimi sonekini döner ('UTC' ya da
# IANA adı), yoksa boş. SAF fonksiyon, HER ZAMAN 0 döner.
# TUZAK: son kelimeye bakmak TEK BAŞINA yetmez — '*-*-* *:0/15:00' (her 15
# dakikada) ifadesinin son kelimesi de '/' İÇERİR. Bu yüzden IANA adı için
# '*' / ':' İÇERMEYEN VE EN AZ BİR '/' bileşeni olan katı bir desen aranır;
# 'UTC' ise literal olarak karşılaştırılır.
_cron_calendar_tz_suffix() {
    local cal="${1:-}" last
    last="${cal##* }"
    [[ "$last" != "$cal" ]] || return 0   # tek kelime → sonek YOK
    if [[ "$last" == "UTC" ]]; then
        printf 'UTC'
        return 0
    fi
    local re='^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)+$'
    if [[ "$last" =~ $re ]]; then
        printf '%s' "$last"
    fi
    return 0
}

# OnCalendar ifadesinin dilim soneki ÇIKARILMIŞ gövdesi. SAF.
_cron_calendar_body() {
    local cal="${1:-}" sfx
    sfx=$(_cron_calendar_tz_suffix "$cal")
    if [[ -n "$sfx" ]]; then
        printf '%s' "${cal% "$sfx"}"
    else
        printf '%s' "$cal"
    fi
}

# OnCalendar gövdesindeki SABİT saat:dakika (varsa) → 'SS:DD'. SAF.
# Saat ya da dakika alanı JOKER/ADIM/LİSTE içeriyorsa (ör. '*:0/15:00',
# '*:00:00') BOŞ döner: "her 15 dakikada" bir işin "yerel karşılığı" diye
# tek bir saat basmak YANLIŞ olurdu — bilinmeyeni uydurma ilkesi.
_cron_calendar_fixed_hhmm() {
    local cal="${1:-}" body last
    body=$(_cron_calendar_body "$cal")
    last="${body##* }"
    local re='^([0-9]{1,2}):([0-9]{1,2})(:[0-9]{1,2})?$'
    [[ "$last" =~ $re ]] || return 0
    local hh="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}"
    (( 10#$hh <= 23 )) || return 0
    (( 10#$mm <= 59 )) || return 0
    printf '%02d:%02d' "$((10#$hh))" "$((10#$mm))"
}

# 'SS:DD' + ofset(dakika) → 'SS:DD' (gün taşması NOTLA belirtilir). SAF.
# Ofset ±14 saatle sınırlı olduğundan taşma en fazla BİR gündür.
_cron_shift_hhmm() {
    local hhmm="${1:-}" off="${2:-}"
    local re_t='^([0-9]{1,2}):([0-9]{1,2})$'
    local re_o='^-?[0-9]+$'
    [[ "$hhmm" =~ $re_t ]] || return 1
    # TUZAK: BASH_REMATCH bir SONRAKİ '[[ =~ ]]' ile EZİLİR (ve ofset regex'i
    # yakalama grubu içermediğinden [1]/[2] TANIMSIZ kalıp 'set -u' altında
    # scripti öldürürdü) — bu yüzden değerler ofset kontrolünden ÖNCE, ilk
    # eşleşmenin HEMEN ardından kopyalanır.
    local hh="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}"
    [[ "$off" =~ $re_o ]] || return 1
    local total=$(( 10#$hh * 60 + 10#$mm + off ))
    local day=0
    while (( total < 0 ));     do total=$(( total + 1440 )); day=$(( day - 1 )); done
    while (( total >= 1440 )); do total=$(( total - 1440 )); day=$(( day + 1 )); done
    local note=""
    if   (( day > 0 )); then note=" (ertesi gün)"
    elif (( day < 0 )); then note=" (bir önceki gün)"
    fi
    printf '%02d:%02d%s' "$(( total / 60 ))" "$(( total % 60 ))" "$note"
}

# ─── GÖRÜNTÜLEME: bir OnCalendar ifadesinin dilimi ASLA belirsiz kalmaz ───
# 'cron list' ve 'cron show' bu TEK kaynağı kullanır. Üç durum:
#   (a) sonek YOK       → sunucu yerel saati (YENİ varsayılan)
#   (b) sonek 'UTC'     → ESKİ varsayılanla kurulmuş cron: yerel KARŞILIĞI
#                         hesaplanıp AÇIKÇA gösterilir (operatör 3 saatlik
#                         farkı GÖRSÜN — sessiz kaymanın panzehiri)
#   (c) sonek IANA adı  → operatörün ham modda kendi yazdığı dilim
# HER ZAMAN 0 döner (çağıranın 'set -e' altında guard yazması gerekmesin).
_cron_schedule_tz_note() {
    local cal="${1:-}"
    [[ -n "$cal" ]] || { printf 'bilinmiyor'; return 0; }

    local sfx tzdisp
    sfx=$(_cron_calendar_tz_suffix "$cal")
    tzdisp=$(_cron_tz_display)

    if [[ -z "$sfx" ]]; then
        printf 'sunucu yerel saati (%s)' "$tzdisp"
        return 0
    fi
    if [[ "$sfx" != "UTC" ]]; then
        printf 'ifadede sabitlenmiş dilim: %s — sunucu yerel saati: %s' "$sfx" "$tzdisp"
        return 0
    fi

    local off hhmm local_hhmm
    off=$(_cron_tz_offset_minutes)
    hhmm=$(_cron_calendar_fixed_hhmm "$cal")
    if [[ -n "$off" && "$off" == "0" ]]; then
        printf "UTC'ye SABİTLENMİŞ — sunucu da UTC'de (%s), saat farkı YOK" "$tzdisp"
        return 0
    fi
    if [[ -n "$off" && -n "$hhmm" ]] && local_hhmm=$(_cron_shift_hhmm "$hhmm" "$off"); then
        printf "UTC'de zamanlanmış (%s UTC) — sunucu yerel saatiyle (%s) %s'e denk geliyor" \
            "$hhmm" "$tzdisp" "$local_hhmm"
        return 0
    fi
    printf "UTC'de zamanlanmış — sunucu yerel saati: (%s); bu ifadenin SABİT bir saati olmadığından yerel karşılığı hesaplanamadı" "$tzdisp"
    return 0
}

# ─── Üç biçimi sırayla dener; başarıda "MOD GÖVDE..." (tek satır, 'read'
# ile ayrıştırılır — GÖVDE boşluk içerebileceğinden 'read'in SON değişkeni
# TÜM kalanı yutar, bkz. lib/domain.sh:_domain_unit_common_ctx İLE AYNI
# desen) yazar. MOD ∈ {turkish, cron5, raw}. ÖNCELİK SIRASI ÖNEMLİ DEĞİL
# (biçimler yapısal olarak ÇAKIŞMAZ — bkz. her çeviricinin kendi yorumu)
# ama cron5 'BENZİYORSA' (tam 5 alan) VE çeviri BAŞARISIZSA ham moda ASLA
# DÜŞÜLMEZ: yanlış yorumlamaktansa net bir hata tercih edilir.
#
# İKİNCİ ARGÜMAN — tz_mode ∈ {local, utc}, VARSAYILAN 'local' (KARAR
# DEĞİŞTİ, bkz. dosya başı "ZAMAN DİLİMİ" bloğu): 'local' hiçbir sonek
# EKLEMEZ (systemd soneksiz OnCalendar'ı sistem yerel saatinde yorumlar),
# 'utc' ise ESKİ davranışı birebir geri getirir (' UTC' soneki). Ham mod
# HER İKİ tz_mode'da da OLDUĞU GİBİ geçer — operatörün kendi yazdığı
# ifadeye srvctl ASLA dokunmaz (bunun '--utc' ile ÇELİŞMESİ 'cron add'de
# AÇIKÇA uyarılır).
# ═══════════════════════════════════════════════
_cron_resolve_schedule() {
    local input="$1" tz_mode="${2:-local}"
    local body suffix=""
    if [[ "$tz_mode" == "utc" ]]; then
        suffix=" UTC"
    fi

    if body=$(_cron_translate_turkish "$input"); then
        printf 'turkish %s%s' "$body" "$suffix"
        return 0
    fi

    if _cron_looks_like_cron5 "$input"; then
        if body=$(_cron_translate_cron5 "$input"); then
            printf 'cron5 %s%s' "$body" "$suffix"
            return 0
        fi
        return 1
    fi

    if _cron_calendar_charset_ok "$input"; then
        printf 'raw %s' "$input"
        return 0
    fi

    return 1
}

# ═══════════════════════════════════════════════
#  KİMLİK / UNIT ADI YARDIMCILARI
# ═══════════════════════════════════════════════

# Cron adı doğrulaması — YENİ bir regex YAZILMADI, mevcut assert_safe_ident
# (core.sh) KULLANILIYOR (görev talebi). Ek olarak makul bir uzunluk sınırı
# (unit dosya adı hijyeni — diğer kimliklerle AYNI konvansiyon).
_cron_ident_ok() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    (( ${#name} <= 50 )) || return 1
    assert_safe_ident "$name"
}

# sname="" → sistem kapsamı; sname="<safe_name>" → domain kapsamı.
_cron_svc_name() {
    if [[ -z "$1" ]]; then
        printf 'srvctl-syscron-%s.service' "$2"
    else
        printf 'srvctl-cron-%s-%s.service' "$1" "$2"
    fi
}
_cron_timer_name() {
    if [[ -z "$1" ]]; then
        printf 'srvctl-syscron-%s.timer' "$2"
    else
        printf 'srvctl-cron-%s-%s.timer' "$1" "$2"
    fi
}
_cron_fail_svc_name() {
    if [[ -z "$1" ]]; then
        printf 'srvctl-syscronfail-%s.service' "$2"
    else
        printf 'srvctl-cronfail-%s-%s.service' "$1" "$2"
    fi
}

# ═══════════════════════════════════════════════
#  DEPLOY KİLİDİ DİZİNİ — DAC/root ÇELİŞKİSİ DÜZELTMESİ (GERÇEK üretim
#  sunucusunda ölçüldü: 'flock: cannot open lock file
#  /run/srvctl/deploy-<sname>.lock: Permission denied', çıkış 66 — AppArmor
#  denied kaydı YOKTU, MAC katmanına HİÇ sıra gelmiyordu). Kilit dizini
#  ESKİDEN 700 root:root idi — bu YALNIZCA root olarak çalışan
#  lib/deploy.sh:_deploy_lock İÇİN doğruydu; bu cron job'u ise domain'in
#  KENDİ kullanıcısı (User=web_<sname>, aşağıdaki ExecStart sarmalaması)
#  olarak AYNI kilidi KARŞI taraftan (flock(1) exec-form) açmaya çalışıyor
#  — 700 root:root bir dizine web_<sname> hiç GİREMEZ.
#
#  ÇÖZÜM — domain BAŞINA AYRI bir alt dizin.
#
#  ⚠ SONRAKİ DÜZELTME (KRİTİK GÜVENLİK — canlı üretimde SÖMÜRÜLDÜ):
#  Bu fonksiyonun GÖVDESİ core.sh'a (_srvctl_lock_ensure) TAŞINDI. İKİ
#  gerekçe:
#    (1) Alt dizin ilk sürümde '700 web_<sname>:web_<sname>' idi — SAHİBİ
#        domain kullanıcısı olduğundan o kullanıcı dizinde UNLINK + CREATE
#        yapabiliyordu: kilit dosyasını silip yerine KEYFİ bir hedefe
#        sembolik bağ koyuyor, root olarak çalışan lib/deploy.sh:_deploy_lock
#        bunu dereference edip hedefi chown/chmod/truncate ediyordu
#        ('/etc/ld.so.preload' → TAM ROOT). Yeni model: '710 root:web_<sname>'
#        — domain kullanıcısında 'w' YOK, yalnız 'x' (geçiş) var; kilit
#        DOSYASI '660 root:web_<sname>' olarak ROOT tarafından ÖN-OLUŞTURULUR.
#        flock(1) dosyayı 'O_RDONLY|O_CREAT|O_NOCTTY' ile açar (util-linux
#        kaynağından doğrulandı; hem 22.04'ün v2.37.2'sinde hem 24.04'ün
#        v2.39.3'ünde AYNI) — MEVCUT dosya için 'r' yeter, ama O_CREAT artık
#        işe yaramaz olduğundan dosyanın ÖNCEDEN var olması ZORUNLUDUR.
#    (2) Formül AYNI ANDA lib/deploy.sh:_deploy_lock_dir'de de KOPYA olarak
#        duruyordu ve ikisi de AYNI hatayı taşıyordu. core.sh HER modülden
#        ÖNCE koşulsuz source edildiğinden (bin/srvctl:_load_and_run) tek
#        kaynağa indirmek çapraz modül 'source' sorunu (exit 127) DOĞURMAZ
#        ve drift'i YAPISAL olarak imkânsız kılar.
#  Tam izin modeli + ölçüm notları: lib/core.sh:_srvctl_lock_ensure başlık
#  yorumu. Drift'i ayrıca tests/test_deploy_lock_isolation.sh doğrular.
_cron_lock_dir() {
    _srvctl_lock_ensure "$1" "$2"
}

# ═══════════════════════════════════════════════
#  AppArmor ÖN-KONTROLÜ — flock EXEC + KİLİT DOSYASI izni (KOORDİNATÖR
#  HOST BULGUSU — İKİ KATMAN, AYNI SINIF)
# ═══════════════════════════════════════════════
# GERÇEK Ubuntu 24.04 VM'de İKİ AŞAMADA ölçüldü:
#   (1) 'flock' EXEC izni YOKTU → '/bin/sh: 1: flock: Permission denied'
#       (status=126). Düzeltme: templates/apparmor/profile-cli.tpl'e
#       '/usr/bin/flock rix,' eklendi.
#   (2) (1) düzeltildikten SONRA ölçüldü — flock ARTIK ÇALIŞIYOR ama kilit
#       DOSYASINI açamıyordu: 'flock: cannot open lock file
#       /run/srvctl/deploy-<sname>.lock: Permission denied' — DAC (dosya
#       izinleri) sorunsuzdu, engel yine AppArmor'du ('denied_mask="rc"',
#       '/run/srvctl' için profilde HİÇBİR KURAL yoktu). Düzeltme: AYNI
#       şablona '/run/srvctl/deploy-{{SAFE_NAME}}.lock rwk,' eklendi (bkz.
#       o dosyadaki UZUN gerekçe — 'k' locking izni 'rw'den AYRIDIR).
# İKİSİ DE yalnızca ŞABLONU günceller; ÖNCEDEN render edilmiş ('srvctl
# domain add'/'repair' ile zaten oluşturulmuş) canlı profil dosyaları
# ('/etc/apparmor.d/srvctl-<sname>-cli') OTOMATİK GÜNCELLENMEZ — 'srvctl
# domain repair <domain>' ÇALIŞTIRILMADAN düzeltme o domainde ETKİN OLMAZ.
#
# Bu fonksiyon TEK bir kontrolde İKİSİNİ BİRDEN doğrular (koordinatör
# talebi: "tek bir 'profil güncel mi' kontrolü ikisini birden kapsasın") —
# 'cron add' anında CANLI profili GERÇEKTEN okuyup EKSİK KALAN katmanı
# tespit eder; operatör bunu ancak BAŞARISIZ bir çalıştırmadan (126/66/2
# gibi bir exit kodundan) SONRA fark etmek yerine EKLEME ANINDA görür.
#
# Dönüş: 0=HER İKİ izin de VAR (profil tam güncel), 1=profil VAR ama
# EN AZ BİRİ eksik (repair gerekir — hangisi olduğunu ayırt ETMEYİZ, TEK
# bir "repair çalıştırın" mesajı yeterlidir, ikisi de AYNI komutla çözülür),
# 2=profil hiç yok/okunamıyor (bilinmiyor — domain henüz hardened olmayabilir
# ya da AppArmor kapalı olabilir; bu durumda SESSİZCE geçilir, UYARI
# ÜRETİLMEZ — "hiç profil yok" ile "profil var ama eksik" AYNI ŞEY DEĞİLDİR,
# ilkini "eksik/bozuk" gibi göstermek yanlış alarmdır, bkz. core.sh:
# _require_owned_or_warn'daki AYNI missing-vs-tamper ayrım ilkesi).
#
# DÜRÜSTLÜK NOTU: 'rwk,'/'rix,' desenleri HOST'ta ampirik ÖLÇÜLMÜŞ satırlarla
# (templates/apparmor/profile-cli.tpl'e eklenenlerle) BİREBİR aynı literal
# metni arar — bu fonksiyon AppArmor sözdizimini genel olarak ANLAMAZ,
# yalnızca "bu İKİ BİLİNEN-İYİ satır profilde var mı" sorusuna cevap verir.
_cron_apparmor_flock_ok() {
    local sname="$1"
    local profile="${SRVCTL_APPARMOR_DIR:-/etc/apparmor.d}/srvctl-${sname}-cli"
    [[ -f "$profile" ]] || return 2
    grep -Eq '^[[:space:]]*/usr/bin/flock[[:space:]]+m?rix,[[:space:]]*$' "$profile" 2>/dev/null || return 1
    # NOT (DAC/root çelişkisi düzeltmesi — bkz. _cron_lock_dir yorumu): kilit
    # dosyası artık domain'e özel bir alt dizinde yaşıyor
    # ('/run/srvctl/locks/<sname>/deploy-<sname>.lock') — eskiden düz
    # '/run/srvctl/deploy-<sname>.lock' idi. Bu regex İKİ dosyanın (bu
    # fonksiyon + templates/apparmor/profile-cli.tpl) AYNI ANDA güncellenmiş
    # olmasını GEREKTİRİR; sürüklenirse (biri güncellenip diğeri unutulursa)
    # tests/test_cron_add.sh (7b/7c/7d) bunu YAKALAR.
    local lock_re="^[[:space:]]*/run/srvctl/locks/${sname}/deploy-${sname}\\.lock[[:space:]]+rwk,[[:space:]]*$"
    grep -Eq "$lock_re" "$profile" 2>/dev/null || return 1
    return 0
}

# ═══════════════════════════════════════════════
#  SANDBOX (systemd mount namespace) ÖN-KONTROLÜ — DÖRDÜNCÜ HOST BULGUSU
# ═══════════════════════════════════════════════
# Koordinatör, AYNI Ubuntu 24.04 domain, ÖNCEKİ ÜÇ katman (exec izni,
# AppArmor dosya kuralı, DAC dizin modu) düzeltildikten SONRA ölçtü: flock
# artık dizine hem DAC hem AppArmor açısından girebiliyordu (AppArmor
# 'aa-complain' moduna alınıp TEKRAR denendiğinde BİLE AYNI hata — bu
# AppArmor'u KESİN olarak eledi) ama YİNE DE 'Permission denied' (çıkış
# 73) ile düşmeye devam etti. Kalan tek aday systemd'nin KENDİ mount
# sandbox'ıydı: cron unit'i 'ProtectSystem=strict' kullanır — bu TÜM dosya
# sistemi hiyerarşisini salt-okunur mount eder ('/dev','/proc','/sys'
# hariç); 'ReadWritePaths=' yalnız AÇIKÇA listelenen yolları geri açar.
# Kilit dizini bu listede YOKTU (yalnız DOMAIN_ROOT vardı) — flock DAC/
# AppArmor'dan GEÇSE BİLE salt-okunur bind-mount'a ÇARPIYORDU. Koordinatör
# bunu 'systemd-run' ile AYNI sandbox koşullarını kurup A/B testiyle
# KANITLADI: ReadWritePaths'te kilit dizini YOKKEN 'touch' başarısız,
# VARKEN başarılıydı.
#
# Düzeltme İKİ KATMANLI: (1) templates/systemd/srvctl-cron.service.tpl'in
# 'ReadWritePaths=' satırına YENİ bir LOCK_DIR token'ı eklendi (bkz. o
# şablonun TOKENS envanteri, _cron_add'in render_template çağrısı). (2)
# BU FONKSİYON — koordinatörün KENDİ teşhis tekniğinin (systemd-run A/B
# testi) 'cron add' ANINA taşınmış hâli: cron unit'inin KULLANACAĞI TAM
# AYNI sandbox özellikleriyle (User/Group, ProtectSystem=strict,
# ProtectHome=yes, PrivateTmp=yes, ReadWritePaths=-domain_root -lock_dir)
# geçici bir 'touch' unit'i çalıştırıp GERÇEKTEN yazılabilir mi diye
# DİNAMİK olarak sınar — statik metin eşleşmesinin (bkz.
# _cron_assert_readwrite_covers_lock, render sonrası) YAKALAYAMAYACAĞI
# "syntax doğru ama KERNEL/systemd sürümü BEKLENMEDİK davranıyor" sınıfı
# sorunları da kapsar.
#
# FAIL-SOFT (İSTEĞE BAĞLI): çağıran taraf (_cron_add) bu fonksiyonun
# sonucunu ASLA 'cron add'i ENGELLEMEK için kullanmaz, yalnız UYARIR —
# bkz. dönüş kodu 2 (probe hiç çalıştırılamadı) İLE 1 (probe çalıştı ve
# BAŞARISIZ) arasındaki ayrım. systemd-analyze (schedule sözdizimi)
# KASITLI OLARAK fail-closed'dır çünkü SAF/deterministik bir sözdizim
# kontrolüdür; bu probe İSE canlı sistem durumuna (kullanıcı henüz var mı,
# systemd sürümü, cgroup delegasyonu, o anki sistem yükü) BAĞIMLI bir
# DIŞ YAN ETKİLİ komut çalıştırır — GEÇİCİ/ilgisiz bir nedenle başarısız
# olması TÜM 'cron add' akışını KIRMAMALIDIR (istenmeyen bir fail-closed
# riski, tespit değeri kadar önemli).
#
# DÜRÜSTLÜK NOTU (görev talebi — "ölç, tahmin etme"): bu macOS geliştirme
# makinesinde systemd YOK — bu fonksiyonun 'systemd-run' ÇAĞRISI BURADAN
# HİÇ ÇALIŞTIRILAMADI/doğrulanamadı (yalnız 'command -v systemd-run'
# YOKKEN erken dönen (2) dalı VE argüman/mantık akışı test edilebildi,
# bkz. tests/test_cron_schedule.sh). GERÇEK üretim sunucusunda
# 'srvctl cron add' ile doğrulanmalı — sözdiziminde bir sorun çıkarsa
# YUKARIDAKİ fail-soft tasarımı sayesinde en kötü ihtimalle YANLIŞ bir
# uyarı basar/basmaz, ama 'cron add' akışını KIRMAZ.
#
# Dönüş: 0=probe BAŞARILI (sandbox altında kilit dizini yazılabilir —
# KANITLANDI), 1=probe ÇALIŞTI ama BAŞARISIZ (sandbox kilit dizinini
# KAPSAMIYOR — GERÇEK bir tespit), 2=probe HİÇ ÇALIŞTIRILAMADI
# (systemd-run yok / web kullanıcısı henüz yok / eksik argüman — BİLİNMİYOR,
# "eksik" "hatalı" ile AYNI ŞEY DEĞİL, sessizce geçilir — core.sh'taki AYNI
# missing-vs-tamper ayrım ilkesi, bkz. _cron_apparmor_flock_ok yorumu).
_cron_sandbox_probe_ok() {
    local domain_root="$1" lock_dir="$2" web_user="$3"
    command -v systemd-run >/dev/null 2>&1 || return 2
    [[ -n "$domain_root" && -n "$lock_dir" && -n "$web_user" ]] || return 2
    id "$web_user" >/dev/null 2>&1 || return 2

    local probe_file="${lock_dir}/.srvctl-cron-add-sandbox-probe.$$"
    systemd-run --quiet --wait --pipe --collect \
        --uid="$web_user" --gid="$web_user" \
        --property="ProtectSystem=strict" \
        --property="ProtectHome=yes" \
        --property="PrivateTmp=yes" \
        --property="ReadWritePaths=-${domain_root} -${lock_dir}" \
        -- /usr/bin/touch "$probe_file" >/dev/null 2>&1
    local rc=$?
    rm -f -- "$probe_file" 2>/dev/null || true
    [[ "$rc" -eq 0 ]] && return 0
    return 1
}

# ═══════════════════════════════════════════════
#  ALTINCI HOST BULGUSU — KOMUT ÖN-DOĞRULAMASI (AppArmor exec beyaz listesi)
# ═══════════════════════════════════════════════
# GERÇEK üretim sunucusunda (Ubuntu 24.04) ölçüldü:
#   srvctl cron add ... --command="echo 'x' && date +%Y"
# 'add' EXIT=0 verir, "Cron eklendi ve etkinleştirildi" der — ama 04:00'te
# tetiklendiğinde 'Result: exit-code / ExecMainStatus: 126' ile düşer.
# Domain'in CLI profili altında TEK TEK ölçüm ('aa-exec -p srvctl-<sname>-cli'):
#     php8.4 rc=0    flock rc=0
#     date rc=126    cat rc=126    tar  rc=126    mysqldump rc=126
#     git  rc=126    find rc=126   curl rc=126
# Kök neden: '-cli' profili DEPLOY için tasarlanmıştı — yalnız php/sh/dash/
# flock exec edilebiliyordu. ÜSTELİK son 8 dakikada çekirdekte 'apparmor.*
# DENIED' satırı SAYISI = 0: reddin sebebi bir 'deny' KURALI değil, kural
# YOKLUĞUdur ve bu audit kaydı ÜRETMEZ — yani deny TAMAMEN SESSİZDİR,
# operatör sebebi journal'da da, dmesg'te de, audit.log'da da GÖREMEZ.
#
# Profil şablonuna coreutils izinleri (date/cat/tar/sed/awk/mysqldump ...)
# AYRI bir görevde eklenmektedir; ama egress/yorumlayıcı araçları (curl,
# wget, bash, python3, find, xargs, env, nc, base64, ssh, rsync) domain
# izolasyonunu koruma amacıyla BİLEREK yasak KALACAKTIR — bu yüzden
# ön-doğrulama ihtiyacı ORTADAN KALKMAZ, yalnız kapsamı daralır.
#
# TASARIM: komut EKLENİRKEN (04:00'i beklemeden), komutun İÇİNDEKİ
# çalıştırılabilir adayları çıkarıp HER BİRİNİ domain'in KENDİ profili
# altında GERÇEKTEN exec etmeyi dener; rc==126 gören adayı "profil
# engelliyor" sayar ve 'error' ile ekleme AKIŞINI DURDURUR (yarım unit
# dosyası bırakmadan — kontrol, TÜM dosya yazımlarından ve 'confirm'
# sorusundan ÖNCE çalışır).
#
# FAIL-SOFT SINIRI (BİLİNÇLİ, test edilir — tests/test_cron_precheck.sh):
# prob YALNIZCA "GERÇEKTEN ölçtüm ve 126 gördüm" dediğinde ENGELLER. Prob
# çalıştırılamıyorsa (aa-exec yok / root değil / AppArmor çekirdek arayüzü
# okunamıyor / profil çekirdeğe yüklü değil / profil altında temel kabuk
# denemesi bile başarısız) ekleme ENGELLENMEZ, yalnız 'warn' ile
# "doğrulanamadı" denir: fail-closed yapılsaydı AppArmor'suz (ya da henüz
# 'domain repair' görmemiş) sistemlerde 'cron add' TAMAMEN kullanılamaz
# hâle gelirdi — bu, tespit değerinden daha büyük bir zarardır. AYNI
# missing-vs-tamper ayrım ilkesi: bkz. _cron_apparmor_flock_ok / core.sh:
# _require_owned_or_warn.

# safe_name → domain CLI AppArmor profil adı. Sistem kapsamında (sname boş)
# profil YOKTUR (root, profilsiz çalışır) — boş dizge döner. Ad TEK yerde
# türetilir ki 'cron add' ön-doğrulaması, teşhis metinleri ve gelecekteki
# çağrılar birbirinden SÜRÜKLENMESİN.
_cron_cli_profile() {
    local sname="${1:-}"
    [[ -n "$sname" ]] || return 0
    printf 'srvctl-%s-cli' "$sname"
}

# ─── Komut dizgesini kabuk operatörlerinden PARÇALARA böler (SAF fonksiyon) ───
# Ayraçlar: '&&' '||' ';' '|' '&' ve satır sonu. TIRNAK İÇİNDEKİ operatörler
# ayraç SAYILMAZ ('echo "a && b"' TEK parçadır) — aksi halde tırnaklı metin
# yüzünden uydurma adaylar üretirdik. Ters-eğik-çizgi ile kaçırılan karakter
# olduğu gibi taşınır. Her parça stdout'a AYRI SATIR olarak yazılır.
_cron_split_command() {
    local s="$1"
    local n=${#s} i=0 c nxt
    local cur="" in_s=0 in_d=0
    # Ters-eğik-çizgi KARŞILAŞTIRMASI bir değişken üzerinden yapılır
    # ($'\\' = TEK bir '\'): hem shellcheck SC1003 gürültüsü olmaz, hem de
    # '[[ == ]]' sağ tarafı TIRNAKLI olduğundan literal kalır (bkz.
    # _cron_escape_unit_squote'taki 'BASH pattern TUZAĞI' notu).
    local bs=$'\\'
    while (( i < n )); do
        c="${s:i:1}"
        if (( in_s )); then
            cur+="$c"
            [[ "$c" == "'" ]] && in_s=0
            i=$((i+1)); continue
        fi
        if (( in_d )); then
            if [[ "$c" == "$bs" && $((i+1)) -lt $n ]]; then
                cur+="$c${s:i+1:1}"; i=$((i+2)); continue
            fi
            cur+="$c"
            [[ "$c" == '"' ]] && in_d=0
            i=$((i+1)); continue
        fi
        if [[ "$c" == "$bs" && $((i+1)) -lt $n ]]; then
            cur+="$c${s:i+1:1}"; i=$((i+2)); continue
        fi
        if [[ "$c" == "'" ]]; then in_s=1; cur+="$c"; i=$((i+1)); continue; fi
        if [[ "$c" == '"' ]]; then in_d=1; cur+="$c"; i=$((i+1)); continue; fi
        if [[ "$c" == '&' || "$c" == '|' || "$c" == ';' || "$c" == $'\n' ]]; then
            printf '%s\n' "$cur"
            cur=""
            nxt="${s:i+1:1}"
            # '&&' ve '||' TEK ayraçtır (ikinci karakteri de yut) — aksi
            # halde araya BOŞ bir parça girerdi (zararsız ama gürültü).
            if [[ ( "$c" == '&' || "$c" == '|' ) && "$nxt" == "$c" ]]; then
                i=$((i+2))
            else
                i=$((i+1))
            fi
            continue
        fi
        cur+="$c"
        i=$((i+1))
    done
    printf '%s\n' "$cur"
}

# Bir parçanın İLK ANLAMLI kelimesi = çalıştırılacak aday (SAF fonksiyon).
# Baştaki kabuk anahtar kelimeleri ('if/then/do/...'), gruplama karakterleri
# ve DEĞİŞKEN ATAMALARI ('FOO=bar date' → 'date') atlanır. Aday
# bulunamazsa 1 döner (stdout boş).
_cron_part_first_word() {
    local part="$1"
    local -a words=()
    read -ra words <<< "$part"
    local i=0 tok
    while (( i < ${#words[@]} )); do
        tok="${words[$i]}"
        # Anahtar kelimeler TIRNAKLI yazılır — tırnaksız 'in'/'esac' bash'in
        # KENDİ 'case' sözdizimiyle karışabilir (shellcheck SC1010).
        case "$tok" in
            '('|')'|'{'|'}'|'!'|'if'|'then'|'else'|'elif'|'fi'|'do'|'done'|'while'|'until'|'for'|'case'|'esac'|'in'|'time'|'exec')
                i=$((i+1)); continue ;;
        esac
        # 'VAR=deger' önekleri (bir komut ÖNÜNDE ortam ataması) atlanır.
        if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            i=$((i+1)); continue
        fi
        # '(cd x' gibi YAPIŞIK gruplama karakterlerini soy.
        while [[ "$tok" == '('* || "$tok" == '{'* ]]; do tok="${tok:1}"; done
        if [[ -n "$tok" ]]; then
            printf '%s' "$tok"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# '/bin/sh' (dash) BUILTIN'i mi? — HİÇ exec EDİLMEZ, dolayısıyla AppArmor
# exec mediasyonuna DA girmez. YANLIŞ ALARM ÖNLEME: HOST ölçümünde
# '/bin/echo' rc=126 verdi, ama "sh -c 'echo x'" SORUNSUZ çalışır çünkü
# 'echo' dash'te builtin'dir ve '/bin/echo' hiç çalıştırılmaz. Bu ayrımı
# yapmayan bir ön-doğrulama, çalışan cron'ları REDDEDERDİ.
_cron_is_shell_builtin() {
    case "$1" in
        echo|printf|test|'['|cd|:|true|false|read|export|set|unset|exit|eval|exec|shift|trap|wait|umask) return 0 ;;
        pwd|hash|type|ulimit|local|return|break|continue|command|getopts|readonly|alias|unalias|kill|jobs|fg|bg|times|source|.) return 0 ;;
    esac
    return 1
}

# Kelime ÇÖZÜLEBİLİR mi, yoksa çalışma anında mı belirleniyor? Değişken
# ('$CMD'), komut ikamesi ('$(...)'/backtick), tırnak ya da glob içeren bir
# kelimenin HANGİ ikiliye karşılık geleceğini EKLEME ANINDA bilemeyiz —
# UYDURMAK YERİNE 'çözülemedi' deyip operatöre AÇIKÇA bildiririz.
_cron_word_is_dynamic() {
    local cand="$1" bs=$'\\'
    [[ "$cand" == *'$'* || "$cand" == *'`'* || "$cand" == *"'"* || "$cand" == *'"'* \
       || "$cand" == *'*'* || "$cand" == *'?'* || "$cand" == *'['* || "$cand" == *"$bs"* ]]
}

# Komut dizgesinden SINIFLANDIRILMIŞ adayları üretir (SAF fonksiyon).
# Her satır: '<sınıf> <kelime>', sınıf ∈ {aday, builtin, dinamik}.
_cron_command_candidates() {
    local command="$1"
    local part word
    while IFS= read -r part; do
        word=$(_cron_part_first_word "$part") || continue
        [[ -n "$word" ]] || continue
        if _cron_is_shell_builtin "$word"; then
            printf 'builtin %s\n' "$word"
        elif _cron_word_is_dynamic "$word"; then
            printf 'dinamik %s\n' "$word"
        else
            printf 'aday %s\n' "$word"
        fi
    done < <(_cron_split_command "$command")
}

# Aday kelimeyi MUTLAK ikili yoluna çevirir. Göreli yollar ('./script.sh')
# çalışma dizinine bağlıdır ve WorkingDirectory ilk deploy'dan sonra
# oluşabilir — ÇÖZÜLEMEZ sayılır (1). PATH'te bulunamayan kelime de 1 döner.
_cron_resolve_bin() {
    local word="$1" p
    if [[ "$word" == /* ]]; then
        printf '%s' "$word"
        return 0
    fi
    [[ "$word" != */* ]] || return 1
    p=$(command -v -- "$word" 2>/dev/null) || return 1
    [[ "$p" == /* ]] || return 1
    printf '%s' "$p"
}

# Prob, ikiliyi GERÇEKTEN çalıştırır ('--version' ile). Bu, standart sistem
# ikilileri için zararsız bir no-op'tur; ama operatörün KENDİ betiği
# ('/usr/local/bin/backup.sh' — '--version'ı yok sayıp GERÇEK yedeği
# alabilir) için DEĞİLDİR. Bu yüzden ÇALIŞTIRARAK deneme YALNIZCA sistem
# ikili dizinlerinin DOĞRUDAN çocuklarında yapılır; diğerleri
# 'denetlenmedi' olarak AÇIKÇA raporlanır (sessizce 'geçti' SAYILMAZ).
# SRVCTL_CRON_PROBE_DIRS: test-seam + operatör kaçış kapısı.
_cron_probe_dir_ok() {
    local bin="$1" d rest
    local -a dirs=()
    read -ra dirs <<< "${SRVCTL_CRON_PROBE_DIRS:-/bin /usr/bin /sbin /usr/sbin}"
    for d in "${dirs[@]}"; do
        [[ -n "$d" ]] || continue
        [[ "$bin" == "${d}/"* ]] || continue
        rest="${bin#"${d}/"}"
        [[ "$rest" != */* ]] || continue
        return 0
    done
    return 1
}

# ─── PROBUN KENDİSİ (tek exec noktası) ───
# _cron_probe_exec_rc <profil> [<mutlak-ikili-yol>]
#   ikili yolu BOŞ  → TEMEL (self-check) denemesi: profil altında '/bin/sh'
#                     gerçekten çalışıyor mu (0 beklenir).
#   ikili yolu DOLU → o ikiliyi profil altında exec etmeyi dener.
# Dönüş: KABUK exit kodu — 126 'bulundu ama çalıştırılamadı' (AppArmor/DAC),
# 127 'bulunamadı'. Ölçüm 'aa-exec -p <profil> -- /bin/sh -c ...' ile
# yapılır: exec HATASINI yorumlayan taraf POSIX kabuğun KENDİSİ olduğundan
# 126/127 ayrımı GARANTİLİDİR (aa-exec'in kendi hata çıkış kodlarına
# GÜVENİLMEZ). Ayrıca bu, cron unit'inin GERÇEK çalışma biçimini
# ('AppArmorProfile=' + '/bin/sh -c') birebir taklit eder.
# TEST-SEAM: SRVCTL_CRON_PROBE_FN — tanımlıysa GERÇEK 'aa-exec' yerine o
# fonksiyon çağrılır (macOS geliştirme makinesinde AppArmor YOKTUR). Bu
# seam YALNIZCA TAVSİYE niteliğindeki ön-doğrulamayı etkiler; GERÇEK
# zorlama (enforcement) çekirdekteki AppArmor profilindedir ve buradan
# ETKİLENMEZ — yani seam bir güvenlik sınırını gevşetmez, yalnız erken
# uyarıyı devre dışı bırakabilir.
_cron_probe_exec_rc() {
    local profile="$1" bin="${2:-}"
    local fn="${SRVCTL_CRON_PROBE_FN:-}"
    local rc=0
    if [[ -n "$fn" ]] && declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$profile" "$bin" || rc=$?
        return "$rc"
    fi
    # stdin '/dev/null'dan verilir VE (varsa) 'timeout' ile sınırlanır:
    # prob, ikiliyi GERÇEKTEN çalıştırdığından, '--version'ı yok sayıp
    # stdin'den okumaya kalkan bir ikili 'cron add'i SONSUZA KADAR
    # BEKLETEBİLİRDİ. 'timeout' yoksa (minimal imaj) prob yine çalışır —
    # yetenek tespiti, sürüm karşılaştırması DEĞİL.
    #
    # SC2016 BİLİNÇLİ: '-c' betiği TEK TIRNAKLI olmak ZORUNDA — '$1' burada
    # AppArmor profili altında çalışan KABUĞUN konumsal argümanıdır, srvctl
    # tarafında genişletilirse ikili yolu kabuk metnine GÖMÜLÜRDÜ (enjeksiyon).
    # shellcheck disable=SC2016
    if [[ -z "$bin" ]]; then
        _cron_probe_limited aa-exec -p "$profile" -- /bin/sh -c 'exit 0' </dev/null >/dev/null 2>&1 || rc=$?
    else
        _cron_probe_limited aa-exec -p "$profile" -- /bin/sh -c 'exec "$1" --version' sh "$bin" </dev/null >/dev/null 2>&1 || rc=$?
    fi
    return "$rc"
}

# 'timeout' VARSA komutu 5 saniyeyle sınırlar, yoksa doğrudan çalıştırır.
# Zaman aşımında 'timeout' 124 döner — bu 126 DEĞİLDİR, yani sonuç ASLA
# "profil engelledi" diye yorumlanmaz (bkz. _cron_precheck_command'ın 124
# dalı: 'ölçülemedi' olarak raporlanır).
_cron_probe_limited() {
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1 5 "$@"
    else
        "$@"
    fi
}

# Profil çekirdeğe YÜKLÜ mü? 0=evet, 1=hayır, 2=BİLİNMİYOR (ne securityfs
# okunabiliyor ne 'aa-status' var). SRVCTL_AA_PROFILES_FILE: test-seam.
_cron_profile_loaded() {
    local profile="$1"
    local pf="${SRVCTL_AA_PROFILES_FILE:-/sys/kernel/security/apparmor/profiles}"
    if [[ -r "$pf" ]]; then
        grep -q "^${profile} " "$pf" 2>/dev/null && return 0
        return 1
    fi
    if command -v aa-status >/dev/null 2>&1; then
        aa-status 2>/dev/null | grep -q -- "$profile" && return 0
        return 1
    fi
    return 2
}

# Prob KULLANILABİLİR mi? 0=evet; 2=hayır (NEDENİ stdout'a Türkçe yazılır,
# çağıran onu 'warn' içinde gösterir — "doğrulanamadı" demek "sorun yok"
# demek DEĞİLDİR, sebebi hep söylenir). Sıralama ÖNEMLİ: en ucuz/kesin
# koşuldan en pahalıya. SON adım GERÇEK bir 'aa-exec' denemesidir — bu,
# "aa-exec var ama çekirdek geçişi reddediyor" (konteyner, eksik yetenek,
# LSM kapalı) sınıfını da yakalar ve o durumda YANLIŞ 126 yorumlamayı önler.
_cron_probe_ready() {
    local profile="$1"
    if [[ -z "${SRVCTL_CRON_PROBE_FN:-}" ]]; then
        # ─ GERÇEK ortam koşulları (yalnız 'aa-exec' yolunda anlamlı) ─
        [[ -n "$profile" ]] || { printf 'profil adı yok (sistem kapsamı)'; return 2; }
        command -v aa-exec >/dev/null 2>&1 || { printf "'aa-exec' bulunamadı (apparmor paketi kurulu değil)"; return 2; }
        [[ "${EUID:-$(id -u)}" -eq 0 ]] || { printf 'root değilsiniz — profil geçişi denenemez'; return 2; }
        local ld=0
        _cron_profile_loaded "$profile" || ld=$?
        if (( ld == 1 )); then
            printf "'%s' profili çekirdeğe YÜKLÜ DEĞİL ('srvctl domain repair' çalıştırılmamış olabilir)" "$profile"
            return 2
        fi
        if (( ld == 2 )); then
            printf 'AppArmor durumu okunamadı (securityfs yok, aa-status yok)'
            return 2
        fi
    elif ! declare -F "${SRVCTL_CRON_PROBE_FN}" >/dev/null 2>&1; then
        printf 'enjekte edilen prob fonksiyonu tanımlı değil: %s' "${SRVCTL_CRON_PROBE_FN}"
        return 2
    fi
    # ─ TEMEL (self-check) denemesi — HER İKİ yolda da ZORUNLU ─
    # "aa-exec var ama çekirdek profil geçişini reddediyor" (konteyner, eksik
    # yetenek, LSM kapalı) durumunda ADAY sonuçlarını 126 diye yorumlamak
    # YANLIŞ olurdu: prob GÜVENİLİR olduğunu ÖNCE kendisi kanıtlamalıdır.
    local rc=0
    _cron_probe_exec_rc "$profile" "" || rc=$?
    if (( rc != 0 )); then
        printf "profil altında temel kabuk denemesi başarısız (aa-exec rc=%s)" "$rc"
        return 2
    fi
    return 0
}

# ─── ÖN-DOĞRULAMANIN GİRİŞ NOKTASI (yalnız DOMAIN kapsamı) ───
# Engellenen ikili bulunursa 'error' ile ÇIKAR (ekleme yapılmaz, hiçbir
# dosya yazılmamıştır — çağrı, tüm render/confirm adımlarından ÖNCEDİR).
# Diğer TÜM belirsizlikler 'warn'/'info' ile RAPORLANIR ama akışı durdurmaz.
_cron_precheck_command() {
    local command="$1" sname="$2" domain="$3"
    local profile
    profile=$(_cron_cli_profile "$sname")
    [[ -n "$profile" ]] || return 0

    local -a exec_words=() dyn_words=()
    local class word seen=" "
    while read -r class word; do
        [[ -n "$word" ]] || continue
        case " ${seen} " in *" ${word} "*) continue ;; esac
        seen="${seen}${word} "
        case "$class" in
            aday)    exec_words+=("$word") ;;
            dinamik) dyn_words+=("$word") ;;
        esac
    done < <(_cron_command_candidates "$command")

    if (( ${#dyn_words[@]} > 0 )); then
        info "Komut ön-doğrulaması: şu parça(lar) değişken/tırnak/kalıp içerdiği için ÇÖZÜLEMEDİ ve DENETLENMEDİ: ${dyn_words[*]}"
    fi
    (( ${#exec_words[@]} > 0 )) || return 0

    local reason=""
    if ! reason=$(_cron_probe_ready "$profile"); then
        warn "Komut ön-doğrulaması YAPILAMADI (${reason}) — komuttaki ikililerin '${profile}' profili altında çalıştırılabildiği DOĞRULANMADI. Ekleme sürüyor; ilk planlı çalışmayı beklemeden 'srvctl cron run ${domain} <ad>' ile GERÇEKTEN test edin."
        return 0
    fi

    local -a blocked=() unresolved=() unprobed=() timedout=() checked=()
    local w bin rc
    for w in "${exec_words[@]}"; do
        if ! bin=$(_cron_resolve_bin "$w"); then unresolved+=("$w"); continue; fi
        if ! _cron_probe_dir_ok "$bin"; then unprobed+=("$bin"); continue; fi
        rc=0
        _cron_probe_exec_rc "$profile" "$bin" || rc=$?
        case "$rc" in
            126)     blocked+=("$bin") ;;
            127)     unresolved+=("$w") ;;
            124|137) timedout+=("$bin") ;;   # 'timeout' kesti — ÖLÇÜLEMEDİ
            *)       checked+=("$bin") ;;
        esac
    done

    if (( ${#unprobed[@]} > 0 )); then
        info "Komut ön-doğrulaması: şu yol(lar) sistem ikili dizinlerinin DIŞINDA olduğu için ÇALIŞTIRILARAK denenmedi (kendi betiğinizi 'cron add' anında çalıştırma riski alınmaz): ${unprobed[*]}"
    fi
    if (( ${#timedout[@]} > 0 )); then
        warn "Komut ön-doğrulaması: şu ikili(ler) prob süresinde ('timeout' 5sn) yanıt vermedi — ÖLÇÜLEMEDİ, engelli olup olmadıkları BİLİNMİYOR: ${timedout[*]}"
    fi
    if (( ${#unresolved[@]} > 0 )); then
        warn "Komut ön-doğrulaması: şu komut(lar) PATH'te BULUNAMADI — çalışma anında 127 ('komut bulunamadı') ile düşebilir: ${unresolved[*]}"
    fi

    if (( ${#blocked[@]} > 0 )); then
        error "Komut bu domain'in AppArmor profili altında ÇALIŞTIRILAMIYOR — cron EKLENMEDİ.
  Engellenen ikili(ler): ${blocked[*]}
  Profil             : ${profile}
  Ölçüm              : profil altında exec denendi, çıkış kodu 126 (bulundu ama çalıştırma İZNİ YOK).
  Not: bu red SESSİZDİR — çekirdek 'DENIED' kaydı ÜRETMEZ; eklenseydi ilk planlı
  çalışmada hiçbir açıklama olmadan 126 ile düşerdi.
  Ne yapabilirsiniz:
    1) Komutu profilde İZİNLİ araçlarla yazın (ör. HTTP isteğini 'curl' yerine PHP tarafında yapın).
    2) İkili GERÇEKTEN gerekliyse profile exec izni ekleyip yeniden yükleyin
       (templates/apparmor/profile-cli.tpl + 'srvctl domain repair ${domain}').
       curl/wget/bash/python3/find/env/nc/ssh/rsync gibi egress ve yorumlayıcı
       araçları BİLEREK yasaktır — izin vermek domain izolasyonunu ZAYIFLATIR,
       bilinçli bir karar olmalıdır.
    3) İş gerçekten sistem geneliyse 'srvctl cron add --system ...' kullanın —
       ama bu root olarak, domain izolasyonunun DIŞINDA çalışır."
    fi

    if (( ${#checked[@]} > 0 )); then
        info "Komut ön-doğrulaması GEÇTİ: ${#checked[@]} ikili '${profile}' profili altında GERÇEKTEN çalıştırılabildi (${checked[*]})."
    fi
    return 0
}

# ═══════════════════════════════════════════════
#  ÇIKIŞ KODU TEŞHİSİ (TEK KAYNAK — run/list/show/logs/_on-failure AYNI metni
#  kullanır; ham sayı operatöre HİÇBİR ŞEY anlatmıyordu)
# ═══════════════════════════════════════════════
# Bilinmeyen kod için BOŞ dizge basar (uydurma YOK) ve HER ZAMAN 0 döner —
# çağıran tarafın 'set -e' altında ekstra guard yazmasına gerek kalmaz.
_cron_exit_hint() {
    local code="${1:-}" profile="${2:-}"
    case "$code" in
        126)
            if [[ -n "$profile" ]]; then
                printf "izin reddedildi — komuttaki bir ikili ÇALIŞTIRILAMADI; büyük olasılıkla AppArmor profili ('%s') o ikiliyi engelliyor (curl/wget/bash/python3/find/env gibi araçlar BİLEREK yasaktır). Kontrol: 'aa-exec -p %s -- /bin/sh -c \"exec <ikili> --version\"'" "$profile" "$profile"
            else
                printf 'izin reddedildi — komuttaki bir ikili çalıştırılamadı (çalıştırma izni yok ya da yorumlayıcı/betik başlığı eksik)'
            fi
            ;;
        127)
            printf 'komut bulunamadı — PATH ya da yazım hatası (mutlak yol kullanmayı deneyin)'
            ;;
        75)
            printf 'deploy kilidi meşguldü — çalışma ATLANDI (flock -E 75); GERÇEK bir başarısızlık DEĞİL, bir sonraki planlı zamanda tekrar denenir'
            ;;
    esac
    return 0
}

# ═══════════════════════════════════════════════
#  KAÇIŞ YARDIMCILARI (bkz. dosya başındaki UZUN sözleşme yorumu)
# ═══════════════════════════════════════════════

# systemd BİRİM DOSYASI tek-tırnaklı bir "item" için kaçış — BU POSIX KABUK
# KAÇIŞI DEĞİLDİR (bkz. dosya başı "ÜÇÜNCÜ HOST BULGUSU" yorumu). systemd
# ExecStart= gibi değerleri systemd.syntax(7)'nin "Quoting" bölümündeki
# C-tarzı kaçış tablosuyla kendi ayrıştırıcısıyla çözer; bu tabloda TEK
# bilinen tek-tırnak kaçışı "\'" tir (POSIX'in "'\''" deseni SYSTEMD'DE
# ÇALIŞMAZ — GERÇEK üretim sunucusunda 'Unterminated quoted string' ile
# ÖLÇÜLDÜ). Aynı tabloda ters-eğik-çizgi TEK TIRNAK İÇİNDE BİLE kaçış
# karakteridir (POSIX kabuğun AKSİNE) — bu yüzden ham metindeki HER '\'
# ÖNCE '\\' olarak KENDİSİ kaçırılmak ZORUNDADIR, aksi halde systemd
# SONRAKİ karakteri kendi tablosuna göre (yanlış) yorumlar. Sıra ÖNEMLİDİR:
# ÖNCE '\' → '\\', SONRA "'" → "\'" — tersi sırada ikinci adımın ÜRETTİĞİ
# yeni '\' karakterleri yanlışlıkla BİRİNCİ adım tarafından tekrar
# işlenmiş OLURDU (burada sıra zaten doğru: birinci adım BİTTİKTEN sonra
# ikinci adım çalışır, ikinci adımın çıktısı bir daha BİRİNCİ adımdan
# GEÇMEZ).
#
# BASH 'pattern' TUZAĞI: "${s//$bs/...}" gibi PATTERN tarafında TIRNAKSIZ
# bir değişken kullanmak, değişkenin İÇERİĞİNİ (tek bir '\') bir glob
# kaçış karakteri gibi yorumlatıp EŞLEŞMEYİ SESSİZCE BOZAR (ampirik
# doğrulandı) — bu yüzden PATTERN tarafındaki HER değişken referansı
# "$bs"/"$q" ŞEKLİNDE TIRNAKLANIR (bkz. aşağıdaki iki satır).
_cron_escape_unit_squote() {
    local s="$1" bs='\' q="'"
    s="${s//"$bs"/$bs$bs}"
    s="${s//"$q"/$bs$q}"
    printf '%s' "$s"
}

# systemd '%' specifier ikilemesi (ExecStart= VE Description= için).
_cron_escape_percent() {
    printf '%s' "${1//%/%%}"
}

# ═══════════════════════════════════════════════
#  RENDER SONRASI GÜVENLİK AĞI (domain.sh:_domain_assert_no_leftover_tokens
#  İLE AYNI mantığın KENDİ İÇİNDE tutulan kopyası — çapraz modül bağımlılığı
#  KURULMAMASI için, CLAUDE.md deseni: cross-module çağrı yalnızca GEREKTİĞİNDE)
# ═══════════════════════════════════════════════
_cron_assert_no_leftover_tokens() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if grep -q '{{' "$file" 2>/dev/null; then
        local leftover
        leftover=$(grep -oE '\{\{[A-Z_]+\}\}' "$file" 2>/dev/null | sort -u | tr '\n' ' ')
        rm -f -- "$file"
        error "Şablon render hatası: ${file} içinde beslenmeyen token kaldı (${leftover:-'{{...}}'}) — dosya silindi, işlem durduruldu."
    fi
}

# DÖRDÜNCÜ HOST BULGUSU'nun STATİK yarısı (bkz. _cron_sandbox_probe_ok'un
# UZUN yorumu — DİNAMİK yarısı). Bu bir OPERATÖR/host koşulu DEĞİL, saf
# bir srvctl İÇ TUTARLILIK denetimidir: render EDİLMİŞ dosyanın KENDİSİNDE
# LOCK_DIR'in GERÇEKTEN 'ReadWritePaths='e ULAŞTIĞINI doğrular — ileride
# biri _cron_add'in render_template çağrısından 'LOCK_DIR=...' token'ını
# YANLIŞLIKLA çıkarırsa (ya da şablondan satırı silerse) bu, render'ın
# KENDİSİNİ ('{{LOCK_DIR}}' leftover) KIRMAZ (render_template salt
# string-replace'tir, eksik token'ı SESSİZCE boş bırakabilir) — bu yüzden
# '_cron_assert_no_leftover_tokens' TEK BAŞINA bu sınıf regresyonu
# YAKALAYAMAZ, AYRI bir SEMANTİK kontrol gerekir. '_cron_assert_no_leftover_
# tokens' İLE AYNI ciddiyette FAIL-CLOSED: dosyayı SİLER, hata verir —
# bir kod hatası operatöre "cron eklendi" YANILSAMASI VERİP GERÇEK
# üretimde sessizce (66/73 ile) düşmesine asla İZİN VERİLMEZ.
_cron_assert_readwrite_covers_lock() {
    local svc_file="$1" lock_dir="$2"
    [[ -f "$svc_file" ]] || return 0
    [[ -n "$lock_dir" ]] || return 0
    local rwline
    rwline=$(grep -m1 '^ReadWritePaths=' "$svc_file" 2>/dev/null) || rwline=""
    if [[ "$rwline" != *"$lock_dir"* ]]; then
        rm -f -- "$svc_file"
        error "İç tutarlılık hatası: ${svc_file} içindeki 'ReadWritePaths=' satırı kilit dizinini ('${lock_dir}') İÇERMİYOR — bu bir srvctl KOD HATASIDIR (LOCK_DIR token'ı şablona ya da render çağrısına eksik besleniyor olabilir), bir yapılandırma sorunu DEĞİL. Dosya silindi, işlem durduruldu — lütfen bir hata bildirin."
    fi
}

# ═══════════════════════════════════════════════
#  systemctl SORGU YARDIMCILARI (macOS/test-seam: systemctl yoksa 'bilinmiyor')
# ═══════════════════════════════════════════════
_cron_unit_prop() {
    command -v systemctl >/dev/null 2>&1 || { printf ''; return 0; }
    systemctl show "$1" -p "$2" --value 2>/dev/null || true
}
_cron_is_enabled() {
    command -v systemctl >/dev/null 2>&1 || { printf 'bilinmiyor'; return 0; }
    local st
    st=$(systemctl is-enabled "$1" 2>/dev/null) || true
    printf '%s' "${st:-bilinmiyor}"
}
_cron_active_state() {
    command -v systemctl >/dev/null 2>&1 || { printf 'bilinmiyor'; return 0; }
    local st
    st=$(systemctl is-active "$1" 2>/dev/null) || true
    printf '%s' "${st:-bilinmiyor}"
}
_cron_last_run() {
    local v
    v=$(_cron_unit_prop "$1" ExecMainStartTimestamp)
    if [[ -n "$v" ]]; then printf '%s' "$v"; else printf 'hiç çalışmadı / bilinmiyor'; fi
}
# Epoch MİKROSANİYE → sunucu YEREL saatinde okunabilir damga. Yetenek
# tespiti: GNU date '-d @<sn>', BSD/macOS date '-r <sn>' — hangisi VARSA o
# kullanılır, sürüm karşılaştırması YOK. Hiçbiri işe yaramazsa BOŞ döner
# (çağıran ham değeri basar — uydurma YOK). HER ZAMAN 0 döner.
_cron_fmt_epoch_usec() {
    local usec="${1:-}"
    local re='^[0-9]+$'
    [[ "$usec" =~ $re ]] || return 0
    local sec=$(( usec / 1000000 ))
    (( sec > 0 )) || return 0
    local out=""
    out=$(date -d "@${sec}" '+%a %Y-%m-%d %H:%M:%S %z' 2>/dev/null) || out=""
    if [[ -z "$out" ]]; then
        out=$(date -r "$sec" '+%a %Y-%m-%d %H:%M:%S %z' 2>/dev/null) || out=""
    fi
    printf '%s' "$out"
}

# BİR SONRAKİ GERÇEK ÇALIŞMA ANI — HER ZAMAN sunucu YEREL saatinde.
# systemd sürümüne göre 'NextElapseUSecRealtime' ya insan-okunur bir damga
# ya da HAM epoch mikrosaniye olarak gelir (yetenek/biçim tespiti — sürüm
# karşılaştırması YOK): sayısalsa yerel saate çevrilir, değilse systemd'nin
# KENDİ (zaten yerel, '+03' gibi ofset ekli) biçimi olduğu gibi basılır.
_cron_next_run() {
    local v
    v=$(_cron_unit_prop "$1" NextElapseUSecRealtime)
    if [[ -z "$v" || "$v" == "0" || "$v" == "n/a" ]]; then
        printf 'bilinmiyor'
        return 0
    fi
    local re='^[0-9]+$'
    if [[ "$v" =~ $re ]]; then
        local human
        human=$(_cron_fmt_epoch_usec "$v")
        if [[ -n "$human" ]]; then
            printf '%s' "$human"
        else
            printf '%s (ham mikrosaniye — yerel saate çevrilemedi)' "$v"
        fi
        return 0
    fi
    printf '%s' "$v"
}
_cron_last_exit() {
    local v r
    v=$(_cron_unit_prop "$1" ExecMainStatus)
    r=$(_cron_unit_prop "$1" Result)
    if [[ -n "$v" ]]; then printf '%s (%s)' "$v" "${r:-bilinmiyor}"; else printf 'bilinmiyor'; fi
}

# safe_name → gerçek domain adı (yalnız GÖRÜNTÜLEME amaçlı, 'cron list'
# TÜM domain'leri tararken). Bulunamazsa 1 döner — çağıran taraf safe_name'i
# parantez içinde göstermeye düşer (UYDURMA YOK).
_cron_domain_from_sname() {
    local target="$1" d s
    while IFS= read -r d; do
        s=$(safe_name "$d")
        if [[ "$s" == "$target" ]]; then
            printf '%s' "$d"
            return 0
        fi
    done < <(list_all_domains)
    return 1
}

# ═══════════════════════════════════════════════
#  AÇIKLAMA GÖRÜNTÜLEME — systemd 'Description=' ÖNEKİNİN SOYULMASI
# ═══════════════════════════════════════════════
# GERÇEK üretim sunucusunda görülen görüntüleme kusuru: 'cron list'
# "Açıklama" alanında kullanıcının yazdığı metin yerine systemd
# 'Description=' satırının TAMAMI basılıyordu —
#     Açıklama : srvctl Cron (dev.designwestgate.art / escapetest): Kacis+ampersand
# oysa operatör yalnızca 'Kacis+ampersand' yazmıştı. Önek, unit'in systemd
# tarafında kimliklenebilmesi İÇİN şablonda BİLEREK vardır (bkz.
# templates/systemd/srvctl-cron.service.tpl) — kaldırılmaz, yalnız GÖSTERİMDE
# soyulur.
#
# NEDEN "domain adını bilip ondan önek kurma" DEĞİL de YAPISAL SOYMA: 'cron
# list' TÜM domain'leri tararken bir safe_name gerçek domain'e ÇÖZÜLEMEYEBİLİR
# (domain silinmiş, unit kalmış) — o durumda önek eşleşmez ve kusur GERİ
# GELİRDİ. Bunun yerine ŞABLONLARIN GARANTİ ETTİĞİ yapı kullanılır:
#     'srvctl Cron (<domain> / <ad>): <açıklama>'      (domain kapsamı)
#     'srvctl Sistem Cron (<ad>): <açıklama>'          (sistem kapsamı)
# Ne domain (validate_domain) ne de ad (assert_safe_ident) ')' ya da ':'
# İÇEREBİLİR — bu yüzden İLK '): ' ayracı HER ZAMAN öneki bitirir; kullanıcı
# açıklamasında '): ' geçse bile SONRASINDA kalır, dokunulmaz.
#
# '%%' GERİ ALMA: açıklama unit'e yazılırken _cron_escape_percent ile
# ikilenmişti (systemd specifier savunması) — gösterimde geri alınır.
# BASH TUZAĞI: '${d//%%/%}' kullanılabilirdi ama değiştirme dizgesinde '&'
# bash 5.2'de EŞLEŞEN METNE genişler; burada değiştirme dizgesi salt '%'
# olduğundan güvenlidir, YİNE DE önek soyma tarafında '&' içerebilen
# KULLANICI metnine hiç dokunmayan '${d#...}' (önek silme) tercih edilir —
# o operatörde '&' semantiği HİÇ YOKTUR.
_cron_desc_user_part() {
    local d="${1:-}"
    case "$d" in
        "srvctl "*"): "*) d="${d#*"): "}" ;;
    esac
    printf '%s' "${d//%%/%}"
}

# ═══════════════════════════════════════════════
#  SIDECAR (yalnız kullanıcının GİRDİĞİ ham metni saklar — tek doğruluk
#  kaynağı UNIT DOSYALARIdır; burası yalnız systemd'den GERİ ÇEVRİLEMEYEN
#  TEK bilgiyi — operatörün orijinal ifadesini — tutar, 'bilinmeyeni
#  uydurma' ilkesiyle uyumlu).
# ═══════════════════════════════════════════════
_cron_sidecar_dir() {
    printf '%s/_cron/%s' "${SRVCTL_STATE_DIR}" "${1:-_system}"
}
_cron_write_sidecar() {
    local sname="$1" name="$2" raw="$3" mode="$4"
    local dir
    dir=$(_cron_sidecar_dir "$sname")
    secure_dir "$dir" 700
    local sidecar_file="${dir}/${name}.conf"
    {
        printf 'SCHEDULE_RAW=%s\n' "$raw"
        printf 'SCHEDULE_MODE=%s\n' "$mode"
        printf 'CREATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$sidecar_file"
    chmod 644 "$sidecar_file" 2>/dev/null || true
    chown root:root "$sidecar_file" 2>/dev/null || true
}

# ═══════════════════════════════════════════════
#  OnFailure DROP-IN + BİLDİRİM UNIT'İ (bkz. dosya başı sözleşme yorumu)
# ═══════════════════════════════════════════════
_cron_write_failure_hook() {
    local sysd_dir="$1" svc_name="$2" fail_name="$3" domain="$4" name="$5" is_system="$6"

    local dropin_dir="${sysd_dir}/${svc_name}.d"
    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/override.conf" <<EOF
# srvctl tarafından otomatik üretildi (srvctl cron add) — elle düzenlemeyin.
# Bu drop-in ana şablona (TOKENS kontratı SABİT) DOKUNMADAN "bildir + kaydet,
# otomatik tekrar YOK" davranışını ekler (bkz. lib/cron.sh dosya başı yorumu).
[Unit]
OnFailure=${fail_name}
EOF
    chmod 644 "${dropin_dir}/override.conf" 2>/dev/null || true

    local target_arg
    if [[ "$is_system" == "true" ]]; then
        target_arg="--system"
    else
        target_arg="$domain"
    fi
    # target_arg/name burada TIRNAKSIZ gömülür: domain (validate_domain) ve
    # name (assert_safe_ident) ZATEN boşluk/özel-karakter İÇEREMEZ — tek
    # argv kelimesi olarak güvenle gömülebilirler (ek tırnaklama gerekmez).
    cat > "${sysd_dir}/${fail_name}" <<EOF
# srvctl tarafından otomatik üretildi (srvctl cron add) — elle düzenlemeyin.
[Unit]
Description=srvctl cron basarisizlik bildirimi (${name})

[Service]
Type=oneshot
ExecStart=${SRVCTL_ROOT}/bin/srvctl cron _on-failure ${target_arg} ${name}
EOF
    chmod 644 "${sysd_dir}/${fail_name}" 2>/dev/null || true
}

# 'OnFailure=' tarafından tetiklenir — YALNIZ INTERNAL kullanım. Exit kodu
# 75 (flock -E 75 sentinel'i — bkz. dosya başı DEPLOY KİLİDİ yorumu) ÖZEL
# olarak "atlandı" sayılır: kaydedilir ama bildirim GÖNDERİLMEZ.
_cron_on_failure() {
    local scope_arg="${1:-}" name="${2:-}"
    if [[ -z "$scope_arg" || -z "$name" ]]; then
        log_action "CRON _on-failure: eksik argüman (bu bir dahili çağrıdır, elle çalıştırılmamalıdır)"
        return 0
    fi

    local sname="" scope_label unit
    if [[ "$scope_arg" == "--system" ]]; then
        scope_label="sistem geneli"
        unit=$(_cron_svc_name "" "$name")
    else
        sname=$(safe_name "$scope_arg")
        scope_label="domain: ${scope_arg}"
        unit=$(_cron_svc_name "$sname" "$name")
    fi

    local exit_code result
    exit_code=$(_cron_unit_prop "$unit" ExecMainStatus); exit_code="${exit_code:-bilinmiyor}"
    result=$(_cron_unit_prop "$unit" Result); result="${result:-bilinmiyor}"

    if [[ "$exit_code" == "75" ]]; then
        log_action "CRON ATLANDI (deploy kilidi aktifti, GERÇEK başarısızlık DEĞİL): ${scope_label} / ${name} — unit=${unit}"
        return 0
    fi

    # Ham çıkış kodunun ANLAMI (TEK kaynak — bkz. _cron_exit_hint): 126,
    # bildirimi alan operatöre TEK BAŞINA hiçbir şey anlatmıyordu; AppArmor
    # reddi SESSİZ olduğu için journal'da da bir ipucu YOKTUR.
    local profile hint diag=""
    profile=$(_cron_cli_profile "$sname")
    hint=$(_cron_exit_hint "$exit_code" "$profile")
    if [[ -n "$hint" ]]; then
        diag="
Teşhis: ${hint}"
    fi

    log_action "CRON BAŞARISIZ: ${scope_label} / ${name} — unit=${unit} exit=${exit_code} result=${result}${hint:+ — ${hint}}"

    # Çapraz modül bildirim (CLAUDE.md deseni) — notify.sh yoksa sessizce atlanır.
    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true
    if declare -f send_notification &>/dev/null; then
        send_notification "Cron Görevi Başarısız" \
"Görev: ${name}
Kapsam: ${scope_label}
Unit: ${unit}
Çıkış kodu: ${exit_code}
Sonuç: ${result}${diag}

Otomatik tekrar YOK — bir sonraki planlı zamanda yeniden denenecek.
Loglar: journalctl -u ${unit}" \
            "critical" || true
    fi
    return 0
}

# ═══════════════════════════════════════════════
#  cron add <domain>|--system --name= --schedule= --command= [--description=] [--timeout=]
# ═══════════════════════════════════════════════
_cron_add() {
    local scope_arg="${1:-}"
    if [[ -z "$scope_arg" ]]; then
        error "Kullanım: srvctl cron add <domain>|--system --name=<ad> --schedule=<zaman> --command=<komut> [--description=...] [--timeout=<sn>] [--catch-up-on-boot]"
    fi
    shift

    local is_system=false domain="" sname=""
    if [[ "$scope_arg" == "--system" ]]; then
        is_system=true
    else
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
    fi

    local name="" schedule="" command="" description="" timeout="$CRON_DEFAULT_TIMEOUT"
    local catchup="false" tz_mode="local"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --name=*)        name="${arg#--name=}" ;;
            --schedule=*)    schedule="${arg#--schedule=}" ;;
            --command=*)     command="${arg#--command=}" ;;
            --description=*) description="${arg#--description=}" ;;
            --timeout=*)     timeout="${arg#--timeout=}" ;;
            --catch-up-on-boot) catchup="true" ;;
            # ZAMAN DİLİMİ (bkz. dosya başı "ZAMAN DİLİMİ" bloğu): varsayılan
            # SUNUCU YEREL SAATİ. '--utc' ESKİ davranışı (' UTC' soneki)
            # AÇIK TERCİH olarak geri getirir — çok sunuculu/çok bölgeli
            # kurulumlarda meşrudur.
            --utc)           tz_mode="utc" ;;
            *) error "Bilinmeyen seçenek: ${arg}" ;;
        esac
    done
    # CRON_PERSISTENT (Persistent=) — PER-JOB, sabit DEĞİL (koordinatör
    # geri bildirimi — bkz. srvctl-cron.timer.tpl başlık yorumu): "cache
    # temizliği" (kaçırılırsa ZARARSIZ) ile "gecelik yedekleme" (kaçırılırsa
    # VERİ KAYBI riski) TAM TERS varsayılan ister, tek sabit değer ikisini
    # AYNI ANDA doğru karşılayamaz. Varsayılan 'false' (crontab-parity, EN AZ
    # SÜRPRİZ — şablonun kendi önerisi); operatör AÇIKÇA '--catch-up-on-boot'
    # vermeden 'true' OLMAZ. Değer burada literal "true"/"false" olarak
    # ÜRETİLDİĞİNDEN (kullanıcı serbest metni DEĞİL) doğal olarak güvenlidir;
    # yine de şablonun istediği "kaynak taraf validasyonu" için savunma
    # amaçlı normalize edilir.
    validate_bool "$catchup" || catchup="false"

    _cron_ident_ok "$name" || error "Geçersiz cron adı: '${name}' (yalnız harf/rakam/alt çizgi, azami 50 karakter)"
    [[ -n "$schedule" ]] || error "--schedule zorunlu"
    [[ "$schedule" != *$'\n'* && "$schedule" != *$'\r'* ]] || error "--schedule satırsonu/CR içeremez"
    [[ -n "$command" ]] || error "--command zorunlu"
    [[ "$command" != *$'\n'* && "$command" != *$'\r'* ]] || error "--command satırsonu/CR içeremez"
    validate_uint "$timeout" 86400 || error "Geçersiz --timeout: ${timeout} (1-86400 saniye)"
    (( timeout >= 1 )) || error "--timeout en az 1 saniye olmalı"
    [[ -n "$description" ]] || description="$name"

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc_name timer_name fail_name
    svc_name=$(_cron_svc_name "$sname" "$name")
    timer_name=$(_cron_timer_name "$sname" "$name")
    fail_name=$(_cron_fail_svc_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc_name}" ]] && error "Bu isimde bir cron zaten var: ${svc_name} (önce 'srvctl cron remove' ile silin ya da farklı bir --name seçin)"

    if [[ "$is_system" != "true" ]]; then
        local first="${command%% *}"
        if [[ "$first" == "php" ]]; then
            warn "Komut 'php' ile başlıyor — bu, \$PATH üzerindeki VARSAYILAN php ikili dosyasını kullanır ve domain'in yapılandırılmış PHP sürümüyle AYNI OLMAYABİLİR. Domain'in PHP'sini garanti etmek için 'php<sürüm>' (ör. php8.3) ya da mutlak yol (/usr/bin/php8.3) kullanmanız önerilir."
        fi
        # ALTINCI HOST BULGUSU — komut ön-doğrulaması (bkz. o bölümün UZUN
        # yorumu). BURADA, yani HİÇBİR dosya yazılmadan VE 'confirm'
        # sorulmadan ÖNCE çağrılır: engellenen bir ikili bulunursa
        # '_cron_precheck_command' içindeki 'error' AKIŞI SONLANDIRIR ve
        # geriye YARIM bir unit/timer/drop-in KALMAZ. Sistem cron'ları
        # ('--system') root olarak, HİÇBİR CLI profiline bağlı OLMADAN
        # çalıştığından bu kontrolün DIŞINDADIR (yanlış alarm olurdu).
        _cron_precheck_command "$command" "$sname" "$domain"
    fi

    local resolved
    if ! resolved=$(_cron_resolve_schedule "$schedule" "$tz_mode"); then
        error "Zamanlama ifadesi anlaşılamadı: '${schedule}'
  Desteklenen biçimler ('srvctl cron' yardımına bkz: srvctl cron):
    1) Türkçe kısayol (küçük harf): 'her gün SS:DD', 'her N dakikada', 'her saat',
       'her <gün> SS:DD', \"ayın N'i SS:DD\", 'hafta içi SS:DD'
    2) Standart 5 alanlı cron sözdizimi (ör. '0 3 * * *') — ayın_günü VE
       haftanın_günü AYNI ANDA kısıtlanamaz.
    3) Ham systemd takvim ifadesi (ör. '*-*-01 02:00:00')"
    fi

    local mode calendar
    read -r mode calendar <<< "$resolved"

    # ─── ZAMAN DİLİMİ BİLDİRİMİ (bkz. dosya başı "ZAMAN DİLİMİ" bloğu) ───
    # Operatör HANGİ dilimde iş kurduğunu HER ZAMAN, EKLEME ANINDA görür —
    # "sanırım yereldir" belirsizliği bırakılmaz.
    local tz_display
    tz_display=$(_cron_tz_display)
    if [[ "$mode" == "raw" ]]; then
        if [[ "$tz_mode" == "utc" ]]; then
            warn "'--utc' HAM systemd ifadesinde YOK SAYILDI: ham mod OLDUĞU GİBİ geçer, srvctl operatörün yazdığı ifadeye ASLA sonek eklemez. UTC istiyorsanız ifadenin SONUNA kendiniz ' UTC' yazın."
        fi
        warn "Ham mod: zaman dilimi ifadenin İÇİNDE belirtilmemişse SUNUCUNUN yerel saatine göre yorumlanır (systemd varsayılanı; bu sunucu: ${tz_display}). Belirli bir dilim istiyorsanız ifadenin sonuna 'UTC' ya da 'Europe/Istanbul' gibi bir IANA adı ekleyin."
    elif [[ "$tz_mode" == "utc" ]]; then
        info "Zamanlama UTC'ye SABİTLENDİ ('--utc' verildi): ${calendar}"
        local utc_hhmm local_hhmm off_min
        utc_hhmm=$(_cron_calendar_fixed_hhmm "$calendar")
        off_min=$(_cron_tz_offset_minutes)
        if [[ -n "$utc_hhmm" && -n "$off_min" && "$off_min" != "0" ]] && local_hhmm=$(_cron_shift_hhmm "$utc_hhmm" "$off_min"); then
            warn "DİKKAT: bu iş SUNUCU YEREL SAATİYLE (${tz_display}) ${local_hhmm} civarında çalışacak — yazdığınız ${utc_hhmm} DEĞİL. '--utc' bayrağını kaldırırsanız tam olarak ${utc_hhmm} yerel saatinde çalışır."
        fi
    else
        info "Zamanlama SUNUCUNUN YEREL saatine göre kuruldu (${tz_display}) — yazdığınız saat, işin çalışacağı saattir: ${calendar}"
        info "Not: birden fazla bölgedeki sunucuları AYNI mutlak anda tetiklemek istiyorsanız '--utc' bayrağını kullanın (OnCalendar'a ' UTC' soneki yazılır)."
    fi

    # Persistent= — PER-JOB (CRON_PERSISTENT), sabit DEĞİL (bkz. yukarıdaki
    # 'catchup' değişkeninin yorumu). Operatöre AÇIKÇA hangi davranışın
    # seçildiği söylenir — sessizce varsayılana güvenilmez.
    if [[ "$catchup" == "true" ]]; then
        info "Not: '--catch-up-on-boot' verildi — sunucu kapalıyken kaçan bir çalışma AÇILIŞTA telafi edilecek (Persistent=true)."
    else
        info "Not: sunucu kapalıyken kaçan bir çalışma OTOMATİK TELAFİ EDİLMEZ (Persistent=false — crontab davranışıyla uyumlu varsayılan). Yedekleme gibi 'mutlaka çalışmalı' işler için '--catch-up-on-boot' kullanın."
    fi

    echo ""
    info "Hesaplanan OnCalendar ifadesi: ${calendar}"
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze calendar "$calendar" --iterations=3; then
            error "systemd-analyze bu ifadeyi GEÇERSİZ buldu — cron eklenmedi: ${calendar}"
        fi
    else
        warn "systemd-analyze bulunamadı — zamanlama sözdizimi DOĞRULANAMADI (fail-safe: yukarıdaki ifadeyi GÖZLE kontrol edin)"
    fi
    echo ""

    if ! confirm "Bu zamanlamayla '${name}' cron'u eklensin mi?"; then
        info "İptal edildi."
        return 0
    fi

    # ── Kabuk sarmalama + kaçış (bkz. dosya başındaki UZUN sözleşme yorumu) ──
    # TEK KATMANLI TASARIM: flock KENDİ '-c' bayrağıyla (iç kabuk çağırma)
    # DEĞİL, exec-form ile ('flock <bayraklar> <kilit-dosyası> <komut>
    # [argüman...]') kullanılır — flock hiçbir metni yeniden AYRIŞTIRMAZ,
    # kendisine verilen argv'yi execve() eder. FLOCK_PREFIX (ExecStart'ın
    # BAŞINA, '/bin/sh'den ÖNCE eklenir) boş kalabilir (sistem cron'u ya da
    # flock yoksa) — bu durumda ExecStart doğrudan '/bin/sh' ile başlar
    # (syscron şablonuyla BİREBİR AYNI biçim).
    #
    # NOT: web_user/domain_root/working_dir/lock_dir burada, render_template
    # çağrısından ÖNCE, ERKEN hesaplanır (aşağıdaki render bölümünde AYRICA
    # tanımlanan aynı-adlı değişkenlerle çakışmaz — bkz. o bölümdeki NOT) —
    # 'lock_dir' HEM FLOCK_PREFIX'in kilit yolu HEM DE render'a beslenen
    # LOCK_DIR token'ı (ReadWritePaths= — bkz. DÖRDÜNCÜ HOST BULGUSU
    # aşağıda) İÇİN gereklidir; bu yüzden flock MEVCUT OLMASA BİLE
    # hesaplanır (LOCK_DIR token'ı HER ZAMAN beslenmek ZORUNDADIR, aksi
    # halde render_template leftover-token guard'ı patlar).
    local flock_prefix="" lock_dir="" domain_root="" working_dir="" web_user=""
    if [[ "$is_system" != "true" ]]; then
        web_user="web_${sname}"
        # WEB_ROOT/<domain>/current — _domain_working_dir (lib/domain.sh) İLE
        # BİREBİR AYNI sözleşme; çapraz modül bağımlılığı KURULMADAN (tek
        # satırlık formül) burada yeniden üretilir.
        working_dir="${WEB_ROOT}/${domain}/current"
        # DOMAIN_ROOT: ReadWritePaths= için domain'in TÜM ağacı gerekir
        # (yalnız WORKING_DIR/'current' DEĞİL — worker/scheduler İLE AYNI
        # gerekçe, bkz. srvctl-cron.service.tpl başlık yorumu: 'writable/',
        # 'storage/', üst düzey 'logs/' gibi KARDEŞ dizinler de dahil).
        domain_root="${WEB_ROOT}/${domain}"
        # FAIL-CLOSED: kilit ağacı güvenli biçimde kurulamıyorsa (ör. bir
        # bileşen sembolik bağ — bkz. core.sh:_reject_symlink) cron unit'i
        # YAZILMAZ. Eskiden dönüş değeri hiç kontrol edilmiyordu ve boş bir
        # lock_dir sessizce '/deploy-<sname>.lock' gibi anlamsız bir yola
        # (dolayısıyla ETKİSİZ bir deploy kilidine) dönüşürdü.
        lock_dir=$(_cron_lock_dir "$sname" "$web_user") \
            || error "Kilit dizini güvenli biçimde hazırlanamadı (yukarıdaki uyarıya bakın) — 'srvctl domain repair ${domain}' çalıştırın"
        [[ -n "$lock_dir" ]] \
            || error "Kilit dizini yolu hesaplanamadı: ${domain}"

        if command -v flock >/dev/null 2>&1; then
            local lock_path lock_escaped
            lock_path="${lock_dir}/deploy-${sname}.lock"
            lock_escaped=$(_cron_escape_percent "$(_cron_escape_unit_squote "$lock_path")")
            # Sondaki BOŞLUK KASITLI: FLOCK_PREFIX doluyken '/usr/bin/flock
            # ... <kilit-dosyası>' İLE '/bin/sh' arasını ayırır. '/usr/bin/
            # flock' MUTLAK yol OLARAK sabit — templates/apparmor/
            # profile-cli.tpl'İN whitelist'i de AYNI mutlak yolu ('/usr/bin/
            # flock rix,') bekler, bare 'flock' systemd'nin KENDİ arama
            # yoluna (PATH benzeri ama AYNI DEĞİL) bel bağlardı.
            flock_prefix="/usr/bin/flock -n -E 75 '${lock_escaped}' "
            info "Deploy kilidi entegrasyonu aktif: 'srvctl deploy ${domain}' sürerken bu cron ÇALIŞMAZ (çıkış kodu 75 ile sessizce atlanır, bildirim GÖNDERİLMEZ)."

            # AppArmor ön-kontrolü (koordinatör HOST bulgusu, İKİ katman —
            # bkz. yukarıdaki _cron_apparmor_flock_ok yorumu): "hiç profil
            # yok" (2) SESSİZCE geçilir, "profil var ama exec VE/YA DA kilit
            # dosyası izni eksik" (1) TEK bir mesajla UYARILIR (hangisinin
            # eksik olduğu ayırt edilmez — ikisi de AYNI 'domain repair'
            # komutuyla çözülür, ayrımın operatöre pratik faydası yok).
            local aa_rc=0
            _cron_apparmor_flock_ok "$sname" || aa_rc=$?
            if [[ "$aa_rc" -eq 1 ]]; then
                warn "AppArmor profili GÜNCEL DEĞİL: /etc/apparmor.d/srvctl-${sname}-cli 'flock' exec VE/YA DA deploy kilidi dosyası ('${lock_path}') izinlerinden birini İÇERMİYOR — bu cron çalıştığında 'Permission denied' (ör. 126) ile BAŞARISIZ OLUR. Düzeltme: 'srvctl domain repair ${domain}' (profili yeniden render edip AppArmor'a yeniden yükler), sonra 'srvctl cron run ${domain} ${name}' ile doğrulayın."
            fi

            # ── DÖRDÜNCÜ HOST BULGUSU (koordinatör, AYNI Ubuntu 24.04
            # domain, ÖNCEKİ ÜÇ katman — exec izni, AppArmor dosya kuralı,
            # DAC dizin modu — düzeltildikten SONRA ölçüldü): flock DAC VE
            # AppArmor'dan (complain modda BİLE) geçtiği HÂLDE 'Permission
            # denied' (çıkış 73) İLE düşmeye DEVAM ETTİ. Kök neden: cron
            # unit'i 'ProtectSystem=strict' kullanıyor — bu, TÜM dosya
            # sistemini salt-okunur mount eder; 'ReadWritePaths=' yalnız
            # AÇIKÇA listelenen yolları geri açar VE kilit dizini bu listede
            # YOKTU (yalnız DOMAIN_ROOT vardı). Düzeltme: şablona YENİ bir
            # LOCK_DIR token'ı eklendi (bkz. srvctl-cron.service.tpl TOKENS
            # envanteri) — STATİK doğrulama _cron_assert_readwrite_covers_lock
            # ile (render'dan hemen sonra, aşağıda), DİNAMİK (varsa GERÇEK
            # bir systemd-run probe'uyla) doğrulama ise burada, EKLEME
            # ANINDA, _cron_sandbox_probe_ok ile yapılır — koordinatörün
            # KENDİ teşhis tekniğinin (systemd-run A/B testi) 'cron add'e
            # taşınmış hâli. FAIL-SOFT: yalnız UYARIR, asla 'cron add'i
            # ENGELLEMEZ (bkz. o fonksiyonun DÜRÜSTLÜK NOTU — bu macOS
            # geliştirme makinesinde GERÇEK bir systemd-run çağrısı hiç
            # ÇALIŞTIRILAMADI/doğrulanamadı).
            local sandbox_rc=0
            _cron_sandbox_probe_ok "$domain_root" "$lock_dir" "$web_user" || sandbox_rc=$?
            if [[ "$sandbox_rc" -eq 1 ]]; then
                warn "systemd SANDBOX ön-kontrolü BAŞARISIZ: '${lock_dir}' bu unit'in 'ProtectSystem=strict' + 'ReadWritePaths=' sınırları İÇİNDE YAZILABİLİR DEĞİL (GERÇEK bir 'systemd-run' probe'uyla ölçüldü) — bu cron GERÇEK bir deploy kilidi çakışmasında 'Permission denied' (ör. 73) ile BAŞARISIZ OLABİLİR. Bu normalde bir srvctl KOD HATASINI gösterir (LOCK_DIR token'ı ReadWritePaths='e eksik besleniyor olabilir) — lütfen srvctl'i GÜNCEL sürüme yükseltin ya da bir hata bildirin."
            fi
        else
            warn "flock bulunamadı — bu cron deploy ile ÇAKIŞMAYA KARŞI KORUNMUYOR (lib/deploy.sh:_deploy_lock ile AYNI sınırlama)"
        fi
    fi

    local cron_command_final description_final
    cron_command_final=$(_cron_escape_percent "$(_cron_escape_unit_squote "$command")")
    description_final=$(_cron_escape_percent "$description")

    mkdir -p "$sysd_dir"
    local svc_file="${sysd_dir}/${svc_name}" timer_file="${sysd_dir}/${timer_name}"

    if [[ "$is_system" == "true" ]]; then
        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-syscron.service.tpl" \
            "CRON_NAME=${name}" "CRON_DESCRIPTION=${description_final}" \
            "CRON_COMMAND=${cron_command_final}" "RUNTIME_MAX=${timeout}" \
            > "$svc_file"
        _cron_assert_no_leftover_tokens "$svc_file"

        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-syscron.timer.tpl" \
            "CRON_NAME=${name}" "CRON_DESCRIPTION=${description_final}" \
            "ON_CALENDAR=${calendar}" "RANDOMIZED_DELAY=${CRON_DEFAULT_RANDOMIZED_DELAY}" \
            "CRON_PERSISTENT=${catchup}" \
            > "$timer_file"
        _cron_assert_no_leftover_tokens "$timer_file"
    else
        # web_user/working_dir/domain_root/lock_dir YUKARIDA (FLOCK_PREFIX
        # bloğunda) ZATEN hesaplandı — burada TEKRAR hesaplanmaz (drift
        # riski: iki ayrı hesaplama noktası kolayca birbirinden SAPAR;
        # bkz. o bloktaki NOT).
        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.service.tpl" \
            "SAFE_NAME=${sname}" "DOMAIN=${domain}" "WEB_USER=${web_user}" \
            "WORKING_DIR=${working_dir}" "CRON_NAME=${name}" \
            "CRON_DESCRIPTION=${description_final}" "CRON_COMMAND=${cron_command_final}" \
            "RUNTIME_MAX=${timeout}" "DOMAIN_ROOT=${domain_root}" \
            "LOCK_DIR=${lock_dir}" "FLOCK_PREFIX=${flock_prefix}" \
            > "$svc_file"
        _cron_assert_no_leftover_tokens "$svc_file"
        # DÖRDÜNCÜ HOST BULGUSU'nun STATİK yarısı (bkz. FLOCK_PREFIX
        # bloğundaki DİNAMİK 'systemd-run' probe'unun yorumu): render'dan
        # HEMEN SONRA, RENDER EDİLMİŞ dosyanın KENDİSİNDE LOCK_DIR'in
        # GERÇEKTEN 'ReadWritePaths='e ULAŞTIĞINI doğrular — bu bir
        # OPERATÖR/host koşulu DEĞİL, saf bir srvctl İÇ TUTARLILIK
        # denetimidir (token besleme/şablon DRIFT'i), bu yüzden
        # '_cron_assert_no_leftover_tokens' İLE AYNI ciddiyette FAIL-CLOSED
        # (dosyayı SİLER, hata verir) — bir sonraki koddaki bir hata bunu
        # SESSİZCE geçemez.
        _cron_assert_readwrite_covers_lock "$svc_file" "$lock_dir"

        render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-cron.timer.tpl" \
            "SAFE_NAME=${sname}" "DOMAIN=${domain}" "CRON_NAME=${name}" \
            "CRON_DESCRIPTION=${description_final}" "ON_CALENDAR=${calendar}" \
            "RANDOMIZED_DELAY=${CRON_DEFAULT_RANDOMIZED_DELAY}" \
            "CRON_PERSISTENT=${catchup}" \
            > "$timer_file"
        _cron_assert_no_leftover_tokens "$timer_file"

        [[ -d "$working_dir" ]] || warn "WorkingDirectory henüz yok: ${working_dir} (ilk 'srvctl deploy ${domain}' bekleniyor — timer tetiklendiğinde çalışmayabilir)"
    fi

    _cron_write_failure_hook "$sysd_dir" "$svc_name" "$fail_name" "$domain" "$name" "$is_system"
    _cron_write_sidecar "$sname" "$name" "$schedule" "$mode"

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$timer_name" >/dev/null 2>&1 || true

    success "Cron eklendi ve etkinleştirildi: ${name} (${timer_name})"
    log_action "CRON ADD: isim=${name} kapsam=${domain:---system} zamanlama='${schedule}' dilim=${tz_mode} -> ${calendar}"
}

# ═══════════════════════════════════════════════
#  cron list [<domain>|--system]
# ═══════════════════════════════════════════════
# Görev sözleşmesi ("cron list çıktısı: ad, açıklama, zaman, son çalışma,
# sonraki çalışma, son çıkış kodu, etkin/devre dışı") YEDİ alanı gerektirir —
# bu, tek satırlık bir tabloya SIĞDIRILAMAYACAK kadar geniştir (okunaklılık
# kaybı). Bunun yerine cron başına ÇOK SATIRLI, kompakt bir blok basılır
# (domain_list'in tek-satır tablo desenine göre bu veri hacmi için daha
# uygun — 'git log' ile 'git log --oneline' farkına benzer bir karar).
# Bilinmeyen alan HER ZAMAN 'bilinmiyor' basar, ASLA UYDURULMAZ.
_cron_print_row() {
    local sname="$1" name="$2" domain_display="$3"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc timer scope_col
    svc=$(_cron_svc_name "$sname" "$name")
    timer=$(_cron_timer_name "$sname" "$name")
    if [[ -z "$sname" ]]; then scope_col="sistem"; else scope_col="$domain_display"; fi

    # 'Description=' satırının TAMAMI DEĞİL, yalnız KULLANICININ yazdığı kısım
    # (bkz. _cron_desc_user_part — GERÇEK üretimde ölçülen görüntüleme kusuru).
    local description desc_user
    description=$(grep -m1 '^Description=' "${sysd_dir}/${svc}" 2>/dev/null | cut -d= -f2-)
    desc_user=$(_cron_desc_user_part "$description")

    # ZAMAN DİLİMİ — tek doğruluk kaynağı .timer dosyasının KENDİSİ (sidecar
    # DEĞİL): varsayılan değişse bile diskte duran ESKİ (' UTC' sonekli)
    # unit'ler AYNEN çalışmaya devam eder ve burada AÇIKÇA işaretlenir.
    local on_calendar tz_note
    on_calendar=$(grep -m1 '^OnCalendar=' "${sysd_dir}/${timer}" 2>/dev/null | cut -d= -f2-)
    tz_note=$(_cron_schedule_tz_note "$on_calendar")
    if [[ "$(_cron_calendar_tz_suffix "$on_calendar")" == "UTC" ]]; then
        _CRON_UTC_SEEN=$(( _CRON_UTC_SEEN + 1 ))
    fi

    local raw=""
    local sidecar_dir
    sidecar_dir=$(_cron_sidecar_dir "$sname")
    if [[ -f "${sidecar_dir}/${name}.conf" ]]; then
        local SCHEDULE_RAW=""
        read_kv_file "${sidecar_dir}/${name}.conf" SCHEDULE_RAW
        raw="$SCHEDULE_RAW"
    fi

    local enabled exitc last_run next_run
    enabled=$(_cron_is_enabled "$timer")
    exitc=$(_cron_unit_prop "$svc" ExecMainStatus); exitc="${exitc:-bilinmiyor}"
    last_run=$(_cron_last_run "$svc")
    next_run=$(_cron_next_run "$timer")

    # Ham çıkış kodu operatöre HİÇBİR ŞEY anlatmıyordu (126 = "AppArmor bir
    # ikiliyi engelledi" bilgisi hiçbir yerde görünmüyordu) — teşhis metni
    # TEK kaynaktan (_cron_exit_hint) gelir.
    local hint
    hint=$(_cron_exit_hint "$exitc" "$(_cron_cli_profile "$sname")")

    echo -e "  ${BOLD}${name}${NC}  ${DIM}[${scope_col}]${NC}  (${enabled})"
    echo "    Açıklama       : ${desc_user:-bilinmiyor}"
    echo "    Zaman          : ${raw:-bilinmiyor}"
    echo "    Zaman dilimi   : ${tz_note}"
    echo "    Son çalışma    : ${last_run}"
    echo "    Sonraki çalışma: ${next_run}"
    if [[ -n "$hint" ]]; then
        echo "    Son çıkış kodu : ${exitc}  — ${hint}"
    else
        echo "    Son çıkış kodu : ${exitc}"
    fi
}

_cron_list() {
    local filter="${1:-}"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"

    # ESKİ (' UTC' sonekli) cron sayacı — _cron_print_row tarafından artırılır.
    # Modül düzeyi değişken KASITLI: satırlar AYNI kabukta basılır (subshell
    # YOK), bu yüzden sayaç dışarı sızar; her 'cron list' çağrısında SIFIRLANIR.
    _CRON_UTC_SEEN=0

    echo ""
    echo -e "  ${BOLD}Cron Görevleri${NC}  ${DIM}(sunucu saat dilimi: $(_cron_tz_display))${NC}"
    divider

    local count=0
    local f base rest sname name domain_display

    if [[ -z "$filter" || "$filter" == "--system" ]]; then
        for f in "${sysd_dir}"/srvctl-syscron-*.service; do
            [[ -e "$f" ]] || continue
            base=$(basename "$f" .service)
            name="${base#srvctl-syscron-}"
            _cron_print_row "" "$name" "--system"
            divider
            count=$((count + 1))
        done
    fi

    if [[ "$filter" != "--system" ]]; then
        if [[ -n "$filter" ]]; then
            domain_exists "$filter" || error "Domain bulunamadı: ${filter}"
            sname=$(safe_name "$filter")
            for f in "${sysd_dir}/srvctl-cron-${sname}-"*.service; do
                [[ -e "$f" ]] || continue
                base=$(basename "$f" .service)
                name="${base#srvctl-cron-"${sname}"-}"
                _cron_print_row "$sname" "$name" "$filter"
                divider
                count=$((count + 1))
            done
        else
            for f in "${sysd_dir}"/srvctl-cron-*.service; do
                [[ -e "$f" ]] || continue
                base=$(basename "$f" .service)
                rest="${base#srvctl-cron-}"
                sname="${rest%%-*}"
                name="${rest#*-}"
                if ! domain_display=$(_cron_domain_from_sname "$sname"); then
                    domain_display="(${sname})"
                fi
                _cron_print_row "$sname" "$name" "$domain_display"
                divider
                count=$((count + 1))
            done
        fi
    fi

    echo "  Toplam: ${count} cron"
    # GÖÇ GÖRÜNÜRLÜĞÜ: srvctl'in ESKİ varsayılanıyla (' UTC' soneki) kurulmuş
    # cron'lar OLDUĞU GİBİ çalışmaya devam eder — srvctl onları ASLA yeniden
    # yazmaz. Ama operatörün saat farkını FARK ETMESİ için sayıları burada
    # ÖZETLENİR (yukarıda her satırın "Zaman dilimi" alanında yerel karşılığı
    # zaten tek tek gösterildi).
    if (( _CRON_UTC_SEEN > 0 )); then
        echo ""
        echo "  Not: ${_CRON_UTC_SEEN} cron UTC'ye SABİTLENMİŞ (srvctl'in ESKİ varsayılanı ya da"
        echo "  '--utc' bayrağı). Zamanlamaları DEĞİŞTİRİLMEDİ; yerel karşılıkları yukarıda"
        echo "  'Zaman dilimi' satırında gösteriliyor. Yerel saate taşımak isterseniz:"
        echo "  'srvctl cron remove <kapsam> <ad>' + 'srvctl cron add ...' ('--utc' VERMEDEN)."
    fi
    echo ""
}

# ═══════════════════════════════════════════════
#  cron show <domain>|--system <ad>
# ═══════════════════════════════════════════════
_cron_show() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron show <domain>|--system <ad>"

    local sname="" scope_label domain=""
    if [[ "$scope_arg" == "--system" ]]; then
        scope_label="sistem geneli"
    else
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
        scope_label="domain: ${domain}"
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc timer
    svc=$(_cron_svc_name "$sname" "$name")
    timer=$(_cron_timer_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc}" ]] || error "Cron bulunamadı: ${name} (${scope_label})"

    local description desc_user on_calendar persistent tz_note
    description=$(grep -m1 '^Description=' "${sysd_dir}/${svc}" 2>/dev/null | cut -d= -f2-)
    # systemd önekini SOY — operatörün yazdığı açıklama gösterilir (bkz.
    # _cron_desc_user_part).
    desc_user=$(_cron_desc_user_part "$description")
    on_calendar=$(grep -m1 '^OnCalendar=' "${sysd_dir}/${timer}" 2>/dev/null | cut -d= -f2-)
    # Dilim ASLA belirsiz kalmaz: .timer dosyasındaki İFADENİN KENDİSİNDEN
    # okunur, UTC'ye sabitlenmişse yerel karşılığı da basılır.
    tz_note=$(_cron_schedule_tz_note "$on_calendar")
    # CRON_PERSISTENT (koordinatör talebi): operatörün bilmesi gereken bir
    # DAVRANIŞ ("kaçan çalışma açılışta telafi edilir mi?") — .timer
    # dosyasının KENDİSİNDEN okunur (tek doğruluk kaynağı, sidecar'da AYRICA
    # tutulmaz).
    persistent=$(grep -m1 '^Persistent=' "${sysd_dir}/${timer}" 2>/dev/null | cut -d= -f2-)

    local raw="" created=""
    local sidecar_dir
    sidecar_dir=$(_cron_sidecar_dir "$sname")
    if [[ -f "${sidecar_dir}/${name}.conf" ]]; then
        local SCHEDULE_RAW="" CREATED_AT=""
        read_kv_file "${sidecar_dir}/${name}.conf" SCHEDULE_RAW CREATED_AT
        raw="$SCHEDULE_RAW"; created="$CREATED_AT"
    fi

    header "Cron: ${name}"
    echo "  Kapsam           : ${scope_label}"
    echo "  Açıklama         : ${desc_user:-bilinmiyor}"
    echo "  Girilen zamanlama: ${raw:-bilinmiyor}"
    echo "  OnCalendar       : ${on_calendar:-bilinmiyor}"
    echo "  Zaman dilimi     : ${tz_note}"
    echo "  Sunucu dilimi    : $(_cron_tz_display)"
    echo "  Kaçan çalışma    : $([[ "$persistent" == "true" ]] && echo "AÇILIŞTA telafi edilir (--catch-up-on-boot)" || echo "telafi edilmez (crontab-parity varsayılanı)")"
    echo "  Oluşturma        : ${created:-bilinmiyor}"
    echo "  Etkin mi         : $(_cron_is_enabled "$timer")"
    echo "  Aktif durum      : $(_cron_active_state "$svc")"
    echo "  Son çalışma      : $(_cron_last_run "$svc")"
    echo "  Sonraki çalışma  : $(_cron_next_run "$timer")"
    echo "  Son çıkış kodu   : $(_cron_last_exit "$svc")"
    # 126/127/75 gibi kodların ANLAMI (TEK kaynak — bkz. _cron_exit_hint).
    local last_code hint
    last_code=$(_cron_unit_prop "$svc" ExecMainStatus)
    hint=$(_cron_exit_hint "${last_code:-}" "$(_cron_cli_profile "$sname")")
    if [[ -n "$hint" ]]; then
        echo "  Teşhis           : ${hint}"
    fi
    if [[ -n "$domain" ]]; then
        echo "  Loglar           : srvctl cron logs ${domain} ${name}"
    else
        echo "  Loglar           : srvctl cron logs --system ${name}"
    fi
    echo ""
}

# ═══════════════════════════════════════════════
#  cron run <domain>|--system <ad>   (şimdi bir kez çalıştır — test)
# ═══════════════════════════════════════════════
_cron_run() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron run <domain>|--system <ad>"

    local sname="" domain=""
    if [[ "$scope_arg" != "--system" ]]; then
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc
    svc=$(_cron_svc_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc}" ]] || error "Cron bulunamadı: ${name}"

    info "Şimdi çalıştırılıyor (test): ${svc} ..."
    systemctl start "$svc" 2>/dev/null || true
    local code logs_target
    code=$(_cron_unit_prop "$svc" ExecMainStatus)
    logs_target="--system"; [[ -n "$domain" ]] && logs_target="$domain"
    if [[ "$code" == "0" ]]; then
        success "Çalıştırıldı, çıkış kodu: 0"
    else
        # Ham kod yerine ANLAMLI teşhis (TEK kaynak — bkz. _cron_exit_hint).
        local hint
        hint=$(_cron_exit_hint "${code:-}" "$(_cron_cli_profile "$sname")")
        if [[ -n "$hint" ]]; then
            warn "Çalıştırıldı, çıkış kodu: ${code:-bilinmiyor} — ${hint}. Ayrıntı: srvctl cron logs ${logs_target} ${name}"
        else
            warn "Çalıştırıldı, çıkış kodu: ${code:-bilinmiyor} — ayrıntı: srvctl cron logs ${logs_target} ${name}"
        fi
    fi
    log_action "CRON RUN (manuel test): ${name} (${svc}) exit=${code:-bilinmiyor}"
}

# ═══════════════════════════════════════════════
#  cron enable|disable <domain>|--system <ad>
# ═══════════════════════════════════════════════
_cron_set_enabled() {
    local want_enabled="$1" scope_arg="${2:-}" name="${3:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron enable|disable <domain>|--system <ad>"

    local sname="" domain=""
    if [[ "$scope_arg" != "--system" ]]; then
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local timer
    timer=$(_cron_timer_name "$sname" "$name")
    [[ -e "${sysd_dir}/${timer}" ]] || error "Cron bulunamadı: ${name}"

    if [[ "$want_enabled" == "true" ]]; then
        systemctl enable --now "$timer" >/dev/null 2>&1 || true
        success "Etkinleştirildi: ${name}"
        log_action "CRON ENABLE: ${name} (${timer})"
    else
        systemctl disable --now "$timer" >/dev/null 2>&1 || true
        success "Devre dışı bırakıldı: ${name}"
        log_action "CRON DISABLE: ${name} (${timer})"
    fi
}

# ═══════════════════════════════════════════════
#  cron remove <domain>|--system <ad>
# ═══════════════════════════════════════════════
_cron_remove() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron remove <domain>|--system <ad>"

    local sname="" domain="" scope_label
    if [[ "$scope_arg" == "--system" ]]; then
        scope_label="sistem geneli"
    else
        domain="$scope_arg"
        domain_exists "$domain" || error "Domain bulunamadı: ${domain}"
        sname=$(safe_name "$domain")
        scope_label="domain: ${domain}"
    fi

    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc timer fail
    svc=$(_cron_svc_name "$sname" "$name")
    timer=$(_cron_timer_name "$sname" "$name")
    fail=$(_cron_fail_svc_name "$sname" "$name")
    [[ -e "${sysd_dir}/${svc}" || -e "${sysd_dir}/${timer}" ]] || error "Cron bulunamadı: ${name} (${scope_label})"

    if ! confirm "'${name}' (${scope_label}) cron'u kalıcı olarak silinsin mi?"; then
        info "İptal edildi."
        return 0
    fi

    systemctl disable --now "$timer" >/dev/null 2>&1 || true
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable --now "$fail" >/dev/null 2>&1 || true

    rm -f -- "${sysd_dir}/${timer}" "${sysd_dir}/${svc}" "${sysd_dir}/${fail}"
    rm -rf -- "${sysd_dir}/${svc}.d"
    rm -f -- "$(_cron_sidecar_dir "$sname")/${name}.conf"

    systemctl daemon-reload >/dev/null 2>&1 || true

    success "Cron silindi: ${name} (${scope_label})"
    log_action "CRON REMOVE: ${name} (${scope_label})"
}

# ═══════════════════════════════════════════════
#  cron logs <domain>|--system <ad> [-n N]
# ═══════════════════════════════════════════════
_cron_logs() {
    local scope_arg="${1:-}" name="${2:-}"
    [[ -n "$scope_arg" && -n "$name" ]] || error "Kullanım: srvctl cron logs <domain>|--system <ad> [-n N]"

    local n=50
    local -a rest=("${@:3}")
    local idx=0 a
    while (( idx < ${#rest[@]} )); do
        a="${rest[$idx]}"
        case "$a" in
            -n)
                idx=$((idx + 1))
                n="${rest[$idx]:-50}"
                ;;
            -n*)
                n="${a#-n}"
                ;;
        esac
        idx=$((idx + 1))
    done
    validate_uint "$n" 100000 || n=50

    local sname=""
    if [[ "$scope_arg" != "--system" ]]; then
        domain_exists "$scope_arg" || error "Domain bulunamadı: ${scope_arg}"
        sname=$(safe_name "$scope_arg")
    fi
    local svc
    svc=$(_cron_svc_name "$sname" "$name")

    # Journal satırları 126'nın SEBEBİNİ göstermez (AppArmor bu reddi SESSİZ
    # yapar — 'DENIED' kaydı bile ÜRETİLMEZ). Bu yüzden logların ÜSTÜNE, son
    # çıkış kodunun ANLAMI stderr'e basılır (stdout SALT journal çıktısı
    # kalsın — 'srvctl cron logs ... | grep' bozulmasın).
    local last_code hint
    last_code=$(_cron_unit_prop "$svc" ExecMainStatus)
    hint=$(_cron_exit_hint "${last_code:-}" "$(_cron_cli_profile "$sname")")
    if [[ -n "$hint" ]]; then
        warn "Son çıkış kodu ${last_code}: ${hint}"
    fi

    command -v journalctl >/dev/null 2>&1 || error "journalctl bulunamadı — loglar okunamıyor"
    journalctl -u "$svc" -n "$n" --no-pager
}
