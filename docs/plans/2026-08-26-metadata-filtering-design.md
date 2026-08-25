# Metadata Filtering Design

## Goal

Phase 4.2 adds strict typed metadata filtering to exact vector search. Filters
run before vector scoring, use the flat payloads introduced in Phase 4.1, and
do not change any persisted format.

## Scope

The first filter model supports one or more conditions combined with logical
AND. Each condition compares one document field with one typed
`PayloadValue`. Supported operators are:

```text
==  !=  <  <=  >  >=
```

String and Bool support equality and inequality only. Int64 and finite Float64
support all six operators. Int64 and Float64 remain distinct types and are not
coerced. OR, NOT, nested expressions, missing-field operators, substring or
token matching, case folding, partial payload projection, and metadata indexes
remain out of scope.

## Public API

`FilterCondition` is a public typed condition with static constructors such as:

```mojo
FilterCondition.equal("category", PayloadValue.string("database"))
FilterCondition.greater_than("page", PayloadValue.integer(5))
```

`PersistentCollection` retains every existing search method and adds:

```text
search_dot_filtered(query, k, conditions)
search_l2_filtered(query, k, conditions)
search_cosine_filtered(query, k, conditions)
```

An empty condition list has the same semantics as an unfiltered search. Search
continues to return lightweight `SearchResult` values. Callers use
`get(result.id)` to retrieve the complete document.

## Components

The implementation keeps filtering in the query layer:

```text
query/filter_ast.mojo    condition model and constructor validation
query/evaluator.mojo     one-document AND evaluation
api/collection.mojo      pre-filtered exact scoring and Top-K
```

The operator representation uses explicit stable tags rather than an opaque
variant. Public constructors validate the field name and operator/value
combination before a condition reaches a search. Field names share the document
model's validation rule: they must be non-empty and contain no NUL byte.

## Matching semantics

All conditions must match one document. Evaluation rules are strict:

| Document state | Result |
| --- | --- |
| Field is missing | false |
| Field and condition have different value tags | false |
| Empty condition list | true |
| Every condition matches | true |
| Any condition does not match | false |

Missing fields do not match inequality either. String equality compares exact
UTF-8 content, Bool compares truth values, Int64 uses integer comparison, and
Float64 uses native finite-value comparison. Payload and filter constructors
reject non-finite Float64 values, so NaN and infinity require no query-time
ordering rules.

Invalid conditions fail during construction. Valid filters never fail merely
because a schemaless collection contains missing or differently typed fields.
Vector validation, storage corruption, and scoring errors remain visible to the
caller.

## Query data flow

```text
MemTable live entries
  -> evaluate all metadata conditions
  -> score matching vectors with the selected SIMD metric
  -> bounded Top-K
  -> SearchResult(id, score)
```

Filtering must happen before scoring. This avoids work for rejected documents
and prevents an invalid candidate for a particular metric, such as a zero-norm
cosine vector, from failing a query when metadata already excludes it.

With no metadata index, complexity is `O(N * F + M * D)`, where `N` is the
number of live documents, `F` is the condition count, `M` is the number of
matching candidates, and `D` is vector dimension. A future metadata index may
replace candidate generation without changing the condition model or public
search API.

## Persistence and compatibility

Filters are query-only values. WAL, MemTable payload ownership, Segment,
Manifest, and recovery formats do not change. Phase 3 vector-only records and
Phase 4.1 v2 payload records retain their existing compatibility behavior.
Vector-only records have empty fields and therefore do not match a condition.
Deleted records remain absent from the live MemTable view.

## Testing

Tests cover three layers:

1. Condition constructors: all six operators, invalid field names,
   String/Bool range rejection, finite Float64 enforcement, and owned values.
2. Evaluator: all four payload types, all comparisons, AND, empty conditions,
   missing fields, strict type mismatch, and missing-field inequality.
3. Persistent collection: dot/L2/cosine filtered methods, filtered Top-K,
   stable ID ties, empty-filter equivalence, WAL reopen, snapshot reopen,
   vector-only records, deletes, and search-result-to-get lookup.

A cosine regression test stores a zero-norm vector that metadata rejects. The
filtered query must succeed, proving that filter evaluation occurs before SIMD
scoring. All Phase 4.1 persistence and compatibility tests remain regression
requirements.

