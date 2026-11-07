use arrow_array::{Array,LargeBinaryArray,RecordBatch,StructArray,UInt8Array};
use arrow_schema::{DataType,Field,Schema};
use datafusion_common::ScalarValue;
use serde_json::{Value,json};
use std::sync::Arc;
#[derive(Debug)]struct Error(String);
impl Error{fn invalid_input_source(e:Box<dyn std::error::Error+Send+Sync>)->Self{Self(e.to_string())}}
impl From<arrow_schema::ArrowError> for Error{fn from(e:arrow_schema::ArrowError)->Self{Self(e.to_string())}}
#[derive(Debug)]enum DataFusionError{Execution(String)}
type Result<T>=std::result::Result<T,Error>;
struct JsonIndexPlugin;
struct JsonQueryParser{path:String}
enum Expr{ScalarFunction(Function),Literal(ScalarValue,()),Column}
struct Function{name:String,args:Vec<Expr>}
impl Function{fn name(&self)->&str{&self.name}}
#[allow(dead_code)]mod source;
fn hex(bytes:&[u8])->String{bytes.iter().map(|b|format!("{b:02x}")).collect()}
fn bytes(hex:&str)->Vec<u8>{(0..hex.len()).step_by(2).map(|i|u8::from_str_radix(&hex[i..i+2],16).unwrap()).collect()}
fn scalar_json(v:&ScalarValue)->Value{match v{
 ScalarValue::Boolean(v)=>json!(v),ScalarValue::Int64(v)=>json!(v),ScalarValue::Float64(v)=>json!(v.map(|v|format!("{:016x}",v.to_bits()))),ScalarValue::Utf8(v)=>json!(v),ScalarValue::LargeBinary(v)=>json!(v.as_ref().map(|v|hex(v))),_=>unreachable!()}}
fn main(){
 std::panic::set_hook(Box::new(|_|{}));
 let input=std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();let mut cases:Vec<Value>=serde_json::from_str(&input).unwrap();
 for row in &mut cases{
  let body=if let Some(value)=row.get("wrapped_scalar"){
   let value=bytes(value.as_str().unwrap());jsonb::OwnedJsonb::build_object([("v",jsonb::RawJsonb::new(&value))].into_iter()).unwrap().to_vec()
  }else{jsonb::parse_value(row["text"].as_str().unwrap().as_bytes()).unwrap().to_vec()};
  row["body"]=json!(hex(&body));row["result"]=source::evaluate(&body,row["path"].as_str().unwrap(),row["function"].as_str().unwrap());
 }
 println!("{}",serde_json::to_string(&cases).unwrap());
}
