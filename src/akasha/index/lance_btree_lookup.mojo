"""Lance BTreeLookup directory search (The Lance Authors, Apache-2.0).

Ports scan_equality_pages/pages_between/pages_null using native scalar keys.
Leaf storage and predicate evaluation are independent of directory pruning.
"""
from std.sys import size_of
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapBound
from akasha.query.control import QueryControl


@fieldwise_init
struct BTreePageStats(Copyable, Movable):
    var minimum: LanceScalarKey
    var maximum: LanceScalarKey
    var null_count: Int
    var row_count: Int


@fieldwise_init
struct BTreePageMatch(Copyable, Movable):
    var page: Int
    var all_rows: Bool


struct LanceBTreeLookup(Copyable, Movable):
    var target: UInt8
    var pages: List[BTreePageStats]
    var search_start: Int

    def __init__(out self, target: UInt8, var pages: List[BTreePageStats]) raises:
        _ = LanceScalarKey.null(target)
        if len(pages) > 1_000_000:
            raise Error("B-tree page count limit exceeded")
        self.target = target
        self.search_start = len(pages)
        var bytes = len(pages) * size_of[BTreePageStats]()
        for i in range(len(pages)):
            ref page = pages[i]
            bytes += len(page.minimum._bytes) + len(page.maximum._bytes)
            if bytes > 64 * 1024 * 1024:
                raise Error("B-tree directory byte limit exceeded")
            page.minimum.validate(target)
            page.maximum.validate(target)
            if page.row_count <= 0 or page.null_count < 0 or page.null_count > page.row_count:
                raise Error("invalid B-tree page cardinality")
            if page.minimum._compare_same(page.maximum) > 0:
                raise Error("invalid B-tree page range")
            if page.minimum.is_null != (page.null_count > 0) or page.maximum.is_null != (page.null_count == page.row_count):
                raise Error("invalid B-tree page null statistics")
            if i > 0 and pages[i-1].minimum._compare_same(page.minimum) > 0:
                raise Error("B-tree page minima must be sorted")
            if not page.maximum.is_null and self.search_start == len(pages):
                self.search_start = i
        self.pages = pages^

    def _partition(self, key: LanceScalarKey, *, after: Bool = False, end: Int = -1) -> Int:
        var lo = 0
        var hi = len(self.pages) if end < 0 else end
        while lo < hi:
            var mid = lo + (hi-lo)//2
            var compare = self.pages[mid].minimum._compare_same(key)
            if compare < 0 or (after and compare == 0):
                lo = mid + 1
            else:
                hi = mid
        return lo

    def _start(self, key: LanceScalarKey) -> Int:
        var p = self._partition(key)
        if p == 0:
            return self.search_start
        var first = self._partition(self.pages[p-1].minimum, end=p)
        return max(first, self.search_start)

    def pages_null(self, control: Optional[QueryControl] = None) raises -> List[BTreePageMatch]:
        var result = List[BTreePageMatch]()
        if control:
            control.value().checkpoint(0)
        # Source returns mixed null pages first, followed by all-null pages.
        for all_null in [False, True]:
            for i in range(len(self.pages)):
                if control:
                    control.value().checkpoint(i)
                if self.pages[i].null_count > 0 and self.pages[i].maximum.is_null == all_null:
                    result.append(BTreePageMatch(i, all_null))
        return result^

    def pages_eq(self, key: LanceScalarKey,
                 control: Optional[QueryControl] = None) raises -> List[BTreePageMatch]:
        key.validate(self.target)
        if control:
            control.value().checkpoint(0)
        if key.is_null:
            return self.pages_null(control)
        var result = List[BTreePageMatch]()
        var start = self._start(key)
        var end = self._partition(key, after=True)
        for i in range(start, end):
            if control:
                control.value().checkpoint(i)
            ref page = self.pages[i]
            if not page.maximum.is_null and page.maximum._compare_same(key) >= 0:
                result.append(BTreePageMatch(i, False))
        return result^

    def pages_in(self, values: List[LanceScalarKey],
                 control: Optional[QueryControl] = None) raises -> List[BTreePageMatch]:
        if control:
            control.value().checkpoint(0)
        if len(values) > 65_536:
            raise Error("B-tree IN literal limit exceeded")
        var seen = List[Bool](length=len(self.pages), fill=False)
        for value in values:
            for candidate in self.pages_eq(value, control):
                seen[candidate.page] = True
        var result = List[BTreePageMatch]()
        for i in range(len(seen)):
            if seen[i]:
                result.append(BTreePageMatch(i, False))
        return result^

    def pages_between(self, lower: LanceBitmapBound, upper: LanceBitmapBound,
                      control: Optional[QueryControl] = None) raises -> List[BTreePageMatch]:
        if control:
            control.value().checkpoint(0)
        if lower.key:
            lower.key.value().validate(self.target)
        if upper.key:
            upper.key.value().validate(self.target)
        var start = self._start(lower.key.value()) if lower.key else self.search_start
        # Source includes min == upper even for an exclusive bound; the leaf
        # predicate then resolves the boundary exactly.
        var end = self._partition(upper.key.value(), after=True) if upper.key else len(self.pages)
        var result = List[BTreePageMatch]()
        for i in range(start, end):
            if control:
                control.value().checkpoint(i)
            ref page = self.pages[i]
            if page.maximum.is_null:
                continue
            if lower.key:
                var compare = page.maximum._compare_same(lower.key.value())
                if compare < 0 or (compare == 0 and not lower.included):
                    continue
            if page.minimum.is_null:
                result.append(BTreePageMatch(i, False))
                continue
            var full = True
            if lower.key:
                var compare = page.minimum._compare_same(lower.key.value())
                full = compare > 0 or (compare == 0 and lower.included)
            if upper.key:
                var compare = page.maximum._compare_same(upper.key.value())
                full = full and (compare < 0 or (compare == 0 and upper.included))
            result.append(BTreePageMatch(i, full))
        return result^
