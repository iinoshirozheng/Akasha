from contextlib import closing
import math

import pyarrow as pa
import pytest

from akashadb import Collection, JsonbValue, PayloadField, PointMutation, ValidationError
from akashadb.arrow import scan_record_batches


def call(function, argument, *, input="data", **options):
    return dict(function=function, input=input, argument=argument, **options)


def field(text):
    return PayloadField("data", "jsonb", JsonbValue.from_json(text))


def test_all_source_output_types_nulls_and_chained_calls(tmp_path):
    columns = {
        "first": call("json_path", "$.items[*]"),
        "many": call("json_extract", "$.items[*]"),
        "typed": call("json_extract_with_type", "$.n"),
        "exists": call("json_exists", "$.flag == false"),
        "raw": call("json_get", "items"),
        "text": call("json_get_string", "text"),
        "integer": call("json_get_int", "price"),
        "float": call("json_get_float", "price"),
        "bool": call("json_get_bool", "flag"),
        "contains": call("json_array_contains", "$.items", needle="2"),
        "length": call("json_array_length", "$.items"),
        "nested": call("json_get_string", "name", input=call("json_get", "profile")),
    }
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(1, fields=[field('{items:[1,2],n:null,flag:"YES",text:"hello",price:1.5,profile:{name:"Alice"}}')]),
                              PointMutation.upsert(2), PointMutation.upsert(3, fields=[PayloadField("data", "null", None)])])
        scanner = scan_record_batches(db, columns=("id",), json_columns=columns)
        batches = list(scanner)
        result = pa.Table.from_batches(batches)
        assert result["id"].to_pylist() == [1, 2, 3]
        expected = dict(first="1", many="[1,2]", exists=True,
            raw=JsonbValue.from_json("[1,2]").data, text="hello", integer=2, float=1.5,
            bool=True, contains=True, length=2, nested="Alice")
        for name, value in expected.items():
            assert result[name].to_pylist() == [value, None, None]
        assert result["typed"].to_pylist() == [dict(value=JsonbValue.from_json("null").data, type_tag=0),
                                            dict(value=None, type_tag=0), dict(value=None, type_tag=0)]
        assert result["typed"].type == pa.struct([pa.field("value", pa.large_binary()), pa.field("type_tag", pa.uint8(), nullable=False)])
        assert result["raw"].type == pa.large_binary()
        assert result["first"].type == pa.string()
        assert result["integer"].type == pa.int64()
        assert result["float"].type == pa.float64()
        assert result["bool"].type == pa.bool_()
        assert result["typed"].null_count == 0
        assert scanner.stats["borrowed_bytes"] == 0
    assert batches[0].column("nested")[0].as_py() == "Alice"


def test_nonfinite_float_and_signed_zero_are_source_values(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(i, fields=[field('{v:'+number+'}')])
                              for i, number in enumerate(["NaN", "Infinity", "-Infinity", "-0.0"])])
        result = pa.Table.from_batches(list(scan_record_batches(db, columns=(), json_columns={"v": call("json_get_float", "v")})))
        values = result["v"].to_pylist()
        assert math.isnan(values[0])
        assert values[1:3] == [math.inf, -math.inf]
        assert values[3] == 0 and math.copysign(1, values[3]) == -1


def test_empty_scan_validates_expressions_and_preserves_schema(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        scanner = scan_record_batches(db, columns=(), json_columns={"v": call("json_get_float", "v")})
        assert scanner.schema == pa.schema([pa.field("v", pa.float64())])
        assert list(scanner) == []
        for expression in [call("bad", "$"), call("json_extract", "$["),
                call("json_get", "x", input=call("json_get_float", "x")),
                call("json_get", "x", needle="extra"), call("json_array_contains", "$"),
                call("json_get", "x", max_work=True), call("json_get", "x", extra=True)]:
            with pytest.raises(ValidationError):
                scan_record_batches(db, json_columns={"bad": expression})


@pytest.mark.parametrize("flush", [False, True])
def test_snapshot_reopen_filters_and_owned_slices(tmp_path, flush):
    db = Collection(tmp_path, 1)
    db.apply_point_batch([PointMutation.upsert(i, fields=[field('{value:'+str(i)+'}')]) for i in (1, 2, 3)])
    columns = {"n": call("json_get_int", "value"), "owned": call("json_get", "value")}
    captured = scan_record_batches(db, columns=("id",), batch_size=1, json_columns=columns)
    db.set_payload({"data": JsonbValue.from_json('{value:99}')}, points=[1])
    if flush:
        db.flush()
    db.close()
    batches = list(captured)
    owned = [batch.slice(0, 1) for batch in batches]
    del batches, captured
    assert sorted(row["n"] for batch in owned for row in batch.to_pylist()) == [1, 2, 3]
    assert sorted(JsonbValue(row["owned"]).to_json() for batch in owned for row in batch.to_pylist()) == ["1", "2", "3"]
    with closing(Collection(tmp_path, 1)) as db:
        values = pa.Table.from_batches(list(scan_record_batches(db, columns=("id",), json_columns=columns))).to_pylist()
        assert {row["id"]: row["n"] for row in values} == {1: 99, 2: 2, 3: 3}
        db.set_payload({"data": "wrong type"}, points=[3])
        filt = dict(kind="has_id", ids=[1, 2])
        result = pa.Table.from_batches(list(scan_record_batches(db, columns=("id",), json_columns=columns, filter=filt)))
        assert sorted(result["id"].to_pylist()) == [1, 2]
        sequence = db.last_sequence
        failed = scan_record_batches(db, columns=(), json_columns=columns)
        with pytest.raises(ValidationError, match="JSONB payload"):
            list(failed)
        assert failed.closed
        assert db.last_sequence == sequence


@pytest.mark.parametrize("option", ["max_work", "max_results", "max_bytes"])
def test_expression_limits_close_scanner(tmp_path, option):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [field('[1,2,3]')])
        scanner = scan_record_batches(db, columns=(), json_columns={"x": call("json_extract", "$[*]", **{option: 1})})
        with pytest.raises(ValidationError, match="resource limit"):
            next(scanner)
        assert scanner.closed


def test_separate_row_budget_controls_and_projection_bounds(tmp_path):
    from akashadb import CancellationToken
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [field('{items:[1,2,3,4]}')])
        expr = {"x": call("json_extract", "$.items[*]")}
        # One scanned row still permits a multi-step source selector.
        assert list(scan_record_batches(db, columns=(), json_columns=expr, max_candidates=1))[0]["x"].to_pylist() == ["[1,2,3,4]"]
        scanner = scan_record_batches(db, columns=(), json_columns=expr, batch_size=1, max_batch_bytes=8)
        with pytest.raises(ValidationError, match="intermediate"):
            next(scanner)
        assert scanner.closed
        token = CancellationToken()
        scanner = scan_record_batches(db, columns=(), json_columns=expr, cancellation=token)
        token.cancel()
        with pytest.raises(ValidationError, match="cancelled"):
            next(scanner)
        expired = scan_record_batches(db, columns=(), json_columns=expr, deadline_ns=1)
        with pytest.raises(ValidationError, match="deadline"):
            next(expired)
        assert expired.closed
        chain = call("json_get", "x")
        for _ in range(16):
            chain = call("json_get", "x", input=chain)
        with pytest.raises(ValidationError, match="step resource limit"):
            scan_record_batches(db, columns=(), json_columns={"x": chain})
        with pytest.raises(ValidationError, match="column resource limit"):
            scan_record_batches(db, columns=(), json_columns={str(i): call("json_get", "x") for i in range(257)})
        with pytest.raises(ValueError, match="unique"):
            scan_record_batches(db, columns=("id",), json_columns={"id": call("json_get", "x")})


def test_null_arguments_late_row_cast_failure_and_input_error_order(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(1, fields=[field('{v:true}')]),
                             PointMutation.upsert(2, fields=[field('{v:42}')])])
        expr = {"x": call("json_get_bool", "v")}
        scanner = scan_record_batches(db, columns=(), json_columns=expr)
        with pytest.raises(ValidationError, match="boolean"):
            next(scanner)
        assert scanner.closed and scanner.stats["rows"] == 0
        expr = {"null": call("json_get_bool", None),
                "typed": call("json_extract_with_type", None),
                "contains": call("json_array_contains", "$", needle=None)}
        result = pa.Table.from_batches(list(scan_record_batches(db, columns=(), json_columns=expr))).to_pydict()
        assert result == {"null": [None, None], "typed": [dict(value=None, type_tag=0)]*2, "contains": [None, None]}


def test_output_budget_is_shared_across_computed_columns(tmp_path):
    import json
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [field(json.dumps({"v": "x"*600}))])
        expr = call("json_get_string", "v")
        success = list(scan_record_batches(db, columns=(), batch_size=1,
            json_columns={"x": expr}, max_batch_bytes=1024))
        assert success[0]["x"].to_pylist() == ["x"*600]
        scanner = scan_record_batches(db, columns=(), batch_size=1,
            json_columns={"x": expr, "y": expr}, max_batch_bytes=1024)
        with pytest.raises(ValidationError, match="batch buffer resource limit"):
            next(scanner)
        assert scanner.closed and scanner.stats["rows"] == 0
        assert success[0]["x"].to_pylist() == ["x"*600]


def test_direct_binding_rejects_invalid_alias_and_expression(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        base = dict(batch_size=1, filter=None, max_candidates=100,
                    deadline_ns=0, max_batch_bytes=1024,
                    json_expression=None, indexes=[], cancelled=False)
        for name in ("", "bad\0name"):
            with pytest.raises(ValidationError):
                db._call("scanner", {**base, "columns": [dict(name=name, kind=13,
                    payload_name="", expression=call("json_get", "x"))]})


def test_scanner_configuration_rechecks_collection_after_python_callback(tmp_path):
    db = Collection(tmp_path, 1)
    class ClosingColumn(dict):
        def __getitem__(self, key):
            if key == "expression":
                db.close()
            return super().__getitem__(key)
    options = dict(batch_size=1, filter=None, max_candidates=100, deadline_ns=0,
        json_expression=None, indexes=[], cancelled=False,
        max_batch_bytes=1024, columns=[ClosingColumn(name="x", kind=13,
            payload_name="", expression=call("json_get", "x"))])
    with pytest.raises(Exception, match="closed"):
        db._call("scanner", options)
