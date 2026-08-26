"""Python adapter for the AkashaDB Mojo kernel."""

from .database import Collection, LocalDatabase
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
    SearchRequest,
    SearchResult,
    SparseElement,
)

__version__ = "0.1.0"

__all__ = [
    "AkashaError",
    "BatchMutation",
    "BatchWriteResult",
    "Collection",
    "CollectionAlreadyOpenError",
    "CollectionClosedError",
    "CollectionNotFoundError",
    "Document",
    "LocalDatabase",
    "PayloadField",
    "SearchRequest",
    "SearchResult",
    "SparseElement",
    "ValidationError",
    "__version__",
]
