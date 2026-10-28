#!/bin/sh
# Run the test suite with coverage, print a per-file line-coverage summary,
# and render HTML when genhtml is available.
#
# Usage: ./tool/coverage.sh [flutter test args...]
set -eu

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
    echo "error: flutter not found on PATH." >&2
    echo "hint: add the SDK, e.g. export PATH=\"\$HOME/src/flutter-sdk/flutter/bin:\$PATH\"" >&2
    exit 1
fi

flutter test --coverage "$@"

# Per-file line coverage, parsed from lcov.info without lcov installed.
awk '
    /^SF:/ {
        file = substr($0, 4)
        sub(/.*\/lib\//, "lib/", file)
        sub(/.*\/test\//, "test/", file)
    }
    /^DA:/ {
        line = substr($0, 4)
        total[file]++
        if (line ~ /,[1-9]/) hit[file]++
    }
    END {
        t = 0; h = 0
        for (f in total) {
            pct = total[f] ? 100.0 * hit[f] / total[f] : 0
            printf "%6.1f%%  %s (%d/%d lines)\n", pct, f, hit[f], total[f] | "sort -k2"
            t += total[f]; h += hit[f]
        }
        close("sort -k2")
        if (t) printf "%6.1f%%  TOTAL (%d/%d lines)\n", 100.0 * h / t, h, t
    }
' coverage/lcov.info

if command -v genhtml >/dev/null 2>&1; then
    genhtml -q -o coverage/html coverage/lcov.info
    echo "HTML report: coverage/html/index.html"
else
    echo "genhtml not found; skipping HTML report (dnf install lcov)."
fi
