# Finish callback-safe binding boundaries

The first two search methods were fixed in `a269d81`. A follow-up subprocess
audit of adjacent binding entry points reproduces 32 additional process aborts,
with 13 existing passing cases. Preserve both groups and the earlier 72 tests.
Work is isolated under `.build/2026-10-04-binding-close`; production begins with
Python kernel `b8a66097…`, unchanged core engine `cc15f37`.

Use the existing closed-handle checks after Python conversions and before native
access. Materialize inline native call arguments before borrowing the collection;
keep native argument order and error precedence. For recognized metric branches,
check inside the branch so unknown-metric errors remain unchanged. For named
operations, check separately before schema capture and after query conversion.
No new ownership abstraction, heap allocation, GIL release, engine or format change.

Legacy Arrow ingestion must not retain a native collection borrow through Python
descriptor conversion. Pass the Python owner into its existing helper, capture
dimension/mode only after checking the handle, then recheck before native commit.
Retain array owners and bounded staging. The native commit phase has no Python
conversion. Named Arrow similarly checks before schema capture and commit.

Scanner construction checks before schema/snapshot acquisition. A captured
snapshot continues to outlive collection close as already specified. Next-batch
checks after converting the cancellation flag and captures visited-slot stats
before Python/Arrow export; it must not read a scanner handle after export can
invoke Python. Add focused coverage for export-time close if reproducible.

Run failing baseline cases first, compile the copied entry with the pinned Mojo
1.0.0/Metal wrapper, then run targeted and full saved-package Python with guarded
imports and `-o pythonpath=`. Adopt only after correctness passes. No benchmark
claim follows from this correction. Run jobs serially; retain failed runs and
immutable evidence. M5/M6 performance and Linux/nonresident remain unfinished.

## Result

The first 45-case baseline produced 32 empty-Optional aborts and 13 passes.
A separate Arrow import callback reproducer added a 33rd abort; its batch was
already captured, but reading visited-slot stats after callback close failed.
The candidate passes all 46 new cases and 506 full Python tests (388 original,
72 earlier conversion-close cases, 46 new cases). Only the Python binding source
changed; the existing core and native worker remain unchanged. Promotion copies
the tested binary; both conversion-close files are rechecked after promotion.
No new performance gate is claimed.
