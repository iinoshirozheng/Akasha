"""Trusted validation and ownership rules for Arrow C Data consumers.

The Python adapter imports C Data capsules and passes Arrow-owned primitive
buffer views to the compiled binding. These descriptors validate the same
length/offset invariants in Mojo before values enter engine-owned storage.
"""


comptime ARROW_INT64_FORMAT = "l"
comptime ARROW_FLOAT32_FORMAT = "f"
comptime ARROW_FLOAT64_FORMAT = "g"
comptime ARROW_BOOL_FORMAT = "b"
comptime ARROW_UTF8_FORMAT = "u"
comptime ARROW_LIST_FORMAT = "+l"
comptime ARROW_FIXED_SIZE_LIST_PREFIX = "+w:"


struct ArrowArrayDescriptor(Copyable, Movable):
    """Bounds metadata for one imported, producer-owned Arrow array."""

    var length: Int
    var offset: Int
    var null_count: Int
    var buffer_length: Int

    def __init__(
        out self,
        length: Int,
        offset: Int,
        null_count: Int,
        buffer_length: Int,
    ) raises:
        if length < 0 or offset < 0 or null_count < 0:
            raise Error("Arrow array metadata cannot be negative")
        if null_count > length:
            raise Error("Arrow null count exceeds array length")
        if offset > Int.MAX - length or offset + length > buffer_length:
            raise Error("Arrow array view exceeds its imported buffer")
        self.length = length
        self.offset = offset
        self.null_count = null_count
        self.buffer_length = buffer_length

    def require_non_null(self) raises:
        if self.null_count != 0:
            raise Error("Arrow array cannot contain nulls")


struct ArrowConsumerLease(Movable):
    """One-shot C Data consumer release state.

    `release_callback_calls` models the C Data `release` callback invocation and
    is observable for ABI tests. Imported buffer views must call `ensure_active`
    before access.
    """

    var _released: Bool
    var _release_callback_calls: Int

    def __init__(out self):
        self._released = False
        self._release_callback_calls = 0

    def ensure_active(self) raises:
        if self._released:
            raise Error("Arrow C Data consumer lease is released")

    def release(mut self) raises:
        if self._released:
            raise Error("Arrow C Data release callback may run exactly once")
        self._released = True
        self._release_callback_calls += 1

    def released(self) -> Bool:
        return self._released

    def release_callback_calls(self) -> Int:
        return self._release_callback_calls


def validate_fixed_size_vectors(
    rows: ArrowArrayDescriptor,
    values: ArrowArrayDescriptor,
    dimension: Int,
) raises:
    rows.require_non_null()
    values.require_non_null()
    if dimension <= 0:
        raise Error("Arrow vector dimension must be positive")
    if rows.length > Int.MAX // dimension:
        raise Error("Arrow vector element count overflows")
    if values.length != rows.length * dimension:
        raise Error("Arrow fixed-size vector value count mismatch")


def validate_sparse_offsets(
    offsets: List[Int], term_count: Int, weight_count: Int
) raises:
    if len(offsets) < 2:
        raise Error("Arrow sparse offsets require at least one row")
    if term_count < 0 or term_count != weight_count:
        raise Error("Arrow sparse child value counts differ")
    if offsets[0] < 0 or offsets[len(offsets) - 1] > term_count:
        raise Error("Arrow sparse offsets exceed child buffers")
    for index in range(len(offsets) - 1):
        if offsets[index + 1] <= offsets[index]:
            raise Error("Arrow sparse rows must be non-empty and ordered")
