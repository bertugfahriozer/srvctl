#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9d/dev — test_domconf_fm_f9d_double_bk{,_more}.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, harness_safe.sh, lib/domconf.sh, lib/domain.sh, fm_f9c_common.sh'yi source eder, sonra bunu.
_md5stdin() { if command -v md5sum >/dev/null 2>&1; then md5sum | cut -d' ' -f1; else md5 -q; fi; }
# Yedeklerin parmak izi: her .bk.* altındaki yol + içerik md5 + mod (dizinse 'dir'); ayrıca kayıt dizinindeki TÜM .bk/.superseded adları.
bkhash() {
    local p
    ( cd "$SD" 2>/dev/null || exit 0
      find . -name '.bk.*' | LC_ALL=C sort | while IFS= read -r p; do
          if [[ -f "$p" ]]; then printf '%s %s %s\n' "$p" "$(_md5 "$p")" "$(_mode "$p")"; else printf '%s dir\n' "$p"; fi
      done | _md5stdin )
}
bknames() { ( cd "$SD" 2>/dev/null && find . -maxdepth 1 -name '.*bk.*' | LC_ALL=C sort | tr '\n' ' ' ); }
snap() { printf '%s|%s' "$(bkhash)" "$(bknames)"; }
_off() { ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; }
_status() { ( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; }
mk2() { _mk_stale_bk AAAAAA; _mk_stale_bk BBBBBB; fm_sim_reload; }
diskfp() { printf '%s|%s|%s|%s' "$(_md5 "$MAN")" "$([[ -e $F90 ]] && _md5 "$F90" || echo -)" "$([[ -e $F21 ]] && _md5 "$F21" || echo -)" "$([[ -e $F20 ]] && _md5 "$F20" || echo -)"; }

# Senaryo kurulumu (HER ZAMAN tam iki yarım-işlem yedeği AAAAAA + BBBBBB)
setup() {
    reset_all
    case "$1" in
        K0)            _on; mk2 ;;                                                                  # kayıt on, üç eser sağlam (sınıf 0)
        K4_90)         _on; printf '# kurcalandi\n' >> "$F90"; mk2 ;;                               # sınıf 4: 90 kurcalanmış
        K4_21)         _on; rm -f "$F21"; mk2 ;;                                                    # sınıf 4: 21 eksik
        K4_20)         _on; printf 'return 200 "kullanici";\n' > "$F20"; chmod 644 "$F20"; mk2 ;;   # sınıf 4: 20 tanınmıyor (21/90 sağlam)
        KOFF)          _on; _off; mk2 ;;                                                            # kayıt off + kapalı kök (zaten kapalı)
        KOFF_OPENDISK) _on; cp -p "$F90" "${FM_STUBS}/s90"; cp -p "$F21" "${FM_STUBS}/s21"; _off
                       cp -p "${FM_STUBS}/s90" "$F90"; cp -p "${FM_STUBS}/s21" "$F21"; mk2 ;;       # kayıt off ama 90/21 diskte
        KNOREC_EMPTY)  _on; mk2; rm -f "$MAN" "$F90" "$F21" "$F20"; fm_sim_reload ;;                # kayıt yok, disk boş
        KNOREC_OPEN)   _on; mk2; rm -f "$MAN"; fm_sim_reload ;;                                     # kayıt yok ama 90/21/20 diskte
    esac
}
# php-switch yalnız soket yazacağı zaman kurtarmaya girer (sınıf 4 ya da kayıt on + PHP kayması): diğer senaryolarda no-op (BELGELİ SINIR).
phpswitch_enters() { case "$1" in K0|K4_90|K4_21|K4_20) return 0 ;; *) return 1 ;; esac; }

