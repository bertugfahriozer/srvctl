#!/bin/bash
# QL6-P1: cmd_cloudflare, token denetimini ALT KOMUTU geçirerek yapar (`_cf_check_token "${1:-}"`).
# Eskiden argümansız çağrılıyordu: istisna ('setup') hiç tetiklenmiyor, token yokken `setup` dahil HER şey
# "Önce: srvctl cloudflare setup" diyerek reddediliyordu (setup'a ulaşılamıyordu).
# Hücreler (CF_API_TOKEN tanımsız VE tanımlı-boş; QL7-M5): setup → _cf_setup'a ULAŞIR; argümansız/help/-h/--help → kullanım metni rc 0,
# hiçbir API işlevi çağrılmaz; bilinmeyen alt komut ve dns/purge/waf/ddos/status → fail-closed (rc≠0, "Önce:" iletisi,
# hiçbir işleyici çağrılmaz). Token doluyken: dns işleyicisine ulaşır, bilinmeyen alt komut rc≠0 kalır.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export WEB_ROOT="${T}/www" SRVCTL_STATE_DIR="${T}/state"
mkdir -p "$WEB_ROOT" "$SRVCTL_STATE_DIR"

# QL7-M5: "token yok" İKİ ayrı durumdur: TANIMSIZ (@UNSET → unset CF_API_TOKEN) ve TANIMLI-BOŞ (CF_API_TOKEN='' → dışa
# aktarılır, boş). Eskiden boş değer unset EDİLİYORDU; kapı `-z "${CF_API_TOKEN:-}"` yerine `${CF_API_TOKEN+x}` olsa
# (boşu "tanımlı" sayardı) hiçbir hücre kırılmıyordu (QL7 mutantı E02). Artık her "yok" hücresi iki biçimde koşar.
run() {   # $1 = token (@UNSET = tanımsız, "" = tanımlı boş), $2.. = cmd_cloudflare argümanları → çıktı + "HANDLER=<ad|->" + "RC=<n>"
    local tok="$1"; shift
    ( set +e
      source "${REPO_ROOT}/lib/core.sh" >/dev/null 2>&1
      require_root() { :; }; log_action() { :; }
      source "${REPO_ROOT}/lib/cloudflare.sh" >/dev/null 2>&1
      if [[ "$tok" == "@UNSET" ]]; then unset CF_API_TOKEN; else export CF_API_TOKEN="$tok"; fi
      HANDLER=-
      _cf_setup()  { HANDLER=setup;  }
      _cf_dns()    { HANDLER=dns;    }
      _cf_purge()  { HANDLER=purge;  }
      _cf_waf()    { HANDLER=waf;    }
      _cf_ddos()   { HANDLER=ddos;   }
      _cf_status() { HANDLER=status; }
      _cf_api()    { HANDLER=API;    }
      # error() çıkış yapar: işleyici izini dosyaya yaz, çıkışı ayrı alt kabukta yakala
      ( cmd_cloudflare "$@" 2>&1 </dev/null; rc=$?; echo "$HANDLER" > "${T}/h"; exit "$rc" )
      rc=$?
      [[ -f "${T}/h" ]] || echo - > "${T}/h"
      echo "HANDLER=$(cat "${T}/h")"; rm -f "${T}/h"
      echo "RC=${rc}" )
}
rc_of() { local o="$1"; o="${o##*RC=}"; echo "${o%%$'\n'*}"; }
h_of()  { local o="$1"; o="${o##*HANDLER=}"; echo "${o%%$'\n'*}"; }

for form in @UNSET ""; do
    flbl="tanımsız"; [[ "$form" == "" ]] && flbl="tanımlı-boş"
    echo "── A: token YOK (${flbl}) ──"
    out=$(run "$form" setup)
    assert_eq "$(h_of "$out")" "setup" "A1[${flbl}]: token yokken 'setup' _cf_setup'a ULAŞIR"
    assert_eq "$(rc_of "$out")" "0" "A1[${flbl}]: setup rc 0"
    assert_not_contains "$out" "Önce: srvctl cloudflare setup" "A1[${flbl}]: setup 'Önce setup' diye reddedilmez"

    for a in "" help -h --help; do
        if [[ -z "$a" ]]; then out=$(run "$form"); lbl="(argümansız)"; else out=$(run "$form" "$a"); lbl="$a"; fi
        assert_eq "$(rc_of "$out")" "0" "A2[${flbl}/$lbl]: token yokken kullanım metni rc 0"
        assert_contains "$out" "Kullanım: srvctl cloudflare" "A2[${flbl}/$lbl]: kullanım metni basıldı"
        assert_eq "$(h_of "$out")" "-" "A2[${flbl}/$lbl]: hiçbir işleyici/API çağrılmadı"
        assert_not_contains "$out" "Önce: srvctl cloudflare setup" "A2[${flbl}/$lbl]: 'Önce setup' reddi YOK"
    done

    for a in zzz-bilinmeyen dns purge waf ddos status; do
        out=$(run "$form" "$a" example.com)
        rc=$(rc_of "$out")
        assert_eq "$([[ "$rc" =~ ^[0-9]+$ && "$rc" -ne 0 ]] && echo NONZERO || echo "ZERO($rc)")" "NONZERO" "A3[${flbl}/$a]: token yokken fail-closed rc≠0"
        assert_contains "$out" "Önce: srvctl cloudflare setup" "A3[${flbl}/$a]: token iletisi"
        assert_eq "$(h_of "$out")" "-" "A3[${flbl}/$a]: işleyici/API ÇAĞRILMADI"
    done
done

# (ön koşul) iki biçim GERÇEKTEN farklı ortam kurar: tanımlı-boş hücrede değişken tanımlı, tanımsızda değil
probe_env() { ( set +e; if [[ "$1" == "@UNSET" ]]; then unset CF_API_TOKEN; else export CF_API_TOKEN="$1"; fi
                printf '%s' "${CF_API_TOKEN+DEFINED}" ); }
assert_eq "$(probe_env "")" "DEFINED" "(ön koşul) tanımlı-boş biçimde CF_API_TOKEN tanımlı"
assert_eq "$(probe_env @UNSET)" "" "(ön koşul) tanımsız biçimde CF_API_TOKEN tanımsız"

echo "── B: token VAR ──"
out=$(run "tok" dns list example.com)
assert_eq "$(h_of "$out")" "dns" "B1: token varken dns işleyicisine ulaşır"
out=$(run "tok" zzz-bilinmeyen)
rc=$(rc_of "$out")
assert_eq "$([[ "$rc" =~ ^[0-9]+$ && "$rc" -ne 0 ]] && echo NONZERO || echo "ZERO($rc)")" "NONZERO" "B2: token varken bilinmeyen alt komut rc≠0 (QL5-M3 korunur)"
assert_contains "$out" "Bilinmeyen cloudflare alt komutu" "B2: uyarı"

test_summary
