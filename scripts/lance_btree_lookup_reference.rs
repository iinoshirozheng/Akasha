// The lookup/statistics algorithm bodies are extracted unchanged in source.rs.
use std::{cmp::Ordering,ops::Bound,sync::Arc};
use arrow_array::{Array,RecordBatch,UInt32Array,new_null_array};
use arrow_schema::{DataType,Field,Schema,SortOptions};
use arrow_ord::ord::make_comparator;
use datafusion_common::ScalarValue;
use serde_json::{Value,json};
type Result<T>=std::result::Result<T,Error>;
#[derive(Debug)] pub struct Error(String);
impl Error {fn internal(s:impl Into<String>)->Self{Self(s.into())}}
impl From<arrow_schema::ArrowError> for Error{fn from(e:arrow_schema::ArrowError)->Self{Self(e.to_string())}}
impl From<datafusion_common::DataFusionError> for Error{fn from(e:datafusion_common::DataFusionError)->Self{Self(e.to_string())}}
trait OptionExt<T>{fn expect_ok(self)->Result<T>;}
impl<T> OptionExt<T> for Option<T>{fn expect_ok(self)->Result<T>{self.ok_or_else(||Error("required field missing".into()))}}
const VALUE_COLUMN_NAME:&str="value";
#[allow(dead_code)] mod source;
use source::OrderableScalarValue;
fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn dtype(t:u64)->DataType{match t{1=>DataType::Boolean,2=>DataType::Int64,3=>DataType::Float64,4=>DataType::Utf8,5=>DataType::LargeBinary,_=>unreachable!()}}
fn scalar(v:&Value,t:u64)->ScalarValue{match t{1=>ScalarValue::Boolean(v.as_bool()),2=>ScalarValue::Int64(v.as_i64()),3=>ScalarValue::Float64(v.as_str().map(|s|f64::from_bits(u64::from_str_radix(s,16).unwrap()))),4=>ScalarValue::Utf8(v.as_str().map(String::from)),5=>ScalarValue::LargeBinary(v.as_str().map(bytes)),_=>unreachable!()}}
fn key(v:&ScalarValue)->Value{match v{ScalarValue::Boolean(x)=>json!(x),ScalarValue::Int64(x)=>json!(x),ScalarValue::Float64(x)=>json!(x.map(|x|format!("{:016x}",x.to_bits()))),ScalarValue::Utf8(x)=>json!(x),ScalarValue::LargeBinary(x)=>json!(x.as_ref().map(|x|x.iter().map(|b|format!("{b:02x}")).collect::<String>())),_=>unreachable!()}}
fn bound(v:&Value,t:u64)->Bound<OrderableScalarValue>{if v.is_null(){Bound::Unbounded}else{let k=OrderableScalarValue(scalar(&v["value"],t));if v["included"]==true{Bound::Included(k)}else{Bound::Excluded(k)}}}
fn main(){
 let input:Vec<Value>=serde_json::from_slice(&std::fs::read(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
 let mut output=Vec::new();
 for case in input {
  let t=case["type"].as_u64().unwrap();let page_size=case["page_size"].as_u64().unwrap() as usize;
  let mut values:Vec<_>=case["values"].as_array().unwrap().iter().map(|v|OrderableScalarValue(scalar(v,t))).collect();values.sort();
  let mut mins=Vec::new();let mut maxs=Vec::new();let mut counts=Vec::new();let mut pages=Vec::new();
  for chunk in values.chunks(page_size){
   let arr=ScalarValue::iter_to_array(chunk.iter().map(|v|v.0.clone())).unwrap();
   let batch=RecordBatch::try_new(Arc::new(Schema::new(vec![Field::new(VALUE_COLUMN_NAME,dtype(t),true)])),vec![arr]).unwrap();
   let (min,max,nulls)=source::stats(&batch).unwrap();
   pages.push(json!([key(&min),key(&max),nulls,chunk.len()]));mins.push(min);maxs.push(max);counts.push(nulls);
  }
  let min_arr=if mins.is_empty(){new_null_array(&dtype(t),0)}else{ScalarValue::iter_to_array(mins).unwrap()};
  let max_arr=if maxs.is_empty(){new_null_array(&dtype(t),0)}else{ScalarValue::iter_to_array(maxs).unwrap()};
  let schema=Arc::new(Schema::new(vec![Field::new("min",dtype(t),true),Field::new("max",dtype(t),true),Field::new("null_count",DataType::UInt32,false),Field::new("page_idx",DataType::UInt32,false)]));
  let batch=RecordBatch::try_new(schema,vec![min_arr,max_arr,Arc::new(UInt32Array::from(counts)),Arc::new(UInt32Array::from_iter_values(0..pages.len() as u32))]).unwrap();
  let mut queries=Vec::new();for q in case["queries"].as_array().unwrap(){queries.push(json!({"query":q,"matches":source::query(batch.clone(),q,t).unwrap()}));}
  output.push(json!({"type":t,"pages":pages,"queries":queries}));
 }
 println!("{}",serde_json::to_string(&output).unwrap());
}
