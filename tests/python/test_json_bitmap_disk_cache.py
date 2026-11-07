from contextlib import closing

from akashadb import Collection
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
