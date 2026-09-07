from akasha.compute.simd import prevalidated_simd_dot_product
from akasha.storage.memtable import MemTable
from max.gpu.host import DeviceBuffer, DeviceContext
from std.time import perf_counter_ns
from std.math import isfinite
from std.utils import BlockingScopedLock, BlockingSpinLock


struct GpuExecutionTimings(Copyable, Movable):
    """Host wall times; kernel times are populated only in profiling mode."""

    var preparation_ns: Int
    var allocation_ns: Int
    var upload_ns: Int
    var distance_ns: Int
    var topk_ns: Int
    var download_ns: Int
    var total_ns: Int
    var cache_hit: Bool
    var buffer_allocations: Int
    var request_upload_bytes: UInt64
    var vector_upload_bytes: UInt64
    var resident_bytes: UInt64
    var generation: UInt64
    var sequence: UInt64

    def __init__(out self):
        self.preparation_ns = 0
        self.allocation_ns = 0
        self.upload_ns = 0
        self.distance_ns = 0
        self.topk_ns = 0
        self.download_ns = 0
        self.total_ns = 0
        self.cache_hit = False
        self.buffer_allocations = 0
        self.request_upload_bytes = 0
        self.vector_upload_bytes = 0
        self.resident_bytes = 0
        self.generation = 0
        self.sequence = 0


struct GpuScratch(Movable):
    """Query buffers and bounded partial Top-K storage; no dense score matrix.
    """

    var queries: DeviceBuffer[DType.float32]
    var partial_scores: DeviceBuffer[DType.float32]
    var partial_ids: DeviceBuffer[DType.int64]
    var candidates: DeviceBuffer[DType.int64]
    var offsets: DeviceBuffer[DType.int64]
    var tile_offsets: DeviceBuffer[DType.int64]
    var output_ids: DeviceBuffer[DType.int64]
    var output_scores: DeviceBuffer[DType.float32]

    def __init__(
        out self,
        context: DeviceContext,
        query_values: Int,
        partials: Int,
        candidates: Int,
        queries: Int,
        outputs: Int,
    ) raises:
        self.queries = context.enqueue_create_buffer[DType.float32](
            query_values
        )
        self.partial_scores = context.enqueue_create_buffer[DType.float32](
            partials
        )
        self.partial_ids = context.enqueue_create_buffer[DType.int64](partials)
        self.candidates = context.enqueue_create_buffer[DType.int64](
            max(1, candidates)
        )
        self.offsets = context.enqueue_create_buffer[DType.int64](queries + 1)
        self.tile_offsets = context.enqueue_create_buffer[DType.int64](
            queries + 1
        )
        self.output_ids = context.enqueue_create_buffer[DType.int64](outputs)
        self.output_scores = context.enqueue_create_buffer[DType.float32](
            outputs
        )

    def fits(
        self,
        query_values: Int,
        partials: Int,
        candidates: Int,
        queries: Int,
        outputs: Int,
    ) -> Bool:
        return (
            len(self.queries) >= query_values
            and len(self.partial_scores) >= partials
            and len(self.candidates) >= max(1, candidates)
            and len(self.offsets) >= queries + 1
            and len(self.output_ids) >= outputs
        )

    def bytes(self) -> UInt64:
        return (
            UInt64(
                len(self.queries)
                + len(self.partial_scores)
                + len(self.output_scores)
            )
            * 4
            + UInt64(
                len(self.partial_ids)
                + len(self.candidates)
                + len(self.offsets)
                + len(self.tile_offsets)
                + len(self.output_ids)
            )
            * 8
        )


struct GpuSnapshotCache(Movable):
    """F32 device copy of one immutable snapshot; never shared across versions.
    """

    var context: DeviceContext
    var vectors: DeviceBuffer[DType.float32]
    var ids: DeviceBuffer[DType.int64]
    var positions: List[Int]
    var point_norms: List[Float32]
    var point_count: Int
    var dimension: Int
    var scratch: Optional[GpuScratch]

    def __init__(
        out self, table: MemTable, mut timings: GpuExecutionTimings
    ) raises:
        var start = perf_counter_ns()
        self.context = DeviceContext()
        self.point_count = table.live_count()
        self.dimension = table.dimension
        self.vectors = self.context.enqueue_create_buffer[DType.float32](
            self.point_count * (self.dimension + 1)
        )
        self.ids = self.context.enqueue_create_buffer[DType.int64](
            self.point_count
        )
        self.scratch = Optional[GpuScratch]()
        timings.allocation_ns += perf_counter_ns() - start
        timings.buffer_allocations += 2
        start = perf_counter_ns()
        var ordinals = table.live_ordinals(id_order=True)
        self.positions = List[Int](length=table.slot_count(), fill=-1)
        self.point_norms = List[Float32](length=self.point_count, fill=0.0)
        for position in range(len(ordinals)):
            self.positions[ordinals[position]] = position
        timings.preparation_ns += perf_counter_ns() - start
        start = perf_counter_ns()
        with self.vectors.map_to_host() as vectors:
            with self.ids.map_to_host() as ids:
                for position in range(len(ordinals)):
                    ref entry = table.entry_ref_at(ordinals[position])
                    ids[position] = Int64(entry.id)
                    for column in range(self.dimension):
                        var value = entry.values[column]
                        vectors[position * self.dimension + column] = value
                    var norm = prevalidated_simd_dot_product(
                        entry.values, entry.values
                    )
                    if not isfinite(norm):
                        raise Error(
                            "GPU vector norm exceeds finite F32 accumulation"
                        )
                    self.point_norms[position] = norm
                    vectors[self.point_count * self.dimension + position] = norm
        timings.upload_ns += perf_counter_ns() - start
        timings.vector_upload_bytes = (
            UInt64(self.point_count) * UInt64(self.dimension) * 4
        )

    def vector_bytes(self) -> UInt64:
        return UInt64(self.point_count) * UInt64((self.dimension + 1) * 4 + 8)

    def ensure_scratch(
        mut self,
        query_count: Int,
        partials: Int,
        candidates: Int,
        output_count: Int,
        budget: UInt64,
        mut timings: GpuExecutionTimings,
    ) raises:
        var values = query_count * (self.dimension + 1)
        if self.scratch:
            if (
                self.scratch.value().fits(
                    values, partials, candidates, query_count, output_count
                )
                and self.vector_bytes() + self.scratch.value().bytes() <= budget
            ):
                timings.resident_bytes = (
                    self.vector_bytes() + self.scratch.value().bytes()
                )
                return
            # Release old storage before allocating its replacement. A later
            # smaller budget must not retain an earlier large allocation.
            self.scratch = Optional[GpuScratch]()
            self.context.synchronize()
        var start = perf_counter_ns()
        self.scratch = Optional(
            GpuScratch(
                self.context,
                values,
                partials,
                candidates,
                query_count,
                output_count,
            )
        )
        timings.allocation_ns += perf_counter_ns() - start
        timings.buffer_allocations += 8
        timings.resident_bytes = (
            self.vector_bytes() + self.scratch.value().bytes()
        )
        if timings.resident_bytes > budget:
            self.scratch = Optional[GpuScratch]()
            raise Error("GPU retained allocation exceeds memory budget")


struct GpuSnapshotState(Movable):
    """Snapshot-owned cache and lock; a query holds the lock through readback.
    """

    var lock: BlockingSpinLock
    var cache: Optional[GpuSnapshotCache]
    var generation: UInt64
    var sequence: UInt64

    def __init__(out self, generation: UInt64 = 0, sequence: UInt64 = 0):
        self.lock = BlockingSpinLock()
        self.cache = Optional[GpuSnapshotCache]()
        self.generation = generation
        self.sequence = sequence

    def release(mut self):
        with BlockingScopedLock(self.lock):
            self.cache = Optional[GpuSnapshotCache]()

    def trim_to_budget(mut self, budget: UInt64):
        with BlockingScopedLock(self.lock):
            if not self.cache:
                return
            var retained = self.cache.value().vector_bytes()
            if self.cache.value().scratch:
                retained += self.cache.value().scratch.value().bytes()
            if retained > budget:
                self.cache = Optional[GpuSnapshotCache]()
