#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 80 - clone Serial Cables repos to <DevRoot>\src and build their environments.
.DESCRIPTION
    For each repo in config\machine.psd1 with a Url: clone (or fast-forward), then
    'uv sync' if it has a pyproject.toml, 'npm ci' if it has a package-lock.json.
    Reports any dependency that failed to resolve a win_arm64 wheel - those are the
    packages to fix (build from source with the MSVC ARM64 tools, or swap out).
    Installs the nda_guard pre-commit hook in every repo (standing NDA rule).
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '80-Workspace'
$cfg = Get-MachineConfig
Update-SessionPath
$src = Join-Path $cfg.DevRoot 'src'
New-Item -ItemType Directory -Path $src -Force | Out-Null
$problems = @()
$py = Get-SuPython
$guard = Join-Path $cfg.SuHome 'tools\nda_guard.py'

foreach ($r in $cfg.Repos) {
    if (-not $r.Url) { Write-Step "$($r.Name): no Url in machine.psd1 - skipped" -Level Skip; continue }
    $dir = Join-Path $src $r.Name
    if (Test-Path (Join-Path $dir '.git')) {
        & git -C $dir pull --ff-only
        Write-Step "$($r.Name): updated" -Level Ok
    } else {
        & git clone $r.Url $dir
        if ($LASTEXITCODE -ne 0) { Write-Step "$($r.Name): clone failed" -Level Fail; $problems += $r.Name; continue }
        Write-Step "$($r.Name): cloned" -Level Ok
    }
    # NDA rule: every repo gets the guard as a pre-commit hook (blocks protected terms before they can be pushed or shared)
    if ($py -and (Test-Path $guard)) {
        & $py -I $guard hook-install $dir
        if ($LASTEXITCODE -ne 0) { Write-Step "$($r.Name): existing pre-commit hook - add 'nda_guard.py scan --staged' to it (or to .pre-commit-config.yaml)" -Level Warn }
    } else { Write-Step "$($r.Name): nda_guard not installed yet (stage 65) - no pre-commit hook" -Level Warn }
    if (Test-Path (Join-Path $dir 'pyproject.toml')) {
        Push-Location $dir
        $out = & uv sync --all-extras 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Pop-Location
        if ($rc -eq 0) { Write-Step "$($r.Name): uv sync OK" -Level Ok }
        else {
            $problems += $r.Name
            Write-Step "$($r.Name): uv sync failed" -Level Fail
            $out -split "`n" | Where-Object { $_ -match 'win_arm64|no wheels|Failed to build|error:' } |
                Select-Object -First 8 | ForEach-Object { Write-Step "   $_" -Level Warn }
        }
    }
    if (Test-Path (Join-Path $dir 'package-lock.json')) {
        Push-Location $dir; & npm ci; $rc = $LASTEXITCODE; Pop-Location
        if ($rc -eq 0) { Write-Step "$($r.Name): npm ci OK" -Level Ok } else { $problems += "$($r.Name) (npm)" }
    }
}
if ($problems.Count) { Write-Step "Needs attention: $($problems -join ', ')" -Level Warn }
Write-Step 'Stage 80 complete' -Level Ok
exit 0
