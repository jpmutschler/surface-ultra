#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 00 - read-only inventory of the new machine. Changes nothing.
.DESCRIPTION
    Confirms ARM64 + RTX Spark, reads driver version, reads the GPU/Windows memory split set in the
    NVIDIA app (dedicated = the model budget), commit limit, unexpected power-offs, USB4 routers,
    storage, device-encryption and virtualization state, and writes logs\preflight-<stamp>.json.
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '00-Preflight'
$cfg = Get-MachineConfig
$report = [ordered]@{ timestamp = (Get-Date).ToString('s') }
$problems = 0

# ---------------------------------------------------------------- CPU / OS
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$report.cpu = $cpu.Name
$report.cores = $cpu.NumberOfCores
$report.logicalProcessors = $cs.NumberOfLogicalProcessors
$report.os = "$($os.Caption) build $($os.BuildNumber)"
$report.ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$report.model = "$($cs.Manufacturer) $($cs.Model)"

if (Test-IsArm64Host) { Write-Step "ARM64 host: $($cpu.Name), $($cpu.NumberOfCores) cores" -Level Ok }
else { Write-Step "Host is NOT ARM64 ($($cpu.Name)) - these scripts target Windows on Arm" -Level Fail; $problems++ }
if (-not (Test-IsNativeArm64Process)) {
    Write-Step "This PowerShell is running emulated ($env:PROCESSOR_ARCHITECTURE). Use the ARM64 PowerShell for best results." -Level Warn
}
Write-Step "$($report.model) | $($report.os) | RAM $($report.ramGB) GB"

# ---------------------------------------------------------------- GPU + driver
$gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
if ($gpu) {
    # NVIDIA WDDM version 32.0.16.1630 -> marketing 616.30 (last 5 digits of the last two fields)
    $parts = $gpu.DriverVersion.Split('.')
    $tail = ($parts[-2] + $parts[-1])
    $tail = $tail.Substring($tail.Length - 5)
    $nvVer = [double]('{0}.{1}' -f $tail.Substring(0, 3), $tail.Substring(3))
    $report.gpu = $gpu.Name
    $report.driverWddm = $gpu.DriverVersion
    $report.driverNvidia = $nvVer
    if ($nvVer -ge 616.0) { Write-Step "GPU $($gpu.Name), driver $nvVer (R616+ required for CUDA 13.4 WoA)" -Level Ok }
    else { Write-Step "GPU $($gpu.Name), driver $nvVer - install the R616+ developer driver" -Level Fail; $problems++ }

    # Memory split (set in the NVIDIA app): the dedicated segment is the real model budget
    $split = Get-GpuMemorySplit
    if ($split) {
        $report.installedGB = $split.InstalledGB
        $report.gpuDedicatedGB = $split.DedicatedGB
        $report.gpuSharedSpillGB = $split.SharedGB
        $report.windowsVisibleGB = $split.WindowsGB
        Write-Step ("Memory split: {0} GB dedicated to the GPU, {1} GB for Windows (CUDA can spill ~{2} GB more into shared, slower)" -f `
            $split.DedicatedGB, $split.WindowsGB, $split.SharedGB) -Level Info
        if ($split.DedicatedGB -lt ($cfg.GpuDedicatedTargetGB - 4)) {
            Write-Step ("Dedicated is below the {0} GB this build plans for (sc-research 65 GB + resident set + KV). Raise it in the NVIDIA app; until then run sc-analyst locally and sc-research on the Spark." -f $cfg.GpuDedicatedTargetGB) -Level Warn
        } else { Write-Step "Dedicated split matches the plan ($($cfg.GpuDedicatedTargetGB) GB)" -Level Ok }
    } else {
        Write-Step 'Could not read the GPU dedicated memory size from the registry' -Level Warn
    }
    $nvApp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -match '^NVIDIA app' } | Select-Object -First 1
    if ($nvApp) { Write-Step "NVIDIA app $($nvApp.DisplayVersion) present (memory split, drivers)" -Level Ok }
    else { Write-Step 'NVIDIA app not found - it is where the GPU/Windows memory split is set. Install it from nvidia.com.' -Level Warn }
} else {
    Write-Step 'No NVIDIA display adapter found' -Level Fail; $problems++
}
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    $q = & nvidia-smi '--query-gpu=name,driver_version,memory.total' '--format=csv,noheader' 2>$null
    $report.nvidiaSmi = "$q"
    Write-Step "nvidia-smi: $q (reports the carveout only)" -Level Ok
} else { Write-Step 'nvidia-smi not on PATH yet' -Level Warn }

# ---------------------------------------------------------------- USB4 / PCIe
$usb4 = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'USB4|Thunderbolt' })
$report.usb4Devices = @($usb4 | ForEach-Object { "$($_.Class): $($_.FriendlyName) [$($_.Status)]" })
if ($usb4.Count -gt 0) { $usb4 | ForEach-Object { Write-Step "USB4: $($_.FriendlyName) [$($_.Status)]" -Level Ok } }
else { Write-Step 'No USB4 host router listed in PnP (check Device Manager > USB4 / Universal Serial Bus controllers)' -Level Warn }

# ---------------------------------------------------------------- storage
$disks = Get-PhysicalDisk | Select-Object FriendlyName, BusType, MediaType, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }
$report.disks = @($disks | ForEach-Object { "$($_.FriendlyName) $($_.BusType) $($_.SizeGB)GB" })
$disks | ForEach-Object { Write-Step "Disk: $($_.FriendlyName) $($_.BusType) $($_.SizeGB) GB" }
$vols = Get-Volume | Where-Object { $_.DriveLetter } | Select-Object DriveLetter, FileSystem, FileSystemLabel, @{n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB) } }, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }
$report.volumes = @($vols | ForEach-Object { "$($_.DriveLetter): $($_.FileSystem) $($_.FreeGB)/$($_.SizeGB) GB free" })
$vols | ForEach-Object { Write-Step ("Volume {0}: {1} {2}/{3} GB free {4}" -f $_.DriveLetter, $_.FileSystem, $_.FreeGB, $_.SizeGB, $_.FileSystemLabel) }
if ($cfg.DevDrivePresent) { Write-Step "Dev Drive $($cfg.DevDriveLetter): present - repos/models go there" -Level Ok }
else { Write-Step "No $($cfg.DevDriveLetter): Dev Drive yet - scripts will use C:\. Create one in Settings first (see README)." -Level Warn }

# ---------------------------------------------------------------- security / virtualization
if (Test-IsAdmin) {
    try {
        $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $report.bitlocker = "$($bl.ProtectionStatus) $($bl.VolumeStatus)"
        Write-Step "Device encryption (BitLocker) on C: $($bl.ProtectionStatus) - your call; recorded for reference" -Level Info
    } catch { Write-Step "BitLocker status unavailable: $($_.Exception.Message)" -Level Info }
} else { Write-Step 'Not elevated - skipping BitLocker check' -Level Skip }
$report.hypervisorPresent = $cs.HypervisorPresent
Write-Step "Hypervisor present: $($cs.HypervisorPresent)"
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
$report.wsl = [bool]$wsl

# ---------------------------------------------------------------- commit + stability
$commit = Get-CommitState
$report.commitLimitGB = $commit.LimitGB
Write-Step ("Commit: {0} GB used of a {1} GB limit. CUDA allocations count against it; stage 10 sizes the page file (PageFileGB = {2})." -f $commit.UsedGB, $commit.LimitGB, $cfg.PageFileGB) -Level Info
# A review unit hard-powered-off under sustained all-core FP64 load (Kernel-Power 41, bugcheck 0). Record a baseline.
$kp = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
$report.kernelPower41Last30d = $kp.Count
Write-Step ("Unexpected power-offs (Kernel-Power 41) in the last 30 days: {0}" -f $kp.Count) -Level $(if ($kp.Count) { 'Warn' } else { 'Ok' })

# ---------------------------------------------------------------- power
try {
    Add-Type -AssemblyName System.Windows.Forms
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $report.power = "$($ps.PowerLineStatus) battery $([int]($ps.BatteryLifePercent*100))%"
    Write-Step "Power: $($report.power)"
} catch { }

# ---------------------------------------------------------------- write report
$out = Join-Path (Get-RepoRoot) ("logs\preflight-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | ConvertTo-Json -Depth 4 | Set-Content -Path $out -Encoding UTF8
Write-Step "Report: $out"
if ($problems -gt 0) { Write-Step "$problems blocking problem(s) found" -Level Fail; exit 1 }
Write-Step 'Preflight passed' -Level Ok
exit 0
