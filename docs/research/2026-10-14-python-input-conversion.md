# Python query conversion diagnostic

Direct NumPy conversion does **not** improve the fixed Python-list input
boundary. In the corrected probe, a 1536D list takes 13.432 µs through the
existing scalar helper, versus 22.314 µs with `asarray`, 17.282 µs with counted
`fromiter` and 17.759 µs with unbounded `fromiter`. The alternatives also change
conversion behavior for some inputs. No engine or package dependency change is
made, and no database acceptance trial is rerun for these rejected alternatives.

The investigation follows the remaining selective failures in the
[filtered-only delta candidate](2026-10-14-delta-filtered-four.md). Inspection
confirms `SearchRequest.vector` is passed through to `_float_vector`, which
reserves a Mojo list using `len(value)` and iterates Python values through
`Float32(py=item)`. The original benchmark starts both engines from the same
Python list and includes request creation plus search; this input boundary is
preserved in the list cases here.

An isolated Python extension contains that helper verbatim and three diagnostic
alternatives. They create a NumPy float32 array, borrow it with the project's
existing `from_numpy_array` API and bulk-copy into an owned Mojo list. An
immutable-argument helper keeps the Python owner alive during the read borrow;
the returned list is independent. NumPy 2.4.6 is already in the project Pixi
environment; the package metadata is unchanged.

| Python list dimension | Existing scalar µs | `asarray` µs | Counted `fromiter` µs | Unbounded `fromiter` µs |
| --- | ---: | ---: | ---: | ---: |
| 3 | .226 | 3.976 | 4.012 | 3.866 |
| 16 | .298 | 3.266 | 3.117 | 3.094 |
| 128 | 1.238 | 4.488 | 4.084 | 4.048 |
| 1536 | 13.432 | 22.314 | 17.282 | 17.759 |
| 4096 | 35.476 | 53.508 | 40.834 | 42.145 |

Five dimensions and four input kinds (list, tuple, contiguous float32 NumPy and
strided NumPy) use seven varying queries, five rotating trials, four variants
and 200 calls per timed block: **400 observations**. All **140 numeric preflight
query groups** match in every Float32 component across the four variants, and
every timed aggregate matches. Timing includes the extension call, conversion,
native bit accumulation, return and destruction; it is not a measurement of
the helper's isolated share of a real database query.

NumPy-array inputs can benefit from a typed borrow and bulk copy. For example,
the initial probe's 1536D contiguous float32 array takes 39.597 µs through scalar
iteration versus 3.439 µs through `asarray`. Both attempts' complete array-input
observations are retained. This does not justify changing the original list
input to an array in the acceptance benchmark or assuming an end-to-end
zero-copy query: the engine still receives an owned Mojo list.

The semantic audit records all outcomes, warnings and errors for **39 inputs
per variant**, including signed zero, rounding boundaries, subnormals, NaN
payloads, nonfinite/overflow values, numeric objects, readonly/strided/endian
arrays, nested input and unusual sequence behavior. It reveals:

- All three NumPy conversions accept numeric strings that the original helper
  rejects, and convert a `None` element to NaN instead of raising at conversion.
- Counted `fromiter` truncates an iterable whose reported length is too short,
  and errors when it is too long. It also stops before an item appended by a
  custom numeric conversion. The original loop continues to exhaustion.
- `asarray` handles a bytes sequence differently and rejects the tested
  sequence mutation during array construction.

The counted behavior agrees with NumPy's documented `count` contract: it is
the number of values to read, not merely a reservation hint.
[NumPy 2.4 `fromiter` documentation](https://numpy.org/doc/2.4/reference/generated/numpy.fromiter.html).
These are conversion-level differences; subsequent engine validation may reject
some resulting values, so this probe does not claim every difference would
produce an accepted database query.

The initial probe passed a mutable local Python object directly to the borrow
API, causing readonly input to be rejected. That was a harness borrow-mode
error, not an inherent readonly-array limitation. Changing to an immutable
helper argument fixes that case. The new code compiles and runs successfully;
all **400 initial observations** and their semantic outcomes/source/binary
identity remain alongside the corrected 400. No samples are selected or removed
to improve a performance conclusion. Both attempts find slower list conversion.

The corrected extension compiles in 2.784 s and its probe runs in 1.994 s using
Mojo 1.0.0 (`ed45d567`), metal:4/apple-m4. Its binary SHA-256 is
`2a65ea8e3425f4aa3c4b56d181595b725cd562c00bcf7e0e9c3c36476ed4ac87`.

The [archive](2026-10-14-python-input-conversion.json.gz) contains **28 files,
52,835 bytes**: both runnable probe versions, 800 timing observations, all
semantic outcomes, build logs, binary/source identities and the relevant public
binding/input contracts. Every embedded hash is verified. Archive SHA-256:
`e8589f911382d3da0d4b4f96df7166a9ce50711133380621318cbe08b7572a6b`.

Production engine and Python/C binaries are unchanged. This probe closes no
Qdrant, capacity, native Linux, HTTP or GPU gate; M5/M6 remain incomplete.
