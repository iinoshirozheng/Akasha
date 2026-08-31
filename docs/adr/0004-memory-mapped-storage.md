# ADR 0004: Validated read-only memory mapping

- Status: Accepted
- Date: 2026-09-01

## Context

The persisted HNSW checkpoint is immutable after its manifest commit. Loading
that checkpoint into an owned byte buffer duplicates data and prevents the OS
page cache from paging the frozen graph on demand. Akasha therefore needs a
small read-only mapping owner before it can expose a validated graph view.

The wrapper must not let an unchecked raw address escape, and it must retain
the same format validation and recovery rules as the owned loader. Mojo 1.0's
origin system can bind a safe `Pointer` to an owner, but it cannot make a raw
POSIX mapping into initialized typed graph storage. The initial API consequently
exposes checked bytes only; typed HNSW interpretation remains a later layer.

## Decision

`MappedFile` is a unique, movable RAII owner around these POSIX calls:

```c
int open(const char *path, int oflag, ...);
int fstat(int fd, struct stat *buffer);
void *mmap(void *address, size_t length, int protection,
           int flags, int fd, off_t offset);
int munmap(void *address, size_t length);
int close(int fd);
```

The Mojo declarations use `external_call`, `c_int` for descriptors, flags and
status values, `c_size_t` for lengths, `c_long` for the 64-bit `off_t`, and an
`OpaquePointer[MutUntrackedOrigin]` mmap result. `open` is variadic in C, so the
call specifies `num_fixed_args=2`. A null address hint is represented by
`Optional[OpaquePointer[MutUntrackedOrigin]] = None`; Mojo's `Pointer` is
deliberately non-nullable. `MAP_FAILED` is detected as address `-1` before any
dereference. `O_RDONLY` is reused from `std.io.file`; Mojo 1.0 does not expose
`PROT_READ` or `MAP_PRIVATE`, so those two audited POSIX constants remain local.

The mapping constants are:

| Constant | macOS ARM64 | Linux x86-64 |
| --- | ---: | ---: |
| `O_RDONLY` | 0 | 0 |
| `PROT_READ` | 1 | 1 |
| `MAP_PRIVATE` | 2 | 2 |

The supported `struct stat` layouts are:

| Target | `sizeof(struct stat)` | `offsetof(st_size)` | `st_size` |
| --- | ---: | ---: | --- |
| macOS ARM64 | 144 | 96 | signed 64-bit `off_t` |
| Linux x86-64 (glibc) | 144 | 48 | signed 64-bit `off_t` |

The same layouts place `st_mode` at byte 4 as a 16-bit value on macOS and
byte 24 as a 32-bit value on Linux. The wrapper passes the reconstructed mode
to the standard library's `std.stat.S_ISREG` and rejects directories, devices,
sockets, and other special files before considering empty-file behavior.

The stat scratch allocation uses Mojo 1.0's layout-aware
`alloc(Layout[Int](count=18)).into_managed()`. This gives the `st_size` word its
required eight-byte alignment while keeping allocation ownership automatic.
Compilation is restricted to the exact supported Linux triple and the Pixi
macOS ARM64 target; another target must use the owned loader.

`MappedFile` stores the immutable byte base, file length, descriptor, and closed
state. Its explicit move initializer transfers the sole ownership. Explicit
`close()` and the destructor share one idempotent, non-raising release path:
unmap a non-empty mapping, close the descriptor, clear all resource state, and
mark the owner closed. An empty file is valid and has length zero, but creates no
zero-length POSIX mapping; its descriptor remains RAII-owned until close.
Because neither `close()` nor a destructor may raise under this interface,
`munmap` and final `close` status values are intentionally ignored after the
ownership state is cleared. Acquisition failures preserve `errno` before any
cleanup call and do raise.

`MappedBytes` never stores or returns a pointer into mapped pages. It stores an
origin-tracked safe pointer to its `MappedFile` owner plus a validated offset and
length. Every byte read goes back through the owner, which checks closed state
and file bounds. Slice validation uses `length <= file_length - offset`, after
first checking `offset <= file_length`, so `offset + length` cannot overflow.
Zero-length slices at end-of-file are valid.

The wrapper does not silently fall back. A consumer may respond to an
unsupported target or mmap failure by running the existing bounded owned-load
path, but it must then perform the normal size, checksum, layout, and structural
validation before accepting the file. Mapping failure never relaxes validation
or turns committed corruption into usable data.

Error text uses `std.sys._libc_errno.get_errno`, the same existing internal
standard-library dependency already used by Akasha's filesystem and collection
lock wrappers. Mojo 1.0 has no public errno accessor. This dependency is kept at
the FFI boundary and should migrate when a public API becomes available.

## Verification

On the development macOS ARM64 host (Mojo 1.0.0), the capability test opens a
page-sized fixture and verifies first/last bytes, checked slices, overflow and
bounds rejection, empty and missing files, double close, post-close slice
rejection, and scope-based destructor cleanup. A native SDK C probe reported
`sizeof(struct stat) == 144` and `offsetof(st_size) == 96`.
A compile-fail ownership probe also confirms that
`MappedBytes[origin_of(mapped)]` cannot be returned as an untracked-origin
value, so its safe owner pointer cannot outlive the `MappedFile`.

For Linux x86-64, a Debian bookworm glibc C probe running in a `linux/amd64`
container reported `144` and `48`, and Mojo successfully emitted an x86-64 ELF
object for the capability test with:

```bash
pixi run mojo build \
  --target-triple x86_64-unknown-linux-gnu \
  --target-cpu=x86-64-v3 \
  --emit object -I src tests/mojo/test_mapped_file.mojo \
  -o /tmp/test_mapped_file_linux.o
```

The Linux Mojo run remains a CI execution gate, not a locally claimed runtime
result. The repository's `ubuntu-latest` matrix runs:

```bash
pixi run mojo run -I src tests/mojo/test_mapped_file.mojo
```

## Consequences

- Frozen checkpoint bytes can be owned by the OS page cache without exposing an
  unchecked application pointer.
- Empty files, close semantics, supported ABI layouts, and fallback validation
  are explicit contracts rather than caller assumptions.
- Byte access adds checked indirection. Task 24 may build typed immutable views
  only after validating ranges, alignment, counts, and serialized structure.
- Adding another libc ABI requires its own proven `struct stat` layout or a
  different maintained platform API; guessing offsets is not acceptable.
