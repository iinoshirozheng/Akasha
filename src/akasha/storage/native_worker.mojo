from std.ffi import OwnedDLHandle


struct NativeWorker(Movable):
    """One bounded native worker with at most one queued callback."""

    var _library: OwnedDLHandle
    var _handle: OpaquePointer[MutUntrackedOrigin]
    var _closed: Bool
    var _close_status: Int32

    def __init__(
        out self,
        var library: OwnedDLHandle,
        handle: OpaquePointer[MutUntrackedOrigin],
    ):
        self._library = library^
        self._handle = handle
        self._closed = False
        self._close_status = 0

    @staticmethod
    def open[
        origin: MutOrigin, CallbackType: AnyType, //
    ](
        library_path: String,
        context: OpaquePointer[origin],
        callback: CallbackType,
    ) raises -> NativeWorker:
        var library = OwnedDLHandle(library_path)
        var open_worker = library.get_function[
            OpaquePointer[MutUntrackedOrigin]
        ]("akasha_worker_open")
        var valid = library.get_function[Int32]("akasha_worker_valid")
        var handle = open_worker(context, callback)
        if valid(handle) == 0:
            raise Error("native maintenance worker failed to start")
        return NativeWorker(library^, handle)

    def __deinit__(deinit self):
        if not self._closed:
            try:
                var close_worker = self._library.get_function[Int32](
                    "akasha_worker_close"
                )
                _ = close_worker(self._handle)
            except:
                pass

    def request(mut self) raises -> Bool:
        if self._closed:
            raise Error("native maintenance worker is closed")
        var request_worker = self._library.get_function[Int32](
            "akasha_worker_request"
        )
        var status = request_worker(self._handle)
        if status == -1:
            raise Error("native maintenance worker is closing")
        if status == -2:
            raise Error("native maintenance worker has failed")
        return status == 1

    def pending_count(self) raises -> Int:
        if self._closed:
            return 0
        var pending = self._library.get_function[Int32](
            "akasha_worker_pending_count"
        )
        return Int(pending(self._handle))

    def is_running(self) raises -> Bool:
        if self._closed:
            return False
        var running = self._library.get_function[Int32](
            "akasha_worker_is_running"
        )
        return running(self._handle) == 1

    def drain(mut self) raises -> Int32:
        if self._closed:
            return self._close_status
        var drain_worker = self._library.get_function[Int32](
            "akasha_worker_drain"
        )
        return drain_worker(self._handle)

    def close(mut self) raises -> Int32:
        if self._closed:
            return self._close_status
        var close_worker = self._library.get_function[Int32](
            "akasha_worker_close"
        )
        self._close_status = close_worker(self._handle)
        self._closed = True
        return self._close_status

    def is_closed(self) -> Bool:
        return self._closed
