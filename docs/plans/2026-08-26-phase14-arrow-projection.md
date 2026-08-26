# Phase 14: Arrow C Data Interchange and Projection

**Goal:** Add explicit field projection and a trusted, batch-oriented Arrow C
Data path whose ownership, copying boundary, schema validation, and failure
atomicity are observable and tested.

## Architecture

The Mojo query model owns a `FieldProjection` value. A projection independently
selects point metadata (`id`, `sequence`), the dense vector, all payload fields,
or a named payload subset. Projection is applied while constructing a result so
unrequested vectors and payload values are not cloned across the adapter
boundary. Existing `get` and search APIs keep their current full/minimal result
shapes for compatibility; projected variants are additive.

The Arrow boundary has two layers:

1. `bindings/arrow_c_data.mojo` defines trusted read-only array views over the
   Arrow C Data primitive buffers used by Akasha, validates bounds/nullability,
   and models one-shot consumer release. A view never outlives its owner.
2. `python/akashadb/arrow.py` validates a `pyarrow.RecordBatch`, keeps the Arrow
   producers alive for the complete synchronous kernel call, and passes typed
   buffer descriptors to the compiled Mojo extension. Mojo reads IDs, fixed-size
   dense float32 vectors, optional sparse list columns, and scalar payload
   columns directly from Arrow buffers. Persistent records necessarily copy into
   engine-owned WAL/MemTable storage; no intermediate Python sequences are
   materialized.

The result exporter creates Arrow arrays from typed result columns and returns
an owned `RecordBatch`. The producer owns buffers until the consumer imports or
releases them. Python list/NumPy-compatible helpers remain explicitly copying
and use different function names.

## Canonical ingest schema

- `id`: non-null `int64`.
- `vector`: non-null `fixed_size_list<float32>[collection.dimension]`.
- `sparse_term_ids`: optional non-null `list<int64>`.
- `sparse_weights`: optional non-null `list<float32>` with identical offsets to
  `sparse_term_ids`.
- Payload columns use the `payload.` prefix and one non-null scalar type:
  `utf8`, `int64`, `float64`, or `bool`. A nullable payload value means that
  field is absent for that row.

The two sparse columns must appear together. Unknown columns, sliced buffers
with invalid offsets, nested payloads, dictionary encodings, and inconsistent
lengths are rejected.

## Ownership and atomicity

- The producer retains every Arrow owner for the complete synchronous call.
- The consumer release state is one-shot; use-after-release and double-release
  are errors.
- Mojo validates all descriptors and converts every row into an owned
  `BatchMutation` before calling `PersistentCollection.apply_batch` once.
- A schema, bounds, dimension, sparse alignment, payload, or release error occurs
  before sequence allocation/WAL append and therefore mutates nothing.
- Returned Arrow batches own their buffers independently of query snapshots and
  collection lifetime.

## TDD sequence

1. Add failing Mojo tests for projection and Arrow primitive/list views,
   including release, null, offset, and bounds failures.
2. Implement `FieldProjection`, projected documents, and snapshot/collection
   projected reads.
3. Implement trusted Arrow views and one-shot ownership in Mojo.
4. Add failing Python tests for valid dense/sparse/payload batches, sliced
   arrays, schema rejection, premature release, and all-or-nothing writes.
5. Add the compiled kernel batch descriptor method and PyArrow public adapter.
6. Add projected Python reads and Arrow result export.
7. Document the exact zero-copy/copying boundary and run focused, full, crash,
   build, and smoke validation.

## Completion gates

- Projection omits unrequested vectors/fields and remains snapshot-stable.
- Dense, sparse, and every supported payload type round-trip through a PyArrow
  `RecordBatch` without a Python list conversion.
- Invalid or released input leaves sequence, WAL-visible state, and point state
  unchanged.
- Release is exactly once and exported results survive collection close.
- Existing copying helpers remain compatible and explicitly documented.
