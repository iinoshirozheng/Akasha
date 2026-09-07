"""Paired CPU/resident/cold GPU measurements; no universal hardware thresholds."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def percentile(values: list[int], p: float) -> int:
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/post-hnsw/crossover')
    parser.add_argument('--samples', type=int, default=31)
    args = parser.parse_args()
    if args.samples < 20:
        parser.error('at least 20 paired samples are required')
    args.output.mkdir(parents=True, exist_ok=True)
    binary = (args.binary or args.output / 'gpu-bench').resolve()
    if not args.binary:
        subprocess.run(['pixi', 'run', 'mojo', 'build', '-I', 'src', '-I', 'benchmarks/mojo', 'benchmarks/mojo/gpu_pipeline_bench.mojo', '-o', str(binary)], cwd=ROOT, check=True)
    report = {'host': platform.platform(), 'machine': platform.machine(),
              'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'samples': args.samples,
              'warmups': 3, 'scope': 'identical immutable F32 data, exact CPU with automatic threads versus explicit actual GPU; snapshot capture excluded; cold includes context/allocation/vector upload',
              'cells': []}
    for metric in [0, 1, 2]:
        for n, d, b in [(2000, 32, 1), (8192, 384, 1), (8192, 384, 32), (32768, 768, 32), (32768, 768, 128)]:
            log = args.output / f'{metric}-{n}-{d}-{b}.log'
            with log.open('w') as stream:
                result = subprocess.run([str(binary), str(n), str(d), str(b), str(args.samples), str(metric)], stdout=stream, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f'differential/actual-device gate failed: {log}')
            rows = [dict(x.split('=', 1) for x in line.split()[1:]) for line in log.read_text().splitlines() if line.startswith('sample ')]
            if len(rows) != args.samples:
                raise RuntimeError('missing paired samples')
            cell = {'points': n, 'dimension': d, 'batch': b, 'metric': metric}
            for key in ['cpu_ns', 'resident_gpu_ns', 'cold_gpu_ns']:
                values = [int(row[key]) for row in rows]
                cell[key] = {'p50': percentile(values, .5), 'p95': percentile(values, .95),
                             'throughput_qps_at_p50': b * 1e9 / percentile(values, .5),
                             'amortized_ns_per_query_at_p50': percentile(values, .5) / b}
            for key in ['resident_gpu_ns', 'cold_gpu_ns']:
                ratios = [int(row['cpu_ns']) / int(row[key]) for row in rows]
                wins = sum(ratio > 1 for ratio in ratios)
                cell[key]['paired_wins'] = wins
                cell[key]['measured_gpu_benefit'] = wins >= math.ceil(.9 * len(rows)) and cell[key]['p95'] < cell['cpu_ns']['p50']
            report['cells'].append(cell)
            (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            print(f'metric={metric} n={n} d={d} b={b} cpu_ms={cell["cpu_ns"]["p50"]/1e6:.3f} resident_ms={cell["resident_gpu_ns"]["p50"]/1e6:.3f} cold_ms={cell["cold_gpu_ns"]["p50"]/1e6:.3f}', flush=True)


if __name__ == '__main__':
    main()
