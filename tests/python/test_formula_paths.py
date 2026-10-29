"""Qdrant path syntax at the public formula boundary."""
from contextlib import closing
import json
from pathlib import Path

import pytest

from akashadb import Collection, Formula, PayloadField, PointMutation, QueryRequest, ValidationError
from akashadb.arrow import query_record_batch


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-json-path/paths.json").read_text())


@pytest.fixture
def db(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(1, fields=[
            PayloadField(name, "float", value) for name, value in [
                ("plain", 1), ("a.b[]", 2), ("a b", 3), ("$score", 4),
                ("中文", 5), ("😀", 6), ("e\u0301", 7), ("line\nfeed", 8)]])])
        yield db


def query(expression, defaults=None):
    return QueryRequest("formula", prefetch=(QueryRequest(),), formula=Formula(expression, defaults or {}))


@pytest.mark.parametrize("expression,expected", [
    ("plain", 1), ('"plain"', 1), ('"a.b[]"', 2), ('"a b"', 3), ('"$score"', 4),
    ("中文", 5), ('"😀"', 6), ('"e\u0301"', 7), ('"line\nfeed"', 8),
    ("$score", 0), ('$"score"', 0), ('$"score"[00]', 0),
    ("$score[18446744073709551615]", 0),
])
def test_formula_reads_literal_quoted_and_unicode_payload_keys(db, expression, expected):
    hits = db.query(query(expression))
    assert [(h.id, h.score) for h in hits] == [(1, expected)]
    assert query_record_batch(db, query(expression)).to_pydict() == {"id": [1], "score": [expected]}


@pytest.mark.parametrize("expression,default", [
    ('"missing key"', { '"missing key"': 3.25}),
    ('"missing"', {"missing": 3.25}), ("missing", {'"missing"': 3.25}),
    ('"a\x00"', {'"a\x00"': 3.25}), ('""', {'""': 3.25}),
    ("$score[9223372036854775808]", {'$"score"[09223372036854775808]': 3.25}),
    ('$"score"[18446744073709551615]', {"$score[18446744073709551615]": 3.25}),
])
def test_formula_normalizes_default_aliases_and_full_uint64_indexes(db, expression, default):
    assert db.query(query(expression, default))[0].score == 3.25


@pytest.mark.parametrize("defaults", [
    {"plain": 1, '"plain"': 2}, {"$score": 1, '$"score"[000]': 2},
    {"$score[18446744073709551615]": 1, '$"score"[18446744073709551615]': 2},
])
def test_formula_rejects_duplicate_normalized_default_paths(db, defaults):
    with pytest.raises(ValidationError, match="duplicate"):
        db.query(query(1, defaults))


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=lambda c: c["input"])
def test_formula_acceptance_matches_source_variable_parser_with_explicit_rich_value_gap(db, case):
    variable = case["variable"]
    if variable is None:
        with pytest.raises(ValidationError):
            db.query(query(case["input"]))
        return
    if "payload" in variable and variable["payload"]["rest"]:
        with pytest.raises(ValidationError, match="rich payload"):
            db.query(query(case["input"], {case["input"]: 1}))
        return
    # Use a matching default for all missing flat keys. Stored values retain
    # priority; score[0] resolves the zero-score scroll source.
    hits = db.query(query(case["input"], {case["input"]: 1}))
    assert [h.id for h in hits] == [1]


def test_nested_syntax_never_reads_literal_dot_field_without_quotes(db):
    db.apply_point_batch([PointMutation.update(1, fields=[PayloadField("a.b", "float", 9)])])
    assert db.query(query('"a.b"'))[0].score == 9
    with pytest.raises(ValidationError, match="rich payload"):
        db.query(query("a.b"))


def test_formula_path_limits_are_enforced_before_recursion(db):
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(query("x" * 65537))
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(query("x" + "[]" * 1024))
