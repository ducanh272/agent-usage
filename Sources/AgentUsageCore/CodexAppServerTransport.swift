import Foundation

public enum AppServerTransportError: Error, Equatable, Sendable {
    case alreadyStarted
    case notRunning
    case stopped
    case launchFailed
    case processExited
    case invalidFrame
    case writeFailed
    case timedOut
    case cancelled
    case serverError(code: Int?)
}

public struct AppServerNotification: Sendable {
    public let method: String
    public let params: Data?

    public init(method: String, params: Data?) {
        self.method = method
        self.params = params
    }
}

/// One Codex App Server child process and its newline-delimited JSON connection.
public actor CodexAppServerTransport {
    private enum State {
        case idle
        case starting
        case ready
        case stopped
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let codexHomeURL: URL
    private let defaultTimeout: Duration
    private var state: State = .idle
    private var process: Process?
    private var input: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private let notificationContinuation: AsyncStream<AppServerNotification>.Continuation
    public nonisolated let notifications: AsyncStream<AppServerNotification>

    public init(executableURL: URL, codexHomeURL: URL, defaultTimeout: Duration = .seconds(10)) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
        self.defaultTimeout = defaultTimeout
        let stream = AsyncStream.makeStream(
            of: AppServerNotification.self, bufferingPolicy: .bufferingNewest(100)
        )
        self.notifications = stream.stream
        self.notificationContinuation = stream.continuation
    }

    /// Starts the child and completes the required handshake before returning.
    public func start() async throws {
        guard state == .idle else { throw AppServerTransportError.alreadyStarted }
        state = .starting

        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": codexHomeURL.path]) {
            _, selected in selected
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        do {
            try child.run()
        } catch {
            state = .stopped
            notificationContinuation.finish()
            throw AppServerTransportError.launchFailed
        }
        process = child
        input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        let diagnostics = stderr.fileHandleForReading

        stdoutTask = Task.detached(priority: .utility) { [weak self] in
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                await self?.receive(chunk)
            }
            await self?.streamClosed()
        }
        // Drain stderr independently. It may contain sensitive diagnostics and is never parsed as protocol data.
        stderrTask = Task.detached(priority: .utility) {
            while !diagnostics.availableData.isEmpty { }
        }

        do {
            let initialize = try JSONSerialization.data(withJSONObject: [
                "clientInfo": ["name": "agent_usage", "title": AppInfo.displayName, "version": "0.1.0"]
            ])
            _ = try await performRequest(method: "initialize", params: initialize, timeout: defaultTimeout)
            try send(method: "initialized", id: nil, params: Data("{}".utf8))
            guard state == .starting else { throw AppServerTransportError.processExited }
            state = .ready
        } catch {
            stop(with: .processExited)
            throw error
        }
    }

    /// Returns only the JSON value under `result`; server errors expose a code but no raw diagnostic text.
    public func request(method: String, params: Data? = nil, timeout: Duration? = nil) async throws -> Data {
        guard state == .ready else { throw AppServerTransportError.notRunning }
        return try await performRequest(method: method, params: params, timeout: timeout ?? defaultTimeout)
    }

    public func notify(method: String, params: Data? = nil) throws {
        guard state == .ready else { throw AppServerTransportError.notRunning }
        try send(method: method, id: nil, params: params)
    }

    public func stop() {
        stop(with: .stopped)
    }

    private func performRequest(method: String, params: Data?, timeout: Duration) async throws -> Data {
        guard state == .starting || state == .ready else { throw AppServerTransportError.notRunning }
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.finish(id: id, result: .failure(AppServerTransportError.timedOut))
                }
                pending[id] = PendingRequest(continuation: continuation, timeoutTask: timer)
                do { try send(method: method, id: id, params: params) }
                catch { finish(id: id, result: .failure(AppServerTransportError.writeFailed)) }
                if Task.isCancelled {
                    finish(id: id, result: .failure(AppServerTransportError.cancelled))
                }
            }
        } onCancel: {
            Task { await self.finish(id: id, result: .failure(AppServerTransportError.cancelled)) }
        }
    }

    private func send(method: String, id: Int?, params: Data?) throws {
        var message: [String: Any] = ["method": method]
        if let id { message["id"] = id }
        if let params {
            message["params"] = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])
        }
        try write(message)
    }

    private func write(_ message: [String: Any]) throws {
        guard let input, state == .starting || state == .ready else { throw AppServerTransportError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ chunk: Data) {
        guard state == .starting || state == .ready else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.count > 8 * 1024 * 1024 {
                stop(with: .invalidFrame)
                return
            }
            if !line.isEmpty { handle(line) }
            if state == .stopped { return }
        }
        if buffer.count > 8 * 1024 * 1024 { stop(with: .invalidFrame) }
    }

    private func handle(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            stop(with: .invalidFrame)
            return
        }
        if let id = message["id"] as? Int, pending[id] != nil {
            if let error = message["error"] as? [String: Any] {
                finish(id: id, result: .failure(AppServerTransportError.serverError(code: error["code"] as? Int)))
            } else if let result = message["result"],
                      let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                finish(id: id, result: .success(data))
            } else {
                finish(id: id, result: .failure(AppServerTransportError.invalidFrame))
            }
        } else if let method = message["method"] as? String, message["id"] == nil {
            let params = message["params"].flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
            }
            notificationContinuation.yield(AppServerNotification(method: method, params: params))
        }
    }

    private func finish(id: Int, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func streamClosed() {
        stop(with: .processExited)
    }

    private func stop(with reason: AppServerTransportError) {
        guard state != .stopped else { return }
        state = .stopped
        for id in Array(pending.keys) { finish(id: id, result: .failure(reason)) }
        notificationContinuation.finish()
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
    }
}
