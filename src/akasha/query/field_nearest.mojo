"""Shared nearest retrieval with optional source-derived MMR rescoring."""

from akasha.compute.field_metrics import validate_field_query
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.field_ivf import IvfOptions
from akasha.query.control import QueryControl
from akasha.query.field_ann import search_generation_field_approx, validate_approx_field_options
from akasha.query.field_ivf import search_generation_field_ivf, validate_ivf_field_options
from akasha.query.field_search import FieldSearchExecution, FieldSearchResult, field_exact_stats, search_generation_field_reported
from akasha.query.field_mmr import rerank_generation_mmr
from akasha.query.filter_ast import FilterExpression
from akasha.query.mmr import MmrOptions
from akasha.storage.read_generation import ReadGeneration


def search_generation_nearest(
    view: ReadGeneration, field: VectorFieldSpec, query: VectorValue, k: Int,
    expression: Optional[FilterExpression], *, approximate: Bool = False,
    ef_search: Int = -1, rerank_k: Int = 0, ivf: Optional[IvfOptions] = None,
    control: Optional[QueryControl] = None,
    excluded_ids: Optional[Dict[Int, Bool]] = None, mmr: Optional[MmrOptions] = None,
) raises -> FieldSearchExecution:
    if ivf and (approximate or ef_search != -1 or rerank_k != 0):
        raise Error("IVF cannot be combined with HNSW options")
    if not approximate and (ef_search != -1 or rerank_k != 0):
        raise Error("ef_search and rerank_k require approximate field search")
    var count = k
    if mmr:
        count = mmr.value().candidate_count(k)
        if field.kind == 3:
            raise Error("binary MMR is not supported by Qdrant")
        validate_field_query(query, field)
        if expression:
            expression.value().validate()
        if control:
            control.value().checkpoint(0)
        if count == 0:
            if ivf:
                validate_ivf_field_options(field, ivf.value())
            elif approximate:
                _ = validate_approx_field_options(field, 0, ef_search, rerank_k)
            var stats = field_exact_stats(field)
            stats.backend_name = "qdrant-mmr-f32"
            stats.storage_name = "field-mmr"
            return FieldSearchExecution(List[FieldSearchResult](), stats^, "field_mmr")
    var execution: FieldSearchExecution
    if ivf:
        execution = search_generation_field_ivf(
            view, field, query, count, expression, ivf.value().nlist,
            ivf.value().nprobe, ivf.value().iterations, control, excluded_ids,
        )
    elif approximate:
        execution = search_generation_field_approx(
            view, field, query, count, expression, ef_search, rerank_k,
            control, excluded_ids,
        )
    else:
        execution = search_generation_field_reported(
            view, field, query, count, expression, control, excluded_ids,
        )
    if mmr:
        return rerank_generation_mmr(view, field, query, execution^, k, mmr.value().diversity, control)
    return execution^
