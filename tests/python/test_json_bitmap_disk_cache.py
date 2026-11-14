from contextlib import closing

from akashadb import Collection, JsonbValue, PayloadField, PointMutation
from test_json_catalog import populate, predicate


def test_disk_cache_shared_definition_drop_and_reopen(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        db.create_json_index("one", "data", "$.v")
        files = list(tmp_path.glob("json-bitmap-*.cache"))
        assert len(files) == 1
        cache = files[0]
        db.create_json_index("two", "data", "$.v")
        assert len(list(tmp_path.glob("json-bitmap-*.cache"))) == 1
        db.drop_json_index("one")
        assert cache.exists()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate(), indexes=["two"]) == [2, 9]
        db.drop_json_index("two")
        assert not cache.exists()


def test_corrupt_cache_and_publication_failure_leave_authority_usable(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        db.create_json_index("v", "data", "$.v")
        cache, = tmp_path.glob("json-bitmap-*.cache")
        original = cache.read_bytes()
        temporary = cache.with_name(cache.name + ".tmp")
        temporary.mkdir()
        try:
            db.rebuild_json_index("v")
            assert cache.read_bytes() == original
            assert db.query_json(predicate(), indexes=["v"]) == [2, 9]
        finally:
            temporary.rmdir()
    cache.write_bytes(original[:-1])
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate(), indexes=["v"]) == [2, 9]
        db.rebuild_json_index("v")
        assert cache.read_bytes() == original


def test_public_create_rebuild_and_reopen_with_spilled_sort(tmp_path):
    # Converted key bytes alone exceed the collection's 8 MiB run budget.
    # Repeated keys keep the resulting bitmap small, independent of sort input.
    value = "s" * 300_000
    expression = {"kind": "predicate", "projection": {
        "function": "json_get_string", "input": "data", "argument": "v"},
        "operator": "eq", "value": value}
    payload = JsonbValue.from_json('{"v":"' + value + '"}')
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(i, fields=[
            PayloadField("data", "jsonb", payload)]) for i in range(32)])
        db.create_json_index("v", "data", "$.v")
        assert db.query_json(expression, indexes=["v"]) == list(range(32))
        db.rebuild_json_index("v")
        assert db.query_json(expression, indexes=["v"]) == list(range(32))
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(expression, indexes=["v"]) == list(range(32))
