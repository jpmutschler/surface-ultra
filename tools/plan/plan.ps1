#Requires -Version 5.1
<#
.SYNOPSIS
    Runs one plan_agent step on a research project (local models only).
.DESCRIPTION
    Steps, in order (re-run any of them whenever you like):
      ingest    parse + embed sources/public and sources/vendor (provenance recorded per chunk)
      terms     suggest protected terms from vendor sources -> <NDA root>\terms\candidates\<vendor>.txt
      scope     scoping questions from your brief -> plan\01-scope-questions.md (answer them)
      draft     write every section with [S#] citations (-Section 4 to redo one)
      critique  second model checks each section against its sources -> plan\review.md
      revise    apply your ">>" comments in the section files + critic findings (-Section ...)
      handoff   build handoff\local (full plan + binding layer) and handoff\cloud (obfuscated, scanned)
      status    what exists so far
    Then: Export-Handoff.ps1 copies the reviewed cloud pack into the code repo for Claude Code.
.EXAMPLE
    .\plan.ps1 draft -Project acme-switch-api
    .\plan.ps1 revise -Project acme-switch-api -Section 4,7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('ingest', 'terms', 'scope', 'draft', 'critique', 'revise', 'handoff', 'status')][string]$Step,
    [Parameter(Mandatory)][string]$Project,
    [int[]]$Section
)
Import-Module (Join-Path $PSScriptRoot '..\..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$root = if (Test-Path (Join-Path $Project 'project.json')) { (Resolve-Path $Project).Path } else { Join-Path $cfg.NdaRoot "projects\$Project" }
if (-not (Test-Path (Join-Path $root 'project.json'))) { Write-Step "No project at $root - run New-ResearchProject.ps1" -Level Fail; exit 1 }
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Write-Step 'uv not found - run stage 20' -Level Fail; exit 1 }

$env:NDA_TERMS_DIR = $cfg.NdaTermsDir
$installed = Join-Path $cfg.SuHome 'tools\nda_guard.py'
$env:NDA_GUARD = $(if (Test-Path $installed) { $installed } else { Join-Path $PSScriptRoot '..\nda_guard.py' })
$env:PYTHONUTF8 = '1'

$agent = Join-Path $PSScriptRoot 'plan_agent.py'
$pyArgs = @('run', '--no-project', '--python', '3.12', '--with', 'pypdf', '--with', 'numpy', 'python', '-I', $agent, $Step, '--project', $root)
foreach ($s in @($Section)) { if ($s) { $pyArgs += @('--section', "$s") } }
& uv @pyArgs
exit $LASTEXITCODE
