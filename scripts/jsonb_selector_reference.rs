use jsonb::{OwnedJsonb, Value as JsonbValue};
use jsonb::jsonpath::{parse_json_path, Selector};
use serde_json::{Value,json};
use std::{io::{self,Read},collections::BTreeMap};

fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn hex(b:&[u8])->String{b.iter().map(|v|format!("{v:02x}")).collect()}
fn metrics(v:&JsonbValue<'_>)->(usize,usize){
    let mut nodes=1;let mut depth=0;
    match v{
        JsonbValue::Array(v)=>{depth=1;for v in v{let(n,d)=metrics(v);nodes+=n;depth=depth.max(d+1);}},
        JsonbValue::Object(v)=>{depth=1;for v in v.values(){let(n,d)=metrics(v);nodes+=n;depth=depth.max(d+1);}},
        _=>{}
    }(nodes,depth)
}
fn output_limit(v:&Value)->bool{
    match v{
        Value::String(s)=>{let b=bytes(s);let(n,d)=metrics(&jsonb::from_slice(&b).unwrap());b.len()>16*1024*1024||n>65536||d>64},
        Value::Array(v)=>v.iter().any(output_limit),
        _=>false
    }
}
fn result<T>(f:impl FnOnce()->Result<T,jsonb::Error>, encode:impl FnOnce(T)->Value)->Value{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)){
        Ok(Ok(v))=>{let encoded=encode(v);if output_limit(&encoded){json!({"ok":encoded,"output_limit":true})}else{json!({"ok":encoded})}},Ok(Err(e))=>json!({"error":e.to_string()}),Err(_)=>json!({"panic":true})
    }
}
fn main(){
    std::panic::set_hook(Box::new(|_|{}));
    let mut s=String::new();io::stdin().read_to_string(&mut s).unwrap();let input:Value=serde_json::from_str(&s).unwrap();
    let mut docs:Vec<OwnedJsonb>=Vec::new();
    for d in input["docs"].as_array().unwrap(){
        let value=if let Some(text)=d.get("text"){text.as_str().unwrap().parse::<OwnedJsonb>().unwrap()}
        else if let Some(raw)=d.get("hex"){OwnedJsonb::new(bytes(raw.as_str().unwrap()))}
        else {let v=jsonb::from_slice(docs[d["wrap"].as_u64().unwrap() as usize].as_ref()).unwrap();
            let mut object=BTreeMap::new();object.insert("a".to_string(),v.clone());object.insert("b".to_string(),JsonbValue::Number(jsonb::Number::Int64(0)));
            object.insert("items".to_string(),JsonbValue::Array(vec![JsonbValue::Null,v.clone(),JsonbValue::Array(vec![v])]));
            OwnedJsonb::new(JsonbValue::Object(object).to_vec())};
        docs.push(value);
    }
    let paths:Vec<Vec<u8>>=input["paths"].as_array().unwrap().iter().map(|s|bytes(s.as_str().unwrap())).collect();
    let mut rows=Vec::new();
    for pair in input["pairs"].as_array().unwrap(){
        let doc=&docs[pair[0].as_u64().unwrap() as usize];let path=&paths[pair[1].as_u64().unwrap() as usize];
        let parsed=std::panic::catch_unwind(||parse_json_path(path));
        let row=match parsed {
            Ok(Ok(path))=>{
                // A fresh original Selector for each public mode; expected
                // output is not inferred from another mode's output.
                let raw=doc.as_raw();
                json!({"pair":pair,"modes":[
                    result(||Selector::new(raw).select_values(&path),|v|json!(v.iter().map(|v|hex(v.as_ref())).collect::<Vec<_>>())),
                    result(||Selector::new(raw).select_array(&path),|v|json!(hex(v.as_ref()))),
                    result(||Selector::new(raw).select_first(&path),|v|json!(v.map(|v|hex(v.as_ref())))),
                    result(||Selector::new(raw).select_value(&path),|v|json!(v.map(|v|hex(v.as_ref())))),
                    result(||Selector::new(raw).exists(&path),|v|json!(v)),
                    result(||Selector::new(raw).predicate_match(&path),|v|json!(v)),
                ]})
            },
            Ok(Err(e))=>json!({"pair":pair,"parse_error":e.to_string()}),
            Err(_)=>json!({"pair":pair,"parse_panic":true}),
        };rows.push(row);
    }
    println!("{}",json!({"docs":docs.iter().map(|d|hex(d.as_ref())).collect::<Vec<_>>(),"paths":input["paths"],"cases":rows}));
}
