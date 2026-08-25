from apps.server.main import app


def test_server_exposes_project_metadata() -> None:
    assert app.title == "AkashaDB"
    assert app.version == "0.1.0"
