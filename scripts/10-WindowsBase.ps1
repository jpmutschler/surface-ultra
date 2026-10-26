#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 10 - Windows base configuration and core apps.
.DESCRIPTION
    Developer Mode, long paths, Explorer tweaks, fixed page file (commit headroom for CUDA),
    cache env vars on the Dev Drive, Defender exclusion for the model store, and core arm64 apps.
    Leaves device encryption (BitLocker) exactly as Windows set it up - that's your call.
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '10-WindowsBase'
Assert-Admin
$cfg = Get-MachineConfig

# ---------------------------------------------------------------- OS settings
$dev = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
if (-not (Test-Path $dev)) { New-Item -Path $dev -Force | Out-Null }
Set-ItemProperty -Path $dev -Name AllowDevelopmentWithoutDevLicense -Type DWord -Value 1
Write-Step 'Developer Mode on' -Level Ok

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Type DWord -Value 1
Write-Step 'Win32 long paths on' -Level Ok

$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $adv -Name HideFileExt -Type DWord -Value 0
Set-ItemProperty -Path $adv -Name Hidden -Type DWord -Value 1
Write-Step 'Explorer: show extensions + hidden files' -Level Ok

# Best-performance power mode on AC (overlay GUID documented by powercfg /overlay*). Best effort.
& powercfg /overlaysetactive ded574b5-45a0-4f42-8737-46345c09c238 2>$null
if ($LASTEXITCODE -eq 0) { Write-Step 'Power mode: Best performance' -Level Ok }
else { Write-Step 'Could not set power mode overlay - set "Best performance" in Settings > System > Power' -Level Warn }

# ---------------------------------------------------------------- page file (commit headroom for CUDA)
# CUDA allocations count against Windows' commit limit, and with 96 GB dedicated to the GPU Windows
# sees ~30 GB of RAM. A fixed page file raises the limit so ~85 GB of model weights can load.
$rebootNeeded = $false
if ($cfg.PageFileGB -gt 0) {
    $mb = [uint32]($cfg.PageFileGB * 1024)
    $freeC = [math]::Round((Get-PSDrive C).Free / 1GB)
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'C:*' } | Select-Object -First 1
    if ($pf -and $pf.InitialSize -eq $mb -and $pf.MaximumSize -eq $mb) {
        Write-Step "Page file already fixed at $($cfg.PageFileGB) GB on C:" -Level Skip
    } elseif ($freeC -lt ($cfg.PageFileGB + 40)) {
        Write-Step "Only $freeC GB free on C: - page file left as is (needs $($cfg.PageFileGB) GB + 40 GB margin)" -Level Warn
    } elseif ($PSCmdlet.ShouldProcess('C:\pagefile.sys', "fixed $($cfg.PageFileGB) GB")) {
        $csys = Get-CimInstance Win32_ComputerSystem
        if ($csys.AutomaticManagedPagefile) { Set-CimInstance -InputObject $csys -Property @{ AutomaticManagedPagefile = $false } }
        if ($pf) { Set-CimInstance -InputObject $pf -Property @{ InitialSize = $mb; MaximumSize = $mb } }
        else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys'; InitialSize = $mb; MaximumSize = $mb } | Out-Null }
        Write-Step "Page file fixed at $($cfg.PageFileGB) GB on C: (takes effect after a reboot)" -Level Ok
        $rebootNeeded = $true
    }
} else { Write-Step 'PageFileGB = 0 - page file left Windows-managed' -Level Skip }

# ---------------------------------------------------------------- folders + cache env vars
foreach ($p in @($cfg.DevRoot, $cfg.ModelRoot, $cfg.ToolsRoot, (Join-Path $cfg.DevRoot 'src'), (Join-Path $cfg.DevRoot 'cache'))) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null; Write-Step "Created $p" -Level Ok }
}
$cache = Join-Path $cfg.DevRoot 'cache'
Set-UserEnv -Name 'UV_CACHE_DIR' -Value (Join-Path $cache 'uv')
Set-UserEnv -Name 'PIP_CACHE_DIR' -Value (Join-Path $cache 'pip')
Set-UserEnv -Name 'npm_config_cache' -Value (Join-Path $cache 'npm')
Set-UserEnv -Name 'HF_HOME' -Value (Join-Path $cache 'huggingface')
Set-UserEnv -Name 'SURFACE_ULTRA_MODELS' -Value $cfg.ModelRoot
Set-UserEnv -Name 'SURFACE_ULTRA_TOOLS' -Value $cfg.ToolsRoot

if (-not $cfg.DevDrivePresent) {
    Write-Step "No Dev Drive at $($cfg.DevDriveLetter): - using C:\. Re-run this stage after creating it to move roots." -Level Warn
} else {
    # Dev Drive trust + Defender performance mode for the dev volume
    & fsutil devdrv trust "$($cfg.DevDriveLetter):" 2>$null | Out-Null
    Write-Step "Dev Drive $($cfg.DevDriveLetter): trusted (Defender scans it in performance mode)" -Level Ok
}

# Model files are multi-GB data blobs; real-time scanning them on every load costs minutes.
try {
    Add-MpPreference -ExclusionPath $cfg.ModelRoot -ErrorAction Stop
    Write-Step "Defender exclusion: $($cfg.ModelRoot)" -Level Ok
} catch { Write-Step "Defender exclusion failed: $($_.Exception.Message)" -Level Warn }

# ---------------------------------------------------------------- core apps (arm64 builds)
$core = @(
    @{ Id = 'Microsoft.PowerShell' }
    @{ Id = 'Microsoft.WindowsTerminal' }
    @{ Id = 'Git.Git' }
    @{ Id = 'GitHub.cli' }
    @{ Id = 'Microsoft.VisualStudioCode' }    # part of Microsoft's RTX Spark dev baseline; not central to a terminal-first workflow
    @{ Id = '7zip.7zip' }
    @{ Id = 'tailscale.tailscale' }
    @{ Id = 'dorssel.usbipd-win' }
    @{ Id = 'WiresharkFoundation.Wireshark'; AllowEmulated = $true }
)
& winget source update --disable-interactivity | Out-Null
$failed = @()
foreach ($pkg in $core) {
    $ok = Install-WingetPackage -Id $pkg.Id -AllowEmulated:([bool]$pkg.AllowEmulated) -WhatIfOnly:$WhatIfPreference
    if (-not $ok) { $failed += $pkg.Id }
}
Update-SessionPath

Write-Step 'Next: sign in to Tailscale (tray icon) so the Spark resolves as' -Level Info
Write-Step "      '$($cfg.SparkHost)', then run stage 20." -Level Info
Write-Step 'NVIDIA app: set the memory split to the largest GPU share (plan: 96 GB) before stage 50.' -Level Info
if ($failed.Count) { Write-Step "Failed: $($failed -join ', ')" -Level Fail; exit 1 }
if ($rebootNeeded) { Write-Step 'The new page file takes effect at the next reboot (stage 40 asks for one before any model loads).' -Level Info }
Write-Step 'Stage 10 complete' -Level Ok
exit 0
