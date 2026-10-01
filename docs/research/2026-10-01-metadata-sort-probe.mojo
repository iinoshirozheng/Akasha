"""Check official stable sort's entry copies on the project-pinned compiler.

This wrapper counts every Copyable operation on the real production entry types.
The counter outlives the temporary entries; the pointer never leaves _check.
"""

from akasha.document.value import PayloadValue
from akasha.index.keyword import KeywordIndex, _KeywordEntry
from akasha.index.sorted_block import SortedBlockIndex, _IntEntry, _FloatEntry
from std.sys import size_of
from std.testing import assert_equal, assert_true


struct Counted[T: Deinitable & Copyable & Comparable](
    Comparable, Copyable, Movable
):
    var value: Self.T
    var copies: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self, var value: Self.T, copies: Pointer[Int, MutUntrackedOrigin]
    ):
        self.value = value^
        self.copies = copies

    def __init__(out self, *, copy: Self):
        copy.copies[] += 1
        self.copies = copy.copies
        self.value = copy.value.copy()

    def __lt__(self, other: Self) -> Bool:
        return self.value < other.value

    def __gt__(self, other: Self) -> Bool:
        return self.value > other.value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def __le__(self, other: Self) -> Bool:
        return self.value <= other.value

    def __ge__(self, other: Self) -> Bool:
        return self.value >= other.value


def _check[T: Deinitable & Copyable & Comparable](entries: List[T]) raises:
    var copies = 0
    var wrapped = List[Counted[T]](capacity=len(entries))
    for entry in entries:
        wrapped.append(
            Counted(
                entry.copy(),
                Pointer[Int, MutUntrackedOrigin](
                    unsafe_from_address=Int(Pointer(to=copies))
                ),
            )
        )
    # Prove the instrumentation fires before measuring the real sorting path.
    if len(wrapped) > 0:
        var copied = wrapped[0].copy()
        assert_true(copied.value == wrapped[0].value)
        assert_equal(copies, 1)
    copies = 0
    sort[stable=True](Span(wrapped))
    assert_equal(copies, 0)
    for i in range(1, len(wrapped)):
        assert_true(wrapped[i - 1] <= wrapped[i])
    print("entries", len(wrapped), "entry_copies", copies)


def main() raises:
    print(
        "descriptor_bytes keyword",
        size_of[_KeywordEntry](),
        "int",
        size_of[_IntEntry](),
        "float",
        size_of[_FloatEntry](),
    )
    for count in [0, 1, 31, 32, 33, 10_000, 100_000]:
        var keyword = KeywordIndex(count)
        var numbers = SortedBlockIndex(count)
        keyword.begin_bulk()
        numbers.begin_bulk()
        for ordinal in range(count):
            var name = "field-" * 16 + String(ordinal % 3)
            keyword.add(
                name,
                PayloadValue.string(
                    "value-" * 16 + String((ordinal * 7919) % 1000)
                ),
                ordinal,
            )
            numbers.add(
                name,
                PayloadValue.integer(Int64((ordinal * 7919) % 1000)),
                ordinal,
            )
            numbers.add(
                name,
                PayloadValue.floating(Float64((ordinal * 7919) % 1000)),
                ordinal,
            )
        _check(keyword._entries)
        _check(numbers._integers)
        _check(numbers._floats)
