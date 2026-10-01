from akasha.storage.file_leases import try_reclaim_file
from akasha.storage.filesystem import sync_file


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
        self._files.extend(files.copy())
        self.reclaim(directory)

    def reclaim(mut self, directory: String) raises:
        if len(self._files) == 0:
            return
        var handle = open(directory, "r")
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
