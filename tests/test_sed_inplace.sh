#!/bin/bash
# _sed_inplace: KARAR 2 (denetim DALGA 4) — atomik/portable 'sed -i' sarmalayıcısı.
#
# Eski kod: 26+ çıplak 'sed -i' (GNU-only) + 1 adet 'sed -i.bak' (sır içeren
# '.credentials.bak'/'sshd_config.bak' gibi kalıcı yedek dosyaları bırakıyordu
# — yedek/exclude listeleri bunları BİLMİYORDU). Ayrıca GNU 'sed -i' bile
# atomik DEĞİLDİR (bazı durumlarda yerinde truncate+write) — eşzamanlı okunan
# dosyalarda (users.acl/sshd_config) yarım-yazılmış içerik riski taşırdı; ve
# eski 'sed -i.bak ... && rm' zincirinin dönüş değeri HİÇ kontrol edilmiyordu
# (H5) — sed başarısız olsa bile orijinal sessizce '.bak'a devredilmiş
# sayılabiliyordu.
#
# Bu test: (1) mod/sahiplik korunuyor mu, (2) '.bak'/geçici dosya ARTIĞI
# bırakmıyor mu, (3) sed başarısızsa ORİJİNAL bozulmuyor mu (içerik + mod),
# (4) 'atomik' iddiası — başarı yolunda dosyanın inode'u DEĞİŞİR (yerinde
# truncate+write DEĞİL, 'mv' ile değiştirme).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# Portable inode okuyucu (yalnız bu testin GÖZLEMİ için — core.sh helper'ı
# DEĞİL; _stat_mode/_stat_owner/_stat_group projenin GERÇEK portable
# sarmalayıcıları, onlar zaten aşağıda kullanılıyor).
_inode_of() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }

work="${WEB_ROOT}/work"
mkdir -p "$work"

# ─── (1) + (4): mod/sahiplik korunuyor, atomik (inode değişiyor) ───
f1="${work}/conf1.txt"
printf 'foo=eski\nbar=degismez\n' > "$f1"
chmod 640 "$f1"
before_mode="$(_stat_mode "$f1")"
before_inode="$(_inode_of "$f1")"

_sed_inplace "$f1" -e 's/foo=eski/foo=yeni/'
rc=$?

assert_eq "$rc" "0" "_sed_inplace: başarılı sed rc=0 döner"
assert_eq "$(cat "$f1")" "$(printf 'foo=yeni\nbar=degismez\n')" "_sed_inplace: içerik doğru değiştirildi"
assert_eq "$(_stat_mode "$f1")" "$before_mode" "_sed_inplace: dosya modu korundu (640)"

after_inode="$(_inode_of "$f1")"
_inode_changed() { [[ "$1" != "$2" ]] && echo degisti || echo aynı; }
assert_eq "$(_inode_changed "$before_inode" "$after_inode")" "degisti" \
    "_sed_inplace: atomik değiştirme — inode değişti (yerinde truncate+write DEĞİL, mv ile)"

# ─── (2): .bak / geçici dosya artığı YOK ───
leftover=$(find "$work" -maxdepth 1 -type f \( -name '*.bak' -o -name '*.srvctl.*' \) 2>/dev/null)
assert_eq "$leftover" "" "_sed_inplace: '.bak' veya geçici '.srvctl.*' artığı bırakmadı"

# ─── (3): sed başarısızsa ORİJİNAL bozulmaz ───
f2="${work}/conf2.txt"
printf 'kritik=veri\n' > "$f2"
chmod 600 "$f2"
before_content2="$(cat "$f2")"
before_mode2="$(_stat_mode "$f2")"

# Kasıtlı olarak geçersiz sed script'i (kapanmamış 's' komutu) — sed
# non-zero ile başarısız olmalı.
_sed_inplace "$f2" -e 's/kritik' >/dev/null 2>&1
rc2=$?

assert_eq "$rc2" "1" "_sed_inplace: geçersiz sed script'inde 1 döner"
assert_eq "$(cat "$f2")" "$before_content2" "_sed_inplace: sed başarısızsa ORİJİNAL içerik bozulmadı"
assert_eq "$(_stat_mode "$f2")" "$before_mode2" "_sed_inplace: sed başarısızsa ORİJİNAL mod bozulmadı"

leftover2=$(find "$work" -maxdepth 1 -type f \( -name '*.bak' -o -name '*.srvctl.*' \) 2>/dev/null)
assert_eq "$leftover2" "" "_sed_inplace: başarısızlıkta da geçici dosya artığı kalmadı"

# ─── Var olmayan dosya: fail-closed, exit YOK (predikat gibi davranır) ───
assert_fail _sed_inplace "${work}/yok_boyle_bir_dosya" -e 's/a/b/'

rm -rf "$WEB_ROOT"
test_summary
