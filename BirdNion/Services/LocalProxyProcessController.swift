import Darwin
import Foundation

enum LocalProxyRuntimeState: Equatable {
    case checking
    case stopped
    case starting
    case running
    case failed
}

/// Starts BirdNion's bundled helper and can clean up a stale helper left by a
/// previous BirdNion process. It never signals an unrelated listener.
@MainActor
final class LocalProxyProcessController {
    private var ownedProcess: Process?

    var isOwnedProcessRunning: Bool {
        ownedProcess?.isRunning == true
    }

    func start(executable: URL, configURL: URL, workingDirectory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-config", configURL.path, "-local-model"]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        ownedProcess = process
    }

    @discardableResult
    func stopOwnedProcess() -> Bool {
        guard let process = ownedProcess else { return false }
        ownedProcess = nil
        guard process.isRunning else { return false }
        process.terminate()
        return true
    }

    /// Stops only listeners started with BirdNion's private CLIProxyAPI config.
    /// The retired default port is included so an older build can be cleaned up.
    @discardableResult
    func stopManagedListeners(configURL: URL, ports: [Int]) -> Bool {
        var stopped = stopOwnedProcess()
        let pids = Set(ports.flatMap { listenerPIDs(on: $0) })
        for pid in pids where Self.isManagedProcess(commandLine(for: pid), configURL: configURL) {
            stopped = kill(pid_t(pid), SIGTERM) == 0 || stopped
        }
        return stopped
    }

    /// A successful loopback health response is trusted only when the listener
    /// is the bundled helper launched with BirdNion's exact private config.
    /// This prevents a foreign process occupying the fixed port from receiving
    /// profile credentials through the management API.
    func hasManagedListener(configURL: URL, ports: [Int]) -> Bool {
        let pids = Set(ports.flatMap { listenerPIDs(on: $0) })
        return pids.contains { pid in
            Self.isManagedProcess(commandLine(for: pid), configURL: configURL)
        }
    }

    static func isManagedProcess(_ commandLine: String, configURL: URL) -> Bool {
        let helperToken = commandLine.hasPrefix("cliproxyapi ")
            || commandLine.contains("/cliproxyapi ")
        guard helperToken else { return false }

        let configArgument = "-config \(configURL.path)"
        guard let range = commandLine.range(of: configArgument) else { return false }
        return range.upperBound == commandLine.endIndex
            || commandLine[range.upperBound].isWhitespace
    }

    private func listenerPIDs(on port: Int) -> [Int32] {
        guard let output = commandOutput(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        ) else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func commandLine(for pid: Int32) -> String {
        commandOutput(
            executable: "/bin/ps",
            arguments: ["-ww", "-p", String(pid), "-o", "command="]
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func commandOutput(executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
