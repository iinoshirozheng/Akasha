
// In-memory page-reader adapter; original search/lookup/predicate bodies above.
pub fn paged(values:&[Value],t:u64,page_size:usize,query:&SargableQuery,track:bool)->Result<NullableRowAddrSet>{
 let mut rows:Vec<_>=values.iter().enumerate().map(|(i,v)|(OrderableScalarValue(scalar(v,t)),i as u64)).collect();
 rows.sort_by(|a,b|a.0.cmp(&b.0));
 let mut mins=Vec::new();let mut maxs=Vec::new();let mut counts=Vec::new();let mut leaves=Vec::new();
 let schema=Arc::new(Schema::new(vec![Field::new(BTREE_VALUES_COLUMN,dtype(t),true),Field::new(BTREE_IDS_COLUMN,DataType::UInt64,false)]));
 for chunk in rows.chunks(page_size){
  let arr=ScalarValue::iter_to_array(chunk.iter().map(|(v,_)|v.0.clone()))?;
  let ids=Arc::new(UInt64Array::from_iter_values(chunk.iter().map(|(_,id)|*id)));
  let batch=RecordBatch::try_new(schema.clone(),vec![arr,ids])?;
  let s=analyze_batch(&batch)?;mins.push(s.min);maxs.push(s.max);counts.push(s.null_count);
  leaves.push(Arc::new(FlatIndex{data:Arc::new(batch),df_schema:DFSchema::try_from(schema.clone())?,all_addrs_map:RowAddrTreeMap(chunk.iter().map(|(_,id)|*id).collect()),null_addrs_map:RowAddrTreeMap(chunk.iter().filter(|(v,_)|v.0.is_null()).map(|(_,id)|*id).collect())}));
 }
 let min_arr=if mins.is_empty(){new_null_array(&dtype(t),0)}else{ScalarValue::iter_to_array(mins)?};
 let max_arr=if maxs.is_empty(){new_null_array(&dtype(t),0)}else{ScalarValue::iter_to_array(maxs)?};
 let lookup_schema=Arc::new(Schema::new(vec![Field::new("min",dtype(t),true),Field::new("max",dtype(t),true),Field::new("null_count",DataType::UInt32,false),Field::new("page_idx",DataType::UInt32,false)]));
 let lookup=RecordBatch::try_new(lookup_schema,vec![min_arr,max_arr,Arc::new(UInt32Array::from(counts)),Arc::new(UInt32Array::from_iter_values(0..leaves.len() as u32))])?;
 let index=BTreeIndex{page_lookup:BTreeLookup::try_new(lookup)?,store:Arc::new(leaves),ranges_to_files:(),data_type:dtype(t)};
 let SearchResult::Exact(result)=futures::executor::block_on(index.search_with_options(query,SearchOptions(track),&Metrics))?;
 Ok(result)
}
