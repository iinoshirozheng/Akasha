"""Command-line operations for local Akasha collections."""

import argparse

from .database import Collection
from .operations import (
    backup_collection,
    export_ndjson,
    import_ndjson,
    inspect_storage,
    quarantine_orphans,
    report_json,
    restore_storage,
)


def main() -> None:
    parser = argparse.ArgumentParser(prog="akashadb-admin")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("inspect", "scan"):
        command = commands.add_parser(name)
        command.add_argument("path")
        command.add_argument("dimension", type=int)
    backup = commands.add_parser("backup")
    backup.add_argument("path")
    backup.add_argument("dimension", type=int)
    backup.add_argument("target")
    restore = commands.add_parser("restore")
    restore.add_argument("backup")
    restore.add_argument("dimension", type=int)
    restore.add_argument("target")
    export = commands.add_parser("export")
    export.add_argument("path")
    export.add_argument("dimension", type=int)
    export.add_argument("target")
    import_parser = commands.add_parser("import")
    import_parser.add_argument("path")
    import_parser.add_argument("dimension", type=int)
    import_parser.add_argument("source")
    quarantine = commands.add_parser("quarantine-orphans")
    quarantine.add_argument("path")
    quarantine.add_argument("dimension", type=int)
    quarantine.add_argument("target")
    args = parser.parse_args()

    if args.command in {"inspect", "scan"}:
        print(report_json(inspect_storage(args.path, args.dimension)))
    elif args.command == "restore":
        print(report_json(restore_storage(args.backup, args.target, args.dimension)))
    elif args.command == "quarantine-orphans":
        for path in quarantine_orphans(args.path, args.dimension, args.target):
            print(path)
    else:
        collection = Collection(args.path, args.dimension)
        try:
            if args.command == "backup":
                print(report_json(backup_collection(collection, args.target)))
            elif args.command == "export":
                print(export_ndjson(collection, args.target))
            else:
                print(import_ndjson(collection, args.source))
        finally:
            collection.close()


if __name__ == "__main__":
    main()
