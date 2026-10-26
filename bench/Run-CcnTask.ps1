#Requires -Version 5.1
<#
.SYNOPSIS
    Bake-off leg for ccn: each model drives Claude Code through a small research task.
.DESCRIPTION
    For each model: a fresh fixture project under D:\nda\projects\_bench-ccn\<model> holding the
    FICTIONAL ORCA-7 excerpt and a TASK.md; ccn runs headless there (claude -p) on that model; the
    answers file is graded for grounded answers with page citations and correct abstentions. Turns and
    wall time come from Claude Code's JSON output. Results append to bench\results\ccn_results.jsonl.

    Needs the NDA session up (tools\NdaSession.ps1 -Start) - ccn only talks to the NDA gateway.
.EXAMPLE
    .\Run-CcnTask.ps1                                   # sc-research, sc-analyst
    .\Run-CcnTask.ps1 -Models spark/research,sc-research
#>
[CmdletBinding()]
param([string[]]$Models = @('sc-research', 'sc-analyst'), [int]$MaxTurns = 25)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$ccn = Join-Path $PSScriptRoot '..\tools\ccn.ps1'
$helper = Join-Path $PSScriptRoot 'ccn_task.py'
$root = Join-Path $cfg.NdaRoot 'projects\_bench-ccn'

foreach ($m in $Models) {
    $dir = Join-Path $root ($m -replace '[\\/:]', '_')
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $prompt = (& uv run --no-project --python 3.12 python $helper prepare $dir | Select-Object -Last 1)
    Write-Step "ccn on $m ..."
    Push-Location $dir
    try {
        $out = & $ccn -Model $m -p $prompt --output-format json --permission-mode acceptEdits --max-turns $MaxTurns 2>$null
        $resultFile = Join-Path $dir 'result.json'
        Set-Content -Path $resultFile -Value ($out | Out-String) -Encoding UTF8
    } finally { Pop-Location }
    & uv run --no-project --python 3.12 python $helper grade $dir $resultFile $m
}
Write-Step "Results: $(Join-Path $PSScriptRoot 'results\ccn_results.jsonl')" -Level Ok
