from akasha.api.database import DatabaseConfig
from std.testing import assert_equal, TestSuite


def test_database_config_retains_public_values() raises:
    var config = DatabaseConfig("local", 1)

    assert_equal(config.name, "local")
    assert_equal(config.format_version, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
