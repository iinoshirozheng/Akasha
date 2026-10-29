"""Stored-vector lookup and ID exclusions on retained read roots.

Ported from Qdrant fetch_vectors.rs ReferencedVectors::resolve_reference and
collection_query.rs reference exclusion, revision
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
See THIRD_PARTY_NOTICES.md and docs/upstream/ports.json.
"""

from akasha.document.point_state import PointField
from akasha.index.field_ivf import IvfOptions
from akasha.query.control import QueryControl
from akasha.query.field_nearest import search_generation_nearest
from akasha.query.mmr import MmrOptions
from akasha.query.field_search import FieldSearchExecution
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration
from std.os.path import realpath


def same_collection_roots(left: ReadGeneration, right: ReadGeneration) raises -> Bool:
    if Int(left._pins.unsafe_ptr()) == Int(right._pins.unsafe_ptr()):
        return True
    # A retained snapshot may outlive its writer and be used after reopen.
    # Canonical paths also handle an explicit lookup through a directory symlink.
    if left._pins[]._directory == "" or right._pins[]._directory == "":
        return False
    return realpath(left._pins[]._directory) == realpath(right._pins[]._directory)


def resolve_point_field(view: ReadGeneration, name: String, id: Int) raises -> PointField:
    """Resolve an ID to an immutable native owner, never a Python vector copy."""
    if not view.catalog:
        raise Error("named lookup requires a field-aware collection")
    var ordinal = view.catalog.value()[].named_ordinal(name)
    if ordinal < 0:
        raise Error("unknown named lookup field")
    var location = view.find(id)
    if location[0] < 0:
        raise Error("lookup point not found")
    ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
    var field = entry.field_ordinal(view.catalog.value()[].field_at(ordinal).id)
    if field < 0:
        raise Error("lookup point has no requested vector")
    return entry.vector_at(field).copy()


def search_generation_field_by_id(
    view: ReadGeneration,
    source: ReadGeneration,
    name: String,
    id: Int,
    k: Int,
    expression: Optional[FilterExpression],
    *,
    lookup_field: Optional[String] = None,
    approximate: Bool = False,
    ef_search: Int = -1,
    rerank_k: Int = 0,
    ivf: Optional[IvfOptions] = None,
    mmr: Optional[MmrOptions] = None,
    control: Optional[QueryControl] = None,
) raises -> FieldSearchExecution:
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(view.visible_count)
    if not view.catalog:
        raise Error("named search requires a field-aware collection")
    ref catalog = view.catalog.value()[]
    var ordinal = catalog.named_ordinal(name)
    if ordinal < 0:
        raise Error("unknown named vector field")
    var query = resolve_point_field(
        source, lookup_field.value() if lookup_field else name, id
    )
    var excluded = Optional[Dict[Int, Bool]]()
    if same_collection_roots(view, source):
        var ids = Dict[Int, Bool]()
        ids[id] = True
        excluded = Optional(ids^)
    ref field = catalog.field_at(ordinal)
    return search_generation_nearest(
        view, field, query.value(), k, expression, approximate=approximate,
        ef_search=ef_search, rerank_k=rerank_k, ivf=ivf, mmr=mmr,
        control=control, excluded_ids=excluded,
    )
