#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-trip: fill the flash drive (travel cache) with what you might need away from the NAS and Spark.
.DESCRIPTION
    Copies to <flash>\surface-ultra\ (volume label SU-COLD):
      models\<alias>   TravelModels from machine.psd1 (or -Models): taken from the hot tier if present,
                       otherwise from the NAS library. Promote on the road with
                       tools\Move-ModelTier.ps1 -Promote <alias> (copies at ~400 MB/s; nothing runs from the stick).
      kit\drivers      the repo's staged drivers (FTDI ARM64, Quarch zip, ...)
      kit\apps         the repo's staged installers
      kit\repo         this build repo (so a rebuild works offline)
    NDA material is NOT copied (the stick is small and easy to lose); use Sync-ResearchReplica.ps1
    for NDA collections, which land in the laptop's NDA workspace.
.EXAMPLE
    .\Sync-TravelCache.ps1
    .\Sync-TravelCache.ps1 -Models sc-research-alt,sc-analyst
#>
[CmdletBinding(SupportsShouldProcess)] param([string[]]$Models)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage 'Sync-TravelCache'
$cfg = Get-MachineConfig
$cold = Get-ColdRoot -Cfg $cfg
if (-not $cold) { Write-Step "Flash drive with volume label '$($cfg.ColdVolumeLabel)' not found - plug it in (and label it once: Set-Volume -DriveLetter E -NewFileSystemLabel $($cfg.ColdVolumeLabel))" -Level Fail; exit 1 }
$nas = Get-NasRoot -Cfg $cfg
if (-not $Models) { $Models = @($cfg.TravelModels) }

function Copy-Tree([string]$From, [string]$Dest, [string[]]$Extra = @()) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $rcArgs = @($From, $Dest, '/MIR', '/MT:8', '/R:1', '/W:2', '/NFL', '/NDL', '/NP', '/NJH') + $Extra
    & robocopy.exe @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $Dest" }
}

$freeGB = { [math]::Round((Get-PSDrive ((Split-Path -Qualifier $cold).TrimEnd(':'))).Free / 1GB) }
foreach ($a in $Models) {
    $src = Join-Path $cfg.ModelRoot $a
    if (-not (Test-Path $src) -and $nas) { $src = Join-Path (Join-Path $nas $cfg.NasModelsSubdir) $a }
    if (-not (Test-Path $src)) { Write-Step "$($a): not in hot tier or NAS library - skipped" -Level Warn; continue }
    $gb = [math]::Round(((Get-ChildItem $src -Recurse -File | Measure-Object Length -Sum).Sum) / 1GB, 1)
    if ($gb -gt (& $freeGB)) { Write-Step "$($a): $gb GB won't fit ($(& $freeGB) GB free on the stick)" -Level Fail; continue }
    if ($PSCmdlet.ShouldProcess($a, "copy $src -> flash")) {
        Write-Step "$($a): copying $gb GB (USB 3.2 Gen 1 writes are slow - expect minutes)"
        Copy-Tree $src (Join-Path $cold "models\$a") @('/XD', '.cache')
        Write-Step "$($a): on the flash drive" -Level Ok
    }
}

$root = Get-RepoRoot
foreach ($pair in @(@('drivers', 'kit\drivers'), @('apps', 'kit\apps'))) {
    $src = Join-Path $root $pair[0]
    if (Test-Path $src) { Copy-Tree $src (Join-Path $cold $pair[1]); Write-Step "$($pair[0]) -> $($pair[1])" -Level Ok }
}
Copy-Tree $root (Join-Path $cold 'kit\repo') @('/XD', 'logs', 'apps', 'drivers', '.git', '__pycache__', 'results')
Write-Step 'Build repo copied (offline rebuild kit)' -Level Ok
Write-Step "Flash drive free: $(& $freeGB) GB" -Level Info
