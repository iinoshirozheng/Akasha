"""Query-scoring boundary for the shared HNSW traversal.

Follows Qdrant's QueryScorer/FilteredScorer separation at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0). Graph topology and
admission stay independent of the query's scoring strategy. Heap distances
are lower-is-better; each scorer owns its public-score conversion.
"""

from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.query.control import QueryControl


trait HnswQueryScorer:
    def validate[GraphType: HnswGraphAccess](self, graph: GraphType) raises:
        ...

    def distance[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slot: UInt32, control: Optional[QueryControl],
    ) raises -> Float32:
        ...

    def distance_four[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slots: SIMD[DType.uint32, 4], control: Optional[QueryControl],
    ) raises -> SIMD[DType.float32, 4]:
        ...

    def public_score(self, distance: Float32) -> Float32:
        ...

    def backend_name(self) -> String:
        ...

    def metric_name(self) -> String:
        ...

    def scalar_name(self) -> String:
        ...


struct MetricPointScorer(HnswQueryScorer, Movable):
    """Existing prepared nearest-vector scoring, including four-row kernels."""

    var dispatcher: MetricDispatcher
    var prepared: List[Float32]

    def __init__(out self, dispatcher: MetricDispatcher, var prepared: List[Float32]):
        self.dispatcher = dispatcher.copy()
        self.prepared = prepared^

    def validate[GraphType: HnswGraphAccess](self, graph: GraphType) raises:
        self.dispatcher.require_supported_backend()
        if self.dispatcher.dimension() != graph.graph_dimension():
            raise Error("metric dispatcher dimension does not match HNSW graph")
        self.dispatcher.validate_prepared_vector(self.prepared)

    def distance[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slot: UInt32, control: Optional[QueryControl],
    ) raises -> Float32:
        comptime if backend_tag < 0:
            return graph.distance_to_slot(self.dispatcher, self.prepared, slot)
        else:
            return graph._distance_to_slot_backend[backend_tag](self.dispatcher, self.prepared, slot)

    def distance_four[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slots: SIMD[DType.uint32, 4], control: Optional[QueryControl],
    ) raises -> SIMD[DType.float32, 4]:
        return graph._distance_to_four_f32[backend_tag](self.dispatcher, self.prepared, slots)

    def public_score(self, distance: Float32) -> Float32:
        return self.dispatcher.public_score(distance)

    def backend_name(self) -> String:
        return self.dispatcher.backend_name()

    def metric_name(self) -> String:
        return self.dispatcher.metric_name()

    def scalar_name(self) -> String:
        return self.dispatcher.scalar_name()
