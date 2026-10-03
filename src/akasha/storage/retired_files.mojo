from akasha.storage.file_leases import try_reclaim_file
from akasha.storage.filesystem import sync_file
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


struct RetiredFileQueue(Movable):
    """Retry obsolete paths whose exact file leases or I/O defer deletion.

    Callers serialize this queue through the collection writer lock. Leases
    independently reclaim their own files after the collection has closed.
    """

    var _files: List[String]

    def __init__(out self):
        self._files = List[String]()

    def retire_or_reclaim(
        mut self, directory: String, files: List[String]
    ) raises:
        self.enqueue(files)
        self.reclaim(directory)

    def enqueue(mut self, files: List[String]):
        """Queue proven-obsolete paths without performing filesystem I/O."""
        self._files.extend(files.copy())

    def detach(mut self) -> RetiredFileQueue:
        """Transfer pending paths to one I/O owner; caller serializes mutation."""
        var pending = RetiredFileQueue()
        pending._files = self._files^
        self._files = List[String]()
        return pending^

    def restore(mut self, pending: RetiredFileQueue):
        """Keep deferred/retry paths alongside any newly queued paths."""
        self._files.extend(pending._files.copy())

    def reclaim(mut self, directory: String) raises:
        if len(self._files) == 0:
            return
        var handle = open(directory, "r")
        self._reclaim_from_handle(directory, handle)

    def _reclaim_from_handle(
        mut self, directory: String, handle: FileHandle
    ) raises:
        var retained = List[String]()
        var removed = False
        for path in self._files:
            var prefix = directory + "/"
            if not path.startswith(prefix):
                raise Error("retired file belongs to a different directory")
            var name = String(path.removeprefix(prefix))
            if (
                name.byte_length() == 0
                or name == "."
                or name == ".."
                or "/" in name
            ):
                raise Error("retired file must be a basename")
            if try_reclaim_file(handle, name):
                removed = True
            else:
                retained.append(path.copy())
        # Keep the original queue on any unlink/fsync error for a later retry.
        if removed:
            sync_file(handle)
        self._files = retained^


def reclaim_retired_batch(
    directory: String,
    retired: ArcPointer[RetiredFileQueue],
    writer_lock: ArcPointer[BlockingSpinLock],
) raises:
    """Detach under the writer lock, reclaim outside it, and restore retries.

    The caller must not hold the writer lock. An open directory anchors the
    detached batch across path replacement. The operation's source owner must
    remain alive until this function returns, including on an I/O failure.
    """
    var pending: RetiredFileQueue
    var handle: FileHandle
    with BlockingScopedLock(writer_lock[]):
        if len(retired[]._files) == 0:
            return
        # Open before detaching: failure leaves every path in the shared queue.
        handle = open(directory, "r")
        pending = retired[].detach()
    try:
        pending._reclaim_from_handle(directory, handle)
    except error:
        with BlockingScopedLock(writer_lock[]):
            retired[].restore(pending)
        raise error^
    with BlockingScopedLock(writer_lock[]):
        retired[].restore(pending)
