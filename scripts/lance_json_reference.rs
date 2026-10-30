use arrow_array::{Array, ArrayRef, RecordBatch, StringArray};
use arrow_array::builder::StringViewBuilder;
use arrow_schema::{DataType, Field, Schema};
use serde_json::{json, Value};
use std::{io::{self, Read}, sync::Arc, fs::File};

pub const ARROW_EXT_NAME_KEY: &str = "ARROW:extension:name";
#[allow(dead_code)]
#[path = "lance_json.rs"] mod lance_json;

fn tree(v: &jsonb::Value<'_>) -> Value {
    use jsonb::{Value as J, Number as N};
    match v {
        J::Null => json!([5]), J::Bool(v) => json!([4,v]), J::String(v) => json!([1,v]),
        J::Number(N::Int64(v)) => json!([2,v.to_string()]),
        J::Number(N::UInt64(v)) => json!([8,v.to_string()]),
        J::Number(N::Float64(v)) => json!([3,v.to_bits().to_string()]),
        J::Array(v) => json!([6,v.iter().map(tree).collect::<Vec<_>>()]),
        J::Object(v) => json!([7,v.iter().map(|(k,v)|json!([k,tree(v)])).collect::<Vec<_>>()]),
        _ => json!(["extended",format!("{v:?}")]),
    }
}

fn parse(bytes: &[u8], standard: bool) -> Value {
    let result=std::panic::catch_unwind(|| {
        let parsed=if standard {jsonb::parse_value_standard_mode(bytes)} else {jsonb::parse_value(bytes)};
        match parsed { Ok(v)=>json!({"value":tree(&v),"text":v.to_string()}),
                      Err(e)=>json!({"error":e.to_string()}) }
    });
    result.unwrap_or_else(|_|json!({"panic":true}))
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let mut input=String::new();io::stdin().read_to_string(&mut input).unwrap();
    let hexes:Vec<String>=serde_json::from_str(&input).unwrap();
    let rows:Vec<_>=hexes.into_iter().map(|hex|{
        let bytes:Vec<u8>=hex.as_bytes().chunks_exact(2).map(|v|u8::from_str_radix(std::str::from_utf8(v).unwrap(),16).unwrap()).collect();
        json!({"hex":hex,"extended":parse(&bytes,false),"standard":parse(&bytes,true)})
    }).collect();
    let source_nulls=lance_json::JsonArray::try_from_iter([None,Some("null"),Some("[null]"),Some("{\"x\":null}")]).unwrap();
    let null_output=source_nulls.to_arrow_json();
    let strings=null_output.as_any().downcast_ref::<StringArray>().unwrap();
    let nulls:Vec<_>=(0..strings.len()).map(|i|if strings.is_null(i){None}else{Some(strings.value(i))}).collect();
    let make_field=|data_type|Field::new("j",data_type,true).with_metadata([(ARROW_EXT_NAME_KEY.to_string(),"arrow.json".to_string())].into());
    let recognized:Vec<_>=[DataType::Utf8,DataType::LargeUtf8,DataType::Utf8View].into_iter().map(|t|lance_json::is_arrow_json_field(&make_field(t))).collect();
    let values=[Some("discard"),None,Some(""),Some("012345678901"),Some("0123456789012"),Some("漢字😀"),Some("😀😀😀😀"),Some("a\0b"),Some("the second long buffer string"),Some("tail")];
    let mut builder=StringViewBuilder::new().with_fixed_block_size(20);
    for value in values {builder.append_option(value);}
    let array=builder.finish().slice(1,values.len()-2);
    let schema=Arc::new(Schema::new(vec![Field::new("text",DataType::Utf8View,true)]));
    let batch=RecordBatch::try_new(schema.clone(),vec![Arc::new(array) as ArrayRef]).unwrap();
    let path=std::env::args().nth(1).unwrap();
    let mut writer=arrow_ipc::writer::FileWriter::try_new(File::create(path).unwrap(),&schema).unwrap();writer.write(&batch).unwrap();writer.finish().unwrap();
    println!("{}",serde_json::to_string_pretty(&json!({"cases":rows,"arrow_nulls":nulls,"recognized_storage":recognized,"stringview_values":&values[1..values.len()-1]})).unwrap());
}
