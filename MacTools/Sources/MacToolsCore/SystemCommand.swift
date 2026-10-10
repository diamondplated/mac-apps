import Foundation
import Darwin

public struct CommandResult: Sendable, Equatable {
    public let output: String
    public let errorOutput: String
    public let status: Int32
    public let truncated: Bool

    public init(output: String, errorOutput: String = "", status: Int32 = 0, truncated: Bool = false) {
        self.output = output
        self.errorOutput = errorOutput
        self.status = status
        self.truncated = truncated
    }
}

public enum SystemCommandError: LocalizedError {
    case invalidExecutable, timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidExecutable: "The diagnostic command is unavailable."
        case .timedOut: "The diagnostic took too long. Try again when your Mac is less busy."
        }
    }
}

/// Runs fixed native executables without a shell; drains both streams with bounded memory.
public enum SystemCommand {
    public static func run(_ executable: String, arguments: [String] = [], timeout: TimeInterval = 10,
                           maximumOutputBytes: Int = 1_000_000, retainOutputTail: Bool = false) async throws -> CommandResult {
        guard executable.hasPrefix("/"), (0.1...60).contains(timeout), (1...4_000_000).contains(maximumOutputBytes) else {
            throw SystemCommandError.invalidExecutable
        }
        let task = Task.detached(priority: .utility) {
            try execute(executable, arguments: arguments, timeout: timeout,
                        maximumOutputBytes: maximumOutputBytes, retainOutputTail: retainOutputTail)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func execute(_ executable: String, arguments: [String], timeout: TimeInterval,
                                maximumOutputBytes: Int, retainOutputTail: Bool) throws -> CommandResult {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "C"]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let stdout = CommandBuffer(limit: maximumOutputBytes, tail: retainOutputTail)
            let stderr = CommandBuffer(limit: maximumOutputBytes, tail: retainOutputTail)
            try process.run()
            let readers = DispatchGroup()
            for (handle, buffer) in [(output.fileHandleForReading, stdout), (errors.fileHandleForReading, stderr)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { readers.leave() }
                    while let data = try? handle.read(upToCount: 32_768), !data.isEmpty { buffer.append(data) }
                }
            }
            let deadline = Date().addingTimeInterval(timeout)
            var stopped: Error?
            while process.isRunning {
                if Task.isCancelled { stopped = CancellationError(); break }
                if Date() >= deadline { stopped = SystemCommandError.timedOut; break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if stopped != nil, process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(0.3)
                while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            if readers.wait(timeout: .now() + 1) == .timedOut {
                try? output.fileHandleForReading.close()
                try? errors.fileHandleForReading.close()
                _ = readers.wait(timeout: .now() + 0.2)
            }
            if let stopped { throw stopped }
            let left = stdout.snapshot(), right = stderr.snapshot()
            return CommandResult(output: String(decoding: left.0, as: UTF8.self),
                                 errorOutput: String(decoding: right.0, as: UTF8.self),
                                 status: process.terminationStatus, truncated: left.1 || right.1)
    }
}

private final class CommandBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let tail: Bool
    private var bytes = Data()
    private var truncated = false
    init(limit: Int, tail: Bool) { self.limit = limit; self.tail = tail }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if tail {
            bytes.append(data)
            if bytes.count > limit { bytes.removeFirst(bytes.count - limit); truncated = true }
        } else {
            let available = max(0, limit - bytes.count)
            bytes.append(data.prefix(available))
            if data.count > available { truncated = true }
        }
    }
    func snapshot() -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (bytes, truncated)
    }
}
