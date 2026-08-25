from akasha import (
    DocumentField,
    FilterCondition,
    PayloadValue,
    PersistentCollection,
)


def main() raises:
    var path = String("/tmp/akasha-persistent-example")
    var collection = PersistentCollection.open(path, 3)

    var chunk_fields = List[DocumentField]()
    chunk_fields.append(
        DocumentField("document_type", PayloadValue.string("chunk"))
    )
    chunk_fields.append(
        DocumentField(
            "chunk_text",
            PayloadValue.string("Akasha stores vectors with typed payloads."),
        )
    )
    chunk_fields.append(DocumentField("source_page", PayloadValue.integer(7)))
    chunk_fields.append(
        DocumentField("confidence", PayloadValue.floating(0.98))
    )
    collection.upsert_document(101, [1.0, 0.0, 0.0], chunk_fields^)

    var image_fields = List[DocumentField]()
    image_fields.append(
        DocumentField("document_type", PayloadValue.string("image"))
    )
    image_fields.append(
        DocumentField(
            "image_uri", PayloadValue.string("s3://examples/diagram.png")
        )
    )
    image_fields.append(
        DocumentField("mime_type", PayloadValue.string("image/png"))
    )
    image_fields.append(DocumentField("source_page", PayloadValue.integer(2)))
    image_fields.append(DocumentField("verified", PayloadValue.boolean(True)))
    collection.upsert_document(202, [0.8, 0.2, 0.0], image_fields^)
    collection.upsert(303, [0.0, 1.0, 0.0])
    collection.flush()

    var reopened = PersistentCollection.open(path, 3)
    var query: List[Float32] = [1.0, 0.0, 0.0]
    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("document_type", PayloadValue.string("chunk"))
    )
    conditions.append(
        FilterCondition.greater_or_equal("source_page", PayloadValue.integer(5))
    )
    var results = reopened.search_cosine_filtered(query, 2, conditions)
    var nearest = reopened.get(results[0].id)

    print(
        "reopened sequence",
        reopened.last_sequence(),
        "nearest ID",
        results[0].id,
        "chunk",
        nearest.value().get_field("chunk_text").value().as_string(),
    )
