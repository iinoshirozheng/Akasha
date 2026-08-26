struct QueryPlanner:
    """Deterministic exact-versus-HNSW policy for one collection."""

    comptime EXACT_COLLECTION_THRESHOLD = 64
    comptime SELECTIVITY_DENOMINATOR = 8

    @staticmethod
    def use_hnsw(
        total_count: Int,
        k: Int,
        matched_count: Int,
        has_filter: Bool,
    ) -> Bool:
        if (
            total_count < 0
            or k <= 0
            or matched_count < 0
            or matched_count > total_count
        ):
            return False
        if total_count < QueryPlanner.EXACT_COLLECTION_THRESHOLD:
            return False
        if not has_filter:
            return True
        if matched_count <= k * 2:
            return False
        return (
            matched_count * QueryPlanner.SELECTIVITY_DENOMINATOR >= total_count
        )
