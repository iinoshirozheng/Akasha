"""Bounded, single-consumer iteration over one immutable read generation."""

from akasha.query.control import CancellationToken, QueryControl
from akasha.query.evaluator import matches_expression
from akasha.query.filter_ast import FilterExpression
from akasha.storage.memtable import MemTableEntry
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer


struct ScanBatch(Movable):
    """A bounded selection in one run, retaining its immutable source owner."""

    var root: ArcPointer[ReadGeneration]
    var layer: Int
    var ordinals: List[Int]

    def __init__(
        out self,
        var root: ArcPointer[ReadGeneration],
        layer: Int,
        var ordinals: List[Int],
    ):
        self.root = root^
        self.layer = layer
        self.ordinals = ordinals^

    def row_count(self) -> Int:
        return len(self.ordinals)

    def entry(
        self, row: Int
    ) raises -> ref[
        origin_of(
            self.root[]
            .layers[self.layer]
            .run[]
            .memtable._entries[self.ordinals[row]],
            self,
        )
    ] MemTableEntry:
        if row < 0 or row >= len(self.ordinals):
            raise Error("scanner row is outside batch")
        return (
            self.root[]
            .layers[self.layer]
            .run[]
            .memtable.entry_ref_at(self.ordinals[row])
        )


struct ReadScanner(Movable):
    """Scan run/slot order with bounded selection memory and no row copies.

    The cursor has one consumer. A returned batch owns its source independently
    of scanner/snapshot/collection close. Errors close the cursor; exhaustion
    drops its owner and subsequent calls return None until explicitly closed.
    """

    var _root: Optional[ArcPointer[ReadGeneration]]
    var _expression: Optional[FilterExpression]
    var _batch_size: Int
    var _layer: Int
    var _ordinal: Int
    var _closed: Bool
    var visited_slots: Int

    def __init__(
        out self,
        var root: ArcPointer[ReadGeneration],
        batch_size: Int,
        var expression: Optional[FilterExpression],
    ) raises:
        if batch_size <= 0:
            raise Error("scanner batch size must be positive")
        if expression:
            expression.value().validate()
        self._root = Optional(root^)
        self._expression = expression^
        self._batch_size = batch_size
        self._layer = 0
        self._ordinal = 0
        self._closed = False
        self.visited_slots = 0

    def close(mut self):
        self._closed = True
        self._root = Optional[ArcPointer[ReadGeneration]]()

    def next_batch(mut self) raises -> Optional[ScanBatch]:
        var token = CancellationToken()
        var control = QueryControl(token, max_candidates=Int.MAX)
        return self.next(control)

    def next(mut self, control: QueryControl) raises -> Optional[ScanBatch]:
        if self._closed:
            raise Error("scanner is closed")
        try:
            control.checkpoint(0)
            return self._next(control)
        except error:
            self.close()
            raise error

    def _next(mut self, control: QueryControl) raises -> Optional[ScanBatch]:
        if not self._root:
            return Optional[ScanBatch]()
        var root = self._root.value().copy()
        while self._layer < root[].layer_count():
            var layer = self._layer
            ref source = root[].run(layer).memtable
            var ordinals = List[Int](
                capacity=min(self._batch_size, source.slot_count())
            )
            while (
                self._ordinal < source.slot_count()
                and len(ordinals) < self._batch_size
            ):
                control.checkpoint(self.visited_slots)
                # Check before advancing, avoiding integer overflow at the limit.
                if self.visited_slots >= control.max_candidates:
                    raise Error("query candidate resource limit exceeded")
                self.visited_slots += 1
                var ordinal = self._ordinal
                self._ordinal += 1
                if not root[].layers[layer].is_visible(ordinal):
                    continue
                if self._expression:
                    if not matches_expression(
                        source.entry_ref_at(ordinal).fields(),
                        self._expression.value(),
                    ):
                        continue
                ordinals.append(ordinal)
            if self._ordinal == source.slot_count():
                self._layer += 1
                self._ordinal = 0
            if len(ordinals) > 0:
                var batch = ScanBatch(root.copy(), layer, ordinals^)
                if self._layer == root[].layer_count():
                    self._root = Optional[ArcPointer[ReadGeneration]]()
                return Optional(batch^)
        self._root = Optional[ArcPointer[ReadGeneration]]()
        return Optional[ScanBatch]()
