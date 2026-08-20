# Supertag

Supertag gives Org documents typed semantics without transferring ownership of the documents themselves to the database.

## Language

**Document Fact**:
A fact encoded by the user's Org text or document topology, such as a title, body, heading relation, Tag Occurrence, or Document Link.
_Avoid_: Node data, file-backed semantic data

**Semantic Fact**:
A typed fact that Org text does not encode, such as a Tag schema, field value, or Semantic Edge.
_Avoid_: Metadata, database copy

**Projection**:
A disposable representation derived from Document Facts, Semantic Facts, or both. It has no independent ownership and can be rebuilt.
_Avoid_: Cache when referring to authoritative data, source of truth

**Tag Occurrence**:
A tag token that physically appears in an Org document.
_Avoid_: Tag entity, Tag definition

**Semantic Tag**:
A stable semantic identity that can own a schema, inheritance, a canonical name, and aliases. A Tag Occurrence may resolve to it without owning it.
_Avoid_: Tag token, tag string

**Document Link**:
A physical Org link owned by the document in which it appears.
_Avoid_: Semantic relation, backlink

**Semantic Edge**:
A typed relation owned by the semantic store and not represented by inserting reciprocal text into Org documents.
_Avoid_: Org link, reference cache

**Backlink**:
A derived answer to “which Document Links or Semantic Edges point here?” It is not a second physical link.
_Avoid_: Reciprocal link

**Reindex**:
Rebuild Document Projections and derived indexes from their authoritative facts without changing Semantic Facts.
_Avoid_: Full database rebuild, semantic restore

**Semantic Restore**:
Restore non-rebuildable Semantic Facts from a backup or synchronized copy.
_Avoid_: Reindex, rescan
