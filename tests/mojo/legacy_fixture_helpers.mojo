from std.python import Python


def copy_legacy_fixture(name: String, path: String) raises:
    """Copy frozen pre-point-authority bytes; never use the current writer."""
    _ = Python.import_module("shutil").copytree(
        "tests/fixtures/default-legacy/" + name, path, dirs_exist_ok=True
    )
