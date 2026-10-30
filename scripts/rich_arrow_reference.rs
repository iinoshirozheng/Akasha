// Reference-only executable. Calls the pinned, unmodified Arrow and Lance
// implementations; no Akasha implementation is linked into this oracle.
use std::{fs::File, sync::Arc};
use arrow_array::*;
use arrow_buffer::{NullBuffer, OffsetBuffer, ScalarBuffer};
use arrow_schema::{DataType, Field, Schema};
use arrow_json::writer::{WriterBuilder, JsonArray};
mod lance_list;
mod lance_struct;
use lance_list::ListArrayExt;
use lance_struct::StructArrayExt;

fn json(batch: &RecordBatch) -> Vec<u8> {
    let mut writer = WriterBuilder::new().with_explicit_nulls(true)
        .build::<_, JsonArray>(Vec::new());
    writer.write(batch).unwrap();
    writer.finish().unwrap();
    writer.into_inner()
}

fn main() {
    let target = std::env::args().nth(1).unwrap();
    let mut columns: Vec<(String, ArrayRef)> = vec![];
    macro_rules! column { ($name:expr, $value:expr) => {
        columns.push((format!("payload.{}", $name), Arc::new($value)));
    }; }
    macro_rules! integers { ($name:expr, $array:ty, $primitive:ty) => {
        column!($name, <$array>::from(vec![Some(<$primitive>::MIN), None,
            Some(<$primitive>::MAX), Some(0)]));
    }; }
    integers!("i8", Int8Array, i8);
    integers!("i16", Int16Array, i16);
    integers!("i32", Int32Array, i32);
    integers!("i64", Int64Array, i64);
    integers!("u8", UInt8Array, u8);
    integers!("u16", UInt16Array, u16);
    integers!("u32", UInt32Array, u32);
    integers!("u64", UInt64Array, u64);
    column!("f32", Float32Array::from(vec![Some(-0.0), None, Some(1.5), Some(16777216.0)]));
    column!("f64", Float64Array::from(vec![Some(-0.0), None, Some(1.5), Some(f64::MAX)]));
    column!("bool", BooleanArray::from(vec![Some(true), None, Some(false), Some(true)]));
    column!("text", StringArray::from(vec![Some(""), None, Some("中文\0😀"), Some("e\u{301}")]));
    column!("large_text", LargeStringArray::from(vec![Some("字"), None, Some(""), Some("\0")]));
    column!("null", NullArray::new(4));

    let floats: ArrayRef = Arc::new(Float64Array::from(vec![99.0, 1.5, f64::NAN, f64::INFINITY, 4.5, 99.0]).slice(1, 4));
    let list = ListArray::new(Arc::new(Field::new("item", DataType::Float64, true)),
        OffsetBuffer::new(ScalarBuffer::from(vec![0i32, 1, 3, 3, 4])), floats,
        Some(NullBuffer::from(vec![true, false, true, true])));
    let filtered = list.filter_garbage_nulls();
    assert_eq!(filtered.value_offsets(), &[0, 1, 1, 1, 2]);
    let one = |a: ArrayRef| RecordBatch::try_from_iter([("x", a)]).unwrap();
    assert_eq!(json(&one(Arc::new(list.clone()))), json(&one(Arc::new(filtered))));
    let sliced = list.slice(1, 3);
    let trimmed = ListArray::new(Arc::new(Field::new("item", DataType::Float64, true)),
        sliced.trimmed_offsets(), sliced.trimmed_values(), sliced.nulls().cloned());
    assert_eq!(json(&one(Arc::new(sliced))), json(&one(Arc::new(trimmed))));
    column!("list", list);

    let strings: ArrayRef = Arc::new(StringArray::from(vec![Some("ignored"), Some("α"), None, Some("β"), Some("")]).slice(1, 4));
    column!("large_list", LargeListArray::new(Arc::new(Field::new("item", DataType::Utf8, true)),
        OffsetBuffer::new(ScalarBuffer::from(vec![0i64, 2, 2, 3, 4])), strings, None));

    let required = Arc::new(Field::new("required", DataType::Int64, false));
    let required_values: ArrayRef = Arc::new(Int64Array::from(vec![Some(99), Some(7), None, Some(9), Some(10), Some(99)]).slice(1, 4));
    let object = StructArray::try_new(vec![required.clone()].into(), vec![required_values.clone()],
        Some(NullBuffer::from(vec![true, false, true, true]))).unwrap();
    assert!(StructArray::try_new(vec![required.clone()].into(), vec![required_values.clone()], None).is_err());
    let pushed = object.pushdown_nulls().unwrap();
    assert_eq!(json(&one(Arc::new(object.clone()))), json(&one(Arc::new(pushed))));
    let normalized = object.normalize_slicing().unwrap();
    assert_eq!(json(&one(Arc::new(object.clone()))), json(&one(Arc::new(normalized))));
    column!("object", object.clone());
    column!("nested", ListArray::new(Arc::new(Field::new("item", object.data_type().clone(), true)),
        OffsetBuffer::new(ScalarBuffer::from(vec![0i32, 2, 2, 3, 4])), Arc::new(object), None));
    column!("fixed_required", FixedSizeListArray::try_new(required.clone(), 1, required_values.clone(),
        Some(NullBuffer::from(vec![true, false, true, true]))).unwrap());
    assert!(FixedSizeListArray::try_new(required, 1, required_values, None).is_err());
    column!("fixed_masked", FixedSizeListArray::new(Arc::new(Field::new("item", DataType::Float64, false)), 2,
        Arc::new(Float64Array::from(vec![1., 2., f64::NAN, f64::INFINITY, 3., 4., 5., 6.])),
        Some(NullBuffer::from(vec![true, false, true, true]))));
    column!("empty_object", StructArray::try_new_with_length(Vec::<Field>::new().into(), vec![], None, 4).unwrap());
    column!("empty_fixed", FixedSizeListArray::try_new_with_length(Arc::new(Field::new("item", DataType::Int64, true)),
        0, Arc::new(Int64Array::from(Vec::<i64>::new())), None, 4).unwrap());

    let fields: Vec<Field> = columns.iter().map(|(name, array)| Field::new(name, array.data_type().clone(), true)).collect();
    let schema = Arc::new(Schema::new(fields));
    let batch = RecordBatch::try_new(schema.clone(), columns.into_iter().map(|(_, a)| a).collect()).unwrap();
    let mut writer = arrow_ipc::writer::StreamWriter::try_new(File::create(format!("{target}/values.arrow")).unwrap(), &schema).unwrap();
    writer.write(&batch).unwrap();
    writer.finish().unwrap();
    let expected: serde_json::Value = serde_json::from_slice(&json(&batch)).unwrap();
    std::fs::write(format!("{target}/expected.json"), serde_json::to_string_pretty(&expected).unwrap() + "\n").unwrap();
    println!("{} rows × {} columns; Lance null/trim/struct and Arrow required-child checks passed", batch.num_rows(), batch.num_columns());
}
