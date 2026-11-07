"""Independent v1/v3 cache fingerprint oracle; no Akasha imports."""
import json
import struct
import zlib


def payload(fields, version):
    out = (struct.pack("<I", len(fields)) if version == 1 else
           struct.pack("<IHHI", 0xFFFFFFFF, version, 0, len(fields)))
    for name, kind, value in fields:
        name = name.encode()
        out += struct.pack("<H", len(name)) + name + bytes([kind])
        if kind == 1:
            value = value.encode()
            out += struct.pack("<I", len(value)) + value
        else:
            out += struct.pack({2: "<q", 3: "<d", 4: "<?"}[kind], value)
    return out


def checksum(rows, version):
    out = struct.pack("<II", 2, len(rows))
    for id, sequence, tombstone, vector, fields in rows:
        encoded = payload(fields, version)
        out += struct.pack("<qQBBH", id, sequence, tombstone, 0, 0)
        out += struct.pack("<" + "f" * len(vector), *vector)
        out += struct.pack("<I", len(encoded)) + encoded
    return f"{zlib.crc32(out):08X}"


def main():
    rows = [(-7, 1, False, [-0., 1.5], [("tag", 1, "長長長"),
             ("n", 2, -(2**63)), ("f", 3, -0.), ("b", 4, True)]),
            (-(2**63), 2, False, [2., -3.], []), (42, 3, False, [4., 5.], [])]
    states = [rows.copy()]
    rows[2] = (42, 4, False, [9., -7.], [("b", 4, False)])
    states.append(rows.copy())
    rows[0] = (-7, 5, True, [], [])
    states.append(rows.copy())
    rows.append((-100, 6, True, [], []))
    states.append(rows.copy())
    rows[0] = (-7, 7, False, [8.25, -0.], [("n", 2, 2**63 - 1)])
    states.append(rows.copy())
    print(json.dumps({f"v{version}": [checksum(state, version) for state in states]
                      for version in (1, 3)}, indent=2))


if __name__ == "__main__":
    main()
