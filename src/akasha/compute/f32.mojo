"""Explicit F32 rounding boundaries for source-derived scalar algorithms."""


@no_inline
def rounded_f32_product(left: Float32, right: Float32) -> Float32:
    """Round before addition/subtraction, as the portable Rust source does.

    Mojo 1.0 contract=fast permits FMA across separate statements. The call
    boundary preserves scalar source cancellation, overflow and cosine bits.
    """
    return left * right
