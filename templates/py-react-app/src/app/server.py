"""FastAPI app: /api/* plus the built React UI from ./static (single-page-app fallback)."""
from __future__ import annotations

import pathlib

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import __version__

STATIC = pathlib.Path(__file__).parent / "static"
app = FastAPI(title="app", version=__version__)


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "version": __version__}


# --- your API routes go here (prefix them with /api) ---


if (STATIC / "assets").is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC / "assets"), name="assets")


@app.get("/{path:path}", include_in_schema=False)
def spa(path: str) -> FileResponse:
    if path.startswith("api/"):
        raise HTTPException(status_code=404)
    target = (STATIC / path).resolve()
    if path and target.is_file() and target.is_relative_to(STATIC.resolve()):   # no ../ escapes
        return FileResponse(target)
    index = STATIC / "index.html"
    if not index.is_file():
        raise HTTPException(status_code=503, detail="UI not built - run `just build`")
    return FileResponse(index)
