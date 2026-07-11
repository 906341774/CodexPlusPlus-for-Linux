#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$SkipInstallerSelftest,
    [switch]$SkipCargo,
    [switch]$SkipCodexDesktopNodeTests,
    [switch]$SkipCodexDesktopSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

function Invoke-WithIsolatedHome {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) "codexpp-$Name-$PID"
    $isolatedHome = Join-Path $root 'home'
    $data = Join-Path $root 'data'
    $config = Join-Path $root 'config'
    $cache = Join-Path $root 'cache'
    New-Item -ItemType Directory -Force -Path $isolatedHome, $data, $config, $cache | Out-Null

    # EN: PowerShell may try to initialize modules under the real HOME; isolate it for reproducible local and CI runs.
    # ZH: PowerShell 可能会尝试在真实 HOME 下初始化模块；这里隔离 HOME，保证本地和 CI 行为可复现。
    $oldHome = $env:HOME
    $oldData = $env:XDG_DATA_HOME
    $oldConfig = $env:XDG_CONFIG_HOME
    $oldCache = $env:XDG_CACHE_HOME
    try {
        $env:HOME = $isolatedHome
        $env:XDG_DATA_HOME = $data
        $env:XDG_CONFIG_HOME = $config
        $env:XDG_CACHE_HOME = $cache
        & $Script
    } finally {
        $env:HOME = $oldHome
        $env:XDG_DATA_HOME = $oldData
        $env:XDG_CONFIG_HOME = $oldConfig
        $env:XDG_CACHE_HOME = $oldCache
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Write-Host "== $Label =="
    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Label failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

Push-Location $RepoRoot
try {
    Write-Host '== Adapter workflow contract =='
    Invoke-WithIsolatedHome 'workflow' {
        & (Join-Path $RepoRoot 'scripts/developer/Test-AdapterWorkflow.ps1')
    }

    Write-Host '== Distribution workflow contract =='
    Invoke-WithIsolatedHome 'distribution' {
        & (Join-Path $RepoRoot 'tests/Test-DistributionWorkflow.ps1')
    }

    if (-not $SkipInstallerSelftest) {
        Write-Host '== Installer selftest =='
        Invoke-WithIsolatedHome 'installer' {
            & (Join-Path $RepoRoot 'scripts/developer/Installer-and-Manager.ps1') selftest -NonInteractive -NoTui
        }
    }


    $codexPlusPlusRoot = Join-Path $RepoRoot 'CodexPlusPlus/src'
    if (-not $SkipCargo) {
        Invoke-NativeChecked -Label 'Codex++ core regression tests' -FilePath 'cargo' -WorkingDirectory $codexPlusPlusRoot -Arguments @(
            'test', '--locked', '-p', 'codex-plus-core',
            '--test', 'bridge_routes',
            '--test', 'cdp_bridge',
            '--test', 'codex_sqlite',
            '--test', 'installers',
            '--test', 'launcher',
            '--test', 'relay_config',
            '--test', 'watcher'
        )
        Invoke-NativeChecked -Label 'Codex++ provider sync regression tests' -FilePath 'cargo' -WorkingDirectory $codexPlusPlusRoot -Arguments @(
            'test', '--locked', '-p', 'codex-plus-data', '--test', 'provider_sync'
        )
    }
    Invoke-NativeChecked -Label 'Codex++ Pure API Node contract' -FilePath 'node' -WorkingDirectory $codexPlusPlusRoot -Arguments @(
        '--test', 'apps/codex-plus-manager/src/relay-config-contract.test.mjs'
    )

    $codexDesktopRoot = Join-Path $RepoRoot 'codex-desktop-linux/src'
    if (-not $SkipCodexDesktopNodeTests) {
        $desktopNodeTests = @(
            Get-ChildItem -LiteralPath (Join-Path $codexDesktopRoot 'scripts') -Recurse -File |
                Where-Object { $_.Name -like '*.test.js' }
            Get-ChildItem -LiteralPath (Join-Path $codexDesktopRoot 'linux-features') -Recurse -File |
                Where-Object { $_.Name -eq 'test.js' }
        ) | Sort-Object FullName -Unique | ForEach-Object { $_.FullName }
        $desktopNodeArguments = @('--test') + @($desktopNodeTests)
        Invoke-NativeChecked -Label 'CodexDesktop Node regression tests' -FilePath 'node' -WorkingDirectory $codexDesktopRoot -Arguments $desktopNodeArguments
    }
    if (-not $SkipCodexDesktopSmoke) {
        Invoke-NativeChecked -Label 'CodexDesktop script smoke tests' -FilePath 'bash' -WorkingDirectory $codexDesktopRoot -Arguments @('tests/scripts_smoke.sh')
    }

    Write-Host 'Adapter regression checks OK.'
} finally {
    Pop-Location
}
