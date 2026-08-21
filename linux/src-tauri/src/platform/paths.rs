use std::{
    collections::HashMap,
    ffi::{OsStr, OsString},
    path::{Path, PathBuf},
};

pub type EnvMap = HashMap<OsString, OsString>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Platform {
    Unix,
    Windows,
}

impl Platform {
    pub const fn current() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else {
            Self::Unix
        }
    }
}

pub fn current_env() -> EnvMap {
    std::env::vars_os().collect()
}

pub fn non_empty_env<'a>(env: &'a EnvMap, key: &str) -> Option<&'a OsStr> {
    env.get(OsStr::new(key))
        .map(OsString::as_os_str)
        .filter(|value| !value.to_string_lossy().trim().is_empty())
}

pub fn platform_env<'a>(env: &'a EnvMap, key: &str, platform: Platform) -> Option<&'a OsStr> {
    non_empty_env(env, key).or_else(|| {
        (platform == Platform::Windows).then(|| {
            env.iter().find_map(|(candidate, value)| {
                candidate
                    .to_string_lossy()
                    .eq_ignore_ascii_case(key)
                    .then_some(value.as_os_str())
                    .filter(|value| !value.to_string_lossy().trim().is_empty())
            })
        })?
    })
}

pub fn user_home_from(env: &EnvMap, platform: Platform) -> Option<PathBuf> {
    match platform {
        Platform::Unix => platform_env(env, "HOME", platform).map(PathBuf::from),
        Platform::Windows => platform_env(env, "USERPROFILE", platform)
            .map(PathBuf::from)
            .or_else(|| {
                let drive = platform_env(env, "HOMEDRIVE", platform)?;
                let tail = platform_env(env, "HOMEPATH", platform)?;
                let mut home = drive.to_os_string();
                home.push(tail);
                Some(PathBuf::from(home))
            }),
    }
}

pub fn app_config_root_from(env: &EnvMap, platform: Platform) -> Option<PathBuf> {
    match platform {
        Platform::Unix => platform_env(env, "XDG_CONFIG_HOME", platform)
            .map(PathBuf::from)
            .or_else(|| user_home_from(env, platform).map(|home| home.join(".config"))),
        Platform::Windows => platform_env(env, "APPDATA", platform)
            .map(PathBuf::from)
            .or_else(|| {
                user_home_from(env, platform).map(|home| home.join("AppData").join("Roaming"))
            }),
    }
}

pub fn app_local_data_root_from(env: &EnvMap, platform: Platform) -> Option<PathBuf> {
    match platform {
        Platform::Unix => platform_env(env, "XDG_DATA_HOME", platform)
            .map(PathBuf::from)
            .or_else(|| user_home_from(env, platform).map(|home| home.join(".local/share"))),
        Platform::Windows => platform_env(env, "LOCALAPPDATA", platform)
            .map(PathBuf::from)
            .or_else(|| {
                user_home_from(env, platform).map(|home| home.join("AppData").join("Local"))
            }),
    }
}

pub fn app_local_data_root() -> Option<PathBuf> {
    app_local_data_root_from(&current_env(), Platform::current())
}

pub fn birdnion_config_path_from<F>(env: &EnvMap, platform: Platform, exists: F) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    if let Some(path) = platform_env(env, "BIRDNION_CONFIG", platform) {
        return Some(PathBuf::from(path));
    }

    let primary = app_config_root_from(env, platform)?.join("birdnion/settings.json");
    if exists(&primary) {
        return Some(primary);
    }

    if let Some(legacy) = user_home_from(env, platform)
        .map(|home| home.join(".birdnion/settings.json"))
        .filter(|path| exists(path))
    {
        return Some(legacy);
    }
    Some(primary)
}

pub fn birdnion_config_path() -> Option<PathBuf> {
    birdnion_config_path_from(&current_env(), Platform::current(), Path::exists)
}

pub fn claude_config_dir_from(env: &EnvMap, platform: Platform) -> Option<OsString> {
    platform_env(env, "CLAUDE_CONFIG_DIR", platform).map(OsStr::to_os_string)
}

pub fn claude_config_dirs_from(env: &EnvMap, platform: Platform) -> Vec<PathBuf> {
    if let Some(configured) = claude_config_dir_from(env, platform) {
        let roots: Vec<PathBuf> = configured
            .to_string_lossy()
            .split(',')
            .map(str::trim)
            .filter(|root| !root.is_empty())
            .map(PathBuf::from)
            .collect();
        if !roots.is_empty() {
            return roots;
        }
    }

    let Some(home) = user_home_from(env, platform) else {
        return Vec::new();
    };
    match platform {
        Platform::Unix => vec![home.join(".claude"), home.join(".config/claude")],
        Platform::Windows => vec![home.join(".claude")],
    }
}

pub fn claude_config_dirs() -> Vec<PathBuf> {
    claude_config_dirs_from(&current_env(), Platform::current())
}

pub fn is_projects_dir(path: &Path, platform: Platform) -> bool {
    match platform {
        Platform::Unix => path.file_name().is_some_and(|name| name == "projects"),
        Platform::Windows => path
            .as_os_str()
            .to_string_lossy()
            .trim_end_matches(['/', '\\'])
            .rsplit(['/', '\\'])
            .next()
            .is_some_and(|name| name.eq_ignore_ascii_case("projects")),
    }
}

pub fn codex_home_from(env: &EnvMap, platform: Platform) -> Option<PathBuf> {
    platform_env(env, "CODEX_HOME", platform)
        .map(PathBuf::from)
        .or_else(|| user_home_from(env, platform).map(|home| home.join(".codex")))
}

pub fn grok_home_from(env: &EnvMap, platform: Platform) -> Option<PathBuf> {
    platform_env(env, "GROK_HOME", platform)
        .map(PathBuf::from)
        .or_else(|| user_home_from(env, platform).map(|home| home.join(".grok")))
}

pub fn codex_home() -> Option<PathBuf> {
    codex_home_from(&current_env(), Platform::current())
}

pub fn grok_home() -> Option<PathBuf> {
    grok_home_from(&current_env(), Platform::current())
}

pub fn gemini_credentials_path_from(env: &EnvMap, platform: Platform) -> Option<PathBuf> {
    platform_env(env, "GEMINI_CLI_HOME", platform)
        .map(PathBuf::from)
        .or_else(|| user_home_from(env, platform))
        .map(|root| root.join(".gemini/oauth_creds.json"))
}

pub fn gemini_credentials_path() -> Option<PathBuf> {
    gemini_credentials_path_from(&current_env(), Platform::current())
}

pub fn cursor_state_db_candidates_from(env: &EnvMap, platform: Platform) -> Vec<PathBuf> {
    app_config_root_from(env, platform)
        .map(|root| root.join("Cursor/User/globalStorage/state.vscdb"))
        .into_iter()
        .collect()
}

pub fn cursor_state_db_candidates() -> Vec<PathBuf> {
    cursor_state_db_candidates_from(&current_env(), Platform::current())
}
