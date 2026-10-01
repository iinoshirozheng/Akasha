"""Correctness gates for the reproducible comparison, independent of Qdrant."""

import numpy as np
import pytest

from benchmarks.qdrant_workload import (
    SplitMix64, Workload, exact_ids, load_workload, save_workload,
    synthetic_workload, validate_result,
)
from benchmarks.qdrant_compare import Akasha, Qdrant, PLANNER_POLICY, execution_kind, latency_summary, matched_summary
from benchmarks.qdrant_mixed import matched_mixed_summary


def test_cost_plan_comparison_requires_explicit_policy_exact_oracle_and_storage():
    stats = {"fallback_reason": "scan_cost", "storage_name": "exact"}
    spec = {"akasha_planner_policy": PLANNER_POLICY}
    assert execution_kind("akasha", "all", stats, 1.0, spec) == "planned_exact"
    assert execution_kind("akasha", "all", stats, 1.0, {}) == "invalid_fallback"
    assert execution_kind("akasha", "all", stats, .99, spec) == "invalid_fallback"
    assert execution_kind("akasha", "all", {**stats, "storage_name": "segmented-f32"}, 1.0, spec) == "invalid_fallback"
    for reason in ("graph_unavailable", "filtered_exhausted", "unknown"):
        assert execution_kind("akasha", "selective", {**stats, "fallback_reason": reason}, 1.0, spec) == "invalid_fallback"
    assert execution_kind("akasha", "selective", {**stats, "fallback_reason": "selectivity"}, 1.0, spec) == "planned_exact"
    assert execution_kind("qdrant", "all", {}, 1.0, spec) == "unobservable"


def test_splitmix_matches_published_seed_zero_sequence_and_chunking():
    expected = [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F]
    scalar = SplitMix64(0)
    assert [scalar.next_u64() for _ in range(3)] == expected
    vector = SplitMix64(0)
    assert vector.words(2).tolist() + vector.words(1).tolist() == expected


def test_oracle_uses_replacements_deletes_filters_and_id_ties():
    workload = Workload(
        ids=np.array([5, 1, 9, 3], dtype=np.int64),
        vectors=np.array([[4, 0], [4, 0], [10, 0], [1, 0]], dtype=np.float32),
        update_ids=np.array([3], dtype=np.int64),
        updates=np.array([[8, 0]], dtype=np.float32),
        deletes=np.array([9], dtype=np.int64),
        queries=np.ones((4, 4, 2), dtype=np.float32), metadata={"seed": 0},
    )
    assert exact_ids(workload, [1, 0], "dot", 10, "all", 0) == [3, 1, 5]
    assert exact_ids(workload, [4, 0], "l2", 2, "all", 0) == [1, 5]
    assert exact_ids(workload, [1, 0], "cosine", 3, "all", 0) == [1, 3, 5]
    assert exact_ids(workload, [1, 0], "dot", 10, "correlated", 0) == [1]
    assert exact_ids(workload, [1, 0], "dot", 10, "selective", 0) == []


def test_result_validation_rejects_duplicates_deleted_and_wrong_filter():
    workload = synthetic_workload(128, 8, 4, seed=12345)
    valid = exact_ids(workload, [1] * 8, "dot", 10, "all", 0)
    assert validate_result(workload, valid, valid, "all", 0) == 1.0
    with pytest.raises(ValueError, match="duplicate"):
        validate_result(workload, [valid[0]] * 10, valid, "all", 0)
    with pytest.raises(ValueError, match="live"):
        validate_result(workload, [int(workload.deletes[0])], valid, "all", 0)
    with pytest.raises(ValueError, match="filter"):
        validate_result(workload, [valid[0]], valid, "selective", (valid[0] + 1) % 32)
    assert validate_result(workload, [], valid, "all", 0) == 0.0


def test_workload_roundtrip_checksums_and_corruption(tmp_path):
    original = synthetic_workload(128, 8, 4, seed=12345)
    second = synthetic_workload(128, 8, 4, seed=12345)
    assert original.checksum() == second.checksum()
    path = tmp_path / "data.npz"
    save_workload(path, original)
    loaded = load_workload(path)
    assert loaded.checksum() == original.checksum()
    loaded.vectors[0, 0] += 1
    assert loaded.checksum() != original.checksum()
    with np.load(path, allow_pickle=False) as data:
        arrays = dict(data)
    arrays["vectors"][0, 0] += 1
    np.savez(path, **arrays)
    with pytest.raises(ValueError, match="checksum"):
        load_workload(path)


def test_failed_recall_cannot_produce_speed_ratio_or_skip_missing_cells():
    def result(engine, recalls):
        return {"engine": engine, "status": "ok", "measurements": [
            {"mode": "all", "ef": ef, "recall": recall,
             "latency_ns": [100, 200], "execution_valid": True}
            for ef, recall in recalls
        ]}
    left = result("akasha", [(32, .8), (64, .95), (128, .99)])
    right = result("qdrant", [(32, .7), (64, .94)])
    report = matched_summary(left, right, .95, modes=("all", "correlated"))
    assert all(row["status"] == "FAILED" for row in report)
    assert all("qps_ratio_akasha_over_qdrant" not in row for row in report)
    right["measurements"].append({"mode": "all", "ef": 128, "recall": .96,
                                  "latency_ns": [200, 400], "execution_valid": True})
    row = matched_summary(left, right, .95, modes=("all",))[0]
    assert row["status"] == "PASSED"
    assert row["akasha"]["ef"] == 64
    assert row["qdrant"]["ef"] == 128
    assert row["qps_ratio_akasha_over_qdrant"] == 2.0
    right["measurements"][-1]["execution_valid"] = False
    assert matched_summary(left, right, .95, modes=("all",))[0]["status"] == "FAILED"
    right["measurements"][-1]["execution_valid"] = True
    right["reopen"] = {"status": "FAILED"}
    assert matched_summary(left, right, .95, modes=("all",))[0]["status"] == "FAILED"


@pytest.mark.parametrize(
    "akasha_samples,qdrant_samples,qps_passed,p95_passed",
    [
        ([100] * 20, [100] * 20, True, True),
        ([90] * 20, [100] * 20, True, True),
        ([90] * 20, [50] * 18 + [100] * 2, False, True),
        ([40] * 18 + [150] * 2, [60] * 20, True, False),
        ([101] * 20, [100] * 20, False, False),
    ],
)
def test_matched_cell_requires_both_qps_and_p95_without_tolerance(
    akasha_samples, qdrant_samples, qps_passed, p95_passed,
):
    def report(samples):
        return {"status": "ok", "measurements": [
            {"mode": "all", "ef": 32, "recall": .95,
             "latency_ns": samples, "execution_valid": True},
            {"mode": "selective", "ef": 10, "recall": 1.0,
             "latency_ns": [1] * 20, "execution_valid": True},
        ]}

    rows = matched_summary(report(akasha_samples), report(qdrant_samples), .95,
                           modes=("all", "selective"))
    row = rows[0]
    assert row["quality_status"] == "PASSED"
    assert row["qps_passed"] is qps_passed
    assert row["p95_passed"] is p95_passed
    assert row["status"] == ("PASSED" if qps_passed and p95_passed else "FAILED")
    assert row["p95_ratio_akasha_over_qdrant"] > 0
    assert rows[1]["status"] == "PASSED"
    mixed = matched_mixed_summary(
        {"modes": [{"mode": "all", "recall": .95, "execution_valid": True,
                    **latency_summary(akasha_samples)}]},
        {"modes": [{"mode": "all", "recall": .95, "execution_valid": True,
                    **latency_summary(qdrant_samples)}]},
    )
    assert mixed[0]["quality_status"] == "PASSED"
    assert mixed[0]["status"] == row["status"]
    assert mixed[0]["qps_passed"] is qps_passed
    assert mixed[0]["p95_passed"] is p95_passed
    assert all(cell["status"] == "FAILED" for cell in mixed[1:])


@pytest.mark.parametrize("failure", ["recall", "execution", "missing"])
def test_mixed_quality_failure_cannot_be_offset_by_other_modes(failure):
    def report():
        return {"modes": [
            {"mode": mode, "recall": 1.0, "execution_valid": True,
             **latency_summary([100] * 20)}
            for mode in ("selective", "independent", "correlated", "all")
        ]}

    left, right = report(), report()
    if failure == "recall":
        left["modes"][-1]["recall"] = .94
    elif failure == "execution":
        left["modes"][-1]["execution_valid"] = False
    else:
        left["modes"].pop()
    cells = matched_mixed_summary(left, right)
    assert [cell["mode"] for cell in cells] == ["all", "correlated", "independent", "selective"]
    assert cells[0]["quality_status"] == cells[0]["status"] == "FAILED"
    assert "qps_ratio_akasha_over_qdrant" not in cells[0]
    assert "p95_ratio_akasha_over_qdrant" not in cells[0]
    assert all(cell["status"] == "PASSED" for cell in cells[1:])


@pytest.mark.parametrize("factory", [Akasha, Qdrant])
def test_public_adapter_exact_filters_mutations_and_reopen(tmp_path, factory):
    if factory is Qdrant:
        pytest.importorskip("qdrant_edge", reason="optional pinned benchmark dependency")
    workload = synthetic_workload(128, 8, 2)
    spec = {"dimension": 8, "metric": "dot", "scalar": "f32", "efs": [128],
            "points": 128, "seed": 12345, "k": 10}
    database = factory(tmp_path / "database", spec)
    try:
        database.upsert(workload.ids, workload.vectors)
        database.optimize()
        info = database.info()
        if factory is Akasha:
            assert info["config"]["dimension"] == 8
        else:
            assert info["indexed_vectors_count"] == 128
            assert info["config"]["max_search_threads"] == 1
        database.upsert(workload.update_ids, workload.updates)
        database.delete(workload.deletes)
        database.flush()
    finally:
        database.close()
    database = factory(tmp_path / "database", spec, reopen=True)
    try:
        for index, mode in enumerate(("all", "correlated", "independent", "selective")):
            query = workload.queries[index, 0].tolist()
            result = database.search(database.request(query, mode, 0, 128, exact=True))
            assert [row.id for row in result] == exact_ids(workload, query, "dot", 10, mode, 0)
    finally:
        database.close()
