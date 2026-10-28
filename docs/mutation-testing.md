# Mutation testing

Mutation testing measures test quality by making small changes ("mutants") to
the source code and checking whether the test suite detects them. A mutant
that leaves all tests green ("survived") points at behavior that is executed
but not asserted. The ratio of killed to total mutants is a far stronger
signal than line coverage alone.

We use the [`mutation_test`](https://pub.dev/packages/mutation_test) package
with its builtin mutation rules. The scope is configured in
`mutation_test.xml` at the repo root and covers the interior logic only
(`lib/src/model`, `lib/src/util`, `lib/src/state`, `lib/src/sources`,
`lib/src/plugins`, `lib/src/art`, plus `paths.dart`, `covers.dart`,
`config.dart`, `launcher.dart`, and `host.dart`). `lib/src/ui` and
`lib/main.dart` are excluded: widget code makes runs slow and produces
unkillable mutants.

## Running

```sh
./tool/mutation.sh          # incremental: files changed vs HEAD~1
./tool/mutation.sh --full   # everything in mutation_test.xml
```

The incremental mode is the normal choice while developing; use `--full`
before merging large changes, or when only UI files changed — they are outside
the configured scope, so an incremental run then does nothing. Each mutant
triggers a `flutter test` run (600s timeout), so even incremental runs take a
while.

For speed, run `./tool/coverage.sh` first. When `coverage/lcov.info` exists,
`mutation_test` skips mutants on uncovered lines instead of running the test
suite for each of them. Without coverage data the run still works, it is just
slower.

## Reports

Reports land in `./mutation-test-report/` (ignored by git). Open
`mutation-test-report/mutation-test-report.html` for a top-level overview;
each source file links to a line-by-line report where surviving mutants are
marked in red.

## Quality gate

`mutation_test.xml` sets `<threshold failure="70">`: if fewer than 70% of
mutants are detected, the run exits non-zero. Inspect the HTML report to find
the surviving mutants and add assertions or tests that cover the mutated
behavior.
