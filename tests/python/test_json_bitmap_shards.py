"""Incremental derived shards are optional; every read validates its source."""
from contextlib import closing
import struct
import zlib

from akashadb import Collection, JsonbValue, PayloadField, PointMutation
from test_json_catalog import predicate


def row(id, value):
    return PointMutation.upsert(id, fields=[PayloadField(
        "data", "jsonb", JsonbValue.from_json('{"v":' + str(value) + '}'))])


def seed(db):
    db.apply_point_batch([row(i, 1) for i in range(5000)])
    db.create_json_index("v", "data", "$.v")


def test_incremental_shards_reuse_rebase_shrink_and_snapshot(tmp_path):
    db = Collection(tmp_path, 1)
    seed(db)
    full, = tmp_path.glob("json-bitmap-*.cache")
    shards = [full.with_name(full.name + f".shard-{i}") for i in range(2)]
    before = [(p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes()) for p in shards]
    prepared = db.prepare_json(predicate("eq", 1), indexes=["v"])
    db.apply_point_batch([row(4500, 2)])
    db.rebuild_json_index("v")
    assert (shards[0].stat().st_ino, shards[0].stat().st_mtime_ns, shards[0].read_bytes()) == before[0]
    assert shards[1].read_bytes() != before[1][2]
    assert db.query_json(predicate("eq", 2), indexes=["v"]) == [4500]
    # Insertion before every existing ID shifts chunk boundaries and ordinals.
    db.apply_point_batch([row(-9, 2)])
    db.rebuild_json_index("v")
    assert db.query_json(predicate("eq", 2), indexes=["v"]) == [-9, 4500]
    assert prepared.execute() == list(range(5000))
    db.apply_point_batch([PointMutation.delete(i) for i in range(4000, 5000)])
    db.rebuild_json_index("v")
    assert not shards[1].exists()
    assert db.query_json(predicate("eq", 2), indexes=["v"]) == [-9]
    db.drop_json_index("v")
    assert not list(tmp_path.glob("json-bitmap-*"))
    db.close()
    assert prepared.execute() == list(range(5000))
    prepared.close()


def test_valid_crc_bad_shard_rebuild_and_read_only_cache_miss(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
    full, = tmp_path.glob("json-bitmap-*.cache")
    shard = full.with_name(full.name + ".shard-0")
    good = shard.read_bytes()
    bad = bytearray(good)
    # Last posting ordinal becomes a duplicate, with a valid envelope CRC.
    bad[-12:-4] = struct.pack("<Q", 0)
    bad[-4:] = struct.pack("<I", zlib.crc32(bad[:-4]))
    shard.write_bytes(bad)
    full.unlink()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate("eq", 1), indexes=["v"]) == list(range(5000))
        assert shard.read_bytes() == bad  # snapshot demand never publishes
        assert not full.exists()
        db.rebuild_json_index("v")
        assert shard.read_bytes() == good
        assert full.exists()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate("eq", 1), indexes=["v"]) == list(range(5000))


def test_failed_partial_publication_recovers_from_authority(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
        full, = tmp_path.glob("json-bitmap-*.cache")
        original = full.read_bytes()
        # First shard publishes; second cannot replace its temporary path.
        blocked = full.with_name(full.name + ".shard-1.tmp")
        blocked.mkdir()
        db.apply_point_batch([row(0, 2), row(4500, 2)])
        db.rebuild_json_index("v")
        assert full.read_bytes() == original
        assert db.query_json(predicate("eq", 2), indexes=["v"]) == [0, 4500]
    blocked.rmdir()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate("eq", 2), indexes=["v"]) == [0, 4500]
        db.rebuild_json_index("v")
        assert full.read_bytes() != original


def test_all_null_first_shard_does_not_choose_type_early(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(i, fields=[]) for i in range(4096)] + [row(4096, 2)])
        db.create_json_index("v", "data", "$.v")
        assert db.json_indexes()[0]["target"] == 2
        assert db.query_json(predicate("eq", 2), indexes=["v"]) == [4096]


def test_full_v1_cache_without_shards_and_torn_shard_remain_rebuildable(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        seed(db)
    full, = tmp_path.glob("json-bitmap-*.cache")
    original = full.read_bytes()
    for path in tmp_path.glob("*.cache.shard-*"):
        path.unlink()
    # A pre-sharding v1 full cache has exactly this format and identity.
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate("eq", 1), indexes=["v"]) == list(range(5000))
        assert full.read_bytes() == original
        assert not list(tmp_path.glob("*.cache.shard-*"))
        db.rebuild_json_index("v")
    shard = full.with_name(full.name + ".shard-0")
    shard.write_bytes(shard.read_bytes()[:40])
    full.unlink()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate("eq", 1), indexes=["v"]) == list(range(5000))
        db.rebuild_json_index("v")
        assert full.read_bytes() == original
