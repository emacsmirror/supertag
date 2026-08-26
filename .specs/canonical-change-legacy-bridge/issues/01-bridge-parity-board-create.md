# 01 Prove bridge parity with board-create tracer

status: done
blocked_by:
authority: `supertag-core-change.el` — owns Canonical/legacy commit delivery; `supertag-board-ops.el` retains board creation semantics without duplicating the delivery rule
spec_ref: `../SPEC.md`
context_ref: `../../../KERNEL.md`; `../../../CONTEXT.md`; `../../../doc/architecture/04-final-architecture.md`
evidence_ref: `../../../EVIDENCE.md#e-20260825-009--canonical-change-legacy-bridge-and-first-production-writer-verified`

## Goal

Implement the private CommitRecord-to-legacy bridge and route exactly
`supertag-board-create` through Canonical Change while preserving its legacy
event contract.

## Scope

- `supertag-core-change.el`
- `supertag-core-notify.el`
- `supertag-board-ops.el`
- `test/canonical-change-test.el`
- a new focused bridge/board ERT file only if keeping the external seam test
  readable requires it
- `test/run-tests.sh` only when the new focused file needs suite routing
- this Slice's status and Evidence section

No other production writer, consumer, knowledge document, or workflow file is
in scope.

## Acceptance

- Managed writes suppress their original immediate `:store-changed` and emit
  exactly one Canonical Change followed by one bridged legacy event per changed
  first-touch path.
- Legacy events preserve `(path old new)` values and first-touch order; the
  public Canonical Change still contains no raw path or CommitRecord.
- No-op, error, and rollback emit zero Canonical and zero bridged legacy events.
- A nested commit triggered by either Canonical or bridged legacy delivery is
  appended as one later batch and cannot interleave with the current batch.
- The same callback cannot subscribe to both Canonical and legacy
  `:store-changed` topics, regardless of subscription order; unrelated legacy
  topics/path subscriptions still work.
- Bridge diagnostics report current legacy subscriber count, bridged commit
  count, total path count, and last commit path count without retaining raw
  CommitRecords.
- `supertag-board-create` returns and stores the existing board shape, writes
  once, publishes operation `:board-created` with semantic/fact/single
  classification, and bridges exactly the previous legacy event after it.
- Repository search finds no other production `supertag-change-commit` caller.
- Existing ambient-transaction rejection remains tested and unchanged.

## Verification

```bash
emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/canonical-change-test.el -f ert-run-tests-batch-and-exit
./test/run-tests.sh change transaction automation board ownership architecture
```

Then run temporary-copy byte compilation for changed production Elisp,
`check-parens`, `bash -n test/run-tests.sh`, `git diff --check`, and the
full `./test/run-tests.sh`.

## Evidence

Executed 2026-08-25.

- Baseline before implementation:
  - `emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/canonical-change-test.el -f ert-run-tests-batch-and-exit` — 7/7 expected, 0 unexpected.
  - production `supertag-change-commit` caller scan — 0 callers.
- Tests were added before implementation. The first 11-test run produced 6
  expected passes and 5 expected failures covering missing bridge ordering,
  topic exclusivity, managed rollback suppression, nested batch isolation, and
  the unmigrated board writer.
- Final focused command:
  - `emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/canonical-change-test.el -f ert-run-tests-batch-and-exit` — 11/11 expected, 0 unexpected.
- Related gate without changing the runner:
  - `./test/run-tests.sh change tx automation-condition view-kanban view-runtime ownership architecture` — 92 total, 90 expected pass, 0 unexpected, 2 existing interactive dashboard skips.
  - `emacs -Q --batch -L . --eval '(package-initialize)' -l test/test-automation-scheduled.el` — exit 0; scheduled rule and day filter self-check passed. The file's documented `emacs --batch -Q -L . ...` form was also tried first and stopped before test execution because `ht` was unavailable without package initialization.
- Changed production Elisp temporary-copy byte compilation — exit 0 for
  `supertag-core-notify.el`, `supertag-core-change.el`, and
  `supertag-board-ops.el`; only the pre-existing wide-docstring warning in
  `supertag-core-notify.el` was reported. Repository `.elc` count remained 0.
- Static gates:
  - `check-parens` over the three changed production files and `test/canonical-change-test.el` — exit 0.
  - `bash -n test/run-tests.sh` — exit 0.
  - `git diff --check` — exit 0.
- Scope scans after implementation:
  - production `supertag-change-commit` callers — exactly 1,
    `supertag-board-ops.el`.
  - production `supertag-core-change` requires — exactly 1,
    `supertag-board-ops.el`.
  - production `supertag-change-subscribe` callers — 0; no consumer migrated.
  - `test/run-tests.sh` was not edited by this Slice; its existing dirty state
    was preserved.
- Full `./test/run-tests.sh` — 573 total, 571 expected pass, 0 unexpected,
  2 existing interactive dashboard skips.

The focused tests verify private first-touch `(path old new)` parity,
Canonical-before-legacy order, complete nested FIFO batches from both delivery
topics, no double delivery, zero-topic no-op/error/rollback behavior, both
subscription orders, bounded diagnostics without a retained raw CommitRecord,
board shape/return/write-count/event parity, and unchanged ambient transaction
rejection.
