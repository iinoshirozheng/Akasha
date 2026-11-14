from test_lance_btree import _build
from akasha.index.lance_bitmap import LanceBitmapRow, LanceBitmapQuery
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_btree import LanceBTreeIndex
from akasha.index.roaring_rows import RoaringRowSet
from akasha.storage.btree_pages import map_btree_pages
from akasha.storage.index_cache import publish_mapped_cache, load_cache_artifact
from akasha.query.control import QueryControl, CancellationToken
from std.memory import ArcPointer
from std.python import Python, PythonObject
from test_lance_bitmap import _rows, _key, _u64
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def test_update_filter_spill_and_reopen() raises:
    var rows = List[LanceBitmapRow]()
    for i in range(5000):
        rows.append(LanceBitmapRow(LanceScalarKey.integer(Int64(i)), UInt64(i)))
    var old = _build(rows, 2, 4096)
    var removed = RoaringRowSet()
    _ = removed.insert(1)
    var new = old.updated([LanceBitmapRow(LanceScalarKey.integer(-7), 1),
        LanceBitmapRow(LanceScalarKey.null(2), 5000)], removed=Optional(removed^),
        sequence=18, source_checksum=43, sort_memory_bytes=512)
    assert_equal(new.pages.row_count, 5001)
    assert_equal(new.pages.artifact[].sequence, 18)
    assert_equal(new.pages.artifact[].source_checksum, 43)
    assert_equal(old.search(LanceBitmapQuery.equals(LanceScalarKey.integer(1))).selected_rows.count(), 1)
    assert_equal(new.search(LanceBitmapQuery.equals(LanceScalarKey.integer(1))).selected_rows.count(), 0)
    assert_equal(new.search(LanceBitmapQuery.equals(LanceScalarKey.integer(-7))).selected_rows.values(), [UInt64(1)])
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    publish_mapped_cache(path, "updated.cache", new.pages.artifact[])
    var artifact = load_cache_artifact(path + "/updated.cache")
    var reopened = LanceBTreeIndex(map_btree_pages(ArcPointer(artifact.take()), "data", "$.v", 2, 5001))
    assert_equal(reopened.search(LanceBitmapQuery.is_null()).selected_rows.values(), [UInt64(5000)])
    with assert_raises():
        _ = old.updated([LanceBitmapRow(LanceScalarKey.integer(7), 1)], sequence=18, source_checksum=43)
    with assert_raises():
        _ = old.updated([LanceBitmapRow(LanceScalarKey.text("wrong"), 5001)], sequence=18, source_checksum=43)


def test_remap_delete_preserve_collision_and_empty() raises:
    var old = _build([LanceBitmapRow(LanceScalarKey.integer(3), 0),
        LanceBitmapRow(LanceScalarKey.integer(3), 1),
        LanceBitmapRow(LanceScalarKey.null(2), 2)], 2, 1)
    var mapping = Dict[UInt64, Optional[UInt64]]()
    mapping[0] = Optional(UInt64.MAX)
    mapping[2] = None
    var new = old.remapped(mapping, sequence=18, source_checksum=43)
    assert_equal(new.pages.row_count, 2)
    assert_equal(new.search(LanceBitmapQuery.equals(LanceScalarKey.integer(3))).selected_rows.values(), [UInt64(1), UInt64.MAX])
    assert_equal(old.search(LanceBitmapQuery.is_null()).selected_rows.values(), [UInt64(2)])
    mapping[0] = Optional(UInt64(1))
    with assert_raises():
        _ = old.remapped(mapping, sequence=18, source_checksum=43)
    mapping[0] = None
    mapping[1] = None
    var empty = old.remapped(mapping, sequence=18, source_checksum=43)
    assert_equal(empty.pages.row_count, 0)
    assert_equal(empty.search(LanceBitmapQuery.is_null()).selected_rows.count(), 0)
    var token = CancellationToken()
    token.cancel()
    var control = QueryControl(token, max_candidates=100)
    with assert_raises():
        _ = old.remapped(mapping, sequence=18, source_checksum=43, control=Optional(control.copy()))
    with assert_raises():
        _ = old.updated(List[LanceBitmapRow](), sequence=18, source_checksum=43, control=Optional(control.copy()))
    assert_equal(old.pages.row_count, 3)


def test_lifecycle_types_and_resource_failure() raises:
    var keys: List[LanceScalarKey] = [LanceScalarKey.boolean(True),
        LanceScalarKey.integer(-7), LanceScalarKey.float_bits(0x7ff8000000000001),
        LanceScalarKey.text("雪"), LanceScalarKey.binary([UInt8(0), 255])]
    for key in keys:
        var old = _build([LanceBitmapRow(key.copy(), 0),
            LanceBitmapRow(LanceScalarKey.null(key.target), 1)], key.target, 1)
        var new = old.updated([LanceBitmapRow(key.copy(), 2)], sequence=18, source_checksum=43)
        var mapping = Dict[UInt64, Optional[UInt64]]()
        mapping[0] = None
        mapping[1] = Optional(UInt64(3))
        var remapped = new.remapped(mapping, sequence=19, source_checksum=44)
        assert_equal(remapped.pages.row_count, 2)
        assert_equal(remapped.search(LanceBitmapQuery.is_null()).selected_rows.values(), [UInt64(3)])
        assert_equal(remapped.pages.read_page(0)[1].key.compare(key), 0)
        var token = CancellationToken()
        var control = Optional(QueryControl(token, max_candidates=1))
        with assert_raises():
            _ = old.updated([], sequence=18, source_checksum=43, control=control.copy())
        with assert_raises():
            _ = old.remapped(mapping, sequence=18, source_checksum=43, control=control.copy())
        assert_equal(old.pages.row_count, 2)


def _assert_source_rows(index: LanceBTreeIndex, expected: PythonObject, target: UInt8) raises:
    var actual = Dict[UInt64, LanceScalarKey]()
    for page in range(len(index.pages.locations)):
        for row in index.pages.read_page(page):
            actual[row.id] = row.key.copy()
    assert_equal(len(actual), len(expected))
    for row in expected:
        var id = _u64(row["id"])
        var key = _key(row["value"], target)
        assert_equal(actual[id].compare(key), 0)
        if target == 3 and not key.is_null:
            assert_equal(actual[id]._bits, key._bits)


def test_original_lance_lifecycle_corpus() raises:
    var cases = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/lance-btree-lifecycle/cases.json").read())
    for scenario in cases:
        var target = UInt8(Int(py=scenario["type"]))
        var old = _build(_rows(scenario["old"], target), target, 3)
        var removed = RoaringRowSet()
        for id in scenario["removed"]:
            _ = removed.insert(_u64(id))
        var updated = old.updated(_rows(scenario["new"], target), sequence=18,
            source_checksum=43, removed=Optional(removed^), sort_memory_bytes=128)
        _assert_source_rows(updated, scenario["updated"], target)
        var mapping = Dict[UInt64, Optional[UInt64]]()
        for pair in scenario["mapping"]:
            mapping[_u64(pair[0])] = None if Bool(py=pair[1] == Python.none()) else Optional(_u64(pair[1]))
        var remapped = old.remapped(mapping, sequence=18, source_checksum=43)
        _assert_source_rows(remapped, scenario["remapped"], target)
    assert_equal(len(cases), 105)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
