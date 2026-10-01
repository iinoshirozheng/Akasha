from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    ReadSnapshot,
    SparseElement,
)
from akasha.common.config import CollectionConfig
from akasha.index.flat import SearchResult
from akasha.query.fusion import reciprocal_rank_fusion
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import (
    HEAD_MAX_POINTS,
    ReadGeneration,
    ReadGenerationCache,
)
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

comptime SPAN = 800
"""Point IDs span [-SPAN, SPAN) so negative IDs order ties."""


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "/manifest.bin",
        "/manifest.bin.tmp",
        "/wal.bin",
        "/wal.bin.tmp",
        "/sparse.wal",
        "/sparse.wal.tmp",
    ]:
        remove_file_if_exists(path + name)
    for sequence in range(8):
        for prefix in [
            "/segment-base-",
            "/segment-delta-",
            "/sparse-base-",
            "/sparse-delta-",
        ]:
            remove_file_if_exists(path + prefix + String(sequence) + ".bin")


def _color_fields(color: Int) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("color", PayloadValue.integer(Int64(color))))
    return fields^


def _red() raises -> FilterExpression:
    return FilterExpression.condition(
        FilterCondition.equal("color", PayloadValue.integer(1))
    )


def _not_red() raises -> FilterExpression:
    return FilterExpression.negate(_red())


def _modulo(value: Int, divisor: Int) -> Int:
    return ((value % divisor) + divisor) % divisor


struct _Model(Copyable, Movable):
    """An owned oracle of the latest point states, indexed by ID + SPAN."""

    var live: List[Bool]
    var vector: List[Float32]
    var color: List[Int]
    var sparse: List[List[SparseElement]]

    def __init__(out self):
        self.live = List[Bool]()
        self.vector = List[Float32]()
        self.color = List[Int]()
        self.sparse = List[List[SparseElement]]()
        for _ in range(2 * SPAN):
            self.live.append(False)
            self.vector.append(0.0)
            self.color.append(-1)
            self.sparse.append(List[SparseElement]())

    def upsert(mut self, id: Int, value: Float32, color: Int):
        """A dense write replaces vector and payload; sparse survives only
        on a live point."""
        var slot = id + SPAN
        if not self.live[slot]:
            self.sparse[slot] = List[SparseElement]()
        self.live[slot] = True
        self.vector[slot] = value
        self.color[slot] = color

    def delete(mut self, id: Int):
        var slot = id + SPAN
        self.live[slot] = False
        self.color[slot] = -1
        self.sparse[slot] = List[SparseElement]()

    def is_red(self, slot: Int) -> Bool:
        return self.color[slot] == 1

    def matches(self, slot: Int, filter: Int) -> Bool:
        """filter: 0 none, 1 red, 2 NOT red (true when color is absent)."""
        if filter == 1:
            return self.is_red(slot)
        if filter == 2:
            return not self.is_red(slot)
        return True

    def sparse_top(
        self, query: List[SparseElement], k: Int, filter: Int
    ) -> List[SearchResult]:
        var scored = List[SearchResult]()
        for slot in range(2 * SPAN):
            if not self.live[slot] or not self.matches(slot, filter):
                continue
            var score = Optional[Float32]()
            for term in query:
                for element in self.sparse[slot]:
                    if element.term_id == term.term_id:
                        var contribution = term.weight * element.weight
                        if score:
                            score = Optional(score.value() + contribution)
                        else:
                            score = Optional(contribution)
            if score:
                scored.append(SearchResult(slot - SPAN, score.value()))
        return _ranked(scored^, k)

    def dense_top(
        self, query: Float32, k: Int, filter: Int
    ) -> List[SearchResult]:
        var scored = List[SearchResult]()
        for slot in range(2 * SPAN):
            if self.live[slot] and self.matches(slot, filter):
                scored.append(
                    SearchResult(slot - SPAN, query * self.vector[slot])
                )
        return _ranked(scored^, k)


def _ranked(var scored: List[SearchResult], k: Int) -> List[SearchResult]:
    """Total order: higher score first, then smaller ID."""
    for index in range(1, len(scored)):
        var current = scored[index]
        var position = index
        while position > 0 and (
            scored[position - 1].score < current.score
            or (
                scored[position - 1].score == current.score
                and scored[position - 1].id > current.id
            )
        ):
            scored[position] = scored[position - 1]
            position -= 1
        scored[position] = current
    var result = List[SearchResult]()
    for index in range(min(k, len(scored))):
        result.append(scored[index])
    return result^


def _same(actual: List[SearchResult], expected: List[SearchResult]) raises:
    assert_equal(len(actual), len(expected))
    for index in range(len(expected)):
        assert_equal(actual[index].id, expected[index].id)
        assert_equal(actual[index].score, expected[index].score)


def _query() -> List[SparseElement]:
    return [SparseElement(1, 0.7), SparseElement(4, 0.3), SparseElement(9, 1.1)]


def _check(snapshot: ReadSnapshot, model: _Model) raises:
    """Every sparse, filtered and hybrid path matches the owned oracle."""
    var query = _query()
    var dense: List[Float32] = [1.0]
    _same(snapshot.search_sparse_dot(query, 25), model.sparse_top(query, 25, 0))
    _same(
        snapshot.search_sparse_dot(query, 4 * SPAN),
        model.sparse_top(query, 4 * SPAN, 0),
    )
    _same(
        snapshot.search_sparse_dot_where(query, 25, _red()),
        model.sparse_top(query, 25, 1),
    )
    _same(
        snapshot.search_sparse_dot_where(query, 25, _not_red()),
        model.sparse_top(query, 25, 2),
    )
    _same(
        snapshot.search_dot_where(dense, 25, _red()),
        model.dense_top(1.0, 25, 1),
    )
    _same(
        snapshot.search_dot_where(dense, 25, _not_red()),
        model.dense_top(1.0, 25, 2),
    )
    var conditions = List[FilterCondition]()
    conditions.append(FilterCondition.equal("color", PayloadValue.integer(1)))
    _same(
        snapshot.search_dot_filtered(dense, 25, conditions),
        model.dense_top(1.0, 25, 1),
    )
    _same(
        snapshot.search_hybrid_dot(dense, query, 10, 40),
        reciprocal_rank_fusion(
            model.dense_top(1.0, 40, 0), model.sparse_top(query, 40, 0), 10, 60
        ),
    )
    _same(
        snapshot.search_hybrid_dot_where(dense, query, 10, 40, 60, _not_red()),
        reciprocal_rank_fusion(
            model.dense_top(1.0, 40, 2), model.sparse_top(query, 40, 2), 10, 60
        ),
    )
    var records = snapshot.sparse_records()
    var position = 0
    for slot in range(2 * SPAN):
        if not model.live[slot] or len(model.sparse[slot]) == 0:
            continue
        assert_equal(records[position].id, slot - SPAN)
        assert_equal(len(records[position].elements), len(model.sparse[slot]))
        for index in range(len(model.sparse[slot])):
            assert_equal(
                records[position].elements[index].weight,
                model.sparse[slot][index].weight,
            )
        position += 1
    assert_equal(len(records), position)


def test_field_owners_are_replaced_independently() raises:
    var table = MemTable(1)
    var pins = ArcPointer(GenerationPinRegistry())
    var config = CollectionConfig.defaults(1)
    var cache = ReadGenerationCache()
    table.apply_document_upsert(-3, 1, [1.0], _color_fields(1))
    table.set_sparse(-3, [SparseElement(2, 1.0)])
    var original = cache.acquire(config, 0, 2, table, pins)

    def entry_addresses(
        root: ArcPointer[ReadGeneration], id: Int
    ) raises -> Tuple[Int, Int, Int]:
        var location = root[].find(id)
        ref entry = root[].run(location[0]).memtable.entry_ref_at(location[1])
        return (
            entry.dense_address(),
            entry.payload_address(),
            entry.sparse_address(),
        )

    var first = entry_addresses(original, -3)

    # Sparse-only: dense and payload owners are kept.
    table.set_sparse(-3, [SparseElement(2, 5.0)])
    cache.record(table, [-3], 3)
    var sparse_only = cache.acquire(config, 0, 3, table, pins)
    var second = entry_addresses(sparse_only, -3)
    assert_equal(second[0], first[0])
    assert_equal(second[1], first[1])
    assert_true(second[2] != first[2])

    # Payload-only has no public write path; replace only the payload owner.
    var slot = table.ordinal_for(-3)
    table._entries[slot]._payload = ArcPointer(_color_fields(2))
    cache.record(table, [-3], 4)
    var payload_only = cache.acquire(config, 0, 4, table, pins)
    var third = entry_addresses(payload_only, -3)
    assert_equal(third[0], second[0])
    assert_true(third[1] != second[1])
    assert_equal(third[2], second[2])

    # A full document replacement keeps the sparse owner.
    table.apply_document_upsert(-3, 5, [7.0], _color_fields(1))
    cache.record(table, [-3], 5)
    var full = cache.acquire(config, 0, 5, table, pins)
    var fourth = entry_addresses(full, -3)
    assert_true(fourth[0] != third[0])
    assert_true(fourth[1] != third[1])
    assert_equal(fourth[2], third[2])

    # Delete clears the whole point; a reinsert starts without sparse.
    table.apply_delete(-3, 6)
    table.apply_upsert(-3, 7, [9.0])
    cache.record(table, [-3], 7)
    var reinserted = cache.acquire(config, 0, 7, table, pins)
    assert_equal(entry_addresses(reinserted, -3)[2], 0)

    # Every root keeps its own point state.
    var query: List[SparseElement] = [SparseElement(2, 1.0)]
    assert_equal(
        ReadSnapshot(original).search_sparse_dot(query, 1)[0].score, 1.0
    )
    assert_equal(
        ReadSnapshot(sparse_only).search_sparse_dot(query, 1)[0].score, 5.0
    )
    assert_equal(
        len(
            ReadSnapshot(payload_only).search_sparse_dot_where(query, 1, _red())
        ),
        0,
    )
    assert_equal(
        len(
            ReadSnapshot(sparse_only).search_sparse_dot_where(query, 1, _red())
        ),
        1,
    )
    assert_equal(
        ReadSnapshot(full).search_sparse_dot_where(query, 1, _red())[0].score,
        5.0,
    )
    assert_equal(len(ReadSnapshot(reinserted).search_sparse_dot(query, 1)), 0)


def test_layered_fields_match_owned_oracle_across_roots_and_reopen() raises:
    var path = String("/tmp/akasha-49-generation-fields")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var model = _Model()
    for id in range(-SPAN, SPAN):
        var value = Float32(_modulo(id * 7, 11)) * 0.5
        if _modulo(id, 7) == 0:
            collection.upsert(id, [value])
            model.upsert(id, value, -1)
        else:
            collection.upsert_document(
                id, [value], _color_fields(_modulo(id, 3))
            )
            model.upsert(id, value, _modulo(id, 3))
        if _modulo(id, 2) == 0:
            # Few distinct weights: many exact score ties across IDs.
            var elements: List[SparseElement] = [
                SparseElement(1, Float32(_modulo(id, 5)) * 0.1 + 0.1),
                SparseElement(4, 0.3),
            ]
            collection.upsert_sparse(id, elements)
            model.sparse[id + SPAN] = elements^
    var base = collection.snapshot()
    var base_model = model.copy()

    var roots = List[ReadSnapshot]()
    var models = List[_Model]()
    var writes = 0
    for round in range(3):
        for id in range(-SPAN, SPAN):
            var slot = id + SPAN
            var kind = _modulo(id + round, 4)
            var previous = writes
            if kind == 1 and model.live[slot]:
                # Payload and dense replacement; the sparse owner survives.
                var value = Float32(_modulo(id * 3 + round, 13)) * 0.25
                var color = _modulo(id + round + 1, 3)
                collection.upsert_document(id, [value], _color_fields(color))
                model.upsert(id, value, color)
                writes += 1
            elif kind == 2 and model.live[slot]:
                var elements: List[SparseElement] = [
                    SparseElement(4, Float32(_modulo(id, 3)) * 0.2 + 0.1),
                    SparseElement(9, 0.5),
                ]
                collection.upsert_sparse(id, elements)
                model.sparse[slot] = elements^
                writes += 1
            elif kind == 3 and _modulo(id, 3) == 0:
                if model.live[slot]:
                    collection.delete(id)
                    model.delete(id)
                else:
                    collection.upsert(id, [2.0])
                    model.upsert(id, 2.0, -1)
                writes += 1
            if writes != previous and writes % 700 == 0:
                roots.append(collection.snapshot())
                models.append(model.copy())
    assert_true(writes > 2 * HEAD_MAX_POINTS)
    var latest = collection.snapshot()
    # Base, sealed runs and a frozen head all take part in the latest root.
    assert_true(latest._slot[].root.value()[].layer_count() >= 3)
    assert_true(len(roots) >= 2)

    _check(base, base_model)
    for index in range(len(roots)):
        _check(roots[index], models[index])
    _check(latest, model)

    collection.flush()
    _check(collection.snapshot(), model)
    base.close()
    latest.close()
    for index in range(len(roots)):
        roots[index].close()
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    _check(reopened.snapshot(), model)
    reopened.close()


def test_failed_sparse_write_does_not_publish_a_root() raises:
    var path = String("/tmp/akasha-49-failed-sparse")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(-1, [1.0])
    collection.upsert_sparse(-1, [SparseElement(3, 1.0)])
    var before = collection.snapshot()
    var sequence = collection.last_sequence()
    var revision = collection._read_generations[].revision
    with assert_raises():
        collection.upsert_sparse(-2, [SparseElement(3, 1.0)])
    with assert_raises():
        collection.upsert_sparse(-1, List[SparseElement]())
    with assert_raises():
        collection.upsert_sparse(
            -1, [SparseElement(4, 1.0), SparseElement(3, 1.0)]
        )
    assert_equal(collection.last_sequence(), sequence)
    var after = collection.snapshot()
    assert_true(after._slot[].root.value() is before._slot[].root.value())
    assert_equal(collection._read_generations[].revision, revision)
    assert_equal(
        after.search_sparse_dot([SparseElement(3, 1.0)], 1)[0].score, 1.0
    )
    before.close()
    after.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
