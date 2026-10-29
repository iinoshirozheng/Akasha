"""DBSF normalization ported from Qdrant's Apache-2.0 score_fusion.rs.

Source: qdrant/qdrant@74f3e85b9473c62560006c043e13737ce6b48412,
lib/segment/src/common/score_fusion.rs (norm, welfords_mean_variance,
distr_norm). Modified for Mojo score lists and finite-value validation.
Attribution and exact source hashes: docs/upstream/ports.json.
"""

from std.math import isfinite, sqrt


def distribution_normalize(scores: List[Float32]) raises -> List[Float32]:
    """Normalize with upstream sample variance and three-sigma bounds.

    Values outside those bounds are deliberately not clamped. The only
    behavior added at this boundary is rejecting nonfinite inputs/results.
    """
    for score in scores:
        if not isfinite(score):
            raise Error("DBSF requires finite Float32 scores")
    if len(scores) == 0:
        return []
    if len(scores) == 1:
        return [Float32(0.5)]

    var mean = Float32(0)
    var aggregate = Float32(0)
    for index in range(len(scores)):
        var old_delta = scores[index] - mean
        mean += old_delta / Float32(index + 1)
        var delta = scores[index] - mean
        aggregate += old_delta * delta
    var variance = aggregate / (Float32(len(scores)) - Float32(1))
    var std_dev = sqrt(variance)
    var lower = mean - Float32(3) * std_dev
    var upper = mean + Float32(3) * std_dev
    if not isfinite(lower) or not isfinite(upper):
        raise Error("DBSF normalization exceeds finite Float32 range")

    var normalized = List[Float32](capacity=len(scores))
    for score in scores:
        var value = Float32(0.5)
        if lower != upper:
            value = (score - lower) / (upper - lower)
            if not isfinite(value) or not isfinite(upper - lower):
                raise Error("DBSF normalization exceeds finite Float32 range")
        normalized.append(value)
    return normalized^
