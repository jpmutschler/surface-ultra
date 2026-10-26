#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 90 - end-to-end validation with PASS / WARN / FAIL per check. Read-only.
.DESCRIPTION
    Go/no-go checks from the build plan: GPU memory split, native inference speed, commit headroom,
    power-offs, gateways, vector DB, WSL GPU passthrough, Spark reachability, serial ports, toolchain
    (native vs emulated), Visual Studio + WDK, NDA guardrails, and the ccn profile.
    Writes logs\validate-<stamp>.json.
#>
[CmdletBinding(SupportsShouldProcess)] param([switch]$SkipInference)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '90-Validate'
$cfg = Get-MachineConfig
Update-SessionPath
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$Check, [string]$Status, [string]$Detail) {
    [void]$results.Add([pscustomobject]@{ check = $Check; status = $Status; detail = $Detail })
    $lvl = @{ PASS = 'Ok'; WARN = 'Warn'; FAIL = 'Fail' }[$Status]
    Write-Step ("{0,-28} {1}" -f $Check, $Detail) -Level $lvl
}

# 1. platform
Add-Result 'arm64 host' $(if (Test-IsArm64Host) { 'PASS' } else { 'FAIL' }) $env:PROCESSOR_ARCHITECTURE
$q = & nvidia-smi '--query-gpu=name,driver_version' '--format=csv,noheader' 2>$null
if ($q) {
    $ver = [double](($q -split ',')[1].Trim())
    Add-Result 'nvidia driver >= 616' $(if ($ver -ge 616) { 'PASS' } else { 'FAIL' }) "$q"
} else { Add-Result 'nvidia driver >= 616' 'FAIL' 'nvidia-smi unavailable' }

# 2. real GPU budget via CUDA (PyTorch nightly from NVIDIA's index if present, else skip)
$py = "import ctypes,sys`ntry:`n  c=ctypes.WinDLL('nvcuda.dll')`nexcept OSError:`n  print('NOCUDA');sys.exit(0)`n" +
      "c.cuInit(0);d=ctypes.c_int();c.cuDeviceGet(ctypes.byref(d),0);ctx=ctypes.c_void_p()`n" +
      "c.cuDevicePrimaryCtxRetain(ctypes.byref(ctx),d);c.cuCtxSetCurrent(ctx)`n" +
      "f=ctypes.c_size_t();t=ctypes.c_size_t();c.cuMemGetInfo_v2(ctypes.byref(f),ctypes.byref(t))`n" +
      "print('%.1f %.1f'%(f.value/2**30,t.value/2**30))"
$tmpPy = Join-Path $env:TEMP 'su-cumem.py'
Set-Content -Path $tmpPy -Value $py -Encoding ASCII
$mem = & uv run --no-project --python 3.12 python $tmpPy 2>$null
Remove-Item $tmpPy -ErrorAction SilentlyContinue
if ($mem -and $mem -ne 'NOCUDA') {
    $free, $total = ($mem -split ' ') | ForEach-Object { [double]$_ }
    Add-Result 'CUDA memory (cuMemGetInfo)' 'PASS' ("total {0} GiB, free {1} GiB" -f $total, $free)
} else { Add-Result 'CUDA memory (cuMemGetInfo)' 'WARN' 'could not query nvcuda.dll' }
$split = Get-GpuMemorySplit
if ($split) {
    $st = if ($split.DedicatedGB -ge ($cfg.GpuDedicatedTargetGB - 4)) { 'PASS' } elseif ($split.DedicatedGB -ge 60) { 'WARN' } else { 'FAIL' }
    Add-Result 'GPU dedicated split' $st ("{0} GB dedicated / {1} GB Windows (plan {2}; set in the NVIDIA app)" -f $split.DedicatedGB, $split.WindowsGB, $cfg.GpuDedicatedTargetGB)
} else { Add-Result 'GPU dedicated split' 'WARN' 'could not read it from the registry' }

# 3. native inference
$swap = "http://$($cfg.LlamaSwapListen)"
try {
    $m = Invoke-RestMethod "$swap/v1/models" -TimeoutSec 10
    Add-Result 'llama-swap up' 'PASS' (($m.data | ForEach-Object id) -join ', ')
    if (-not $SkipInference) {
        # target decode tok/s on AC: analyst ~ Spark's 56 for Qwen3.6-35B-A3B; research ~ Spark's 16 for Nemotron 3 Super
        foreach ($t in @(@{ M = 'sc-analyst'; Pass = 40; Warn = 25 }, @{ M = 'sc-research'; Pass = 12; Warn = 8 })) {
            $body = @{ model = $t.M; max_tokens = 256; temperature = 0
                       messages = @(@{ role = 'user'; content = 'In two sentences, what does the PCIe LTSSM Recovery state do?' }) } | ConvertTo-Json -Depth 5
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-RestMethod "$swap/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900
                $sw.Stop()
                $tps = $null
                if ($r.PSObject.Properties.Name -contains 'timings') { $tps = [math]::Round($r.timings.predicted_per_second, 1) }
                if ($tps) {
                    $st = if ($tps -ge $t.Pass) { 'PASS' } elseif ($tps -ge $t.Warn) { 'WARN' } else { 'FAIL' }
                    Add-Result "$($t.M) decode tok/s" $st "$tps tok/s (target >= $($t.Pass) on AC)"
                } else { Add-Result "$($t.M) responds" 'PASS' ("{0:N1}s wall incl. load" -f $sw.Elapsed.TotalSeconds) }
            } catch { Add-Result "$($t.M) responds" 'FAIL' $_.Exception.Message }
        }
    }
} catch { Add-Result 'llama-swap up' 'FAIL' $_.Exception.Message }
# With sc-research loaded (the largest allocation this build makes), commit must still have room:
# CUDA allocations count against Windows commit on RTX Spark.
$cm = Get-CommitState
$st = if ($cm.FreeGB -ge 8) { 'PASS' } elseif ($cm.FreeGB -ge 3) { 'WARN' } else { 'FAIL' }
Add-Result 'commit headroom' $st ("{0} GB free of a {1} GB limit (raise PageFileGB if this is tight)" -f $cm.FreeGB, $cm.LimitGB)
$kp = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue)
Add-Result 'unexpected power-offs (7d)' $(if ($kp.Count) { 'WARN' } else { 'PASS' }) ("{0} Kernel-Power 41 event(s){1}" -f $kp.Count, $(if ($kp.Count) { ' - check Windows Update for Surface firmware; note what was running' } else { '' }))

# 4. gateway + vector DB
$key = [Environment]::GetEnvironmentVariable('LITELLM_MASTER_KEY', 'User')
try {
    $g = Invoke-RestMethod "http://127.0.0.1:$($cfg.LiteLLMPort)/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 10
    Add-Result 'LiteLLM gateway' 'PASS' ("{0} routes" -f @($g.data).Count)
} catch { Add-Result 'LiteLLM gateway' 'FAIL' $_.Exception.Message }
try { Invoke-RestMethod 'http://127.0.0.1:6333/readyz' -TimeoutSec 5 | Out-Null; Add-Result 'Qdrant' 'PASS' '127.0.0.1:6333' }
catch { Add-Result 'Qdrant' 'FAIL' $_.Exception.Message }

# 5. WSL GPU passthrough
& wsl.exe -d $cfg.WslDistro '--' bash -lc 'docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L' 2>$null | Out-String | Set-Variable wslOut
if ($LASTEXITCODE -eq 0 -and $wslOut -match 'GPU 0') { Add-Result 'WSL docker --gpus all' 'PASS' ($wslOut.Trim() -split "`n")[0] }
else { Add-Result 'WSL docker --gpus all' 'WARN' 'failed - native inference unaffected; vLLM profile unavailable' }

# 6. Spark over Tailscale
try {
    Invoke-WebRequest -Uri ($cfg.SparkLiteLLMUrl -replace '/v1$', '/health/liveliness') -UseBasicParsing -TimeoutSec 5 | Out-Null
    Add-Result 'DGX Spark gateway' 'PASS' $cfg.SparkLiteLLMUrl
} catch { Add-Result 'DGX Spark gateway' 'WARN' "unreachable ($($cfg.SparkHost)) - fine when travelling" }

# 7. HIL
$ports = @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue | Where-Object Status -eq 'OK')
Add-Result 'serial ports' $(if ($ports.Count) { 'PASS' } else { 'WARN' }) ("{0} OK: {1}" -f $ports.Count, (($ports | ForEach-Object FriendlyName) -join '; '))
$bad = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in @('Error', 'Unknown') })
Add-Result 'devices without driver' $(if ($bad.Count) { 'WARN' } else { 'PASS' }) ("{0}: {1}" -f $bad.Count, (($bad | Select-Object -First 5 | ForEach-Object FriendlyName) -join '; '))

# 8. toolchain native-ness
$pyArch = & uv run --no-project --python 3.12 python -c "import platform;print(platform.machine())" 2>$null
Add-Result 'python arch' $(if ("$pyArch".Trim() -eq 'ARM64') { 'PASS' } else { 'WARN' }) "$pyArch"
foreach ($c in @('git', 'node', 'claude', 'hf', 'usbipd', 'just', 'hx', 'rg', 'glow')) {
    $cmd = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Add-Result "cmd: $c" $(if ($cmd) { 'PASS' } else { 'WARN' }) $(if ($cmd) { Get-PeArchitecture -Path $cmd.Source } else { 'missing' })
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = if (Test-Path $vswhere) { & $vswhere -latest -products * -property installationPath } else { $null }
Add-Result 'Visual Studio' $(if ($vsPath) { 'PASS' } else { 'WARN' }) $(if ($vsPath) { $vsPath } else { 'not found - stage 20' })
if ($cfg.InstallWdk) {
    $km = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'km') } | Sort-Object Name | Select-Object -Last 1
    Add-Result 'WDK' $(if ($km) { 'PASS' } else { 'WARN' }) $(if ($km) { "$($km.Name) - next: tools\Test-DriverBuild.ps1 on a real x64 driver" } else { 'kernel headers missing - stage 20' })
}

# 9. NDA guardrails + privacy
$ccSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $ccSettings) {
    $raw = Get-Content $ccSettings -Raw
    $ndaPosix = '//' + $cfg.NdaRoot.Substring(0, 1).ToLower() + '/' + ($cfg.NdaRoot.Substring(3) -replace '\\', '/')
    Add-Result 'Claude deny NDA workspace' $(if ($raw -match [regex]::Escape("Read($ndaPosix/**)")) { 'PASS' } else { 'FAIL' }) "Read($ndaPosix/**)"
    Add-Result 'Claude reads fenced' $(if ($raw -match '"blockReadsOutsideWorkingDirectories":\s*true') { 'PASS' } else { 'FAIL' }) 'blockReadsOutsideWorkingDirectories'
    Add-Result 'Claude NDA hooks' $(if ($raw -match 'nda_guard\.py') { 'PASS' } else { 'FAIL' }) 'UserPromptSubmit + PreToolUse'
} else { Add-Result 'Claude settings' 'FAIL' 'no ~/.claude/settings.json - run stage 70' }
$idx = Join-Path $cfg.SuHome 'nda-index.json'
Add-Result 'NDA term index' $(if (Test-Path $idx) { 'PASS' } else { 'WARN' }) $(if (Test-Path $idx) { $idx } else { 'add term lists, then tools\NdaSession.ps1 -Start' })
Add-Result 'NDA workspace outside repos' $(if ($cfg.NdaRoot -notlike "$($cfg.DevRoot)\src*") { 'PASS' } else { 'FAIL' }) $cfg.NdaRoot
$ep = [Environment]::GetEnvironmentVariable('NDA_GUARD_ENDPOINTS', 'User')
Add-Result 'Guard path/endpoint list' $(if ($ep) { 'PASS' } else { 'FAIL' }) $(if ($ep) { 'set' } else { 'run stage 65' })
$recall = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -ErrorAction SilentlyContinue).DisableAIDataAnalysis
$want = $cfg.RecallPolicy -eq 'Disable'
Add-Result 'Recall policy' $(if ($want -eq ($recall -eq 1)) { 'PASS' } else { 'WARN' }) ("RecallPolicy = {0}; policy {1}" -f $cfg.RecallPolicy, $(if ($recall -eq 1) { 'off' } else { 'not set (your choice in Settings)' }))
# ccn: the local-model Claude Code profile
$ccnDir = Join-Path $cfg.NdaRoot $cfg.Ccn.ConfigDirName
$ccnSettings = Join-Path $ccnDir 'settings.json'
if (Test-Path $ccnSettings) {
    $cs = Get-Content $ccnSettings -Raw | ConvertFrom-Json
    $h = ([uri]"$($cs.env.ANTHROPIC_BASE_URL)").Host
    Add-Result 'ccn gateway is loopback' $(if ($h -in @('127.0.0.1', 'localhost', '::1', '[::1]')) { 'PASS' } else { 'FAIL' }) "$($cs.env.ANTHROPIC_BASE_URL)"
    Add-Result 'ccn Anthropic traffic off' $(if ($cs.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -eq '1' -and $cs.env.DISABLE_FEEDBACK_COMMAND -eq '1' -and $cs.skipWebFetchPreflight) { 'PASS' } else { 'FAIL' }) 'nonessential traffic, /feedback, WebFetch preflight'
    Add-Result 'ccn credential' $(if ($cs.apiKeyHelper -and -not $cs.env.ANTHROPIC_API_KEY -and -not $cs.env.ANTHROPIC_AUTH_TOKEN) { 'PASS' } else { 'FAIL' }) 'NDA gateway key via apiKeyHelper only'
    Add-Result 'ccn MCP list' $(if (Test-Path (Join-Path $ccnDir 'mcp.json')) { 'PASS' } else { 'WARN' }) $(if (Test-Path (Join-Path $ccnDir 'mcp.json')) { 'mcp.json present' } else { 'run tools\Set-ResearchMode.ps1' })
} else { Add-Result 'ccn profile' 'FAIL' "no $ccnSettings - run stage 70" }
$gw = Test-TcpPort -HostName '127.0.0.1' -Port $cfg.NdaLiteLLMPort
Add-Result 'NDA gateway' $(if ($gw) { 'PASS' } else { 'WARN' }) $(if ($gw) { "127.0.0.1:$($cfg.NdaLiteLLMPort)" } else { 'stopped - tools\NdaSession.ps1 -Start when researching' })
$desk = [Environment]::GetFolderPath('Desktop')
Add-Result 'Desktop not in OneDrive' $(if ($desk -notmatch 'OneDrive') { 'PASS' } else { 'WARN' }) $desk
foreach ($s in $cfg.SparkMcp) {
    $u = [uri]$s.Url
    $ok = $false
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($u.Host, $u.Port).Wait(3000); $c.Close() } catch { }
    Add-Result "Spark MCP $($s.Name)" $(if ($ok) { 'PASS' } else { 'WARN' }) "$($s.Url) [$($s.Zone)]"
}

$out = Join-Path (Get-RepoRoot) ("logs\validate-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$results | ConvertTo-Json -Depth 3 | Set-Content -Path $out -Encoding UTF8
$fails = @($results | Where-Object status -eq 'FAIL').Count
$warns = @($results | Where-Object status -eq 'WARN').Count
Write-Step "Summary: $fails FAIL, $warns WARN -> $out" -Level $(if ($fails) { 'Fail' } elseif ($warns) { 'Warn' } else { 'Ok' })
if ($fails) { exit 1 }
exit 0
