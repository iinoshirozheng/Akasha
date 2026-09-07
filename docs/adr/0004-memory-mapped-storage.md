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
macOS ARM64 ABI. macOS checks the ARM64 architecture prefix of the target
triple, independently of the Darwin version and selected CPU features.
`CompilationTarget.is_apple_silicon()` is unsuitable here: in Mojo 1.0 it
identifies AMX-capable CPU specializations and is false for generic ARM64.
The public `is_triple()` checks an exact triple, including the OS version;
Mojo 1.0 has no public ARM64 ABI predicate. This boundary consequently uses
`std.sys.info._triple_attr` to inspect the architecture, with a regression
test for a generic CPU target. Replace that internal accessor when a suitable
public API is available. The source for these semantics is the
[Mojo 1.0 standard library](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/sys/info.mojo).
Compile-time assertions also require little endian and 64-bit `Int`/`c_long`.

`MappedFile` stores the immutable byte base, file length, descriptor, and closed
state. Its only public construction path without I/O creates a harmless closed
owner. There is no raw-parts constructor or factory: only `open_readonly`
populates the resource fields after successful validation and acquisition.
Mojo 1.0 does not provide a reliable Rust-style field-privacy boundary, so the
resource fields remain underscore-prefixed module implementation details. A
compile contract prevents the ordinary safe API from regaining a
`MappedFile(base, length, descriptor)` adoption path; code must not mutate
underscore-prefixed fields across the module boundary.

The explicit move initializer transfers the sole ownership. Explicit `close()`
and the destructor share one idempotent, non-raising release path:
unmap a non-empty mapping, close the descriptor, clear all resource state, and
mark the owner closed. An empty file is valid and has length zero, but creates no
zero-length POSIX mapping; its descriptor remains RAII-owned until close.
Because neither `close()` nor a destructor may raise under this interface,
`munmap` and final `close` status values are intentionally ignored and the
ownership state is then cleared. This means cleanup cannot report a late kernel
error to the caller; it does not retain or retry ownership after attempting the
release. Acquisition failures preserve `errno` before any cleanup call and do
raise.

`MappedBytes` never stores or returns a pointer into mapped pages. It stores an
origin-tracked safe pointer to its `MappedFile` owner plus a validated offset and
length. Every byte read goes back through the owner, which checks closed state
and file bounds. Slice validation uses `length <= file_length - offset`, after
first checking `offset <= file_length`, so `offset + length` cannot overflow.
Zero-length slices at end-of-file are valid.

The wrapper does not silently fall back. An unsupported ABI is a compile-time
error: an owned loader for such a target must be selected at compile time,
before instantiating `open_readonly`. The collection's runtime mmap fallback
only catches acquisition errors on supported targets. Owned loading must still
perform the normal size, checksum, layout, and structural validation before
accepting the file. Mapping failure never relaxes validation or turns committed
corruption into usable data.

The mapped inode is immutable for the complete lifetime of every `MappedFile`
that refers to it. It must not be truncated or rewritten in place. POSIX cannot
turn all violations of this rule into a Mojo `Error`: reading a mapped page past
a concurrently truncated file can instead deliver `SIGBUS` to the process.
Akasha's collection sidecar lifecycle satisfies this precondition. It writes a
new `hnsw-<sequence>.bin.tmp`, syncs it, publishes it with `atomic_replace`, and
later unlinks the superseded name. Even a replacement at the same final pathname
changes the directory entry to a new inode; it does not truncate the inode held
by an existing mapping. `write_hnsw_snapshot` must therefore continue to target
the temporary pathname, never a live mapped final sidecar.

Error text uses `std.sys._libc_errno.get_errno`, the same existing internal
standard-library dependency already used by Akasha's filesystem and collection
lock wrappers. Mojo 1.0 has no public errno accessor. This dependency is kept at
the FFI boundary and should migrate when a public API becomes available.

## Verification

The automated ABI gate compiles `tests/c/mapped_file_abi_probe.c` with the host
C headers and compares its output with a Mojo probe importing the actual
mapping constants. It checks `sizeof` and alignment of `struct stat`, offsets
and widths of `st_size`/`st_mode`, signed file size, `off_t`/`size_t` widths,
endianness, and the open/mmap constants. CI runs it on both supported hosts
before the CPU suite. A linked production C shim is unnecessary for these two
fixed ABIs; adding a new ABI still requires a verified layout or a maintained
platform API.

```bash
pixi run pytest tests/python/test_mapped_file_abi.py -q
```

On macOS this also compiles a probe proving that `--target-cpu generic` makes
`is_apple_silicon()` false, then executes the full mapping capability tests
under that same target. Negative compile tests preserve rejection of macOS
x86-64 and Linux ARM64 instead of widening support accidentally.

On the development macOS ARM64 host (Mojo 1.0.0), eight capability tests open a
page-sized fixture and verify first/last bytes, checked slices, overflow and
bounds rejection, empty and missing files, a harmless default owner, double
close, post-close slice rejection, observable descriptor cleanup after scope
exit, and explicit-move exactly-once ownership. The descriptor assertions use
`fcntl(F_GETFD)` and require `EBADF` after cleanup. A native SDK C probe reported
`sizeof(struct stat) == 144` and `offsetof(st_size) == 96`.
Two reproducible compile contracts confirm that the raw-parts constructor is
not callable and that `MappedBytes[origin_of(mapped)]` cannot be returned as an
untracked-origin value, so its safe owner pointer cannot outlive the
`MappedFile`. Run them with:

```bash
pixi run pytest tests/python/test_mapped_file_compile_contract.py -q
```

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
