# 03 Make node creation save before projection

status: done
blocked_by:
authority: `supertag-service-org.el`
spec_ref: `../SPEC.md`
context_ref: `../../../KERNEL.md`; `../../../CONTEXT.md`
evidence_ref: `../../../EVIDENCE.md#e-20260825-005--node-creation-is-document-first`

## Goal

Route `supertag-create-node` through one Document Command seam that persists the
Org ID/heading before creating or reconciling the node Projection.

## Scope

- `supertag-service-org.el`
- `supertag-ui-commands.el` create-node hunk only
- `test/document-command-ownership-test.el`
- `test/sync-worker-regression-test.el` only if its command-level fixture must
  become file-backed to preserve the existing assertion

## Acceptance

- Existing-heading and new-heading branches call the same save-before-project service contract.
- Save failure emits no node Projection mutation.
- Successful creation saves once and projects once.
- Existing public command name, prompt behavior, returned node ID, point behavior, and unrelated user edits remain intact.
- Slice 01 create tests pass.

## Verification

```bash
emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/document-command-ownership-test.el -f ert-run-tests-batch-and-exit
./test/run-tests.sh ownership identity
```

## Evidence

- Three focused create tests cover existing headings, newly inserted headings,
  and save failure; all pass with exactly one save before one projection.
- Ownership, identity, sync-worker, and architecture regressions pass 59/59.
- Same-context check confirmed mutation ordering is owned only by
  `supertag-service-org.el`; UI retains prompts/messages and returns the node ID.
- Changed production files byte-compile from temporary copies; `check-parens`
  and `git diff --check` pass.  Reported compile warnings predate this slice.
