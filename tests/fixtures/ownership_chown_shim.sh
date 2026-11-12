#!/bin/bash
# tests/test_selfupdate_ownership.sh için SAHTE chown (PATH'in başına konur; test kullanıcısı root olmadığından gerçek chown
# root:root yapamaz). Gerçek bir chown'un anlamını taklit eder: sahipliği OWN_LEDGER defterine (yol<TAB>uid<TAB>gid) yazar,
# her çağrıyı OWN_CALLS'a kaydeder. -h YOKSA ve yol sembolik bağsa sahiplik bağın HEDEFİNE yazılır (GNU davranışı) ve
# "SYMLINK-IZLENDI <yol>" satırı düşer — test bunun HİÇ oluşmadığını doğrular. OWN_FAIL=1 ise chown başarısız olur.
: "${OWN_LEDGER:?}" "${OWN_CALLS:?}"
printf '%s\n' "$*" >> "$OWN_CALLS"
[[ "${OWN_FAIL:-0}" == 1 ]] && exit 1
flags=""; spec=""; paths=()
for a in "$@"; do
    case "$a" in
        --) ;;
        -*) flags+="$a" ;;
        *) if [[ -z "$spec" ]]; then spec="$a"; else paths+=("$a"); fi ;;
    esac
done
[[ "$spec" == "root:root" ]] || exit 1
for p in "${paths[@]}"; do
    t="$p"
    if [[ -L "$p" && "$flags" != *h* ]]; then
        echo "SYMLINK-IZLENDI $p" >> "$OWN_CALLS"
        t="$(readlink -f "$p")"
    fi
    printf '%s\t0\t0\n' "$t" >> "$OWN_LEDGER"
done
exit 0
