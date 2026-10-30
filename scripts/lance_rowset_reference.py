"""Actual roaring point-set operations and original Lance nullable formulas."""
from pathlib import Path
import hashlib
import json
import os
import random
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
REVISION = "ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e"


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def inputs():
    rng = random.Random(318602)
    edge = [0, 1, 63, 64, 65535, 65536, 65537, (1<<32)-1, 1<<32, (1<<63)-1, 1<<63, (1<<64)-1]
    cases = []
    for n in [0, 1, 4095, 4096, 4097, 7000, 65536]:
        a = [(3<<32)+i for i in range(n)]
        b = [(3<<32)+i for i in range(0, min(65536, n+20), 2)]
        cases.append(dict(a=a+edge, b=b+edge[::2], remove=a[max(0,n-20):]+edge[::3]))
    for i in range(300):
        prefixes = [0, 1, 7, (1<<16)-1, 1<<31, (1<<32)-1]
        values = [((rng.choice(prefixes)<<32)|(rng.choice([0,1,65535])<<16)|rng.randrange(65536)) for _ in range(i%100)]
        a = values + edge[:i%13]
        b = values[::3] + [rng.randrange(1<<64) for _ in range(i%17)]
        cases.append(dict(a=a+a[::5], b=b, remove=values[::4]+edge[::2]))
    # Explicit array-left/bitmap-right dispatch and dense/dense intersections
    # small enough to change the result back into an array container.
    cases.append(dict(a=list(range(0,40,2)), b=list(range(7000)), remove=[0,2,39]))
    cases.append(dict(a=list(range(7000)), b=list(range(6500,14000)), remove=list(range(2904,7000))))
    masks = []
    # All raw selected/null overlap representations of a single row.
    for a in range(8):
        for b in range(8):
            masks.append(dict(a=dict(block=bool(a&4), selected=[0] if a&1 else [], nulls=[0] if a&2 else []),
                              b=dict(block=bool(b&4), selected=[0] if b&1 else [], nulls=[0] if b&2 else []), probe=edge))
    for _ in range(500):
        def mask():
            return dict(block=bool(rng.randrange(2)), selected=[v for v in edge if rng.randrange(2)], nulls=[v for v in edge if rng.randrange(2)])
        masks.append(dict(a=mask(), b=mask(), probe=edge))
    return dict(sets=cases, masks=masks)


def main():
    source=ROOT/"reference/lance"
    assert subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()==REVISION
    nullable=source/"rust/lance-select/src/mask/nullable.rs"
    assert nullable.read_bytes()==subprocess.check_output(["git","-C",str(source),"show",f"{REVISION}:rust/lance-select/src/mask/nullable.rs"])
    original=nullable.read_text().split("#[cfg(test)]")[0]
    adapted=original.replace("use lance_core::deepsize::DeepSizeOf;", "").replace(", DeepSizeOf)]", ")]")
    build=ROOT/".build/lance-rowset-reference";out=ROOT/"tests/fixtures/lance-rowset"
    (build/"src").mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    (build/"src/nullable.rs").write_text(adapted)
    shutil.copyfile(ROOT/"scripts/lance_rowset_reference.rs",build/"src/main.rs")
    (build/"Cargo.toml").write_text('[package]\nname="akasha-lance-rowset-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\nroaring="=0.11.4"\nserde_json="=1.0.151"\n[workspace]\n')
    (build/"inputs.json").write_text(json.dumps(inputs(),separators=(",",":")))
    if (out/"Cargo.lock").exists():
        shutil.copyfile(out/"Cargo.lock",build/"Cargo.lock")
    if not (build/"Cargo.lock").exists():
        subprocess.run(["cargo","generate-lockfile","--offline","--manifest-path",str(build/"Cargo.toml")],check=True)
    lock=tomllib.loads((build/"Cargo.lock").read_text())
    dependencies=[]
    for dep in lock["package"]:
        if "checksum" not in dep:continue
        name,version=dep["name"],dep["version"]
        directory=next((Path.home()/".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive=Path.home()/".cargo/registry/cache"/directory.parent.name/f"{name}-{version}.crate"
        assert sha(archive)==dep["checksum"]
        files=[]
        if name=="roaring":
            assert dep["checksum"]=="1dedc5658c6ecb3bdb5ef5f3295bb9253f42dcf3fd1402c03f6b1f7659c3c4a9"
            with tarfile.open(archive) as tar:
                for file in sorted((directory/"src").rglob("*.rs")):
                    rel=str(file.relative_to(directory))
                    assert file.read_bytes()==tar.extractfile(f"{name}-{version}/{rel}").read()
                    files.append(dict(path=rel,sha256=sha(file)))
                assert (directory/"LICENSE-APACHE").read_bytes()==tar.extractfile(f"{name}-{version}/LICENSE-APACHE").read()
            license=directory/"LICENSE-APACHE"
            shutil.copyfile(license,ROOT/"docs/upstream/licenses/roaring-Apache-2.0.txt")
        dependencies.append(dict(name=name,version=version,checksum=dep["checksum"],files=files))
    data=subprocess.check_output(["cargo","run","--release","--quiet","--locked","--offline","--manifest-path",str(build/"Cargo.toml"),"--",str(build/"inputs.json")],env={**os.environ,"CARGO_TARGET_DIR":str(ROOT/".build/lance-json-reference/target")})
    (out/"cases.json").write_bytes(data);shutil.copyfile(build/"Cargo.lock",out/"Cargo.lock")
    metadata=dict(lance_revision=REVISION,source=dict(path=str(nullable.relative_to(source)),sha256=sha(nullable)),
                  original_module_sha256=hashlib.sha256(original.encode()).hexdigest(),
                  adapted_module_sha256=hashlib.sha256(adapted.encode()).hexdigest(),
                  dependencies=dependencies,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/"scripts/lance_rowset_reference.rs"),
                  cases_sha256=sha(out/"cases.json"),lock_sha256=sha(out/"Cargo.lock"),
                  adapter="Remove only DeepSizeOf import/derive. Original nullable methods use a materialized-row adapter backed by actual roaring::RoaringTreemap; full-fragment selections and serialization are not claimed.",
                  rustc=subprocess.check_output(["rustc","-Vv"],text=True).strip())
    (out/"sources.json").write_text(json.dumps(metadata,indent=2)+"\n")
    values=json.loads(data);print('Original set cases',len(values['sets']),'nullable cases',len(values['masks']))


if __name__=="__main__":main()
