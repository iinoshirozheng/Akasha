"""Python adapter for the AkashaDB Mojo kernel."""

from .database import Collection, LocalDatabase
from .arrow import ArrowBatchLease, results_to_record_batch, upsert_record_batch
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
    Document,
    PayloadField,
    Projection,
    SearchRequest,
    SearchResult,
    SparseElement,
)

__version__ = "0.1.0"

__all__ = [
    "AkashaError",
    "ArrowBatchLease",
    "BatchMutation",
    "BatchWriteResult",
    "Collection",
    "CollectionAlreadyOpenError",
    "CollectionClosedError",
    "CollectionNotFoundError",
    "Document",
    "LocalDatabase",
    "PayloadField",
    "Projection",
    "SearchRequest",
    "SearchResult",
    "SparseElement",
    "ValidationError",
    "results_to_record_batch",
    "upsert_record_batch",
    "__version__",
]
