import Foundation

/// Runs the `cswap` command line tool and decodes its `--json` output.
///
/// The app never touches credentials itself: everything goes through cswap,
/// which already handles the Keychain, locking, token refresh and the usage
/// API's rate limits.
enum CswapCLI {
    static let pathDefaultsKey = "cswapPath"

    enum Failure: LocalizedError {
        case notFound
        case timedOut
        case command(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "claude-swap was not found: this app was built without its bundled copy. Rebuild it with build-app.sh, or set the path of an installed cswap in Settings."
            case .timedOut:
                return "cswap did not answer in time."
            case .command(let message):
                return message
            case .decode(let message):
                return "Unexpected output from cswap: \(message)"
            }
        }
    }

    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Directories a GUI app's minimal PATH lacks but where cswap usually is.
    static var extraPathDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    // MARK: - Locating cswap

    /// How to invoke cswap: an executable plus leading arguments.
    struct Invocation {
        let executable: String
        let leadingArguments: [String]
        let isBundled: Bool

        var summary: String {
            isBundled ? "bundled claude-swap" : executable
        }
    }

    /// The Python runtime with claude-swap that build-app.sh puts in the app.
    static var bundledPython: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let python = resources.appendingPathComponent("runtime/bin/python3").path
        return FileManager.default.isExecutableFile(atPath: python) ? python : nil
    }

    /// A path set in Settings wins; then the bundled copy; then an installed cswap.
    static func locate() -> Invocation? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: pathDefaultsKey),
           !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: expanded) else { return nil }
            return Invocation(executable: expanded, leadingArguments: [], isBundled: false)
        }
        if let python = bundledPython {
            return Invocation(executable: python, leadingArguments: ["-m", "claude_swap"], isBundled: true)
        }
        for dir in extraPathDirectories {
            let candidate = dir + "/cswap"
            if fm.isExecutableFile(atPath: candidate) {
                return Invocation(executable: candidate, leadingArguments: [], isBundled: false)
            }
        }
        // Last resort: ask the user's login shell, which sees their PATH.
        if let out = try? run(executable: "/bin/zsh",
                              arguments: ["-lc", "command -v cswap"],
                              timeout: 5) {
            let path = String(decoding: out.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return Invocation(executable: path, leadingArguments: [], isBundled: false)
            }
        }
        return nil
    }

    // MARK: - Commands

    static func listAccounts() throws -> AccountList {
        try decode(AccountList.self, from: runCswap(["list", "--json"], timeout: 90))
    }

    static func chatgptUsage() throws -> ChatGPTUsage {
        try decode(ChatGPTUsage.self, from: runCswap(["chatgpt", "--json"], timeout: 30))
    }

    static func switchTo(_ number: Int) throws {
        _ = try checked(runCswap(["switch", String(number), "--json"], timeout: 90))
    }

    static func switchBest() throws {
        _ = try checked(runCswap(["switch", "--strategy", "best", "--json"], timeout: 90))
    }

    // MARK: - Plumbing

    private static func runCswap(_ arguments: [String], timeout: TimeInterval) throws -> Output {
        guard let cswap = locate() else { throw Failure.notFound }
        return try run(
            executable: cswap.executable,
            arguments: cswap.leadingArguments + arguments,
            timeout: timeout,
            bundledPython: cswap.isBundled
        )
    }

    /// `cswap --version` of whichever copy is in use, for the Settings panel.
    static func version() -> String? {
        guard let out = try? runCswap(["--version"], timeout: 15), out.status == 0 else {
            return nil
        }
        let text = String(decoding: out.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: " ").last.map(String.init)
    }

    /// Throws the CLI's own error message on a non-zero exit.
    private static func checked(_ output: Output) throws -> Output {
        guard output.status == 0 else { throw commandFailure(output) }
        return output
    }

    private static func decode<T: Decodable>(_ type: T.Type, from output: Output) throws -> T {
        _ = try checked(output)
        do {
            return try JSONDecoder().decode(T.self, from: output.stdout)
        } catch {
            throw Failure.decode(error.localizedDescription)
        }
    }

    private static func commandFailure(_ output: Output) -> Failure {
        // --json errors arrive on stdout as {"schemaVersion":1,"error":{...}}.
        if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: output.stdout) {
            return .command(envelope.error.message)
        }
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.contains("no command given") || stderr.contains("invalid choice") {
            return .command("This cswap version does not support this command — update claude-swap.")
        }
        let lastLine = stderr.split(separator: "\n").last.map(String.init)
        return .command(lastLine ?? "cswap exited with status \(output.status).")
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        bundledPython: Bool = false
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPathDirectories + [basePath]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        if bundledPython {
            // Keep the bundled runtime isolated from any Python setup of the
            // user's, and never write bytecode into the signed app bundle.
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONNOUSERSITE"] = "1"
            env.removeValue(forKey: "PYTHONPATH")
            env.removeValue(forKey: "PYTHONHOME")
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.command("Could not start \(executable): \(error.localizedDescription)")
        }

        // Drain both pipes concurrently so a large output can't block the child.
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setStderr(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw Failure.timedOut
        }
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: box.stdout,
            stderr: String(decoding: box.stderr, as: UTF8.self)
        )
    }
}

/// Thread-safe holder for the two pipe readers' results.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setStdout(_ data: Data) { lock.lock(); out = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); err = data; lock.unlock() }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
}
