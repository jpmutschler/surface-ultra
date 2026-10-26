"""`app` / `python -m app`: serve the API and UI."""
import argparse

import uvicorn


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    a = ap.parse_args()
    uvicorn.run("app.server:app", host=a.host, port=a.port)


if __name__ == "__main__":
    main()
