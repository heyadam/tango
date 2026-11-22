import Foundation

/// The line to whatever talks to the model: the Node program for Claude (`ProcessTransport`)
/// or the app itself for everyone else (`ChatTransport`). Messages are JSON objects; see
/// `Assistant/sidecar.mjs` for the ones that exist.
public protocol AssistantTransport: AnyObject {
    /// Called on the main actor for each message that arrives.
    var onMessage: (([String: Any]) -> Void)? { get set }
    /// Called once when the line closes, with what went wrong if anything did.
    var onClose: ((String?) -> Void)? { get set }
    /// Gets the other end running. `progress` reports slow steps, such as a first-time install.
    func start(progress: @escaping (String) -> Void) async throws
    func send(_ message: [String: Any])
    func stop()
}

public struct AssistantSetupError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs the assistant's Node program. Its files ship inside the app and are installed,
/// with their dependencies, in Application Support the first time they are needed.
public final class ProcessTransport: AssistantTransport {
    public var onMessage: (([String: Any]) -> Void)?
    public var onClose: ((String?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private let errors = LineBuffer()
    private var stoppedOnPurpose = false
    /// A Claude API key to answer on, in place of this Mac's Claude login.
    private let apiKey: String?
    private let needsKey: Bool

    /// With `needsKey` the line only opens with a key: the person chose to answer on one.
    public init(apiKey: String? = nil, needsKey: Bool = false) {
        self.apiKey = apiKey
        self.needsKey = needsKey
    }

    /// Where the assistant's program is installed.
    public static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tango/Assistant", isDirectory: true)
    }

    /// The Claude Code program that came with the Agent SDK, used for signing in.
    public static var claudeExecutable: URL? {
        let modules = directory.appendingPathComponent("node_modules/@anthropic-ai")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modules.path)) ?? []
        for name in names where name.hasPrefix("claude-agent-sdk-darwin") {
            let candidate = modules.appendingPathComponent(name).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func start(progress: @escaping (String) -> Void) async throws {
        if needsKey, apiKey == nil {
            throw AssistantSetupError(message: "Add a Claude API key in Settings (Command-comma), or choose to use this Mac's Claude login there. Then send your message again.")
        }
        let node = try await Self.findNode()
        let directory = Self.directory
        try await Self.install(into: directory, node: node, progress: progress)

        let process = Process()
        process.executableURL = node
        process.arguments = ["sidecar.mjs"]
        process.currentDirectoryURL = directory
        process.environment = Self.environment(node: node)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let complete = lines.append(data)
            guard !complete.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in complete {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        self?.onMessage?(object)
                    }
                }
            }
        }
        let errors = self.errors
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errors.keep(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    let detail = self.errors.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let failed = status != 0 && !self.stoppedOnPurpose
                    self.process = nil
                    self.onClose?(failed ? (detail.isEmpty ? "The assistant stopped (code \(status))." : detail) : nil)
                }
            }
        }
        // Stopped while Node was being found or installed: do not start what nobody will talk to.
        guard !stoppedOnPurpose else { throw CancellationError() }
        // Writing to a helper that has just died must be an error, not the end of the app.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
    }

    /// What goes down the line for a message: `start` takes the key along, when there is one.
    static func outgoing(_ message: [String: Any], apiKey: String?) -> [String: Any] {
        guard let apiKey, message["type"] as? String == "start" else { return message }
        return message.merging(["apiKey": apiKey]) { $1 }
    }

    public func send(_ message: [String: Any]) {
        guard let input, process?.isRunning == true,
              var data = try? JSONSerialization.data(withJSONObject: Self.outgoing(message, apiKey: apiKey))
        else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    public func stop() {
        stoppedOnPurpose = true
        try? input?.close()
        process?.terminate()
        input = nil
    }

    // MARK: Setting up

    private static func environment(node: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bin = node.deletingLastPathComponent().path
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    /// Looks on the PATH this process has. An app started from the Finder does not have
    /// the shell's PATH, so then a login shell is asked where Node is, and last the usual places.
    static func findNode() async throws -> URL {
        // Started from a shell, the PATH is already the shell's.
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(directory)/node"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // An interactive shell started under a terminal tries to take the terminal over and
        // is stopped for it, for good. So it is only asked when there is no terminal.
        let terminal = open("/dev/tty", O_RDONLY | O_NOCTTY)
        if terminal >= 0 { close(terminal) }
        if terminal < 0,
           let found = try? await run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", "command -v node"], in: nil, environment: nil) {
            for line in found.split(separator: "\n").reversed() {
                let path = line.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let nvm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        candidates += versions.sorted().reversed().map { nvm.appendingPathComponent("\($0)/bin/node").path }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw AssistantSetupError(message: "The assistant needs Node.js, which was not found. Install it from nodejs.org or with `brew install node`, then try again.")
    }

    /// Copies the program out of the app and installs what it depends on, when either is
    /// missing or the app brought a newer version.
    static func install(into directory: URL, node: URL, progress: @escaping (String) -> Void) async throws {
        guard let source = Bundle.module.url(forResource: "Assistant", withExtension: nil) else {
            throw AssistantSetupError(message: "The assistant's files are missing from the app.")
        }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var needsInstall = !files.fileExists(atPath: directory.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk").path)
        for name in ["package.json", "sidecar.mjs"] {
            let fresh = try Data(contentsOf: source.appendingPathComponent(name))
            let target = directory.appendingPathComponent(name)
            if (try? Data(contentsOf: target)) != fresh {
                try fresh.write(to: target)
                if name == "package.json" { needsInstall = true }
            }
        }
        guard needsInstall else { return }
        progress("Setting up the assistant. This takes a minute the first time.")
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        guard files.isExecutableFile(atPath: npm.path) else {
            throw AssistantSetupError(message: "npm was not found next to Node at \(node.path).")
        }
        do {
            _ = try await run(npm, ["install", "--no-audit", "--no-fund"], in: directory, environment: environment(node: node))
        } catch {
            throw AssistantSetupError(message: "Could not install the assistant: \(error.localizedDescription)")
        }
    }

    /// Runs a program to the end and returns what it printed.
    private static func run(
        _ executable: URL, _ arguments: [String], in directory: URL?, environment: [String: String]?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            if let environment { process.environment = environment }
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let collected = LineBuffer(), problems = LineBuffer()
            output.fileHandleForReading.readabilityHandler = { collected.keep($0.availableData) }
            errors.fileHandleForReading.readabilityHandler = { problems.keep($0.availableData) }
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: collected.text)
                } else {
                    let detail = problems.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: AssistantSetupError(message: detail.isEmpty ? "It stopped with code \(finished.terminationStatus)." : detail))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Collects bytes arriving on a background thread and hands back whole lines.
nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var kept = Data()

    init() {}

    /// Adds bytes and returns the lines they complete.
    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// Keeps the most recent output, for reporting what went wrong.
    func keep(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        kept.append(data)
        if kept.count > 8000 { kept.removeFirst(kept.count - 8000) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: kept, as: UTF8.self)
    }
}
