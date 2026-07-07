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

function Test-RepoPathExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = Resolve-RepoPath $Path
    return Test-Path -LiteralPath $fullPath
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

function Assert-TextNotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $fullPath = Resolve-RepoPath $Path
    $text = Get-Content -LiteralPath $fullPath -Raw
    if ($text.Contains($Needle)) {
        throw "Workflow contract failed: $Label must not be present in $Path"
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
Assert-TextContains 'scripts/Installer-and-Manager.ps1' "if (-not [string]::IsNullOrWhiteSpace(`$CodexPlusPlusLocalSource))" 'apply-snippets explicit local source path'
Assert-TextContains 'scripts/Installer-and-Manager.ps1' 'No Codex++ source found' 'apply-snippets source root validation'
Assert-TextContains 'scripts/Installer-and-Manager.ps1' 'Assert-SourceLinuxAdaptationApplied -SourceRoot $sourceRoot' 'apply-snippets source marker verification'
Assert-TextContains 'scripts/Installer-and-Manager.ps1' '$env:RUSTUP_HOME = $rustupHome' 'temporary Rust exports RUSTUP_HOME to current process'
Assert-TextContains 'scripts/Installer-and-Manager.ps1' '$env:CARGO_HOME = $cargoHome' 'temporary Rust exports CARGO_HOME to current process'
Assert-TextContains 'scripts/Installer-and-Manager.ps1' '$MinimumNodeMajorVersion = 20' 'Node dependency minimum major version'
Assert-TextContains 'scripts/Installer-and-Manager.ps1' 'Test-NodeMeetsMinimum' 'Node dependency version gate'

# EN: Documentation must point maintainers to the machine-checkable feature matrix.
# ZH: 文档必须把维护者引向可机器检查的功能矩阵。
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'feature-matrix.json' 'English workflow feature matrix link'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' 'feature-matrix.json' 'Chinese workflow feature matrix link'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'sudo mount -o loop,rw "$HOME/.local/share/podman-loop-storage/containers-storage.xfs" "$HOME/.local/share/containers"' 'English workflow Podman XFS mount prerequisite'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' 'sudo mount -o loop,rw "$HOME/.local/share/podman-loop-storage/containers-storage.xfs" "$HOME/.local/share/containers"' 'Chinese workflow Podman XFS mount prerequisite'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' '-CodexDesktopRootPath "$HOME/opt/CodexDesktop"' 'English workflow explicit validation Codex Desktop root'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' '-CodexDesktopRootPath "$HOME/opt/CodexDesktop"' 'Chinese workflow explicit validation Codex Desktop root'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'Stop and report' 'English workflow mandatory stop conditions'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' '必须停下上报' 'Chinese workflow mandatory stop conditions'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'Upstream source and release artifacts are a maintainer policy decision' 'English workflow upstream artifact policy'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' '上游源码和发行文件是否入库属于维护者策略决定' 'Chinese workflow upstream artifact policy'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'freeze one upstream baseline for the whole adaptation round' 'English workflow freezes one upstream baseline per round'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' '每一轮适配必须固定一个上游基线版本' 'Chinese workflow freezes one upstream baseline per round'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'Do not switch to a newer upstream release in the middle of the same round' 'English workflow forbids mid-round upstream switching'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' '同一轮中不得因为上游又发布新版本而中途切换基线' 'Chinese workflow forbids mid-round upstream switching'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'archive the prepared test container with non-solid maximum 7z compression' 'English workflow documents reusable Podman container archive'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' '使用 7z 非固实最高压缩打包已准备好的测试容器' 'Chinese workflow documents reusable Podman container archive'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'CODEX_WEBVIEW_PORT' 'English workflow requires an isolated Codex Desktop webview port during host-network GUI validation'
Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' 'CODEX_WEBVIEW_PORT' 'Chinese workflow requires an isolated Codex Desktop webview port during host-network GUI validation'
Assert-TextContains 'README.adoc' '-CodexDesktopRootPath "$HOME/opt/CodexDesktop"' 'English README explicit Codex Desktop root install example'
Assert-TextContains 'README_zh-CN.adoc' '-CodexDesktopRootPath "$HOME/opt/CodexDesktop"' 'Chinese README explicit Codex Desktop root install example'
Assert-TextContains 'README.adoc' '[source,powershell' 'English README keeps Codex Desktop build example in PowerShell'
Assert-TextContains 'README_zh-CN.adoc' '[source,powershell' 'Chinese README keeps Codex Desktop build example in PowerShell'
Assert-TextContains 'README.adoc' 'Project version: `1.2.28`, synchronized with upstream Codex++ `v1.2.28`.' 'English README documents current pinned upstream version'
Assert-TextContains 'README_zh-CN.adoc' '项目版本：`1.2.28`，与上游 Codex++ `v1.2.28` 同步。' 'Chinese README documents current pinned upstream version'
Assert-TextContains 'CodexPlusPlus/src/Cargo.toml' 'version = "1.2.28"' 'vendored Codex++ workspace version matches current pinned upstream version'
Assert-TextNotContains '.gitignore' "`nCodexPlusPlus/`n" 'blanket upstream Codex++ source ignore'
Assert-TextNotContains '.gitignore' "`ncodex-desktop-linux/`n" 'blanket upstream Codex Desktop source ignore'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'patches/compatibility/' 'English snippets compatibility patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'patches/enhancements/' 'English snippets enhancement patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' 'patches/compatibility/' 'Chinese snippets compatibility patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' 'patches/enhancements/' 'Chinese snippets enhancement patch directory'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' '080-linux-local-thread-catalog-sync' 'English snippets local thread catalog patch'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' '080-linux-local-thread-catalog-sync' 'Chinese snippets local thread catalog patch'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'route-opened local conversations' 'English snippets document local conversation route hydration'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' '点击后始终无法加载' 'Chinese snippets document local conversation route hydration'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'helper HTTP bridge routes' 'English snippets document helper bridge route fallback'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' 'helper HTTP bridge routes' 'Chinese snippets document helper bridge route fallback'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'renamed or merged Codex asset chunk fallback' 'English snippets document merged Codex asset chunk fallback'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' 'Codex asset chunk fallback' 'Chinese snippets document merged Codex asset chunk fallback'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'unimportable Linux `app://-/assets/` dynamic chunk records' 'English snippets document unimportable Linux app-scheme asset records'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' '不可动态 import 的 chunk 记录' 'Chinese snippets document unimportable Linux app-scheme asset records'
Assert-TextContains 'docs/modules/ROOT/pages/snippets.adoc' 'minified dispatcher export drift' 'English snippets document minified dispatcher export drift'
Assert-TextContains 'docs/modules/ROOT/pages/snippets_zh-CN.adoc' '混淆 dispatcher export 漂移' 'Chinese snippets document minified dispatcher export drift'
Assert-TextContains 'docs/modules/ROOT/attachments/feature-matrix.json' 'handle_helper_bridge_route' 'Feature matrix tracks helper HTTP bridge route fallback'
Assert-TextContains 'docs/modules/ROOT/attachments/feature-matrix.json' 'injection_script_falls_back_to_helper_for_bridge_routes_when_binding_is_missing' 'Feature matrix tracks renderer helper fallback regression'
Assert-TextContains 'docs/modules/ROOT/attachments/feature-matrix.json' 'linux_renderer_asset_loader_can_find_merged_codex_chunks_by_features' 'Feature matrix tracks merged Codex asset chunk fallback regression'
Assert-TextContains 'docs/modules/ROOT/attachments/feature-matrix.json' 'linux_renderer_asset_loader_skips_linux_app_scheme_dynamic_chunks' 'Feature matrix tracks unimportable Linux app-scheme asset regression'
Assert-TextContains 'docs/modules/ROOT/attachments/feature-matrix.json' 'linux_renderer_service_tier_patch_finds_dispatcher_without_minified_export_name' 'Feature matrix tracks minified dispatcher export drift regression'
Assert-TextContains 'docs/modules/ROOT/attachments/feature-matrix.json' 'linux_renderer_dispatcher_patches_skip_hotkey_window_route' 'Feature matrix tracks hotkey-window dispatcher guard regression'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/030-linux-launcher-environment.patch' 'handle_helper_bridge_route' 'Launcher patch exposes helper HTTP bridge routes'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/060-renderer-linux-compatibility.patch' 'helperBridgeFallbackRoutes' 'Renderer patch falls back to helper routes when CDP binding is missing'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/060-renderer-linux-compatibility.patch' 'codexAppAssetFeatureFallbacks' 'Renderer patch can discover merged Codex asset chunks by feature markers'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/060-renderer-linux-compatibility.patch' 'codexAppAssetUrlFromLoadedResourceText' 'Renderer patch loads renamed or merged Codex asset chunks from loaded resource text'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/060-renderer-linux-compatibility.patch' 'codexAppAssetImportableUrl' 'Renderer patch skips unimportable Linux app-scheme asset records'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/060-renderer-linux-compatibility.patch' 'findCodexDispatcherClass' 'Renderer patch finds dispatcher without a fixed minified export name'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/060-renderer-linux-compatibility.patch' 'isCodexHotkeyWindowRoute' 'Renderer patch skips main-window dispatcher patches on hotkey route'
Assert-TextContains 'codex-desktop-linux/src/scripts/patches/core/all-linux/webview/local-conversation-route-hydration/patch.js' 'linux-local-conversation-route-hydration' 'Codex Desktop patch hydrates route-opened local conversations'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'default_helper_serves_settings_bridge_routes_over_http' 'Regression patch covers helper settings bridge route'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'injection_script_falls_back_to_helper_for_bridge_routes_when_binding_is_missing' 'Regression patch covers renderer helper fallback'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'linux_renderer_asset_loader_can_find_renamed_dynamic_chunks' 'Regression patch covers renamed Codex dynamic chunks'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'linux_renderer_asset_loader_can_find_merged_codex_chunks_by_features' 'Regression patch covers merged Codex asset chunk fallback'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'linux_renderer_asset_loader_skips_linux_app_scheme_dynamic_chunks' 'Regression patch covers unimportable Linux app-scheme asset records'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'linux_renderer_service_tier_patch_finds_dispatcher_without_minified_export_name' 'Regression patch covers minified dispatcher export drift'
Assert-TextContains 'docs/modules/ROOT/attachments/patches/compatibility/900-regression-tests.patch' 'linux_renderer_dispatcher_patches_skip_hotkey_window_route' 'Regression patch covers hotkey-window dispatcher guard'
Assert-TextContains 'docs/modules/ROOT/nav.adoc' 'adapter-workflow.adoc' 'English nav entry'
Assert-TextContains 'docs/modules/ROOT/nav.adoc' 'adapter-workflow_zh-CN.adoc' 'Chinese nav entry'
Assert-TextContains 'docs/modules/ROOT/nav.adoc' '2026-07-07-v1.2.28-host-regression-hotfix.adoc' 'Host regression hotfix maintenance note nav entry'
Assert-TextContains 'docs/modules/ROOT/pages/maintenance/2026-07-07-v1.2.28-host-regression-hotfix.adoc' '019ee62e-98ba-7c42-8a70-aa5a6f39e45f' 'Host regression note records the concrete unopenable conversation'

# EN: The AlmaLinux 9 Podman fixture is intentionally local-only. If it exists on this workstation, validate it strictly.
# ZH: AlmaLinux 9 Podman 测试夹具按约定只保存在本机；若当前工作站存在该目录，就严格校验其内容。
if (Test-RepoPathExists '.podman-test') {
    foreach ($file in @(
        '.podman-test/codexpp-alma9.Containerfile',
        '.podman-test/README.adoc',
        '.podman-test/pixi.toml',
        '.podman-test/run-codexpp-gui-validation.sh',
        '.podman-test/build-codexdesktop-in-container.ps1'
    )) {
        Assert-FileExists $file
    }

    # EN: The local fixture must preserve the Tauri/WebKitGTK 4.1 build layer discovered during validation.
    # ZH: 本地测试夹具必须固化验收中定位出的 Tauri/WebKitGTK 4.1 构建层。
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'ripgrep' 'AlmaLinux fixture installs ripgrep for source checks'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'pixi' 'AlmaLinux fixture installs pixi'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' '.podman-test/pixi.toml' 'AlmaLinux fixture uses a repository-local pixi manifest'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'noto-sans-cjk' 'AlmaLinux fixture installs Chinese-capable CJK fonts'
    Assert-TextNotContains '.podman-test/codexpp-alma9.Containerfile' 'micromamba' 'AlmaLinux fixture must not use micromamba'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'conda.anaconda.org' 'AlmaLinux fixture warms conda-forge host resolution for pixi'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'ReimuNotMoe/ydotool' 'AlmaLinux fixture builds ydotool from upstream source when no EL9 package exists'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' '--target ydotool ydotoold' 'AlmaLinux fixture avoids ydotool documentation dependency'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'install -m 0755 /tmp/ydotool-build/ydotool' 'AlmaLinux fixture installs ydotool binary manually'
    Assert-TextContains '.podman-test/pixi.toml' '"webkit2gtk4.1"' 'AlmaLinux fixture installs conda-forge WebKitGTK 4.1 through pixi'
    Assert-TextContains '.podman-test/pixi.toml' 'pkg-config' 'AlmaLinux fixture installs pkg-config through pixi'
    Assert-TextContains '.podman-test/pixi.toml' 'glibc = "2.34"' 'AlmaLinux fixture declares EL9 glibc virtual package for pixi solving'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'expat.pc' 'AlmaLinux fixture patches missing expat pkg-config file'
    Assert-TextNotContains '.podman-test/codexpp-alma9.Containerfile' '/etc/ld.so.conf.d/codexpp-tauri.conf' 'AlmaLinux fixture must not globally register the Pixi/Conda runtime linker path'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' '/etc/profile.d/codexpp-tauri.sh' 'AlmaLinux fixture exports conda build environment'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'node-v22' 'AlmaLinux fixture installs Node.js 22 for Codex Desktop build'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' '@openai/codex' 'AlmaLinux fixture installs Codex CLI required by Codex Desktop runtime'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' '7z2600-linux' 'AlmaLinux fixture installs modern 7zz for APFS DMG extraction'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' 'rustup.rs' 'AlmaLinux fixture installs Rust/Cargo for Linux Computer Use plugin builds'
    Assert-TextContains '.podman-test/codexpp-alma9.Containerfile' '/opt/rust/cargo/bin' 'AlmaLinux fixture exposes Rust/Cargo on PATH'
    Assert-TextNotContains '.podman-test/build-codexdesktop-in-container.ps1' 'bash scripts/install-deps.sh' 'Codex Desktop fixture must not run full upstream bootstrap on AlmaLinux 9'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' '$MinimumCodexDesktopNodeMajorVersion = 20' 'Codex Desktop fixture validates Node.js major version'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' 'Assert-CodexDesktopBuildDependency' 'Codex Desktop fixture validates build dependencies'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' "Assert-CodexDesktopBuildDependency 'cargo'" 'Codex Desktop fixture validates cargo for Linux Computer Use plugin builds'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' "Assert-CodexDesktopBuildDependency 'rustc'" 'Codex Desktop fixture validates rustc for Linux Computer Use plugin builds'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' "Assert-CodexDesktopBuildDependency 'codex'" 'Codex Desktop fixture validates Codex CLI runtime dependency'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' 'Copy-Item -Path ' 'Codex Desktop fixture copies build output instead of moving across NFS-backed mounts'
    Assert-TextNotContains '.podman-test/build-codexdesktop-in-container.ps1' "Move-Item -Path 'codex-app'" 'Codex Desktop fixture must not move codex-app across NFS-backed mounts'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' "'TryExec=codex-desktop-linux'" 'Codex Desktop fixture rewrites desktop TryExec to the installed Linux launcher'
    Assert-TextContains '.podman-test/build-codexdesktop-in-container.ps1' '$LASTEXITCODE' 'Codex Desktop fixture fails immediately after native command errors'
    Assert-TextContains '.podman-test/README.adoc' 'webkit2gtk4.1' 'Podman README documents conda-forge WebKitGTK layer'
    Assert-TextContains '.podman-test/README.adoc' 'Pixi' 'Podman README documents Pixi-managed Tauri/WebKitGTK layer'
    Assert-TextContains '.podman-test/README.adoc' 'Chinese font' 'Podman README documents CJK font coverage'
    Assert-TextContains '.podman-test/README.adoc' '--network=host' 'Podman README documents host network build requirement'
    Assert-TextContains '.podman-test/README.adoc' 'glibc = "2.34"' 'Podman README documents Pixi glibc virtual package'
    Assert-TextContains '.podman-test/README.adoc' 'conda.anaconda.org' 'Podman README documents Pixi conda-forge host resolution warmup'
    Assert-TextContains '.podman-test/README.adoc' 'non-solid maximum 7z compression' 'Podman README documents reusable container archive policy'
    Assert-TextContains '.podman-test/README.adoc' 'Rust/Cargo' 'Podman README documents Rust/Cargo requirement for Computer Use plugin builds'
    Assert-TextContains '.podman-test/README.adoc' 'Codex CLI' 'Podman README documents Codex CLI runtime dependency'
    Assert-TextContains '.podman-test/README.adoc' '.podman-test/' 'Podman README documents local fixture retention'
    Assert-TextContains '.podman-test/README.adoc' 'CODEX_WEBVIEW_PORT' 'Podman README documents isolated Codex Desktop webview port selection'
    Assert-TextContains '.podman-test/README.adoc' 'run-codexpp-gui-validation.sh' 'Podman README documents the GUI validation launcher'
    Assert-TextContains '.podman-test/README.adoc' 'isolated CODEX_HOME' 'Podman README documents isolated Codex home for GUI validation'
    Assert-TextContains '.podman-test/README.adoc' 'CODEX_PLUS_DISABLE_UPDATE_CHECK' 'Podman README documents fixed-baseline update prompt suppression'
    Assert-TextContains '.podman-test/README.adoc' 'plugins.sync.lock' 'Podman README documents stale plugin sync lock cleanup'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'CODEX_HOME="${CODEXPP_TEST_CODEX_HOME:-$HOME/.codex-codexpp-gui-test}"' 'GUI validation launcher isolates CODEX_HOME'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'CODEX_PLUS_DISABLE_UPDATE_CHECK=1' 'GUI validation launcher disables upstream update prompt for a fixed baseline round'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'plugins.sync.lock' 'GUI validation launcher removes stale plugin sync lock'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'dbus-run-session' 'GUI validation launcher starts a clean DBus session'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'env -u LD_LIBRARY_PATH dbus-run-session' 'GUI validation launcher starts DBus before injecting the Pixi library path'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'codexpp-tauri.conf.disabled' 'GUI validation launcher disables legacy global Pixi linker config'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'ldconfig' 'GUI validation launcher refreshes linker cache after disabling legacy Pixi linker config'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'unset CONDA_PREFIX PIXI_PROJECT_ENVIRONMENT PIXI_PROJECT_ROOT' 'GUI validation launcher prevents Pixi/Conda metadata from leaking into Electron'
    Assert-TextContains '.podman-test/run-codexpp-gui-validation.sh' 'LD_LIBRARY_PATH="/opt/conda/envs/codexpp-tauri/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' 'GUI validation launcher keeps the WebKitGTK runtime library path for Codex++ Manager'
} else {
    Assert-TextContains '.gitignore' '.podman-test/' 'local-only Podman fixture ignore rule'
    Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow.adoc' 'Podman fixture' 'English workflow documents local Podman fixture'
    Assert-TextContains 'docs/modules/ROOT/pages/adapter-workflow_zh-CN.adoc' 'Podman' 'Chinese workflow documents local Podman fixture'
}

Write-Host 'Adapter workflow contract OK.'
