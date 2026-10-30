# Original Qdrant geographic formula reference

Generate with `rtk proxy python3 scripts/qdrant_geo_reference.py`. Requires the
local pinned Qdrant checkout and the Cargo registry versions fixed in Cargo.lock;
the generator uses offline locked Cargo builds. It first reproduces the existing
rich-formula oracle, then extends that scaffold with the original GeoPoint methods
and the actual `geo = 0.33.1` crate. It does not require a pre-existing .build file.

Sources: Qdrant `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0),
GeoRust `geo` 0.33.1 at `5ab50b072e34a915a33eaa46c80763d51d61295e`
(MIT OR Apache-2.0). The dependency archive matches Qdrant Cargo.lock's checksum;
the read source file is verified against the archive. License and source hashes
are retained in `docs/upstream/ports.json` and `geo.json`.

The fixture executes 22 unchanged extracted Qdrant units plus the original nom
parser and pinned geo implementation. It contains 30 serde/coordinate cases
(7 accepted, 23 errors), 796 F64 distance cases and 1,064 F32 formula cases
(886 scores, 178 errors). All 796 valid-coordinate distances in this fixture
are finite; it does not claim to demonstrate a valid-coordinate NaN case.

Coverage includes poles, antimeridian, small distances, random/antipodal pairs,
map/sequence parsing, ignored point keys, inclusive coordinate bounds, rich
paths/defaults, singleton/multiple arrays, short circuits and exponential decay.
The scalar OrderedFloat wrapper, map-backed payload provider, no-op counters,
Vec MultiValue and request transport are adapters. Geographic validation,
retrieval and scoring bodies are original. The date adapter remains unused.
Decay transport covers a fixed source-equivalent midpoint/scale; the full decay
parser remains covered by the earlier unchanged scalar oracle.

No Qdrant server, typed geo index, polygon/radius filtering, distributed request
or protocol compatibility is implied. All expected values come from Rust;
Python only generates inputs and records output.
