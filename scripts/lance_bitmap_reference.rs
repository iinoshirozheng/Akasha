// Source algorithms are in generated source.rs; these are transport/store adapters.
use std::{any::Any,cmp::Ordering,collections::{BTreeMap,HashMap},ops::Bound,pin::Pin,sync::{Arc,Mutex},task::{Context,Poll}};
use arrow_array::{Array,BooleanArray,RecordBatch,UInt64Array,new_null_array};
use arrow_schema::{DataType,Field,Schema,SortOptions};
use datafusion_common::ScalarValue;
use futures::{Stream,StreamExt,TryStreamExt,stream};
use roaring::{RoaringBitmap,RoaringTreemap};
use serde_json::{Value,json};
use source::OrderableScalarValue;
pub use source::OldIndexDataFilter;
type Result<T>=std::result::Result<T,Error>;
#[derive(Debug)]pub struct Error(String);
// Schema-only adapter for Lance OptionExt::expect_ok. Inputs always contain both columns.
trait OptionExt<T>{fn expect_ok(self)->Result<T>;}
impl<T> OptionExt<T> for Option<T>{fn expect_ok(self)->Result<T>{self.ok_or_else(||Error("required value missing".into()))}}

impl Error{fn not_supported_source(e:Box<dyn std::error::Error+Send+Sync>)->Self{Self(e.to_string())}}
impl From<arrow_schema::ArrowError> for Error{fn from(e:arrow_schema::ArrowError)->Self{Self(e.to_string())}}
impl From<datafusion_common::DataFusionError> for Error{fn from(e:datafusion_common::DataFusionError)->Self{Self(e.to_string())}}
#[derive(Clone,Default,Debug)]pub struct RowAddrTreeMap(RoaringTreemap);
impl RowAddrTreeMap{
 fn insert(&mut self,id:u64){self.0.insert(id);}
 fn is_empty(&self)->bool{self.0.is_empty()}
 fn contains(&self,id:u64)->bool{self.0.contains(id)}
 fn row_addrs(&self)->Option<impl Iterator<Item=u64>+'_>{Some(self.0.iter())}
 fn union_all(sets:&[&Self])->Self{Self(sets.iter().fold(RoaringTreemap::new(),|a,b|a|&b.0))}
 fn retain_fragments(&mut self,ids:impl Iterator<Item=u32>){let keep:RoaringBitmap=ids.collect();self.0=self.0.iter().filter(|id|keep.contains((id>>32)as u32)).collect();}
}
impl FromIterator<u64> for RowAddrTreeMap{fn from_iter<T:IntoIterator<Item=u64>>(iter:T)->Self{Self(iter.into_iter().collect())}}
impl std::ops::BitOrAssign<&Self> for RowAddrTreeMap{fn bitor_assign(&mut self,b:&Self){self.0|=&b.0;}}
impl std::ops::BitAndAssign<&Self> for RowAddrTreeMap{fn bitand_assign(&mut self,b:&Self){self.0&=&b.0;}}
#[derive(Debug)]pub struct NullableRowAddrSet{selected:RowAddrTreeMap,nulls:RowAddrTreeMap}
impl NullableRowAddrSet{fn new(selected:RowAddrTreeMap,nulls:RowAddrTreeMap)->Self{Self{selected,nulls}}}
pub enum SearchResult{Exact(NullableRowAddrSet)}
pub trait AnyQuery{fn as_any(&self)->&dyn Any;}
pub enum SargableQuery{Equals(ScalarValue),Range(Bound<ScalarValue>,Bound<ScalarValue>),IsIn(Vec<ScalarValue>),IsNull(),FullTextSearch(()),LikePrefix(ScalarValue)}
impl AnyQuery for SargableQuery{fn as_any(&self)->&dyn Any{self}}
pub trait MetricsCollector{fn record_comparisons(&self,_:usize){}}
pub struct Metrics;impl MetricsCollector for Metrics{}
fn get_num_compute_intensive_cpus()->usize{1}
pub struct RowAddrRemap(HashMap<u64,Option<u64>>);
impl RowAddrRemap{fn get(&self,id:u64)->Option<Option<u64>>{self.0.get(&id).copied()}}
pub struct BitmapIndex{index_map:BTreeMap<OrderableScalarValue,usize>,null_map:Arc<RowAddrTreeMap>,postings:Vec<RowAddrTreeMap>}
impl BitmapIndex{
 async fn load_bitmap(&self,key:&OrderableScalarValue,_:Option<&dyn MetricsCollector>)->Result<Arc<RowAddrTreeMap>>{
  if key.0.is_null(){return Ok(self.null_map.clone())}
  Ok(Arc::new(self.index_map.get(key).map(|i|self.postings[*i].clone()).unwrap_or_default()))
 }
 fn from_file(file:IndexFile)->Self{
  let mut index_map=BTreeMap::new();let mut null_map=Arc::new(RowAddrTreeMap::default());let mut postings=Vec::new();
  for (key,rows) in file.rows {if key.is_null(){null_map=Arc::new(rows)}else{index_map.insert(OrderableScalarValue(key),postings.len());postings.push(rows);}}
  Self{index_map,null_map,postings}
 }
 fn state(&self,typ:&DataType)->HashMap<ScalarValue,RowAddrTreeMap>{
  let mut state=self.index_map.iter().map(|(k,i)|(k.0.clone(),self.postings[*i].clone())).collect::<HashMap<_,_>>();
  if !self.null_map.is_empty(){state.insert(ScalarValue::try_from_array(&new_null_array(typ,1),0).unwrap(),(*self.null_map).clone());}state
 }
}
pub struct BitmapIndexPlugin;
pub struct IndexFile{rows:Vec<(ScalarValue,RowAddrTreeMap)>}
pub trait IndexStore{fn memory(&self)->Arc<Mutex<Vec<(ScalarValue,RowAddrTreeMap)>>>;}
#[derive(Default)]pub struct MemoryStore(Arc<Mutex<Vec<(ScalarValue,RowAddrTreeMap)>>>);
impl IndexStore for MemoryStore{fn memory(&self)->Arc<Mutex<Vec<(ScalarValue,RowAddrTreeMap)>>>{self.0.clone()}}
pub struct BitmapBatchWriter{rows:Arc<Mutex<Vec<(ScalarValue,RowAddrTreeMap)>>>}
impl BitmapBatchWriter{
 async fn emit(&mut self,key:ScalarValue,rows:&RowAddrTreeMap)->Result<()>{self.rows.lock().unwrap().push((key,rows.clone()));Ok(())}
 async fn finish(self)->Result<IndexFile>{Ok(IndexFile{rows:std::mem::take(&mut*self.rows.lock().unwrap())})}
}
async fn new_bitmap_batch_writer(store:&dyn IndexStore,_:&str,_:&DataType)->Result<BitmapBatchWriter>{Ok(BitmapBatchWriter{rows:store.memory()})}
pub trait RecordBatchStream:Stream<Item=Result<RecordBatch>>{fn schema(&self)->Arc<Schema>;}
pub type SendableRecordBatchStream=Pin<Box<dyn RecordBatchStream>>;
struct MemoryStream{schema:Arc<Schema>,batches:std::collections::VecDeque<RecordBatch>}
impl Stream for MemoryStream{type Item=Result<RecordBatch>;fn poll_next(mut self:Pin<&mut Self>,_:&mut Context<'_>)->Poll<Option<Self::Item>>{Poll::Ready(self.batches.pop_front().map(Ok))}}
impl RecordBatchStream for MemoryStream{fn schema(&self)->Arc<Schema>{self.schema.clone()}}
const VALUE_COLUMN_NAME:&str="value";const ROW_ID:&str="row_id";
#[allow(dead_code)]mod source;
fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn hex(b:&[u8])->String{b.iter().map(|b|format!("{b:02x}")).collect()}
fn dtype(typ:u64)->DataType{match typ{1=>DataType::Boolean,2=>DataType::Int64,3=>DataType::Float64,4=>DataType::Utf8,5=>DataType::LargeBinary,_=>unreachable!()}}
fn scalar(v:&Value,typ:u64)->ScalarValue{match typ{
 1=>ScalarValue::Boolean(v.as_bool()),2=>ScalarValue::Int64(v.as_i64()),3=>ScalarValue::Float64(v.as_str().map(|s|f64::from_bits(u64::from_str_radix(s,16).unwrap()))),
 4=>ScalarValue::Utf8(v.as_str().map(String::from)),5=>ScalarValue::LargeBinary(v.as_str().map(bytes)),_=>unreachable!()}}
fn key(v:&ScalarValue)->Value{match v{ScalarValue::Boolean(v)=>json!(v),ScalarValue::Int64(v)=>json!(v),ScalarValue::Float64(v)=>json!(v.map(|v|format!("{:016x}",v.to_bits()))),ScalarValue::Utf8(v)=>json!(v),ScalarValue::LargeBinary(v)=>json!(v.as_ref().map(|v|hex(v))),_=>unreachable!()}}
fn input_stream(rows:&Value,typ:u64)->SendableRecordBatchStream{
 let rows=rows.as_array().unwrap();let vals:Vec<_>=rows.iter().map(|r|scalar(&r["value"],typ)).collect();
 let values=if vals.is_empty(){new_null_array(&dtype(typ),0)}else{ScalarValue::iter_to_array(vals.clone()).unwrap()};
 let indices=arrow_ord::sort::sort_to_indices(values.as_ref(),Some(SortOptions{descending:false,nulls_first:true}),None).unwrap();
 let values=if vals.is_empty(){values}else{ScalarValue::iter_to_array(indices.values().iter().map(|i|vals[*i as usize].clone())).unwrap()};
 let ids=UInt64Array::from_iter_values(indices.values().iter().map(|i|rows[*i as usize]["id"].as_u64().unwrap()));
 let schema=Arc::new(Schema::new(vec![Field::new(VALUE_COLUMN_NAME,dtype(typ),true),Field::new(ROW_ID,DataType::UInt64,false)]));
 let batch=RecordBatch::try_new(schema.clone(),vec![values,Arc::new(ids)]).unwrap();
 let batches=(0..rows.len()).step_by(3).map(|i|batch.slice(i,3.min(rows.len()-i))).collect();
 Box::pin(MemoryStream{schema,batches})
}
fn bound(v:&Value,typ:u64)->Bound<ScalarValue>{if v.is_null(){Bound::Unbounded}else if v["included"]==true{Bound::Included(scalar(&v["value"],typ))}else{Bound::Excluded(scalar(&v["value"],typ))}}
fn query(v:&Value,typ:u64)->SargableQuery{match v["op"].as_str().unwrap(){"eq"=>SargableQuery::Equals(scalar(&v["value"],typ)),"in"=>SargableQuery::IsIn(v["values"].as_array().unwrap().iter().map(|v|scalar(v,typ)).collect()),"range"=>SargableQuery::Range(bound(&v["lower"],typ),bound(&v["upper"],typ)),"null"=>SargableQuery::IsNull(),"text"=>SargableQuery::FullTextSearch(()),"prefix"=>SargableQuery::LikePrefix(scalar(&v["value"],typ)),_=>unreachable!()}}
fn state(index:&BitmapIndex)->Value{
 let mut rows:Vec<_>=index.index_map.iter().map(|(k,i)|json!({"key":key(&k.0),"rows":index.postings[*i].0.iter().collect::<Vec<_>>()})).collect();
 rows.insert(0,json!({"key":null,"rows":index.null_map.0.iter().collect::<Vec<_>>()}));json!(rows)
}
async fn searches(index:&BitmapIndex,queries:&Value,typ:u64)->Value{
 let mut out=Vec::new();for q in queries.as_array().unwrap(){for track in [true,false]{
 match source::run_search(index,&query(q,typ),track).await {
 Ok(SearchResult::Exact(rows))=>out.push(json!({"selected":rows.selected.0.iter().collect::<Vec<_>>(),"nulls":rows.nulls.0.iter().collect::<Vec<_>>()})),
 Err(error)=>out.push(json!({"error":error.0})),
 }}}
 json!(out)
}
fn main(){
 let text=std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();let mut cases:Vec<Value>=serde_json::from_str(&text).unwrap();
 futures::executor::block_on(async{for row in &mut cases{
  let typ=row["type"].as_u64().unwrap();let old=BitmapIndex::from_file(source::run_build(input_stream(&row["old"],typ),None,&MemoryStore::default(),None).await.unwrap());
  let f=&row["filter"];let filter=if f.is_null(){None}else if let Some(ids)=f.get("rows"){Some(OldIndexDataFilter::RowIds(ids.as_array().unwrap().iter().map(|v|v.as_u64().unwrap()).collect()))}else{Some(OldIndexDataFilter::Fragments{to_keep:f["fragments"].as_array().unwrap().iter().map(|v|v.as_u64().unwrap()as u32).collect(),to_remove:RoaringBitmap::new()})};
  let updated=BitmapIndex::from_file(source::run_build(input_stream(&row["new"],typ),Some(&old),&MemoryStore::default(),filter.as_ref()).await.unwrap());
  let mapping=RowAddrRemap(row["mapping"].as_object().unwrap().iter().map(|(k,v)|(k.parse().unwrap(),v.as_u64())).collect());
  let remapped=source::run_remap(updated.state(&dtype(typ)),&mapping);
  let mut sorted:Vec<_>=remapped.into_iter().collect();sorted.sort_by(|(a,_),(b,_)|OrderableScalarValue(a.clone()).cmp(&OrderableScalarValue(b.clone())));
  let remapped=BitmapIndex::from_file(IndexFile{rows:sorted});
  let domain:Vec<_>=row["values"].as_array().unwrap().iter().map(|v|scalar(v,typ)).collect();
  let comparisons:Vec<_>=domain.iter().flat_map(|a|domain.iter().map(move|b|json!([OrderableScalarValue(a.clone()).cmp(&OrderableScalarValue(b.clone()))as i8,a==b]))).collect();
  row["results"]=json!({"old_state":state(&old),"new_state":state(&updated),"remap_state":state(&remapped),"old_search":searches(&old,&row["queries"],typ).await,"new_search":searches(&updated,&row["queries"],typ).await,"remap_search":searches(&remapped,&row["queries"],typ).await,"comparisons":comparisons});
 }});
 println!("{}",serde_json::to_string(&cases).unwrap());
}
