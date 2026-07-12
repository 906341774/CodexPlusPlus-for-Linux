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
$PayloadCompatibilityScript = Join-Path $DeveloperScripts 'test-release-payload-compatibility.sh'
$ManagerCompatibilityScript = Join-Path $DeveloperScripts 'linux-manager-webkit4-compat.sh'
$ManagerCompatibilitySource = Join-Path $DeveloperScripts 'lib/linux-manager-webkit4-compat.c'
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
    'New-PortableRelease.ps1',
    'linux-manager-webkit4-compat.sh',
    'test-release-payload-compatibility.sh'
)
foreach ($name in $requiredDeveloperScripts) {
    Assert-PathIsFile (Join-Path $DeveloperScripts $name)
}
Assert-PathIsFile $PortableManager
Assert-PathIsFile $ManagerCompatibilitySource
$topLevelScripts = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -File -Force -ErrorAction Stop)
Assert-True ($topLevelScripts.Count -eq 0) 'scripts/ must contain only the developer/ and normal_user/ subdirectories.'

Write-Host '== Legacy Linux Manager build compatibility contract =='
& bash $ManagerCompatibilityScript selftest 2>&1 | Out-Host
Assert-True ($LASTEXITCODE -eq 0) 'Linux Manager WebKitGTK 4.0 helper selftest failed.'
$hostElfForManagerVerification = @('/usr/bin/true', '/bin/true') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
Assert-True (-not [string]::IsNullOrWhiteSpace($hostElfForManagerVerification)) 'Could not locate an ELF fixture for Manager verification.'
$managerVerificationFailure = @(& bash $ManagerCompatibilityScript verify $hostElfForManagerVerification 2>&1)
Assert-True ($LASTEXITCODE -ne 0) 'WebKitGTK 4.0 verification accepted an unrelated ELF executable.'
Assert-True (($managerVerificationFailure -join "`n").Contains('libwebkit2gtk-4.0.so.37')) 'WebKitGTK 4.0 verification did not explain the missing runtime SONAME.'
$managerHelperText = [System.IO.File]::ReadAllText($ManagerCompatibilityScript)
foreach ($marker in @(
    'prepare)',
    'verify)',
    'install-runtime)',
    'libwebkit2gtk-4.0.so.37',
    'libjavascriptcoregtk-4.0.so.18',
    'libsoup-2.4.so.1',
    'manager-runtime'
)) {
    Assert-True ($managerHelperText.Contains($marker)) "Linux Manager compatibility helper is missing contract marker: $marker"
}
$managerCompatibilitySourceText = [System.IO.File]::ReadAllText($ManagerCompatibilitySource)
foreach ($symbol in @(
    'webkit_uri_scheme_request_get_http_body',
    'soup_cookie_get_same_site_policy',
    'soup_cookie_set_same_site_policy',
    'soup_message_headers_ref',
    'soup_message_headers_unref',
    'g_source_set_dispose_function',
    'g_uri_error_quark',
    'webkit_cookie_manager_get_all_cookies',
    'webkit_cookie_manager_get_all_cookies_finish'
)) {
    Assert-True ($managerCompatibilitySourceText.Contains($symbol)) "Linux Manager compatibility source is missing symbol: $symbol"
}
$installerText = [System.IO.File]::ReadAllText((Join-Path $DeveloperScripts 'Installer-and-Manager.ps1'))
Assert-True ($installerText.Contains('CODEXPP_LINUX_MANAGER_WEBKIT_MODE')) 'Installer does not expose the Linux Manager WebKit mode override.'
Assert-True ($installerText.Contains('linux-manager-webkit4-compat.sh')) 'Installer does not invoke the WebKitGTK 4.0 compatibility helper.'
foreach ($marker in @(
    'Resolve-LinuxManagerWebKitBuildMode',
    "@('prepare'",
    "@('verify'",
    "@('install-runtime'",
    'manager-runtime'
)) {
    Assert-True ($installerText.Contains($marker)) "Installer is missing the Linux Manager compatibility flow marker: $marker"
}
Assert-True (
    $installerText.Contains("Invoke-External -FilePath 'sh' -Arguments @('-c', `$buildInfo.BeforeBuildCommand)")
) 'Manager frontend build must preserve the caller PATH when invoking the configured shell command.'
Assert-True (
    -not $installerText.Contains("Invoke-External -FilePath 'sh' -Arguments @('-lc', `$buildInfo.BeforeBuildCommand)")
) 'Manager frontend build must not use a login shell that can reset PATH.'

$debControlText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'codex-desktop-linux/src/packaging/linux/control'))
foreach ($dependency in @('libwebkit2gtk-4.0-37', 'libjavascriptcoregtk-4.0-18', 'libsoup2.4-1')) {
    Assert-True ($debControlText.Contains($dependency)) "Debian package metadata is missing the Codex++ Manager runtime dependency: $dependency"
}
Assert-True (
    $debControlText -match '(?m)^Depends:.*(?:,\s*|:\s*)git(?:\s*,|$)'
) 'Debian package metadata must install git so Codex app-server plugin sync cannot stall on the HTTP fallback.'
$rpmSpecText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'codex-desktop-linux/src/packaging/linux/codex-desktop.spec'))
foreach ($dependency in @('libwebkit2gtk-4.0.so.37', 'libjavascriptcoregtk-4.0.so.18', 'libsoup-2.4.so.1')) {
    Assert-True ($rpmSpecText.Contains($dependency)) "RPM package metadata is missing the Codex++ Manager runtime dependency: $dependency"
}
Assert-True (
    $rpmSpecText -match '(?m)^Requires:\s+git(?:\s|,|$)'
) 'RPM package metadata must install git so Codex app-server plugin sync cannot stall on the HTTP fallback.'
Assert-True (
    $rpmSpecText -match '(?m)^Recommends:\s+.*\bgoogle-noto-sans-cjk-ttc-fonts\b'
) 'RPM package metadata must recommend the RHEL 9 CJK font so the Codex++ Manager default UI does not render tofu glyphs.'
$debBuilderText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'codex-desktop-linux/src/scripts/build-deb.sh'))
foreach ($dependency in @('build-essential', 'dpkg', 'p7zip-full', 'unzip')) {
    Assert-True (
        $debBuilderText.Contains("s/$dependency, //g")
    ) "Debian no-updater packaging does not remove the build-only dependency: $dependency"
}

Write-Host '== Dynamic Linux feature discovery contract =='
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codexpp-distribution-$PID-$([Guid]::NewGuid().ToString('N'))"
try {
    Write-Host '== Release payload compatibility gate =='
    $compatibilityRoot = Join-Path $testRoot 'compatibility-payload'
    $compatibilityInstall = Join-Path $compatibilityRoot '.codex-plusplus/install'
    New-Item -ItemType Directory -Force -Path $compatibilityInstall | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $compatibilityInstall 'codex-plus-plus-manager'),
        "#!/bin/sh`nexit 0`n"
    )
    & bash $PayloadCompatibilityScript --max-glibc 2.28 $compatibilityRoot 2>&1 | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) 'Compatibility gate rejected a payload containing no ELF files.'

    $hostElf = @('/usr/bin/true', '/bin/true') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    Assert-True (-not [string]::IsNullOrWhiteSpace($hostElf)) 'Could not locate a host ELF fixture.'
    Copy-Item -LiteralPath $hostElf -Destination (Join-Path $compatibilityRoot 'too-new-elf') -Force
    $compatibilityFailure = @(& bash $PayloadCompatibilityScript --max-glibc 2.28 $compatibilityRoot 2>&1)
    Assert-True ($LASTEXITCODE -ne 0) 'Compatibility gate accepted an ELF requiring a GLIBC version above 2.28.'
    Assert-True (($compatibilityFailure -join "`n").Contains('exceeds maximum GLIBC_2.28')) 'Compatibility gate failure did not identify the GLIBC ceiling.'
    Remove-Item -LiteralPath (Join-Path $compatibilityRoot 'too-new-elf') -Force

    $staticSource = Join-Path $compatibilityRoot 'static-fixture.c'
    $staticElf = Join-Path $compatibilityRoot 'static-fixture'
    [System.IO.File]::WriteAllText($staticSource, "int main(void) { return 0; }`n")
    & gcc -static $staticSource -o $staticElf
    Assert-True ($LASTEXITCODE -eq 0) 'Could not compile the static ELF compatibility fixture.'
    $staticResult = @(& bash $PayloadCompatibilityScript --max-glibc 2.28 $compatibilityRoot 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "Compatibility gate rejected a static ELF with no GLIBC version requirements: $($staticResult -join "`n")"

    $managerFailure = @(& bash $PayloadCompatibilityScript --max-glibc 2.28 --require-manager-elf $compatibilityRoot 2>&1)
    Assert-True ($LASTEXITCODE -ne 0) 'Compatibility gate accepted a non-ELF Codex++ Manager.'
    Assert-True (($managerFailure -join "`n").Contains('Codex++ Manager is not an ELF executable')) 'Compatibility gate did not explain the Manager runtime failure.'

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
    $x11FeatureRoot = Join-Path $featuresRoot 'x11-ewmh-computer-use'
    New-Item -ItemType Directory -Force -Path $x11FeatureRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $x11FeatureRoot 'feature.json'),
        (@{ id = 'x11-ewmh-computer-use' } | ConvertTo-Json -Compress)
    )

    $x11FixtureRepository = Join-Path $testRoot 'x11-computer-use-source'
    New-Item -ItemType Directory -Force -Path $x11FixtureRepository | Out-Null
    & git -C $x11FixtureRepository init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the X11 Computer Use source fixture.' }
    & git -C $x11FixtureRepository config user.name 'Codex++ Distribution Test'
    & git -C $x11FixtureRepository config user.email 'codexpp-distribution-test@example.invalid'
    [System.IO.File]::WriteAllText(
        (Join-Path $x11FixtureRepository 'Cargo.toml'),
        @'
[package]
name = "codex-computer-use-x11"
version = "0.0.0"
'@
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $x11FixtureRepository 'compatibility-marker'),
        "glibc-2.28-source$([Environment]::NewLine)"
    )
    & git -C $x11FixtureRepository add Cargo.toml compatibility-marker
    & git -C $x11FixtureRepository commit --quiet -m 'compatible source fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the X11 Computer Use source fixture.' }
    $x11FixtureCommit = (& git -C $x11FixtureRepository rev-parse HEAD).Trim()
    & git -C $x11FixtureRepository tag compatibility-fixture
    [System.IO.File]::WriteAllText(
        (Join-Path $x11FixtureRepository 'compatibility-marker'),
        "newer unpinned source$([Environment]::NewLine)"
    )
    & git -C $x11FixtureRepository add compatibility-marker
    & git -C $x11FixtureRepository commit --quiet -m 'newer source fixture'

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
test -n "$CODEX_X11_COMPUTER_USE_SOURCE"
test -f "$CODEX_X11_COMPUTER_USE_SOURCE/Cargo.toml"
grep -qx 'glibc-2.28-source' "$CODEX_X11_COMPUTER_USE_SOURCE/compatibility-marker"
test "$(git -C "$CODEX_X11_COMPUTER_USE_SOURCE" rev-parse HEAD)" = "$CODEXPP_TEST_EXPECTED_X11_COMMIT"
case "$CODEX_X11_COMPUTER_USE_SOURCE" in
    "$CODEXPP_TEST_EXPECTED_X11_CACHE_ROOT"/*) ;;
    *) echo "X11 source escaped the isolated build-source cache" >&2; exit 1 ;;
esac
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
    $oldExpectedX11Commit = $env:CODEXPP_TEST_EXPECTED_X11_COMMIT
    $oldExpectedX11CacheRoot = $env:CODEXPP_TEST_EXPECTED_X11_CACHE_ROOT
    $x11FixtureCacheRoot = Join-Path $testRoot 'build-source-cache'
    try {
        $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$oldPath"
        $env:CODEXPP_TEST_EXPECTED_X11_COMMIT = $x11FixtureCommit
        $env:CODEXPP_TEST_EXPECTED_X11_CACHE_ROOT = $x11FixtureCacheRoot
        [void](Invoke-CheckedPowerShell $BuildScript @(
            '-Action', 'build-install',
            '-SourceRoot', $featureSource,
            '-InstallPath', $fakeInstall,
            '-BuildSourceCacheRoot', $x11FixtureCacheRoot,
            '-X11ComputerUseRepository', $x11FixtureRepository,
            '-X11ComputerUseRef', 'compatibility-fixture',
            '-X11ComputerUseCommit', $x11FixtureCommit
        ))
    } finally {
        $env:PATH = $oldPath
        $env:CODEXPP_TEST_EXPECTED_X11_COMMIT = $oldExpectedX11Commit
        $env:CODEXPP_TEST_EXPECTED_X11_CACHE_ROOT = $oldExpectedX11CacheRoot
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
