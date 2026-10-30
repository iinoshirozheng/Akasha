// Calls the complete, unchanged pinned Lance json.rs module.
use arrow_array::{Array, ArrayRef, RecordBatch, StringArray, LargeStringArray, StructArray, ListArray, LargeListArray, FixedSizeListArray, MapArray, Int64Array};
use arrow_buffer::{OffsetBuffer, NullBuffer};
use arrow_schema::{DataType, Field, Schema};
use std::{sync::Arc, fs::File, path::Path};
use serde_json::json;
pub const ARROW_EXT_NAME_KEY: &str = "ARROW:extension:name";
#[allow(dead_code)]
#[path = "lance_json.rs"] mod lance_json;

fn field(name: &str, dtype: DataType, nullable: bool) -> Field {
    Field::new(name, dtype, nullable).with_metadata([("user".into(),format!("metadata-{name}"))].into())
}
fn write(path: &Path, batch: &RecordBatch) {
    let mut writer=arrow_ipc::writer::FileWriter::try_new(File::create(path).unwrap(), &batch.schema()).unwrap();
    writer.write(batch).unwrap(); writer.finish().unwrap();
}
fn main() {
    let dir=std::env::args().nth(1).unwrap(); let dir=Path::new(&dir);
    let mut records=vec![];
    for large in [false,true] {
        let values=[Some("'discard'"),None,Some("null"),Some("{z:[NaN,,],a:'漢字😀'}"),Some("0.5"),Some("'tail'")];
        let leaf:ArrayRef=if large { Arc::new(LargeStringArray::from(values.to_vec())) } else { Arc::new(StringArray::from(values.to_vec())) };
        let leaf=leaf.slice(1,4);
        let mut item=field("V",leaf.data_type().clone(),true);
        item.metadata_mut().insert(ARROW_EXT_NAME_KEY.into(),"arrow.json".into());
        item.metadata_mut().insert("ARROW:extension:metadata".into(),"{}".into());
        let item=Arc::new(item);
        let keys=Arc::new(Int64Array::from(vec![9,9,1,1])) as ArrayRef;
        let entries=StructArray::new(vec![Arc::new(field("K",DataType::Int64,false)), item.clone()].into(),vec![keys,leaf.clone()],None);
        let entry_field=Arc::new(field("pairs",entries.data_type().clone(),false));
        let arrays:Vec<(&str,ArrayRef)>=vec![
            ("scalar",leaf.clone()),
            ("struct",Arc::new(StructArray::new(vec![item.clone()].into(),vec![leaf.clone()],Some(NullBuffer::from(vec![true,false,true,true]))))),
            ("list",Arc::new(ListArray::new(item.clone(),OffsetBuffer::new(vec![0i32,2,4].into()),leaf.clone(),None))),
            ("large-list",Arc::new(LargeListArray::new(item.clone(),OffsetBuffer::new(vec![0i64,2,4].into()),leaf.clone(),None))),
            ("fixed",Arc::new(FixedSizeListArray::new(item.clone(),2,leaf.clone(),None))),
            ("map",Arc::new(MapArray::new(entry_field,OffsetBuffer::new(vec![0i32,2,4].into()),entries,None,false))),
        ];
        for (kind,array) in arrays {
            let name=format!("{}-{kind}",if large {"large"} else {"utf8"});
            let root=if kind=="scalar" {item.as_ref().clone().with_name("data")} else {field("data",array.data_type().clone(),true)};
            let schema=Arc::new(Schema::new_with_metadata(vec![root],[("schema-user".into(),"retained".into())].into()));
            let input=RecordBatch::try_new(schema,vec![array]).unwrap();
            let binary=lance_json::convert_json_columns(&input).unwrap();
            let text=lance_json::convert_lance_json_to_arrow(&binary).unwrap();
            for (suffix,batch) in [("input",&input),("binary",&binary),("text",&text)] {write(&dir.join(format!("{name}-{suffix}.arrow")),batch);}
            records.push(json!({"name":name,"rows":input.num_rows()}));
        }
    }
    println!("{}",serde_json::to_string_pretty(&records).unwrap());
}
