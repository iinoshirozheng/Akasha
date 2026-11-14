"""Bounded sorted runs and two-way external merge for scalar bitmap rows.

Akasha-owned staging format, not a durable index format. Sorted stream output
feeds Lance's existing value-run builder. Anonymous POSIX files are RAII owned.
"""
from std.io.file import FileHandle
from std.sys import size_of
from akasha.storage.filesystem import create_anonymous_file
from akasha.storage.checksum import BinaryWriter, BorrowedBinaryReader, crc32
from akasha.index.lance_bitmap import BitmapRowStream, LanceBitmapRow, _OrderedRow
from akasha.index.lance_scalar import LanceScalarKey
from akasha.query.control import QueryControl


@fieldwise_init
struct _SortRun(Copyable, Movable):
    var offset: Int
    var end: Int
    var remaining: Int




def _write_row(mut file: FileHandle, row: LanceBitmapRow, mut length: Int, limit: Int) raises:
    var writer = BinaryWriter()
    writer.write_u8(row.key.target)
    writer.write_u8(UInt8(row.key.is_null))
    writer.write_u64(row.id)
    if not row.key.is_null:
        if row.key.target <= 2:
            writer.write_i64(row.key._integer)
        elif row.key.target == 3:
            writer.write_u64(row.key._bits)
        else:
            writer.write_u32(UInt32(len(row.key._bytes)))
            writer.write_bytes(row.key._bytes)
    var bytes = writer.take_bytes()
    if len(bytes) + 8 > limit - length:
        raise Error("bitmap spill disk byte limit exceeded")
    writer.write_u32(UInt32(len(bytes)))
    writer.write_u32(crc32(bytes))
    file.write_all(writer.take_bytes())
    file.write_all(bytes)
    length += len(bytes) + 8


def _read_row(mut file: FileHandle, mut run: _SortRun, max_bytes: Int) raises -> Optional[LanceBitmapRow]:
    if run.remaining == 0:
        if run.offset != run.end:
            raise Error("bitmap spill run length mismatch")
        return None
    if run.end - run.offset < 8:
        raise Error("truncated bitmap spill header")
    _ = file.seek(run.offset)
    var header = file.read_bytes(8)
    var reader = BorrowedBinaryReader(Span(header))
    var length = Int(reader.read_u32())
    var checksum = reader.read_u32()
    if length > max_bytes + 18 or length > run.end - run.offset - 8:
        raise Error("invalid bitmap spill record length")
    var bytes = file.read_bytes(length)
    if len(bytes) != length or crc32(bytes) != checksum:
        raise Error("bitmap spill checksum/truncation failure")
    var row = BorrowedBinaryReader(Span(bytes))
    var target = row.read_u8()
    var key = LanceScalarKey.null(target)
    var null = row.read_u8()
    if null > 1:
        raise Error("invalid bitmap spill null tag")
    var id = row.read_u64()
    if null == 0:
        if target <= 2:
            var value = row.read_i64()
            if target == 1 and value != 0 and value != 1:
                raise Error("invalid bitmap spill Boolean")
            key = LanceScalarKey.boolean(value == 1) if target == 1 else LanceScalarKey.integer(value)
        elif target == 3:
            key = LanceScalarKey.float_bits(row.read_u64())
        else:
            var count = Int(row.read_u32())
            var data = row.read_bytes(count)
            if target == 4:
                _ = String(from_utf8=Span(data))
            key = LanceScalarKey.binary(data^)
            key.target = target
    if row.remaining() != 0:
        raise Error("bitmap spill trailing record bytes")
    run.offset += length + 8
    run.remaining -= 1
    return Optional(LanceBitmapRow(key^, id))


struct ExternalBitmapSort(BitmapRowStream):
    """Single-consumer sorter. Limits exclude caller batches and output bitmap.

    One oversized row may exceed memory_bytes but never max_row_bytes. Merge
    keeps two row heads, two anonymous files, and O(max_rows) run descriptors.
    disk_bytes bounds the combined input/output files during every merge pass.
    """
    var memory_bytes: Int
    var disk_bytes: Int
    var max_row_bytes: Int
    var max_rows: Int
    var directory: String
    var _control: Optional[QueryControl]
    var _rows: List[_OrderedRow]
    var _runs: List[_SortRun]
    var _file: Optional[FileHandle]
    var _length: Int
    var _buffer_bytes: Int
    var _seen: Int
    var _position: Int
    var _prepared: Bool
    var _closed: Bool
    var target: UInt8
    var spill_runs: Int
    var merge_passes: Int
    var peak_buffer_bytes: Int

    def __init__(out self, *, memory_bytes: Int = 8 * 1024 * 1024,
                 disk_bytes: Int = 512 * 1024 * 1024, max_row_bytes: Int = 64 * 1024 * 1024,
                 max_rows: Int = 1_000_000, var directory: String = "/tmp",
                 var control: Optional[QueryControl] = None) raises:
        if memory_bytes <= 0 or disk_bytes <= 0 or max_row_bytes <= 0 or max_rows <= 0:
            raise Error("bitmap sort limits must be positive")
        if max_row_bytes > Int.MAX - 32:
            raise Error("bitmap sort row byte limit is too large")
        self.memory_bytes = memory_bytes
        self.disk_bytes = disk_bytes
        self.max_row_bytes = max_row_bytes
        self.max_rows = max_rows
        self.directory = directory^
        self._control = control^
        self._rows = List[_OrderedRow]()
        self._runs = List[_SortRun]()
        self._file = Optional[FileHandle]()
        self._length = 0
        self._buffer_bytes = 0
        self._seen = 0
        self._position = 0
        self._prepared = False
        self._closed = False
        self.target = 4
        self.spill_runs = 0
        self.merge_passes = 0
        self.peak_buffer_bytes = 0

    def abort(mut self):
        self._rows.clear()
        self._runs.clear()
        self._file = None
        self._buffer_bytes = 0
        self._closed = True

    def _checkpoint(self) raises:
        if self._closed:
            raise Error("bitmap sort is closed")
        if self._control:
            self._control.value().checkpoint(0)

    def push(mut self, var row: LanceBitmapRow) raises:
        try:
            self._checkpoint()
            if self._prepared:
                raise Error("bitmap sort already prepared")
            var cost = size_of[_OrderedRow]() + len(row.key._bytes)
            if cost > self.max_row_bytes or self._seen >= self.max_rows:
                raise Error("bitmap sort input limit exceeded")
            self._seen += 1
            if self._control:
                self._control.value().validate_candidate_count(self._seen)
            if len(self._rows) and cost > self.memory_bytes - self._buffer_bytes:
                self._flush()
            self._rows.append(_OrderedRow(row^))
            self._buffer_bytes += cost
            if self._buffer_bytes > self.peak_buffer_bytes:
                self.peak_buffer_bytes = self._buffer_bytes
        except error:
            self.abort()
            raise error

    def _sort(mut self) raises:
        self._checkpoint()
        sort[stable=True](Span(self._rows))
        self._checkpoint()

    def _flush(mut self) raises:
        if not len(self._rows):
            return
        self._sort()
        if not self._file:
            self._file = Optional(create_anonymous_file(self.directory))
        var start = self._length
        _ = self._file.value().seek(self._length)
        for item in self._rows:
            self._checkpoint()
            _write_row(self._file.value(), item.row, self._length, self.disk_bytes)
        self._runs.append(_SortRun(start, self._length, len(self._rows)))
        self.spill_runs += 1
        self._rows.clear()
        self._buffer_bytes = 0

    def prepare(mut self, target: UInt8) raises:
        try:
            self._checkpoint()
            if self._prepared:
                raise Error("bitmap sort already prepared")
            _ = LanceScalarKey.null(target)
            self.target = target
            if not len(self._runs):
                self._sort()
            else:
                self._flush()
                while len(self._runs) > 1:
                    self._merge_pass()
            self._prepared = True
        except error:
            self.abort()
            raise error

    def _merge_pass(mut self) raises:
        var output = create_anonymous_file(self.directory)
        var length = 0
        var runs = List[_SortRun]()
        for pair in range(0, len(self._runs), 2):
            self._checkpoint()
            var left = self._runs[pair].copy()
            var right = self._runs[pair+1].copy() if pair+1 < len(self._runs) else _SortRun(0, 0, 0)
            var count = left.remaining + right.remaining
            var a = _read_row(self._file.value(), left, self.max_row_bytes)
            var b = _read_row(self._file.value(), right, self.max_row_bytes)
            var start = length
            while Bool(a) or Bool(b):
                self._checkpoint()
                # Left-first ties preserve the stable order of adjacent runs.
                if not b or (Bool(a) and a.value().key._compare_same(b.value().key) <= 0):
                    _write_row(output, a.value(), length, self.disk_bytes - self._length)
                    a = _read_row(self._file.value(), left, self.max_row_bytes)
                else:
                    _write_row(output, b.value(), length, self.disk_bytes - self._length)
                    b = _read_row(self._file.value(), right, self.max_row_bytes)
            runs.append(_SortRun(start, length, count))
        self._file = Optional(output^)
        self._runs = runs^
        self._length = length
        self.merge_passes += 1

    def next(mut self) raises -> Optional[LanceBitmapRow]:
        try:
            self._checkpoint()
            if not self._prepared:
                raise Error("bitmap sort is not prepared")
            var row: Optional[LanceBitmapRow]
            if self._file:
                row = _read_row(self._file.value(), self._runs[0], self.max_row_bytes)
            elif self._position < len(self._rows):
                row = Optional(self._rows[self._position].row.copy())
                self._position += 1
            else:
                row = None
            if row:
                if row.value().key.is_null:
                    row.value().key.target = self.target
                row.value().key.validate(self.target)
            return row^
        except error:
            self.abort()
            raise error
