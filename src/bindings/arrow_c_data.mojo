# The Production MVP uses the validated copying column adapter in
# ``python/akashadb/arrow.py``. A trusted Arrow C Data Interface bridge remains
# intentionally disabled until Mojo exposes a stable cross-language ownership
# ABI; this module must not imply zero-copy behavior.
