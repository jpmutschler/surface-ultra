#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the Surface Laptop Ultra build scripts.
.NOTES
    Compatible with Windows PowerShell 5.1 (ships with Windows) and PowerShell 7.
    Keep this file ASCII-only: PS 5.1 reads BOM-less scripts as ANSI.
#>

Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LogDir   = Join-Path $script:RepoRoot 'logs'
$script:StateFile = Join-Path $script:RepoRoot 'logs\state.json'
$script:LogFile  = $null

function Get-RepoRoot { $script:RepoRoot }

# ---------------------------------------------------------------- logging
function Start-StageLog {
    param([Parameter(Mandatory)][string]$Stage)
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $script:LogDir "$Stage-$stamp.log"
    Write-Step "=== $Stage ($stamp) ===" -Level Head
}

function Write-Step {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Fail', 'Head', 'Skip')][string]$Level = 'Info'
    )
    $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Fail = 'Red'; Head = 'Cyan'; Skip = 'DarkGray' }[$Level]
    $tag = @{ Info = '[..]'; Ok = '[OK]'; Warn = '[!!]'; Fail = '[XX]'; Head = '[==]'; Skip = '[--]' }[$Level]
    $line = "{0} {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $tag, $Message
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
}

# ---------------------------------------------------------------- config / state
function Get-MachineConfig {
    $path = Join-Path $script:RepoRoot 'config\machine.psd1'
    $local = Join-Path $script:RepoRoot 'config\machine.local.psd1'
    $cfg = Import-PowerShellDataFile -Path $path
    if (Test-Path $local) {
        # machine.local.psd1 (gitignored) overrides individual keys
        $over = Import-PowerShellDataFile -Path $local
        foreach ($k in $over.Keys) { $cfg[$k] = $over[$k] }
    }
    # Resolve roots: use the Dev Drive if it exists, otherwise fall back to C:
    $devDrive = '{0}:\' -f $cfg.DevDriveLetter
    $useDev = Test-Path $devDrive
    $base = if ($useDev) { $devDrive } else { 'C:\' }
    $cfg.DevDrivePresent = $useDev
    $cfg.DevRoot   = Join-Path $base $cfg.DevRootName
    $cfg.ModelRoot = Join-Path $base $cfg.ModelRootName
    $cfg.ToolsRoot = Join-Path $base $cfg.ToolsRootName
    # NDA workspace + guard locations (rules-based; no vault)
    $cfg.NdaRoot     = Join-Path $base $cfg.NdaRootName
    $cfg.NdaTermsDir = Join-Path $cfg.NdaRoot 'terms'
    $cfg.NdaSecrets  = Join-Path $cfg.NdaRoot 'secrets'
    $cfg.SuHome      = Join-Path $env:USERPROFILE '.surface-ultra'
    return $cfg
}

function Get-ModelCatalog {
    $path = Join-Path $script:RepoRoot 'config\models.psd1'
    (Import-PowerShellDataFile -Path $path).Models
}

function Get-StageState {
    if (Test-Path $script:StateFile) {
        $obj = Get-Content $script:StateFile -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    return @{}
}

function Set-StageState {
    param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$Status)
    $state = Get-StageState
    $state[$Stage] = [ordered]@{ status = $Status; at = (Get-Date).ToString('s') }
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StateFile -Encoding UTF8
}

# ---------------------------------------------------------------- platform checks
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) { throw 'Run this from an elevated PowerShell (Run as administrator).' }
}

function Test-IsArm64Host {
    # Win32_Processor.Architecture 12 = ARM64. Works even if this shell runs under x64 emulation.
    $arch = (Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture
    return ($arch -eq 12)
}

function Test-IsNativeArm64Process {
    return ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Set-UserEnv {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $Value
    Write-Step "User env $Name = $Value" -Level Ok
}

# ---------------------------------------------------------------- winget
function Test-WingetPackage {
    param([Parameter(Mandatory)][string]$Id)
    $out = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    return ($out -match [regex]::Escape($Id))
}

function Install-WingetPackage {
    <#
      Idempotent winget install. Prefers the arm64 build; falls back to the default
      architecture (x64 under Prism) only when -AllowEmulated is passed.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Override,
        [switch]$AllowEmulated,
        [switch]$WhatIfOnly
    )
    if (Test-WingetPackage -Id $Id) { Write-Step "$Id already installed" -Level Skip; return $true }
    if ($WhatIfOnly) { Write-Step "WHATIF: winget install $Id" -Level Info; return $true }

    $common = @('install', '--id', $Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($Override) { $common += @('--override', $Override) }

    Write-Step "winget install $Id (arm64)"
    & winget @($common + @('--architecture', 'arm64')) | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Step "$Id installed (arm64)" -Level Ok; return $true }

    if ($AllowEmulated) {
        Write-Step "$Id has no arm64 package; installing default build (runs under Prism emulation)" -Level Warn
        & winget @common | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Step "$Id installed (emulated)" -Level Ok; return $true }
    }
    Write-Step "$Id failed (winget exit $LASTEXITCODE)" -Level Fail
    return $false
}

# ---------------------------------------------------------------- downloads
function Get-GitHubReleaseAsset {
    <#
      Finds the newest release (or a pinned tag) in owner/repo with an asset whose name
      matches $Pattern. Returns @{ Tag; Name; Url }.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Pattern,
        [string]$Tag = 'latest',
        [switch]$IncludePrerelease
    )
    $headers = @{ 'User-Agent' = 'surface-ultra-setup'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    if ($Tag -ne 'latest') {
        $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $headers)
    } else {
        $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=20" -Headers $headers)
    }
    foreach ($r in $releases) {
        if ($r.prerelease -and -not $IncludePrerelease -and $Tag -eq 'latest') { continue }
        $asset = $r.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        if ($asset) { return @{ Tag = $r.tag_name; Name = $asset.name; Url = $asset.browser_download_url } }
    }
    return $null
}

function Invoke-Download {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Step "Downloading $Url"
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # 10x faster in PS 5.1
    try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing }
    finally { $ProgressPreference = $old }
}

function New-RandomSecret {
    param([int]$Bytes = 24)
    $b = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ('sk-' + (($b | ForEach-Object { $_.ToString('x2') }) -join ''))
}

# ---------------------------------------------------------------- WSL helpers
function Invoke-Wsl {
    <# Runs a bash command in the configured distro and returns exit code. #>
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Command, [string]$User)
    $wslArgs = @('-d', $Distro)
    if ($User) { $wslArgs += @('-u', $User) }
    $wslArgs += @('--', 'bash', '-lc', $Command)
    & wsl.exe @wslArgs
    return $LASTEXITCODE
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath, [Parameter(Mandatory)][string]$Distro)
    $p = (& wsl.exe -d $Distro '--' wslpath -a ($WindowsPath -replace '\\', '/')) | Select-Object -First 1
    return $p.Trim()
}

# ---------------------------------------------------------------- llama-swap config generation
function Resolve-ModelFile {
    <# Resolves a relative path or wildcard (for split GGUFs) under the model's folder. #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Relative)
    $hit = Get-ChildItem -Path (Join-Path $Folder $Relative) -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function New-LlamaSwapConfig {
    <#
      Generates llama-swap.yaml from config\models.psd1 for every model whose files are
      present on disk. Paths are written with forward slashes (llama-swap splits cmd
      lines shell-style, so backslashes would be eaten as escapes).
    #>
    param([Parameter(Mandatory)][hashtable]$Cfg)
    $models = Get-ModelCatalog
    $server = (Join-Path $Cfg.ToolsRoot 'llama.cpp\current\llama-server.exe') -replace '\\', '/'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# GENERATED by scripts/51-PullModels.ps1 from config/models.psd1 - do not edit by hand')
    [void]$sb.AppendLine('healthCheckTimeout: 600')
    [void]$sb.AppendLine('logLevel: info')
    [void]$sb.AppendLine('startPort: 10001')
    [void]$sb.AppendLine('models:')
    $present = @()
    foreach ($m in $models) {
        $folder = Join-Path $Cfg.ModelRoot $m.Alias
        if (-not $m.Main) { continue }
        $main = Resolve-ModelFile -Folder $folder -Relative $m.Main
        if (-not $main) { continue }
        $present += $m
        $cmd = "$server --port `${PORT} --host 127.0.0.1 -m $($main -replace '\\','/') --alias $($m.Alias) -ngl 999 --no-mmap"
        if ($m.ContainsKey('Mmproj') -and $m.Mmproj) {
            $mm = Resolve-ModelFile -Folder $folder -Relative $m.Mmproj
            if ($mm) { $cmd += " --mmproj $($mm -replace '\\','/')" }
        }
        if ($m.Args) { $cmd += " $($m.Args)" }
        [void]$sb.AppendLine("  `"$($m.Alias)`":")
        [void]$sb.AppendLine("    cmd: >-")
        [void]$sb.AppendLine("      $cmd")
        [void]$sb.AppendLine("    ttl: $($m.TtlSeconds)")
        if ($m.ContainsKey('Description')) { [void]$sb.AppendLine("    description: `"$($m.Description)`"") }
    }
    # Groups: 'resident' members stay loaded together; 'main' members swap with each other.
    $resident = @($present | Where-Object { $_.Group -eq 'resident' } | ForEach-Object { '"' + $_.Alias + '"' })
    $main = @($present | Where-Object { $_.Group -eq 'main' } | ForEach-Object { '"' + $_.Alias + '"' })
    [void]$sb.AppendLine('groups:')
    if ($resident.Count -gt 0) {
        [void]$sb.AppendLine('  "resident":')
        [void]$sb.AppendLine('    swap: false')
        [void]$sb.AppendLine('    exclusive: false')
        [void]$sb.AppendLine('    persistent: true')
        [void]$sb.AppendLine("    members: [$($resident -join ', ')]")
    }
    if ($main.Count -gt 0) {
        [void]$sb.AppendLine('  "main":')
        [void]$sb.AppendLine('    swap: true')
        [void]$sb.AppendLine('    exclusive: false')
        [void]$sb.AppendLine("    members: [$($main -join ', ')]")
    }
    $out = Join-Path $Cfg.ToolsRoot 'llama-swap\llama-swap.yaml'
    if (-not (Test-Path (Split-Path $out))) { New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null }
    # UTF-8 without BOM so Go's YAML parser is happy on PS 5.1 too
    [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    Write-Step "Wrote $out ($($present.Count) models: $(($present | ForEach-Object Alias) -join ', '))" -Level Ok
    return $out
}

function Get-SuPython {
    <# Path to the uv-managed native ARM64 Python used for stdlib helper tools (nda_guard, bench). #>
    param([string]$Version = '3.12')
    $p = (& uv python find $Version 2>$null | Select-Object -First 1)
    if ($p) { return $p.Trim() }
    return $null
}

# ---------------------------------------------------------------- storage tiers
function Test-TcpPort {
    param([Parameter(Mandatory)][string]$HostName, [int]$Port = 445, [int]$TimeoutMs = 1500)
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($HostName, $Port).Wait($TimeoutMs); $c.Close(); return $ok }
    catch { return $false }
}

function Get-NasRoot {
    <# First reachable NAS root from NasRoots (quick SMB port probe first, so an offline NAS costs ~1.5 s, not 20). #>
    param([Parameter(Mandatory)][hashtable]$Cfg)
    foreach ($r in $Cfg.NasRoots) {
        $h = ($r -replace '^\\\\', '') -split '\\' | Select-Object -First 1
        if ((Test-TcpPort -HostName $h) -and (Test-Path $r)) { return $r }
    }
    return $null
}

function Get-ColdRoot {
    <# Root folder on the flash drive (found by volume label), or $null when it isn't plugged in. #>
    param([Parameter(Mandatory)][hashtable]$Cfg)
    $v = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $Cfg.ColdVolumeLabel -and $_.DriveLetter } | Select-Object -First 1
    if (-not $v) { return $null }
    $root = Join-Path ('{0}:\' -f $v.DriveLetter) $Cfg.ColdRootName
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Restart-LlamaSwap {
    $task = Get-ScheduledTask -TaskName 'SurfaceUltra-llama-swap' -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName 'SurfaceUltra-llama-swap'
        Get-Process -Name 'llama-swap', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-ScheduledTask -TaskName 'SurfaceUltra-llama-swap'
        Write-Step 'llama-swap restarted with the current model list' -Level Ok
    }
}

# ---------------------------------------------------------------- platform: VS plan, GPU split, commit
function Get-VsPlan {
    <# winget IDs for the configured Visual Studio version/edition and the SDK + WDK that match it. #>
    param([Parameter(Mandatory)][hashtable]$Cfg)
    $ver = "$($Cfg.VisualStudio.Version)"; $ed = "$($Cfg.VisualStudio.Edition)"
    if ($ver -eq '2022') {
        return @{ VsId = "Microsoft.VisualStudio.2022.$ed"; SdkId = 'Microsoft.WindowsSDK.10.0.26100'; WdkId = 'Microsoft.WindowsWDK.10.0.26100'; Kit = '10.0.26100' }
    }
    # VS 2026 (18.x) dropped the year from its winget IDs
    return @{ VsId = "Microsoft.VisualStudio.$ed"; SdkId = 'Microsoft.WindowsSDK.10.0.28000'; WdkId = 'Microsoft.WindowsWDK.10.0.28000'; Kit = '10.0.28000' }
}

function Get-GpuMemorySplit {
    <#
      Dedicated GPU memory (the NVIDIA-app split) from the display adapter's registry entry, and the
      shared segment computed with NVIDIA's documented rule (remaining - 16 GB, clamped to 50-80% of
      remaining). CUDA allocations fill dedicated first and spill to shared (smaller pages, slower).
    #>
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $dedicated = $null
    Get-ChildItem $classKey -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and ($p.PSObject.Properties.Name -contains 'DriverDesc') -and $p.DriverDesc -match 'NVIDIA' -and
            ($p.PSObject.Properties.Name -contains 'HardwareInformation.qwMemorySize')) {
            $dedicated = [double]$p.'HardwareInformation.qwMemorySize'
        }
    }
    if (-not $dedicated) { return $null }
    $installed = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    $installedGB = [math]::Round($installed / 1GB, 1)
    $dedGB = [math]::Round($dedicated / 1GB, 1)
    $remain = $installedGB - $dedGB
    $shared = [math]::Min([math]::Max($remain - 16, 0.5 * $remain), 0.8 * $remain)
    return [pscustomobject]@{ InstalledGB = $installedGB; DedicatedGB = $dedGB; SharedGB = [math]::Round($shared, 1); WindowsGB = [math]::Round($remain, 1) }
}

function Get-CommitState {
    <# Windows commit charge and limit in GB. CUDA allocations on RTX Spark count against commit. #>
    $os = Get-CimInstance Win32_OperatingSystem
    $limit = [double]$os.TotalVirtualMemorySize * 1024
    $free = [double]$os.FreeVirtualMemory * 1024
    return [pscustomobject]@{ LimitGB = [math]::Round($limit / 1GB, 1); UsedGB = [math]::Round(($limit - $free) / 1GB, 1); FreeGB = [math]::Round($free / 1GB, 1) }
}

function Get-PeArchitecture {
    <# Machine type from an .exe's PE header: ARM64 (native) vs x64/x86 (runs under Prism). #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $br = New-Object IO.BinaryReader($fs)
            [void]$fs.Seek(0x3C, 'Begin'); $pe = $br.ReadInt32()
            [void]$fs.Seek($pe + 4, 'Begin'); $m = $br.ReadUInt16()
        } finally { $fs.Close() }
        # IMAGE_FILE_MACHINE_*: 0xAA64 ARM64, 0xA641 ARM64EC, 0x8664 AMD64, 0x014C I386
        $names = @{ 43620 = 'ARM64'; 42561 = 'ARM64EC'; 34404 = 'x64, emulated'; 332 = 'x86, emulated' }
        if ($names.ContainsKey([int]$m)) { $names[[int]$m] } else { '0x{0:X4}' -f $m }
    } catch { 'unknown' }
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lf = $Content -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding $false))
}

Export-ModuleMember -Function *
