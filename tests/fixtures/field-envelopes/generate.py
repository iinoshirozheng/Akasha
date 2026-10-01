"""Independent v4 envelope fixtures from struct/zlib and golden point bodies."""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT.parent


def finish(body):
    return body + struct.pack('<I', zlib.crc32(body[4:]))


def binding(name):
    raw = (FIXTURES / 'field-catalog' / name).read_bytes()
    return struct.unpack_from('<Q', raw, 16)[0], struct.unpack_from('<I', raw, len(raw)-4)[0]


def action(fid, value=None):
    return struct.pack('<IBBHI', fid, 2 if value is None else 1, 0, 0,
                       0 if value is None else len(value)) + (value or b'')


def mutation(pid, kind, fields=(), payload=None):
    body = (b'' if payload is None else struct.pack('<I', len(payload)) + payload) + b''.join(fields)
    return struct.pack('<qBBHII', pid, kind, int(payload is not None), 0, len(fields), len(body)) + body


def wal(first, mutations, catalog='named-f32-v2.bin'):
    revision, crc = binding(catalog)
    body = b''.join(mutations)
    return finish(struct.pack('<4sHBBIQIQII', b'AKWL', 4, 4, 0, 44+len(body),
                              first, len(mutations), revision, crc, 0) + body)


def segment(kind, low, high, records, catalog='named-f32-v2.bin'):
    revision, crc = binding(catalog)
    return finish(struct.pack('<4sHHQIIQQQ', b'AKSG', 4, kind, revision, crc, 0,
                              len(records), low, high) + b''.join(records))


def point(name):
    return (FIXTURES / 'point-records' / name).read_bytes()


def main():
    fixtures = {
        'combined-wal-v4.bin': ('named-f32-v2.bin', wal(8, [
            mutation(-42, 1, [action(0, struct.pack('<3f', 1, -0.0, 3)),
                              action(1, struct.pack('<I', 0)),
                              action(2, struct.pack('<2f', 4, 5))], b'\0'*4),
            mutation(-42, 3, [action(2), action(7, struct.pack('<4f', 6, 7, 8, 9))]),
            mutation(-(2**63), 2),
            mutation(2**63-1, 1, [], b'\0'*4),
        ])),
        'last-sequence-wal-v4.bin': ('type-matrix-v2.bin', wal(2**64-1, [mutation(1, 2)], 'type-matrix-v2.bin')),
        'base-v4.bin': ('named-f32-v2.bin', segment(1, 0, 10, [
            point('default-and-named.bin'), point('payload-only.bin'), point('named-only.bin')
        ])),
        'delta-v4.bin': ('named-f32-v2.bin', segment(2, 8, 11, [
            point('deleted.bin'), point('default-and-named.bin'), point('named-only.bin')
        ])),
        'typed-base-v4.bin': ('type-matrix-v2.bin', segment(1, 0, 2**64-1, [
            point('type-matrix.bin'), point('empty-multivector.bin')
        ], 'type-matrix-v2.bin')),
        'empty-base-v4.bin': ('type-matrix-v2.bin', segment(1, 0, 0, [], 'type-matrix-v2.bin')),
    }
    manifest = {}
    for name, (catalog, raw) in fixtures.items():
        (ROOT / name).write_bytes(raw)
        manifest[name] = {'catalog': catalog, 'bytes': len(raw),
                          'crc32': f'{struct.unpack_from("<I", raw, len(raw)-4)[0]:08x}',
                          'sha256': hashlib.sha256(raw).hexdigest()}
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
