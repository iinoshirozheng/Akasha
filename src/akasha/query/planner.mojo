struct HnswPlan(Movable, Writable):
    """One deterministic exact-versus-HNSW dense-query decision."""

    var use_hnsw: Bool
    var initial_ef: Int
    var max_ef: Int
    var reason: String

    def __init__(
        out self,
        use_hnsw: Bool,
        initial_ef: Int,
        max_ef: Int,
        var reason: String,
    ):
        self.use_hnsw = use_hnsw
        self.initial_ef = initial_ef
        self.max_ef = max_ef
        self.reason = reason^


struct QueryPlanner:
    """Deterministic exact-versus-HNSW policy for one collection."""

    comptime EXACT_COLLECTION_THRESHOLD = 64
    comptime SELECTIVITY_DENOMINATOR = 8

    @staticmethod
    def plan_dense(
        total_count: Int,
        matched_count: Int,
        k: Int,
        requested_ef: Int,
        max_ef: Int,
        has_filter: Bool,
        metric_compatible: Bool,
        graph_ready: Bool,
    ) -> HnswPlan:
        var normalized_max = max_ef
        if normalized_max < 0:
            normalized_max = 0
        var initial_ef = requested_ef
        if initial_ef < k:
            initial_ef = k
        if initial_ef > normalized_max:
            initial_ef = normalized_max

        if (
            total_count < 0
            or matched_count < 0
            or matched_count > total_count
            or k <= 0
            or requested_ef <= 0
            or max_ef <= 0
        ):
            return HnswPlan(
                False,
                initial_ef,
                normalized_max,
                String("invalid_request"),
            )
        if max_ef < k:
            return HnswPlan(
                False,
                initial_ef,
                normalized_max,
                String("ef_limit_below_k"),
            )
        if total_count < QueryPlanner.EXACT_COLLECTION_THRESHOLD:
            return HnswPlan(
                False,
                initial_ef,
                normalized_max,
                String("small_collection"),
            )
        if not metric_compatible:
            return HnswPlan(
                False,
                initial_ef,
                normalized_max,
                String("metric_mismatch"),
            )
        if not graph_ready:
            return HnswPlan(
                False,
                initial_ef,
                normalized_max,
                String("graph_unavailable"),
            )
        if has_filter:
            # Express matched_count <= 2*k without overflowing k*2.
            if matched_count <= k or matched_count - k <= k:
                return HnswPlan(
                    False,
                    initial_ef,
                    normalized_max,
                    String("filtered_match_count"),
                )
            # HNSW is worthwhile only when at least one eighth of the live
            # collection is eligible. Compute ceil(total/8) without addition
            # or multiplication overflow.
            var ann_match_floor = (
                total_count // QueryPlanner.SELECTIVITY_DENOMINATOR
            )
            if total_count % QueryPlanner.SELECTIVITY_DENOMINATOR != 0:
                ann_match_floor += 1
            if matched_count < ann_match_floor:
                return HnswPlan(
                    False,
                    initial_ef,
                    normalized_max,
                    String("selectivity"),
                )
        return HnswPlan(
            True, initial_ef, normalized_max, String("ann")
        )

    @staticmethod
    def use_hnsw(
        total_count: Int,
        k: Int,
        matched_count: Int,
        has_filter: Bool,
    ) -> Bool:
        var plan = QueryPlanner.plan_dense(
            total_count,
            matched_count,
            k,
            k,
            k,
            has_filter,
            True,
            True,
        )
        return plan.use_hnsw
