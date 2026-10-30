# Logical point fixture

`v1.ndjson` is an independently specified, frozen version 1 export: two points,
including a negative named-only ID, nine-bit binary data, BF16 multivectors,
signed zero, absent default fields, and present empty sparse/multivector values.
The source versions differ from the destination's newly allocated sequences.
Do not regenerate this fixture from the production exporter.

`v2.ndjson` independently specifies one ordinary rich payload with an empty
array, UInt64 maximum and null. `v3.ndjson` specifies one typed array containing
storage null, source JSONB null and timezone bytes, an ordinary object whose
keys resemble type markers, a full-range integer and negative-zero float.
Both use the frozen v1 default config with an empty named-vector schema. They
were assembled as JSON records without calling Akasha's exporter; keep them
frozen. Binary bodies also occur in the actual-source jsonb-codec oracle.
