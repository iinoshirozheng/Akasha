from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.index_cache import (
    CacheArtifact,
    CACHE_HNSW_KIND,
    publish_cache,
)
from akasha.storage.mapped_file import MappedFile
from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite

comptime _MIB = 1 << 20


def _peak_rss_bytes() -> Int:
    var usage = List[Int64](length=32, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), usage.unsafe_ptr())
    var peak = Int(usage[4])
    comptime if CompilationTarget.is_macos():
        return peak
    else:
        return peak * 1024


def test_cache_publication_does_not_duplicate_the_owned_payload() raises:
    var directory = String("/tmp/akasha-cache-publish-memory")
    var path = directory + "/hnsw.cache"
    ensure_directory(directory)
    remove_file_if_exists(path)
    remove_file_if_exists(path + ".tmp")
    var warm = CacheArtifact(CACHE_HNSW_KIND, 1, 1, 2, 3, [UInt8(9)])
    publish_cache(directory, "hnsw.cache", warm)
    var size = 64 * _MIB
    var artifact = CacheArtifact(
        CACHE_HNSW_KIND,
        1,
        1,
        2,
        3,
        List[UInt8](length=size, fill=0x5A),
    )
    var before = _peak_rss_bytes()
    publish_cache(directory, "hnsw.cache", artifact)
    var growth = _peak_rss_bytes() - before
    print("cache publication peak growth bytes:", growth)
    assert_true(growth < 16 * _MIB, "publication duplicates the owned payload")
    var mapped = MappedFile.open_readonly(path)
    assert_equal(mapped.byte_length(), size + 40)
    assert_equal(mapped.byte_at(36), UInt8(0x5A))
    assert_equal(mapped.byte_at(size + 35), UInt8(0x5A))
    assert_equal(
        mapped.checksum(0, UInt64(size + 36)),
        mapped.load_scalars[DType.uint32, 1](size + 36),
    )
    assert_equal(artifact.payload[0], UInt8(0x5A))
    assert_equal(len(artifact.payload), size)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
