import Foundation

/// Watches the system Codex home (`~/.codex`) and invalidates the system auth
/// context when its contents change — e.g. the user runs `codex login` in a
/// terminal, which rewrites `auth.json`. Mirrors CodexBar's
/// `CodexSystemAccountObserver` so the menu updates without a manual refresh.
///
/// Best-effort: silently no-ops if the directory can't be opened. QuotaService
/// debounces the resulting refreshes (codex login writes several files in quick
/// succession), and the watch re-arms if the directory is atomically replaced.
@MainActor
final class CodexSystemAccountObserver {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var rearmTask: Task<Void, Never>?

    private var watchedDir: URL {
        CodexAccountStore.systemAuthURL().deletingLastPathComponent()
    }

    func start() {
        stop()
        let dir = watchedDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let descriptor = open(dir.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        fd = descriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let replaced = src.data.contains(.delete) || src.data.contains(.rename)
            self.handleChange(rearm: replaced)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        rearmTask?.cancel()
        rearmTask = nil
    }

    private func handleChange(rearm: Bool) {
        // Fence an in-flight fetch before any delayed refresh can observe the
        // replacement credential. The system snapshot is identity-bound too.
        CodexAuthStore.invalidateCredential(at: CodexAccountStore.systemAuthURL())
        _ = CodexAccountSnapshotStore.shared.removeSnapshot(forAccount: "system")
        NotificationCenter.default.post(name: .birdnionRefresh, object: "codex")

        guard rearm else { return }
        rearmTask?.cancel()
        rearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            // The directory was swapped out from under us → re-open the watch.
            self?.start()
        }
    }
}
