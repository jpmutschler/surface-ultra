#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 30 - hardware-in-the-loop drivers and inventory.
.DESCRIPTION
    Installs every ARM64 driver package (.inf) you staged under .\drivers\ (FTDI ARM64
    CDM, SiLabs CP210x universal, etc.) with pnputil, then inventories COM ports, USB
    devices and anything Windows could not bind a driver to - the fastest way to find
    gear that has no ARM64 driver.

    Stage drivers first (vendor downloads, gitignored):
      drivers\ftdi\       FTDI CDM 2.12.36.20 ARM64 (Universal or Desktop) - unzip here
      drivers\cp210x\     Silicon Labs CP210x Universal Windows Driver - unzip here
      drivers\<vendor>\   anything else with an ARM64 .inf
.PARAMETER InventoryOnly
    Skip driver installation; just report.
#>
[CmdletBinding(SupportsShouldProcess)] param([switch]$InventoryOnly)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '30-HilDrivers'
Assert-Admin
$root = Get-RepoRoot
$drvRoot = Join-Path $root 'drivers'

# ---------------------------------------------------------------- install staged INFs
if (-not $InventoryOnly) {
    if (-not (Test-Path $drvRoot)) { New-Item -ItemType Directory -Path $drvRoot | Out-Null }
    # Vendor zips dropped straight into drivers\ get unpacked next to themselves first
    foreach ($z in @(Get-ChildItem -Path $drvRoot -Filter *.zip -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $drvRoot $z.BaseName
        if (-not (Test-Path $dest)) { Expand-Archive -Path $z.FullName -DestinationPath $dest; Write-Step "Unpacked $($z.Name)" -Level Ok }
    }
    $infs = @(Get-ChildItem -Path $drvRoot -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    # Quarch Torridon: WinUSB package without an ARM64 section -> Zadig preset route
    if ($infs | Where-Object { $_.Name -like 'Quarch_Torridon*' }) {
        Write-Step 'Quarch Torridon driver has no ARM64 section. Bind WinUSB with the presets in tools\zadig (see its README).' -Level Warn
    }
    if ($infs.Count -eq 0) {
        Write-Step "No .inf files under $drvRoot - stage vendor ARM64 drivers there (see script header)" -Level Warn
    }
    foreach ($inf in $infs) {
        # Skip INFs that don't declare an ARM64 section - installing them would fail anyway
        $text = Get-Content $inf.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -and $text -notmatch '(?i)NTarm64') {
            Write-Step "Skipping $($inf.Name): no NTarm64 section (x64-only driver)" -Level Warn
            continue
        }
        if ($PSCmdlet.ShouldProcess($inf.FullName, 'pnputil /add-driver /install')) {
            $out = & pnputil.exe /add-driver $inf.FullName /install 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $out -match 'Added driver packages:\s*[1-9]') { Write-Step "Installed $($inf.Name)" -Level Ok }
            else { Write-Step "pnputil failed for $($inf.Name): $($out.Trim())" -Level Fail }
        }
    }
}

# ---------------------------------------------------------------- inventory
Write-Step 'COM ports:' -Level Head
$ports = @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue)
if ($ports.Count -eq 0) { Write-Step 'none (plug in an Atlas3/HYDRA console or FTDI cable and re-run with -InventoryOnly)' -Level Info }
foreach ($p in $ports) {
    $svc = (Get-PnpDeviceProperty -InstanceId $p.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
    Write-Step ("{0}  [{1}]  driver={2}" -f $p.FriendlyName, $p.Status, $svc) -Level Ok
}

Write-Step 'USB devices (VID:PID):' -Level Head
Get-PnpDevice -PresentOnly -Class USB -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})' } |
    ForEach-Object {
        [void]($_.InstanceId -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})')
        Write-Step ("{0}:{1}  {2}  [{3}]" -f $Matches[1], $Matches[2], $_.FriendlyName, $_.Status)
    }

Write-Step 'Devices with no working driver (likely missing ARM64 builds):' -Level Head
$bad = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in @('Error', 'Unknown', 'Degraded') })
if ($bad.Count -eq 0) { Write-Step 'none' -Level Ok }
foreach ($b in $bad) {
    $code = (Get-PnpDeviceProperty -InstanceId $b.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
    Write-Step ("{0} | {1} | problem code {2} | {3}" -f $b.Class, $b.FriendlyName, $code, $b.InstanceId) -Level Warn
}

# ---------------------------------------------------------------- usbipd (for Linux-only tools in WSL)
Update-SessionPath
if (Get-Command usbipd -ErrorAction SilentlyContinue) {
    Write-Step 'usbipd-win present. To hand a device to WSL:  usbipd bind --busid <x-y>; usbipd attach --wsl --busid <x-y>' -Level Ok
    & usbipd list
} else { Write-Step 'usbipd not found (stage 10 installs it)' -Level Warn }

Write-Step 'Python-side notes: pyserial works as-is; pyftdi/pyusb need WinUSB bound to the device (Zadig) - do not do that for devices you use through the FTDI VCP driver.' -Level Info
Write-Step 'Stage 30 complete' -Level Ok
exit 0
