from .distance import cosine_similarity, dot_product, l2_squared_distance
from .dispatch import (
    DistanceBackend,
    DistanceExecutionStats,
    portable_simd_width,
    select_distance_backend,
)
from .gpu import DeviceBatchResult, GpuExecutionOptions, GpuPlan
from .metric import MetricDispatcher
from .quantization import (
    decode_bf16,
    decode_f16,
    decode_symmetric_i8,
    encode_bf16,
    encode_f16,
    encode_symmetric_i8,
    i8_dot_f32,
    normalize_for_cosine_i8,
    round_clamp_u8,
    symmetric_i8_scale,
)
from .simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
