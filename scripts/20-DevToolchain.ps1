#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 20 - native ARM64 developer toolchain.
.DESCRIPTION
    uv + uv-managed Python (aarch64-pc-windows), Node LTS, Rust, Go, CMake, Ninja, just,
    Visual Studio (BuildTools or the Community IDE, 2026 or 2022 - see VisualStudio in machine.psd1)
    with MSVC ARM64/ARM64EC + x64 cross tools and Spectre-mitigated libs, the matching Windows SDK +
    WDK, optional CUDA 13.4 toolkit, git defaults.

    VS 2026 pairs with the current WDK (10.0.28000); VS 2022 pairs with WDK 26100.x. The WDK installs and
    builds natively on ARM64 hosts since 10.0.26100.1. Building x64 kernel drivers from an ARM64 host is
    not spelled out by Microsoft - check it on day one with tools\Test-DriverBuild.ps1.
#>
[CmdletBinding(SupportsShouldProcess)] param()
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '20-DevToolchain'
Assert-Admin
$cfg = Get-MachineConfig
$failed = @()

$pkgs = @('astral-sh.uv', 'OpenJS.NodeJS.LTS', 'Rustlang.Rustup', 'GoLang.Go', 'Kitware.CMake', 'Ninja-build.Ninja')
foreach ($id in $pkgs) {
    if (-not (Install-WingetPackage -Id $id -WhatIfOnly:$WhatIfPreference)) { $failed += $id }
}
if (-not (Install-WingetPackage -Id 'Casey.Just' -AllowEmulated -WhatIfOnly:$WhatIfPreference)) { $failed += 'Casey.Just' }

# ---------------------------------------------------------------- Visual Studio + SDK + WDK
$vs = Get-VsPlan -Cfg $cfg
$comps = @($cfg.VsComponents)
if ($cfg.VisualStudio.Edition -eq 'BuildTools') {
    # BuildTools has no IDE workload: swap the desktop workload for the C++ build tools one
    $comps = @('Microsoft.VisualStudio.Workload.VCTools') + @($comps | Where-Object { $_ -notmatch 'Workload\.NativeDesktop|ComponentGroup\.NativeDesktop' })
}
$vsOverride = '--quiet --wait --norestart --nocache ' + (($comps | ForEach-Object { "--add $_" }) -join ' ') + ' --includeRecommended'
# The VS bootstrapper may only be published as x64; it still installs the native ARM64 IDE on this host.
Write-Step "Visual Studio $($cfg.VisualStudio.Version) $($cfg.VisualStudio.Edition) ($($vs.VsId))"
if (-not (Install-WingetPackage -Id $vs.VsId -Override $vsOverride -AllowEmulated -WhatIfOnly:$WhatIfPreference)) { $failed += $vs.VsId }
if ($cfg.InstallWdk) {
    # SDK and WDK build numbers must match; the WDK installer may be x86-only (it installs ARM64 host tools)
    foreach ($id in @($vs.SdkId, $vs.WdkId)) {
        if (-not (Install-WingetPackage -Id $id -AllowEmulated -WhatIfOnly:$WhatIfPreference)) { $failed += $id }
    }
}
Update-SessionPath

# ---------------------------------------------------------------- CUDA toolkit (optional)
$nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
if ($nvcc) {
    Write-Step "nvcc present: $((& nvcc --version | Select-String 'release').ToString().Trim())" -Level Skip
} elseif ($cfg.CudaInstallerPath -and (Test-Path $cfg.CudaInstallerPath)) {
    Write-Step "Installing CUDA toolkit from $($cfg.CudaInstallerPath) (silent)"
    if ($PSCmdlet.ShouldProcess($cfg.CudaInstallerPath, 'install CUDA')) {
        $p = Start-Process -FilePath $cfg.CudaInstallerPath -ArgumentList '-s' -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Step 'CUDA toolkit installed' -Level Ok } else { Write-Step "CUDA installer exit $($p.ExitCode)" -Level Fail; $failed += 'CUDA' }
    }
} else {
    Write-Step 'CUDA toolkit skipped. For nvcc/CUDA dev, download the 13.4+ Windows-on-Arm installer from https://developer.nvidia.com/cuda-downloads and set CudaInstallerPath.' -Level Warn
}

# ---------------------------------------------------------------- Python via uv
Update-SessionPath
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
    foreach ($v in $cfg.PythonVersions) {
        & uv python install $v
        if ($LASTEXITCODE -eq 0) { Write-Step "uv python $v installed" -Level Ok } else { $failed += "python $v" }
    }
    $arch = & uv run --python $cfg.PythonVersions[0] --no-project python -c "import platform;print(platform.machine())"
    if ("$arch".Trim() -eq 'ARM64') { Write-Step "Python reports $arch (native)" -Level Ok }
    else { Write-Step "Python reports '$arch' - expected ARM64 (native). Check uv python list." -Level Warn }
    foreach ($t in $cfg.UvTools) {
        & uv tool install --upgrade $t
        if ($LASTEXITCODE -eq 0) { Write-Step "uv tool: $t" -Level Ok } else { $failed += "uv tool $t" }
    }
} else { Write-Step 'uv not found on PATH - open a new shell and re-run stage 20' -Level Fail; $failed += 'uv' }

# ---------------------------------------------------------------- git defaults
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    & git config --global user.name  $cfg.GitUserName
    & git config --global user.email $cfg.GitUserEmail
    & git config --global init.defaultBranch main
    & git config --global core.autocrlf false
    & git config --global core.longpaths true
    & git config --global pull.rebase true
    & git config --global fetch.prune true
    Write-Step 'git global config set' -Level Ok
}

# ---------------------------------------------------------------- report
foreach ($c in @('python', 'uv', 'node', 'cargo', 'go', 'cmake', 'ninja', 'git')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { Write-Step ("{0,-7} {1}" -f $c, $cmd.Source) -Level Ok } else { Write-Step "$c not on PATH (new shell may be needed)" -Level Warn }
}
if ($failed.Count) { Write-Step "Failed: $($failed -join ', ')" -Level Fail; exit 1 }
Write-Step 'Stage 20 complete' -Level Ok
exit 0
