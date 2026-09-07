"""Validated HTTP-only request and response schemas."""

from typing import Any, Literal

from pydantic import AliasChoices, BaseModel, ConfigDict, Field

from akashadb import CollectionConfig


class OpenCollectionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    dimension: int = Field(gt=0)
    ann_metric: Literal["dot", "l2", "cosine"] | None = Field(
        default=None, validation_alias=AliasChoices("ann_metric", "annMetric")
    )
    scalar_kind: Literal["f32", "bf16", "f16", "i8"] | None = Field(
        default=None, validation_alias=AliasChoices("scalar_kind", "scalarKind")
    )
    m: int | None = Field(
        default=None, ge=0, validation_alias=AliasChoices("m", "M")
    )
    m0: int | None = Field(
        default=None, ge=0, validation_alias=AliasChoices("m0", "M0")
    )
    ef_construction: int | None = Field(
        default=None,
        ge=0,
        validation_alias=AliasChoices("ef_construction", "efConstruction"),
    )
    default_ef_search: int | None = Field(
        default=None,
        ge=0,
        validation_alias=AliasChoices("default_ef_search", "defaultEfSearch"),
    )
    max_ef_search: int | None = Field(
        default=None,
        ge=0,
        validation_alias=AliasChoices("max_ef_search", "maxEfSearch"),
    )
    max_level: int | None = Field(
        default=None,
        ge=0,
        validation_alias=AliasChoices("max_level", "maxLevel"),
    )
    rebuild_inactive_percent: int | None = Field(
        default=None,
        ge=0,
        validation_alias=AliasChoices(
            "rebuild_inactive_percent", "rebuildInactivePercent"
        ),
    )
    delta_max_points: int | None = Field(
        default=None,
        ge=0,
        validation_alias=AliasChoices("delta_max_points", "deltaMaxPoints"),
    )
    level_seed: int | None = Field(
        default=None,
        ge=0,
        le=0xFFFF_FFFF_FFFF_FFFF,
        validation_alias=AliasChoices("level_seed", "levelSeed"),
    )

    def collection_config(self) -> CollectionConfig | None:
        values = self.model_dump(exclude_none=True)
        dimension = int(values.pop("dimension"))
        if not values:
            return None
        return CollectionConfig.defaults(dimension, **values)


class PayloadFieldRequest(BaseModel):
    name: str = Field(min_length=1)
    type: Literal["string", "int", "float", "bool"]
    value: str | int | float | bool


class SparseElementRequest(BaseModel):
    term_id: int = Field(ge=0)
    weight: float


class UpsertRequest(BaseModel):
    id: int
    vector: list[float] = Field(min_length=1)
    fields: list[PayloadFieldRequest] | None = None
    sparse: list[SparseElementRequest] | None = None


class SearchRequestBody(BaseModel):
    metric: Literal["dot", "l2", "cosine"] = "cosine"
    mode: Literal["exact", "approx", "sparse", "hybrid"] = "exact"
    k: int = Field(gt=0)
    vector: list[float] | None = None
    sparse: list[SparseElementRequest] = Field(default_factory=list)
    ef_search: int = Field(default=64, gt=0)
    fetch_k: int = Field(default=50, gt=0)
    rank_constant: int = Field(default=60, gt=0)
    filter: dict[str, Any] | None = None


class SearchResultResponse(BaseModel):
    id: int
    score: float
