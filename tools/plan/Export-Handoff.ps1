#Requires -Version 5.1
<#
.SYNOPSIS
    The only door from a research project to a code repo: copies the reviewed, obfuscated cloud
    pack into <Repo>\docs\plan so Claude Code can build from it.
.DESCRIPTION
    Refuses unless:
      - handoff\cloud exists and handoff\manifest.json says the scan was clean
      - a fresh nda_guard scan of the pack is clean right now (catches edits made after 'plan handoff')
      - the repo is outside the NDA workspace
      - you type the project name to confirm you have read handoff\cloud\PLAN.md yourself
    Copies PLAN.md -> <Repo>\docs\plan\PLAN.md and the project rules -> <Repo>\CLAUDE.md (or, if the repo
    already has one, <Repo>\docs\plan\CLAUDE-rules.md for you to merge). handoff\local never leaves.
.EXAMPLE
    .\Export-Handoff.ps1 -Project acme-switch-api -Repo D:\src\acme-switch-api
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$Repo
)
Import-Module (Join-Path $PSScriptRoot '..\..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$root = Join-Path $cfg.NdaRoot "projects\$Project"
$cloud = Join-Path $root 'handoff\cloud'
$manifest = Join-Path $root 'handoff\manifest.json'
if (-not (Test-Path (Join-Path $cloud 'PLAN.md')) -or -not (Test-Path $manifest)) {
    Write-Step "No cloud pack - run: tools\plan\plan.ps1 handoff -Project $Project" -Level Fail; exit 1
}
if ((Get-Content $manifest -Raw | ConvertFrom-Json).scan -ne 'clean') { Write-Step 'Manifest scan is not clean' -Level Fail; exit 1 }

$repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
$ndaFull = [IO.Path]::GetFullPath($cfg.NdaRoot).TrimEnd('\')
if ($repoFull -eq $ndaFull -or $repoFull.StartsWith("$ndaFull\", [StringComparison]::OrdinalIgnoreCase)) {
    Write-Step 'Repo is inside the NDA workspace - pick a normal repo path' -Level Fail; exit 1
}
if (-not (Test-Path $repoFull)) { Write-Step "Repo $repoFull not found" -Level Fail; exit 1 }

# Fresh scan - the pack may have been edited since 'plan handoff'
$py = Get-SuPython
$guard = Join-Path $cfg.SuHome 'tools\nda_guard.py'
if (-not $py -or -not (Test-Path $guard)) { Write-Step 'nda_guard not installed - run stage 65' -Level Fail; exit 1 }
$env:NDA_TERMS_DIR = $cfg.NdaTermsDir
& $py -I $guard scan $cloud
if ($LASTEXITCODE -ne 0) { Write-Step 'Scan found protected terms (or no index) - fix the pack, re-run plan handoff' -Level Fail; exit 1 }
Write-Step 'Fresh scan: clean' -Level Ok

$plan = Join-Path $cloud 'PLAN.md'
$lines = (Get-Content $plan).Count
Write-Step "Pack: $plan ($lines lines). handoff\local stays here."
$answer = Read-Host "Have you read it yourself? Type the project name ($Project) to export"
if ($answer -ne $Project) { Write-Step 'Not exported' -Level Skip; exit 1 }

$dest = Join-Path $repoFull 'docs\plan'
if ($PSCmdlet.ShouldProcess($dest, 'copy cloud pack')) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $plan (Join-Path $dest 'PLAN.md') -Force
    $rules = Join-Path $cloud 'CLAUDE.md'
    if (Test-Path (Join-Path $repoFull 'CLAUDE.md')) {
        Copy-Item $rules (Join-Path $dest 'CLAUDE-rules.md') -Force
        Write-Step 'Repo already has CLAUDE.md - merge docs\plan\CLAUDE-rules.md into it' -Level Info
    } else { Copy-Item $rules (Join-Path $repoFull 'CLAUDE.md') -Force }
    Add-Content -Path (Join-Path $root 'handoff\exports.log') -Value ("{0}  {1}  {2}" -f (Get-Date -Format s), $repoFull, (Get-FileHash $plan).Hash.Substring(0, 16))
    Write-Step "Exported to $dest. Open the repo in Claude Code and start from docs\plan\PLAN.md." -Level Ok
}
exit 0
