"""Unedited Qdrant numerical formula evaluator with transport/type adapters.

Geo/date operations are present in the copied match but deliberately unsupported
by this scalar oracle. Conditions are constant checkers. Payload/default values
and prefetch score maps exercise the original retrieval and short-circuit code.
Uses a release build: upstream decay debug_asserts can panic on nonfinite
intermediates; the production scorer handles them at the final F32 boundary.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"
BASE = "lib/segment/src/index/query_optimization/rescore_formula/"

SCAFFOLD = r'''
use std::collections::HashMap;
use std::ops::Neg;
type PreciseScore = f64;
type ScoreType = f32;
type PointOffsetType = u32;
type JsonPath = String;
type AHashMap<K,V> = HashMap<K,V>;
const DEFAULT_SCORE: f64 = 0.0;
const DEFAULT_DECAY_TARGET: f64 = 0.0;
const DEFAULT_DECAY_MIDPOINT: f32 = 0.5;
const DEFAULT_DECAY_SCALE: f32 = 1.0;
#[derive(Clone,Debug)] struct OrderedFloat<T>(T);
#[derive(Debug)] enum OperationError {
    NonFiniteNumber {expression:String},
    VariableTypeError {field_name:String, expected_type:String, description:String},
    Validation(String),
}
impl OperationError { fn validation_error(s:String)->Self {Self::Validation(s)} }
type OperationResult<T> = Result<T,OperationError>;
#[derive(Clone,Debug)] enum Value { Number(f64), String(String), Bool(bool), Array(Vec<Value>) }
impl Value {
    fn as_f64(&self)->Option<f64> {if let Self::Number(n)=self {Some(*n)} else {None}}
    fn as_str(&self)->Option<&str> {if let Self::String(s)=self {Some(s)} else {None}}
}
#[derive(Clone,Copy,Debug)] struct GeoPoint;
#[derive(Clone,Copy,Debug)] struct DateTimePayloadType;
impl DateTimePayloadType {fn timestamp(&self)->i64 {panic!("datetime outside scalar oracle")}}
impl std::str::FromStr for DateTimePayloadType {type Err=String; fn from_str(_: &str)->Result<Self,String>{Err("datetime outside scalar oracle".into())}}
struct Haversine;
impl Haversine {fn distance(&self,_:GeoPoint,_:GeoPoint)->f64 {panic!("geo outside scalar oracle")}}
mod serde_json {use super::*; pub fn from_value<T>(_:Value)->Result<T,String>{Err("geo outside scalar oracle".into())}}
#[derive(Clone,Debug,PartialEq,Eq,Hash)] enum VariableId {Score(usize),Payload(String),Condition(usize)}
#[derive(Clone,Debug)] enum DatetimeExpression {Constant(DateTimePayloadType),PayloadVariable(String)}
#[derive(Clone,Copy,Debug)] enum DecayKind {Lin,Exp,Gauss}
#[derive(Clone,Debug)] enum ParsedExpression {
    Constant(OrderedFloat<f64>), Variable(VariableId), GeoDistance{origin:GeoPoint,key:String}, Datetime(DatetimeExpression),
    Mult(Vec<Self>),Sum(Vec<Self>),Div{left:Box<Self>,right:Box<Self>,by_zero_default:Option<OrderedFloat<f64>>},
    Neg(Box<Self>),Sqrt(Box<Self>),Pow{base:Box<Self>,exponent:Box<Self>},Exp(Box<Self>),Log10(Box<Self>),Ln(Box<Self>),Abs(Box<Self>),
    Decay{kind:DecayKind,x:Box<Self>,target:Option<Box<Self>>,lambda:OrderedFloat<f64>},
}
struct Checker(bool);
impl Checker {fn check(&self,_:u32)->OperationResult<bool>{Ok(self.0)}}
type VariableRetrieverFn = Box<dyn Fn(u32)->Vec<Value>>;
struct FormulaScorer {
    formula:ParsedExpression, prefetches_scores:Vec<AHashMap<u32,f32>>,
    payload_retrievers:HashMap<String,VariableRetrieverFn>, condition_checkers:Vec<Checker>, defaults:HashMap<VariableId,Value>,
}
trait FriendlyName {fn friendly_name()->&'static str;}
impl FriendlyName for f64 {fn friendly_name()->&'static str{"number"}}
impl FriendlyName for GeoPoint {fn friendly_name()->&'static str{"geo point"}}
impl FriendlyName for DateTimePayloadType {fn friendly_name()->&'static str{"datetime"}}
'''


def bits(value, width=32):
    return struct.unpack('<I' if width == 32 else '<Q', struct.pack('<f' if width == 32 else '<d', value))[0]


def num(value, width=32):
    return f'f{width}::from_bits({bits(value, width)})'


def main():
    sources, functions = {}, {}
    def get(path, signature):
        text = subprocess.check_output(['rtk', 'proxy', 'git', '-C', str(ROOT/'reference/qdrant'),
                                        'show', f'{REVISION}:{path}'], text=True)
        sources[path] = hashlib.sha256(text.encode()).hexdigest()
        body = extract(text, signature)
        functions[signature] = dict(source=path, sha256=hashlib.sha256(body.encode()).hexdigest())
        return body
    methods = [get(BASE+'formula_scorer.rs', signature) for signature in (
        'pub fn score(', 'fn eval_expression(', 'fn get_payload_value(', 'fn get_parsed_payload_value<')]
    decays = [get(BASE+'formula_scorer.rs', 'fn '+name+'(') for name in ('exp_decay','gauss_decay','linear_decay')]
    parameter = get(BASE+'parsed_formula.rs','pub fn decay_params_to_lambda(')
    source = SCAFFOLD+'\nimpl FormulaScorer {\n'+'\n'.join(methods)+'\n}\n'
    source += 'impl ParsedExpression {\n'+parameter+'\n}\n'+'\n'.join(decays)

    cases = []
    def add(expr, **extra):
        cases.append(dict(expression=expr, payload={}, defaults={}, scores=[{'1':2.25},{'2':4.5}], **extra))
    for op in ('sum','mult'):
        for values in ([], [0], [1,-1,0], [1e30,1e30,-1e30], [16777216,1,-16777216]):
            add({op:values})
    for op in ('neg','abs','sqrt','exp','ln','log10'):
        for value in (0,-0.0,-1,1,2,1e-30,1e30,1000):
            add({op:value})
    for left,right in ((0,0),(1,0),(-1,-0.0),(1,3),(1e30,1e-30),(-2,0.5),(0,-1),(2,3)):
        add({'div':{'left':left,'right':right}})
        add({'div':{'left':left,'right':right,'by_zero_default':-7.25}})
        add({'pow':{'base':left,'exponent':right}})
    for op in ('lin_decay','exp_decay','gauss_decay'):
        for x in (-1e30,-3,0,0.5,2,1e30):
            for target in (None,1.25):
                params=dict(x=x,scale=2,midpoint=0.25)
                if target is not None: params['target']=target
                add({op:params})
    for expr in ('$score','$score[1]','$score[5]','missing','number','wrong',
                 {'mult':[0, 'missing']},{'mult':['missing',0]},
                 {'div':{'left':0,'right':'missing'}},{'sum':[0,'missing']},
                 {'mult':[{'mult':['large','large']},0]},
                 {'sum':['large','large',{'neg':'large'}]},
                 {'condition':True},{'condition':False}):
        add(expr)
        cases[-1]['payload']={'number':85.125,'wrong':'not numeric','large':1e308}
        cases[-1]['defaults']={'$score[1]':1.5,'$score[5]':'ignored','missing':6.25,'wrong':7}
    for expr in ('missing', {'mult':[0,'missing']}, {'mult':['missing',0]},
                 {'div':{'left':0,'right':'missing'}}, {'div':{'left':1,'right':0}}):
        add(expr)
    overflow = {'mult':['large','large']}
    nan = {'sum':[overflow, {'neg':overflow}]}
    for expr in (
        {'mult':[nan, 0]}, {'mult':[{'exp':overflow}, 0]},
        {'div':{'left':nan,'right':0,'by_zero_default':3}},
        {'pow':{'base':nan,'exponent':0}}, {'sqrt':{'neg':0.0}},
        {'lin_decay':{'x':overflow}}, {'lin_decay':{'x':nan}},
        {'lin_decay':{'x':overflow,'midpoint':1}},
        {'exp_decay':{'x':nan}}, {'gauss_decay':{'x':overflow}},
        {'lin_decay':{'x':overflow,'target':overflow}},
        {'mult':[{'sum':['large','large']},0]},
    ):
        add(expr);cases[-1]['payload']={'large':1e308}
    rng = random.Random(20261030)
    def tree(depth):
        if not depth or rng.random()<0.3: return rng.choice([0,-0.0,1,-2,0.25,1e-20,1e20,'$score','$score[1]','number'])
        op = rng.choice(['sum','mult','neg','abs','sqrt','exp','ln','log10','div','pow','lin_decay','exp_decay','gauss_decay'])
        if op in ('sum','mult'): return {op:[tree(depth-1) for _ in range(rng.randrange(4))]}
        if op in ('div','pow'):
            keys=('left','right') if op=='div' else ('base','exponent')
            return {op:{keys[0]:tree(depth-1),keys[1]:tree(depth-1)}}
        if op.endswith('_decay'): return {op:dict(x=tree(depth-1),target=tree(depth-1),scale=2,midpoint=0.5)}
        return {op:tree(depth-1)}
    for _ in range(160):
        add(tree(4));cases[-1]['payload']={'number':rng.uniform(-2,2)}

    def variable(key):
        if key=='$score': return 'VariableId::Score(0)'
        if key.startswith('$score['): return 'VariableId::Score('+key[7:-1]+')'
        return 'VariableId::Payload('+json.dumps(key)+'.into())'
    def value(v):
        if type(v) is bool: return 'Value::Bool('+str(v).lower()+')'
        if isinstance(v,str): return 'Value::String('+json.dumps(v)+'.into())'
        return 'Value::Number('+num(v,64)+')'
    def expression(e,conditions):
        if isinstance(e,(int,float)): return 'ParsedExpression::Constant(OrderedFloat(f64::from('+num(e)+')))'
        if isinstance(e,str): return 'ParsedExpression::Variable('+variable(e)+')'
        op,arg=next(iter(e.items()))
        if op=='condition':
            index=len(conditions);conditions.append(arg)
            return f'ParsedExpression::Variable(VariableId::Condition({index}))'
        if op in ('sum','mult'):
            return 'ParsedExpression::'+op.title()+'(vec!['+','.join(expression(x,conditions) for x in arg)+'])'
        if op in ('div','pow'):
            keys=('left','right') if op=='div' else ('base','exponent')
            rest=','+'by_zero_default:'+('Some(OrderedFloat(f64::from('+num(arg['by_zero_default'])+')))' if 'by_zero_default' in arg else 'None') if op=='div' else ''
            return 'ParsedExpression::'+op.title()+'{'+','.join(k+':Box::new('+expression(arg[k],conditions)+')' for k in keys)+rest+'}'
        if op.endswith('_decay'):
            kind={'lin_decay':'Lin','exp_decay':'Exp','gauss_decay':'Gauss'}[op]
            target='Some(Box::new('+expression(arg['target'],conditions)+'))' if 'target' in arg else 'None'
            return 'ParsedExpression::Decay{kind:DecayKind::'+kind+',x:Box::new('+expression(arg['x'],conditions)+'),target:'+target+',lambda:OrderedFloat(ParsedExpression::decay_params_to_lambda(Some('+num(arg.get('midpoint',0.5))+'),Some('+num(arg.get('scale',1))+'),DecayKind::'+kind+').unwrap())}'
        return 'ParsedExpression::'+{'log10':'Log10'}.get(op,op.title())+'(Box::new('+expression(arg,conditions)+'))'

    source+='\nfn main() {\n'
    for i,case in enumerate(cases):
        conditions=[]; expr=expression(case['expression'],conditions)
        source+=' { let mut scorer=FormulaScorer {formula:'+expr+',prefetches_scores:vec!['
        source+=','.join('['+','.join('('+id+','+num(score)+')' for id,score in scores.items())+'].into()' for scores in case['scores'])
        source+='],payload_retrievers:HashMap::new(),condition_checkers:vec!['+','.join('Checker('+str(v).lower()+')' for v in conditions)+'],defaults:['
        source+=','.join('('+variable(k)+','+value(v)+')' for k,v in case['defaults'].items())+'].into()};\n'
        for k,v in case['payload'].items():
            source+='scorer.payload_retrievers.insert('+json.dumps(k)+'.into(),Box::new(|_|vec!['+value(v)+']));\n'
        source+=f' match scorer.score(1) {{ Ok(score)=>println!("{i} {{}}",score.to_bits()), Err(_)=>println!("{i} ERROR") }}\n }}\n'
    source+='}\n'
    build=ROOT/'.build/qdrant-formula-reference';build.mkdir(parents=True,exist_ok=True)
    (build/'reference.rs').write_text(source)
    subprocess.run(['rtk','proxy','rustc','--edition=2024','-Awarnings','-C','opt-level=3',
                    '-C','debug-assertions=no',str(build/'reference.rs'),'-o',str(build/'reference')],check=True)
    for line in subprocess.check_output([str(build/'reference')],text=True).splitlines():
        i,result=line.split();cases[int(i)]['expected_bits']=None if result=='ERROR' else int(result)
    fixture=dict(revision=REVISION,sources=sources,functions=functions,
                 scaffold_sha256=hashlib.sha256(source.encode()).hexdigest(),
                 rustc_flags=['--edition=2024','-C','opt-level=3','-C','debug-assertions=no'],
                 adapter=__doc__,cases=cases)
    target=ROOT/'tests/fixtures/qdrant-formula';target.mkdir(parents=True,exist_ok=True)
    metadata={k:v for k,v in fixture.items() if k!='cases'}
    text=json.dumps(metadata,indent=2)[:-2]+',\n  "cases": [\n'
    text+=',\n'.join('    '+json.dumps(c,separators=(',',':')) for c in cases)+'\n  ]\n}\n'
    (target/'formula.json').write_text(text)
    print(json.dumps(dict(cases=len(cases),errors=sum(c['expected_bits'] is None for c in cases))))


if __name__=='__main__':
    main()
