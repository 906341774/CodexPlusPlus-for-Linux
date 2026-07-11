#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CodexPlusPlusVersion,
    [Parameter(Mandatory = $true)][string]$CodexDesktopCommit,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$ManagerScript = Join-Path $RepoRoot 'scripts/normal_user/CodexDesktop-Portable-Manager.ps1'

function Resolve-SevenZip {
    foreach ($name in @('7zz', '7z')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw '7zz is required to create the portable release.'
}

function Assert-PortablePayload {
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($relative in @(
        'start.sh',
        '.codex-linux/build-info.json',
        'resources/codex-linux-build-info.json',
        '.codex-plusplus/install/codex-plus-plus',
        '.codex-plusplus/install/codex-plus-plus-manager',
        '.codex-plusplus/install/launch-codex-plus-plus'
    )) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Portable payload is incomplete: $path"
        }
    }
}

$payloadRootFull = [System.IO.Path]::GetFullPath($PayloadRoot)
$outputPathFull = [System.IO.Path]::GetFullPath($OutputPath)
Assert-PortablePayload $payloadRootFull
if (-not (Test-Path -LiteralPath $ManagerScript -PathType Leaf)) {
    throw "Portable manager is missing: $ManagerScript"
}

$outputParent = Split-Path -Parent $outputPathFull
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codexdesktop-portable-$PID-$([Guid]::NewGuid().ToString('N'))"
$partialPath = "$outputPathFull.partial-$PID"
try {
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    Copy-Item -LiteralPath $payloadRootFull -Destination (Join-Path $stageRoot 'CodexDesktop') -Recurse -Force
    Copy-Item -LiteralPath $ManagerScript -Destination (Join-Path $stageRoot 'CodexDesktop-Portable-Manager.ps1') -Force

    $buildInfo = Get-Content -LiteralPath (Join-Path $payloadRootFull '.codex-linux/build-info.json') -Raw | ConvertFrom-Json
    $manifest = [ordered]@{
        schemaVersion = 1
        packageType = 'codex-desktop-portable-7z'
        version = $Version
        codexPlusPlusVersion = $CodexPlusPlusVersion
        codexDesktopCommit = $CodexDesktopCommit
        linuxFeatures = @($buildInfo.linuxFeatures.enabled | Sort-Object)
        payloadDirectory = 'CodexDesktop'
        userDataPreservedByDefault = $true
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stageRoot 'portable-manifest.json') -Encoding utf8NoBOM

    if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
    $sevenZip = Resolve-SevenZip
    Push-Location $stageRoot
    try {
        & $sevenZip a '-t7z' '-mx=9' '-m0=lzma2' '-ms=off' '-mmt=on' '-bb1' $partialPath 'CodexDesktop' 'CodexDesktop-Portable-Manager.ps1' 'portable-manifest.json'
        if ($LASTEXITCODE -ne 0) { throw "7z failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }

    $listing = @(& $sevenZip l -slt -- $partialPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($listing -join "`n") -notmatch '(?m)^Solid = -$')) {
        throw 'Portable archive verification failed: archive is unreadable or solid.'
    }

    if (Test-Path -LiteralPath $outputPathFull) { Remove-Item -LiteralPath $outputPathFull -Force }
    Move-Item -LiteralPath $partialPath -Destination $outputPathFull
    $hash = (Get-FileHash -LiteralPath $outputPathFull -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($outputPathFull))" |
        Set-Content -LiteralPath "$outputPathFull.sha256" -Encoding ascii
    Write-Host "Created portable release: $outputPathFull"
    Write-Host "SHA256: $hash"
} finally {
    if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}
