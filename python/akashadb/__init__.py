"""Python adapter for the AkashaDB Mojo kernel."""

from .payload import JsonbValue

from .query import Formula, QueryRequest
from .vectors import ContextPair, FieldQuery, IvfOptions, MmrOptions, Point, PointMutation, VectorField
from .database import CancellationToken, Collection, LocalDatabase
from .arrow import (
    ArrowBatchLease,
    ArrowScanner,
    results_to_record_batch,
    search_record_batch,
    scan_record_batches,
    upsert_record_batch,
)
from .operations import (
    StorageReport,
    backup_collection,
    export_ndjson,
    import_ndjson,
    inspect_storage,
    quarantine_orphans,
    restore_storage,
)
from .distributed import DistributedCluster, ProtocolError, QuorumUnavailable
from .exceptions import (
    AkashaError,
    CollectionAlreadyOpenError,
    CollectionClosedError,
    CollectionNotFoundError,
    ValidationError,
)
from .models import (
    BatchMutation,
    BatchWriteResult,
    CollectionConfig,
    Document,
    PayloadField,
    Projection,
    MetricsSnapshot,
    ResourceLimits,
    SearchRequest,
    SearchResult,
    SearchStats,
    SparseElement,
    TraceRecord,
)

__version__ = "0.1.0"

__all__ = [
    "AkashaError",
    "ArrowBatchLease",
    "ArrowScanner",
    "BatchMutation",
    "BatchWriteResult",
    "StorageReport",
    "Collection",
    "CollectionConfig",
    "CancellationToken",
    "CollectionAlreadyOpenError",
    "CollectionClosedError",
    "CollectionNotFoundError",
    "Document",
    "DistributedCluster",
    "LocalDatabase",
    "PayloadField",
    "JsonbValue",
    "Point",
    "PointMutation",
    "FieldQuery",
    "IvfOptions",
    "MmrOptions",
    "ContextPair",
    "VectorField",
    "Projection",
    "ProtocolError",
    "QuorumUnavailable",
    "MetricsSnapshot",
    "ResourceLimits",
    "SearchRequest",
    "QueryRequest",
    "Formula",
    "SearchResult",
    "SearchStats",
    "SparseElement",
    "TraceRecord",
    "ValidationError",
    "results_to_record_batch",
    "search_record_batch",
    "scan_record_batches",
    "upsert_record_batch",
    "backup_collection",
    "export_ndjson",
    "import_ndjson",
    "inspect_storage",
    "quarantine_orphans",
    "restore_storage",
    "__version__",
]
