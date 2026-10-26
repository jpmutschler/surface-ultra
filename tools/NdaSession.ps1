#Requires -Version 5.1
<#
.SYNOPSIS
    NDA workspace and research sessions (rules-based; no encrypted vault).
.DESCRIPTION
    NDA SDKs and documents are research material only. They live in the NDA workspace
    (D:\nda by default), outside every project repo and outside Claude Code's working
    directories, and are never copied into a project. Projects ship our own API, built
    from what we learn here.

      -Init    create the workspace layout and the NDA keys (idempotent)
      -Start   rebuild the nda_guard index from the term lists, start the NDA Qdrant and the NDA gateway
      -Stop    stop both
      -Status  show workspace, index and service state

    The NDA gateway (LiteLLM on 127.0.0.1:4001) is what `ccn` - Claude Code on local models - and the
    planning pipeline talk to. It has no trace export and uses the Spark's no-content-logging key.

    Layout:
      D:\nda\terms\<vendor>.txt         protected terms, "REAL => ALIAS" per line
      D:\nda\terms\candidates\<vendor>.txt   suggestions from 'plan terms' (inert until you move lines over)
      D:\nda\docs\<vendor>\             vendor SDKs, PDFs, headers
      D:\nda\projects\<name>\           research projects (tools\plan)
      D:\nda\replica\                   NDA Qdrant snapshot files (pre-trip sync)
      D:\nda\secrets\                   Spark NDA tokens, NDA Qdrant + gateway keys
      D:\nda\.claude\                   ccn's Claude Code profile (settings, MCP list, transcripts)
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Init')][switch]$Init,
    [Parameter(ParameterSetName = 'Start')][switch]$Start,
    [Parameter(ParameterSetName = 'Stop')][switch]$Stop,
    [Parameter(ParameterSetName = 'Status')][switch]$Status
)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$guard = Join-Path $cfg.SuHome 'tools\nda_guard.py'
if (-not (Test-Path $guard)) { $guard = Join-Path $PSScriptRoot 'nda_guard.py' }
$keyFile = Join-Path $cfg.NdaSecrets 'qdrant-nda.key'
$gwKeyFile = Join-Path $cfg.NdaSecrets 'litellm-nda.key'                # NDA gateway master key (ccn uses it)
$sparkKeyFile = Join-Path $cfg.NdaSecrets 'spark-litellm-nda.key'       # the Spark's 'ultra-nda' key (no content logging)

function Invoke-Guard([string[]]$GuardArgs) {
    $py = Get-SuPython
    if (-not $py) { Write-Step 'uv-managed Python not found - run stage 20' -Level Warn; return }
    $env:NDA_TERMS_DIR = $cfg.NdaTermsDir
    & $py -I $guard @GuardArgs
}

function Read-Secret([string]$Path) { if (Test-Path $Path) { (Get-Content $Path -Raw).Trim() } else { '' } }

function Set-NdaServices([switch]$Up) {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return }
    if ($Up) {
        $qk = Read-Secret $keyFile; $gk = Read-Secret $gwKeyFile; $sk = Read-Secret $sparkKeyFile
        if (-not $sk) { $sk = 'unset'; Write-Step "No Spark key in $sparkKeyFile - spark/* through the NDA gateway will 401" -Level Warn }
        $envs = "QDRANT_NDA_KEY='$qk' NDA_QDRANT_PORT=$($cfg.NdaQdrantPort) LITELLM_NDA_KEY='$gk' SPARK_NDA_LITELLM_KEY='$sk' NDA_LITELLM_PORT=$($cfg.NdaLiteLLMPort)"
        $rc = Invoke-Wsl -Distro $cfg.WslDistro -Command "cd ~/surface-ultra 2>/dev/null && $envs docker compose --profile nda up -d qdrant-nda litellm-nda"
        if ($rc -eq 0) { Write-Step "NDA Qdrant on 127.0.0.1:$($cfg.NdaQdrantPort), NDA gateway on 127.0.0.1:$($cfg.NdaLiteLLMPort)" -Level Ok }
        else { Write-Step 'NDA services not started (run stage 60 first)' -Level Warn }
    } else {
        [void](Invoke-Wsl -Distro $cfg.WslDistro -Command 'cd ~/surface-ultra 2>/dev/null && docker compose --profile nda stop qdrant-nda litellm-nda')
        Write-Step 'NDA Qdrant and NDA gateway stopped' -Level Ok
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Init' {
        foreach ($d in @('terms', 'docs', 'projects', 'replica', 'secrets')) {
            New-Item -ItemType Directory -Path (Join-Path $cfg.NdaRoot $d) -Force | Out-Null
        }
        $readme = Join-Path $cfg.NdaTermsDir 'README.txt'
        if (-not (Test-Path $readme)) {
            Set-Content -Path $readme -Encoding UTF8 -Value @(
                '# One file per vendor: <vendor>.txt. One protected term per line, optional alias:'
                '#   ORCA7 => SWITCH_A'
                '#   Fabric Link Monitor => FEATURE_FLM'
                '# Include: codenames, part numbers, register/field names, feature names, unreleased specs.'
                '# Avoid short generic words (false positives). Run NdaSession.ps1 -Start to rebuild the index.'
            )
        }
        if (-not (Test-Path $keyFile)) { Set-Content -Path $keyFile -Value (New-RandomSecret) -Encoding ASCII }
        if (-not (Test-Path $gwKeyFile)) { Set-Content -Path $gwKeyFile -Value ('sk-' + (New-RandomSecret)) -Encoding ASCII }
        if (-not (Test-Path $sparkKeyFile)) {
            Set-Content -Path $sparkKeyFile -Value '' -Encoding ASCII
            Write-Step "Paste the Spark's 'ultra-nda' LiteLLM key into $sparkKeyFile (see the Spark overhaul plan, C5)" -Level Info
        }
        foreach ($s in @($cfg.SparkMcp | Where-Object { $_.Zone -eq 'nda' -and $_.TokenFile })) {
            $tf = Join-Path $cfg.NdaRoot $s.TokenFile
            if (-not (Test-Path $tf)) { Set-Content -Path $tf -Value '' -Encoding ASCII; Write-Step "Paste the Spark token for '$($s.Name)' into $tf" -Level Info }
        }
        if ($cfg.NdaRoot -like "$($cfg.DevRoot)\src*") { Write-Step 'NDA workspace is inside the repo tree - move it out' -Level Fail }
        Write-Step "NDA workspace ready at $($cfg.NdaRoot)" -Level Ok
    }
    'Start' {
        if (-not (Test-Path $cfg.NdaTermsDir)) { throw "No NDA workspace - run with -Init first" }
        Invoke-Guard @('build')
        Set-NdaServices -Up
        Write-Step 'NDA session on. Research with ccn (red tab) or a local client; cloud Claude Code is denied the workspace and these endpoints.' -Level Info
    }
    'Stop' { Set-NdaServices }
    default {
        Write-Step ("Workspace  : {0} ({1})" -f $cfg.NdaRoot, $(if (Test-Path $cfg.NdaRoot) { 'exists' } else { 'missing - run -Init' }))
        Invoke-Guard @('status')
        $up = Test-TcpPort -HostName '127.0.0.1' -Port $cfg.NdaQdrantPort
        Write-Step ("NDA Qdrant : {0}" -f $(if ($up) { "running on :$($cfg.NdaQdrantPort)" } else { 'stopped' }))
        $gw = Test-TcpPort -HostName '127.0.0.1' -Port $cfg.NdaLiteLLMPort
        Write-Step ("NDA gateway: {0}" -f $(if ($gw) { "running on :$($cfg.NdaLiteLLMPort)" } else { 'stopped' }))
    }
}
