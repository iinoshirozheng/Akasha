// Adapters provide IO and row-ID containers; source.rs contains unchanged Lance bodies.
use std::{collections::{BTreeSet,HashMap},sync::{Arc,Mutex}};
use arrow_array::{Array,ArrayRef,BooleanArray,RecordBatch,UInt64Array,new_null_array,cast::AsArray};
use arrow_array::types::UInt64Type;
use arrow_schema::{DataType,Field,Schema as ArrowSchema,SortOptions};
use datafusion_common::{ScalarValue,DataFusionError};
use datafusion_physical_expr::{EquivalenceProperties,PhysicalSortExpr,expressions::Column};
use datafusion_physical_plan::{ExecutionPlan,SendableRecordBatchStream,PlanProperties,Partitioning,DisplayAs,DisplayFormatType,execution_plan::{EmissionType,Boundedness},stream::RecordBatchStreamAdapter,union::UnionExec,sorts::sort_preserving_merge::SortPreservingMergeExec};
use futures::{stream,StreamExt,TryStreamExt};
use serde_json::{Value,json};
mod datafusion {pub use datafusion_physical_plan as physical_plan;pub use datafusion_execution as execution;}
trait SchemaNames {fn field_names(&self)->Vec<&String>;}
impl SchemaNames for ArrowSchema {fn field_names(&self)->Vec<&String>{self.fields().iter().map(|f|f.name()).collect()}}
#[derive(Debug)] struct Error(String);
impl Error {fn internal(v:impl Into<String>)->Self{Self(v.into())}fn invalid_input(v:impl Into<String>)->Self{Self(v.into())}fn index(v:impl Into<String>)->Self{Self(v.into())}}
impl From<arrow_schema::ArrowError> for Error {fn from(e:arrow_schema::ArrowError)->Self{Self(e.to_string())}}
impl From<DataFusionError> for Error {fn from(e:DataFusionError)->Self{Self(e.to_string())}}
impl From<Error> for DataFusionError {fn from(e:Error)->Self{Self::Execution(e.0)}}
type Result<T>=std::result::Result<T,Error>;
const VALUE_COLUMN_NAME:&str="values";const ROW_ID:&str="row_ids";const IDS_COL_IDX:usize=1;const VALUES_COL_IDX:usize=0;const BTREE_INDEX_VERSION:u32=0;
#[derive(Clone)] struct RowAddrTreeMap(BTreeSet<u64>);
impl RowAddrTreeMap {fn contains(&self,v:u64)->bool{self.0.contains(&v)}fn is_empty(&self)->bool{self.0.is_empty()}}
#[derive(Clone)] struct RoaringBitmap(BTreeSet<u32>);
impl RoaringBitmap {fn contains(&self,v:u32)->bool{self.0.contains(&v)}fn is_empty(&self)->bool{self.0.is_empty()}}
#[derive(Clone)] enum OldIndexDataFilter{Fragments{to_keep:RoaringBitmap,to_remove:RoaringBitmap},RowIds(RowAddrTreeMap)}
struct RowAddrRemap(HashMap<u64,Option<u64>>);
impl RowAddrRemap{fn get(&self,id:u64)->Option<Option<u64>>{self.0.get(&id).copied()}}
trait RowIdRemapper:Send+Sync {fn remap_row_ids_record_batch(&self,b:RecordBatch,index:usize)->Result<RecordBatch>;}
trait IndexStore:Send+Sync{} struct Store;impl IndexStore for Store{}
struct CreatedIndex{index_details:(),index_version:u32,files:Vec<RecordBatch>}
mod pbold {#[derive(Default)]pub struct BTreeIndexDetails{}}
mod prost_types {pub struct Any;impl Any{pub fn from_msg<T>(_:&T)->Result<(),()>{Ok(())}}}
#[derive(Default)]struct LanceExecutionOptions{use_spilling:bool}
fn execute_plan(plan:Arc<dyn ExecutionPlan>,_:LanceExecutionOptions)->Result<SendableRecordBatchStream>{Ok(plan.execute(0,Arc::new(datafusion_execution::TaskContext::default()))?)}
fn chunk_concat_stream(s:SendableRecordBatchStream,_:usize)->SendableRecordBatchStream{s}
async fn train_btree_index(s:SendableRecordBatchStream,_:&dyn IndexStore,_:u32,_:Option<u64>,_:Option<u32>)->Result<Vec<RecordBatch>>{Ok(s.try_collect().await?)}
struct FlatIndex;
#[derive(Clone)]struct BTreeIndex{data_type:DataType,batch_size:u32,frag_reuse_index:Option<Arc<dyn RowIdRemapper>>,data:RecordBatch}
impl BTreeIndex{async fn data_stream(&self)->Result<SendableRecordBatchStream>{Ok(Box::pin(RecordBatchStreamAdapter::new(self.data.schema(),stream::iter(vec![Ok(self.data.clone())]))))}}
mod source;
fn dtype(t:u64)->DataType{match t{1=>DataType::Boolean,2=>DataType::Int64,3=>DataType::Float64,4=>DataType::Utf8,5=>DataType::LargeBinary,_=>unreachable!()}}
fn scalar(v:&Value,t:u64)->ScalarValue{match t{1=>ScalarValue::Boolean(v.as_bool()),2=>ScalarValue::Int64(v.as_i64()),3=>ScalarValue::Float64(v.as_str().map(|s|f64::from_bits(u64::from_str_radix(s,16).unwrap()))),4=>ScalarValue::Utf8(v.as_str().map(String::from)),5=>ScalarValue::LargeBinary(v.as_str().map(|s|s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect())),_=>unreachable!()}}
fn batch(rows:&[Value],t:u64)->RecordBatch{
 let values=if rows.is_empty(){new_null_array(&dtype(t),0)}else{ScalarValue::iter_to_array(rows.iter().map(|r|scalar(&r["value"],t))).unwrap()};
 let ids: ArrayRef=Arc::new(UInt64Array::from_iter_values(rows.iter().map(|r|r["id"].as_u64().unwrap())));
 let order=arrow_ord::sort::sort_to_indices(&*values,Some(SortOptions{descending:false,nulls_first:true}),None).unwrap();
 let values=arrow_select::take::take(&*values,&order,None).unwrap();let ids=arrow_select::take::take(&*ids,&order,None).unwrap();
 RecordBatch::try_new(Arc::new(ArrowSchema::new(vec![Field::new("values",dtype(t),true),Field::new("row_ids",DataType::UInt64,false)])),vec![values,ids]).unwrap()
}
fn rows(batches:Vec<RecordBatch>)->Vec<Value>{
 let mut rows=Vec::new();
 for b in batches{for i in 0..b.num_rows(){let v=ScalarValue::try_from_array(b.column(0),i).unwrap();let value=match v{ScalarValue::Boolean(x)=>json!(x),ScalarValue::Int64(x)=>json!(x),ScalarValue::Float64(x)=>json!(x.map(|x|format!("{:016x}",x.to_bits()))),ScalarValue::Utf8(x)=>json!(x),ScalarValue::LargeBinary(x)=>json!(x.map(|x|x.iter().map(|b|format!("{b:02x}")).collect::<String>())),_=>unreachable!()};rows.push(json!({"id":b.column(1).as_primitive::<arrow_array::types::UInt64Type>().value(i),"value":value}));}}
 rows.sort_by_key(|r|r["id"].as_u64().unwrap());rows
}
#[tokio::main]async fn main(){
 let inputs:Vec<Value>=serde_json::from_slice(&std::fs::read(std::env::args().nth(1).unwrap()).unwrap()).unwrap();let mut output=Vec::new();
 for mut case in inputs{
  let t=case["type"].as_u64().unwrap();let old=batch(case["old"].as_array().unwrap(),t);let new=batch(case["new"].as_array().unwrap(),t);
  let mapping=RowAddrRemap(case["mapping"].as_array().unwrap().iter().map(|x|(x[0].as_u64().unwrap(),x[1].as_u64())).collect());
  case["remapped"]=json!(rows(vec![FlatIndex::remap_batch(old.clone(),&mapping).unwrap()]));
  let removed:BTreeSet<u64>=case["removed"].as_array().unwrap().iter().map(|v|v.as_u64().unwrap()).collect();
  let keep=RowAddrTreeMap(case["old"].as_array().unwrap().iter().map(|v|v["id"].as_u64().unwrap()).filter(|id|!removed.contains(id)).collect());
  let index=Arc::new(BTreeIndex{data_type:dtype(t),batch_size:3,frag_reuse_index:None,data:old});
  let stream=Box::pin(RecordBatchStreamAdapter::new(new.schema(),stream::iter(vec![Ok(new)])));
  let created=BTreeIndex::merge_segments(&[index],stream,&Store,&[Some(OldIndexDataFilter::RowIds(keep))]).await.unwrap();
  case["updated"]=json!(rows(created.files));output.push(case);
 }
 println!("{}",serde_json::to_string(&output).unwrap());
}
