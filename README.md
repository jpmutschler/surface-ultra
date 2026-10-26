# surface-ultra

Build scripts that turn a **Surface Laptop Ultra** into the primary Serial Cables R&D workstation. The target config is RTX Spark N1X, 20-core CPU, 6,144-core Blackwell GPU, 128 GB unified memory, 1 TB SSD, Windows 11 Pro **ARM64**.

**Division of labor (Oct 26, 2026):**

- **Local (this laptop + the DGX Spark):** private R&D. Research, planning and design over NDA/SLA material, using local models, local MCP servers and RAG. Nothing in this zone reaches a cloud model.
- **Claude (Max plan):** long-running coding, testing and advanced research on *obfuscated* material.
- **DGX Spark:** an extension of the laptop, reached over the LAN or Tailscale. It hosts the heavy and shared pieces: the Spec MCP, the NDA RAG plus ingestion, big models, and Langfuse. The laptop keeps anything interactive, hardware-bound or needed offline. See `spark/README.md` and the Spark overhaul plan.

> **Standing NDA rule (all projects):** make a best effort to obfuscate NDA data before it is used with Claude cloud models. NDA SDKs and documents are **research material, not project dependencies**: we learn from them and build **our own API**. Vendor specifics live only in a thin binding layer that uses aliases, with the real names and values in a local-only data map. Code that implements vendor NDA material may be written with Claude this way; the documents and research stay local.

The full rationale is in the build plan doc.

## How you work on this machine

Terminal first. Everything below runs from Windows Terminal; the apps are there for when a project needs them.

| Work | Where | Model | NDA allowed? |
| --- | --- | --- | --- |
| Research and planning over NDA material | **`ccn`**: Claude Code on local models, in the red **NDA \| LOCAL** tab, inside `D:\nda\projects\<name>`. It has the nda-rag and specs MCPs and drives `tools\plan`. | `spark/research` on the tailnet, `sc-research` offline | Yes |
| Reading and annotating plan sections | `glow` / Helix in the same red tab | — | Yes |
| Handoff to a repo | `tools\plan\Export-Handoff.ps1` | — | Scanned, obfuscated pack only |
| Building and testing | **`claude`** (Max) in the repo | Claude | No: aliases only |
| Debugging when the terminal isn't enough | PyCharm / CLion (JetBrains Toolbox), connected to the terminal session with `/ide`; Visual Studio + WinDbg for drivers | Claude, via the terminal session | No |
| General conversation, docs, non-NDA planning | Cowork (Claude desktop app) | Claude | No |
| Quick chat over NDA documents | Open WebUI http://127.0.0.1:3000 | Local | Yes |

**Two Claude Code profiles, one binary:**

- `claude` uses your Max login and `%USERPROFILE%\.claude`, with the NDA guardrails (below). A profile function refuses to start it inside `D:\nda`.
- `ccn` uses `D:\nda\.claude`: its own settings, MCP list and transcripts. It talks only to the **NDA gateway** (LiteLLM on `127.0.0.1:4001`, no trace export), with that gateway's key via `apiKeyHelper`, never your Max login.
  - Telemetry, error reports, `/feedback`, surveys and the WebFetch preflight are off.
  - WebSearch is denied, since it runs on Anthropic's servers.
  - It can't edit the repo tree.

Anthropic [doesn't support](https://code.claude.com/docs/en/llm-gateway) non-Claude models behind a gateway. It works, but tool use is slower and less reliable than with Claude, so the bake-off includes a Claude Code task (`bench\Run-CcnTask.ps1`).

**Watch for IDE AI features.** JetBrains AI Assistant, GitHub Copilot and a cloud `claude` connected to an IDE all see open files. Repos are fine, since they hold no NDA material by design. Never open `D:\nda` in an IDE with those on, and never add `D:\nda` as a Cowork folder.

## What the Ultra is built for, and what this build keeps

Microsoft and NVIDIA tuned this platform. The build uses that tuning rather than working around it:

| Platform feature | What this build does |
| --- | --- |
| **Unified memory split, set in the NVIDIA app.** 128 GB units ship 64/64, and reviews show up to 96 GB for the GPU. CUDA fills the dedicated segment first and only spills into shared memory (smaller pages, slower) when it's full. | Plan for **96 GB dedicated**: `sc-research` (65 GB) + the resident set + KV cache must fit there. Preflight and validation read the real split. At 96/32 Windows sees ~30 GB, so WSL is capped at 12 GB. With 64/64, run `sc-analyst` locally and `sc-research` on the Spark. |
| **Commit charge.** CUDA allocations count against Windows' commit limit (an NVIDIA forum report; NVIDIA hasn't confirmed it). | Stage 10 sets a fixed 80 GB page file on C:. It's reserved, not written in normal use. Validation measures the remaining commit headroom with `sc-research` loaded. |
| **Power modes.** "Best performance" on AC gives full inference throughput. On battery the GPU drops to a lower power state. | Stage 10 sets Best performance on AC. The bake-off runs on AC and on battery. |
| **Stability.** A review unit hard-powered-off under sustained all-core FP64 load (Kernel-Power 41). | Preflight and validation count unexpected power-offs. Keep Surface firmware current through Windows Update. |
| **Native ARM64 everywhere.** Prism emulates x64 user-mode apps well; kernel drivers must be ARM64. | Tools prefer ARM64 builds; stage 22 and validation report which binaries are emulated. |
| **Microsoft's dev baseline** (the Surface RTX Spark Dev Box ships VS Code, WSL 2 with CUDA, PowerShell 7). | All three are installed. VS Code is there, not central. |
| **NVIDIA's local-LLM path.** NVIDIA lists llama.cpp and Ollama builds for Windows on Arm; TensorRT for RTX is supported but isn't an LLM server. | Native llama.cpp (CUDA 13, ARM64) behind llama-swap; vLLM in WSL is optional. |
| **Agent containment: Microsoft Execution Containers (MXC, GA Oct 2026)**, with NVIDIA OpenShell coming on top of it. | **Tracked, not wired yet.** Microsoft lists Claude Code as "releasing support". When it ships, run `claude` and `ccn` in MXC process containers (read-write on the project folder only, loopback-only network for `ccn`). That replaces today's best-effort hooks with OS-enforced isolation. |
| **Recall / Copilot features** (if offered on this unit). | Left to you (`RecallPolicy = 'UserChoice'`). Recall is opt-in and keeps snapshots on the device, so it doesn't break the cloud rule. Set `'Disable'` to turn it off by policy. |

## Layout

```
Install-All.ps1              orchestrator (elevated); resumes after reboots: .\Install-All.ps1 -From 40
lib/SurfaceUltra.psm1        shared helpers (logging, winget, releases, llama-swap config, storage tiers, memory split)
config/machine.psd1          everything machine-specific - edit first (or override in machine.local.psd1)
config/models.psd1           local model catalog (research-first tiers)
config/*.template            .wslconfig and LiteLLM config templates
scripts/00..90-*.ps1         the stages (each runnable on its own)
wsl/                         Ubuntu bootstrap + compose (LiteLLM, NDA gateway, Qdrant x2, Open WebUI, vLLM)
spark/README.md              what lives on the DGX Spark and how to expose it (tokens, ACLs)
tools/ccn.ps1                Claude Code on local models (NDA research profile)
tools/nda_guard.py           NDA term scanner / redactor / restorer, Claude Code hook, git pre-commit hook
tools/claude_settings.py     writes both Claude Code profiles (cloud guardrails, ccn local profile)
tools/NdaSession.ps1         NDA workspace + session services: -Init / -Start / -Stop / -Status
tools/plan/                  research -> plan -> handoff pipeline (local models only)
tools/Test-DriverBuild.ps1   day-one: build an existing driver solution for x64 + ARM64 on this host
tools/Set-Secrets.ps1        day-one: paste keys from your password manager into env vars / D:\nda\secrets
tools/Move-ModelTier.ps1     models between hot SSD, NAS library and flash travel cache
tools/Sync-TravelCache.ps1   pre-trip: travel models + offline rebuild kit -> flash drive
tools/Sync-ResearchReplica.ps1  pre-trip: Spark Qdrant collections -> laptop replicas
tools/Set-ResearchMode.ps1   points ccn and other local clients at Spark MCP (online) or replicas (offline)
tools/zadig/                 WinUSB presets for Quarch Torridon on ARM64
tools/Test-Usb4Pcie.ps1      USB4-to-CEM adapter go/no-go
templates/py-react-app/      Python API + React UI that ships as one wheel (no Node on target machines)
bench/                       bake-off: grounded Q&A (cite + abstain), tool calls, spec Q&A, speed, ccn agentic task
drivers/, apps/              staged vendor drivers and installers (gitignored)
```

## How the NDA rule is enforced

Rules, not an encrypted vault. Device encryption is left as Windows sets it up; that's your call.

| Layer | What it does |
| --- | --- |
| **NDA workspace** (`D:\nda`, `tools\NdaSession.ps1`) | Vendor docs, term lists, research projects, replicas, NDA secrets and the `ccn` profile live here: outside every repo and outside every cloud Claude Code working directory. Nothing is ever copied from here into a project. |
| **NDA session services** | `NdaSession.ps1 -Start` brings up the NDA Qdrant (:6335) and the NDA gateway (:4001, no trace export, the Spark's no-content-logging key). Both stop with `-Stop`. |
| **`ccn` profile** (stage 70) | Local models only: a loopback gateway with its own key, nonessential traffic off, WebSearch denied, no edits in the repo tree, and NDA MCP servers registered only here. |
| **Term lists** (`D:\nda\terms\<vendor>.txt`) | `REAL => ALIAS` per line: codenames, part numbers, register/field/feature names. `NdaSession.ps1 -Start` builds a keyed-hash index in `~/.surface-ultra`, which is what the scanners use. |
| **Obfuscation** (`nda_guard.py redact` / `restore`) | `nda redact brief.md brief.cloud.md` before anything goes to Claude (the `nda` profile helper). Don't run `restore` into repo source: real values belong in the local-only data map. |
| **Cloud Claude Code scope** (stage 70) | `blockReadsOutsideWorkingDirectories` is on, plus `Read`/`Edit` deny rules on `//d/nda/**` and `~/.surface-ultra/**`. The rule text also goes into the user-level `CLAUDE.md`, so it applies to every project. |
| **Cloud Claude Code hooks** (stage 70) | Every prompt and every file, shell, web and MCP tool call is scanned. Hits are blocked (exit 2) with a message that names only an opaque id, never the term. Any call naming the NDA workspace or an NDA endpoint (:6335, :4001, the Spark NDA MCP) is blocked outright. |
| **Git pre-commit hook** (stage 80) | `nda_guard.py scan --staged` on every repo. |
| **MCP zoning** (`SparkMcp` in machine.psd1) | `nda` servers are never registered with cloud Claude Code or the Claude desktop app. Their tokens live in `D:\nda\secrets`. |
| **Windows** (stage 65) | OneDrive backup of Desktop/Documents and the dev and NDA roots flagged; Recall per `RecallPolicy`. |

The hooks are best effort. Claude Code has no OS sandbox on native Windows today, so a script Claude writes could in principle read files the rules don't cover. The real protections are the habits: keep cloud `claude` in a project folder, do NDA work in `ccn`, and only hand Claude the scanned pack. MXC containment, once Claude Code supports it, turns those habits into enforcement.

### Our own API, not the vendor's

A project that needs a vendor's NDA API file to run can't be released without the vendor's permission. New projects avoid that:

1. **Research** the vendor SDK locally (`ccn` + `tools\plan`).
2. **Design our API** in our vocabulary, from public-spec concepts (PCIe, NVMe-MI, MCTP, CXL).
3. Isolate everything vendor-specific in a **binding layer**. It sits behind an interface we define and refers to registers and parts by alias. At runtime it loads the real values from a **local-only data map**, which is never committed or sent to the cloud.
4. Claude builds the API, the UI and the binding layer against a **mock**. You run hardware tests locally.

For a UI, `templates\py-react-app` ships a React front end inside the Python wheel. The browser runs React, FastAPI serves the built files, and target machines need Python only.

Whether a given binding layer can ship depends on the NDA's terms, especially its "permitted purpose" and "residuals" clauses. Check with counsel before release; this repo isn't legal advice.

## Planning workflow (new API/UI project)

Run these in the red tab, or ask `ccn` to run them and summarize each step:

```powershell
tools\NdaSession.ps1 -Start                       # term index + NDA Qdrant + NDA gateway
tools\plan\New-ResearchProject.ps1 -Name acme-switch-api -Vendor acme -Public D:\specs\pcie6\*.pdf -VendorDocs D:\nda\docs\acme\sdk-4.2
cd D:\nda\projects\acme-switch-api; ccn          # write plan\00-brief.md together
tools\plan\plan.ps1 ingest   -Project acme-switch-api   # chunks tagged public / nda
tools\plan\plan.ps1 terms    -Project acme-switch-api   # -> D:\nda\terms\candidates\acme.txt (review, move lines to terms\acme.txt, -Start again)
tools\plan\plan.ps1 scope    -Project acme-switch-api   # answer the questions in plan\01-scope-questions.md
tools\plan\plan.ps1 draft    -Project acme-switch-api   # 12 sections, [S#] citations, provenance badges
tools\plan\plan.ps1 critique -Project acme-switch-api   # a second model checks each section against its sources
# add review comments as lines starting with ">>" in plan\sections\*.md (glow to read, hx to edit)
tools\plan\plan.ps1 revise   -Project acme-switch-api -Section 4,7
tools\plan\plan.ps1 handoff  -Project acme-switch-api   # local pack + obfuscated cloud pack; refuses on any leak
tools\plan\Export-Handoff.ps1 -Project acme-switch-api -Repo D:\dev\src\acme-switch-api
```

- `handoff\local\` holds the full plan and `BINDING-LAYER.md` (the real vendor operations, for building the data map). It never leaves the NDA workspace.
- `handoff\cloud\` holds `PLAN.md` and `CLAUDE.md` project rules. In this copy, terms are replaced by aliases, NDA citations become `[vendor ref]`, and the binding-layer section is cut down to its interface.
- `Export-Handoff.ps1` re-scans the pack and asks you to confirm you've read it. It then copies the pack to `<repo>\docs\plan\`, where `claude` picks it up.

The pipeline talks to llama-swap on loopback (`sc-research` drafts, `sc-analyst` critiques, plus `sc-embed` and `sc-rerank`). It never goes through the everyday gateway, so NDA prompts never reach its trace export. Each project's `project.json` can change the models, or point at the NDA gateway (:4001) for `spark/*`.

## Storage tiers

| Tier | Where | What | Speed |
| --- | --- | --- | --- |
| **Hot** | Internal Gen5 SSD (`D:` Dev Drive) | Repos, active models, WSL/containers, NDA workspace | The only tier anything runs from |
| **NAS library** | `\\home-nas\surface-ultra` (or `\\192.168.5.203\...`), LAN or Tailscale | `models\` (every pulled model), `archive\` | Promote on the LAN (1 GbE NAS: ~10 min for 65 GB); nothing runs from it |
| **Travel cache** | SanDisk Extreme Fit, volume label `SU-COLD`, folder `surface-ultra` | `TravelModels`, drivers, installers, offline rebuild kit. **No NDA material.** | Promote on the road; nothing runs from it |

- `51-PullModels.ps1` copies from the NAS library first and falls back to Hugging Face. After an HF download it seeds the library. `-Archive` downloads straight to the NAS; `-NoNas` skips it.
- `Move-ModelTier.ps1 -List | -Promote a,b | -Demote a,b [-To Nas|Cold] [-Keep]`. Promote and demote regenerate `llama-swap.yaml` and restart llama-swap.
- `Sync-TravelCache.ps1` runs before a trip. Label the stick once with `Set-Volume -DriveLetter E -NewFileSystemLabel SU-COLD`.

## The old x64 PC becomes the lab host

Keep it (`LabHostX64` in machine.psd1). It covers what an ARM64 machine can't:

- **x64 driver test target.** Load and test x64 drivers there; debug them from the Ultra with WinDbg over kdnet. Never test-load a kernel driver on the machine you work on.
- **x64 build fallback**, if `Test-DriverBuild.ps1` shows x64 kernel-mode builds don't work from the ARM64 host.
- **Veeam file-level restores** (next section).

## Backups (Veeam)

Backups run off-box: Veeam Agent for Windows over the site-to-site VPN to the office, then to encrypted/immutable storage.

- **There is no native ARM64 Veeam agent.** The x64 agent runs under emulation, and backups work. File-level and volume restores fail on the laptop ("Failed to check FLR driver"), because x64 kernel drivers never load on ARM64. The question is open with the Veeam rep.
- **Restore path until then:**
  - *Individual files:* restore them on an **x64 Windows host** (the lab host, or the office Veeam B&R console), then copy them back over SMB or the NAS.
  - *Rebuild:* rebuild the laptop from these scripts, then restore the data folders the same way.
- **Exclude what's rebuildable:**
  - `D:\models` (it's on the NAS library)
  - `D:\dev\cache`, `%LOCALAPPDATA%\uv`, Hugging Face caches
  - the WSL `ext4.vhdx` (containers and Qdrant replicas rebuild from the scripts and the Spark)
  - `C:\pagefile.sys`
- **NDA workspace:** include `D:\nda` only if your NDAs allow company backups. Most permit them under equivalent protection, which an encrypted, immutable repository provides. Check the terms.
- A restic fallback to the NAS is drafted in the plan, but not built until Veeam answers.

## Before the laptop arrives

1. Fill in `config/machine.psd1`:
   - repo URLs, persona folder and Claude-safe MCP servers
   - `SparkMcp` URLs, ports and zones, `ReplicaCollections` and `ReplicaMcp`
   - `NasRoots`, `TravelModels`, `LabHostX64`
2. On the Spark, work through the Spark overhaul plan (tokens, ACLs, the `ultra-nda` LiteLLM key).
3. Keep the Spark keys in your password manager. On day one, `tools\Set-Secrets.ps1` takes each one by hidden prompt and writes it where the build reads it. Everyday keys go to user env vars; the NDA-zone ones go to `D:\nda\secrets`.
4. Stage drivers (`drivers/README.md`) and installers (`apps/`).
5. Draft your per-vendor term lists.
6. Create `surface-ultra\models` and `surface-ultra\archive` shares on the NAS.

## Day one (in order)

1. Windows OOBE, then Windows Update, including Surface firmware. Install the **R616+ NVIDIA driver** if Windows Update didn't. Decide on device encryption; the scripts only report it.
2. **NVIDIA app: set the memory split to the largest GPU share** (the plan assumes 96 GB). Run `.\scripts\00-Preflight.ps1` to confirm what Windows sees.
3. **Create a Dev Drive.** Go to Settings > System > Storage > Advanced storage settings > Disks & volumes > Create dev drive. Use 400-500 GB ReFS as `D:`.
4. Copy this folder to `D:\dev\src\surface-ultra` (not the Desktop, which OneDrive may back up). In an **elevated Windows PowerShell**, run:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   Get-ChildItem -Recurse | Unblock-File
   .\Install-All.ps1
   ```
   - Stage 10 sets the page file; it takes effect at the reboot stage 40 asks for.
   - Stage 40 stops twice (a reboot, then Linux user creation). Each time, resume with `-From 40`.
   - Sign in to Tailscale after stage 10. Log in to `claude` with your Max account after stage 70. `ccn` needs no login.
   - With the NAS reachable, stage 51 pulls from the library instead of Hugging Face.
5. Put your term lists in `D:\nda\terms\`. Run `tools\Set-Secrets.ps1` and paste the keys from your password manager. Then run `tools\NdaSession.ps1 -Start` and `tools\Set-ResearchMode.ps1`. `Set-Secrets.ps1 -List` shows what's set, plus the keys the build generated, which you should copy into the password manager.
6. Run the go/no-go checks:
   ```powershell
   .\scripts\90-Validate.ps1
   .\tools\Test-Usb4Pcie.ps1 -TestDrive E
   .\scripts\30-HilDrivers.ps1 -InventoryOnly                          # with your gear plugged in
   .\tools\Test-DriverBuild.ps1 -Solution D:\dev\src\<driver>\<x>.sln   # x64 + ARM64 from this host
   ```
7. Run the bake-off on AC and on battery, with NDA-grounded tasks kept in the NDA workspace:
   ```powershell
   .\tools\Move-ModelTier.ps1 -Promote sc-research-alt
   .\bench\Run-Bakeoff.ps1 -ExtraTasks D:\nda\research\bench-tasks.jsonl
   .\bench\Run-CcnTask.ps1 -Models sc-research,sc-analyst,spark/research   # how well each drives Claude Code
   ```
8. Open the red **NDA | LOCAL** tab in Windows Terminal and try `ccn`.

## Daily use

| Need | Use |
| --- | --- |
| NDA research | `tools\NdaSession.ps1 -Start`, then the red **NDA \| LOCAL** tab (or `ccn` from `D:\nda\projects\<name>`). Finish with `NdaSession.ps1 -Stop`. |
| Plan a new project | `tools\plan\` (above, from `ccn`), then `Export-Handoff.ps1` into the repo |
| Hand other work to Claude | Write it locally, `nda redact brief.md brief.cloud.md`, review, give `brief.cloud.md` to `claude` |
| Coding and testing | `claude` (Max plan) from the project folder. Open PyCharm/CLion and `/ide` when you want a debugger view. |
| Drivers | Visual Studio / `msbuild` here; test x64 drivers on the lab host with WinDbg over kdnet |
| A Python tool with a real UI | Copy `templates\py-react-app`, then `just setup`, `just dev`, `just wheel` |
| Before a trip | `tools\Sync-ResearchReplica.ps1` (NDA session running), `tools\Sync-TravelCache.ps1`. On the road: `Set-ResearchMode.ps1 -Mode Offline` (ccn then uses the replicas and `sc-research`). |
| Free SSD space | `tools\Move-ModelTier.ps1 -Demote <alias>` |
| Any OpenAI-compatible client | LiteLLM at http://127.0.0.1:4000/v1: `sc-research`, `sc-analyst`, `sc-fast`, `sc-embed`, `spark/<model>` |
| What's loaded / free the GPU | `llm-status`, `llm-unload` |
| Roll back llama.cpp | `.\scripts\50-LocalLlm.ps1 -Rollback` |

## Rules that matter on this machine

- **x64 kernel drivers never load on ARM64.** WinUSB devices (like the Quarch Torridon) can be re-bound with Zadig. Everything else needs a vendor ARM64 build or the lab host. The same rule is behind the Veeam restore gap.
- **The model budget is the dedicated split.** `sc-research` (65 GB) and `sc-analyst` (22 GB) swap with each other rather than co-residing; at 96/32 keep WSL at 12 GB.
- **Nothing runs from the NAS or the flash drive.** Promote to the SSD first.
- **NordVPN and Tailscale** shouldn't run at the same time.

## Status

Written before the hardware shipped (Oct 2026). The PowerShell was syntax-checked with a parser; there was no Windows host to run it on. These were tested in Linux:
- `nda_guard`, both settings profiles, the planning pipeline (against a mock model server), the `ccn` bake-off grader and the Python + React template (built, packaged and served).

The NAS paths, the memory-split and page-file behaviour, and `ccn` against a real local model haven't been exercised yet. Nothing has run on an RTX Spark yet, so expect day-one fixes.
