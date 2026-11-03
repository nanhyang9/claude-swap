import Foundation
import ServiceManagement

/// Holds what the popover shows and refreshes it from cswap in the background.
///
/// The 60-second timer only re-reads cswap's view: cswap's own usage store
/// decides whether any account is actually fetched from Anthropic (every
/// 1–10 minutes depending on the account), so polling here never adds API
/// pressure beyond what `cswap list` itself allows.
///
/// All state is mutated on the main thread: the timer fires on the main run
/// loop, and background work hands its results back with `MainActor.run`.
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var busyMessage: String?

    @Published private(set) var chatgpt: ChatGPTUsage?
    @Published private(set) var chatgptError: String?

    @Published var showChatGPT: Bool {
        didSet {
            UserDefaults.standard.set(showChatGPT, forKey: Self.showChatGPTKey)
            if showChatGPT { refresh(forceChatGPT: true) }
        }
    }

    @Published var cswapPath: String {
        didSet {
            UserDefaults.standard.set(cswapPath, forKey: CswapCLI.pathDefaultsKey)
        }
    }

    /// Which claude-swap the app runs, for the Settings panel.
    @Published private(set) var cswapDescription: String = ""

    private static let showChatGPTKey = "showChatGPT"
    private let refreshInterval: TimeInterval = 60
    private let chatgptInterval: TimeInterval = 300
    private var lastChatGPTFetch: Date?
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        showChatGPT = defaults.object(forKey: Self.showChatGPTKey) as? Bool ?? true
        cswapPath = defaults.string(forKey: CswapCLI.pathDefaultsKey) ?? ""
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    var activeAccount: Account? { accounts.first { $0.active } }

    /// Short text for the menu bar: the active account's 5h and 7d percentages.
    var menuBarText: String? {
        guard let usage = activeAccount?.shownUsage else { return nil }
        var parts: [String] = []
        if let w = usage.fiveHour { parts.append("\(Int(w.pct.rounded()))%") }
        if let w = usage.sevenDay { parts.append("\(Int(w.pct.rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Refresh

    func refresh(forceChatGPT: Bool = false) {
        guard !isLoading else { return }
        isLoading = true
        let wantChatGPT = showChatGPT && (
            forceChatGPT
                || lastChatGPTFetch == nil
                || Date().timeIntervalSince(lastChatGPTFetch ?? .distantPast) >= chatgptInterval
        )
        Task.detached(priority: .utility) {
            let list = Result(catching: { try CswapCLI.listAccounts() })
            let gpt: Result<ChatGPTUsage, Error>? =
                wantChatGPT ? Result(catching: { try CswapCLI.chatgptUsage() }) : nil
            await MainActor.run {
                self.apply(list: list, chatgpt: gpt)
            }
        }
    }

    private func apply(list: Result<AccountList, Error>, chatgpt: Result<ChatGPTUsage, Error>?) {
        switch list {
        case .success(let result):
            accounts = result.accounts
            errorMessage = nil
            lastUpdated = Date()
        case .failure(let error):
            // Keep the last good list on screen; just report the failure.
            errorMessage = error.localizedDescription
        }
        if let chatgpt {
            lastChatGPTFetch = Date()
            switch chatgpt {
            case .success(let usage):
                self.chatgpt = usage
                chatgptError = nil
            case .failure(let error):
                self.chatgpt = nil
                chatgptError = error.localizedDescription
            }
        }
        isLoading = false
    }

    // MARK: - Actions

    func clearMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    func switchTo(_ account: Account) {
        perform("Switching to \(account.displayName)…",
                success: "Switched to \(account.displayName).") {
            try CswapCLI.switchTo(account.number)
        }
    }

    func switchToBest() {
        perform("Switching to the account with the most quota…",
                success: "Switched to the account with the most quota left.") {
            try CswapCLI.switchBest()
        }
    }

    /// Add a new account from a token.
    func addToken(_ token: String, email: String?, alias: String?,
                  completion: @escaping (Bool) -> Void) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Adding the account…", success: "Account added.", completion: completion) {
            try CswapCLI.addToken(value, email: email, alias: alias)
        }
    }

    /// Renew an existing token account in place (same slot).
    func replaceToken(_ token: String, account number: Int, name: String,
                      completion: @escaping (Bool) -> Void) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Replacing the token…", success: "Token replaced for \(name).",
                completion: completion) {
            try CswapCLI.replaceToken(value, account: number)
        }
    }

    func removeAccount(_ account: Account) {
        perform("Removing \(account.displayName)…",
                success: "Removed \(account.displayName).") {
            try CswapCLI.removeAccount(account.number)
        }
    }

    func addCurrentLogin(completion: @escaping (Bool) -> Void) {
        perform("Adding the current Claude Code login…", success: "Account saved.",
                completion: completion) {
            try CswapCLI.addCurrentLogin()
        }
    }

    /// `claude setup-token` needs a terminal (browser sign-in, pasted code),
    /// so it runs in Terminal; the new account shows up on the next refresh.
    func createTokenInTerminal(email: String?, alias: String?, replacing number: Int? = nil) {
        clearMessages()
        var args = ["setup-token", "--new"]
        if let number {
            args += ["--replace", String(number)]
        } else {
            if let email { args += ["--email", email] }
            if let alias { args += ["--alias", alias] }
        }
        do {
            try CswapCLI.openInTerminal(args)
            noticeMessage = "Finish in the Terminal window. The account appears here when it's done."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(
        _ message: String,
        success: String? = nil,
        completion: ((Bool) -> Void)? = nil,
        _ action: @escaping () throws -> Void
    ) {
        guard busyMessage == nil else { return }
        clearMessages()
        busyMessage = message
        Task.detached(priority: .userInitiated) {
            let result = Result(catching: action)
            await MainActor.run {
                self.busyMessage = nil
                switch result {
                case .success:
                    self.noticeMessage = success
                    completion?(true)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    completion?(false)
                }
                self.refresh()
            }
        }
    }

    func describeCswap() {
        Task.detached(priority: .utility) {
            let invocation = CswapCLI.locate()
            let version = invocation == nil ? nil : CswapCLI.version()
            let text: String
            if let invocation {
                text = "\(invocation.summary)" + (version.map { " \($0)" } ?? "")
            } else {
                text = "not found"
            }
            await MainActor.run { self.cswapDescription = text }
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
    }
}
