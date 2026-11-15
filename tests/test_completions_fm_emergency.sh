#!/bin/bash
# QL6-M1 (a1 ARAYÜZ notu): `fm-auth <alan> off --emergency` bayrağı tamamlamada ve `domain help`te görünür; ayrıca
# fm-root tamamlama açıklamasındaki "tek nginx -t + tek reload" üst sınırı koşullu (QL6-L6).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
BASH_C="$(cat "${REPO_ROOT}/completions/srvctl.bash")"
ZSH_C="$(cat "${REPO_ROOT}/completions/srvctl.zsh")"
assert_contains "$BASH_C" 'compgen -W "--script= --region= --force --dry --emergency"' "bash tamamlama: fm-auth --emergency"
assert_contains "$ZSH_C" "'--emergency:" "zsh tamamlama: fm-auth --emergency"
assert_contains "$ZSH_C" "--apply: yazım gerekirse tek nginx -t + tek reload" "zsh tamamlama: fm-root açıklaması koşullu (L6)"
H=$(
  set +e
  source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
  require_root() { :; }
  source "${REPO_ROOT}/lib/domain.sh" >/dev/null 2>&1
  cmd_domain help 2>&1
)
assert_contains "$H" "[--emergency]  (yalnız off: ACİL kapatma" "domain help: --emergency anlatılıyor"
assert_contains "$H" "'FM HÂLÂ AÇIK' + çıkış 3/4/5/6" "domain help: gerçek durum + acil çıkış kodları (3/4/5/6; 6 = işaret yazılamadı)"
assert_eq "$(grep -cE '^[[:space:]]+rc=6[[:space:]]*$' "${REPO_ROOT}/lib/domconf.sh")" "1" "kod (yorum değil, tek atama satırı): domain help'in vadettiği çıkış 6 gerçekten atanıyor (acil işaret yazılamadı)"
# kod bayrağı gerçekten tanıyor (belge↔kod)
assert_contains "$(cat "${REPO_ROOT}/lib/domconf.sh")" "--emergency) emergency=1" "kod: --emergency ayrıştırılıyor"
# bash tamamlama sözdizimi geçerli ve fm-auth'ta --emergency öneriyor (gerçek çalıştırma)
out=$(bash -c '
  source "$1/completions/srvctl.bash"
  COMP_WORDS=(srvctl domain fm-auth example.com off --em); COMP_CWORD=5
  _srvctl_completions
  printf "%s\n" "${COMPREPLY[@]}"' _ "$REPO_ROOT" 2>&1)
assert_eq "$out" "--emergency" "bash tamamlama gerçek çalıştırma: 'off --em' → --emergency"
# ── QL7-M6: zsh tamamlama GERÇEKTEN koşturulur (alt dize araması bir satırın yorumda kalmasını yakalamaz — QL7 mutantı Q7) ──
# `zsh -f` (kullanıcı rc'si yok) + taklit `_arguments`/`_describe`/`compdef`: dosya source edilir (son satırı `_srvctl`i
# çağırır), `words` önceden kurulur, `_describe`ın verdiği SEÇENEK listesi yazdırılır. zsh yoksa test bu bölümü
# GEREKÇELİ atlar (macOS'ta /bin/zsh var; Ubuntu CI'da zsh kurulu değilse atlanır, sessizce geçmez: SKIP satırı basılır).
zsh_describe() {   # $@ = words dizisi → "DESCRIBE <başlık>" + her giriş ayrı satır
    zsh -f -c '
      compdef() { :; }
      _arguments() { state=args; return 0; }
      _describe() { print -r -- "DESCRIBE $1"; local a; for a in "${(@P)2}"; do print -r -- "ENTRY $a"; done; }
      words=("$@")
      source "$ZSHC"
    ' _ "$@" 2>&1
}
if command -v zsh >/dev/null 2>&1; then
    export ZSHC="${REPO_ROOT}/completions/srvctl.zsh"
    assert_eq "$(zsh -fn "$ZSHC" 2>&1; echo "rc=$?")" "rc=0" "zsh sözdizimi geçerli (zsh -n)"
    Z=$(zsh_describe domain fm-auth example.com off)
    assert_contains "$Z" "DESCRIBE domain fm-auth seçeneği" "zsh gerçek çalıştırma: fm-auth seçenek listesine ulaşıldı (ön koşul)"
    assert_contains "$Z" "ENTRY --emergency:ACİL kapat" "zsh gerçek çalıştırma: '--emergency' tamamlama girdisi ÜRETİLİYOR"
    assert_contains "$Z" "ENTRY --force:" "zsh gerçek çalıştırma: kontrol girdisi (--force) de üretiliyor (liste boş değil)"
    ZR=$(zsh_describe domain fm-root --all example.com)
    assert_contains "$ZR" "DESCRIBE domain fm-root seçeneği" "zsh gerçek çalıştırma: fm-root seçeneklerine ulaşıldı"
    assert_contains "$ZR" "ENTRY --apply:Uygula (tek kilit, tek nginx -t → hata: hepsi geri, tek reload)" "zsh gerçek çalıştırma: fm-root --apply girdisi"
else
    echo "  SKIP zsh bulunamadı: zsh tamamlama gerçek çalıştırma testleri atlandı (GEREKÇE: koşturulacak yorumlayıcı yok; alt dize kilidi yukarıda yine çalışır)"
fi
test_summary
