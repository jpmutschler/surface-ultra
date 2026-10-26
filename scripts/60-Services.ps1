#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 60 - WSL2 service stack: LiteLLM gateway, Qdrant, Open WebUI (+ optional vLLM profile).
.DESCRIPTION
    Renders litellm.yaml from the template, writes ~/surface-ultra/.env (secrets, chmod 600)
    inside WSL, copies compose.yaml, and brings the stack up. Generates a LiteLLM master
    key once and stores it as the Windows user env var LITELLM_MASTER_KEY.
.PARAMETER WithVllm
    Also start the vLLM profile (stop big native models first; raise WslMemoryGB).
#>
[CmdletBinding(SupportsShouldProcess)] param([switch]$WithVllm)
Import-Module (Join-Path $PSScriptRoot '..\lib\SurfaceUltra.psm1') -Force
Start-StageLog -Stage '60-Services'
$cfg = Get-MachineConfig
$root = Get-RepoRoot
$distro = $cfg.WslDistro

# ---------------------------------------------------------------- secrets
$master = [Environment]::GetEnvironmentVariable('LITELLM_MASTER_KEY', 'User')
if (-not $master) { $master = New-RandomSecret; Set-UserEnv -Name 'LITELLM_MASTER_KEY' -Value $master }
else { Write-Step 'LITELLM_MASTER_KEY already set' -Level Skip }
$sparkKey = [Environment]::GetEnvironmentVariable('SPARK_LITELLM_KEY', 'User')
if (-not $sparkKey) {
    Write-Step 'SPARK_LITELLM_KEY not set - spark/* routes will 401 until you set it (the Spark gateway master or a virtual key)' -Level Warn
    $sparkKey = 'unset'
}

# ---------------------------------------------------------------- render litellm.yaml
$tpl = Get-Content (Join-Path $root 'config\litellm.template.yaml') -Raw
$tpl = $tpl.Replace('{{SPARK_HOST}}', $cfg.SparkHost).Replace('{{SPARK_LITELLM_URL}}', $cfg.SparkLiteLLMUrl)
if ($cfg.SparkLangfuseUrl) {
    $lf = "  success_callback: [`"langfuse`"]`n  failure_callback: [`"langfuse`"]`n"
} else { $lf = '' }
$stage = Join-Path $env:TEMP 'su-services'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
# everyday gateway (traces) and NDA gateway (no callbacks, the Spark's no-logging key)
Write-Utf8NoBom -Path (Join-Path $stage 'litellm.yaml') -Content ($tpl.Replace('{{LANGFUSE_BLOCK}}', $lf).Replace('{{SPARK_KEY_ENV}}', 'SPARK_LITELLM_KEY'))
Write-Utf8NoBom -Path (Join-Path $stage 'litellm-nda.yaml') -Content ($tpl.Replace('{{LANGFUSE_BLOCK}}', '').Replace('{{SPARK_KEY_ENV}}', 'SPARK_NDA_LITELLM_KEY'))
Copy-Item (Join-Path $root 'wsl\compose.yaml') (Join-Path $stage 'compose.yaml') -Force

$envLines = @(
    "LITELLM_MASTER_KEY=$master"
    "SPARK_LITELLM_KEY=$sparkKey"
    "LITELLM_PORT=$($cfg.LiteLLMPort)"
    "OPENWEBUI_PORT=$($cfg.OpenWebUIPort)"
)
if ($cfg.SparkLangfuseUrl) {
    $envLines += "LANGFUSE_HOST=$($cfg.SparkLangfuseUrl)"
    foreach ($k in @('LANGFUSE_PUBLIC_KEY', 'LANGFUSE_SECRET_KEY')) {
        $v = [Environment]::GetEnvironmentVariable($k, 'User')
        if ($v) { $envLines += "$k=$v" } else { Write-Step "$k not set - Langfuse export will be skipped by LiteLLM" -Level Warn }
    }
}
$hfTok = [Environment]::GetEnvironmentVariable('HF_TOKEN', 'User')
if ($hfTok) { $envLines += "HF_TOKEN=$hfTok" }
Write-Utf8NoBom -Path (Join-Path $stage '.env') -Content (($envLines -join "`n") + "`n")

# ---------------------------------------------------------------- copy into WSL + up
$src = ConvertTo-WslPath -WindowsPath $stage -Distro $distro
$profileArg = if ($WithVllm) { '--profile vllm ' } else { '' }
$cmd = @(
    'set -e'
    'mkdir -p ~/surface-ultra'
    "cp '$src/compose.yaml' '$src/litellm.yaml' '$src/litellm-nda.yaml' '$src/.env' ~/surface-ultra/"
    'chmod 600 ~/surface-ultra/.env'
    'cd ~/surface-ultra'
    "docker compose $($profileArg)pull"
    "docker compose $($profileArg)up -d"
    'docker compose ps'
) -join ' && '
$rc = Invoke-Wsl -Distro $distro -Command $cmd
Remove-Item $stage -Recurse -Force
if ($rc -ne 0) { Write-Step "docker compose failed (exit $rc)" -Level Fail; exit 1 }

# ---------------------------------------------------------------- smoke checks from Windows
Start-Sleep -Seconds 10
$hdr = @{ Authorization = "Bearer $master" }
try {
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:$($cfg.LiteLLMPort)/v1/models" -Headers $hdr -TimeoutSec 20
    Write-Step ("LiteLLM up: {0}" -f (($models.data | ForEach-Object id) -join ', ')) -Level Ok
} catch { Write-Step "LiteLLM not answering on 127.0.0.1:$($cfg.LiteLLMPort) yet: $($_.Exception.Message)" -Level Warn }
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:6333/readyz' -TimeoutSec 10 | Out-Null
    Write-Step 'Qdrant ready on 127.0.0.1:6333' -Level Ok
} catch { Write-Step 'Qdrant not ready yet' -Level Warn }
Write-Step "Open WebUI: http://127.0.0.1:$($cfg.OpenWebUIPort) (first account you create becomes admin)" -Level Info
Write-Step 'Stage 60 complete' -Level Ok
exit 0
