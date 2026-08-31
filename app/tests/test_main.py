import importlib

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v9.9.9-test")
    monkeypatch.setenv("GIT_SHA", "abc1234def")
    monkeypatch.setenv("APP_API_KEY", "test-secret")
    # Pin everything the app reads so CI env vars (CodeBuild sets ENVIRONMENT=prod) cannot leak in.
    monkeypatch.setenv("ENVIRONMENT", "test")
    monkeypatch.delenv("SIMULATE_FAILURE", raising=False)
    import main

    importlib.reload(main)
    return TestClient(main.app)


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_ready_ok_when_secret_present(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["checks"]["secret_present"] is True


def test_ready_fails_without_secret(monkeypatch):
    monkeypatch.delenv("APP_API_KEY", raising=False)
    import main

    importlib.reload(main)
    r = TestClient(main.app).get("/ready")
    assert r.status_code == 503
    assert r.json()["checks"]["secret_present"] is False


def test_version_reports_build_metadata(client):
    body = client.get("/version").json()
    assert body["version"] == "v9.9.9-test"
    assert body["commit"] == "abc1234def"
    assert body["environment"] == "test"


def test_request_id_and_release_headers(client):
    r = client.get("/version", headers={"x-request-id": "req-123"})
    assert r.headers["x-request-id"] == "req-123"
    assert r.headers["x-release"] == "v9.9.9-test+abc1234"


def test_simulated_failure_is_alive_but_not_ready(monkeypatch):
    """The failure mode the ALB can't see: process up, dependencies down."""
    monkeypatch.setenv("SIMULATE_FAILURE", "true")
    monkeypatch.setenv("APP_API_KEY", "x")
    import main

    importlib.reload(main)
    c = TestClient(main.app)
    assert c.get("/health").status_code == 200
    r = c.get("/ready")
    assert r.status_code == 503
    assert r.json()["checks"]["dependencies"] is False


def test_index_shows_release(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "v9.9.9-test" in r.text and "abc1234" in r.text


def test_secret_never_leaks(client):
    for path in ("/", "/health", "/ready", "/version"):
        assert "test-secret" not in client.get(path).text


def test_no_docs_exposed(client):
    assert client.get("/docs").status_code == 404
