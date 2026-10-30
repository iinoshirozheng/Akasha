// Stream/schema/error transport. All inference and conversion run original source.
use arrow_array::{Array,ArrayRef,RecordBatch,StructArray,LargeBinaryArray,UInt8Array,UInt64Array,BooleanArray,Int64Array,Float64Array,StringArray};
use arrow_schema::{DataType,Field,Schema};
use futures::{Stream,StreamExt};
use serde_json::{Value,json};
use std::{pin::Pin,sync::{Arc,atomic::{AtomicUsize,Ordering}},task::{Context,Poll}};
#[derive(Debug)]struct Error(String);
#[derive(Debug)]enum DataFusionError{Execution(String)}
impl Error{fn invalid_input_source(e:Box<dyn std::error::Error+Send+Sync>)->Self{Self(e.to_string())}}
impl From<arrow_schema::ArrowError> for Error{fn from(e:arrow_schema::ArrowError)->Self{Self(e.to_string())}}
impl From<DataFusionError> for Error{fn from(e:DataFusionError)->Self{let DataFusionError::Execution(e)=e;Self(e)}}
impl From<Error> for DataFusionError{fn from(e:Error)->Self{Self::Execution(e.0)}}
type Result<T>=std::result::Result<T,Error>;
type BatchResult=std::result::Result<RecordBatch,DataFusionError>;
trait RecordBatchStream:Stream<Item=BatchResult>{fn schema(&self)->Arc<Schema>;}
type SendableRecordBatchStream=Pin<Box<dyn RecordBatchStream>>;
struct RecordBatchStreamAdapter<S>{schema:Arc<Schema>,stream:S}
impl<S> RecordBatchStreamAdapter<S>{fn new(schema:Arc<Schema>,stream:S)->Self{Self{schema,stream}}}
impl<S:Stream<Item=BatchResult>+Unpin> Stream for RecordBatchStreamAdapter<S>{type Item=BatchResult;fn poll_next(mut self:Pin<&mut Self>,cx:&mut Context<'_>)->Poll<Option<Self::Item>>{Pin::new(&mut self.stream).poll_next(cx)}}
impl<S:Stream<Item=BatchResult>+Unpin> RecordBatchStream for RecordBatchStreamAdapter<S>{fn schema(&self)->Arc<Schema>{self.schema.clone()}}
const VALUE_COLUMN_NAME:&str="value";
#[allow(dead_code)]mod source;
fn extracted_schema()->Arc<Schema>{Arc::new(Schema::new(vec![Field::new("json_result",DataType::Struct(vec![Arc::new(Field::new("value",DataType::LargeBinary,true)),Arc::new(Field::new("type_tag",DataType::UInt8,true))].into()),false),Field::new("row_id",DataType::UInt64,false),Field::new("row_addr",DataType::UInt64,false)]))}
fn extract_stream(data:SendableRecordBatchStream,path:String)->Result<SendableRecordBatchStream>{
 let schema=extracted_schema();let output=schema.clone();
 let stream=data.map(move|batch|{
  let batch=batch?;let values=batch.column(0).as_any().downcast_ref::<LargeBinaryArray>().unwrap();let mut bodies=Vec::new();let mut tags=Vec::new();
  for value in values.iter(){let result=match value{Some(b)=>source::udf::extract(b,&path)?,None=>None};match result{Some((body,tag))=>{bodies.push(Some(body));tags.push(tag)},None=>{bodies.push(None);tags.push(0)}}}
  let fields=match output.field(0).data_type(){DataType::Struct(f)=>f.clone(),_=>unreachable!()};
  let array=StructArray::new(fields,vec![Arc::new(LargeBinaryArray::from_iter(bodies.iter().map(|b|b.as_deref()))),Arc::new(UInt8Array::from(tags))],None);
  Ok(RecordBatch::try_new(output.clone(),vec![Arc::new(array),batch.column(1).clone(),batch.column(2).clone()]).map_err(Error::from)?)
 });Ok(Box::pin(RecordBatchStreamAdapter::new(schema,stream)))
}
fn hex(bytes:&[u8])->String{bytes.iter().map(|b|format!("{b:02x}")).collect()}
fn dtype(t:u64)->DataType{match t{1=>DataType::Boolean,2=>DataType::Int64,3=>DataType::Float64,4=>DataType::Utf8,5=>DataType::LargeBinary,_=>unreachable!()}}
fn type_id(t:&DataType)->u8{match t{DataType::Boolean=>1,DataType::Int64=>2,DataType::Float64=>3,DataType::Utf8=>4,DataType::LargeBinary=>5,_=>unreachable!()}}
fn values(a:&ArrayRef)->Value{json!((0..a.len()).map(|i|{if a.is_null(i){return Value::Null}let b=a.as_any();
 if let Some(b)=b.downcast_ref::<BooleanArray>(){json!(b.value(i))}else if let Some(b)=b.downcast_ref::<Int64Array>(){json!(b.value(i))}else if let Some(b)=b.downcast_ref::<Float64Array>(){json!(format!("{:016x}",b.value(i).to_bits()))}else if let Some(b)=b.downcast_ref::<StringArray>(){json!(b.value(i))}else if let Some(b)=b.downcast_ref::<LargeBinaryArray>(){json!(hex(b.value(i)))}else if let Some(b)=b.downcast_ref::<UInt64Array>(){json!(b.value(i))}else{unreachable!()}
 }).collect::<Vec<_>>())}
fn main(){
 let input=std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();let mut cases:Vec<Value>=serde_json::from_str(&input).unwrap();
 futures::executor::block_on(async{for row in &mut cases{
  let schema=Arc::new(Schema::new(vec![Field::new("value",DataType::LargeBinary,true),Field::new("row_id",DataType::UInt64,false),Field::new("row_addr",DataType::UInt64,false)]));
  let mut batches=Vec::new();let mut bodies_out=Vec::new();let mut ids_out=Vec::new();let mut ordinal=0u64;
  for batch in row["batches"].as_array().unwrap(){
   let bodies:Vec<_>=batch.as_array().unwrap().iter().map(|v|v.as_str().map(|s|jsonb::parse_value(s.as_bytes()).unwrap().to_vec())).collect();
   let ids:Vec<_>=bodies.iter().map(|_|{let i=ordinal;ordinal+=1;if i%3==0{u64::MAX-i}else{i}}).collect();let addrs:Vec<_>=ids.iter().enumerate().map(|(i,_)|(2u64<<32)+i as u64).collect();
   bodies_out.push(json!(bodies.iter().map(|b|b.as_ref().map(|b|hex(b))).collect::<Vec<_>>()));ids_out.push(json!(ids));
   batches.push(Ok(RecordBatch::try_new(schema.clone(),vec![Arc::new(LargeBinaryArray::from_iter(bodies.iter().map(|b|b.as_deref()))),Arc::new(UInt64Array::from(ids)),Arc::new(UInt64Array::from(addrs))]).unwrap()));
  }
  row["bodies"]=json!(bodies_out);row["ids"]=json!(ids_out);let polled=Arc::new(AtomicUsize::new(0));let count=polled.clone();
  let stream=futures::stream::iter(batches).inspect(move |_|{count.fetch_add(1,Ordering::SeqCst);});let data=Box::pin(RecordBatchStreamAdapter::new(schema,stream))as SendableRecordBatchStream;
  let path=row["path"].as_str().unwrap().to_owned();let prepared=if let Some(t)=row["target"].as_u64(){extract_stream(data,path.clone()).map(|s|(s,dtype(t)))}else{source::infer(data,path.clone()).await};
  let mut result=json!({"prefix_batches":polled.load(Ordering::SeqCst)});
  match prepared{
   Err(e)=>{result["error"]=json!(e.0);result["phase"]=json!("inference");},
   Ok((data,target))=>{result["target"]=json!(type_id(&target));let mut converted=source::convert(data,target,path).unwrap();let mut outputs=Vec::new();
    while let Some(batch)=converted.next().await{match batch{Ok(b)=>outputs.push(json!({"values":values(b.column(0)),"ids":values(b.column(1)),"addresses":values(b.column(2)),"polled":polled.load(Ordering::SeqCst)})),Err(e)=>{result["error"]=json!(Error::from(e).0);result["phase"]=json!("conversion");break}}}
    result["converted"]=json!(outputs);
   }
  }
  result["polled"]=json!(polled.load(Ordering::SeqCst));row["result"]=result;row.as_object_mut().unwrap().remove("batches");
 }});
 println!("{}",serde_json::to_string(&cases).unwrap());
}
