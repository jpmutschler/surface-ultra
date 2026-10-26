#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 25 - install the apps you staged in .\apps (gitignored).
.DESCRIPTION
      *.msix / *.appx  -> Add-AppxPackage
      *.msi            -> msiexec /qn /norestart (x64 MSIs install and run under Prism emulation)
      *.zip            -> unpacked to <ToolsRoot>\<name>
      *.exe            -> listed; launched one at a time only if you confirm (vendor installers are interactive)
    Notes for the current set:
      * Ninite: untick Git if you can - stage 10 installs the native ARM64 Git via winget, and two Gits on PATH cause trouble.
      * NordVPN: don't run it at the same time as Tailscale (routes/DNS fight). Use split tunnelling or switch between them.
      * Claude desktop app: never add NDA-zone MCP servers to it (stage 65 checks).
#>
[CmdletBinding(SupportsShouldProcess)] param([switch]$NoPrompt)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '25-StagedApps'
Assert-Admin
$cfg = Get-MachineConfig
$apps = Join-Path (Get-RepoRoot) 'apps'
if (-not (Test-Path $apps)) { Write-Step 'No apps\ folder - nothing to install' -Level Skip; exit 0 }

foreach ($f in @(Get-ChildItem $apps -File | Sort-Object -Property Extension, Name)) {
    switch -Regex ($f.Extension) {
        '^\.(msix|appx|msixbundle)$' {
            if ($PSCmdlet.ShouldProcess($f.Name, 'Add-AppxPackage')) {
                try { Add-AppxPackage -Path $f.FullName -ErrorAction Stop; Write-Step "Installed $($f.Name)" -Level Ok }
                catch { Write-Step "$($f.Name): $($_.Exception.Message)" -Level Fail }
            }
        }
        '^\.msi$' {
            if ($PSCmdlet.ShouldProcess($f.Name, 'msiexec /qn')) {
                $log = Join-Path (Get-RepoRoot) "logs\msi-$($f.BaseName).log"
                $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($f.FullName)`"", '/qn', '/norestart', '/l*v', "`"$log`"") -Wait -PassThru
                if ($p.ExitCode -in 0, 3010) { Write-Step "Installed $($f.Name)" -Level Ok } else { Write-Step "$($f.Name): msiexec exit $($p.ExitCode) (log $log)" -Level Fail }
            }
        }
        '^\.zip$' {
            $dest = Join-Path $cfg.ToolsRoot $f.BaseName
            if (Test-Path $dest) { Write-Step "$($f.Name) already unpacked" -Level Skip }
            else { Expand-Archive -Path $f.FullName -DestinationPath $dest; Write-Step "Unpacked $($f.Name) -> $dest" -Level Ok }
        }
        '^\.exe$' {
            if ($NoPrompt) { Write-Step "Interactive installer left for you: $($f.Name)" -Level Info; continue }
            $ans = Read-Host "Run $($f.Name) now? [y/N]"
            if ($ans -match '^[yY]') { Start-Process -FilePath $f.FullName -Wait; Write-Step "Ran $($f.Name)" -Level Ok }
        }
        default { Write-Step "Ignored $($f.Name)" -Level Skip }
    }
}
Write-Step 'Stage 25 complete' -Level Ok
exit 0
