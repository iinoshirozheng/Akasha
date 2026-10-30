"""Original Qdrant/GeoRust polygon and robust orientation execution oracles."""
from __future__ import annotations

import hashlib
import itertools
import json
import math
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tarfile
import tomllib

from qdrant_dbsf_reference import extract
from qdrant_payload_filter_reference import ROOT, main as filter_reference


TARGET = ROOT / "tests/fixtures/qdrant-polygon"
BUILD = ROOT / ".build/robust-orientation-reference"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def dependency(name, version, paths):
    registry = Path.home() / ".cargo/registry"
    archive = next((registry / "cache").glob(f"*/{name}-{version}.crate"))
    locked = tomllib.loads((ROOT / "reference/qdrant/Cargo.lock").read_text())
    package = next(p for p in locked["package"] if p["name"] == name and p["version"] == version)
    assert digest(archive.read_bytes()) == package["checksum"]
    directory = next((registry / "src").glob(f"*/{name}-{version}"))
    with tarfile.open(archive) as tar:
        for path in paths:
            assert tar.extractfile(f"{name}-{version}/{path}").read() == (directory/path).read_bytes()
    revision = json.loads((directory / ".cargo_vcs_info.json").read_text())["git"]["sha1"]
    return directory, dict(name=name, version=version, revision=revision,
        crate_sha256=package["checksum"], sources={p:digest((directory/p).read_bytes()) for p in paths})


def polygon_cases():
    point = lambda x,y:dict(lon=x,lat=y)
    ring = lambda coordinates:dict(points=[point(*p) for p in coordinates])
    square = [(-4,-4),(4,-4),(4,4),(-4,4),(-4,-4)]
    hole = [(-1,-1),(1,-1),(1,1),(-1,1),(-1,-1)]
    polygon = lambda exterior, *holes:dict(exterior=ring(exterior),interiors=[ring(h) for h in holes])
    shapes = [polygon(square), polygon(square,hole), polygon(square,hole,hole),
        polygon(square,[(2,2),(6,2),(6,6),(2,6),(2,2)]),
        polygon(square,[(10,10),(11,10),(11,11),(10,11),(10,10)]),
        polygon([(0,0),(4,0),(4,1),(1,1),(1,4),(0,4),(0,0)]),
        polygon([(-4,-4),(4,4),(-4,4),(4,-4),(-4,-4)]),
        polygon([(0,0)]*4), polygon([(0,0),(1,1),(2,2),(0,0)]),
        polygon([(170,-10),(-170,-10),(-170,10),(170,10),(170,-10)]),
        polygon([(-180,-90),(180,-90),(180,90),(-180,90),(-180,-90)]),
        polygon([(0,0),(1,0),(0,1),(2**-52,0)]),
        polygon([(0,0),(1,0),(0,1),(0,2**-52)]),
        polygon([(0,0),(1,1),(2,math.nextafter(2,math.inf)),(0,0)]),
        polygon([(2**-54,2**-54),(2,2),(2,0),(2**-54,2**-54)]),
        polygon([(2**-54,math.nextafter(2**-54,math.inf)),(2,2),(2,0),(2**-54,math.nextafter(2**-54,math.inf))]),
        polygon([(2**-54,math.nextafter(2**-54,-math.inf)),(2,2),(2,0),(2**-54,math.nextafter(2**-54,-math.inf))])]
    reversed_shapes=[]
    for shape in shapes:
        reversed_shapes.append(dict(exterior={"points":shape["exterior"]["points"][::-1]},
            interiors=[{"points":h["points"][::-1]} for h in shape["interiors"]]))
    shapes += reversed_shapes
    values=[point(x,y) for x,y in itertools.product([-5,-4,-1,0,1,2,4,5],repeat=2)]
    values += [None,True,"0",[0,0],{"lon":0},{"lat":0},point(True,0),point("0",0),
        point(None,0),point(0,181),point(181,0),point(1e308,0),point(-1e308,0)]
    rng = random.Random(2026103001)
    values += [point(rng.randint(-1440,1440)/8,rng.randint(-720,720)/8) for _ in range(100)]
    for shape in shapes[:17]:
        for p in shape["exterior"]["points"]:
            for delta in [-math.inf,math.inf]:
                values += [point(math.nextafter(p["lon"],delta),p["lat"]),
                           point(p["lon"],math.nextafter(p["lat"],delta))]
    cases=[]
    def add(payload,shape,**extra):
        cases.append(dict(payload=payload,filter=dict(kind="field",key="a",geo_polygon=shape,**extra)))
    for shape in shapes:
        for value in values:
            add({"a":value},shape)
        for value in [point(0,0),point(2,2),point(4,4),[point(2,2)],None]:
            add({"a":[None,value]},shape)
        add({},shape)
    # Validation accepts unknown serde fields and struct sequence forms.
    good=polygon(square,hole)
    variants=[dict(exterior=good["exterior"]),dict(exterior=good["exterior"],interiors=None),
        dict(good,ignored=True),[good["exterior"]],[good["exterior"],good["interiors"]],
        dict(exterior=[[[p["lon"],p["lat"]] for p in good["exterior"]["points"]]])]
    for shape in variants:
        for value in [point(0,0),point(2,2),point(4,4)]: add({"a":value},shape)
    for bad in [{},None,False,[],[good["exterior"],[],0],dict(exterior={}),
        dict(exterior={"points":None}),dict(exterior={"points":[]}),
        polygon([(0,0),(1,0),(0,0)]),polygon([(0,0),(1,0),(0,1),(2**-51,0)]),
        polygon([(0,0),(181,0),(0,1),(0,0)]),polygon([(0,0),(0,91),(0,1),(0,0)]),
        dict(exterior=good["exterior"],interiors={}),dict(exterior=good["exterior"],interiors=[None]),
        dict(exterior=good["exterior"],interiors=[ring([(0,0)]*3)]),
        dict(exterior={"points":[point(False,0)]*4}),dict(exterior=[[],[]])]:
        if bad is not None: add({"a":point(2,2)},bad)
    # Composite field precedence and scoped nested conditions.
    for extra in [dict(match={"value":"yes"}),dict(range={"gt":0}),
        dict(is_empty=False),dict(is_null=True),dict(values_count={"gte":0}),
        dict(geo_bounding_box={"top_left":point(20,30),"bottom_right":point(30,20)}),
        dict(geo_radius={"center":point(25,25),"radius":10})]:
        for value in [point(2,2),point(0,0),point(25,25),"yes",2,None,[],[None,point(2,2)]]:
            add({"a":value},good,**extra)
    nested=dict(kind="nested",key="items",filter=dict(kind="all",children=[
        dict(kind="field",key="a",geo_polygon=good),dict(kind="field",key="active",match={"value":True})]))
    for items in [[{"a":point(2,2),"active":False},{"a":point(0,0),"active":True}],
                  [{"a":point(2,2),"active":True}],[],None]:
        cases.append(dict(payload={"items":items},filter=nested))
    return cases


def orientation_reference(robust_dir):
    (BUILD/"src").mkdir(parents=True,exist_ok=True)
    source=(robust_dir/"src/lib.rs").read_text()
    # Separate tracing copy proves every adaptive exit is exercised. Actual
    # expected bits always come from the unmodified published robust crate.
    traced='#![allow(dead_code,unused_parens)]\n' + '\n'.join(
        line for line in source.splitlines()
        if not line.startswith('#![cfg_attr(') and not line.startswith('#![doc(')) + '\n'
    adapted=extract(source,"fn orient2dadapt(")
    for stage in [1,2,3]:
        adapted=adapted.replace("return det;",f"STAGE.store({stage},std::sync::atomic::Ordering::Relaxed); return det;",1)
        # Protect already-replaced returns from the next replacement.
        adapted=adapted.replace("return det;","return (det);",1)
    adapted=adapted.replace("D[dlength - 1]","{ STAGE.store(4,std::sync::atomic::Ordering::Relaxed); D[dlength - 1] }")
    traced=traced.replace(extract(source,"fn orient2dadapt("),adapted)
    traced += '\npub static STAGE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);\n'
    (BUILD/"src/traced.rs").write_text(traced)
    code=r'''
mod traced;
use serde_json::{Value,json};
fn main() {
 let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
 let mut coverage=[0usize;5];
 let cases:Vec<Value>=input.as_array().unwrap().iter().map(|row| {
  let b:Vec<u64>=row.as_array().unwrap().iter().map(|v|v.as_u64().unwrap()).collect();
  let v:Vec<f64>=b.iter().map(|x|f64::from_bits(*x)).collect();
  let expected=robust::orient2d(robust::Coord{x:v[0],y:v[1]},robust::Coord{x:v[2],y:v[3]},robust::Coord{x:v[4],y:v[5]});
  traced::STAGE.store(0,std::sync::atomic::Ordering::Relaxed);
  let actual=traced::orient2d(traced::Coord{x:v[0],y:v[1]},traced::Coord{x:v[2],y:v[3]},traced::Coord{x:v[4],y:v[5]});
  assert_eq!(expected.to_bits(),actual.to_bits());
  let stage=traced::STAGE.load(std::sync::atomic::Ordering::Relaxed);
  coverage[stage]+=1;
  json!({"input_bits":b,"output_bits":expected.to_bits(),"stage":stage})
 }).collect();
 println!("{}",json!({"cases":cases,"coverage":coverage}));
}
'''
    (BUILD/"src/main.rs").write_text(code)
    (BUILD/"Cargo.toml").write_text('''[package]
name="akasha-robust-reference"
version="0.1.0"
edition="2024"
[dependencies]
robust="=1.2.0"
serde_json="=1.0.151"
[workspace]
''')
    rows=[[float(v) for v in line.split()[1:7]] for line in (robust_dir/"fixtures/orient2d.txt").read_text().splitlines() if line.strip()]
    rng=random.Random(2026103002)
    for _ in range(6000):
        a=[rng.uniform(-180,180),rng.uniform(-90,90)]
        b=[rng.uniform(-180,180),rng.uniform(-90,90)]
        t=rng.uniform(-2,2)
        c=[a[i]+t*(b[i]-a[i]) for i in range(2)]
        for i in range(2):
            for direction in [-math.inf,math.inf]:
                point=c.copy();point[i]=math.nextafter(point[i],direction)
                rows.append(a+b+point)
        rows.append(a+b+c)
    for exponent in [-530,-500,-100,-50,0,50,100,500]:
        scale=2.0**exponent
        for offsets in itertools.product([-1,0,1],repeat=2):
            a=[scale,scale];b=[2*scale,2*scale];c=[3*scale,3*scale]
            for i,offset in enumerate(offsets):
                if offset:c[i]=math.nextafter(c[i],math.inf if offset>0 else -math.inf)
            rows.extend([a+b+c,c+b+a])
    rows += [[0.,0.,0.,0.,0.,0.],[-0.,0.,0.,-0.,0.,0.],[0.,0.,1.,0.,0.,1.]]
    for exponent in [-500,-50,0,50,500]:
        scale=2.0**exponent
        rows += [[scale,scale,2*scale,2*scale,scale*2**-54,scale*2**-54],
                 [scale*2**-54,scale*2**-54,2*scale,2*scale,scale,scale]]
        for direction in [-math.inf,math.inf]:
            rows.append([scale*2**-54,math.nextafter(scale*2**-54,direction),2*scale,2*scale,scale,scale])
    bits=lambda n:struct.unpack('<Q',struct.pack('<d',n))[0]
    (BUILD/"input.json").write_text(json.dumps([[bits(v) for v in row] for row in rows]))
    lock=TARGET/"orientation-Cargo.lock"
    if lock.exists():shutil.copyfile(lock,BUILD/"Cargo.lock")
    else:subprocess.run(['rtk','proxy','cargo','generate-lockfile','--offline','--manifest-path',str(BUILD/'Cargo.toml')],check=True)
    subprocess.run(['rtk','proxy','cargo','build','--offline','--locked','--release','--manifest-path',str(BUILD/'Cargo.toml')],check=True)
    shutil.copyfile(BUILD/"Cargo.lock",lock)
    result=json.loads(subprocess.check_output([str(BUILD/'target/release/akasha-robust-reference'),str(BUILD/'input.json')],text=True))
    assert all(result["coverage"]),result["coverage"]
    result.update(scaffold_sha256=digest(code.encode()),traced_sha256=digest(traced.encode()),
        cargo_lock_sha256=digest(lock.read_bytes()),source_fixture_sha256=digest((robust_dir/'fixtures/orient2d.txt').read_bytes()))
    cases=result.pop('cases')
    text=json.dumps(result,indent=2)[:-2]+',\n  "cases": [\n'
    text+=',\n'.join('    '+json.dumps(row,separators=(',',':')) for row in cases)+'\n  ]\n}\n'
    (TARGET/'orientation.json').write_text(text)
    print('orientation cases',len(rows),'adaptive stage coverage',result['coverage'])


def main():
    TARGET.mkdir(parents=True,exist_ok=True)
    dependencies=[]
    units={
        'geo':{'src/algorithm/coordinate_position.rs':['impl<T> CoordinatePosition for Polygon<T>','pub fn coord_pos_relative_to_ring<T>'],
            'src/algorithm/contains/polygon.rs':['impl<T> Contains<Coord<T>>','impl<T> Contains<Point<T>>'],
            'src/algorithm/kernels/robust.rs':['fn orient2d('],
            'src/algorithm/intersects/mod.rs':['pub(crate) fn value_in_between','fn value_in_range']},
        'geo-types':{'src/geometry/polygon.rs':['pub fn new('],
                     'src/geometry/line_string.rs':['pub fn close(', 'pub fn is_closed(']},
        'robust':{'src/lib.rs':['pub fn orient2d<','fn orient2dadapt(']+['fn '+name+'(' for name in [
            'two_product','two_product_tail','split','two_sum','two_sum_tail','fast_two_sum',
            'fast_two_sum_tail','two_diff','two_diff_tail','two_one_diff','two_two_diff',
            'estimate','fast_expansion_sum_zeroelim']]}}
    for name,version,paths in [
        ('geo','0.33.1',['src/algorithm/coordinate_position.rs','src/algorithm/contains/polygon.rs','src/algorithm/kernels/robust.rs','src/algorithm/intersects/mod.rs']),
        ('geo-types','0.7.19',['src/geometry/polygon.rs','src/geometry/line_string.rs']),
        ('robust','1.2.0',['src/lib.rs','fixtures/orient2d.txt','LICENSE-MIT'])]:
        directory,meta=dependency(name,version,paths)
        meta['units']={path:{sig:digest(extract((directory/path).read_text(),sig).encode())
            for sig in signatures} for path,signatures in units[name].items()}
        meta['license']='MIT OR Apache-2.0'
        meta['license_file']='docs/upstream/licenses/'+('robust-MIT.txt' if name=='robust' else 'geo-MIT.txt')
        meta['license_sha256']=digest((ROOT/meta['license_file']).read_bytes())
        if name=='geo-types':
            meta['license_source']='https://raw.githubusercontent.com/georust/geo/981be9feea12cdede572fb252064536cb8b287b1/LICENSE-MIT'
        dependencies.append(meta)
        if name=='robust':robust_dir=directory
    (TARGET/'dependencies.json').write_text(json.dumps(dependencies,indent=2)+'\n')
    if not (TARGET/'Cargo.lock').exists():
        shutil.copyfile(ROOT/'tests/fixtures/qdrant-payload-filter/Cargo.lock',TARGET/'Cargo.lock')
    filter_reference(cases_override=polygon_cases(),fixture_name='qdrant-polygon')
    orientation_reference(robust_dir)


if __name__=='__main__':
    main()
