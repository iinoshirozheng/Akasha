"""Validated HTTP-only request and response schemas."""

from typing import Any, Literal

from pydantic import BaseModel, Field


class OpenCollectionRequest(BaseModel):
    dimension: int = Field(gt=0)


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
