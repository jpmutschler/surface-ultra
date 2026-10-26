#!/usr/bin/env python3
"""
nda_guard - keep NDA terms out of anything that reaches a cloud model.

Standing rule (all NDA projects): make a best effort to obfuscate NDA data before it is
used with Claude cloud models. This tool is the mechanical half of that rule.

Term lists live in the NDA workspace (plain text, one per vendor), which Claude Code is denied:
    D:\\nda\\terms\\<vendor>.txt        lines:  REAL TERM => ALIAS     (alias optional)
                                                # comments allowed
Commands
    build                  term lists -> keyed-hash index (~/.surface-ultra/nda-index.json); no plaintext copy
    scan PATH... | --staged | -   exit 1 if any protected term is found
    redact  [IN [OUT]]     replace real terms with aliases; stdin/stdout if no files
    restore [IN [OUT]]     replace aliases with real terms - for local-only data maps, never for repo source
    hook                   Claude Code hook: reads the hook JSON on stdin, exits 2 to block
    hook-install REPO      install a git pre-commit hook that runs 'scan --staged'
    status                 show index and term-list state

Messages never print a matched term - only its vendor and an opaque id - so a block
message fed back to a model can't leak the thing it blocked.
Stdlib only; runs on any Python 3.9+.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys

HOME = pathlib.Path(os.environ.get("SURFACE_ULTRA_HOME", pathlib.Path.home() / ".surface-ultra"))
INDEX = HOME / "nda-index.json"
KEYFILE = HOME / "nda-index.key"
TERMS_DIR = pathlib.Path(os.environ.get("NDA_TERMS_DIR", r"D:\nda\terms"))
MAX_NGRAM = 8
MAX_FILE_BYTES = 8 * 1024 * 1024
TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


# ----------------------------------------------------------------------------- core
def tokens(text: str) -> list[str]:
    return [t.lower() for t in TOKEN_RE.findall(text)]


def key() -> bytes:
    HOME.mkdir(parents=True, exist_ok=True)
    if not KEYFILE.exists():
        KEYFILE.write_bytes(secrets.token_bytes(32))
    return KEYFILE.read_bytes()


def digest(k: bytes, toks: list[str]) -> str:
    return hmac.new(k, " ".join(toks).encode(), hashlib.sha256).hexdigest()[:32]


def read_terms() -> list[dict]:
    if not TERMS_DIR.is_dir():
        raise SystemExit(f"nda_guard: term folder {TERMS_DIR} not found - run tools\\NdaSession.ps1 -Init")
    out = []
    for f in sorted(TERMS_DIR.glob("*.txt")):
        vendor = f.stem
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            line = re.sub(r"\s+#.*$", "", line).strip()   # full-line and trailing "  # note" comments
            if not line or line.startswith("#"):
                continue
            real, _, alias = (p.strip() for p in line.partition("=>"))
            if not tokens(real):
                continue
            alias = alias or f"{vendor.upper()}_T{n:03d}"
            out.append({"vendor": vendor, "real": real, "alias": alias, "id": f"{vendor}:{n}"})
    return out


def load_index() -> tuple[bytes, dict, int]:
    if not INDEX.exists():
        return b"", {}, 0
    data = json.loads(INDEX.read_text(encoding="utf-8"))
    return key(), data["hashes"], data.get("max_ngram", MAX_NGRAM)


def find_hits(text: str, k: bytes, hashes: dict, max_n: int) -> list[str]:
    toks = tokens(text)
    hits = set()
    for i in range(len(toks)):
        for n in range(1, max_n + 1):
            if i + n > len(toks):
                break
            h = digest(k, toks[i:i + n])
            if h in hashes:
                hits.add(hashes[h])
    return sorted(hits)


def describe(hits: list[str]) -> str:
    vendors = sorted({h.split(":")[0] for h in hits})
    return f"{len(hits)} protected term(s) from {', '.join(vendors)} [ids: {', '.join(hits[:8])}{' ...' if len(hits) > 8 else ''}]"


# ----------------------------------------------------------------------------- commands
def cmd_build(_args):
    terms = read_terms()
    k = key()
    hashes, short = {}, []
    max_n = 1
    for t in terms:
        toks = tokens(t["real"])
        max_n = max(max_n, min(len(toks), MAX_NGRAM))
        hashes[digest(k, toks)] = t["id"]
        if len(toks) == 1 and len(toks[0]) < 4:
            short.append(t["id"])
    INDEX.write_text(json.dumps({"hashes": hashes, "max_ngram": max_n, "count": len(hashes)}, indent=1), encoding="utf-8")
    print(f"nda_guard: indexed {len(hashes)} terms from {TERMS_DIR} -> {INDEX}")
    if short:
        print(f"nda_guard: WARNING short single-token terms will false-positive often: {', '.join(short)}")


def scan_paths(paths: list[str]) -> list[tuple[str, list[str]]]:
    k, hashes, max_n = load_index()
    if not hashes:
        raise SystemExit("nda_guard: no index - run 'nda_guard.py build' (or NdaSession.ps1 -Start)")
    results = []
    for p in paths:
        path = pathlib.Path(p)
        files = [f for f in path.rglob("*") if f.is_file()] if path.is_dir() else [path]
        for f in files:
            if ".git" in f.parts or not f.exists() or f.stat().st_size > MAX_FILE_BYTES:
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            hits = find_hits(text, k, hashes, max_n)
            if hits:
                results.append((str(f), hits))
    return results


def cmd_scan(args):
    if args == ["-"]:
        k, hashes, max_n = load_index()
        hits = find_hits(sys.stdin.read(), k, hashes, max_n)
        if hits:
            print(f"stdin: {describe(hits)}", file=sys.stderr)
            return 1
        return 0
    if args == ["--staged"]:
        k, hashes, max_n = load_index()
        if not hashes:
            print("nda_guard: no index yet - commit allowed (run 'build' to enable)", file=sys.stderr)
            return 0
        names = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                               capture_output=True, text=True, check=True).stdout.split()
        bad = []
        for name in names:
            blob = subprocess.run(["git", "show", f":{name}"], capture_output=True).stdout.decode("utf-8", "ignore")
            hits = find_hits(blob + "\n" + name, k, hashes, max_n)
            if hits:
                bad.append((name, hits))
        for name, hits in bad:
            print(f"BLOCKED {name}: {describe(hits)}", file=sys.stderr)
        if bad:
            print("nda_guard: obfuscate with 'nda_guard.py redact' or move values to the local-only map; "
                  "override once with git commit --no-verify only if you are sure.", file=sys.stderr)
        return 1 if bad else 0
    found = scan_paths(args or ["."])
    for f, hits in found:
        print(f"{f}: {describe(hits)}")
    return 1 if found else 0


def _sub(text: str, pairs: list[tuple[str, str]]) -> tuple[str, int]:
    """Token-aware replace: 'Fabric Link Monitor' also matches 'fabric  link-monitor', like the scanner."""
    count = 0
    for src, dst in sorted(pairs, key=lambda p: -len(p[0])):
        body = r"[^A-Za-z0-9]+".join(re.escape(t) for t in TOKEN_RE.findall(src))
        pat = re.compile(r"(?<![A-Za-z0-9])" + body + r"(?![A-Za-z0-9])", re.IGNORECASE)
        text, n = pat.subn(dst, text)
        count += n
    return text, count


def _io(args):
    src = pathlib.Path(args[0]).read_text(encoding="utf-8") if args else sys.stdin.read()

    def sink(text):
        if len(args) > 1:
            pathlib.Path(args[1]).write_text(text, encoding="utf-8")
        else:
            sys.stdout.write(text)
    return src, sink


def cmd_redact(args):
    terms = read_terms()
    src, sink = _io(args)
    out, n = _sub(src, [(t["real"], t["alias"]) for t in terms])
    sink(out)
    k, hashes, max_n = load_index()
    left = find_hits(out, k, hashes, max_n) if hashes else []
    print(f"nda_guard: {n} replacement(s)" + (f"; STILL CONTAINS {describe(left)}" if left else "; clean"), file=sys.stderr)
    return 1 if left else 0


def cmd_restore(args):
    terms = read_terms()
    src, sink = _io(args)
    out, n = _sub(src, [(t["alias"], t["real"]) for t in terms])
    sink(out)
    print(f"nda_guard: {n} alias(es) restored", file=sys.stderr)
    return 0


def cmd_hook(_args):
    """Claude Code hook (UserPromptSubmit / PreToolUse). Exit 2 blocks; stderr explains."""
    raw = sys.stdin.read()
    base = os.environ.get("ANTHROPIC_BASE_URL", "")
    if base.startswith(("http://127.0.0.1", "http://localhost")):
        return 0  # ccn / loopback gateway session: the model is on this machine or the Spark, nothing leaves the local zone
    k, hashes, max_n = load_index()  # empty index: term checks pass, endpoint checks still apply
    try:
        ev = json.loads(raw)
    except json.JSONDecodeError:
        ev = {}
    texts = []
    if ev.get("hook_event_name") == "UserPromptSubmit":
        texts.append(str(ev.get("prompt", raw)))
    else:
        tool_input = ev.get("tool_input", {}) or {}
        texts.append(json.dumps(tool_input))
        # NDA endpoints and paths (NDA Qdrant, Spark NDA MCP, the NDA workspace folder): a cloud session
        # must not touch them, even indirectly through curl/python - the hook can't see a command's
        # output, so block the call itself. Compared lower-case with '/' separators.
        def norm(t: str) -> str:
            return re.sub(r"/+", "/", t.lower().replace("\\", "/"))
        blob = norm(json.dumps(tool_input))
        endpoints = [norm(e.strip()) for e in os.environ.get("NDA_GUARD_ENDPOINTS", "").split(",") if e.strip()]
        if any(re.search(re.escape(e) + r"(?![a-z0-9_-])", blob) for e in endpoints):
            print("NDA guard blocked this call: it targets the NDA workspace or an NDA-zone endpoint. "
                  "Do NDA research in a local client instead.", file=sys.stderr)
            return 2
        fp = tool_input.get("file_path") or tool_input.get("notebook_path")
        if fp:
            p = pathlib.Path(fp)
            if p.is_file() and p.stat().st_size <= MAX_FILE_BYTES:
                try:
                    texts.append(p.read_text(encoding="utf-8", errors="ignore"))
                except OSError:
                    pass
    hits = find_hits("\n".join(texts), k, hashes, max_n)
    if hits:
        what = "prompt" if ev.get("hook_event_name") == "UserPromptSubmit" else f"{ev.get('tool_name', 'tool')} input"
        print(f"NDA guard blocked this {what}: it contains {describe(hits)}. "
              f"Obfuscate it locally (nda_guard.py redact) before sending it to a cloud model.", file=sys.stderr)
        return 2
    return 0


def cmd_hook_install(args):
    repo = pathlib.Path(args[0] if args else ".").resolve()
    hooks = repo / ".git" / "hooks"
    if not hooks.is_dir():
        raise SystemExit(f"nda_guard: {repo} is not a git repository")
    me = pathlib.Path(__file__).resolve().as_posix()
    py = pathlib.Path(sys.executable).as_posix()
    hook = hooks / "pre-commit"
    body = f'#!/bin/sh\n# installed by nda_guard.py\nexec "{py}" "{me}" scan --staged\n'
    if hook.exists() and "nda_guard" not in hook.read_text(errors="ignore"):
        raise SystemExit(f"nda_guard: {hook} exists and isn't ours - add 'scan --staged' to it by hand")
    hook.write_text(body, encoding="utf-8", newline="\n")
    hook.chmod(0o755)
    print(f"nda_guard: pre-commit hook installed in {repo}")
    return 0


def cmd_status(_args):
    _, hashes, max_n = load_index()
    print(f"index : {INDEX} ({len(hashes)} terms, max n-gram {max_n})")
    print(f"terms : {TERMS_DIR} ({'present' if TERMS_DIR.is_dir() else 'missing'})")
    return 0


COMMANDS = {"build": cmd_build, "scan": cmd_scan, "redact": cmd_redact, "restore": cmd_restore,
            "hook": cmd_hook, "hook-install": cmd_hook_install, "status": cmd_status}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        return 64
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stdin.reconfigure(encoding="utf-8")
    return COMMANDS[sys.argv[1]](sys.argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main())
