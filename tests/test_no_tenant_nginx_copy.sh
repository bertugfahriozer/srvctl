#!/bin/bash
# F3 R1: nginx FM dosyaları YALNIZ srvctl şablonlarından üretilir. Kiracı (WEB_ROOT) ağacından
# nginx/custom.d'ye kopyalayan yol ve eski install-fm-nginx.sh düzeneği KALMADI.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
set +e
R="${NOCOPY_ROOT:-$REPO_ROOT}"   # mutasyon kancası
echo "── A: eski kurulum düzeneği izi YOK (tests/ hariç: bu dosya kalıbı yazar) ──"
hits=$(grep -rIn -e 'install-fm-nginx' -e 'Deploy/nginx' "$R" --exclude-dir=.git --exclude-dir=tests 2>/dev/null)
assert_eq "$hits" "" "lib/ bin/ templates/ completions/ README: install-fm-nginx / Deploy/nginx başvurusu yok"
tests_hits=$(grep -rIln -e 'install-fm-nginx' -e 'Deploy/nginx' "$R/tests" --exclude=test_no_tenant_nginx_copy.sh --exclude-dir=fuzz 2>/dev/null)
assert_eq "$tests_hits" "" "tests/ (bu dosya hariç; fuzz hariç): başvuru yok"
echo "── B: şablon kaynağı yalnız srvctl kurulum dizini ──"
tpl=$(grep -n '_domconf_fm_tpl_dir()' -A2 "$R/lib/domconf.sh" | tr '\n' ' ')
assert_contains "$tpl" 'SRVCTL_ROOT' "şablon dizini SRVCTL_ROOT/templates"
assert_not_contains "$tpl" 'WEB_ROOT' "…WEB_ROOT (kiracı) DEĞİL"
echo "── C: custom.d'ye yazan HİÇBİR komut kaynağı WEB_ROOT'tan almaz (rev-L10: çok satırlı/boşluk/aklama dayanıklı) ──"
# Eski kilit tek satırlık bir regex'ti (aşağıda ek kat olarak duruyor); '\' devamı, sekme, değişkenle
# aklama, 'cat … >'/'| tee', '$(cat …)' ile atomik yazım ondan kaçıyordu. tests/lib_nocopy_scan.awk:
# mantıksal satır + tırnak-duyarlı yorum + işlev-içi değişken lekesi (bkz. dosya başı).
SCAN="${REPO_ROOT}/tests/lib_nocopy_scan.awk"
CT="$(mktemp -d)"; trap 'rm -rf "$CT"' EXIT
cat > "${CT}/pos.sh" <<'POSEOF'
f1() {
    cp "${WEB_ROOT}/${domain}/x.conf" \
       "${SRVCTL_NGINX_CUSTOM_DIR}/${sname}/20.conf"
}
f2() {
	cp	"$WEB_ROOT/a"	"$dir/b"
}
f3() {
    local src="${WEB_ROOT}/${d}/fm.conf"
    local cdir="${SRVCTL_NGINX_CUSTOM_DIR}/${s}"
    cp -- "$src" "${cdir}/x.conf"
}
f4() {
    cat "${WEB_ROOT}/x" > "${SRVCTL_NGINX_CUSTOM_DIR}/y"
}
f5() {
    install -m 644 "$WEB_ROOT/x" "$CUR_DIR/y"
}
f6() {
    ln -sf "$WEB_ROOT/x" "${dir}/y"
}
f7() {
    rsync -a "$WEB_ROOT/" "/etc/nginx/custom.d/x/"
}
f8() {
    tee "${dir}/y" < "$WEB_ROOT/x" >/dev/null
}
f9() {
    local body; body=$(cat "${WEB_ROOT}/${d}/n.conf")
    _domconf_atomic_write "${SRVCTL_NGINX_CUSTOM_DIR}/${s}/20.conf" "$body"
}
f10() {
    local a="${WEB_ROOT}/${d}"; local b="$a/n.conf"; local t="${SRVCTL_NGINX_CUSTOM_DIR}"; local u="$t/${s}"
    mv  -f  --  "$b"   "$u/20.conf"
}
f11() {
    _domconf_atomic_write "$dir/20.conf" "$(cat "$WEB_ROOT/x")"
}
f12() {
    echo "a #b"; cp "$WEB_ROOT/x" "$dir/y"
}
f13() {
    cat "${WEB_ROOT}/${d}/n.conf" | tee "${SRVCTL_NGINX_CUSTOM_DIR}/${s}/20.conf" >/dev/null
}
f14() {
    cat "${WEB_ROOT}/${d}/n.conf" |
        tee "${dir}/20.conf" >/dev/null
}
f15() {
    [[ -f "$WEB_ROOT/x" ]] &&
        cp "$WEB_ROOT/x" "$dir/y"
}
POSEOF
cat > "${CT}/neg.sh" <<'NEGEOF'
n1() {
    # cp "${WEB_ROOT}/x" "${SRVCTL_NGINX_CUSTOM_DIR}/y"   (yorum)
    cp "$tpl" "${dir}/20.conf"
}
n2() {
    local src="${WEB_ROOT}/${d}"
}
n3() {
    cp -- "$src" "${dir}/x"        # src bu işlevde WEB_ROOT'tan değil (n2'nin lekesi taşınmaz)
}
n4() {
    cp -a "${WEB_ROOT}/a/" "${WEB_ROOT}/b/"
    IFS='|' read -r a b <<< "$row"
}
n5() {
    printf 'root %s;\n' "${WEB_ROOT}/${d}/public" # custom.d/x yorum
}
n6() {
    local src="${WEB_ROOT}/${d}/x.conf"
}
cp -- "$src" "${dir}/y"
NEGEOF
_pl=$(LC_ALL=C awk -f "$SCAN" "${CT}/pos.sh" | awk -F: '{print $2}' | tr '\n' ' ')
assert_eq "$_pl" "2 6 11 14 17 20 23 26 30 34 37 40 43 46 50 " "(pozitif kontrol) 15 kaçış biçiminin HER biri doğru satırda yakalanır: devam satırı, sekme, değişkenle aklama, 'cat >', install, ln, rsync, 'tee <', \$(cat) içeriği, çok aşamalı aklama, \$(cat) argümanı, tırnaklı ' #', boru hattı, satır sonu '|', satır sonu '&&'"
assert_eq "$(LC_ALL=C awk -f "$SCAN" "${CT}/neg.sh")" "" "(negatif kontrol) yorum, şablon kaynağı, başka işlevin lekesi, WEB_ROOT→WEB_ROOT, here-string, printf ile yol üretimi, işlev DIŞI kod (leke işlev sonunda sıfırlanır): bulgu YOK"
bad=$(LC_ALL=C awk -f "$SCAN" "$R"/lib/*.sh "$R/bin/srvctl" 2>/dev/null)
assert_eq "$bad" "" "lib/*.sh + bin/srvctl: WEB_ROOT → custom.d kopyası yok (mantıksal satır çözümleyicisi)"
assert_eq "$(LC_ALL=C awk -f "$SCAN" "$R"/lib/*.sh "$R/bin/srvctl" >/dev/null 2>&1; echo $?)" "0" "çözümleyici hatasız koştu (awk rc 0)"
bad=$(grep -nE '(cp|mv|install|rsync|ln -s?f?)[^#|;]*WEB_ROOT[^#|;]*(custom\.d|SRVCTL_NGINX_CUSTOM_DIR|CUR_DIR|\$\{?dir\}?)' "$R/lib/domconf.sh" "$R/lib/domain.sh" 2>/dev/null)
assert_eq "$bad" "" "(eski tek satır kalıbı, ek kat) domconf.sh/domain.sh: WEB_ROOT → custom.d kopyası yok"
echo "── D: şablon dosyaları depoda, düz (include/proxy yok) ──"
for t in fm-auth fm-upload fm-download; do
    assert_eq "$([[ -f "$R/templates/nginx/${t}.conf.tpl" ]] && echo var || echo yok)" "var" "templates/nginx/${t}.conf.tpl var"
    assert_eq "$(grep -c '^[[:space:]]*include ' "$R/templates/nginx/${t}.conf.tpl")" "0" "${t}: include YOK (kiracı dosyası yüklenmez)"
done
test_summary
