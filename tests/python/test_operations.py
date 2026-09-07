import json

import pytest

import akashadb


def test_backup_restore_inspect_export_import_and_observability(tmp_path) -> None:
    source = akashadb.Collection(tmp_path / "source", 2)
    source.upsert(
        1,
        [1.0, 0.0],
        [akashadb.PayloadField("chunk", "string", "operational")],
    )
    source.upsert(2, [0.0, 1.0])
    source.upsert_sparse(1, [akashadb.SparseElement(7, 2.0)])

    backup = akashadb.backup_collection(source, tmp_path / "backup")
    assert backup.valid and backup.live_points == 2
    assert akashadb.inspect_storage(tmp_path / "backup", 2) == backup

    logical = tmp_path / "points.ndjson"
    assert akashadb.export_ndjson(source, logical) == 2
    source.close()
    restored_report = akashadb.restore_storage(
        tmp_path / "backup", tmp_path / "restored", 2
    )
    assert restored_report.last_sequence == backup.last_sequence
    restored = akashadb.Collection(tmp_path / "restored", 2)
    assert restored.get(1).fields[0].value == "operational"
    assert restored.search(
        akashadb.SearchRequest(
            "dot", 1, sparse=[akashadb.SparseElement(7, 1.0)], mode="sparse"
        )
    )[0].id == 1
    restored.close()

    imported = akashadb.Collection(tmp_path / "imported", 2)
    assert akashadb.import_ndjson(imported, logical) == 2
    assert imported.get(1).vector == [1.0, 0.0]
    metrics = imported.metrics()
    assert metrics.operations >= 3
    assert metrics.writes >= 2
    assert imported.traces()
    assert all("vector" not in trace.operation for trace in imported.traces())
    imported.close()


def test_invalid_import_limits_cancellation_and_orphan_quarantine(tmp_path) -> None:
    collection = akashadb.Collection(
        tmp_path / "bounded",
        1,
        limits=akashadb.ResourceLimits(
            max_batch_rows=2, max_query_batch=2, max_k=2, max_candidates=2
        ),
    )
    collection.upsert(1, [1.0])
    collection.upsert(2, [2.0])
    baseline = collection.last_sequence
    invalid = tmp_path / "invalid.ndjson"
    invalid.write_text(
        json.dumps(
            {
                "id": 3,
                "vector": [3.0],
                "fields": [],
                "sparse": [
                    {"term_id": 7, "weight": 1.0},
                    {"term_id": 7, "weight": 2.0},
                ],
            }
        )
        + "\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="sparse"):
        akashadb.import_ndjson(collection, invalid)
    assert collection.last_sequence == baseline
    assert collection.get(3) is None
    with pytest.raises(akashadb.ValidationError, match="resource limit"):
        collection.search(akashadb.SearchRequest("dot", 3, vector=[1.0]))

    token = akashadb.CancellationToken()
    token.cancel()
    with pytest.raises(akashadb.ValidationError, match="cancel"):
        collection.search_controlled("dot", [1.0], 1, cancellation=token)
    assert collection.metrics().cancellations == 1
    collection.flush()
    report = akashadb.inspect_storage(tmp_path / "bounded", 1)
    orphan = tmp_path / "bounded" / "segment-delta-999.bin"
    orphan.write_bytes(b"orphan")
    unrelated = tmp_path / "bounded" / "notes.txt"
    unrelated.write_text("keep", encoding="utf-8")
    collection.close()

    moved = akashadb.quarantine_orphans(
        tmp_path / "bounded", 1, tmp_path / "quarantine"
    )
    assert [path.name for path in moved] == ["segment-delta-999.bin"]
    assert unrelated.exists()
    assert all((tmp_path / "bounded" / name).exists() for name in report.segment_names)


def test_backup_and_restore_preserve_full_collection_identity(tmp_path) -> None:
    config = akashadb.CollectionConfig.defaults(
        2,
        ann_metric="cosine",
        scalar_kind="bf16",
        m=8,
        m0=16,
        ef_construction=64,
        level_seed=91,
    )
    source = akashadb.Collection(tmp_path / "configured-source", 2, config=config)
    source.upsert(1, [1.0, 0.0])
    source.flush()
    fingerprint = source.collection_config().fingerprint
    backup = akashadb.backup_collection(source, tmp_path / "configured-backup")
    source.close()
    assert backup.config_fingerprint == fingerprint

    restored = akashadb.restore_storage(
        tmp_path / "configured-backup", tmp_path / "configured-restored", 2
    )
    assert restored.config_fingerprint == fingerprint
    reopened = akashadb.Collection(
        tmp_path / "configured-restored", 2, config=config
    )
    assert reopened.collection_config() == config
    reopened.close()
