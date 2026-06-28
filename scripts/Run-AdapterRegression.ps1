#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$SkipInstallerSelftest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

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

Push-Location $RepoRoot
try {
    Write-Host '== Adapter workflow contract =='
    Invoke-WithIsolatedHome 'workflow' {
        & (Join-Path $RepoRoot 'scripts/Test-AdapterWorkflow.ps1')
    }

    if (-not $SkipInstallerSelftest) {
        Write-Host '== Installer selftest =='
        Invoke-WithIsolatedHome 'installer' {
            & (Join-Path $RepoRoot 'scripts/Installer-and-Manager.ps1') selftest -NonInteractive -NoTui
        }
    }

    Write-Host 'Adapter regression checks OK.'
} finally {
    Pop-Location
}
