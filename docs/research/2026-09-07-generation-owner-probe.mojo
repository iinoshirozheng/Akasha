"""Compiled ownership proof for ADR 0007; not an engine implementation."""

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true


struct FrozenField(Movable):
    var values: List[Float32]

    def __init__(out self, var values: List[Float32]):
        self.values = values^


struct ViewRoot(Movable):
    var base: ArcPointer[FrozenField]
    var deltas: List[ArcPointer[FrozenField]]
    var sequence: UInt64

    def __init__(
        out self, var base: ArcPointer[FrozenField],
        var deltas: List[ArcPointer[FrozenField]], sequence: UInt64,
    ):
        self.base = base^
        self.deltas = deltas^
        self.sequence = sequence


struct FieldLease(Movable):
    var _owner: Optional[ArcPointer[FrozenField]]

    def __init__(out self, var owner: ArcPointer[FrozenField]):
        self._owner = Optional(owner^)

    def first(self) raises -> Float32:
        if not self._owner:
            raise Error("field lease closed")
        var operation_owner = self._owner.value()
        return _readonly_values(operation_owner[])[0]

    def buffer_address(self) raises -> Int:
        if not self._owner:
            raise Error("field lease closed")
        var operation_owner = self._owner.value()
        return Int(_readonly_values(operation_owner[]).unsafe_ptr())

    def close(mut self):
        self._owner = Optional[ArcPointer[FrozenField]]()


def _readonly_values(field: FrozenField) -> Span[Float32, origin_of(field.values)]:
    return Span(field.values)


def main() raises:
    var original: List[Float32] = [1.0, 2.0, 3.0]
    var address = Int(original.unsafe_ptr())
    var base = ArcPointer(FrozenField(original^))
    var old_root = ArcPointer(ViewRoot(base, List[ArcPointer[FrozenField]](), 7))
    var old_snapshot = old_root
    assert_true(old_snapshot is old_root)
    var output = FieldLease(old_root[].base)
    assert_equal(output.buffer_address(), address)
    # Freeze a new delta by move. Copying root handles does not copy base data.
    var pending: List[Float32] = [9.0]
    var delta_address = Int(pending.unsafe_ptr())
    var delta = ArcPointer(FrozenField(pending^))
    var deltas = old_root[].deltas.copy()
    deltas.append(delta)
    var new_root = ArcPointer(ViewRoot(base, deltas^, 8))
    assert_equal(Int(new_root[].base[].values.unsafe_ptr()), address)
    assert_equal(Int(new_root[].deltas[0][].values.unsafe_ptr()), delta_address)
    assert_equal(old_snapshot[].sequence, UInt64(7))
    assert_equal(new_root[].sequence, UInt64(8))
    assert_equal(len(old_snapshot[].deltas), 0)
    # End every collection/snapshot owner; the exported field lease still owns
    # the allocation. A final close releases it after the last borrow ends.
    _ = old_root^
    _ = old_snapshot^
    _ = new_root^
    _ = base^
    _ = delta^
    assert_equal(output.first(), 1.0)
    assert_equal(output.buffer_address(), address)
    assert_equal(output._owner.value().count(), UInt64(1))
    output.close()
    output.close()
    print("PASS moved base/delta buffers, distinct sequence roots, shared handles, exported lease after owner release")
