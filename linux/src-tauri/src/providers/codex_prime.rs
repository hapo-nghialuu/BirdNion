//! Safe Codex 5-hour-window priming command.
//!
//! Scheduling and once-per-day policy live in the frontend refresh tick. This
//! module only resolves the system CLI, launches one fixed read-only request,
//! and returns a credential-free success/failure result.

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const PRIME_ARGS: [&str; 5] = ["exec", "-s", "read-only", "--skip-git-repo-check", "say ok"];
const PRIME_TIMEOUT: Duration = Duration::from_secs(30);
const POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Runs a single harmless Codex request against the CLI-owned system home.
/// Tokens, account ids, stdout, and stderr are never returned to the WebView.
#[tauri::command]
pub async fn prime_codex() -> bool {
    tauri::async_runtime::spawn_blocking(prime_codex_blocking)
        .await
        .unwrap_or(false)
}

fn prime_codex_blocking() -> bool {
    let Some(executable) = crate::platform::executable::resolve_executable("codex") else {
        return false;
    };
    let Some(auth_path) = crate::codex_accounts::system_auth_path() else {
        return false;
    };
    let Some(codex_home) = auth_path.parent() else {
        return false;
    };
    run_prime(&executable, codex_home, PRIME_TIMEOUT)
}

fn prime_command(executable: &Path, codex_home: &Path) -> Command {
    let mut command = Command::new(executable);
    command
        .args(PRIME_ARGS)
        .env("CODEX_HOME", codex_home)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn run_prime(executable: &Path, codex_home: &Path, timeout: Duration) -> bool {
    let mut command = prime_command(executable, codex_home);
    let Ok(mut child) = command.spawn() else {
        return false;
    };
    let deadline = Instant::now() + timeout;
    wait_for_prime(&mut child, deadline)
}

fn wait_for_prime(child: &mut Child, deadline: Instant) -> bool {
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) => {
                let now = Instant::now();
                if now >= deadline {
                    let _ = child.kill();
                    return child.wait().map(|status| status.success()).unwrap_or(false);
                }
                thread::sleep(POLL_INTERVAL.min(deadline.saturating_duration_since(now)));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_uses_literal_safe_args_and_system_home() {
        let command = prime_command(Path::new("/opt/tools/codex"), Path::new("/home/me/.codex"));
        let args = command
            .get_args()
            .map(|value| value.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(args, PRIME_ARGS);
        assert_eq!(
            command
                .get_envs()
                .find(|(key, _)| *key == "CODEX_HOME")
                .and_then(|(_, value)| value)
                .map(Path::new),
            Some(Path::new("/home/me/.codex"))
        );
    }

    #[cfg(unix)]
    fn write_script(slug: &str, body: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "birdnion-codex-prime-{}-{slug}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("codex");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[cfg(unix)]
    #[test]
    fn runner_returns_true_only_for_zero_exit() {
        let home = Path::new("/tmp/system-codex-home");
        let success = write_script(
            "success",
            "if read line; then exit 9; fi; echo ignored; echo ignored >&2; exit 0",
        );
        let nonzero = write_script("nonzero", "exit 17");

        assert!(run_prime(&success, home, Duration::from_secs(1)));
        assert!(!run_prime(&nonzero, home, Duration::from_secs(1)));

        std::fs::remove_dir_all(success.parent().unwrap()).unwrap();
        std::fs::remove_dir_all(nonzero.parent().unwrap()).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn completed_child_status_wins_after_deadline() {
        let executable = write_script("completed", "exit 0");
        let mut command = prime_command(&executable, Path::new("/tmp/system-codex-home"));
        let mut child = command.spawn().unwrap();
        while child.try_wait().unwrap().is_none() {
            thread::yield_now();
        }

        assert!(wait_for_prime(
            &mut child,
            Instant::now() - Duration::from_millis(1),
        ));
        std::fs::remove_dir_all(executable.parent().unwrap()).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn runner_kills_and_waits_after_hard_timeout() {
        let executable = write_script("timeout", "while :; do :; done");
        let started = Instant::now();
        assert!(!run_prime(
            &executable,
            Path::new("/tmp/system-codex-home"),
            Duration::from_millis(40),
        ));
        assert!(started.elapsed() < Duration::from_secs(2));
        std::fs::remove_dir_all(executable.parent().unwrap()).unwrap();
    }
}
