// Lance function bodies in source.rs remain unchanged; adapters live here.
use std::{any::Any,collections::{BTreeSet,HashSet},cmp::Ordering,ops::Bound,sync::Arc};
use arrow_array::{Array,ArrayRef,BooleanArray,RecordBatch,UInt64Array,UInt32Array,new_null_array};
use arrow_schema::{DataType,Field,Schema,SortOptions};
use datafusion_common::{ScalarValue,Column,DFSchema};
use datafusion_expr::{Expr,expr::Like,execution_props::ExecutionProps};
use datafusion_physical_expr::{PhysicalExpr,create_physical_expr};
use serde_json::{Value,json};
type Result<T>=std::result::Result<T,Error>;
#[derive(Debug)] pub struct Error(String);
impl Error {fn internal(s:impl Into<String>)->Self{Self(s.into())} fn invalid_input(s:impl Into<String>)->Self{Self(s.into())}}
impl From<arrow_schema::ArrowError> for Error{fn from(e:arrow_schema::ArrowError)->Self{Self(e.to_string())}}
impl From<datafusion_common::DataFusionError> for Error{fn from(e:datafusion_common::DataFusionError)->Self{Self(e.to_string())}}
trait OptionExt<T>{fn expect_ok(self)->Result<T>;}
impl<T> OptionExt<T> for Option<T>{fn expect_ok(self)->Result<T>{self.ok_or_else(||Error("required field missing".into()))}}
use arrow_ord::ord::make_comparator;
use futures::{stream,StreamExt,TryStreamExt,FutureExt};
macro_rules! debug {($($arg:tt)*)=>{}}
const VALUE_COLUMN_NAME:&str="values";
const BTREE_IDS_COLUMN:&str="row_ids";
fn get_num_compute_intensive_cpus()->usize{1}
struct SearchOptions(bool);
impl SearchOptions{fn track_nulls(&self)->bool{self.0}}
enum SearchResult{Exact(NullableRowAddrSet)}
#[derive(Clone)] struct LazyIndexReader(Arc<Vec<Arc<FlatIndex>>>);
impl LazyIndexReader{fn new(store:Arc<Vec<Arc<FlatIndex>>>,_:())->Self{Self(store)}}
mod arrow {pub mod compute {pub use arrow_arith::boolean::is_null;}}
const BTREE_VALUES_COLUMN:&str="values";
const IDS_COL_IDX:usize=1;
trait AnyQuery:Send+Sync {fn as_any(&self)->&dyn Any;}
#[allow(dead_code)] enum SargableQuery{Equals(ScalarValue),Range(Bound<ScalarValue>,Bound<ScalarValue>),IsIn(Vec<ScalarValue>),IsNull(),FullTextSearch(TextQuery),LikePrefix(ScalarValue)}
struct TextQuery{query:String}
impl AnyQuery for SargableQuery{fn as_any(&self)->&dyn Any{self}}
trait MetricsCollector:Send+Sync{fn record_comparisons(&self,n:usize);}
struct Metrics;
impl MetricsCollector for Metrics{fn record_comparisons(&self,_:usize){}}
#[derive(Clone,Default)] struct RowAddrTreeMap(BTreeSet<u64>);
impl std::ops::Sub<&RowAddrTreeMap> for RowAddrTreeMap{type Output=Self;fn sub(self,rhs:&Self)->Self{Self(self.0.difference(&rhs.0).copied().collect())}}
impl RowAddrTreeMap{fn union_all(sets:&[&Self])->Self{Self(sets.iter().flat_map(|s|s.0.iter().copied()).collect())} fn from_sorted_iter(v:impl Iterator<Item=u64>)->Result<Self>{Ok(Self(v.collect()))}}
struct NullableRowAddrSet{selected:RowAddrTreeMap,nulls:RowAddrTreeMap}
impl NullableRowAddrSet{fn selected_rows(&self)->&RowAddrTreeMap{&self.selected} fn union_all(sets:&[Self])->Self{let selected:BTreeSet<u64>=sets.iter().flat_map(|s|s.selected.0.iter().copied()).collect();let true_rows:BTreeSet<u64>=sets.iter().flat_map(|s|s.selected.0.difference(&s.nulls.0).copied()).collect();let nulls:BTreeSet<u64>=sets.iter().flat_map(|s|s.nulls.0.iter().copied()).filter(|v|!true_rows.contains(v)).collect();Self::new(RowAddrTreeMap(selected),RowAddrTreeMap(nulls))} fn new(selected:RowAddrTreeMap,nulls:RowAddrTreeMap)->Self{Self{selected,nulls}} fn empty()->Self{Self::new(Default::default(),Default::default())}}
struct FlatIndex{data:Arc<RecordBatch>,all_addrs_map:RowAddrTreeMap,null_addrs_map:RowAddrTreeMap,df_schema:DFSchema}
mod source;
fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn dtype(t:u64)->DataType{match t{1=>DataType::Boolean,2=>DataType::Int64,3=>DataType::Float64,4=>DataType::Utf8,5=>DataType::LargeBinary,_=>unreachable!()}}
fn scalar(v:&Value,t:u64)->ScalarValue{match t{1=>ScalarValue::Boolean(v.as_bool()),2=>ScalarValue::Int64(v.as_i64()),3=>ScalarValue::Float64(v.as_str().map(|s|f64::from_bits(u64::from_str_radix(s,16).unwrap()))),4=>ScalarValue::Utf8(v.as_str().map(String::from)),5=>ScalarValue::LargeBinary(v.as_str().map(bytes)),_=>unreachable!()}}
fn bound(v:&Value,t:u64)->Bound<ScalarValue>{if v.is_null(){Bound::Unbounded}else{let k=scalar(&v["value"],t);if v["included"]==true{Bound::Included(k)}else{Bound::Excluded(k)}}}
fn query(v:&Value,t:u64)->SargableQuery{match v["op"].as_str().unwrap(){"null"=>SargableQuery::IsNull(),"eq"=>SargableQuery::Equals(scalar(&v["value"],t)),"in"=>SargableQuery::IsIn(v["values"].as_array().unwrap().iter().map(|v|scalar(v,t)).collect()),"range"=>SargableQuery::Range(bound(&v["lower"],t),bound(&v["upper"],t)),_=>unreachable!()}}
fn main(){
 let input:Vec<Value>=serde_json::from_slice(&std::fs::read(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
 let mut output=Vec::new();
 for case in input {
  let t=case["type"].as_u64().unwrap();let values=case["values"].as_array().unwrap();
  let arr=if values.is_empty(){new_null_array(&dtype(t),0)}else{ScalarValue::iter_to_array(values.iter().map(|v|scalar(v,t))).unwrap()};
  let schema=Arc::new(Schema::new(vec![Field::new("values",dtype(t),true),Field::new("row_ids",DataType::UInt64,false)]));
  let batch=RecordBatch::try_new(schema.clone(),vec![arr,Arc::new(UInt64Array::from_iter_values(0..values.len() as u64))]).unwrap();
  let flat=FlatIndex{data:Arc::new(batch),df_schema:DFSchema::try_from(schema).unwrap(),all_addrs_map:RowAddrTreeMap((0..values.len() as u64).collect()),null_addrs_map:RowAddrTreeMap(values.iter().enumerate().filter(|(_,v)|v.is_null()).map(|(i,_)|i as u64).collect())};
  let mut queries=Vec::new();
  for q in case["queries"].as_array().unwrap(){let mut results=Vec::new();for track in [false,true]{let result=flat.search(&query(q,t),track,&Metrics).unwrap();results.push(json!({"selected":result.selected.0,"nulls":result.nulls.0}));}let mut paged=Vec::new();for page_size in [1,3,7]{let mut runs=Vec::new();for track in [false,true]{let result=source::paged(values,t,page_size,&query(q,t),track).unwrap();runs.push(json!({"selected":result.selected.0,"nulls":result.nulls.0}));}paged.push(runs);}queries.push(json!({"query":q,"results":results,"paged":paged}));}
  output.push(json!({"type":t,"values":values,"queries":queries}));
 }
 println!("{}",serde_json::to_string(&output).unwrap());
}
