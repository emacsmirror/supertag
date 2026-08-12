# tech-refer_ownership_separation_20260812

## Current Code Map

```text
Org files
  → supertag-services-sync.el extractors
  → :nodes / :tags / :node-tag / :reference
  → some reference paths write reciprocal text back to Org

supertag--store
  ├─ Document Projection: nodes, tag membership, document references
  ├─ Semantic Facts: schema, fields, semantic relations, boards, automations
  ├─ Operational durable state: unresolved sync conflicts
  └─ Derived state: relation/schema/rule indexes and caches

raw collections / scan-based queries
  → View Runtime / Stream / Table / Node / Kanban
  → Board / Graph / Completion / Query / Automation
```

The Store is a physical container, not a single owner. The ownership seam is currently hidden in collection type, relation type, key whitelists and caller ordering.

## Proven Mixed-ownership Points

### Node plist

`supertag--merge-node-properties` treats a hard-coded key list as Org-owned and every unknown old key as DB-owned. This is field-level ownership inside one plist and makes new extractor keys unsafe by default.

### Tag membership

A single Org token is represented by `node.:tags`, a Tag entity and a `:node-tag` relation. Consumers merge these representations again.

Task006 establishes the first explicit runtime split:

- `node.:tag-occurrences` stores sanitized Org-owned tokens.
- `node.:tags` stores only IDs resolved against existing Semantic Tags.
- `node.:unresolved-tags` is a rebuildable diagnostic projection.
- reindex reconciles `:node-tag` only from resolved IDs and never creates a Tag entity.
- explicit migration or the completion `[New]` action remains the creation boundary.

This is an intermediate name-based resolver. Stable IDs and aliases remain gated by task016–017.

### Reference

A reference may be represented by a source Org link, a reciprocal target Org link, a relation and node ref caches. Scanner reconciliation calls a command that can write the source documents it is supposed to project.

### Query reads

`supertag-view-api-get-collection` returns raw hash tables. Generic `supertag-query` accepts arbitrary collections/paths. Several `index-*` functions remain O(N) scans.

### Durable roots

`:automations` and `:sync-conflicts` are created dynamically and serialized despite not being declared in the Store root contract. Save verification primarily protects node count rather than all non-rebuildable facts.

## Ownership Matrix

| Predicate / collection | Owner | Projection / note |
|---|---|---|
| Node ID/title/body/topology/TODO/schedule/deadline/properties | Org | document-node projection |
| Tag Occurrence | Org | token catalog and membership resolution |
| Physical Org link | Org | document-link projection |
| Stable Semantic Tag/name/aliases | Semantic Store | occurrence resolves by alias |
| Tag inheritance/schema | Semantic Store | resolved schema is derived |
| Field definition/association/value | Semantic Store | legacy nested fields migrate away |
| Semantic Edge | Semantic Store | distinct from Document Link |
| Board/Automation/persisted Query/View | Semantic Store | runtime registries are derived |
| Backlink | none | query over document links and semantic edges |
| `:node-tag` relation | none | membership projection |
| field-reference edge | none | projection of authoritative field value |
| relation/schema/rule indexes | none | cold rebuild |
| sync scan state | none | disposable operational optimization |
| unresolved sync conflict | operational durable | retain until resolved |

## Target Flow

```text
                       ┌──────────────────────┐
                       │ Org Document Facts   │
                       └──────────┬───────────┘
                                  │ pure extraction
                                  ▼
                       ┌──────────────────────┐
                       │ Document Projection  │
                       └──────────┬───────────┘
                                  │
                                  │ join/index
                                  ▼
┌──────────────────────┐  ┌──────────────────────┐
│ Semantic Facts       │→ │ Concrete Query Model │→ Consumers
└──────────────────────┘  └──────────────────────┘
```

Write direction:

```text
Document command → write/save Org → reproject affected document
Semantic command → semantic transaction → invalidate/rebuild query projection
Query/View       → read only
```

## Module Seams

The phase deepens existing modules before creating new ones.

| Module | Interface after migration | Implementation locality |
|---|---|---|
| Document Projector | reindex file/vault, return report, never write Org/Semantic Facts | `supertag-services-sync.el` |
| Document Commands | mutate/save Org, then request reindex | `supertag-service-org.el`, command callers |
| Semantic Writes | stable Tag/schema/field/edge/board/automation/query/view operations | existing `supertag-ops-*`, board/automation operations |
| Derived Indexes | clear/rebuild/incrementally maintain known indexes | `supertag-core-index.el` and existing cache modules |
| Query Model | named domain queries; no arbitrary collection/path access | `supertag-services-query.el`; `supertag-view-api.el` becomes a compatibility caller |

No repository/factory/backend adapter is introduced. A second adapter is required before a backend seam becomes real.

## Concrete Query Interface

Names are finalised when task019 begins; required query shapes are:

- node by ID and node summaries
- Semantic Tag by ID and Tags with display paths
- descendants and nodes by resolved Tag
- resolved fields and node field value
- relations from/to/among entity IDs by kind
- composed node detail
- node query execution
- board detail
- automation list for rule-index rebuild

Raw collection access is not part of the interface.

## Reindex Contract

Reindex may change only:

- Document node/location projection
- Tag Occurrence catalog and membership resolution
- Document-link projection
- derived indexes/caches
- scan state

Reindex must not change:

- Semantic Tag identity/name/aliases/schema/inheritance
- field definitions/associations/values
- Semantic Edges
- boards/automations/persisted queries/views
- unresolved operational conflicts
- Org file contents

## Migration Gates

### Reciprocal links

Existing automatic and user-authored links are syntactically indistinguishable. Migration is preview + explicit confirmation only; new writes can become forward-only independently.

### Stable Tag ID

Dry-run must produce a complete old-ID mapping, alias conflict report and reverse mapping before any write. Unresolved occurrences remain visible and fail closed rather than silently rebinding.

### Fields

Global field cutover requires per-node/per-field parity. Legacy storage becomes read-only before deletion.

### Consumers

Each consumer migrates independently behind its existing public command. Raw interfaces are removed only after repository-wide caller audit.

## Deferred Decision

SQLite is deliberately deferred. Ownership and query seams must be correct before evaluating a physical backend; otherwise SQL would only preserve the current mixed model in tables.
