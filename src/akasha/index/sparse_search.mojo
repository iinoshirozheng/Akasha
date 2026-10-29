"""Qdrant sparse SearchContext execution over immutable native postings.

Source: lib/sparse/src/index/search_context.rs at
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
Ported plain_search, advance_batch, next_min_id and last-posting dispatch.
These postings do not provide reliable suffix-max weights, so the source's
non-pruning path applies. Native bounded Top-K retains ascending public-ID ties.
"""

from akasha.compute.topk import BoundedTopK, TopKEntry
from akasha.index.field_sparse import FieldSparseIndex, _FieldPosting
from akasha.index.sorted_postings import _lower_bound
from akasha.index.sparse import SparseElement, validate_sparse
from akasha.query.control import QueryControl
from std.math import isfinite
from std.memory import ArcPointer, bitcast


@fieldwise_init
struct SparseSearchOutcome(Movable):
    var results: List[TopKEntry[DType.float32]]
    var evaluated: Int
    var rejected: Int


@fieldwise_init
struct _PostingCursor(TrivialRegisterPassable):
    var term: Int
    var weight: Float32
    var position: Int


def _offer_sparse(
    index: FieldSparseIndex, allowed: List[Bool], row: Int, score: Float32,
    allow_zero: Bool, mut heap: BoundedTopK[DType.float32], mut rejected: Int,
) raises:
    if not allowed[row]:
        rejected += 1
        return
    # Recommendation's public contract rejects nonfinite results. Keep this
    # after visibility/filter admission so rejected rows cannot fail a query.
    if not isfinite(score):
        raise Error("recommendation score must be finite")
    if (allow_zero or score != 0) and score > bitcast[DType.float32](UInt32(0xFF7FFFFF)):
        heap.offer(index.rows[row].id, score)


def _next_sparse_row(index: FieldSparseIndex, cursors: List[_PostingCursor]) raises -> Optional[Int]:
    var next_row = Optional[Int]()
    for cursor in cursors:
        ref postings = index.postings[cursor.term]
        if cursor.position < len(postings):
            var row = postings[cursor.position].row
            if not next_row or row < next_row.value():
                next_row = Optional(row)
    return next_row^


def search_sparse_postings(
    owner: ArcPointer[FieldSparseIndex], query: List[SparseElement],
    allowed: List[Bool], k: Int, plain: Bool,
    control: Optional[QueryControl] = None,
) raises -> SparseSearchOutcome:
    """Nearest sparse search, preserving source path-specific zero admission."""
    if k <= 0:
        raise Error("sparse search k must be positive")
    validate_sparse(query)
    ref index = owner[]
    if len(allowed) != len(index.rows):
        raise Error("sparse search admission differs from its index")
    if control:
        control.value().checkpoint(0)
    if len(query) == 0 or len(index.rows) == 0:
        return SparseSearchOutcome([], 0, 0)
    var heap = BoundedTopK[DType.float32](min(k, len(index.rows)), smaller_is_better=False)
    var evaluated = 0
    var rejected = 0
    var cursors = List[_PostingCursor]()
    var last_row = 0
    for term in query:
        if term.term_id in index.postings:
            ref postings = index.postings[term.term_id]
            if len(postings) > 0:
                cursors.append(_PostingCursor(term.term_id, term.weight, 0))
                last_row = max(last_row, postings[len(postings) - 1].row)
    if plain:
        # Qdrant plain_search sorts the admitted internal IDs, seeks each
        # posting, and omits rows with no query-term overlap. Its TopK admits
        # zero sums, including cancellation and stored/query zero weights.
        for row in range(len(index.rows)):
            if control:
                control.value().checkpoint(row)
            if not allowed[row]:
                continue
            var score = Float32(0)
            var overlaps = False
            for cursor in cursors:
                ref postings = index.postings[cursor.term]
                var position = _lower_bound(postings, _FieldPosting(row, 0))
                if position < len(postings) and postings[position].row == row:
                    score += postings[position].weight * cursor.weight
                    overlaps = True
            if overlaps:
                evaluated += 1
                _offer_sparse(index, allowed, row, score, True, heap, rejected)
    else:
        var next_row = _next_sparse_row(index, cursors)
        while next_row:
            if control:
                control.value().checkpoint(0)
            var start = next_row.value()
            # Upstream range includes both endpoints (10001 IDs).
            var end = start + min(10_000, last_row - start)
            var scores = List[Float32](length=end - start + 1, fill=0)
            var touched = List[Bool](length=end - start + 1, fill=False)
            for i in range(len(cursors)):
                ref cursor = cursors[i]
                ref postings = index.postings[cursor.term]
                var operations = 0
                while cursor.position < len(postings):
                    var posting = postings[cursor.position]
                    if posting.row > end:
                        break
                    if control:
                        control.value().checkpoint(operations)
                    operations += 1
                    scores[posting.row - start] += posting.weight * cursor.weight
                    touched[posting.row - start] = True
                    cursor.position += 1
            for offset in range(len(scores)):
                if control:
                    control.value().checkpoint(offset)
                if touched[offset]:
                    evaluated += 1
                    _offer_sparse(index, allowed, start + offset, scores[offset], False, heap, rejected)
            var remaining = List[_PostingCursor](capacity=len(cursors))
            for cursor in cursors:
                if cursor.position < len(index.postings[cursor.term]):
                    remaining.append(cursor)
            cursors = remaining^
            if len(cursors) == 0:
                break
            if len(cursors) == 1:
                # Source process_last_posting_list sends each product directly
                # to TopK, so unlike advance_batch, it does not discard zero.
                var cursor = cursors[0]
                ref postings = index.postings[cursor.term]
                for position in range(cursor.position, len(postings)):
                    if control:
                        control.value().checkpoint(position)
                    var posting = postings[position]
                    if not allowed[posting.row]:
                        rejected += 1
                        continue
                    evaluated += 1
                    _offer_sparse(index, allowed, posting.row, posting.weight * cursor.weight, True, heap, rejected)
                break
            next_row = _next_sparse_row(index, cursors)
    if control:
        control.value().checkpoint(0)
    return SparseSearchOutcome(heap.sorted_entries(), evaluated, rejected)
