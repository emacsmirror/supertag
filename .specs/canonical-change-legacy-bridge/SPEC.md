# Canonical Change legacy bridge parity

status: confirmed
revision: 1
context_refs: `../../KERNEL.md`; `../../CONTEXT.md`; `../../doc/architecture/04-final-architecture.md`

## Problem and goal

K2 proves Canonical Change only as an isolated, non-production commit seam.
Production writers still emit legacy `:store-changed` events directly, so the
first writer cannot enter the seam until a private CommitRecord bridge proves
that old subscribers keep receiving the same `(path old new)` contract without
double delivery.

M2b will implement that one-way bridge and migrate exactly one low-risk
production writer, `supertag-board-create`, as a tracer. Board creation is
chosen because it owns one outer Store write and has no ambient transaction;
this keeps the known ambient-transaction limitation explicit instead of
silently weakening it.

## Unchanged contracts

- Document, Semantic, and Operational Fact ownership remains unchanged;
  Projection still has no independent authority.
- Canonical Change v1 authority/scope envelope, bounded public summary,
  FIFO/non-reentrant delivery, rollback/no-op behavior, and subscriber failure
  isolation remain unchanged.
- Raw first-touch paths remain private and never enter the Canonical Change
  public value.
- Unmigrated Store writers retain their current immediate legacy behavior and
  emit no Canonical Change.
- `supertag-board-create` keeps its public name, input, return value, generated
  board shape, Store location, and one legacy `:store-changed` notification.
- Durable Store layout and persistence format do not change.
- Existing unrelated dirty work and user files remain untouched.

## Decision and boundaries

This is a compatible revision of the enacted Canonical Change lifecycle.
`supertag-core-change.el` remains the authority for commit ordering, the
private CommitRecord, the one-way bridge, delivery FIFO, topic exclusivity,
and bridge diagnostics.

For a Kernel-managed write:

```text
validate envelope
  -> suppress only immediate legacy :store-changed inside the owned transaction
  -> commit and capture the private first-touch CommitRecord
  -> atomically enqueue one delivery batch
       [one Canonical Change, zero-or-more legacy (path old new) events]
  -> deliver Canonical first, then legacy paths in first-touch order
```

A subscriber-triggered nested commit appends a complete batch to the FIFO; it
cannot interleave with the current batch. The bridge is one-way: a legacy
event never creates a Canonical Change.

The bridge uses the private CommitRecord, not the bounded public summary. It
exposes bounded diagnostics sufficient to count legacy subscribers, bridged
commits, total path events, and the most recent commit's path count. Debug
logging is opt-in.

## Model delta

- Revise the K2 Canonical Change lifecycle from “isolated non-production seam”
  to “production seam enacted for board creation”.
- Record the temporary CommitRecord-to-legacy bridge as the only permitted
  second delivery site for migrated writers.
- No new concept, identity, relation, fact authority, durable collection, or
  persistence format is introduced.

After verification, `learn` may revise K2 to K3. Implementation must not edit
`KERNEL.md` directly.

## Action Contracts

### AC1 Bridge a committed change to legacy subscribers

- precondition: Canonical Change owns the outer transaction and a real mutation
  yields a non-empty private CommitRecord.
- input: validated envelope, mutation body, and private first-touch entries.
- permitted effect: enqueue one Canonical Change followed by one legacy
  `:store-changed(path, old, new)` event per changed first-touch path.
- invariant: immediate legacy events from the managed body are suppressed;
  no-op/error/rollback emit neither topic; public Canonical data contains no
  raw path; bridge delivery never creates another Canonical Change.
- verification: ERT compares shape, values, first-touch ordering, delivery
  order, event counts, no-op/rollback behavior, and nested FIFO behavior.

### AC2 Keep consumer topics exclusive

- precondition: a callback subscribes through a Canonical or legacy
  `:store-changed` subscription interface.
- input: topic and callback identity.
- permitted effect: register the callback on exactly one topic.
- invariant: the same callback cannot be active on both topics; unrelated
  legacy topics and path subscriptions are unchanged.
- verification: ERT covers both subscription orders and confirms a legacy
  event cannot feed back into the Canonical queue.

### AC3 Create a board through Canonical Change

- precondition: `supertag-board-create` is called outside an ambient Store
  transaction with a title.
- input: title plus generated ID/time.
- permitted effect: persist one `:boards` Semantic Fact, return the existing
  board shape, publish one `:board-created` Canonical Change, then bridge one
  legacy `:store-changed` event.
- invariant: the Store is written once; the legacy path/value contract is
  unchanged; rollback/error publishes zero; no existing board update/delete
  writer is migrated.
- verification: ERT fixes ID/time, compares the returned/stored board, and
  asserts exact Canonical/legacy counts and delivery order.

## Seams and verification

The external seam remains `supertag-change-commit`; the legacy bridge is a
private adapter inside its implementation. No general event abstraction or
ambient after-commit hook is added.

Required checks:

```text
focused canonical-change/board bridge ERT
transaction, automation, board/view, ownership, and architecture regressions
source scan proving only board-create is a production Canonical writer
changed production Elisp byte compilation via temporary copies
check-parens for changed Elisp
bash -n test/run-tests.sh
git diff --check
full ./test/run-tests.sh
```

## Compatibility and migration

- Compatibility classification: compatible revision.
- Mapping: board-create's previous direct legacy event becomes the bridge's
  post-commit event with the same three arguments and first-touch position;
  one additive Canonical event is published before it.
- All unmigrated writers remain on their old path.
- Replacement: migrated writers and consumers eventually use Canonical Change.
- Bridge usage evidence: diagnostics and repository scans count legacy
  subscribers and bridged path events.
- Delete gate: every production writer and consumer has migrated, repository
  legacy subscriber/path counts are zero, parity/recursion regressions pass,
  and an explicitly confirmed SPEC removes the bridge.

## Out of scope

- ambient/nested caller transaction support or a general after-commit hook;
- migration of `supertag-field-set`, field definitions, relations, tags,
  Projector, Automation, View, board update/delete, or any consumer;
- changing legacy subscriber error semantics outside the bridge;
- deleting or deprecating `:store-changed`, `supertag-ops-commit`, or Store
  mutation functions;
- durable event logs, cross-process delivery, replay, or exactly-once claims;
- persistence/data migration and unrelated cleanup.

## Issue map

```text
01 bridge parity + board-create tracer (ready; no dependencies)
```

## Revision notes

- revision 1 — captured the user-authorized M2b compatible revision as one
  vertical slice, with explicit ambient-transaction and migration limits.
