import Foundation

/// Path resolution and discovery for Oh My Pi (`omp`) sessions and configuration roots.
///
/// Supports:
/// - Default session root: `~/.omp/agent/sessions/`
/// - Named profiles: `~/.omp/profiles/<name>/agent/sessions/`
/// - Environment overrides: `PI_CODING_AGENT_DIR`, `PI_CONFIG_DIR`, `OMP_PROFILE`, `PI_PROFILE`, `XDG_DATA_HOME`
enum OMPPaths {

    /// Default home directory.
    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Base `~/.omp` directory.
    static var baseDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["PI_CONFIG_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".omp", isDirectory: true)
    }

    /// Agent configuration file (`~/.omp/agent/config.yml` or active profile).
    static func configFile(profile: String? = nil) -> URL {
        if let profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
            return baseDirectory
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(profile, isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("config.yml")
        }
        return baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("config.yml")
    }

    /// SQLite agent database (`~/.omp/agent/agent.db`).
    static var databaseFile: URL {
        baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("agent.db")
    }

    /// Default sessions directory (`~/.omp/agent/sessions/`).
    static var defaultSessionsDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        return baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Discovers all valid session root directories across default and named profiles.
    /// Canonicalizes paths to prevent scanning the same directory twice.
    static func allSessionDirectories(fileManager: FileManager = .default) -> [URL] {
        var roots: [URL] = []
        var seenPaths: Set<String> = []

        func addRoot(_ url: URL) {
            let standardized = url.standardizedFileURL.path
            guard !seenPaths.contains(standardized) else { return }
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue {
                seenPaths.insert(standardized)
                roots.append(url.standardizedFileURL)
            }
        }

        // 1. Default session directory
        addRoot(defaultSessionsDirectory)

        // 2. Active profile from environment
        if let envProfile = ProcessInfo.processInfo.environment["OMP_PROFILE"] ?? ProcessInfo.processInfo.environment["PI_PROFILE"],
           !envProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let profileDir = baseDirectory
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(envProfile, isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            addRoot(profileDir)
        }

        // 3. Named profiles in ~/.omp/profiles/*/agent/sessions
        let profilesDir = baseDirectory.appendingPathComponent("profiles", isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for entry in entries {
                let sessionDir = entry
                    .appendingPathComponent("agent", isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true)
                addRoot(sessionDir)
            }
        }

        // 4. XDG data home fallback (~/.local/share/omp/agent/sessions)
        if let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !xdgData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let xdgSessions = URL(fileURLWithPath: xdgData, isDirectory: true)
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            addRoot(xdgSessions)
        }

        return roots
    }
}
