import Foundation
import VoxaCore

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String
    /// Output past the size limit was dropped and the process stopped.
    public var wasTruncated: Bool

    public init(status: Int32, standardOutput: String = "", standardError: String = "", wasTruncated: Bool = false) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.wasTruncated = wasTruncated
    }

    public var succeeded: Bool { status == 0 }
}

public enum ProcessError: Error, Sendable, Equatable {
    case launchFailed(String)
    /// The process outlived its time limit and was stopped.
    case timedOut
}

/// Runs a helper program (`osascript`, `shortcuts`) out of process, so a script that hangs can be killed and can never take
/// the app down with it. A protocol so tools are tested without launching anything.
public protocol ProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: Duration
    ) async throws -> ProcessOutput
}

/// `Process`-backed runner.
///
/// - The child gets a **minimal environment**: no inherited variables, so nothing secret in Voxa's own environment (an API
///   key exported for development, for instance) is visible to a script.
/// - Output is capped; a script that prints without end is stopped rather than filling memory.
/// - The process is stopped on timeout and on cancellation: first politely (SIGTERM), then for certain (SIGKILL).
public struct SystemProcessRunner: ProcessRunning {
    public let maxOutputBytes: Int
    public let environment: [String: String]

    public init(
        maxOutputBytes: Int = 256 * 1024,
        environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory(),
        ]
    ) {
        self.maxOutputBytes = maxOutputBytes
        self.environment = environment
    }

    public func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: Duration
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : stdin

        let handle = ProcessHandle(process)
        let exit = ExitWaiter()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            if let standardInput {
                // Written off the caller's task: a script that never reads its input must not block the write. A child
                // that exits without reading would otherwise raise SIGPIPE here, which ends the whole app.
                let writer = stdin.fileHandleForWriting
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global().async {
                    try? writer.write(contentsOf: standardInput)
                    try? writer.close()
                }
            }
            let limit = maxOutputBytes
            async let out = Self.drain(stdout.fileHandleForReading, limit: limit) { handle.stop() }
            async let err = Self.drain(stderr.fileHandleForReading, limit: limit) { handle.stop() }

            let timer = Task {
                try await Task.sleep(for: timeout)
                handle.markTimedOut()
                handle.stop()
            }
            let status = await exit.wait()
            timer.cancel()
            let (outData, outTruncated) = await out
            let (errData, errTruncated) = await err

            if handle.timedOut { throw ProcessError.timedOut }
            try Task.checkCancellation()
            // Lossy on purpose: a script's output that isn't valid UTF-8 must still be reported, not dropped.
            // swiftlint:disable optional_data_string_conversion
            return ProcessOutput(
                status: status,
                standardOutput: String(decoding: outData, as: UTF8.self),
                standardError: String(decoding: errData, as: UTF8.self),
                wasTruncated: outTruncated || errTruncated
            )
            // swiftlint:enable optional_data_string_conversion
        } onCancel: {
            handle.stop()
        }
    }

    /// Reads a pipe to its end (which arrives when the process exits), keeping at most `limit` bytes.
    private static func drain(
        _ file: FileHandle,
        limit: Int,
        onOverflow: @escaping @Sendable () -> Void
    ) async -> (Data, Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                var truncated = false
                while true {
                    let chunk = file.availableData  // blocks; empty at end of file
                    if chunk.isEmpty { break }
                    if data.count + chunk.count > limit {
                        data.append(chunk.prefix(limit - data.count))
                        if !truncated {
                            truncated = true
                            onOverflow()
                        }
                    } else {
                        data.append(chunk)
                    }
                }
                continuation.resume(returning: (data, truncated))
            }
        }
    }
}

/// Stops a process, politely and then for certain. Thread-safe.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var didTimeOut = false

    init(_ process: Process) {
        self.process = process
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Delivers a process's exit status to whoever waits for it, whichever happens first.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        lock.lock()
        status = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
