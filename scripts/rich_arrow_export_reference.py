"""Pin and run Arrow's Float64-to-F16/F32 casts for native export comparison."""
from pathlib import Path
import json
import shutil
import subprocess
import tarfile
import tomllib
from rich_arrow_reference import ROOT, LANCE, LANCE_REVISION, digest


def main():
    out = ROOT / "tests/fixtures/rich-arrow-export"
    build = ROOT / ".build/rich-arrow-export-reference"
    out.mkdir(parents=True, exist_ok=True)
    build.joinpath("src").mkdir(parents=True, exist_ok=True)
    actual = subprocess.check_output(["git", "-C", str(LANCE), "rev-parse", "HEAD"], text=True).strip()
    if actual != LANCE_REVISION:
        raise RuntimeError("Lance source revision mismatch")
    manifest = '[package]\nname="akasha-rich-arrow-export-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    arrow_crates = ["arrow-array", "arrow-schema", "arrow-buffer", "arrow-data", "arrow-ord", "arrow-select", "arrow-cast"]
    for name in arrow_crates:
        manifest += f'{name}="=58.4.0"\n'
    manifest += 'serde_json="=1.0.151"\n[workspace]\n'
    (build / "Cargo.toml").write_text(manifest)
    scaffold = ROOT / "scripts/rich_arrow_export_reference.rs"
    shutil.copyfile(scaffold, build / "src/main.rs")
    flags = []
    if (out / "Cargo.lock").exists():
        shutil.copyfile(out / "Cargo.lock", build / "Cargo.lock")
        flags = ["--locked"]
    subprocess.run(["cargo", "fetch", *flags, "--manifest-path", str(build / "Cargo.toml")], check=True)
    provenance = []
    lance_lock = tomllib.loads((LANCE / "Cargo.lock").read_text())["package"]
    for name in [*arrow_crates, "half", "num-traits"]:
        entry = next(p for p in lance_lock if p["name"] == name)
        version = entry["version"]
        selected = next(p for p in tomllib.loads((build / "Cargo.lock").read_text())["package"] if p["name"] == name)
        if entry["checksum"] != selected["checksum"]:
            raise RuntimeError(f"{name} differs from Lance's dependency")
        directory = next((Path.home() / ".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive = Path.home() / ".cargo/registry/cache" / directory.parent.name / f"{name}-{version}.crate"
        if digest(archive.read_bytes()) != entry["checksum"]:
            raise RuntimeError(f"{name} archive checksum mismatch")
        files = []
        with tarfile.open(archive) as tar:
            for path in sorted(directory.joinpath("src").rglob("*.rs")):
                relative = str(path.relative_to(directory)); data = path.read_bytes()
                if data != tar.extractfile(f"{name}-{version}/{relative}").read():
                    raise RuntimeError(f"modified source: {path}")
                files.append(dict(path=relative, sha256=digest(data)))
        provenance.append(dict(name=name, version=version, checksum=entry["checksum"], files=files))
    output = subprocess.check_output(["cargo", "run", "--quiet", "--locked", "--manifest-path", str(build / "Cargo.toml")])
    (out / "casts.json").write_bytes(output)
    shutil.copyfile(build / "Cargo.lock", out / "Cargo.lock")
    metadata = dict(lance_revision=actual, dependencies=provenance,
                    generator_sha256=digest(Path(__file__).read_bytes()), scaffold_sha256=digest(scaffold.read_bytes()),
                    lock_sha256=digest((out / "Cargo.lock").read_bytes()), fixture_sha256=digest(output))
    (out / "sources.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"{len(json.loads(output))} exact Arrow cast cases generated")


if __name__ == "__main__":
    main()
