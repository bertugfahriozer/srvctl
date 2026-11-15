#!/bin/bash
# test_domconf_fm_g13_phpswitch_on_crash.sh'in K=9…son adım dilimi (dosya başı süre payı için bölündü; B/C/D kontrolleri 1. dilimde).
G13_KFROM=9 G13_KTO=99 G13_KTO_OPEN=1 G13_SKIPBCD=1 exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_domconf_fm_g13_phpswitch_on_crash.sh"
