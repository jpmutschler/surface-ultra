#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a research project in the NDA workspace for tools\plan\plan.ps1.
.DESCRIPTION
    <NDA root>\projects\<Name>\
        sources\public\   copies of -Public files (public specs, datasheets, app notes)
        sources\vendor\   copies of -Vendor files (NDA SDKs, headers, vendor docs)
        plan\00-brief.md  template - fill in goals, users, constraints before 'plan scope'
        project.json      models and endpoint (local llama-swap by default)
    The default endpoint is llama-swap on loopback, not LiteLLM, so NDA prompts never pass through
    the gateway's trace export. Point base_url at the Spark only for an NDA-zone model you trust there.
.EXAMPLE
    .\New-ResearchProject.ps1 -Name acme-switch-api -Vendor acme `
        -Public D:\specs\pcie6\*.pdf -VendorDocs D:\nda\docs\acme\sdk-4.2
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}$')][string]$Name,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,30}$')][string]$Vendor,
    [string]$Title,
    [string[]]$Public = @(),
    [string[]]$VendorDocs = @()
)
Import-Module (Join-Path $PSScriptRoot '..\..\lib\SurfaceUltra.psm1') -Force
$cfg = Get-MachineConfig
if (-not (Test-Path $cfg.NdaRoot)) { Write-Step "No NDA workspace - run tools\NdaSession.ps1 -Init first" -Level Fail; exit 1 }
$root = Join-Path $cfg.NdaRoot "projects\$Name"
if ((Test-Path $root) -and (Test-Path (Join-Path $root 'project.json'))) {
    Write-Step "$root already exists - adding sources only" -Level Info
}
foreach ($d in @('sources\public', 'sources\vendor', 'plan\sections', 'notes', 'handoff', 'index')) {
    New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
}

function Copy-Sources([string[]]$Items, [string]$Dest) {
    $n = 0
    foreach ($item in $Items) {
        foreach ($src in @(Resolve-Path $item -ErrorAction SilentlyContinue)) {
            if (-not $PSCmdlet.ShouldProcess($src.Path, "copy -> $Dest")) { continue }
            if (Test-Path $src.Path -PathType Container) {
                Copy-Item $src.Path -Destination (Join-Path $Dest (Split-Path $src.Path -Leaf)) -Recurse -Force
            } else { Copy-Item $src.Path -Destination $Dest -Force }
            $n++
        }
        if (-not (Resolve-Path $item -ErrorAction SilentlyContinue)) { Write-Step "Not found: $item" -Level Warn }
    }
    $n
}
$np = Copy-Sources $Public (Join-Path $root 'sources\public')
$nv = Copy-Sources $VendorDocs (Join-Path $root 'sources\vendor')
Write-Step "Sources: $np public item(s), $nv vendor item(s)" -Level Ok

$pj = Join-Path $root 'project.json'
if (-not (Test-Path $pj)) {
    $listen = $cfg.LlamaSwapListen
    $project = [ordered]@{
        name      = $Name
        title     = $(if ($Title) { $Title } else { $Name })
        vendor    = $Vendor
        created   = (Get-Date).ToString('s')
        base_url  = "http://$listen/v1"
        terms_dir = $cfg.NdaTermsDir
        models    = [ordered]@{
            research = 'sc-research'     # drafts and revisions
            critic   = 'sc-analyst'      # a different model family checks the drafts
            embed    = 'sc-embed'
            rerank   = 'sc-rerank'
        }
    }
    Write-Utf8NoBom -Path $pj -Content ($project | ConvertTo-Json -Depth 4)
}
$brief = Join-Path $root 'plan\00-brief.md'
if (-not (Test-Path $brief)) {
    Write-Utf8NoBom -Path $brief -Content @"
# Brief: $(if ($Title) { $Title } else { $Name })

## What we are building
(One paragraph: the API/UI, who it is for, the problem it solves.)

## Users and workflows
-

## Must have / out of scope
-

## Interfaces and hardware
(Host OS, transports - PCIe, MCTP over SMBus/I3C, UART - devices under test, the vendor SDK in sources\vendor.)

## Constraints
(Release model: our own API, distributable without the vendor SDK. Languages, licensing, deadlines.)

## Questions I already have
-
"@
}
Write-Step "Project ready: $root" -Level Ok
Write-Step "Next: edit plan\00-brief.md, then  tools\plan\plan.ps1 ingest -Project $Name" -Level Info
exit 0
