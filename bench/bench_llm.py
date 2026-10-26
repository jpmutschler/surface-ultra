#!/usr/bin/env python3
"""
Local-model bake-off for the Surface Laptop Ultra (stdlib only - runs on any Python 3.10+).

Measures, per model, against any OpenAI-compatible endpoint (llama-swap, LiteLLM, vLLM):
  * load time, TTFT, prefill and decode tok/s at several prompt sizes
  * tool-calling accuracy on Serial Cables-style HIL tools (incl. "don't call a tool" cases)
  * PCIe / NVMe-MI / MCTP / CXL / I3C spec Q&A
  * grounded research Q&A: answer only from a supplied excerpt, cite the page, and abstain
    when the excerpt doesn't contain the answer (the core NDA-research skill)
  * small protocol-coding tasks graded by running asserts (python -I, temp dir, timeout)
  * AC vs battery is recorded with every run (Windows GetSystemPowerStatus)

Usage:
  python bench_llm.py --models sc-research,sc-analyst --base http://127.0.0.1:8080/v1
  python bench_llm.py --models sc-analyst --speed-only
  python bench_llm.py --models sc-research --tasks bench/tasks.jsonl --tasks D:/nda/research/bench-tasks.jsonl
NDA-derived tasks belong in the NDA workspace, not in this repo.
Results land in bench/results/<stamp>/ as JSON + summary.md.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent

FILLER = (
    "In FLIT mode the PCIe 6.0 data link layer packs TLPs into fixed 256-byte flits protected by "
    "CRC and a lightweight forward error correction code, which lets the PHY run PAM4 signaling at "
    "64 GT/s with a raw bit error rate far above what NRZ links tolerated. The LTSSM still walks "
    "Detect, Polling, Configuration and L0, and Recovery handles speed changes and equalization. "
    "NVMe-MI messages ride MCTP over SMBus/I2C or PCIe VDM, and CXL multiplexes CXL.io, CXL.cache "
    "and CXL.mem on the same physical layer. "
)


# ----------------------------------------------------------------------------- helpers
def power_source() -> str:
    if os.name != "nt":
        return "n/a"

    class SPS(ctypes.Structure):
        _fields_ = [("ACLineStatus", ctypes.c_byte), ("BatteryFlag", ctypes.c_byte),
                    ("BatteryLifePercent", ctypes.c_byte), ("SystemStatusFlag", ctypes.c_byte),
                    ("BatteryLifeTime", ctypes.c_ulong), ("BatteryFullLifeTime", ctypes.c_ulong)]
    s = SPS()
    if not ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s)):
        return "unknown"
    return f"{'AC' if s.ACLineStatus == 1 else 'battery'} {s.BatteryLifePercent}%"


def post(base: str, path: str, body: dict, key: str | None, timeout: int = 1800, stream: bool = False):
    req = urllib.request.Request(
        base.rstrip("/") + path, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {key}"} if key else {})})
    resp = urllib.request.urlopen(req, timeout=timeout)
    if stream:
        return resp
    return json.loads(resp.read().decode())


def chat(base, key, model, messages, max_tokens=4096, tools=None, temperature=0.2):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    t0 = time.perf_counter()
    r = post(base, "/chat/completions", body, key)
    return r, time.perf_counter() - t0


def stream_timing(base, key, model, prompt, max_tokens=256):
    """Returns dict with ttft_s, decode_tps, prefill_tps, prompt_tokens (server timings when available)."""
    body = {"model": model, "stream": True, "max_tokens": max_tokens, "temperature": 0,
            "messages": [{"role": "user", "content": prompt}],
            "stream_options": {"include_usage": True}}
    t0 = time.perf_counter()
    ttft = None
    n_chunks = 0
    timings = None
    usage = None
    with post(base, "/chat/completions", body, key, stream=True) as resp:
        for raw in resp:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except json.JSONDecodeError:
                continue
            if obj.get("timings"):
                timings = obj["timings"]
            if obj.get("usage"):
                usage = obj["usage"]
            for ch in obj.get("choices", []):
                d = ch.get("delta", {})
                if d.get("content") or d.get("reasoning_content"):
                    n_chunks += 1
                    if ttft is None:
                        ttft = time.perf_counter() - t0
    total = time.perf_counter() - t0
    out = {"ttft_s": round(ttft or total, 3), "wall_s": round(total, 2)}
    if timings:  # llama.cpp server reports exact numbers
        out["prefill_tps"] = round(timings.get("prompt_per_second", 0), 1)
        out["decode_tps"] = round(timings.get("predicted_per_second", 0), 1)
        out["prompt_tokens"] = timings.get("prompt_n")
    else:
        gen_time = max(total - (ttft or 0), 1e-6)
        out["decode_tps"] = round(n_chunks / gen_time, 1)
        if usage:
            out["prompt_tokens"] = usage.get("prompt_tokens")
    return out


def parse_num(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        s = v.strip().lower()
        if s in ("true", "false"):
            return s == "true"
        try:
            return int(s, 0)
        except ValueError:
            return s
    return v


def norm(v):
    v = parse_num(v)
    return v.lower() if isinstance(v, str) else v


def extract_code(text: str) -> str:
    m = re.findall(r"```(?:python|py)?\s*\n(.*?)```", text, re.S)
    return max(m, key=len) if m else text


# ----------------------------------------------------------------------------- graders
def grade_toolcall(task, msg):
    calls = msg.get("tool_calls") or []
    if task.get("expect") is None:  # negative case: must answer without a tool
        return (len(calls) == 0), ("no tool call" if not calls else f"called {calls[0]['function']['name']}")
    if not calls:
        return False, "no tool call"
    fn = calls[0]["function"]
    try:
        args = json.loads(fn.get("arguments") or "{}")
    except json.JSONDecodeError:
        return False, "invalid JSON arguments"
    if fn.get("name") != task["expect"]["name"]:
        return False, f"wrong tool {fn.get('name')}"
    for k, v in task["expect"].get("args", {}).items():
        if norm(args.get(k)) != norm(v):
            return False, f"arg {k}={args.get(k)!r} expected {v!r}"
    return True, "ok"


def grade_qa(task, msg):
    text = (msg.get("content") or "").lower()
    if "expect_all" in task:
        miss = [e for e in task["expect_all"] if e.lower() not in text]
        return (not miss), ("ok" if not miss else f"missing {miss}")
    hit = any(e.lower() in text for e in task["expect_any"])
    return hit, ("ok" if hit else f"none of {task['expect_any']}")


def grade_code(task, msg):
    code = extract_code(msg.get("content") or "")
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "solution.py"
        p.write_text(code + "\n\n" + task["test"] + "\nprint('PASS')\n", encoding="utf-8")
        try:
            r = subprocess.run([sys.executable, "-I", str(p)], cwd=d, capture_output=True, text=True, timeout=20)
        except subprocess.TimeoutExpired:
            return False, "timeout"
        ok = r.returncode == 0 and "PASS" in r.stdout
        return ok, ("ok" if ok else (r.stderr.strip().splitlines() or ["fail"])[-1][:160])


ABSTAIN = ("not in the", "not specified", "not provided", "not mentioned", "not stated", "no information",
           "cannot find", "can't find", "cannot be determined", "does not say", "doesn't say", "not contain",
           "does not specify", "doesn't specify", "not covered", "unknown from")


def grade_grounded(task, msg):
    text = (msg.get("content") or "").lower()
    ok, why = grade_qa(task, msg)
    if ok and task.get("expect_cite") and task["expect_cite"].lower() not in text:
        return False, f"missing citation {task['expect_cite']}"
    return ok, why


def grade_abstain(task, msg):
    text = (msg.get("content") or "").lower()
    hit = any(p in text for p in ABSTAIN)
    bad = [w for w in task.get("forbid", []) if w.lower() in text]
    if bad:
        return False, f"hallucinated {bad}"
    return hit, ("abstained" if hit else "answered without support")


GRADERS = {"toolcall": grade_toolcall, "qa": grade_qa, "code": grade_code,
           "grounded": grade_grounded, "abstain": grade_abstain}


# ----------------------------------------------------------------------------- main
def run_model(args, model, tasks, tools):
    res = {"model": model, "power": power_source(), "started": dt.datetime.now().isoformat(timespec="seconds")}
    # load / warm-up (llama-swap loads the model on first request)
    t0 = time.perf_counter()
    try:
        chat(args.base, args.key, model, [{"role": "user", "content": "Reply with OK."}], max_tokens=512)
    except urllib.error.URLError as e:
        res["error"] = f"load failed: {e}"
        return res
    res["load_s"] = round(time.perf_counter() - t0, 1)
    print(f"  loaded in {res['load_s']}s ({res['power']})")

    speed = []
    for n in args.ctx:
        prompt = (FILLER * (n * 4 // len(FILLER) + 1))[: n * 4] + "\n\nSummarize the text above in three bullet points."
        try:
            s = stream_timing(args.base, args.key, model, prompt)
        except Exception as e:  # noqa: BLE001
            s = {"error": str(e)}
        s["target_prompt_tokens"] = n
        speed.append(s)
        print(f"  ctx~{n}: {s}")
    res["speed"] = speed
    if args.speed_only:
        return res

    sys_prompt = ("You are a hardware validation assistant for PCIe, NVMe-MI, MCTP, CXL and I2C/I3C work. "
                  "Use a tool only when the user asks for an action or live data.")
    scored = []
    for t in tasks:
        if t["type"] in ("grounded", "abstain"):
            sp = ("Answer ONLY from the excerpt below. Cite the page like [p.N]. If the excerpt does not "
                  "contain the answer, say it is not in the excerpt. Do not use outside knowledge.\n\n"
                  "EXCERPT:\n" + t["context"])
            msgs = [{"role": "system", "content": sp}, {"role": "user", "content": t["prompt"]}]
        else:
            msgs = [{"role": "system", "content": sys_prompt}, {"role": "user", "content": t["prompt"]}]
        try:
            r, wall = chat(args.base, args.key, model, msgs, tools=tools if t["type"] == "toolcall" else None)
            msg = r["choices"][0]["message"]
            ok, why = GRADERS[t["type"]](t, msg)
        except Exception as e:  # noqa: BLE001
            ok, why, wall = False, f"error: {e}", 0
        scored.append({"id": t["id"], "type": t["type"], "pass": ok, "why": why, "wall_s": round(wall, 1)})
        print(f"  {'PASS' if ok else 'FAIL'} {t['id']:<22} {why}")
    res["tasks"] = scored
    for ty in GRADERS:
        sub = [s for s in scored if s["type"] == ty]
        if sub:
            res[f"{ty}_score"] = round(100 * sum(s["pass"] for s in sub) / len(sub))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8080/v1")
    ap.add_argument("--key", default=os.environ.get("BENCH_API_KEY"))
    ap.add_argument("--models", required=True, help="comma-separated aliases")
    ap.add_argument("--ctx", default="512,8192,32768", help="prompt sizes (approx tokens)")
    ap.add_argument("--tasks", action="append", help="tasks .jsonl (repeatable); default bench/tasks.jsonl")
    ap.add_argument("--tools", default=str(HERE / "tools.json"))
    ap.add_argument("--speed-only", action="store_true")
    ap.add_argument("--out", default=str(HERE / "results"))
    args = ap.parse_args()
    args.ctx = [int(x) for x in args.ctx.split(",") if x]

    tasks = []
    for tf in args.tasks or [str(HERE / "tasks.jsonl")]:
        tasks += [json.loads(line) for line in open(tf, encoding="utf-8") if line.strip() and not line.startswith("//")]
    tools = json.load(open(args.tools, encoding="utf-8"))
    outdir = pathlib.Path(args.out) / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir.mkdir(parents=True, exist_ok=True)

    all_res = []
    for m in [x.strip() for x in args.models.split(",") if x.strip()]:
        print(f"== {m}")
        r = run_model(args, m, tasks, tools)
        all_res.append(r)
        (outdir / f"{m}.json").write_text(json.dumps(r, indent=2), encoding="utf-8")

    lines = ["| Model | Power | Load s | Decode tok/s (ctx) | Prefill tok/s (largest ctx) | Grounded % | Abstain % | Tool calls % | Spec Q&A % | Code % |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for r in all_res:
        sp = r.get("speed", [])
        dec = " / ".join(str(s.get("decode_tps", "-")) for s in sp)
        pre = sp[-1].get("prefill_tps", "-") if sp else "-"
        lines.append(f"| {r['model']} | {r.get('power')} | {r.get('load_s', '-')} | {dec} | {pre} | "
                     f"{r.get('grounded_score', '-')} | {r.get('abstain_score', '-')} | "
                     f"{r.get('toolcall_score', '-')} | {r.get('qa_score', '-')} | {r.get('code_score', '-')} |")
    summary = "\n".join(lines)
    (outdir / "summary.md").write_text(summary + "\n", encoding="utf-8")
    print("\n" + summary + f"\n\nResults: {outdir}")


if __name__ == "__main__":
    main()
