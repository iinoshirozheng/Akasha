"""Independent NumPy oracles for native field-score contracts."""

import numpy as np


def f16_cosine(lhs, rhs):
    """Qdrant half cosine on canonical half inputs, with scalar F32 sums."""
    def prepare(values):
        values = np.asarray(values, dtype=np.float16).astype(np.float32)
        length = np.add.accumulate(values * values, dtype=np.float32)[-1]
        if length >= np.finfo(np.float32).eps and abs(length - 1) > 1e-6:
            values = values / np.sqrt(length)
        return values.astype(np.float16).astype(np.float32)

    return float(np.add.accumulate(prepare(lhs) * prepare(rhs), dtype=np.float32)[-1])
