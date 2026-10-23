"""Python conversion callbacks must not invalidate a native search handle."""

import hashlib
from pathlib import Path
import subprocess
import sys

import pytest

from akashadb import _kernel


@pytest.mark.parametrize("route", ["approx", "where_approx", "where_exact"])
@pytest.mark.parametrize("columns", [False, True])
@pytest.mark.parametrize("trigger", ["len", "iter", "integer"])
@pytest.mark.parametrize("metric", ["dot", "l2", "cosine", "unknown"])
def test_search_conversion_can_close_collection(
    tmp_path, route, columns, trigger, metric
):
    # The old binding aborts the process at Optional.value(); isolate each call
    # so a regression is an ordinary pytest failure with the original stderr.
    binary = Path(_kernel.__file__).resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    script = """
from pathlib import Path
import hashlib
import sys
from akashadb import Collection, CollectionConfig, _kernel

assert Path(_kernel.__file__).resolve() == Path(sys.argv[1])
assert hashlib.sha256(Path(_kernel.__file__).read_bytes()).hexdigest() == sys.argv[2]
route, columns, trigger, metric = sys.argv[4], bool(int(sys.argv[5])), sys.argv[6], sys.argv[7]
config = CollectionConfig.defaults(2, ann_metric=metric if metric != 'unknown' else 'dot')
collection = Collection(Path(sys.argv[3]) / 'database', 2, config=config)
collection.upsert(1, [1., 2.])
closed = False

def close():
    global closed
    closed = True
    collection.close()

class ClosingVector:
    def __len__(self):
        if trigger == 'len':
            close()
        return 2

    def __iter__(self):
        if trigger == 'iter':
            close()
        return iter([1., 2.])

class ClosingInt:
    def __index__(self):
        close()
        return 1

    def __int__(self):
        close()
        return 1

count = ClosingInt() if trigger == 'integer' else 1
try:
    suffix = '_columns' if columns else ''
    if route == 'approx':
        getattr(collection._kernel, 'search_approx' + suffix)(metric, ClosingVector(), count, 16)
    else:
        options = dict(k=count, ef_search=16, approximate=route == 'where_approx',
            filter=dict(kind='condition', name='x', operator='eq', type='int', value=1))
        getattr(collection._kernel, 'search_dense_where' + suffix)(metric, ClosingVector(), options)
except Exception as error:
    expected = 'unknown dense metric' if metric == 'unknown' else 'collection is closed'
    assert expected in str(error), str(error)
else:
    raise AssertionError('closed search unexpectedly succeeded')
finally:
    collection.close()
assert closed, 'conversion callback did not run'
reopened = Collection(Path(sys.argv[3]) / 'database', 2, config=config)
assert reopened._kernel.search_dot([1., 2.], 1)[0]['id'] == 1
reopened.close()
print('closed conversion rejected without abort')
"""
    result = subprocess.run(
        [
            "rtk", "proxy", sys.executable, "-c", script,
            str(binary), digest, str(tmp_path), route, str(int(columns)),
            trigger, metric,
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "closed conversion rejected without abort" in result.stdout
