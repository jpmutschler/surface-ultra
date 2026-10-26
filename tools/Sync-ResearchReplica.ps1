#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-trip sync: copy RAG collections from the DGX Spark's Qdrant to the laptop for offline research.
.DESCRIPTION
    For each collection in config\machine.psd1 ReplicaCollections (or -Collection):
      1. snapshot it on the Spark       POST /collections/<c>/snapshots?wait=true
      2. download the snapshot          (NDA zone: into D:\nda\replica, never the dev tree)
      3. restore it locally             POST /collections/<c>/snapshots/upload?priority=snapshot
         - zone 'nda'  -> NDA-session Qdrant 127.0.0.1:<NdaQdrantPort> (NdaSession.ps1 -Start first)
         - otherwise   -> everyday Qdrant 127.0.0.1:6333
      4. delete the snapshot on the Spark and the local download
    Writes %USERPROFILE%\.surface-ultra\replica-manifest.json (what was synced, when, point counts).
    The local embedding model (sc-embed) must be the same model the Spark used to build the index.
.EXAMPLE
    .\Sync-ResearchReplica.ps1                       # everything in ReplicaCollections
    .\Sync-ResearchReplica.ps1 -Collection vendor-acme
#>
[CmdletBinding()] param([string[]]$Collection, [switch]$KeepFiles)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage 'Sync-ResearchReplica'
$cfg = Get-MachineConfig
$spark = $cfg.SparkQdrantUrl.TrimEnd('/')
$sparkHdr = @{}
$sk = [Environment]::GetEnvironmentVariable('SPARK_QDRANT_KEY', 'User')
if ($sk) { $sparkHdr['api-key'] = $sk }

$items = @($cfg.ReplicaCollections)
if ($Collection) { $items = @($items | Where-Object { $Collection -contains $_.Name }) }
if ($items.Count -eq 0) { Write-Step 'Nothing to sync - add entries to ReplicaCollections in machine.psd1' -Level Warn; exit 0 }

try { Invoke-RestMethod "$spark/collections" -Headers $sparkHdr -TimeoutSec 10 | Out-Null }
catch { Write-Step "Spark Qdrant unreachable at $spark : $($_.Exception.Message)" -Level Fail; exit 1 }

$manifestPath = Join-Path $cfg.SuHome 'replica-manifest.json'
$manifest = @{}
if (Test-Path $manifestPath) {
    (Get-Content $manifestPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $manifest[$_.Name] = $_.Value }
}

foreach ($c in $items) {
    $name = $c.Name
    $nda = ($c.Zone -eq 'nda')
    if ($nda) {
        if (-not (Test-TcpPort -HostName '127.0.0.1' -Port $cfg.NdaQdrantPort)) { Write-Step "$($name) (nda): NDA Qdrant not running - run NdaSession.ps1 -Start" -Level Warn; continue }
        $port = $cfg.NdaQdrantPort
        $localHdr = @('-H', ('api-key: ' + (Get-Content (Join-Path $cfg.NdaSecrets 'qdrant-nda.key') -Raw).Trim()))
        $dlDir = Join-Path $cfg.NdaRoot 'replica'
    } else {
        $port = 6333
        $localHdr = @()
        $dlDir = Join-Path $cfg.DevRoot 'replica'
    }
    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    try {
        Write-Step "$name ($($c.Zone)): snapshot on Spark..."
        $snap = Invoke-RestMethod -Method Post "$spark/collections/$name/snapshots?wait=true" -Headers $sparkHdr -TimeoutSec 3600
        $sname = $snap.result.name
        $file = Join-Path $dlDir $sname
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest "$spark/collections/$name/snapshots/$sname" -Headers $sparkHdr -OutFile $file -UseBasicParsing -TimeoutSec 7200
        $ProgressPreference = $old
        $mb = [math]::Round((Get-Item $file).Length / 1MB)
        Write-Step "$($name): downloaded $mb MB"

        $curlArgs = @('-sS', '-f', '-X', 'POST', "http://127.0.0.1:$port/collections/$name/snapshots/upload?priority=snapshot") + $localHdr + @('-F', "snapshot=@$file")
        & curl.exe @curlArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "local restore failed (curl exit $LASTEXITCODE) - is the target Qdrant running on port $port?" }

        $info = if ($nda) {
            $k = ($localHdr[1] -replace '^api-key: ', '')
            Invoke-RestMethod "http://127.0.0.1:$port/collections/$name" -Headers @{ 'api-key' = $k }
        } else { Invoke-RestMethod "http://127.0.0.1:$port/collections/$name" }
        $points = $info.result.points_count
        Write-Step "$($name): restored locally on :$port ($points points)" -Level Ok
        $manifest[$name] = [ordered]@{ zone = $c.Zone; synced = (Get-Date).ToString('s'); points = $points; port = $port }

        Invoke-RestMethod -Method Delete "$spark/collections/$name/snapshots/$sname" -Headers $sparkHdr | Out-Null
        if (-not $KeepFiles) { Remove-Item $file -Force }
    } catch { Write-Step "$($name): $($_.Exception.Message)" -Level Fail }
}
New-Item -ItemType Directory -Path $cfg.SuHome -Force | Out-Null
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Step "Manifest: $manifestPath" -Level Ok
Write-Step 'Next: tools\Set-ResearchMode.ps1 -Mode Offline when you lose the Spark.' -Level Info
