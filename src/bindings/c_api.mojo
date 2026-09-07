from akasha.api.collection import PersistentCollection
from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.index.flat import SearchResult
from std.memory import OwnedPointer
from std.math import isfinite
from std.runtime import initialize_runtime


comptime _ABI_VERSION = UInt64(1)
comptime _STATUS_OK = UInt32(0)
comptime _STATUS_INVALID_ARGUMENT = UInt32(1)
comptime _STATUS_BUFFER_TOO_SMALL = UInt32(2)
comptime _STATUS_ENGINE_ERROR = UInt32(3)

comptime _ERROR_SIZE = UInt64(288)
comptime _ERROR_CAPACITY = UInt64(256)
comptime _CONFIG_SIZE = UInt64(112)
comptime _SEARCH_OPTIONS_SIZE = UInt64(32)
comptime _SEARCH_RESULT_SIZE = 32
comptime _SEARCH_STATS_SIZE = UInt64(112)

comptime _ERROR_SIZE_OFFSET = 0
comptime _ERROR_VERSION_OFFSET = 8
comptime _ERROR_CAPACITY_OFFSET = 16
comptime _ERROR_LENGTH_OFFSET = 24
comptime _ERROR_MESSAGE_OFFSET = 32


def _is_null(pointer: OpaquePointer[MutUntrackedOrigin]) -> Bool:
    return Int(pointer) == 0


def _pointer_at[
    T: AnyType
](pointer: OpaquePointer[MutUntrackedOrigin], offset: Int) -> Pointer[
    T, MutUntrackedOrigin
]:
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(pointer) + offset
    )


def _load_u64(
    pointer: OpaquePointer[MutUntrackedOrigin], offset: Int
) -> UInt64:
    return _pointer_at[UInt64](pointer, offset)[]


def _store_u64(
    pointer: OpaquePointer[MutUntrackedOrigin], offset: Int, value: UInt64
):
    _pointer_at[UInt64](pointer, offset)[] = value


def _store_i64(
    pointer: OpaquePointer[MutUntrackedOrigin], offset: Int, value: Int64
):
    _pointer_at[Int64](pointer, offset)[] = value


def _store_f32(
    pointer: OpaquePointer[MutUntrackedOrigin], offset: Int, value: Float32
):
    _pointer_at[Float32](pointer, offset)[] = value


def _prepare_error(error: OpaquePointer[MutUntrackedOrigin]) -> Bool:
    if _is_null(error):
        return False
    if (
        _load_u64(error, _ERROR_SIZE_OFFSET) != _ERROR_SIZE
        or _load_u64(error, _ERROR_VERSION_OFFSET) != _ABI_VERSION
        or _load_u64(error, _ERROR_CAPACITY_OFFSET) != _ERROR_CAPACITY
    ):
        return False
    _store_u64(error, _ERROR_LENGTH_OFFSET, UInt64(0))
    _pointer_at[UInt8](error, _ERROR_MESSAGE_OFFSET)[] = UInt8(0)
    return True


def _write_error(error: OpaquePointer[MutUntrackedOrigin], var message: String):
    var source = message.as_c_string_slice()
    var source_pointer = source.unsafe_ptr()
    var length = message.byte_length()
    if length >= Int(_ERROR_CAPACITY):
        length = Int(_ERROR_CAPACITY) - 1
    var destination = _pointer_at[UInt8](error, _ERROR_MESSAGE_OFFSET)
    for index in range(length):
        destination[unsafe_offset=index] = UInt8(
            source_pointer[unsafe_offset=index]
        )
    destination[unsafe_offset=length] = UInt8(0)
    _store_u64(error, _ERROR_LENGTH_OFFSET, UInt64(length))


def _invalid(
    error: OpaquePointer[MutUntrackedOrigin], message: String
) -> UInt32:
    _write_error(error, message)
    return _STATUS_INVALID_ARGUMENT


def _engine_error(
    error: OpaquePointer[MutUntrackedOrigin], message: String
) -> UInt32:
    _write_error(error, message)
    return _STATUS_ENGINE_ERROR


def _string_from_bytes(
    pointer: OpaquePointer[MutUntrackedOrigin], length: UInt64
) raises -> String:
    if length > UInt64(Int.MAX):
        raise Error("string length exceeds host address space")
    var bytes = List[UInt8](capacity=Int(length))
    var source = pointer.unsafe_bitcast[UInt8]()
    for index in range(Int(length)):
        var byte = source[unsafe_offset=index]
        if byte == UInt8(0):
            raise Error("string buffer contains an embedded NUL")
        bytes.append(byte)
    return String(from_utf8=bytes)


def _read_config(
    pointer: OpaquePointer[MutUntrackedOrigin],
) raises -> CollectionConfig:
    if _load_u64(pointer, 0) != _CONFIG_SIZE:
        raise Error("collection config struct_size is invalid")
    if _load_u64(pointer, 8) != _ABI_VERSION:
        raise Error("collection config api_version is unsupported")
    var dimension = _load_u64(pointer, 16)
    var metric = _load_u64(pointer, 24)
    var scalar = _load_u64(pointer, 32)
    if dimension > UInt64(Int.MAX):
        raise Error("collection dimension exceeds host address space")
    if metric > UInt64(2):
        raise Error("collection metric tag is invalid")
    if scalar > UInt64(3):
        raise Error("collection scalar tag is invalid")
    var integer_fields = List[Int]()
    for offset in range(40, 104, 8):
        var value = _load_u64(pointer, offset)
        if value > UInt64(Int.MAX):
            raise Error("collection config value exceeds host address space")
        integer_fields.append(Int(value))
    var config = CollectionConfig(
        dimension=Int(dimension),
        ann_metric=MetricKind.from_tag(UInt8(metric)),
        scalar_kind=ScalarKind.from_tag(UInt8(scalar)),
        m=integer_fields[0],
        m0=integer_fields[1],
        ef_construction=integer_fields[2],
        default_ef_search=integer_fields[3],
        max_ef_search=integer_fields[4],
        max_level=integer_fields[5],
        rebuild_inactive_percent=integer_fields[6],
        delta_max_points=integer_fields[7],
        level_seed=_load_u64(pointer, 104),
    )
    config.validate()
    return config^


def _collection(
    handle: OpaquePointer[MutUntrackedOrigin],
) -> Pointer[PersistentCollection, MutUntrackedOrigin]:
    return handle.unsafe_bitcast[PersistentCollection]()


def _read_vector(
    pointer: OpaquePointer[MutUntrackedOrigin], dimension: UInt64
) raises -> List[Float32]:
    if dimension > UInt64(Int.MAX):
        raise Error("vector dimension exceeds host address space")
    var values = List[Float32](capacity=Int(dimension))
    var source = pointer.unsafe_bitcast[Float32]()
    for index in range(Int(dimension)):
        var value = source[unsafe_offset=index]
        if not isfinite(value):
            raise Error("vector values must be finite")
        values.append(value)
    return values^


@export("akasha_collection_open")
def akasha_collection_open(
    path: OpaquePointer[MutUntrackedOrigin],
    path_length: UInt64,
    config_pointer: OpaquePointer[MutUntrackedOrigin],
    out_collection: OpaquePointer[MutUntrackedOrigin],
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(path) or path_length == 0:
        return _invalid(error, "path must be a non-empty buffer")
    if _is_null(config_pointer):
        return _invalid(error, "collection config must not be null")
    if _is_null(out_collection):
        return _invalid(error, "out_collection must not be null")
    var output = out_collection.unsafe_bitcast[
        Optional[OpaquePointer[MutUntrackedOrigin]]
    ]()
    output[] = None
    var owned_path: String
    var config: CollectionConfig
    try:
        owned_path = _string_from_bytes(path, path_length)
        config = _read_config(config_pointer)
    except caught:
        return _invalid(error, String(caught))
    try:
        var collection = PersistentCollection.open_with_config(
            owned_path, config
        )
        var holder = OwnedPointer(collection^)
        var allocation = holder^.unsafe_take_allocation()
        var raw = allocation^.unsafe_leak()
        output[] = Optional(raw.unsafe_bitcast[NoneType]())
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))


@export("akasha_collection_close")
def akasha_collection_close(
    collection_pointer: OpaquePointer[MutUntrackedOrigin],
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(collection_pointer):
        return _invalid(error, "collection pointer must not be null")
    var slot = collection_pointer.unsafe_bitcast[
        Optional[OpaquePointer[MutUntrackedOrigin]]
    ]()
    var maybe_handle = slot[]
    if not maybe_handle:
        return _STATUS_OK
    var handle = maybe_handle.value()
    # Invalidate caller storage before running fallible shutdown. The owned
    # allocation below always releases the object, including on error.
    slot[] = None
    var holder = OwnedPointer[PersistentCollection](
        unsafe_from_opaque_pointer=handle
    )
    try:
        holder[].close()
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))


@export("akasha_collection_upsert")
def akasha_collection_upsert(
    handle: OpaquePointer[MutUntrackedOrigin],
    id: Int64,
    vector: OpaquePointer[MutUntrackedOrigin],
    dimension: UInt64,
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(handle):
        return _invalid(error, "collection handle must not be null")
    if _is_null(vector):
        return _invalid(error, "vector must not be null")
    if dimension != UInt64(_collection(handle)[].dimension):
        return _invalid(error, "vector dimension does not match collection")
    var values: List[Float32]
    try:
        values = _read_vector(vector, dimension)
    except caught:
        return _invalid(error, String(caught))
    try:
        _collection(handle)[].upsert(Int(id), values^)
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))


@export("akasha_collection_delete")
def akasha_collection_delete(
    handle: OpaquePointer[MutUntrackedOrigin],
    id: Int64,
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(handle):
        return _invalid(error, "collection handle must not be null")
    try:
        _collection(handle)[].delete(Int(id))
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))


@export("akasha_collection_flush")
def akasha_collection_flush(
    handle: OpaquePointer[MutUntrackedOrigin],
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(handle):
        return _invalid(error, "collection handle must not be null")
    try:
        _collection(handle)[].flush()
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))


@export("akasha_collection_search")
def akasha_collection_search(
    handle: OpaquePointer[MutUntrackedOrigin],
    query_pointer: OpaquePointer[MutUntrackedOrigin],
    dimension: UInt64,
    options: OpaquePointer[MutUntrackedOrigin],
    result_pointer: OpaquePointer[MutUntrackedOrigin],
    result_capacity: UInt64,
    out_count: OpaquePointer[MutUntrackedOrigin],
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(handle):
        return _invalid(error, "collection handle must not be null")
    if _is_null(query_pointer):
        return _invalid(error, "query must not be null")
    if _is_null(options):
        return _invalid(error, "search options must not be null")
    if _is_null(out_count):
        return _invalid(error, "out_count must not be null")
    if result_capacity > 0 and _is_null(result_pointer):
        return _invalid(
            error, "results must not be null when capacity is nonzero"
        )
    _store_u64(out_count, 0, UInt64(0))
    if dimension != UInt64(_collection(handle)[].dimension):
        return _invalid(error, "query dimension does not match collection")
    if _load_u64(options, 0) != _SEARCH_OPTIONS_SIZE:
        return _invalid(error, "search options struct_size is invalid")
    if _load_u64(options, 8) != _ABI_VERSION:
        return _invalid(error, "search options api_version is unsupported")
    var k_value = _load_u64(options, 16)
    var ef_value = _load_u64(options, 24)
    if (
        k_value == 0
        or ef_value == 0
        or k_value > UInt64(Int.MAX)
        or ef_value > UInt64(Int.MAX)
        or result_capacity > UInt64(Int.MAX)
    ):
        return _invalid(error, "search sizes must be positive and fit the host")
    var config = _collection(handle)[].collection_config()
    if ef_value > UInt64(config.max_ef_search):
        return _invalid(error, "ef_search exceeds the collection maximum")
    var query: List[Float32]
    try:
        query = _read_vector(query_pointer, dimension)
    except caught:
        return _invalid(error, String(caught))
    try:
        var results: List[SearchResult]
        if config.ann_metric == MetricKind.dot():
            results = _collection(handle)[].search_dot_approx(
                query, Int(k_value), Int(ef_value)
            )
        elif config.ann_metric == MetricKind.l2():
            results = _collection(handle)[].search_l2_approx(
                query, Int(k_value), Int(ef_value)
            )
        else:
            results = _collection(handle)[].search_cosine_approx(
                query, Int(k_value), Int(ef_value)
            )
        _store_u64(out_count, 0, UInt64(len(results)))
        if result_capacity < UInt64(len(results)):
            _write_error(error, "result buffer capacity is too small")
            return _STATUS_BUFFER_TOO_SMALL
        for index in range(len(results)):
            var offset = index * _SEARCH_RESULT_SIZE
            if _load_u64(result_pointer, offset) != UInt64(_SEARCH_RESULT_SIZE):
                return _invalid(error, "result struct_size is invalid")
            if _load_u64(result_pointer, offset + 8) != _ABI_VERSION:
                return _invalid(error, "result api_version is unsupported")
        for index in range(len(results)):
            var offset = index * _SEARCH_RESULT_SIZE
            _store_i64(result_pointer, offset + 16, Int64(results[index].id))
            _store_f32(result_pointer, offset + 24, results[index].score)
            _pointer_at[UInt32](result_pointer, offset + 28)[] = UInt32(0)
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))


@export("akasha_collection_last_search_stats")
def akasha_collection_last_search_stats(
    handle: OpaquePointer[MutUntrackedOrigin],
    stats_pointer: OpaquePointer[MutUntrackedOrigin],
    error: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> UInt32:
    initialize_runtime()
    if not _prepare_error(error):
        return _STATUS_INVALID_ARGUMENT
    if _is_null(handle):
        return _invalid(error, "collection handle must not be null")
    if _is_null(stats_pointer):
        return _invalid(error, "stats must not be null")
    if _load_u64(stats_pointer, 0) != _SEARCH_STATS_SIZE:
        return _invalid(error, "stats struct_size is invalid")
    if _load_u64(stats_pointer, 8) != _ABI_VERSION:
        return _invalid(error, "stats api_version is unsupported")
    try:
        var stats = _collection(handle)[].last_search_stats()
        _store_u64(stats_pointer, 16, UInt64(stats.requested_ef))
        _store_u64(stats_pointer, 24, UInt64(stats.effective_ef))
        _store_u64(stats_pointer, 32, UInt64(stats.widening_rounds))
        _store_u64(stats_pointer, 40, UInt64(stats.upper_visited))
        _store_u64(stats_pointer, 48, UInt64(stats.base_visited))
        _store_u64(stats_pointer, 56, UInt64(stats.distance_evaluations))
        _store_u64(stats_pointer, 64, UInt64(stats.retained_candidates))
        _store_u64(stats_pointer, 72, UInt64(stats.reranked_candidates))
        _store_u64(stats_pointer, 80, UInt64(stats.filtered_rejections))
        _store_u64(stats_pointer, 88, UInt64(stats.inactive_rejections))
        _store_u64(stats_pointer, 96, UInt64(stats.base_candidates))
        _store_u64(stats_pointer, 104, UInt64(stats.delta_candidates))
        return _STATUS_OK
    except caught:
        return _engine_error(error, String(caught))
