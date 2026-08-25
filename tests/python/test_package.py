import akashadb


def test_package_exposes_project_version() -> None:
    assert akashadb.__version__ == "0.1.0"
