# Ownership-safe mutations

status: confirmed
revision: 1
context_refs: `KERNEL.md`; `CONTEXT.md`; `doc/OWNERSHIP-CONSTITUTION_cn.md`; `doc/architecture/04-final-architecture.md`; `docs/protocols/supertag-development.md`

## Problem and goal

Supertag has enacted Document/Semantic/Projection ownership semantics, but
public node create/delete/demote commands still permit Store-first or unsaved
cross-owner writes. Mutation notifications also have no single future contract.

The first implementation batch will:

1. prove save failure and projection failure behavior at Document Command boundaries;
2. prevent new cross-boundary raw writes through a source-level architecture guard;
3. make create/delete/demote save Org before reconciling Projection;
4. introduce a tested Canonical Change/FIFO skeleton without migrating production consumers.

## Unchanged contracts

- Org remains authoritative for node identity, heading content, topology, Tag Occurrences, and physical Document Links.
- Semantic Facts and existing durable Store collections remain unchanged.
- Store physical layout, persistence format, transaction rollback, complete Reindex, Node Identity, Query behavior, and View Runtime remain unchanged.
- Existing public command names and user interaction prompts remain available.
- Existing legacy `:store-changed` behavior remains the production path during this batch.
- C5 has no production consumer and does not bulk-migrate existing writers.
- Existing unrelated user changes in `supertag-ui-commands.el`, TextUI/demo files, and untracked files are preserved.

## Decision and boundaries

### Document write order

Node create/delete/demote are Document Commands:

```text
validate/locate
  -> recoverable Org buffer edit
  -> save-buffer
  -> reconcile affected Projection
  -> return domain result
```

Store mutation is forbidden before save succeeds. A Projector failure occurs
after the Document Fact is durable; its Store transaction must roll back and a
structured `supertag-projection-error` must expose a safe retry entry.

### Mutation/event seam

C5 adds one internal seam adjacent to existing Store/Transform/Notify code. It
does not add a Repository or change Store data access. The seam accepts:

```elisp
(:authority :document | :semantic | :operational
 :scope :fact | :projection | :fact+projection
 :operation symbol
 :subject plist-or-nil
 :cardinality :single | :batch
 :affected bounded-summary
 :metadata plist)
```

`Operational Fact` is narrowly limited to non-rebuildable conflict/recovery
state. This batch proves the authority value in the contract but introduces no
new Operational writer or durable collection. Its concrete owner/lifecycle must
be verified before K2 promotion.

### Ownership of rules

- runtime node identity: `supertag-service-node-identity.el`;
- Org-backed mutation ordering: `supertag-service-org.el`;
- interactive commands: thin validation/prompt adapters in `supertag-ui-commands.el`;
- Store transaction/commit record: existing Store/Transform boundary;
- event queue/subscriber lifecycle: `supertag-core-notify.el` or one private implementation beside it;
- architecture source guard: test-only enforcement under `test/`.

## Model delta

Candidate stable delta after verification:

```text
Authoritative Fact = Document Fact | Semantic Fact | Operational Fact
Projection has no independent authority.
Change authority and change scope are orthogonal.
```

Operational Fact is not runtime ephemeral state and is not a general escape
hatch. Only unresolved conflict/recovery records that cannot be reconstructed
from Document or Semantic Facts qualify.

K1 remains enacted during implementation. `learn` may revise it to K2 only
after C5 verification and a concrete authority/lifecycle check.

## Action Contracts

### AC1 Create node

- precondition: current buffer is a file-backed Org buffer and creation point/title is valid.
- input: existing heading or new heading title.
- permitted effect: create/persist Org ID and heading content, save once, then create/reconcile one node Projection.
- invariant: save failure leaves Store/Projection unchanged; no duplicate projection event.
- verification: ERT captures save/project call order and final Store state.

### AC2 Delete node

- precondition: point resolves to a projected node and user confirms deletion.
- input: node ID and current Org subtree.
- permitted effect: delete subtree, save Org, then remove node/document-owned Projections.
- invariant: save failure leaves Store unchanged and keeps the edit recoverable; Semantic Facts are not deleted.
- verification: ERT injects save failure and projection failure separately.

### AC3 Demote node to ordinary heading

- precondition: point is a heading with an Org ID and user confirms demotion.
- input: node ID.
- permitted effect: remove the ID Document Fact, save Org, then remove the node Projection while preserving heading/body.
- invariant: save failure leaves Store unchanged; no unsaved ID deletion is reported as success.
- verification: ERT asserts buffer/file/Store outcomes and call order.

### AC4 Projection failure after successful save

- precondition: Org save completed and Projector reconciliation fails.
- input: node ID, file, and retry operation.
- permitted effect: signal `supertag-projection-error` containing diagnosable retry data.
- invariant: already-saved Org is not rolled back or reported as unsaved; Store transaction keeps the old Projection.
- verification: ERT checks error data, durable Document change, and unchanged Store Projection.

### AC5 Architecture boundary guard

- precondition: production source tree is available to ERT.
- input: explicit source scopes and documented legacy allowlist.
- permitted effect: read source files and fail when a new forbidden dependency/write appears.
- invariant: guard performs no source/runtime mutation and does not treat legitimate Query Model reads as writes.
- verification: self-test proves a synthetic violation fails and current allowlist passes.

### AC6 Canonical Change skeleton

- precondition: a caller enters the internal commit seam with a validated authority/scope envelope.
- input: operation envelope and transactional body.
- permitted effect: on a real successful mutation, enqueue one bounded Canonical Change after commit.
- invariant: no-op/error/rollback emits zero; nested subscriber commits are FIFO and non-reentrant; one subscriber error does not block others or roll back committed Store.
- verification: focused ERT covers success/no-op/error/nesting/isolation/batch summary.

## Seams and verification

- Reuse `supertag-service-org-save-and-project-current-node` ordering rather than duplicating tag-specific behavior.
- Reuse Node Identity for locating nodes; no new `org-id-locations` caller.
- Reuse `supertag-with-transaction` rollback; no file-system/Store pseudo-transaction.
- Keep first-touch path/old/new private; public Canonical Change contains bounded domain summary.
- The event skeleton may use an internal adapter over current notify functions, but no new public abstraction is added for a single consumer.

Required checks:

```text
focused document command ERT
architecture guard self-test
transaction/ownership/node-identity regressions
canonical change ERT
byte compile of changed production Elisp
check-parens for changed Elisp
git diff --check
full ./test/run-tests.sh after all five slices
```

## Compatibility and migration

- Public command names remain stable.
- Direct legacy Store writers and `:store-changed` remain during C1–C5.
- C5 is additive and initially has no production subscriber; therefore it cannot double-run Automation.
- A later SPEC will add the private CommitRecord-to-legacy bridge and migrate writers/consumers incrementally.
- No durable schema/data migration occurs in this SPEC.
- The Operational Fact addition is compatible with existing Document/Semantic facts because it classifies already-declared durable recovery state; it does not reclassify ordinary Semantic data.

## Out of scope

- deleting legacy mutation APIs or `:store-changed`;
- migrating Automation, View, Query, field writers, or Projector batches to Canonical Change;
- splitting Query Model/Engine or unifying comparators;
- moving/splitting the large sync, persistence, or view files;
- adding SQLite, Repository/backend adapters, durable event log, or cross-process exactly-once delivery;
- changing persistence format or user data;
- editing unrelated TextUI/dashboard work.

## Issue map

```text
01 document failure contracts ─┐
02 architecture boundary guard ├─> 03 create save-before-project
                               └─> 04 delete/demote save-before-project
03 + 04 ──────────────────────────> 05 canonical event skeleton
```

## Revision notes

- revision 1 — captured the user-confirmed C1–C5 batch after legacy-v2 cutover; added the confirmed Operational Fact candidate while keeping K1 unchanged until verification.
