#Requires -Version 5.1
<#
.SYNOPSIS
    Launches llama-swap with the generated config; used by the SurfaceUltra-llama-swap logon task.
    Output goes to logs\llama-swap-<date>.log. Run it by hand to debug in the foreground.
#>
[CmdletBinding()] param([switch]$Foreground)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$exe = Join-Path $cfg.ToolsRoot 'llama-swap\llama-swap.exe'
$yaml = Join-Path $cfg.ToolsRoot 'llama-swap\llama-swap.yaml'
if (-not (Test-Path $exe) -or -not (Test-Path $yaml)) { throw "llama-swap or its config missing under $($cfg.ToolsRoot)\llama-swap - run stage 50/51" }
$argList = @('-config', $yaml, '-listen', $cfg.LlamaSwapListen)
if ($Foreground) { & $exe @argList; return }
$logDir = Join-Path (Get-RepoRoot) 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir ("llama-swap-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$err = "$log.err"
$p = Start-Process -FilePath $exe -ArgumentList $argList -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Hidden -PassThru
$p.WaitForExit()
exit $p.ExitCode
