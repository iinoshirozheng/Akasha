# Original Lance Arrow JSON conversions

Run `pixi run python scripts/arrow_json_reference.py` from the repository root.
The scaffold compiles the complete unchanged pinned Lance `json.rs`, invokes
`convert_json_columns` and `convert_lance_json_to_arrow`, then writes actual
Arrow IPC input/binary/text batches. Twelve cases cover UTF-8/LargeUTF-8 scalar,
Struct, List, LargeList, FixedSizeList and Map, with nullable slots, JSON null,
extended source syntax, independently sliced leaves, Unicode, nonfinite values,
non-string/duplicate map keys and metadata at nested field/entries/schema levels.

The reference's Map fields deliberately use custom names. PyArrow's C Data
boundary canonicalizes those names; tests compare at that same public boundary.
Akasha retains its existing parent-null masking and nonempty-ingress contracts.
It does not store or recover an input table schema. Projections supply a schema.

`sources.json` pins Lance and all dependency archives/source hashes, the
unchanged source file, scaffolds, lock and 36 IPC files. The original Arrow
writer sorts metadata keys when creating IPC, so these fixtures reproduce
byte-for-byte. Runtime parsing/rendering remains Mojo, never this Rust oracle.
Licenses are retained in `docs/upstream/licenses/{lance,arrow,jsonb}-Apache-2.0.txt`
and associated dependency notices from the preceding JSONB source ports.
