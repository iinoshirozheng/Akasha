// Harness adapters transport inputs/results; all consumer algorithms are upstream.
use arrow_array::{Array,ArrayRef,LargeBinaryArray,StringArray,BooleanArray,Int64Array,Float64Array,StructArray,UInt8Array};
use serde_json::{Value,json};
use std::{sync::Arc,collections::BTreeMap};
pub const ARROW_EXT_NAME_KEY:&str="ARROW:extension:name";
#[allow(dead_code)] mod lance_json;
#[allow(dead_code)] mod lance_udf;
fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn hex(b:&[u8])->String{b.iter().map(|v|format!("{v:02x}")).collect()}
fn array_json(array:&ArrayRef)->Value{
    let mut values=Vec::new();
    for i in 0..array.len(){
        if array.is_null(i){values.push(Value::Null);continue}
        let any=array.as_any();
        let v=if let Some(a)=any.downcast_ref::<StringArray>(){json!(a.value(i))}
        else if let Some(a)=any.downcast_ref::<LargeBinaryArray>(){json!(hex(a.value(i)))}
        else if let Some(a)=any.downcast_ref::<Int64Array>(){json!(a.value(i))}
        else if let Some(a)=any.downcast_ref::<Float64Array>(){json!(format!("{:016x}",a.value(i).to_bits()))}
        else if let Some(a)=any.downcast_ref::<BooleanArray>(){json!(a.value(i))}
        else if let Some(a)=any.downcast_ref::<StructArray>(){
            let b=a.column(0).as_any().downcast_ref::<LargeBinaryArray>().unwrap();
            let t=a.column(1).as_any().downcast_ref::<UInt8Array>().unwrap();
            json!({"value":if b.is_null(i){None}else{Some(hex(b.value(i)))},"type_tag":t.value(i)})
        }else{panic!("unsupported result")};values.push(v);
    }json!(values)
}
fn strings(v:&Value,sliced:bool)->StringArray{
    let mut v:Vec<Option<&str>>=v.as_array().unwrap().iter().map(|x|x.as_str()).collect();
    if sliced {let n=v.len();v.insert(0,Some("discard"));StringArray::from(v).slice(1,n)} else {StringArray::from(v)}
}
fn depth(v:&jsonb::Value<'_>)->usize { match v { jsonb::Value::Array(v)=>1+v.iter().map(depth).max().unwrap_or(0),jsonb::Value::Object(v)=>1+v.values().map(depth).max().unwrap_or(0),_=>0 } }
fn main(){
    std::panic::set_hook(Box::new(|_|{}));
    let text=std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let mut cases:Vec<Value>=serde_json::from_str(&text).unwrap();
    for row in &mut cases {
        let mut bodies:Vec<Option<Vec<u8>>>=Vec::new();
        let mut input_limit=false;
        for v in row["bodies"].as_array().unwrap(){
            if v.is_null(){bodies.push(None);continue}
            let mut b=if let Some(t)=v.get("text"){lance_json::encode_json(t.as_str().unwrap()).unwrap()}else{bytes(v.as_str().unwrap())};
            if let Some(w)=row.get("wrap"){
                let raw=jsonb::RawJsonb::new(&b);
                b=if w=="array"{jsonb::OwnedJsonb::build_array([raw].into_iter()).unwrap().to_vec()}
                else{jsonb::OwnedJsonb::build_object([("v",raw)].into_iter()).unwrap().to_vec()};
            }
            if row.get("wrap").is_some() && depth(&jsonb::from_slice(&b).unwrap())>64 {input_limit=true;}
            bodies.push(Some(b));
        }
        if input_limit {row["input_limit"]=json!("depth>64 after source wrapper");}
        row["bodies"]=json!(bodies.iter().map(|b|b.as_ref().map(|b|hex(b))).collect::<Vec<_>>());
        let sliced=row.get("sliced")==Some(&json!(true));
        let n=bodies.len();
        if sliced {bodies.insert(0,Some(vec![0]));}
        let mut array=LargeBinaryArray::from_iter(bodies.iter().map(|b|b.as_deref()));
        if sliced {array=array.slice(1,n);}
        let paths=strings(&row["args"],sliced);
        let mut args:Vec<ArrayRef>=vec![Arc::new(array.clone()),Arc::new(paths.clone())];
        let needles=if row["values"].is_null(){None}else{Some(strings(&row["values"],sliced))};
        let mut results=BTreeMap::new();
        for op in row["ops"].as_array().unwrap(){
            let op=op.as_u64().unwrap() as usize;
            if op==9 {args.push(Arc::new(needles.as_ref().unwrap().clone()));}
            let value=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||->Result<Value,String>{
                if op==0 {
                    let mut out=vec![];
                    for i in 0..array.len(){
                        let j=if paths.len()==1{0}else{i};
                        if array.is_null(i)||paths.is_null(j){out.push(None);continue}
                        out.push(lance_json::oracle_raw_path(array.clone(),i,paths.value(j)).map_err(|e|e.to_string())?);
                    }Ok(json!(out))
                }else {lance_udf::run(op,&args).map(|a|array_json(&a))}
            }));
            if op==9 {args.pop();}
            results.insert(op.to_string(),match value{Ok(Ok(v))=>json!({"ok":v}),Ok(Err(e))=>json!({"error":e}),Err(_)=>json!({"panic":true})});
        }
        row["results"]=json!(results);row.as_object_mut().unwrap().remove("wrap");
    }
    println!("{}",serde_json::to_string(&cases).unwrap());
}
