"""Reproduce typed Arrow ingress fixtures using pinned upstream implementations."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
LANCE = ROOT / "reference/lance"
BUILD = ROOT / ".build/rich-arrow-reference"
FIXTURES = ROOT / "tests/fixtures/rich-arrow"
CRATES = {"arrow-array": "58.4.0", "arrow-schema": "58.4.0", "arrow-buffer": "58.4.0",
          "arrow-data": "58.4.0", "arrow-json": "58.3.0", "arrow-ipc": "58.4.0",
          "arrow-select": "58.4.0", "serde_json": "1.0.151"}
LANCE_REVISION = "ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    actual = subprocess.check_output(["git", "-C", str(LANCE), "rev-parse", "HEAD"], text=True).strip()
    if actual != LANCE_REVISION:
        raise RuntimeError("Lance source revision differs from the pinned source")
    BUILD.joinpath("src").mkdir(parents=True, exist_ok=True)
    FIXTURES.mkdir(parents=True, exist_ok=True)
    manifest = '[package]\nname="akasha-rich-arrow-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for name, version in CRATES.items():
        manifest += f'{name}="={version}"\n' if name != "serde_json" else f'serde_json={{version="={version}", features=["preserve_order"]}}\n'
    manifest += "[workspace]\n"
    (BUILD / "Cargo.toml").write_text(manifest)
    if (FIXTURES / "Cargo.lock").exists():
        shutil.copyfile(FIXTURES / "Cargo.lock", BUILD / "Cargo.lock")
    scaffold = ROOT / "scripts/rich_arrow_reference.rs"
    shutil.copyfile(scaffold, BUILD / "src/main.rs")
    sources = []
    for name in ["list", "struct"]:
        path = LANCE / f"rust/lance-arrow/src/{name}.rs"
        data = path.read_bytes()
        if data != subprocess.check_output(["git", "-C", str(LANCE), "show", f"{LANCE_REVISION}:{path.relative_to(LANCE)}"]):
            raise RuntimeError(f"modified Lance source: {path}")
        shutil.copyfile(path, BUILD / f"src/lance_{name}.rs")
        sources.append(dict(path=str(path.relative_to(LANCE)), sha256=digest(data)))
    lock_flag = ["--locked"] if (FIXTURES / "Cargo.lock").exists() else []
    subprocess.run(["cargo", "fetch", *lock_flag, "--manifest-path", str(BUILD / "Cargo.toml")], check=True)
    upstream = tomllib.loads((LANCE / "Cargo.lock").read_text())["package"]
    metadata = []
    for name, version in CRATES.items():
        if name == "serde_json":
            # Generator serialization dependency, not the ported Arrow code.
            continue
        locked = next(p for p in upstream if p["name"] == name and p["version"] == version)
        directory = next((Path.home() / ".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive = Path.home() / ".cargo/registry/cache" / directory.parent.name / f"{name}-{version}.crate"
        if digest(archive.read_bytes()) != locked["checksum"]:
            raise RuntimeError(f"registry checksum mismatch: {name}")
        with tarfile.open(archive) as tar:
            paths = sorted(p for p in directory.rglob("*.rs") if "src" in p.parts)
            hashes = []
            for path in paths:
                relative = str(path.relative_to(directory))
                data = path.read_bytes()
                if data != tar.extractfile(f"{name}-{version}/{relative}").read():
                    raise RuntimeError(f"modified upstream file: {path}")
                hashes.append(dict(path=relative, sha256=digest(data)))
        vcs_path = directory / ".cargo_vcs_info.json"
        vcs = json.loads(vcs_path.read_text()) if vcs_path.exists() else None
        metadata.append(dict(name=name, version=version, checksum=locked["checksum"],
                             revision=vcs["git"]["sha1"] if vcs else None,
                             identity=f"crates.io:{name}@{version}", files=hashes))
    subprocess.run(["cargo", "run", "--quiet", "--locked", "--manifest-path", str(BUILD / "Cargo.toml"), "--", str(FIXTURES)], check=True)
    shutil.copyfile(BUILD / "Cargo.lock", FIXTURES / "Cargo.lock")
    record = dict(lance_revision=actual, lance_sources=sources, dependencies=metadata,
                  generator_sha256=digest(Path(__file__).read_bytes()),
                  scaffold_sha256=digest(scaffold.read_bytes()),
                  lock_sha256=digest((BUILD / "Cargo.lock").read_bytes()),
                  files={p: digest((FIXTURES / p).read_bytes()) for p in ["values.arrow", "expected.json"]})
    (FIXTURES / "sources.json").write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
