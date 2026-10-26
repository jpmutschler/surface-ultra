#!/usr/bin/env python3
"""
Idempotently merge Claude Code settings for the two profiles on this laptop.

--profile cloud (default) -> %USERPROFILE%\\.claude  (your Max login; `claude`)
  * permissions       - blockReadsOutsideWorkingDirectories, plus Read/Edit deny rules for the
                        NDA workspace and the guard's key/index
  * hooks             - nda_guard on UserPromptSubmit and PreToolUse (file, shell, web, MCP tools)
  * env               - CLAUDE_CODE_GIT_BASH_PATH when Git Bash exists
  * CLAUDE.md         - the standing NDA rule, in a managed block

--profile local -> D:\\nda\\.claude  (`ccn`: Claude Code on local models, NDA research)
  * env               - ANTHROPIC_BASE_URL = the NDA gateway on loopback, model slots, and every
                        switch that stops non-model traffic to Anthropic (telemetry, error reports,
                        /feedback, surveys, marketplace auto-install)
  * apiKeyHelper      - reads the NDA gateway key from D:\\nda\\secrets (never your Max login)
  * skipWebFetchPreflight, WebSearch denied (it runs on Anthropic's servers)
  * permissions       - Edit denied in the repo tree (NDA research never writes into a repo)
  * CLAUDE.md         - the local research rules, in a managed block

Re-running replaces only what this script manages; your other settings are kept.
"""
from __future__ import annotations

import argparse
import json
import pathlib

MARK = "nda_guard.py"
MD_BEGIN = "<!-- surface-ultra:nda-rule:begin -->"
MD_END = "<!-- surface-ultra:nda-rule:end -->"

NDA_RULE = f"""{MD_BEGIN}
## NDA rule (applies to every project)

- Vendor NDA SDKs, documents and research notes are research material only. They stay in the
  local environment (the NDA workspace on this laptop and the DGX Spark) and are never copied into
  a project. You (a cloud model) never receive them.
- Projects ship OUR OWN API built from what was learned: our names and concepts, mostly defined by
  public specs (PCIe, NVMe, NVMe-MI, MCTP, CXL, I2C/I3C). Never vendor SDK files or headers.
- Anything genuinely vendor-specific lives in a thin, isolated binding layer. In code you touch it
  uses aliases (e.g. SWITCH_A, REG_DBG0); real names and values come from a local-only data map at
  runtime. Do not ask for, guess, or reconstruct real vendor part numbers, register names,
  codenames or values.
- Work only inside this session's working directories. If the NDA guard blocks a prompt, file or
  tool call, do not work around it - tell me which step needs obfuscating.
- Research over NDA material happens in the local profile (`ccn`, Claude Code on local models), not
  here. If a task needs it, say so and stop; plans arrive here as the obfuscated pack in docs/plan.
{MD_END}
"""


LOCAL_BEGIN = "<!-- surface-ultra:ccn-rule:begin -->"
LOCAL_END = "<!-- surface-ultra:ccn-rule:end -->"
LOCAL_RULE = f"""{LOCAL_BEGIN}
## You are running on LOCAL models (ccn profile) inside the NDA workspace

- Everything in this session stays on this laptop and the DGX Spark. NDA material is allowed here:
  vendor SDKs, documents, term lists and research notes.
- Ground every factual claim in a source you actually read (nda-rag / specs MCP results or files in
  this workspace) and cite it: document, page or section, table. If the sources do not say it, write
  "not in the sources" - never fill gaps from memory.
- Work inside D:\\nda (research projects live in D:\\nda\\projects\\<name>). Never write into a code
  repository. Plans reach a repo only through `tools\\plan\\plan.ps1 handoff` and
  `tools\\plan\\Export-Handoff.ps1`, which obfuscate, scan and ask Josh to confirm.
- The deliverable of research is OUR OWN API: our vocabulary from public specs, with vendor specifics
  confined to the binding-layer section (section 7 of the plan).
- Prefer the planning pipeline steps (`plan.ps1 ingest|terms|scope|draft|critique|revise|handoff`)
  over ad-hoc long generations; they record provenance per chunk.
{LOCAL_END}
"""

LOCAL_ENV = {
    # non-model traffic to Anthropic: all off (https://code.claude.com/docs/en/data-usage)
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_FEEDBACK_COMMAND": "1",
    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
    "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
}


def merge_local_settings(path: pathlib.Path, py: str, base_url: str, key_file: str,
                         model: str, fast_model: str, deny: list[str], git_bash: str | None):
    s = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    env = s.setdefault("env", {})
    env.update(LOCAL_ENV)
    env["ANTHROPIC_BASE_URL"] = base_url
    env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = fast_model
    env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
    env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
    for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):    # the helper below is the only credential
        env.pop(k, None)
    if git_bash:
        env["CLAUDE_CODE_GIT_BASH_PATH"] = git_bash
    s["model"] = model
    kf = key_file.replace("\\", "/")
    s["apiKeyHelper"] = f'"{py}" -I -c "import pathlib;print(pathlib.Path(r\'{kf}\').read_text().strip())"'
    s["skipWebFetchPreflight"] = True
    perms = s.setdefault("permissions", {})
    cur = perms.setdefault("deny", [])
    for rule in ["WebSearch"] + deny:
        if rule not in cur:
            cur.append(rule)
    # no nda_guard hooks here: this profile never talks to a cloud model
    hooks = s.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if MARK not in json.dumps(g)]
        if not hooks[event]:
            del hooks[event]
    if "hooks" in s and not s["hooks"]:
        del s["hooks"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(s, indent=2) + "\n", encoding="utf-8")


def merge_settings(path: pathlib.Path, py: str, guard: str, deny: list[str], git_bash: str | None):
    s = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    perms = s.setdefault("permissions", {})
    # File tools refuse anything outside the session's working directories, in every permission mode.
    perms["blockReadsOutsideWorkingDirectories"] = True
    cur = perms.setdefault("deny", [])
    for rule in deny:
        if rule not in cur:
            cur.append(rule)

    cmd = f'"{py}" -I "{guard}" hook'
    hooks = s.setdefault("hooks", {})
    wanted = {
        "UserPromptSubmit": {"hooks": [{"type": "command", "command": cmd, "timeout": 20}]},
        "PreToolUse": {"matcher": "Read|Grep|Glob|Bash|PowerShell|WebFetch|WebSearch|mcp__.*",
                       "hooks": [{"type": "command", "command": cmd, "timeout": 20}]},
    }
    for event, group in wanted.items():
        groups = [g for g in hooks.get(event, []) if MARK not in json.dumps(g)]
        groups.append(group)
        hooks[event] = groups

    if git_bash:
        s.setdefault("env", {})["CLAUDE_CODE_GIT_BASH_PATH"] = git_bash
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(s, indent=2) + "\n", encoding="utf-8")


def merge_claude_md(path: pathlib.Path, block: str = NDA_RULE, begin: str = MD_BEGIN, end: str = MD_END):
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if begin in text and end in text:
        pre, rest = text.split(begin, 1)
        post = rest.split(end, 1)[1]
        text = pre + block.strip() + post
    else:
        text = (text.rstrip() + "\n\n" if text.strip() else "") + block
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", choices=["cloud", "local"], default="cloud")
    ap.add_argument("--claude-dir", required=True)
    ap.add_argument("--python", required=True)
    ap.add_argument("--guard", help="cloud profile: path to nda_guard.py")
    ap.add_argument("--deny", action="append", default=[])
    ap.add_argument("--git-bash")
    ap.add_argument("--base-url", help="local profile: NDA gateway, must be loopback")
    ap.add_argument("--key-file", help="local profile: file holding the NDA gateway key")
    ap.add_argument("--model", default="sc-research")
    ap.add_argument("--fast-model", default="sc-fast")
    a = ap.parse_args()
    d = pathlib.Path(a.claude_dir)
    fwd = lambda p: p.replace("\\", "/")  # noqa: E731 - Git Bash runs hook and helper commands
    if a.profile == "local":
        if not a.base_url or not a.key_file:
            ap.error("--profile local needs --base-url and --key-file")
        host = (a.base_url.split("://", 1)[-1].split("/", 1)[0].rsplit(":", 1)[0]).strip("[]").lower()
        if host not in ("127.0.0.1", "localhost", "::1"):
            ap.error(f"--base-url must be loopback for the local profile, got {host}")
        merge_local_settings(d / "settings.json", fwd(a.python), a.base_url, a.key_file,
                             a.model, a.fast_model, a.deny, a.git_bash)
        merge_claude_md(d / "CLAUDE.md", LOCAL_RULE, LOCAL_BEGIN, LOCAL_END)
        print(f"claude_settings: local (ccn) profile written to {d / 'settings.json'} and {d / 'CLAUDE.md'}")
        return
    if not a.guard:
        ap.error("--profile cloud needs --guard")
    merge_settings(d / "settings.json", fwd(a.python), fwd(a.guard), a.deny, a.git_bash)
    merge_claude_md(d / "CLAUDE.md")
    print(f"claude_settings: guardrails merged into {d / 'settings.json'} and {d / 'CLAUDE.md'}")


if __name__ == "__main__":
    main()
