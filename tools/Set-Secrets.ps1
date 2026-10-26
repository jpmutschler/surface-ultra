#Requires -Version 5.1
<#
.SYNOPSIS
    Day one: paste the keys from your password manager into the places the build reads them.
.DESCRIPTION
    Prompts for each key with hidden input (nothing lands in shell history or on screen) and writes it:
      user env vars   everyday keys the services read (SPARK_LITELLM_KEY, SPARK_QDRANT_KEY, Langfuse, ...)
      D:\nda\secrets  NDA-zone keys - the Spark's no-logging 'ultra-nda' LiteLLM key and the nda-rag MCP
                      token. Cloud Claude Code is denied this folder.
    Press Enter on a prompt to skip it and keep what's already there. -List shows which are set (never the
    values). Keys this build generates itself (the laptop's LITELLM_MASTER_KEY, the NDA gateway key and the
    NDA Qdrant key in D:\nda\secrets) are listed too, so you can copy them INTO your password manager.

    After changing Spark keys, re-run scripts\60-Services.ps1 (everyday gateway) and, for the NDA keys,
    tools\NdaSession.ps1 -Stop then -Start.
.EXAMPLE
    .\Set-Secrets.ps1 -List
    .\Set-Secrets.ps1                         # prompt for every key
    .\Set-Secrets.ps1 -Only SPARK_LITELLM_KEY,spark-litellm-nda.key
#>
[CmdletBinding()] param([switch]$List, [string[]]$Only)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig

$secrets = @(
    @{ Name = 'SPARK_LITELLM_KEY';      Kind = 'Env'; What = "Spark LiteLLM key for everyday spark/* calls (laptop gateway :4000)" }
    @{ Name = 'spark-litellm-nda.key';  Kind = 'Nda'; What = "Spark LiteLLM 'ultra-nda' key - content logging off (NDA gateway :4001, ccn)" }
    @{ Name = 'spark-nda-rag.token';    Kind = 'Nda'; What = 'Spark nda-rag MCP bearer token' }
    @{ Name = 'SPARK_MCP_SPECS_TOKEN';  Kind = 'Env'; What = 'Spark specs MCP bearer token' }
    @{ Name = 'SPARK_QDRANT_KEY';       Kind = 'Env'; What = 'Spark Qdrant key (public collections, replica sync)' }
    @{ Name = 'LANGFUSE_PUBLIC_KEY';    Kind = 'Env'; What = 'Langfuse on the Spark (everyday traces only)' }
    @{ Name = 'LANGFUSE_SECRET_KEY';    Kind = 'Env'; What = 'Langfuse on the Spark' }
    @{ Name = 'HF_TOKEN';               Kind = 'Env'; What = 'Hugging Face token (gated model downloads; optional)' }
)
$generated = @(
    @{ Name = 'LITELLM_MASTER_KEY'; Kind = 'Env'; What = 'laptop everyday gateway master key (stage 60)' }
    @{ Name = 'litellm-nda.key';    Kind = 'Nda'; What = 'laptop NDA gateway key (NdaSession -Init)' }
    @{ Name = 'qdrant-nda.key';     Kind = 'Nda'; What = 'laptop NDA Qdrant key (NdaSession -Init)' }
)

function Test-Set($s) {
    if ($s.Kind -eq 'Env') { return [bool][Environment]::GetEnvironmentVariable($s.Name, 'User') }
    $f = Join-Path $cfg.NdaSecrets $s.Name
    return (Test-Path $f) -and ((Get-Content $f -Raw -ErrorAction SilentlyContinue) -as [string]).Trim().Length -gt 0
}
function Where-Stored($s) { if ($s.Kind -eq 'Env') { "user env $($s.Name)" } else { Join-Path $cfg.NdaSecrets $s.Name } }

if ($List) {
    Write-Step 'From your password manager:' -Level Head
    foreach ($s in $secrets) { Write-Step ("{0,-24} {1,-6} {2}" -f $s.Name, $(if (Test-Set $s) { 'set' } else { 'unset' }), $s.What) -Level $(if (Test-Set $s) { 'Ok' } else { 'Warn' }) }
    Write-Step 'Generated here (copy them into your password manager):' -Level Head
    foreach ($s in $generated) { Write-Step ("{0,-24} {1,-6} {2}  [{3}]" -f $s.Name, $(if (Test-Set $s) { 'set' } else { 'unset' }), $s.What, (Where-Stored $s)) -Level Info }
    return
}

$todo = if ($Only) { @($secrets | Where-Object { $Only -contains $_.Name }) } else { $secrets }
if ($Only -and $todo.Count -ne @($Only).Count) { Write-Step "Unknown name(s): $((@($Only) | Where-Object { $_ -notin $secrets.Name }) -join ', ')" -Level Warn }
if (@($todo | Where-Object Kind -eq 'Nda').Count -and -not (Test-Path $cfg.NdaSecrets)) {
    Write-Step "No NDA workspace yet - run tools\NdaSession.ps1 -Init (stage 65) first" -Level Fail; exit 1
}
$changed = @()
foreach ($s in $todo) {
    $state = if (Test-Set $s) { 'set - Enter keeps it' } else { 'unset - Enter skips' }
    $sec = Read-Host -AsSecureString ("{0} ({1}) [{2}]" -f $s.Name, $s.What, $state)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $val = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $val) { continue }
    $val = $val.Trim()
    if ($s.Kind -eq 'Env') {
        [Environment]::SetEnvironmentVariable($s.Name, $val, 'User')
        Set-Item "Env:$($s.Name)" $val
    } else {
        Set-Content -Path (Join-Path $cfg.NdaSecrets $s.Name) -Value $val -Encoding ASCII -NoNewline
    }
    $changed += $s.Name
    Write-Step "$($s.Name) saved to $(Where-Stored $s)" -Level Ok
}
$val = $null
if ($changed | Where-Object { $_ -match '^(SPARK_LITELLM_KEY|LANGFUSE_|HF_TOKEN)' }) { Write-Step 'Re-run scripts\60-Services.ps1 so the everyday gateway picks them up' -Level Info }
if ($changed | Where-Object { $_ -match 'nda' }) { Write-Step 'NDA keys changed: tools\NdaSession.ps1 -Stop, then -Start, then tools\Set-ResearchMode.ps1' -Level Info }
if (-not $changed) { Write-Step 'Nothing changed' -Level Skip }
