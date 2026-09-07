# ADR 0006: Capability-verified C ABI

## Status

Accepted on 2026-09-07 for Mojo 1.0.0 (`ed45d567`).

## Context

Akasha needs a stable native boundary that does not expose Mojo compiler
layouts. The pinned compiler had to prove that it could emit an unmangled C
symbol, link a host C program, initialize the Mojo runtime without a Mojo
`main()`, and preserve opaque-handle ownership before the API could be claimed.

The official Mojo 1.0.0 `@export` and compilation documentation requires an
explicit `abi("C")` effect. It also requires `initialize_runtime()` before
standard-library use from a non-Mojo shared-library host. That initialization
is documented as idempotent and process-wide.

## Capability gate

The accepted probe source is retained in `tools/abi_probe.mojo`:

```mojo
@export("akasha_abi_probe_add")
def akasha_abi_probe_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b
```

It was verified on macOS arm64 with:

```text
pixi run mojo --version
# Mojo 1.0.0 (ed45d567)
mkdir -p .build/abi-probe
pixi run mojo build --emit shared-lib tools/abi_probe.mojo \
  -o .build/abi-probe/libakasha_probe.dylib
nm -gU .build/abi-probe/libakasha_probe.dylib
# ... T _akasha_abi_probe_add
cc tests/c/abi_probe.c -L.build/abi-probe -lakasha_probe \
  -o .build/abi-probe/probe
DYLD_LIBRARY_PATH=.build/abi-probe .build/abi-probe/probe
# exit 0; result 42
```

`pixi run test-c` additionally proves a live opaque allocation can cross the C
boundary, be used for durable collection operations, be reclaimed once by
`close`, and reopen its persistent state.

Linux uses the same host build with `.so`, `LD_LIBRARY_PATH`, and the platform
linker. It is encoded in the portable Pixi tasks but was not executed on this
macOS host. Shared-library cross compilation is not claimed; a target build
must run with a target linker on that host.

## Decision

Expose ABI version 1 through `include/akasha.h` and
`src/bindings/c_api.mojo`:

- `akasha_collection_t` is opaque. Mojo allocates and owns its aligned
  `PersistentCollection`; `akasha_collection_close(akasha_collection_t **, …)`
  releases it once and sets the caller slot to null. Closing an already-null
  slot is successful. A copied pointer is invalid after close and must not be
  reused.
- Every exported function invokes the idempotent `initialize_runtime()` before
  standard-library use, so hosts have no separate initialization ordering
  contract.
- The ABI contains only fixed-width integers, `float`, opaque pointers, and C
  PODs with exact `struct_size` and `api_version`. Mojo `String`, `List`,
  exceptions, and Mojo struct layouts never cross it.
- Paths and vectors are caller-owned borrowed buffers. Akasha copies their
  contents during the call and retains no pointer.
- Search results and errors are caller-owned output buffers. Search always
  writes the actual/required count; insufficient capacity writes no result
  element and returns `AKASHA_STATUS_BUFFER_TOO_SMALL`.
- Each fallible function receives a caller-initialized `akasha_error_t`. Error
  text is copied into its fixed buffer and is valid until the caller overwrites
  that structure. Invalid or null error structures return
  `AKASHA_STATUS_INVALID_ARGUMENT` without dereferencing them.
- Mojo errors are caught at every export boundary and translated to
  `AKASHA_STATUS_ENGINE_ERROR`; validation performed at the ABI boundary maps
  to `AKASHA_STATUS_INVALID_ARGUMENT`.

The supported functions cover open, close, upsert, delete, flush, approximate
search using the collection's durable metric, and last-search stats.

## Consequences

ABI version 1 supports the repository's declared 64-bit `osx-arm64` and
`linux-64` platforms. Changing field order, field width, enum values, or
ownership semantics requires a new ABI version. Language-specific wrappers are
outside this decision and must build on this C contract rather than Mojo
layouts.
