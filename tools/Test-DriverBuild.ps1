#Requires -Version 5.1
<#
.SYNOPSIS
    Day-one check: build one of your existing driver solutions for x64 and ARM64 on this ARM64 host.
.DESCRIPTION
    Microsoft documents building and debugging ARM64 drivers from an ARM64 host (WDK 10.0.26100.1+). It
    does not spell out building x64 kernel-mode drivers from one - and x64 is what customers run. This
    finds MSBuild through vswhere, builds each platform, and lists the .sys/.inf/.cat it produced.

    An x64 driver can be built here but never loaded here (x64 kernel drivers don't run on ARM64):
    test it on the x64 lab host (LabHostX64 in machine.psd1), debugging with WinDbg over kdnet.
    If the x64 build fails here, build x64 on the lab host and keep ARM64 here.
.EXAMPLE
    .\Test-DriverBuild.ps1 -Solution D:\dev\src\hydra-driver\hydra.sln
    .\Test-DriverBuild.ps1 -Solution .\x.sln -Platforms x64 -Configuration Debug
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Solution,
    [string[]]$Platforms = @('x64', 'ARM64'),
    [string]$Configuration = 'Release'
)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage 'Test-DriverBuild'
$sln = (Resolve-Path $Solution -ErrorAction Stop).Path

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Write-Step 'vswhere not found - run stage 20 (Visual Studio)' -Level Fail; exit 1 }
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\**\MSBuild.exe' |
    Where-Object { $_ -match '\\arm64\\' } | Select-Object -First 1
if (-not $msbuild) { $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1 }
if (-not $msbuild) { Write-Step 'MSBuild not found' -Level Fail; exit 1 }
Write-Step "MSBuild: $msbuild [$(Get-PeArchitecture -Path $msbuild)]"

$wdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'km') } | Sort-Object Name | Select-Object -Last 1
if ($wdk) { Write-Step "WDK headers: $($wdk.Name)" -Level Ok } else { Write-Step 'No WDK kernel headers found (Include\<ver>\km) - set InstallWdk = $true and run stage 20' -Level Warn }

$results = foreach ($p in $Platforms) {
    $log = Join-Path (Get-RepoRoot) ("logs\driverbuild-{0}-{1}.log" -f $p, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Step "Building $Configuration|$p ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $msbuild $sln '/m' '/nologo' '/v:minimal' "/p:Configuration=$Configuration" "/p:Platform=$p" "/flp:logfile=$log;verbosity=normal" | Out-Null
    $rc = $LASTEXITCODE; $sw.Stop()
    $outs = @(Get-ChildItem (Split-Path $sln) -Recurse -Include *.sys, *.inf, *.cat -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\$p\\" -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) })
    [pscustomobject]@{ Platform = $p; Result = $(if ($rc -eq 0) { 'PASS' } else { "FAIL ($rc)" }); Seconds = [int]$sw.Elapsed.TotalSeconds
                       Outputs = ($outs | ForEach-Object Name) -join ', '; Log = $log }
}
$results | Format-Table -AutoSize
foreach ($r in $results) {
    if ($r.Result -ne 'PASS') { Write-Step "$($r.Platform) build failed - see $($r.Log)" -Level Fail }
}
if (@($results | Where-Object { $_.Platform -eq 'x64' -and $_.Result -ne 'PASS' }).Count) {
    Write-Step 'x64 driver builds need another home: build them on the x64 lab host, keep ARM64 here.' -Level Warn
}
Write-Step 'Load/test x64 drivers on the x64 lab host only; debug from here with WinDbg (kdnet).' -Level Info
