"""Prepared custom query boundary shared by recommendation and discovery."""

from akasha.document.vector_value import VectorValue
from akasha.query.control import QueryControl


trait PreparedFieldQuery(Deinitable, Movable):
    def query_name(self) -> String:
        ...

    def similarity_count(self) -> Int:
        ...

    def score(self, stored: VectorValue, control: Optional[QueryControl]) raises -> Float32:
        ...

    def ranking_score(self, score: Float32) -> Float32:
        """Adapt source scores to the native numeric heap ordering."""
        return score

    def public_score(self, score: Float32) -> Float32:
        return score
