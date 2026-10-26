#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 50 - native Windows-on-Arm GPU inference: llama.cpp (CUDA 13.x arm64) + llama-swap.
.DESCRIPTION
    Downloads the newest (or pinned) llama.cpp release that ships a win-cuda-13.x-arm64
    build plus its cudart package into <ToolsRoot>\llama.cpp\<tag>, points a 'current'
    junction at it (old builds stay for rollback), installs llama-swap, and registers a
    logon task that serves all local models on 127.0.0.1:8080.
.PARAMETER Rollback
    Point 'current' at the previous llama.cpp build instead of downloading.
#>
[CmdletBinding(SupportsShouldProcess)] param([switch]$Rollback)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '50-LocalLlm'
$cfg = Get-MachineConfig
$llamaRoot = Join-Path $cfg.ToolsRoot 'llama.cpp'
$current = Join-Path $llamaRoot 'current'
New-Item -ItemType Directory -Path $llamaRoot -Force | Out-Null

function Set-CurrentBuild([string]$Target) {
    if (Test-Path $current) { (Get-Item $current).Delete() }   # removes the junction only
    New-Item -ItemType Junction -Path $current -Target $Target | Out-Null
    Write-Step "llama.cpp current -> $Target" -Level Ok
}

# ---------------------------------------------------------------- llama.cpp
if ($Rollback) {
    $builds = @(Get-ChildItem $llamaRoot -Directory | Where-Object Name -ne 'current' | Sort-Object Name -Descending)
    if ($builds.Count -lt 2) { Write-Step 'No previous build to roll back to' -Level Fail; exit 1 }
    Set-CurrentBuild $builds[1].FullName
} else {
    $rel = Get-GitHubReleaseAsset -Repo 'ggml-org/llama.cpp' -Pattern $cfg.LlamaCppAssetRegex -Tag $cfg.LlamaCppTag -IncludePrerelease
    if (-not $rel) { Write-Step "No llama.cpp release with an asset matching '$($cfg.LlamaCppAssetRegex)'" -Level Fail; exit 1 }
    $dest = Join-Path $llamaRoot $rel.Tag
    if (Test-Path (Join-Path $dest 'llama-server.exe')) {
        Write-Step "llama.cpp $($rel.Tag) already present" -Level Skip
    } else {
        $tmp = Join-Path $env:TEMP "su-llama-$($rel.Tag)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp $rel.Name
        Invoke-Download -Url $rel.Url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        # cudart package: published once per CUDA version (not per build tag); search the same release
        $cud = Get-GitHubReleaseAsset -Repo 'ggml-org/llama.cpp' -Pattern $cfg.CudartAssetRegex -Tag $rel.Tag -IncludePrerelease
        if ($cud) {
            $cz = Join-Path $tmp $cud.Name
            Invoke-Download -Url $cud.Url -OutFile $cz
            Expand-Archive -Path $cz -DestinationPath $dest -Force
        } else { Write-Step 'No cudart arm64 package found - llama-server will need CUDA DLLs on PATH (install the toolkit)' -Level Warn }
        # Zips sometimes nest a folder; flatten so llama-server.exe sits at the top
        $exe = Get-ChildItem $dest -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
        if ($exe -and $exe.DirectoryName -ne $dest) {
            Get-ChildItem $exe.DirectoryName | Move-Item -Destination $dest -Force
        }
        Remove-Item $tmp -Recurse -Force
        Write-Step "llama.cpp $($rel.Tag) installed to $dest" -Level Ok
    }
    Set-CurrentBuild $dest
}

# Sanity: the binary must be ARM64 and see the GPU
$server = Join-Path $current 'llama-server.exe'
$bytes = [IO.File]::ReadAllBytes($server)
$peOff = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $peOff + 4)
if ($machine -eq 0xAA64) { Write-Step 'llama-server.exe is native ARM64' -Level Ok }
else { Write-Step ('llama-server.exe machine type 0x{0:X4} - not ARM64!' -f $machine) -Level Fail }
$devs = & $server --list-devices 2>&1 | Out-String
Write-Step "llama-server --list-devices:`n$devs"
if ($devs -notmatch 'CUDA') { Write-Step 'No CUDA device visible to llama.cpp - check the R616+ driver' -Level Fail }

# ---------------------------------------------------------------- llama-swap
$swapDir = Join-Path $cfg.ToolsRoot 'llama-swap'
New-Item -ItemType Directory -Path $swapDir -Force | Out-Null
$swapExe = Join-Path $swapDir 'llama-swap.exe'
if (-not (Test-Path $swapExe)) {
    $sw = Get-GitHubReleaseAsset -Repo 'mostlygeek/llama-swap' -Pattern $cfg.LlamaSwapAssetRegex -Tag $cfg.LlamaSwapTag
    if ($sw) {
        $tmp = Join-Path $env:TEMP 'su-llama-swap'
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $arc = Join-Path $tmp $sw.Name
        Invoke-Download -Url $sw.Url -OutFile $arc
        if ($arc -match '\.zip$') { Expand-Archive -Path $arc -DestinationPath $tmp -Force }
        else { & tar.exe -xf $arc -C $tmp }
        $found = Get-ChildItem $tmp -Recurse -Filter 'llama-swap*.exe' | Select-Object -First 1
        if ($found) { Copy-Item $found.FullName $swapExe -Force; Write-Step "llama-swap $($sw.Tag) installed" -Level Ok }
        Remove-Item $tmp -Recurse -Force
    }
    if (-not (Test-Path $swapExe)) {
        Write-Step 'No windows_arm64 llama-swap release asset; building from source with Go' -Level Warn
        Update-SessionPath
        if (Get-Command go -ErrorAction SilentlyContinue) {
            $env:GOBIN = $swapDir
            & go install github.com/mostlygeek/llama-swap@latest
            if (Test-Path $swapExe) { Write-Step 'llama-swap built with go install' -Level Ok }
        }
        if (-not (Test-Path $swapExe)) { Write-Step 'llama-swap not installed - build it manually (see README)' -Level Fail; exit 1 }
    }
} else { Write-Step 'llama-swap present' -Level Skip }

# ---------------------------------------------------------------- config + logon task
$swapCfg = New-LlamaSwapConfig -Cfg $cfg
$launcher = Join-Path (Get-RepoRoot) 'tools\Start-LlamaSwap.ps1'
$taskName = 'SurfaceUltra-llama-swap'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Get-Process -Name 'llama-swap', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-ScheduledTask -TaskName $taskName
Write-Step "Logon task '$taskName' -> http://$($cfg.LlamaSwapListen) (config $swapCfg)" -Level Ok

# ---------------------------------------------------------------- optional Ollama
if ($cfg.InstallOllama) {
    [void](Install-WingetPackage -Id 'Ollama.Ollama' -WhatIfOnly:$WhatIfPreference)
    Set-UserEnv -Name 'OLLAMA_KEEP_ALIVE' -Value '2m'
    Set-UserEnv -Name 'OLLAMA_MAX_LOADED_MODELS' -Value '1'
    Write-Step 'Ollama shares the GPU budget with llama-swap - keep one of them idle' -Level Warn
}
Write-Step 'Stage 50 complete. Next: stage 51 to download models.' -Level Ok
exit 0
