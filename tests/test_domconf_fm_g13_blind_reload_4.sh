#!/bin/bash
# test_domconf_fm_g13_blind_reload.sh'in K=10…12 dilimi (dosya başı süre payı için bölündü; iddialar aynı dosyadadır, kontroller 1. dilimde).
G13_KFROM=10 G13_KTO=12 G13_SKIPC=1 exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_domconf_fm_g13_blind_reload.sh"
