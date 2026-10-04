# HTTP JSON decoder compatibility probe

No production change was made. The prior
[HTTP phase profile](../benchmarks/2026-10-04-binding-gil.md) identifies request
JSON parsing as a material high-dimensional HTTP cost. The existing dependency
`pydantic-core` 2.46.4 supplies `from_json`; this probe checks a direct substitution
before measuring speed or introducing a route implementation.

[Pydantic documents the parser](https://pydantic.dev/docs/validation/latest/concepts/json/),
and [FastAPI documents custom Request/route handling](https://fastapi.tiangolo.com/how-to/custom-request-and-route/).
Installed source confirms Starlette uses `json.loads`, while FastAPI maps
`JSONDecodeError` to structured 422 responses and other parse exceptions to 400.
The installed parser has no separate float-roundtrip option.

With fixed seed 42004, **20,006 numeric values** (random finite F64 values,
long decimal literals, signed zero, underflow/overflow and nonfinite tokens)
produce identical F64 bits in both decoders. Sixteen syntax/encoding examples
expose five acceptance differences: UTF-16, UTF-32, UTF-8 BOM and two lone
surrogate escapes. This is a sampled correctness audit, not a proof for every
possible number or a speed benchmark.

A separate subprocess uses the actual app, kernel and project Python 3.11 /
FastAPI 0.141.1 / Starlette 1.6.0. Both apps create a real collection and record,
then submit ten bodies. A diagnostic override changes only `Request.json` to
call `from_json`; production files and the validated binding remain untouched.

| Request | Baseline | Direct substitution |
| --- | ---: | ---: |
| UTF-8 valid search | 200 | 200, same result |
| UTF-16 / UTF-32 / UTF-8 BOM | 200 each | 400 each |
| Ignored property with lone high / low surrogate | 200 each | 400 each |
| Trailing comma / leading zero / trailing data | 422 each | 400 each |
| Invalid UTF-8 | 400 | 400, same response |

**The direct substitution is not adopted.** It changes accepted inputs and
error responses. This does not prove every integration of a faster parser is
impossible. No compatibility fallback, request-schema shortcut or new dependency
was added, and no HTTP performance pass is claimed. M5/M6 remain unfinished.

[Frozen evidence](../benchmarks/results/2026-10-04-http-json-compatibility.json.gz):
five files, 4,382 bytes, SHA-256
`f3b0f809da21e17d0ceb27a7433609e7f9d38d575f040ae4969f9c69d312a2c9`.
Gzip readback and embedded hashes verified. Includes scripts, all ten paired HTTP
responses, parser outcomes, identities and official reference notes. As-run
directory: `.build/2026-10-04-http-json`. Reproduce in fresh paths with project
Python and `PYTHONPATH` pointing to the intended package; scripts guard runtime
and kernel identities and refuse to overwrite their result JSON.

Current production kernel remains
`780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`.
The applicable latest correctness evidence is
[506 full Python / 118 promoted targeted tests](2026-10-04-binding-close.md).
No new engine integration or performance matrix was run for this probe.
