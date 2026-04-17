#!/usr/bin/env bash
# kingjj-lint-no-marmotcore.sh
# Structural guard: fail if Packages/MarmotCore/ ever reappears at the repo
# root, or if MarmotIM/** / MarmotIMTests/** start referencing it.
#
# The Packages/MarmotCore/ duplicate tree was deleted in spec-002 (KI-DUP-001).
# See the corresponding ADR on deletion for the rationale. Re-introducing the
# duplicate should be caught immediately by this check.
#
# Run manually or from CI: bash scripts/kingjj-lint-no-marmotcore.sh
#
# Notes: this companion script lives in the tracked project `scripts/`
# directory because `.knowledge/` is gitignored. The equivalent in-PKB hook
# lives in `.knowledge/scripts/kingjj-lint-pkb.sh` (section 7) for agents
# that also run PKB lint locally.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

fail_count=0

err() { echo "NO-MARMOTCORE ERROR: $*" >&2; fail_count=$((fail_count+1)); }
ok()  { echo "NO-MARMOTCORE OK:    $*"; }

# 1. The deleted directory must not reappear.
if [[ -d "Packages/MarmotCore" ]]; then
  err "Packages/MarmotCore reappeared — see ADR on deletion (spec-002)"
fi

# 2. No Swift source or test may reference the deleted tree or module.
if [[ -d MarmotIM || -d MarmotIMTests ]]; then
  if grep -r -l -I 'Packages/MarmotCore\|import MarmotCore' MarmotIM/ MarmotIMTests/ 2>/dev/null | grep -q .; then
    err "MarmotCore references reappeared in MarmotIM/ or MarmotIMTests/"
  fi
fi

if [[ $fail_count -gt 0 ]]; then
  echo "NO-MARMOTCORE FAILED ($fail_count errors)"
  exit 1
fi

ok "no MarmotCore duplicate tree or references"
exit 0
