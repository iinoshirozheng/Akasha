"""Lance materialized nullable set/mask algebra (Lance Authors, Apache-2.0).

Raw selected and null sets may overlap or store nulls only in the null set.
Null always overrides selected; allow/block masks avoid enumerating a universe.
"""
from akasha.index.roaring_rows import RoaringRowSet


@fieldwise_init
struct NullableRowSet(Copyable, Movable):
    var selected_rows: RoaringRowSet
    var nulls: RoaringRowSet

    def selected(self, id: UInt64) raises -> Bool:
        return self.selected_rows.contains(id) and not self.nulls.contains(id)

    def true_rows(self) raises -> RoaringRowSet:
        return self.selected_rows.difference(self.nulls)

    @staticmethod
    def union_all(selections: List[NullableRowSet]) raises -> NullableRowSet:
        var selected = RoaringRowSet()
        var nulls = RoaringRowSet()
        var any_true = RoaringRowSet()
        for selection in selections:
            selected = selected.union_with(selection.selected_rows)
            nulls = nulls.union_with(selection.nulls)
            any_true = any_true.union_with(selection.true_rows())
        return NullableRowSet(selected^, nulls.difference(any_true))


@fieldwise_init
struct NullableRowMask(Copyable, Movable):
    var rows: NullableRowSet
    var block: Bool

    def selected(self, id: UInt64) raises -> Bool:
        return (not self.rows.selected_rows.contains(id) if self.block else self.rows.selected_rows.contains(id)) and not self.rows.nulls.contains(id)

    def negated(self) -> Self:
        return Self(self.rows.copy(), not self.block)

    def and_with(self, other: Self) raises -> Self:
        ref a = self.rows
        ref b = other.rows
        if not self.block and not other.block:
            var nulls = a.nulls.intersection(b.nulls).union_with(a.nulls.intersection(b.selected_rows)).union_with(b.nulls.intersection(a.selected_rows))
            return Self(NullableRowSet(a.selected_rows.intersection(b.selected_rows), nulls^), False)
        if self.block and not other.block:
            return other.and_with(self)
        if not self.block:
            var nulls = a.nulls.intersection(b.nulls).union_with(a.nulls.difference(b.selected_rows)).union_with(b.nulls.intersection(a.selected_rows))
            return Self(NullableRowSet(a.selected_rows.difference(b.selected_rows), nulls^), False)
        var nulls = a.nulls.intersection(b.nulls).union_with(a.nulls.difference(b.selected_rows)).union_with(b.nulls.difference(a.selected_rows))
        return Self(NullableRowSet(a.selected_rows.union_with(b.selected_rows), nulls^), True)

    def or_with(self, other: Self) raises -> Self:
        ref a = self.rows
        ref b = other.rows
        if not self.block and not other.block:
            var true_rows = a.selected_rows.difference(a.nulls).union_with(b.selected_rows.difference(b.nulls))
            var nulls = a.nulls.union_with(b.nulls).difference(true_rows)
            var selected = a.selected_rows.union_with(b.selected_rows).union_with(nulls)
            return Self(NullableRowSet(selected^, nulls^), False)
        if self.block and not other.block:
            return other.or_with(self)
        if not self.block:
            var allow_true = a.selected_rows.difference(a.nulls)
            var block_false = b.selected_rows.difference(b.nulls)
            var nulls = a.nulls.intersection(block_false).union_with(b.nulls.difference(allow_true))
            var selected = block_false.difference(allow_true).union_with(nulls)
            return Self(NullableRowSet(selected^, nulls^), True)
        var a_false = a.selected_rows.difference(a.nulls)
        var b_false = b.selected_rows.difference(b.nulls)
        var nulls = a.nulls.intersection(b_false).union_with(b.nulls.intersection(a_false)).union_with(a.nulls.intersection(b.nulls))
        var selected = a_false.intersection(b_false).union_with(nulls)
        return Self(NullableRowSet(selected^, nulls^), True)
