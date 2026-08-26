comptime _DOT_TAG = UInt8(0)
comptime _L2_TAG = UInt8(1)
comptime _COSINE_TAG = UInt8(2)

comptime _F32_TAG = UInt8(0)
comptime _BF16_TAG = UInt8(1)
comptime _F16_TAG = UInt8(2)
comptime _I8_TAG = UInt8(3)

comptime _FNV_OFFSET_BASIS = UInt64(14695981039346656037)
comptime _FNV_PRIME = UInt64(1099511628211)
comptime _UINT16_MAX_AS_INT = 65_535
comptime _UINT32_MAX_AS_INT = 4_294_967_295


struct MetricKind(Copyable, Equatable, Movable, Writable):
    """The metric used to build and traverse a collection's ANN graph."""

    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    @staticmethod
    def dot() -> MetricKind:
        return MetricKind(_DOT_TAG)

    @staticmethod
    def l2() -> MetricKind:
        return MetricKind(_L2_TAG)

    @staticmethod
    def cosine() -> MetricKind:
        return MetricKind(_COSINE_TAG)

    @staticmethod
    def from_tag(tag: UInt8) -> MetricKind:
        """Construct from a durable codec tag; validation remains explicit."""
        return MetricKind(tag)

    def tag(self) -> UInt8:
        return self._tag

    def is_valid(self) -> Bool:
        return (
            self._tag == _DOT_TAG
            or self._tag == _L2_TAG
            or self._tag == _COSINE_TAG
        )

    def name(self) -> String:
        if self._tag == _DOT_TAG:
            return "dot"
        if self._tag == _L2_TAG:
            return "l2"
        if self._tag == _COSINE_TAG:
            return "cosine"
        return "unknown"

    def __eq__(self, other: MetricKind) -> Bool:
        return self._tag == other._tag


struct ScalarKind(Copyable, Equatable, Movable, Writable):
    """The scalar representation used by the collection's ANN graph."""

    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    @staticmethod
    def f32() -> ScalarKind:
        return ScalarKind(_F32_TAG)

    @staticmethod
    def bf16() -> ScalarKind:
        return ScalarKind(_BF16_TAG)

    @staticmethod
    def f16() -> ScalarKind:
        return ScalarKind(_F16_TAG)

    @staticmethod
    def i8() -> ScalarKind:
        return ScalarKind(_I8_TAG)

    @staticmethod
    def from_tag(tag: UInt8) -> ScalarKind:
        """Construct from a durable codec tag; validation remains explicit."""
        return ScalarKind(tag)

    def tag(self) -> UInt8:
        return self._tag

    def is_valid(self) -> Bool:
        return (
            self._tag == _F32_TAG
            or self._tag == _BF16_TAG
            or self._tag == _F16_TAG
            or self._tag == _I8_TAG
        )

    def name(self) -> String:
        if self._tag == _F32_TAG:
            return "f32"
        if self._tag == _BF16_TAG:
            return "bf16"
        if self._tag == _F16_TAG:
            return "f16"
        if self._tag == _I8_TAG:
            return "i8"
        return "unknown"

    def __eq__(self, other: ScalarKind) -> Bool:
        return self._tag == other._tag


struct CollectionConfig(Copyable, Equatable, Movable, Writable):
    """Immutable-on-disk identity and HNSW tuning for one collection."""

    var dimension: Int
    var ann_metric: MetricKind
    var scalar_kind: ScalarKind
    var m: Int
    var m0: Int
    var ef_construction: Int
    var default_ef_search: Int
    var max_ef_search: Int
    var max_level: Int
    var rebuild_inactive_percent: Int
    var delta_max_points: Int
    var level_seed: UInt64

    def __init__(
        out self,
        dimension: Int,
        ann_metric: MetricKind,
        scalar_kind: ScalarKind,
        m: Int,
        m0: Int,
        ef_construction: Int,
        default_ef_search: Int,
        max_ef_search: Int,
        max_level: Int,
        rebuild_inactive_percent: Int,
        delta_max_points: Int,
        level_seed: UInt64,
    ):
        self.dimension = dimension
        self.ann_metric = ann_metric.copy()
        self.scalar_kind = scalar_kind.copy()
        self.m = m
        self.m0 = m0
        self.ef_construction = ef_construction
        self.default_ef_search = default_ef_search
        self.max_ef_search = max_ef_search
        self.max_level = max_level
        self.rebuild_inactive_percent = rebuild_inactive_percent
        self.delta_max_points = delta_max_points
        self.level_seed = level_seed

    @staticmethod
    def defaults(dimension: Int) -> CollectionConfig:
        return CollectionConfig(
            dimension=dimension,
            ann_metric=MetricKind.l2(),
            scalar_kind=ScalarKind.f32(),
            m=16,
            m0=32,
            ef_construction=128,
            default_ef_search=64,
            max_ef_search=512,
            max_level=32,
            rebuild_inactive_percent=25,
            delta_max_points=10_000,
            level_seed=UInt64(0xA5A5A5A5A5A5A5A5),
        )

    def validate(self) raises:
        if self.dimension <= 0:
            raise Error("dimension must be positive")
        if self.dimension > _UINT32_MAX_AS_INT:
            raise Error("dimension must fit UInt32")
        if not self.ann_metric.is_valid():
            raise Error(
                String(
                    "ann_metric has an unknown tag: ",
                    Int(self.ann_metric.tag()),
                )
            )
        if not self.scalar_kind.is_valid():
            raise Error(
                String(
                    "scalar_kind has an unknown tag: ",
                    Int(self.scalar_kind.tag()),
                )
            )
        if self.m < 2:
            raise Error("m must be at least 2")
        if self.m > _UINT16_MAX_AS_INT:
            raise Error("m must fit UInt16")
        if self.m0 < self.m:
            raise Error("m0 must be greater than or equal to m")
        if self.m0 > _UINT16_MAX_AS_INT:
            raise Error("m0 must fit UInt16")
        if self.ef_construction < self.m0:
            raise Error("ef_construction must be greater than or equal to m0")
        if self.ef_construction > _UINT32_MAX_AS_INT:
            raise Error("ef_construction must fit UInt32")
        if self.default_ef_search < 1:
            raise Error("default_ef_search must be at least 1")
        if self.default_ef_search > _UINT32_MAX_AS_INT:
            raise Error("default_ef_search must fit UInt32")
        if self.max_ef_search < self.default_ef_search:
            raise Error(
                "max_ef_search must be greater than or equal to"
                " default_ef_search"
            )
        if self.max_ef_search > _UINT32_MAX_AS_INT:
            raise Error("max_ef_search must fit UInt32")
        if self.max_level < 1 or self.max_level > 63:
            raise Error("max_level must be between 1 and 63")
        if (
            self.rebuild_inactive_percent < 1
            or self.rebuild_inactive_percent > 90
        ):
            raise Error("rebuild_inactive_percent must be between 1 and 90")
        if self.delta_max_points <= 0:
            raise Error("delta_max_points must be positive")
        if self.delta_max_points > _UINT32_MAX_AS_INT:
            raise Error("delta_max_points must fit UInt32")
        if (
            self.scalar_kind == ScalarKind.i8()
            and self.ann_metric == MetricKind.l2()
        ):
            raise Error("scalar_kind i8 is not compatible with ann_metric l2")

    def metric_name(self) -> String:
        return self.ann_metric.name()

    def scalar_name(self) -> String:
        return self.scalar_kind.name()

    def fingerprint(self) -> UInt64:
        """Return the stable collection-identity fingerprint.

        Fingerprint schema v1 is FNV-1a 64 (offset 14695981039346656037,
        prime 1099511628211) over these bytes in exact order: dimension as
        u64 LE; ANN metric as u8; scalar kind as u8; m, m0, ef_construction,
        default_ef_search, max_ef_search, max_level,
        rebuild_inactive_percent, and delta_max_points each as u64 LE; then
        level_seed as u64 LE. Width and order are intentionally independent
        from the durable collection codec and are locked by golden vectors.
        """
        var value = _FNV_OFFSET_BASIS
        value = _mix_u64(value, UInt64(self.dimension))
        value = _mix_u8(value, self.ann_metric.tag())
        value = _mix_u8(value, self.scalar_kind.tag())
        value = _mix_u64(value, UInt64(self.m))
        value = _mix_u64(value, UInt64(self.m0))
        value = _mix_u64(value, UInt64(self.ef_construction))
        value = _mix_u64(value, UInt64(self.default_ef_search))
        value = _mix_u64(value, UInt64(self.max_ef_search))
        value = _mix_u64(value, UInt64(self.max_level))
        value = _mix_u64(value, UInt64(self.rebuild_inactive_percent))
        value = _mix_u64(value, UInt64(self.delta_max_points))
        value = _mix_u64(value, self.level_seed)
        return value

    def __eq__(self, other: CollectionConfig) -> Bool:
        return (
            self.dimension == other.dimension
            and self.ann_metric == other.ann_metric
            and self.scalar_kind == other.scalar_kind
            and self.m == other.m
            and self.m0 == other.m0
            and self.ef_construction == other.ef_construction
            and self.default_ef_search == other.default_ef_search
            and self.max_ef_search == other.max_ef_search
            and self.max_level == other.max_level
            and self.rebuild_inactive_percent == other.rebuild_inactive_percent
            and self.delta_max_points == other.delta_max_points
            and self.level_seed == other.level_seed
        )


def _mix_u8(value: UInt64, byte: UInt8) -> UInt64:
    return (value ^ UInt64(byte)) * _FNV_PRIME


def _mix_u64(value: UInt64, field: UInt64) -> UInt64:
    var mixed = value
    for byte_index in range(8):
        mixed = _mix_u8(mixed, UInt8(field >> UInt64(byte_index * 8)))
    return mixed
