#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Join-Path $RepoRoot $Path
}

function Assert-FileExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = Resolve-RepoPath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required workflow file is missing: $Path"
    }
}

function Assert-TextContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $fullPath = Resolve-RepoPath $Path
    $text = Get-Content -LiteralPath $fullPath -Raw
    if (-not $text.Contains($Needle)) {
        throw "Workflow contract failed: $Label was not found in $Path"
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = Resolve-RepoPath $Path
    return Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
}

# EN: These files are the durable maintenance contract for each upstream update.
# ZH: 这些文件共同构成每次上游更新时必须遵守的固定维护契约。
$requiredFiles = @(
    'docs/modules/ROOT/pages/adapter-workflow.adoc',
    'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc',
    'docs/modules/ROOT/attachments/feature-matrix.json',
    'docs/modules/ROOT/attachments/patches/compatibility/.gitkeep',
    'docs/modules/ROOT/attachments/patches/enhancements/.gitkeep',
    '.github/workflows/adaptation-regression.yml',
    'scripts/run-adapter-regression.sh',
    'scripts/Run-AdapterRegression.ps1',
    'scripts/Installer-and-Manager.ps1'
)

foreach ($file in $requiredFiles) {
    Assert-FileExists $file
}

# EN: The feature matrix must cover every known Linux adaptation surface.
# ZH: 功能矩阵必须覆盖所有已知的 Linux 适配功能面。
$matrix = Read-JsonFile 'docs/modules/ROOT/attachments/feature-matrix.json'
if (-not $matrix.features -or $matrix.features.Count -lt 10) {
    throw 'Feature matrix must describe at least ten adaptation feature contracts.'
}

$requiredFeatureIds = @(
    'linux-app-paths',
    'cdp-main-window-injection',
    'launcher-environment',
    'entrypoint-health',
    'pure-api-config-sync',
    'plugins-navigation',
    'plugins-detail',
    'delete-conversation-stability',
    'fast-button',
    'context-used-meter'
)

$featureIds = @($matrix.features | ForEach-Object { $_.id })
foreach ($id in $requiredFeatureIds) {
    if ($featureIds -notcontains $id) {
        throw "Feature matrix is missing required feature id: $id"
    }
}

foreach ($feature in $matrix.features) {
    if (-not $feature.patchIds -or $feature.patchIds.Count -eq 0) {
        throw "Feature $($feature.id) must name at least one patch id."
    }
    if (-not $feature.whiteBoxChecks -or $feature.whiteBoxChecks.Count -eq 0) {
        throw "Feature $($feature.id) must name at least one white-box check."
    }
    if (-not $feature.blackBoxChecks -or $feature.blackBoxChecks.Count -eq 0) {
        throw "Feature $($feature.id) must name at least one black-box check."
    }
}

# EN: The scheduled workflow must be manually runnable and must not push without an explicit release job.
# ZH: 定时工作流必须支持手动触发，并且不能在未进入明确发布任务时自动推送。
Assert-TextContains '.github/workflows/adaptation-regression.yml' 'workflow_dispatch:' 'manual workflow trigger'
Assert-TextContains '.github/workflows/adaptation-regression.yml' 'schedule:' 'scheduled workflow trigger'
Assert-TextContains '.github/workflows/adaptation-regression.yml' 'Test-AdapterWorkflow.ps1' 'workflow contract test'
Assert-TextContains '.github/workflows/adaptation-regression.yml' 'Installer-and-Manager.ps1 selftest' 'installer selftest'
Assert-TextContains '.github/workflows/adaptation-regression.yml' 'permissions:' 'explicit workflow permissions'
Assert-TextContains 'scripts/run-adapter-regression.sh' 'XDG_DATA_HOME' 'local shell wrapper isolates PowerShell startup'
Assert-TextContains 'scripts/Run-AdapterRegression.ps1' 'Test-AdapterWorkflow.ps1' 'local regression contract step'
Assert-TextContains 'scripts/Run-AdapterRegression.ps1' 'Installer-and-Manager.ps1' 'local regression installer selftest step'

# EN: Documentation must point maintainers to the machine-checkable feature matrix.
# ZH: 文档必须把维护者引向可机器检查的功能矩阵。
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'feature-matrix.json' 'English workflow feature matrix link'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' 'feature-matrix.json' 'Chinese workflow feature matrix link'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'patches/compatibility/' 'English snippets compatibility patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'patches/enhancements/' 'English snippets enhancement patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' 'patches/compatibility/' 'Chinese snippets compatibility patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' 'patches/enhancements/' 'Chinese snippets enhancement patch directory'
Assert-TextContains 'docs/modules/ROOT/nav.adoc' 'adapter-workflow.adoc' 'English nav entry'
Assert-TextContains 'docs/modules/ROOT/nav.adoc' 'adapter-workflow_zh-CN.adoc' 'Chinese nav entry'

Write-Host 'Adapter workflow contract OK.'
