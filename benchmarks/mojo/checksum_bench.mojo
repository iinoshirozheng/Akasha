from akasha.storage.checksum import crc32
from std.time import perf_counter_ns


def main() raises:
    var data = List[UInt8](capacity=16 * 1024 * 1024)
    for index in range(16 * 1024 * 1024):
        data.append(UInt8(index % 251))
    for sample in range(7):
        var start = perf_counter_ns()
        var result = crc32(data)
        print(
            "crc sample="
            + String(sample)
            + " bytes="
            + String(len(data))
            + " ns="
            + String(perf_counter_ns() - start)
            + " value="
            + String(result)
        )
