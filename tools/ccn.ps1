#Requires -Version 5.1
<#
.SYNOPSIS
    ccn - Claude Code on local models, for NDA research ("NDA | LOCAL", the red terminal tab).
.DESCRIPTION
    Runs the same Claude Code you use every day, as a separate profile:
      * CLAUDE_CONFIG_DIR = D:\nda\.claude - its own settings, MCP list and session transcripts,
        all inside the NDA workspace (cloud Claude Code is denied that folder)
      * ANTHROPIC_BASE_URL = the NDA gateway (LiteLLM on 127.0.0.1:4001, no trace export), with that
        gateway's key via apiKeyHelper - never your Max login
      * telemetry, error reports, /feedback, surveys and the WebFetch preflight are off; WebSearch is
        denied (it runs on Anthropic's servers)
      * MCP servers from D:\nda\.claude\mcp.json (written by tools\Set-ResearchMode.ps1): the Spark's
        nda-rag + specs online, the laptop replicas offline
      * model: spark/research when the Spark answers, sc-research otherwise (-Offline forces it)

    Refuses to start unless the profile's gateway URL is loopback, the NDA gateway is running
    (tools\NdaSession.ps1 -Start) and the current folder is inside the NDA workspace (-AnyDir overrides).
    ccn's own switches: -Offline, -AnyDir, -Shell, -Model <name>. Everything else goes to claude unchanged
    (so `ccn -p "..."`, `ccn -c`, `ccn --resume` work as they do with claude).
.EXAMPLE
    ccn                              # interactive session
    ccn -Offline
    ccn -p "list the open questions in plan\review.md"
    ccn -Model sc-analyst
    . .\tools\ccn.ps1 -Shell         # turn THIS shell into an NDA shell (the Windows Terminal profile does this)
#>
# Plain script (no param block) so claude's own flags pass through untouched.
$Offline = $false; $AnyDir = $false; $Shell = $false; $ModelOverride = $null
$ClaudeArgs = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = "$($args[$i])"
    switch -Regex ($a) {
        '^-Offline$' { $Offline = $true; continue }
        '^-AnyDir$'  { $AnyDir = $true; continue }
        '^-Shell$'   { $Shell = $true; continue }
        '^-Model$'   { $i++; $ModelOverride = "$($args[$i])"; continue }
        '^--$'       { continue }
        default      { $ClaudeArgs.Add($a) }
    }
}
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$ccnDir = Join-Path $cfg.NdaRoot $cfg.Ccn.ConfigDirName
$settingsFile = Join-Path $ccnDir 'settings.json'
$mcpFile = Join-Path $ccnDir 'mcp.json'

function Stop-Ccn([string]$Why) { Write-Step "ccn: $Why" -Level Fail; if ($Shell) { return } else { exit 1 } }

# ---------------------------------------------------------------- preconditions
if (-not (Test-Path $settingsFile)) { Stop-Ccn "no profile at $ccnDir - run scripts\70-ClaudeCode.ps1"; return }
$settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
$base = "$($settings.env.ANTHROPIC_BASE_URL)"
$gwHost = if ($base) { ([uri]$base).Host.Trim('[', ']').ToLower() } else { '' }
if ($gwHost -notin @('127.0.0.1', 'localhost', '::1')) { Stop-Ccn "profile gateway '$base' is not loopback - refusing"; return }
$exe = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $exe) { Stop-Ccn 'claude not found - run scripts\70-ClaudeCode.ps1'; return }

$gatewayUp = Test-TcpPort -HostName '127.0.0.1' -Port $cfg.NdaLiteLLMPort
if (-not $gatewayUp -and -not $Shell) { Stop-Ccn "NDA gateway not running on :$($cfg.NdaLiteLLMPort) - tools\NdaSession.ps1 -Start"; return }

$here = (Get-Location).ProviderPath
$ndaFull = [IO.Path]::GetFullPath($cfg.NdaRoot).TrimEnd('\')
$inNda = $here -eq $ndaFull -or $here.StartsWith("$ndaFull\", [StringComparison]::OrdinalIgnoreCase)
if (-not $inNda -and -not $AnyDir -and -not $Shell) {
    Stop-Ccn "run ccn from inside $ndaFull (e.g. $ndaFull\projects\<name>), or pass -AnyDir"; return
}

# ---------------------------------------------------------------- model
$model = $cfg.Ccn.ModelOffline
if ($ModelOverride) { $model = $ModelOverride }
elseif (-not $Offline) {
    $u = [uri]$cfg.SparkLiteLLMUrl
    if (Test-TcpPort -HostName $u.Host -Port $u.Port -TimeoutMs 2000) { $model = $cfg.Ccn.ModelOnline }
}

# ---------------------------------------------------------------- environment for this profile
$saved = @{}
foreach ($k in @('CLAUDE_CONFIG_DIR', 'ANTHROPIC_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'SU_NDA_SESSION')) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
}
$env:CLAUDE_CONFIG_DIR = $ccnDir
$env:ANTHROPIC_MODEL = $model
$env:CLAUDE_CODE_SUBAGENT_MODEL = $model
$env:SU_NDA_SESSION = '1'
foreach ($k in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL')) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
$mcpArgs = @()
if (Test-Path $mcpFile) { $mcpArgs = @('--mcp-config', $mcpFile) }
else { Write-Step "ccn: no $mcpFile yet - run tools\Set-ResearchMode.ps1 for the nda-rag/specs servers" -Level Warn }

try { $Host.UI.RawUI.WindowTitle = "NDA | LOCAL  ccn  [$model]" } catch { }
Write-Host ''
Write-Host "  NDA | LOCAL  Claude Code on $model via 127.0.0.1:$($cfg.NdaLiteLLMPort)  (config $ccnDir)" -ForegroundColor White -BackgroundColor DarkRed
if (-not $gatewayUp) { Write-Host "  NDA gateway is not running yet: tools\NdaSession.ps1 -Start" -ForegroundColor Yellow }
Write-Host ''

if ($Shell) {
    # This shell is now an NDA shell: `claude` here is the local profile.
    $global:SuCcnExe = $exe
    $global:SuCcnMcpArgs = $mcpArgs
    function global:claude { & $global:SuCcnExe @global:SuCcnMcpArgs @args }
    function global:prompt { Write-Host '[NDA LOCAL] ' -NoNewline -ForegroundColor Red; "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
    return
}

$ca = $ClaudeArgs.ToArray()
try {
    & $exe @mcpArgs @ca
    $rc = $LASTEXITCODE
} finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$k" $saved[$k] }
    }
}
exit $rc
