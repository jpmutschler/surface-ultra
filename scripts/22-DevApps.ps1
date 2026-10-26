#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 22 - terminal tools, plus the apps beyond the terminal for when a project needs them.
.DESCRIPTION
    Terminal first:  Helix, ripgrep, bat, delta (git diffs), glow (render markdown, e.g. plan sections),
                     fzf. Native ARM64 builds are preferred; a tool without one installs its x64 build,
                     which runs under Prism and is reported here.
    Beyond (InstallIdes = $true in machine.psd1):
      JetBrains Toolbox  install PyCharm and CLion from it (both have native ARM64 Windows builds);
                         your paid licenses follow your JetBrains account. For Claude Code in a
                         JetBrains IDE, install the "Claude Code" plugin, then run `/ide` in a
                         terminal session to connect it (diffs + the file you are on).
      WinDbg             kernel debugging over kdnet to an x64 test box.
    Visual Studio and the WDK come from stage 20 (VisualStudio in machine.psd1).

    AI features inside IDEs (JetBrains AI Assistant, GitHub Copilot) send code to the cloud. That's fine
    in repos (no NDA material there by design); never open D:\nda in an IDE with them on.
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '22-DevApps'
Assert-Admin
$cfg = Get-MachineConfig
$failed = @()

foreach ($id in $cfg.TerminalTools) {
    if (-not (Install-WingetPackage -Id $id -AllowEmulated -WhatIfOnly:$WhatIfPreference)) { $failed += $id }
}

if ($cfg.InstallIdes) {
    foreach ($app in $cfg.IdeApps) {
        if (Install-WingetPackage -Id $app.Id -AllowEmulated -WhatIfOnly:$WhatIfPreference) { Write-Step "$($app.Id): $($app.Note)" -Level Info }
        else { $failed += $app.Id }
    }
} else { Write-Step 'InstallIdes = $false - JetBrains Toolbox and WinDbg skipped' -Level Skip }
Update-SessionPath

# git: delta as the pager, if it installed
if ((Get-Command delta -ErrorAction SilentlyContinue) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    & git config --global core.pager delta
    & git config --global interactive.diffFilter 'delta --color-only'
    & git config --global delta.navigate true
    Write-Step 'git uses delta for diffs' -Level Ok
}

# what's native and what's emulated
foreach ($c in @('hx', 'rg', 'bat', 'delta', 'glow', 'fzf', 'just')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Write-Step "$c not on PATH (new shell may be needed)" -Level Warn; continue }
    $arch = Get-PeArchitecture -Path $cmd.Source
    Write-Step ("{0,-6} {1}  [{2}]" -f $c, $cmd.Source, $arch) -Level $(if ($arch -eq 'ARM64') { 'Ok' } else { 'Info' })
}

if ($failed.Count) { Write-Step "Failed: $($failed -join ', ')" -Level Fail; exit 1 }
Write-Step 'Stage 22 complete' -Level Ok
exit 0
