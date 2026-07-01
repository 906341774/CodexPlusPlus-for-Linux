#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet("install", "update", "uninstall", "list-snippets", "apply-snippets", "selftest")]
    [string]$Action = "install",

    [string]$CodexDesktopRootPath,
    [string]$CodexPlusPlusLocalSourcePath,
    [string]$CodexPlusPlusReleasePackagePath,
    [string]$CodexPlusPlusInstallPathValue,

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
#   relative path: resolved from the detected Codex app directory, e.g. .codex-plusplus
#   absolute path: used as-is
[string]$CodexPlusPlusInstallPath = '.codex-plusplus'

# Upstream source URL used when no local source or package is configured.
# 未指定本地源码或包时使用的上游源码地址。
[string]$CodexPlusPlusGitHubRepo = 'https://github.com/BigPizzaV3/CodexPlusPlus'
# Upstream version pinned by this adapter release.
# 当前适配项目固定对应的上游 Codex++ 版本。
[string]$CodexPlusPlusUpstreamVersion = '1.2.25'
[string]$CodexPlusPlusReleaseTag = "v$CodexPlusPlusUpstreamVersion"
[string]$CodexPlusPlusVersionZipUrl = "https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/tags/$CodexPlusPlusReleaseTag.zip"
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
if ($env:CODEXPP_LINUX_UPSTREAM_VERSION) {
    $CodexPlusPlusUpstreamVersion = $env:CODEXPP_LINUX_UPSTREAM_VERSION
    $CodexPlusPlusReleaseTag = "v$CodexPlusPlusUpstreamVersion"
    $CodexPlusPlusVersionZipUrl = "https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/tags/$CodexPlusPlusReleaseTag.zip"
}
if ($env:CODEXPP_LINUX_INCLUDE_TEST_SNIPPETS) { $IncludeRegressionTestSnippets = [System.Convert]::ToBoolean($env:CODEXPP_LINUX_INCLUDE_TEST_SNIPPETS) }
if ($env:CODEXPP_LINUX_CREATE_DESKTOP_ENTRIES) { $CreateDesktopEntries = [System.Convert]::ToBoolean($env:CODEXPP_LINUX_CREATE_DESKTOP_ENTRIES) }
if ($env:CODEXPP_LINUX_PRESERVE_USER_SCRIPTS) { $PreserveUserScriptsOnUninstall = [System.Convert]::ToBoolean($env:CODEXPP_LINUX_PRESERVE_USER_SCRIPTS) }

# EN: Explicit command-line path parameters override the script defaults and environment variables.
# ZH: 明确传入的命令行路径参数优先级最高，会覆盖脚本配置区默认值和环境变量。
if ($PSBoundParameters.ContainsKey('CodexDesktopRootPath')) { $CodexDesktopRoot = $CodexDesktopRootPath }
if ($PSBoundParameters.ContainsKey('CodexPlusPlusLocalSourcePath')) { $CodexPlusPlusLocalSource = $CodexPlusPlusLocalSourcePath }
if ($PSBoundParameters.ContainsKey('CodexPlusPlusReleasePackagePath')) { $CodexPlusPlusReleasePackage = $CodexPlusPlusReleasePackagePath }
if ($PSBoundParameters.ContainsKey('CodexPlusPlusInstallPathValue')) { $CodexPlusPlusInstallPath = $CodexPlusPlusInstallPathValue }

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
        Title = 'CodexPlusPlus on Linux 安装与管理器'
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
        PromptCodexDesktopRoot = '配置中的 Linux Codex Desktop 安装目录是：{0}。如需指定新路径请输入；直接回车保留该值'
        PromptCodexPlusPlusLocalSource = '配置中的 Codex++ 本地源码仓库路径是：{0}。如需指定新路径请输入；直接回车保留该值'
        PromptCodexPlusPlusReleasePackage = '配置中的 Codex++ release/DMG 包路径是：{0}。如需指定新路径请输入；直接回车保留该值'
        PromptCodexPlusPlusInstallPath = '配置中的 Codex++ 适配安装路径是：{0}。如需指定新路径请输入；直接回车保留该值'
        EmptyPath = '<未指定>'
        CodexMissing = '未检测到 Linux Codex Desktop。请先按照 ilysenko/codex-desktop-linux 的 README 安装。'
        SourceDmg = '检测到 DMG 包；Linux 上无法直接对 DMG 二进制包做源码注入，将改为获取源码。'
        SnippetAlready = '片段已存在，跳过'
        SnippetApply = '正在注入片段'
    }
    en = @{
        Title = 'CodexPlusPlus on Linux Installer and Manager'
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
        PromptCodexDesktopRoot = 'Configured Codex Desktop root: {0}. Enter a new path, or press Enter to keep this value'
        PromptCodexPlusPlusLocalSource = 'Configured Codex++ local source: {0}. Enter a new path, or press Enter to keep this value'
        PromptCodexPlusPlusReleasePackage = 'Configured Codex++ release package: {0}. Enter a new path, or press Enter to keep this value'
        PromptCodexPlusPlusInstallPath = 'Configured Codex++ install path: {0}. Enter a new path, or press Enter to keep this value'
        EmptyPath = '<not set>'
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
    # EN: PowerShell returns a scalar for a single pipeline item; force an array before using Count.
    # ZH: PowerShell 管道只有一个结果时会返回标量；使用 Count 前必须强制转成数组。
    $logs = @($script:LogLines | Select-Object -Last 8)
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

function Read-ConfiguredPathOverride {
    param(
        [string]$PromptKey,
        [string]$CurrentValue
    )

    # EN: Noninteractive runs must consume configured or parameter-supplied paths without waiting for stdin.
    # ZH: 非交互运行必须直接使用配置区或命令行传入的路径，不能等待标准输入。
    if ($NonInteractive) { return $CurrentValue }

    # EN: Empty optional paths are shown explicitly so users know they are keeping an unset value.
    # ZH: 可选路径为空时明确显示未指定，避免用户误以为脚本隐藏了某个默认路径。
    $displayValue = if ([string]::IsNullOrWhiteSpace($CurrentValue)) { T 'EmptyPath' } else { $CurrentValue }
    $answer = Read-Host ([string]::Format((T $PromptKey), $displayValue))

    # EN: Pressing Enter keeps the current configured value exactly as-is, including shell-style path forms.
    # ZH: 用户直接回车时原样保留当前配置值，包括 $HOME、${HOME}、$env:HOME 和 ~/ 等写法。
    if ([string]::IsNullOrWhiteSpace($answer)) { return $CurrentValue }
    return $answer.Trim()
}

function Read-OperationPathConfiguration {
    # EN: Install, update, and uninstall all resolve paths from the same prompt sequence before doing work.
    # ZH: 安装、更新、卸载在执行任何实际操作前，都按相同顺序确认路径配置。
    $script:CodexDesktopRoot = Read-ConfiguredPathOverride 'PromptCodexDesktopRoot' $script:CodexDesktopRoot
    $script:CodexPlusPlusLocalSource = Read-ConfiguredPathOverride 'PromptCodexPlusPlusLocalSource' $script:CodexPlusPlusLocalSource
    $script:CodexPlusPlusReleasePackage = Read-ConfiguredPathOverride 'PromptCodexPlusPlusReleasePackage' $script:CodexPlusPlusReleasePackage
    $script:CodexPlusPlusInstallPath = Read-ConfiguredPathOverride 'PromptCodexPlusPlusInstallPath' $script:CodexPlusPlusInstallPath
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
    param([string]$CodexAppDir, [string]$InstallPath)
    $raw = $InstallPath.Trim()
    $usesShellRoot = $raw -eq '~' -or $raw.StartsWith('~/') -or $raw.StartsWith('$HOME') -or $raw.StartsWith('${HOME}') -or $raw.StartsWith('$env:HOME')
    if ([System.IO.Path]::IsPathRooted($raw) -or $usesShellRoot) {
        return Expand-AdapterPath $raw
    }
    return [System.IO.Path]::GetFullPath((Join-Path $CodexAppDir $raw))
}

function Resolve-AdapterInstallPathForExistingOperation {
    param(
        [object]$CodexInfo,
        [string]$InstallPath
    )
    $raw = $InstallPath.Trim()
    $usesShellRoot = $raw -eq '~' -or $raw.StartsWith('~/') -or $raw.StartsWith('$HOME') -or $raw.StartsWith('${HOME}') -or $raw.StartsWith('$env:HOME')
    if ([System.IO.Path]::IsPathRooted($raw) -or $usesShellRoot) {
        return Resolve-AdapterInstallPath $CodexInfo.AppDir $raw
    }

    # EN: Uninstall/apply operations may run after Codex Desktop was moved or partially removed.
    # EN: Check both documented layout anchors before falling back to the currently detected app directory.
    # ZH: 卸载/apply 操作可能发生在 Codex Desktop 已被移动或部分删除之后。
    # ZH: 回退到当前识别的 app 目录前，先检查两种文档化布局对应的安装锚点。
    $candidateDirs = @(
        [string]$CodexInfo.AppDir,
        [string]$CodexInfo.Root,
        (Join-Path ([string]$CodexInfo.Root) 'codex-app')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($dir in $candidateDirs) {
        $candidate = Resolve-AdapterInstallPath $dir $raw
        if (Test-Path $candidate) { return $candidate }
    }
    return Resolve-AdapterInstallPath $CodexInfo.AppDir $raw
}

function Clear-CodexPlusPlusLatestStatusForKnownLayouts {
    param([object]$CodexInfo)
    # EN: Existing installs may have used either the direct app root or nested codex-app layout.
    # ZH: 既有安装可能使用直接 app 根目录，也可能使用嵌套 codex-app 布局。
    $candidateDirs = @(
        [string]$CodexInfo.AppDir,
        [string]$CodexInfo.Root,
        (Join-Path ([string]$CodexInfo.Root) 'codex-app')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($dir in $candidateDirs) {
        Clear-CodexPlusPlusLatestStatus -CodexAppDir $dir
    }
}

function Get-AdapterUserHome {
    # EN: Prefer HOME so tests and container runs can isolate Codex++ user state.
    # ZH: 优先使用 HOME，便于测试和容器运行隔离 Codex++ 用户状态。
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        return [System.IO.Path]::GetFullPath($env:HOME)
    }
    return [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}

function Get-AdapterXdgDataHome {
    # EN: Codex++ stores Linux user state under XDG data home when available.
    # ZH: Linux 下 Codex++ 用户状态优先放在 XDG data home。
    if (-not [string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
        return [System.IO.Path]::GetFullPath($env:XDG_DATA_HOME)
    }
    return Join-Path (Get-AdapterUserHome) '.local/share'
}

function Get-AdapterApplicationsDir {
    # EN: Desktop entries are user data; honor XDG_DATA_HOME/HOME for containers and user-level installs.
    # ZH: desktop entry 属于用户数据；遵循 XDG_DATA_HOME/HOME，便于容器测试和用户级安装隔离。
    return Join-Path (Get-AdapterXdgDataHome) 'applications'
}

function New-AdapterJsonObject {
    return [pscustomobject]@{}
}

function Backup-AdapterStateFile {
    param([string]$PathValue)
    if (-not (Test-Path $PathValue)) { return }
    $backup = "$PathValue.codexpp-backup-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).bak"
    Copy-Item -LiteralPath $PathValue -Destination $backup -Force
    Add-AdapterLog "Backed up unreadable state file: $backup"
}

function Read-AdapterJsonObject {
    param([string]$PathValue)
    if (-not (Test-Path $PathValue)) { return (New-AdapterJsonObject) }
    try {
        $json = [System.IO.File]::ReadAllText($PathValue)
        if ([string]::IsNullOrWhiteSpace($json)) { return (New-AdapterJsonObject) }
        $value = $json | ConvertFrom-Json
        if ($null -eq $value -or $value -is [array]) {
            Backup-AdapterStateFile $PathValue
            return (New-AdapterJsonObject)
        }
        return $value
    } catch {
        # EN: Keep a backup instead of dumping or discarding user settings that may contain API keys.
        # ZH: 状态文件可能包含 API Key；解析失败时只做备份，不打印内容也不直接丢弃。
        Backup-AdapterStateFile $PathValue
        return (New-AdapterJsonObject)
    }
}

function Set-AdapterJsonProperty {
    param(
        [object]$ObjectValue,
        [string]$Name,
        [object]$Value
    )
    $ObjectValue | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Write-AdapterJsonObject {
    param(
        [string]$PathValue,
        [object]$ObjectValue
    )
    [void][System.IO.Directory]::CreateDirectory(([System.IO.Path]::GetDirectoryName($PathValue)))
    $json = $ObjectValue | ConvertTo-Json -Depth 64
    [System.IO.File]::WriteAllText($PathValue, "$json`n")
}

function Get-CodexPlusPlusSessionPath {
    param([string]$FileName)
    # EN: Codex++ upstream stores manager runtime state in the session-delete directory under HOME.
    # ZH: Codex++ 上游把管理器运行状态放在 HOME 下的 session-delete 目录中。
    return Join-Path (Join-Path (Get-AdapterUserHome) '.codex-session-delete') $FileName
}

function Sync-CodexSessionDeleteSettings {
    param([string]$CodexAppDir)
    $path = Get-CodexPlusPlusSessionPath 'settings.json'
    $settings = Read-AdapterJsonObject $path
    Set-AdapterJsonProperty $settings 'codexAppPath' ([System.IO.Path]::GetFullPath($CodexAppDir))
    Write-AdapterJsonObject $path $settings
    Add-AdapterLog "Synced Codex++ manager settings path: $path"
}

function Sync-CodexPlusPlusState {
    param(
        [string]$CodexAppDir,
        [string]$InstallRoot,
        [string]$SourceRoot,
        [string]$CodexPlusPlusVersion,
        [string]$CodexDesktopVersion
    )
    $path = Join-Path (Get-AdapterXdgDataHome) 'codex-plusplus/state.json'
    $state = Read-AdapterJsonObject $path
    Set-AdapterJsonProperty $state 'version' $CodexPlusPlusVersion
    if (-not ($state.PSObject.Properties.Name -contains 'installedAt') -or [string]::IsNullOrWhiteSpace([string]$state.installedAt)) {
        Set-AdapterJsonProperty $state 'installedAt' ([DateTimeOffset]::UtcNow.ToString('o'))
    }
    Set-AdapterJsonProperty $state 'appRoot' ([System.IO.Path]::GetFullPath($CodexAppDir))
    Set-AdapterJsonProperty $state 'codexVersion' $CodexDesktopVersion
    Set-AdapterJsonProperty $state 'sourceRoot' ([System.IO.Path]::GetFullPath($SourceRoot))
    Set-AdapterJsonProperty $state 'linuxAdapterInstallRoot' ([System.IO.Path]::GetFullPath($InstallRoot))
    $binDir = Join-Path $InstallRoot 'install'
    $apps = Get-AdapterApplicationsDir
    # EN: These explicit Linux paths help manager health checks and future diagnostics avoid stale upstream defaults.
    # ZH: 明确写入这些 Linux 路径，避免管理器健康检查和后续诊断退回到上游默认旧路径。
    Set-AdapterJsonProperty $state 'linuxCodexStartScript' ([System.IO.Path]::GetFullPath((Join-Path $CodexAppDir 'start.sh')))
    Set-AdapterJsonProperty $state 'linuxAdapterLauncherPath' ([System.IO.Path]::GetFullPath((Join-Path $binDir 'launch-codex-plus-plus')))
    Set-AdapterJsonProperty $state 'linuxAdapterManagerPath' ([System.IO.Path]::GetFullPath((Join-Path $binDir 'codex-plus-plus-manager')))
    Set-AdapterJsonProperty $state 'linuxAdapterDesktopEntryPath' ([System.IO.Path]::GetFullPath((Join-Path $apps 'codex-plus-plus.desktop')))
    Set-AdapterJsonProperty $state 'linuxAdapterManagerDesktopEntryPath' ([System.IO.Path]::GetFullPath((Join-Path $apps 'codex-plus-plus-manager.desktop')))
    Write-AdapterJsonObject $path $state
    Add-AdapterLog "Synced Codex++ state path: $path"
}

function Clear-CodexPlusPlusLatestStatus {
    param([string]$CodexAppDir)
    $path = Get-CodexPlusPlusSessionPath 'latest-status.json'
    if (-not (Test-Path $path)) { return }

    $shouldClear = $true
    try {
        $status = Read-AdapterJsonObject $path
        $statusApp = [string]$status.codex_app
        # EN: If the status belongs to a different app path, leave it alone.
        # ZH: 如果最近启动状态属于不同的 Codex app 路径，则不主动清理。
        if (-not [string]::IsNullOrWhiteSpace($statusApp)) {
            $shouldClear = ([System.IO.Path]::GetFullPath($statusApp) -eq [System.IO.Path]::GetFullPath($CodexAppDir))
        }
    } catch {
        # EN: Bad status JSON is non-authoritative runtime state, so clearing it is safer than surfacing stale failure UI.
        # ZH: 损坏的 status JSON 只是运行状态；清理它比继续在界面展示陈旧失败更稳妥。
        $shouldClear = $true
    }

    if ($shouldClear) {
        Remove-Item -LiteralPath $path -Force
        Add-AdapterLog "Cleared stale Codex++ launch status: $path"
    }
}

function Sync-CodexPlusPlusUserState {
    param(
        [string]$CodexAppDir,
        [string]$InstallRoot,
        [string]$SourceRoot,
        [string]$CodexPlusPlusVersion,
        [string]$CodexDesktopVersion
    )
    # EN: Keep user-level Codex++ state aligned with the Codex Desktop chosen during install/update.
    # ZH: 安装/更新时同步用户级 Codex++ 状态，使其指向用户本次选择的 Codex Desktop。
    Sync-CodexSessionDeleteSettings -CodexAppDir $CodexAppDir
    Sync-CodexPlusPlusState `
        -CodexAppDir $CodexAppDir `
        -InstallRoot $InstallRoot `
        -SourceRoot $SourceRoot `
        -CodexPlusPlusVersion $CodexPlusPlusVersion `
        -CodexDesktopVersion $CodexDesktopVersion
    Clear-CodexPlusPlusLatestStatus -CodexAppDir $CodexAppDir
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
    # EN: A release archive often contains exactly one top-level source directory; keep it as an array under StrictMode.
    # ZH: release 压缩包通常只有一个顶层源码目录；StrictMode 下要保持数组形态，避免单元素标量没有 Count。
    $candidates = @(Get-ChildItem -LiteralPath $Directory -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'Cargo.toml')
    })
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
    # EN: The install work tree may live under another Git repository, such as CodexDesktop itself.
    # ZH: 安装工作目录可能位于另一个 Git 仓库内部，例如 CodexDesktop 自身仓库。
    $gitApplyEnvironment = @{
        GIT_CEILING_DIRECTORIES = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($SourceRoot))
    }
    Set-AdapterProgress -Total $script:TotalPercent -Step 20 -StepName (T 'SnippetApply') -Detail $Snippet.id
    $checkOk = $true
    try {
        Invoke-External -FilePath 'git' -Arguments @('apply', '--check', $patchPath) -WorkingDirectory $SourceRoot -Environment $gitApplyEnvironment | Out-Null
    } catch {
        Add-AdapterLog "Patch check failed for $($Snippet.id): $($_.Exception.Message)"
        $checkOk = $false
    }
    if ($checkOk) {
        Invoke-External -FilePath 'git' -Arguments @('apply', $patchPath) -WorkingDirectory $SourceRoot -Environment $gitApplyEnvironment | Out-Null
        Add-AdapterLog "Applied snippet: $($Snippet.id)"
        return
    }

    $reverseOk = $true
    try {
        Invoke-External -FilePath 'git' -Arguments @('apply', '--reverse', '--check', $patchPath) -WorkingDirectory $SourceRoot -Environment $gitApplyEnvironment | Out-Null
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

function Assert-TextFileContains {
    param(
        [string]$PathValue,
        [string]$Literal,
        [string]$Label
    )
    if (-not (Test-Path $PathValue)) {
        throw "Missing file while verifying Linux adaptation: $PathValue"
    }
    $text = [System.IO.File]::ReadAllText($PathValue)
    if (-not $text.Contains($Literal)) {
        throw "Linux adaptation verification failed: $Label was not found in $PathValue"
    }
}

function Test-BinaryContainsAsciiLiteral {
    param(
        [string]$PathValue,
        [string]$Literal
    )
    if (-not (Test-Path $PathValue)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($PathValue)
    $needle = [System.Text.Encoding]::ASCII.GetBytes($Literal)
    if ($needle.Length -eq 0) { return $true }
    if ($bytes.Length -lt $needle.Length) { return $false }

    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i += 1) {
        $matched = $true
        for ($j = 0; $j -lt $needle.Length; $j += 1) {
            if ($bytes[$i + $j] -ne $needle[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) { return $true }
    }
    return $false
}

function Assert-BinaryContainsAsciiLiteral {
    param(
        [string]$PathValue,
        [string]$Literal,
        [string]$Label
    )
    if (-not (Test-BinaryContainsAsciiLiteral -PathValue $PathValue -Literal $Literal)) {
        throw "Installed binary verification failed: $Label was not found in $PathValue"
    }
}

function Assert-SourceLinuxAdaptationApplied {
    param([string]$SourceRoot)
    # EN: Fail before building if required Linux snippets did not actually modify the upstream source.
    # ZH: 如果必需的 Linux 片段没有真实修改上游源码，则在构建前直接失败。
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/app_paths.rs') 'app_dir.join("start.sh")' 'Linux Codex start.sh resolver'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/app_paths.rs') 'app_dir.join("version")' 'Linux Codex version file resolver'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/launcher.rs') 'codex_process_environment_for_app(app_dir)' 'Linux launcher environment handoff'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/launcher.rs') '"--new-instance"' 'Linux start.sh new-instance argument'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/launcher.rs') 'CODEX_WEBVIEW_PORT' 'Linux Codex++ webview port environment'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/launcher.rs') 'Access-Control-Allow-Private-Network' 'Linux helper private-network CORS marker'
    Assert-TextFileContains (Join-Path $SourceRoot 'apps/codex-plus-manager/src-tauri/src/commands.rs') 'inspect_entrypoints_for_app(codex_app_path.as_deref())' 'Linux manager overview entrypoint resolver'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/install/mod.rs') 'linuxAdapterInstallRoot' 'Linux adapter state install root'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/install/mod.rs') 'codex-plus-plus.desktop' 'Linux upstream-style desktop entry name'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/relay_config.rs') 'effective_codex_base_url' 'Pure API effective BaseURL normalization'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/relay_config.rs') 'requires_openai_auth: bool' 'Pure API configurable OpenAI auth requirement'
    Assert-TextFileContains (Join-Path $SourceRoot 'assets/inject/renderer-inject.js') 'normalizeCodexPlusPluginDetail' 'Linux plugin detail response normalization'
    Assert-TextFileContains (Join-Path $SourceRoot 'assets/inject/renderer-inject.js') 'codexPlusSyntheticAccountReadResult' 'Pure API synthetic account read compatibility'
    Assert-TextFileContains (Join-Path $SourceRoot 'assets/inject/renderer-inject.js') 'clearPluginEntryUnlockLabel' 'Native Plugins label cleanup'
    Assert-TextFileContains (Join-Path $SourceRoot 'assets/inject/renderer-inject.js') 'avoidFloatingCodexPlusMenuNativeControlOverlap' 'Floating Codex++ menu overlap avoidance'
    Assert-TextFileContains (Join-Path $SourceRoot 'assets/inject/renderer-inject.js') 'codexServiceTierLinuxComposerFooters' 'Linux Fast badge composer placement'
    Assert-TextFileContains (Join-Path $SourceRoot 'assets/inject/renderer-inject.js') 'codexServiceTierBackendBlocksLocalOverride' 'Linux Fast badge transient backend checking clickability'
    Assert-TextFileContains (Join-Path $SourceRoot 'crates/codex-plus-core/src/user_scripts.rs') 'codexPlusLinuxUserScriptLocation' 'Linux user script location alias'
    Add-AdapterLog "Verified Linux adaptation markers in patched source."
}

function Assert-InstalledLinuxAdaptationApplied {
    param([string]$InstallRoot)
    $binDir = Join-Path $InstallRoot 'install'
    $launcher = Join-Path $binDir 'codex-plus-plus'
    $manager = Join-Path $binDir 'codex-plus-plus-manager'
    # EN: Release binaries must carry these string markers; otherwise a stale unpatched build was installed.
    # ZH: release 二进制必须包含这些字符串标记；否则说明安装进去了陈旧的未补丁构建。
    Assert-BinaryContainsAsciiLiteral $launcher 'start.sh' 'Linux start.sh launcher marker'
    Assert-BinaryContainsAsciiLiteral $launcher 'CODEX_WEBVIEW_PORT' 'Linux webview environment marker'
    Assert-BinaryContainsAsciiLiteral $launcher 'Access-Control-Allow-Private-Network' 'Linux helper private-network CORS marker'
    Assert-BinaryContainsAsciiLiteral $launcher 'codexServiceTierLinuxComposerFooters' 'Linux Fast badge composer marker'
    Assert-BinaryContainsAsciiLiteral $launcher 'codexServiceTierBackendBlocksLocalOverride' 'Linux Fast badge transient backend checking marker'
    Assert-BinaryContainsAsciiLiteral $launcher 'codexPlusLinuxUserScriptLocation' 'Linux user script location alias marker'
    Assert-BinaryContainsAsciiLiteral $manager 'linuxAdapterInstallRoot' 'Linux state entrypoint marker'
    Assert-BinaryContainsAsciiLiteral $manager 'codex-plus-plus.desktop' 'Linux desktop entry marker'
    Add-AdapterLog "Verified Linux adaptation markers in installed binaries."
}

# =============================================================================
# Source and dependencies / 源码与依赖
# =============================================================================

function Test-CodexDesktopInstall {
    param([string]$CodexRoot)
    $nestedAppDir = Join-Path $CodexRoot 'codex-app'
    $directStart = Join-Path $CodexRoot 'start.sh'
    # EN: ilysenko/codex-desktop-linux can be kept as a repository root containing codex-app,
    # EN: or its built codex-app directory can be installed directly as the user-facing root.
    # ZH: ilysenko/codex-desktop-linux 可保留为包含 codex-app 的源码根目录，
    # ZH: 也可把构建出的 codex-app 目录内容直接作为用户安装根目录。
    $appDir = if (Test-Path $directStart) { $CodexRoot } else { $nestedAppDir }
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

    Add-AdapterLog "Fetching source from $CodexPlusPlusGitHubRepo tag $CodexPlusPlusReleaseTag"
    $zip = Join-Path $downloadRoot 'CodexPlusPlus.zip'
    try {
        Invoke-WebRequest -Uri $CodexPlusPlusVersionZipUrl -OutFile $zip
    } catch {
        # EN: Falling back keeps the script usable, but the pinned tag is the supported patch baseline.
        # ZH: 回退分支保证脚本可用，但固定 tag 才是当前补丁支持的基线。
        Add-AdapterLog "$CodexPlusPlusReleaseTag.zip failed, trying main.zip"
        try {
            Invoke-WebRequest -Uri $CodexPlusPlusMainZipUrl -OutFile $zip
        } catch {
            Add-AdapterLog "main.zip failed, trying master.zip"
            Invoke-WebRequest -Uri $CodexPlusPlusMasterZipUrl -OutFile $zip
        }
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

function Get-ManagerFrontendBuildInfo {
    param([string]$ManagerDir)

    $tauriConfig = Join-Path $ManagerDir 'src-tauri/tauri.conf.json'
    $srcTauriDir = Join-Path $ManagerDir 'src-tauri'
    $frontendDist = Join-Path $ManagerDir 'dist'
    $beforeBuildCommand = 'npm run vite:build'

    if (Test-Path $tauriConfig) {
        $config = [System.IO.File]::ReadAllText($tauriConfig) | ConvertFrom-Json
        if ($config.build.frontendDist) {
            $rawDist = [string]$config.build.frontendDist
            $frontendDist = if ([System.IO.Path]::IsPathRooted($rawDist)) {
                $rawDist
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $srcTauriDir $rawDist))
            }
        }
        if ($config.build.beforeBuildCommand) {
            $beforeBuildCommand = [string]$config.build.beforeBuildCommand
        }
    }

    return [pscustomobject]@{
        FrontendDist = [System.IO.Path]::GetFullPath($frontendDist)
        BeforeBuildCommand = $beforeBuildCommand
    }
}

function Invoke-ManagerFrontendBuild {
    param([string]$ManagerDir)

    $buildInfo = Get-ManagerFrontendBuildInfo $ManagerDir

    # EN: `cargo build` invokes Tauri context generation, which requires frontendDist to exist.
    # ZH: `cargo build` 会触发 Tauri context 生成，必须先确保 frontendDist 前端产物已经存在。
    if ([string]::IsNullOrWhiteSpace($buildInfo.BeforeBuildCommand)) {
        if (Test-Path $buildInfo.FrontendDist) { return }
        throw "Manager frontendDist is missing and no beforeBuildCommand is configured: $($buildInfo.FrontendDist)"
    }

    Add-AdapterLog "Building manager frontend: $($buildInfo.BeforeBuildCommand)"
    if (Test-CommandAvailable 'sh') {
        Invoke-External -FilePath 'sh' -Arguments @('-lc', $buildInfo.BeforeBuildCommand) -WorkingDirectory $ManagerDir | Out-Null
    } elseif ($buildInfo.BeforeBuildCommand -match '^npm\s+run\s+([A-Za-z0-9:_-]+)$') {
        Invoke-External -FilePath 'npm' -Arguments @('run', $Matches[1]) -WorkingDirectory $ManagerDir | Out-Null
    } else {
        throw "Cannot run manager frontend build command without sh: $($buildInfo.BeforeBuildCommand)"
    }

    if (-not (Test-Path $buildInfo.FrontendDist)) {
        throw "Manager frontend build did not create frontendDist: $($buildInfo.FrontendDist)"
    }
}

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
    Invoke-ManagerFrontendBuild $managerDir
    $buildArgs = @('build', '-p', 'codex-plus-launcher', '-p', 'codex-plus-manager')
    if ($BuildMode -eq 'release') { $buildArgs += '--release' }
    Invoke-External -FilePath 'cargo' -Arguments $buildArgs -WorkingDirectory $SourceRoot | Out-Null
}

function Quote-DesktopExecPath {
    param([string]$PathValue)
    return '"' + $PathValue.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Install-ExecutableFile {
    param(
        [string]$Source,
        [string]$Destination
    )
    $destinationDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Destination))
    [void][System.IO.Directory]::CreateDirectory($destinationDir)
    $tempDestination = Join-Path $destinationDir (".{0}.tmp.{1}" -f ([System.IO.Path]::GetFileName($Destination)), $PID)

    # EN: Linux returns ETXTBSY when copying over a running executable; copy to a sibling file first.
    # ZH: Linux 上直接覆盖正在运行的可执行文件会触发 ETXTBSY；先复制到同目录临时文件。
    Copy-Item -LiteralPath $Source -Destination $tempDestination -Force

    # EN: A same-directory rename replaces the path while the old running inode remains valid for existing processes.
    # ZH: 同目录 rename 会替换路径，同时旧 inode 仍可供已运行进程继续使用。
    if (Test-CommandAvailable 'mv') {
        Invoke-External -FilePath 'mv' -Arguments @('-f', $tempDestination, $Destination) | Out-Null
    } else {
        Move-Item -LiteralPath $tempDestination -Destination $Destination -Force
    }
}

function Get-CodexDesktopIconPath {
    param([string]$CodexAppDir)
    $linuxIcon = Join-Path $CodexAppDir '.codex-linux/codex-desktop.png'
    if (Test-Path $linuxIcon) {
        return [System.IO.Path]::GetFullPath($linuxIcon)
    }
    return ''
}

function New-DesktopEntryText {
    param(
        [string]$Name,
        [string]$Comment,
        [string]$ExecPath,
        [string]$IconPath
    )
    $iconLine = if ([string]::IsNullOrWhiteSpace($IconPath)) { '' } else { "Icon=$IconPath`n" }
    # EN: Keep a final newline so tools do not concatenate following output with the last desktop key.
    # ZH: 保留文件末尾换行，避免命令行工具把后续输出接到最后一个 desktop 键后面。
    $text = @"
[Desktop Entry]
Type=Application
Name=$Name
Comment=$Comment
Exec=$(Quote-DesktopExecPath $ExecPath)
${iconLine}Terminal=false
Categories=Development;
"@
    return "$text`n"
}

function Remove-DesktopEntryFiles {
    param(
        [string]$ApplicationsDir,
        [string[]]$Names
    )
    foreach ($name in $Names) {
        $path = Join-Path $ApplicationsDir $name
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Install-DesktopEntries {
    param(
        [string]$InstallRoot,
        [string]$CodexAppDir
    )

    # EN: Match Codex++ upstream-style Linux entry names instead of creating adapter-branded duplicates.
    # ZH: 这里保持 Codex++ 原项目风格的 Linux 入口名称，不再创建带适配器品牌的重复快捷方式。
    $apps = Get-AdapterApplicationsDir
    [void][System.IO.Directory]::CreateDirectory($apps)
    Remove-DesktopEntryFiles $apps @('codex-plus-plus-linux.desktop', 'codex-plus-plus-manager-linux.desktop')

    $binDir = Join-Path $InstallRoot 'install'
    $wrapper = [System.IO.Path]::GetFullPath((Join-Path $binDir 'launch-codex-plus-plus'))
    $manager = [System.IO.Path]::GetFullPath((Join-Path $binDir 'codex-plus-plus-manager'))
    $icon = Get-CodexDesktopIconPath $CodexAppDir

    [System.IO.File]::WriteAllText(
        (Join-Path $apps 'codex-plus-plus.desktop'),
        (New-DesktopEntryText 'Codex++' 'Launch Codex Desktop with Codex++ injection' $wrapper $icon)
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $apps 'codex-plus-plus-manager.desktop'),
        (New-DesktopEntryText 'Codex++ Manager' 'Manage Codex++ settings and diagnostics' $manager $icon)
    )
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
    Install-ExecutableFile -Source $launcher -Destination (Join-Path $binDir 'codex-plus-plus')
    Install-ExecutableFile -Source $manager -Destination (Join-Path $binDir 'codex-plus-plus-manager')

    $wrapper = Join-Path $binDir 'launch-codex-plus-plus'
    $launcherQuoted = Quote-ShSingle ([System.IO.Path]::GetFullPath((Join-Path $binDir 'codex-plus-plus')))
    $appQuoted = Quote-ShSingle ([System.IO.Path]::GetFullPath($CodexAppDir))
    $wrapperText = @"
#!/bin/sh
# Managed by CodexPlusPlus on Linux.
exec $launcherQuoted --app-path $appQuoted "`$@"
"@
    [System.IO.File]::WriteAllText($wrapper, $wrapperText)
    if (Test-CommandAvailable 'chmod') {
        Invoke-External -FilePath 'chmod' -Arguments @('+x', (Join-Path $binDir 'codex-plus-plus'), (Join-Path $binDir 'codex-plus-plus-manager'), $wrapper) | Out-Null
    }

    $readme = Join-Path $binDir 'README-linux-adapter.txt'
    [System.IO.File]::WriteAllText($readme, "Managed by CodexPlusPlus on Linux.`nLaunch with: $wrapper`n")

    Assert-InstalledLinuxAdaptationApplied -InstallRoot $InstallRoot

    if ($CreateDesktopEntries) {
        Install-DesktopEntries -InstallRoot $InstallRoot -CodexAppDir $CodexAppDir
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
    $apps = Get-AdapterApplicationsDir
    Remove-DesktopEntryFiles $apps @(
        'codex-plus-plus.desktop',
        'codex-plus-plus-manager.desktop',
        'codex-plus-plus-linux.desktop',
        'codex-plus-plus-manager-linux.desktop'
    )
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
    Add-AdapterLog "Using Codex Desktop root: $codexRoot"

    Invoke-AdapterStep 8 'Check Codex Desktop / 检查 Codex Desktop' {
        $script:CodexInfo = Test-CodexDesktopInstall $codexRoot
        if (-not $script:CodexInfo.Installed) { throw (T 'CodexMissing') }
    }
    # EN: Relative Codex++ paths must follow the detected Linux app root, not a hard-coded codex-app child.
    # ZH: 相对 Codex++ 路径必须跟随已识别的 Linux app 根目录，而不是硬编码 codex-app 子目录。
    $installRoot = Resolve-AdapterInstallPath $script:CodexInfo.AppDir $CodexPlusPlusInstallPath
    $workRoot = Join-Path $installRoot $WorkDirName
    Add-AdapterLog "Using Codex++ install root: $installRoot"
    [void][System.IO.Directory]::CreateDirectory($workRoot)
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
        Assert-SourceLinuxAdaptationApplied -SourceRoot $script:SourceRoot
    }
    Invoke-AdapterStep 72 'Build Codex++ / 构建 Codex++' {
        Invoke-CodexPlusPlusBuild $script:SourceRoot
    }
    Invoke-AdapterStep 90 'Install binaries / 安装二进制文件' {
        Install-AdaptedBinaries -SourceRoot $script:SourceRoot -InstallRoot $installRoot -CodexAppDir $script:CodexInfo.AppDir
        Sync-CodexPlusPlusUserState `
            -CodexAppDir $script:CodexInfo.AppDir `
            -InstallRoot $installRoot `
            -SourceRoot $script:SourceRoot `
            -CodexPlusPlusVersion (Get-CodexPlusPlusVersion $script:SourceRoot) `
            -CodexDesktopVersion $script:CodexInfo.Version
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
    $versionPath = Join-Path (Get-RepositoryRoot) 'VERSION'
    if (Test-Path $versionPath) {
        $projectVersion = [System.IO.File]::ReadAllText($versionPath).Trim()
        if ($projectVersion -ne $CodexPlusPlusUpstreamVersion) {
            throw "VERSION ($projectVersion) does not match pinned upstream version ($CodexPlusPlusUpstreamVersion)"
        }
    }
    $layoutTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codexpp-layout-selftest-{0}" -f ([Guid]::NewGuid().ToString('N')))
    try {
        $directRoot = Join-Path $layoutTestRoot 'CodexDesktop'
        $nestedRoot = Join-Path $layoutTestRoot 'codex-desktop-linux'
        $nestedApp = Join-Path $nestedRoot 'codex-app'
        [void][System.IO.Directory]::CreateDirectory($directRoot)
        [void][System.IO.Directory]::CreateDirectory($nestedApp)
        [System.IO.File]::WriteAllText((Join-Path $directRoot 'start.sh'), "#!/bin/sh`n")
        [System.IO.File]::WriteAllText((Join-Path $directRoot 'version'), "direct`n")
        [System.IO.File]::WriteAllText((Join-Path $nestedApp 'start.sh'), "#!/bin/sh`n")
        [System.IO.File]::WriteAllText((Join-Path $nestedApp 'version'), "nested`n")
        [void][System.IO.Directory]::CreateDirectory((Join-Path $directRoot '.codex-plusplus'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $nestedApp '.codex-plusplus'))

        # EN: The installer must accept both Linux packaging layouts used by the documented workflows.
        # ZH: 安装脚本必须同时接受文档工作流中会出现的两种 Linux 打包布局。
        $directInfo = Test-CodexDesktopInstall $directRoot
        $nestedInfo = Test-CodexDesktopInstall $nestedRoot
        if (-not $directInfo.Installed -or [System.IO.Path]::GetFullPath($directInfo.AppDir) -ne [System.IO.Path]::GetFullPath($directRoot)) {
            throw 'Direct Codex Desktop root layout was not detected correctly.'
        }
        if (-not $nestedInfo.Installed -or [System.IO.Path]::GetFullPath($nestedInfo.AppDir) -ne [System.IO.Path]::GetFullPath($nestedApp)) {
            throw 'Nested codex-app layout was not detected correctly.'
        }

        # EN: Relative Codex++ install paths are resolved from the detected app directory, not blindly from the outer root.
        # ZH: 相对 Codex++ 安装路径应从已识别的 app 目录解析，而不是盲目从外层根目录解析。
        $directInstall = Resolve-AdapterInstallPath $directInfo.AppDir '.codex-plusplus'
        $nestedInstall = Resolve-AdapterInstallPath $nestedInfo.AppDir '.codex-plusplus'
        if ([System.IO.Path]::GetFullPath($directInstall) -ne [System.IO.Path]::GetFullPath((Join-Path $directRoot '.codex-plusplus'))) {
            throw 'Direct Codex++ install path was not resolved from the direct app root.'
        }
        if ([System.IO.Path]::GetFullPath($nestedInstall) -ne [System.IO.Path]::GetFullPath((Join-Path $nestedApp '.codex-plusplus'))) {
            throw 'Nested Codex++ install path was not resolved from the nested app root.'
        }
        if ([System.IO.Path]::GetFullPath((Resolve-AdapterInstallPathForExistingOperation $directInfo '.codex-plusplus')) -ne [System.IO.Path]::GetFullPath((Join-Path $directRoot '.codex-plusplus'))) {
            throw 'Existing direct Codex++ install path was not found.'
        }
        if ([System.IO.Path]::GetFullPath((Resolve-AdapterInstallPathForExistingOperation $nestedInfo '.codex-plusplus')) -ne [System.IO.Path]::GetFullPath((Join-Path $nestedApp '.codex-plusplus'))) {
            throw 'Existing nested Codex++ install path was not found.'
        }
    } finally {
        if (Test-Path $layoutTestRoot) { Remove-Item -LiteralPath $layoutTestRoot -Recurse -Force }
    }
    Write-Host "Selftest OK: manifest and patch attachments are readable."
}

try {
    switch ($Action) {
        'install' {
            Read-OperationPathConfiguration
            Invoke-InstallOrUpdate -IsUpdate:$false
        }
        'update' {
            Read-OperationPathConfiguration
            Invoke-InstallOrUpdate -IsUpdate:$true
        }
        'uninstall' {
            Read-OperationPathConfiguration
            $codexRoot = Expand-AdapterPath $CodexDesktopRoot
            $codexInfo = Test-CodexDesktopInstall $codexRoot
            $installRoot = Resolve-AdapterInstallPathForExistingOperation $codexInfo $CodexPlusPlusInstallPath
            Add-AdapterLog "Using Codex Desktop root: $codexRoot"
            Add-AdapterLog "Using Codex++ install root: $installRoot"
            if (Confirm-AdapterAction (T 'ConfirmUninstall') $true) {
                Invoke-AdapterStep 100 'Uninstall / 卸载' {
                    Uninstall-AdaptedCodexPlusPlus $installRoot
                    Clear-CodexPlusPlusLatestStatusForKnownLayouts $codexInfo
                }
            }
        }
        'list-snippets' { Invoke-ListSnippets }
        'apply-snippets' {
            $codexRoot = Expand-AdapterPath $CodexDesktopRoot
            $codexInfo = Test-CodexDesktopInstall $codexRoot
            $installRoot = Resolve-AdapterInstallPathForExistingOperation $codexInfo $CodexPlusPlusInstallPath
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
