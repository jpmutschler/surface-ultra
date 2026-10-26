#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the local-model bake-off through llama-swap and prints the summary table.
.DESCRIPTION
    Pulls nothing - run 51-PullModels.ps1 -Alias ... first for the candidates you want.
    Run twice: once on AC, once on battery (the harness records which).
.EXAMPLE
    .\Run-Bakeoff.ps1                                         # sc-research vs sc-research-alt vs sc-analyst
    .\Run-Bakeoff.ps1 -ExtraTasks D:\nda\research\bench-tasks.jsonl   # add NDA-grounded tasks (kept in the NDA workspace)
    .\Run-Bakeoff.ps1 -Models sc-research -Ctx 512,32768,131072        # long-context prefill on the real unit
    .\Run-Bakeoff.ps1 -Base http://127.0.0.1:8000/v1 -Models vllm-coder   # vLLM profile in WSL
#>
[CmdletBinding()]
param(
    [string[]]$Models = @('sc-research', 'sc-research-alt', 'sc-analyst'),
    [string[]]$ExtraTasks = @(),
    [string]$Base,
    [int[]]$Ctx = @(512, 8192, 32768),
    [switch]$SpeedOnly
)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
if (-not $Base) { $Base = "http://$($cfg.LlamaSwapListen)/v1" }
$py = @('run', '--no-project', '--python', '3.12', 'python', (Join-Path $PSScriptRoot 'bench_llm.py'),
        '--base', $Base, '--models', ($Models -join ','), '--ctx', ($Ctx -join ','))
$py += @('--tasks', (Join-Path $PSScriptRoot 'tasks.jsonl'))
foreach ($t in $ExtraTasks) { $py += @('--tasks', $t) }
if ($SpeedOnly) { $py += '--speed-only' }
& uv @py
# Unload afterwards so the resident set gets its memory back
try { Invoke-RestMethod "http://$($cfg.LlamaSwapListen)/unload" -TimeoutSec 30 | Out-Null } catch { }
