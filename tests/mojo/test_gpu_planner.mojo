from akasha.compute.gpu.planner import GpuExecutionOptions, plan_gpu_execution
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_gpu_planner_rejects_disabled_unavailable_and_small_workloads() raises:
    var options = GpuExecutionOptions(enabled=False)
    var disabled = plan_gpu_execution(True, 8, 1_000, 128, 10, options)
    assert_false(disabled.use_gpu)
    assert_equal(disabled.reason, "disabled")

    options = GpuExecutionOptions()
    var unavailable = plan_gpu_execution(False, 8, 1_000, 128, 10, options)
    assert_equal(unavailable.reason, "no accelerator")
    var small = plan_gpu_execution(True, 1, 32, 4, 10, options)
    assert_equal(small.reason, "below work threshold")


def test_gpu_planner_accounts_for_memory_and_accepts_large_work() raises:
    var constrained = GpuExecutionOptions(
        memory_budget_bytes=1_024, min_work_items=1
    )
    var rejected = plan_gpu_execution(True, 8, 1_000, 128, 10, constrained)
    assert_false(rejected.use_gpu)
    assert_equal(rejected.reason, "memory budget exceeded")
    assert_true(rejected.required_bytes > UInt64(1_024))

    var eligible = plan_gpu_execution(
        True,
        8,
        1_000,
        128,
        10,
        GpuExecutionOptions(memory_budget_bytes=32_000_000),
    )
    assert_true(eligible.use_gpu)
    assert_equal(eligible.reason, "gpu eligible")
    assert_true(eligible.transfer_bytes < eligible.required_bytes)


def test_gpu_planner_validates_configuration_and_overflow() raises:
    with assert_raises():
        _ = GpuExecutionOptions(memory_budget_bytes=0)
    with assert_raises():
        _ = plan_gpu_execution(True, -1, 10, 4, 1, GpuExecutionOptions())
    with assert_raises():
        _ = plan_gpu_execution(
            True, Int.MAX, Int.MAX, Int.MAX, 1, GpuExecutionOptions()
        )


def test_tiled_topk_fits_without_a_dense_score_matrix() raises:
    var plan = plan_gpu_execution(
        True,
        128,
        100_000,
        32,
        10,
        GpuExecutionOptions(
            min_work_items=1, memory_budget_bytes=32 * 1024 * 1024
        ),
    )
    assert_true(plan.use_gpu)
    assert_true(plan.required_bytes < UInt64(32 * 1024 * 1024))
    # Dense scores alone would require 51.2 MB, before vectors or outputs.
    var ragged = plan_gpu_execution(
        True,
        4,
        769,
        33,
        800,
        GpuExecutionOptions(min_work_items=1),
        candidate_count=1155,
        candidate_tiles=7,
    )
    assert_true(ragged.use_gpu)
    with assert_raises():
        _ = plan_gpu_execution(
            True, 1, 10, 4, 1, GpuExecutionOptions(), candidate_tiles=-2
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
