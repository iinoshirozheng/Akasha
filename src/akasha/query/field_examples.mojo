"""Shared vector/ID resolution for captured-root custom queries.

Qdrant recommendations.rs and discovery.rs, revision 74f3e85b9473c625,
Apache-2.0. Keep the existing public RecommendationExample input type.
"""
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.query.control import QueryControl
from akasha.query.field_lookup import resolve_point_field
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_input
from akasha.storage.read_generation import ReadGeneration


@fieldwise_init
struct RecommendationExample(Movable):
    var id: Optional[Int]
    var vector: Optional[VectorValue]

    @staticmethod
    def point(id: Int) -> Self:
        return Self(Optional(id), None)

    @staticmethod
    def raw(var value: VectorValue) -> Self:
        return Self(None, Optional(value^))


def resolve_query_example(
    example: RecommendationExample, source: ReadGeneration,
    name: String, field: VectorFieldSpec, same: Bool,
    mut excluded: Dict[Int, Bool],
) raises -> VectorValue:
    var value: VectorValue
    if example.id:
        if example.vector:
            raise Error("query example must contain either ID or vector")
        var point = resolve_point_field(source, name, example.id.value())
        ref catalog = source.catalog.value()[]
        ref source_field = catalog.field_at(catalog.named_ordinal(name))
        # Qdrant retrieves already preprocessed stored vectors. Akasha keeps
        # raw native authority, so reconstruct that representation here.
        value = prepare_recommendation_vector(point.value(), source_field)
        if same:
            excluded[example.id.value()] = True
    elif example.vector:
        value = recommendation_input(example.vector.value())
    else:
        raise Error("query example is empty")
    if value.kind() != field.kind or (field.kind != 1 and value.dimension() != field.dimension):
        raise Error("query vector kind or dimension mismatch")
    if field.kind == 2 and value.row_count() == 0:
        raise Error("query multivector example must have rows")
    return value^


def resolve_query_examples(
    examples: List[RecommendationExample], source: ReadGeneration,
    name: String, field: VectorFieldSpec, same: Bool,
    mut excluded: Dict[Int, Bool], control: Optional[QueryControl],
) raises -> List[VectorValue]:
    var result = List[VectorValue]()
    for i in range(len(examples)):
        if control:
            control.value().checkpoint(i)
        result.append(resolve_query_example(examples[i], source, name, field, same, excluded))
    return result^
