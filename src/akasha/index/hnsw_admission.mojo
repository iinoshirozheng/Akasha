"""Eligibility contract shared by graph construction and traversal."""

trait HnswResultAdmission:
    """Internal result-admission contract shared by graph search paths."""

    def is_allow_all(self) -> Bool:
        ...

    def validate(self, slot_count: Int) raises:
        ...

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        ...
