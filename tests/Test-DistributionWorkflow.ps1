#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DeveloperScripts = Join-Path $RepoRoot 'scripts/developer'
$NormalUserScripts = Join-Path $RepoRoot 'scripts/normal_user'
$BuildScript = Join-Path $DeveloperScripts 'Build-CodexDesktopLinux.ps1'
$PackageScript = Join-Path $DeveloperScripts 'New-PortableRelease.ps1'
$PortableManager = Join-Path $NormalUserScripts 'CodexDesktop-Portable-Manager.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-PathIsFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "Expected file is missing: $Path"
}

function Invoke-CheckedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $output = @(& pwsh -NoLogo -NoProfile -File $ScriptPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "PowerShell command failed ($LASTEXITCODE): $ScriptPath $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return $output
}

function Resolve-SevenZip {
    foreach ($name in @('7zz', '7z')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw '7zz or 7z is required for distribution tests.'
}

function New-FakeCodexDesktopPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $appRoot = Join-Path $Root 'CodexDesktop'
    $codexPlusInstall = Join-Path $appRoot '.codex-plusplus/install'
    $buildInfoRoot = Join-Path $appRoot '.codex-linux'
    $resourcesRoot = Join-Path $appRoot 'resources'
    New-Item -ItemType Directory -Force -Path $codexPlusInstall, $buildInfoRoot, $resourcesRoot | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $appRoot 'start.sh'), "#!/usr/bin/env bash`necho CodexDesktop $Version`n")
    [System.IO.File]::WriteAllText((Join-Path $appRoot 'version'), "$Version`n")
    foreach ($name in @('codex-plus-plus', 'codex-plus-plus-manager', 'launch-codex-plus-plus')) {
        [System.IO.File]::WriteAllText((Join-Path $codexPlusInstall $name), "#!/usr/bin/env bash`necho $name $Version`n")
    }

    $buildInfo = [ordered]@{
        version = $Version
        linuxFeatures = [ordered]@{ enabled = @('alpha', 'beta') }
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $buildInfoRoot 'build-info.json'), $buildInfo)
    [System.IO.File]::WriteAllText((Join-Path $resourcesRoot 'codex-linux-build-info.json'), $buildInfo)
    return $appRoot
}

Write-Host '== Script layout contract =='
$requiredDeveloperScripts = @(
    'Installer-and-Manager.ps1',
    'Run-AdapterRegression.ps1',
    'Test-AdapterWorkflow.ps1',
    'run-adapter-regression.sh',
    'Build-CodexDesktopLinux.ps1',
    'New-PortableRelease.ps1'
)
foreach ($name in $requiredDeveloperScripts) {
    Assert-PathIsFile (Join-Path $DeveloperScripts $name)
}
Assert-PathIsFile $PortableManager
$topLevelScripts = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -File -Force -ErrorAction Stop)
Assert-True ($topLevelScripts.Count -eq 0) 'scripts/ must contain only the developer/ and normal_user/ subdirectories.'

Write-Host '== Dynamic Linux feature discovery contract =='
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codexpp-distribution-$PID-$([Guid]::NewGuid().ToString('N'))"
try {
    $featureSource = Join-Path $testRoot 'feature-source'
    $featuresRoot = Join-Path $featureSource 'linux-features'
    foreach ($name in @('beta', 'alpha', 'example-feature', 'local', 'missing-descriptor', '.hidden')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $featuresRoot $name) | Out-Null
    }
    foreach ($name in @('alpha', 'beta', 'example-feature', 'local', '.hidden')) {
        [System.IO.File]::WriteAllText(
            (Join-Path $featuresRoot "$name/feature.json"),
            (@{ id = $name } | ConvertTo-Json -Compress)
        )
    }

    $featureOutput = Invoke-CheckedPowerShell $BuildScript @(
        '-Action', 'discover-features',
        '-SourceRoot', $featureSource,
        '-NoLogoOutput'
    )
    $discovered = @(($featureOutput -join "`n" | ConvertFrom-Json).enabled)
    Assert-True (($discovered -join ',') -eq 'alpha,beta') "Unexpected discovered feature set: $($discovered -join ',')"

    Write-Host '== Codex Desktop build-install output isolation contract =='
    $fakeBin = Join-Path $testRoot 'fake-bin'
    $fakeMake = Join-Path $fakeBin 'make'
    $fakeInstall = Join-Path $testRoot 'fake-codex-desktop-install'
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $featureSource 'codex-app/content/webview/assets') | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $featureSource 'codex-app/content/webview/assets/stale-hash.js'),
        "stale payload must not survive a fresh build`n"
    )
    [System.IO.File]::WriteAllText(
        $fakeMake,
        @'
#!/usr/bin/env bash
set -euo pipefail
echo "fake make emits native stdout"
test "${1:-}" = "build-app"
mkdir -p codex-app/.codex-linux codex-app/resources
printf '#!/usr/bin/env bash\n' > codex-app/start.sh
chmod +x codex-app/start.sh
printf '{"linuxFeatures":' > codex-app/.codex-linux/build-info.json
cat linux-features/features.json >> codex-app/.codex-linux/build-info.json
printf '}\n' >> codex-app/.codex-linux/build-info.json
cp codex-app/.codex-linux/build-info.json codex-app/resources/codex-linux-build-info.json
'@
    )
    & chmod +x $fakeMake
    if ($LASTEXITCODE -ne 0) { throw 'Could not make the fake build command executable.' }

    $oldPath = $env:PATH
    try {
        $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$oldPath"
        [void](Invoke-CheckedPowerShell $BuildScript @(
            '-Action', 'build-install',
            '-SourceRoot', $featureSource,
            '-InstallPath', $fakeInstall
        ))
    } finally {
        $env:PATH = $oldPath
    }
    Assert-PathIsFile (Join-Path $fakeInstall 'start.sh')
    Assert-PathIsFile (Join-Path $fakeInstall '.codex-linux/build-info.json')
    Assert-PathIsFile (Join-Path $fakeInstall 'resources/codex-linux-build-info.json')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fakeInstall 'content/webview/assets/stale-hash.js'))) 'Codex Desktop build-install retained a stale generated asset from the previous payload.'

    Write-Host '== Portable package compression contract =='
    $packageText = Get-Content -LiteralPath $PackageScript -Raw
    Assert-True ($packageText.Contains('-mx=9')) 'Portable packager must request 7z maximum compression (-mx=9).'
    Assert-True ($packageText.Contains('-ms=off')) 'Portable packager must disable solid compression (-ms=off).'

    $payloadOne = New-FakeCodexDesktopPayload -Root (Join-Path $testRoot 'payload-one') -Version '9.9.1'
    $archiveOne = Join-Path $testRoot 'codex-desktop-portable-9.9.1.7z'
    [void](Invoke-CheckedPowerShell $PackageScript @(
        '-PayloadRoot', $payloadOne,
        '-OutputPath', $archiveOne,
        '-Version', '9.9.1',
        '-CodexPlusPlusVersion', '9.9.1',
        '-CodexDesktopCommit', 'test-commit-one',
        '-NonInteractive'
    ))
    Assert-PathIsFile $archiveOne
    $sevenZip = Resolve-SevenZip
    $archiveListing = @(& $sevenZip l -slt -- $archiveOne 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "Could not inspect portable archive: $($archiveListing -join "`n")"
    Assert-True (($archiveListing -join "`n") -match '(?m)^Solid = -$') 'Portable 7z archive is solid; it must be non-solid.'
    Assert-True (($archiveListing -join "`n").Contains('CodexDesktop/start.sh')) 'Portable archive does not contain a direct CodexDesktop payload.'
    Assert-True (($archiveListing -join "`n").Contains('CodexDesktop/.codex-plusplus/install/codex-plus-plus')) 'Portable archive does not contain Codex++.'

    Write-Host '== Portable manager lifecycle contract =='
    $isolatedHome = Join-Path $testRoot 'home'
    $xdgConfig = Join-Path $isolatedHome '.config'
    $xdgData = Join-Path $isolatedHome '.local/share'
    $xdgState = Join-Path $isolatedHome '.local/state'
    $installRoot = Join-Path $isolatedHome '.local/opt/CodexDesktop'
    New-Item -ItemType Directory -Force -Path $isolatedHome, $xdgConfig, $xdgData, $xdgState | Out-Null

    $oldEnvironment = @{
        HOME = $env:HOME
        XDG_CONFIG_HOME = $env:XDG_CONFIG_HOME
        XDG_DATA_HOME = $env:XDG_DATA_HOME
        XDG_STATE_HOME = $env:XDG_STATE_HOME
    }
    try {
        $env:HOME = $isolatedHome
        $env:XDG_CONFIG_HOME = $xdgConfig
        $env:XDG_DATA_HOME = $xdgData
        $env:XDG_STATE_HOME = $xdgState

        [void](Invoke-CheckedPowerShell $PortableManager @(
            '-Action', 'install', '-ArchivePath', $archiveOne, '-InstallPath', $installRoot,
            '-NonInteractive', '-NoTui'
        ))
        Assert-PathIsFile (Join-Path $installRoot 'start.sh')
        Assert-PathIsFile (Join-Path $installRoot '.codex-plusplus/install/codex-plus-plus')
        Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'version') -Raw).Trim() -eq '9.9.1') 'Portable install selected the wrong payload version.'

        $userDataFiles = @(
            (Join-Path $isolatedHome '.codex/session.json'),
            (Join-Path $xdgConfig 'Codex/settings.json'),
            (Join-Path $xdgData 'codex-plusplus/state.json')
        )
        foreach ($path in $userDataFiles) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [System.IO.File]::WriteAllText($path, "preserve me`n")
        }

        $payloadTwo = New-FakeCodexDesktopPayload -Root (Join-Path $testRoot 'payload-two') -Version '9.9.2'
        $archiveTwo = Join-Path $testRoot 'codex-desktop-portable-9.9.2.7z'
        [void](Invoke-CheckedPowerShell $PackageScript @(
            '-PayloadRoot', $payloadTwo,
            '-OutputPath', $archiveTwo,
            '-Version', '9.9.2',
            '-CodexPlusPlusVersion', '9.9.2',
            '-CodexDesktopCommit', 'test-commit-two',
            '-NonInteractive'
        ))
        [void](Invoke-CheckedPowerShell $PortableManager @(
            '-Action', 'update', '-ArchivePath', $archiveTwo, '-InstallPath', $installRoot,
            '-NonInteractive', '-NoTui'
        ))
        Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'version') -Raw).Trim() -eq '9.9.2') 'Portable update did not replace the installed payload.'
        foreach ($path in $userDataFiles) { Assert-PathIsFile $path }

        [void](Invoke-CheckedPowerShell $PortableManager @(
            '-Action', 'uninstall', '-InstallPath', $installRoot, '-NonInteractive', '-NoTui'
        ))
        Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Portable uninstall left the installation directory behind.'
        foreach ($path in $userDataFiles) { Assert-PathIsFile $path }

        [void](Invoke-CheckedPowerShell $PortableManager @(
            '-Action', 'install', '-ArchivePath', $archiveTwo, '-InstallPath', $installRoot,
            '-NonInteractive', '-NoTui'
        ))
        [void](Invoke-CheckedPowerShell $PortableManager @(
            '-Action', 'uninstall', '-InstallPath', $installRoot, '-PurgeUserData',
            '-NonInteractive', '-NoTui'
        ))
        foreach ($path in $userDataFiles) {
            Assert-True (-not (Test-Path -LiteralPath $path)) "Explicit purge left user data behind: $path"
        }
    } finally {
        $env:HOME = $oldEnvironment.HOME
        $env:XDG_CONFIG_HOME = $oldEnvironment.XDG_CONFIG_HOME
        $env:XDG_DATA_HOME = $oldEnvironment.XDG_DATA_HOME
        $env:XDG_STATE_HOME = $oldEnvironment.XDG_STATE_HOME
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Distribution workflow contract OK.'
