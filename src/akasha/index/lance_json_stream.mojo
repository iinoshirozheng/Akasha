"""Incremental Lance JSON training over the source-ported bitmap target.

Port: lance-index scalar/json.rs extract_json_with_type_info,
convert_stream_by_type, train_index/update and learned-type rebuild rules
(The Lance Authors, Apache-2.0). In-memory training retains a bounded inference prefix and converted rows.
Collection training uses bounded external sorting and streams null-prefix IDs
until the learned type is known. File publication remains a separate layer.
"""
from std.sys import size_of
from akasha.index.bitmap_sort import ExternalBitmapSort
from akasha.document.jsonb import JsonbValue
from akasha.index.lance_json_input import JsonIndexValue, extract_json_index_batch, infer_json_index_type, convert_json_index_batch
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow, LanceBitmapQuery, LanceBitmapBound, LanceOldRows
from akasha.index.nullable_rows import NullableRowSet, NullableRowMask
from akasha.index.lance_json_matcher import json_bitmap_reference_supported, json_bitmap_query_supported
from akasha.query.control import QueryControl


@fieldwise_init
struct _ExtractedBatch(Copyable, Movable):
    var values: List[JsonIndexValue]
    var ids: List[UInt64]


@fieldwise_init
struct SortedJsonRows(Movable):
    """Converted sorted input shared by the bitmap and paged B-tree builders."""
    var path: String
    var target: UInt8
    var string_getter_safe: Bool
    var stream: ExternalBitmapSort


@fieldwise_init
struct LanceJsonBitmapIndex(Copyable, Movable):
    var path: String
    var _bitmap: LanceBitmapIndex
    # Converted extension strings cannot reveal their original JSONB type.
    var _string_getter_safe: Bool

    def target(self) -> UInt8:
        return self._bitmap.target

    def trainer(self, *, control: Optional[QueryControl] = None) raises -> LanceJsonBitmapTrainer:
        """Derived rebuild/update parameters retain the learned target type."""
        return LanceJsonBitmapTrainer(self.path.copy(), learned_type=Optional(self.target()),
            max_rows=self._bitmap.max_rows, max_bytes=self._bitmap.max_bytes, control=control.copy())

    def search(self, query: LanceBitmapQuery, *, track_nulls: Bool = True,
               control: Optional[QueryControl] = None) raises -> NullableRowSet:
        return self._bitmap.search(query, track_nulls=track_nulls, control=control.copy())

    def try_search(self, function: String, argument: Optional[String],
                   query: LanceBitmapQuery, *, negated: Bool = False,
                   control: Optional[QueryControl] = None) raises -> Optional[NullableRowMask]:
        """Execute a covered typed function leaf, or retain it as unhandled.

        None is not an empty result: the caller must keep the original predicate.
        The caller selected this index's column; this is not SQL AST binding.
        """
        if control:
            control.value().checkpoint(0)
        if not json_bitmap_reference_supported(self.path, self.target(), function, argument):
            return None
        if function == "json_get_string" and not self._string_getter_safe:
            return None
        if not json_bitmap_query_supported(self.target(), query):
            return None
        var rows = self._bitmap.search(query, track_nulls=True, control=control.copy())
        return Optional(NullableRowMask(rows^, negated))

    def try_compare(self, function: String, argument: Optional[String],
                    operator: String, literal: LanceScalarKey, *,
                    control: Optional[QueryControl] = None) raises -> Optional[NullableRowMask]:
        """Bind a canonical typed comparison; None retains the original leaf.

        Ports SargableQueryParser::visit_comparison. The function is the left
        operand, and the caller must have bound the column and literal type.
        No implicit casts, operand reversal or SQL expression parsing occurs.
        """
        if control:
            control.value().checkpoint(0)
        if literal.is_null or literal.target != self.target():
            return None
        var query: LanceBitmapQuery
        if operator == "eq" or operator == "ne":
            query = LanceBitmapQuery.equals(literal.copy())
        elif operator == "lt" or operator == "le":
            query = LanceBitmapQuery.range_of(LanceBitmapBound(),
                LanceBitmapBound(Optional(literal.copy()), operator == "le"))
        elif operator == "gt" or operator == "ge":
            query = LanceBitmapQuery.range_of(
                LanceBitmapBound(Optional(literal.copy()), operator == "ge"), LanceBitmapBound())
        else:
            return None
        return self.try_search(function, argument, query, negated=operator == "ne",
                               control=control.copy())

    def remapped(self, mapping: Dict[UInt64, Optional[UInt64]], *,
                 control: Optional[QueryControl] = None) raises -> Self:
        return Self(self.path.copy(), self._bitmap.remapped(mapping, control=control.copy()),
                    self._string_getter_safe)


struct LanceJsonBitmapTrainer(Movable):
    """Single-consumer trainer; a failed/finished instance cannot be reused.

    push accepts one input batch. finish builds an index; finish_update merges
    with an old index of the same path/type. Errors discard all staged state.
    No partial index is published. The standalone in-memory mode keeps its
    existing aggregate byte bounds. sort_memory_bytes selects external runs;
    max_bytes then bounds batches, individual rows and the final bitmap, not
    aggregate sort input. Neither mode promises a peak RSS cap.
    """
    var path: String
    var max_rows: Int
    var max_bytes: Int
    var _type: Optional[UInt8]
    var _control: Optional[QueryControl]
    var _state: UInt8
    var _seen: Int
    var _pending_bytes: Int
    var _row_bytes: Int
    var _pending: List[_ExtractedBatch]
    var _rows: List[LanceBitmapRow]
    var _string_getter_safe: Bool
    var _sorter: Optional[ExternalBitmapSort]

    def __init__(out self, var path: String, *, learned_type: Optional[UInt8] = None,
                 max_rows: Int = 1_000_000, max_bytes: Int = 64 * 1024 * 1024,
                 var control: Optional[QueryControl] = None,
                 sort_memory_bytes: Optional[Int] = None,
                 spill_directory: String = "/tmp", spill_bytes: Int = 512 * 1024 * 1024) raises:
        if max_rows <= 0 or max_bytes <= 0:
            raise Error("JSON bitmap trainer limits must be positive")
        if path.byte_length() > 65_536:
            raise Error("JSON index path exceeds byte limit")
        if learned_type:
            _ = LanceScalarKey.null(learned_type.value())
        self.path = path^
        self.max_rows = max_rows
        self.max_bytes = max_bytes
        self._type = learned_type
        self._sorter = Optional[ExternalBitmapSort]()
        if sort_memory_bytes:
            self._sorter = Optional(ExternalBitmapSort(memory_bytes=sort_memory_bytes.value(),
                disk_bytes=spill_bytes, max_row_bytes=max_bytes, max_rows=max_rows,
                directory=spill_directory.copy(), control=control.copy()))
        self._control = control^
        self._state = 0
        self._seen = 0
        self._pending_bytes = 0
        self._row_bytes = 0
        self._pending = List[_ExtractedBatch]()
        self._rows = List[LanceBitmapRow]()
        self._string_getter_safe = True

    def learned_type(self) -> Optional[UInt8]:
        return self._type

    def _check_open(self) raises:
        if self._state != 0:
            raise Error("JSON bitmap trainer is closed")
        if self._control:
            self._control.value().checkpoint(0)

    def _check_bytes(self, used: Int, addition: Int) raises -> Int:
        if used < 0 or addition < 0 or used > self.max_bytes or addition > self.max_bytes-used:
            raise Error("JSON bitmap trainer byte limit exceeded")
        return used + addition

    def abort(mut self):
        """Discard staged state, also used by a caller whose input stream fails."""
        self._state = 1
        if self._sorter:
            self._sorter.value().abort()
        self._pending.clear()
        self._rows.clear()
        self._pending_bytes = 0
        self._row_bytes = 0

    def push(mut self, values: List[Optional[JsonbValue]], ids: List[UInt64]) raises:
        try:
            self._check_open()
            if len(values) != len(ids):
                raise Error("JSON bitmap batch values and row IDs have different lengths")
            if len(values) > self.max_rows-self._seen:
                raise Error("JSON bitmap trainer row limit exceeded")
            self._seen += len(values)
            if self._control:
                self._control.value().validate_candidate_count(self._seen)
            var batch = extract_json_index_batch(values, self.path,
                max_bytes=self.max_bytes, control=self._control.copy())
            if self._type:
                self._append(batch, ids)
                return
            # Source inference reads tags only and stops at the first non-null
            # tag. Whole-batch validation remains in the conversion stage.
            var inferred = infer_json_index_type(batch, self.path, control=self._control.copy())
            if self._sorter:
                if inferred:
                    self._type = inferred
                    self._append(batch, ids)
                else:
                    # Type inference found only nulls. Preserve IDs without
                    # retaining extracted JSON or guessing the learned type.
                    for id in ids:
                        self._sorter.value().push(LanceBitmapRow(LanceScalarKey.null(4), id))
                return
            var bytes = size_of[_ExtractedBatch]() + len(batch) * (size_of[JsonIndexValue]() + size_of[UInt64]())
            var total = self._check_bytes(self._pending_bytes, bytes)
            for item in batch:
                if item.value:
                    total = self._check_bytes(total, len(item.value.value()._data))
            self._pending_bytes = total
            self._pending.append(_ExtractedBatch(batch^, ids.copy()))
            if inferred:
                self._type = inferred
                self._flush_prefix()
        except error:
            self.abort()
            raise error

    def _append(mut self, batch: List[JsonIndexValue], ids: List[UInt64]) raises:
        # Source validates the complete batch before deserializing any row.
        var converted = convert_json_index_batch(batch, self._type.value(), self.path,
            max_bytes=self.max_bytes, control=self._control.copy())
        var bytes = self._row_bytes
        if not self._sorter:
            bytes = self._check_bytes(bytes, len(converted) * size_of[LanceBitmapRow]())
            for value in converted:
                bytes = self._check_bytes(bytes, value.owned_bytes())
        for i in range(len(converted)):
            if self._control:
                self._control.value().checkpoint(i)
            # Serde accepts extensions that json_get_string rejects. Retain
            # provenance while the original value is still available.
            if self._type.value() == 4:
                if converted[i].text:
                    if batch[i].value.value().kind() != 1:
                        self._string_getter_safe = False
            var row = LanceBitmapRow(LanceScalarKey.from_json_result(converted[i], self._type.value()), ids[i])
            if self._sorter:
                self._sorter.value().push(row^)
            else:
                self._rows.append(row^)
        self._row_bytes = bytes

    def _flush_prefix(mut self) raises:
        var prefix = self._pending^
        self._pending = List[_ExtractedBatch]()
        self._pending_bytes = 0
        for batch in prefix:
            self._append(batch.values, batch.ids)

    def _prepare_finish(mut self) raises:
        self._check_open()
        if not self._type:
            # Only end-of-stream supplies Utf8; a null/empty prefix is not EOF.
            self._type = Optional(UInt8(4))
            self._flush_prefix()

    def _finished(mut self):
        self._rows.clear()
        self._row_bytes = 0
        self._state = 2
        if self._sorter:
            self._sorter.value().abort()

    def finish_sorted(mut self) raises -> SortedJsonRows:
        """Transfer prepared external rows; finishing closes this trainer."""
        try:
            self._prepare_finish()
            if not self._sorter:
                raise Error("sorted JSON training requires external sorting")
            self._sorter.value().prepare(self._type.value())
            var sorter = self._sorter.take()
            self._finished()
            return SortedJsonRows(self.path.copy(), self._type.value(), self._string_getter_safe, sorter^)
        except error:
            self.abort()
            raise error

    def finish(mut self) raises -> LanceJsonBitmapIndex:
        try:
            self._prepare_finish()
            var bitmap: LanceBitmapIndex
            if self._sorter:
                var sorted = self.finish_sorted()
                var empty = LanceBitmapIndex(sorted.target, max_rows=self.max_rows, max_bytes=self.max_bytes)
                bitmap = empty.merge_stream(sorted.stream, control=self._control.copy())
            else:
                bitmap = LanceBitmapIndex.build(self._type.value(), self._rows,
                    max_rows=self.max_rows, max_bytes=self.max_bytes, control=self._control.copy())
            self._finished()
            return LanceJsonBitmapIndex(self.path.copy(), bitmap^, self._string_getter_safe)
        except error:
            self.abort()
            raise error

    def finish_update(mut self, old: LanceJsonBitmapIndex, *,
                      old_filter: Optional[LanceOldRows] = None) raises -> LanceJsonBitmapIndex:
        try:
            self._check_open()
            if self.path != old.path or not self._type or self._type.value() != old.target():
                raise Error("JSON bitmap update must retain the old path and learned type")
            self._prepare_finish()
            var bitmap: LanceBitmapIndex
            if self._sorter:
                self._sorter.value().prepare(self._type.value())
                bitmap = old._bitmap.merge_stream(self._sorter.value(), old_filter=old_filter.copy(), control=self._control.copy())
            else:
                bitmap = old._bitmap.updated(self._rows, old_filter=old_filter.copy(), control=self._control.copy())
            self._finished()
            # Old-row filtering and remap cannot recover discarded source
            # types. Only a complete rebuild can establish string-only input.
            return LanceJsonBitmapIndex(self.path.copy(), bitmap^,
                self._string_getter_safe and old._string_getter_safe)
        except error:
            self.abort()
            raise error
