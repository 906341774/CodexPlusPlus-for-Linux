#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('discover-features', 'build', 'build-install', 'verify')]
    [string]$Action = 'build-install',

    [string]$SourceRoot,
    [string]$InstallPath = '$HOME/opt/CodexDesktop',
    [string]$BuildSourceCacheRoot,
    [string[]]$EnabledFeatureIds,
    [string]$X11ComputerUseRepository = 'https://github.com/AlekseiSeleznev/codex-computer-use-x11.git',
    [string]$X11ComputerUseRef = 'v0.1.3',
    [string]$X11ComputerUseCommit = '2c50ed6cd2c41e5f38627ef1208f2a65691d66dc',
    [switch]$NoLogoOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path $RepoRoot 'codex-desktop-linux/src'
}
if ([string]::IsNullOrWhiteSpace($BuildSourceCacheRoot)) {
    $BuildSourceCacheRoot = Join-Path $RepoRoot '.cache/build-sources'
}

function Expand-BuildPath {
    param([Parameter(Mandatory = $true)][string]$Value)
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $expanded = $Value.Trim()
    foreach ($prefix in @('$env:HOME', '${HOME}', '$HOME')) {
        if ($expanded -eq $prefix) {
            $expanded = $homePath
            break
        }
        if ($expanded.StartsWith("$prefix/")) {
            $expanded = Join-Path $homePath $expanded.Substring($prefix.Length + 1)
            break
        }
    }
    if ($expanded -eq '~') { $expanded = $homePath }
    if ($expanded.StartsWith('~/')) { $expanded = Join-Path $homePath $expanded.Substring(2) }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-CodexLinuxFeatureIds {
    param([Parameter(Mandatory = $true)][string]$DesktopSourceRoot)

    $featuresRoot = Join-Path $DesktopSourceRoot 'linux-features'
    if (-not (Test-Path -LiteralPath $featuresRoot -PathType Container)) {
        throw "Linux features directory is missing: $featuresRoot"
    }

    $reserved = @('example-feature', 'local')
    $ids = foreach ($directory in Get-ChildItem -LiteralPath $featuresRoot -Directory -Force) {
        if ($directory.Name.StartsWith('.') -or $reserved -contains $directory.Name) { continue }
        $descriptorPath = Join-Path $directory.FullName 'feature.json'
        if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) { continue }
        $descriptor = Get-Content -LiteralPath $descriptorPath -Raw | ConvertFrom-Json
        if (-not $descriptor.id -or [string]$descriptor.id -ne $directory.Name) {
            throw "Linux feature descriptor id must match its directory name: $descriptorPath"
        }
        $directory.Name
    }

    $result = @($ids | Sort-Object -Unique)
    if ($result.Count -eq 0) { throw "No usable Linux features were discovered under $featuresRoot" }
    return $result
}

function Resolve-CodexLinuxFeatureIds {
    param(
        [Parameter(Mandatory = $true)][string]$DesktopSourceRoot,
        [string[]]$ExplicitFeatureIds
    )

    $available = @(Get-CodexLinuxFeatureIds -DesktopSourceRoot $DesktopSourceRoot)
    $requested = @()
    if ($null -ne $ExplicitFeatureIds) {
        $requested = @($ExplicitFeatureIds)
    }
    if ($requested.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:CODEX_LINUX_FEATURES)) {
        $requested = @($env:CODEX_LINUX_FEATURES -split ',')
    }
    if ($requested.Count -eq 0) {
        return $available
    }

    $normalized = @($requested | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    foreach ($id in $normalized) {
        if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Invalid Linux feature id: $id"
        }
        if ($available -notcontains $id) {
            throw "Requested Linux feature is not present under linux-features: $id"
        }
    }
    return @($normalized | Sort-Object -Unique)
}

function Write-CodexLinuxFeaturesConfig {
    param(
        [Parameter(Mandatory = $true)][string]$DesktopSourceRoot,
        [Parameter(Mandatory = $true)][string[]]$FeatureIds
    )
    $configPath = Join-Path $DesktopSourceRoot 'linux-features/features.json'
    [ordered]@{ enabled = @($FeatureIds) } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    return $configPath
}

function Get-GitHeadCommit {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)

    $output = @(& git -C $RepositoryPath rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return '' }
    return ($output -join '').Trim().ToLowerInvariant()
}

function Resolve-X11ComputerUseSource {
    param(
        [Parameter(Mandatory = $true)][string]$DesktopSourceRoot,
        [Parameter(Mandatory = $true)][string[]]$FeatureIds
    )

    if ($FeatureIds -notcontains 'x11-ewmh-computer-use') { return $null }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_X11_COMPUTER_USE_SOURCE)) {
        $explicitSource = Expand-BuildPath $env:CODEX_X11_COMPUTER_USE_SOURCE
        if (-not (Test-Path -LiteralPath (Join-Path $explicitSource 'Cargo.toml') -PathType Leaf)) {
            throw "CODEX_X11_COMPUTER_USE_SOURCE lacks Cargo.toml: $explicitSource"
        }
        return $explicitSource
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to fetch the pinned X11 Computer Use source.'
    }
    if ([string]::IsNullOrWhiteSpace($X11ComputerUseRepository)) {
        throw 'X11ComputerUseRepository must not be empty.'
    }
    if ([string]::IsNullOrWhiteSpace($X11ComputerUseRef)) {
        throw 'X11ComputerUseRef must not be empty.'
    }
    if ($X11ComputerUseCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'X11ComputerUseCommit must be a full 40-character Git commit.'
    }

    $expectedCommit = $X11ComputerUseCommit.ToLowerInvariant()
    $cacheRoot = Join-Path (Expand-BuildPath $BuildSourceCacheRoot) 'codex-computer-use-x11'
    $cachedSource = Join-Path $cacheRoot $expectedCommit
    $cachedCargo = Join-Path $cachedSource 'Cargo.toml'
    if (
        (Test-Path -LiteralPath $cachedCargo -PathType Leaf) -and
        (Get-GitHeadCommit -RepositoryPath $cachedSource) -eq $expectedCommit
    ) {
        Write-Host "Using cached X11 Computer Use source at $cachedSource"
        return $cachedSource
    }

    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    if (Test-Path -LiteralPath $cachedSource) {
        Remove-Item -LiteralPath $cachedSource -Recurse -Force
    }
    $incoming = Join-Path $cacheRoot ".incoming-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        $cloneOutput = @(
            & git clone --quiet --single-branch --depth 1 --branch $X11ComputerUseRef -- $X11ComputerUseRepository $incoming 2>&1
        )
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone pinned X11 Computer Use source: $($cloneOutput -join [Environment]::NewLine)"
        }
        $actualCommit = Get-GitHeadCommit -RepositoryPath $incoming
        if ($actualCommit -ne $expectedCommit) {
            throw "X11 Computer Use ref $X11ComputerUseRef resolved to $actualCommit instead of $expectedCommit."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $incoming 'Cargo.toml') -PathType Leaf)) {
            throw "Pinned X11 Computer Use source lacks Cargo.toml: $incoming"
        }
        Move-Item -LiteralPath $incoming -Destination $cachedSource
    } finally {
        if (Test-Path -LiteralPath $incoming) {
            Remove-Item -LiteralPath $incoming -Recurse -Force
        }
    }

    Write-Host "Fetched pinned X11 Computer Use source at $cachedSource"
    return $cachedSource
}

function Assert-CodexDesktopPayload {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFeatureIds
    )
    foreach ($relative in @('start.sh', '.codex-linux/build-info.json', 'resources/codex-linux-build-info.json')) {
        $path = Join-Path $PayloadRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Codex Desktop payload file is missing: $path"
        }
    }

    $expected = @($ExpectedFeatureIds | Sort-Object)
    foreach ($relative in @('.codex-linux/build-info.json', 'resources/codex-linux-build-info.json')) {
        $path = Join-Path $PayloadRoot $relative
        $buildInfo = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $actual = @($buildInfo.linuxFeatures.enabled | Sort-Object)
        if (($actual -join "`n") -ne ($expected -join "`n")) {
            throw "Linux features in $path do not match discovery. Expected [$($expected -join ', ')], got [$($actual -join ', ')]."
        }
    }
}

function Invoke-CodexDesktopBuild {
    param(
        [Parameter(Mandatory = $true)][string]$DesktopSourceRoot,
        [Parameter(Mandatory = $true)][string[]]$FeatureIds
    )

    if (-not (Get-Command make -ErrorAction SilentlyContinue)) { throw 'make is required to build Codex Desktop.' }
    $payloadRoot = Join-Path $DesktopSourceRoot 'codex-app'
    if (Test-Path -LiteralPath $payloadRoot) {
        Remove-Item -LiteralPath $payloadRoot -Recurse -Force
    }
    $x11ComputerUseSource = Resolve-X11ComputerUseSource -DesktopSourceRoot $DesktopSourceRoot -FeatureIds $FeatureIds
    $configPath = Write-CodexLinuxFeaturesConfig -DesktopSourceRoot $DesktopSourceRoot -FeatureIds $FeatureIds
    $saved = @{
        CODEX_LINUX_FEATURES = $env:CODEX_LINUX_FEATURES
        CODEX_LINUX_FEATURES_CONFIG = $env:CODEX_LINUX_FEATURES_CONFIG
        CODEX_LINUX_DISABLE_FEATURES = $env:CODEX_LINUX_DISABLE_FEATURES
        CODEX_X11_COMPUTER_USE_SOURCE = $env:CODEX_X11_COMPUTER_USE_SOURCE
        PACKAGE_WITH_UPDATER = $env:PACKAGE_WITH_UPDATER
        CODEX_BOOTSTRAP_NONINTERACTIVE = $env:CODEX_BOOTSTRAP_NONINTERACTIVE
        CODEX_LINUX_ENABLE_COMPUTER_USE_UI = $env:CODEX_LINUX_ENABLE_COMPUTER_USE_UI
    }
    try {
        $env:CODEX_LINUX_FEATURES = $FeatureIds -join ','
        $env:CODEX_LINUX_FEATURES_CONFIG = $configPath
        $env:CODEX_LINUX_DISABLE_FEATURES = ''
        $env:PACKAGE_WITH_UPDATER = '0'
        $env:CODEX_BOOTSTRAP_NONINTERACTIVE = '1'
        $env:CODEX_LINUX_ENABLE_COMPUTER_USE_UI = '1'
        if (-not [string]::IsNullOrWhiteSpace($x11ComputerUseSource)) {
            $env:CODEX_X11_COMPUTER_USE_SOURCE = $x11ComputerUseSource
        }
        Push-Location $DesktopSourceRoot
        try {
            & make build-app | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Codex Desktop build failed with exit code $LASTEXITCODE." }
        } finally {
            Pop-Location
        }
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item "Env:$name" $saved[$name]
            }
        }
    }

    Assert-CodexDesktopPayload -PayloadRoot $payloadRoot -ExpectedFeatureIds $FeatureIds
    return $payloadRoot
}

function Install-CodexDesktopPayload {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $incoming = Join-Path $parent ".codexdesktop-incoming-$PID-$([Guid]::NewGuid().ToString('N'))"
    $backup = Join-Path $parent ".codexdesktop-backup-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $PayloadRoot -Destination $incoming -Recurse -Force
        if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $backup }
        try {
            Move-Item -LiteralPath $incoming -Destination $Destination
        } catch {
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $Destination }
            throw
        }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    } finally {
        if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Recurse -Force }
    }
}

$sourceRootFull = Expand-BuildPath $SourceRoot
$installPathFull = Expand-BuildPath $InstallPath
$features = @(Resolve-CodexLinuxFeatureIds -DesktopSourceRoot $sourceRootFull -ExplicitFeatureIds $EnabledFeatureIds)

switch ($Action) {
    'discover-features' {
        if (-not $NoLogoOutput) { Write-Host "Discovered $($features.Count) Linux features." }
        [ordered]@{ enabled = $features } | ConvertTo-Json -Depth 4
    }
    'build' {
        $payload = Invoke-CodexDesktopBuild -DesktopSourceRoot $sourceRootFull -FeatureIds $features
        Write-Host "Validated Codex Desktop payload: $payload"
    }
    'build-install' {
        $payload = Invoke-CodexDesktopBuild -DesktopSourceRoot $sourceRootFull -FeatureIds $features
        Install-CodexDesktopPayload -PayloadRoot $payload -Destination $installPathFull
        Assert-CodexDesktopPayload -PayloadRoot $installPathFull -ExpectedFeatureIds $features
        Write-Host "Installed Codex Desktop with $($features.Count) Linux features at $installPathFull"
    }
    'verify' {
        Assert-CodexDesktopPayload -PayloadRoot $installPathFull -ExpectedFeatureIds $features
        Write-Host "Verified Codex Desktop with $($features.Count) Linux features at $installPathFull"
    }
}
