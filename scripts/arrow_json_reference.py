"""Reproduce nested IPC using unchanged pinned Lance JSON conversion code."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    previous = ROOT / "tests/fixtures/lance-json"
    evidence = json.loads((previous / "sources.json").read_text())
    source = ROOT / "reference/lance"
    assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == evidence["lance_revision"]
    original = source / evidence["lance_source"]["path"]
    assert sha(original) == evidence["lance_source"]["sha256"]
    build = ROOT / ".build/arrow-json-reference"
    out = ROOT / "tests/fixtures/arrow-json"
    (build / "src").mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    manifest = '[package]\nname="akasha-lance-json-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in evidence["dependencies"]:
        name, version = dep["name"], dep["version"]
        if name == "jsonb":
            manifest += f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n'
        elif name == "serde_json":
            manifest += f'{name}={{version="={version}",features=["preserve_order"]}}\n'
        else:
            manifest += f'{name}="={version}"\n'
        directory = next((Path.home()/".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive = Path.home()/".cargo/registry/cache"/directory.parent.name/f"{name}-{version}.crate"
        assert sha(archive) == dep["checksum"]
        with tarfile.open(archive) as tar:
            for item in dep["files"]:
                file = directory/item["path"]
                assert sha(file) == item["sha256"]
                assert file.read_bytes() == tar.extractfile(f'{name}-{version}/{item["path"]}').read()
    (build/"Cargo.toml").write_text(manifest+'[workspace]\n')
    shutil.copyfile(previous/"Cargo.lock", build/"Cargo.lock")
    shutil.copyfile(original, build/"src/lance_json.rs")
    shutil.copyfile(ROOT/"scripts/arrow_json_reference.rs", build/"src/main.rs")
    data = subprocess.check_output(["cargo", "run", "--quiet", "--release", "--locked", "--offline", "--manifest-path", str(build/"Cargo.toml"), "--", str(out)], env={**os.environ,"CARGO_TARGET_DIR":str(ROOT/".build/lance-json-reference/target")})
    (out/"cases.json").write_bytes(data)
    shutil.copyfile(build/"Cargo.lock",out/"Cargo.lock")
    for item in tomllib.loads((build/"Cargo.lock").read_text())["package"]:
        for dep in evidence["dependencies"]:
            if item["name"] == dep["name"] and item["version"] == dep["version"]:
                assert item["checksum"] == dep["checksum"]
    metadata = dict(lance_revision=evidence["lance_revision"], lance_source=evidence["lance_source"], dependencies=evidence["dependencies"], generator_sha256=sha(__file__), scaffold_sha256=sha(ROOT/"scripts/arrow_json_reference.rs"), files={p.name:sha(p) for p in sorted(out.iterdir()) if p.suffix in (".arrow", ".lock") or p.name == "cases.json"})
    (out/"sources.json").write_text(json.dumps(metadata, indent=2)+"\n")
    print("original Lance conversions:",len(json.loads(data)),"cases /",len(list(out.glob("*.arrow"))),"IPC files")


if __name__ == "__main__":
    main()
