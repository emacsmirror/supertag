# 02 Guard ownership boundaries in source

status: done
blocked_by:
authority: n/a — test-only enforcement of existing Kernel/SPEC boundaries; no business rule is introduced
spec_ref: `../SPEC.md`
context_ref: `../../../KERNEL.md`; `../../../docs/protocols/supertag-development.md`
evidence_ref: `../../../EVIDENCE.md#e-20260825-004--architecture-boundary-guard-enacted`

## Goal

Add a small source-level guard that prevents new raw Store writes in UI/View/
Automation, Ops-to-Automation private callbacks, and renderer-to-Query private
calls while documenting current legacy exceptions.

## Scope

- `test/architecture-boundary-test.el`
- `test/run-tests.sh`

## Acceptance

- Current source passes with an explicit path/pattern allowlist and each exception has a reason.
- A synthetic forbidden source sample is rejected by the same scanner.
- The guard distinguishes Store reads from writes and does not ban stable Query Model calls.
- The allowlist can only shrink without an explicit test change.

## Verification

```bash
emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/architecture-boundary-test.el -f ert-run-tests-batch-and-exit
```

## Evidence

- Focused architecture ERT passed 3/3, including an exact current-source
  allowlist, a synthetic forbidden write, and allowed Store/Query reads.
- The scanner accepts full Emacs Lisp symbol syntax used by the guarded calls,
  including predicate/comparator suffixes such as `<`.
- Same-context check confirmed this is test-only enforcement with no hidden
  production authority; `check-parens`, `bash -n`, and `git diff --check`
  passed.
