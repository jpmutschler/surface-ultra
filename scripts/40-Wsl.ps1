#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 40 - WSL2 with Ubuntu 24.04 arm64, Docker CE and the NVIDIA container toolkit.
.DESCRIPTION
    Run 1: enables WSL (reboot required).
    Run 2: installs the distro - a window opens for you to create your Linux user; close it and re-run.
    Run 3: writes %USERPROFILE%\.wslconfig, runs wsl\bootstrap.sh as root, restarts WSL,
           re-runs the bootstrap so the systemd/docker part completes, and registers a
           logon task that keeps the WSL VM up for the service stack.
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '40-Wsl'
Assert-Admin
$cfg = Get-MachineConfig
$distro = $cfg.WslDistro
$root = Get-RepoRoot

# ---------------------------------------------------------------- 1. WSL platform
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Step 'Enabling WSL (no distribution yet)'
    & wsl.exe --install --no-distribution
    Set-StageState -Stage '40-Wsl' -Status 'reboot-required'
    Write-Step 'REBOOT, then run stage 40 again.' -Level Warn
    exit 3010
}
& wsl.exe --update | Out-Null
& wsl.exe --set-default-version 2 | Out-Null
Write-Step 'WSL platform ready' -Level Ok

# ---------------------------------------------------------------- 2. .wslconfig
$tpl = Get-Content (Join-Path $root 'config\wslconfig.template') -Raw
$tpl = $tpl.Replace('{{WSL_MEMORY_GB}}', [string]$cfg.WslMemoryGB).Replace('{{WSL_SWAP_GB}}', [string]$cfg.WslSwapGB)
$tpl = $tpl.Replace('{{WSL_PROCESSORS}}', [string]$cfg.WslProcessors).Replace('{{WSL_VHD_MAX_GB}}', [string]$cfg.WslVhdMaxGB)
$wslcfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wslcfg) {
    $existing = Get-Content $wslcfg -Raw
    if ($existing -ne $tpl) { Copy-Item $wslcfg "$wslcfg.bak-$(Get-Date -Format yyyyMMddHHmmss)"; Write-Step "Backed up existing .wslconfig" -Level Info }
}
Write-Utf8NoBom -Path $wslcfg -Content $tpl
Write-Step "Wrote $wslcfg (memory=$($cfg.WslMemoryGB)GB, mirrored networking)" -Level Ok

# ---------------------------------------------------------------- 3. distro
$installed = (& wsl.exe --list --quiet) -replace "`0", '' | Where-Object { $_.Trim() -eq $distro }
if (-not $installed) {
    Write-Step "Installing $distro - a console opens: create your Linux user, type 'exit', then re-run stage 40." -Level Warn
    & wsl.exe --install -d $distro
    Set-StageState -Stage '40-Wsl' -Status 'distro-user-pending'
    exit 3010
}
$linuxUser = ((& wsl.exe -d $distro '--' whoami) | Select-Object -First 1).Trim()
if (-not $linuxUser -or $linuxUser -eq 'root') {
    Write-Step "Default WSL user is '$linuxUser'. Launch '$distro' once and create a normal user, then re-run." -Level Fail
    exit 1
}
Write-Step "$distro present, default user '$linuxUser'" -Level Ok

# ---------------------------------------------------------------- 4. bootstrap (twice: before + after systemd restart)
$bootstrap = ConvertTo-WslPath -WindowsPath (Join-Path $root 'wsl\bootstrap.sh') -Distro $distro
for ($pass = 1; $pass -le 2; $pass++) {
    Write-Step "bootstrap.sh pass $pass"
    $rc = Invoke-Wsl -Distro $distro -User 'root' -Command "tr -d '\r' < '$bootstrap' > /tmp/su-bootstrap.sh && bash /tmp/su-bootstrap.sh '$linuxUser'"
    if ($rc -ne 0) { Write-Step "bootstrap.sh failed (exit $rc) - see output above" -Level Fail; exit 1 }
    if ($pass -eq 1) { & wsl.exe --shutdown; Start-Sleep -Seconds 8 }
}

# ---------------------------------------------------------------- 5. keep the VM alive at logon (services live in it)
$taskName = 'SurfaceUltra-WSL-KeepAlive'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -Command `"wsl.exe -d $distro -u root -e sleep infinity`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Step "Logon task '$taskName' registered and started" -Level Ok

Set-StageState -Stage '40-Wsl' -Status 'done'
Write-Step 'Stage 40 complete' -Level Ok
exit 0
