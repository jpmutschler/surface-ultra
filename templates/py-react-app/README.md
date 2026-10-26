# py-react-app template

A Python API with a React UI that ships as **one wheel**. Target machines need Python only, not Node.

```
src/app/server.py      FastAPI: /api/* routes + serves the built UI from src/app/static
frontend/              React + TypeScript (Vite). `npm run build` writes into src/app/static
pyproject.toml         hatchling; the built UI is package data, so `pip install` brings it along
justfile               dev / build / wheel / run
```

## Use it

```powershell
Copy-Item -Recurse D:\dev\src\surface-ultra\templates\py-react-app D:\dev\src\my-tool
cd D:\dev\src\my-tool
just setup        # uv sync + npm install (once)
just dev          # API on :8000 with reload + Vite on :5173 proxying /api to it
just wheel        # builds the UI, then dist\my_tool-*.whl with the UI inside
```

Rename the package (`app` and `name` in pyproject.toml) before the first commit. The built UI is
git-ignored; `just wheel` rebuilds it, and hatchling ships it as an artifact.

## Why it stays portable

- The browser runs React; the built UI is a few hundred KB of static files.
- FastAPI serves them next to the API, so one `pip install` and one process run on the lab PC, a
  customer's box, or the Spark.
- Node is only needed where you build the UI: here, or in CI.
- No server-side rendering (that's what would need a Node server, e.g. Next.js).

NiceGUI stays the quicker choice for an operator panel. This template is for the API products where
the UI deserves real components.
