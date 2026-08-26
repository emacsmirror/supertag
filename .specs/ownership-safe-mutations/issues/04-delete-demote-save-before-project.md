# 04 Make node deletion and demotion save before projection

status: done
blocked_by:
authority: `supertag-service-org.el`
spec_ref: `../SPEC.md`
context_ref: `../../../KERNEL.md`; `../../../CONTEXT.md`
evidence_ref: `../../../EVIDENCE.md#e-20260825-006--delete-and-demote-are-document-first-and-retryable`

## Goal

Route delete and demote through recoverable Org edit → save → Projection
reconciliation, with a structured retryable error when projection fails after
save.

## Scope

- `supertag-service-org.el`
- `supertag-ui-commands.el` delete/demote hunks only
- `test/document-command-ownership-test.el`
- `test/test-smart-key.el` demotion fixtures only
- `test/run-tests.sh`

## Acceptance

- Delete removes subtree and saves before deleting node/document-owned Projections.
- Demote removes only ID, saves, then removes Projection while retaining heading/body.
- Save failure leaves Store unchanged and does not report success.
- Projection failure preserves the already-saved Document Fact, rolls back Store mutation, and signals `supertag-projection-error` with node/file/retry data.
- Existing unrelated path-normalization edits in `supertag-ui-commands.el` are byte-identical.
- All document-command ownership tests pass.

## Verification

```bash
emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/document-command-ownership-test.el -f ert-run-tests-batch-and-exit
./test/run-tests.sh ownership identity transaction
```

## Evidence

- Ten focused Document Command tests pass, including real save failure rollback,
  late Projection transaction rollback, service-level retry execution, and a
  durable demotion end-state.
- Ownership, identity, transaction, smart-key, architecture, and command
  regressions pass 86/86; focused command + transaction tests pass 30/30 after
  wrapping the complete Projector lifecycle in one Store transaction.
- Same-context check confirmed Org ordering remains owned by
  `supertag-service-org.el`, UI prompts/messages remain thin, and the user's
  four later path-normalization hunks are unchanged.
- Temporary-copy byte compilation, `check-parens`, `bash -n`, and
  `git diff --check` pass; emitted warnings predate this slice.
