"""Compile original Qdrant GeoPoint/retrieval/scoring with its pinned geo crate."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import random
import subprocess

from qdrant_dbsf_reference import extract
import qdrant_formula_payload_reference as payload_reference

ROOT = Path(__file__).resolve().parents[1]
GEO_REVISION = '5ab50b072e34a915a33eaa46c80763d51d61295e'
GEO_CHECKSUM = '30eb1fdc57c1e5cfd11826fe0caec4b9dc7901f3758263bb506228d88c8d9e9a'
GEO_PATH = 'src/algorithm/line_measures/metric_spaces/haversine.rs'


def main():
    # Rebuild the source scaffold reproducibly; never require a stale .build file.
    payload_reference.main()
    base = ROOT / '.build/qdrant-formula-payload-reference/src/main.rs'
    build = ROOT / '.build/qdrant-geo-reference'
    target = ROOT / 'tests/fixtures/qdrant-geo'
    (build/'src').mkdir(parents=True,exist_ok=True)
    target.mkdir(parents=True,exist_ok=True)
    metadata = json.loads((ROOT/'tests/fixtures/qdrant-formula-payload/formula.json').read_text())
    sources = metadata['sources'].copy()
    units = metadata['units'].copy()
    def source(path):
        text = subprocess.check_output(['rtk','proxy','git','-C',str(ROOT/'reference/qdrant'),
            'show',f'{payload_reference.REVISION}:{path}'],text=True)
        sources[path] = hashlib.sha256(text.encode()).hexdigest()
        return text
    def unit(text,signature):
        body=extract(text,signature)
        units[signature]=hashlib.sha256(body.encode()).hexdigest()
        return body
    types=source('lib/segment/src/types.rs')
    source('Cargo.lock')
    source('lib/shard/src/query/formula.rs')
    source('lib/api/src/rest/schema.rs')
    cache = Path.home()/'.cargo/registry'
    crate=next(cache.glob('cache/*/geo-0.33.1.crate'))
    assert hashlib.sha256(crate.read_bytes()).hexdigest()==GEO_CHECKSUM
    geo=next(cache.glob('src/*/geo-0.33.1'))
    # Verify extracted source against the registry archive, not its mutable cache.
    import tarfile
    with tarfile.open(crate) as archive:
        geo_source=archive.extractfile('geo-0.33.1/'+GEO_PATH).read()
    assert (geo/GEO_PATH).read_bytes()==geo_source
    code=base.read_text()
    code=code.replace('#[derive(Clone,Debug)] struct OrderedFloat<T>(T);',
                      '#[derive(Clone,Copy,Debug)] struct OrderedFloat<T>(T);')
    geo_type='#[derive(Clone,Copy,Debug,serde::Deserialize)]\n#[serde(try_from="GeoPointShadow")]\n'
    geo_type+=unit(types,'pub struct GeoPoint {')+'\n'
    geo_type+='#[derive(serde::Deserialize)]\n'+unit(types,'struct GeoPointShadow {')+'\n'
    geo_type+='#[derive(Debug)]\n'+unit(types,'pub struct GeoPointValidationError {')+'\n'
    for sig in ('impl std::fmt::Display for GeoPointValidationError {','impl GeoPoint {',
                'impl TryFrom<GeoPointShadow> for GeoPoint {','impl From<GeoPoint> for geo::Point {'):
        geo_type+=unit(types,sig)+'\n'
    code=code.replace('#[derive(Clone,Copy,Debug,serde::Deserialize)] struct GeoPoint;',geo_type)
    code=code.replace('struct Haversine;\nimpl Haversine {fn distance(&self,_:GeoPoint,_:GeoPoint)->f64 {panic!("geo outside scalar oracle")}}',
                      'use geo::{Haversine,Distance};')
    code=code.replace('match kind.as_str() {', '''match kind.as_str() {
        "geo_distance"=>{
            let key:JsonPath=arg["to"].as_str().unwrap().parse().unwrap();
            vars.push(key.clone());
            ParsedExpression::GeoDistance{origin:serde_json::from_value(arg["origin"].clone()).unwrap(),key}
        },
        "exp_decay"=>ParsedExpression::Decay{kind:DecayKind::Exp,x:Box::new(expression(&arg["x"],vars)),
            target:None,lambda:OrderedFloat(0.5f64.ln()/arg["scale"].as_f64().unwrap())},''')
    # Extend input/output transport only; the scorer above stays unchanged.
    code=code.replace('fn main() {','fn formula_main(input:&Value)->Vec<Value> {')
    read_input='    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();\n'
    assert read_input in code
    code=code.replace(read_input,'')
    code=code.replace('    println!("{}",json!(output));','    output')
    code+=r'''
fn main() {
    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let points:Vec<_>=input["points"].as_array().unwrap().iter().map(|v| {
        match serde_json::from_value::<GeoPoint>(v.clone()) {
            Ok(p)=>json!({"input":v,"point":[p.lon.0,p.lat.0]}),
            Err(e)=>json!({"input":v,"error":e.to_string()})
        }
    }).collect();
    let distances:Vec<_>=input["distances"].as_array().unwrap().iter().map(|v| {
        let a:GeoPoint=serde_json::from_value(v[0].clone()).unwrap();
        let b:GeoPoint=serde_json::from_value(v[1].clone()).unwrap();
        let d=Haversine.distance(a.into(),b.into());
        json!({"from":v[0],"to":v[1],"bits":d.to_bits(),"finite":d.is_finite()})
    }).collect();
    println!("{}",json!({"points":points,"distances":distances,"formulas":formula_main(&input["formulas"])}));
}
'''
    (build/'src/main.rs').write_text(code)
    (build/'src/parse.rs').write_bytes((base.parent/'parse.rs').read_bytes())
    (build/'Cargo.toml').write_text('[package]\nname="akasha-geo-reference"\nversion="0.1.0"\nedition="2024"\n'
        '[dependencies]\nnom="=8.0.0"\nserde={version="=1.0.228",features=["derive"]}\n'
        'serde_json={version="=1.0.151",features=["preserve_order"]}\ngeo="=0.33.1"\n[workspace]\n')
    def point(lon,lat): return {'lon':lon,'lat':lat}
    values=[None,False,True,'0',0,[],[0],[0,0],[0,0,0],['0',0],[False,0],
        {},{'lon':0},{'lat':0},point(0,0),point(-0.0,-0.0),point(180,90),point(-180,-90),
        point(181,0),point(0,91),point(-181,0),point(0,-91),point('0',0),point(True,0),
        point(None,0),point(0,2**64-1),dict(point(0,0),ignored={'any':[1,None]}),
        point(math.nextafter(180,math.inf),0),point(0,math.nextafter(90,math.inf)),
        point(math.nextafter(180,0),math.nextafter(90,0))]
    anchors=[point(0,0),point(-0.0,-0.0),point(180,90),point(-180,-90),point(180,0),
        point(-180,0),point(0,90),point(0,-90),point(121.5654,25.033),point(-74.006,40.7128),
        point(-0.1278,51.5074),point(179.9999,0),point(-179.9999,0),point(1e-12,1e-12)]
    distances=[[a,b] for a in anchors for b in anchors]
    rng=random.Random(20261030)
    for _ in range(300):
        a=point(rng.uniform(-180,180),rng.uniform(-90,90))
        b=point(rng.uniform(-180,180),rng.uniform(-90,90))
        distances.append([a,b])
        # Source rounding near antipodes is intentionally retained, including NaNs.
        lon=a['lon']+180 if a['lon']<=0 else a['lon']-180
        distances.append([a,point(lon,-a['lat'])])
    def expression(origin=point(0,0),to='location'):
        return {'geo_distance':{'origin':origin,'to':to}}
    formulas=[]
    for a,b in distances:
        formulas.append(dict(expression=expression(a),payload={'location':b},defaults={}))
    for value in values+[[],[point(1,2)],[point(1,2),point(3,4)],[None,point(1,2)],[[point(1,2)]]]:
        for path,payload in [('location',{'location':value}),('meta[].location',{'meta':[{'location':value}]}),
                             ('location[]',{'location':value})]:
            for defaults in ({},{path:point(1,2)}):
                formulas.append(dict(expression=expression(to=path),payload=payload,defaults=defaults))
        formulas.append(dict(expression=expression(),payload={},defaults={'location':value}))
    for origin in (point(1,2),[1,2],dict(point(1,2),extra='ignored')):
        formulas.append(dict(expression=expression(origin),payload={'location':point(0,0)},defaults={}))
    for expr in ({'mult':[0,expression()]},{'mult':[expression(),0]},
                 {'div':{'left':0,'right':expression()}},{'neg':expression()},
                 {'sum':['$score',{'exp_decay':{'x':expression(),'scale':1000000}}]}):
        for value in (None,point(121.5654,25.033),[point(0,0)],'wrong'):
            formulas.append(dict(expression=expr,payload={'location':value},defaults={}))
    (build/'input.json').write_text(json.dumps(dict(points=values,distances=distances,formulas=formulas)))
    lock=target/'Cargo.lock'
    if lock.exists():
        (build/'Cargo.lock').write_bytes(lock.read_bytes())
    else:
        subprocess.run(['rtk','proxy','cargo','generate-lockfile','--offline','--manifest-path',str(build/'Cargo.toml')],check=True)
    subprocess.run(['rtk','proxy','cargo','build','--offline','--locked','--release','--manifest-path',str(build/'Cargo.toml')],check=True)
    lock.write_bytes((build/'Cargo.lock').read_bytes())
    output=json.loads(subprocess.check_output([str(build/'target/release/akasha-geo-reference'),str(build/'input.json')],text=True))
    meta=dict(revision=payload_reference.REVISION,sources=sources,units=units,
        geo=dict(version='0.33.1',revision=GEO_REVISION,crate_sha256=GEO_CHECKSUM,source=GEO_PATH,
            source_sha256=hashlib.sha256(geo_source).hexdigest(),license='MIT OR Apache-2.0'),
        scaffold_sha256=hashlib.sha256(code.encode()).hexdigest(),cargo_lock_sha256=hashlib.sha256(lock.read_bytes()).hexdigest())
    text=json.dumps(meta,indent=2)[:-2]
    for key,rows in output.items():
        text+=',\n  '+json.dumps(key)+': [\n'+',\n'.join('    '+json.dumps(row,separators=(',',':')) for row in rows)+'\n  ]'
    (target/'geo.json').write_text(text+'\n}\n')
    print({key:len(rows) for key,rows in output.items()},'source geo cases')


if __name__=='__main__':
    main()
