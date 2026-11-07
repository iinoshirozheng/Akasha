# JSON expression and catalog indexes in Arrow scanning

Status: implemented and verified. See [acceptance evidence](../research/2026-11-08-json-arrow-scanner-validation.md).

The user approved extending the existing scanner with native JSON expressions,
catalog indexes, projections, bounded Arrow batches and snapshot ownership.

Use `scan_record_batches(..., json_expression=spec, indexes=[name])`. Omitted
indexes execute residuals. Index names without an expression are rejected.
Existing `filter` is evaluated first; only passing rows evaluate JSON. Keep
physical run/slot ordering and existing Arrow buffer ownership and byte limits.

ReadScanner owns an optional PreparedJsonQuery built from the same captured
snapshot. Add shared per-row evaluation to the prepared executor and map physical
rows to its ID-ordered bitmap ordinals by binary search. This avoids a second
ordinal map or complete matched-ID result list. A separate scanner/export path
would duplicate lifecycle logic; eagerly executing the query would move residual
errors ahead of batch iteration. Both alternatives are rejected.

Preparation uses native candidate/deadline/cancellation controls; scanning retains
the physical-slot budget and per-batch cancellation. Masks and location metadata
are snapshot-sized, as in the existing prepared API; output selection and Arrow
buffers stay bounded per batch. Close, exhaustion and failure release the query
owner while returned batches remain independently valid.

Validation: indexed versus residual IDs and projections, nested nullable/short
circuit expressions, multi-run replacements/deletions, writes/drop/compaction and
collection close after capture, cancellation before preparation and between
batches, deadlines, candidate and byte limits, deferred residual/projection
errors and existing scanner/query regressions. No durable format change.
