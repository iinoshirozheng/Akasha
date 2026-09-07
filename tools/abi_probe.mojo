@export("akasha_abi_probe_add")
def akasha_abi_probe_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b
