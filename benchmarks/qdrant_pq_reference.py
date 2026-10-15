"""Compare Akasha PQ centroids with unedited Qdrant serial kmeans methods.

The adapters provide serial Rayon and deterministic SplitMix64 empty-cluster
sampling. Upstream's training algorithm is inserted verbatim. Fixtures use the
whole training population (below Qdrant's 10,000-row sampling threshold).
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "21db2f3ff95d50de3a2b88a741312c056fd1762d"

SCAFFOLD = r'''
#![allow(dead_code)]
#[derive(Debug)] enum EncodingError { EncodingError(String), Stopped }
mod rayon {
    pub struct ThreadPool;
    impl ThreadPool { pub fn install<R>(&self, f: impl FnOnce() -> R) -> R { f() } }
    pub struct ThreadPoolBuilder;
    impl ThreadPoolBuilder {
        pub fn new() -> Self { Self }
        pub fn thread_name(self, _: impl Fn(usize) -> String) -> Self { self }
        pub fn num_threads(self, count: usize) -> Self { assert_eq!(count,1); self }
        pub fn build(self) -> Result<ThreadPool, String> { Ok(ThreadPool) }
    }
    pub mod prelude {
        pub trait ParallelMut<T> { fn par_iter_mut(&mut self) -> std::slice::IterMut<'_,T>; }
        impl<T> ParallelMut<T> for [T] {
            fn par_iter_mut(&mut self) -> std::slice::IterMut<'_,T> { self.iter_mut() }
        }
    }
}
mod rand {
    use std::sync::atomic::{AtomicU64,Ordering};
    static STATE: AtomicU64 = AtomicU64::new(1);
    pub fn reset() { STATE.store(1,Ordering::Relaxed); }
    fn next() -> u64 {
        let mut x=STATE.fetch_add(0x9e3779b97f4a7c15,Ordering::Relaxed).wrapping_add(0x9e3779b97f4a7c15);
        x=(x^(x>>30)).wrapping_mul(0xbf58476d1ce4e5b9);
        x=(x^(x>>27)).wrapping_mul(0x94d049bb133111eb); x^(x>>31)
    }
    pub struct Rng;
    pub fn rng() -> Rng { Rng }
    pub trait RngExt { fn random_range(&mut self, range: std::ops::Range<usize>) -> usize; }
    impl RngExt for Rng {
        fn random_range(&mut self, range: std::ops::Range<usize>) -> usize {
            assert_eq!(range.start,0); let bound=range.end as u64;
            let limit=u64::MAX-u64::MAX%bound;
            loop { let x=next(); if x<limit { return (x%bound) as usize; } }
        }
    }
}
mod upstream {
use crate::{rand,rayon};
__SOURCE__
}
fn run(case_id:usize, rows:Vec<Vec<f32>>, subquantizers:usize, count:usize, iterations:usize) {
    rand::reset();
    let dim=rows[0].len()/subquantizers;
    for sub in 0..subquantizers {
        let data:Vec<f32>=rows.iter().flat_map(|v|v[sub*dim..(sub+1)*dim].iter().copied()).collect();
        let values=upstream::kmeans(&data,count,dim,iterations,1,1e-5,
            &std::sync::atomic::AtomicBool::new(false)).unwrap();
        for centroid in 0..count { for offset in 0..dim {
            println!("{} {} {} {} {}",case_id,sub,centroid,offset,values[centroid*dim+offset].to_bits());
        }}
    }
}
fn main() { __CASES__ }
'''


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    source_path = ROOT / "reference/qdrant-edge-0.8.0/lib/quantization/src/kmeans.rs"
    source = source_path.read_text()
    fixtures = []
    for dimension in [2, 4, 8]:
        for subquantizers in [1, 2]:
            for centroids in [1, 2, 4]:
                fixtures.append(dict(vectors=[
                    [((row*17+col*7)%29-14)*0.25+(row%3)*0.125
                     for col in range(dimension)] for row in range(32)],
                    subquantizers=subquantizers, centroids=centroids, iterations=12))
    fixtures.extend([
        dict(vectors=[[100_000_000.0], [1.0], [-100_000_000.0]],
             subquantizers=1, centroids=1, iterations=3),
        dict(vectors=[[0.,0.], [0.,0.], [10.,10.], [10.,10.]],
             subquantizers=2, centroids=2, iterations=8),
    ])
    fixture_path = args.output / "fixtures.json"
    fixture_path.write_text(json.dumps(fixtures, indent=2)+"\n")
    calls=[]
    for i, fixture in enumerate(fixtures):
        vectors=",".join("vec!["+",".join(f"{float(x)!r}f32" for x in row)+"]"
                         for row in fixture["vectors"])
        calls.append(f"run({i},vec![{vectors}],{fixture['subquantizers']},{fixture['centroids']},{fixture['iterations']});")
    rust = args.output / "reference.rs"
    rust.write_text(SCAFFOLD.replace("__SOURCE__",source).replace("__CASES__","\n".join(calls)))
    rust_binary = args.output / "reference"
    subprocess.run(["rtk","proxy","rustc","--edition=2021",str(rust),"-o",str(rust_binary)],check=True)
    expected=subprocess.check_output([str(rust_binary)],text=True)
    (args.output/"reference.log").write_text(expected)
    mojo_binary = args.output / "akasha"
    subprocess.run(["rtk","proxy","pixi","run","mojo","build","-I","src",
                    "benchmarks/mojo/qdrant_pq_differential.mojo","-o",str(mojo_binary)],cwd=ROOT,check=True)
    actual=subprocess.check_output([str(mojo_binary),str(fixture_path)],text=True)
    (args.output/"akasha.log").write_text(actual)
    def parse(raw):
        result={}
        for line in raw.splitlines():
            i,sub,centroid,offset,bits=map(int,line.split())
            result.setdefault(i,[]).append((sub,centroid,offset,bits))
        return result
    expected_rows,actual_rows=parse(expected),parse(actual)
    results=[dict(case=i,passed=actual_rows.get(i)==expected_rows[i]) for i in range(len(fixtures))]
    report=dict(upstream_revision=REVISION,source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        adapter_sha256=hashlib.sha256(rust.read_bytes()).hexdigest(),
        implementation_sha256=hashlib.sha256((ROOT/"src/akasha/index/quantization.mojo").read_bytes()).hexdigest(),
        cases=results,passed=sum(r["passed"] for r in results),total=len(results),
        adaptations=["serial one-thread reduction", "deterministic SplitMix64 instead of upstream thread RNG",
                     "fixtures below 10000 rows; no sample selection", "explicit Akasha centroid/iteration parameters"])
    (args.output/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"{report['passed']}/{report['total']} centroid fixtures passed")
    return 0 if report["passed"]==report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
