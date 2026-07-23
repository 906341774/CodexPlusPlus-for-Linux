use codex_plus_core::install::{
    InstallOptions, MANAGER_BUNDLE_ID, SILENT_BINARY, SILENT_BUNDLE_ID, app_bundle_names,
    build_macos_app_bundle, build_windows_entrypoint_plan, companion_binary_path_from_exe,
    default_install_root_strategy, macos_companion_bundle_identifier_from_exe, shortcut_names,
};

#[cfg(target_os = "linux")]
fn linux_install_env_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}

#[cfg(target_os = "linux")]
struct EnvVarRestore {
    key: &'static str,
    old_value: Option<std::ffi::OsString>,
}

#[cfg(target_os = "linux")]
impl Drop for EnvVarRestore {
    fn drop(&mut self) {
        if let Some(value) = self.old_value.take() {
            unsafe { std::env::set_var(self.key, value) };
        } else {
            unsafe { std::env::remove_var(self.key) };
        }
    }
}

#[cfg(target_os = "linux")]
fn set_xdg_data_home_for_test(path: &std::path::Path) -> EnvVarRestore {
    let old_value = std::env::var_os("XDG_DATA_HOME");
    unsafe { std::env::set_var("XDG_DATA_HOME", path) };
    EnvVarRestore {
        key: "XDG_DATA_HOME",
        old_value,
    }
}

#[test]
fn windows_entrypoint_plan_contains_silent_and_manager_entrypoints() {
    let options = InstallOptions {
        install_root: Some("C:/Users/A/Desktop".into()),
        launcher_path: Some("C:/Tools/codex-plus-plus.exe".into()),
        manager_path: Some("C:/Tools/codex-plus-plus-manager.exe".into()),
        remove_owned_data: false,
    };

    let plan = build_windows_entrypoint_plan(&options);

    assert!(plan.silent_shortcut.ends_with("Codex++.lnk"));
    assert!(plan.manager_shortcut.ends_with("Codex++ 管理工具.lnk"));
    assert_eq!(plan.launcher_path, "C:/Tools/codex-plus-plus.exe");
    assert_eq!(plan.manager_path, "C:/Tools/codex-plus-plus-manager.exe");
    assert_eq!(plan.silent_icon_path, "C:/Tools/codex-plus-plus.exe");
    assert_eq!(
        plan.manager_icon_path,
        "C:/Tools/codex-plus-plus-manager.exe"
    );
    assert_eq!(plan.uninstall_key, "CodexPlusPlus");
    assert_eq!(plan.legacy_uninstall_key, "Codex++");
    assert_eq!(
        plan.uninstaller_path.replace('\\', "/"),
        "C:/Tools/uninstall.exe"
    );
    assert_eq!(
        plan.uninstall_command.replace('\\', "/"),
        "\"C:/Tools/uninstall.exe\""
    );
    assert_eq!(
        plan.quiet_uninstall_command.replace('\\', "/"),
        "\"C:/Tools/uninstall.exe\" /S"
    );
    assert_ne!(
        plan.uninstall_command,
        "\"C:/Tools/codex-plus-plus-manager.exe\""
    );
}

#[test]
fn windows_entrypoint_plan_can_request_owned_data_removal_without_shell_script() {
    let options = InstallOptions {
        install_root: Some("C:/Users/A/Desktop".into()),
        launcher_path: None,
        manager_path: None,
        remove_owned_data: true,
    };

    let plan = build_windows_entrypoint_plan(&options);

    assert!(plan.silent_shortcut.ends_with("Codex++.lnk"));
    assert!(plan.manager_shortcut.ends_with("Codex++ 管理工具.lnk"));
    assert!(plan.remove_owned_data);
}

#[test]
fn macos_bundle_metadata_contains_silent_and_manager_apps() {
    let options = InstallOptions {
        install_root: Some("/Applications".into()),
        launcher_path: Some("/opt/Codex++/codex-plus-plus".into()),
        manager_path: Some("/opt/Codex++/codex-plus-plus-manager".into()),
        remove_owned_data: false,
    };

    let silent = build_macos_app_bundle(&options, false);
    let manager = build_macos_app_bundle(&options, true);

    assert!(silent.app_path.ends_with("Codex++.app"));
    assert!(manager.app_path.ends_with("Codex++ 管理工具.app"));
    assert!(silent.info_plist.contains("<string>Codex++</string>"));
    assert!(
        manager
            .info_plist
            .contains("<string>Codex++ 管理工具</string>")
    );
    assert_eq!(
        silent.binary_target_name.as_deref(),
        Some("codex-plus-plus")
    );
    assert_eq!(
        manager.binary_target_name.as_deref(),
        Some("codex-plus-plus-manager")
    );
    assert!(silent.launch_script.contains("$DIR/codex-plus-plus"));
    assert!(
        manager
            .launch_script
            .contains("$DIR/codex-plus-plus-manager")
    );
}

#[test]
fn installer_exports_expected_two_entrypoint_names() {
    assert_eq!(shortcut_names(), ("Codex++.lnk", "Codex++ 管理工具.lnk"));
    assert_eq!(app_bundle_names(), ("Codex++.app", "Codex++ 管理工具.app"));
}

#[test]
fn macos_dmg_includes_applications_shortcut_for_drag_install() {
    let script = std::fs::read_to_string("../../scripts/installer/macos/package-dmg.sh")
        .expect("read macOS DMG packaging script");

    assert!(script.contains("ln -s /Applications \"$STAGE/Applications\""));
}

#[test]
fn companion_binary_path_resolves_macos_silent_app_next_to_manager_app() {
    let manager_exe = std::path::Path::new(
        "/Applications/Codex++ 管理工具.app/Contents/MacOS/CodexPlusPlusManager",
    );

    let companion = companion_binary_path_from_exe(manager_exe, SILENT_BINARY);

    assert_eq!(
        companion,
        std::path::PathBuf::from("/Applications/Codex++.app/Contents/MacOS/CodexPlusPlus")
    );
    assert_ne!(
        companion,
        std::path::PathBuf::from(
            "/Applications/Codex++ 管理工具.app/Contents/MacOS/codex-plus-plus"
        )
    );
}

#[test]
fn companion_binary_path_resolves_macos_manager_app_next_to_silent_app() {
    let silent_exe = std::path::Path::new("/Applications/Codex++.app/Contents/MacOS/CodexPlusPlus");

    let companion =
        companion_binary_path_from_exe(silent_exe, codex_plus_core::install::MANAGER_BINARY);

    assert_eq!(
        companion,
        std::path::PathBuf::from(
            "/Applications/Codex++ 管理工具.app/Contents/MacOS/CodexPlusPlusManager"
        )
    );
}

#[test]
fn macos_companion_launch_uses_bundle_ids_from_app_translocation() {
    let manager_exe = std::path::Path::new(
        "/private/var/folders/x/AppTranslocation/manager-id/d/Codex++ 管理工具.app/Contents/MacOS/CodexPlusPlusManager",
    );
    let silent_exe = std::path::Path::new(
        "/private/var/folders/x/AppTranslocation/silent-id/d/Codex++.app/Contents/MacOS/CodexPlusPlus",
    );

    assert_eq!(
        macos_companion_bundle_identifier_from_exe(manager_exe, SILENT_BINARY),
        Some(SILENT_BUNDLE_ID)
    );
    assert_eq!(
        macos_companion_bundle_identifier_from_exe(
            silent_exe,
            codex_plus_core::install::MANAGER_BINARY,
        ),
        Some(MANAGER_BUNDLE_ID)
    );
}

#[test]
fn macos_companion_launch_keeps_bare_binary_development_mode() {
    let manager_exe = std::path::Path::new("/tmp/target/debug/codex-plus-plus-manager");

    assert_eq!(
        macos_companion_bundle_identifier_from_exe(manager_exe, SILENT_BINARY),
        None
    );
}

#[test]
fn macos_bundle_does_not_wrap_the_bundle_executable_in_itself() {
    let options = InstallOptions {
        install_root: Some("/Applications".into()),
        launcher_path: Some("/Applications/Codex++.app/Contents/MacOS/CodexPlusPlus".into()),
        manager_path: Some(
            "/Applications/Codex++ 管理工具.app/Contents/MacOS/CodexPlusPlusManager".into(),
        ),
        remove_owned_data: false,
    };

    let silent = build_macos_app_bundle(&options, false);
    let manager = build_macos_app_bundle(&options, true);

    assert_eq!(
        silent.binary_source,
        Some(std::path::PathBuf::from(
            "/Applications/Codex++.app/Contents/MacOS/CodexPlusPlus"
        ))
    );
    assert_eq!(
        manager.binary_source,
        Some(std::path::PathBuf::from(
            "/Applications/Codex++ 管理工具.app/Contents/MacOS/CodexPlusPlusManager"
        ))
    );
    assert!(silent.launch_script.contains("$DIR/codex-plus-plus"));
    assert!(
        manager
            .launch_script
            .contains("$DIR/codex-plus-plus-manager")
    );
}

#[test]
fn windows_default_install_root_uses_known_folder_before_userprofile_desktop() {
    let strategy = default_install_root_strategy();

    if cfg!(windows) {
        assert_eq!(strategy, "windows-known-folder");
    } else if cfg!(target_os = "macos") {
        assert_eq!(strategy, "macos-applications");
    } else {
        assert_eq!(strategy, "user-dirs-desktop");
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_adapter_entrypoint_health_contract_accepts_codex_app_root() {
    let source = include_str!("../src/install/mod.rs");

    assert!(source.contains("pub fn inspect_entrypoints_for_app"));
    assert!(source.contains(".codex-plusplus"));
    assert!(source.contains("launch-codex-plus-plus"));
    assert!(source.contains("linuxAdapterInstallRoot"));
}

#[cfg(target_os = "linux")]
#[test]
fn linux_adapter_entrypoint_detection_uses_codex_app_install_dir() {
    let _guard = linux_install_env_lock()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let temp = tempfile::tempdir().unwrap();
    let xdg_data_home = temp.path().join("empty-xdg-data");
    let _restore = set_xdg_data_home_for_test(&xdg_data_home);
    let app_dir = temp.path().join("codex-app");
    let install_dir = app_dir.join(".codex-plusplus/install");
    std::fs::create_dir_all(&install_dir).unwrap();
    std::fs::write(install_dir.join("launch-codex-plus-plus"), "#!/bin/sh\n").unwrap();
    std::fs::write(install_dir.join("codex-plus-plus-manager"), "").unwrap();

    let state = codex_plus_core::install::inspect_entrypoints_for_app(Some(&app_dir));

    assert!(state.silent_shortcut.installed);
    assert!(state.management_shortcut.installed);
    assert!(
        state
            .silent_shortcut
            .path
            .as_deref()
            .unwrap()
            .ends_with(".codex-plusplus/install/launch-codex-plus-plus")
    );
    assert!(
        state
            .management_shortcut
            .path
            .as_deref()
            .unwrap()
            .ends_with(".codex-plusplus/install/codex-plus-plus-manager")
    );
}

#[cfg(target_os = "linux")]
#[test]
fn linux_adapter_entrypoint_detection_uses_synced_state_install_root() {
    let _guard = linux_install_env_lock()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let temp = tempfile::tempdir().unwrap();
    let data_home = temp.path().join("xdg-data");
    let install_root = temp.path().join("external-codexpp");
    let install_dir = install_root.join("install");
    std::fs::create_dir_all(data_home.join("codex-plusplus")).unwrap();
    std::fs::create_dir_all(&install_dir).unwrap();
    std::fs::write(install_dir.join("launch-codex-plus-plus"), "#!/bin/sh\n").unwrap();
    std::fs::write(install_dir.join("codex-plus-plus-manager"), "").unwrap();
    std::fs::write(
        data_home.join("codex-plusplus/state.json"),
        format!(
            r#"{{"linuxAdapterInstallRoot":"{}","appRoot":"/stale/codex-app"}}"#,
            install_root.display()
        ),
    )
    .unwrap();
    let _restore = set_xdg_data_home_for_test(&data_home);

    let state = codex_plus_core::install::inspect_entrypoints_for_app(None);

    assert!(state.silent_shortcut.installed);
    assert!(state.management_shortcut.installed);
    assert_eq!(
        state.silent_shortcut.path.as_deref(),
        Some(install_dir.join("launch-codex-plus-plus").to_str().unwrap())
    );
    assert_eq!(
        state.management_shortcut.path.as_deref(),
        Some(
            install_dir
                .join("codex-plus-plus-manager")
                .to_str()
                .unwrap()
        )
    );
}
