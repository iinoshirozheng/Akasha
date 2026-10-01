"""Independent point-body fixtures; no Akasha codec or metadata imports."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent


def record(pid, sequence, document_sequence, fields=(), payload=b'\0' * 4, deleted=False):
    body = payload + b''.join(struct.pack('<II', fid, len(data)) + data for fid, data in fields)
    return struct.pack('<IBBHqQQII', 40 + len(body), 2 if deleted else 1, 0, 0,
                       pid, sequence, document_sequence, len(fields), len(payload)) + body


def main():
    title = struct.pack('<IH', 1, 5) + b'title' + struct.pack('<BI', 1, 3) + b'old'
    fixtures = {
        'default-and-named.bin': ('named-f32-v2.bin', record(-42, 9, 8, [
            (0, struct.pack('<3f', 1, -0.0, 3)),
            (1, struct.pack('<I', 0)),
            (2, struct.pack('<2f', 4, 5)),
        ], title)),
        'named-only.bin': ('named-f32-v2.bin', record(2**63 - 1, 10, 0, [
            (2, struct.pack('<2f', 0, 0)),
            (7, struct.pack('<4f', -1, 2, -3, 4)),
            (9, struct.pack('<Iqfqf', 2, 0, -1, 2**63 - 1, 2)),
        ])),
        'payload-only.bin': ('named-f32-v2.bin', record(0, 7, 0)),
        'deleted.bin': ('named-f32-v2.bin', record(-(2**63), 11, 0, payload=b'', deleted=True)),
        'type-matrix.bin': ('type-matrix-v2.bin', record(-1, 1, 1, [
            (0, struct.pack('<3I', 0x80000000, 1, 0x7f7fffff)),
            (1, struct.pack('<Iqf', 1, 9, 0.5)),
            (2, struct.pack('<7H', 0, 0x8000, 0x3c00, 0xbc00, 1, 0x7bff, 0xfbff)),
            (3, struct.pack('<7H', 0, 0x8000, 0x3f80, 0xbf80, 1, 0x7f7f, 0xff7f)),
            (4, struct.pack('<7b', -128, -127, -1, 0, 1, 126, 127)),
            (5, bytes([0, 1, 2, 127, 128, 254, 255])),
            (6, bytes([255, 1])),
            (7, bytes([1, 128, 1])),
            (8, struct.pack('<I6f', 2, 1, 2, 3, -1, -2, -3)),
        ])),
        'empty-multivector.bin': ('type-matrix-v2.bin', record(42, 2**64 - 1, 0, [
            (8, struct.pack('<I', 0)),
        ])),
    }
    manifest = {}
    for name, (catalog, data) in fixtures.items():
        (ROOT / name).write_bytes(data)
        manifest[name] = {'catalog': catalog, 'bytes': len(data),
                          'sha256': hashlib.sha256(data).hexdigest()}
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
