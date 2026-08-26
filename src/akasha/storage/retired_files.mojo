from akasha.storage.filesystem import remove_file_if_exists, sync_directory
from akasha.storage.generation_pins import GenerationPinRegistry
from std.memory import ArcPointer


struct RetiredFileBatch(Movable):
    var maximum_generation: UInt64
    var files: List[String]

    def __init__(out self, maximum_generation: UInt64, var files: List[String]):
        self.maximum_generation = maximum_generation
        self.files = files^

    def clone(self) -> RetiredFileBatch:
        var files = List[String](capacity=len(self.files))
        for index in range(len(self.files)):
            files.append(String(copy=self.files[index]))
        return RetiredFileBatch(self.maximum_generation, files^)


struct RetiredFileQueue(Movable):
    """Obsolete immutable files awaiting snapshot-pin release.

    Callers serialize every method through the collection writer lock.
    """

    var _batches: List[RetiredFileBatch]

    def __init__(out self):
        self._batches = List[RetiredFileBatch]()

    def retire_or_reclaim(
        mut self,
        directory: String,
        maximum_generation: UInt64,
        files: List[String],
        pins: ArcPointer[GenerationPinRegistry],
    ) raises:
        if pins[].has_pin_at_or_before(maximum_generation):
            var owned = List[String](capacity=len(files))
            for index in range(len(files)):
                owned.append(String(copy=files[index]))
            self._batches.append(RetiredFileBatch(maximum_generation, owned^))
            return
        for index in range(len(files)):
            remove_file_if_exists(files[index])
        if len(files) > 0:
            sync_directory(directory)

    def reclaim(
        mut self,
        directory: String,
        pins: ArcPointer[GenerationPinRegistry],
    ) raises:
        if len(self._batches) == 0:
            return
        var retained = List[RetiredFileBatch]()
        var removed_any = False
        for index in range(len(self._batches)):
            if pins[].has_pin_at_or_before(
                self._batches[index].maximum_generation
            ):
                retained.append(self._batches[index].clone())
                continue
            for file_index in range(len(self._batches[index].files)):
                remove_file_if_exists(self._batches[index].files[file_index])
            removed_any = True
        self._batches = retained^
        if removed_any:
            sync_directory(directory)

    def pending_batch_count(self) -> Int:
        return len(self._batches)
