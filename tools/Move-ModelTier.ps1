#Requires -Version 5.1
<#
.SYNOPSIS
    Moves model folders between storage tiers. Nothing ever runs from the NAS or the flash drive.
.DESCRIPTION
    hot  = <ModelRoot> on the internal Gen5 SSD (the only place llama-swap loads from)
    nas  = <NAS>\models  - the model library (\\home-nas, LAN or Tailscale)
    cold = <flash>\surface-ultra\models - travel cache on the SanDisk Extreme Fit (label SU-COLD)

      -List                 where every model lives, with sizes
      -Promote a,b          copy into hot (from the NAS if reachable, else the flash drive), then
                            regenerate llama-swap.yaml and restart llama-swap
      -Demote a,b [-To Nas|Cold] [-Keep]
                            copy out of hot (default: NAS), verify sizes, then delete the hot copy
                            unless -Keep; regenerate llama-swap.yaml
.EXAMPLE
    .\Move-ModelTier.ps1 -List
    .\Move-ModelTier.ps1 -Promote sc-research-alt          # before a bake-off
    .\Move-ModelTier.ps1 -Demote sc-research-alt           # afterwards, frees ~63 GB
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Promote', Mandatory)][string[]]$Promote,
    [Parameter(ParameterSetName = 'Demote', Mandatory)][string[]]$Demote,
    [Parameter(ParameterSetName = 'Demote')][ValidateSet('Nas', 'Cold')][string]$To = 'Nas',
    [Parameter(ParameterSetName = 'Demote')][switch]$Keep
)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage 'Move-ModelTier'
$cfg = Get-MachineConfig
$nas = Get-NasRoot -Cfg $cfg
$cold = Get-ColdRoot -Cfg $cfg
$tiers = [ordered]@{
    hot  = $cfg.ModelRoot
    nas  = $(if ($nas) { Join-Path $nas $cfg.NasModelsSubdir } else { $null })
    cold = $(if ($cold) { Join-Path $cold 'models' } else { $null })
}

function Get-FolderGB([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    [math]::Round(((Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 1)
}

function Copy-Tree([string]$From, [string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    & robocopy.exe $From $Dest /E /MT:16 /R:1 /W:2 /NFL /NDL /NP /NJH | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $Dest" }
}

switch ($PSCmdlet.ParameterSetName) {
    'List' {
        Write-Step ("NAS : {0}" -f $(if ($nas) { $nas } else { 'not reachable' }))
        Write-Step ("Cold: {0}" -f $(if ($cold) { $cold } else { "flash drive '$($cfg.ColdVolumeLabel)' not plugged in" }))
        $names = @(Get-ModelCatalog | ForEach-Object Alias)
        foreach ($t in $tiers.Values) { if ($t -and (Test-Path $t)) { $names += @(Get-ChildItem $t -Directory | ForEach-Object Name) } }
        $rows = foreach ($n in ($names | Sort-Object -Unique)) {
            [pscustomobject]@{
                Model  = $n
                HotGB  = Get-FolderGB (Join-Path $tiers.hot $n)
                NasGB  = $(if ($tiers.nas) { Get-FolderGB (Join-Path $tiers.nas $n) })
                ColdGB = $(if ($tiers.cold) { Get-FolderGB (Join-Path $tiers.cold $n) })
            }
        }
        $rows | Format-Table -AutoSize
        $free = [math]::Round((Get-PSDrive ((Split-Path -Qualifier $cfg.ModelRoot).TrimEnd(':'))).Free / 1GB)
        Write-Step "Hot tier free: $free GB"
    }
    'Promote' {
        foreach ($a in $Promote) {
            $src = $null
            foreach ($t in @('nas', 'cold')) {
                if ($tiers[$t] -and (Test-Path (Join-Path $tiers[$t] $a))) { $src = Join-Path $tiers[$t] $a; break }
            }
            if (-not $src) { Write-Step "$($a): not found on the NAS or the flash drive" -Level Fail; continue }
            $need = Get-FolderGB $src
            $free = [math]::Round((Get-PSDrive ((Split-Path -Qualifier $cfg.ModelRoot).TrimEnd(':'))).Free / 1GB)
            if (($free - $need) -lt $cfg.MinFreeGBAfterPull) { Write-Step "$($a): needs $need GB, only $free GB free (floor $($cfg.MinFreeGBAfterPull))" -Level Fail; continue }
            if ($PSCmdlet.ShouldProcess($a, "copy $src -> hot")) {
                Write-Step "$($a): $need GB from $src"
                Copy-Tree $src (Join-Path $tiers.hot $a)
                Write-Step "$($a): promoted to hot" -Level Ok
            }
        }
        [void](New-LlamaSwapConfig -Cfg $cfg); Restart-LlamaSwap
    }
    'Demote' {
        $dstRoot = $tiers[$To.ToLower()]
        if (-not $dstRoot) { Write-Step "$To tier not available (NAS unreachable or flash drive not plugged in)" -Level Fail; exit 1 }
        foreach ($a in $Demote) {
            $hot = Join-Path $tiers.hot $a
            if (-not (Test-Path $hot)) { Write-Step "$($a): not in hot tier" -Level Skip; continue }
            $dst = Join-Path $dstRoot $a
            if ($PSCmdlet.ShouldProcess($a, "copy hot -> $dst")) {
                Copy-Tree $hot $dst
                $h = Get-FolderGB $hot; $d = Get-FolderGB $dst
                if ($h -ne $d) { Write-Step "$($a): size mismatch after copy ($h vs $d GB) - hot copy kept" -Level Fail; continue }
                if (-not $Keep) { Remove-Item $hot -Recurse -Force; Write-Step "$($a): demoted to $To ($d GB freed)" -Level Ok }
                else { Write-Step "$($a): copied to $To, hot copy kept" -Level Ok }
            }
        }
        [void](New-LlamaSwapConfig -Cfg $cfg); Restart-LlamaSwap
    }
}
