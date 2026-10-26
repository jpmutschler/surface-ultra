#!/usr/bin/env python3
"""
plan_agent - local, step-by-step research -> plan -> handoff pipeline for new API/UI projects.

Everything runs against LOCAL models (llama-swap / LiteLLM on this laptop, or the Spark) and keeps
NDA material in the NDA workspace. The output is OUR OWN API plan; vendor specifics are isolated in
a binding-layer section, and only an obfuscated, scanned pack ever leaves for Claude.

Project layout (created by New-ResearchProject.ps1):
    <NDA root>/projects/<name>/
        project.json                 settings (models, base URL, vendor)
        sources/public/...           public specs, datasheets, app notes   -> class "public"
        sources/vendor/...           NDA SDKs, headers, vendor docs        -> class "nda"
        index/                       chunks.jsonl + vectors.f32 (local vector index)
        plan/00-brief.md             YOUR goals, users, constraints (you write this)
        plan/01-scope-questions.md   generated questions; write answers under each "Answer:"
        plan/outline.json            section list (edit freely)
        plan/sections/NN-*.md        drafts; add review comments as lines starting with ">>"
        plan/review.md               critic findings
        handoff/local/               full plan + binding-layer spec (never leaves the zone)
        handoff/cloud/               obfuscated, scanned pack for Claude Code

Steps (run in order, re-run any time):
    ingest    parse + chunk + embed sources (records each chunk's source class)
    terms     suggest protected terms from vendor sources -> <terms>/candidates/<vendor>.txt
    scope     generate scoping questions from the brief and the sources
    draft     write sections with [S#] citations and provenance badges   (--section N to redo one)
    critique  second model checks every section against its cited sources
    revise    apply your ">>" comments + critic findings                  (--section N)
    handoff   assemble local + cloud packs; redact, scan, refuse if anything leaks
    status    show what exists

Usage:  python plan_agent.py <step> --project D:/nda/projects/acme-api [--section 4]
Requires: Python 3.10+. Optional: pypdf (PDFs), numpy (fast search) - plan.ps1 runs it via
`uv run --with pypdf --with numpy`. Everything else is stdlib.
"""
from __future__ import annotations

import argparse
import array
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import shutil
import sys
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
TEXT_EXT = {".md", ".txt", ".rst", ".h", ".hpp", ".c", ".cpp", ".cc", ".py", ".json", ".yaml", ".yml",
            ".csv", ".ini", ".cfg", ".xml", ".html", ".htm", ".ps1", ".sh", ".toml"}
CODE_EXT = {".h", ".hpp", ".c", ".cpp", ".cc", ".py", ".ps1", ".sh"}
CHUNK_CHARS, CHUNK_OVERLAP = 1400, 200
QUERY_INSTRUCT = "Instruct: Given a question about a hardware SDK or specification, retrieve passages that answer it\nQuery: "

DEFAULT_OUTLINE = [
    {"n": 1, "slug": "purpose-scope", "title": "Purpose and scope",
     "ask": "What the project is for, what is in and out of scope, success criteria."},
    {"n": 2, "slug": "users-use-cases", "title": "Users and use cases",
     "ask": "Who uses it and the concrete workflows it must support."},
    {"n": 3, "slug": "architecture", "title": "System architecture",
     "ask": "Components, process boundaries, data flow, deployment. Keep the vendor binding layer as one isolated component."},
    {"n": 4, "slug": "public-api", "title": "Public API (our own)",
     "ask": "Endpoints/functions/CLI in OUR vocabulary, built on public-spec concepts. No vendor names, registers or SDK calls here."},
    {"n": 5, "slug": "data-model", "title": "Data model",
     "ask": "Entities, fields, units, persistence, versioning."},
    {"n": 6, "slug": "ui-flows", "title": "UI flows",
     "ask": "Screens and interactions, states, errors shown to users."},
    {"n": 7, "slug": "binding-layer", "title": "Device binding layer (vendor-specific, isolated)",
     "ask": "Exactly what the binding layer must do for each public API operation: vendor calls, register access, sequences, timing. This section is the ONLY place vendor specifics live."},
    {"n": 8, "slug": "errors-diagnostics", "title": "Errors and diagnostics",
     "ask": "Error taxonomy, recovery, logging, telemetry, health checks."},
    {"n": 9, "slug": "security-licensing", "title": "Security and licensing",
     "ask": "AuthN/Z, secrets, licensing model, what may be distributed, NDA exposure of each component."},
    {"n": 10, "slug": "testing", "title": "Test strategy and acceptance tests",
     "ask": "Unit/integration/HIL tests, mocks for the binding layer, acceptance criteria per use case."},
    {"n": 11, "slug": "milestones", "title": "Milestones",
     "ask": "Ordered deliverables, dependencies, what Claude builds vs what is done locally."},
    {"n": 12, "slug": "open-questions", "title": "Open questions and assumptions",
     "ask": "Everything unresolved, every assumption made, and what would settle it."},
]


# ----------------------------------------------------------------------------- llm client
class LLM:
    def __init__(self, cfg: dict):
        self.base = cfg.get("base_url", "http://127.0.0.1:8080/v1").rstrip("/")
        self.key = os.environ.get(cfg.get("api_key_env", ""), "") if cfg.get("api_key_env") else ""
        self.m = cfg["models"]

    def _post(self, path: str, body: dict, timeout: int = 3600) -> dict:
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json",
                                              **({"Authorization": f"Bearer {self.key}"} if self.key else {})})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())

    def chat(self, role: str, system: str, user: str, max_tokens: int = 4096, temperature: float = 0.3) -> str:
        r = self._post("/chat/completions", {"model": self.m[role], "max_tokens": max_tokens, "temperature": temperature,
                                             "messages": [{"role": "system", "content": system},
                                                          {"role": "user", "content": user}]})
        text = r["choices"][0]["message"].get("content") or ""
        return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()

    def embed(self, texts: list[str]) -> list[list[float]]:
        out = []
        for i in range(0, len(texts), 32):
            r = self._post("/embeddings", {"model": self.m["embed"], "input": texts[i:i + 32]})
            out += [d["embedding"] for d in sorted(r["data"], key=lambda d: d["index"])]
        return out

    def rerank(self, query: str, docs: list[str]) -> list[int] | None:
        if not self.m.get("rerank"):
            return None
        try:
            r = self._post("/rerank", {"model": self.m["rerank"], "query": query, "documents": docs}, timeout=600)
        except (urllib.error.URLError, KeyError, ValueError):
            return None
        res = r.get("results", r.get("data", []))
        return [x["index"] for x in sorted(res, key=lambda x: -x.get("relevance_score", x.get("score", 0)))]


# ----------------------------------------------------------------------------- project
class Project:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.cfg = json.loads((root / "project.json").read_text(encoding="utf-8"))
        self.llm = LLM(self.cfg)
        self.plan = root / "plan"
        self.sections = self.plan / "sections"
        self.index = root / "index"

    def outline(self) -> list[dict]:
        p = self.plan / "outline.json"
        if not p.exists():
            p.write_text(json.dumps(DEFAULT_OUTLINE, indent=2), encoding="utf-8")
        return json.loads(p.read_text(encoding="utf-8"))

    def brief(self) -> str:
        p = self.plan / "00-brief.md"
        return p.read_text(encoding="utf-8") if p.exists() else ""

    def scope_answers(self) -> str:
        p = self.plan / "01-scope-questions.md"
        return p.read_text(encoding="utf-8") if p.exists() else ""

    def section_path(self, s: dict) -> pathlib.Path:
        return self.sections / f"{s['n']:02d}-{s['slug']}.md"


# ----------------------------------------------------------------------------- ingest
def extract(path: pathlib.Path) -> list[tuple[str, str]]:
    """Returns [(locator, text)] - locator is 'p.N' for PDFs, 'L<a>-<b>' for text/code."""
    ext = path.suffix.lower()
    if ext == ".pdf":
        try:
            from pypdf import PdfReader  # type: ignore
        except ImportError:
            print(f"  skip {path.name}: pypdf not installed (run via plan.ps1, which adds it)")
            return []
        out = []
        for i, page in enumerate(PdfReader(str(path)).pages, 1):
            t = (page.extract_text() or "").strip()
            if t:
                out.append((f"p.{i}", t))
        return out
    if ext in TEXT_EXT:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        step = 60 if ext in CODE_EXT else 80
        return [(f"L{i + 1}-{min(i + step, len(lines))}", "\n".join(lines[i:i + step]))
                for i in range(0, len(lines), step) if "\n".join(lines[i:i + step]).strip()]
    return []


def chunk(text: str) -> list[str]:
    text = re.sub(r"[ \t]+", " ", text)
    if len(text) <= CHUNK_CHARS:
        return [text]
    out, i = [], 0
    while i < len(text):
        out.append(text[i:i + CHUNK_CHARS])
        i += CHUNK_CHARS - CHUNK_OVERLAP
    return out


def cmd_ingest(p: Project, a):
    p.index.mkdir(exist_ok=True)
    chunks = []
    for cls, sub in (("public", "public"), ("nda", "vendor")):
        base = p.root / "sources" / sub
        for f in sorted(base.rglob("*")) if base.exists() else []:
            if not f.is_file():
                continue
            rel = f.relative_to(p.root / "sources").as_posix()
            parts = extract(f)
            for loc, text in parts:
                for j, c in enumerate(chunk(text)):
                    chunks.append({"id": len(chunks), "doc": rel, "loc": loc, "cls": cls, "text": c})
            print(f"  {cls:6} {rel}: {len(parts)} parts")
    if not chunks:
        raise SystemExit("ingest: no sources found under sources/public or sources/vendor")
    print(f"ingest: embedding {len(chunks)} chunks with {p.llm.m['embed']} ...")
    vecs = p.llm.embed([c["text"] for c in chunks])
    dim = len(vecs[0])
    buf = array.array("f")
    for v in vecs:
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        buf.extend(x / n for x in v)
    with open(p.index / "vectors.f32", "wb") as fh:
        buf.tofile(fh)
    with open(p.index / "chunks.jsonl", "w", encoding="utf-8") as fh:
        for c in chunks:
            fh.write(json.dumps(c) + "\n")
    (p.index / "meta.json").write_text(json.dumps({"dim": dim, "count": len(chunks), "embed": p.llm.m["embed"],
                                                   "built": dt.datetime.now().isoformat(timespec="seconds")}), encoding="utf-8")
    nda = sum(c["cls"] == "nda" for c in chunks)
    print(f"ingest: {len(chunks)} chunks ({nda} nda, {len(chunks) - nda} public), dim {dim}")


class Index:
    def __init__(self, p: Project):
        meta = json.loads((p.index / "meta.json").read_text(encoding="utf-8"))
        self.dim = meta["dim"]
        self.chunks = [json.loads(line) for line in open(p.index / "chunks.jsonl", encoding="utf-8")]
        self.p = p
        try:                       # numpy if present (plan.ps1 adds it): ~1000x faster on big indexes
            import numpy as np  # type: ignore
            self.np = np
            self.mat = np.fromfile(p.index / "vectors.f32", dtype=np.float32).reshape(meta["count"], self.dim)
        except ImportError:
            self.np = None
            self.vecs = array.array("f")
            with open(p.index / "vectors.f32", "rb") as fh:
                self.vecs.fromfile(fh, meta["count"] * self.dim)

    def search(self, query: str, k: int = 8, pool: int = 40) -> list[dict]:
        q = self.p.llm.embed([QUERY_INSTRUCT + query])[0]
        n = math.sqrt(sum(x * x for x in q)) or 1.0
        q = [x / n for x in q]
        d = self.dim
        if self.np is not None:
            s = self.mat @ self.np.asarray(q, dtype=self.np.float32)
            top = [int(i) for i in self.np.argsort(-s)[:pool]]
        else:
            scores = [(sum(q[j] * self.vecs[i * d + j] for j in range(d)), i) for i in range(len(self.chunks))]
            top = [i for _, i in sorted(scores, reverse=True)[:pool]]
        order = self.p.llm.rerank(query, [self.chunks[i]["text"] for i in top])
        if order:
            top = [top[i] for i in order]
        return [self.chunks[i] for i in top[:k]]


# ----------------------------------------------------------------------------- terms
GENERIC = set("""PCIE NVME CXL MCTP SMBUS I2C I3C PCI SIG LTSSM FLIT FEC TLP DLLP AER ACS ARI ATS PRI PASID BAR MSI MSIX
LINK LANE PORT GEN RX TX EQ CRC ECRC DMA IRQ GPIO UART SPI JTAG USB SATA SAS NVM API SDK CPU GPU RAM ROM EEPROM
TRUE FALSE NULL VOID INT UINT8 UINT16 UINT32 UINT64 INT8 INT16 INT32 INT64 BOOL CHAR STATUS ERROR SUCCESS OK
DEFINE IFDEF ENDIF INCLUDE STRUCT ENUM TYPEDEF STATIC CONST EXTERN RETURN MAX MIN SIZE COUNT INDEX ID""".split())
IDENT_RE = re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+){1,}\b")      # REG_NAME_FIELD
PART_RE = re.compile(r"\b[A-Z]{2,5}[- ]?\d{3,6}[A-Z0-9]{0,4}\b")     # ORCA7, XR-4821 (part-number shapes)
DEFINE_RE = re.compile(r"#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)")
FUNC_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+)\s*\(")


def cmd_terms(p: Project, a):
    idx_chunks = [json.loads(line) for line in open(p.index / "chunks.jsonl", encoding="utf-8")]
    public_text = " ".join(c["text"] for c in idx_chunks if c["cls"] == "public").upper()
    counts: dict[str, int] = {}
    for c in idx_chunks:
        if c["cls"] != "nda":
            continue
        found: set[str] = set()
        for rx in (IDENT_RE, PART_RE, DEFINE_RE, FUNC_RE):
            found.update(m if isinstance(m, str) else m[0] for m in rx.findall(c["text"]))
        for term in found:                       # count = number of chunks the term appears in
            counts[term] = counts.get(term, 0) + 1
    vendor = p.cfg.get("vendor", "vendor")
    rows = []
    for term, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        up = term.upper()
        if up in GENERIC or len(term) < 4:
            continue
        in_public = re.search(r"\b" + re.escape(up) + r"\b", public_text) is not None
        rows.append((term, n, in_public))
    terms_dir = pathlib.Path(p.cfg.get("terms_dir", os.environ.get("NDA_TERMS_DIR", r"D:\nda\terms")))
    # A subfolder on purpose: nda_guard only reads terms\*.txt, so candidates are inert until you move them.
    cand_dir = terms_dir / "candidates"
    cand_dir.mkdir(parents=True, exist_ok=True)
    out = cand_dir / f"{vendor}.txt"
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(f"# Candidate protected terms for '{vendor}' from {p.root.name} ({dt.date.today()}).\n"
                 f"# Review, then MOVE the lines you want into ..\\{vendor}.txt and run NdaSession.ps1 -Start.\n"
                 f"# Lines marked [also-in-public] appear in public sources - usually NOT confidential.\n"
                 f"# Rename aliases to something meaningful in your API vocabulary if you like.\n"
                 f"# Only identifier-shaped names are found - add codenames and multi-word feature names by hand.\n\n")
        for i, (term, n, pub) in enumerate(rows, 1):
            alias = f"{vendor.upper()}_T{i:03d}"
            fh.write(f"{'# ' if pub else ''}{term} => {alias}    # x{n}{' [also-in-public]' if pub else ''}\n")
    print(f"terms: {len(rows)} candidates -> {out}")


# ----------------------------------------------------------------------------- scope
SYS_RESEARCH = ("You are a senior hardware/software architect doing private R&D for Serial Cables (PCIe, NVMe, "
                "NVMe-MI, MCTP, CXL, I2C/I3C test and management products). Ground every factual claim in the "
                "provided sources and cite them as [S#]. If the sources do not support something, write "
                "'Assumption:' or 'Unknown:' explicitly. Never invent register names, values or behavior.")


def fmt_sources(hits: list[dict]) -> tuple[str, list[dict]]:
    lines, reg = [], []
    for i, h in enumerate(hits, 1):
        reg.append({"s": f"S{i}", "id": h["id"], "doc": h["doc"], "loc": h["loc"], "cls": h["cls"]})
        lines.append(f"[S{i}] ({h['cls']}) {h['doc']} {h['loc']}\n{h['text']}\n")
    return "\n".join(lines), reg


def cmd_scope(p: Project, a):
    brief = p.brief()
    if not brief.strip():
        raise SystemExit("scope: write plan/00-brief.md first (goals, users, constraints)")
    hits = Index(p).search(brief[:2000], k=10)
    src, _ = fmt_sources(hits)
    out = p.llm.chat("research", SYS_RESEARCH,
                     f"PROJECT BRIEF:\n{brief}\n\nSOURCES:\n{src}\n\n"
                     "Write 8-15 scoping questions the owner must answer before an API/UI plan can be drafted. "
                     "Group them (Goals, Users, Interfaces, Hardware/SDK, Constraints, Release). For each: the "
                     "question, one line on why it matters, and an empty line starting with 'Answer:'. Markdown.")
    path = p.plan / "01-scope-questions.md"
    if path.exists():
        shutil.copy(path, path.with_suffix(f".{dt.datetime.now():%Y%m%d%H%M%S}.bak"))
    path.write_text(f"# Scoping questions\n\n_Write your answers after each 'Answer:'. Re-run `draft` afterwards._\n\n{out}\n",
                    encoding="utf-8")
    print(f"scope: {path}")


# ----------------------------------------------------------------------------- draft / critique / revise
def section_footer(reg: list[dict]) -> str:
    rows = "\n".join(f"| {r['s']} | {r['cls']} | {r['doc']} | {r['loc']} | {r['id']} |" for r in reg)
    return ("\n\n---\n<!-- sources -->\n| Ref | Class | Document | Location | Chunk |\n| --- | --- | --- | --- | --- |\n"
            + rows + "\n")


def badge(text: str, reg: list[dict]) -> str:
    cited = set(re.findall(r"\[S(\d+)\]", text))
    classes = {r["cls"] for r in reg if r["s"][1:] in cited}
    if "nda" in classes:
        return "> **Provenance:** uses NDA vendor sources - review before handoff; vendor specifics belong in the binding layer.\n\n"
    if classes:
        return "> **Provenance:** public sources only.\n\n"
    return "> **Provenance:** no sources cited - design decisions/assumptions only.\n\n"


def parse_footer(text: str) -> list[dict]:
    reg = []
    for m in re.finditer(r"^\| (S\d+) \| (\w+) \| (.+?) \| (.+?) \| (\d+) \|$", text, re.M):
        reg.append({"s": m.group(1), "cls": m.group(2), "doc": m.group(3), "loc": m.group(4), "id": int(m.group(5))})
    return reg


def body_of(text: str) -> str:
    return text.split("\n---\n<!-- sources -->")[0]


def draft_one(p: Project, idx: Index, s: dict, extra: str = "") -> pathlib.Path:
    query = f"{s['title']}. {s['ask']}\n{p.brief()[:1500]}"
    hits = idx.search(query, k=10 if s["slug"] == "binding-layer" else 8)
    src, reg = fmt_sources(hits)
    rule = ("This is the binding-layer section: be precise about vendor operations, sequences and values, "
            "citing sources." if s["slug"] == "binding-layer" else
            "Use OUR OWN vocabulary based on public-spec concepts. Do not put vendor part numbers, register "
            "names, SDK function names or codenames in this section - refer to 'the binding layer' instead.")
    body = p.llm.chat("research", SYS_RESEARCH,
                      f"PROJECT BRIEF:\n{p.brief()}\n\nSCOPING Q&A:\n{p.scope_answers()}\n\n"
                      f"SECTION {s['n']}: {s['title']}\nWHAT IT MUST COVER: {s['ask']}\nRULE: {rule}\n{extra}\n\n"
                      f"SOURCES:\n{src}\n\nWrite this section in Markdown (no top-level heading; start with "
                      "the content). Cite [S#] after every sourced claim. Be concrete: names, fields, units, "
                      "sequences, acceptance criteria. Mark assumptions.", max_tokens=6000)
    path = p.section_path(s)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        hist = p.sections / ".history"
        hist.mkdir(exist_ok=True)
        shutil.copy(path, hist / f"{path.stem}.{dt.datetime.now():%Y%m%d%H%M%S}.md")
    path.write_text(f"## {s['n']}. {s['title']}\n\n{badge(body, reg)}{body}{section_footer(reg)}", encoding="utf-8")
    return path


def pick_sections(p: Project, a) -> list[dict]:
    out = p.outline()
    if a.section:
        out = [s for s in out if s["n"] in a.section]
    return out


def cmd_draft(p: Project, a):
    idx = Index(p)
    for s in pick_sections(p, a):
        print(f"draft: section {s['n']} {s['title']} ...")
        print(f"  -> {draft_one(p, idx, s)}")


def cmd_critique(p: Project, a):
    idx = Index(p)
    by_id = {c["id"]: c for c in idx.chunks}
    out = [f"# Critic review ({dt.datetime.now():%Y-%m-%d %H:%M}, model {p.llm.m['critic']})\n"]
    for s in pick_sections(p, a):
        path = p.section_path(s)
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        reg = parse_footer(text)
        src = "\n".join(f"[{r['s']}] ({r['cls']}) {r['doc']} {r['loc']}\n{by_id[r['id']]['text']}\n"
                        for r in reg if r["id"] in by_id)
        res = p.llm.chat("critic", "You are a strict technical reviewer. Check the draft ONLY against the cited sources.",
                         f"DRAFT SECTION:\n{body_of(text)}\n\nCITED SOURCES:\n{src}\n\n"
                         "List, as Markdown bullets under these headings: Unsupported or wrong claims (quote them), "
                         "Missing items the sources say matter, Contradictions, Vendor terms leaking outside the "
                         "binding layer (section 7 is the only place they belong), Questions for the owner. "
                         "Write 'None' under a heading with no findings.", max_tokens=3000, temperature=0.1)
        out.append(f"\n## Section {s['n']}: {s['title']}\n\n{res}\n")
        print(f"critique: section {s['n']} done")
    (p.plan / "review.md").write_text("\n".join(out), encoding="utf-8")
    print(f"critique: {p.plan / 'review.md'}")


def cmd_revise(p: Project, a):
    idx = Index(p)
    review = (p.plan / "review.md").read_text(encoding="utf-8") if (p.plan / "review.md").exists() else ""
    for s in pick_sections(p, a):
        path = p.section_path(s)
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        comments = "\n".join(line[2:].strip() for line in text.splitlines() if line.startswith(">>"))
        m = re.search(rf"## Section {s['n']}:.*?(?=\n## Section |\Z)", review, re.S)
        findings = m.group(0) if m else ""
        if not comments and not findings:
            print(f"revise: section {s['n']} - nothing to apply")
            continue
        extra = (f"PREVIOUS DRAFT:\n{body_of(text)}\n\nOWNER COMMENTS (highest priority):\n{comments or 'none'}\n\n"
                 f"CRITIC FINDINGS:\n{findings or 'none'}\n\nRevise the previous draft: apply every owner "
                 "comment, fix every valid finding, keep what was right.")
        print(f"revise: section {s['n']} ({len(comments.splitlines())} comments) ...")
        print(f"  -> {draft_one(p, idx, s, extra)}")


# ----------------------------------------------------------------------------- handoff
def load_guard():
    g = os.environ.get("NDA_GUARD") or str(pathlib.Path.home() / ".surface-ultra" / "tools" / "nda_guard.py")
    if not pathlib.Path(g).exists():
        g = str(HERE.parent / "nda_guard.py")
    spec = importlib.util.spec_from_file_location("nda_guard", g)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


CLAUDE_MD = """# Project rules for Claude Code

- This project ships OUR OWN API. The plan in `docs/plan/PLAN.md` is the source of truth.
- Vendor-specific behaviour lives only in the binding layer (`binding/`). In code it uses the aliases in
  the plan (e.g. SWITCH_A, REG_DBG0). Real names and values are loaded at runtime from a local-only data
  map that is not in this repository. Never ask for, guess or reconstruct real vendor names or values.
- Build and test against a mock binding layer that implements the interface in the plan; hardware tests
  are run locally by the owner.
- If anything is ambiguous, ask - do not invent vendor behaviour.
"""


def cmd_handoff(p: Project, a):
    guard = load_guard()
    secs = [(s, p.section_path(s)) for s in p.outline() if p.section_path(s).exists()]
    if not secs:
        raise SystemExit("handoff: no drafted sections")
    local, cloud = p.root / "handoff" / "local", p.root / "handoff" / "cloud"
    (p.root / "handoff" / "manifest.json").unlink(missing_ok=True)   # only a clean run writes a new one
    for d in (local, cloud):
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)

    def clean(text: str) -> str:   # drop review comments
        return "\n".join(line for line in text.splitlines() if not line.startswith(">>"))

    title = p.cfg.get("title", p.root.name)
    full = [f"# {title} - plan\n\n_Generated locally {dt.date.today()} by plan_agent from {len(secs)} sections._\n"]
    binding = []
    for s, path in secs:
        t = clean(path.read_text(encoding="utf-8"))
        full.append(t)
        if s["slug"] == "binding-layer":
            binding.append(t)
    (local / "PLAN.md").write_text("\n\n".join(full), encoding="utf-8")
    (local / "BINDING-LAYER.md").write_text(
        "# Binding layer - LOCAL ONLY\n\nReal vendor operations, names and values. Implement the runtime data map "
        "from this; it never goes to the cloud or into a repo.\n\n" + "\n\n".join(binding), encoding="utf-8")

    # Cloud pack: no NDA source citations, binding layer reduced to its interface, terms redacted.
    terms = guard.read_terms()
    pairs = [(t["real"], t["alias"]) for t in terms]
    out_parts = [full[0]]
    for s, path in secs:
        t = clean(path.read_text(encoding="utf-8"))
        reg = {r["s"]: r for r in parse_footer(t)}
        body = body_of(t)
        body = re.sub(r"\[(S\d+)\]", lambda m: "[vendor ref]" if reg.get(m.group(1), {}).get("cls") == "nda"
                      else f"[{m.group(1)}]", body)
        if s["slug"] == "binding-layer":
            body = (f"## {s['n']}. {s['title']}\n\n_Interface only. Implement against a mock; the real implementation "
                    "data is supplied locally at runtime._\n\n" +
                    p.llm.chat("research", SYS_RESEARCH,
                               f"From this binding-layer section, write ONLY the interface the rest of the "
                               f"code needs: operation names (our vocabulary), parameters, return values, errors, "
                               f"timing expectations. No vendor register names, addresses, values, sequences or "
                               f"SDK function names.\n\n{body}", max_tokens=3000))
        pub = [r for r in reg.values() if r["cls"] == "public"]
        foot = ("\n\n**Public sources:** " + "; ".join(f"{r['s']} {r['doc']} {r['loc']}" for r in pub)) if pub else ""
        out_parts.append(body + foot)
    text, n = guard._sub("\n\n".join(out_parts), pairs)
    (cloud / "PLAN.md").write_text(text, encoding="utf-8")
    (cloud / "CLAUDE.md").write_text(CLAUDE_MD, encoding="utf-8")
    print(f"handoff: {n} protected term(s) replaced by aliases")

    # Scan the whole cloud pack with the guard's index; refuse on any hit.
    k, hashes, max_n = guard.load_index()
    if not hashes:
        print("handoff: WARNING - no term index (add term lists + NdaSession.ps1 -Start); scan was a no-op")
    bad = []
    for f in cloud.rglob("*"):
        if f.is_file():
            hits = guard.find_hits(f.read_text(encoding="utf-8", errors="ignore"), k, hashes, max_n)
            if hits:
                bad.append((f, guard.describe(hits)))
    if bad:
        for f, d in bad:
            print(f"handoff: BLOCKED {f.name}: {d}")
        shutil.rmtree(cloud)
        raise SystemExit("handoff: cloud pack removed - add aliases for these terms, re-run handoff")
    digest = hashlib.sha256((cloud / "PLAN.md").read_bytes()).hexdigest()[:16]
    (p.root / "handoff" / "manifest.json").write_text(json.dumps({
        "built": dt.datetime.now().isoformat(timespec="seconds"), "sections": len(secs),
        "replacements": n, "scan": "clean", "plan_sha256_16": digest}, indent=2), encoding="utf-8")
    print(f"handoff: clean. Review {cloud / 'PLAN.md'} yourself, then run Export-Handoff.ps1")


def cmd_status(p: Project, a):
    meta = p.index / "meta.json"
    print(f"project : {p.root}")
    print(f"index   : {json.loads(meta.read_text())['count'] if meta.exists() else 'not built'} chunks")
    print(f"brief   : {'yes' if p.brief().strip() else 'missing (plan/00-brief.md)'}")
    print(f"scope   : {'yes' if (p.plan / '01-scope-questions.md').exists() else 'no'}")
    for s in p.outline():
        f = p.section_path(s)
        c = sum(1 for line in f.read_text(encoding='utf-8').splitlines() if line.startswith('>>')) if f.exists() else 0
        print(f"  {s['n']:2}. {s['title']:<48} {'drafted' if f.exists() else '-':8} {f'{c} comments' if c else ''}")
    print(f"review  : {'yes' if (p.plan / 'review.md').exists() else 'no'}")
    print(f"handoff : {'ready' if (p.root / 'handoff' / 'cloud' / 'PLAN.md').exists() else 'no'}")


STEPS = {"ingest": cmd_ingest, "terms": cmd_terms, "scope": cmd_scope, "draft": cmd_draft,
         "critique": cmd_critique, "revise": cmd_revise, "handoff": cmd_handoff, "status": cmd_status}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=list(STEPS))
    ap.add_argument("--project", required=True)
    ap.add_argument("--section", type=int, action="append", help="limit to section number(s)")
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    STEPS[a.step](Project(pathlib.Path(a.project)), a)


if __name__ == "__main__":
    main()
