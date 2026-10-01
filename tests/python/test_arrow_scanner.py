import gc
import threading
from itertools import permutations
from time import monotonic_ns

import pyarrow as pa
import pytest

import akashadb
from akashadb.arrow import scan_record_batches


def _collection(path):
    collection = akashadb.Collection(path, 2)
    for row in range(5):
        fields = [
            akashadb.PayloadField("label", "string", f"文字-{row}"),
            akashadb.PayloadField("active", "bool", row % 2 == 0),
            akashadb.PayloadField("weight", "float", row + 0.25),
        ]
        if row != 2:
            fields.append(akashadb.PayloadField("page", "int", row))
        collection.upsert(row, [float(row), 1.0], fields=fields)
    collection.upsert_sparse(1, [akashadb.SparseElement(7, 0.5)])
    collection.upsert_sparse(3, [akashadb.SparseElement(2, 1.0), akashadb.SparseElement(9, 0.25)])
    return collection


def test_bounded_batches_capture_full_state_and_outlive_collection(tmp_path):
    collection = _collection(tmp_path / "scan")
    scanner = scan_record_batches(
        collection, batch_size=2,
        payload_schema={"label": "string", "page": "int", "weight": "float", "active": "bool"},
    )
    collection.upsert(0, [99.0, 99.0])
    collection.delete(1)
    collection.close()
    batches = list(scanner)
    assert all(0 < batch.num_rows <= 2 for batch in batches)
    for batch in batches:
        batch.validate(full=True)
        assert batch.schema == scanner.schema
    rows = sorted(pa.Table.from_batches(batches).to_pylist(), key=lambda row: row["id"])
    assert [row["id"] for row in rows] == list(range(5))
    assert rows[0]["vector"] == [0.0, 1.0]
    assert rows[1]["sparse_term_ids"] == [7]
    assert rows[1]["sparse_weights"] == [0.5]
    assert rows[0]["sparse_term_ids"] is None
    assert rows[3]["sparse_term_ids"] == [2, 9]
    assert rows[2]["payload.page"] is None
    assert rows[4]["payload.label"] == "文字-4"
    assert rows[4]["payload.weight"] == 4.25
    assert [row["payload.active"] for row in rows] == [True, False, True, False, True]
    assert scanner.stats["rows"] == 5
    assert scanner.stats["borrowed_bytes"] == 8
    assert scanner.stats["materialized_bytes"] > 0


def test_borrowed_vector_slice_survives_every_producer_close(tmp_path):
    collection = _collection(tmp_path / "borrow")
    scanner = scan_record_batches(collection, batch_size=1, columns=("vector",))
    batch = next(scanner)
    assert scanner.stats["borrowed_bytes"] == 8
    assert scanner.stats["materialized_bytes"] == 0
    values = batch.column(0).values.slice(1, 1)
    pointer = values.buffers()[1].address
    scanner.close()
    collection.close()
    del batch, scanner, collection
    gc.collect()
    assert values.buffers()[1].address == pointer
    assert values.to_pylist() == [1.0]
    assert not values.to_numpy(zero_copy_only=True).flags.writeable
    del values
    gc.collect()


def test_foreign_thread_last_release_reclaims_retired_sidecar(tmp_path):
    path = tmp_path / "last-release"
    # Force an actual base replacement; a below-threshold checkpoint now keeps
    # its current base referenced, so releasing a reader must not remove it.
    collection = akashadb.Collection(
        path, 2, config=akashadb.CollectionConfig.defaults(2, delta_max_points=1)
    )
    collection.upsert(1, [1.0, 2.0])
    collection.flush()
    old_sidecar, = path.glob("hnsw-*.bin")
    scanner = scan_record_batches(collection, columns=("vector",), batch_size=1)
    batch = next(scanner)
    scanner.close()
    collection.upsert(2, [3.0, 4.0])
    collection.flush()
    collection.close()
    assert old_sidecar.exists()
    held = [batch.column(0).values.slice(1, 1)]
    del batch, scanner, collection
    gc.collect()
    assert held[0].to_pylist() == [2.0]
    def release():
        held.clear()
        gc.collect()
    thread = threading.Thread(target=release)
    thread.start()
    thread.join(timeout=10)
    assert not thread.is_alive()
    assert not old_sidecar.exists()


def test_empty_projection_filter_cancel_and_validation(tmp_path):
    collection = _collection(tmp_path / "filter")
    scanner = scan_record_batches(collection, batch_size=2, columns=("id",), filter={
        "kind": "condition", "name": "active", "operator": "eq", "type": "bool", "value": True
    })
    assert [value for batch in scanner for value in batch.column(0).to_pylist()] == [0, 2, 4]
    scanner.close()
    with pytest.raises(RuntimeError, match="closed"):
        next(scanner)
    token = akashadb.CancellationToken()
    scanner = scan_record_batches(collection, cancellation=token)
    token.cancel()
    with pytest.raises(akashadb.AkashaError, match="cancel"):
        next(scanner)
    assert scanner.closed
    for size in (0, -1, True):
        with pytest.raises((ValueError, TypeError)):
            scan_record_batches(collection, batch_size=size)
    with pytest.raises(ValueError):
        scan_record_batches(collection, columns=("vector", "vector"))
    with pytest.raises(ValueError):
        scan_record_batches(collection, payload_schema={"label": "int8"})
    mismatch = scan_record_batches(collection, payload_schema={"label": "int"})
    with pytest.raises(akashadb.AkashaError, match="type"):
        next(mismatch)
    assert mismatch.closed
    collection.close()
    empty = akashadb.Collection(tmp_path / "empty", 2)
    scanner = scan_record_batches(empty)
    assert list(scanner) == []
    assert list(scanner) == []
    empty.close()


def test_scan_budget_and_context_manager_close(tmp_path):
    collection = _collection(tmp_path / "limit")
    with scan_record_batches(collection, batch_size=2, columns=("id",), max_candidates=3) as scanner:
        assert next(scanner).column(0).to_pylist() == [0, 1]
        with pytest.raises(akashadb.AkashaError, match="limit"):
            next(scanner)
    assert scanner.closed
    collection.close()


@pytest.mark.parametrize("size", [1, 2, 9, 17])
def test_bitmap_boundaries_nulls_utf8_and_sliced_ragged_values(tmp_path, size):
    collection = akashadb.Collection(tmp_path / "bitmaps", 1)
    expected = []
    for row in range(19):
        fields = []
        value = None
        label = None
        if row % 3:
            value = row % 2 == 0
            label = "" if row % 5 == 0 else "🧪" * row
            fields = [akashadb.PayloadField("yes", "bool", value), akashadb.PayloadField("s", "string", label)]
        collection.upsert(row - 9, [float(row)], fields)
        expected.append({"id": row - 9, "sequence": row + 1, "payload.yes": value, "payload.s": label})
    with scan_record_batches(collection, batch_size=size, columns=("id", "sequence"),
                             payload_schema={"yes": "bool", "s": "string"}) as scanner:
        batches = list(scanner)
        assert pa.Table.from_batches(batches).to_pylist() == expected
        assert scanner.stats["borrowed_bytes"] == 0
        for batch in batches:
            batch.slice(1).validate(full=True)
    collection.close()


def test_zero_columns_empty_filter_limits_and_existing_batch_on_error(tmp_path):
    collection = _collection(tmp_path / "empty-projection")
    with scan_record_batches(collection, columns=(), batch_size=2) as scanner:
        batches = list(scanner)
        assert [batch.num_rows for batch in batches] == [2, 2, 1]
        assert all(batch.num_columns == 0 for batch in batches)
        assert scanner.stats["materialized_bytes"] == 0
    with scan_record_batches(collection, filter={"kind": "any", "children": []}) as scanner:
        assert list(scanner) == []
        assert scanner.stats["visited_slots"] == 5
    with scan_record_batches(collection, deadline_ns=monotonic_ns() - 1) as scanner:
        with pytest.raises(akashadb.AkashaError, match="deadline"):
            next(scanner)
    with scan_record_batches(collection, batch_size=1, max_batch_bytes=8) as scanner:
        with pytest.raises(akashadb.AkashaError, match="buffer.*limit"):
            next(scanner)
    token = akashadb.CancellationToken()
    scanner = scan_record_batches(collection, batch_size=1, cancellation=token)
    first = next(scanner)
    token.cancel()
    with pytest.raises(akashadb.AkashaError, match="cancel"):
        next(scanner)
    collection.close()
    assert first.column("vector").to_pylist() == [[0.0, 1.0]]


@pytest.mark.parametrize("order", list(permutations(("collection", "scanner", "batch"))))
def test_all_close_orders_keep_the_last_borrowed_slice(tmp_path, order):
    collection = _collection(tmp_path / "close-order")
    scanner = scan_record_batches(collection, batch_size=1, columns=("vector",))
    batch = next(scanner)
    values = batch.column(0).values.slice(1)
    owners = dict(collection=collection, scanner=scanner, batch=batch)
    del collection, scanner, batch
    for name in order:
        if name != "batch":
            owners[name].close()
        del owners[name]
        gc.collect()
        assert values.to_pylist() == [1.0]


def test_independent_scanners_keep_versions_during_index_updates(tmp_path):
    collection = _collection(tmp_path / "versions")
    collection.flush()
    old = scan_record_batches(collection, batch_size=1, columns=("id", "vector"))
    first = next(old)
    collection.upsert(0, [99.0, 99.0])
    collection.delete(1)
    collection.upsert(6, [6.0, 1.0])
    collection.flush()
    current = scan_record_batches(collection, batch_size=2, columns=("id", "vector"))
    collection.close()
    old_rows = pa.Table.from_batches([first, *old]).to_pylist()
    current_rows = pa.Table.from_batches(list(current)).to_pylist()
    assert {row["id"]: row["vector"] for row in old_rows} == {i: [float(i), 1.0] for i in range(5)}
    assert {row["id"]: row["vector"] for row in current_rows} == {
        0: [99.0, 99.0], 2: [2.0, 1.0], 3: [3.0, 1.0], 4: [4.0, 1.0], 6: [6.0, 1.0]
    }


def test_signed_id_boundaries_and_all_null_payload_buffers(tmp_path):
    collection = akashadb.Collection(tmp_path / "bounds", 1)
    ids = [-(1 << 63), (1 << 63) - 1]
    for value in ids:
        collection.upsert(value, [1.0])
    with scan_record_batches(collection, columns=("id",),
                             payload_schema={"s": "string", "b": "bool", "i": "int", "f": "float"}) as scanner:
        batch = next(scanner)
        batch.validate(full=True)
        assert batch.column("id").to_pylist() == ids
        for name in ("s", "b", "i", "f"):
            assert batch.column(f"payload.{name}").to_pylist() == [None, None]
    collection.close()
