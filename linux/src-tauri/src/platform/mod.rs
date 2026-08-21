pub mod atomic_file;
#[cfg(windows)]
mod atomic_file_windows;
pub mod executable;
pub mod paths;
pub mod process;
#[cfg(windows)]
mod process_windows;

#[cfg(test)]
mod path_contract_tests {
    use std::{ffi::OsStr, path::PathBuf};

    use super::paths::*;

    fn env(entries: &[(&str, &str)]) -> EnvMap {
        entries
            .iter()
            .map(|(key, value)| ((*key).into(), (*value).into()))
            .collect()
    }

    #[test]
    fn non_empty_lookup_rejects_empty_and_whitespace() {
        let values = env(&[("EMPTY", ""), ("SPACE", "  "), ("VALUE", " a b ")]);
        assert_eq!(non_empty_env(&values, "EMPTY"), None);
        assert_eq!(non_empty_env(&values, "SPACE"), None);
        assert_eq!(non_empty_env(&values, "VALUE"), Some(OsStr::new(" a b ")));
    }

    #[test]
    fn resolves_unix_and_windows_homes() {
        let cases = [
            (
                env(&[("HOME", "/Users/người dùng")]),
                Platform::Unix,
                Some("/Users/người dùng"),
            ),
            (
                env(&[("USERPROFILE", r"C:\Users\Jane Doe")]),
                Platform::Windows,
                Some(r"C:\Users\Jane Doe"),
            ),
            (
                env(&[("HOMEDRIVE", "D:"), ("HOMEPATH", r"\Users\李")]),
                Platform::Windows,
                Some(r"D:\Users\李"),
            ),
            (EnvMap::new(), Platform::Windows, None),
        ];
        for (values, platform, expected) in cases {
            assert_eq!(
                user_home_from(&values, platform),
                expected.map(PathBuf::from)
            );
        }
    }

    #[test]
    fn resolves_platform_config_roots() {
        let windows = env(&[("APPDATA", r"D:\Profiles\Jane Doe\AppData\Roaming")]);
        assert_eq!(
            app_config_root_from(&windows, Platform::Windows),
            Some(PathBuf::from(r"D:\Profiles\Jane Doe\AppData\Roaming"))
        );
        let fallback = env(&[("USERPROFILE", r"C:\Users\李")]);
        assert_eq!(
            app_config_root_from(&fallback, Platform::Windows),
            Some(PathBuf::from(r"C:\Users\李").join("AppData/Roaming"))
        );
        let unix = env(&[("HOME", "/home/me"), ("XDG_CONFIG_HOME", "/data/config")]);
        assert_eq!(
            app_config_root_from(&unix, Platform::Unix),
            Some("/data/config".into())
        );
    }

    #[test]
    fn config_path_preserves_override_primary_and_legacy_precedence() {
        let override_env = env(&[("BIRDNION_CONFIG", "/custom/Bird Nion.json")]);
        assert_eq!(
            birdnion_config_path_from(&override_env, Platform::Unix, |_| false),
            Some("/custom/Bird Nion.json".into())
        );
        let unix = env(&[("HOME", "/home/me"), ("XDG_CONFIG_HOME", "/xdg")]);
        let legacy = PathBuf::from("/home/me/.birdnion/settings.json");
        assert_eq!(
            birdnion_config_path_from(&unix, Platform::Unix, |path| path == legacy),
            Some(legacy)
        );
        let windows = env(&[
            ("USERPROFILE", r"C:\Users\me"),
            ("APPDATA", r"D:\Roaming"),
            ("XDG_CONFIG_HOME", r"E:\ignored"),
        ]);
        let primary = PathBuf::from(r"D:\Roaming").join("birdnion/settings.json");
        assert_eq!(
            birdnion_config_path_from(&windows, Platform::Windows, |path| path == primary),
            Some(primary)
        );
    }

    #[test]
    fn config_path_uses_existing_windows_legacy_only_as_fallback() {
        let values = env(&[("USERPROFILE", r"C:\Users\me"), ("APPDATA", r"D:\Roaming")]);
        let legacy = PathBuf::from(r"C:\Users\me").join(".birdnion/settings.json");
        assert_eq!(
            birdnion_config_path_from(&values, Platform::Windows, |path| path == legacy),
            Some(legacy)
        );
        assert_eq!(
            birdnion_config_path_from(&EnvMap::new(), Platform::Windows, |_| false),
            None
        );
    }

    #[test]
    fn provider_homes_keep_overrides_and_dot_dir_defaults() {
        let values = env(&[
            ("HOME", "/home/me"),
            ("CLAUDE_CONFIG_DIR", "/one,/two"),
            ("CODEX_HOME", "/custom/codex"),
            ("GROK_HOME", "/custom/grok"),
        ]);
        assert_eq!(
            claude_config_dir_from(&values, Platform::Unix),
            Some("/one,/two".into())
        );
        assert_eq!(
            codex_home_from(&values, Platform::Unix),
            Some("/custom/codex".into())
        );
        assert_eq!(
            grok_home_from(&values, Platform::Unix),
            Some("/custom/grok".into())
        );
        let defaults = env(&[("HOME", "/home/me")]);
        assert_eq!(
            codex_home_from(&defaults, Platform::Unix),
            Some("/home/me/.codex".into())
        );
        assert_eq!(
            grok_home_from(&defaults, Platform::Unix),
            Some("/home/me/.grok".into())
        );
        let windows = env(&[("USERPROFILE", r"C:\Users\李")]);
        assert_eq!(
            codex_home_from(&windows, Platform::Windows),
            Some(PathBuf::from(r"C:\Users\李").join(".codex"))
        );
        assert_eq!(
            grok_home_from(&windows, Platform::Windows),
            Some(PathBuf::from(r"C:\Users\李").join(".grok"))
        );
    }

    #[test]
    fn claude_config_dirs_split_override_and_keep_defaults() {
        let values = env(&[("CLAUDE_CONFIG_DIR", " /first , ,/second path, /配置 ")]);
        assert_eq!(
            claude_config_dirs_from(&values, Platform::Windows),
            vec![
                PathBuf::from("/first"),
                PathBuf::from("/second path"),
                PathBuf::from("/配置"),
            ]
        );
        let unix = env(&[("HOME", "/home/me")]);
        assert_eq!(
            claude_config_dirs_from(&unix, Platform::Unix),
            vec![
                PathBuf::from("/home/me/.config/claude"),
                PathBuf::from("/home/me/.claude"),
            ]
        );
        let windows = env(&[("USERPROFILE", r"C:\Users\me")]);
        assert_eq!(
            claude_config_dirs_from(&windows, Platform::Windows),
            vec![PathBuf::from(r"C:\Users\me").join(".claude")]
        );
    }

    #[test]
    fn windows_environment_keys_are_case_insensitive() {
        let values = env(&[
            ("UserProfile", r"C:\Users\me"),
            ("appdata", r"D:\Roaming"),
            ("codex_home", r"D:\Codex"),
        ]);
        assert_eq!(
            user_home_from(&values, Platform::Windows),
            Some(PathBuf::from(r"C:\Users\me"))
        );
        assert_eq!(
            app_config_root_from(&values, Platform::Windows),
            Some(PathBuf::from(r"D:\Roaming"))
        );
        assert_eq!(
            codex_home_from(&values, Platform::Windows),
            Some(PathBuf::from(r"D:\Codex"))
        );
        assert_eq!(platform_env(&values, "PATH", Platform::Unix), None);
    }

    #[test]
    fn projects_leaf_uses_platform_case_semantics() {
        let mixed_case = PathBuf::from(r"C:\Users\me\.claude\Projects");
        assert!(is_projects_dir(&mixed_case, Platform::Windows));
        assert!(!is_projects_dir(&mixed_case, Platform::Unix));
    }
}
