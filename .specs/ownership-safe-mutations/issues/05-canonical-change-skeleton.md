# 05 Establish the canonical change skeleton

status: done
blocked_by:
authority: `supertag-core-change.el` — SPEC-approved candidate authority; K1 map gap must be reported by check before K2 promotion
spec_ref: `../SPEC.md`
context_ref: `../../../KERNEL.md`; `../../../CONTEXT.md`
evidence_ref: `../../../EVIDENCE.md#e-20260825-007--canonical-change-skeleton-verified`

## Goal

Implement the smallest internal Canonical Change/CommitRecord/FIFO seam and
prove its semantics without migrating production writers or consumers.

## Scope

- `supertag-core-change.el`
- `test/canonical-change-test.el`
- `test/run-tests.sh`
- minimal require/load entry only if focused tests cannot load the module directly

## Acceptance

- Envelope validates authority (`document|semantic|operational`), scope, operation, cardinality, and bounded affected summary.
- Successful real mutation publishes one Canonical Change after transaction commit.
- No-op, body error, and rollback publish zero.
- Nested subscriber commits enqueue after the current delivery and never reenter the dispatch stack.
- One subscriber error is captured/reported without blocking later subscribers or rolling back Store.
- Batch events expose bounded counts and no public raw path list.
- No production writer/subscriber is migrated and legacy `:store-changed` behavior is untouched.

## Verification

```bash
emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/canonical-change-test.el -f ert-run-tests-batch-and-exit
./test/run-tests.sh transaction ownership
```

## Evidence

- Seven focused tests pass for schema validation, real/no-op/rollback
  detection, post-commit delivery, FIFO causation, subscriber isolation,
  bounded batch summaries, and explicit ambient-transaction rejection.
- Change/transaction/ownership/architecture regressions pass 56/56.
- Same-context check found the expected K1 authority-map gap.  `learn`
  promoted the verified seam and the existing durable sync-conflict lifecycle
  to K2 without claiming a production migration.
- Repository search confirms no production require, writer, or subscriber;
  legacy `:store-changed` code is untouched.
- Temporary-copy byte compilation, `check-parens`, `bash -n`, and
  `git diff --check` pass.
