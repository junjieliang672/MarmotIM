#!/usr/bin/env bash
# kingjj-lint-no-shared-db-in-tests.sh
# Structural guard: fail if any MarmotIMTests/*.swift file contains the
# literal string `VocabularyDatabase.shared`. After spec-004 Part A
# (T1+T2) every DB-touching test uses `VocabularyDatabase.makeForTests`
# for isolation; re-introducing `.shared` re-pollutes the user's
# production dictionary.db on every `swift test` run (the human-reported
# incident that spawned spec-004). See spec-004 decision
# 003-structural-lint-via-LegacyTestShimGuard.
#
# Run manually or from CI: bash scripts/kingjj-lint-no-shared-db-in-tests.sh
#
# Complements the in-process XCTestCase `LegacyTestShimGuard` (same
# check, runs during `swift test`). This script is the
# out-of-band/CI-friendly version and matches the pattern of
# scripts/kingjj-lint-no-marmotcore.sh (spec-002).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

fail_count=0

err() { echo "NO-SHARED-DB-IN-TESTS ERROR: $*" >&2; fail_count=$((fail_count+1)); }
ok()  { echo "NO-SHARED-DB-IN-TESTS OK:    $*"; }

if [[ ! -d MarmotIMTests ]]; then
  ok "MarmotIMTests/ not present — nothing to check"
  exit 0
fi

# Scan every .swift file for the literal. The LegacyTestShimGuard.swift
# test file itself is the ONLY exemption — it splits the literal
# `"VocabularyDatabase" + ".shared"` to keep the forbidden string out of
# its own body (see the file's comments).
hits=$(grep -r -l -I 'VocabularyDatabase\.shared' MarmotIMTests/ 2>/dev/null || true)

if [[ -n "$hits" ]]; then
  for f in $hits; do
    err "$f contains 'VocabularyDatabase.shared' — migrate to makeForTests(path:)"
  done
fi

if [[ $fail_count -gt 0 ]]; then
  echo "NO-SHARED-DB-IN-TESTS FAILED ($fail_count errors)"
  exit 1
fi

ok "no 'VocabularyDatabase.shared' found in MarmotIMTests/"
exit 0
