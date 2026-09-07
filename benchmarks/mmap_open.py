"""Cold/warm mmap stages and per-process peak RSS; verify page residency."""
from __future__ import annotations
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def resident_fraction(path: Path) -> float:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.restype = ctypes.c_void_p
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong]
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    size = path.stat().st_size
    pages = (size + os.sysconf('SC_PAGE_SIZE') - 1) // os.sysconf('SC_PAGE_SIZE')
    with path.open('rb') as stream:
        address = libc.mmap(None, size, 1, 2, stream.fileno(), 0)
        if address == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_errno(), 'mmap for mincore')
        try:
            vec = (ctypes.c_ubyte * pages)()
            if libc.mincore(address, size, vec):
                raise OSError(ctypes.get_errno(), 'mincore')
            return sum(bool(v & 1) for v in vec) / pages
        finally:
            libc.munmap(address, size)


def run(binary: Path, fixture: Path, points: int, dimension: int, repetitions: int, log: Path) -> dict:
    with log.open('w') as output:
        proc = subprocess.Popen([str(binary), 'open', str(fixture), str(points), str(dimension), str(repetitions)], stdout=output, stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(proc.pid, 0)
        proc.returncode = os.waitstatus_to_exitcode(status)
    if proc.returncode:
        raise RuntimeError(log.read_text())
    rows = [dict(field.split('=') for field in line.split()[1:]) for line in log.read_text().splitlines() if line.startswith('open ')]
    return {'samples': [{key: int(value) for key, value in row.items()} for row in rows],
            'peak_rss_bytes': int(usage.ru_maxrss * (1 if sys.platform == 'darwin' else 1024)),
            'major_faults': usage.ru_majflt, 'minor_faults': usage.ru_minflt}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/post-hnsw/mmap-results')
    parser.add_argument('--points', type=int, default=32768)
    parser.add_argument('--dimension', type=int, default=384)
    parser.add_argument('--trials', type=int, default=7)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    binary = (args.binary or args.output / 'mmap-bench').resolve()
    if args.binary is None:
        subprocess.run(['pixi', 'run', 'mojo', 'build', '-I', 'src', 'benchmarks/mojo/mmap_open_bench.mojo', '-o', str(binary)], cwd=ROOT, check=True)
    fixture = args.output.resolve() / 'fixture.bin'
    subprocess.run([str(binary), 'prepare', str(fixture), str(args.points), str(args.dimension), '1'], check=True)
    report = {'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'git_diff': subprocess.check_output(['git', 'diff'], cwd=ROOT, text=True),
              'points': args.points, 'dimension': args.dimension, 'fixture_bytes': fixture.stat().st_size,
              'cold_method': 'uncached copy writes on macOS; fsync and POSIX_FADV_DONTNEED on Linux; mincore before open',
              'rss_scope': 'entire open-only child process, including runtime, mapped resident pages and validation scratch; excludes fixture construction',
              'trials': []}
    for trial in range(args.trials):
        with tempfile.TemporaryDirectory(prefix='akasha-mmap-') as directory:
            candidate = Path(directory) / 'cold.bin'
            with fixture.open('rb') as source, candidate.open('wb') as target:
                if sys.platform == 'darwin':
                    fcntl.fcntl(target.fileno(), fcntl.F_NOCACHE, 1)
                shutil.copyfileobj(source, target, 1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
                if hasattr(os, 'posix_fadvise'):
                    os.posix_fadvise(target.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
            residency = resident_fraction(candidate)
            cold = run(binary, candidate, args.points, args.dimension, 1, args.output / f'cold-{trial}.log')
            warm_residency = resident_fraction(candidate)
            warm = run(binary, candidate, args.points, args.dimension, 3, args.output / f'warm-{trial}.log')
            report['trials'].append({'cold_resident_fraction': residency, 'warm_resident_fraction': warm_residency, 'cold': cold, 'warm': warm})
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'trial={trial} initial_resident={residency:.3f} warm_resident={warm_residency:.3f} cold_rss={cold["peak_rss_bytes"]} warm_rss={warm["peak_rss_bytes"]}', flush=True)
    fixture.unlink()


if __name__ == '__main__':
    main()
