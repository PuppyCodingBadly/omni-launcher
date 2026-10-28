#!/bin/sh
# Runs mutation tests on OmniLauncher via the mutation_test package.
#
# Default (incremental): only the .dart files under lib/ changed vs HEAD~1.
# --full:                every target listed in mutation_test.xml.
#
# Reports are written to ./mutation-test-report (HTML by default).
# Run ./tool/coverage.sh first: coverage/lcov.info lets the tool skip
# mutants on uncovered lines, which speeds up the run considerably.

set -eu

cd "$(dirname "$0")/.."

COVERAGE_ARGS=""
if [ -f coverage/lcov.info ]; then
  COVERAGE_ARGS="--coverage coverage/lcov.info"
else
  echo "tool/mutation.sh: coverage/lcov.info not found; running without coverage data (slower)." >&2
  echo "tool/mutation.sh: run ./tool/coverage.sh first to speed up the analysis." >&2
fi

run_full() {
  # shellcheck disable=SC2086
  exec dart run mutation_test $COVERAGE_ARGS mutation_test.xml
}

if [ "${1:-}" = "--full" ]; then
  run_full
fi

# Incremental recipe: changed files vs HEAD~1, restricted to the same scope as
# mutation_test.xml. The UI is excluded there because widget mutants are slow
# and mostly unkillable, so an incremental run never mutates it either.
CHANGED=$(git diff --name-only HEAD HEAD~1 \
  | grep '^lib/.*\.dart$' \
  | grep -vE '^(lib/src/ui/|lib/main\.dart$)' \
  || true)

if [ -z "$CHANGED" ]; then
  cat >&2 <<'EOF'
tool/mutation.sh: no mutable .dart files changed vs HEAD~1; nothing to do.
  (lib/src/ui and main.dart are outside mutation_test.xml's scope.)
Use --full to run the whole configured scope.
EOF
  exit 0
fi

echo "tool/mutation.sh: incremental run on:" >&2
echo "$CHANGED" >&2
# shellcheck disable=SC2086
exec dart run mutation_test $COVERAGE_ARGS $CHANGED
