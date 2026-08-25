from akasha.document import DocumentField, DocumentRecord, PayloadValue
from std.math import inf
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_payload_value_exposes_only_its_active_type() raises:
    var text = PayloadValue.string("hello")
    var integer = PayloadValue.integer(-42)
    var floating = PayloadValue.floating(3.5)
    var boolean = PayloadValue.boolean(True)

    assert_equal(text.as_string(), "hello")
    assert_equal(integer.as_int(), Int64(-42))
    assert_almost_equal(floating.as_float(), 3.5, atol=1.0e-12)
    assert_equal(boolean.as_bool(), True)
    with assert_raises():
        _ = text.as_int()
    with assert_raises():
        _ = boolean.as_string()


def test_float_payload_rejects_non_finite_values() raises:
    with assert_raises():
        _ = PayloadValue.floating(inf[DType.float64]())


def test_document_field_rejects_invalid_names() raises:
    with assert_raises():
        _ = DocumentField("", PayloadValue.string("empty"))
    with assert_raises():
        _ = DocumentField("bad\0name", PayloadValue.string("nul"))


def test_document_record_lookup_and_clone_are_owned() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("Akasha")))
    fields.append(DocumentField("page", PayloadValue.integer(7)))
    var vector: List[Float32] = [1.0, 2.0]
    var record = DocumentRecord(10, 3, vector^, fields^)

    var chunk = record.get_field("chunk")
    var missing = record.get_field("missing")
    assert_true(Bool(chunk))
    assert_false(Bool(missing))
    assert_equal(chunk.value().as_string(), "Akasha")

    var cloned = record.clone()
    cloned.vector[0] = 99.0
    cloned.fields[0].name = "changed"
    assert_equal(record.vector[0], Float32(1.0))
    assert_equal(record.fields[0].name, "chunk")


def test_document_record_rejects_duplicate_names() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("source", PayloadValue.string("a")))
    fields.append(DocumentField("source", PayloadValue.string("b")))
    var vector: List[Float32] = [1.0]

    with assert_raises():
        _ = DocumentRecord(1, 1, vector^, fields^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
