"""Record clean local source pins and the pinned Qdrant REST contract inventory."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(path: Path, *args: str) -> str:
    return subprocess.check_output(["rtk", "proxy", "git", "-C", str(path), *args], text=True).strip()


def main() -> None:
    directory = ROOT / "docs/upstream"
    directory.mkdir(parents=True, exist_ok=True)
    sources = []
    for name in ("qdrant", "qdrant-edge-0.8.0", "lance", "lancedb", "rocksdb", "raft-rs", "pgvector"):
        path = ROOT / "reference" / name
        if git(path, "status", "--porcelain"):
            raise RuntimeError(f"Uncommitted reference changes: {name}")
        licenses = [item for item in path.glob("LICENSE*") if item.is_file()]
        sources.append({"name": name, "revision": git(path, "rev-parse", "HEAD"),
                        "version": git(path, "describe", "--tags", "--always"),
                        "licenses": [{"path": item.name, "sha256": hashlib.sha256(item.read_bytes()).hexdigest()}
                                     for item in sorted(licenses)]})
    (directory / "source-lock.json").write_text(json.dumps({"sources": sources}, indent=2) + "\n")
    contract = ROOT / "reference/qdrant/docs/redoc/v1.19.x/openapi.json"
    api = json.loads(contract.read_text())
    operations = []
    for path, methods in sorted(api["paths"].items()):
        for method, operation in sorted(methods.items()):
            if method not in {"get", "post", "put", "patch", "delete", "head", "options"}:
                continue
            operations.append({"method": method.upper(), "path": path,
                               "operation_id": operation.get("operationId"),
                               "summary": operation.get("summary"),
                               "status": "compatibility_unverified", "evidence": []})
    (directory / "qdrant-rest.json").write_text(json.dumps({
        "revision": sources[0]["revision"], "contract": str(contract.relative_to(ROOT)),
        "sha256": hashlib.sha256(contract.read_bytes()).hexdigest(),
        "note": "Inventory baseline only. Every operation requires client-level behavior verification. Newer upstream features remain in the master ledger.",
        "operations": operations,
    }, indent=2) + "\n")
    print(json.dumps({"sources": len(sources), "rest_operations": len(operations)}))


if __name__ == "__main__":
    main()
