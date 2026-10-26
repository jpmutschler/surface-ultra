#Requires -Version 5.1
<#
.SYNOPSIS
    Day-one go/no-go for the USB4-to-x16 CEM adapter (PCIe tunneling).
.DESCRIPTION
    1. Snapshots PCI devices, asks you to plug in the adapter with a card installed,
       snapshots again and shows what enumerated.
    2. Prints negotiated vs maximum link speed/width for each new device
       (DEVPKEY_PciDevice_* properties; expect Gen4 x4 through a 40 Gbps USB4 tunnel).
    3. Optional: -TestDrive E runs a sequential-read benchmark (winsat) on an NVMe card.
.EXAMPLE
    .\Test-Usb4Pcie.ps1 -TestDrive E
#>
[CmdletBinding()] param([string]$TestDrive)

function Get-PciSnapshot {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } |
        Select-Object InstanceId, FriendlyName, 'Class', Status
}
$speedName = @{ 1 = 'Gen1 2.5GT/s'; 2 = 'Gen2 5GT/s'; 3 = 'Gen3 8GT/s'; 4 = 'Gen4 16GT/s'; 5 = 'Gen5 32GT/s'; 6 = 'Gen6 64GT/s' }
function Get-Prop([string]$Id, [string]$Key) {
    (Get-PnpDeviceProperty -InstanceId $Id -KeyName $Key -ErrorAction SilentlyContinue).Data
}

Write-Host 'Unplug the USB4-to-CEM adapter, then press Enter...' -ForegroundColor Cyan; [void](Read-Host)
$before = Get-PciSnapshot
Write-Host 'Plug in the adapter (card installed, adapter powered), wait ~10 s, then press Enter...' -ForegroundColor Cyan; [void](Read-Host)
Start-Sleep -Seconds 3
$after = Get-PciSnapshot
$new = @($after | Where-Object { $before.InstanceId -notcontains $_.InstanceId })

if ($new.Count -eq 0) {
    Write-Host 'NO-GO: nothing new enumerated on PCI. Check: USB4 port (not the Magnetic Connect port), adapter power, Device Manager > USB4 Host Router, and Windows Settings > Bluetooth & devices > USB > USB4 hubs and devices.' -ForegroundColor Red
    exit 1
}
Write-Host ("{0} new PCI function(s):" -f $new.Count) -ForegroundColor Green
$rows = foreach ($d in $new) {
    $cs = Get-Prop $d.InstanceId 'DEVPKEY_PciDevice_CurrentLinkSpeed'
    $cw = Get-Prop $d.InstanceId 'DEVPKEY_PciDevice_CurrentLinkWidth'
    $ms = Get-Prop $d.InstanceId 'DEVPKEY_PciDevice_MaxLinkSpeed'
    $mw = Get-Prop $d.InstanceId 'DEVPKEY_PciDevice_MaxLinkWidth'
    [pscustomobject]@{
        Device  = $d.FriendlyName
        Class   = $d.Class
        Status  = $d.Status
        Link    = if ($cs) { "$($speedName[[int]$cs]) x$cw" } else { '' }
        Max     = if ($ms) { "$($speedName[[int]$ms]) x$mw" } else { '' }
        Driver  = Get-Prop $d.InstanceId 'DEVPKEY_Device_Service'
    }
}
$rows | Format-Table -AutoSize
$broken = @($new | Where-Object Status -ne 'OK')
if ($broken.Count) { Write-Host "WARN: $($broken.Count) function(s) without a working driver (likely no ARM64 driver for that card)." -ForegroundColor Yellow }

if ($TestDrive) {
    Write-Host "Sequential read on ${TestDrive}: (winsat)..." -ForegroundColor Cyan
    & winsat disk -seq -read -drive $TestDrive.TrimEnd(':')
    Write-Host 'Expect roughly 3 GB/s or more through a 40 Gbps USB4 PCIe tunnel.' -ForegroundColor Cyan
}
