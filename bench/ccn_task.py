#!/usr/bin/env python3
"""
ccn_task - an agentic bake-off task for Claude Code on local models (the ccn profile).

The plain bench (bench_llm.py) asks a model questions directly. This asks the model to DRIVE Claude
Code: read a document in a project folder, write an answer file with citations, and abstain where the
document is silent. It measures what ccn needs day to day: tool use through Claude Code's harness,
file reading and writing, grounding, abstention, turns and wall time.

The document is the FICTIONAL ORCA-7 excerpt from tasks.jsonl, so this is safe to run anywhere.

  python ccn_task.py prepare <dir>                 # writes docs/orca7.md + TASK.md, prints the prompt
  python ccn_task.py grade <dir> <result.json> <model>   # scores notes/answers.md, appends results.jsonl
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bench_llm  # noqa: E402  (grade_grounded / grade_abstain)

PROMPT = ("Read TASK.md in this folder and do exactly what it says. Use only docs/orca7.md as your "
          "source. When you are done, reply with the single word DONE.")


def tasks():
    out = []
    for line in (HERE / "tasks.jsonl").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        t = json.loads(line)
        if t.get("type") in ("grounded", "abstain"):
            out.append(t)
    return out


def prepare(d: pathlib.Path):
    ts = tasks()
    (d / "docs").mkdir(parents=True, exist_ok=True)
    (d / "notes").mkdir(exist_ok=True)
    (d / "docs" / "orca7.md").write_text("# ORCA-7 datasheet excerpt (fictional)\n\n" + ts[0]["context"] + "\n",
                                          encoding="utf-8")
    qs = "\n".join(f"Q{i + 1}. {t['prompt']}" for i, t in enumerate(ts))
    (d / "TASK.md").write_text(
        "# Task\n\nAnswer every question below using ONLY docs/orca7.md.\n\n"
        "Write the answers to notes/answers.md, one section per question headed exactly `## Q<n>`.\n"
        "Cite the page for every fact as [p.NN]. If the document does not contain the answer, write\n"
        "\"Not in the sources.\" for that question - do not guess.\n\n" + qs + "\n", encoding="utf-8")
    (d / "questions.json").write_text(json.dumps(ts), encoding="utf-8")
    print(PROMPT)


def grade(d: pathlib.Path, result_file: pathlib.Path, model: str):
    ts = json.loads((d / "questions.json").read_text(encoding="utf-8"))
    ans_file = d / "notes" / "answers.md"
    text = ans_file.read_text(encoding="utf-8", errors="ignore") if ans_file.exists() else ""
    sections = {int(m.group(1)): m.group(2) for m in
                re.finditer(r"^##\s*Q(\d+)\b(.*?)(?=^##\s*Q\d+\b|\Z)", text, re.S | re.M)}
    rows, g_ok, a_ok, g_n, a_n = [], 0, 0, 0, 0
    for i, t in enumerate(ts, 1):
        msg = {"content": sections.get(i, "")}
        ok, why = (bench_llm.grade_grounded if t["type"] == "grounded" else bench_llm.grade_abstain)(t, msg)
        rows.append((i, t["id"], ok, why))
        if t["type"] == "grounded":
            g_n += 1
            g_ok += ok
        else:
            a_n += 1
            a_ok += ok
    try:
        res = json.loads(result_file.read_text(encoding="utf-8", errors="ignore") or "{}") if result_file.exists() else {}
    except ValueError:      # claude -p printed something other than its JSON result
        res = {}
    summary = {
        "model": model, "answers_file": ans_file.exists(),
        "grounded": f"{g_ok}/{g_n}", "abstain": f"{a_ok}/{a_n}",
        "turns": res.get("num_turns"), "seconds": round((res.get("duration_ms") or 0) / 1000, 1),
        "error": res.get("is_error"),
    }
    for i, tid, ok, why in rows:
        print(f"  Q{i:<2} {tid:<22} {'PASS' if ok else 'FAIL'}  {why}")
    print(json.dumps(summary))
    with open(HERE / "results" / "ccn_results.jsonl", "a", encoding="utf-8") as fh:
        fh.write(json.dumps(summary) + "\n")


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "prepare":
        prepare(pathlib.Path(sys.argv[2]))
    elif len(sys.argv) >= 5 and sys.argv[1] == "grade":
        (HERE / "results").mkdir(exist_ok=True)
        grade(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
