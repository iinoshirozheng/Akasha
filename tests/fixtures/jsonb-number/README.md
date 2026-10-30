# Original JSONB Number oracle

Regenerate with `pixi run python scripts/jsonb_number_reference.py`.
The generator verifies pinned crates.io archives and original source files,
then runs the original jsonb 0.5.6 Number and ethnum 1.5.3 code in Rust release
mode, locked and offline. It does not reimplement the expected arithmetic.
Arrow 58.4.0's existing checked i256 multiply supplies the Mojo overflow-check
algorithm; its behavior is independently compared with ethnum's implementation.

`cases.json` contains 8,495 typed unary cases, 94,213 ordered pairs (comparison
plus five arithmetic operations each), 2,404 wrapping/checked i256 products,
256 source i128/i256 powers, and 4,709 original/legacy numeric JSONB bodies.
All 36 ordered type combinations, every decimal scale byte, signed/unsigned
extrema and casts, rounding, zero division, subnormal/infinite/NaN values,
exact/fallback scale comparisons and product-boundary overflows are covered.

A number is `[kind, big_endian_hex, scale]`; tags 0..5 are Int64, UInt64,
Float64 bits, Decimal64, Decimal128 and Decimal256. Errors retain source text.
Float conversion and all non-NaN arithmetic results are checked by exact bits;
arithmetic NaNs use classification, since Rust does not guarantee their sign or
payload. Source serialization and decoded variants are compared separately,
so canonical integer zero does not erase the expression's original variant.

`sources.json` records archive/source, generator, scaffold, codec-input, output,
license and lock hashes. This validates the native Number dependency; it does
not stand in for JSONB selector/public-query/index or full product acceptance.
