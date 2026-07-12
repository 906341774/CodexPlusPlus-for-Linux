#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('install', 'update', 'uninstall')]
    [string]$Action = 'install',
    [string]$ArchivePath,
    [string]$InstallPath = '$HOME/.local/opt/CodexDesktop',
    [switch]$PurgeUserData,
    [switch]$NonInteractive,
    [switch]$NoTui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UserHome {
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return [System.IO.Path]::GetFullPath($env:HOME) }
    return [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}

function Expand-PortablePath {
    param([Parameter(Mandatory = $true)][string]$Value)
    $homePath = Get-UserHome
    $expanded = $Value.Trim()
    foreach ($prefix in @('$env:HOME', '${HOME}', '$HOME')) {
        if ($expanded -eq $prefix) { $expanded = $homePath; break }
        if ($expanded.StartsWith("$prefix/")) {
            $expanded = Join-Path $homePath $expanded.Substring($prefix.Length + 1)
            break
        }
    }
    if ($expanded -eq '~') { $expanded = $homePath }
    if ($expanded.StartsWith('~/')) { $expanded = Join-Path $homePath $expanded.Substring(2) }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-XdgPath {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName, [Parameter(Mandatory = $true)][string]$Fallback)
    $value = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return [System.IO.Path]::GetFullPath($value) }
    return Join-Path (Get-UserHome) $Fallback
}

$script:UseChinese = @($env:LANG, $env:LC_ALL, $env:LC_MESSAGES) -match '(^|[.=])zh([_-]|$)'
$script:Interactive = -not $NonInteractive -and -not $NoTui -and [Environment]::UserInteractive
$script:Messages = @{
    en = @{
        Title = 'CodexDesktop Portable Manager'
        Install = 'Install a validated CodexDesktop + Codex++ portable release'
        Update = 'Atomically replace the installed release and keep user data'
        Uninstall = 'Remove the portable application; user data is preserved by default'
        Purge = 'User data will also be permanently removed'
        Preserve = 'User data will be preserved'
        Confirm = 'Continue with this operation?'
    }
    zh = @{
        Title = 'CodexDesktop 便携版管理器'
        Install = '安装已验收的 CodexDesktop + Codex++ 便携发行包'
        Update = '以原子替换方式升级应用，并保留用户数据'
        Uninstall = '卸载便携应用；默认保留用户数据'
        Purge = '用户数据也将被永久删除'
        Preserve = '用户数据将被保留'
        Confirm = '确认继续执行吗？'
    }
}

function T {
    param([Parameter(Mandatory = $true)][string]$Key)
    $language = if ($script:UseChinese) { 'zh' } else { 'en' }
    return $script:Messages[$language][$Key]
}

function Write-ManagerStatus {
    param([Parameter(Mandatory = $true)][string]$Message, [ValidateSet('info', 'ok', 'warn')][string]$Kind = 'info')
    $prefix = switch ($Kind) { 'ok' { '[OK]' } 'warn' { '[!]' } default { '[>]' } }
    Write-Host "$prefix $Message"
}

function Show-OperationSummary {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $description = switch ($Action) {
        'install' { T 'Install' }
        'update' { T 'Update' }
        'uninstall' { T 'Uninstall' }
    }
    Write-Host ''
    Write-Host ('=' * 68)
    Write-Host (T 'Title')
    Write-Host ('=' * 68)
    Write-Host $description
    Write-Host "Action:      $Action"
    if ($Action -ne 'uninstall') { Write-Host "Archive:     $ArchivePath" }
    Write-Host "Destination: $Destination"
    Write-Host "Data policy: $(if ($PurgeUserData) { T 'Purge' } else { T 'Preserve' })"
    Write-Host ('=' * 68)
    Write-Host ''
}

function Confirm-Operation {
    if ($NonInteractive) { return $true }
    $answer = Read-Host "$(T 'Confirm') [Y/n]"
    return [string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|yes|是|确认|確認)$'
}

function Resolve-SevenZip {
    foreach ($name in @('7zz', '7z')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw '7zz is required to install or update the portable release.'
}

function Remove-PortableBackupBestEffort {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $lastError = $null
    foreach ($attempt in 1..4) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            $lastError = $_
            if ($attempt -lt 4) { Start-Sleep -Milliseconds (250 * $attempt) }
        }
    }

    $message = if ($script:UseChinese) {
        "便携版更新已成功，但旧备份暂时无法清理：$Path。请关闭旧安装仍在运行的进程；下次安装或更新会重试。$($lastError.Exception.Message)"
    } else {
        "Portable update succeeded, but old backup cleanup was deferred: $Path. Close processes from the previous installation; the next install or update will retry cleanup. $($lastError.Exception.Message)"
    }
    Write-ManagerStatus $message warn
    return $false
}

function Remove-StalePortableBackups {
    param([Parameter(Mandatory = $true)][string]$Parent)

    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { return }
    $backups = @(
        Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.codexdesktop-portable-backup-*' }
    )
    foreach ($backup in $backups) {
        [void](Remove-PortableBackupBestEffort -Path $backup.FullName)
    }
}

function Assert-Payload {
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($relative in @(
        'start.sh',
        '.codex-linux/build-info.json',
        '.codex-linux/codex-desktop.png',
        'resources/codex-linux-build-info.json',
        '.codex-plusplus/install/codex-plus-plus',
        '.codex-plusplus/install/codex-plus-plus-manager',
        '.codex-plusplus/install/launch-codex-plus-plus'
    )) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Archive payload is incomplete: $relative" }
    }

    $first = Get-Content -LiteralPath (Join-Path $Root '.codex-linux/build-info.json') -Raw | ConvertFrom-Json
    $second = Get-Content -LiteralPath (Join-Path $Root 'resources/codex-linux-build-info.json') -Raw | ConvertFrom-Json
    $firstFeatures = @($first.linuxFeatures.enabled | Sort-Object)
    $secondFeatures = @($second.linuxFeatures.enabled | Sort-Object)
    if (($firstFeatures -join "`n") -ne ($secondFeatures -join "`n")) {
        throw 'The two Codex Desktop build-info files disagree about enabled Linux features.'
    }
}

function Write-AtomicTextFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($temporary, $Content)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Remove-PortableManagedDesktopEntry {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text.Contains('X-CodexDesktop-Portable-Managed=true')) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function New-PortableDesktopEntryText {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Comment,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Icon
    )

    $quotedExecutable = '"' + $Executable.Replace('\', '\\').Replace('"', '\"') + '"'
    return @"
[Desktop Entry]
Type=Application
Name=$Name
Comment=$Comment
Exec=$quotedExecutable
Icon=$Icon
Terminal=false
Categories=Development;
X-CodexDesktop-Portable-Managed=true
"@
}

function Set-PortableIntegration {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $dataHome = Get-XdgPath 'XDG_DATA_HOME' '.local/share'
    $binRoot = Join-Path (Get-UserHome) '.local/bin'
    $applicationsRoot = Join-Path $dataHome 'applications'
    New-Item -ItemType Directory -Force -Path $binRoot, $applicationsRoot | Out-Null

    $links = [ordered]@{
        'codex-desktop-linux' = Join-Path $Destination 'start.sh'
        'codex-plus-plus' = Join-Path $Destination '.codex-plusplus/install/launch-codex-plus-plus'
        'codex-plus-plus-manager' = Join-Path $Destination '.codex-plusplus/install/codex-plus-plus-manager'
    }
    foreach ($name in $links.Keys) {
        $link = Join-Path $binRoot $name
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        New-Item -ItemType SymbolicLink -Path $link -Target $links[$name] | Out-Null
    }

    Remove-PortableManagedDesktopEntry -Path (Join-Path $applicationsRoot 'codex-desktop-portable.desktop')
    $icon = Join-Path $Destination '.codex-linux/codex-desktop.png'
    $desktopEntries = @(
        [ordered]@{
            File = 'codex-plus-plus.desktop'
            Name = 'Codex++'
            Comment = 'Launch Codex Desktop with Codex++ injection'
            Executable = Join-Path $binRoot 'codex-plus-plus'
        },
        [ordered]@{
            File = 'codex-plus-plus-manager.desktop'
            Name = 'Codex++ Manager'
            Comment = 'Manage Codex++ settings and diagnostics'
            Executable = Join-Path $binRoot 'codex-plus-plus-manager'
        }
    )
    foreach ($entry in $desktopEntries) {
        $text = New-PortableDesktopEntryText -Name $entry.Name -Comment $entry.Comment -Executable $entry.Executable -Icon $icon
        Write-AtomicTextFile -Path (Join-Path $applicationsRoot $entry.File) -Content $text
    }

    $stateRoot = Get-XdgPath 'XDG_STATE_HOME' '.local/state'
    $statePath = Join-Path $stateRoot 'codexdesktop-portable-manager/state.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
    [ordered]@{ installPath = $Destination; updatedAt = [DateTimeOffset]::UtcNow.ToString('O') } |
        ConvertTo-Json |
        Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
}

function Remove-PortableIntegration {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $dataHome = Get-XdgPath 'XDG_DATA_HOME' '.local/share'
    $binRoot = Join-Path (Get-UserHome) '.local/bin'
    foreach ($name in @('codex-desktop-linux', 'codex-plus-plus', 'codex-plus-plus-manager')) {
        $path = Join-Path $binRoot $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.LinkType -and [System.IO.Path]::GetFullPath([string]$item.Target) -like "$Destination/*") {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($name in @('codex-desktop-portable.desktop', 'codex-plus-plus.desktop', 'codex-plus-plus-manager.desktop')) {
        Remove-PortableManagedDesktopEntry -Path (Join-Path $dataHome "applications/$name")
    }
    $statePath = Join-Path (Get-XdgPath 'XDG_STATE_HOME' '.local/state') 'codexdesktop-portable-manager/state.json'
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
}

function Install-PortablePayload {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][bool]$IsUpdate
    )
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "Archive does not exist: $Archive" }
    if ($IsUpdate -and -not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "Cannot update because CodexDesktop is not installed at $Destination"
    }
    if (-not $IsUpdate -and (Test-Path -LiteralPath $Destination)) {
        throw "Install destination already exists. Use -Action update: $Destination"
    }

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Remove-StalePortableBackups -Parent $parent
    $workRoot = Join-Path $parent ".codexdesktop-portable-work-$PID-$([Guid]::NewGuid().ToString('N'))"
    $incoming = Join-Path $parent ".codexdesktop-portable-incoming-$PID-$([Guid]::NewGuid().ToString('N'))"
    $backup = Join-Path $parent ".codexdesktop-portable-backup-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
        $sevenZip = Resolve-SevenZip
        Write-ManagerStatus 'Extracting and validating release...'
        & $sevenZip x -y "-o$workRoot" -- $Archive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z extraction failed with exit code $LASTEXITCODE." }
        $payload = Join-Path $workRoot 'CodexDesktop'
        Assert-Payload $payload
        Move-Item -LiteralPath $payload -Destination $incoming

        if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $backup }
        try {
            Move-Item -LiteralPath $incoming -Destination $Destination
            foreach ($relative in @('start.sh', '.codex-plusplus/install/codex-plus-plus', '.codex-plusplus/install/codex-plus-plus-manager', '.codex-plusplus/install/launch-codex-plus-plus')) {
                & chmod 0755 (Join-Path $Destination $relative)
                if ($LASTEXITCODE -ne 0) { throw "Could not mark executable: $relative" }
            }
            Set-PortableIntegration $Destination
        } catch {
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $Destination }
            throw
        }
        if (Test-Path -LiteralPath $backup) { [void](Remove-PortableBackupBestEffort -Path $backup) }
        Write-ManagerStatus "Installed at $Destination" ok
    } finally {
        foreach ($path in @($incoming, $workRoot)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}

function Remove-PortableUserData {
    $homePath = Get-UserHome
    $configHome = Get-XdgPath 'XDG_CONFIG_HOME' '.config'
    $dataHome = Get-XdgPath 'XDG_DATA_HOME' '.local/share'
    $stateHome = Get-XdgPath 'XDG_STATE_HOME' '.local/state'
    $cacheHome = Get-XdgPath 'XDG_CACHE_HOME' '.cache'
    $paths = @(
        (Join-Path $homePath '.codex'),
        (Join-Path $homePath '.codex-plus-plus'),
        (Join-Path $configHome 'Codex'),
        (Join-Path $configHome 'codex-plus-plus'),
        (Join-Path $dataHome 'codex-plusplus'),
        (Join-Path $stateHome 'codex-desktop'),
        (Join-Path $cacheHome 'codex-desktop')
    ) | Select-Object -Unique
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}

$destinationFull = Expand-PortablePath $InstallPath
if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Expand-PortablePath $ArchivePath }
Show-OperationSummary $destinationFull
if (-not (Confirm-Operation)) { Write-ManagerStatus 'Cancelled.' warn; exit 0 }

switch ($Action) {
    'install' { Install-PortablePayload -Archive $ArchivePath -Destination $destinationFull -IsUpdate:$false }
    'update' { Install-PortablePayload -Archive $ArchivePath -Destination $destinationFull -IsUpdate:$true }
    'uninstall' {
        Remove-PortableIntegration $destinationFull
        if (Test-Path -LiteralPath $destinationFull) { Remove-Item -LiteralPath $destinationFull -Recurse -Force }
        if ($PurgeUserData) {
            Remove-PortableUserData
            Write-ManagerStatus 'Application and user data removed.' ok
        } else {
            Write-ManagerStatus 'Application removed. User data was preserved.' ok
        }
    }
}
