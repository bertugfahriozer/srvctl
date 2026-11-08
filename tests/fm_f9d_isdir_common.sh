#!/bin/bash
# shellcheck disable=SC2034,SC2120,SC2317,SC2329  # fm_env.sh bayrakları; yardımcılar isteğe bağlı argüman alır; işlevler dolaylı çağrılır
# F9d/dev — test_domconf_fm_f9d_isdir_loud{,_off}.sh için ORTAK yardımcılar (çalıştırılabilir test DEĞİLDİR: tests/run.sh yalnız test_*.sh koşar).
# Çağıran test önce fm_env.sh, harness_safe.sh, lib/domconf.sh, lib/domain.sh, fm_f9c_common.sh'yi source eder, sonra bunu.
# ARCHITECTURE §15/43(a): 20/21/90 yerinde DİZİN iken kapatma yolları yüksek sesle başarısız olur (ayrıntı: test_domconf_fm_f9d_isdir_loud.sh).
_off() { ( _domconf_fm_auth example.com off ) >"$OUTF" 2>&1; }
_status() { ( _domconf_fm_auth example.com status ) >"$OUTF" 2>&1; }
# Gerçek nginx gibi: custom.d/*.conf glob'unda DİZİN varsa pread() EISDIR ile 'nginx -t' düşer.
_ngx_isdir_hook() {
    local f
    for f in "${CUR_DIR}"/*.conf; do
        if [[ -d "$f" ]]; then NGINX_TEST_RC=1; NGINX_T_MSG="nginx: [emerg] pread() \"${f}\" failed (21: Is a directory)"; fi
    done
}
listing() { ( cd "$CUR_DIR" && find . | LC_ALL=C sort | tr '\n' ' ' ); }
mkdirs() {   # <hedef: 90|21|both|20>: ilgili adı DİZİN yapar
    case "$1" in
        90)   rm -f "$F90"; mkdir "$F90" ;;
        21)   rm -f "$F21"; mkdir "$F21" ;;
        both) rm -f "$F90" "$F21"; mkdir "$F90" "$F21" ;;
        20)   rm -f "$F20"; mkdir "$F20" ;;
    esac
}
fp() { printf '%s|%s' "$(_md5 "$MAN")" "$([[ -f $F20 ]] && _md5 "$F20" || echo dizin)"; }

# isdir_matrix <on|off>: 20/21/90 yerinde DİZİN x nginx -t {sağlam, kırık} x yollar; kayıt <on|off>.
isdir_matrix() {
    local rec="$1" t ngx path rc out src sout l0 f0 tag
    for t in 90 21 both 20; do
        for ngx in ok kirik; do
            for path in repair83 repairall fmroot fmrootall provision phpswitch; do
                # php-switch kayıt off iken no-op (kurtarma/kapatma yoluna girmez; belgeli sınır)
                if [[ "$path" == phpswitch && "$rec" == off ]]; then continue; fi
                reset_all; _on; if [[ "$rec" == off ]]; then _off; fi
                mkdirs "$t"; fm_sim_reload
                l0=$(listing); f0=$(fp)
                if [[ "$ngx" == kirik ]]; then NGINX_T_HOOK=_ngx_isdir_hook; else NGINX_T_HOOK=""; fi
                runpath "$path"; rc=$?; NGINX_T_HOOK=""; NGINX_TEST_RC=0; NGINX_T_MSG=""
                out=$(strip < "$OUTF")
                tag="A [kayıt=${rec} dizin=${t} nginx-t=${ngx} / ${path}]"
                assert_eq "$((rc != 0))" "1" "${tag}: rc≠0 (kapatma yüksek sesle başarısız)"
                assert_contains "$out" "FM HÂLÂ AÇIK OLABİLİR" "${tag}: ileti 'FM HÂLÂ AÇIK OLABİLİR' (aynen)"
                assert_contains "$out" "yerinde DİZİN" "${tag}: nedeni söyler: yerinde DİZİN (yabancı nesne)"
                # YENİ taşıma/silme mekanizması YOK: dizin yerinde, dizin listesi bayt bayt aynı (kenara taşıma/adli kopya/geçici dosya yok)
                assert_eq "$(listing)|$(fp)|$(_bkn)|$(_supn)" "${l0}|${f0}|0|0" "${tag}: dizin(ler) taşınmadı/silinmedi/ezilmedi; custom.d listesi, kayıt ve 20 aynı; yedek sızmadı"
                case "$t" in
                    90|both) assert_eq "$([[ -d $F90 && ! -L $F90 ]] && echo dizin)" "dizin" "${tag}: 90 hâlâ DİZİN" ;;
                esac
                case "$t" in
                    21|both) assert_eq "$([[ -d $F21 && ! -L $F21 ]] && echo dizin)" "dizin" "${tag}: 21 hâlâ DİZİN" ;;
                esac
                if [[ "$t" == 20 ]]; then assert_eq "$([[ -d $F20 && ! -L $F20 ]] && echo dizin)" "dizin" "${tag}: 20 hâlâ DİZİN"; fi
                # sonraki status TAMPERED ve rc≠0
                _status; src=$?; sout=$(strip < "$OUTF")
                assert_eq "$((src != 0))" "1" "${tag}: sonraki status rc≠0"
                assert_contains "$sout" "TAMPERED" "${tag}: sonraki status TAMPERED der"
            done
        done
    done
}
