#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates the Surface Laptop Ultra build, stage by stage.
.DESCRIPTION
    Stages are idempotent - re-running skips what's already done. Stages that need a
    reboot (WSL enablement) or an interactive step (WSL user creation) stop with a
    message; run Install-All again afterwards and it resumes.

      00 Preflight      read-only inventory, GPU/Windows memory split, commit, power-off history
      10 WindowsBase    dev mode, long paths, page file, Dev Drive, Defender exclusion, core apps
      20 DevToolchain   uv/Python arm64, Node, Rust, Go, just, Visual Studio + SDK + WDK, (CUDA), git
      22 DevApps        terminal tools (Helix, rg, bat, delta, glow, fzf); JetBrains Toolbox, WinDbg
      25 StagedApps     installs what you staged in .\apps (msix/msi/zip; asks before .exe)
      30 HilDrivers     ARM64 INFs from .\drivers (zips unpacked), COM/USB inventory
      40 Wsl            Ubuntu 24.04 arm64, Docker CE, NVIDIA container toolkit
      50 LocalLlm       llama.cpp win-cuda-arm64 + llama-swap logon task
      51 PullModels     always-on model set + llama-swap.yaml
      60 Services       LiteLLM, Qdrant, Open WebUI in WSL (+ NDA-session Qdrant profile)
      65 Privacy        NDA workspace, guard index + path list, Recall policy, OneDrive checks
      70 ClaudeCode     Claude Code: cloud profile + NDA guardrails, ccn local profile, red Terminal tab, MCP
      80 Workspace      clone + uv sync Serial Cables repos, nda_guard pre-commit hooks
      90 Validate       go/no-go checks
.PARAMETER Only
    Run just these stage numbers, e.g. -Only 50,51
.PARAMETER From
    Start at this stage number.
.EXAMPLE
    # elevated Windows PowerShell, from the repo root:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\Install-All.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param([string[]]$Only, [string]$From = '00')

Import-Module (Join-Path $PSScriptRoot 'lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage 'Install-All'
Assert-Admin

$stages = Get-ChildItem (Join-Path $PSScriptRoot 'scripts') -Filter '*.ps1' | Sort-Object Name
foreach ($s in $stages) {
    $num = $s.Name.Substring(0, 2)
    if ($Only -and ($Only -notcontains $num)) { continue }
    if (-not $Only -and ([int]$num -lt [int]$From)) { continue }
    Write-Step "---- $($s.BaseName) ----" -Level Head
    $global:LASTEXITCODE = 0
    & $s.FullName -WhatIf:$WhatIfPreference
    $rc = $LASTEXITCODE
    if ($rc -eq 3010) {
        Write-Step "$($s.BaseName) needs a reboot or an interactive step. Then: .\Install-All.ps1 -From $num" -Level Warn
        exit 3010
    }
    if ($rc -ne 0 -and $null -ne $rc) {
        Set-StageState -Stage $s.BaseName -Status "failed:$rc"
        Write-Step "$($s.BaseName) failed (exit $rc). Fix and resume: .\Install-All.ps1 -From $num" -Level Fail
        exit $rc
    }
    Set-StageState -Stage $s.BaseName -Status 'done'
    $global:LASTEXITCODE = 0
}
Write-Step 'All requested stages complete.' -Level Ok
