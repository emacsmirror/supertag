# 01 Prove document-command failure contracts

status: done
blocked_by:
authority: `supertag-service-org.el`
spec_ref: `../SPEC.md`
context_ref: `../../../KERNEL.md`; `../../../CONTEXT.md`
evidence_ref: E-20260825-003

## Goal

Add focused ERT that reproduces the current create/delete/demote ordering
violations and fixes the required observable outcomes before implementation is
changed.

## Scope

- `test/document-command-ownership-test.el`
- existing test fixtures only when reuse requires a surgical addition

## Acceptance

- Save failure during create/delete/demote is asserted to leave Store Projection unchanged.
- Call-order probes distinguish save-before-project from Store-first behavior.
- Projection failure after successful save has an explicit pending expectation for structured retry data and unchanged old Projection.
- The focused tests demonstrably fail against the current violating implementation for the intended reason; unrelated baseline tests remain unchanged.

## Verification

```bash
emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/document-command-ownership-test.el -f ert-run-tests-batch-and-exit
```

Capture the exact failing test names/messages; red is expected evidence for
this test-first slice and is removed by slices 03/04.

## Evidence

Focused ERT loaded successfully after adding package initialization. Against
the pre-implementation code, all seven contract tests failed for the intended
reasons:

- create did not call save and projected immediately;
- delete projected before the failing save;
- demote projected and never called save;
- projection failure was a generic pre-save error rather than a structured
  post-save retryable error.

The preceding relevant baseline run passed 53/53 tests.
