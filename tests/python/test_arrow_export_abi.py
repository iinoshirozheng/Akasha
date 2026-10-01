import subprocess
from pathlib import Path

import pyarrow as pa


ROOT = Path(__file__).resolve().parents[2]


def test_arrow_array_layout_matches_installed_official_c_header(tmp_path):
    native = tmp_path / "arrow_abi"
    subprocess.run([
        "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", pa.get_include(),
        str(ROOT / "tests/c/arrow_array_abi_probe.c"), "-o", str(native),
    ], check=True)
    source = tmp_path / "arrow_abi.mojo"
    source.write_text('''
from bindings.arrow_export import ARROW_ARRAY_SIZE, ARROW_ARRAY_RELEASE_OFFSET, ARROW_ARRAY_PRIVATE_OFFSET, _release_array
from std.sys.info import size_of, align_of

def main():
    print("size=" + String(ARROW_ARRAY_SIZE))
    print("release=" + String(ARROW_ARRAY_RELEASE_OFFSET))
    print("private=" + String(ARROW_ARRAY_PRIVATE_OFFSET))
    print("pointer_size=" + String(size_of[OpaquePointer[MutUntrackedOrigin]]()))
    print("function_size=" + String(size_of[type_of(_release_array)]()))
    print("alignment=" + String(align_of[Int64]()))
''')
    expected = subprocess.check_output([str(native)], text=True)
    actual = subprocess.check_output([
        "mojo", "run", "-I", str(ROOT / "src"), str(source)
    ], text=True, cwd=ROOT)
    assert actual == expected
