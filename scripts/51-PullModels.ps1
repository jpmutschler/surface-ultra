#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 51 - download local models from Hugging Face and regenerate llama-swap.yaml.
.DESCRIPTION
    Default: every model in config\models.psd1 with Pull = $true (the always-on set), into the hot
    tier. If the NAS model library (\\home-nas\surface-ultra\models) already has the model it is
    copied from there over the LAN instead of downloaded; newly downloaded models are also copied
    to the NAS so they're only ever downloaded once (the Spark can use the same library).
    Checks free space first so a 65 GB download can't fill the 1 TB SSD.
.PARAMETER Alias
    Specific aliases to pull, e.g. -Alias sc-research-alt
.PARAMETER All
    Pull every model that has a Repo set.
.PARAMETER Archive
    Download into the NAS library only (nothing lands on the laptop). Promote later with
    tools\Move-ModelTier.ps1 -Promote <alias>.
.PARAMETER NoNas
    Ignore the NAS (always download from Hugging Face; no copy to the library).
.PARAMETER ConfigOnly
    Skip downloads; just regenerate llama-swap.yaml from what's on disk and restart.
.EXAMPLE
    .\51-PullModels.ps1                            # default set (~101 GB: research, analyst, fast, embed, rerank)
    .\51-PullModels.ps1 -Alias sc-research-alt     # bake-off challenger (63 GB)
    .\51-PullModels.ps1 -Alias sc-research-alt -Archive   # straight to the NAS library
#>
[CmdletBinding(SupportsShouldProcess)] param([string[]]$Alias, [switch]$All, [switch]$Archive, [switch]$NoNas, [switch]$ConfigOnly)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '51-PullModels'
$cfg = Get-MachineConfig
Update-SessionPath
$catalog = Get-ModelCatalog

if (-not $ConfigOnly) {
    $hf = Get-Command hf -ErrorAction SilentlyContinue
    if (-not $hf) { Write-Step "'hf' CLI not found - stage 20 installs it (uv tool install huggingface_hub[cli])" -Level Fail; exit 1 }

    $want = @()
    if ($Alias) { $want = @($catalog | Where-Object { $Alias -contains $_.Alias }) }
    elseif ($All) { $want = @($catalog | Where-Object { $_.Repo }) }
    else { $want = @($catalog | Where-Object { $_.Pull }) }
    $want = @($want | Where-Object {
        if (-not $_.Repo) { Write-Step "$($_.Alias): no Repo set in models.psd1 - skipped" -Level Warn; $false } else { $true } })

    $nasLib = $null
    if (-not $NoNas) {
        $nas = Get-NasRoot -Cfg $cfg
        if ($nas) { $nasLib = Join-Path $nas $cfg.NasModelsSubdir; Write-Step "NAS model library: $nasLib" -Level Ok }
        else { Write-Step 'NAS not reachable - downloading from Hugging Face only' -Level Info }
    }
    if ($Archive -and -not $nasLib) { Write-Step '-Archive needs the NAS' -Level Fail; exit 1 }

    $drive = (Split-Path -Qualifier $cfg.ModelRoot).TrimEnd(':')
    foreach ($m in $want) {
        $folder = if ($Archive) { Join-Path $nasLib $m.Alias } else { Join-Path $cfg.ModelRoot $m.Alias }
        if ($m.Main -and (Resolve-ModelFile -Folder $folder -Relative $m.Main)) {
            Write-Step "$($m.Alias) already there ($folder)" -Level Skip; continue
        }
        $freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
        if (-not $Archive -and (($freeGB - $m.SizeGB) -lt $cfg.MinFreeGBAfterPull)) {
            Write-Step ("{0}: needs {1} GB, {2} GB free, floor {3} GB - skipped. Demote something (tools\Move-ModelTier.ps1) or use -Archive." -f `
                $m.Alias, $m.SizeGB, $freeGB, $cfg.MinFreeGBAfterPull) -Level Fail
            continue
        }
        # NAS first: a LAN copy beats a fresh download
        $nasCopy = if ($nasLib -and -not $Archive) { Join-Path $nasLib $m.Alias } else { $null }
        if ($nasCopy -and $m.Main -and (Resolve-ModelFile -Folder $nasCopy -Relative $m.Main)) {
            if ($PSCmdlet.ShouldProcess($m.Alias, "copy from NAS library")) {
                & robocopy.exe $nasCopy $folder /E /MT:16 /R:1 /W:2 /NFL /NDL /NP /NJH | Out-Null
                if ($LASTEXITCODE -lt 8) { Write-Step "$($m.Alias) copied from the NAS library" -Level Ok; continue }
                Write-Step "$($m.Alias): NAS copy failed (robocopy $LASTEXITCODE) - downloading instead" -Level Warn
            }
        }
        Write-Step ("{0}: {1} ({2} GB, {3})" -f $m.Alias, $m.Repo, $m.SizeGB, $m.License)
        $hfArgs = @('download', $m.Repo, '--local-dir', $folder)
        foreach ($inc in $m.Include) { $hfArgs += @('--include', $inc) }
        if ($PSCmdlet.ShouldProcess($m.Repo, 'hf download')) {
            & hf @hfArgs
            if ($LASTEXITCODE -eq 0) {
                Write-Step "$($m.Alias) downloaded" -Level Ok
                if ($nasCopy) {   # seed the library so this model is never downloaded twice
                    & robocopy.exe $folder $nasCopy /E /MT:16 /R:1 /W:2 /NFL /NDL /NP /NJH /XD .cache | Out-Null
                    if ($LASTEXITCODE -lt 8) { Write-Step "$($m.Alias) copied to the NAS library" -Level Ok }
                }
            }
            else { Write-Step "$($m.Alias) download failed (exit $LASTEXITCODE)" -Level Fail }
        }
    }
}

# ---------------------------------------------------------------- regenerate + restart
[void](New-LlamaSwapConfig -Cfg $cfg)
Restart-LlamaSwap
$used = (Get-ChildItem $cfg.ModelRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Step ("Model store {0}: {1:N1} GB" -f $cfg.ModelRoot, ($used / 1GB))
Write-Step 'Stage 51 complete' -Level Ok
exit 0
