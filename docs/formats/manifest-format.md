# Manifest Binary Format v1

`manifest.bin` is the commit point for a flushed snapshot. It names exactly one
immutable segment and records the metadata required to validate it.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKMF` |
| 4 | 2 | Version (`1`) |
| 6 | 2 | Flags (must be `0`) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Segment last sequence |
| 20 | 4 | Referenced segment CRC32 |
| 24 | 2 | UTF-8 segment filename byte length |
| 26 | 2 | Reserved (must be `0`) |
| 28 | variable | UTF-8 segment filename |
| final 4 | 4 | Manifest CRC32 of bytes `[4, final 4)` |

The filename must be non-empty and may not contain `/` or a NUL byte. Akasha
writes `manifest.bin.tmp`, fsyncs it, atomically renames it to `manifest.bin`,
and fsyncs the collection directory. Recovery only trusts the segment named by
a valid manifest; unreferenced segment files are harmless orphans.

