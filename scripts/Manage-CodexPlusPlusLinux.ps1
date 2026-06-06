#!/usr/bin/env pwsh
#Requires -Version 7.2

[CmdletBinding()]
param(
    [ValidateSet("install", "update", "uninstall", "list-snippets", "apply-snippets", "selftest")]
    [string]$Action = "install",

    [switch]$NonInteractive,
    [switch]$NoTui,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$KeepWorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# Configuration / 配置区域
# =============================================================================

# Codex Desktop Linux root directory.
# Linux 版 Codex Desktop 的安装根目录。
# Supported variable forms / 支持变量形式:
#   $HOME/path, ${HOME}/path, $env:HOME/path, ~/path
[string]$CodexDesktopRoot = '$HOME/opt/codex-desktop-linux'

# Local Codex++ source repository or extracted source directory.
# 已 clone 或已解压的 Codex++ 源码目录。
# Optional / 可选:
#   empty string: fetch BigPizzaV3/CodexPlusPlus from GitHub
#   non-empty: copy this local source as the build input
[string]$CodexPlusPlusLocalSource = ''

# Local Codex++ release/source package.
# 已下载的 Codex++ release 或源码包路径。
# Optional / 可选:
#   empty string: ignored
#   .zip: extracted with PowerShell Expand-Archive
#   .tar.gz/.tgz/.tar.xz/.txz: extracted with system tar if available
#   .dmg: detected but not source-patchable on Linux; script falls back to source fetch
[string]$CodexPlusPlusReleasePackage = ''

# Adapted Codex++ install path.
# 适配后的 Codex++ 安装路径。
# Optional values / 可选值:
#   relative path: resolved from CodexDesktopRoot, e.g. codex-app/.codex-plusplus
#   absolute path: used as-is
[string]$CodexPlusPlusInstallPath = 'codex-app/.codex-plusplus'

# Upstream source URL used when no local source or package is configured.
# 未指定本地源码或包时使用的上游源码地址。
[string]$CodexPlusPlusGitHubRepo = 'https://github.com/BigPizzaV3/CodexPlusPlus'
[string]$CodexPlusPlusMainZipUrl = 'https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/heads/main.zip'
[string]$CodexPlusPlusMasterZipUrl = 'https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/heads/master.zip'

# Snippet controls.
# 片段注入控制。
# IncludeRegressionTestSnippets / 是否注入回归测试片段:
#   true: inject production snippets and test snippets
#   false: inject production snippets only
[bool]$IncludeRegressionTestSnippets = $true

# EnabledSnippetIds / 仅启用这些片段:
#   empty array: use manifest defaultEnabled values
#   non-empty: only IDs listed here are enabled, unless explicitly disabled
[string[]]$EnabledSnippetIds = @()

# DisabledSnippetIds / 禁用这些片段:
#   empty array: disable nothing
#   non-empty: these IDs are skipped even if defaultEnabled=true
[string[]]$DisabledSnippetIds = @()

# Dependency handling.
# 依赖处理。
# DependencyMode choices / 可选项:
#   auto: use system tool if present; download temporary tool if missing
#   system: require system cargo/node/npm/git
#   temp: prefer temporary tools under Codex++ install directory
[ValidateSet("auto", "system", "temp")]
[string]$DependencyMode = "auto"

# Build mode choices / 构建模式:
#   release: optimized production binaries
#   debug: faster development build
[ValidateSet("release", "debug")]
[string]$BuildMode = "release"

# Runtime defaults / 运行默认值。
[int]$DebugPort = 9229
[int]$HelperPort = 57321
[bool]$CheckUpdatesByDefault = $false
[bool]$CreateDesktopEntries = $true
[bool]$PreserveUserScriptsOnUninstall = $true
[string]$TemporaryToolsDirName = 'tools'
[string]$WorkDirName = 'work'

# Environment overrides for CI/container runs.
# CI/容器运行时的环境变量覆盖。
if ($env:CODEXPP_LINUX_CODEX_DESKTOP_ROOT) { $CodexDesktopRoot = $env:CODEXPP_LINUX_CODEX_DESKTOP_ROOT }
if ($env:CODEXPP_LINUX_LOCAL_SOURCE) { $CodexPlusPlusLocalSource = $env:CODEXPP_LINUX_LOCAL_SOURCE }
if ($env:CODEXPP_LINUX_RELEASE_PACKAGE) { $CodexPlusPlusReleasePackage = $env:CODEXPP_LINUX_RELEASE_PACKAGE }
if ($env:CODEXPP_LINUX_INSTALL_PATH) { $CodexPlusPlusInstallPath = $env:CODEXPP_LINUX_INSTALL_PATH }
if ($env:CODEXPP_LINUX_DEPENDENCY_MODE) { $DependencyMode = $env:CODEXPP_LINUX_DEPENDENCY_MODE }
if ($env:CODEXPP_LINUX_BUILD_MODE) { $BuildMode = $env:CODEXPP_LINUX_BUILD_MODE }
if ($env:CODEXPP_LINUX_INCLUDE_TEST_SNIPPETS) { $IncludeRegressionTestSnippets = [System.Convert]::ToBoolean($env:CODEXPP_LINUX_INCLUDE_TEST_SNIPPETS) }
if ($env:CODEXPP_LINUX_CREATE_DESKTOP_ENTRIES) { $CreateDesktopEntries = [System.Convert]::ToBoolean($env:CODEXPP_LINUX_CREATE_DESKTOP_ENTRIES) }
if ($env:CODEXPP_LINUX_PRESERVE_USER_SCRIPTS) { $PreserveUserScriptsOnUninstall = [System.Convert]::ToBoolean($env:CODEXPP_LINUX_PRESERVE_USER_SCRIPTS) }

# =============================================================================
# Localization / 本地化
# =============================================================================

function Test-ChineseLocale {
    $candidates = @(
        [System.Globalization.CultureInfo]::CurrentUICulture.Name,
        [System.Globalization.CultureInfo]::CurrentCulture.Name,
        $env:LANG,
        $env:LC_ALL,
        $env:LC_MESSAGES
    ) | Where-Object { $_ }
    foreach ($item in $candidates) {
        if ($item -match '^(zh|cmn|yue)(-|_|$)' -or $item -match '(zh_CN|zh_TW|zh_HK|zh_MO|zh_SG|zh_MY|Chinese)') {
            return $true
        }
    }
    return $false
}

$script:UseChinese = Test-ChineseLocale
$script:Messages = @{
    zh = @{
        Title = 'Codex++ Linux 适配管理器'
        Total = '总流程'
        Step = '当前步骤'
        Log = '操作记录'
        Done = '完成'
        Failed = '失败'
        Continue = '继续'
        ConfirmInstall = '确认开始安装/更新适配后的 Codex++ 吗？'
        ConfirmUninstall = '确认卸载适配后的 Codex++ 吗？'
        CheckUpdates = '是否检查 BigPizzaV3/CodexPlusPlus 更新？默认否'
        PurgeWork = '是否清理本次下载/构建临时文件？默认是'
        CodexMissing = '未检测到 Linux Codex Desktop。请先按照 ilysenko/codex-desktop-linux 的 README 安装。'
        SourceDmg = '检测到 DMG 包；Linux 上无法直接对 DMG 二进制包做源码注入，将改为获取源码。'
        SnippetAlready = '片段已存在，跳过'
        SnippetApply = '正在注入片段'
    }
    en = @{
        Title = 'Codex++ Linux Adapter Manager'
        Total = 'Overall'
        Step = 'Current step'
        Log = 'Operation log'
        Done = 'Done'
        Failed = 'Failed'
        Continue = 'Continue'
        ConfirmInstall = 'Start installing/updating the adapted Codex++ now?'
        ConfirmUninstall = 'Uninstall the adapted Codex++ now?'
        CheckUpdates = 'Check BigPizzaV3/CodexPlusPlus for updates? Default no'
        PurgeWork = 'Purge downloaded/build temporary files? Default yes'
        CodexMissing = 'Linux Codex Desktop was not detected. Install it first by following ilysenko/codex-desktop-linux README.'
        SourceDmg = 'A DMG package was detected. It is not source-patchable on Linux; the script will fetch source instead.'
        SnippetAlready = 'Snippet already applied, skipping'
        SnippetApply = 'Applying snippet'
    }
}

function T([string]$Key) {
    $lang = if ($script:UseChinese) { 'zh' } else { 'en' }
    return $script:Messages[$lang][$Key]
}

# =============================================================================
# TUI / 终端界面
# =============================================================================

$script:IsInteractive = -not $NoTui -and -not $NonInteractive -and [Environment]::UserInteractive
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:TotalPercent = 0
$script:StepPercent = 0
$script:CurrentStep = ''
$script:CurrentDetail = ''

function Add-AdapterLog {
    param([string]$Message)
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $script:LogLines.Add("[$stamp] $Message")
    if ($script:LogLines.Count -gt 400) {
        $script:LogLines.RemoveRange(0, $script:LogLines.Count - 400)
    }
    if (-not $script:IsInteractive) {
        Write-Host "[$stamp] $Message"
    }
}

function New-ProgressBar {
    param(
        [int]$Percent,
        [int]$Width = 42,
        [string]$Color = "`e[36m"
    )
    $bounded = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [Math]::Floor($Width * $bounded / 100)
    $empty = $Width - $filled
    $filledText = [string]::Empty.PadLeft($filled, '█')
    $emptyText = [string]::Empty.PadLeft($empty, '░')
    return "$Color$filledText`e[0m$emptyText $bounded%"
}

function Render-AdapterTui {
    if (-not $script:IsInteractive) { return }
    $height = 16
    $logs = $script:LogLines | Select-Object -Last 8
    Write-Host "`e[2J`e[H" -NoNewline
    Write-Host "╔════════════════════════════════════════════════════════════════════╗"
    Write-Host ("║ {0,-66} ║" -f (T 'Title'))
    Write-Host "╠════════════════════════════════════════════════════════════════════╣"
    Write-Host ("║ {0,-10} {1,-53} ║" -f (T 'Total'), (New-ProgressBar $script:TotalPercent 38 "`e[35m"))
    Write-Host ("║ {0,-10} {1,-53} ║" -f (T 'Step'), (New-ProgressBar $script:StepPercent 38 "`e[32m"))
    Write-Host ("║ {0,-66} ║" -f ($script:CurrentStep.Substring(0, [Math]::Min(66, $script:CurrentStep.Length))))
    Write-Host ("║ {0,-66} ║" -f ($script:CurrentDetail.Substring(0, [Math]::Min(66, $script:CurrentDetail.Length))))
    Write-Host "╠════════════════════════════════════════════════════════════════════╣"
    Write-Host ("║ {0,-66} ║" -f (T 'Log'))
    foreach ($line in $logs) {
        $text = $line.Substring(0, [Math]::Min(66, $line.Length))
        Write-Host ("║ {0,-66} ║" -f $text)
    }
    for ($i = $logs.Count; $i -lt 8; $i++) {
        Write-Host "║                                                                    ║"
    }
    Write-Host "╚════════════════════════════════════════════════════════════════════╝"
}

function Set-AdapterProgress {
    param(
        [int]$Total,
        [int]$Step,
        [string]$StepName,
        [string]$Detail
    )
    $script:TotalPercent = $Total
    $script:StepPercent = $Step
    $script:CurrentStep = $StepName
    $script:CurrentDetail = $Detail
    Render-AdapterTui
}

function Invoke-AdapterStep {
    param(
        [int]$Total,
        [string]$Name,
        [scriptblock]$Body
    )
    Set-AdapterProgress -Total $Total -Step 0 -StepName $Name -Detail ''
    Add-AdapterLog $Name
    & $Body
    Set-AdapterProgress -Total $Total -Step 100 -StepName $Name -Detail (T 'Done')
}

function Confirm-AdapterAction {
    param([string]$Prompt, [bool]$Default = $true)
    if ($NonInteractive) { return $Default }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^(y|yes|是|好|确定|確認)$'
}

# =============================================================================
# Path and process helpers / 路径与进程辅助
# =============================================================================

function Expand-AdapterPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $value = $PathValue.Trim()
    if ($value -eq '$env:HOME') {
        $value = $userHome
    } elseif ($value.StartsWith('$env:HOME/')) {
        $value = Join-Path $userHome $value.Substring('$env:HOME/'.Length)
    } elseif ($value -eq '${HOME}') {
        $value = $userHome
    } elseif ($value.StartsWith('${HOME}/')) {
        $value = Join-Path $userHome $value.Substring('${HOME}/'.Length)
    } elseif ($value -eq '$HOME') {
        $value = $userHome
    } elseif ($value.StartsWith('$HOME/')) {
        $value = Join-Path $userHome $value.Substring('$HOME/'.Length)
    } elseif ($value.StartsWith('~/')) {
        $value = Join-Path $userHome $value.Substring(2)
    } elseif ($value -eq '~') {
        $value = $userHome
    }
    return [System.IO.Path]::GetFullPath($value)
}

function Quote-ShSingle {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Resolve-AdapterInstallPath {
    param([string]$DesktopRoot, [string]$InstallPath)
    $raw = $InstallPath.Trim()
    $usesShellRoot = $raw -eq '~' -or $raw.StartsWith('~/') -or $raw.StartsWith('$HOME') -or $raw.StartsWith('${HOME}') -or $raw.StartsWith('$env:HOME')
    if ([System.IO.Path]::IsPathRooted($raw) -or $usesShellRoot) {
        return Expand-AdapterPath $raw
    }
    return [System.IO.Path]::GetFullPath((Join-Path $DesktopRoot $raw))
}

function Test-CommandAvailable {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{}
    )
    Add-AdapterLog ("$FilePath " + ($Arguments -join ' '))
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($key in $Environment.Keys) {
        $psi.Environment[$key] = [string]$Environment[$key]
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($stdout.Trim()) { Add-AdapterLog $stdout.Trim() }
    if ($stderr.Trim()) { Add-AdapterLog $stderr.Trim() }
    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath $($Arguments -join ' ')`n$stderr"
    }
    return $stdout
}

function Copy-DirectoryTree {
    param([string]$Source, [string]$Destination)
    if (Test-Path $Destination) {
        [System.IO.Directory]::Delete($Destination, $true)
    }
    [void][System.IO.Directory]::CreateDirectory($Destination)
    $sourceFull = [System.IO.Path]::GetFullPath($Source)
    foreach ($item in [System.IO.Directory]::EnumerateFileSystemEntries($sourceFull, '*', [System.IO.SearchOption]::AllDirectories)) {
        $relative = [System.IO.Path]::GetRelativePath($sourceFull, $item)
        if ($relative -match '(^|/|\\)(\.git|target|node_modules)(/|\\|$)') { continue }
        $target = Join-Path $Destination $relative
        if ([System.IO.Directory]::Exists($item)) {
            [void][System.IO.Directory]::CreateDirectory($target)
        } else {
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
            [System.IO.File]::Copy($item, $target, $true)
        }
    }
}

function Find-ExtractedSourceRoot {
    param([string]$Directory)
    $candidates = Get-ChildItem -LiteralPath $Directory -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'Cargo.toml')
    }
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }
    if (Test-Path (Join-Path $Directory 'Cargo.toml')) { return $Directory }
    throw "Could not locate Codex++ source root in $Directory"
}

# =============================================================================
# Snippet manifest / 片段清单
# =============================================================================

function Get-RepositoryRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Read-SnippetManifest {
    $repo = Get-RepositoryRoot
    $page = Join-Path $repo 'docs/modules/ROOT/pages/snippets.adoc'
    $text = [System.IO.File]::ReadAllText($page)
    $match = [Regex]::Match($text, '// tag::snippet-manifest\[\].*?----\s*(?<json>\[.*?\])\s*----.*?// end::snippet-manifest\[\]', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "Could not parse snippet manifest from $page"
    }
    return $match.Groups['json'].Value | ConvertFrom-Json
}

function Get-EnabledSnippets {
    param([object[]]$Manifest)
    $enabledSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $EnabledSnippetIds) { [void]$enabledSet.Add($id) }
    $disabledSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $DisabledSnippetIds) { [void]$disabledSet.Add($id) }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($snippet in $Manifest) {
        $enabled = if ($enabledSet.Count -gt 0) { $enabledSet.Contains($snippet.id) } else { [bool]$snippet.defaultEnabled }
        if ($snippet.kind -eq 'test' -and -not $IncludeRegressionTestSnippets) { $enabled = $false }
        if ($disabledSet.Contains($snippet.id)) { $enabled = $false }
        if ($snippet.required -and $disabledSet.Contains($snippet.id)) {
            Add-AdapterLog "Required snippet disabled by configuration: $($snippet.id)"
        }
        if ($enabled) { [void]$result.Add($snippet) }
    }
    return $result.ToArray()
}

function Apply-SnippetPatch {
    param([string]$SourceRoot, [object]$Snippet)
    $repo = Get-RepositoryRoot
    $patchPath = Join-Path $repo ([string]$Snippet.patch)
    if (-not (Test-Path $patchPath)) {
        throw "Patch attachment not found: $patchPath"
    }
    Set-AdapterProgress -Total $script:TotalPercent -Step 20 -StepName (T 'SnippetApply') -Detail $Snippet.id
    $checkOk = $true
    try {
        Invoke-External -FilePath 'git' -Arguments @('apply', '--check', $patchPath) -WorkingDirectory $SourceRoot | Out-Null
    } catch {
        Add-AdapterLog "Patch check failed for $($Snippet.id): $($_.Exception.Message)"
        $checkOk = $false
    }
    if ($checkOk) {
        Invoke-External -FilePath 'git' -Arguments @('apply', $patchPath) -WorkingDirectory $SourceRoot | Out-Null
        Add-AdapterLog "Applied snippet: $($Snippet.id)"
        return
    }

    $reverseOk = $true
    try {
        Invoke-External -FilePath 'git' -Arguments @('apply', '--reverse', '--check', $patchPath) -WorkingDirectory $SourceRoot | Out-Null
    } catch {
        Add-AdapterLog "Reverse patch check failed for $($Snippet.id): $($_.Exception.Message)"
        $reverseOk = $false
    }
    if ($reverseOk) {
        Add-AdapterLog "$(T 'SnippetAlready'): $($Snippet.id)"
        return
    }
    throw "Snippet $($Snippet.id) cannot be applied cleanly. Upstream may have changed this area."
}

# =============================================================================
# Source and dependencies / 源码与依赖
# =============================================================================

function Test-CodexDesktopInstall {
    param([string]$CodexRoot)
    $appDir = Join-Path $CodexRoot 'codex-app'
    $start = Join-Path $appDir 'start.sh'
    return [pscustomobject]@{
        Root = $CodexRoot
        AppDir = $appDir
        StartScript = $start
        Installed = (Test-Path $start)
        Version = if (Test-Path (Join-Path $appDir 'version')) { ([System.IO.File]::ReadAllText((Join-Path $appDir 'version')).Trim()) } else { 'unknown' }
    }
}

function Get-CodexPlusPlusVersion {
    param([string]$SourceRoot)
    $cargo = Join-Path $SourceRoot 'Cargo.toml'
    if (-not (Test-Path $cargo)) { return 'unknown' }
    $text = [System.IO.File]::ReadAllText($cargo)
    $match = [Regex]::Match($text, '(?m)^\s*version\s*=\s*"(?<v>[^"]+)"')
    if ($match.Success) { return $match.Groups['v'].Value }
    return 'unknown'
}

function Prepare-Source {
    param([string]$WorkRoot)
    $sourceRoot = Join-Path $WorkRoot 'source'
    $downloadRoot = Join-Path $WorkRoot 'download'
    [void][System.IO.Directory]::CreateDirectory($downloadRoot)

    if (-not [string]::IsNullOrWhiteSpace($CodexPlusPlusLocalSource)) {
        $local = Expand-AdapterPath $CodexPlusPlusLocalSource
        Add-AdapterLog "Using local Codex++ source: $local"
        Copy-DirectoryTree -Source $local -Destination $sourceRoot
        return $sourceRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($CodexPlusPlusReleasePackage)) {
        $package = Expand-AdapterPath $CodexPlusPlusReleasePackage
        if ($package -match '\.dmg$') {
            Add-AdapterLog (T 'SourceDmg')
        } elseif ($package -match '\.zip$') {
            Add-AdapterLog "Extracting package: $package"
            $extract = Join-Path $downloadRoot 'package'
            if (Test-Path $extract) { [System.IO.Directory]::Delete($extract, $true) }
            Expand-Archive -LiteralPath $package -DestinationPath $extract -Force
            Copy-DirectoryTree -Source (Find-ExtractedSourceRoot $extract) -Destination $sourceRoot
            return $sourceRoot
        } elseif ($package -match '\.(tar\.gz|tgz|tar\.xz|txz)$') {
            if (-not (Test-CommandAvailable 'tar')) { throw "tar is required to extract $package" }
            $extract = Join-Path $downloadRoot 'package'
            if (Test-Path $extract) { [System.IO.Directory]::Delete($extract, $true) }
            [void][System.IO.Directory]::CreateDirectory($extract)
            Invoke-External -FilePath 'tar' -Arguments @('-xf', $package, '-C', $extract) | Out-Null
            Copy-DirectoryTree -Source (Find-ExtractedSourceRoot $extract) -Destination $sourceRoot
            return $sourceRoot
        }
    }

    Add-AdapterLog "Fetching source from $CodexPlusPlusGitHubRepo"
    $zip = Join-Path $downloadRoot 'CodexPlusPlus.zip'
    try {
        Invoke-WebRequest -Uri $CodexPlusPlusMainZipUrl -OutFile $zip
    } catch {
        Add-AdapterLog "main.zip failed, trying master.zip"
        Invoke-WebRequest -Uri $CodexPlusPlusMasterZipUrl -OutFile $zip
    }
    $extractDir = Join-Path $downloadRoot 'source-zip'
    if (Test-Path $extractDir) { [System.IO.Directory]::Delete($extractDir, $true) }
    Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force
    Copy-DirectoryTree -Source (Find-ExtractedSourceRoot $extractDir) -Destination $sourceRoot
    return $sourceRoot
}

function Ensure-Dependency {
    param(
        [string]$Name,
        [scriptblock]$Installer
    )
    if ($DependencyMode -ne 'temp' -and (Test-CommandAvailable $Name)) {
        Add-AdapterLog "Dependency found: $Name"
        return
    }
    if ($DependencyMode -eq 'system') {
        throw "Missing required system dependency: $Name"
    }
    Add-AdapterLog "Dependency missing: $Name; attempting temporary install"
    & $Installer
}

function Install-TemporaryRust {
    param([string]$ToolsRoot)
    $rustRoot = Join-Path $ToolsRoot 'rust'
    $cargoHome = Join-Path $rustRoot 'cargo'
    $rustupHome = Join-Path $rustRoot 'rustup'
    [void][System.IO.Directory]::CreateDirectory($rustRoot)
    $rustup = Join-Path $rustRoot 'rustup-init'
    Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init' -OutFile $rustup
    if (Test-CommandAvailable 'chmod') { Invoke-External -FilePath 'chmod' -Arguments @('+x', $rustup) | Out-Null }
    Invoke-External -FilePath $rustup -Arguments @('-y', '--no-modify-path', '--profile', 'minimal') -Environment @{
        RUSTUP_HOME = $rustupHome
        CARGO_HOME = $cargoHome
    } | Out-Null
    $env:PATH = (Join-Path $cargoHome 'bin') + [System.IO.Path]::PathSeparator + $env:PATH
}

function Install-TemporaryNode {
    param([string]$ToolsRoot)
    if (-not (Test-CommandAvailable 'tar')) {
        throw "Temporary Node.js install needs tar for the official .tar.xz archive."
    }
    $nodeRoot = Join-Path $ToolsRoot 'node'
    [void][System.IO.Directory]::CreateDirectory($nodeRoot)
    $archive = Join-Path $nodeRoot 'node.tar.xz'
    $version = 'v22.16.0'
    $name = "node-$version-linux-x64"
    Invoke-WebRequest -Uri "https://nodejs.org/dist/$version/$name.tar.xz" -OutFile $archive
    Invoke-External -FilePath 'tar' -Arguments @('-xf', $archive, '-C', $nodeRoot) | Out-Null
    $env:PATH = (Join-Path $nodeRoot "$name/bin") + [System.IO.Path]::PathSeparator + $env:PATH
}

function Ensure-Dependencies {
    param([string]$InstallRoot)
    $toolsRoot = Join-Path $InstallRoot $TemporaryToolsDirName
    [void][System.IO.Directory]::CreateDirectory($toolsRoot)
    Ensure-Dependency 'git' { throw "git is required for patch application." }
    Ensure-Dependency 'cargo' { Install-TemporaryRust $toolsRoot }
    Ensure-Dependency 'node' { Install-TemporaryNode $toolsRoot }
    Ensure-Dependency 'npm' { Install-TemporaryNode $toolsRoot }
}

# =============================================================================
# Build and install / 构建与安装
# =============================================================================

function Invoke-CodexPlusPlusBuild {
    param([string]$SourceRoot)
    if ($SkipBuild) {
        Add-AdapterLog "Skipping build by request"
        return
    }
    $managerDir = Join-Path $SourceRoot 'apps/codex-plus-manager'
    if (Test-Path (Join-Path $managerDir 'package-lock.json')) {
        Invoke-External -FilePath 'npm' -Arguments @('ci') -WorkingDirectory $managerDir | Out-Null
    } else {
        Invoke-External -FilePath 'npm' -Arguments @('install') -WorkingDirectory $managerDir | Out-Null
    }
    if (-not $SkipTests) {
        Invoke-External -FilePath 'node' -Arguments @('--check', 'assets/inject/renderer-inject.js') -WorkingDirectory $SourceRoot | Out-Null
        Invoke-External -FilePath 'npm' -Arguments @('run', 'check') -WorkingDirectory $managerDir | Out-Null
        Invoke-External -FilePath 'cargo' -Arguments @('test', '-p', 'codex-plus-core', '--test', 'cdp_bridge') -WorkingDirectory $SourceRoot | Out-Null
    }
    $buildArgs = @('build', '-p', 'codex-plus-launcher', '-p', 'codex-plus-manager')
    if ($BuildMode -eq 'release') { $buildArgs += '--release' }
    Invoke-External -FilePath 'cargo' -Arguments $buildArgs -WorkingDirectory $SourceRoot | Out-Null
}

function Install-AdaptedBinaries {
    param(
        [string]$SourceRoot,
        [string]$InstallRoot,
        [string]$CodexAppDir
    )
    $profile = if ($BuildMode -eq 'release') { 'release' } else { 'debug' }
    $targetDir = Join-Path $SourceRoot "target/$profile"
    $launcher = Join-Path $targetDir 'codex-plus-plus'
    $manager = Join-Path $targetDir 'codex-plus-plus-manager'
    if (-not (Test-Path $launcher)) { throw "Launcher binary not found: $launcher" }
    if (-not (Test-Path $manager)) { throw "Manager binary not found: $manager" }

    $binDir = Join-Path $InstallRoot 'install'
    [void][System.IO.Directory]::CreateDirectory($binDir)
    Copy-Item -LiteralPath $launcher -Destination (Join-Path $binDir 'codex-plus-plus') -Force
    Copy-Item -LiteralPath $manager -Destination (Join-Path $binDir 'codex-plus-plus-manager') -Force

    $wrapper = Join-Path $binDir 'launch-codex-plus-plus'
    $launcherQuoted = Quote-ShSingle ([System.IO.Path]::GetFullPath((Join-Path $binDir 'codex-plus-plus')))
    $appQuoted = Quote-ShSingle ([System.IO.Path]::GetFullPath($CodexAppDir))
    $wrapperText = @"
#!/bin/sh
# Managed by the Codex++ Linux adapter.
exec $launcherQuoted --app-path $appQuoted "`$@"
"@
    [System.IO.File]::WriteAllText($wrapper, $wrapperText)
    if (Test-CommandAvailable 'chmod') {
        Invoke-External -FilePath 'chmod' -Arguments @('+x', (Join-Path $binDir 'codex-plus-plus'), (Join-Path $binDir 'codex-plus-plus-manager'), $wrapper) | Out-Null
    }

    $readme = Join-Path $binDir 'README-linux-adapter.txt'
    [System.IO.File]::WriteAllText($readme, "Managed by Codex++ Linux Adapter.`nLaunch with: $wrapper`n")

    if ($CreateDesktopEntries) {
        $apps = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.local/share/applications'
        [void][System.IO.Directory]::CreateDirectory($apps)
        [System.IO.File]::WriteAllText((Join-Path $apps 'codex-plus-plus-linux.desktop'), @"
[Desktop Entry]
Type=Application
Name=Codex++ Linux
Exec=$wrapper
Terminal=false
Categories=Development;
"@)
        [System.IO.File]::WriteAllText((Join-Path $apps 'codex-plus-plus-manager-linux.desktop'), @"
[Desktop Entry]
Type=Application
Name=Codex++ Manager Linux
Exec=$(Join-Path $binDir 'codex-plus-plus-manager')
Terminal=false
Categories=Development;
"@)
    }
}

function Uninstall-AdaptedCodexPlusPlus {
    param([string]$InstallRoot)
    $binDir = Join-Path $InstallRoot 'install'
    if (-not (Test-Path $InstallRoot)) {
        Add-AdapterLog "Install root does not exist: $InstallRoot"
        return
    }
    if ($PreserveUserScriptsOnUninstall) {
        foreach ($name in @('codex-plus-plus', 'codex-plus-plus-manager', 'launch-codex-plus-plus', 'README-linux-adapter.txt')) {
            $path = Join-Path $binDir $name
            if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
        }
        Add-AdapterLog "Removed binaries and preserved user data: $InstallRoot"
    } else {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        Add-AdapterLog "Removed install root: $InstallRoot"
    }
    $apps = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.local/share/applications'
    foreach ($name in @('codex-plus-plus-linux.desktop', 'codex-plus-plus-manager-linux.desktop')) {
        $path = Join-Path $apps $name
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Show-InfoPanel {
    param(
        [object]$CodexInfo,
        [string]$SourceRoot,
        [object[]]$Snippets
    )
    $sourceLabel = if ($CodexPlusPlusLocalSource) {
        "local: $(Expand-AdapterPath $CodexPlusPlusLocalSource)"
    } elseif ($CodexPlusPlusReleasePackage) {
        "package: $(Expand-AdapterPath $CodexPlusPlusReleasePackage)"
    } else {
        "github: $CodexPlusPlusGitHubRepo"
    }
    $version = Get-CodexPlusPlusVersion $SourceRoot
    Write-Host ''
    Write-Host '================================================================'
    Write-Host "Codex++ source: $sourceLabel"
    Write-Host "Codex++ version: $version"
    Write-Host "Codex Desktop: $($CodexInfo.AppDir)"
    Write-Host "Codex Desktop installed: $($CodexInfo.Installed)"
    Write-Host "Codex Desktop version: $($CodexInfo.Version)"
    Write-Host "Enabled snippets: $($Snippets.id -join ', ')"
    Write-Host '================================================================'
    Write-Host ''
}

function Invoke-InstallOrUpdate {
    param([bool]$IsUpdate)
    $codexRoot = Expand-AdapterPath $CodexDesktopRoot
    $installRoot = Resolve-AdapterInstallPath $codexRoot $CodexPlusPlusInstallPath
    $workRoot = Join-Path $installRoot $WorkDirName
    [void][System.IO.Directory]::CreateDirectory($workRoot)

    Invoke-AdapterStep 8 'Check Codex Desktop / 检查 Codex Desktop' {
        $script:CodexInfo = Test-CodexDesktopInstall $codexRoot
        if (-not $script:CodexInfo.Installed) { throw (T 'CodexMissing') }
    }
    Invoke-AdapterStep 16 'Prepare source / 准备源码' {
        $script:SourceRoot = Prepare-Source $workRoot
    }
    $manifest = Read-SnippetManifest
    $snippets = Get-EnabledSnippets $manifest
    Show-InfoPanel -CodexInfo $script:CodexInfo -SourceRoot $script:SourceRoot -Snippets $snippets
    if ($CheckUpdatesByDefault -or (Confirm-AdapterAction (T 'CheckUpdates') $false)) {
        Add-AdapterLog "Update check requested; source fetch mode already uses the configured upstream/latest source."
    }
    if (-not (Confirm-AdapterAction (T 'ConfirmInstall') $true)) { return }

    Invoke-AdapterStep 28 'Ensure dependencies / 检查依赖' {
        Ensure-Dependencies $installRoot
    }
    Invoke-AdapterStep 42 'Apply snippets / 注入片段' {
        $i = 0
        foreach ($snippet in $snippets) {
            $i += 1
            $percent = [Math]::Floor($i * 100 / [Math]::Max(1, $snippets.Count))
            Set-AdapterProgress -Total 42 -Step $percent -StepName (T 'SnippetApply') -Detail $snippet.id
            Apply-SnippetPatch -SourceRoot $script:SourceRoot -Snippet $snippet
        }
    }
    Invoke-AdapterStep 72 'Build Codex++ / 构建 Codex++' {
        Invoke-CodexPlusPlusBuild $script:SourceRoot
    }
    Invoke-AdapterStep 90 'Install binaries / 安装二进制文件' {
        Install-AdaptedBinaries -SourceRoot $script:SourceRoot -InstallRoot $installRoot -CodexAppDir $script:CodexInfo.AppDir
    }
    Invoke-AdapterStep 100 'Finalize / 收尾' {
        if (-not $KeepWorkDir -and (Confirm-AdapterAction (T 'PurgeWork') $true)) {
            if (Test-Path $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
            Add-AdapterLog "Purged work directory: $workRoot"
        }
    }
}

function Invoke-ListSnippets {
    $manifest = Read-SnippetManifest
    $snippets = Get-EnabledSnippets $manifest
    $manifest | Select-Object id, required, defaultEnabled, kind, patch, purpose | Format-Table -AutoSize
    Write-Host ''
    Write-Host "Enabled: $($snippets.id -join ', ')"
}

function Invoke-SelfTest {
    $manifest = Read-SnippetManifest
    if (-not $manifest -or $manifest.Count -lt 1) { throw "Manifest is empty" }
    foreach ($snippet in $manifest) {
        $patchPath = Join-Path (Get-RepositoryRoot) ([string]$snippet.patch)
        if (-not (Test-Path $patchPath)) { throw "Missing patch: $patchPath" }
    }
    Write-Host "Selftest OK: manifest and patch attachments are readable."
}

try {
    switch ($Action) {
        'install' { Invoke-InstallOrUpdate -IsUpdate:$false }
        'update' { Invoke-InstallOrUpdate -IsUpdate:$true }
        'uninstall' {
            $codexRoot = Expand-AdapterPath $CodexDesktopRoot
            $installRoot = Resolve-AdapterInstallPath $codexRoot $CodexPlusPlusInstallPath
            if (Confirm-AdapterAction (T 'ConfirmUninstall') $true) {
                Invoke-AdapterStep 100 'Uninstall / 卸载' { Uninstall-AdaptedCodexPlusPlus $installRoot }
            }
        }
        'list-snippets' { Invoke-ListSnippets }
        'apply-snippets' {
            $codexRoot = Expand-AdapterPath $CodexDesktopRoot
            $installRoot = Resolve-AdapterInstallPath $codexRoot $CodexPlusPlusInstallPath
            $workRoot = Join-Path $installRoot $WorkDirName
            $sourceRoot = Join-Path $workRoot 'source'
            if (-not (Test-Path $sourceRoot)) { throw "No prepared source found: $sourceRoot" }
            $snippets = Get-EnabledSnippets (Read-SnippetManifest)
            foreach ($snippet in $snippets) { Apply-SnippetPatch -SourceRoot $sourceRoot -Snippet $snippet }
        }
        'selftest' { Invoke-SelfTest }
    }
    Add-AdapterLog (T 'Done')
    Render-AdapterTui
} catch {
    Add-AdapterLog "$(T 'Failed'): $($_.Exception.Message)"
    Render-AdapterTui
    throw
}
