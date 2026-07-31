#!/bin/bash
# warn(): STDOUT'a hiçbir şey yazmamalı — tüm çıktısı STDERR'e gitmeli.
# GEREKÇE: birçok fonksiyon "$(_some_fn)" ile stdout'u parse ediyor (ör.
# _deploy_worker_cmd, _domain_read_framework, _redis_major_version...).
# 'warn' stdout'a sızarsa bu çağıranların çıktısına KARIŞIR — ör.
# "PHP CLI bulunamadı" uyarısı bir komut satırının PARÇASI olarak
# systemd unit'e YAZILABİLİRDİ. warn() > /dev/stderr yazdığından bu testin
# amacı bu sözleşmeyi regresyona karşı kilitlemek.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

out=$(warn "test uyarı mesajı" 2>/dev/null)
assert_eq "$out" "" "warn(): stdout tamamen boş"

err=$(warn "test uyarı mesajı" 2>&1 >/dev/null)
assert_contains "$err" "test uyarı mesajı" "warn(): mesaj stderr'e gidiyor"

# error() de aynı sözleşmeye tabi olmalı (exit ETSE de, stdout'a yazmamalı) —
# subshell'de çağrılır ki 'exit' üst test script'ini öldürmesin.
out_err=$( (error "test hata mesajı") 2>/dev/null )
assert_eq "$out_err" "" "error(): stdout tamamen boş (exit etse de)"

rm -rf "$WEB_ROOT"
test_summary
