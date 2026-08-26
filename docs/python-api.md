# Python API

Build the Mojo extension before importing the local package:

```bash
pixi run build-python
PYTHONPATH=python python -c 'import akashadb; print(akashadb.__version__)'
```

`akashadb.Collection(path, dimension)` owns an embedded Mojo
`PersistentCollection`. `upsert`, `apply_batch`, sparse updates, delete,
flush, lookup, and every query execute in the compiled kernel. `close()` drains
background maintenance before releasing the collection directory lock.

## Atomic mutations

```python
from akashadb import BatchMutation, Collection, PayloadField

collection = Collection("/tmp/python-batch", 3)
commit = collection.apply_batch(
    [
        BatchMutation.upsert(
            1,
            [1.0, 0.0, 0.0],
            [PayloadField("chunk", "string", "owned text")],
        ),
        BatchMutation.delete(9),
    ]
)
print(commit.first_sequence, commit.last_sequence)
```

The return value names the contiguous accepted sequence range. Validation or
WAL failure changes neither durable nor live state.

## Dense batches and filters

```python
filters = [
    {
        "kind": "condition",
        "name": "language",
        "operator": "eq",
        "type": "string",
        "value": "zh-TW",
    },
    {
        "kind": "condition",
        "name": "page",
        "operator": "ge",
        "type": "int",
        "value": 10,
    },
]
results = collection.search_batch(
    "cosine",
    [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    10,
    num_workers=4,
    filters=filters,
)
```

`filters` is optional. When present, its length must equal the vector count;
each dictionary uses the same bounded condition/all/any/negate shape as
`SearchRequest.filter`. Result lists remain aligned to input vectors.

`upsert_columns` validates column-shaped Python data and copies it through
Python values. It is not a zero-copy Arrow C Data interface.

`upsert_record_batch` imports a producer's Arrow C Data schema/array capsules
into a one-shot `ArrowBatchLease`, validates the complete schema and offsets,
and keeps the imported owner alive through the synchronous Mojo call. Primitive
buffers reach the compiled binding without an intermediate Python list.
Persistence still copies accepted values once into WAL/MemTable-owned memory.
`results_to_record_batch` returns an independently owned `int64` ID / `float32`
score batch.

Projected reads use `Collection.get(id, projection=Projection(...))`.
`include_vector=False` omits the embedding, `fields=None` selects every payload
field, and a tuple selects only named fields.
