# TOKENS: (yok) — bu dosya render_template İLE İŞLENMEZ; lib/init.sh
# _install_modsecurity tarafından DÜZ 'cp' ile /etc/nginx/modsec/main.conf'a
# kopyalanır (bkz. lib/init.sh:1081). Buraya çift-küme-parantezli bir yer
# tutucu eklenirse SESSİZCE olduğu gibi diske yazılır — render_template
# kullanılmadığından assert_regex_safe/assert_safe_ident kapısı da DEVREDE
# DEĞİLDİR. Bu dosyaya yer tutucu eklemeyin; ihtiyaç varsa önce
# render_template akışına geçirin.
#
# ═══════════════════════════════════════════════
#  ModSecurity Ana Yapılandırma
#  OWASP Core Rule Set (CRS) ile WAF
# ═══════════════════════════════════════════════

SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off

# ─── Request Body ───
SecRequestBodyLimit 52428800
SecRequestBodyNoFilesLimit 131072
SecRequestBodyLimitAction Reject

# ─── Temp/Data dizinleri ───
# GÜVENLİK (O5 — DALGA 5): /tmp/modsecurity yerine /var/lib/modsecurity.
# /tmp 1777 olduğundan bu dizinler lib/init.sh çalışmadan ÖNCE herhangi bir
# yerel kullanıcı tarafından (kendi sahipliğinde, kendi seçtiği modda, ör.
# 0777) önceden yerleştirilebiliyordu; sonraki chown SAHİPLİĞİ değiştirir ama
# MODU değiştirmez → dizin dünya-yazılabilir kalabiliyordu. Bu üç yönerge
# TÜM domainlerin WAF tarafından tutulan istek gövdesi/upload artefaktlarını
# içerdiğinden (tek paylaşılan ModSecurity örneği — domain başına değil) bu
# çapraz-kiracı okuma/yazma ve WAF artefaktı manipülasyonu anlamına geliyordu.
# /var/lib altında (root:root 755) önceden-yerleştirme saldırısı mümkün
# değildir — alt dizini yalnızca root oluşturabilir. Dizinlerin kendisi
# lib/init.sh tarafından root:www-data 0750 olarak oluşturulur/sıkılaştırılır
# (bu şablon sadece yolu referans eder, dizini OLUŞTURMAZ).
SecTmpDir /var/lib/modsecurity/tmp
SecDataDir /var/lib/modsecurity/data
SecUploadDir /var/lib/modsecurity/upload
# SecUploadKeepFiles Off (bilinçli karar — bkz. DALGA 5 raporu): yakalanan
# multipart/form-data dosyaları hiçbir zaman kalıcı olarak SecUploadDir'de
# TUTULMAZ. "RelevantOnly" (yalnız kural ihlali eden istekler) bile disk
# üzerinde başka bir domain'e ait ham dosya içeriğini bırakabileceğinden ve
# bu tek paylaşılan dizin TÜM domainler arasında ortak olduğundan, en dar
# yüzey "Off"tur. Adli inceleme/forensics ihtiyacı varsa SecAuditLogParts'a
# zaten 'F' (response body) yerine mevcut 'ABIJDEFHZ' seti + audit log
# yeterli iz bırakıyor; ayrıca ham dosya saklamak GDPR/KVKK açısından da ek
# bir veri saklama yükümlülüğü doğurur.
SecUploadKeepFiles Off

# ─── Audit Log ───
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsecurity-audit.log
SecAuditLogParts ABIJDEFHZ

# ─── Debug Log (üretimde kapalı) ───
SecDebugLog /var/log/nginx/modsecurity-debug.log
SecDebugLogLevel 0

# ─── Varsayılan Kurallar ───
SecRule REQUEST_HEADERS:Content-Type "(?:application(?:/soap\+|/)|text/)xml" \
    "id:200000,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=XML"
SecRule REQUEST_HEADERS:Content-Type "application/json" \
    "id:200001,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=JSON"

# ─── OWASP CRS Yükle ───
Include /etc/nginx/owasp-crs/crs-setup.conf
Include /etc/nginx/owasp-crs/rules/*.conf

# ─── Özel Kurallar (False Positive Temizliği) ───
# CI4 CSRF token uzun olabilir
SecRule REQUEST_HEADERS:Content-Type "application/x-www-form-urlencoded" \
    "id:200010,phase:1,t:none,nolog,pass,ctl:requestBodyProcessor=URLENCODED"

# CI4 admin: yalnız bilinen yanlış-pozitif XSS kuralı (941160 — zengin-metin
# alanlarında HTML-injection checker). XSS ailesinin (941xxx) geri kalanı /admin/
# için de AKTİF kalır; operatör ihtiyaca göre ek ID ekleyebilir.
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:200020,phase:1,t:none,nolog,pass,ctl:ruleRemoveById=941160"
