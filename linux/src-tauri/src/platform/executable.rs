use std::{
    ffi::{OsStr, OsString},
    path::{Path, PathBuf},
};

use super::paths::{current_env, platform_env, EnvMap, Platform};

const DEFAULT_WINDOWS_EXTENSIONS: [&str; 4] = [".EXE", ".COM", ".BAT", ".CMD"];

pub fn resolve_executable(name: impl AsRef<OsStr>) -> Option<PathBuf> {
    resolve_executable_from(
        name.as_ref(),
        &current_env(),
        Platform::current(),
        Path::is_file,
    )
}

pub fn resolve_executable_from<F>(
    name: &OsStr,
    env: &EnvMap,
    platform: Platform,
    is_file: F,
) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    if name.is_empty() {
        return None;
    }

    let extensions = windows_extensions(env, platform);
    if has_path_separator(name, platform) {
        return find_candidate(PathBuf::from(name), name, &extensions, platform, &is_file);
    }

    let path = platform_env(env, "PATH", platform)?;
    let directories = search_directories(path, platform);
    if platform == Platform::Windows && !has_explicit_extension(name, platform) {
        return directories.iter().find_map(|directory| {
            extensions.iter().find_map(|extension| {
                let candidate = append_extension(directory.join(name), extension);
                is_file(&candidate).then_some(candidate)
            })
        });
    }
    directories.into_iter().find_map(|directory| {
        let candidate = directory.join(name);
        is_file(&candidate).then_some(candidate)
    })
}

fn find_candidate<F>(
    base: PathBuf,
    name: &OsStr,
    extensions: &[OsString],
    platform: Platform,
    is_file: &F,
) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    if platform == Platform::Unix || has_explicit_extension(name, platform) {
        return is_file(&base).then_some(base);
    }

    extensions.iter().find_map(|extension| {
        let candidate = append_extension(base.clone(), extension);
        is_file(&candidate).then_some(candidate)
    })
}

fn append_extension(base: PathBuf, extension: &OsStr) -> PathBuf {
    let mut candidate = base.into_os_string();
    candidate.push(extension);
    PathBuf::from(candidate)
}

fn search_directories(path: &OsStr, platform: Platform) -> Vec<PathBuf> {
    match platform {
        Platform::Unix => std::env::split_paths(path).collect(),
        Platform::Windows => split_windows_paths(path),
    }
}

fn split_windows_paths(path: &OsStr) -> Vec<PathBuf> {
    let mut entries = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    for character in path.to_string_lossy().chars() {
        match character {
            '"' => quoted = !quoted,
            ';' if !quoted => {
                let entry = current.trim();
                if !entry.is_empty() {
                    entries.push(PathBuf::from(entry));
                }
                current.clear();
            }
            _ => current.push(character),
        }
    }
    let entry = current.trim();
    if !entry.is_empty() {
        entries.push(PathBuf::from(entry));
    }
    entries
}

fn windows_extensions(env: &EnvMap, platform: Platform) -> Vec<OsString> {
    if platform == Platform::Unix {
        return Vec::new();
    }
    let configured = platform_env(env, "PATHEXT", platform).map(|value| {
        value
            .to_string_lossy()
            .split(';')
            .map(str::trim)
            .filter(|extension| !extension.is_empty())
            .map(|extension| {
                if extension.starts_with('.') {
                    OsString::from(extension)
                } else {
                    OsString::from(format!(".{extension}"))
                }
            })
            .collect::<Vec<_>>()
    });
    configured
        .filter(|extensions| !extensions.is_empty())
        .unwrap_or_else(|| {
            DEFAULT_WINDOWS_EXTENSIONS
                .iter()
                .map(OsString::from)
                .collect()
        })
}

fn has_path_separator(name: &OsStr, platform: Platform) -> bool {
    let value = name.to_string_lossy();
    value.contains('/') || (platform == Platform::Windows && value.contains('\\'))
}

fn has_explicit_extension(name: &OsStr, platform: Platform) -> bool {
    if platform == Platform::Unix {
        return Path::new(name).extension().is_some();
    }
    let value = name.to_string_lossy();
    let leaf = value.rsplit(['/', '\\']).next().unwrap_or_default();
    leaf.rsplit_once('.')
        .is_some_and(|(stem, extension)| !stem.is_empty() && !extension.is_empty())
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    fn env(entries: &[(&str, &str)]) -> EnvMap {
        entries
            .iter()
            .map(|(key, value)| ((*key).into(), (*value).into()))
            .collect()
    }

    fn resolve(
        name: &str,
        values: &EnvMap,
        platform: Platform,
        files: &[PathBuf],
    ) -> Option<PathBuf> {
        let files: HashSet<&Path> = files.iter().map(PathBuf::as_path).collect();
        resolve_executable_from(OsStr::new(name), values, platform, |path| {
            files.contains(path)
        })
    }

    #[test]
    fn unix_uses_path_order_and_exact_filename() {
        let values = env(&[("PATH", "/first:/second")]);
        let files = [PathBuf::from("/first/tool"), PathBuf::from("/second/tool")];
        assert_eq!(
            resolve("tool", &values, Platform::Unix, &files),
            Some(files[0].clone())
        );
        assert_eq!(resolve("tool.exe", &values, Platform::Unix, &files), None);
    }

    #[test]
    fn windows_preserves_path_directory_precedence() {
        let values = env(&[("PATH", r"C:\first;D:\second"), ("PATHEXT", ".CMD;.EXE")]);
        let files = [
            PathBuf::from(r"C:\first").join("tool.EXE"),
            PathBuf::from(r"D:\second").join("tool.CMD"),
        ];
        assert_eq!(
            resolve("tool", &values, Platform::Windows, &files),
            Some(files[0].clone())
        );
    }

    #[test]
    fn windows_uses_pathext_order_within_one_directory() {
        let values = env(&[("PATH", r"C:\bin"), ("PATHEXT", ".CMD;.EXE")]);
        let files = [
            PathBuf::from(r"C:\bin").join("tool.EXE"),
            PathBuf::from(r"C:\bin").join("tool.CMD"),
        ];
        assert_eq!(
            resolve("tool", &values, Platform::Windows, &files),
            Some(files[1].clone())
        );
    }

    #[test]
    fn windows_default_extensions_include_exe_cmd_and_bat() {
        let values = env(&[("PATH", r"C:\bin")]);
        for extension in DEFAULT_WINDOWS_EXTENSIONS {
            let expected = PathBuf::from(r"C:\bin").join(format!("birdnion{extension}"));
            assert_eq!(
                resolve("birdnion", &values, Platform::Windows, &[expected.clone()]),
                Some(expected)
            );
        }
    }

    #[test]
    fn windows_preserves_explicit_extension() {
        let values = env(&[("PATH", r"C:\bin"), ("PATHEXT", ".EXE;.CMD")]);
        let expected = PathBuf::from(r"C:\bin").join("tool.cmd");
        assert_eq!(
            resolve("tool.cmd", &values, Platform::Windows, &[expected.clone()]),
            Some(expected)
        );
    }

    #[test]
    fn supports_spaces_unicode_and_literal_shell_characters() {
        let values = env(&[("PATH", r"C:\Program Files\工具")]);
        let unicode = PathBuf::from(r"C:\Program Files\工具").join("my tool.EXE");
        assert_eq!(
            resolve("my tool", &values, Platform::Windows, &[unicode.clone()]),
            Some(unicode)
        );

        let unix = env(&[("PATH", "/bin")]);
        let literal = PathBuf::from("/bin/$(tool)");
        assert_eq!(
            resolve("$(tool)", &unix, Platform::Unix, &[literal.clone()]),
            Some(literal)
        );
    }

    #[test]
    fn does_not_search_current_directory_implicitly() {
        let values = env(&[("PATH", r";C:\bin;;")]);
        let cwd_file = PathBuf::from("tool.EXE");
        assert_eq!(
            resolve("tool", &values, Platform::Windows, &[cwd_file]),
            None
        );
        assert_eq!(
            resolve("tool", &EnvMap::new(), Platform::Windows, &[]),
            None
        );
    }

    #[test]
    fn explicit_path_is_checked_without_path_search() {
        let values = env(&[("PATH", r"D:\other")]);
        let expected = PathBuf::from(r"C:\Apps\Bird Nion\tool.exe");
        assert_eq!(
            resolve(
                r"C:\Apps\Bird Nion\tool.exe",
                &values,
                Platform::Windows,
                &[expected.clone()]
            ),
            Some(expected)
        );
    }

    #[test]
    fn windows_unquotes_path_entries_and_keeps_quoted_semicolons() {
        let values = env(&[("PATH", r#""C:\Program Files\Tools";"D:\Semi;Colon""#)]);
        let expected = PathBuf::from(r"D:\Semi;Colon").join("tool.EXE");
        assert_eq!(
            resolve("tool", &values, Platform::Windows, &[expected.clone()]),
            Some(expected)
        );
    }

    #[test]
    fn unix_preserves_empty_path_component_as_current_directory() {
        let values = env(&[("PATH", ":/usr/bin")]);
        let expected = PathBuf::from("tool");
        assert_eq!(
            resolve("tool", &values, Platform::Unix, &[expected.clone()]),
            Some(expected)
        );
    }

    #[test]
    fn windows_path_and_pathext_keys_are_case_insensitive() {
        let values = env(&[("Path", r"C:\bin"), ("PathExt", ".CMD;.EXE")]);
        let expected = PathBuf::from(r"C:\bin").join("tool.CMD");
        assert_eq!(
            resolve("tool", &values, Platform::Windows, &[expected.clone()]),
            Some(expected)
        );
    }
}
