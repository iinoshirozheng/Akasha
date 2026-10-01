"""Independent field-catalog fixtures; run from any directory to reproduce."""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent


def config(dimension, metric=1, graph_scalar=0):
    body = struct.pack('<4sHHIBBHHHIIIHBBIQQ', b'AKCF', 1, 0, dimension,
                       metric, graph_scalar, 16, 32, 0, 128, 64, 512,
                       32, 25, 0, 10000, 0xA5A5A5A5A5A5A5A5, 0)
    assert len(body) == 56
    return body + struct.pack('<I', zlib.crc32(body[4:]))


def field(fid, name, kind, scalar, metric, index, dimension, graph=b''):
    name = name.encode('utf-8')
    return (struct.pack('<IBBBBIHHII', fid, kind, scalar, metric, index,
                        dimension, len(name), len(graph), 0, 0) + name + graph)


def catalog(fields, cutover=7):
    length = 36 + sum(map(len, fields))
    body = struct.pack('<4sHHIIQQ', b'AKCF', 2, 0, length, len(fields), 1, cutover)
    body += b''.join(fields)
    return body + struct.pack('<I', zlib.crc32(body[4:]))


def main():
    defaults = [field(0, '', 0, 0, 1, 1, 3, config(3, 1, 2)),
                field(1, '', 1, 0, 0, 2, 0)]
    named = defaults + [field(2, 'image', 0, 0, 2, 1, 2, config(2, 2, 1)),
                        field(7, 'text', 0, 0, 0, 0, 4),
                        field(9, '詞', 1, 0, 0, 2, 0)]
    matrix = defaults + [field(2, 'half', 0, 2, 1, 0, 7),
                         field(3, 'brain', 0, 1, 2, 0, 7),
                         field(4, 'signed', 0, 3, 0, 0, 7),
                         field(5, 'unsigned', 0, 4, 1, 0, 7),
                         field(6, 'bits', 3, 5, 3, 0, 9),
                         field(7, 'bits_j', 3, 5, 4, 0, 17),
                         field(8, 'patches', 2, 0, 0, 0, 3)]
    fixtures = {'legacy-v1.bin': config(3, 1, 2),
                'named-f32-v2.bin': catalog(named),
                'type-matrix-v2.bin': catalog(matrix, cutover=0)}
    metadata = {}
    for name, data in fixtures.items():
        (ROOT / name).write_bytes(data)
        metadata[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                          'crc32': f'{struct.unpack("<I", data[-4:])[0]:08x}'}
    (ROOT / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    main()
