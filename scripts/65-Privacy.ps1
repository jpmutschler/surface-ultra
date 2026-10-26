#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 65 - NDA privacy baseline: NDA workspace, guard index, and Windows' own cloud paths.
.DESCRIPTION
    Standing rules (all NDA projects):
      * NDA SDKs/docs are research material only. They live in the NDA workspace (D:\nda),
        outside every project and outside Claude Code's working directories, and never ship.
      * Projects ship our own API; anything vendor-specific sits in a thin binding layer.
      * Best-effort obfuscation before anything reaches a Claude cloud model.

    This stage:
      * creates the NDA workspace (tools\NdaSession.ps1 -Init) and builds the guard index
      * installs nda_guard into %USERPROFILE%\.surface-ultra\tools
      * sets NDA_GUARD_ENDPOINTS (NDA workspace paths + NDA endpoints the Claude Code hook blocks)
      * Recall: left to you by default (on-device), or off by policy with RecallPolicy = 'Disable'
      * checks that OneDrive is not backing up Desktop/Documents, the dev root or the NDA workspace
      * checks the Claude desktop app's MCP config for NDA-zone servers
    Stage 70 wires the guard into Claude Code; stage 80 adds pre-commit hooks to repos.
    Disk encryption (BitLocker device encryption) is left to you.
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '65-Privacy'
Assert-Admin
$cfg = Get-MachineConfig
$warn = 0

# ---------------------------------------------------------------- guard install
$suTools = Join-Path $cfg.SuHome 'tools'
New-Item -ItemType Directory -Path $suTools -Force | Out-Null
Copy-Item (Join-Path (Get-RepoRoot) 'tools\nda_guard.py') $suTools -Force
Set-UserEnv -Name 'NDA_TERMS_DIR' -Value $cfg.NdaTermsDir
Write-Step "nda_guard installed to $suTools" -Level Ok

# ---------------------------------------------------------------- NDA workspace
& (Join-Path (Get-RepoRoot) 'tools\NdaSession.ps1') -Init
if ($cfg.NdaRoot -like "$($cfg.DevRoot)\src*") { Write-Step 'NDA workspace sits inside the repo tree - move it out' -Level Fail; $warn++ }
$py = Get-SuPython
if ($py) { $env:NDA_TERMS_DIR = $cfg.NdaTermsDir; & $py -I (Join-Path $suTools 'nda_guard.py') build }

# Paths and endpoints a cloud session may never touch (checked by the Claude Code PreToolUse hook)
$drive = $cfg.NdaRoot.Substring(0, 1).ToLower()
$rest = $cfg.NdaRoot.Substring(3) -replace '\\', '/'
$ep = @($cfg.NdaRoot, "$($drive):/$rest", "/mnt/$drive/$rest",
        "127.0.0.1:$($cfg.NdaQdrantPort)", "localhost:$($cfg.NdaQdrantPort)",
        "127.0.0.1:$($cfg.NdaLiteLLMPort)", "localhost:$($cfg.NdaLiteLLMPort)")
foreach ($s in @($cfg.SparkMcp | Where-Object { $_.Zone -eq 'nda' })) { $ep += ([uri]$s.Url).Authority }
Set-UserEnv -Name 'NDA_GUARD_ENDPOINTS' -Value ($ep -join ',')

# ---------------------------------------------------------------- Recall
# Recall is opt-in and on-device (snapshots never leave the laptop), so it doesn't break the cloud
# rule. Leave it to Windows unless RecallPolicy = 'Disable'.
$k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
if ($cfg.RecallPolicy -eq 'Disable') {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name DisableAIDataAnalysis -Type DWord -Value 1
    Write-Step 'Recall snapshots disabled by policy (RecallPolicy = Disable)' -Level Ok
} else {
    $cur = (Get-ItemProperty $k -ErrorAction SilentlyContinue).DisableAIDataAnalysis
    if ($cur -eq 1) { Remove-ItemProperty -Path $k -Name DisableAIDataAnalysis -ErrorAction SilentlyContinue; Write-Step 'Removed an earlier Recall-off policy (RecallPolicy = UserChoice)' -Level Ok }
    Write-Step 'Recall left to you (Settings > Privacy & security > Recall & snapshots, if offered on this unit)' -Level Info
}

# ---------------------------------------------------------------- OneDrive
$paths = [ordered]@{
    Desktop      = [Environment]::GetFolderPath('Desktop')
    Documents    = [Environment]::GetFolderPath('MyDocuments')
    DevRoot      = $cfg.DevRoot
    NdaWorkspace = $cfg.NdaRoot
}
foreach ($n in $paths.Keys) {
    if ($paths[$n] -match 'OneDrive') {
        Write-Step "$n is inside OneDrive ($($paths[$n])). Stop backing it up: OneDrive > Settings > Sync and backup > Manage backup." -Level Warn
        $warn++
    } else { Write-Step "$n not synced by OneDrive" -Level Ok }
}
if ((Get-RepoRoot) -match 'OneDrive') { Write-Step "This repo lives in OneDrive ($(Get-RepoRoot)) - move it to $($cfg.DevRoot)\src" -Level Warn; $warn++ }

# ---------------------------------------------------------------- Claude desktop app MCP config
$cd = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (Test-Path $cd) {
    $raw = Get-Content $cd -Raw
    foreach ($s in @($cfg.SparkMcp | Where-Object { $_.Zone -eq 'nda' })) {
        if ($raw -match [regex]::Escape(([uri]$s.Url).Authority) -or $raw -match [regex]::Escape($s.Name)) {
            Write-Step "Claude desktop config references NDA-zone server '$($s.Name)' - remove it from $cd" -Level Fail; $warn++
        }
    }
    Write-Step 'Claude desktop MCP config checked' -Level Ok
}

Write-Step 'Rule of thumb: NDA research with ccn (tools\NdaSession.ps1 -Start, red tab); cloud Claude Code only in project folders.' -Level Info
if ($warn) { Write-Step "$warn privacy item(s) need attention" -Level Warn }
Write-Step 'Stage 65 complete' -Level Ok
exit 0
