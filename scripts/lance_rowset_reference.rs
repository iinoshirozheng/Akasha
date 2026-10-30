// Adapter for finite/materialized rows. Nullable algorithm bodies are upstream.
use roaring::RoaringTreemap;
use serde_json::{json,Value};
#[derive(Clone,Debug,Default,PartialEq)] pub struct RowAddrTreeMap(RoaringTreemap);
#[allow(dead_code)] pub trait RowSetOps {}
impl RowAddrTreeMap {
    fn new()->Self {Self::default()}
    fn len(&self)->Option<u64>{Some(self.0.len())}
    fn is_empty(&self)->bool{self.0.is_empty()}
    fn contains(&self,id:u64)->bool{self.0.contains(id)}
    fn union_all(sets:&[&Self])->Self{Self(sets.iter().fold(RoaringTreemap::new(),|a,b|a|&b.0))}
}
macro_rules! ops {($trait:ident,$method:ident,$op:tt,$assign:ident,$amethod:ident)=>{
 impl std::ops::$trait<&Self> for RowAddrTreeMap {type Output=Self;fn $method(self,b:&Self)->Self{Self(self.0 $op &b.0)}}
 impl std::ops::$trait<Self> for RowAddrTreeMap {type Output=Self;fn $method(self,b:Self)->Self{Self(self.0 $op b.0)}}
 impl std::ops::$assign<&Self> for RowAddrTreeMap {fn $amethod(&mut self,b:&Self){self.0=self.0.clone() $op &b.0;}}
}}
ops!(BitAnd,bitand,&,BitAndAssign,bitand_assign);
ops!(BitOr,bitor,|,BitOrAssign,bitor_assign);
ops!(Sub,sub,-,SubAssign,sub_assign);
#[derive(Clone,Debug)] pub enum RowAddrMask{AllowList(RowAddrTreeMap),BlockList(RowAddrTreeMap)}
#[allow(dead_code,unused_imports)] mod nullable;
use nullable::{NullableRowAddrSet,NullableRowAddrMask};
fn ids(v:&Value)->Vec<u64>{v.as_array().unwrap().iter().map(|v|v.as_u64().unwrap()).collect()}
fn set(v:&Value)->RoaringTreemap{ids(v).into_iter().collect()}
fn mask(v:&Value)->NullableRowAddrMask{
    let rows=NullableRowAddrSet::new(RowAddrTreeMap(set(&v["selected"])),RowAddrTreeMap(set(&v["nulls"])));
    if v["block"]==true{NullableRowAddrMask::BlockList(rows)}else{NullableRowAddrMask::AllowList(rows)}
}
fn value(m:&NullableRowAddrMask,probe:&[u64])->Value{
    let (block,s)=match m{NullableRowAddrMask::AllowList(s)=>(false,s),NullableRowAddrMask::BlockList(s)=>(true,s)};
    json!({"block":block,"selected":s.selected_rows().0.iter().collect::<Vec<_>>(),"nulls":s.null_rows().0.iter().collect::<Vec<_>>(),"states":probe.iter().map(|id|if s.null_rows().contains(*id){2}else if m.selected(*id){1}else{0}).collect::<Vec<_>>()})
}
fn main(){
    let input=std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let mut corpus:Value=serde_json::from_str(&input).unwrap();
    for row in corpus["sets"].as_array_mut().unwrap(){
        let mut a=RoaringTreemap::new();
        let inserted:Vec<_>=ids(&row["a"]).into_iter().map(|id|a.insert(id)).collect();
        let b=set(&row["b"]);
        let mut results=serde_json::Map::new();
        for (name,s) in [("union",&a|&b),("intersection",&a & &b),("difference",&a-&b),("xor",&a^&b)] {
            results.insert(name.into(),json!(s.iter().collect::<Vec<_>>()));
        }
        let removed:Vec<_>=ids(&row["remove"]).into_iter().map(|id|a.remove(id)).collect();
        row["results"]=json!({"inserted":inserted,"removed":removed,"after":a.iter().collect::<Vec<_>>(),"ops":results});
    }
    for row in corpus["masks"].as_array_mut().unwrap(){
        let a=mask(&row["a"]);let b=mask(&row["b"]);let probe=ids(&row["probe"]);
        let (sa,sb)=match (&a,&b){(NullableRowAddrMask::AllowList(a)|NullableRowAddrMask::BlockList(a),NullableRowAddrMask::AllowList(b)|NullableRowAddrMask::BlockList(b))=>(a,b)};
        let union=NullableRowAddrSet::union_all(&[sa.clone(),sb.clone()]);
        row["results"]=json!({"and":value(&(a.clone()&b.clone()),&probe),"or":value(&(a.clone()|b.clone()),&probe),"not":value(&!a,&probe),"union_all":value(&NullableRowAddrMask::AllowList(union),&probe)});
    }
    println!("{}",serde_json::to_string(&corpus).unwrap());
}
