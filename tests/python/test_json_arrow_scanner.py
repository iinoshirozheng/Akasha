from contextlib import closing
from time import monotonic_ns

import pytest

from akashadb import (CancellationToken, Collection, JsonbValue, PayloadField,
                     PointMutation, ValidationError, scan_record_batches)


def leaf(operator="ge", value=2):
    return {"kind": "predicate", "projection": {
        "function": "json_get_int", "input": "data", "argument": "v"},
        "operator": operator, "value": value}


def put(db, id, text):
    db.apply_point_batch([PointMutation.upsert(id, vector=[float(id)], fields=[
        PayloadField("data", "jsonb", JsonbValue.from_json(text))])])


def seed(db):
    for id in range(6):
        put(db, id, '{"v":' + str(id) + '}')
    db.create_json_index("v", "data", "$.v")


def rows(scanner):
    with scanner:
        return [row for batch in scanner for row in batch.to_pylist()]


def test_json_scanner_indexed_residual_projection_and_owned_snapshot(tmp_path):
    db = Collection(tmp_path, 1)
    seed(db)
    options = dict(batch_size=2, columns=("id", "vector"), json_expression=leaf(),
                   json_columns={"value": leaf()["projection"]})
    expected = rows(scan_record_batches(db, **options))
    scanner = scan_record_batches(db, **options, indexes=["v"])
    first = next(scanner)
    put(db, 5, '{"v":0}')
    db.drop_json_index("v")
    db.flush()
    db.close()
    actual = first.to_pylist() + rows(scanner)
    assert actual == expected
    assert sorted(row["id"] for row in actual) == [2, 3, 4, 5]
    assert first["value"].to_pylist() == [row["value"] for row in expected[:2]]
    assert scanner.stats["rows"] == 4


def test_json_scanner_controls(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
        options = dict(batch_size=1, columns=("id",), json_expression=leaf(), indexes=["v"])
        token = CancellationToken()
        token.cancel()
        with pytest.raises(ValidationError, match="cancel"):
            scan_record_batches(db, **options, cancellation=token)
        with pytest.raises(ValidationError, match="deadline"):
            scan_record_batches(db, **options, deadline_ns=monotonic_ns()-1)
        with pytest.raises(ValidationError, match="candidate"):
            scan_record_batches(db, **options, max_candidates=2)
        token = CancellationToken()
        scanner = scan_record_batches(db, **options, cancellation=token)
        first = next(scanner)
        token.cancel()
        with pytest.raises(ValidationError, match="cancel"):
            next(scanner)
        assert scanner.closed
        assert first.num_rows == 1


def test_json_scanner_rejects_indexes_without_expression(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        with pytest.raises((ValueError, ValidationError)):
            scan_record_batches(db, indexes=["v"])


def test_json_scanner_multirun_visibility_nullable_and_flush(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
        put(db, -10, '{"v":null}')
        db.flush()
        put(db, 2, '{"v":9}')
        db.apply_point_batch([PointMutation.delete(3)])
        put(db, 20, '{"v":5}')
        expression = {"kind": "not", "child": leaf("lt", 4)}
        expected = db.query_json(expression, indexes=["v"])
        scanner = scan_record_batches(db, columns=("id",), batch_size=1,
            json_expression=expression, indexes=["v"])
        db.flush()
        actual = rows(scanner)
        assert sorted(row["id"] for row in actual) == expected == [2, 4, 5, 20]


def test_json_scanner_filter_first_and_lazy_residual_errors(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        put(db, 1, '{"v":3}')
        db.apply_point_batch([PointMutation.upsert(2, fields=[PayloadField("data", "string", "bad")])])
        scanner = scan_record_batches(db, columns=("id",), batch_size=1, json_expression=leaf())
        first = next(scanner)
        assert first["id"].to_pylist() == [1]
        with pytest.raises(ValidationError, match="JSONB"):
            next(scanner)
        assert scanner.closed
        assert first["id"].to_pylist() == [1]
        # The ordinary filter rejects the invalid JSONB row before JSON evaluation.
        db.set_payload({"keep": True}, points=[1])
        filt = {"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True}
        assert rows(scan_record_batches(db, columns=("id",), filter=filt,
                    json_expression=leaf())) == [{"id": 1}]
        lazy = {"kind": "any", "children": [{"kind": "all", "children": []}, leaf()]}
        assert sorted(row["id"] for row in rows(scan_record_batches(db,
            columns=("id",), json_expression=lazy))) == [1, 2]


def test_json_scanner_output_limit_and_projection_error_close(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
        db.set_payload({"big": "x" * 1000}, points=[2])
        scanner = scan_record_batches(db, columns=("id",), batch_size=1,
            payload_schema={"big": "string"}, max_batch_bytes=64,
            json_expression=leaf("eq", 2), indexes=["v"])
        with pytest.raises(ValidationError):
            next(scanner)
        assert scanner.closed

        projection = {"function": "json_get_int", "input": "big", "argument": "v"}
        scanner = scan_record_batches(db, columns=("id",), batch_size=1,
            json_columns={"bad": projection}, json_expression=leaf("eq", 2), indexes=["v"])
        with pytest.raises(ValidationError):
            next(scanner)
        assert scanner.closed


@pytest.mark.parametrize("indexes", [[], ["v"]])
def test_json_scanner_budget_counts_physical_slots_not_only_live_rows(tmp_path, indexes):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
        # The frozen head shadows one base slot: six live rows, seven visits.
        put(db, 2, '{"v":9}')
        scanner = scan_record_batches(db, columns=("id",), batch_size=1,
            json_expression=leaf("ge", 0), indexes=indexes, max_candidates=6)
        with pytest.raises(ValidationError, match="candidate"):
            list(scanner)
        assert scanner.closed


def test_json_scanner_invalid_expression_and_catalog_name(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
        with pytest.raises(ValidationError, match="unknown JSON index"):
            scan_record_batches(db, json_expression=leaf(), indexes=["missing"])
        with pytest.raises(ValidationError):
            scan_record_batches(db, json_expression={"kind": "unknown"})
        assert [row["id"] for row in rows(scan_record_batches(db,
            columns=("id",), json_expression=leaf("eq", 2), indexes=["v"]))] == [2]
