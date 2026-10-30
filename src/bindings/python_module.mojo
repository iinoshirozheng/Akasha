from akasha.query.query_plan import QueryNode, plan_query
from akasha.query.formula import Formula, FormulaDefault, FormulaNode
from akasha.query.field_recommendation import RecommendationExample
from akasha.query.field_discovery import ContextPair
from akasha import (
    BatchMutation,
    CollectionConfig,
    DocumentField,
    DocumentRecord,
    FieldProjection,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    MetricKind,
    ScalarKind,
    SparseElement,
    QueryControl,
    CancellationToken,
)
from akasha.query.field_fusion import FieldQuery
from akasha.index.field_ivf import IvfOptions
from akasha.query.mmr import MmrOptions
from akasha.query.field_search import FieldSearchResult
from akasha.index.sparse import validate_sparse
from akasha.document.point_state import PointMutation, FieldUpdate, PointState
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from bindings.point_values import vector_from_python, vector_to_python
from bindings.payload_python import payload_value_from_python, payload_value_to_python, payload_kind_name
from bindings.point_arrow import arrow_vector_is_valid, vector_from_arrow
from std.collections import Dict
from akasha.index.flat import SearchResult
from akasha.api.scanner import ReadScanner
from akasha.api.snapshot import ReadSnapshot
from bindings.arrow_export import ArrowColumn, scanner_schema, import_scan_batch
from akasha.storage.operations import (
    inspect_storage,
    restore_storage,
    StorageInspection,
)
from std.os import abort
from std.python import Python, PythonObject
from std.python.bindings import PythonModuleBuilder
from std.python.numpy import from_numpy_array


struct BoundScanner(Movable, Writable):
    var inner: Optional[ReadScanner]
    var columns: List[ArrowColumn]
    var schema_value: PythonObject
    var token: CancellationToken
    var max_candidates: Int
    var deadline_ns: Int
    var max_bytes: Int

    def __init__(out self) raises:
        self.inner = Optional[ReadScanner]()
        self.columns = List[ArrowColumn]()
        self.schema_value = Python.none()
        self.token = CancellationToken()
        self.max_candidates = 1
        self.deadline_ns = 0
        self.max_bytes = 1

    def write_to(self, mut writer: Some[Writer]):
        writer.write("AkashaScanner")

    def write_repr_to(self, mut writer: Some[Writer]):
        writer.write("AkashaScanner()")

    @staticmethod
    def py_init(
        out self: BoundScanner, args: PythonObject, kwargs: PythonObject
    ) raises:
        self = BoundScanner()
        if len(args) != 2:
            raise Error("Scanner requires a collection and options")
        var collection = args[0].downcast_value_ptr[BoundCollection]()
        _ensure_open(collection[])
        var options = args[1]
        self.max_candidates = _exact_python_int(
            options["max_candidates"], "scanner candidate limit"
        )
        self.deadline_ns = _exact_python_int(
            options["deadline_ns"], "scanner deadline"
        )
        self.max_bytes = _exact_python_int(
            options["max_batch_bytes"], "scanner buffer limit"
        )
        _ = QueryControl(
            self.token,
            max_candidates=self.max_candidates,
            deadline_ns=self.deadline_ns,
        )
        if self.max_bytes <= 0:
            raise Error("scanner buffer limit must be positive")
        _ensure_open(collection[])
        var field_schema = collection[].inner.value().vector_fields()
        var point_mode = Bool(collection[].inner.value()._field_catalog())
        for column in options["columns"]:
            var name = _exact_python_string(
                column["name"], "scanner column name"
            )
            for previous in self.columns:
                if previous.name == name:
                    raise Error("scanner column names must be unique")
            var kind = _exact_python_int(column["kind"], "scanner column kind")
            var source_name = _exact_python_string(
                column["payload_name"], "scanner source name"
            )
            var vector_field = Optional[VectorFieldSpec]()
            if kind == 10:
                var ordinal = _named_field_ordinal(field_schema, source_name)
                vector_field = Optional(field_schema[ordinal].copy())
            elif kind == 3 and point_mode:
                kind = 10
                vector_field = Optional(field_schema[0].copy())
            self.columns.append(
                ArrowColumn(
                    name^,
                    kind,
                    source_name^,
                    vector_field^,
                )
            )
        var expression = Optional[FilterExpression]()
        if not _is_python_none(options["filter"]):
            expression = Optional(_filter_expression(options["filter"]))
        _ensure_open(collection[])
        var snapshot = collection[].inner.value().snapshot()
        self.schema_value = scanner_schema(
            self.columns, snapshot.collection_config().dimension
        )
        self.inner = Optional(
            snapshot.scanner(
                _exact_python_int(options["batch_size"], "scanner batch size"),
                expression^,
            )
        )
        snapshot.close()

    @staticmethod
    def schema(py_self: PythonObject) raises -> PythonObject:
        return py_self.downcast_value_ptr[BoundScanner]()[].schema_value

    @staticmethod
    def close(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundScanner]()
        self[].inner = Optional[ReadScanner]()
        return Python.none()

    @staticmethod
    def next_batch(
        py_self: PythonObject, cancelled: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundScanner]()
        if not self[].inner:
            raise Error("scanner is closed")
        try:
            if Bool(py=cancelled):
                self[].token.cancel()
            if not self[].inner:
                raise Error("scanner is closed")
            var control = QueryControl(
                self[].token,
                max_candidates=self[].max_candidates,
                deadline_ns=self[].deadline_ns,
            )
            var batch = self[].inner.value().next(control)
            var visited = self[].inner.value().visited_slots
            if not batch:
                return Python.dict(
                    batch=Python.none(),
                    visited_slots=PythonObject(
                        visited
                    ),
                )
            var result = import_scan_batch(
                batch.value(),
                self[].columns,
                self[].schema_value,
                self[].max_bytes,
                control,
            )
            _set_output_item(
                result, PythonObject("visited_slots"), PythonObject(visited)
            )
            return result
        except error:
            self[].inner = Optional[ReadScanner]()
            raise error


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
        if len(args) < 2 or len(args) > 4:
            raise Error(
                "Collection(path, dimension, config=None, vectors=None)"
                " requires two to four arguments"
            )
        var keyword_count = 0
        # PythonTypeBuilder passes a null kwargs pointer when no keywords are
        # present. Follow its own stdlib initializer pattern before touching it.
        if kwargs._obj_ptr:
            keyword_count = len(kwargs)
            for raw_name in kwargs:
                var name = _exact_python_string(raw_name, "Collection keyword")
                if name != "config":
                    raise Error("unknown Collection keyword: " + name)
        if len(args) >= 3 and keyword_count != 0:
            raise Error("Collection config specified more than once")
        var path = String(py=args[0])
        var dimension = _exact_python_int(args[1], "dimension")
        var config_value = Python.none()
        if len(args) >= 3:
            config_value = args[2]
        elif keyword_count == 1:
            config_value = kwargs["config"]
        if len(args) == 4:
            var config = CollectionConfig.defaults(dimension)
            if not _is_python_none(config_value):
                config = _collection_config_from_python(dimension, config_value)
            var fields = legacy_vector_fields(config)
            for raw in args[3]:
                fields.append(_vector_field_from_python(raw))
            self.inner = Optional(
                PersistentCollection.open_with_fields(path, fields^)
            )
        elif _is_python_none(config_value):
            self.inner = Optional(PersistentCollection.open(path, dimension))
        else:
            var config = _collection_config_from_python(dimension, config_value)
            config.validate()
            self.inner = Optional(
                PersistentCollection.open_with_config(path, config)
            )

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
    def collection_config(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        return _collection_config_to_python(
            self[].inner.value().collection_config()
        )

    @staticmethod
    def last_search_stats(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var stats = self[].inner.value().last_search_stats()
        return Python.dict(
            planner_reason=PythonObject(
                self[].inner.value().last_dense_plan_reason()
            ),
            backend_name=PythonObject(stats.backend_name),
            metric_name=PythonObject(stats.metric_name),
            scalar_name=PythonObject(stats.scalar_name),
            storage_name=PythonObject(stats.storage_name),
            fallback_reason=PythonObject(stats.fallback_reason),
            requested_ef=PythonObject(stats.requested_ef),
            effective_ef=PythonObject(stats.effective_ef),
            widening_rounds=PythonObject(stats.widening_rounds),
            upper_visited=PythonObject(stats.upper_visited),
            base_visited=PythonObject(stats.base_visited),
            visited=PythonObject(stats.upper_visited + stats.base_visited),
            distance_evaluations=PythonObject(stats.distance_evaluations),
            retained_candidates=PythonObject(stats.retained_candidates),
            reranked_candidates=PythonObject(stats.reranked_candidates),
            filtered_rejections=PythonObject(stats.filtered_rejections),
            inactive_rejections=PythonObject(stats.inactive_rejections),
            base_candidates=PythonObject(stats.base_candidates),
            delta_candidates=PythonObject(stats.delta_candidates),
            ivf_partitions=PythonObject(stats.ivf_partitions),
            ivf_probed_partitions=PythonObject(stats.ivf_probed_partitions),
        )

    @staticmethod
    def upsert(
        py_self: PythonObject, id: PythonObject, vector: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(vector)
        var native_id = Int(py=id)
        _ensure_open(self[])
        self[].inner.value().upsert(native_id, values^)
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
        var native_id = Int(py=id)
        _ensure_open(self[])
        self[].inner.value().upsert_document(native_id, values^, mojo_fields^)
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
        _ensure_open(self[])
        var committed = self[].inner.value().apply_batch(batch)
        return Python.dict(
            first_sequence=PythonObject(committed.first_sequence),
            last_sequence=PythonObject(committed.last_sequence),
            count=PythonObject(committed.count),
        )

    @staticmethod
    def vector_fields(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var output = List[PythonObject]()
        for field in fields:
            output.append(_vector_field_to_python(field))
        return Python.list(Span(output))

    @staticmethod
    def apply_point_batch(
        py_self: PythonObject, mutations: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var batch = List[PointMutation](capacity=len(mutations))
        for item in mutations:
            var operation = _exact_python_string(
                item["operation"], "point operation"
            )
            var kind: UInt8 = 1
            if operation == "delete":
                kind = 2
            elif operation == "update":
                kind = 3
            elif operation != "upsert":
                raise Error("unknown point mutation operation")
            var updates = Dict[Int, FieldUpdate]()
            for raw in item["updates"]:
                var ordinal: Int
                if Bool(py=raw.__contains__("name")):
                    if Bool(py=raw.__contains__("id")):
                        raise Error(
                            "field update must use either a name or a"
                            " reserved ID"
                        )
                    ordinal = _named_field_ordinal(
                        fields, _exact_python_string(raw["name"], "field name")
                    )
                else:
                    ordinal = _exact_python_int(raw["id"], "reserved field ID")
                    if ordinal < 0 or ordinal > 1:
                        raise Error("named fields must be addressed by name")
                if ordinal in updates:
                    raise Error("duplicate point field update")
                ref spec = fields[ordinal]
                if _is_python_none(raw["value"]):
                    updates[ordinal] = FieldUpdate.remove(spec.id)
                else:
                    updates[ordinal] = FieldUpdate.set(
                        spec.id, vector_from_python(raw["value"], spec)
                    )
            var ordered = List[FieldUpdate](capacity=len(updates))
            for ordinal in range(len(fields)):
                if ordinal in updates:
                    ordered.append(updates[ordinal].copy())
            var payload = Optional[List[DocumentField]]()
            if not _is_python_none(item["fields"]):
                payload = Optional(_document_fields(item["fields"]))
            batch.append(
                PointMutation(
                    _exact_python_int(item["id"], "point ID"),
                    kind,
                    ordered^,
                    payload^,
                )
            )
        _ensure_open(self[])
        var committed = self[].inner.value().apply_point_batch(batch)
        return Python.dict(
            first_sequence=PythonObject(committed.first_sequence),
            last_sequence=PythonObject(committed.last_sequence),
            count=PythonObject(committed.count),
        )

    @staticmethod
    def apply_point_arrow_batch(
        py_self: PythonObject,
        descriptor: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var rows = _exact_python_int(descriptor["row_count"], "Arrow row count")
        if rows <= 0 or rows > 65_536:
            raise Error("Arrow batch row count is invalid")
        var ids = from_numpy_array[DType.int64](descriptor["ids"])
        if len(ids) != rows:
            raise Error("Arrow ID buffer length mismatch")
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var columns = descriptor["updates"]
        var positions = Dict[Int, Int]()
        for index in range(len(columns)):
            var raw = columns[index]
            var ordinal: Int
            if Bool(py=raw.__contains__("name")):
                if Bool(py=raw.__contains__("id")):
                    raise Error(
                        "Arrow field requires either a name or reserved ID"
                    )
                ordinal = _named_field_ordinal(
                    fields, _exact_python_string(raw["name"], "field name")
                )
            else:
                ordinal = _exact_python_int(raw["id"], "reserved field ID")
                if ordinal < 0 or ordinal > 1:
                    raise Error("named fields must be addressed by name")
            if ordinal in positions:
                raise Error("duplicate Arrow field column")
            if _exact_python_int(raw["row_count"], "vector row count") != rows:
                raise Error("Arrow field row count mismatch")
            positions[ordinal] = index
        var mutations = List[PointMutation](capacity=rows)
        for row in range(rows):
            var updates = List[FieldUpdate](capacity=len(positions))
            for ordinal in range(len(fields)):
                if ordinal not in positions:
                    continue
                var raw = columns[positions[ordinal]]
                ref spec = fields[ordinal]
                if arrow_vector_is_valid(raw, row):
                    updates.append(
                        FieldUpdate.set(
                            spec.id, vector_from_arrow(raw, spec, row)
                        )
                    )
                else:
                    updates.append(FieldUpdate.remove(spec.id))
            var payload = Optional[List[DocumentField]]()
            if len(descriptor["payloads"]) != 0:
                var values = List[DocumentField]()
                for column in descriptor["payloads"]:
                    var raw = column["values"][row].as_py()
                    if not _is_python_none(raw):
                        values.append(
                            DocumentField(
                                _exact_python_string(
                                    column["name"], "payload name"
                                ),
                                _payload_value(
                                    _exact_python_string(
                                        column["type"], "payload type"
                                    ),
                                    raw,
                                ),
                            )
                        )
                payload = Optional(values^)
            mutations.append(
                PointMutation(Int(ids[row]), 1, updates^, payload^)
            )
        _ensure_open(self[])
        var committed = self[].inner.value().apply_point_batch(mutations)
        return Python.dict(
            first_sequence=PythonObject(committed.first_sequence),
            last_sequence=PythonObject(committed.last_sequence),
            count=PythonObject(committed.count),
        )

    @staticmethod
    def get_point(
        py_self: PythonObject, id: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var point = (
            self[].inner.value().get_point(_exact_python_int(id, "point ID"))
        )
        if not point:
            return Python.none()
        var schema = self[].inner.value().vector_fields()
        return _point_to_python(point.value(), schema)

    @staticmethod
    def query[columns: Bool = False](
        py_self: PythonObject, raw_nodes: PythonObject, options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var max_nodes = _exact_python_int(options["max_nodes"], "max_nodes")
        var max_examples = _exact_python_int(options["max_examples"], "max_examples")
        var max_k = _exact_python_int(options["max_k"], "max_k")
        var size = len(raw_nodes)
        if size <= 0 or size > max_nodes:
            raise Error("query node resource limit exceeded")
        var token = CancellationToken()
        if Bool(py=options["cancelled"]):
            token.cancel()
        var control = Optional(QueryControl(token,
            max_candidates=_exact_python_int(options["max_candidates"], "max_candidates"),
            deadline_ns=_exact_python_int(options["deadline_ns"], "deadline_ns")))
        control.value().checkpoint(0)
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var nodes = List[QueryNode]()
        var owners = Python.list()
        var owner_indices = Dict[Int, Int]()
        var examples = 0
        var resources = size
        for i in range(size):
            control.value().checkpoint(i)
            var raw = raw_nodes[i]
            var kind = _exact_python_string(raw["kind"], "query kind")
            var name = _exact_python_string(raw["using"], "query field")
            var lookup_index = -1
            var owner = raw["lookup_from"]
            if not _is_python_none(owner):
                var source = owner.downcast_value_ptr[BoundCollection]()
                if Int(source) != Int(self):
                    var identity = Int(source)
                    if identity not in owner_indices:
                        owner_indices[identity] = len(owners)
                        owners.append(owner)
                    lookup_index = owner_indices[identity]
            var field = fields[0].copy()
            if kind == "nearest" or kind == "recommend" or kind == "discover" or kind == "context":
                if name != "":
                    field = fields[_named_field_ordinal(fields, name)].copy()
            field.scalar = 0
            var target = Optional[RecommendationExample]()
            var raw_target = raw["target"]
            var pos = raw["positive"]
            var neg = raw["negative"]
            var count = Int(not _is_python_none(raw_target)) + len(pos) + len(neg)
            if count > max_examples - examples:
                raise Error("query example resource limit exceeded")
            examples += count
            if not _is_python_none(raw_target):
                target = Optional(_query_example_from_python(raw_target, field))
            var positive = _recommendation_examples_from_python(pos, field)
            var negative = _recommendation_examples_from_python(neg, field)
            var children = List[Int]()
            var raw_children = raw["children"]
            if len(raw_children) > size:
                raise Error("query child resource limit exceeded")
            for j in range(len(raw_children)):
                children.append(_exact_python_int(raw_children[j], "prefetch index"))
            var expression = Optional[FilterExpression]()
            if not _is_python_none(raw["filter"]):
                expression = Optional(_filter_expression(raw["filter"]))
            var threshold = Optional[Float32]()
            if not _is_python_none(raw["threshold"]):
                threshold = Optional(Float32(py=raw["threshold"]))
            var lookup_field = Optional[String]()
            if not _is_python_none(raw["lookup_field"]):
                lookup_field = Optional(_exact_python_string(raw["lookup_field"], "lookup field"))
            var mmr = Optional[MmrOptions]()
            var raw_mmr = raw["mmr"]
            if not _is_python_none(raw_mmr):
                mmr = Optional(MmrOptions(Float32(py=raw_mmr["diversity"]),
                    _exact_python_int(raw_mmr["candidates_limit"], "MMR candidate limit")))
            var weights = Optional[List[Float32]]()
            if not _is_python_none(raw["weights"]):
                var values = List[Float32]()
                var raw_weights = raw["weights"]
                if len(raw_weights) > size:
                    raise Error("query weight resource limit exceeded")
                for j in range(len(raw_weights)):
                    values.append(Float32(py=raw_weights[j]))
                weights = Optional(values^)
            var formula = Optional[Formula]()
            if not _is_python_none(raw["formula"]):
                formula = Optional(_formula_from_python(raw["formula"], max_nodes - resources))
                resources += len(formula.value().nodes) + len(formula.value().defaults)
            nodes.append(QueryNode(kind, name, target=target^, positive=positive^,
                negative=negative^, strategy=_exact_python_string(raw["strategy"], "query strategy"),
                children=children^, limit=_exact_python_int(raw["limit"], "query limit"),
                offset=_exact_python_int(raw["offset"], "query offset"), threshold=threshold,
                filter=expression^, approximate=Bool(py=raw["approximate"]),
                ef_search=_exact_python_int(raw["ef_search"], "ef_search"),
                lookup_index=lookup_index, lookup_field=lookup_field, mmr=mmr,
                rank_constant=_exact_python_int(raw["rank_constant"], "rank constant"), weights=weights,
                formula=formula^))
        _ = plan_query(nodes, max_nodes, max_k, max_examples)
        # All Python conversions finish before acquiring any read root. A
        # callback may close either target or lookup: recheck both here.
        _ensure_open(self[])
        var lookups = List[ReadSnapshot]()
        for i in range(len(owners)):
            var source = owners[i].downcast_value_ptr[BoundCollection]()
            _ensure_open(source[])
            lookups.append(source[].inner.value().snapshot())
        var results = self[].inner.value().query(nodes, lookups, control=control,
            max_nodes=max_nodes, max_k=max_k, max_examples=max_examples)
        return _field_results_to_python[columns](results)

    @staticmethod
    def discover_field[columns: Bool = False](
        py_self: PythonObject, name: PythonObject, raw_target: PythonObject,
        raw_context: PythonObject, k: PythonObject, options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var count = _exact_python_int(k, "k")
        if count < 0:
            raise Error("discovery k must be nonnegative")
        if count == 0:
            var pairs = List[ContextPair]()
            var results = self[].inner.value().discover_field("", None, pairs, 0)
            return _field_results_to_python[columns](results)
        var field_name = _exact_python_string(name, "field name")
        var mode = _exact_python_string(options["mode"], "discovery mode")
        if mode != "exact" and mode != "approx":
            raise Error("discovery mode must be exact or approx")
        var ef = _exact_python_int(options.get("ef_search", PythonObject(-1)), "ef_search")
        var limit = _exact_python_int(options["max_examples"], "max_examples")
        var token = CancellationToken()
        if Bool(py=options["cancelled"]):
            token.cancel()
        var control = Optional(QueryControl(
            token, max_candidates=_exact_python_int(options["max_candidates"], "max_candidates"),
            deadline_ns=_exact_python_int(options["deadline_ns"], "deadline_ns"),
        ))
        control.value().checkpoint(0)
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var ordinal = _named_field_ordinal(fields, field_name)
        var query_field = fields[ordinal].copy()
        query_field.scalar = 0
        var has_target = not _is_python_none(raw_target)
        var pair_count = len(raw_context)
        if limit <= 0 or pair_count > (limit - Int(has_target)) // 2:
            raise Error("discovery example resource limit exceeded")
        var target = Optional[RecommendationExample]()
        if has_target:
            target = Optional(_query_example_from_python(raw_target, query_field))
        var context = List[ContextPair]()
        for i in range(pair_count):
            var pair = raw_context[i]
            context.append(ContextPair(
                _query_example_from_python(pair["positive"], query_field),
                _query_example_from_python(pair["negative"], query_field),
            ))
        var expression = Optional[FilterExpression]()
        if not _is_python_none(options["filter"]):
            expression = Optional(_filter_expression(options["filter"]))
        var lookup_field = Optional[String]()
        var raw_lookup_field = options["lookup_field"]
        if not _is_python_none(raw_lookup_field):
            lookup_field = Optional(_exact_python_string(raw_lookup_field, "lookup field"))
        var raw_lookup = options["lookup_from"]
        _ensure_open(self[])
        var lookup = Optional[ReadSnapshot]()
        if not _is_python_none(raw_lookup):
            var source = raw_lookup.downcast_value_ptr[BoundCollection]()
            _ensure_open(source[])
            if Int(source) != Int(self):
                lookup = Optional(source[].inner.value().snapshot())
        _ensure_open(self[])
        var results = self[].inner.value().discover_field(
            field_name, target, context, count, lookup=lookup, lookup_field=lookup_field,
            expression=expression^, max_examples=limit, control=control,
            approximate=mode == "approx", ef_search=ef,
        )
        return _field_results_to_python[columns](results)

    @staticmethod
    def recommend_field[columns: Bool = False](
        py_self: PythonObject, name: PythonObject, positive: PythonObject,
        negative: PythonObject, k: PythonObject, options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var field_name = _exact_python_string(name, "field name")
        var strategy = _exact_python_string(options["strategy"], "recommendation strategy")
        var mode = _exact_python_string(options["mode"], "recommendation mode")
        if mode != "exact" and mode != "approx":
            raise Error("recommendation mode must be exact or approx")
        var ef = _exact_python_int(options.get("ef_search", PythonObject(-1)), "ef_search")
        var count = _exact_python_int(k, "k")
        var limit = _exact_python_int(options["max_examples"], "max_examples")
        var token = CancellationToken()
        if Bool(py=options["cancelled"]):
            token.cancel()
        var control = Optional(QueryControl(
            token, max_candidates=_exact_python_int(options["max_candidates"], "max_candidates"),
            deadline_ns=_exact_python_int(options["deadline_ns"], "deadline_ns"),
        ))
        control.value().checkpoint(0)
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var ordinal = _named_field_ordinal(fields, field_name)
        var query_field = fields[ordinal].copy()
        query_field.scalar = 0
        var pos_count = len(positive)
        var neg_count = len(negative)
        if limit <= 0 or pos_count > limit or neg_count > limit - pos_count:
            raise Error("recommendation example resource limit exceeded")
        var positives = _recommendation_examples_from_python(positive, query_field)
        var negatives = _recommendation_examples_from_python(negative, query_field)
        var expression = Optional[FilterExpression]()
        if not _is_python_none(options["filter"]):
            expression = Optional(_filter_expression(options["filter"]))
        var lookup_field = Optional[String]()
        var raw_lookup_field = options["lookup_field"]
        if not _is_python_none(raw_lookup_field):
            lookup_field = Optional(_exact_python_string(raw_lookup_field, "lookup field"))
        var raw_lookup = options["lookup_from"]
        _ensure_open(self[])
        var lookup = Optional[ReadSnapshot]()
        if not _is_python_none(raw_lookup):
            var source = raw_lookup.downcast_value_ptr[BoundCollection]()
            _ensure_open(source[])
            if Int(source) != Int(self):
                lookup = Optional(source[].inner.value().snapshot())
        _ensure_open(self[])
        var results = self[].inner.value().recommend_field(
            field_name, positives, negatives, count, strategy=strategy,
            lookup=lookup, lookup_field=lookup_field, expression=expression^,
            max_examples=limit, control=control, approximate=mode == "approx", ef_search=ef,
        )
        return _field_results_to_python[columns](results)

    @staticmethod
    def search_field[
        columns: Bool = False,
        by_id: Bool = False,
    ](
        py_self: PythonObject,
        name: PythonObject,
        raw: PythonObject,
        k: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var field_name = _exact_python_string(name, "field name")
        var search_mode = _exact_python_string(options["mode"], "search mode")
        if search_mode != "exact" and search_mode != "approx" and search_mode != "ivf":
            raise Error("named search mode must be exact, approx or ivf")
        var ivf = _ivf_from_python(search_mode, options["ivf"])
        var mmr = Optional[MmrOptions]()
        var raw_mmr = options.get("mmr", Python.none())
        if not _is_python_none(raw_mmr):
            mmr = Optional(MmrOptions(Float32(py=raw_mmr["diversity"]),
                _exact_python_int(raw_mmr["candidates_limit"], "MMR candidates_limit")))
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var ordinal = _named_field_ordinal(fields, field_name)
        var token = CancellationToken()
        if Bool(py=options["cancelled"]):
            token.cancel()
        var control = Optional(
            QueryControl(
                token,
                max_candidates=_exact_python_int(
                    options["max_candidates"], "max_candidates"
                ),
                deadline_ns=_exact_python_int(
                    options["deadline_ns"], "deadline_ns"
                ),
            )
        )
        control.value().checkpoint(0)
        var query = Optional[VectorValue]()
        var point_id = 0
        comptime if by_id:
            point_id = _exact_python_int(raw, "point ID")
        else:
            query = Optional(vector_from_python(raw, fields[ordinal]))
        var expression = Optional[FilterExpression]()
        if not _is_python_none(options["filter"]):
            expression = Optional(_filter_expression(options["filter"]))
        var count = _exact_python_int(k, "k")
        var ef = _exact_python_int(options["ef_search"], "ef_search")
        var rerank = _exact_python_int(options["rerank_k"], "rerank_k")
        comptime if by_id:
            var lookup_field = Optional[String]()
            var raw_lookup_field = options.get("lookup_field", Python.none())
            if not _is_python_none(raw_lookup_field):
                lookup_field = Optional(_exact_python_string(raw_lookup_field, "lookup field"))
            var raw_lookup = options.get("lookup_from", Python.none())
            _ensure_open(self[])
            var lookup = Optional[ReadSnapshot]()
            if not _is_python_none(raw_lookup):
                var source = raw_lookup.downcast_value_ptr[BoundCollection]()
                _ensure_open(source[])
                # Explicit self lookup must use the search's single root.
                if Int(source) != Int(self):
                    lookup = Optional(source[].inner.value().snapshot())
            _ensure_open(self[])
            var results = self[].inner.value().search_field_by_id(
                field_name, point_id, count, lookup=lookup,
                lookup_field=lookup_field, expression=expression^,
                approximate=search_mode == "approx", ef_search=ef,
                rerank_k=rerank, ivf=ivf, mmr=mmr, control=control,
            )
            return _field_results_to_python[columns](results)
        _ensure_open(self[])
        var results = (
            self[]
            .inner.value()
            .search_field(
                field_name,
                query.value(),
                count,
                expression^,
                approximate=search_mode == "approx",
                ef_search=ef,
                rerank_k=rerank,
                ivf=ivf, mmr=mmr,
                control=control,
            )
        )
        return _field_results_to_python[columns](results)

    @staticmethod
    def search_fields[
        columns: Bool = False
    ](
        py_self: PythonObject, raw: PythonObject, options: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var token = CancellationToken()
        if Bool(py=options["cancelled"]):
            token.cancel()
        var control = Optional(
            QueryControl(
                token,
                max_candidates=_exact_python_int(
                    options["max_candidates"], "max_candidates"
                ),
                deadline_ns=_exact_python_int(
                    options["deadline_ns"], "deadline_ns"
                ),
            )
        )
        control.value().checkpoint(0)
        _ensure_open(self[])
        var fields = self[].inner.value().vector_fields()
        var queries = List[FieldQuery]()
        for item in raw:
            queries.append(_field_query_from_python(item, fields))
        var rerank = Optional[FieldQuery]()
        if not _is_python_none(options["rerank"]):
            rerank = Optional(_field_query_from_python(options["rerank"], fields))
        var expression = Optional[FilterExpression]()
        if not _is_python_none(options["filter"]):
            expression = Optional(_filter_expression(options["filter"]))
        var count = _exact_python_int(options["k"], "k")
        var fetch = _exact_python_int(options["fetch_k"], "fetch_k")
        var rank = _exact_python_int(options["rank_constant"], "rank_constant")
        var fusion = String(py=options.get("fusion", "rrf"))
        var weights = Optional[List[Float32]]()
        var raw_weights = options.get("weights", Python.none())
        if not _is_python_none(raw_weights):
            weights = Optional(_float_vector(raw_weights))
        _ensure_open(self[])
        var results = (
            self[]
            .inner.value()
            .search_fields(
                queries,
                count,
                fetch_k=fetch,
                rank_constant=rank,
                fusion=fusion,
                weights=weights,
                expression=expression^,
                control=control,
                rerank=rerank,
            )
        )
        return _field_results_to_python[columns](results)

    @staticmethod
    def upsert_sparse(
        py_self: PythonObject, id: PythonObject, elements: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var sparse = _sparse_vector(elements)
        var native_id = Int(py=id)
        _ensure_open(self[])
        self[].inner.value().upsert_sparse(native_id, sparse^)
        return Python.none()

    @staticmethod
    def delete(py_self: PythonObject, id: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var native_id = Int(py=id)
        _ensure_open(self[])
        self[].inner.value().delete(native_id)
        return Python.none()

    @staticmethod
    def flush(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        self[].inner.value().flush()
        return Python.none()

    @staticmethod
    def backup_to(
        py_self: PythonObject, target: PythonObject
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var target_path = String(py=target)
        _ensure_open(self[])
        var report = self[].inner.value().backup_to(target_path)
        return _storage_report_to_python(report)

    @staticmethod
    def is_point_collection(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        return PythonObject(Bool(self[].inner.value()._field_catalog()))

    @staticmethod
    def export_points(py_self: PythonObject) raises -> PythonObject:
        """Capture schema and all visible typed rows from one immutable root."""
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var snapshot = self[].inner.value().snapshot()
        var root = snapshot._acquire()
        if not root[].catalog:
            return Python.none()
        ref fields = root[].catalog.value()[]._fields
        var schema = List[PythonObject]()
        for field in fields:
            schema.append(_vector_field_to_python(field))
        var output = List[PythonObject]()
        for location in root[].id_ordered_locations():
            var point = root[].run(location[0]).memtable.entry_ref_at(location[1]).to_point()
            output.append(_point_to_python(point, fields))
        return Python.dict(
            config=_collection_config_to_python(root[].config),
            schema=Python.list(Span(schema)),
            points=Python.list(Span(output)),
            source_sequence=PythonObject(root[].sequence),
        )

    @staticmethod
    def export_records(py_self: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var snapshot = self[].inner.value().snapshot()
        var documents = snapshot.documents()
        var sparse = snapshot.sparse_records()
        var output = List[PythonObject]()
        for document_index in range(len(documents)):
            var record = _document_to_python(
                Optional(documents[document_index].clone())
            )
            var elements = List[PythonObject]()
            for sparse_index in range(len(sparse)):
                if sparse[sparse_index].id != documents[document_index].id:
                    continue
                for element in sparse[sparse_index].elements:
                    elements.append(
                        Python.dict(
                            term_id=PythonObject(element.term_id),
                            weight=PythonObject(element.weight),
                        )
                    )
                break
            _set_output_item(record, PythonObject("sparse"), Python.list(Span(elements)))
            output.append(record)
        snapshot.close()
        return Python.list(Span(output))

    @staticmethod
    def scanner(
        py_self: PythonObject, options: PythonObject
    ) raises -> PythonObject:
        _ensure_open(py_self.downcast_value_ptr[BoundCollection]()[])
        return Python.import_module("akashadb._kernel").Scanner(
            py_self, options
        )

    @staticmethod
    def search_controlled(
        py_self: PythonObject,
        metric: PythonObject,
        query: PythonObject,
        k: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var token = CancellationToken()
        if Bool(py=options["cancelled"]):
            token.cancel()
        var control = QueryControl(
            token,
            max_candidates=Int(py=options["max_candidates"]),
            deadline_ns=Int(py=options["deadline_ns"]),
        )
        _ensure_open(self[])
        var snapshot = self[].inner.value().snapshot()
        var values = _float_vector(query)
        var metric_name = String(py=metric)
        var results: List[SearchResult]
        if metric_name == "dot":
            results = snapshot.search_dot_controlled(values, Int(py=k), control)
        elif metric_name == "l2":
            results = snapshot.search_l2_controlled(values, Int(py=k), control)
        elif metric_name == "cosine":
            results = snapshot.search_cosine_controlled(
                values, Int(py=k), control
            )
        else:
            raise Error("unknown dense metric")
        snapshot.close()
        return _results_to_python(results)

    @staticmethod
    def get(py_self: PythonObject, id: PythonObject) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var native_id = Int(py=id)
        _ensure_open(self[])
        var record = self[].inner.value().get(native_id)
        if not Bool(record):
            return Python.none()
        var fields = List[PythonObject]()
        for index in range(len(record.value().fields)):
            fields.append(_field_to_python(record.value().fields[index]))
        var vector = List[PythonObject]()
        for value in record.value().vector:
            vector.append(value)
        return Python.dict(
            id=PythonObject(record.value().id),
            sequence=PythonObject(record.value().sequence),
            vector=Python.list(Span(vector)),
            fields=Python.list(Span(fields)),
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
        var native_id = Int(py=id)
        _ensure_open(self[])
        var record = self[].inner.value().get_projected(native_id, requested)
        return _document_to_python(record)

    @staticmethod
    def apply_arrow_batch(
        py_self: PythonObject, descriptor: PythonObject
    ) raises -> PythonObject:
        """Consume validated Arrow-owned buffers without Python list staging."""
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        return _apply_arrow_buffers(
            py_self,
            descriptor,
            descriptor["ids"],
            descriptor["vectors"],
            descriptor["sparse_offsets"],
            descriptor["sparse_terms"],
            descriptor["sparse_weights"],
        )

    @staticmethod
    def search_dot[
        columns: Bool
    ](
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(query)
        var count = Int(py=k)
        _ensure_open(self[])
        return _results_to_python[columns](
            self[].inner.value().search_dot(values, count)
        )

    @staticmethod
    def search_l2[
        columns: Bool
    ](
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(query)
        var count = Int(py=k)
        _ensure_open(self[])
        return _results_to_python[columns](
            self[].inner.value().search_l2(values, count)
        )

    @staticmethod
    def search_cosine[
        columns: Bool
    ](
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var values = _float_vector(query)
        var count = Int(py=k)
        _ensure_open(self[])
        return _results_to_python[columns](
            self[].inner.value().search_cosine(values, count)
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
            _ensure_open(self[])
            results = (
                self[]
                .inner.value()
                .search_dot_batch(vectors, count, num_workers=workers)
            )
        elif metric_name == "l2":
            _ensure_open(self[])
            results = (
                self[]
                .inner.value()
                .search_l2_batch(vectors, count, num_workers=workers)
            )
        elif metric_name == "cosine":
            _ensure_open(self[])
            results = (
                self[]
                .inner.value()
                .search_cosine_batch(vectors, count, num_workers=workers)
            )
        else:
            raise Error("unknown dense metric")
        var output = List[PythonObject](capacity=len(results))
        for query_results in results:
            output.append(_results_to_python(query_results))
        return Python.list(Span(output))

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
            _ensure_open(self[])
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
            _ensure_open(self[])
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
            _ensure_open(self[])
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
        var output = List[PythonObject](capacity=len(results))
        for query_results in results:
            output.append(_results_to_python(query_results))
        return Python.list(Span(output))

    @staticmethod
    def search_approx[
        columns: Bool
    ](
        py_self: PythonObject,
        metric: PythonObject,
        query: PythonObject,
        k: PythonObject,
        ef_search: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        # Python conversions can re-enter close(); recheck before native access.
        var metric_name = String(py=metric)
        var values = _float_vector(query)
        var count = Int(py=k)
        var ef = Int(py=ef_search)
        if metric_name == "dot":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[].inner.value().search_dot_approx(values, count, ef)
            )
        if metric_name == "l2":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[].inner.value().search_l2_approx(values, count, ef)
            )
        if metric_name == "cosine":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[].inner.value().search_cosine_approx(values, count, ef)
            )
        raise Error("unknown dense metric")

    @staticmethod
    def search_sparse[
        columns: Bool
    ](
        py_self: PythonObject,
        query: PythonObject,
        k: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var sparse = _sparse_vector(query)
        var count = Int(py=k)
        _ensure_open(self[])
        return _results_to_python[columns](
            self[].inner.value().search_sparse_dot(sparse, count)
        )

    @staticmethod
    def search_hybrid[
        columns: Bool
    ](
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
            _ensure_open(self[])
            return _results_to_python[columns](
                self[]
                .inner.value()
                .search_hybrid_dot(dense, sparse, k, fetch_k, rank_constant)
            )
        if metric_name == "l2":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[]
                .inner.value()
                .search_hybrid_l2(dense, sparse, k, fetch_k, rank_constant)
            )
        if metric_name == "cosine":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[]
                .inner.value()
                .search_hybrid_cosine(dense, sparse, k, fetch_k, rank_constant)
            )
        raise Error("unknown dense metric")

    @staticmethod
    def search_dense_where[
        columns: Bool
    ](
        py_self: PythonObject,
        metric: PythonObject,
        query: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        # Python conversions can re-enter close(); recheck before native access.
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
                _ensure_open(self[])
                return _results_to_python[columns](
                    self[]
                    .inner.value()
                    .search_dot_approx_where(values, k, ef, expression)
                )
            if metric_name == "l2":
                _ensure_open(self[])
                return _results_to_python[columns](
                    self[]
                    .inner.value()
                    .search_l2_approx_where(values, k, ef, expression)
                )
            if metric_name == "cosine":
                _ensure_open(self[])
                return _results_to_python[columns](
                    self[]
                    .inner.value()
                    .search_cosine_approx_where(values, k, ef, expression)
                )
        else:
            if metric_name == "dot":
                _ensure_open(self[])
                return _results_to_python[columns](
                    self[].inner.value().search_dot_where(values, k, expression)
                )
            if metric_name == "l2":
                _ensure_open(self[])
                return _results_to_python[columns](
                    self[].inner.value().search_l2_where(values, k, expression)
                )
            if metric_name == "cosine":
                _ensure_open(self[])
                return _results_to_python[columns](
                    self[]
                    .inner.value()
                    .search_cosine_where(values, k, expression)
                )
        raise Error("unknown dense metric")

    @staticmethod
    def search_sparse_where[
        columns: Bool
    ](
        py_self: PythonObject,
        query: PythonObject,
        options: PythonObject,
    ) raises -> PythonObject:
        var self = py_self.downcast_value_ptr[BoundCollection]()
        _ensure_open(self[])
        var sparse = _sparse_vector(query)
        var expression = _filter_expression(options["filter"])
        var count = Int(py=options["k"])
        _ensure_open(self[])
        return _results_to_python[columns](
            self[]
            .inner.value()
            .search_sparse_dot_where(sparse, count, expression)
        )

    @staticmethod
    def search_hybrid_where[
        columns: Bool
    ](
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
            _ensure_open(self[])
            return _results_to_python[columns](
                self[]
                .inner.value()
                .search_hybrid_dot_where(
                    dense, sparse, k, fetch_k, rank_constant, expression
                )
            )
        if metric_name == "l2":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[]
                .inner.value()
                .search_hybrid_l2_where(
                    dense, sparse, k, fetch_k, rank_constant, expression
                )
            )
        if metric_name == "cosine":
            _ensure_open(self[])
            return _results_to_python[columns](
                self[]
                .inner.value()
                .search_hybrid_cosine_where(
                    dense, sparse, k, fetch_k, rank_constant, expression
                )
            )
        raise Error("unknown dense metric")


def _metric_kind_from_python(value: PythonObject) raises -> MetricKind:
    var name = _exact_python_string(value, "ann_metric")
    if name == "dot":
        return MetricKind.dot()
    if name == "l2":
        return MetricKind.l2()
    if name == "cosine":
        return MetricKind.cosine()
    raise Error("unknown ann_metric")


def _scalar_kind_from_python(value: PythonObject) raises -> ScalarKind:
    var name = _exact_python_string(value, "scalar_kind")
    if name == "f32":
        return ScalarKind.f32()
    if name == "bf16":
        return ScalarKind.bf16()
    if name == "f16":
        return ScalarKind.f16()
    if name == "i8":
        return ScalarKind.i8()
    raise Error("unknown scalar_kind")


def _collection_config_from_python(
    dimension: Int, value: PythonObject
) raises -> CollectionConfig:
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(value) == builtins.dict):
        raise Error("collection config must be a dict or None")
    for raw_name in value:
        var name = _exact_python_string(raw_name, "collection config option")
        if (
            name != "dimension"
            and name != "ann_metric"
            and name != "scalar_kind"
            and name != "m"
            and name != "m0"
            and name != "ef_construction"
            and name != "default_ef_search"
            and name != "max_ef_search"
            and name != "max_level"
            and name != "rebuild_inactive_percent"
            and name != "delta_max_points"
            and name != "level_seed"
        ):
            raise Error("unknown collection config option: " + name)
    var config = CollectionConfig.defaults(dimension)
    if (
        _exact_python_int(
            value.get("dimension", PythonObject(dimension)), "dimension"
        )
        != dimension
    ):
        raise Error("collection config dimension mismatch")
    config.ann_metric = _metric_kind_from_python(
        value.get("ann_metric", PythonObject(config.metric_name()))
    )
    config.scalar_kind = _scalar_kind_from_python(
        value.get("scalar_kind", PythonObject(config.scalar_name()))
    )
    config.m = _exact_python_int(value.get("m", PythonObject(config.m)), "m")
    config.m0 = _exact_python_int(
        value.get("m0", PythonObject(config.m0)), "m0"
    )
    config.ef_construction = _exact_python_int(
        value.get("ef_construction", PythonObject(config.ef_construction)),
        "ef_construction",
    )
    config.default_ef_search = _exact_python_int(
        value.get("default_ef_search", PythonObject(config.default_ef_search)),
        "default_ef_search",
    )
    config.max_ef_search = _exact_python_int(
        value.get("max_ef_search", PythonObject(config.max_ef_search)),
        "max_ef_search",
    )
    config.max_level = _exact_python_int(
        value.get("max_level", PythonObject(config.max_level)), "max_level"
    )
    config.rebuild_inactive_percent = _exact_python_int(
        value.get(
            "rebuild_inactive_percent",
            PythonObject(config.rebuild_inactive_percent),
        ),
        "rebuild_inactive_percent",
    )
    config.delta_max_points = _exact_python_int(
        value.get("delta_max_points", PythonObject(config.delta_max_points)),
        "delta_max_points",
    )
    var seed = value.get("level_seed", Python.none())
    if not _is_python_none(seed):
        config.level_seed = UInt64(_exact_python_int64(seed, "level_seed"))
    return config^


def _named_field_ordinal(
    fields: List[VectorFieldSpec], name: String
) raises -> Int:
    if name.byte_length() == 0:
        raise Error("named field requires a nonempty name")
    for ordinal in range(2, len(fields)):
        if fields[ordinal].name == name:
            return ordinal
    raise Error("unknown vector field: " + name)


def _vector_kind_names() -> List[String]:
    return ["dense", "sparse", "multivector", "binary"]


def _vector_scalar_names() -> List[String]:
    return ["f32", "bf16", "f16", "i8", "u8", "binary"]


def _vector_metric_names() -> List[String]:
    return ["dot", "l2", "cosine", "hamming", "jaccard"]


def _vector_tag(value: PythonObject, names: List[String]) raises -> UInt8:
    var name = _exact_python_string(value, "vector schema tag")
    for index in range(len(names)):
        if names[index] == name:
            return UInt8(index)
    raise Error("unknown vector schema tag: " + name)


def _vector_field_from_python(raw: PythonObject) raises -> VectorFieldSpec:
    var id = _exact_python_int(raw["id"], "field ID")
    if id < 2:
        raise Error("named field IDs must follow reserved fields")
    var dimension = _exact_python_int(raw["dimension"], "field dimension")
    var kind = _vector_tag(raw["kind"], _vector_kind_names())
    var hnsw = Optional[CollectionConfig]()
    var index: UInt8 = 2 if kind == 1 else 0
    if not _is_python_none(raw["hnsw"]):
        hnsw = Optional(_collection_config_from_python(dimension, raw["hnsw"]))
        index = 1
    var spec = VectorFieldSpec(
        id,
        _exact_python_string(raw["name"], "field name"),
        kind,
        _vector_tag(raw["dtype"], _vector_scalar_names()),
        _vector_tag(raw["metric"], _vector_metric_names()),
        index,
        dimension,
        hnsw^,
    )
    spec.validate()
    return spec^


def _vector_field_to_python(field: VectorFieldSpec) raises -> PythonObject:
    var hnsw = Python.none()
    if field.hnsw:
        hnsw = _collection_config_to_python(field.hnsw.value())
    return Python.dict(
        id=PythonObject(field.id),
        name=PythonObject(field.name),
        dimension=PythonObject(field.dimension),
        kind=PythonObject(_vector_kind_names()[Int(field.kind)]),
        dtype=PythonObject(_vector_scalar_names()[Int(field.scalar)]),
        metric=PythonObject(_vector_metric_names()[Int(field.metric)]),
        hnsw=hnsw,
    )


def _is_python_none(value: PythonObject) -> Bool:
    return value is Python.none()


def _recommendation_examples_from_python(raw: PythonObject, field: VectorFieldSpec) raises -> List[RecommendationExample]:
    var result = List[RecommendationExample]()
    for i in range(len(raw)):
        result.append(_query_example_from_python(raw[i], field))
    return result^


def _query_example_from_python(item: PythonObject, field: VectorFieldSpec) raises -> RecommendationExample:
    var builtins = Python.import_module("builtins")
    if Bool(py=builtins.type(item) == builtins.int):
        return RecommendationExample.point(_exact_python_int(item, "point ID"))
    return RecommendationExample.raw(vector_from_python(item, field))


def _exact_python_int(value: PythonObject, name: String) raises -> Int:
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(value) == builtins.int):
        raise Error(name + " must be an integer")
    return Int(py=value)


def _exact_python_int64(value: PythonObject, name: String) raises -> Int64:
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(value) == builtins.int):
        raise Error(name + " must be an integer")
    return Int64(py=value)


def _exact_python_string(value: PythonObject, name: String) raises -> String:
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(value) == builtins.str):
        raise Error(name + " must be a string")
    return String(py=value)


def _collection_config_to_python(
    config: CollectionConfig,
) raises -> PythonObject:
    return Python.dict(
        dimension=PythonObject(config.dimension),
        ann_metric=PythonObject(config.metric_name()),
        scalar_kind=PythonObject(config.scalar_name()),
        m=PythonObject(config.m),
        m0=PythonObject(config.m0),
        ef_construction=PythonObject(config.ef_construction),
        default_ef_search=PythonObject(config.default_ef_search),
        max_ef_search=PythonObject(config.max_ef_search),
        max_level=PythonObject(config.max_level),
        rebuild_inactive_percent=PythonObject(config.rebuild_inactive_percent),
        delta_max_points=PythonObject(config.delta_max_points),
        level_seed=PythonObject(config.level_seed),
        fingerprint=PythonObject(config.fingerprint()),
    )


def validate_collection_config_py(
    dimension: PythonObject, value: PythonObject
) raises -> PythonObject:
    var native_dimension = _exact_python_int(dimension, "dimension")
    var config = CollectionConfig.defaults(native_dimension)
    if not _is_python_none(value):
        config = _collection_config_from_python(native_dimension, value)
    config.validate()
    return _collection_config_to_python(config)


def _ensure_open(collection: BoundCollection) raises:
    if not Bool(collection.inner):
        raise Error("collection is closed")


def _field_query_from_python(item: PythonObject, fields: List[VectorFieldSpec]) raises -> FieldQuery:
    var name = _exact_python_string(item["name"], "field name")
    var ordinal = _named_field_ordinal(fields, name)
    var mode = _exact_python_string(item["mode"], "search mode")
    if mode != "exact" and mode != "approx" and mode != "ivf":
        raise Error("field query mode must be exact, approx or ivf")
    return FieldQuery(name,
        vector_from_python(item["vector"], fields[ordinal]),
        approximate=mode == "approx",
        ef_search=_exact_python_int(item["ef_search"], "ef_search"),
        rerank_k=_exact_python_int(item["rerank_k"], "rerank_k"),
        ivf=_ivf_from_python(mode, item["ivf"]))


def _ivf_from_python(mode: String, raw: PythonObject) raises -> Optional[IvfOptions]:
    if mode != "ivf":
        if not _is_python_none(raw):
            raise Error("IVF options require ivf mode")
        return None
    if _is_python_none(raw):
        raise Error("IVF mode requires its query options")
    var options = IvfOptions(
        _exact_python_int(raw["nlist"], "nlist"),
        _exact_python_int(raw["nprobe"], "nprobe"),
        _exact_python_int(raw["iterations"], "iterations"),
    )
    options.validate()
    return Optional(options^)


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
    if len(value) > 1024:
        raise Error("payload field count exceeds limit")
    var result = List[DocumentField](capacity=len(value))
    var nodes = 0
    var content = 0
    for item in value:
        var name = String(py=item["name"])
        var kind = String(py=item["type"])
        var raw = item["value"]
        var parsed = payload_value_from_python(kind, raw)
        nodes += parsed.node_count()
        content += name.byte_length() + parsed.content_bytes()
        if nodes > PayloadValue.MAX_NODES or content > PayloadValue.MAX_BYTES:
            raise Error("payload node count or content exceeds limit")
        result.append(DocumentField(name, parsed^))
    return result^


def _formula_number_from_python(value: PythonObject) raises -> Float32:
    var builtins = Python.import_module("builtins")
    var kind = builtins.type(value)
    if not Bool(py=kind == builtins.float) and not Bool(py=kind == builtins.int):
        raise Error("formula numeric parameter must be a number")
    return Float32(py=value)


def _formula_expression_from_python(
    value: PythonObject, mut nodes: List[FormulaNode], depth: Int,
    mut count: Int, limit: Int,
) raises -> Int:
    if depth > 64 or count >= limit:
        raise Error("formula expression resource limit exceeded")
    count += 1
    var builtins = Python.import_module("builtins")
    var value_type = builtins.type(value)
    if Bool(py=value_type == builtins.str):
        nodes.append(FormulaNode("variable", key=String(py=value)))
    elif Bool(py=value_type == builtins.int) or Bool(py=value_type == builtins.float):
        nodes.append(FormulaNode("constant", value=Float32(py=value)))
    elif Bool(py=value_type == builtins.dict) and len(value) == 1:
        var kind = _exact_python_string(builtins.next(builtins.iter(value)), "formula operator")
        var arg = value[kind]
        var children = List[Int]()
        var condition = Optional[FilterExpression]()
        var fallback = Optional[Float32]()
        var midpoint = Float32(0.5)
        var scale = Float32(1)
        if kind == "condition":
            condition = Optional(_filter_expression(arg))
        elif kind == "sum" or kind == "mult":
            if not Bool(py=builtins.type(arg) == builtins.list) and not Bool(py=builtins.type(arg) == builtins.tuple):
                raise Error("formula sum/mult requires a list")
            if len(arg) > limit - count:
                raise Error("formula expression resource limit exceeded")
            for i in range(len(arg)):
                children.append(_formula_expression_from_python(arg[i], nodes, depth + 1, count, limit))
        elif kind == "div" or kind == "pow" or kind == "lin_decay" or kind == "exp_decay" or kind == "gauss_decay":
            if not Bool(py=builtins.type(arg) == builtins.dict):
                raise Error("formula operator parameters must be a dictionary")
            var allowed = Python.list()
            if kind == "div" or kind == "pow":
                var left = "left" if kind == "div" else "base"
                var right = "right" if kind == "div" else "exponent"
                allowed.append(left)
                allowed.append(right)
                children.append(_formula_expression_from_python(arg[left], nodes, depth + 1, count, limit))
                children.append(_formula_expression_from_python(arg[right], nodes, depth + 1, count, limit))
                if kind == "div":
                    allowed.append("by_zero_default")
                    if Bool(py=arg.__contains__("by_zero_default")):
                        fallback = Optional(_formula_number_from_python(arg["by_zero_default"]))
            else:
                allowed.append("x")
                allowed.append("target")
                allowed.append("midpoint")
                allowed.append("scale")
                children.append(_formula_expression_from_python(arg["x"], nodes, depth + 1, count, limit))
                if Bool(py=arg.__contains__("target")):
                    children.append(_formula_expression_from_python(arg["target"], nodes, depth + 1, count, limit))
                midpoint = _formula_number_from_python(arg.get("midpoint", PythonObject(0.5)))
                scale = _formula_number_from_python(arg.get("scale", PythonObject(1)))
            for key in arg:
                if not Bool(py=allowed.__contains__(key)):
                    raise Error("unknown formula operator parameter")
        elif kind == "neg" or kind == "abs" or kind == "sqrt" or kind == "exp" or kind == "ln" or kind == "log10":
            children.append(_formula_expression_from_python(arg, nodes, depth + 1, count, limit))
        else:
            raise Error("unsupported formula operator")
        nodes.append(FormulaNode(kind, children^, condition=condition^,
            by_zero_default=fallback, midpoint=midpoint, scale=scale))
    else:
        raise Error("formula expression must be a number, variable or one operator")
    return len(nodes) - 1


def _formula_from_python(value: PythonObject, limit: Int) raises -> Formula:
    var builtins = Python.import_module("builtins")
    var raw_defaults = value["defaults"]
    if not Bool(py=builtins.type(raw_defaults) == builtins.dict):
        raise Error("formula defaults must be a dictionary")
    if len(raw_defaults) > 1024 or len(raw_defaults) >= limit:
        raise Error("formula default resource limit exceeded")
    var nodes = List[FormulaNode]()
    var count = 0
    _ = _formula_expression_from_python(value["expression"], nodes, 0, count, min(1024, limit - len(raw_defaults)))
    var defaults = List[FormulaDefault]()
    for key in raw_defaults:
        var name = _exact_python_string(key, "formula default name")
        var raw = raw_defaults[key]
        var kind = builtins.type(raw)
        var item: PayloadValue
        if Bool(py=kind == builtins.str):
            item = PayloadValue.string(String(py=raw))
        elif Bool(py=kind == builtins.bool):
            item = PayloadValue.boolean(Bool(py=raw))
        elif Bool(py=kind == builtins.int):
            item = PayloadValue.integer(Int64(py=raw))
        elif Bool(py=kind == builtins.float):
            item = PayloadValue.floating(Float64(py=raw))
        else:
            raise Error("formula default must be a flat scalar value")
        defaults.append(FormulaDefault(name, item^))
    return Formula(nodes^, defaults^)


def _filter_expression(value: PythonObject) raises -> FilterExpression:
    var count = 0
    return _bounded_filter_expression(value, 0, count)


def _bounded_filter_expression(value: PythonObject, depth: Int, mut count: Int) raises -> FilterExpression:
    if depth > FilterExpression.MAX_DEPTH or count >= FilterExpression.MAX_NODES:
        raise Error("filter expression resource limit exceeded")
    count += 1
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
        var child = _bounded_filter_expression(value["child"], depth + 1, count)
        return FilterExpression.negate(child^)
    if kind == "all" or kind == "any":
        var children = List[FilterExpression]()
        for item in value["children"]:
            children.append(_bounded_filter_expression(item, depth + 1, count))
        if kind == "all":
            return FilterExpression.all(children^)
        return FilterExpression.any(children^)
    raise Error("unknown filter expression kind")


def _payload_value(kind: String, raw: PythonObject) raises -> PayloadValue:
    if kind != "string" and kind != "int" and kind != "float" and kind != "bool":
        raise Error("unknown filter value type")
    return payload_value_from_python(kind, raw)


def _field_to_python(field: DocumentField) raises -> PythonObject:
    return Python.dict(
        name=PythonObject(field.name),
        type=PythonObject(payload_kind_name(field.value)),
        value=payload_value_to_python(field.value),
    )



def _set_output_item(
    target: PythonObject, key: PythonObject, value: PythonObject
) raises:
    # These are freshly built output dictionaries, with owned Python values.
    # PyDict_SetItem borrows all three arguments; the caller keeps them alive.
    if Python().cpython().PyDict_SetItem(
        target._obj_ptr, key._obj_ptr, value._obj_ptr
    ) != 0:
        raise Python().cpython().unsafe_get_error()


def _point_to_python(
    point: PointState, schema: List[VectorFieldSpec]
) raises -> PythonObject:
    var dense = Python.none()
    var sparse = Python.none()
    var vectors = Python.dict()
    for ordinal in range(point.field_count()):
        ref field = point.field_at(ordinal)
        var value = vector_to_python(field.value())
        if field.id == 0:
            dense = value
        elif field.id == 1:
            sparse = value
        else:
            for spec in schema:
                if spec.id == field.id:
                    _set_output_item(vectors, PythonObject(spec.name), value)
                    break
    var payload = List[PythonObject]()
    for index in range(len(point.payload())):
        payload.append(_field_to_python(point.payload()[index]))
    return Python.dict(
        id=PythonObject(point.id),
        sequence=PythonObject(point.sequence),
        document_sequence=PythonObject(point.document_sequence),
        vector=dense,
        sparse=sparse,
        vectors=vectors,
        fields=Python.list(Span(payload)),
    )

def _document_to_python(
    record: Optional[DocumentRecord],
) raises -> PythonObject:
    if not Bool(record):
        return Python.none()
    var fields = List[PythonObject]()
    for index in range(len(record.value().fields)):
        fields.append(_field_to_python(record.value().fields[index]))
    var vector = List[PythonObject]()
    for value in record.value().vector:
        vector.append(value)
    return Python.dict(
        id=PythonObject(record.value().id),
        sequence=PythonObject(record.value().sequence),
        vector=Python.list(Span(vector)),
        fields=Python.list(Span(fields)),
    )


def _results_to_python[
    columns: Bool = False
](results: List[SearchResult]) raises -> PythonObject:
    comptime if columns:
        var np = Python.import_module("numpy")
        var ids_array = np.empty(len(results), dtype="int64")
        var scores_array = np.empty(len(results), dtype="float32")
        var ids = from_numpy_array[DType.int64](ids_array)
        var scores = from_numpy_array[DType.float32](scores_array)
        for index in range(len(results)):
            ids[index] = Int64(results[index].id)
            scores[index] = results[index].score
        return Python.dict(ids=ids_array, scores=scores_array)
    # Build owned rows without PythonObject's dynamic positional call path.
    # Mojo 1.0.0 retains an extra argument reference for output.append(row).
    var output = List[PythonObject](capacity=len(results))
    for result in results:
        output.append(
            Python.dict(
                id=PythonObject(result.id), score=PythonObject(result.score)
            )
        )
    return Python.list(Span(output))


def _storage_report_to_python(report: StorageInspection) raises -> PythonObject:
    var segments = List[PythonObject]()
    for name in report.segment_names:
        segments.append(name)
    var sparse = List[PythonObject]()
    for name in report.sparse_names:
        sparse.append(name)
    return Python.dict(
        dimension=PythonObject(report.dimension),
        format_version=PythonObject(report.format_version),
        generation=PythonObject(report.generation),
        last_sequence=PythonObject(report.last_sequence),
        segment_count=PythonObject(report.segment_count),
        live_points=PythonObject(report.live_points),
        valid=PythonObject(report.valid),
        config_fingerprint=PythonObject(report.config_fingerprint),
        segment_names=Python.list(Span(segments)),
        sparse_names=Python.list(Span(sparse)),
    )


def inspect_storage_py(
    path: PythonObject, dimension: PythonObject
) raises -> PythonObject:
    return _storage_report_to_python(
        inspect_storage(String(py=path), Int(py=dimension))
    )


def restore_storage_py(
    backup: PythonObject, target: PythonObject, dimension: PythonObject
) raises -> PythonObject:
    return _storage_report_to_python(
        restore_storage(String(py=backup), String(py=target), Int(py=dimension))
    )


@export
def PyInit__kernel() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("_kernel")
        _ = (
            module.add_type[BoundScanner]("Scanner")
            .def_py_init[BoundScanner.py_init]()
            .def_method[BoundScanner.schema]("schema")
            .def_method[BoundScanner.next_batch]("next_batch")
            .def_method[BoundScanner.close]("close")
        )
        _ = (
            module.add_type[BoundCollection]("Collection")
            .def_py_init[BoundCollection.py_init]()
            .def_method[BoundCollection.close]("close")
            .def_method[BoundCollection.last_sequence]("last_sequence")
            .def_method[BoundCollection.collection_config]("collection_config")
            .def_method[BoundCollection.last_search_stats]("last_search_stats")
            .def_method[BoundCollection.upsert]("upsert")
            .def_method[BoundCollection.upsert_document]("upsert_document")
            .def_method[BoundCollection.apply_batch]("apply_batch")
            .def_method[BoundCollection.vector_fields]("vector_fields")
            .def_method[BoundCollection.apply_point_batch]("apply_point_batch")
            .def_method[BoundCollection.apply_point_arrow_batch](
                "apply_point_arrow_batch"
            )
            .def_method[BoundCollection.get_point]("get_point")
            .def_method[BoundCollection.search_fields[False]]("search_fields")
            .def_method[BoundCollection.search_fields[True]](
                "search_fields_columns"
            )
            .def_method[BoundCollection.recommend_field[False]]("recommend_field")
            .def_method[BoundCollection.recommend_field[True]]("recommend_field_columns")
            .def_method[BoundCollection.discover_field[False]]("discover_field")
            .def_method[BoundCollection.query[False]]("query")
            .def_method[BoundCollection.query[True]]("query_columns")
            .def_method[BoundCollection.discover_field[True]]("discover_field_columns")
            .def_method[BoundCollection.search_field[False]]("search_field")
            .def_method[BoundCollection.search_field[True]](
                "search_field_columns"
            )
            .def_method[BoundCollection.search_field[False, True]]("search_field_by_id")
            .def_method[BoundCollection.search_field[True, True]]("search_field_by_id_columns")
            .def_method[BoundCollection.upsert_sparse]("upsert_sparse")
            .def_method[BoundCollection.delete]("delete")
            .def_method[BoundCollection.flush]("flush")
            .def_method[BoundCollection.backup_to]("backup_to")
            .def_method[BoundCollection.export_records]("export_records")
            .def_method[BoundCollection.export_points]("export_points")
            .def_method[BoundCollection.is_point_collection](
                "is_point_collection"
            )
            .def_method[BoundCollection.scanner]("scanner")
            .def_method[BoundCollection.search_controlled]("search_controlled")
            .def_method[BoundCollection.get]("get")
            .def_method[BoundCollection.get_projected]("get_projected")
            .def_method[BoundCollection.apply_arrow_batch]("apply_arrow_batch")
            .def_method[BoundCollection.search_dot[True]]("search_dot_columns")
            .def_method[BoundCollection.search_dot[False]]("search_dot")
            .def_method[BoundCollection.search_l2[True]]("search_l2_columns")
            .def_method[BoundCollection.search_l2[False]]("search_l2")
            .def_method[BoundCollection.search_cosine[True]](
                "search_cosine_columns"
            )
            .def_method[BoundCollection.search_cosine[False]]("search_cosine")
            .def_method[BoundCollection.search_batch]("search_batch")
            .def_method[BoundCollection.search_batch_where](
                "search_batch_where"
            )
            .def_method[BoundCollection.search_approx[True]](
                "search_approx_columns"
            )
            .def_method[BoundCollection.search_approx[False]]("search_approx")
            .def_method[BoundCollection.search_sparse[True]](
                "search_sparse_columns"
            )
            .def_method[BoundCollection.search_sparse[False]]("search_sparse")
            .def_method[BoundCollection.search_hybrid[True]](
                "search_hybrid_columns"
            )
            .def_method[BoundCollection.search_hybrid[False]]("search_hybrid")
            .def_method[BoundCollection.search_dense_where[True]](
                "search_dense_where_columns"
            )
            .def_method[BoundCollection.search_dense_where[False]](
                "search_dense_where"
            )
            .def_method[BoundCollection.search_sparse_where[True]](
                "search_sparse_where_columns"
            )
            .def_method[BoundCollection.search_sparse_where[False]](
                "search_sparse_where"
            )
            .def_method[BoundCollection.search_hybrid_where[True]](
                "search_hybrid_where_columns"
            )
            .def_method[BoundCollection.search_hybrid_where[False]](
                "search_hybrid_where"
            )
        )
        module.def_function[inspect_storage_py]("inspect_storage")
        module.def_function[restore_storage_py]("restore_storage")
        module.def_function[validate_collection_config_py](
            "validate_collection_config"
        )
        return module.finalize()
    except error:
        abort(String("failed to create Akasha Python module: ", error))


def _apply_arrow_buffers(
    py_self: PythonObject,
    descriptor: PythonObject,
    ids_array: PythonObject,
    vectors_array: PythonObject,
    offsets_array: PythonObject,
    terms_array: PythonObject,
    weights_array: PythonObject,
) raises -> PythonObject:
    """Retain array owners; borrow the collection only after Python conversion."""
    var handle = py_self.downcast_value_ptr[BoundCollection]()
    _ensure_open(handle[])
    var row_count = Int(py=descriptor["row_count"])
    if row_count <= 0 or row_count > 65_536:
        raise Error("Arrow batch row count is invalid")
    var ids = from_numpy_array[DType.int64](ids_array)
    var vectors = from_numpy_array[DType.float32](vectors_array)
    _ensure_open(handle[])
    var dimension = handle[].inner.value().dimension
    if len(ids) != row_count or len(vectors) != row_count * dimension:
        raise Error("Arrow primitive buffer length mismatch")

    var points = List[PointMutation](capacity=row_count)
    var has_sparse = Bool(py=descriptor["has_sparse"])
    var sparse_offsets = from_numpy_array[DType.int32](offsets_array)
    var sparse_terms = from_numpy_array[DType.int64](terms_array)
    var sparse_weights = from_numpy_array[DType.float32](weights_array)
    if has_sparse and len(sparse_offsets) != row_count + 1:
        raise Error("Arrow sparse offsets length mismatch")

    for row in range(row_count):
        var vector = List[Float32](capacity=dimension)
        vector.extend(vectors[row * dimension : (row + 1) * dimension])
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
        var sparse = List[SparseElement]()
        if has_sparse:
            var begin = Int(sparse_offsets[row])
            var end = Int(sparse_offsets[row + 1])
            if begin < 0 or end < begin or end > len(sparse_terms):
                raise Error("Arrow sparse offsets are invalid")
            if len(sparse_terms) != len(sparse_weights):
                raise Error("Arrow sparse value buffers are misaligned")
            for index in range(begin, end):
                sparse.append(
                    SparseElement(
                        Int(sparse_terms[index]),
                        sparse_weights[index],
                    )
                )
            validate_sparse(sparse)
        var updates = List[FieldUpdate]()
        updates.append(
            FieldUpdate.set(0, VectorValue.dense[DType.float32](vector^))
        )
        if has_sparse:
            updates.append(FieldUpdate.set(1, VectorValue.sparse(sparse^)))
        points.append(
            PointMutation(Int(ids[row]), 1, updates^, Optional(fields^))
        )

    _ensure_open(handle[])
    ref collection = handle[].inner.value()
    _ = collection.apply_point_batch(points)
    return PythonObject(row_count)


def _field_results_to_python[
    columns: Bool
](results: List[FieldSearchResult]) raises -> PythonObject:
    comptime if columns:
        var np = Python.import_module("numpy")
        var ids_array = np.empty(len(results), dtype="int64")
        var scores_array = np.empty(len(results), dtype="float64")
        var ids = from_numpy_array[DType.int64](ids_array)
        var scores = from_numpy_array[DType.float64](scores_array)
        for index in range(len(results)):
            ids[index] = Int64(results[index].id)
            scores[index] = results[index].score
        return Python.dict(ids=ids_array, scores=scores_array)
    # Build owned rows without PythonObject's dynamic positional call path.
    # Mojo 1.0.0 retains an extra argument reference for output.append(row).
    var output = List[PythonObject](capacity=len(results))
    for result in results:
        output.append(
            Python.dict(
                id=PythonObject(result.id), score=PythonObject(result.score)
            )
        )
    return Python.list(Span(output))
