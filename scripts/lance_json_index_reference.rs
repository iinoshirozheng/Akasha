// Transport only: all inference/validation/conversion and extraction are source.
use arrow_array::{Array,ArrayRef,LargeBinaryArray,RecordBatch,StructArray,UInt8Array,Int64Array,Float64Array,BooleanArray,StringArray};
use arrow_schema::{DataType,Field,Schema};
use serde_json::{Value,json};
use std::sync::Arc;
#[allow(dead_code)] mod source;
fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn hex(b:&[u8])->String{b.iter().map(|v|format!("{v:02x}")).collect()}
fn caught(f:impl FnOnce()->Result<Value,String>)->Value {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(v))=>json!({"ok":v}),Ok(Err(e))=>json!({"error":e}),Err(_)=>json!({"panic":true})
    }
}
fn values(array:&ArrayRef)->Value{
    json!((0..array.len()).map(|i|{
        if array.is_null(i){return Value::Null}
        let a=array.as_any();
        if let Some(a)=a.downcast_ref::<Int64Array>(){json!(a.value(i))}
        else if let Some(a)=a.downcast_ref::<Float64Array>(){json!(format!("{:016x}",a.value(i).to_bits()))}
        else if let Some(a)=a.downcast_ref::<BooleanArray>(){json!(a.value(i))}
        else if let Some(a)=a.downcast_ref::<StringArray>(){json!(a.value(i))}
        else if let Some(a)=a.downcast_ref::<LargeBinaryArray>(){json!(hex(a.value(i)))}
        else{unreachable!()}
    }).collect::<Vec<_>>())
}
fn main(){
    std::panic::set_hook(Box::new(|_|{}));
    let input=std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let mut rows:Vec<Value>=serde_json::from_str(&input).unwrap();
    let types=[DataType::Boolean,DataType::Int64,DataType::Float64,DataType::Utf8,DataType::LargeBinary];
    for row in &mut rows {
        let bodies:Vec<Option<Vec<u8>>>=if let Some(texts)=row.get("texts") {
            texts.as_array().unwrap().iter().map(|v|v.as_str().map(|s|jsonb::parse_value(s.as_bytes()).unwrap().to_vec())).collect()
        } else {row["bodies"].as_array().unwrap().iter().map(|v|v.as_str().map(bytes)).collect()};
        let path=row["path"].as_str().unwrap();
        let mut extracted:Vec<Option<Vec<u8>>>=Vec::new();
        let mut tags:Vec<Option<u8>>=Vec::new();
        let extraction=caught(||{
            for (i,body) in bodies.iter().enumerate(){
                if let Some(override_tags)=row.get("tags") {
                    extracted.push(body.clone());tags.push(override_tags[i].as_u64().map(|v|v as u8));
                }else if let Some(body)=body {
                    if let Some((b,t))=source::udf::extract(body,path)? {
                        extracted.push(Some(b));tags.push(Some(t));
                    }else{extracted.push(None);tags.push(Some(0));}
                }else{extracted.push(None);tags.push(Some(0));}
            }
            Ok(json!(extracted.iter().zip(&tags).map(|(b,t)|json!({"value":b.as_ref().map(|b|hex(b)),"tag":t})).collect::<Vec<_>>()))
        });
        let mut result=json!({"extraction":extraction});
        if extraction.get("ok").is_some(){
            let fields=vec![Arc::new(Field::new("value",DataType::LargeBinary,true)),Arc::new(Field::new("type_tag",DataType::UInt8,true))];
            let children:Vec<ArrayRef>=vec![Arc::new(LargeBinaryArray::from_iter(extracted.iter().map(|b|b.as_deref()))),Arc::new(UInt8Array::from(tags))];
            let array=StructArray::new(fields.into(),children,None);
            let input_schema=Arc::new(Schema::new(vec![Field::new("json_result",array.data_type().clone(),false),Field::new("row_id",DataType::Int64,false)]));
            let batch=RecordBatch::try_new(input_schema,vec![Arc::new(array),Arc::new(Int64Array::from_iter_values((0..bodies.len()).map(|i|i as i64*7+11)))]).unwrap();
            result["inference"]=caught(||source::infer(&batch,path).map(|v|json!(v.map(|v|format!("{v:?}")))));
            let mut converted=serde_json::Map::new();
            for target in &types {
                let schema=Arc::new(Schema::new(vec![Field::new("value",target.clone(),true),Field::new("row_id",DataType::Int64,false)]));
                converted.insert(format!("{target:?}"),caught(||source::convert(batch.clone(),schema,&[1],target,path).map(|b|{
                    assert_eq!(values(b.column(1)),values(batch.column(1)));
                    values(b.column(0))
                })));
            }
            result["converted"]=json!(converted);
        }
        row["bodies"]=json!(bodies.iter().map(|b|b.as_ref().map(|b|hex(b))).collect::<Vec<_>>());
        row.as_object_mut().unwrap().remove("texts");
        row["result"]=result;
    }
    println!("{}",serde_json::to_string(&rows).unwrap());
}
