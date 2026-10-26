#Requires -Version 5.1
<#
.SYNOPSIS
    Points local research clients at the Spark's MCP servers (online) or the laptop replicas (offline).
.DESCRIPTION
    Writes the server list in the common "mcpServers" format to two places:
      D:\nda\.claude\mcp.json                     ccn (Claude Code on local models) loads it with --mcp-config
      %USERPROFILE%\.surface-ultra\mcp.local.json  for other local clients (Open WebUI via mcpo, opencode...)
    Both can contain NDA-zone servers and tokens. Never import either into cloud Claude Code or the
    Claude desktop app; cloud Claude Code is denied both folders by stage 70.

      Online  : Spark MCP servers over the tailnet (NDA-zone tokens read from D:\nda\secrets)
      Offline : ReplicaMcp commands from machine.psd1, serving the synced local collections
      Auto    : Online if the Spark answers within 3 s, otherwise Offline
.EXAMPLE
    .\Set-ResearchMode.ps1              # auto-detect
    .\Set-ResearchMode.ps1 -Mode Offline
#>
[CmdletBinding()] param([ValidateSet('Auto', 'Online', 'Offline')][string]$Mode = 'Auto')
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
$ndaReady = Test-Path $cfg.NdaSecrets

function Test-Tcp([string]$Url) {
    $u = [uri]$Url
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($u.Host, $u.Port).Wait(3000); $c.Close(); return $ok } catch { return $false }
}

if ($Mode -eq 'Auto') {
    $probe = @($cfg.SparkMcp)[0]
    $Mode = if ($probe -and (Test-Tcp $probe.Url)) { 'Online' } else { 'Offline' }
    Write-Step "Auto-detected: $Mode"
}

$servers = [ordered]@{}
if ($Mode -eq 'Online') {
    foreach ($s in $cfg.SparkMcp) {
        $tok = $null
        if ($s.Zone -eq 'nda') {
            if (-not $ndaReady) { Write-Step "$($s.Name): no NDA workspace (NdaSession.ps1 -Init) - left out" -Level Skip; continue }
            $tf = Join-Path $cfg.NdaRoot $s.TokenFile
            if (Test-Path $tf) { $tok = (Get-Content $tf -Raw).Trim() }
        } elseif ($s.TokenEnv) { $tok = [Environment]::GetEnvironmentVariable($s.TokenEnv, 'User') }
        $entry = [ordered]@{ type = 'http'; url = $s.Url }
        if ($tok) { $entry.headers = @{ Authorization = "Bearer $tok" } }
        $servers[$s.Name] = $entry
        Write-Step "$($s.Name) -> $($s.Url) [$($s.Zone)]" -Level Ok
    }
} else {
    foreach ($s in $cfg.ReplicaMcp) {
        $envMap = @{}
        if ($s.Env) { foreach ($k in $s.Env.Keys) { $envMap[$k] = $s.Env[$k] } }
        if ($s.Zone -eq 'nda') {
            if (-not $ndaReady) { Write-Step "$($s.Name): no NDA workspace - NDA replica left out" -Level Skip; continue }
            $envMap['QDRANT_API_KEY'] = (Get-Content (Join-Path $cfg.NdaSecrets 'qdrant-nda.key') -Raw).Trim()
        }
        $servers[$s.Name] = [ordered]@{ command = $s.Command; args = @($s.Args); env = $envMap }
        Write-Step "$($s.Name) -> local replica [$($s.Zone)]" -Level Ok
    }
    if ($servers.Count -eq 0) { Write-Step 'No ReplicaMcp entries configured in machine.psd1' -Level Warn }
}

$json = (@{ mcpServers = $servers } | ConvertTo-Json -Depth 6)
$out = Join-Path $cfg.SuHome 'mcp.local.json'
New-Item -ItemType Directory -Path $cfg.SuHome -Force | Out-Null
Write-Utf8NoBom -Path $out -Content $json
if ($ndaReady) {
    $ccnMcp = Join-Path (Join-Path $cfg.NdaRoot $cfg.Ccn.ConfigDirName) 'mcp.json'
    Write-Utf8NoBom -Path $ccnMcp -Content $json
    Write-Step "ccn picks up $ccnMcp on its next start" -Level Ok
}
Write-Step "Wrote $out ($Mode, $($servers.Count) servers) for other local clients." -Level Ok
Write-Step 'Do NOT load these into cloud Claude Code or the Claude desktop app.' -Level Warn
