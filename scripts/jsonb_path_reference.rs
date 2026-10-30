use jsonb::jsonpath::{parse_json_path, Path, Expr, PathValue, Index, ArrayIndex, RecursiveLevelEnd, BinaryOperator, UnaryOperator};
use jsonb::Number;
use serde_json::{Value, json};
use std::io::{self,Read};
fn node(k:u8,a:i64,b:i64,text:&str,bits:u64,children:Vec<Value>)->Value {json!([k,a,b,text,bits.to_string(),children])}
fn leaf(k:u8)->Value {node(k,0,0,"",0,vec![])}
fn idx(i:&Index)->Value {match i {Index::Index(v)=>node(16,0,*v as i64,"",0,vec![]),Index::LastIndex(v)=>node(16,1,*v as i64,"",0,vec![])}}
fn paths(p:&[Path<'_>])->Vec<Value> {p.iter().map(path).collect()}
fn path(p:&Path<'_>)->Value {match p {
 Path::Root=>leaf(0),Path::Current=>leaf(1),Path::DotWildcard=>leaf(2),Path::BracketWildcard=>leaf(4),
 Path::RecursiveDotWildcard(level)=>{let (a,b)=match level {None=>(-1,-1),Some(l)=>(l.start as i64,match l.end {None=>-1,Some(RecursiveLevelEnd::Last)=>256,Some(RecursiveLevelEnd::Index(v))=>v as i64})};node(3,a,b,"",0,vec![])},
 Path::DotField(s)=>node(5,0,0,s,0,vec![]),Path::ColonField(s)=>node(6,0,0,s,0,vec![]),Path::ObjectField(s)=>node(7,0,0,s,0,vec![]),
 Path::ArrayIndices(items)=>node(8,0,0,"",0,items.iter().map(|i|match i {ArrayIndex::Index(i)=>idx(i),ArrayIndex::Slice((a,b))=>node(17,0,0,"",0,vec![idx(a),idx(b)])}).collect()),
 Path::FilterExpr(e)=>node(9,0,0,"",0,vec![expr(e)]),Path::Expr(e)=>node(10,0,0,"",0,vec![expr(e)]),
}}
fn op(o:&BinaryOperator)->i64 {match o {BinaryOperator::And=>0,BinaryOperator::Or=>1,BinaryOperator::Eq=>2,BinaryOperator::NotEq=>3,BinaryOperator::Lt=>4,BinaryOperator::Lte=>5,BinaryOperator::Gt=>6,BinaryOperator::Gte=>7,BinaryOperator::StartsWith=>8,BinaryOperator::Add=>9,BinaryOperator::Subtract=>10,BinaryOperator::Multiply=>11,BinaryOperator::Divide=>12,BinaryOperator::Modulo=>13}}
fn expr(e:&Expr<'_>)->Value {match e {
 Expr::Paths(p)=>node(11,0,0,"",0,paths(p)),Expr::ExistsFunc(p)=>node(15,0,0,"",0,paths(p)),
 Expr::BinaryOp{op:o,left,right}=>node(13,op(o),0,"",0,vec![expr(left),expr(right)]),
 Expr::UnaryOp{op,operand}=>node(14,if *op==UnaryOperator::Add {0}else{1},0,"",0,vec![expr(operand)]),
 Expr::Value(v)=>match v.as_ref(){PathValue::Null=>leaf(12),PathValue::Boolean(v)=>node(12,1,0,"",u64::from(*v),vec![]),PathValue::String(v)=>node(12,5,0,v,0,vec![]),PathValue::Number(v)=>match v {Number::Int64(v)=>node(12,2,0,"",*v as u64,vec![]),Number::UInt64(v)=>node(12,3,0,"",*v,vec![]),Number::Float64(v)=>node(12,4,0,"",v.to_bits(),vec![]),_=>panic!("unexpected parser numeric type")},_=>panic!("unexpected parser raw value")}
}}
fn main(){
 std::panic::set_hook(Box::new(|_|{}));
 let mut text=String::new();io::stdin().read_to_string(&mut text).unwrap();let inputs:Vec<String>=serde_json::from_str(&text).unwrap();
 let rows:Vec<_>=inputs.into_iter().map(|hex|{
  let raw:Vec<u8>=hex.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect();
  let result=std::panic::catch_unwind(||match parse_json_path(&raw){Ok(p)=>json!({"ast":paths(&p.paths),"predicate":p.is_predicate()}),Err(_)=>json!({"error":true})});
  let mut result=result.unwrap_or_else(|_|json!({"panic":true}));result["hex"]=json!(hex);result
 }).collect();
 println!("{}",serde_json::to_string_pretty(&rows).unwrap());
}
