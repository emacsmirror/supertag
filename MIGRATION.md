# SPEC-AGENTS Migration

status: complete
date: 2026-08-25
source_classification: legacy-v2
report: `.scratch/upgrade-review/REPORT.md`
archive: `archive/legacy-v2/2026-08-25-phrase/`

## Confirmed decisions

- The tracked root `.phrase/` tree was legacy v2 history, not current workflow state.
- Project-specific development rules were preserved in `docs/protocols/supertag-development.md`.
- Root `AGENTS.md`, `START.md`, `UPGRADE.md`, `skills/`, and `docs/spec-agents/` are installed doctrine.
- Existing `CONTEXT.md` remains the only project vocabulary entry point.
- Confirmed-only `KERNEL.md` K1 is the initial stable semantic floor.
- Operational Fact is an approved candidate Kernel revision for narrowly scoped non-rebuildable conflict/recovery state; it will be promoted only after the active SPEC verifies its owner and lifecycle.
- The C1–C5 architecture enforcement work proceeds through the modern six-action workflow.

## Preserved history

All 196 files previously tracked below root `.phrase/` were moved with Git
history to `archive/legacy-v2/2026-08-25-phrase/`. No completed legacy phase was
imported into modern active state. Ignored copies inside separate nested
worktree directories were not touched.

## Root model

- `KERNEL.md`: enacted K1, confirmed-only.
- `CONTEXT.md`: preserved unchanged; SHA-256 before and after cutover is `ee5b903c1abaad6723e53c660cf2b17903f324b3ce1c014c227cc3c39e99e5c6`.
- `EVIDENCE.md`: migration decision and verification evidence.
- `STATUS.md`: created only when the first modern SPEC becomes active.
- `ROADMAP.md`: intentionally absent.

## Verification

- `git ls-files .phrase | wc -l` → `0`.
- `git ls-files archive/legacy-v2/2026-08-25-phrase | wc -l` → `196`.
- `cmp AGENTS.md /Users/chenyibin/Documents/prj/SPEC-AGENTS.md/AGENTS.md` → identical.
- `CONTEXT.md` checksum before/after → identical.
- Doctrine and project Protocol paths are no longer hidden by `.gitignore`; `.scratch/` remains ignored as one-shot review state.
- No application source, tests, dependencies, or durable user data were changed by the cutover.

## Remaining work

The next permitted action is `capture` for the confirmed C1–C5 architecture
enforcement SPEC, followed by `arrange`, one ready Slice at a time, `check`,
and `learn`.
