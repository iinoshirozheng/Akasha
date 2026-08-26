struct GpuExecutionOptions:
    """Host-side policy limits for optional GPU query execution."""

    var enabled: Bool
    var memory_budget_bytes: Int
    var min_work_items: Int
    var block_size: Int
    var fail_before_launch: Bool

    def __init__(
        out self,
        *,
        enabled: Bool = True,
        memory_budget_bytes: Int = 512 * 1024 * 1024,
        min_work_items: Int = 65_536,
        block_size: Int = 256,
        fail_before_launch: Bool = False,
    ) raises:
        if memory_budget_bytes <= 0:
            raise Error("GPU memory budget must be positive")
        if min_work_items < 0:
            raise Error("GPU minimum work items cannot be negative")
        if block_size <= 0 or block_size > 1_024:
            raise Error("GPU block size must be between 1 and 1024")
        self.enabled = enabled
        self.memory_budget_bytes = memory_budget_bytes
        self.min_work_items = min_work_items
        self.block_size = block_size
        self.fail_before_launch = fail_before_launch


struct GpuPlan(Movable):
    var use_gpu: Bool
    var reason: String
    var required_bytes: UInt64
    var transfer_bytes: UInt64
    var work_items: UInt64

    def __init__(
        out self,
        use_gpu: Bool,
        reason: String,
        required_bytes: UInt64,
        transfer_bytes: UInt64,
        work_items: UInt64,
    ):
        self.use_gpu = use_gpu
        self.reason = String(copy=reason)
        self.required_bytes = required_bytes
        self.transfer_bytes = transfer_bytes
        self.work_items = work_items


def plan_gpu_execution(
    accelerator_available: Bool,
    batch_size: Int,
    point_count: Int,
    dimension: Int,
    k: Int,
    options: GpuExecutionOptions,
) raises -> GpuPlan:
    if batch_size < 0 or point_count < 0 or dimension <= 0 or k <= 0:
        raise Error("invalid GPU query shape")
    var batch = UInt64(batch_size)
    var points = UInt64(point_count)
    var dims = UInt64(dimension)
    var result_count = UInt64(min(k, point_count))
    var vector_bytes = _checked_mul(_checked_mul(points, dims), 4)
    var query_bytes = _checked_mul(_checked_mul(batch, dims), 4)
    var id_bytes = _checked_mul(points, 8)
    var score_bytes = _checked_mul(_checked_mul(batch, points), 4)
    var output_bytes = _checked_mul(
        _checked_mul(batch, result_count), 12
    )
    var transfer_bytes = _checked_add(
        _checked_add(vector_bytes, query_bytes),
        _checked_add(id_bytes, output_bytes),
    )
    var required_bytes = _checked_add(transfer_bytes, score_bytes)
    var work_items = _checked_mul(_checked_mul(batch, points), dims)

    if not options.enabled:
        return GpuPlan(
            False,
            "disabled",
            required_bytes,
            transfer_bytes,
            work_items,
        )
    if not accelerator_available:
        return GpuPlan(
            False,
            "no accelerator",
            required_bytes,
            transfer_bytes,
            work_items,
        )
    if batch_size == 0 or point_count == 0:
        return GpuPlan(
            False,
            "empty workload",
            required_bytes,
            transfer_bytes,
            work_items,
        )
    if work_items < UInt64(options.min_work_items):
        return GpuPlan(
            False,
            "below work threshold",
            required_bytes,
            transfer_bytes,
            work_items,
        )
    if required_bytes > UInt64(options.memory_budget_bytes):
        return GpuPlan(
            False,
            "memory budget exceeded",
            required_bytes,
            transfer_bytes,
            work_items,
        )
    return GpuPlan(
        True,
        "gpu eligible",
        required_bytes,
        transfer_bytes,
        work_items,
    )


def _checked_mul(lhs: UInt64, rhs: UInt64) raises -> UInt64:
    if rhs != 0 and lhs > UInt64.MAX // rhs:
        raise Error("GPU query size overflows UInt64")
    return lhs * rhs


def _checked_add(lhs: UInt64, rhs: UInt64) raises -> UInt64:
    if lhs > UInt64.MAX - rhs:
        raise Error("GPU query size overflows UInt64")
    return lhs + rhs
