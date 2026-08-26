# Supertag Development Protocol

status: enacted
scope: Supertag Emacs package development and documentation
applies_when: changing, reviewing, testing, or documenting this repository
source: E-20260825-001
verification: compare this protocol with the preserved pre-cutover `AGENTS.md` in `.scratch/upgrade-review/REPORT.md`; run repository checks named below

## Task routing

- Semantic, architecture, interface, lifecycle, invariant, or cross-context work follows `plan → capture → arrange → do → check → learn`.
- A small behavior-preserving task may use the modern short path when `plan` explicitly approves it.
- A user-facing proposal may use a PR/FAQ as a design aid when the confirmed SPEC calls for one; it is not a second workflow or authority source.
- Coding and review apply the five-layer test: data model, special cases, complexity, compatibility, and practical value. Fix root causes and avoid speculative seams.
- Documentation leads with conclusions and supports claims with concrete, reproducible evidence.

## Repository structure

- Top-level `*.el` files contain Supertag entry points, core, service, operation, and UI modules.
- `test/` contains ERT tests, runners, and fixtures.
- `doc/`, `README*.md`, `CHANGELOG.org`, and current architecture records contain user/developer documentation.
- `ext/` contains optional external UI and experimental components.
- `KERNEL.md` owns stable project semantics; `.specs/` owns active design contracts; `STATUS.md` lists active SPEC state only; archived `.phrase` records are history, not current authority.

Do not reintroduce `org-supertag` as a current entry point, public symbol, data
directory, or repository name. The old name is permitted only in migration,
historical, legacy-format compatibility, and corresponding test contexts.

## Emacs Lisp implementation

- Target Emacs 29+ and lexical binding. Use 2-space indentation and the existing `supertag-` public prefix.
- Preserve existing module boundaries unless an approved SPEC changes one.
- Prefer existing Store, Query, View Runtime, and test helpers over new parallel abstractions.
- Do not perform unrelated import reordering, repository-wide formatting, or speculative refactoring.
- Public commands, variables, data writes, file writes, and recovery paths require clear docstrings and diagnosable errors.
- Every changed line must trace to the approved Slice; preserve unrelated user changes.

## Verification

Prefer repository entry points:

```bash
./test/run-tests.sh
./test/run-tests.sh persist query git
```

- Core Elisp changes require relevant ERT; cross-module changes require the full suite.
- Entry/load-path changes require an isolated `(require 'supertag)` or byte-compile check as appropriate.
- Distinguish existing byte-compile warnings from new errors.
- Before handoff, run `git diff --check` and inspect `git status`.

## Git and safety

- Git is the current local version-control interface unless a separately approved setup adds `.jj/`.
- Use Conventional Commits and keep each commit focused on one atomic task when the user asks for commits.
- Never overwrite unrelated dirty work or use destructive reset/clean operations.
- Do not commit secrets, tokens, certificates, real user data, generated databases, or temporary compile output.
- Remote rename, push, publish, and deletion require explicit authorization.
- Do not initialize or invoke a missing Beads workflow.

## Handoff

State what changed, what was verified, which pre-existing user changes were
preserved, and any remaining limitation or next permitted action. Do not add
unrelated build systems, directories, automation services, or agent protocols
to project development guidance.
