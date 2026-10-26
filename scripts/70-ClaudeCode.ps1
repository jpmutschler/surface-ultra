#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 70 - Claude Code (Max plan login), agent personas, MCP servers, local-model helpers.
.DESCRIPTION
    Installs Claude Code with the official native installer (win32-arm64 is supported) and sets up
    TWO profiles of it:

      claude  (cloud, your Max login, %USERPROFILE%\.claude)
              building and testing in repos. NDA guardrails: blockReadsOutsideWorkingDirectories,
              deny rules for the NDA workspace, nda_guard hooks on prompts and tool calls, the standing
              NDA rule in the user-level CLAUDE.md. A profile function refuses to start it inside D:\nda.
      ccn     (local models, D:\nda\.claude)
              NDA research and planning. Talks only to the NDA gateway on loopback with that gateway's
              key, nonessential traffic off, its own MCP list (nda-rag, specs) and transcripts, and may
              not edit the repo tree. Anthropic does not support non-Claude models behind a gateway;
              it works, but expect slower, less reliable tool use than with Claude.

    Also: agent personas, cloud-safe MCP servers, a red "NDA | LOCAL" Windows Terminal profile, and
    PowerShell helpers (ccn, nda, llm-status, llm-unload).
#>
[CmdletBinding(SupportsShouldProcess)] param([switch]$WithOpencode)   # opencode: optional extra local-model harness
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '70-ClaudeCode'
$cfg = Get-MachineConfig
Update-SessionPath

# ---------------------------------------------------------------- install
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Step "Claude Code present: $(& claude --version)" -Level Skip
} elseif ($PSCmdlet.ShouldProcess('Claude Code', 'native install')) {
    Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
    $bin = Join-Path $env:USERPROFILE '.local\bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$bin*") { [Environment]::SetEnvironmentVariable('Path', "$userPath;$bin", 'User') }
    Update-SessionPath
    if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Step "Installed: $(& claude --version)" -Level Ok }
    else { Write-Step 'Install finished but claude not on PATH - open a new terminal' -Level Warn }
}
Write-Step 'First run: type  claude  and log in with your Max account in the browser.' -Level Info

# ---------------------------------------------------------------- NDA guardrails (standing rule)
# Fence Claude's file tools to the session's working directories, deny the NDA workspace and the
# guard's key/index outright, run nda_guard on every prompt and on
# file/shell/web/MCP tool calls, and put the NDA rule in the user-level CLAUDE.md (all projects).
$py = Get-SuPython
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not $py) {
    Write-Step 'uv-managed Python not found - run stage 20 first; NDA guardrails NOT installed' -Level Fail
    exit 1
}
$suTools = Join-Path $cfg.SuHome 'tools'
New-Item -ItemType Directory -Path $suTools -Force | Out-Null
Copy-Item (Join-Path (Get-RepoRoot) 'tools\nda_guard.py') $suTools -Force
$guard = Join-Path $suTools 'nda_guard.py'
# Windows paths are matched in POSIX form: D:\nda -> //d/nda
$ndaPosix = '//' + $cfg.NdaRoot.Substring(0, 1).ToLower() + '/' + ($cfg.NdaRoot.Substring(3) -replace '\\', '/')
$csArgs = @((Join-Path (Get-RepoRoot) 'tools\claude_settings.py'),
    '--claude-dir', (Join-Path $env:USERPROFILE '.claude'), '--python', $py, '--guard', $guard,
    '--deny', "Read($ndaPosix/**)", '--deny', "Edit($ndaPosix/**)",
    '--deny', 'Read(~/.surface-ultra/**)', '--deny', 'Edit(~/.surface-ultra/**)')
if (Test-Path $gitBash) { $csArgs += @('--git-bash', $gitBash) }
& $py -I @csArgs
if ($LASTEXITCODE -ne 0) { Write-Step 'claude_settings.py failed' -Level Fail; exit 1 }
Set-UserEnv -Name 'NDA_TERMS_DIR' -Value $cfg.NdaTermsDir
Write-Step "NDA guard: reads fenced to working dirs, deny $ndaPosix/**, hooks on prompts + tools, rule in ~/.claude/CLAUDE.md" -Level Ok

# ---------------------------------------------------------------- ccn: the local-model profile
$ccnDir = Join-Path $cfg.NdaRoot $cfg.Ccn.ConfigDirName
$srcRoot = Join-Path $cfg.DevRoot 'src'
$srcPosix = '//' + $srcRoot.Substring(0, 1).ToLower() + '/' + ($srcRoot.Substring(3) -replace '\\', '/')
$lpArgs = @((Join-Path (Get-RepoRoot) 'tools\claude_settings.py'), '--profile', 'local',
    '--claude-dir', $ccnDir, '--python', $py,
    '--base-url', "http://127.0.0.1:$($cfg.NdaLiteLLMPort)",
    '--key-file', (Join-Path $cfg.NdaSecrets 'litellm-nda.key'),
    '--model', $cfg.Ccn.ModelOffline, '--fast-model', $cfg.Ccn.FastModel,
    '--deny', "Edit($srcPosix/**)")
if (Test-Path $gitBash) { $lpArgs += @('--git-bash', $gitBash) }
& $py -I @lpArgs
if ($LASTEXITCODE -ne 0) { Write-Step 'ccn profile not written' -Level Fail; exit 1 }
& (Join-Path (Get-RepoRoot) 'tools\Set-ResearchMode.ps1')   # writes D:\nda\.claude\mcp.json
Write-Step "ccn profile: $ccnDir -> NDA gateway 127.0.0.1:$($cfg.NdaLiteLLMPort), no Anthropic traffic, no repo edits" -Level Ok

# Windows Terminal: a red "NDA | LOCAL" profile that opens an NDA shell in D:\nda\projects
$wtFrag = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\SurfaceUltra'
New-Item -ItemType Directory -Path $wtFrag -Force | Out-Null
$shellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$ccnScript = Join-Path (Get-RepoRoot) 'tools\ccn.ps1'
$frag = [ordered]@{ profiles = @([ordered]@{
    guid                     = '{6f3c1d2a-7b4e-4c8a-9d1e-5a2b3c4d5e6f}'
    name                     = 'NDA | LOCAL (ccn)'
    commandline              = "$shellExe -NoLogo -NoExit -Command `". '$ccnScript' -Shell`""
    startingDirectory        = (Join-Path $cfg.NdaRoot 'projects')
    tabColor                 = $cfg.Ccn.TabColor
    tabTitle                 = 'NDA | LOCAL'
    suppressApplicationTitle = $true
}) }
Write-Utf8NoBom -Path (Join-Path $wtFrag 'ccn.json') -Content ($frag | ConvertTo-Json -Depth 5)
Write-Step 'Windows Terminal profile "NDA | LOCAL (ccn)" added (restart Terminal to see it)' -Level Ok

# ---------------------------------------------------------------- personas
if ($cfg.AgentPersonaSource -and (Test-Path $cfg.AgentPersonaSource)) {
    $agents = Join-Path $env:USERPROFILE '.claude\agents'
    New-Item -ItemType Directory -Path $agents -Force | Out-Null
    Copy-Item (Join-Path $cfg.AgentPersonaSource '*.md') $agents -Force
    Write-Step "Copied agent personas to $agents" -Level Ok
} else { Write-Step 'AgentPersonaSource not set - copy Vega / Dr. Lane Prescott / I2C-I3C personas manually or set it in machine.psd1' -Level Skip }

# ---------------------------------------------------------------- MCP servers (cloud-safe only)
if (Get-Command claude -ErrorAction SilentlyContinue) {
    foreach ($s in $cfg.ClaudeMcpServers) {
        $mcpArgs = @('mcp', 'add', '--scope', 'user', $s.Name, '--', $s.Command) + $s.Args
        & claude @mcpArgs
        if ($LASTEXITCODE -eq 0) { Write-Step "MCP server '$($s.Name)' registered" -Level Ok } else { Write-Step "MCP add '$($s.Name)' failed" -Level Warn }
    }
    foreach ($s in $cfg.SparkMcp) {
        if (-not $s.ClaudeCode) { Write-Step "Spark MCP '$($s.Name)' ($($s.Zone)) kept local-only" -Level Skip; continue }
        if ($s.Zone -eq 'nda') { Write-Step "REFUSED: '$($s.Name)' is in the nda zone and can never be registered with Claude Code" -Level Fail; continue }
        $tok = [Environment]::GetEnvironmentVariable($s.TokenEnv, 'User')
        $mcpArgs = @('mcp', 'add', '--transport', 'http', '--scope', 'user', $s.Name, $s.Url)
        if ($tok) { $mcpArgs += @('--header', "Authorization: Bearer $tok") }
        & claude @mcpArgs
        if ($LASTEXITCODE -eq 0) { Write-Step "Spark MCP '$($s.Name)' registered with Claude Code ($($s.Zone))" -Level Ok }
    }
}

# ---------------------------------------------------------------- opencode (optional local-model harness)
if ($WithOpencode) {
    & npm install -g opencode-ai
    if ($LASTEXITCODE -eq 0) { Write-Step 'opencode installed (point it at http://127.0.0.1:4000/v1)' -Level Ok }
    else { Write-Step 'opencode install failed - check for a win32-arm64 build' -Level Warn }
}

# ---------------------------------------------------------------- profile helpers
$marker = '# >>> surface-ultra helpers >>>'
$ndaRootLit = $cfg.NdaRoot
$helpers = @"
$marker
function ccn {
    # Claude Code on local models for NDA research - see tools\ccn.ps1
    & '$ccnScript' @args
}
function claude {
    # cloud Claude Code (Max login), except: refuse inside the NDA workspace unless this is a ccn shell
    `$exe = (Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    `$here = (Get-Location).ProviderPath
    `$nda = '$ndaRootLit'
    if ((`$here -eq `$nda -or `$here.StartsWith("`$nda\", [StringComparison]::OrdinalIgnoreCase)) -and `$env:CLAUDE_CONFIG_DIR -ne '$ccnDir') {
        Write-Host 'Refusing: cloud Claude Code inside the NDA workspace. Use ccn here.' -ForegroundColor Red
        return
    }
    & `$exe @args
}
function llm-status {
    try { (Invoke-RestMethod http://$($cfg.LlamaSwapListen)/running).running | Format-Table model, state -AutoSize } catch { 'llama-swap not reachable' }
    nvidia-smi '--query-gpu=name,driver_version,memory.used,memory.total,power.draw' '--format=csv'
}
function nda {
    # nda redact brief.md brief.cloud.md | nda restore claude_out.py local.py | nda scan <path> | nda status
    & '$py' -I '$guard' @args
}
function llm-unload { Invoke-RestMethod http://$($cfg.LlamaSwapListen)/unload | Out-Null; 'unloaded all models' }
# <<< surface-ultra helpers <<<
"@
foreach ($prof in @($PROFILE.CurrentUserAllHosts, (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'))) {
    $dir = Split-Path $prof
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = if (Test-Path $prof) { Get-Content $prof -Raw } else { '' }
    if ($existing -match [regex]::Escape($marker)) {
        $existing = [regex]::Replace($existing, '(?s)# >>> surface-ultra helpers >>>.*?# <<< surface-ultra helpers <<<\r?\n?', '')
    }
    Set-Content -Path $prof -Value ($existing.TrimEnd() + "`r`n`r`n" + $helpers) -Encoding UTF8
    Write-Step "Profile helpers written to $prof" -Level Ok
}
Write-Step 'Stage 70 complete' -Level Ok
exit 0
