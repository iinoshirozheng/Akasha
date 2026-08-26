from akasha import (
    BatchMutation,
    DocumentField,
    DocumentRecord,
    FieldProjection,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)
from akasha.index.flat import SearchResult
from std.os import abort
from std.python import Python, PythonObject
from std.python.bindings import PythonModuleBuilder


struct BoundCollection(Movable, Writable):
    var inner: Optional[PersistentCollection]

    def __init__(out self):
        self.inner = Optional[PersistentCollection]()

    def write_to(self, mut writer: Some[Writer]):
        writer.write("AkashaCollection")

    def write_repr_to(self, mut writer: Some[Writer]):
        writer.write("AkashaCollection()")

    @staticmethod
    def py_init(
        out self: BoundCollection,
        args: PythonObject,
        kwargs: PythonObject,
    ) raises:
        self = BoundCollection()
        if len(args) != 2:
            raise Error("Collection(path, dimension) requires two arguments")
        var path = String(py=args[0])
        var dimension = Int(py=args[1])
        self.inner = Optional(PersistentCollection.open(path, dimension))

    @staticmethod
    def close(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        if Bool(self[].inner):
            self[].inner.value().close()
            self[].inner = Optional[PersistentCollection]()
        return Python.none()

    @staticmethod
    def last_sequence(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        return PythonObject(self[].inner.value().last_sequence())

    @staticmethod
    def upsert(
        py_self: PythonObject, id: PythonObject, vector: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(vector)
        self[].inner.value().upsert(Int(py=id), values^)
        return Python.none()

    @staticmethod
    def upsert_document(
        py_self: PythonObject,
        id: PythonObject,
        vector: PythonObject,
        fields: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(vector)
        var mojo_fields = _document_fields(fields)
        self[].inner.value().upsert_document(Int(py=id), values^, mojo_fields^)
        return Python.none()

    @staticmethod
    def apply_batch(
        py_self: PythonObject, mutations: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var batch = List[BatchMutation](capacity=len(mutations))
        for item in mutations:
            var operation = String(py=item["operation"])
            var id = Int(py=item["id"])
            if operation == "delete":
                batch.append(BatchMutation.delete(id))
            elif operation == "upsert":
                var values = _float_vector(item["vector"])
                var fields = _document_fields(item.get("fields", Python.list()))
                batch.append(
                    BatchMutation.document_upsert(id, values^, fields^)
                )
            else:
                raise Error("unknown batch mutation operation")
        var committed = self[].inner.value().apply_batch(batch)
        return Python.dict(
            first_sequence=PythonObject(committed.first_sequence),
            last_sequence=PythonObject(committed.last_sequence),
            count=PythonObject(committed.count),
        )

    @staticmethod
    def upsert_sparse(
        py_self: PythonObject, id: PythonObject, elements: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var sparse = _sparse_vector(elements)
        self[].inner.value().upsert_sparse(Int(py=id), sparse^)
        return Python.none()

    @staticmethod
    def delete(py_self: PythonObject, id: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        self[].inner.value().delete(Int(py=id))
        return Python.none()

    @staticmethod
    def flush(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        self[].inner.value().flush()
        return Python.none()

    @staticmethod
    def get(py_self: PythonObject, id: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var record = self[].inner.value().get(Int(py=id))
        if not Bool(record):
            return Python.none()
        var fields = Python.list()
        for index in range(len(record.value().fields)):
            fields.append(_field_to_python(record.value().fields[index]))
        var vector = Python.list()
        for value in record.value().vector:
            vector.append(value)
        return Python.dict(
            id=PythonObject(record.value().id),
            sequence=PythonObject(record.value().sequence),
            vector=vector,
            fields=fields,
        )

    @staticmethod
    def get_projected(
        py_self: PythonObject,
        id: PythonObject,
        projection: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var names = List[String]()
        for item in projection["fields"]:
            names.append(String(py=item))
        var requested = FieldProjection(
            Bool(py=projection["include_vector"]),
            Bool(py=projection["all_fields"]),
            names^,
        )
        var record = self[].inner.value().get_projected(Int(py=id), requested)
        return _document_to_python(record)

    @staticmethod
    def apply_arrow_batch(
        py_self: PythonObject, descriptor: PythonObject
    ) raises -> PythonObject:
        """Consume validated Arrow-owned buffers without Python list staging."""
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var row_count = Int(py=descriptor["row_count"])
        if row_count <= 0 or row_count > 65_536:
            raise Error("Arrow batch row count is invalid")
        var ids = descriptor["ids"]
        var vectors = descriptor["vectors"]
        var dimension = self[].inner.value().dimension
        if len(ids) != row_count or len(vectors) != row_count * dimension:
            raise Error("Arrow primitive buffer length mismatch")

        var mutations = List[BatchMutation](capacity=row_count)
        var sparse_rows = List[List[SparseElement]](capacity=row_count)
        var has_sparse = Bool(py=descriptor["has_sparse"])
        var sparse_offsets = descriptor["sparse_offsets"]
        var sparse_terms = descriptor["sparse_terms"]
        var sparse_weights = descriptor["sparse_weights"]
        var sparse_value_base = Int(py=descriptor["sparse_value_base"])
        if has_sparse and len(sparse_offsets) != row_count + 1:
            raise Error("Arrow sparse offsets length mismatch")

        for row in range(row_count):
            var vector = List[Float32](capacity=dimension)
            for column in range(dimension):
                vector.append(Float32(py=vectors[row * dimension + column]))
            var fields = List[DocumentField]()
            for payload in descriptor["payloads"]:
                var raw = payload["values"][row].as_py()
                if Bool(py=raw == Python.none()):
                    continue
                fields.append(
                    DocumentField(
                        String(py=payload["name"]),
                        _payload_value(String(py=payload["type"]), raw),
                    )
                )
            mutations.append(
                BatchMutation.document_upsert(
                    Int(py=ids[row]), vector^, fields^
                )
            )

            var sparse = List[SparseElement]()
            if has_sparse:
                var begin = Int(py=sparse_offsets[row]) - sparse_value_base
                var end = Int(py=sparse_offsets[row + 1]) - sparse_value_base
                if begin < 0 or end < begin or end > len(sparse_terms):
                    raise Error("Arrow sparse offsets are invalid")
                if len(sparse_terms) != len(sparse_weights):
                    raise Error("Arrow sparse value buffers are misaligned")
                for index in range(begin, end):
                    sparse.append(
                        SparseElement(
                            Int(py=sparse_terms[index]),
                            Float32(py=sparse_weights[index]),
                        )
                    )
            sparse_rows.append(sparse^)

        # PersistentCollection performs complete batch validation before WAL
        # sequence allocation. Sparse rows have also been fully materialized.
        _ = self[].inner.value().apply_batch(mutations)
        if has_sparse:
            for row in range(row_count):
                if len(sparse_rows[row]) != 0:
                    self[].inner.value().upsert_sparse(
                        Int(py=ids[row]), sparse_rows[row]
                    )
        return PythonObject(row_count)

    @staticmethod
    def search_dot(
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(query)
        return _results_to_python(
            self[].inner.value().search_dot(values, Int(py=k))
        )

    @staticmethod
    def search_l2(
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(query)
        return _results_to_python(
            self[].inner.value().search_l2(values, Int(py=k))
        )

    @staticmethod
    def search_cosine(
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(query)
        return _results_to_python(
            self[].inner.value().search_cosine(values, Int(py=k))
        )

    @staticmethod
    def search_batch(
        py_self: PythonObject,
        metric: PythonObject,
        queries: PythonObject,
        k: PythonObject,
        num_workers: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var metric_name = String(py=metric)
        var vectors = _float_vectors(queries)
        var count = Int(py=k)
        var workers = Int(py=num_workers)
        var results: List[List[SearchResult]]
        if metric_name == "dot":
            results = (
                self[]
                .inner.value()
                .search_dot_batch(vectors, count, num_workers=workers)
            )
        elif metric_name == "l2":
            results = (
                self[]
                .inner.value()
                .search_l2_batch(vectors, count, num_workers=workers)
            )
        elif metric_name == "cosine":
            results = (
                self[]
                .inner.value()
                .search_cosine_batch(vectors, count, num_workers=workers)
            )
        else:
            raise Error("unknown dense metric")
        var output = Python.list()
        for query_results in results:
            output.append(_results_to_python(query_results))
        return output

    @staticmethod
    def search_batch_where(
        py_self: PythonObject,
        metric: PythonObject,
        queries: PythonObject,
        filters: PythonObject,
        k: PythonObject,
        num_workers: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var metric_name = String(py=metric)
        var vectors = _float_vectors(queries)
        var expressions = List[FilterExpression](capacity=len(filters))
        for item in filters:
            expressions.append(_filter_expression(item))
        var count = Int(py=k)
        var workers = Int(py=num_workers)
        var results: List[List[SearchResult]]
        if metric_name == "dot":
            results = (
                self[]
                .inner.value()
                .search_dot_where_batch(
                    vectors,
                    expressions,
                    count,
                    num_workers=workers,
                )
            )
        elif metric_name == "l2":
            results = (
                self[]
                .inner.value()
                .search_l2_where_batch(
                    vectors,
                    expressions,
                    count,
                    num_workers=workers,
                )
            )
        elif metric_name == "cosine":
            results = (
                self[]
                .inner.value()
                .search_cosine_where_batch(
                    vectors,
                    expressions,
                    count,
                    num_workers=workers,
                )
            )
        else:
            raise Error("unknown dense metric")
        var output = Python.list()
        for query_results in results:
            output.append(_results_to_python(query_results))
        return output

    @staticmethod
    def search_approx(
        py_self: PythonObject,
        metric: PythonObject,
        query: PythonObject,
        k: PythonObject,
        ef_search: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var metric_name = String(py=metric)
        var values = _float_vector(query)
        var count = Int(py=k)
        var ef = Int(py=ef_search)
        if metric_name == "dot":
            return _results_to_python(
                self[].inner.value().search_dot_approx(values, count, ef)
            )
        if metric_name == "l2":
            return _results_to_python(
                self[].inner.value().search_l2_approx(values, count, ef)
            )
        if metric_name == "cosine":
            return _results_to_python(
                self[].inner.value().search_cosine_approx(values, count, ef)
            )
        raise Error("unknown dense metric")

    @staticmethod
    def search_sparse(
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var sparse = _sparse_vector(query)
        return _results_to_python(
            self[].inner.value().search_sparse_dot(sparse, Int(py=k))
        )

    @staticmethod
    def search_hybrid(
        py_self: PythonObject,
        metric: PythonObject,
        dense_query: PythonObject,
        sparse_query: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var metric_name = String(py=metric)
        var dense = _float_vector(dense_query)
        var sparse = _sparse_vector(sparse_query)
        var k = Int(py=options["k"])
        var fetch_k = Int(py=options["fetch_k"])
        var rank_constant = Int(py=options["rank_constant"])
        if metric_name == "dot":
            return _results_to_python(
                self[]
                .inner.value()
                .search_hybrid_dot(dense, sparse, k, fetch_k, rank_constant)
            )
        if metric_name == "l2":
            return _results_to_python(
                self[]
                .inner.value()
                .search_hybrid_l2(dense, sparse, k, fetch_k, rank_constant)
            )
        if metric_name == "cosine":
            return _results_to_python(
                self[]
                .inner.value()
                .search_hybrid_cosine(dense, sparse, k, fetch_k, rank_constant)
            )
        raise Error("unknown dense metric")

    @staticmethod
    def search_dense_where(
        py_self: PythonObject,
        metric: PythonObject,
        query: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var metric_name = String(py=metric)
        var values = _float_vector(query)
        var k = Int(py=options["k"])
        var expression = _filter_expression(options["filter"])
        var approximate = Bool(
            py=options.get("approximate", PythonObject(False))
        )
        if approximate:
            var ef = Int(py=options["ef_search"])
            if metric_name == "dot":
                return _results_to_python(
                    self[]
                    .inner.value()
                    .search_dot_approx_where(values, k, ef, expression)
                )
            if metric_name == "l2":
                return _results_to_python(
                    self[]
                    .inner.value()
                    .search_l2_approx_where(values, k, ef, expression)
                )
            if metric_name == "cosine":
                return _results_to_python(
                    self[]
                    .inner.value()
                    .search_cosine_approx_where(values, k, ef, expression)
                )
        else:
            if metric_name == "dot":
                return _results_to_python(
                    self[].inner.value().search_dot_where(values, k, expression)
                )
            if metric_name == "l2":
                return _results_to_python(
                    self[].inner.value().search_l2_where(values, k, expression)
                )
            if metric_name == "cosine":
                return _results_to_python(
                    self[]
                    .inner.value()
                    .search_cosine_where(values, k, expression)
                )
        raise Error("unknown dense metric")

    @staticmethod
    def search_sparse_where(
        py_self: PythonObject,
        query: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var sparse = _sparse_vector(query)
        var expression = _filter_expression(options["filter"])
        return _results_to_python(
            self[]
            .inner.value()
            .search_sparse_dot_where(sparse, Int(py=options["k"]), expression)
        )

    @staticmethod
    def search_hybrid_where(
        py_self: PythonObject,
        metric: PythonObject,
        dense_query: PythonObject,
        sparse_query: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var metric_name = String(py=metric)
        var dense = _float_vector(dense_query)
        var sparse = _sparse_vector(sparse_query)
        var k = Int(py=options["k"])
        var fetch_k = Int(py=options["fetch_k"])
        var rank_constant = Int(py=options["rank_constant"])
        var expression = _filter_expression(options["filter"])
        if metric_name == "dot":
            return _results_to_python(
                self[]
                .inner.value()
                .search_hybrid_dot_where(
                    dense, sparse, k, fetch_k, rank_constant, expression
                )
            )
        if metric_name == "l2":
            return _results_to_python(
                self[]
                .inner.value()
                .search_hybrid_l2_where(
                    dense, sparse, k, fetch_k, rank_constant, expression
                )
            )
        if metric_name == "cosine":
            return _results_to_python(
                self[]
                .inner.value()
                .search_hybrid_cosine_where(
                    dense, sparse, k, fetch_k, rank_constant, expression
                )
            )
        raise Error("unknown dense metric")


def _ensure_open(collection: BoundCollection) raises:
    if not Bool(collection.inner):
        raise Error("collection is closed")


def _float_vector(value: PythonObject) raises -> List[Float32]:
    var result = List[Float32](capacity=len(value))
    for item in value:
        result.append(Float32(py=item))
    return result^


def _float_vectors(value: PythonObject) raises -> List[List[Float32]]:
    var result = List[List[Float32]](capacity=len(value))
    for item in value:
        result.append(_float_vector(item))
    return result^


def _sparse_vector(value: PythonObject) raises -> List[SparseElement]:
    var result = List[SparseElement](capacity=len(value))
    for item in value:
        result.append(
            SparseElement(Int(py=item["term_id"]), Float32(py=item["weight"]))
        )
    return result^


def _document_fields(value: PythonObject) raises -> List[DocumentField]:
    var result = List[DocumentField](capacity=len(value))
    for item in value:
        var name = String(py=item["name"])
        var kind = String(py=item["type"])
        var raw = item["value"]
        if kind == "string":
            result.append(
                DocumentField(name, PayloadValue.string(String(py=raw)))
            )
        elif kind == "int":
            result.append(
                DocumentField(name, PayloadValue.integer(Int64(py=raw)))
            )
        elif kind == "float":
            result.append(
                DocumentField(name, PayloadValue.floating(Float64(py=raw)))
            )
        elif kind == "bool":
            result.append(
                DocumentField(name, PayloadValue.boolean(Bool(py=raw)))
            )
        else:
            raise Error("unknown payload value type")
    return result^


def _filter_expression(value: PythonObject) raises -> FilterExpression:
    var kind = String(py=value["kind"])
    if kind == "condition":
        var operator_name = String(py=value["operator"])
        var operator_kind: UInt8
        if operator_name == "eq":
            operator_kind = FilterCondition.EQUAL
        elif operator_name == "ne":
            operator_kind = FilterCondition.NOT_EQUAL
        elif operator_name == "lt":
            operator_kind = FilterCondition.LESS_THAN
        elif operator_name == "le":
            operator_kind = FilterCondition.LESS_OR_EQUAL
        elif operator_name == "gt":
            operator_kind = FilterCondition.GREATER_THAN
        elif operator_name == "ge":
            operator_kind = FilterCondition.GREATER_OR_EQUAL
        else:
            raise Error("unknown filter operator")
        var payload = _payload_value(String(py=value["type"]), value["value"])
        var condition = FilterCondition(
            String(py=value["name"]), operator_kind, payload^
        )
        return FilterExpression.condition(condition^)
    if kind == "not":
        var child = _filter_expression(value["child"])
        return FilterExpression.negate(child^)
    if kind == "all" or kind == "any":
        var children = List[FilterExpression]()
        for item in value["children"]:
            children.append(_filter_expression(item))
        if kind == "all":
            return FilterExpression.all(children^)
        return FilterExpression.any(children^)
    raise Error("unknown filter expression kind")


def _payload_value(kind: String, raw: PythonObject) raises -> PayloadValue:
    if kind == "string":
        return PayloadValue.string(String(py=raw))
    if kind == "int":
        return PayloadValue.integer(Int64(py=raw))
    if kind == "float":
        return PayloadValue.floating(Float64(py=raw))
    if kind == "bool":
        return PayloadValue.boolean(Bool(py=raw))
    raise Error("unknown payload value type")


def _field_to_python(field: DocumentField) raises -> PythonObject:
    var kind: String
    var value: PythonObject
    if field.value.is_string():
        kind = "string"
        value = PythonObject(field.value.as_string())
    elif field.value.is_integer():
        kind = "int"
        value = PythonObject(field.value.as_int())
    elif field.value.is_floating():
        kind = "float"
        value = PythonObject(field.value.as_float())
    else:
        kind = "bool"
        value = PythonObject(field.value.as_bool())
    return Python.dict(
        name=PythonObject(field.name),
        type=PythonObject(kind),
        value=value,
    )


def _document_to_python(
    record: Optional[DocumentRecord]
) raises -> PythonObject:
    if not Bool(record):
        return Python.none()
    var fields = Python.list()
    for index in range(len(record.value().fields)):
        fields.append(_field_to_python(record.value().fields[index]))
    var vector = Python.list()
    for value in record.value().vector:
        vector.append(value)
    return Python.dict(
        id=PythonObject(record.value().id),
        sequence=PythonObject(record.value().sequence),
        vector=vector,
        fields=fields,
    )


def _results_to_python(results: List[SearchResult]) raises -> PythonObject:
    var output = Python.list()
    for result in results:
        output.append(
            Python.dict(
                id=PythonObject(result.id), score=PythonObject(result.score)
            )
        )
    return output


@export
def PyInit__kernel() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("_kernel")
        _ = (
            module.add_type[BoundCollection]("Collection")
            .def_py_init[BoundCollection.py_init]()
            .def_method[BoundCollection.close]("close")
            .def_method[BoundCollection.last_sequence]("last_sequence")
            .def_method[BoundCollection.upsert]("upsert")
            .def_method[BoundCollection.upsert_document]("upsert_document")
            .def_method[BoundCollection.apply_batch]("apply_batch")
            .def_method[BoundCollection.upsert_sparse]("upsert_sparse")
            .def_method[BoundCollection.delete]("delete")
            .def_method[BoundCollection.flush]("flush")
            .def_method[BoundCollection.get]("get")
            .def_method[BoundCollection.get_projected]("get_projected")
            .def_method[BoundCollection.apply_arrow_batch]("apply_arrow_batch")
            .def_method[BoundCollection.search_dot]("search_dot")
            .def_method[BoundCollection.search_l2]("search_l2")
            .def_method[BoundCollection.search_cosine]("search_cosine")
            .def_method[BoundCollection.search_batch]("search_batch")
            .def_method[BoundCollection.search_batch_where](
                "search_batch_where"
            )
            .def_method[BoundCollection.search_approx]("search_approx")
            .def_method[BoundCollection.search_sparse]("search_sparse")
            .def_method[BoundCollection.search_hybrid]("search_hybrid")
            .def_method[BoundCollection.search_dense_where](
                "search_dense_where"
            )
            .def_method[BoundCollection.search_sparse_where](
                "search_sparse_where"
            )
            .def_method[BoundCollection.search_hybrid_where](
                "search_hybrid_where"
            )
        )
        return module.finalize()
    except error:
        abort(String("failed to create Akasha Python module: ", error))
