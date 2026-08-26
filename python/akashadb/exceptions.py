"""Stable Python exceptions mapped from Mojo kernel errors."""


class AkashaError(RuntimeError):
    """Base class for all adapter-visible Akasha failures."""


class ValidationError(AkashaError):
    """A request violates a public value or query invariant."""


class CollectionAlreadyOpenError(AkashaError):
    """Another live writer owns the collection directory."""


class CollectionClosedError(AkashaError):
    """The requested collection handle is closed."""


class CollectionNotFoundError(AkashaError):
    """A named local adapter collection is not open."""


def map_kernel_error(error: Exception) -> AkashaError:
    message = str(error)
    if "already open" in message:
        return CollectionAlreadyOpenError(message)
    if "closed" in message:
        return CollectionClosedError(message)
    return ValidationError(message)
