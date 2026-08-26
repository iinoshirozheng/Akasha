import os
from contextlib import asynccontextmanager
from pathlib import Path
from tempfile import gettempdir

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from akashadb import AkashaError, CollectionNotFoundError, LocalDatabase
from apps.server.routes.collections import router as collections_router
from apps.server.routes.points import router as points_router


def create_app(database: LocalDatabase | None = None) -> FastAPI:
    owned_database = database

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        yield
        application.state.database.close_all()

    app = FastAPI(
        title="AkashaDB",
        version="0.1.0",
        description="Local HTTP adapter for the AkashaDB Mojo kernel.",
        lifespan=lifespan,
    )
    root = Path(
        os.environ.get("AKASHA_DATA_DIR", str(Path(gettempdir()) / "akashadb"))
    )
    app.state.database = owned_database or LocalDatabase(root)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "kernel": "mojo"}

    @app.get("/metrics")
    def metrics() -> dict[str, object]:
        return app.state.database.metrics()

    @app.exception_handler(CollectionNotFoundError)
    async def not_found_handler(
        request: Request, error: CollectionNotFoundError
    ) -> JSONResponse:
        return JSONResponse(status_code=404, content={"detail": str(error)})

    @app.exception_handler(AkashaError)
    async def akasha_error_handler(
        request: Request, error: AkashaError
    ) -> JSONResponse:
        return JSONResponse(status_code=400, content={"detail": str(error)})

    app.include_router(collections_router)
    app.include_router(points_router)
    return app


app = create_app()
